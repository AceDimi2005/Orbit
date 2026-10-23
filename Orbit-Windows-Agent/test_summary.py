"""Monthly summary: Steam/Epic names, game totals and spans, the report and the summary.ready event.

Temporary folders stand in for Steam and Epic, the process lookup is a fake, and clocks are fixed.
"""
import calendar
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_energy as energy
import orbit_settings
import orbit_summary as summary

TOKEN = "test-control-token-at-least-24-chars"


def utc(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%d %H:%M:%S"))


def utc_day(timestamp):
    return time.strftime("%Y-%m-%d", time.gmtime(timestamp))


class Clock:
    def __init__(self, start):
        self.now = float(start)

    def __call__(self):
        return self.now


def acf(appid, name, installdir):
    return ('"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n'
            '\t"LauncherPath"\t\t"C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe"\n\t"StateFlags"\t\t"4"\n}\n') % (appid, name, installdir)


class StoreFolders(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.steam = self.root / "Program Files (x86)" / "Steam"
        self.library = self.root / "D" / "SteamLibrary"
        for library, apps in ((self.steam, [(1245620, "ELDEN RING", "ELDEN RING")]),
                              (self.library, [(1086940, "Baldur's Gate 3", "Baldurs Gate 3")])):
            (library / "steamapps" / "common").mkdir(parents=True)
            for appid, name, folder_name in apps:
                (library / "steamapps" / f"appmanifest_{appid}.acf").write_text(acf(appid, name, folder_name), encoding="utf-8")
                (library / "steamapps" / "common" / folder_name).mkdir()
        self.epic = self.root / "ProgramData" / "Epic" / "EpicGamesLauncher" / "Data" / "Manifests"
        self.epic.mkdir(parents=True)
        self.fortnite = self.root / "Program Files" / "Epic Games" / "Fortnite"
        item = {"DisplayName": "Fortnite", "InstallLocation": str(self.fortnite),
                "LaunchExecutable": "FortniteGame/Binaries/Win64/FortniteLauncher.exe",
                "ProcessNames": ["FortniteClient-Win64-Shipping.exe"], "bIsIncompleteInstall": False}
        (self.epic / "A1B2.item").write_text(json.dumps(item), encoding="utf-8")
        (self.epic / "broken.item").write_text("{", encoding="utf-8")
        environment = patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": os.pathsep.join([str(self.steam), str(self.library)]),
                                              "ORBIT_EPIC_MANIFESTS": str(self.epic)})
        environment.start()
        self.addCleanup(environment.stop)
        registry = patch.object(summary, "_registry_steam_path", return_value=None)
        registry.start()
        self.addCleanup(registry.stop)


class VdfTests(unittest.TestCase):
    def test_nested_blocks_escapes_and_comments(self):
        text = '// header\n"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"\n' \
               '\t\t"label"\t\t"say \\"hi\\""\n\t\t"apps" { "620" "123" }\n\t}\n\t"1"\t"D:\\\\Games"\n}\n'
        data = summary.parse_vdf(text)
        self.assertEqual(data["libraryfolders"]["0"]["path"], "C:\\Program Files (x86)\\Steam")
        self.assertEqual(data["libraryfolders"]["0"]["label"], 'say "hi"')
        self.assertEqual(data["libraryfolders"]["0"]["apps"], {"620": "123"})
        self.assertEqual(data["libraryfolders"]["1"], "D:\\Games")

    def test_broken_text_raises(self):
        for text in ("{ }", '"a" { "b" "c" } }'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                summary.parse_vdf(text)


class SteamLibraryTests(StoreFolders):
    def test_environment_list_wins(self):
        self.assertEqual(summary.steam_libraries(), [str(self.steam), str(self.library)])

    def test_steam_path_and_library_folders_in_both_formats(self):
        vdf = self.steam / "steamapps" / "libraryfolders.vdf"
        escaped = str(self.library).replace("\\", "\\\\")
        vdf.write_text('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n'
                       '\t"contentstatsid"\t"123"\n}\n' % (str(self.steam).replace("\\", "\\\\"), escaped), encoding="utf-8")
        with patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": "", "ORBIT_STEAM_PATH": str(self.steam)}):
            self.assertEqual(summary.steam_libraries(), [str(self.steam), str(self.library)])
        vdf.write_text('"LibraryFolders"\n{\n\t"TimeNextStatsReport"\t"1"\n\t"1"\t"%s"\n}\n' % escaped, encoding="utf-8")
        with patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": "", "ORBIT_STEAM_PATH": str(self.steam)}):
            self.assertEqual(summary.steam_libraries(), [str(self.steam), str(self.library)])

    def test_registry_is_used_without_overrides(self):
        with patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": "", "ORBIT_STEAM_PATH": ""}), \
             patch.object(summary, "_registry_steam_path", return_value=str(self.steam)):
            self.assertEqual(summary.steam_libraries(), [str(self.steam)])
        with patch.dict(os.environ, {"ORBIT_STEAM_LIBRARIES": "", "ORBIT_STEAM_PATH": ""}):
            self.assertEqual(summary.steam_libraries(), [])


class RegistryReaderTests(unittest.TestCase):
    def test_reads_steam_path_or_install_path(self):
        fake = MagicMock()
        fake.HKEY_CURRENT_USER, fake.HKEY_LOCAL_MACHINE = "HKCU", "HKLM"
        fake.OpenKey.return_value.__enter__.return_value = "key"
        fake.QueryValueEx.return_value = ("c:/program files (x86)/steam", 1)
        with patch.object(summary, "winreg", fake):
            self.assertEqual(summary._registry_steam_path(), "c:/program files (x86)/steam")
        fake.OpenKey.assert_called_with("HKCU", r"Software\Valve\Steam")
        fake.OpenKey.side_effect = [OSError("missing"), OSError("missing"), MagicMock(__enter__=lambda s: "k", __exit__=lambda s, *a: False)]
        fake.QueryValueEx.return_value = ("C:\\Program Files (x86)\\Steam", 1)
        with patch.object(summary, "winreg", fake):
            self.assertEqual(summary._registry_steam_path(), "C:\\Program Files (x86)\\Steam")
        with patch.object(summary, "winreg", None):
            self.assertIsNone(summary._registry_steam_path())


class GameNameTests(StoreFolders):
    def names(self, paths):
        clock = Clock(1000)
        resolver = summary.GameNames(process_lookup=lambda process: paths.get(process.lower()), clock=clock)
        return resolver, clock

    def test_steam_epic_and_tidied_names(self):
        elden = self.steam / "steamapps" / "common" / "ELDEN RING" / "Game" / "eldenring.exe"
        bg3 = self.library / "steamapps" / "common" / "Baldurs Gate 3" / "bin" / "bg3.exe"
        fortnite = self.fortnite / "FortniteGame" / "Binaries" / "Win64" / "FortniteClient-Win64-Shipping.exe"
        resolver, _ = self.names({"eldenring.exe": str(elden), "bg3.exe": str(bg3), "fortniteclient-win64-shipping.exe": str(fortnite)})
        self.assertEqual(resolver.display_name("eldenring", "eldenring.exe"), "ELDEN RING")
        self.assertEqual(resolver.display_name("bg3", "bg3.exe"), "Baldur's Gate 3")
        self.assertEqual(resolver.display_name("fortniteclient-win64-shipping", "FortniteClient-Win64-Shipping.exe"), "Fortnite")
        self.assertEqual(resolver.display_name("hogwartslegacy", "HogwartsLegacy.exe"), "Hogwarts Legacy")
        self.assertEqual(resolver.display_name("cs2", None), "CS2")

    def test_windows_style_paths_and_an_install_dir_found_in_another_library(self):
        resolver, _ = self.names({})
        # The exe's own library has no manifest for it, the configured libraries do.
        path = "Z:\\Games\\steamapps\\common\\ELDEN RING\\Game\\eldenring.exe"
        self.assertEqual(resolver.store_name(path), "ELDEN RING")
        self.assertIsNone(resolver.store_name("Z:\\Games\\steamapps\\common\\Unknown\\x.exe"))
        self.assertEqual(resolver.store_name(None, "FortniteLauncher.exe"), "Fortnite")  # LaunchExecutable basename

    def test_games_without_a_store_name_are_retried_after_ten_minutes(self):
        paths = {}
        resolver, clock = self.names(paths)
        self.assertEqual(resolver.display_name("hades", "Hades.exe"), "Hades")
        (self.steam / "steamapps" / "appmanifest_1145360.acf").write_text(acf(1145360, "Hades II", "Hades II"), encoding="utf-8")
        paths["hades.exe"] = str(self.steam / "steamapps" / "common" / "Hades II" / "Hades.exe")
        clock.now += 60
        self.assertEqual(resolver.display_name("hades", "Hades.exe"), "Hades")
        clock.now += summary.NAME_RETRY_SECONDS
        self.assertEqual(resolver.display_name("hades", "Hades.exe"), "Hades II")
        paths.clear()
        clock.now += summary.NAME_RETRY_SECONDS * 10
        self.assertEqual(resolver.display_name("hades", "Hades.exe"), "Hades II")  # store names stay

    def test_lookup_failures_fall_back_to_a_tidied_name(self):
        def broken(process):
            raise PermissionError("access denied")
        resolver = summary.GameNames(process_lookup=broken)
        self.assertEqual(resolver.display_name("cyberpunk2077", "Cyberpunk2077.exe"), "Cyberpunk 2077")

    def test_find_process_exe_matches_the_name_case_insensitively(self):
        processes = [MagicMock(info={"name": "explorer.exe", "exe": "C:\\Windows\\explorer.exe"}),
                     MagicMock(info={"name": "EldenRing.exe", "exe": None}),
                     MagicMock(info={"name": "eldenring.exe", "exe": "D:\\SteamLibrary\\steamapps\\common\\ELDEN RING\\Game\\eldenring.exe"})]
        with patch.object(summary.psutil, "process_iter", return_value=processes):
            self.assertTrue(summary.find_process_exe("ELDENRING.EXE").endswith("eldenring.exe"))
            self.assertIsNone(summary.find_process_exe("missing.exe"))
            self.assertIsNone(summary.find_process_exe(""))


class FakeNames:
    def __init__(self, names=None):
        self.names = names or {}

    def display_name(self, game, process=None):
        return self.names.get(game) or energy.prettify_game_name(process or game)


class TrackerCase(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.wall = Clock(utc("2026-10-10 20:00:00"))
        self.mono = Clock(100)
        self.events = []
        self.allow = True
        self.runtime, self.tracker = self.make_runtime()

    def emit(self, kind, title, body, level="active", data=None, toast=True):
        event = {"kind": kind, "title": title, "body": body, "level": level, "data": data, "toast": toast}
        self.events.append(event)
        return event

    def make_runtime(self):
        ledger = energy.Ledger(self.folder / "ledger.sqlite3")
        tracker = summary.GameTracker(ledger, names=FakeNames({"eldenring": "ELDEN RING"}), emit=self.emit,
                                      alerts_allow=lambda: self.allow, day_of=utc_day)
        runtime = energy.LedgerRuntime(ledger, [energy.EnergyTracker(ledger), tracker],
                                       price_provider=lambda: {"pricePerKWh": 1.0, "currency": "RON"},
                                       settings_provider=lambda: {"baseWatts": 60.0, "psuEfficiency": 1.0},
                                       clock=self.wall, monotonic=self.mono, day_of=utc_day)
        self.addCleanup(runtime.close)
        return runtime, tracker

    def tick(self, seconds=1.0, game="eldenring.exe", runtime=None, **values):
        self.mono.now += seconds
        self.wall.now += seconds
        snapshot = {"telemetryAvailable": True, "activeGameProcess": game, "activeGame": game and game[:-4]}
        snapshot.update(values)
        (runtime or self.runtime).record(snapshot)

    def play(self, seconds, game="eldenring.exe", runtime=None, **values):
        for _ in range(int(seconds)):
            self.tick(1, game, runtime, **values)

    def spans(self, runtime=None):
        (runtime or self.runtime).flush()
        return [dict(row) for row in (runtime or self.runtime).ledger.query("SELECT * FROM game_spans ORDER BY id")]


class GameTrackerTests(TrackerCase):
    def test_play_time_fps_and_temperatures_per_day(self):
        self.tick(0, fps=60, cpuTemp=70, gpuTemp=65)
        self.play(10, fps=120, cpuTemp=80, gpuTemp=75)
        self.tick(1, fps=None, cpuTemp=None, gpuTemp=91)
        self.tick(1, telemetryAvailable=False, fps=999)
        self.runtime.flush()
        row = dict(self.runtime.ledger.query("SELECT * FROM game_daily")[0])
        self.assertEqual((row["day"], row["game"], row["display_name"]), ("2026-10-10", "eldenring", "ELDEN RING"))
        self.assertAlmostEqual(row["play_seconds"], 11)
        self.assertEqual((row["fps_sum"], row["fps_count"]), (60 + 120 * 10, 11))
        self.assertEqual((row["cpu_temp_peak"], row["gpu_temp_peak"]), (80, 91))
        self.assertEqual(row["gpu_temp_count"], 12)

    def test_desktop_time_is_not_play_time(self):
        self.tick(0, game=None)
        self.play(30, game=None)
        self.runtime.flush()
        self.assertEqual(self.runtime.ledger.query("SELECT * FROM game_daily"), [])
        self.assertEqual(self.spans(), [])

    def test_a_span_survives_short_gaps_and_ends_after_five_minutes(self):
        start = self.wall.now
        self.tick(0)
        self.play(60)
        self.play(240, game=None)  # 4 minutes on the desktop, then back
        self.play(60)
        self.play(301, game=None)  # more than 5 minutes: a new session
        self.play(30)
        spans = self.spans()
        self.assertEqual(len(spans), 2)
        self.assertEqual((spans[0]["started_at"], spans[0]["ended_at"]), (start, start + 360))
        self.assertEqual(spans[1]["ended_at"] - spans[1]["started_at"], 29)

    def test_switching_games_starts_a_new_span(self):
        self.tick(0)
        self.play(10)
        self.play(10, game="bg3.exe")
        self.play(10)
        self.assertEqual([span["game"] for span in self.spans()], ["eldenring", "bg3", "eldenring"])

    def test_a_restart_within_five_minutes_continues_the_span(self):
        self.tick(0)
        self.play(100)
        first = self.spans()
        self.runtime.close()
        self.wall.now += 120
        runtime, _ = self.make_runtime()
        self.tick(0, runtime=runtime)
        self.play(50, runtime=runtime)
        spans = self.spans(runtime)
        self.assertEqual(len(spans), 1)
        self.assertEqual(spans[0]["id"], first[0]["id"])
        self.assertEqual(spans[0]["ended_at"] - spans[0]["started_at"], 270)
        runtime.close()
        self.wall.now += 400
        runtime, _ = self.make_runtime()
        self.tick(0, runtime=runtime)
        self.play(5, runtime=runtime)
        self.assertEqual(len(self.spans(runtime)), 2)

    def test_a_span_crossing_midnight_stays_one_session_and_days_split(self):
        self.wall.now = utc("2026-10-10 23:59:00")
        self.tick(0)
        self.play(120)
        self.runtime.flush()
        days = {row["day"]: row["play_seconds"] for row in self.runtime.ledger.query("SELECT * FROM game_daily")}
        self.assertEqual(days, {"2026-10-10": 59, "2026-10-11": 61})
        self.assertEqual(len(self.spans()), 1)

    def test_failed_flush_does_not_lose_or_duplicate_spans(self):
        self.tick(0)
        self.play(10)
        with patch.object(self.runtime.ledger, "transaction", side_effect=energy.sqlite3.OperationalError("locked")), \
             self.assertLogs("orbit.energy", "ERROR"):
            self.assertFalse(self.runtime.flush())
        self.play(10)
        spans = self.spans()
        self.assertEqual(len(spans), 1)
        self.assertEqual(spans[0]["ended_at"] - spans[0]["started_at"], 20)
        self.runtime.flush()
        self.assertEqual(self.runtime.ledger.query("SELECT play_seconds FROM game_daily")[0][0], 20)


class MonthSummaryTests(TrackerCase):
    def seed(self):
        ledger = self.runtime.ledger
        with ledger.transaction() as db:
            rows = [("2026-10-01", "eldenring", "ELDEN RING", 7200, 60 * 7200, 7200, 70 * 7200, 7200, 88, 65 * 7200, 7200, 80),
                    ("2026-10-02", "eldenring", "ELDEN RING", 3600, 55 * 3600, 3600, 0, 0, None, 0, 0, None),
                    ("2026-10-02", "bg3", "Baldur's Gate 3", 5400, 90 * 5400, 5400, 75 * 5400, 5400, 91, 70 * 5400, 5400, 86),
                    ("2026-10-05", "bg3", "Baldur's Gate 3", 30, 0, 0, 0, 0, None, 0, 0, None),
                    ("2026-09-20", "eldenring", "ELDEN RING", 1800, 0, 0, 0, 0, None, 0, 0, None)]
            db.executemany("""INSERT INTO game_daily (day, game, display_name, play_seconds, fps_sum, fps_count, cpu_temp_sum,
                              cpu_temp_count, cpu_temp_peak, gpu_temp_sum, gpu_temp_count, gpu_temp_peak)
                              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", rows)
            energy_rows = [("2026-10-01", "", 500, 0.5, "RON"), ("2026-10-01", "eldenring", 3000, 3.0, "RON"),
                           ("2026-10-02", "bg3", 2000, 0.4, "EUR"), ("2026-09-20", "", 700, 0.7, "RON")]
            db.executemany("INSERT INTO energy_daily (day, game, wall_wh, seconds, cost, currency) VALUES (?, ?, ?, 3600, ?, ?)", energy_rows)
            spans = [("eldenring", "ELDEN RING", utc("2026-10-01 18:00:00"), utc("2026-10-01 20:00:00")),
                     ("bg3", "Baldur's Gate 3", utc("2026-10-02 10:00:00"), utc("2026-10-02 11:30:00")),
                     ("bg3", "Baldur's Gate 3", utc("2026-10-05 10:00:00"), utc("2026-10-05 10:00:30")),
                     ("eldenring", "ELDEN RING", utc("2026-09-30 23:00:00"), utc("2026-10-01 01:00:00"))]
            db.executemany("INSERT INTO game_spans (game, display_name, started_at, ended_at) VALUES (?, ?, ?, ?)", spans)

    def test_report_shape_and_numbers(self):
        self.seed()
        report = summary.month_summary(self.runtime.ledger, 2026, 10, {"pricePerKWh": 1.0, "currency": "RON"}, day_of=utc_day)
        self.assertEqual(report["month"], "2026-10")
        self.assertEqual(report["playSeconds"], 7200 + 3600 + 5400 + 30)
        self.assertEqual(report["daysPlayed"], 2)  # Oct 5 had only 30 s
        self.assertEqual(report["sessions"], 2)  # the 30-second span is not a session; Sept 30 is last month
        top = report["topGame"]
        self.assertEqual((top["game"], top["name"], top["playSeconds"]), ("eldenring", "ELDEN RING", 10800))
        self.assertEqual(top["averageFPS"], round((60 * 7200 + 55 * 3600) / 10800, 1))
        self.assertEqual((top["peakGPUTemp"], top["kWh"], top["cost"]), (80, 3.0, 3.0))
        self.assertEqual([game["game"] for game in report["games"]], ["eldenring", "bg3"])
        bg3 = report["games"][1]
        self.assertEqual((bg3["playSeconds"], bg3["averageFPS"], bg3["peakCPUTemp"], bg3["kWh"], bg3["cost"]),
                         (5430, 90.0, 91, 2.0, 2.0))  # EUR row restated at the current RON price
        self.assertEqual(report["longestSession"], {"game": "eldenring", "name": "ELDEN RING", "seconds": 7200, "date": "2026-10-01"})
        self.assertEqual(report["busiestDay"], {"day": "2026-10-02", "playSeconds": 9000})
        self.assertEqual((report["peakCPUTemp"], report["peakGPUTemp"]), (91, 86))
        self.assertEqual(report["energy"], {"kWh": 5.5, "cost": 5.5, "currency": "RON", "gamingKWh": 5.0, "isEstimate": True})
        self.assertEqual(report["previous"], {"month": "2026-09", "playSeconds": 1800, "kWh": 0.7})
        self.assertEqual(report["available"], ["2026-09", "2026-10"])

    def test_empty_month(self):
        report = summary.month_summary(self.runtime.ledger, 2026, 11, {"pricePerKWh": None, "currency": None}, day_of=utc_day)
        self.assertEqual((report["playSeconds"], report["daysPlayed"], report["sessions"]), (0, 0, 0))
        self.assertIsNone(report["topGame"])
        self.assertIsNone(report["longestSession"])
        self.assertIsNone(report["busiestDay"])
        self.assertEqual(report["energy"], {"kWh": 0.0, "cost": None, "currency": None, "gamingKWh": 0.0, "isEstimate": True})

    def test_spans_are_assigned_to_the_local_month(self):
        self.seed()
        plus_two = lambda ts: utc_day(ts + 2 * 3600)  # Sept 30 23:00 UTC is Oct 1 01:00 local
        report = summary.month_summary(self.runtime.ledger, 2026, 10, {"pricePerKWh": 1.0, "currency": "RON"}, day_of=plus_two)
        self.assertEqual(report["sessions"], 3)

    def test_live_ticks_end_up_in_the_report(self):
        self.tick(0, fps=100, gpuTemp=70, cpuPowerWatts=100, gpuPowerWatts=240)
        self.play(600, fps=100, gpuTemp=70, cpuPowerWatts=100, gpuPowerWatts=240)
        self.runtime.flush()
        report = summary.month_summary(self.runtime.ledger, 2026, 10, {"pricePerKWh": 1.0, "currency": "RON"}, day_of=utc_day)
        self.assertEqual(report["playSeconds"], 600)
        self.assertEqual(report["games"][0]["kWh"], round(400 * 600 / 3600 / 1000, 3))
        self.assertEqual(report["longestSession"]["seconds"], 600)
        self.assertEqual(report["sessions"], 1)


class SummaryReadyTests(TrackerCase):
    def seed_october(self, seconds=7200):
        with self.runtime.ledger.transaction() as db:
            db.execute("INSERT INTO game_daily (day, game, display_name, play_seconds) VALUES ('2026-10-12', 'eldenring', 'ELDEN RING', ?)", (seconds,))
            db.execute("INSERT INTO game_daily (day, game, display_name, play_seconds) VALUES ('2026-10-13', 'bg3', 'Baldur''s Gate 3', 600)")

    def test_announced_once_on_the_first_and_remembered(self):
        self.seed_october()
        event = self.tracker.check_summary_ready(utc("2026-11-01 09:00:00"))
        self.assertEqual(event["kind"], "summary.ready")
        self.assertEqual((event["level"], event["toast"], event["data"]), ("passive", False, {"month": "2026-10"}))
        self.assertEqual(event["title"], "Your October summary is ready")
        self.assertEqual(event["body"], "You played 2 h 10 min in October, most of it ELDEN RING. Open Orbit to see your month.")
        self.assertIsNone(self.tracker.check_summary_ready(utc("2026-11-01 10:00:00")))
        self.assertEqual(self.runtime.ledger.meta(summary.SUMMARY_READY_META), "2026-10")
        restarted = summary.GameTracker(self.runtime.ledger, names=FakeNames(), emit=self.emit, day_of=utc_day)
        self.assertIsNone(restarted.check_summary_ready(utc("2026-11-02 09:00:00")))
        self.assertEqual(len(self.events), 1)

    def test_late_start_within_the_first_week_still_announces(self):
        self.seed_october()
        self.assertIsNone(self.tracker.check_summary_ready(utc("2026-11-08 09:00:00")))
        self.assertIsNotNone(self.tracker.check_summary_ready(utc("2026-11-07 23:00:00")))

    def test_no_play_last_month_means_no_event(self):
        self.seed_october(seconds=20)
        with self.runtime.ledger.transaction() as db:
            db.execute("DELETE FROM game_daily WHERE game = 'bg3'")
        self.assertIsNone(self.tracker.check_summary_ready(utc("2026-11-01 09:00:00")))
        self.assertEqual(self.events, [])
        self.assertIsNone(self.runtime.ledger.meta(summary.SUMMARY_READY_META))

    def test_turned_off_in_alerts_is_marked_without_an_event(self):
        self.seed_october()
        self.allow = False
        self.assertIsNone(self.tracker.check_summary_ready(utc("2026-11-01 09:00:00")))
        self.assertEqual(self.events, [])
        self.assertEqual(self.runtime.ledger.meta(summary.SUMMARY_READY_META), "2026-10")

    def test_alerts_setting_is_read_from_the_shared_store(self):
        store = orbit_settings.SettingsStore(self.folder / "settings.json")
        orbit_settings.set_shared_store(store)
        self.addCleanup(orbit_settings.set_shared_store, None)
        self.assertTrue(summary._alerts_allow_summary())
        store.replace("alerts", {"summary": {"enabled": False}})
        self.assertFalse(summary._alerts_allow_summary())

    def test_the_runtime_announces_after_the_month_turns(self):
        self.wall.now = utc("2026-10-31 23:58:00")
        self.tick(0)
        self.play(240)  # two flushes; the second runs on Nov 1
        self.assertEqual([event["data"] for event in self.events], [{"month": "2026-10"}])
        self.assertIn("all of it ELDEN RING", self.events[0]["body"])


class SummaryRouteTests(TrackerCase):
    def test_route_needs_https_token_runtime_and_a_valid_month(self):
        import orbit_agent as agent
        with patch.object(agent, "API_TOKEN", TOKEN):
            client = TestClient(agent.app, base_url="https://testserver")
            self.addCleanup(client.close)
            headers = {"Authorization": f"Bearer {TOKEN}"}
            self.assertEqual(client.get("/api/summary").status_code, 401)
            with patch.object(energy, "current_runtime", return_value=None):
                self.assertEqual(client.get("/api/summary", headers=headers).status_code, 503)
            self.tick(0)
            self.play(70)
            with patch.object(energy, "current_runtime", return_value=self.runtime), \
                 patch.object(energy, "current_price", return_value={"pricePerKWh": 1.0, "currency": "RON"}):
                self.assertEqual(client.get("/api/summary", params={"month": "2026-00"}, headers=headers).status_code, 422)
                body = client.get("/api/summary", headers=headers).json()
                self.assertEqual(body["month"], "2026-10")
                self.assertEqual(body["playSeconds"], 70)
                self.assertEqual(body["topGame"]["name"], "ELDEN RING")
                for key in ("daysPlayed", "sessions", "games", "longestSession", "busiestDay", "peakCPUTemp", "peakGPUTemp",
                            "energy", "previous", "available"):
                    self.assertIn(key, body)
                energy_body = client.get("/api/energy/summary", params={"month": "2026-10"}, headers=headers).json()
                self.assertEqual(energy_body["games"][0]["name"], "ELDEN RING")
            self.assertEqual(TestClient(agent.app).get("/api/summary", headers=headers).status_code, 426)


if __name__ == "__main__":
    unittest.main()
