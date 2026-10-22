"""Keyboard input planning and the SendInput adapter, with a fake user32: nothing is typed."""
import ctypes
import json
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_input as keyboard

TOKEN = "input-test-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
UP, UNICODE, EXT = keyboard.KEYEVENTF_KEYUP, keyboard.KEYEVENTF_UNICODE, keyboard.KEYEVENTF_EXTENDEDKEY


class FakeUser32:
    def __init__(self, accept=None, layout=None):
        self.accept = accept
        self.layout = layout or {}
        self.batches = []
        self.SendInput = MagicMock(side_effect=self.send)
        self.MapVirtualKeyW = MagicMock(side_effect=lambda code, kind: code + 0x100)
        self.VkKeyScanW = MagicMock(side_effect=lambda character: self.layout.get(character, -1))

    def send(self, count, array, size):
        self.batches.append([(array[index].union.ki.wVk, array[index].union.ki.wScan, array[index].union.ki.dwFlags)
                             for index in range(count)])
        self.size = size
        return count if self.accept is None else min(self.accept, count)


class PlanTests(unittest.TestCase):
    def test_input_structure_matches_windows(self):
        expected = 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28
        self.assertEqual(ctypes.sizeof(keyboard.INPUT), expected)
        self.assertEqual(keyboard.INPUT.union.offset, 8 if expected == 40 else 4)

    def test_text_is_unicode_packets_in_any_layout(self):
        events = keyboard.text_events("aă€🪐")
        units = [scan for vk, scan, flags in events if not flags & UP]
        self.assertEqual(units, [ord("a"), ord("ă"), ord("€"), 0xD83E, 0xDE90])
        self.assertTrue(all(vk == 0 and flags & UNICODE for vk, scan, flags in events))
        self.assertEqual(len(events), 10)  # every unit pressed and released

    def test_new_lines_and_tabs_are_real_keys_and_controls_are_refused(self):
        self.assertEqual(keyboard.text_events("a\r\nb\tc"), [
            (0, ord("a"), UNICODE), (0, ord("a"), UNICODE | UP), (0x0D, 0, 0), (0x0D, 0, UP),
            (0, ord("b"), UNICODE), (0, ord("b"), UNICODE | UP), (0x09, 0, 0), (0x09, 0, UP),
            (0, ord("c"), UNICODE), (0, ord("c"), UNICODE | UP)])
        for bad in ("bell\x07", "x" * 1001, "\x9b"):
            with self.assertRaises(keyboard.InputError):
                keyboard.text_events(bad)

    def test_shortcuts_press_modifiers_first_and_release_them_last(self):
        self.assertEqual(keyboard.plan_keyboard(key="c", modifiers=["ctrl"]),
                         [(0x11, 0, 0), (0x43, 0, 0), (0x43, 0, UP), (0x11, 0, UP)])
        self.assertEqual(keyboard.plan_keyboard(key="d", modifiers="win"),
                         [(0x5B, 0, EXT), (0x44, 0, 0), (0x44, 0, UP), (0x5B, 0, EXT | UP)])
        self.assertEqual(keyboard.plan_keyboard(key="F4", modifiers=["Alt"])[1], (0x73, 0, 0))
        self.assertEqual(keyboard.plan_keyboard(key="Escape", modifiers=["shift", "ctrl"])[:3],
                         [(0x11, 0, 0), (0x10, 0, 0), (0x1B, 0, 0)])
        self.assertEqual(keyboard.plan_keyboard(key="left", repeat=3).count((0x25, 0, EXT)), 3)
        self.assertEqual(keyboard.plan_keyboard(key="f24")[0], (0x87, 0, 0))
        self.assertEqual(keyboard.plan_keyboard(key="=", modifiers=["ctrl"])[1], (0xBB, 0, 0))
        self.assertEqual(keyboard.plan_keyboard(key="Page Up")[0], (0x21, 0, EXT))

    def test_old_key_names_keep_working(self):
        for name, code in (("ENTER", 0x0D), ("BACKSPACE", 0x08), ("SPACE", 0x20), ("ESC", 0x1B), ("WIN", 0x5B), ("TAB", 0x09)):
            self.assertEqual(keyboard.plan_keyboard(key=name)[0][0], code)
        events = keyboard.plan_keyboard(text="ok", key="ENTER")
        self.assertEqual(events[0][0], 0x0D)  # key first, then the text, as before
        self.assertEqual(events[-1], (0, ord("k"), UNICODE | UP))

    def test_validation(self):
        for arguments in ({"key": "c", "modifiers": ["cmd"]}, {"key": "c", "modifiers": ["hyper"]}, {"modifiers": ["ctrl"]},
                          {"key": "notakey"}, {}, {"key": "a", "repeat": 0}, {"key": "a", "repeat": 21},
                          {"key": "a", "repeat": True}, {"key": "a", "modifiers": ["ctrl"] * 5}, {"key": "€"}):
            with self.assertRaises(keyboard.InputError, msg=arguments):
                keyboard.plan_keyboard(**arguments)
        with self.assertRaisesRegex(keyboard.InputError, "ctrl"):
            keyboard.parse_modifiers(["cmd"])

    def test_scan_codes_come_from_the_layout(self):
        events = keyboard.plan_keyboard(key="c", modifiers=["ctrl"], scan=lambda code: code + 1)
        self.assertEqual(events[0], (0x11, 0x12, 0))


class AdapterTests(unittest.TestCase):
    def test_one_sendinput_call_with_the_right_structure_size(self):
        user32 = FakeUser32()
        sent = keyboard.send_keyboard(text="hi", key="c", modifiers=["ctrl"], keyboard=keyboard.WindowsKeyboard(user32))
        self.assertEqual(sent, 8)
        self.assertEqual(len(user32.batches), 1)
        self.assertEqual(user32.size, ctypes.sizeof(keyboard.INPUT))
        self.assertEqual(user32.batches[0][0], (0x11, 0x111, 0))  # MapVirtualKeyW scan code

    def test_layout_characters_without_shift_can_be_keys(self):
        user32 = FakeUser32(layout={"é": 0x0032, "!": 0x0131, "@": 0x0632})
        adapter = keyboard.WindowsKeyboard(user32)
        self.assertEqual(adapter.layout_key("é"), 0x32)
        self.assertIsNone(adapter.layout_key("!"))   # needs Shift
        self.assertIsNone(adapter.layout_key("@"))   # needs AltGr
        self.assertIsNone(adapter.layout_key("€"))   # not on this layout
        keyboard.send_keyboard(key="é", modifiers=["ctrl"], keyboard=adapter)
        self.assertEqual(user32.batches[0][1][0], 0x32)

    def test_blocked_input_releases_held_modifiers(self):
        user32 = FakeUser32(accept=2)  # ctrl down and C down got through, then UIPI stopped it
        with self.assertRaises(keyboard.InputBlocked):
            keyboard.send_keyboard(key="c", modifiers=["ctrl", "shift"], keyboard=keyboard.WindowsKeyboard(user32))
        release = user32.batches[1]
        self.assertEqual([(vk, flags) for vk, scan, flags in release], [(0x10, UP), (0x11, UP)])

    def test_refuses_off_windows(self):
        with patch.object(keyboard.os, "name", "posix"):
            with self.assertRaises(keyboard.InputBlocked):
                keyboard.WindowsKeyboard()


class KeyboardEndpointTests(unittest.TestCase):
    def setUp(self):
        self.user32 = FakeUser32()
        self.patches = [patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent, "require_windows"),
                        patch.object(agent, "send_keyboard",
                                     lambda text, key, modifiers, repeat=1: keyboard.send_keyboard(
                                         text, key, modifiers, repeat, keyboard=keyboard.WindowsKeyboard(self.user32)))]
        for item in self.patches:
            item.start()
        self.client = TestClient(agent.app)

    def tearDown(self):
        self.client.close()
        for item in reversed(self.patches):
            item.stop()

    def test_old_query_parameters(self):
        response = self.client.post("/api/input/keyboard?text=ok&key=ENTER", headers=AUTH)
        self.assertEqual(response.json(), {"status": "sent", "events": 6})
        self.assertEqual(self.user32.batches[0][0], (0x0D, 0x10D, 0))
        self.assertEqual(self.client.post("/api/input/keyboard?key=NOPE", headers=AUTH).status_code, 422)
        self.assertEqual(self.client.post("/api/input/keyboard?text=" + "x" * 1001, headers=AUTH).status_code, 422)
        self.assertEqual(self.client.post("/api/input/keyboard?key=c&modifiers=ctrl,shift", headers=AUTH).status_code, 200)

    def test_json_shortcuts_and_unicode(self):
        self.assertEqual(self.client.post("/api/input/keyboard", headers=AUTH, json={"key": "c", "modifiers": ["ctrl"]}).json()["events"], 4)
        self.assertEqual(self.client.post("/api/input/keyboard", headers=AUTH, json={"text": "Bună ziua 👋"}).status_code, 200)
        self.assertEqual(self.client.post("/api/input/keyboard", headers=AUTH, json={"key": "c", "modifiers": ["cmd"]}).status_code, 422)
        self.assertEqual(self.client.post("/api/input/keyboard", headers=AUTH, json={"key": "c", "shout": True}).status_code, 422)
        self.assertEqual(self.client.post("/api/input/keyboard", headers=AUTH, json={"key": "left", "repeat": 50}).status_code, 422)

    def test_blocked_input_is_503(self):
        self.user32.accept = 0
        response = self.client.post("/api/input/keyboard", headers=AUTH, json={"text": "x"})
        self.assertEqual(response.status_code, 503)
        self.assertIn("administrator", response.json()["detail"])

    def test_websocket_keyboard_messages(self):
        with patch.object(agent.os, "name", "nt"):
            with self.client.websocket_connect("/ws/input", headers=AUTH) as websocket:
                websocket.send_text(json.dumps({"key": "tab", "modifiers": ["alt"]}))
                websocket.send_text(json.dumps({"text": "ă"}))
                websocket.send_text(json.dumps({"key": "nope"}))  # ignored, the socket stays open
                websocket.send_text(json.dumps({"text": "!"}))
        self.assertEqual(self.user32.batches[0][:2], [(0x12, 0x112, 0), (0x09, 0x109, 0)])
        self.assertEqual(self.user32.batches[1][0], (0, ord("ă"), UNICODE))
        self.assertEqual(self.user32.batches[2][0], (0, ord("!"), UNICODE))


if __name__ == "__main__":
    unittest.main()
