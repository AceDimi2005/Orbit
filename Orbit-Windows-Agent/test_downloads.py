"""Steam/Epic/GOG download tracking: VDF parsing, manifest state machine, events and the route.

Launcher files are written to temporary folders and found through the ORBIT_* overrides; the
registry is a small fake. Nothing reads the real machine's launchers.
"""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_downloads as downloads

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

NEW_LAYOUT = r'''
"libraryfolders"
{
	"0"
	{
		"path"		"C:\\Program Files (x86)\\Steam"
		"label"		""
		"contentid"		"4911245830022233411"
		"totalsize"		"0"
		"apps"
		{
			"228980"		"420153755"
		}
	}
	"1"
	{
		"path"		"D:\\SteamLibrary"
		"label"		"Games"
		"apps"
		{
			"620"		"12000000000"
		}
	}
}
'''

OLD_LAYOUT = r'''
"LibraryFolders"
{
	"TimeNextStatsReport"		"1600000000"
	"ContentStatsID"		"-123"
	"1"		"D:\\SteamLibrary"
	"2"		"E:/Games/Steam"
}
'''


def vdf(root, values, indent=0):
    pad = "\t" * indent
    lines = [f'{pad}"{root}"', f"{pad}{{"]
    for key, value in values.items():
        if isinstance(value, dict):
            lines.append(vdf(key, value, indent + 1))
        else:
            lines.append(f'{pad}\t"{key}"\t\t"{value}"')
    lines.append(f"{pad}}}")
    return "\n".join(lines)


class Clock:
    def __init__(self, now=10_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class VDFTests(unittest.TestCase):
    def test_new_layout_with_nested_blocks(self):
        paths = downloads.SteamScanner.library_paths_from_vdf(NEW_LAYOUT)
        self.assertEqual(paths, [Path("C:\\Program Files (x86)\\Steam"), Path("D:\\SteamLibrary")])

    def test_old_layout_with_paths_as_values(self):
        paths = downloads.SteamScanner.library_paths_from_vdf(OLD_LAYOUT)
        self.assertEqual(paths, [Path("D:\\SteamLibrary"), Path("E:/Games/Steam")])

    def test_parser_handles_escapes_comments_conditionals_and_case(self):
        text = '// header comment\n"AppState" { "name" "Say \\"Hi\\"\\tnow" "StateFlags" "4" [$WIN32]\n' \
               '"Nested" { "Key" Value } }'
        data = downloads.parse_vdf(text)
        state = downloads.vdf_get(data, "appstate")
        self.assertEqual(state["name"], 'Say "Hi"\tnow')
        self.assertEqual(downloads.vdf_get(state, "stateflags"), "4")
        self.assertEqual(state["Nested"], {"Key": "Value"})
        for broken in ('"a" { "b" "c"', '"a" "b" }', '{ "a" "b" }'):
            with self.subTest(text=broken), self.assertRaises(ValueError):
                downloads.parse_vdf(broken)

    def test_garbage_vdf_gives_no_libraries(self):
        self.assertEqual(downloads.SteamScanner.library_paths_from_vdf('"something" { "else" "x" }'), [])


class SteamFixture:
    """A Steam folder (and an optional second library) with manifests the tests rewrite."""

    def __init__(self, test, layout="new"):
        folder = tempfile.TemporaryDirectory()
        test.addCleanup(folder.cleanup)
        self.base = Path(folder.name)
        self.root = self.base / "Steam"
        self.second = self.base / "Library2"
        for library in (self.root, self.second):
            (library / "steamapps" / "common").mkdir(parents=True)
        (self.root / "logs").mkdir()
        # Paths with forward slashes, as Steam writes SteamPath on Windows too.
        second = str(self.second).replace("\\", "/")
        if layout == "new":
            text = vdf("libraryfolders", {"0": {"path": str(self.root).replace("\\", "\\\\")},
                                          "1": {"path": second, "apps": {"620": "1"}}})
        else:
            text = vdf("LibraryFolders", {"TimeNextStatsReport": "1", "1": second})
        (self.root / "steamapps" / "libraryfolders.vdf").write_text(text, encoding="utf-8")
        env = patch.dict(os.environ, {"ORBIT_STEAM_PATH": str(self.root)}, clear=False)
        env.start()
        test.addCleanup(env.stop)
        for name in ("ORBIT_STEAM_LIBRARIES", "ORBIT_EPIC_MANIFESTS", "ORBIT_EPIC_LAUNCHER_INSTALLED", "ORBIT_GOG_GAMES_KEY"):
            os.environ.pop(name, None)
        self.mtime = 1_700_000_000

    def manifest(self, appid, flags, name="Portal 2", library=None, to_download=0, downloaded=0, to_stage=0, staged=0,
                 update_result=0, build="100", target=None):
        library = library or self.second
        path = library / "steamapps" / f"appmanifest_{appid}.acf"
        path.write_text(vdf("AppState", {
            "appid": appid, "Universe": 1, "name": name, "StateFlags": flags, "installdir": name,
            "LastUpdated": 1, "SizeOnDisk": downloaded, "buildid": build, "UpdateResult": update_result,
            "BytesToDownload": to_download, "BytesDownloaded": downloaded, "BytesToStage": to_stage,
            "BytesStaged": staged, "TargetBuildID": target or build}), encoding="utf-8")
        # Every write gets a new mtime so the scanner's cache never hides a change.
        self.mtime += 1
        os.utime(path, (self.mtime, self.mtime))
        return path

    def downloading_folder(self, appid, library=None, present=True):
        folder = (library or self.second) / "steamapps" / "downloading" / str(appid)
        if present:
            folder.mkdir(parents=True, exist_ok=True)
        elif folder.exists():
            folder.rmdir()

    def log(self, line):
        with open(self.root / "logs" / "content_log.txt", "a", encoding="utf-8") as stream:
            stream.write(f"[2026-10-24 10:00:00] {line}\n")


class FakeLaunchers:
    """LauncherMonitor stand-in: Steam and Epic are running unless a test closes them."""

    def __init__(self, running=True):
        self.state = {"steam": running, "epic": running}
        self.busy = {}

    def refresh(self, force=False):
        pass

    def running(self, store):
        return self.state.get(store)

    def busy_within(self, store, seconds):
        return self.busy.get(store, False)


def make_watcher(test, clock=None, wall=None, enabled=lambda: True, launchers=None):
    clock = clock or Clock()
    wall = wall or Clock(1_790_000_000.0)
    emit = MagicMock(side_effect=lambda kind, title, body, **kwargs: {"id": 1, "kind": kind, "title": title, "body": body, **kwargs})
    watcher = downloads.DownloadsWatcher(clock=wall, monotonic=clock, emit=emit, notify_enabled=enabled,
                                         launchers=launchers or FakeLaunchers())
    return watcher, emit, clock


def kinds(emit):
    return [entry.args[0] for entry in emit.call_args_list]


class SteamHelpers:
    def poll(self, seconds=5):
        self.watcher.poll()
        self.clock.advance(seconds)
        return self.watcher.payload()

    def item(self, payload, ident="steam:620"):
        return next((entry for entry in payload["downloads"] if entry["id"] == ident), None)


class SteamTests(SteamHelpers, unittest.TestCase):
    def setUp(self):
        self.steam = SteamFixture(self)
        self.watcher, self.emit, self.clock = make_watcher(self)

    def test_libraries_from_vdf_and_environment_without_duplicates(self):
        extra = self.steam.base / "Extra"
        (extra / "steamapps").mkdir(parents=True)
        missing = self.steam.base / "Missing"
        with patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": os.pathsep.join([str(extra), str(self.steam.second), str(missing)])}):
            scanner = downloads.SteamScanner()
            self.assertTrue(scanner.present())
            libraries = scanner.libraries()
        self.assertEqual([downloads._normal(p) for p in libraries],
                         [downloads._normal(p) for p in (self.steam.root, self.steam.second, extra)])

    def test_old_layout_is_read_too(self):
        steam = SteamFixture(self, layout="old")
        scanner = downloads.SteamScanner()
        self.assertTrue(scanner.present())
        self.assertIn(downloads._normal(steam.second), [downloads._normal(p) for p in scanner.libraries()])

    def test_registry_steam_path_with_forward_slashes(self):
        os.environ.pop("ORBIT_STEAM_PATH")
        fake = FakeRegistry({r"HKEY_CURRENT_USER\Software\Valve\Steam": {"SteamPath": str(self.steam.root).replace("\\", "/")}})
        with patch.object(downloads, "winreg", fake):
            self.assertEqual(downloads._normal(downloads.SteamScanner.locate_root()), downloads._normal(self.steam.root))
        with patch.object(downloads, "winreg", FakeRegistry({})):
            self.assertIsNone(downloads.SteamScanner.locate_root())

    def test_installed_games_are_not_downloads(self):
        self.steam.manifest(620, 4)
        self.steam.manifest(440, 4 | 64, name="Team Fortress 2", library=self.steam.root)  # running
        payload = self.poll()
        self.assertEqual(payload["downloads"], [])
        self.assertFalse(payload["active"])
        self.assertEqual(payload["stores"], {"steam": True, "epic": False, "gog": False})

    def test_new_install_queued_downloading_staging_finished(self):
        gb = 1_000_000_000
        self.steam.manifest(620, 1026, to_download=12 * gb, downloaded=0, target="200")
        self.steam.downloading_folder(620)
        payload = self.poll()
        self.assertEqual(self.item(payload)["state"], "queued")
        self.assertTrue(payload["active"])
        self.steam.manifest(620, 1026, to_download=12 * gb, downloaded=5 * gb, target="200")
        entry = self.item(self.poll())
        self.assertEqual((entry["state"], entry["progress"], entry["bytesDone"], entry["bytesTotal"]),
                         ("downloading", round(5 / 12, 4), 5 * gb, 12 * gb))
        self.assertEqual(entry["name"], "Portal 2")
        self.steam.manifest(620, 1026, to_download=12 * gb, downloaded=12 * gb, to_stage=4 * gb, staged=1 * gb, target="200")
        entry = self.item(self.poll())
        self.assertEqual((entry["state"], entry["progress"], entry["bytesDone"]), ("staging", 0.25, 1 * gb))
        self.assertEqual(kinds(self.emit), [])
        self.steam.manifest(620, 4, build="200")
        self.steam.downloading_folder(620, present=False)
        payload = self.poll()
        entry = self.item(payload)
        self.assertEqual((entry["state"], entry["progress"], entry["bytesTotal"]), ("finished", 1.0, 12 * gb))
        self.assertFalse(payload["active"])
        self.assertEqual(kinds(self.emit), ["download.finished"])
        kind, title, body = self.emit.call_args.args
        self.assertEqual(title, "Portal 2 finished downloading")
        self.assertIn("Steam is done (12.0 GB)", body)
        self.assertEqual(self.emit.call_args.kwargs["data"], {"id": "steam:620", "store": "steam", "name": "Portal 2", "bytesTotal": 12 * gb})
        # allFinished once 60 s have passed since the last poll that saw activity.
        for _ in range(10):
            self.poll()
        self.assertEqual(kinds(self.emit), ["download.finished"])
        self.poll()
        self.assertEqual(kinds(self.emit), ["download.finished", "downloads.allFinished"])
        kind, title, body = self.emit.call_args.args
        self.assertEqual((title, body), ("All downloads finished", "Portal 2 is ready to play."))
        self.assertFalse(self.emit.call_args.kwargs["toast"])  # one download: the PC already showed its toast
        for _ in range(20):
            self.poll()
        self.assertEqual(kinds(self.emit).count("downloads.allFinished"), 1)

    def test_update_of_an_installed_game(self):
        self.steam.manifest(620, 6, to_download=100, target="300")  # update required, not started: not a download
        self.assertEqual(self.poll()["downloads"], [])
        self.steam.manifest(620, 1030, to_download=100, downloaded=40, target="300")
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.steam.manifest(620, 4, build="300")
        self.poll()
        self.assertEqual(self.emit.call_args.args[1], "Portal 2 finished updating")

    def test_finished_requires_the_target_build(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=50, target="300")
        self.poll()
        self.steam.manifest(620, 4, build="200", target="300")  # flags say installed, build is still old
        self.assertNotEqual(self.item(self.poll())["state"], "finished")
        self.assertEqual(kinds(self.emit), [])

    def test_failure_from_update_result_and_content_log_reason(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.poll()  # notes the log size; old lines are history
        self.steam.manifest(620, 1026, to_download=100, downloaded=60)
        self.poll()
        self.steam.log("AppID 620 update canceled : Failed updating depot 621 (Disk write failure)")
        self.steam.log("AppID 620 scheduler finished : removed from schedule (result Disk write failure, state 0x602)")
        self.steam.manifest(620, 1538, to_download=100, downloaded=60, update_result=7)
        entry = self.item(self.poll())
        self.assertEqual(entry["state"], "failed")
        self.assertEqual((entry["bytesDone"], entry["progress"]), (60, 0.6))
        self.assertEqual(kinds(self.emit), ["download.failed"])
        kind, title, body = self.emit.call_args.args
        self.assertEqual(title, "Portal 2 download failed")
        self.assertEqual(body, "Steam stopped the download: Disk write failure.")
        self.assertEqual(self.emit.call_args.kwargs["data"]["reason"], "Disk write failure")
        self.poll()
        self.assertEqual(kinds(self.emit), ["download.failed"])  # once
        for _ in range(12):
            self.poll()
        self.assertEqual(kinds(self.emit), ["download.failed", "downloads.allFinished"])
        self.assertEqual(self.emit.call_args.args[1:], ("Downloads stopped", "Portal 2 failed."))
        # A retry that completes still reports the finish.
        self.steam.manifest(620, 1026, to_download=100, downloaded=80)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.steam.manifest(620, 4)
        self.poll()
        self.assertEqual(kinds(self.emit)[-1], "download.finished")

    def test_failure_only_in_the_content_log(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.poll()
        self.steam.log("AppID 620 state changed : Update Required,Update Queued,Update Started, (No Internet Connection)")
        self.steam.manifest(620, 1538, to_download=100, downloaded=10)
        entry = self.item(self.poll())
        self.assertEqual(entry["state"], "failed")
        self.assertIn("No Internet Connection", self.emit.call_args.args[2])

    def test_a_leftover_downloading_folder_alone_is_not_a_download(self):
        self.steam.manifest(620, 6, to_download=100, target="300")  # update pending, never started
        self.steam.downloading_folder(620)
        self.assertEqual(self.poll()["downloads"], [])
        self.steam.manifest(620, 6, to_download=100, downloaded=40, target="300")  # started before, now waiting
        self.assertEqual(self.item(self.poll())["state"], "paused")

    def test_old_log_lines_are_not_replayed(self):
        self.steam.log("AppID 620 update canceled : Failed updating depot 621 (Disk write failure)")
        self.steam.manifest(620, 1538, to_download=100, downloaded=10)
        self.steam.downloading_folder(620)
        self.assertEqual(self.item(self.poll())["state"], "paused")
        self.assertEqual(kinds(self.emit), [])

    def test_pause_resume_and_queue_behind_another_download(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.poll()
        self.steam.manifest(620, 1538, to_download=100, downloaded=30)  # paused by the user
        payload = self.poll()
        self.assertEqual(self.item(payload)["state"], "paused")
        self.assertFalse(payload["active"])
        # Another game downloads: the held one counts as queued behind it.
        self.steam.manifest(730, 1026, name="Counter-Strike 2", library=self.steam.root, to_download=100, downloaded=5)
        self.poll()
        self.steam.manifest(730, 1026, name="Counter-Strike 2", library=self.steam.root, to_download=100, downloaded=50)
        payload = self.poll()
        self.assertEqual(self.item(payload)["state"], "queued")
        self.assertEqual(self.item(payload, "steam:730")["state"], "downloading")
        self.assertEqual(payload["downloads"][0]["state"] in ("downloading", "queued"), True)
        self.steam.manifest(620, 1026, to_download=100, downloaded=60)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.assertEqual(kinds(self.emit), [])

    def test_paused_download_does_not_count_as_activity_but_is_mentioned(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.poll()
        self.steam.manifest(620, 1538, to_download=100, downloaded=30)
        for _ in range(13):
            self.poll()
        self.assertEqual(kinds(self.emit), ["downloads.allFinished"])
        self.assertEqual(self.emit.call_args.args[1:], ("Downloads stopped", "1 download is paused."))
        self.assertTrue(self.emit.call_args.kwargs["toast"])

    def test_canceled_install_disappears_quietly(self):
        path = self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.poll()
        path.unlink()
        payload = self.poll()
        self.assertEqual(payload["downloads"], [])
        self.steam.manifest(440, 1026, name="TF2", to_download=100, downloaded=10)
        self.poll()
        self.steam.manifest(440, 1, name="TF2")  # uninstalled flag: canceled
        self.assertIsNone(self.item(self.poll(), "steam:440"))
        self.assertNotIn("download.finished", kinds(self.emit))

    def test_two_downloads_then_one_summary(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.steam.manifest(730, 1026, name="Counter-Strike 2", library=self.steam.root, to_download=100, downloaded=10)
        self.poll()
        self.steam.manifest(620, 4)
        self.poll()
        self.steam.manifest(730, 4, name="Counter-Strike 2", library=self.steam.root)
        for _ in range(14):
            self.poll()
        self.assertEqual(kinds(self.emit), ["download.finished", "download.finished", "downloads.allFinished"])
        self.assertEqual(self.emit.call_args.args[2], "Portal 2 and Counter-Strike 2 are ready to play.")
        self.assertTrue(self.emit.call_args.kwargs["toast"])

    def test_notifications_off_still_tells_listeners(self):
        watcher, emit, clock = make_watcher(self, enabled=lambda: False)
        heard = []
        watcher.add_listener(lambda events, all_done: heard.append(([kind for kind, _ in events], bool(all_done))))
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        watcher.poll()
        clock.advance(5)
        self.assertIsNone(watcher.quiet_since())  # something is downloading
        self.steam.manifest(620, 4)
        watcher.poll()
        for _ in range(13):
            clock.advance(5)
            watcher.poll()
        emit.assert_not_called()
        self.assertEqual(heard[0], (["finished"], False))
        self.assertEqual(heard[-1], ([], True))
        self.assertIsNotNone(watcher.quiet_since())

    def test_finished_items_are_listed_for_an_hour(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.poll()
        self.steam.manifest(620, 4)
        self.poll()
        self.clock.advance(downloads.RETAIN_FINISHED_SECONDS - 60)
        self.assertEqual(self.item(self.poll())["state"], "finished")
        self.clock.advance(120)
        self.assertIsNone(self.item(self.poll()))

    def test_half_written_manifest_keeps_the_last_good_reading(self):
        path = self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.poll()
        path.write_text('"AppState" { "StateFlags" "10', encoding="utf-8")
        os.utime(path, (self.steam.mtime + 50, self.steam.mtime + 50))
        self.assertEqual(self.item(self.poll())["state"], "downloading")


class SteamPauseTests(SteamHelpers, unittest.TestCase):
    """Pauses, cancels, a closed Steam and stalled downloads are never failures or activity.
    The content_log lines follow the formats in research-windows-integrations.md (taken from real
    logs); the exact pause wording still needs checking on a real PC, so several variants are covered."""

    def setUp(self):
        self.steam = SteamFixture(self)
        self.launchers = FakeLaunchers()
        self.watcher, self.emit, self.clock = make_watcher(self, launchers=self.launchers)

    def test_pause_and_resume_with_steams_log_lines(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=10)
        self.poll()  # notes the log size
        self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        # The user pauses it (Steam writes the same when it suspends downloads during a game).
        self.steam.log("AppID 620 App update changed : None,")
        self.steam.log("AppID 620 scheduler finished : removed from schedule (result Suspended, state 0x602)")
        self.steam.log("AppID 620 state changed : Update Required,Update Queued,Update Started,")
        self.steam.manifest(620, 1538, to_download=100, downloaded=30, update_result=4)
        payload = self.poll()
        self.assertEqual((self.item(payload)["state"], payload["active"]), ("paused", False))
        self.assertEqual(kinds(self.emit), [])
        # Resumed.
        self.steam.log("AppID 620 App update changed : Running Update,Downloading,")
        self.steam.manifest(620, 1026, to_download=100, downloaded=50)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.steam.manifest(620, 4)
        self.poll()
        self.assertEqual(kinds(self.emit), ["download.finished"])

    def test_stop_on_purpose_reasons_and_codes_are_pauses(self):
        held = {"appid": "620", "name": "Portal 2", "flags": 1538, "toDownload": 100, "downloaded": 30, "toStage": 0,
                "staged": 0, "updateResult": 0, "buildid": "1", "targetBuild": "2", "downloadingFolder": True}
        previous = downloads.Observation("steam:620", "steam", "Portal 2", "downloading")
        lines = ["AppID 620 scheduler finished : removed from schedule (result Suspended, state 0x602)",
                 "AppID 620 scheduler finished : removed from schedule (result Paused, state 0x602)",
                 "AppID 620 state changed : Update Required,Update Queued,Update Started, (Suspended)",
                 "AppID 620 update canceled : Suspended",
                 "AppID 620 update canceled : Game started (App Running)",
                 "AppID 620 state changed : Update Required,Update Queued,Update Started, (Update Required)",
                 "AppID 620 scheduler finished : removed from schedule (result No Error, state 0x602)"]
        for line in lines:
            with self.subTest(line=line):
                scanner = downloads.SteamScanner(self.clock, self.launchers)
                scanner.note_log_line(line)
                observation = scanner._classify(dict(held), previous)
                self.assertEqual((observation.state, observation.reason), ("held", None))
        for code in (2, 3, 4):
            with self.subTest(code=code):
                observation = downloads.SteamScanner(self.clock, self.launchers)._classify(dict(held, updateResult=code), previous)
                self.assertEqual(observation.state, "held")
        failed = downloads.SteamScanner(self.clock, self.launchers)._classify(dict(held, updateResult=12), previous)
        self.assertEqual((failed.state, failed.reason), ("failed", "Steam reported error 12"))
        # A fresh pause in the log outranks an older error code left in the manifest.
        scanner = downloads.SteamScanner(self.clock, self.launchers)
        scanner.note_log_line("AppID 620 update canceled : Failed updating depot 621 (Disk write failure)")
        scanner.note_log_line("AppID 620 scheduler finished : removed from schedule (result Suspended, state 0x602)")
        self.assertEqual(scanner._classify(dict(held, updateResult=7), previous).state, "held")
        self.assertEqual(downloads.steam_reason_kind(" canceled "), "cancel")
        scanner = downloads.SteamScanner(self.clock, self.launchers)
        scanner.note_log_line("AppID 620 update canceled : ")
        self.assertEqual((scanner._log_failure("620"), scanner._log_pause("620")), (None, "cancel"))
        self.assertEqual(downloads.steam_reason_kind("Disk write failure"), "error")

    def test_removed_from_the_queue_is_dropped_quietly(self):
        self.steam.manifest(620, 1030, to_download=100, downloaded=40, target="300")
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.steam.log("AppID 620 scheduler finished : removed from schedule (result Canceled, state 0x6)")
        self.steam.manifest(620, 6, to_download=100, downloaded=40, target="300", update_result=3)
        self.assertIsNone(self.item(self.poll()))
        for _ in range(14):
            self.poll()
        self.assertEqual(kinds(self.emit), [])  # no "Nothing is downloading" summary either

    def test_stale_pause_codes_on_a_pending_update_are_not_listed(self):
        for code in (2, 3, 4):
            with self.subTest(code=code):
                self.steam.manifest(620, 6, to_download=100, target="300", update_result=code)
                self.assertEqual(self.poll()["downloads"], [])
        self.assertEqual(kinds(self.emit), [])

    def test_steam_closed_means_paused(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.steam.manifest(730, 1026, name="Counter-Strike 2", library=self.steam.root, to_download=100)
        payload = self.poll()
        self.assertEqual((self.item(payload)["state"], self.item(payload, "steam:730")["state"]), ("downloading", "queued"))
        self.launchers.state["steam"] = False  # Steam was closed mid-download: the manifests stay as they were
        payload = self.poll()
        self.assertEqual((self.item(payload)["state"], self.item(payload, "steam:730")["state"], payload["active"]),
                         ("paused", "paused", False))
        self.launchers.state["steam"] = True
        self.steam.manifest(620, 1026, to_download=100, downloaded=40)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.assertNotIn("download.failed", kinds(self.emit))

    def test_ten_minutes_without_progress_is_paused_unless_steam_is_busy(self):
        self.steam.manifest(620, 1026, to_download=100, downloaded=30)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.clock.advance(downloads.STEAM_STALL_SECONDS - 10)
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.assertEqual(self.item(self.poll())["state"], "paused")
        self.launchers.busy["steam"] = True  # still writing (allocating, verifying): not paused
        self.assertEqual(self.item(self.poll())["state"], "downloading")
        self.launchers.busy["steam"] = False
        self.assertEqual(self.item(self.poll())["state"], "paused")
        self.steam.manifest(620, 1026, to_download=100, downloaded=31)
        self.assertEqual(self.item(self.poll())["state"], "downloading")


class EpicTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        base = Path(folder.name)
        self.manifests = base / "Manifests"
        (self.manifests / "Pending").mkdir(parents=True)
        self.install = base / "Epic Games" / "RocketLeague"
        self.staging = self.install / ".egstore" / "bps"
        self.staging.mkdir(parents=True)
        env = patch.dict(os.environ, {"ORBIT_EPIC_MANIFESTS": str(self.manifests),
                                      "ORBIT_EPIC_LAUNCHER_INSTALLED": str(base / "LauncherInstalled.dat"),
                                      "ORBIT_STEAM_PATH": str(base / "no-steam")})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("ORBIT_STEAM_LIBRARIES", None)
        os.environ.pop("ORBIT_GOG_GAMES_KEY", None)
        self.launchers = FakeLaunchers()
        self.watcher, self.emit, self.clock = make_watcher(self, launchers=self.launchers)
        self.watcher.scanners["gog"] = types.SimpleNamespace(present=lambda: False, scan=lambda tracked: [])

    def item_file(self, incomplete, pending=False, guid="ABC123"):
        item = {"FormatVersion": 0, "bIsIncompleteInstall": incomplete, "AppName": "Sugar", "DisplayName": "Rocket League",
                "InstallLocation": str(self.install), "StagingLocation": str(self.staging), "InstallSize": 1000,
                "InstallationGuid": guid}
        path = self.manifests / f"{guid}.item"
        path.write_text("\ufeff" + json.dumps(item), encoding="utf-8")
        os.utime(path, (os.path.getmtime(path) + 1, os.path.getmtime(path) + 1))
        pending_path = self.manifests / "Pending" / f"{guid}.item"
        if pending:
            pending_path.write_text(json.dumps(item), encoding="utf-8")
        elif pending_path.exists():
            pending_path.unlink()

    def poll(self):
        self.watcher.poll()
        self.clock.advance(20)
        return self.watcher.payload()

    def test_incomplete_install_with_estimated_progress_then_finished(self):
        self.assertEqual(self.poll()["downloads"], [])  # Orbit was watching before the download began
        self.item_file(True, pending=True)
        (self.staging / "chunk.bin").write_bytes(b"x" * 250)
        payload = self.poll()
        self.assertEqual(payload["stores"], {"steam": False, "epic": True, "gog": False})
        entry = payload["downloads"][0]
        self.assertEqual((entry["id"], entry["store"], entry["name"], entry["state"]), ("epic:Sugar", "epic", "Rocket League", "downloading"))
        self.assertEqual((entry["progress"], entry["bytesDone"], entry["bytesTotal"]), (0.25, 250, 1000))
        (self.staging / "chunk.bin").write_bytes(b"x" * 5000)  # more than InstallSize: capped below 100 %
        self.assertEqual(self.poll()["downloads"][0]["progress"], 0.99)
        self.item_file(True, pending=False)  # incomplete flag alone still means downloading
        self.assertEqual(self.poll()["downloads"][0]["state"], "downloading")
        self.item_file(False, pending=False)
        payload = self.poll()
        self.assertEqual(payload["downloads"][0]["state"], "finished")
        self.assertEqual(kinds(self.emit), ["download.finished"])
        self.assertEqual(self.emit.call_args.args[1], "Rocket League finished downloading")

    def test_a_half_done_install_from_before_orbit_started_is_paused(self):
        self.item_file(True)
        (self.staging / "chunk.bin").write_bytes(b"x" * 250)
        for _ in range(12):
            payload = self.poll()
            self.assertEqual((payload["downloads"][0]["state"], payload["active"]), ("paused", False))
        self.assertEqual(kinds(self.emit), [])  # never active, so no summary at start either
        (self.staging / "chunk.bin").write_bytes(b"x" * 400)  # resumed in the launcher
        self.assertEqual(self.poll()["downloads"][0]["state"], "downloading")

    def test_no_progress_for_three_minutes_or_a_closed_launcher_is_paused(self):
        self.poll()
        self.item_file(True, pending=True)
        (self.staging / "chunk.bin").write_bytes(b"x" * 100)
        states = [self.poll()["downloads"][0]["state"] for _ in range(10)]  # 20 s per poll
        self.assertEqual(states, ["downloading"] * 9 + ["paused"])
        (self.staging / "chunk.bin").write_bytes(b"x" * 200)
        self.assertEqual(self.poll()["downloads"][0]["state"], "downloading")
        self.launchers.state["epic"] = False
        self.assertEqual(self.poll()["downloads"][0]["state"], "paused")
        self.launchers.state["epic"] = True
        self.assertEqual(self.poll()["downloads"][0]["state"], "downloading")  # the change 40 s ago still counts
        for _ in range(9):
            self.poll()
        self.assertEqual(self.poll()["downloads"][0]["state"], "paused")
        self.launchers.busy["epic"] = True  # verifying or moving files: busy, not paused
        self.assertEqual(self.poll()["downloads"][0]["state"], "downloading")
        self.assertNotIn("download.failed", kinds(self.emit))

    def test_pending_update_of_a_complete_install(self):
        self.item_file(False)
        self.assertEqual(self.poll()["downloads"], [])
        self.item_file(False, pending=True)
        entry = self.poll()["downloads"][0]
        self.assertEqual(entry["state"], "downloading")
        self.assertIsNone(entry["progress"])  # empty staging folder: unknown, not zero
        self.item_file(False, pending=False)
        self.poll()
        self.assertEqual(self.emit.call_args.args[1], "Rocket League finished updating")

    def test_removed_while_downloading_is_dropped(self):
        self.item_file(True, pending=True)
        self.poll()
        (self.manifests / "ABC123.item").unlink()
        (self.manifests / "Pending" / "ABC123.item").unlink()
        self.assertEqual(self.poll()["downloads"], [])
        self.assertEqual(kinds(self.emit), [])


class FakeRegistry(types.SimpleNamespace):
    """Just enough of winreg: {r"HKEY_...\\path": {value: data}}; subkeys are implied by paths."""

    def __init__(self, keys):
        super().__init__(HKEY_LOCAL_MACHINE="HKEY_LOCAL_MACHINE", HKEY_CURRENT_USER="HKEY_CURRENT_USER")
        self.keys = {key.lower(): (key, values) for key, values in keys.items()}

    def OpenKey(self, hive, subkey):
        path = f"{hive}\\{subkey}".lower()
        if path not in self.keys and not any(key.startswith(path + "\\") for key in self.keys):
            raise FileNotFoundError(2, "missing")
        registry = self

        class Handle:
            def __enter__(self):
                return path

            def __exit__(self, *exc):
                return False
        return Handle()

    def QueryValueEx(self, path, name):
        values = self.keys.get(path, ("", {}))[1]
        if name not in values:
            raise FileNotFoundError(2, "missing")
        return values[name], 1

    def EnumKey(self, path, index):
        children = sorted({self.keys[key][0].split("\\")[len(path.split("\\"))] for key in self.keys
                           if key.startswith(path + "\\")})
        if index >= len(children):
            raise OSError(259, "No more data")
        return children[index]

    def EnumValue(self, path, index):
        values = list(self.keys.get(path, ("", {}))[1].items())
        if index >= len(values):
            raise OSError(259, "No more data")
        return values[index][0], values[index][1], 1


class GogTests(unittest.TestCase):
    KEY = r"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\GOG.com\Games"

    def setUp(self):
        self.registry = FakeRegistry({self.KEY + r"\1495134320": {"gameName": "The Witcher 3", "gameID": "1495134320"}})
        patcher = patch.object(downloads, "winreg", self.registry)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = patch.dict(os.environ, {"ORBIT_STEAM_PATH": "/nonexistent/steam", "ORBIT_EPIC_MANIFESTS": "/nonexistent/epic",
                                      "ORBIT_EPIC_LAUNCHER_INSTALLED": "/nonexistent/epic.dat",
                                      "ORBIT_GOG_GAMES_KEY": r"HKLM\SOFTWARE\WOW6432Node\GOG.com\Games"})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("ORBIT_STEAM_LIBRARIES", None)
        self.watcher, self.emit, self.clock = make_watcher(self)

    def test_only_new_installs_are_reported(self):
        self.watcher.poll()
        payload = self.watcher.payload()
        self.assertEqual(payload["stores"], {"steam": False, "epic": False, "gog": True})
        self.assertEqual(payload["downloads"], [])
        self.registry.keys[(self.KEY + r"\1207658924").lower()] = (self.KEY + r"\1207658924", {"gameName": "Cyberpunk 2077"})
        self.clock.advance(5)
        self.watcher.poll()
        entry = self.watcher.payload()["downloads"][0]
        self.assertEqual((entry["id"], entry["store"], entry["name"], entry["state"], entry["progress"]),
                         ("gog:1207658924", "gog", "Cyberpunk 2077", "finished", 1.0))
        self.assertEqual(kinds(self.emit), ["download.finished"])
        self.assertEqual(self.emit.call_args.args[1:], ("Cyberpunk 2077 is installed", "GOG Galaxy finished installing it."))
        self.clock.advance(5)
        self.watcher.poll()
        self.assertEqual(kinds(self.emit), ["download.finished"])


class WatcherTests(unittest.TestCase):
    def test_no_launcher_means_no_polling_until_the_recheck(self):
        calls = []
        scanner = types.SimpleNamespace(present=lambda: calls.append("present") or False, scan=lambda tracked: calls.append("scan") or [])
        clock = Clock()
        watcher = downloads.DownloadsWatcher(monotonic=clock, emit=MagicMock(), scanners={"steam": scanner})
        watcher.poll()
        watcher.poll()
        self.assertEqual(calls, ["present"])
        self.assertIsNotNone(watcher.quiet_since())
        clock.advance(downloads.STORE_RECHECK_SECONDS)
        watcher.poll()
        self.assertEqual(calls, ["present", "present"])
        self.assertEqual(watcher.payload(), {"downloads": [], "active": False, "stores": {"steam": False, "epic": False, "gog": False}})

    def test_a_failing_scanner_does_not_stop_the_others(self):
        broken = types.SimpleNamespace(present=lambda: True, scan=MagicMock(side_effect=OSError("denied")))
        good = types.SimpleNamespace(present=lambda: True, scan=lambda tracked: [
            downloads.Observation("epic:Sugar", "epic", "Rocket League", "downloading", 0.5, 5, 10)])
        watcher = downloads.DownloadsWatcher(monotonic=Clock(), emit=MagicMock(), scanners={"steam": broken, "epic": good})
        with self.assertLogs("orbit.downloads", "ERROR"):
            watcher.poll()
        self.assertEqual([entry["id"] for entry in watcher.payload()["downloads"]], ["epic:Sugar"])

    def test_the_api_answers_while_a_slow_scan_runs(self):
        entered, release = threading.Event(), threading.Event()

        def slow_scan(tracked):
            entered.set()
            release.wait(5)  # a cold disk or a huge Epic staging folder
            return [downloads.Observation("steam:620", "steam", "Portal 2", "downloading", 0.5, 5, 10)]
        watcher = downloads.DownloadsWatcher(monotonic=Clock(), emit=MagicMock(),
                                             scanners={"steam": types.SimpleNamespace(present=lambda: True, scan=slow_scan)})
        worker = threading.Thread(target=watcher.poll)
        worker.start()
        self.assertTrue(entered.wait(5))
        started = time.monotonic()
        self.assertEqual(watcher.payload()["downloads"], [])
        watcher.quiet_since()
        watcher.power_status(0.0)
        watcher.active_ids()
        self.assertLess(time.monotonic() - started, 0.5)
        release.set()
        worker.join(5)
        self.assertEqual(watcher.payload()["downloads"][0]["state"], "downloading")

    def test_thread_runs_and_stops(self):
        import threading
        stop = threading.Event()
        polls = []
        watcher = downloads.DownloadsWatcher(emit=MagicMock(), scanners={}, poll_seconds=0.01)
        watcher.poll = lambda: polls.append(1) or ([], None)
        thread = watcher.start(stop)
        while len(polls) < 1:
            pass
        stop.set()
        thread.join(2)
        self.assertFalse(thread.is_alive())


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock(0.0)
        self.emit = MagicMock(side_effect=lambda *args, **kwargs: {"id": 1})
        self.tracker = downloads.DownloadTracker(clock=Clock(1_790_000_000.0), monotonic=self.clock, emit=self.emit)

    def apply(self, *observations, seconds=5):
        result = self.tracker.apply(list(observations), {"steam"})
        self.clock.advance(seconds)
        return result

    def test_a_canceled_only_download_is_not_announced(self):
        self.apply(downloads.Observation("steam:620", "steam", "Portal 2", "downloading", 0.3, 30, 100))
        self.apply()  # canceled: the manifest is gone
        for _ in range(20):
            self.assertEqual(self.apply(), ([], None))
        self.emit.assert_not_called()
        # The next real download still gets its summary.
        self.apply(downloads.Observation("steam:730", "steam", "Counter-Strike 2", "downloading", 0.5, 5, 10))
        self.apply(downloads.Observation("steam:730", "steam", "Counter-Strike 2", "complete", 1.0, 10, 10, size=10))
        for _ in range(13):
            self.apply()
        self.assertEqual([entry.args[0] for entry in self.emit.call_args_list], ["download.finished", "downloads.allFinished"])
        self.assertEqual(self.emit.call_args.args[1:], ("All downloads finished", "Counter-Strike 2 is ready to play."))

    def test_a_download_paused_before_the_activity_is_not_mentioned(self):
        stale = downloads.Observation("steam:400", "steam", "Portal", "paused", 0.1, 1, 10)
        self.apply(stale)
        self.apply(stale, downloads.Observation("steam:620", "steam", "Portal 2", "downloading", 0.3, 30, 100))
        self.apply(stale, downloads.Observation("steam:620", "steam", "Portal 2", "complete", 1.0, 100, 100, size=100))
        for _ in range(13):
            self.apply(stale)
        self.assertEqual(self.emit.call_args.args[1:], ("All downloads finished", "Portal 2 is ready to play."))
        self.assertEqual(self.emit.call_args.kwargs["data"], {"finished": 1, "failed": 0, "paused": 0})


class PowerStatusTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock(0.0)
        self.seen = []
        scanner = types.SimpleNamespace(present=lambda: True, scan=lambda tracked: list(self.seen))
        self.watcher = downloads.DownloadsWatcher(monotonic=self.clock, clock=Clock(1_790_000_000.0), emit=MagicMock(),
                                                  scanners={"steam": scanner, "gog": types.SimpleNamespace(
                                                      present=lambda: True, scan=lambda tracked: list(self.gog))})
        self.gog = []

    def poll(self, *observations):
        self.seen = list(observations)
        self.watcher.poll()
        self.clock.advance(5)

    def test_only_downloads_since_the_rule_count(self):
        self.assertIsNone(self.watcher.power_status(0.0))
        old = downloads.Observation("steam:400", "steam", "Portal", "paused", 0.1, 1, 10)
        self.poll(old)
        since = self.clock()
        status = self.watcher.power_status(since)
        self.assertEqual((status["active"], status["activeSince"], status["paused"], status["finished"]), (False, False, [], []))
        running = downloads.Observation("steam:620", "steam", "Portal 2", "downloading", 0.3, 30, 100)
        self.poll(old, running)
        self.assertEqual(self.watcher.active_ids(), ["steam:620"])
        status = self.watcher.power_status(since)
        self.assertTrue(status["active"] and status["activeSince"])
        self.poll(old, downloads.Observation("steam:620", "steam", "Portal 2", "paused", 0.3, 30, 100))
        status = self.watcher.power_status(since)
        self.assertEqual((status["active"], status["paused"]), (False, ["Portal 2"]))  # the old pause is not listed
        self.poll(old, downloads.Observation("steam:620", "steam", "Portal 2", "complete", 1.0, 100, 100, size=100))
        status = self.watcher.power_status(since)
        self.assertEqual((status["paused"], status["finished"], status["failed"]), ([], ["Portal 2"], []))
        # A GOG install (GOG only reports finished ones) counts as well.
        later = self.clock()
        self.gog = [downloads.Observation("gog:1", "gog", "The Witcher 3", "installed", 1.0)]
        self.poll(old)
        status = self.watcher.power_status(later)
        self.assertEqual((status["activeSince"], status["finished"]), (True, ["The Witcher 3"]))
        self.assertEqual(status["lastActive"], later)


class LauncherMonitorTests(unittest.TestCase):
    class Process:
        def __init__(self, name, total=0):
            self.info = {"name": name}
            self.total = total

        def io_counters(self):
            return types.SimpleNamespace(read_bytes=self.total, write_bytes=0, other_bytes=0)

    def test_running_and_busy_from_the_process_list(self):
        clock = Clock(0.0)
        processes = [self.Process("explorer.exe")]
        monitor = downloads.LauncherMonitor(clock, process_iter=lambda attrs: list(processes))
        self.assertEqual((monitor.running("steam"), monitor.running("epic")), (False, False))
        steam = self.Process("Steam.exe", 1_000)
        processes.append(steam)
        self.assertFalse(monitor.running("steam"))  # sampled at most every 15 s
        clock.advance(downloads.LAUNCHER_CHECK_SECONDS)
        self.assertTrue(monitor.running("steam"))
        self.assertFalse(monitor.busy_within("steam", 60))  # one sample is not a rate
        clock.advance(15)
        steam.total += 15 * 2_000_000  # 2 MB/s
        self.assertTrue(monitor.busy_within("steam", 60))
        clock.advance(15)  # idle since
        self.assertFalse(monitor.busy_within("steam", 10))
        self.assertTrue(monitor.busy_within("steam", 60))
        processes.append(self.Process("EpicGamesLauncher.exe"))
        clock.advance(15)
        self.assertTrue(monitor.running("epic"))
        broken = downloads.LauncherMonitor(clock, process_iter=MagicMock(side_effect=OSError("denied")))
        self.assertIsNone(broken.running("steam"))  # unknown: never treated as "closed"


class RouteTests(unittest.TestCase):
    def setUp(self):
        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")
        self.watcher = downloads.DownloadsWatcher(monotonic=Clock(), clock=Clock(1_790_000_000.0), emit=MagicMock(), scanners={
            "steam": types.SimpleNamespace(present=lambda: True, scan=lambda tracked: [
                downloads.Observation("steam:620", "steam", "Portal 2", "downloading", 0.42, 42, 100)])})
        self.watcher.poll()
        app = FastAPI()
        app.include_router(downloads.create_downloads_router(verify, lambda: self.watcher))
        self.client = TestClient(app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.http = TestClient(app)
        self.addCleanup(self.http.close)

    def test_contract_shape(self):
        response = self.client.get("/api/downloads", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {
            "downloads": [{"id": "steam:620", "store": "steam", "name": "Portal 2", "state": "downloading", "progress": 0.42,
                           "bytesDone": 42, "bytesTotal": 100, "updatedAt": "2026-09-21T14:13:20Z"}],
            "active": True, "stores": {"steam": True, "epic": False, "gog": False}})

    def test_token_then_https(self):
        self.assertEqual(self.client.get("/api/downloads").status_code, 401)
        self.assertEqual(self.http.get("/api/downloads", headers=AUTH).status_code, 426)


if __name__ == "__main__":
    unittest.main()
