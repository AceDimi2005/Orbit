"""History regressions use temporary SQLite files and synthetic metrics only."""

import importlib
import math
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

import orbit_history as history


class Clock:
    def __init__(self):
        self.now = 1700000000.0

    def __call__(self):
        return self.now


class SessionHistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "history.sqlite3"
        self.clock = Clock()
        self.recorder = history.SessionRecorder(self.path, clock=self.clock)

    def tearDown(self):
        self.recorder.close()
        self.directory.cleanup()

    def sample(self, delta=5, **metrics):
        self.clock.now += delta
        self.recorder.record_sample({"telemetryAvailable": True, **metrics})

    def test_import_does_not_create_history_file(self):
        other = Path(self.directory.name) / "not-created" / "history.sqlite3"
        with patch.dict("os.environ", {"ORBIT_HISTORY_FILE": str(other)}):
            importlib.reload(history)
        self.assertFalse(other.exists())

    def test_idle_pc_is_not_recorded_without_explicit_session(self):
        self.sample(cpuUsage=20)
        self.assertEqual(self.recorder.sessions(), {"sessions": [], "activeSession": None})

    def test_manual_recording_samples_every_five_seconds(self):
        started = self.recorder.start("Work")
        self.sample(delta=0, cpuUsage=10, fps=None)
        self.sample(delta=1, cpuUsage=99)
        self.sample(delta=4, cpuUsage=30, fps=120)
        stopped = self.recorder.stop()
        detail = self.recorder.detail(started["id"])
        self.assertEqual(detail["session"]["sampleCount"], 2)
        self.assertEqual(stopped["statistics"]["cpuUsage"], {"average": 20, "peak": 30, "count": 2})
        self.assertEqual(stopped["statistics"]["fps"]["average"], 120)
        self.assertEqual(stopped["durationSeconds"], 5)
        self.assertEqual(stopped["status"], "completed")

    def test_game_automatically_starts_changes_and_finishes(self):
        self.sample(activeGameProcess="game.exe", activeGame="Game", fps=60)
        first = self.recorder.sessions()["activeSession"]
        self.assertEqual((first["name"], first["kind"]), ("Game", "auto"))
        self.sample(activeGameProcess="other.exe", fps=100)
        active = self.recorder.sessions()["activeSession"]
        self.assertEqual(active["gameProcess"], "other.exe")
        self.sample()
        self.assertIsNone(self.recorder.sessions()["activeSession"])
        self.assertEqual(len(self.recorder.sessions()["sessions"]), 2)

    def test_stop_does_not_immediately_restart_same_game(self):
        self.sample(activeGameProcess="game.exe")
        self.recorder.stop()
        self.sample(activeGameProcess="game.exe")
        self.assertIsNone(self.recorder.sessions()["activeSession"])
        self.sample()
        self.sample(activeGameProcess="game.exe")
        self.assertIsNotNone(self.recorder.sessions()["activeSession"])

    def test_manual_session_overrides_auto_and_rejects_duplicate_manual_start(self):
        self.sample(activeGameProcess="game.exe")
        manual = self.recorder.start("My recording")
        self.sample(activeGameProcess="new-game.exe")
        self.assertEqual(self.recorder.sessions()["activeSession"]["id"], manual["id"])
        with self.assertRaises(ValueError):
            self.recorder.start("Duplicate")

    def test_missing_invalid_and_nonfinite_sensors_remain_null(self):
        session = self.recorder.start()
        self.sample(cpuUsage=True, cpuTemp=math.nan, gpuTemp=math.inf, fps=-10,
                    gpuUsage=300, cpuPowerWatts=0, gpuPowerWatts=85, networkUploadMBps=0.0001)
        sample = self.recorder.detail(session["id"])["samples"][0]
        for metric in ("cpuUsage", "cpuTemp", "gpuTemp", "fps", "gpuUsage", "ramUsedGB"):
            self.assertIsNone(sample[metric])
        self.assertEqual(sample["cpuPowerWatts"], 0)
        self.assertEqual(sample["networkUploadMBps"], 0.0001)

    def test_unavailable_telemetry_is_a_gap_and_does_not_end_game(self):
        self.sample(activeGameProcess="game.exe", cpuTemp=60)
        session = self.recorder.sessions()["activeSession"]
        self.sample(delta=1, telemetryAvailable=False, cpuTemp=0)
        self.sample(delta=1, activeGameProcess="game.exe", cpuTemp=62)
        detail = self.recorder.detail(session["id"])
        self.assertEqual([row["segment"] for row in detail["samples"]], [0, 1, 2])
        self.assertIsNone(detail["samples"][1]["cpuTemp"])
        self.assertEqual(detail["session"]["statistics"]["cpuTemp"]["count"], 2)
        self.assertEqual(detail["session"]["status"], "recording")

    def test_long_gap_creates_new_chart_segment(self):
        session = self.recorder.start()
        self.sample(cpuUsage=10)
        self.sample(delta=80, cpuUsage=20)
        self.assertEqual([row["segment"] for row in self.recorder.detail(session["id"])["samples"]], [0, 1])

    def test_reduced_payload_preserves_each_sensor_gap(self):
        session = self.recorder.start()
        self.sample(cpuUsage=10, cpuTemp=50)
        self.sample(cpuUsage=20, cpuTemp=None)
        self.sample(cpuUsage=30, cpuTemp=60)
        with patch.object(history, "MAX_DETAIL_SAMPLES", 2):
            points = self.recorder.detail(session["id"])["samples"]
        self.assertEqual(points[0]["metricSegments"]["cpuUsage"], points[1]["metricSegments"]["cpuUsage"])
        self.assertNotEqual(points[0]["metricSegments"]["cpuTemp"], points[1]["metricSegments"]["cpuTemp"])

    def test_backward_wall_clock_does_not_reorder_or_inflate_history(self):
        session = self.recorder.start()
        self.sample(cpuUsage=10)
        self.sample(delta=-100, cpuUsage=20)
        detail = self.recorder.detail(session["id"])
        self.assertEqual(detail["session"]["sampleCount"], 1)
        self.assertEqual(detail["session"]["durationSeconds"], 5)

    def test_restart_marks_open_session_interrupted_at_last_real_sample(self):
        self.sample(activeGameProcess="game.exe", fps=70)
        first = self.recorder.sessions()["activeSession"]
        self.sample(fps=80, activeGameProcess="game.exe")
        # Simulate abrupt exit rather than calling the graceful close method.
        self.recorder._db.close()
        self.recorder._closed = True
        self.clock.now += 86400
        reopened = history.SessionRecorder(self.path, clock=self.clock)
        try:
            previous = reopened.detail(first["id"])["session"]
            self.assertEqual(previous["status"], "interrupted")
            self.assertEqual(previous["durationSeconds"], 5)
            self.assertEqual(previous["statistics"]["fps"]["average"], 75)
        finally:
            reopened.close()

    def test_retention_and_count_are_bounded(self):
        self.recorder.close()
        self.recorder = history.SessionRecorder(self.path, clock=self.clock, max_sessions=3, retention_seconds=100)
        oldest_id = None
        for index in range(6):
            current = self.recorder.start(f"Session {index}")
            if index == 0:
                oldest_id = current["id"]
            self.sample(cpuUsage=index)
            self.recorder.stop()
        self.assertEqual(len(self.recorder.sessions()["sessions"]), 3)
        with self.assertRaises(KeyError):
            self.recorder.detail(oldest_id)
        self.sample(delta=4000)
        self.assertEqual(self.recorder.sessions()["sessions"], [])

    def test_delete_removes_samples_and_protects_active_recording(self):
        session = self.recorder.start()
        self.sample(cpuUsage=15)
        with self.assertRaises(ValueError):
            self.recorder.delete(session["id"])
        self.recorder.stop()
        self.recorder.delete(session["id"])
        self.assertEqual(self.recorder._db.execute("SELECT COUNT(*) FROM samples").fetchone()[0], 0)
        with self.assertRaises(KeyError):
            self.recorder.delete(session["id"])

    def test_transport_is_bounded_and_never_changes_aggregates(self):
        session = self.recorder.start()
        for index in range(31):
            self.sample(cpuUsage=index)
        with patch.object(history, "MAX_DETAIL_SAMPLES", 8):
            detail = self.recorder.detail(session["id"])
        self.assertEqual(len(detail["samples"]), 8)
        self.assertTrue(detail["downsampled"])
        self.assertEqual(detail["session"]["statistics"]["cpuUsage"]["average"], 15)
        self.assertEqual(detail["samples"][0]["cpuUsage"], 0)
        self.assertEqual(detail["samples"][-1]["cpuUsage"], 30)

    def test_no_extra_metadata_or_secrets_are_persisted(self):
        session = self.recorder.start()
        self.sample(cpuUsage=20, token="secret-token", clipboard="secret-clipboard", file="secret-file")
        self.recorder.stop()
        detail_text = str(self.recorder.detail(session["id"]))
        self.assertNotIn("secret-", detail_text)
        for row in self.recorder._db.execute("SELECT readings FROM samples"):
            self.assertNotIn("secret-", row[0])

    def test_concurrent_reads_and_writes_are_consistent(self):
        self.recorder.start()
        errors = []
        def read():
            try:
                for _ in range(10):
                    self.recorder.sessions()
            except Exception as exc:
                errors.append(exc)
        thread = threading.Thread(target=read)
        thread.start()
        for _ in range(10):
            self.sample(cpuUsage=15)
        thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(self.recorder.sessions()["activeSession"]["sampleCount"], 10)


class HistoryAPITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.recorder = history.SessionRecorder(Path(self.directory.name) / "history.sqlite3", clock=self.clock)
        def verify(value):
            if value != "Bearer control-token":
                raise HTTPException(401, "Unauthorized")
        app = FastAPI()
        app.include_router(history.create_history_router(verify, lambda: self.recorder))
        self.client = TestClient(app, base_url="https://testserver")
        self.headers = {"Authorization": "Bearer control-token"}

    def tearDown(self):
        self.recorder.close()
        self.directory.cleanup()

    def test_all_routes_require_control_token(self):
        for method, path, body in [("GET", "/sessions", None), ("POST", "/start", {}),
                                   ("POST", "/stop", None), ("GET", "/sessions/missing", None),
                                   ("DELETE", "/sessions/missing", None)]:
            for headers in ({}, {"Authorization": "Bearer widget-token"}):
                response = self.client.request(method, "/api/history" + path, headers=headers, json=body)
                self.assertEqual(response.status_code, 401, (method, path))

    def test_manual_session_roundtrip_and_conflicts(self):
        response = self.client.post("/api/history/start", headers=self.headers, json={"name": "Desktop"})
        self.assertEqual(response.status_code, 200)
        session_id = response.json()["id"]
        self.assertEqual(self.client.post("/api/history/start", headers=self.headers, json={}).status_code, 409)
        self.assertEqual(self.client.delete(f"/api/history/sessions/{session_id}", headers=self.headers).status_code, 409)
        self.recorder.record_sample({"cpuTemp": 55})
        self.assertEqual(self.client.get("/api/history/sessions", headers=self.headers).json()["activeSession"]["id"], session_id)
        self.assertEqual(self.client.get(f"/api/history/sessions/{session_id}", headers=self.headers).json()["samples"][0]["cpuTemp"], 55)
        self.assertEqual(self.client.post("/api/history/stop", headers=self.headers).json()["session"]["status"], "completed")
        self.assertEqual(self.client.delete(f"/api/history/sessions/{session_id}", headers=self.headers).json(), {"deleted": True})
        self.assertEqual(self.client.get(f"/api/history/sessions/{session_id}", headers=self.headers).status_code, 404)

    def test_uninitialized_recorder_returns_503_after_authentication(self):
        app = FastAPI()
        def verify(value):
            if value != "Bearer control-token":
                raise HTTPException(401, "Unauthorized")
        app.include_router(history.create_history_router(verify, lambda: None))
        client = TestClient(app, base_url="https://testserver")
        self.assertEqual(client.get("/api/history/sessions", headers=self.headers).status_code, 503)
        self.assertEqual(client.get("/api/history/sessions").status_code, 401)

    def test_cleartext_history_is_rejected_after_authentication(self):
        self.assertEqual(self.client.get("http://testserver/api/history/sessions", headers=self.headers).status_code, 426)
        self.assertEqual(self.client.get("http://testserver/api/history/sessions").status_code, 401)

    def test_start_name_is_bounded(self):
        self.assertEqual(self.client.post("/api/history/start", headers=self.headers, json={"name": "x" * 101}).status_code, 422)


if __name__ == "__main__":
    unittest.main()
