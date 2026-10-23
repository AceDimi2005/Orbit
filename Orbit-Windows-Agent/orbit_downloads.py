"""Game downloads on this PC: Steam, Epic Games Launcher and GOG Galaxy (DESIGN F1).

A low-priority thread reads the launchers' own files every 5 seconds, but only while at least one
launcher is installed (it looks again every 5 minutes otherwise):

- **Steam.** The install folder comes from `ORBIT_STEAM_PATH`, else the registry
  (`HKCU\\Software\\Valve\\Steam\\SteamPath`, then `InstallPath` under HKLM). Libraries come from
  `steamapps/libraryfolders.vdf` (the old layout with paths as values and the new one with a `path`
  key per library) plus `ORBIT_STEAM_LIBRARIES` (an `os.pathsep` list). Each `appmanifest_<id>.acf`
  gives `StateFlags` (Valve's EAppState bits) and the `BytesToDownload/BytesDownloaded/BytesToStage/
  BytesStaged` counters. `steamapps/downloading/<id>` and `logs/content_log.txt` (only the lines
  written while Orbit runs) add hints, for example the reason a download failed.
- **Epic.** `*.item` manifests in `%PROGRAMDATA%\\Epic\\EpicGamesLauncher\\Data\\Manifests`
  (`ORBIT_EPIC_MANIFESTS`): `bIsIncompleteInstall`, or a file in `Manifests\\Pending`, means a download
  or update is running. Epic writes no byte counters, so progress is estimated from the staging folder
  and may be missing. `LauncherInstalled.dat` (`ORBIT_EPIC_LAUNCHER_INSTALLED`) shows Epic is installed.
- **GOG.** Only finished installs: a new subkey under `HKLM\\SOFTWARE\\WOW6432Node\\GOG.com\\Games`
  (`ORBIT_GOG_GAMES_KEY`).

`GET /api/downloads` (main token, HTTPS only):

    {"downloads": [{"id": "steam:620", "store": "steam", "name": "Portal 2",
                    "state": "queued|downloading|staging|paused|finished|failed", "progress": 0.42,
                    "bytesDone": 123, "bytesTotal": 456, "updatedAt": "ISO"}],
     "active": true, "stores": {"steam": true, "epic": false, "gog": false}}

`progress` and the byte counts belong to the current phase: downloading, then staging (Steam's
"installing" step). They are null when the launcher does not say.

Events: `download.finished` / `download.failed` for each item, and `downloads.allFinished` once nothing
has been queued, downloading or staging for 60 seconds after some activity. A paused download does
not count as activity. Listeners (power after downloads) hear about every change even when the user
turned download notifications off.

Steam's StateFlags meanings come from community documentation (Lutris, SteamKit) and have not all
been confirmed on a real PC, so every rule here prefers the byte counters where they exist.
"""
import ctypes
from dataclasses import dataclass, field
import json
import logging
import os
from pathlib import Path
import re
import threading
import time

from fastapi import APIRouter, Depends, HTTPException, Request, Response

import orbit_events

try:
    import winreg
except ImportError:  # Not Windows: only the environment overrides can point at launcher files.
    winreg = None

LOGGER = logging.getLogger("orbit.downloads")
POLL_SECONDS = 5.0
STORE_RECHECK_SECONDS = 300.0
ALL_FINISHED_QUIET_SECONDS = 60.0
RETAIN_FINISHED_SECONDS = 60 * 60
MAX_LISTED = 40
EPIC_PROGRESS_SECONDS = 15.0
EPIC_MAX_FILES = 20000
CONTENT_LOG_MAX_READ = 256 * 1024
LOG_FAILURE_SECONDS = 15 * 60
ACTIVE_STATES = ("queued", "downloading", "staging")
TERMINAL_STATES = ("finished", "failed")
STORES = ("steam", "epic", "gog")
STORE_NAMES = {"steam": "Steam", "epic": "Epic Games", "gog": "GOG Galaxy"}

# Valve's EAppState bits (appmanifest StateFlags).
UNINSTALLED = 1
UPDATE_REQUIRED = 2
FULLY_INSTALLED = 4
ENCRYPTED = 8
LOCKED = 16
APP_RUNNING = 64
UPDATE_RUNNING = 256
UPDATE_PAUSED = 512  # current clients write it for "update queued" as well
UPDATE_STARTED = 1024
ADDING_FILES = 262144
PREALLOCATING = 524288
DOWNLOADING = 1048576
STAGING = 2097152
COMMITTING = 4194304
STARTED_BITS = UPDATE_RUNNING | UPDATE_STARTED | ADDING_FILES | PREALLOCATING | DOWNLOADING | STAGING | COMMITTING
HARMLESS_BITS = APP_RUNNING | ENCRYPTED | LOCKED

DEFAULT_GOG_KEYS = (r"HKLM\SOFTWARE\WOW6432Node\GOG.com\Games", r"HKLM\SOFTWARE\GOG.com\Games")


# -- Valve KeyValues (VDF) ------------------------------------------------------------------------

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}


def _vdf_tokens(text):
    index, length = 0, len(text)
    while index < length:
        char = text[index]
        if char.isspace():
            index += 1
        elif char == "/" and text.startswith("//", index):
            end = text.find("\n", index)
            index = length if end < 0 else end + 1
        elif char in "{}":
            yield char, char
            index += 1
        elif char == "[":
            # Platform conditionals such as [$WIN32] after a value: not needed here.
            end = text.find("]", index)
            index = length if end < 0 else end + 1
        elif char == '"':
            index += 1
            parts = []
            while index < length and text[index] != '"':
                if text[index] == "\\" and index + 1 < length:
                    parts.append(_ESCAPES.get(text[index + 1], "\\" + text[index + 1]))
                    index += 2
                else:
                    parts.append(text[index])
                    index += 1
            index += 1
            yield "string", "".join(parts)
        else:
            start = index
            while index < length and not text[index].isspace() and text[index] not in '{}"':
                index += 1
            yield "string", text[start:index]


def parse_vdf(text):
    """Valve KeyValues text as nested dicts. Keys keep their case (use `vdf_get` to look up without
    case); a repeated key keeps its last value. Raises ValueError on unbalanced braces."""
    root = {}
    stack = [root]
    key = None
    for kind, value in _vdf_tokens(text):
        if kind == "string":
            if key is None:
                key = value
            else:
                stack[-1][key] = value
                key = None
        elif kind == "{":
            if key is None:
                raise ValueError("A '{' without a name in VDF text")
            child = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        else:
            if len(stack) == 1:
                raise ValueError("Unbalanced '}' in VDF text")
            stack.pop()
            key = None
    if len(stack) != 1:
        raise ValueError("Unclosed block in VDF text")
    return root


def vdf_get(mapping, key, default=None):
    if not isinstance(mapping, dict):
        return default
    if key in mapping:
        return mapping[key]
    folded = key.casefold()
    for name, value in mapping.items():
        if name.casefold() == folded:
            return value
    return default


def _int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def read_text(path, limit=4 * 1024 * 1024):
    with open(path, "rb") as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError(f"{path} is unexpectedly large")
    return raw.decode("utf-8-sig", errors="replace")


# -- Registry helpers ---------------------------------------------------------------------------

_HIVES = {"HKLM": "HKEY_LOCAL_MACHINE", "HKEY_LOCAL_MACHINE": "HKEY_LOCAL_MACHINE",
          "HKCU": "HKEY_CURRENT_USER", "HKEY_CURRENT_USER": "HKEY_CURRENT_USER"}


def _split_key(path):
    parts = [part for part in str(path).replace("/", "\\").split("\\") if part]
    if not parts or parts[0].upper() not in _HIVES or winreg is None:
        return None, None
    return getattr(winreg, _HIVES[parts[0].upper()], None), "\\".join(parts[1:])


def registry_value(path, name):
    hive, subkey = _split_key(path)
    if hive is None:
        return None
    try:
        with winreg.OpenKey(hive, subkey) as key:
            return winreg.QueryValueEx(key, name)[0]
    except OSError:
        return None


def registry_subkeys(path):
    """Subkey names, or None when the key does not exist."""
    hive, subkey = _split_key(path)
    if hive is None:
        return None
    try:
        with winreg.OpenKey(hive, subkey) as key:
            names = []
            index = 0
            while index < 100000:
                try:
                    names.append(winreg.EnumKey(key, index))
                except OSError:
                    break
                index += 1
            return names
    except OSError:
        return None


def registry_values(path):
    hive, subkey = _split_key(path)
    if hive is None:
        return {}
    values = {}
    try:
        with winreg.OpenKey(hive, subkey) as key:
            index = 0
            while index < 1000:
                try:
                    name, value, _ = winreg.EnumValue(key, index)
                except OSError:
                    break
                values[str(name).casefold()] = value
                index += 1
    except OSError:
        return {}
    return values


def _environment_path(name):
    value = os.environ.get(name, "").strip()
    return Path(value) if value else None


def _program_data():
    return Path(os.environ.get("PROGRAMDATA") or "C:/ProgramData")


def _normal(path):
    return os.path.normcase(os.path.normpath(str(path)))


# -- Observations ---------------------------------------------------------------------------------

@dataclass
class Observation:
    """What one poll saw for one item. `state` is one of ACTIVE_STATES, `paused`, `failed`,
    `complete` (installed and up to date) or `installed` (GOG: a new install appeared)."""
    id: str
    store: str
    name: str
    state: str
    progress: float = None
    bytes_done: int = None
    bytes_total: int = None
    size: int = None
    reason: str = None
    update: bool = False


def _phase_numbers(done, total):
    if total and total > 0:
        done = max(0, min(done, total))
        return done, total, round(done / total, 4)
    return None, None, None


# -- Steam ----------------------------------------------------------------------------------------

_LOG_LINE = re.compile(r"AppID\s+(\d+)\s+(update canceled|scheduler finished|state changed)\s*:\s*(.*)$", re.IGNORECASE)
_LOG_RESULT = re.compile(r"\(result\s+([^,)]+)", re.IGNORECASE)
_LOG_SUFFIX = re.compile(r"\(([^()]+)\)\s*$")


class SteamScanner:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._manifests = {}  # path -> (signature, fields)
        self._libraries = []
        self._libraries_signature = None
        self._root = None
        self._log_offset = None
        self._log_failures = {}  # appid -> (reason, time)

    @staticmethod
    def locate_root():
        override = _environment_path("ORBIT_STEAM_PATH")
        if override is not None:
            return override if override.is_dir() else None
        for path, name in ((r"HKCU\Software\Valve\Steam", "SteamPath"),
                           (r"HKLM\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                           (r"HKLM\SOFTWARE\Valve\Steam", "InstallPath")):
            value = registry_value(path, name)
            if isinstance(value, str) and value.strip():
                candidate = Path(value.strip())
                if candidate.is_dir():
                    return candidate
        return None

    def present(self):
        self._root = self.locate_root()
        return self._root is not None or bool(self._environment_libraries())

    @staticmethod
    def _environment_libraries():
        value = os.environ.get("ORBIT_STEAM_LIBRARIES", "")
        return [Path(part.strip()) for part in value.split(os.pathsep) if part.strip()]

    @staticmethod
    def library_paths_from_vdf(text):
        """Library folders named in libraryfolders.vdf (old and new layouts)."""
        data = parse_vdf(text)
        folders = vdf_get(data, "libraryfolders")
        if not isinstance(folders, dict):
            return []
        paths = []
        for key, value in folders.items():
            if not str(key).isdigit():
                continue
            path = value if isinstance(value, str) else vdf_get(value, "path")
            if isinstance(path, str) and path.strip():
                paths.append(Path(path.strip()))
        return paths

    def libraries(self):
        root = self._root
        candidates = [root] if root is not None else []
        vdf_files = [root / "steamapps" / "libraryfolders.vdf", root / "config" / "libraryfolders.vdf"] if root else []
        signature = []
        for vdf_file in vdf_files:
            try:
                info = vdf_file.stat()
            except OSError:
                continue
            signature.append((str(vdf_file), info.st_mtime_ns, info.st_size))
        signature.append(os.environ.get("ORBIT_STEAM_LIBRARIES", ""))
        signature.append(str(root))
        if signature == self._libraries_signature:
            return self._libraries
        for vdf_file in vdf_files:
            try:
                candidates.extend(self.library_paths_from_vdf(read_text(vdf_file)))
            except (OSError, ValueError):
                continue
        candidates.extend(self._environment_libraries())
        unique, seen = [], set()
        for candidate in candidates:
            key = _normal(candidate)
            if key in seen:
                continue
            seen.add(key)
            if (candidate / "steamapps").is_dir():
                unique.append(candidate)
        self._libraries, self._libraries_signature = unique, signature
        return unique

    def _manifest(self, path):
        try:
            info = path.stat()
        except OSError:
            return None
        signature = (info.st_mtime_ns, info.st_size)
        cached = self._manifests.get(str(path))
        if cached and cached[0] == signature:
            return cached[1]
        try:
            state = vdf_get(parse_vdf(read_text(path, 1024 * 1024)), "AppState")
        except (OSError, ValueError):
            # Steam replaces manifests while writing; the next poll reads the finished file.
            return cached[1] if cached else None
        if not isinstance(state, dict):
            return None
        fields = {
            "appid": str(vdf_get(state, "appid", "") or ""),
            "name": str(vdf_get(state, "name", "") or "").strip(),
            "flags": _int(vdf_get(state, "StateFlags")),
            "toDownload": max(0, _int(vdf_get(state, "BytesToDownload"))),
            "downloaded": max(0, _int(vdf_get(state, "BytesDownloaded"))),
            "toStage": max(0, _int(vdf_get(state, "BytesToStage"))),
            "staged": max(0, _int(vdf_get(state, "BytesStaged"))),
            "updateResult": _int(vdf_get(state, "UpdateResult")),
            "buildid": str(vdf_get(state, "buildid", "") or "").strip(),
            "targetBuild": str(vdf_get(state, "TargetBuildID", "") or "").strip(),
        }
        self._manifests[str(path)] = (signature, fields)
        return fields

    def _read_content_log(self):
        """New `content_log.txt` lines since the last poll; the first poll only notes the size."""
        if self._root is None:
            return
        path = self._root / "logs" / "content_log.txt"
        try:
            size = path.stat().st_size
        except OSError:
            if self._log_offset is None:
                self._log_offset = 0  # a log that appears later is read from its first line
            return
        if self._log_offset is None:
            # First look: only lines written from now on matter, not the log's history.
            self._log_offset = size
            return
        if size < self._log_offset:
            self._log_offset = 0  # rotated
        if size == self._log_offset:
            return
        start = max(self._log_offset, size - CONTENT_LOG_MAX_READ)
        try:
            with open(path, "rb") as stream:
                stream.seek(start)
                chunk = stream.read(size - start)
        except OSError:
            return
        complete = chunk.rfind(b"\n")
        if complete < 0:
            return
        self._log_offset = start + complete + 1
        now = self._clock()
        for line in chunk[:complete].decode("utf-8", errors="replace").splitlines():
            self.note_log_line(line, now)

    def note_log_line(self, line, now=None):
        match = _LOG_LINE.search(line)
        if not match:
            return
        appid, what, rest = match.group(1), match.group(2).lower(), match.group(3).strip()
        now = self._clock() if now is None else now
        reason = None
        if what == "update canceled":
            suffix = _LOG_SUFFIX.search(rest)
            reason = (suffix.group(1) if suffix else rest.split(":")[0]).strip() or "Steam canceled the update"
        elif what == "scheduler finished":
            result = _LOG_RESULT.search(rest)
            if result and result.group(1).strip().casefold() != "no error":
                reason = result.group(1).strip()
        else:
            if "fully installed" in rest.casefold():
                self._log_failures.pop(appid, None)
                return
            suffix = _LOG_SUFFIX.search(rest)
            if suffix and suffix.group(1).strip().casefold() not in ("", "no error"):
                reason = suffix.group(1).strip()
        if reason:
            self._log_failures[appid] = (reason, now)

    def _log_failure(self, appid):
        entry = self._log_failures.get(appid)
        if entry and self._clock() - entry[1] <= LOG_FAILURE_SECONDS:
            return entry[0]
        return None

    def scan(self, tracked):
        """Observations for every manifest that is not plainly installed (plus tracked ones)."""
        self._read_content_log()
        raw = []
        seen_paths = set()
        for library in self.libraries():
            steamapps = library / "steamapps"
            try:
                manifests = list(steamapps.glob("appmanifest_*.acf"))
            except OSError:
                continue
            for path in manifests:
                seen_paths.add(str(path))
                fields = self._manifest(path)
                if not fields:
                    continue
                appid = fields["appid"] or path.stem.split("_", 1)[-1]
                fields = dict(fields, appid=appid)
                flags = fields["flags"]
                ident = f"steam:{appid}"
                if self._complete(fields) and ident not in tracked:
                    continue
                fields["downloadingFolder"] = (steamapps / "downloading" / appid).is_dir()
                raw.append(fields)
        for stale in set(self._manifests) - seen_paths:
            self._manifests.pop(stale, None)
        observations = [self._classify(fields, tracked.get(f"steam:{fields['appid']}")) for fields in raw]
        observations = [item for item in observations if item is not None]
        progressing = any(item.state in ("downloading", "staging") for item in observations)
        for item in observations:
            if item.state == "held":
                item.state = "queued" if progressing else "paused"
        return observations

    @staticmethod
    def _complete(fields):
        flags = fields["flags"]
        if flags & ~HARMLESS_BITS != FULLY_INSTALLED:
            return False
        if fields["targetBuild"] not in ("", "0") and fields["buildid"] and fields["targetBuild"] != fields["buildid"]:
            return False
        return fields["toDownload"] == 0 or fields["downloaded"] >= fields["toDownload"]

    def _classify(self, fields, previous):
        appid = fields["appid"]
        flags = fields["flags"]
        ident = f"steam:{appid}"
        name = fields["name"] or (previous.name if previous else f"Steam app {appid}")
        update = bool(flags & FULLY_INSTALLED) or bool(previous and previous.update)
        size = fields["toDownload"] or (previous.size if previous else None)
        if self._complete(fields):
            return Observation(ident, "steam", name, "complete", 1.0, size, size, size=size, update=update)
        downloading_left = fields["toDownload"] > 0 and fields["downloaded"] < fields["toDownload"]
        staging_left = fields["toStage"] > 0 and fields["staged"] < fields["toStage"]
        if downloading_left or not staging_left:
            done, total, progress = _phase_numbers(fields["downloaded"], fields["toDownload"])
        else:
            done, total, progress = _phase_numbers(fields["staged"], fields["toStage"])
        started = bool(flags & STARTED_BITS)
        held = bool(flags & UPDATE_PAUSED)
        if flags & UNINSTALLED and not started and not held:
            return None  # the install was canceled
        failure = None
        if fields["updateResult"]:
            failure = self._log_failure(appid) or f"Steam reported error {fields['updateResult']}"
        if held or not started:
            log_failure = self._log_failure(appid)
            if failure or log_failure:
                state = "failed"
                failure = failure or log_failure
            elif held:
                state = "held"  # queued behind another download, or paused: decided by the caller
            elif previous is not None or (fields["downloadingFolder"] and (fields["downloaded"] or fields["staged"])):
                state = "held"  # started earlier (partial bytes on disk), now waiting
            else:
                return None  # an update Steam has not started (scheduled or waiting for a launch)
        elif not downloading_left and (staging_left or flags & (STAGING | COMMITTING)):
            state = "staging"
        elif fields["downloaded"] == 0 and fields["staged"] == 0 and not flags & DOWNLOADING:
            state = "queued"
        else:
            state = "downloading"
        if state != "failed":
            failure = None
        if state in ("downloading", "staging"):
            self._log_failures.pop(appid, None)  # a retry is running; an old failure no longer applies
        return Observation(ident, "steam", name, state, progress, done, total, size=size, reason=failure, update=update)


# -- Epic -----------------------------------------------------------------------------------------

class EpicScanner:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._items = {}  # path -> (signature, item)
        self._progress = {}  # id -> (time, bytes)

    @staticmethod
    def manifests_folder():
        return _environment_path("ORBIT_EPIC_MANIFESTS") or (_program_data() / "Epic" / "EpicGamesLauncher" / "Data" / "Manifests")

    @staticmethod
    def launcher_installed_file():
        return _environment_path("ORBIT_EPIC_LAUNCHER_INSTALLED") or (_program_data() / "Epic" / "UnrealEngineLauncher" / "LauncherInstalled.dat")

    def present(self):
        return self.manifests_folder().is_dir() or self.launcher_installed_file().is_file()

    def _item(self, path):
        try:
            info = path.stat()
        except OSError:
            return None
        signature = (info.st_mtime_ns, info.st_size)
        cached = self._items.get(str(path))
        if cached and cached[0] == signature:
            return cached[1]
        try:
            item = json.loads(read_text(path, 2 * 1024 * 1024))
        except (OSError, ValueError):
            return cached[1] if cached else None
        if not isinstance(item, dict):
            return None
        self._items[str(path)] = (signature, item)
        return item

    def _staged_bytes(self, ident, folder):
        """Bytes in the staging folder, measured at most every 15 s (bounded walk)."""
        now = self._clock()
        cached = self._progress.get(ident)
        if cached and now - cached[0] < EPIC_PROGRESS_SECONDS:
            return cached[1]
        total, files = 0, 0
        for directory, _, names in os.walk(folder):
            for name in names:
                try:
                    total += os.stat(os.path.join(directory, name)).st_size
                except OSError:
                    continue
            files += len(names)
            if files > EPIC_MAX_FILES:
                break  # a partial sum is still a useful estimate; never walk a huge tree every poll
        value = total if total else None
        self._progress[ident] = (now, value)
        return value

    def scan(self, tracked):
        folder = self.manifests_folder()
        pending_folder = folder / "Pending"
        pending = {}
        try:
            for path in pending_folder.glob("*.item"):
                item = self._item(path) or {}
                pending[path.stem.casefold()] = item
                if item.get("AppName"):
                    pending[f"app:{str(item['AppName']).casefold()}"] = item
        except OSError:
            pass
        observations, seen = [], set()
        try:
            paths = list(folder.glob("*.item"))
        except OSError:
            paths = []
        for path in paths:
            item = self._item(path)
            if not item or not item.get("AppName"):
                continue
            app = str(item["AppName"])
            seen.add(path.stem.casefold())
            seen.add(f"app:{app.casefold()}")
            waiting = path.stem.casefold() in pending or f"app:{app.casefold()}" in pending
            observation = self._observe(item, bool(item.get("bIsIncompleteInstall")) or waiting, tracked)
            if observation is not None:
                observations.append(observation)
        for key, item in pending.items():
            if key in seen or not key.startswith("app:") or not item.get("AppName"):
                continue
            observation = self._observe(item, True, tracked)
            if observation is not None:
                observations.append(observation)
        for stale in [key for key in self._items if not Path(key).exists()]:
            self._items.pop(stale, None)
        return observations

    def _observe(self, item, incomplete, tracked):
        app = str(item["AppName"])
        ident = f"epic:{app}"
        name = str(item.get("DisplayName") or app).strip() or app
        size = _int(item.get("InstallSize"), 0) or None
        previous = tracked.get(ident)
        if not incomplete:
            if previous is None:
                return None
            return Observation(ident, "epic", name, "complete", 1.0, size, size, size=size, update=previous.update)
        staging = item.get("StagingLocation") or (Path(str(item.get("InstallLocation") or "")) / ".egstore" / "bps")
        done = self._staged_bytes(ident, staging) if staging else None
        progress = None
        if done is not None and size:
            done = min(done, size)
            progress = round(min(0.99, done / size), 4)
        update = bool(previous.update) if previous else not bool(item.get("bIsIncompleteInstall"))
        return Observation(ident, "epic", name, "downloading", progress, done if size else None, size, size=size, update=update)


# -- GOG ------------------------------------------------------------------------------------------

class GogScanner:
    def __init__(self):
        self._known = None
        self._key = None

    @staticmethod
    def keys():
        override = os.environ.get("ORBIT_GOG_GAMES_KEY", "").strip()
        return (override,) if override else DEFAULT_GOG_KEYS

    def present(self):
        for key in self.keys():
            if registry_subkeys(key) is not None:
                self._key = key
                return True
        self._key = None
        return False

    def scan(self, tracked):
        if self._key is None:
            return []
        names = registry_subkeys(self._key)
        if names is None:
            return []
        current = set(names)
        if self._known is None:
            self._known = current
            return []
        new = sorted(current - self._known)
        self._known = current
        observations = []
        for game_id in new:
            values = registry_values(f"{self._key}\\{game_id}")
            name = str(values.get("gamename") or values.get("game_name") or f"GOG game {game_id}").strip()
            observations.append(Observation(f"gog:{game_id}", "gog", name, "installed", 1.0))
        return observations


# -- Tracking and events --------------------------------------------------------------------------

@dataclass
class Item:
    id: str
    store: str
    name: str
    state: str
    progress: float = None
    bytes_done: int = None
    bytes_total: int = None
    size: int = None
    reason: str = None
    update: bool = False
    updated_at: float = 0.0  # wall clock, for the API
    ended_at: float = None  # monotonic, for retention
    extra: dict = field(default_factory=dict)

    def payload(self):
        return {"id": self.id, "store": self.store, "name": self.name, "state": self.state,
                "progress": self.progress, "bytesDone": self.bytes_done, "bytesTotal": self.bytes_total,
                "updatedAt": orbit_events.iso_timestamp(self.updated_at)}


def _size_text(size):
    if not size:
        return ""
    if size >= 1_000_000_000:
        return f"{size / 1_000_000_000:.1f} GB"
    return f"{max(1, round(size / 1_000_000))} MB"


def _names_text(names):
    names = list(names)
    if len(names) <= 2:
        return " and ".join(names)
    return f"{names[0]}, {names[1]} and {len(names) - 2} other{'s' if len(names) > 3 else ''}"


class DownloadTracker:
    """Keeps the list the API shows and decides which events to send. Not thread-safe on its own;
    the watcher calls it under its lock."""

    def __init__(self, *, clock=time.time, monotonic=time.monotonic, emit=None, notify_enabled=None):
        self._clock = clock
        self._monotonic = monotonic
        self._emit = emit
        self._notify_enabled = notify_enabled or (lambda: True)
        self.items = {}
        self.started = monotonic()
        self.last_active = None
        self.polled = False
        self._window = {"finished": [], "failed": []}
        self._had_activity = False

    def active(self):
        return any(item.state in ACTIVE_STATES for item in self.items.values())

    def apply(self, observations, scanned_stores):
        """Applies one poll. `scanned_stores` are the stores whose observations are complete, so a
        tracked item of such a store that was not observed has gone (canceled or uninstalled)."""
        now_wall, now = self._clock(), self._monotonic()
        events = []
        seen = set()
        for observation in observations:
            seen.add(observation.id)
            item = self.items.get(observation.id)
            if observation.state in ("complete", "installed"):
                if observation.state == "installed" and item is None:
                    item = Item(observation.id, observation.store, observation.name, "queued", updated_at=now_wall)
                    self.items[item.id] = item
                if item is None or item.state == "finished":
                    continue
                item.name = observation.name or item.name
                item.size = observation.size or item.size or item.bytes_total
                item.state, item.progress = "finished", 1.0
                item.bytes_total = item.size or item.bytes_total
                item.bytes_done = item.bytes_total
                item.reason, item.updated_at, item.ended_at = None, now_wall, now
                events.append(("finished", item))
                continue
            if item is None:
                item = Item(observation.id, observation.store, observation.name, observation.state,
                            observation.progress, observation.bytes_done, observation.bytes_total,
                            observation.size, observation.reason, observation.update, now_wall)
                self.items[item.id] = item
                if item.state in ACTIVE_STATES:
                    self._had_activity = True
                continue
            changed = (item.state, item.progress, item.bytes_done, item.bytes_total) != (
                observation.state, observation.progress, observation.bytes_done, observation.bytes_total)
            previous_state = item.state
            item.name = observation.name or item.name
            item.state = observation.state
            item.progress, item.bytes_done, item.bytes_total = observation.progress, observation.bytes_done, observation.bytes_total
            item.size = observation.size or item.size
            item.update = item.update or observation.update
            item.reason = observation.reason
            if changed:
                item.updated_at = now_wall
            if item.state in TERMINAL_STATES:
                item.ended_at = item.ended_at if previous_state == item.state else now
            else:
                item.ended_at = None
            if item.state == "failed" and previous_state != "failed":
                events.append(("failed", item))
        for ident, item in list(self.items.items()):
            if ident in seen:
                continue
            if item.state in TERMINAL_STATES:
                continue
            if item.store in scanned_stores:
                # Canceled or uninstalled while unfinished: drop it quietly.
                del self.items[ident]
        if self.active():
            self._had_activity = True
            self.last_active = now
        self._prune(now)
        self.polled = True
        for kind, item in events:
            self._window["finished" if kind == "finished" else "failed"].append(item.name)
            self._send_item_event(kind, item)
        all_done = None
        if not self.active() and self._had_activity:
            quiet_since = self.last_active if self.last_active is not None else self.started
            if now - quiet_since >= ALL_FINISHED_QUIET_SECONDS:
                all_done = self._send_all_finished()
        return events, all_done

    def _prune(self, now):
        for ident, item in list(self.items.items()):
            if item.state in TERMINAL_STATES and item.ended_at is not None and now - item.ended_at > RETAIN_FINISHED_SECONDS:
                del self.items[ident]
        if len(self.items) > MAX_LISTED:
            ended = sorted((item for item in self.items.values() if item.state in TERMINAL_STATES),
                           key=lambda item: item.ended_at or 0)
            for item in ended[:len(self.items) - MAX_LISTED]:
                del self.items[item.id]

    def _emit_event(self, *args, **kwargs):
        if not self._notify_enabled():
            return None
        try:
            return (self._emit or orbit_events.emit)(*args, **kwargs)
        except Exception:
            LOGGER.exception("Could not record a downloads event")
            return None

    def _send_item_event(self, kind, item):
        store = STORE_NAMES.get(item.store, item.store)
        data = {"id": item.id, "store": item.store, "name": item.name}
        if kind == "finished":
            if item.store == "gog":
                title, body = f"{item.name} is installed", "GOG Galaxy finished installing it."
            else:
                verb = "updating" if item.update else "downloading"
                size = _size_text(item.size or item.bytes_total)
                title = f"{item.name} finished {verb}"
                body = f"{store} is done{f' ({size})' if size else ''}. It's ready to play."
            if item.size or item.bytes_total:
                data["bytesTotal"] = item.size or item.bytes_total
            return self._emit_event("download.finished", title, body, level="active", data=data)
        reason = (item.reason or "").strip()
        body = f"{store} stopped the download: {reason}." if reason else f"{store} stopped the download. Open {store} on the PC to see why."
        if reason:
            data["reason"] = reason[:200]
        return self._emit_event("download.failed", f"{item.name} download failed", body.replace("..", "."), level="active", data=data)

    def _send_all_finished(self):
        finished, failed = self._window["finished"], self._window["failed"]
        paused = [item.name for item in self.items.values() if item.state == "paused"]
        self._window = {"finished": [], "failed": []}
        self._had_activity = False
        if not failed and not paused:
            title = "All downloads finished"
            if finished:
                body = f"{_names_text(finished)} {'is' if len(finished) == 1 else 'are'} ready to play."
            else:
                body = "Nothing is downloading on your PC any more."
        else:
            title = "Downloads stopped"
            parts = []
            if finished:
                parts.append(f"{_names_text(finished)} finished.")
            if failed:
                parts.append(f"{_names_text(failed)} failed.")
            if paused:
                parts.append(f"{len(paused)} download{' is' if len(paused) == 1 else 's are'} paused.")
            body = " ".join(parts)
        data = {"finished": len(finished), "failed": len(failed), "paused": len(paused)}
        # One download already got its own toast on the PC; the phone still gets both.
        toast = len(finished) + len(failed) > 1 or bool(paused)
        event = self._emit_event("downloads.allFinished", title, body, level="active", data=data, toast=toast)
        return {"title": title, "body": body, "data": data, "event": event}

    def payload(self, stores):
        def order(item):
            rank = 0 if item.state in ACTIVE_STATES else 1 if item.state == "paused" else 2
            return rank, -item.updated_at, item.name.casefold()
        return {"downloads": [item.payload() for item in sorted(self.items.values(), key=order)],
                "active": self.active(), "stores": {store: bool(stores.get(store)) for store in STORES}}


def _lower_thread_priority():
    if os.name != "nt":
        return
    try:
        kernel32 = ctypes.windll.kernel32
        kernel32.SetThreadPriority(kernel32.GetCurrentThread(), -2)  # THREAD_PRIORITY_LOWEST
    except Exception:
        LOGGER.debug("Could not lower the downloads thread priority", exc_info=True)


class DownloadsWatcher:
    """Runs the scanners on a background thread and answers the API and power-after rules."""

    def __init__(self, *, clock=time.time, monotonic=time.monotonic, emit=None, notify_enabled=None,
                 scanners=None, poll_seconds=POLL_SECONDS):
        self._monotonic = monotonic
        self._lock = threading.RLock()
        self._poll_seconds = poll_seconds
        self.scanners = scanners or {"steam": SteamScanner(monotonic), "epic": EpicScanner(monotonic), "gog": GogScanner()}
        self.tracker = DownloadTracker(clock=clock, monotonic=monotonic, emit=emit, notify_enabled=notify_enabled)
        self.stores = {store: False for store in STORES}
        self._detected_at = None
        self._listeners = []
        self._thread = None

    def add_listener(self, listener):
        """`listener(events, all_finished)` after every poll that changed something."""
        with self._lock:
            self._listeners.append(listener)

    def detect_stores(self):
        stores = {}
        for store, scanner in self.scanners.items():
            try:
                stores[store] = bool(scanner.present())
            except Exception:
                LOGGER.warning("Could not check for %s", STORE_NAMES.get(store, store), exc_info=True)
                stores[store] = False
        with self._lock:
            self.stores = {store: stores.get(store, False) for store in STORES}
            self._detected_at = self._monotonic()
            return dict(self.stores)

    def any_store(self):
        with self._lock:
            return any(self.stores.values())

    def poll(self):
        """One pass over every installed launcher."""
        with self._lock:
            if self._detected_at is None or (not any(self.stores.values())
                                             and self._monotonic() - self._detected_at >= STORE_RECHECK_SECONDS):
                self.detect_stores()
            if not any(self.stores.values()):
                self.tracker.polled = True
                return [], None
            observations, scanned = [], set()
            tracked = dict(self.tracker.items)
            for store, scanner in self.scanners.items():
                if not self.stores.get(store):
                    continue
                try:
                    observations.extend(scanner.scan(tracked))
                    scanned.add(store)
                except Exception:
                    LOGGER.exception("Could not read %s downloads", STORE_NAMES.get(store, store))
            events, all_done = self.tracker.apply(observations, scanned)
            listeners = list(self._listeners)
        if events or all_done:
            for listener in listeners:
                try:
                    listener(events, all_done)
                except Exception:
                    LOGGER.exception("A downloads listener failed")
        return events, all_done

    def payload(self):
        with self._lock:
            return self.tracker.payload(self.stores)

    def quiet_since(self):
        """Monotonic time since when nothing has been downloading, or None while something is
        active or before the first poll."""
        with self._lock:
            if not self.tracker.polled or self.tracker.active():
                return None
            return self.tracker.last_active if self.tracker.last_active is not None else self.tracker.started

    def run(self, stop_event):
        _lower_thread_priority()
        while not stop_event.is_set():
            try:
                self.poll()
            except Exception:
                LOGGER.exception("The downloads check failed")
            with self._lock:
                idle = not any(self.stores.values())
            # Without a launcher the poll above only re-checks for one every few minutes.
            stop_event.wait(self._poll_seconds if not idle else min(self._poll_seconds * 6, STORE_RECHECK_SECONDS))

    def start(self, stop_event):
        self._thread = threading.Thread(target=self.run, args=(stop_event,), name="orbit-downloads", daemon=True)
        self._thread.start()
        return self._thread


_WATCHER = None
_WATCHER_LOCK = threading.Lock()


def shared_watcher():
    """The agent's watcher (created on first use, started by the agent's lifespan)."""
    global _WATCHER
    with _WATCHER_LOCK:
        if _WATCHER is None:
            import orbit_alerts
            _WATCHER = DownloadsWatcher(notify_enabled=lambda: orbit_alerts.kind_enabled("downloads"))
        return _WATCHER


def set_shared_watcher(watcher):
    global _WATCHER
    with _WATCHER_LOCK:
        _WATCHER = watcher


def create_downloads_router(verify_control, watcher_provider=shared_watcher):
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Downloads need Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    @router.get("/downloads")
    def list_downloads():
        watcher = watcher_provider()
        if watcher is None:
            raise HTTPException(503, "Download tracking is starting. Try again in a moment.")
        return watcher.payload()

    return router
