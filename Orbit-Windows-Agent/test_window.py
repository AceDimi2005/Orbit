"""The companion window: one-time launch codes, session cookie, Host/Origin checks, CSP,
the local API, the Edge launcher and the agent's window backend. No browser is opened."""
import json
from pathlib import Path
import re
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_activity as activity
import orbit_agent as agent
import orbit_devices as devices
import orbit_settings as settings_module
import orbit_window as window
import orbit_window_ui as page

PORT = 8767
HOST = f"http://127.0.0.1:{PORT}"


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


class FakeBackend(window.WindowBackend):
    def __init__(self):
        self.calls = []
        self.failure = None

    def _call(self, name, *arguments):
        self.calls.append((name, arguments))
        if self.failure is not None:
            raise self.failure
        return {"called": name}

    def overview(self): return self._call("overview")
    def devices(self): return self._call("devices")
    def update_device(self, device_id, name=None, scopes=None): return self._call("update_device", device_id, name, scopes)
    def remove_device(self, device_id): return self._call("remove_device", device_id)
    def add_manual_device(self): return self._call("add_manual_device")
    def activity(self, before=None, category=None, limit=50): return self._call("activity", before, category, limit)
    def settings(self): return self._call("settings")
    def update_settings(self, changes): return self._call("update_settings", changes)
    def set_boot_task(self, enabled): return self._call("set_boot_task", enabled)
    def diagnostics(self, force=False): return self._call("diagnostics", force)
    def fix(self, kind, interface_index=None): return self._call("fix", kind, interface_index)
    def check_updates(self): return self._call("check_updates")
    def install_update(self): return self._call("install_update")
    def restart(self): return self._call("restart")


class SessionTests(unittest.TestCase):
    def test_codes_work_once_and_expire(self):
        clock = Clock()
        sessions = window.WindowSessions(clock=clock)
        code = sessions.issue_launch_code()
        session = sessions.redeem(code)
        self.assertTrue(session)
        self.assertIsNone(sessions.redeem(code))
        late = sessions.issue_launch_code()
        clock.now += window.LAUNCH_SECONDS + 1
        self.assertIsNone(sessions.redeem(late))
        self.assertIsNone(sessions.redeem(""))
        self.assertIsNone(sessions.redeem(None))

    def test_sessions_expire_when_idle_and_are_bounded(self):
        clock = Clock()
        sessions = window.WindowSessions(clock=clock)
        session = sessions.redeem(sessions.issue_launch_code())
        clock.now += window.SESSION_IDLE_SECONDS - 10
        self.assertTrue(sessions.valid(session))  # use keeps it alive
        clock.now += window.SESSION_IDLE_SECONDS - 10
        self.assertTrue(sessions.valid(session))
        clock.now += window.SESSION_IDLE_SECONDS + 1
        self.assertFalse(sessions.valid(session))
        many = [sessions.redeem(sessions.issue_launch_code()) for _ in range(window.MAX_SESSIONS + 3)]
        self.assertEqual(sum(sessions.valid(item) for item in many), window.MAX_SESSIONS)
        sessions.end_all()
        self.assertFalse(any(sessions.valid(item) for item in many))


class WindowAppTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.sessions = window.WindowSessions()
        self.app = window.create_window_app(self.backend, self.sessions, PORT)
        self.client = TestClient(self.app, base_url=HOST)

    def tearDown(self):
        self.client.close()

    def sign_in(self):
        response = self.client.get(f"/open?code={self.sessions.issue_launch_code()}", follow_redirects=False)
        self.assertEqual(response.status_code, 303)
        return response

    def call(self, method, path, **kwargs):
        headers = {"X-Orbit-Window": "1", "Origin": HOST, **kwargs.pop("headers", {})}
        return self.client.request(method, path, headers=headers, **kwargs)

    def test_foreign_host_headers_are_refused(self):
        for host in ("evil.example", "orbit.local:8767", "127.0.0.1:9999", "192.168.1.196:8767"):
            response = self.client.get("/", headers={"Host": host})
            self.assertEqual(response.status_code, 403, host)
        self.assertEqual(self.client.get("/", headers={"Host": f"localhost:{PORT}"}).status_code, 200)

    def test_launch_code_becomes_a_strict_http_only_cookie_and_leaves_the_address_bar(self):
        response = self.sign_in()
        self.assertEqual(response.headers["location"], "/")
        cookie = response.headers["set-cookie"]
        self.assertIn(f"{window.COOKIE}=", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=strict", cookie)
        refused = self.client.get("/open?code=not-a-code", follow_redirects=False)
        self.assertNotIn("set-cookie", refused.headers)

    def test_api_needs_the_session_and_the_window_header(self):
        self.assertEqual(self.call("GET", "/local/api/overview").status_code, 401)
        self.sign_in()
        self.assertEqual(self.client.get("/local/api/overview").status_code, 401)  # no X-Orbit-Window
        self.assertEqual(self.call("GET", "/local/api/overview").json(), {"called": "overview"})

    def test_changes_must_come_from_this_origin(self):
        self.sign_in()
        for origin in ("http://evil.example", "http://127.0.0.1:9999", None):
            headers = {"X-Orbit-Window": "1"}
            if origin:
                headers["Origin"] = origin
            response = self.client.request("DELETE", f"/local/api/devices/{'a' * 32}", headers=headers)
            self.assertEqual(response.status_code, 403, origin)
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(self.call("DELETE", f"/local/api/devices/{'a' * 32}").json(), {"called": "remove_device"})

    def test_page_carries_a_nonce_csp_and_no_cache(self):
        self.sign_in()
        response = self.client.get("/")
        policy = response.headers["content-security-policy"]
        nonce = re.search(r"script-src 'nonce-([^']+)'", policy).group(1)
        self.assertIn(f'<script nonce="{nonce}">', response.text)
        self.assertIn(f'<style nonce="{nonce}">', response.text)
        self.assertIn("frame-ancestors 'none'", policy)
        self.assertNotIn("unsafe-inline", policy)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.headers["x-frame-options"], "DENY")
        self.assertIn("const SIGNED_IN = true;", response.text)
        self.client.cookies.clear()
        self.assertIn("const SIGNED_IN = false;", self.client.get("/").text)

    def test_endpoints_delegate_and_map_errors(self):
        self.sign_in()
        self.call("PATCH", f"/local/api/devices/{'b' * 32}", json={"name": "Living room"})
        self.call("GET", "/local/api/activity?before=40&category=power&limit=20")
        self.call("PATCH", "/local/api/settings", json={"runAtStartup": True, "notifications": {"files": False}})
        self.call("POST", "/local/api/settings/boot-task", json={"enabled": True})
        self.call("GET", "/local/api/diagnostics?force=true")
        self.call("POST", "/local/api/diagnostics/fix", json={"kind": "privateNetwork", "interfaceIndex": 12})
        self.call("POST", "/local/api/devices/manual", json={})
        names = [name for name, _ in self.backend.calls]
        self.assertEqual(names, ["update_device", "activity", "update_settings", "set_boot_task", "diagnostics", "fix",
                                 "add_manual_device"])
        self.assertEqual(self.backend.calls[0][1], ("b" * 32, "Living room", None))
        self.assertEqual(self.backend.calls[1][1], (40, "power", 20))
        self.assertEqual(self.backend.calls[2][1], ({"runAtStartup": True, "notifications": {"files": False}},))
        self.assertEqual(self.backend.calls[4][1], (True,))
        self.assertEqual(self.backend.calls[5][1], ("privateNetwork", 12))
        for body, status in (({}, 422), ({"name": "x", "owner": "y"}, 422)):
            self.assertEqual(self.call("PATCH", f"/local/api/devices/{'b' * 32}", json=body).status_code, status)
        self.assertEqual(self.call("POST", "/local/api/diagnostics/fix", json={"kind": "rm -rf"}).status_code, 422)
        self.assertEqual(self.call("POST", "/local/api/diagnostics/fix", json={"kind": "privateNetwork"}).status_code, 422)
        self.assertEqual(self.call("PATCH", "/local/api/settings", json={}).status_code, 422)
        for error, status in ((KeyError("x"), 404), (ValueError("bad"), 422), (PermissionError("frozen"), 409), (OSError("no"), 503)):
            self.backend.failure = error
            self.assertEqual(self.call("GET", "/local/api/devices").status_code, status)


class PageTests(unittest.TestCase):
    def test_page_is_self_contained(self):
        html = page.render_page("abc", True)
        # No CDN, remote font, script or stylesheet: nothing loads from outside this PC.
        self.assertNotRegex(html, r"(?:src|href)=\"https?://|url\(\s*['\"]?https?://|@import|fonts\.googleapis")
        self.assertNotIn("{{", html)
        self.assertIn("Segoe UI Variable", html)
        self.assertIn("#0a84ff", html.lower())
        self.assertIn("<svg", html)
        self.assertNotRegex(html, r"linear-gradient|radial-gradient|backdrop-filter")
        self.assertNotRegex(html, r'\son[a-z]+="')  # no inline event handlers (CSP)
        self.assertNotRegex(html, r'\sstyle="')  # no inline style attributes (CSP)

    def test_every_dynamic_value_is_escaped(self):
        html = page.render_page("abc", True)
        self.assertIn('const escape = (value) => String(value ?? "").replace(/[&<>"\']/g', html)


class LauncherTests(unittest.TestCase):
    def test_edge_from_the_usual_folders_or_app_paths(self):
        environ = {"PROGRAMFILES(X86)": r"C:\Program Files (x86)", "PROGRAMFILES": r"C:\Program Files"}
        expected = str(Path(r"C:\Program Files (x86)") / "Microsoft" / "Edge" / "Application" / "msedge.exe")
        self.assertEqual(window.find_edge(environ, exists=lambda path: path == expected, registry=None), expected)
        self.assertIsNone(window.find_edge({}, exists=lambda path: False, registry=None))

    def test_opens_an_app_window_or_falls_back_to_the_browser(self):
        launched, opened = [], []
        self.assertEqual(window.open_app_window("http://127.0.0.1:8767/open?code=x", edge="msedge.exe",
                                                launcher=launched.append, browser=opened.append), "edge")
        self.assertEqual(launched[0][:2], ["msedge.exe", "--app=http://127.0.0.1:8767/open?code=x"])
        self.assertEqual(window.open_app_window("http://127.0.0.1:8767/x", edge="", launcher=launched.append,
                                                browser=opened.append), "browser")
        self.assertEqual(opened, ["http://127.0.0.1:8767/x"])

    def test_tray_click_issues_a_fresh_code_each_time(self):
        with patch.object(agent, "open_app_window") as opened:
            agent.open_companion_window()
            agent.open_companion_window()
        first, second = (call.args[0] for call in opened.call_args_list)
        self.assertTrue(first.startswith(f"http://127.0.0.1:{agent.WINDOW_PORT}/open?code="))
        self.assertNotEqual(first, second)


class AgentBackendTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        self.environ = {}
        self.settings = settings_module.Settings(root / "settings.json", environ=self.environ)
        self.patches = [patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "ACTIVITY", self.log),
                        patch.object(agent, "SETTINGS", self.settings), patch.object(agent, "POWER_SCHEDULER", None)]
        for item in self.patches:
            item.start()
        self.backend = agent.AgentWindowBackend()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.log.close()
        self.folder.cleanup()

    def test_overview_counts_and_pairing(self):
        phone, token = self.registry.register("Orbit on iPhone", "iOS")
        self.registry.register("Apple TV · Orbit", "tvOS")
        self.registry.authenticate(token, "192.168.1.23")
        self.log.record(phone["id"], "iPhone", "audio", "volume.set", "Set the volume to 40%")
        manager = MagicMock()
        manager.pending.return_value = {"name": "Orbit on Mac", "kind": "Mac", "code": "123456", "expiresIn": 90}
        with patch.object(agent, "PAIRING_MANAGER", manager):
            overview = self.backend.overview()
        self.assertEqual(overview["counts"], {"devices": 2, "online": 1, "actionsToday": 1})
        self.assertEqual(overview["pairing"]["code"], "123456")
        self.assertEqual(overview["activity"][0]["summary"], "Set the volume to 40%")
        self.assertEqual(overview["pc"]["version"], "5.0.0")
        self.assertEqual(set(overview), {"pc", "pairing", "devices", "counts", "activity", "power", "game"})

    def test_changes_from_the_window_are_recorded_as_this_pc(self):
        tv, _ = self.registry.register("Apple TV · Orbit", "tvOS")
        self.backend.update_device(tv["id"], name="Living room", scopes=["read"])
        self.backend.remove_device(tv["id"])
        with self.assertRaises(KeyError):
            self.backend.remove_device(tv["id"])
        rows = self.log.entries()["entries"]
        self.assertEqual([(row["deviceName"], row["summary"]) for row in rows],
                         [("This PC", "Removed Living room"), ("This PC", "Changed Living room (access: read)")])

    def test_manual_device_is_copied_privately(self):
        with patch("orbit_desktop.copy_private_text") as copy, patch.object(agent, "on_device_paired"):
            result = self.backend.add_manual_device()
        copy.assert_called_once_with(result["token"])
        self.assertTrue(result["copied"])
        self.assertEqual(self.registry.authenticate(result["token"]).name, "Manual setup")

    def test_settings_are_validated_before_anything_changes(self):
        startup = MagicMock()
        with patch("orbit_tray.StartupManager", return_value=startup), patch("orbit_tray.BootTaskManager") as boot:
            boot.return_value.is_installed.return_value = False
            startup.is_enabled.return_value = False
            with self.assertRaises(settings_module.SettingsError):
                self.backend.update_settings({"runAtStartup": True, "monitoring": {"gameProcesses": ["not an exe"]}})
            startup.set_enabled.assert_not_called()
            result = self.backend.update_settings({"runAtStartup": True, "monitoring": {"gameProcesses": ["eldenring.exe"]},
                                                   "notifications": {"files": False}})
        startup.set_enabled.assert_called_once_with(True)
        self.assertEqual(result["monitoring"]["gameProcesses"], ["eldenring.exe"])
        self.assertFalse(result["notifications"]["files"])
        self.assertEqual(self.environ["ORBIT_GAME_PROCESSES"], "eldenring.exe")
        self.assertIn("Turned on Start with Windows", self.log.entries()["entries"][0]["summary"])

    def test_restart_starts_a_new_companion_that_waits_for_this_one(self):
        launched = []
        with patch.object(agent.threading, "Timer") as timer:
            agent.restart_companion(launcher=launched.append)
        command = launched[0]
        self.assertIn("--after", command)
        self.assertEqual(command[command.index("--after") + 1], str(agent.os.getpid()))
        self.assertTrue(command[-1] == "--tray")
        timer.assert_called_once()
        self.assertEqual(timer.call_args.args[1], agent.STOP_EVENT.set)
        with patch.object(agent.orbit_paths, "is_frozen", return_value=True), patch.object(agent.sys, "executable", r"C:\Orbit\OrbitCompanion.exe"):
            self.assertEqual(agent.restart_command(42), [r"C:\Orbit\OrbitCompanion.exe", "--after", "42", "--tray"])

    def test_install_update_is_refused_in_the_frozen_build(self):
        with patch.object(agent.orbit_paths, "is_frozen", return_value=True):
            with self.assertRaises(PermissionError):
                self.backend.install_update()


class RemoteSettingsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.settings = settings_module.Settings(root / "settings.json", environ={})
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        _, admin = self.registry.register("Orbit on iPhone", "iOS")
        _, reader = self.registry.register("Orbit on iPad", "iPadOS", scopes=["read"])
        self.admin, self.reader = {"Authorization": f"Bearer {admin}"}, {"Authorization": f"Bearer {reader}"}
        self.patches = [patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "SETTINGS", self.settings),
                        patch.object(agent, "ACTIVITY", self.log), patch("orbit_tray.StartupManager"), patch("orbit_tray.BootTaskManager")]
        for item in self.patches:
            item.start()
        self.https = TestClient(agent.app, base_url="https://testserver")
        self.http = TestClient(agent.app)

    def tearDown(self):
        self.https.close()
        self.http.close()
        for item in reversed(self.patches):
            item.stop()
        self.log.close()
        self.folder.cleanup()

    def test_shape_scope_and_https(self):
        self.assertEqual(self.http.get("/api/settings", headers=self.admin).status_code, 426)
        self.assertEqual(self.https.get("/api/settings", headers=self.reader).json()["scope"], "admin")
        body = self.https.get("/api/settings", headers=self.admin).json()
        self.assertEqual(set(body), {"runAtStartup", "startBeforeSignIn", "bootTaskAvailable", "notifications", "monitoring", "updates"})
        self.assertEqual(set(body["monitoring"]), {"gameProcesses", "networkInterface", "presentMonCSV", "libreHardwareMonitorURL",
                                                   "managedByEnvironment"})
        self.assertEqual(body["updates"]["version"], "5.0.0")

    def test_patch_validates_and_logs_the_device(self):
        response = self.https.patch("/api/settings", headers=self.admin,
                                    json={"monitoring": {"libreHardwareMonitorURL": "http://127.0.0.1:8086/data.json"}})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["monitoring"]["libreHardwareMonitorURL"], "http://127.0.0.1:8086/data.json")
        for body in ({"monitoring": {"libreHardwareMonitorURL": "http://evil.example/data.json"}}, {"monitoring": {"x": 1}},
                     {"updates": {"checkAutomatically": "yes"}}, {}, {"theme": "dark"}):
            self.assertEqual(self.https.patch("/api/settings", headers=self.admin, json=body).status_code, 422, body)
        self.log.wait()
        row = [entry for entry in self.log.entries(category="settings")["entries"] if entry["result"] == "ok"][0]
        self.assertEqual((row["deviceName"], row["summary"]), ("iPhone", "Monitoring: libreHardwareMonitorURL"))


if __name__ == "__main__":
    unittest.main()
