"""Integrated route boundaries and a complete history snapshot, no native actions."""
import copy
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient
import orbit_agent as agent


class FeatureWiringTests(unittest.TestCase):
    def test_new_routes_require_main_token_and_https(self):
        paths = ("/api/files/roots", "/api/clipboard", "/api/audio/sessions", "/api/history/sessions", "/api/events",
                 "/api/alerts", "/api/downloads", "/api/tasks", "/api/power/after", "/api/push/status")
        token = "test-control-token-at-least-24-chars"
        client = TestClient(agent.app)
        self.addCleanup(client.close)
        with patch.object(agent, "API_TOKEN", token), patch.object(agent, "WIDGET_TOKEN", "widget-only-token"):
            for path in paths:
                with self.subTest(path=path):
                    self.assertEqual(client.get(path).status_code, 401)
                    self.assertEqual(client.get(path, headers={"Authorization": "Bearer widget-only-token"}).status_code, 401)
                    self.assertEqual(client.get(path, headers={"Authorization": f"Bearer {token}"}).status_code, 426)

    def test_new_actions_require_main_token_and_https_before_doing_anything(self):
        posts = (("/api/input/hotkey", {"keys": ["alt", "f10"]}), ("/api/open-url", {"url": "https://example.com"}),
                 ("/api/tasks", {"pid": 4, "createTime": 1.0, "mode": "exit"}),
                 ("/api/push/register", {"deviceID": "A", "apnsToken": "ab" * 32, "environment": "sandbox", "key": "A" * 44}))
        token = "test-control-token-at-least-24-chars"
        client = TestClient(agent.app)
        self.addCleanup(client.close)
        with patch.object(agent, "API_TOKEN", token), patch.object(agent, "WIDGET_TOKEN", "widget-only-token"), \
             patch.object(agent.orbit_input, "press_chord") as press, patch.object(agent.orbit_links, "open_url") as opened:
            for path, body in posts:
                with self.subTest(path=path):
                    self.assertEqual(client.post(path, json=body).status_code, 401)
                    # Authentication is checked before the body, so a missing body is still 401.
                    self.assertEqual(client.post(path).status_code, 401)
                    self.assertEqual(client.post(path, json=body, headers={"Authorization": "Bearer widget-only-token"}).status_code, 401)
                    self.assertEqual(client.post(path, json=body, headers={"Authorization": f"Bearer {token}"}).status_code, 426)
            press.assert_not_called()
            opened.assert_not_called()

    def test_capabilities_need_the_main_token_on_both_ports_and_list_these_features(self):
        token = "test-control-token-at-least-24-chars"
        with patch.object(agent, "API_TOKEN", token), patch.object(agent, "WIDGET_TOKEN", "widget-only-token"):
            for base_url in ("http://testserver", "https://testserver"):
                client = TestClient(agent.app, base_url=base_url)
                self.addCleanup(client.close)
                with self.subTest(base_url=base_url):
                    self.assertEqual(client.get("/api/capabilities").status_code, 401)
                    self.assertEqual(client.get("/api/capabilities", headers={"Authorization": "Bearer widget-only-token"}).status_code, 401)
                    response = client.get("/api/capabilities", headers={"Authorization": f"Bearer {token}"})
                    self.assertEqual(response.status_code, 200)
                    body = response.json()
                    self.assertEqual(body["agentVersion"], agent.AGENT_VERSION)
                    self.assertTrue({"events", "hotkeys", "openUrl", "alerts", "downloads", "tasks", "powerAfter", "push"} <= set(body["features"]))
                    self.assertEqual(len(body["features"]), len(set(body["features"])))

    def test_every_new_module_is_bundled_into_the_standalone_exe(self):
        from pathlib import Path
        script = (Path(agent.__file__).resolve().parent / "build_exe.bat").read_text(encoding="utf-8")
        for module in ("orbit_capabilities", "orbit_settings", "orbit_notify", "orbit_input", "orbit_events", "orbit_links",
                       "orbit_alerts", "orbit_downloads", "orbit_tasks", "orbit_power_after", "orbit_push"):
            with self.subTest(module=module):
                self.assertIn(f'--hidden-import "{module}"', script)

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
