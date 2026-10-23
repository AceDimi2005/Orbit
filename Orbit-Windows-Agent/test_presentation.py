"""Presentation remote: a fake PowerPoint COM object model, the keystroke fallback and thumbnails.

Nothing here touches Windows or the network: comtypes is replaced by a fake whose objects are
handed out as fresh proxies (like comtypes dynamic dispatch), so the tests can check that no COM
pointer outlives its CoInitialize/CoUninitialize pair. Keys go to a mocked orbit_input.
"""
import logging
import os
import tempfile
import threading
import time
import unittest
import weakref
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_input
import orbit_presentation as presentation

PNG = presentation.PNG_SIGNATURE + b"fake slide picture"
QUIET_LOGGER = logging.getLogger("orbit.tests.presentation")
QUIET_LOGGER.addHandler(logging.NullHandler())
QUIET_LOGGER.propagate = False
LIVE_PROXIES = weakref.WeakSet()


def signed(code):
    return code - (1 << 32) if code >= 1 << 31 else code


CALL_REJECTED = signed(0x80010001)
DISCONNECTED = signed(0x80010108)
PPT_INVALID_REQUEST = signed(0x80048240)
MK_E_UNAVAILABLE = signed(0x800401E3)


class FakeCOMError(Exception):
    def __init__(self, hresult, text="Error", details=None):
        super().__init__(hresult, text, details)
        self.hresult, self.text, self.details = hresult, text, details


# -- fake PowerPoint ---------------------------------------------------------------------------

class FakePowerPoint:
    """The state behind the fake object model, plus fault injection and a call log."""

    def __init__(self, slides=12, name="Quarterly Review.pptx", open_=True):
        self.slides = [{"title": f"Slide title {i}", "notes": f"Notes for slide {i}"} for i in range(1, slides + 1)]
        self.name = name
        self.open = open_
        self.running = False
        self.position = 1
        self.state = 1
        self.editor = 1
        self.page = (960.0, 540.0)
        self.calls = []
        self.faults = {}
        self.export_bytes = PNG
        self.exports = []
        self.notes_order = ("image", "body")
        self.has_active_window = True

    def fault(self, key, factory, times=1):
        """Raise factory() on the next `times` accesses of key (times=None: always)."""
        self.faults[key] = [factory, times]

    def check(self, key):
        entry = self.faults.get(key)
        if entry is None:
            return
        factory, times = entry
        if times is not None:
            entry[1] -= 1
            if entry[1] <= 0:
                del self.faults[key]
        raise factory()

    def start(self, index=1):
        self.running, self.position, self.state = True, index, 1


class Model:
    def __init__(self, ppt):
        self._ppt = ppt

    def _before(self, name):
        self._ppt.check(f"{type(self).__name__}.{name}")


class Proxy:
    """What comtypes hands out: a new wrapper on every access, released when dropped."""
    __slots__ = ("_target", "__weakref__")

    def __init__(self, target):
        object.__setattr__(self, "_target", target)
        LIVE_PROXIES.add(self)

    def __getattr__(self, name):
        target = object.__getattribute__(self, "_target")
        target._before(name)
        value = getattr(target, name)
        if callable(value) and not isinstance(value, Model):
            def method(*args):
                target._before(name + "()")
                return wrap(value(*args))
            return method
        return wrap(value)

    def __setattr__(self, name, value):
        target = object.__getattribute__(self, "_target")
        target._before("set " + name)
        setattr(target, name, value)


def wrap(value):
    return Proxy(value) if isinstance(value, Model) else value


class Collection(Model):
    def __init__(self, ppt, items):
        super().__init__(ppt)
        self._items = items

    @property
    def Count(self):
        return len(self._items())

    def Item(self, index):
        items = self._items()
        if not 1 <= int(index) <= len(items):
            raise FakeCOMError(PPT_INVALID_REQUEST, "Item not found")
        return items[int(index) - 1]


class TextRange(Model):
    def __init__(self, ppt, text):
        super().__init__(ppt)
        self.Text = text


class TextFrame(Model):
    def __init__(self, ppt, text):
        super().__init__(ppt)
        self.TextRange = TextRange(ppt, text)


class Shape(Model):
    def __init__(self, ppt, text, placeholder_type, has_text=True):
        super().__init__(ppt)
        self.HasTextFrame = -1 if has_text else 0
        self.TextFrame = TextFrame(ppt, text)
        self.PlaceholderFormat = SimpleNamespace(Type=placeholder_type)


class Shapes(Model):
    def __init__(self, ppt, index):
        super().__init__(ppt)
        self._title = ppt.slides[index - 1]["title"]

    @property
    def HasTitle(self):
        return -1 if self._title is not None else 0

    @property
    def Title(self):
        if self._title is None:
            raise FakeCOMError(PPT_INVALID_REQUEST, "This slide has no title")
        return Shape(self._ppt, self._title, 1)


class NotesShapes(Model):
    def __init__(self, ppt, index):
        super().__init__(ppt)
        notes = ppt.slides[index - 1]["notes"]
        shapes = {"image": Shape(ppt, "", 1, has_text=False), "body": Shape(ppt, notes, 2),
                  "number": Shape(ppt, str(index), 13)}
        self.Placeholders = Collection(ppt, lambda: [shapes[name] for name in ppt.notes_order])


class NotesPage(Model):
    def __init__(self, ppt, index):
        super().__init__(ppt)
        self.Shapes = NotesShapes(ppt, index)


class Slide(Model):
    def __init__(self, ppt, index):
        super().__init__(ppt)
        self.SlideIndex = index
        self.Shapes = Shapes(ppt, index)
        self.NotesPage = NotesPage(ppt, index)

    def Export(self, path, filter_name, width, height):
        self._ppt.exports.append((path, filter_name, width, height))
        if self._ppt.export_bytes is not None:
            with open(path, "wb") as handle:
                handle.write(self._ppt.export_bytes)


class PageSetup(Model):
    @property
    def SlideWidth(self):
        return self._ppt.page[0]

    @property
    def SlideHeight(self):
        return self._ppt.page[1]


class Settings(Model):
    def Run(self):
        self._ppt.calls.append("Run")
        self._ppt.start(1)
        return SlideShowWindow(self._ppt)


class Presentation(Model):
    @property
    def Name(self):
        return self._ppt.name

    @property
    def Slides(self):
        return Collection(self._ppt, lambda: [Slide(self._ppt, i) for i in range(1, len(self._ppt.slides) + 1)])

    @property
    def SlideShowSettings(self):
        return Settings(self._ppt)

    @property
    def PageSetup(self):
        return PageSetup(self._ppt)


class View(Model):
    @property
    def State(self):
        return self._ppt.state

    @State.setter
    def State(self, value):
        self._ppt.calls.append(f"State={value}")
        self._ppt.state = value

    @property
    def Slide(self):
        if self._ppt.state == 5:
            raise FakeCOMError(PPT_INVALID_REQUEST, "There is no currently active slide.")
        return Slide(self._ppt, self._ppt.position)

    @property
    def CurrentShowPosition(self):
        return self._ppt.position

    PresentationElapsedTime = 754
    SlideElapsedTime = 31

    def _move(self, name, position):
        self._ppt.calls.append(name)
        self._ppt.position, self._ppt.state = position, 1

    def Next(self):
        if self._ppt.position >= len(self._ppt.slides):
            self._ppt.calls.append("Next")
            self._ppt.state = 5
        else:
            self._move("Next", self._ppt.position + 1)

    def Previous(self):
        self._move("Previous", max(1, self._ppt.position - (0 if self._ppt.state == 5 else 1)))

    def First(self):
        self._move("First", 1)

    def Last(self):
        self._move("Last", len(self._ppt.slides))

    def GotoSlide(self, index, reset=-1):
        self._move(f"GotoSlide({index})", index)

    def Exit(self):
        self._ppt.calls.append("Exit")
        self._ppt.running = False


class SlideShowWindow(Model):
    @property
    def View(self):
        return View(self._ppt)

    @property
    def Presentation(self):
        return Presentation(self._ppt)


class DocumentView(Model):
    @property
    def Slide(self):
        return Slide(self._ppt, self._ppt.editor)


class DocumentWindow(Model):
    @property
    def View(self):
        return DocumentView(self._ppt)


class Application(Model):
    @property
    def SlideShowWindows(self):
        return Collection(self._ppt, lambda: [SlideShowWindow(self._ppt)] if self._ppt.running else [])

    @property
    def Presentations(self):
        return Collection(self._ppt, lambda: [Presentation(self._ppt)] if self._ppt.open else [])

    @property
    def ActivePresentation(self):
        if not self._ppt.open:
            raise FakeCOMError(PPT_INVALID_REQUEST, "There is no active presentation.")
        return Presentation(self._ppt)

    @property
    def ActiveWindow(self):
        if not self._ppt.open or not self._ppt.has_active_window:
            raise FakeCOMError(PPT_INVALID_REQUEST, "No window")
        return DocumentWindow(self._ppt)


class FakeComtypes:
    """Stands in for the comtypes package: counts COM initialization, serves the fake PowerPoint."""
    COMError = FakeCOMError

    def __init__(self, ppt=None):
        self.ppt = ppt
        self.inits = 0
        self.uninits = 0
        self.live_at_uninit = []
        self.attached = []
        self.attach_hook = None
        self.client = SimpleNamespace(GetActiveObject=self.get_active_object)

    def CoInitialize(self):
        self.inits += 1

    def CoUninitialize(self):
        self.uninits += 1
        self.live_at_uninit.append(len(LIVE_PROXIES))

    def get_active_object(self, progid, interface=None, dynamic=False):
        self.attached.append((progid, dynamic))
        if self.attach_hook:
            self.attach_hook()
        if self.ppt is None:
            raise OSError(MK_E_UNAVAILABLE, "Operation unavailable")
        self.ppt.check("GetActiveObject")
        return Proxy(Application(self.ppt))


# -- helpers ------------------------------------------------------------------------------------

class PresentationTestCase(unittest.TestCase):
    def setUp(self):
        self.com = FakeComtypes(FakePowerPoint())
        self.ppt = self.com.ppt
        self.foreground = "chrome.exe"
        replacements = {"_load_comtypes": lambda: self.com, "KEY_SETTLE_SECONDS": 0, "BUSY_RETRY_PAUSE": 0.001,
                        "LOGGER": QUIET_LOGGER, "_LAST_LOGGED": {}, "_foreground_process_name": lambda: self.foreground}
        for name, replacement in replacements.items():
            patcher = patch.object(presentation, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.pressed = []
        press = patch.object(presentation.orbit_input, "press_chord", side_effect=self._press)
        self.press = press.start()
        self.addCleanup(press.stop)
        self.export_root = tempfile.mkdtemp(prefix="orbit-test-exports-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.export_root, ignore_errors=True))
        root = patch.object(presentation, "_export_root", lambda: self.export_root)
        root.start()
        self.addCleanup(root.stop)
        self.controller = presentation.PresentationController(presentation.ComWorker("test-presentation"))
        self.boot = False
        self.windows = True
        self.client = self.make_client()

    def _press(self, chord, **kwargs):
        self.pressed.append("+".join(orbit_input.normalize_chord(chord)))
        return chord

    def make_client(self):
        app = FastAPI()

        def verify(authorization: str = Header(None)):
            if authorization != "Bearer control":
                raise HTTPException(401, "Invalid Orbit token")

        def secure(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(426, "Encrypted connection required")

        def require_windows():
            if not self.windows:
                raise HTTPException(501, "PC controls require Windows")

        app.include_router(presentation.create_presentation_router(
            verify, secure, require_windows, boot_mode=lambda: self.boot, controller=self.controller))
        client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})
        self.addCleanup(client.close)
        return client

    def state(self):
        response = self.client.get("/api/presentation")
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def act(self, action, body=None, status=200):
        response = self.client.post(f"/api/presentation/{action}", json=body) if body is not None \
            else self.client.post(f"/api/presentation/{action}")
        self.assertEqual(response.status_code, status, response.text)
        return response.json()

    def assertCOMBalanced(self):
        self.assertEqual(self.com.inits, self.com.uninits)
        self.assertTrue(self.com.live_at_uninit, "COM was never initialized")
        self.assertEqual(set(self.com.live_at_uninit), {0}, "a COM pointer outlived CoUninitialize")


# -- state ----------------------------------------------------------------------------------------

class StateTests(PresentationTestCase):
    def test_closed_powerpoint_reports_none_and_keys(self):
        self.com.ppt = None
        self.assertEqual(self.state(), presentation.empty_state())
        self.assertEqual(self.com.attached, [("PowerPoint.Application", True)])
        self.assertCOMBalanced()

    def test_missing_comtypes_reports_none(self):
        def broken():
            raise ImportError("No module named comtypes")
        with patch.object(presentation, "_load_comtypes", broken):
            body = self.state()
        self.assertEqual(body["app"], "none")
        self.assertEqual(body["control"], "keys")

    def test_powerpoint_without_a_presentation(self):
        self.ppt.open = False
        body = self.state()
        self.assertEqual(body["app"], "powerpoint")
        self.assertEqual((body["slides"], body["slide"], body["state"], body["thumbnails"]), (0, 0, "none", False))
        self.assertEqual(body["control"], "keys")

    def test_presentation_open_in_the_editor(self):
        self.ppt.editor = 4
        body = self.state()
        self.assertEqual(body, {
            "app": "powerpoint", "running": False, "slide": 4, "slides": 12, "state": "none",
            "notes": "Notes for slide 4", "title": "Quarterly Review", "slideTitle": "Slide title 4",
            "control": "keys", "thumbnails": True, "elapsedSeconds": None, "slideElapsedSeconds": None})
        self.assertCOMBalanced()

    def test_editor_slide_falls_back_to_the_first_slide(self):
        self.ppt.has_active_window = False
        self.assertEqual(self.state()["slide"], 1)

    def test_running_show(self):
        self.ppt.start(3)
        body = self.state()
        self.assertEqual(body, {
            "app": "powerpoint", "running": True, "slide": 3, "slides": 12, "state": "running",
            "notes": "Notes for slide 3", "title": "Quarterly Review", "slideTitle": "Slide title 3",
            "control": "powerpoint", "thumbnails": True, "elapsedSeconds": 754, "slideElapsedSeconds": 31})
        self.assertCOMBalanced()

    def test_show_states_are_named(self):
        self.ppt.start(2)
        for code, name in ((1, "running"), (2, "paused"), (3, "black"), (4, "white"), (99, "running")):
            with self.subTest(code=code):
                self.ppt.state = code
                self.assertEqual(self.state()["state"], name)

    def test_end_of_show_screen_is_done_without_reading_the_slide(self):
        self.ppt.start(12)
        self.ppt.state = 5
        reads = []
        self.ppt.fault("View.Slide", lambda: reads.append("View.Slide") or FakeCOMError(PPT_INVALID_REQUEST, "No slide"),
                       None)
        body = self.state()
        self.assertEqual(reads, [], "View.Slide must not be read at the end screen")
        self.assertEqual((body["state"], body["running"], body["slide"], body["slides"]), ("done", True, 12, 12))
        self.assertEqual((body["notes"], body["slideTitle"], body["slideElapsedSeconds"]), ("", "", None))
        self.assertEqual(body["elapsedSeconds"], 754)
        self.assertCOMBalanced()

    def test_unreadable_slide_in_a_running_show_falls_back_to_the_show_position(self):
        self.ppt.start(6)
        self.ppt.fault("View.Slide", lambda: FakeCOMError(PPT_INVALID_REQUEST, "Invalid request"), None)
        body = self.state()
        self.assertEqual((body["slide"], body["state"]), (6, "running"))

    def test_notes_come_from_the_body_placeholder_and_are_cleaned(self):
        self.ppt.notes_order = ("number", "image", "body")
        self.ppt.slides[0]["notes"] = "  First line\rSecond\x0bThird\r\nFourth\x07 \ud800 end  "
        self.ppt.slides[0]["title"] = "  Big\r\ntitle\t "
        body = self.state()
        self.assertEqual(body["notes"], "First line\nSecond\nThird\nFourth � end")
        self.assertEqual(body["slideTitle"], "Big title")

    def test_long_notes_are_cut(self):
        self.ppt.slides[0]["notes"] = "x" * (presentation.MAX_NOTES + 50)
        notes = self.state()["notes"]
        self.assertEqual(len(notes), presentation.MAX_NOTES + 1)
        self.assertTrue(notes.endswith("…"))

    def test_slides_without_notes_or_title(self):
        self.ppt.slides[0].update(notes="", title=None)
        body = self.state()
        self.assertEqual((body["notes"], body["slideTitle"]), ("", ""))

    def test_titles_keep_unknown_extensions_and_unsaved_names(self):
        for name, title in (("Deck.PPTX", "Deck"), ("Show.ppsx", "Show"), ("Presentation1", "Presentation1"),
                            ("v1.2 final", "v1.2 final"), ("notes.txt", "notes.txt")):
            with self.subTest(name=name):
                self.ppt.name = name
                self.assertEqual(self.state()["title"], title)

    def test_busy_powerpoint_is_retried(self):
        self.ppt.start(2)
        self.ppt.fault("Application.SlideShowWindows", lambda: FakeCOMError(CALL_REJECTED, "Call was rejected"), 3)
        self.assertEqual(self.state()["slide"], 2)
        self.assertCOMBalanced()

    def test_persistently_busy_powerpoint_is_a_503_with_retry_after(self):
        self.ppt.fault("Application.SlideShowWindows", lambda: FakeCOMError(CALL_REJECTED, "Call was rejected"), None)
        with patch.object(presentation, "BUSY_RETRY_SECONDS", 0.02):
            response = self.client.get("/api/presentation")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.headers["Retry-After"], "2")
        self.assertIn("PowerPoint is busy", response.json()["detail"])
        self.assertCOMBalanced()

    def test_powerpoint_closing_during_the_read_reports_none(self):
        self.ppt.fault("Presentation.Slides", lambda: FakeCOMError(DISCONNECTED, "The object invoked has disconnected"))
        self.assertEqual(self.state()["app"], "none")
        self.assertCOMBalanced()

    def test_unexpected_com_failure_is_a_plain_503(self):
        self.ppt.start(2)
        self.ppt.fault("Presentation.Slides", lambda: FakeCOMError(signed(0x80004005), "Secret internals \\\\server\\x"))
        response = self.client.get("/api/presentation")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], presentation.FAILED)
        self.assertCOMBalanced()

    def test_windows_and_https_are_checked_before_powerpoint(self):
        self.windows = False
        self.assertEqual(self.client.get("/api/presentation").status_code, 501)
        self.assertEqual(self.client.post("/api/presentation/next").status_code, 501)
        self.assertEqual(self.client.get("/api/presentation/slide.png").status_code, 501)
        plain = TestClient(self.client.app, base_url="http://test", headers={"Authorization": "Bearer control"})
        self.addCleanup(plain.close)
        self.assertEqual(plain.get("/api/presentation").status_code, 426)
        self.assertEqual(plain.post("/api/presentation/next").status_code, 426)
        self.assertEqual(self.client.get("/api/presentation", headers={"Authorization": "Bearer nope"}).status_code, 401)
        self.assertEqual(self.com.attached, [])
        self.assertEqual(self.pressed, [])

    def test_state_is_never_cached(self):
        self.assertEqual(self.client.get("/api/presentation").headers["Cache-Control"], "no-store")


# -- actions through COM ------------------------------------------------------------------------

class COMActionTests(PresentationTestCase):
    def setUp(self):
        super().setUp()
        self.ppt.start(3)

    def test_moves_use_the_slide_show_view(self):
        for action, call, slide in (("next", "Next", 4), ("previous", "Previous", 3), ("last", "Last", 12),
                                    ("first", "First", 1)):
            with self.subTest(action=action):
                body = self.act(action)
                self.assertEqual((body["status"], body["action"], body["via"], body["keys"]),
                                 ("done", action, "powerpoint", []))
                self.assertEqual(self.ppt.calls[-1], call)
                self.assertEqual(body["presentation"]["slide"], slide)
                self.assertEqual(body["presentation"]["notes"], f"Notes for slide {slide}")
        self.assertEqual(self.pressed, [])
        self.assertCOMBalanced()

    def test_goto(self):
        body = self.act("goto", {"slide": 7})
        self.assertEqual(self.ppt.calls, ["GotoSlide(7)"])
        self.assertEqual((body["presentation"]["slide"], body["detail"]), (7, "Went to slide 7."))

    def test_goto_past_the_end_is_refused_before_anything_changes(self):
        body = self.act("goto", {"slide": 13}, status=422)
        self.assertEqual(body["detail"], "This presentation has 12 slides. Choose a slide from 1 to 12.")
        self.assertEqual(self.ppt.calls, [])
        self.assertCOMBalanced()

    def test_goto_needs_a_whole_slide_number(self):
        for body in (None, {}, {"slide": 0}, {"slide": -1}, {"slide": "3"}, {"slide": 2.5}, {"slide": True},
                     {"slide": 10001}, {"via": "mouse", "slide": 2}):
            with self.subTest(body=body):
                self.act("goto", body, status=422)
        self.assertEqual(self.ppt.calls, [])
        self.assertEqual(self.com.attached, [])

    def test_black_and_white_toggle(self):
        body = self.act("black")
        self.assertEqual((self.ppt.state, body["presentation"]["state"]), (3, "black"))
        self.assertIn("Press Black again", body["detail"])
        body = self.act("black")
        self.assertEqual((self.ppt.state, body["detail"]), (1, "Showing the slide again."))
        self.act("white")
        self.assertEqual(self.ppt.state, 4)
        self.act("black")
        self.assertEqual(self.ppt.state, 3)
        self.assertEqual(self.ppt.calls, ["State=3", "State=1", "State=4", "State=3"])

    def test_moving_from_a_black_screen_shows_the_slide_first(self):
        self.ppt.state = 3
        body = self.act("next")
        self.assertEqual(self.ppt.calls, ["State=1", "Next"])
        self.assertEqual((body["presentation"]["state"], body["presentation"]["slide"]), ("running", 4))

    def test_next_on_the_last_slide_reaches_the_end_screen_and_previous_comes_back(self):
        self.ppt.position = 12
        body = self.act("next")
        self.assertEqual(body["presentation"]["state"], "done")
        self.assertEqual(body["presentation"]["slide"], 12)
        body = self.act("previous")
        self.assertEqual((body["presentation"]["state"], body["presentation"]["slide"]), ("running", 12))

    def test_end_and_start_while_running(self):
        body = self.act("start")
        self.assertEqual((self.ppt.calls, body["presentation"]["slide"]), (["First"], 1))
        body = self.act("startCurrent")
        self.assertEqual(body["detail"], "The slide show is already running.")
        body = self.act("end")
        self.assertEqual(self.ppt.calls, ["First", "Exit"])
        self.assertEqual((body["presentation"]["running"], body["presentation"]["state"]), (False, "none"))

    def test_rejected_call_is_retried_once_it_is_accepted(self):
        self.ppt.fault("View.Next()", lambda: FakeCOMError(CALL_REJECTED, "Call was rejected"), 2)
        self.act("next")
        self.assertEqual(self.ppt.calls, ["Next"])

    def test_failure_after_the_change_is_reported_as_done_without_state(self):
        # The show is found once for the action; only the read afterwards fails.
        original = Application.SlideShowWindows.fget
        calls = []

        def windows(application):
            calls.append(1)
            if len(calls) > 1:
                raise FakeCOMError(signed(0x80004005), "fail")
            return original(application)
        with patch.object(Application, "SlideShowWindows", property(windows)):
            body = self.act("next")
        self.assertEqual((body["via"], body["presentation"]), ("powerpoint", None))
        self.assertEqual(self.ppt.calls, ["Next"])
        self.assertCOMBalanced()

    def test_failed_com_action_is_a_plain_503(self):
        self.ppt.fault("View.Next()", lambda: FakeCOMError(signed(0x80004005), "Unspecified error"))
        body = self.act("next", status=503)
        self.assertEqual(body["detail"], presentation.FAILED)
        self.assertEqual(self.pressed, [])
        self.assertCOMBalanced()

    def test_via_keys_presses_keys_even_during_a_show(self):
        body = self.act("next", {"via": "keys"})
        self.assertEqual((body["via"], body["keys"]), ("keys", ["Right"]))
        self.assertEqual(self.pressed, ["right"])
        self.assertEqual(self.ppt.calls, [])


class StartTests(PresentationTestCase):
    def test_start_runs_the_show_over_com_without_changing_its_settings(self):
        body = self.act("start")
        self.assertEqual((body["via"], body["detail"]), ("powerpoint", "Started the slide show."))
        self.assertEqual(self.ppt.calls, ["Run"])
        self.assertTrue(body["presentation"]["running"])
        self.assertEqual(self.pressed, [])
        self.assertCOMBalanced()

    def test_start_current_jumps_to_the_editor_slide(self):
        self.ppt.editor = 5
        body = self.act("startCurrent")
        self.assertEqual(self.ppt.calls, ["Run", "GotoSlide(5)"])
        self.assertEqual((body["presentation"]["slide"], body["detail"]), (5, "Started the slide show from slide 5."))

    def test_start_current_on_the_first_slide_does_not_jump(self):
        self.act("startCurrent")
        self.assertEqual(self.ppt.calls, ["Run"])

    def test_start_current_still_starts_when_the_jump_fails(self):
        self.ppt.editor = 5
        self.ppt.fault("View.GotoSlide()", lambda: FakeCOMError(PPT_INVALID_REQUEST, "Invalid request"))
        body = self.act("startCurrent")
        self.assertEqual(body["via"], "powerpoint")
        self.assertIn("couldn't jump", body["detail"])
        self.assertTrue(self.ppt.running)

    def test_start_with_an_empty_presentation_is_refused(self):
        self.ppt.slides = []
        body = self.act("start", status=409)
        self.assertEqual(body["detail"], presentation.NO_SLIDES)
        self.assertEqual(self.pressed, [])


# -- keystroke fallback ---------------------------------------------------------------------------

class KeyFallbackTests(PresentationTestCase):
    def test_without_powerpoint_every_action_is_a_key(self):
        self.com.ppt = None
        expected = {"next": "right", "previous": "left", "first": "home", "last": "end", "start": "f5",
                    "startCurrent": "shift+f5", "end": "esc", "black": "b", "white": "w"}
        for action, key in expected.items():
            with self.subTest(action=action):
                self.pressed.clear()
                body = self.act(action)
                self.assertEqual((body["via"], body["action"], self.pressed), ("keys", action, [key]))
                self.assertEqual(body["presentation"], presentation.empty_state())
                self.assertIn("window in front", body["detail"])
        self.assertEqual(self.act("startCurrent")["keys"], ["Shift+F5"])

    def test_goto_by_keys_types_the_number_on_the_keypad_then_enter(self):
        self.com.ppt = None
        body = self.act("goto", {"slide": 104})
        self.assertEqual(self.pressed, ["numpad1", "numpad0", "numpad4", "enter"])
        self.assertEqual(body["detail"], "Pressed 104 and Enter on the PC. Keys go to the window in front.")

    def test_without_a_show_moves_are_keys_and_state_is_read_back(self):
        self.ppt.editor = 2
        body = self.act("next")
        self.assertEqual((body["via"], self.pressed), ("keys", ["right"]))
        self.assertEqual(body["presentation"]["slide"], 2)
        self.assertEqual(body["presentation"]["app"], "powerpoint")
        self.assertCOMBalanced()

    def test_powerpoint_editor_in_front_without_a_show_gets_no_keys(self):
        self.foreground = "powerpnt.exe"
        for action, body in (("next", None), ("black", None), ("white", None), ("goto", {"slide": 3}), ("end", None)):
            with self.subTest(action=action):
                self.assertEqual(self.act(action, body, status=409)["detail"], presentation.NO_SHOW)
        self.assertEqual(self.pressed, [])
        # Asked for keys explicitly, or nothing can tell what is in front: the keys are pressed.
        self.assertEqual(self.act("black", {"via": "keys"})["via"], "keys")
        self.foreground = ""
        self.assertEqual(self.act("next")["via"], "keys")
        self.assertEqual(self.pressed, ["b", "right"])

    def test_powerpoint_in_front_without_a_presentation_still_gets_f5(self):
        self.foreground = "powerpnt.exe"
        self.ppt.open = False
        self.assertEqual(self.act("start")["keys"], ["F5"])

    def test_start_without_a_presentation_presses_f5(self):
        self.ppt.open = False
        body = self.act("start")
        self.assertEqual((body["via"], self.pressed), ("keys", ["f5"]))

    def test_via_powerpoint_never_presses_keys(self):
        cases = ((True, "next", presentation.NO_SHOW), (False, "start", presentation.NO_PRESENTATION))
        for open_, action, message in cases:
            with self.subTest(action=action):
                self.ppt.open = open_
                self.assertEqual(self.act(action, {"via": "powerpoint"}, status=409)["detail"], message)
        self.com.ppt = None
        self.assertEqual(self.act("black", {"via": "powerpoint"}, status=409)["detail"], presentation.NOT_OPEN)
        self.assertEqual(self.pressed, [])

    def test_refused_keys_are_a_503_in_plain_words(self):
        self.com.ppt = None
        self.press.side_effect = orbit_input.InputRejected("refused")
        body = self.act("next", status=503)
        self.assertEqual(body["detail"], presentation.KEYS_REFUSED)

    def test_boot_instance_does_not_press_keys(self):
        self.com.ppt = None
        self.boot = True
        body = self.act("next", status=409)
        self.assertEqual(body["detail"], presentation.SIGN_IN_FIRST)
        self.assertEqual(self.pressed, [])

    def test_unknown_actions_do_nothing(self):
        for action in ("shutdown", "Next", "goto2", "%2e%2e"):
            with self.subTest(action=action):
                self.act(action, status=404)
        self.assertEqual((self.pressed, self.com.attached), ([], []))

    def test_keys_hold_the_input_lock_for_the_whole_sequence(self):
        self.com.ppt = None
        holders = []
        self.press.side_effect = lambda chord, **kwargs: holders.append(orbit_input.INPUT_LOCK._is_owned())
        self.act("goto", {"slide": 12})
        self.assertEqual(holders, [True, True, True])


# -- thumbnails -----------------------------------------------------------------------------------

class ThumbnailTests(PresentationTestCase):
    def png(self, query="", status=200):
        response = self.client.get(f"/api/presentation/slide.png{query}")
        self.assertEqual(response.status_code, status, response.text)
        return response

    def test_current_slide_is_exported_into_a_private_folder_that_is_removed(self):
        self.ppt.start(5)
        response = self.png()
        self.assertEqual(response.content, PNG)
        self.assertEqual(response.headers["content-type"], "image/png")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        path, filter_name, width, height = self.ppt.exports[0]
        self.assertEqual((filter_name, width, height), ("PNG", 800, 450))
        folder = os.path.dirname(path)
        self.assertEqual(os.path.dirname(folder), self.export_root)
        self.assertTrue(os.path.basename(folder).startswith(presentation.EXPORT_PREFIX))
        self.assertFalse(os.path.exists(folder))
        self.assertEqual(os.listdir(self.export_root), [])
        self.assertCOMBalanced()

    def test_requested_slide_and_width_follow_the_slide_shape(self):
        self.ppt.page = (720.0, 540.0)
        self.png("?slide=2&width=400")
        self.assertEqual(self.ppt.exports[-1][2:], (400, 300))
        self.ppt.page = (540.0, 960.0)  # portrait: the height is capped and the width shrinks
        self.png("?width=1920")
        self.assertEqual(self.ppt.exports[-1][2:], (1080, 1920))
        self.ppt.page = (0, 0)
        self.png("?width=1600")
        self.assertEqual(self.ppt.exports[-1][2:], (1600, 900))

    def test_slide_defaults_to_the_editor_slide(self):
        self.ppt.editor = 7
        self.png()
        self.assertEqual(os.path.basename(self.ppt.exports[-1][0]), "slide.png")

    def test_missing_powerpoint_presentation_or_slide_is_404(self):
        self.assertEqual(self.png("?slide=13", status=404).json()["detail"],
                         "This presentation has 12 slides. Choose a slide from 1 to 12.")
        self.ppt.open = False
        self.assertEqual(self.png(status=404).json()["detail"], presentation.NO_PRESENTATION)
        self.com.ppt = None
        self.assertEqual(self.png(status=404).json()["detail"], presentation.NOT_OPEN)
        self.assertEqual(self.ppt.exports, [])

    def test_invalid_parameters_are_422(self):
        for query in ("?width=63", "?width=1921", "?width=abc", "?slide=0", "?slide=10001", "?slide=x"):
            with self.subTest(query=query):
                self.png(query, status=422)
        self.assertEqual(self.com.attached, [])

    def test_failed_or_bad_exports_are_503_and_leave_nothing_behind(self):
        cases = (
            ("raises", lambda: self.ppt.fault("Slide.Export()", lambda: FakeCOMError(signed(0x80004005), "fail"))),
            ("writes nothing", lambda: setattr(self.ppt, "export_bytes", None)),
            ("not a png", lambda: setattr(self.ppt, "export_bytes", b"GIF89a....")),
        )
        for name, arrange in cases:
            with self.subTest(case=name):
                self.ppt.export_bytes = PNG
                arrange()
                self.assertEqual(self.png(status=503).json()["detail"], presentation.EXPORT_FAILED)
                self.assertEqual(os.listdir(self.export_root), [])
        self.assertCOMBalanced()

    def test_unwritable_temporary_folder_is_reported_without_exporting(self):
        with patch.object(presentation.tempfile, "mkdtemp", side_effect=OSError(28, "No space left on device")):
            self.assertEqual(self.png(status=503).json()["detail"], presentation.NO_TEMPORARY_FOLDER)
        self.assertEqual(self.ppt.exports, [])
        self.assertCOMBalanced()

    def test_oversized_export_is_refused(self):
        with patch.object(presentation, "MAX_PNG_BYTES", 8):
            self.assertEqual(self.png(status=503).json()["detail"], presentation.EXPORT_TOO_LARGE)
        self.assertEqual(os.listdir(self.export_root), [])

    def test_end_of_show_thumbnail_is_the_last_slide(self):
        self.ppt.start(12)
        self.ppt.state = 5
        self.png()
        self.assertEqual(len(self.ppt.exports), 1)

    def test_stale_export_folders_are_swept_once(self):
        old = os.path.join(self.export_root, presentation.EXPORT_PREFIX + "old")
        fresh = os.path.join(self.export_root, presentation.EXPORT_PREFIX + "fresh")
        other = os.path.join(self.export_root, "someone-else")
        for folder in (old, fresh, other):
            os.makedirs(folder)
        past = time.time() - presentation.STALE_EXPORT_SECONDS - 5
        os.utime(old, (past, past))
        os.utime(other, (past, past))
        with patch.object(presentation, "_SWEPT", False):
            self.png()
            self.assertEqual(sorted(os.listdir(self.export_root)), sorted([os.path.basename(fresh), "someone-else"]))
            os.makedirs(old)
            os.utime(old, (past, past))
            self.png()  # only once per agent run
            self.assertTrue(os.path.exists(old))


# -- COM thread -----------------------------------------------------------------------------------

class WorkerTests(PresentationTestCase):
    def test_every_call_initializes_and_uninitializes_com_on_the_worker_thread(self):
        threads = []
        self.com.attach_hook = lambda: threads.append(threading.current_thread().name)
        for _ in range(3):
            self.state()
        self.act("next")  # no show: keys, then one more job reads the state back
        self.client.get("/api/presentation/slide.png")
        self.assertEqual(self.com.inits, 6)
        self.assertCOMBalanced()
        self.assertEqual(set(threads), {"test-presentation"})

    def test_hung_powerpoint_times_out_and_later_requests_fail_fast_without_queueing(self):
        release = threading.Event()
        started = threading.Event()

        def hang():
            started.set()
            release.wait(5)
        self.com.attach_hook = hang
        worker = self.controller.worker
        with patch.object(presentation, "STATE_TIMEOUT", 0.1), patch.object(presentation, "STATE_WAIT", 0.05), \
             patch.object(presentation, "ACTION_WAIT", 0.05):
            response = self.client.get("/api/presentation")
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.json()["detail"], presentation.NOT_RESPONDING)
            self.assertEqual(response.headers["Retry-After"], "2")
            begun = time.monotonic()
            busy = self.client.post("/api/presentation/next")
            self.assertEqual(busy.status_code, 503)
            self.assertEqual(busy.json()["detail"], presentation.BUSY)
            self.assertLess(time.monotonic() - begun, 3.0)  # far below the 6 s action timeout
            self.assertEqual(self.pressed, [])
            self.com.attach_hook = None
            release.set()
            deadline = time.monotonic() + 5
            while worker._gate.locked() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(self.state()["app"], "powerpoint")
        self.assertEqual(self.ppt.calls, [])  # the refused "next" never ran later
        self.assertCOMBalanced()

    def test_an_action_the_caller_gave_up_on_is_never_applied_later(self):
        self.ppt.start(3)
        original = View.State.fget
        release = threading.Event()

        def slow_state(view):
            release.wait(5)
            return original(view)
        with patch.object(View, "State", property(slow_state, View.State.fset)), \
             patch.object(presentation, "ACTION_TIMEOUT", 0.3), patch.object(presentation, "DEADLINE_MARGIN", 0.1):
            body = self.act("next", status=503)
            self.assertEqual(body["detail"], presentation.NOT_RESPONDING)
            release.set()
            deadline = time.monotonic() + 5
            while self.controller.worker._gate.locked() and time.monotonic() < deadline:
                time.sleep(0.01)
        self.assertEqual(self.ppt.calls, [])
        self.assertEqual(self.ppt.position, 3)
        self.assertCOMBalanced()

    def test_job_errors_never_kill_the_worker(self):
        worker = presentation.ComWorker("test-errors")

        def explode(com):
            raise KeyError("boom")
        with self.assertRaises(presentation.PresentationError) as failure:
            worker.call(explode, timeout=2, wait=1)
        self.assertEqual(str(failure.exception), presentation.FAILED)
        self.assertEqual(worker.call(lambda com: "alive", timeout=2, wait=1), "alive")

    def test_coinitialize_failure_is_reported(self):
        def fail():
            raise OSError(signed(0x80010106), "Cannot change thread mode")
        self.com.CoInitialize = fail
        response = self.client.get("/api/presentation")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], presentation.COM_FAILED)
        self.assertEqual(self.com.uninits, 0)


class ForegroundTests(unittest.TestCase):
    def test_foreground_name_is_empty_when_windows_apis_are_missing(self):
        with patch.object(presentation, "_USER32", None), \
             patch.object(presentation.ctypes, "WinDLL", side_effect=OSError("no user32"), create=True):
            self.assertEqual(presentation._foreground_process_name(), "")

    def test_foreground_name_comes_from_the_window_process(self):
        def thread_process(window, pid_pointer):
            pid_pointer._obj.value = 4242
            return 77
        user32 = SimpleNamespace(GetForegroundWindow=lambda: 0x1234, GetWindowThreadProcessId=thread_process)
        process = SimpleNamespace(name=lambda: "POWERPNT.EXE")
        with patch.object(presentation, "_USER32", user32), \
             patch.object(presentation.psutil, "Process", return_value=process) as lookup:
            self.assertEqual(presentation._foreground_process_name(), "powerpnt.exe")
        lookup.assert_called_once_with(4242)
        with patch.object(presentation, "_USER32", SimpleNamespace(GetForegroundWindow=lambda: None)):
            self.assertEqual(presentation._foreground_process_name(), "")


class HResultTests(unittest.TestCase):
    def test_codes_are_read_from_comerror_oserror_and_args(self):
        self.assertEqual(presentation._hresult(FakeCOMError(CALL_REJECTED)), 0x80010001)
        error = OSError(MK_E_UNAVAILABLE, "unavailable")
        self.assertEqual(presentation._hresult(error), 0x800401E3)
        windows_error = OSError(0, "x")
        windows_error.winerror = DISCONNECTED
        self.assertEqual(presentation._hresult(windows_error), 0x80010108)
        self.assertIsNone(presentation._hresult(ValueError("no code")))
        self.assertTrue(presentation._is_busy(FakeCOMError(signed(0x8001010A))))
        self.assertTrue(presentation._is_gone(FakeCOMError(signed(0x800706BA))))


if __name__ == "__main__":
    unittest.main()
