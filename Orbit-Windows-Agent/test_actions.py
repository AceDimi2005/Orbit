"""perform_action keeps every PC action exactly as execute_action ran it, plus the power hooks.

Every Windows call is mocked: nothing locks, sleeps or shuts down the machine running the tests.
"""
import ast
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import MagicMock, call, patch

from fastapi import HTTPException
from fastapi.testclient import TestClient

import orbit_agent as agent

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
NO_WINDOW = 0x08000000


def chord(*vks):
    """keybd_event calls for pressing vks in order and releasing them in reverse (tap_key style)."""
    return [call(vk, 0, 0, 0) for vk in vks] + [call(vk, 0, 2, 0) for vk in reversed(vks)]


# What the pre-refactor execute_action sent for each key action (keybd_event, legacy virtual keys).
KEY_ACTIONS = {
    "mute": chord(0xAD), "volume_up": chord(0xAF), "volume_down": chord(0xAE),
    "media_play_pause": chord(0xB3), "media_next": chord(0xB0), "media_prev": chord(0xB1),
    "fullscreen": chord(0x7A), "toggle_hdr": chord(0x5B, 0x12, 0x42), "show_desktop": chord(0x5B, 0x44),
    "task_view": chord(0x5B, 0x09), "alt_tab": chord(0x12, 0x09), "screenshot": chord(0x5B, 0x2C),
}
ALL_ACTIONS = {"lock", "sleep", "restart", "shutdown", "mute", "volume_up", "volume_down", "media_play_pause",
               "media_next", "media_prev", "toggle_hdr", "restore_display", "kill_game", "show_desktop",
               "task_view", "alt_tab", "screenshot", "fullscreen"}


class PerformActionTests(unittest.TestCase):
    def setUp(self):
        self.windll = MagicMock()
        for patcher in (patch.object(agent, "require_windows"),
                        patch.object(agent.ctypes, "windll", self.windll, create=True),
                        patch.object(agent.subprocess, "run"), patch.object(agent.subprocess, "Popen"),
                        patch.object(agent, "BEFORE_POWER_HOOKS", [])):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.user32 = self.windll.user32
        token = patch.object(agent, "API_TOKEN", TOKEN)
        token.start()
        self.addCleanup(token.stop)
        self.client = TestClient(agent.app)
        self.addCleanup(self.client.close)

    def test_action_names_are_unchanged(self):
        self.assertEqual(set(agent.ACTIONS), ALL_ACTIONS)
        self.assertEqual(set(agent.POWER_ACTIONS), {"sleep", "restart", "shutdown"})

    def test_key_actions_send_the_same_keys_through_function_and_route(self):
        for name, expected in KEY_ACTIONS.items():
            for via in ("function", "route"):
                with self.subTest(action=name, via=via):
                    self.user32.reset_mock()
                    if via == "function":
                        result = agent.perform_action(name)
                    else:
                        response = self.client.post(f"/api/action/{name}", headers=AUTH)
                        self.assertEqual(response.status_code, 200)
                        result = response.json()
                    self.assertEqual(result, {"status": "sent", "executed": name})
                    self.assertEqual(self.user32.keybd_event.call_args_list, expected)

    def test_lock(self):
        self.assertEqual(agent.perform_action("lock"), {"status": "sent", "executed": "lock"})
        self.user32.LockWorkStation.assert_called_once_with()
        self.user32.LockWorkStation.return_value = 0
        with self.assertRaises(HTTPException) as failed:
            agent.perform_action("lock")
        self.assertEqual(failed.exception.status_code, 503)

    def test_sleep_uses_set_suspend_state_without_forcing(self):
        self.assertEqual(agent.perform_action("sleep")["executed"], "sleep")
        self.windll.powrprof.SetSuspendState.assert_called_once_with(0, 0, 0)
        self.windll.powrprof.SetSuspendState.return_value = 0
        self.assertEqual(self.client.post("/api/action/sleep", headers=AUTH).status_code, 503)

    def test_automation_restart_and_shutdown_use_shutdown_exe_with_a_short_delay(self):
        # Power after downloads and deck buttons call perform_action directly; the apps' route
        # starts Windows' 30-second countdown instead (test_power_countdown).
        for name, switch in (("restart", "/r"), ("shutdown", "/s")):
            with self.subTest(action=name):
                agent.subprocess.run.reset_mock()
                self.assertEqual(agent.perform_action(name), {"status": "sent", "executed": name})
                agent.subprocess.run.assert_called_once_with(["shutdown", switch, "/t", "3"], check=True, timeout=5,
                                                             capture_output=True, creationflags=NO_WINDOW)
        for error in (OSError("missing"), subprocess.CalledProcessError(1, "shutdown"), subprocess.TimeoutExpired("shutdown", 5)):
            with self.subTest(error=type(error).__name__):
                agent.subprocess.run.side_effect = error
                with self.assertRaises(HTTPException) as failed:
                    agent.perform_action("shutdown")
                self.assertEqual(failed.exception.status_code, 503)
        self.assertIsNone(agent.POWER_COUNTDOWN.snapshot())

    def test_restore_display(self):
        agent.perform_action("restore_display")
        agent.subprocess.Popen.assert_called_once_with(["DisplaySwitch.exe", "/extend"], creationflags=NO_WINDOW)

    def test_kill_game_closes_only_the_verified_foreground_game(self):
        self.user32.GetForegroundWindow.return_value = 0xBEEF

        def owner(pid):
            def fill(handle, reference):
                reference._obj.value = pid
            return fill
        self.user32.GetWindowThreadProcessId.side_effect = owner(42)
        with patch.object(agent, "detect_game", return_value={"name": "Example", "pid": 42, "foreground": True}):
            self.assertEqual(agent.perform_action("kill_game"), {"status": "sent", "executed": "kill_game"})
            self.user32.PostMessageW.assert_called_once_with(0xBEEF, 0x0010, 0, 0)
            self.user32.PostMessageW.return_value = 0
            self.assertEqual(self.client.post("/api/action/kill_game", headers=AUTH).status_code, 503)
            self.user32.PostMessageW.return_value = 1
            self.user32.GetWindowThreadProcessId.side_effect = owner(7)
            with self.assertRaises(HTTPException) as changed:
                agent.perform_action("kill_game")
            self.assertEqual(changed.exception.status_code, 409)
        for game in (None, {"name": "Example", "pid": 42, "foreground": False}):
            with self.subTest(game=game), patch.object(agent, "detect_game", return_value=game):
                self.user32.PostMessageW.reset_mock()
                with self.assertRaises(HTTPException) as refused:
                    agent.perform_action("kill_game")
                self.assertEqual(refused.exception.status_code, 409)
                self.user32.PostMessageW.assert_not_called()

    def test_unknown_action_is_404_from_both_entry_points_even_off_windows(self):
        with patch.object(agent, "require_windows", side_effect=AssertionError("checked after the name")):
            for name in ("not-an-action", "Sleep", "", "lock ", "shutdown_now"):
                with self.subTest(name=name), self.assertRaises(HTTPException) as unknown:
                    agent.perform_action(name)
                self.assertEqual(unknown.exception.status_code, 404)
            self.assertEqual(self.client.post("/api/action/not-an-action", headers=AUTH).status_code, 404)
        self.user32.assert_not_called()

    def test_known_action_off_windows_is_501(self):
        with patch.object(agent, "require_windows", side_effect=HTTPException(501, "PC controls require Windows")):
            self.assertEqual(self.client.post("/api/action/mute", headers=AUTH).status_code, 501)
        self.user32.keybd_event.assert_not_called()

    def test_keyboard_actions_wait_for_a_held_shortcut_and_power_actions_do_not(self):
        self.assertEqual(agent.KEYBOARD_ACTIONS, set(KEY_ACTIONS))
        finished = []
        with agent.orbit_input.INPUT_LOCK:
            worker = threading.Thread(target=lambda: finished.append(agent.perform_action("show_desktop")))
            worker.start()
            worker.join(0.2)
            self.assertEqual(finished, [])  # blocked while the "shortcut" holds the input lock
            self.assertEqual(self.user32.keybd_event.call_args_list, [])
            power = threading.Thread(target=lambda: finished.append(agent.perform_action("lock")))
            power.start()
            power.join(5)
            self.assertEqual(finished, [{"status": "sent", "executed": "lock"}])
        worker.join(5)
        self.assertEqual(self.user32.keybd_event.call_args_list, KEY_ACTIONS["show_desktop"])
        # The lock is released after failures too.
        self.user32.keybd_event.side_effect = OSError("blocked")
        with self.assertRaises(HTTPException):
            agent.perform_action("mute")
        self.assertTrue(agent.orbit_input.INPUT_LOCK.acquire(timeout=1))
        agent.orbit_input.INPUT_LOCK.release()

    def test_route_still_requires_the_main_token(self):
        with patch.object(agent, "WIDGET_TOKEN", "widget-only-token-with-more-than-24-characters"):
            for headers in ({}, {"Authorization": "Bearer widget-only-token-with-more-than-24-characters"}):
                self.assertEqual(self.client.post("/api/action/shutdown", headers=headers).status_code, 401)
        agent.subprocess.run.assert_not_called()


class BeforePowerHookTests(unittest.TestCase):
    def setUp(self):
        self.order = []
        self.windll = MagicMock()
        self.windll.powrprof.SetSuspendState.side_effect = lambda *args: self.order.append("suspend") or 1
        run = MagicMock(side_effect=lambda *args, **kwargs: self.order.append("shutdown.exe"))
        self.hooks = []
        for patcher in (patch.object(agent, "require_windows"),
                        patch.object(agent.ctypes, "windll", self.windll, create=True),
                        patch.object(agent.subprocess, "run", run), patch.object(agent.subprocess, "Popen"),
                        patch.object(agent, "BEFORE_POWER_HOOKS", self.hooks)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_hooks_run_once_in_order_before_each_power_action_and_never_otherwise(self):
        self.hooks.append(lambda: self.order.append("first"))
        self.hooks.append(lambda: self.order.append("second"))
        agent.perform_action("sleep")
        self.assertEqual(self.order, ["first", "second", "suspend"])
        for name in ("restart", "shutdown"):
            self.order.clear()
            agent.perform_action(name)
            self.assertEqual(self.order, ["first", "second", "shutdown.exe"])
        self.order.clear()
        for name in sorted(agent.ACTIONS - agent.POWER_ACTIONS - {"kill_game"}):
            agent.perform_action(name)
        self.assertEqual(self.order, [])

    def test_a_failing_hook_is_logged_and_the_rest_still_run(self):
        def broken():
            raise RuntimeError("relay down")
        self.hooks.extend([broken, lambda: self.order.append("after")])
        with self.assertLogs("orbit", "ERROR"):
            agent.perform_action("sleep")
        self.assertEqual(self.order, ["after", "suspend"])

    def test_a_hung_hook_cannot_stop_the_power_action(self):
        release = threading.Event()
        self.addCleanup(release.set)
        self.hooks.append(lambda: release.wait(10))
        with patch.object(agent, "BEFORE_POWER_HOOKS_TIMEOUT", 0.05), self.assertLogs("orbit", "WARNING"):
            agent.perform_action("shutdown")
        self.assertEqual(self.order, ["shutdown.exe"])

    def test_hooks_do_not_run_for_unknown_names_or_off_windows(self):
        self.hooks.append(lambda: self.order.append("hook"))
        with self.assertRaises(HTTPException):
            agent.perform_action("hibernate")
        with patch.object(agent, "require_windows", side_effect=HTTPException(501, "PC controls require Windows")):
            with self.assertRaises(HTTPException):
                agent.perform_action("sleep")
        self.assertEqual(self.order, [])


class ScriptModuleAliasTests(unittest.TestCase):
    def test_running_as_a_script_registers_the_module_as_orbit_agent_before_feature_imports(self):
        source = (Path(__file__).resolve().parent / "orbit_agent.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        alias_line = None
        for node in tree.body:
            if isinstance(node, ast.If) and "__main__" in ast.unparse(node.test):
                if 'sys.modules.setdefault("orbit_agent", sys.modules[__name__])' in ast.unparse(node).replace("'", '"'):
                    alias_line = node.lineno
                    break
        self.assertIsNotNone(alias_line)
        feature_imports = [node.lineno for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom))
                           and any(alias.name.startswith("orbit_") for alias in node.names)
                           or (isinstance(node, ast.ImportFrom) and (node.module or "").startswith("orbit_"))]
        self.assertTrue(feature_imports)
        self.assertLess(alias_line, min(feature_imports))


if __name__ == "__main__":
    unittest.main()
