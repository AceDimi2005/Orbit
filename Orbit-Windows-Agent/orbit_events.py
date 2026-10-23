"""The PC's event log: things worth telling the user about (a download finished, the PC is hot).

Features call `emit(kind, title, body, level, data)`. The event is stored in
`%LOCALAPPDATA%\\Orbit\\events.sqlite3` (kept 7 days, at most 1000 events), shown as a PC toast
when the user allows it, and handed to registered dispatchers (instant push) on a background
thread, so a slow network never holds up the feature that emitted it.

Phones read the log with `GET /api/events?since=<id>&limit=<1..200>` (main token, HTTPS only):
`{"events": [...oldest first...], "latestID": <id>, "more": <bool>}`.

- Without `since`: the newest `limit` events (`more` is false).
- With `since`: the events after that id, oldest first. `more` is true when newer events are
  still waiting; ask again with `since` = the id of the last event received. When `more` is
  false the client is caught up and may remember `latestID` as its next `since`: every id up
  to it was either returned or has expired.
- `latestID` is the highest id this log has ever handed out (0 for a brand-new log). It never
  goes down, not even when old events expire or every event is gone. Ids only grow, so a
  `latestID` below the `since` a client remembers means the log was recreated on the PC (for
  example after it was damaged or deleted) and the client should start again from 0.
- Events older than 7 days are never listed (they are deleted before each read).

Event kinds: pc.online, download.finished, download.failed, downloads.allFinished,
temperature.high, task.finished, power.scheduled, power.cancelled, power.executing,
summary.ready, webcam.connected. Levels: passive, active, timeSensitive.
"""
import copy
from datetime import datetime, timezone
import json
import logging
import math
import os
from pathlib import Path
import queue
import re
import sqlite3
import threading
import time

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

import orbit_notify

LOGGER = logging.getLogger("orbit.events")
LEVELS = ("passive", "active", "timeSensitive")
EVENT_KINDS = (
    "pc.online", "download.finished", "download.failed", "downloads.allFinished", "temperature.high",
    "task.finished", "power.scheduled", "power.cancelled", "power.executing", "summary.ready",
    "webcam.connected",
)
RETENTION_SECONDS = 7 * 24 * 60 * 60
MAX_EVENTS = 1000
DEFAULT_PAGE = 50
MAX_PAGE = 200
TITLE_LIMIT = 120
BODY_LIMIT = 500
MAX_DATA_BYTES = 4096
DISPATCH_QUEUE_SIZE = 256
_KIND = re.compile(r"^[a-z][A-Za-z0-9]{0,31}(\.[a-z][A-Za-z0-9]{0,31}){1,3}$")


def default_events_path():
    from orbit_tls import data_directory
    return data_directory() / "events.sqlite3"


def iso_timestamp(seconds):
    """`2026-10-23T18:00:00Z`: UTC, whole seconds (what ISO8601DateFormatter reads by default)."""
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event_epoch(event):
    """The event's time as Unix seconds (from the `ts` text of an event dict)."""
    return datetime.strptime(event["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def _clean(value, limit):
    return orbit_notify.clean_text(value, limit)


def _validated(kind, level, data):
    if not isinstance(kind, str) or not _KIND.match(kind):
        raise ValueError(f"Invalid event kind: {kind!r}")
    if level not in LEVELS:
        raise ValueError(f"Invalid event level: {level!r}. Use one of {', '.join(LEVELS)}.")
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ValueError("Event data must be a dict")
    encoded = json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if len(encoded.encode("utf-8")) > MAX_DATA_BYTES:
        raise ValueError(f"Event data must stay under {MAX_DATA_BYTES} bytes")
    return encoded


class EventLog:
    """Thread-safe SQLite store. Opening and `append` prune to the retention window and row
    limit; `page` first deletes events that expired while nothing was appended."""

    def __init__(self, path=None, *, clock=time.time, retention_seconds=RETENTION_SECONDS, max_events=MAX_EVENTS):
        self.path = Path(path) if path is not None else default_events_path()
        self._clock = clock
        self._retention = max(60.0, float(retention_seconds))
        self._max_events = max(1, int(max_events))
        self._lock = threading.RLock()
        self._closed = False
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self._db = self._open()
        except sqlite3.OperationalError:
            raise  # Locked or unreachable, not damaged: never set a good log aside.
        except sqlite3.DatabaseError:
            # Events are a convenience: a damaged log is set aside rather than stopping the agent.
            damaged = self.path.with_name(self.path.name + ".corrupt")
            LOGGER.warning("The event log was unreadable and was moved to %s", damaged)
            for suffix in ("-wal", "-shm"):
                Path(str(self.path) + suffix).unlink(missing_ok=True)
            os.replace(self.path, damaged)
            self._db = self._open()

    def _open(self):
        db = sqlite3.connect(self.path, check_same_thread=False)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA journal_mode = WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL,
                    level TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, data TEXT
                );
                CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            """)
            self._prune(db, self._now())
            db.commit()
            return db
        except BaseException:
            db.close()
            raise

    def _prune(self, db, now):
        db.execute("DELETE FROM events WHERE ts < ?", (now - self._retention,))
        db.execute("DELETE FROM events WHERE id < (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?)",
                   (self._max_events - 1,))

    def _now(self):
        now = self._clock()
        if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now):
            now = time.time()
        return float(now)

    @staticmethod
    def _high_water_mark(db):
        """The highest id ever handed out: AUTOINCREMENT's counter, which deleting rows never lowers."""
        row = db.execute("SELECT seq FROM sqlite_sequence WHERE name = 'events'").fetchone()
        sequence = int(row["seq"] or 0) if row is not None else 0
        newest = db.execute("SELECT MAX(id) AS newest FROM events").fetchone()["newest"]
        return max(sequence, int(newest or 0))

    def _drop_expired(self, now):
        """Deletes events past the retention window before a read (the PC may have been idle for
        days, with no append to prune them). A failure here only leaves them hidden."""
        cutoff = now - self._retention
        if self._db.execute("SELECT 1 FROM events WHERE ts < ? LIMIT 1", (cutoff,)).fetchone() is None:
            return
        try:
            with self._db:
                self._prune(self._db, now)
        except sqlite3.OperationalError:
            LOGGER.warning("Could not delete expired events; they stay hidden", exc_info=True)

    @staticmethod
    def _row(row):
        data = None
        if row["data"]:
            try:
                data = json.loads(row["data"])
            except ValueError:
                data = None
        return {"id": row["id"], "ts": iso_timestamp(row["ts"]), "kind": row["kind"], "level": row["level"],
                "title": row["title"], "body": row["body"], "data": data if isinstance(data, dict) else {}}

    def append(self, kind, title, body, level="active", data=None):
        """Stores one event and returns it exactly as `GET /api/events` shows it."""
        encoded = _validated(kind, level, data)
        title = _clean(title, TITLE_LIMIT) or kind
        body = _clean(body, BODY_LIMIT)
        with self._lock:
            if self._closed:
                raise RuntimeError("The event log is closed.")
            now = self._now()
            with self._db:
                cursor = self._db.execute(
                    "INSERT INTO events (ts, kind, level, title, body, data) VALUES (?, ?, ?, ?, ?, ?)",
                    (now, kind, level, title, body, encoded))
                identifier = cursor.lastrowid
                self._prune(self._db, now)
            row = self._db.execute("SELECT * FROM events WHERE id = ?", (identifier,)).fetchone()
        return self._row(row)

    def latest_id(self):
        """The highest id ever handed out (see the module docstring); 0 for a brand-new log."""
        with self._lock:
            if self._closed:
                raise RuntimeError("The event log is closed.")
            return self._high_water_mark(self._db)

    def page(self, since=None, limit=DEFAULT_PAGE):
        """`{"events", "latestID", "more"}`: events oldest first, after `since`, or the newest
        `limit` ones without it. `more` is true when events after the last one returned remain."""
        limit = max(1, min(MAX_PAGE, int(limit)))
        with self._lock:
            if self._closed:
                raise RuntimeError("The event log is closed.")
            now = self._now()
            self._drop_expired(now)
            cutoff = now - self._retention
            # The high-water mark is read first and bounds the rows, so "caught up to latestID"
            # holds even if another process appends between the two statements.
            latest = self._high_water_mark(self._db)
            if since is None:
                rows = self._db.execute(
                    "SELECT * FROM (SELECT * FROM events WHERE id <= ? AND ts >= ? ORDER BY id DESC LIMIT ?) "
                    "ORDER BY id ASC", (latest, cutoff, limit)).fetchall()
                more = False
            else:
                rows = self._db.execute(
                    "SELECT * FROM events WHERE id > ? AND id <= ? AND ts >= ? ORDER BY id ASC LIMIT ?",
                    (int(since), latest, cutoff, limit + 1)).fetchall()
                more = len(rows) > limit
                rows = rows[:limit]
        return {"events": [self._row(row) for row in rows], "latestID": latest, "more": more}

    def close(self):
        with self._lock:
            if not self._closed:
                self._closed = True
                self._db.close()


# The agent's current log (set during startup) and the dispatchers that forward events. --------

_LOG_LOCK = threading.Lock()
_LOG = None
_DISPATCHERS = []
_DISPATCH_LOCK = threading.Lock()
_DISPATCH_QUEUE = queue.Queue(maxsize=DISPATCH_QUEUE_SIZE)
_DISPATCH_THREAD = None
_MISSING_LOG_WARNED = False


def set_event_log(log):
    """Makes `log` the store `emit` writes to (None while the agent is not running)."""
    global _LOG, _MISSING_LOG_WARNED
    with _LOG_LOCK:
        _LOG = log
        _MISSING_LOG_WARNED = False


def current_log():
    with _LOG_LOCK:
        return _LOG


def register_dispatcher(dispatcher):
    """`dispatcher(event)` runs on the dispatch thread for every stored event. Exceptions are logged."""
    if not callable(dispatcher):
        raise TypeError("The dispatcher must be callable")
    with _DISPATCH_LOCK:
        if dispatcher not in _DISPATCHERS:
            _DISPATCHERS.append(dispatcher)


def unregister_dispatcher(dispatcher):
    with _DISPATCH_LOCK:
        if dispatcher in _DISPATCHERS:
            _DISPATCHERS.remove(dispatcher)


class _Barrier:
    def __init__(self):
        self.done = threading.Event()


def _dispatch_loop():
    while True:
        item = _DISPATCH_QUEUE.get()
        try:
            if isinstance(item, _Barrier):
                item.done.set()
                continue
            with _DISPATCH_LOCK:
                dispatchers = list(_DISPATCHERS)
            for dispatcher in dispatchers:
                try:
                    dispatcher(copy.deepcopy(item))
                except Exception:
                    LOGGER.exception("An event dispatcher failed for event %s", item.get("id"))
        finally:
            _DISPATCH_QUEUE.task_done()


def _ensure_dispatch_thread():
    global _DISPATCH_THREAD
    with _DISPATCH_LOCK:
        if _DISPATCH_THREAD is None or not _DISPATCH_THREAD.is_alive():
            _DISPATCH_THREAD = threading.Thread(target=_dispatch_loop, name="orbit-events-dispatch", daemon=True)
            _DISPATCH_THREAD.start()


def _queue_dispatch(event):
    with _DISPATCH_LOCK:
        if not _DISPATCHERS:
            return False
    _ensure_dispatch_thread()
    try:
        _DISPATCH_QUEUE.put_nowait(event)
        return True
    except queue.Full:
        LOGGER.warning("Event dispatch is backed up; event %s will reach phones by polling only", event.get("id"))
        return False


def flush_dispatch(timeout=5.0):
    """Waits until every event queued so far has been dispatched. Returns False on timeout."""
    with _DISPATCH_LOCK:
        running = _DISPATCH_THREAD is not None and _DISPATCH_THREAD.is_alive()
    if not running:
        return _DISPATCH_QUEUE.empty()
    barrier = _Barrier()
    try:
        _DISPATCH_QUEUE.put(barrier, timeout=timeout)
    except queue.Full:
        return False
    return barrier.done.wait(timeout)


def emit(kind, title, body, level="active", data=None, toast=True):
    """Records an event, shows a PC toast (when `toast` and the user's `pcToasts` allow it)
    and queues it for the dispatchers. Returns the event as the API shows it.

    Invalid kinds, levels or data are programming errors and raise ValueError. A storage failure
    is logged and does not raise: the toast is still shown, the event gets `id` None and is not
    dispatched (phones could not de-duplicate it against the log).
    """
    global _MISSING_LOG_WARNED
    _validated(kind, level, data)
    log = current_log()
    event = None
    if log is not None:
        try:
            event = log.append(kind, title, body, level=level, data=data)
        except (sqlite3.Error, OSError, RuntimeError):
            LOGGER.exception("Could not store the %s event", kind)
    else:
        if not _MISSING_LOG_WARNED:
            _MISSING_LOG_WARNED = True
            LOGGER.warning("The event log is not open; %s was not stored", kind)
    if event is None:
        event = {"id": None, "ts": iso_timestamp(time.time()), "kind": kind, "level": level,
                 "title": _clean(title, TITLE_LIMIT) or kind, "body": _clean(body, BODY_LIMIT), "data": data or {}}
    if toast:
        orbit_notify.notify(event["title"], event["body"])
    if event["id"] is not None:
        _queue_dispatch(copy.deepcopy(event))
    return event


def create_events_router(verify_control, log_provider=current_log):
    """`GET /api/events` behind the caller's token check and the encrypted connection."""
    def require_encrypted(request: Request, response: Response):
        if request.url.scheme != "https":
            raise HTTPException(426, "Notifications need Orbit's encrypted connection. Pair the PC again in Orbit to turn it on.")
        response.headers["Cache-Control"] = "no-store"

    router = APIRouter(prefix="/api", dependencies=[Depends(verify_control), Depends(require_encrypted)])

    @router.get("/events")
    def list_events(since: int | None = Query(default=None, ge=0, le=2 ** 62),
                    limit: int = Query(default=DEFAULT_PAGE, ge=1, le=MAX_PAGE)):
        log = log_provider()
        if log is None:
            raise HTTPException(503, "The PC's event history is not ready. Restart Orbit PC Companion.")
        try:
            return log.page(since=since, limit=limit)
        except (sqlite3.Error, RuntimeError) as error:
            raise HTTPException(503, "The PC could not read its event history. Try again in a moment.") from error

    return router
