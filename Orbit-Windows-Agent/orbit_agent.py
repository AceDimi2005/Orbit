"""Orbit PC Companion: authenticated local-network monitoring and controls."""
import asyncio
import copy
import ctypes
import hmac
import io
import ipaddress
import json
import logging
import os
import secrets
import socket
import subprocess
import threading
import time
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

import psutil
import uvicorn
from fastapi import FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect

from orbit_hardware import (basic_specs, collect_specs, detect_game, nvidia_metrics,
                            read_presentmon, temperature_metrics, timestamp)

try:
    import mss
    from PIL import Image
    HAS_SCREEN_CAPTURE = True
except ImportError:
    HAS_SCREEN_CAPTURE = False

try:
    import comtypes
    from pycaw.pycaw import AudioUtilities
    HAS_PYCAW = True
except (ImportError, OSError):
    HAS_PYCAW = False

LOGGER = logging.getLogger("orbit")
API_TOKEN = ""
AGENT_PORT = int(os.getenv("ORBIT_PORT", "8765"))
TOKEN_PATH = Path(os.getenv("ORBIT_TOKEN_FILE", str(Path(__file__).with_name(".orbit-token"))))
SUNSHINE_APPS_PATHS = [
    Path(os.getenv("PROGRAMDATA", "C:/ProgramData")) / "LizardByte/Sunshine/config/apps.json",
    Path(os.getenv("PROGRAMFILES", "C:/Program Files")) / "Sunshine/config/apps.json",
    Path.home() / ".config/sunshine/apps.json",
]
if os.getenv("ORBIT_SUNSHINE_APPS"):
    SUNSHINE_APPS_PATHS.insert(0, Path(os.environ["ORBIT_SUNSHINE_APPS"]))

STATE_LOCK = threading.Lock()
STOP_EVENT = threading.Event()
SPECS = {}
STATE = {
    "hostname": socket.gethostname(), "cpuName": "Unavailable", "motherboard": "Unavailable",
    "coolerName": "Unavailable", "gpuName": "Unavailable", "isOnline": True,
    "cpuTemp": None, "cpuUsage": 0.0, "liquidTemp": None, "gpuTemp": None,
    "gpuUsage": None, "gpuPowerWatts": None, "vramUsedGB": None, "vramTotalGB": None,
    "ramUsedGB": 0.0, "ramTotalGB": 0.0, "ssdUsedTB": 0.0, "ssdTotalTB": 0.0,
    "uptimeSeconds": 0, "activeGame": None, "activeGameProcess": None,
    "volume": 0.0, "isMuted": False, "volumeAvailable": False, "hdrEnabled": None,
    "fps": None, "fpsSource": None, "fpsUnavailableReason": "Waiting for telemetry",
    "telemetryAvailable": False, "lastUpdated": None,
}
LAST_TELEMETRY = 0.0


def load_api_token(path=TOKEN_PATH):
    token = os.getenv("ORBIT_API_TOKEN", "").strip()
    if not token:
        if path.exists():
            token = path.read_text(encoding="utf-8").strip()
        else:
            token = secrets.token_urlsafe(32)
            path.parent.mkdir(parents=True, exist_ok=True)
            # Exclusive creation and private permissions on platforms that support them.
            try:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                    output.write(token + "\n")
            except FileExistsError:
                token = path.read_text(encoding="utf-8").strip()
    if len(token) < 24 or token == "endspec-secret-token":
        raise RuntimeError("Orbit token must contain at least 24 characters. Remove .orbit-token to generate a new token.")
    return token


def authorized(authorization):
    return bool(API_TOKEN and isinstance(authorization, str)
                and hmac.compare_digest(authorization, f"Bearer {API_TOKEN}"))


def verify_token(authorization: str = Header(None)):
    if not authorized(authorization):
        raise HTTPException(status_code=401, detail="Invalid Orbit token", headers={"WWW-Authenticate": "Bearer"})


def require_windows():
    if os.name != "nt":
        raise HTTPException(status_code=501, detail="PC controls require Windows")


@contextmanager
def endpoint_volume():
    if not HAS_PYCAW or os.name != "nt":
        raise RuntimeError("Windows audio control is unavailable")
    comtypes.CoInitialize()
    try:
        device = AudioUtilities.GetSpeakers()
        volume = getattr(device, "EndpointVolume", None)
        if volume is None:
            # Older pycaw releases returned an IMMDevice without EndpointVolume.
            from pycaw.pycaw import IAudioEndpointVolume
            interface = device.Activate(IAudioEndpointVolume._iid_, comtypes.CLSCTX_ALL, None)
            volume = ctypes.cast(interface, ctypes.POINTER(IAudioEndpointVolume))
        yield volume
    finally:
        comtypes.CoUninitialize()


def audio_metrics():
    try:
        with endpoint_volume() as volume:
            return {"volume": round(volume.GetMasterVolumeLevelScalar() * 100, 1),
                    "isMuted": bool(volume.GetMute()), "volumeAvailable": True}
    except Exception:
        return {"volume": 0.0, "isMuted": False, "volumeAvailable": False}


def inventory_worker():
    global SPECS
    try:
        specs = collect_specs()
        with STATE_LOCK:
            SPECS = specs
            STATE["cpuName"] = specs["cpu"]["name"] or "Unavailable"
            STATE["motherboard"] = " ".join(filter(None, [specs["motherboard"]["manufacturer"], specs["motherboard"]["model"]])) or "Unavailable"
            STATE["gpuName"] = next((gpu["name"] for gpu in specs["gpus"] if gpu["name"]), "Unavailable")
    except Exception:
        LOGGER.exception("Hardware inventory failed; basic inventory remains available")


def sensor_worker():
    while not STOP_EVENT.is_set():
        try:
            sensors = temperature_metrics()
            with STATE_LOCK:
                STATE.update(sensors)
        except Exception:
            with STATE_LOCK:
                STATE.update(cpuTemp=None, liquidTemp=None)
        STOP_EVENT.wait(5)


def telemetry_worker():
    global LAST_TELEMETRY
    psutil.cpu_percent(interval=None)
    while not STOP_EVENT.wait(1):
        try:
            memory = psutil.virtual_memory()
            disk = psutil.disk_usage(os.getenv("SystemDrive", "C:") + "\\" if os.name == "nt" else "/")
            update = {
                "cpuUsage": round(psutil.cpu_percent(interval=None), 1),
                "ramUsedGB": round(memory.used / 1024 ** 3, 2), "ramTotalGB": round(memory.total / 1024 ** 3, 2),
                # Legacy field names; these describe the system volume, not an assumed SSD.
                "ssdUsedTB": round(disk.used / 1024 ** 4, 3), "ssdTotalTB": round(disk.total / 1024 ** 4, 3),
                "uptimeSeconds": max(0, int(time.time() - psutil.boot_time())),
                "gpuTemp": None, "gpuUsage": None, "gpuPowerWatts": None,
                "vramUsedGB": None, "vramTotalGB": None,
            }
            gpus = nvidia_metrics()
            if gpus:
                update.update({k: v for k, v in gpus[0].items() if k != "driverVersion"})
            game = detect_game()
            update.update(activeGame=game["name"] if game else None,
                          activeGameProcess=game["process"] if game else None)
            update.update(read_presentmon(os.getenv("ORBIT_PRESENTMON_CSV"), game))
            update.update(audio_metrics())
            update.update(telemetryAvailable=True, lastUpdated=timestamp())
            with STATE_LOCK:
                STATE.update(update)
                LAST_TELEMETRY = time.monotonic()
        except Exception:
            LOGGER.exception("Telemetry sample failed")
            with STATE_LOCK:
                STATE["telemetryAvailable"] = False
                for key in ("cpuTemp", "liquidTemp", "gpuTemp", "gpuUsage", "gpuPowerWatts", "vramUsedGB", "vramTotalGB", "fps"):
                    STATE[key] = None


@asynccontextmanager
async def lifespan(application):
    global API_TOKEN, SPECS
    API_TOKEN = load_api_token()
    SPECS = basic_specs()
    STOP_EVENT.clear()
    threads = [threading.Thread(target=worker, daemon=True) for worker in (inventory_worker, telemetry_worker, sensor_worker)]
    for thread in threads:
        thread.start()
    yield
    STOP_EVENT.set()
    for thread in threads:
        await asyncio.to_thread(thread.join, 5)


app = FastAPI(title="Orbit PC Companion Agent", version="3.0", lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/api/discover")
def discover():
    # Minimal identity only: discovery must not disclose system or network details.
    return {"service": "orbit-agent", "version": 3}


def get_local_network_details():
    """Prefer the routed interface and return only an actual adapter's MAC."""
    routed_ip = None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("1.1.1.1", 80))  # Route selection; no packet is sent.
            routed_ip = probe.getsockname()[0]
    except OSError:
        pass
    candidates = []
    stats = psutil.net_if_stats()
    for interface, addresses in psutil.net_if_addrs().items():
        if interface in stats and not stats[interface].isup:
            continue
        for address in addresses:
            if address.family != socket.AF_INET or address.address.startswith("127."):
                continue
            mac = next((a.address.replace("-", ":").upper() for a in addresses if a.family == psutil.AF_LINK), "")
            mask = address.netmask or ""
            try:
                broadcast = str(ipaddress.IPv4Network(f"{address.address}/{mask}", strict=False).broadcast_address) if mask else ""
            except ValueError:
                broadcast = ""
            candidates.append({"hostname": socket.gethostname(), "ipAddress": address.address,
                               "subnetMask": mask, "broadcastAddress": broadcast, "macAddress": mac,
                               "agentPort": AGENT_PORT})
    return next((n for n in candidates if n["ipAddress"] == routed_ip), candidates[0] if candidates else {
        "hostname": socket.gethostname(), "ipAddress": "", "subnetMask": "", "broadcastAddress": "",
        "macAddress": "", "agentPort": AGENT_PORT})


@app.get("/api/network-info")
def api_network_info(authorization: str = Header(None)):
    verify_token(authorization)
    return get_local_network_details()


@app.get("/api/specs")
def get_specs(authorization: str = Header(None)):
    verify_token(authorization)
    with STATE_LOCK:
        return copy.deepcopy(SPECS)


@app.get("/api/status")
def get_status(authorization: str = Header(None)):
    verify_token(authorization)
    with STATE_LOCK:
        result = copy.deepcopy(STATE)
        if time.monotonic() - LAST_TELEMETRY > 10:
            result["telemetryAvailable"] = False
            for key in ("cpuTemp", "liquidTemp", "gpuTemp", "gpuUsage", "gpuPowerWatts", "vramUsedGB", "vramTotalGB", "fps"):
                result[key] = None
        return result


@app.post("/api/volume")
def api_set_volume(level: int, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    if not 0 <= level <= 100:
        raise HTTPException(status_code=422, detail="Volume must be between 0 and 100")
    try:
        with endpoint_volume() as volume:
            volume.SetMasterVolumeLevelScalar(level / 100, None)
        measured = audio_metrics()
        with STATE_LOCK:
            STATE.update(measured)
        return {"status": "ok", **measured}
    except Exception as error:
        raise HTTPException(status_code=503, detail="Windows audio control is unavailable") from error


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def tap_key(vk):
    ctypes.windll.user32.keybd_event(vk, 0, 0, 0)
    ctypes.windll.user32.keybd_event(vk, 0, 2, 0)


@app.post("/api/input/mouse")
def mouse_input(dx: int = 0, dy: int = 0, click: str = "", scroll: int = 0, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    if click not in {"", "left", "double", "right"} or max(abs(dx), abs(dy)) > 10000 or abs(scroll) > 100:
        raise HTTPException(status_code=422, detail="Invalid mouse input")
    u32 = ctypes.windll.user32
    if dx or dy:
        point = POINT()
        if not u32.GetCursorPos(ctypes.byref(point)) or not u32.SetCursorPos(point.x + dx, point.y + dy):
            raise HTTPException(status_code=503, detail="Windows could not move the cursor")
    for _ in range(2 if click == "double" else 1):
        if click in {"left", "double"}:
            u32.mouse_event(0x0002, 0, 0, 0, 0)
            u32.mouse_event(0x0004, 0, 0, 0, 0)
        elif click == "right":
            u32.mouse_event(0x0008, 0, 0, 0, 0)
            u32.mouse_event(0x0010, 0, 0, 0, 0)
    if scroll:
        u32.mouse_event(0x0800, 0, 0, scroll * 120, 0)
    return {"status": "sent"}


@app.post("/api/input/keyboard")
def keyboard_input(text: str = "", key: str = "", authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    special = {"ENTER": 0x0D, "BACKSPACE": 0x08, "SPACE": 0x20, "ESC": 0x1B, "WIN": 0x5B, "TAB": 0x09}
    if (key and key.upper() not in special) or len(text) > 1000:
        raise HTTPException(status_code=422, detail="Unsupported key or text too long")
    u32 = ctypes.windll.user32
    u32.VkKeyScanW.argtypes = [ctypes.c_wchar]
    u32.VkKeyScanW.restype = ctypes.c_short
    codes = [u32.VkKeyScanW(char) if ord(char) <= 0xFFFF else -1 for char in text]
    if -1 in codes:
        raise HTTPException(status_code=422, detail="Some characters are not available in the PC keyboard layout")
    if key:
        tap_key(special[key.upper()])
    for code in codes:
        modifiers = [vk for mask, vk in ((1, 0x10), (2, 0x11), (4, 0x12)) if (code >> 8) & mask]
        for modifier in modifiers:
            u32.keybd_event(modifier, 0, 0, 0)
        tap_key(code & 0xFF)
        for modifier in reversed(modifiers):
            u32.keybd_event(modifier, 0, 2, 0)
    return {"status": "sent"}


@app.post("/api/input/gamepad")
def gamepad_input(button: str, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    keymap = {"A": 0x20, "B": 0x1B, "X": 0x45, "Y": 0x52, "UP": 0x57, "DOWN": 0x53, "LEFT": 0x41, "RIGHT": 0x44}
    if button.upper() not in keymap:
        raise HTTPException(status_code=422, detail="Unsupported gamepad button")
    tap_key(keymap[button.upper()])
    return {"status": "sent", "mode": "keyboard_mapping"}


@app.post("/api/action/{action_name}")
def execute_action(action_name: str, authorization: str = Header(None)):
    verify_token(authorization)
    actions = {"lock", "sleep", "restart", "shutdown", "mute", "media_play_pause", "media_next", "media_prev", "toggle_hdr", "restore_display", "kill_game"}
    if action_name not in actions:
        raise HTTPException(status_code=404, detail="Unknown PC action")
    require_windows()
    u32 = ctypes.windll.user32
    try:
        if action_name == "lock":
            if not u32.LockWorkStation():
                raise OSError("LockWorkStation failed")
        elif action_name == "sleep":
            # Do not force suspension; let Windows honor its power policy.
            if not ctypes.windll.powrprof.SetSuspendState(0, 0, 0):
                raise OSError("SetSuspendState failed")
        elif action_name in {"restart", "shutdown"}:
            subprocess.run(["shutdown", "/r" if action_name == "restart" else "/s", "/t", "3"], check=True,
                           timeout=5, capture_output=True, creationflags=0x08000000)
        elif action_name in {"mute", "media_play_pause", "media_next", "media_prev"}:
            tap_key({"mute": 0xAD, "media_play_pause": 0xB3, "media_next": 0xB0, "media_prev": 0xB1}[action_name])
        elif action_name == "toggle_hdr":
            u32.keybd_event(0x5B, 0, 0, 0)
            u32.keybd_event(0x12, 0, 0, 0)
            tap_key(0x42)
            u32.keybd_event(0x12, 0, 2, 0)
            u32.keybd_event(0x5B, 0, 2, 0)
            # Shortcut delivery cannot verify HDR state; hdrEnabled remains null.
        elif action_name == "restore_display":
            subprocess.Popen(["DisplaySwitch.exe", "/extend"], creationflags=0x08000000)
        elif action_name == "kill_game":
            game = detect_game()
            if not game or not game["foreground"]:
                raise HTTPException(status_code=409, detail="Bring the detected game to the foreground before closing it")
            # Close only the verified foreground game, never an arbitrary active window.
            handle = u32.GetForegroundWindow()
            pid = ctypes.c_ulong()
            u32.GetWindowThreadProcessId(handle, ctypes.byref(pid))
            if pid.value != game["pid"]:
                raise HTTPException(status_code=409, detail="The foreground application changed")
            u32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
            if not u32.PostMessageW(handle, 0x0010, 0, 0):
                raise OSError("Windows rejected close request")
    except (OSError, subprocess.SubprocessError) as error:
        raise HTTPException(status_code=503, detail="Windows could not execute this action") from error
    return {"status": "sent", "executed": action_name}


def sunshine_entries():
    for path in SUNSHINE_APPS_PATHS:
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8-sig"))
                entries = data.get("apps", [])
                if not isinstance(entries, list):
                    raise ValueError("Invalid apps list")
                return [entry for entry in entries if isinstance(entry, dict)]
            except (OSError, ValueError, AttributeError) as error:
                raise HTTPException(status_code=503, detail="Sunshine apps configuration is unreadable") from error
    return []


@app.get("/api/sunshine/apps")
def get_sunshine_apps(authorization: str = Header(None)):
    verify_token(authorization)
    return [{"id": str(index + 1), "title": entry.get("name") or f"Sunshine App {index + 1}",
             "genre": "Sunshine library", "iconSymbol": "gamecontroller.fill", "accentHex": "#57C8FF",
             "isFavorite": False} for index, entry in enumerate(sunshine_entries())]


@app.post("/api/sunshine/launch")
def launch_sunshine_app(app: str, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    for entry in sunshine_entries():
        if str(entry.get("name", "")).casefold() == app.casefold():
            detached = entry.get("detached") or []
            command = entry.get("cmd") or (detached[0] if isinstance(detached, list) and detached else None)
            if not isinstance(command, str) or not command.strip():
                raise HTTPException(status_code=409, detail="This Sunshine entry has no direct launch command. Open it in Moonlight.")
            try:
                # Only commands from the user's local Sunshine configuration are accepted.
                subprocess.Popen(command, shell=True, cwd=entry.get("working-dir") or None,
                                 creationflags=0x08000000)
            except OSError as error:
                raise HTTPException(status_code=503, detail="Could not start the configured application") from error
            return {"status": "launch_requested", "app": app}
    raise HTTPException(status_code=404, detail="Application was not found in Sunshine")


@app.websocket("/ws/stream")
async def websocket_video_stream(websocket: WebSocket):
    if not authorized(websocket.headers.get("authorization")):
        await websocket.close(code=1008)
        return
    await websocket.accept()
    if not HAS_SCREEN_CAPTURE:
        await websocket.close(code=1011, reason="Screen capture dependencies are unavailable")
        return
    try:
        with mss.mss() as capture:
            if len(capture.monitors) < 2:
                await websocket.close(code=1011, reason="No display is available")
                return
            monitor = capture.monitors[1]
            while True:
                raw = capture.grab(monitor)
                image = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
                image.thumbnail((1280, 720))
                buffer = io.BytesIO()
                image.save(buffer, format="JPEG", quality=68)
                await websocket.send_bytes(buffer.getvalue())
                await asyncio.sleep(0.05)
    except WebSocketDisconnect:
        pass
    except Exception:
        LOGGER.exception("Screen preview failed")
        try:
            await websocket.close(code=1011, reason="Screen preview failed")
        except RuntimeError:
            pass


if __name__ == "__main__":
    API_TOKEN = load_api_token()
    network = get_local_network_details()
    print(f"Orbit PC Companion · port {AGENT_PORT}")
    print(f"PC IP: {network['ipAddress'] or 'No active LAN adapter'}")
    print(f"Pairing token (enter in the iPhone app): {API_TOKEN}")
    print("Keep this token private. Use a trusted home network or VPN; do not port-forward this agent.")
    uvicorn.run(app, host=os.getenv("ORBIT_HOST", "0.0.0.0"), port=AGENT_PORT, log_level="warning", access_log=False)
