"""Local, bounded telemetry history. Never records file names, clipboard or tokens.

Construct SessionRecorder during application startup, not at import time. The
recorder owns one session: a manual recording takes priority over automatic game
detection. Missing readings stay null and gaps receive separate chart segments.
"""

import json
import logging
import math
import os
from pathlib import Path
import sqlite3
import threading
import time
import uuid

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field


SAMPLE_INTERVAL = 5.0
GAP_SECONDS = 15.0
RETENTION_SECONDS = 30 * 24 * 60 * 60
MAX_SESSIONS = 100
MAX_DETAIL_SAMPLES = 2400
METRIC_LIMITS = {
    "cpuUsage": (0, 100), "gpuUsage": (0, 100),
    "cpuTemp": (-100, 200), "gpuTemp": (-100, 200),
    "fps": (0, 10000), "cpuPowerWatts": (0, 10000), "gpuPowerWatts": (0, 10000),
    "ramUsedGB": (0, 100000), "ramTotalGB": (0, 100000),
    "vramUsedGB": (0, 100000), "vramTotalGB": (0, 100000),
    "networkUploadMBps": (0, 1000000), "networkDownloadMBps": (0, 1000000),
}


def default_history_path():
    override = os.environ.get("ORBIT_HISTORY_FILE")
    if override:
        return Path(override).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "Orbit" / "history.sqlite3"


def _text(value, limit):
    if not isinstance(value, str):
        return None
    cleaned = " ".join(value.split())[:limit].strip()
    return cleaned or None


def _clean_metrics(metrics):
    result = {}
    available = metrics.get("telemetryAvailable") is not False
    for key, (low, high) in METRIC_LIMITS.items():
        value = metrics.get(key)
        valid = (available and isinstance(value, (int, float)) and not isinstance(value, bool)
                 and math.isfinite(value) and low <= value <= high)
        result[key] = round(float(value), 4) if valid else None
    result["telemetryAvailable"] = available
    return result


class SessionRecorder:
    """Thread-safe SQLite storage; callers provide current, non-demo telemetry."""

    def __init__(self, path=None, *, clock=time.time, sample_interval=SAMPLE_INTERVAL,
                 gap_seconds=GAP_SECONDS, retention_seconds=RETENTION_SECONDS,
                 max_sessions=MAX_SESSIONS):
        self.path = Path(path) if path is not None else default_history_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock
        self._sample_interval = max(0.1, sample_interval)
        self._gap_seconds = max(self._sample_interval, gap_seconds)
        self._retention_seconds = max(self._gap_seconds, retention_seconds)
        self._max_sessions = max(1, max_sessions)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(self.path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA foreign_keys = ON")
        self._db.execute("PRAGMA journal_mode = WAL")
        self._db.executescript("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, game_process TEXT,
                kind TEXT NOT NULL, status TEXT NOT NULL, started_at REAL NOT NULL,
                ended_at REAL, last_sample_at REAL
            );
            CREATE TABLE IF NOT EXISTS samples (
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                timestamp REAL NOT NULL, segment INTEGER NOT NULL, readings TEXT NOT NULL,
                PRIMARY KEY (session_id, timestamp)
            );
            CREATE INDEX IF NOT EXISTS samples_time ON samples(timestamp);
            CREATE INDEX IF NOT EXISTS sessions_start ON sessions(started_at DESC);
        """)
        # A killed agent must not turn hours offline into recorded play time.
        self._db.execute("""UPDATE sessions SET status = 'interrupted',
            ended_at = COALESCE(last_sample_at, started_at) WHERE status = 'recording'""")
        self._active_id = None
        self._active_kind = None
        self._active_game = None
        self._last_seen = None
        self._last_stored = None
        self._last_available = None
        self._segment = 0
        self._metric_segments = {key: 0 for key in METRIC_LIMITS}
        self._previous_readings = None
        self._observed_game = None
        self._suppressed_game = None
        self._aggregates = {}
        self._closed = False
        self._last_pruned = None
        self._prune(self._clock())
        self._db.commit()

    def _assert_open(self):
        if self._closed:
            raise RuntimeError("History recorder is closed.")

    def _prune(self, now):
        cutoff = now - self._retention_seconds
        self._db.execute("DELETE FROM samples WHERE timestamp < ?", (cutoff,))
        self._db.execute("DELETE FROM sessions WHERE status != 'recording' AND COALESCE(ended_at, started_at) < ?", (cutoff,))
        self._db.execute("""DELETE FROM sessions WHERE id IN
            (SELECT id FROM sessions WHERE status != 'recording' ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET ?)""",
                         (self._max_sessions - (1 if self._active_id else 0),))
        self._last_pruned = now
        self._aggregates.clear()

    def _begin(self, name, game, kind, now):
        session_id = str(uuid.uuid4())
        self._db.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, 'recording', ?, NULL, NULL)",
                         (session_id, name, game, kind, now))
        self._active_id = session_id
        self._active_kind = kind
        self._active_game = game
        self._last_seen = now
        self._last_stored = None
        self._last_available = None
        self._segment = 0
        self._metric_segments = {key: 0 for key in METRIC_LIMITS}
        self._previous_readings = None
        self._prune(now)
        return session_id

    def _finish(self, status="completed"):
        if self._active_id is None:
            return None
        session_id = self._active_id
        self._db.execute("UPDATE sessions SET status = ?, ended_at = COALESCE(?, started_at) WHERE id = ?",
                         (status, self._last_seen, session_id))
        self._active_id = None
        self._active_kind = None
        self._active_game = None
        self._last_seen = None
        self._last_stored = None
        self._last_available = None
        return session_id

    def start(self, name=None):
        with self._lock:
            self._assert_open()
            if self._active_kind == "manual":
                raise ValueError("A manual session is already recording. Stop it before starting another.")
            now = self._clock()
            self._finish()
            session_id = self._begin(_text(name, 100) or "PC session", None, "manual", now)
            self._db.commit()
            return self._summary(session_id)

    def stop(self):
        with self._lock:
            self._assert_open()
            # An explicit Stop should not immediately create another recording
            # of the same still-running game on the next telemetry tick.
            self._suppressed_game = self._observed_game
            session_id = self._finish()
            self._db.commit()
            return self._summary(session_id) if session_id else None

    def record_sample(self, metrics):
        """Consume an agent snapshot; throttle disk writes without blocking polling.

        A false telemetryAvailable records a gap, without ending a game simply
        because the source is temporarily unavailable. Auto sessions close only
        after a fresh sample reports a stopped or changed game.
        """
        if not isinstance(metrics, dict):
            return
        with self._lock:
            if self._closed:
                return
            now = self._clock()
            # Wall-clock adjustments must not corrupt sample ordering or duration.
            if self._last_seen is not None and now < self._last_seen:
                return
            available = metrics.get("telemetryAvailable") is not False
            game = _text(metrics.get("activeGameProcess"), 180) if available else None
            if available:
                self._observed_game = game
                if game != self._suppressed_game:
                    self._suppressed_game = None
                if game and game == self._suppressed_game:
                    game = None
            if self._active_kind != "manual" and available and game != self._active_game:
                self._finish()
                if game:
                    self._begin(_text(metrics.get("activeGame"), 100) or game, game, "auto", now)
            if self._active_id is None:
                # Also keep retention bounded when the PC stays idle for weeks.
                if self._last_pruned is None or now - self._last_pruned >= 3600:
                    self._prune(now)
                    self._db.commit()
                return
            previous_seen = self._last_seen
            self._last_seen = now
            availability_changed = self._last_available is not None and self._last_available != available
            if self._last_stored is not None and now - self._last_stored < self._sample_interval and not availability_changed:
                return
            new_segment = (previous_seen is not None and now - previous_seen > self._gap_seconds) or availability_changed
            if new_segment:
                self._segment += 1
            # One write per timestamp even if callers submit duplicate snapshots.
            readings = _clean_metrics(metrics)
            for key in METRIC_LIMITS:
                if new_segment or (self._previous_readings is not None and self._previous_readings.get(key) is None and readings.get(key) is not None):
                    self._metric_segments[key] += 1
            # Preserve per-sensor gaps even when the transport selects a reduced
            # set of actual readings and skips a null sample in the middle.
            readings["metricSegments"] = dict(self._metric_segments)
            cursor = self._db.execute("INSERT OR IGNORE INTO samples VALUES (?, ?, ?, ?)",
                                      (self._active_id, now, self._segment, json.dumps(readings, allow_nan=False)))
            if cursor.rowcount and self._active_id in self._aggregates:
                self._add_aggregate(self._aggregates[self._active_id], readings)
            self._db.execute("UPDATE sessions SET last_sample_at = ? WHERE id = ?", (now, self._active_id))
            self._last_stored = now
            self._last_available = available
            self._previous_readings = readings
            if self._last_pruned is None or now - self._last_pruned >= 3600:
                self._prune(now)
            self._db.commit()

    def _summary(self, session_id):
        row = self._db.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        if row is None:
            raise KeyError("Session not found.")
        # Only bounded numeric readings are stored. Aggregate full retained data;
        # detail downsampling never changes these averages and peaks.
        aggregate = self._aggregates.get(session_id)
        if aggregate is None:
            aggregate = {"sampleCount": 0, "metrics": {key: {"total": 0.0, "peak": None, "count": 0} for key in METRIC_LIMITS}}
            for sample in self._db.execute("SELECT readings FROM samples WHERE session_id = ?", (session_id,)):
                self._add_aggregate(aggregate, json.loads(sample["readings"]))
            self._aggregates[session_id] = aggregate
        statistics = {key: {"average": round(value["total"] / value["count"], 3) if value["count"] else None,
                            "peak": value["peak"], "count": value["count"]}
                      for key, value in aggregate["metrics"].items()}
        end = row["ended_at"] if row["ended_at"] is not None else row["last_sample_at"]
        return {"id": row["id"], "name": row["name"], "gameProcess": row["game_process"],
                "kind": row["kind"], "status": row["status"], "startedAt": row["started_at"],
                "endedAt": row["ended_at"], "durationSeconds": max(0, (end or row["started_at"]) - row["started_at"]),
                "sampleCount": aggregate["sampleCount"], "statistics": statistics}

    @staticmethod
    def _add_aggregate(aggregate, readings):
        aggregate["sampleCount"] += 1
        for key, statistic in aggregate["metrics"].items():
            value = readings.get(key)
            if value is not None:
                statistic["total"] += value
                statistic["count"] += 1
                statistic["peak"] = max(statistic["peak"], value) if statistic["peak"] is not None else value

    def sessions(self):
        with self._lock:
            self._assert_open()
            ids = [row[0] for row in self._db.execute("SELECT id FROM sessions ORDER BY started_at DESC, id DESC LIMIT ?", (self._max_sessions,))]
            summaries = [self._summary(session_id) for session_id in ids]
            return {"sessions": summaries, "activeSession": next((row for row in summaries if row["id"] == self._active_id), None)}

    def detail(self, session_id):
        with self._lock:
            self._assert_open()
            summary = self._summary(session_id)
            # Keep transport/rendering bounded. Actual points retain their segment
            # identifiers; summary averages and peaks use all stored samples.
            count = summary["sampleCount"]
            if count > MAX_DETAIL_SAMPLES:
                indices = {round(index * (count - 1) / (MAX_DETAIL_SAMPLES - 1)) for index in range(MAX_DETAIL_SAMPLES)}
                # Fetch at most 2400 rows instead of materializing up to 30 days
                # of 5-second samples in memory. The window uses an indexed scan.
                placeholders = ",".join("?" for _ in indices)
                rows = self._db.execute(f"""SELECT timestamp, segment, readings FROM
                    (SELECT timestamp, segment, readings, ROW_NUMBER() OVER (ORDER BY timestamp) - 1 AS row_index
                    FROM samples WHERE session_id = ?) WHERE row_index IN ({placeholders}) ORDER BY timestamp""",
                                        (session_id, *sorted(indices))).fetchall()
            else:
                rows = self._db.execute("SELECT timestamp, segment, readings FROM samples WHERE session_id = ? ORDER BY timestamp", (session_id,)).fetchall()
            samples = [{"timestamp": row["timestamp"], "segment": row["segment"], **json.loads(row["readings"])} for row in rows]
            reduced = downsample(samples)
            return {"session": summary, "samples": reduced, "downsampled": len(reduced) < count,
                    "sampleIntervalSeconds": self._sample_interval}

    def power_samples(self, session_id):
        """Every stored sample of a session, oldest first, with only what energy estimates need:
        `{"timestamp", "segment", "telemetryAvailable", "cpuPowerWatts", "gpuPowerWatts"}`."""
        with self._lock:
            self._assert_open()
            if self._db.execute("SELECT 1 FROM sessions WHERE id = ?", (session_id,)).fetchone() is None:
                raise KeyError("Session not found.")
            rows = self._db.execute("SELECT timestamp, segment, readings FROM samples WHERE session_id = ? ORDER BY timestamp",
                                    (session_id,)).fetchall()
        result = []
        for row in rows:
            try:
                readings = json.loads(row["readings"])
            except ValueError:
                continue
            result.append({"timestamp": row["timestamp"], "segment": row["segment"],
                           "telemetryAvailable": readings.get("telemetryAvailable") is not False,
                           "cpuPowerWatts": readings.get("cpuPowerWatts"), "gpuPowerWatts": readings.get("gpuPowerWatts")})
        return result

    def delete(self, session_id):
        with self._lock:
            self._assert_open()
            if session_id == self._active_id:
                raise ValueError("Stop this session before deleting it.")
            cursor = self._db.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
            if not cursor.rowcount:
                raise KeyError("Session not found.")
            self._aggregates.pop(session_id, None)
            self._db.commit()

    def close(self):
        with self._lock:
            if not self._closed:
                self._finish()
                self._db.commit()
                self._db.close()
                self._closed = True


def downsample(samples, limit=MAX_DETAIL_SAMPLES):
    """Bound chart payload with actual points; never interpolate across gaps."""
    if len(samples) <= limit:
        return samples
    if limit < 2:
        return samples[:max(limit, 0)]
    # Spread sample selections across the complete time range. Segment labels
    # remain attached to actual measurements, so missing chunks cannot join.
    indices = {round(index * (len(samples) - 1) / (limit - 1)) for index in range(limit)}
    return [samples[index] for index in sorted(indices)]


class StartSessionBody(BaseModel):
    name: str | None = Field(default=None, max_length=100)


def create_history_router(verify_control, recorder_provider, detail_extras=None):
    """All routes use the caller's existing control-token verification.

    `detail_extras(recorder, session_id)` may return more top-level keys for a session's detail
    (the electricity estimate, `"energy"`); when it fails the detail is answered without them.
    """
    router = APIRouter(prefix="/api/history", tags=["Session history"])

    def recorder(authorization, request):
        verify_control(authorization)
        if request.url.scheme != "https":
            raise HTTPException(426, "Session history requires Orbit's encrypted connection on secure port 8766.")
        result = recorder_provider()
        if result is None:
            raise HTTPException(503, "Session history is not ready. Restart Orbit Agent.")
        return result

    @router.get("/sessions")
    def list_sessions(request: Request, authorization: str = Header(None)):
        return recorder(authorization, request).sessions()

    @router.post("/start")
    def start_session(body: StartSessionBody, request: Request, authorization: str = Header(None)):
        try:
            return recorder(authorization, request).start(body.name)
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc

    @router.post("/stop")
    def stop_session(request: Request, authorization: str = Header(None)):
        return {"session": recorder(authorization, request).stop()}

    @router.get("/sessions/{session_id}")
    def session_detail(session_id: str, request: Request, authorization: str = Header(None)):
        active = recorder(authorization, request)
        try:
            result = active.detail(session_id)
        except KeyError as exc:
            raise HTTPException(404, "Session not found.") from exc
        if detail_extras is not None:
            try:
                extras = detail_extras(active, session_id)
                if isinstance(extras, dict):
                    result.update({key: value for key, value in extras.items() if key not in result})
            except Exception:
                logging.getLogger("orbit.history").exception("Could not add extras to session %s", session_id)
        return result

    @router.delete("/sessions/{session_id}")
    def delete_session(session_id: str, request: Request, authorization: str = Header(None)):
        try:
            recorder(authorization, request).delete(session_id)
        except KeyError as exc:
            raise HTTPException(404, "Session not found.") from exc
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc
        return {"deleted": True}

    return router
