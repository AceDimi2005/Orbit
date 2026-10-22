"""Power timers, keep-awake, plans and their API, with a fake backend and a fake clock.

No test here can sleep, hibernate, sign out, shut down or restart anything.
"""
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fastapi.testclient import TestClient

import orbit_activity as activity
import orbit_agent as agent
import orbit_devices as devices
import orbit_power as power

PLANS_EN = """
Existing Power Schemes (* Active)
-----------------------------------
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *
Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)
Power Scheme GUID: a1841308-3541-4fab-bc81-f71556f20b4a  (Power saver)
"""
PLANS_RO = """
Scheme de alimentare existente (* Activă)
-----------------------------------
GUID schemă de alimentare: 381b4222-f694-41f0-9685-ff5bb260df2e  (Echilibrat)
GUID schemă de alimentare: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Performanță ridicată) *
"""


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class FakeBackend:
    def __init__(self, path=None):
        self.executed = []
        self.aborts = 0
        self.states = []
        self.path = path
        self.on_disk_when_executed = []
        self.fail = None

    def execute(self, action, comment, seconds=30):
        if self.path is not None:
            self.on_disk_when_executed.append(json.loads(Path(self.path).read_text())["timer"])
        if self.fail:
            raise power.PowerUnavailable(self.fail)
        self.executed.append((action, seconds, comment))

    def abort(self):
        self.aborts += 1

    def set_execution_state(self, flags):
        self.states.append(flags)


class PlanParsingTests(unittest.TestCase):
    def test_english_and_localized_powercfg_output(self):
        self.assertEqual(power.parse_power_plans(PLANS_EN), [
            {"id": "381b4222-f694-41f0-9685-ff5bb260df2e", "name": "Balanced", "active": True},
            {"id": "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c", "name": "High performance", "active": False},
            {"id": "a1841308-3541-4fab-bc81-f71556f20b4a", "name": "Power saver", "active": False}])
        romanian = power.parse_power_plans(PLANS_RO)
        self.assertEqual([(plan["name"], plan["active"]) for plan in romanian], [("Echilibrat", False), ("Performanță ridicată", True)])
        self.assertEqual(power.parse_power_plans("garbage"), [])


class WindowsAdapterTests(unittest.TestCase):
    def test_commands_for_plans_and_sign_out(self):
        calls = []

        def runner(arguments):
            calls.append(arguments)
            return SimpleNamespace(returncode=0, stdout=PLANS_EN)
        adapter = power.WindowsPower(runner=runner)
        self.assertEqual(len(adapter.plans()), 3)
        adapter.set_plan("8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")
        adapter.sign_out()
        self.assertEqual(calls, [["powercfg", "/list"], ["powercfg", "/setactive", "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"],
                                 ["shutdown", "/l"]])
        with self.assertRaises(ValueError):
            adapter.set_plan("x; format c:")

    def test_native_calls_refuse_to_run_off_windows(self):
        adapter = power.WindowsPower()
        with patch.object(power.os, "name", "posix"):
            for call in (lambda: adapter.suspend(), lambda: adapter.suspend(True), adapter.display_off,
                         lambda: adapter.set_execution_state(power.ES_CONTINUOUS), adapter.sign_out, adapter.plans):
                with self.assertRaises(power.PowerUnavailable):
                    call()
            self.assertEqual(adapter.capabilities(), {"hibernate": False, "displayOff": False})

    def test_execute_dispatches_each_action(self):
        adapter = power.WindowsPower(runner=lambda arguments: SimpleNamespace(returncode=0))
        with patch.object(adapter, "countdown") as countdown, patch.object(adapter, "suspend") as suspend, \
             patch.object(adapter, "sign_out") as sign_out, patch.object(adapter, "display_off") as display_off:
            adapter.execute("restart", "c", 12)
            adapter.execute("sleep", "c")
            adapter.execute("hibernate", "c")
            adapter.execute("signout", "c")
            adapter.execute("displayOff", "c")
        countdown.assert_called_once_with("restart", 12, "c")
        self.assertEqual([call.args for call in suspend.call_args_list], [(False,), (True,)])
        sign_out.assert_called_once()
        display_off.assert_called_once()
        with self.assertRaises(ValueError):
            adapter.execute("explode", "c")


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "power.json"
        self.clock = Clock()
        self.backend = FakeBackend(self.path)
        self.notes = []
        self.records = []
        self.game = None
        self.scheduler = self.make()

    def make(self):
        return power.PowerScheduler(self.backend, self.path, clock=self.clock,
                                    notify=lambda title, message: self.notes.append(message),
                                    game=lambda: self.game,
                                    record=lambda action, summary, by, result="ok": self.records.append((action, summary, result)))

    def tearDown(self):
        self.scheduler.close()
        self.folder.cleanup()

    def advance(self, seconds):
        self.clock.now += seconds
        self.scheduler.tick()

    def test_validation(self):
        for arguments in (("explode", 60, None), ("sleep", None, None), ("sleep", 60, "gameExits"), ("sleep", 1, None),
                          ("sleep", 10 ** 9, None), ("sleep", True, None), ("sleep", 60.5, None), ("sleep", None, "tomorrow")):
            with self.assertRaises(ValueError, msg=arguments):
                self.scheduler.set_timer(*arguments)
        with self.assertRaises(LookupError):
            self.scheduler.set_timer("sleep", when="gameExits")

    def test_sleep_timer_warns_a_minute_before_and_is_forgotten_before_it_fires(self):
        timer, summary = self.scheduler.set_timer("sleep", 600, requested_by="iPhone")
        self.assertEqual(summary, "Set the PC to go to sleep in 10 minutes")
        self.assertEqual((timer["action"], timer["when"], timer["state"], timer["remainingSeconds"], timer["requestedBy"]),
                         ("sleep", "time", "scheduled", 600, "iPhone"))
        self.assertEqual(set(timer), {"id", "action", "when", "state", "firesAt", "remainingSeconds", "createdAt", "requestedBy", "game"})
        self.assertIn("go to sleep in 10 minutes", self.notes[-1])
        self.advance(530)
        self.assertEqual(len(self.notes), 1)
        self.advance(15)  # 55 s left: the one-minute warning
        self.assertIn("will go to sleep in 55 seconds", self.notes[-1])
        self.advance(54)
        self.assertEqual(self.backend.executed, [])
        self.advance(1)
        self.assertEqual(self.backend.executed[0][0], "sleep")
        self.assertIsNone(self.backend.on_disk_when_executed[0])  # gone from disk before acting
        self.assertIsNone(self.scheduler.public_timer())
        self.assertEqual(self.records[-1][:2], ("power.timer.fired", "Sleep timer fired"))

    def test_shutdown_timer_starts_the_windows_countdown_thirty_seconds_early(self):
        self.scheduler.set_timer("shutdown", 300, requested_by="iPhone")
        self.advance(269)
        self.assertEqual(self.backend.executed, [])
        self.advance(1)
        action, seconds, comment = self.backend.executed[0]
        self.assertEqual((action, seconds), ("shutdown", 30))
        self.assertIn("requested from iPhone", comment)
        self.assertEqual(self.scheduler.public_timer()["state"], "countdown")
        self.assertEqual(self.backend.on_disk_when_executed[0]["state"], "countdown")  # a reload never re-fires it
        self.scheduler.cancel_timer()
        self.assertEqual(self.backend.aborts, 1)

    def test_countdown_state_clears_after_the_deadline(self):
        self.scheduler.set_timer("restart", 40)
        self.advance(10)
        self.assertEqual(self.backend.executed[0][:2], ("restart", 30))
        self.advance(41)
        self.assertIsNone(self.scheduler.public_timer())

    def test_when_the_game_exits(self):
        self.game = "Cyberpunk 2077"
        timer, summary = self.scheduler.set_timer("sleep", when="gameExits", requested_by="iPhone")
        self.assertEqual((timer["state"], timer["game"], timer["firesAt"]), ("waitingForGame", "Cyberpunk 2077", None))
        self.assertEqual(summary, "Set the PC to go to sleep when Cyberpunk 2077 exits")
        self.advance(3600)
        self.assertEqual(self.scheduler.public_timer()["state"], "waitingForGame")
        self.game = None
        self.advance(30)  # a launcher restart or a loading screen is not an exit
        self.assertEqual(self.scheduler.public_timer()["state"], "waitingForGame")
        self.advance(31)
        self.assertEqual(self.scheduler.public_timer()["state"], "scheduled")
        self.assertIn("Cyberpunk 2077 closed", self.notes[-1])
        self.advance(60)
        self.assertEqual(self.backend.executed[0][0], "sleep")

    def test_timers_survive_a_restart_but_never_fire_late(self):
        self.scheduler.set_timer("hibernate", 3600, requested_by="iPhone")
        self.scheduler.close()
        self.clock.now += 600
        restored = self.make()
        restored.load()
        self.assertEqual(restored.public_timer()["remainingSeconds"], 3000)
        restored.close()
        self.clock.now += 3000 + power.LATE_GRACE_SECONDS + 1  # the PC was off past the deadline
        late = self.make()
        late.load()
        self.assertIsNone(late.public_timer())
        self.assertEqual(self.records[-1][0], "power.timer.dropped")
        self.assertIsNone(json.loads(self.path.read_text())["timer"])
        late.close()

    def test_a_slightly_late_timer_fires_after_a_warning(self):
        self.scheduler.set_timer("sleep", 60)
        self.scheduler.close()
        self.clock.now += 90  # restarted 30 s after the deadline
        restored = self.make()
        restored.load()
        self.assertEqual(restored.public_timer()["remainingSeconds"], power.WARNING_SECONDS)
        restored.close()

    def test_game_timer_is_dropped_when_the_game_is_gone_after_a_restart(self):
        self.game = "Doom"
        self.scheduler.set_timer("shutdown", when="gameExits")
        self.scheduler.close()
        self.game = None
        restored = self.make()
        restored.load()
        self.assertIsNone(restored.public_timer())
        self.assertIn("no longer running", self.records[-1][1])
        restored.close()

    def test_failed_action_is_recorded_and_cleared(self):
        self.backend.fail = "Windows did not enter sleep."
        self.scheduler.set_timer("sleep", 10)
        self.advance(10)
        self.assertIsNone(self.scheduler.public_timer())
        self.assertEqual(self.records[-1][2], "error")

    def test_a_new_timer_replaces_a_running_countdown(self):
        self.scheduler.set_timer("shutdown", 30)
        self.advance(0)
        self.assertEqual(self.scheduler.public_timer()["state"], "countdown")
        self.scheduler.set_timer("sleep", 600)
        self.assertEqual(self.backend.aborts, 1)

    def wait_for_states(self, count):
        deadline = time.monotonic() + 2
        while len(self.backend.states) < count and time.monotonic() < deadline:
            time.sleep(0.01)

    def test_keep_awake_holds_the_execution_state_and_expires(self):
        result = self.scheduler.set_keep_awake(30, display=True, requested_by="iPhone")
        self.assertEqual((result["display"], result["remainingSeconds"], result["requestedBy"]), (True, 1800, "iPhone"))
        self.wait_for_states(1)
        self.assertEqual(self.backend.states[0], power.ES_CONTINUOUS | power.ES_SYSTEM_REQUIRED | power.ES_DISPLAY_REQUIRED)
        self.advance(1800)
        self.wait_for_states(2)
        self.assertEqual(self.backend.states[-1], power.ES_CONTINUOUS)
        self.assertIsNone(self.scheduler.public_keep_awake())
        for bad in (0, 10 ** 7, True, 1.5):
            with self.assertRaises(ValueError):
                self.scheduler.set_keep_awake(bad)

    def test_keep_awake_until_stopped_survives_a_restart(self):
        self.scheduler.set_keep_awake(None)
        self.scheduler.close()
        restored = self.make()
        restored.load()
        self.assertIsNone(restored.public_keep_awake()["until"])
        self.assertTrue(restored.stop_keep_awake())
        self.assertFalse(restored.stop_keep_awake())
        restored.close()


class PowerAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.clock = Clock()
        self.backend = FakeBackend()
        self.backend.plans = lambda: power.parse_power_plans(PLANS_EN)
        self.backend.plan_set = []
        self.backend.set_plan = self.backend.plan_set.append
        self.backend.capabilities = lambda: {"hibernate": False, "displayOff": True}
        self.scheduler = power.PowerScheduler(self.backend, root / "power.json", clock=self.clock)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        _, token = self.registry.register("Orbit on iPhone", "iOS")
        _, reader = self.registry.register("Orbit on iPad", "iPadOS", scopes=["read"])
        self.auth, self.reader = {"Authorization": f"Bearer {token}"}, {"Authorization": f"Bearer {reader}"}
        self.patches = [patch.object(agent, "POWER", self.backend), patch.object(agent, "POWER_SCHEDULER", self.scheduler),
                        patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "ACTIVITY", self.log),
                        patch.object(agent, "require_windows")]
        for item in self.patches:
            item.start()
        self.https = TestClient(agent.app, base_url="https://testserver")
        self.http = TestClient(agent.app)

    def tearDown(self):
        self.https.close()
        self.http.close()
        for item in reversed(self.patches):
            item.stop()
        self.scheduler.close()
        self.log.close()
        self.folder.cleanup()

    def test_power_state_shape(self):
        self.assertEqual(self.http.get("/api/power", headers=self.reader).status_code, 426)
        body = self.https.get("/api/power", headers=self.reader).json()
        self.assertEqual(body, {"timer": None, "keepAwake": None, "plans": power.parse_power_plans(PLANS_EN),
                                "supports": {"hibernate": False, "displayOff": True}})

    def test_timer_lifecycle(self):
        self.assertEqual(self.https.post("/api/power/timer", headers=self.reader, json={"action": "sleep", "inSeconds": 60}).json()["scope"],
                         "control")
        created = self.https.post("/api/power/timer", headers=self.auth, json={"action": "sleep", "inSeconds": 1800})
        self.assertEqual(created.status_code, 200)
        self.assertEqual((created.json()["action"], created.json()["remainingSeconds"], created.json()["requestedBy"]),
                         ("sleep", 1800, "iPhone"))
        self.assertEqual(self.https.get("/api/power", headers=self.reader).json()["timer"]["id"], created.json()["id"])
        for body, status in (({"action": "hibernate", "inSeconds": 60}, 409), ({"action": "sleep", "when": "gameExits"}, 409),
                             ({"action": "sleep"}, 422), ({"action": "sleep", "inSeconds": "60"}, 422),
                             ({"action": "sleep", "inSeconds": 60, "force": True}, 422), ({"action": "nuke", "inSeconds": 60}, 422)):
            self.assertEqual(self.https.post("/api/power/timer", headers=self.auth, json=body).status_code, status, body)
        self.assertEqual(self.https.delete("/api/power/timer", headers=self.auth).json(), {"status": "cancelled"})
        self.assertEqual(self.https.delete("/api/power/timer", headers=self.auth).status_code, 404)
        self.log.wait()
        summaries = [row["summary"] for row in self.log.entries(category="power")["entries"] if row["result"] == "ok"]
        self.assertEqual(summaries, ["Cancelled the sleep timer", "Set the PC to go to sleep in 30 minutes"])

    def test_cancel_endpoint_also_cancels_orbit_timers(self):
        self.scheduler.set_timer("restart", 3600)
        with patch.object(self.backend, "abort", side_effect=power.NothingToCancel("none")):
            self.assertEqual(self.http.post("/api/power/cancel", headers=self.auth).json(), {"status": "cancelled"})
            self.assertIsNone(self.scheduler.public_timer())
            self.assertEqual(self.http.post("/api/power/cancel", headers=self.auth).status_code, 409)

    def test_keep_awake_and_plans(self):
        result = self.https.put("/api/power/keep-awake", headers=self.auth, json={"minutes": 120})
        self.assertEqual((result.json()["remainingSeconds"], result.json()["display"]), (7200, False))
        self.assertEqual(self.https.put("/api/power/keep-awake", headers=self.auth, json={"minutes": 0}).status_code, 422)
        self.assertEqual(self.https.delete("/api/power/keep-awake", headers=self.auth).json(), {"status": "stopped"})
        self.assertEqual(self.https.delete("/api/power/keep-awake", headers=self.auth).status_code, 404)
        switched = self.https.put("/api/power/plan", headers=self.auth, json={"id": "8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C"})
        self.assertEqual(switched.status_code, 200)
        self.assertEqual(self.backend.plan_set, ["8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"])
        self.assertEqual(len(switched.json()["plans"]), 3)
        self.assertEqual(self.https.put("/api/power/plan", headers=self.auth, json={"id": "00000000-0000-0000-0000-000000000000"}).status_code, 404)
        self.assertEqual(self.https.put("/api/power/plan", headers=self.auth, json={"id": "balanced"}).status_code, 422)
        self.log.wait()
        summaries = [row["summary"] for row in self.log.entries(category="power")["entries"] if row["result"] == "ok"]
        self.assertEqual(summaries, ["Switched to the High performance power plan", "Let the PC sleep again",
                                     "Kept the PC awake for 120 minutes"])


if __name__ == "__main__":
    unittest.main()
