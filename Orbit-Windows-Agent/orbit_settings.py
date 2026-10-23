"""Settings the agent keeps for its features: one small JSON file per PC.

`%LOCALAPPDATA%\\Orbit\\settings.json` holds one top-level object with a section per feature
(`alerts`, `energy`, `deck`, `display`, `webcam`, `presentation`, `push`). The folder is already
hidden from the Files API. Only non-secret values belong here; secrets (the push channel secret,
per-device push keys) go in their own file, `default_secrets_path()`, through a second store.

Every change is written to a new temporary file in the same folder, flushed to disk and moved
over the old file with `os.replace`, so a crash or power cut leaves either the old or the new
settings and never a half-written file. Temporary files are created private (0600), and the
replacement keeps that mode, so the secrets file is private too.

Stores that point at the same file share one lock and one cache inside the process, so two
features updating different sections at the same moment cannot lose each other's change. A
change made by another process (the boot-time instance during hand-over) is noticed through the
file's size, modification time and identity and read again before the next change.
"""
import copy
import json
import logging
import os
from pathlib import Path
import re
import tempfile
import threading
import time

LOGGER = logging.getLogger("orbit.settings")
SETTINGS_FILE_NAME = "settings.json"
SECRETS_FILE_NAME = "push-secrets.json"
MAX_SETTINGS_BYTES = 4 * 1024 * 1024
_SECTION = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
# Windows briefly refuses to open or replace a file that antivirus or a reader holds open.
_RETRY_ATTEMPTS = 8
_RETRY_DELAY = 0.025


def default_settings_path():
    from orbit_tls import data_directory
    return data_directory() / SETTINGS_FILE_NAME


def default_secrets_path():
    from orbit_tls import data_directory
    return data_directory() / SECRETS_FILE_NAME


class _FileState:
    """The lock and the last loaded contents for one settings file, shared by its stores."""

    def __init__(self):
        self.lock = threading.RLock()
        self.data = None
        self.signature = None


_STATES = {}
_STATES_GUARD = threading.Lock()


def _state_for(path):
    key = os.path.normcase(os.path.abspath(str(path)))
    with _STATES_GUARD:
        state = _STATES.get(key)
        if state is None:
            state = _STATES[key] = _FileState()
        return state


def _check_section(section):
    if not isinstance(section, str) or not _SECTION.match(section):
        raise ValueError(f"Invalid settings section name: {section!r}")
    return section


def _with_retries(operation):
    for attempt in range(_RETRY_ATTEMPTS):
        try:
            return operation()
        except PermissionError:
            if attempt == _RETRY_ATTEMPTS - 1:
                raise
            time.sleep(_RETRY_DELAY)


class SettingsStore:
    """Thread-safe sections of one JSON object, saved atomically on every change."""

    def __init__(self, path=None):
        self.path = Path(path) if path is not None else default_settings_path()
        self._state = _state_for(self.path)

    # Reading -----------------------------------------------------------------------------

    def _signature(self):
        try:
            info = os.stat(self.path)
        except FileNotFoundError:
            return None
        return info.st_mtime_ns, info.st_size, getattr(info, "st_ino", 0)

    def _quarantine_locked(self):
        """Keeps an unreadable file for inspection instead of silently overwriting it."""
        damaged = self.path.with_name(self.path.name + ".corrupt")
        try:
            os.replace(self.path, damaged)
            LOGGER.warning("Orbit settings were unreadable and were moved to %s; starting with defaults", damaged)
        except OSError:
            LOGGER.warning("Orbit settings were unreadable; starting with defaults")

    def _load_locked(self):
        state = self._state
        signature = self._signature()
        if state.data is not None and signature == state.signature:
            return state.data
        if signature is None:
            state.data, state.signature = {}, None
            return state.data
        if signature[1] > MAX_SETTINGS_BYTES:
            data = None
        else:
            try:
                raw = _with_retries(self.path.read_bytes)
            except FileNotFoundError:
                # Removed between stat and read: nothing saved any more.
                state.data, state.signature = {}, None
                return state.data
            try:
                data = json.loads(raw.decode("utf-8-sig"))
            except (UnicodeDecodeError, ValueError):
                data = None
        if not isinstance(data, dict):
            self._quarantine_locked()
            state.data, state.signature = {}, self._signature()
            return state.data
        state.data, state.signature = data, signature
        return data

    def _current_locked(self):
        """The loaded settings; on a read error, the last good copy (or nothing) so reads never fail."""
        try:
            return self._load_locked()
        except OSError:
            LOGGER.warning("Could not read Orbit settings from %s", self.path, exc_info=True)
            return self._state.data or {}

    def get(self, section, default=None):
        """A private copy of one section, or `default` when it was never saved."""
        _check_section(section)
        with self._state.lock:
            data = self._current_locked()
            if section in data:
                return copy.deepcopy(data[section])
        return copy.deepcopy(default)

    def snapshot(self):
        """A private copy of every section."""
        with self._state.lock:
            return copy.deepcopy(self._current_locked())

    # Writing -----------------------------------------------------------------------------

    def _write_locked(self, data):
        encoded = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False).encode("utf-8")
        if len(encoded) > MAX_SETTINGS_BYTES:
            raise ValueError("These settings are too large to save.")
        directory = self.path.parent
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", suffix=".tmp", dir=directory)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            _with_retries(lambda: os.replace(temporary, self.path))
            temporary = None
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
        if os.name != "nt":
            # Make the rename itself durable (Windows has no directory handles to flush).
            try:
                folder = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(folder)
                finally:
                    os.close(folder)
            except OSError:
                pass
        # Cache exactly what is on disk (tuples became lists, keys became strings).
        self._state.data = json.loads(encoded.decode("utf-8"))
        self._state.signature = self._signature()

    def _change(self, section, compute):
        _check_section(section)
        with self._state.lock:
            data = copy.deepcopy(self._load_locked())
            value = compute(data.get(section), section in data)
            data[section] = value
            self._write_locked(data)
            return copy.deepcopy(self._state.data[section])

    def update(self, section, values):
        """Merges `values` into a dict section (creating it) and saves; returns the new section."""
        if not isinstance(values, dict):
            raise TypeError("Settings updates must be a dict")

        def merge(current, exists):
            merged = dict(current) if exists and isinstance(current, dict) else {}
            merged.update(values)
            return merged
        return self._change(section, merge)

    def replace(self, section, value):
        """Replaces a whole section with any JSON value and saves; returns the saved value."""
        return self._change(section, lambda current, exists: value)

    def modify(self, section, function, default=None):
        """Read-modify-write under the store lock: `function(copy_of_section_or_default)` returns
        the new value, which is saved and returned. Nothing else can change the file in between."""
        def compute(current, exists):
            return function(copy.deepcopy(current) if exists else copy.deepcopy(default))
        return self._change(section, compute)

    def remove(self, section):
        """Deletes a section; returns True when it existed."""
        _check_section(section)
        with self._state.lock:
            data = copy.deepcopy(self._load_locked())
            if section not in data:
                return False
            del data[section]
            self._write_locked(data)
            return True


_SHARED = None
_SHARED_GUARD = threading.Lock()


def shared_store():
    """The process-wide store for `settings.json` (created on first use, never touches disk until a change)."""
    global _SHARED
    with _SHARED_GUARD:
        if _SHARED is None:
            _SHARED = SettingsStore()
        return _SHARED


def set_shared_store(store):
    """Points `shared_store()` at another store (tests); None goes back to the default file."""
    global _SHARED
    with _SHARED_GUARD:
        _SHARED = store
