"""Watched programs: "tell me when this finishes" (DESIGN F1).

`POST /api/tasks` `{"pid": 123, "createTime": 1729700000.5, "mode": "exit|idle", "idleMinutes": 2,
"label": "Premiere Pro"}` starts watching one process, identified by its PID *and* creation time
(the pair the Task Manager list shows), so a recycled PID never counts as the same program.

- `exit`: finished when that process exits.
- `idle`: finished when the process and all its child processes together use less than 3 % of the
  PC's CPU (from `cpu_times` deltas) for `idleMinutes`, after having been busy at least once. If the
  process exits first, the task ends as `gone`.

`GET /api/tasks` → `{"tasks": [{"id", "pid", "createTime", "label", "name", "mode", "idleMinutes",
"state": "watching|finished|gone", "startedAt", "finishedAt", "cpuPercent", "wasActive"}]}` and
`DELETE /api/tasks/{id}` stops watching (or forgets a finished task). Each finish emits
`task.finished` when task notifications are on; listeners (power after a task) always hear it.
Tasks live in memory: an agent restart forgets them.
"""
import logging
import math
import re
import threading
import time
import uuid

import psutil
from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

import orbit_events
import orbit_notify

LOGGER = logging.getLogger("orbit.tasks")
MODES = ("exit", "idle")
IDLE_PERCENT = 3.0
IDLE_MINUTES_LIMITS = (1, 240)
DEFAULT_IDLE_MINUTES = 2
MAX_WATCHING = 20
MAX_TASKS = 50
RETAIN_ENDED_SECONDS = 6 * 60 * 60
POLL_SECONDS = 2.0
IDLE_SAMPLE_SECONDS = 5.0
LABEL_LIMIT = 80
# JSON carries the float exactly; this only absorbs rounding by other clients.
CREATE_TIME_TOLERANCE = 0.001
_ID = re.compile(r"^[0-9a-f]{32}$")


class TaskError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def _number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def _minutes_text(minutes):
    return f"{minutes:g} minute{'s' if minutes != 1 else ''}"


class TaskWatcher:
    """Thread-safe list of watched processes; `poll()` checks them (the thread calls it every 2 s)."""

    def __init__(self, *, clock=time.time, monotonic=time.monotonic, process=None, cpu_count=None,
                 emit=None, notify_enabled=None):
        self._clock = clock
        self._monotonic = monotonic
        self._process = process or psutil.Process
        self._cpu_count = cpu_count or (lambda: psutil.cpu_count() or 1)
        self._emit = emit
        self._notify_enabled = notify_enabled or (lambda: True)
        self._lock = threading.RLock()
        self._tasks = {}
        self._listeners = []
        self._thread = None

    def add_listener(self, listener):
        """`listener(kind, task)` with kind `finished` or `removed` (task is the API dict)."""
        with self._lock:
            self._listeners.append(listener)

    # Process access ------------------------------------------------------------------------------

    def _open(self, pid, create_time):
        """A fresh process object for exactly this (pid, createTime), or None when it has ended."""
        try:
            process = self._process(pid)
            created = process.create_time()
            if abs(float(created) - float(create_time)) > CREATE_TIME_TOLERANCE:
                return None
            status = process.status()
            if status == getattr(psutil, "STATUS_ZOMBIE", "zombie"):
                return None
            return process
        except (psutil.NoSuchProcess, psutil.ZombieProcess):
            return None

    @staticmethod
    def _tree_cpu(process):
        """{(pid, createTime): cpu seconds} for the process and every descendant still visible."""
        members = [process]
        try:
            members.extend(process.children(recursive=True))
        except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied):
            pass
        totals = {}
        for member in members:
            try:
                times = member.cpu_times()
                totals[(member.pid, float(member.create_time()))] = float(times.user) + float(times.system)
            except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied, AttributeError):
                continue
        return totals

    # API operations -----------------------------------------------------------------------------

    def add(self, body):
        if not isinstance(body, dict):
            raise TaskError(422, "Send the program to watch as a JSON object.")
        pid = body.get("pid")
        create_time = body.get("createTime")
        mode = body.get("mode", "exit")
        if isinstance(pid, bool) or not isinstance(pid, int) or not 0 < pid < 2 ** 32:
            raise TaskError(422, "pid must be the program's process ID from the Task Manager list.")
        if not _number(create_time) or create_time <= 0:
            raise TaskError(422, "createTime must be the program's creation time from the Task Manager list.")
        if mode not in MODES:
            raise TaskError(422, "mode must be \"exit\" or \"idle\".")
        idle_minutes = body.get("idleMinutes", DEFAULT_IDLE_MINUTES)
        if idle_minutes is None:
            idle_minutes = DEFAULT_IDLE_MINUTES
        low, high = IDLE_MINUTES_LIMITS
        if not _number(idle_minutes) or not low <= idle_minutes <= high:
            raise TaskError(422, f"idleMinutes must be between {low} and {high}.")
        label = body.get("label")
        if label is not None and not isinstance(label, str):
            raise TaskError(422, "label must be text.")
        process = self._open(pid, create_time)
        if process is None:
            raise TaskError(404, "That program has already closed, or its process ID now belongs to another program. Refresh the list and try again.")
        try:
            name = process.name()
        except (psutil.Error, OSError):
            name = ""
        label = orbit_notify.clean_text(label or "", LABEL_LIMIT) or orbit_notify.clean_text(_display_name(name), LABEL_LIMIT) or f"Process {pid}"
        baseline = self._tree_cpu(process) if mode == "idle" else {}
        now_wall, now = self._clock(), self._monotonic()
        with self._lock:
            for task in self._tasks.values():
                if (task["state"] == "watching" and task["pid"] == pid and task["mode"] == mode
                        and abs(task["createTime"] - float(create_time)) <= CREATE_TIME_TOLERANCE):
                    task["label"] = label
                    task["idleMinutes"] = idle_minutes
                    return self._public(task)
            self._prune(now)
            if sum(1 for task in self._tasks.values() if task["state"] == "watching") >= MAX_WATCHING:
                raise TaskError(409, f"Orbit is already watching {MAX_WATCHING} programs on this PC. Stop watching one first.")
            task = {
                "id": uuid.uuid4().hex, "pid": pid, "createTime": float(create_time), "label": label,
                "name": name or None, "mode": mode, "idleMinutes": idle_minutes if mode == "idle" else None,
                "state": "watching", "startedAt": now_wall, "finishedAt": None, "reason": None,
                "cpuPercent": None, "wasActive": False,
                "_sampleAt": now, "_sampleWall": now_wall, "_cpu": baseline, "_idleSince": None, "_ended": None,
            }
            self._tasks[task["id"]] = task
            return self._public(task)

    def get(self, task_id):
        with self._lock:
            task = self._tasks.get(task_id)
            return self._public(task) if task else None

    def list(self):
        with self._lock:
            self._prune(self._monotonic())
            tasks = sorted(self._tasks.values(), key=lambda task: (task["state"] != "watching", -task["startedAt"]))
            return {"tasks": [self._public(task) for task in tasks]}

    def remove(self, task_id):
        with self._lock:
            task = self._tasks.pop(task_id, None)
            listeners = list(self._listeners)
        if task is None:
            return False
        public = self._public(task)
        for listener in listeners:
            try:
                listener("removed", public)
            except Exception:
                LOGGER.exception("A task listener failed")
        return True

    @staticmethod
    def _public(task):
        return {
            "id": task["id"], "pid": task["pid"], "createTime": task["createTime"], "label": task["label"],
            "name": task["name"], "mode": task["mode"], "idleMinutes": task["idleMinutes"], "state": task["state"],
            "startedAt": orbit_events.iso_timestamp(task["startedAt"]),
            "finishedAt": orbit_events.iso_timestamp(task["finishedAt"]) if task["finishedAt"] else None,
            "reason": task["reason"], "cpuPercent": task["cpuPercent"], "wasActive": task["wasActive"],
        }

    def _prune(self, now):
        for task_id, task in list(self._tasks.items()):
            if task["_ended"] is not None and now - task["_ended"] > RETAIN_ENDED_SECONDS:
                del self._tasks[task_id]
        if len(self._tasks) > MAX_TASKS:
            ended = sorted((task for task in self._tasks.values() if task["_ended"] is not None), key=lambda task: task["_ended"])
            for task in ended[:len(self._tasks) - MAX_TASKS]:
                del self._tasks[task["id"]]

    # Watching -----------------------------------------------------------------------------------

    def poll(self):
        """Checks every watched process once. Returns the tasks that ended in this pass."""
        with self._lock:
            watching = [(task["id"], task["pid"], task["createTime"], task["mode"]) for task in self._tasks.values()
                        if task["state"] == "watching"]
        ended = []
        for task_id, pid, create_time, mode in watching:
            try:
                process = self._open(pid, create_time)
            except (psutil.Error, OSError):
                continue  # Windows refused to look this time (access denied); try again next pass
            now_wall, now = self._clock(), self._monotonic()
            if process is None:
                ended.append(self._end(task_id, "finished" if mode == "exit" else "gone", "exited", now_wall, now))
                continue
            if mode != "idle":
                continue
            with self._lock:
                task = self._tasks.get(task_id)
                due = task is not None and now - task["_sampleAt"] >= IDLE_SAMPLE_SECONDS
            if not due:
                continue
            try:
                totals = self._tree_cpu(process)
            except (psutil.Error, OSError):
                continue
            with self._lock:
                task = self._tasks.get(task_id)
                if task is None or task["state"] != "watching":
                    continue
                elapsed = now - task["_sampleAt"]
                previous, previous_wall = task["_cpu"], task["_sampleWall"]
                used = 0.0
                for key, seconds in totals.items():
                    if key in previous:
                        used += max(0.0, seconds - previous[key])
                    elif key[1] >= previous_wall - 1.0:
                        used += max(0.0, seconds)  # a child that started since the last sample
                percent = used / (elapsed * max(1, int(self._cpu_count()))) * 100.0 if elapsed > 0 else 0.0
                task["_cpu"], task["_sampleAt"], task["_sampleWall"] = totals, now, now_wall
                task["cpuPercent"] = round(percent, 1)
                if percent >= IDLE_PERCENT:
                    task["wasActive"] = True
                    task["_idleSince"] = None
                    continue
                if not task["wasActive"]:
                    continue
                if task["_idleSince"] is None:
                    # The quiet period started somewhere in the interval that just ended.
                    task["_idleSince"] = now - elapsed
                if now - task["_idleSince"] < task["idleMinutes"] * 60:
                    continue
            ended.append(self._end(task_id, "finished", "idle", now_wall, now))
        return [task for task in ended if task is not None]

    def _end(self, task_id, state, reason, now_wall, now):
        with self._lock:
            task = self._tasks.get(task_id)
            if task is None or task["state"] != "watching":
                return None
            task.update(state=state, reason=reason, finishedAt=now_wall, _ended=now)
            public = self._public(task)
            listeners = list(self._listeners)
        self._announce(public)
        for listener in listeners:
            try:
                listener("finished", public)
            except Exception:
                LOGGER.exception("A task listener failed")
        return public

    def _announce(self, task):
        if not self._notify_enabled():
            return None
        label = task["label"]
        if task["reason"] == "idle":
            title, body = f"{label} finished", f"It has been idle for {_minutes_text(task['idleMinutes'])}."
        elif task["state"] == "gone":
            title, body = f"{label} closed", "It closed before it went idle."
        else:
            title, body = f"{label} finished", "The program closed."
        try:
            return (self._emit or orbit_events.emit)("task.finished", title, body, level="active", data={
                "taskID": task["id"], "pid": task["pid"], "mode": task["mode"], "reason": task["reason"], "label": label})
        except Exception:
            LOGGER.exception("Could not record the task.finished event")
            return None

    def run(self, stop_event, interval=POLL_SECONDS):
        while not stop_event.wait(interval):
            try:
                self.poll()
            except Exception:
                LOGGER.exception("The watched-programs check failed")

    def start(self, stop_event):
        self._thread = threading.Thread(target=self.run, args=(stop_event,), name="orbit-tasks", daemon=True)
        self._thread.start()
        return self._thread


def _display_name(process_name):
    """`Adobe Premiere Pro.exe` → `Adobe Premiere Pro`."""
    name = (process_name or "").strip()
    return name[:-4] if name.lower().endswith(".exe") else name


_WATCHER = None
_WATCHER_LOCK = threading.Lock()


def shared_watcher():
    global _WATCHER
    with _WATCHER_LOCK:
        if _WATCHER is None:
            import orbit_alerts
            _WATCHER = TaskWatcher(notify_enabled=lambda: orbit_alerts.kind_enabled("tasks"))
        return _WATCHER


def set_shared_watcher(watcher):
    global _WATCHER
    with _WATCHER_LOCK:
        _WATCHER = watcher


def create_tasks_router(verify_control, watcher_provider=shared_watcher):
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Watching programs needs Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    @router.get("/tasks")
    def list_tasks():
        return watcher_provider().list()

    @router.post("/tasks")
    def watch_task(body: object = Body(None)):
        try:
            return watcher_provider().add(body)
        except TaskError as error:
            raise HTTPException(error.status, error.message) from error
        except psutil.AccessDenied as error:
            raise HTTPException(403, "Windows doesn't let Orbit watch this program.") from error
        except (psutil.Error, OSError) as error:
            raise HTTPException(503, "The PC could not look at this program. Try again in a moment.") from error

    @router.delete("/tasks/{task_id}")
    def stop_watching(task_id: str):
        if not _ID.match(task_id) or not watcher_provider().remove(task_id):
            raise HTTPException(404, "Orbit isn't watching that program.")
        return {"status": "removed"}

    return router
