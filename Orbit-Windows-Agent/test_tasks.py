"""Watched programs: exit and idle modes, process-tree CPU, PID reuse, the route. No real process is touched."""
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient
import psutil

import orbit_tasks as tasks

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
START = 1_790_000_000.0


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class FakeTable:
    """Pretend processes: pid -> {name, created, cpu seconds, children pids}. `advance` moves both
    clocks and adds CPU time at each process's current rate (% of the whole 4-core machine)."""

    def __init__(self):
        self.wall = Clock(START)
        self.mono = Clock(500.0)
        self.rows = {}
        self.cores = 4

    def add(self, pid, name, rate=0.0, parent=None, created=None):
        self.rows[pid] = {"name": name, "created": created if created is not None else self.wall.now - 100,
                          "cpu": 0.0, "rate": rate, "parent": parent}

    def advance(self, seconds):
        for row in self.rows.values():
            row["cpu"] += row["rate"] / 100.0 * self.cores * seconds
        self.wall.now += seconds
        self.mono.now += seconds

    def process(self, pid):
        if pid not in self.rows:
            raise psutil.NoSuchProcess(pid)
        return FakeProcess(self, pid, self.rows[pid]["created"])


class FakeProcess:
    def __init__(self, table, pid, created):
        self.table, self.pid, self._created = table, pid, created

    def _row(self):
        row = self.table.rows.get(self.pid)
        if row is None or row["created"] != self._created:
            raise psutil.NoSuchProcess(self.pid)
        return row

    def create_time(self):
        return self._row()["created"]

    def status(self):
        self._row()
        return psutil.STATUS_RUNNING

    def name(self):
        return self._row()["name"]

    def cpu_times(self):
        total = self._row()["cpu"]
        return SimpleNamespace(user=total * 0.8, system=total * 0.2)

    def children(self, recursive=False):
        self._row()
        result, frontier = [], [self.pid]
        while frontier:
            current = frontier.pop()
            for pid, row in self.table.rows.items():
                if row["parent"] == current:
                    result.append(FakeProcess(self.table, pid, row["created"]))
                    if recursive:
                        frontier.append(pid)
        return result


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.table = FakeTable()
        self.emit = MagicMock(side_effect=lambda kind, title, body, **kwargs: {"kind": kind, "title": title, "body": body, **kwargs})
        self.watcher = tasks.TaskWatcher(clock=self.table.wall, monotonic=self.table.mono, process=self.table.process,
                                         cpu_count=lambda: self.table.cores, emit=self.emit)
        self.heard = []
        self.watcher.add_listener(lambda kind, task: self.heard.append((kind, task["state"], task["reason"])))

    def run_for(self, seconds, step=2.0):
        ended = []
        elapsed = 0.0
        while elapsed < seconds:
            self.table.advance(step)
            elapsed += step
            ended.extend(self.watcher.poll())
        return ended

    def test_exit_mode_finishes_when_the_process_exits(self):
        self.table.add(4242, "Blender.exe", rate=50)
        task = self.watcher.add({"pid": 4242, "createTime": self.table.rows[4242]["created"], "mode": "exit"})
        self.assertEqual((task["state"], task["label"], task["name"], task["mode"], task["idleMinutes"]),
                         ("watching", "Blender", "Blender.exe", "exit", None))
        self.assertEqual(task["startedAt"], "2026-09-21T14:13:20Z")
        self.assertEqual(self.run_for(10), [])
        del self.table.rows[4242]
        ended = self.run_for(2)
        self.assertEqual([(entry["state"], entry["reason"]) for entry in ended], [("finished", "exited")])
        self.assertIsNotNone(ended[0]["finishedAt"])
        kind, title, body = self.emit.call_args.args
        self.assertEqual((kind, title, body), ("task.finished", "Blender finished", "The program closed."))
        self.assertEqual(self.emit.call_args.kwargs["data"]["taskID"], task["id"])
        self.assertEqual(self.heard, [("finished", "finished", "exited")])
        self.assertEqual(self.run_for(4), [])
        self.assertEqual(self.emit.call_count, 1)

    def test_pid_reuse_is_not_the_same_program(self):
        self.table.add(4242, "Render.exe", rate=50)
        created = self.table.rows[4242]["created"]
        self.watcher.add({"pid": 4242, "createTime": created, "mode": "exit", "label": "My render"})
        # The program exits and Windows hands the same PID to something else.
        del self.table.rows[4242]
        self.table.add(4242, "notepad.exe", rate=0, created=created + 30)
        ended = self.run_for(2)
        self.assertEqual(ended[0]["state"], "finished")
        self.assertEqual(self.emit.call_args.args[1], "My render finished")
        # Watching by the old identity is refused: it would watch notepad instead.
        with self.assertRaises(tasks.TaskError) as refused:
            self.watcher.add({"pid": 4242, "createTime": created, "mode": "exit"})
        self.assertEqual(refused.exception.status, 404)

    def test_idle_mode_counts_children_and_waits_for_activity_first(self):
        self.table.add(100, "Adobe Premiere Pro.exe", rate=1.0)
        task = self.watcher.add({"pid": 100, "createTime": self.table.rows[100]["created"], "mode": "idle", "idleMinutes": 2})
        self.assertEqual((task["label"], task["idleMinutes"]), ("Adobe Premiere Pro", 2))
        # Idle from the start: never "finished" before it was busy once.
        self.assertEqual(self.run_for(180), [])
        self.assertFalse(self.watcher.get(task["id"])["wasActive"])
        # The work happens in a child (and grandchild) process.
        self.table.add(101, "AMEEncoder.exe", rate=30.0, parent=100)
        self.table.add(102, "worker.exe", rate=20.0, parent=101)
        self.run_for(30)
        current = self.watcher.get(task["id"])
        self.assertTrue(current["wasActive"])
        self.assertAlmostEqual(current["cpuPercent"], 51.0, delta=1.0)
        # The encode ends; the children exit and the parent drops to 1 %.
        del self.table.rows[102]
        del self.table.rows[101]
        self.assertEqual(self.run_for(110), [])
        ended = self.run_for(20)
        self.assertEqual([(entry["state"], entry["reason"]) for entry in ended], [("finished", "idle")])
        self.assertEqual(self.emit.call_args.args[1:], ("Adobe Premiere Pro finished", "It has been idle for 2 minutes."))

    def test_short_dips_do_not_finish_an_idle_task(self):
        self.table.add(100, "Render.exe", rate=40.0)
        task = self.watcher.add({"pid": 100, "createTime": self.table.rows[100]["created"], "mode": "idle", "idleMinutes": 1})
        self.run_for(20)
        self.table.rows[100]["rate"] = 0.5
        self.run_for(40)
        self.table.rows[100]["rate"] = 40.0
        self.run_for(20)
        self.table.rows[100]["rate"] = 0.5
        self.assertEqual(self.run_for(50), [])
        self.assertEqual(self.watcher.get(task["id"])["state"], "watching")
        self.assertEqual(len(self.run_for(20)), 1)

    def test_idle_task_whose_process_exits_is_gone(self):
        self.table.add(100, "Render.exe", rate=40.0)
        self.watcher.add({"pid": 100, "createTime": self.table.rows[100]["created"], "mode": "idle"})
        self.run_for(10)
        del self.table.rows[100]
        ended = self.run_for(2)
        self.assertEqual((ended[0]["state"], ended[0]["reason"]), ("gone", "exited"))
        self.assertEqual(self.emit.call_args.args[1:], ("Render closed", "It closed before it went idle."))

    def test_notifications_off_still_tells_listeners(self):
        watcher = tasks.TaskWatcher(clock=self.table.wall, monotonic=self.table.mono, process=self.table.process,
                                    cpu_count=lambda: 4, emit=self.emit, notify_enabled=lambda: False)
        heard = []
        watcher.add_listener(lambda kind, task: heard.append(kind))
        self.table.add(7, "a.exe")
        watcher.add({"pid": 7, "createTime": self.table.rows[7]["created"], "mode": "exit"})
        del self.table.rows[7]
        self.table.advance(2)
        watcher.poll()
        self.emit.assert_not_called()
        self.assertEqual(heard, ["finished"])

    def test_validation(self):
        self.table.add(7, "a.exe")
        created = self.table.rows[7]["created"]
        cases = [
            ("not a dict", 422), ({"pid": "7", "createTime": created}, 422), ({"pid": True, "createTime": created}, 422),
            ({"pid": 7}, 422), ({"pid": 7, "createTime": -1}, 422), ({"pid": 7, "createTime": created, "mode": "sleep"}, 422),
            ({"pid": 7, "createTime": created, "mode": "idle", "idleMinutes": 0}, 422),
            ({"pid": 7, "createTime": created, "mode": "idle", "idleMinutes": 1000}, 422),
            ({"pid": 7, "createTime": created, "label": 5}, 422), ({"pid": 8, "createTime": created}, 404),
            ({"pid": 7, "createTime": created + 1}, 404),
        ]
        for body, status in cases:
            with self.subTest(body=body), self.assertRaises(tasks.TaskError) as refused:
                self.watcher.add(body)
            self.assertEqual(refused.exception.status, status)

    def test_same_program_twice_is_one_task_and_the_limit_holds(self):
        self.table.add(7, "a.exe")
        created = self.table.rows[7]["created"]
        first = self.watcher.add({"pid": 7, "createTime": created, "mode": "exit"})
        second = self.watcher.add({"pid": 7, "createTime": created, "mode": "exit", "label": "Renamed"})
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(second["label"], "Renamed")
        for pid in range(1000, 1000 + tasks.MAX_WATCHING - 1):
            self.table.add(pid, "p.exe")
            self.watcher.add({"pid": pid, "createTime": self.table.rows[pid]["created"]})
        self.table.add(5000, "p.exe")
        with self.assertRaises(tasks.TaskError) as refused:
            self.watcher.add({"pid": 5000, "createTime": self.table.rows[5000]["created"]})
        self.assertEqual(refused.exception.status, 409)

    def test_remove_and_retention(self):
        self.table.add(7, "a.exe")
        task = self.watcher.add({"pid": 7, "createTime": self.table.rows[7]["created"]})
        self.assertTrue(self.watcher.remove(task["id"]))
        self.assertFalse(self.watcher.remove(task["id"]))
        self.assertEqual(self.heard, [("removed", "watching", None)])
        self.table.add(8, "b.exe")
        task = self.watcher.add({"pid": 8, "createTime": self.table.rows[8]["created"]})
        del self.table.rows[8]
        self.run_for(2)
        self.assertEqual(self.watcher.list()["tasks"][0]["state"], "finished")
        self.table.advance(tasks.RETAIN_ENDED_SECONDS + 10)
        self.assertEqual(self.watcher.list(), {"tasks": []})

    def test_access_denied_while_polling_is_retried_later(self):
        self.table.add(7, "a.exe")
        self.watcher.add({"pid": 7, "createTime": self.table.rows[7]["created"]})
        original = self.table.process
        self.watcher._process = MagicMock(side_effect=psutil.AccessDenied(7))
        self.assertEqual(self.run_for(4), [])
        self.watcher._process = original
        self.assertEqual(self.watcher.list()["tasks"][0]["state"], "watching")


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.table = FakeTable()
        self.table.add(4242, "Blender.exe", rate=50)
        self.watcher = tasks.TaskWatcher(clock=self.table.wall, monotonic=self.table.mono, process=self.table.process,
                                         cpu_count=lambda: 4, emit=MagicMock())

        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")
        app = FastAPI()
        app.include_router(tasks.create_tasks_router(verify, lambda: self.watcher))
        self.client = TestClient(app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.http = TestClient(app)
        self.addCleanup(self.http.close)

    def test_post_get_delete(self):
        created = self.table.rows[4242]["created"]
        response = self.client.post("/api/tasks", json={"pid": 4242, "createTime": created, "mode": "idle", "idleMinutes": 3,
                                                        "label": "Final render"}, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        task = response.json()
        self.assertEqual({key: task[key] for key in ("pid", "createTime", "label", "mode", "idleMinutes", "state", "finishedAt")},
                         {"pid": 4242, "createTime": created, "label": "Final render", "mode": "idle", "idleMinutes": 3,
                          "state": "watching", "finishedAt": None})
        listed = self.client.get("/api/tasks", headers=AUTH).json()
        self.assertEqual([entry["id"] for entry in listed["tasks"]], [task["id"]])
        self.assertEqual(self.client.delete(f"/api/tasks/{task['id']}", headers=AUTH).json(), {"status": "removed"})
        self.assertEqual(self.client.delete(f"/api/tasks/{task['id']}", headers=AUTH).status_code, 404)
        self.assertEqual(self.client.delete("/api/tasks/../../etc", headers=AUTH).status_code, 404)

    def test_errors_are_sentences(self):
        response = self.client.post("/api/tasks", json={"pid": 1, "createTime": 5.0}, headers=AUTH)
        self.assertEqual(response.status_code, 404)
        self.assertIn("already closed", response.json()["detail"])
        self.assertEqual(self.client.post("/api/tasks", json={"pid": 4242}, headers=AUTH).status_code, 422)

    def test_token_then_https(self):
        for method in ("get", "post"):
            with self.subTest(method=method):
                self.assertEqual(getattr(self.client, method)("/api/tasks").status_code, 401)
                self.assertEqual(getattr(self.http, method)("/api/tasks", headers=AUTH).status_code, 426)
        self.assertEqual(self.client.delete("/api/tasks/" + "a" * 32).status_code, 401)


if __name__ == "__main__":
    unittest.main()
