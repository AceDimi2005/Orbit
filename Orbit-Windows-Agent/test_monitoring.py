"""Integration regressions for source selection; no physical device access."""
import copy
import unittest
from unittest.mock import patch

import orbit_agent as agent
import check_monitoring as monitoring


class GPUIntegrationTests(unittest.TestCase):
    def test_nvidia_never_mixes_with_another_adapter(self):
        cache = {"gpuName": "Intel GPU", "gpuTemp": 60, "gpuPowerWatts": 12, "gpuSource": "LHM"}
        result = agent.select_gpu_metrics([{"gpuName": "NVIDIA GPU", "gpuTemp": None, "gpuUsage": 50, "driverVersion": "1"}], cache, 1)
        self.assertEqual(result["gpuName"], "NVIDIA GPU")
        self.assertIsNone(result["gpuTemp"])
        self.assertIsNone(result["gpuPowerWatts"])
        self.assertEqual(result["gpuSource"], "NVIDIA SMI")
        self.assertNotIn("driverVersion", result)

    def test_lhm_supports_non_nvidia_but_expired_values_are_hidden(self):
        cache = {"gpuName": "AMD GPU", "gpuTemp": 62, "gpuPowerWatts": 90, "gpuSource": "LHM HTTP"}
        fresh = agent.select_gpu_metrics([], cache, 2)
        self.assertEqual(fresh["gpuTemp"], 62)
        self.assertEqual(fresh["gpuName"], "AMD GPU")
        self.assertTrue(all(value is None for value in agent.select_gpu_metrics([], cache, 16).values()))

    def test_sensor_worker_caches_gpu_without_clobbering_driver(self):
        state = copy.deepcopy(agent.STATE)
        state.update(gpuTemp=70, gpuName="NVIDIA GPU", gpuSource="NVIDIA SMI")
        readings = {"cpuTemp": 55, "gpuTemp": 45, "gpuSensorName": "Intel GPU", "sensorSource": "LHM HTTP", "sensorStatus": "Connected"}
        with patch.object(agent, "STATE", state), patch.object(agent, "SENSOR_GPU_CACHE", {}), \
             patch.object(agent, "sensor_metrics", return_value=readings), \
             patch.object(agent.STOP_EVENT, "is_set", side_effect=[False, True]), \
             patch.object(agent.STOP_EVENT, "wait"):
            agent.sensor_worker()
            self.assertEqual(agent.SENSOR_GPU_CACHE["gpuTemp"], 45)
            self.assertEqual(state["gpuTemp"], 70)
            self.assertEqual(state["cpuTemp"], 55)
            self.assertEqual(state["sensorSource"], "LHM HTTP")

    def test_old_gpu_cache_does_not_hide_new_driver_data(self):
        result = agent.select_gpu_metrics([{"gpuName": "NVIDIA", "gpuTemp": 60}], {"gpuTemp": 20}, 200)
        self.assertEqual(result["gpuTemp"], 60)


class SensorExpiryTests(unittest.TestCase):
    def snapshot(self, *, sensor_age=16, telemetry_age=1, gpu_source="LibreHardwareMonitor · HTTP"):
        state = copy.deepcopy(agent.STATE)
        state.update(cpuTemp=55, cpuPowerWatts=40, gpuTemp=65, gpuPowerWatts=100,
                     vramUsedGB=4, gpuSource=gpu_source, telemetryAvailable=True,
                     sensorSource="LibreHardwareMonitor · HTTP", sensorStatus="Temperature sensors connected.")
        with patch.object(agent, "STATE", state), patch.object(agent, "LAST_TELEMETRY", 100 - telemetry_age), \
             patch.object(agent, "LAST_SENSOR", 100 - sensor_age), \
             patch.object(agent.time, "monotonic", return_value=100):
            return agent.status_snapshot()

    def test_expired_sensor_cache_clears_lhm_gpu_and_provider_status(self):
        result = self.snapshot()
        self.assertTrue(result["telemetryAvailable"])
        self.assertTrue(all(result[key] is None for key in agent.SENSOR_FIELDS + agent.GPU_SENSOR_FIELDS))
        self.assertIsNone(result["sensorSource"])
        self.assertIsNone(result["gpuSource"])
        self.assertIn("expired", result["sensorStatus"])

    def test_expired_sensors_preserve_fresh_nvidia(self):
        result = self.snapshot(gpu_source="NVIDIA SMI")
        self.assertIsNone(result["cpuTemp"])
        self.assertIsNone(result["sensorSource"])
        self.assertEqual(result["gpuTemp"], 65)
        self.assertEqual(result["gpuPowerWatts"], 100)
        self.assertEqual(result["gpuSource"], "NVIDIA SMI")

    def test_expired_provider_status_clears_even_when_main_telemetry_expired(self):
        result = self.snapshot(telemetry_age=11)
        self.assertFalse(result["telemetryAvailable"])
        self.assertIsNone(result["sensorSource"])
        self.assertIn("expired", result["sensorStatus"])

    def test_fresh_hardware_monitor_readings_remain_available(self):
        result = self.snapshot(sensor_age=2)
        self.assertEqual(result["cpuTemp"], 55)
        self.assertEqual(result["gpuTemp"], 65)
        self.assertEqual(result["sensorSource"], "LibreHardwareMonitor · HTTP")
        self.assertEqual(result["sensorStatus"], "Temperature sensors connected.")


class MonitoringDiagnosticTests(unittest.TestCase):
    def test_frame_progress_is_sampled_on_both_sides_of_wait(self):
        events = []
        first_game = {"pid": 1, "process": "first.exe"}
        second_game = {"pid": 2, "process": "second.exe"}
        fresh_frames = {"fps": 120, "fpsSource": "PresentMon · application FPS"}
        def frames(path, game):
            events.append(("frames", path, game))
            return {"fps": None} if len(events) == 1 else fresh_frames
        with patch.object(monitoring, "sensor_metrics", return_value={}), \
             patch.object(monitoring, "io_metrics", return_value={}), \
             patch.object(monitoring, "nvidia_metrics", return_value=[]), \
             patch.object(monitoring, "detect_game", side_effect=[first_game, second_game]), \
             patch.object(monitoring, "read_presentmon", side_effect=frames), \
             patch.object(monitoring.time, "sleep", side_effect=lambda seconds: events.append(("wait", seconds))), \
             patch.dict(monitoring.os.environ, {"ORBIT_PRESENTMON_CSV": "C:/live.csv"}):
            result = monitoring.monitoring_report()
        self.assertEqual(events, [("frames", "C:/live.csv", first_game), ("wait", 1.1),
                                  ("frames", "C:/live.csv", second_game)])
        self.assertEqual(result["frames"], fresh_frames)


if __name__ == "__main__":
    unittest.main()
