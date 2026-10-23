"""Power after downloads / a watched program: the state machine, cancel during the countdown, the
route. `perform` is always a mock: nothing sleeps or shuts down."""
import threading
import time
import unittest
from unittest.mock import MagicMock

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_power_after as power

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class FakeDownloads:
    def __init__(self, clock):
        self.clock = clock
        self.active = False
        self.last_active = None
        self.stores = True
        self.tracker = type("Tracker", (), {"polled": True})()

    def any_store(self):
        return self.stores

    def quiet_since(self):
        if self.active:
            return None
        return self.last_active if self.last_active is not None else 0.0

    def set_active(self, active):
        if self.active and not active:
            self.last_active = self.clock.now
        self.active = active


class FakeTasks:
    def __init__(self):
        self.tasks = {}

    def get(self, task_id):
        task = self.tasks.get(task_id)
        return dict(task) if task else None


class Machine(unittest.TestCase):
    def setUp(self):
        self.mono = Clock(1000.0)
        self.wall = Clock(1_790_000_000.0)
        self.downloads = FakeDownloads(self.mono)
        self.tasks = FakeTasks()
        self.events = []
        self.perform = MagicMock(return_value={"status": "sent"})
        self.idle = 10_000.0  # nobody touched the PC
        self.before = MagicMock()
        self.service = power.PowerAfter(perform=self.perform, downloads=lambda: self.downloads, tasks=lambda: self.tasks,
                                        emit=self.record, clock=self.wall, monotonic=self.mono,
                                        idle_seconds=lambda: self.idle, before_execute=self.before, hostname="Gaming-PC")

    def record(self, kind, title, body, level="active", data=None):
        self.events.append({"kind": kind, "title": title, "body": body, "level": level, "data": data})
        return self.events[-1]

    def advance(self, seconds, step=1.0):
        results = []
        elapsed = 0.0
        while elapsed < seconds:
            self.mono.now += step
            self.wall.now += step
            elapsed += step
            result = self.service.tick()
            if result:
                results.append(result)
        return results

    def kinds(self):
        return [event["kind"] for event in self.events]


class DownloadsRuleTests(Machine):
    def test_waits_for_downloads_then_counts_down_and_sleeps(self):
        self.downloads.set_active(True)
        rule = self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 60})["rule"]
        self.assertEqual(rule, {"trigger": "downloads", "taskID": None, "action": "sleep", "delaySeconds": 60,
                                "state": "waiting", "countdownEndsAt": None})
        self.assertEqual(self.advance(300), [])
        self.downloads.set_active(False)
        self.assertEqual(self.advance(59), [])
        self.assertEqual(self.advance(1), ["scheduled"])
        snapshot = self.service.snapshot()["rule"]
        self.assertEqual(snapshot["state"], "countdown")
        self.assertEqual(snapshot["countdownEndsAt"], "2026-09-21T14:20:20Z")
        scheduled = self.events[-1]
        self.assertEqual((scheduled["kind"], scheduled["title"], scheduled["level"]), ("power.scheduled", "Sleeping in 60 s", "timeSensitive"))
        self.assertEqual(scheduled["body"], "Downloads finished. Cancel from Orbit if you're still using the PC.")
        self.assertEqual(scheduled["data"]["delaySeconds"], 60)
        self.assertEqual(self.advance(59), [])
        self.perform.assert_not_called()
        self.assertEqual(self.advance(1), ["executed"])
        self.perform.assert_called_once_with("sleep")
        self.before.assert_called_once_with()
        self.assertEqual(self.kinds(), ["power.scheduled", "power.executing"])
        self.assertEqual(self.events[-1]["title"], "Going to sleep now")
        self.assertEqual(self.events[-1]["body"], "Downloads finished. Gaming-PC will go to sleep.")
        self.assertEqual(self.service.snapshot(), {"rule": None})
        self.assertEqual(self.advance(120), [])
        self.perform.assert_called_once()

    def test_rule_set_while_nothing_downloads_fires_after_a_quiet_minute(self):
        self.downloads.last_active = None
        self.service.set_rule({"trigger": "downloads", "action": "shutdown", "delaySeconds": 30})
        self.assertEqual(self.advance(59), [])
        self.assertEqual(self.advance(1), ["scheduled"])
        self.assertEqual(self.events[-1]["title"], "Shutting down in 30 s")
        self.advance(30)
        self.perform.assert_called_once_with("shutdown")

    def test_activity_during_the_wait_restarts_the_quiet_minute(self):
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.advance(50)
        self.downloads.set_active(True)
        self.advance(20)
        self.downloads.set_active(False)
        self.assertEqual(self.advance(59), [])
        self.assertEqual(self.advance(1), ["scheduled"])

    def test_cancel_during_the_countdown_never_sleeps(self):
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 120})
        self.advance(60)
        self.assertEqual(self.service.snapshot()["rule"]["state"], "countdown")
        self.advance(100)
        self.assertTrue(self.service.cancel())
        self.assertEqual(self.advance(600), [])
        self.perform.assert_not_called()
        self.assertEqual(self.kinds(), ["power.scheduled", "power.cancelled"])
        self.assertEqual(self.events[-1]["title"], "Sleep cancelled")
        self.assertEqual(self.events[-1]["body"], "Cancelled from Orbit. The PC will stay on.")
        self.assertEqual(self.events[-1]["data"]["state"], "countdown")
        self.assertFalse(self.service.cancel())

    def test_cancel_a_waiting_rule(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "shutdown"})
        self.assertTrue(self.service.cancel())
        self.assertEqual(self.events[-1]["body"], "Orbit won't shut down the PC after the downloads.")
        self.downloads.set_active(False)
        self.assertEqual(self.advance(300), [])

    def test_a_new_rule_replaces_the_old_one_and_cancels_its_countdown(self):
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 300})
        self.advance(61)
        self.assertEqual(self.service.snapshot()["rule"]["state"], "countdown")
        self.downloads.set_active(True)
        rule = self.service.set_rule({"trigger": "downloads", "action": "shutdown", "delaySeconds": 30})["rule"]
        self.assertEqual((rule["action"], rule["state"]), ("shutdown", "waiting"))
        self.assertEqual(self.kinds(), ["power.scheduled", "power.cancelled"])
        self.assertEqual(self.events[-1]["data"]["reason"], "replaced")
        self.assertEqual(self.advance(600), [])
        self.perform.assert_not_called()

    def test_someone_using_the_pc_cancels_at_the_end(self):
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 60})
        self.advance(60)
        self.idle = 12.0  # the mouse moved 12 s ago, during the countdown
        self.assertEqual(self.advance(60), ["cancelled"])
        self.perform.assert_not_called()
        self.assertEqual(self.events[-1]["kind"], "power.cancelled")
        self.assertEqual(self.events[-1]["body"], "Someone used the PC during the countdown, so it stayed on.")
        self.assertEqual(self.service.snapshot(), {"rule": None})

    def test_unknown_idle_time_does_not_block(self):
        self.idle = None
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        self.advance(90)
        self.perform.assert_called_once_with("sleep")

    def test_windows_refusing_is_reported(self):
        self.perform.side_effect = HTTPException(503, "Windows could not execute this action")
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        with self.assertLogs("orbit.power_after", "WARNING"):
            self.assertEqual(self.advance(90), ["scheduled", "failed"])
        self.assertEqual(self.events[-1]["title"], "Couldn't go to sleep")
        self.assertEqual(self.events[-1]["data"]["reason"], "failed")

    def test_cancel_while_executing_is_refused(self):
        started, release = threading.Event(), threading.Event()

        def slow(action):
            started.set()
            release.wait(5)
        self.perform.side_effect = slow
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        self.advance(60)
        self.mono.now += 30
        worker = threading.Thread(target=self.service.tick)
        worker.start()
        self.assertTrue(started.wait(5))
        with self.assertRaises(power.PowerAfterError) as late:
            self.service.cancel()
        self.assertEqual(late.exception.status, 409)
        with self.assertRaises(power.PowerAfterError):
            self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        release.set()
        worker.join(5)
        self.assertFalse(self.service.cancel())

    def test_no_launcher_is_refused(self):
        self.downloads.stores = False
        with self.assertRaises(power.PowerAfterError) as refused:
            self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.assertEqual(refused.exception.status, 409)
        self.assertIn("Steam", refused.exception.message)


class TaskRuleTests(Machine):
    def setUp(self):
        super().setUp()
        self.tasks.tasks["t1"] = {"id": "t1", "label": "Blender", "state": "watching"}

    def test_fires_when_the_task_finishes(self):
        rule = self.service.set_rule({"trigger": "task", "taskID": "t1", "action": "shutdown", "delaySeconds": 45})["rule"]
        self.assertEqual((rule["trigger"], rule["taskID"]), ("task", "t1"))
        self.assertEqual(self.advance(600), [])
        self.tasks.tasks["t1"]["state"] = "finished"
        self.service.task_changed("finished", self.tasks.get("t1"))
        self.assertEqual(self.advance(1), ["scheduled"])
        self.assertEqual(self.events[-1]["body"], "Blender finished. Cancel from Orbit if you're still using the PC.")
        self.assertEqual(self.events[-1]["title"], "Shutting down in 45 s")
        self.advance(45)
        self.perform.assert_called_once_with("shutdown")
        self.assertEqual(self.events[-1]["body"], "Blender finished. Gaming-PC will shut down.")

    def test_gone_counts_as_finished(self):
        self.service.set_rule({"trigger": "task", "taskID": "t1", "action": "sleep"})
        self.tasks.tasks["t1"]["state"] = "gone"
        self.assertEqual(self.advance(1), ["scheduled"])
        self.assertTrue(self.events[-1]["body"].startswith("Blender closed."))

    def test_removing_the_task_cancels_the_rule(self):
        self.service.set_rule({"trigger": "task", "taskID": "t1", "action": "sleep"})
        removed = self.tasks.tasks.pop("t1")
        self.service.task_changed("removed", removed)
        self.assertEqual(self.service.snapshot(), {"rule": None})
        self.assertEqual(self.events[-1]["kind"], "power.cancelled")
        self.assertIn("no longer being watched", self.events[-1]["body"])
        # Listeners for other tasks do nothing.
        self.service.task_changed("removed", {"id": "other"})
        self.assertEqual(len(self.events), 1)

    def test_validation(self):
        cases = [
            ({"trigger": "task", "action": "sleep"}, 422),
            ({"trigger": "task", "taskID": "missing", "action": "sleep"}, 404),
            ({"trigger": "reboot"}, 422),
            ({"trigger": "downloads", "action": "restart"}, 422),
            ({"trigger": "downloads", "action": "sleep", "delaySeconds": 29}, 422),
            ({"trigger": "downloads", "action": "sleep", "delaySeconds": 601}, 422),
            ({"trigger": "downloads", "action": "sleep", "delaySeconds": 30.5}, 422),
            ({"trigger": "downloads", "action": "sleep", "delaySeconds": True}, 422),
            ("sleep", 422),
        ]
        for body, status in cases:
            with self.subTest(body=body), self.assertRaises(power.PowerAfterError) as refused:
                self.service.set_rule(body)
            self.assertEqual(refused.exception.status, status)
        self.tasks.tasks["t1"]["state"] = "finished"
        with self.assertRaises(power.PowerAfterError) as done:
            self.service.set_rule({"trigger": "task", "taskID": "t1", "action": "sleep"})
        self.assertEqual(done.exception.status, 409)
        self.assertEqual(self.service.snapshot(), {"rule": None})
        self.assertEqual(self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 600.0})["rule"]["delaySeconds"], 600)


class ThreadTests(unittest.TestCase):
    def test_worker_runs_the_countdown_and_a_cancel_wakes_it(self):
        mono = Clock(0.0)
        downloads = FakeDownloads(mono)
        perform = MagicMock()
        service = power.PowerAfter(perform=perform, downloads=lambda: downloads, emit=MagicMock(), monotonic=mono,
                                   idle_seconds=lambda: None)
        stop = threading.Event()
        thread = service.start(stop)
        self.addCleanup(stop.set)
        service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        mono.now = 61.0
        service.wake()
        deadline = time.monotonic() + 5
        while service.snapshot()["rule"]["state"] != "countdown" and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(service.snapshot()["rule"]["state"], "countdown")
        self.assertTrue(service.cancel())
        mono.now = 1000.0
        service.wake()
        time.sleep(0.2)
        perform.assert_not_called()
        service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        mono.now = 1061.0
        service.wake()
        while service.snapshot()["rule"] is not None and service.snapshot()["rule"]["state"] != "countdown":
            time.sleep(0.01)
        mono.now = 1100.0
        service.wake()
        deadline = time.monotonic() + 5
        while not perform.called and time.monotonic() < deadline:
            time.sleep(0.01)
        perform.assert_called_once_with("sleep")
        stop.set()
        service.wake()
        thread.join(3)
        self.assertFalse(thread.is_alive())


class RouteTests(Machine):
    def setUp(self):
        super().setUp()
        self.windows = MagicMock()

        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")
        app = FastAPI()
        app.include_router(power.create_power_after_router(verify, lambda: self.service, require_windows=self.windows))
        self.client = TestClient(app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.http = TestClient(app)
        self.addCleanup(self.http.close)

    def test_get_put_delete(self):
        self.assertEqual(self.client.get("/api/power/after", headers=AUTH).json(), {"rule": None})
        self.downloads.set_active(True)
        response = self.client.put("/api/power/after", json={"trigger": "downloads", "action": "sleep", "delaySeconds": 60, "taskID": None}, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["rule"]["state"], "waiting")
        self.windows.assert_called_once_with()
        self.assertEqual(self.client.get("/api/power/after", headers=AUTH).json()["rule"]["trigger"], "downloads")
        self.assertEqual(self.client.delete("/api/power/after", headers=AUTH).json(), {"rule": None, "cancelled": True})
        self.assertEqual(self.client.delete("/api/power/after", headers=AUTH).json(), {"rule": None, "cancelled": False})

    def test_errors(self):
        response = self.client.put("/api/power/after", json={"trigger": "downloads", "delaySeconds": 5}, headers=AUTH)
        self.assertEqual(response.status_code, 422)
        self.assertIn("30 to 600", response.json()["detail"])
        self.windows.side_effect = HTTPException(501, "PC controls require Windows")
        self.assertEqual(self.client.put("/api/power/after", json={"trigger": "downloads"}, headers=AUTH).status_code, 501)

    def test_token_then_https(self):
        for method in ("get", "put", "delete"):
            with self.subTest(method=method):
                self.assertEqual(getattr(self.client, method)("/api/power/after").status_code, 401)
                self.assertEqual(getattr(self.http, method)("/api/power/after", headers=AUTH).status_code, 426)


if __name__ == "__main__":
    unittest.main()
