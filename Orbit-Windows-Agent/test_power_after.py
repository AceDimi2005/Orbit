"""Power after downloads / a watched program: the state machine, cancel during the countdown, the
route. `perform` is always a mock: nothing sleeps or shuts down."""
import threading
import time
import types
import unittest
from unittest.mock import MagicMock

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_downloads
import orbit_power_after as power

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class FakeDownloads:
    """A real DownloadsWatcher whose only launcher reports what the test says (polled on every tick)."""

    STATES = {"finished": "complete"}

    def __init__(self, clock):
        self.observations = {}
        self.stores = True
        launcher = types.SimpleNamespace(present=lambda: self.stores, scan=lambda tracked: list(self.observations.values()))
        self.watcher = orbit_downloads.DownloadsWatcher(monotonic=clock, clock=clock, emit=MagicMock(),
                                                        scanners={"steam": launcher})
        self.watcher.poll()

    def set(self, state, ident="steam:620", name="Portal 2"):
        self.observations[ident] = orbit_downloads.Observation(ident, "steam", name, self.STATES.get(state, state), 0.5, 5, 10)
        self.watcher.poll()

    def remove(self, ident="steam:620"):
        self.observations.pop(ident, None)
        self.watcher.poll()

    def set_active(self, active):
        """The old shorthand: one download running, then finished."""
        self.set("downloading" if active else "finished")


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
        self.toasts = []
        self.service = power.PowerAfter(perform=self.perform, downloads=lambda: self.downloads.watcher, tasks=lambda: self.tasks,
                                        emit=self.record, clock=self.wall, monotonic=self.mono,
                                        idle_seconds=lambda: self.idle, before_execute=self.before, hostname="Gaming-PC",
                                        notify=lambda title, message: self.toasts.append((title, message)))

    def record(self, kind, title, body, level="active", data=None, toast=True):
        self.events.append({"kind": kind, "title": title, "body": body, "level": level, "data": data, "toast": toast})
        return self.events[-1]

    def advance(self, seconds, step=1.0):
        results = []
        elapsed = 0.0
        while elapsed < seconds:
            self.mono.now += step
            self.wall.now += step
            elapsed += step
            self.downloads.watcher.poll()
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
        # The person at the PC gets their own words: using the PC is what keeps it on.
        self.assertFalse(scheduled["toast"])
        self.assertEqual(self.toasts, [("Sleeping in 60 s", "Downloads finished. Move the mouse or press a key to keep the PC on.")])
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

    def test_rule_set_while_nothing_downloads_waits_for_a_download(self):
        self.service.set_rule({"trigger": "downloads", "action": "shutdown", "delaySeconds": 30})
        self.assertEqual(self.advance(3600), [])  # never "finished" when nothing ever downloaded
        self.perform.assert_not_called()
        self.downloads.set_active(True)  # started later, for example from the Steam mobile app
        self.advance(300)
        self.downloads.set_active(False)
        self.assertEqual(self.advance(59), [])
        self.assertEqual(self.advance(1), ["scheduled"])
        self.assertEqual(self.events[-1]["title"], "Shutting down in 30 s")
        self.advance(30)
        self.perform.assert_called_once_with("shutdown")

    def test_activity_during_the_quiet_minute_restarts_it(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.downloads.set_active(False)
        self.advance(50)
        self.downloads.set("downloading", "steam:730", "Counter-Strike 2")
        self.advance(20)
        self.downloads.set("finished", "steam:730", "Counter-Strike 2")
        self.assertEqual(self.advance(59), [])
        self.assertEqual(self.advance(1), ["scheduled"])

    def test_a_download_that_ends_before_the_next_poll_still_counts(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.downloads.observations.clear()  # canceled right away
        self.assertEqual(self.advance(60), ["scheduled"])
        self.assertEqual(self.events[-1]["body"], "Nothing is downloading any more. Cancel from Orbit if you're still using the PC.")

    def test_a_paused_download_keeps_the_rule_waiting(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.advance(30)
        self.downloads.set("paused")  # Steam pauses downloads while a game runs (a controller is not "input")
        self.assertEqual(self.advance(3 * 3600), [])
        self.downloads.set("downloading")
        self.advance(60)
        self.downloads.set("finished")
        self.assertEqual(self.advance(60), ["scheduled"])

    def test_a_download_paused_before_the_rule_does_not_hold_it(self):
        self.downloads.set("paused", "steam:400", "Portal")  # paused weeks ago
        self.downloads.set("downloading")
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.advance(10)
        self.downloads.set("finished")
        self.assertEqual(self.advance(60), ["scheduled"])

    def test_failed_downloads_are_named(self):
        self.downloads.set("downloading")
        self.downloads.set("downloading", "steam:730", "Counter-Strike 2")
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.downloads.set("failed", "steam:730", "Counter-Strike 2")
        self.downloads.set("finished")
        self.assertEqual(self.advance(60), ["scheduled"])
        self.assertEqual(self.events[-1]["body"], "Downloads finished, but Counter-Strike 2 failed. Cancel from Orbit if you're still using the PC.")
        self.service.cancel()
        self.downloads.set("downloading", "steam:440", "Team Fortress 2")
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.downloads.set("failed", "steam:440", "Team Fortress 2")
        self.assertEqual(self.advance(60), ["scheduled"])
        self.assertTrue(self.events[-1]["body"].startswith("Downloads stopped: Team Fortress 2 failed."))

    def test_cancel_during_the_countdown_never_sleeps(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 120})
        self.downloads.set_active(False)
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
        self.service.set_rule({"trigger": "downloads", "action": "sleep"})
        self.service.cancel()
        self.assertEqual(self.events[-1]["body"], "Orbit won't put the PC to sleep after the downloads.")
        self.downloads.set_active(False)
        self.assertEqual(self.advance(300), [])

    def test_a_new_rule_replaces_the_old_one_and_cancels_its_countdown(self):
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 300})
        self.downloads.set_active(False)
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
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 60})
        self.downloads.set_active(False)
        self.advance(60)
        self.idle = 12.0  # the mouse moved 12 s ago, during the countdown
        self.assertEqual(self.advance(60), ["cancelled"])
        self.perform.assert_not_called()
        self.assertEqual(self.events[-1]["kind"], "power.cancelled")
        self.assertEqual(self.events[-1]["body"], "Someone used the PC during the countdown, so it stayed on.")
        self.assertEqual(self.service.snapshot(), {"rule": None})

    def test_unknown_idle_time_does_not_block(self):
        self.idle = None
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        self.downloads.set_active(False)
        self.advance(90)
        self.perform.assert_called_once_with("sleep")

    def test_windows_refusing_is_reported(self):
        self.perform.side_effect = HTTPException(503, "Windows could not execute this action")
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        self.downloads.set_active(False)
        with self.assertLogs("orbit.power_after", "WARNING"):
            self.assertEqual(self.advance(90), ["scheduled", "failed"])
        self.assertEqual(self.events[-1]["title"], "Couldn't go to sleep")
        self.assertEqual(self.events[-1]["body"], "Windows didn't let Orbit put the PC to sleep.")
        self.assertEqual(self.events[-1]["data"]["reason"], "failed")

    def test_cancel_while_executing_is_refused(self):
        started, release = threading.Event(), threading.Event()

        def slow(action):
            started.set()
            release.wait(5)
        self.perform.side_effect = slow
        self.downloads.set_active(True)
        self.service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        self.downloads.set_active(False)
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
        self.downloads.watcher.detect_stores()
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

    def test_removing_the_finished_task_during_the_countdown_keeps_it(self):
        self.service.set_rule({"trigger": "task", "taskID": "t1", "action": "sleep", "delaySeconds": 60})
        self.tasks.tasks["t1"]["state"] = "finished"
        self.assertEqual(self.advance(1), ["scheduled"])
        removed = self.tasks.tasks.pop("t1")  # cleaned up from the list in Orbit
        self.service.task_changed("removed", removed)
        self.assertEqual(self.service.snapshot()["rule"]["state"], "countdown")
        self.assertEqual(self.advance(60), ["executed"])
        self.perform.assert_called_once_with("sleep")
        self.assertEqual(self.kinds(), ["power.scheduled", "power.executing"])

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
        service = power.PowerAfter(perform=perform, downloads=lambda: downloads.watcher, emit=MagicMock(), monotonic=mono,
                                   idle_seconds=lambda: None, notify=MagicMock())
        stop = threading.Event()
        thread = service.start(stop)
        self.addCleanup(stop.set)
        downloads.set_active(True)
        service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        downloads.set_active(False)
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
        downloads.set("downloading", "steam:730")
        service.set_rule({"trigger": "downloads", "action": "sleep", "delaySeconds": 30})
        downloads.set("finished", "steam:730")
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
