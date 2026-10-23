"""Windows System Tray (Notification Area) icon, menu, and startup registration."""
import ctypes
from ctypes import wintypes
import io
import logging
import math
import os
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import threading

from orbit_notify import fit_utf16
from orbit_tls import data_directory

LOGGER = logging.getLogger("orbit.tray")

RUN_REGISTRY_PATH = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "OrbitPCCompanion"
ICON_PATH = Path(__file__).resolve().with_name("orbit.ico")
MAX_LOG_BYTES = 2 * 1024 * 1024

WM_DESTROY = 0x0002
WM_CLOSE = 0x0010
WM_QUIT = 0x0012
WM_SETICON = 0x0080
WM_COMMAND = 0x0111
WM_LBUTTONUP = 0x0202
WM_LBUTTONDBLCLK = 0x0203
WM_RBUTTONUP = 0x0205
WM_CONTEXTMENU = 0x007B
WM_USER = 0x0400
WM_TRAYICON = WM_USER + 20
NIN_SELECT = WM_USER + 0
NIN_KEYSELECT = WM_USER + 1
NIN_BALLOONUSERCLICK = WM_USER + 5

NIM_ADD = 0x00000000
NIM_MODIFY = 0x00000001
NIM_DELETE = 0x00000002

NIF_MESSAGE = 0x00000001
NIF_ICON = 0x00000002
NIF_TIP = 0x00000004
NIF_INFO = 0x00000010

NIIF_INFO = 0x00000001
NIIF_NOSOUND = 0x00000010

IMAGE_ICON = 1
LR_LOADFROMFILE = 0x00000010
LR_DEFAULTSIZE = 0x00000040

SM_CXICON = 11
SM_CYICON = 12
SM_CXSMICON = 49
SM_CYSMICON = 50
ICON_SMALL = 0
ICON_BIG = 1

SW_HIDE = 0
SW_SHOW = 5
SW_RESTORE = 9

MF_STRING = 0x00000000
MF_GRAYED = 0x00000001
MF_DISABLED = 0x00000002
MF_CHECKED = 0x00000008
MF_UNCHECKED = 0x00000000
MF_SEPARATOR = 0x00000800

TPM_RIGHTBUTTON = 0x0002
TPM_NONOTIFY = 0x0080
TPM_RETURNCMD = 0x0100

ID_TOGGLE_STARTUP = 1001
ID_TOGGLE_CONSOLE = 1002
ID_SHOW_DETAILS = 1003
ID_COPY_TOKEN = 1004
ID_OPEN_LOG = 1005
ID_EXIT = 1006
ID_CHECK_UPDATES = 1007
ID_TOGGLE_BOOT = 1008

BOOT_TASK_NAME = "Orbit PC Companion (boot)"

IDYES = 6
IDNO = 7


class _GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", wintypes.DWORD),
        ("Data2", wintypes.WORD),
        ("Data3", wintypes.WORD),
        ("Data4", wintypes.BYTE * 8),
    ]


class NOTIFYICONDATAW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("hWnd", wintypes.HWND),
        ("uID", wintypes.UINT),
        ("uFlags", wintypes.UINT),
        ("uCallbackMessage", wintypes.UINT),
        ("hIcon", wintypes.HICON),
        ("szTip", wintypes.WCHAR * 128),
        ("dwState", wintypes.DWORD),
        ("dwStateMask", wintypes.DWORD),
        ("szInfo", wintypes.WCHAR * 256),
        ("uTimeoutOrVersion", wintypes.UINT),
        ("szInfoTitle", wintypes.WCHAR * 64),
        ("dwInfoFlags", wintypes.DWORD),
        ("guidItem", _GUID),
        ("hBalloonIcon", wintypes.HICON),
    ]


WNDPROC = (
    ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
    if hasattr(ctypes, "WINFUNCTYPE")
    else ctypes.CFUNCTYPE(ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
)


class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.UINT),
        ("style", wintypes.UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", wintypes.HINSTANCE),
        ("hIcon", wintypes.HICON),
        ("hCursor", wintypes.HANDLE),
        ("hbrBackground", wintypes.HBRUSH),
        ("lpszMenuName", wintypes.LPCWSTR),
        ("lpszClassName", wintypes.LPCWSTR),
        ("hIconSm", wintypes.HICON),
    ]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class MSG(ctypes.Structure):
    _fields_ = [
        ("hwnd", wintypes.HWND),
        ("message", wintypes.UINT),
        ("wParam", wintypes.WPARAM),
        ("lParam", wintypes.LPARAM),
        ("time", wintypes.DWORD),
        ("pt", POINT),
    ]


def build_windows_ico(base_rgba, sizes=(16, 20, 24, 32, 40, 48, 64, 256)):
    """Build a spec-compliant Windows .ico with 32-bit BGRA DIBs and 256px PNG."""
    from PIL import Image

    entries = []
    payloads = []
    for sz in sizes:
        frame = base_rgba.resize((sz, sz), Image.Resampling.LANCZOS).convert("RGBA")
        if sz == 256:
            buf = io.BytesIO()
            frame.save(buf, format="PNG")
            data = buf.getvalue()
        else:
            flipped = frame.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            raw_bgra = flipped.tobytes("raw", "BGRA")
            row_bytes = ((sz + 31) // 32) * 4
            and_mask = bytearray(row_bytes * sz)
            alpha = flipped.getchannel("A").tobytes()
            for y in range(sz):
                for x in range(sz):
                    if alpha[y * sz + x] == 0:
                        and_mask[y * row_bytes + (x >> 3)] |= (0x80 >> (x & 7))
            bih = struct.pack("<IIIHHIIIIII", 40, sz, sz * 2, 1, 32, 0, len(raw_bgra) + len(and_mask), 0, 0, 0, 0)
            data = bih + raw_bgra + bytes(and_mask)
        entries.append((0 if sz == 256 else sz, 0 if sz == 256 else sz, 0, 0, 1, 32, len(data)))
        payloads.append(data)
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory = bytearray()
    for w, h, colors, res, planes, bpp, size in entries:
        directory.extend(struct.pack("<BBBBHHII", w, h, colors, res, planes, bpp, size, offset))
        offset += size
    return header + bytes(directory) + b"".join(payloads)


def render_default_icon(size=256):
    """Render the Orbit planet, glowing cyan orbital ring, and satellite moon."""
    from PIL import Image, ImageDraw

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    margin = max(2, int(size * 0.02))
    radius = int(size * 0.23)
    draw.rounded_rectangle(
        (margin, margin, size - 1 - margin, size - 1 - margin),
        radius=radius,
        fill=(4, 15, 42, 255),
        outline=(87, 200, 255, 160),
        width=max(2, int(size * 0.025)),
    )
    center = size / 2.0
    planet_r = size * 0.21
    draw.ellipse(
        (center - planet_r, center - planet_r, center + planet_r, center + planet_r),
        fill=(10, 38, 92, 255),
        outline=(72, 190, 255, 235),
        width=max(2, int(size * 0.025)),
    )
    highlight_r = planet_r * 0.55
    draw.ellipse(
        (center - planet_r * 0.55, center - planet_r * 0.65,
         center - planet_r * 0.55 + highlight_r, center - planet_r * 0.65 + highlight_r * 0.7),
        fill=(145, 225, 255, 150),
    )
    rx, ry = size * 0.38, size * 0.19
    tilt = -math.pi / 6.5
    cos_t, sin_t = math.cos(tilt), math.sin(tilt)
    points = []
    for step in range(96):
        angle = 2 * math.pi * step / 96
        px = rx * math.cos(angle)
        py = ry * math.sin(angle)
        x = center + px * cos_t - py * sin_t
        y = center + px * sin_t + py * cos_t
        points.append((x, y))
    points.append(points[0])
    draw.line(points, fill=(95, 215, 255, 255), width=max(3, int(size * 0.045)), joint="curve")
    moon_angle = -math.pi / 5.5
    mx = rx * math.cos(moon_angle)
    my = ry * math.sin(moon_angle)
    moon_x = center + mx * cos_t - my * sin_t
    moon_y = center + mx * sin_t + my * cos_t
    moon_r = max(3.0, size * 0.06)
    draw.ellipse(
        (moon_x - moon_r, moon_y - moon_r, moon_x + moon_r, moon_y + moon_r),
        fill=(225, 252, 255, 255),
        outline=(87, 200, 255, 255),
        width=max(1, int(size * 0.015)),
    )
    return canvas


def ensure_icon_file(path=ICON_PATH, fallback_directory=None):
    """Return the bundled orbit.ico or generate a fallback .ico file if missing."""
    target = Path(path)
    if target.is_file() and target.stat().st_size > 64:
        return target
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        bundled = Path(meipass) / "orbit.ico"
        if bundled.is_file() and bundled.stat().st_size > 64:
            return bundled
    fallback_dir = Path(fallback_directory) if fallback_directory is not None else data_directory()
    fallback_dir.mkdir(parents=True, exist_ok=True)
    generated = fallback_dir / "orbit.ico"
    if not generated.is_file() or generated.stat().st_size <= 64:
        ico_bytes = build_windows_ico(render_default_icon(256))
        generated.write_bytes(ico_bytes)
    return generated


def resolve_pythonw_executable(script_path=None, python_executable=None):
    """Prefer the private venv's pythonw.exe so Windows startup runs without a console."""
    script = Path(script_path).resolve() if script_path is not None else Path(__file__).resolve().with_name("orbit_agent.py")
    candidates = [
        script.parent / ".venv" / "Scripts" / "pythonw.exe",
        script.parent / ".venv" / "Scripts" / "python.exe",
    ]
    current = Path(python_executable or sys.executable)
    if current.name.lower() == "python.exe":
        candidates.insert(1, current.with_name("pythonw.exe"))
    candidates.append(current)
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return current


class BootTaskManager:
    """Scheduled task that starts the companion when Windows boots, before anyone signs in.

    The task runs under the user's own account with the S4U logon type (no password stored,
    same %LOCALAPPDATA%, so the TLS identity and history are the ones the phone already trusts)
    and the ``--boot`` flag: no tray icon, and it hands the ports over to the normal tray
    instance as soon as the user signs in. Creating or removing the task needs administrator
    rights, so those run through a UAC-elevated PowerShell.
    """

    def __init__(self, script_path=None, python_executable=None, frozen_executable=None, runner=None,
                 elevated_runner=None, task_name=BOOT_TASK_NAME, user_name=None):
        self.script_path = Path(script_path).resolve() if script_path is not None else Path(__file__).resolve().with_name("orbit_agent.py")
        self.python_executable = python_executable
        self.frozen_executable = (
            Path(frozen_executable).resolve()
            if frozen_executable is not None
            else (Path(sys.executable).resolve() if getattr(sys, "frozen", False) else None)
        )
        self.task_name = task_name
        self.runner = runner or self._run
        self.elevated_runner = elevated_runner or self._run_elevated
        self.user_name = user_name or self._current_user()

    @staticmethod
    def _current_user():
        domain = os.environ.get("USERDOMAIN") or os.environ.get("COMPUTERNAME") or "."
        user = os.environ.get("USERNAME") or ""
        return f"{domain}\\{user}" if user else ""

    @staticmethod
    def _run(arguments):
        return subprocess.run(arguments, capture_output=True, text=True, creationflags=0x08000000 if os.name == "nt" else 0).returncode

    @staticmethod
    def _run_elevated(executable, parameters):
        if os.name != "nt":
            raise RuntimeError("The boot task can only be configured on Windows.")
        result = ctypes.windll.shell32.ShellExecuteW(None, "runas", executable, parameters, None, 0)
        if result <= 32:
            raise RuntimeError("Windows did not grant administrator rights (ShellExecute %s)." % result)
        return result

    def executable_and_arguments(self):
        if self.frozen_executable is not None:
            return str(self.frozen_executable), "--boot"
        executable = resolve_pythonw_executable(self.script_path, self.python_executable)
        return str(executable), f'"{self.script_path}" --boot'

    def is_installed(self):
        try:
            return self.runner(["schtasks", "/Query", "/TN", self.task_name]) == 0
        except OSError:
            return False

    def register_script(self):
        executable, arguments = self.executable_and_arguments()
        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"
        return (
            f"$action = New-ScheduledTaskAction -Execute {quote(executable)} -Argument {quote(arguments)} -WorkingDirectory {quote(self.script_path.parent)}; "
            "$trigger = New-ScheduledTaskTrigger -AtStartup; $trigger.Delay = 'PT20S'; "
            f"$principal = New-ScheduledTaskPrincipal -UserId {quote(self.user_name)} -LogonType S4U -RunLevel Highest; "
            "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable "
            "-ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1); "
            f"Register-ScheduledTask -TaskName {quote(self.task_name)} -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null"
        )

    def unregister_script(self):
        return f"Unregister-ScheduledTask -TaskName '{self.task_name}' -Confirm:$false"

    @staticmethod
    def powershell_parameters(script):
        return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + script.replace('"', '\\"') + '"'

    def set_installed(self, enabled):
        if enabled and not self.user_name:
            raise RuntimeError("Could not determine the Windows user name for the boot task.")
        script = self.register_script() if enabled else self.unregister_script()
        self.elevated_runner("powershell.exe", self.powershell_parameters(script))
        return enabled

    def toggle(self):
        return self.set_installed(not self.is_installed())


class StartupManager:
    """Manage per-user Windows login startup under HKCU\\...\\CurrentVersion\\Run."""

    def __init__(self, script_path=None, python_executable=None, registry=None,
                 value_name=RUN_VALUE_NAME, key_path=RUN_REGISTRY_PATH, frozen_executable=None):
        self.script_path = Path(script_path).resolve() if script_path is not None else Path(__file__).resolve().with_name("orbit_agent.py")
        self.python_executable = python_executable
        self.frozen_executable = (
            Path(frozen_executable).resolve()
            if frozen_executable is not None
            else (Path(sys.executable).resolve() if getattr(sys, "frozen", False) else None)
        )
        self.value_name = value_name
        self.key_path = key_path
        if registry is None and os.name == "nt":
            import winreg
            registry = winreg
        self.registry = registry

    def startup_command(self):
        if self.frozen_executable is not None:
            return f'"{self.frozen_executable}" --background'
        executable = resolve_pythonw_executable(self.script_path, self.python_executable)
        return f'"{executable}" "{self.script_path}" --background'

    def is_enabled(self):
        if self.registry is None:
            return False
        try:
            with self.registry.OpenKey(
                self.registry.HKEY_CURRENT_USER,
                self.key_path,
                0,
                self.registry.KEY_READ,
            ) as key:
                value, reg_type = self.registry.QueryValueEx(key, self.value_name)
        except FileNotFoundError:
            return False
        except OSError:
            return False
        if reg_type != self.registry.REG_SZ or not isinstance(value, str) or not value.strip():
            return False
        lowered = value.casefold()
        if self.frozen_executable is not None and str(self.frozen_executable).casefold() in lowered:
            return True
        return str(self.script_path).casefold() in lowered

    def set_enabled(self, enabled):
        if self.registry is None:
            raise RuntimeError("Windows startup configuration requires Windows.")
        with self.registry.CreateKeyEx(
            self.registry.HKEY_CURRENT_USER,
            self.key_path,
            0,
            self.registry.KEY_SET_VALUE | self.registry.KEY_READ,
        ) as key:
            if enabled:
                self.registry.SetValueEx(key, self.value_name, 0, self.registry.REG_SZ, self.startup_command())
            else:
                try:
                    self.registry.DeleteValue(key, self.value_name)
                except FileNotFoundError:
                    pass
        return self.is_enabled()

    def toggle(self):
        return self.set_enabled(not self.is_enabled())

    def sync_if_enabled(self):
        if self.is_enabled():
            return self.set_enabled(True)
        return False


def default_log_path():
    return data_directory() / "agent.log"


def ensure_background_stdio(log_path=None):
    """Redirect missing stdio handles under pythonw.exe to a bounded log file."""
    if sys.stdout is not None and sys.stderr is not None:
        return None
    target = Path(log_path) if log_path is not None else default_log_path()
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_file() and target.stat().st_size > MAX_LOG_BYTES:
            backup = target.with_suffix(".old.log")
            target.replace(backup)
        stream = open(target, "a", encoding="utf-8", buffering=1)
    except OSError:
        stream = open(os.devnull, "w", encoding="utf-8")
    if sys.stdout is None:
        sys.stdout = stream
    if sys.stderr is None:
        sys.stderr = stream
    return target


def _win32_apis():
    if os.name != "nt":
        raise RuntimeError("System tray requires Windows.")
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    definitions = (
        (user32.RegisterClassExW, [ctypes.POINTER(WNDCLASSEXW)], wintypes.ATOM),
        (user32.UnregisterClassW, [wintypes.LPCWSTR, wintypes.HINSTANCE], wintypes.BOOL),
        (user32.CreateWindowExW, [
            wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
            ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, ctypes.c_void_p,
        ], wintypes.HWND),
        (user32.DestroyWindow, [wintypes.HWND], wintypes.BOOL),
        (user32.DefWindowProcW, [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], ctypes.c_ssize_t),
        (user32.GetMessageW, [ctypes.POINTER(MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT], wintypes.BOOL),
        (user32.TranslateMessage, [ctypes.POINTER(MSG)], wintypes.BOOL),
        (user32.DispatchMessageW, [ctypes.POINTER(MSG)], ctypes.c_ssize_t),
        (user32.PostMessageW, [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], wintypes.BOOL),
        (user32.SendMessageW, [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM], ctypes.c_ssize_t),
        (user32.PostQuitMessage, [ctypes.c_int], None),
        (user32.LoadImageW, [wintypes.HINSTANCE, wintypes.LPCWSTR, wintypes.UINT, ctypes.c_int, ctypes.c_int, wintypes.UINT], wintypes.HANDLE),
        (user32.DestroyIcon, [wintypes.HICON], wintypes.BOOL),
        (user32.GetSystemMetrics, [ctypes.c_int], ctypes.c_int),
        (user32.CreatePopupMenu, [], wintypes.HMENU),
        (user32.AppendMenuW, [wintypes.HMENU, wintypes.UINT, ctypes.c_size_t, wintypes.LPCWSTR], wintypes.BOOL),
        (user32.TrackPopupMenu, [wintypes.HMENU, wintypes.UINT, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HWND, ctypes.c_void_p], wintypes.BOOL),
        (user32.DestroyMenu, [wintypes.HMENU], wintypes.BOOL),
        (user32.SetForegroundWindow, [wintypes.HWND], wintypes.BOOL),
        (user32.GetCursorPos, [ctypes.POINTER(POINT)], wintypes.BOOL),
        (user32.RegisterWindowMessageW, [wintypes.LPCWSTR], wintypes.UINT),
        (user32.IsWindowVisible, [wintypes.HWND], wintypes.BOOL),
        (user32.ShowWindow, [wintypes.HWND, ctypes.c_int], wintypes.BOOL),
        (user32.MessageBoxW, [wintypes.HWND, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.UINT], ctypes.c_int),
        (shell32.Shell_NotifyIconW, [wintypes.DWORD, ctypes.POINTER(NOTIFYICONDATAW)], wintypes.BOOL),
        (kernel32.GetModuleHandleW, [wintypes.LPCWSTR], wintypes.HMODULE),
        (kernel32.GetConsoleWindow, [], wintypes.HWND),
    )
    for func, argtypes, restype in definitions:
        func.argtypes = argtypes
        func.restype = restype
    return user32, shell32, kernel32


class OrbitTrayIcon:
    """Windows notification-area (system tray) icon and context menu for Orbit."""

    def __init__(self, *, status_provider, on_stop, startup_manager=None,
                 token_provider=None, update_checker=None, update_installer=None,
                 release_page_opener=None, icon_path=ICON_PATH, log_path=None,
                 notify_on_start=False, apis=None, boot_task=None):
        self.status_provider = status_provider
        self.on_stop = on_stop
        self.startup = startup_manager or StartupManager()
        self.boot_task = boot_task or BootTaskManager()
        self.token_provider = token_provider
        self.update_checker = update_checker
        self.update_installer = update_installer
        self.release_page_opener = release_page_opener
        self.icon_path = Path(icon_path)
        self.log_path = Path(log_path) if log_path is not None else default_log_path()
        self.notify_on_start = bool(notify_on_start)
        self._apis = apis
        self._hwnd = None
        self._hicon_small = None
        self._hicon_big = None
        self._class_name = f"OrbitTrayWindow_{secrets.token_hex(6)}"
        self._taskbar_created_msg = 0
        self._wndproc_ref = None
        self._thread = None
        self._ready = threading.Event()
        self._closed = threading.Event()
        self._lock = threading.Lock()

    def _get_apis(self):
        if self._apis is None:
            self._apis = _win32_apis()
        return self._apis

    def has_console_window(self):
        try:
            _, _, kernel32 = self._get_apis()
            return bool(kernel32.GetConsoleWindow())
        except Exception:
            return False

    def is_console_visible(self):
        try:
            user32, _, kernel32 = self._get_apis()
            hwnd = kernel32.GetConsoleWindow()
            return bool(hwnd and user32.IsWindowVisible(hwnd))
        except Exception:
            return False

    def set_console_visible(self, visible):
        try:
            user32, _, kernel32 = self._get_apis()
            hwnd = kernel32.GetConsoleWindow()
            if not hwnd:
                return False
            user32.ShowWindow(hwnd, SW_RESTORE if visible else SW_HIDE)
            if visible:
                user32.SetForegroundWindow(hwnd)
            return bool(user32.IsWindowVisible(hwnd))
        except Exception:
            return False

    def format_tooltip(self):
        info = self.status_provider() or {}
        version = info.get("agentVersion") or "4.1.0"
        ip_address = info.get("ipAddress") or "No LAN IP"
        secure_port = info.get("securePort") or 8766
        game = info.get("activeGame")
        suffix = f" · {game}" if game else ""
        text = f"Orbit PC Companion {version} ({ip_address}:{secure_port}){suffix}"
        return fit_utf16(text, 127)  # szTip is WCHAR[128] with the terminator

    def build_menu_items(self):
        """Return ordered menu item descriptors for inspection and native rendering."""
        info = self.status_provider() or {}
        version = info.get("agentVersion") or "4.1.0"
        ip_address = info.get("ipAddress") or "No active LAN adapter"
        secure_port = info.get("securePort") or 8766
        game = info.get("activeGame")
        startup_enabled = self.startup.is_enabled()

        items = [
            {"id": 0, "label": f"Orbit PC Companion {version}", "enabled": False, "checked": False},
            {"id": 0, "label": f"IP: {ip_address} · HTTPS {secure_port}", "enabled": False, "checked": False},
            {"id": 0, "label": f"Game: {game}" if game else "Status: Online in background", "enabled": False, "checked": False},
            {"separator": True},
            {"id": ID_TOGGLE_STARTUP, "label": "Run at Windows startup", "enabled": True, "checked": startup_enabled},
            {"id": ID_TOGGLE_BOOT, "label": "Start before Windows sign-in (boot task)", "enabled": True, "checked": self.boot_task.is_installed()},
        ]
        if self.has_console_window():
            items.append({
                "id": ID_TOGGLE_CONSOLE,
                "label": "Show console window",
                "enabled": True,
                "checked": self.is_console_visible(),
            })
        items.extend([
            {"id": ID_CHECK_UPDATES, "label": "Check for updates...", "enabled": True, "checked": False},
            {"id": ID_SHOW_DETAILS, "label": "Connection details...", "enabled": True, "checked": False},
            {"id": ID_COPY_TOKEN, "label": "Copy manual pairing token", "enabled": bool(self.token_provider), "checked": False},
        ])
        if self.log_path and self.log_path.is_file():
            items.append({"id": ID_OPEN_LOG, "label": "Open agent log", "enabled": True, "checked": False})
        items.extend([
            {"separator": True},
            {"id": ID_EXIT, "label": "Stop Orbit Companion", "enabled": True, "checked": False},
        ])
        return items

    def execute_command(self, command_id):
        """Execute a tray context-menu command ID."""
        if command_id == ID_TOGGLE_STARTUP:
            try:
                enabled = self.startup.toggle()
                self.show_notification(
                    "Orbit PC Companion",
                    "Orbit will start automatically when you sign in to Windows."
                    if enabled else
                    "Automatic Windows startup has been turned off.",
                )
            except Exception as error:
                LOGGER.exception("Could not update Windows startup setting")
                self._async_message_box(
                    f"Could not update Windows startup setting:\n{error}",
                    "Orbit · Startup Setting",
                    0x00000030,
                )
            return "startup_toggled"
        if command_id == ID_TOGGLE_BOOT:
            try:
                enabled = self.boot_task.toggle()
                self.show_notification(
                    "Orbit PC Companion",
                    "Orbit will start with Windows, before anyone signs in, so your phone can connect right after power-on."
                    if enabled else
                    "The boot-time start has been removed; Orbit starts when you sign in.",
                )
            except Exception as error:
                LOGGER.exception("Could not update the boot task")
                self._async_message_box(
                    f"Could not update the boot task (administrator rights are needed):\n{error}",
                    "Orbit · Start before sign-in",
                    0x00000030,
                )
            return "boot_toggled"
        if command_id == ID_TOGGLE_CONSOLE:
            self.set_console_visible(not self.is_console_visible())
            return "console_toggled"
        if command_id == ID_CHECK_UPDATES:
            self.check_for_updates_async()
            return "update_check_started"
        if command_id == ID_SHOW_DETAILS:
            self.show_connection_details()
            return "details_shown"
        if command_id == ID_COPY_TOKEN:
            if callable(self.token_provider):
                token = self.token_provider()
                if token:
                    try:
                        from orbit_desktop import WindowsClipboard
                        WindowsClipboard().write(token)
                        self.show_notification(
                            "Orbit PC Companion",
                            "Manual pairing token copied to clipboard. Keep this token private.",
                        )
                    except Exception:
                        LOGGER.exception("Could not copy manual pairing token")
            return "token_copied"
        if command_id == ID_OPEN_LOG:
            if self.log_path and self.log_path.is_file() and os.name == "nt":
                try:
                    subprocess.Popen(["notepad.exe", str(self.log_path)], creationflags=0x08000000)
                except OSError:
                    LOGGER.exception("Could not open agent log")
            return "log_opened"
        if command_id == ID_EXIT:
            self.request_stop()
            return "stopped"
        return None

    def perform_update_check(self):
        """Run a synchronous GitHub update check and handle the interactive dialog."""
        from orbit_updater import (
            GITHUB_RELEASES_PAGE,
            check_for_updates,
            download_and_apply_update,
            open_releases_page,
        )

        info = self.status_provider() or {}
        current_version = info.get("agentVersion") or "4.1.0"
        checker = self.update_checker or check_for_updates
        installer = self.update_installer or download_and_apply_update
        opener = self.release_page_opener or open_releases_page

        try:
            result = checker(current_version)
        except Exception as error:
            LOGGER.warning("GitHub update check failed: %s", error)
            response = self._show_message_box_sync(
                f"Could not check GitHub for updates:\n{error}\n\n"
                "Would you like to open the Orbit GitHub releases page in your browser?",
                "Orbit PC Companion · Update Check",
                0x00040034,  # MB_YESNO | MB_ICONWARNING | MB_TOPMOST
            )
            if response == IDYES:
                try:
                    opener(GITHUB_RELEASES_PAGE)
                except Exception:
                    LOGGER.exception("Could not open GitHub releases page")
            return {"status": "error", "error": str(error)}

        latest_version = result.get("latestVersion") or current_version
        release_url = result.get("releaseUrl") or GITHUB_RELEASES_PAGE
        download_url = result.get("downloadUrl")
        notes = (result.get("releaseNotes") or "").strip()
        notes_preview = f"\n\nRelease notes:\n{notes[:360]}" if notes else ""

        if not result.get("updateAvailable"):
            self.show_notification(
                "Orbit PC Companion is up to date",
                f"You are running the latest public version ({current_version}).",
            )
            self._show_message_box_sync(
                f"You are running the latest public version of Orbit PC Companion ({current_version}).\n\n"
                f"GitHub Repository: github.com/{result.get('repository', 'AceDimi2005/Orbit')}",
                "Orbit PC Companion · Up to Date",
                0x00040040,
            )
            return {"status": "up_to_date", "result": result}

        can_self_update = bool(download_url) and not getattr(sys, "frozen", False)
        if can_self_update:
            prompt = (
                f"A new version of Orbit PC Companion is available on GitHub!\n\n"
                f"Installed version: {current_version}\n"
                f"Latest version: {latest_version}"
                f"{notes_preview}\n\n"
                "Click Yes to download and install the update automatically,\n"
                "No to open the GitHub release page in your browser,\n"
                "or Cancel to close."
            )
            flags = 0x00040043  # MB_YESNOCANCEL | MB_ICONINFORMATION | MB_TOPMOST
        else:
            prompt = (
                f"A new version of Orbit PC Companion is available on GitHub!\n\n"
                f"Installed version: {current_version}\n"
                f"Latest version: {latest_version}"
                f"{notes_preview}\n\n"
                "Would you like to open the GitHub release page to download it?"
            )
            flags = 0x00040044  # MB_YESNO | MB_ICONINFORMATION | MB_TOPMOST

        choice = self._show_message_box_sync(prompt, "Orbit PC Companion · Update Available", flags)
        if can_self_update and choice == IDYES:
            try:
                updated = installer(download_url)
                self.show_notification(
                    "Orbit PC Companion Updated",
                    f"Updated {len(updated)} files to version {latest_version}. Restart Orbit to use the new version.",
                )
                self._show_message_box_sync(
                    f"Orbit PC Companion has been updated to version {latest_version} ({len(updated)} files updated).\n\n"
                    "Please restart Orbit PC Companion to finish applying the update.",
                    "Orbit PC Companion · Update Installed",
                    0x00040040,
                )
                return {"status": "updated", "files": updated, "result": result}
            except Exception as error:
                LOGGER.exception("Automatic update failed")
                self._show_message_box_sync(
                    f"Automatic update could not be completed:\n{error}\n\n"
                    "Opening the GitHub releases page instead.",
                    "Orbit PC Companion · Update Error",
                    0x00040030,
                )
                try:
                    opener(release_url)
                except Exception:
                    pass
                return {"status": "update_failed", "error": str(error), "result": result}

        if (can_self_update and choice == IDNO) or (not can_self_update and choice == IDYES):
            try:
                opener(release_url)
            except Exception:
                LOGGER.exception("Could not open GitHub release page")
            return {"status": "opened_browser", "result": result}

        return {"status": "dismissed", "result": result}

    def check_for_updates_async(self):
        thread = threading.Thread(
            target=self.perform_update_check,
            daemon=True,
            name="orbit-tray-updater",
        )
        thread.start()
        return thread

    def _show_message_box_sync(self, text, title, flags=0x00040040):
        if os.name != "nt" and self._apis is None:
            return 0
        try:
            user32, _, _ = self._get_apis()
            return int(user32.MessageBoxW(None, text, title, flags))
        except Exception:
            LOGGER.exception("Could not display tray dialog")
            return 0

    def show_connection_details(self):
        info = self.status_provider() or {}
        version = info.get("agentVersion") or "4.1.0"
        hostname = info.get("hostname") or "PC"
        ip_address = info.get("ipAddress") or "No active LAN adapter"
        port = info.get("agentPort") or 8765
        secure_port = info.get("securePort") or 8766
        fingerprint = info.get("fingerprint") or "Unavailable"
        startup_state = "Enabled" if self.startup.is_enabled() else "Disabled"
        message = (
            f"Orbit PC Companion {version}\n\n"
            f"PC Name: {hostname}\n"
            f"LAN IP Address: {ip_address}\n"
            f"Encrypted HTTPS Port: {secure_port} (HTTP: {port})\n"
            f"Run at Windows Startup: {startup_state}\n\n"
            f"Certificate SHA-256:\n{fingerprint}\n\n"
            "In Orbit on iPhone, tap Find my PC to pair with a one-use 6-digit code."
        )
        self._async_message_box(message, "Orbit PC Companion · Connection Details", 0x00040040)

    def _async_message_box(self, text, title, flags=0x00040040):
        if os.name != "nt" and self._apis is None:
            return
        threading.Thread(
            target=self._show_message_box_sync,
            args=(text, title, flags),
            daemon=True,
            name="orbit-tray-dialog",
        ).start()

    def _notify_data(self, flags=NIF_MESSAGE | NIF_ICON | NIF_TIP, info_title="", info_text=""):
        data = NOTIFYICONDATAW()
        data.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
        data.hWnd = self._hwnd
        data.uID = 1
        data.uFlags = flags
        data.uCallbackMessage = WM_TRAYICON
        data.hIcon = self._hicon_small or self._hicon_big
        data.szTip = self.format_tooltip()
        if info_text:
            data.uFlags |= NIF_INFO
            # WCHAR[64] / WCHAR[256] with the terminator, counted in UTF-16 units (emoji take two).
            data.szInfoTitle = fit_utf16(info_title, 63)
            data.szInfo = fit_utf16(info_text, 255)
            data.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND
        return data

    def show_notification(self, title, message):
        with self._lock:
            if not self._hwnd:
                return False
            try:
                _, shell32, _ = self._get_apis()
                data = self._notify_data(info_title=title, info_text=message)
                return bool(shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(data)))
            except Exception:
                return False

    def update_tooltip(self):
        with self._lock:
            if not self._hwnd:
                return False
            try:
                _, shell32, _ = self._get_apis()
                data = self._notify_data(flags=NIF_TIP)
                return bool(shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(data)))
            except Exception:
                return False

    def _show_context_menu(self, hwnd):
        user32, _, _ = self._get_apis()
        self.update_tooltip()
        menu = user32.CreatePopupMenu()
        if not menu:
            return
        try:
            for item in self.build_menu_items():
                if item.get("separator"):
                    user32.AppendMenuW(menu, MF_SEPARATOR, 0, None)
                    continue
                flags = MF_STRING
                if not item.get("enabled", True):
                    flags |= MF_GRAYED | MF_DISABLED
                if item.get("checked"):
                    flags |= MF_CHECKED
                user32.AppendMenuW(menu, flags, int(item.get("id") or 0), item["label"])
            point = POINT()
            user32.GetCursorPos(ctypes.byref(point))
            user32.SetForegroundWindow(hwnd)
            selected = int(user32.TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                0,
                hwnd,
                None,
            ))
            user32.PostMessageW(hwnd, 0, 0, 0)
        finally:
            user32.DestroyMenu(menu)
        if selected > 0:
            self.execute_command(selected)

    def _load_icons(self, user32, kernel32):
        resolved = ensure_icon_file(self.icon_path)
        sm_cx = user32.GetSystemMetrics(SM_CXSMICON) or 16
        sm_cy = user32.GetSystemMetrics(SM_CYSMICON) or 16
        bg_cx = user32.GetSystemMetrics(SM_CXICON) or 32
        bg_cy = user32.GetSystemMetrics(SM_CYICON) or 32
        self._hicon_small = user32.LoadImageW(None, str(resolved), IMAGE_ICON, sm_cx, sm_cy, LR_LOADFROMFILE)
        self._hicon_big = user32.LoadImageW(None, str(resolved), IMAGE_ICON, bg_cx, bg_cy, LR_LOADFROMFILE)
        if not self._hicon_small:
            self._hicon_small = user32.LoadImageW(None, str(resolved), IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE)
        console = kernel32.GetConsoleWindow()
        if console:
            if self._hicon_small:
                user32.SendMessageW(console, WM_SETICON, ICON_SMALL, self._hicon_small)
            if self._hicon_big:
                user32.SendMessageW(console, WM_SETICON, ICON_BIG, self._hicon_big)

    def _wnd_proc(self, hwnd, msg, wparam, lparam):
        user32, shell32, _ = self._get_apis()
        if msg == WM_TRAYICON:
            event = int(lparam) & 0xFFFF
            if event in (WM_RBUTTONUP, WM_LBUTTONUP, WM_CONTEXTMENU, NIN_SELECT, NIN_KEYSELECT):
                self._show_context_menu(hwnd)
                return 0
            if event in (WM_LBUTTONDBLCLK, NIN_BALLOONUSERCLICK):
                self.show_connection_details()
                return 0
        elif self._taskbar_created_msg and msg == self._taskbar_created_msg:
            with self._lock:
                if self._hwnd:
                    data = self._notify_data()
                    shell32.Shell_NotifyIconW(NIM_ADD, ctypes.byref(data))
            return 0
        elif msg == WM_COMMAND:
            self.execute_command(int(wparam) & 0xFFFF)
            return 0
        elif msg == WM_CLOSE:
            user32.DestroyWindow(hwnd)
            return 0
        elif msg == WM_DESTROY:
            with self._lock:
                if self._hwnd:
                    data = self._notify_data()
                    shell32.Shell_NotifyIconW(NIM_DELETE, ctypes.byref(data))
                    self._hwnd = None
            user32.PostQuitMessage(0)
            return 0
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam)

    def _run_loop(self):
        try:
            user32, shell32, kernel32 = self._get_apis()
            hinstance = kernel32.GetModuleHandleW(None)
            self._load_icons(user32, kernel32)
            self._taskbar_created_msg = user32.RegisterWindowMessageW("TaskbarCreated")
            self._wndproc_ref = WNDPROC(self._wnd_proc)

            wc = WNDCLASSEXW()
            wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
            wc.lpfnWndProc = self._wndproc_ref
            wc.hInstance = hinstance
            wc.hIcon = self._hicon_big
            wc.hIconSm = self._hicon_small
            wc.lpszClassName = self._class_name
            if not user32.RegisterClassExW(ctypes.byref(wc)):
                self._ready.set()
                return

            hwnd = user32.CreateWindowExW(
                0, self._class_name, "Orbit PC Companion", 0,
                0, 0, 0, 0, None, None, hinstance, None,
            )
            if not hwnd:
                user32.UnregisterClassW(self._class_name, hinstance)
                self._ready.set()
                return

            with self._lock:
                self._hwnd = hwnd
                data = self._notify_data()
                shell32.Shell_NotifyIconW(NIM_ADD, ctypes.byref(data))

            self.startup.sync_if_enabled()
            self._ready.set()

            if self.notify_on_start:
                self.show_notification(
                    "Orbit PC Companion is running",
                    "Click the Orbit icon in the system tray to toggle Windows startup or stop the companion.",
                )

            msg = MSG()
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))
        except Exception:
            LOGGER.exception("Orbit system tray loop failed")
            self._ready.set()
        finally:
            try:
                user32, shell32, kernel32 = self._get_apis()
                with self._lock:
                    if self._hwnd:
                        data = self._notify_data()
                        shell32.Shell_NotifyIconW(NIM_DELETE, ctypes.byref(data))
                        self._hwnd = None
                if self._hicon_small:
                    user32.DestroyIcon(self._hicon_small)
                    self._hicon_small = None
                if self._hicon_big:
                    user32.DestroyIcon(self._hicon_big)
                    self._hicon_big = None
                user32.UnregisterClassW(self._class_name, kernel32.GetModuleHandleW(None))
            except Exception:
                pass
            self._closed.set()

    def start(self):
        if os.name != "nt" and self._apis is None:
            return False
        if self._thread is not None and self._thread.is_alive():
            return True
        self._ready.clear()
        self._closed.clear()
        self._thread = threading.Thread(target=self._run_loop, daemon=True, name="orbit-tray")
        self._thread.start()
        self._ready.wait(timeout=3.0)
        return self._hwnd is not None

    def request_stop(self):
        try:
            if callable(self.on_stop):
                self.on_stop()
        finally:
            self.close()

    def close(self):
        with self._lock:
            hwnd = self._hwnd
        if hwnd:
            try:
                user32, _, _ = self._get_apis()
                user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
            except Exception:
                pass
        if self._thread is not None and self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=2.0)
