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

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator

MAX_CLIPBOARD_BYTES = 1024 * 1024
_CLIPBOARD_LOCK = threading.Lock()
_AUDIO_LOCK = threading.Lock()


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

    def write(self, text):
        if not isinstance(text, str) or "\0" in text:
            raise ValueError("Clipboard text cannot contain null characters.")
        try:
            data = text.encode("utf-16-le", errors="strict") + b"\0\0"
        except UnicodeEncodeError as error:
            raise ValueError("Clipboard text must contain valid Unicode.") from error
        if len(data) > MAX_CLIPBOARD_BYTES:
            raise ValueError("Clipboard text exceeds the 1 MB transfer limit.")
        with _CLIPBOARD_LOCK, self.opened():
            handle = self.kernel.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
            if not handle:
                raise _native_error("memory allocation")
            transferred = False
            try:
                pointer = self.kernel.GlobalLock(handle)
                if not pointer:
                    raise _native_error("memory lock")
                try:
                    ctypes.memmove(pointer, data, len(data))
                finally:
                    self.kernel.GlobalUnlock(handle)
                # Allocate/copy before emptying, so preparation failures leave the
                # existing clipboard untouched. Windows owns hMem after success.
                if not self.user.EmptyClipboard():
                    raise _native_error("clear")
                if not self.user.SetClipboardData(13, handle):
                    raise _native_error("write")
                transferred = True
            finally:
                if not transferred:
                    self.kernel.GlobalFree(handle)


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


def _session_snapshot(session):
    identity, pid = _session_identity(session)
    if int(session.State) == 2:  # AudioSessionStateExpired
        raise AudioSessionGone("This audio session has ended. Refresh the mixer.")
    volume = session.SimpleAudioVolume
    level = float(volume.GetMasterVolume()) * 100
    if not math.isfinite(level) or not 0 <= level <= 100.001:
        raise DesktopUnavailable("Windows returned an invalid audio session level.")
    try:
        process = session.Process
        name = process.name() if process is not None else ("System sounds" if pid == 0 else f"Application {pid}")
    except Exception:
        name = f"Application {pid}"
    name = "".join(character for character in str(name) if ord(character) >= 32)[:260]
    return {"id": identity, "pid": pid, "name": name or f"Application {pid}",
            "volume": round(min(100.0, level), 1), "isMuted": bool(volume.GetMute())}


def list_audio_sessions():
    with _AUDIO_LOCK, _audio_sessions() as sessions:
        result = []
        for session in sessions:
            try:
                result.append(_session_snapshot(session))
            except Exception:
                # Sessions can disappear while the enumerator is being read.
                continue
        return sorted(result, key=lambda item: (item["name"].casefold(), item["pid"], item["id"]))


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
        return {"status": "ok", "session": session}

    return router
