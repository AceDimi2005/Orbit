"""Headless Qt checks; uses synthetic frames, never captures the real desktop."""
import io
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Orbit-Linux-Agent"), str(ROOT / "Orbit-Windows-Agent")]
from PySide6.QtCore import Qt
from PySide6.QtGui import QImage
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QMessageBox
from orbit_linux import Startup
from orbit_linux_tray import ScreenCapture, Tray

APP = QApplication.instance() or QApplication([])
APP.setQuitOnLastWindowClosed(False)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        # Prevent the real portal from ever opening during tests.
        self.activate = patch.object(ScreenCapture, "_activate")
        self.activate.start()
        self.capture = ScreenCapture()

    def tearDown(self):
        self.capture.stop()
        self.activate.stop()

    def test_synthetic_frame_is_bounded_jpeg(self):
        from PIL import Image
        image = QImage(1920, 1080, QImage.Format.Format_RGB32)
        image.fill(Qt.GlobalColor.blue)
        self.capture.start()
        self.capture._frame(Mock(isValid=lambda: True, toImage=lambda: image))
        result = self.capture.frame(.1)
        with Image.open(io.BytesIO(result)) as decoded:
            self.assertEqual(decoded.format, "JPEG")
            self.assertEqual(decoded.size, (1280, 720))

    def test_stop_unblocks_waiter_and_discards_frames(self):
        self.capture.start()
        results = []
        def wait():
            try:
                self.capture.frame(30)
            except RuntimeError:
                results.append("stopped")
        thread = threading.Thread(target=wait)
        thread.start()
        self.capture.stop()
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results, ["stopped"])
        self.assertIsNone(self.capture.latest)

    def test_portal_failure_and_timeout_do_not_reuse_stale_frame(self):
        self.capture.start()
        with self.assertRaises(TimeoutError):
            self.capture.frame(.01)
        self.capture._failed(None, "Permission denied")
        with self.assertRaisesRegex(RuntimeError, "Permission denied"):
            self.capture.frame(.01)
        self.capture.start()
        with self.assertRaises(TimeoutError):
            self.capture.frame(.01)

    def test_native_screen_requires_local_consent_before_capture(self):
        self.capture.commands = Mock()
        self.capture.select_output("DP-2")
        self.capture.start()
        with self.assertRaises(TimeoutError):
            self.capture.frame(.01)
        self.capture.commands.run.assert_not_called()
        self.assertIsNone(self.capture.output_name)
        self.capture._request_native_consent("DP-2", self.capture.generation)
        self.capture.consent.done(QMessageBox.StandardButton.No)
        with self.assertRaisesRegex(RuntimeError, "declined"):
            self.capture.frame(.01)
        self.capture.commands.run.assert_not_called()

    def test_native_frame_and_input_use_the_same_output(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGB", (1920, 1080), "red").save(data, "JPEG")
        self.capture.commands = Mock()
        self.capture.commands.run.return_value = data.getvalue()
        self.capture.select_output("DP-2")
        self.capture.start()
        self.capture._request_native_consent("DP-2", self.capture.generation)
        self.capture.consent.done(QMessageBox.StandardButton.Yes)
        result = self.capture.frame(.1)
        self.assertEqual(self.capture.output_name, "DP-2")
        self.assertEqual(self.capture.commands.run.call_args.args[:3], ("grim", "-o", "DP-2"))
        with Image.open(io.BytesIO(result)) as picture:
            self.assertEqual(picture.size, (1280, 720))
        self.capture.stop()
        self.assertIsNone(self.capture.output_name)

    def test_stopped_native_capture_discards_inflight_frame(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGB", (160, 120)).save(data, "JPEG")
        def capture(*args, **kwargs):
            self.capture.stop()
            return data.getvalue()
        self.capture.commands = Mock(run=capture)
        self.capture.select_output("DP-2")
        self.capture.start()
        self.capture.approved_output = "DP-2"
        with self.assertRaisesRegex(RuntimeError, "stopped"):
            self.capture.frame(.1)
        self.assertIsNone(self.capture.output_name)


class TrayTests(unittest.TestCase):
    def test_pin_is_plain_text_and_is_dismissed_when_consumed(self):
        with tempfile.TemporaryDirectory() as tmp, patch("orbit_linux_tray.QSystemTrayIcon.isSystemTrayAvailable", return_value=True):
            agent = Mock(API_TOKEN="private-token")
            tray = Tray(agent, Mock(), Startup(directory=tmp), Path(tmp) / "agent.log")
            cancel = tray.show_pin('<b>Phone</b>', '123456')
            APP.processEvents()
            self.assertEqual(len(tray.dialogs), 1)
            label = tray.dialogs[0].findChild(QLabel)
            self.assertEqual(label.textFormat(), Qt.TextFormat.PlainText)
            self.assertIn('123456', label.text())
            cancel()
            QTest.qWait(250)
            APP.processEvents()
            self.assertEqual(tray.dialogs, [])
            tray.close()


if __name__ == "__main__":
    unittest.main()
