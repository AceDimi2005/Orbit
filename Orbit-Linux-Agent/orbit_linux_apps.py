"""XDG application catalog and key-based presentation control."""
import configparser
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path

from fastapi import HTTPException


@dataclass(frozen=True)
class DesktopApp:
    id: str
    name: str
    path: str


class LinuxApps:
    def __init__(self, environment=None):
        self.environment = os.environ if environment is None else environment

    def list(self):
        home = Path(self.environment.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
        roots = [home, *(Path(path) for path in self.environment.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"))]
        desktops = set(self.environment.get("XDG_CURRENT_DESKTOP", "").split(":"))
        found, seen = [], set()
        for root in roots:
            directory = root / "applications"
            for index, path in enumerate(sorted(directory.glob("**/*.desktop"))):
                if index >= 10000 or len(found) >= 2000:
                    break
                desktop_id = str(path.relative_to(directory)).replace("/", "-")
                if desktop_id in seen:
                    continue
                seen.add(desktop_id)
                try:
                    if path.stat().st_size > 256 * 1024:
                        continue
                    config = configparser.ConfigParser(interpolation=None, strict=False)
                    config.read(path, encoding="utf-8")
                    entry = config["Desktop Entry"]
                    if entry.get("Type") != "Application" or entry.getboolean("Hidden", False) or entry.getboolean("NoDisplay", False):
                        continue
                    only = set(filter(None, entry.get("OnlyShowIn", "").split(";")))
                    excluded = set(filter(None, entry.get("NotShowIn", "").split(";")))
                    if (only and not desktops.intersection(only)) or desktops.intersection(excluded):
                        continue
                    name = entry.get("Name", "").strip()
                    if name and (entry.get("Exec") or entry.getboolean("DBusActivatable", False)):
                        found.append(DesktopApp(hashlib.sha1(desktop_id.encode()).hexdigest(), name[:120], str(path)))
                except (OSError, ValueError, KeyError, configparser.Error):
                    continue
        return sorted(found, key=lambda app: app.name.casefold())

    def find(self, identity):
        return next((app for app in self.list() if app.id == identity), None)

    def payload(self):
        return {"apps": [{"id": app.id, "name": app.name, "iconID": None, "folder": None} for app in self.list()]}


class LinuxPresentation:
    def __init__(self, desktop):
        self.desktop = desktop

    def state(self):
        from orbit_presentation import empty_state
        return empty_state()

    def thumbnail(self, slide=None, width=640):
        raise HTTPException(501, "Slide metadata and thumbnails require PowerPoint COM on Windows. Linux supports presentation keys.")

    def perform(self, action, slide=None, via="auto", boot_mode=False):
        import orbit_presentation
        if via == "powerpoint":
            raise HTTPException(501, "PowerPoint COM is unavailable on Linux. Select keyboard control.")
        chords = orbit_presentation._key_chords(action, slide)
        with self.desktop.input_lock:
            for chord in chords:
                self.desktop.hotkey(chord)
        return {"status": "done", "action": action, "via": "keys", "keys": ["+".join(chord) for chord in chords],
                "detail": "Sent presentation keys to the focused Linux application.", "presentation": self.state()}
