"""Monthly gaming summary, "Wrapped" (feature `summary`), from the energy ledger's game tables.

Every telemetry tick while a game runs adds to `game_daily` (play time, FPS and temperature sums,
peaks) for the PC's local day, and extends the game's current span in `game_spans`. A span ends
when the game has not been seen for 5 minutes, so a crash and relaunch stays one session. Both
tables live in `ledger.sqlite3` (see orbit_energy) and are written with it every 60 s.

Game names: the running exe's folder is looked up in Steam's `appmanifest_*.acf` files
(`installdir` → `name`) and Epic's `.item` manifests (`InstallLocation` → `DisplayName`); without
a match the exe name is tidied ("Cyberpunk2077" → "Cyberpunk 2077"). The environment variables
`ORBIT_STEAM_PATH`, `ORBIT_STEAM_LIBRARIES` (os.pathsep list) and `ORBIT_EPIC_MANIFESTS` replace
the registry and default folders.

`GET /api/summary?month=YYYY-MM` (main token, HTTPS only) answers
`{"month", "playSeconds", "daysPlayed", "sessions", "topGame", "games": [...], "longestSession",
"busiestDay", "peakCPUTemp", "peakGPUTemp", "energy": {"kWh", "cost", "currency"},
"previous": {"month", "playSeconds", "kWh"}, "available": ["2026-09", "2026-10"]}`.

On the first days of a month (the 1st, or the first time the agent runs within the first 7
days) a passive `summary.ready` event announces the previous month once, when it has play time.
"""
import calendar
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import threading
import time

import psutil
from fastapi import APIRouter, Depends, HTTPException, Query

try:
    import winreg
except ImportError:  # Not Windows.
    winreg = None

import orbit_energy
import orbit_events
import orbit_settings
from orbit_energy import _number, game_key, month_day_range, month_text, parse_month, prettify_game_name, shift_month

LOGGER = logging.getLogger("orbit.summary")

SPAN_GAP_SECONDS = 5 * 60
MIN_SESSION_SECONDS = 60
MIN_DAY_PLAY_SECONDS = 60
SUMMARY_READY_DAYS = 7
SUMMARY_READY_META = "summaryReadyMonth"
NAME_RETRY_SECONDS = 10 * 60
LIBRARY_CACHE_SECONDS = 10 * 60
MAX_MANIFESTS = 4000
MAX_MANIFEST_BYTES = 512 * 1024
MAX_NAME_CACHE = 512
MONTH_NAMES = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
               "October", "November", "December")


# Steam / Epic names ---------------------------------------------------------------------------

_VDF_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|(\{)|(\})|(//[^\r\n]*)|([^\s{}"]+)', re.S)
_VDF_ESCAPES = {"\\": "\\", '"': '"', "n": "\n", "t": "\t"}


def _unescape(text):
    return re.sub(r"\\(.)", lambda match: _VDF_ESCAPES.get(match.group(1), "\\" + match.group(1)), text)


def parse_vdf(text):
    """Valve's KeyValues text (appmanifest_*.acf, libraryfolders.vdf) as nested dicts."""
    root = {}
    stack = [root]
    key = None
    for match in _VDF_TOKEN.finditer(text):
        quoted, opening, closing, comment, bare = match.groups()
        if comment is not None:
            continue
        if opening:
            if key is None:
                raise ValueError("A block without a name")
            child = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        elif closing:
            if len(stack) == 1:
                raise ValueError("An unmatched closing brace")
            stack.pop()
            key = None
        else:
            token = _unescape(quoted) if quoted is not None else bare
            if key is None:
                key = token
            else:
                stack[-1][key] = token
                key = None
    return root


def _get(mapping, key):
    if not isinstance(mapping, dict):
        return None
    if key in mapping:
        return mapping[key]
    lowered = key.lower()
    return next((value for name, value in mapping.items() if name.lower() == lowered), None)


def _norm(path):
    return re.sub(r"[\\/]+", "/", str(path)).rstrip("/").lower()


def _parts(path):
    return [part for part in re.split(r"[\\/]+", str(path))]


def _read_text(path):
    path = Path(path)
    if path.stat().st_size > MAX_MANIFEST_BYTES:
        raise ValueError("Manifest too large")
    return path.read_text(encoding="utf-8-sig", errors="replace")


def _registry_steam_path():
    if winreg is None:
        return None
    for hive, key, value in ((getattr(winreg, "HKEY_CURRENT_USER", None), r"Software\Valve\Steam", "SteamPath"),
                             (getattr(winreg, "HKEY_LOCAL_MACHINE", None), r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                             (getattr(winreg, "HKEY_LOCAL_MACHINE", None), r"SOFTWARE\Valve\Steam", "InstallPath")):
        if hive is None:
            continue
        try:
            with winreg.OpenKey(hive, key) as handle:
                path, _ = winreg.QueryValueEx(handle, value)
            if isinstance(path, str) and path.strip():
                return path.strip()
        except OSError:
            continue
    return None


def steam_libraries():
    """Steam library roots: `ORBIT_STEAM_LIBRARIES`, else Steam's folder (`ORBIT_STEAM_PATH` or the
    registry) and the folders listed in its `libraryfolders.vdf`."""
    listed = os.getenv("ORBIT_STEAM_LIBRARIES")
    roots = [part for part in listed.split(os.pathsep) if part.strip()] if listed else []
    if not roots:
        steam = os.getenv("ORBIT_STEAM_PATH") or _registry_steam_path()
        if steam:
            roots.append(steam)
            try:
                folders = _get(parse_vdf(_read_text(Path(steam) / "steamapps" / "libraryfolders.vdf")), "libraryfolders")
            except (OSError, ValueError):
                folders = None
            for name, value in (folders or {}).items():
                path = _get(value, "path") if isinstance(value, dict) else (value if name.isdigit() else None)
                if isinstance(path, str) and path.strip():
                    roots.append(path.strip())
    unique, seen = [], set()
    for root in roots:
        if _norm(root) not in seen:
            seen.add(_norm(root))
            unique.append(root)
    return unique


def epic_manifest_folder():
    configured = os.getenv("ORBIT_EPIC_MANIFESTS")
    if configured:
        return Path(configured)
    return Path(os.getenv("PROGRAMDATA") or "C:/ProgramData") / "Epic" / "EpicGamesLauncher" / "Data" / "Manifests"


def find_process_exe(process_name):
    """Full path of a running process with this exe name (None when it is gone or hidden)."""
    target = (process_name or "").lower()
    if not target:
        return None
    for process in psutil.process_iter(["name", "exe"]):
        try:
            info = process.info
        except (psutil.Error, OSError):
            continue
        if (info.get("name") or "").lower() == target and info.get("exe"):
            return info["exe"]
    return None


class GameNames:
    """Store names for running games, cached (a game without a store match is retried every 10 min)."""

    def __init__(self, process_lookup=find_process_exe, clock=time.monotonic):
        self._lookup = process_lookup
        self._clock = clock
        self._names = {}
        self._steam = {}
        self._epic = None
        self._lock = threading.Lock()

    def _steam_names(self, root):
        now = self._clock()
        key = _norm(root)
        cached = self._steam.get(key)
        if cached and now - cached[0] < LIBRARY_CACHE_SECONDS:
            return cached[1]
        names = {}
        try:
            manifests = sorted((Path(root) / "steamapps").glob("appmanifest_*.acf"))[:MAX_MANIFESTS]
        except OSError:
            manifests = []
        for manifest in manifests:
            try:
                state = _get(parse_vdf(_read_text(manifest)), "AppState")
            except (OSError, ValueError):
                continue
            folder, name = _get(state, "installdir"), _get(state, "name")
            if isinstance(folder, str) and isinstance(name, str) and folder.strip() and name.strip():
                names[folder.strip().lower()] = " ".join(name.split())[:100]
        self._steam[key] = (now, names)
        return names

    def _epic_entries(self):
        now = self._clock()
        if self._epic and now - self._epic[0] < LIBRARY_CACHE_SECONDS:
            return self._epic[1]
        entries = []
        try:
            manifests = sorted(epic_manifest_folder().glob("*.item"))[:MAX_MANIFESTS]
        except OSError:
            manifests = []
        for manifest in manifests:
            try:
                item = json.loads(_read_text(manifest))
            except (OSError, ValueError):
                continue
            if not isinstance(item, dict):
                continue
            name, location = item.get("DisplayName"), item.get("InstallLocation")
            if not isinstance(name, str) or not name.strip():
                continue
            executables = set()
            launch = item.get("LaunchExecutable")
            if isinstance(launch, str) and launch.strip():
                executables.add(_parts(launch)[-1].lower())
            for process in item.get("ProcessNames") or []:
                if isinstance(process, str):
                    executables.add(_parts(process)[-1].lower())
            entries.append((_norm(location) if isinstance(location, str) and location.strip() else None,
                            " ".join(name.split())[:100], executables))
        self._epic = (now, entries)
        return entries

    def store_name(self, exe_path, process_name=None):
        """The Steam or Epic title for a running exe, or None."""
        if exe_path:
            parts = _parts(exe_path)
            lowered = [part.lower() for part in parts]
            for index in range(len(parts) - 3, -1, -1):
                if lowered[index] == "steamapps" and lowered[index + 1] == "common":
                    root, folder = "/".join(parts[:index]) or "/", lowered[index + 2]
                    name = self._steam_names(root).get(folder)
                    if name:
                        return name
                    for library in steam_libraries():
                        name = self._steam_names(library).get(folder)
                        if name:
                            return name
                    break
            normalized = _norm(exe_path)
            matches = [(len(location), name) for location, name, _ in self._epic_entries()
                       if location and (normalized == location or normalized.startswith(location + "/"))]
            if matches:
                return max(matches)[1]
        executable = _parts(exe_path or process_name or "")[-1].lower()
        if executable:
            for _, name, executables in self._epic_entries():
                if executable in executables:
                    return name
        return None

    def display_name(self, game, process_name=None):
        with self._lock:
            now = self._clock()
            cached = self._names.get(game)
            if cached and (cached[1] or now - cached[2] < NAME_RETRY_SECONDS):
                return cached[0]
            process = process_name if isinstance(process_name, str) and process_name.strip() else f"{game}.exe"
            try:
                exe_path = self._lookup(_parts(process)[-1])
            except Exception:
                exe_path = None
            try:
                name = self.store_name(exe_path, process)
            except Exception:
                LOGGER.debug("Could not read store manifests", exc_info=True)
                name = None
            found = name is not None
            name = name or (cached[0] if cached else None) or prettify_game_name(process if process_name else game)
            if len(self._names) >= MAX_NAME_CACHE and game not in self._names:
                self._names.clear()
            self._names[game] = (name, found, now)
            return name


# Tracking ---------------------------------------------------------------------------------------

class _GameBucket:
    __slots__ = ("name", "play_seconds", "fps_sum", "fps_count", "cpu_sum", "cpu_count", "cpu_peak",
                 "gpu_sum", "gpu_count", "gpu_peak")

    def __init__(self):
        self.name = None
        self.play_seconds = self.fps_sum = self.cpu_sum = self.gpu_sum = 0.0
        self.fps_count = self.cpu_count = self.gpu_count = 0
        self.cpu_peak = self.gpu_peak = None


class _Span:
    __slots__ = ("id", "game", "name", "started_at", "ended_at", "dirty")

    def __init__(self, identifier, game, name, started_at, ended_at, dirty=True):
        self.id = identifier
        self.game = game
        self.name = name
        self.started_at = started_at
        self.ended_at = ended_at
        self.dirty = dirty


def _peak(current, value):
    if value is None:
        return current
    return value if current is None else max(current, value)


def format_duration(seconds):
    minutes = int(round(seconds / 60.0))
    hours, minutes = divmod(minutes, 60)
    if hours and minutes:
        return f"{hours} h {minutes} min"
    return f"{hours} h" if hours else f"{minutes} min"


def _alerts_allow_summary():
    try:
        alerts = orbit_settings.shared_store().get("alerts", {})
    except Exception:
        return True
    summary = alerts.get("summary") if isinstance(alerts, dict) else None
    return not (isinstance(summary, dict) and summary.get("enabled") is False)


class GameTracker:
    """Per-day game totals and play spans, kept in memory between ledger flushes."""

    def __init__(self, ledger, *, names=None, emit=None, alerts_allow=_alerts_allow_summary,
                 day_of=orbit_energy.local_day):
        self.ledger = ledger
        self.names = names or GameNames()
        self._emit = emit or orbit_events.emit
        self._alerts_allow = alerts_allow
        self.day_of = day_of
        self._pending = {}
        self._span = None
        self._ended = []
        self._assigned = []
        self._resumed = False
        self._ready_checked = None

    def add(self, snapshot, dt, now, day, context=None):
        if snapshot.get("telemetryAvailable") is False:
            return
        process = snapshot.get("activeGameProcess") or snapshot.get("activeGame")
        game = game_key(process)
        if not game:
            return
        name = self.names.display_name(game, process if isinstance(process, str) else None)
        bucket = self._pending.get((day, game))
        if bucket is None:
            bucket = self._pending[(day, game)] = _GameBucket()
        bucket.name = name
        if dt > 0:
            bucket.play_seconds += dt
        fps = _number(snapshot.get("fps"), 0.0, 10000.0)
        if fps:
            bucket.fps_sum += fps
            bucket.fps_count += 1
        cpu = _number(snapshot.get("cpuTemp"), 1.0, 150.0)
        if cpu is not None:
            bucket.cpu_sum += cpu
            bucket.cpu_count += 1
            bucket.cpu_peak = _peak(bucket.cpu_peak, cpu)
        gpu = _number(snapshot.get("gpuTemp"), 1.0, 150.0)
        if gpu is not None:
            bucket.gpu_sum += gpu
            bucket.gpu_count += 1
            bucket.gpu_peak = _peak(bucket.gpu_peak, gpu)
        self._extend_span(game, name, now)

    def _extend_span(self, game, name, now):
        span = self._span
        if span is None and not self._resumed:
            # After a restart (or the boot instance's hand-over) the same game continues its span.
            self._resumed = True
            rows = self.ledger.query("SELECT * FROM game_spans ORDER BY ended_at DESC, id DESC LIMIT 1")
            if rows and rows[0]["game"] == game and -SPAN_GAP_SECONDS <= now - rows[0]["ended_at"] <= SPAN_GAP_SECONDS:
                row = rows[0]
                span = _Span(row["id"], row["game"], row["display_name"], row["started_at"], row["ended_at"], dirty=False)
        if span is not None and span.game == game and now - span.ended_at <= SPAN_GAP_SECONDS:
            span.ended_at = max(span.ended_at, now)
            span.name = name
            span.dirty = True
        else:
            if span is not None and span.dirty:
                self._ended.append(span)
            span = _Span(None, game, name, now, now)
        self._span = span

    def flush(self, db):
        self._assigned = []
        for (day, game), bucket in self._pending.items():
            row = db.execute("SELECT * FROM game_daily WHERE day = ? AND game = ?", (day, game)).fetchone()
            if row is None:
                db.execute("""INSERT INTO game_daily (day, game, display_name, play_seconds, fps_sum, fps_count,
                              cpu_temp_sum, cpu_temp_count, cpu_temp_peak, gpu_temp_sum, gpu_temp_count, gpu_temp_peak)
                              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                           (day, game, bucket.name, bucket.play_seconds, bucket.fps_sum, bucket.fps_count,
                            bucket.cpu_sum, bucket.cpu_count, bucket.cpu_peak, bucket.gpu_sum, bucket.gpu_count,
                            bucket.gpu_peak))
                continue
            db.execute("""UPDATE game_daily SET display_name = COALESCE(?, display_name), play_seconds = play_seconds + ?,
                          fps_sum = fps_sum + ?, fps_count = fps_count + ?, cpu_temp_sum = cpu_temp_sum + ?,
                          cpu_temp_count = cpu_temp_count + ?, cpu_temp_peak = ?, gpu_temp_sum = gpu_temp_sum + ?,
                          gpu_temp_count = gpu_temp_count + ?, gpu_temp_peak = ? WHERE day = ? AND game = ?""",
                       (bucket.name, bucket.play_seconds, bucket.fps_sum, bucket.fps_count, bucket.cpu_sum,
                        bucket.cpu_count, _peak(row["cpu_temp_peak"], bucket.cpu_peak), bucket.gpu_sum,
                        bucket.gpu_count, _peak(row["gpu_temp_peak"], bucket.gpu_peak), day, game))
        for span in self._ended + ([self._span] if self._span is not None else []):
            if not span.dirty:
                continue
            if span.id is None:
                cursor = db.execute("INSERT INTO game_spans (game, display_name, started_at, ended_at) VALUES (?, ?, ?, ?)",
                                    (span.game, span.name, span.started_at, span.ended_at))
                self._assigned.append((span, cursor.lastrowid))
            else:
                db.execute("UPDATE game_spans SET display_name = ?, ended_at = MAX(ended_at, ?) WHERE id = ?",
                           (span.name, span.ended_at, span.id))
                self._assigned.append((span, span.id))

    def flushed(self):
        """The flush committed: keep the new span ids and forget what was written."""
        for span, identifier in self._assigned:
            span.id = identifier
            span.dirty = False
        self._assigned = []
        self._ended = []
        self._pending.clear()

    def periodic(self, now):
        self.check_summary_ready(now)

    def check_summary_ready(self, now):
        """Emits `summary.ready` for last month once, in the first days of a month. Returns the event."""
        today = self.day_of(now)
        year, month, day = int(today[:4]), int(today[5:7]), int(today[8:10])
        if day > SUMMARY_READY_DAYS:
            return None
        previous = month_text(*shift_month(year, month, -1))
        if self._ready_checked == previous:
            return None
        sent = self.ledger.meta(SUMMARY_READY_META)
        if sent is not None and sent >= previous:
            self._ready_checked = previous
            return None
        first, after = month_day_range(*shift_month(year, month, -1))
        rows = self.ledger.query("""SELECT game, MAX(display_name) AS name, SUM(play_seconds) AS seconds FROM game_daily
                                    WHERE day >= ? AND day < ? GROUP BY game ORDER BY seconds DESC""", (first, after))
        total = sum(row["seconds"] or 0.0 for row in rows)
        self._ready_checked = previous
        if total < MIN_DAY_PLAY_SECONDS:
            return None
        # Remember first: a crash right after must not announce the month twice.
        self.ledger.set_meta(SUMMARY_READY_META, previous)
        if not self._alerts_allow():
            return None
        month_name = MONTH_NAMES[int(previous[5:7]) - 1]
        top = rows[0]["name"] or prettify_game_name(rows[0]["game"])
        body = f"You played {format_duration(total)} in {month_name}"
        body += f", most of it {top}." if len(rows) > 1 else f", all of it {top}."
        body += " Open Orbit to see your month."
        try:
            return self._emit("summary.ready", f"Your {month_name} summary is ready", body, level="passive",
                              data={"month": previous}, toast=False)
        except Exception:
            LOGGER.exception("Could not announce the monthly summary")
            return None


# Report -----------------------------------------------------------------------------------------

def _round(value, digits):
    return None if value is None else round(value, digits)


def month_summary(ledger, year, month, price, *, day_of=orbit_energy.local_day):
    """The `GET /api/summary` object (flush the ledger first)."""
    first, after = month_day_range(year, month)
    label = month_text(year, month)
    daily = ledger.query("SELECT * FROM game_daily WHERE day >= ? AND day < ? ORDER BY day", (first, after))
    energy_rows = ledger.query("SELECT * FROM energy_daily WHERE day >= ? AND day < ?", (first, after))
    currency, unit = orbit_energy._month_costing(energy_rows, price)

    games, per_day = {}, {}
    for row in daily:
        game = games.setdefault(row["game"], {"name": None, "play": 0.0, "fps_sum": 0.0, "fps_count": 0,
                                              "cpu_sum": 0.0, "cpu_count": 0, "cpu_peak": None,
                                              "gpu_sum": 0.0, "gpu_count": 0, "gpu_peak": None, "days": set(),
                                              "wh": 0.0, "cost": None})
        game["name"] = row["display_name"] or game["name"]
        game["play"] += row["play_seconds"]
        game["fps_sum"] += row["fps_sum"]
        game["fps_count"] += row["fps_count"]
        game["cpu_sum"] += row["cpu_temp_sum"]
        game["cpu_count"] += row["cpu_temp_count"]
        game["cpu_peak"] = _peak(game["cpu_peak"], row["cpu_temp_peak"])
        game["gpu_sum"] += row["gpu_temp_sum"]
        game["gpu_count"] += row["gpu_temp_count"]
        game["gpu_peak"] = _peak(game["gpu_peak"], row["gpu_temp_peak"])
        if row["play_seconds"] > 0:
            game["days"].add(row["day"])
        per_day[row["day"]] = per_day.get(row["day"], 0.0) + row["play_seconds"]

    total_wh, total_cost, costed, gaming_wh = 0.0, 0.0, False, 0.0
    for row in energy_rows:
        cost = orbit_energy.row_cost(row, currency, unit)
        total_wh += row["wall_wh"]
        if cost is not None:
            total_cost += cost
            costed = True
        if row["game"] and row["game"] in games:
            game = games[row["game"]]
            game["wh"] += row["wall_wh"]
            gaming_wh += row["wall_wh"]
            if cost is not None:
                game["cost"] = (game["cost"] or 0.0) + cost

    game_list = []
    for key, game in games.items():
        game_list.append({
            "game": key,
            "name": game["name"] or prettify_game_name(key),
            "playSeconds": int(round(game["play"])),
            "averageFPS": _round(game["fps_sum"] / game["fps_count"], 1) if game["fps_count"] else None,
            "peakGPUTemp": _round(game["gpu_peak"], 1),
            "peakCPUTemp": _round(game["cpu_peak"], 1),
            "averageGPUTemp": _round(game["gpu_sum"] / game["gpu_count"], 1) if game["gpu_count"] else None,
            "averageCPUTemp": _round(game["cpu_sum"] / game["cpu_count"], 1) if game["cpu_count"] else None,
            "daysPlayed": len(game["days"]),
            "kWh": round(game["wh"] / 1000.0, 3),
            "cost": _round(game["cost"], 2) if game["cost"] is not None else (0.0 if currency else None),
        })
    game_list = [game for game in game_list if game["playSeconds"] > 0]
    game_list.sort(key=lambda game: (-game["playSeconds"], game["name"]))

    # Spans that started in this month (local time); the query window is padded for time zones.
    start = calendar.timegm((year, month, 1, 0, 0, 0)) - 2 * 86400
    next_year, next_month = shift_month(year, month, 1)
    end = calendar.timegm((next_year, next_month, 1, 0, 0, 0)) + 2 * 86400
    spans = [row for row in ledger.query("SELECT * FROM game_spans WHERE started_at >= ? AND started_at < ?", (start, end))
             if day_of(row["started_at"])[:7] == label]
    sessions = [row for row in spans if row["ended_at"] - row["started_at"] >= MIN_SESSION_SECONDS]
    longest = max(spans, key=lambda row: (row["ended_at"] - row["started_at"], -row["started_at"]), default=None)
    names = {game["game"]: game["name"] for game in game_list}
    busiest = max(per_day.items(), key=lambda item: (item[1], item[0]), default=None)

    previous_year, previous_month = shift_month(year, month, -1)
    previous_first, previous_after = month_day_range(previous_year, previous_month)
    previous_play = ledger.query("SELECT COALESCE(SUM(play_seconds), 0) AS seconds FROM game_daily WHERE day >= ? AND day < ?",
                                 (previous_first, previous_after))[0]["seconds"]
    previous_wh = ledger.query("SELECT COALESCE(SUM(wall_wh), 0) AS wh FROM energy_daily WHERE day >= ? AND day < ?",
                               (previous_first, previous_after))[0]["wh"]

    play_total = sum(game["playSeconds"] for game in game_list)
    peaks_cpu = [game["peakCPUTemp"] for game in game_list if game["peakCPUTemp"] is not None]
    peaks_gpu = [game["peakGPUTemp"] for game in game_list if game["peakGPUTemp"] is not None]
    return {
        "month": label,
        "playSeconds": play_total,
        "daysPlayed": sum(1 for seconds in per_day.values() if seconds >= MIN_DAY_PLAY_SECONDS),
        "sessions": len(sessions),
        "topGame": game_list[0] if game_list else None,
        "games": game_list,
        "longestSession": None if longest is None else {
            "game": longest["game"],
            "name": names.get(longest["game"]) or longest["display_name"] or prettify_game_name(longest["game"]),
            "seconds": int(round(longest["ended_at"] - longest["started_at"])),
            "date": day_of(longest["started_at"]),
        },
        "busiestDay": None if busiest is None or busiest[1] <= 0 else {"day": busiest[0], "playSeconds": int(round(busiest[1]))},
        "peakCPUTemp": max(peaks_cpu) if peaks_cpu else None,
        "peakGPUTemp": max(peaks_gpu) if peaks_gpu else None,
        "energy": {"kWh": round(total_wh / 1000.0, 3),
                   "cost": _round(total_cost, 2) if costed else (0.0 if currency else None),
                   "currency": currency, "gamingKWh": round(gaming_wh / 1000.0, 3), "isEstimate": True},
        "previous": {"month": month_text(previous_year, previous_month), "playSeconds": int(round(previous_play)),
                     "kWh": round(previous_wh / 1000.0, 3)},
        "available": ledger.available_months(),
    }


def create_summary_router(verify_control, require_encrypted, store_provider=None):
    """`GET /api/summary` behind the main token and the encrypted connection."""
    router = APIRouter(prefix="/api", tags=["Monthly summary"],
                       dependencies=[Depends(verify_control), Depends(require_encrypted)])

    @router.get("/summary")
    def get_summary(month: str | None = Query(default=None, max_length=16)):
        runtime = orbit_energy.current_runtime()
        if runtime is None:
            raise HTTPException(503, "Monthly summaries are not running on the PC. Restart Orbit PC Companion.")
        try:
            year, number = parse_month(month) if month else parse_month(runtime.today()[:7])
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        store = store_provider() if store_provider is not None else None
        price = orbit_energy.current_price(store)
        try:
            runtime.flush()
            return month_summary(runtime.ledger, year, number, price, day_of=runtime.day_of)
        except (sqlite3.Error, RuntimeError) as error:
            raise HTTPException(503, "The PC could not read its play history. Try again in a moment.") from error

    return router
