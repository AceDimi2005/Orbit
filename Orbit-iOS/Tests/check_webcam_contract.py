"""Check the iPhone webcam (DESIGN F10) against the real agent, without a PC, a camera or a simulator.

1. Fixtures come from the agent in this checkout (Orbit-Windows-Agent/orbit_webcam.py):
   * `GET /api/webcam` bodies from `status_payload` for a set-up PC, a missing Visual C++ runtime, a setup
     that waits for the Windows prompt and Windows on ARM. The PC is emulated with copies of the real,
     hash-pinned Softcam DLLs in a temporary folder and an in-memory registry; nothing on this Mac is
     touched and nothing is installed.
   * `POST /api/webcam/install` (200 and 202) and `POST /api/webcam/uninstall` through the real router
     (FastAPI TestClient, HTTPS, main token).
   * Text messages of the real `WS /ws/camera` handler: ready, connected false/true, and the errors
     badHello, replaced (a second phone) and notInstalled.
2. Orbit/OrbitWebcamPipeline.swift is compiled with Tests/OrbitWebcamTests.swift, which decodes and parses
   all of that, checks the frame pipeline (one frame on its way, frame-rate cap, stale sinks) and writes
   JPEGs of known test pictures.
3. The app's hello goes through the agent's `parse_hello`, and its JPEGs through the agent's own
   `jpeg_to_bgr` (what the PC hands to Softcam): exact size, upright, unmirrored, pillarboxed when the
   phone is held upright.

Run with the agent venv: output/.recovery-test-venv/bin/python3 Orbit-iOS/Tests/check_webcam_contract.py
"""
from pathlib import Path
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "Orbit-Windows-Agent"
TOKEN = "check-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class FakeRegistry:
    """The part of `winreg` orbit_webcam reads: HKLM keys per registry view (64-bit / 32-bit)."""
    HKEY_LOCAL_MACHINE = "HKLM"
    KEY_READ = 0x20019

    def __init__(self, webcam):
        self.views = webcam.KEY_WOW64_64KEY | webcam.KEY_WOW64_32KEY
        self.keys = {}

    def set(self, view, path, name, value):
        self.keys.setdefault((view, path.lower()), {"values": {}, "subkeys": []})["values"][name] = value
        parent, _, child = path.rpartition("\\")
        if parent:
            entry = self.keys.setdefault((view, parent.lower()), {"values": {}, "subkeys": []})
            if child not in entry["subkeys"]:
                entry["subkeys"].append(child)

    def clear(self):
        self.keys.clear()

    class Key:
        def __init__(self, entry):
            self.entry = entry

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def OpenKey(self, root, path, reserved=0, access=0):
        entry = self.keys.get((access & self.views, path.lower()))
        if root != self.HKEY_LOCAL_MACHINE or entry is None:
            raise FileNotFoundError(path)
        return self.Key(entry)

    def QueryValueEx(self, key, name):
        if name not in key.entry["values"]:
            raise FileNotFoundError(name)
        return key.entry["values"][name], 1

    def EnumKey(self, key, index):
        if index >= len(key.entry["subkeys"]):
            raise OSError("no more items")
        return key.entry["subkeys"][index]


class FakeSoftcam:
    """Softcam as orbit_webcam's camera worker calls it."""

    def __init__(self):
        self.connected = False
        self.handle = 0x5C0F0
        self.frames = 0

    def create(self, width, height, fps):
        self.handle += 1
        return self.handle

    def delete(self, camera):
        pass

    def send(self, camera, bgr):
        self.frames += 1

    def is_connected(self, camera):
        return self.connected


def emulate_pc(webcam, registry, folder, runtime=(14, 44), registered=True):
    """A Windows x64 PC where the webcam is (or isn't) set up in `folder`."""
    registry.clear()
    for arch, version in (("x64", (14, 44)), ("x86", runtime)):
        path = webcam.VC_RUNTIME_KEY + "\\" + arch  # Windows keeps both under WOW6432Node (32-bit view)
        for name, value in (("Installed", 1), ("Major", version[0]), ("Minor", version[1]), ("Bld", 35211),
                            ("Version", f"v{version[0]}.{version[1]}.35211.00")):
            registry.set(webcam.KEY_WOW64_32KEY, path, name, value)
    if registered:
        for view, name in ((webcam.KEY_WOW64_64KEY, "softcam64.dll"), (webcam.KEY_WOW64_32KEY, "softcam32.dll")):
            registry.set(view, webcam.INPROC_KEY, "", str(folder / name))
            registry.set(view, webcam.INPROC_KEY, "ThreadingModel", "Both")
            registry.set(view, webcam.CATEGORY_INSTANCE_KEY, "CLSID", webcam.CLSID)
            registry.set(view, webcam.CATEGORY_INSTANCE_KEY, "FriendlyName", webcam.CAMERA_NAME)


def build_fixtures(webcam, work, fixtures):
    from fastapi import FastAPI, Header, HTTPException, Request
    from fastapi.testclient import TestClient

    folder = work / "Program Files" / "Orbit" / "Webcam" / webcam.INSTALL_ID
    folder.mkdir(parents=True)
    for name in ("softcam64.dll", "softcam32.dll"):
        shutil.copyfile(AGENT / "webcam" / name, folder / name)  # the real, hash-pinned DLLs
    registry = FakeRegistry(webcam)
    library = FakeSoftcam()
    manager = webcam.CameraManager(library_loader=lambda: library, emit=lambda camera_format: None)
    idle = webcam.Installer(lambda progress: "installed", lambda progress: "uninstalled")

    def write(name, payload):
        (fixtures / name).write_text(json.dumps(payload))

    with patch.object(webcam, "winreg", registry), patch.object(webcam, "install_directory", lambda: folder), \
            patch.object(webcam, "native_machine", lambda: "x64"), patch.object(webcam, "process_bits", lambda: 64):
        emulate_pc(webcam, registry, folder)
        write("status-ready.json", webcam.status_payload(manager, idle))

        emulate_pc(webcam, registry, folder, runtime=(14, 40), registered=False)
        write("status-runtime.json", webcam.status_payload(manager, idle))

        class Waiting:
            installing, uninstalling, stage, last_error = True, False, "waitingForApproval", None
        emulate_pc(webcam, registry, folder, registered=False)
        write("status-waiting.json", webcam.status_payload(manager, Waiting()))

        with patch.object(webcam, "native_machine", lambda: "arm64"):
            write("status-arm.json", webcam.status_payload(manager, idle))

        # The routes, as the app calls them.
        approved = threading.Event()

        def install(progress):
            progress("waitingForApproval")
            approved.wait(10)  # the person at the PC hasn't answered the prompt yet
            emulate_pc(webcam, registry, folder)
            return "installed"

        def uninstall(progress):
            registry.clear()
            return "uninstalled"

        installer = webcam.Installer(install, uninstall)
        app = FastAPI()

        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(status_code=401, detail="Invalid Orbit token")

        def require_https(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(status_code=426, detail="Needs HTTPS")

        app.include_router(webcam.create_webcam_router(verify, require_https, lambda: None, lambda value: value == f"Bearer {TOKEN}",
                                                       boot_mode=lambda: False, manager=manager, installer=installer))
        client = TestClient(app, base_url="https://testserver")
        with patch.object(webcam, "INSTALL_WAIT_SECONDS", 0.3):
            reply = client.post("/api/webcam/install", headers=AUTH)
            assert reply.status_code == 202, (reply.status_code, reply.text)
            write("install-202.json", reply.json())
            approved.set()
            for _ in range(100):
                if not installer.installing:
                    break
                time.sleep(0.05)
            reply = client.post("/api/webcam/install", headers=AUTH)
            assert reply.status_code == 200, (reply.status_code, reply.text)
            write("install-200.json", reply.json())
        reply = client.post("/api/webcam/uninstall", headers=AUTH)
        assert reply.status_code == 200, (reply.status_code, reply.text)
        write("uninstall-200.json", reply.json())

        # The camera socket, set up again.
        emulate_pc(webcam, registry, folder)
        messages = {}
        quick = {"STATUS_INTERVAL": 0.02, "HEARTBEAT_SECONDS": 0.2, "CONNECTION_POLL_SECONDS": 0.02, "GRACE_SECONDS": 0.1}
        with patch.multiple(webcam, **quick):
            hello = json.dumps({"width": 1280, "height": 720, "fps": 30})
            with client.websocket_connect("wss://testserver/ws/camera", headers=AUTH) as socket:
                socket.send_text(hello)
                messages["ready"] = socket.receive_text()
                messages["connectedFalse"] = socket.receive_text()
                frame = io.BytesIO()
                webcam.Image.new("RGB", (1280, 720), (30, 60, 90)).save(frame, "JPEG", quality=70)
                socket.send_bytes(frame.getvalue())
                for _ in range(200):  # the camera worker converts it off the event loop
                    if library.frames:
                        break
                    time.sleep(0.01)
                assert library.frames, "the agent did not pass the JPEG frame to Softcam"
                library.connected = True
                for _ in range(100):
                    text = socket.receive_text()
                    if json.loads(text).get("connected") is True:
                        messages["connectedTrue"] = text
                        break
                # A second phone takes the camera over.
                with client.websocket_connect("wss://testserver/ws/camera", headers=AUTH) as other:
                    other.send_text(hello)
                    assert json.loads(other.receive_text()).get("ready") is True
                    for _ in range(100):
                        text = socket.receive_text()
                        if "error" in json.loads(text):
                            messages["replaced"] = text
                            break
            with client.websocket_connect("wss://testserver/ws/camera", headers=AUTH) as socket:
                socket.send_text(json.dumps({"width": 1281, "height": 720, "fps": 30}))
                messages["badHello"] = socket.receive_text()
            registry.clear()  # the webcam was removed on the PC
            with client.websocket_connect("wss://testserver/ws/camera", headers=AUTH) as socket:
                messages["notInstalled"] = socket.receive_text()
        write("messages.json", messages)
        client.close()
        manager.close()
    print(f"Fixtures from the agent in this checkout (Softcam {webcam.SOFTCAM_VERSION}, camera \"{webcam.CAMERA_NAME}\", "
          f"{len(messages)} socket messages, {library.frames} frame(s) passed to Softcam).", flush=True)


def check_output(webcam, output):
    for name, expected in (("hello-720.json", (1280, 720, 30)), ("hello-1080.json", (1920, 1080, 15))):
        parsed = webcam.parse_hello((output / name).read_text())
        assert parsed == expected, f"{name}: the agent read {parsed}"

    def color(pixel, name):
        b, g, r = pixel
        return {"red": r > 180 and g < 80 and b < 80, "blue": b > 180 and r < 80 and g < 80,
                "green": g > 180 and r < 80 and b < 80, "yellow": r > 180 and g > 180 and b < 80,
                "black": r < 40 and g < 40 and b < 40, "grey": 90 < r < 170 and 90 < g < 170 and 90 < b < 170}[name]

    width, height = 1280, 720
    for name in ("landscape", "portrait", "downscaled"):
        data = (output / f"{name}.jpg").read_bytes()
        assert webcam.is_jpeg(data), f"{name}: not JPEG"
        with webcam.Image.open(io.BytesIO(data)) as image:
            assert image.size == (width, height), f"{name}: {image.size}"
        bgr = webcam.jpeg_to_bgr(data, width, height)  # exactly what the PC hands to Softcam
        assert len(bgr) == width * height * 3

        def at(x, y):
            offset = (int(y) * width + int(x)) * 3
            return tuple(bgr[offset:offset + 3])

        # The picture's area: all of it, or the centred 9:16 column when the phone was upright.
        inner = height * 9 / 16 if name == "portrait" else width
        left, right = (width - inner) / 2, (width + inner) / 2
        band = min(inner, height) * 0.1
        checks = {"top is red (upright)": (at(width / 2, band / 2), "red"),
                  "bottom is blue": (at(width / 2, height - band / 2), "blue"),
                  "left is green (unmirrored)": (at(left + band / 2, height / 2), "green"),
                  "right is yellow": (at(right - band / 2, height / 2), "yellow"),
                  "middle is grey": (at(width / 2, height / 2), "grey")}
        if name == "portrait":
            checks["pillarbox left is black"] = (at(left / 2, height / 2), "black")
            checks["pillarbox right is black"] = (at((right + width) / 2, height / 2), "black")
        for label, (pixel, expected) in checks.items():
            assert color(pixel, expected), f"{name}: {label} failed, found BGR {pixel}"


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-webcam-") as directory:
        work = Path(directory)
        os.environ["LOCALAPPDATA"] = str(work / "LocalAppData")  # the agent's data folder (never this Mac's)
        os.environ["APPDATA"] = str(work / "AppData")
        sys.path.insert(0, str(AGENT))
        import orbit_webcam as webcam

        fixtures, output = work / "fixtures", work / "output"
        fixtures.mkdir()
        output.mkdir()
        build_fixtures(webcam, work, fixtures)
        binary = work / "webcam-tests"
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                        str(ROOT / "Orbit-iOS/Orbit/OrbitWebcamPipeline.swift"),
                        str(ROOT / "Orbit-iOS/Tests/OrbitWebcamTests.swift"),
                        "-o", str(binary)], check=True)
        result = subprocess.run([str(binary), str(fixtures), str(output)], capture_output=True, text=True, timeout=300)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            raise SystemExit(f"OrbitWebcamTests failed ({result.returncode})")
        check_output(webcam, output)
        print("PASS: the agent parses the app's hello (720p30, 1080p15) and turns its JPEGs (landscape, upright phone, "
              "bigger capture) into upright, unmirrored 1280x720 frames, pillarboxed for an upright phone")


if __name__ == "__main__":
    main()
