"""Windows' 30-second warning after Shut Down or Restart from the apps, and Cancel.

shutdown.exe never runs: every PowerCountdown here gets a fake runner, and the real runner is only
checked with os.name and subprocess.run patched.
"""
import subprocess
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_capabilities as capabilities
import orbit_power_countdown as countdown

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
WIDGET = "widget-only-token-with-more-than-24-characters"


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class FakeShutdown:
    """Records shutdown.exe calls and answers like Windows: one countdown at a time."""

    def __init__(self):
        self.calls = []
        self.pending = False
        self.next_codes = []

    def __call__(self, arguments):
        self.calls.append(list(arguments))
        if self.next_codes:
            return self.next_codes.pop(0)
        if arguments[1] == "/a":
            if not self.pending:
                return countdown.ERROR_NO_SHUTDOWN_IN_PROGRESS
            self.pending = False
            return 0
        if self.pending:
            return countdown.ERROR_SHUTDOWN_IS_SCHEDULED
        self.pending = True
        return 0


def start_arguments(action):
    return ["shutdown", "/s" if action == "shutdown" else "/r", "/t", "30", "/c", countdown.shutdown_comment(action)]


class PowerCountdownTests(unittest.TestCase):
    def setUp(self):
        self.windows = FakeShutdown()
        self.mono = Clock(500.0)
        self.wall = Clock(1_790_000_000.0)
        self.subject = countdown.PowerCountdown(runner=self.windows, monotonic=self.mono, clock=self.wall)

    def advance(self, seconds):
        self.mono.now += seconds
        self.wall.now += seconds

    def test_start_runs_windows_countdown_and_counts_it_down(self):
        self.assertIsNone(self.subject.snapshot())
        announced = []
        pending, started = self.subject.start("shutdown", before_start=lambda: announced.append(list(self.windows.calls)))
        self.assertTrue(started)
        self.assertEqual(announced, [[]])  # the hooks ran before shutdown.exe
        self.assertEqual(self.windows.calls, [start_arguments("shutdown")])
        self.assertEqual(pending, {"action": "shutdown", "remainingSeconds": 30, "endsAt": "2026-09-21T14:13:50Z"})
        self.advance(3.2)
        self.assertEqual(self.subject.snapshot()["remainingSeconds"], 27)
        self.assertEqual(self.subject.snapshot()["endsAt"], "2026-09-21T14:13:50Z")
        self.advance(26.8)
        self.assertIsNone(self.subject.snapshot())  # Windows is shutting down now

    def test_the_comment_names_the_action_and_how_to_cancel(self):
        self.assertEqual(countdown.shutdown_comment("shutdown"), "Orbit: shutdown requested from a paired device. Cancel it in Orbit.")
        self.assertEqual(countdown.shutdown_comment("restart"), "Orbit: restart requested from a paired device. Cancel it in Orbit.")
        self.assertLess(len(countdown.shutdown_comment("restart")), 512)

    def test_asking_again_keeps_the_running_countdown(self):
        self.subject.start("restart")
        self.advance(10)
        hooks = MagicMock()
        pending, started = self.subject.start("restart", before_start=hooks)
        self.assertFalse(started)
        hooks.assert_not_called()
        self.assertEqual(pending["remainingSeconds"], 20)
        self.assertEqual(self.windows.calls, [start_arguments("restart")])

    def test_the_other_action_replaces_the_countdown(self):
        self.subject.start("restart")
        self.advance(10)
        pending, started = self.subject.start("shutdown")
        self.assertTrue(started)
        self.assertEqual(pending["action"], "shutdown")
        self.assertEqual(pending["remainingSeconds"], 30)
        self.assertEqual(self.windows.calls, [start_arguments("restart"), ["shutdown", "/a"], start_arguments("shutdown")])

    def test_windows_refusals_leave_nothing_pending(self):
        for code, status in ((countdown.ERROR_SHUTDOWN_IS_SCHEDULED, 409), (countdown.ERROR_SHUTDOWN_IN_PROGRESS, 409), (5, 503)):
            with self.subTest(code=code):
                self.windows.next_codes = [code]
                with self.assertRaises(countdown.CountdownError) as refused:
                    self.subject.start("shutdown")
                self.assertEqual(refused.exception.status, status)
                self.assertIsNone(self.subject.snapshot())
        with self.assertRaises(ValueError):
            self.subject.start("sleep")

    def test_cancel_stops_windows_countdown_and_forgets_it(self):
        self.subject.start("shutdown")
        self.advance(4)
        self.assertEqual(self.subject.cancel(), "shutdown")
        self.assertEqual(self.windows.calls[-1], ["shutdown", "/a"])
        self.assertIsNone(self.subject.snapshot())
        with self.assertRaises(countdown.NothingToCancel) as nothing:
            self.subject.cancel()
        self.assertEqual(nothing.exception.status, 409)

    def test_cancel_also_stops_a_countdown_orbit_did_not_start(self):
        self.windows.pending = True  # shutdown /s /t 600 typed at the PC, or started before the agent restarted
        self.assertIsNone(self.subject.cancel())
        self.assertFalse(self.windows.pending)

    def test_cancel_when_someone_stopped_it_at_the_pc_forgets_it_too(self):
        self.subject.start("restart")
        self.windows.pending = False  # shutdown /a at the PC
        with self.assertRaises(countdown.NothingToCancel):
            self.subject.cancel()
        self.assertIsNone(self.subject.snapshot())

    def test_cancel_failures_keep_the_countdown(self):
        self.subject.start("shutdown")
        self.windows.next_codes = [countdown.ERROR_SHUTDOWN_IN_PROGRESS]
        with self.assertRaises(countdown.CountdownError) as late:
            self.subject.cancel()
        self.assertEqual(late.exception.status, 503)  # only "nothing to cancel" is 409
        self.assertIn("too late", str(late.exception))
        self.windows.next_codes = [5]
        with self.assertRaises(countdown.CountdownError) as failed:
            self.subject.cancel()
        self.assertEqual(failed.exception.status, 503)
        self.assertEqual(self.subject.snapshot()["action"], "shutdown")

    def test_whole_seconds_round_up_without_reading_one_second_long(self):
        self.assertEqual(countdown.seconds_until(2048.0 + 30, 2048.0), 30)
        self.assertEqual(countdown.seconds_until(1030.0, 1000.4), 30)
        self.assertEqual(countdown.seconds_until(1000.0, 1000.0), 0)
        self.assertEqual(countdown.seconds_until(999.0, 1000.0), 0)

    def test_the_real_runner_refuses_away_from_windows(self):
        with patch.object(countdown.os, "name", "posix"), patch.object(countdown.subprocess, "run") as run:
            with self.assertRaises(countdown.CountdownError) as refused:
                countdown.run_shutdown_exe(["shutdown", "/a"])
        self.assertEqual(refused.exception.status, 501)
        run.assert_not_called()

    def test_the_real_runner_returns_the_exit_code_without_a_console(self):
        with patch.object(countdown.os, "name", "nt"), patch.object(countdown.subprocess, "run") as run:
            run.return_value = MagicMock(returncode=1116)
            self.assertEqual(countdown.run_shutdown_exe(["shutdown", "/a"]), 1116)
            run.assert_called_once_with(["shutdown", "/a"], capture_output=True, timeout=10, creationflags=countdown.CREATE_NO_WINDOW)
            for error in (OSError("missing"), subprocess.TimeoutExpired("shutdown", 10)):
                run.side_effect = error
                with self.assertRaises(countdown.CountdownError) as failed:
                    countdown.run_shutdown_exe(["shutdown", "/a"])
                self.assertEqual(failed.exception.status, 503)


class CountdownRouteTests(unittest.TestCase):
    def setUp(self):
        self.windows = FakeShutdown()
        self.order = []
        self.cancelled = MagicMock(side_effect=lambda: self.order.append("cancelled hook"))
        self.subject = countdown.PowerCountdown(runner=self.recording_runner)
        for patcher in (patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent, "WIDGET_TOKEN", WIDGET),
                        patch.object(agent, "require_windows"),
                        patch.object(agent, "POWER_COUNTDOWN", self.subject),
                        patch.object(agent, "BEFORE_POWER_HOOKS", [lambda: self.order.append("before hook")]),
                        patch.object(agent, "POWER_CANCELLED_HOOKS", [self.cancelled]),
                        patch.object(agent.subprocess, "run")):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = TestClient(agent.app)
        self.addCleanup(self.client.close)

    def recording_runner(self, arguments):
        self.order.append(" ".join(arguments[:2]))
        return self.windows(arguments)

    def test_shut_down_from_the_apps_starts_the_countdown_the_status_reports(self):
        response = self.client.post("/api/action/shutdown", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "sent", "executed": "shutdown", "countdownSeconds": 30})
        self.assertEqual(self.order, ["before hook", "shutdown /s"])
        self.assertEqual(self.windows.calls, [start_arguments("shutdown")])
        agent.subprocess.run.assert_not_called()  # not the automation's `/t 3`
        for path in ("/api/status", "/api/watch/summary"):
            with self.subTest(path=path):
                reported = self.client.get(path, headers=AUTH).json()["powerCountdown"]
                self.assertEqual(reported["action"], "shutdown")
                self.assertIn(reported["remainingSeconds"], (29, 30))
                self.assertTrue(reported["endsAt"].endswith("Z"))

    def test_cancel_stops_it_and_re_arms_the_push_alarm(self):
        self.client.post("/api/action/restart", headers=AUTH)
        response = self.client.post("/api/power/cancel", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "cancelled", "action": "restart"})
        self.assertEqual(self.order, ["before hook", "shutdown /r", "shutdown /a", "cancelled hook"])
        for path in ("/api/status", "/api/watch/summary"):
            self.assertIsNone(self.client.get(path, headers=AUTH).json()["powerCountdown"])
        again = self.client.post("/api/power/cancel", headers=AUTH)
        self.assertEqual(again.status_code, 409)
        self.assertEqual(again.json()["detail"], "No shutdown or restart is waiting on the PC.")
        self.cancelled.assert_called_once_with()

    def test_asking_twice_keeps_the_countdown_and_the_other_action_replaces_it(self):
        self.client.post("/api/action/shutdown", headers=AUTH)
        self.assertEqual(self.client.post("/api/action/shutdown", headers=AUTH).json()["executed"], "shutdown")
        self.assertEqual(self.order, ["before hook", "shutdown /s"])
        replaced = self.client.post("/api/action/restart", headers=AUTH).json()
        self.assertEqual(replaced, {"status": "sent", "executed": "restart", "countdownSeconds": 30})
        self.assertEqual(self.order, ["before hook", "shutdown /s", "shutdown /a", "before hook", "shutdown /r"])
        self.assertEqual(self.client.get("/api/status", headers=AUTH).json()["powerCountdown"]["action"], "restart")

    def test_a_refused_countdown_re_arms_the_alarm_it_announced(self):
        self.windows.next_codes = [5]
        failed = self.client.post("/api/action/shutdown", headers=AUTH)
        self.assertEqual(failed.status_code, 503)
        self.assertEqual(self.order, ["before hook", "shutdown /s", "cancelled hook"])
        self.windows.next_codes = [countdown.ERROR_SHUTDOWN_IS_SCHEDULED]
        busy = self.client.post("/api/action/shutdown", headers=AUTH)
        self.assertEqual(busy.status_code, 409)
        self.assertIn("already counting down", busy.json()["detail"])
        self.assertIsNone(self.client.get("/api/status", headers=AUTH).json()["powerCountdown"])

    def test_sleep_and_automation_stay_immediate(self):
        windll = MagicMock()
        with patch.object(agent.ctypes, "windll", windll, create=True):
            self.assertEqual(self.client.post("/api/action/sleep", headers=AUTH).json(), {"status": "sent", "executed": "sleep"})
            self.assertEqual(agent.perform_action("shutdown"), {"status": "sent", "executed": "shutdown"})
        windll.powrprof.SetSuspendState.assert_called_once_with(0, 0, 0)
        agent.subprocess.run.assert_called_once()
        self.assertEqual(agent.subprocess.run.call_args.args[0], ["shutdown", "/s", "/t", "3"])
        self.assertEqual(self.windows.calls, [])
        self.assertIsNone(self.subject.snapshot())

    def test_both_routes_need_the_main_token_but_not_https(self):
        for headers in ({}, {"Authorization": f"Bearer {WIDGET}"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.client.post("/api/action/shutdown", headers=headers).status_code, 401)
                self.assertEqual(self.client.post("/api/power/cancel", headers=headers).status_code, 401)
        self.assertEqual(self.windows.calls, [])
        # TestClient speaks plain HTTP: Cancel works wherever Shut Down does.
        self.client.post("/api/action/shutdown", headers=AUTH)
        self.assertEqual(self.client.post("/api/power/cancel", headers=AUTH).status_code, 200)

    def test_off_windows_cancel_is_501_before_shutdown_exe(self):
        with patch.object(agent, "require_windows", side_effect=agent.HTTPException(501, "PC controls require Windows")):
            self.assertEqual(self.client.post("/api/power/cancel", headers=AUTH).status_code, 501)
            self.assertEqual(self.client.post("/api/action/restart", headers=AUTH).status_code, 501)
        self.assertEqual(self.windows.calls, [])
        self.assertEqual(self.order, [])

    def test_the_feature_is_listed(self):
        self.assertIn("powerCountdown", capabilities.KNOWN_FEATURES)
        features = self.client.get("/api/capabilities", headers=AUTH).json()["features"]
        self.assertIn("powerCountdown", features)


if __name__ == "__main__":
    unittest.main()
