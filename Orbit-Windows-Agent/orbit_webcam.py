"""iPhone as a PC webcam (DESIGN.md F10) through Softcam, a DirectShow virtual camera.

The phone streams JPEG frames over a WebSocket. The agent decodes them with Pillow and hands
them to Softcam (tshino/softcam 1.8.1, MIT; it statically links Microsoft's DirectShow
BaseClasses, MIT) through ctypes. Apps that use DirectShow cameras (Chrome, Edge, Teams,
Discord, Zoom, OBS) then list a camera called "DirectShow Softcam". The Windows Camera app and
Store apps only use Media Foundation and never see it.

Files: `webcam/softcam64.dll` and `webcam/softcam32.dll` next to this module, SHA-256 pinned in
`DLL_SHA256`. The self-updater copies only top-level files, so when a bundled DLL is missing or
different, setup downloads it from raw.githubusercontent.com/<owner>/<repo>/<ref>/
Orbit-Windows-Agent/webcam/ (a host orbit_updater already trusts): first from this agent's release
tag `pc-v<version>` (it never moves, so a later Softcam rebuild on main cannot break an older agent),
then from main. A download is used only when its SHA-256 matches the pin.

Setup needs administrator rights once, because DirectShow filters are COM servers registered
machine-wide (HKLM) and load inside every camera app of every user, 64-bit and 32-bit:

1. Check the Microsoft Visual C++ 2015-2022 runtime, x64 and x86, at least 14.44 (the DLLs are
   linked with MSVC 14.44). Missing or older: refuse with the winget commands.
2. Nothing to do when the versioned folder already holds both verified DLLs and both registry
   views point at them ("alreadyInstalled"). Otherwise find a verified copy of each DLL: the
   installed folder, the bundled `webcam/` folder, the download cache, else a download.
3. One UAC prompt (ShellExecuteExW "runas") starts Windows PowerShell, which
   - creates `<Program Files>\\Orbit\\Webcam\\<INSTALL_ID>\\` in the native Program Files folder
     (found through HKLM and GetSystemWindowsDirectoryW, never through environment variables a
     user can change). Only administrators may create or change anything under Program Files,
     so no other account can plant a DLL there, which matters because Windows looks for the
     DLL's own dependencies (MSVCP140.dll, ...) next to it. Folders that are links (reparse
     points) are refused. The name comes from the pinned hashes, so a new build never
     overwrites a DLL that a running app still has loaded;
   - reads each DLL into memory, checks its SHA-256 there and only then writes it into the
     folder, then checks the written file again (a file that changed on the way is never used);
   - runs `<Windows>\\System32\\regsvr32.exe /s` for softcam64.dll and `<Windows>\\SysWOW64\\regsvr32.exe /s`
     for softcam32.dll. When the second one fails, the first view is put back as it was before:
     an older Orbit webcam that was registered there is registered again, otherwise the new
     registration is removed;
   - after success, deletes older Orbit webcam version folders (a file that an open app still
     has loaded stays until the next setup or removal).
4. Success is reported only after the agent itself read CLSID {AEF3B972-5FA5-4647-9571-358EB472BC9E}
   InprocServer32 in both registry views (pointing at exactly these files) and found the camera in
   the DirectShow video input category: a subkey of CLSID\\{860BB310-5D01-11D0-BD3B-00A0C911CE86}\\Instance
   whose CLSID value is Softcam's (Softcam 1.8.1 names that subkey "DirectShow Softcam").

Removing the webcam (POST /api/webcam/uninstall) uses the same single prompt: `regsvr32 /u /s` for
every registry view that points at Orbit's webcam folder (when that DLL is gone, its registry keys
are deleted directly), then the webcam folder is deleted. Another program's registration of the
same camera is left alone.

HTTP contract (main token; HTTPS port only, 426 over HTTP; 501 when not Windows):

GET /api/webcam -> 200
    {"installed": bool,      DLLs present in the versioned Program Files folder with the pinned hashes
     "registered": bool,     registry verified as in step 4
     "active": bool,         a virtual camera exists now (a phone is sending, or just stopped < 5 s ago)
     "clients": int,         phones connected to /ws/camera
     "width": 1280, "height": 720, "fps": 30,   current camera format (last or default when inactive)
     "reason": str | null,   plain-words reason the webcam cannot be used now; null when ready
     "connected": bool,      an app on the PC opened the camera (Softcam 1.8.1 cannot tell when it
                             closes it again, so this stays true until the camera is recreated)
     "installing": bool,     a setup runs now
     "uninstalling": bool,   a removal runs now
     "installStage": null | "preparing" | "waitingForApproval" | "verifying",   of the running setup or removal
     "installError": str | null,   why the last setup or removal failed (cleared when a new one starts)
     "runtime": {"ok": bool, "required": "14.44", "x64": "14.44.35211" | null, "x86": ... | null,
                 "missing": ["x86"], "commands": ["winget install Microsoft.VCRedist.2015+.x86"]} | null,
     "cameraName": "DirectShow Softcam", "softcamVersion": "1.8.1",
     "limits": {"minWidth": 160, "minHeight": 120, "maxWidth": 1920, "maxHeight": 1080,
                "sizeMultiple": 4, "minFPS": 15, "maxFPS": 30, "maxFrameBytes": 3145728}}

POST /api/webcam/install (no body). Waits up to 90 s, so give the request a 120 s timeout:
    200 {"status": "installed" | "alreadyInstalled", ...the GET fields}
    202 {"status": "waitingForApproval", ...the GET fields}: the UAC prompt is still open on the
        PC; poll GET /api/webcam until "installing" is false, then read "registered"/"installError".
        Another POST while a setup runs joins it (never a second prompt).
    403 the Windows prompt was declined; 409 Visual C++ runtime missing/too old (detail has the
        winget commands), Windows on ARM, not signed in, or a removal is running; 503 download,
        copy or registration failed. Errors are {"detail": "<plain sentence>"}.

POST /api/webcam/uninstall (no body). Same waiting rules (90 s, then 202 and poll "uninstalling"):
    200 {"status": "uninstalled" | "notInstalled", "filesLeft": bool, ...the GET fields}
        "notInstalled": nothing of Orbit's webcam was on the PC, so no prompt was shown.
        "filesLeft": the camera is gone, but an open app (or Orbit PC Companion itself, after a
        phone streamed) still has a webcam file loaded; restart the PC and remove it again to
        delete the files.
    202 {"status": "waitingForApproval", ...}; 403 declined; 409 Windows on ARM, not signed in, or
        a setup is running; 503 Windows still lists Orbit's camera afterwards.
    Phones streaming at that moment are closed with 4001 notInstalled.

WS /ws/camera (wss on the TLS port only; `Authorization: Bearer <main token>` header; a token in
the query string, a wrong token or plain ws:// is refused before the handshake completes):
    client -> text hello {"width": 1280, "height": 720, "fps": 30} within 10 s: whole numbers,
        width/height multiples of 4 from 160x120 to 1920x1080 (landscape), fps 15-30.
    agent  -> text {"ready": true, "width": 1280, "height": 720, "fps": 30, "cameraName": "DirectShow Softcam"}
    client -> binary messages, one upright JPEG frame each (at most 3 MiB, at most 3840x2160 pixels;
        EXIF orientation is ignored, send unmirrored). Other sizes are scaled and letterboxed into
        the camera size. Frames that arrive while the previous one is still being converted
        replace it (the newest frame wins, nothing queues up).
    agent  -> text {"connected": bool} right after "ready", whenever it changes, and every 5 s.
    agent  -> text {"error": "<plain sentence>", "code": "<code>"} right before it closes:
        1008 badHello, 1003 badFrame (not JPEG), 1009 frameTooLarge, 4001 notInstalled (also when
        the webcam is removed while streaming), 4002 replaced (a newer connection took over the
        camera), 4003 cameraUnavailable (Windows would not create the camera within 2 s, usually
        because an app still has the previous camera open; this also ends the phone that was
        streaming when a new format could not start), 4004 unsupported (not Windows, Windows on
        ARM, nobody signed in), 1011 internal.
    The camera is created on the first hello and deleted 5 s after the last phone disconnects, so
    a quick reconnect with the same format keeps apps streaming. A different format recreates
    the camera; apps that had it open must reopen it (Softcam cannot resize a connected camera).

The first camera of a session emits the event `webcam.connected` (level passive), which also
shows a PC toast.
"""
import asyncio
import concurrent.futures
import ctypes
from collections import deque
from dataclasses import dataclass, field
import hashlib
import io
import json
import logging
import math
import ntpath
import os
from pathlib import Path
import re
import stat
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import uuid

from fastapi import APIRouter, Depends, HTTPException, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

import orbit_capabilities
import orbit_events
import orbit_notify

try:
    import winreg
except ImportError:  # Not Windows (unit tests); the pretend PC harness provides its own.
    winreg = None

try:
    from PIL import Image
    HAS_PILLOW = True
except ImportError:
    Image = None
    HAS_PILLOW = False

LOGGER = logging.getLogger("orbit.webcam")

SOFTCAM_VERSION = "1.8.1"
SOFTCAM_COMMIT = "afb424c2415b04da627fa1a7b4706575c2ba3010"
CAMERA_NAME = "DirectShow Softcam"
CLSID = "{AEF3B972-5FA5-4647-9571-358EB472BC9E}"
VIDEO_INPUT_CATEGORY = "{860BB310-5D01-11D0-BD3B-00A0C911CE86}"  # CLSID_VideoInputDeviceCategory
INPROC_KEY = "SOFTWARE\\Classes\\CLSID\\" + CLSID + "\\InprocServer32"
# DirectShow lists a filter in a category under Instance\<szInstance>, with CLSID, FriendlyName and
# FilterData values. Softcam's DllRegisterServer passes its filter name as szInstance
# (IFilterMapper2::RegisterFilter(CLSID, L"DirectShow Softcam", 0, &CLSID_VideoInputDeviceCategory,
# L"DirectShow Softcam", ...)), so the subkey is "DirectShow Softcam", not the CLSID.
INSTANCE_ROOT_KEY = "SOFTWARE\\Classes\\CLSID\\" + VIDEO_INPUT_CATEGORY + "\\Instance"
CATEGORY_INSTANCE_KEY = INSTANCE_ROOT_KEY + "\\" + CAMERA_NAME
MAX_INSTANCE_SUBKEYS = 4096
WINDOWS_CURRENT_VERSION_KEY = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion"
DLL_SHA256 = {
    "softcam64.dll": "f62432a498c06b053eae3d437f445ff64e8b847be92b689e5ee01f0f2fdf911a",
    "softcam32.dll": "aa2e2d870a1d280d3f11382b0fdba5cb760a66830cc3d6353a03b3571f44c66d",
}
# The versioned folder in <Program Files>\Orbit\Webcam: a prefix of the hash of both pins.
INSTALL_ID = hashlib.sha256("".join(f"{name}={DLL_SHA256[name]}\n" for name in sorted(DLL_SHA256))
                            .encode("ascii")).hexdigest()[:16]
MAX_DLL_BYTES = 4 * 1024 * 1024
DOWNLOAD_FOLDER = "Orbit-Windows-Agent/webcam/"

MIN_VC_RUNTIME = (14, 44)
VC_RUNTIME_KEY = "SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes"
VC_RUNTIME_FILES = {"x64": ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"),
                    "x86": ("msvcp140.dll", "vcruntime140.dll")}
VC_REDIST_PAGE = "https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist"
WINGET_COMMANDS = {"x64": "winget install Microsoft.VCRedist.2015+.x64",
                   "x86": "winget install Microsoft.VCRedist.2015+.x86"}

MIN_WIDTH, MIN_HEIGHT = 160, 120
MAX_WIDTH, MAX_HEIGHT = 1920, 1080
MIN_FPS, MAX_FPS = 15, 30
DEFAULT_FORMAT = (1280, 720, 30)
MAX_HELLO_CHARS = 1024
MAX_FRAME_BYTES = 3 * 1024 * 1024
MAX_SOURCE_PIXELS = 3840 * 2160
MIN_SOURCE_SIDE = 16
LIMITS = {"minWidth": MIN_WIDTH, "minHeight": MIN_HEIGHT, "maxWidth": MAX_WIDTH, "maxHeight": MAX_HEIGHT,
          "sizeMultiple": 4, "minFPS": MIN_FPS, "maxFPS": MAX_FPS, "maxFrameBytes": MAX_FRAME_BYTES}

HELLO_TIMEOUT = 10.0
GRACE_SECONDS = 5.0
STATUS_INTERVAL = 1.0
HEARTBEAT_SECONDS = 5.0
CONNECTION_POLL_SECONDS = 1.0
INSTALL_WAIT_SECONDS = 90.0
ELEVATED_TIMEOUT_SECONDS = 120.0
# Softcam refuses a new camera while an app's filter still maps the previous one's shared memory
# (until its next frame poll, or for as long as its graph is stopped), so creation is retried.
CREATE_RETRY_SECONDS = 2.0
CREATE_RETRY_INTERVAL = 0.05

CLOSE_POLICY = 1008
CLOSE_UNSUPPORTED_DATA = 1003
CLOSE_TOO_BIG = 1009
CLOSE_INTERNAL = 1011
CLOSE_NOT_INSTALLED = 4001
CLOSE_REPLACED = 4002
CLOSE_CAMERA_UNAVAILABLE = 4003
CLOSE_UNSUPPORTED_PC = 4004
_TOKEN_QUERY_NAMES = frozenset({"token", "access_token", "accesstoken", "apitoken", "api_token", "authorization",
                                "auth", "bearer"})

KEY_WOW64_64KEY = 0x0100
KEY_WOW64_32KEY = 0x0200
_IMAGE_FILE_MACHINES = {0x8664: "x64", 0x014C: "x86", 0xAA64: "arm64"}

REGISTRATION_MESSAGES = {
    "missing": "Set up the iPhone webcam on the PC first. Orbit asks Windows for permission once.",
    "notListed": "Windows does not list the DirectShow Softcam camera. Set up the iPhone webcam again.",
    "olderOrbit": "Another version of Orbit's webcam is registered on this PC. Set up the iPhone webcam again to update it.",
    "otherProgram": "Another program registered its own DirectShow Softcam camera on this PC. Setting up the iPhone "
                    "webcam takes that camera over.",
}
NOT_SIGNED_IN = "Sign in to Windows on the PC first. The iPhone webcam works on the signed-in desktop."
CAMERA_BUSY_MESSAGE = ("The PC could not start the DirectShow Softcam camera. An app on the PC may still have the "
                       "previous camera open, or another program is sending video to it. Close the camera in that "
                       "app (or restart the app) and try again.")
REPLACED_MESSAGE = "Another device started using this PC's webcam."
REMOVED_MESSAGE = "The iPhone webcam was removed from this PC. Set it up again to use it."
BUSY_MESSAGES = {"install": "The iPhone webcam is being set up on the PC right now. Try again when that finishes.",
                 "uninstall": "The iPhone webcam is being removed from the PC right now. Try again when that "
                              "finishes."}


class UnsupportedPC(Exception):
    """This PC cannot run the webcam at all; the message says why in plain words."""


class InstallError(Exception):
    """Setup failed; `status` is the HTTP status and `message` a sentence for the phone."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class CameraError(Exception):
    """The camera cannot start for this phone: `code`, a sentence and the WebSocket close code."""

    def __init__(self, code, message, close_code):
        super().__init__(message)
        self.code = code
        self.message = message
        self.close_code = close_code


class FrameError(ValueError):
    """A frame that is not a usable JPEG image."""


class HelloError(ValueError):
    """An invalid hello message; the text is shown on the phone."""


# Files and hashes ----------------------------------------------------------------------------

_HASH_LOCK = threading.Lock()
_HASH_CACHE = {}


def file_sha256(path, use_cache=True):
    """Hex SHA-256 of a regular file of at most MAX_DLL_BYTES; None when missing or unreadable.
    Cached by size, modification time and file id for status polls."""
    path = Path(path)
    try:
        info = os.stat(path)
    except (OSError, ValueError):
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_DLL_BYTES:
        return None
    key = os.path.normcase(os.path.abspath(str(path)))
    signature = (info.st_size, info.st_mtime_ns, getattr(info, "st_ino", 0))
    if use_cache:
        with _HASH_LOCK:
            cached = _HASH_CACHE.get(key)
        if cached is not None and cached[0] == signature:
            return cached[1]
    try:
        with open(path, "rb") as stream:
            data = stream.read(MAX_DLL_BYTES + 1)
    except OSError:
        return None
    if len(data) > MAX_DLL_BYTES:
        return None
    digest = hashlib.sha256(data).hexdigest()
    with _HASH_LOCK:
        _HASH_CACHE[key] = (signature, digest)
    return digest


def is_verified(path, name, use_cache=True):
    return file_sha256(path, use_cache) == DLL_SHA256[name]


def _is_windows():
    return sys.platform == "win32"


def _windows_directory():
    """The Windows folder as Windows itself reports it (GetSystemWindowsDirectoryW); None when unknown."""
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        function = kernel32.GetSystemWindowsDirectoryW
        function.argtypes = [ctypes.c_wchar_p, ctypes.c_uint]
        function.restype = ctypes.c_uint
        buffer = ctypes.create_unicode_buffer(1024)
        length = function(buffer, len(buffer))
    except Exception:
        return None
    if not 0 < length < len(buffer):
        return None
    return buffer.value or None


def system_root():
    """C:\\Windows. On Windows from GetSystemWindowsDirectoryW, never from %SystemRoot% or %windir%:
    users can override those for their own processes, and the elevated command runs programs from
    this folder. Elsewhere (unit tests, the pretend PC) the environment stands in for Windows."""
    if _is_windows():
        return _windows_directory() or "C:\\Windows"
    return os.environ.get("SystemRoot") or os.environ.get("windir") or "C:\\Windows"


_PLAIN_FOLDER = re.compile(r"[A-Za-z]:\\[^\\%\"<>|?*\x00-\x1f][^%\"<>|?*\x00-\x1f]*")


def _program_files_from_registry(registry, view):
    value = _read_value(registry, WINDOWS_CURRENT_VERSION_KEY, "ProgramFilesDir", view)
    if isinstance(value, str) and _PLAIN_FOLDER.fullmatch(value.strip()):
        return value.strip().rstrip("\\")
    return None


def program_files():
    """The native Program Files folder, where only administrators may create or change files. On
    Windows it comes from HKLM (the 64-bit view, so a 32-bit agent also gets C:\\Program Files),
    never from %ProgramFiles%, which users can override."""
    if not _is_windows():
        return Path(os.environ.get("ProgramW6432") or os.environ.get("PROGRAMFILES") or "C:\\Program Files")
    view = 0 if native_machine() == "x86" else KEY_WOW64_64KEY
    value = _program_files_from_registry(winreg, view) if winreg is not None else None
    if value:
        return Path(value)
    drive = ntpath.splitdrive(system_root())[0] or "C:"
    return Path(drive + "\\Program Files")


def orbit_program_files():
    return program_files() / "Orbit"


def webcam_root():
    """`<Program Files>\\Orbit\\Webcam`: one folder per pinned build, created by the elevated setup."""
    return orbit_program_files() / "Webcam"


def install_directory():
    return webcam_root() / INSTALL_ID


def bundled_directories():
    folders = [Path(__file__).resolve().parent / "webcam"]
    if getattr(sys, "frozen", False):
        bundle = getattr(sys, "_MEIPASS", None)
        if bundle:
            folders.append(Path(bundle) / "webcam")
        folders.append(Path(sys.executable).resolve().parent / "webcam")
    return folders


def cache_directory():
    from orbit_tls import data_directory
    return data_directory() / "webcam" / INSTALL_ID


# What kind of Windows this is -----------------------------------------------------------------

@dataclass(frozen=True)
class Target:
    name: str        # softcam64.dll
    regsvr32: str    # as the elevated (native) PowerShell sees it
    view: int        # registry view flag for this bitness
    runtime: str     # "x64" or "x86"


@dataclass(frozen=True)
class Layout:
    machine: str                 # "x64" or "x86" (the Windows itself)
    process_bits: int            # this Python process
    targets: tuple
    powershell: str              # the native Windows PowerShell, as this process must name it
    sender_dll: str              # the DLL this process loads to send frames
    runtime_dirs: dict = field(default_factory=dict)  # VC++ runtime folder per arch, as this process sees it


def _native_machine_from_windows():
    """`IsWow64Process2`'s native machine ("x64", "x86", "arm64"); None when unknown."""
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        query = kernel32.IsWow64Process2
        kernel32.GetCurrentProcess.argtypes = []
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        query.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
        query.restype = ctypes.c_int
        process_machine, native_machine = ctypes.c_ushort(0), ctypes.c_ushort(0)
        if not query(kernel32.GetCurrentProcess(), ctypes.byref(process_machine), ctypes.byref(native_machine)):
            return None
        return _IMAGE_FILE_MACHINES.get(native_machine.value)
    except Exception:  # Not Windows, or Windows 10 before 1709 (no IsWow64Process2).
        return None


def native_machine():
    machine = _native_machine_from_windows()
    if machine:
        return machine
    text = (os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE") or "").upper()
    return {"AMD64": "x64", "X86": "x86", "ARM64": "arm64"}.get(text, "x64")


def process_bits():
    return struct.calcsize("P") * 8


def platform_layout():
    """Which DLLs to register with which regsvr32, in which registry view. Raises UnsupportedPC."""
    machine = native_machine()
    if machine == "arm64":
        raise UnsupportedPC("The iPhone webcam needs a PC with an Intel or AMD processor. Windows on ARM is not "
                            "supported yet.")
    root = system_root()
    bits = process_bits()

    def path(*parts):
        return os.path.join(root, *parts)

    if machine == "x86":
        targets = (Target("softcam32.dll", path("System32", "regsvr32.exe"), 0, "x86"),)
        native_folder = "System32"
        runtime_dirs = {"x86": path("System32")}
        sender = "softcam32.dll"
    else:
        targets = (Target("softcam64.dll", path("System32", "regsvr32.exe"), KEY_WOW64_64KEY, "x64"),
                   Target("softcam32.dll", path("SysWOW64", "regsvr32.exe"), KEY_WOW64_32KEY, "x86"))
        # A 32-bit process reaches the real System32 only through Sysnative; everything the
        # elevated (then 64-bit) PowerShell runs uses the normal names.
        native_folder = "Sysnative" if bits == 32 else "System32"
        runtime_dirs = {"x64": path(native_folder), "x86": path("SysWOW64")}
        sender = "softcam64.dll" if bits == 64 else "softcam32.dll"
    return Layout(machine=machine, process_bits=bits, targets=targets,
                  powershell=path(native_folder, "WindowsPowerShell", "v1.0", "powershell.exe"),
                  sender_dll=sender, runtime_dirs=runtime_dirs)


def files_installed(layout, folder=None):
    folder = Path(folder) if folder is not None else install_directory()
    return all(is_verified(folder / target.name, target.name) for target in layout.targets)


# Registry ------------------------------------------------------------------------------------

def _open_machine_key(registry, path, view):
    return registry.OpenKey(registry.HKEY_LOCAL_MACHINE, path, 0, registry.KEY_READ | view)


def _read_value(registry, path, name, view):
    try:
        with _open_machine_key(registry, path, view) as key:
            return registry.QueryValueEx(key, name)[0]
    except OSError:
        return None


def _subkey_names(registry, path, view):
    try:
        with _open_machine_key(registry, path, view) as key:
            names = []
            for index in range(MAX_INSTANCE_SUBKEYS):
                try:
                    names.append(registry.EnumKey(key, index))
                except OSError:  # ERROR_NO_MORE_ITEMS
                    break
            return names
    except OSError:
        return []


def _listed(registry, view):
    """Whether the DirectShow video input category lists Softcam's CLSID in this registry view: a
    subkey of ...\\Instance whose CLSID value is ours. Softcam 1.8.1 names it "DirectShow Softcam";
    any name counts as long as its CLSID value points at the filter, and a subkey without that
    value never does."""
    names = sorted(_subkey_names(registry, INSTANCE_ROOT_KEY, view),
                   key=lambda name: name.lower() != CAMERA_NAME.lower())  # the usual name first
    for name in names:
        value = _read_value(registry, INSTANCE_ROOT_KEY + "\\" + name, "CLSID", view)
        if isinstance(value, str) and value.strip().upper() == CLSID.upper():
            return True
    return False


def _normalized_path(value):
    if not isinstance(value, str) or not value.strip():
        return None
    return os.path.normcase(os.path.normpath(value.strip().strip('"')))


_VERSION_FOLDER = re.compile(r"[0-9a-f]{16}")


def orbit_dll_path(value, name):
    """`value` (a registered InprocServer32 path), cleaned up, when it names Orbit's own copy of
    `name` in a version folder of the admin-only webcam folder; None for anything else (another
    program's camera, environment variables, odd values). Only such paths are ever handed to an
    elevated regsvr32."""
    if not isinstance(value, str):
        return None
    text = value.strip().strip('"')
    if not text or "%" in text:
        return None
    actual = os.path.normcase(os.path.normpath(text))
    folder, file_name = os.path.split(actual)
    root = os.path.normcase(os.path.normpath(str(webcam_root())))
    if file_name != os.path.normcase(name) or os.path.dirname(folder) != root:
        return None
    if not _VERSION_FOLDER.fullmatch(os.path.basename(folder).lower()):
        return None
    return os.path.normpath(text)


@dataclass(frozen=True)
class Registration:
    ok: bool
    problem: object  # None, "missing", "notListed", "olderOrbit" or "otherProgram"
    paths: dict      # dll name -> the registered InprocServer32 path (None when missing)


_PROBLEM_ORDER = ("otherProgram", "olderOrbit", "missing", "notListed")


def registration_state(layout, folder=None, registry=None):
    """Whether both views register exactly these DLLs as the Softcam camera, listed in the
    DirectShow video input category."""
    registry = winreg if registry is None else registry
    folder = Path(folder) if folder is not None else install_directory()
    if registry is None:
        return Registration(False, "missing", {})
    problems, paths = [], {}
    for target in layout.targets:
        value = _read_value(registry, INPROC_KEY, "", target.view)
        paths[target.name] = value if isinstance(value, str) else None
        actual = _normalized_path(value)
        if actual is None:
            problems.append("missing")
        elif actual != _normalized_path(str(folder / target.name)):
            problems.append("olderOrbit" if orbit_dll_path(value, target.name) else "otherProgram")
        elif not _listed(registry, target.view):
            problems.append("notListed")
    problem = next((name for name in _PROBLEM_ORDER if name in problems), None)
    return Registration(problem is None, problem, paths)


def orbit_registrations(layout, registry=None):
    """{dll name: path} for the registry views whose camera is one of Orbit's webcam DLLs (any version)."""
    paths = registration_state(layout, registry=registry).paths
    owned = {}
    for target in layout.targets:
        path = orbit_dll_path(paths.get(target.name), target.name)
        if path:
            owned[target.name] = path
    return owned


def webcam_files_left():
    """Whether anything is left in the webcam folder (a removal deletes it)."""
    try:
        return any(webcam_root().iterdir())
    except OSError:
        return False


# Visual C++ runtime --------------------------------------------------------------------------

class VS_FIXEDFILEINFO(ctypes.Structure):
    _fields_ = [("dwSignature", ctypes.c_uint32), ("dwStrucVersion", ctypes.c_uint32),
                ("dwFileVersionMS", ctypes.c_uint32), ("dwFileVersionLS", ctypes.c_uint32),
                ("dwProductVersionMS", ctypes.c_uint32), ("dwProductVersionLS", ctypes.c_uint32),
                ("dwFileFlagsMask", ctypes.c_uint32), ("dwFileFlags", ctypes.c_uint32),
                ("dwFileOS", ctypes.c_uint32), ("dwFileType", ctypes.c_uint32), ("dwFileSubtype", ctypes.c_uint32),
                ("dwFileDateMS", ctypes.c_uint32), ("dwFileDateLS", ctypes.c_uint32)]


def _parse_version(text):
    if not isinstance(text, str):
        return None
    parts = text.strip().lstrip("vV").split(".")
    try:
        numbers = tuple(int(part) for part in parts[:3])
    except ValueError:
        return None
    if len(numbers) < 2:
        return None
    return numbers + (0,) * (3 - len(numbers))


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _runtime_from_registry(registry, arch, views):
    best = None
    for view in views:
        try:
            with _open_machine_key(registry, VC_RUNTIME_KEY + "\\" + arch, view) as key:
                values = {}
                for name in ("Installed", "Major", "Minor", "Bld", "Version"):
                    try:
                        values[name] = registry.QueryValueEx(key, name)[0]
                    except OSError:
                        values[name] = None
        except OSError:
            continue
        if values["Installed"] not in (1, "1"):
            continue
        if _is_int(values["Major"]) and _is_int(values["Minor"]):
            version = (values["Major"], values["Minor"], values["Bld"] if _is_int(values["Bld"]) else 0)
        else:
            version = _parse_version(values["Version"])
        if version is not None and (best is None or version > best):
            best = version
    return best


def _file_version(path):
    """(major, minor, build) from a DLL's VS_FIXEDFILEINFO; None when unknown."""
    if not os.path.isfile(path):
        return None
    try:
        library = ctypes.WinDLL("version")
        library.GetFileVersionInfoSizeW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
        library.GetFileVersionInfoSizeW.restype = ctypes.c_uint32
        library.GetFileVersionInfoW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        library.GetFileVersionInfoW.restype = ctypes.c_int
        library.VerQueryValueW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_void_p),
                                           ctypes.POINTER(ctypes.c_uint)]
        library.VerQueryValueW.restype = ctypes.c_int
        ignored = ctypes.c_uint32(0)
        size = int(library.GetFileVersionInfoSizeW(str(path), ctypes.byref(ignored)) or 0)
        if not 0 < size <= 1024 * 1024:
            return None
        block = ctypes.create_string_buffer(size)
        if not library.GetFileVersionInfoW(str(path), 0, size, block):
            return None
        pointer, length = ctypes.c_void_p(), ctypes.c_uint(0)
        if not library.VerQueryValueW(block, "\\", ctypes.byref(pointer), ctypes.byref(length)):
            return None
        start, end = ctypes.addressof(block), ctypes.addressof(block) + size
        needed = ctypes.sizeof(VS_FIXEDFILEINFO)
        if not pointer.value or length.value < needed or not start <= pointer.value <= end - needed:
            return None
        info = VS_FIXEDFILEINFO.from_address(pointer.value)
        if info.dwSignature != 0xFEEF04BD:
            return None
        return (info.dwFileVersionMS >> 16, info.dwFileVersionMS & 0xFFFF, info.dwFileVersionLS >> 16)
    except Exception:
        return None


def _runtime_from_files(folder, arch):
    versions = [_file_version(os.path.join(folder, name)) for name in VC_RUNTIME_FILES[arch]]
    if not versions or any(version is None for version in versions):
        return None
    return min(versions)


def _format_version(version):
    return ".".join(str(part) for part in version) if version else None


def vc_runtime_status(layout, registry=None):
    """The installed VC++ 2015-2022 runtime per needed arch (registry, else the DLL file versions)."""
    registry = winreg if registry is None else registry
    views = (KEY_WOW64_64KEY, KEY_WOW64_32KEY) if layout.machine == "x64" else (0,)
    found = {}
    for target in layout.targets:
        arch = target.runtime
        version = _runtime_from_registry(registry, arch, views) if registry is not None else None
        if version is None or version[:2] < MIN_VC_RUNTIME:
            from_files = _runtime_from_files(layout.runtime_dirs.get(arch, ""), arch)
            if from_files is not None and (version is None or from_files > version):
                version = from_files
        found[arch] = version
    missing = [arch for arch, version in found.items() if version is None or version[:2] < MIN_VC_RUNTIME]
    status = {"ok": not missing, "required": _format_version(MIN_VC_RUNTIME)}
    status.update({arch: _format_version(version) for arch, version in found.items()})
    status["missing"] = missing
    status["commands"] = [WINGET_COMMANDS[arch] for arch in missing]
    return status


def runtime_message(runtime):
    archs = [arch for arch in ("x64", "x86") if arch in runtime]
    details = []
    for arch in runtime["missing"]:
        found = runtime.get(arch)
        details.append(f"{arch}: version {found} is too old" if found else f"{arch}: not installed")
    return (f"The iPhone webcam needs the Microsoft Visual C++ 2015–2022 Redistributable {runtime['required']} or "
            f"newer for {' and '.join(archs)} ({'; '.join(details)}). On the PC, open Terminal and run "
            f"{' and then '.join(runtime['commands'])} (use winget upgrade instead of winget install when an older "
            f"version is installed), or download the installers from {VC_REDIST_PAGE}. Then set up the webcam again.")


# Getting verified DLLs -------------------------------------------------------------------------

_RELEASE_VERSION = re.compile(r"\d+\.\d+\.\d+")


def _agent_version():
    try:
        return str(orbit_capabilities.capabilities_payload().get("agentVersion") or "")
    except Exception:
        return ""


def download_refs():
    """Where in the repository to download the DLLs from: this agent's release tag first (a tag
    never moves, so these exact files stay there even after main switches to a newer Softcam
    build), then main for builds that have no release yet."""
    version = _agent_version()
    return ([f"pc-v{version}"] if _RELEASE_VERSION.fullmatch(version) else []) + ["main"]


def download_url(name, ref="main"):
    import orbit_updater
    return (f"https://raw.githubusercontent.com/{orbit_updater.GITHUB_OWNER}/{orbit_updater.GITHUB_REPO}/{ref}/"
            f"{DOWNLOAD_FOLDER}{name}")


def _write_atomically(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def download_dll(name, fetch=None):
    """Downloads one DLL into the cache (see download_refs); only a file with the pinned SHA-256
    is kept. Raises InstallError(503)."""
    import orbit_updater
    fetch = fetch or orbit_updater._fetch_bytes
    http_error, mismatch = None, False
    for ref in download_refs():
        try:
            data = fetch(download_url(name, ref), timeout=20.0, accept="application/octet-stream")
        except urllib.error.HTTPError as error:
            http_error = error  # 404: no such release tag (yet); try the next ref
            continue
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise InstallError(503, f"Could not download the webcam driver ({name}) from GitHub. Check the PC's "
                                    "internet connection, or download the full Orbit PC Companion again, then try "
                                    "again.") from error
        if len(data) > MAX_DLL_BYTES or hashlib.sha256(data).hexdigest() != DLL_SHA256[name]:
            LOGGER.warning("The %s downloaded from %s does not match the pinned SHA-256; not used", name, ref)
            mismatch = True
            continue
        path = cache_directory() / name
        try:
            _write_atomically(path, data)
        except OSError as error:
            raise InstallError(503, "Could not save the downloaded webcam driver on the PC. Check the free disk "
                                    "space and try again.") from error
        return path
    if mismatch:
        raise InstallError(503, f"The webcam driver on GitHub ({name}) is a different version than this Orbit PC "
                                "Companion expects, so it was not used. Update Orbit PC Companion from its tray menu, "
                                "then try again.")
    code = f" (HTTP {http_error.code})" if http_error is not None else ""
    raise InstallError(503, f"Could not download the webcam driver ({name}) from GitHub{code}. Download the full "
                            "Orbit PC Companion again and try again.")


def source_directories():
    """Where verified DLLs may already be: the installed folder (admin-only), next to the agent,
    and the download cache."""
    return [install_directory()] + bundled_directories() + [cache_directory()]


def ensure_sources(layout, download=None):
    """A verified copy of every DLL this PC needs: installed, bundled, cached or freshly downloaded."""
    sources = {}
    for target in layout.targets:
        name = target.name
        source = next((folder / name for folder in source_directories()
                       if is_verified(folder / name, name, use_cache=False)), None)
        if source is None:
            LOGGER.info("%s is missing or different next to the agent; downloading it", name)
            source = (download or download_dll)(name)
            if not is_verified(source, name, use_cache=False):
                raise InstallError(503, f"The webcam driver ({name}) could not be verified. Try again.")
        sources[name] = Path(source)
    return sources


# The elevated step -------------------------------------------------------------------------------

_PS_QUOTES = "'\u2018\u2019\u201a\u201b"  # PowerShell ends a single-quoted string at any of these


def ps_quote(value):
    """A PowerShell single-quoted literal. Paths with double quotes or control characters (which
    Windows paths cannot contain) are refused, so the command line never needs double quotes."""
    text = str(value)
    if '"' in text or any(ord(character) < 32 for character in text):
        raise InstallError(503, "A webcam folder path contains characters Windows PowerShell cannot take. Move "
                                "Orbit PC Companion to a simpler folder and try again.")
    return "'" + "".join(character * 2 if character in _PS_QUOTES else character for character in text) + "'"


REPARSE_POINT = 0x400  # FILE_ATTRIBUTE_REPARSE_POINT: a junction or symbolic link
_VERSION_FOLDER_PATTERN = "'^[0-9a-f]{16}$'"


def _fails(path_expression, expected):
    """PowerShell condition: the file's SHA-256 is not `expected`."""
    return (f"(Get-FileHash -LiteralPath {path_expression} -Algorithm SHA256 -ErrorAction Stop).Hash "
            f"-ne '{expected}'")


def _is_link(path_expression):
    """PowerShell condition: the existing folder is a junction or symbolic link."""
    attributes = f"[int]((Get-Item -LiteralPath {path_expression} -Force -ErrorAction Stop).Attributes)"
    return f"(({attributes} -band {REPARSE_POINT}) -ne 0)"


def _regsvr32(executable, dll, unregister=False):
    return f"& {ps_quote(executable)} {'/u /s' if unregister else '/s'} {ps_quote(dll)} 2>&1 | Out-Null"


def _exit_on_failure(base, cleanup=()):
    """After a regsvr32: exit with base + its exit code (0-9; 9 = other) when it failed."""
    steps = ["$c = [int]$LASTEXITCODE", "if ($c -lt 0 -or $c -gt 9) { $c = 9 }", *cleanup, f"exit ({base} + $c)"]
    return "if ($LASTEXITCODE -ne 0) { " + "; ".join(steps) + " }"


def _old_version_folders(webcam, keep=None):
    """Pipeline that deletes Orbit's version folders in `webcam` (not links, not `keep`)."""
    keep_test = f"$_.Name -ne {ps_quote(keep)} -and " if keep else ""
    return (f"Get-ChildItem -LiteralPath {webcam} -Directory -Force -ErrorAction SilentlyContinue | Where-Object {{ "
            f"{keep_test}$_.Name -match {_VERSION_FOLDER_PATTERN} -and "
            f"(([int]$_.Attributes) -band {REPARSE_POINT}) -eq 0 }} | Remove-Item -Recurse -Force "
            "-ErrorAction SilentlyContinue")


def elevation_script(layout, folder, sources, previous=None):
    """The one-line PowerShell script the setup's UAC prompt runs. `previous` maps each DLL name to
    the path its registry view pointed at before (for the rollback). Exit codes: 0 done; 13 the
    folder could not be created; 14 a folder is a link (reparse point); 20 a copy failed; 21 a hash
    did not match; 30-39 / 40-49 regsvr32 failed for the first / second DLL (code - 30 or - 40 is
    regsvr32's own exit code: 3 = the DLL could not be loaded, 5 = DllRegisterServer failed, 9 =
    other); 90 the script failed.

    The folder is in Program Files, so only administrators can have put anything there. Nothing
    is written before its hash is checked in memory. Cmdlets that matter stop on errors
    (-ErrorAction Stop, caught or trapped); native tools are judged by $LASTEXITCODE only, so
    their messages on stderr never abort the script. Piping regsvr32 (a GUI program) to Out-Null
    makes PowerShell wait for it and set $LASTEXITCODE.
    """
    q = ps_quote
    folder = Path(folder)
    webcam = folder.parent
    previous = previous or {}
    statements = [
        "trap { exit 90 }",
        "$step = 'orbit-webcam-install'",
        f"try {{ [void][IO.Directory]::CreateDirectory({q(folder)}) }} catch {{ exit 13 }}",
        f"foreach ($p in @({', '.join(q(path) for path in (webcam.parent, webcam, folder))})) "
        f"{{ if {_is_link('$p')} {{ exit 14 }} }}",
    ]
    for target in layout.targets:
        expected = DLL_SHA256[target.name].upper()
        statements += [
            f"$d = {q(folder / target.name)}",
            f"$s = {q(sources[target.name])}",
            f"if (-not (Test-Path -LiteralPath $d -PathType Leaf) -or {_fails('$d', expected)}) {{ $b = $null; "
            f"try {{ if ((Get-Item -LiteralPath $s -Force -ErrorAction Stop).Length -le {MAX_DLL_BYTES}) "
            "{ $b = [IO.File]::ReadAllBytes($s) } } catch { exit 20 }; if ($null -eq $b) { exit 21 }; "
            "if ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '') "
            f"-ne '{expected}') {{ exit 21 }}; try {{ [IO.File]::WriteAllBytes($d, $b) }} catch {{ exit 20 }} }}",
            f"if ({_fails('$d', expected)}) "
            "{ Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue; exit 21 }",
        ]
    done = []
    for index, target in enumerate(layout.targets):
        new = folder / target.name
        statements.append(_regsvr32(target.regsvr32, new))
        cleanup = [step for step in (_undo(item, previous) for item in done) if step]
        restore = _restorable(target, new, previous)
        if restore:  # Put the older Orbit webcam back in the view whose registration just failed.
            cleanup.append(f"if (Test-Path -LiteralPath {q(restore)} -PathType Leaf) "
                           f"{{ {_regsvr32(target.regsvr32, restore)} }}")
        statements.append(_exit_on_failure(30 + 10 * index, cleanup))
        done.append((target, new))
    statements.append(_old_version_folders(q(webcam), keep=folder.name))
    statements.append("exit 0")
    return "; ".join(statements)


def _restorable(target, new, previous):
    """The older Orbit DLL that `target`'s view pointed at before, when it can be registered again."""
    before = previous.get(target.name)
    if _normalized_path(before) == _normalized_path(str(new)):
        return None
    return orbit_dll_path(before, target.name)


def _undo(item, previous):
    """Rollback of a registration this script made: back to how that view was before the prompt."""
    target, new = item
    if _normalized_path(previous.get(target.name)) == _normalized_path(str(new)):
        return ""  # It was registered to this very file already: leave it.
    restore = _restorable(target, new, previous)
    remove = _regsvr32(target.regsvr32, new, unregister=True)
    if restore:
        return (f"if (Test-Path -LiteralPath {ps_quote(restore)} -PathType Leaf) "
                f"{{ {_regsvr32(target.regsvr32, restore)} }} else {{ {remove} }}")
    # Nothing (or another program's camera, whose DLL is never run elevated) was there before.
    return remove


def _classes_key(target):
    classes = "SOFTWARE\\Classes\\WOW6432Node" if target.view == KEY_WOW64_32KEY else "SOFTWARE\\Classes"
    return "Registry::HKEY_LOCAL_MACHINE\\" + classes


def uninstall_script(layout, owned):
    """The one-line PowerShell script the removal's UAC prompt runs. `owned` maps DLL names to
    the Orbit webcam DLL their registry view points at (see orbit_registrations); other views are
    left alone. Exit codes: 0 done; 14 the webcam folder is a link, so it was not deleted; 50 files
    are still in use and stay; 60-69 / 70-79 regsvr32 /u failed for the first / second DLL; 90 the
    script failed."""
    q = ps_quote
    statements = ["trap { exit 90 }", "$step = 'orbit-webcam-uninstall'"]
    for index, target in enumerate(layout.targets):
        path = owned.get(target.name)
        if not path:
            continue
        classes = _classes_key(target)
        clsid_key = classes + "\\CLSID\\" + CLSID
        instances = classes + "\\CLSID\\" + VIDEO_INPUT_CATEGORY + "\\Instance"
        # When the DLL is gone, DllUnregisterServer cannot run: delete what it would have deleted.
        statements.append(
            f"if (Test-Path -LiteralPath {q(path)} -PathType Leaf) {{ "
            f"{_regsvr32(target.regsvr32, path, unregister=True)}; {_exit_on_failure(60 + 10 * index)} }} else {{ "
            f"Remove-Item -LiteralPath {q(clsid_key)} -Recurse -Force -ErrorAction SilentlyContinue; "
            f"Get-ChildItem -LiteralPath {q(instances)} -ErrorAction SilentlyContinue | Where-Object "
            f"{{ $_.GetValue('CLSID') -eq {q(CLSID)} }} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }}")
    webcam, orbit = webcam_root(), orbit_program_files()
    statements += [
        f"$w = {q(webcam)}",
        f"if (Test-Path -LiteralPath $w) {{ if {_is_link('$w')} {{ exit 14 }}; {_old_version_folders('$w')}; "
        f"try {{ [IO.Directory]::Delete($w) }} catch {{ }}; try {{ [IO.Directory]::Delete({q(orbit)}) }} catch {{ }} }}",
        "if (Test-Path -LiteralPath $w) { exit 50 }",
        "exit 0",
    ]
    return "; ".join(statements)


def powershell_parameters(script):
    if '"' in script:
        raise ValueError("The elevated script must not contain double quotes")
    return f'-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "{script}"'


SEE_MASK_NOCLOSEPROCESS = 0x00000040
SEE_MASK_NOASYNC = 0x00000100
SW_HIDE = 0
ERROR_FILE_NOT_FOUND = 2
ERROR_CANCELLED = 1223
WAIT_OBJECT_0 = 0x00000000
WAIT_TIMEOUT = 0x00000102
COINIT_APARTMENTTHREADED = 0x2
COINIT_DISABLE_OLE1DDE = 0x4


class SHELLEXECUTEINFOW(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint32), ("fMask", ctypes.c_uint32), ("hwnd", ctypes.c_void_p),
                ("lpVerb", ctypes.c_wchar_p), ("lpFile", ctypes.c_wchar_p), ("lpParameters", ctypes.c_wchar_p),
                ("lpDirectory", ctypes.c_wchar_p), ("nShow", ctypes.c_int), ("hInstApp", ctypes.c_void_p),
                ("lpIDList", ctypes.c_void_p), ("lpClass", ctypes.c_wchar_p), ("hkeyClass", ctypes.c_void_p),
                ("dwHotKey", ctypes.c_uint32), ("hIconOrMonitor", ctypes.c_void_p), ("hProcess", ctypes.c_void_p)]


class ElevationDeclined(Exception):
    """The user chose No in the UAC prompt (or could not give administrator credentials)."""


class ElevationFailed(Exception):
    def __init__(self, code):
        super().__init__(f"Windows error {code}")
        self.code = code


def run_elevated(executable, parameters, timeout=ELEVATED_TIMEOUT_SECONDS):
    """Starts `executable` as administrator through one UAC prompt and waits for it to finish.

    Returns the exit code, or None when Windows returned no process handle. Raises
    ElevationDeclined, ElevationFailed or TimeoutError. ShellExecuteExW blocks until the prompt
    is answered, so call this on a worker thread.
    """
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ole32 = ctypes.WinDLL("ole32")
    shell32.ShellExecuteExW.argtypes = [ctypes.POINTER(SHELLEXECUTEINFOW)]
    shell32.ShellExecuteExW.restype = ctypes.c_int
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.WaitForSingleObject.restype = ctypes.c_uint32
    kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel32.GetExitCodeProcess.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    ole32.CoInitializeEx.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    ole32.CoInitializeEx.restype = ctypes.c_long
    ole32.CoUninitialize.argtypes = []
    ole32.CoUninitialize.restype = None

    info = SHELLEXECUTEINFOW()
    info.cbSize = ctypes.sizeof(SHELLEXECUTEINFOW)
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC
    info.hwnd = None
    info.lpVerb = "runas"
    info.lpFile = str(executable)
    info.lpParameters = parameters
    info.lpDirectory = None
    info.nShow = SW_HIDE
    # ShellExecuteEx wants COM initialized on the calling thread (single-threaded apartment).
    initialized = ole32.CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) in (0, 1)
    try:
        succeeded = shell32.ShellExecuteExW(ctypes.byref(info))
        error = 0 if succeeded else ctypes.get_last_error()
    finally:
        if initialized:
            ole32.CoUninitialize()
    if not succeeded:
        if error == ERROR_CANCELLED:
            raise ElevationDeclined()
        raise ElevationFailed(error)
    handle = info.hProcess
    if not handle:
        return None
    try:
        waited = kernel32.WaitForSingleObject(handle, int(max(0.0, timeout) * 1000))
        if waited == WAIT_TIMEOUT:
            raise TimeoutError("The elevated setup did not finish in time")
        if waited != WAIT_OBJECT_0:
            raise ElevationFailed(ctypes.get_last_error())
        code = ctypes.c_uint32(0)
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            raise ElevationFailed(ctypes.get_last_error())
        return code.value
    finally:
        kernel32.CloseHandle(handle)


def failure_message(code, layout, timed_out, registration):
    """A plain sentence for a setup that did not end with a verified registration."""
    if timed_out:
        return "The webcam setup on the PC did not finish within 2 minutes. Try again."
    if code == 13:
        return f"Windows could not create the webcam folder ({install_directory()}), so nothing was registered. Try again."
    if code == 14:
        return (f"The webcam folder ({webcam_root()}) or its parent is a link to another folder, so nothing was "
                "registered. Delete that link and try again.")
    if code == 20:
        return ("Windows could not copy the webcam files. Close apps that may be using a camera (Zoom, Teams, "
                "browsers, OBS) and try again.")
    if code == 21:
        return "The webcam files changed during setup, so nothing was registered. Try again."
    if isinstance(code, int) and 30 <= code < 30 + 10 * len(layout.targets):
        target = layout.targets[(code - 30) // 10]
        detail = (code - 30) % 10
        if detail == 3:
            return (f"Windows could not load the webcam driver ({target.name}), so nothing was registered. The "
                    "Microsoft Visual C++ Redistributable (x64 and x86) may be missing or damaged, or antivirus or "
                    f"Smart App Control blocked the file. Install or repair it from {VC_REDIST_PAGE}, then try again.")
        return (f"Windows could not register the webcam driver ({target.name}, regsvr32 error {detail}), so nothing "
                "was registered. Try again.")
    if code == 90:
        return "The webcam setup script failed on the PC. Try again."
    if code in (0, None):
        problem = registration.problem or "missing"
        return ("Windows finished the setup, but the camera is not registered correctly. "
                + REGISTRATION_MESSAGES.get(problem, REGISTRATION_MESSAGES["missing"]))
    return f"The webcam setup failed on the PC (code {code}). Try again."


def _elevate(elevate, layout, script, what):
    """Runs the script through the one UAC prompt. Returns (exit code or None, timed out)."""
    try:
        return (elevate or run_elevated)(layout.powershell, powershell_parameters(script),
                                         ELEVATED_TIMEOUT_SECONDS), False
    except ElevationDeclined as error:
        raise InstallError(403, f"The webcam was not {what}: the Windows administrator prompt was declined on the PC. "
                                "Try again and choose Yes. If you are not an administrator on this PC, ask one to "
                                "approve it.") from error
    except ElevationFailed as error:
        if error.code == ERROR_FILE_NOT_FOUND:
            message = f"Windows PowerShell was not found on the PC, so the webcam could not be {what}."
            raise InstallError(503, message) from error
        raise InstallError(503, f"Windows could not ask for administrator permission (error {error.code}). Try "
                                "again.") from error
    except TimeoutError:
        return None, True


def install_webcam(progress=lambda stage: None, *, elevate=None, download=None, registry=None):
    """Sets the webcam up (see the module docstring). Returns "installed" or "alreadyInstalled";
    raises InstallError. Blocks while the UAC prompt is open."""
    try:
        layout = platform_layout()
    except UnsupportedPC as error:
        raise InstallError(409, str(error)) from error
    runtime = vc_runtime_status(layout, registry)
    if not runtime["ok"]:
        raise InstallError(409, runtime_message(runtime))
    progress("preparing")
    folder = install_directory()
    before = registration_state(layout, folder, registry)
    if files_installed(layout, folder) and before.ok:
        return "alreadyInstalled"  # Before any download: a set-up PC needs no source files.
    sources = ensure_sources(layout, download)
    script = elevation_script(layout, folder, sources, previous=before.paths)
    progress("waitingForApproval")
    orbit_notify.notify("Approve the webcam setup",
                        "Windows asks whether Windows PowerShell may make changes. Choose Yes to finish setting up the "
                        "iPhone webcam. No prompt on screen? Click the flashing shield in the taskbar.")
    code, timed_out = _elevate(elevate, layout, script, "set up")
    progress("verifying")
    registration = registration_state(layout, folder, registry)
    if files_installed(layout, folder) and registration.ok:
        if code not in (0, None):
            LOGGER.warning("The elevated webcam setup exited with %s, but the registration is complete", code)
        orbit_notify.notify("iPhone webcam is set up",
                            f'Apps on this PC can now use the "{CAMERA_NAME}" camera. Restart apps that were already '
                            "open.")
        return "installed"
    LOGGER.warning("Webcam setup failed: exit %s, timed out %s, registration %s", code, timed_out, registration)
    raise InstallError(503, failure_message(code, layout, timed_out, registration))


def uninstall_failure_message(code, layout, timed_out):
    """A plain sentence for a removal after which Windows still lists Orbit's camera."""
    if timed_out:
        return "Removing the webcam on the PC did not finish within 2 minutes. Try again."
    if isinstance(code, int) and 60 <= code < 60 + 10 * len(layout.targets):
        target = layout.targets[(code - 60) // 10]
        return (f"Windows could not remove the webcam driver ({target.name}, regsvr32 error {(code - 60) % 10}). Close "
                "apps that may be using a camera (Zoom, Teams, browsers, OBS) and try again.")
    if code == 90:
        return "The webcam removal script failed on the PC. Try again."
    return "Windows still lists Orbit's DirectShow Softcam camera on the PC. Try again."


def uninstall_webcam(progress=lambda stage: None, *, elevate=None, registry=None, camera=None):
    """Removes Orbit's webcam from Windows (see the module docstring). Returns "uninstalled" or
    "notInstalled"; raises InstallError. Blocks while the UAC prompt is open."""
    try:
        layout = platform_layout()
    except UnsupportedPC as error:
        raise InstallError(409, str(error)) from error
    progress("preparing")
    owned = orbit_registrations(layout, registry)
    if not owned and not webcam_files_left():
        return "notInstalled"
    script = uninstall_script(layout, owned)
    progress("waitingForApproval")
    orbit_notify.notify("Approve removing the webcam",
                        "Windows asks whether Windows PowerShell may make changes. Choose Yes to remove the iPhone "
                        "webcam from this PC. No prompt on screen? Click the flashing shield in the taskbar.")
    code, timed_out = _elevate(elevate, layout, script, "removed")
    progress("verifying")
    remaining = orbit_registrations(layout, registry)
    if remaining:
        LOGGER.warning("Webcam removal failed: exit %s, timed out %s, still registered %s", code, timed_out, remaining)
        raise InstallError(503, uninstall_failure_message(code, layout, timed_out))
    if code not in (0, 14, 50, None):
        LOGGER.warning("The elevated webcam removal exited with %s, but nothing of Orbit's is registered", code)
    (camera or CAMERA).end_all(CameraError("notInstalled", REMOVED_MESSAGE, CLOSE_NOT_INSTALLED))
    left = webcam_files_left()
    if left:
        LOGGER.info("Webcam files are still in use and stay in %s", webcam_root())
    orbit_notify.notify("iPhone webcam removed",
                        f'The "{CAMERA_NAME}" camera was removed from this PC.'
                        + (f" Some files are still in use and stay in {webcam_root()}; restart the PC and remove the "
                           "webcam again to delete them." if left else ""))
    return "uninstalled"


class Installer:
    """At most one setup or removal at a time. Callers asking for the one that runs share its
    result; asking for the other one meanwhile is refused (409)."""

    def __init__(self, runner=None, uninstaller=None):
        self._runner = runner
        self._uninstaller = uninstaller
        self._lock = threading.Lock()
        self._future = None
        self._operation = None
        self._stage = None
        self.last_error = None

    def start(self, operation="install"):
        if operation not in BUSY_MESSAGES:
            raise ValueError(f"Unknown webcam operation {operation!r}")
        with self._lock:
            if self._future is not None and not self._future.done():
                if self._operation != operation:
                    raise InstallError(409, BUSY_MESSAGES[self._operation])
                return self._future
            future = concurrent.futures.Future()
            future.set_running_or_notify_cancel()
            self._future = future
            self._operation = operation
            self._stage = "preparing"
            self.last_error = None
        threading.Thread(target=self._run, args=(future, operation), name=f"orbit-webcam-{operation}",
                         daemon=True).start()
        return future

    def _set_stage(self, stage):
        with self._lock:
            self._stage = stage

    def _run(self, future, operation):
        if operation == "install":
            runner = self._runner or install_webcam
        else:
            runner = self._uninstaller or uninstall_webcam
        try:
            result = runner(progress=self._set_stage)
        except InstallError as error:
            failure = error
        except BaseException:
            LOGGER.exception("Webcam %s failed", operation)
            what = "setup" if operation == "install" else "removal"
            failure = InstallError(503, f"Webcam {what} failed on the PC. Try again; agent.log has the details.")
        else:
            with self._lock:
                self._stage = None
            future.set_result(result)
            return
        with self._lock:
            self._stage = None
            self.last_error = failure.message
        future.set_exception(failure)

    def _running(self, operation):
        with self._lock:
            return self._future is not None and not self._future.done() and self._operation == operation

    @property
    def installing(self):
        return self._running("install")

    @property
    def uninstalling(self):
        return self._running("uninstall")

    @property
    def stage(self):
        with self._lock:
            running = self._future is not None and not self._future.done()
            return self._stage if running else None


# Frames ------------------------------------------------------------------------------------------

def is_jpeg(data):
    return len(data) >= 4 and bytes(data[:3]) == b"\xff\xd8\xff"


def fit_frame(image, width, height):
    """Scales an RGB image to fit width x height, keeping its aspect ratio, centred on black."""
    source_width, source_height = image.size
    scale = min(width / source_width, height / source_height)
    fitted = (max(1, min(width, round(source_width * scale))), max(1, min(height, round(source_height * scale))))
    if fitted != image.size:
        image = image.resize(fitted, Image.Resampling.BILINEAR)
    if fitted == (width, height):
        return image
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(image, ((width - fitted[0]) // 2, (height - fitted[1]) // 2))
    return canvas


def jpeg_to_bgr(data, width, height):
    """One JPEG frame as top-down 24-bit BGR rows of exactly width x height (what scSendFrame
    takes). Raises FrameError for anything that is not a decodable JPEG of a sane size."""
    if not HAS_PILLOW:
        raise FrameError("Pillow is not installed")
    if not is_jpeg(data):
        raise FrameError("not a JPEG image")
    try:
        with Image.open(io.BytesIO(data), formats=["JPEG"]) as image:
            source_width, source_height = image.size
            if min(source_width, source_height) < MIN_SOURCE_SIDE or source_width * source_height > MAX_SOURCE_PIXELS:
                raise FrameError(f"unsupported frame size {source_width}x{source_height}")
            if (source_width, source_height) != (width, height):
                image.draft("RGB", (width, height))  # libjpeg scales big frames down while decoding
            image.load()
            picture = image if image.mode == "RGB" else image.convert("RGB")
            if picture.size != (width, height):
                picture = fit_frame(picture, width, height)
            return picture.tobytes("raw", "BGR")
    except FrameError:
        raise
    except (OSError, SyntaxError, ValueError, Image.DecompressionBombError) as error:
        raise FrameError("damaged JPEG image") from error


# Softcam ----------------------------------------------------------------------------------------

class SoftcamLibrary:
    """ctypes binding of softcam.h (plain C exports, __cdecl on 32-bit):

        scCamera scCreateCamera(int width, int height, float framerate);  // NULL on failure
        void     scDeleteCamera(scCamera camera);
        void     scSendFrame(scCamera camera, const void* image_bits);    // top-down BGR24
        bool     scWaitForConnection(scCamera camera, float timeout);
        bool     scIsConnected(scCamera camera);

    Softcam has no locking of its own, so one thread makes every call (CameraManager's worker).
    """

    def __init__(self, dll):
        self._dll = dll
        dll.scCreateCamera.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_float]
        dll.scCreateCamera.restype = ctypes.c_void_p
        dll.scDeleteCamera.argtypes = [ctypes.c_void_p]
        dll.scDeleteCamera.restype = None
        dll.scSendFrame.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        dll.scSendFrame.restype = None
        dll.scWaitForConnection.argtypes = [ctypes.c_void_p, ctypes.c_float]
        dll.scWaitForConnection.restype = ctypes.c_bool
        dll.scIsConnected.argtypes = [ctypes.c_void_p]
        dll.scIsConnected.restype = ctypes.c_bool

    @classmethod
    def load(cls, path):
        return cls(ctypes.CDLL(str(path)))

    def create(self, width, height, fps):
        handle = self._dll.scCreateCamera(int(width), int(height), float(fps))
        return int(handle) if handle else None

    def delete(self, camera):
        self._dll.scDeleteCamera(camera)

    def send(self, camera, bgr):
        self._dll.scSendFrame(camera, bgr)

    def is_connected(self, camera):
        return bool(self._dll.scIsConnected(camera))

    def wait_for_connection(self, camera, timeout):
        return bool(self._dll.scWaitForConnection(camera, float(timeout)))


_LIBRARY_LOCK = threading.Lock()
_LIBRARY = None


def load_sender_library():
    """Loads the verified, registered Softcam DLL of this process's bitness (once per process)."""
    global _LIBRARY
    with _LIBRARY_LOCK:
        if _LIBRARY is not None:
            return _LIBRARY
        try:
            layout = platform_layout()
        except UnsupportedPC as error:
            raise CameraError("unsupported", str(error), CLOSE_UNSUPPORTED_PC) from error
        path = install_directory() / layout.sender_dll
        if not is_verified(path, layout.sender_dll, use_cache=False):
            raise CameraError("notInstalled", REGISTRATION_MESSAGES["missing"], CLOSE_NOT_INSTALLED)
        try:
            library = SoftcamLibrary.load(path)
        except (OSError, AttributeError) as error:
            LOGGER.warning("Could not load %s: %s", path, error)
            raise CameraError("cameraUnavailable", "Windows could not load the webcam driver in Orbit PC Companion. "
                                                   "Install or repair the Microsoft Visual C++ Redistributable (x64 "
                                                   "and x86), then restart Orbit PC Companion.",
                              CLOSE_CAMERA_UNAVAILABLE) from error
        _LIBRARY = library
        return library


def _emit_connected(camera_format):
    width, height, fps = camera_format
    try:
        orbit_events.emit("webcam.connected", "iPhone webcam is on",
                          f'Apps on this PC can now use the "{CAMERA_NAME}" camera ({width}×{height}, {fps} fps).',
                          level="passive", data={"width": width, "height": height, "fps": fps,
                                                 "cameraName": CAMERA_NAME})
    except Exception:
        LOGGER.exception("Could not record the webcam.connected event")


class CameraManager:
    """Owns the one Softcam camera of this process. A single worker thread makes every DLL call:
    it creates the camera for the newest phone, converts and sends only the newest frame (frames
    that arrive while it is busy replace the waiting one), polls scIsConnected and deletes the
    camera GRACE_SECONDS after the last phone left. Callers never block on it.

    Invariant: a phone is only registered while a camera exists. When a camera cannot be
    (re)created, every phone is ended with cameraUnavailable instead of streaming into nothing,
    and the next camera starts a new session (a new webcam.connected)."""

    def __init__(self, library_loader=None, converter=None, emit=None, clock=time.monotonic):
        self._loader = library_loader
        self._convert = converter
        self._emit = emit
        self._clock = clock
        self._cond = threading.Condition()
        self._commands = deque()
        self._thread = None
        self._library = None
        self._camera = None
        self._format = None
        self._last_format = DEFAULT_FORMAT
        self._senders = {}
        self._active = None
        self._pending = None
        self._grace_deadline = None
        self._next_poll = 0.0
        self._connected = False
        self._session = False
        self._closed = False
        self._send_failure_logged = False
        self.stats = {"received": 0, "sent": 0, "dropped": 0, "bad": 0}

    # Called from the event loop (never blocks on the DLL) ------------------------------------

    def start_sender(self, sender_id, camera_format, on_ended=None):
        """Queues "make the camera ready for this phone". The future resolves with a dict or
        fails with CameraError. Older phones are ended: `on_ended(CameraError)` of theirs is
        called from the worker with "replaced", or with the error that stopped the camera."""
        future = concurrent.futures.Future()
        with self._cond:
            if self._closed:
                future.set_exception(CameraError("internal", "The webcam is shutting down.", CLOSE_INTERNAL))
                return future
            self._commands.append(("start", sender_id, tuple(camera_format), on_ended, future))
            self._ensure_thread()
            self._cond.notify_all()
        return future

    def end_all(self, error):
        """Queues "end every phone with `error` and delete the camera" (the webcam was removed)."""
        future = concurrent.futures.Future()
        with self._cond:
            if self._closed:
                future.set_result(None)
                return future
            self._commands.append(("end", error, future))
            self._ensure_thread()
            self._cond.notify_all()
        return future

    def submit_frame(self, sender_id, data):
        with self._cond:
            if sender_id != self._active:
                return False
            self.stats["received"] += 1
            if self._pending is not None:
                self.stats["dropped"] += 1
            self._pending = (sender_id, data)
            self._cond.notify_all()
            return True

    def stop_sender(self, sender_id):
        with self._cond:
            if self._senders.pop(sender_id, None) is None:
                return
            if self._active == sender_id:
                self._active = None
                self._pending = None
            if not self._senders:
                if self._camera is not None:
                    self._grace_deadline = self._clock() + GRACE_SECONDS
                else:
                    self._session = False
                    self._grace_deadline = None
            self._cond.notify_all()

    @property
    def connected(self):
        with self._cond:
            return bool(self._connected and self._camera is not None)

    def snapshot(self):
        with self._cond:
            width, height, fps = self._format or self._last_format
            return {"active": self._camera is not None, "clients": len(self._senders), "width": width,
                    "height": height, "fps": fps, "connected": bool(self._connected and self._camera is not None)}

    def close(self, timeout=2.0):
        """Deletes the camera and stops the worker (agent shutdown, tests)."""
        with self._cond:
            self._closed = True
            thread = self._thread
            self._cond.notify_all()
        if thread is not None:
            thread.join(timeout)

    # The worker ------------------------------------------------------------------------------

    def _ensure_thread(self):
        if self._thread is None or not self._thread.is_alive():
            self._thread = threading.Thread(target=self._run, name="orbit-webcam", daemon=True)
            self._thread.start()

    def _housekeeping_due(self, now):
        if self._camera is None:
            return False
        expired = not self._senders and self._grace_deadline is not None and now >= self._grace_deadline
        return expired or now >= self._next_poll

    def _wait_timeout(self, now):
        if self._camera is None:
            return None
        deadline = self._next_poll
        if not self._senders and self._grace_deadline is not None:
            deadline = min(deadline, self._grace_deadline)
        return min(1.0, max(0.01, deadline - now))

    def _run(self):
        while True:
            with self._cond:
                while (not self._closed and not self._commands and self._pending is None
                       and not self._housekeeping_due(self._clock())):
                    self._cond.wait(self._wait_timeout(self._clock()))
                if self._closed:
                    break
                command = self._commands.popleft() if self._commands else None
                frame = None
                if command is None and self._pending is not None:
                    frame, self._pending = self._pending, None
            try:
                if command is not None and command[0] == "start":
                    self._start(*command[1:])
                elif command is not None:
                    self._end_all(*command[1:])
                elif frame is not None:
                    self._send(frame)
                self._housekeeping()
            except Exception:
                LOGGER.exception("The webcam worker hit an error")
        self._delete_camera()
        with self._cond:
            waiting, self._commands = list(self._commands), deque()
        for command in waiting:
            future = command[-1]
            if not future.set_running_or_notify_cancel():
                continue
            if command[0] == "start":
                future.set_exception(CameraError("internal", "The webcam is shutting down.", CLOSE_INTERNAL))
            else:
                future.set_result(None)

    def _create_camera(self, camera_format):
        """scCreateCamera, retried for up to CREATE_RETRY_SECONDS: Softcam refuses a new camera while
        an app's DirectShow filter still maps the previous camera's shared memory, which it
        releases at its next frame poll (or only when the app closes it, while its graph is
        stopped). Runs on the worker; close() interrupts it. Returns the handle or None."""
        deadline = self._clock() + CREATE_RETRY_SECONDS
        while True:
            handle = self._library.create(*camera_format)
            if handle:
                return handle
            with self._cond:
                remaining = deadline - self._clock()
                if self._closed or remaining <= 0:
                    return None
                self._cond.wait(min(CREATE_RETRY_INTERVAL, remaining))

    def _drop_senders(self):
        """Forgets every phone (the camera is gone) and returns their on_ended callbacks."""
        with self._cond:
            callbacks = [info.get("on_ended") for info in self._senders.values()]
            self._senders = {}
            self._active = None
            self._pending = None
            if self._camera is None:
                self._session = False
                self._grace_deadline = None
        return [callback for callback in callbacks if callback is not None]

    @staticmethod
    def _tell(callbacks, error):
        for callback in callbacks:
            try:
                callback(error)
            except Exception:
                LOGGER.exception("Could not tell a phone that its webcam stream ended")

    def _start(self, sender_id, camera_format, on_ended, future):
        if not future.set_running_or_notify_cancel():
            return
        try:
            if self._library is None:
                self._library = (self._loader or load_sender_library)()
            created = False
            if self._camera is not None and self._format != camera_format:
                with self._cond:  # The current phone's frames wait while the camera is rebuilt.
                    self._active = None
                    self._pending = None
                self._delete_camera()
            if self._camera is None:
                handle = self._create_camera(camera_format)
                if not handle:
                    raise CameraError("cameraUnavailable", CAMERA_BUSY_MESSAGE, CLOSE_CAMERA_UNAVAILABLE)
                with self._cond:
                    self._camera, self._format = handle, camera_format
                    self._connected = False
                    self._next_poll = self._clock()
                self._send_failure_logged = False
                created = True
            with self._cond:
                replaced = [info.get("on_ended") for other, info in self._senders.items() if other != sender_id]
                self._senders = {sender_id: {"format": camera_format, "on_ended": on_ended}}
                self._active = sender_id
                self._pending = None
                self._grace_deadline = None
                self._last_format = camera_format
                announce = created and not self._session
                self._session = True
        except Exception as failure:
            if isinstance(failure, CameraError):
                error = failure
            else:
                LOGGER.exception("Could not start the virtual camera")
                error = CameraError("cameraUnavailable", "The PC could not start the virtual camera. Restart Orbit PC "
                                                         "Companion and try again.", CLOSE_CAMERA_UNAVAILABLE)
            if self._camera is None:  # No camera left: nobody may keep sending into nothing.
                self._tell(self._drop_senders(), error)
            future.set_exception(error)
            return
        self._tell([callback for callback in replaced if callback is not None],
                   CameraError("replaced", REPLACED_MESSAGE, CLOSE_REPLACED))
        width, height, fps = camera_format
        future.set_result({"created": created, "width": width, "height": height, "fps": fps})
        if announce:
            (self._emit or _emit_connected)(camera_format)

    def _end_all(self, error, future):
        if not future.set_running_or_notify_cancel():
            return
        try:
            self._delete_camera()
            self._tell(self._drop_senders(), error)
        finally:
            future.set_result(None)

    def _send(self, frame):
        sender_id, data = frame
        with self._cond:
            camera, camera_format, active = self._camera, self._format, self._active
        if camera is None or sender_id != active:
            return
        try:
            bgr = (self._convert or jpeg_to_bgr)(data, camera_format[0], camera_format[1])
        except FrameError:
            with self._cond:
                self.stats["bad"] += 1
            return
        try:
            self._library.send(camera, bgr)
        except Exception:
            if not self._send_failure_logged:  # once per camera, not 30 times a second
                self._send_failure_logged = True
                LOGGER.exception("scSendFrame failed")
            return
        with self._cond:
            self.stats["sent"] += 1

    def _housekeeping(self):
        now = self._clock()
        with self._cond:
            camera = self._camera
            expire = (camera is not None and not self._senders and not self._commands
                      and self._grace_deadline is not None and now >= self._grace_deadline)
            poll = camera is not None and not expire and now >= self._next_poll
        if expire:
            self._delete_camera()
            with self._cond:
                self._session = False
                self._grace_deadline = None
            LOGGER.info("The iPhone webcam stopped; the virtual camera was removed")
            return
        if poll:
            try:
                connected = bool(self._library.is_connected(camera))
            except Exception:
                LOGGER.debug("scIsConnected failed", exc_info=True)
                connected = False
            with self._cond:
                if self._camera == camera:
                    self._connected = connected
                self._next_poll = now + CONNECTION_POLL_SECONDS

    def _delete_camera(self):
        with self._cond:
            camera, self._camera = self._camera, None
            self._format = None
            self._connected = False
        if camera is not None and self._library is not None:
            try:
                self._library.delete(camera)
            except Exception:
                LOGGER.exception("Could not delete the virtual camera")


# Status --------------------------------------------------------------------------------------

def sender_readiness(boot_mode=False, registry=None):
    """None when a phone may start sending, else (code, sentence, close code)."""
    if boot_mode:
        return ("unsupported", NOT_SIGNED_IN, CLOSE_UNSUPPORTED_PC)
    try:
        layout = platform_layout()
    except UnsupportedPC as error:
        return ("unsupported", str(error), CLOSE_UNSUPPORTED_PC)
    if not HAS_PILLOW:
        return ("internal", "Orbit PC Companion is missing Pillow. Run install_orbit.bat again.", CLOSE_INTERNAL)
    folder = install_directory()
    if not files_installed(layout, folder):
        return ("notInstalled", REGISTRATION_MESSAGES["missing"], CLOSE_NOT_INSTALLED)
    registration = registration_state(layout, folder, registry)
    if not registration.ok:
        return ("notInstalled", REGISTRATION_MESSAGES[registration.problem], CLOSE_NOT_INSTALLED)
    return None


def status_payload(manager, installer, boot_mode=False, registry=None):
    """`GET /api/webcam` (see the module docstring)."""
    camera = manager.snapshot()
    payload = {"installed": False, "registered": False, "active": camera["active"], "clients": camera["clients"],
               "width": camera["width"], "height": camera["height"], "fps": camera["fps"], "reason": None,
               "connected": camera["connected"], "installing": installer.installing,
               "uninstalling": installer.uninstalling, "installStage": installer.stage,
               "installError": installer.last_error, "runtime": None,
               "cameraName": CAMERA_NAME, "softcamVersion": SOFTCAM_VERSION, "limits": dict(LIMITS)}
    try:
        layout = platform_layout()
    except UnsupportedPC as error:
        payload["reason"] = str(error)
        return payload
    folder = install_directory()
    payload["installed"] = files_installed(layout, folder)
    registration = registration_state(layout, folder, registry)
    payload["registered"] = registration.ok
    runtime = vc_runtime_status(layout, registry)
    payload["runtime"] = runtime
    if boot_mode:
        reason = NOT_SIGNED_IN
    elif payload["installing"] or payload["uninstalling"]:
        if payload["installStage"] == "waitingForApproval":
            reason = "Waiting for you to approve the Windows prompt on the PC."
        elif payload["installing"]:
            reason = "Setting up the iPhone webcam on the PC."
        else:
            reason = "Removing the iPhone webcam from the PC."
    elif payload["installed"] and registration.ok:
        reason = None if HAS_PILLOW else "Orbit PC Companion is missing Pillow. Run install_orbit.bat again."
    elif not runtime["ok"]:
        reason = runtime_message(runtime)
    elif registration.problem not in (None, "missing"):
        reason = REGISTRATION_MESSAGES[registration.problem]
    else:
        reason = REGISTRATION_MESSAGES["missing"]
    payload["reason"] = reason
    return payload


# The phone's video -----------------------------------------------------------------------------

def _reject_constant(name):
    raise ValueError(f"{name} is not allowed")


def _whole_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and (not math.isfinite(value) or not value.is_integer()):
        return None
    return int(value)


def parse_hello(text):
    """(width, height, fps) from the phone's first message; raises HelloError."""
    example = 'Start with a JSON hello such as {"width":1280,"height":720,"fps":30}.'
    if not isinstance(text, str) or len(text) > MAX_HELLO_CHARS:
        raise HelloError(example)
    try:
        payload = json.loads(text, parse_constant=_reject_constant)
    except ValueError as error:
        raise HelloError(example) from error
    if not isinstance(payload, dict):
        raise HelloError(example)
    width, height, fps = (_whole_number(payload.get(key)) for key in ("width", "height", "fps"))
    if width is None or height is None:
        raise HelloError("The hello needs width and height as whole numbers.")
    if width % 4 or height % 4:
        raise HelloError("Width and height must be multiples of 4.")
    if not (MIN_WIDTH <= width <= MAX_WIDTH and MIN_HEIGHT <= height <= MAX_HEIGHT):
        raise HelloError(f"The camera size must be from {MIN_WIDTH}×{MIN_HEIGHT} to {MAX_WIDTH}×{MAX_HEIGHT} (landscape).")
    if fps is None or not MIN_FPS <= fps <= MAX_FPS:
        raise HelloError(f"The frame rate must be a whole number from {MIN_FPS} to {MAX_FPS} fps.")
    return width, height, fps


async def handle_camera_socket(websocket, *, authorized, manager, boot_mode=lambda: False, require_windows=None,
                               readiness=None):
    """`WS /ws/camera` (see the module docstring)."""
    if any(name.lower() in _TOKEN_QUERY_NAMES for name in websocket.query_params.keys()):
        await websocket.close(code=CLOSE_POLICY)  # Tokens never travel in URLs (logs, proxies).
        return
    if not authorized(websocket.headers.get("authorization")):
        await websocket.close(code=CLOSE_POLICY)
        return
    if websocket.url.scheme != "wss":
        await websocket.close(code=CLOSE_POLICY)  # Video from a camera only over the pinned TLS port.
        return
    await websocket.accept()
    loop = asyncio.get_running_loop()
    send_lock = asyncio.Lock()
    state = {"closed": False}

    async def send_json(payload):
        async with send_lock:
            if state["closed"]:
                return False
            try:
                await websocket.send_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
                return True
            except Exception:
                state["closed"] = True
                return False

    async def fail(code, message, close_code):
        await send_json({"error": message, "code": code})
        async with send_lock:
            if state["closed"]:
                return
            state["closed"] = True
            try:
                await websocket.close(code=close_code, reason=code)
            except Exception:
                pass

    try:
        if require_windows is not None:
            require_windows()
    except HTTPException as error:
        await fail("unsupported", str(error.detail), CLOSE_UNSUPPORTED_PC)
        return
    problem = await asyncio.to_thread(readiness or sender_readiness, bool(boot_mode()))
    if problem is not None:
        await fail(*problem)
        return

    try:
        message = await asyncio.wait_for(websocket.receive(), HELLO_TIMEOUT)
    except asyncio.TimeoutError:
        await fail("badHello", 'Send the camera format first, for example {"width":1280,"height":720,"fps":30}.',
                   CLOSE_POLICY)
        return
    if message.get("type") == "websocket.disconnect":
        return
    if message.get("bytes") is not None:
        await fail("badHello", "Send the camera format as a text message before any video frames.", CLOSE_POLICY)
        return
    text = message.get("text")
    if isinstance(text, str) and len(text) > MAX_HELLO_CHARS:
        await fail("badHello", "The hello message is too long.", CLOSE_TOO_BIG)
        return
    try:
        camera_format = parse_hello(text)
    except HelloError as error:
        await fail("badHello", str(error), CLOSE_POLICY)
        return

    ended = asyncio.Event()
    ending = {}

    def on_ended(error):
        """From the camera worker: a newer phone took over, or the camera stopped (CameraError)."""
        def mark():
            ending.setdefault("error", error)
            ended.set()
        try:
            loop.call_soon_threadsafe(mark)
        except RuntimeError:
            pass  # The connection's loop is gone already.

    sender_id = uuid.uuid4().hex
    future = manager.start_sender(sender_id, camera_format, on_ended)
    try:
        await asyncio.wrap_future(future)
    except CameraError as error:
        await fail(error.code, error.message, error.close_code)
        return
    except BaseException:
        future.add_done_callback(lambda _done: manager.stop_sender(sender_id))
        raise

    async def status_loop():
        last_value, last_sent = None, 0.0
        while not state["closed"]:
            connected = manager.connected
            now = loop.time()
            if connected != last_value or now - last_sent >= HEARTBEAT_SECONDS:
                if not await send_json({"connected": connected}):
                    return
                last_value, last_sent = connected, now
            try:
                await asyncio.wait_for(ended.wait(), STATUS_INTERVAL)
            except asyncio.TimeoutError:
                continue
            error = ending.get("error") or CameraError("replaced", REPLACED_MESSAGE, CLOSE_REPLACED)
            await fail(error.code, error.message, error.close_code)
            return

    async def receive_loop():
        while not state["closed"]:
            try:
                message = await websocket.receive()
            except (RuntimeError, WebSocketDisconnect):
                return
            if message.get("type") == "websocket.disconnect":
                return
            data = message.get("bytes")
            if data is not None:
                if len(data) > MAX_FRAME_BYTES:
                    await fail("frameTooLarge", f"Video frames must be at most {MAX_FRAME_BYTES // (1024 * 1024)} MB.",
                               CLOSE_TOO_BIG)
                    return
                if not is_jpeg(data):
                    await fail("badFrame", "Video frames must be JPEG images.", CLOSE_UNSUPPORTED_DATA)
                    return
                manager.submit_frame(sender_id, data)
                continue
            text = message.get("text")
            if isinstance(text, str) and len(text) > MAX_HELLO_CHARS:
                await fail("badHello", "Text messages must be short JSON.", CLOSE_TOO_BIG)
                return
            # Other short text messages (pings) are ignored.

    try:
        width, height, fps = camera_format
        if not await send_json({"ready": True, "width": width, "height": height, "fps": fps,
                                "cameraName": CAMERA_NAME}):
            return
        status_task = asyncio.create_task(status_loop())
        try:
            await receive_loop()
        finally:
            status_task.cancel()
            try:
                await status_task
            except BaseException:
                pass
    finally:
        manager.stop_sender(sender_id)


CAMERA = CameraManager()
INSTALLER = Installer()


def create_webcam_router(verify_control, require_https, require_windows, authorized, boot_mode=lambda: False,
                         manager=None, installer=None):
    """`GET /api/webcam`, `POST /api/webcam/install`, `POST /api/webcam/uninstall` and `WS /ws/camera`."""
    camera = manager or CAMERA
    setup = installer or INSTALLER
    router = APIRouter()
    guards = [Depends(verify_control), Depends(require_https)]

    def run(operation):
        """Starts (or joins) the setup or removal and waits up to INSTALL_WAIT_SECONDS for it."""
        try:
            future = setup.start(operation)
            result = future.result(timeout=INSTALL_WAIT_SECONDS)
        except concurrent.futures.TimeoutError:
            return JSONResponse(status_code=202, headers={"Cache-Control": "no-store"},
                                content={"status": "waitingForApproval", **status_payload(camera, setup, False)})
        except InstallError as error:
            raise HTTPException(status_code=error.status, detail=error.message) from error
        body = {"status": result}
        if operation == "uninstall":
            body["filesLeft"] = webcam_files_left()
        return {**body, **status_payload(camera, setup, False)}

    @router.get("/api/webcam", dependencies=guards)
    def webcam_status(response: Response):
        require_windows()
        response.headers["Cache-Control"] = "no-store"
        return status_payload(camera, setup, bool(boot_mode()))

    @router.post("/api/webcam/install", dependencies=guards)
    def webcam_install(response: Response):
        require_windows()
        response.headers["Cache-Control"] = "no-store"
        if boot_mode():
            raise HTTPException(status_code=409, detail="Sign in to Windows on the PC first. The webcam is set up "
                                                        "from the signed-in desktop.")
        return run("install")

    @router.post("/api/webcam/uninstall", dependencies=guards)
    def webcam_uninstall(response: Response):
        require_windows()
        response.headers["Cache-Control"] = "no-store"
        if boot_mode():
            raise HTTPException(status_code=409, detail="Sign in to Windows on the PC first. The webcam is removed "
                                                        "from the signed-in desktop.")
        return run("uninstall")

    @router.websocket("/ws/camera")
    async def camera_socket(websocket: WebSocket):
        await handle_camera_socket(websocket, authorized=authorized, manager=camera, boot_mode=boot_mode,
                                   require_windows=require_windows)

    return router
