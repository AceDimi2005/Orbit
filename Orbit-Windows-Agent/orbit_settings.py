"""The companion's settings, in %LOCALAPPDATA%\\Orbit\\settings.json.

Values are validated on the way in and on the way out: a hand-edited or damaged
file never breaks the agent, it only falls back to defaults for the bad keys.

Monitoring options used to be environment variables only. They are settings now
(the companion window and PATCH /api/settings change them); an environment variable
the owner set in Windows still wins, and the window says which ones it is.
"""
import copy
import json
import os
from pathlib import Path
import re
import secrets
import threading
from urllib.parse import urlparse

NOTIFICATION_KEYS = ("newDevice", "power", "files", "screenView", "inputSession", "quietWhileGaming")
# Setting → the environment variable the monitoring code reads.
MONITORING_ENVIRONMENT = {
    "gameProcesses": "ORBIT_GAME_PROCESSES",
    "networkInterface": "ORBIT_NETWORK_INTERFACE",
    "presentMonCSV": "ORBIT_PRESENTMON_CSV",
    "libreHardwareMonitorURL": "ORBIT_LHM_URL",
}
DEFAULTS = {
    "notifications": {"newDevice": True, "power": True, "files": True, "screenView": True,
                      "inputSession": True, "quietWhileGaming": True},
    "monitoring": {"gameProcesses": [], "networkInterface": None, "presentMonCSV": None, "libreHardwareMonitorURL": None},
    "updates": {"checkAutomatically": True},
}
EXECUTABLE = re.compile(r'^[^\\/:*?"<>|;]{1,100}\.exe$', re.IGNORECASE)


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


def clean_monitoring_value(key, value):
    """The validated form of one monitoring setting; SettingsError when it cannot be used."""
    if key == "gameProcesses":
        if value is None:
            return []
        if isinstance(value, str):
            value = [part for part in value.split(";")]
        if not isinstance(value, list) or len(value) > 32:
            raise SettingsError("List at most 32 game executables, such as game.exe.")
        names = []
        for item in value:
            name = str(item).strip()
            if not name:
                continue
            if not EXECUTABLE.fullmatch(name):
                raise SettingsError(f"“{name}” is not an executable name such as game.exe.")
            if name.casefold() not in (known.casefold() for known in names):
                names.append(name)
        return names
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if not isinstance(value, str):
        raise SettingsError("This setting is text.")
    value = value.strip()
    if key == "networkInterface":
        if len(value) > 100 or any(ord(character) < 32 for character in value):
            raise SettingsError("Use the adapter's name as Windows shows it, such as Ethernet.")
        return value
    if key == "presentMonCSV":
        if len(value) > 1024 or "\0" in value or not value.casefold().endswith(".csv") or not (
                os.path.isabs(value) or re.match(r"^[a-zA-Z]:[\\/]", value)):
            raise SettingsError("Use the full path of PresentMon's CSV file, such as C:\\Orbit\\presentmon.csv.")
        return value
    if key == "libreHardwareMonitorURL":
        parsed = urlparse(value)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1") or len(value) > 200:
            raise SettingsError("LibreHardwareMonitor must be on this PC: http://127.0.0.1:8085/data.json.")
        return value
    raise SettingsError(f"Unknown monitoring setting: {key}.")


def environment_value(key, value):
    if key == "gameProcesses":
        return ";".join(value) if value else None
    return value


class Settings:
    def __init__(self, path, environ=None):
        self.path = Path(path)
        self.environ = os.environ if environ is None else environ
        # Variables the owner set in Windows before Orbit started win over settings.json.
        self.external = {key for key, variable in MONITORING_ENVIRONMENT.items() if self.environ.get(variable)}
        self._lock = threading.Lock()
        self._data = copy.deepcopy(DEFAULTS)
        self._load()

    def _load(self):
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(raw, dict):
            return
        self._data["notifications"] = _notifications(raw.get("notifications"), DEFAULTS["notifications"])
        monitoring = raw.get("monitoring") if isinstance(raw.get("monitoring"), dict) else {}
        for key in MONITORING_ENVIRONMENT:
            try:
                self._data["monitoring"][key] = clean_monitoring_value(key, monitoring.get(key))
            except SettingsError:
                pass
        updates = raw.get("updates") if isinstance(raw.get("updates"), dict) else {}
        if isinstance(updates.get("checkAutomatically"), bool):
            self._data["updates"]["checkAutomatically"] = updates["checkAutomatically"]
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

    # MARK: notifications

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

    # MARK: monitoring

    def monitoring(self):
        """Effective values (environment first) and which keys Windows' environment manages."""
        with self._lock:
            stored = copy.deepcopy(self._data["monitoring"])
        result = {}
        for key, variable in MONITORING_ENVIRONMENT.items():
            if key in self.external:
                raw = self.environ.get(variable, "")
                result[key] = [part for part in raw.split(";") if part.strip()] if key == "gameProcesses" else raw
            else:
                result[key] = stored[key]
        result["managedByEnvironment"] = sorted(self.external)
        return result

    def update_monitoring(self, changes):
        if not isinstance(changes, dict) or not changes:
            raise SettingsError("Send at least one monitoring setting.")
        unknown = sorted(set(changes) - set(MONITORING_ENVIRONMENT))
        if unknown:
            raise SettingsError(f"Unknown monitoring setting: {', '.join(unknown)}.")
        managed = sorted(set(changes) & self.external)
        if managed:
            variables = ", ".join(MONITORING_ENVIRONMENT[key] for key in managed)
            raise SettingsError(f"{variables} is set in Windows' environment variables. Remove it there to change this here.")
        cleaned = {key: clean_monitoring_value(key, value) for key, value in changes.items()}
        with self._lock:
            self._data["monitoring"].update(cleaned)
            self._save_locked()
        self.apply_environment()
        return self.monitoring()

    def apply_environment(self):
        """Hand the monitoring settings to the code that reads environment variables."""
        with self._lock:
            stored = copy.deepcopy(self._data["monitoring"])
        for key, variable in MONITORING_ENVIRONMENT.items():
            if key in self.external:
                continue
            value = environment_value(key, stored[key])
            if value:
                self.environ[variable] = value
            else:
                self.environ.pop(variable, None)

    # MARK: updates and other keys

    def updates(self):
        with self._lock:
            return dict(self._data["updates"])

    def update_updates(self, changes):
        if not isinstance(changes, dict) or set(changes) - {"checkAutomatically"} or not changes:
            raise SettingsError("The update setting is checkAutomatically.")
        if not isinstance(changes["checkAutomatically"], bool):
            raise SettingsError("checkAutomatically is true or false.")
        with self._lock:
            self._data["updates"].update(changes)
            self._save_locked()
            return dict(self._data["updates"])

    def get(self, key, default=None):
        with self._lock:
            return copy.deepcopy(self._data.get(key, default))

    def set(self, key, value):
        with self._lock:
            self._data[key] = copy.deepcopy(value)
            self._save_locked()
