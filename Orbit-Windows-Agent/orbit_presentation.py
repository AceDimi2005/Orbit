"""Presentation remote (feature "presentation"): PowerPoint through COM, other presenters by keys.

Desktop PowerPoint is reached with `comtypes.client.GetActiveObject("PowerPoint.Application",
dynamic=True)`, so no type-library wrappers are generated (safe in the frozen exe). When a
PowerPoint slide show runs, actions go through its SlideShowView (no focus needed). Otherwise the
action becomes a key press through `orbit_input`, which reaches the window in front: PowerPoint,
Google Slides, Keynote for iCloud, a PDF viewer... The response says which path was used.

All COM work runs on one worker thread, one job at a time; each job initializes COM and
uninitializes it again (like orbit_desktop). Callers wait with a short timeout, and while a job is
stuck (a dialog open in PowerPoint) new requests fail fast instead of queueing stale slide changes.
Every COM pointer a job touches is released inside the job, before CoUninitialize.

HTTP contract (main token, HTTPS only: 426 over plain HTTP; 501 when the agent is not on Windows;
JSON keys are camelCase; errors are {"detail": "<plain sentence>"}):

GET /api/presentation  -> 200
  {"app": "powerpoint" | "none",       # desktop PowerPoint is running and reachable
   "running": true,                     # a PowerPoint slide show is running (also at the end screen)
   "slide": 3,                          # slide number shown in the show, or selected in the editor; 0 = none
   "slides": 12,                        # slides in that presentation; 0 = no presentation
   "state": "running" | "paused" | "black" | "white" | "done" | "none",   # "done" = end-of-show screen
   "notes": "Speaker notes",            # notes of `slide`, "\n" line breaks, "" when none (<= 20,000 chars)
   "title": "Quarterly Review",         # presentation name without extension, "" when none
   "slideTitle": "Agenda",              # title of `slide`, "" when none
   "control": "powerpoint" | "keys",    # how next/previous are sent right now
   "thumbnails": true,                  # GET /api/presentation/slide.png works now
   "elapsedSeconds": 754 | null,        # time since the show started (null when not running)
   "slideElapsedSeconds": 31 | null}    # time on the current slide (null when not running or done)
  503 PowerPoint is busy or not responding (has a Retry-After header).

POST /api/presentation/{action}  body (optional JSON): {"slide": 5, "via": "auto" | "powerpoint" | "keys"}
  action: next | previous | first | last | start | startCurrent | end | black | white | goto
  `slide` (1...10000) is required for goto and ignored otherwise. `via` defaults to "auto":
    - a PowerPoint slide show runs -> COM: next/previous/first/last/goto, start (= back to the first
      slide), startCurrent (nothing to do), end, black/white (toggle: a second press shows the slide;
      next/previous/first/last/goto from a black or white screen show the slide again first);
    - no show, but PowerPoint has a presentation open -> start/startCurrent start the show over COM
      (startCurrent then jumps to the slide selected in the editor); every other action uses keys,
      except while PowerPoint's own editor window is in front (409: the keys would edit the slide);
    - otherwise keys to the window in front: next Right, previous Left, first Home, last End,
      start F5, startCurrent Shift+F5, end Esc, black B, white W, goto = the slide number on the
      numeric keypad then Enter (black/white toggle there too).
    "keys" always presses keys; "powerpoint" never does (409 when no show / no PowerPoint).
  -> 200 {"status": "done", "action": "next", "via": "powerpoint" | "keys",
          "keys": ["Right"],               # what was pressed ([] on the PowerPoint path)
          "detail": "Went to the next slide.",
          "presentation": {...GET shape...} | null}   # state right after the action, null if unreadable
  404 unknown action. 422 invalid body, goto without `slide`, or goto past the last slide.
  409 via "powerpoint" without a show or PowerPoint; no show while PowerPoint's editor is in front;
      start with a presentation that has no slides; keys while the PC is still at the sign-in
      screen (boot instance).
  503 PowerPoint busy or not responding (Retry-After; a change PowerPoint had not started by then
      is dropped, not applied later), or Windows refused the keys (locked PC, secure desktop).

GET /api/presentation/slide.png?slide=N&width=800  -> 200 image/png (Cache-Control: no-store)
  `slide` (1...10000) defaults to the slide shown (or selected in the editor); `width` 64...1920
  pixels, default 800; the height follows the slide size (16:9, 4:3, portrait...), at most 1920
  (the width shrinks to fit). Exported with Slide.Export into a private temporary folder that is
  deleted right after reading. 404 when PowerPoint is not open, no presentation is open, or the
  slide does not exist. 503 PowerPoint busy or the export failed.
"""
from concurrent.futures import Future, TimeoutError as FutureTimeout
import ctypes
from dataclasses import dataclass
import gc
import logging
import math
import os
import queue
import re
import shutil
import tempfile
import threading
import time
from typing import Any, Literal, Optional

import psutil
from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, StrictInt

import orbit_input

LOGGER = logging.getLogger("orbit")

PROGID = "PowerPoint.Application"
POWERPOINT_EXE = "powerpnt.exe"
ACTIONS = ("next", "previous", "first", "last", "start", "startCurrent", "end", "black", "white", "goto")
VIA_VALUES = ("auto", "powerpoint", "keys")
# PpSlideShowState
SHOW_STATES = {1: "running", 2: "paused", 3: "black", 4: "white", 5: "done"}
STATE_RUNNING, STATE_BLACK, STATE_WHITE, STATE_DONE = 1, 3, 4, 5
PP_PLACEHOLDER_BODY = 2
MAX_SLIDE = 10000
MAX_NOTES = 20000
MAX_TITLE = 300
MAX_PLACEHOLDERS = 32
THUMBNAIL_MIN_WIDTH = 64
THUMBNAIL_MAX_SIDE = 1920
THUMBNAIL_DEFAULT_WIDTH = 800
MAX_PNG_BYTES = 16 * 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EXPORT_PREFIX = "orbit-slide-"
STALE_EXPORT_SECONDS = 600

# How long a request waits for its turn on the COM thread, and for its job to finish.
STATE_WAIT, STATE_TIMEOUT = 1.5, 4.0
ACTION_WAIT, ACTION_TIMEOUT = 2.5, 6.0
EXPORT_WAIT, EXPORT_TIMEOUT = 2.5, 12.0
# PowerPoint rejects calls for a moment while it is busy (RPC_E_CALL_REJECTED); retry for this long.
BUSY_RETRY_SECONDS = 1.5
BUSY_RETRY_PAUSE = 0.1
# After keys, PowerPoint needs a moment before the new slide can be read back.
KEY_SETTLE_SECONDS = 0.25
# A change is skipped when less than this is left before the caller gives up, so a request that
# was already answered "didn't respond" never changes the slide later.
DEADLINE_MARGIN = 0.75
RETRY_AFTER_SECONDS = "2"

KEY_ACTIONS = {
    "next": ("right",), "previous": ("left",), "first": ("home",), "last": ("end",),
    "start": ("f5",), "startCurrent": ("shift", "f5"), "end": ("esc",), "black": ("b",), "white": ("w",),
}
_PRESENTATION_EXTENSIONS = (".pptx", ".pptm", ".ppt", ".ppsx", ".ppsm", ".pps", ".potx", ".potm", ".pot", ".odp")

# HRESULTs, compared unsigned.
_BUSY_CODES = frozenset({0x80010001, 0x8001010A})  # RPC_E_CALL_REJECTED, RPC_E_SERVERCALL_RETRYLATER
_GONE_CODES = frozenset({
    0x80010108,  # RPC_E_DISCONNECTED
    0x800706BA,  # RPC_S_SERVER_UNAVAILABLE
    0x800706BE,  # RPC_S_CALL_FAILED
    0x80010007,  # RPC_E_SERVER_DIED
    0x80010012,  # RPC_E_SERVER_DIED_DNE
    0x800401FD,  # CO_E_OBJNOTCONNECTED
    0x800401E3,  # MK_E_UNAVAILABLE
    0x800401F3,  # CO_E_CLASSSTRING (PowerPoint is not installed)
    0x80040154,  # REGDB_E_CLASSNOTREG
})

NOT_OPEN = "PowerPoint isn't open on the PC."
NO_PRESENTATION = "No presentation is open in PowerPoint."
NO_SLIDES = "This presentation has no slides."
NO_SHOW = "No PowerPoint slide show is running. Start the slide show first."
CLOSED = "PowerPoint closed while Orbit was talking to it."
BUSY = "PowerPoint is busy. Close any open dialog in PowerPoint and try again."
NOT_RESPONDING = "PowerPoint didn't respond in time. A dialog may be open in PowerPoint on the PC."
FAILED = "PowerPoint couldn't do that right now. Try again."
EXPORT_FAILED = "PowerPoint couldn't make a picture of this slide."
EXPORT_TOO_LARGE = "The picture of this slide is too large to send."
NO_TEMPORARY_FOLDER = "Orbit couldn't create a temporary file on the PC. Check that the system drive isn't full."
KEYS_REFUSED = "Windows didn't accept the key presses. The PC may be locked or showing a secure screen."
SIGN_IN_FIRST = "Sign in to Windows on the PC first. Orbit presses the keys on the signed-in desktop."
COM_FAILED = "Windows couldn't start the connection to PowerPoint."
UNKNOWN_ACTION = ("Unknown presentation action. Use next, previous, first, last, start, startCurrent, end, "
                  "black, white or goto.")
GOTO_NEEDS_SLIDE = "Send the slide number to go to, for example {\"slide\": 3}."

_CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0c\x0e-\x1f\x7f]")


class PresentationError(RuntimeError):
    """A failure the user can read. Every subclass takes just the message."""
    status = 503


class PresentationBusy(PresentationError):
    """PowerPoint is busy or did not answer in time (503 with Retry-After)."""


class PowerPointUnavailable(PresentationError):
    """PowerPoint is not open, has no presentation, or runs no show (409; 404 for thumbnails)."""
    status = 409


class SlideOutOfRange(PresentationError):
    """The slide number is past the end of the presentation (422; 404 for thumbnails)."""
    status = 422


class KeysRefused(PresentationError):
    """Windows did not take the synthetic key presses (503)."""


class SignInRequired(PresentationError):
    """Keys need the signed-in desktop; the boot instance has none (409)."""
    status = 409


def _hresult(error):
    """The HRESULT of a COMError/OSError, unsigned, or None."""
    for attribute in ("hresult", "winerror"):
        value = getattr(error, attribute, None)
        if isinstance(value, int) and not isinstance(value, bool) and value:
            return value & 0xFFFFFFFF
    arguments = getattr(error, "args", ())
    if arguments and isinstance(arguments[0], int) and not isinstance(arguments[0], bool) and arguments[0]:
        return arguments[0] & 0xFFFFFFFF
    return None


def _is_busy(error):
    return _hresult(error) in _BUSY_CODES


def _is_gone(error):
    return _hresult(error) in _GONE_CODES


_LOG_LOCK = threading.Lock()
_LAST_LOGGED = {}


def _log_failure(context, error):
    """Logs a COM failure once a minute per kind (GET is polled every second)."""
    code = _hresult(error) or 0
    key = (context, code, type(error).__name__)
    now = time.monotonic()
    with _LOG_LOCK:
        if now - _LAST_LOGGED.get(key, -math.inf) < 60:
            return
        if len(_LAST_LOGGED) > 256:
            _LAST_LOGGED.clear()
        _LAST_LOGGED[key] = now
    LOGGER.warning("PowerPoint %s failed: %s (0x%08X)", context, type(error).__name__, code)


def _as_int(value, default=None):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    return default


def _as_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) and value > 0 else None


def _truthy(value):
    # msoTrue is -1, msoFalse 0.
    return value not in (0, False, None)


def _clean_text(value, limit, single_line=False):
    """COM text made safe for JSON: \\n line breaks, no control characters, no lone surrogates."""
    if not isinstance(value, str):
        return ""
    text = value.encode("utf-16", "surrogatepass").decode("utf-16", "replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\x0b", "\n")
    text = _CONTROL_CHARACTERS.sub("", text)
    if single_line:
        text = " ".join(text.split())
    text = text.strip()
    if len(text) > limit:
        text = text[:limit].rstrip() + "…"
    return text


def _optional(read, default=None):
    """A read that may fail (missing shape, older PowerPoint). Busy and closed still propagate."""
    try:
        return read()
    except Exception as error:
        if _is_busy(error) or _is_gone(error):
            raise
        return default


def _retry(step):
    """Runs a COM step, retrying while PowerPoint rejects calls because it is busy.

    A rejected call was not executed, so retrying it is safe. Each step ends with at most one call
    that changes anything, so a retry never repeats a change that already happened.
    """
    deadline = time.monotonic() + BUSY_RETRY_SECONDS
    while True:
        try:
            return step()
        except Exception as error:
            if not _is_busy(error) or time.monotonic() >= deadline:
                raise
        time.sleep(BUSY_RETRY_PAUSE)


def _count(collection):
    return max(0, _as_int(collection.Count, 0))


def empty_state(app="none"):
    return {"app": app, "running": False, "slide": 0, "slides": 0, "state": "none", "notes": "", "title": "",
            "slideTitle": "", "control": "keys", "thumbnails": False, "elapsedSeconds": None,
            "slideElapsedSeconds": None}


# -- COM thread ----------------------------------------------------------------------------------

def _load_comtypes():
    import comtypes
    import comtypes.client  # noqa: F401  (GetActiveObject lives there)
    return comtypes


_JOB = threading.local()


def _ensure_time_left():
    """Called on the COM thread right before a change: refuse when the caller is giving up."""
    deadline = getattr(_JOB, "deadline", None)
    if deadline is not None and time.monotonic() > deadline:
        raise PresentationBusy(NOT_RESPONDING)


def _fresh(error):
    """A new exception without the traceback, so no frame keeps COM pointers alive."""
    if isinstance(error, PresentationError):
        return type(error)(*error.args)
    if _is_busy(error):
        return PresentationBusy(BUSY)
    if _is_gone(error):
        return PowerPointUnavailable(CLOSED)
    return PresentationError(FAILED)


def _run_job(job):
    """Runs `job(comtypes_or_None)` inside its own COM initialization; returns (ok, value)."""
    try:
        com = _load_comtypes()
    except Exception as error:  # ImportError, OSError: no COM here, so no PowerPoint either.
        _log_failure("import", error)
        com = None
    if com is None:
        return _capture(job, None)
    try:
        com.CoInitialize()
    except Exception as error:
        _log_failure("CoInitialize", error)
        return False, PresentationError(COM_FAILED)
    outcome = (False, PresentationError(FAILED))
    try:
        outcome = _capture(job, com)
        return outcome
    finally:
        if not outcome[0]:
            # A failed job's frames are gone by now; collect anyway, so a reference cycle can't
            # release a COM pointer after this thread left COM.
            gc.collect()
        com.CoUninitialize()


def _drop_tracebacks(error):
    """Cuts the frames (and the COM pointers in them) off an exception and the ones it chains to,
    in case something else still holds one of those exception objects."""
    seen = set()
    while error is not None and id(error) not in seen:
        seen.add(id(error))
        error.__traceback__ = None
        if error.__cause__ is not None and id(error.__cause__) not in seen:
            _drop_tracebacks(error.__cause__)
        error = error.__context__


def _capture(job, com):
    try:
        return True, job(com)
    except Exception as error:
        if not isinstance(error, PresentationError):
            _log_failure("call", error)
        _drop_tracebacks(error)
        # `error` itself is dropped when this block ends, before the caller uninitializes COM.
        return False, _fresh(error)


class ComWorker:
    """One thread that runs COM jobs one at a time; callers wait with a timeout.

    The gate is held from submitting a job until the job finishes. A caller that times out leaves
    the gate held, so while PowerPoint hangs new requests fail after `wait` instead of queueing
    actions that would all run late once it recovers.
    """

    def __init__(self, name="orbit-presentation"):
        self._name = name
        self._jobs = queue.SimpleQueue()
        self._gate = threading.Lock()
        self._thread_lock = threading.Lock()
        self._thread = None

    def call(self, job, *, timeout, wait):
        if not self._gate.acquire(timeout=wait):
            raise PresentationBusy(BUSY)
        future = Future()
        deadline = time.monotonic() + max(0.0, timeout - DEADLINE_MARGIN)
        try:
            self._ensure_thread()
            self._jobs.put((job, future, deadline))
        except BaseException:
            self._gate.release()
            raise
        try:
            ok, value = future.result(timeout=timeout)
        except FutureTimeout:
            raise PresentationBusy(NOT_RESPONDING) from None
        if ok:
            return value
        raise value

    def _ensure_thread(self):
        with self._thread_lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._loop, name=self._name, daemon=True)
                self._thread.start()

    def _loop(self):
        while True:
            job, future, _JOB.deadline = self._jobs.get()
            try:
                outcome = _run_job(job)
            except BaseException:  # never let the worker die with the gate held
                outcome = (False, PresentationError(FAILED))
            try:
                future.set_result(outcome)
            finally:
                job = future = outcome = _JOB.deadline = None
                self._gate.release()


# -- PowerPoint object model ------------------------------------------------------------------

@dataclass
class _Show:
    window: Any
    view: Any
    presentation: Any


def _attach(com):
    """The running PowerPoint.Application, or None when it is not running (or COM is missing)."""
    if com is None:
        return None
    try:
        return com.client.GetActiveObject(PROGID, dynamic=True)
    except OSError:
        return None  # MK_E_UNAVAILABLE (not running), CO_E_CLASSSTRING (not installed)
    except Exception as error:
        if _is_gone(error):
            return None
        raise


def _show(app):
    """The first slide show window, or None when no show runs."""
    windows = app.SlideShowWindows
    if _count(windows) < 1:
        return None
    window = windows.Item(1)
    return _Show(window=window, view=window.View, presentation=window.Presentation)


def _active_presentation(app):
    try:
        if _count(app.Presentations) < 1:
            return None
        return app.ActivePresentation
    except Exception as error:
        if _is_busy(error) or _is_gone(error):
            raise
        return None  # no document window (Protected View, windowless automation)


def _editor_slide_index(app, total):
    """The slide selected in PowerPoint's editor, 1 when it can't be read, 0 without slides."""
    if total < 1:
        return 0
    for read in (lambda: app.ActiveWindow.View.Slide.SlideIndex,
                 lambda: app.ActiveWindow.Selection.SlideRange.Item(1).SlideIndex):
        index = _as_int(_optional(read))
        if index is not None and 1 <= index <= total:
            return index
    return 1


def _show_slide_index(show, state_code, total):
    """The slide shown; the last slide at the end-of-show screen (View.Slide raises there)."""
    if state_code != STATE_DONE:
        # SlideIndex is the slide's number in the file; CurrentShowPosition counts only the slides
        # in this show (hidden slides and custom shows differ), so it is only the fallback.
        for read in (lambda: show.view.Slide.SlideIndex, lambda: show.view.CurrentShowPosition):
            index = _as_int(_optional(read))
            if index is not None and 1 <= index <= total:
                return index
    return total


def _presentation_title(presentation):
    name = _clean_text(_optional(lambda: presentation.Name, ""), MAX_TITLE, single_line=True)
    stem, extension = os.path.splitext(name)
    if stem and extension.lower() in _PRESENTATION_EXTENSIONS:
        return stem
    return name


def _slide_title(slide):
    def read():
        shapes = slide.Shapes
        if not _truthy(_optional(lambda: shapes.HasTitle, -1)):
            return ""
        return shapes.Title.TextFrame.TextRange.Text
    return _clean_text(_optional(read, ""), MAX_TITLE, single_line=True)


def _slide_notes(slide):
    def text_of(shape):
        if not _truthy(_optional(lambda: shape.HasTextFrame, -1)):
            return ""
        return shape.TextFrame.TextRange.Text

    def read():
        placeholders = slide.NotesPage.Shapes.Placeholders
        count = min(_count(placeholders), MAX_PLACEHOLDERS)
        for index in range(1, count + 1):
            shape = placeholders.Item(index)
            if _as_int(_optional(lambda: shape.PlaceholderFormat.Type)) == PP_PLACEHOLDER_BODY:
                return text_of(shape)
        # No body placeholder found by type: the usual position of the notes text.
        return text_of(placeholders.Item(2)) if count >= 2 else ""
    return _clean_text(_optional(read, ""), MAX_NOTES)


def _snapshot(app):
    """GET /api/presentation for an attached PowerPoint (plain data only)."""
    result = empty_state("powerpoint")
    show = _show(app)
    if show is not None:
        code = _as_int(_optional(lambda: show.view.State), STATE_RUNNING)
        presentation = show.presentation
        total = _count(presentation.Slides)
        index = _show_slide_index(show, code, total)
        result.update(running=True, control="powerpoint", state=SHOW_STATES.get(code, "running"))
        result["elapsedSeconds"] = _as_int(_optional(lambda: show.view.PresentationElapsedTime))
        if code != STATE_DONE:
            result["slideElapsedSeconds"] = _as_int(_optional(lambda: show.view.SlideElapsedTime))
    else:
        presentation = _active_presentation(app)
        if presentation is None:
            return result
        total = _as_int(_optional(lambda: _count(presentation.Slides)), 0)
        index = _editor_slide_index(app, total)
    result.update(slides=total, slide=index if total else 0, title=_presentation_title(presentation),
                  thumbnails=total > 0)
    # At the end-of-show screen no slide is shown, so there are no notes or title to read.
    if total and not (show is not None and result["state"] == "done"):
        slide = _optional(lambda: presentation.Slides.Item(index))
        if slide is not None:
            result["slideTitle"] = _slide_title(slide)
            result["notes"] = _slide_notes(slide)
    return result


def _state_job(com):
    app = _retry(lambda: _attach(com))
    if app is None:
        return empty_state()
    try:
        return _retry(lambda: _snapshot(app))
    except Exception as error:
        if _is_gone(error):
            return empty_state()  # PowerPoint closed while it was being read
        raise


def _state_after(app):
    """State right after an action; None when it can't be read (the action itself succeeded)."""
    try:
        return _retry(lambda: _snapshot(app))
    except Exception as error:
        _log_failure("read after action", error)
        return None


def _set_show_state(view, value):
    def step():
        view.State = value
    _retry(step)


def _show_action(show, action, slide):
    """Performs `action` in the running show; returns the detail sentence."""
    view = show.view
    code = _as_int(_retry(lambda: view.State), STATE_RUNNING)
    total = _retry(lambda: _count(show.presentation.Slides))
    moves = ("next", "previous", "first", "last", "goto")
    if action == "goto" and not 1 <= slide <= total:
        raise SlideOutOfRange(_out_of_range(total))
    _ensure_time_left()
    if action in moves and code in (STATE_BLACK, STATE_WHITE):
        _set_show_state(view, STATE_RUNNING)  # show the slide again before moving
    if action == "next":
        _retry(lambda: view.Next())
        return "Went to the next slide."
    if action == "previous":
        _retry(lambda: view.Previous())
        return "Went back one slide."
    if action in ("first", "start"):
        _retry(lambda: view.First())
        return "Went to the first slide."
    if action == "last":
        _retry(lambda: view.Last())
        return "Went to the last slide."
    if action == "goto":
        _retry(lambda: view.GotoSlide(slide))
        return f"Went to slide {slide}."
    if action == "startCurrent":
        return "The slide show is already running."
    if action == "end":
        _retry(lambda: view.Exit())
        return "Ended the slide show."
    if action in ("black", "white"):
        target = STATE_BLACK if action == "black" else STATE_WHITE
        if code == target:
            _set_show_state(view, STATE_RUNNING)
            return "Showing the slide again."
        _set_show_state(view, target)
        return f"The screen is {action}. Press {action.title()} again to show the slide."
    raise PresentationError(FAILED)


def _start_show(app, presentation, action):
    """Starts the slide show of `presentation` over COM; returns the detail sentence.

    Run() honours the presentation's own slide-show settings, like F5. For startCurrent the show
    then jumps to the slide selected in the editor, so the saved settings are never changed.
    """
    total = _retry(lambda: _count(presentation.Slides))
    if total < 1:
        raise PowerPointUnavailable(NO_SLIDES)
    index = _editor_slide_index(app, total) if action == "startCurrent" else 1
    _ensure_time_left()
    window = _retry(lambda: presentation.SlideShowSettings.Run())
    if action != "startCurrent" or index <= 1:
        return "Started the slide show."

    def jump():
        target = window if window is not None else app.SlideShowWindows.Item(1)
        target.View.GotoSlide(index)
    try:
        _retry(jump)
    except Exception as error:
        if _is_gone(error):
            raise
        _log_failure("jump after start", error)
        return "Started the slide show. Orbit couldn't jump to the current slide."
    return f"Started the slide show from slide {index}."


def _out_of_range(total):
    if total == 1:
        return "This presentation has 1 slide."
    return f"This presentation has {total} slides. Choose a slide from 1 to {total}."


def _action_job(action, slide, via):
    """COM part of an action. Returns (detail, state) when PowerPoint handled it, or
    ("keys", powerpoint_open) when the action should be sent as keys instead."""
    def job(com):
        app = _retry(lambda: _attach(com))
        if app is None:
            if via == "powerpoint":
                raise PowerPointUnavailable(NOT_OPEN)
            return "keys", False
        show = _retry(lambda: _show(app))
        if show is not None:
            detail = _show_action(show, action, slide)
            return detail, _state_after(app)
        if action in ("start", "startCurrent"):
            presentation = _retry(lambda: _active_presentation(app))
            if presentation is not None:
                detail = _start_show(app, presentation, action)
                return detail, _state_after(app)
            if via == "powerpoint":
                raise PowerPointUnavailable(NO_PRESENTATION)
        elif via == "powerpoint":
            raise PowerPointUnavailable(NO_SHOW)
        return "keys", True
    return job


def _thumbnail_size(presentation, width):
    """(width, height) in pixels for the slide's aspect ratio, both sides at most 1920."""
    slide_width = _as_number(_optional(lambda: presentation.PageSetup.SlideWidth))
    slide_height = _as_number(_optional(lambda: presentation.PageSetup.SlideHeight))
    ratio = slide_height / slide_width if slide_width and slide_height else 9 / 16
    ratio = min(max(ratio, 0.1), 10.0)
    height = round(width * ratio)
    if height > THUMBNAIL_MAX_SIDE:
        height = THUMBNAIL_MAX_SIDE
        width = round(THUMBNAIL_MAX_SIDE / ratio)
    return max(16, int(width)), max(16, int(height))


def _export_root():
    return tempfile.gettempdir()


_SWEEP_LOCK = threading.Lock()
_SWEPT = False


def sweep_stale_exports(now=None):
    """Removes export folders left behind by a crash (once per agent run, older than 10 minutes)."""
    root = _export_root()
    now = time.time() if now is None else now
    try:
        entries = list(os.scandir(root))
    except OSError:
        return 0
    removed = 0
    for entry in entries:
        try:
            if not entry.name.startswith(EXPORT_PREFIX) or not entry.is_dir(follow_symlinks=False):
                continue
            if now - entry.stat(follow_symlinks=False).st_mtime < STALE_EXPORT_SECONDS:
                continue
        except OSError:
            continue
        shutil.rmtree(entry.path, ignore_errors=True)
        removed += 1
    return removed


def _sweep_once():
    global _SWEPT
    with _SWEEP_LOCK:
        if _SWEPT:
            return
        _SWEPT = True
    try:
        sweep_stale_exports()
    except Exception as error:
        _log_failure("cleanup", error)


def _export_png(slide, width, height):
    """Slide.Export into a private temporary folder; returns the PNG bytes. The folder is always
    deleted, also when the export fails (this runs on the COM thread, so even a late export after
    the caller gave up is cleaned)."""
    try:
        folder = tempfile.mkdtemp(prefix=EXPORT_PREFIX, dir=_export_root())
    except OSError as error:
        _log_failure("temporary folder", error)
        raise PresentationError(NO_TEMPORARY_FOLDER) from None
    try:
        target = os.path.join(folder, "slide.png")
        try:
            _retry(lambda: slide.Export(target, "PNG", width, height))
        except Exception as error:
            if _is_busy(error) or _is_gone(error):
                raise
            _log_failure("export", error)
            raise PresentationError(EXPORT_FAILED) from None
        try:
            size = os.path.getsize(target)
        except OSError:
            raise PresentationError(EXPORT_FAILED) from None
        if size > MAX_PNG_BYTES:
            raise PresentationError(EXPORT_TOO_LARGE)
        with open(target, "rb") as handle:
            data = handle.read(MAX_PNG_BYTES + 1)
        if len(data) > MAX_PNG_BYTES:
            raise PresentationError(EXPORT_TOO_LARGE)
        if not data.startswith(PNG_SIGNATURE):
            raise PresentationError(EXPORT_FAILED)
        return data
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def _thumbnail_job(slide_number, width):
    def job(com):
        app = _retry(lambda: _attach(com))
        if app is None:
            raise PowerPointUnavailable(NOT_OPEN)
        show = _retry(lambda: _show(app))
        if show is not None:
            presentation = show.presentation
            total = _retry(lambda: _count(presentation.Slides))
            code = _as_int(_retry(lambda: _optional(lambda: show.view.State)), STATE_RUNNING)
            current = _retry(lambda: _show_slide_index(show, code, total))
        else:
            presentation = _retry(lambda: _active_presentation(app))
            if presentation is None:
                raise PowerPointUnavailable(NO_PRESENTATION)
            total = _retry(lambda: _count(presentation.Slides))
            current = _retry(lambda: _editor_slide_index(app, total))
        if total < 1:
            raise PowerPointUnavailable(NO_SLIDES)
        index = slide_number or current or 1
        if index > total:
            raise SlideOutOfRange(_out_of_range(total))
        size = _retry(lambda: _thumbnail_size(presentation, width))
        slide = _retry(lambda: presentation.Slides.Item(index))
        _sweep_once()
        return _export_png(slide, *size)
    return job


# -- controller ---------------------------------------------------------------------------------

def _key_chords(action, slide):
    if action == "goto":
        return [[f"numpad{digit}"] for digit in str(slide)] + [["enter"]]
    return [list(KEY_ACTIONS[action])]


_USER32 = None


def _foreground_process_name():
    """Lowercase executable name of the window in front, "" when it can't be told."""
    global _USER32
    try:
        if _USER32 is None:
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            user32.GetForegroundWindow.argtypes = []
            user32.GetForegroundWindow.restype = ctypes.c_void_p
            user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
            user32.GetWindowThreadProcessId.restype = ctypes.c_uint32
            _USER32 = user32
        window = _USER32.GetForegroundWindow()
        if not window:
            return ""
        pid = ctypes.c_uint32(0)
        if not _USER32.GetWindowThreadProcessId(window, ctypes.byref(pid)) or not pid.value:
            return ""
        return str(psutil.Process(pid.value).name()).lower()
    except Exception:
        return ""


class PresentationController:
    def __init__(self, worker=None):
        self.worker = worker or ComWorker()

    def state(self):
        return self.worker.call(_state_job, timeout=STATE_TIMEOUT, wait=STATE_WAIT)

    def thumbnail(self, slide=None, width=THUMBNAIL_DEFAULT_WIDTH):
        width = int(width)
        if not THUMBNAIL_MIN_WIDTH <= width <= THUMBNAIL_MAX_SIDE:
            raise ValueError(f"Choose a width from {THUMBNAIL_MIN_WIDTH} to {THUMBNAIL_MAX_SIDE} pixels.")
        if slide is not None and not 1 <= int(slide) <= MAX_SLIDE:
            raise ValueError(f"Choose a slide from 1 to {MAX_SLIDE}.")
        return self.worker.call(_thumbnail_job(slide, width), timeout=EXPORT_TIMEOUT, wait=EXPORT_WAIT)

    def perform(self, action, slide=None, via="auto", boot_mode=False):
        if action not in ACTIONS:
            raise ValueError(UNKNOWN_ACTION)
        if via not in VIA_VALUES:
            raise ValueError("Use \"auto\", \"powerpoint\" or \"keys\" for via.")
        if action == "goto" and (slide is None or not 1 <= slide <= MAX_SLIDE):
            raise ValueError(GOTO_NEEDS_SLIDE)
        if action != "goto":
            slide = None
        powerpoint_open = None
        if via != "keys":
            outcome = self.worker.call(_action_job(action, slide, via), timeout=ACTION_TIMEOUT, wait=ACTION_WAIT)
            if outcome[0] != "keys":
                detail, state = outcome
                return {"status": "done", "action": action, "via": "powerpoint", "keys": [], "detail": detail,
                        "presentation": state}
            powerpoint_open = outcome[1]
            if powerpoint_open and action not in ("start", "startCurrent") \
                    and _foreground_process_name() == POWERPOINT_EXE:
                # PowerPoint's editor is in front and no show runs: B, W or a slide number would
                # be typed into the slide, and arrows would only move the cursor.
                raise PowerPointUnavailable(NO_SHOW)
        return self._press(action, slide, boot_mode, powerpoint_open)

    def _press(self, action, slide, boot_mode, powerpoint_open):
        if boot_mode:
            raise SignInRequired(SIGN_IN_FIRST)
        chords = _key_chords(action, slide)
        try:
            with orbit_input.INPUT_LOCK:
                for chord in chords:
                    orbit_input.press_chord(chord)
        except OSError as error:
            _log_failure("keys", error)
            raise KeysRefused(KEYS_REFUSED) from None
        labels = [orbit_input.chord_label(chord) for chord in chords]
        if powerpoint_open is False:
            state = empty_state()
        else:
            # PowerPoint (or maybe PowerPoint, with via "keys") may have reacted: read it back.
            time.sleep(KEY_SETTLE_SECONDS)
            try:
                state = self.state()
            except PresentationError:
                state = None
        if action == "goto":
            pressed = f"{slide} and Enter"
        else:
            pressed = labels[0]
        return {"status": "done", "action": action, "via": "keys", "keys": labels,
                "detail": f"Pressed {pressed} on the PC. Keys go to the window in front.", "presentation": state}


CONTROLLER = PresentationController()


# -- HTTP ------------------------------------------------------------------------------------------

class PresentationActionBody(BaseModel):
    model_config = ConfigDict(extra="ignore")
    slide: Optional[StrictInt] = Field(default=None, ge=1, le=MAX_SLIDE)
    via: Literal["auto", "powerpoint", "keys"] = "auto"


def create_presentation_router(verify_control, require_secure, require_windows, boot_mode=lambda: False,
                               controller=None):
    """Routes under /api/presentation: main token, HTTPS only, Windows only."""
    router = APIRouter(prefix="/api/presentation", dependencies=[Depends(verify_control), Depends(require_secure)])

    def active():
        return controller or CONTROLLER

    def translate(operation, *, not_found=False):
        try:
            return operation()
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        except (PowerPointUnavailable, SlideOutOfRange) as error:
            raise HTTPException(404 if not_found else error.status, str(error)) from error
        except PresentationBusy as error:
            raise HTTPException(503, str(error), headers={"Retry-After": RETRY_AFTER_SECONDS}) from error
        except PresentationError as error:
            raise HTTPException(error.status, str(error)) from error

    @router.get("")
    def presentation_state(response: Response):
        require_windows()
        response.headers["Cache-Control"] = "no-store"
        return translate(lambda: active().state())

    @router.get("/slide.png")
    def presentation_slide_png(slide: Optional[int] = Query(None, ge=1, le=MAX_SLIDE),
                               width: int = Query(THUMBNAIL_DEFAULT_WIDTH, ge=THUMBNAIL_MIN_WIDTH,
                                                  le=THUMBNAIL_MAX_SIDE)):
        require_windows()
        data = translate(lambda: active().thumbnail(slide, width), not_found=True)
        return Response(content=data, media_type="image/png", headers={"Cache-Control": "no-store"})

    @router.post("/{action}")
    def presentation_action(action: str, response: Response, body: Optional[PresentationActionBody] = None):
        if action not in ACTIONS:
            raise HTTPException(404, UNKNOWN_ACTION)
        body = body or PresentationActionBody()
        if action == "goto" and body.slide is None:
            raise HTTPException(422, GOTO_NEEDS_SLIDE)
        require_windows()
        response.headers["Cache-Control"] = "no-store"
        return translate(lambda: active().perform(action, body.slide, body.via, bool(boot_mode())))

    return router
