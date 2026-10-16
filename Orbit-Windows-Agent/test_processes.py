"""Process manager tests: every OS process API is mocked; nothing is ended."""

import unittest
import ctypes
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import psutil

import orbit_processes as processes


PID = 200
CREATED = 1700000000.125


def fake_process(pid=PID, created=CREATED, name="Example.exe", username="DESKTOP\\Player"):
    process = MagicMock()
    process.pid = pid
    process.create_time.return_value = created
    process.name.return_value = name
    process.username.return_value = username
    process.status.return_value = psutil.STATUS_RUNNING
    process.parents.return_value = []
    process.wait.return_value = 0
    process.info = {"pid": pid, "name": name, "create_time": created,
                    "memory_info": SimpleNamespace(rss=64 * 1024 * 1024),
                    "cpu_times": SimpleNamespace(user=10, system=2),
                    "status": psutil.STATUS_RUNNING, "username": username}
    return process


class ProcessSnapshotTests(unittest.TestCase):
    def setUp(self):
        processes._cpu_samples.clear()
        processes._gpu_identities.clear()
        self.patchers = [patch.object(processes.os, "getpid", return_value=500),
                         patch.object(processes.psutil, "Process", return_value=fake_process(pid=500)),
                         patch.object(processes.psutil, "process_iter", return_value=[]),
                         patch.object(processes.psutil, "cpu_count", return_value=8)]
        self.mocks = [patcher.start() for patcher in self.patchers]
        self.addCleanup(lambda: [patcher.stop() for patcher in reversed(self.patchers)])

    def test_snapshot_has_no_private_paths_or_command_lines_and_first_cpu_is_unknown(self):
        self.mocks[2].return_value = [fake_process()]
        result = processes.collect_processes()
        self.assertEqual(result["totalCount"], 1)
        row = result["processes"][0]
        self.assertEqual(set(row), {"pid", "name", "createTime", "memoryMB", "cpuPercent", "status", "canTerminate",
                                    "gpuPercent", "vramMB", "sharedGpuMemoryMB", "gpuEngine"})
        self.assertIsNone(row["cpuPercent"])
        self.assertEqual(row["memoryMB"], 64)
        self.assertTrue(row["canTerminate"])
        self.assertFalse(result["truncated"])

    def test_cpu_uses_whole_machine_scale_and_pid_reuse_resets_sample(self):
        process = fake_process()
        self.mocks[2].return_value = [process]
        with patch.object(processes.time, "monotonic", side_effect=[10, 10, 12, 12, 14, 14]):
            processes.collect_processes()
            process.info["cpu_times"] = SimpleNamespace(user=12, system=2)
            self.assertEqual(processes.collect_processes()["processes"][0]["cpuPercent"], 12.5)
            process.info["create_time"] = CREATED + 10
            self.assertIsNone(processes.collect_processes()["processes"][0]["cpuPercent"])
        self.assertEqual(len(processes._cpu_samples), 1)

    def test_missing_creation_time_is_not_selectable_and_missing_metrics_stay_unknown(self):
        unknown = fake_process(pid=300)
        unknown.info["create_time"] = None
        partial = fake_process()
        partial.info.update(memory_info=None, cpu_times=None, username=None)
        self.mocks[2].return_value = [unknown, partial]
        result = processes.collect_processes()
        self.assertEqual(result["totalCount"], 1)
        row = result["processes"][0]
        self.assertIsNone(row["memoryMB"])
        self.assertIsNone(row["cpuPercent"])
        self.assertFalse(row["canTerminate"])

    def test_protected_system_accounts_and_ancestors_cannot_be_ended(self):
        own = self.mocks[1].return_value
        own.parents.return_value = [SimpleNamespace(pid=90)]
        self.mocks[2].return_value = [fake_process(pid=4, name="System"),
                                     fake_process(pid=90), fake_process(pid=500),
                                     fake_process(pid=301, name="CSRSS.EXE"),
                                     fake_process(pid=302, username="NT AUTHORITY\\SYSTEM"),
                                     fake_process(pid=303, username="NT SERVICE\\Example")]
        self.assertTrue(all(not row["canTerminate"] for row in processes.collect_processes()["processes"]))

    def test_unreadable_parent_chain_disables_termination_and_collection_has_deadline(self):
        self.mocks[1].return_value.parents.side_effect = psutil.AccessDenied(500)
        self.mocks[2].return_value = [fake_process(), fake_process(pid=201)]
        with patch.object(processes.time, "monotonic", side_effect=[10, 10, 12]):
            result = processes.collect_processes()
        self.assertTrue(result["truncated"])
        self.assertEqual(result["totalCount"], 1)
        self.assertFalse(result["processes"][0]["canTerminate"])

    def test_gpu_metrics_prime_per_process_lifetime_and_verify_identity(self):
        target = fake_process()
        self.mocks[2].return_value = [target]
        self.mocks[1].side_effect = lambda pid: fake_process(pid=500) if pid == 500 else target
        reading = {PID: {"gpuPercent": 86.5, "vramMB": 1024, "sharedGpuMemoryMB": 30, "gpuEngine": "3D"}}
        with patch.object(processes, "_gpu_snapshot", return_value=(reading, None)):
            self.assertIsNone(processes.collect_processes()["processes"][0]["gpuPercent"])
            row = processes.collect_processes()["processes"][0]
            self.assertEqual(row["gpuPercent"], 86.5)
            self.assertEqual(row["vramMB"], 1024)
            target.create_time.return_value = CREATED + 1
            self.assertIsNone(processes.collect_processes()["processes"][0]["vramMB"])

    def test_unavailable_gpu_is_null_with_a_reason_not_zero(self):
        self.mocks[2].return_value = [fake_process()]
        with patch.object(processes, "_gpu_snapshot", return_value=({}, "GPU driver counters unavailable")):
            result = processes.collect_processes()
        self.assertFalse(result["gpuMetricsAvailable"])
        self.assertIn("unavailable", result["gpuMetricsStatus"])
        self.assertIsNone(result["processes"][0]["gpuPercent"])
        self.assertIsNone(result["processes"][0]["vramMB"])


class GPUCounterTests(unittest.TestCase):
    def test_busiest_engine_and_memory_sum_match_windows_semantics(self):
        reader = processes._WindowsGPUCounters.__new__(processes._WindowsGPUCounters)
        reader.query = ctypes.c_void_p()
        reader.api = MagicMock()
        reader.api.PdhCollectQueryData.return_value = 0
        reader.initialized = False
        reader.counters = {"gpuPercent": 1, "vramMB": 2, "sharedGpuMemoryMB": 3}
        readings = {
            1: [("pid_200_luid_1_phys_0_eng_0_engtype_3D", 70),
                ("pid_200_luid_1_phys_0_eng_1_engtype_Copy", 40),
                ("pid_300_luid_1_phys_0_eng_0_engtype_3D", 4)],
            2: [("pid_200_luid_1_phys_0", 100 * 1024**2), ("pid_200_luid_2_phys_0", 50 * 1024**2),
                ("pid_200_luid_2_phys_0", 50 * 1024**2)],
            3: [("pid_200_luid_1_phys_0", 12 * 1024**2)],
        }
        reader._values = lambda counter: readings[counter]
        self.assertNotIn("gpuPercent", reader.snapshot()[200])
        current = reader.snapshot()[200]
        self.assertEqual(current["gpuPercent"], 70)  # not 110% or an engine average
        self.assertEqual(current["gpuEngine"], "3D")
        self.assertEqual(current["vramMB"], 150)  # distinct adapters, duplicate ignored
        self.assertEqual(current["sharedGpuMemoryMB"], 12)

    def test_native_array_ignores_invalid_values_and_uses_fixed_width_status(self):
        reader = processes._WindowsGPUCounters.__new__(processes._WindowsGPUCounters)
        reader.query = ctypes.c_void_p()
        api = MagicMock(); reader.api = api
        names = [ctypes.create_unicode_buffer("pid_200_luid_1"), ctypes.create_unicode_buffer("pid_300_luid_1")]
        def values(counter, format, size, count, buffer):
            size._obj.value = ctypes.sizeof(processes._PdhItem) * 2; count._obj.value = 2
            if buffer is None:
                return 0x800007D2
            array = ctypes.cast(buffer, ctypes.POINTER(processes._PdhItem))
            for index, status in enumerate((0, 0xC0000BC6)):
                array[index].szName = ctypes.cast(names[index], ctypes.c_wchar_p)
                array[index].FmtValue.CStatus = status
                array[index].FmtValue.doubleValue = 20 + index
            return 0
        api.PdhGetFormattedCounterArrayW.side_effect = values
        self.assertEqual(reader._values(1), [("pid_200_luid_1", 20)])
        self.assertEqual(ctypes.sizeof(processes._PdhValue), 16)

    def test_oversized_native_array_is_never_allocated(self):
        reader = processes._WindowsGPUCounters.__new__(processes._WindowsGPUCounters)
        reader.query = ctypes.c_void_p(); reader.api = MagicMock()
        def values(counter, format, size, count, buffer):
            size._obj.value = 10 * 1024**2
            return 0x800007D2
        reader.api.PdhGetFormattedCounterArrayW.side_effect = values
        self.assertEqual(reader._values(1), [])


class EndTaskTests(unittest.TestCase):
    def setUp(self):
        self.own = fake_process(pid=500)
        self.target = fake_process()
        self.patches = [patch.object(processes.os, "getpid", return_value=500),
                        patch.object(processes.psutil, "Process", side_effect=lambda pid: self.own if pid == 500 else self.target)]
        self.mocks = [patcher.start() for patcher in self.patches]
        self.addCleanup(lambda: [patcher.stop() for patcher in reversed(self.patches)])

    def assert_no_termination(self):
        self.target.terminate.assert_not_called()
        self.target.kill.assert_not_called()

    def test_selected_process_is_ended_and_exit_is_confirmed(self):
        result = processes.terminate_process(PID, CREATED)
        self.target.terminate.assert_called_once_with()
        self.target.wait.assert_called_once_with(timeout=1)
        self.target.kill.assert_not_called()
        self.assertEqual(result, {"pid": PID, "name": "Example.exe", "status": "terminated", "forced": False})

    def test_pid_reuse_is_rejected_before_any_signal(self):
        self.target.create_time.return_value = CREATED + 1
        with self.assertRaisesRegex(ProcessLookupError, "process changed"):
            processes.terminate_process(PID, CREATED)
        self.assert_no_termination()

    def test_system_names_accounts_self_ancestors_and_pid4_are_protected(self):
        self.own.parents.return_value = [SimpleNamespace(pid=90)]
        for pid in (4, 90, 500):
            with self.subTest(pid=pid), self.assertRaises(PermissionError):
                processes.terminate_process(pid, CREATED)
        for name in processes.PROTECTED_NAMES:
            self.target.name.return_value = name.upper()
            with self.subTest(name=name), self.assertRaises(PermissionError):
                processes.terminate_process(PID, CREATED)
        self.target.name.return_value = "Example.exe"
        for username in ("NT AUTHORITY\\SYSTEM", "NT AUTHORITY\\LOCAL SERVICE", "NT AUTHORITY\\NETWORK SERVICE", None):
            self.target.username.return_value = username
            with self.subTest(username=username), self.assertRaises(PermissionError):
                processes.terminate_process(PID, CREATED)
        self.assert_no_termination()

    def test_unknown_identity_invalid_pid_and_unreadable_process_never_end_task(self):
        for pid, created in ((True, CREATED), (0, CREATED), (-1, CREATED), ("200", CREATED),
                             (PID, None), (PID, float("nan")), (PID, float("inf")), (PID, -1)):
            with self.subTest(pid=pid, created=created), self.assertRaises(ValueError):
                processes.terminate_process(pid, created)
        self.target.username.side_effect = psutil.AccessDenied(PID)
        with self.assertRaises(PermissionError):
            processes.terminate_process(PID, CREATED)
        self.assert_no_termination()

    def test_exit_timeout_does_not_claim_success_or_escalate_implicitly(self):
        self.target.wait.side_effect = psutil.TimeoutExpired(1, pid=PID)
        result = processes.terminate_process(PID, CREATED)
        self.assertEqual(result["status"], "terminating")
        self.assertFalse(result["forced"])
        self.target.kill.assert_not_called()

    def test_explicit_force_rechecks_process_identity_before_kill(self):
        replacement = fake_process(created=CREATED + 1)
        self.target.wait.side_effect = psutil.TimeoutExpired(1, pid=PID)
        self.mocks[1].side_effect = [self.own, self.target, self.own, replacement]
        with self.assertRaises(ProcessLookupError):
            processes.terminate_process(PID, CREATED, force=True)
        self.target.terminate.assert_called_once_with()
        self.target.kill.assert_not_called()
        replacement.kill.assert_not_called()

    def test_explicit_force_only_retries_same_safe_application(self):
        retry = fake_process()
        self.target.wait.side_effect = psutil.TimeoutExpired(1, pid=PID)
        self.mocks[1].side_effect = [self.own, self.target, self.own, retry]
        result = processes.terminate_process(PID, CREATED, force=True)
        self.target.terminate.assert_called_once_with()
        retry.kill.assert_called_once_with()
        self.assertTrue(result["forced"])
        self.assertEqual(result["status"], "terminated")

    def test_access_denied_during_termination_is_reported(self):
        self.target.terminate.side_effect = psutil.AccessDenied(PID)
        with self.assertRaisesRegex(PermissionError, "denied permission"):
            processes.terminate_process(PID, CREATED)
        self.target.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
