"""Event log: storage, retention, paging, emit (toast + dispatch) and GET /api/events."""
import contextlib
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_events as events

DAY = 24 * 60 * 60
START = datetime(2026, 10, 23, 18, 0, 0, tzinfo=timezone.utc).timestamp()


class Clock:
    def __init__(self, now=START):
        self.now = now

    def __call__(self):
        return self.now


class EventLogTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "Orbit" / "events.sqlite3"
        self.clock = Clock()

    def open(self, **options):
        log = events.EventLog(self.path, clock=self.clock, **options)
        self.addCleanup(log.close)
        return log

    def database(self):
        """A separate connection to the log file that is closed afterwards (sqlite3's own context
        manager only commits)."""
        return contextlib.closing(sqlite3.connect(self.path))

    def stored_titles(self):
        with self.database() as db:
            return [row[0] for row in db.execute("SELECT title FROM events ORDER BY id")]

    def test_append_returns_the_api_shape_with_iso_utc_time(self):
        log = self.open()
        event = log.append("download.finished", "Portal 2 finished downloading", "Ready to play.", data={"id": "steam:620"})
        self.assertEqual(event, {"id": 1, "ts": "2026-10-23T18:00:00Z", "kind": "download.finished", "level": "active",
                                 "title": "Portal 2 finished downloading", "body": "Ready to play.",
                                 "data": {"id": "steam:620"}})
        self.assertEqual(events.event_epoch(event), START)
        second = log.append("pc.online", "PC is online", "", level="passive")
        self.assertEqual((second["id"], second["data"], second["body"]), (2, {}, ""))
        self.assertEqual(log.latest_id(), 2)

    def test_schema_matches_the_design(self):
        self.open().append("pc.online", "Online", "")
        with self.database() as db:
            columns = [(row[1], row[2], row[5]) for row in db.execute("PRAGMA table_info(events)")]
            sql = db.execute("SELECT sql FROM sqlite_master WHERE name = 'events'").fetchone()[0]
        self.assertEqual(columns, [("id", "INTEGER", 1), ("ts", "REAL", 0), ("kind", "TEXT", 0), ("level", "TEXT", 0),
                                   ("title", "TEXT", 0), ("body", "TEXT", 0), ("data", "TEXT", 0)])
        self.assertIn("AUTOINCREMENT", sql)

    def test_text_is_cleaned_and_bounded(self):
        log = self.open()
        event = log.append("temperature.high", "  CPU\nis hot\x00 ", "B" * 2000, level="timeSensitive")
        self.assertEqual(event["title"], "CPU is hot")
        self.assertEqual(len(event["body"]), events.BODY_LIMIT)
        self.assertEqual(event["level"], "timeSensitive")
        self.assertEqual(log.append("summary.ready", "", "", level="passive")["title"], "summary.ready")
        # A lone surrogate (possible in Windows file names) cannot be stored as UTF-8: it is replaced.
        odd = log.append("download.finished", "Saved photo\udc80.jpg", "\U0001F3AE" * 400)
        self.assertEqual(odd["title"], "Saved photo\ufffd.jpg")
        self.assertLessEqual(len(odd["body"].encode("utf-16-le")) // 2, events.BODY_LIMIT)
        self.assertEqual(log.page()["events"][-1], odd)

    def test_invalid_kind_level_and_data_are_programming_errors(self):
        log = self.open()
        for kind in ("", "online", "PC.online", "pc..online", "pc.online.", "pc online", None, 5, "a." + "b" * 40):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                log.append(kind, "t", "b")
        for level in ("urgent", "", None, "Active"):
            with self.subTest(level=level), self.assertRaises(ValueError):
                log.append("pc.online", "t", "b", level=level)
        for data in ([1, 2], "text", {"nan": float("nan")}, {"big": "x" * events.MAX_DATA_BYTES}):
            with self.subTest(data=str(data)[:30]), self.assertRaises(ValueError):
                log.append("pc.online", "t", "b", data=data)
        with self.assertRaises(TypeError):
            log.append("pc.online", "t", "b", data={"object": object()})
        self.assertEqual(log.latest_id(), 0)
        for kind in events.EVENT_KINDS:
            with self.subTest(kind=kind):
                log.append(kind, "t", "b")

    def test_events_older_than_seven_days_are_removed_and_never_listed(self):
        log = self.open()
        log.append("pc.online", "old", "")
        self.clock.now += 6 * DAY
        log.append("pc.online", "recent", "")
        self.clock.now += DAY + 1
        # The first event is now just over 7 days old: a read deletes it before listing.
        self.assertEqual(self.stored_titles(), ["old", "recent"])
        self.assertEqual([event["title"] for event in log.page()["events"]], ["recent"])
        self.assertEqual(self.stored_titles(), ["recent"])
        log.append("pc.online", "new", "")
        self.assertEqual(self.stored_titles(), ["recent", "new"])
        self.assertEqual(log.page(since=0)["latestID"], 3)

    def test_at_most_1000_events_are_kept_and_ids_keep_growing(self):
        log = self.open()
        for index in range(1005):
            log.append("task.finished", f"Task {index}", "")
        with self.database() as db:
            count, low, high = db.execute("SELECT COUNT(*), MIN(id), MAX(id) FROM events").fetchone()
        self.assertEqual((count, low, high), (1000, 6, 1005))
        # Ids are never reused, even after old rows are deleted (AUTOINCREMENT).
        self.assertEqual(log.append("task.finished", "next", "")["id"], 1006)

    def test_smaller_limits_for_tests_and_reopening_prunes(self):
        log = self.open(max_events=3)
        for index in range(5):
            log.append("pc.online", str(index), "")
        self.assertEqual([event["title"] for event in log.page()["events"]], ["2", "3", "4"])
        log.close()
        self.clock.now += 8 * DAY
        reopened = self.open()
        self.assertEqual(self.stored_titles(), [])
        # Every event expired while the agent was off, but latestID stays at the highest id handed
        # out: a client that remembers since=5 must not mistake this for a reset log.
        self.assertEqual(reopened.page(), {"events": [], "latestID": 5, "more": False})
        self.assertEqual(reopened.page(since=5), {"events": [], "latestID": 5, "more": False})
        self.assertEqual(reopened.latest_id(), 5)
        self.assertEqual(reopened.append("pc.online", "after", "")["id"], 6)
        self.assertEqual(reopened.page(since=5)["events"][0]["title"], "after")

    def test_paging_newest_without_since_and_forward_with_since(self):
        log = self.open()
        for index in range(1, 11):
            self.clock.now = START + index
            log.append("download.finished", f"Game {index}", "")
        newest = log.page(limit=3)
        self.assertEqual([event["id"] for event in newest["events"]], [8, 9, 10])
        self.assertEqual((newest["latestID"], newest["more"]), (10, False))
        first = log.page(since=0, limit=4)
        self.assertEqual([event["id"] for event in first["events"]], [1, 2, 3, 4])
        self.assertEqual((first["latestID"], first["more"]), (10, True))
        second = log.page(since=first["events"][-1]["id"], limit=4)
        self.assertEqual([event["id"] for event in second["events"]], [5, 6, 7, 8])
        self.assertTrue(second["more"])
        last = log.page(since=8, limit=4)
        self.assertEqual([event["id"] for event in last["events"]], [9, 10])
        self.assertFalse(last["more"])
        # A full page that happens to end at the newest event says there is nothing more.
        exact = log.page(since=6, limit=4)
        self.assertEqual(([event["id"] for event in exact["events"]], exact["more"]), ([7, 8, 9, 10], False))
        self.assertEqual(log.page(since=10), {"events": [], "latestID": 10, "more": False})
        # latestID below the client's since: this log was recreated, the client starts again from 0.
        self.assertEqual(log.page(since=500), {"events": [], "latestID": 10, "more": False})
        self.assertEqual(len(log.page(limit=1000)["events"]), 10)
        self.assertEqual(len(log.page(limit=0)["events"]), 1)
        self.assertEqual(log.page(limit=2)["events"][0]["ts"], "2026-10-23T18:00:09Z")

    def follow_the_documented_rule(self, log, since, limit):
        """What a phone does: page while `more`, then remember `latestID`. Returns (ids, since)."""
        received = []
        for _ in range(100):
            page = log.page(since=since, limit=limit)
            received += [event["id"] for event in page["events"]]
            if page["more"]:
                since = page["events"][-1]["id"]
                continue
            return received, page["latestID"]
        self.fail("The client never caught up")

    def test_events_that_expire_while_the_pc_is_idle_do_not_trap_a_polling_client(self):
        log = self.open()
        for index in range(1, 11):
            log.append("download.finished", f"Game {index}", "")
        self.clock.now += 8 * DAY  # no append for 8 days: nothing pruned them yet
        page = log.page(since=5)
        self.assertEqual(page, {"events": [], "latestID": 10, "more": False})
        self.assertEqual(self.stored_titles(), [])  # the read deleted them
        self.assertEqual(self.follow_the_documented_rule(log, 5, 2), ([], 10))
        self.assertEqual(log.append("pc.online", "back", "")["id"], 11)
        self.assertEqual(self.follow_the_documented_rule(log, 10, 2), ([11], 11))

    def test_a_client_following_the_rule_gets_every_event_once(self):
        log = self.open()
        for index in range(1, 8):
            self.clock.now = START + index * DAY / 4
            log.append("task.finished", f"Task {index}", "")
        self.clock.now = START + 7.6 * DAY  # events 1 and 2 have expired, 3..7 have not
        self.assertEqual(self.follow_the_documented_rule(log, 0, 2), ([3, 4, 5, 6, 7], 7))
        self.assertEqual(self.follow_the_documented_rule(log, 7, 2), ([], 7))
        for limit in (1, 3, 5, 200):
            with self.subTest(limit=limit):
                self.assertEqual(self.follow_the_documented_rule(log, 0, limit), ([3, 4, 5, 6, 7], 7))

    def test_rows_never_go_past_the_latest_id_reported_with_them(self):
        log = self.open()
        for index in range(10):
            log.append("pc.online", str(index), "")
        # As if another process appended 8..10 between reading the high-water mark and the rows.
        with patch.object(events.EventLog, "_high_water_mark", return_value=7):
            page = log.page(since=0, limit=200)
            newest = log.page(limit=200)
        self.assertEqual(([event["id"] for event in page["events"]], page["latestID"], page["more"]),
                         (list(range(1, 8)), 7, False))
        self.assertEqual([event["id"] for event in newest["events"]][-1], 7)

    def test_failing_to_delete_expired_events_still_hides_them(self):
        log = self.open()
        log.append("pc.online", "old", "")
        self.clock.now += 8 * DAY
        with patch.object(log, "_prune", side_effect=sqlite3.OperationalError("disk full")), \
             self.assertLogs("orbit.events", "WARNING"):
            self.assertEqual(log.page(since=0), {"events": [], "latestID": 1, "more": False})
        self.assertEqual(self.stored_titles(), ["old"])
        self.assertEqual(log.page(), {"events": [], "latestID": 1, "more": False})
        self.assertEqual(self.stored_titles(), [])

    def test_reads_without_expired_events_do_not_write(self):
        log = self.open()
        log.append("pc.online", "fresh", "")
        with patch.object(log, "_prune") as prune:
            log.page()
            log.page(since=0)
        prune.assert_not_called()

    def test_concurrent_appends_get_unique_increasing_ids(self):
        log = self.open()
        ids = []
        lock = threading.Lock()

        def worker():
            for _ in range(50):
                event = log.append("download.finished", "x", "")
                with lock:
                    ids.append(event["id"])
        threads = [threading.Thread(target=worker) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        self.assertEqual(sorted(ids), list(range(1, 301)))

    def test_damaged_database_is_set_aside_and_a_new_log_starts(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b"this is not a database" * 100)
        with self.assertLogs("orbit.events", "WARNING"):
            log = self.open()
        self.assertEqual(log.latest_id(), 0)  # below any since a client remembers: it starts again
        self.assertEqual(log.append("pc.online", "fresh", "")["id"], 1)
        self.assertTrue(self.path.with_name("events.sqlite3.corrupt").exists())

    def test_closed_log_refuses_work(self):
        log = self.open()
        log.close()
        log.close()
        with self.assertRaises(RuntimeError):
            log.append("pc.online", "t", "")
        with self.assertRaises(RuntimeError):
            log.page()
        with self.assertRaises(RuntimeError):
            log.latest_id()


class EmitTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.clock = Clock()
        self.log = events.EventLog(Path(folder.name) / "events.sqlite3", clock=self.clock)
        self.addCleanup(self.log.close)
        events.set_event_log(self.log)
        self.addCleanup(events.set_event_log, None)
        toast = patch.object(events.orbit_notify, "notify", return_value=True)
        self.toast = toast.start()
        self.addCleanup(toast.stop)

    def test_emit_stores_toasts_and_returns_the_event(self):
        event = events.emit("download.finished", "Portal 2 finished downloading", "Ready to play.", data={"id": "steam:620"})
        self.assertEqual(event["id"], 1)
        self.assertEqual(self.log.page()["events"], [event])
        self.toast.assert_called_once_with("Portal 2 finished downloading", "Ready to play.")

    def test_toast_can_be_skipped(self):
        events.emit("summary.ready", "Your October summary is ready", "", level="passive", toast=False)
        self.toast.assert_not_called()
        self.assertEqual(self.log.latest_id(), 1)

    def test_dispatchers_run_off_the_calling_thread_and_failures_are_contained(self):
        received = []
        threads = []

        def push(event):
            threads.append(threading.current_thread().name)
            received.append(event)

        def broken(event):
            raise RuntimeError("relay unreachable")
        events.register_dispatcher(broken)
        events.register_dispatcher(push)
        events.register_dispatcher(push)  # registering twice does not double-deliver
        self.addCleanup(events.unregister_dispatcher, push)
        self.addCleanup(events.unregister_dispatcher, broken)
        with self.assertLogs("orbit.events", "ERROR"):
            first = events.emit("temperature.high", "CPU at 95 °C", "For 30 seconds.", level="timeSensitive")
            second = events.emit("pc.online", "PC is online", "")
            self.assertTrue(events.flush_dispatch(5))
        self.assertEqual(received, [first, second])
        self.assertEqual(set(threads), {"orbit-events-dispatch"})
        received[0]["title"] = "changed"
        self.assertEqual(first["title"], "CPU at 95 °C")  # dispatchers get their own copy

    def test_slow_dispatcher_does_not_block_emit(self):
        gate = threading.Event()
        events.register_dispatcher(lambda event: gate.wait(5))
        self.addCleanup(lambda: [events.unregister_dispatcher(d) for d in list(events._DISPATCHERS)])
        started = threading.Event()

        def emitter():
            for _ in range(3):
                events.emit("download.finished", "x", "")
            started.set()
        thread = threading.Thread(target=emitter)
        thread.start()
        self.assertTrue(started.wait(2))
        gate.set()
        self.assertTrue(events.flush_dispatch(5))
        thread.join(5)

    def test_full_dispatch_queue_drops_only_the_push(self):
        events.register_dispatcher(lambda event: None)
        self.addCleanup(lambda: [events.unregister_dispatcher(d) for d in list(events._DISPATCHERS)])
        with patch.object(events._DISPATCH_QUEUE, "put_nowait", side_effect=events.queue.Full), \
             self.assertLogs("orbit.events", "WARNING"):
            event = events.emit("download.failed", "Download failed", "Disk full")
        self.assertEqual(self.log.page()["events"][-1]["id"], event["id"])

    def test_storage_failure_still_toasts_but_does_not_dispatch(self):
        dispatched = []
        events.register_dispatcher(dispatched.append)
        self.addCleanup(events.unregister_dispatcher, dispatched.append)
        broken = MagicMock()
        broken.append.side_effect = sqlite3.OperationalError("disk I/O error")
        events.set_event_log(broken)
        with self.assertLogs("orbit.events", "ERROR"):
            event = events.emit("task.finished", "Export finished", "Premiere Pro is idle.")
        self.assertIsNone(event["id"])
        self.assertEqual(event["kind"], "task.finished")
        self.toast.assert_called_once_with("Export finished", "Premiere Pro is idle.")
        events.flush_dispatch(5)
        self.assertEqual(dispatched, [])

    def test_without_a_log_emit_warns_once_and_still_toasts(self):
        events.set_event_log(None)
        with self.assertLogs("orbit.events", "WARNING") as logged:
            events.emit("pc.online", "Online", "")
            events.emit("pc.online", "Online", "")
        self.assertEqual(len(logged.output), 1)
        self.assertEqual(self.toast.call_count, 2)

    def test_invalid_events_raise_before_anything_happens(self):
        with self.assertRaises(ValueError):
            events.emit("bad kind", "t", "b")
        with self.assertRaises(ValueError):
            events.emit("pc.online", "t", "b", level="loud")
        self.toast.assert_not_called()
        self.assertEqual(self.log.latest_id(), 0)


def authorized(request: Request):
    if request.headers.get("authorization") != "Bearer control":
        raise HTTPException(401, "Control token required")


class EventsRouteTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.clock = Clock()
        self.log = events.EventLog(Path(folder.name) / "events.sqlite3", clock=self.clock)
        self.addCleanup(self.log.close)
        self.current = self.log
        app = FastAPI()
        app.include_router(events.create_events_router(authorized, lambda: self.current))
        self.client = TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})
        self.addCleanup(self.client.close)

    def test_requires_token_and_https(self):
        self.assertEqual(self.client.get("/api/events", headers={"Authorization": "Bearer readonly"}).status_code, 401)
        self.assertEqual(self.client.get("http://test/api/events").status_code, 426)

    def test_lists_events_with_paging_and_no_store(self):
        for index in range(5):
            self.log.append("download.finished", f"Game {index}", "Done", data={"index": index})
        response = self.client.get("/api/events", params={"limit": 2})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        body = response.json()
        self.assertEqual(set(body), {"events", "latestID", "more"})
        self.assertEqual((body["latestID"], body["more"]), (5, False))
        self.assertEqual([event["id"] for event in body["events"]], [4, 5])
        self.assertEqual(body["events"][0], {"id": 4, "ts": "2026-10-23T18:00:00Z", "kind": "download.finished",
                                             "level": "active", "title": "Game 3", "body": "Done", "data": {"index": 3}})
        response = self.client.get("/api/events", params={"since": 2, "limit": 200})
        self.assertEqual([event["id"] for event in response.json()["events"]], [3, 4, 5])
        self.assertFalse(response.json()["more"])
        response = self.client.get("/api/events", params={"since": 1, "limit": 2})
        self.assertEqual(([event["id"] for event in response.json()["events"]], response.json()["more"]), ([2, 3], True))
        self.assertEqual(self.client.get("/api/events").json()["latestID"], 5)

    def test_parameter_bounds(self):
        for params in ({"limit": 0}, {"limit": 201}, {"since": -1}, {"limit": "many"}, {"since": "x"}):
            with self.subTest(params=params):
                self.assertEqual(self.client.get("/api/events", params=params).status_code, 422)
        self.assertEqual(self.client.get("/api/events", params={"limit": 200, "since": 0}).status_code, 200)

    def test_unavailable_log_is_503(self):
        self.current = None
        self.assertEqual(self.client.get("/api/events").status_code, 503)
        self.current = MagicMock()
        self.current.page.side_effect = sqlite3.OperationalError("locked")
        self.assertEqual(self.client.get("/api/events").status_code, 503)


if __name__ == "__main__":
    unittest.main()
