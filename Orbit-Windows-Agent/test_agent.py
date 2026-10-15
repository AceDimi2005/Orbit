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
AUTH = {"Authorization": f"Bearer {TOKEN}"}
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
        self.assertEqual(response.json(), {"service": "orbit-agent", "version": 3})

    def test_private_reads_and_mutations_require_auth(self):
        for path in ("/api/status", "/api/specs", "/api/network-info", "/api/sunshine/apps"):
            self.assertEqual(self.client.get(path).status_code, 401)
            self.assertEqual(self.client.get(path, headers={"Authorization": "Bearer wrong"}).status_code, 401)
        for path in ("/api/action/shutdown", "/api/volume?level=55", "/api/input/mouse", "/api/sunshine/launch?app=Example"):
            self.assertEqual(self.client.post(path).status_code, 401)

    def test_stale_status_clears_sensitive_measurements(self):
        state = copy.deepcopy(agent.STATE)
        state.update(cpuTemp=74, fps=120, telemetryAvailable=True)
        with patch.object(agent, "STATE", state), patch.object(agent, "LAST_TELEMETRY", 0):
            result = self.client.get("/api/status", headers=AUTH).json()
            self.assertFalse(result["telemetryAvailable"])
            self.assertIsNone(result["cpuTemp"])
            self.assertIsNone(result["fps"])
            self.assertEqual(state["fps"], 120)  # Endpoint works on a snapshot.

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
             patch.object(agent, "inventory_worker") as inventory, \
             patch.object(agent, "telemetry_worker") as telemetry, \
             patch.object(agent, "sensor_worker") as sensors:
            with TestClient(agent.app) as client:
                self.assertEqual(client.get("/api/status", headers=AUTH).status_code, 200)
            inventory.assert_called_once()
            telemetry.assert_called_once()
            sensors.assert_called_once()
            self.assertTrue(agent.STOP_EVENT.is_set())


class TokenTests(unittest.TestCase):
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
        output = "GPU One, N/A, 15, [Not Supported], 1024, 8192, 555\nGPU Two, 50, 30, nan, 2048, 16384, 556\n"
        with patch.object(hardware.subprocess, "check_output", return_value=output):
            gpus = hardware.nvidia_metrics()
        self.assertEqual(len(gpus), 2)
        self.assertIsNone(gpus[0]["gpuTemp"])
        self.assertIsNone(gpus[0]["gpuPowerWatts"])
        self.assertIsNone(gpus[1]["gpuPowerWatts"])
        self.assertEqual(gpus[1]["vramTotalGB"], 16)
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
