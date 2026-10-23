"""Full-screen streaming and the virtual second screen: the PC side (features streamDisplay, secondScreen).

Sunshine streams the display it captures and scales it into the size the client asked for, with
black bars when the shapes differ. To fill an iPhone, iPad or Mac screen, the PC needs a display
that can switch to exactly that size. The Virtual Display Driver (VDD,
VirtualDrivers/Virtual-Display-Driver, MIT, installed by the user with winget) adds an invisible
monitor whose sizes are listed in its `vdd_settings.xml`. This module:

* adds sizes to that list (`POST /api/stream/display/modes`) and restarts the driver while
  nobody streams, so Windows offers the new size;
* points Sunshine at the virtual display through Sunshine's own web API, with the login the user
  saved in Orbit (`POST /api/stream/display/fill`);
* makes the virtual display an extended second screen, left or right of the main one
  (`POST /api/stream/display/second-screen`).

Sunshine rewrites its whole `sunshine.conf` from the map posted to `/api/config`, so every change
reads the full map, changes only Orbit's keys and posts everything back. The map from before
Orbit's first change stays in settings.json (`display.savedSunshineConfig`) and Orbit's keys are
put back from it when the user turns the features off; the map from right before the latest change
is kept too (`display.lastSunshineConfig`). Sunshine reads its settings only when it starts, so it
is restarted, but never while a stream is running.

Native calls use private ctypes handles with full prototypes. Nothing here runs with
administrator rights except one helper started through a single UAC prompt (`ShellExecuteExW`
with the `runas` verb), and only when Windows needs it: to save `vdd_settings.xml` when the user
cannot write it, and to restart the driver.
"""
import base64
import copy
import ctypes
from ctypes import wintypes
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import http.client
import json
import logging
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import threading
import time
from typing import Literal
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

import psutil
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator

import orbit_settings

LOGGER = logging.getLogger("orbit.streamdisplay")

SETTINGS_SECTION = "display"
VDD_INSTALL_COMMAND = "winget install -e --id VirtualDrivers.Virtual-Display-Driver"
VDD_DEFAULT_DIRECTORY = "C:\\VirtualDisplayDriver"
VDD_SETTINGS_NAME = "vdd_settings.xml"
VDD_BACKUP_NAME = "vdd_settings.orbit-backup.xml"
VDD_REGISTRY_KEY = "SOFTWARE\\MikeTheTech\\VirtualDisplayDriver"
VDD_HARDWARE_ID = "root\\mttvdd"
VDD_PIPE_NAME = "\\\\.\\pipe\\MTTVirtualDisplayPipe"
# The driver's EDID always reports manufacturer MTT, product 0x1337 (Driver.cpp modifyEdid).
VDD_MONITOR_ID = "MTT1337"
VDD_FRIENDLY_NAME = "VDD by MTT"
SUDOVDA_REGISTRY_KEY = "SOFTWARE\\SudoMaker\\SudoVDA"
DEVICE_ENUM_ROOT = "SYSTEM\\CurrentControlSet\\Enum\\ROOT"

BASE_RESOLUTIONS = ((1920, 1080), (2560, 1440), (3840, 2160))
BASE_REFRESH_RATES = (60, 120)
MAX_RESOLUTIONS = 48
MAX_REFRESH_RATES = 16

# Sunshine's keys that Orbit changes; everything else in sunshine.conf is left as it is.
MANAGED_KEYS = ("output_name", "dd_configuration_option", "dd_resolution_option", "dd_refresh_rate_option")
# `GET /api/config` adds these to the file's own keys (confighttp.cpp getConfig); they never go back.
CONFIG_META_KEYS = ("status", "platform", "version")
REPORTED_KEYS = ("dd_configuration_option", "dd_resolution_option", "dd_refresh_rate_option", "output_name")
MAX_SUNSHINE_REPLY_BYTES = 16 * 1024 * 1024

LOGIN_MISSING = "Save your Sunshine web UI login in Orbit first, so Orbit can change Sunshine's settings."
LOGIN_REJECTED = "Sunshine rejected the saved web UI login. Save it again in Orbit."
SUNSHINE_UNREACHABLE = "Could not reach Sunshine's web UI on this PC. Make sure Sunshine is running, then try again."
STREAM_RUNNING = ("Someone is streaming from this PC right now. Sunshine has to restart to use new display settings, "
                  "so Orbit changes them only between streams. End the stream and try again.")
STREAM_UNKNOWN = ("Orbit could not check whether a stream is running, so it did not restart Sunshine. "
                  "Try again in a moment.")
APP_RUNNING = ("An app is still running in Sunshine. Sunshine has to restart to use new display settings, which would "
               "close it. Quit the app from Moonlight first, then try again.")
SUNSHINE_TOO_OLD = ("This needs Sunshine 2025.118 or newer, which can switch displays for each stream. "
                    "Update Sunshine on the PC and try again.")
VDD_MISSING = ("Install the free Virtual Display Driver on the PC first (" + VDD_INSTALL_COMMAND
               + " in Terminal), then try again.")
SUDOVDA_ONLY = ("SudoVDA (from Apollo) is installed, but Orbit sets this up with the Virtual Display Driver. "
                "Install it with: " + VDD_INSTALL_COMMAND)
VDD_NOT_IN_SUNSHINE = ("Sunshine does not list the virtual display yet. Restart the PC so the Virtual Display Driver "
                       "and Sunshine start together, then try again.")
VDD_DISABLED = "The Virtual Display Driver is turned off in Device Manager. Turn it on and try again."
SIGN_IN_FIRST = ("Sign in to Windows on the PC first. Adding a screen size to the virtual display can need your "
                 "approval on the PC's screen.")
UAC_DECLINED = "The administrator prompt on the PC was declined, so Orbit left the virtual display unchanged."
PROMPT_TIMEOUT = ("Nobody approved the administrator prompt on the PC in time, so Orbit left the virtual display "
                  "unchanged. Try again when you can answer it on the PC.")
PROMPT_STILL_OPEN = ("An earlier administrator prompt from Orbit is still open on the PC. Close it there (it no longer "
                     "changes anything), then try again.")
HELPER_SAW_STREAM = ("A stream started, or an app was running in Sunshine, before the administrator prompt was "
                     "approved, so Orbit left the virtual display unchanged. End it and try again.")
KEPT_NEW_SIZE = ("Orbit kept the new screen size in the Virtual Display Driver settings; Windows offers it after the "
                 "driver restarts, for example after you restart the PC.")
DRIVER_STUCK = ("The Virtual Display Driver stopped responding after the reload, so restart the PC before streaming "
                "to it.")
SETTINGS_NOT_SAVED = ("Orbit could not save its own settings on this PC (settings.json), so it changed nothing. "
                      "Check that the disk has free space, then try again.")
STAGING_FAILED = ("Orbit could not prepare the new Virtual Display Driver settings in its data folder. Check that the "
                  "disk has free space, then try again.")
NO_DEVICE_LIST = ("Sunshine's log does not list the PC's displays. Restart Sunshine and try again; if this stays, set "
                  "Sunshine's Log Level to Info (Configuration > Advanced).")
DEVICE_ID_INVALID = ("Sunshine's log lists the virtual display with an id Orbit does not recognise, so Orbit did not "
                     "use it. Restart Sunshine and try again.")
BUSY = "Orbit is already changing the display settings on this PC. Wait a moment and try again."
PLACEMENT_HINT = ("To move it yourself: open Windows Settings > System > Display, drag the screen named "
                  "'VDD by MTT' to the {side} of your main display and select Apply.")
NO_VDD_WARNING = ("Without the Virtual Display Driver, Sunshine can only switch your own monitor to sizes it supports, "
                  "so some devices may still show black bars.")


class DisplaySetupError(Exception):
    """A request that cannot be done; `detail` is a plain sentence for the app to show. `kind`
    tells callers inside this module why (for example "declined"), when that matters."""

    def __init__(self, status, detail, kind=None):
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.kind = kind


class NeedsElevation(Exception):
    """Windows refused a change that an administrator can make."""


class ElevationDeclined(Exception):
    """The user answered No to the UAC prompt (or no administrator approved it)."""


class ElevationTimedOut(Exception):
    """Nobody answered the UAC prompt in time. If it is approved later, the helper does nothing."""


class ElevationBusy(Exception):
    """An earlier UAC prompt from Orbit is still waiting for an answer."""


class ElevationFailed(Exception):
    """The administrator helper could not start or did not finish its work."""


class PipeUnavailable(OSError):
    """The driver's control pipe is not there (driver not running, or an old version)."""


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# -- native access ----------------------------------------------------------------------------

_LIBRARIES = {}
_LIBRARIES_LOCK = threading.Lock()


def _library(name):
    """A private `WinDLL(name, use_last_error=True)`: prototypes set here never change the shared
    `ctypes.windll` functions that other modules call with their own argument types."""
    with _LIBRARIES_LOCK:
        library = _LIBRARIES.get(name)
        if library is None:
            loader = getattr(ctypes, "WinDLL", None)
            if loader is None:
                raise OSError("This needs Windows.")
            library = _LIBRARIES[name] = loader(name, use_last_error=True)
        return library


def _prototype(function, argtypes, restype):
    function.argtypes = argtypes
    function.restype = restype
    return function


def _last_error():
    try:
        return int(ctypes.get_last_error())
    except Exception:
        return 0


def _registry():
    try:
        import winreg
    except ImportError:
        return None
    return winreg


GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
PIPE_READMODE_MESSAGE = 0x00000002
ERROR_FILE_NOT_FOUND = 2
ERROR_BROKEN_PIPE = 109
ERROR_PIPE_BUSY = 231
ERROR_PIPE_NOT_CONNECTED = 233
ERROR_CANCELLED = 1223
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
MAX_PATH = 260

SEE_MASK_NOCLOSEPROCESS = 0x00000040
SEE_MASK_NOASYNC = 0x00000100
SW_HIDE = 0
WAIT_OBJECT_0 = 0x00000000
WAIT_TIMEOUT = 0x00000102

DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001
DISPLAY_DEVICE_PRIMARY_DEVICE = 0x00000004
DISPLAY_DEVICE_MIRRORING_DRIVER = 0x00000008
EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001
ENUM_CURRENT_SETTINGS = 0xFFFFFFFF
DM_POSITION = 0x00000020
CDS_UPDATEREGISTRY = 0x00000001
CDS_NORESET = 0x10000000
DISP_CHANGE_SUCCESSFUL = 0

CR_SUCCESS = 0
CR_NO_SUCH_DEVNODE = 0x0000000D
DN_STARTED = 0x00000008
DN_HAS_PROBLEM = 0x00000400
CM_PROB_DISABLED = 22
CM_LOCATE_DEVNODE_NORMAL = 0


class SHELLEXECUTEINFOW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("fMask", wintypes.ULONG),
        ("hwnd", wintypes.HWND),
        ("lpVerb", wintypes.LPCWSTR),
        ("lpFile", wintypes.LPCWSTR),
        ("lpParameters", wintypes.LPCWSTR),
        ("lpDirectory", wintypes.LPCWSTR),
        ("nShow", ctypes.c_int),
        ("hInstApp", wintypes.HINSTANCE),
        ("lpIDList", ctypes.c_void_p),
        ("lpClass", wintypes.LPCWSTR),
        ("hkeyClass", wintypes.HKEY),
        ("dwHotKey", wintypes.DWORD),
        ("hIconOrMonitor", wintypes.HANDLE),
        ("hProcess", wintypes.HANDLE),
    ]


class DISPLAY_DEVICEW(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("DeviceName", wintypes.WCHAR * 32),
        ("DeviceString", wintypes.WCHAR * 128),
        ("StateFlags", wintypes.DWORD),
        ("DeviceID", wintypes.WCHAR * 128),
        ("DeviceKey", wintypes.WCHAR * 128),
    ]


class DEVMODEW(ctypes.Structure):
    """DEVMODEW with the display branch of its unions (dmPosition, dmDisplayFlags): 220 bytes."""
    _fields_ = [
        ("dmDeviceName", wintypes.WCHAR * 32),
        ("dmSpecVersion", wintypes.WORD),
        ("dmDriverVersion", wintypes.WORD),
        ("dmSize", wintypes.WORD),
        ("dmDriverExtra", wintypes.WORD),
        ("dmFields", wintypes.DWORD),
        ("dmPositionX", wintypes.LONG),
        ("dmPositionY", wintypes.LONG),
        ("dmDisplayOrientation", wintypes.DWORD),
        ("dmDisplayFixedOutput", wintypes.DWORD),
        ("dmColor", ctypes.c_short),
        ("dmDuplex", ctypes.c_short),
        ("dmYResolution", ctypes.c_short),
        ("dmTTOption", ctypes.c_short),
        ("dmCollate", ctypes.c_short),
        ("dmFormName", wintypes.WCHAR * 32),
        ("dmLogPixels", wintypes.WORD),
        ("dmBitsPerPel", wintypes.DWORD),
        ("dmPelsWidth", wintypes.DWORD),
        ("dmPelsHeight", wintypes.DWORD),
        ("dmDisplayFlags", wintypes.DWORD),
        ("dmDisplayFrequency", wintypes.DWORD),
        ("dmICMMethod", wintypes.DWORD),
        ("dmICMIntent", wintypes.DWORD),
        ("dmMediaType", wintypes.DWORD),
        ("dmDitherType", wintypes.DWORD),
        ("dmReserved1", wintypes.DWORD),
        ("dmReserved2", wintypes.DWORD),
        ("dmPanningWidth", wintypes.DWORD),
        ("dmPanningHeight", wintypes.DWORD),
    ]


# -- the driver's control pipe ------------------------------------------------------------------

def encode_pipe_command(command):
    """A VDD pipe request: UTF-16LE text without BOM or terminator, at most 127 characters
    (the driver reads one message into a 128-character buffer and adds the terminator itself)."""
    if not isinstance(command, str) or not command or len(command) > 127:
        raise ValueError("A driver command is 1 to 127 characters long.")
    if any(not 32 <= ord(character) < 127 for character in command):
        raise ValueError("Driver commands are plain ASCII text.")
    return command.encode("utf-16-le")


def send_pipe_command(command, timeout=2.0, library=None):
    """Sends one command to `\\\\.\\pipe\\MTTVirtualDisplayPipe` (message mode) and waits up to
    `timeout` seconds for the driver to answer or close the pipe. Returns
    `{"handled": bool, "reply": str}`; raises PipeUnavailable or OSError."""
    payload = encode_pipe_command(command)
    kernel32 = library or _library("kernel32")
    create = _prototype(kernel32.CreateFileW, [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                               wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE], wintypes.HANDLE)
    wait_pipe = _prototype(kernel32.WaitNamedPipeW, [wintypes.LPCWSTR, wintypes.DWORD], wintypes.BOOL)
    set_state = _prototype(kernel32.SetNamedPipeHandleState,
                           [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                            ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL)
    write = _prototype(kernel32.WriteFile, [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p], wintypes.BOOL)
    peek = _prototype(kernel32.PeekNamedPipe, [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                               ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                                               ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL)
    read = _prototype(kernel32.ReadFile, [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                          ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p], wintypes.BOOL)
    close = _prototype(kernel32.CloseHandle, [wintypes.HANDLE], wintypes.BOOL)

    handle = None
    for attempt in range(2):
        handle = create(VDD_PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
        if handle not in (None, 0, INVALID_HANDLE_VALUE):
            break
        error = _last_error()
        handle = None
        if error == ERROR_PIPE_BUSY and attempt == 0 and wait_pipe(VDD_PIPE_NAME, int(timeout * 1000)):
            continue
        if error in (ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY):
            raise PipeUnavailable("The Virtual Display Driver's control pipe is not available.")
        raise OSError(f"Could not open the Virtual Display Driver's control pipe (Windows error {error}).")
    try:
        mode = wintypes.DWORD(PIPE_READMODE_MESSAGE)
        set_state(handle, ctypes.byref(mode), None, None)  # best effort; requests are messages either way
        buffer = ctypes.create_string_buffer(payload, len(payload))
        written = wintypes.DWORD(0)
        if not write(handle, buffer, len(payload), ctypes.byref(written), None) or written.value != len(payload):
            raise OSError(f"The Virtual Display Driver did not take the command (Windows error {_last_error()}).")
        reply = b""
        handled = False
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            available = wintypes.DWORD(0)
            if not peek(handle, None, 0, None, ctypes.byref(available), None):
                handled = True  # the driver handled the request and closed its end
                break
            if available.value:
                chunk = ctypes.create_string_buffer(min(available.value, 4096))
                count = wintypes.DWORD(0)
                if read(handle, chunk, len(chunk), ctypes.byref(count), None) or count.value:
                    reply += chunk.raw[:count.value]
                    handled = True
            time.sleep(0.05)
        return {"handled": handled, "reply": reply.replace(b"\x00", b"").decode("utf-8", "replace").strip()}
    finally:
        close(handle)


# -- the administrator helper (one UAC prompt) --------------------------------------------------

# How long Orbit waits for someone to answer the UAC prompt. The helper itself refuses to run when
# it starts later than that, so a prompt approved after the phone stopped waiting changes nothing.
PROMPT_WAIT_SECONDS = 60.0
HELPER_RUN_SECONDS = 120.0
NET_EPOCH_TICKS = 621355968000000000  # 0001-01-01 to 1970-01-01 in .NET's 100 ns ticks


def system_directory(kernel32=None):
    """Windows' System32 folder from GetSystemDirectoryW. Never from %SystemRoot%/%windir%, which a
    user's own environment can point elsewhere: the administrator must approve the real PowerShell."""
    kernel32 = kernel32 or _library("kernel32")
    get = _prototype(kernel32.GetSystemDirectoryW, [wintypes.LPWSTR, wintypes.UINT], wintypes.UINT)
    buffer = ctypes.create_unicode_buffer(MAX_PATH + 1)
    length = int(get(buffer, len(buffer)) or 0)
    folder = buffer.value
    if not length or length >= len(buffer) or length != len(folder) or not re.match(r"^[A-Za-z]:\\", folder):
        raise ElevationFailed("Orbit could not find Windows' system folder to start PowerShell.")
    return folder


def powershell_path(kernel32=None):
    return system_directory(kernel32).rstrip("\\/") + "\\WindowsPowerShell\\v1.0\\powershell.exe"


_PS_SINGLE_QUOTES = re.compile("['‘’‚‛]")


def _ps_quote(value):
    """A PowerShell single-quoted string. PowerShell ends such a string at any of ' ‘ ’ ‚ ‛, so each
    of them is doubled (like its own EscapeSingleQuotedStringContent)."""
    return "'" + _PS_SINGLE_QUOTES.sub(lambda match: match.group(0) * 2, str(value)) + "'"


def _ps_text(value):
    """A PowerShell expression for the text `value` that carries none of its characters: UTF-8,
    base64-encoded. Paths and ids reach the administrator's PowerShell only this way."""
    encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
    return f"([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{encoded}')))"


def dotnet_ticks(unix_seconds):
    """`unix_seconds` as [DateTime]::UtcNow.Ticks counts (both read the same system clock)."""
    return int(round(float(unix_seconds) * 10_000_000)) + NET_EPOCH_TICKS


# Run inside the helper right before it touches anything: is a stream or a Sunshine app running?
# 0: nobody streams, 1: a stream or an app is running, 2: cannot tell. Sunshine's process is found by
# name, by the pids Orbit saw, and as the owner of its TCP listeners (like sunshine_activity).
_HELPER_BUSY_CHECK = [
    "function Test-OrbitBusy {",
    "  try {",
    "    $ids = @($knownSunshine | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })",
    "    $ids += @(Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })",
    "    $tcp = @(Get-NetTCPConnection -ErrorAction Stop)",
    "    $listen = @(($basePort - 5), $basePort, ($basePort + 1), ($basePort + 21))",
    "    $ids += @($tcp | Where-Object { $_.State -eq 'Listen' -and $listen -contains $_.LocalPort } |"
    " ForEach-Object { [int]$_.OwningProcess })",
    "    if (@($tcp | Where-Object { $_.State -eq 'Established' -and $_.LocalPort -eq ($basePort + 21) -and"
    " $ids -contains $_.OwningProcess }).Count -gt 0) { return 1 }",
    "    $udp = @(($basePort + 9), ($basePort + 10), ($basePort + 11))",
    "    if (@(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $udp -contains $_.LocalPort -and"
    " $ids -contains $_.OwningProcess }).Count -gt 0) { return 1 }",
    "  } catch { return 2 }",
    "  try {",
    "    $request = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $basePort + '/serverinfo')",
    "    $request.Proxy = $null",
    "    $request.Timeout = 5000",
    "    $request.ReadWriteTimeout = 5000",
    "    $response = $request.GetResponse()",
    "    try {",
    "      $stream = $response.GetResponseStream()",
    "      $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $stream",
    "      $text = $reader.ReadToEnd()",
    "    } finally { $response.Close() }",
    "  } catch {",
    "    if ($ids.Count -gt 0) { return 2 }",
    "    return 0",
    "  }",
    "  if ($ids.Count -eq 0 -or $text -match '<!DOCTYPE|<!ENTITY') { return 2 }",
    "  try { $info = [xml]$text } catch { return 2 }",
    "  $game = ([string]$info.root.currentgame).Trim()",
    "  $state = ([string]$info.root.state).Trim()",
    "  if ($state -like '*_SERVER_BUSY' -or ($game -ne '' -and $game -ne '0')) { return 1 }",
    "  if ($game -eq '0' -or $state -like '*_SERVER_FREE') { return 0 }",
    "  return 2",
    "}",
]


def build_helper_script(source=None, target=None, sha256=None, instance_ids=(), not_after=None, base_port=47989,
                        sunshine_pids=()):
    """The PowerShell the elevated helper runs. It first refuses to run after `not_after` (Unix
    time; by default PROMPT_WAIT_SECONDS from now). Before restarting the driver it checks that no
    stream and no Sunshine app is running. With `source`, it checks the staged file's SHA-256, keeps
    one backup of the old settings, and replaces `target` through a temporary file. It then restarts
    each driver instance (disable, then always enable again). When the restart fails it puts the old
    file back. Every path and id is passed base64-encoded, never as PowerShell text.

    Exit codes: 0 done, 3 staged file changed, 4 could not save, 5 could not restart the driver (old
    settings restored), 6 started too late (nothing done), 7 a stream or an app is running in
    Sunshine (nothing done), 8 could not check for a stream (nothing done)."""
    deadline = dotnet_ticks(time.time() + PROMPT_WAIT_SECONDS if not_after is None else not_after)
    lines = [
        "# Orbit PC Companion: Virtual Display Driver helper, run once as administrator",
        "$ErrorActionPreference = 'Stop'",
        f"if ([DateTime]::UtcNow.Ticks -gt {deadline}) {{ exit 6 }}",
        f"$source = {_ps_text(source or '')}",
        f"$target = {_ps_text(target or '')}",
        f"$expected = {_ps_text((sha256 or '').upper())}",
        f"$backupName = {_ps_text(VDD_BACKUP_NAME)}",
        "$devices = @(" + ", ".join(_ps_text(item) for item in instance_ids) + ")",
        f"$basePort = {int(base_port)}",
        "$knownSunshine = @(" + ", ".join(str(int(pid)) for pid in sorted(sunshine_pids)) + ")",
        *_HELPER_BUSY_CHECK,
        "if ($devices.Count -gt 0) {",
        "  $busy = @(Test-OrbitBusy)[-1]",
        "  if ($busy -eq 1) { exit 7 }",
        "  if ($busy -ne 0) { exit 8 }",
        "}",
        "$original = $null",
        "$wrote = $false",
        "if ($source -ne '') {",
        "  try {",
        "    $bytes = [System.IO.File]::ReadAllBytes($source)",
        "    $sha = [System.Security.Cryptography.SHA256]::Create()",
        "    $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')",
        "    if ($hash -ne $expected) { exit 3 }",
        "    $folder = [System.IO.Path]::GetDirectoryName($target)",
        "    [System.IO.Directory]::CreateDirectory($folder) | Out-Null",
        "    if ([System.IO.File]::Exists($target)) {",
        "      $original = [System.IO.File]::ReadAllBytes($target)",
        "      $backup = [System.IO.Path]::Combine($folder, $backupName)",
        "      if (-not [System.IO.File]::Exists($backup)) { [System.IO.File]::WriteAllBytes($backup, $original) }",
        "      [System.IO.File]::SetAttributes($target, [System.IO.FileAttributes]::Normal)",
        "    }",
        "    $temporary = $target + '.orbit-tmp'",
        "    [System.IO.File]::WriteAllBytes($temporary, $bytes)",
        "    [System.IO.File]::Copy($temporary, $target, $true)",
        "    [System.IO.File]::Delete($temporary)",
        "    $wrote = $true",
        "  } catch { exit 4 }",
        "}",
        "$failed = $false",
        "foreach ($id in $devices) {",
        "  try {",
        "    try { Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop }",
        "    finally { Start-Sleep -Milliseconds 1500; Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop }",
        "  } catch {",
        "    $failed = $true",
        "    try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction SilentlyContinue } catch { }",
        "  }",
        "}",
        "if ($failed) {",
        "  if ($wrote -and ($null -ne $original)) { try { [System.IO.File]::WriteAllBytes($target, $original) } catch { } }",
        "  exit 5",
        "}",
        "if ($devices.Count -gt 0) { Start-Sleep -Seconds 2 }",
        "exit 0",
    ]
    script = "\r\n".join(lines) + "\r\n"
    if not script.isascii():
        raise ValueError("The administrator helper must be plain ASCII.")
    return script


def powershell_parameters(script):
    """Inline script through -EncodedCommand (UTF-16LE, base64): nothing on disk is run elevated."""
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return f"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand {encoded}"


COINIT_APARTMENTTHREADED = 0x2
COINIT_DISABLE_OLE1DDE = 0x4


def _com_initialize(ole32):
    """CoInitializeEx for this thread, as Microsoft asks before ShellExecuteEx. Returns the ole32
    handle when this call initialized COM (the caller then uninitializes it), else None."""
    try:
        ole32 = ole32 or _library("ole32")
        _prototype(ole32.CoInitializeEx, [ctypes.c_void_p, wintypes.DWORD], ctypes.c_long)
        _prototype(ole32.CoUninitialize, [], None)
        return ole32 if ole32.CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) in (0, 1) else None
    except (OSError, AttributeError):
        return None


_PROMPT_LOCK = threading.Lock()
_PROMPT_THREAD = None  # the thread blocked in ShellExecuteExW until someone answers the prompt, else None


def run_elevated_powershell(script, timeout=HELPER_RUN_SECONDS, prompt_timeout=PROMPT_WAIT_SECONDS, shell32=None,
                            kernel32=None, ole32=None):
    """Runs `script` in an elevated PowerShell after one UAC prompt and returns its exit code.

    ShellExecuteExW blocks until somebody answers the prompt, so it runs on its own thread and
    Orbit stops waiting after `prompt_timeout` seconds (ElevationTimedOut). That thread then just
    closes the helper's handle if the prompt is approved later; the helper refuses to run late on
    its own (exit 6). While a prompt is still open, another one is refused (ElevationBusy).
    Raises ElevationDeclined when the prompt is declined and ElevationFailed otherwise."""
    global _PROMPT_THREAD
    shell32 = shell32 or _library("shell32")
    kernel32 = kernel32 or _library("kernel32")
    execute = _prototype(shell32.ShellExecuteExW, [ctypes.POINTER(SHELLEXECUTEINFOW)], wintypes.BOOL)
    wait = _prototype(kernel32.WaitForSingleObject, [wintypes.HANDLE, wintypes.DWORD], wintypes.DWORD)
    exit_code = _prototype(kernel32.GetExitCodeProcess, [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)],
                           wintypes.BOOL)
    close = _prototype(kernel32.CloseHandle, [wintypes.HANDLE], wintypes.BOOL)
    info = SHELLEXECUTEINFOW()
    info.cbSize = ctypes.sizeof(SHELLEXECUTEINFOW)
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC
    info.hwnd = None
    info.lpVerb = "runas"
    info.lpFile = powershell_path(kernel32)
    info.lpParameters = powershell_parameters(script)
    info.lpDirectory = None
    info.nShow = SW_HIDE
    outcome = {"done": False, "abandoned": False, "started": False, "error": 0}
    outcome_lock = threading.Lock()
    answered = threading.Event()

    def ask():
        global _PROMPT_THREAD
        started, error = False, 0
        try:
            com = _com_initialize(ole32)
            try:
                started = bool(execute(ctypes.byref(info)))
                error = 0 if started else _last_error()  # last-error values are per thread: read it here
            finally:
                if com is not None:
                    com.CoUninitialize()
        except Exception:
            LOGGER.exception("ShellExecuteExW failed")
            started, error = False, -1
        finally:
            with _PROMPT_LOCK:  # answered (or failed): the next request may ask again right away
                if _PROMPT_THREAD is threading.current_thread():
                    _PROMPT_THREAD = None
        with outcome_lock:
            outcome.update(done=True, started=started, error=error)
            abandoned = outcome["abandoned"]
        if abandoned and started and info.hProcess:
            close(info.hProcess)  # approved too late: the helper exits by itself without doing anything
        answered.set()

    with _PROMPT_LOCK:
        if _PROMPT_THREAD is not None:
            raise ElevationBusy(PROMPT_STILL_OPEN)
        worker = threading.Thread(target=ask, name="orbit-uac-prompt", daemon=True)
        _PROMPT_THREAD = worker
        worker.start()
    if not answered.wait(prompt_timeout):
        with outcome_lock:
            if not outcome["done"]:
                outcome["abandoned"] = True
                raise ElevationTimedOut(PROMPT_TIMEOUT)
    started, error = outcome["started"], outcome["error"]
    if not started:
        if error == ERROR_CANCELLED:
            raise ElevationDeclined(UAC_DECLINED)
        raise ElevationFailed(f"Windows could not start the administrator helper (error {error}).")
    process = info.hProcess
    if not process:
        raise ElevationFailed("Windows started the administrator helper without telling Orbit when it finished.")
    try:
        result = wait(process, int(timeout * 1000))
        if result == WAIT_TIMEOUT:
            raise ElevationFailed("The administrator helper did not finish in time.")
        if result != WAIT_OBJECT_0:
            raise ElevationFailed(f"Orbit could not wait for the administrator helper (error {_last_error()}).")
        code = wintypes.DWORD(0)
        if not exit_code(process, ctypes.byref(code)):
            raise ElevationFailed("Orbit could not read the administrator helper's result.")
        return int(code.value)
    finally:
        close(process)


HELPER_FAILURES = {
    3: "The new virtual display settings changed before they could be saved. Try again.",
    4: "Windows did not let Orbit save the Virtual Display Driver settings, even as administrator.",
    5: "Windows could not restart the Virtual Display Driver, so Orbit kept its previous settings.",
    6: PROMPT_TIMEOUT,
    7: HELPER_SAW_STREAM,
    8: STREAM_UNKNOWN,
}
# Exit codes where the helper changed nothing on purpose: 409, like the same checks in Orbit itself.
HELPER_CONFLICTS = {6: "timeout", 7: "stream", 8: "streamUnknown"}


# -- vdd_settings.xml -------------------------------------------------------------------------

_PROLOG_ITEM = re.compile(r"\s+|<\?.*?\?>|<!--.*?-->", re.S)


@dataclass
class VddSettings:
    resolutions: list = field(default_factory=list)  # [(width, height, refresh)] in file order
    global_rates: list = field(default_factory=list)  # [refresh] in file order
    monitor_count: int | None = None

    def mode_strings(self):
        sizes = []
        for width, height, _ in self.resolutions:
            if (width, height) not in sizes:
                sizes.append((width, height))
        modes = {(width, height, refresh) for width, height, refresh in self.resolutions}
        modes.update((width, height, rate) for width, height in sizes for rate in self.global_rates)
        ordered = sorted(modes, key=lambda mode: (mode[0] * mode[1], mode[0], mode[2]))
        return [f"{width}x{height}@{refresh}" for width, height, refresh in ordered]

    def sizes(self):
        found = []
        for width, height, _ in self.resolutions:
            if (width, height) not in found:
                found.append((width, height))
        return found

    def has_mode(self, width, height, refresh):
        if (width, height) not in self.sizes():
            return False
        return refresh in self.global_rates or (width, height, refresh) in self.resolutions


def _decode_xml(data):
    """(text, encoding, bom) for vdd_settings.xml as the driver's XmlLite reads it."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8"), "utf-8", b"\xef\xbb\xbf"
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        encoding = "utf-16-le" if data.startswith(b"\xff\xfe") else "utf-16-be"
        return data[2:].decode(encoding), encoding, data[:2]
    head = data[:200].decode("ascii", "replace")
    declared = re.search(r"""encoding\s*=\s*["']([A-Za-z0-9._-]+)["']""", head)
    encoding = (declared.group(1).lower() if declared else "utf-8")
    try:
        return data.decode(encoding), encoding, b""
    except (LookupError, UnicodeDecodeError) as error:
        raise ValueError("The Virtual Display Driver settings file has an encoding Orbit cannot read.") from error


def _split_prolog(text):
    position = 0
    while True:
        match = _PROLOG_ITEM.match(text, position)
        if not match or match.end() == position:
            break
        position = match.end()
    if text.startswith("<!DOCTYPE", position) or not text.startswith("<", position):
        raise ValueError("The Virtual Display Driver settings file is not in the usual format.")
    return text[:position], text[position:]


def _epilogue(body):
    """Whatever follows the root element (a newline, sometimes a comment): ElementTree drops it."""
    end = body.rfind("</vdd_settings")
    if end < 0:
        return body[len(body.rstrip()):]
    close = body.find(">", end)
    return body[close + 1:] if close >= 0 else ""


def _parse_root(body):
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True, insert_pis=True))
    try:
        root = ET.fromstring(body, parser=parser)
    except ET.ParseError as error:
        raise ValueError(f"The Virtual Display Driver settings file is not valid XML ({error}).") from error
    if root.tag != "vdd_settings":
        raise ValueError("This is not a Virtual Display Driver settings file.")
    return root


def _int_text(element):
    try:
        return int((element.text or "").strip())
    except (TypeError, ValueError):
        return None


def _read_settings(root):
    settings = VddSettings()
    for container in root.iter("resolutions"):
        for item in container.findall("resolution"):
            width, height, refresh = (_int_text(item.find(name)) if item.find(name) is not None else None
                                      for name in ("width", "height", "refresh_rate"))
            if width and height:
                settings.resolutions.append((width, height, refresh or 60))
    for container in root.iter("global"):
        for item in container.findall("g_refresh_rate"):
            rate = _int_text(item)
            if rate and rate not in settings.global_rates:
                settings.global_rates.append(rate)
    for container in root.iter("monitors"):
        count = container.find("count")
        if count is not None:
            settings.monitor_count = _int_text(count)
    return settings


def parse_vdd_settings(data):
    """The sizes and refresh rates a vdd_settings.xml gives Windows."""
    text, _, _ = _decode_xml(data)
    _, body = _split_prolog(text)
    return _read_settings(_parse_root(body))


def _indent_of(whitespace):
    if whitespace and whitespace.strip() == "" and "\n" in whitespace:
        return whitespace[whitespace.rfind("\n") + 1:]
    return None


def _append_child(parent, element, fallback_unit="    "):
    """Appends `element` with the indentation its siblings use (or none in a compact file);
    returns the indentation unit used inside the parent."""
    children = list(parent)
    if children:
        last = children[-1]
        between = children[-2].tail if len(children) >= 2 else parent.text
        closing = last.tail
    else:
        between, closing = None, parent.text
    child_indent = _indent_of(between)
    closing_indent = _indent_of(closing)
    if child_indent is None and closing_indent is not None:
        child_indent = closing_indent + fallback_unit
    if child_indent is None:
        parent.append(element)
        return ""
    if closing_indent is None:
        closing_indent = child_indent[:-len(fallback_unit)] if child_indent.endswith(fallback_unit) else ""
    if children:
        children[-1].tail = "\n" + child_indent
    else:
        parent.text = "\n" + child_indent
    element.tail = "\n" + closing_indent
    parent.append(element)
    unit = child_indent[len(closing_indent):] if child_indent.startswith(closing_indent) else ""
    return unit or fallback_unit


def _fill_simple(element, children, unit, indent):
    """Gives a new element its children (name, text) on their own indented lines."""
    inner = indent + unit if unit else None
    if inner is not None:
        element.text = "\n" + inner
    for index, (name, text) in enumerate(children):
        child = ET.SubElement(element, name)
        child.text = text
        if inner is not None:
            child.tail = "\n" + (inner if index < len(children) - 1 else indent)


def _element_indent(parent, element):
    children = list(parent)
    index = children.index(element)
    whitespace = children[index - 1].tail if index > 0 else parent.text
    return _indent_of(whitespace) or ""


def _ensure_section(root, name):
    section = root.find(name)
    if section is not None:
        return section
    section = ET.Element(name)
    unit = _append_child(root, section)
    if unit:
        indent = _element_indent(root, section)
        section.text = "\n" + indent
    return section


def plan_vdd_modes(data, width, height, refresh):
    """New file contents that list `width`x`height` and the refresh rates Orbit needs, or None
    when the file already lists them. Keeps every other element, comment and the prolog; only
    adds `<resolution>` and `<g_refresh_rate>` entries, never removes one. Always adds the base
    sizes 1920x1080, 2560x1440 and 3840x2160 and the rates 60 and 120 Hz."""
    text, encoding, bom = _decode_xml(data)
    prolog, body = _split_prolog(text)
    root = _parse_root(body)
    before = _read_settings(root)
    wanted_sizes = list(BASE_RESOLUTIONS) + [(width, height)]
    wanted_rates = sorted(set(BASE_REFRESH_RATES) | {refresh})
    missing_sizes = []
    for size in wanted_sizes:
        if size not in before.sizes() and size not in missing_sizes:
            missing_sizes.append(size)
    missing_rates = [rate for rate in wanted_rates if rate not in before.global_rates]
    if not missing_sizes and not missing_rates:
        return None, before
    if len(before.sizes()) + len(missing_sizes) > MAX_RESOLUTIONS:
        raise DisplaySetupError(409, f"The virtual display already lists {len(before.sizes())} screen sizes. "
                                     f"Remove some from {VDD_SETTINGS_NAME} and try again.")
    if len(before.global_rates) + len(missing_rates) > MAX_REFRESH_RATES:
        raise DisplaySetupError(409, f"The virtual display already lists {len(before.global_rates)} refresh rates. "
                                     f"Remove some from {VDD_SETTINGS_NAME} and try again.")
    if missing_rates:
        section = _ensure_section(root, "global")
        for rate in missing_rates:
            item = ET.Element("g_refresh_rate")
            item.text = str(rate)
            _append_child(section, item)
    if missing_sizes:
        section = _ensure_section(root, "resolutions")
        for size_width, size_height in missing_sizes:
            item = ET.Element("resolution")
            unit = _append_child(section, item)
            rate = refresh if (size_width, size_height) == (width, height) else 60
            _fill_simple(item, [("width", str(size_width)), ("height", str(size_height)),
                                ("refresh_rate", str(rate))], unit, _element_indent(section, item))
    serialized = ET.tostring(root, encoding="unicode")
    new_text = prolog + serialized + _epilogue(body)
    after = _read_settings(_parse_root(_split_prolog(new_text)[1]))
    if not after.has_mode(width, height, refresh):
        raise ValueError("Orbit could not add this screen size to the Virtual Display Driver settings.")
    return bom + new_text.encode(encoding), after


# -- Sunshine's log: which display is the virtual one ---------------------------------------------

# The marker only counts in one of Sunshine's own log records ("[2026-10-17 15:20:30.512]: Info: ...")
# and only at the end of its line, where the JSON list starts on the next line.
_DEVICE_LIST_MARKER = re.compile(
    r"^[ \t]*\[\d{4}[-:]\d{2}[-:]\d{2}[^\]\r\n]*\][ \t]*:?[ \t]*[A-Za-z]+[ \t]*:[^\r\n]*?"
    r"Currently available (?:display )?devices:[ \t]*\r?$", re.I | re.M)
_LOG_LINE_PREFIX = re.compile(r"^\s*\[\d{4}-\d{2}-\d{2}[^\]]*\]\s*:?\s*(?:[A-Za-z]+\s*:\s*)?")
# libdisplaydevice's device ids are braced UUIDs ({de9bb7e2-186e-505b-9e93-f48793333810}). Sunshine
# writes output_name into sunshine.conf as a "key = value" line, so nothing else is ever sent.
_DEVICE_ID = re.compile(r"\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}")


def valid_device_id(value):
    return isinstance(value, str) and _DEVICE_ID.fullmatch(value) is not None


def parse_display_devices(log_text):
    """The newest display list Sunshine logged (libdisplaydevice's JSON after "Currently available
    display devices:" at the end of one of its log records), as a list of dicts, or None when the
    log has no readable list."""
    if not isinstance(log_text, str) or not log_text:
        return None
    decoder = json.JSONDecoder()
    for match in reversed(list(_DEVICE_LIST_MARKER.finditer(log_text))):
        rest = log_text[match.end():]
        candidates = [rest.lstrip()]
        # Some log viewers and formats prefix every line with the time and level.
        stripped = "\n".join(_LOG_LINE_PREFIX.sub("", line) for line in rest.splitlines()[:4000])
        candidates.append(stripped.lstrip())
        for candidate in candidates:
            if not candidate.startswith("["):
                continue
            try:
                value, _ = decoder.raw_decode(candidate)
            except ValueError:
                continue
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict) and isinstance(item.get("device_id"), str)
                        and item.get("device_id")]
    return None


def _vdd_score(device):
    score = 0
    edid = device.get("edid") if isinstance(device.get("edid"), dict) else {}
    manufacturer = str(edid.get("manufacturer_id") or "").strip().upper()
    product = str(edid.get("product_code") or "").strip().upper().removeprefix("0X")
    if manufacturer == "MTT" and product in ("1337", "4919"):
        score = max(score, 3)
    name = str(device.get("friendly_name") or "").strip().casefold()
    if VDD_FRIENDLY_NAME.casefold() in name:
        score = max(score, 3)
    elif name.startswith("vdd") or any(marker in name for marker in ("virtual display driver", "virtualdisplaydriver",
                                                                     "mttvdd")):
        score = max(score, 2)
    return score


def pick_vdd_device(devices):
    """The Virtual Display Driver's entry in Sunshine's display list, or None."""
    best, best_score = None, 0
    for device in devices or []:
        score = _vdd_score(device)
        if score > best_score:
            best, best_score = device, score
    return best


# -- Sunshine's web API ---------------------------------------------------------------------------

class SunshineWebAPI:
    """Sunshine's local web API on https://127.0.0.1:<port+1>, with the login saved in Orbit.

    Sunshine uses a self-signed certificate on loopback, so verification is skipped for these
    localhost requests only (like `_sunshine_web_call` in orbit_agent). Requests carry neither
    Origin nor Referer, which Sunshine's CSRF check lets through.
    """

    def __init__(self, credentials, base_port, timeout=10.0):
        self._credentials = credentials
        self._base_port = base_port
        self.timeout = timeout

    def login_saved(self):
        try:
            return self._credentials() is not None
        except Exception:
            return False

    def _request(self, method, path, payload=None, timeout=None):
        credentials = self._credentials()
        if credentials is None:
            raise DisplaySetupError(428, LOGIN_MISSING)
        url = f"https://127.0.0.1:{int(self._base_port()) + 1}{path}"
        token = base64.b64encode(f"{credentials[0]}:{credentials[1]}".encode("utf-8")).decode("ascii")
        headers = {"Authorization": f"Basic {token}", "Accept": "application/json, text/plain"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(request, timeout=timeout or self.timeout, context=context) as response:
            return response.read(MAX_SUNSHINE_REPLY_BYTES)

    def _call(self, method, path, payload=None, timeout=None):
        try:
            return self._request(method, path, payload, timeout)
        except DisplaySetupError:
            raise
        except urllib.error.HTTPError as error:
            if error.code == 401:
                raise DisplaySetupError(428, LOGIN_REJECTED) from error
            if error.code == 403:
                raise DisplaySetupError(502, "Sunshine's web UI refused the request from this PC. Check Origin Web UI "
                                             "Allowed in Sunshine's network settings.") from error
            message = None
            try:
                body = json.loads(error.read() or b"{}")
                message = body.get("error") if isinstance(body, dict) else None
            except Exception:
                pass
            detail = f"Sunshine answered HTTP {error.code} to {path}" + (f": {message}" if message else ".")
            raise DisplaySetupError(502, detail) from error
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
            raise DisplaySetupError(502, SUNSHINE_UNREACHABLE) from error

    def _json(self, method, path, payload=None):
        raw = self._call(method, path, payload)
        try:
            body = json.loads(raw or b"{}")
        except ValueError as error:
            raise DisplaySetupError(502, f"Sunshine sent an unreadable answer to {path}.") from error
        if not isinstance(body, dict):
            raise DisplaySetupError(502, f"Sunshine sent an unexpected answer to {path}.")
        return body

    def config(self):
        """(settings without status/platform/version, version or None)."""
        body = self._json("GET", "/api/config")
        version = body.get("version")
        settings = {key: value for key, value in body.items() if key not in CONFIG_META_KEYS}
        return settings, (str(version) if isinstance(version, (str, int, float)) and str(version) else None)

    def save_config(self, settings):
        body = self._json("POST", "/api/config", settings)
        if body.get("status") not in (True, "true", "True"):
            message = body.get("error") if isinstance(body.get("error"), str) else None
            raise DisplaySetupError(502, "Sunshine did not save the settings" + (f": {message}" if message else "."))

    def restart(self):
        """Asks Sunshine to restart. It may drop the connection without answering, which is fine."""
        try:
            self._request("POST", "/api/restart", {})
        except urllib.error.HTTPError as error:
            if error.code == 401:
                raise DisplaySetupError(428, LOGIN_REJECTED) from error
            raise DisplaySetupError(502, f"Sunshine answered HTTP {error.code} when asked to restart.") from error
        except (http.client.HTTPException, ConnectionError, TimeoutError, socket.timeout):
            pass  # Sunshine exits while answering
        except urllib.error.URLError as error:
            if isinstance(error.reason, (ConnectionResetError, ConnectionAbortedError, TimeoutError, socket.timeout)):
                return
            raise DisplaySetupError(502, SUNSHINE_UNREACHABLE) from error
        except OSError as error:
            raise DisplaySetupError(502, SUNSHINE_UNREACHABLE) from error

    def logs(self):
        raw = self._call("GET", "/api/logs", timeout=max(self.timeout, 20.0))
        return raw.decode("utf-8", "replace")

    def server_info(self, timeout=3.0):
        """(running app id or None, state or None) from Sunshine's public `/serverinfo` on
        http://127.0.0.1:<port> (plain HTTP, no login and no pairing: nvhttp serverinfo reports
        `currentgame` and `state` to every client). Raises OSError (nothing answers),
        http.client.HTTPException or ValueError."""
        connection = http.client.HTTPConnection("127.0.0.1", int(self._base_port()), timeout=timeout)
        try:
            connection.request("GET", "/serverinfo", headers={"Accept": "application/xml, text/xml"})
            response = connection.getresponse()
            body = response.read(MAX_SERVER_INFO_BYTES + 1)
            status = response.status
        finally:
            connection.close()
        if status != 200:
            raise ValueError(f"Sunshine answered HTTP {status} to /serverinfo.")
        if len(body) > MAX_SERVER_INFO_BYTES:
            raise ValueError("Sunshine's /serverinfo answer is too large.")
        return parse_server_info(body)


MAX_SERVER_INFO_BYTES = 256 * 1024


def parse_server_info(data):
    """(running app id or None, state or None) from Sunshine's /serverinfo XML."""
    if isinstance(data, bytes):
        data = data.decode("utf-8", "replace")
    if "<!DOCTYPE" in data or "<!ENTITY" in data:
        raise ValueError("Sunshine's /serverinfo answer is not in the usual format.")
    try:
        root = ET.fromstring(data.strip())
    except ET.ParseError as error:
        raise ValueError("Sunshine sent an unreadable /serverinfo answer.") from error
    game_text = (root.findtext("currentgame") or "").strip()
    state = (root.findtext("state") or "").strip() or None
    try:
        game = int(game_text) if game_text else None
    except ValueError:
        game = None
    return game, state


def app_running_from(current_game, state):
    """True when /serverinfo says an app runs, False when it says none does, None otherwise."""
    state = (state or "").upper()
    if state.endswith("_SERVER_BUSY") or (current_game is not None and current_game != 0):
        return True
    if current_game == 0 or state.endswith("_SERVER_FREE"):
        return False
    return None


def sunshine_supports_display_settings(version):
    """True from Sunshine 2025.118.151840 (the first release with per-stream display settings),
    False for the 0.x releases before it, None when the version is unknown or a development build."""
    if not version:
        return None
    match = re.match(r"^\s*v?(\d+)\.(\d+)\.(\d+)", str(version))
    if not match:
        return None
    major, minor, patch = (int(part) for part in match.groups())
    if major >= 2000:
        return (major, minor) >= (2025, 118)
    if (major, minor, patch) == (0, 0, 0):
        return None
    return False


# -- is anybody streaming? --------------------------------------------------------------------

def sunshine_pids(ps=None):
    ps = ps or psutil
    found = set()
    for process in ps.process_iter(["name"]):
        name = (getattr(process, "info", {}) or {}).get("name") or ""
        if name.lower() in ("sunshine.exe", "sunshine"):
            found.add(process.pid)
    return found


def _listener_ports(base_port):
    # HTTPS (base - 5), HTTP (base), web UI (base + 1) and RTSP (base + 21): only Sunshine listens there.
    return {base_port - 5, base_port, base_port + 1, base_port + 21}


def _listener_pids(connections, base_port):
    """Owners of TCP listeners on Sunshine's ports, so a renamed build or a fork still counts."""
    ports = _listener_ports(base_port)
    found = set()
    for connection in connections:
        if getattr(connection, "type", None) != socket.SOCK_STREAM or getattr(connection, "status", None) != "LISTEN":
            continue
        port = getattr(getattr(connection, "laddr", None), "port", None)
        pid = getattr(connection, "pid", None)
        if port in ports and pid:
            found.add(pid)
    return found


def sunshine_processes(base_port, ps=None):
    """Sunshine's pids: processes named sunshine.exe plus the owners of its TCP listeners."""
    ps = ps or psutil
    pids = set(sunshine_pids(ps))
    try:
        pids |= _listener_pids(ps.net_connections(kind="inet"), base_port)
    except Exception:
        pass
    return pids


def _stream_sockets_open(connections, pids, base_port):
    stream_udp = {base_port + 9, base_port + 10, base_port + 11}
    rtsp = base_port + 21
    for connection in connections:
        if getattr(connection, "pid", None) not in pids:
            continue
        port = getattr(getattr(connection, "laddr", None), "port", None)
        kind = getattr(connection, "type", None)
        if kind == socket.SOCK_DGRAM and port in stream_udp:
            return True
        if kind == socket.SOCK_STREAM and port == rtsp and getattr(connection, "status", None) == "ESTABLISHED":
            return True
    return False


SERVER_INFO_ERRORS = (OSError, ValueError, http.client.HTTPException, DisplaySetupError)


@dataclass(frozen=True)
class SunshineActivity:
    """What Sunshine is doing; None in a field means Orbit could not tell."""
    pids: frozenset = frozenset()
    streaming: bool | None = False  # its stream sockets are open
    app_running: bool | None = False  # /serverinfo reports a running app (restarting would close it)

    @property
    def busy(self):
        if self.streaming or self.app_running:
            return True
        if self.streaming is None or self.app_running is None:
            return None
        return False


def sunshine_activity(base_port, ps=None, server_info=None):
    """Whether Sunshine streams or runs an app right now, judged conservatively.

    Sunshine opens its video, control and audio UDP ports (base + 9, 10, 11) when the first
    stream starts and closes them after the last one ends, and a client being set up keeps an
    RTSP connection (TCP base + 21) open. Only sockets owned by Sunshine count; its process is
    found by name and as the owner of its listeners. A client that left without quitting leaves
    no sockets but keeps the app running, which a restart would close, so `server_info()` (see
    SunshineWebAPI.server_info) is asked too. When something answers there but no Sunshine
    process is found, or it cannot be read while Sunshine runs, the answer is "cannot tell".
    """
    ps = ps or psutil
    try:
        named = sunshine_pids(ps)
    except Exception:
        LOGGER.warning("Could not list processes to look for Sunshine", exc_info=True)
        return SunshineActivity(frozenset(), None, None)
    try:
        connections = list(ps.net_connections(kind="inet"))
    except Exception:
        LOGGER.warning("Could not list network connections to check for a running stream", exc_info=True)
        connections = None
    pids = set(named) | (_listener_pids(connections, base_port) if connections is not None else set())
    if not pids:
        if server_info is None:
            return SunshineActivity(frozenset(), False, False)
        try:
            server_info()
        except SERVER_INFO_ERRORS:
            return SunshineActivity(frozenset(), False, False)  # nothing answers: Sunshine is not running
        LOGGER.warning("Something answers on Sunshine's port %s, but Orbit could not find Sunshine's process",
                       base_port)
        return SunshineActivity(frozenset(), None, None)
    streaming = None if connections is None else _stream_sockets_open(connections, pids, base_port)
    app_running = False
    if server_info is not None:
        try:
            app_running = app_running_from(*server_info())
        except SERVER_INFO_ERRORS:
            LOGGER.info("Could not read Sunshine's /serverinfo", exc_info=True)
            app_running = None
    return SunshineActivity(frozenset(pids), streaming, app_running)


def stream_activity(base_port, ps=None, server_info=None):
    """True when a stream (or, with `server_info`, a Sunshine app) is running, False when not,
    None when Orbit cannot tell."""
    return sunshine_activity(base_port, ps, server_info).busy


# -- Windows: the driver, its settings file and the displays ----------------------------------------

@dataclass
class Display:
    name: str
    adapter: str
    monitor_id: str
    attached: bool
    primary: bool
    vdd: bool
    x: int = 0
    y: int = 0
    width: int = 0
    height: int = 0
    refresh: int = 0

    def summary(self):
        return {"x": self.x, "y": self.y, "width": self.width, "height": self.height, "refreshRate": self.refresh}


def _is_vdd_display(adapter_string, monitor_id):
    if VDD_MONITOR_ID.casefold() in (monitor_id or "").casefold():
        return True
    adapter = (adapter_string or "").casefold()
    return any(marker in adapter for marker in ("virtual display driver", "virtualdisplaydriver", "mttvdd"))


class WindowsDisplayPlatform:
    """Everything this feature asks Windows. Tests replace it with a fake."""

    def __init__(self, registry_provider=_registry, library=_library, ps=None):
        self._registry_provider = registry_provider
        self._library = library
        self._ps = ps

    # registry -------------------------------------------------------------------------------

    def _open_hklm(self, path):
        registry = self._registry_provider()
        if registry is None:
            return None, None
        access = registry.KEY_READ | getattr(registry, "KEY_WOW64_64KEY", 0)
        try:
            return registry, registry.OpenKey(registry.HKEY_LOCAL_MACHINE, path, 0, access)
        except OSError:
            return registry, None

    def _read_value(self, path, name):
        registry, key = self._open_hklm(path)
        if key is None:
            return None
        try:
            with key:
                value, kind = registry.QueryValueEx(key, name)
        except OSError:
            return None
        if isinstance(value, str) and kind == getattr(registry, "REG_EXPAND_SZ", 2):
            try:
                value = registry.ExpandEnvironmentStrings(value)
            except Exception:
                pass
        return value

    def key_exists(self, path):
        _, key = self._open_hklm(path)
        if key is None:
            return False
        try:
            key.Close()
        except Exception:
            pass
        return True

    def vdd_settings_path(self):
        configured = self._read_value(VDD_REGISTRY_KEY, "VDDPATH")
        folder = configured.strip() if isinstance(configured, str) and configured.strip() else VDD_DEFAULT_DIRECTORY
        return Path(folder.rstrip("\\/") or folder) / VDD_SETTINGS_NAME

    def vdd_instances(self):
        """Device instance IDs whose hardware ID is Root\\MttVDD (from the device registry)."""
        registry, root = self._open_hklm(DEVICE_ENUM_ROOT)
        if root is None:
            return []
        found = []
        try:
            with root:
                for class_name in self._subkeys(registry, root):
                    try:
                        with registry.OpenKey(root, class_name, 0, registry.KEY_READ) as class_key:
                            for instance in self._subkeys(registry, class_key):
                                try:
                                    with registry.OpenKey(class_key, instance, 0, registry.KEY_READ) as device:
                                        ids, _ = registry.QueryValueEx(device, "HardwareID")
                                except OSError:
                                    continue
                                ids = [ids] if isinstance(ids, str) else list(ids or [])
                                if any(str(item).casefold() == VDD_HARDWARE_ID for item in ids):
                                    found.append(f"ROOT\\{class_name}\\{instance}")
                    except OSError:
                        continue
        except OSError:
            return found
        return found

    @staticmethod
    def _subkeys(registry, key):
        names = []
        for index in range(4096):
            try:
                names.append(registry.EnumKey(key, index))
            except OSError:
                break
        return names

    def sudovda_installed(self):
        return self.key_exists(SUDOVDA_REGISTRY_KEY)

    # device status --------------------------------------------------------------------------

    def device_status(self, instance_id):
        """running | disabled | problem | notPresent | unknown for a device instance."""
        try:
            cfgmgr = self._library("cfgmgr32")
            locate = _prototype(cfgmgr.CM_Locate_DevNodeW, [ctypes.POINTER(wintypes.DWORD), wintypes.LPCWSTR,
                                                            wintypes.ULONG], wintypes.DWORD)
            status_of = _prototype(cfgmgr.CM_Get_DevNode_Status, [ctypes.POINTER(wintypes.ULONG),
                                                                  ctypes.POINTER(wintypes.ULONG), wintypes.DWORD,
                                                                  wintypes.ULONG], wintypes.DWORD)
            node = wintypes.DWORD(0)
            result = locate(ctypes.byref(node), instance_id, CM_LOCATE_DEVNODE_NORMAL)
            if result == CR_NO_SUCH_DEVNODE:
                return "notPresent"
            if result != CR_SUCCESS:
                return "unknown"
            status, problem = wintypes.ULONG(0), wintypes.ULONG(0)
            if status_of(ctypes.byref(status), ctypes.byref(problem), node.value, 0) != CR_SUCCESS:
                return "unknown"
            if status.value & DN_HAS_PROBLEM:
                return "disabled" if problem.value == CM_PROB_DISABLED else "problem"
            return "running" if status.value & DN_STARTED else "unknown"
        except Exception:
            return "unknown"

    # displays -------------------------------------------------------------------------------

    def _user32(self):
        user32 = self._library("user32")
        _prototype(user32.EnumDisplayDevicesW, [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(DISPLAY_DEVICEW),
                                                wintypes.DWORD], wintypes.BOOL)
        _prototype(user32.EnumDisplaySettingsExW, [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(DEVMODEW),
                                                   wintypes.DWORD], wintypes.BOOL)
        _prototype(user32.ChangeDisplaySettingsExW, [wintypes.LPCWSTR, ctypes.POINTER(DEVMODEW), wintypes.HWND,
                                                     wintypes.DWORD, ctypes.c_void_p], wintypes.LONG)
        return user32

    def list_displays(self):
        user32 = self._user32()
        displays = []
        for index in range(64):
            adapter = DISPLAY_DEVICEW()
            adapter.cb = ctypes.sizeof(DISPLAY_DEVICEW)
            if not user32.EnumDisplayDevicesW(None, index, ctypes.byref(adapter), 0):
                break
            if adapter.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER:
                continue
            monitor = DISPLAY_DEVICEW()
            monitor.cb = ctypes.sizeof(DISPLAY_DEVICEW)
            monitor_id = ""
            if user32.EnumDisplayDevicesW(adapter.DeviceName, 0, ctypes.byref(monitor), EDD_GET_DEVICE_INTERFACE_NAME):
                monitor_id = monitor.DeviceID
            display = Display(name=adapter.DeviceName, adapter=adapter.DeviceString, monitor_id=monitor_id,
                              attached=bool(adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP),
                              primary=bool(adapter.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE),
                              vdd=_is_vdd_display(adapter.DeviceString, monitor_id))
            if display.attached:
                mode = DEVMODEW()
                mode.dmSize = ctypes.sizeof(DEVMODEW)
                if user32.EnumDisplaySettingsExW(adapter.DeviceName, ENUM_CURRENT_SETTINGS, ctypes.byref(mode), 0):
                    display.x, display.y = int(mode.dmPositionX), int(mode.dmPositionY)
                    display.width, display.height = int(mode.dmPelsWidth), int(mode.dmPelsHeight)
                    display.refresh = int(mode.dmDisplayFrequency)
                else:
                    display.attached = False
            displays.append(display)
        return displays

    def display_offers_mode(self, device_name, width, height, refresh):
        user32 = self._user32()
        for index in range(4096):
            mode = DEVMODEW()
            mode.dmSize = ctypes.sizeof(DEVMODEW)
            if not user32.EnumDisplaySettingsExW(device_name, index, ctypes.byref(mode), 0):
                return False
            if (mode.dmPelsWidth, mode.dmPelsHeight) == (width, height) and abs(int(mode.dmDisplayFrequency) - refresh) <= 1:
                return True
        return False

    def move_display(self, device_name, x, y):
        """Moves one display on the desktop; True when Windows applied it."""
        user32 = self._user32()
        mode = DEVMODEW()
        mode.dmSize = ctypes.sizeof(DEVMODEW)
        mode.dmFields = DM_POSITION
        mode.dmPositionX = int(x)
        mode.dmPositionY = int(y)
        result = user32.ChangeDisplaySettingsExW(device_name, ctypes.byref(mode), None,
                                                 CDS_UPDATEREGISTRY | CDS_NORESET, None)
        if result != DISP_CHANGE_SUCCESSFUL:
            LOGGER.warning("Windows refused to move %s (ChangeDisplaySettingsEx %s)", device_name, result)
            return False
        result = user32.ChangeDisplaySettingsExW(None, None, None, 0, None)
        if result != DISP_CHANGE_SUCCESSFUL:
            LOGGER.warning("Windows did not apply the new display layout (ChangeDisplaySettingsEx %s)", result)
            return False
        return True

    # files, pipe, elevation ---------------------------------------------------------------------

    @staticmethod
    def read_file(path):
        return Path(path).read_bytes()

    @staticmethod
    def write_file_as_user(path, data):
        """Replaces `path` through a temporary file next to it; raises NeedsElevation when the user
        may not write there."""
        path = Path(path)
        temporary = path.with_name(path.name + ".orbit-tmp")
        try:
            temporary.write_bytes(data)
            backup = path.with_name(VDD_BACKUP_NAME)
            if path.exists() and not backup.exists():
                try:
                    backup.write_bytes(path.read_bytes())
                except OSError:
                    pass
            for attempt in range(6):
                try:
                    os.replace(temporary, path)
                    break
                except PermissionError:
                    if attempt == 5:
                        raise
                    time.sleep(0.05 * (attempt + 1))
        except PermissionError as error:
            raise NeedsElevation(str(error)) from error
        finally:
            try:
                temporary.unlink()
            except OSError:
                pass

    def send_pipe_command(self, command):
        return send_pipe_command(command, library=self._library("kernel32"))

    def run_elevated(self, script):
        return run_elevated_powershell(script, shell32=self._library("shell32"), kernel32=self._library("kernel32"),
                                       ole32=self._library("ole32"))


@dataclass
class VirtualDisplayInfo:
    driver: str | None = None  # "vdd", "sudovda" or None
    settings_path: Path | None = None
    settings_exists: bool = False
    settings: VddSettings | None = None
    settings_error: str | None = None
    instances: list = field(default_factory=list)
    statuses: dict = field(default_factory=dict)  # instance id -> running | disabled | problem | notPresent | unknown
    device_status: str = "notFound"

    @property
    def installed(self):
        return self.driver is not None

    def restartable_instances(self):
        """Driver instances a restart should touch: never one the user disabled."""
        return [item for item in self.instances if self.statuses.get(item, "unknown") in ("running", "problem", "unknown")]

    def payload(self):
        settings = self.settings
        return {
            "installed": self.installed,
            "driver": self.driver,
            "modes": settings.mode_strings() if settings else [],
            "resolutions": [f"{width}x{height}" for width, height in settings.sizes()] if settings else [],
            "refreshRates": sorted(set(settings.global_rates)) if settings else [],
            "settingsPath": str(self.settings_path) if self.settings_path and self.driver == "vdd" else None,
            "settingsError": self.settings_error,
            "deviceStatus": self.device_status,
        }


def detect_virtual_display(platform):
    """What this PC has: the Virtual Display Driver (device and/or settings file), SudoVDA, or nothing."""
    info = VirtualDisplayInfo()
    try:
        info.settings_path = platform.vdd_settings_path()
    except Exception:
        info.settings_path = None
    try:
        info.instances = list(platform.vdd_instances())
    except Exception:
        LOGGER.debug("Could not look for the Virtual Display Driver device", exc_info=True)
        info.instances = []
    if info.settings_path is not None:
        try:
            info.settings = parse_vdd_settings(platform.read_file(info.settings_path))
            info.settings_exists = True
        except FileNotFoundError:
            info.settings_exists = False
        except ValueError as error:
            info.settings_exists = True
            info.settings_error = str(error)
        except OSError:
            info.settings_exists = True
            info.settings_error = "Orbit could not read the Virtual Display Driver settings file."
    if info.instances or info.settings_exists:
        info.driver = "vdd"
        info.statuses = {instance: platform.device_status(instance) for instance in info.instances}
        for preferred in ("running", "problem", "disabled", "unknown", "notPresent"):
            if preferred in info.statuses.values():
                info.device_status = preferred
                break
    else:
        try:
            if platform.sudovda_installed():
                info.driver = "sudovda"
                info.device_status = "unknown"
        except Exception:
            pass
    return info


# -- the feature ------------------------------------------------------------------------------

def _fill_overrides(only_display, device_id):
    values = {"dd_configuration_option": "ensure_only_display" if only_display else "ensure_primary",
              "dd_resolution_option": "auto", "dd_refresh_rate_option": "auto"}
    if device_id:
        values["output_name"] = device_id
    return values


def _second_screen_overrides(device_id):
    return {"output_name": device_id, "dd_configuration_option": "ensure_active", "dd_resolution_option": "auto"}


def _without_meta(config):
    return {key: value for key, value in (config or {}).items() if key not in CONFIG_META_KEYS}


def merge_sunshine_config(current, original, overrides):
    """The full map to post: `current` with Orbit's keys taken from `original` (the map before
    Orbit changed anything) and then from `overrides`. Keys outside MANAGED_KEYS are never
    touched. A managed key that ends up empty is left out, which is how Sunshine forgets it."""
    target = _without_meta(current)
    for key in MANAGED_KEYS:
        value = overrides[key] if key in overrides else (original or {}).get(key)
        if value is None or (isinstance(value, str) and not value.strip()):
            target.pop(key, None)
        else:
            target[key] = value
    return target


PENDING_HINT = ("Orbit moves the virtual display to the {side} of your main display when the stream starts. "
                "If it ends up somewhere else: open Windows Settings > System > Display, drag the screen named "
                "'VDD by MTT' to the {side} and select Apply.")


class StreamDisplayService:
    """The feature's logic; the routes are thin wrappers around it."""

    def __init__(self, sunshine, store_provider=None, platform=None, ps=None, sunshine_base_port=None,
                 clock=time.monotonic, sleep=time.sleep, restart_timeout=25.0, staging_directory=None,
                 start_placer=True, desktop_available=None):
        self.sunshine = sunshine
        # False in the boot-time instance: no desktop to show the UAC prompt or move displays on.
        self._desktop_available = desktop_available or (lambda: True)
        self._store_provider = store_provider or orbit_settings.shared_store
        self.platform = platform or WindowsDisplayPlatform()
        self._ps = ps
        self._base_port = sunshine_base_port or (lambda: 47989)
        self._clock = clock
        self._sleep = sleep
        self.restart_timeout = restart_timeout
        self._staging_directory = staging_directory
        self._start_placer = start_placer
        self._operation = threading.Lock()
        self._device_cache = None  # (Sunshine pids, time, devices or None)
        self._placer = None
        self._placer_lock = threading.Lock()

    # saved state ------------------------------------------------------------------------------

    def state(self):
        value = self._store_provider().get(SETTINGS_SECTION, {})
        return value if isinstance(value, dict) else {}

    def _save_state(self, state):
        try:
            self._store_provider().replace(SETTINGS_SECTION, state)
        except (OSError, ValueError) as error:
            LOGGER.error("Could not save the display settings", exc_info=True)
            raise DisplaySetupError(503, SETTINGS_NOT_SAVED) from error

    def _restore_state(self, previous):
        """Puts the section back exactly as it was (None: it did not exist)."""
        if previous is None:
            try:
                self._store_provider().remove(SETTINGS_SECTION)
            except (OSError, ValueError) as error:
                LOGGER.error("Could not remove the display settings", exc_info=True)
                raise DisplaySetupError(503, SETTINGS_NOT_SAVED) from error
        else:
            self._save_state(previous)

    def _rollback_state(self, previous):
        """_restore_state during a rollback: a failure is logged, so the original error still reaches the app."""
        try:
            self._restore_state(previous)
        except DisplaySetupError:
            LOGGER.error("Could not put Orbit's display settings back after a failed change")

    @staticmethod
    def fill_state(state):
        fill = state.get("fill") if isinstance(state.get("fill"), dict) else {}
        return {"enabled": bool(fill.get("enabled")), "onlyDisplay": bool(fill.get("onlyDisplay"))}

    @staticmethod
    def second_state(state):
        second = state.get("secondScreen") if isinstance(state.get("secondScreen"), dict) else {}
        return {"active": bool(second.get("active")),
                "position": second.get("position") if second.get("position") in ("left", "right") else None,
                "width": second.get("width"), "height": second.get("height"),
                "refreshRate": second.get("refreshRate")}

    def _active(self, state):
        return self.fill_state(state)["enabled"] or self.second_state(state)["active"]

    # checks -----------------------------------------------------------------------------------

    def virtual_display(self):
        return detect_virtual_display(self.platform)

    def activity(self):
        return sunshine_activity(int(self._base_port()), self._ps, self.sunshine.server_info)

    def stream_active(self):
        return self.activity().busy

    def _require_idle(self):
        activity = self.activity()
        if activity.streaming:
            raise DisplaySetupError(409, STREAM_RUNNING)
        if activity.app_running:
            raise DisplaySetupError(409, APP_RUNNING)
        if activity.busy is None:
            raise DisplaySetupError(409, STREAM_UNKNOWN)

    def _sunshine_pids(self):
        try:
            return frozenset(sunshine_processes(int(self._base_port()), self._ps))
        except Exception:
            return frozenset()

    def display_devices(self, refresh=False):
        """Sunshine's display list from its log (cached per Sunshine process for 30 s)."""
        pids = self._sunshine_pids()
        cached = self._device_cache
        if not refresh and cached and cached[0] == pids and self._clock() - cached[1] < 30:
            return cached[2]
        devices = parse_display_devices(self.sunshine.logs())
        self._device_cache = (pids, self._clock(), devices)
        return devices

    def _lookup_device(self, refresh=False):
        """(device id or None, reason or None, missing) where `missing` is True only when Sunshine's
        log was read, lists displays and the virtual one is not among them. A log that cannot be
        fetched raises its DisplaySetupError (428 or 502)."""
        devices = self.display_devices(refresh=refresh)
        if devices is None:
            return None, NO_DEVICE_LIST, False
        device = pick_vdd_device(devices)
        if device is None:
            return None, VDD_NOT_IN_SUNSHINE, True
        if not valid_device_id(device.get("device_id")):
            LOGGER.warning("Sunshine's log lists the virtual display with an unexpected id; not using it")
            return None, DEVICE_ID_INVALID, False
        return device["device_id"], None, False

    def vdd_device_id(self, refresh=False):
        """(device id or None, reason or None) for Sunshine's output_name."""
        try:
            device_id, reason, _ = self._lookup_device(refresh=refresh)
        except DisplaySetupError as error:
            return None, error.detail
        return device_id, reason

    # status -----------------------------------------------------------------------------------

    def _placement_now(self, position):
        try:
            target = self.placement_target(self.platform.list_displays(), position or "right")
        except Exception:
            return None
        if target is None:
            return "pending"
        return "done" if target[3] else "manual"

    def status(self):
        state = self.state()
        login_saved = self.sunshine.login_saved()
        virtual = self.virtual_display()
        second = self.second_state(state)
        saved = state.get("savedSunshineConfig")
        activity = self.activity()
        payload = {
            "sunshineVersion": None,
            "sunshineRunning": bool(activity.pids),
            "loginSaved": login_saved,
            "sunshineSupported": None,
            "streamActive": activity.streaming,
            "appRunning": activity.app_running,
            "virtualDisplay": {**virtual.payload(), "deviceId": None, "deviceIdReason": None,
                               "attached": None, "position": None},
            "config": dict.fromkeys(REPORTED_KEYS),
            "fill": self.fill_state(state),
            "fillReady": False,
            "secondScreen": {**second, "placement": self._placement_now(second["position"]) if second["active"] else None},
            "savedConfig": {"available": isinstance(saved, dict),
                            "savedAt": state.get("savedAt") if isinstance(saved, dict) else None},
            "installCommand": VDD_INSTALL_COMMAND,
            "reason": None,
        }
        reason = None
        if login_saved:
            try:
                config, version = self.sunshine.config()
                payload["sunshineVersion"] = version
                payload["sunshineRunning"] = True
                payload["sunshineSupported"] = sunshine_supports_display_settings(version)
                payload["config"] = {key: (config.get(key) if config.get(key) not in ("", None) else None)
                                     for key in REPORTED_KEYS}
            except DisplaySetupError as error:
                reason = error.detail
        else:
            reason = LOGIN_MISSING
        if virtual.driver == "vdd":
            if payload["sunshineVersion"] is not None:
                device_id, device_reason = self.vdd_device_id()
                payload["virtualDisplay"]["deviceId"] = device_id
                payload["virtualDisplay"]["deviceIdReason"] = device_reason
            try:
                vdd = next((display for display in self.platform.list_displays() if display.vdd), None)
            except Exception:
                vdd = None
            if vdd is not None:
                payload["virtualDisplay"]["attached"] = vdd.attached
                payload["virtualDisplay"]["position"] = vdd.summary() if vdd.attached else None
        if reason is None:
            if payload["sunshineSupported"] is False:
                reason = SUNSHINE_TOO_OLD
            elif virtual.driver is None:
                reason = VDD_MISSING
            elif virtual.driver == "sudovda":
                reason = SUDOVDA_ONLY
            elif virtual.settings_error:
                reason = virtual.settings_error
            elif not virtual.settings_exists:
                reason = (f"The Virtual Display Driver's settings file was not found ({virtual.settings_path}). "
                          f"Reinstall the driver with: {VDD_INSTALL_COMMAND}")
            elif virtual.device_status == "disabled":
                reason = VDD_DISABLED
            elif payload["virtualDisplay"]["deviceId"] is None:
                reason = payload["virtualDisplay"]["deviceIdReason"] or VDD_NOT_IN_SUNSHINE
        payload["fillReady"] = reason is None
        payload["reason"] = reason
        if second["active"]:
            self._ensure_placer(second["position"] or "right")
        return payload

    # Sunshine changes -------------------------------------------------------------------------

    def _begin(self):
        if not self._operation.acquire(blocking=False):
            raise DisplaySetupError(409, BUSY)

    def _wait_for_sunshine(self, old_pids):
        """Waits until the old Sunshine process is gone and the web API answers again."""
        deadline = self._clock() + self.restart_timeout
        while old_pids and self._clock() < deadline and self._sunshine_pids() & old_pids:
            self._sleep(0.5)
        while self._clock() < deadline:
            try:
                self.sunshine.config()
                return True
            except DisplaySetupError:
                self._sleep(0.5)
        return False

    def _restart_sunshine(self):
        """Restarts Sunshine, only while nobody streams and no app runs. True when it answers again."""
        self._require_idle()
        old_pids = self._sunshine_pids()
        self.sunshine.restart()
        self._device_cache = None
        return self._wait_for_sunshine(old_pids)

    def _resolve_device_id(self, virtual):
        """The VDD's id from Sunshine's log. Sunshine lists displays only when it starts, so when the
        log lists displays but not the running driver, Sunshine is restarted once (while idle). A log
        that cannot be fetched is a Sunshine failure (502), never a reason to restart it."""
        device_id, reason, missing = self._lookup_device(refresh=True)
        if device_id or not missing or virtual.device_status not in ("running", "unknown"):
            return device_id, reason, False
        if not self._restart_sunshine():
            return None, "Sunshine is still restarting. Try again in a few seconds.", True
        device_id, reason, _ = self._lookup_device(refresh=True)
        return device_id, reason, True

    def _device_id_in_use(self, state, current):
        """The virtual display's id while one feature stays on and the other changes: the id saved
        when it was turned on, else Sunshine's log, else Sunshine's current output_name is kept (with
        a warning) rather than dropped."""
        stored = state.get("outputName")
        if valid_device_id(stored):
            return stored, None
        device_id, reason = self.vdd_device_id(refresh=True)
        if device_id:
            return device_id, None
        kept = current.get("output_name")
        kept = kept if isinstance(kept, str) and kept.strip() else None
        warning = ("Orbit could not find the virtual display in Sunshine's log, so Sunshine keeps the display it "
                   "uses now." + (f" {reason}" if reason else ""))
        return kept, warning

    def _apply_sunshine(self, current, new_state, device_id):
        """Saves `new_state`, posts the matching full map and restarts Sunshine. When Sunshine cannot
        restart (a stream began meanwhile, or it failed) the previous map and state are put back."""
        previous = self._store_provider().get(SETTINGS_SECTION, None)
        state = self.state()
        current = _without_meta(current)
        was_active = self._active(state)
        saved = state.get("savedSunshineConfig") if isinstance(state.get("savedSunshineConfig"), dict) else None
        # The map from before Orbit's first change; unknown (None) only if settings.json was lost.
        original = saved if was_active else current
        fill = self.fill_state(new_state)
        second = self.second_state(new_state)
        overrides = {}
        if fill["enabled"]:
            overrides.update(_fill_overrides(fill["onlyDisplay"], device_id))
        if second["active"]:
            overrides.update(_second_screen_overrides(device_id))
        target = merge_sunshine_config(current, original, overrides)
        now_active = fill["enabled"] or second["active"]
        updated = copy.deepcopy(new_state)
        updated["version"] = 1
        updated["outputName"] = device_id if now_active else None
        if now_active:
            updated["savedSunshineConfig"] = copy.deepcopy(original)
            updated["savedAt"] = (state.get("savedAt") if was_active else None) or utc_now_iso()
        else:
            updated["savedSunshineConfig"] = None
            updated["savedAt"] = None
        if target == current:
            self._save_state(updated)
            return {"changed": False, "restarted": False, "sunshineReady": True}
        self._require_idle()
        updated["lastSunshineConfig"] = copy.deepcopy(current)
        updated["lastChangedAt"] = utc_now_iso()
        # Saved before Sunshine changes, so the previous map survives even a crash right now.
        self._save_state(updated)
        try:
            self.sunshine.save_config(target)
        except DisplaySetupError:
            self._rollback_state(previous)
            raise
        try:
            ready = self._restart_sunshine()
        except DisplaySetupError as error:
            try:
                self.sunshine.save_config(current)
            except DisplaySetupError:
                LOGGER.error("Could not put Sunshine's previous settings back after a failed restart")
                raise DisplaySetupError(502, "Sunshine took the new settings but could not restart, and Orbit could "
                                             "not put the previous settings back. Restart Sunshine on the PC.") from error
            self._rollback_state(previous)
            raise
        return {"changed": True, "restarted": True, "sunshineReady": ready}

    def _current_config(self):
        current, version = self.sunshine.config()
        if sunshine_supports_display_settings(version) is False:
            raise DisplaySetupError(409, SUNSHINE_TOO_OLD)
        return current

    def set_fill(self, enabled, only_display=False):
        self._begin()
        try:
            current = self._current_config()
            state = self.state()
            new_state = copy.deepcopy(state)
            new_state["fill"] = {"enabled": bool(enabled), "onlyDisplay": bool(enabled and only_display)}
            warning = None
            device_id = None
            if self.second_state(state)["active"]:
                device_id, warning = self._device_id_in_use(state, current)
            if enabled and not valid_device_id(device_id):
                virtual = self.virtual_display()
                if virtual.driver == "vdd" and virtual.device_status != "disabled":
                    found, reason, restarted = self._resolve_device_id(virtual)
                    if found:
                        device_id, warning = found, None
                    else:
                        warning = warning or reason
                    if restarted:
                        current = self._current_config()
                elif virtual.driver == "vdd":
                    warning = VDD_DISABLED
                else:
                    warning = NO_VDD_WARNING
            result = self._apply_sunshine(current, new_state, device_id)
            result["warning"] = warning
            return result
        finally:
            self._operation.release()

    def set_second_screen(self, enabled, width=None, height=None, refresh=60, position="right"):
        self._begin()
        try:
            if not enabled:
                return self._second_screen_off()
            current = self._current_config()
            state = self.state()
            new_state = copy.deepcopy(state)
            virtual = self.virtual_display()
            if virtual.driver == "vdd" and virtual.device_status == "disabled":
                raise DisplaySetupError(409, VDD_DISABLED)
            mode = self._ensure_mode_locked(width, height, refresh, virtual)
            device_id, reason, restarted = self._resolve_device_id(self.virtual_display())
            if device_id is None:
                raise DisplaySetupError(409, reason or VDD_NOT_IN_SUNSHINE)
            if restarted:
                current = self._current_config()
            new_state["secondScreen"] = {"active": True, "position": position, "width": width, "height": height,
                                         "refreshRate": refresh}
            result = self._apply_sunshine(current, new_state, device_id)
            placement = self._place(position)
            self._ensure_placer(position)
            hint = None
            if placement == "pending":
                hint = PENDING_HINT.format(side=position)
            elif placement == "manual":
                hint = PLACEMENT_HINT.format(side=position)
            return {**result, "placement": placement, "placementHint": hint, "modes": mode["modes"],
                    "reload": mode["reload"], "elevated": mode["elevated"]}
        finally:
            self._operation.release()

    def _second_screen_off(self):
        state = self.state()
        second = self.second_state(state)
        if not second["active"]:
            # Already off (a defensive "Stop" from the app): Sunshine is not asked or changed at all.
            self._stop_placer()
            return {"changed": False, "restarted": False, "sunshineReady": None, "warning": None,
                    "placement": None, "placementHint": None}
        current = self._current_config()
        new_state = copy.deepcopy(state)
        new_state["secondScreen"] = {**second, "active": False}
        device_id, warning = None, None
        if self.fill_state(state)["enabled"]:
            device_id, warning = self._device_id_in_use(state, current)
        result = self._apply_sunshine(current, new_state, device_id)
        self._stop_placer()
        return {**result, "warning": warning, "placement": None, "placementHint": None}

    def revert(self):
        """Turns full-screen streaming and the second screen off and puts Orbit's keys back."""
        self._begin()
        try:
            current = self._current_config()
            state = self.state()
            new_state = copy.deepcopy(state)
            new_state["fill"] = {"enabled": False, "onlyDisplay": False}
            new_state["secondScreen"] = {**self.second_state(state), "active": False}
            result = self._apply_sunshine(current, new_state, None)
            self._stop_placer()
            return result
        finally:
            self._operation.release()

    # the driver's screen sizes ------------------------------------------------------------------

    def _staging_path(self):
        if self._staging_directory is not None:
            folder = Path(self._staging_directory)
        else:
            from orbit_tls import data_directory
            folder = data_directory() / "display"
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        return folder / f"vdd_settings-{secrets.token_hex(6)}.xml"

    def _elevated_apply(self, path, new_data, instances):
        """One UAC prompt: saves `new_data` (when given) to `path` and restarts the driver instances.
        Raises DisplaySetupError; its `kind` says why for the cases where the helper changed nothing
        on purpose (declined, timeout, busy, stream, streamUnknown)."""
        staged = None
        try:
            if new_data is not None:
                try:
                    staged = self._staging_path()
                    staged.write_bytes(new_data)
                except OSError as error:
                    LOGGER.error("Could not stage the Virtual Display Driver settings", exc_info=True)
                    raise DisplaySetupError(503, STAGING_FAILED) from error
            script = build_helper_script(str(staged) if staged else None, str(path) if staged else None,
                                         hashlib.sha256(new_data).hexdigest() if new_data is not None else None,
                                         instances, not_after=time.time() + PROMPT_WAIT_SECONDS,
                                         base_port=int(self._base_port()), sunshine_pids=self._sunshine_pids())
            try:
                code = self.platform.run_elevated(script)
            except ElevationDeclined as error:
                raise DisplaySetupError(409, UAC_DECLINED, kind="declined") from error
            except ElevationTimedOut as error:
                raise DisplaySetupError(409, PROMPT_TIMEOUT, kind="timeout") from error
            except ElevationBusy as error:
                raise DisplaySetupError(409, PROMPT_STILL_OPEN, kind="busy") from error
            except ElevationFailed as error:
                raise DisplaySetupError(503, str(error)) from error
            except OSError as error:
                raise DisplaySetupError(503, "Windows could not start the administrator helper.") from error
            if code != 0:
                detail = HELPER_FAILURES.get(code, f"The administrator helper failed (code {code}).")
                raise DisplaySetupError(409 if code in HELPER_CONFLICTS else 503, detail, kind=HELPER_CONFLICTS.get(code))
        finally:
            if staged is not None:
                try:
                    staged.unlink()
                except OSError:
                    pass

    def _driver_stuck(self, virtual):
        try:
            return any(self.platform.device_status(instance) == "problem" for instance in virtual.instances)
        except Exception:
            return False

    def _reload_took(self, virtual, width, height, refresh):
        """After RELOAD_DRIVER: the driver still runs and Windows lists the new size for the virtual
        display, whether it is on the desktop or not (Sunshine's ensure_* options keep it off the
        desktop between streams)."""
        if self._driver_stuck(virtual):
            return False
        try:
            vdd = next((display for display in self.platform.list_displays() if display.vdd), None)
            return vdd is not None and bool(self.platform.display_offers_mode(vdd.name, width, height, refresh))
        except Exception:
            return False

    _NOT_RESTARTED = {
        "declined": "The administrator prompt on the PC was declined, so the Virtual Display Driver was not restarted.",
        "timeout": ("Nobody approved the administrator prompt on the PC in time, so the Virtual Display Driver was not "
                    "restarted."),
        "busy": PROMPT_STILL_OPEN,
        "stream": ("A stream started, or an app was running in Sunshine, before the administrator prompt was approved, "
                   "so the Virtual Display Driver was not restarted."),
        "streamUnknown": "Orbit could not check whether a stream was running, so the Virtual Display Driver was not restarted.",
    }

    def _kept_after_reload(self, error, virtual):
        """The answer when RELOAD_DRIVER reached the driver but the restart through UAC did not happen:
        the new file stays (adding sizes is harmless, and the driver may already use it)."""
        detail = self._NOT_RESTARTED.get(error.kind, "Windows could not restart the Virtual Display Driver.")
        detail += " " + KEPT_NEW_SIZE
        if self._driver_stuck(virtual):
            detail += " " + DRIVER_STUCK
        return DisplaySetupError(error.status, detail, kind=error.kind)

    def _ensure_mode_locked(self, width, height, refresh, virtual=None):
        virtual = virtual or self.virtual_display()
        if virtual.driver != "vdd":
            raise DisplaySetupError(409, SUDOVDA_ONLY if virtual.driver == "sudovda" else VDD_MISSING)
        if virtual.settings_error:
            raise DisplaySetupError(409, virtual.settings_error)
        if not virtual.settings_exists or virtual.settings_path is None:
            raise DisplaySetupError(409, f"The Virtual Display Driver's settings file was not found "
                                         f"({virtual.settings_path}). Reinstall the driver with: {VDD_INSTALL_COMMAND}")
        path = virtual.settings_path
        try:
            old_data = self.platform.read_file(path)
            new_data, after = plan_vdd_modes(old_data, width, height, refresh)
        except ValueError as error:
            raise DisplaySetupError(409, str(error)) from error
        except OSError as error:
            raise DisplaySetupError(503, "Orbit could not read the Virtual Display Driver settings file.") from error
        result = {"changed": False, "reload": "notNeeded", "elevated": False, "modes": after.mode_strings()}
        if new_data is None:
            return result
        if not self._desktop_available():
            raise DisplaySetupError(409, SIGN_IN_FIRST)
        self._require_idle()
        restartable = virtual.restartable_instances()
        try:
            self.platform.write_file_as_user(path, new_data)
        except NeedsElevation:
            self._elevated_apply(path, new_data, restartable)
            result.update(changed=True, reload="driverRestart" if restartable else "nextStart", elevated=True)
            return result
        except OSError as error:
            raise DisplaySetupError(503, "Orbit could not save the Virtual Display Driver settings file.") from error
        result["changed"] = True
        if not restartable:
            result["reload"] = "nextStart"
            return result
        pipe_sent = False
        try:
            self.platform.send_pipe_command("RELOAD_DRIVER")
            pipe_sent = True
            self._sleep(1.0)
            if self._reload_took(virtual, width, height, refresh):
                result["reload"] = "pipe"
                return result
        except OSError:
            LOGGER.info("The Virtual Display Driver's pipe did not take RELOAD_DRIVER; restarting the device instead")
        try:
            self._elevated_apply(path, None, restartable)
        except DisplaySetupError as error:
            if pipe_sent:
                raise self._kept_after_reload(error, virtual) from error
            # Nothing half-applied: the driver never saw the new file, so put the previous one back.
            try:
                self.platform.write_file_as_user(path, old_data)
            except (NeedsElevation, OSError):
                LOGGER.error("Could not restore the previous Virtual Display Driver settings")
            raise
        result.update(reload="driverRestart", elevated=True)
        return result

    def ensure_mode(self, width, height, refresh):
        self._begin()
        try:
            return self._ensure_mode_locked(width, height, refresh)
        finally:
            self._operation.release()

    # placing the second screen ------------------------------------------------------------------

    @staticmethod
    def placement_target(displays, position):
        """(virtual display, x, y, already on that side) or None when it is not on the desktop."""
        vdd = next((display for display in displays if display.vdd and display.attached), None)
        others = [display for display in displays if display.attached and not display.vdd]
        if vdd is None or not others:
            return None
        primary = next((display for display in others if display.primary), others[0])
        if position == "left":
            edge = min(display.x for display in others)
            return vdd, edge - vdd.width, primary.y, vdd.x + vdd.width <= edge
        edge = max(display.x + display.width for display in others)
        return vdd, edge, primary.y, vdd.x >= edge

    def _place(self, position):
        """done | pending (the virtual display is not on the desktop yet) | manual."""
        if not self._desktop_available():
            return "pending"
        try:
            target = self.placement_target(self.platform.list_displays(), position)
        except Exception:
            LOGGER.debug("Could not list displays", exc_info=True)
            return "manual"
        if target is None:
            return "pending"
        vdd, x, y, there = target
        if there:
            return "done"
        try:
            moved = self.platform.move_display(vdd.name, x, y)
        except Exception:
            LOGGER.warning("Could not move the virtual display", exc_info=True)
            moved = False
        return "done" if moved and self._placement_now(position) == "done" else "manual"

    def _ensure_placer(self, position):
        if not self._start_placer or not self._desktop_available():
            return
        with self._placer_lock:
            # Read again under the lock: a status() that read the state before a concurrent
            # "second screen off" finished must not start a placer that outlives the feature.
            second = self.second_state(self.state())
            if not second["active"]:
                return
            position = second["position"] or position
            if self._placer is not None and self._placer.is_alive():
                self._placer.position = position
                return
            self._placer = _Placer(self, position)
            self._placer.start()

    def _stop_placer(self):
        with self._placer_lock:
            placer, self._placer = self._placer, None
        if placer is not None:
            placer.stop()

    def close(self):
        self._stop_placer()


class _Placer(threading.Thread):
    """While the second screen is on: when Sunshine puts the virtual display on the desktop at the
    start of a stream, move it to the chosen side (a few tries per activation, never fighting the
    user's own arrangement afterwards). It ends by itself once the saved state says the second
    screen is off, so it never moves the display during fill streams afterwards."""

    INTERVAL = 3.0
    TRIES_PER_ACTIVATION = 3

    def __init__(self, service, position):
        super().__init__(name="orbit-second-screen", daemon=True)
        self.service = service
        self.position = position
        self._stop_event = threading.Event()

    def stop(self):
        self._stop_event.set()

    def run(self):
        tries = 0
        while not self._stop_event.wait(self.INTERVAL):
            try:
                second = self.service.second_state(self.service.state())
            except Exception:
                continue
            if not second["active"]:
                return
            position = second["position"] or self.position or "right"
            if position != self.position:
                self.position, tries = position, 0
            try:
                target = self.service.placement_target(self.service.platform.list_displays(), self.position)
            except Exception:
                continue
            if target is None:
                tries = 0  # not on the desktop: the next activation gets fresh tries
                continue
            if target[3] or tries >= self.TRIES_PER_ACTIVATION:
                continue
            tries += 1
            try:
                self.service.platform.move_display(target[0].name, target[1], target[2])
            except Exception:
                LOGGER.debug("Could not move the virtual display", exc_info=True)


# -- routes -----------------------------------------------------------------------------------

class FillBody(BaseModel):
    model_config = ConfigDict(extra="ignore")
    enabled: bool
    onlyDisplay: bool = False


class ModeBody(BaseModel):
    model_config = ConfigDict(extra="ignore")
    width: int = Field(ge=640, le=7680)
    height: int = Field(ge=480, le=4320)
    refreshRate: int = Field(default=60, ge=24, le=500)


class SecondScreenBody(BaseModel):
    model_config = ConfigDict(extra="ignore")
    enabled: bool
    width: int | None = Field(default=None, ge=640, le=7680)
    height: int | None = Field(default=None, ge=480, le=4320)
    refreshRate: int = Field(default=60, ge=24, le=500)
    position: Literal["left", "right"] = "right"

    @model_validator(mode="after")
    def size_when_enabling(self):
        if self.enabled and (self.width is None or self.height is None):
            raise ValueError("Send the screen's width and height in pixels to turn the second screen on.")
        return self


ACTION_DEFAULTS = {"changed": False, "restarted": False, "sunshineReady": None, "warning": None}


def create_stream_display_router(verify_control, require_secure, service, require_windows=None):
    """Routes under /api/stream/display: main token, HTTPS only. `require_windows()` (501 off
    Windows) guards the routes that change something; reading the status works everywhere."""
    router = APIRouter(prefix="/api/stream/display", dependencies=[Depends(verify_control), Depends(require_secure)])
    windows_only = require_windows or (lambda: None)

    def run(operation):
        try:
            return operation()
        except DisplaySetupError as error:
            raise HTTPException(status_code=error.status, detail=error.detail) from error
        except OSError as error:
            # Every expected failure is a DisplaySetupError; this keeps an unexpected Windows error
            # a plain sentence instead of a 500 with a traceback.
            LOGGER.exception("Display setup failed with a Windows error")
            raise HTTPException(status_code=503, detail="Windows refused a step of the display setup. "
                                                        "Try again in a moment.") from error

    def respond(result):
        return {**ACTION_DEFAULTS, **result, "display": run(service.status)}

    @router.get("")
    def get_display():
        return run(service.status)

    @router.post("/fill")
    def post_fill(body: FillBody):
        windows_only()
        return respond(run(lambda: service.set_fill(body.enabled, body.onlyDisplay)))

    @router.post("/modes")
    def post_modes(body: ModeBody):
        windows_only()
        return respond(run(lambda: service.ensure_mode(body.width, body.height, body.refreshRate)))

    @router.post("/second-screen")
    def post_second_screen(body: SecondScreenBody):
        windows_only()
        return respond(run(lambda: service.set_second_screen(body.enabled, body.width, body.height,
                                                             body.refreshRate, body.position)))

    @router.post("/revert")
    def post_revert():
        windows_only()
        return respond(run(service.revert))

    return router


# -- tray: "Set up full-screen streaming…" ------------------------------------------------------

TRAY_TITLE = "Orbit · Full-screen streaming"
TRAY_MENU_LABEL = "Set up full-screen streaming…"


def tray_setup_text(virtual=None):
    if virtual is None:
        try:
            virtual = detect_virtual_display(WindowsDisplayPlatform())
        except Exception:
            virtual = VirtualDisplayInfo()
    if virtual.driver == "vdd":
        driver_line = "Virtual Display Driver on this PC: installed."
    elif virtual.driver == "sudovda":
        driver_line = "Virtual Display Driver on this PC: not found (SudoVDA from Apollo is installed instead)."
    else:
        driver_line = "Virtual Display Driver on this PC: not found."
    return (
        "Full-screen streaming lets Orbit stream at the exact shape of your iPhone, iPad or Mac screen, "
        "without black bars. The same driver can also make your iPad or Mac a second screen for this PC.\n\n"
        "1. Install the free Virtual Display Driver (an extra, invisible monitor) from Terminal:\n"
        f"    {VDD_INSTALL_COMMAND}\n\n"
        "2. In Orbit, save your Sunshine web UI login, then choose Fill Screen.\n\n"
        "What Orbit changes in Sunshine: output_name (stream the virtual display), dd_configuration_option "
        "(make it the main display, or the only one), and dd_resolution_option and dd_refresh_rate_option "
        "(auto, so each stream gets your device's size). Orbit saves your previous Sunshine settings first and "
        "puts them back when you turn the feature off. Sunshine restarts to use them, but never while someone is "
        "streaming or an app is still running in it. Adding a new screen size can ask for administrator permission "
        "once.\n\n"
        f"{driver_line}\n\n"
        "Copy the install command to the clipboard?"
    )


def run_tray_setup_dialog(show_message_box, notify=None, copy_text=None, virtual=None):
    """Shows the explanation; Yes copies the winget command. `show_message_box(text, title, flags)`
    returns the button pressed, like MessageBoxW."""
    choice = show_message_box(tray_setup_text(virtual), TRAY_TITLE, 0x00040044)  # MB_YESNO | MB_ICONINFORMATION | MB_TOPMOST
    if choice != 6:  # IDYES
        return False
    try:
        if copy_text is None:
            from orbit_desktop import WindowsClipboard
            WindowsClipboard().write(VDD_INSTALL_COMMAND)
        else:
            copy_text(VDD_INSTALL_COMMAND)
    except Exception:
        LOGGER.exception("Could not copy the Virtual Display Driver install command")
        show_message_box("Orbit could not copy the command. Type it in Terminal:\n\n" + VDD_INSTALL_COMMAND,
                         TRAY_TITLE, 0x00040030)
        return False
    if notify is not None:
        notify("Install command copied", "Paste it into Terminal on this PC to install the Virtual Display Driver.")
    return True
