"""Phone JPEG stream to an explicitly configured v4l2loopback camera.

Kernel module setup belongs to the local administrator/package manager. Nothing
here installs a driver, takes over a physical webcam, or invokes a privileged tool.
"""
import importlib.util
import os
from pathlib import Path
import re

from fastapi import APIRouter, Depends, HTTPException, Response, WebSocket
import orbit_webcam

CAMERA_NAME = "Orbit Camera"
SETUP = "Configure a writable v4l2loopback device named 'Orbit Camera', or set ORBIT_WEBCAM_DEVICE to its /dev/videoN path. See the Linux setup guide."


class LinuxWebcam:
    def __init__(self, environment=None, sysfs="/sys/devices/virtual/video4linux", manager=None):
        self.environment = os.environ if environment is None else environment
        self.sysfs = Path(sysfs)
        self.manager = manager or orbit_webcam.CameraManager(library_loader=lambda: V4L2Library(self.device))

    def device(self):
        selected = self.environment.get("ORBIT_WEBCAM_DEVICE")
        if selected and not re.fullmatch(r"/dev/video[0-9]+", selected):
            raise RuntimeError("ORBIT_WEBCAM_DEVICE must be a /dev/videoN path.")
        for entry in sorted(self.sysfs.glob("video*")):
            if not re.fullmatch(r"video[0-9]+", entry.name):
                continue
            try:
                name = (entry / "name").read_text().strip()
            except OSError:
                continue
            path = f"/dev/{entry.name}"
            if path == selected or (selected is None and name == CAMERA_NAME):
                if not os.access(path, os.R_OK | os.W_OK):
                    raise RuntimeError(f"Your desktop user needs read/write access to {path}. Check the device ACL or video group.")
                return path
        raise RuntimeError(SETUP)

    def readiness(self, boot_mode=False):
        if importlib.util.find_spec("pyvirtualcam") is None:
            return ("notInstalled", "Install Orbit's Linux Python dependencies (pyvirtualcam is missing).", orbit_webcam.CLOSE_NOT_INSTALLED)
        try:
            self.device()
        except RuntimeError as error:
            return ("notInstalled", str(error), orbit_webcam.CLOSE_NOT_INSTALLED)
        return None

    def status(self):
        problem = self.readiness()
        return {**self.manager.snapshot(), "installed": problem is None, "registered": problem is None,
                "reason": problem[1] if problem else None, "cameraName": self.camera_name(), "softcamVersion": None,
                "installing": False, "uninstalling": False, "installStage": None, "installError": None,
                "runtime": None, "limits": dict(orbit_webcam.LIMITS), "backend": "v4l2loopback",
                "connectionStatusAvailable": False, "setupManagedExternally": True}

    def camera_name(self):
        try:
            return (self.sysfs / Path(self.device()).name / "name").read_text().strip()
        except (OSError, RuntimeError):
            return CAMERA_NAME

    def router(self, verify_control, require_https, authorized):
        router = APIRouter()
        guards = [Depends(verify_control), Depends(require_https)]

        @router.get("/api/webcam", dependencies=guards)
        def status(response: Response):
            response.headers["Cache-Control"] = "no-store"
            return self.status()

        @router.post("/api/webcam/install", dependencies=guards)
        @router.post("/api/webcam/uninstall", dependencies=guards)
        def setup():
            raise HTTPException(501, "Linux camera setup and removal are managed locally by your distribution. " + SETUP)

        @router.websocket("/ws/camera")
        async def stream(websocket: WebSocket):
            await orbit_webcam.handle_camera_socket(websocket, authorized=authorized, manager=self.manager,
                                                    readiness=self.readiness, camera_name=self.camera_name())

        return router


class V4L2Library:
    def __init__(self, device):
        self.device = device

    def create(self, width, height, fps):
        try:
            import pyvirtualcam
            return pyvirtualcam.Camera(width=width, height=height, fps=fps, fmt=pyvirtualcam.PixelFormat.BGR,
                                       device=self.device(), backend="v4l2loopback")
        except (ImportError, OSError, RuntimeError) as error:
            raise orbit_webcam.CameraError("cameraUnavailable", "Could not open the Linux virtual camera. Check device permissions and close other producers such as OBS.",
                                           orbit_webcam.CLOSE_CAMERA_UNAVAILABLE) from error

    @staticmethod
    def send(camera, bgr):
        import numpy as np
        camera.send(np.frombuffer(bgr, dtype=np.uint8).reshape((camera.height, camera.width, 3)))

    @staticmethod
    def delete(camera):
        camera.close()

    @staticmethod
    def is_connected(camera):
        # v4l2loopback/pyvirtualcam cannot reliably report consumer presence.
        # Sending does not depend on this flag. Never invent a connected app.
        return False
