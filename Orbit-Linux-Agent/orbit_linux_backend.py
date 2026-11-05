"""Linux desktop operations. No shell strings, root escalation, or XWayland fallback.

External helpers inherit the signed-in desktop's environment. Their availability
is reported separately from compositor permission: installed does not mean allowed.
"""
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import threading

import psutil
from fastapi import HTTPException

KEYSYMS = {
    "ctrl": "Control_L", "shift": "Shift_L", "alt": "Alt_L", "win": "Super_L",
    "enter": "Return", "esc": "Escape", "escape": "Escape", "space": "space",
    "backspace": "BackSpace", "tab": "Tab", "delete": "Delete", "insert": "Insert",
    "home": "Home", "end": "End", "pageup": "Prior", "pagedown": "Next",
    "up": "Up", "down": "Down", "left": "Left", "right": "Right",
}
# evdev keycodes, used only for explicitly allowlisted shortcuts with ydotool.
EVDEV = dict(zip("qwertyuiop", range(16, 26))) | dict(zip("asdfghjkl", range(30, 39))) | dict(zip("zxcvbnm", range(44, 51)))
EVDEV.update(dict(zip("1234567890", range(2, 12))))
EVDEV.update({"ctrl": 29, "shift": 42, "alt": 56, "win": 125, "enter": 28, "esc": 1,
              "escape": 1, "space": 57, "backspace": 14, "tab": 15, "delete": 111,
              "insert": 110, "home": 102, "end": 107, "pageup": 104, "pagedown": 109,
              "up": 103, "down": 108, "left": 105, "right": 106})
EVDEV.update({f"f{i}": 58 + i for i in range(1, 11)})
EVDEV.update(f11=87, f12=88)

EVDEV.update({"menu": 139, "minus": 12, "equals": 13, "comma": 51, "period": 52, "slash": 53,
              "backslash": 43, "semicolon": 39, "quote": 40, "bracketleft": 26, "bracketright": 27,
              "grave": 41, "printscreen": 99, "pause": 119, "capslock": 58, "numlock": 69, "scrolllock": 70,
              "volumeup": 115, "volumedown": 114, "volumemute": 113, "playpause": 164,
              "nexttrack": 163, "prevtrack": 165, "stop": 166})
EVDEV.update({f"f{i}": 170 + i for i in range(13, 25)})
EVDEV.update({f"numpad{i}": value for i, value in enumerate([82, 79, 80, 81, 75, 76, 77, 71, 72, 73])})
KEYSYMS.update({"menu": "Menu", "quote": "apostrophe", "printscreen": "Print", "pause": "Pause",
                "capslock": "Caps_Lock", "numlock": "Num_Lock", "scrolllock": "Scroll_Lock",
                "volumeup": "XF86AudioRaiseVolume", "volumedown": "XF86AudioLowerVolume", "volumemute": "XF86AudioMute",
                "playpause": "XF86AudioPlay", "nexttrack": "XF86AudioNext", "prevtrack": "XF86AudioPrev", "stop": "XF86AudioStop"})
KEYSYMS.update({f"numpad{i}": f"KP_{i}" for i in range(10)})


def unavailable(message):
    raise HTTPException(503, message)


class Commands:
    def has(self, name):
        return shutil.which(name) is not None

    def run(self, *arguments, input=None, timeout=5):
        if not self.has(arguments[0]):
            unavailable(f"Install {arguments[0]} on the Linux PC to use this feature.")
        try:
            result = subprocess.run(arguments, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, check=False, env={**os.environ, "LC_ALL": "C"})
        except (OSError, subprocess.TimeoutExpired) as error:
            unavailable(f"{arguments[0]} did not complete. Check the desktop session and permissions.")
        if result.returncode:
            # Never return helper stderr, which may contain clipboard text or credentials.
            unavailable(f"{arguments[0]} refused the request. Check the desktop session and permissions.")
        return result.stdout

    def json(self, *arguments):
        try:
            return json.loads(self.run(*arguments))
        except (ValueError, UnicodeError):
            unavailable(f"{arguments[0]} returned an invalid response.")


class LinuxDesktop:
    def __init__(self, commands=None, environment=None, pointer_factory=None):
        self.commands = commands or Commands()
        self.environment = os.environ if environment is None else environment
        self.wayland = bool(self.environment.get("WAYLAND_DISPLAY") or self.environment.get("XDG_SESSION_TYPE") == "wayland")
        desktop = self.environment.get("XDG_CURRENT_DESKTOP", "").lower()
        preferred = self.environment.get("ORBIT_KEYBOARD_BACKEND")
        self.use_wtype = preferred == "wtype" or (preferred is None and any(name in desktop for name in ("hyprland", "sway", "river", "labwc")))
        self.input_lock = threading.RLock()
        self.audio_lock = threading.RLock()
        self.capture = None  # Attached by the Qt tray on its main thread.
        self._dragging = False
        self._stream_gate = threading.BoundedSemaphore(1)
        from orbit_linux_pointer import WaylandPointer
        self._pointer_factory = pointer_factory or WaylandPointer
        self._pointer = None
        self._pointer_unavailable = False
        self.pointer_backend = self.environment.get("ORBIT_POINTER_BACKEND", "auto")
        if self.pointer_backend not in {"auto", "wayland", "ydotool"}:
            raise ValueError("ORBIT_POINTER_BACKEND must be auto, wayland, or ydotool.")
        from orbit_linux_apps import LinuxApps, LinuxPresentation
        self.apps = LinuxApps(self.environment)
        self.presentation = LinuxPresentation(self)

    def diagnostics(self):
        tools = ("pactl", "playerctl", "loginctl", "systemctl", "xdg-open", "gio", "sunshine")
        desktop_tools = ("wl-copy", "wl-paste", "wtype", "ydotool", "grim") if self.wayland else ("xclip", "xdotool")
        return {"session": "wayland" if self.wayland else "x11", "desktop": self.environment.get("XDG_CURRENT_DESKTOP", "unknown"),
                "helpers": {name: self.commands.has(name) for name in tools + desktop_tools},
                "capture": "XDG ScreenCast portal / PipeWire" if self.wayland else "Qt screen capture",
                "absolutePointer": not self.wayland or bool(self._pointer and self._pointer.manager_version >= 2 and self.capture and getattr(self.capture, "output_name", None)),
                "pointerBackend": ("wayland" if self._pointer else "ydotool" if self._pointer_unavailable else self.pointer_backend) if self.wayland else "xdotool",
                "inputNote": "Native wlr virtual pointer where available; ydotoold fallback on other compositors. Direct touch requires a native screen selected in the tray." if self.wayland else "X11 input requires xdotool."}

    def _native_pointer(self):
        if self.pointer_backend == "ydotool" or self._pointer_unavailable:
            return None
        if self._pointer is None:
            from orbit_linux_pointer import PointerUnavailable
            try:
                self._pointer = self._pointer_factory()
            except PointerUnavailable as error:
                if self.pointer_backend == "wayland":
                    unavailable(str(error))
                self._pointer_unavailable = True
        return self._pointer

    def clipboard_read(self):
        args = ("wl-paste", "--no-newline", "--type", "text") if self.wayland else ("xclip", "-selection", "clipboard", "-o")
        data = self.commands.run(*args)
        if len(data) > 1024 * 1024:
            raise HTTPException(413, "Clipboard text exceeds 1 MiB.")
        try:
            return data.decode("utf-8")
        except UnicodeError:
            raise HTTPException(422, "The clipboard does not contain UTF-8 text.") from None

    def clipboard_write(self, text):
        data = text.encode("utf-8")
        if len(data) > 1024 * 1024 or "\0" in text:
            raise HTTPException(422, "Clipboard text must be at most 1 MiB without null characters.")
        args = ("wl-copy", "--type", "text/plain;charset=utf-8") if self.wayland else ("xclip", "-selection", "clipboard", "-i")
        self.commands.run(*args, input=data)

    def type_text(self, text):
        if len(text) > 10000 or "\0" in text:
            raise HTTPException(422, "Text is too long or contains null characters.")
        if not text:
            return
        with self.input_lock:
            if self.wayland and self.use_wtype and self.commands.has("wtype"):
                self.commands.run("wtype", "-", input=text.encode(), timeout=15)
            elif self.wayland:
                if not text.isascii():
                    raise HTTPException(422, "Unicode typing needs wtype and compositor virtual-keyboard support. Use Clipboard instead.")
                self.commands.run("ydotool", "type", "--key-delay", "0", "--file", "-", input=text.encode(), timeout=15)
            else:
                self.commands.run("xdotool", "type", "--clearmodifiers", "--delay", "0", "--file", "-", input=text.encode(), timeout=15)

    def hotkey(self, keys):
        import orbit_input
        keys = orbit_input.normalize_chord(keys)
        if any(key not in EVDEV for key in keys):
            raise HTTPException(422, "This shortcut is not supported by the Linux input backend.")
        with self.input_lock:
            if self.wayland and self.use_wtype and self.commands.has("wtype"):
                args = ["wtype"]
                for key in keys:
                    args.extend(["-P", KEYSYMS.get(key, key.upper() if key.startswith("f") and key[1:].isdigit() else key)])
                for key in reversed(keys):
                    args.extend(["-p", KEYSYMS.get(key, key.upper() if key.startswith("f") and key[1:].isdigit() else key)])
                self.commands.run(*args)
            elif self.wayland:
                events = [f"{EVDEV[key]}:1" for key in keys] + [f"{EVDEV[key]}:0" for key in reversed(keys)]
                self.commands.run("ydotool", "key", "--key-delay", "0", *events)
            else:
                chord = "+".join(KEYSYMS.get(key, key.upper() if key.startswith("f") and key[1:].isdigit() else key) for key in keys)
                self.commands.run("xdotool", "key", "--clearmodifiers", chord)
        return keys

    def cursor(self, dx=0, dy=0, click="", scroll=0, hscroll=0, norm_x=None, norm_y=None, drag=""):
        if click not in {"", "left", "right", "middle", "double"} or drag not in {"", "down", "up"}:
            raise HTTPException(422, "Invalid pointer operation.")
        if max(abs(dx), abs(dy)) > 10000 or max(abs(scroll), abs(hscroll)) > 100:
            raise HTTPException(422, "Pointer movement exceeds the allowed range.")
        if (norm_x is None) != (norm_y is None):
            raise HTTPException(422, "Both normalized coordinates are required.")
        if norm_x is not None and not all(math.isfinite(v) and 0 <= v <= 1 for v in (norm_x, norm_y)):
            raise HTTPException(422, "Normalized coordinates must be between zero and one.")
        with self.input_lock:
            output = getattr(self.capture, "output_name", None) if self.capture else None
            if self.wayland and norm_x is not None and not output:
                raise HTTPException(501, "Choose a native screen preview in the Linux tray for direct touch, or use Sunshine. Portal capture supports trackpad input.")
            pointer = self._native_pointer() if self.wayland else None
            if pointer is not None:
                try:
                    pointer.cursor(dx, dy, click, scroll, hscroll, norm_x, norm_y, drag, output)
                    self._dragging = (drag == "down") if drag else self._dragging
                except Exception:
                    pointer.close()
                    self._pointer = None
                    self._dragging = False
                    unavailable("Native Wayland input stopped. Check that the shared screen is still connected and try again.")
                return
            if self.wayland and norm_x is not None:
                raise HTTPException(501, "Direct touch needs compositor virtual-pointer support; use trackpad input or Sunshine.")
            if norm_x is not None:
                if self.capture is None or self.capture.geometry is None:
                    raise HTTPException(409, "Start the screen preview before direct-touch input.")
                x, y, width, height = self.capture.geometry
                self.commands.run("xdotool", "mousemove", str(x + round(norm_x * (width - 1))), str(y + round(norm_y * (height - 1))))
            elif dx or dy:
                args = ("ydotool", "mousemove", "--", str(dx), str(dy)) if self.wayland else ("xdotool", "mousemove_relative", "--", str(dx), str(dy))
                self.commands.run(*args)
            if drag:
                if self.wayland:
                    self.commands.run("ydotool", "click", "0x40" if drag == "down" else "0x80")
                else:
                    self.commands.run("xdotool", "mousedown" if drag == "down" else "mouseup", "1")
                self._dragging = drag == "down"
            if click:
                if self.wayland:
                    self.commands.run("ydotool", "click", "--repeat", "2" if click == "double" else "1", {"left": "0xC0", "double": "0xC0", "right": "0xC1", "middle": "0xC2"}[click])
                else:
                    self.commands.run("xdotool", "click", "--repeat", "2" if click == "double" else "1", {"left": "1", "double": "1", "right": "3", "middle": "2"}[click])
            if scroll or hscroll:
                if self.wayland:
                    self.commands.run("ydotool", "mousemove", "--wheel", "--", str(hscroll), str(scroll))
                else:
                    for value, positive, negative in ((scroll, "4", "5"), (hscroll, "7", "6")):
                        if value:
                            self.commands.run("xdotool", "click", "--repeat", str(abs(value)), positive if value > 0 else negative)

    def release_input(self):
        with self.input_lock:
            if self._pointer is not None:
                try:
                    self._pointer.close()
                finally:
                    self._pointer = None
                    self._dragging = False
                return
            if self._dragging:
                try:
                    self.cursor(drag="up")
                finally:
                    self._dragging = False

    def audio_metrics(self):
        try:
            sink = self.commands.run("pactl", "get-default-sink").decode().strip()
            rows = self.commands.json("pactl", "--format=json", "list", "sinks")
            row = next(item for item in rows if item["name"] == sink)
            return {"volume": self._volume(row), "isMuted": bool(row["mute"]), "volumeAvailable": True}
        except (HTTPException, KeyError, StopIteration, ValueError):
            return {"volume": 0, "isMuted": False, "volumeAvailable": False}

    @staticmethod
    def _volume(row):
        channels = list(row.get("volume", {}).values())
        return round(min(100, max(0, sum(channel["value"] for channel in channels) / max(1, len(channels)) / 65536 * 100)), 1)

    def set_volume(self, level):
        self.commands.run("pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{level}%")
        return {"status": "ok", **self.audio_metrics()}

    def list_audio_sessions(self):
        result = []
        for row in self.commands.json("pactl", "--format=json", "list", "sink-inputs"):
            props = row.get("properties", {})
            try:
                pid = int(props.get("application.process.id", 0))
                created = psutil.Process(pid).create_time() if pid > 0 else None
            except (ValueError, psutil.Error):
                continue
            # Sink input identity also changes when an application recreates its stream.
            identity = hashlib.sha256(f"{row['index']}:{row.get('client')}:{pid}:{created}".encode()).hexdigest()
            result.append({"id": identity, "pid": pid, "name": props.get("application.name", "Audio stream"),
                           "displayName": props.get("media.name") or props.get("application.name", "Audio stream"),
                           "volume": self._volume(row), "isMuted": bool(row.get("mute")), "isActive": not row.get("corked", False),
                           "kind": "app", "iconID": None, "processCreateTime": created,
                           "outputDeviceID": str(row.get("sink", "")), "outputDeviceName": None,
                           "_index": row["index"]})
        return result

    def _audio_session(self, identity):
        row = next((row for row in self.list_audio_sessions() if row["id"] == identity), None)
        if row is None:
            raise HTTPException(409, "This audio stream ended. Refresh the mixer.")
        return row

    def update_audio_session(self, identity, volume, muted):
        with self.audio_lock:
            row = self._audio_session(identity)
            if volume is not None:
                self.commands.run("pactl", "set-sink-input-volume", str(row["_index"]), f"{volume}%")
            if muted is not None:
                row = self._audio_session(identity)
                self.commands.run("pactl", "set-sink-input-mute", str(row["_index"]), "1" if muted else "0")
            return self._audio_session(identity)

    def list_audio_outputs(self):
        rows = self.commands.json("pactl", "--format=json", "list", "sinks")
        return {"devices": [{"id": str(row["index"]), "name": row.get("description", row["name"])} for row in rows], "routingAvailable": True}

    def route_audio_session(self, identity, expected_create_time, device_id):
        with self.audio_lock:
            row = self._audio_session(identity)
            if row["processCreateTime"] != expected_create_time:
                raise HTTPException(409, "The application changed. Refresh the mixer.")
            if device_id and device_id not in {row["id"] for row in self.list_audio_outputs()["devices"]}:
                raise HTTPException(409, "This audio output disconnected.")
            self.commands.run("pactl", "move-sink-input", str(row["_index"]), device_id or "@DEFAULT_SINK@")
            return {"status": "ok", "session": self._audio_session(identity)}

    def action(self, name):
        if name in {"sleep", "restart", "shutdown"}:
            self.commands.run("systemctl", "--no-ask-password", {"sleep": "suspend", "restart": "reboot", "shutdown": "poweroff"}[name])
        elif name == "lock":
            session = self.environment.get("XDG_SESSION_ID")
            if not session:
                unavailable("XDG_SESSION_ID is missing; start Orbit inside the graphical login session.")
            self.commands.run("loginctl", "lock-session", session)
        elif name == "mute":
            self.commands.run("pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle")
        elif name in {"volume_up", "volume_down"}:
            metrics = self.audio_metrics()
            if not metrics["volumeAvailable"]:
                unavailable("PulseAudio/PipeWire audio is unavailable.")
            self.set_volume(max(0, min(100, metrics["volume"] + (5 if name == "volume_up" else -5))))
        elif name in {"media_play_pause", "media_next", "media_prev"}:
            self.commands.run("playerctl", {"media_play_pause": "play-pause", "media_next": "next", "media_prev": "previous"}[name])
        elif name in {"fullscreen", "alt_tab", "show_desktop", "task_view"}:
            self.hotkey({"fullscreen": ["f11"], "alt_tab": ["alt", "tab"], "show_desktop": ["win", "d"], "task_view": ["win", "tab"]}[name])
        else:
            raise HTTPException(501, f"{name} has no portable Linux equivalent. Use the compositor's controls.")
        return {"status": "sent", "executed": name}

    def open_target(self, target):
        if str(target).endswith(".desktop") and Path(target).is_file():
            self.commands.run("gio", "launch", str(target))
        else:
            import orbit_links
            self.commands.run("xdg-open", orbit_links.validate_url(target))

    def sensor_metrics(self):
        readings = psutil.sensors_temperatures()
        temperatures = [entry.current for name, entries in readings.items() if name in {"coretemp", "k10temp", "zenpower", "cpu_thermal"} for entry in entries if math.isfinite(entry.current)]
        frequency = psutil.cpu_freq()
        fans = [entry.current for entries in psutil.sensors_fans().values() for entry in entries if entry.current > 0 and "cpu" in entry.label.lower()]
        return {"cpuTemp": max(temperatures) if temperatures else None, "cpuClockMHz": frequency.current if frequency else None,
                "cpuFanRPM": max(fans) if fans else None, "sensorSource": "Linux hwmon / psutil",
                "sensorStatus": "Only sensors exposed by the kernel and readable by your user are available."}

    async def stream(self, websocket):
        from fastapi import WebSocketDisconnect
        if self.capture is None:
            await websocket.close(code=1011, reason="Start Orbit's Linux tray to enable screen capture.")
            return
        if not self._stream_gate.acquire(blocking=False):
            await websocket.close(code=1013, reason="Another preview is already active.")
            return
        try:
            self.capture.start()
            while True:
                frame = await asyncio.to_thread(self.capture.frame, 30)
                await websocket.send_bytes(frame)
                await asyncio.sleep(0.1)
        except (WebSocketDisconnect, RuntimeError, TimeoutError):
            try:
                await websocket.close(code=1011, reason="Screen sharing stopped or was declined. Approve the portal on the PC and retry.")
            except RuntimeError:
                pass
        finally:
            self.capture.stop()
            try:
                await asyncio.to_thread(self.release_input)
            except HTTPException:
                pass
            self._stream_gate.release()
