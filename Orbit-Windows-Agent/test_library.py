"""Game library: Steam/Epic/GOG parsing on fixture folders, covers, launching, status.

Every store lives in a temporary folder or a fake registry; launching uses a fake.
"""
import base64
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

import orbit_activity as activity
import orbit_agent as agent
import orbit_devices as devices
import orbit_icons
import orbit_library as library

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content, encoding="utf-8")
    return path


def manifest(appid, name, installdir, flags=4, size=1000, last_played=None):
    played = f'\n\t"LastPlayed"\t\t"{last_played}"' if last_played else ""
    return (f'"AppState"\n{{\n\t"appid"\t\t"{appid}"\n\t"universe"\t\t"1"\n\t"name"\t\t"{name}"\n'
            f'\t"StateFlags"\t\t"{flags}"\n\t"installdir"\t\t"{installdir}"\n\t"SizeOnDisk"\t\t"{size}"{played}\n}}\n')


def steam_fixture(root):
    """Two libraries (new libraryfolders.vdf format), covers in both cache layouts."""
    root = Path(root)
    second = root / "SecondLibrary"
    write(root / "steamapps" / "libraryfolders.vdf",
          '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"label"\t\t""\n\t}\n'
          '\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' % (str(root).replace("\\", "\\\\"), str(second).replace("\\", "\\\\")))
    write(root / "steamapps" / "appmanifest_1091500.acf", manifest(1091500, "Cyberpunk 2077", "Cyberpunk 2077",
                                                                   size=70_000_000_000, last_played=1_700_000_500))
    write(root / "steamapps" / "appmanifest_228980.acf", manifest(228980, "Steamworks Common Redistributables", "Steamworks Shared"))
    write(root / "steamapps" / "appmanifest_1493710.acf", manifest(1493710, "Proton Experimental", "Proton - Experimental"))
    write(second / "steamapps" / "appmanifest_570.acf", manifest(570, "Dota 2", "dota 2 beta"))
    write(second / "steamapps" / "appmanifest_730.acf", manifest(730, "Counter-Strike 2", "Counter-Strike Global Offensive", flags=1026))
    game = root / "steamapps" / "common" / "Cyberpunk 2077"
    write(game / "bin" / "x64" / "Cyberpunk2077.exe", b"MZ" + b"\x00" * 4000)
    write(game / "unins000.exe", b"MZ" + b"\x00" * 9000)
    write(game / "bin" / "x64" / "CrashReporter.exe", b"MZ" + b"\x00" * 9000)
    write(second / "steamapps" / "common" / "dota 2 beta" / "game" / "bin" / "win64" / "dota2.exe", b"MZ")
    write(root / "appcache" / "librarycache" / "1091500_library_600x900.jpg", JPEG)  # old flat layout
    write(root / "appcache" / "librarycache" / "570" / "4f2a9b" / "library_600x900.jpg", JPEG)  # 2024 per-app layout
    write(root / "appcache" / "librarycache" / "730" / "header.jpg", JPEG)  # landscape only: no portrait cover
    # Last played for Dota from the account's localconfig.vdf.
    write(root / "userdata" / "123" / "config" / "localconfig.vdf",
          '"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"apps"\n\t\t\t\t{\n'
          '\t\t\t\t\t"570"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LastPlayed"\t\t"1700000900"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
    return root


def epic_fixture(folder):
    data = Path(folder) / "Epic" / "EpicGamesLauncher" / "Data"
    install = Path(folder) / "Epic Games" / "Hades"
    write(install / "x64" / "Hades.exe", b"MZ")
    base = {"CatalogNamespace": "min", "bIsIncompleteInstall": False, "AppCategories": ["public", "games", "applications"]}
    write(data / "Manifests" / "A.item", json.dumps({**base, "DisplayName": "Hades", "AppName": "Min", "CatalogItemId": "abc123",
                                                    "MainGameAppName": "Min", "InstallLocation": str(install),
                                                    "LaunchExecutable": "x64/Hades.exe", "InstallSize": 15_000_000_000}))
    write(data / "Manifests" / "B.item", json.dumps({**base, "DisplayName": "Hades DLC", "AppName": "MinDLC", "CatalogItemId": "d1",
                                                    "MainGameAppName": "Min"}))
    write(data / "Manifests" / "C.item", json.dumps({**base, "DisplayName": "Half", "AppName": "Half", "CatalogItemId": "h1",
                                                    "bIsIncompleteInstall": True}))
    write(data / "Manifests" / "D.item", json.dumps({**base, "DisplayName": "Unreal Engine", "AppName": "UE_5.4",
                                                    "CatalogItemId": "ue", "AppCategories": ["public", "engines"]}))
    write(data / "Manifests" / "E.item", "{not json")
    catalog = [{"id": "abc123", "keyImages": [{"type": "DieselGameBoxTall", "url": "https://cdn1.epicgames.com/min/box.jpg"},
                                              {"type": "DieselGameBox", "url": "https://cdn1.epicgames.com/min/wide.jpg"}]},
               {"id": "h1", "keyImages": [{"type": "DieselGameBoxTall", "url": "http://evil.example/x.jpg"}]}]
    write(data / "Catalog" / "catcache.bin", base64.b64encode(json.dumps(catalog).encode()))
    return data


class FakeKey:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeRegistry:
    HKEY_LOCAL_MACHINE = "HKLM"
    HKEY_CURRENT_USER = "HKCU"

    def __init__(self, keys):
        self.keys = keys  # {(root, path): {name: value}} and children by prefix

    def OpenKey(self, root, path):
        full = path if isinstance(root, str) else f"{root.path}\\{path}"
        prefix = root if isinstance(root, str) else None
        key = (prefix or self._root_of(root), full)
        if key not in self.keys and not any(name[1].startswith(full + "\\") for name in self.keys):
            raise OSError(path)
        return FakeKey((key[0], full)) if isinstance(root, str) else FakeKey((key[0], full))

    def _root_of(self, key):
        return key.path[0]

    def EnumKey(self, key, index):
        root, path = key.path
        children = sorted({name[len(path) + 1:].split("\\")[0] for kind, name in self.keys
                           if kind == root and name.startswith(path + "\\")})
        if index >= len(children):
            raise OSError("No more keys")
        return children[index]

    def QueryValueEx(self, key, name):
        root, path = key.path
        values = self.keys.get((root, path), {})
        if name not in values:
            raise OSError(name)
        return values[name], 1


class FakeRegistryKey(FakeKey):
    pass


def gog_registry(folder):
    exe = write(Path(folder) / "GOG Games" / "Witcher 3" / "bin" / "x64" / "witcher3.exe", b"MZ")
    base = r"SOFTWARE\WOW6432Node\GOG.com\Games"
    registry = FakeRegistry({
        ("HKLM", base + r"\1207664643"): {"gameName": "The Witcher 3: Wild Hunt", "gameID": "1207664643", "exe": str(exe),
                                          "launchParam": "-nologo", "path": str(Path(folder) / "GOG Games" / "Witcher 3"),
                                          "workingDir": str(exe.parent)},
        ("HKLM", base + r"\1640424747"): {"gameName": "Hearts of Stone", "gameID": "1640424747", "dependsOn": "1207664643",
                                          "exe": str(exe)},
    })

    def open_key(root, path):
        if isinstance(root, FakeKey):
            return FakeKey((root.path[0], root.path[1] + "\\" + path))
        if not any(kind == root and (name == path or name.startswith(path + "\\")) for kind, name in registry.keys):
            raise OSError(path)
        return FakeKey((root, path))
    registry.OpenKey = open_key
    return registry


class VdfTests(unittest.TestCase):
    def test_nested_values_escapes_comments_and_case(self):
        data = library.parse_vdf('// header\n"Root"\n{\n  "Key" "va\\"lue" // trailing\n  "Child" { "LastPlayed" "12" }\n'
                                 '  "Path" "C:\\\\Games"\n  "flag" "1" [$WIN32]\n}\n')
        root = data.get("root")
        self.assertEqual(root.get("key"), 'va"lue')
        self.assertEqual(root.get("Child").get("lastplayed"), "12")
        self.assertEqual(root.get("path"), "C:\\Games")
        self.assertEqual(root.get("FLAG"), "1")

    def test_broken_files_never_raise(self):
        self.assertEqual(library.parse_vdf('"a" { "b" "c" } } } "d"').get("a").get("b"), "c")
        self.assertEqual(dict(library.parse_vdf("{ {")), {})
        self.assertEqual(dict(library.read_vdf("/nonexistent/file.vdf")), {})


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()

    def tearDown(self):
        self.folder.cleanup()

    def test_steam_libraries_manifests_tools_and_last_played(self):
        root = steam_fixture(self.root / "Steam")
        result = library.SteamSource(root=root).scan()
        self.assertTrue(result.available)
        games = {game["id"]: game for game in result.games}
        self.assertEqual(set(games), {"steam:1091500", "steam:570", "steam:730"})
        cyberpunk = games["steam:1091500"]
        self.assertEqual((cyberpunk["title"], cyberpunk["steamAppID"], cyberpunk["sizeBytes"]), ("Cyberpunk 2077", "1091500", 70_000_000_000))
        self.assertEqual(cyberpunk["lastPlayedAt"], "2023-11-14T22:21:40Z")
        self.assertTrue(cyberpunk["exe"].endswith("Cyberpunk2077.exe"))
        self.assertEqual(cyberpunk["launch"], {"uri": "steam://rungameid/1091500"})
        self.assertEqual(games["steam:570"]["lastPlayedAt"], "2023-11-14T22:28:20Z")  # from localconfig.vdf
        self.assertFalse(games["steam:730"]["canLaunch"])  # StateFlags without "fully installed"
        self.assertTrue(games["steam:570"]["canLaunch"])

    def test_steam_covers_in_old_and_2024_layouts(self):
        root = steam_fixture(self.root / "Steam")
        self.assertEqual(library.SteamSource.covers(root, "1091500").name, "1091500_library_600x900.jpg")
        self.assertEqual(library.SteamSource.covers(root, "570").parts[-2:], ("4f2a9b", "library_600x900.jpg"))
        self.assertIsNone(library.SteamSource.covers(root, "730"))  # only a landscape header
        self.assertIsNone(library.SteamSource.covers(root, "999"))

    def test_old_libraryfolders_format_and_missing_steam(self):
        root = self.root / "Steam"
        other = self.root / "D" / "SteamLibrary"
        write(root / "steamapps" / "libraryfolders.vdf",
              '"LibraryFolders"\n{\n\t"TimeNextStatsReport"\t\t"1"\n\t"ContentStatsID"\t\t"2"\n\t"1"\t\t"%s"\n}\n'
              % str(other).replace("\\", "\\\\"))
        write(other / "steamapps" / "appmanifest_10.acf", manifest(10, "Counter-Strike", "Half-Life"))
        self.assertEqual([game["id"] for game in library.SteamSource(root=root).scan().games], ["steam:10"])
        self.assertFalse(library.SteamSource(root=None, root_finder=lambda: None).scan().available)

    def test_steam_root_comes_from_the_registry(self):
        steam = self.root / "Valve Steam"
        steam.mkdir()
        registry = SimpleNamespace(HKEY_CURRENT_USER="HKCU", HKEY_LOCAL_MACHINE="HKLM",
                                   OpenKey=lambda root, path: FakeKey((root, path)),
                                   QueryValueEx=lambda key, name: (str(steam), 1) if key.path == ("HKCU", r"Software\Valve\Steam") else (_ for _ in ()).throw(OSError()))
        self.assertEqual(library.steam_root(registry=registry, environ={}), steam)

    def test_epic_games_skip_dlc_partial_installs_and_engines(self):
        data = epic_fixture(self.root)
        result = library.EpicSource(data_folder=data).scan()
        self.assertEqual([game["id"] for game in result.games], ["epic:Min"])
        hades = result.games[0]
        self.assertEqual(hades["launch"]["uri"], "com.epicgames.launcher://apps/min%3Aabc123%3AMin?action=launch&silent=true")
        self.assertEqual(hades["coverURL"], "https://cdn1.epicgames.com/min/box.jpg")
        self.assertTrue(hades["exe"].replace("\\", "/").endswith("x64/Hades.exe"))
        self.assertFalse(library.EpicSource(data_folder=self.root / "missing").scan().available)

    def test_gog_games_from_the_registry_without_dlc(self):
        result = library.GogSource(registry=gog_registry(self.root)).scan()
        self.assertTrue(result.available)
        self.assertEqual([(game["id"], game["title"]) for game in result.games], [("gog:1207664643", "The Witcher 3: Wild Hunt")])
        self.assertEqual(result.games[0]["launch"]["arguments"], "-nologo")
        self.assertFalse(library.GogSource(registry=None).scan().available)

    def test_main_executable_skips_installers_and_crash_reporters(self):
        folder = self.root / "Game"
        write(folder / "unins000.exe", b"MZ" * 900)
        write(folder / "UnityCrashHandler64.exe", b"MZ" * 900)
        write(folder / "vcredist_x64.exe", b"MZ" * 900)
        self.assertIsNone(library.main_executable(folder, "My Game"))
        write(folder / "Tool.exe", b"MZ" * 10)
        write(folder / "Binaries" / "Win64" / "MyGame-Win64-Shipping.exe", b"MZ" * 500)
        self.assertTrue(library.main_executable(folder, "My Game").endswith("MyGame-Win64-Shipping.exe"))
        self.assertIsNone(library.main_executable(self.root / "missing", "x"))

    def test_sunshine_apps_are_matched_to_library_games(self):
        game = {"title": "Cyberpunk 2077™", "steamAppID": "1091500", "installDir": "D:\\Games\\Cyberpunk 2077",
                "exe": "D:\\Games\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe"}
        self.assertEqual(library.sunshine_match(game, [{"name": "Steam Big Picture", "cmd": "steam://open/bigpicture"},
                                                       {"name": "CP", "detached": ["steam://rungameid/1091500"]}]), "CP")
        self.assertIsNone(library.sunshine_match(game, [{"name": "Other", "detached": ["steam://rungameid/10915001"]}]))
        self.assertEqual(library.sunshine_match(game, [{"name": "Night City", "cmd": '"D:\\Games\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe"'}]),
                         "Night City")
        self.assertEqual(library.sunshine_match(game, [{"name": "Cyberpunk 2077"}]), "Cyberpunk 2077")
        epic = {"title": "Hades", "epicAppName": "Min"}
        self.assertEqual(library.sunshine_match(epic, [{"name": "H", "cmd": "com.epicgames.launcher://apps/min%3Aabc%3AMin?action=launch"}]), "H")


class FakeLauncher:
    def __init__(self):
        self.uris, self.started = [], []

    def open_uri(self, uri):
        self.uris.append(uri)

    def start(self, exe, arguments, working_dir):
        self.started.append((exe, arguments, working_dir))


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        self.launcher = FakeLauncher()
        self.icons = orbit_icons.IconRegistry(extractor=lambda path, index: None)
        self.library = library.GameLibrary(
            sources=[library.SteamSource(root=steam_fixture(self.root / "Steam")),
                     library.EpicSource(data_folder=epic_fixture(self.root)),
                     library.GogSource(registry=gog_registry(self.root))],
            icons=self.icons, launcher=self.launcher,
            sunshine_entries=lambda: [{"name": "Dota", "detached": ["steam://rungameid/570"]}])

    def tearDown(self):
        self.folder.cleanup()

    def test_snapshot_shape_order_and_running_games(self):
        dota_exe = str(self.root / "Steam" / "SecondLibrary" / "steamapps" / "common" / "dota 2 beta" / "game" / "bin" / "win64" / "dota2.exe")
        snapshot = self.library.snapshot([dota_exe])
        self.assertTrue(snapshot["scannedAt"].endswith("Z"))
        self.assertEqual(snapshot["stores"], [{"store": "steam", "available": True, "count": 3},
                                              {"store": "epic", "available": True, "count": 1},
                                              {"store": "gog", "available": True, "count": 1}])
        games = snapshot["games"]
        self.assertEqual(set(games[0]), {"id", "store", "title", "steamAppID", "sizeBytes", "lastPlayedAt", "isRunning",
                                         "coverID", "coverURL", "iconID", "sunshineApp", "canLaunch"})
        self.assertEqual(games[0]["id"], "steam:570")  # running first
        self.assertTrue(games[0]["isRunning"])
        self.assertEqual(games[0]["sunshineApp"], "Dota")
        self.assertEqual(games[1]["id"], "steam:1091500")  # then most recently played
        self.assertNotIn(str(self.root), json.dumps(snapshot))  # never a path
        self.assertRegex(games[1]["coverID"], r"^[0-9a-f]{32}$")
        self.assertRegex(games[1]["iconID"], r"^[0-9a-f]{32}$")
        steam_730 = next(game for game in games if game["id"] == "steam:730")
        self.assertIsNone(steam_730["coverID"])
        self.assertEqual(steam_730["coverURL"],
                         "https://shared.steamstatic.com/store_item_assets/steam/apps/730/library_600x900.jpg")

    def test_covers_are_served_by_opaque_id_only(self):
        cover = next(game["coverID"] for game in self.library.snapshot()["games"] if game["id"] == "steam:1091500")
        self.assertEqual(self.library.covers.read(cover), (JPEG, "image/jpeg"))
        for bad in ("0" * 32, "../../etc/passwd", str(self.root), ""):
            with self.assertRaises(KeyError):
                self.library.covers.read(bad)
        not_image = write(self.root / "fake.jpg", b"<html>")
        identity = self.library.covers.register(not_image)
        with self.assertRaises(OSError):
            self.library.covers.read(identity)

    def test_launch_through_each_store(self):
        self.assertEqual(self.library.launch("steam:1091500")["title"], "Cyberpunk 2077")
        self.library.launch("epic:Min")
        self.library.launch("gog:1207664643")
        self.assertEqual(self.launcher.uris, ["steam://rungameid/1091500",
                                              "com.epicgames.launcher://apps/min%3Aabc123%3AMin?action=launch&silent=true"])
        self.assertEqual(self.launcher.started[0][1:], ("-nologo", self.launcher.started[0][2]))
        self.assertTrue(self.launcher.started[0][0].endswith("witcher3.exe"))
        with self.assertRaises(PermissionError):
            self.library.launch("steam:730")
        with self.assertRaises(KeyError):
            self.library.launch("steam:1")

    def test_running_executable_maps_to_the_library_game(self):
        self.library.scan()
        exe = self.root / "Steam" / "steamapps" / "common" / "Cyberpunk 2077" / "bin" / "x64" / "Cyberpunk2077.exe"
        self.assertEqual(self.library.match_executable(str(exe))["title"], "Cyberpunk 2077")
        self.assertEqual(self.library.match_executable(str(exe).upper().replace("/", "\\"))["id"], "steam:1091500")
        self.assertIsNone(self.library.match_executable(str(self.root / "Steam" / "steamapps" / "common" / "Cyberpunk 20777" / "x.exe")))
        self.assertIsNone(self.library.match_executable(None))
        self.assertTrue(all(root.endswith("/") for root in self.library.install_roots()))

    def test_failing_store_is_reported_unavailable_not_fatal(self):
        broken = Mock(store="epic")
        broken.scan.side_effect = RuntimeError("corrupt")
        lib = library.GameLibrary(sources=[broken], icons=self.icons, launcher=self.launcher)
        self.assertEqual(lib.snapshot()["stores"], [{"store": "epic", "available": False, "count": 0}])

    def test_scan_is_cached_until_rescan(self):
        source = Mock(store="steam")
        source.scan.return_value = library.StoreScan("steam", True, [])
        lib = library.GameLibrary(sources=[source], icons=self.icons, launcher=self.launcher)
        lib.snapshot()
        lib.snapshot()
        self.assertEqual(source.scan.call_count, 1)
        lib.scan(force=True)
        self.assertEqual(source.scan.call_count, 2)


class LibraryAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name).resolve()
        self.launcher = FakeLauncher()
        self.library = library.GameLibrary(sources=[library.SteamSource(root=steam_fixture(root / "Steam"))],
                                           icons=orbit_icons.IconRegistry(extractor=lambda path, index: None), launcher=self.launcher)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        _, token = self.registry.register("Orbit on iPhone", "iOS")
        _, reader = self.registry.register("Orbit on iPad", "iPadOS", scopes=["read"])
        self.auth, self.reader = {"Authorization": f"Bearer {token}"}, {"Authorization": f"Bearer {reader}"}
        self.patches = [patch.object(agent, "LIBRARY", self.library), patch.object(agent, "DEVICE_REGISTRY", self.registry),
                        patch.object(agent, "ACTIVITY", self.log), patch.object(agent, "running_executables", return_value=[])]
        for item in self.patches:
            item.start()
        self.https = TestClient(agent.app, base_url="https://testserver")
        self.http = TestClient(agent.app)

    def tearDown(self):
        self.https.close()
        self.http.close()
        for item in reversed(self.patches):
            item.stop()
        self.log.close()
        self.folder.cleanup()

    def test_library_needs_https_and_read(self):
        self.assertEqual(self.http.get("/api/library", headers=self.auth).status_code, 426)
        body = self.https.get("/api/library", headers=self.reader).json()
        self.assertEqual({game["id"] for game in body["games"]}, {"steam:1091500", "steam:570", "steam:730"})

    def test_cover_endpoint(self):
        cover = next(game["coverID"] for game in self.https.get("/api/library", headers=self.reader).json()["games"] if game["coverID"])
        response = self.https.get(f"/api/library/covers/{cover}", headers=self.reader)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "image/jpeg")
        self.assertIn("max-age", response.headers["cache-control"])
        self.assertEqual(response.content, JPEG)
        self.assertEqual(self.https.get(f"/api/library/covers/{'0' * 32}", headers=self.reader).status_code, 404)
        # Anything that is not an opaque cover ID is refused before reaching the file system.
        self.assertIn(self.https.get("/api/library/covers/..%2F..%2Fsecret", headers=self.reader).status_code, (403, 404, 422))
        self.assertEqual(self.https.get("/api/library/covers/not-hex", headers=self.reader).status_code, 422)

    def test_launch_is_control_202_and_logged(self):
        self.assertEqual(self.https.post("/api/library/steam:1091500/launch", headers=self.reader).json()["scope"], "control")
        with patch.object(agent, "require_windows"):
            response = self.https.post("/api/library/steam:1091500/launch", headers=self.auth)
            self.assertEqual(response.status_code, 202)
            self.assertEqual(response.json(), {"status": "launch_requested", "id": "steam:1091500", "title": "Cyberpunk 2077"})
            self.assertEqual(self.https.post("/api/library/steam:730/launch", headers=self.auth).status_code, 409)
            self.assertEqual(self.https.post("/api/library/steam:42/launch", headers=self.auth).status_code, 404)
            self.assertEqual(self.https.post("/api/library/uplay:1/launch", headers=self.auth).status_code, 422)
        self.assertEqual(self.launcher.uris, ["steam://rungameid/1091500"])
        self.log.wait()
        rows = self.log.entries(category="apps")["entries"]
        self.assertEqual([row["summary"] for row in rows if row["result"] == "ok"], ["Launched Cyberpunk 2077"])
        self.assertEqual(rows[-1]["result"], "denied")
        self.assertEqual(self.https.post("/api/library/steam:1091500/launch", headers=self.auth).status_code, 501)  # not Windows

    def test_rescan(self):
        self.assertEqual(self.https.post("/api/library/rescan", headers=self.reader).status_code, 403)
        self.assertEqual(len(self.https.post("/api/library/rescan", headers=self.auth).json()["games"]), 3)


class StatusGameTests(unittest.TestCase):
    def test_status_names_the_running_library_game(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            lib = library.GameLibrary(sources=[library.SteamSource(root=steam_fixture(root / "Steam"))],
                                      icons=orbit_icons.IconRegistry(extractor=lambda path, index: None), launcher=FakeLauncher())
            lib.scan()
            exe = str(root / "Steam" / "steamapps" / "common" / "Cyberpunk 2077" / "bin" / "x64" / "Cyberpunk2077.exe")
            state = copy.deepcopy(agent.STATE)
            stop = Mock()
            stop.wait.side_effect = [False, True]
            game = {"name": "cyberpunk2077", "process": "Cyberpunk2077.exe", "pid": 7, "exe": exe, "foreground": True, "created": 1}
            with patch.object(agent, "LIBRARY", lib), patch.object(agent, "STATE", state), patch.object(agent, "STOP_EVENT", stop), \
                 patch.object(agent, "HISTORY_RECORDER", None), \
                 patch.object(agent.psutil, "virtual_memory", return_value=SimpleNamespace(used=1, total=2)), \
                 patch.object(agent.psutil, "disk_usage", return_value=SimpleNamespace(used=1, total=2)), \
                 patch.object(agent, "io_metrics", return_value={}), patch.object(agent, "nvidia_metrics", return_value=[]), \
                 patch.object(agent, "detect_game", return_value=game) as detect, \
                 patch.object(agent, "read_fps", return_value={"fps": None}), patch.object(agent, "audio_metrics", return_value={}):
                agent.telemetry_worker()
            self.assertEqual((state["activeGame"], state["activeGameTitle"], state["activeGameID"]),
                             ("Cyberpunk 2077", "Cyberpunk 2077", "steam:1091500"))
            self.assertEqual(state["activeGameProcess"], "Cyberpunk2077.exe")
            self.assertTrue(any(root_path.endswith("cyberpunk 2077/") for root_path in detect.call_args.kwargs["roots"]))

    def test_detection_accepts_games_under_library_folders(self):
        import orbit_hardware as hardware
        processes = [SimpleNamespace(info={"pid": 9, "name": "Game.exe", "exe": "D:/MyGames/Indie/Game.exe", "create_time": 1}),
                     SimpleNamespace(info={"pid": 10, "name": "notepad.exe", "exe": "C:/Windows/notepad.exe", "create_time": 2})]
        with patch.object(hardware.psutil, "process_iter", return_value=processes), patch.object(hardware, "foreground_pid", return_value=9):
            self.assertIsNone(hardware.detect_game({}))
            found = hardware.detect_game({}, roots=["d:/mygames/indie/"])
        self.assertEqual((found["pid"], found["exe"]), (9, "D:/MyGames/Indie/Game.exe"))


if __name__ == "__main__":
    unittest.main()
