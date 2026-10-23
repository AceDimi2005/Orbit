"""Instant push: per-device AES-GCM (checked by independent decryption), and the relay client against
a fake relay that implements Orbit-Push-Relay/PROTOCOL.md on 127.0.0.1 (channels, devices with
remembered 410 tokens, notify fan-out, heartbeats, offline-expected, status, recovery)."""
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import secrets
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient

import orbit_push as push
import orbit_settings as settings

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
DEVICE_A = "6F1D2C3B-4A59-4E8F-9A0B-1C2D3E4F5A6B"
DEVICE_B = "A1B2C3D4-0000-4E8F-9A0B-FFFFFFFFFFFF"
KEY_A = bytes(range(32))
KEY_B = bytes(range(100, 132))
TOKEN_A = "a1" * 32
TOKEN_B = "b2" * 40
DEVICE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BASE64 = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
COLLAPSE = re.compile(r"^[A-Za-z0-9._:-]{1,48}$")


def open_sealed(key, device_id, sealed):
    """Independent decryption, exactly as the phone does it (AES.GCM.SealedBox(combined:))."""
    raw = base64.b64decode(sealed, validate=True)
    nonce, body = raw[:12], raw[12:]
    plain = AESGCM(key).decrypt(nonce, body, device_id.encode("utf-8"))
    return plain


def b64(key):
    return base64.b64encode(key).decode("ascii")


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


# -- Fake relay ----------------------------------------------------------------------------------

class FakeRelay:
    """PROTOCOL.md version 1, in memory. Tests steer it through attributes."""

    def __init__(self):
        self.lock = threading.Lock()
        self.channels = {}
        self.requests = []
        self.forced = []  # [(method, path regex, status, body, headers)] used once each
        self.behaviour = {}  # deviceId -> sent | unregistered | retry | permanent | timeout
        self.down = False
        self.offline_expected_delay = 0.0
        relay = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                relay.handle(self, "GET")

            def do_POST(self):
                relay.handle(self, "POST")

            def do_PUT(self):
                relay.handle(self, "PUT")

            def do_DELETE(self):
                relay.handle(self, "DELETE")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    # Helpers for tests
    def paths(self, method=None):
        with self.lock:
            return [(entry["method"], entry["route"]) for entry in self.requests if method is None or entry["method"] == method]

    def last(self, method, route_end):
        with self.lock:
            for entry in reversed(self.requests):
                if entry["method"] == method and entry["route"].endswith(route_end):
                    return entry
        return None

    def clear(self):
        with self.lock:
            self.requests.clear()

    def force(self, method, pattern, status, body, headers=None):
        self.forced.append((method, re.compile(pattern), status, body, headers or {}))

    # Request handling
    def reply(self, handler, status, body, headers=None):
        data = json.dumps(body).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            handler.send_header(name, value)
        handler.end_headers()
        handler.wfile.write(data)

    def error(self, handler, status, code, message, headers=None, **extra):
        self.reply(handler, status, {"error": code, "message": message, **extra}, headers)

    def handle(self, handler, method):
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length else b""
        route = handler.path.split("?")[0].rstrip("/") or "/"
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            body = None
        entry = {"method": method, "route": route, "body": body, "headers": dict(handler.headers.items())}
        with self.lock:
            self.requests.append(entry)
        if self.down:
            handler.close_connection = True
            return  # no answer at all: the client sees a dropped connection
        for index, (forced_method, pattern, status, forced_body, headers) in enumerate(self.forced):
            if forced_method == method and pattern.search(route):
                del self.forced[index]
                return self.reply(handler, status, forced_body, headers)
        if route in ("/", "/v1/health") and method == "GET":
            return self.reply(handler, 200, {"ok": True, "service": "orbit-push-relay", "protocol": 1, "apns": "configured"})
        if route == "/v1/channels":
            if method != "POST":
                return self.error(handler, 405, "method_not_allowed", "Use POST.")
            channel_id, secret = secrets.token_hex(16), secrets.token_urlsafe(32)
            with self.lock:
                self.channels[channel_id] = {"hash": hashlib.sha256(secret.encode()).hexdigest(), "devices": {},
                                             "remembered": {}, "state": "new", "offlineAlertSent": False,
                                             "offlineExpected": []}
            return self.reply(handler, 201, {"channelId": channel_id, "pcSecret": secret, "heartbeatSeconds": 300, "offlineAfterSeconds": 900})
        parts = route.split("/")
        if len(parts) < 4 or parts[1] != "v1" or parts[2] != "c":
            return self.error(handler, 404, "not_found", "There is no such route on the relay.")
        channel_id, rest = parts[3], parts[4:]
        authorization = handler.headers.get("Authorization") or ""
        if not authorization.startswith("Bearer "):
            return self.error(handler, 401, "unauthorized", "Send the channel secret.")
        with self.lock:
            channel = self.channels.get(channel_id)
        if channel is None:
            return self.error(handler, 404, "channel_not_found", "This channel does not exist.")
        if not hmac.compare_digest(hashlib.sha256(authorization[7:].encode()).hexdigest(), channel["hash"]):
            return self.error(handler, 401, "unauthorized", "Wrong channel secret.")
        if not rest:
            if method == "GET":
                return self.reply(handler, 200, {"channelId": channel_id, "state": channel["state"], "devices": [
                    {"deviceId": device_id, "env": device["env"], "hasOfflineCiphertext": device["offlineCt"] is not None,
                     "lastDeliveryAt": device.get("lastDeliveryAt"), "lastError": None}
                    for device_id, device in channel["devices"].items()],
                    "unregisteredDevices": channel.get("unregisteredDevices", []), "maxDevices": 20})
            if method == "DELETE":
                with self.lock:
                    self.channels.pop(channel_id, None)
                return self.reply(handler, 200, {"status": "deleted"})
            return self.error(handler, 405, "method_not_allowed", "Wrong method.")
        if rest[0] == "devices" and len(rest) == 2:
            device_id = rest[1]
            if not DEVICE_ID.match(device_id):
                return self.error(handler, 400, "bad_request", "deviceId is invalid.")
            if method == "DELETE":
                existed = channel["devices"].pop(device_id, None) is not None
                return self.reply(handler, 200, {"status": "deleted", "existed": existed})
            if method != "PUT":
                return self.error(handler, 405, "method_not_allowed", "Wrong method.")
            if not isinstance(body, dict) or not re.match(r"^[0-9a-fA-F]{64,200}$", str(body.get("token"))) or len(body["token"]) % 2:
                return self.error(handler, 400, "bad_request", "token must be hex.")
            if body.get("env") not in ("sandbox", "production"):
                return self.error(handler, 400, "bad_request", "env must be \"sandbox\" or \"production\".")
            offline = body.get("offlineCt")
            if offline is not None and (not isinstance(offline, str) or len(offline) > 3072 or len(offline) % 4 or not BASE64.match(offline)):
                return self.error(handler, 400, "bad_request", "offlineCt must be standard base64.")
            token = body["token"].lower()
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            if token_hash in channel["remembered"]:
                if body.get("reregistered") is True:
                    del channel["remembered"][token_hash]
                else:
                    return self.error(handler, 410, "token_unregistered", "APNs reported this device token as no longer valid.",
                                      unregisteredAt="2026-10-23T18:15:00Z")
            created = device_id not in channel["devices"]
            if created and len(channel["devices"]) >= 20:
                return self.error(handler, 409, "device_limit", "The channel already has 20 devices.")
            replaced = [other for other, device in channel["devices"].items() if device["token"] == token and other != device_id]
            for other in replaced:
                del channel["devices"][other]
            previous = channel["devices"].get(device_id, {})
            channel["devices"][device_id] = {"token": token, "env": body["env"],
                                             "offlineCt": previous.get("offlineCt") if "offlineCt" not in body else offline}
            return self.reply(handler, 200, {"status": "registered", "created": created,
                                             "hasOfflineCiphertext": channel["devices"][device_id]["offlineCt"] is not None,
                                             "replaced": replaced})
        if len(rest) == 1 and method == "POST":
            if rest[0] == "hb":
                previous = channel["state"]
                sent, channel["offlineAlertSent"] = channel["offlineAlertSent"], False
                channel["state"] = "online"
                return self.reply(handler, 200, {"status": "ok", "state": "online", "previousState": previous,
                                                 "offlineAlertSent": sent, "offlineAfterSeconds": 900, "heartbeatSeconds": 300})
            if rest[0] == "offline-expected":
                if self.offline_expected_delay:
                    time.sleep(self.offline_expected_delay)
                channel["offlineExpected"].append(body)
                channel["state"] = "expected-offline"
                return self.reply(handler, 200, {"status": "ok", "state": "expected-offline", "offlineAt": None})
            if rest[0] == "notify":
                return self.notify(handler, channel, body)
        return self.error(handler, 404, "not_found", "There is no such route on the relay.")

    def notify(self, handler, channel, body):
        items = body.get("items") if isinstance(body, dict) else None
        if not isinstance(items, dict) or not 1 <= len(items) <= 20:
            return self.error(handler, 400, "bad_request", "items must name 1 to 20 devices.")
        for device_id, ciphertext in items.items():
            if not DEVICE_ID.match(device_id) or not isinstance(ciphertext, str) or len(ciphertext) > 3072 \
                    or len(ciphertext) % 4 or not BASE64.match(ciphertext) or len(base64.b64decode(ciphertext)) < 29:
                return self.error(handler, 400, "bad_request", "A ciphertext is invalid.")
        if body.get("level", "active") not in ("passive", "active", "timeSensitive", "time-sensitive"):
            return self.error(handler, 400, "bad_request", "level is invalid.")
        collapse = body.get("collapseId")
        if collapse is not None and not COLLAPSE.match(collapse):
            return self.error(handler, 400, "bad_request", "collapseId is invalid.")
        ttl = body.get("ttl", 3600)
        if not isinstance(ttl, int) or isinstance(ttl, bool) or not 0 <= ttl <= 604800:
            return self.error(handler, 400, "bad_request", "ttl is invalid.")
        results, sent = {}, 0
        for device_id in items:
            device = channel["devices"].get(device_id)
            if device is None:
                results[device_id] = {"status": "unknown_device", "retryable": False}
                continue
            behaviour = self.behaviour.get(device_id, "sent")
            if behaviour == "sent":
                results[device_id] = {"status": "sent", "apnsId": secrets.token_hex(8)}
                device["lastDeliveryAt"] = "2026-10-24T10:00:00Z"
                sent += 1
            elif behaviour == "unregistered":
                del channel["devices"][device_id]
                channel["remembered"][hashlib.sha256(device["token"].encode()).hexdigest()] = True
                results[device_id] = {"status": "unregistered", "apnsStatus": 410, "reason": "Unregistered", "retryable": False}
            elif behaviour == "retry":
                results[device_id] = {"status": "failed", "apnsStatus": 503, "reason": "ServiceUnavailable", "retryable": True}
            else:
                results[device_id] = {"status": "failed", "apnsStatus": 400, "reason": "BadDeviceToken", "retryable": False}
        return self.reply(handler, 200, {"results": results, "sent": sent, "failed": len(items) - sent})


# -- Encryption ---------------------------------------------------------------------------------

class EncryptionTests(unittest.TestCase):
    MESSAGE = {"v": 1, "pc": "Gaming-PC", "id": 12, "kind": "download.finished", "title": "Portal 2 finished downloading",
               "body": "Steam is done (12.0 GB). It's ready to play.", "ts": 1790000000, "link": "orbit://notifications"}

    def test_sealed_message_opens_with_the_device_key_and_id(self):
        sealed = push.seal(KEY_A, DEVICE_A, self.MESSAGE)
        self.assertTrue(BASE64.match(sealed))
        raw = base64.b64decode(sealed)
        plain = open_sealed(KEY_A, DEVICE_A, sealed)
        self.assertEqual(len(raw), 12 + len(plain) + 16)  # nonce ‖ ciphertext ‖ tag
        self.assertEqual(len(plain) % 128, 0)
        self.assertLessEqual(len(plain), 2048)
        self.assertEqual(json.loads(plain.decode("utf-8")), self.MESSAGE)
        self.assertEqual(plain, plain.rstrip(b" ") + b" " * (len(plain) - len(plain.rstrip(b" "))))
        self.assertEqual(plain.rstrip(b" "), json.dumps(self.MESSAGE, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))

    def test_aad_key_and_tampering_are_checked(self):
        sealed = push.seal(KEY_A, DEVICE_A, self.MESSAGE)
        for key, device in ((KEY_A, DEVICE_B), (KEY_B, DEVICE_A), (KEY_A, DEVICE_A.lower())):
            with self.subTest(device=device), self.assertRaises(InvalidTag):
                open_sealed(key, device, sealed)
        raw = bytearray(base64.b64decode(sealed))
        raw[20] ^= 1
        with self.assertRaises(InvalidTag):
            open_sealed(KEY_A, DEVICE_A, base64.b64encode(bytes(raw)).decode())

    def test_every_encryption_uses_a_fresh_nonce(self):
        nonces = {base64.b64decode(push.seal(KEY_A, DEVICE_A, self.MESSAGE))[:12] for _ in range(50)}
        self.assertEqual(len(nonces), 50)

    def test_unicode_and_long_text_stay_within_2048_padded_bytes(self):
        message = dict(self.MESSAGE, title="Ț" * 120, body="🎮 " * 500)
        plain = open_sealed(KEY_A, DEVICE_A, push.seal(KEY_A, DEVICE_A, message))
        self.assertLessEqual(len(plain), 2048)
        self.assertEqual(len(plain) % 128, 0)
        decoded = json.loads(plain.decode("utf-8"))
        self.assertTrue(decoded["body"].endswith("…"))
        self.assertEqual(decoded["title"], "Ț" * 120)
        self.assertLessEqual(len(push.seal(KEY_A, DEVICE_A, message)), 3072)

    def test_offline_message(self):
        message = push.offline_message("Gaming-PC", 1790000000)
        self.assertEqual(message, {"v": 1, "pc": "Gaming-PC", "id": 0, "kind": "pc.offline", "title": "PC offline",
                                   "body": "Gaming-PC stopped responding.", "ts": 1790000000, "link": "orbit://notifications"})

    def test_collapse_ids_follow_the_protocol_formula_and_are_opaque(self):
        key = bytes(32)
        expected = "c." + base64.urlsafe_b64encode(hmac.new(key, b"download.steam:620", hashlib.sha256).digest()).decode()[:16]
        self.assertEqual(push.collapse_id(key, "download.steam:620"), expected)
        self.assertTrue(COLLAPSE.match(expected))
        self.assertNotIn("620", expected[2:] if "620" not in expected else "")
        self.assertNotEqual(push.collapse_id(key, "download.steam:620"), push.collapse_id(bytes([1] * 32), "download.steam:620"))

    def test_delivery_policy_table(self):
        cases = [
            ({"kind": "temperature.high", "level": "timeSensitive", "data": {"sensor": "gpu"}}, ("timeSensitive", 900, "temperature.gpu", None)),
            ({"kind": "download.finished", "level": "active", "data": {"id": "steam:620"}}, ("active", 21600, "download.steam:620", None)),
            ({"kind": "download.failed", "level": "active", "data": {"id": "epic:Sugar"}}, ("active", 21600, "download.epic:Sugar", None)),
            ({"kind": "downloads.allFinished", "level": "active"}, ("active", 21600, "downloads", None)),
            ({"kind": "task.finished", "level": "active", "data": {"taskID": "ab"}}, ("active", 21600, "task.ab", None)),
            ({"kind": "power.scheduled", "level": "timeSensitive", "data": {"delaySeconds": 90}}, ("timeSensitive", 90, "power", None)),
            ({"kind": "power.executing", "level": "active"}, ("active", 300, "power", None)),
            ({"kind": "power.cancelled", "level": "active"}, ("active", 600, "power", None)),
            ({"kind": "pc.online", "level": "active"}, ("active", 3600, None, "offline")),
            ({"kind": "summary.ready", "level": "passive"}, ("passive", 604800, "summary", None)),
            ({"kind": "webcam.connected", "level": "active"}, ("active", 300, "webcam", None)),
        ]
        for event, expected in cases:
            with self.subTest(kind=event["kind"]):
                self.assertEqual(push.delivery_policy(event), expected)

    def test_key_and_url_validation(self):
        self.assertEqual(push.decode_key(b64(KEY_A)), KEY_A)
        self.assertEqual(push.decode_key(base64.urlsafe_b64encode(KEY_B).decode().rstrip("=")), KEY_B)
        for bad in (None, "", "abc", b64(bytes(16)), b64(bytes(48)), "!" * 44):
            with self.subTest(key=bad), self.assertRaises(ValueError):
                push.decode_key(bad)
        self.assertEqual(push.validate_relay_url("https://relay.example.workers.dev/"), "https://relay.example.workers.dev")
        self.assertEqual(push.validate_relay_url("http://127.0.0.1:8787"), "http://127.0.0.1:8787")
        self.assertEqual(push.validate_relay_url("http://localhost:8787/"), "http://localhost:8787")
        for bad in ("http://relay.example.com", "ftp://x", "https://user:pw@relay.example.com", "https://relay?x=1", "relay.example.com", ""):
            with self.subTest(url=bad), self.assertRaises(ValueError):
                push.validate_relay_url(bad)


# -- Service against the fake relay -----------------------------------------------------------------

class ServiceTestCase(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.relay = FakeRelay()
        self.addCleanup(self.relay.close)
        self.settings = settings.SettingsStore(self.folder / "settings.json")
        self.store = push.PushStore(self.folder / "push-secrets.json")
        self.mono = Clock(1000.0)
        self.wall = Clock(1_790_000_000.0)
        self.environ = {"ORBIT_PUSH_RELAY_URL": self.relay.url}
        self.back_online = MagicMock()
        self.boot_task = False
        # Relay trouble is logged on purpose; keep the test output readable.
        logger = logging.getLogger("orbit.push")
        self.addCleanup(logger.setLevel, logger.level)
        logger.setLevel(logging.CRITICAL)

    def service(self, **options):
        defaults = dict(store=self.store, settings=self.settings, agent_version="4.4.0", clock=self.wall, monotonic=self.mono,
                        hostname="Gaming-PC", environ=self.environ, on_back_online=self.back_online,
                        boot_task_installed=lambda: self.boot_task)
        defaults.update(options)
        return push.PushService(**defaults)

    def advance(self, seconds):
        self.mono.now += seconds
        self.wall.now += seconds

    def register(self, service, device=DEVICE_A, key=KEY_A, token=TOKEN_A, environment="sandbox", name="Dimi's iPhone"):
        return service.register({"deviceID": device, "apnsToken": token, "environment": environment, "key": b64(key), "deviceName": name})

    def channel(self):
        return self.store.channel()

    def event(self, ident, kind="download.finished", level="active", data=None, title="Portal 2 finished downloading", body="Ready."):
        return {"id": ident, "ts": "2026-10-24T10:00:00Z", "kind": kind, "level": level, "title": title, "body": body,
                "data": data if data is not None else {"id": "steam:620"}}


class DisabledRelayTests(ServiceTestCase):
    def test_nothing_is_sent_without_a_relay_url(self):
        self.assertEqual(push.DEFAULT_RELAY_URL, "")
        opener = MagicMock()
        opener.open.side_effect = AssertionError("the network must not be used")
        service = self.service(environ={}, opener=opener)
        self.assertEqual(self.register(service), {"status": "registered", "relay": "disabled"})
        self.assertFalse(service.dispatch(self.event(1)))
        for _ in range(5):
            service.step()
            self.advance(400)
        self.assertTrue(service.planned_offline("sleep") is False)
        opener.open.assert_not_called()
        self.assertEqual(self.relay.requests, [])
        status = service.status()
        self.assertFalse(status["relayConfigured"])
        self.assertEqual(status["devices"][0]["deviceName"], "Dimi's iPhone")

    def test_settings_override_the_environment(self):
        service = self.service()
        self.settings.update("push", {"relayURL": ""})
        self.assertEqual(service.relay_url(), ("", None))
        self.settings.update("push", {"relayURL": "http://relay.example.com"})
        url, problem = service.relay_url()
        self.assertEqual(url, "")
        self.assertIn("https://", problem)
        status = service.status()
        self.assertFalse(status["relayConfigured"])
        self.assertIn("https://", status["relayError"])
        self.settings.update("push", {"relayURL": self.relay.url + "/"})
        self.assertEqual(service.relay_url(), (self.relay.url, None))


class RegistrationTests(ServiceTestCase):
    def test_first_registration_creates_a_channel_puts_the_device_and_beats(self):
        service = self.service()
        service.step()  # agent start with no devices: nothing to do
        self.assertEqual(self.relay.requests, [])
        self.assertEqual(self.register(service), {"status": "registered", "relay": "enabled"})
        service.step()
        channel_id = self.channel()["channelId"]
        # The first heartbeat after start also reads the channel status (then about hourly).
        self.assertEqual(self.relay.paths(), [("POST", "/v1/channels"), ("PUT", f"/v1/c/{channel_id}/devices/{DEVICE_A}"),
                                              ("POST", f"/v1/c/{channel_id}/hb"), ("GET", f"/v1/c/{channel_id}")])
        for entry in self.relay.requests:
            self.assertEqual(entry["headers"]["User-Agent"], "OrbitAgent/4.4.0")
        put = self.relay.last("PUT", DEVICE_A)
        self.assertEqual(put["headers"]["Authorization"], f"Bearer {self.channel()['pcSecret']}")
        self.assertEqual((put["body"]["token"], put["body"]["env"], put["body"]["reregistered"]), (TOKEN_A, "sandbox", True))
        offline = json.loads(open_sealed(KEY_A, DEVICE_A, put["body"]["offlineCt"]))
        self.assertEqual((offline["id"], offline["kind"], offline["title"], offline["body"], offline["pc"]),
                         (0, "pc.offline", "PC offline", "Gaming-PC stopped responding.", "Gaming-PC"))
        channel = self.channel()
        self.assertEqual(set(channel), {"relayURL", "channelId", "pcSecret", "collapseKey", "createdAt"})
        self.assertEqual(channel["relayURL"], self.relay.url)
        self.assertEqual(len(base64.b64decode(channel["collapseKey"])), 32)
        if os.name != "nt":
            self.assertEqual((self.folder / "push-secrets.json").stat().st_mode & 0o777, 0o600)
        self.assertNotIn(channel["pcSecret"], (self.folder / "settings.json").read_text() if (self.folder / "settings.json").exists() else "")

    def test_registration_waits_briefly_for_the_running_worker(self):
        service = self.service()
        stop = threading.Event()
        self.addCleanup(stop.set)
        service.mono = time.monotonic
        real = self.service(monotonic=time.monotonic, clock=time.time)
        thread = real.start(stop)
        self.assertEqual(self.register(real), {"status": "registered", "relay": "enabled"})
        self.assertIn(("POST", "/v1/channels"), self.relay.paths())
        self.assertTrue(any(method == "PUT" for method, _ in self.relay.paths()))
        stop.set()
        real.wake()
        thread.join(3)

    def test_validation_and_device_limit(self):
        service = self.service(environ={})
        cases = [
            ("x", "JSON object"),
            ({"deviceID": "-bad", "apnsToken": TOKEN_A, "environment": "sandbox", "key": b64(KEY_A)}, "deviceID"),
            ({"deviceID": DEVICE_A, "apnsToken": "zz" * 32, "environment": "sandbox", "key": b64(KEY_A)}, "apnsToken"),
            ({"deviceID": DEVICE_A, "apnsToken": "abc" * 31, "environment": "sandbox", "key": b64(KEY_A)}, "apnsToken"),
            ({"deviceID": DEVICE_A, "apnsToken": TOKEN_A, "environment": "debug", "key": b64(KEY_A)}, "environment"),
            ({"deviceID": DEVICE_A, "apnsToken": TOKEN_A, "environment": "sandbox", "key": b64(bytes(16))}, "32-byte"),
        ]
        for body, words in cases:
            with self.subTest(body=body), self.assertRaises(ValueError) as refused:
                service.register(body)
            self.assertIn(words, str(refused.exception))
        for index in range(push.MAX_DEVICES):
            self.register(service, device=f"D{index}", token=f"{index:02x}" * 32)
        with self.assertRaises(OverflowError):
            self.register(service, device="D99", token="99" * 32)
        self.register(service, device="D3", token="33" * 32)  # updating an existing device is fine
        self.assertEqual(self.store.device("D3")["apnsToken"], "33" * 32)

    def test_re_registration_clears_a_remembered_410(self):
        service = self.service()
        self.register(service)
        service.step()
        # APNs rejected the token during an offline alert; the relay remembers it.
        channel = self.relay.channels[self.channel()["channelId"]]
        channel["remembered"][hashlib.sha256(TOKEN_A.encode()).hexdigest()] = True
        channel["devices"].pop(DEVICE_A)
        self.relay.clear()
        self.register(service)  # the phone is alive and registers again
        service.step()
        put = self.relay.last("PUT", DEVICE_A)
        self.assertTrue(put["body"]["reregistered"])
        self.assertIn(DEVICE_A, channel["devices"])
        self.assertTrue(self.store.device(DEVICE_A)["active"])

    def test_replaced_registrations_are_dropped_locally(self):
        service = self.service()
        self.register(service, device=DEVICE_A, token=TOKEN_A)
        service.step()
        # Reinstall: same token, new deviceID.
        self.register(service, device=DEVICE_B, key=KEY_B, token=TOKEN_A)
        service.step()
        self.assertIsNone(self.store.device(DEVICE_A))
        self.assertIsNotNone(self.store.device(DEVICE_B))


class AgentStartTests(ServiceTestCase):
    def seed(self):
        first = self.service()
        self.register(first, device=DEVICE_A, key=KEY_A, token=TOKEN_A)
        self.register(first, device=DEVICE_B, key=KEY_B, token=TOKEN_B, environment="production")
        first.step()
        self.relay.clear()
        return self.relay.channels[self.channel()["channelId"]]

    def test_start_puts_every_active_device_without_reregistered_then_beats(self):
        channel = self.seed()
        # The relay deleted B after an APNs 410 during an offline alert the agent never saw.
        channel["devices"].pop(DEVICE_B)
        channel["remembered"][hashlib.sha256(TOKEN_B.encode()).hexdigest()] = True
        service = self.service()
        service.step()
        channel_id = self.channel()["channelId"]
        self.assertEqual(self.relay.paths(), [("PUT", f"/v1/c/{channel_id}/devices/{DEVICE_A}"),
                                              ("PUT", f"/v1/c/{channel_id}/devices/{DEVICE_B}"), ("POST", f"/v1/c/{channel_id}/hb"),
                                              ("GET", f"/v1/c/{channel_id}")])
        for entry in self.relay.requests[:2]:
            self.assertFalse(entry["body"]["reregistered"])
        self.assertTrue(self.store.device(DEVICE_A)["active"])
        self.assertEqual((self.store.device(DEVICE_B)["active"], self.store.device(DEVICE_B)["lastError"]), (False, "Unregistered"))
        status = service.status()
        self.assertTrue(status["relayConfigured"])
        self.assertIsNotNone(status["lastHeartbeatAt"])
        self.assertEqual({device["deviceID"]: device["active"] for device in status["devices"]}, {DEVICE_A: True, DEVICE_B: False})
        # The fresh offline message uses a new nonce.
        offline_now = channel["devices"][DEVICE_A]["offlineCt"]
        self.assertTrue(open_sealed(KEY_A, DEVICE_A, offline_now))

    def test_heartbeat_every_five_minutes_and_back_online(self):
        self.seed()
        service = self.service()
        service.step()
        self.relay.clear()
        self.advance(299)
        service.step()
        self.assertEqual(self.relay.paths(), [])
        self.advance(1)
        channel = self.relay.channels[self.channel()["channelId"]]
        channel["offlineAlertSent"] = True
        service.step()
        self.assertEqual([path for _, path in self.relay.paths()], [f"/v1/c/{self.channel()['channelId']}/hb"])
        self.back_online.assert_called_once_with()

    def test_status_sync_marks_devices_the_relay_dropped(self):
        channel = self.seed()
        channel["unregisteredDevices"] = [{"deviceId": DEVICE_B, "unregisteredAt": "2099-01-01T00:00:00Z"}]
        service = self.service()
        service.step()
        self.assertFalse(self.store.device(DEVICE_B)["active"])
        self.assertEqual(self.store.device(DEVICE_A)["lastDeliveryAt"], None)


class NotifyTests(ServiceTestCase):
    def setUp(self):
        super().setUp()
        self.svc = self.service()
        self.register(self.svc, device=DEVICE_A, key=KEY_A, token=TOKEN_A)
        self.register(self.svc, device=DEVICE_B, key=KEY_B, token=TOKEN_B)
        self.svc.step()
        self.relay.clear()

    def notifies(self):
        return [entry for entry in self.relay.requests if entry["route"].endswith("/notify")]

    def test_one_notify_per_event_with_a_ciphertext_per_device(self):
        self.assertTrue(self.svc.dispatch(self.event(41, data={"id": "steam:620"})))
        self.svc.step()
        [request] = self.notifies()
        body = request["body"]
        self.assertEqual(set(body["items"]), {DEVICE_A, DEVICE_B})
        key = base64.b64decode(self.channel()["collapseKey"])
        self.assertEqual(body["collapseId"], push.collapse_id(key, "download.steam:620"))
        self.assertNotIn("steam", body["collapseId"])
        self.assertEqual((body["level"], body["ttl"]), ("active", 21600))
        for device, device_key in ((DEVICE_A, KEY_A), (DEVICE_B, KEY_B)):
            message = json.loads(open_sealed(device_key, device, body["items"][device]))
            self.assertEqual(message, {"v": 1, "pc": "Gaming-PC", "id": 41, "kind": "download.finished",
                                       "title": "Portal 2 finished downloading", "body": "Ready.",
                                       "ts": 1792836000, "link": "orbit://notifications"})
        self.assertEqual(self.store.device(DEVICE_A)["lastDeliveryAt"], "2026-09-21T14:13:20Z")
        self.assertEqual(self.svc.pending(), 0)
        self.assertTrue(self.svc.flush(0.1))

    def test_pc_online_uses_the_literal_offline_collapse_id_and_temperature_is_time_sensitive(self):
        self.svc.dispatch(self.event(1, kind="pc.online", data={"reason": "started"}))
        self.svc.dispatch(self.event(2, kind="temperature.high", level="timeSensitive", data={"sensor": "cpu"}))
        self.svc.dispatch(self.event(3, kind="power.scheduled", level="timeSensitive", data={"delaySeconds": 60}))
        self.svc.step()
        bodies = [entry["body"] for entry in self.notifies()]
        self.assertEqual(bodies[0]["collapseId"], "offline")
        self.assertEqual((bodies[1]["level"], bodies[1]["ttl"]), ("timeSensitive", 900))
        self.assertEqual((bodies[2]["level"], bodies[2]["ttl"]), ("timeSensitive", 60))
        self.assertTrue(bodies[1]["collapseId"].startswith("c."))
        self.assertEqual(bodies[2]["collapseId"], push.collapse_id(base64.b64decode(self.channel()["collapseKey"]), "power"))

    def test_retryable_failures_are_retried_for_those_devices_only(self):
        self.relay.behaviour[DEVICE_B] = "retry"
        self.svc.dispatch(self.event(7))
        self.svc.step()
        first = self.notifies()[0]["body"]["items"][DEVICE_B]
        self.relay.behaviour[DEVICE_B] = "sent"
        self.advance(29)
        self.svc.step()
        self.assertEqual(len(self.notifies()), 1)
        self.advance(1)
        self.svc.step()
        retry = self.notifies()[1]["body"]
        self.assertEqual(set(retry["items"]), {DEVICE_B})
        self.assertEqual(retry["items"][DEVICE_B], first)  # same ciphertext, no re-encryption
        self.assertEqual(retry["ttl"], 21600 - 30)
        self.assertEqual(self.svc.pending(), 0)

    def test_retries_stop_after_the_schedule(self):
        self.relay.behaviour[DEVICE_B] = "retry"
        self.svc.dispatch(self.event(7))
        for wait in (0, 30, 120, 600, 1800):
            self.advance(wait)
            self.svc.step()
        self.assertEqual(len(self.notifies()), 4)  # first try + 30 s + 2 min + 10 min
        self.assertEqual(self.svc.pending(), 0)

    def test_unregistered_and_permanent_failures(self):
        self.relay.behaviour[DEVICE_A] = "unregistered"
        self.relay.behaviour[DEVICE_B] = "permanent"
        self.svc.dispatch(self.event(8))
        self.svc.step()
        self.assertEqual((self.store.device(DEVICE_A)["active"], self.store.device(DEVICE_A)["lastError"]), (False, "Unregistered"))
        self.assertEqual(self.store.device(DEVICE_B)["lastError"], "BadDeviceToken")
        self.assertTrue(self.store.device(DEVICE_B)["active"])
        self.assertEqual(self.svc.pending(), 0)
        self.relay.behaviour.clear()
        self.svc.dispatch(self.event(9))
        self.svc.step()
        self.assertEqual(set(self.notifies()[-1]["body"]["items"]), {DEVICE_B})

    def test_unknown_device_is_put_once_then_resent(self):
        channel = self.relay.channels[self.channel()["channelId"]]
        channel["devices"].pop(DEVICE_A)
        self.svc.dispatch(self.event(10))
        self.svc.step()
        self.svc.step()
        routes = [route for _, route in self.relay.paths()]
        self.assertEqual([route.rsplit("/", 1)[-1] for route in routes], ["notify", DEVICE_A, "notify"])
        self.assertEqual(set(self.notifies()[1]["body"]["items"]), {DEVICE_A})
        self.assertTrue(self.store.device(DEVICE_A)["active"])
        # A second time the device is unknown, it is marked inactive instead of looping.
        channel["devices"].pop(DEVICE_A)
        self.svc.dispatch(self.event(11))
        self.svc.step()
        self.assertFalse(self.store.device(DEVICE_A)["active"])

    def test_queue_while_the_relay_is_unreachable_and_drop_after_ttl(self):
        self.relay.down = True
        self.svc.dispatch(self.event(20, kind="temperature.high", level="timeSensitive", data={"sensor": "cpu"}))  # ttl 900
        self.svc.dispatch(self.event(21))  # ttl 6 h
        self.svc.step()
        self.assertEqual(self.svc.pending(), 2)
        self.assertIn("Could not reach the push relay", self.svc.status()["relayError"])
        self.relay.down = False
        self.advance(29)
        self.relay.clear()
        self.svc.step()
        self.assertEqual(self.notifies(), [])  # still backing off (30 s)
        self.relay.down = True
        for wait in (1, 120, 600):  # 30 s, then 2 min, then 10 min backoff
            self.advance(wait)
            self.svc.step()
        self.relay.down = False
        self.relay.clear()
        self.advance(1800)  # past the temperature alert's 15-minute TTL
        self.svc.step()
        self.assertEqual([entry["body"]["collapseId"] for entry in self.notifies()],
                         [push.collapse_id(base64.b64decode(self.channel()["collapseKey"]), "download.steam:620")])
        self.assertEqual(self.svc.pending(), 0)

    def test_rate_limit_honours_retry_after(self):
        self.relay.force("POST", r"/notify$", 429, {"error": "rate_limited", "message": "Too many requests.", "retryAfterSeconds": 77},
                         {"Retry-After": "77"})
        self.svc.dispatch(self.event(30))
        self.svc.step()
        self.advance(76)
        self.svc.step()
        self.assertEqual(len(self.notifies()), 1)
        self.advance(1)
        self.svc.step()
        self.assertEqual(len(self.notifies()), 2)
        self.assertEqual(self.svc.pending(), 0)

    def test_apns_not_configured_retries_every_ten_minutes_but_heartbeats_continue(self):
        self.relay.force("POST", r"/notify$", 503, {"error": "apns_not_configured", "message": "No APNs key."})
        self.svc.dispatch(self.event(31))
        self.svc.step()
        self.relay.clear()
        self.advance(300)
        self.svc.step()
        self.assertEqual([route.rsplit("/", 1)[-1] for _, route in self.relay.paths()], ["hb"])
        self.advance(300)
        self.svc.step()
        self.assertIn("notify", [route.rsplit("/", 1)[-1] for _, route in self.relay.paths()])
        self.assertEqual(self.svc.pending(), 0)

    def test_a_request_bug_is_dropped_not_retried(self):
        self.relay.force("POST", r"/notify$", 400, {"error": "bad_request", "message": "items must name at least one device."})
        self.svc.dispatch(self.event(32))
        with self.assertLogs("orbit.push", "ERROR"):
            self.svc.step()
        self.assertEqual(self.svc.pending(), 0)
        self.advance(3600)
        self.svc.step()
        self.assertEqual(len(self.notifies()), 1)

    def test_channel_recovery_after_404_then_at_most_every_ten_minutes(self):
        old = self.channel()
        del self.relay.channels[old["channelId"]]  # retention purge or relay reset
        self.svc.dispatch(self.event(40))
        self.svc.step()  # notify → 404 → recovery
        self.svc.step()  # the event goes out on the new channel
        new = self.channel()
        self.assertNotEqual(new["channelId"], old["channelId"])
        self.assertNotEqual(new["collapseKey"], old["collapseKey"])
        routes = [(method, route.replace(new["channelId"], "NEW").replace(old["channelId"], "OLD")) for method, route in self.relay.paths()]
        self.assertEqual(routes, [("POST", "/v1/c/OLD/notify"), ("POST", "/v1/channels"),
                                  ("PUT", f"/v1/c/NEW/devices/{DEVICE_A}"), ("PUT", f"/v1/c/NEW/devices/{DEVICE_B}"),
                                  ("POST", "/v1/c/NEW/hb"), ("POST", "/v1/c/NEW/notify")])
        for entry in self.relay.requests:
            if entry["method"] == "PUT":
                self.assertFalse(entry["body"]["reregistered"])
        self.assertEqual(self.notifies()[-1]["body"]["collapseId"],
                         push.collapse_id(base64.b64decode(new["collapseKey"]), "download.steam:620"))
        self.assertEqual(self.svc.pending(), 0)
        # Lost again a minute later (a 401 this time): no second recovery inside 10 minutes.
        self.relay.clear()
        self.advance(60)
        tampered = dict(new, pcSecret="x" * 43)
        self.store.set_channel(tampered)
        self.svc.dispatch(self.event(41))
        self.svc.step()
        self.assertNotIn(("POST", "/v1/channels"), self.relay.paths())
        self.assertIn("no longer knows this PC", self.svc.status()["relayError"])
        self.advance(500)
        self.svc.step()
        self.assertNotIn(("POST", "/v1/channels"), self.relay.paths())
        self.advance(41)
        self.svc.step()
        self.assertIn(("POST", "/v1/channels"), self.relay.paths())
        self.svc.step()
        self.assertEqual(self.svc.pending(), 0)

    def test_removing_the_last_device_deletes_the_channel(self):
        channel_id = self.channel()["channelId"]
        self.assertEqual(self.svc.unregister(DEVICE_A), {"status": "removed", "existed": True})
        self.svc.step()
        self.assertEqual(self.relay.paths(), [("DELETE", f"/v1/c/{channel_id}/devices/{DEVICE_A}")])
        self.assertIsNotNone(self.channel())
        self.svc.unregister(DEVICE_B)
        self.svc.step()
        self.assertEqual(self.relay.paths()[-2:], [("DELETE", f"/v1/c/{channel_id}/devices/{DEVICE_B}"), ("DELETE", f"/v1/c/{channel_id}")])
        self.assertIsNone(self.channel())
        self.assertNotIn(channel_id, self.relay.channels)
        self.assertEqual(self.svc.unregister(DEVICE_B), {"status": "removed", "existed": False})
        self.relay.clear()
        self.advance(900)
        self.svc.step()
        self.assertEqual(self.relay.paths(), [])  # no channel, no heartbeats

    def test_a_new_relay_url_moves_the_channel(self):
        other = FakeRelay()
        self.addCleanup(other.close)
        old = self.channel()
        self.environ["ORBIT_PUSH_RELAY_URL"] = other.url
        self.svc.step()
        self.assertNotIn(old["channelId"], self.relay.channels)
        self.assertEqual(self.relay.paths(), [("DELETE", f"/v1/c/{old['channelId']}")])
        self.assertEqual(self.channel()["relayURL"], other.url)
        self.assertEqual([method for method, _ in other.paths()], ["POST", "PUT", "PUT", "POST"])
        # Turning the relay off deletes the channel and stops all traffic.
        self.environ["ORBIT_PUSH_RELAY_URL"] = ""
        self.svc.step()
        self.assertIsNone(self.channel())
        other.clear()
        self.assertFalse(self.svc.dispatch(self.event(50)))
        self.advance(900)
        self.svc.step()
        self.assertEqual(other.paths(), [])

    def test_secrets_never_reach_the_log(self):
        stream = []

        class Capture(logging.Handler):
            def emit(self, record):
                stream.append(record.getMessage())
        handler = Capture(logging.DEBUG)
        logger = logging.getLogger("orbit.push")
        logger.addHandler(handler)
        old_level = logger.level
        logger.setLevel(logging.DEBUG)
        self.addCleanup(logger.removeHandler, handler)
        self.addCleanup(logger.setLevel, old_level)
        del self.relay.channels[self.channel()["channelId"]]
        self.relay.down = False
        self.svc.dispatch(self.event(60))
        self.svc.step()
        self.relay.down = True
        self.svc.dispatch(self.event(61))
        self.advance(1000)
        self.svc.step()
        text = "\n".join(stream)
        self.assertTrue(text)
        for secret in (self.channel()["pcSecret"], self.channel()["collapseKey"], b64(KEY_A), TOKEN_A, TOKEN_B):
            self.assertNotIn(secret, text)


class PlannedOfflineTests(ServiceTestCase):
    def setUp(self):
        super().setUp()
        self.svc = self.service()
        self.register(self.svc)
        self.svc.step()

    def offline_bodies(self):
        return self.relay.channels[self.channel()["channelId"]]["offlineExpected"]

    def test_sleep_and_shutdown_send_an_empty_body_restart_waits_only_with_the_boot_task(self):
        self.assertTrue(self.svc.planned_offline("sleep"))
        self.assertTrue(self.svc.planned_offline("restart"))
        self.boot_task = True
        self.assertTrue(self.svc.planned_offline("restart"))
        self.assertTrue(self.svc.planned_offline("shutdown"))
        self.assertEqual(self.offline_bodies(), [{}, {}, {"backWithinSeconds": 900}, {}])
        entry = self.relay.last("POST", "/offline-expected")
        self.assertEqual(entry["headers"]["User-Agent"], "OrbitAgent/4.4.0")

    def test_a_hanging_relay_cannot_hold_the_power_action(self):
        self.assertEqual(push.OFFLINE_EXPECTED_TIMEOUT, 3.0)
        self.relay.offline_expected_delay = 2.0
        with patch.object(push, "OFFLINE_EXPECTED_TIMEOUT", 0.3):
            started = time.monotonic()
            self.assertFalse(self.svc.planned_offline("sleep"))
            self.assertLess(time.monotonic() - started, 1.5)

    def test_through_the_agent_power_hooks(self):
        import orbit_agent as agent
        self.boot_task = True
        windll = MagicMock()
        push.set_shared_service(self.svc)
        self.addCleanup(push.set_shared_service, None)
        self.assertIn(push.planned_offline, agent.BEFORE_POWER_HOOKS)
        self.assertTrue(push.planned_offline.accepts_action)
        with patch.object(agent, "require_windows"), patch.object(agent.ctypes, "windll", windll, create=True), \
             patch.object(agent.subprocess, "run") as run:
            agent.perform_action("restart")
            agent.perform_action("sleep")
            agent.perform_action("mute")
        run.assert_called_once()
        windll.powrprof.SetSuspendState.assert_called_once_with(0, 0, 0)
        self.assertEqual(self.offline_bodies(), [{"backWithinSeconds": 900}, {}])
        push.set_shared_service(None)
        self.assertFalse(push.planned_offline("sleep"))


class RouteTests(ServiceTestCase):
    def setUp(self):
        super().setUp()
        self.svc = self.service()

        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")
        app = FastAPI()
        app.include_router(push.create_push_router(verify, lambda: self.svc))
        self.client = TestClient(app, base_url="https://testserver")
        self.addCleanup(self.client.close)
        self.http = TestClient(app)
        self.addCleanup(self.http.close)

    def body(self, **changes):
        return {"deviceID": DEVICE_A, "apnsToken": TOKEN_A, "environment": "production", "key": b64(KEY_A),
                "deviceName": "iPhone 17 Pro", **changes}

    def test_register_status_delete(self):
        response = self.client.post("/api/push/register", json=self.body(), headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "registered", "relay": "enabled"})
        self.assertEqual(response.headers["cache-control"], "no-store")
        status = self.client.get("/api/push/status", headers=AUTH).json()
        self.assertEqual(status["relayConfigured"], True)
        [device] = status["devices"]
        self.assertEqual({key: device[key] for key in ("deviceID", "deviceName", "lastDeliveryAt", "lastError", "active")},
                         {"deviceID": DEVICE_A, "deviceName": "iPhone 17 Pro", "lastDeliveryAt": None, "lastError": None, "active": True})
        self.assertRegex(device["registeredAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertNotIn("key", device)
        self.assertNotIn("apnsToken", json.dumps(status))
        self.assertEqual(self.client.delete(f"/api/push/devices/{DEVICE_A}", headers=AUTH).json(), {"status": "removed", "existed": True})
        self.assertEqual(self.client.delete(f"/api/push/devices/{DEVICE_A}", headers=AUTH).json(), {"status": "removed", "existed": False})
        self.assertIn(self.client.delete("/api/push/devices/..%2F..%2Fx", headers=AUTH).status_code, (404, 422))
        self.assertEqual(self.client.delete("/api/push/devices/-x", headers=AUTH).status_code, 422)

    def test_errors(self):
        response = self.client.post("/api/push/register", json=self.body(environment="beta"), headers=AUTH)
        self.assertEqual(response.status_code, 422)
        self.assertIn("environment", response.json()["detail"])
        for index in range(push.MAX_DEVICES):
            self.store.put_device(f"D{index}", {"apnsToken": TOKEN_B, "environment": "sandbox", "key": b64(KEY_B), "active": True})
        self.assertEqual(self.client.post("/api/push/register", json=self.body(), headers=AUTH).status_code, 409)

    def test_token_then_https(self):
        self.assertEqual(self.client.get("/api/push/status").status_code, 401)
        self.assertEqual(self.client.post("/api/push/register", json=self.body()).status_code, 401)
        self.assertEqual(self.client.delete(f"/api/push/devices/{DEVICE_A}").status_code, 401)
        self.assertEqual(self.http.get("/api/push/status", headers=AUTH).status_code, 426)
        self.assertEqual(self.http.post("/api/push/register", json=self.body(), headers=AUTH).status_code, 426)
        self.assertEqual(self.http.delete(f"/api/push/devices/{DEVICE_A}", headers=AUTH).status_code, 426)
        self.assertIsNone(self.store.device(DEVICE_A))


class AgentLifespanTests(unittest.TestCase):
    """The whole F1 wiring in the agent's lifespan, with every file in a temporary folder."""

    def test_register_then_an_event_reaches_the_relay(self):
        import orbit_agent as agent
        import orbit_alerts
        import orbit_events
        relay = FakeRelay()
        self.addCleanup(relay.close)
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        base = Path(folder.name)
        store = settings.SettingsStore(base / "Orbit" / "settings.json")
        settings.set_shared_store(store)
        self.addCleanup(settings.set_shared_store, None)
        orbit_alerts._reset_online_state()
        self.addCleanup(orbit_alerts._reset_online_state)
        environment = {"LOCALAPPDATA": str(base), "ORBIT_PUSH_RELAY_URL": relay.url,
                       "ORBIT_STEAM_PATH": str(base / "no-steam"), "ORBIT_EPIC_MANIFESTS": str(base / "no-epic"),
                       "ORBIT_EPIC_LAUNCHER_INSTALLED": str(base / "no-epic.dat"), "ORBIT_GOG_GAMES_KEY": r"HKLM\SOFTWARE\NoGog"}
        with patch.dict(os.environ, environment), \
             patch.object(agent, "load_api_token", return_value=TOKEN), \
             patch.object(agent, "load_widget_token", return_value="widget-token-with-more-than-24-characters"), \
             patch.object(agent, "inventory_worker"), patch.object(agent, "telemetry_worker"), \
             patch.object(agent, "sensor_worker"), patch.object(agent, "SessionRecorder"), \
             patch.object(orbit_events.orbit_notify, "notify"):
            with TestClient(agent.app, base_url="https://testserver") as client:
                # pc.online was announced once (no phones yet, so nothing went to the relay).
                events = client.get("/api/events", headers=AUTH).json()["events"]
                self.assertEqual([event["kind"] for event in events], ["pc.online"])
                self.assertEqual(client.get("/api/capabilities", headers=AUTH).status_code, 200)
                response = client.post("/api/push/register", headers=AUTH, json={
                    "deviceID": DEVICE_A, "apnsToken": TOKEN_A, "environment": "sandbox", "key": b64(KEY_A), "deviceName": "iPhone"})
                self.assertEqual(response.json(), {"status": "registered", "relay": "enabled"})
                self.assertEqual(client.get("/api/downloads", headers=AUTH).json()["stores"], {"steam": False, "epic": False, "gog": False})
                self.assertEqual(client.get("/api/power/after", headers=AUTH).json(), {"rule": None})
                self.assertEqual(client.get("/api/tasks", headers=AUTH).json(), {"tasks": []})
                self.assertEqual(client.get("/api/alerts", headers=AUTH).json()["pcToasts"], True)
                event = orbit_events.emit("task.finished", "Blender finished", "The program closed.", data={"taskID": "t1"})
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and not any(route.endswith("/notify") for _, route in relay.paths()):
                    time.sleep(0.05)
                notify = relay.last("POST", "/notify")
                self.assertIsNotNone(notify)
                message = json.loads(open_sealed(KEY_A, DEVICE_A, notify["body"]["items"][DEVICE_A]))
                self.assertEqual((message["id"], message["kind"], message["title"]), (event["id"], "task.finished", "Blender finished"))
                self.assertTrue((base / "Orbit" / "push-secrets.json").exists())
            self.assertIsNone(push.shared_service())
        self.assertIn(push.planned_offline, agent.BEFORE_POWER_HOOKS)  # stays registered for the next start

    def test_a_failing_notification_start_never_stops_the_agent(self):
        import orbit_agent as agent
        with patch.object(agent, "load_api_token", return_value=TOKEN), \
             patch.object(agent, "load_widget_token", return_value="widget-token-with-more-than-24-characters"), \
             patch.object(agent, "inventory_worker"), patch.object(agent, "telemetry_worker"), \
             patch.object(agent, "sensor_worker"), patch.object(agent, "SessionRecorder"), patch.object(agent, "EventLog"), \
             patch.object(agent.orbit_push, "PushService", side_effect=RuntimeError("broken")):
            with self.assertLogs("orbit", "ERROR"):
                with TestClient(agent.app, base_url="https://testserver") as client:
                    self.assertEqual(client.get("/api/status", headers=AUTH).status_code, 200)
                    self.assertEqual(client.get("/api/push/status", headers=AUTH).status_code, 503)


if __name__ == "__main__":
    unittest.main()
