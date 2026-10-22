"""Explicit clipboard transfers and per-session Windows Core Audio controls.

No clipboard polling, persistence, key simulation, or master-volume fallback.
COM and clipboard handles live only on the request's worker thread.
"""
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import hashlib
import math
import os
import threading
import time
import psutil

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator
from orbit_access import note
from orbit_audio_policy import AudioPolicyConfig, AudioPolicyUnavailable, DefaultEndpointPolicy
from orbit_icons import ICONS, parse_icon_location, system_sounds_icon_location

MAX_CLIPBOARD_BYTES = 1024 * 1024
_CLIPBOARD_LOCK = threading.Lock()
_AUDIO_LOCK = threading.Lock()
_DESCRIPTION_LOCK = threading.Lock()
_DESCRIPTIONS = {}
# Mixer order, like Windows Task Manager: apps with a window, then background
# processes, then System sounds. Inside each group, sessions playing come first.
SESSION_KIND_ORDER = {"app": 0, "background": 1, "system": 2}


class DesktopUnavailable(RuntimeError):
    pass


class AudioSessionGone(RuntimeError):
    pass


def _native_error(operation):
    # Error numbers identify failures without exposing any clipboard content.
    code = getattr(ctypes, "get_last_error", lambda: 0)()
    return DesktopUnavailable(f"Windows clipboard {operation} failed (error {code}).")


def _clipboard_apis():
    if os.name != "nt":
        raise DesktopUnavailable("Clipboard transfers require Windows.")
    try:
        user = ctypes.WinDLL("user32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    except OSError as error:
        raise DesktopUnavailable("Windows clipboard APIs are unavailable in this session.") from error
    definitions = (
        (user.OpenClipboard, [wintypes.HWND], wintypes.BOOL),
        (user.CloseClipboard, [], wintypes.BOOL),
        (user.EmptyClipboard, [], wintypes.BOOL),
        (user.IsClipboardFormatAvailable, [wintypes.UINT], wintypes.BOOL),
        (user.GetClipboardData, [wintypes.UINT], wintypes.HANDLE),
        (user.SetClipboardData, [wintypes.UINT, wintypes.HANDLE], wintypes.HANDLE),
        (user.CreateWindowExW, [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR,
                               wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                               ctypes.c_int, wintypes.HWND, wintypes.HMENU,
                               wintypes.HINSTANCE, ctypes.c_void_p], wintypes.HWND),
        (user.DestroyWindow, [wintypes.HWND], wintypes.BOOL),
        (user.RegisterClipboardFormatW, [wintypes.LPCWSTR], wintypes.UINT),
        (user.GetClipboardSequenceNumber, [], wintypes.DWORD),
        (kernel.GlobalAlloc, [wintypes.UINT, ctypes.c_size_t], wintypes.HGLOBAL),
        (kernel.GlobalFree, [wintypes.HGLOBAL], wintypes.HGLOBAL),
        (kernel.GlobalLock, [wintypes.HGLOBAL], ctypes.c_void_p),
        (kernel.GlobalUnlock, [wintypes.HGLOBAL], wintypes.BOOL),
        (kernel.GlobalSize, [wintypes.HGLOBAL], ctypes.c_size_t),
    )
    for function, arguments, result in definitions:
        function.argtypes = arguments
        function.restype = result
    return user, kernel


class WindowsClipboard:
    def __init__(self, apis=None):
        self.user, self.kernel = apis if apis is not None else _clipboard_apis()

    @contextmanager
    def opened(self):
        # EmptyClipboard with a NULL owner makes SetClipboardData fail. A hidden
        # message-only STATIC window gives this worker thread a real owner HWND.
        window = self.user.CreateWindowExW(0, "STATIC", "Orbit clipboard", 0,
                                          0, 0, 0, 0, ctypes.c_void_p(-3), None, None, None)
        if not window:
            raise _native_error("owner-window creation")
        opened = False
        try:
            for attempt in range(6):
                if self.user.OpenClipboard(window):
                    opened = True
                    break
                if attempt < 5:
                    time.sleep(0.025 * (attempt + 1))
            if not opened:
                raise DesktopUnavailable("The PC clipboard is busy. Close the other clipboard operation and retry.")
            yield
        finally:
            if opened:
                self.user.CloseClipboard()
            self.user.DestroyWindow(window)

    def read(self):
        with _CLIPBOARD_LOCK, self.opened():
            if not self.user.IsClipboardFormatAvailable(13):  # CF_UNICODETEXT
                return None
            handle = self.user.GetClipboardData(13)
            if not handle:
                raise _native_error("read")
            size = int(self.kernel.GlobalSize(handle))
            if size < 2 or size % 2 or size > MAX_CLIPBOARD_BYTES:
                raise DesktopUnavailable("PC clipboard text is malformed or exceeds the 1 MB transfer limit.")
            pointer = self.kernel.GlobalLock(handle)
            if not pointer:
                raise _native_error("memory lock")
            try:
                raw = ctypes.string_at(pointer, size)
                end = next((offset for offset in range(0, size, 2)
                            if raw[offset:offset + 2] == b"\0\0"), None)
                if end is None:
                    raise DesktopUnavailable("PC clipboard text has no valid terminator.")
                try:
                    return raw[:end].decode("utf-16-le", errors="strict")
                except UnicodeDecodeError as error:
                    raise DesktopUnavailable("PC clipboard does not contain valid Unicode text.") from error
            finally:
                self.kernel.GlobalUnlock(handle)

    def _global_copy(self, data):
        handle = self.kernel.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        if not handle:
            raise _native_error("memory allocation")
        try:
            pointer = self.kernel.GlobalLock(handle)
            if not pointer:
                raise _native_error("memory lock")
            try:
                ctypes.memmove(pointer, data, len(data))
            finally:
                self.kernel.GlobalUnlock(handle)
        except BaseException:
            self.kernel.GlobalFree(handle)
            raise
        return handle

    def write(self, text, exclude_from_history=False):
        """Replace the clipboard text. `exclude_from_history` marks it private: Windows
        then keeps it out of clipboard history (Win+V) and cloud clipboard sync, the
        formats Microsoft documents for password managers. Returns the clipboard
        sequence number after the write (0 when unknown)."""
        if not isinstance(text, str) or "\0" in text:
            raise ValueError("Clipboard text cannot contain null characters.")
        try:
            data = text.encode("utf-16-le", errors="strict") + b"\0\0"
        except UnicodeEncodeError as error:
            raise ValueError("Clipboard text must contain valid Unicode.") from error
        if len(data) > MAX_CLIPBOARD_BYTES:
            raise ValueError("Clipboard text exceeds the 1 MB transfer limit.")
        with _CLIPBOARD_LOCK, self.opened():
            # Allocate/copy before emptying, so preparation failures leave the
            # existing clipboard untouched. Windows owns hMem after success.
            handle = self._global_copy(data)
            transferred = False
            try:
                if not self.user.EmptyClipboard():
                    raise _native_error("clear")
                if not self.user.SetClipboardData(13, handle):
                    raise _native_error("write")
                transferred = True
            finally:
                if not transferred:
                    self.kernel.GlobalFree(handle)
            if exclude_from_history:
                self._mark_private()
            try:
                return int(self.user.GetClipboardSequenceNumber() or 0)
            except Exception:
                return 0

    def _mark_private(self):
        # https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats
        markers = (("ExcludeClipboardContentFromMonitorProcessing", b"\0\0\0\0"),
                   ("CanIncludeInClipboardHistory", (0).to_bytes(4, "little")),
                   ("CanUploadToCloudClipboard", (0).to_bytes(4, "little")))
        for name, payload in markers:
            identifier = self.user.RegisterClipboardFormatW(name)
            if not identifier:
                raise _native_error("private format registration")
            handle = self._global_copy(payload)
            if not self.user.SetClipboardData(identifier, handle):
                self.kernel.GlobalFree(handle)
                raise _native_error("private format write")

    def clear_if_unchanged(self, sequence):
        """Empty the clipboard only if nothing was copied since `sequence` (a private copy)."""
        if not sequence:
            return False
        with _CLIPBOARD_LOCK:
            if int(self.user.GetClipboardSequenceNumber() or 0) != int(sequence):
                return False
            with self.opened():
                if int(self.user.GetClipboardSequenceNumber() or 0) != int(sequence):
                    return False
                return bool(self.user.EmptyClipboard())


def copy_private_text(text, clear_after=60.0, clipboard_factory=None, timer_factory=threading.Timer):
    """Copy a credential so it skips clipboard history, then clear it after `clear_after`
    seconds unless the user copied something else meanwhile."""
    clipboard = (clipboard_factory or WindowsClipboard)()
    sequence = clipboard.write(text, exclude_from_history=True)
    if clear_after and sequence:
        def clear():
            try:
                (clipboard_factory or WindowsClipboard)().clear_if_unchanged(sequence)
            except Exception:
                pass
        timer = timer_factory(clear_after, clear)
        timer.daemon = True
        timer.start()
    return sequence


@contextmanager
def _audio_sessions():
    if os.name != "nt":
        raise DesktopUnavailable("The audio mixer requires Windows.")
    try:
        import comtypes
        from pycaw.pycaw import AudioUtilities
    except (ImportError, OSError) as error:
        raise DesktopUnavailable("Windows Core Audio is unavailable. Update the complete Orbit Agent folder and its dependencies.") from error
    initialized = False
    try:
        comtypes.CoInitialize()
        initialized = True
        sessions = AudioUtilities.GetAllSessions()
        # Include streams on every active render endpoint. After routing an app
        # away from the default device it must remain visible in Orbit's mixer.
        default = AudioUtilities.GetSpeakers()
        default_id = getattr(default, "id", None)
        default_name = getattr(default, "FriendlyName", None)
        for session in sessions:
            session.orbitOutputID = default_id if isinstance(default_id, str) else None
            session.orbitOutputName = default_name if isinstance(default_name, str) else None
        for device in AudioUtilities.GetAllDevices(data_flow=0, device_state=1):
            if device.id == default_id:
                continue
            try:
                from pycaw.utils import AudioSession
                from pycaw.api.audiopolicy import IAudioSessionControl2
                enumerator = device.AudioSessionManager.GetSessionEnumerator()
                for index in range(enumerator.GetCount()):
                    control = enumerator.GetSession(index)
                    if control is None:
                        continue
                    session = AudioSession(control.QueryInterface(IAudioSessionControl2))
                    session.orbitOutputID = device.id
                    session.orbitOutputName = device.FriendlyName
                    sessions.append(session)
            except Exception:
                # USB/Bluetooth endpoints can disappear during enumeration.
                # Other still-active endpoints remain usable.
                continue
        yield sessions
    except (DesktopUnavailable, AudioSessionGone):
        raise
    except Exception as error:
        raise DesktopUnavailable("Windows could not access audio sessions. Check the active playback device and retry.") from error
    finally:
        if initialized:
            comtypes.CoUninitialize()


def _session_identity(session):
    # A PID can be recycled and one process may own several sessions. The Core
    # Audio instance identifier is unique for the lifetime of this session.
    instance = session.InstanceIdentifier
    pid = int(session.ProcessId)
    if not isinstance(instance, str) or not instance or pid < 0:
        raise AudioSessionGone("This audio session is no longer available. Refresh the mixer.")
    digest = hashlib.sha256(f"{pid}\0{instance}".encode("utf-8")).hexdigest()
    return digest, pid


def _printable(text):
    return "".join(character for character in str(text) if ord(character) >= 32).strip()


def _read_file_description(path):
    """The FileDescription Windows shows for an executable ("Google Chrome")."""
    version = ctypes.WinDLL("version", use_last_error=True)
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p),
                                       ctypes.POINTER(wintypes.UINT)]
    version.VerQueryValueW.restype = wintypes.BOOL
    handle = wintypes.DWORD()
    size = version.GetFileVersionInfoSizeW(path, ctypes.byref(handle))
    if not size or size > 4 * 1024 * 1024:
        return None
    block = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(path, 0, size, block):
        return None
    pointer, length = ctypes.c_void_p(), wintypes.UINT()
    languages = []
    if (version.VerQueryValueW(block, "\\VarFileInfo\\Translation", ctypes.byref(pointer), ctypes.byref(length))
            and pointer.value and length.value >= 4):
        count = min(length.value // 4, 16)
        words = (ctypes.c_uint16 * (count * 2)).from_address(pointer.value)
        languages = [(words[2 * index], words[2 * index + 1]) for index in range(count)]
    for language, codepage in languages + [(0x0409, 0x04B0), (0x0409, 0x04E4), (0x0000, 0x04B0)]:
        key = f"\\StringFileInfo\\{language:04x}{codepage:04x}\\FileDescription"
        if (version.VerQueryValueW(block, key, ctypes.byref(pointer), ctypes.byref(length))
                and pointer.value and length.value > 1):
            text = ctypes.wstring_at(pointer.value, min(length.value, 512)).split("\0", 1)[0]
            if text.strip():
                return text
    return None


def _file_description(path):
    if os.name != "nt" or not isinstance(path, str) or not path:
        return None
    key = path.casefold()
    with _DESCRIPTION_LOCK:
        if key in _DESCRIPTIONS:
            return _DESCRIPTIONS[key]
    try:
        description = _read_file_description(path)
    except Exception:
        description = None
    description = _printable(description)[:120] if description else None
    with _DESCRIPTION_LOCK:
        if len(_DESCRIPTIONS) >= 2048:
            _DESCRIPTIONS.clear()
        _DESCRIPTIONS[key] = description or None
    return description or None


def _window_owner_pids(user32, callback_type):
    """PIDs owning a visible, unowned, titled, non-tool top-level window (the
    taskbar's apps). Store apps draw inside ApplicationFrameHost's frame window:
    their own process owns a child of that frame, so frames count their children."""
    pids = set()

    def owner(window):
        process = wintypes.DWORD()
        if user32.GetWindowThreadProcessId(window, ctypes.byref(process)) and process.value:
            pids.add(int(process.value))

    def visit_child(window, _):
        owner(window)
        return True

    child_callback = callback_type(visit_child)

    def visit(window, _):
        if (user32.IsWindowVisible(window) and not user32.GetWindow(window, 4)  # GW_OWNER
                and not user32.GetWindowLongW(window, -20) & 0x80  # WS_EX_TOOLWINDOW
                and user32.GetWindowTextLengthW(window) > 0):
            owner(window)
            name = ctypes.create_unicode_buffer(64)
            if user32.GetClassNameW(window, name, 64) and name.value == "ApplicationFrameWindow":
                user32.EnumChildWindows(window, child_callback, 0)
        return True

    callback = callback_type(visit)
    user32.EnumWindows(callback, 0)
    return pids


def _visible_window_pids():
    """Processes with a window on the taskbar: what Task Manager calls apps."""
    if os.name != "nt":
        return set()
    try:
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        for function, arguments, result in (
            (user32.EnumWindows, [callback_type, wintypes.LPARAM], wintypes.BOOL),
            (user32.EnumChildWindows, [wintypes.HWND, callback_type, wintypes.LPARAM], wintypes.BOOL),
            (user32.IsWindowVisible, [wintypes.HWND], wintypes.BOOL),
            (user32.GetWindow, [wintypes.HWND, wintypes.UINT], wintypes.HWND),
            (user32.GetWindowLongW, [wintypes.HWND, ctypes.c_int], wintypes.LONG),
            (user32.GetWindowTextLengthW, [wintypes.HWND], ctypes.c_int),
            (user32.GetClassNameW, [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int], ctypes.c_int),
            (user32.GetWindowThreadProcessId, [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)], wintypes.DWORD),
        ):
            function.argtypes = arguments
            function.restype = result
        return _window_owner_pids(user32, callback_type)
    except Exception:
        return set()


def _application_context():
    """PIDs and executables that own windows. Chrome or Discord play audio from a
    helper process of the same executable, so the executable counts too."""
    pids = _visible_window_pids()
    executables = set()
    for pid in pids:
        try:
            executable = psutil.Process(pid).exe()
        except (psutil.Error, OSError):
            continue
        if isinstance(executable, str) and executable:
            executables.add(executable.casefold())
    return pids, executables


def _session_executable(session, pid):
    if pid <= 0:
        return None
    try:
        process = session.Process
        executable = process.exe() if process is not None else None
    except Exception:
        return None
    return executable if isinstance(executable, str) and executable else None


def _display_name(session, pid, name, executable):
    """What Windows' own mixer shows: the session's name, else the file description."""
    if pid == 0:
        return "System sounds"
    try:
        label = session.DisplayName
    except Exception:
        label = None
    if isinstance(label, str):
        label = _printable(label)
        if label and not label.startswith("@"):  # "@dll,-id" strings are unresolved resources.
            return label[:120]
    description = _file_description(executable)
    if description:
        return description
    base = name[:-4] if name.casefold().endswith(".exe") else name
    return base or name


def _session_icon(session, pid, executable):
    try:
        location = parse_icon_location(session.IconPath)
    except Exception:
        location = None
    if location is None and pid == 0:
        location = system_sounds_icon_location()
    if location is not None and os.path.isfile(location[0]):
        icon = ICONS.register(*location)
        if icon:
            return icon
    return ICONS.register(executable) if executable else None


def _session_snapshot(session, context=None):
    identity, pid = _session_identity(session)
    state = int(session.State)
    if state == 2:  # AudioSessionStateExpired
        raise AudioSessionGone("This audio session has ended. Refresh the mixer.")
    volume = session.SimpleAudioVolume
    level = float(volume.GetMasterVolume()) * 100
    if not math.isfinite(level) or not 0 <= level <= 100.001:
        raise DesktopUnavailable("Windows returned an invalid audio session level.")
    try:
        process = session.Process
        name = process.name() if process is not None else ("System sounds" if pid == 0 else f"Application {pid}")
        created = float(process.create_time()) if process is not None else None
        if created is not None and (not math.isfinite(created) or created <= 0):
            created = None
    except Exception:
        name = f"Application {pid}"
        created = None
    name = _printable(name)[:260] or f"Application {pid}"
    executable = _session_executable(session, pid)
    window_pids, window_executables = context if context is not None else _application_context()
    if pid == 0:
        kind = "system"
    elif pid in window_pids or (executable is not None and executable.casefold() in window_executables):
        kind = "app"
    else:
        kind = "background"
    return {"id": identity, "pid": pid, "name": name,
            "displayName": _display_name(session, pid, name, executable),
            "volume": round(min(100.0, level), 1), "isMuted": bool(volume.GetMute()),
            "isActive": state == 1,  # AudioSessionStateActive: a stream is playing.
            "kind": kind,
            "iconID": _session_icon(session, pid, executable),
            "processCreateTime": created,
            "outputDeviceID": getattr(session, "orbitOutputID", None),
            "outputDeviceName": getattr(session, "orbitOutputName", None)}


def session_importance(item):
    return (SESSION_KIND_ORDER.get(item.get("kind"), 1), not item.get("isActive"),
            str(item.get("displayName") or item["name"]).casefold(), item["pid"], item["id"])


def list_audio_sessions():
    with _AUDIO_LOCK, _audio_sessions() as sessions:
        context = _application_context()
        result = []
        for session in sessions:
            try:
                result.append(_session_snapshot(session, context))
            except Exception:
                # Sessions can disappear while the enumerator is being read.
                continue
        return sorted(result, key=session_importance)


def update_audio_session(identity, volume=None, muted=None):
    if not isinstance(identity, str) or len(identity) != 64:
        raise AudioSessionGone("Invalid audio session. Refresh the mixer.")
    if volume is None and muted is None:
        raise ValueError("Select a volume or mute change.")
    if volume is not None and (isinstance(volume, bool) or not isinstance(volume, (float, int))
                               or not math.isfinite(volume) or not 0 <= volume <= 100):
        raise ValueError("Volume must be between 0 and 100.")
    if muted is not None and not isinstance(muted, bool):
        raise ValueError("Mute must be true or false.")
    with _AUDIO_LOCK, _audio_sessions() as sessions:
        for session in sessions:
            try:
                current, _ = _session_identity(session)
            except Exception:
                continue
            if current != identity:
                continue
            if int(session.State) == 2 or _session_identity(session)[0] != identity:
                raise AudioSessionGone("This audio session has ended. Refresh the mixer.")
            control = session.SimpleAudioVolume
            if volume is not None:
                control.SetMasterVolume(float(volume) / 100.0, None)
            if muted is not None:
                if _session_identity(session)[0] != identity:
                    raise AudioSessionGone("The audio session changed. Refresh the mixer.")
                control.SetMute(muted, None)
            return _session_snapshot(session)
    raise AudioSessionGone("This audio session has ended or the playback device changed. Refresh the mixer.")


@contextmanager
def _com():
    """A COM apartment on this request's worker thread, without enumerating sessions."""
    if os.name != "nt":
        raise DesktopUnavailable("Windows audio controls require Windows.")
    try:
        import comtypes
    except (ImportError, OSError) as error:
        raise DesktopUnavailable("Windows Core Audio is unavailable. Update the complete Orbit Agent folder and its dependencies.") from error
    comtypes.CoInitialize()
    try:
        yield
    finally:
        comtypes.CoUninitialize()


def _device_id(device):
    value = getattr(device, "id", None)
    if not isinstance(value, str):
        try:
            value = device.GetId()
        except Exception:
            value = None
    return value if isinstance(value, str) and value else None


def _default_output_id():
    """The console/multimedia default playback device, or None."""
    try:
        from pycaw.pycaw import AudioUtilities
        return _device_id(AudioUtilities.GetSpeakers())
    except Exception:
        return None


def _output_devices():
    from pycaw.pycaw import AudioUtilities
    default_id = _default_output_id()
    devices = []
    for device in AudioUtilities.GetAllDevices(data_flow=0, device_state=1):
        if isinstance(device.id, str) and device.id:
            devices.append({"id": device.id, "name": str(device.FriendlyName or "Audio output")[:260],
                            "isDefault": device.id == default_id})
    return devices


def _default_switch_reason():
    try:
        with DefaultEndpointPolicy():
            return None
    except (AudioPolicyUnavailable, OSError, AttributeError) as error:
        return str(error)


def list_audio_outputs():
    with _AUDIO_LOCK, _audio_sessions():  # Same worker-thread COM apartment.
        devices = _output_devices()
        default_reason = _default_switch_reason()
        result = {"devices": devices, "defaultDeviceID": next((device["id"] for device in devices if device.get("isDefault")), None),
                  "defaultSwitchAvailable": default_reason is None, "defaultSwitchUnavailableReason": default_reason}
        try:
            with AudioPolicyConfig():
                pass
            return {**result, "routingAvailable": True, "routingUnavailableReason": None}
        except (AudioPolicyUnavailable, OSError, AttributeError) as error:
            return {**result, "routingAvailable": False, "routingUnavailableReason": str(error)}


def set_default_output(device_id):
    """Make an active playback device the Windows default for every role, then confirm it."""
    if not isinstance(device_id, str) or not device_id:
        raise ValueError("Select an active audio output.")
    with _AUDIO_LOCK, _com():
        devices = _output_devices()
        device = next((item for item in devices if item["id"] == device_id), None)
        if device is None:
            raise AudioSessionGone("That audio device disconnected. Refresh and select an active output.")
        try:
            with DefaultEndpointPolicy() as policy:
                policy.set_default(device_id)
        except AudioPolicyUnavailable as error:
            raise DesktopUnavailable(str(error)) from error
        if _default_output_id() != device_id:
            raise DesktopUnavailable("Windows did not make this the default output. Try again from Windows Settings → System → Sound.")
        devices = _output_devices()
        return {"status": "default_changed", "deviceID": device_id, "name": device["name"], "devices": devices}


def _capture_endpoints():
    """The default recording devices for the console and communications roles (often the
    same microphone), each with its IAudioEndpointVolume. Empty without a microphone."""
    import comtypes
    from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
    if hasattr(AudioUtilities, "GetDeviceEnumerator"):
        enumerator = AudioUtilities.GetDeviceEnumerator()
    else:
        from pycaw.constants import CLSID_MMDeviceEnumerator
        from pycaw.pycaw import IMMDeviceEnumerator
        enumerator = comtypes.CoCreateInstance(CLSID_MMDeviceEnumerator, IMMDeviceEnumerator, comtypes.CLSCTX_INPROC_SERVER)
    endpoints, seen = [], set()
    for role in (0, 2):  # eConsole, eCommunications
        try:
            device = enumerator.GetDefaultAudioEndpoint(1, role)  # eCapture
        except Exception:
            continue  # No default device for this role.
        identity = _device_id(device)
        if not identity or identity in seen:
            continue
        seen.add(identity)
        interface = device.Activate(IAudioEndpointVolume._iid_, comtypes.CLSCTX_ALL, None)
        volume = ctypes.cast(interface, ctypes.POINTER(IAudioEndpointVolume))
        try:
            name = AudioUtilities.CreateDevice(device).FriendlyName
        except Exception:
            name = None
        endpoints.append({"id": identity, "name": str(name or "Microphone")[:260], "volume": volume})
    return endpoints


def microphone_state():
    with _AUDIO_LOCK, _com():
        try:
            endpoints = _capture_endpoints()
        except Exception as error:
            raise DesktopUnavailable("Windows could not read the microphone.") from error
        if not endpoints:
            return {"available": False, "muted": None, "devices": []}
        muted = all(bool(endpoint["volume"].GetMute()) for endpoint in endpoints)
        return {"available": True, "muted": muted,
                "devices": [{"id": endpoint["id"], "name": endpoint["name"]} for endpoint in endpoints]}


def set_microphone_muted(muted):
    if not isinstance(muted, bool):
        raise ValueError("muted is true or false.")
    with _AUDIO_LOCK, _com():
        try:
            endpoints = _capture_endpoints()
        except Exception as error:
            raise DesktopUnavailable("Windows could not reach the microphone.") from error
        if not endpoints:
            raise AudioSessionGone("This PC has no active microphone.")
        for endpoint in endpoints:
            endpoint["volume"].SetMute(muted, None)
        actual = all(bool(endpoint["volume"].GetMute()) for endpoint in endpoints)
        if actual != muted:
            raise DesktopUnavailable("Windows did not change the microphone mute.")
        return {"muted": actual, "devices": [{"id": endpoint["id"], "name": endpoint["name"]} for endpoint in endpoints]}


def route_audio_session(identity, expected_create_time, device_id):
    if not isinstance(identity, str) or len(identity) != 64:
        raise AudioSessionGone("Invalid audio session. Refresh the mixer.")
    if isinstance(expected_create_time, bool) or not isinstance(expected_create_time, (int, float)) or not math.isfinite(expected_create_time) or expected_create_time <= 0:
        raise ValueError("The selected process creation time is required for routing.")
    if not isinstance(device_id, str):
        raise ValueError("Select an audio output or System default.")
    with _AUDIO_LOCK, _audio_sessions() as sessions:
        if device_id and device_id not in {device["id"] for device in _output_devices()}:
            raise AudioSessionGone("That audio device disconnected. Refresh the mixer and select an active output.")
        for session in sessions:
            try:
                current, pid = _session_identity(session)
            except Exception:
                continue
            if current != identity:
                continue
            if pid <= 0:
                raise ValueError("Windows system sounds do not have a per-application output preference.")

            def verify():
                try:
                    if (_session_identity(session)[0] != identity or int(session.State) == 2
                            or psutil.Process(pid).create_time() != expected_create_time):
                        raise AudioSessionGone("This application changed or closed. Refresh the mixer before routing audio.")
                except psutil.Error as error:
                    raise AudioSessionGone("This application is no longer accessible. Refresh the mixer.") from error

            verify()
            try:
                with AudioPolicyConfig() as policy:
                    policy.set_output(pid, device_id, verify)
            except AudioPolicyUnavailable as error:
                raise DesktopUnavailable(str(error)) from error
            return {"status": "routing_requested", "pid": pid, "deviceID": device_id}
    raise AudioSessionGone("This audio session ended. Refresh the mixer before changing its output.")


class ClipboardWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(max_length=MAX_CLIPBOARD_BYTES // 2 - 1)

    @field_validator("text")
    @classmethod
    def valid_text(cls, value):
        if "\0" in value:
            raise ValueError("Clipboard text cannot contain null characters.")
        try:
            size = len(value.encode("utf-16-le")) + 2
        except UnicodeEncodeError as error:
            raise ValueError("Clipboard text must contain valid Unicode.") from error
        if size > MAX_CLIPBOARD_BYTES:
            raise ValueError("Clipboard text exceeds the 1 MB transfer limit.")
        return value


class AudioSessionWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^[0-9a-f]{64}$")
    volume: float | None = Field(default=None, ge=0, le=100, allow_inf_nan=False)
    isMuted: StrictBool | None = None

    @field_validator("volume", mode="before")
    @classmethod
    def numeric_volume(cls, value):
        if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))):
            raise ValueError("Volume must be a number between 0 and 100.")
        return value

    @model_validator(mode="after")
    def has_change(self):
        if self.volume is None and self.isMuted is None:
            raise ValueError("Select a volume or mute change.")
        return self


class AudioDefaultWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    deviceID: str = Field(min_length=1, max_length=32768)


class MicrophoneWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    muted: StrictBool


class AudioRouteWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^[0-9a-f]{64}$")
    expectedCreateTime: float = Field(gt=0, allow_inf_nan=False)
    deviceID: str = Field(max_length=32768)

    @field_validator("expectedCreateTime", mode="before")
    @classmethod
    def valid_creation_time(cls, value):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("Process creation time must be a number.")
        return value


def create_desktop_router(verify_control):
    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control)])

    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Set up the encrypted Orbit connection to use clipboard and audio tools.")
        response.headers["Cache-Control"] = "no-store"

    def translate(operation):
        try:
            return operation()
        except AudioSessionGone as error:
            raise HTTPException(409, str(error)) from error
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        except DesktopUnavailable as error:
            raise HTTPException(503, str(error)) from error

    @router.get("/clipboard", dependencies=[Depends(require_encrypted)])
    def read_clipboard():
        text = translate(lambda: WindowsClipboard().read())
        return {"text": text or "", "format": "text", "available": text is not None}

    @router.put("/clipboard", dependencies=[Depends(require_encrypted)])
    def write_clipboard(body: ClipboardWrite):
        translate(lambda: WindowsClipboard().write(body.text))
        return {"status": "ok"}

    @router.get("/audio/sessions", dependencies=[Depends(require_encrypted)])
    def audio_sessions():
        return {"sessions": translate(list_audio_sessions), "available": True}

    @router.post("/audio/session", dependencies=[Depends(require_encrypted)])
    def audio_session(body: AudioSessionWrite):
        session = translate(lambda: update_audio_session(body.id, body.volume, body.isMuted))
        name = session.get("displayName") or session.get("name") or "an app"
        changes = ([f"volume {round(body.volume)}%"] if body.volume is not None else []) + \
                  (["muted" if body.isMuted else "unmuted"] if body.isMuted is not None else [])
        note(summary=f"Set {name}: {', '.join(changes)}")
        return {"status": "ok", "session": session}

    @router.get("/audio/outputs", dependencies=[Depends(require_encrypted)])
    def audio_outputs():
        return translate(list_audio_outputs)

    @router.post("/audio/route", dependencies=[Depends(require_encrypted)])
    def audio_route(body: AudioRouteWrite):
        return translate(lambda: route_audio_session(body.id, body.expectedCreateTime, body.deviceID))

    @router.post("/audio/default", dependencies=[Depends(require_encrypted)])
    def audio_default(body: AudioDefaultWrite):
        result = translate(lambda: set_default_output(body.deviceID))
        note(summary=f"Made {result['name']} the default output")
        return result

    @router.get("/audio/microphone", dependencies=[Depends(require_encrypted)])
    def microphone():
        return translate(microphone_state)

    @router.post("/audio/microphone", dependencies=[Depends(require_encrypted)])
    def microphone_mute(body: MicrophoneWrite):
        result = translate(lambda: set_microphone_muted(body.muted))
        note(summary="Muted the microphone" if body.muted else "Unmuted the microphone")
        return result

    return router
