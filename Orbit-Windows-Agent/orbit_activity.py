"""What paired devices did on this PC, and the Windows notifications about it.

Every state-changing request is written to %LOCALAPPDATA%\\Orbit\\activity.sqlite3:
which device, a category, an action id, a one-line summary and the result. Typed
text, clipboard contents and file contents are never recorded; file names are.
Single mouse/keyboard events are not logged one by one: an input session is.

Rows are written by a background thread so a request never waits for the disk.
"""
from datetime import datetime, timezone
import queue
import sqlite3
import threading
import time

CATEGORIES = ("power", "audio", "media", "display", "apps", "input", "screen", "clipboard", "files",
              "devices", "settings", "sunshine", "update", "history", "system")
RETENTION_SECONDS = 90 * 24 * 3600
MAX_ROWS = 5000
MAX_LIMIT = 200
PC_ACTOR = ("pc", "This PC")

# /api/action/{name}: category and summary.
ACTIONS = {
    "lock": ("power", "Locked the PC"),
    "sleep": ("power", "Put the PC to sleep"),
    "restart": ("power", "Restarted the PC (30-second warning on the PC)"),
    "shutdown": ("power", "Shut down the PC (30-second warning on the PC)"),
    "mute": ("audio", "Toggled mute"),
    "volume_up": ("audio", "Turned the volume up"),
    "volume_down": ("audio", "Turned the volume down"),
    "media_play_pause": ("media", "Play / pause"),
    "media_next": ("media", "Next track"),
    "media_prev": ("media", "Previous track"),
    "toggle_hdr": ("display", "Toggled HDR"),
    "restore_display": ("display", "Restored the display layout"),
    "kill_game": ("apps", "Closed the game"),
    "show_desktop": ("system", "Showed the desktop"),
    "task_view": ("system", "Opened Task View"),
    "alt_tab": ("system", "Switched windows"),
    "screenshot": ("system", "Took a screenshot"),
    "fullscreen": ("system", "Toggled full screen"),
}
SUMMARIES = {
    "volume.set": lambda c: f"Set the volume to {c.query.get('level', '?')}%",
    "process.end": lambda c: f"Ended process {c.path_params.get('pid', '')}",
    "audio.session": lambda c: "Changed an app's volume",
    "audio.route": lambda c: "Changed an app's audio output",
    "audio.default": lambda c: "Changed the default audio output",
    "audio.microphone": lambda c: "Changed the microphone mute",
    "sunshine.pin": lambda c: f"Entered the Sunshine pairing PIN for {c.query.get('name') or 'Orbit'}",
    "sunshine.start": lambda c: "Started Sunshine",
    "sunshine.launch": lambda c: f"Started {c.query.get('app') or 'an app'} from the Sunshine library",
    "sunshine.login.save": lambda c: "Saved the Sunshine web UI login",
    "sunshine.login.remove": lambda c: "Removed the Sunshine web UI login",
    "history.start": lambda c: "Started recording a session",
    "history.stop": lambda c: "Stopped recording",
    "history.delete": lambda c: "Deleted a recorded session",
    "clipboard.read": lambda c: "Read the PC clipboard",
    "clipboard.write": lambda c: "Sent text to the PC clipboard",
    "files.download": lambda c: f"Downloaded {_base(c.query.get('path'))}",
    "files.upload": lambda c: f"Uploaded {c.query.get('name') or 'a file'} to {_base(c.query.get('directory'))}",
    "files.mkdir": lambda c: "Created a folder",
    "files.rename": lambda c: "Renamed a file",
    "files.move": lambda c: "Moved a file",
    "files.trash": lambda c: "Moved an item to the Recycle Bin",
    "files.archive": lambda c: "Prepared a folder as ZIP",
    "files.archive.download": lambda c: "Downloaded a folder as ZIP",
    "device.create": lambda c: "Added a device",
    "device.update": lambda c: "Changed a device",
    "device.revoke": lambda c: "Removed a device",
    "update.apply": lambda c: "Updated Orbit PC Companion",
    "settings.notifications": lambda c: "Changed notification settings",
    "library.launch": lambda c: f"Launched {c.path_params.get('game_id', 'a game')}",
    "power.cancel": lambda c: "Cancelled the pending shutdown or restart",
    "power.timer": lambda c: "Set a power timer",
    "power.timer.cancel": lambda c: "Cancelled the power timer",
    "power.keepAwake": lambda c: "Kept the PC awake",
    "power.keepAwake.stop": lambda c: "Let the PC sleep again",
    "power.plan": lambda c: "Changed the power plan",
}


def _base(path):
    text = str(path or "").replace("\\", "/").rstrip("/")
    return text.rsplit("/", 1)[-1] or text or "the PC"


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def describe(context, status):
    """(category, action, summary) for a request that passed the access middleware."""
    policy = context.policy
    category = policy.category or "system"
    action = policy.action or f"{context.method.lower()} {context.path}"
    summary = None
    if action == "action":
        name = str(context.path_params.get("action_name", ""))
        category, summary = ACTIONS.get(name, ("system", f"Ran {name}"))
        action = f"action.{name}"
    elif action in SUMMARIES:
        try:
            summary = SUMMARIES[action](context)
        except Exception:
            summary = None
    notes = context.notes
    category = notes.get("category", category)
    action = notes.get("action", action)
    summary = notes.get("summary") or summary or action
    return category, action, summary


def result_for(status):
    if status is None:
        return "error"
    if status in (401, 403, 426):
        return "denied"
    return "ok" if status < 400 else "error"


class ActivityLog:
    def __init__(self, path, clock=time.time, retention_seconds=RETENTION_SECONDS, max_rows=MAX_ROWS):
        self.clock = clock
        self.retention_seconds = retention_seconds
        self.max_rows = max_rows
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.execute("PRAGMA journal_mode = WAL")
            self._db.executescript("""
                CREATE TABLE IF NOT EXISTS activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL,
                    device_id TEXT, device_name TEXT, category TEXT NOT NULL, action TEXT NOT NULL,
                    summary TEXT NOT NULL, result TEXT NOT NULL, status INTEGER);
                CREATE INDEX IF NOT EXISTS activity_category ON activity(category, id);
            """)
            self._prune_locked()
            self._db.commit()
        self._queue = queue.Queue(maxsize=10_000)
        self._writer = threading.Thread(target=self._write_loop, name="orbit-activity", daemon=True)
        self._closed = False
        self._writer.start()

    def _prune_locked(self):
        self._db.execute("DELETE FROM activity WHERE at < ?", (self.clock() - self.retention_seconds,))
        self._db.execute("DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY id DESC LIMIT ?)",
                         (self.max_rows,))

    def record(self, device_id, device_name, category, action, summary, result="ok", status=None):
        """Queue one entry; never blocks a request on the database."""
        if self._closed:
            return
        entry = (self.clock(), device_id, (device_name or "")[:80] or None, category if category in CATEGORIES else "system",
                 str(action)[:80], " ".join(str(summary).split())[:300], result, status)
        try:
            self._queue.put_nowait(entry)
        except queue.Full:
            pass

    def _write_loop(self):
        written = 0
        while True:
            entry = self._queue.get()
            if entry is None:
                self._queue.task_done()
                return
            batch = [entry]
            while True:
                try:
                    more = self._queue.get_nowait()
                except queue.Empty:
                    break
                if more is None:
                    self._queue.put(None)
                    self._queue.task_done()
                    break
                batch.append(more)
            try:
                with self._lock:
                    self._db.executemany("""INSERT INTO activity (at, device_id, device_name, category, action, summary,
                                            result, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""", batch)
                    written += len(batch)
                    if written >= 200:
                        self._prune_locked()
                        written = 0
                    self._db.commit()
            except sqlite3.Error:
                pass
            for _ in batch:
                self._queue.task_done()

    def wait(self, timeout=2.0):
        """Let queued entries reach the database (for reads right after a change)."""
        deadline = time.monotonic() + timeout
        while self._queue.unfinished_tasks and time.monotonic() < deadline:
            time.sleep(0.005)

    def entries(self, before=None, limit=50, category=None):
        limit = max(1, min(MAX_LIMIT, int(limit)))
        self.wait()
        query = "SELECT * FROM activity WHERE 1 = 1"
        arguments = []
        if before is not None:
            query += " AND id < ?"
            arguments.append(int(before))
        if category is not None:
            query += " AND category = ?"
            arguments.append(category)
        query += " ORDER BY id DESC LIMIT ?"
        arguments.append(limit + 1)
        with self._lock:
            rows = self._db.execute(query, arguments).fetchall()
        page = rows[:limit]
        entries = [{"id": row["id"], "at": iso(row["at"]), "deviceID": row["device_id"], "deviceName": row["device_name"],
                    "category": row["category"], "action": row["action"], "summary": row["summary"],
                    "result": row["result"], "status": row["status"]} for row in page]
        return {"entries": entries, "nextBefore": page[-1]["id"] if len(rows) > limit and page else None}

    def close(self):
        if self._closed:
            return
        self._closed = True
        self._queue.put(None)
        self._writer.join(timeout=5)
        with self._lock:
            self._db.close()


class Notifier:
    """Windows notifications through the tray balloon, filtered by the owner's settings.

    New devices and power actions always notify when enabled; file transfers, screen
    viewing and input sessions stay quiet while a game is running if the owner asked.
    """
    QUIET_WHILE_GAMING = frozenset({"files", "screenView", "inputSession"})

    def __init__(self, show=None, settings=None, gaming=None, clock=time.monotonic, throttle_seconds=30):
        self.show = show
        self.settings = settings or (lambda: {})
        self.gaming = gaming or (lambda: False)
        self.clock = clock
        self.throttle_seconds = throttle_seconds
        self._recent = {}
        self._suppressed = {}
        self._lock = threading.Lock()

    def notify(self, kind, title, message, key=None):
        show = self.show
        if show is None:
            return False
        settings = self.settings() or {}
        if not settings.get(kind, True):
            return False
        if settings.get("quietWhileGaming", True) and kind in self.QUIET_WHILE_GAMING and self.gaming():
            return False
        if key is not None:
            now = self.clock()
            with self._lock:
                last = self._recent.get((kind, key))
                if last is not None and now - last < self.throttle_seconds:
                    self._suppressed[(kind, key)] = self._suppressed.get((kind, key), 0) + 1
                    return False
                self._recent[(kind, key)] = now
                more = self._suppressed.pop((kind, key), 0)
            if more:
                message = f"{message} (+{more} more)"
        try:
            return bool(show(title, message))
        except Exception:
            return False


class InputSessions:
    """A device "starts controlling" the PC after `idle_seconds` without input from it."""

    def __init__(self, idle_seconds=120, clock=time.monotonic):
        self.idle_seconds = idle_seconds
        self.clock = clock
        self._last = {}
        self._lock = threading.Lock()

    def touch(self, device_key):
        now = self.clock()
        with self._lock:
            last = self._last.get(device_key)
            self._last[device_key] = now
            if len(self._last) > 256:
                for key, value in list(self._last.items()):
                    if now - value > self.idle_seconds:
                        del self._last[key]
            return last is None or now - last > self.idle_seconds
