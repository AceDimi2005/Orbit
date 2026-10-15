"""Integrated route boundaries and a complete history snapshot, no native actions."""
import copy
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient
import orbit_agent as agent


class FeatureWiringTests(unittest.TestCase):
    def test_new_routes_require_main_token_and_https(self):
        paths = ("/api/files/roots", "/api/clipboard", "/api/audio/sessions", "/api/history/sessions")
        token = "test-control-token-at-least-24-chars"
        client = TestClient(agent.app)
        self.addCleanup(client.close)
        with patch.object(agent, "API_TOKEN", token), patch.object(agent, "WIDGET_TOKEN", "widget-only-token"):
            for path in paths:
                with self.subTest(path=path):
                    self.assertEqual(client.get(path).status_code, 401)
                    self.assertEqual(client.get(path, headers={"Authorization": "Bearer widget-only-token"}).status_code, 401)
                    self.assertEqual(client.get(path, headers={"Authorization": f"Bearer {token}"}).status_code, 426)

    def test_recorded_sample_includes_sensor_cache_not_just_cpu_usage_update(self):
        state = copy.deepcopy(agent.STATE)
        state.update(cpuTemp=55, cpuPowerWatts=65, cpuClockMHz=4200, sensorSource="MSI Afterburner")
        stop = Mock()
        stop.wait.side_effect = [False, True]
        recorder = Mock()
        with patch.object(agent, "STATE", state), patch.object(agent, "STOP_EVENT", stop), \
             patch.object(agent, "LAST_SENSOR", 100), patch.object(agent.time, "monotonic", return_value=100), \
             patch.object(agent, "HISTORY_RECORDER", recorder), \
             patch.object(agent.psutil, "virtual_memory", return_value=SimpleNamespace(used=8 * 1024**3, total=16 * 1024**3)), \
             patch.object(agent.psutil, "disk_usage", return_value=SimpleNamespace(used=1, total=2)), \
             patch.object(agent.psutil, "cpu_percent", return_value=42), \
             patch.object(agent, "io_metrics", return_value={}), patch.object(agent, "nvidia_metrics", return_value=[]), \
             patch.object(agent, "detect_game", return_value=None), patch.object(agent, "read_fps", return_value={"fps": None}), \
             patch.object(agent, "audio_metrics", return_value={}):
            agent.telemetry_worker()
        sample = recorder.record_sample.call_args.args[0]
        self.assertEqual(sample["cpuTemp"], 55)
        self.assertEqual(sample["cpuPowerWatts"], 65)
        self.assertEqual(sample["cpuUsage"], 42)
        self.assertTrue(sample["telemetryAvailable"])


if __name__ == "__main__": unittest.main()
