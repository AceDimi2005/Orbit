"""Windows' own 30-second warning before Orbit shuts down or restarts the PC.

Shut Down and Restart from the apps (`POST /api/action/shutdown` and `/restart`) run
`shutdown /s|/r /t 30 /c "…"`: the person at the PC sees Windows' warning, and
`POST /api/power/cancel` (`shutdown /a`) stops it. The answer to the action says
`"countdownSeconds": 30`, and the `powerCountdown` feature in `/api/capabilities` says this agent
has both routes.

Windows can't be asked how long is left, so this module remembers the countdown it started.
`/api/status` and `/api/watch/summary` report it as

    "powerCountdown": null | {"action": "shutdown|restart", "remainingSeconds": 27, "endsAt": "ISO"}

so every app shows the same countdown with Cancel, whichever device started it. A shutdown typed
at the PC (or one Orbit started before the agent restarted) isn't listed, but Cancel still stops it.

Automation keeps the short delay it always had: power after downloads has its own countdown in
the apps, and deck buttons run `perform_action` directly.

Nothing in the unit tests reaches Windows: the runner refuses to run elsewhere and the tests pass
their own.
"""
from datetime import datetime, timezone
import math
import os
import subprocess
import threading
import time

CREATE_NO_WINDOW = 0x08000000
COUNTDOWN_SECONDS = 30
COUNTDOWN_ACTIONS = ("shutdown", "restart")
# shutdown.exe exit codes (Win32 error numbers).
ERROR_SHUTDOWN_IN_PROGRESS = 1115
ERROR_NO_SHUTDOWN_IN_PROGRESS = 1116
ERROR_SHUTDOWN_IS_SCHEDULED = 1190


class CountdownError(RuntimeError):
    """Windows refused; `status` is the HTTP status the route answers with."""

    def __init__(self, message, status=503):
        super().__init__(message)
        self.status = status


class NothingToCancel(CountdownError):
    """409, and only this: the apps then drop their countdown, since nothing is left to cancel."""

    def __init__(self):
        super().__init__("No shutdown or restart is waiting on the PC.", status=409)


def shutdown_comment(action):
    """The line Windows shows in its warning (shutdown.exe allows 512 characters)."""
    noun = "restart" if action == "restart" else "shutdown"
    return f"Orbit: {noun} requested from a paired device. Cancel it in Orbit."


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def seconds_until(target, now):
    """Whole seconds left, rounded up. Rounded to milliseconds first: when start + 30 crosses a
    power of two, (start + 30) - start comes out a hair over 30 and would read as 31."""
    return max(0, math.ceil(round(target - now, 3)))


def run_shutdown_exe(arguments, timeout=10):
    """Runs shutdown.exe without a console window and returns its exit code."""
    if os.name != "nt":
        raise CountdownError("PC controls require Windows.", status=501)
    try:
        completed = subprocess.run(arguments, capture_output=True, timeout=timeout, creationflags=CREATE_NO_WINDOW)
    except (OSError, subprocess.SubprocessError) as error:
        raise CountdownError("Windows could not run shutdown.exe.") from error
    return completed.returncode


class PowerCountdown:
    """The countdown Orbit started, if any. `runner(arguments)` returns shutdown.exe's exit code."""

    def __init__(self, runner=None, seconds=COUNTDOWN_SECONDS, monotonic=time.monotonic, clock=time.time):
        self.runner = runner or run_shutdown_exe
        self.seconds = seconds
        self._monotonic = monotonic
        self._clock = clock
        # Start and cancel run one at a time; reading the state never waits for shutdown.exe.
        self._operation = threading.Lock()
        self._lock = threading.Lock()
        self._pending = None

    def snapshot(self):
        """`{"action", "remainingSeconds", "endsAt"}` while a countdown runs, else None."""
        with self._lock:
            pending = self._pending
            if pending is None:
                return None
            remaining = seconds_until(pending["endsAt"], self._monotonic())
            if remaining <= 0:
                self._pending = None
                return None
            return {"action": pending["action"], "remainingSeconds": remaining, "endsAt": iso(pending["endsAtWall"])}

    def start(self, action, before_start=None):
        """Starts Windows' warning for `action` and returns `(snapshot, started)`.

        The same action asked again keeps the countdown already running (`started` is False, and
        `before_start` doesn't run again). The other action replaces it: Orbit stops its countdown
        and starts a new one. `before_start()` runs right before shutdown.exe (the power hooks).
        Raises CountdownError: 409 when Windows already counts down to a shutdown Orbit didn't start.
        """
        if action not in COUNTDOWN_ACTIONS:
            raise ValueError("Only shutdown and restart use Windows' countdown.")
        with self._operation:
            current = self.snapshot()
            if current is not None and current["action"] == action:
                return current, False
            if current is not None:
                self._abort(missing_is_fine=True)
            if before_start is not None:
                before_start()
            code = self.runner(["shutdown", "/s" if action == "shutdown" else "/r", "/t", str(self.seconds),
                                "/c", shutdown_comment(action)])
            if code in (ERROR_SHUTDOWN_IS_SCHEDULED, ERROR_SHUTDOWN_IN_PROGRESS):
                raise CountdownError("Windows is already counting down to a shutdown or restart. Cancel it first.", status=409)
            if code != 0:
                raise CountdownError("Windows refused the shutdown request.")
            started_at, wall = self._monotonic(), self._clock()
            with self._lock:
                self._pending = {"action": action, "endsAt": started_at + self.seconds, "endsAtWall": wall + self.seconds}
            return self.snapshot() or {"action": action, "remainingSeconds": self.seconds, "endsAt": iso(wall + self.seconds)}, True

    def cancel(self):
        """Stops Windows' countdown (`shutdown /a`) and returns the action Orbit had started, or None
        when Windows had one Orbit didn't track. Raises NothingToCancel or CountdownError."""
        with self._operation:
            with self._lock:
                pending = self._pending
            self._abort(missing_is_fine=False)
            return pending["action"] if pending is not None else None

    def _abort(self, missing_is_fine):
        code = self.runner(["shutdown", "/a"])
        if code == 0 or (code == ERROR_NO_SHUTDOWN_IN_PROGRESS and missing_is_fine):
            with self._lock:
                self._pending = None
            return
        if code == ERROR_NO_SHUTDOWN_IN_PROGRESS:
            # Nothing waits on Windows' side either: someone stopped it at the PC.
            with self._lock:
                self._pending = None
            raise NothingToCancel()
        if code == ERROR_SHUTDOWN_IN_PROGRESS:
            raise CountdownError("It's too late to cancel: Windows is already shutting down.")
        raise CountdownError("Windows could not cancel the shutdown.")
