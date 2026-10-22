"""Keyboard input through SendInput: any character in any layout, keys and shortcuts.

Text is sent as KEYEVENTF_UNICODE packets (UTF-16 code units), so "ă", "ß", "€" or an
emoji arrive exactly, whatever keyboard layout the PC uses. Named keys and shortcuts
("ctrl+c", "win+d", "alt+f4", arrows, F1–F24) are sent as virtual keys with their scan
codes and the extended-key flag where the key needs it, inside one SendInput call so
nothing else interleaves. If Windows accepts only part of a chord, the modifiers are
released again: a failed request never leaves Ctrl or Win held down.

Windows refuses injected input for elevated windows (UIPI) and the secure desktop
(lock screen, UAC prompt); that is reported, not hidden.
"""
import ctypes
from ctypes import wintypes
import os

INPUT_KEYBOARD = 1
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
MAPVK_VK_TO_VSC = 0
MAX_TEXT = 1000
MAX_REPEAT = 20

MODIFIERS = {"ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "option": 0x12,
             "win": 0x5B, "windows": 0x5B, "meta": 0x5B, "super": 0x5B}
MODIFIER_ORDER = (0x11, 0x10, 0x12, 0x5B)
EXTENDED = frozenset({0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90,
                      0xA3, 0xA5, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3})
KEYS = {
    "enter": 0x0D, "return": 0x0D, "backspace": 0x08, "tab": 0x09, "space": 0x20, "esc": 0x1B, "escape": 0x1B,
    "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "ins": 0x2D, "home": 0x24, "end": 0x23,
    "pageup": 0x21, "pgup": 0x21, "pagedown": 0x22, "pgdn": 0x22,
    "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
    "arrowup": 0x26, "arrowdown": 0x28, "arrowleft": 0x25, "arrowright": 0x27,
    "capslock": 0x14, "printscreen": 0x2C, "prtsc": 0x2C, "pause": 0x13, "scrolllock": 0x91, "numlock": 0x90,
    "menu": 0x5D, "apps": 0x5D, "contextmenu": 0x5D, "win": 0x5B, "windows": 0x5B,
    "volumemute": 0xAD, "volumedown": 0xAE, "volumeup": 0xAF, "nexttrack": 0xB0, "prevtrack": 0xB1,
    "stop": 0xB2, "playpause": 0xB3,
    "plus": 0xBB, "equals": 0xBB, "minus": 0xBD, "comma": 0xBC, "period": 0xBE, "slash": 0xBF,
    "backquote": 0xC0, "semicolon": 0xBA, "quote": 0xDE, "bracketleft": 0xDB, "bracketright": 0xDD, "backslash": 0xDC,
}
KEYS.update({chr(code).lower(): code for code in range(0x41, 0x5B)})
KEYS.update({str(digit): 0x30 + digit for digit in range(10)})
KEYS.update({f"f{number}": 0x6F + number for number in range(1, 25)})
SYMBOL_KEYS = {"=": "equals", "+": "plus", "-": "minus", ",": "comma", ".": "period", "/": "slash", "`": "backquote",
               ";": "semicolon", "'": "quote", "[": "bracketleft", "]": "bracketright", "\\": "backslash", " ": "space"}


class InputError(ValueError):
    pass


class InputBlocked(RuntimeError):
    pass


def parse_modifiers(values):
    """["ctrl", "Shift"] or "ctrl,shift" → virtual keys in the order Windows users press them."""
    if values is None:
        return []
    if isinstance(values, str):
        values = [part for part in values.replace("+", ",").split(",") if part.strip()]
    if not isinstance(values, (list, tuple)) or len(values) > 4:
        raise InputError("Send at most four modifiers: ctrl, shift, alt, win.")
    keys = set()
    for value in values:
        name = str(value).strip().casefold()
        if name in ("cmd", "command"):
            raise InputError('Windows has no Command key: send "ctrl" for shortcuts like copy, or "win".')
        if name not in MODIFIERS:
            raise InputError(f"Unknown modifier {value!r}. Use ctrl, shift, alt or win.")
        keys.add(MODIFIERS[name])
    return [key for key in MODIFIER_ORDER if key in keys]


def resolve_key(name, layout_key=None):
    """(virtual key, extended) for a key name, an F-key, a letter, a digit or a symbol."""
    if not isinstance(name, str) or not name or len(name) > 40:
        raise InputError("Unsupported key.")
    text = name if len(name) == 1 else name.strip()
    folded = text.casefold().replace("_", "").replace(" ", "") if len(text) > 1 else text.casefold()
    if folded in SYMBOL_KEYS:
        folded = SYMBOL_KEYS[folded]
    if folded in KEYS:
        code = KEYS[folded]
        return code, code in EXTENDED
    if len(text) == 1 and layout_key is not None:
        code = layout_key(text)
        if code is not None:
            return code, False
    raise InputError(f"Unsupported key {name!r}.")


def key_events(code, extended, modifiers=(), scan=lambda code: 0, repeat=1):
    """Press the modifiers, tap the key `repeat` times, release in reverse order."""
    def event(vk, up):
        flags = (KEYEVENTF_KEYUP if up else 0) | (KEYEVENTF_EXTENDEDKEY if (vk in EXTENDED or (vk == code and extended)) else 0)
        return (vk, scan(vk), flags)
    events = [event(modifier, False) for modifier in modifiers]
    for _ in range(repeat):
        events += [event(code, False), event(code, True)]
    events += [event(modifier, True) for modifier in reversed(modifiers)]
    return events


def text_events(text, scan=lambda code: 0):
    """UTF-16 KEYEVENTF_UNICODE packets; new lines and tabs are real Enter and Tab presses."""
    if not isinstance(text, str):
        raise InputError("Text must be a string.")
    if len(text) > MAX_TEXT:
        raise InputError(f"Send at most {MAX_TEXT} characters at a time.")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    events = []
    for character in text:
        if character == "\n":
            events += key_events(0x0D, False, scan=scan)
        elif character == "\t":
            events += key_events(0x09, False, scan=scan)
        elif ord(character) < 32 or 0x7F <= ord(character) < 0xA0:
            raise InputError("Text cannot contain control characters.")
        else:
            data = character.encode("utf-16-le", errors="strict")
            for index in range(0, len(data), 2):
                unit = int.from_bytes(data[index:index + 2], "little")
                events += [(0, unit, KEYEVENTF_UNICODE), (0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)]
    return events


def plan_keyboard(text="", key="", modifiers=None, repeat=1, scan=lambda code: 0, layout_key=None):
    """Every SendInput event for one keyboard request: first the key or shortcut, then the text."""
    if isinstance(repeat, bool) or not isinstance(repeat, int) or not 1 <= repeat <= MAX_REPEAT:
        raise InputError(f"repeat must be between 1 and {MAX_REPEAT}.")
    modifier_keys = parse_modifiers(modifiers)
    events = []
    if key:
        code, extended = resolve_key(key, layout_key)
        events += key_events(code, extended, [modifier for modifier in modifier_keys if modifier != code], scan, repeat)
    elif modifier_keys:
        raise InputError("Modifiers need a key, for example {\"key\": \"c\", \"modifiers\": [\"ctrl\"]}.")
    if text:
        try:
            events += text_events(text, scan)
        except UnicodeEncodeError as error:
            raise InputError("Text must be valid Unicode.") from error
    if not events:
        raise InputError("Send text or a key.")
    return events


# MARK: - Windows

# Fixed-width types: Windows' DWORD and LONG are 32-bit everywhere (ctypes.wintypes maps
# them to C long, which is 64-bit on macOS and Linux), so the layout is testable anywhere.
DWORD, LONG, WORD, ULONG_PTR = ctypes.c_uint32, ctypes.c_int32, ctypes.c_uint16, ctypes.c_size_t


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", WORD), ("wScan", WORD), ("dwFlags", DWORD), ("time", DWORD), ("dwExtraInfo", ULONG_PTR)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", LONG), ("dy", LONG), ("mouseData", DWORD), ("dwFlags", DWORD), ("time", DWORD),
                ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", DWORD), ("wParamL", WORD), ("wParamH", WORD)]


class _INPUTUNION(ctypes.Union):
    # MOUSEINPUT is the largest member: without it sizeof(INPUT) is wrong and SendInput fails.
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", DWORD), ("union", _INPUTUNION)]


class WindowsKeyboard:
    def __init__(self, user32=None):
        if user32 is None:
            if os.name != "nt":
                raise InputBlocked("Keyboard input requires Windows.")
            user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.user32 = user32
        user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        user32.SendInput.restype = wintypes.UINT
        user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
        user32.MapVirtualKeyW.restype = wintypes.UINT
        user32.VkKeyScanW.argtypes = [ctypes.c_wchar]
        user32.VkKeyScanW.restype = ctypes.c_short

    def scan(self, code):
        return int(self.user32.MapVirtualKeyW(code, MAPVK_VK_TO_VSC)) & 0xFFFF

    def layout_key(self, character):
        """The virtual key for a character on the PC's own layout, when one key types it on
        its own. Characters that need Shift or AltGr are refused as keys (send the modifier
        explicitly, or send them as text), so a shortcut never silently changes meaning."""
        value = int(self.user32.VkKeyScanW(character))
        if value == -1 or (value >> 8) & 0x07:
            return None
        return value & 0xFF

    def send(self, events):
        if not events:
            return 0
        array = (INPUT * len(events))()
        for index, (vk, scan, flags) in enumerate(events):
            array[index].type = INPUT_KEYBOARD
            array[index].union.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
        sent = int(self.user32.SendInput(len(events), array, ctypes.sizeof(INPUT)))
        if sent != len(events):
            self._release_held(events[:sent])
            raise InputBlocked("Windows blocked the input. The active window may be running as administrator, "
                               "or the PC is locked.")
        return sent

    def _release_held(self, delivered):
        held = []
        for vk, scan, flags in delivered:
            if flags & KEYEVENTF_UNICODE or not vk:
                continue
            if flags & KEYEVENTF_KEYUP:
                if vk in held:
                    held.remove(vk)
            elif vk not in held:
                held.append(vk)
        if held:
            release = [(vk, self.scan(vk), KEYEVENTF_KEYUP | (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED else 0)) for vk in reversed(held)]
            array = (INPUT * len(release))()
            for index, (vk, scan, flags) in enumerate(release):
                array[index].type = INPUT_KEYBOARD
                array[index].union.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
            self.user32.SendInput(len(release), array, ctypes.sizeof(INPUT))


def send_keyboard(text="", key="", modifiers=None, repeat=1, keyboard=None):
    keyboard = keyboard or WindowsKeyboard()
    events = plan_keyboard(text, key, modifiers, repeat, keyboard.scan, keyboard.layout_key)
    return keyboard.send(events)
