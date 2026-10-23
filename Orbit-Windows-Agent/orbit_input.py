"""Key presses and shortcuts on the PC through `SendInput` with hardware scan codes.

Games and global hotkey hooks (Discord, the Xbox Game Bar, GPU overlays) read scan codes, so
most keys are sent with `KEYEVENTF_SCANCODE`, and keys from the extended block (arrows, the
navigation cluster, Windows and menu keys) carry `KEYEVENTF_EXTENDEDKEY` as a real keyboard
reports them. Letters, digits and punctuation are looked up in the keyboard layout of the
window in front, so "z" is the key that types z on a German or French keyboard too.

A few keys go by virtual-key code instead, as Windows documents for them: media and volume keys
(handled by the shell by virtual key), the lock keys, Print Screen, Pause (which has no single
scan code) and the numeric keypad digits (whose scan codes turn into navigation keys when Num
Lock is off).

A chord presses its modifiers first, then the other keys, holds them for about 40 ms and
releases everything in reverse order; the release is sent even when the press failed, so a
modifier can never stay stuck. Chords are serialized, so two requests never interleave.

Windows drops synthetic input aimed at an app running as administrator (UIPI) without
reporting it, and refuses all input while the PC is locked.
"""
from dataclasses import dataclass
import ctypes
import threading
import time

INPUT_KEYBOARD = 1
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_SCANCODE = 0x0008
MAPVK_VK_TO_VSC_EX = 4
HOLD_SECONDS = 0.04
MAX_CHORD_KEYS = 5
MODIFIERS = ("ctrl", "shift", "alt", "win")
# One lock for every synthetic key press, shared with the text typing of /api/input/keyboard.
INPUT_LOCK = threading.RLock()


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_uint16), ("wScan", ctypes.c_uint16), ("dwFlags", ctypes.c_uint32),
                ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_int32), ("dy", ctypes.c_int32), ("mouseData", ctypes.c_uint32),
                ("dwFlags", ctypes.c_uint32), ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class _HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_uint32), ("wParamL", ctypes.c_uint16), ("wParamH", ctypes.c_uint16)]


class _INPUTUNION(ctypes.Union):
    # The mouse member makes the union (and INPUT) the size SendInput checks through cbSize.
    _fields_ = [("mi", _MOUSEINPUT), ("ki", _KEYBDINPUT), ("hi", _HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", ctypes.c_uint32), ("u", _INPUTUNION)]


KEYBDINPUT = _KEYBDINPUT


@dataclass(frozen=True)
class KeyCode:
    """How one key is sent: by scan code (the usual way) or by virtual key."""
    name: str
    vk: int
    scan: int
    extended: bool
    by_vk: bool = False
    layout: bool = False


def _scan(name, vk, scan, extended=False):
    return KeyCode(name, vk, scan, extended)


def _layout(name, vk, scan):
    return KeyCode(name, vk, scan, False, layout=True)


def _virtual(name, vk, scan, extended=False):
    return KeyCode(name, vk, scan, extended, by_vk=True)


def _build_keys():
    keys = {}
    # Scan codes are scan code set 1 for a US keyboard; layout keys are looked up at press time.
    letters = {"a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12, "f": 0x21, "g": 0x22, "h": 0x23,
               "i": 0x17, "j": 0x24, "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18, "p": 0x19,
               "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14, "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D,
               "y": 0x15, "z": 0x2C}
    for letter, scan in letters.items():
        keys[letter] = _layout(letter, ord(letter.upper()), scan)
    for digit in range(10):
        keys[str(digit)] = _layout(str(digit), 0x30 + digit, 0x0B if digit == 0 else 0x01 + digit)
    function_scans = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58,
                      0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x76]
    for index, scan in enumerate(function_scans):
        keys[f"f{index + 1}"] = _scan(f"f{index + 1}", 0x70 + index, scan)
    for name, vk, scan, extended in (
            ("enter", 0x0D, 0x1C, False), ("esc", 0x1B, 0x01, False), ("tab", 0x09, 0x0F, False),
            ("space", 0x20, 0x39, False), ("backspace", 0x08, 0x0E, False),
            ("insert", 0x2D, 0x52, True), ("delete", 0x2E, 0x53, True), ("home", 0x24, 0x47, True),
            ("end", 0x23, 0x4F, True), ("pageup", 0x21, 0x49, True), ("pagedown", 0x22, 0x51, True),
            ("up", 0x26, 0x48, True), ("down", 0x28, 0x50, True), ("left", 0x25, 0x4B, True),
            ("right", 0x27, 0x4D, True), ("menu", 0x5D, 0x5D, True),
            ("ctrl", 0xA2, 0x1D, False), ("shift", 0xA0, 0x2A, False), ("alt", 0xA4, 0x38, False),
            ("win", 0x5B, 0x5B, True)):
        keys[name] = _scan(name, vk, scan, extended)
    for name, vk, scan in (
            ("minus", 0xBD, 0x0C), ("equals", 0xBB, 0x0D), ("comma", 0xBC, 0x33), ("period", 0xBE, 0x34),
            ("slash", 0xBF, 0x35), ("backslash", 0xDC, 0x2B), ("semicolon", 0xBA, 0x27), ("quote", 0xDE, 0x28),
            ("bracketleft", 0xDB, 0x1A), ("bracketright", 0xDD, 0x1B), ("grave", 0xC0, 0x29)):
        keys[name] = _layout(name, vk, scan)
    numpad_scans = [0x52, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49]
    for digit, scan in enumerate(numpad_scans):
        keys[f"numpad{digit}"] = _virtual(f"numpad{digit}", 0x60 + digit, scan)
    for name, vk, scan, extended in (
            ("printscreen", 0x2C, 0x37, True), ("pause", 0x13, 0x45, False), ("capslock", 0x14, 0x3A, False),
            ("numlock", 0x90, 0x45, True), ("scrolllock", 0x91, 0x46, False),
            ("volumeup", 0xAF, 0x30, True), ("volumedown", 0xAE, 0x2E, True), ("volumemute", 0xAD, 0x20, True),
            ("playpause", 0xB3, 0x22, True), ("nexttrack", 0xB0, 0x19, True), ("prevtrack", 0xB1, 0x10, True),
            ("stop", 0xB2, 0x24, True)):
        keys[name] = _virtual(name, vk, scan, extended)
    return keys


KEYS = _build_keys()
KEY_NAMES = frozenset(KEYS)
_LABELS = {"ctrl": "Ctrl", "shift": "Shift", "alt": "Alt", "win": "Win", "esc": "Esc", "pageup": "Page Up",
           "pagedown": "Page Down", "printscreen": "Print Screen", "capslock": "Caps Lock",
           "numlock": "Num Lock", "scrolllock": "Scroll Lock", "backspace": "Backspace",
           "volumeup": "Volume Up", "volumedown": "Volume Down", "volumemute": "Mute",
           "playpause": "Play/Pause", "nexttrack": "Next Track", "prevtrack": "Previous Track",
           "minus": "-", "equals": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
           "semicolon": ";", "quote": "'", "bracketleft": "[", "bracketright": "]", "grave": "`"}


class InputRejected(OSError):
    """Windows did not take the synthetic input (locked PC, secure desktop)."""


def normalize_key(name):
    """The allowlisted lowercase name for `name` (any case); ValueError for anything else."""
    if not isinstance(name, str) or not name.strip():
        raise ValueError("Each key must be a key name such as \"ctrl\" or \"f10\".")
    key = name.strip().lower()
    if key not in KEYS:
        shown = name if len(name) <= 24 else name[:24] + "…"
        raise ValueError(f"\"{shown}\" is not a key Orbit can press. Use names such as ctrl, shift, alt, win, a, f10 or enter.")
    return key


def is_known_key(name):
    try:
        normalize_key(name)
        return True
    except ValueError:
        return False


def normalize_chord(keys):
    """Validated chord in press order: modifiers first (in the order given), then the other keys."""
    if isinstance(keys, str) or not isinstance(keys, (list, tuple)):
        raise ValueError("Send the shortcut as a list of key names, for example [\"ctrl\", \"shift\", \"m\"].")
    if not keys:
        raise ValueError("Choose at least one key.")
    if len(keys) > MAX_CHORD_KEYS:
        raise ValueError(f"A shortcut can have at most {MAX_CHORD_KEYS} keys.")
    names = [normalize_key(key) for key in keys]
    if len(set(names)) != len(names):
        raise ValueError("Each key can appear only once in a shortcut.")
    if {"ctrl", "alt", "delete"} <= set(names):
        raise ValueError("Windows does not accept Ctrl+Alt+Delete from apps. Use the Lock action instead.")
    return [name for name in names if name in MODIFIERS] + [name for name in names if name not in MODIFIERS]


def chord_label(keys):
    """A readable label such as "Ctrl+Shift+M"."""
    def label(name):
        if name in _LABELS:
            return _LABELS[name]
        if len(name) == 1 or (name[0] == "f" and name[1:].isdigit()):
            return name.upper()
        return name.title()
    return "+".join(label(name) for name in normalize_chord(keys))


_USER32 = None


def _load_user32():
    global _USER32
    if _USER32 is None:
        if not hasattr(ctypes, "WinDLL"):
            raise InputRejected("Synthetic input needs Windows.")
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]
        user32.SendInput.restype = ctypes.c_uint
        user32.GetForegroundWindow.argtypes = []
        user32.GetForegroundWindow.restype = ctypes.c_void_p
        user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        user32.GetWindowThreadProcessId.restype = ctypes.c_uint32
        user32.GetKeyboardLayout.argtypes = [ctypes.c_uint32]
        user32.GetKeyboardLayout.restype = ctypes.c_void_p
        user32.MapVirtualKeyExW.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p]
        user32.MapVirtualKeyExW.restype = ctypes.c_uint
        _USER32 = user32
    return _USER32


def _foreground_layout(user32):
    """Keyboard layout of the window in front (layouts are per thread); the agent's own otherwise."""
    try:
        window = user32.GetForegroundWindow()
        thread = user32.GetWindowThreadProcessId(window, None) if window else 0
        return user32.GetKeyboardLayout(thread or 0)
    except Exception:
        return None


def resolve_key(name, user32=None, layout=None):
    """The KeyCode to send; layout keys take their scan code from the given keyboard layout."""
    key = KEYS[normalize_key(name)]
    if not key.layout or user32 is None:
        return key
    try:
        mapped = int(user32.MapVirtualKeyExW(key.vk, MAPVK_VK_TO_VSC_EX, layout) or 0)
    except Exception:
        mapped = 0
    if not mapped & 0xFF:
        return key  # This layout has no such key: keep the US position.
    return KeyCode(key.name, key.vk, mapped & 0xFF, (mapped >> 8) in (0xE0, 0xE1), layout=True)


def key_event(code, *, up):
    """One keyboard INPUT for `code`, pressed or released."""
    flags = (KEYEVENTF_KEYUP if up else 0) | (KEYEVENTF_EXTENDEDKEY if code.extended else 0)
    event = INPUT()
    event.type = INPUT_KEYBOARD
    if code.by_vk:
        event.ki = _KEYBDINPUT(wVk=code.vk, wScan=code.scan, dwFlags=flags, time=0, dwExtraInfo=0)
    else:
        # With KEYEVENTF_SCANCODE Windows ignores wVk and derives the key from wScan.
        event.ki = _KEYBDINPUT(wVk=0, wScan=code.scan, dwFlags=flags | KEYEVENTF_SCANCODE, time=0, dwExtraInfo=0)
    return event


def _send(user32, events):
    if not events:
        return
    array = (INPUT * len(events))(*events)
    sent = user32.SendInput(len(events), array, ctypes.sizeof(INPUT))
    if sent != len(events):
        raise InputRejected("Windows did not accept the key presses. The PC may be locked or showing a secure screen.")


def press_chord(keys, *, hold=HOLD_SECONDS):
    """Presses the keys together (modifiers wrapped around the others) and releases them.

    Returns the normalized chord. Raises ValueError for an invalid chord (nothing is sent) and
    InputRejected (an OSError) when Windows refuses the input.
    """
    chord = normalize_chord(keys)
    with INPUT_LOCK:
        user32 = _load_user32()
        layout = _foreground_layout(user32)
        codes = [resolve_key(name, user32, layout) for name in chord]
        presses = [key_event(code, up=False) for code in codes]
        releases = [key_event(code, up=True) for code in reversed(codes)]
        try:
            _send(user32, presses)
            time.sleep(max(0.0, min(float(hold), 0.5)))
        finally:
            # Always release, even after a partial press: a stuck Ctrl or Win key is far worse.
            _send(user32, releases)
    return chord


def tap(key, *, hold=HOLD_SECONDS):
    """Presses and releases one key."""
    return press_chord([key], hold=hold)
