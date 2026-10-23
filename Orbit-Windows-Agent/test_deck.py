"""The button deck: validation, storage, runs, Start menu shortcuts and OBS.

Every Windows call is mocked: nothing presses keys, opens programs, sleeps or shuts down the
machine running the tests. OBS is a small obs-websocket 5 server inside the test.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, call, patch
import uuid

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_deck as deck
import orbit_icons
import orbit_input
import orbit_settings

TOKEN = "deck-test-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
APP_ID = "0123456789abcdef0123456789abcdef01234567"
OBS_PASSWORD = "S3cret-OBS-Password-for-tests"


def button(title="Mute Discord", action=None, **extra):
    value = {"id": str(uuid.uuid4()).upper(), "title": title, "symbol": "mic.slash.fill", "color": "#ff453a",
             "action": action or {"type": "hotkey", "keys": ["ctrl", "shift", "m"]}}
    value.update(extra)
    return value


def make_app(folder, *, windows=True, perform=None, type_text=None, apps=None, obs=None, open_target=None,
             runner=None, clock=None):
    """A FastAPI app with only the deck router, its own settings file and mocked Windows work."""
    store = orbit_settings.SettingsStore(Path(folder) / "settings.json")
    flags = {"boot": False, "windows": windows}

    def verify(authorization: str = Header(None)):
        if authorization != f"Bearer {TOKEN}":
            raise HTTPException(401, "Invalid Orbit token")

    def secure(request: Request):
        if request.url.scheme != "https":
            raise HTTPException(426, "This needs Orbit's encrypted connection.")

    def require_windows():
        if not flags["windows"]:
            raise HTTPException(501, "PC controls require Windows")

    perform = perform or MagicMock(side_effect=lambda name: {"status": "sent", "executed": name})
    type_text = type_text or MagicMock()
    apps = apps or MagicMock()
    obs = obs or MagicMock()
    opener = open_target or MagicMock()
    sleeper = MagicMock()
    runner = runner or deck.DeckRunner(perform_action=perform, type_text=type_text, apps=apps, obs=obs,
                                       open_target=opener, sleep=sleeper)
    router = deck.create_deck_router(verify, secure, require_windows=require_windows, perform_action=perform,
                                     type_text=type_text, boot_mode=lambda: flags["boot"],
                                     store=deck.DeckStore(lambda: store, clock=clock), apps=apps, obs=obs,
                                     runner=runner)
    application = FastAPI()
    application.include_router(router)
    client = TestClient(application, base_url="https://testserver")
    return SimpleNamespace(client=client, store=store, flags=flags, perform=perform, type_text=type_text,
                           apps=apps, obs=obs, open=opener, sleep=sleeper, app=application)


class TempFolderTestCase(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self._temporary.cleanup)
        self.folder = Path(self._temporary.name)


# MARK: - Validation

class ActionValidationTests(unittest.TestCase):
    def assertRefused(self, action, message=None, **options):
        with self.assertRaises(deck.DeckError) as refused:
            deck.validate_action(action, **options)
        if message:
            self.assertIn(message, str(refused.exception))
        return str(refused.exception)

    def test_every_action_type_is_accepted_and_normalized(self):
        cases = [
            ({"type": "hotkey", "keys": ["M", "Shift", "CTRL"]}, {"type": "hotkey", "keys": ["shift", "ctrl", "m"]}),
            ({"type": "text", "text": "gg wp\nnext"}, {"type": "text", "text": "gg wp\nnext"}),
            ({"type": "openUrl", "url": "steam://rungameid/620"}, {"type": "openUrl", "url": "steam://rungameid/620"}),
            ({"type": "launch", "appID": APP_ID.upper(), "name": " Spotify "},
             {"type": "launch", "appID": APP_ID, "name": "Spotify"}),
            ({"type": "system", "name": "lock"}, {"type": "system", "name": "lock"}),
            ({"type": "media", "name": "playpause"}, {"type": "media", "name": "playpause"}),
            ({"type": "obs", "request": "ToggleRecord", "data": {"ignored": True}},
             {"type": "obs", "request": "ToggleRecord", "data": {}}),
            ({"type": "obs", "request": "SetCurrentProgramScene", "data": {"sceneName": "BRB  2", "other": 1}},
             {"type": "obs", "request": "SetCurrentProgramScene", "data": {"sceneName": "BRB  2"}}),
            ({"type": "sequence", "steps": [{"type": "media", "name": "mute"}, {"type": "system", "name": "lock"}]},
             {"type": "sequence", "steps": [{"type": "media", "name": "mute"}, {"type": "system", "name": "lock"}],
              "delayMs": deck.DEFAULT_DELAY_MS}),
        ]
        for action, expected in cases:
            with self.subTest(type=action["type"]):
                self.assertEqual(deck.validate_action(action), expected)

    def test_unknown_or_missing_types_are_refused(self):
        for action in (None, [], "hotkey", {}, {"type": None}, {"type": ["hotkey"]}, {"type": 3}):
            with self.subTest(action=action):
                self.assertRefused(action)
        self.assertRefused({"type": "teleport"}, "Update Orbit PC Companion")

    def test_hotkeys_use_the_allowlist_and_refuse_ctrl_alt_delete(self):
        for keys, message in ((["ctrl", "alt", "delete"], "Ctrl+Alt+Delete"),
                              (["Delete", "ALT", "Ctrl"], "Ctrl+Alt+Delete"),
                              (["ctrl", "warp"], "is not a key"), (["a", "b", "c", "d", "e", "f"], "at most 5"),
                              (["a", "A"], "only once"), ([], "at least one key"), ("ctrl+m", "list of key names"),
                              (None, "list of key names"), ([1], "key name")):
            with self.subTest(keys=keys):
                self.assertRefused({"type": "hotkey", "keys": keys}, message)
        # Ctrl+Shift+Esc (Task Manager) and Win+Alt+G are fine.
        self.assertEqual(deck.validate_action({"type": "hotkey", "keys": ["ctrl", "shift", "esc"]})["keys"],
                         ["ctrl", "shift", "esc"])
        self.assertEqual(deck.validate_action({"type": "hotkey", "keys": ["win", "alt", "g"]})["keys"], ["win", "alt", "g"])

    def test_text_limits(self):
        self.assertEqual(deck.validate_action({"type": "text", "text": "x" * 1000})["text"], "x" * 1000)
        self.assertEqual(deck.validate_action({"type": "text", "text": "a\tb\r\nc"})["text"], "a\tb\r\nc")
        for text, message in (("x" * 1001, "at most 1,000"), ("", "Enter the text"), (None, "Enter the text"),
                              (42, "Enter the text"), ("bad\x00", "control characters"), ("esc\x1b", "control characters"),
                              ("lone \ud800", "control characters")):
            with self.subTest(text=repr(text)[:30]):
                self.assertRefused({"type": "text", "text": text}, message)

    def test_url_schemes(self):
        accepted = ("https://example.com/path?q=1", "http://192.168.1.20:8080/", "steam://rungameid/620",
                    "steam://open/bigpicture", "com.epicgames.launcher://apps/Fortnite?action=launch&silent=true",
                    "spotify:track:4uLU6hMCjMI75M1A2tKUQC", "discord://-/channels/@me", "ms-settings:display",
                    "MS-SETTINGS:sound")
        for url in accepted:
            with self.subTest(url=url):
                self.assertEqual(deck.validate_action({"type": "openUrl", "url": url})["url"], url)
        refused = ("file:///C:/Windows/System32/calc.exe", "javascript:alert(1)", "ms-msdt:/id PCWDiagnostic",
                   "search-ms:query=x", "shell:startup", "mailto:a@example.com", "C:\\Windows\\notepad.exe",
                   "calc.exe", "ftp://example.com/", "vbscript:msgbox", "ms-settings-other:x", "steamx://run/1",
                   "", None, 5)
        for url in refused:
            with self.subTest(url=url):
                self.assertRefused({"type": "openUrl", "url": url})
        self.assertIn("steam://", self.assertRefused({"type": "openUrl", "url": "file:///C:/x"}))
        for url, message in (("https://user:pass@example.com/", "user name or password"),
                             ('steam://run/620//"-dangerous"', "percent-encoded"),
                             ("spotify:track:a b", "spaces"),
                             ("https://example.com/" + "a" * 5000, "4,096")):
            with self.subTest(url=url[:40]):
                self.assertRefused({"type": "openUrl", "url": url}, message)

    def test_launch_needs_a_start_menu_id(self):
        for app_id in (None, "", "123", "C:\\Program Files\\x.exe", APP_ID + "0", "g" * 40, 7):
            with self.subTest(app_id=app_id):
                self.assertRefused({"type": "launch", "appID": app_id}, "Start menu")
        self.assertRefused({"type": "launch", "appID": APP_ID, "name": ""}, "can't be empty")

    def test_system_actions_are_the_agent_actions(self):
        for name in sorted(deck.SYSTEM_ACTIONS):
            with self.subTest(name=name):
                self.assertEqual(deck.validate_action({"type": "system", "name": name}), {"type": "system", "name": name})
        for name in ("format_c", "", None, ["lock"], "LOCK", "hibernate"):
            with self.subTest(name=name):
                self.assertRefused({"type": "system", "name": name}, "Choose a PC action")

    def test_media_names(self):
        for name in deck.MEDIA_ACTIONS:
            self.assertEqual(deck.validate_action({"type": "media", "name": name})["name"], name)
        for name in ("stop", "", None, {"x": 1}):
            with self.subTest(name=name):
                self.assertRefused({"type": "media", "name": name}, "Media buttons")

    def test_obs_requests_are_allowlisted_and_their_data_filtered(self):
        for request in deck.OBS_ACTIONS:
            data = {"sceneName": "Gaming"} if request == "SetCurrentProgramScene" else \
                {"inputName": "Mic/Aux"} if request == "ToggleInputMute" else {}
            with self.subTest(request=request):
                self.assertEqual(deck.validate_action({"type": "obs", "request": request, "data": data})["request"], request)
        for request in ("StopStream", "CallVendorRequest", "SetInputSettings", "Sleep", "GetSceneList", "", None, ["ToggleRecord"]):
            with self.subTest(request=request):
                self.assertRefused({"type": "obs", "request": request}, "OBS buttons")
        self.assertRefused({"type": "obs", "request": "SetCurrentProgramScene"}, "Choose the OBS scene")
        self.assertRefused({"type": "obs", "request": "SetCurrentProgramScene", "data": {"sceneName": "  "}}, "Choose the OBS scene")
        self.assertRefused({"type": "obs", "request": "SetCurrentProgramScene", "data": {"sceneName": "a\nb"}}, "not allowed")
        self.assertRefused({"type": "obs", "request": "SetCurrentProgramScene", "data": {"sceneUuid": "nope"}}, "not a valid OBS id")
        self.assertRefused({"type": "obs", "request": "ToggleInputMute", "data": {}}, "audio source")
        self.assertRefused({"type": "obs", "request": "ToggleRecord", "data": "x"}, "not valid")
        scene_id = str(uuid.uuid4()).upper()
        self.assertEqual(deck.validate_action({"type": "obs", "request": "SetCurrentProgramScene",
                                               "data": {"sceneUuid": scene_id, "sceneName": "BRB"}})["data"],
                         {"sceneUuid": scene_id.lower(), "sceneName": "BRB"})

    def test_sequences(self):
        step = {"type": "media", "name": "next"}
        self.assertEqual(len(deck.validate_action({"type": "sequence", "steps": [step] * 8})["steps"]), 8)
        self.assertRefused({"type": "sequence", "steps": [step] * 9}, "at most 8 steps")
        self.assertRefused({"type": "sequence", "steps": []}, "at least one step")
        self.assertRefused({"type": "sequence"}, "at least one step")
        self.assertRefused({"type": "sequence", "steps": [step, {"type": "sequence", "steps": [step]}]},
                           "can't contain another sequence")
        self.assertRefused({"type": "sequence", "steps": [step]}, "can't contain another sequence", inside_sequence=True)
        self.assertIn("Step 2:", self.assertRefused({"type": "sequence", "steps": [step, {"type": "hotkey", "keys": ["warp"]}]}))
        self.assertRefused({"type": "sequence", "steps": [{"type": "system", "name": "sleep"}, step]}, "last step")
        self.assertEqual(deck.validate_action({"type": "sequence", "steps": [step, {"type": "system", "name": "sleep"}]})["steps"][-1],
                         {"type": "system", "name": "sleep"})
        # The same range as the apps' editor (DESIGN F4: 0-5000 ms, 150 when left out).
        self.assertEqual((deck.MAX_DELAY_MS, deck.DEFAULT_DELAY_MS), (5000, 150))
        for delay, expected in ((0, 0), (3000, 3000), (5000, 5000), (4999.6, 5000), (150.4, 150), (None, 150)):
            self.assertEqual(deck.validate_action({"type": "sequence", "steps": [step], "delayMs": delay})["delayMs"], expected)
        # A 400-digit integer (json.loads gives an int) is refused, not an OverflowError.
        for delay in (-1, 5001, 5000.5, True, "100", float("nan"), float("inf"), -float("inf"), 10 ** 400, -10 ** 400):
            with self.subTest(delay=delay):
                self.assertRefused({"type": "sequence", "steps": [step], "delayMs": delay}, "pause between steps")

    def test_power_detection(self):
        for name in ("sleep", "shutdown", "restart"):
            self.assertTrue(deck.is_power_action({"type": "system", "name": name}))
        self.assertFalse(deck.is_power_action({"type": "system", "name": "lock"}))
        self.assertTrue(deck.is_power_action({"type": "sequence", "steps": [{"type": "system", "name": "restart"}]}))
        self.assertFalse(deck.is_power_action({"type": "hotkey", "keys": ["win", "l"]}))


class ButtonValidationTests(unittest.TestCase):
    def test_a_valid_button_is_normalized(self):
        value = button()
        saved = deck.validate_button(value)
        self.assertEqual(saved, {"id": value["id"], "title": "Mute Discord", "symbol": "mic.slash.fill",
                                 "color": "#FF453A", "confirm": False,
                                 "action": {"type": "hotkey", "keys": ["ctrl", "shift", "m"]}})

    def test_missing_id_symbol_and_color_get_defaults(self):
        saved = deck.validate_button({"title": "Lock", "action": {"type": "system", "name": "lock"}})
        self.assertRegex(saved["id"], r"^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$")
        self.assertEqual((saved["symbol"], saved["color"], saved["confirm"]), (deck.DEFAULT_SYMBOL, deck.DEFAULT_COLOR, False))
        with self.assertRaises(deck.DeckError):
            deck.validate_button({"title": "Lock", "action": {"type": "system", "name": "lock"}}, assign_id=False)

    def test_field_limits(self):
        cases = (({"id": "../etc"}, "UUIDs"), ({"id": "x" * 65}, "UUIDs"), ({"id": 5}, "UUIDs"),
                 ({"title": ""}, "can't be empty"), ({"title": " \n\t "}, "can't be empty"),
                 ({"title": "x" * 41}, "at most 40"), ({"title": None}, "must be text"),
                 ({"title": "bad \ud800"}, "not valid text"),
                 ({"symbol": "Mic.Slash"}, "SF Symbol"), ({"symbol": "../x"}, "SF Symbol"), ({"symbol": "mic slash"}, "SF Symbol"),
                 ({"symbol": "a" * 65}, "SF Symbol"), ({"symbol": 3}, "SF Symbol"),
                 ({"color": "red"}, "hex color"), ({"color": "#12345"}, "hex color"), ({"color": "#GGGGGG"}, "hex color"),
                 ({"confirm": "yes"}, "true or false"), ({"action": "lock"}, "needs an action"))
        for change, message in cases:
            with self.subTest(change=change):
                with self.assertRaises(deck.DeckError) as refused:
                    deck.validate_button(button(**change))
                self.assertIn(message, str(refused.exception))
        self.assertEqual(deck.validate_button(button(title="x" * 40))["title"], "x" * 40)
        self.assertEqual(deck.validate_button(button(title="  Two\nlines\u202e  "))["title"], "Two lines")
        self.assertEqual(deck.validate_button(button(title="👨‍👩‍👧 Family"))["title"], "👨‍👩‍👧 Family")
        self.assertEqual(deck.validate_button(button(color="#0a84ff80"))["color"], "#0A84FF80")

    def test_power_buttons_must_ask_for_confirmation(self):
        for name in ("sleep", "shutdown", "restart"):
            with self.subTest(name=name):
                with self.assertRaises(deck.DeckError) as refused:
                    deck.validate_button(button(action={"type": "system", "name": name}))
                self.assertIn("confirmation", str(refused.exception))
                self.assertTrue(deck.validate_button(button(action={"type": "system", "name": name}, confirm=True))["confirm"])
        sequence = {"type": "sequence", "steps": [{"type": "obs", "request": "StopRecord"}, {"type": "system", "name": "shutdown"}]}
        with self.assertRaises(deck.DeckError):
            deck.validate_button(button(action=sequence))
        self.assertTrue(deck.validate_button(button(action=sequence, confirm=True))["confirm"])

    def test_deck_limits(self):
        self.assertEqual(len(deck.validate_buttons([button(title=f"B{i}") for i in range(64)])), 64)
        with self.assertRaises(deck.DeckError) as refused:
            deck.validate_buttons([button() for _ in range(65)])
        self.assertIn("at most 64 buttons", str(refused.exception))
        same = button()
        with self.assertRaises(deck.DeckError) as refused:
            deck.validate_buttons([same, dict(same, id=same["id"].lower(), title="Other")])
        self.assertIn("already uses the id", str(refused.exception))
        self.assertIn("Button 2 (\u201cOther\u201d)", str(refused.exception))
        with self.assertRaises(deck.DeckError) as refused:
            deck.validate_buttons([button(), button(title="Broken", action={"type": "hotkey", "keys": ["warp"]})])
        self.assertTrue(str(refused.exception).startswith("Button 2 (\u201cBroken\u201d): "))
        with self.assertRaises(deck.DeckError):
            deck.validate_buttons({"buttons": []})
        huge = [button(title=f"T{i}", action={"type": "sequence", "steps": [{"type": "text", "text": "\u4e00" * 1000}] * 8})
                for i in range(30)]
        with self.assertRaises(deck.DeckError) as refused:
            deck.validate_buttons(huge)
        self.assertIn("too large", str(refused.exception))


# MARK: - Routes

class DeckRouteTests(TempFolderTestCase):
    def setUp(self):
        super().setUp()
        self.ctx = make_app(self.folder)
        self.addCleanup(self.ctx.client.close)

    def put(self, buttons, **extra):
        return self.ctx.client.put("/api/deck", json={"buttons": buttons, **extra}, headers=AUTH)

    def test_routes_need_the_token_and_https(self):
        http = TestClient(self.ctx.app)
        self.addCleanup(http.close)
        routes = (("get", "/api/deck"), ("put", "/api/deck"), ("post", "/api/deck/run"),
                  ("post", "/api/deck/buttons/ABC/run"), ("get", "/api/deck/apps"), ("get", "/api/deck/obs"))
        for method, path in routes:
            with self.subTest(path=path, method=method):
                self.assertEqual(getattr(self.ctx.client, method)(path).status_code, 401)
                self.assertEqual(getattr(http, method)(path, headers=AUTH).status_code, 426)
        self.ctx.perform.assert_not_called()

    def test_an_empty_deck(self):
        response = self.ctx.client.get("/api/deck", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"buttons": [], "updatedAt": deck.NEVER_SAVED, "maxButtons": 64})
        self.assertEqual(response.headers["cache-control"], "no-store")

    def test_saving_and_reading_the_deck(self):
        first, second = button(), button(title="Lock", action={"type": "system", "name": "lock"}, symbol=None, color=None)
        response = self.put([first, second])
        self.assertEqual(response.status_code, 200, response.text)
        saved = response.json()
        self.assertEqual([b["id"] for b in saved["buttons"]], [first["id"], second["id"]])
        self.assertEqual(saved["buttons"][1]["symbol"], deck.DEFAULT_SYMBOL)
        self.assertRegex(saved["updatedAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual(self.ctx.client.get("/api/deck", headers=AUTH).json(), saved)
        on_disk = json.loads((self.folder / "settings.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["deck"]["buttons"], saved["buttons"])
        # Every device sees the same deck; an empty list clears it.
        self.assertEqual(self.put([]).json()["buttons"], [])

    def test_invalid_decks_are_refused_and_nothing_is_saved(self):
        self.put([button(title="Keep")])
        for body, status, message in (
                ({"buttons": [button(action={"type": "system", "name": "shutdown"})]}, 422, "confirmation"),
                ({"buttons": [button() for _ in range(65)]}, 422, "at most 64"),
                ({"buttons": "nope"}, 422, "list"), ({}, 422, "{\"buttons\""), ([], 422, "{\"buttons\""),
                ({"buttons": [], "baseUpdatedAt": 5}, 422, "baseUpdatedAt")):
            with self.subTest(body=str(body)[:60]):
                response = self.ctx.client.put("/api/deck", json=body, headers=AUTH)
                self.assertEqual(response.status_code, status)
                self.assertIn(message, response.json()["detail"])
        self.assertEqual([b["title"] for b in self.ctx.client.get("/api/deck", headers=AUTH).json()["buttons"]], ["Keep"])

    def test_bodies_that_are_not_json_or_too_large(self):
        for content in (b"", b"not json", b"\xff\xfe", b"[" * 100000 + b"]" * 100000):
            with self.subTest(content=content[:10]):
                response = self.ctx.client.put("/api/deck", content=content, headers={**AUTH, "Content-Type": "application/json"})
                self.assertEqual(response.status_code, 422)
        big = json.dumps({"buttons": [], "padding": "x" * (deck.MAX_BODY_BYTES + 1)})
        self.assertEqual(self.ctx.client.put("/api/deck", content=big, headers=AUTH).status_code, 413)
        nan = '{"action": {"type": "sequence", "steps": [{"type": "media", "name": "mute"}], "delayMs": NaN}}'
        response = self.ctx.client.post("/api/deck/run", content=nan, headers=AUTH)
        self.assertEqual(response.status_code, 422)
        self.assertIn("pause between steps", response.json()["detail"])
        huge_sequence = '{"type": "sequence", "steps": [{"type": "media", "name": "mute"}], "delayMs": ' + "9" * 400 + "}"
        for method, path, content in (
                ("post", "/api/deck/run", '{"action": ' + huge_sequence + "}"),
                ("put", "/api/deck", '{"buttons": [{"title": "Huge", "action": ' + huge_sequence + "}]}")):
            with self.subTest(path=path):
                response = getattr(self.ctx.client, method)(path, content=content, headers=AUTH)
                self.assertEqual(response.status_code, 422, response.text)
                self.assertIn("pause between steps", response.json()["detail"])
        self.ctx.perform.assert_not_called()

    def test_a_change_from_another_device_is_detected(self):
        saved = self.put([button()]).json()
        newer = self.put([button(title="Other device")], baseUpdatedAt=saved["updatedAt"])
        self.assertEqual(newer.status_code, 200)
        stale = self.put([button(title="Mine")], baseUpdatedAt=saved["updatedAt"])
        self.assertEqual(stale.status_code, 409)
        self.assertIn("changed on another device", stale.json()["detail"])
        self.assertEqual(self.ctx.client.get("/api/deck", headers=AUTH).json()["buttons"][0]["title"], "Other device")

    def test_updated_at_grows_with_every_save(self):
        from datetime import datetime, timezone
        fixed = datetime(2026, 10, 24, 12, 0, 0, tzinfo=timezone.utc)
        ctx = make_app(self.folder / "clock", clock=lambda: fixed)
        self.addCleanup(ctx.client.close)
        stamps = [ctx.client.put("/api/deck", json={"buttons": []}, headers=AUTH).json()["updatedAt"] for _ in range(3)]
        self.assertEqual(stamps, ["2026-10-24T12:00:00Z", "2026-10-24T12:00:01Z", "2026-10-24T12:00:02Z"])

    def test_a_hand_edited_deck_keeps_only_valid_buttons(self):
        good = deck.validate_button(button(title="Good"))
        self.ctx.store.replace("deck", {"buttons": [good, {"id": "BAD", "title": "", "action": {}},
                                                    dict(good, title="Duplicate"), "junk",
                                                    {"title": "No id", "action": {"type": "system", "name": "lock"}},
                                                    dict(deck.validate_button(button(title="Power")),
                                                         action={"type": "system", "name": "shutdown"}, confirm=False)],
                                        "updatedAt": "yesterday"})
        with self.assertLogs("orbit.deck", "WARNING"):
            payload = self.ctx.client.get("/api/deck", headers=AUTH).json()
        self.assertEqual([b["title"] for b in payload["buttons"]], ["Good"])
        self.assertEqual(payload["updatedAt"], deck.NEVER_SAVED)
        with self.assertLogs("orbit.deck", "WARNING"):
            response = self.ctx.client.post("/api/deck/buttons/BAD/run", headers=AUTH)
        self.assertEqual(response.status_code, 404)
        self.ctx.perform.assert_not_called()

    def test_a_hand_edited_updated_at_never_blocks_saving(self):
        from datetime import datetime, timezone
        fixed = datetime(2026, 10, 24, 12, 0, 0, tzinfo=timezone.utc)
        for stamp, shown in (("2026-13-45T99:99:99Z", deck.NEVER_SAVED), ("0000-01-01T00:00:00Z", deck.NEVER_SAVED),
                             ("9999-12-31T23:59:59Z", "9999-12-31T23:59:59Z")):
            with self.subTest(stamp=stamp):
                ctx = make_app(self.folder / stamp.replace(":", "-"), clock=lambda: fixed)
                self.addCleanup(ctx.client.close)
                ctx.store.replace("deck", {"buttons": [], "updatedAt": stamp})
                self.assertEqual(ctx.client.get("/api/deck", headers=AUTH).json()["updatedAt"], shown)
                response = ctx.client.put("/api/deck", json={"buttons": [button()]}, headers=AUTH)
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()["updatedAt"], "2026-10-24T12:00:00Z")
                # The next save still gets a later time than this one.
                again = ctx.client.put("/api/deck", json={"buttons": [], "baseUpdatedAt": "2026-10-24T12:00:00Z"},
                                       headers=AUTH)
                self.assertEqual(again.json()["updatedAt"], "2026-10-24T12:00:01Z")

    def test_running_a_saved_button(self):
        saved = self.put([button()]).json()["buttons"][0]
        with patch.object(deck.orbit_input, "press_chord", return_value=["ctrl", "shift", "m"]) as press:
            response = self.ctx.client.post(f"/api/deck/buttons/{saved['id']}/run", headers=AUTH)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json(), {"status": "done", "detail": "Pressed Ctrl+Shift+M"})
            press.assert_called_once_with(["ctrl", "shift", "m"])
            # Ids match whatever case the device sends; an optional body is ignored.
            self.assertEqual(self.ctx.client.post(f"/api/deck/buttons/{saved['id'].lower()}/run", json={}, headers=AUTH).status_code, 200)
        self.assertEqual(self.ctx.client.post("/api/deck/buttons/missing-button/run", headers=AUTH).status_code, 404)
        self.assertEqual(self.ctx.client.post("/api/deck/buttons/..%2F..%2Fetc/run", headers=AUTH).status_code, 404)

    def test_power_buttons_run_only_with_confirmation(self):
        saved = self.put([button(title="Sleep", action={"type": "system", "name": "sleep"}, confirm=True)]).json()["buttons"][0]
        response = self.ctx.client.post(f"/api/deck/buttons/{saved['id']}/run", headers=AUTH)
        self.assertEqual(response.json(), {"status": "done", "detail": "The PC is going to sleep"})
        self.ctx.perform.assert_called_once_with("sleep")
        self.ctx.perform.reset_mock()
        for name in ("sleep", "shutdown", "restart"):
            with self.subTest(name=name):
                refused = self.ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": name}}, headers=AUTH)
                self.assertEqual(refused.status_code, 428)
                self.assertIn("Confirm it", refused.json()["detail"])
                self.assertEqual(self.ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": name},
                                                                             "confirm": "yes"}, headers=AUTH).status_code, 422)
        self.ctx.perform.assert_not_called()
        confirmed = self.ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": "restart"}, "confirm": True},
                                         headers=AUTH)
        self.assertEqual(confirmed.status_code, 200)
        self.ctx.perform.assert_called_once_with("restart")

    def test_one_off_runs_validate_first(self):
        response = self.ctx.client.post("/api/deck/run", json={"action": {"type": "hotkey", "keys": ["ctrl", "alt", "delete"]}},
                                        headers=AUTH)
        self.assertEqual(response.status_code, 422)
        self.assertIn("Ctrl+Alt+Delete", response.json()["detail"])
        for body in ({}, {"action": None}, [], {"action": {"type": "openUrl", "url": "file:///C:/x"}}):
            with self.subTest(body=body):
                self.assertEqual(self.ctx.client.post("/api/deck/run", json=body, headers=AUTH).status_code, 422)
        self.ctx.perform.assert_not_called()
        self.ctx.open.assert_not_called()

    def test_off_windows_and_in_the_boot_instance(self):
        self.ctx.flags["windows"] = False
        for method, path, body in (("post", "/api/deck/run", {"action": {"type": "system", "name": "lock"}}),
                                   ("get", "/api/deck/apps", None), ("get", "/api/deck/obs", None)):
            with self.subTest(path=path):
                self.assertEqual(getattr(self.ctx.client, method)(path, headers=AUTH, **({"json": body} if body else {})).status_code, 501)
        # The deck itself is just data and works anywhere.
        self.assertEqual(self.ctx.client.get("/api/deck", headers=AUTH).status_code, 200)
        self.assertEqual(self.put([button()]).status_code, 200)
        self.ctx.flags.update(windows=True, boot=True)
        response = self.ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": "lock"}}, headers=AUTH)
        self.assertEqual(response.status_code, 409)
        self.assertIn("Sign in to Windows", response.json()["detail"])
        self.ctx.perform.assert_not_called()

    def test_too_many_buttons_at_once(self):
        inside, release = threading.Semaphore(0), threading.Event()

        def slow(name):
            inside.release()
            release.wait(5)
            return {"status": "sent", "executed": name}
        ctx = make_app(self.folder / "busy", perform=MagicMock(side_effect=slow))
        self.addCleanup(ctx.client.close)
        results = []

        def run():
            client = TestClient(ctx.app, base_url="https://testserver")
            with client:
                results.append(client.post("/api/deck/run", json={"action": {"type": "system", "name": "lock"}}, headers=AUTH).status_code)
        workers = [threading.Thread(target=run) for _ in range(deck.MAX_CONCURRENT_RUNS)]
        for worker in workers:
            worker.start()
        for _ in workers:
            self.assertTrue(inside.acquire(timeout=5))
        busy = ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": "lock"}}, headers=AUTH)
        release.set()
        for worker in workers:
            worker.join(5)
        self.assertEqual(busy.status_code, 429)
        self.assertEqual(results, [200] * deck.MAX_CONCURRENT_RUNS)


    def test_a_launch_waiting_for_permission_frees_its_run_slot(self):
        answered = threading.Event()
        self.addCleanup(answered.set)
        apps = MagicMock()
        apps.find.return_value = deck.StartMenuApp(id=APP_ID, name="HWiNFO", path="C:\\Start Menu\\HWiNFO.lnk")
        perform = MagicMock(side_effect=lambda name: {"status": "sent", "executed": name})
        runner = deck.DeckRunner(perform_action=perform, type_text=MagicMock(), apps=apps, obs=MagicMock(),
                                 open_target=lambda target: answered.wait(5), sleep=MagicMock(), open_wait=0.05)
        ctx = make_app(self.folder / "uac", perform=perform, apps=apps, runner=runner)
        self.addCleanup(ctx.client.close)
        for _ in range(deck.MAX_CONCURRENT_RUNS):
            response = ctx.client.post("/api/deck/run", json={"action": {"type": "launch", "appID": APP_ID}}, headers=AUTH)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["detail"], "Windows is still opening HWiNFO. If the PC asks for permission, answer it there.")
        # Other buttons still run while the prompts wait on the PC.
        self.assertEqual(ctx.client.post("/api/deck/run", json={"action": {"type": "system", "name": "lock"}},
                                         headers=AUTH).status_code, 200)
        answered.set()
        for thread in [thread for thread in threading.enumerate() if thread.name == "orbit-deck-open"]:
            thread.join(5)


# MARK: - Running each kind of action

class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.perform = MagicMock(side_effect=lambda name: {"status": "sent", "executed": name})
        self.type_text = MagicMock()
        self.apps = MagicMock()
        self.obs = MagicMock()
        self.open = MagicMock()
        self.sleep = MagicMock()
        self.runner = deck.DeckRunner(perform_action=self.perform, type_text=self.type_text, apps=self.apps,
                                      obs=self.obs, open_target=self.open, sleep=self.sleep)

    def run_action(self, action, confirmed=False):
        return self.runner.run(deck.validate_action(action), confirmed=confirmed)

    def test_hotkeys_go_through_press_chord(self):
        with patch.object(deck.orbit_input, "press_chord", return_value=["alt", "f10"]) as press:
            self.assertEqual(self.run_action({"type": "hotkey", "keys": ["alt", "f10"]}), "Pressed Alt+F10")
        press.assert_called_once_with(["alt", "f10"])
        with patch.object(deck.orbit_input, "press_chord", side_effect=orbit_input.InputRejected("Windows did not accept the key presses.")):
            with self.assertRaises(HTTPException) as failed:
                self.run_action({"type": "hotkey", "keys": ["win", "alt", "g"]})
        self.assertEqual(failed.exception.status_code, 503)
        self.assertIn("did not accept", failed.exception.detail)

    def test_text_is_typed_with_enter_for_line_breaks(self):
        self.assertEqual(self.run_action({"type": "text", "text": "gg\nwp\r\n!"}), "Typed 8 characters")
        self.type_text.assert_called_once_with("gg\rwp\r!")
        self.type_text.side_effect = HTTPException(422, "Some characters are not available in the PC keyboard layout")
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "text", "text": "ț"})
        self.assertEqual(failed.exception.status_code, 422)

    def test_links_open_with_the_default_handler(self):
        self.assertEqual(self.run_action({"type": "openUrl", "url": "https://www.twitch.tv/directory?x=1"}),
                         "Opened www.twitch.tv/directory")
        self.assertEqual(self.run_action({"type": "openUrl", "url": "steam://rungameid/620"}), "Opened steam://rungameid/620")
        self.assertEqual(self.open.call_args_list, [call("https://www.twitch.tv/directory?x=1"), call("steam://rungameid/620")])
        for url, code, message in (("steam://rungameid/620", 31, "No app on the PC opens steam: links. Install Steam"),
                                   ("com.epicgames.launcher://apps/x", 2, "Install the Epic Games Launcher"),
                                   ("https://example.com", 31, "no default web browser"),
                                   ("https://example.com", 5, "could not open this link in the default browser"),
                                   ("spotify:track:1", 26, "could not open this link with Spotify")):
            with self.subTest(url=url, code=code):
                self.open.side_effect = deck.ShellOpenError(code)
                with self.assertRaises(HTTPException) as failed:
                    self.run_action({"type": "openUrl", "url": url})
                self.assertEqual(failed.exception.status_code, 503)
                self.assertIn(message, failed.exception.detail)

    def test_a_stored_link_is_checked_again_before_opening(self):
        with self.assertRaises(deck.DeckError):
            self.runner.run({"type": "openUrl", "url": "file:///C:/Windows/System32/calc.exe"}, confirmed=False)
        self.open.assert_not_called()

    def test_launch_opens_the_listed_shortcut(self):
        app = deck.StartMenuApp(id=APP_ID, name="Spotify", path="C:\\Users\\Gamer\\Start Menu\\Spotify.lnk")
        self.apps.find.return_value = app
        self.assertEqual(self.run_action({"type": "launch", "appID": APP_ID}), "Opened Spotify")
        self.apps.find.assert_called_once_with(APP_ID)
        self.open.assert_called_once_with(app.path)
        self.apps.find.return_value = None
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "launch", "appID": APP_ID, "name": "Spotify"})
        self.assertEqual(failed.exception.status_code, 404)
        self.assertIn("Spotify is no longer in the PC's Start menu", failed.exception.detail)
        self.apps.find.return_value = app
        self.open.side_effect = deck.ShellOpenError(2)
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "launch", "appID": APP_ID})
        self.assertIn("may have been uninstalled", failed.exception.detail)

    def test_an_open_that_waits_for_an_answer_on_the_pc_does_not_hold_the_run(self):
        # ShellExecuteW blocks while a UAC prompt (an app that needs administrator rights) waits.
        answered, opened = threading.Event(), []

        def waiting(target):
            opened.append(target)
            answered.wait(5)
            if target.startswith("steam:"):
                raise deck.ShellOpenError(5)  # Declined on the PC.
        runner = deck.DeckRunner(perform_action=self.perform, type_text=self.type_text, apps=self.apps, obs=self.obs,
                                 open_target=waiting, sleep=self.sleep, open_wait=0.05)
        app = deck.StartMenuApp(id=APP_ID, name="MSI Afterburner", path="C:\\ProgramData\\Start Menu\\MSI Afterburner.lnk")
        self.apps.find.return_value = app
        launch = deck.validate_action({"type": "launch", "appID": APP_ID})
        link = deck.validate_action({"type": "openUrl", "url": "steam://rungameid/620"})
        started = time.monotonic()
        with self.assertLogs("orbit.deck", "INFO") as logs:
            for _ in range(deck.MAX_PENDING_OPENS - 1):
                self.assertEqual(runner.run(launch, confirmed=False),
                                 "Windows is still opening MSI Afterburner. If the PC asks for permission, answer it there.")
            self.assertEqual(runner.run(link, confirmed=False),
                             "Windows is still opening the link. If the PC asks which app to use, answer it there.")
            self.assertLess(time.monotonic() - started, 3)
            # Every waiting open is a thread; past the limit a run is refused instead of starting more.
            with self.assertRaises(HTTPException) as busy:
                runner.run(launch, confirmed=False)
            self.assertEqual(busy.exception.status_code, 429)
            self.assertIn("Answer it on the PC", busy.exception.detail)
            self.assertEqual(len(opened), deck.MAX_PENDING_OPENS)
            answered.set()
            for thread in [thread for thread in threading.enumerate() if thread.name == "orbit-deck-open"]:
                thread.join(5)
        output = "\n".join(logs.output)
        self.assertIn("Opened MSI Afterburner after Windows asked on the PC", output)
        self.assertIn("Could not open a link after Windows asked on the PC", output)
        self.assertNotIn("rungameid", output)  # Links are never logged.
        # Once answered, opens are quick again and their errors come back as usual.
        self.assertEqual(runner.run(launch, confirmed=False), "Opened MSI Afterburner")
        with self.assertRaises(HTTPException) as failed:
            runner.run(link, confirmed=False)
        self.assertEqual(failed.exception.status_code, 503)

    def test_system_and_media_use_perform_action(self):
        for name in sorted(deck.SYSTEM_ACTIONS - deck.POWER_ACTIONS):
            self.assertEqual(self.run_action({"type": "system", "name": name}), deck.SYSTEM_DETAILS[name])
        for name, expected in deck.MEDIA_ACTIONS.items():
            self.assertEqual(self.run_action({"type": "media", "name": name}), deck.MEDIA_DETAILS[name])
            self.assertEqual(self.perform.call_args, call(expected))
        self.perform.side_effect = HTTPException(409, "Bring the detected game to the foreground before closing it")
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "system", "name": "kill_game"})
        self.assertEqual(failed.exception.status_code, 409)

    def test_power_actions_need_confirmation(self):
        for name in sorted(deck.POWER_ACTIONS):
            with self.subTest(name=name):
                with self.assertRaises(HTTPException) as failed:
                    self.run_action({"type": "system", "name": name})
                self.assertEqual(failed.exception.status_code, 428)
        self.perform.assert_not_called()
        self.run_action({"type": "system", "name": "shutdown"}, confirmed=True)
        self.perform.assert_called_once_with("shutdown")

    def test_obs_actions_go_to_the_controller(self):
        self.obs.run.return_value = "Recording started"
        self.assertEqual(self.run_action({"type": "obs", "request": "ToggleRecord"}), "Recording started")
        self.obs.run.assert_called_once_with("ToggleRecord", {})

    def test_sequences_run_in_order_with_pauses(self):
        order = []
        self.perform.side_effect = lambda name: order.append(name)
        self.open.side_effect = lambda url: order.append(url)
        self.sleep.side_effect = lambda seconds: order.append(("pause", seconds))
        detail = self.run_action({"type": "sequence", "delayMs": 250, "steps": [
            {"type": "media", "name": "mute"}, {"type": "openUrl", "url": "discord://-/channels/@me"},
            {"type": "system", "name": "sleep"}]}, confirmed=True)
        self.assertEqual(detail, "Ran 3 steps")
        self.assertEqual(order, ["mute", ("pause", 0.25), "discord://-/channels/@me", ("pause", 0.25), "sleep"])
        order.clear()
        self.run_action({"type": "sequence", "delayMs": 0, "steps": [{"type": "media", "name": "next"}] * 2})
        self.assertEqual(order, ["media_next", "media_next"])  # No pause at all with delayMs 0.
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "sequence", "steps": [{"type": "media", "name": "mute"}, {"type": "system", "name": "sleep"}]})
        self.assertEqual(failed.exception.status_code, 428)

    def test_a_failing_step_stops_the_sequence(self):
        self.perform.side_effect = [None, HTTPException(503, "Windows could not execute this action"), None]
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "sequence", "steps": [{"type": "media", "name": "mute"},
                                                           {"type": "system", "name": "lock"},
                                                           {"type": "media", "name": "next"}]})
        self.assertEqual(failed.exception.status_code, 503)
        self.assertEqual(failed.exception.detail, "Step 2 of 3 didn't work: Windows could not execute this action. "
                                                  "The steps before it ran.")
        self.assertEqual(self.perform.call_count, 2)
        self.perform.side_effect = HTTPException(503, "Nope.")
        with self.assertRaises(HTTPException) as failed:
            self.run_action({"type": "sequence", "steps": [{"type": "media", "name": "mute"}]})
        self.assertEqual(failed.exception.detail, "Step 1 of 1 didn't work: Nope.")


class ShellOpenTests(unittest.TestCase):
    def libraries(self, result=42, com=0):
        libraries = {name: MagicMock(name=name) for name in ("ole32", "shell32", "user32")}
        libraries["ole32"].CoInitializeEx.return_value = com
        libraries["shell32"].ShellExecuteW.return_value = result
        return libraries

    def test_shell_execute_open_with_com_initialized(self):
        libraries = self.libraries()
        with patch.object(deck, "_library", side_effect=libraries.__getitem__):
            deck.shell_open("C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Steam\\Steam.lnk")
        libraries["shell32"].ShellExecuteW.assert_called_once_with(
            None, "open", "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Steam\\Steam.lnk", None, None, 1)
        libraries["ole32"].CoInitializeEx.assert_called_once_with(None, 0x6)
        libraries["ole32"].CoUninitialize.assert_called_once_with()

    def test_failures_carry_the_shell_code(self):
        for code in (0, 2, 5, 31, 32):
            libraries = self.libraries(result=code, com=-2147417850)  # RPC_E_CHANGED_MODE: COM stays as it is.
            with self.subTest(code=code), patch.object(deck, "_library", side_effect=libraries.__getitem__):
                with self.assertRaises(deck.ShellOpenError) as failed:
                    deck.shell_open("steam://rungameid/620")
                self.assertEqual(failed.exception.code, code)
                self.assertIsInstance(failed.exception, OSError)
                libraries["ole32"].CoUninitialize.assert_not_called()


# MARK: - Start menu shortcuts

LINK_CLSID = bytes.fromhex("0114020000000000c000000000000046")


def build_lnk(target=None, *, icon=None, icon_index=0, arguments=None, relative=None, environment_target=None,
              environment_icon=None, unicode=True, unicode_link_info=False, id_list=False, force_no_link_info=False):
    """A .lnk file laid out as [MS-SHLLINK] describes it (header, IDList, LinkInfo, strings, extra data)."""
    flags = 0x80 if unicode else 0
    body = b""
    if id_list:
        flags |= 0x1
        items = struct.pack("<H", 6) + b"\x1f\x50\x00\x00" + b"\x00\x00"  # one ItemID, then the TerminalID
        body += struct.pack("<H", len(items)) + items
    if target is not None:
        flags |= 0x2
        if force_no_link_info:
            flags |= 0x100
        header_size = 0x24 if unicode_link_info else 0x1C
        volume = struct.pack("<IIII", 0x11, 3, 0x1234ABCD, 0x10) + b"\x00"
        base = (b"?\x00" if unicode_link_info else target.encode("cp1252")) + b"\x00"
        suffix = b"\x00"
        volume_offset = header_size
        base_offset = volume_offset + len(volume)
        suffix_offset = base_offset + len(base)
        tail = b""
        unicode_offsets = b""
        if unicode_link_info:
            base_unicode_offset = suffix_offset + len(suffix)
            base_unicode = target.encode("utf-16-le") + b"\x00\x00"
            suffix_unicode_offset = base_unicode_offset + len(base_unicode)
            tail = base_unicode + b"\x00\x00"
            unicode_offsets = struct.pack("<II", base_unicode_offset, suffix_unicode_offset)
        size = header_size + len(volume) + len(base) + len(suffix) + len(tail)
        info = struct.pack("<IIIIIII", size, header_size, 0x1, volume_offset, base_offset, 0, suffix_offset)
        body += info + unicode_offsets + volume + base + suffix + tail
    for flag, text in ((0x8, relative), (0x20, arguments), (0x40, icon)):
        if text is not None:
            flags |= flag
            encoded = text.encode("utf-16-le") if unicode else text.encode("cp1252")
            body += struct.pack("<H", len(text)) + encoded
    extra = b""
    for flag, signature, text in ((0x200, 0xA0000001, environment_target), (0x4000, 0xA0000007, environment_icon)):
        if text is not None:
            flags |= flag
            ansi = text.encode("cp1252").ljust(260, b"\x00")
            wide = text.encode("utf-16-le").ljust(520, b"\x00")
            extra += struct.pack("<II", 0x314, signature) + ansi + wide
    header = struct.pack("<I16sIIQQQIiIHHII", 0x4C, LINK_CLSID, flags, 0x20, 0, 0, 0, 0, icon_index, 1, 0, 0, 0, 0)
    return header + body + extra + b"\x00\x00\x00\x00"


class ShortcutParsingTests(unittest.TestCase):
    def test_target_from_link_info(self):
        info = deck.parse_shortcut(build_lnk("C:\\Program Files\\Spotify\\Spotify.exe", arguments="--minimized"))
        self.assertEqual(info.target, "C:\\Program Files\\Spotify\\Spotify.exe")
        self.assertEqual(info.arguments, "--minimized")
        self.assertEqual((info.icon_path, info.icon_index), ("C:\\Program Files\\Spotify\\Spotify.exe", 0))

    def test_unicode_link_info_and_ansi_strings(self):
        info = deck.parse_shortcut(build_lnk("C:\\Jocuri\\Ținuturi\\joc.exe", unicode_link_info=True, id_list=True))
        self.assertEqual(info.target, "C:\\Jocuri\\Ținuturi\\joc.exe")
        info = deck.parse_shortcut(build_lnk("C:\\Games\\game.exe", icon="C:\\Games\\game.ico", icon_index=2, unicode=False))
        self.assertEqual((info.target, info.icon_path, info.icon_index), ("C:\\Games\\game.exe", "C:\\Games\\game.ico", 2))

    def test_environment_blocks_and_icon_location(self):
        with patch.dict(os.environ, {"ProgramFiles": "C:\\Program Files", "LOCALAPPDATA": "C:\\Users\\Gamer\\AppData\\Local"}):
            info = deck.parse_shortcut(build_lnk("C:\\Old\\obs64.exe", environment_target="%ProgramFiles%\\obs-studio\\bin\\64bit\\obs64.exe",
                                                 environment_icon="%LOCALAPPDATA%\\OBS\\obs.ico", icon="ignored.ico", icon_index=1))
            self.assertEqual(info.target, "C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe")
            self.assertEqual((info.icon_path, info.icon_index), ("C:\\Users\\Gamer\\AppData\\Local\\OBS\\obs.ico", 1))
            info = deck.parse_shortcut(build_lnk("C:\\x.exe", icon='"%ProgramFiles%\\X\\x.dll"', icon_index=-101))
            self.assertEqual((info.icon_path, info.icon_index), ("C:\\Program Files\\X\\x.dll", -101))

    def test_relative_path_and_ignored_link_info(self):
        folder = os.path.join(os.sep, "menu", "Programs")
        info = deck.parse_shortcut(build_lnk("C:\\ignored.exe", relative="..\\Tools\\tool.exe", force_no_link_info=True), folder)
        self.assertEqual(info.target, os.path.normpath(os.path.join(folder, "..", "Tools", "tool.exe")))

    def test_header_only_links_like_the_pretend_pc_writes(self):
        header = struct.pack("<I16sIIQQQIiIHHII", 0x4C, LINK_CLSID, 0, 0x20, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0) + b"\0\0\0\0"
        self.assertEqual(deck.parse_shortcut(header), deck.ShortcutInfo(None, None, None, 0))

    def test_damaged_files_are_refused(self):
        good = build_lnk("C:\\Program Files\\App\\app.exe", arguments="-x", icon="C:\\a.ico")
        for data in (b"", b"MZ" + b"\0" * 100, good[:60], good[:80], good[:-10],
                     good[:4] + b"\0" * 16 + good[20:], struct.pack("<I", 0x4D) + good[4:]):
            with self.subTest(length=len(data)):
                with self.assertRaises((ValueError, struct.error)):
                    deck.parse_shortcut(data)

    def test_read_shortcut_never_raises(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "x.lnk"
            path.write_bytes(b"garbage")
            self.assertIsNone(deck.read_shortcut(str(path)))
            self.assertIsNone(deck.read_shortcut(str(Path(folder) / "missing.lnk")))
            path.write_bytes(build_lnk("C:\\a.exe"))
            self.assertEqual(deck.read_shortcut(str(path)).target, "C:\\a.exe")


class StartMenuTests(TempFolderTestCase):
    def setUp(self):
        super().setUp()
        self.user = self.folder / "Roaming" / "Microsoft" / "Windows" / "Start Menu" / "Programs"
        self.common = self.folder / "ProgramData" / "Microsoft" / "Windows" / "Start Menu" / "Programs"
        links = {
            self.user / "Spotify.lnk": build_lnk("C:\\Users\\Gamer\\AppData\\Roaming\\Spotify\\Spotify.exe"),
            self.user / "Discord Inc" / "Discord.lnk": build_lnk("C:\\Users\\Gamer\\AppData\\Local\\Discord\\Update.exe",
                                                                 arguments="--processStart Discord.exe",
                                                                 icon="C:\\Users\\Gamer\\AppData\\Local\\Discord\\app.ico"),
            self.user / "Uninstall Spotify.lnk": build_lnk("C:\\Spotify\\Spotify.exe"),
            self.user / "Readme.lnk": build_lnk("C:\\Game\\readme.txt"),
            self.user / "Game Tools" / "Manual.lnk": build_lnk("C:\\Game\\manual.exe"),
            self.user / "Game Tools" / "Docs.lnk": build_lnk("C:\\Game\\docs.chm"),
            self.user / "Game Tools" / "Remove Game.lnk": build_lnk("C:\\Game\\unins000.exe"),
            self.user / "Damaged.lnk": b"not a shortcut",
            self.common / "Spotify.lnk": build_lnk("C:\\Program Files\\Spotify\\Spotify.exe"),
            self.common / "Steam" / "Steam.lnk": build_lnk("C:\\Program Files (x86)\\Steam\\steam.exe"),
            self.common / "OBS Studio" / "OBS Studio (64bit).lnk": build_lnk(
                "C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe", icon="C:\\Program Files\\obs-studio\\obs.ico"),
            self.common / "Pretend.lnk": struct.pack("<I16sIIQQQIiIHHII", 0x4C, LINK_CLSID, 0, 0x20, 0, 0, 0, 0, 0, 1,
                                                     0, 0, 0, 0) + b"\0\0\0\0",
            self.common / "a" / "b" / "c" / "d" / "e" / "f" / "Six Levels.lnk": build_lnk("C:\\six.exe"),
            self.common / "a" / "b" / "c" / "d" / "e" / "f" / "g" / "Too Deep.lnk": build_lnk("C:\\deep.exe"),
        }
        for path, data in links.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.user / "notes.txt").write_text("not a shortcut", encoding="utf-8")
        (self.common / "desktop.ini").write_text("[.ShellClassInfo]", encoding="utf-8")
        self.registry = orbit_icons.IconRegistry(extractor=lambda path, index: None, key=b"k" * 32)
        icons = patch.object(deck.orbit_icons, "ICONS", self.registry)
        icons.start()
        self.addCleanup(icons.stop)
        self.apps = deck.StartMenuApps(folders_provider=lambda: [str(self.user), str(self.common)])

    def test_listing(self):
        payload = self.apps.payload()["apps"]
        self.assertEqual([row["name"] for row in payload],
                         ["Damaged", "Discord", "OBS Studio (64bit)", "Pretend", "Six Levels", "Spotify", "Steam"])
        by_name = {row["name"]: row for row in payload}
        self.assertEqual(by_name["Spotify"]["id"], deck.app_id_for(self.user / "Spotify.lnk"))  # The user's copy wins.
        self.assertEqual(by_name["Spotify"]["id"],
                         hashlib.sha1(os.path.normpath(str(self.user / "Spotify.lnk")).casefold().encode()).hexdigest())
        self.assertEqual(by_name["Discord"]["folder"], "Discord Inc")
        self.assertIsNone(by_name["Spotify"]["folder"])
        self.assertEqual(by_name["Discord"]["iconID"],
                         self.registry.identity("C:\\Users\\Gamer\\AppData\\Local\\Discord\\app.ico", 0))
        self.assertEqual(by_name["Steam"]["iconID"], self.registry.identity("C:\\Program Files (x86)\\Steam\\steam.exe", 0))
        self.assertIsNone(by_name["Pretend"]["iconID"])
        self.assertIsNone(by_name["Damaged"]["iconID"])
        for row in payload:
            self.assertEqual(set(row), {"id", "name", "iconID", "folder"})
            self.assertRegex(row["id"], r"^[0-9a-f]{40}$")
        # Paths never leave the PC.
        self.assertNotIn(str(self.folder), json.dumps(payload))

    def test_ids_are_stable_and_listing_is_cached(self):
        first = [app.id for app in self.apps.list()]
        (self.common / "New App.lnk").write_bytes(build_lnk("C:\\New\\new.exe"))
        self.assertEqual([app.id for app in self.apps.list()], first)  # Cached for 30 seconds.
        refreshed = deck.StartMenuApps(folders_provider=lambda: [str(self.user), str(self.common)]).list()
        self.assertEqual([app.id for app in refreshed if app.name != "New App"], first)

    def test_find_rescans_for_new_and_removed_shortcuts(self):
        self.apps.list()
        new = self.common / "New App.lnk"
        new.write_bytes(build_lnk("C:\\New\\new.exe"))
        found = self.apps.find(deck.app_id_for(new))
        self.assertEqual(found.name, "New App")
        steam = self.common / "Steam" / "Steam.lnk"
        steam.unlink()
        self.assertIsNone(self.apps.find(deck.app_id_for(steam)))
        self.assertIsNone(self.apps.find("../../etc"))
        self.assertIsNone(self.apps.find(APP_ID))

    def test_launching_through_the_route(self):
        ctx = make_app(self.folder / "app", apps=self.apps)
        self.addCleanup(ctx.client.close)
        steam = deck.app_id_for(self.common / "Steam" / "Steam.lnk")
        response = ctx.client.post("/api/deck/run", json={"action": {"type": "launch", "appID": steam}}, headers=AUTH)
        self.assertEqual(response.json(), {"status": "done", "detail": "Opened Steam"})
        ctx.open.assert_called_once_with(str(self.common / "Steam" / "Steam.lnk"))
        response = ctx.client.post("/api/deck/run", json={"action": {"type": "launch", "appID": APP_ID, "name": "Gone"}}, headers=AUTH)
        self.assertEqual(response.status_code, 404)
        self.assertIn("Gone is no longer", response.json()["detail"])
        listing = ctx.client.get("/api/deck/apps", headers=AUTH)
        self.assertEqual(listing.status_code, 200)
        self.assertIn(steam, [row["id"] for row in listing.json()["apps"]])

    def test_start_menu_folders_from_the_environment(self):
        with patch.object(deck.orbit_files, "_known_folder", side_effect=AttributeError("no windll")), \
             patch.dict(os.environ, {"APPDATA": str(self.folder / "Roaming"), "PROGRAMDATA": str(self.folder / "ProgramData")}):
            self.assertEqual(deck.start_menu_folders(), [os.path.join(str(self.folder / "Roaming"), "Microsoft", "Windows", "Start Menu", "Programs"),
                                                         os.path.join(str(self.folder / "ProgramData"), "Microsoft", "Windows", "Start Menu", "Programs")])
        with patch.object(deck.orbit_files, "_known_folder", side_effect=lambda guid: str(self.common) if guid == deck.FOLDERID_COMMON_PROGRAMS else None), \
             patch.dict(os.environ, {"APPDATA": str(self.folder / "missing")}, clear=False):
            self.assertEqual(deck.start_menu_folders(), [str(self.common)])


# MARK: - OBS

def independent_obs_auth(password, salt, challenge):
    """The protocol's two SHA-256 steps written out separately from orbit_deck's implementation."""
    first = hashlib.sha256()
    first.update(password.encode("utf-8"))
    first.update(salt.encode("utf-8"))
    secret = base64.standard_b64encode(first.digest())
    second = hashlib.sha256()
    second.update(secret)
    second.update(challenge.encode("utf-8"))
    return base64.standard_b64encode(second.digest()).decode()


class OBSAuthenticationTests(unittest.TestCase):
    def test_known_vectors_computed_with_openssl(self):
        # printf '%s' "<password><salt>" | openssl dgst -sha256 -binary | base64, then again with the challenge.
        self.assertEqual(deck.obs_authentication("supersecretpassword", "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
                                                 "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="),
                         "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
        self.assertEqual(deck.obs_authentication("pässwörd", "c2FsdA==", "Y2hhbGxlbmdl"),
                         "f18Q7g1rjm6mzXg4eQILFEV+0uBR39IioAJoZqAagmY=")

    def test_matches_an_independent_implementation(self):
        for password, salt, challenge in (("a", "b", "c"), (OBS_PASSWORD, "salt+/=", "challenge=="), ("ünï", "", "")):
            self.assertEqual(deck.obs_authentication(password, salt, challenge), independent_obs_auth(password, salt, challenge))


class FakeOBS:
    """A small obs-websocket 5 server: Hello/Identify with authentication, requests, events."""

    def __init__(self, *, password=OBS_PASSWORD, auth=True, subprotocols="select", silent=False, close_code=None,
                 binary=False):
        from websockets.sync.server import serve
        self.password, self.auth, self.silent, self.close_code, self.binary = password, auth, silent, close_code, binary
        self.scenes = ["Gaming", "Just Chatting", "BRB"]
        self.state = {"scene": "Gaming", "recording": False, "streaming": False, "replay": False,
                      "inputs": {"Mic/Aux": False, "Desktop Audio": False, "Webcam": None}}
        self.requests, self.negotiated, self.identified, self.raw = [], [], [], []
        options = {"compression": None}
        if subprotocols == "select":
            options["select_subprotocol"] = lambda connection, offered: \
                "obswebsocket.json" if "obswebsocket.json" in offered else None
        elif subprotocols == "none":
            options["select_subprotocol"] = lambda connection, offered: None
        elif subprotocols == "reject":
            options["select_subprotocol"] = lambda connection, offered: None
            options["process_request"] = self._refuse_offers
        self.server = serve(self._handler, "127.0.0.1", 0, **options)
        self.port = self.server.socket.getsockname()[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.thread.join(5)

    @staticmethod
    def _refuse_offers(connection, request):
        if request.headers.get("Sec-WebSocket-Protocol"):
            return connection.respond(400, "This server does not take subprotocols.\n")
        return None

    @staticmethod
    def scene_id(name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, name))

    def settings(self, **change):
        values = {"found": True, "enabled": True, "port": self.port, "auth_required": self.auth, "password": self.password}
        values.update(change)
        return deck.OBSSettings(**values)

    def _handler(self, websocket):
        self.negotiated.append(websocket.subprotocol)
        if self.silent:
            time.sleep(1.5)
            return
        challenge, salt = base64.b64encode(os.urandom(24)).decode(), base64.b64encode(os.urandom(24)).decode()
        hello = {"obsStudioVersion": "31.1.2", "obsWebSocketVersion": "5.6.2", "rpcVersion": 1}
        if self.auth:
            hello["authentication"] = {"challenge": challenge, "salt": salt}
        websocket.send(json.dumps({"op": 0, "d": hello}))
        try:
            identify = json.loads(websocket.recv(timeout=5))
        except Exception:
            return
        self.identified.append(identify)
        if self.close_code:
            websocket.close(self.close_code, "Closing for the test.")
            return
        if self.auth and identify.get("d", {}).get("authentication") != independent_obs_auth(self.password, salt, challenge):
            websocket.close(4009, "Authentication failed.")
            return
        websocket.send(json.dumps({"op": 2, "d": {"negotiatedRpcVersion": 1}}))
        try:
            for raw in websocket:
                self.raw.append(raw)
                message = json.loads(raw)
                data = message.get("d") or {}
                if message.get("op") != 6:
                    websocket.close(4006, "Unknown op")
                    return
                self.requests.append((data.get("requestType"), data.get("requestData")))
                if self.binary:
                    websocket.send(b"\x82\x00binary")
                    continue
                # An event and a reply meant for another request come first; the client must skip both.
                websocket.send(json.dumps({"op": 5, "d": {"eventType": "StudioModeStateChanged", "eventIntent": 1,
                                                          "eventData": {"studioModeEnabled": False}}}))
                websocket.send(json.dumps({"op": 7, "d": {"requestType": data.get("requestType"), "requestId": "someone-else",
                                                          "requestStatus": {"result": False, "code": 600}}}))
                status, response = self._respond(data.get("requestType"), data.get("requestData") or {})
                reply = {"requestType": data.get("requestType"), "requestId": data.get("requestId"), "requestStatus": status}
                if response is not None:
                    reply["responseData"] = response
                websocket.send(json.dumps({"op": 7, "d": reply}))
        except Exception:
            return

    def _respond(self, kind, data):
        ok = {"result": True, "code": 100}
        state = self.state
        if kind == "GetSceneList":
            return ok, {"currentProgramSceneName": state["scene"], "currentPreviewSceneName": None,
                        "scenes": [{"sceneName": name, "sceneIndex": index, "sceneUuid": self.scene_id(name)}
                                   for index, name in enumerate(reversed(self.scenes))]}
        if kind in ("GetRecordStatus", "GetStreamStatus"):
            return ok, {"outputActive": state["recording" if kind == "GetRecordStatus" else "streaming"]}
        if kind == "GetReplayBufferStatus":
            return ok, {"outputActive": state["replay"]}
        if kind == "GetInputList":
            return ok, {"inputs": [{"inputName": name, "inputKind": "wasapi_input_capture"} for name in state["inputs"]]}
        if kind == "SetCurrentProgramScene":
            name = data.get("sceneName")
            if "sceneUuid" in data:
                name = next((scene for scene in self.scenes if self.scene_id(scene) == data["sceneUuid"]), None)
                if name is None:
                    return {"result": False, "code": 600, "comment": "No scene was found by that UUID."}, None
            if name not in self.scenes:
                return {"result": False, "code": 600, "comment": f"No source was found by the name of `{name}`."}, None
            state["scene"] = name
            return ok, None
        if kind in ("StartRecord", "StopRecord", "ToggleRecord", "ToggleStream"):
            key = "recording" if "Record" in kind else "streaming"
            if kind == "StartRecord" and state[key]:
                return {"result": False, "code": 500, "comment": "The output is already running."}, None
            if kind == "StopRecord" and not state[key]:
                return {"result": False, "code": 501, "comment": "The output is not running."}, None
            state[key] = not state[key] if kind.startswith("Toggle") else kind.startswith("Start")
            if kind == "StopRecord":
                return ok, {"outputPath": "C:\\Users\\Gamer\\Videos\\2026-10-24 12-00-00.mkv"}
            return ok, ({"outputActive": state[key]} if kind.startswith("Toggle") else None)
        if kind == "StartReplayBuffer":
            if state["replay"]:
                return {"result": False, "code": 500, "comment": "The output is already running."}, None
            state["replay"] = True
            return ok, None
        if kind == "SaveReplayBuffer":
            if not state["replay"]:
                return {"result": False, "code": 501, "comment": "Replay buffer is not active."}, None
            return ok, None
        if kind == "ToggleInputMute":
            name = data.get("inputName")
            if name not in state["inputs"]:
                return {"result": False, "code": 600, "comment": "No input was found."}, None
            if state["inputs"][name] is None:
                # What obs-websocket answers (RequestStatus::InvalidResourceState, RequestHandler_Inputs.cpp).
                return {"result": False, "code": 604, "comment": "The specified input does not support audio."}, None
            state["inputs"][name] = not state["inputs"][name]
            return ok, {"inputMuted": state["inputs"][name]}
        return {"result": False, "code": 204, "comment": "Unknown request"}, None


class OBSSettingsTests(TempFolderTestCase):
    def write_config(self, data, bom=False):
        path = self.folder / "obs-studio" / "plugin_config" / "obs-websocket" / "config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        text = data if isinstance(data, str) else json.dumps(data)
        path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))

    def test_config_json(self):
        self.write_config({"server_enabled": True, "server_port": 4456, "auth_required": True,
                           "server_password": OBS_PASSWORD, "first_load": False}, bom=True)
        settings = deck.load_obs_settings(self.folder / "obs-studio")
        self.assertEqual(settings, deck.OBSSettings(True, True, 4456, True, OBS_PASSWORD, "config.json"))
        self.assertNotIn(OBS_PASSWORD, repr(settings))
        with patch.dict(os.environ, {"APPDATA": str(self.folder)}):
            self.assertEqual(deck.load_obs_settings(), settings)

    def test_bad_values_fall_back_to_defaults(self):
        self.write_config({"server_enabled": "true", "server_port": 99999, "auth_required": "nope", "server_password": 5})
        settings = deck.load_obs_settings(self.folder / "obs-studio")
        self.assertEqual((settings.enabled, settings.port, settings.auth_required, settings.password), (True, 4455, True, None))

    def test_global_ini_from_obs_28_and_29(self):
        self.write_config("{broken")
        ini = self.folder / "obs-studio" / "global.ini"
        ini.write_text("[General]\nName=x\n\n[OBSWebSocket]\nServerEnabled=true\nServerPort=4444\nAuthRequired=true\n"
                       f"ServerPassword={OBS_PASSWORD}%\nFirstLoad=false\n", encoding="utf-8-sig")
        settings = deck.load_obs_settings(self.folder / "obs-studio")
        self.assertEqual(settings, deck.OBSSettings(True, True, 4444, True, OBS_PASSWORD + "%", "global.ini"))

    def test_nothing_saved(self):
        self.assertFalse(deck.load_obs_settings(self.folder / "obs-studio").found)
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(deck.load_obs_settings().found)

    def test_installed_detection(self):
        empty = deck.OBSSettings(found=False)
        with patch.object(deck, "obs_running", return_value=False), patch.object(deck, "_registry_install_path", return_value=None), \
             patch.dict(os.environ, {"ProgramFiles": str(self.folder / "PF")}, clear=True):
            self.assertFalse(deck.obs_installed(empty, self.folder / "obs-studio"))
            exe = self.folder / "PF" / "obs-studio" / "bin" / "64bit" / "obs64.exe"
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b"MZ")
            self.assertTrue(deck.obs_installed(empty, self.folder / "obs-studio"))
        with patch.object(deck, "obs_running", return_value=True), patch.object(deck, "_registry_install_path", return_value=None), \
             patch.dict(os.environ, {}, clear=True):
            self.assertTrue(deck.obs_installed(empty, self.folder / "nothing"))
        self.assertTrue(deck.obs_installed(deck.OBSSettings(found=True)))

    def test_running_detection(self):
        processes = [SimpleNamespace(info={"name": "explorer.exe"}), SimpleNamespace(info={"name": "OBS64.EXE"})]
        with patch.object(deck.psutil, "process_iter", return_value=processes):
            self.assertTrue(deck.obs_running())
        with patch.object(deck.psutil, "process_iter", return_value=processes[:1]):
            self.assertFalse(deck.obs_running())
        with patch.object(deck.psutil, "process_iter", side_effect=OSError("denied")):
            self.assertFalse(deck.obs_running())


class OBSControllerTests(unittest.TestCase):
    def start(self, **options):
        fake = FakeOBS(**options)
        self.addCleanup(fake.close)
        return fake

    def controller(self, fake=None, settings=None, installed=True):
        loaded = settings if settings is not None else fake.settings()
        return deck.OBSController(settings_loader=lambda: loaded, installed=lambda s: installed)

    def test_status_with_a_running_obs(self):
        fake = self.start()
        fake.state.update(recording=True, replay=True, scene="BRB")
        status = self.controller(fake).status()
        self.assertEqual(status, {"installed": True, "enabled": True, "connected": True,
                                  "scenes": ["Gaming", "Just Chatting", "BRB"], "currentScene": "BRB",
                                  "recording": True, "streaming": False, "replayBuffer": True,
                                  "inputs": ["Mic/Aux", "Desktop Audio", "Webcam"], "reason": None})
        self.assertEqual(fake.negotiated, ["obswebsocket.json"])
        self.assertEqual(fake.identified[0]["d"]["eventSubscriptions"], 0)
        self.assertEqual([request for request, _ in fake.requests], list(deck.OBS_STATUS_REQUESTS))
        self.assertNotIn(fake.password, json.dumps(status))

    def test_status_explains_why_obs_is_unavailable(self):
        cases = ((deck.OBSSettings(found=False), False, deck.OBS_NOT_INSTALLED, False),
                 (deck.OBSSettings(found=False), True, deck.OBS_NOT_SET_UP, True),
                 (deck.OBSSettings(found=True, enabled=False, password=OBS_PASSWORD), True, deck.OBS_SERVER_OFF, True))
        for settings, installed, reason, expected_installed in cases:
            with self.subTest(reason=reason[:30]):
                status = deck.OBSController(settings_loader=lambda: settings, installed=lambda s: installed).status()
                self.assertEqual((status["installed"], status["connected"], status["reason"]), (expected_installed, False, reason))
                self.assertFalse(status["enabled"])
                self.assertNotIn(OBS_PASSWORD, json.dumps(status))

    def test_closed_port_means_obs_is_not_running(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        settings = deck.OBSSettings(found=True, enabled=True, port=port, password=OBS_PASSWORD)
        with patch.object(deck, "obs_running", return_value=False):
            self.assertEqual(self.controller(settings=settings).status()["reason"], deck.OBS_NOT_RUNNING)
        with patch.object(deck, "obs_running", return_value=True):
            self.assertEqual(self.controller(settings=settings).status()["reason"], deck.OBS_NOT_ANSWERING.format(port=port))
            with self.assertRaises(HTTPException) as failed:
                self.controller(settings=settings).run("ToggleRecord", {})
        self.assertEqual(failed.exception.status_code, 503)

    def test_running_obs_actions(self):
        fake = self.start()
        obs = self.controller(fake)
        self.assertEqual(obs.run("SetCurrentProgramScene", {"sceneName": "BRB"}), "Switched to BRB")
        self.assertEqual(fake.state["scene"], "BRB")
        self.assertEqual(obs.run("ToggleRecord", {}), "Recording started")
        self.assertEqual(obs.run("ToggleRecord", {}), "Recording stopped")
        self.assertEqual(obs.run("StartRecord", {}), "Recording started")
        self.assertEqual(obs.run("StopRecord", {}), "Recording saved as 2026-10-24 12-00-00.mkv")
        self.assertEqual(obs.run("ToggleStream", {}), "Streaming started")
        self.assertEqual(obs.run("StartReplayBuffer", {}), "Replay buffer started")
        self.assertEqual(obs.run("SaveReplayBuffer", {}), "Replay saved")
        self.assertEqual(obs.run("ToggleInputMute", {"inputName": "Mic/Aux"}), "Muted Mic/Aux")
        self.assertEqual(obs.run("ToggleInputMute", {"inputName": "Mic/Aux"}), "Unmuted Mic/Aux")
        self.assertEqual(fake.requests[1], ("ToggleRecord", None))
        self.assertTrue(all(request in deck.OBS_ALLOWED_REQUESTS for request, _ in fake.requests))

    def test_scene_ids_fall_back_to_the_name(self):
        fake = self.start()
        obs = self.controller(fake)
        self.assertEqual(obs.run("SetCurrentProgramScene", {"sceneUuid": fake.scene_id("Just Chatting"),
                                                            "sceneName": "Old name"}), "Switched to Old name")
        self.assertEqual(fake.state["scene"], "Just Chatting")
        self.assertEqual(obs.run("SetCurrentProgramScene", {"sceneUuid": str(uuid.uuid4()), "sceneName": "BRB"}), "Switched to BRB")
        self.assertEqual(fake.requests[-2:], [("SetCurrentProgramScene", {"sceneUuid": fake.requests[-2][1]["sceneUuid"]}),
                                              ("SetCurrentProgramScene", {"sceneName": "BRB"})])

    def test_obs_refusals_in_plain_words(self):
        fake = self.start()
        obs = self.controller(fake)
        for request, data, message in (("StopRecord", {}, "OBS isn't recording."),
                                       ("SaveReplayBuffer", {}, "The replay buffer isn't running"),
                                       ("SetCurrentProgramScene", {"sceneName": "Nope"}, "OBS has no scene called \u201cNope\u201d"),
                                       ("ToggleInputMute", {"inputName": "Nope"}, "no audio source called \u201cNope\u201d"),
                                       ("ToggleInputMute", {"inputName": "Webcam"}, "\u201cWebcam\u201d in OBS has no audio")):
            with self.subTest(request=request):
                with self.assertRaises(HTTPException) as failed:
                    obs.run(request, data)
                self.assertEqual(failed.exception.status_code, 409)
                self.assertIn(message, failed.exception.detail)
        obs.run("StartRecord", {})
        with self.assertRaises(HTTPException) as failed:
            obs.run("StartRecord", {})
        self.assertEqual(failed.exception.detail, "OBS is already recording.")
        self.assertEqual(deck._obs_failure("ToggleInputMute", {"inputName": "Cam"}, deck.OBSResult(False, 605, None, {})),
                         "\u201cCam\u201d in OBS has no audio to mute.")
        result = deck.OBSResult(False, 702, "Some new failure.", {})
        self.assertEqual(deck._obs_failure("ToggleStream", {}, result), "OBS couldn't do that: Some new failure.")
        self.assertEqual(deck._obs_failure("ToggleStream", {}, deck.OBSResult(False, 207, None, {}))[:12], "OBS is busy ")

    def test_a_wrong_or_missing_password(self):
        fake = self.start()
        wrong = "not-the-password"
        with self.assertRaises(HTTPException) as failed:
            self.controller(settings=fake.settings(password=wrong)).run("ToggleRecord", {})
        self.assertEqual(failed.exception.status_code, 409)
        self.assertEqual(failed.exception.detail, deck.OBS_AUTH_FAILED)
        self.assertNotIn(wrong, failed.exception.detail)
        self.assertNotIn(fake.password, failed.exception.detail)
        status = self.controller(settings=fake.settings(password=wrong)).status()
        self.assertEqual((status["connected"], status["reason"]), (False, deck.OBS_AUTH_FAILED))
        self.assertNotIn(wrong, json.dumps(status))
        with self.assertRaises(HTTPException) as failed:
            self.controller(settings=fake.settings(password=None)).run("ToggleRecord", {})
        self.assertEqual(failed.exception.detail, deck.OBS_PASSWORD_UNKNOWN)
        self.assertEqual(fake.requests, [])  # Nothing was sent before OBS accepted Orbit.

    def test_obs_without_authentication(self):
        fake = self.start(auth=False)
        self.assertEqual(self.controller(settings=fake.settings(password=None)).run("ToggleStream", {}), "Streaming started")
        self.assertNotIn("authentication", fake.identified[0]["d"])

    def test_with_or_without_the_json_subprotocol(self):
        for mode, negotiated in (("none", None), ("reject", None), ("select", "obswebsocket.json")):
            with self.subTest(mode=mode):
                fake = self.start(subprotocols=mode)
                self.assertTrue(self.controller(fake).status()["connected"])
                self.assertEqual(fake.negotiated, [negotiated])

    def test_protocol_problems(self):
        fake = self.start(close_code=4010)
        with self.assertRaises(HTTPException) as failed:
            self.controller(fake).run("ToggleRecord", {})
        self.assertEqual((failed.exception.status_code, failed.exception.detail), (502, deck.OBS_UNSUPPORTED))
        fake = self.start(binary=True)
        with self.assertRaises(HTTPException) as failed:
            self.controller(fake).run("ToggleRecord", {})
        self.assertEqual((failed.exception.status_code, failed.exception.detail), (502, deck.OBS_UNSUPPORTED))

    def test_a_connection_that_times_out_is_not_obs_being_busy(self):
        # Windows can take seconds to refuse a closed local port; a timeout while connecting is
        # reported like a refused connection, from the process list.
        settings = deck.OBSSettings(found=True, enabled=True, port=4455, password=OBS_PASSWORD)
        with patch("websockets.sync.client.connect", side_effect=TimeoutError("timed out during opening handshake")):
            with patch.object(deck, "obs_running", return_value=False):
                with self.assertRaises(deck.OBSUnavailable) as failed:
                    deck.open_obs_session(settings)
                self.assertEqual((failed.exception.status, failed.exception.reason), (503, deck.OBS_NOT_RUNNING))
            with patch.object(deck, "obs_running", return_value=True):
                with self.assertRaises(deck.OBSUnavailable) as failed:
                    deck.open_obs_session(settings)
                self.assertEqual(failed.exception.reason, deck.OBS_NOT_ANSWERING.format(port=4455))
        self.assertGreater(deck.OBS_OPEN_TIMEOUT, 2.5)

    def test_a_silent_server_times_out_quickly(self):
        fake = self.start(silent=True)
        started = time.monotonic()
        with patch.object(deck, "OBS_REPLY_TIMEOUT", 0.3):
            with self.assertRaises(deck.OBSUnavailable) as failed:
                deck.open_obs_session(fake.settings(), timeout=0.6)
        self.assertEqual((failed.exception.status, failed.exception.reason), (504, deck.OBS_TIMEOUT))
        self.assertLess(time.monotonic() - started, 3)

    def test_only_allowlisted_requests_are_ever_sent(self):
        fake = self.start()
        with deck.open_obs_session(fake.settings()) as session:
            for request in ("CallVendorRequest", "SetInputSettings", "StopStream", "Sleep", "SetProfileParameter"):
                with self.subTest(request=request), self.assertRaises(ValueError):
                    session.request(request)
            self.assertTrue(session.request("GetSceneList").ok)
        self.assertEqual([request for request, _ in fake.requests], ["GetSceneList"])
        self.assertEqual(deck.OBS_ALLOWED_REQUESTS, frozenset(deck.OBS_ACTIONS + deck.OBS_STATUS_REQUESTS))

    def test_missing_websockets_package(self):
        with patch.dict("sys.modules", {"websockets.sync.client": None}):
            with self.assertRaises(deck.OBSUnavailable) as failed:
                deck.open_obs_session(deck.OBSSettings(found=True, enabled=True, password="x"))
        self.assertEqual(failed.exception.reason, deck.OBS_PACKAGES)

    def test_obs_routes(self):
        fake = self.start()
        with tempfile.TemporaryDirectory() as folder:
            ctx = make_app(folder, obs=self.controller(fake))
            self.addCleanup(ctx.client.close)
            status = ctx.client.get("/api/deck/obs", headers=AUTH)
            self.assertEqual(status.status_code, 200)
            self.assertTrue(status.json()["connected"])
            saved = ctx.client.put("/api/deck", json={"buttons": [button(title="Record", action={"type": "obs", "request": "ToggleRecord"})]},
                                   headers=AUTH).json()["buttons"][0]
            run = ctx.client.post(f"/api/deck/buttons/{saved['id']}/run", headers=AUTH)
            self.assertEqual(run.json(), {"status": "done", "detail": "Recording started"})
            failed = ctx.client.post("/api/deck/run", json={"action": {"type": "obs", "request": "StopStream"}}, headers=AUTH)
            self.assertEqual(failed.status_code, 422)
            for response in (status, run, failed):
                self.assertNotIn(fake.password, response.text)


# MARK: - The agent

class AgentDeckTests(TempFolderTestCase):
    """The deck as orbit_agent wires it: its perform_action, its keyboard typing and the shared settings."""

    def setUp(self):
        super().setUp()
        import orbit_agent as agent
        self.agent = agent
        orbit_settings.set_shared_store(orbit_settings.SettingsStore(self.folder / "settings.json"))
        self.addCleanup(orbit_settings.set_shared_store, None)
        for patcher in (patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent, "require_windows")):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = TestClient(agent.app, base_url="https://testserver")
        self.addCleanup(self.client.close)

    def test_action_lists_match_the_agent(self):
        self.assertEqual(deck.SYSTEM_ACTIONS, self.agent.ACTIONS)
        self.assertEqual(deck.POWER_ACTIONS, self.agent.POWER_ACTIONS)
        self.assertTrue(set(deck.MEDIA_ACTIONS.values()) <= self.agent.ACTIONS)
        self.assertEqual(set(deck.SYSTEM_DETAILS), set(deck.SYSTEM_ACTIONS))

    def test_deck_is_kept_in_the_shared_settings(self):
        saved = self.client.put("/api/deck", json={"buttons": [button()]}, headers=AUTH)
        self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(orbit_settings.shared_store().get("deck")["buttons"], saved.json()["buttons"])

    def test_system_and_media_buttons_call_the_agents_perform_action(self):
        with patch.object(self.agent, "perform_action", return_value={"status": "sent"}) as perform:
            response = self.client.post("/api/deck/run", json={"action": {"type": "media", "name": "next"}}, headers=AUTH)
            self.assertEqual(response.json(), {"status": "done", "detail": "Next track"})
            perform.assert_called_once_with("media_next")
            self.client.post("/api/deck/run", json={"action": {"type": "system", "name": "shutdown"}, "confirm": True}, headers=AUTH)
            self.assertEqual(perform.call_args, call("shutdown"))  # The mock: nothing shuts down.

    def test_text_buttons_use_the_keyboard_typing_path(self):
        user32 = MagicMock()
        user32.VkKeyScanW.side_effect = lambda char: 0x0D if char == "\r" else 0x0131 if char == "!" else ord(char.upper())
        with patch.object(self.agent.ctypes, "windll", create=True) as windll:
            windll.user32 = user32
            response = self.client.post("/api/deck/run", json={"action": {"type": "text", "text": "hi\n!"}}, headers=AUTH)
        self.assertEqual(response.json(), {"status": "done", "detail": "Typed 4 characters"})
        pressed = [args[0] for args, _ in (entry for entry in user32.keybd_event.call_args_list) if args[2] == 0]
        self.assertEqual(pressed, [ord("H"), ord("I"), 0x0D, 0x10, 0x31])  # Shift+1 for "!".
        user32.VkKeyScanW.side_effect = lambda char: -1
        with patch.object(self.agent.ctypes, "windll", create=True) as windll:
            windll.user32 = user32
            refused = self.client.post("/api/deck/run", json={"action": {"type": "text", "text": "ț"}}, headers=AUTH)
        self.assertEqual(refused.status_code, 422)
        self.assertIn("keyboard layout", refused.json()["detail"])

    def test_hotkeys_go_through_orbit_input(self):
        with patch.object(self.agent.orbit_input, "press_chord", return_value=["ctrl", "shift", "esc"]) as press:
            response = self.client.post("/api/deck/run", json={"action": {"type": "hotkey", "keys": ["ctrl", "shift", "esc"]}}, headers=AUTH)
        self.assertEqual(response.json()["detail"], "Pressed Ctrl+Shift+Esc")
        press.assert_called_once_with(["ctrl", "shift", "esc"])

    def test_boot_instance_refuses_runs(self):
        with patch.object(self.agent, "BOOT_MODE", True), patch.object(self.agent, "perform_action") as perform:
            response = self.client.post("/api/deck/run", json={"action": {"type": "system", "name": "lock"}}, headers=AUTH)
        self.assertEqual(response.status_code, 409)
        perform.assert_not_called()

    def test_obs_status_reads_the_password_from_obs_and_never_returns_it(self):
        fake = FakeOBS()
        self.addCleanup(fake.close)
        config = self.folder / "Roaming" / "obs-studio" / "plugin_config" / "obs-websocket" / "config.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"server_enabled": True, "server_port": fake.port, "auth_required": True,
                                      "server_password": fake.password}), encoding="utf-8")
        with patch.dict(os.environ, {"APPDATA": str(self.folder / "Roaming")}):
            status = self.client.get("/api/deck/obs", headers=AUTH)
            record = self.client.post("/api/deck/run", json={"action": {"type": "obs", "request": "ToggleRecord"}}, headers=AUTH)
        self.assertEqual(status.status_code, 200)
        self.assertTrue(status.json()["connected"])
        self.assertEqual(record.json(), {"status": "done", "detail": "Recording started"})
        for response in (status, record):
            self.assertNotIn(fake.password, response.text)

    def test_capabilities_list_deck_and_obs(self):
        features = self.client.get("/api/capabilities", headers=AUTH).json()["features"]
        self.assertIn("deck", features)
        self.assertIn("obs", features)


if __name__ == "__main__":
    unittest.main()
