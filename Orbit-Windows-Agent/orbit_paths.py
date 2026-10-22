"""Where the companion's program files live, and which files hold its secrets.

A PyInstaller build (OrbitCompanion.exe) unpacks its Python modules into a
temporary `_MEIPASS` folder, so `__file__` does not point at the folder the
user installed. The installed folder is the one next to the executable.
"""
import os
from pathlib import Path
import sys
import threading

# File names that hold credentials anywhere on the PC. The Files API hides and
# refuses every file with one of these names, and every `.orbit-*` file.
SECRET_FILE_NAMES = frozenset({
    ".orbit-token", ".orbit-widget-token", ".orbit-sunshine-login",
    "server-key.pem", "server-cert.pem", ".orbit-tls-key.pem", ".env",
})
SECRET_PREFIX = ".orbit-"

_PROTECTED = []
_PROTECTED_LOCK = threading.Lock()


def is_frozen():
    return bool(getattr(sys, "frozen", False))


def runtime_directory():
    """The installed companion folder: next to OrbitCompanion.exe, or next to orbit_agent.py."""
    if is_frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def bundle_directory():
    """The temporary folder a one-file build unpacks itself into, or None."""
    bundle = getattr(sys, "_MEIPASS", None) if is_frozen() else None
    return Path(bundle).resolve() if bundle else None


def program_directories():
    """Folders holding the running companion's code; the Files API never writes there."""
    folders = [runtime_directory()]
    bundle = bundle_directory()
    if bundle is not None and bundle not in folders:
        folders.append(bundle)
    return folders


def is_secret_name(name):
    folded = str(name or "").casefold()
    return folded in SECRET_FILE_NAMES or folded.startswith(SECRET_PREFIX)


def protect_path(path):
    """Register a credential or private-state file the Files API must never expose."""
    if not path:
        return
    candidate = Path(path).absolute()
    with _PROTECTED_LOCK:
        if candidate not in _PROTECTED:
            _PROTECTED.append(candidate)


def registered_protected_paths():
    with _PROTECTED_LOCK:
        return list(_PROTECTED)


def mask_secret(value, visible=4):
    """`••••••••abcd`: enough to recognise a credential, never enough to use it."""
    text = str(value or "")
    if len(text) <= visible:
        return "•" * 8
    return "•" * 8 + text[-visible:]


def interactive_console(stream=None):
    """True only for a terminal someone is looking at, never for the background log file."""
    stream = sys.stdout if stream is None else stream
    try:
        return bool(stream is not None and stream.isatty())
    except (AttributeError, ValueError, OSError):
        return False


def environment_path(name):
    value = os.environ.get(name, "").strip()
    return Path(value) if value else None
