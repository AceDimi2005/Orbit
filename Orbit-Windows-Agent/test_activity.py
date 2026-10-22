"""Activity log, notifications, notification settings and the cancellable shutdown.

Power calls go to a fake adapter; nothing here can shut down, restart or sleep a PC.
"""
from pathlib import Path
import json
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_access as access
import orbit_activity as activity
import orbit_agent as agent
import orbit_devices as devices
import orbit_power as power
import orbit_screen as screen
import orbit_settings as settings_module

MASTER = "legacy-master-token-with-more-than-24-characters"


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class FakePower:
    def __init__(self):
        self.countdowns = []
        self.aborts = 0
        self.pending = False

    def countdown(self, action, seconds, comment):
        self.countdowns.append((action, seconds, comment))
        self.pending = True

    def abort(self):
        self.aborts += 1
        if not self.pending:
            raise power.NothingToCancel("No shutdown or restart is waiting on the PC.")
        self.pending = False


class ActivityLogTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.log = activity.ActivityLog(Path(self.folder.name) / "activity.sqlite3", clock=self.clock)

    def tearDown(self):
        self.log.close()
        self.folder.cleanup()

    def test_entries_are_newest_first_with_cursor_paging_and_category_filter(self):
        for index in range(5):
            self.clock.now += 1
            self.log.record("a" * 32, "iPhone", "power" if index % 2 else "files", f"act.{index}", f"Entry {index}")
        page = self.log.entries(limit=2)
        self.assertEqual([entry["summary"] for entry in page["entries"]], ["Entry 4", "Entry 3"])
        self.assertEqual(set(page["entries"][0]), {"id", "at", "deviceID", "deviceName", "category", "action",
                                                   "summary", "result", "status"})
        self.assertTrue(page["entries"][0]["at"].endswith("Z"))
        second = self.log.entries(before=page["nextBefore"], limit=2)
        self.assertEqual([entry["summary"] for entry in second["entries"]], ["Entry 2", "Entry 1"])
        last = self.log.entries(before=second["nextBefore"], limit=2)
        self.assertEqual([entry["summary"] for entry in last["entries"]], ["Entry 0"])
        self.assertIsNone(last["nextBefore"])
        self.assertEqual([entry["summary"] for entry in self.log.entries(category="power")["entries"]], ["Entry 3", "Entry 1"])

    def test_retention_row_cap_and_unknown_categories(self):
        self.log.record(None, "This PC", "not-a-category", "x", "Odd")
        self.assertEqual(self.log.entries()["entries"][0]["category"], "system")
        self.log.close()
        path = Path(self.folder.name) / "activity.sqlite3"
        self.clock.now += activity.RETENTION_SECONDS + 10
        reopened = activity.ActivityLog(path, clock=self.clock, max_rows=3)
        self.assertEqual(reopened.entries()["entries"], [])
        for index in range(250):
            reopened.record(None, "This PC", "system", "x", f"Row {index}")
        reopened.wait()
        reopened.close()
        self.log = activity.ActivityLog(path, clock=self.clock, max_rows=3)
        self.assertEqual(len(self.log.entries(limit=200)["entries"]), 3)

    def test_long_text_is_bounded_and_close_is_idempotent(self):
        self.log.record("a" * 32, "x" * 500, "files", "files.upload", "word " * 200)
        entry = self.log.entries()["entries"][0]
        self.assertLessEqual(len(entry["summary"]), 300)
        self.assertLessEqual(len(entry["deviceName"]), 80)
        self.log.close()
        self.log.close()
        self.log.record("a" * 32, "x", "files", "y", "after close")  # ignored, no error


class DescribeTests(unittest.TestCase):
    def context(self, method, path, policy=None, path_params=None, query=None, notes=None):
        principal = devices.Principal("a" * 32, "iPhone", frozenset(devices.SCOPES))
        context = access.RequestContext(principal, policy or access.policy_for(method, path), method, path,
                                        path_params or {}, query or {}, "10.0.0.2")
        context.notes.update(notes or {})
        return context

    def test_actions_get_their_own_category_and_words(self):
        self.assertEqual(activity.describe(self.context("POST", "/api/action/{action_name}", path_params={"action_name": "shutdown"}), 200),
                         ("power", "action.shutdown", "Shut down the PC (30-second warning on the PC)"))
        self.assertEqual(activity.describe(self.context("POST", "/api/action/{action_name}", path_params={"action_name": "media_next"}), 200)[0],
                         "media")
        self.assertEqual(activity.describe(self.context("POST", "/api/volume", query={"level": "40"}), 200),
                         ("audio", "volume.set", "Set the volume to 40%"))

    def test_endpoint_notes_win_and_contents_are_never_described(self):
        upload = self.context("POST", "/api/files/upload", query={"directory": "C:\\Users\\Me\\Downloads", "name": "IMG_1.jpg"})
        self.assertEqual(activity.describe(upload, 200)[2], "Uploaded IMG_1.jpg to Downloads")
        upload.notes["summary"] = "Uploaded IMG_1.jpg (2.0 MB) to Downloads"
        self.assertEqual(activity.describe(upload, 200)[2], "Uploaded IMG_1.jpg (2.0 MB) to Downloads")
        clipboard = self.context("PUT", "/api/clipboard", query={"text": "secret"})
        self.assertEqual(activity.describe(clipboard, 200)[2], "Sent text to the PC clipboard")

    def test_results(self):
        self.assertEqual(activity.result_for(200), "ok")
        self.assertEqual(activity.result_for(403), "denied")
        self.assertEqual(activity.result_for(503), "error")
        self.assertEqual(activity.result_for(None), "error")


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.shown = []
        self.settings = dict(settings_module.DEFAULTS["notifications"])
        self.gaming = False
        self.clock = Clock(0)
        self.notifier = activity.Notifier(show=lambda title, message: self.shown.append((title, message)) or True,
                                          settings=lambda: self.settings, gaming=lambda: self.gaming, clock=self.clock)

    def test_settings_switch_kinds_off(self):
        self.settings["newDevice"] = False
        self.assertFalse(self.notifier.notify("newDevice", "t", "m"))
        self.assertTrue(self.notifier.notify("power", "t", "m"))
        self.assertEqual(len(self.shown), 1)

    def test_quiet_while_gaming_spares_security_notifications(self):
        self.gaming = True
        for kind in ("files", "screenView", "inputSession"):
            self.assertFalse(self.notifier.notify(kind, "t", "m"))
        self.assertTrue(self.notifier.notify("newDevice", "t", "m"))
        self.assertTrue(self.notifier.notify("power", "t", "m"))
        self.settings["quietWhileGaming"] = False
        self.assertTrue(self.notifier.notify("files", "t", "m"))

    def test_bursts_are_throttled_and_counted(self):
        self.assertTrue(self.notifier.notify("files", "t", "first", key="phone"))
        self.assertFalse(self.notifier.notify("files", "t", "second", key="phone"))
        self.assertFalse(self.notifier.notify("files", "t", "third", key="phone"))
        self.assertTrue(self.notifier.notify("files", "t", "other device", key="tv"))
        self.clock.now += 31
        self.assertTrue(self.notifier.notify("files", "t", "fourth", key="phone"))
        self.assertEqual(self.shown[-1][1], "fourth (+2 more)")

    def test_without_a_tray_nothing_is_shown(self):
        self.assertFalse(activity.Notifier(show=None).notify("power", "t", "m"))

    def test_input_sessions_start_after_idle(self):
        sessions = activity.InputSessions(idle_seconds=120, clock=self.clock)
        self.assertTrue(sessions.touch("phone"))
        self.clock.now += 60
        self.assertFalse(sessions.touch("phone"))
        self.clock.now += 121
        self.assertTrue(sessions.touch("phone"))


class SettingsTests(unittest.TestCase):
    def test_defaults_validation_and_persistence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            path.write_text("{broken")
            stored = settings_module.Settings(path)
            self.assertEqual(stored.notifications(), settings_module.DEFAULTS["notifications"])
            self.assertFalse(stored.update_notifications({"files": False})["files"])
            for bad in ({}, {"nope": True}, {"files": "no"}, []):
                with self.assertRaises(settings_module.SettingsError):
                    stored.update_notifications(bad)
            self.assertFalse(settings_module.Settings(path).notifications()["files"])
            raw = json.loads(path.read_text())
            raw["notifications"]["power"] = "maybe"
            raw["somethingElse"] = {"kept": True}
            path.write_text(json.dumps(raw))
            reloaded = settings_module.Settings(path)
            self.assertTrue(reloaded.notifications()["power"])
            self.assertEqual(reloaded.get("somethingElse"), {"kept": True})


class PowerAdapterTests(unittest.TestCase):
    def test_comment_never_carries_quotes_or_shell_characters(self):
        comment = power.shutdown_comment("restart", 'Bad "name" & | ^ % <x>')
        self.assertNotRegex(comment, r'["&|^%<>]')
        self.assertTrue(comment.startswith("Orbit: restart requested from Bad name"))
        self.assertIn("a paired device", power.shutdown_comment("shutdown", None))

    def test_windows_commands_and_cancel_codes(self):
        calls = []
        adapter = power.WindowsPower(runner=lambda arguments: calls.append(arguments) or SimpleNamespace(returncode=0))
        adapter.countdown("shutdown", 30, "Orbit: test")
        adapter.countdown("restart", 30, "Orbit: test")
        adapter.abort()
        self.assertEqual(calls, [["shutdown", "/s", "/t", "30", "/c", "Orbit: test"],
                                 ["shutdown", "/r", "/t", "30", "/c", "Orbit: test"], ["shutdown", "/a"]])
        with self.assertRaises(ValueError):
            adapter.countdown("sleep", 30, "x")
        nothing = power.WindowsPower(runner=lambda arguments: SimpleNamespace(returncode=1116))
        with self.assertRaises(power.NothingToCancel):
            nothing.abort()

    def test_the_real_runner_refuses_off_windows(self):
        with patch.object(power.os, "name", "posix"), patch.object(power.subprocess, "run") as run:
            with self.assertRaises(power.PowerUnavailable):
                power.WindowsPower().countdown("shutdown", 30, "x")
            run.assert_not_called()


class ActivityAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.registry.migrate_legacy(MASTER)
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        self.settings = settings_module.Settings(root / "settings.json")
        self.power = FakePower()
        self.shown = []
        notifier = activity.Notifier(show=lambda title, message: self.shown.append((title, message)) or True,
                                     settings=self.settings.notifications, gaming=lambda: False)
        self.patches = [patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "API_TOKEN", MASTER),
                        patch.object(agent, "ACTIVITY", self.log), patch.object(agent, "SETTINGS", self.settings),
                        patch.object(agent, "POWER", self.power), patch.object(agent, "NOTIFIER", notifier),
                        patch.object(agent, "INPUT_SESSIONS", activity.InputSessions())]
        for item in self.patches:
            item.start()
        self.http = TestClient(agent.app)
        self.https = TestClient(agent.app, base_url="https://testserver")
        device, token = self.registry.register("Orbit on iPhone", "iOS")
        self.device = device
        self.auth = {"Authorization": f"Bearer {token}"}

    def tearDown(self):
        self.http.close()
        self.https.close()
        for item in reversed(self.patches):
            item.stop()
        self.log.close()
        self.folder.cleanup()

    def entries(self, **query):
        return self.https.get("/api/activity", headers=self.auth, params=query).json()["entries"]

    def test_state_changes_are_logged_with_the_device_and_reads_are_not(self):
        volume = MagicMock()
        from contextlib import contextmanager

        @contextmanager
        def endpoint():
            yield volume
        with patch.object(agent, "require_windows"), patch.object(agent, "endpoint_volume", endpoint), \
             patch.object(agent, "audio_metrics", return_value={"volume": 40.0, "isMuted": False, "volumeAvailable": True}):
            self.assertEqual(self.http.post("/api/volume?level=40", headers=self.auth).status_code, 200)
        self.http.get("/api/status", headers=self.auth)
        rows = self.entries()
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["deviceID"], rows[0]["deviceName"], rows[0]["category"], rows[0]["summary"], rows[0]["result"]),
                         (self.device["id"], "iPhone", "audio", "Set the volume to 40%", "ok"))

    def test_denied_attempts_are_logged_for_the_owner(self):
        _, token = self.registry.register("Apple TV · Orbit", "tvOS", scopes=["read"])
        response = self.http.post("/api/action/lock", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(response.status_code, 403)
        row = self.entries()[0]
        self.assertEqual((row["deviceName"], row["action"], row["result"], row["status"]), ("Apple TV", "action.lock", "denied", 403))

    def test_shutdown_uses_the_windows_countdown_and_can_be_cancelled(self):
        with patch.object(agent, "require_windows"), patch.object(agent.ctypes, "windll", create=True):
            response = self.http.post("/api/action/shutdown", headers=self.auth)
        self.assertEqual(response.json(), {"status": "sent", "executed": "shutdown", "delaySeconds": 30})
        action, seconds, comment = self.power.countdowns[0]
        self.assertEqual((action, seconds), ("shutdown", 30))
        self.assertIn("requested from iPhone", comment)
        self.assertTrue(any("Shut down the PC" in message for _, message in self.shown))
        with patch.object(agent, "require_windows"):
            # Cancelling also works over plain HTTP, so even old Watch builds can stop it.
            self.assertEqual(self.http.post("/api/power/cancel", headers=self.auth).json(), {"status": "cancelled"})
            again = self.http.post("/api/power/cancel", headers=self.auth)
        self.assertEqual(again.status_code, 409)
        summaries = [row["summary"] for row in self.entries(category="power")]
        self.assertIn("Cancelled the pending shutdown or restart", summaries)

    def test_input_sessions_log_once_and_notify(self):
        with patch.object(agent, "require_windows"), patch.object(agent, "_apply_cursor_operation"):
            for _ in range(5):
                self.assertEqual(self.http.post("/api/input/mouse?dx=3", headers=self.auth).status_code, 200)
        rows = self.entries(category="input")
        self.assertEqual([row["summary"] for row in rows], ["Started controlling the mouse and keyboard"])
        self.assertEqual(sum("controlling the mouse" in message for _, message in self.shown), 1)

    def test_screen_viewing_is_logged_and_notified(self):
        grab = SimpleNamespace(monitors=[{}, {"left": 0}], grab=lambda monitor: SimpleNamespace(size=(1, 1), bgra=b"\x00\x00\x00\x00"))
        with patch.object(agent, "HAS_SCREEN_CAPTURE", True), \
             patch.object(agent, "screen_frame_source", lambda: screen.FrameSource(capture_factory=lambda: grab)):
            with self.http.websocket_connect("/ws/stream", headers=self.auth) as websocket:
                websocket.receive_bytes()
        self.assertEqual(self.entries(category="screen")[0]["summary"], "Started viewing the screen")
        self.assertIn(("Orbit · Screen", "iPhone is viewing your screen."), self.shown)

    def test_new_device_is_logged_and_notified_unless_switched_off(self):
        with patch.object(agent, "current_principal", return_value=None):
            agent.register_paired_device({"name": "Orbit on Mac", "platform": "macOS"}, "192.168.1.40")
        self.assertEqual(self.entries(category="devices")[0]["summary"], "Paired Mac (Mac) from 192.168.1.40")
        self.assertEqual(self.shown[-1][0], "Orbit · New device")
        self.assertEqual(self.https.patch("/api/settings/notifications", headers=self.auth, json={"newDevice": False}).status_code, 200)
        count = len(self.shown)
        with patch.object(agent, "current_principal", return_value=None):
            agent.register_paired_device({"name": "Orbit on iPad", "platform": "iPadOS"}, "192.168.1.41")
        self.assertEqual(len(self.shown), count)

    def test_notification_settings_api(self):
        self.assertEqual(self.http.get("/api/settings/notifications", headers=self.auth).status_code, 426)
        self.assertEqual(self.https.get("/api/settings/notifications", headers=self.auth).json(),
                         settings_module.DEFAULTS["notifications"])
        updated = self.https.patch("/api/settings/notifications", headers=self.auth, json={"files": False, "quietWhileGaming": False})
        self.assertEqual((updated.json()["files"], updated.json()["quietWhileGaming"]), (False, False))
        for body in ({"files": "off"}, {"unknown": True}, {}):
            self.assertEqual(self.https.patch("/api/settings/notifications", headers=self.auth, json=body).status_code, 422)
        rows = self.entries(category="settings")
        self.assertEqual([row["result"] for row in rows], ["error", "error", "error", "ok"])
        self.assertTrue(all(row["summary"].startswith("Changed notification settings") for row in rows))
        self.assertIn("files off", rows[-1]["summary"])

    def test_activity_api_validation_and_scope(self):
        self.assertEqual(self.https.get("/api/activity?category=nonsense", headers=self.auth).status_code, 422)
        self.assertEqual(self.https.get("/api/activity?limit=500", headers=self.auth).status_code, 422)
        body = self.https.get("/api/activity", headers=self.auth).json()
        self.assertEqual(set(body), {"entries", "nextBefore", "categories"})
        _, reader = self.registry.register("Reader", scopes=["read"])
        self.assertEqual(self.https.get("/api/activity", headers={"Authorization": f"Bearer {reader}"}).json()["scope"], "admin")

    def test_file_transfers_are_described_with_names_and_notified(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            uploaded = self.https.post("/api/files/upload", headers=self.auth, params={"directory": str(root), "name": "photo.jpg"},
                                       content=b"x" * 2048)
            self.assertEqual(uploaded.status_code, 200)
            self.assertEqual(self.https.get("/api/files/download", headers=self.auth,
                                            params={"path": str(root / "photo.jpg")}).status_code, 200)
            self.https.post("/api/files/rename", headers=self.auth, json={"path": str(root / "photo.jpg"), "name": "beach.jpg"})
        summaries = [row["summary"] for row in self.entries(category="files")]
        self.assertEqual(summaries[:3], ["Renamed photo.jpg to beach.jpg", "Downloaded photo.jpg (2.0 KB)",
                                         f"Uploaded photo.jpg (2.0 KB) to {root.name}"])
        file_notes = [message for title, message in self.shown if title == "Orbit · Files"]
        self.assertEqual(len(file_notes), 1)  # a burst is one notification


if __name__ == "__main__":
    unittest.main()
