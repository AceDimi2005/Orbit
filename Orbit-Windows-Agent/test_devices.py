"""Per-device tokens, scopes, revocation and the legacy master-token migration.

Every registry lives in a temporary folder; no real token file, PC or network is used.
"""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient
from srptools import SRPClientSession
from starlette.websockets import WebSocketDisconnect

import orbit_access as access
import orbit_agent as agent
import orbit_devices as devices
import orbit_pairing as pairing

MASTER = "legacy-master-token-with-more-than-24-characters"
WIDGET = "widget-only-token-with-more-than-24-characters"


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


def all_routes(routes, prefix=""):
    """(method, path) of every route, also through FastAPI versions that keep included routers."""
    for route in routes:
        original = getattr(route, "original_router", None)
        if original is not None:
            context = getattr(route, "include_context", None)
            yield from all_routes(original.routes, prefix + (getattr(context, "prefix", "") or ""))
            continue
        path = getattr(route, "path", None)
        if path is None:
            continue
        methods = getattr(route, "methods", None)
        if methods is None:
            yield "WS", prefix + path
        else:
            for method in methods:
                if method != "HEAD":
                    yield method, prefix + path


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "devices.json"
        self.clock = Clock()
        self.registry = devices.DeviceRegistry(self.path, clock=self.clock)

    def tearDown(self):
        self.folder.cleanup()

    def test_tokens_are_returned_once_and_stored_only_as_hashes(self):
        device, token = self.registry.register("Orbit on iPhone", "iOS", "iPhone17,1")
        self.assertGreaterEqual(len(token), 40)
        self.assertEqual(device["name"], "iPhone")
        self.assertEqual(device["scopes"], list(devices.SCOPES))
        stored = self.path.read_text()
        self.assertNotIn(token, stored)
        self.assertIn(devices.token_hash(token), stored)
        if os.name != "nt":
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        principal = self.registry.authenticate(token, "192.168.1.20")
        self.assertEqual(principal.device_id, device["id"])
        self.assertTrue(principal.has("files"))

    def test_unknown_and_revoked_tokens_have_distinct_codes(self):
        device, token = self.registry.register("Orbit on iPad", "iPadOS")
        with self.assertRaises(devices.AccessError) as unknown:
            self.registry.authenticate("not-a-device-token-at-all-not-at-all")
        self.assertEqual((unknown.exception.status, unknown.exception.code), (401, "invalid_token"))
        self.registry.revoke(device["id"])
        with self.assertRaises(devices.AccessError) as revoked:
            self.registry.authenticate(token)
        self.assertEqual((revoked.exception.status, revoked.exception.code), (401, "device_revoked"))
        self.assertEqual(self.registry.list(), [])
        # A fresh registry reading the same file keeps the revocation.
        with self.assertRaises(devices.AccessError):
            devices.DeviceRegistry(self.path, clock=self.clock).authenticate(token)

    def test_master_token_becomes_one_legacy_device_with_every_scope(self):
        first = self.registry.migrate_legacy(MASTER)
        self.assertEqual(self.registry.migrate_legacy(MASTER), first)
        listed = self.registry.list()
        self.assertEqual([(row["name"], row["legacy"], row["scopes"]) for row in listed],
                         [("Legacy device", True, list(devices.SCOPES))])
        self.assertEqual(self.registry.authenticate(MASTER).device_id, first)
        reloaded = devices.DeviceRegistry(self.path, clock=self.clock)
        self.assertEqual(reloaded.migrate_legacy(MASTER), first)
        self.assertEqual(reloaded.count(), 1)

    def test_rotated_master_token_retires_the_old_legacy_device(self):
        old = self.registry.migrate_legacy(MASTER)
        new = self.registry.migrate_legacy("rotated-master-token-with-more-than-24-chars")
        self.assertNotEqual(old, new)
        with self.assertRaises(devices.AccessError) as revoked:
            self.registry.authenticate(MASTER)
        self.assertEqual(revoked.exception.code, "device_revoked")
        self.assertEqual(self.registry.authenticate("rotated-master-token-with-more-than-24-chars").device_id, new)

    def test_removed_legacy_device_stays_removed(self):
        legacy = self.registry.migrate_legacy(MASTER)
        self.registry.revoke(legacy)
        self.assertIsNone(self.registry.migrate_legacy(MASTER))
        self.assertIsNone(self.registry.migrate_legacy("another-master-token-with-more-than-24-chars"))
        self.assertEqual(self.registry.list(), [])
        with self.assertRaises(devices.AccessError) as revoked:
            self.registry.authenticate(MASTER)
        self.assertEqual(revoked.exception.code, "device_revoked")

    def test_rename_and_scopes_are_validated(self):
        device, token = self.registry.register("Orbit on Mac", "macOS")
        updated = self.registry.update(device["id"], name="  Studio Mac  ", scopes=["files", "read"])
        self.assertEqual((updated["name"], updated["scopes"]), ("Studio Mac", ["read", "files"]))
        self.assertEqual(self.registry.authenticate(token).scopes, frozenset({"read", "files"}))
        with self.assertRaises(ValueError):
            self.registry.update(device["id"], scopes=["root"])
        with self.assertRaises(ValueError):
            self.registry.update(device["id"], name="   ")
        with self.assertRaises(KeyError):
            self.registry.update("0" * 32, name="Nobody")

    def test_last_seen_and_address_are_recorded_and_flushed_in_the_background(self):
        device, token = self.registry.register("Apple TV · Orbit", None)
        self.assertEqual(device["platform"], "tvOS")
        self.registry.authenticate(token, "192.168.1.30")
        on_disk = json.loads(self.path.read_text())["devices"][0]
        self.assertIsNone(on_disk["lastSeenAt"])  # never written on the request itself
        self.registry.flush(force=False)  # first use is urgent: the flusher writes it at once
        on_disk = json.loads(self.path.read_text())["devices"][0]
        self.assertEqual(on_disk["lastAddress"], "192.168.1.30")
        self.assertIsNotNone(on_disk["lastSeenAt"])
        self.clock.now += 5
        self.registry.authenticate(token, "192.168.1.30")
        self.registry.flush(force=False)
        self.assertEqual(json.loads(self.path.read_text())["devices"][0]["lastSeenAt"], on_disk["lastSeenAt"])
        self.clock.now += 120
        self.registry.authenticate(token, "192.168.1.30")
        self.registry.flush(force=False)
        self.assertNotEqual(json.loads(self.path.read_text())["devices"][0]["lastSeenAt"], on_disk["lastSeenAt"])

    def test_unused_devices_expire_but_legacy_and_used_ones_stay(self):
        self.registry.migrate_legacy(MASTER)
        unused, _ = self.registry.register("Orbit on iPhone", "iOS")
        used, token = self.registry.register("Orbit on iPad", "iPadOS")
        self.registry.authenticate(token)
        self.clock.now += devices.UNUSED_SECONDS + 60
        names = {row["name"] for row in self.registry.list()}
        self.assertEqual(names, {"Legacy device", "iPad"})

    def test_revocation_tombstones_expire(self):
        device, token = self.registry.register("Orbit on iPhone", "iOS")
        self.registry.authenticate(token)
        self.registry.revoke(device["id"])
        self.clock.now += devices.TOMBSTONE_SECONDS + 60
        self.registry.list()
        self.assertEqual(self.registry.revoked_count(), 0)

    def test_new_manual_token_retires_the_unused_previous_one(self):
        first, first_token = self.registry.register("Manual setup", replace_unused_named="Manual setup")
        second, second_token = self.registry.register("Manual setup", replace_unused_named="Manual setup")
        self.assertEqual([row["id"] for row in self.registry.list()], [second["id"]])
        with self.assertRaises(devices.AccessError):
            self.registry.authenticate(first_token)
        self.registry.authenticate(second_token)
        third, _ = self.registry.register("Manual setup", replace_unused_named="Manual setup")
        self.assertEqual({row["id"] for row in self.registry.list()}, {second["id"], third["id"]})

    def test_unreadable_registry_is_never_silently_reset(self):
        self.path.write_text("{not json")
        with self.assertRaises(RuntimeError):
            devices.DeviceRegistry(self.path)
        self.assertEqual(self.path.read_text(), "{not json")

    def test_device_limit(self):
        with patch.object(devices, "MAX_DEVICES", 2):
            self.registry.register("A")
            self.registry.register("B")
            with self.assertRaises(devices.AccessError) as full:
                self.registry.register("C")
        self.assertEqual((full.exception.status, full.exception.code), (409, "too_many_devices"))

    def test_platform_names_and_default_scopes(self):
        self.assertEqual(devices.normalize_platform("ios"), "iOS")
        self.assertEqual(devices.normalize_platform("watchOS"), "watchOS")
        self.assertEqual(devices.normalize_platform(None, "Orbit on Dimitrie's MacBook Pro"), "macOS")
        self.assertEqual(devices.normalize_platform(None, "Orbit on iPad"), "iPadOS")
        self.assertIsNone(devices.normalize_platform(None, "Orbit on Living Room"))
        self.assertEqual(devices.display_name("Orbit on Dimitrie's MacBook Pro"), "Dimitrie's MacBook Pro")
        self.assertEqual(devices.display_name("Apple TV · Orbit"), "Apple TV")
        self.assertEqual(devices.display_name("", "tvOS"), "Apple TV")
        self.assertEqual(devices.device_kind("macOS"), "Mac")
        self.assertEqual(devices.device_kind(None), "device")
        self.assertEqual(devices.default_scopes("watchOS"), ["read", "control", "input"])
        self.assertEqual(devices.default_scopes("iOS"), list(devices.SCOPES))
        with self.assertRaises(ValueError):
            devices.normalize_scopes("read")

    def test_authentication_never_waits_for_a_slow_disk(self):
        import threading
        import time
        device, token = self.registry.register("Orbit on iPhone", "iOS")
        entered, release = threading.Event(), threading.Event()
        original = self.registry._persist

        def slow(payload):
            entered.set()
            release.wait(2)
            original(payload)
        with patch.object(self.registry, "_persist", slow):
            writer = threading.Thread(target=self.registry.update, args=(device["id"],), kwargs={"name": "Slow disk"})
            writer.start()
            self.assertTrue(entered.wait(2))
            started = time.monotonic()
            self.registry.authenticate(token)
            elapsed = time.monotonic() - started
            release.set()
            writer.join(2)
        self.assertLess(elapsed, 0.2)
        self.assertEqual(json.loads(self.path.read_text())["devices"][0]["name"], "Slow disk")

    def test_background_flusher_writes_and_stops(self):
        device, token = self.registry.register("Orbit on iPhone", "iOS")
        self.registry.start()
        self.registry.authenticate(token, "10.0.0.2")
        self.registry.close()
        self.assertEqual(json.loads(self.path.read_text())["devices"][0]["lastAddress"], "10.0.0.2")


class DeviceAPITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.registry = devices.DeviceRegistry(Path(self.folder.name) / "devices.json")
        self.legacy = self.registry.migrate_legacy(MASTER)
        self.patches = [patch.object(agent, "DEVICE_REGISTRY", self.registry), patch.object(agent, "API_TOKEN", MASTER),
                        patch.object(agent, "WIDGET_TOKEN", WIDGET)]
        for item in self.patches:
            item.start()
        self.http = TestClient(agent.app)
        self.https = TestClient(agent.app, base_url="https://testserver")

    def tearDown(self):
        self.http.close()
        self.https.close()
        for item in reversed(self.patches):
            item.stop()
        self.folder.cleanup()

    def device(self, name="Orbit on iPhone", scopes=None, platform="iOS"):
        device, token = self.registry.register(name, platform, None, scopes)
        return device, {"Authorization": f"Bearer {token}"}

    def test_legacy_master_token_keeps_every_existing_feature(self):
        auth = {"Authorization": f"Bearer {MASTER}"}
        self.assertEqual(self.http.get("/api/status", headers=auth).status_code, 200)
        self.assertEqual(self.https.get("/api/devices", headers=auth).status_code, 200)
        with patch.object(agent, "WIDGET_TOKEN", WIDGET):
            self.assertEqual(self.https.post("/api/widget/pairing", headers=auth).json(), {"token": WIDGET})

    def test_read_only_device_gets_machine_readable_scope_errors(self):
        _, auth = self.device(scopes=["read"])
        self.assertEqual(self.http.get("/api/status", headers=auth).status_code, 200)
        cases = [(self.http.post, "/api/volume?level=10", "control"), (self.http.post, "/api/action/lock", "control"),
                 (self.http.post, "/api/input/mouse?dx=1", "input"), (self.https.get, "/api/clipboard", "input"),
                 (self.https.get, "/api/files/roots", "files"), (self.https.get, "/api/devices", "admin"),
                 (self.https.post, "/api/update/apply", "admin"), (self.http.get, "/api/update/check", "admin"),
                 (self.https.post, "/api/history/start", "control"), (self.http.post, "/api/sunshine/start", "control")]
        with patch.object(agent, "endpoint_volume") as native, patch.object(agent, "require_windows"):
            for call, path, scope in cases:
                with self.subTest(path=path):
                    response = call(path, headers=auth)
                    self.assertEqual(response.status_code, 403)
                    body = response.json()
                    self.assertEqual((body["code"], body["scope"]), ("scope_missing", scope))
                    self.assertIn("detail", body)
            native.assert_not_called()

    def test_invalid_and_revoked_tokens(self):
        response = self.http.get("/api/status", headers={"Authorization": "Bearer nope"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json(), {"detail": "Invalid Orbit token", "code": "invalid_token"})
        self.assertEqual(response.headers["www-authenticate"], "Bearer")
        device, auth = self.device()
        self.registry.revoke(device["id"])
        response = self.http.get("/api/status", headers=auth)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["code"], "device_revoked")
        # Non-ASCII junk is a wrong token, never a server error.
        self.assertEqual(self.http.get("/api/status", headers={"Authorization": "Bearer é".encode("latin-1")}).status_code, 401)

    def test_widget_token_is_never_a_device_token(self):
        auth = {"Authorization": f"Bearer {WIDGET}"}
        for path in ("/api/status", "/api/capabilities", "/api/devices"):
            self.assertEqual(self.https.get(path, headers=auth).status_code, 401)
        self.assertEqual(self.https.get("/api/widget/status", headers=auth).status_code, 200)

    def test_capabilities_describe_the_agent_and_the_calling_device(self):
        device, auth = self.device(scopes=["read", "input"])
        self.assertEqual(self.http.get("/api/capabilities", headers=auth).status_code, 426)
        body = self.https.get("/api/capabilities", headers=auth).json()
        self.assertEqual(body["apiVersion"], 2)
        self.assertEqual(body["agentVersion"], "5.0.0")
        self.assertEqual(body["scopes"], ["read", "input"])
        self.assertIn("devices", body["features"])
        self.assertEqual((body["deviceID"], body["deviceName"]), (device["id"], "iPhone"))

    def test_admin_lists_renames_restricts_and_revokes_devices(self):
        phone, phone_auth = self.device()
        tv, tv_auth = self.device("Apple TV · Orbit", ["read", "control"], platform=None)
        listed = self.https.get("/api/devices", headers=phone_auth).json()
        self.assertEqual(listed["scopes"], list(devices.SCOPES))
        rows = {row["id"]: row for row in listed["devices"]}
        self.assertEqual(set(rows), {self.legacy, phone["id"], tv["id"]})
        self.assertTrue(rows[phone["id"]]["current"])
        self.assertEqual(rows[tv["id"]]["platform"], "tvOS")
        self.assertEqual(set(rows[phone["id"]]), {"id", "name", "platform", "model", "scopes", "createdAt", "lastSeenAt",
                                                  "lastAddress", "legacy", "current"})
        self.assertEqual(rows[phone["id"]]["lastAddress"], "testclient")
        renamed = self.https.patch(f"/api/devices/{tv['id']}", headers=phone_auth, json={"name": "Living room TV"})
        self.assertEqual(renamed.json()["name"], "Living room TV")
        restricted = self.https.patch(f"/api/devices/{tv['id']}", headers=phone_auth, json={"scopes": ["read"]})
        self.assertEqual(restricted.json()["scopes"], ["read"])
        self.assertEqual(self.http.post("/api/action/lock", headers=tv_auth).status_code, 403)
        for body in ({}, {"scopes": ["everything"]}, {"name": ""}, {"name": "x", "owner": "me"}):
            self.assertEqual(self.https.patch(f"/api/devices/{tv['id']}", headers=phone_auth, json=body).status_code, 422)
        self.assertEqual(self.https.patch(f"/api/devices/{'0' * 32}", headers=phone_auth, json={"name": "x"}).status_code, 404)
        self.assertEqual(self.https.patch("/api/devices/../../etc", headers=phone_auth, json={"name": "x"}).status_code, 404)
        self.assertEqual(self.https.delete(f"/api/devices/{tv['id']}", headers=phone_auth).json(),
                         {"status": "revoked", "id": tv["id"]})
        self.assertEqual(self.http.get("/api/status", headers=tv_auth).json()["code"], "device_revoked")

    def test_any_device_can_remove_itself_but_not_others(self):
        phone, phone_auth = self.device()
        tv, tv_auth = self.device("Apple TV · Orbit", ["read"], platform="tvOS")
        refused = self.https.delete(f"/api/devices/{phone['id']}", headers=tv_auth)
        self.assertEqual((refused.status_code, refused.json()["scope"]), (403, "admin"))
        self.assertEqual(self.https.delete(f"/api/devices/{tv['id']}", headers=tv_auth).status_code, 200)
        self.assertEqual(self.http.get("/api/status", headers=tv_auth).status_code, 401)
        self.assertEqual(self.http.get("/api/status", headers=phone_auth).status_code, 200)

    def test_admin_endpoints_need_https(self):
        _, auth = self.device()
        for call, path in ((self.http.get, "/api/devices"), (self.http.post, "/api/sunshine/credentials"),
                           (self.http.post, "/api/update/apply"), (self.http.delete, f"/api/devices/{'a' * 32}")):
            response = call(path, headers=auth)
            self.assertEqual(response.status_code, 426, path)
            self.assertEqual(response.json()["code"], "https_required")

    def test_admin_can_create_a_watch_token_within_its_own_scopes(self):
        _, admin = self.device()
        created = self.https.post("/api/devices", headers=admin, json={"name": "Apple Watch", "platform": "watchOS"})
        self.assertEqual(created.status_code, 201)
        body = created.json()
        self.assertEqual(body["device"]["scopes"], ["read", "control", "input"])
        watch = {"Authorization": f"Bearer {body['token']}"}
        self.assertEqual(self.http.get("/api/watch/summary", headers=watch).status_code, 200)
        self.assertEqual(self.https.get("/api/files/roots", headers=watch).json()["scope"], "files")
        _, limited = self.device("Orbit on iPad", ["read", "admin"], platform="iPadOS")
        escalation = self.https.post("/api/devices", headers=limited, json={"name": "x", "scopes": ["files"]})
        self.assertEqual((escalation.status_code, escalation.json()["scope"]), (403, "files"))
        self.assertEqual(self.https.post("/api/devices", headers=admin, json={"name": "x", "scopes": ["root"]}).status_code, 422)

    def test_websockets_need_the_input_scope(self):
        _, reader = self.device(scopes=["read"])
        for path in ("/ws/input", "/ws/stream"):
            with self.assertRaises(WebSocketDisconnect) as refused:
                with self.http.websocket_connect(path, headers=reader):
                    pass
            self.assertEqual(refused.exception.code, 1008)
        _, typist = self.device(scopes=["input"])
        with patch.object(agent, "HAS_SCREEN_CAPTURE", False):
            with self.http.websocket_connect("/ws/stream", headers=typist) as websocket:
                with self.assertRaises(WebSocketDisconnect) as unavailable:
                    websocket.receive_bytes()
        self.assertEqual(unavailable.exception.code, 1011)

    def test_handover_only_accepts_the_master_token_from_loopback(self):
        _, admin = self.device()
        local = TestClient(agent.app, client=("127.0.0.1", 50000))
        self.addCleanup(local.close)
        with patch.object(agent.threading, "Timer") as timer:
            self.assertEqual(local.post("/api/internal/handover", headers=admin).status_code, 401)
            timer.assert_not_called()
            self.assertEqual(local.post("/api/internal/handover", headers={"Authorization": f"Bearer {MASTER}"}).status_code, 200)
            timer.assert_called_once()

    def test_paired_device_gets_its_own_token_in_the_pairing_payload(self):
        with patch.object(agent, "on_device_paired") as paired:
            extra = agent.register_paired_device({"name": "Orbit on Mac", "platform": "macOS", "model": "Mac15,3"}, "10.0.0.4")
        self.assertEqual(extra["apiToken"], extra["deviceToken"])
        self.assertEqual(extra["scopes"], list(devices.SCOPES))
        self.assertEqual(self.registry.authenticate(extra["apiToken"]).device_id, extra["deviceID"])
        paired.assert_called_once()
        self.assertEqual(paired.call_args.args[0]["platform"], "macOS")

    def test_manual_pairing_token_is_a_new_device_and_replaces_the_unused_one(self):
        with patch.object(agent, "on_device_paired"):
            first = agent.mint_manual_token()
            second = agent.mint_manual_token()
        self.assertNotEqual(first, second)
        self.assertNotEqual(second, MASTER)
        with self.assertRaises(devices.AccessError):
            self.registry.authenticate(first)
        self.assertEqual(self.registry.authenticate(second).name, "Manual setup")
        with patch.object(agent, "DEVICE_REGISTRY", None):
            self.assertIsNone(agent.mint_manual_token())


class PolicyTableTests(unittest.TestCase):
    def test_every_route_has_an_explicit_policy_and_every_policy_a_route(self):
        routes = set(all_routes(agent.app.routes))
        policies = set(access.POLICIES)
        self.assertEqual(sorted(routes - policies), [], "routes without an explicit scope policy")
        self.assertEqual(sorted(policies - routes), [], "policies for routes that do not exist")

    def test_scopes_follow_the_documented_mapping(self):
        policy = access.policy_for
        for path in ("/api/status", "/api/specs", "/api/history/sessions", "/api/watch/summary", "/api/processes"):
            self.assertEqual(policy("GET", path).scope, "read", path)
        for method, path in (("POST", "/api/action/{action_name}"), ("POST", "/api/volume"), ("POST", "/api/audio/session"),
                             ("POST", "/api/audio/route"), ("POST", "/api/sunshine/pin"), ("POST", "/api/sunshine/start"),
                             ("POST", "/api/processes/{pid}/terminate"), ("POST", "/api/sunshine/launch")):
            self.assertEqual(policy(method, path).scope, "control", path)
        for method, path in (("POST", "/api/input/mouse"), ("POST", "/api/input/keyboard"), ("GET", "/api/clipboard"),
                             ("PUT", "/api/clipboard")):
            self.assertEqual(policy(method, path).scope, "input", path)
        self.assertEqual(access.POLICIES[("WS", "/ws/input")].scope, "input")
        self.assertEqual(access.POLICIES[("WS", "/ws/stream")].scope, "input")
        for method, path in access.POLICIES:
            if path.startswith("/api/files/"):
                self.assertEqual((policy(method, path).scope, policy(method, path).secure), ("files", True), path)
        for method, path in (("GET", "/api/devices"), ("POST", "/api/devices"), ("PATCH", "/api/devices/{device_id}"),
                             ("POST", "/api/update/apply"), ("POST", "/api/sunshine/credentials"),
                             ("DELETE", "/api/sunshine/credentials")):
            self.assertEqual((policy(method, path).scope, policy(method, path).secure), ("admin", True), path)

    def test_unknown_paths_need_an_admin_over_https(self):
        table = access.PolicyTable(access.POLICIES)
        self.assertEqual(table.resolve("GET", "/api/not-a-route")[1], access.DEFAULT_POLICY)
        self.assertEqual(table.resolve("GET", "/api/devices/" + "a" * 32)[1], access.DEFAULT_POLICY)
        self.assertEqual(table.resolve("DELETE", "/api/devices/" + "a" * 32)[0], "/api/devices/{device_id}")
        self.assertEqual(table.resolve("HEAD", "/api/status")[0], "/api/status")


class PairingDeviceTests(unittest.TestCase):
    FINGERPRINT = "12:34:" + ":".join(["ab"] * 30)

    def setUp(self):
        self.shown = []
        self.registered = []

    def manager(self, show=None, register=None):
        def payload(host):
            return {"hostname": "PC", "apiToken": MASTER, "widgetToken": WIDGET}
        return pairing.PairingManager(self.FINGERPRINT, payload, show_pin=show or self.show, register_device=register)

    def show(self, name, pin, kind="device"):
        self.shown.append((name, pin, kind))
        return lambda: None

    def pair(self, manager, name="Orbit on Mac", platform=None, model=None, wrong=False):
        first = SRPClientSession(pairing.PairingContext("unused"))
        challenge = manager.start("192.0.2.10", name, first.public, platform=platform, model=model)
        pin = (manager._sessions[challenge["id"]]["pin"])
        if wrong:
            pin = "000000" if pin != "000000" else "000001"
        client = SRPClientSession(pairing.PairingContext(pin), private=first.private)
        client.process(challenge["serverPublic"], challenge["salt"])
        proof = client.key_proof.decode("ascii") if isinstance(client.key_proof, bytes) else client.key_proof
        return challenge, client, manager.finish("192.0.2.10", challenge["id"], proof, "192.0.2.1")

    def test_dialog_names_the_kind_of_device_that_pairs(self):
        manager = self.manager()
        manager.start("192.0.2.10", "Orbit on Mac", SRPClientSession(pairing.PairingContext("x")).public, platform="macOS")
        manager.close()
        self.assertEqual(self.shown[-1][2], "Mac")
        manager = self.manager()
        manager.start("192.0.2.11", "Apple TV · Orbit", SRPClientSession(pairing.PairingContext("x")).public)
        manager.close()
        self.assertEqual(self.shown[-1][2], "Apple TV")
        self.assertIn("Enter this code on your Apple TV.", pairing.pin_message("Apple TV", "123456", "Apple TV"))

    def test_two_argument_displays_from_older_callers_still_work(self):
        shown = []
        manager = self.manager(show=lambda name, pin: shown.append(pin))
        manager.start("192.0.2.10", "Orbit on iPhone", SRPClientSession(pairing.PairingContext("x")).public)
        manager.close()
        self.assertEqual(len(shown), 1)

    def test_successful_proof_registers_the_device_and_returns_its_token(self):
        def register(client, peer):
            self.registered.append((client, peer))
            return {"apiToken": "device-token-" + "x" * 30, "deviceToken": "device-token-" + "x" * 30,
                    "deviceID": "a" * 32, "scopes": ["read"]}
        manager = self.manager(register=register)
        pending_before = None
        challenge, client, confirmation = self.pair(manager, platform="macOS", model="Mac15,3")
        import base64
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        key_hex = client.key.decode("ascii") if isinstance(client.key, bytes) else client.key
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=challenge["id"].encode(), info=pairing.KEY_INFO).derive(bytes.fromhex(key_hex))
        credentials = json.loads(AESGCM(key).decrypt(base64.b64decode(confirmation["nonce"]),
                                                    base64.b64decode(confirmation["ciphertext"]), challenge["id"].encode()))
        self.assertEqual(credentials["apiToken"], "device-token-" + "x" * 30)
        self.assertEqual(credentials["deviceID"], "a" * 32)
        self.assertEqual(credentials["widgetToken"], WIDGET)
        self.assertEqual(self.registered[0][0]["platform"], "macOS")
        self.assertEqual(self.registered[0][0]["model"], "Mac15,3")
        self.assertIsNone(pending_before)

    def test_wrong_pin_never_registers_a_device(self):
        register = MagicMock()
        manager = self.manager(register=register)
        with self.assertRaises(pairing.HTTPException) as wrong:
            self.pair(manager, wrong=True)
        self.assertEqual(wrong.exception.status_code, 403)
        register.assert_not_called()

    def test_registration_failure_returns_no_credentials(self):
        manager = self.manager(register=MagicMock(side_effect=devices.AccessError(409, "too_many_devices", "Full")))
        with self.assertRaises(pairing.HTTPException) as full:
            self.pair(manager)
        self.assertEqual(full.exception.status_code, 409)
        manager = self.manager(register=MagicMock(side_effect=OSError("disk full")))
        with self.assertRaises(pairing.HTTPException) as broken:
            self.pair(manager)
        self.assertEqual(broken.exception.status_code, 503)

    def test_pending_code_is_available_for_the_window_on_the_pc(self):
        manager = self.manager()
        self.assertIsNone(manager.pending())
        manager.start("192.0.2.10", "Orbit on iPad", SRPClientSession(pairing.PairingContext("x")).public)
        pending = manager.pending()
        self.assertEqual((pending["kind"], pending["code"]), ("iPad", self.shown[-1][1]))
        self.assertEqual(pending["expiresIn"], pairing.PIN_SECONDS)
        manager.close()
        self.assertIsNone(manager.pending())

    def test_router_accepts_platform_and_model(self):
        from fastapi import FastAPI
        manager = self.manager()
        app = FastAPI()
        app.include_router(pairing.create_pairing_router(lambda: manager))
        client = TestClient(app, base_url="https://orbit.test", client=("192.0.2.10", 1))
        self.addCleanup(client.close)
        body = {"name": "Orbit on iPhone", "clientPublic": SRPClientSession(pairing.PairingContext("x")).public,
                "platform": "iOS", "model": "iPhone17,1"}
        self.assertEqual(client.post("/api/pair/start", json=body).status_code, 200)
        session = next(iter(manager._sessions.values()))
        self.assertEqual(session["client"]["model"], "iPhone17,1")
        self.assertEqual(self.shown[-1][2], "iPhone")
        manager.close()
        self.assertEqual(client.post("/api/pair/start", json={**body, "platform": "x" * 21}).status_code, 422)


if __name__ == "__main__":
    unittest.main()
