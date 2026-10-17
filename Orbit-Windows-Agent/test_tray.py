"""Tests for the Windows system tray icon, menu actions, and startup registration."""
import asyncio
from contextlib import contextmanager
from pathlib import Path
import socket
import ssl
import struct
import sys
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI
import httpx

import orbit_tls as tls
import orbit_tray as tray


class FakeRegistry:
    HKEY_CURRENT_USER = 0x80000001
    KEY_READ = 0x20019
    KEY_SET_VALUE = 0x0002
    REG_SZ = 1

    def __init__(self):
        self.values = {}

    @contextmanager
    def OpenKey(self, root, path, reserved, access):
        if (root, path) not in self.values:
            raise FileNotFoundError(path)
        yield (root, path)

    @contextmanager
    def CreateKeyEx(self, root, path, reserved, access):
        self.values.setdefault((root, path), {})
        yield (root, path)

    def QueryValueEx(self, key, name):
        bucket = self.values.get(key, {})
        if name not in bucket:
            raise FileNotFoundError(name)
        return bucket[name]

    def SetValueEx(self, key, name, reserved, reg_type, value):
        self.values.setdefault(key, {})[name] = (value, reg_type)

    def DeleteValue(self, key, name):
        bucket = self.values.get(key, {})
        if name not in bucket:
            raise FileNotFoundError(name)
        del bucket[name]


class StartupManagerTests(unittest.TestCase):
    def test_startup_toggle_registers_and_removes_background_command(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / "orbit_agent.py"
            script.write_text("# agent\n", encoding="utf-8")
            venv_scripts = root / ".venv" / "Scripts"
            venv_scripts.mkdir(parents=True)
            pythonw = venv_scripts / "pythonw.exe"
            pythonw.write_bytes(b"MZ")

            reg = FakeRegistry()
            manager = tray.StartupManager(script_path=script, registry=reg)
            self.assertFalse(manager.is_enabled())

            self.assertTrue(manager.toggle())
            self.assertTrue(manager.is_enabled())
            stored, reg_type = reg.values[(reg.HKEY_CURRENT_USER, tray.RUN_REGISTRY_PATH)][tray.RUN_VALUE_NAME]
            self.assertEqual(reg_type, reg.REG_SZ)
            self.assertIn(str(pythonw.resolve()), stored)
            self.assertIn(str(script.resolve()), stored)
            self.assertTrue(stored.endswith("--background"))

            self.assertFalse(manager.toggle())
            self.assertFalse(manager.is_enabled())
            # Disabling again when already absent must not raise.
            self.assertFalse(manager.set_enabled(False))

    def test_stale_script_path_in_registry_is_reported_as_disabled(self):
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "orbit_agent.py"
            script.write_text("# agent\n", encoding="utf-8")
            reg = FakeRegistry()
            reg.values[(reg.HKEY_CURRENT_USER, tray.RUN_REGISTRY_PATH)] = {
                tray.RUN_VALUE_NAME: ('"C:\\OldFolder\\pythonw.exe" "C:\\OldFolder\\orbit_agent.py" --background', reg.REG_SZ)
            }
            manager = tray.StartupManager(script_path=script, registry=reg)
            self.assertFalse(manager.is_enabled())
            self.assertTrue(manager.set_enabled(True))
            self.assertTrue(manager.is_enabled())


class IconTests(unittest.TestCase):
    def test_bundled_orbit_ico_contains_tray_and_hidpi_frames(self):
        self.assertTrue(tray.ICON_PATH.is_file())
        raw = tray.ICON_PATH.read_bytes()
        reserved, ico_type, count = struct.unpack_from("<HHH", raw, 0)
        self.assertEqual((reserved, ico_type), (0, 1))
        self.assertGreaterEqual(count, 6)
        sizes = set()
        for index in range(count):
            w, h, _, _, _, bpp, size, offset = struct.unpack_from("<BBBBHHII", raw, 6 + index * 16)
            sizes.add((w or 256, h or 256))
            self.assertEqual(bpp, 32)
            self.assertLessEqual(offset + size, len(raw))
        for expected in ((16, 16), (24, 24), (32, 32), (48, 48), (256, 256)):
            self.assertIn(expected, sizes)

    def test_fallback_icon_generator_creates_valid_ico_when_missing(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = Path(folder) / "missing.ico"
            fallback_dir = Path(folder) / "fallback"
            generated = tray.ensure_icon_file(path=missing, fallback_directory=fallback_dir)
            self.assertTrue(generated.is_file())
            self.assertEqual(generated.read_bytes()[:4], b"\x00\x00\x01\x00")


class TrayMenuAndLifecycleTests(unittest.TestCase):
    def make_fake_apis(self, console_hwnd=0, console_visible=False):
        user32 = MagicMock()
        shell32 = MagicMock()
        kernel32 = MagicMock()
        kernel32.GetConsoleWindow.return_value = console_hwnd
        user32.IsWindowVisible.return_value = int(bool(console_visible))
        shell32.Shell_NotifyIconW.return_value = 1
        return user32, shell32, kernel32

    def test_menu_reflects_startup_check_console_and_actions(self):
        reg = FakeRegistry()
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "orbit_agent.py"
            script.write_text("# agent\n", encoding="utf-8")
            log_file = Path(folder) / "agent.log"
            log_file.write_text("started\n", encoding="utf-8")
            startup = tray.StartupManager(script_path=script, registry=reg)
            stopped = threading.Event()
            apis = self.make_fake_apis(console_hwnd=101, console_visible=True)

            icon = tray.OrbitTrayIcon(
                status_provider=lambda: {
                    "agentVersion": "4.1.0",
                    "hostname": "GAMING-PC",
                    "ipAddress": "192.168.1.50",
                    "agentPort": 8765,
                    "securePort": 8766,
                    "fingerprint": "AA:BB:CC",
                    "activeGame": "Cyberpunk 2077",
                },
                on_stop=stopped.set,
                startup_manager=startup,
                token_provider=lambda: "secret-token-value-at-least-24-chars",
                log_path=log_file,
                apis=apis,
            )
            icon._hwnd = 555

            self.assertIn("192.168.1.50:8766", icon.format_tooltip())
            self.assertIn("Cyberpunk 2077", icon.format_tooltip())

            items = icon.build_menu_items()
            by_id = {item.get("id"): item for item in items if item.get("id")}
            self.assertFalse(by_id[tray.ID_TOGGLE_STARTUP]["checked"])
            self.assertTrue(by_id[tray.ID_TOGGLE_CONSOLE]["checked"])
            self.assertIn(tray.ID_CHECK_UPDATES, by_id)
            self.assertIn(tray.ID_OPEN_LOG, by_id)
            self.assertIn(tray.ID_EXIT, by_id)

            icon.execute_command(tray.ID_TOGGLE_STARTUP)
            self.assertTrue(startup.is_enabled())
            items_after = {item.get("id"): item for item in icon.build_menu_items() if item.get("id")}
            self.assertTrue(items_after[tray.ID_TOGGLE_STARTUP]["checked"])

            icon.execute_command(tray.ID_EXIT)
            self.assertTrue(stopped.is_set())

    def test_tray_update_check_handles_up_to_date_and_update_install(self):
        apis = self.make_fake_apis()
        user32, _, _ = apis
        user32.MessageBoxW.return_value = tray.IDYES
        installed_urls = []

        icon = tray.OrbitTrayIcon(
            status_provider=lambda: {"agentVersion": "4.1.0"},
            on_stop=lambda: None,
            update_checker=lambda current: {
                "currentVersion": current,
                "latestVersion": "4.2.0",
                "updateAvailable": True,
                "releaseTitle": "Orbit 4.2.0",
                "releaseNotes": "Added new tray updater",
                "releaseUrl": "https://github.com/AceDimi2005/Orbit/releases/tag/v4.2.0",
                "downloadUrl": "https://github.com/AceDimi2005/Orbit/releases/download/v4.2.0/Orbit-Windows-Agent.zip",
                "repository": "AceDimi2005/Orbit",
            },
            update_installer=lambda url: (installed_urls.append(url) or ["orbit_agent.py", "orbit_tray.py"]),
            apis=apis,
        )
        icon._hwnd = 777
        outcome = icon.perform_update_check()
        self.assertEqual(outcome["status"], "updated")
        self.assertEqual(len(installed_urls), 1)

        # Up-to-date path
        icon.update_checker = lambda current: {
            "currentVersion": current,
            "latestVersion": "4.1.0",
            "updateAvailable": False,
            "repository": "AceDimi2005/Orbit",
        }
        up_to_date = icon.perform_update_check()
        self.assertEqual(up_to_date["status"], "up_to_date")

    def test_background_stdio_redirects_missing_streams_to_log_file(self):
        with tempfile.TemporaryDirectory() as folder:
            log_file = Path(folder) / "agent.log"
            with patch.object(sys, "stdout", None), patch.object(sys, "stderr", None):
                resolved = tray.ensure_background_stdio(log_file)
                self.assertEqual(resolved, log_file)
                print("Tray background output test", flush=True)
                sys.stdout.close()
            self.assertIn("Tray background output test", log_file.read_text(encoding="utf-8"))


class UpdaterTests(unittest.TestCase):
    def test_version_comparison_and_github_check(self):
        import io
        import json
        import orbit_updater as updater

        self.assertTrue(updater.is_newer_version("v4.2.0", "4.1.0"))
        self.assertTrue(updater.is_newer_version("4.1.1", "4.1.0"))
        self.assertFalse(updater.is_newer_version("4.1.0", "4.1.0"))
        self.assertFalse(updater.is_newer_version("4.0.9", "4.1.0"))

        def fake_opener(request, timeout=6.0):
            url = request.full_url
            if "/releases?per_page=20" in url or "/releases/latest" in url:
                payload = json.dumps([
                    {
                        "tag_name": "ios-v9.9.9",
                        "name": "Orbit for iOS 9.9.9",
                        "body": "iPhone App Store release only.",
                        "html_url": "https://github.com/AceDimi2005/Orbit/releases/tag/ios-v9.9.9",
                        "assets": [],
                    },
                    {
                        "tag_name": "pc-v4.3.0",
                        "name": "Orbit PC Companion 4.3.0",
                        "body": "Faster telemetry and tray improvements.",
                        "html_url": "https://github.com/AceDimi2005/Orbit/releases/tag/pc-v4.3.0",
                        "assets": [
                            {
                                "name": "Orbit-Windows-Agent-4.3.0.zip",
                                "browser_download_url": "https://github.com/AceDimi2005/Orbit/releases/download/pc-v4.3.0/Orbit-Windows-Agent-4.3.0.zip",
                            }
                        ],
                    },
                ]).encode("utf-8")
                return io.BytesIO(payload)
            if "raw.githubusercontent.com" in url:
                return io.BytesIO(b'AGENT_VERSION = "4.1.0"\n')
            raise AssertionError(f"Unexpected URL: {url}")

        info = updater.check_for_updates("4.1.0", opener=fake_opener)
        self.assertTrue(info["updateAvailable"])
        self.assertEqual(info["latestVersion"], "4.3.0")
        self.assertEqual(
            info["downloadUrl"],
            "https://github.com/AceDimi2005/Orbit/releases/download/pc-v4.3.0/Orbit-Windows-Agent-4.3.0.zip",
        )

    def test_apply_update_archive_updates_agent_files_and_preserves_tokens(self):
        import io
        import zipfile
        import orbit_updater as updater

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("Orbit-main/Orbit-Windows-Agent/orbit_agent.py", 'AGENT_VERSION = "4.2.0"\n')
            zf.writestr("Orbit-main/Orbit-Windows-Agent/orbit_tray.py", "# updated tray\n")
            zf.writestr("Orbit-main/Orbit-Windows-Agent/.orbit-token", "should-not-overwrite-secret")

        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)
            (target / "orbit_agent.py").write_text('AGENT_VERSION = "4.1.0"\n', encoding="utf-8")
            (target / ".orbit-token").write_text("existing-secret-token-value-12345", encoding="utf-8")

            updated = updater.apply_update_archive(buf.getvalue(), target_dir=target)
            self.assertIn("orbit_agent.py", updated)
            self.assertIn("orbit_tray.py", updated)
            self.assertNotIn(".orbit-token", updated)
            self.assertEqual((target / "orbit_agent.py").read_text(encoding="utf-8"), 'AGENT_VERSION = "4.2.0"\n')
            self.assertEqual((target / ".orbit-token").read_text(encoding="utf-8"), "existing-secret-token-value-12345")

    def test_frozen_executable_startup_command(self):
        with tempfile.TemporaryDirectory() as folder:
            exe = Path(folder) / "OrbitCompanion.exe"
            exe.write_bytes(b"MZ")
            reg = FakeRegistry()
            manager = tray.StartupManager(frozen_executable=exe, registry=reg)
            self.assertTrue(manager.set_enabled(True))
            self.assertTrue(manager.is_enabled())
            self.assertEqual(manager.startup_command(), f'"{exe.resolve()}" --background')


class StopEventServerTests(unittest.IsolatedAsyncioTestCase):
    async def test_serve_both_exits_cleanly_when_tray_stop_event_is_set(self):
        app = FastAPI()

        @app.get("/health")
        def health():
            return {"ok": True}

        def free_port():
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                return sock.getsockname()[1]

        first, second = free_port(), free_port()
        while second == first:
            second = free_port()

        stop_event = threading.Event()
        with tempfile.TemporaryDirectory() as folder:
            cert, key, _ = tls.ensure_tls_identity(folder)
            context = ssl.create_default_context(cafile=str(cert))
            server_task = asyncio.create_task(
                tls.serve_both(app, "127.0.0.1", first, second, cert, key, stop_event=stop_event)
            )
            async with httpx.AsyncClient(trust_env=False, timeout=1, verify=context) as client:
                for _ in range(100):
                    try:
                        response = await client.get(f"https://127.0.0.1:{second}/health")
                        if response.status_code == 200:
                            break
                    except httpx.ConnectError:
                        await asyncio.sleep(0.025)
                else:
                    self.fail("HTTPS server did not start")
            stop_event.set()
            await asyncio.wait_for(server_task, timeout=5.0)


if __name__ == "__main__":
    unittest.main()
