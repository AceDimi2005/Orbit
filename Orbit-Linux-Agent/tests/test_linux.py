"""Linux API/backend tests: helpers are fakes, no desktop or power actions run."""
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Orbit-Linux-Agent"), str(ROOT / "Orbit-Windows-Agent")]
from fastapi import HTTPException
from fastapi.testclient import TestClient
from orbit_linux_backend import LinuxDesktop, Commands, EVDEV
from orbit_linux_apps import LinuxApps
from orbit_linux import Startup, desktop_exec
import orbit_input


class Helpers:
    def __init__(self, available=()):
        self.available = set(available)
        self.calls = []
        self.responses = {}

    def has(self, name):
        return name in self.available

    def run(self, *args, **options):
        self.calls.append((args, options))
        result = self.responses.get(args, b"")
        if isinstance(result, Exception):
            raise result
        return result

    def json(self, *args):
        return json.loads(self.run(*args))


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.helpers = Helpers(["wtype", "ydotool", "xdotool", "wl-copy", "wl-paste", "pactl"])
        self.desktop = LinuxDesktop(self.helpers, {"WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "Hyprland", "ORBIT_POINTER_BACKEND": "ydotool"})

    def test_wayland_wins_over_xwayland(self):
        self.desktop.cursor(dx=7, dy=-4, drag="down")
        self.desktop.release_input()
        self.assertEqual([args for args, _ in self.helpers.calls], [
            ("ydotool", "mousemove", "--", "7", "-4"), ("ydotool", "click", "0x40"), ("ydotool", "click", "0x80")])

    def test_scroll_direction_matches_windows_and_evdev(self):
        self.desktop.cursor(scroll=2, hscroll=-1)
        self.assertEqual(self.helpers.calls[0][0], ("ydotool", "mousemove", "--wheel", "--", "-1", "2"))

    def test_text_never_becomes_command_arguments(self):
        text = '-M ctrl $(touch /tmp/never) "hello" ∇'
        self.desktop.type_text(text)
        args, options = self.helpers.calls[0]
        self.assertEqual(args, ("wtype", "-"))
        self.assertEqual(options["input"], text.encode())

    def test_clipboard_is_wayland_native(self):
        self.desktop.clipboard_write("héllo")
        self.assertEqual(self.helpers.calls[0][0], ("wl-copy", "--type", "text/plain;charset=utf-8"))
        self.helpers.responses[("wl-paste", "--no-newline", "--type", "text")] = b"test"
        self.assertEqual(self.desktop.clipboard_read(), "test")

    def test_clipboard_limits(self):
        for text in ["x" * (1024 * 1024 + 1), "a\0b"]:
            with self.assertRaises(HTTPException):
                self.desktop.clipboard_write(text)
        self.assertEqual(self.helpers.calls, [])

    def test_x11_backend_and_screen_coordinates(self):
        desktop = LinuxDesktop(self.helpers, {"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"})
        desktop.capture = Mock(geometry=(100, 200, 1920, 1080))
        desktop.cursor(norm_x=1, norm_y=1, click="right")
        desktop.hotkey(["ctrl", "shift", "m"])
        desktop.type_text("hello")
        self.assertEqual(self.helpers.calls[0][0], ("xdotool", "mousemove", "2019", "1279"))
        self.assertTrue(all(args[0] == "xdotool" for args, _ in self.helpers.calls))

    def test_gnome_uses_uinput_instead_of_unsupported_virtual_keyboard(self):
        desktop = LinuxDesktop(self.helpers, {"WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "GNOME"})
        desktop.hotkey(["ctrl", "a"])
        self.assertEqual(self.helpers.calls[0][0], ("ydotool", "key", "--key-delay", "0", "29:1", "30:1", "30:0", "29:0"))

    def test_no_guessing_portal_monitor_coordinates(self):
        with self.assertRaises(HTTPException) as error:
            self.desktop.cursor(norm_x=.5, norm_y=.5)
        self.assertEqual(error.exception.status_code, 501)
        self.assertEqual(self.helpers.calls, [])

    def test_invalid_pointer_cannot_send_partial_input(self):
        for options in ({"dx": 10001}, {"norm_x": float("nan"), "norm_y": 0}, {"click": "shell"}, {"norm_x": 0}):
            with self.assertRaises(HTTPException):
                self.desktop.cursor(**options)
        self.assertEqual(self.helpers.calls, [])

    def test_all_shared_key_names_have_linux_codes(self):
        self.assertFalse(orbit_input.KEY_NAMES - EVDEV.keys())

    def test_hotkey_releases_in_reverse_order(self):
        self.desktop.hotkey(["ctrl", "shift", "a"])
        self.assertEqual(self.helpers.calls[0][0], ("wtype", "-P", "Control_L", "-P", "Shift_L", "-P", "a", "-p", "a", "-p", "Shift_L", "-p", "Control_L"))

    def test_power_respects_system_policy_without_sudo(self):
        self.desktop.action("sleep")
        self.assertEqual(self.helpers.calls[0][0], ("systemctl", "--no-ask-password", "suspend"))

    def test_no_arbitrary_action_execution(self):
        with self.assertRaises(HTTPException):
            self.desktop.action("shutdown; touch /tmp/never")
        self.assertEqual(self.helpers.calls, [])

    def test_missing_helper_and_errors_are_explicit(self):
        with patch("shutil.which", return_value=None), self.assertRaises(HTTPException):
            Commands().run("wl-copy")
        with patch("shutil.which", return_value="/bin/tool"), patch("subprocess.run", return_value=Mock(returncode=1, stderr=b"private clipboard text")), self.assertRaises(HTTPException) as error:
            Commands().run("wl-copy")
        self.assertNotIn("private", error.exception.detail)

    def test_presentation_uses_keys_and_does_not_claim_com_metadata(self):
        self.desktop.presentation.perform("goto", slide=12)
        self.assertEqual(len(self.helpers.calls), 3)
        self.assertFalse(self.desktop.presentation.state()["thumbnails"])


class CatalogTests(unittest.TestCase):
    def test_hidden_overrides_and_no_shell_parsing(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, system = Path(tmp) / "home", Path(tmp) / "system"
            for root in (home, system):
                (root / "applications").mkdir(parents=True)
            (system / "applications/app.desktop").write_text('[Desktop Entry]\nType=Application\nName=Test\nExec=printf "hello world"\n')
            catalog = LinuxApps({"XDG_DATA_HOME": str(home), "XDG_DATA_DIRS": str(system), "XDG_CURRENT_DESKTOP": "Hyprland", "ORBIT_POINTER_BACKEND": "ydotool"})
            apps = catalog.list()
            self.assertEqual(len(apps), 1)
            self.assertEqual(catalog.find(apps[0].id), apps[0])
            self.assertEqual(len(apps[0].id), 40)
            (home / "applications/app.desktop").write_text('[Desktop Entry]\nHidden=true\n')
            self.assertEqual(catalog.list(), [])

    def test_startup_is_opt_in_and_quoted(self):
        with tempfile.TemporaryDirectory() as tmp:
            startup = Startup(["/space dir/python", '/a%file/$app".py'], tmp)
            self.assertFalse(startup.enabled())
            startup.set_enabled(True)
            self.assertTrue(startup.enabled())
            self.assertIn('"/space dir/python"', startup.path.read_text())
            self.assertIn('%%file/\\$app\\"', startup.path.read_text())
            startup.set_enabled(False)
            self.assertFalse(startup.enabled())


class APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.environment = patch.dict(os.environ, {"ORBIT_PLATFORM": "linux", "LOCALAPPDATA": cls.directory.name,
                                                  "HYPRLAND_INSTANCE_SIGNATURE": "",
                                                  "ORBIT_TOKEN_FILE": cls.directory.name + "/token", "ORBIT_WIDGET_TOKEN_FILE": cls.directory.name + "/widget"})
        cls.environment.start()
        import orbit_agent
        cls.agent = orbit_agent
        cls.agent.API_TOKEN = "test-control-token-with-32-characters"
        cls.agent.WIDGET_TOKEN = "test-widget-token-with-32-characters"
        cls.client = TestClient(orbit_agent.app, base_url="https://testserver")
        cls.headers = {"Authorization": f"Bearer {cls.agent.API_TOKEN}"}

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.stop()
        cls.directory.cleanup()

    def setUp(self):
        self.helpers = Helpers(["wtype", "ydotool", "pactl"])
        self.agent.PLATFORM.commands = self.helpers
        self.agent.PLATFORM.use_wtype = True
        self.agent.PLATFORM.wayland = True
        self.agent.PLATFORM.pointer_backend = "ydotool"
        self.agent.STREAM_DISPLAY.platform.commands = self.helpers
        from orbit_stream_display import SunshineActivity
        self.agent.STREAM_DISPLAY.activity = lambda: SunshineActivity()

    def test_controls_require_main_token(self):
        for path in ("/api/action/sleep", "/api/input/mouse?dx=2", "/api/input/keyboard?text=test"):
            self.assertEqual(self.client.post(path).status_code, 401)
            self.assertEqual(self.client.post(path, headers={"Authorization": f"Bearer {self.agent.WIDGET_TOKEN}"}).status_code, 401)
        self.assertFalse(self.helpers.calls)

    def test_inputs_reach_linux_backend(self):
        response = self.client.post("/api/input/keyboard", params={"text": "hello"}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.helpers.calls[0][0], ("wtype", "-"))
        response = self.client.post("/api/input/hotkey", json={"keys": ["ctrl", "a"]}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)

    def test_clipboard_https_and_auth(self):
        response = self.client.put("/api/clipboard", json={"text": "test"}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        client = TestClient(self.agent.app, base_url="http://testserver")
        try:
            self.assertEqual(client.put("/api/clipboard", json={"text": "test"}, headers=self.headers).status_code, 426)
        finally:
            client.close()

    def test_driver_capabilities_are_not_advertised(self):
        response = self.client.get("/api/capabilities", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        features = response.json()["features"]
        self.assertIn("deck", features)
        self.assertIn("presentation", features)
        self.assertIn("webcam", features)
        self.assertFalse(set(features) & {"streamDisplay", "secondScreen"})

    def test_driver_routes_fail_before_platform_operations(self):
        response = self.client.get("/api/stream/display", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["virtualDisplay"]["installed"])
        response = self.client.post("/api/stream/display/modes", json={"width": 1280, "height": 720}, headers=self.headers)
        self.assertEqual(response.status_code, 501, response.text)

    def test_linux_webcam_status_and_privileged_setup(self):
        response = self.client.get("/api/webcam", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["backend"], "v4l2loopback")
        self.assertTrue(response.json()["setupManagedExternally"])
        self.assertEqual(self.client.get("/api/webcam").status_code, 401)
        for operation in ("install", "uninstall"):
            self.assertEqual(self.client.post(f"/api/webcam/{operation}", headers=self.headers).status_code, 501)

    def test_linux_camera_socket_uses_shared_worker_and_cleans_up(self):
        from concurrent.futures import Future
        manager = Mock(connected=False)
        ready = Future()
        ready.set_result({})
        manager.start_sender.return_value = ready
        camera = self.agent.PLATFORM.webcam
        with patch.object(camera, "manager", manager), patch.object(camera, "readiness", return_value=None):
            with self.client.websocket_connect("wss://testserver/ws/camera", headers=self.headers) as socket:
                socket.send_json({"width": 1280, "height": 720, "fps": 30})
                self.assertTrue(socket.receive_json()["ready"])
                socket.send_bytes(b"\xff\xd8\xff\xe0frame\xff\xd9")
            manager.start_sender.assert_called_once()
            sender = manager.start_sender.call_args.args[0]
            manager.stop_sender.assert_called_once_with(sender)
            manager.submit_frame.assert_called_once()

    def test_linux_files_keep_credentials_and_code_protected(self):
        import orbit_files
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "notes:today.txt"
            source.write_text("test")
            self.assertEqual(orbit_files.checked_path(str(source)), source)
            with patch.dict(os.environ, {"ORBIT_APP_DIRECTORY": str(root)}), self.assertRaises(HTTPException):
                orbit_files.checked_path(str(source), writing=True)
            with self.assertRaises(HTTPException):
                orbit_files.checked_path(os.environ["ORBIT_TOKEN_FILE"])
            with patch("send2trash.send2trash", side_effect=OSError("no trash")), self.assertRaises(HTTPException):
                orbit_files.recycle_path(str(source))
            self.assertTrue(source.is_file())

    def test_linux_process_protection(self):
        import orbit_processes
        import pwd
        owner = pwd.getpwuid(os.getuid()).pw_name
        for pid, name, user in [(1, "init", owner), (42, "Hyprland", owner), (43, "editor", "another-user")]:
            self.assertFalse(orbit_processes._can_terminate(pid, name, user, "running", set()))
        self.assertTrue(orbit_processes._can_terminate(44, "editor", owner, "running", set()))

    def test_windows_update_cannot_overwrite_linux_installation(self):
        self.assertEqual(self.client.post("/api/update/apply", headers=self.headers).status_code, 501)

    def test_unknown_audio_session_is_not_modified(self):
        self.helpers.responses[("pactl", "--format=json", "list", "sink-inputs")] = b"[]"
        response = self.client.post("/api/audio/session", json={"id": "a" * 64, "volume": 50}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(len(self.helpers.calls), 1)

    def test_websocket_input_auth_and_release(self):
        with self.client.websocket_connect("/ws/input", headers=self.headers) as ws:
            ws.send_json({"drag": "down"})
            ws.send_json({"dx": 1})
        self.assertIn((("ydotool", "click", "0x80"), {}), self.helpers.calls)


if __name__ == "__main__":
    unittest.main()
