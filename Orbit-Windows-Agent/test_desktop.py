"""No physical clipboard or audio writes: native boundaries are mocked."""
from contextlib import contextmanager
import ctypes
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_desktop as desktop
import orbit_audio_policy as policy_adapter


class ClipboardAPIs:
    def __init__(self, text="Hello 😀\năîșț"):
        self.data = text.encode("utf-16-le") + b"\0\0"
        self.buffer = ctypes.create_string_buffer(self.data)
        self.user = MagicMock()
        self.kernel = MagicMock()
        self.user.CreateWindowExW.return_value = 123
        self.user.OpenClipboard.return_value = True
        self.user.IsClipboardFormatAvailable.return_value = True
        self.user.GetClipboardData.return_value = 456
        self.user.SetClipboardData.return_value = 456
        self.user.EmptyClipboard.return_value = True
        self.kernel.GlobalSize.side_effect = lambda _: len(self.data)
        self.kernel.GlobalLock.side_effect = lambda _: ctypes.addressof(self.buffer)
        self.kernel.GlobalAlloc.side_effect = self.allocate

    def allocate(self, flags, size):
        self.buffer = ctypes.create_string_buffer(size)
        return 456

    def clipboard(self):
        return desktop.WindowsClipboard((self.user, self.kernel))


class ClipboardTests(unittest.TestCase):
    def test_64_bit_handle_and_memory_api_signatures(self):
        user, kernel = MagicMock(), MagicMock()
        with patch.object(desktop.os, "name", "nt"), \
             patch.object(desktop.ctypes, "WinDLL", side_effect=[user, kernel], create=True):
            desktop._clipboard_apis()
        self.assertIs(kernel.GlobalLock.restype, ctypes.c_void_p)
        self.assertIs(kernel.GlobalSize.restype, ctypes.c_size_t)
        self.assertEqual(kernel.GlobalAlloc.argtypes[1], ctypes.c_size_t)
        self.assertEqual(user.GetClipboardData.restype, desktop.wintypes.HANDLE)

    def test_reads_unicode_with_bounded_utf16_and_releases_handles(self):
        native = ClipboardAPIs()
        self.assertEqual(native.clipboard().read(), "Hello 😀\năîșț")
        native.kernel.GlobalUnlock.assert_called_once_with(456)
        native.user.CloseClipboard.assert_called_once()
        native.user.DestroyWindow.assert_called_once_with(123)
        native.kernel.GlobalFree.assert_not_called()  # the clipboard owns read handles

    def test_nontext_clipboard_does_not_request_data(self):
        native = ClipboardAPIs()
        native.user.IsClipboardFormatAvailable.return_value = False
        self.assertIsNone(native.clipboard().read())
        native.user.GetClipboardData.assert_not_called()

    def test_unterminated_text_is_rejected_and_unlocked(self):
        native = ClipboardAPIs()
        native.data = b"a\0b\0"
        native.buffer = ctypes.create_string_buffer(native.data)
        with self.assertRaisesRegex(desktop.DesktopUnavailable, "terminator"):
            native.clipboard().read()
        native.kernel.GlobalUnlock.assert_called_once()

    def test_oversized_read_never_dereferences_memory(self):
        native = ClipboardAPIs()
        native.kernel.GlobalSize.side_effect = None
        native.kernel.GlobalSize.return_value = desktop.MAX_CLIPBOARD_BYTES + 2
        with self.assertRaises(desktop.DesktopUnavailable):
            native.clipboard().read()
        native.kernel.GlobalLock.assert_not_called()

    def test_write_utf16_ownership_transfers_only_on_success(self):
        native = ClipboardAPIs()
        native.clipboard().write("é🪐")
        expected = "é🪐".encode("utf-16-le") + b"\0\0"
        self.assertEqual(native.buffer.raw, expected)
        native.kernel.GlobalAlloc.assert_called_once_with(2, len(expected))
        native.user.OpenClipboard.assert_called_once_with(123)  # never NULL HWND
        native.kernel.GlobalUnlock.assert_called_once()
        native.kernel.GlobalFree.assert_not_called()

    def test_failed_write_frees_allocation(self):
        native = ClipboardAPIs()
        native.user.SetClipboardData.return_value = 0
        with self.assertRaises(desktop.DesktopUnavailable):
            native.clipboard().write("hello")
        native.kernel.GlobalFree.assert_called_once_with(456)
        native.user.CloseClipboard.assert_called_once()

    def test_allocation_failure_preserves_existing_clipboard(self):
        native = ClipboardAPIs()
        native.kernel.GlobalAlloc.side_effect = None
        native.kernel.GlobalAlloc.return_value = 0
        with self.assertRaises(desktop.DesktopUnavailable):
            native.clipboard().write("hello")
        native.user.EmptyClipboard.assert_not_called()

    def test_busy_clipboard_retries_then_destroys_owner(self):
        native = ClipboardAPIs()
        native.user.OpenClipboard.return_value = False
        with patch.object(desktop.time, "sleep") as delay:
            with self.assertRaisesRegex(desktop.DesktopUnavailable, "busy"):
                native.clipboard().read()
        self.assertEqual(native.user.OpenClipboard.call_count, 6)
        self.assertEqual(delay.call_count, 5)
        native.user.CloseClipboard.assert_not_called()
        native.user.DestroyWindow.assert_called_once()

    def test_invalid_write_never_opens_clipboard(self):
        native = ClipboardAPIs()
        for value in ("embedded\0null", "😀" * (desktop.MAX_CLIPBOARD_BYTES // 4), "\ud800"):
            with self.assertRaises(ValueError):
                native.clipboard().write(value)
        native.user.OpenClipboard.assert_not_called()


def session(instance="instance A", pid=123, name="game.exe", level=0.75, muted=False):
    volume = MagicMock()
    volume.GetMasterVolume.return_value = level
    volume.GetMute.return_value = muted
    volume.SetMasterVolume.side_effect = lambda value, _: setattr(volume.GetMasterVolume, "return_value", value)
    volume.SetMute.side_effect = lambda value, _: setattr(volume.GetMute, "return_value", value)
    process = MagicMock()
    process.name.return_value = name
    process.create_time.return_value = 1700000000.25
    return SimpleNamespace(InstanceIdentifier=instance, ProcessId=pid, State=1,
                           Process=process, SimpleAudioVolume=volume)


@contextmanager
def sessions(items):
    yield items


class AudioMixerTests(unittest.TestCase):
    def test_com_is_initialized_and_released_on_request_thread(self):
        com, audio = MagicMock(), MagicMock()
        audio.GetAllSessions.return_value = []
        modules = {"comtypes": com, "pycaw": SimpleNamespace(),
                   "pycaw.pycaw": SimpleNamespace(AudioUtilities=audio)}
        with patch.object(desktop.os, "name", "nt"), patch.dict(sys.modules, modules):
            with desktop._audio_sessions() as values:
                self.assertEqual(values, [])
        com.CoInitialize.assert_called_once()
        com.CoUninitialize.assert_called_once()

    def test_com_released_after_native_failure(self):
        com, audio = MagicMock(), MagicMock()
        audio.GetAllSessions.side_effect = OSError("No endpoint")
        modules = {"comtypes": com, "pycaw": SimpleNamespace(),
                   "pycaw.pycaw": SimpleNamespace(AudioUtilities=audio)}
        with patch.object(desktop.os, "name", "nt"), patch.dict(sys.modules, modules):
            with self.assertRaises(desktop.DesktopUnavailable):
                with desktop._audio_sessions():
                    self.fail("Failed native enumeration must not produce sessions")
        com.CoUninitialize.assert_called_once()

    def test_multiple_sessions_for_same_pid_have_different_identity(self):
        one, two = session("one"), session("two")
        with patch.object(desktop, "_audio_sessions", lambda: sessions([one, two])):
            result = desktop.list_audio_sessions()
        self.assertEqual(len({item["id"] for item in result}), 2)
        self.assertEqual(result[0]["volume"], 75)
        self.assertFalse(result[0]["isMuted"])

    def test_session_scalar_does_not_change_master_or_other_application(self):
        one, two = session("one"), session("two")
        identity = desktop._session_identity(two)[0]
        with patch.object(desktop, "_audio_sessions", lambda: sessions([one, two])):
            result = desktop.update_audio_session(identity, 38, True)
        two.SimpleAudioVolume.SetMasterVolume.assert_called_once_with(0.38, None)
        two.SimpleAudioVolume.SetMute.assert_called_once_with(True, None)
        one.SimpleAudioVolume.SetMasterVolume.assert_not_called()
        self.assertEqual(result["volume"], 38)
        self.assertTrue(result["isMuted"])

    def test_recycled_pid_or_ended_session_cannot_receive_command(self):
        old, replacement = session("old"), session("new")
        old_identity = desktop._session_identity(old)[0]
        with patch.object(desktop, "_audio_sessions", lambda: sessions([replacement])):
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.update_audio_session(old_identity, 50)
        replacement.SimpleAudioVolume.SetMasterVolume.assert_not_called()

    def test_session_identity_is_checked_again_before_write(self):
        current = session()
        identity = desktop._session_identity(current)[0]
        with patch.object(desktop, "_audio_sessions", lambda: sessions([current])), \
             patch.object(desktop, "_session_identity", side_effect=[(identity, 123), ("b" * 64, 123)]):
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.update_audio_session(identity, 50)
        current.SimpleAudioVolume.SetMasterVolume.assert_not_called()

    def test_expired_sessions_are_omitted_and_rejected(self):
        current = session()
        current.State = 2
        with patch.object(desktop, "_audio_sessions", lambda: sessions([current])):
            self.assertEqual(desktop.list_audio_sessions(), [])
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.update_audio_session(desktop._session_identity(current)[0], 50)

    def test_invalid_levels_do_not_enter_native_audio(self):
        with patch.object(desktop, "_audio_sessions") as native:
            for value in (float("nan"), float("inf"), -1, 101, True, "50"):
                with self.assertRaises(ValueError):
                    desktop.update_audio_session("a" * 64, value)
        native.assert_not_called()

    def test_per_app_routing_validates_device_and_process_lifetime(self):
        current = session()
        identity = desktop._session_identity(current)[0]
        process = MagicMock(); process.create_time.return_value = 1700000000.25
        with patch.object(desktop, "_audio_sessions", lambda: sessions([current])), \
             patch.object(desktop, "_output_devices", return_value=[{"id": "speakers", "name": "Speakers"}]), \
             patch.object(desktop.psutil, "Process", return_value=process), \
             patch.object(desktop, "AudioPolicyConfig") as factory:
            factory.return_value.__enter__.return_value.set_output.side_effect = lambda pid, output, verify: verify()
            result = desktop.route_audio_session(identity, 1700000000.25, "speakers")
        self.assertEqual(result["status"], "routing_requested")
        self.assertEqual(result["pid"], 123)
        self.assertEqual(factory.return_value.__enter__.return_value.set_output.call_args.args[:2], (123, "speakers"))

    def test_per_app_route_cannot_target_reused_pid_or_disconnected_device(self):
        current = session(); identity = desktop._session_identity(current)[0]
        with patch.object(desktop, "_audio_sessions", lambda: sessions([current])), \
             patch.object(desktop, "_output_devices", return_value=[]), \
             patch.object(desktop, "AudioPolicyConfig") as native:
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.route_audio_session(identity, 1700000000.25, "disconnected")
        native.assert_not_called()
        process = MagicMock(); process.create_time.return_value = 1700000001
        with patch.object(desktop, "_audio_sessions", lambda: sessions([current])), \
             patch.object(desktop, "_output_devices", return_value=[]), \
             patch.object(desktop.psutil, "Process", return_value=process), \
             patch.object(desktop, "AudioPolicyConfig") as native:
            with self.assertRaises(desktop.AudioSessionGone):
                desktop.route_audio_session(identity, 1700000000.25, "")
        native.assert_not_called()

    def test_routing_capability_failure_does_not_claim_global_device_switch(self):
        with patch.object(desktop, "_audio_sessions", lambda: sessions([])), \
             patch.object(desktop, "_output_devices", return_value=[{"id": "speaker", "name": "Speakers"}]), \
             patch.object(desktop, "AudioPolicyConfig", side_effect=policy_adapter.AudioPolicyUnavailable("Unsupported interface")):
            result = desktop.list_audio_outputs()
        self.assertFalse(result["routingAvailable"])
        self.assertEqual(result["routingUnavailableReason"], "Unsupported interface")
        self.assertEqual(len(result["devices"]), 1)


class AudioPolicyAdapterTests(unittest.TestCase):
    def test_exact_known_iinspectable_slot_and_argument_layout(self):
        adapter = policy_adapter.AudioPolicyConfig.__new__(policy_adapter.AudioPolicyConfig)
        table = (ctypes.c_void_p * 27)()
        table[25] = 0x12345678; table[26] = 0x23456789
        instance = ctypes.c_void_p(ctypes.addressof(table))
        adapter.factory = ctypes.cast(ctypes.pointer(instance), ctypes.c_void_p)
        function = MagicMock()
        with patch.object(ctypes, "WINFUNCTYPE", return_value=function, create=True) as signature:
            adapter._method(adapter.SET_SLOT, ctypes.c_uint32, ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p)
        function.assert_called_once_with(0x12345678)
        self.assertEqual(signature.call_args.args, (ctypes.c_int32, ctypes.c_void_p, ctypes.c_uint32,
                                                   ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p))
        self.assertEqual(ctypes.sizeof(policy_adapter._GUID), 16)

    def test_all_app_roles_are_changed_without_master_or_other_process_calls(self):
        adapter = policy_adapter.AudioPolicyConfig.__new__(policy_adapter.AudioPolicyConfig)
        values = {0: "", 1: "", 2: ""}; writes = []
        adapter._get_raw = lambda pid, role: values[role]
        def write(pid, role, output):
            writes.append((pid, role, output)); values[role] = output
        adapter._set_raw = write
        verify = MagicMock()
        adapter.set_output(123, "{test-output}", verify)
        self.assertEqual([item[:2] for item in writes], [(123, 0), (123, 1), (123, 2)])
        self.assertEqual(values[0], r"\\?\SWD#MMDEVAPI#{test-output}#{e6327cad-dcec-4949-ae8a-991e976a79d2}")
        self.assertEqual(verify.call_count, 4)

    def test_partial_policy_failure_restores_previous_roles(self):
        adapter = policy_adapter.AudioPolicyConfig.__new__(policy_adapter.AudioPolicyConfig)
        values = {0: "old-console", 1: "old-multimedia", 2: "old-communication"}
        original = values.copy()
        adapter._get_raw = lambda pid, role: values[role]
        def write(pid, role, output):
            if role == 1 and output.startswith(adapter.PREFIX):
                raise policy_adapter.AudioPolicyUnavailable("Device removed")
            values[role] = output
        adapter._set_raw = write
        with self.assertRaises(policy_adapter.AudioPolicyUnavailable):
            adapter.set_output(123, "new-device", lambda: None)
        self.assertEqual(values, original)

    def test_failed_readback_is_not_claimed_as_success(self):
        adapter = policy_adapter.AudioPolicyConfig.__new__(policy_adapter.AudioPolicyConfig)
        adapter._get_raw = lambda pid, role: ""
        adapter._set_raw = MagicMock()
        with self.assertRaisesRegex(policy_adapter.AudioPolicyUnavailable, "retain"):
            adapter.set_output(123, "new-device", lambda: None)

    def test_winrt_apartment_and_hstring_ownership_are_balanced(self):
        api = MagicMock(); api.RoInitialize.return_value = 0
        def create(text, length, result):
            result._obj.value = 123
            return 0
        def activate(name, iid, result):
            result._obj.value = 456
            return 0
        api.WindowsCreateString.side_effect = create
        api.RoGetActivationFactory.side_effect = activate
        with patch.object(policy_adapter.os, "name", "nt"), \
             patch.object(policy_adapter.sys, "getwindowsversion", return_value=SimpleNamespace(major=10, build=22631), create=True), \
             patch.object(ctypes, "WinDLL", return_value=api, create=True), \
             patch.object(policy_adapter.AudioPolicyConfig, "_method", return_value=MagicMock()) as method:
            with policy_adapter.AudioPolicyConfig():
                pass
        api.RoInitialize.assert_called_once_with(0)
        api.RoUninitialize.assert_called_once()
        api.WindowsDeleteString.assert_called_once()
        method.assert_called_once_with(2)

    def test_failed_interface_activation_closes_winrt_without_any_slot_call(self):
        api = MagicMock(); api.RoInitialize.return_value = 1
        api.WindowsCreateString.side_effect = lambda text, length, result: 0
        api.RoGetActivationFactory.return_value = -2147467262
        with patch.object(policy_adapter.os, "name", "nt"), \
             patch.object(policy_adapter.sys, "getwindowsversion", return_value=SimpleNamespace(major=10, build=19045), create=True), \
             patch.object(ctypes, "WinDLL", return_value=api, create=True), \
             patch.object(policy_adapter.AudioPolicyConfig, "_method") as method:
            with self.assertRaises(policy_adapter.AudioPolicyUnavailable):
                policy_adapter.AudioPolicyConfig()
        method.assert_not_called()
        api.RoUninitialize.assert_called_once()


class DesktopRouteTests(unittest.TestCase):
    def setUp(self):
        def verify(authorization: str = Header(None)):
            if authorization != "Bearer control":
                raise HTTPException(401, "Invalid control token")
        app = FastAPI()
        app.include_router(desktop.create_desktop_router(verify))
        self.client = TestClient(app, base_url="https://pc.local")
        self.headers = {"Authorization": "Bearer control"}

    def test_all_routes_require_control_token(self):
        for method, path, body in (("GET", "/api/clipboard", None),
                                   ("PUT", "/api/clipboard", {"text": "hello"}),
                                   ("GET", "/api/audio/sessions", None),
                                   ("POST", "/api/audio/session", {"id": "a" * 64, "volume": 50}),
                                   ("GET", "/api/audio/outputs", None),
                                   ("POST", "/api/audio/route", {"id": "a" * 64, "expectedCreateTime": 1700000000, "deviceID": ""})):
            with self.subTest(path=path):
                self.assertEqual(self.client.request(method, path, json=body).status_code, 401)
                self.assertEqual(self.client.request(method, path, json=body,
                                                    headers={"Authorization": "Bearer widget"}).status_code, 401)

    def test_http_is_rejected_before_clipboard_access(self):
        with patch.object(desktop, "WindowsClipboard") as native:
            response = self.client.get("http://pc.local/api/clipboard", headers=self.headers)
        self.assertEqual(response.status_code, 426)
        native.assert_not_called()

    def test_empty_nontext_clipboard_is_distinguished_from_empty_text(self):
        with patch.object(desktop, "WindowsClipboard") as native:
            native.return_value.read.return_value = None
            self.assertFalse(self.client.get("/api/clipboard", headers=self.headers).json()["available"])
            native.return_value.read.return_value = ""
            self.assertTrue(self.client.get("/api/clipboard", headers=self.headers).json()["available"])

    def test_write_is_explicit_and_validated(self):
        with patch.object(desktop, "WindowsClipboard") as native:
            response = self.client.put("/api/clipboard", headers=self.headers, json={"text": "hello"})
            self.assertEqual(response.status_code, 200)
            native.return_value.write.assert_called_once_with("hello")
            self.assertEqual(self.client.put("/api/clipboard", headers=self.headers,
                                            json={"text": "bad\u0000text"}).status_code, 422)

    def test_audio_validation_and_stale_session_status(self):
        for body in ({"id": "a" * 64}, {"id": "a" * 64, "volume": True},
                     {"id": "a" * 64, "volume": 101}, {"id": "a" * 64, "isMuted": "true"},
                     {"id": "x/y", "volume": 20}):
            self.assertEqual(self.client.post("/api/audio/session", json=body, headers=self.headers).status_code, 422)
        with patch.object(desktop, "update_audio_session", side_effect=desktop.AudioSessionGone("Refresh mixer")):
            self.assertEqual(self.client.post("/api/audio/session", json={"id": "a" * 64, "volume": 50},
                                             headers=self.headers).status_code, 409)

    def test_native_unavailability_is_truthful(self):
        with patch.object(desktop, "list_audio_sessions", side_effect=desktop.DesktopUnavailable("No device")):
            response = self.client.get("/api/audio/sessions", headers=self.headers)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], "No device")

    def test_route_validates_creation_time_and_uses_https(self):
        for value in (True, "1700000000", -1):
            response = self.client.post("/api/audio/route", headers=self.headers,
                                        json={"id": "a" * 64, "expectedCreateTime": value, "deviceID": ""})
            self.assertEqual(response.status_code, 422)
        with patch.object(desktop, "route_audio_session") as native:
            response = self.client.post("http://pc.local/api/audio/route", headers=self.headers,
                                        json={"id": "a" * 64, "expectedCreateTime": 1700000000, "deviceID": ""})
        self.assertEqual(response.status_code, 426)
        native.assert_not_called()


if __name__ == "__main__":
    unittest.main()
