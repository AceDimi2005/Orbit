"""PresentMon regressions; captures and process/foreground APIs are local mocks."""
import csv
import io
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import orbit_hardware as hardware

NOW = 1_000_000
GAME = {"name": "Example", "process": "example.exe", "pid": 42}
V1 = "Application,ProcessID,SwapChainAddress,TimeInSeconds,MsBetweenPresents"


class PresentMonRegressionTests(unittest.TestCase):
    def setUp(self):
        hardware._PRESENTMON_PROGRESS.clear()
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.addCleanup(hardware._PRESENTMON_PROGRESS.clear)

    def capture(self, header=V1, rows=None, age=0):
        rows = rows or [["example.exe", 42, "0x1", 1, 20], ["example.exe", 42, "0x1", 1.02, 20]]
        stream = io.StringIO()
        writer = csv.writer(stream)
        writer.writerow(header.split(","))
        writer.writerows(rows)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        file = Path(directory.name) / "frames.csv"
        file.write_text(stream.getvalue(), encoding="utf-8-sig")
        os.utime(file, (NOW - age, NOW - age))
        return file

    def test_v2_cpu_frame_timing_and_pid_swapchain_isolation(self):
        header = "Application,ProcessID,SwapChainAddress,CPUStartTime,FrameTime,GPUBusy"
        rows = [["example.exe", 42, "0x1", 1000, 20, 2],
                ["example.exe", 42, "0x1", 1020, 20, 2],
                ["example.exe", 99, "0x1", 1020, 1, 2],
                ["example.exe", 42, "0x2", 1020, 1, 2],
                ["browser.exe", 33, "0x1", 1020, 1, 2]]
        result = hardware.read_presentmon(self.capture(header, rows), GAME, now=NOW)
        self.assertEqual(result["fps"], 50)
        self.assertIn("CPU frame", result["fpsSource"])

    def test_current_default_metrics_use_present_interval_not_cpu_busy(self):
        header = "Application,ProcessID,SwapChainAddress,TimeInMs,MsBetweenPresents,CPUStartTimeInMs,MsCPUBusy"
        rows = [["example.exe", 42, "0x1", 1000, 10, 999, 3],
                ["example.exe", 42, "0x1", 1010, 10, 1009, 3]]
        result = hardware.read_presentmon(self.capture(header, rows), GAME, now=NOW)
        self.assertEqual(result["fps"], 100)
        self.assertIn("application", result["fpsSource"])

    def test_v2_time_is_milliseconds_when_other_process_advances(self):
        header = "Application,ProcessID,SwapChainAddress,CPUStartTime,FrameTime"
        rows = [["example.exe", 42, "0x1", 1000, 20],
                ["example.exe", 42, "0x1", 1020, 20],
                ["browser.exe", 99, "0x1", 1800, 10]]
        result = hardware.read_presentmon(self.capture(header, rows), GAME, now=NOW)
        self.assertEqual(result["fps"], 50)
        file = self.capture(header, rows + [["browser.exe", 99, "0x1", 5000, 10]])
        self.assertIsNone(hardware.read_presentmon(file, GAME, now=NOW)["fps"])

    def test_qpc_milliseconds_v2_is_supported_but_raw_ticks_are_not_guessed(self):
        header = "Application,ProcessID,SwapChainAddress,CPUStartQPCTime,FrameTime"
        rows = [["example.exe", 42, "0x1", 800000, 20], ["example.exe", 42, "0x1", 800020, 20]]
        self.assertEqual(hardware.read_presentmon(self.capture(header, rows), GAME, now=NOW)["fps"], 50)
        result = hardware.read_presentmon(self.capture(header.replace("CPUStartQPCTime", "CPUStartQPC"), rows), GAME, now=NOW)
        self.assertIsNone(result["fps"])
        self.assertIn("--qpc_time", result["fpsUnavailableReason"])

    def test_generated_frames_do_not_inflate_cpu_fps(self):
        header = "Application,ProcessID,SwapChainAddress,CPUStartTime,FrameTime,FrameType"
        rows = [["example.exe", 42, "0x1", 1000, 20, "Application"],
                ["example.exe", 42, "0x1", 1020, 20, "Application"],
                ["example.exe", 42, "0x1", 1020, 5, "Intel XeSS-FG"],
                ["example.exe", 42, "0x1", 1030, 5, "Repeated"]]
        self.assertEqual(hardware.read_presentmon(self.capture(header, rows), GAME, now=NOW)["fps"], 50)

    def test_old_mtime_accepts_new_frames_after_observed_progress(self):
        file = self.capture(age=60)
        self.assertIsNone(hardware.read_presentmon(file, GAME, now=NOW)["fps"])
        with file.open("a", encoding="utf-8") as stream:
            stream.write("example.exe,42,0x1,1.04,20\n")
        os.utime(file, (NOW - 60, NOW - 60))
        self.assertEqual(hardware.read_presentmon(file, GAME, now=NOW + 1)["fps"], 50)
        self.assertIsNone(hardware.read_presentmon(file, GAME, now=NOW + 7)["fps"])

    def test_touching_a_stopped_capture_does_not_refresh_old_fps(self):
        file = self.capture()
        self.assertEqual(hardware.read_presentmon(file, GAME, now=NOW)["fps"], 50)
        os.utime(file, (NOW + 10, NOW + 10))
        result = hardware.read_presentmon(file, GAME, now=NOW + 10)
        self.assertIsNone(result["fps"])
        self.assertIn("stale", result["fpsUnavailableReason"])

    def test_other_process_progress_does_not_keep_game_fps_alive(self):
        file = self.capture()
        hardware.read_presentmon(file, GAME, now=NOW)
        with file.open("a", encoding="utf-8") as stream:
            stream.write("browser.exe,99,0x1,1.05,1\n")
        os.utime(file, (NOW + 8, NOW + 8))
        self.assertIsNone(hardware.read_presentmon(file, GAME, now=NOW + 8)["fps"])

    def test_live_foreground_csv_finds_game_outside_launcher_libraries(self):
        process = MagicMock()
        process.name.return_value = "EXAMPLE.exe"
        process.is_running.return_value = True
        with patch.object(hardware, "foreground_pid", return_value=42), \
             patch.object(hardware.psutil, "Process", return_value=process):
            result = hardware.read_presentmon(self.capture(), None, now=NOW)
        self.assertEqual(result["fps"], 50)
        self.assertEqual(result["activeGameProcess"], "example.exe")

    def test_foreground_capture_preferred_to_unfocused_detected_game(self):
        process = MagicMock()
        process.name.return_value = "example.exe"
        process.is_running.return_value = True
        background = {"name": "Other", "process": "other.exe", "pid": 99, "foreground": False}
        with patch.object(hardware, "foreground_pid", return_value=42), \
             patch.object(hardware.psutil, "Process", return_value=process):
            result = hardware.read_presentmon(self.capture(), background, now=NOW)
        self.assertEqual(result["fps"], 50)
        self.assertEqual(result["activeGameProcess"], "example.exe")

    def test_browser_and_pid_reuse_are_not_auto_recognized_as_games(self):
        process = MagicMock()
        process.is_running.return_value = True
        for live_name, csv_name in (("chrome.exe", "chrome.exe"), ("other.exe", "example.exe")):
            with self.subTest(live_name=live_name):
                process.name.return_value = live_name
                rows = [[csv_name, 42, "0x1", 1, 20], [csv_name, 42, "0x1", 1.02, 20]]
                with patch.object(hardware, "foreground_pid", return_value=42), \
                     patch.object(hardware.psutil, "Process", return_value=process):
                    self.assertIsNone(hardware.read_presentmon(self.capture(rows=rows), None, now=NOW)["fps"])

    def test_exited_foreground_process_is_not_shown_from_saved_csv(self):
        process = MagicMock()
        process.name.return_value = "example.exe"
        process.is_running.return_value = False
        with patch.object(hardware, "foreground_pid", return_value=42), \
             patch.object(hardware.psutil, "Process", return_value=process):
            self.assertIsNone(hardware.read_presentmon(self.capture(), None, now=NOW)["fps"])

    def test_setting_alias_works_and_canonical_setting_wins(self):
        file = self.capture()
        with patch.dict(os.environ, {"ORBIT_PRESENTATION_CSV": str(file)}):
            self.assertEqual(hardware.read_presentmon(None, GAME, now=NOW)["fps"], 50)
            with patch.dict(os.environ, {"ORBIT_PRESENTMON_CSV": str(file.parent / "wrong.csv")}):
                result = hardware.read_presentmon(None, GAME, now=NOW)
                self.assertIsNone(result["fps"])
                self.assertIn("does not exist", result["fpsUnavailableReason"])

    def test_diagnostics_without_game_still_explain_missing_capture(self):
        result = hardware.read_presentmon(None, None, now=NOW)
        self.assertIn("ORBIT_PRESENTMON_CSV", result["fpsUnavailableReason"])
        self.assertIn("start", result["fpsUnavailableReason"])

    def test_blank_rows_spaces_and_incomplete_last_record(self):
        file = self.capture(rows=[[" EXAMPLE.EXE ", " 42 ", " 0x1 ", 1, 20],
                                  ["example.exe", 42, "0x1", 1.02, 20]])
        with file.open("a", encoding="utf-8") as stream:
            stream.write("\nexample.exe,42,0x1,1.04,1")
        self.assertEqual(hardware.read_presentmon(file, GAME, now=NOW)["fps"], 50)

    def test_large_capture_tail_keeps_current_frames(self):
        file = self.capture(rows=[["browser.exe", 33, "0x1", .5, 1]] * 30000 +
                                 [["example.exe", 42, "0x1", 1, 20],
                                  ["example.exe", 42, "0x1", 1.02, 20]])
        self.assertGreater(file.stat().st_size, 524288)
        self.assertEqual(hardware.read_presentmon(file, GAME, now=NOW)["fps"], 50)

    def test_game_executable_configuration_normalizes_windows_paths(self):
        processes = [SimpleNamespace(info={"pid": 42, "name": "Example.EXE", "exe": None, "create_time": 1})]
        with patch.dict(os.environ, {"ORBIT_GAME_PROCESSES": " C:\\Custom\\Example.EXE "}), \
             patch.object(hardware.psutil, "process_iter", return_value=processes), \
             patch.object(hardware, "foreground_pid", return_value=42):
            self.assertEqual(hardware.detect_game()["pid"], 42)
            self.assertIsNone(hardware.detect_game({}))


if __name__ == "__main__":
    unittest.main()
