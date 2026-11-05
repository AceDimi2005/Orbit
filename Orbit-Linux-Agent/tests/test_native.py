"""Native backend contracts with fake transports/devices, never the desktop."""
import asyncio
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Orbit-Linux-Agent"), str(ROOT / "Orbit-Windows-Agent")]
from fastapi import HTTPException
from orbit_linux_backend import LinuxDesktop
from orbit_linux_pointer import PointerUnavailable, WaylandPointer
from orbit_linux_webcam import LinuxWebcam, V4L2Library
import orbit_webcam


class SelectionTests(unittest.TestCase):
    def desktop(self, factory):
        self.commands = Mock()
        return LinuxDesktop(self.commands, {"WAYLAND_DISPLAY": "fake"}, pointer_factory=factory)

    def test_native_pointer_persists_until_disconnect(self):
        pointer = Mock()
        factory = Mock(return_value=pointer)
        desktop = self.desktop(factory)
        desktop.cursor(dx=5, drag="down")
        desktop.cursor(dy=7)
        self.assertEqual(factory.call_count, 1)
        self.assertEqual(pointer.cursor.call_count, 2)
        desktop.release_input()
        pointer.close.assert_called_once()
        self.commands.run.assert_not_called()

    def test_unsupported_compositor_falls_back_before_input_only(self):
        factory = Mock(side_effect=PointerUnavailable("not supported"))
        desktop = self.desktop(factory)
        desktop.cursor(dx=5)
        desktop.cursor(dx=6)
        self.assertEqual(factory.call_count, 1)
        self.assertEqual(self.commands.run.call_count, 2)

    def test_failed_native_input_is_not_replayed(self):
        pointer = Mock()
        pointer.cursor.side_effect = OSError("disconnected")
        desktop = self.desktop(lambda: pointer)
        with self.assertRaises(HTTPException):
            desktop.cursor(click="left")
        pointer.close.assert_called_once()
        self.commands.run.assert_not_called()

    def test_forced_native_never_falls_back(self):
        desktop = self.desktop(Mock(side_effect=PointerUnavailable("denied")))
        desktop.pointer_backend = "wayland"
        with self.assertRaises(HTTPException):
            desktop.cursor(dx=1)
        self.commands.run.assert_not_called()

    def test_direct_touch_requires_a_captured_named_output(self):
        pointer = Mock()
        desktop = self.desktop(lambda: pointer)
        desktop.capture = Mock(output_name=None)
        with self.assertRaises(HTTPException):
            desktop.cursor(norm_x=.5, norm_y=.5)
        pointer.cursor.assert_not_called()
        desktop.capture.output_name = "DP-2"
        desktop.cursor(norm_x=.5, norm_y=.5)
        self.assertEqual(pointer.cursor.call_args.args[-1], "DP-2")


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        # Construct without connecting to any socket.
        self.native = WaylandPointer.__new__(WaylandPointer)
        self.native.display = Mock()
        self.native.manager = Mock()
        self.native.manager_version = 2
        self.native.pointer = None
        self.native.held = set()
        self.native.bound_output = None
        self.native.outputs = {8: {"name": "DP-2", "proxy": Mock()}}
        self.native._sync = Mock()

    def test_absolute_input_binds_captured_output(self):
        self.native.cursor(norm_x=1, norm_y=0, output="DP-2", click="left")
        self.native.manager.create_virtual_pointer_with_output.assert_called_once_with(None, self.native.outputs[8]["proxy"])
        self.assertEqual(self.native.pointer.motion_absolute.call_args.args[1:], (65535, 0, 65536, 65536))
        self.assertEqual([call.args[1:] for call in self.native.pointer.button.call_args_list], [(272, 1), (272, 0)])

    def test_unplugged_output_refuses_click(self):
        with self.assertRaises(PointerUnavailable):
            self.native.cursor(norm_x=.5, norm_y=.5, output="gone", click="left")
        self.native.manager.create_virtual_pointer_with_output.assert_not_called()

    def test_drag_is_released_before_connection_closes(self):
        self.native.cursor(drag="down")
        pointer = self.native.pointer
        display = self.native.display
        self.native.close()
        self.assertEqual([call.args[1:] for call in pointer.button.call_args_list], [(272, 1), (272, 0)])
        display.disconnect.assert_called_once()

    def test_scroll_polarity_uses_wayland_axis_convention(self):
        self.native.cursor(scroll=2, hscroll=-1)
        self.assertEqual([call.args[1:] for call in self.native.pointer.axis_discrete.call_args_list], [(0, -30., -2), (1, -15., -1)])


class WebcamTests(unittest.TestCase):
    def test_only_designated_virtual_camera_is_selected(self):
        with tempfile.TemporaryDirectory() as tmp, patch("orbit_linux_webcam.os.access", return_value=True):
            base = Path(tmp)
            for number, label in ((0, "Another Camera"), (10, "Orbit Camera")):
                folder = base / f"video{number}"
                folder.mkdir()
                (folder / "name").write_text(label)
            camera = LinuxWebcam({}, sysfs=tmp)
            self.assertEqual(camera.device(), "/dev/video10")
            self.assertEqual(camera.camera_name(), "Orbit Camera")
            camera.environment["ORBIT_WEBCAM_DEVICE"] = "/dev/video0"
            self.assertEqual(camera.device(), "/dev/video0")
            camera.environment["ORBIT_WEBCAM_DEVICE"] = "/dev/../etc/passwd"
            with self.assertRaises(RuntimeError):
                camera.device()

    def test_missing_device_status_is_actionable_and_never_connected(self):
        with tempfile.TemporaryDirectory() as tmp:
            camera = LinuxWebcam({}, sysfs=tmp)
            status = camera.status()
            self.assertFalse(status["installed"])
            self.assertIn("v4l2loopback", status["reason"])
            self.assertFalse(status["connectionStatusAvailable"])
            self.assertTrue(status["setupManagedExternally"])

    def test_bgr_bytes_keep_shape_and_channel_order(self):
        camera = Mock(width=2, height=1)
        V4L2Library.send(camera, bytes([1, 2, 3, 4, 5, 6]))
        frame = camera.send.call_args.args[0]
        self.assertEqual(frame.shape, (1, 2, 3))
        self.assertEqual(frame.tolist(), [[[1, 2, 3], [4, 5, 6]]])
        V4L2Library.delete(camera)
        camera.close.assert_called_once()
        self.assertFalse(V4L2Library.is_connected(camera))

    def test_camera_opens_only_explicit_loopback_backend(self):
        library = Mock()
        with patch.dict(sys.modules, {"pyvirtualcam": library}):
            adapter = V4L2Library(lambda: "/dev/video10")
            camera = adapter.create(1280, 720, 30)
            library.Camera.assert_called_once_with(width=1280, height=720, fps=30, fmt=library.PixelFormat.BGR,
                                                  device="/dev/video10", backend="v4l2loopback")
            self.assertIs(camera, library.Camera.return_value)

    def test_shared_worker_converts_jpeg_and_closes_camera(self):
        from PIL import Image
        import threading
        sent = threading.Event()
        device = Mock(width=160, height=120)
        device.send.side_effect = lambda frame: sent.set()
        backend = V4L2Library(lambda: "/dev/video10")
        backend.create = Mock(return_value=device)
        manager = orbit_webcam.CameraManager(library_loader=lambda: backend, emit=lambda *_: None)
        try:
            manager.start_sender("phone", (160, 120, 15)).result(timeout=2)
            frame = io.BytesIO()
            Image.new("RGB", (160, 120), "red").save(frame, "JPEG")
            manager.submit_frame("phone", frame.getvalue())
            self.assertTrue(sent.wait(2))
            pixel = device.send.call_args.args[0][0, 0]
            self.assertGreater(int(pixel[2]), 240)  # red remains red after BGR conversion
        finally:
            manager.close()
        device.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
