"""Opening links on the PC (`POST /api/open-url`, Send to PC).

Only plain web links are accepted: `http` or `https`, a host, no user name or password, at most
4096 characters, and none of the characters RFC 3986 requires to be percent-encoded. That last
rule matters on Windows: the browser is started by pasting the link into a command line template
from the registry, so a quote or a space must never reach it. The link is then handed to the
default browser through `ShellExecuteW(..., "open", ...)`, never to a shell.

`validate_url(value, allowed_schemes)` also serves features that open other kinds of links
(for example `steam://`): the character rules always apply, the host rules apply to web links.
"""
import ctypes
import os
import unicodedata
from urllib.parse import urlsplit

WEB_SCHEMES = frozenset({"http", "https"})
MAX_URL_LENGTH = 4096
_FORBIDDEN_CHARACTERS = frozenset('"<>\\^`{|}')
_INVISIBLE_CATEGORIES = frozenset({"Cc", "Cf", "Cs", "Zs", "Zl", "Zp"})
_HOST_PUNCTUATION = frozenset("-._:")
SW_SHOWNORMAL = 1
SE_ERR_NOASSOC = 31
COINIT_APARTMENTTHREADED = 0x2
COINIT_DISABLE_OLE1DDE = 0x4
ASFW_ANY = 0xFFFFFFFF


class LinkError(ValueError):
    """The link is not one Orbit opens; the message explains why in plain words."""


def validate_url(value, allowed_schemes=WEB_SCHEMES):
    """Returns `value` unchanged when it is safe to open, else raises LinkError."""
    if not isinstance(value, str) or not value:
        raise LinkError("Send a web address such as https://example.com.")
    if len(value) > MAX_URL_LENGTH:
        raise LinkError(f"This link is longer than {MAX_URL_LENGTH:,} characters, so it cannot be opened on the PC.")
    for character in value:
        if character.isspace() or unicodedata.category(character) in _INVISIBLE_CATEGORIES:
            raise LinkError("This link contains spaces or invisible control characters.")
        if character in _FORBIDDEN_CHARACTERS:
            raise LinkError("This link contains characters such as quotes, spaces or backslashes that must be percent-encoded.")
    try:
        parts = urlsplit(value)
    except ValueError as error:
        raise LinkError("This is not a valid web address.") from error
    scheme = parts.scheme.lower()
    if not scheme or scheme not in allowed_schemes:
        if allowed_schemes == WEB_SCHEMES:
            raise LinkError("Only http and https links can be opened on the PC.")
        raise LinkError("Orbit cannot open this kind of link on the PC.")
    if scheme in WEB_SCHEMES:
        if "@" in parts.netloc:
            raise LinkError("Links that contain a user name or password cannot be opened from Orbit.")
        host = parts.hostname
        if not value[len(parts.scheme):].startswith("://") or not host:
            raise LinkError("This link has no website address. Use a full link such as https://example.com.")
        if any(not (character.isalnum() or character in _HOST_PUNCTUATION) for character in host):
            raise LinkError("This link's website address is not valid.")
        try:
            parts.port
        except ValueError as error:
            raise LinkError("This link has an invalid port number.") from error
    elif not value[len(parts.scheme) + 1:]:
        raise LinkError("This link is empty after its scheme.")
    return value


def display_url(value, limit=120):
    """A short form for notifications: host and path, without query or fragment."""
    try:
        parts = urlsplit(value)
        text = (parts.hostname or "") + (parts.path if parts.path not in ("", "/") else "")
    except ValueError:
        text = ""
    text = text or value
    return text if len(text) <= limit else text[:limit - 1] + "…"


_LIBRARIES = {}


def _library(name):
    """A private ctypes handle for a system DLL. Prototypes set on it never change the shared
    `ctypes.windll` functions other modules call (orbit_tray compares ShellExecuteW's default
    int result with 32, for example)."""
    library = _LIBRARIES.get(name)
    if library is None:
        library = _LIBRARIES[name] = ctypes.WinDLL(name)
    return library


def _shell_execute(url):
    """`ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL)` with COM initialized for
    the call, as Microsoft requires for ShellExecute on threads it does not own."""
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
            # Lets the browser come to the front; harmless when Windows does not allow it.
            user32.AllowSetForegroundWindow(ASFW_ANY)
        except Exception:
            pass
        handle = shell32.ShellExecuteW(None, "open", url, None, None, SW_SHOWNORMAL)
    finally:
        if initialized:
            ole32.CoUninitialize()
    code = int(handle or 0)
    if code <= 32:
        if code == SE_ERR_NOASSOC:
            raise OSError("Windows has no default web browser to open this link. Choose one in Windows Settings.")
        raise OSError("Windows could not open this link in the default browser.")


def open_url(url, allowed_schemes=WEB_SCHEMES):
    """Opens a validated link with the user's default handler. Raises LinkError or OSError."""
    url = validate_url(url, allowed_schemes)
    if os.name != "nt":
        raise OSError("Opening links on the PC needs Windows.")
    _shell_execute(url)
    return url
