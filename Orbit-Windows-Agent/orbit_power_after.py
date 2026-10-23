"""Sleep or shut down the PC when downloads or a watched program finish (DESIGN F1).

There is at most one rule per PC. `GET /api/power/after` →

    {"rule": null | {"trigger": "downloads|task", "taskID": null, "action": "sleep|shutdown",
                     "delaySeconds": 60, "state": "waiting|countdown", "countdownEndsAt": "ISO|null"}}

`PUT /api/power/after` `{"trigger": "downloads", "action": "sleep", "delaySeconds": 60, "taskID": null}`
replaces the rule (a running countdown is cancelled first). `DELETE /api/power/after` cancels a waiting
rule or a running countdown. All three need the main token and HTTPS.

- Trigger `downloads`: fires once nothing has been queued, downloading or staging for 60 seconds,
  counted from the later of the last download activity and the moment the rule was set (so a rule set
  while nothing downloads fires after a minute).
- Trigger `task`: fires when the watched program (`taskID` from `POST /api/tasks`) finishes or closes.
  Removing that task cancels the rule.

When it fires, `power.scheduled` ("Sleeping in 60 s") is emitted and the countdown (30–600 s) starts.
At the end, if nobody used the PC's keyboard or mouse during the countdown, `power.executing` is
emitted and the action runs through `orbit_agent.perform_action` (which tells the push relay first).
Otherwise, and on DELETE, `power.cancelled` is emitted. Rules live in memory only.
"""
import ctypes
import logging
import os
import socket
import threading
import time

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

import orbit_events

LOGGER = logging.getLogger("orbit.power_after")
TRIGGERS = ("downloads", "task")
ACTIONS = ("sleep", "shutdown")
DELAY_LIMITS = (30, 600)
DEFAULT_DELAY = 60
DOWNLOADS_QUIET_SECONDS = 60.0
ACTION_WORDS = {
    "sleep": {"ing": "Sleeping", "now": "Going to sleep now", "noun": "Sleep", "verb": "go to sleep",
              "stay": "The PC will stay on."},
    "shutdown": {"ing": "Shutting down", "now": "Shutting down now", "noun": "Shut down", "verb": "shut down",
                 "stay": "The PC will stay on."},
}


class PowerAfterError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def seconds_since_last_input():
    """Seconds since the last keyboard or mouse input on the PC, or None when Windows can't say."""
    if os.name != "nt":
        return None
    try:
        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(LASTINPUTINFO)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return None
        now = ctypes.windll.kernel32.GetTickCount() & 0xFFFFFFFF
        return ((now - info.dwTime) & 0xFFFFFFFF) / 1000.0
    except Exception:
        return None


def _delay_text(seconds):
    if seconds % 60 == 0 and seconds >= 120:
        return f"{seconds // 60} min"
    return f"{seconds} s"


class PowerAfter:
    """The single rule and its countdown. `tick()` advances it; `run()` ticks on a thread."""

    def __init__(self, *, perform, downloads=None, tasks=None, emit=None, clock=time.time,
                 monotonic=time.monotonic, idle_seconds=seconds_since_last_input, before_execute=None,
                 hostname=None):
        self._perform = perform
        self._downloads = downloads  # provider returning the DownloadsWatcher (or None)
        self._tasks = tasks  # provider returning the TaskWatcher (or None)
        self._emit = emit
        self._clock = clock
        self._monotonic = monotonic
        self._idle_seconds = idle_seconds
        self._before_execute = before_execute
        self._hostname = hostname
        self._condition = threading.Condition(threading.RLock())
        self._rule = None
        self._executing = False
        self._thread = None

    # Helpers -------------------------------------------------------------------------------------

    def _downloads_watcher(self):
        return self._downloads() if callable(self._downloads) else None

    def _task_watcher(self):
        return self._tasks() if callable(self._tasks) else None

    def _send(self, kind, title, body, level, data):
        try:
            return (self._emit or orbit_events.emit)(kind, title, body, level=level, data=data)
        except Exception:
            LOGGER.exception("Could not record the %s event", kind)
            return None

    def _public(self, rule):
        if rule is None:
            return None
        ends = rule["countdownEndsAtWall"]
        return {"trigger": rule["trigger"], "taskID": rule["taskID"], "action": rule["action"],
                "delaySeconds": rule["delaySeconds"], "state": rule["state"],
                "countdownEndsAt": orbit_events.iso_timestamp(ends) if ends is not None else None}

    def snapshot(self):
        with self._condition:
            return {"rule": self._public(self._rule)}

    # API operations -----------------------------------------------------------------------------

    def set_rule(self, body):
        if not isinstance(body, dict):
            raise PowerAfterError(422, "Send the rule as a JSON object.")
        trigger = body.get("trigger")
        action = body.get("action", "sleep")
        delay = body.get("delaySeconds", DEFAULT_DELAY)
        task_id = body.get("taskID")
        if trigger not in TRIGGERS:
            raise PowerAfterError(422, "trigger must be \"downloads\" or \"task\".")
        if action not in ACTIONS:
            raise PowerAfterError(422, "action must be \"sleep\" or \"shutdown\".")
        if delay is None:
            delay = DEFAULT_DELAY
        low, high = DELAY_LIMITS
        if isinstance(delay, bool) or not isinstance(delay, (int, float)) or not float(delay).is_integer() or not low <= delay <= high:
            raise PowerAfterError(422, f"delaySeconds must be a whole number of seconds from {low} to {high}.")
        delay = int(delay)
        label = None
        if trigger == "downloads":
            task_id = None
            watcher = self._downloads_watcher()
            if watcher is None or (watcher.tracker.polled and not watcher.any_store()):
                raise PowerAfterError(409, "Orbit can't find Steam, Epic Games Launcher or GOG Galaxy on this PC, so it can't tell when downloads finish.")
        else:
            if not isinstance(task_id, str) or not task_id:
                raise PowerAfterError(422, "taskID is required for a task rule. Start watching the program first.")
            watcher = self._task_watcher()
            task = watcher.get(task_id) if watcher is not None else None
            if task is None:
                raise PowerAfterError(404, "Orbit isn't watching that program any more. Start watching it again from the Task Manager.")
            if task["state"] != "watching":
                raise PowerAfterError(409, f"{task['label']} has already finished.")
            label = task["label"]
        replaced = None
        with self._condition:
            if self._executing:
                raise PowerAfterError(409, "The PC is already going to sleep or shutting down.")
            if self._rule is not None and self._rule["state"] == "countdown":
                replaced = self._rule
            self._rule = {"trigger": trigger, "taskID": task_id, "taskLabel": label, "action": action,
                          "delaySeconds": delay, "state": "waiting", "createdAt": self._monotonic(),
                          "countdownStartedAt": None, "countdownEndsAt": None, "countdownEndsAtWall": None,
                          "firedBy": None}
            public = self._public(self._rule)
            self._condition.notify_all()
        if replaced is not None:
            words = ACTION_WORDS[replaced["action"]]
            self._send("power.cancelled", f"{words['noun']} cancelled", "A new rule from Orbit replaced the countdown.",
                       "active", {"action": replaced["action"], "reason": "replaced"})
        return {"rule": public}

    def cancel(self, reason="user"):
        """Cancels the rule. Returns True when there was one. Raises PowerAfterError(409) when the
        action is already running."""
        with self._condition:
            if self._executing:
                raise PowerAfterError(409, "It's too late to cancel: the PC is already going to sleep or shutting down.")
            rule, self._rule = self._rule, None
            self._condition.notify_all()
        if rule is None:
            return False
        words = ACTION_WORDS[rule["action"]]
        if reason == "task_removed":
            body = "The program it was waiting for is no longer being watched. " + words["stay"]
        elif rule["state"] == "countdown":
            body = "Cancelled from Orbit. " + words["stay"]
        else:
            body = f"Orbit won't {words['verb']} the PC after {'the downloads' if rule['trigger'] == 'downloads' else rule['taskLabel'] or 'the program'}."
        self._send("power.cancelled", f"{words['noun']} cancelled", body, "active",
                   {"action": rule["action"], "reason": reason, "state": rule["state"]})
        return True

    def task_changed(self, kind, task):
        """TaskWatcher listener: wakes the worker on a finish, cancels the rule on removal."""
        with self._condition:
            rule = self._rule
            if rule is None or rule["trigger"] != "task" or rule["taskID"] != task.get("id"):
                return
            if kind == "finished":
                self._condition.notify_all()
                return
        if kind == "removed":
            try:
                self.cancel("task_removed")
            except PowerAfterError:
                pass

    # State machine -------------------------------------------------------------------------------

    def _trigger_reason(self, rule):
        """A sentence when the rule's trigger has fired, else None."""
        if rule["trigger"] == "downloads":
            watcher = self._downloads_watcher()
            if watcher is None:
                return None
            quiet_since = watcher.quiet_since()
            if quiet_since is None:
                return None
            if self._monotonic() - max(quiet_since, rule["createdAt"]) < DOWNLOADS_QUIET_SECONDS:
                return None
            return "Downloads finished."
        watcher = self._task_watcher()
        task = watcher.get(rule["taskID"]) if watcher is not None else None
        if task is None:
            return None  # removal cancels the rule through task_changed
        if task["state"] == "watching":
            return None
        return f"{task['label']} {'closed' if task['state'] == 'gone' else 'finished'}."

    def tick(self):
        """Advances the rule once. Returns what happened ("scheduled", "executed", ...) or None."""
        with self._condition:
            rule = self._rule
            if rule is None or self._executing:
                return None
            state = rule["state"]
        if state == "waiting":
            reason = self._trigger_reason(rule)
            if reason is None:
                return None
            with self._condition:
                if self._rule is not rule or rule["state"] != "waiting":
                    return None
                now, wall = self._monotonic(), self._clock()
                rule.update(state="countdown", countdownStartedAt=now, countdownEndsAt=now + rule["delaySeconds"],
                            countdownEndsAtWall=wall + rule["delaySeconds"], firedBy=reason)
                self._condition.notify_all()
            words = ACTION_WORDS[rule["action"]]
            self._send("power.scheduled", f"{words['ing']} in {_delay_text(rule['delaySeconds'])}",
                       f"{reason} Cancel from Orbit if you're still using the PC.", "timeSensitive",
                       {"action": rule["action"], "trigger": rule["trigger"], "taskID": rule["taskID"],
                        "delaySeconds": rule["delaySeconds"],
                        "countdownEndsAt": orbit_events.iso_timestamp(rule["countdownEndsAtWall"])})
            return "scheduled"
        with self._condition:
            if self._rule is not rule or rule["state"] != "countdown":
                return None
            now = self._monotonic()
            if now < rule["countdownEndsAt"]:
                return None
            elapsed = now - rule["countdownStartedAt"]
            idle = None
            try:
                idle = self._idle_seconds() if self._idle_seconds else None
            except Exception:
                idle = None
            in_use = idle is not None and idle < elapsed - 1.0
            self._rule = None
            self._executing = not in_use
            self._condition.notify_all()
        words = ACTION_WORDS[rule["action"]]
        if in_use:
            self._send("power.cancelled", f"{words['noun']} cancelled",
                       f"Someone used the PC during the countdown, so it stayed on.", "active",
                       {"action": rule["action"], "reason": "inUse"})
            return "cancelled"
        try:
            name = self._hostname or socket.gethostname()
            self._send("power.executing", words["now"], f"{rule['firedBy'] or ''} {name} will {words['verb']}.".strip(),
                       "active", {"action": rule["action"], "trigger": rule["trigger"], "taskID": rule["taskID"]})
            if self._before_execute is not None:
                try:
                    self._before_execute()
                except Exception:
                    LOGGER.warning("Could not deliver notifications before the power action", exc_info=True)
            try:
                self._perform(rule["action"])
            except Exception as error:
                LOGGER.warning("The %s after %s failed: %s", rule["action"], rule["trigger"], error)
                self._send("power.cancelled", f"Couldn't {words['verb']}",
                           f"Windows didn't let Orbit {words['verb']} the PC.", "active",
                           {"action": rule["action"], "reason": "failed"})
                return "failed"
            return "executed"
        finally:
            with self._condition:
                self._executing = False

    def run(self, stop_event):
        while not stop_event.is_set():
            try:
                self.tick()
            except Exception:
                LOGGER.exception("The power-after check failed")
            with self._condition:
                rule = self._rule
                timeout = 1.0
                if rule is not None and rule["state"] == "countdown":
                    timeout = max(0.05, min(1.0, rule["countdownEndsAt"] - self._monotonic()))
                self._condition.wait(timeout)

    def start(self, stop_event):
        def run():
            self.run(stop_event)
        self._thread = threading.Thread(target=run, name="orbit-power-after", daemon=True)
        self._thread.start()
        return self._thread

    def wake(self):
        with self._condition:
            self._condition.notify_all()


_SERVICE = None
_SERVICE_LOCK = threading.Lock()


def shared_service():
    with _SERVICE_LOCK:
        return _SERVICE


def set_shared_service(service):
    global _SERVICE
    with _SERVICE_LOCK:
        _SERVICE = service


def create_power_after_router(verify_control, service_provider=shared_service, require_windows=None):
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Sleep after downloads needs Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api/power", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    def service():
        current = service_provider()
        if current is None:
            raise HTTPException(503, "Orbit is still starting. Try again in a moment.")
        return current

    @router.get("/after")
    def get_rule():
        return service().snapshot()

    @router.put("/after")
    def put_rule(body: object = Body(None)):
        current = service()
        if require_windows is not None:
            require_windows()
        try:
            return current.set_rule(body)
        except PowerAfterError as error:
            raise HTTPException(error.status, error.message) from error

    @router.delete("/after")
    def delete_rule():
        current = service()
        try:
            cancelled = current.cancel("user")
        except PowerAfterError as error:
            raise HTTPException(error.status, error.message) from error
        return {"rule": None, "cancelled": cancelled}

    return router
