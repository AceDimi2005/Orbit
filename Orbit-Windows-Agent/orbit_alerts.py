"""What the PC tells the user about, and the temperature watch (DESIGN F1).

`GET /api/alerts` and `PUT /api/alerts` (main token, HTTPS only) read and replace the alert settings
stored on the PC (settings section `alerts`), so every phone paired with this PC sees the same choices:

    {"temperature": {"enabled": true, "cpu": 90, "gpu": 85, "forSeconds": 30},
     "downloads": {"enabled": true}, "tasks": {"enabled": true}, "online": {"enabled": true},
     "summary": {"enabled": true}, "pcToasts": true}

PUT is a full replace: anything left out goes back to its default. Unknown keys are ignored.

`TemperatureMonitor.observe(snapshot)` runs on every telemetry tick. A sensor (CPU or GPU) has to stay
at or above its threshold for `forSeconds` before `temperature.high` is emitted. After an alert the
sensor is re-armed only once it drops 5 °C below the threshold, and alerts for one sensor are at least
10 minutes apart.

`announce_online()` emits `pc.online` when the agent starts. It stays quiet when this instance took
the ports over from the boot-time instance (which already announced the boot), and when the agent
was running moments ago in the same Windows boot (an update or a restart of Orbit itself): same boot
time within 10 s and a "still alive" mark from the last 10 minutes. The boot time alone is not
enough: with Fast Startup, Windows keeps its boot time across a shutdown. `announce_back_online()` is
for the push relay's "the PC was reported offline" case.
"""
import copy
import logging
import math
import socket
import threading
import time

import psutil
from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

import orbit_events
import orbit_settings

LOGGER = logging.getLogger("orbit.alerts")
SECTION = "alerts"
STATE_SECTION = "alertsState"
DEFAULT_ALERTS = {
    "temperature": {"enabled": True, "cpu": 90, "gpu": 85, "forSeconds": 30},
    "downloads": {"enabled": True},
    "tasks": {"enabled": True},
    "online": {"enabled": True},
    "summary": {"enabled": True},
    "pcToasts": True,
}
KINDS = ("downloads", "tasks", "online", "summary")
TEMPERATURE_LIMITS = (40, 120)
FOR_SECONDS_LIMITS = (0, 600)
HYSTERESIS_DEGREES = 5.0
COOLDOWN_SECONDS = 10 * 60
# Ticks further apart than this (the agent paused, the PC slept) restart a "too hot" streak.
MAX_SAMPLE_GAP_SECONDS = 20.0
# psutil.boot_time() moves a little when Windows adjusts its clock; two real boots are always
# further apart than this (the first one has to run long enough to start the agent).
BOOT_TIME_TOLERANCE_SECONDS = 10.0
# An agent start this soon after the last "still alive" mark of the same boot is a restart of Orbit.
RESTART_WINDOW_SECONDS = 10 * 60
ALIVE_MARK_SECONDS = 5 * 60
BACK_ONLINE_QUIET_SECONDS = 10 * 60


def _store(store=None):
    return store if store is not None else orbit_settings.shared_store()


def _is_number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def _whole(value):
    """Keeps 90 as 90 (not 90.0) so the JSON looks like what the phone sent."""
    return int(value) if float(value).is_integer() else round(float(value), 1)


def _check_bool(value, label):
    if not isinstance(value, bool):
        raise ValueError(f"{label} must be true or false.")
    return value


def _check_section(body, key):
    value = body.get(key, None)
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"\"{key}\" must be an object such as {{\"enabled\": true}}.")
    return value


def validate_alerts(body):
    """The complete settings for a PUT body (missing keys take their defaults). Raises ValueError
    with a sentence the phone can show."""
    if not isinstance(body, dict):
        raise ValueError("Send the alert settings as a JSON object.")
    result = copy.deepcopy(DEFAULT_ALERTS)
    temperature = _check_section(body, "temperature")
    if "enabled" in temperature:
        result["temperature"]["enabled"] = _check_bool(temperature["enabled"], "temperature.enabled")
    low, high = TEMPERATURE_LIMITS
    for sensor, label in (("cpu", "The CPU temperature alert"), ("gpu", "The GPU temperature alert")):
        if sensor in temperature:
            value = temperature[sensor]
            if not _is_number(value) or not low <= value <= high:
                raise ValueError(f"{label} must be between {low} and {high} °C.")
            result["temperature"][sensor] = _whole(value)
    if "forSeconds" in temperature:
        value = temperature["forSeconds"]
        low_s, high_s = FOR_SECONDS_LIMITS
        if not _is_number(value) or not low_s <= value <= high_s or not float(value).is_integer():
            raise ValueError(f"forSeconds must be a whole number of seconds from {low_s} to {high_s}.")
        result["temperature"]["forSeconds"] = int(value)
    for kind in KINDS:
        section = _check_section(body, kind)
        if "enabled" in section:
            result[kind]["enabled"] = _check_bool(section["enabled"], f"{kind}.enabled")
    if "pcToasts" in body and body["pcToasts"] is not None:
        result["pcToasts"] = _check_bool(body["pcToasts"], "pcToasts")
    return result


def _merged(stored):
    """Stored settings over the defaults, keeping only values that are still valid one by one."""
    result = copy.deepcopy(DEFAULT_ALERTS)
    if not isinstance(stored, dict):
        return result
    for key, default in DEFAULT_ALERTS.items():
        if key not in stored:
            continue
        candidate = copy.deepcopy(result)
        if isinstance(default, dict):
            if not isinstance(stored[key], dict):
                continue
            for field, value in stored[key].items():
                if field not in default:
                    continue
                trial = copy.deepcopy(candidate)
                trial[key][field] = value
                try:
                    candidate = validate_alerts(trial)
                except ValueError:
                    continue
        else:
            candidate[key] = stored[key]
            try:
                candidate = validate_alerts(candidate)
            except ValueError:
                continue
        result = candidate
    return result


def current_alerts(store=None):
    """The alert settings in force (defaults for anything never saved or no longer valid)."""
    try:
        stored = _store(store).get(SECTION, None)
    except Exception:
        LOGGER.warning("Could not read the alert settings; using the defaults", exc_info=True)
        stored = None
    return _merged(stored)


def kind_enabled(kind, store=None):
    """Whether events of one family (`downloads`, `tasks`, `online`, `summary`, `temperature`) are on."""
    alerts = current_alerts(store)
    section = alerts.get(kind)
    return bool(section.get("enabled", True)) if isinstance(section, dict) else True


def save_alerts(body, store=None):
    validated = validate_alerts(body)
    return _merged(_store(store).replace(SECTION, validated))


def _duration_text(seconds):
    seconds = int(round(seconds))
    if seconds < 90:
        return f"{seconds} second{'s' if seconds != 1 else ''}"
    minutes = int(round(seconds / 60))
    return f"{minutes} minute{'s' if minutes != 1 else ''}"


class TemperatureMonitor:
    """Turns telemetry ticks into `temperature.high` events (see the module docstring)."""

    SENSORS = (("cpu", "cpuTemp", "CPU"), ("gpu", "gpuTemp", "GPU"))

    def __init__(self, *, clock=time.monotonic, config_provider=None, emit=None,
                 cooldown_seconds=COOLDOWN_SECONDS, hysteresis=HYSTERESIS_DEGREES):
        self._clock = clock
        self._config = config_provider or current_alerts
        self._emit = emit
        self._cooldown = float(cooldown_seconds)
        self._hysteresis = float(hysteresis)
        self._lock = threading.Lock()
        self._sensors = {name: {"since": None, "armed": True, "lastAlert": None, "lastSeen": None}
                         for name, _, _ in self.SENSORS}

    def state(self, sensor):
        with self._lock:
            return dict(self._sensors[sensor])

    def observe(self, snapshot):
        """Feeds one telemetry snapshot. Never raises; returns the events it emitted."""
        try:
            return self._observe(snapshot)
        except Exception:
            LOGGER.exception("The temperature alert check failed")
            return []

    def _observe(self, snapshot):
        if not isinstance(snapshot, dict):
            return []
        config = self._config()
        temperature = config.get("temperature") or {}
        enabled = bool(temperature.get("enabled", True))
        hold = float(temperature.get("forSeconds", 30))
        now = float(self._clock())
        alerts = []
        with self._lock:
            for name, field, label in self.SENSORS:
                state = self._sensors[name]
                value = snapshot.get(field)
                threshold = temperature.get(name)
                previous_seen, state["lastSeen"] = state["lastSeen"], now
                if previous_seen is not None and now - previous_seen > MAX_SAMPLE_GAP_SECONDS:
                    state["since"] = None
                if not _is_number(value) or not _is_number(threshold):
                    # A missing reading never counts towards (or against) a streak.
                    state["since"] = None
                    continue
                value = float(value)
                threshold = float(threshold)
                if value < threshold:
                    state["since"] = None
                    if not state["armed"] and value <= threshold - self._hysteresis:
                        state["armed"] = True
                    continue
                if not enabled:
                    state["since"] = None  # the hold time starts when the alert is turned on
                    continue
                if state["since"] is None:
                    state["since"] = now
                if not state["armed"]:
                    continue
                if now - state["since"] < hold:
                    continue
                if state["lastAlert"] is not None and now - state["lastAlert"] < self._cooldown:
                    continue
                state["armed"] = False
                state["lastAlert"] = now
                alerts.append((name, label, value, threshold, now - state["since"], hold))
        emitted = []
        for name, label, value, threshold, held, hold in alerts:
            emitted.append(self._send(name, label, value, threshold, max(held, hold)))
        return emitted

    def _send(self, sensor, label, value, threshold, held):
        emit = self._emit or orbit_events.emit
        if held >= 1:
            body = (f"The {label} has been at {value:.0f} °C or more for {_duration_text(held)}. "
                    f"Your alert is set to {threshold:.0f} °C.")
        else:
            body = f"The {label} reached {value:.0f} °C. Your alert is set to {threshold:.0f} °C."
        try:
            return emit("temperature.high", f"{label} is running hot", body, level="timeSensitive",
                        data={"sensor": sensor, "temperature": round(value, 1), "threshold": _whole(threshold)})
        except Exception:
            LOGGER.exception("Could not record the %s temperature alert", label)
            return None


# -- pc.online ---------------------------------------------------------------------------------

_ONLINE_LOCK = threading.Lock()
_LAST_ONLINE = None  # monotonic time of the last pc.online this process emitted
_HANDOVER = False
_LAST_ALIVE_MARK = None  # monotonic time the "still alive" mark was last written


def note_handover():
    """Called when this instance took the ports over from the boot-time instance, which already
    announced this boot."""
    global _HANDOVER
    with _ONLINE_LOCK:
        _HANDOVER = True


def _reset_online_state():
    """For tests."""
    global _LAST_ONLINE, _HANDOVER, _LAST_ALIVE_MARK
    with _ONLINE_LOCK:
        _LAST_ONLINE = None
        _HANDOVER = False
        _LAST_ALIVE_MARK = None


def _current_boot_time():
    try:
        value = psutil.boot_time()
    except Exception:
        return None
    return float(value) if _is_number(value) and value > 0 else None


def note_alive(*, store=None, clock=time.time, monotonic=time.monotonic, force=False):
    """Refreshes the "Orbit was running" mark (at most every 5 minutes; the telemetry tick calls it)."""
    global _LAST_ALIVE_MARK
    now = monotonic()
    with _ONLINE_LOCK:
        if not force and (_LAST_ALIVE_MARK is None or now - _LAST_ALIVE_MARK < ALIVE_MARK_SECONDS):
            # Nothing before this process announced its start (announce_online writes the first mark).
            return False
        _LAST_ALIVE_MARK = now
    values = {"lastAliveAt": float(clock())}
    boot = _current_boot_time()
    if boot is not None:
        values["onlineBootTime"] = boot
    try:
        _store(store).update(STATE_SECTION, values)
        return True
    except Exception:
        LOGGER.debug("Could not refresh the still-alive mark", exc_info=True)
        return False


def announce_online(*, store=None, boot_time=None, hostname=None, emit=None, handover=None, monotonic=time.monotonic,
                    clock=time.time):
    """Emits `pc.online` for an agent start (see the module docstring). Returns the event or None."""
    global _LAST_ONLINE, _LAST_ALIVE_MARK
    settings = _store(store)
    boot = boot_time if boot_time is not None else _current_boot_time()
    now = float(clock())
    with _ONLINE_LOCK:
        handed_over = _HANDOVER if handover is None else bool(handover)
    try:
        marker = settings.get(STATE_SECTION, {}) or {}
    except Exception:
        marker = {}
    marker = marker if isinstance(marker, dict) else {}
    announced, alive = marker.get("onlineBootTime"), marker.get("lastAliveAt")
    same_boot = boot is not None and _is_number(announced) and abs(float(announced) - boot) <= BOOT_TIME_TOLERANCE_SECONDS
    restarted = same_boot and _is_number(alive) and 0 <= now - float(alive) <= RESTART_WINDOW_SECONDS
    values = {"lastAliveAt": now}
    if boot is not None:
        values["onlineBootTime"] = boot
    try:
        settings.update(STATE_SECTION, values)
        with _ONLINE_LOCK:
            _LAST_ALIVE_MARK = monotonic()
    except Exception:
        LOGGER.warning("Could not remember that this start was announced", exc_info=True)
    if handed_over:
        return None
    if restarted:
        LOGGER.info("Orbit restarted within the same Windows boot; pc.online not repeated")
        return None
    if not kind_enabled("online", settings):
        return None
    name = hostname or socket.gethostname()
    try:
        # For the phone only: the PC needs no balloon about itself (the tray shows its own).
        event = (emit or orbit_events.emit)("pc.online", f"{name} is online", "Orbit is running on your PC.",
                                            level="active", data={"reason": "started"}, toast=False)
    except Exception:
        LOGGER.exception("Could not record the pc.online event")
        return None
    with _ONLINE_LOCK:
        _LAST_ONLINE = monotonic()
    return event


def announce_back_online(*, store=None, hostname=None, emit=None, monotonic=time.monotonic):
    """`pc.online` after the push relay told the phones this PC was offline (its heartbeat said
    `offlineAlertSent`). Skipped when this process announced itself in the last 10 minutes."""
    global _LAST_ONLINE
    now = monotonic()
    with _ONLINE_LOCK:
        if _LAST_ONLINE is not None and now - _LAST_ONLINE < BACK_ONLINE_QUIET_SECONDS:
            return None
        _LAST_ONLINE = now
    if not kind_enabled("online", store):
        return None
    name = hostname or socket.gethostname()
    try:
        return (emit or orbit_events.emit)("pc.online", f"{name} is back online",
                                           "Orbit can reach your PC again.", level="active",
                                           data={"reason": "reconnected"}, toast=False)
    except Exception:
        LOGGER.exception("Could not record the pc.online event")
        return None


# -- Shared monitor and routes -------------------------------------------------------------------

_MONITOR = TemperatureMonitor()


def shared_monitor():
    return _MONITOR


def observe(snapshot):
    """Telemetry hook: one call per tick with the status snapshot. Never raises."""
    try:
        note_alive()
    except Exception:
        LOGGER.debug("Could not refresh the still-alive mark", exc_info=True)
    return _MONITOR.observe(snapshot)


def create_alerts_router(verify_control, store_provider=None):
    """`GET/PUT /api/alerts` behind the caller's token check and the encrypted connection."""
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Notification settings need Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    def settings():
        return store_provider() if store_provider is not None else orbit_settings.shared_store()

    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    @router.get("/alerts")
    def get_alerts():
        return current_alerts(settings())

    @router.put("/alerts")
    def put_alerts(body: object = Body(None)):
        try:
            validated = validate_alerts(body)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        try:
            return _merged(settings().replace(SECTION, validated))
        except (OSError, ValueError) as error:
            LOGGER.warning("Could not save the alert settings", exc_info=True)
            raise HTTPException(503, "The PC could not save these alert settings. Try again in a moment.") from error

    return router
