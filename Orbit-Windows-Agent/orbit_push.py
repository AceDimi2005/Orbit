"""Instant notifications on the iPhone through the Orbit push relay (DESIGN F1).

The relay protocol is `Orbit-Push-Relay/PROTOCOL.md`; this module is its agent side. The phone never
talks to the relay: it registers with this PC over the pinned TLS connection, and the PC manages the
relay channel on its behalf.

Routes (main token, HTTPS only):

- `POST /api/push/register` `{"deviceID": "UUID", "apnsToken": "hex", "environment": "sandbox|production",
  "key": "base64 of 32 bytes", "deviceName": "iPhone"}` → `{"status": "registered", "relay": "enabled|disabled"}`
- `DELETE /api/push/devices/{deviceID}` → `{"status": "removed", "existed": bool}`
- `GET /api/push/status` → `{"relayConfigured": bool, "devices": [{"deviceID", "deviceName", "registeredAt",
  "lastDeliveryAt", "lastError", "active"}], "relayError": null|"…", "lastHeartbeatAt": null|"ISO"}`

The relay URL is `DEFAULT_RELAY_URL` (empty), overridden by `ORBIT_PUSH_RELAY_URL`, then by settings
`push.relayURL`. While it is empty nothing is ever sent anywhere: events are only kept in the PC's
event log for the apps to poll.

Every event is encrypted separately for each phone with that phone's 32-byte key (AES-256-GCM, a fresh
12-byte nonce, AAD = the UTF-8 deviceID, plaintext JSON space-padded to a multiple of 128 bytes, wire
format base64(nonce ‖ ciphertext ‖ tag)). The relay only ever sees ciphertext, the APNs token and
opaque collapse ids derived from a key it never sees.

Secrets (channel id and secret, collapse key, per-phone keys and tokens) live in
`%LOCALAPPDATA%\\Orbit\\push-secrets.json` (private, written atomically through orbit_settings).

Planned downtime never raises a "PC offline" alert: `planned_offline()` tells the relay before Orbit's
own sleep/shutdown/restart (BEFORE_POWER_HOOKS), before Windows suspends the PC (PBT_APMSUSPEND, from the
tray window or, in the windowless boot-time instance, `watch_suspend_resume()`), and when Windows ends
the session (WM_ENDSESSION: shutdown, restart or sign-out started from Windows). After that no heartbeat
re-arms the relay's alarm until the PC resumes (PBT_APMRESUMEAUTOMATIC), which sends one right away.
"""
import base64
import binascii
from collections import deque
import copy
import hashlib
import hmac
import http.client
import json
import logging
import math
import os
import re
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

import orbit_events
import orbit_notify
import orbit_settings

LOGGER = logging.getLogger("orbit.push")
DEFAULT_RELAY_URL = ""
SETTINGS_SECTION = "push"
HEARTBEAT_SECONDS = 300
RECOVERY_INTERVAL_SECONDS = 600
STATUS_SYNC_EVERY = 12  # heartbeats (about an hour)
NOTIFY_TIMEOUT = 30.0
REQUEST_TIMEOUT = 10.0
OFFLINE_EXPECTED_TIMEOUT = 3.0
SYSTEM_EVENT_TIMEOUT = 1.8  # Windows gives apps about 2 s for PBT_APMSUSPEND and WM_ENDSESSION
PLANNED_QUIET_SECONDS = 120.0  # no heartbeat may re-arm the alarm right before the PC goes away
PLANNED_DEDUPE_SECONDS = 30.0  # Orbit's own sleep is followed by Windows' suspend message
RESUME_RETRY_SECONDS = (10, 30, 60)  # the network is often not back the moment the PC wakes
REGISTER_WAIT_SECONDS = 8.0
BACKOFF_SECONDS = (30, 120, 600, 1800)
ITEM_RETRY_SECONDS = (30, 120, 600)
APNS_UNCONFIGURED_RETRY = 600
CONFIG_ERROR_RETRY = 1800
MAX_DEVICES = 20
MAX_QUEUE = 200
PAD_BLOCK = 128
MAX_PLAINTEXT = 2048
RESTART_BACK_WITHIN_SECONDS = 900
RESUME_JUMP_SECONDS = 60.0
MAX_RESPONSE_BYTES = 1024 * 1024
DEVICE_NAME_LIMIT = 60
LINK = "orbit://notifications"
_DEVICE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_TOKEN = re.compile(r"^[0-9a-fA-F]{64,200}$")
_LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

# Event kind -> (ttl seconds or None for "from data", logical collapse key function).
_POLICY = {
    "temperature.high": (900, lambda event: f"temperature.{(event.get('data') or {}).get('sensor') or 'cpu'}"),
    "download.finished": (21600, lambda event: f"download.{(event.get('data') or {}).get('id') or event.get('id')}"),
    "download.failed": (21600, lambda event: f"download.{(event.get('data') or {}).get('id') or event.get('id')}"),
    "downloads.allFinished": (21600, lambda event: "downloads"),
    "task.finished": (21600, lambda event: f"task.{(event.get('data') or {}).get('taskID') or event.get('id')}"),
    "power.scheduled": (None, lambda event: "power"),
    "power.executing": (300, lambda event: "power"),
    "power.cancelled": (600, lambda event: "power"),
    "summary.ready": (604800, lambda event: "summary"),
    "webcam.connected": (300, lambda event: "webcam"),
}


# -- Encryption ---------------------------------------------------------------------------------

def collapse_id(collapse_key, logical_key):
    """Opaque collapse id for one logical key (PROTOCOL §5.5)."""
    digest = hmac.new(collapse_key, logical_key.encode("utf-8"), hashlib.sha256).digest()
    return "c." + base64.urlsafe_b64encode(digest).decode("ascii")[:16]


def padded_plaintext(message):
    """Compact UTF-8 JSON, right-padded with spaces to a multiple of 128 bytes and at most 2048
    bytes (the body, then the title, are shortened to fit)."""
    message = dict(message)
    for field in ("body", "title"):
        while True:
            plain = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            padded_length = len(plain) + (-len(plain) % PAD_BLOCK)
            if padded_length <= MAX_PLAINTEXT:
                return plain + b" " * (padded_length - len(plain))
            text = str(message.get(field) or "")
            if not text:
                break
            excess = padded_length - MAX_PLAINTEXT
            keep = max(0, len(text) - max(1, excess // 2) - 1)
            message[field] = (text[:keep].rstrip() + "…") if keep else ""
    plain = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return plain + b" " * (-len(plain) % PAD_BLOCK)


def seal(key, device_id, message):
    """base64(nonce ‖ ciphertext ‖ tag) of the padded message for one device (PROTOCOL §6)."""
    if not isinstance(key, (bytes, bytearray)) or len(key) != 32:
        raise ValueError("A push key must be 32 bytes")
    nonce = os.urandom(12)
    sealed = AESGCM(bytes(key)).encrypt(nonce, padded_plaintext(message), device_id.encode("utf-8"))
    return base64.b64encode(nonce + sealed).decode("ascii")


def event_message(event, hostname):
    try:
        timestamp = int(orbit_events.event_epoch(event))
    except (KeyError, TypeError, ValueError):
        timestamp = int(time.time())
    return {"v": 1, "pc": hostname, "id": event.get("id") or 0, "kind": event.get("kind"),
            "title": event.get("title") or "", "body": event.get("body") or "", "ts": timestamp, "link": LINK}


def offline_message(hostname, now=None):
    return {"v": 1, "pc": hostname, "id": 0, "kind": "pc.offline", "title": "PC offline",
            "body": f"{hostname} stopped responding.", "ts": int(now if now is not None else time.time()), "link": LINK}


def delivery_policy(event):
    """(level, ttl, logical collapse key, literal collapse id or None) for one event."""
    kind = event.get("kind") or ""
    level = event.get("level") if event.get("level") in orbit_events.LEVELS else "active"
    if kind == "pc.online":
        return level, 3600, None, "offline"
    ttl, logical = _POLICY.get(kind, (3600, lambda item: kind or "event"))
    if ttl is None:
        delay = (event.get("data") or {}).get("delaySeconds")
        ttl = int(delay) if isinstance(delay, (int, float)) and not isinstance(delay, bool) and 0 < delay <= 604800 else 300
    return level, int(ttl), logical(event), None


def decode_key(value):
    """The phone's key: standard or URL-safe base64 of exactly 32 bytes."""
    if not isinstance(value, str) or not 40 <= len(value.strip()) <= 64:
        raise ValueError("key must be the base64 text of a 32-byte key.")
    text = value.strip()
    text += "=" * (-len(text) % 4)
    try:
        raw = base64.b64decode(text, altchars=b"-_" if ("-" in text or "_" in text) else None, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("key must be the base64 text of a 32-byte key.") from error
    if len(raw) != 32:
        raise ValueError("key must be the base64 text of a 32-byte key.")
    return raw


def validate_relay_url(value):
    """The normalized relay base URL (no trailing slash). Raises ValueError for anything that is not
    https:// (plain http:// is accepted only for this PC itself, for `wrangler dev`)."""
    if not isinstance(value, str):
        raise ValueError("The push relay URL must be text.")
    text = value.strip().rstrip("/")
    parts = urllib.parse.urlsplit(text)
    host = (parts.hostname or "").lower()
    if not host or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError("The push relay URL must look like https://orbit-push-relay.example.workers.dev.")
    if parts.scheme == "https" or (parts.scheme == "http" and host in _LOCAL_HOSTS):
        return text
    raise ValueError("The push relay URL must start with https://.")


# -- Relay client --------------------------------------------------------------------------------

class RelayError(Exception):
    """A failed relay request. `status` is None for network errors and timeouts."""

    def __init__(self, status, code, message, retry_after=None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retry_after = retry_after

    @property
    def channel_lost(self):
        return self.status == 401 or (self.status == 404 and self.code == "channel_not_found")

    @property
    def transient(self):
        return self.status is None or self.status == 429 or (self.status >= 500 and self.code != "apns_not_configured")


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # the relay never redirects; a redirect would carry the channel secret elsewhere


def _retry_after(headers, data):
    for candidate in ((headers or {}).get("Retry-After") if headers else None, (data or {}).get("retryAfterSeconds")):
        try:
            seconds = float(candidate)
        except (TypeError, ValueError):
            continue
        if math.isfinite(seconds) and seconds >= 0:
            return min(seconds, 24 * 3600)
    return None


class RelayClient:
    def __init__(self, base_url, *, user_agent, opener=None):
        self.base_url = validate_relay_url(base_url)
        self._user_agent = user_agent
        self._opener = opener or urllib.request.build_opener(_NoRedirects())

    def request(self, method, path, *, body=None, secret=None, timeout=REQUEST_TIMEOUT):
        """(status, json dict). Raises RelayError for HTTP errors, network errors and timeouts."""
        data = json.dumps(body if body is not None else {}, separators=(",", ":")).encode("utf-8") if method in ("POST", "PUT") else None
        headers = {"Accept": "application/json", "User-Agent": self._user_agent}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if secret:
            headers["Authorization"] = f"Bearer {secret}"
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with self._opener.open(request, timeout=timeout) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                status = response.status
        except urllib.error.HTTPError as error:
            try:
                raw = error.read(MAX_RESPONSE_BYTES)
                parsed = json.loads(raw.decode("utf-8")) if raw else {}
            except (ValueError, OSError, UnicodeDecodeError):
                parsed = {}
            parsed = parsed if isinstance(parsed, dict) else {}
            message = str(parsed.get("message") or f"The push relay answered HTTP {error.code}.")
            raise RelayError(error.code, str(parsed.get("error") or ""), message, _retry_after(error.headers, parsed)) from None
        except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as error:
            reason = getattr(error, "reason", None) or error
            raise RelayError(None, "network", f"Could not reach the push relay ({reason}).") from None
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            raise RelayError(status, "bad_response", "The push relay sent an answer Orbit could not read.") from None
        return status, parsed if isinstance(parsed, dict) else {}


# -- Device and channel storage ------------------------------------------------------------------

class PushStore:
    """Phones and the relay channel, in the private secrets file."""

    def __init__(self, path=None):
        self.settings = orbit_settings.SettingsStore(path if path is not None else orbit_settings.default_secrets_path())

    def devices(self):
        value = self.settings.get("devices", {})
        return value if isinstance(value, dict) else {}

    def device(self, device_id):
        return self.devices().get(device_id)

    def put_device(self, device_id, record):
        def change(devices):
            devices = devices if isinstance(devices, dict) else {}
            devices[device_id] = record
            return devices
        self.settings.modify("devices", change, {})

    def update_device(self, device_id, **changes):
        def change(devices):
            devices = devices if isinstance(devices, dict) else {}
            if device_id in devices:
                devices[device_id] = {**devices[device_id], **changes}
            return devices
        self.settings.modify("devices", change, {})

    def remove_device(self, device_id):
        removed = []

        def change(devices):
            devices = devices if isinstance(devices, dict) else {}
            if devices.pop(device_id, None) is not None:
                removed.append(device_id)
            return devices
        self.settings.modify("devices", change, {})
        return bool(removed)

    def channel(self):
        value = self.settings.get("channel", None)
        if isinstance(value, dict) and value.get("channelId") and value.get("pcSecret") and value.get("relayURL"):
            return value
        return None

    def set_channel(self, channel):
        if channel is None:
            self.settings.remove("channel")
        else:
            self.settings.replace("channel", channel)


def _key_of(record):
    try:
        return decode_key(record.get("key", ""))
    except (ValueError, AttributeError):
        return None


def _now_iso(clock):
    return orbit_events.iso_timestamp(clock())


# -- The service ---------------------------------------------------------------------------------

class PushService:
    """Registers phones, keeps the relay channel alive and delivers events (one worker thread)."""

    def __init__(self, *, store=None, settings=None, agent_version="", clock=time.time, monotonic=time.monotonic,
                 hostname=None, opener=None, environ=None, on_back_online=None, boot_task_installed=None):
        self.store = store or PushStore()
        self._settings = settings
        self._user_agent = f"OrbitAgent/{agent_version or '0'}"
        self._clock = clock
        self._monotonic = monotonic
        self._hostname = hostname
        self._opener = opener
        self._environ = environ if environ is not None else os.environ
        self._on_back_online = on_back_online
        self._boot_task_installed = boot_task_installed
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._idle = threading.Condition(self._lock)
        self._control = deque()
        self._queue = deque()
        self._active_url = None
        self._backoff_index = 0
        self._next_attempt = 0.0  # notify backoff
        self._control_backoff = 0
        self._control_next = 0.0  # backoff of phone registrations, removals and the start-up sync
        self._quiet_until = 0.0
        self._resume_retries = 0
        self._offline_call = None
        self._last_planned = None
        self._next_heartbeat = 0.0
        self._heartbeats = 0
        self._last_recovery = None
        self._needs_sync = False
        self._reput_attempted = set()
        self._thread = None
        self._sending = False
        self.relay_error = None
        self.last_heartbeat = None

    # Configuration --------------------------------------------------------------------------------

    def hostname(self):
        return self._hostname or socket.gethostname()

    def relay_url(self):
        """(url, error): the configured relay URL ("" when disabled) and why it was refused."""
        candidate = DEFAULT_RELAY_URL
        environment = self._environ.get("ORBIT_PUSH_RELAY_URL")
        if environment is not None and environment.strip():
            candidate = environment
        try:
            settings = self._settings if self._settings is not None else orbit_settings.shared_store()
            section = settings.get(SETTINGS_SECTION, {}) or {}
        except Exception:
            section = {}
        if isinstance(section, dict) and isinstance(section.get("relayURL"), str):
            candidate = section["relayURL"]
        if not candidate or not candidate.strip():
            return "", None
        try:
            return validate_relay_url(candidate), None
        except ValueError as error:
            return "", str(error)

    def _client(self, url=None):
        return RelayClient(url or self._active_url, user_agent=self._user_agent, opener=self._opener)

    def _set_error(self, message):
        with self._lock:
            self.relay_error = message
        if message:
            LOGGER.warning("Push relay: %s", message)

    def _boot_task(self):
        try:
            return bool(self._boot_task_installed()) if self._boot_task_installed else False
        except Exception:
            return False

    # API: registration ---------------------------------------------------------------------------

    def register(self, body):
        if not isinstance(body, dict):
            raise ValueError("Send the registration as a JSON object.")
        device_id = body.get("deviceID")
        token = body.get("apnsToken")
        environment = body.get("environment")
        name = body.get("deviceName")
        if not isinstance(device_id, str) or not _DEVICE_ID.match(device_id):
            raise ValueError("deviceID must be 1 to 64 letters, digits, dots, dashes or underscores.")
        if not isinstance(token, str) or not _TOKEN.match(token) or len(token) % 2:
            raise ValueError("apnsToken must be the APNs device token as hex.")
        if environment not in ("sandbox", "production"):
            raise ValueError("environment must be \"sandbox\" or \"production\".")
        key = decode_key(body.get("key"))
        if name is not None and not isinstance(name, str):
            raise ValueError("deviceName must be text.")
        name = orbit_notify.clean_text(name or "", DEVICE_NAME_LIMIT) or "iPhone"
        devices = self.store.devices()
        existing = devices.get(device_id)
        if existing is None and len(devices) >= MAX_DEVICES:
            raise OverflowError(f"This PC already has {MAX_DEVICES} devices set up for notifications. Remove one in Orbit first.")
        record = {
            "apnsToken": token.lower(), "environment": environment, "key": base64.b64encode(key).decode("ascii"),
            "deviceName": name, "registeredAt": _now_iso(self._clock), "active": True,
            "lastDeliveryAt": (existing or {}).get("lastDeliveryAt"), "lastError": None,
        }
        self.store.put_device(device_id, record)
        self._reput_attempted.discard(device_id)
        url, _ = self.relay_url()
        if not url:
            return {"status": "registered", "relay": "disabled"}
        done = threading.Event()
        with self._lock:
            self._control.append(("register", device_id, done))
            # A phone registering now gets a fresh try, whatever went wrong before.
            self._control_next, self._control_backoff = 0.0, 0
            self._next_attempt, self._backoff_index = 0.0, 0
        self._wake.set()
        if self._thread is not None and self._thread.is_alive():
            done.wait(REGISTER_WAIT_SECONDS)
        return {"status": "registered", "relay": "enabled"}

    def unregister(self, device_id):
        existed = self.store.remove_device(device_id)
        if existed:
            with self._lock:
                self._control.append(("delete", device_id, threading.Event()))
            self._wake.set()
        return {"status": "removed", "existed": existed}

    def status(self):
        url, problem = self.relay_url()
        devices = []
        for device_id, record in sorted(self.store.devices().items(), key=lambda pair: pair[1].get("registeredAt") or ""):
            devices.append({"deviceID": device_id, "deviceName": record.get("deviceName") or "iPhone",
                            "registeredAt": record.get("registeredAt"), "lastDeliveryAt": record.get("lastDeliveryAt"),
                            "lastError": record.get("lastError"), "active": bool(record.get("active", True))})
        with self._lock:
            error = problem or (self.relay_error if url else None)
            heartbeat = self.last_heartbeat
        return {"relayConfigured": bool(url), "devices": devices, "relayError": error,
                "lastHeartbeatAt": orbit_events.iso_timestamp(heartbeat) if heartbeat else None}

    # Events ------------------------------------------------------------------------------------

    def active_devices(self):
        return {device_id: record for device_id, record in self.store.devices().items()
                if record.get("active", True) and _key_of(record) is not None}

    def dispatch(self, event):
        """orbit_events dispatcher: encrypts the event for every active phone and queues it."""
        with self._lock:
            url = self._active_url
        if url is None:
            url, _ = self.relay_url()  # before the worker's first pass (pc.online at start)
        if not url or not isinstance(event, dict) or not event.get("id"):
            return False
        devices = self.active_devices()
        if not devices:
            return False
        level, ttl, logical, literal = delivery_policy(event)
        message = event_message(event, self.hostname())
        items = {}
        for device_id, record in devices.items():
            try:
                items[device_id] = seal(_key_of(record), device_id, message)
            except Exception:
                LOGGER.exception("Could not encrypt event %s for a device", event.get("id"))
        if not items:
            return False
        now = self._monotonic()
        job = {"eventID": event["id"], "kind": event.get("kind"), "items": items, "level": level, "ttl": ttl,
               "logical": logical, "literal": literal, "deadline": now + ttl, "attempt": 0, "nextAt": now}
        with self._lock:
            self._queue.append(job)
            while len(self._queue) > MAX_QUEUE:
                dropped = self._queue.popleft()
                LOGGER.warning("Push queue is full; event %s reaches phones by polling only", dropped["eventID"])
        self._wake.set()
        return True

    def pending(self):
        with self._lock:
            return len(self._queue)

    def flush(self, timeout=4.0):
        """Waits (bounded) until queued events were sent or given up on. Returns True when empty."""
        deadline = self._monotonic() + max(0.0, timeout)
        self._wake.set()
        with self._idle:
            while self._queue or self._sending:
                remaining = deadline - self._monotonic()
                if remaining <= 0:
                    return False
                self._idle.wait(min(remaining, 0.2))
        return True

    # Relay operations (worker thread) -------------------------------------------------------------

    def _channel_request(self, method, suffix, body=None, timeout=REQUEST_TIMEOUT, channel=None):
        channel = channel or self.store.channel()
        if channel is None:
            raise RelayError(404, "channel_not_found", "This PC has no relay channel yet.")
        client = self._client(channel["relayURL"])
        return client.request(method, f"/v1/c/{channel['channelId']}{suffix}", body=body,
                              secret=channel["pcSecret"], timeout=timeout)

    def _create_channel(self):
        status, data = self._client().request("POST", "/v1/channels", body={})
        channel_id, secret = data.get("channelId"), data.get("pcSecret")
        if not isinstance(channel_id, str) or not re.match(r"^[0-9a-f]{32}$", channel_id) \
                or not isinstance(secret, str) or not re.match(r"^[A-Za-z0-9_-]{43}$", secret):
            raise RelayError(status, "bad_response", "The push relay sent a channel Orbit could not use.")
        channel = {"relayURL": self._active_url, "channelId": channel_id, "pcSecret": secret,
                   "collapseKey": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
                   "createdAt": _now_iso(self._clock)}
        # Saved before it is used: the secret cannot be fetched again.
        self.store.set_channel(channel)
        LOGGER.info("Created a push relay channel")
        return channel

    def _ensure_channel(self):
        """(channel, created)."""
        channel = self.store.channel()
        if channel is not None and channel["relayURL"] == self._active_url:
            return channel, False
        return self._create_channel(), True

    def _put_device(self, device_id, reregistered=False, channel=None):
        """PUTs one device. Returns True when the relay registered it. Raises RelayError for
        channel loss and transient failures."""
        record = self.store.device(device_id)
        key = _key_of(record) if record else None
        if record is None or key is None:
            return False
        body = {"token": record["apnsToken"], "env": record["environment"],
                "offlineCt": seal(key, device_id, offline_message(self.hostname(), self._clock())),
                "reregistered": bool(reregistered)}
        try:
            _, data = self._channel_request("PUT", f"/devices/{device_id}", body=body, channel=channel)
        except RelayError as error:
            if error.channel_lost or error.transient:
                raise
            if error.status == 410:
                self.store.update_device(device_id, active=False, lastError="Unregistered")
            elif error.status == 409:
                self.store.update_device(device_id, lastError="The relay already has 20 devices for this PC. Remove one in Orbit.")
            else:
                LOGGER.error("The push relay refused a device (%s %s): %s", error.status, error.code, error.message)
                self.store.update_device(device_id, lastError=error.message[:200])
            return False
        for replaced in data.get("replaced") or []:
            if isinstance(replaced, str) and replaced != device_id:
                self.store.remove_device(replaced)
        self.store.update_device(device_id, active=True, lastError=None)
        return True

    def _put_all(self, channel=None):
        for device_id in list(self.active_devices()):
            self._put_device(device_id, False, channel)

    def _quiet(self):
        with self._lock:
            return self._monotonic() < self._quiet_until

    def _heartbeat(self):
        channel = self.store.channel()
        if channel is None or channel["relayURL"] != self._active_url or self._quiet():
            return False
        _, data = self._channel_request("POST", "/hb", body={}, channel=channel)
        with self._lock:
            self.last_heartbeat = self._clock()
            self._heartbeats += 1
            sync = self._heartbeats % STATUS_SYNC_EVERY == 1
        self._set_error(None)
        if data.get("offlineAlertSent") and self._on_back_online is not None:
            try:
                self._on_back_online()
            except Exception:
                LOGGER.exception("Could not announce that the PC is back online")
        if sync:
            self._sync_status(channel)
        return True

    def _sync_status(self, channel):
        """Marks devices the relay dropped after an APNs 410 during an offline alert."""
        try:
            _, data = self._channel_request("GET", "", channel=channel)
        except RelayError:
            return
        devices = self.store.devices()
        for entry in data.get("unregisteredDevices") or []:
            device_id = entry.get("deviceId") if isinstance(entry, dict) else None
            record = devices.get(device_id)
            if record and record.get("active", True) and (record.get("registeredAt") or "") <= (entry.get("unregisteredAt") or ""):
                self.store.update_device(device_id, active=False, lastError="Unregistered")
        for entry in data.get("devices") or []:
            device_id = entry.get("deviceId") if isinstance(entry, dict) else None
            record = devices.get(device_id)
            delivered = entry.get("lastDeliveryAt") if isinstance(entry, dict) else None
            if record and isinstance(delivered, str) and delivered > (record.get("lastDeliveryAt") or ""):
                self.store.update_device(device_id, lastDeliveryAt=delivered)

    def _recover(self):
        """Channel recovery (PROTOCOL §7): at most once every 10 minutes."""
        now = self._monotonic()
        with self._lock:
            if self._last_recovery is not None and now - self._last_recovery < RECOVERY_INTERVAL_SECONDS:
                resume_at = self._last_recovery + RECOVERY_INTERVAL_SECONDS
                self._next_attempt = max(self._next_attempt, resume_at)
                self._control_next = max(self._control_next, resume_at)
                recent = True
            else:
                self._last_recovery = now
                recent = False
        if recent:
            self._set_error("The push relay no longer knows this PC. Orbit will set it up again in a few minutes.")
            return False
        LOGGER.warning("The push relay lost this PC's channel; creating a new one")
        self.store.set_channel(None)
        self._reput_attempted.clear()
        if not self.active_devices():
            return True
        channel = self._create_channel()
        self._put_all(channel)
        self._heartbeat()
        return True

    def _delete_channel(self, channel):
        try:
            self._channel_request("DELETE", "", channel=channel)
        except RelayError as error:
            if not (error.channel_lost or error.status == 404):
                raise

    def _switch(self, url):
        """Applies a (new) relay URL: the agent-start flow of PROTOCOL §7."""
        channel = self.store.channel()
        if channel is not None and channel["relayURL"] != url:
            try:
                self._delete_channel(channel)
            except RelayError as error:
                LOGGER.info("Could not delete the old relay channel (%s); it expires on its own", error.message)
            self.store.set_channel(None)
        with self._lock:
            self._active_url = url
            self._needs_sync = bool(url)
            self._next_heartbeat = 0.0
        if not url:
            with self._lock:
                self._queue.clear()
                self._idle.notify_all()

    def _sync(self):
        """PUT every active device with a fresh offline message, then a heartbeat."""
        if not self.active_devices():
            channel = self.store.channel()
            if channel is not None and not self.store.devices():
                self._delete_channel(channel)
                self.store.set_channel(None)
            with self._lock:
                self._needs_sync = False
            return
        channel, _ = self._ensure_channel()
        self._put_all(channel)
        self._heartbeat()
        with self._lock:
            self._needs_sync = False
            self._next_heartbeat = self._monotonic() + HEARTBEAT_SECONDS

    def _control_job(self, job):
        kind, device_id, done = job
        try:
            if kind == "register":
                channel, created = self._ensure_channel()
                self._put_device(device_id, True, channel)
                if created:
                    self._heartbeat()
                    with self._lock:
                        self._next_heartbeat = self._monotonic() + HEARTBEAT_SECONDS
            elif kind == "delete":
                channel = self.store.channel()
                if channel is not None:
                    try:
                        self._channel_request("DELETE", f"/devices/{device_id}", channel=channel)
                    except RelayError as error:
                        if not (error.channel_lost or error.status == 404):
                            raise
                    if not self.store.devices():
                        self._delete_channel(channel)
                        self.store.set_channel(None)
        finally:
            done.set()

    def _send_job(self, job, channel):
        now = self._monotonic()
        devices = self.active_devices()
        items = {device_id: ciphertext for device_id, ciphertext in job["items"].items() if device_id in devices}
        if not items:
            return True
        key = base64.b64decode(channel["collapseKey"])
        body = {"items": items, "level": job["level"], "ttl": max(0, min(job["ttl"], int(job["deadline"] - now))),
                "collapseId": job["literal"] or collapse_id(key, job["logical"])}
        _, data = self._channel_request("POST", "/notify", body=body, timeout=NOTIFY_TIMEOUT, channel=channel)
        results = data.get("results") if isinstance(data.get("results"), dict) else {}
        retry = {}
        delivered_at = _now_iso(self._clock)
        for device_id, ciphertext in items.items():
            result = results.get(device_id) or {}
            status = result.get("status")
            if status == "sent":
                self.store.update_device(device_id, lastDeliveryAt=delivered_at, lastError=None)
            elif status == "unregistered":
                self.store.update_device(device_id, active=False, lastError="Unregistered")
            elif status == "unknown_device":
                if device_id not in self._reput_attempted:
                    self._reput_attempted.add(device_id)
                    try:
                        if self._put_device(device_id, False, channel):
                            retry[device_id] = ciphertext
                            continue
                    except RelayError as error:
                        if error.channel_lost:
                            raise
                self.store.update_device(device_id, active=False, lastError="Unregistered")
            elif status == "failed" and result.get("retryable"):
                retry[device_id] = ciphertext
            else:
                reason = str(result.get("reason") or "The relay could not deliver this notification.")[:200]
                self.store.update_device(device_id, lastError=reason)
        if not retry:
            return True
        job["items"] = retry
        immediate = all(device_id in self._reput_attempted for device_id in retry) and job["attempt"] == 0
        job["attempt"] += 1
        if job["attempt"] > len(ITEM_RETRY_SECONDS):
            return True
        job["nextAt"] = now if immediate else now + ITEM_RETRY_SECONDS[job["attempt"] - 1]
        return job["nextAt"] > job["deadline"]

    def _process_queue(self):
        now = self._monotonic()
        with self._lock:
            for job in [job for job in self._queue if job["deadline"] <= now]:
                self._queue.remove(job)
            if now < self._next_attempt:
                self._idle.notify_all()
                return
            due = [job for job in self._queue if job["nextAt"] <= now]
            self._sending = bool(due)
        try:
            for job in due:
                channel = self.store.channel()
                if channel is None or channel["relayURL"] != self._active_url:
                    if not self.active_devices():
                        with self._lock:
                            self._queue.clear()
                        return
                    channel, created = self._ensure_channel()
                    if created:
                        self._put_all(channel)
                try:
                    finished = self._send_job(job, channel)
                except RelayError as error:
                    if error.channel_lost or error.transient or error.status in (426, 503):
                        raise
                    # A request Orbit built wrongly (400/405/413): log it and never retry it.
                    LOGGER.error("The push relay refused event %s (%s %s): %s", job["eventID"], error.status, error.code, error.message)
                    self._set_error(error.message)
                    finished = True
                with self._lock:
                    self._backoff_index = 0
                    if finished and job in self._queue:
                        self._queue.remove(job)
        finally:
            with self._lock:
                self._sending = False
                self._idle.notify_all()

    def _handle_error(self, error, control=False):
        """Backoff after a failed relay operation: the notify backoff, or with `control` the separate
        one for registrations, removals and the start-up sync. Returns True when the operation may be
        retried right away (after a successful channel recovery)."""
        now = self._monotonic()
        if error.channel_lost:
            try:
                return self._recover()
            except RelayError as nested:
                return self._handle_error(nested, control) if not nested.channel_lost else False
        with self._lock:
            index = self._control_backoff if control else self._backoff_index
            backoff = BACKOFF_SECONDS[min(index, len(BACKOFF_SECONDS) - 1)]
            if error.status == 503 and error.code == "apns_not_configured":
                delay = APNS_UNCONFIGURED_RETRY
                message = "The push relay is not set up to reach Apple yet. Orbit will try again in 10 minutes."
            elif error.status == 426:
                delay = CONFIG_ERROR_RETRY
                message = "The push relay URL must use https://."
            elif error.transient:
                delay = error.retry_after if error.retry_after is not None else backoff
                message = error.message
            else:
                LOGGER.error("The push relay refused a request (%s %s): %s", error.status, error.code, error.message)
                delay, message = backoff, error.message
            if control:
                self._control_backoff += 1
                self._control_next = now + delay
            else:
                self._backoff_index += 1
                self._next_attempt = now + delay
        self._set_error(message)
        return False

    def step(self):
        """One pass of the worker: configuration, control jobs, heartbeat and the event queue."""
        url, problem = self.relay_url()
        if url != self._active_url:
            try:
                self._switch(url)
            except RelayError as error:
                self._handle_error(error)
        if problem:
            self._set_error(problem)
        if not self._active_url:
            # Disabled: phones are only stored, removals are local.
            with self._lock:
                while self._control:
                    self._control.popleft()[2].set()
            return
        # Heartbeats keep their own schedule: a notify backoff must never let the relay's offline
        # alarm run out. A failed heartbeat is not retried before the next one is due (except right
        # after a resume), and none is sent while a planned sleep or shutdown is under way.
        if self._monotonic() >= self._next_heartbeat and not self._needs_sync and not self._quiet():
            self._await_offline_call()
            with self._lock:
                self._next_heartbeat = self._monotonic() + HEARTBEAT_SECONDS
            try:
                if self._heartbeat():
                    with self._lock:
                        self._resume_retries = 0
            except RelayError as error:
                if error.channel_lost:
                    self._handle_error(error)
                else:
                    self._set_error(error.message)
                    self._retry_heartbeat_soon()
        # Registrations, removals and the start-up sync have their own backoff: a notify backoff
        # (APNs not set up on the relay, a rate limit) must not hold up a phone being set up.
        if (self._needs_sync or self._control) and self._monotonic() >= self._control_next:
            try:
                if self._needs_sync:
                    self._sync()
                self._run_control_jobs()
                with self._lock:
                    self._control_backoff = 0
            except RelayError as error:
                if self._handle_error(error, control=True):
                    self._wake.set()
                return
        if self._monotonic() < self._next_attempt:
            return
        try:
            self._process_queue()
        except RelayError as error:
            if self._handle_error(error):
                self._wake.set()

    def _run_control_jobs(self):
        while True:
            with self._lock:
                job = self._control[0] if self._control else None
            if job is None:
                return
            try:
                self._control_job(job)
            except RelayError as error:
                if error.channel_lost or error.transient or error.status in (426, 503):
                    raise
                LOGGER.error("The push relay refused a %s request (%s %s): %s", job[0], error.status, error.code, error.message)
                self._set_error(error.message)
            with self._lock:
                if self._control and self._control[0] is job:
                    self._control.popleft()

    def _retry_heartbeat_soon(self):
        with self._lock:
            if self._resume_retries > 0:
                index = len(RESUME_RETRY_SECONDS) - self._resume_retries
                self._next_heartbeat = self._monotonic() + RESUME_RETRY_SECONDS[index]
                self._resume_retries -= 1

    def _await_offline_call(self):
        """A heartbeat must not overtake an offline-expected call that is still on its way (it was
        cut short by a suspend): the relay would end up with no alarm until the next heartbeat."""
        with self._lock:
            call = self._offline_call
        if call is not None and call.is_alive() and call is not threading.current_thread():
            call.join(OFFLINE_EXPECTED_TIMEOUT + 0.5)

    def _rearm(self):
        """After a resume: heartbeat now (re-arming the alarm, learning whether an alert went out)
        and retry everything that was waiting."""
        with self._lock:
            self._quiet_until = 0.0
            self._next_heartbeat = 0.0
            self._next_attempt = 0.0
            self._control_next = 0.0
            self._resume_retries = len(RESUME_RETRY_SECONDS)
        self._wake.set()

    def _next_wait(self):
        now = self._monotonic()
        with self._lock:
            moments = [max(self._next_heartbeat, self._quiet_until), now + 15.0]
            if self._next_attempt > now:
                moments.append(self._next_attempt)
            if (self._control or self._needs_sync) and self._control_next > now:
                moments.append(self._control_next)
            moments.extend(job["nextAt"] for job in self._queue)
        return max(0.2, min(moments) - now)

    def run(self, stop_event):
        wall, mono = self._clock(), self._monotonic()
        while not stop_event.is_set():
            try:
                self.step()
            except Exception:
                LOGGER.exception("The push worker failed; retrying shortly")
                with self._lock:
                    self._next_attempt = self._monotonic() + BACKOFF_SECONDS[0]
            self._wake.wait(self._next_wait())
            self._wake.clear()
            new_wall, new_mono = self._clock(), self._monotonic()
            if (new_wall - wall) - (new_mono - mono) > RESUME_JUMP_SECONDS:
                # The PC slept (or the clock jumped): re-arm the relay's offline alarm right away.
                self._rearm()
            wall, mono = new_wall, new_mono

    def start(self, stop_event):
        def run():
            self.run(stop_event)
        self._thread = threading.Thread(target=run, name="orbit-push", daemon=True)
        self._thread.start()
        return self._thread

    def wake(self):
        self._wake.set()

    # Planned power actions --------------------------------------------------------------------

    def planned_offline(self, action=None, timeout=None):
        """Tells the relay this PC is about to sleep, shut down or restart, so no "PC offline" alert
        is sent. Best effort: returns within `timeout` (3 s) whatever happens. Heartbeats pause for
        two minutes (or until the PC resumes) so none re-arms the alarm before the PC is gone."""
        timeout = OFFLINE_EXPECTED_TIMEOUT if timeout is None else timeout
        with self._lock:
            url = self._active_url
        if not url:
            url, _ = self.relay_url()
        channel = self.store.channel()
        if not url or channel is None or channel["relayURL"] != url:
            return False
        body = {}
        if action == "restart" and self._boot_task():
            body = {"backWithinSeconds": RESTART_BACK_WITHIN_SECONDS}
        outcome = []

        def call():
            try:
                self._channel_request("POST", "/offline-expected", body=body, timeout=timeout, channel=channel)
                outcome.append(True)
            except RelayError as error:
                LOGGER.info("Could not tell the push relay about the planned %s: %s", action or "power action", error.message)
            except Exception:
                LOGGER.exception("Could not tell the push relay about the planned power action")

        worker = threading.Thread(target=call, name="orbit-push-offline", daemon=True)
        with self._lock:
            self._quiet_until = max(self._quiet_until, self._monotonic() + PLANNED_QUIET_SECONDS)
            self._offline_call = worker
        worker.start()
        worker.join(timeout + 0.2)
        if outcome:
            with self._lock:
                self._last_planned = self._monotonic()
        return bool(outcome)

    def _announced_recently(self):
        """True (and the quiet period extended) when a planned offline went out moments ago, for
        example Orbit's own sleep, which Windows then announces again with PBT_APMSUSPEND."""
        with self._lock:
            now = self._monotonic()
            if self._last_planned is None or now - self._last_planned >= PLANNED_DEDUPE_SECONDS:
                return False
            self._quiet_until = max(self._quiet_until, now + PLANNED_QUIET_SECONDS)
            return True

    def system_suspending(self):
        """Windows is about to sleep or hibernate (PBT_APMSUSPEND), whoever started it."""
        if self._announced_recently():
            return True
        return self.planned_offline("sleep", timeout=SYSTEM_EVENT_TIMEOUT)

    def session_ending(self):
        """Windows is shutting down, restarting or signing out (WM_ENDSESSION). Restart and shutdown
        look the same here, so the relay is told without `backWithinSeconds`: no alert at all."""
        if self._announced_recently():
            return True
        return self.planned_offline("shutdown", timeout=SYSTEM_EVENT_TIMEOUT)

    def system_resumed(self):
        """The PC woke up (PBT_APMRESUMEAUTOMATIC / PBT_APMRESUMESUSPEND)."""
        self._rearm()


# -- Shared service, power hook and routes --------------------------------------------------------

_SERVICE = None
_SERVICE_LOCK = threading.Lock()


def shared_service():
    with _SERVICE_LOCK:
        return _SERVICE


def set_shared_service(service):
    global _SERVICE
    with _SERVICE_LOCK:
        _SERVICE = service


def planned_offline(action=None):
    """BEFORE_POWER_HOOKS entry: forwards to the running service (no-op without one)."""
    service = shared_service()
    return service.planned_offline(action) if service is not None else False


planned_offline.accepts_action = True

# Windows power messages (WM_POWERBROADCAST wParam values).
PBT_APMSUSPEND = 0x0004
PBT_APMRESUMESUSPEND = 0x0007
PBT_APMRESUMEAUTOMATIC = 0x0012
DEVICE_NOTIFY_CALLBACK = 2
_POWER_BROADCASTS = {PBT_APMSUSPEND: "suspend", PBT_APMRESUMESUSPEND: "resume", PBT_APMRESUMEAUTOMATIC: "resume"}


def power_broadcast_kind(value):
    """"suspend", "resume" or None for a WM_POWERBROADCAST wParam (or a suspend/resume callback type)."""
    try:
        return _POWER_BROADCASTS.get(int(value))
    except (TypeError, ValueError):
        return None


def system_power_event(kind):
    """What Windows says about power, from the tray window or the boot-time callback: "suspend",
    "resume" or "session-ending". Runs synchronously and returns within about 2 seconds."""
    service = shared_service()
    if service is None:
        return False
    if kind == "suspend":
        return service.system_suspending()
    if kind == "session-ending":
        return service.session_ending()
    if kind == "resume":
        service.system_resumed()
        return True
    return False


def watch_suspend_resume(listener=None, powrprof=None):
    """Suspend and resume notifications for a process without a window (the boot-time instance), via
    PowerRegisterSuspendResumeNotification (Windows 8+). Returns a function that stops them; a no-op
    away from Windows or when Windows refuses."""
    listener = listener or system_power_event
    if powrprof is None and os.name != "nt":
        return lambda: None
    try:
        import ctypes
        from ctypes import wintypes
        factory = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)
        routine_type = factory(ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p)

        class SubscribeParameters(ctypes.Structure):
            _fields_ = [("Callback", routine_type), ("Context", ctypes.c_void_p)]

        def callback(context, kind, setting):
            event = power_broadcast_kind(kind)
            if event is not None:
                try:
                    listener(event)
                except Exception:
                    LOGGER.exception("Could not handle the Windows %s notification", event)
            return 0

        routine = routine_type(callback)
        parameters = SubscribeParameters(routine, None)
        handle = ctypes.c_void_p()
        library = powrprof if powrprof is not None else ctypes.WinDLL("powrprof")
        register = library.PowerRegisterSuspendResumeNotification
        register.argtypes = [wintypes.DWORD, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        register.restype = wintypes.DWORD
        status = register(DEVICE_NOTIFY_CALLBACK, ctypes.byref(parameters), ctypes.byref(handle))
    except Exception:
        LOGGER.warning("Windows sleep notifications are not available; a sleep may cause a \"PC offline\" alert", exc_info=True)
        return lambda: None
    if status != 0:
        LOGGER.warning("Windows refused sleep notifications (error %s); a sleep may cause a \"PC offline\" alert", status)
        return lambda: None
    keep = [routine, parameters]

    def stop():
        if not keep:
            return
        try:
            unregister = library.PowerUnregisterSuspendResumeNotification
            unregister.argtypes = [ctypes.c_void_p]
            unregister.restype = wintypes.DWORD
            unregister(handle)
        except Exception:
            LOGGER.debug("Could not stop the sleep notifications", exc_info=True)
        keep.clear()
    stop.callback = callback  # for tests
    return stop


def boot_task_installed_once():
    """Whether the boot-time scheduled task exists (checked once; Windows only)."""
    cache = boot_task_installed_once.__dict__
    if "value" not in cache:
        value = False
        if os.name == "nt":
            try:
                from orbit_tray import BootTaskManager
                value = BootTaskManager().is_installed()
            except Exception:
                value = False
        cache["value"] = value
    return cache["value"]


def create_push_router(verify_control, service_provider=shared_service):
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Notifications need Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/push", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    def service():
        current = service_provider()
        if current is None:
            raise HTTPException(503, "Notifications are still starting on the PC. Try again in a moment.")
        return current

    @router.post("/register")
    def register_device(body: object = Body(None)):
        current = service()
        try:
            return current.register(body)
        except OverflowError as error:
            raise HTTPException(409, str(error)) from error
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        except OSError as error:
            raise HTTPException(503, "The PC could not save this device. Try again in a moment.") from error

    @router.delete("/devices/{device_id}")
    def remove_device(device_id: str):
        if not _DEVICE_ID.match(device_id):
            raise HTTPException(422, "That is not a valid device ID.")
        try:
            return service().unregister(device_id)
        except OSError as error:
            raise HTTPException(503, "The PC could not remove this device. Try again in a moment.") from error

    @router.get("/status")
    def push_status():
        return service().status()

    return router
