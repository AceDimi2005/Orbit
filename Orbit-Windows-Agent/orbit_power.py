"""Power actions behind a small adapter, so tests never touch a real PC.

Shutdown and restart use Windows' own countdown (`shutdown /s|/r /t 30 /c …`): the
person at the PC sees a warning naming the device that asked, and `shutdown /a`
(POST /api/power/cancel) stops it.
"""
import os
import subprocess

CREATE_NO_WINDOW = 0x08000000
COUNTDOWN_SECONDS = 30
ERROR_NO_SHUTDOWN_IN_PROGRESS = 1116


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


class WindowsPower:
    """The real Windows calls. Every method raises PowerUnavailable off Windows."""

    def __init__(self, runner=None):
        self.runner = runner or self._run

    @staticmethod
    def _run(arguments, timeout=10):
        if os.name != "nt":
            raise PowerUnavailable("Power controls require Windows.")
        return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, creationflags=CREATE_NO_WINDOW)

    def countdown(self, action, seconds, comment):
        if action not in ("shutdown", "restart"):
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
