"""Power actions, timers, keep-awake and power plans, behind a small adapter.

Shutdown and restart use Windows' own countdown (`shutdown /s|/r /t 30 /c …`): the
person at the PC sees a warning naming the device that asked, and `shutdown /a`
(POST /api/power/cancel) stops it.

Timers ("sleep in 30 minutes", "shut down when the game exits") survive a restart of
the companion: they are saved in %LOCALAPPDATA%\\Orbit\\power.json and removed from
there *before* they fire, so a restart timer can never fire again after the reboot.
A timer whose time passed while the companion was not running is dropped, never
fired late. Every timer warns on the PC a minute before it fires.

Nothing in the unit tests reaches Windows: WindowsPower refuses to run elsewhere and
the tests use a fake backend.
"""
import ctypes
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time

CREATE_NO_WINDOW = 0x08000000
COUNTDOWN_SECONDS = 30
ERROR_NO_SHUTDOWN_IN_PROGRESS = 1116
TIMER_ACTIONS = ("shutdown", "restart", "sleep", "hibernate", "signout", "displayOff")
COUNTDOWN_ACTIONS = ("shutdown", "restart")
MIN_TIMER_SECONDS = 5
MAX_TIMER_SECONDS = 24 * 3600
MAX_KEEP_AWAKE_MINUTES = 7 * 24 * 60
WARNING_SECONDS = 60
GAME_EXIT_GRACE_SECONDS = 60
LATE_GRACE_SECONDS = 120
ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
ES_DISPLAY_REQUIRED = 0x00000002
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PLAN_LINE = re.compile(r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+?)\)\s*(\*)?\s*$")
ACTION_WORDS = {"shutdown": ("shut down", "Shutdown"), "restart": ("restart", "Restart"), "sleep": ("go to sleep", "Sleep"),
                "hibernate": ("hibernate", "Hibernate"), "signout": ("sign out", "Sign-out"),
                "displayOff": ("turn the display off", "Display off")}


class PowerUnavailable(RuntimeError):
    pass


class NothingToCancel(RuntimeError):
    pass


def shutdown_comment(action, requested_by):
    """`Orbit: restart requested from iPhone.` Quotes and control characters never reach shutdown.exe."""
    name = "".join(character for character in str(requested_by or "") if character.isprintable() and character not in '"%^&|<>')
    name = " ".join(name.split())[:40] or "a paired device"
    verb = {"shutdown": "shutdown", "restart": "restart"}.get(action, action)
    return f"Orbit: {verb} requested from {name}. Cancel it in Orbit on that device."


def parse_power_plans(text):
    plans = []
    for line in str(text or "").splitlines():
        match = PLAN_LINE.search(line.strip())
        if match:
            plans.append({"id": match.group(1).lower(), "name": match.group(2).strip(), "active": bool(match.group(3))})
    return plans


def iso(timestamp):
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def seconds_until(target, now):
    """Whole seconds left, rounded up. Rounded to milliseconds first: when start + 120 crosses a
    power of two, (start + 120) - start comes out a hair over 120 and would read as 121."""
    return max(0, math.ceil(round(target - now, 3)))


class WindowsPower:
    """The real Windows calls. Every method raises PowerUnavailable off Windows."""

    def __init__(self, runner=None, interactive=True):
        self.runner = runner or self._run
        self.interactive = interactive

    @staticmethod
    def _run(arguments, timeout=10):
        if os.name != "nt":
            raise PowerUnavailable("Power controls require Windows.")
        completed = subprocess.run(arguments, capture_output=True, timeout=timeout, creationflags=CREATE_NO_WINDOW)
        for name in ("stdout", "stderr"):
            raw = getattr(completed, name) or b""
            try:
                setattr(completed, name, raw.decode("oem", errors="replace"))  # console code page
            except LookupError:
                setattr(completed, name, raw.decode("utf-8", errors="replace"))
        return completed

    def _require_windows(self):
        if os.name != "nt":
            raise PowerUnavailable("Power controls require Windows.")

    def countdown(self, action, seconds, comment):
        if action not in COUNTDOWN_ACTIONS:
            raise ValueError("Only shutdown and restart use the Windows countdown.")
        seconds = max(0, min(int(seconds), 315360000))
        result = self.runner(["shutdown", "/s" if action == "shutdown" else "/r", "/t", str(seconds), "/c", comment[:500]])
        if getattr(result, "returncode", 1) != 0:
            raise PowerUnavailable("Windows refused the shutdown request.")

    def abort(self):
        result = self.runner(["shutdown", "/a"])
        code = getattr(result, "returncode", 1)
        if code == ERROR_NO_SHUTDOWN_IN_PROGRESS:
            raise NothingToCancel("No shutdown or restart is waiting on the PC.")
        if code != 0:
            raise PowerUnavailable("Windows could not cancel the shutdown.")

    def suspend(self, hibernate=False):
        """Sleep or hibernate, honouring Windows' power policy (no forced suspend)."""
        self._require_windows()
        if not ctypes.windll.powrprof.SetSuspendState(1 if hibernate else 0, 0, 0):
            raise PowerUnavailable("Windows did not enter " + ("hibernation." if hibernate else "sleep."))

    def sign_out(self):
        result = self.runner(["shutdown", "/l"])
        if getattr(result, "returncode", 1) != 0:
            raise PowerUnavailable("Windows could not sign out.")

    def display_off(self):
        self._require_windows()
        if not self.interactive:
            raise PowerUnavailable("The display can only be turned off from the signed-in session.")
        user32 = ctypes.windll.user32
        user32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
        # HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off. Posted, so a hung window cannot block it.
        if not user32.PostMessageW(ctypes.c_void_p(0xFFFF), 0x0112, 0xF170, 2):
            raise PowerUnavailable("Windows could not turn the display off.")

    def set_execution_state(self, flags):
        """Per thread: KeepAwake calls this from its own long-lived thread."""
        self._require_windows()
        kernel32 = ctypes.windll.kernel32
        kernel32.SetThreadExecutionState.argtypes = [ctypes.c_uint32]
        kernel32.SetThreadExecutionState.restype = ctypes.c_uint32
        if not kernel32.SetThreadExecutionState(flags):
            raise PowerUnavailable("Windows refused to keep the PC awake.")

    def plans(self):
        result = self.runner(["powercfg", "/list"])
        if getattr(result, "returncode", 1) != 0:
            raise PowerUnavailable("Windows could not list the power plans.")
        return parse_power_plans(getattr(result, "stdout", ""))

    def set_plan(self, guid):
        if not GUID.fullmatch(str(guid)):
            raise ValueError("Unknown power plan.")
        result = self.runner(["powercfg", "/setactive", guid])
        if getattr(result, "returncode", 1) != 0:
            raise PowerUnavailable("Windows could not switch the power plan.")

    def capabilities(self):
        supports = {"hibernate": False, "displayOff": os.name == "nt" and self.interactive}
        if os.name == "nt":
            try:
                # SYSTEM_POWER_CAPABILITIES starts with BOOLEANs: SystemS4 at 6, HiberFilePresent at 8.
                buffer = (ctypes.c_ubyte * 128)()
                if ctypes.windll.powrprof.GetPwrCapabilities(ctypes.byref(buffer)):
                    supports["hibernate"] = bool(buffer[6]) and bool(buffer[8])
            except (AttributeError, OSError):
                pass
        return supports

    def execute(self, action, comment, seconds=COUNTDOWN_SECONDS):
        if action in COUNTDOWN_ACTIONS:
            self.countdown(action, seconds, comment)
        elif action == "sleep":
            self.suspend(False)
        elif action == "hibernate":
            self.suspend(True)
        elif action == "signout":
            self.sign_out()
        elif action == "displayOff":
            self.display_off()
        else:
            raise ValueError("Unknown power action.")


class KeepAwake:
    """SetThreadExecutionState is per thread, so one thread holds the request and lets
    Windows sleep again the moment it ends."""

    def __init__(self, backend):
        self.backend = backend
        self._stop = None
        self._thread = None
        self._lock = threading.Lock()
        self.flags = 0

    def apply(self, flags):
        with self._lock:
            if flags == self.flags and (not flags or (self._thread and self._thread.is_alive())):
                return
            self._end_locked()
            self.flags = flags
            if flags:
                stop = threading.Event()
                thread = threading.Thread(target=self._hold, args=(flags, stop), name="orbit-keep-awake", daemon=True)
                self._stop, self._thread = stop, thread
                thread.start()

    def _hold(self, flags, stop):
        try:
            self.backend.set_execution_state(ES_CONTINUOUS | flags)
        except Exception:
            return
        stop.wait()
        try:
            self.backend.set_execution_state(ES_CONTINUOUS)
        except Exception:
            pass

    def _end_locked(self):
        if self._stop is not None:
            self._stop.set()
            if self._thread is not None and self._thread is not threading.current_thread():
                self._thread.join(timeout=2)
        self._stop = self._thread = None
        self.flags = 0

    def close(self):
        with self._lock:
            self._end_locked()


class PowerScheduler:
    def __init__(self, backend, path, clock=time.time, notify=None, game=None, record=None):
        self.backend = backend
        self.path = Path(path) if path else None
        self.clock = clock
        self.notify = notify or (lambda title, message: None)
        self.game = game or (lambda: None)
        self.record = record or (lambda action, summary, requested_by, result="ok": None)
        self.keeper = KeepAwake(backend)
        self.timer = None
        self.keep_awake = None
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread = None

    # MARK: persistence

    def load(self):
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8")) if self.path else {}
        except (OSError, ValueError):
            raw = {}
        now = self.clock()
        timer = raw.get("timer") if isinstance(raw, dict) else None
        if isinstance(timer, dict) and timer.get("action") in TIMER_ACTIONS:
            if timer.get("when") == "gameExits" and timer.get("state") == "waitingForGame":
                if self.game():
                    self.timer = timer
                else:
                    self.record("power.timer.dropped", f"Dropped the {ACTION_WORDS[timer['action']][1].lower()} timer: "
                                "the game was no longer running when Orbit started", timer.get("requestedBy"))
            elif isinstance(timer.get("firesAt"), (int, float)) and timer.get("state") == "scheduled":
                if timer["firesAt"] >= now - LATE_GRACE_SECONDS:
                    timer["firesAt"] = max(timer["firesAt"], now + WARNING_SECONDS)
                    timer["warned"] = False
                    self.timer = timer
                else:
                    self.record("power.timer.dropped", f"Dropped the {ACTION_WORDS[timer['action']][1].lower()} timer: "
                                "its time passed while Orbit was not running", timer.get("requestedBy"))
        keep = raw.get("keepAwake") if isinstance(raw, dict) else None
        if isinstance(keep, dict) and (keep.get("until") is None or (isinstance(keep.get("until"), (int, float)) and keep["until"] > now)):
            self.keep_awake = keep
            self.keeper.apply(ES_SYSTEM_REQUIRED | (ES_DISPLAY_REQUIRED if keep.get("display") else 0))
        self._save()

    def _save(self):
        if self.path is None:
            return
        payload = json.dumps({"timer": self.timer, "keepAwake": self.keep_awake}, sort_keys=True)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(f".orbit-tmp-{secrets.token_hex(6)}")
            with open(temporary, "w", encoding="utf-8") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
        except OSError:
            pass

    def start(self):
        self.load()
        if self._thread is None:
            self._stop.clear()
            self._thread = threading.Thread(target=self._loop, name="orbit-power", daemon=True)
            self._thread.start()

    def _loop(self):
        while not self._stop.wait(1.0):
            try:
                self.tick()
            except Exception:
                pass

    def close(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=3)
            self._thread = None
        self.keeper.close()

    # MARK: public state

    def public_timer(self):
        with self._lock:
            timer = self.timer
            if timer is None:
                return None
            fires = timer.get("firesAt")
            return {"id": timer["id"], "action": timer["action"], "when": timer["when"], "state": timer["state"],
                    "firesAt": iso(fires), "remainingSeconds": seconds_until(fires, self.clock()) if fires else None,
                    "createdAt": iso(timer["createdAt"]), "requestedBy": timer.get("requestedBy"), "game": timer.get("game")}

    def public_keep_awake(self):
        with self._lock:
            keep = self.keep_awake
            if keep is None:
                return None
            until = keep.get("until")
            return {"since": iso(keep["since"]), "until": iso(until), "display": bool(keep.get("display")),
                    "requestedBy": keep.get("requestedBy"),
                    "remainingSeconds": seconds_until(until, self.clock()) if until else None}

    # MARK: timers

    def set_timer(self, action, in_seconds=None, when=None, requested_by=None):
        if action not in TIMER_ACTIONS:
            raise ValueError(f"Unknown action. Use one of: {', '.join(TIMER_ACTIONS)}.")
        if (in_seconds is None) == (when is None):
            raise ValueError("Send either inSeconds or when.")
        now = self.clock()
        timer = {"id": secrets.token_hex(8), "action": action, "createdAt": now, "requestedBy": requested_by,
                 "warned": False}
        if when is not None:
            if when != "gameExits":
                raise ValueError('The only "when" is "gameExits".')
            game = self.game()
            if not game:
                raise LookupError("No game is running on the PC right now.")
            timer.update(when="gameExits", state="waitingForGame", firesAt=None, game=game, gameSeenAt=now)
            summary = f"Set the PC to {ACTION_WORDS[action][0]} when {game} exits"
        else:
            if isinstance(in_seconds, bool) or not isinstance(in_seconds, int) or not MIN_TIMER_SECONDS <= in_seconds <= MAX_TIMER_SECONDS:
                raise ValueError(f"inSeconds must be between {MIN_TIMER_SECONDS} and {MAX_TIMER_SECONDS}.")
            timer.update(when="time", state="scheduled", firesAt=now + in_seconds, game=None)
            summary = f"Set the PC to {ACTION_WORDS[action][0]} in {_duration(in_seconds)}"
        with self._lock:
            replaced = self.timer
            if replaced is not None and replaced.get("state") == "countdown":
                self._abort_quietly()
            self.timer = timer
            self._save()
        self.notify("Orbit · Power", f"{summary} (requested from {requested_by or 'a paired device'}). Cancel it in Orbit.")
        return self.public_timer(), summary

    def cancel_timer(self):
        with self._lock:
            timer = self.timer
            if timer is None:
                return None
            self.timer = None
            self._save()
            if timer.get("state") == "countdown":
                self._abort_quietly()
        return timer

    def _abort_quietly(self):
        try:
            self.backend.abort()
        except Exception:
            pass

    def tick(self):
        with self._lock:
            timer = self.timer
            now = self.clock()
            if self.keep_awake is not None and self.keep_awake.get("until") and now >= self.keep_awake["until"]:
                self.keep_awake = None
                self.keeper.apply(0)
                self._save()
            if timer is None:
                return
            action = timer["action"]
            words = ACTION_WORDS[action]
            if timer["state"] == "waitingForGame":
                if self.game():
                    timer["gameSeenAt"] = now
                elif now - timer.get("gameSeenAt", timer["createdAt"]) >= GAME_EXIT_GRACE_SECONDS:
                    timer.update(state="scheduled", firesAt=now + WARNING_SECONDS, warned=True)
                    self._save()
                    self.notify("Orbit · Power", f"{timer.get('game') or 'The game'} closed. The PC will {words[0]} in "
                                                 "1 minute. Cancel it in Orbit.")
                return
            if timer["state"] == "countdown":
                if now >= timer["firesAt"] + 10:
                    self.timer = None
                    self._save()
                return
            lead = COUNTDOWN_SECONDS if action in COUNTDOWN_ACTIONS else 0
            if not timer.get("warned") and timer["firesAt"] - now <= WARNING_SECONDS + lead:
                timer["warned"] = True
                self._save()
                remaining = max(1, seconds_until(timer["firesAt"], now))
                self.notify("Orbit · Power", f"The PC will {words[0]} in {_duration(remaining)} "
                                             f"(requested from {timer.get('requestedBy') or 'a paired device'}). Cancel it in Orbit.")
            if now < timer["firesAt"] - lead:
                return
            # Forget the timer on disk before acting: it must never fire twice.
            comment = shutdown_comment(action, timer.get("requestedBy"))
            if action in COUNTDOWN_ACTIONS:
                timer["state"] = "countdown"
                self._save()
                seconds = seconds_until(timer["firesAt"], now)
            else:
                self.timer = None
                self._save()
                seconds = 0
        try:
            self.backend.execute(action, comment, seconds)
            self.record("power.timer.fired", f"{words[1]} timer fired", timer.get("requestedBy"))
        except Exception as error:
            with self._lock:
                if self.timer is timer:
                    self.timer = None
                    self._save()
            self.record("power.timer.failed", f"{words[1]} timer could not run: {error}", timer.get("requestedBy"), "error")

    # MARK: keep awake

    def set_keep_awake(self, minutes=None, display=False, requested_by=None):
        if minutes is not None and (isinstance(minutes, bool) or not isinstance(minutes, int)
                                    or not 1 <= minutes <= MAX_KEEP_AWAKE_MINUTES):
            raise ValueError(f"minutes must be between 1 and {MAX_KEEP_AWAKE_MINUTES}, or null for until turned off.")
        if not isinstance(display, bool):
            raise ValueError("display is true or false.")
        now = self.clock()
        with self._lock:
            self.keep_awake = {"since": now, "until": now + minutes * 60 if minutes else None, "display": display,
                               "requestedBy": requested_by}
            self.keeper.apply(ES_SYSTEM_REQUIRED | (ES_DISPLAY_REQUIRED if display else 0))
            self._save()
        return self.public_keep_awake()

    def stop_keep_awake(self):
        with self._lock:
            if self.keep_awake is None:
                return False
            self.keep_awake = None
            self.keeper.apply(0)
            self._save()
            return True


def _duration(seconds):
    seconds = int(seconds)
    if seconds < 90:
        return f"{seconds} seconds" if seconds != 1 else "1 second"
    minutes = round(seconds / 60)
    if minutes < 90:
        return f"{minutes} minutes"
    hours, rest = divmod(minutes, 60)
    return f"{hours} h {rest} min" if rest else f"{hours} h"
