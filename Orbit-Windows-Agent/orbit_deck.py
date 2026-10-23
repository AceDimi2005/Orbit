"""Custom button deck: buttons kept on the PC and run from any Orbit device.

The deck lives in the settings section `deck`, so every iPhone, iPad, Mac, Watch and widget
paired with this PC shows the same buttons:

    GET  /api/deck                     {"buttons": [Button], "updatedAt": "ISO", "maxButtons": 64}
    PUT  /api/deck                     {"buttons": [Button]} replaces the deck (at most 64 buttons);
                                       optional "baseUpdatedAt" refuses the change (409) when another
                                       device saved in between
    POST /api/deck/buttons/{id}/run    runs a saved button
    POST /api/deck/run                 {"action": Action, "confirm": false} runs an action once
    GET  /api/deck/apps                {"apps": [{"id", "name", "iconID", "folder"}]} Start menu shortcuts
    GET  /api/deck/obs                 OBS Studio status for OBS buttons

    Button = {"id": "UUID", "title": "Mute Discord", "symbol": "mic.slash.fill",
              "color": "#FF453A", "confirm": false, "action": Action}

Actions are tagged by "type":

    hotkey   {"keys": ["ctrl", "shift", "m"]}          orbit_input's key names, at most 5 keys
    text     {"text": "gg wp"}                         typed with the PC's keyboard layout
    openUrl  {"url": "steam://rungameid/620"}          http, https, steam, com.epicgames.launcher,
                                                       spotify, discord and ms-settings links
    launch   {"appID": "<sha1>", "name": "Spotify"}    a shortcut from GET /api/deck/apps
    system   {"name": "lock"}                          an /api/action name; sleep, shutdown and
                                                       restart need "confirm": true
    media    {"name": "playpause"}                     playpause, next, previous, mute, volumeup, volumedown
    obs      {"request": "ToggleRecord", "data": {}}   an allowlisted obs-websocket 5 request
    sequence {"steps": [Action], "delayMs": 150}       at most 8 steps, no sequence inside a sequence;
                                                       a pause of 0 to 5000 ms between steps (150 if left out)

Every route needs the main token and the encrypted port. A run answers
`{"status": "done", "detail": "Pressed Ctrl+Shift+M"}`, or an HTTP error whose `detail` says in
plain words what went wrong. Buttons that sleep, shut down or restart the PC must be saved with
`"confirm": true` (the device asks before running them); a one-off run of such an action must
send `"confirm": true` itself (428 otherwise).

Launch buttons open `.lnk` shortcuts from the Start menu (the signed-in user's and the one for
all users) with ShellExecuteW, exactly as clicking them would. Shortcut IDs are the SHA-1 of the
shortcut's path, so they stay the same while the shortcut exists; the agent only ever opens
shortcuts it lists itself, never a path sent by a device. A program that needs administrator
rights makes Windows show a UAC prompt on the PC, and ShellExecuteW waits for it: after
OPEN_WAIT_SECONDS the run answers "done" with a detail saying Windows is still opening it, so a
prompt nobody answers never holds a run slot (the same goes for links Windows asks about).

OBS buttons talk to obs-websocket 5 (bundled with OBS Studio 28 and later) on 127.0.0.1. The
WebSocket password is read from OBS's own settings on this PC
(`%APPDATA%\\obs-studio\\plugin_config\\obs-websocket\\config.json`, or `global.ini` from
OBS 28 and 29), so nobody has to type it. It is never sent to a device, logged or stored by
Orbit. Only the requests listed in OBS_ALLOWED_REQUESTS are ever sent, with short timeouts.
"""
import base64
import codecs
import configparser
import contextlib
import ctypes
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import hashlib
import inspect
import json
import logging
import math
import ntpath
import os
from pathlib import Path
import re
import struct
import threading
import time
import unicodedata
import uuid
from urllib.parse import urlsplit

import psutil
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from starlette.concurrency import run_in_threadpool

import orbit_files
import orbit_icons
import orbit_input
import orbit_links
import orbit_notify
import orbit_settings
from orbit_capabilities import register_feature

try:
    import winreg
except ImportError:  # Not Windows (tests, development on a Mac).
    winreg = None

LOGGER = logging.getLogger("orbit.deck")

SETTINGS_SECTION = "deck"
MAX_BUTTONS = 64
MAX_TITLE_LENGTH = 40
MAX_SYMBOL_LENGTH = 64
MAX_TEXT_LENGTH = 1000          # the same limit as /api/input/keyboard
MAX_NAME_LENGTH = 256           # OBS scene and source names, app names
MAX_SEQUENCE_STEPS = 8
# The pause between sequence steps; the apps offer the same range (DESIGN F4: 0-5000 ms, default 150).
MAX_DELAY_MS = 5000
DEFAULT_DELAY_MS = 150
MAX_DECK_BYTES = 512 * 1024
MAX_BODY_BYTES = 1024 * 1024
MAX_CONCURRENT_RUNS = 4
# ShellExecuteW waits while Windows shows a UAC prompt (programs that need administrator rights)
# or asks which app opens a link. A run stops waiting after OPEN_WAIT_SECONDS, so it never holds a
# run slot until someone answers on the PC; at most MAX_PENDING_OPENS opens may still be waiting.
OPEN_WAIT_SECONDS = 2.5
MAX_PENDING_OPENS = 4
DEFAULT_SYMBOL = "square.grid.2x2.fill"
DEFAULT_COLOR = "#0A84FF"
# updatedAt of a deck that was never saved (always a string, so clients can decode it as a date).
NEVER_SAVED = "1970-01-01T00:00:00Z"

ACTION_TYPES = ("hotkey", "text", "openUrl", "launch", "system", "media", "obs", "sequence")
URL_SCHEMES = frozenset({"http", "https", "steam", "com.epicgames.launcher", "spotify", "discord", "ms-settings"})
_SCHEME_APPS = {"steam": "Steam", "com.epicgames.launcher": "the Epic Games Launcher", "spotify": "Spotify",
                "discord": "Discord", "ms-settings": "Windows Settings"}
# Every name orbit_agent.perform_action accepts (test_deck checks that the two lists match).
SYSTEM_ACTIONS = frozenset({
    "lock", "sleep", "restart", "shutdown", "mute", "volume_up", "volume_down", "media_play_pause",
    "media_next", "media_prev", "toggle_hdr", "restore_display", "kill_game", "show_desktop", "task_view",
    "alt_tab", "screenshot", "fullscreen",
})
POWER_ACTIONS = frozenset({"sleep", "shutdown", "restart"})
SYSTEM_DETAILS = {
    "lock": "Locked the PC", "sleep": "The PC is going to sleep", "restart": "The PC is restarting",
    "shutdown": "The PC is shutting down", "mute": "Toggled mute", "volume_up": "Turned the volume up",
    "volume_down": "Turned the volume down", "media_play_pause": "Play/pause", "media_next": "Next track",
    "media_prev": "Previous track", "toggle_hdr": "Toggled HDR", "restore_display": "Restored the display layout",
    "kill_game": "Closed the game", "show_desktop": "Showed the desktop", "task_view": "Opened Task View",
    "alt_tab": "Switched windows", "screenshot": "Took a screenshot", "fullscreen": "Toggled full screen",
}
MEDIA_ACTIONS = {"playpause": "media_play_pause", "next": "media_next", "previous": "media_prev",
                 "mute": "mute", "volumeup": "volume_up", "volumedown": "volume_down"}
MEDIA_DETAILS = {"playpause": "Play/pause", "next": "Next track", "previous": "Previous track",
                 "mute": "Toggled mute", "volumeup": "Turned the volume up", "volumedown": "Turned the volume down"}
OBS_ACTIONS = ("SetCurrentProgramScene", "StartRecord", "StopRecord", "ToggleRecord", "ToggleStream",
               "SaveReplayBuffer", "ToggleInputMute", "StartReplayBuffer")
OBS_STATUS_REQUESTS = ("GetSceneList", "GetRecordStatus", "GetStreamStatus", "GetReplayBufferStatus", "GetInputList")
# The only requests Orbit ever sends to OBS.
OBS_ALLOWED_REQUESTS = frozenset(OBS_ACTIONS + OBS_STATUS_REQUESTS)

_BUTTON_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")   # UUIDs (and short ids from tests or scripts)
_APP_ID = re.compile(r"^[0-9a-f]{40}$")
_SYMBOL = re.compile(r"^[a-z0-9]+(?:\.[a-z0-9]+)*$")
_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$")
_UUID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
_ISO_SECONDS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
# Right-to-left overrides and isolates can make a title read differently from what it is.
_BIDI_CONTROLS = frozenset("‪‫‬‭‮⁦⁧⁨⁩")


class DeckError(ValueError):
    """A deck, button or action that Orbit does not accept; the message says why in plain words."""


# MARK: - Validation

def _label(value, what, limit):
    """One line of display text: control characters become spaces, whitespace collapses."""
    if not isinstance(value, str):
        raise DeckError(f"{what} must be text.")
    characters = []
    for character in value:
        category = unicodedata.category(character)
        if category == "Cs":
            raise DeckError(f"{what} contains a character that is not valid text.")
        characters.append(" " if category in ("Cc", "Zl", "Zp") or character in _BIDI_CONTROLS else character)
    text = " ".join("".join(characters).split())
    if not text:
        raise DeckError(f"{what} can't be empty.")
    if len(text) > limit:
        raise DeckError(f"{what} can have at most {limit} characters.")
    return text


def _exact_name(value, missing, what):
    """A name that must reach OBS exactly as typed (scene and source names may contain any spacing)."""
    if value is None or (isinstance(value, str) and not value.strip()):
        raise DeckError(missing)
    if not isinstance(value, str):
        raise DeckError(f"{what} must be text.")
    if len(value) > MAX_NAME_LENGTH:
        raise DeckError(f"{what} can have at most {MAX_NAME_LENGTH} characters.")
    if any(unicodedata.category(character) in ("Cc", "Cs") for character in value):
        raise DeckError(f"{what} contains characters that are not allowed.")
    return value


def _uuid_text(value, what):
    if not isinstance(value, str) or not _UUID.match(value):
        raise DeckError(f"{what} is not a valid OBS id.")
    return value.lower()


def _validate_url(value):
    if not isinstance(value, str) or not value:
        raise DeckError("Enter the link to open, for example https://example.com or steam://rungameid/620.")
    try:
        scheme = urlsplit(value).scheme.lower()
    except ValueError:
        scheme = ""
    if scheme not in URL_SCHEMES:
        raise DeckError("Buttons can open web links and steam://, com.epicgames.launcher://, spotify:, "
                        "discord:// and ms-settings: links.")
    try:
        return orbit_links.validate_url(value, URL_SCHEMES)
    except ValueError as error:
        raise DeckError(str(error)) from error


def _validate_obs(value):
    request = value.get("request")
    if not isinstance(request, str) or request not in OBS_ACTIONS:
        raise DeckError("OBS buttons can switch scenes, start, stop or toggle recording, toggle streaming, start or "
                        "save the replay buffer, and mute or unmute an audio source.")
    data = value.get("data")
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise DeckError("The OBS settings of this button are not valid.")
    clean = {}
    if request == "SetCurrentProgramScene":
        if data.get("sceneName") is not None:
            clean["sceneName"] = _exact_name(data["sceneName"], "Choose the OBS scene to switch to.", "The scene name")
        if data.get("sceneUuid") is not None:
            clean["sceneUuid"] = _uuid_text(data["sceneUuid"], "The scene")
        if not clean:
            raise DeckError("Choose the OBS scene to switch to.")
    elif request == "ToggleInputMute":
        if data.get("inputName") is not None:
            clean["inputName"] = _exact_name(data["inputName"], "Choose the OBS audio source to mute or unmute.",
                                             "The audio source name")
        if data.get("inputUuid") is not None:
            clean["inputUuid"] = _uuid_text(data["inputUuid"], "The audio source")
        if not clean:
            raise DeckError("Choose the OBS audio source to mute or unmute.")
    # The other requests take no settings; anything sent with them is dropped, never passed to OBS.
    return {"type": "obs", "request": request, "data": clean}


def validate_action(value, *, inside_sequence=False):
    """The normalized copy of one action; DeckError explains what is wrong with it."""
    if not isinstance(value, dict):
        raise DeckError("Each button needs an action, such as a shortcut or a link.")
    kind = value.get("type")
    if not isinstance(kind, str) or kind not in ACTION_TYPES:
        if isinstance(kind, str) and kind:
            shown = kind if len(kind) <= 32 else kind[:32] + "…"
            raise DeckError(f"This PC's Orbit Companion doesn't know the action \"{shown}\". Update Orbit PC Companion on the PC.")
        raise DeckError("Each action needs a type, such as hotkey, text or openUrl.")
    if kind == "hotkey":
        try:
            return {"type": "hotkey", "keys": orbit_input.normalize_chord(value.get("keys"))}
        except ValueError as error:
            raise DeckError(str(error)) from error
    if kind == "text":
        text = value.get("text")
        if not isinstance(text, str) or not text:
            raise DeckError("Enter the text to type.")
        if len(text) > MAX_TEXT_LENGTH:
            raise DeckError(f"Text buttons can type at most {MAX_TEXT_LENGTH:,} characters.")
        for character in text:
            category = unicodedata.category(character)
            if category == "Cs" or (category == "Cc" and character not in "\t\n\r"):
                raise DeckError("The text contains control characters that can't be typed.")
        return {"type": "text", "text": text}
    if kind == "openUrl":
        return {"type": "openUrl", "url": _validate_url(value.get("url"))}
    if kind == "launch":
        app_id = value.get("appID")
        if not isinstance(app_id, str) or not _APP_ID.match(app_id.lower()):
            raise DeckError("Choose an app from the PC's Start menu.")
        action = {"type": "launch", "appID": app_id.lower()}
        if value.get("name") is not None:
            action["name"] = _label(value["name"], "The app name", MAX_NAME_LENGTH)
        return action
    if kind == "system":
        name = value.get("name")
        if not isinstance(name, str) or name not in SYSTEM_ACTIONS:
            raise DeckError("Choose a PC action such as lock, sleep, mute or screenshot.")
        return {"type": "system", "name": name}
    if kind == "media":
        name = value.get("name")
        if not isinstance(name, str) or name not in MEDIA_ACTIONS:
            raise DeckError("Media buttons can play/pause, skip to the next or previous track, mute, or turn the volume up or down.")
        return {"type": "media", "name": name}
    if kind == "obs":
        return _validate_obs(value)
    # sequence
    if inside_sequence:
        raise DeckError("A sequence can't contain another sequence.")
    steps = value.get("steps")
    if not isinstance(steps, list) or not steps:
        raise DeckError("Add at least one step to the sequence.")
    if len(steps) > MAX_SEQUENCE_STEPS:
        raise DeckError(f"A sequence can have at most {MAX_SEQUENCE_STEPS} steps.")
    clean_steps = []
    for index, step in enumerate(steps, 1):
        try:
            clean_steps.append(validate_action(step, inside_sequence=True))
        except DeckError as error:
            raise DeckError(f"Step {index}: {error}") from error
    if any(is_power_action(step) for step in clean_steps[:-1]):
        raise DeckError("Sleep, shut down and restart can only be the last step of a sequence.")
    delay = value.get("delayMs")
    if delay is None:
        delay = DEFAULT_DELAY_MS
    # Integers are compared as they are: math.isfinite() of a 400-digit number would overflow.
    if (isinstance(delay, bool) or not isinstance(delay, (int, float))
            or (isinstance(delay, float) and not math.isfinite(delay)) or not 0 <= delay <= MAX_DELAY_MS):
        raise DeckError(f"The pause between steps must be between 0 and {MAX_DELAY_MS:,} milliseconds.")
    return {"type": "sequence", "steps": clean_steps, "delayMs": int(round(delay))}


def is_power_action(action):
    """True for actions that sleep, shut down or restart the PC (also inside a sequence)."""
    if not isinstance(action, dict):
        return False
    if action.get("type") == "system":
        return action.get("name") in POWER_ACTIONS
    if action.get("type") == "sequence":
        return any(is_power_action(step) for step in action.get("steps") or [])
    return False


def validate_button(value, *, assign_id=True):
    """The normalized copy of one button. A missing id gets a new UUID when `assign_id` is set."""
    if not isinstance(value, dict):
        raise DeckError("Each button needs a title and an action.")
    button_id = value.get("id")
    if button_id is None or button_id == "":
        if not assign_id:
            raise DeckError("This button has no id.")
        button_id = str(uuid.uuid4()).upper()
    elif not isinstance(button_id, str) or not _BUTTON_ID.match(button_id):
        raise DeckError("Button ids must be UUIDs.")
    title = _label(value.get("title"), "The button title", MAX_TITLE_LENGTH)
    symbol = value.get("symbol")
    if symbol is None or symbol == "":
        symbol = DEFAULT_SYMBOL
    elif not isinstance(symbol, str) or len(symbol) > MAX_SYMBOL_LENGTH or not _SYMBOL.match(symbol):
        raise DeckError("The symbol must be an SF Symbol name such as mic.slash.fill.")
    color = value.get("color")
    if color is None or color == "":
        color = DEFAULT_COLOR
    elif not isinstance(color, str) or not _COLOR.match(color):
        raise DeckError("The color must be a hex color such as #FF453A.")
    confirm = value.get("confirm")
    if confirm is None:
        confirm = False
    if not isinstance(confirm, bool):
        raise DeckError("\"confirm\" must be true or false.")
    action = validate_action(value.get("action"))
    if is_power_action(action) and not confirm:
        raise DeckError("Buttons that put the PC to sleep, shut it down or restart it must ask for confirmation. "
                        "Turn on confirmation for this button.")
    return {"id": button_id, "title": title, "symbol": symbol, "color": color.upper(), "confirm": confirm,
            "action": action}


def _button_name(index, value):
    title = value.get("title") if isinstance(value, dict) else None
    if isinstance(title, str):
        title = " ".join(title.split())[:MAX_TITLE_LENGTH]
        if title and not any(unicodedata.category(character) in ("Cc", "Cs") for character in title):
            return f"Button {index} (“{title}”)"
    return f"Button {index}"


def validate_buttons(buttons):
    """The normalized deck (a list of buttons); DeckError names the first button that is wrong."""
    if not isinstance(buttons, list):
        raise DeckError("Send the buttons as a list.")
    if len(buttons) > MAX_BUTTONS:
        raise DeckError(f"A deck can have at most {MAX_BUTTONS} buttons.")
    clean, seen = [], set()
    for index, value in enumerate(buttons, 1):
        try:
            button = validate_button(value)
        except DeckError as error:
            raise DeckError(f"{_button_name(index, value)}: {error}") from error
        key = button["id"].casefold()
        if key in seen:
            raise DeckError(f"{_button_name(index, value)}: another button already uses the id {button['id']}.")
        seen.add(key)
        clean.append(button)
    if len(json.dumps(clean, ensure_ascii=False).encode("utf-8")) > MAX_DECK_BYTES:
        raise DeckError("These buttons are too large to save. Shorten the longest text buttons.")
    return clean


# MARK: - Storage

def _iso(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _parse_iso_or_none(text):
    try:
        return _parse_iso(text)
    except (ValueError, OverflowError):
        return None


class _ChangedElsewhere(Exception):
    pass


class DeckStore:
    """The deck in the settings section `deck`, re-validated whenever it is read."""

    def __init__(self, store_provider=None, clock=None):
        self._provider = store_provider or orbit_settings.shared_store
        self._clock = clock or (lambda: datetime.now(timezone.utc))

    @staticmethod
    def decode(section):
        """The saved deck; buttons that are no longer valid (a hand-edited file) are left out."""
        if not isinstance(section, dict):
            return {"buttons": [], "updatedAt": NEVER_SAVED}
        buttons, seen = [], set()
        saved = section.get("buttons")
        for value in saved if isinstance(saved, list) else []:
            if len(buttons) >= MAX_BUTTONS:
                break
            try:
                button = validate_button(value, assign_id=False)
            except DeckError as error:
                LOGGER.warning("Skipped a saved deck button that is not valid: %s", error)
                continue
            if button["id"].casefold() in seen:
                continue
            seen.add(button["id"].casefold())
            buttons.append(button)
        updated = section.get("updatedAt")
        if not isinstance(updated, str) or not _ISO_SECONDS.match(updated) or _parse_iso_or_none(updated) is None:
            updated = NEVER_SAVED  # Also impossible dates such as 2026-13-45T99:99:99Z.
        return {"buttons": buttons, "updatedAt": updated}

    def load(self):
        return self.decode(self._provider().get(SETTINGS_SECTION))

    def find(self, button_id):
        if not isinstance(button_id, str) or not _BUTTON_ID.match(button_id):
            return None
        buttons = self.load()["buttons"]
        return (next((button for button in buttons if button["id"] == button_id), None)
                or next((button for button in buttons if button["id"].casefold() == button_id.casefold()), None))

    def save(self, buttons, base_updated_at=None):
        """Replaces the deck with already validated buttons and returns the saved deck."""
        def change(current):
            previous = self.decode(current)["updatedAt"]
            if base_updated_at is not None and base_updated_at != previous:
                raise _ChangedElsewhere()
            moment = self._clock()
            if previous != NEVER_SAVED:
                # Every save gets a later time than the last one, even within the same second,
                # so baseUpdatedAt always tells two saves apart.
                try:
                    earliest = _parse_iso(previous) + timedelta(seconds=1)
                except OverflowError:  # 9999-12-31T23:59:59Z from a hand-edited file.
                    earliest = moment
                if moment < earliest:
                    moment = earliest
            return {"buttons": buttons, "updatedAt": _iso(moment)}
        try:
            saved = self._provider().modify(SETTINGS_SECTION, change)
        except _ChangedElsewhere:
            raise HTTPException(409, "The buttons were changed on another device. Reload them and try again.") from None
        except (OSError, ValueError, TypeError) as error:
            LOGGER.warning("Could not save the deck: %s", error)
            raise HTTPException(503, "The PC could not save the buttons. Try again.") from error
        return self.decode(saved)


def deck_payload(deck):
    return {"buttons": deck["buttons"], "updatedAt": deck["updatedAt"], "maxButtons": MAX_BUTTONS}


# MARK: - Opening links and shortcuts

SW_SHOWNORMAL = 1
COINIT_APARTMENTTHREADED = 0x2
COINIT_DISABLE_OLE1DDE = 0x4
ASFW_ANY = 0xFFFFFFFF
_LIBRARIES = {}


class ShellOpenError(OSError):
    """ShellExecuteW refused; `code` is its result (2 file not found, 5 access denied, 31 no app...)."""

    def __init__(self, code):
        super().__init__(f"ShellExecuteW failed with code {code}")
        self.code = code


def _library(name):
    # Private handles: prototypes set here never change the shared ctypes.windll functions.
    library = _LIBRARIES.get(name)
    if library is None:
        library = _LIBRARIES[name] = ctypes.WinDLL(name)
    return library


def shell_open(target):
    """`ShellExecuteW(NULL, "open", target, NULL, NULL, SW_SHOWNORMAL)` with COM initialized for the
    call, as Microsoft requires on threads it does not own. Raises ShellOpenError."""
    ole32, shell32, user32 = _library("ole32"), _library("shell32"), _library("user32")
    ole32.CoInitializeEx.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    ole32.CoInitializeEx.restype = ctypes.c_long
    ole32.CoUninitialize.argtypes = []
    ole32.CoUninitialize.restype = None
    shell32.ShellExecuteW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p,
                                      ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_int]
    shell32.ShellExecuteW.restype = ctypes.c_void_p  # HINSTANCE: a status code, > 32 is success
    user32.AllowSetForegroundWindow.argtypes = [ctypes.c_uint32]
    user32.AllowSetForegroundWindow.restype = ctypes.c_int
    result = ole32.CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)
    initialized = result in (0, 1)  # S_OK or S_FALSE; RPC_E_CHANGED_MODE leaves COM as it is.
    try:
        try:
            user32.AllowSetForegroundWindow(ASFW_ANY)  # Lets the app come to the front.
        except Exception:
            pass
        handle = shell32.ShellExecuteW(None, "open", target, None, None, SW_SHOWNORMAL)
    finally:
        if initialized:
            ole32.CoUninitialize()
    code = int(handle or 0)
    if code <= 32:
        raise ShellOpenError(code)


def _short_url(url, limit=80):
    scheme = urlsplit(url).scheme.lower()
    if scheme in orbit_links.WEB_SCHEMES:
        return orbit_links.display_url(url, limit)
    return url if len(url) <= limit else url[:limit - 1] + "…"


def _link_failure(url, error):
    scheme = urlsplit(url).scheme.lower()
    code = getattr(error, "code", None)
    if scheme in orbit_links.WEB_SCHEMES:
        if code == 31:
            return "Windows has no default web browser to open this link. Choose one in Windows Settings."
        return "Windows could not open this link in the default browser."
    app = _SCHEME_APPS.get(scheme, "the app for this link")
    if code in (2, 3, 31):
        return f"No app on the PC opens {scheme}: links. Install {app} and try again."
    return f"Windows could not open this link with {app}."


def _launch_failure(name, error):
    code = getattr(error, "code", None)
    if code in (2, 3):
        return f"The program behind the {name} shortcut is missing. It may have been uninstalled."
    if code == 5:
        return f"Windows refused to open {name}."
    if code == 31:
        return f"Windows has no program to open the {name} shortcut."
    return f"Windows could not open {name}."


# MARK: - Start menu shortcuts

FOLDERID_PROGRAMS = "a77f5d77-2e2b-44c3-a6a2-aba601054a51"
FOLDERID_COMMON_PROGRAMS = "0139d44e-6afe-49f2-8690-3dafcae6ffb8"
MAX_SCAN_DEPTH = 6
MAX_SCAN_FILES = 5000
MAX_APPS = 500
MAX_LINK_BYTES = 1024 * 1024
APPS_CACHE_SECONDS = 30.0
LINK_CLSID = uuid.UUID("00021401-0000-0000-c000-000000000046").bytes_le
HAS_LINK_TARGET_ID_LIST = 0x1
HAS_LINK_INFO = 0x2
HAS_NAME = 0x4
HAS_RELATIVE_PATH = 0x8
HAS_WORKING_DIR = 0x10
HAS_ARGUMENTS = 0x20
HAS_ICON_LOCATION = 0x40
IS_UNICODE = 0x80
FORCE_NO_LINK_INFO = 0x100
HAS_EXP_STRING = 0x200
HAS_EXP_ICON = 0x4000
ENVIRONMENT_BLOCK = 0xA0000001
ICON_ENVIRONMENT_BLOCK = 0xA0000007
_NOISE_NAME = re.compile(r"\b(uninstall|uninstaller|deinstall|readme|read me|release notes|licen[cs]e|eula|"
                         r"documentation|manual|changelog|website|web site|homepage|faq|help)\b", re.IGNORECASE)
_NOISE_TARGET = re.compile(r"^(unins\d*|uninst|uninstall\w*|uninstaller)\.exe$", re.IGNORECASE)
_DOCUMENT_EXTENSIONS = frozenset({".txt", ".rtf", ".pdf", ".chm", ".hlp", ".htm", ".html", ".mht", ".url",
                                  ".ini", ".log", ".md", ".xml", ".doc", ".docx", ".nfo"})


def _ansi_codec():
    for name in ("mbcs", "cp1252"):  # mbcs (the PC's ANSI code page) exists only on Windows.
        try:
            codecs.lookup(name)
            return name
        except LookupError:
            pass
    return "latin-1"


_ANSI = _ansi_codec()


@dataclass(frozen=True)
class ShortcutInfo:
    target: str | None
    arguments: str | None
    icon_path: str | None
    icon_index: int


def _ansi_string(buffer, offset):
    if offset <= 0 or offset >= len(buffer):
        return ""
    end = buffer.find(b"\0", offset)
    return buffer[offset:end if end >= 0 else len(buffer)].decode(_ANSI, "replace")


def _unicode_string(buffer, offset):
    if offset <= 0 or offset >= len(buffer):
        return ""
    end = offset
    while end + 1 < len(buffer) and buffer[end:end + 2] != b"\0\0":
        end += 2
    return buffer[offset:end].decode("utf-16-le", "replace")


def _link_info_path(info):
    """LocalBasePath + CommonPathSuffix from a LinkInfo structure ([MS-SHLLINK] 2.3)."""
    header_size, flags, _volume, base_offset, _network, suffix_offset = struct.unpack_from("<IIIIII", info, 4)
    if not flags & 0x1:  # VolumeIDAndLocalBasePath: a network-only link has no local path.
        return None
    base = suffix = ""
    if header_size >= 0x24 and len(info) >= 36:
        base_unicode, suffix_unicode = struct.unpack_from("<II", info, 28)
        base = _unicode_string(info, base_unicode)
        suffix = _unicode_string(info, suffix_unicode)
    if not base:
        base = _ansi_string(info, base_offset)
        suffix = _ansi_string(info, suffix_offset)
    return (base + suffix) or None


def _expand(text):
    text = (text or "").strip().strip('"').strip()
    return ntpath.expandvars(text) if text else None


def parse_shortcut(data, directory=None):
    """Target, arguments and icon of a `.lnk` file ([MS-SHLLINK]). ValueError when it is not one."""
    if len(data) < 76:
        raise ValueError("Too short for a shell link")
    header_size, clsid, flags = struct.unpack_from("<I16sI", data, 0)
    if header_size != 0x4C or clsid != LINK_CLSID:
        raise ValueError("Not a shell link")
    (icon_index,) = struct.unpack_from("<i", data, 56)
    offset = 76
    if flags & HAS_LINK_TARGET_ID_LIST:
        (size,) = struct.unpack_from("<H", data, offset)
        offset += 2 + size
    local_path = None
    if flags & HAS_LINK_INFO:
        (size,) = struct.unpack_from("<I", data, offset)
        if size < 0x1C or offset + size > len(data):
            raise ValueError("Damaged link information")
        if not flags & FORCE_NO_LINK_INFO:
            local_path = _link_info_path(data[offset:offset + size])
        offset += size
    unicode = bool(flags & IS_UNICODE)
    strings = {}
    for flag, key in ((HAS_NAME, "name"), (HAS_RELATIVE_PATH, "relative"), (HAS_WORKING_DIR, "directory"),
                      (HAS_ARGUMENTS, "arguments"), (HAS_ICON_LOCATION, "icon")):
        if flags & flag:
            (count,) = struct.unpack_from("<H", data, offset)
            offset += 2
            length = count * 2 if unicode else count
            if offset + length > len(data):
                raise ValueError("Damaged link strings")
            raw = data[offset:offset + length]
            strings[key] = raw.decode("utf-16-le", "replace") if unicode else raw.decode(_ANSI, "replace")
            offset += length
    blocks = {}
    while offset + 8 <= len(data):
        (size,) = struct.unpack_from("<I", data, offset)
        if size < 8 or offset + size > len(data):
            break  # The terminal block (size < 4) or a damaged one.
        (signature,) = struct.unpack_from("<I", data, offset + 4)
        blocks.setdefault(signature, data[offset + 8:offset + size])
        offset += size

    def environment_target(signature):
        block = blocks.get(signature)
        if not block or len(block) < 260:
            return None
        text = block[260:780].decode("utf-16-le", "replace").split("\0", 1)[0] if len(block) >= 780 else ""
        if not text:
            text = block[:260].split(b"\0", 1)[0].decode(_ANSI, "replace")
        return text or None

    target = _expand(environment_target(ENVIRONMENT_BLOCK)) if flags & HAS_EXP_STRING else None
    target = target or local_path
    if not target and strings.get("relative") and directory:
        target = os.path.normpath(os.path.join(directory, strings["relative"].replace("\\", os.sep)))
    icon_path, index = None, icon_index
    if flags & HAS_EXP_ICON:
        icon_path = _expand(environment_target(ICON_ENVIRONMENT_BLOCK))
    if not icon_path and strings.get("icon"):
        icon_path = _expand(strings["icon"])
    if not icon_path:
        icon_path, index = target, 0
    return ShortcutInfo(target=target or None, arguments=strings.get("arguments") or None,
                        icon_path=icon_path or None, icon_index=index)


def read_shortcut(path):
    """parse_shortcut for a file; None when it cannot be read or is not a shell link."""
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_LINK_BYTES + 1)
    except OSError:
        return None
    if len(data) > MAX_LINK_BYTES:
        return None
    try:
        return parse_shortcut(data, os.path.dirname(path))
    except (struct.error, ValueError, IndexError):
        return None


def _environment(*names):
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def start_menu_folders():
    """The signed-in user's Start menu Programs folder, then the one for all users."""
    folders = []
    for identifier, variables in ((FOLDERID_PROGRAMS, ("APPDATA",)),
                                  (FOLDERID_COMMON_PROGRAMS, ("PROGRAMDATA", "ProgramData", "ALLUSERSPROFILE"))):
        path = None
        try:
            path = orbit_files._known_folder(identifier)
        except Exception:
            path = None
        if not path:
            base = _environment(*variables)
            if base:
                path = os.path.join(base, "Microsoft", "Windows", "Start Menu", "Programs")
        if path and os.path.isdir(path) and path not in folders:
            folders.append(path)
    return folders


def app_id_for(path):
    """The stable ID of a shortcut: the SHA-1 of its normalized path (case-insensitive like Windows)."""
    normalized = os.path.normpath(str(path)).casefold()
    return hashlib.sha1(normalized.encode("utf-8", "surrogatepass")).hexdigest()


def _is_noise(name, info):
    if _NOISE_NAME.search(name):
        return True
    target = info.target if info else None
    if target:
        file_name = ntpath.basename(target.replace("/", "\\"))
        if _NOISE_TARGET.match(file_name) or ntpath.splitext(file_name)[1].casefold() in _DOCUMENT_EXTENSIONS:
            return True
    return False


@dataclass(frozen=True)
class StartMenuApp:
    id: str
    name: str
    path: str = field(repr=False)
    folder: str | None = None
    icon: tuple | None = field(default=None, repr=False)


def scan_start_menu(folders):
    """Every app shortcut in the given Start menu folders, sorted by name. The first folder wins
    when both have a shortcut at the same place (Windows shows it once too)."""
    apps, seen, visited = [], set(), 0
    for root in folders:
        root = os.path.normpath(str(root))
        for directory, subdirectories, files in os.walk(root, followlinks=False):
            relative = os.path.relpath(directory, root)
            depth = 0 if relative == os.curdir else relative.count(os.sep) + 1
            if depth >= MAX_SCAN_DEPTH:
                subdirectories[:] = []
            subdirectories.sort(key=str.casefold)
            for file_name in sorted(files, key=str.casefold):
                visited += 1
                if visited > MAX_SCAN_FILES or len(apps) >= MAX_APPS:
                    LOGGER.warning("The Start menu has more shortcuts than Orbit lists; some were left out")
                    return sorted(apps, key=lambda app: (app.name.casefold(), app.folder or ""))
                if not file_name.casefold().endswith(".lnk"):
                    continue
                name = file_name[:-4].strip()
                key = os.path.normpath(os.path.join(relative, file_name)).casefold()
                if not name or key in seen:
                    continue
                path = os.path.join(directory, file_name)
                info = read_shortcut(path)
                if _is_noise(name, info):
                    continue
                seen.add(key)
                icon = (info.icon_path, info.icon_index) if info and info.icon_path else None
                folder = None if relative == os.curdir else os.path.basename(directory)
                apps.append(StartMenuApp(id=app_id_for(path), name=name, path=path, folder=folder, icon=icon))
    return sorted(apps, key=lambda app: (app.name.casefold(), app.folder or ""))


class StartMenuApps:
    """The Start menu shortcuts, rescanned at most every APPS_CACHE_SECONDS."""

    def __init__(self, folders_provider=None, clock=time.monotonic, cache_seconds=APPS_CACHE_SECONDS):
        self._folders = folders_provider or start_menu_folders
        self._clock = clock
        self._cache_seconds = cache_seconds
        self._lock = threading.Lock()
        self._apps = None
        self._scanned = 0.0

    def list(self, refresh=False):
        with self._lock:
            if refresh or self._apps is None or self._clock() - self._scanned > self._cache_seconds:
                self._apps = scan_start_menu(self._folders())
                self._scanned = self._clock()
            return list(self._apps)

    def find(self, app_id):
        if not isinstance(app_id, str) or not _APP_ID.match(app_id):
            return None
        for refresh in (False, True):  # A shortcut added or removed a moment ago needs a fresh scan.
            app = next((app for app in self.list(refresh=refresh) if app.id == app_id), None)
            if app is not None and os.path.isfile(app.path):
                return app
        return None

    def payload(self):
        rows = []
        for app in self.list():
            icon_id = None
            if app.icon:
                try:
                    icon_id = orbit_icons.ICONS.register(*app.icon)
                except Exception:
                    icon_id = None
            rows.append({"id": app.id, "name": app.name, "iconID": icon_id, "folder": app.folder})
        return {"apps": rows}


# MARK: - OBS Studio (obs-websocket 5)

OBS_DEFAULT_PORT = 4455
# Windows takes about two seconds to refuse a connection to a closed local port; wait longer than
# that, so a closed OBS reads as "not running" and not as a timeout.
OBS_OPEN_TIMEOUT = 3.0
OBS_REPLY_TIMEOUT = 3.0
OBS_SESSION_TIMEOUT = 6.0
OBS_SUBPROTOCOL = "obswebsocket.json"
OBS_PROCESS_NAMES = frozenset({"obs64.exe", "obs32.exe", "obs.exe"})
MAX_OBS_FILE_BYTES = 256 * 1024
MAX_OBS_MESSAGES = 200
MAX_OBS_LIST = 200
OBS_NOT_INSTALLED = "OBS Studio isn't installed on this PC."
OBS_NOT_SET_UP = ("Open OBS Studio 28 or later on the PC, then turn on its WebSocket server in "
                  "Tools → WebSocket Server Settings.")
OBS_SERVER_OFF = ("OBS's WebSocket server is turned off. On the PC, open OBS, choose Tools → WebSocket Server "
                  "Settings and turn on Enable WebSocket server.")
OBS_NOT_RUNNING = "OBS Studio isn't running on the PC. Start it and try again."
OBS_NOT_ANSWERING = ("OBS is running, but its WebSocket server isn't answering on port {port}. Check Tools → "
                     "WebSocket Server Settings in OBS.")
OBS_TIMEOUT = "OBS didn't answer in time. It may be busy or showing a dialog on the PC."
OBS_AUTH_FAILED = ("OBS didn't accept the WebSocket password saved in its settings. If OBS was started with "
                   "--websocket_password, remove that option, or set the password again in Tools → WebSocket "
                   "Server Settings.")
OBS_PASSWORD_UNKNOWN = ("OBS asks for a WebSocket password that isn't saved in its settings (it may have been "
                        "started with --websocket_password). Remove that option or set a password in Tools → "
                        "WebSocket Server Settings.")
OBS_UNSUPPORTED = "This version of OBS uses a WebSocket protocol Orbit doesn't support. Update OBS Studio."
OBS_NOT_OBS = ("Something on OBS's WebSocket port {port} isn't answering like OBS. Check the port in Tools → "
               "WebSocket Server Settings in OBS.")
OBS_CLOSED = "OBS closed the connection unexpectedly. Try again."
OBS_PACKAGES = ("OBS buttons need newer Python packages on the PC. Run install_orbit.bat again in the Orbit PC "
                "Companion folder to update them.")


class OBSUnavailable(Exception):
    """OBS can't be reached or refused Orbit; `reason` is a sentence for the user."""

    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


@dataclass(frozen=True)
class OBSSettings:
    found: bool
    enabled: bool = False
    port: int = OBS_DEFAULT_PORT
    auth_required: bool = True
    password: str | None = field(default=None, repr=False)  # never logged or sent to a device
    source: str | None = None


def obs_authentication(password, salt, challenge):
    """obs-websocket 5's authentication string: base64(sha256(base64(sha256(password + salt)) + challenge))."""
    secret = base64.b64encode(hashlib.sha256((password + salt).encode("utf-8")).digest()).decode("ascii")
    return base64.b64encode(hashlib.sha256((secret + challenge).encode("utf-8")).digest()).decode("ascii")


def obs_studio_folder():
    appdata = _environment("APPDATA")
    return Path(appdata) / "obs-studio" if appdata else None


def _read_small_text(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_OBS_FILE_BYTES + 1)
    except OSError:
        return None
    if len(data) > MAX_OBS_FILE_BYTES:
        return None
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None


def _flag(value, default):
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.strip().lower() in ("true", "false", "1", "0"):
        return value.strip().lower() in ("true", "1")
    if isinstance(value, int):
        return value != 0
    return default


def _port(value):
    try:
        port = int(value)
    except (TypeError, ValueError):
        return OBS_DEFAULT_PORT
    return port if 1 <= port <= 65535 else OBS_DEFAULT_PORT


def load_obs_settings(folder=None):
    """obs-websocket's settings from OBS's own files (config.json; global.ini before OBS 30)."""
    folder = obs_studio_folder() if folder is None else Path(folder)
    if folder is None:
        return OBSSettings(found=False)
    text = _read_small_text(folder / "plugin_config" / "obs-websocket" / "config.json")
    if text is not None:
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if isinstance(data, dict):
            password = data.get("server_password")
            return OBSSettings(found=True, enabled=_flag(data.get("server_enabled"), False),
                               port=_port(data.get("server_port")), auth_required=_flag(data.get("auth_required"), True),
                               password=password if isinstance(password, str) and password else None,
                               source="config.json")
    text = _read_small_text(folder / "global.ini")
    if text is not None:
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        try:
            parser.read_string(text)
        except configparser.Error:
            parser = None
        if parser is not None and parser.has_section("OBSWebSocket"):
            section = parser["OBSWebSocket"]
            return OBSSettings(found=True, enabled=_flag(section.get("ServerEnabled"), False),
                               port=_port(section.get("ServerPort")), auth_required=_flag(section.get("AuthRequired"), True),
                               password=section.get("ServerPassword") or None, source="global.ini")
    return OBSSettings(found=False)


def obs_running():
    try:
        return any((process.info.get("name") or "").casefold() in OBS_PROCESS_NAMES
                   for process in psutil.process_iter(["name"]))
    except Exception:
        return False


def _registry_install_path():
    if winreg is None:
        return None
    for path in (r"SOFTWARE\OBS Studio", r"SOFTWARE\WOW6432Node\OBS Studio"):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as key:
                value, _ = winreg.QueryValueEx(key, "")
        except (OSError, AttributeError, TypeError):
            continue
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def obs_installed(settings, folder=None):
    """Whether OBS Studio is on this PC: its settings, its program folder, the registry or a running OBS."""
    if settings.found:
        return True
    folder = obs_studio_folder() if folder is None else Path(folder)
    if folder is not None and folder.is_dir():
        return True
    for base in (_environment("ProgramW6432", "PROGRAMW6432"), _environment("ProgramFiles", "PROGRAMFILES"),
                 _environment("ProgramFiles(x86)", "PROGRAMFILES(X86)")):
        if base and (Path(base) / "obs-studio" / "bin" / "64bit" / "obs64.exe").is_file():
            return True
    if _registry_install_path():
        return True
    return obs_running()


@dataclass(frozen=True)
class OBSResult:
    ok: bool
    code: int | None
    comment: str | None
    data: dict


def _close_code(error):
    for attribute in ("rcvd", "sent"):
        frame = getattr(error, attribute, None)
        code = getattr(frame, "code", None) if frame is not None else None
        if code is not None:
            return code
    return None


def _obs_unavailable(error, port, connecting=False):
    """The OBSUnavailable (with a reason for the user) for an error from talking to OBS.

    `connecting` is set while the WebSocket connection itself is being opened: a timeout then
    means nothing answered on the port, like a refused connection."""
    if isinstance(error, OBSUnavailable):
        return error
    try:
        from websockets.exceptions import ConnectionClosed, InvalidHandshake
    except ImportError:
        ConnectionClosed = InvalidHandshake = ()
    if ConnectionClosed and isinstance(error, ConnectionClosed):
        code = _close_code(error)
        if code == 4009:
            return OBSUnavailable(409, OBS_AUTH_FAILED)
        if code == 4010:
            return OBSUnavailable(502, OBS_UNSUPPORTED)
        return OBSUnavailable(502, OBS_CLOSED)
    if InvalidHandshake and isinstance(error, InvalidHandshake):
        return OBSUnavailable(502, OBS_NOT_OBS.format(port=port))
    if isinstance(error, TimeoutError) and not connecting:
        return OBSUnavailable(504, OBS_TIMEOUT)
    if isinstance(error, OSError):
        if obs_running():
            return OBSUnavailable(503, OBS_NOT_ANSWERING.format(port=port))
        return OBSUnavailable(503, OBS_NOT_RUNNING)
    if isinstance(error, (ValueError, TypeError, KeyError)):
        return OBSUnavailable(502, OBS_NOT_OBS.format(port=port))
    LOGGER.warning("Unexpected error while talking to OBS: %r", error)
    return OBSUnavailable(502, OBS_CLOSED)


class OBSSession:
    """One identified obs-websocket 5 connection that sends only allowlisted requests.

    Every failure while talking to OBS comes out as OBSUnavailable with a reason for the user."""

    def __init__(self, connection, deadline, port=OBS_DEFAULT_PORT, closer=None):
        self._connection = connection
        self._deadline = deadline
        self._port = port
        self._closer = closer or connection.close

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        try:
            self._closer()
        except Exception:
            pass

    def send(self, message):
        try:
            self._connection.send(json.dumps(message))
        except Exception as error:
            raise _obs_unavailable(error, self._port) from None

    def receive(self):
        try:
            remaining = self._deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("OBS did not answer in time")
            raw = self._connection.recv(timeout=min(remaining, OBS_REPLY_TIMEOUT))
            if not isinstance(raw, str):
                raise OBSUnavailable(502, OBS_UNSUPPORTED)  # MessagePack or another binary format.
            message = json.loads(raw)
            if (not isinstance(message, dict) or isinstance(message.get("op"), bool)
                    or not isinstance(message.get("op"), int)):
                raise ValueError("Not an obs-websocket message")
            return message
        except Exception as error:
            raise _obs_unavailable(error, self._port) from None

    def receive_op(self, op):
        for _ in range(MAX_OBS_MESSAGES):
            message = self.receive()
            if message["op"] == op:
                data = message.get("d")
                if not isinstance(data, dict):
                    raise OBSUnavailable(502, OBS_NOT_OBS.format(port=self._port))
                return data
            if message["op"] != 5:  # Events are skipped (Orbit subscribes to none).
                raise OBSUnavailable(502, OBS_NOT_OBS.format(port=self._port))
        raise OBSUnavailable(502, OBS_NOT_OBS.format(port=self._port))

    def identify(self, settings):
        hello = self.receive_op(0)
        identify = {"rpcVersion": 1, "eventSubscriptions": 0}
        authentication = hello.get("authentication")
        if authentication is not None:
            if not isinstance(authentication, dict) or not isinstance(authentication.get("salt"), str) \
                    or not isinstance(authentication.get("challenge"), str):
                raise OBSUnavailable(502, OBS_NOT_OBS.format(port=self._port))
            if not settings.password:
                raise OBSUnavailable(409, OBS_PASSWORD_UNKNOWN)
            identify["authentication"] = obs_authentication(settings.password, authentication["salt"],
                                                            authentication["challenge"])
        self.send({"op": 1, "d": identify})
        self.receive_op(2)

    def request(self, request_type, data=None):
        if request_type not in OBS_ALLOWED_REQUESTS:
            raise ValueError(f"{request_type} is not a request Orbit sends to OBS")
        request_id = uuid.uuid4().hex
        payload = {"requestType": request_type, "requestId": request_id}
        if data:
            payload["requestData"] = data
        self.send({"op": 6, "d": payload})
        for _ in range(MAX_OBS_MESSAGES):
            reply = self.receive_op(7)
            if reply.get("requestId") != request_id:
                continue
            status = reply.get("requestStatus") if isinstance(reply.get("requestStatus"), dict) else {}
            code = status.get("code")
            comment = status.get("comment")
            response = reply.get("responseData")
            return OBSResult(ok=status.get("result") is True,
                             code=code if isinstance(code, int) and not isinstance(code, bool) else None,
                             comment=orbit_notify.clean_text(comment, 300) if isinstance(comment, str) and comment else None,
                             data=response if isinstance(response, dict) else {})
        raise OBSUnavailable(502, OBS_NOT_OBS.format(port=self._port))


def _connect_options(connect):
    try:
        parameters = inspect.signature(connect).parameters
    except (TypeError, ValueError):
        parameters = {}
    wanted = {"open_timeout": OBS_OPEN_TIMEOUT, "close_timeout": 1, "max_size": 4 * 1024 * 1024,
              "compression": None, "ping_interval": None,
              # websockets 15+ would otherwise use a proxy configured for the system, even for 127.0.0.1.
              "proxy": None}
    return {name: value for name, value in wanted.items() if name in parameters}


def open_obs_session(settings, timeout=OBS_SESSION_TIMEOUT):
    """An identified session with OBS on 127.0.0.1; raises OBSUnavailable with a reason."""
    try:
        from websockets.sync.client import connect
        from websockets.exceptions import InvalidHandshake
    except ImportError as error:
        raise OBSUnavailable(503, OBS_PACKAGES) from error
    uri = f"ws://127.0.0.1:{settings.port}"
    options = _connect_options(connect)
    deadline = time.monotonic() + timeout
    # connect() is entered as a context manager (websockets 17 requires it; older versions return
    # the connection itself, which is a context manager too). The stack closes it with the session.
    stack = contextlib.ExitStack()
    connecting = True
    try:
        try:
            connection = stack.enter_context(connect(uri, subprotocols=[OBS_SUBPROTOCOL], **options))
        except InvalidHandshake:
            # obs-websocket uses JSON when no subprotocol is offered; a server that refuses the offer
            # (or picks something else) gets one more try without it.
            connection = stack.enter_context(connect(uri, **options))
        connecting = False
        if getattr(connection, "subprotocol", None) not in (None, OBS_SUBPROTOCOL):
            raise OBSUnavailable(502, OBS_UNSUPPORTED)
        session = OBSSession(connection, deadline, settings.port, closer=stack.close)
        session.identify(settings)
        return session
    except Exception as error:
        try:
            stack.close()
        except Exception:
            pass
        raise _obs_unavailable(error, settings.port, connecting) from None


def _obs_name(data, key):
    value = data.get(key)
    return value if isinstance(value, str) and value else None


def _obs_failure(request, data, result):
    code = result.code
    scene = data.get("sceneName") or "this scene"
    source = data.get("inputName") or "this source"
    if code == 207:
        return "OBS is busy (it may be switching scene collections or closing). Try again in a moment."
    if request == "SetCurrentProgramScene" and code == 600:
        return f"OBS has no scene called “{scene}”. Edit the button and choose the scene again."
    if request == "ToggleInputMute" and code == 600:
        return f"OBS has no audio source called “{source}”. Edit the button and choose it again."
    if request == "ToggleInputMute" and code in (604, 605):  # obs-websocket answers 604 (InvalidResourceState).
        return f"“{source}” in OBS has no audio to mute."
    if request == "StartRecord" and code == 500:
        return "OBS is already recording."
    if request == "StopRecord" and code == 501:
        return "OBS isn't recording."
    if request == "StartReplayBuffer" and code == 500:
        return "The replay buffer is already running in OBS."
    if request in ("SaveReplayBuffer", "StartReplayBuffer") and code in (504, 604):
        return "The replay buffer is turned off in OBS. Turn it on in Settings → Output → Replay Buffer."
    if request == "SaveReplayBuffer" and code == 501:
        return "The replay buffer isn't running in OBS. Start it first, for example with a Start Replay Buffer button."
    if result.comment:
        return f"OBS couldn't do that: {result.comment}"
    return f"OBS couldn't do that (code {code})." if code is not None else "OBS couldn't do that."


def _obs_detail(request, data, result):
    active = result.data.get("outputActive")
    if request == "SetCurrentProgramScene":
        return f"Switched to {data.get('sceneName') or 'the scene'}"
    if request == "StartRecord":
        return "Recording started"
    if request == "StopRecord":
        path = result.data.get("outputPath")
        if isinstance(path, str) and path:
            return f"Recording saved as {orbit_notify.clean_text(ntpath.basename(path), 120)}"
        return "Recording stopped"
    if request == "ToggleRecord":
        return {True: "Recording started", False: "Recording stopped"}.get(active, "Toggled recording")
    if request == "ToggleStream":
        return {True: "Streaming started", False: "Streaming stopped"}.get(active, "Toggled streaming")
    if request == "SaveReplayBuffer":
        return "Replay saved"
    if request == "StartReplayBuffer":
        return "Replay buffer started"
    muted = result.data.get("inputMuted")
    source = data.get("inputName") or "the audio source"
    return {True: f"Muted {source}", False: f"Unmuted {source}"}.get(muted, f"Toggled mute for {source}")


class OBSController:
    """OBS status and OBS buttons; every call opens a short session and closes it again."""

    def __init__(self, settings_loader=None, session_opener=None, installed=None):
        self._load = settings_loader or load_obs_settings
        self._open = session_opener or open_obs_session
        self._installed = installed or obs_installed

    def _ready_settings(self):
        """Settings that allow a connection, or OBSUnavailable explaining why not."""
        settings = self._load()
        if not settings.found:
            raise OBSUnavailable(409, OBS_NOT_SET_UP if self._installed(settings) else OBS_NOT_INSTALLED)
        if not settings.enabled:
            raise OBSUnavailable(409, OBS_SERVER_OFF)
        return settings

    def status(self):
        result = {"installed": False, "enabled": False, "connected": False, "scenes": [], "currentScene": None,
                  "recording": False, "streaming": False, "replayBuffer": False, "inputs": [], "reason": None}
        settings = self._load()
        result["installed"] = bool(self._installed(settings))
        result["enabled"] = settings.found and settings.enabled
        try:
            settings = self._ready_settings()
            with self._open(settings) as session:
                scenes = session.request("GetSceneList")
                record = session.request("GetRecordStatus")
                stream = session.request("GetStreamStatus")
                replay = session.request("GetReplayBufferStatus")
                inputs = session.request("GetInputList")
        except OBSUnavailable as error:
            result["reason"] = error.reason
            return result
        result["connected"] = True
        if scenes.ok:
            listed = [scene for scene in scenes.data.get("scenes") or [] if isinstance(scene, dict)
                      and isinstance(scene.get("sceneName"), str)]
            # OBS lists scenes bottom-up (sceneIndex 0 is the last one in its Scenes dock).
            listed.sort(key=lambda scene: scene.get("sceneIndex") if isinstance(scene.get("sceneIndex"), int) else -1,
                        reverse=True)
            result["scenes"] = [scene["sceneName"] for scene in listed][:MAX_OBS_LIST]
            result["currentScene"] = _obs_name(scenes.data, "currentProgramSceneName")
        result["recording"] = record.ok and record.data.get("outputActive") is True
        result["streaming"] = stream.ok and stream.data.get("outputActive") is True
        result["replayBuffer"] = replay.ok and replay.data.get("outputActive") is True
        if inputs.ok:
            result["inputs"] = [item["inputName"] for item in inputs.data.get("inputs") or []
                                if isinstance(item, dict) and isinstance(item.get("inputName"), str)][:MAX_OBS_LIST]
        return result

    def run(self, request, data):
        if request not in OBS_ACTIONS:
            raise HTTPException(422, "Orbit doesn't send this request to OBS.")
        try:
            settings = self._ready_settings()
            with self._open(settings) as session:
                result = self._send(session, request, data)
        except OBSUnavailable as error:
            raise HTTPException(error.status, error.reason) from None
        if not result.ok:
            raise HTTPException(409, _obs_failure(request, data, result))
        return _obs_detail(request, data, result)

    @staticmethod
    def _send(session, request, data):
        if request == "SetCurrentProgramScene":
            name, scene_id = data.get("sceneName"), data.get("sceneUuid")
            if scene_id:
                result = session.request(request, {"sceneUuid": scene_id})
                # OBS before 30 has no scene ids, and an id goes stale when the scene is recreated.
                if result.ok or not name or result.code not in (300, 400, 401, 600):
                    return result
            return session.request(request, {"sceneName": name})
        if request == "ToggleInputMute":
            name, input_id = data.get("inputName"), data.get("inputUuid")
            if input_id:
                result = session.request(request, {"inputUuid": input_id})
                if result.ok or not name or result.code not in (300, 400, 401, 600):
                    return result
            return session.request(request, {"inputName": name})
        return session.request(request)


# MARK: - Running buttons

def _typing_text(text):
    # A line break is the Enter key (VkKeyScanW maps "\n" to Ctrl+Enter).
    return text.replace("\r\n", "\r").replace("\n", "\r")


class DeckRunner:
    """Runs validated actions. Windows work goes through the callables the agent passes in."""

    def __init__(self, *, perform_action, type_text, apps, obs, open_target=None, sleep=time.sleep,
                 open_wait=OPEN_WAIT_SECONDS):
        self._perform_action = perform_action
        self._type_text = type_text
        self._apps = apps
        self._obs = obs
        self._open = open_target or shell_open
        self._sleep = sleep
        self._open_wait = open_wait
        self._pending_opens = threading.BoundedSemaphore(MAX_PENDING_OPENS)

    def run(self, action, *, confirmed):
        if is_power_action(action) and not confirmed:
            raise HTTPException(428, "This button sleeps, shuts down or restarts the PC. Confirm it on your device first.")
        if action["type"] == "sequence":
            return self._run_sequence(action)
        return self._run_step(action)

    def _run_sequence(self, action):
        steps, delay = action["steps"], action["delayMs"] / 1000
        for index, step in enumerate(steps):
            if index and delay:
                self._sleep(delay)
            try:
                self._run_step(step)
            except HTTPException as error:
                reason = str(error.detail).strip()
                if reason and reason[-1] not in ".!?":
                    reason += "."
                earlier = " The steps before it ran." if index else ""
                raise HTTPException(error.status_code,
                                    f"Step {index + 1} of {len(steps)} didn't work: {reason}{earlier}") from error
        return f"Ran {len(steps)} step{'s' if len(steps) != 1 else ''}"

    def _open_soon(self, target, what):
        """Opens `target` on a short-lived thread (with its own COM apartment, see shell_open).

        True when Windows finished within `open_wait` seconds (its error is raised here as usual);
        False while it is still busy, typically because a UAC prompt or an "open with" question on
        the PC waits for an answer. The thread then finishes on its own and only logs the outcome.
        `what` names the target in the log (an app name or "a link", never the link itself).
        """
        if not self._pending_opens.acquire(blocking=False):
            raise HTTPException(429, "Windows on the PC is still waiting for an answer about something you opened "
                                     "earlier. Answer it on the PC, then try again.")
        lock, finished, state = threading.Lock(), threading.Event(), {"done": False, "late": False, "error": None}

        def work():
            error = None
            try:
                self._open(target)
            except Exception as caught:
                error = caught
            finally:
                self._pending_opens.release()
            with lock:
                state.update(done=True, error=error)
                late = state["late"]
            finished.set()
            if late:
                if error is None:
                    LOGGER.info("Opened %s after Windows asked on the PC", what)
                else:
                    LOGGER.warning("Could not open %s after Windows asked on the PC: %s", what, error)

        try:
            threading.Thread(target=work, name="orbit-deck-open", daemon=True).start()
        except RuntimeError as error:  # No thread could be started.
            self._pending_opens.release()
            raise HTTPException(503, "The PC is too busy to open this right now. Try again.") from error
        finished.wait(self._open_wait)
        with lock:
            if not state["done"]:
                state["late"] = True
                return False
            error = state["error"]
        if error is not None:
            raise error
        return True

    def _run_step(self, action):
        kind = action["type"]
        if kind == "hotkey":
            try:
                keys = orbit_input.press_chord(action["keys"])
            except ValueError as error:
                raise HTTPException(422, str(error)) from error
            except OSError as error:
                raise HTTPException(503, str(error) or "Windows did not accept the shortcut.") from error
            return f"Pressed {orbit_input.chord_label(keys)}"
        if kind == "text":
            self._type_text(_typing_text(action["text"]))
            count = len(action["text"])
            return f"Typed {count} character{'s' if count != 1 else ''}"
        if kind == "openUrl":
            url = _validate_url(action["url"])
            try:
                opened = self._open_soon(url, "a link")
            except OSError as error:
                raise HTTPException(503, _link_failure(url, error)) from error
            if not opened:
                return "Windows is still opening the link. If the PC asks which app to use, answer it there."
            return f"Opened {_short_url(url)}"
        if kind == "launch":
            app = self._apps.find(action["appID"])
            if app is None:
                name = action.get("name") or "This app"
                raise HTTPException(404, f"{name} is no longer in the PC's Start menu. Edit the button and choose the app again.")
            try:
                opened = self._open_soon(app.path, app.name)
            except OSError as error:
                raise HTTPException(503, _launch_failure(app.name, error)) from error
            if not opened:
                # Programs that need administrator rights wait for the UAC prompt on the PC.
                return f"Windows is still opening {app.name}. If the PC asks for permission, answer it there."
            return f"Opened {app.name}"
        if kind == "system":
            self._perform_action(action["name"])
            return SYSTEM_DETAILS[action["name"]]
        if kind == "media":
            self._perform_action(MEDIA_ACTIONS[action["name"]])
            return MEDIA_DETAILS[action["name"]]
        if kind == "obs":
            return self._obs.run(action["request"], action["data"])
        raise HTTPException(422, "A sequence can't contain another sequence.")


# MARK: - Routes

async def read_json_body(request, *, limit=MAX_BODY_BYTES, allow_empty=False):
    """The request's JSON body, read with a size limit (413 when larger)."""
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > limit:
        raise HTTPException(413, "This request is too large.")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise HTTPException(413, "This request is too large.")
    if not bytes(body).strip():
        if allow_empty:
            return None
        raise HTTPException(422, "The request has no JSON body.")
    try:
        return json.loads(bytes(body).decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise HTTPException(422, "The request body isn't valid JSON.") from None


def create_deck_router(verify_control, require_secure, *, require_windows, perform_action, type_text,
                       boot_mode=None, store=None, apps=None, obs=None, runner=None):
    """The deck routes behind the main token and the encrypted connection.

    `perform_action(name)` and `type_text(text)` are the agent's own (they raise HTTPException);
    `boot_mode()` is true for the instance that runs before anyone signs in.
    """
    store = store or DeckStore()
    apps = apps or StartMenuApps()
    obs = obs or OBSController()
    runner = runner or DeckRunner(perform_action=perform_action, type_text=type_text, apps=apps, obs=obs)
    is_boot_instance = boot_mode or (lambda: False)
    gate = threading.BoundedSemaphore(MAX_CONCURRENT_RUNS)

    def private(response: Response):
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control), Depends(require_secure), Depends(private)])

    def execute(action, confirmed):
        require_windows()
        if is_boot_instance():
            raise HTTPException(409, "Sign in to Windows on the PC first. Buttons work on the signed-in desktop.")
        if not gate.acquire(blocking=False):
            raise HTTPException(429, "The PC is still running other buttons. Try again in a moment.")
        try:
            detail = runner.run(action, confirmed=confirmed)
        finally:
            gate.release()
        return {"status": "done", "detail": detail}

    @router.get("/deck")
    def get_deck():
        return deck_payload(store.load())

    @router.put("/deck")
    async def put_deck(request: Request):
        body = await read_json_body(request)
        if not isinstance(body, dict) or "buttons" not in body:
            raise HTTPException(422, "Send the deck as {\"buttons\": [...]}.")
        base = body.get("baseUpdatedAt")
        if base is not None and not isinstance(base, str):
            raise HTTPException(422, "baseUpdatedAt must be the updatedAt text from GET /api/deck.")
        try:
            buttons = validate_buttons(body["buttons"])
        except DeckError as error:
            raise HTTPException(422, str(error)) from None
        return deck_payload(await run_in_threadpool(store.save, buttons, base))

    @router.post("/deck/run")
    async def run_action(request: Request):
        body = await read_json_body(request)
        if not isinstance(body, dict):
            raise HTTPException(422, "Send the action as {\"action\": {...}}.")
        try:
            action = validate_action(body.get("action"))
        except DeckError as error:
            raise HTTPException(422, str(error)) from None
        confirm = body.get("confirm")
        if confirm is not None and not isinstance(confirm, bool):
            raise HTTPException(422, "\"confirm\" must be true or false.")
        return await run_in_threadpool(execute, action, confirm is True)

    @router.post("/deck/buttons/{button_id}/run")
    async def run_button(button_id: str, request: Request):
        await read_json_body(request, allow_empty=True)  # No body is needed; a large one is refused.
        button = await run_in_threadpool(store.find, button_id)
        if button is None:
            raise HTTPException(404, "This button is no longer on the PC. Refresh your buttons.")
        return await run_in_threadpool(execute, button["action"], button["confirm"])

    @router.get("/deck/apps")
    def list_apps():
        require_windows()
        return apps.payload()

    @router.get("/deck/obs")
    def obs_status():
        require_windows()
        return obs.status()

    register_feature("deck")
    register_feature("obs")
    return router
