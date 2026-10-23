"""SendInput key chords: the exact INPUT structures, ordering, validation and the HTTP routes.

Windows is never touched: user32 is a fake that decodes the INPUT array SendInput receives.
"""
import ctypes
import threading
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_input as keys

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
SCAN = keys.KEYEVENTF_SCANCODE
EXT = keys.KEYEVENTF_EXTENDEDKEY
UP = keys.KEYEVENTF_KEYUP
REAL_LOAD_USER32 = keys._load_user32

DESIGN_KEY_NAMES = (
    {chr(code) for code in range(ord("a"), ord("z") + 1)} | {str(digit) for digit in range(10)}
    | {f"f{number}" for number in range(1, 25)}
    | {"enter", "esc", "tab", "space", "backspace", "delete", "insert", "home", "end", "pageup", "pagedown",
       "up", "down", "left", "right", "printscreen", "pause", "capslock", "numlock", "scrolllock", "menu",
       "minus", "equals", "comma", "period", "slash", "backslash", "semicolon", "quote", "bracketleft",
       "bracketright", "grave"}
    | {f"numpad{digit}" for digit in range(10)}
    | {"volumeup", "volumedown", "volumemute", "playpause", "nexttrack", "prevtrack", "stop"}
    | {"ctrl", "shift", "alt", "win"})


class FakeUser32:
    """Records every SendInput call as decoded (type, wVk, wScan, dwFlags, time, extra) tuples."""

    def __init__(self, layout=None, foreground=0x1234, thread=77, hkl=0x04070407):
        self.layout = layout or {}
        self.sent = []
        self.sizes = []
        self.accept = None  # None: accept everything; otherwise number of events accepted per call
        self.SendInput = MagicMock(side_effect=self._send)
        self.GetForegroundWindow = MagicMock(return_value=foreground)
        self.GetWindowThreadProcessId = MagicMock(return_value=thread)
        self.GetKeyboardLayout = MagicMock(return_value=hkl)
        self.MapVirtualKeyExW = MagicMock(side_effect=lambda vk, mode, hkl: self.layout.get(vk, 0))

    def _send(self, count, array, size):
        self.sizes.append(size)
        self.sent.append([(array[index].type, array[index].ki.wVk, array[index].ki.wScan, array[index].ki.dwFlags,
                           array[index].ki.time, array[index].ki.dwExtraInfo) for index in range(count)])
        return count if self.accept is None else min(count, self.accept)


def down(scan, flags=SCAN, vk=0):
    return (keys.INPUT_KEYBOARD, vk, scan, flags, 0, 0)


def release(scan, flags=SCAN, vk=0):
    return (keys.INPUT_KEYBOARD, vk, scan, flags | UP, 0, 0)


class InputStructureTests(unittest.TestCase):
    def setUp(self):
        self.user32 = FakeUser32()
        patcher = patch.object(keys, "_load_user32", return_value=self.user32)
        patcher.start()
        self.addCleanup(patcher.stop)
        sleeper = patch.object(keys.time, "sleep")
        self.sleep = sleeper.start()
        self.addCleanup(sleeper.stop)

    def test_structures_have_the_windows_layout(self):
        pointer = ctypes.sizeof(ctypes.c_void_p)
        self.assertEqual(ctypes.sizeof(keys.INPUT), 40 if pointer == 8 else 28)
        self.assertEqual(ctypes.sizeof(keys.KEYBDINPUT), 24 if pointer == 8 else 16)
        self.assertEqual(keys.INPUT.u.offset, 8 if pointer == 8 else 4)
        self.assertEqual([keys.KEYBDINPUT.wVk.offset, keys.KEYBDINPUT.wScan.offset, keys.KEYBDINPUT.dwFlags.offset,
                          keys.KEYBDINPUT.time.offset], [0, 2, 4, 8])
        self.assertEqual(keys.KEYBDINPUT.dwExtraInfo.offset, 16 if pointer == 8 else 12)
        self.assertEqual((keys.KEYEVENTF_EXTENDEDKEY, keys.KEYEVENTF_KEYUP, keys.KEYEVENTF_SCANCODE, keys.INPUT_KEYBOARD),
                         (0x1, 0x2, 0x8, 1))

    def test_discord_mute_chord_presses_modifiers_first_holds_and_releases_in_reverse(self):
        self.assertEqual(keys.press_chord(["ctrl", "shift", "m"]), ["ctrl", "shift", "m"])
        self.assertEqual(self.user32.sent, [
            [down(0x1D), down(0x2A), down(0x32)],
            [release(0x32), release(0x2A), release(0x1D)],
        ])
        self.assertEqual(self.user32.sizes, [ctypes.sizeof(keys.INPUT)] * 2)
        self.assertEqual([call.args[0] for call in self.user32.SendInput.call_args_list], [3, 3])
        self.sleep.assert_called_once_with(keys.HOLD_SECONDS)
        self.assertTrue(0.03 <= keys.HOLD_SECONDS <= 0.05)

    def test_modifiers_wrap_the_key_whatever_order_they_are_given_in(self):
        keys.press_chord(["g", "WIN", "Alt"])
        self.assertEqual(self.user32.sent, [
            [down(0x5B, SCAN | EXT), down(0x38), down(0x22)],
            [release(0x22), release(0x38), release(0x5B, SCAN | EXT)],
        ])

    def test_extended_keys_carry_the_extended_flag(self):
        expected = {"insert": 0x52, "delete": 0x53, "home": 0x47, "end": 0x4F, "pageup": 0x49, "pagedown": 0x51,
                    "up": 0x48, "down": 0x50, "left": 0x4B, "right": 0x4D, "menu": 0x5D, "win": 0x5B}
        for name, scan in expected.items():
            with self.subTest(key=name):
                self.user32.sent.clear()
                keys.tap(name)
                self.assertEqual(self.user32.sent, [[down(scan, SCAN | EXT)], [release(scan, SCAN | EXT)]])

    def test_plain_keys_use_set_one_scan_codes(self):
        expected = {"enter": 0x1C, "esc": 0x01, "tab": 0x0F, "space": 0x39, "backspace": 0x0E, "ctrl": 0x1D,
                    "shift": 0x2A, "alt": 0x38, "a": 0x1E, "q": 0x10, "z": 0x2C, "1": 0x02, "9": 0x0A, "0": 0x0B,
                    "minus": 0x0C, "equals": 0x0D, "bracketleft": 0x1A, "bracketright": 0x1B, "semicolon": 0x27,
                    "quote": 0x28, "grave": 0x29, "backslash": 0x2B, "comma": 0x33, "period": 0x34, "slash": 0x35,
                    "f1": 0x3B, "f10": 0x44, "f11": 0x57, "f12": 0x58, "f13": 0x64, "f23": 0x6E, "f24": 0x76}
        for name, scan in expected.items():
            with self.subTest(key=name):
                self.user32.sent.clear()
                keys.tap(name)
                self.assertEqual(self.user32.sent, [[down(scan)], [release(scan)]])

    def test_media_lock_and_numpad_keys_go_by_virtual_key(self):
        expected = {"volumeup": (0xAF, 0x30, EXT), "volumedown": (0xAE, 0x2E, EXT), "volumemute": (0xAD, 0x20, EXT),
                    "playpause": (0xB3, 0x22, EXT), "nexttrack": (0xB0, 0x19, EXT), "prevtrack": (0xB1, 0x10, EXT),
                    "stop": (0xB2, 0x24, EXT), "pause": (0x13, 0x45, 0), "printscreen": (0x2C, 0x37, EXT),
                    "numlock": (0x90, 0x45, EXT), "capslock": (0x14, 0x3A, 0), "scrolllock": (0x91, 0x46, 0),
                    "numpad0": (0x60, 0x52, 0), "numpad5": (0x65, 0x4C, 0), "numpad9": (0x69, 0x49, 0)}
        for name, (vk, scan, flags) in expected.items():
            with self.subTest(key=name):
                self.user32.sent.clear()
                keys.tap(name)
                self.assertEqual(self.user32.sent, [[down(scan, flags, vk)], [release(scan, flags, vk)]])

    def test_every_key_is_either_a_scan_code_or_a_virtual_key_event(self):
        for name, code in keys.KEYS.items():
            with self.subTest(key=name):
                pressed = keys.key_event(code, up=False)
                released = keys.key_event(code, up=True)
                self.assertEqual(pressed.type, keys.INPUT_KEYBOARD)
                self.assertEqual(released.ki.dwFlags, pressed.ki.dwFlags | UP)
                self.assertEqual(pressed.ki.wScan, code.scan)
                self.assertTrue(0 < code.scan <= 0x7F)
                if code.by_vk:
                    self.assertEqual(pressed.ki.wVk, code.vk)
                    self.assertFalse(pressed.ki.dwFlags & SCAN)
                else:
                    self.assertEqual(pressed.ki.wVk, 0)
                    self.assertTrue(pressed.ki.dwFlags & SCAN)
                self.assertEqual(bool(pressed.ki.dwFlags & EXT), code.extended)

    def test_letters_follow_the_keyboard_layout_of_the_window_in_front(self):
        # German QWERTZ: the key that types Z sits where US keyboards have Y (scan 0x15), and the
        # layout reports the slash key as an extended scan code.
        self.user32.layout = {ord("Z"): 0x15, 0xBF: 0xE035}
        keys.press_chord(["ctrl", "z"])
        self.assertEqual(self.user32.sent[0], [down(0x1D), down(0x15)])
        self.user32.GetWindowThreadProcessId.assert_called_with(0x1234, None)
        self.user32.GetKeyboardLayout.assert_called_with(77)
        self.user32.MapVirtualKeyExW.assert_called_once_with(ord("Z"), keys.MAPVK_VK_TO_VSC_EX, 0x04070407)
        self.user32.sent.clear()
        keys.tap("slash")
        self.assertEqual(self.user32.sent[0], [down(0x35, SCAN | EXT)])

    def test_positional_keys_are_not_remapped_and_missing_layout_keys_keep_us_positions(self):
        self.user32.layout = {0xA2: 0x99, 0x79: 0x99}  # would be wrong if consulted
        keys.press_chord(["ctrl", "f10", "left"])
        self.user32.MapVirtualKeyExW.assert_not_called()
        self.assertEqual(self.user32.sent[0], [down(0x1D), down(0x44), down(0x4B, SCAN | EXT)])
        self.user32.layout = {}
        self.user32.sent.clear()
        keys.tap("m")  # MapVirtualKeyExW answers 0: the US scan code is used
        self.assertEqual(self.user32.sent[0], [down(0x32)])

    def test_without_a_foreground_window_the_agents_layout_is_used(self):
        self.user32.GetForegroundWindow.return_value = 0
        keys.tap("a")
        self.user32.GetWindowThreadProcessId.assert_not_called()
        self.user32.GetKeyboardLayout.assert_called_with(0)

    def test_a_failed_press_still_releases_every_key(self):
        self.user32.accept = 1  # Windows took only the first event (Ctrl) of the press
        with self.assertRaises(keys.InputRejected) as refused:
            keys.press_chord(["ctrl", "shift", "esc"])
        self.assertIsInstance(refused.exception, OSError)
        self.assertEqual(len(self.user32.sent), 2)
        self.assertEqual(self.user32.sent[1], [release(0x01), release(0x2A), release(0x1D)])
        self.sleep.assert_not_called()

    def test_an_exception_during_the_hold_still_releases(self):
        self.sleep.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            keys.press_chord(["alt", "tab"])
        self.assertEqual(self.user32.sent[-1], [release(0x0F), release(0x38)])

    def test_invalid_chords_send_nothing(self):
        cases = [
            ([], "at least one key"), (["ctrl", "shift", "alt", "win", "a", "b"], "at most 5"),
            (["ctrl", "CTRL"], "only once"), ("ctrl+m", "list of key names"), (None, "list of key names"),
            (["ctrl", 5], "key name"), (["ctrl", ""], "key name"), (["hyper"], "is not a key"),
            (["ctrl", "alt", "delete"], "Ctrl+Alt+Delete"), (["f25"], "is not a key"), (["numpad10"], "is not a key"),
            (["control"], "is not a key"), (["ctrl", "x" * 300], "is not a key"),
        ]
        for chord, message in cases:
            with self.subTest(chord=chord):
                with self.assertRaises(ValueError) as invalid:
                    keys.press_chord(chord)
                self.assertIn(message, str(invalid.exception))
        self.user32.SendInput.assert_not_called()

    def test_allowlist_is_exactly_the_documented_key_names(self):
        self.assertEqual(set(keys.KEY_NAMES), DESIGN_KEY_NAMES)
        self.assertEqual(keys.normalize_chord(["SHIFT", " Up "]), ["shift", "up"])
        self.assertTrue(keys.is_known_key("PageDown"))
        self.assertFalse(keys.is_known_key("page down"))

    def test_chord_labels(self):
        self.assertEqual(keys.chord_label(["ctrl", "shift", "m"]), "Ctrl+Shift+M")
        self.assertEqual(keys.chord_label(["g", "win", "alt"]), "Win+Alt+G")
        self.assertEqual(keys.chord_label(["alt", "f10"]), "Alt+F10")
        self.assertEqual(keys.chord_label(["shift", "up"]), "Shift+Up")
        self.assertEqual(keys.chord_label(["ctrl", "pagedown"]), "Ctrl+Page Down")

    def test_chords_never_interleave(self):
        holding = threading.Event()
        let_go = threading.Event()
        calls = []

        def slow_hold(seconds):
            calls.append(seconds)
            if len(calls) == 1:
                holding.set()
                let_go.wait(5)
        self.sleep.side_effect = slow_hold
        first = threading.Thread(target=keys.press_chord, args=(["ctrl", "c"],))
        second = threading.Thread(target=keys.press_chord, args=(["ctrl", "v"],))
        first.start()
        self.assertTrue(holding.wait(5))
        second.start()
        second.join(0.2)
        self.assertEqual(len(self.user32.sent), 1)  # the second chord waits while Ctrl+C is held
        let_go.set()
        first.join(5)
        second.join(5)
        self.assertEqual(self.user32.sent, [
            [down(0x1D), down(0x2E)], [release(0x2E), release(0x1D)],
            [down(0x1D), down(0x2F)], [release(0x2F), release(0x1D)],
        ])

    @unittest.skipIf(hasattr(ctypes, "WinDLL"), "only meaningful off Windows")
    def test_load_user32_refuses_off_windows(self):
        with patch.object(keys, "_USER32", None), self.assertRaises(keys.InputRejected):
            REAL_LOAD_USER32()


class InputRouteTests(unittest.TestCase):
    def setUp(self):
        token = patch.object(agent, "API_TOKEN", TOKEN)
        token.start()
        self.addCleanup(token.stop)
        self.client = TestClient(agent.app, base_url="https://testserver")
        self.addCleanup(self.client.close)

    def test_hotkey_requires_token_and_https(self):
        with patch.object(agent.orbit_input, "press_chord") as press:
            self.assertEqual(self.client.post("/api/input/hotkey", json={"keys": ["alt", "f10"]}).status_code, 401)
            self.assertEqual(self.client.post("http://testserver/api/input/hotkey", json={"keys": ["alt", "f10"]}).status_code, 401)
            response = self.client.post("http://testserver/api/input/hotkey", json={"keys": ["alt", "f10"]}, headers=AUTH)
            self.assertEqual(response.status_code, 426)
            press.assert_not_called()

    def test_hotkey_sends_the_normalized_chord(self):
        with patch.object(agent, "require_windows"), patch.object(agent.orbit_input, "press_chord") as press:
            response = self.client.post("/api/input/hotkey", json={"keys": ["F10", "ALT"]}, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "sent"})
        press.assert_called_once_with(["alt", "f10"])

    def test_hotkey_validation_errors_are_422_with_a_sentence(self):
        with patch.object(agent, "require_windows"), patch.object(agent.orbit_input, "press_chord") as press:
            for body, message in (({"keys": ["alt", "warp"]}, "is not a key"),
                                  ({"keys": ["a", "b", "c", "d", "e", "f"]}, "at most 5"),
                                  ({"keys": []}, "at least one key"),
                                  ({"keys": ["ctrl", "alt", "delete"]}, "Ctrl+Alt+Delete")):
                with self.subTest(body=body):
                    response = self.client.post("/api/input/hotkey", json=body, headers=AUTH)
                    self.assertEqual(response.status_code, 422)
                    self.assertIn(message, response.json()["detail"])
            for body in ({}, {"keys": "ctrl+m"}, {"keys": ["a"] * 40}):
                with self.subTest(body=body):
                    self.assertEqual(self.client.post("/api/input/hotkey", json=body, headers=AUTH).status_code, 422)
            press.assert_not_called()

    def test_hotkey_off_windows_and_when_windows_refuses(self):
        with patch.object(agent.os, "name", "posix"), patch.object(agent.orbit_input, "press_chord") as press:
            self.assertEqual(self.client.post("/api/input/hotkey", json={"keys": ["win", "d"]}, headers=AUTH).status_code, 501)
            press.assert_not_called()
        with patch.object(agent, "require_windows"), \
             patch.object(agent.orbit_input, "press_chord", side_effect=keys.InputRejected("Windows did not accept the key presses.")):
            response = self.client.post("/api/input/hotkey", json={"keys": ["win", "d"]}, headers=AUTH)
        self.assertEqual(response.status_code, 503)
        self.assertIn("did not accept", response.json()["detail"])

    def test_keyboard_key_accepts_old_and_new_names_in_any_case(self):
        with patch.object(agent, "require_windows"), patch.object(agent.ctypes, "windll", create=True) as windll, \
             patch.object(agent.orbit_input, "tap") as tap:
            for name, expected in (("ENTER", "enter"), ("BACKSPACE", "backspace"), ("SPACE", "space"), ("ESC", "esc"),
                                   ("WIN", "win"), ("TAB", "tab"), ("volumeup", "volumeup"), ("Right", "right"),
                                   ("f5", "f5"), ("playpause", "playpause")):
                with self.subTest(key=name):
                    tap.reset_mock()
                    response = self.client.post(f"/api/input/keyboard?key={name}", headers=AUTH)
                    self.assertEqual(response.status_code, 200)
                    tap.assert_called_once_with(expected)
            self.assertEqual(self.client.post("/api/input/keyboard?key=hyper", headers=AUTH).status_code, 422)
            self.assertEqual(self.client.post("/api/input/keyboard?key=ctrl%2Bc", headers=AUTH).status_code, 422)
            windll.user32.keybd_event.assert_not_called()

    def test_keyboard_presses_the_key_before_typing_text_and_works_over_http(self):
        order = []
        user32 = MagicMock()
        user32.VkKeyScanW.side_effect = lambda char: ord(char.upper())
        user32.keybd_event.side_effect = lambda vk, scan, flags, extra: order.append(("type", vk, flags))
        client = TestClient(agent.app)  # legacy port: the keyboard route keeps working over HTTP
        self.addCleanup(client.close)
        with patch.object(agent, "require_windows"), patch.object(agent.ctypes, "windll", create=True) as windll, \
             patch.object(agent.orbit_input, "tap", side_effect=lambda name: order.append(("tap", name))):
            windll.user32 = user32
            response = client.post("/api/input/keyboard?key=enter&text=hi", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(order[0], ("tap", "enter"))
        self.assertEqual([entry[1] for entry in order[1:] if entry[2] == 0], [ord("H"), ord("I")])

    def test_keyboard_key_refused_by_windows_is_503(self):
        with patch.object(agent, "require_windows"), patch.object(agent.ctypes, "windll", create=True), \
             patch.object(agent.orbit_input, "tap", side_effect=keys.InputRejected("locked")):
            self.assertEqual(self.client.post("/api/input/keyboard?key=enter", headers=AUTH).status_code, 503)


if __name__ == "__main__":
    unittest.main()
