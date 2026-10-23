"""Alert settings, the temperature watch (hold time, hysteresis, cooldown) and pc.online."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_alerts as alerts
import orbit_settings as settings

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class StoreMixin:
    def make_store(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        store = settings.SettingsStore(Path(folder.name) / "settings.json")
        settings.set_shared_store(store)
        self.addCleanup(settings.set_shared_store, None)
        return store


class SettingsValidationTests(StoreMixin, unittest.TestCase):
    def setUp(self):
        self.store = self.make_store()

    def test_defaults_when_nothing_was_saved(self):
        self.assertEqual(alerts.current_alerts(self.store), alerts.DEFAULT_ALERTS)
        self.assertEqual(alerts.DEFAULT_ALERTS["temperature"], {"enabled": True, "cpu": 90, "gpu": 85, "forSeconds": 30})

    def test_put_is_a_full_replace_with_defaults_for_missing_keys(self):
        saved = alerts.save_alerts({"temperature": {"cpu": 95, "forSeconds": 10}, "downloads": {"enabled": False},
                                    "pcToasts": False, "futureKey": {"x": 1}}, self.store)
        self.assertEqual(saved["temperature"], {"enabled": True, "cpu": 95, "gpu": 85, "forSeconds": 10})
        self.assertFalse(saved["downloads"]["enabled"])
        self.assertFalse(saved["pcToasts"])
        self.assertNotIn("futureKey", saved)
        # A second PUT without "downloads" turns it back on: full replace, not a merge.
        saved = alerts.save_alerts({"temperature": {"cpu": 95}}, self.store)
        self.assertTrue(saved["downloads"]["enabled"])
        self.assertTrue(saved["pcToasts"])
        self.assertEqual(self.store.get("alerts"), saved)

    def test_invalid_values_are_refused_with_sentences(self):
        cases = [
            ([], "JSON object"),
            ({"temperature": {"cpu": 200}}, "between 40 and 120"),
            ({"temperature": {"gpu": "hot"}}, "between 40 and 120"),
            ({"temperature": {"cpu": True}}, "between 40 and 120"),
            ({"temperature": {"forSeconds": -1}}, "forSeconds"),
            ({"temperature": {"forSeconds": 2.5}}, "forSeconds"),
            ({"temperature": {"enabled": "yes"}}, "true or false"),
            ({"downloads": {"enabled": 1}}, "true or false"),
            ({"tasks": "on"}, "must be an object"),
            ({"pcToasts": "no"}, "true or false"),
        ]
        for body, words in cases:
            with self.subTest(body=body), self.assertRaises(ValueError) as refused:
                alerts.validate_alerts(body)
            self.assertIn(words, str(refused.exception))

    def test_damaged_stored_values_fall_back_one_by_one(self):
        self.store.replace("alerts", {"temperature": {"cpu": "x", "gpu": 70, "forSeconds": 5}, "online": {"enabled": False},
                                      "pcToasts": "maybe", "tasks": []})
        current = alerts.current_alerts(self.store)
        self.assertEqual(current["temperature"], {"enabled": True, "cpu": 90, "gpu": 70, "forSeconds": 5})
        self.assertFalse(current["online"]["enabled"])
        self.assertTrue(current["pcToasts"])
        self.assertTrue(current["tasks"]["enabled"])
        self.assertFalse(alerts.kind_enabled("online", self.store))
        self.assertTrue(alerts.kind_enabled("downloads", self.store))

    def test_pc_toasts_setting_is_the_one_orbit_notify_reads(self):
        import orbit_notify
        alerts.save_alerts({"pcToasts": False}, self.store)
        self.assertFalse(orbit_notify.toasts_enabled())
        alerts.save_alerts({}, self.store)
        self.assertTrue(orbit_notify.toasts_enabled())


class RouteTests(StoreMixin, unittest.TestCase):
    def setUp(self):
        self.store = self.make_store()

        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")
        app = FastAPI()
        app.include_router(alerts.create_alerts_router(verify, lambda: self.store))
        self.client = TestClient(app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.http = TestClient(app)
        self.addCleanup(self.http.close)

    def test_get_and_put(self):
        response = self.client.get("/api/alerts", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), alerts.DEFAULT_ALERTS)
        self.assertEqual(response.headers["cache-control"], "no-store")
        body = {"temperature": {"enabled": True, "cpu": 88, "gpu": 80, "forSeconds": 60}, "downloads": {"enabled": True},
                "tasks": {"enabled": False}, "online": {"enabled": True}, "summary": {"enabled": True}, "pcToasts": True}
        response = self.client.put("/api/alerts", json=body, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), body)
        self.assertEqual(self.client.get("/api/alerts", headers=AUTH).json(), body)

    def test_bad_body_is_422_and_saves_nothing(self):
        response = self.client.put("/api/alerts", json={"temperature": {"cpu": 5}}, headers=AUTH)
        self.assertEqual(response.status_code, 422)
        self.assertIn("between 40 and 120", response.json()["detail"])
        self.assertIsNone(self.store.get("alerts"))

    def test_token_then_https(self):
        for method in ("get", "put"):
            with self.subTest(method=method):
                self.assertEqual(getattr(self.client, method)("/api/alerts").status_code, 401)
                self.assertEqual(getattr(self.http, method)("/api/alerts", headers=AUTH).status_code, 426)

    def test_save_failure_is_503(self):
        with patch.object(self.store, "replace", side_effect=OSError("disk full")), self.assertLogs("orbit.alerts", "WARNING"):
            response = self.client.put("/api/alerts", json={}, headers=AUTH)
        self.assertEqual(response.status_code, 503)
        self.assertIn("could not save", response.json()["detail"])


class TemperatureMonitorTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.config = {"temperature": {"enabled": True, "cpu": 90, "gpu": 85, "forSeconds": 30}}
        self.emit = MagicMock(side_effect=lambda kind, title, body, **kwargs: {"kind": kind, "title": title, "body": body, **kwargs})
        self.monitor = alerts.TemperatureMonitor(clock=self.clock, config_provider=lambda: self.config, emit=self.emit)

    def feed(self, seconds, cpu=None, gpu=None, step=1.0):
        """Ticks once per `step` seconds for `seconds` seconds; returns every emitted event."""
        emitted = []
        elapsed = 0.0
        while elapsed < seconds:
            emitted.extend(self.monitor.observe({"cpuTemp": cpu, "gpuTemp": gpu}))
            self.clock.advance(step)
            elapsed += step
        return emitted

    def test_alert_only_after_the_hold_time(self):
        self.assertEqual(self.feed(30, cpu=92), [])
        emitted = self.feed(1, cpu=92)
        self.assertEqual(len(emitted), 1)
        kind, title, body = self.emit.call_args.args
        self.assertEqual((kind, title), ("temperature.high", "CPU is running hot"))
        self.assertIn("92 °C", body)
        self.assertIn("30 seconds", body)
        self.assertEqual(self.emit.call_args.kwargs["level"], "timeSensitive")
        self.assertEqual(self.emit.call_args.kwargs["data"], {"sensor": "cpu", "temperature": 92.0, "threshold": 90})

    def test_a_dip_below_the_threshold_restarts_the_hold_time(self):
        self.feed(20, cpu=95)
        self.feed(1, cpu=89)
        self.assertEqual(self.feed(29, cpu=95), [])
        self.assertEqual(len(self.feed(2, cpu=95)), 1)

    def test_hysteresis_rearms_only_5_degrees_below(self):
        self.assertEqual(len(self.feed(31, cpu=95)), 1)
        self.clock.advance(alerts.COOLDOWN_SECONDS)  # cooldown is not what blocks the next alert here
        self.feed(5, cpu=86)  # below the threshold but not 5 °C below: still disarmed
        self.assertEqual(self.feed(40, cpu=95), [])
        self.feed(2, cpu=85)  # 5 °C below: re-armed
        self.assertEqual(len(self.feed(31, cpu=95)), 1)

    def test_cooldown_of_ten_minutes_per_sensor(self):
        self.assertEqual(len(self.feed(31, cpu=95)), 1)
        self.feed(5, cpu=80)  # re-armed
        # Hot again within the cooldown: waits for the 10 minutes to pass, then alerts once.
        emitted = self.feed(alerts.COOLDOWN_SECONDS - 60, cpu=95, step=5.0)
        self.assertEqual(emitted, [])
        emitted = self.feed(120, cpu=95, step=5.0)
        self.assertEqual(len(emitted), 1)
        self.assertGreaterEqual(self.monitor.state("cpu")["lastAlert"] - 1000.0, alerts.COOLDOWN_SECONDS)

    def test_sensors_are_independent(self):
        emitted = self.feed(31, cpu=95, gpu=86)
        self.assertEqual(sorted(event["data"]["sensor"] for event in emitted), ["cpu", "gpu"])
        self.assertEqual(self.monitor.state("cpu")["armed"], False)
        self.feed(3, cpu=95, gpu=70)
        self.assertTrue(self.monitor.state("gpu")["armed"])
        self.assertFalse(self.monitor.state("cpu")["armed"])

    def test_missing_readings_and_gaps_never_count(self):
        self.feed(20, cpu=95)
        self.feed(1, cpu=None)
        self.assertEqual(self.feed(29, cpu=95), [])
        self.feed(1, cpu=None)
        # A long pause between ticks (PC asleep) restarts the streak too.
        self.assertEqual(self.feed(10, cpu=95), [])
        self.clock.advance(3600)
        self.assertEqual(self.feed(29, cpu=95), [])
        self.assertEqual(len(self.feed(2, cpu=95)), 1)

    def test_disabled_never_alerts_and_zero_hold_alerts_at_once(self):
        self.config["temperature"]["enabled"] = False
        self.assertEqual(self.feed(120, cpu=100), [])
        self.config["temperature"].update(enabled=True, forSeconds=0)
        emitted = self.feed(1, cpu=100)
        self.assertEqual(len(emitted), 1)
        self.assertIn("reached 100 °C", emitted[0]["body"])

    def test_observe_never_raises(self):
        self.emit.side_effect = RuntimeError("database locked")
        monitor = alerts.TemperatureMonitor(clock=self.clock, config_provider=lambda: 1 / 0, emit=self.emit)
        with self.assertLogs("orbit.alerts", "ERROR"):
            self.assertEqual(monitor.observe({"cpuTemp": 99}), [])
        self.assertEqual(self.monitor.observe("not a snapshot"), [])
        with self.assertLogs("orbit.alerts", "ERROR"):
            self.feed(31, cpu=99)


class OnlineTests(StoreMixin, unittest.TestCase):
    BOOT = 1_700_000_000.0

    def setUp(self):
        self.store = self.make_store()
        alerts._reset_online_state()
        self.addCleanup(alerts._reset_online_state)
        self.emit = MagicMock(return_value={"id": 1})
        self.clock = Clock(5000.0)
        self.wall = Clock(self.BOOT + 60)

    def announce(self, boot, **options):
        return alerts.announce_online(store=self.store, boot_time=boot, hostname="Gaming-PC", emit=self.emit,
                                      monotonic=self.clock, clock=self.wall, **options)

    def test_first_start_of_a_boot_is_announced(self):
        self.assertEqual(self.announce(self.BOOT), {"id": 1})
        kind, title, body = self.emit.call_args.args
        self.assertEqual((kind, title), ("pc.online", "Gaming-PC is online"))
        self.assertEqual(self.emit.call_args.kwargs["data"], {"reason": "started"})
        self.assertIs(self.emit.call_args.kwargs["toast"], False)  # the phone's news, not a balloon on the PC
        self.assertEqual(self.store.get("alertsState"), {"onlineBootTime": self.BOOT, "lastAliveAt": self.BOOT + 60})

    def test_restart_of_orbit_in_the_same_boot_stays_quiet(self):
        self.announce(self.BOOT)
        self.wall.advance(120)  # an update restarts the agent two minutes later; boot_time wobbles
        self.assertIsNone(self.announce(self.BOOT + 1.2))
        self.assertEqual(self.emit.call_count, 1)

    def test_a_new_boot_is_announced_even_one_minute_later(self):
        self.announce(self.BOOT)
        self.wall.advance(60)
        self.assertEqual(self.announce(self.BOOT + 90), {"id": 1})  # a quick reboot: new boot time
        self.assertEqual(self.emit.call_count, 2)

    def test_fast_startup_keeps_the_boot_time_but_the_pc_was_off(self):
        self.announce(self.BOOT)
        self.wall.advance(3 * 3600)  # shut down with Fast Startup, powered on three hours later
        self.assertEqual(self.announce(self.BOOT), {"id": 1})

    def test_the_alive_mark_is_refreshed_every_five_minutes(self):
        self.announce(self.BOOT)
        with patch.object(alerts.psutil, "boot_time", return_value=self.BOOT):
            self.clock.advance(60)
            self.assertFalse(alerts.note_alive(store=self.store, clock=self.wall, monotonic=self.clock))
            self.clock.advance(alerts.ALIVE_MARK_SECONDS)
            self.wall.advance(3 * 3600)
            self.assertTrue(alerts.note_alive(store=self.store, clock=self.wall, monotonic=self.clock))
        # The agent was alive until just now: a restart now is quiet even hours after the boot.
        self.wall.advance(30)
        self.assertIsNone(self.announce(self.BOOT))

    def test_handover_from_the_boot_instance_stays_quiet(self):
        self.announce(self.BOOT)
        self.wall.advance(3600)  # the user signs in an hour later
        alerts.note_handover()
        self.assertIsNone(self.announce(self.BOOT))
        self.assertEqual(self.emit.call_count, 1)

    def test_disabled_records_the_start_but_sends_nothing(self):
        alerts.save_alerts({"online": {"enabled": False}}, self.store)
        self.assertIsNone(self.announce(self.BOOT))
        self.emit.assert_not_called()
        self.assertEqual(self.store.get("alertsState")["onlineBootTime"], self.BOOT)

    def test_unknown_boot_time_still_announces(self):
        with patch.object(alerts.psutil, "boot_time", side_effect=OSError("denied")):
            event = alerts.announce_online(store=self.store, hostname="Gaming-PC", emit=self.emit, monotonic=self.clock, clock=self.wall)
        self.assertEqual(event, {"id": 1})

    def test_back_online_after_relay_outage_is_not_doubled_with_the_start_announcement(self):
        self.announce(self.BOOT)
        self.assertIsNone(alerts.announce_back_online(store=self.store, hostname="Gaming-PC", emit=self.emit, monotonic=self.clock))
        self.clock.advance(alerts.BACK_ONLINE_QUIET_SECONDS + 1)
        self.assertEqual(alerts.announce_back_online(store=self.store, hostname="Gaming-PC", emit=self.emit, monotonic=self.clock), {"id": 1})
        self.assertEqual(self.emit.call_args.args[1], "Gaming-PC is back online")
        self.assertEqual(self.emit.call_args.kwargs["data"], {"reason": "reconnected"})
        self.assertIs(self.emit.call_args.kwargs["toast"], False)
        alerts.save_alerts({"online": {"enabled": False}}, self.store)
        self.clock.advance(alerts.BACK_ONLINE_QUIET_SECONDS + 1)
        self.assertIsNone(alerts.announce_back_online(store=self.store, hostname="Gaming-PC", emit=self.emit, monotonic=self.clock))


if __name__ == "__main__":
    unittest.main()
