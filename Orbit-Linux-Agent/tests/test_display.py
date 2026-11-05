"""Display transactions against fakes; never change the signed-in desktop."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Orbit-Linux-Agent"), str(ROOT / "Orbit-Windows-Agent")]
from orbit_linux_display import HyprlandDisplays, LinuxStreamDisplayService, SECTION, mode
from orbit_settings import SettingsStore
from orbit_stream_display import DisplaySetupError, SunshineActivity


def monitor(name, **kwargs):
    return {"name": name, "width": 1920, "height": 1080, "refreshRate": 60, "scale": 1,
            "transform": 0, "x": 0, "y": 0, "disabled": False, "dpmsStatus": True, **kwargs}


class Displays:
    supported = True
    session = "fake-session"
    command = "fake-hyprctl"
    environment = {"HYPRLAND_INSTANCE_SIGNATURE": session, "XDG_RUNTIME_DIR": "/fake runtime"}

    def __init__(self):
        self.rows = [monitor("DP-1"), monitor("DP-2", x=1920, dpmsStatus=False)]
        self.destroyed = []
        self.powered = []
        self.fail_configure = False

    def require(self):
        if not self.supported:
            raise DisplaySetupError(501, "Unsupported compositor")

    def monitors(self):
        return copy.deepcopy(self.rows)

    def find(self, name):
        return next((row for row in self.rows if row["name"] == name), None)

    def create(self, name):
        self.rows.append(monitor(name))

    def configure(self, name, requested, position):
        if self.fail_configure:
            self.fail_configure = False
            raise DisplaySetupError(503, "Mode refused")
        x, y = HyprlandDisplays.placement(self.rows, name, requested["width"], position)
        self.find(name).update(**requested, x=x, y=y)

    def destroy(self, name):
        self.destroyed.append(name)
        self.rows = [row for row in self.rows if row["name"] != name]

    def power(self, name, enabled):
        self.powered.append((name, enabled))
        self.find(name)["dpmsStatus"] = enabled

    def focus(self, name):
        for row in self.rows:
            row["focused"] = row["name"] == name


class Sunshine:
    def __init__(self):
        self.settings = {"output_name": "DP-1", "capture": "kms", "bitrate": "20000",
                         "global_prep_cmd": '[{"do":"existing action","undo":"existing undo"}]'}
        self.restarts = 0
        self.fail_save = False

    def login_saved(self):
        return True

    def config(self):
        return copy.deepcopy(self.settings), "2026.1000"

    def save_config(self, settings):
        self.settings = copy.deepcopy(settings)
        if self.fail_save:
            self.fail_save = False
            raise DisplaySetupError(502, "Write timed out after reaching Sunshine")

    def restart(self):
        self.restarts += 1


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = SettingsStore(Path(self.temp.name) / "settings.json")
        self.displays = Displays()
        self.sunshine = Sunshine()
        self.before = copy.deepcopy(self.sunshine.settings)
        self.activity = SunshineActivity()
        self.service = LinuxStreamDisplayService(self.sunshine, self.displays, lambda: self.store,
                                                 activity=lambda: self.activity, hook_launcher=["/path with spaces/orbit"])

    def test_second_screen_creates_sizes_targets_and_restores(self):
        result = self.service.set_second_screen(True, 2560, 1440, 120, "left")
        state = self.service.state()
        name = state["output"]
        self.assertEqual(result["placement"], "done")
        self.assertEqual(self.displays.find(name)["x"], -2560)
        self.assertEqual(self.sunshine.settings["output_name"], name)
        self.assertEqual(self.sunshine.settings["capture"], "wlr")
        self.assertTrue(self.service.status()["secondScreen"]["active"])
        self.service.set_second_screen(False)
        self.assertIsNone(self.displays.find(name))
        self.assertEqual(self.service.state(), {})
        self.assertEqual(self.sunshine.settings["output_name"], self.before["output_name"])
        self.assertEqual(self.sunshine.settings["capture"], self.before["capture"])
        self.assertEqual(json.loads(self.sunshine.settings["global_prep_cmd"]), json.loads(self.before["global_prep_cmd"]))

    def test_fill_prepares_requested_mode_before_stream(self):
        self.service.ensure_mode(2556, 1178, 60)
        self.service.set_fill(True)
        status = self.service.status()
        self.assertEqual(status["virtualDisplay"]["modes"], ["2556x1178@60"])
        self.assertTrue(status["fillReady"])
        self.assertFalse(status["hdrSupported"])
        self.assertEqual(status["backend"], "hyprland")

    def test_status_does_not_claim_readiness_after_external_changes(self):
        self.service.set_fill(True)
        self.sunshine.settings["capture"] = "kms"
        self.assertFalse(self.service.status()["fillReady"])
        self.sunshine.settings["capture"] = "wlr"
        self.displays.find(self.service.state()["output"])["width"] = 1280
        status = self.service.status()
        self.assertFalse(status["fillReady"])
        self.assertEqual(status["virtualDisplay"]["modes"], ["1280x1080@60"])

    def test_sunshine_user_edits_and_other_hooks_survive_restoration(self):
        self.service.set_fill(True)
        self.sunshine.settings.update(output_name="DP-2", capture="new capture", bitrate="45000")
        hooks = json.loads(self.sunshine.settings["global_prep_cmd"])
        hooks.append({"do": "new user hook"})
        self.sunshine.settings["global_prep_cmd"] = json.dumps(hooks)
        self.service.revert()
        self.assertEqual(self.sunshine.settings["output_name"], "DP-2")
        self.assertEqual(self.sunshine.settings["capture"], "new capture")
        self.assertEqual(self.sunshine.settings["bitrate"], "45000")
        self.assertEqual(len(json.loads(self.sunshine.settings["global_prep_cmd"])), 2)

    def test_failed_mode_creation_removes_only_new_output(self):
        self.displays.fail_configure = True
        with self.assertRaises(DisplaySetupError):
            self.service.ensure_mode(1280, 720, 60)
        self.assertEqual([row["name"] for row in self.displays.rows], ["DP-1", "DP-2"])
        self.assertEqual(self.service.state(), {})

    def test_failed_resize_restores_previous_mode(self):
        self.service.ensure_mode(1280, 720, 60)
        before = self.service.state()
        self.displays.fail_configure = True
        with self.assertRaises(DisplaySetupError):
            self.service.ensure_mode(1920, 1080, 120)
        self.assertEqual(self.service.state(), before)
        self.assertEqual(self.displays.find(before["output"])["width"], 1280)

    def test_ambiguous_sunshine_write_is_rolled_back(self):
        self.sunshine.fail_save = True
        with self.assertRaises(DisplaySetupError):
            self.service.set_fill(True)
        self.assertEqual(self.sunshine.settings["output_name"], "DP-1")
        self.assertEqual(self.sunshine.settings["capture"], "kms")
        self.assertEqual(self.service.state(), {})
        self.assertEqual(len(self.displays.rows), 2)

    def test_crash_journal_can_be_recovered_by_new_instance(self):
        self.service.set_fill(True)
        state = self.service.state()
        state["phase"] = "configuring"
        self.store.replace(SECTION, state)
        restarted = LinuxStreamDisplayService(self.sunshine, self.displays, lambda: self.store, activity=lambda: self.activity)
        restarted.revert()
        self.assertEqual(restarted.state(), {})
        self.assertEqual(self.sunshine.settings["output_name"], "DP-1")

    def test_new_compositor_session_never_deletes_old_named_output(self):
        self.service.set_fill(True)
        name = self.service.state()["output"]
        self.displays.session = "another-session"
        self.service.revert()
        self.assertIsNotNone(self.displays.find(name))
        self.assertFalse(self.displays.destroyed)
        self.assertEqual(self.sunshine.settings["output_name"], "DP-1")

    def test_busy_or_unknown_sunshine_blocks_changes(self):
        for streaming in (True, None):
            self.activity = SunshineActivity(streaming=streaming)
            with self.assertRaises(DisplaySetupError) as error:
                self.service.set_second_screen(True, 1280, 720)
            self.assertEqual(error.exception.status, 409)
            self.assertEqual(len(self.displays.rows), 2)
            self.assertEqual(self.service.state(), {})

    def test_stream_start_during_change_preserves_journal_without_restart(self):
        self.service.set_fill(True)
        before = self.sunshine.config()[0]
        restarts = self.sunshine.restarts
        with patch.object(self.service, "activity", side_effect=[SunshineActivity(), SunshineActivity(streaming=True), SunshineActivity(streaming=True)]):
            with self.assertRaises(DisplaySetupError):
                self.service.set_fill(True, only_display=True)
        self.assertEqual(self.sunshine.settings, before)
        self.assertEqual(self.sunshine.restarts, restarts)
        self.assertEqual(self.service.state()["phase"], "configuring")
        self.service.revert()

    def test_separate_service_instances_share_the_operation_lock(self):
        other = LinuxStreamDisplayService(self.sunshine, self.displays, lambda: self.store, activity=lambda: self.activity)
        with self.service.operation():
            with self.assertRaises(DisplaySetupError) as error:
                other.ensure_mode(1280, 720, 60)
        self.assertEqual(error.exception.status, 409)
        self.assertEqual(other.state(), {})

    def test_hooks_resize_and_restore_only_monitors_they_powered_off(self):
        self.service.set_fill(True, only_display=True)
        self.assertFalse(self.displays.powered)
        self.service.stream_hook(True, {"SUNSHINE_CLIENT_WIDTH": "1280", "SUNSHINE_CLIENT_HEIGHT": "720", "SUNSHINE_CLIENT_FPS": "60"})
        self.assertEqual(self.displays.powered, [("DP-1", False)])
        self.assertEqual(self.service.state()["darkened"], ["DP-1"])
        self.service.stream_hook(False)
        self.assertEqual(self.displays.powered[-1], ("DP-1", True))
        self.assertFalse(self.displays.find("DP-2")["dpmsStatus"])
        self.assertEqual(self.service.state()["darkened"], [])

    def test_emergency_restore_wakes_monitor_even_while_streaming(self):
        self.service.set_fill(True, only_display=True)
        self.service.stream_hook(True, {})
        self.activity = SunshineActivity(streaming=True)
        with self.assertRaises(DisplaySetupError):
            self.service.revert()
        self.assertTrue(self.displays.find("DP-1")["dpmsStatus"])
        self.assertNotEqual(self.service.state(), {})

    def test_second_screen_never_darkens_physical_monitors(self):
        self.service.set_fill(True, only_display=True)
        self.service.set_second_screen(True, 1280, 720)
        self.service.stream_hook(True, {})
        self.assertEqual(self.displays.powered, [])
        self.service.set_second_screen(False)
        self.assertTrue(self.service.state()["fill"]["enabled"])

    def test_fill_restores_focus_unless_the_user_already_moved_it(self):
        self.displays.focus("DP-1")
        self.service.set_fill(True)
        self.service.stream_hook(True, {})
        self.assertTrue(self.displays.find(self.service.state()["output"])["focused"])
        self.service.stream_hook(False)
        self.assertTrue(self.displays.find("DP-1")["focused"])
        self.service.stream_hook(True, {})
        self.displays.focus("DP-2")
        self.service.stream_hook(False)
        self.assertTrue(self.displays.find("DP-2")["focused"])

    def test_failed_wake_keeps_journal_for_retry(self):
        self.service.set_fill(True, only_display=True)
        self.service.stream_hook(True, {})
        with patch.object(self.displays, "power", side_effect=DisplaySetupError(503, "unavailable")):
            with self.assertRaises(DisplaySetupError):
                self.service.revert()
        self.assertEqual(self.service.state()["darkened"], ["DP-1"])
        self.service.revert()
        self.assertTrue(self.displays.find("DP-1")["dpmsStatus"])
        self.assertEqual(self.service.state(), {})

    def test_bad_client_dimensions_or_hdr_fail_before_display_changes(self):
        self.service.set_fill(True, only_display=True)
        before = self.displays.monitors()
        for env in ({"SUNSHINE_CLIENT_WIDTH": "1920; rm -rf /"}, {"SUNSHINE_CLIENT_HDR": "true"}):
            with self.assertRaises(DisplaySetupError):
                self.service.stream_hook(True, env)
            self.assertEqual(self.displays.rows, before)

    def test_hooks_quote_local_paths_and_keep_existing_commands(self):
        self.service.set_fill(True)
        entries = json.loads(self.sunshine.settings["global_prep_cmd"])
        self.assertEqual(entries[0]["do"], "existing action")
        import shlex
        command = shlex.split(entries[1]["do"])
        self.assertIn("/path with spaces/orbit", command)
        self.assertIn("XDG_RUNTIME_DIR=/fake runtime", command)
        self.assertEqual(command[-2:], ["--display-hook", "start"])

    def test_no_saved_state_restoration_is_noop(self):
        self.assertFalse(self.service.revert()["changed"])

    def test_invalid_journal_cannot_remove_arbitrary_display(self):
        self.store.replace(SECTION, {"output": "DP-1", "session": self.displays.session})
        with self.assertRaises(DisplaySetupError):
            self.service.revert()
        self.assertFalse(self.displays.destroyed)

    def test_output_name_collision_is_not_deleted(self):
        with patch.object(self.displays, "create", side_effect=DisplaySetupError(409, "name collision")):
            with self.assertRaises(DisplaySetupError):
                self.service.ensure_mode(1280, 720, 60)
        self.assertFalse(self.displays.destroyed)

    def test_shared_http_routes_enforce_auth_https_and_report_linux_changes(self):
        from fastapi import FastAPI, Header, HTTPException, Request
        from fastapi.testclient import TestClient
        from orbit_stream_display import create_stream_display_router

        def verify(authorization: str = Header(None)):
            if authorization != "Bearer control":
                raise HTTPException(401, "Control token required")

        def secure(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(426, "HTTPS required")

        app = FastAPI()
        app.include_router(create_stream_display_router(verify, secure, self.service))
        body = {"enabled": True, "width": 1280, "height": 720, "refreshRate": 60, "position": "left"}
        headers = {"Authorization": "Bearer control"}
        with TestClient(app, base_url="https://testserver") as client:
            self.assertEqual(client.post("/api/stream/display/second-screen", json=body).status_code, 401)
            self.assertEqual(client.post("/api/stream/display/second-screen", json=body, headers={"Authorization": "Bearer widget"}).status_code, 401)
            result = client.post("/api/stream/display/second-screen", json=body, headers=headers)
            self.assertEqual(result.status_code, 200, result.text)
            self.assertTrue(result.json()["display"]["secondScreen"]["active"])
            self.assertEqual(result.json()["display"]["backend"], "hyprland")
            self.assertEqual(client.post("/api/stream/display/revert", headers=headers).status_code, 200)
        with TestClient(app, base_url="http://testserver") as client:
            self.assertEqual(client.post("/api/stream/display/second-screen", json=body, headers=headers).status_code, 426)
        self.assertEqual(self.service.state(), {})


class HyprlandContractTests(unittest.TestCase):
    def test_scale_rotation_and_negative_coordinates_affect_placement(self):
        rows = [monitor("DP-1", x=-1920, width=3840, scale=2), monitor("DP-2", x=0, width=3840, height=2160, scale=1.5, transform=1)]
        self.assertEqual(HyprlandDisplays.placement(rows, "unused", 1280, "right"), (1440, 0))
        self.assertEqual(HyprlandDisplays.placement(rows, "unused", 1280, "left"), (-3200, 0))

    def test_modern_lua_and_legacy_monitor_commands(self):
        for version, command in (("0.57.0", "eval"), ("0.54.0", "keyword")):
            helpers = Mock()
            helpers.run.return_value = b"ok\n"
            helpers.json.side_effect = lambda *args: {"version": version} if args[-1] == "version" else [monitor("DP-1")]
            displays = HyprlandDisplays(helpers, {"HYPRLAND_INSTANCE_SIGNATURE": "fake"})
            with patch.object(displays, "wait"):
                displays.configure("ORBIT-0123456789abcdef", mode(1280, 720, 60))
            self.assertEqual(helpers.run.call_args.args[1], command)
            self.assertIn("1920x0", helpers.run.call_args.args[-1])

    def test_refusal_with_success_exit_status_is_not_success(self):
        helpers = Mock()
        helpers.run.return_value = b"Name already taken"
        displays = HyprlandDisplays(helpers, {"HYPRLAND_INSTANCE_SIGNATURE": "fake"})
        with self.assertRaises(DisplaySetupError):
            displays.run("output", "create", "headless", "ORBIT-0123456789abcdef")

    def test_power_and_focus_use_the_compositor_dispatch_api(self):
        for version, lua in (("0.57.0", True), ("0.54.0", False)):
            helpers = Mock()
            helpers.run.return_value = b"ok\n"
            helpers.json.return_value = {"version": version}
            displays = HyprlandDisplays(helpers, {"HYPRLAND_INSTANCE_SIGNATURE": "fake"})
            with patch.object(displays, "wait"):
                displays.power("DP-1", False)
            args = helpers.run.call_args.args
            self.assertIn('hl.dsp.dpms({monitor="DP-1",action="off"})' if lua else "off DP-1", args)
            displays.focus("DP-1")
            self.assertIn('hl.dsp.focus({monitor="DP-1"})' if lua else "focusmonitor", helpers.run.call_args.args)

    def test_transitional_hyprland_with_legacy_config_uses_legacy_commands(self):
        helpers = Mock()
        helpers.json.return_value = {"version": "0.55.0"}
        helpers.run.side_effect = [b"eval is only supported with the lua config manager", b"ok"]
        displays = HyprlandDisplays(helpers, {"HYPRLAND_INSTANCE_SIGNATURE": "fake"})
        displays.focus("DP-1")
        self.assertEqual(helpers.run.call_args.args, ("hyprctl", "dispatch", "focusmonitor", "DP-1"))

    def test_invalid_mode_and_output_name_are_rejected(self):
        for values in ((True, 1080, 60), (100000, 720, 60), (1920, 1080, 0)):
            with self.assertRaises(DisplaySetupError):
                mode(*values)
        displays = HyprlandDisplays(Mock(), {})
        with self.assertRaises(DisplaySetupError):
            displays.destroy("DP-1")


if __name__ == "__main__":
    unittest.main()
