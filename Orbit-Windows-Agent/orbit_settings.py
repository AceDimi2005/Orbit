"""The companion's settings, in %LOCALAPPDATA%\\Orbit\\settings.json.

Values are validated on the way in and on the way out: a hand-edited or damaged
file never breaks the agent, it only falls back to defaults for the bad keys.
"""
import copy
import json
import os
from pathlib import Path
import secrets
import threading

NOTIFICATION_KEYS = ("newDevice", "power", "files", "screenView", "inputSession", "quietWhileGaming")
DEFAULTS = {
    "notifications": {"newDevice": True, "power": True, "files": True, "screenView": True,
                      "inputSession": True, "quietWhileGaming": True},
}


class SettingsError(ValueError):
    pass


def _notifications(value, base):
    result = dict(base)
    if not isinstance(value, dict):
        return result
    for key in NOTIFICATION_KEYS:
        if isinstance(value.get(key), bool):
            result[key] = value[key]
    return result


class Settings:
    def __init__(self, path):
        self.path = Path(path)
        self._lock = threading.Lock()
        self._data = copy.deepcopy(DEFAULTS)
        self._load()

    def _load(self):
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if isinstance(raw, dict):
            self._data["notifications"] = _notifications(raw.get("notifications"), DEFAULTS["notifications"])
            for key, value in raw.items():
                if key not in self._data:
                    self._data[key] = value  # Keys owned by other parts of the agent.

    def _save_locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".orbit-tmp-{secrets.token_hex(6)}")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(self._data, output, indent=1, sort_keys=True)
            os.replace(temporary, self.path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def notifications(self):
        with self._lock:
            return dict(self._data["notifications"])

    def update_notifications(self, changes):
        if not isinstance(changes, dict) or not changes:
            raise SettingsError("Send at least one notification setting.")
        unknown = sorted(set(changes) - set(NOTIFICATION_KEYS))
        if unknown:
            raise SettingsError(f"Unknown notification setting: {', '.join(unknown)}.")
        if any(not isinstance(value, bool) for value in changes.values()):
            raise SettingsError("Notification settings are true or false.")
        with self._lock:
            self._data["notifications"].update(changes)
            self._save_locked()
            return dict(self._data["notifications"])

    def get(self, key, default=None):
        with self._lock:
            return copy.deepcopy(self._data.get(key, default))

    def set(self, key, value):
        with self._lock:
            self._data[key] = copy.deepcopy(value)
            self._save_locked()
