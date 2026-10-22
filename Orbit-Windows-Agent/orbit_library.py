"""The PC's game library: Steam, Epic Games and GOG, read from their local files.

- Steam: steamapps/libraryfolders.vdf lists the libraries, each appmanifest_<id>.acf
  one installed app. Covers come from appcache/librarycache, in the old flat layout
  (<id>_library_600x900.jpg) and the 2024 per-app folders (<id>/…/library_600x900.jpg);
  without a local cover the app ID lets the apps load Steam's public artwork.
- Epic: one JSON .item manifest per install in ProgramData; portrait artwork URLs come
  from the launcher's catalog cache when it has them.
- GOG: one registry key per game under HKLM\\SOFTWARE\\WOW6432Node\\GOG.com\\Games.

Listings never contain paths. Covers have opaque IDs (an HMAC of the file path under a
per-run key, like orbit_icons), executables become icon IDs from orbit_icons.
"""
from base64 import b64decode
from collections import OrderedDict
import hashlib
import hmac
import json
import ntpath
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time
from datetime import datetime, timezone

GAME_ID = re.compile(r"^(steam|epic|gog):[A-Za-z0-9._-]{1,128}$")
COVER_ID = re.compile(r"^[0-9a-f]{32}$")
MAX_VDF_BYTES = 32 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_CATALOG_BYTES = 128 * 1024 * 1024
MAX_COVER_BYTES = 8 * 1024 * 1024
MAX_SCAN_ENTRIES = 3000
SCAN_TTL_SECONDS = 10 * 60
STEAM_TOOLS = frozenset({"228980", "1070560", "1391110", "1628350", "1826330", "2805730"})
STEAM_TOOL_PREFIXES = ("proton ", "steam linux runtime", "steamworks common", "steamvr beta")
STEAM_CDN = "https://shared.steamstatic.com/store_item_assets/steam/apps/{appid}/library_600x900.jpg"
HELPER_WORDS = ("unins", "crash", "setup", "redist", "vcredist", "vc_redist", "dxsetup", "directx", "ue4prereq",
                "ueprereq", "prereq", "easyanticheat", "eac_", "battleye", "beservice", "cefprocess", "helper",
                "report", "updater", "launcherpatcher", "dotnet", "physx", "touchup", "cleanup", "benchmark")
EPIC_URI = "com.epicgames.launcher://apps/{namespace}%3A{item}%3A{app}?action=launch&silent=true"


# MARK: - Valve KeyValues (VDF/ACF text format)

class _CaseInsensitive(dict):
    """Steam writes the same key as "LastPlayed" or "lastplayed" depending on the file."""

    def get(self, key, default=None):
        if key in self:
            return self[key]
        folded = str(key).casefold()
        for name, value in self.items():
            if str(name).casefold() == folded:
                return value
        return default


def parse_vdf(text):
    """Parse Valve's text KeyValues into nested dicts. Unknown syntax ends the parse
    at that point instead of raising, so one odd file never hides a whole library."""
    tokens = _vdf_tokens(text)
    root = _CaseInsensitive()
    stack = [root]
    pending = None
    for token, quoted in tokens:
        if not quoted and token == "{":
            if pending is None:
                break
            child = _CaseInsensitive()
            stack[-1][pending] = child
            stack.append(child)
            pending = None
        elif not quoted and token == "}":
            if len(stack) == 1:
                break
            stack.pop()
            pending = None
        elif pending is None:
            pending = token
        else:
            stack[-1][pending] = token
            pending = None
    return root


def _vdf_tokens(text):
    index, length = 0, len(text)
    escapes = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}
    while index < length:
        character = text[index]
        if character.isspace():
            index += 1
        elif text.startswith("//", index):
            newline = text.find("\n", index)
            index = length if newline < 0 else newline + 1
        elif character in "{}":
            yield character, False
            index += 1
        elif character == '"':
            index += 1
            value = []
            while index < length and text[index] != '"':
                if text[index] == "\\" and index + 1 < length:
                    value.append(escapes.get(text[index + 1], text[index + 1]))
                    index += 2
                else:
                    value.append(text[index])
                    index += 1
            index += 1
            yield "".join(value), True
        elif character == "[":  # Conditionals such as [$WIN32] are ignored.
            close = text.find("]", index)
            index = length if close < 0 else close + 1
        else:
            start = index
            while index < length and not text[index].isspace() and text[index] not in '{}"':
                index += 1
            yield text[start:index], True


def read_vdf(path, limit=MAX_VDF_BYTES):
    try:
        if os.path.getsize(path) > limit:
            return _CaseInsensitive()
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return parse_vdf(handle.read())
    except OSError:
        return _CaseInsensitive()


# MARK: - Helpers

def _int(value):
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return number if number >= 0 else None


def _iso(timestamp):
    if not timestamp:
        return None
    try:
        return datetime.fromtimestamp(int(timestamp), timezone.utc).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError):
        return None


def normalized_title(text):
    """"DOOM Eternal™" and "Doom Eternal" match."""
    return re.sub(r"[^0-9a-z]+", "", str(text or "").casefold().replace("™", "").replace("®", ""))


def _norm_path(value):
    return str(value or "").replace("\\", "/").rstrip("/").casefold()


def is_helper_executable(name):
    stem = name.casefold()
    return any(word in stem for word in HELPER_WORDS)


def main_executable(folder, title, max_depth=3):
    """Best guess at a game's own executable: shallow, not an installer or crash
    reporter, preferring a name like the title. None when nothing plausible exists."""
    folder = Path(folder)
    if not folder.is_dir():
        return None
    wanted = normalized_title(title)
    candidates = []
    seen = 0
    queue = [(folder, 0)]
    while queue and seen < MAX_SCAN_ENTRIES:
        current, depth = queue.pop(0)
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    seen += 1
                    if seen > MAX_SCAN_ENTRIES:
                        break
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            if depth < max_depth and not entry.name.startswith((".", "_")):
                                queue.append((Path(entry.path), depth + 1))
                        elif entry.name.casefold().endswith(".exe") and not is_helper_executable(entry.name):
                            size = entry.stat(follow_symlinks=False).st_size
                            stem = normalized_title(entry.name[:-4])
                            score = (bool(wanted) and (stem == wanted or (len(stem) > 2 and (stem in wanted or wanted in stem))),
                                     -depth, size)
                            candidates.append((score, entry.path))
                    except OSError:
                        continue
        except OSError:
            continue
    return max(candidates)[1] if candidates else None


def sunshine_match(game, entries):
    """The Sunshine app (by name) that starts this game, or None."""
    appid = game.get("steamAppID")
    install = _norm_path(game.get("installDir"))
    exe = _norm_path(game.get("exe"))
    epic = (game.get("epicAppName") or "").casefold()
    title = normalized_title(game.get("title"))
    for entry in entries:
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            continue
        commands = [entry.get("cmd")] + list(entry.get("detached") or [])
        text = " ".join(str(command) for command in commands if command).casefold().replace("\\", "/")
        if appid and re.search(rf"rungameid/{re.escape(str(appid))}(?!\d)", text):
            return name
        if epic and f"%3a{epic}" in text:
            return name
        if (exe and exe in text) or (install and install in text):
            return name
        if title and normalized_title(name) == title:
            return name
    return None


# MARK: - Opaque cover IDs

class CoverRegistry:
    """Maps cover IDs this agent listed to image files; never accepts a path."""

    def __init__(self, key=None, limit=4096):
        self._key = key or secrets.token_bytes(32)
        self._paths = OrderedDict()
        self._lock = threading.Lock()
        self._limit = limit

    def register(self, path):
        if not path:
            return None
        identity = hmac.new(self._key, str(path).casefold().encode("utf-8", "surrogatepass"), hashlib.sha256).hexdigest()[:32]
        with self._lock:
            self._paths[identity] = str(path)
            self._paths.move_to_end(identity)
            while len(self._paths) > self._limit:
                self._paths.popitem(last=False)
        return identity

    def read(self, identity):
        """(bytes, media type). KeyError for unknown IDs, OSError when the file is gone."""
        if not COVER_ID.fullmatch(str(identity or "")):
            raise KeyError(identity)
        with self._lock:
            path = self._paths.get(identity)
        if path is None:
            raise KeyError(identity)
        if os.path.getsize(path) > MAX_COVER_BYTES:
            raise OSError("Cover image is too large.")
        with open(path, "rb") as handle:
            data = handle.read(MAX_COVER_BYTES + 1)
        if data.startswith(b"\xff\xd8\xff"):
            return data, "image/jpeg"
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            return data, "image/png"
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            return data, "image/webp"
        raise OSError("Not an image.")


# MARK: - Stores

class StoreScan:
    def __init__(self, store, available, games=None):
        self.store, self.available, self.games = store, available, games or []


def _registry_value(registry, root, path, name):
    if registry is None:
        return None
    try:
        with registry.OpenKey(root, path) as key:
            return registry.QueryValueEx(key, name)[0]
    except OSError:
        return None


def steam_root(registry=None, environ=os.environ):
    if registry is None and os.name == "nt":
        import winreg as registry
    candidates = []
    if registry is not None:
        candidates.append(_registry_value(registry, registry.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"))
        candidates.append(_registry_value(registry, registry.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"))
        candidates.append(_registry_value(registry, registry.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"))
    program_files = environ.get("PROGRAMFILES(X86)") or environ.get("ProgramFiles(x86)") or r"C:\Program Files (x86)"
    candidates.append(ntpath.join(program_files, "Steam"))
    for candidate in candidates:
        if isinstance(candidate, str) and candidate and Path(candidate).is_dir():
            return Path(candidate)
    return None


class SteamSource:
    store = "steam"

    def __init__(self, root=None, root_finder=steam_root):
        self._root = root
        self._root_finder = root_finder

    def _libraries(self, root):
        folders = [root]
        data = read_vdf(root / "steamapps" / "libraryfolders.vdf")
        section = data.get("libraryfolders") or data.get("LibraryFolders") or {}
        for key, value in section.items():
            if not str(key).isdigit():
                continue
            path = value.get("path") if isinstance(value, dict) else value
            if isinstance(path, str) and path:
                folder = Path(path)
                if all(_norm_path(folder) != _norm_path(known) for known in folders):
                    folders.append(folder)
        return folders

    def _last_played(self, root):
        """LastPlayed per app from the most recently used account's localconfig.vdf."""
        newest, found = 0, None
        try:
            with os.scandir(root / "userdata") as users:
                for user in users:
                    config = Path(user.path) / "config" / "localconfig.vdf"
                    try:
                        modified = config.stat().st_mtime
                    except OSError:
                        continue
                    if modified > newest:
                        newest, found = modified, config
        except OSError:
            return {}
        if found is None:
            return {}
        node = read_vdf(found)
        for key in ("UserLocalConfigStore", "Software", "Valve", "Steam", "apps"):
            node = node.get(key) if isinstance(node, dict) else None
        if not isinstance(node, dict):
            return {}
        return {str(appid): _int(values.get("LastPlayed")) for appid, values in node.items() if isinstance(values, dict)}

    @staticmethod
    def covers(root, appid):
        """(portrait cover path or None). Handles the old flat and the 2024 per-app layouts."""
        cache = root / "appcache" / "librarycache"
        for name in (f"{appid}_library_600x900.jpg", f"{appid}_library_600x900_2x.jpg"):
            if (cache / name).is_file():
                return cache / name
        folder = cache / str(appid)
        if folder.is_dir():
            found = []
            try:
                for current, directories, files in os.walk(folder):
                    depth = len(Path(current).relative_to(folder).parts)
                    if depth >= 2:
                        directories[:] = []
                    for name in files:
                        lowered = name.casefold()
                        if lowered in ("library_600x900.jpg", "library_600x900_2x.jpg", "library_capsule.jpg"):
                            rank = {"library_600x900.jpg": 0, "library_600x900_2x.jpg": 1, "library_capsule.jpg": 2}[lowered]
                            found.append((rank, depth, os.path.join(current, name)))
            except OSError:
                return None
            if found:
                return Path(min(found)[2])
        return None

    def scan(self):
        root = self._root or self._root_finder()
        if root is None or not Path(root).is_dir():
            return StoreScan(self.store, False)
        root = Path(root)
        last_played = self._last_played(root)
        games = []
        for library in self._libraries(root):
            steamapps = library / "steamapps"
            try:
                manifests = sorted(steamapps.glob("appmanifest_*.acf"))
            except OSError:
                continue
            for manifest in manifests:
                state = read_vdf(manifest, MAX_MANIFEST_BYTES).get("AppState")
                if not isinstance(state, dict):
                    continue
                appid = str(state.get("appid") or "").strip()
                name = str(state.get("name") or "").strip()
                if not appid.isdigit() or not name or appid in STEAM_TOOLS or name.casefold().startswith(STEAM_TOOL_PREFIXES):
                    continue
                flags = _int(state.get("StateFlags")) or 0
                installdir = str(state.get("installdir") or "").strip()
                folder = steamapps / "common" / installdir if installdir else None
                played = _int(state.get("LastPlayed")) or last_played.get(appid)
                games.append({
                    "id": f"steam:{appid}", "store": "steam", "title": name, "steamAppID": appid,
                    "sizeBytes": _int(state.get("SizeOnDisk")), "lastPlayedAt": _iso(played),
                    "installDir": str(folder) if folder else None,
                    "exe": main_executable(folder, name) if folder else None,
                    "coverPath": self.covers(root, appid), "coverURL": STEAM_CDN.format(appid=appid),
                    "canLaunch": bool(flags & 4), "launch": {"uri": f"steam://rungameid/{appid}"},
                })
        return StoreScan(self.store, True, games)


class EpicSource:
    store = "epic"

    def __init__(self, data_folder=None, environ=os.environ):
        program_data = environ.get("PROGRAMDATA") or environ.get("ProgramData") or r"C:\ProgramData"
        self.folder = Path(data_folder) if data_folder else Path(program_data) / "Epic" / "EpicGamesLauncher" / "Data"

    def _artwork(self):
        """Portrait artwork URLs by catalog item ID, from the launcher's catalog cache."""
        cache = self.folder / "Catalog" / "catcache.bin"
        try:
            if cache.stat().st_size > MAX_CATALOG_BYTES:
                return {}
            items = json.loads(b64decode(cache.read_bytes()))
        except (OSError, ValueError):
            return {}
        result = {}
        for item in items if isinstance(items, list) else []:
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                continue
            images = {image.get("type"): image.get("url") for image in item.get("keyImages") or [] if isinstance(image, dict)}
            url = images.get("DieselGameBoxTall") or images.get("OfferImageTall")
            if isinstance(url, str) and re.match(r"^https://[a-z0-9.-]+\.(epicgames|unrealengine)\.com/", url):
                result[item["id"]] = url
        return result

    def scan(self):
        manifests = self.folder / "Manifests"
        if not manifests.is_dir():
            return StoreScan(self.store, False)
        artwork = self._artwork()
        games = []
        for path in sorted(manifests.glob("*.item")):
            try:
                if path.stat().st_size > MAX_MANIFEST_BYTES:
                    continue
                item = json.loads(path.read_text(encoding="utf-8-sig"))
            except (OSError, ValueError):
                continue
            if not isinstance(item, dict) or item.get("bIsIncompleteInstall"):
                continue
            app, namespace, catalog = item.get("AppName"), item.get("CatalogNamespace"), item.get("CatalogItemId")
            title = item.get("DisplayName")
            if not all(isinstance(value, str) and value for value in (app, namespace, catalog, title)):
                continue
            main = item.get("MainGameAppName")
            if isinstance(main, str) and main and main != app:
                continue  # DLC
            categories = item.get("AppCategories")
            if isinstance(categories, list) and categories and "games" not in categories:
                continue  # Engines and other tools.
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", app):
                continue
            install = item.get("InstallLocation") if isinstance(item.get("InstallLocation"), str) else None
            launch = item.get("LaunchExecutable") if isinstance(item.get("LaunchExecutable"), str) else None
            exe = str(Path(install) / launch) if install and launch else None
            games.append({
                "id": f"epic:{app}", "store": "epic", "title": title.strip(), "steamAppID": None,
                "sizeBytes": _int(item.get("InstallSize")), "lastPlayedAt": None, "installDir": install,
                "exe": exe, "coverPath": None, "coverURL": artwork.get(catalog), "canLaunch": True, "epicAppName": app,
                "launch": {"uri": EPIC_URI.format(namespace=namespace, item=catalog, app=app)},
            })
        return StoreScan(self.store, True, games)


class GogSource:
    store = "gog"
    KEY = r"SOFTWARE\WOW6432Node\GOG.com\Games"

    def __init__(self, registry=None):
        if registry is None and os.name == "nt":
            import winreg as registry
        self.registry = registry

    def scan(self):
        registry = self.registry
        if registry is None:
            return StoreScan(self.store, False)
        try:
            root = registry.OpenKey(registry.HKEY_LOCAL_MACHINE, self.KEY)
        except OSError:
            return StoreScan(self.store, False)
        games = []
        with root:
            index = 0
            while True:
                try:
                    name = registry.EnumKey(root, index)
                except OSError:
                    break
                index += 1
                values = {}
                try:
                    with registry.OpenKey(root, name) as key:
                        for field in ("gameName", "gameID", "exe", "launchParam", "path", "workingDir", "dependsOn"):
                            try:
                                values[field] = registry.QueryValueEx(key, field)[0]
                            except OSError:
                                pass
                except OSError:
                    continue
                game_id = str(values.get("gameID") or name).strip()
                title, exe = values.get("gameName"), values.get("exe")
                if values.get("dependsOn") or not re.fullmatch(r"[0-9]{1,20}", game_id) or not isinstance(title, str) or not title:
                    continue
                exe = exe if isinstance(exe, str) and exe else None
                folder = values.get("path") if isinstance(values.get("path"), str) else None
                games.append({
                    "id": f"gog:{game_id}", "store": "gog", "title": title.strip(), "steamAppID": None,
                    "sizeBytes": None, "lastPlayedAt": None, "installDir": folder, "exe": exe, "coverPath": None,
                    "coverURL": None, "canLaunch": bool(exe),
                    "launch": {"exe": exe, "arguments": str(values.get("launchParam") or "").strip(),
                               "workingDir": values.get("workingDir") or folder},
                })
        return StoreScan(self.store, True, games)


# MARK: - Launching

class Launcher:
    """Starts games the way their store does. Windows only; tests use a fake."""

    def open_uri(self, uri):
        if os.name != "nt":
            raise OSError("Launching games requires Windows.")
        os.startfile(uri)  # noqa: S606 - a steam:// or com.epicgames.launcher:// URI built from local manifests

    def start(self, exe, arguments, working_dir):
        if os.name != "nt":
            raise OSError("Launching games requires Windows.")
        command = subprocess.list2cmdline([exe]) + (f" {arguments}" if arguments else "")
        subprocess.Popen(command, cwd=working_dir if working_dir and os.path.isdir(working_dir) else None,
                         close_fds=True, creationflags=0x00000008)  # DETACHED_PROCESS


# MARK: - The library

class GameLibrary:
    def __init__(self, sources=None, icons=None, covers=None, sunshine_entries=None, launcher=None,
                 clock=time.time, ttl=SCAN_TTL_SECONDS):
        self.sources = sources if sources is not None else [SteamSource(), EpicSource(), GogSource()]
        if icons is None:
            from orbit_icons import ICONS
            icons = ICONS
        self.icons = icons
        self.covers = covers or CoverRegistry()
        self.sunshine_entries = sunshine_entries or (lambda: [])
        self.launcher = launcher or Launcher()
        self.clock = clock
        self.ttl = ttl
        self._lock = threading.Lock()
        self._scan_lock = threading.Lock()
        self._games = []
        self._stores = []
        self._scanned_at = None

    def scan(self, force=False):
        with self._scan_lock:
            with self._lock:
                fresh = self._scanned_at is not None and self.clock() - self._scanned_at < self.ttl
            if fresh and not force:
                return
            stores, games = [], []
            try:
                sunshine = [entry for entry in self.sunshine_entries() if isinstance(entry, dict)]
            except Exception:
                sunshine = []
            for source in self.sources:
                try:
                    result = source.scan()
                except Exception:
                    result = StoreScan(getattr(source, "store", "unknown"), False)
                stores.append({"store": result.store, "available": result.available, "count": len(result.games)})
                for game in result.games:
                    game["sunshineApp"] = sunshine_match(game, sunshine)
                    game["coverID"] = self.covers.register(game.get("coverPath")) if game.get("coverPath") else None
                    game["iconID"] = self.icons.register(game["exe"]) if game.get("exe") else None
                    games.append(game)
            with self._lock:
                self._games, self._stores, self._scanned_at = games, stores, self.clock()

    def _running_folders(self, executables):
        return [_norm_path(path) for path in executables if path]

    def snapshot(self, running_executables=()):
        self.scan()
        running = self._running_folders(running_executables)
        with self._lock:
            games, stores, scanned = list(self._games), list(self._stores), self._scanned_at
        rows = []
        for game in games:
            install = _norm_path(game.get("installDir"))
            is_running = bool(install) and any(path.startswith(install + "/") for path in running)
            rows.append({"id": game["id"], "store": game["store"], "title": game["title"],
                         "steamAppID": game.get("steamAppID"), "sizeBytes": game.get("sizeBytes"),
                         "lastPlayedAt": game.get("lastPlayedAt"), "isRunning": is_running,
                         "coverID": game.get("coverID"), "coverURL": game.get("coverURL"),
                         "iconID": game.get("iconID"), "sunshineApp": game.get("sunshineApp"),
                         "canLaunch": bool(game.get("canLaunch"))})
        rows.sort(key=lambda row: (not row["isRunning"], -(datetime.fromisoformat(row["lastPlayedAt"].replace("Z", "+00:00")).timestamp()
                                                            if row["lastPlayedAt"] else 0), row["title"].casefold()))
        return {"scannedAt": _iso(scanned), "stores": stores, "games": rows}

    def find(self, game_id):
        self.scan()
        with self._lock:
            for game in self._games:
                if game["id"] == game_id:
                    return dict(game)
        raise KeyError(game_id)

    def match_executable(self, executable):
        """The library game whose install folder holds this running executable."""
        path = _norm_path(executable)
        if not path:
            return None
        with self._lock:
            best = None
            for game in self._games:
                install = _norm_path(game.get("installDir"))
                if install and path.startswith(install + "/") and (best is None or len(install) > len(_norm_path(best.get("installDir")))):
                    best = game
            return dict(best) if best else None

    def install_roots(self):
        with self._lock:
            return [_norm_path(game.get("installDir")) + "/" for game in self._games if game.get("installDir")]

    def launch(self, game_id):
        game = self.find(game_id)
        if not game.get("canLaunch"):
            raise PermissionError("This game is not fully installed. Finish the download in its store first.")
        launch = game["launch"]
        if launch.get("uri"):
            self.launcher.open_uri(launch["uri"])
        else:
            self.launcher.start(launch["exe"], launch.get("arguments"), launch.get("workingDir"))
        return game
