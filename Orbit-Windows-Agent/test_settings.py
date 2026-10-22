"""settings.json: monitoring options that replaced environment variables, and the local window
server running next to the device ports (and staying optional)."""
import asyncio
import json
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import unittest

from fastapi import FastAPI
import httpx

import orbit_settings as settings_module
import orbit_tls as tls


class MonitoringSettingsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "settings.json"

    def tearDown(self):
        self.folder.cleanup()

    def test_values_are_validated_and_handed_to_the_monitoring_code(self):
        environ = {}
        settings = settings_module.Settings(self.path, environ=environ)
        result = settings.update_monitoring({"gameProcesses": ["EldenRing.exe", "eldenring.exe", " ", "witcher3.exe"],
                                             "networkInterface": "Ethernet", "presentMonCSV": r"C:\Orbit\presentmon.csv"})
        self.assertEqual(result["gameProcesses"], ["EldenRing.exe", "witcher3.exe"])
        self.assertEqual(environ, {"ORBIT_GAME_PROCESSES": "EldenRing.exe;witcher3.exe", "ORBIT_NETWORK_INTERFACE": "Ethernet",
                                   "ORBIT_PRESENTMON_CSV": r"C:\Orbit\presentmon.csv"})
        settings.update_monitoring({"networkInterface": "", "gameProcesses": []})
        self.assertNotIn("ORBIT_NETWORK_INTERFACE", environ)
        self.assertNotIn("ORBIT_GAME_PROCESSES", environ)
        for key, value in (("gameProcesses", ["notepad"]), ("gameProcesses", ["a/b.exe"]), ("presentMonCSV", "relative.csv"),
                           ("presentMonCSV", r"C:\Orbit\capture.txt"), ("libreHardwareMonitorURL", "http://192.168.1.5:8085/data.json"),
                           ("libreHardwareMonitorURL", "https://127.0.0.1/data.json"), ("networkInterface", "x" * 101)):
            with self.assertRaises(settings_module.SettingsError, msg=(key, value)):
                settings.update_monitoring({key: value})
        with self.assertRaises(settings_module.SettingsError):
            settings.update_monitoring({"unknown": 1})
        stored = json.loads(self.path.read_text())
        self.assertEqual(stored["monitoring"]["gameProcesses"], [])

    def test_windows_environment_variables_still_win(self):
        environ = {"ORBIT_GAME_PROCESSES": "set-by-windows.exe"}
        settings = settings_module.Settings(self.path, environ=environ)
        self.assertEqual(settings.monitoring()["gameProcesses"], ["set-by-windows.exe"])
        self.assertEqual(settings.monitoring()["managedByEnvironment"], ["gameProcesses"])
        with self.assertRaisesRegex(settings_module.SettingsError, "ORBIT_GAME_PROCESSES"):
            settings.update_monitoring({"gameProcesses": ["other.exe"]})
        settings.update_monitoring({"networkInterface": "Wi-Fi"})
        self.assertEqual(environ["ORBIT_GAME_PROCESSES"], "set-by-windows.exe")

    def test_stored_values_survive_a_restart_and_bad_ones_are_dropped(self):
        self.path.write_text(json.dumps({"monitoring": {"gameProcesses": ["ok.exe", "bad"], "networkInterface": "Ethernet",
                                                        "libreHardwareMonitorURL": "http://evil.example/"},
                                         "updates": {"checkAutomatically": False}}))
        environ = {}
        settings = settings_module.Settings(self.path, environ=environ)
        settings.apply_environment()
        self.assertEqual(settings.monitoring()["gameProcesses"], [])  # the whole list was invalid: default
        self.assertEqual(environ, {"ORBIT_NETWORK_INTERFACE": "Ethernet"})
        self.assertFalse(settings.updates()["checkAutomatically"])
        self.assertTrue(settings.update_updates({"checkAutomatically": True})["checkAutomatically"])
        with self.assertRaises(settings_module.SettingsError):
            settings.update_updates({"checkAutomatically": "yes"})


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class LocalWindowServerTests(unittest.IsolatedAsyncioTestCase):
    async def run_servers(self, local_port, blocker=None):
        devices_app, window_app = FastAPI(), FastAPI()

        @devices_app.get("/health")
        def health():
            return {"ok": True}

        @window_app.get("/window")
        def window_page():
            return {"window": True}

        first, second = free_port(), free_port()
        stop = threading.Event()
        with tempfile.TemporaryDirectory() as folder:
            cert, key, _ = tls.ensure_tls_identity(folder)
            task = asyncio.create_task(tls.serve_both(devices_app, "127.0.0.1", first, second, cert, key, stop_event=stop,
                                                      local_app=window_app, local_port=local_port))
            context = ssl.create_default_context(cafile=str(cert))
            results = {}
            async with httpx.AsyncClient(trust_env=False, timeout=1, verify=context) as client:
                for _ in range(100):
                    try:
                        results["devices"] = (await client.get(f"https://127.0.0.1:{second}/health")).json()
                        break
                    except httpx.ConnectError:
                        await asyncio.sleep(0.025)
                try:
                    results["window"] = (await client.get(f"http://127.0.0.1:{local_port}/window")).json()
                except httpx.HTTPError:
                    results["window"] = None
            stop.set()
            await asyncio.wait_for(task, timeout=5)
            return results

    async def test_window_server_runs_beside_the_device_ports(self):
        results = await self.run_servers(free_port())
        self.assertEqual(results, {"devices": {"ok": True}, "window": {"window": True}})

    async def test_a_busy_window_port_never_stops_the_agent(self):
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", 0))
            busy.listen()
            port = busy.getsockname()[1]
            results = await self.run_servers(port)
        self.assertEqual(results["devices"], {"ok": True})


if __name__ == "__main__":
    unittest.main()
