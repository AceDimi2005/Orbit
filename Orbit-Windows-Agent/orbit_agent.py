"""Orbit PC Companion: authenticated local-network monitoring and controls."""
import asyncio
import base64
import copy
import ctypes
import hmac
import io
import ipaddress
import json
import logging
import math
import os
import secrets
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime
from pathlib import Path

if __name__ == "__main__":
    # Run as a script, this module is `__main__`. Feature modules that `import orbit_agent`
    # (power hooks, automation calling perform_action) must get this running module and its
    # globals, not a second copy executed from scratch.
    sys.modules.setdefault("orbit_agent", sys.modules[__name__])

import psutil
import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

import orbit_alerts
import orbit_downloads
import orbit_energy
import orbit_events
import orbit_input
import orbit_links
import orbit_notify
import orbit_power_after
import orbit_power_countdown
import orbit_push
import orbit_tasks
import orbit_summary
import orbit_webcam
from orbit_capabilities import capabilities_payload, register_feature, set_agent_version
from orbit_deck import create_deck_router
from orbit_events import EventLog, create_events_router
from orbit_processes import collect_processes, terminate_process
from orbit_icons import ICON_PIXELS, ICONS, MAX_IDS_PER_REQUEST, parse_icon_ids
from orbit_files import create_files_router
from orbit_desktop import create_desktop_router
from orbit_history import SessionRecorder, create_history_router
from orbit_pairing import PairingManager, OrbitAdvertisement, create_pairing_router

from orbit_hardware import (GPU_SENSOR_FIELDS, IOCounterRates, RATE_FIELDS, SENSOR_FIELDS, basic_specs,
                            collect_specs, detect_game, io_metrics, nvidia_metrics,
                            read_fps, sensor_metrics, timestamp)

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

AGENT_VERSION = "4.6.0b1"
set_agent_version(AGENT_VERSION)
LOGGER = logging.getLogger("orbit")
API_TOKEN = ""
WIDGET_TOKEN = ""
AGENT_PORT = int(os.getenv("ORBIT_PORT", "8765"))
SECURE_PORT = int(os.getenv("ORBIT_TLS_PORT", "8766"))
PAIRING_MANAGER = None
ADVERTISEMENT = None
# True when started by the boot task (before anyone signs in): no tray icon, hands over to the
# per-user instance once that starts.
BOOT_MODE = False
CERTIFICATE_FINGERPRINT = ""
import sys as _sys
_RUNTIME_DIR = Path(_sys.executable).resolve().parent if getattr(_sys, "frozen", False) else Path(__file__).resolve().parent
TOKEN_PATH = Path(os.getenv("ORBIT_TOKEN_FILE", str(_RUNTIME_DIR / ".orbit-token")))
WIDGET_TOKEN_PATH = Path(os.getenv("ORBIT_WIDGET_TOKEN_FILE", str(_RUNTIME_DIR / ".orbit-widget-token")))
SUNSHINE_APPS_PATHS = [
    Path(os.getenv("PROGRAMDATA", "C:/ProgramData")) / "LizardByte/Sunshine/config/apps.json",
    Path(os.getenv("PROGRAMFILES", "C:/Program Files")) / "Sunshine/config/apps.json",
    Path.home() / ".config/sunshine/apps.json",
]
if os.getenv("ORBIT_SUNSHINE_APPS"):
    SUNSHINE_APPS_PATHS.insert(0, Path(os.environ["ORBIT_SUNSHINE_APPS"]))
SUNSHINE_CONF_PATHS = [path.with_name("sunshine.conf") for path in SUNSHINE_APPS_PATHS]
if os.getenv("ORBIT_SUNSHINE_CONF"):
    SUNSHINE_CONF_PATHS.insert(0, Path(os.environ["ORBIT_SUNSHINE_CONF"]))
# Sunshine's web UI login, saved from the app so Orbit can enter pairing PINs itself.
SUNSHINE_CREDENTIALS_PATH = Path(os.getenv("ORBIT_SUNSHINE_LOGIN_FILE", str(_RUNTIME_DIR / ".orbit-sunshine-login")))
SUNSHINE_EXECUTABLE_PATHS = [
    Path(os.getenv("PROGRAMFILES", "C:/Program Files")) / "Sunshine/sunshine.exe",
    Path(os.getenv("PROGRAMFILES(X86)", "C:/Program Files (x86)")) / "Sunshine/sunshine.exe",
]

STATE_LOCK = threading.Lock()
STOP_EVENT = threading.Event()
SPECS = {}
SENSOR_GPU_CACHE = {}
STATE = {
    "agentVersion": AGENT_VERSION, "sensorSource": None, "sensorStatus": None, "gpuSource": None,
    "networkInterface": None,
    "hostname": socket.gethostname(), "cpuName": "Unavailable", "motherboard": "Unavailable",
    "coolerName": "Unavailable", "gpuName": "Unavailable", "isOnline": True,
    "cpuTemp": None, "cpuUsage": 0.0, "liquidTemp": None, "gpuTemp": None,
    "gpuUsage": None, "gpuPowerWatts": None, "vramUsedGB": None, "vramTotalGB": None,
    "ramUsedGB": 0.0, "ramTotalGB": 0.0, "ssdUsedTB": 0.0, "ssdTotalTB": 0.0,
    "uptimeSeconds": 0, "activeGame": None, "activeGameProcess": None,
    "volume": 0.0, "isMuted": False, "volumeAvailable": False, "hdrEnabled": None, "sessionLocked": None,
    "fps": None, "fpsSource": None, "fpsUnavailableReason": "Waiting for telemetry",
    "telemetryAvailable": False, "lastUpdated": None,
    "cpuPowerWatts": None, "cpuClockMHz": None, "cpuClockSource": None,
    "cpuFanRPM": None, "gpuFanPercent": None,
    "diskReadMBps": None, "diskWriteMBps": None,
    "networkUploadMBps": None, "networkDownloadMBps": None,
}
LAST_TELEMETRY = 0.0
LAST_SENSOR = 0.0
HISTORY_RECORDER = None
LIVE_OPTIONAL_FIELDS = SENSOR_FIELDS + RATE_FIELDS + (
    "gpuTemp", "gpuUsage", "gpuPowerWatts", "gpuFanPercent", "vramUsedGB", "vramTotalGB", "gpuSource", "networkInterface", "fps", "fpsSource",
)


def load_token_file(path):
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation and private permissions on platforms that support them.
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(token + "\n")
    except FileExistsError:
        token = path.read_text(encoding="utf-8").strip()
    return token


def load_api_token(path=TOKEN_PATH):
    token = os.getenv("ORBIT_API_TOKEN", "").strip() or load_token_file(path)
    if len(token) < 24 or token == "endspec-secret-token":
        raise RuntimeError("Orbit token must contain at least 24 characters. Remove .orbit-token to generate a new token.")
    return token


def load_widget_token(path=WIDGET_TOKEN_PATH):
    token = load_token_file(path)
    if len(token) < 24 or token == API_TOKEN:
        raise RuntimeError("Orbit widget token must be a separate secret of at least 24 characters. Remove .orbit-widget-token to regenerate it.")
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


def require_https(request: Request):
    """Newer features answer only on the encrypted port; plain HTTP gets 426."""
    if request.url.scheme != "https":
        raise HTTPException(status_code=426, detail="This needs Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")


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
    global LAST_SENSOR
    while not STOP_EVENT.is_set():
        try:
            sensors = sensor_metrics()
            with STATE_LOCK:
                # Sensor polling never overwrites newer NVIDIA readings.
                STATE.update({key: sensors.get(key) for key in SENSOR_FIELDS + ("sensorSource", "sensorStatus")})
                SENSOR_GPU_CACHE.clear()
                SENSOR_GPU_CACHE.update({key: sensors.get(key) for key in GPU_SENSOR_FIELDS})
                SENSOR_GPU_CACHE["gpuName"] = sensors.get("gpuSensorName")
                SENSOR_GPU_CACHE["gpuSource"] = sensors.get("gpuSensorSource") or sensors.get("sensorSource")
                LAST_SENSOR = time.monotonic()
        except Exception:
            with STATE_LOCK:
                STATE.update(dict.fromkeys(SENSOR_FIELDS))
                STATE["sensorSource"] = None
                STATE["sensorStatus"] = "Hardware sensors unavailable. Start MSI Afterburner and enable Monitoring, or use LibreHardwareMonitor with its local web server on port 8085."
                SENSOR_GPU_CACHE.clear()
        STOP_EVENT.wait(5)


def select_gpu_metrics(nvidia, sensor_cache, sensor_age):
    """Keep one adapter/source per sample, preferring the driver's NVIDIA data."""
    result = dict.fromkeys(GPU_SENSOR_FIELDS + ("gpuSource",))
    if nvidia:
        result.update({key: value for key, value in nvidia[0].items() if key != "driverVersion"})
        result["gpuSource"] = "NVIDIA SMI"
    elif sensor_age <= 15 and any(sensor_cache.get(key) is not None for key in GPU_SENSOR_FIELDS):
        result.update({key: sensor_cache.get(key) for key in GPU_SENSOR_FIELDS})
        result["gpuName"] = sensor_cache.get("gpuName") or "GPU · hardware monitor"
        result["gpuSource"] = sensor_cache.get("gpuSource") or "Hardware monitor"
    return result


def telemetry_worker():
    global LAST_TELEMETRY
    psutil.cpu_percent(interval=None)
    rates = IOCounterRates()
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
                "vramUsedGB": None, "vramTotalGB": None, "gpuFanPercent": None,
            }
            update.update(io_metrics(rates))
            gpus = nvidia_metrics()
            with STATE_LOCK:
                sensor_cache = copy.deepcopy(SENSOR_GPU_CACHE)
                sensor_age = time.monotonic() - LAST_SENSOR
            update.update(select_gpu_metrics(gpus, sensor_cache, sensor_age))
            game = detect_game()
            update.update(activeGame=game["name"] if game else None,
                          activeGameProcess=game["process"] if game else None)
            update.update(read_fps(game))
            update.update(audio_metrics())
            update.update(sessionLocked=session_locked(), telemetryAvailable=True, lastUpdated=timestamp())
            with STATE_LOCK:
                STATE.update(update)
                LAST_TELEMETRY = time.monotonic()
            snapshot = status_snapshot()
            record_history(snapshot)
            orbit_alerts.observe(snapshot)  # temperature alerts; never raises
        except Exception:
            LOGGER.exception("Telemetry sample failed")
            with STATE_LOCK:
                STATE["telemetryAvailable"] = False
                for key in LIVE_OPTIONAL_FIELDS:
                    STATE[key] = None
            record_history({"telemetryAvailable": False})


def session_locked():
    """True while Windows shows the sign-in or lock screen (LogonUI is only alive then); None elsewhere."""
    if os.name != "nt":
        return None
    try:
        return any((proc.info.get("name") or "").lower() == "logonui.exe" for proc in psutil.process_iter(["name"]))
    except Exception:
        return None


def record_history(metrics):
    recorder = HISTORY_RECORDER
    if recorder is not None:
        try:
            recorder.record_sample(metrics)
        except Exception:
            LOGGER.exception("Could not save this session sample")
    # Energy ledger and monthly summary (every tick, also without a history session; never raises).
    orbit_energy.record_tick(metrics)


@asynccontextmanager
async def lifespan(application):
    global API_TOKEN, WIDGET_TOKEN, SPECS, HISTORY_RECORDER
    API_TOKEN = load_api_token()
    WIDGET_TOKEN = load_widget_token()
    SPECS = basic_specs()
    HISTORY_RECORDER = SessionRecorder()
    try:
        event_log = EventLog()
    except Exception:
        LOGGER.exception("The event log could not be opened; notifications from this PC are unavailable")
        event_log = None
    orbit_events.set_event_log(event_log)
    orbit_energy.start(extra_trackers=(orbit_summary.GameTracker,), boot_mode=BOOT_MODE)
    STOP_EVENT.clear()
    threads = [threading.Thread(target=worker, daemon=True) for worker in (inventory_worker, telemetry_worker, sensor_worker)]
    for thread in threads:
        thread.start()
    stop_notification_features = start_notification_features()
    if ADVERTISEMENT is not None:
        try:
            await asyncio.to_thread(ADVERTISEMENT.start)
        except Exception:
            LOGGER.exception("Automatic discovery unavailable; manual pairing is still available")
    yield
    STOP_EVENT.set()
    if PAIRING_MANAGER is not None:
        PAIRING_MANAGER.close()
    if ADVERTISEMENT is not None:
        await asyncio.to_thread(ADVERTISEMENT.close)
    for thread in threads:
        await asyncio.to_thread(thread.join, 5)
    await asyncio.to_thread(stop_notification_features)
    recorder, HISTORY_RECORDER = HISTORY_RECORDER, None
    if recorder is not None:
        recorder.close()
    await asyncio.to_thread(orbit_energy.stop)
    orbit_events.set_event_log(None)
    await asyncio.to_thread(orbit_events.flush_dispatch, 2.0)
    if event_log is not None:
        event_log.close()


app = FastAPI(title="Orbit PC Companion Agent", version=AGENT_VERSION, lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(create_files_router(verify_token))
app.include_router(create_desktop_router(verify_token))
app.include_router(create_history_router(verify_token, lambda: HISTORY_RECORDER,
                                         detail_extras=orbit_energy.session_energy_extras))
app.include_router(create_pairing_router(lambda: PAIRING_MANAGER))
app.include_router(create_events_router(verify_token, orbit_events.current_log))
register_feature("events")


@app.get("/api/capabilities")
def get_capabilities(authorization: str = Header(None)):
    """Optional features this agent has; clients treat a 404 as an older agent without any."""
    verify_token(authorization)
    return capabilities_payload(AGENT_VERSION)


@app.get("/api/discover")
def discover():
    # Public bootstrap hints only. Secrets and network configuration require PIN proof.
    return {"service": "orbit-agent", "version": 3, "agentVersion": AGENT_VERSION,
            "name": socket.gethostname(), "securePort": SECURE_PORT,
            "fingerprint": CERTIFICATE_FINGERPRINT, "pairingAvailable": PAIRING_MANAGER is not None}


def get_local_network_details(preferred_ip=None):
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
    return next((n for n in candidates if n["ipAddress"] == preferred_ip), None) or next((n for n in candidates if n["ipAddress"] == routed_ip), candidates[0] if candidates else {
        "hostname": socket.gethostname(), "ipAddress": "", "subnetMask": "", "broadcastAddress": "",
        "macAddress": "", "agentPort": AGENT_PORT})


def pairing_payload(host):
    return {**get_local_network_details(host), "securePort": SECURE_PORT,
            "apiToken": API_TOKEN, "widgetToken": WIDGET_TOKEN, "agentVersion": AGENT_VERSION}


# Tailscale gives every device an address in the CGNAT range 100.64.0.0/10.
TAILSCALE_NETWORK = ipaddress.IPv4Network("100.64.0.0/10")


def tailscale_addresses():
    """IPv4 addresses this PC has on Tailscale, so the apps can offer one as the PC's "Secondary IP"
    (used when its LAN address does not answer). Adapters named Tailscale come first; empty without it."""
    found = []
    try:
        stats = psutil.net_if_stats()
        for interface, addresses in psutil.net_if_addrs().items():
            if interface in stats and not stats[interface].isup:
                continue
            for address in addresses:
                if address.family != socket.AF_INET:
                    continue
                try:
                    ip = ipaddress.IPv4Address(address.address)
                except ValueError:
                    continue
                if ip in TAILSCALE_NETWORK and str(ip) not in (entry for _, entry in found):
                    found.append(("tailscale" not in str(interface).lower(), str(ip)))
    except Exception:
        return []
    return [address for _, address in sorted(found, key=lambda entry: entry[0])]


@app.get("/api/network-info")
def api_network_info(request: Request, authorization: str = Header(None)):
    verify_token(authorization)
    return {**get_local_network_details((request.scope.get("server") or (None,))[0]),
            "tailscaleAddresses": tailscale_addresses()}


@app.get("/api/specs")
def get_specs(authorization: str = Header(None)):
    verify_token(authorization)
    with STATE_LOCK:
        return copy.deepcopy(SPECS)


def status_snapshot():
    with STATE_LOCK:
        result = copy.deepcopy(STATE)
        if time.monotonic() - LAST_TELEMETRY > 10:
            result["telemetryAvailable"] = False
            for key in LIVE_OPTIONAL_FIELDS:
                result[key] = None
        if time.monotonic() - LAST_SENSOR > 15:
            for key in SENSOR_FIELDS:
                result[key] = None
            result["sensorSource"] = None
            result["sensorStatus"] = "Hardware sensor readings expired; waiting for a fresh sample from the PC sensor monitor."
            # Main telemetry may still be fresh while its hardware-monitor cache
            # ages out. NVIDIA readings have an independent, current source.
            if result.get("gpuSource") != "NVIDIA SMI":
                for key in GPU_SENSOR_FIELDS + ("gpuSource",):
                    result[key] = None
        return result


def update_channel():
    """"stable" or "beta" (the tray's Beta updates item), for the apps next to the version."""
    from orbit_updater import current_channel
    return current_channel()


@app.get("/api/status")
def get_status(authorization: str = Header(None)):
    verify_token(authorization)
    # Windows' warning after Shut Down or Restart from Orbit, so every app shows it with Cancel.
    return {**status_snapshot(), "updateChannel": update_channel(), "powerCountdown": POWER_COUNTDOWN.snapshot()}


@app.post("/api/widget/pairing")
def widget_pairing(authorization: str = Header(None)):
    verify_token(authorization)
    return {"token": WIDGET_TOKEN}


@app.get("/api/widget/status")
def widget_status(authorization: str = Header(None)):
    if not WIDGET_TOKEN or not isinstance(authorization, str) or not hmac.compare_digest(authorization, f"Bearer {WIDGET_TOKEN}"):
        raise HTTPException(status_code=401, detail="Invalid Orbit widget token", headers={"WWW-Authenticate": "Bearer"})
    status = status_snapshot()
    available = bool(status.get("telemetryAvailable"))
    sample_time = None
    try:
        parsed = datetime.fromisoformat(status.get("lastUpdated") or "")
        if parsed.tzinfo is not None:
            sample_time = parsed.timestamp()
    except (ValueError, TypeError):
        pass
    result = {"pc_name": status.get("hostname") or "PC", "timestamp": sample_time,
              "telemetry_available": available}
    mapping = {"cpu_usage": "cpuUsage", "gpu_usage": "gpuUsage", "cpu_temp": "cpuTemp", "gpu_temp": "gpuTemp",
               "vram_used": "vramUsedGB", "vram_total": "vramTotalGB", "cpu_power": "cpuPowerWatts",
               "gpu_power": "gpuPowerWatts", "cpu_clock": "cpuClockMHz", "cpu_fan": "cpuFanRPM",
               "gpu_fan": "gpuFanPercent", "coolant_temp": "liquidTemp", "disk_read": "diskReadMBps",
               "disk_write": "diskWriteMBps", "network_download": "networkDownloadMBps",
               "network_upload": "networkUploadMBps", "fps": "fps", "game_name": "activeGame"}
    result.update({key: status.get(source) if available else None for key, source in mapping.items()})
    total = status.get("ramTotalGB") or 0
    result["ram_usage"] = round(status["ramUsedGB"] / total * 100, 1) if available and total > 0 else None
    return result


@app.get("/api/processes")
def list_processes(authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    return collect_processes()


@app.get("/api/icons")
def app_icons(ids: str = Query(..., max_length=MAX_IDS_PER_REQUEST * 33), authorization: str = Header(None)):
    """PNG icons (base64) for icon IDs from the process list and the audio mixer.
    `null` means the file has no icon of its own; IDs this agent never listed are left out."""
    verify_token(authorization)
    try:
        wanted = parse_icon_ids(ids)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    return {"icons": ICONS.lookup(wanted), "size": ICON_PIXELS}


@app.post("/api/processes/{pid}/terminate")
def end_process(pid: int, expectedCreateTime: float = Query(..., gt=0), force: bool = False,
                authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    if not math.isfinite(expectedCreateTime):
        raise HTTPException(status_code=422, detail="A valid process creation time is required")
    try:
        return terminate_process(pid, expectedCreateTime, force)
    except ProcessLookupError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except psutil.Error as error:
        raise HTTPException(status_code=503, detail="Windows could not complete the process request") from error


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


def _apply_cursor_operation(dx: int = 0, dy: int = 0, click: str = "", scroll: int = 0,
                            hscroll: int = 0, norm_x: float = None, norm_y: float = None, drag: str = ""):
    if click not in {"", "left", "double", "right", "middle"} or drag not in {"", "down", "up"}:
        raise HTTPException(status_code=422, detail="Invalid mouse button or drag state")
    if max(abs(dx), abs(dy)) > 10000 or abs(scroll) > 100 or abs(hscroll) > 100:
        raise HTTPException(status_code=422, detail="Invalid mouse input range")
    u32 = ctypes.windll.user32
    if norm_x is not None and norm_y is not None:
        if not (math.isfinite(norm_x) and math.isfinite(norm_y)):
            raise HTTPException(status_code=422, detail="Invalid normalized coordinates")
        nx = max(0.0, min(1.0, float(norm_x)))
        ny = max(0.0, min(1.0, float(norm_y)))
        width = max(1, int(u32.GetSystemMetrics(0)))
        height = max(1, int(u32.GetSystemMetrics(1)))
        target_x = int(round(nx * (width - 1)))
        target_y = int(round(ny * (height - 1)))
        if not u32.SetCursorPos(target_x, target_y):
            raise HTTPException(status_code=503, detail="Windows could not position the cursor")
    elif dx or dy:
        point = POINT()
        if not u32.GetCursorPos(ctypes.byref(point)) or not u32.SetCursorPos(point.x + dx, point.y + dy):
            raise HTTPException(status_code=503, detail="Windows could not move the cursor")
    if drag == "down":
        u32.mouse_event(0x0002, 0, 0, 0, 0)
    elif drag == "up":
        u32.mouse_event(0x0004, 0, 0, 0, 0)
    for _ in range(2 if click == "double" else 1):
        if click in {"left", "double"}:
            u32.mouse_event(0x0002, 0, 0, 0, 0)
            u32.mouse_event(0x0004, 0, 0, 0, 0)
        elif click == "right":
            u32.mouse_event(0x0008, 0, 0, 0, 0)
            u32.mouse_event(0x0010, 0, 0, 0, 0)
        elif click == "middle":
            u32.mouse_event(0x0020, 0, 0, 0, 0)
            u32.mouse_event(0x0040, 0, 0, 0, 0)
    if scroll:
        u32.mouse_event(0x0800, 0, 0, scroll * 120, 0)
    if hscroll:
        u32.mouse_event(0x01000, 0, 0, hscroll * 120, 0)


@app.post("/api/input/mouse")
def mouse_input(dx: int = 0, dy: int = 0, click: str = "", scroll: int = 0, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    _apply_cursor_operation(dx=dx, dy=dy, click=click, scroll=scroll)
    return {"status": "sent"}


@app.post("/api/input/cursor")
def cursor_input(dx: int = 0, dy: int = 0, click: str = "", scroll: int = 0, hscroll: int = 0,
                 normX: float = None, normY: float = None, drag: str = "", authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    _apply_cursor_operation(dx=dx, dy=dy, click=click, scroll=scroll, hscroll=hscroll,
                            norm_x=normX, norm_y=normY, drag=drag)
    return {"status": "sent"}


@app.websocket("/ws/input")
async def websocket_input_stream(websocket: WebSocket):
    if not authorized(websocket.headers.get("authorization")):
        await websocket.close(code=1008)
        return
    await websocket.accept()
    if os.name != "nt":
        await websocket.close(code=1011, reason="PC controls require Windows")
        return
    try:
        while True:
            raw = await websocket.receive_text()
            if len(raw) > 2048:
                continue
            try:
                payload = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(payload, dict):
                continue
            dx = int(payload.get("dx") or 0)
            dy = int(payload.get("dy") or 0)
            click = str(payload.get("click") or "")
            scroll = int(payload.get("scroll") or 0)
            hscroll = int(payload.get("hscroll") or 0)
            drag = str(payload.get("drag") or "")
            norm_x = payload.get("normX")
            norm_y = payload.get("normY")
            try:
                _apply_cursor_operation(
                    dx=dx, dy=dy, click=click, scroll=scroll, hscroll=hscroll,
                    norm_x=float(norm_x) if norm_x is not None else None,
                    norm_y=float(norm_y) if norm_y is not None else None,
                    drag=drag,
                )
            except HTTPException:
                continue
    except WebSocketDisconnect:
        pass
    except Exception:
        LOGGER.exception("WebSocket input stream closed")


@app.get("/api/watch/summary")
def watch_summary(authorization: str = Header(None)):
    verify_token(authorization)
    status = status_snapshot()
    total_ram = status.get("ramTotalGB") or 0
    ram_pct = round(status["ramUsedGB"] / total_ram * 100, 1) if total_ram > 0 else 0.0
    return {
        "hostname": status.get("hostname") or "Your PC",
        "agentVersion": status.get("agentVersion") or AGENT_VERSION,
        "isOnline": True,
        "telemetryAvailable": bool(status.get("telemetryAvailable")),
        "cpuUsage": status.get("cpuUsage") or 0.0,
        "cpuTemp": status.get("cpuTemp"),
        "gpuUsage": status.get("gpuUsage"),
        "gpuTemp": status.get("gpuTemp"),
        "ramUsagePercent": ram_pct,
        "ramUsedGB": status.get("ramUsedGB") or 0.0,
        "ramTotalGB": total_ram,
        "cpuPowerWatts": status.get("cpuPowerWatts"),
        "gpuPowerWatts": status.get("gpuPowerWatts"),
        "activeGame": status.get("activeGame"),
        "fps": status.get("fps"),
        "volume": status.get("volume") or 0.0,
        "isMuted": bool(status.get("isMuted")),
        "uptimeSeconds": status.get("uptimeSeconds") or 0,
        "sessionLocked": status.get("sessionLocked"),
        "lastUpdated": status.get("lastUpdated"),
        "powerCountdown": POWER_COUNTDOWN.snapshot(),
    }


@app.post("/api/input/keyboard")
def keyboard_input(text: str = "", key: str = "", authorization: str = Header(None)):
    """Types `text` and/or presses one key. `key` takes any name from orbit_input.KEY_NAMES in any
    case (ENTER, BACKSPACE, SPACE, ESC, WIN and TAB from older apps included)."""
    verify_token(authorization)
    require_windows()
    key_name = key.lower() if key else ""
    if (key_name and key_name not in orbit_input.KEY_NAMES) or len(text) > 1000:
        raise HTTPException(status_code=422, detail="Unsupported key or text too long")
    codes = _layout_key_codes(text)
    with orbit_input.INPUT_LOCK:
        if key_name:
            try:
                orbit_input.tap(key_name)
            except OSError as error:
                raise HTTPException(status_code=503, detail="Windows did not accept the key press. The PC may be locked.") from error
        _type_key_codes(codes)
    return {"status": "sent"}


def _layout_key_codes(text):
    """VkKeyScanW codes for each character; 422 when the PC's keyboard layout lacks one."""
    u32 = ctypes.windll.user32
    u32.VkKeyScanW.argtypes = [ctypes.c_wchar]
    u32.VkKeyScanW.restype = ctypes.c_short
    codes = [u32.VkKeyScanW(char) if ord(char) <= 0xFFFF else -1 for char in text]
    if -1 in codes:
        raise HTTPException(status_code=422, detail="Some characters are not available in the PC keyboard layout")
    return codes


def _type_key_codes(codes):
    u32 = ctypes.windll.user32
    with orbit_input.INPUT_LOCK:
        for code in codes:
            modifiers = [vk for mask, vk in ((1, 0x10), (2, 0x11), (4, 0x12)) if (code >> 8) & mask]
            for modifier in modifiers:
                u32.keybd_event(modifier, 0, 0, 0)
            tap_key(code & 0xFF)
            for modifier in reversed(modifiers):
                u32.keybd_event(modifier, 0, 2, 0)


def type_text(text):
    """Types text like /api/input/keyboard does (deck text buttons). Raises HTTPException."""
    require_windows()
    _type_key_codes(_layout_key_codes(text))


class HotkeyBody(BaseModel):
    keys: list = Field(max_length=32)


@app.post("/api/input/hotkey", dependencies=[Depends(verify_token), Depends(require_https)])
def hotkey_input(body: HotkeyBody):
    """Presses a shortcut such as `{"keys": ["ctrl", "shift", "m"]}` (at most 5 allowlisted keys)."""
    try:
        keys = orbit_input.normalize_chord(body.keys)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    require_windows()
    try:
        orbit_input.press_chord(keys)
    except OSError as error:
        raise HTTPException(status_code=503, detail=str(error) or "Windows did not accept the shortcut.") from error
    return {"status": "sent"}


register_feature("hotkeys")


class OpenURLBody(BaseModel):
    url: str = Field(max_length=65536)


@app.post("/api/open-url", dependencies=[Depends(verify_token), Depends(require_https)])
def open_url_on_pc(body: OpenURLBody):
    """Opens an http(s) link in the PC's default browser (Send to PC)."""
    try:
        url = orbit_links.validate_url(body.url)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    require_windows()
    if BOOT_MODE:
        raise HTTPException(status_code=409, detail="Sign in to Windows on the PC first. Links open on the signed-in desktop.")
    try:
        orbit_links.open_url(url)
    except OSError as error:
        raise HTTPException(status_code=503, detail=str(error) or "Windows could not open this link.") from error
    orbit_notify.notify("Opened a link from your iPhone", orbit_links.display_url(url))
    return {"status": "opened"}


register_feature("openUrl")

# Electricity cost (orbit_energy) and the monthly summary (orbit_summary) share the energy ledger.
app.include_router(orbit_energy.create_energy_router(verify_token, require_https))
app.include_router(orbit_summary.create_summary_router(verify_token, require_https))
register_feature("energy")
register_feature("summary")


@app.post("/api/input/gamepad")
def gamepad_input(button: str, authorization: str = Header(None)):
    verify_token(authorization)
    require_windows()
    keymap = {"A": 0x20, "B": 0x1B, "X": 0x45, "Y": 0x52, "UP": 0x57, "DOWN": 0x53, "LEFT": 0x41, "RIGHT": 0x44}
    if button.upper() not in keymap:
        raise HTTPException(status_code=422, detail="Unsupported gamepad button")
    with orbit_input.INPUT_LOCK:
        tap_key(keymap[button.upper()])
    return {"status": "sent", "mode": "keyboard_mapping"}


ACTIONS = frozenset({
    "lock", "sleep", "restart", "shutdown",
    "mute", "volume_up", "volume_down",
    "media_play_pause", "media_next", "media_prev",
    "toggle_hdr", "restore_display", "kill_game",
    "show_desktop", "task_view", "alt_tab", "screenshot", "fullscreen",
})
POWER_ACTIONS = frozenset({"sleep", "restart", "shutdown"})
KEYBOARD_ACTIONS = frozenset({"mute", "volume_up", "volume_down", "media_play_pause", "media_next", "media_prev",
                              "fullscreen", "toggle_hdr", "show_desktop", "task_view", "alt_tab", "screenshot"})
# Callables run without arguments right before the PC sleeps, restarts or shuts down through
# perform_action (for example orbit_push.planned_offline). Feature modules append to this list.
# They run in order on a helper thread; after BEFORE_POWER_HOOKS_TIMEOUT seconds the power action
# goes ahead anyway, and a hook that raises is logged and skipped.
BEFORE_POWER_HOOKS = []
BEFORE_POWER_HOOKS_TIMEOUT = 5.0
# Callables run without arguments when a shutdown or restart the hooks above announced doesn't
# happen after all: Windows' countdown was cancelled, or refused (orbit_push re-arms its alarm).
# They must return quickly; one that raises is logged and skipped.
POWER_CANCELLED_HOOKS = []
# Windows' 30-second warning after Shut Down or Restart from the apps (orbit_power_countdown).
POWER_COUNTDOWN = orbit_power_countdown.PowerCountdown()


def run_power_cancelled_hooks():
    for hook in list(POWER_CANCELLED_HOOKS):
        try:
            hook()
        except Exception:
            LOGGER.exception("A power-cancelled hook failed")


def run_before_power_hooks(action_name):
    hooks = list(BEFORE_POWER_HOOKS)
    if not hooks:
        return

    def run():
        for hook in hooks:
            try:
                # A hook marked `accepts_action` learns which action follows (push: restart vs sleep).
                hook(action_name) if getattr(hook, "accepts_action", False) else hook()
            except Exception:
                LOGGER.exception("A before-%s hook failed", action_name)

    worker = threading.Thread(target=run, name="orbit-before-power", daemon=True)
    worker.start()
    worker.join(BEFORE_POWER_HOOKS_TIMEOUT)
    if worker.is_alive():
        LOGGER.warning("Hooks before %s took longer than %s s; continuing", action_name, BEFORE_POWER_HOOKS_TIMEOUT)


@app.post("/api/action/{action_name}")
def execute_action(action_name: str, authorization: str = Header(None)):
    verify_token(authorization)
    # Shut Down and Restart from the apps give the person at the PC Windows' 30-second warning.
    return perform_action(action_name, countdown=True)


def perform_action(action_name, countdown=False):
    """Runs one PC action by name, for the HTTP route and for automation (power after downloads).

    Returns `{"status": "sent", "executed": name}`. With `countdown`, restart and shutdown start
    Windows' 30-second warning instead of the short delay and add `"countdownSeconds"` (see
    orbit_power_countdown). Raises HTTPException: 404 for an unknown name, 501 off Windows,
    409 when kill_game finds no foreground game or Windows already counts down, 503 when
    Windows refuses.
    """
    if action_name not in ACTIONS:
        raise HTTPException(status_code=404, detail="Unknown PC action")
    require_windows()
    if countdown and action_name in orbit_power_countdown.COUNTDOWN_ACTIONS:
        return start_power_countdown(action_name)
    u32 = ctypes.windll.user32
    # Key presses must not interleave with a shortcut being held by /api/input/hotkey.
    typing = action_name in KEYBOARD_ACTIONS
    if typing:
        orbit_input.INPUT_LOCK.acquire()
    try:
        if action_name == "lock":
            if not u32.LockWorkStation():
                raise OSError("LockWorkStation failed")
        elif action_name == "sleep":
            run_before_power_hooks(action_name)
            # Do not force suspension; let Windows honor its power policy.
            if not ctypes.windll.powrprof.SetSuspendState(0, 0, 0):
                raise OSError("SetSuspendState failed")
        elif action_name in {"restart", "shutdown"}:
            run_before_power_hooks(action_name)
            subprocess.run(["shutdown", "/r" if action_name == "restart" else "/s", "/t", "3"], check=True,
                           timeout=5, capture_output=True, creationflags=0x08000000)
        elif action_name in {"mute", "volume_up", "volume_down", "media_play_pause", "media_next", "media_prev", "fullscreen"}:
            tap_key({
                "mute": 0xAD, "volume_up": 0xAF, "volume_down": 0xAE,
                "media_play_pause": 0xB3, "media_next": 0xB0, "media_prev": 0xB1,
                "fullscreen": 0x7A,
            }[action_name])
        elif action_name == "toggle_hdr":
            u32.keybd_event(0x5B, 0, 0, 0)
            u32.keybd_event(0x12, 0, 0, 0)
            tap_key(0x42)
            u32.keybd_event(0x12, 0, 2, 0)
            u32.keybd_event(0x5B, 0, 2, 0)
            # Shortcut delivery cannot verify HDR state; hdrEnabled remains null.
        elif action_name == "show_desktop":
            u32.keybd_event(0x5B, 0, 0, 0)
            tap_key(0x44)  # Win + D
            u32.keybd_event(0x5B, 0, 2, 0)
        elif action_name == "task_view":
            u32.keybd_event(0x5B, 0, 0, 0)
            tap_key(0x09)  # Win + Tab
            u32.keybd_event(0x5B, 0, 2, 0)
        elif action_name == "alt_tab":
            u32.keybd_event(0x12, 0, 0, 0)
            tap_key(0x09)  # Alt + Tab
            u32.keybd_event(0x12, 0, 2, 0)
        elif action_name == "screenshot":
            u32.keybd_event(0x5B, 0, 0, 0)
            tap_key(0x2C)  # Win + PrintScreen
            u32.keybd_event(0x5B, 0, 2, 0)
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
    finally:
        if typing:
            orbit_input.INPUT_LOCK.release()
    return {"status": "sent", "executed": action_name}


def start_power_countdown(action_name):
    """`shutdown /s|/r /t 30` with the power hooks first. Asking again for the same action keeps the
    countdown that runs (and its time left); the other action replaces it."""
    announced = []

    def before_start():
        announced.append(action_name)
        run_before_power_hooks(action_name)
    try:
        pending, _ = POWER_COUNTDOWN.start(action_name, before_start=before_start)
    except orbit_power_countdown.CountdownError as error:
        if announced:
            run_power_cancelled_hooks()
        raise HTTPException(status_code=error.status, detail=str(error)) from error
    return {"status": "sent", "executed": action_name, "countdownSeconds": pending["remainingSeconds"]}


@app.post("/api/power/cancel")
def cancel_power_countdown(authorization: str = Header(None)):
    """Stops Windows' countdown after Shut Down or Restart (`shutdown /a`), whoever started it.

    Same access as /api/action (the main token, HTTP or HTTPS): whoever may shut the PC down may
    stop it. `{"status": "cancelled", "action": "shutdown"|"restart"|null}`; 409 when nothing waits.
    """
    verify_token(authorization)
    require_windows()
    try:
        action = POWER_COUNTDOWN.cancel()
    except orbit_power_countdown.CountdownError as error:
        raise HTTPException(status_code=error.status, detail=str(error)) from error
    LOGGER.info("Cancelled the pending %s", action or "shutdown or restart")
    run_power_cancelled_hooks()
    return {"status": "cancelled", "action": action}


register_feature("powerCountdown")


# -- Notifications (DESIGN F1): alerts, downloads, watched programs, power after, instant push ----
app.include_router(orbit_alerts.create_alerts_router(verify_token))
app.include_router(orbit_downloads.create_downloads_router(verify_token))
app.include_router(orbit_tasks.create_tasks_router(verify_token))
app.include_router(orbit_power_after.create_power_after_router(verify_token, require_windows=require_windows))
app.include_router(orbit_push.create_push_router(verify_token))
for _feature in ("alerts", "downloads", "tasks", "powerAfter", "push"):
    register_feature(_feature)
BEFORE_POWER_HOOKS.append(orbit_push.planned_offline)
POWER_CANCELLED_HOOKS.append(orbit_push.planned_offline_cancelled)


def start_notification_features():
    """Starts the F1 workers (downloads, watched programs, power after, push relay) and announces
    pc.online. Returns a function that stops them. A failure here never stops the agent itself."""
    stop = threading.Event()
    workers, wakers, push = [], [], None

    def stop_all():
        stop.set()
        for wake in wakers:
            wake()
        deadline = time.monotonic() + 5
        for worker in workers:
            worker.join(max(0.1, deadline - time.monotonic()))
        if push is not None:
            orbit_events.unregister_dispatcher(push.dispatch)
        orbit_push.set_shared_service(None)
        orbit_power_after.set_shared_service(None)
    try:
        orbit_downloads.set_shared_watcher(None)
        orbit_tasks.set_shared_watcher(None)
        downloads, tasks = orbit_downloads.shared_watcher(), orbit_tasks.shared_watcher()
        push = orbit_push.PushService(agent_version=AGENT_VERSION, on_back_online=orbit_alerts.announce_back_online,
                                      boot_task_installed=lambda: BOOT_MODE or orbit_push.boot_task_installed_once())

        def deliver_before_power():
            orbit_events.flush_dispatch(2.0)
            push.flush(4.0)
        # perform_action is looked up when the rule fires, so it is always the agent's current one.
        power = orbit_power_after.PowerAfter(perform=lambda action: perform_action(action),
                                             downloads=orbit_downloads.shared_watcher, tasks=orbit_tasks.shared_watcher,
                                             before_execute=deliver_before_power)
        tasks.add_listener(power.task_changed)
        orbit_power_after.set_shared_service(power)
        orbit_push.set_shared_service(push)
        orbit_events.register_dispatcher(push.dispatch)
        wakers.extend((power.wake, push.wake))
        workers.extend(service.start(stop) for service in (downloads, tasks, power, push))
        orbit_alerts.announce_online()
    except Exception:
        LOGGER.exception("Notifications could not start; the rest of Orbit keeps working")
    return stop_all


# Custom button deck and OBS buttons (orbit_deck). The lambdas look the agent's functions up at
# call time, so the deck always runs the current perform_action and type_text.
app.include_router(create_deck_router(
    verify_token, require_https, require_windows=lambda: require_windows(),
    perform_action=lambda name: perform_action(name), type_text=lambda text: type_text(text),
    boot_mode=lambda: BOOT_MODE))


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


def sunshine_config():
    """`key = value` pairs from the first sunshine.conf found; empty when Sunshine is not installed."""
    for path in SUNSHINE_CONF_PATHS:
        if not path.is_file():
            continue
        values = {}
        try:
            for line in path.read_text(encoding="utf-8-sig").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
        except OSError:
            continue
        return values
    return {}


def sunshine_running():
    try:
        return any((proc.info.get("name") or "").lower() in ("sunshine.exe", "sunshine") for proc in psutil.process_iter(["name"]))
    except Exception:
        return False


def sunshine_base_port():
    """Sunshine's base `port` (default 47989); every other port is derived from it."""
    try:
        base = int(sunshine_config().get("port", "47989"))
    except ValueError:
        base = 47989
    return base if 6 <= base <= 65534 else 47989


def sunshine_credentials():
    """Web UI login saved through `POST /api/sunshine/credentials`; None until the user saves one."""
    try:
        data = json.loads(SUNSHINE_CREDENTIALS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    username, password = data.get("username"), data.get("password")
    if not isinstance(username, str) or not isinstance(password, str) or not username or not password:
        return None
    return username, password


def sunshine_executable():
    return next((path for path in SUNSHINE_EXECUTABLE_PATHS if path.is_file()), None)


@app.get("/api/sunshine/info")
def get_sunshine_info(authorization: str = Header(None)):
    """Where Orbit's Moonlight-protocol client should talk to Sunshine on this PC.

    Sunshine derives every port from its base `port` (default 47989): HTTPS is base - 5,
    the Web UI (where the pairing PIN is entered) is base + 1. `canSubmitPin` says whether
    the agent can type the PIN itself and `canStart` whether it can launch Sunshine.
    """
    verify_token(authorization)
    config = sunshine_config()
    base = sunshine_base_port()
    try:
        app_count = len(sunshine_entries())
        installed = any(path.is_file() for path in SUNSHINE_APPS_PATHS) or bool(config)
    except HTTPException:
        app_count, installed = 0, True
    return {"installed": installed, "running": sunshine_running(), "httpPort": base, "httpsPort": base - 5,
            "webUIPort": base + 1, "name": config.get("sunshine_name") or socket.gethostname(), "appCount": app_count,
            "canSubmitPin": sunshine_credentials() is not None, "canStart": sunshine_executable() is not None}


class SunshineLogin(BaseModel):
    username: str
    password: str


@app.post("/api/sunshine/credentials")
def save_sunshine_credentials(login: SunshineLogin, authorization: str = Header(None)):
    """Stores the Sunshine web UI login next to the agent token so `/api/sunshine/pin` can use it."""
    verify_token(authorization)
    username = login.username.strip()
    if not username or not login.password or len(username) > 128 or len(login.password) > 512:
        raise HTTPException(status_code=422, detail="Enter the Sunshine web UI username and password.")
    try:
        SUNSHINE_CREDENTIALS_PATH.write_text(json.dumps({"username": username, "password": login.password}), encoding="utf-8")
        try:
            os.chmod(SUNSHINE_CREDENTIALS_PATH, 0o600)
        except OSError:
            pass
    except OSError as error:
        raise HTTPException(status_code=503, detail="Could not save the Sunshine login on this PC") from error
    return {"status": "saved", "canSubmitPin": True}


@app.delete("/api/sunshine/credentials")
def delete_sunshine_credentials(authorization: str = Header(None)):
    verify_token(authorization)
    try:
        SUNSHINE_CREDENTIALS_PATH.unlink()
    except FileNotFoundError:
        pass
    except OSError as error:
        raise HTTPException(status_code=503, detail="Could not remove the Sunshine login") from error
    return {"status": "removed", "canSubmitPin": False}


def _sunshine_web_call(credentials, method, path, payload=None, timeout=10.0):
    """One request to Sunshine's local web API, the way its own pages make it.

    Sunshine listens on loopback with a self-signed certificate, so verification is skipped
    for this localhost request only. Returns the decoded JSON object; HTTP errors propagate
    as `urllib.error.HTTPError`.
    """
    url = f"https://127.0.0.1:{sunshine_base_port() + 1}{path}"
    token = base64.b64encode(f"{credentials[0]}:{credentials[1]}".encode("utf-8")).decode("ascii")
    headers = {"Authorization": f"Basic {token}", "Accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        body = json.loads(response.read() or b"{}")
    return body if isinstance(body, dict) else {}


def _sunshine_error_message(error):
    """Sunshine's own explanation from an error reply (`{"error": "..."}`), when it sent one."""
    try:
        body = json.loads(error.read() or b"{}")
    except Exception:
        return None
    message = body.get("error") if isinstance(body, dict) else None
    return message.strip() if isinstance(message, str) and message.strip() else None


def _normalized_address(value):
    text = str(value or "").strip().lower()
    return text[7:] if text.startswith("::ffff:") else text


def _pending_sunshine_pairings(credentials, timeout=10.0):
    """Pairing requests waiting for a PIN (`GET /api/pin`, Sunshine 2026 and later), oldest first.

    Returns None for older Sunshine versions, which take the PIN without a pairing id.
    """
    try:
        body = _sunshine_web_call(credentials, "GET", "/api/pin", timeout=timeout)
    except urllib.error.HTTPError as error:
        if error.code in (404, 405):
            return None
        raise
    pairings = body.get("pairings")
    if not isinstance(pairings, list):
        return None
    return [entry for entry in pairings if isinstance(entry, dict) and isinstance(entry.get("id"), str)]


def _choose_pairing(pairings, name, client_address):
    """The newest pending request from this device: same name (preferring the caller's
    address), else the caller's address. Never a request from another device, which would
    get this PIN and fail its own pairing.
    """
    candidates = [entry for entry in pairings if entry.get("name") == name]
    if client_address:
        nearby = [entry for entry in (candidates or pairings)
                  if _normalized_address(entry.get("address")) == _normalized_address(client_address)]
        if nearby or not candidates:
            candidates = nearby
    return candidates[-1] if candidates else None


def post_sunshine_pin(credentials, pin, name, client_address=None, timeout=10.0, wait=8.0):
    """Enters a pairing PIN through Sunshine's local web API, the same call its PIN page makes.

    Sunshine 2026 lists the pairing requests that wait for a PIN and takes the PIN for one of
    them (`pairing_id`); older versions take the PIN for whichever request is pending. The
    request from this device can reach Sunshine a moment after Orbit asks for the PIN, so the
    list is polled for up to `wait` seconds. Returns normally when Sunshine accepted the PIN.
    """
    try:
        pairings = _pending_sunshine_pairings(credentials, timeout)
        if pairings is None:
            body = _sunshine_web_call(credentials, "POST", "/api/pin", {"pin": pin, "name": name}, timeout)
        else:
            deadline = time.monotonic() + wait
            pairing = _choose_pairing(pairings, name, client_address)
            while pairing is None and time.monotonic() < deadline:
                time.sleep(0.5)
                pairings = _pending_sunshine_pairings(credentials, timeout) or []
                pairing = _choose_pairing(pairings, name, client_address)
            if pairing is None:
                if pairings:
                    raise HTTPException(status_code=409, detail="Sunshine is waiting for a PIN from another device, not this one. Enter the PIN in Sunshine's web UI on the PC.")
                raise HTTPException(status_code=409, detail="Sunshine has no pairing request from this device. Start pairing in Orbit, then try again.")
            body = _sunshine_web_call(credentials, "POST", "/api/pin", {"pairing_id": pairing["id"], "pin": pin, "name": name}, timeout)
            # Older requests from the same device would wait until they expire; close them now.
            for stale in pairings:
                if stale is not pairing and stale.get("name") == name and _normalized_address(stale.get("address")) == _normalized_address(pairing.get("address")):
                    try:
                        _sunshine_web_call(credentials, "DELETE", "/api/pin", {"pairing_id": stale["id"]}, timeout)
                    except (urllib.error.URLError, OSError, ValueError):
                        pass
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise HTTPException(status_code=401, detail="Sunshine rejected the saved web UI login. Save it again in Orbit.") from error
        if error.code == 403:
            raise HTTPException(status_code=403, detail="Sunshine's web UI refused the request from this PC. Check Origin Web UI Allowed in Sunshine's network settings.") from error
        message = _sunshine_error_message(error)
        detail = f"Sunshine answered HTTP {error.code} to the PIN request" + (f": {message}" if message else ".")
        raise HTTPException(status_code=502, detail=detail) from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise HTTPException(status_code=502, detail="Could not reach Sunshine's web UI on this PC. Is Sunshine running?") from error
    status = body.get("status") if isinstance(body, dict) else None
    if status not in (True, "true", "True"):
        raise HTTPException(status_code=409, detail="Sunshine did not accept the PIN. Start pairing in Orbit first, then try again.")


@app.post("/api/sunshine/pin")
def submit_sunshine_pin(request: Request, pin: str = Query(..., min_length=4, max_length=4, pattern=r"^[0-9]{4}$"),
                        name: str = Query("Orbit", min_length=1, max_length=40), authorization: str = Header(None)):
    """Types the pairing PIN into Sunshine for the user (needs the saved web UI login).

    `name` is the device name the client sent with its pairing request; with the caller's
    address it picks that request when Sunshine lists several.
    """
    verify_token(authorization)
    credentials = sunshine_credentials()
    if credentials is None:
        raise HTTPException(status_code=428, detail="Save the Sunshine web UI login on the PC first.")
    if not sunshine_running():
        raise HTTPException(status_code=503, detail="Sunshine is not running on the PC.")
    post_sunshine_pin(credentials, pin, name, client_address=request.client.host if request.client else None)
    return {"status": "accepted"}


@app.post("/api/sunshine/start")
def start_sunshine(authorization: str = Header(None)):
    """Launches Sunshine when it is installed but not running."""
    verify_token(authorization)
    require_windows()
    if sunshine_running():
        return {"status": "running"}
    executable = sunshine_executable()
    if executable is None:
        raise HTTPException(status_code=404, detail="Sunshine is not installed in Program Files.")
    try:
        subprocess.Popen([str(executable)], cwd=str(executable.parent), creationflags=0x08000000 | 0x00000008)
    except OSError as error:
        raise HTTPException(status_code=503, detail="Could not start Sunshine") from error
    return {"status": "starting"}


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


# Full-screen streaming and the virtual second screen (orbit_stream_display) change Sunshine's
# display settings through its web API with the login saved above. Lambdas look the helpers up
# at call time, so tests (and the pretend PC) can replace them.
from orbit_stream_display import StreamDisplayService, SunshineWebAPI, create_stream_display_router

STREAM_DISPLAY = StreamDisplayService(SunshineWebAPI(lambda: sunshine_credentials(), lambda: sunshine_base_port()),
                                      sunshine_base_port=lambda: sunshine_base_port(),
                                      desktop_available=lambda: not BOOT_MODE)
app.include_router(create_stream_display_router(verify_token, require_https, STREAM_DISPLAY,
                                                require_windows=lambda: require_windows()))
register_feature("streamDisplay")
register_feature("secondScreen")


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


# Presentation remote: PowerPoint over COM, other presenters by keys (orbit_presentation.py).
import orbit_presentation  # noqa: E402  (kept next to its wiring)

app.include_router(orbit_presentation.create_presentation_router(
    verify_token, require_https, require_windows, boot_mode=lambda: BOOT_MODE))
register_feature("presentation")

# iPhone as a webcam: GET /api/webcam, POST /api/webcam/install, WS /ws/camera (orbit_webcam.py).
app.include_router(orbit_webcam.create_webcam_router(verify_token, require_https, require_windows, authorized,
                                                     boot_mode=lambda: BOOT_MODE))
register_feature("webcam")


@app.post("/api/internal/handover")
def api_handover(request: Request, authorization: str = Header(None)):
    """Asks this instance to exit so another one on the same PC can take the ports.

    Used by the per-user companion when it starts after the boot-time instance (which runs
    before anyone signs in and cannot reach the desktop). Loopback only, token required.
    """
    verify_token(authorization)
    client = (request.client.host if request.client else "") or ""
    if client not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(status_code=403, detail="Hand-over is only accepted from this PC")
    threading.Timer(0.5, STOP_EVENT.set).start()
    return {"status": "stopping", "bootMode": BOOT_MODE}


def takeover_running_instance(token, port=None, timeout=20.0):
    """If another companion already serves this PC's ports (the boot-time instance), ask it to
    stop and wait until the port is free. Returns True when a hand-over happened."""
    port = port or AGENT_PORT
    base = f"http://127.0.0.1:{port}"
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{base}/api/discover"), timeout=2) as response:
            if json.loads(response.read() or b"{}").get("service") != "orbit-agent":
                return False
    except (urllib.error.URLError, OSError, ValueError):
        return False
    try:
        request = urllib.request.Request(f"{base}/api/internal/handover", data=b"", method="POST",
                                         headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(request, timeout=5):
            pass
    except (urllib.error.URLError, OSError):
        return False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) != 0:
                return True
        time.sleep(0.5)
    return False


@app.get("/api/update/check")
def api_check_for_updates(authorization: str = Header(None)):
    verify_token(authorization)
    from orbit_updater import check_for_updates
    try:
        return check_for_updates(AGENT_VERSION)
    except Exception as error:
        raise HTTPException(status_code=503, detail=str(error)) from error


@app.post("/api/update/apply")
def api_apply_update(authorization: str = Header(None)):
    verify_token(authorization)
    from orbit_updater import check_for_updates, download_and_apply_update
    try:
        info = check_for_updates(AGENT_VERSION)
    except Exception as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    if not info.get("updateAvailable"):
        return {"status": "up_to_date", "currentVersion": AGENT_VERSION, "latestVersion": info.get("latestVersion")}
    download_url = info.get("downloadUrl")
    if not download_url:
        raise HTTPException(status_code=409, detail="No downloadable update archive is available for this release")
    try:
        updated = download_and_apply_update(download_url)
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"Could not apply update: {error}") from error
    return {
        "status": "updated",
        "currentVersion": AGENT_VERSION,
        "latestVersion": info.get("latestVersion"),
        "updatedFiles": updated,
    }


def tray_status_snapshot():
    network = get_local_network_details()
    with STATE_LOCK:
        active_game = STATE.get("activeGame")
    return {
        "agentVersion": AGENT_VERSION,
        "updateChannel": update_channel(),
        "hostname": network.get("hostname") or socket.gethostname(),
        "ipAddress": network.get("ipAddress") or "",
        "agentPort": AGENT_PORT,
        "securePort": SECURE_PORT,
        "fingerprint": CERTIFICATE_FINGERPRINT,
        "activeGame": active_game,
    }


def _acquire_single_instance_mutex():
    if os.name != "nt":
        return None
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        kernel32.CreateMutexW.restype = ctypes.c_void_p
        name = f"Local\\OrbitPCCompanion_{AGENT_PORT}_{SECURE_PORT}"
        handle = kernel32.CreateMutexW(None, 1, name)
        if handle and ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
            kernel32.CloseHandle(ctypes.c_void_p(handle))
            return False
        return handle
    except Exception:
        return None


if __name__ == "__main__":
    import sys
    from orbit_tls import ensure_tls_identity, serve_both
    from orbit_tray import OrbitTrayIcon, StartupManager, ensure_background_stdio

    os.chdir(_RUNTIME_DIR)
    args = {arg.strip().lower() for arg in sys.argv[1:]}
    if "--enable-startup" in args:
        StartupManager().set_enabled(True)
        raise SystemExit(0)
    if "--disable-startup" in args:
        StartupManager().set_enabled(False)
        raise SystemExit(0)
    if "--check-updates" in args:
        tray = OrbitTrayIcon(status_provider=tray_status_snapshot, on_stop=lambda: None)
        result = tray.perform_update_check()
        print(json.dumps(result, indent=2))
        raise SystemExit(0)

    BOOT_MODE = "--boot" in args
    log_file = ensure_background_stdio()
    mutex = _acquire_single_instance_mutex()
    if mutex is False:
        if os.name == "nt" and "--background" not in args and not BOOT_MODE:
            ctypes.windll.user32.MessageBoxW(
                None,
                "Orbit PC Companion is already running in the system tray (bottom-right notification area).\n\n"
                "Click the Orbit icon in the taskbar corner to view connection details, check for updates, toggle Windows startup, or stop the companion.",
                "Orbit PC Companion",
                0x00040040,
            )
        raise SystemExit(0)

    try:
        API_TOKEN = load_api_token()
        certificate, private_key, fingerprint = ensure_tls_identity()
    except Exception as startup_error:
        if os.name == "nt" and ("--background" in args or "--tray" in args):
            ctypes.windll.user32.MessageBoxW(
                None,
                f"Orbit PC Companion could not start:\n\n{startup_error}",
                "Orbit PC Companion · Startup Error",
                0x00040010,
            )
        raise

    # The boot-time instance (started before sign-in) runs in another session, where the
    # single-instance mutex is not visible: ask it to hand the ports over to this one.
    if not BOOT_MODE and takeover_running_instance(API_TOKEN):
        print("Took over from the boot-time Orbit Companion instance.")
        orbit_alerts.note_handover()  # that instance already announced this boot (pc.online)

    CERTIFICATE_FINGERPRINT = fingerprint
    PAIRING_MANAGER = PairingManager(fingerprint, pairing_payload)
    ADVERTISEMENT = OrbitAdvertisement(SECURE_PORT, fingerprint, AGENT_VERSION)
    network = get_local_network_details()
    print(f"Orbit PC Companion {AGENT_VERSION} · port {AGENT_PORT}")
    print(f"PC IP: {network['ipAddress'] or 'No active LAN adapter'}")
    print("In Orbit on iPhone, choose Find my PC. A one-use code will appear here and in a Windows dialog.")
    print(f"Advanced manual pairing token: {API_TOKEN}")
    print(f"Encrypted connection port: {SECURE_PORT}")
    print(f"Certificate SHA-256 (manual setup only): {fingerprint}")
    print("Keep this token private. Use a trusted home network or VPN; do not port-forward this agent.")

    STOP_EVENT.clear()
    tray = None
    tray_window = False
    if BOOT_MODE:
        print("Boot-time instance: no tray icon; hands over to the signed-in companion when it starts.")
    else:
        tray = OrbitTrayIcon(
            status_provider=tray_status_snapshot,
            on_stop=STOP_EVENT.set,
            token_provider=lambda: API_TOKEN,
            log_path=log_file,
            notify_on_start=("--tray" in args),
            # Sleep, shutdown or sign-out started from Windows: no "PC offline" push (orbit_push).
            power_listener=orbit_push.system_power_event,
        )
        tray_window = tray.start()
        # PC toasts from features (events, Send to PC, received files) go through the tray icon.
        orbit_notify.set_notifier(tray.show_notification)
        if ("--background" in args or "--tray" in args) and "--console" not in args:
            tray.set_console_visible(False)
    # Without the tray's window (the boot-time instance) Windows calls back on suspend and resume.
    stop_power_watch = orbit_push.watch_suspend_resume() if not tray_window else (lambda: None)
    try:
        asyncio.run(serve_both(
            app,
            os.getenv("ORBIT_HOST", "0.0.0.0"),
            AGENT_PORT,
            SECURE_PORT,
            certificate,
            private_key,
            stop_event=STOP_EVENT,
        ))
    except KeyboardInterrupt:
        pass
    finally:
        STOP_EVENT.set()
        orbit_notify.set_notifier(None)
        stop_power_watch()
        if tray is not None:
            tray.close()
