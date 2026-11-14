"""Win+P from the apps (orbit_display_mode). No real display change: Windows is a fake."""
import ctypes
import unittest
from unittest.mock import patch

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_display_mode as display_mode
import orbit_stream_display


def wide(text, length):
    array = (ctypes.c_uint16 * length)()
    data = text.encode("utf-16-le")
    for index in range(len(data) // 2):
        array[index] = data[2 * index] | (data[2 * index + 1] << 8)
    return array


def path(adapter, target, available=True, active=False, technology=5, source=0):
    info = display_mode.DISPLAYCONFIG_PATH_INFO()
    info.sourceInfo.adapterId.LowPart = adapter
    info.sourceInfo.id = source
    info.targetInfo.adapterId.LowPart = adapter
    info.targetInfo.id = target
    info.targetInfo.outputTechnology = technology
    info.targetInfo.targetAvailable = 1 if available else 0
    info.flags = display_mode.DISPLAYCONFIG_PATH_ACTIVE if active else 0
    return info


class FakeTopology:
    def __init__(self, displays=None, mode="extend", code=0):
        self.listed = displays if displays is not None else [
            {"name": "DELL U2723QE", "connection": "DisplayPort", "active": True, "builtIn": False, "virtual": False},
            {"name": "LG TV", "connection": "HDMI", "active": True, "builtIn": False, "virtual": False}]
        self.mode = mode
        self.code = code
        self.applied = []

    def displays(self):
        return [dict(display) for display in self.listed]

    def current_mode(self):
        return self.mode

    def apply(self, mode):
        self.applied.append(mode)
        if self.code == 0:
            self.mode = mode
        return self.code


class LayoutTests(unittest.TestCase):
    def test_structures_match_the_windows_sizes(self):
        self.assertEqual(ctypes.sizeof(display_mode.DISPLAYCONFIG_PATH_INFO), 72)
        self.assertEqual(ctypes.sizeof(display_mode.DISPLAYCONFIG_MODE_INFO), 64)
        self.assertEqual(ctypes.sizeof(display_mode.DISPLAYCONFIG_DEVICE_INFO_HEADER), 20)
        self.assertEqual(ctypes.sizeof(display_mode.DISPLAYCONFIG_TARGET_DEVICE_NAME), 420)
        self.assertEqual(display_mode.DISPLAYCONFIG_PATH_INFO.flags.offset, 68)
        self.assertEqual(display_mode.DISPLAYCONFIG_PATH_TARGET_INFO.targetAvailable.offset, 40)
        self.assertEqual(display_mode.DISPLAYCONFIG_MODE_INFO.union.offset, 16)
        self.assertEqual(display_mode.DISPLAYCONFIG_TARGET_DEVICE_NAME.monitorFriendlyDeviceName.offset, 36)
        self.assertEqual(display_mode.DISPLAYCONFIG_TARGET_DEVICE_NAME.monitorDevicePath.offset, 164)

    def test_topology_ids_and_set_flags(self):
        self.assertEqual(display_mode.SET_FLAGS, {"internal": 1, "clone": 2, "extend": 4, "external": 8})
        self.assertEqual(display_mode.TOPOLOGY_MODES, {1: "internal", 2: "clone", 4: "extend", 8: "external"})
        self.assertEqual(display_mode.SDC_APPLY, 0x80)
        self.assertEqual(tuple(display_mode.MODE_TITLES), display_mode.MODES)

    def test_virtual_monitor_id_matches_the_stream_display_feature(self):
        self.assertIn(orbit_stream_display.VDD_MONITOR_ID, display_mode.VIRTUAL_MONITOR_IDS)


class DisplaysFromPathsTests(unittest.TestCase):
    def test_each_display_once_active_when_any_path_is(self):
        paths = [path(1, 10, active=True, technology=10), path(1, 10, source=1), path(1, 11, source=0),
                 path(1, 11, source=1, active=True), path(1, 12, available=False, technology=5)]
        names = {10: ("DELL U2723QE", r"\\?\DISPLAY#DELA0D1#...", 10), 11: ("LG TV", r"\\?\DISPLAY#GSM5B09#...", 5)}
        displays = display_mode.displays_from_paths(paths, lambda item: names.get(item.targetInfo.id))
        self.assertEqual(displays, [
            {"name": "DELL U2723QE", "connection": "DisplayPort", "active": True, "builtIn": False, "virtual": False},
            {"name": "LG TV", "connection": "HDMI", "active": True, "builtIn": False, "virtual": False}])

    def test_inactive_built_in_and_virtual_displays(self):
        paths = [path(1, 1, active=True, technology=display_mode.OUTPUT_INTERNAL), path(2, 5, technology=16),
                 path(3, 7, technology=display_mode.OUTPUT_VIRTUAL)]
        names = {1: ("", r"\\?\DISPLAY#BOE0A1B#...", None), 5: ("", r"\\?\DISPLAY#MTT1337#5&1&UID256", 16)}
        displays = display_mode.displays_from_paths(paths, lambda item: names.get(item.targetInfo.id))
        self.assertEqual(displays, [
            {"name": "Built-in display", "connection": "Built-in", "active": True, "builtIn": True, "virtual": False},
            {"name": "Virtual display", "connection": "USB", "active": False, "builtIn": False, "virtual": True},
            {"name": "Virtual display", "connection": "Virtual", "active": False, "builtIn": False, "virtual": True}])

    def test_same_target_id_on_two_adapters_are_two_displays(self):
        paths = [path(1, 0, active=True), path(2, 0)]
        displays = display_mode.displays_from_paths(paths, lambda item: None)
        self.assertEqual([display["name"] for display in displays], ["Display 1", "Display 2"])
        self.assertEqual([display["active"] for display in displays], [True, False])

    def test_name_lookup_failure_still_lists_the_display(self):
        def broken(_):
            raise OSError("gone")
        displays = display_mode.displays_from_paths([path(1, 3, active=True)], broken)
        self.assertEqual(displays[0]["name"], "Display 1")
        self.assertEqual(display_mode.connection_name(0xFFFFFFFF), "Other")

    def test_wide_text_stops_at_the_terminator(self):
        self.assertEqual(display_mode._wide_text(wide("Samsung Odyssey G9", 64)), "Samsung Odyssey G9")
        self.assertEqual(display_mode._wide_text(wide("", 64)), "")


class RefusalTests(unittest.TestCase):
    def test_single_display_allows_only_pc_screen(self):
        one = [{"name": "A", "connection": "HDMI", "active": True, "builtIn": False, "virtual": False}]
        self.assertIsNone(display_mode.refusal("internal", one))
        for mode in ("clone", "extend", "external"):
            self.assertIn("Only one display", display_mode.refusal(mode, one))

    def test_second_screen_only_never_leaves_only_a_virtual_display(self):
        displays = [{"name": "A", "connection": "HDMI", "active": True, "builtIn": False, "virtual": False},
                    {"name": "Virtual display", "connection": "Virtual", "active": True, "builtIn": False, "virtual": True}]
        self.assertIsNone(display_mode.refusal("extend", displays))
        self.assertIsNone(display_mode.refusal("clone", displays))
        self.assertIn("virtual", display_mode.refusal("external", displays))
        displays.append({"name": "TV", "connection": "HDMI", "active": False, "builtIn": False, "virtual": False})
        self.assertIsNone(display_mode.refusal("external", displays))

    def test_windows_errors_become_clear_messages(self):
        self.assertEqual(display_mode.apply_error("extend", 5).status, 409)
        self.assertIn("lock screen", display_mode.apply_error("extend", 5).detail)
        self.assertIn("doesn't support Duplicate", display_mode.apply_error("clone", 50).detail)
        for code in (31, 87, 1610):
            self.assertIn("connected and turned on", display_mode.apply_error("external", code).detail)
        self.assertEqual(display_mode.apply_error("extend", 1234).status, 503)


class ServiceTests(unittest.TestCase):
    def test_status_reports_mode_and_displays(self):
        service = display_mode.DisplayModeService(FakeTopology())
        status = service.status()
        self.assertEqual(status["available"], True)
        self.assertIsNone(status["reason"])
        self.assertEqual(status["mode"], "extend")
        self.assertEqual(len(status["displays"]), 2)

    def test_switch_applies_and_returns_the_new_state(self):
        topology = FakeTopology()
        service = display_mode.DisplayModeService(topology)
        status = service.set_mode("external")
        self.assertEqual(topology.applied, ["external"])
        self.assertEqual(status["mode"], "external")

    def test_refused_switch_never_reaches_windows(self):
        topology = FakeTopology(displays=[{"name": "A", "connection": "HDMI", "active": True, "builtIn": False,
                                           "virtual": False}], mode="internal")
        service = display_mode.DisplayModeService(topology)
        with self.assertRaises(display_mode.DisplayModeError) as raised:
            service.set_mode("extend")
        self.assertEqual(raised.exception.status, 409)
        self.assertEqual(topology.applied, [])

    def test_windows_error_is_reported(self):
        topology = FakeTopology(code=31)
        service = display_mode.DisplayModeService(topology)
        with self.assertRaises(display_mode.DisplayModeError) as raised:
            service.set_mode("clone")
        self.assertEqual(raised.exception.status, 409)
        self.assertEqual(topology.applied, ["clone"])
        self.assertEqual(topology.mode, "extend")

    def test_no_desktop_before_sign_in(self):
        topology = FakeTopology()
        service = display_mode.DisplayModeService(topology, desktop_available=lambda: False)
        status = service.status()
        self.assertFalse(status["available"])
        self.assertIn("Sign in", status["reason"])
        with self.assertRaises(display_mode.DisplayModeError):
            service.set_mode("extend")
        self.assertEqual(topology.applied, [])

    def test_read_failure_is_not_a_crash(self):
        class Broken(FakeTopology):
            def displays(self):
                raise OSError(31, "QueryDisplayConfig failed")
        status = display_mode.DisplayModeService(Broken()).status()
        self.assertFalse(status["available"])
        self.assertEqual(status["displays"], [])
        with self.assertRaises(display_mode.DisplayModeError) as raised:
            display_mode.DisplayModeService(Broken()).set_mode("extend")
        self.assertEqual(raised.exception.status, 503)

    def test_layout_outside_the_four_modes(self):
        status = display_mode.DisplayModeService(FakeTopology(mode=None)).status()
        self.assertTrue(status["available"])
        self.assertIsNone(status["mode"])

    def test_not_windows(self):
        with patch.object(display_mode.os, "name", "posix"):
            status = display_mode.DisplayModeService().status()
        self.assertFalse(status["available"])
        self.assertIn("Windows", status["reason"])


class FakeUser32:
    """The four user32 calls with a two-display configuration, for WindowsDisplayTopology."""

    def __init__(self, topology=4, set_result=0, insufficient_once=False):
        self.topology = topology
        self.set_result = set_result
        self.insufficient_once = insufficient_once
        self.set_calls = []
        self.GetDisplayConfigBufferSizes = self._sizes
        self.QueryDisplayConfig = self._query
        self.SetDisplayConfig = self._set
        self.DisplayConfigGetDeviceInfo = self._info

    def _sizes(self, flags, paths, modes):
        ctypes.cast(paths, ctypes.POINTER(ctypes.c_uint32))[0] = 3
        ctypes.cast(modes, ctypes.POINTER(ctypes.c_uint32))[0] = 2
        return 0

    def _query(self, flags, count, paths, mode_count, modes, topology):
        if self.insufficient_once:
            self.insufficient_once = False
            return display_mode.ERROR_INSUFFICIENT_BUFFER
        array = ctypes.cast(paths, ctypes.POINTER(display_mode.DISPLAYCONFIG_PATH_INFO))
        for index, item in enumerate((path(1, 10, active=True, technology=10), path(1, 10, source=1),
                                      path(1, 11, technology=5))):
            array[index] = item
        ctypes.cast(count, ctypes.POINTER(ctypes.c_uint32))[0] = 3
        if flags & display_mode.QDC_DATABASE_CURRENT:
            ctypes.cast(topology, ctypes.POINTER(ctypes.c_uint32))[0] = self.topology
        else:
            assert topology is None
        return 0

    def _info(self, header):
        request = ctypes.cast(header, ctypes.POINTER(display_mode.DISPLAYCONFIG_TARGET_DEVICE_NAME)).contents
        assert request.header.type == display_mode.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        assert request.header.size == 420
        name = {10: "DELL U2723QE", 11: "LG TV"}[request.header.id]
        request.monitorFriendlyDeviceName = wide(name, 64)
        request.outputTechnology = {10: 10, 11: 5}[request.header.id]
        return 0

    def _set(self, path_count, paths, mode_count, modes, flags):
        self.set_calls.append((path_count, paths, mode_count, modes, flags))
        return self.set_result


class PrototypeCheck:
    """Accepts argtypes/restype assignment like a ctypes function, and calls the fake."""

    def __init__(self, function):
        self.function = function
        self.argtypes = None
        self.restype = None

    def __call__(self, *arguments):
        converted = []
        for argument, kind in zip(arguments, self.argtypes):
            if argument is None:
                converted.append(None)
            elif isinstance(argument, int):
                converted.append(argument)
            else:
                converted.append(ctypes.cast(argument, ctypes.c_void_p))
        return self.function(*converted)


class WrappedUser32:
    def __init__(self, fake):
        for name in ("GetDisplayConfigBufferSizes", "QueryDisplayConfig", "SetDisplayConfig", "DisplayConfigGetDeviceInfo"):
            setattr(self, name, PrototypeCheck(getattr(fake, name)))


class WindowsTopologyTests(unittest.TestCase):
    def test_reads_mode_and_displays_through_the_native_calls(self):
        fake = FakeUser32(topology=2, insufficient_once=True)
        topology = display_mode.WindowsDisplayTopology(WrappedUser32(fake))
        self.assertEqual(topology.current_mode(), "clone")
        self.assertEqual(topology.displays(), [
            {"name": "DELL U2723QE", "connection": "DisplayPort", "active": True, "builtIn": False, "virtual": False},
            {"name": "LG TV", "connection": "HDMI", "active": False, "builtIn": False, "virtual": False}])
        user32 = topology.user32()
        self.assertIs(user32.SetDisplayConfig.restype, ctypes.c_long)
        self.assertEqual(len(user32.QueryDisplayConfig.argtypes), 6)

    def test_apply_uses_only_the_topology_flag(self):
        fake = FakeUser32()
        topology = display_mode.WindowsDisplayTopology(WrappedUser32(fake))
        self.assertEqual(topology.apply("external"), 0)
        self.assertEqual(fake.set_calls, [(0, None, 0, None, display_mode.SDC_APPLY | display_mode.SDC_TOPOLOGY_EXTERNAL)])
        fake.set_result = 31
        self.assertEqual(topology.apply("clone"), 31)

    def test_unknown_topology_is_none(self):
        topology = display_mode.WindowsDisplayTopology(WrappedUser32(FakeUser32(topology=0)))
        self.assertIsNone(topology.current_mode())

    def test_failed_query_raises(self):
        fake = FakeUser32()
        fake.QueryDisplayConfig = lambda *arguments: 31
        topology = display_mode.WindowsDisplayTopology(WrappedUser32(fake))
        with self.assertRaises(OSError):
            topology.displays()


class RouteTests(unittest.TestCase):
    def setUp(self):
        def verify(authorization: str = Header(None)):
            if authorization != "Bearer control":
                raise HTTPException(401, "Invalid token")

        def https(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(426, "Encrypted connection needed")
        self.topology = FakeTopology()
        app = FastAPI()
        app.include_router(display_mode.create_display_mode_router(verify, https,
                                                                   display_mode.DisplayModeService(self.topology)))
        self.client = TestClient(app, base_url="https://pc.local")
        self.headers = {"Authorization": "Bearer control"}

    def test_token_and_encryption_are_required(self):
        self.assertEqual(self.client.get("/api/display/mode").status_code, 401)
        self.assertEqual(self.client.post("/api/display/mode", json={"mode": "extend"}).status_code, 401)
        self.assertEqual(self.client.post("http://pc.local/api/display/mode", headers=self.headers,
                                          json={"mode": "clone"}).status_code, 426)
        self.assertEqual(self.topology.applied, [])

    def test_get_and_post(self):
        response = self.client.get("/api/display/mode", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.json()), {"available", "reason", "mode", "displays"})
        response = self.client.post("/api/display/mode", headers=self.headers, json={"mode": "clone"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["mode"], "clone")
        self.assertEqual(self.topology.applied, ["clone"])

    def test_body_is_validated(self):
        for body in ({"mode": "mirror"}, {}, {"mode": "extend", "extra": 1}, {"mode": 4}):
            with self.subTest(body=body):
                self.assertEqual(self.client.post("/api/display/mode", headers=self.headers, json=body).status_code, 422)
        self.assertEqual(self.topology.applied, [])

    def test_refusal_and_windows_errors_are_409(self):
        self.topology.code = 5
        response = self.client.post("/api/display/mode", headers=self.headers, json={"mode": "internal"})
        self.assertEqual(response.status_code, 409)
        self.assertIn("Sign in", response.json()["detail"])


class AgentWiringTests(unittest.TestCase):
    def test_agent_serves_display_mode_and_lists_the_features(self):
        import orbit_agent as agent
        import orbit_capabilities as capabilities
        self.assertTrue(capabilities.has_feature("displayMode"))
        self.assertTrue(capabilities.has_feature("audioDefaults"))
        self.assertIsInstance(agent.DISPLAY_MODE, display_mode.DisplayModeService)
        with patch.object(agent, "API_TOKEN", "wiring-token"), \
                patch.object(agent.DISPLAY_MODE, "_platform", FakeTopology()), \
                patch.object(agent.DISPLAY_MODE, "_desktop_available", lambda: True):
            client = TestClient(agent.app, base_url="https://pc.local")
            self.addCleanup(client.close)
            headers = {"Authorization": "Bearer wiring-token"}
            response = client.get("/api/display/mode", headers=headers)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["mode"], "extend")
            self.assertEqual(client.get("http://pc.local/api/display/mode", headers=headers).status_code, 426)
            # The audio routes exist (they answer 503 off Windows, never 404).
            self.assertNotEqual(client.get("/api/audio/devices", headers=headers).status_code, 404)
            self.assertNotEqual(client.post("/api/audio/default", headers=headers,
                                            json={"flow": "output", "deviceID": "{x}"}).status_code, 404)


if __name__ == "__main__":
    unittest.main()
