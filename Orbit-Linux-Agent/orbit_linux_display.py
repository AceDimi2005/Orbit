"""Hyprland virtual displays and recoverable Sunshine configuration changes.

Only outputs whose random name and compositor session are in our private journal
are removed. Physical monitors are never disabled or reconfigured: the optional
Sunshine hook temporarily changes DPMS and records every monitor before doing so.
"""
from contextlib import contextmanager
import copy
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import threading
import time
import uuid

from fastapi import HTTPException
import orbit_settings
from orbit_stream_display import DisplaySetupError, sunshine_activity, utc_now_iso

SECTION = "linuxDisplay"
NAME = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")
OWNED = re.compile(r"ORBIT-[0-9a-f]{16}\Z")
SDR_REASON = "Sunshine's wlr capture backend supplies SDR video. HDR streaming needs a different capture backend."


def mode(width, height, refresh):
    if any(isinstance(value, bool) or not isinstance(value, int) for value in (width, height, refresh)):
        raise DisplaySetupError(422, "Display dimensions and refresh rate must be whole numbers.")
    if not (640 <= width <= 7680 and 480 <= height <= 4320 and 24 <= refresh <= 500):
        raise DisplaySetupError(422, "Display mode is outside the supported range.")
    return {"width": width, "height": height, "refreshRate": refresh}


class HyprlandDisplays:
    def __init__(self, commands, environment=None):
        self.commands = commands
        self.environment = os.environ if environment is None else environment
        self.command = self.environment.get("ORBIT_HYPRCTL", "hyprctl")
        self._lua = None

    @property
    def session(self):
        return self.environment.get("HYPRLAND_INSTANCE_SIGNATURE")

    @property
    def supported(self):
        return bool(self.session and self.commands.has(self.command))

    def require(self):
        if not self.supported:
            raise DisplaySetupError(501, "Virtual display management currently requires a Hyprland session with hyprctl.")

    def run(self, *args):
        self.require()
        try:
            reply = self.commands.run(self.command, *args).decode().strip()
        except HTTPException as error:
            raise DisplaySetupError(error.status_code, str(error.detail)) from error
        if reply != "ok":
            raise DisplaySetupError(503, "Hyprland refused the display change. Check the compositor version and output availability.")

    def monitors(self):
        self.require()
        try:
            rows = self.commands.json(self.command, "-j", "monitors", "all")
        except HTTPException as error:
            raise DisplaySetupError(error.status_code, str(error.detail)) from error
        if not isinstance(rows, list) or any(not isinstance(row, dict) or not NAME.fullmatch(str(row.get("name", ""))) for row in rows):
            raise DisplaySetupError(503, "Hyprland returned an invalid monitor list.")
        return rows

    def find(self, name):
        return next((row for row in self.monitors() if row["name"] == name), None)

    def create(self, name):
        if not OWNED.fullmatch(name):
            raise DisplaySetupError(409, "Invalid Orbit output identity.")
        if self.find(name) is not None:
            raise DisplaySetupError(409, "A display already uses Orbit's new output name.")
        self.run("output", "create", "headless", name)
        self.wait(name, lambda row: row is not None)

    def destroy(self, name):
        if not OWNED.fullmatch(name):
            raise DisplaySetupError(409, "Refusing to remove a display not created by Orbit.")
        if self.find(name) is not None:
            self.run("output", "remove", name)
            self.wait(name, lambda row: row is None)

    def wait(self, name, predicate):
        deadline = time.monotonic() + 3
        while True:
            row = self.find(name)
            if predicate(row):
                return row
            if time.monotonic() >= deadline:
                raise DisplaySetupError(503, "Hyprland did not apply the requested display state.")
            time.sleep(.05)

    @staticmethod
    def placement(monitors, name, width, position):
        physical = [row for row in monitors if row["name"] != name and not row.get("disabled", False)]
        if not physical:
            return 0, 0
        edges = []
        for row in physical:
            scale = float(row.get("scale", 1))
            if not math.isfinite(scale) or scale <= 0:
                raise DisplaySetupError(503, "Hyprland returned an invalid output scale.")
            # wl_output transforms 1/3/5/7 swap the physical axes.
            pixels = row["height"] if int(row.get("transform", 0)) % 2 else row["width"]
            edges.append((int(row["x"]), int(row["x"]) + math.ceil(pixels / scale), int(row["y"])))
        return (min(edge[0] for edge in edges) - width if position == "left" else max(edge[1] for edge in edges),
                min(edge[2] for edge in edges))

    def uses_lua(self):
        if self._lua is None:
            try:
                version = self.commands.json(self.command, "-j", "version").get("version", "")
            except HTTPException as error:
                raise DisplaySetupError(error.status_code, str(error.detail)) from error
            parsed = re.match(r"v?(\d+)\.(\d+)", version)
            if not parsed:
                raise DisplaySetupError(503, "Could not determine the Hyprland configuration API version.")
            self._lua = False
            if tuple(map(int, parsed.groups())) >= (0, 55):
                # Transitional releases accept both config formats. Probe the
                # active provider without changing configuration before choosing
                # a mutation API; never retry a failed mutation in another syntax.
                try:
                    reply = self.commands.run(self.command, "eval", "local orbit_api_probe = true").decode().strip()
                except HTTPException as error:
                    self._lua = None
                    raise DisplaySetupError(error.status_code, str(error.detail)) from error
                if reply == "ok":
                    self._lua = True
                elif reply != "eval is only supported with the lua config manager":
                    self._lua = None
                    raise DisplaySetupError(503, "Could not determine the active Hyprland configuration API.")
        return self._lua

    def configure(self, name, requested, position="right"):
        if not OWNED.fullmatch(name) or position not in {"left", "right"}:
            raise DisplaySetupError(422, "Invalid virtual display configuration.")
        requested = mode(requested["width"], requested["height"], requested["refreshRate"])
        resolution = f"{requested['width']}x{requested['height']}@{requested['refreshRate']}"
        for attempt in range(3):
            # Hotplug/layout handlers may resize neighbouring outputs or reload
            # the config after creation. Recompute placement and reapply only our
            # own output if an accepted command is subsequently overwritten.
            x, y = self.placement(self.monitors(), name, requested["width"], position)
            if self.uses_lua():
                self.run("eval", f'hl.monitor({{output={json.dumps(name)},mode="{resolution}",position="{x}x{y}",scale=1}})')
            else:
                self.run("keyword", "monitor", f"{name},{resolution},{x}x{y},1")
            try:
                return self.wait(name, lambda row: bool(row and not row.get("disabled") and row["width"] == requested["width"]
                                                       and row["height"] == requested["height"] and abs(row["refreshRate"] - requested["refreshRate"]) < 1
                                                       and row["x"] == x and row["y"] == y))
            except DisplaySetupError:
                if attempt == 2:
                    raise

    def power(self, name, enabled):
        if not NAME.fullmatch(name):
            raise DisplaySetupError(422, "Invalid output name.")
        action = "on" if enabled else "off"
        if self.uses_lua():
            self.run("dispatch", f'hl.dsp.dpms({{monitor={json.dumps(name)},action="{action}"}})')
        else:
            self.run("dispatch", "dpms", f"{action} {name}")
        self.wait(name, lambda row: row is None or row.get("dpmsStatus") is enabled)

    def focus(self, name):
        if not NAME.fullmatch(name):
            raise DisplaySetupError(422, "Invalid output name.")
        if self.uses_lua():
            self.run("dispatch", f'hl.dsp.focus({{monitor={json.dumps(name)}}})')
        else:
            self.run("dispatch", "focusmonitor", name)


class LinuxStreamDisplayService:
    def __init__(self, sunshine, platform, store_provider=None, activity=None, hook_launcher=None):
        self.sunshine, self.platform = sunshine, platform
        # Hooks are separate processes. Keep the recovery journal in its own file
        # so unrelated agent settings writes cannot race its read/modify/write.
        self._store_provider = store_provider or (lambda: orbit_settings.SettingsStore(
            orbit_settings.default_settings_path().with_name("linux-display.json")))
        self.activity = activity or (lambda: sunshine_activity(47989, server_info=sunshine.server_info))
        self._operation = threading.Lock()
        self.hook_launcher = hook_launcher or self._launcher()

    @staticmethod
    def _launcher():
        return ([os.environ["ORBIT_LAUNCHER"]] if os.environ.get("ORBIT_LAUNCHER") else
                [os.path.abspath(sys.executable), str(Path(__file__).with_name("orbit_linux.py"))])

    def state(self):
        state = self._store_provider().get(SECTION, {})
        if not isinstance(state, dict):
            raise DisplaySetupError(503, "Orbit's display recovery journal is invalid.")
        return state

    def save(self, state):
        try:
            self._store_provider().replace(SECTION, state)
        except (OSError, ValueError) as error:
            raise DisplaySetupError(503, "Could not save the Linux display recovery journal.") from error

    @contextmanager
    def operation(self):
        if not self._operation.acquire(blocking=False):
            raise DisplaySetupError(409, "Another display operation is in progress.")
        fd = None
        try:
            path = self._store_provider().path.with_name("linux-display.lock")
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise DisplaySetupError(409, "Another display operation is in progress.") from error
            yield
        except OSError as error:
            raise DisplaySetupError(503, "Could not access the Linux display recovery journal.") from error
        finally:
            if fd is not None:
                os.close(fd)
            self._operation.release()

    def idle(self):
        if self.activity().busy is not False:
            raise DisplaySetupError(409, "Quit the Sunshine app and end its streams before changing display settings.")

    def owned(self, state):
        if not OWNED.fullmatch(str(state.get("output", ""))) or state.get("session") != self.platform.session:
            raise DisplaySetupError(409, "This display belongs to a different compositor session. Restore Orbit's settings first.")

    def hook(self):
        env = self.platform.environment
        # Sunshine's user service may have a different desktop environment. All
        # values here come from the local launcher, never from an HTTP request.
        variables = {key: env[key] for key in ("XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "XDG_DATA_HOME") if env.get(key)}
        variables["ORBIT_HYPRCTL"] = shutil.which(self.platform.command) or self.platform.command
        prefix = ["env", *(f"{key}={value}" for key, value in variables.items()), *self.hook_launcher, "--display-hook"]
        return {"do": shlex.join([*prefix, "start"]), "undo": shlex.join([*prefix, "stop"]), "elevated": False}

    @staticmethod
    def prep(config):
        value = config.get("global_prep_cmd", "[]")
        try:
            entries = json.loads(value) if isinstance(value, str) else value
        except ValueError as error:
            raise DisplaySetupError(409, "Sunshine's global preparation commands are not valid JSON.") from error
        if not isinstance(entries, list) or any(not isinstance(item, dict) for item in entries):
            raise DisplaySetupError(409, "Sunshine's global preparation commands are not a command list.")
        return entries

    def restart(self):
        self.idle()
        self.sunshine.restart()
        deadline = time.monotonic() + 10
        while True:
            try:
                self.sunshine.config()
                return
            except DisplaySetupError:
                if time.monotonic() >= deadline:
                    raise DisplaySetupError(503, "Sunshine did not return after restarting. Restore displays from the Orbit tray.")
                time.sleep(.2)

    def _ensure(self, requested, position):
        self.platform.require()
        previous = self.state()
        state = copy.deepcopy(previous)
        if state:
            self.owned(state)
            if state.get("phase") not in {"ready", "prepared"}:
                raise DisplaySetupError(409, "Restore the interrupted display operation from the Orbit tray first.")
        else:
            state = {"output": "ORBIT-" + uuid.uuid4().hex[:16], "session": self.platform.session,
                     "fill": {"enabled": False, "onlyDisplay": False}, "secondScreen": {"active": False}, "darkened": []}
        state.update(mode=requested, position=position, phase="preparing")
        self.save(state)  # Journal before creating or resizing anything.
        try:
            if not previous:
                self.platform.create(state["output"])
            elif self.platform.find(state["output"]) is None:
                raise DisplaySetupError(409, "Orbit's virtual output was removed. Restore and set it up again.")
            self.platform.configure(state["output"], requested, position)
            state["phase"] = "ready" if state.get("originalSunshine") is not None else "prepared"
            self.save(state)
            return state
        except Exception as error:
            try:
                if previous:
                    self.platform.configure(previous["output"], previous["mode"], previous["position"])
                elif not isinstance(error, DisplaySetupError) or error.status != 409:
                    self.platform.destroy(state["output"])
                self.save(previous)
            except Exception:
                pass  # Keep the preparing journal so explicit recovery can retry.
            raise

    def ensure_mode(self, width, height, refresh):
        requested = mode(width, height, refresh)
        self.platform.require()
        with self.operation():
            self.idle()
            state = self._ensure(requested, self.state().get("position", "right"))
            return {"changed": True, "modes": [self._mode_string(state)], "reload": "applied", "elevated": False}

    def _target(self, state):
        current, _ = self.sunshine.config()
        entries = self.prep(current)
        state.setdefault("originalSunshine", {key: current.get(key) for key in ("output_name", "capture")})
        state.setdefault("savedAt", utc_now_iso())
        state.setdefault("hook", self.hook())
        target = {**current, "capture": "wlr", "output_name": state["output"]}
        if state["hook"] not in entries:
            entries.append(state["hook"])
        target["global_prep_cmd"] = json.dumps(entries, separators=(",", ":"))
        state["appliedSunshine"] = {"capture": "wlr", "output_name": state["output"]}
        state["phase"] = "configuring"
        self.save(state)
        try:
            self.idle()
            self.sunshine.save_config(target)
            self.restart()
            state["phase"] = "ready"
            self.save(state)
        except Exception:
            # A failed/timed-out write may have reached Sunshine. Use the same
            # recovery journal as a crash, rather than guessing it did nothing.
            try:
                self._recover(state)
            except Exception:
                pass  # Preserve the journal when recovery is unsafe/unavailable.
            raise
        return {"changed": target != current, "restarted": True, "sunshineReady": True}

    def set_fill(self, enabled, only_display=False):
        if enabled:
            self.platform.require()
        with self.operation():
            self.idle()
            state = self.state()
            if not enabled:
                if state.get("secondScreen", {}).get("active"):
                    state["fill"] = {"enabled": False, "onlyDisplay": False}
                    self.save(state)
                    return {"changed": True}
                return self._recover(state)
            state = self._ensure(state.get("mode", mode(1920, 1080, 60)), state.get("position", "right"))
            state["fill"] = {"enabled": True, "onlyDisplay": bool(only_display)}
            return self._target(state)

    def set_second_screen(self, enabled, width=None, height=None, refresh=60, position="right"):
        if position not in {"left", "right"}:
            raise DisplaySetupError(422, "Position must be left or right.")
        if enabled:
            self.platform.require()
        with self.operation():
            self.idle()
            state = self.state()
            if not enabled:
                if state.get("fill", {}).get("enabled"):
                    state["secondScreen"] = {"active": False}
                    self.save(state)
                    return {"changed": True, "placement": None}
                return self._recover(state)
            state = self._ensure(mode(width, height, refresh), position)
            state["secondScreen"] = {"active": True, "position": position, **state["mode"]}
            return {**self._target(state), "placement": "done", "placementHint": None, "reload": "applied", "elevated": False}

    def _wake(self, state):
        if not state or not (state.get("darkened") or state.get("previousFocus")) or state.get("session") != self.platform.session:
            return
        monitors = self.platform.monitors()
        available = {row["name"] for row in monitors}
        for name in list(state.get("darkened", [])):
            if name in available:
                self.platform.power(name, True)
            state["darkened"].remove(name)
            self.save(state)
        previous = state.get("previousFocus")
        if previous in available and any(row["name"] == state.get("output") and row.get("focused") for row in monitors):
            self.platform.focus(previous)
        if state.pop("previousFocus", None) is not None:
            self.save(state)

    def _recover(self, state):
        if not state:
            return {"changed": False}
        self._wake(state)
        self.idle()
        if state.get("originalSunshine") is not None:
            current, _ = self.sunshine.config()
            target = dict(current)
            # Restore only values still owned by Orbit; retain unrelated settings
            # and edits made in Sunshine after Orbit set this output up.
            for key, applied in state.get("appliedSunshine", {}).items():
                if current.get(key) == applied:
                    original = state["originalSunshine"].get(key)
                    if original is None:
                        target.pop(key, None)
                    else:
                        target[key] = original
            entries = self.prep(current)
            remaining = [entry for entry in entries if entry != state.get("hook")]
            if entries != remaining:
                target["global_prep_cmd"] = json.dumps(remaining, separators=(",", ":"))
            if target != current:
                self.sunshine.save_config(target)
                self.restart()
        if state.get("session") == self.platform.session:
            self.owned(state)
            self.platform.destroy(state["output"])
        self.save({})
        return {"changed": True, "restarted": state.get("originalSunshine") is not None, "sunshineReady": True}

    def revert(self):
        with self.operation():
            # The tray's emergency restore must always wake monitors, even while
            # a Sunshine app prevents changing capture settings.
            self._wake(self.state())
            self.idle()
            return self._recover(self.state())

    def stream_hook(self, start, environment=None):
        env = os.environ if environment is None else environment
        with self.operation():
            state = self.state()
            if not state:
                return
            self.owned(state)
            if not start:
                self._wake(state)
                return
            if state.get("phase") != "ready":
                raise DisplaySetupError(409, "Orbit's virtual display is not ready.")
            if env.get("SUNSHINE_CLIENT_HDR", "false").lower() in {"true", "1"}:
                raise DisplaySetupError(409, SDR_REASON + " Turn HDR off in the streaming settings.")
            try:
                requested = mode(int(env.get("SUNSHINE_CLIENT_WIDTH", state["mode"]["width"])),
                                 int(env.get("SUNSHINE_CLIENT_HEIGHT", state["mode"]["height"])),
                                 int(env.get("SUNSHINE_CLIENT_FPS", state["mode"]["refreshRate"])))
            except (ValueError, TypeError) as error:
                raise DisplaySetupError(422, "Sunshine supplied an invalid client display mode.") from error
            self.platform.configure(state["output"], requested, state["position"])
            state["mode"] = requested
            if state.get("secondScreen", {}).get("active"):
                state["secondScreen"].update(requested)
            self.save(state)
            if state.get("fill", {}).get("enabled") and not state.get("secondScreen", {}).get("active"):
                focused = next((row["name"] for row in self.platform.monitors() if row.get("focused") and row["name"] != state["output"]), None)
                if focused:
                    state.setdefault("previousFocus", focused)
                    self.save(state)
                    self.platform.focus(state["output"])
            if state.get("fill", {}).get("onlyDisplay") and not state.get("secondScreen", {}).get("active"):
                try:
                    for row in self.platform.monitors():
                        if row["name"] != state["output"] and not row.get("disabled") and row.get("dpmsStatus"):
                            state.setdefault("darkened", []).append(row["name"])
                            self.save(state)  # Record before switching off a monitor.
                            self.platform.power(row["name"], False)
                except Exception:
                    self._wake(state)
                    raise

    @staticmethod
    def _mode_string(state):
        value = state["mode"]
        return f"{value['width']}x{value['height']}@{value['refreshRate']}"

    def status(self):
        state = self.state()
        supported = self.platform.supported
        login = self.sunshine.login_saved()
        config, version, reason = {}, None, None
        if login:
            try:
                config, version = self.sunshine.config()
            except DisplaySetupError as error:
                reason = error.detail
        else:
            reason = "Save the Sunshine login on the PC first."
        actual = None
        if supported and state.get("session") == self.platform.session and state.get("output"):
            try:
                actual = self.platform.find(state["output"])
            except DisplaySetupError as error:
                reason = reason or error.detail
        attached = bool(actual and not actual.get("disabled"))
        if not supported:
            reason = "Virtual display management currently requires Hyprland."
        elif state and state.get("phase") not in {"ready", "prepared"}:
            reason = "An interrupted display change needs restoration from the Orbit tray."
        elif state and not attached:
            reason = "The virtual output was removed or the compositor restarted. Restore Orbit's settings and set it up again."
        active = self.activity()
        value = ({"width": actual["width"], "height": actual["height"], "refreshRate": round(actual["refreshRate"])} if attached else {})
        if attached and value != state.get("mode"):
            reason = reason or "The compositor changed the virtual display's mode. Set it up again before streaming."
        if state.get("phase") == "ready" and (config.get("capture") != "wlr" or config.get("output_name") != state.get("output")):
            reason = reason or "Sunshine's capture settings changed. Set up the virtual display again before streaming."
        return {"backend": "hyprland", "sunshineVersion": version, "sunshineRunning": bool(version or active.pids),
                "loginSaved": login, "sunshineSupported": True if version else None, "streamActive": active.streaming, "appRunning": active.app_running,
                "virtualDisplay": {"installed": supported, "driver": "hyprland", "deviceStatus": "running" if supported else "notPresent",
                                   "deviceId": state.get("output"), "attached": attached, "modes": [self._mode_string({"mode": value})] if value else [],
                                   "resolutions": [f"{value['width']}x{value['height']}"] if value else [],
                                   "refreshRates": [value["refreshRate"]] if value else [], "settingsError": None},
                "config": {"output_name": config.get("output_name")}, "fill": state.get("fill", {"enabled": False, "onlyDisplay": False}),
                "fillReady": reason is None and attached and state.get("phase") == "ready",
                "secondScreen": {"active": False, **state.get("secondScreen", {}), "placement": "done" if attached else None},
                "savedConfig": {"available": bool(state), "savedAt": state.get("savedAt")}, "installCommand": "",
                "hdrSupported": False, "hdrReason": SDR_REASON, "reason": reason}

    def close(self):
        # Do not terminate an active Sunshine app on Orbit exit. Wake local screens
        # regardless; retain the journal for a later explicit/idle restoration.
        with self.operation():
            state = self.state()
            if state:
                self._wake(state)
                if self.activity().busy is False:
                    self._recover(state)
