"""Default playback device (IPolicyConfig) and microphone mute, with every native call faked."""
from contextlib import contextmanager
import ctypes
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_activity as activity
import orbit_agent as agent
import orbit_audio_policy as policy
import orbit_desktop as desktop
import orbit_devices as devices


def fake_vtable(slots=14):
    table = (ctypes.c_void_p * slots)()
    for index in range(slots):
        table[index] = 0x1000 + index
    instance = ctypes.c_void_p(ctypes.addressof(table))
    holder = ctypes.pointer(instance)
    return table, instance, holder


class DefaultEndpointPolicyTests(unittest.TestCase):
    def make(self, status=0):
        table, instance, holder = fake_vtable()
        api = MagicMock()
        created = {}

        def create(clsid, outer, context, iid, result):
            created["clsid"] = bytes(clsid._obj)
            created["iid"] = bytes(iid._obj)
            created["context"] = context
            if status >= 0:
                result._obj.value = ctypes.addressof(instance)
            return status
        api.CoCreateInstance.side_effect = create
        self.keep = (table, instance, holder)
        return api, created

    def test_created_from_policyconfigclient_with_the_verified_iid(self):
        api, created = self.make()
        calls = []

        def prototype(*signature):
            def bind(address):
                def call(*arguments):
                    calls.append((address, signature, arguments[1:]))
                    return 0
                return call
            return bind
        with patch.object(ctypes, "WINFUNCTYPE", prototype, create=True):
            adapter = policy.DefaultEndpointPolicy(api=api)
            adapter.set_default("{0.0.0.00000000}.{speakers}")
            adapter.close()
        self.assertEqual(created["clsid"], uuid.UUID("870af99c-171d-4f9e-af0d-e63df40c2bc9").bytes_le)
        self.assertEqual(created["iid"], uuid.UUID("f8679f50-850a-41cf-9c72-430f290290c8").bytes_le)
        self.assertEqual(created["context"], 0x17)
        set_calls = [call for call in calls if call[0] == 0x1000 + 13]
        self.assertEqual([call[2] for call in set_calls], [("{0.0.0.00000000}.{speakers}", 0), ("{0.0.0.00000000}.{speakers}", 1),
                                                           ("{0.0.0.00000000}.{speakers}", 2)])
        self.assertEqual(set_calls[0][1], (ctypes.c_int32, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int32))
        self.assertEqual([call[0] for call in calls][-1], 0x1000 + 2)  # IUnknown::Release

    def test_unknown_interface_is_refused_before_any_slot_call(self):
        api, _ = self.make(status=-2147467262)  # E_NOINTERFACE
        with patch.object(policy.DefaultEndpointPolicy, "_method") as method:
            with self.assertRaises(policy.AudioPolicyUnavailable):
                policy.DefaultEndpointPolicy(api=api)
        method.assert_not_called()

    def test_failed_role_is_reported(self):
        api, _ = self.make()
        adapter = policy.DefaultEndpointPolicy(api=api)
        results = iter([0, -1])
        with patch.object(adapter, "_method", return_value=lambda client, device, role: next(results)):
            with self.assertRaises(policy.AudioPolicyUnavailable):
                adapter.set_default("{device}")
        with patch.object(adapter, "_method", return_value=MagicMock()):
            for bad in ("", None, "x\0y"):
                with self.assertRaises(policy.AudioPolicyUnavailable):
                    adapter.set_default(bad)
            adapter.close()

    def test_refuses_off_windows_without_an_injected_api(self):
        with patch.object(policy.os, "name", "posix"):
            with self.assertRaises(policy.AudioPolicyUnavailable):
                policy.DefaultEndpointPolicy()


@contextmanager
def nothing():
    yield


def device(identity, name):
    return SimpleNamespace(id=identity, FriendlyName=name)


class DefaultOutputTests(unittest.TestCase):
    def setUp(self):
        self.default = "speakers"
        utilities = SimpleNamespace(GetAllDevices=lambda data_flow, device_state: [device("speakers", "Speakers"),
                                                                                     device("headset", "Headset")],
                                    GetSpeakers=lambda: device(self.default, "x"))
        self.modules = patch.dict(sys.modules, {"pycaw": SimpleNamespace(), "pycaw.pycaw": SimpleNamespace(AudioUtilities=utilities)})
        self.modules.start()

    def tearDown(self):
        self.modules.stop()

    def test_outputs_mark_the_default_device(self):
        self.assertEqual(desktop._output_devices(), [{"id": "speakers", "name": "Speakers", "isDefault": True},
                                                     {"id": "headset", "name": "Headset", "isDefault": False}])
        with patch.object(desktop, "_audio_sessions", nothing), \
             patch.object(desktop, "AudioPolicyConfig", side_effect=policy.AudioPolicyUnavailable("no routing")), \
             patch.object(desktop, "DefaultEndpointPolicy", MagicMock()):
            result = desktop.list_audio_outputs()
        self.assertEqual((result["defaultDeviceID"], result["defaultSwitchAvailable"], result["routingAvailable"]),
                         ("speakers", True, False))

    def test_switch_is_confirmed_by_reading_the_default_back(self):
        adapter = MagicMock()

        def switch(device_id):
            self.default = device_id
        adapter.__enter__.return_value.set_default.side_effect = switch
        with patch.object(desktop, "_com", nothing), patch.object(desktop, "DefaultEndpointPolicy", return_value=adapter):
            result = desktop.set_default_output("headset")
        self.assertEqual((result["status"], result["deviceID"], result["name"]), ("default_changed", "headset", "Headset"))
        self.assertTrue(next(item for item in result["devices"] if item["id"] == "headset")["isDefault"])

    def test_unconfirmed_or_missing_devices_are_errors(self):
        adapter = MagicMock()  # set_default "succeeds" but Windows keeps the old default
        with patch.object(desktop, "_com", nothing), patch.object(desktop, "DefaultEndpointPolicy", return_value=adapter):
            with self.assertRaises(desktop.DesktopUnavailable):
                desktop.set_default_output("headset")
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.set_default_output("unplugged")
        with patch.object(desktop, "_com", nothing), \
             patch.object(desktop, "DefaultEndpointPolicy", side_effect=policy.AudioPolicyUnavailable("old Windows")):
            with self.assertRaisesRegex(desktop.DesktopUnavailable, "old Windows"):
                desktop.set_default_output("headset")


class MicrophoneTests(unittest.TestCase):
    def endpoint(self, identity, muted=False):
        volume = MagicMock()
        volume.GetMute.return_value = muted
        volume.SetMute.side_effect = lambda value, context: setattr(volume.GetMute, "return_value", value)
        return {"id": identity, "name": identity.title(), "volume": volume}

    def test_mutes_every_default_capture_device(self):
        endpoints = [self.endpoint("mic"), self.endpoint("headset-mic")]
        with patch.object(desktop, "_com", nothing), patch.object(desktop, "_capture_endpoints", return_value=endpoints):
            self.assertEqual(desktop.microphone_state(), {"available": True, "muted": False,
                                                          "devices": [{"id": "mic", "name": "Mic"}, {"id": "headset-mic", "name": "Headset-Mic"}]})
            result = desktop.set_microphone_muted(True)
        self.assertTrue(result["muted"])
        for endpoint in endpoints:
            endpoint["volume"].SetMute.assert_called_once_with(True, None)

    def test_no_microphone(self):
        with patch.object(desktop, "_com", nothing), patch.object(desktop, "_capture_endpoints", return_value=[]):
            self.assertEqual(desktop.microphone_state(), {"available": False, "muted": None, "devices": []})
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.set_microphone_muted(True)
        with self.assertRaises(ValueError):
            desktop.set_microphone_muted("yes")

    def test_mute_that_does_not_stick_is_an_error(self):
        stuck = self.endpoint("mic")
        stuck["volume"].SetMute.side_effect = None
        with patch.object(desktop, "_com", nothing), patch.object(desktop, "_capture_endpoints", return_value=[stuck]):
            with self.assertRaises(desktop.DesktopUnavailable):
                desktop.set_microphone_muted(True)

    def test_capture_endpoints_use_both_default_roles_once(self):
        mic = MagicMock()
        mic.GetId.return_value = "mic"
        enumerator = MagicMock()
        enumerator.GetDefaultAudioEndpoint.side_effect = lambda flow, role: mic
        utilities = SimpleNamespace(GetDeviceEnumerator=lambda: enumerator, CreateDevice=lambda dev: SimpleNamespace(FriendlyName="USB Mic"))
        volume_type = type("IAudioEndpointVolume", (ctypes.Structure,), {"_fields_": [("x", ctypes.c_int)], "_iid_": "iid"})
        modules = {"comtypes": SimpleNamespace(CLSCTX_ALL=23), "pycaw": SimpleNamespace(),
                   "pycaw.pycaw": SimpleNamespace(AudioUtilities=utilities, IAudioEndpointVolume=volume_type)}
        mic.Activate.return_value = ctypes.pointer(volume_type())
        with patch.dict(sys.modules, modules):
            endpoints = desktop._capture_endpoints()
        self.assertEqual([(endpoint["id"], endpoint["name"]) for endpoint in endpoints], [("mic", "USB Mic")])
        self.assertEqual([call.args for call in enumerator.GetDefaultAudioEndpoint.call_args_list], [(1, 0), (1, 2)])


class AudioAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        root = Path(self.folder.name)
        self.registry = devices.DeviceRegistry(root / "devices.json")
        self.log = activity.ActivityLog(root / "activity.sqlite3")
        _, token = self.registry.register("Orbit on iPhone", "iOS")
        _, reader = self.registry.register("Orbit on iPad", "iPadOS", scopes=["read"])
        self.auth, self.reader = {"Authorization": f"Bearer {token}"}, {"Authorization": f"Bearer {reader}"}
        self.patches = [patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "ACTIVITY", self.log)]
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

    def test_default_output_endpoint(self):
        result = {"status": "default_changed", "deviceID": "headset", "name": "Headset", "devices": []}
        with patch.object(desktop, "set_default_output", return_value=result) as switch:
            self.assertEqual(self.http.post("/api/audio/default", headers=self.auth, json={"deviceID": "headset"}).status_code, 426)
            self.assertEqual(self.https.post("/api/audio/default", headers=self.reader, json={"deviceID": "headset"}).json()["scope"], "control")
            self.assertEqual(self.https.post("/api/audio/default", headers=self.auth, json={"deviceID": "headset"}).json(), result)
            self.assertEqual(self.https.post("/api/audio/default", headers=self.auth, json={"deviceID": ""}).status_code, 422)
        switch.assert_called_once_with("headset")
        with patch.object(desktop, "set_default_output", side_effect=desktop.AudioSessionGone("gone")):
            self.assertEqual(self.https.post("/api/audio/default", headers=self.auth, json={"deviceID": "x"}).status_code, 409)
        self.log.wait()
        self.assertIn("Made Headset the default output", [row["summary"] for row in self.log.entries(category="audio")["entries"]])

    def test_microphone_endpoints(self):
        with patch.object(desktop, "microphone_state", return_value={"available": True, "muted": False, "devices": []}):
            self.assertEqual(self.https.get("/api/audio/microphone", headers=self.reader).json()["muted"], False)
        with patch.object(desktop, "set_microphone_muted", return_value={"muted": True, "devices": []}) as mute:
            self.assertEqual(self.https.post("/api/audio/microphone", headers=self.auth, json={"muted": True}).json()["muted"], True)
            self.assertEqual(self.https.post("/api/audio/microphone", headers=self.auth, json={"muted": "yes"}).status_code, 422)
        mute.assert_called_once_with(True)
        self.log.wait()
        self.assertIn("Muted the microphone", [row["summary"] for row in self.log.entries(category="audio")["entries"]])


if __name__ == "__main__":
    unittest.main()
