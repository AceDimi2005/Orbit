"""RTSS SDK byte-layout fixtures; no running game or Windows mapping required."""
import os
import struct
import unittest
from unittest.mock import MagicMock, call, patch

import psutil

import orbit_rtss as rtss

GAME = {"name": "Example Game", "process": "example.exe", "pid": 42, "foreground": True}


def mapping(entries=None, version=0x00020014, entry_size=512, offset=128):
    entries = entries if entries is not None else [{"pid": 42, "name": "example.exe"}]
    data = bytearray(offset + entry_size * len(entries))
    struct.pack_into("<9I", data, 0, 0x52545353, version, entry_size, offset, len(entries), 512, 36, 0, 0)
    for index, entry in enumerate(entries):
        start = offset + index * entry_size
        struct.pack_into("<I", data, start, entry.get("pid", 42))
        name = entry.get("name", "example.exe").encode("cp1252")[:259]
        data[start + 4:start + 4 + len(name)] = name
        struct.pack_into("<5I", data, start + 264, 7,
                         entry.get("time0", 1000), entry.get("time1", 2000),
                         entry.get("frames", 60), entry.get("frame_time", 16667))
        if entry_size >= 316:
            # Benchmark/session statistics deliberately disagree with live FPS.
            struct.pack_into("<8I", data, start + 284, 1, 100, 2000, 999999, 100, 9999, 9999, 9999)
    return bytes(data)


class RTSSParserTests(unittest.TestCase):
    def test_reads_sdk_prefix_and_ignores_old_benchmark_statistics(self):
        snapshot = mapping()
        self.assertEqual(snapshot[:4], b"SSTR")
        result = rtss.parse_rtss(snapshot, tick_ms=2100)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["pid"], 42)
        self.assertEqual(result[0]["process"], "example.exe")
        self.assertEqual(result[0]["fps"], 60)

    def test_header_offsets_and_variable_entry_sizes_are_respected(self):
        snapshot = mapping([{"pid": 12, "name": "other.exe", "frames": 144},
                            {"pid": 42, "name": "C:\\Games\\Example.EXE", "frames": 30}],
                           entry_size=1024, offset=256)
        result = rtss.parse_rtss(snapshot, tick_ms=2001)
        self.assertEqual([(entry["pid"], entry["fps"]) for entry in result], [(12, 144), (42, 30)])
        self.assertEqual(result[1]["process"], "example.exe")

    def test_old_v2_prefix_and_future_minor_version_are_compatible(self):
        for version in (0x00020000, 0x00020005, 0x00020014, 0x000200FF):
            with self.subTest(version=version):
                snapshot = mapping(version=version, entry_size=284, offset=36)
                self.assertEqual(rtss.parse_rtss(snapshot, tick_ms=2000)[0]["fps"], 60)

    def test_bad_signatures_versions_and_truncation_are_rejected(self):
        for signature, version in ((0xDEAD, 0x00020014), (0, 0x00020014),
                                   (0x52545353, 0x00010003), (0x52545353, 0x00030000)):
            snapshot = bytearray(mapping())
            struct.pack_into("<2I", snapshot, 0, signature, version)
            with self.assertRaises(ValueError):
                rtss.parse_rtss(snapshot)
        for data in (b"", bytes(35), mapping()[:-1]):
            with self.assertRaises(ValueError):
                rtss.parse_rtss(data)

    def test_array_overflow_undersized_entries_and_oversized_snapshots_rejected(self):
        for field, value in ((8, 280), (12, 4), (12, 0xFFFFFFF0), (16, 4097), (16, 0xFFFFFFFF)):
            snapshot = bytearray(mapping())
            struct.pack_into("<I", snapshot, field, value)
            with self.assertRaises(ValueError):
                rtss.parse_rtss(snapshot)
        with self.assertRaises(ValueError):
            rtss.parse_rtss(bytes(rtss.MAX_MAPPING_BYTES + 1))

    def test_inactive_invalid_and_unterminated_names_are_skipped(self):
        for entry in ({"pid": 0}, {"name": ""}, {"time0": 0}, {"time1": 1000},
                      {"time1": 999}, {"frames": 0}, {"frames": 0xFFFFFFFF}):
            with self.subTest(entry=entry):
                self.assertEqual(rtss.parse_rtss(mapping([entry])), [])
        snapshot = bytearray(mapping())
        snapshot[132:392] = b"x" * 260
        self.assertEqual(rtss.parse_rtss(snapshot), [])

    def test_measurement_duration_and_age_handle_unsigned_tick_wrap(self):
        snapshot = mapping([{"time0": 0xFFFFFF00, "time1": 744, "frames": 60}])
        self.assertEqual(rtss.parse_rtss(snapshot, tick_ms=800)[0]["fps"], 60)
        self.assertEqual(rtss.parse_rtss(snapshot, tick_ms=6000), [])

    def test_stop_and_future_timestamp_do_not_produce_live_fps(self):
        self.assertEqual(rtss.parse_rtss(mapping(), tick_ms=8000), [])
        self.assertEqual(rtss.parse_rtss(mapping(), tick_ms=1000), [])
        self.assertEqual(rtss.parse_rtss(mapping([{"time0": 0xFFFFF000, "time1": 0xFFFFFF00}]), tick_ms=8000), [])

    def test_one_windows_timer_tick_of_uptime_skew_is_tolerated(self):
        self.assertEqual(rtss.parse_rtss(mapping(), tick_ms=1984)[0]["fps"], 60)

    def test_freshness_clock_cannot_be_nan_or_negative(self):
        for tick in (-1, float("nan"), True):
            with self.assertRaises(ValueError):
                rtss.parse_rtss(mapping(), tick_ms=tick)


class RTSSReaderTests(unittest.TestCase):
    def setUp(self):
        rtss._PROGRESS.clear()
        self.addCleanup(rtss._PROGRESS.clear)
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.process = MagicMock()
        self.process.name.return_value = "Example.EXE"
        self.process.status.return_value = psutil.STATUS_RUNNING
        self.process.is_running.return_value = True
        self.process.create_time.return_value = 100
        self.mapping_patch = patch.object(rtss, "read_mapping", return_value=mapping())
        self.mapping_mock = self.mapping_patch.start()
        self.addCleanup(self.mapping_patch.stop)
        self.process_patch = patch.object(rtss.psutil, "Process", return_value=self.process)
        self.process_mock = self.process_patch.start()
        self.addCleanup(self.process_patch.stop)
        self.tick_patch = patch.object(rtss, "_tick_count_ms", return_value=2100)
        self.tick_mock = self.tick_patch.start()
        self.addCleanup(self.tick_patch.stop)
        self.foreground_patch = patch.object(rtss, "foreground_pid", return_value=42)
        self.foreground_mock = self.foreground_patch.start()
        self.addCleanup(self.foreground_patch.stop)

    def test_reads_existing_mapping_only_and_returns_known_game_fps(self):
        result = rtss.read_rtss(GAME, now=1)
        self.assertEqual(self.mapping_mock.call_args_list, [
            call("RTSSSharedMemoryV2", max_bytes=36),
            call("RTSSSharedMemoryV2", max_bytes=128 + 512)])
        self.assertEqual(result["fps"], 60)
        self.assertIn("RTSS", result["fpsSource"])
        self.assertIsNone(result["fpsUnavailableReason"])

    def test_large_unused_osd_region_is_not_requested(self):
        snapshot = mapping() + b"unused OSD" * 1000
        self.mapping_mock.side_effect = lambda name, max_bytes: snapshot[:max_bytes]
        self.assertEqual(rtss.read_rtss(GAME, now=1)["fps"], 60)
        self.assertEqual(self.mapping_mock.call_args_list[-1].kwargs["max_bytes"], len(mapping()))

    def test_invalid_header_cannot_request_large_memory_copy(self):
        invalid = bytearray(mapping())
        struct.pack_into("<I", invalid, 16, 0xFFFFFFFF)
        self.mapping_mock.return_value = bytes(invalid[:36])
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])
        self.mapping_mock.assert_called_once_with("RTSSSharedMemoryV2", max_bytes=36)

    def test_changed_layout_between_header_and_array_is_rejected(self):
        self.mapping_mock.side_effect = [mapping()[:36], mapping(offset=256)]
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])

    def test_unavailable_or_invalid_mapping_explains_required_rtss(self):
        for error in (OSError("not running"), ValueError("corrupt")):
            self.mapping_mock.side_effect = error
            result = rtss.read_rtss(GAME, now=1)
            self.assertIsNone(result["fps"])
            self.assertIn("RTSS", result["fpsUnavailableReason"])
            self.assertIn("MSI Afterburner", result["fpsUnavailableReason"])

    def test_per_pid_isolation_does_not_use_another_game_or_browser(self):
        self.mapping_mock.return_value = mapping([{"pid": 99, "name": "example.exe", "frames": 240},
                                                 {"pid": 43, "name": "chrome.exe", "frames": 500},
                                                 {"pid": 42, "name": "example.exe", "frames": 75}])
        self.assertEqual(rtss.read_rtss(GAME, now=1)["fps"], 75)

    def test_foreground_custom_install_is_identified_and_names_returned(self):
        result = rtss.read_rtss(now=1)
        self.assertEqual(result["fps"], 60)
        self.assertEqual(result["activeGame"], "example")
        self.assertEqual(result["activeGameProcess"], "example.exe")

    def test_foreground_is_preferred_over_background_detected_game(self):
        background = dict(GAME, pid=99, process="other.exe", foreground=False)
        result = rtss.read_rtss(background, now=1)
        self.assertEqual(result["fps"], 60)
        self.assertEqual(result["activeGameProcess"], "example.exe")

    def test_unfocused_missing_pid_does_not_guess_busiest_capture(self):
        self.foreground_mock.return_value = 77
        self.assertIsNone(rtss.read_rtss(now=1)["fps"])
        self.assertIsNone(rtss.read_rtss(dict(GAME, pid=99), now=1)["fps"])

    def test_pid_reused_for_different_exe_and_exited_or_zombie_game_rejected(self):
        self.process.name.return_value = "other.exe"
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])
        self.process.name.return_value = "example.exe"
        self.process.is_running.return_value = False
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])
        self.process.is_running.return_value = True
        self.process.status.return_value = psutil.STATUS_ZOMBIE
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])

    def test_unreadable_or_missing_process_identity_never_reports_fps(self):
        self.process_mock.side_effect = psutil.AccessDenied(42)
        self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])
        self.process_mock.side_effect = None
        for created in (None, float("nan"), 0):
            self.process.create_time.return_value = created
            self.assertIsNone(rtss.read_rtss(GAME, now=1)["fps"])

    def test_browser_desktop_and_helpers_are_not_auto_detected(self):
        for name in ("chrome.exe", "dwm.exe", "gamehelper.exe", "launcher.exe", "steam.exe"):
            with self.subTest(name=name):
                self.mapping_mock.return_value = mapping([{"name": name}])
                self.process.name.return_value = name
                self.assertIsNone(rtss.read_rtss(now=1)["fps"])

    def test_user_explicitly_configured_process_can_override_desktop_filter(self):
        self.mapping_mock.return_value = mapping([{"name": "gamehelper.exe"}])
        self.process.name.return_value = "gamehelper.exe"
        with patch.dict(os.environ, {"ORBIT_GAME_PROCESSES": " C:\\Games\\GameHelper.exe "}):
            self.assertEqual(rtss.read_rtss(now=1)["fps"], 60)

    def test_stopped_measurement_expires_even_if_game_still_alive(self):
        self.assertEqual(rtss.read_rtss(GAME, now=1)["fps"], 60)
        self.tick_mock.return_value = 8000
        result = rtss.read_rtss(GAME, now=7)
        self.assertIsNone(result["fps"])

    def test_frozen_samples_expire_and_new_measurements_recover(self):
        self.assertEqual(rtss.read_rtss(GAME, now=1)["fps"], 60)
        self.assertIsNone(rtss.read_rtss(GAME, now=7)["fps"])
        self.mapping_mock.return_value = mapping([{"time0": 2000, "time1": 3000, "frames": 120}])
        self.tick_mock.return_value = 3100
        self.assertEqual(rtss.read_rtss(GAME, now=8)["fps"], 120)

    def test_app_exit_and_server_exit_clear_fps_immediately(self):
        self.assertEqual(rtss.read_rtss(GAME, now=1)["fps"], 60)
        self.process.is_running.return_value = False
        self.assertIsNone(rtss.read_rtss(GAME, now=1.1)["fps"])
        self.mapping_mock.side_effect = OSError("server closed")
        self.assertIsNone(rtss.read_rtss(GAME, now=1.2)["fps"])
        self.assertEqual(rtss._PROGRESS, {})

    def test_invalid_monotonic_clock_returns_unavailable(self):
        self.assertIsNone(rtss.read_rtss(GAME, now=float("nan"))["fps"])


if __name__ == "__main__":
    unittest.main()
