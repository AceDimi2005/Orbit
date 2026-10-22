"""Paired devices: one token per device, stored only as a SHA-256 hash, with scopes.

Before 5.0 every app shared one master token (`.orbit-token`). On the first start
of 5.0 that token becomes one "Legacy device" with every scope, so apps paired
today keep working until the owner removes it. New pairings get their own token.

Revoked devices stay as tombstones (hash only) for a while, so their token is told
`device_revoked` instead of a generic error. Devices that never connected within a
day of being created (an interrupted pairing, an unused manual token) are dropped.
"""
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import threading
import time

SCOPES = ("read", "control", "input", "files", "admin")
SCOPE_DESCRIPTIONS = {
    "read": "See status, hardware, history, the game library and power settings",
    "control": "Run PC actions: power, volume and audio, apps, games, Sunshine",
    "input": "Mouse, keyboard, clipboard and the live screen preview",
    "files": "Browse, download and upload files",
    "admin": "Manage devices, settings, updates and the Sunshine login",
}
WATCH_SCOPES = ("read", "control", "input")
PLATFORMS = {"ios": "iOS", "ipados": "iPadOS", "macos": "macOS", "tvos": "tvOS", "watchos": "watchOS",
             "windows": "Windows", "android": "Android", "linux": "Linux", "web": "Web"}
MAX_DEVICES = 64
MAX_TOMBSTONES = 200
TOMBSTONE_SECONDS = 180 * 24 * 3600
UNUSED_SECONDS = 24 * 3600
SEEN_RESOLUTION_SECONDS = 15
FLUSH_SECONDS = 60
LEGACY_NAME = "Legacy device"


class AccessError(Exception):
    """An authentication or authorization failure with a machine-readable code."""

    def __init__(self, status, code, detail, scope=None):
        super().__init__(detail)
        self.status = status
        self.code = code
        self.detail = detail
        self.scope = scope

    def body(self):
        body = {"detail": self.detail, "code": self.code}
        if self.scope:
            body["scope"] = self.scope
        return body

    def headers(self):
        return {"WWW-Authenticate": "Bearer"} if self.status == 401 else {}


def invalid_token():
    return AccessError(401, "invalid_token", "Invalid Orbit token")


def device_revoked():
    return AccessError(401, "device_revoked", "This device was removed from the PC. Pair it again in Orbit.")


def scope_missing(scope):
    return AccessError(403, "scope_missing",
                       f"This device is not allowed to use {scope} on this PC. Allow it in Orbit on the PC.", scope)


@dataclass(frozen=True)
class Principal:
    """Who is calling: a paired device, or the master token while no registry is loaded."""
    device_id: str | None
    name: str
    scopes: frozenset = field(default_factory=frozenset)
    legacy: bool = False
    platform: str | None = None

    def has(self, scope):
        return scope is None or scope in self.scopes


LEGACY_PRINCIPAL = Principal(None, LEGACY_NAME, frozenset(SCOPES), legacy=True)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def iso(timestamp):
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(text):
    if not isinstance(text, str) or not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def clean_text(value, limit):
    text = "".join(character for character in str(value or "") if character.isprintable()).strip()
    return " ".join(text.split())[:limit].strip()


def normalize_scopes(values):
    if values is None:
        return None
    if isinstance(values, str) or not isinstance(values, (list, tuple, set, frozenset)):
        raise ValueError("Scopes must be a list.")
    unknown = sorted({str(value) for value in values} - set(SCOPES))
    if unknown:
        raise ValueError(f"Unknown scope: {', '.join(unknown)}. Use {', '.join(SCOPES)}.")
    return [scope for scope in SCOPES if scope in values]


def normalize_platform(value, name=""):
    """iOS, iPadOS, macOS, tvOS, watchOS… from what the app says, else from its name."""
    text = clean_text(value, 20)
    if text:
        return PLATFORMS.get(text.casefold().replace(" ", ""), text)
    lowered = str(name or "").casefold()
    for needle, platform in (("apple tv", "tvOS"), ("ipad", "iPadOS"), ("iphone", "iOS"), ("watch", "watchOS"),
                             ("macbook", "macOS"), ("imac", "macOS"), ("mac mini", "macOS"), ("mac studio", "macOS"),
                             ("mac pro", "macOS"), ("on mac", "macOS")):
        if needle in lowered:
            return platform
    return None


def display_name(name, platform=None):
    """"Orbit on iPhone" → "iPhone", "Apple TV · Orbit" → "Apple TV"."""
    text = clean_text(name, 80)
    for prefix in ("Orbit on ", "Orbit for "):
        if text.casefold().startswith(prefix.casefold()):
            text = text[len(prefix):]
    for suffix in (" · Orbit", " - Orbit", " (Orbit)"):
        if text.casefold().endswith(suffix.casefold()):
            text = text[:-len(suffix)]
    text = text.strip()[:60]
    return text or {"tvOS": "Apple TV", "macOS": "Mac", "iPadOS": "iPad", "watchOS": "Apple Watch"}.get(platform, "iPhone")


def device_kind(platform):
    """Words for the PC's pairing dialog: "your iPhone", "your Mac"…"""
    return {"iOS": "iPhone", "iPadOS": "iPad", "macOS": "Mac", "tvOS": "Apple TV", "watchOS": "Apple Watch",
            "Windows": "Windows PC", "Android": "Android device"}.get(platform, "device")


def default_scopes(platform):
    """Pairing with the PIN shown on this PC proves the owner is present: full access, as
    before 5.0. A watch only gets what its controls need."""
    return list(WATCH_SCOPES) if platform == "watchOS" else list(SCOPES)


class DeviceRegistry:
    def __init__(self, path, clock=time.time, flush_seconds=FLUSH_SECONDS):
        self.path = Path(path)
        self.clock = clock
        self.flush_seconds = flush_seconds
        # State lock: held briefly by every request (authentication). Write lock: orders file
        # writes, so the event loop never waits for disk I/O.
        self._lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._devices = []
        self._legacy_migrated = False
        self._dirty = False
        self._urgent = False
        self._last_flush = clock()
        self._stop = threading.Event()
        self._flusher = None
        self._load()

    # MARK: storage

    def _load(self):
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (OSError, ValueError) as error:
            # Never silently start empty over an unreadable registry: that would lock every
            # device out and then overwrite the file. Keep it aside and fail loudly.
            raise RuntimeError(f"Orbit's device list ({self.path}) is unreadable: {error}. "
                               "Restore it, or remove it to pair every device again.") from error
        devices = raw.get("devices") if isinstance(raw, dict) else None
        if not isinstance(devices, list):
            raise RuntimeError(f"Orbit's device list ({self.path}) has an unknown format.")
        self._legacy_migrated = bool(raw.get("legacyMigrated"))
        for entry in devices:
            if isinstance(entry, dict) and isinstance(entry.get("id"), str) and isinstance(entry.get("tokenHash"), str):
                entry["scopes"] = [scope for scope in SCOPES if scope in (entry.get("scopes") or [])]
                self._devices.append(entry)

    def _snapshot_locked(self):
        payload = json.dumps({"version": 1, "legacyMigrated": self._legacy_migrated, "devices": self._devices},
                             indent=1, sort_keys=True)
        self._dirty = False
        self._urgent = False
        self._last_flush = self.clock()
        return payload

    def _persist(self, payload):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(f".orbit-tmp-{secrets.token_hex(6)}")
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                    output.write(payload)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, self.path)
            finally:
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass
        except OSError:
            with self._lock:
                self._dirty = True
            raise

    @contextmanager
    def _changing(self):
        """Change the list under the state lock, then write it under the write lock only."""
        with self._write_lock:
            with self._lock:
                yield
                payload = self._snapshot_locked()
            self._persist(payload)

    def flush(self, force=True):
        with self._write_lock:
            with self._lock:
                if not (self._dirty and (force or self._urgent or self.clock() - self._last_flush >= self.flush_seconds)):
                    return
                payload = self._snapshot_locked()
            self._persist(payload)

    def start(self):
        """Write "last seen" changes in the background, never on a request."""
        if self._flusher is None:
            self._stop.clear()
            self._flusher = threading.Thread(target=self._flush_loop, name="orbit-devices", daemon=True)
            self._flusher.start()

    def _flush_loop(self):
        while not self._stop.wait(1.0):
            try:
                self.flush(force=False)
            except OSError:
                pass

    def close(self):
        self._stop.set()
        if self._flusher is not None:
            self._flusher.join(timeout=5)
            self._flusher = None
        try:
            self.flush()
        except OSError:
            pass

    # MARK: queries

    def _active(self):
        return [device for device in self._devices if not device.get("revokedAt")]

    def _prune(self):
        now = self.clock()
        kept = []
        for device in self._devices:
            created = parse_iso(device.get("createdAt")) or now
            revoked = parse_iso(device.get("revokedAt"))
            if revoked is not None and now - revoked > TOMBSTONE_SECONDS:
                continue
            if revoked is None and not device.get("lastSeenAt") and not device.get("legacy") and now - created > UNUSED_SECONDS:
                continue
            kept.append(device)
        tombstones = [device for device in kept if device.get("revokedAt")]
        if len(tombstones) > MAX_TOMBSTONES:
            oldest = sorted(tombstones, key=lambda device: device.get("revokedAt") or "")[:len(tombstones) - MAX_TOMBSTONES]
            kept = [device for device in kept if device not in oldest]
        if len(kept) != len(self._devices):
            self._devices = kept
            self._dirty = True

    @staticmethod
    def public(device, current_id=None):
        return {"id": device["id"], "name": device.get("name") or "Device", "platform": device.get("platform"),
                "model": device.get("model"), "scopes": list(device.get("scopes") or []),
                "createdAt": device.get("createdAt"), "lastSeenAt": device.get("lastSeenAt"),
                "lastAddress": device.get("lastAddress"), "legacy": bool(device.get("legacy")),
                "current": device["id"] == current_id}

    def list(self, current_id=None):
        with self._lock:
            self._prune()
            devices = sorted(self._active(), key=lambda device: (device.get("lastSeenAt") or "", device.get("createdAt") or ""),
                             reverse=True)
            return [self.public(device, current_id) for device in devices]

    def get(self, device_id, current_id=None):
        with self._lock:
            device = self._find(device_id)
            return self.public(device, current_id)

    def _find(self, device_id, include_revoked=False):
        for device in self._devices:
            if device["id"] == device_id and (include_revoked or not device.get("revokedAt")):
                return device
        raise KeyError(device_id)

    def count(self):
        with self._lock:
            return len(self._active())

    # MARK: changes

    def migrate_legacy(self, master_token):
        """Run at every start: the master token becomes (or stays) the "Legacy device".

        A rotated master token (`.orbit-token` deleted and regenerated) retires the old
        legacy device and becomes the new one, like rotating the shared token did before.
        Once the owner removed the legacy device, the master token grants nothing again.
        """
        if not master_token:
            return None
        digest = token_hash(master_token)
        with self._lock:
            legacy = [device for device in self._active() if device.get("legacy")]
            current = next((device for device in legacy if hmac.compare_digest(device["tokenHash"], digest)), None)
            if current is not None:
                return current["id"]
            if any(hmac.compare_digest(device["tokenHash"], digest) for device in self._devices):
                return None  # This exact token was revoked: keep it revoked.
            if self._legacy_migrated and not legacy:
                return None  # The owner removed the legacy device.
        with self._changing():
            now = iso(self.clock())
            for device in self._active():
                if device.get("legacy"):
                    device["revokedAt"], device["revokedReason"] = now, "Master token was regenerated"
            device = self._new_device(LEGACY_NAME, None, None, list(SCOPES), digest, legacy=True)
            self._legacy_migrated = True
        return device["id"]

    def _new_device(self, name, platform, model, scopes, digest, legacy=False):
        device = {"id": secrets.token_hex(16), "name": name, "platform": platform, "model": model,
                  "tokenHash": digest, "scopes": scopes, "createdAt": iso(self.clock()), "lastSeenAt": None,
                  "lastAddress": None, "legacy": legacy, "revokedAt": None, "revokedReason": None}
        self._devices.append(device)
        return device

    def register(self, name, platform=None, model=None, scopes=None, replace_unused_named=None):
        """A new device and its token (returned once, never stored)."""
        platform = normalize_platform(platform, name)
        scopes = normalize_scopes(scopes) if scopes is not None else default_scopes(platform)
        with self._changing():
            self._prune()
            if replace_unused_named:
                # Minting a new manual token retires the previous one nobody used.
                self._devices = [device for device in self._devices
                                 if not (device.get("name") == replace_unused_named and not device.get("lastSeenAt")
                                         and not device.get("revokedAt"))]
            if len(self._active()) >= MAX_DEVICES:
                raise AccessError(409, "too_many_devices",
                                  f"This PC already has {MAX_DEVICES} paired devices. Remove one in Orbit on the PC.")
            token = secrets.token_urlsafe(32)
            device = self._new_device(display_name(name, platform), platform, clean_text(model, 60) or None,
                                      scopes, token_hash(token))
        return self.public(device), token

    def authenticate(self, token, address=None):
        if not isinstance(token, str) or not token:
            raise invalid_token()
        digest = token_hash(token)
        with self._lock:
            match = None
            for device in self._devices:
                if hmac.compare_digest(device["tokenHash"], digest):
                    match = device
            if match is None:
                raise invalid_token()
            if match.get("revokedAt"):
                raise device_revoked()
            self._seen(match, address)
            return Principal(match["id"], match.get("name") or "Device", frozenset(match.get("scopes") or ()),
                             legacy=bool(match.get("legacy")), platform=match.get("platform"))

    def _seen(self, device, address):
        now = self.clock()
        previous = parse_iso(device.get("lastSeenAt"))
        address = clean_text(address, 64) or None
        moved = bool(address and address != device.get("lastAddress"))
        if previous is None or moved or now - previous >= SEEN_RESOLUTION_SECONDS:
            device["lastSeenAt"] = iso(now)
            if address:
                device["lastAddress"] = address
            self._dirty = True
            # First use and address changes are written within a second; routine
            # "still here" updates at most once a minute (by the background flusher).
            self._urgent = self._urgent or previous is None or moved

    def update(self, device_id, name=None, scopes=None, current_id=None):
        # Validate everything first: a rejected change leaves the device untouched.
        cleaned = clean_text(name, 60) if name is not None else None
        if name is not None and not cleaned:
            raise ValueError("Enter a name for this device.")
        scopes = normalize_scopes(scopes) if scopes is not None else None
        with self._changing():
            device = self._find(device_id)
            if cleaned is not None:
                device["name"] = cleaned
            if scopes is not None:
                device["scopes"] = scopes
        return self.public(device, current_id)

    def revoke(self, device_id, reason="Removed by the owner"):
        with self._changing():
            device = self._find(device_id)
            device["revokedAt"] = iso(self.clock())
            device["revokedReason"] = clean_text(reason, 120)
        return self.public(device)

    def revoked_count(self):
        with self._lock:
            return sum(1 for device in self._devices if device.get("revokedAt"))
