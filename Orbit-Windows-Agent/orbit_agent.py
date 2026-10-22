"""Orbit PC Companion: authenticated local-network monitoring and controls."""
import asyncio
import base64
import copy
import ctypes
import hmac
import ipaddress
import json
import logging
import math
import os
import secrets
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime
from pathlib import Path

import psutil
import uvicorn
from fastapi import FastAPI, Header, HTTPException, Path as PathParameter, Query, Request, Response, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, Field

import orbit_paths
from orbit_access import AccessMiddleware, current_principal, error_response, note, websocket_principal
from orbit_activity import CATEGORIES as ACTIVITY_CATEGORIES, PC_ACTOR, ActivityLog, InputSessions, Notifier, describe, result_for
from orbit_power import COUNTDOWN_SECONDS, NothingToCancel, PowerUnavailable, WindowsPower, shutdown_comment
from orbit_library import GAME_ID, GameLibrary
from orbit_settings import Settings, SettingsError
from orbit_devices import (AccessError, DeviceRegistry, LEGACY_PRINCIPAL, SCOPE_DESCRIPTIONS, SCOPES,
                           invalid_token, scope_missing)
from orbit_processes import collect_processes, terminate_process
from orbit_tls import data_directory
from orbit_screen import FrameSource, NoDisplay, StreamSlots, stream_frames
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

AGENT_VERSION = "5.0.0"
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
# The installed folder; in OrbitCompanion.exe that is next to the executable, not _MEIPASS.
_RUNTIME_DIR = orbit_paths.runtime_directory()
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
# Paired devices (token hashes and scopes) live with the TLS identity in %LOCALAPPDATA%\Orbit.
DEVICES_PATH = Path(os.getenv("ORBIT_DEVICES_FILE") or str(data_directory() / "devices.json"))
DEVICE_REGISTRY = None
# What paired devices did (never typed text, clipboard or file contents) and the settings.
ACTIVITY_PATH = data_directory() / "activity.sqlite3"
SETTINGS_PATH = data_directory() / "settings.json"
ACTIVITY = None
SETTINGS = None
for _secret in (TOKEN_PATH, WIDGET_TOKEN_PATH, SUNSHINE_CREDENTIALS_PATH, DEVICES_PATH, SETTINGS_PATH,
                *(Path(str(ACTIVITY_PATH) + suffix) for suffix in ("", "-wal", "-shm", "-journal"))):
    orbit_paths.protect_path(_secret)
# What this agent can do, for `GET /api/capabilities`. Apps check these instead of versions.
FEATURES = ["devices", "scopes", "capabilities", "update.dependencies", "stream.adaptive",
            "activity", "notifications", "power.countdown", "power.cancel", "library"]
POWER = WindowsPower()
INPUT_SESSIONS = InputSessions()


def _notification_settings():
    settings = SETTINGS
    return settings.notifications() if settings is not None else {}


def _gaming():
    with STATE_LOCK:
        return bool(STATE.get("activeGame"))


# Shows Windows notifications through the tray balloon once the tray is up (None: log only).
NOTIFIER = Notifier(show=None, settings=_notification_settings, gaming=_gaming)
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
    "uptimeSeconds": 0, "activeGame": None, "activeGameProcess": None, "activeGameID": None, "activeGameTitle": None,
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


def write_private_file(path, text):
    """Replace a credential file atomically, readable only by this account where the OS allows."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".orbit-tmp-{secrets.token_hex(6)}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(text)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


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


def bearer_token(authorization):
    if isinstance(authorization, str) and authorization[:7].lower() == "bearer ":
        return authorization[7:].strip() or None
    return None


def _same_secret(candidate, secret):
    # Bytes, so a header with non-ASCII characters is simply wrong, never a server error.
    return bool(candidate and secret and hmac.compare_digest(candidate.encode("utf-8", "surrogateescape"),
                                                             secret.encode("utf-8")))


def authenticate(authorization, address=None):
    """The paired device behind a bearer token. Until the device list is loaded (unit tests,
    tools that skip the lifespan), the master token stands for the legacy device."""
    token = bearer_token(authorization)
    registry = DEVICE_REGISTRY
    if registry is not None:
        return registry.authenticate(token, address)
    if _same_secret(token, API_TOKEN):
        return LEGACY_PRINCIPAL
    raise invalid_token()


def authorized(authorization):
    try:
        authenticate(authorization)
        return True
    except AccessError:
        return False


def verify_token(authorization: str = Header(None)):
    """Any paired device; the access middleware has already checked the route's scope."""
    return authenticate(authorization)


def caller(request, authorization=None):
    """The device behind this request (set by the access middleware)."""
    principal = getattr(request.state, "orbit_principal", None) if request is not None else None
    return principal or current_principal() or authenticate(authorization)


def require_scope(principal, scope):
    if not principal.has(scope):
        raise scope_missing(scope)


def require_windows():
    if os.name != "nt":
        raise HTTPException(status_code=501, detail="PC controls require Windows")


def require_https(request):
    """Credentials and administration only travel over the pinned HTTPS port (8766)."""
    if request.url.scheme not in ("https", "wss"):
        raise HTTPException(status_code=426, detail="This needs Orbit's encrypted connection (HTTPS port 8766). Update the app or pair this PC again.")


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


def library_worker():
    """Scan the game library once at start, so status can name the running game."""
    try:
        LIBRARY.scan()
    except Exception:
        LOGGER.exception("Game library scan failed")


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
            game = detect_game(roots=LIBRARY.install_roots())
            # A game from the library gets its real title and ID instead of its exe name.
            match = LIBRARY.match_executable(game.get("exe")) if game else None
            title = match["title"] if match else (game["name"] if game else None)
            update.update(activeGame=title, activeGameTitle=title, activeGameID=match["id"] if match else None,
                          activeGameProcess=game["process"] if game else None)
            update.update(read_fps(game))
            update.update(audio_metrics())
            update.update(sessionLocked=session_locked(), telemetryAvailable=True, lastUpdated=timestamp())
            with STATE_LOCK:
                STATE.update(update)
                LAST_TELEMETRY = time.monotonic()
            record_history(status_snapshot())
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


def open_device_registry(master_token):
    registry = DeviceRegistry(DEVICES_PATH)
    registry.migrate_legacy(master_token)
    registry.start()
    return registry


def open_activity_log():
    ACTIVITY_PATH.parent.mkdir(parents=True, exist_ok=True)
    return ActivityLog(ACTIVITY_PATH)


def open_settings():
    return Settings(SETTINGS_PATH)


@asynccontextmanager
async def lifespan(application):
    global API_TOKEN, WIDGET_TOKEN, SPECS, HISTORY_RECORDER, DEVICE_REGISTRY, ACTIVITY, SETTINGS
    API_TOKEN = load_api_token()
    WIDGET_TOKEN = load_widget_token()
    SETTINGS = open_settings()
    ACTIVITY = open_activity_log()
    DEVICE_REGISTRY = open_device_registry(API_TOKEN)
    SPECS = basic_specs()
    HISTORY_RECORDER = SessionRecorder()
    STOP_EVENT.clear()
    threads = [threading.Thread(target=worker, daemon=True)
               for worker in (inventory_worker, telemetry_worker, sensor_worker, library_worker)]
    for thread in threads:
        thread.start()
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
    recorder, HISTORY_RECORDER = HISTORY_RECORDER, None
    if recorder is not None:
        recorder.close()
    registry, DEVICE_REGISTRY = DEVICE_REGISTRY, None
    if registry is not None:
        registry.close()
    log, ACTIVITY = ACTIVITY, None
    if log is not None:
        log.close()


app = FastAPI(title="Orbit PC Companion Agent", version=AGENT_VERSION, lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


def record_event(principal, category, action, summary, result="ok", status=None):
    """One activity entry for something that did not go through the HTTP middleware
    (WebSockets, pairing, the window on the PC). `principal` None means this PC."""
    log = ACTIVITY
    if log is None:
        return
    device_id, name = (principal.device_id, principal.name) if principal is not None else PC_ACTOR
    log.record(device_id, name, category, action, summary, result, status)


def activity_observer(context, status):
    """After every authenticated request: the activity log, input sessions, notifications."""
    principal = context.principal
    if context.path.startswith("/api/input/") and status is not None and status < 400:
        note_input_session(principal)
    if not context.policy.logs(context.method):
        return
    category, action, summary = describe(context, status)
    result = result_for(status)
    log = ACTIVITY
    if log is not None:
        log.record(principal.device_id, principal.name, category, action, summary, result, status)
    if result != "ok":
        return
    if category == "files" and action in ("files.upload", "files.download", "files.archive.download", "files.trash"):
        NOTIFIER.notify("files", "Orbit · Files", f"{principal.name}: {summary}", key=principal.device_id)
    elif category == "power" and action in ("action.restart", "action.shutdown", "action.sleep"):
        NOTIFIER.notify("power", "Orbit · Power", f"{summary}. Requested from {principal.name}.")


def note_input_session(principal):
    key = principal.device_id or principal.name
    if INPUT_SESSIONS.touch(key):
        record_event(principal, "input", "input.session", "Started controlling the mouse and keyboard")
        NOTIFIER.notify("inputSession", "Orbit · Remote input",
                        f"{principal.name} is controlling the mouse and keyboard.", key=key)


app.add_middleware(AccessMiddleware, authenticate=lambda authorization, address: authenticate(authorization, address),
                   observer=lambda context, status: activity_observer(context, status))


@app.exception_handler(AccessError)
async def access_error_handler(request, error):
    return error_response(error)
app.include_router(create_files_router(verify_token))
app.include_router(create_desktop_router(verify_token))
app.include_router(create_history_router(verify_token, lambda: HISTORY_RECORDER))
app.include_router(create_pairing_router(lambda: PAIRING_MANAGER))


@app.get("/api/discover")
def discover():
    # Public bootstrap hints only. Secrets and network configuration require PIN proof.
    return {"service": "orbit-agent", "version": 3, "agentVersion": AGENT_VERSION,
            "name": socket.gethostname(), "securePort": SECURE_PORT,
            "fingerprint": CERTIFICATE_FINGERPRINT, "pairingAvailable": PAIRING_MANAGER is not None}


@app.get("/api/capabilities")
def get_capabilities(request: Request, authorization: str = Header(None)):
    """What this agent supports and what the calling device may do."""
    principal = caller(request, authorization)
    return {"apiVersion": 2, "agentVersion": AGENT_VERSION,
            "scopes": [scope for scope in SCOPES if principal.has(scope)],
            "features": list(FEATURES), "deviceID": principal.device_id, "deviceName": principal.name}


def require_registry():
    if DEVICE_REGISTRY is None:
        raise HTTPException(status_code=503, detail="The device list is not ready. Restart Orbit PC Companion.")
    return DEVICE_REGISTRY


DEVICE_ID = PathParameter(pattern=r"^[0-9a-f]{32}$")


class DeviceCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=60)
    platform: str | None = Field(default=None, max_length=20)
    model: str | None = Field(default=None, max_length=60)
    scopes: list[str] | None = Field(default=None, max_length=len(SCOPES))


class DeviceUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str | None = Field(default=None, min_length=1, max_length=60)
    scopes: list[str] | None = Field(default=None, max_length=len(SCOPES))


@app.get("/api/devices")
def list_devices(request: Request, authorization: str = Header(None)):
    principal = caller(request, authorization)
    require_scope(principal, "admin")
    return {"devices": require_registry().list(principal.device_id), "scopes": list(SCOPES),
            "scopeDescriptions": dict(SCOPE_DESCRIPTIONS)}


@app.post("/api/devices", status_code=201)
def create_device(body: DeviceCreate, request: Request, authorization: str = Header(None)):
    """A token for another device of the owner (for example an Apple Watch), shown once."""
    principal = caller(request, authorization)
    require_scope(principal, "admin")
    scopes = body.scopes
    try:
        if scopes is not None and not set(scopes) <= set(SCOPES):
            raise ValueError(f"Use only these scopes: {', '.join(SCOPES)}.")
        if scopes is not None and not all(principal.has(scope) for scope in scopes):
            raise scope_missing(next(scope for scope in scopes if not principal.has(scope)))
        device, token = require_registry().register(body.name, body.platform, body.model, scopes)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    note(summary=f"Added {device['name']}", target=device["id"])
    on_device_paired(device, None)
    return {"device": device, "token": token}


@app.patch("/api/devices/{device_id}")
def update_device(body: DeviceUpdate, request: Request, device_id: str = DEVICE_ID, authorization: str = Header(None)):
    principal = caller(request, authorization)
    require_scope(principal, "admin")
    if body.name is None and body.scopes is None:
        raise HTTPException(status_code=422, detail="Send a new name or scopes.")
    try:
        device = require_registry().update(device_id, body.name, body.scopes, current_id=principal.device_id)
    except KeyError as error:
        raise HTTPException(status_code=404, detail="This device is not paired with the PC.") from error
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    changes = [f"renamed to {device['name']}" if body.name is not None else None,
               f"access: {', '.join(device['scopes']) or 'none'}" if body.scopes is not None else None]
    note(summary=f"Changed {device['name']} ({'; '.join(change for change in changes if change)})", target=device_id)
    return device


@app.delete("/api/devices/{device_id}")
def revoke_device(request: Request, device_id: str = DEVICE_ID, authorization: str = Header(None)):
    """Admin devices remove any device; every device may remove itself ("Forget this PC")."""
    principal = caller(request, authorization)
    own = principal.device_id is not None and principal.device_id == device_id
    if not own:
        require_scope(principal, "admin")
    registry = require_registry()
    try:
        name = registry.get(device_id)["name"]
        registry.revoke(device_id, "Removed itself" if own else f"Removed from {principal.name}")
    except KeyError as error:
        raise HTTPException(status_code=404, detail="This device is not paired with the PC.") from error
    note(summary=f"{name} removed itself" if own else f"Removed {name}", target=device_id)
    return {"status": "revoked", "id": device_id}


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


def register_paired_device(client, peer):
    """A PIN pairing just succeeded: give the device its own token. `apiToken` carries it
    too, so apps that know nothing about devices keep working."""
    registry = DEVICE_REGISTRY
    if registry is None:
        return {}
    device, token = registry.register(client.get("name"), client.get("platform"), client.get("model"))
    on_device_paired(device, peer)
    return {"apiToken": token, "deviceToken": token, "deviceID": device["id"], "scopes": device["scopes"]}


def on_device_paired(device, peer):
    """A new device can use this PC: log it and tell the person at the PC."""
    from orbit_devices import device_kind
    manual = device.get("name") == MANUAL_DEVICE_NAME and not device.get("platform")
    summary = "Created a manual pairing token" if manual else f"Paired {device['name']} ({device_kind(device.get('platform'))})"
    actor = current_principal()
    log = ACTIVITY
    if log is not None:
        if actor is not None:
            log.record(actor.device_id, actor.name, "devices", "device.pair", summary)
        elif manual or peer is None:
            log.record(*PC_ACTOR, "devices", "device.pair", summary)
        else:
            log.record(device["id"], device["name"], "devices", "device.pair", f"{summary} from {peer}")
    if not manual:
        NOTIFIER.notify("newDevice", "Orbit · New device",
                        f"{device['name']} can now use this PC. If this was not you, remove it in Orbit.")


MANUAL_DEVICE_NAME = "Manual setup"


def mint_manual_token():
    """For "Copy manual pairing token": a new device token for manual setup in the app.
    A previous manual token that was never used is retired, so the list stays clean."""
    registry = DEVICE_REGISTRY
    if registry is None:
        return None
    device, token = registry.register(MANUAL_DEVICE_NAME, None, None, replace_unused_named=MANUAL_DEVICE_NAME)
    on_device_paired(device, None)
    return token


@app.get("/api/network-info")
def api_network_info(request: Request, authorization: str = Header(None)):
    verify_token(authorization)
    return get_local_network_details((request.scope.get("server") or (None,))[0])


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


@app.get("/api/status")
def get_status(authorization: str = Header(None)):
    verify_token(authorization)
    return status_snapshot()


@app.post("/api/widget/pairing")
def widget_pairing(request: Request, authorization: str = Header(None)):
    verify_token(authorization)
    require_https(request)
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
        result = terminate_process(pid, expectedCreateTime, force)
        note(summary=f"Ended {result.get('name') or f'process {pid}'}" + (" (forced)" if force else ""))
        return result
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
    principal = websocket_principal(websocket, "/ws/input", authenticate)
    if principal is None:
        await websocket.close(code=1008)
        return
    await websocket.accept()
    note_input_session(principal)
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
    }


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
    actions = {
        "lock", "sleep", "restart", "shutdown",
        "mute", "volume_up", "volume_down",
        "media_play_pause", "media_next", "media_prev",
        "toggle_hdr", "restore_display", "kill_game",
        "show_desktop", "task_view", "alt_tab", "screenshot", "fullscreen",
    }
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
            # Windows' own countdown: the person at the PC sees who asked, and
            # POST /api/power/cancel (shutdown /a) stops it.
            principal = current_principal()
            POWER.countdown(action_name, COUNTDOWN_SECONDS, shutdown_comment(action_name, principal.name if principal else None))
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
    except (OSError, subprocess.SubprocessError, PowerUnavailable) as error:
        raise HTTPException(status_code=503, detail="Windows could not execute this action") from error
    if action_name in {"restart", "shutdown"}:
        return {"status": "sent", "executed": action_name, "delaySeconds": COUNTDOWN_SECONDS}
    return {"status": "sent", "executed": action_name}


@app.post("/api/power/cancel")
def cancel_power_action(authorization: str = Header(None)):
    """Stops a pending shutdown or restart (Windows' countdown) and any Orbit power timer."""
    verify_token(authorization)
    require_windows()
    try:
        POWER.abort()
    except NothingToCancel as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except (OSError, subprocess.SubprocessError, PowerUnavailable) as error:
        raise HTTPException(status_code=503, detail="Windows could not cancel the shutdown") from error
    note(summary="Cancelled the pending shutdown or restart")
    NOTIFIER.notify("power", "Orbit · Power", "The shutdown or restart was cancelled.")
    return {"status": "cancelled"}


@app.get("/api/activity")
def get_activity(request: Request, before: int | None = Query(None, ge=1), limit: int = Query(50, ge=1, le=200),
                 category: str | None = Query(None, max_length=20), authorization: str = Header(None)):
    """What paired devices did on this PC, newest first. Page with `nextBefore`."""
    verify_token(authorization)
    if category is not None and category not in ACTIVITY_CATEGORIES:
        raise HTTPException(status_code=422, detail=f"Unknown category. Use one of: {', '.join(ACTIVITY_CATEGORIES)}.")
    if ACTIVITY is None:
        raise HTTPException(status_code=503, detail="The activity log is not ready. Restart Orbit PC Companion.")
    return {**ACTIVITY.entries(before=before, limit=limit, category=category), "categories": list(ACTIVITY_CATEGORIES)}


def require_settings():
    if SETTINGS is None:
        raise HTTPException(status_code=503, detail="Settings are not ready. Restart Orbit PC Companion.")
    return SETTINGS


@app.get("/api/settings/notifications")
def get_notification_settings(authorization: str = Header(None)):
    verify_token(authorization)
    return require_settings().notifications()


@app.patch("/api/settings/notifications")
def update_notification_settings(changes: dict, authorization: str = Header(None)):
    verify_token(authorization)
    try:
        result = require_settings().update_notifications(changes)
    except SettingsError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    note(summary="Changed notification settings: " + ", ".join(f"{key} {'on' if value else 'off'}" for key, value in changes.items()))
    return result


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
def save_sunshine_credentials(login: SunshineLogin, request: Request, authorization: str = Header(None)):
    """Stores the Sunshine web UI login next to the agent token so `/api/sunshine/pin` can use it."""
    verify_token(authorization)
    require_https(request)
    username = login.username.strip()
    if not username or not login.password or len(username) > 128 or len(login.password) > 512:
        raise HTTPException(status_code=422, detail="Enter the Sunshine web UI username and password.")
    try:
        write_private_file(SUNSHINE_CREDENTIALS_PATH, json.dumps({"username": username, "password": login.password}))
    except OSError as error:
        raise HTTPException(status_code=503, detail="Could not save the Sunshine login on this PC") from error
    return {"status": "saved", "canSubmitPin": True}


@app.delete("/api/sunshine/credentials")
def delete_sunshine_credentials(request: Request, authorization: str = Header(None)):
    verify_token(authorization)
    require_https(request)
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


def _sunshine_entries_quietly():
    try:
        return sunshine_entries()
    except HTTPException:
        return []


LIBRARY = GameLibrary(sunshine_entries=_sunshine_entries_quietly)
COVER_ID = PathParameter(pattern=r"^[0-9a-f]{32}$")
LIBRARY_GAME_ID = PathParameter(pattern=GAME_ID.pattern)


def running_executables():
    try:
        return [process.info.get("exe") for process in psutil.process_iter(["exe"]) if process.info.get("exe")]
    except (psutil.Error, OSError):
        return []


@app.get("/api/library")
def get_library(authorization: str = Header(None)):
    """Installed Steam, Epic and GOG games. Covers by opaque ID; never paths."""
    verify_token(authorization)
    return LIBRARY.snapshot(running_executables())


@app.post("/api/library/rescan")
def rescan_library(authorization: str = Header(None)):
    verify_token(authorization)
    LIBRARY.scan(force=True)
    return LIBRARY.snapshot(running_executables())


@app.get("/api/library/covers/{cover_id}")
def get_library_cover(cover_id: str = COVER_ID, authorization: str = Header(None)):
    verify_token(authorization)
    try:
        data, media_type = LIBRARY.covers.read(cover_id)
    except (KeyError, OSError) as error:
        raise HTTPException(status_code=404, detail="This cover is not available. Refresh the library.") from error
    return Response(content=data, media_type=media_type,
                    headers={"Cache-Control": "private, max-age=86400", "X-Content-Type-Options": "nosniff"})


@app.post("/api/library/{game_id}/launch", status_code=202)
def launch_library_game(game_id: str = LIBRARY_GAME_ID, authorization: str = Header(None)):
    """Starts a game through its store: steam://rungameid/…, the Epic launcher URI, or GOG's exe."""
    verify_token(authorization)
    require_windows()
    try:
        game = LIBRARY.launch(game_id)
    except KeyError as error:
        raise HTTPException(status_code=404, detail="This game is not in the PC's library. Refresh the library.") from error
    except PermissionError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except OSError as error:
        raise HTTPException(status_code=503, detail="Windows could not start this game.") from error
    note(summary=f"Launched {game['title']}")
    return {"status": "launch_requested", "id": game_id, "title": game["title"]}


SCREEN_STREAMS = StreamSlots()


def screen_frame_source():
    return FrameSource()


@app.websocket("/ws/stream")
async def websocket_video_stream(websocket: WebSocket):
    principal = websocket_principal(websocket, "/ws/stream", authenticate)
    if principal is None:
        await websocket.close(code=1008)
        return
    await websocket.accept()
    if not HAS_SCREEN_CAPTURE:
        await websocket.close(code=1011, reason="Screen capture dependencies are unavailable")
        return
    if not SCREEN_STREAMS.acquire():
        await websocket.close(code=1013, reason="Two screen previews are already open")
        return
    record_event(principal, "screen", "screen.view", "Started viewing the screen")
    NOTIFIER.notify("screenView", "Orbit · Screen", f"{principal.name} is viewing your screen.",
                    key=principal.device_id or principal.name)
    try:
        # Capture and JPEG encoding run on the preview's own worker thread, so input and
        # every other request keep flowing while a large desktop is being encoded.
        await stream_frames(websocket.send_bytes, screen_frame_source())
    except WebSocketDisconnect:
        pass
    except NoDisplay:
        await _close_quietly(websocket, 1011, "No display is available")
    except Exception:
        LOGGER.exception("Screen preview failed")
        await _close_quietly(websocket, 1011, "Screen preview failed")
    finally:
        SCREEN_STREAMS.release()


async def _close_quietly(websocket, code, reason):
    try:
        await websocket.close(code=code, reason=reason)
    except RuntimeError:
        pass


@app.post("/api/internal/handover")
def api_handover(request: Request, authorization: str = Header(None)):
    """Asks this instance to exit so another one on the same PC can take the ports.

    Used by the per-user companion when it starts after the boot-time instance (which runs
    before anyone signs in and cannot reach the desktop). Loopback only, and only with the
    PC's own master token (`.orbit-token`), which device tokens never replace.
    """
    if not _same_secret(bearer_token(authorization), API_TOKEN):
        raise invalid_token()
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
def api_apply_update(request: Request, authorization: str = Header(None)):
    verify_token(authorization)
    require_https(request)
    from orbit_updater import FrozenBuildError, apply_update, check_for_updates
    if orbit_paths.is_frozen():
        # OrbitCompanion.exe runs from a temporary unpack folder: writing .py files
        # there would do nothing. Installing a new executable is the owner's step.
        raise HTTPException(status_code=409, detail=FrozenBuildError.MESSAGE)
    try:
        info = check_for_updates(AGENT_VERSION)
    except Exception as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    if not info.get("updateAvailable"):
        note(summary=f"Checked for an update: {AGENT_VERSION} is the latest")
        return {"status": "up_to_date", "currentVersion": AGENT_VERSION, "latestVersion": info.get("latestVersion")}
    download_url = info.get("downloadUrl")
    if not download_url:
        raise HTTPException(status_code=409, detail="No downloadable update archive is available for this release")
    try:
        result = apply_update(download_url)
        note(summary=f"Updated Orbit PC Companion to {info.get('latestVersion')}")
    except FrozenBuildError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"Could not apply update: {error}") from error
    return {
        "status": "updated",
        "currentVersion": AGENT_VERSION,
        "latestVersion": info.get("latestVersion"),
        "updatedFiles": result.files,
        "dependencies": result.dependencies,
        "restartRequired": True,
    }


def tray_status_snapshot():
    network = get_local_network_details()
    with STATE_LOCK:
        active_game = STATE.get("activeGame")
    return {
        "agentVersion": AGENT_VERSION,
        "hostname": network.get("hostname") or socket.gethostname(),
        "ipAddress": network.get("ipAddress") or "",
        "agentPort": AGENT_PORT,
        "securePort": SECURE_PORT,
        "fingerprint": CERTIFICATE_FINGERPRINT,
        "activeGame": active_game,
    }


def startup_banner(network, token, fingerprint, interactive):
    """Console lines at start. The token never reaches the background log; an interactive
    console shows only its last four characters."""
    lines = [f"Orbit PC Companion {AGENT_VERSION} · port {AGENT_PORT}",
             f"PC IP: {network.get('ipAddress') or 'No active LAN adapter'}",
             "In Orbit on iPhone, iPad, Mac or Apple TV, choose Find my PC. A one-use code will appear in a Windows dialog."]
    if interactive and token:
        lines.append(f"Manual pairing token: {orbit_paths.mask_secret(token)} (copy it from the Orbit tray menu)")
    lines += [f"Encrypted connection port: {SECURE_PORT}",
              f"Certificate SHA-256 (manual setup only): {fingerprint}",
              "Use a trusted home network; do not port-forward this agent."]
    return lines


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
        DeviceRegistry(DEVICES_PATH)  # An unreadable device list is reported here, not swallowed.
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

    CERTIFICATE_FINGERPRINT = fingerprint
    PAIRING_MANAGER = PairingManager(fingerprint, pairing_payload, register_device=register_paired_device)
    ADVERTISEMENT = OrbitAdvertisement(SECURE_PORT, fingerprint, AGENT_VERSION)
    for line in startup_banner(get_local_network_details(), API_TOKEN, fingerprint, orbit_paths.interactive_console()):
        print(line)

    STOP_EVENT.clear()
    tray = None
    if BOOT_MODE:
        print("Boot-time instance: no tray icon; hands over to the signed-in companion when it starts.")
    else:
        tray = OrbitTrayIcon(
            status_provider=tray_status_snapshot,
            on_stop=STOP_EVENT.set,
            token_provider=mint_manual_token,
            log_path=log_file,
            notify_on_start=("--tray" in args),
        )
        tray.start()
        NOTIFIER.show = tray.show_notification
        if ("--background" in args or "--tray" in args) and "--console" not in args:
            tray.set_console_visible(False)
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
        if tray is not None:
            tray.close()
