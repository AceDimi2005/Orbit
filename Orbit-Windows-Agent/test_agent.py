"""Safe regression tests: Windows control, sensor and process APIs are mocked."""
import copy
import os
import tempfile
import time
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import orbit_agent as agent
import orbit_hardware as hardware

TOKEN = "test-only-token-with-more-than-24-characters"
WIDGET_TOKEN = "widget-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
WIDGET_AUTH = {"Authorization": f"Bearer {WIDGET_TOKEN}"}
GAME = {"name": "Example", "process": "example.exe", "pid": 42}
HEADER = "Application,ProcessID,SwapChainAddress,TimeInSeconds,MsBetweenPresents\n"


class APITests(unittest.TestCase):
    def setUp(self):
        self.token = patch.object(agent, "API_TOKEN", TOKEN)
        self.token.start()
        self.client = TestClient(agent.app)

    def tearDown(self):
        self.client.close()
        self.token.stop()

    def test_discovery_exposes_identity_only_without_token(self):
        response = self.client.get("/api/discover")
        self.assertEqual(response.status_code, 200)
        public = response.json()
        self.assertEqual(public["service"], "orbit-agent")
        self.assertEqual(public["version"], 3)
        self.assertEqual(set(public), {"service", "version", "agentVersion", "name", "securePort", "fingerprint", "pairingAvailable"})
        self.assertNotIn(TOKEN, response.text)
        self.assertNotIn(WIDGET_TOKEN, response.text)

    def test_private_reads_and_mutations_require_auth(self):
        for path in ("/api/status", "/api/specs", "/api/network-info", "/api/sunshine/apps", "/api/sunshine/info"):
            self.assertEqual(self.client.get(path).status_code, 401)
            self.assertEqual(self.client.get(path, headers={"Authorization": "Bearer wrong"}).status_code, 401)
        for path in ("/api/action/shutdown", "/api/volume?level=55", "/api/input/mouse", "/api/sunshine/launch?app=Example",
                     "/api/sunshine/pin?pin=1234", "/api/sunshine/start"):
            self.assertEqual(self.client.post(path).status_code, 401)
        self.assertEqual(self.client.post("/api/sunshine/credentials", json={"username": "a", "password": "b"}).status_code, 401)
        self.assertEqual(self.client.delete("/api/sunshine/credentials").status_code, 401)

    def test_stale_status_clears_sensitive_measurements(self):
        state = copy.deepcopy(agent.STATE)
        state.update(cpuTemp=74, fps=120, telemetryAvailable=True)
        state.update({key: 42 for key in hardware.RATE_FIELDS + ("cpuPowerWatts", "cpuClockMHz", "cpuFanRPM", "gpuFanPercent")})
        with patch.object(agent, "STATE", state), patch.object(agent, "LAST_TELEMETRY", 0):
            result = self.client.get("/api/status", headers=AUTH).json()
            self.assertFalse(result["telemetryAvailable"])
            self.assertIsNone(result["cpuTemp"])
            self.assertIsNone(result["fps"])
            for key in hardware.RATE_FIELDS + ("cpuPowerWatts", "cpuClockMHz", "cpuFanRPM", "gpuFanPercent"):
                self.assertIsNone(result[key])
            self.assertEqual(state["fps"], 120)  # Endpoint works on a snapshot.

    def test_expired_sensors_clear_while_base_telemetry_is_fresh(self):
        state = copy.deepcopy(agent.STATE)
        state.update(cpuTemp=74, cpuPowerWatts=80, cpuClockMHz=5000, cpuFanRPM=900,
                     cpuClockSource="LibreHardwareMonitor · core average", telemetryAvailable=True, cpuUsage=20)
        with patch.object(agent, "STATE", state), patch.object(agent, "LAST_TELEMETRY", time.monotonic()), \
             patch.object(agent, "LAST_SENSOR", time.monotonic() - 20):
            result = self.client.get("/api/status", headers=AUTH).json()
        self.assertTrue(result["telemetryAvailable"])
        self.assertEqual(result["cpuUsage"], 20)
        self.assertTrue(all(result[field] is None for field in hardware.SENSOR_FIELDS))

    def test_widget_token_is_read_only_and_pairing_requires_control_token(self):
        with patch.object(agent, "WIDGET_TOKEN", WIDGET_TOKEN):
            self.assertEqual(self.client.post("/api/widget/pairing").status_code, 401)
            self.assertEqual(self.client.post("/api/widget/pairing", headers=WIDGET_AUTH).status_code, 401)
            self.assertEqual(self.client.post("/api/widget/pairing", headers=AUTH).json(), {"token": WIDGET_TOKEN})
            self.assertEqual(self.client.get("/api/widget/status", headers=AUTH).status_code, 401)
            self.assertEqual(self.client.get("/api/widget/status").status_code, 401)
            self.assertEqual(self.client.get(f"/api/widget/status?token={WIDGET_TOKEN}").status_code, 401)
            self.assertEqual(self.client.get("/api/widget/status", headers=WIDGET_AUTH).status_code, 200)
            for path in ("/api/status", "/api/specs", "/api/network-info", "/api/sunshine/apps"):
                self.assertEqual(self.client.get(path, headers=WIDGET_AUTH).status_code, 401)
            for path in ("/api/volume?level=50", "/api/action/shutdown", "/api/input/mouse", "/api/sunshine/launch?app=Example"):
                self.assertEqual(self.client.post(path, headers=WIDGET_AUTH).status_code, 401)

    def test_widget_snapshot_uses_original_sample_time_and_minimal_schema(self):
        state = copy.deepcopy(agent.STATE)
        state.update(lastUpdated="2025-01-01T00:00:00+00:00", telemetryAvailable=True,
                     cpuUsage=40, ramUsedGB=16, ramTotalGB=32, cpuPowerWatts=75, activeGame="Example")
        with patch.object(agent, "WIDGET_TOKEN", WIDGET_TOKEN), patch.object(agent, "STATE", state), \
             patch.object(agent, "LAST_TELEMETRY", time.monotonic()), patch.object(agent, "LAST_SENSOR", time.monotonic()):
            result = self.client.get("/api/widget/status", headers=WIDGET_AUTH).json()
        self.assertEqual(result["timestamp"], 1735689600)
        self.assertEqual(result["ram_usage"], 50)
        self.assertEqual(result["cpu_power"], 75)
        self.assertEqual(result["game_name"], "Example")
        self.assertEqual(set(result), {"pc_name", "timestamp", "telemetry_available", "cpu_usage", "gpu_usage", "ram_usage",
                                       "cpu_temp", "gpu_temp", "vram_used", "vram_total", "cpu_power", "gpu_power", "fps", "game_name",
                                       "cpu_clock", "cpu_fan", "gpu_fan", "coolant_temp", "disk_read", "disk_write", "network_download", "network_upload"})

    def test_widget_snapshot_never_relabels_stale_samples_as_live(self):
        state = copy.deepcopy(agent.STATE)
        state.update(lastUpdated="2025-01-01T00:00:00+00:00", telemetryAvailable=True,
                     cpuUsage=40, ramUsedGB=16, ramTotalGB=32, activeGame="Example")
        with patch.object(agent, "WIDGET_TOKEN", WIDGET_TOKEN), patch.object(agent, "STATE", state), \
             patch.object(agent, "LAST_TELEMETRY", 0):
            result = self.client.get("/api/widget/status", headers=WIDGET_AUTH).json()
        self.assertFalse(result["telemetry_available"])
        self.assertEqual(result["timestamp"], 1735689600)
        self.assertTrue(all(value is None for key, value in result.items() if key not in {"pc_name", "timestamp", "telemetry_available"}))

    def test_process_endpoints_require_control_token(self):
        with patch.object(agent, "collect_processes") as collect, patch.object(agent, "terminate_process") as end:
            for headers in ({}, WIDGET_AUTH):
                self.assertEqual(self.client.get("/api/processes", headers=headers).status_code, 401)
                self.assertEqual(self.client.post("/api/processes/42/terminate?expectedCreateTime=100", headers=headers).status_code, 401)
            collect.assert_not_called()
            end.assert_not_called()

    def test_process_snapshot_and_identity_checked_end(self):
        payload = {"processes": [], "capturedAt": 100, "totalCount": 0}
        with patch.object(agent, "require_windows"), patch.object(agent, "collect_processes", return_value=payload), \
             patch.object(agent, "terminate_process", return_value={"pid": 42, "name": "Example", "status": "terminating", "forced": False}) as end:
            self.assertEqual(self.client.get("/api/processes", headers=AUTH).json(), payload)
            response = self.client.post("/api/processes/42/terminate?expectedCreateTime=123.5", headers=AUTH)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["status"], "terminating")
            end.assert_called_once_with(42, 123.5, False)

    def test_process_protection_identity_and_validation_errors(self):
        with patch.object(agent, "require_windows"), patch.object(agent, "terminate_process") as end:
            for error, code in ((PermissionError("protected"), 403), (ProcessLookupError("changed"), 409), (ValueError("invalid"), 422)):
                end.side_effect = error
                response = self.client.post("/api/processes/42/terminate?expectedCreateTime=123.5", headers=AUTH)
                self.assertEqual(response.status_code, code)
            end.reset_mock()
            self.assertEqual(self.client.post("/api/processes/42/terminate", headers=AUTH).status_code, 422)
            self.assertEqual(self.client.post("/api/processes/42/terminate?expectedCreateTime=nan", headers=AUTH).status_code, 422)
            end.assert_not_called()

    def test_empty_specs_are_serializable(self):
        with patch.object(agent, "SPECS", hardware.basic_specs()):
            result = self.client.get("/api/specs", headers=AUTH)
            self.assertEqual(result.status_code, 200)
            self.assertIsNone(result.json()["motherboard"]["model"])
            self.assertEqual(result.json()["gpus"], [])

    def test_unknown_action_is_error(self):
        self.assertEqual(self.client.post("/api/action/not-an-action", headers=AUTH).status_code, 404)

    def test_direct_volume_without_keyboard_ramp(self):
        volume = MagicMock()
        @contextmanager
        def fake_endpoint():
            yield volume
        with patch.object(agent, "require_windows"), patch.object(agent, "endpoint_volume", fake_endpoint), \
             patch.object(agent, "audio_metrics", return_value={"volume": 63.0, "isMuted": False, "volumeAvailable": True}), \
             patch.object(agent.ctypes, "windll", create=True) as win32:
            result = self.client.post("/api/volume?level=63", headers=AUTH)
            self.assertEqual(result.status_code, 200)
            volume.SetMasterVolumeLevelScalar.assert_called_once_with(0.63, None)
            self.assertEqual(result.json()["volume"], 63)
            win32.user32.keybd_event.assert_not_called()

    def test_volume_unavailable_is_503_without_key_fallback(self):
        @contextmanager
        def unavailable():
            raise RuntimeError("no audio endpoint")
            yield
        with patch.object(agent, "require_windows"), patch.object(agent, "endpoint_volume", unavailable), \
             patch.object(agent.ctypes, "windll", create=True) as win32:
            response = self.client.post("/api/volume?level=45", headers=AUTH)
            self.assertEqual(response.status_code, 503)
            win32.user32.keybd_event.assert_not_called()

    def test_volume_out_of_range_rejected(self):
        with patch.object(agent, "require_windows"), patch.object(agent, "endpoint_volume") as endpoint:
            self.assertEqual(self.client.post("/api/volume?level=101", headers=AUTH).status_code, 422)
            endpoint.assert_not_called()

    def test_launch_failure_does_not_claim_game_running(self):
        state = copy.deepcopy(agent.STATE)
        with patch.object(agent, "STATE", state), patch.object(agent, "require_windows"), \
             patch.object(agent, "sunshine_entries", return_value=[]), patch.object(agent.subprocess, "Popen") as launch:
            self.assertEqual(self.client.post("/api/sunshine/launch?app=Missing", headers=AUTH).status_code, 404)
            self.assertIsNone(state["activeGame"])
            launch.assert_not_called()

    def test_sunshine_info_reports_ports_from_config(self):
        with tempfile.TemporaryDirectory() as directory:
            conf = Path(directory) / "sunshine.conf"
            conf.write_text("# comment\nsunshine_name = Living Room PC\nport = 48989\nbroken line\n", encoding="utf-8")
            with patch.object(agent, "SUNSHINE_CONF_PATHS", [conf]), patch.object(agent, "SUNSHINE_APPS_PATHS", [Path(directory) / "apps.json"]), \
                 patch.object(agent, "SUNSHINE_CREDENTIALS_PATH", Path(directory) / "login.json"), \
                 patch.object(agent, "SUNSHINE_EXECUTABLE_PATHS", [Path(directory) / "sunshine.exe"]), \
                 patch.object(agent, "sunshine_running", return_value=True):
                info = self.client.get("/api/sunshine/info", headers=AUTH).json()
        self.assertEqual(info, {"installed": True, "running": True, "httpPort": 48989, "httpsPort": 48984, "webUIPort": 48990,
                                "name": "Living Room PC", "appCount": 0, "canSubmitPin": False, "canStart": False})

    def test_sunshine_login_round_trip_enables_pin_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            login = Path(directory) / "login.json"
            with patch.object(agent, "SUNSHINE_CREDENTIALS_PATH", login), patch.object(agent, "SUNSHINE_CONF_PATHS", []), \
                 patch.object(agent, "SUNSHINE_APPS_PATHS", []), patch.object(agent, "SUNSHINE_EXECUTABLE_PATHS", []), \
                 patch.object(agent, "sunshine_running", return_value=True):
                self.assertEqual(self.client.post("/api/sunshine/credentials", json={"username": " admin ", "password": ""}, headers=AUTH).status_code, 422)
                self.assertEqual(self.client.post("/api/sunshine/pin?pin=1234", headers=AUTH).status_code, 428)
                saved = self.client.post("/api/sunshine/credentials", json={"username": " admin ", "password": "s3cret"}, headers=AUTH)
                self.assertEqual(saved.status_code, 200)
                self.assertEqual(agent.sunshine_credentials(), ("admin", "s3cret"))
                self.assertTrue(self.client.get("/api/sunshine/info", headers=AUTH).json()["canSubmitPin"])
                self.assertEqual(self.client.post("/api/sunshine/pin?pin=12ab", headers=AUTH).status_code, 422)
                with patch.object(agent, "post_sunshine_pin") as forward:
                    response = self.client.post("/api/sunshine/pin?pin=1234&name=Orbit%20on%20iPhone", headers=AUTH)
                    self.assertEqual(response.json(), {"status": "accepted"})
                    forward.assert_called_once_with(("admin", "s3cret"), "1234", "Orbit on iPhone")
                self.assertEqual(self.client.delete("/api/sunshine/credentials", headers=AUTH).json(), {"status": "removed", "canSubmitPin": False})
                self.assertFalse(login.exists())
                self.assertEqual(self.client.post("/api/sunshine/pin?pin=1234", headers=AUTH).status_code, 428)

    def test_pin_forwarding_uses_basic_auth_and_reports_rejections(self):
        captured = {}

        class FakeResponse:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return self.body

        def fake_urlopen(request, timeout, context):
            captured["url"] = request.full_url
            captured["auth"] = request.get_header("Authorization")
            captured["body"] = request.data
            return FakeResponse(b'{"status": true}')

        with patch.object(agent, "sunshine_config", return_value={"port": "48989"}), patch.object(agent.urllib.request, "urlopen", fake_urlopen):
            agent.post_sunshine_pin(("admin", "pa:ss"), "0420", "Orbit on Mac")
        self.assertEqual(captured["url"], "https://127.0.0.1:48990/api/pin")
        self.assertEqual(captured["auth"], "Basic " + __import__("base64").b64encode(b"admin:pa:ss").decode())
        self.assertEqual(__import__("json").loads(captured["body"]), {"pin": "0420", "name": "Orbit on Mac"})

        def rejected(request, timeout, context):
            return FakeResponse(b'{"status": false, "error": "no pending pair request"}')
        with patch.object(agent, "sunshine_config", return_value={}), patch.object(agent.urllib.request, "urlopen", rejected):
            with self.assertRaises(agent.HTTPException) as refused:
                agent.post_sunshine_pin(("admin", "x"), "1111", "Orbit")
            self.assertEqual(refused.exception.status_code, 409)

        def unauthorized(request, timeout, context):
            raise agent.urllib.error.HTTPError(request.full_url, 401, "Unauthorized", {}, None)
        with patch.object(agent, "sunshine_config", return_value={}), patch.object(agent.urllib.request, "urlopen", unauthorized):
            with self.assertRaises(agent.HTTPException) as denied:
                agent.post_sunshine_pin(("admin", "x"), "1111", "Orbit")
            self.assertEqual(denied.exception.status_code, 401)

    def test_start_sunshine_launches_installed_binary_once(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "sunshine.exe"
            with patch.object(agent, "require_windows"), patch.object(agent, "SUNSHINE_EXECUTABLE_PATHS", [missing]), \
                 patch.object(agent, "sunshine_running", return_value=False), patch.object(agent.subprocess, "Popen") as launch:
                self.assertEqual(self.client.post("/api/sunshine/start", headers=AUTH).status_code, 404)
                launch.assert_not_called()
                missing.write_bytes(b"")
                self.assertEqual(self.client.post("/api/sunshine/start", headers=AUTH).json(), {"status": "starting"})
                launch.assert_called_once()
                self.assertEqual(launch.call_args.args[0], [str(missing)])
            with patch.object(agent, "require_windows"), patch.object(agent, "sunshine_running", return_value=True), \
                 patch.object(agent.subprocess, "Popen") as launch:
                self.assertEqual(self.client.post("/api/sunshine/start", headers=AUTH).json(), {"status": "running"})
                launch.assert_not_called()

    def test_sunshine_info_defaults_without_config(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(agent, "SUNSHINE_CONF_PATHS", [Path(directory) / "missing.conf"]), \
                 patch.object(agent, "SUNSHINE_APPS_PATHS", [Path(directory) / "missing.json"]), \
                 patch.object(agent, "SUNSHINE_CREDENTIALS_PATH", Path(directory) / "login.json"), \
                 patch.object(agent, "SUNSHINE_EXECUTABLE_PATHS", [Path(directory) / "sunshine.exe"]), \
                 patch.object(agent, "sunshine_running", return_value=False):
                info = self.client.get("/api/sunshine/info", headers=AUTH).json()
        self.assertEqual((info["installed"], info["running"], info["httpPort"], info["httpsPort"], info["webUIPort"]), (False, False, 47989, 47984, 47990))
        self.assertEqual((info["canSubmitPin"], info["canStart"]), (False, False))
        self.assertNotIn(TOKEN, str(info))

    def test_desktop_entry_requires_moonlight(self):
        with patch.object(agent, "require_windows"), patch.object(agent, "sunshine_entries", return_value=[{"name": "Desktop"}]):
            self.assertEqual(self.client.post("/api/sunshine/launch?app=Desktop", headers=AUTH).status_code, 409)

    def test_websocket_uses_bearer_header_not_query(self):
        with self.assertRaises(WebSocketDisconnect) as unauthorized:
            with self.client.websocket_connect(f"/ws/stream?token={TOKEN}"):
                pass
        self.assertEqual(unauthorized.exception.code, 1008)
        with patch.object(agent, "HAS_SCREEN_CAPTURE", False):
            with self.client.websocket_connect("/ws/stream", headers=AUTH) as websocket:
                with self.assertRaises(WebSocketDisconnect) as unavailable:
                    websocket.receive_bytes()
                self.assertEqual(unavailable.exception.code, 1011)

    def test_lifespan_loads_token_and_joins_workers(self):
        with patch.object(agent, "load_api_token", return_value=TOKEN), \
             patch.object(agent, "load_widget_token", return_value=WIDGET_TOKEN), \
             patch.object(agent, "inventory_worker") as inventory, \
             patch.object(agent, "telemetry_worker") as telemetry, \
             patch.object(agent, "SessionRecorder"), \
             patch.object(agent, "sensor_worker") as sensors:
            with TestClient(agent.app) as client:
                self.assertEqual(client.get("/api/status", headers=AUTH).status_code, 200)
            inventory.assert_called_once()
            telemetry.assert_called_once()
            sensors.assert_called_once()
            self.assertTrue(agent.STOP_EVENT.is_set())


class TokenTests(unittest.TestCase):
    def test_widget_token_is_persistent_separate_and_private(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, "API_TOKEN", TOKEN):
            path = Path(directory) / "widget"
            first = agent.load_widget_token(path)
            self.assertGreaterEqual(len(first), 24)
            self.assertNotEqual(first, TOKEN)
            self.assertEqual(agent.load_widget_token(path), first)
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text(TOKEN)
            with self.assertRaises(RuntimeError):
                agent.load_widget_token(path)

    def test_generated_token_is_persistent_and_env_overrides(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            path = Path(directory) / "token"
            first = agent.load_api_token(path)
            self.assertGreaterEqual(len(first), 24)
            self.assertEqual(agent.load_api_token(path), first)
            with patch.dict(os.environ, {"ORBIT_API_TOKEN": TOKEN}):
                self.assertEqual(agent.load_api_token(path), TOKEN)

    def test_legacy_shared_token_is_rejected(self):
        with patch.dict(os.environ, {"ORBIT_API_TOKEN": "endspec-secret-token"}):
            with self.assertRaises(RuntimeError):
                agent.load_api_token()


class HardwareTests(unittest.TestCase):
    def test_cpu_package_power_never_sums_cores_or_other_packages(self):
        def sensor(name, kind, value, identifier):
            return {"Name": name, "SensorType": kind, "Value": value, "Identifier": identifier}
        sensors = [sensor("CPU Package", "Power", 200, "/intelcpu/1/power/0"),
                   sensor("CPU Cores", "Power", 50, "/intelcpu/0/power/1"),
                   sensor("CPU Package", "Power", 75, "/intelcpu/0/power/0"),
                   sensor("CPU Platform", "Power", 120, "/intelcpu/0/power/4"),
                   sensor("CPU Package", "Power", 999, "/gpu-nvidia/0/power/0"),
                   sensor("CPU Package", "Temperature", 70, "/intelcpu/0/temperature/0"),
                   sensor("CPU Core #1", "Clock", 4000, "/intelcpu/0/clock/1"),
                   sensor("CPU Core #2", "Clock", 5000, "/intelcpu/0/clock/2"),
                   sensor("Bus Speed", "Clock", 100, "/intelcpu/0/clock/0"),
                   sensor("Fan #1", "Fan", 2000, "/lpc/0/fan/0"),
                   sensor("CPU Fan", "Control", 75, "/lpc/0/control/0"),
                   sensor("CPU Fan", "Fan", 900, "/lpc/0/fan/1")]
        result = hardware.librehardware_metrics(sensors)
        self.assertEqual(result["cpuPowerWatts"], 75)
        self.assertEqual(result["cpuTemp"], 70)
        self.assertEqual(result["cpuClockMHz"], 4500)
        self.assertEqual(result["cpuFanRPM"], 900)
        self.assertIn("core average", result["cpuClockSource"])
        self.assertEqual(hardware.librehardware_metrics(list(reversed(sensors))), result)

    def test_missing_wrong_type_and_nonfinite_sensors_remain_unknown(self):
        sensors = [{"Name": "CPU Cores", "SensorType": "Power", "Value": 45, "Identifier": "/amdcpu/0/power/1"},
                   {"Name": "CPU Package", "SensorType": "Power", "Value": "nan", "Identifier": "/amdcpu/0/power/0"},
                   {"Name": "CPU Package", "SensorType": "Power", "Value": -1, "Identifier": "/amdcpu/0/power/0"},
                   {"Name": "Fan #1", "SensorType": "Fan", "Value": 900, "Identifier": "/lpc/0/fan/0"}, None]
        self.assertTrue(all(value is None for value in hardware.librehardware_metrics(sensors).values()))

    def test_clock_fallback_does_not_claim_nominal_windows_clock_is_live(self):
        with patch.object(hardware.os, "name", "nt"), patch.object(hardware, "powershell_json", side_effect=OSError), \
             patch.object(hardware.psutil, "cpu_freq", return_value=SimpleNamespace(current=3200)), \
             patch.object(hardware.platform, "system", return_value="Windows"):
            result = hardware.sensor_metrics()
        self.assertIsNone(result["cpuPowerWatts"])
        self.assertEqual(result["cpuClockMHz"], 3200)
        self.assertEqual(result["cpuClockSource"], "System · nominal clock")

    def test_sensor_worker_failure_clears_prior_power_and_clock(self):
        state = copy.deepcopy(agent.STATE)
        state.update({key: 99 for key in hardware.SENSOR_FIELDS})
        stop = MagicMock()
        stop.is_set.side_effect = [False, True]
        with patch.object(agent, "STATE", state), patch.object(agent, "STOP_EVENT", stop), \
             patch.object(agent, "sensor_metrics", side_effect=RuntimeError("sensor disappeared")):
            agent.sensor_worker()
        self.assertTrue(all(state[key] is None for key in hardware.SENSOR_FIELDS))

    def test_cim_single_object_and_array(self):
        raw = {"cpu": {"Name": " Generic CPU ", "NumberOfCores": 8, "NumberOfLogicalProcessors": 16},
               "gpu": [{"Name": "Generic GPU", "AdapterRAM": 4293918720}],
               "memory": [{"Capacity": str(16 * 1024 ** 3), "ConfiguredClockSpeed": 6000}],
               "board": None, "disk": None}
        specs = hardware.inventory_from_cim(raw, hardware.basic_specs())
        self.assertEqual(specs["cpu"]["name"], "Generic CPU")
        self.assertEqual(specs["memory"]["modules"][0]["capacityGB"], 16)
        self.assertIsNone(specs["gpus"][0]["vramGB"])
        self.assertEqual(specs["disks"], [])

    def test_invalid_and_multi_gpu_readings_do_not_invent_values(self):
        output = "GPU One, N/A, 15, [Not Supported], 1024, 8192, 555, N/A\nGPU Two, 50, 30, nan, 2048, 16384, 556, 35\n"
        with patch.object(hardware.subprocess, "check_output", return_value=output):
            gpus = hardware.nvidia_metrics()
        self.assertEqual(len(gpus), 2)
        self.assertIsNone(gpus[0]["gpuTemp"])
        self.assertIsNone(gpus[0]["gpuPowerWatts"])
        self.assertIsNone(gpus[1]["gpuPowerWatts"])
        self.assertEqual(gpus[1]["vramTotalGB"], 16)
        self.assertIsNone(gpus[0]["gpuFanPercent"])
        self.assertEqual(gpus[1]["gpuFanPercent"], 35)
        with patch.object(hardware.subprocess, "check_output", side_effect=FileNotFoundError):
            self.assertEqual(hardware.nvidia_metrics(), [])

    def test_game_detection_configured_and_launcher_paths(self):
        processes = [SimpleNamespace(info={"pid": 1, "name": "launcher.exe", "exe": "C:/Games/Steam/steamapps/common/Game/launcher.exe", "create_time": 3}),
                     SimpleNamespace(info={"pid": 42, "name": "example.exe", "exe": "D:/Custom/example.exe", "create_time": 1}),
                     SimpleNamespace(info={"pid": 44, "name": "other.exe", "exe": "C:/Steam/steamapps/common/Other/other.exe", "create_time": 2})]
        with patch.object(hardware.psutil, "process_iter", return_value=processes), patch.object(hardware, "foreground_pid", return_value=42):
            game = hardware.detect_game({"example.exe": "Example Game"})
            self.assertEqual(game["name"], "Example Game")
            self.assertEqual(game["pid"], 42)
            self.assertTrue(game["foreground"])

    def test_missing_audio_has_explicit_capability(self):
        with patch.object(agent, "HAS_PYCAW", False):
            self.assertEqual(agent.audio_metrics(), {"volume": 0.0, "isMuted": False, "volumeAvailable": False})

    def test_com_cleanup_even_after_audio_failure(self):
        com = MagicMock()
        audio = MagicMock()
        with patch.object(agent.os, "name", "nt"), patch.object(agent, "HAS_PYCAW", True), \
             patch.object(agent, "comtypes", com, create=True), patch.object(agent, "AudioUtilities", audio, create=True):
            with self.assertRaises(RuntimeError):
                with agent.endpoint_volume():
                    raise RuntimeError("setter failed")
        com.CoInitialize.assert_called_once()
        com.CoUninitialize.assert_called_once()


class IORateTests(unittest.TestCase):
    def disk(self, read, write):
        return {"disk0": SimpleNamespace(read_bytes=read, write_bytes=write)}

    def network(self, sent, received):
        return {"Ethernet": SimpleNamespace(bytes_sent=sent, bytes_recv=received)}

    def test_first_sample_unknown_then_uses_actual_elapsed_time(self):
        rates = hardware.IOCounterRates()
        first = rates.sample(self.disk(1_000_000, 2_000_000), self.network(3_000_000, 4_000_000), now=10)
        self.assertTrue(all(value is None for value in first.values()))
        result = rates.sample(self.disk(6_000_000, 12_000_000), self.network(8_000_000, 14_000_000), now=12.5)
        self.assertEqual(result, {"diskReadMBps": 2, "diskWriteMBps": 4, "networkUploadMBps": 2, "networkDownloadMBps": 4})

    def test_counter_resets_do_not_create_negative_rates_and_recover(self):
        rates = hardware.IOCounterRates()
        rates.sample(self.disk(50_000_000, 20_000_000), self.network(10_000_000, 10_000_000), now=1)
        result = rates.sample(self.disk(1_000_000, 21_000_000), self.network(0, 11_000_000), now=2)
        self.assertIsNone(result["diskReadMBps"])
        self.assertIsNone(result["networkUploadMBps"])
        self.assertEqual(result["diskWriteMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 1)
        recovered = rates.sample(self.disk(3_000_000, 23_000_000), self.network(2_000_000, 13_000_000), now=4)
        self.assertTrue(all(value == 1 for value in recovered.values()))

    def test_missing_and_device_changes_reprime_without_spikes(self):
        rates = hardware.IOCounterRates()
        rates.sample(self.disk(0, 0), self.network(0, 0), now=1)
        result = rates.sample(None, self.network(2_000_000, 4_000_000), now=2)
        self.assertIsNone(result["diskReadMBps"])
        self.assertEqual(result["networkDownloadMBps"], 4)
        changed = {**self.network(4_000_000, 8_000_000), "New adapter": SimpleNamespace(bytes_sent=10**12, bytes_recv=10**12)}
        result = rates.sample(self.disk(10**12, 10**12), changed, now=3)
        self.assertIsNone(result["diskReadMBps"])
        self.assertIsNone(result["diskWriteMBps"])
        self.assertEqual(result["networkUploadMBps"], 2)
        self.assertEqual(result["networkDownloadMBps"], 4)
        result = rates.sample(self.disk(10**12, 10**12), changed, now=3)
        self.assertTrue(all(value is None for value in result.values()))
        result = rates.sample(self.disk(10**12, 10**12), changed, now=4)
        self.assertTrue(all(value == 0 for value in result.values()))

    def test_io_read_failure_preserves_other_group_and_disables_wrap_cache(self):
        rates = hardware.IOCounterRates()
        with patch.object(hardware.psutil, "disk_io_counters", side_effect=OSError) as disks, \
             patch.object(hardware.psutil, "net_io_counters", return_value=self.network(0, 0)) as networks, \
             patch.object(hardware.time, "monotonic", side_effect=[1, 2]):
            hardware.io_metrics(rates)
            networks.return_value = self.network(1_000_000, 2_000_000)
            result = hardware.io_metrics(rates)
        self.assertIsNone(result["diskWriteMBps"])
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 2)
        disks.assert_called_with(perdisk=True, nowrap=False)
        networks.assert_called_with(pernic=True, nowrap=False)


class PresentMonTests(unittest.TestCase):
    def capture(self, text, age=0):
        file = tempfile.NamedTemporaryFile(mode="w", delete=False, encoding="utf-8")
        file.write(text)
        file.close()
        self.addCleanup(lambda: Path(file.name).unlink(missing_ok=True))
        os.utime(file.name, (time.time() - age, time.time() - age))
        return file.name

    def test_application_fps_isolates_pid_and_swapchain(self):
        rows = ["example.exe,42,0x1,1.00,20", "example.exe,42,0x1,1.02,20",
                "example.exe,42,0x2,1.02,100", "example.exe,99,0x1,1.02,1",
                "browser.exe,22,0x1,1.02,1"]
        data = hardware.read_presentmon(self.capture(HEADER + "\n".join(rows) + "\n"), GAME)
        self.assertEqual(data["fps"], 50)
        self.assertIn("application", data["fpsSource"])

    def test_stale_capture_and_wrong_process_do_not_report_fps(self):
        text = HEADER + "example.exe,42,0x1,1.0,20\nexample.exe,42,0x1,1.02,20\n"
        self.assertIsNone(hardware.read_presentmon(self.capture(text, age=10), GAME)["fps"])
        fresh = self.capture(text + "browser.exe,33,0x1,8.0,10\n")
        self.assertIsNone(hardware.read_presentmon(fresh, GAME)["fps"])

    def test_v1_case_and_current_time_ms_formats(self):
        text = HEADER.replace("TimeInSeconds", "TimeInMs").replace("MsBetweenPresents", "msBetweenPresents")
        text += "example.exe,42,0x1,1000,10\nexample.exe,42,0x1,1010,10\n"
        self.assertEqual(hardware.read_presentmon(self.capture(text), GAME)["fps"], 100)

    def test_partial_invalid_and_unsupported_rows(self):
        text = HEADER + "example.exe,42,0x1,1,0\nexample.exe,42,0x1,1.01,nan\nexample.exe,42,0x1,1.02,"
        self.assertIsNone(hardware.read_presentmon(self.capture(text), GAME)["fps"])
        text = "Application,ProcessID,FrameTime\nexample.exe,42,16.6\n"
        data = hardware.read_presentmon(self.capture(text), GAME)
        self.assertIsNone(data["fps"])
        self.assertIn("--v1_metrics", data["fpsUnavailableReason"])
        self.assertIsNone(hardware.read_presentmon("missing.csv", GAME)["fps"])
        self.assertIsNone(hardware.read_presentmon(None, GAME)["fps"])
        self.assertIsNone(hardware.read_presentmon(None, None)["fps"])


if __name__ == "__main__":
    unittest.main()
