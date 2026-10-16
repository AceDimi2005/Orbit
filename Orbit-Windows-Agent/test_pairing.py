"""Pairing protocol tests use disposable secrets and mocked PIN displays only."""
import base64
import hashlib
import json
import unittest
from unittest.mock import Mock, patch

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from srptools import SRPClientSession

import orbit_pairing as pairing


FINGERPRINT = "12:34:" + ":".join(["ab"] * 30)
CONTROL = "temporary-control-credential-for-unit-tests"
WIDGET = "temporary-read-only-credential-for-unit-tests"
PEER = "192.0.2.10"
OTHER_PEER = "192.0.2.11"


def ascii_hex(value):
    return value.decode("ascii") if isinstance(value, bytes) else value


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.time = 1000.0
        self.displayed = []
        self.dismissed = []
        self.payload_calls = []
        def display(name, pin):
            self.displayed.append((name, pin))
            def dismiss(): self.dismissed.append(pin)
            return dismiss
        def payload(host):
            self.payload_calls.append(host)
            return {"hostname": "Orbit Test PC", "ipAddress": host,
                    "agentPort": 8765, "securePort": 8766,
                    "macAddress": "02:00:00:00:00:01", "subnetMask": "255.255.255.0",
                    "broadcastAddress": "192.0.2.255", "apiToken": CONTROL, "widgetToken": WIDGET}
        self.manager = pairing.PairingManager(FINGERPRINT, payload, show_pin=display, clock=lambda: self.time)
        self.initial_client = SRPClientSession(pairing.PairingContext("not-used-for-public-key"))

    def tearDown(self):
        self.manager.close()

    def begin(self, peer=PEER, name="Test iPhone", wrong_pin=False):
        response = self.manager.start(peer, name, self.initial_client.public)
        pin = self.displayed[-1][1]
        if wrong_pin: pin = "000000" if pin != "000000" else "000001"
        client = SRPClientSession(pairing.PairingContext(pin), private=self.initial_client.private)
        client.process(response["serverPublic"], response["salt"])
        return response, client

    def finish(self, challenge, client, peer=PEER):
        return self.manager.finish(peer, challenge["id"], ascii_hex(client.key_proof), "192.0.2.20")

    def decrypt(self, challenge, client, confirmation, associated_id=None, key_id=None):
        identifier = challenge["id"]
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=(key_id or identifier).encode(),
                   info=pairing.KEY_INFO).derive(bytes.fromhex(ascii_hex(client.key)))
        plaintext = AESGCM(key).decrypt(base64.b64decode(confirmation["nonce"]),
                                       base64.b64decode(confirmation["ciphertext"]),
                                       (associated_id or identifier).encode())
        return json.loads(plaintext)

    def assert_status(self, status, function, *args):
        with self.assertRaises(HTTPException) as result: function(*args)
        self.assertEqual(result.exception.status_code, status)

    def consume_wrong_proof(self, challenge, peer=PEER):
        self.assert_status(403, self.manager.finish, peer, challenge["id"], "0" * 64, "192.0.2.20")

    def test_real_srp_client_decrypts_authenticated_credentials_and_certificate(self):
        challenge, client = self.begin()
        confirmation = self.finish(challenge, client)
        self.assertTrue(client.verify_proof(confirmation["serverProof"].encode("ascii")))
        self.assertEqual(len(bytes.fromhex(confirmation["serverProof"])), 32)
        self.assertEqual(len(base64.b64decode(confirmation["nonce"])), 12)
        credentials = self.decrypt(challenge, client, confirmation)
        self.assertEqual(credentials["apiToken"], CONTROL)
        self.assertEqual(credentials["widgetToken"], WIDGET)
        self.assertEqual(credentials["certificateFingerprint"], FINGERPRINT.replace(":", "").lower())
        self.assertEqual(credentials["ipAddress"], "192.0.2.20")
        self.assertEqual(self.payload_calls, ["192.0.2.20"])
        self.assertEqual(self.dismissed, [self.displayed[0][1]])
        self.assertEqual(self.manager._sessions, {})

    def test_leading_zero_six_digit_pin_and_fixed_width_salt_work(self):
        with patch.object(pairing.secrets, "randbelow", return_value=0):
            challenge, client = self.begin()
        self.assertEqual(self.displayed[-1][1], "000000")
        self.assertEqual(len(bytes.fromhex(challenge["salt"])), 16)
        self.assertEqual(bytes.fromhex(challenge["salt"])[0], 1)
        self.assertTrue(client.verify_proof(self.finish(challenge, client)["serverProof"].encode("ascii")))

    def test_challenge_contains_only_public_protocol_metadata(self):
        challenge, _ = self.begin()
        self.assertEqual(set(challenge), {"id", "protocol", "salt", "serverPublic", "expiresIn"})
        self.assertEqual(challenge["protocol"], pairing.PROTOCOL)
        self.assertEqual(challenge["expiresIn"], 120)
        self.assertEqual(len(challenge["serverPublic"]), 512)
        serialized = json.dumps(challenge)
        for secret in (CONTROL, WIDGET, "certificateFingerprint", "apiToken", "widgetToken", '"pin"', '"verifier"', '"key"'):
            self.assertNotIn(secret, serialized)
        self.assertEqual(self.payload_calls, [])

    def test_confirmation_never_returns_plaintext_credentials(self):
        challenge, client = self.begin()
        response = self.finish(challenge, client)
        self.assertEqual(set(response), {"serverProof", "nonce", "ciphertext"})
        self.assertNotIn(CONTROL, json.dumps(response))
        self.assertNotIn(WIDGET, json.dumps(response))

    def test_wrong_pin_proof_consumes_session_and_dismisses_code(self):
        challenge, wrong_client = self.begin(wrong_pin=True)
        self.assert_status(403, self.finish, challenge, wrong_client)
        self.assert_status(410, self.finish, challenge, wrong_client)
        self.assertEqual(len(self.dismissed), 1)
        self.assertEqual(self.payload_calls, [])

    def test_malformed_proof_is_consumed_and_cannot_be_retried(self):
        for malformed in ("", "g" * 64, "0" * 63, "0" * 65):
            challenge, client = self.begin()
            self.assert_status(403, self.manager.finish, PEER, challenge["id"], malformed, "test")
            self.assert_status(410, self.finish, challenge, client)
        self.assertEqual(self.payload_calls, [])

    def test_success_cannot_be_replayed(self):
        challenge, client = self.begin()
        self.finish(challenge, client)
        self.assert_status(410, self.finish, challenge, client)
        self.assertEqual(len(self.payload_calls), 1)

    def test_other_peer_cannot_consume_legitimate_pairing(self):
        challenge, client = self.begin()
        self.assert_status(403, self.finish, challenge, client, OTHER_PEER)
        self.assertIn(challenge["id"], self.manager._sessions)
        self.assertEqual(self.dismissed, [])
        response = self.finish(challenge, client)
        self.assertEqual(self.decrypt(challenge, client, response)["apiToken"], CONTROL)

    def test_expired_session_is_consumed_and_dismissed(self):
        challenge, client = self.begin()
        self.time += pairing.PIN_SECONDS
        self.assert_status(410, self.finish, challenge, client)
        self.assertNotIn(challenge["id"], self.manager._sessions)
        self.assertEqual(len(self.dismissed), 1)
        self.assertEqual(self.payload_calls, [])

    def test_new_start_dismisses_expired_dialog_before_replacing_it(self):
        first, _ = self.begin()
        self.time += pairing.PIN_SECONDS
        second, _ = self.begin()
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(len(self.dismissed), 1)
        self.assertNotIn(first["id"], self.manager._sessions)
        self.assertIn(second["id"], self.manager._sessions)

    def test_one_active_code_rejects_parallel_starts_without_new_dialogs(self):
        self.begin()
        for index in range(20):
            self.assert_status(409, self.manager.start, f"198.51.100.{index}", "Another phone", self.initial_client.public)
        self.assertEqual(len(self.displayed), 1)
        self.assertEqual(len(self.manager._sessions), 1)
        self.assertEqual(len(self.manager._starts), 1)

    def test_five_starts_per_address_are_limited_and_expire_after_ten_minutes(self):
        for _ in range(5):
            challenge = self.manager.start(PEER, "iPhone", self.initial_client.public)
            self.consume_wrong_proof(challenge)
        self.assert_status(429, self.manager.start, PEER, "iPhone", self.initial_client.public)
        self.assertEqual(len(self.displayed), 5)
        self.time += 600
        self.manager.start(PEER, "iPhone", self.initial_client.public)
        self.assertEqual(len(self.displayed), 6)
        self.assertEqual(len(self.manager._starts[PEER]), 1)

    def test_global_rate_limit_cannot_be_bypassed_by_changing_address(self):
        for index in range(10):
            peer = f"198.51.100.{index}"
            challenge = self.manager.start(peer, "iPhone", self.initial_client.public)
            self.consume_wrong_proof(challenge, peer)
        self.assert_status(429, self.manager.start, "203.0.113.1", "iPhone", self.initial_client.public)
        self.assertEqual(len(self.manager._starts), 10)
        for index in range(100):
            self.assert_status(429, self.manager.start, f"203.0.113.{index}", "iPhone", self.initial_client.public)
        self.assertEqual(len(self.manager._starts), 10)
        self.time += 600
        self.manager.start("203.0.113.1", "iPhone", self.initial_client.public)
        self.assertEqual(len(self.manager._starts), 1)
        self.assertEqual(len(self.manager._global_starts), 1)

    def test_invalid_client_publics_do_not_show_pin_or_allocate_sessions(self):
        prime = pairing.PairingContext()._prime
        invalid = ("", "0", f"{prime:x}", f"{prime + 1:x}", "f" * 512, "1" * 513, "-1", "0x10", "abcg")
        for value in invalid:
            self.assert_status(400, self.manager.start, PEER, "iPhone", value)
        self.assertEqual(self.displayed, [])
        self.assertEqual(self.manager._sessions, {})
        self.assertEqual(len(self.manager._global_starts), 0)

    def test_close_dismisses_current_dialog_and_removes_session(self):
        self.begin()
        self.manager.close()
        self.assertEqual(self.manager._sessions, {})
        self.assertEqual(len(self.dismissed), 1)
        self.manager.close()
        self.assertEqual(len(self.dismissed), 1)

    def test_display_failure_does_not_leave_a_live_session(self):
        self.manager.show_pin = Mock(side_effect=RuntimeError("mock display unavailable"))
        self.assert_status(503, self.manager.start, PEER, "iPhone", self.initial_client.public)
        self.assertEqual(self.manager._sessions, {})

    def test_display_name_removes_controls_and_has_a_bounded_length(self):
        self.manager.start(PEER, "  Phone\\r\\n".replace("\\r", "\r").replace("\\n", "\n") + "x" * 100 + "\x00", self.initial_client.public)
        name = self.displayed[-1][0]
        self.assertEqual(len(name), 60)
        self.assertTrue(all(character.isprintable() for character in name))
        self.assertTrue(name.startswith("Phone"))

    def test_gcm_authenticates_ciphertext_session_id_and_session_derived_key(self):
        challenge, client = self.begin()
        response = self.finish(challenge, client)
        corrupted = dict(response)
        data = bytearray(base64.b64decode(corrupted["ciphertext"]))
        data[0] ^= 1
        corrupted["ciphertext"] = base64.b64encode(data).decode()
        with self.assertRaises(InvalidTag): self.decrypt(challenge, client, corrupted)
        with self.assertRaises(InvalidTag): self.decrypt(challenge, client, response, associated_id="different-session")
        with self.assertRaises(InvalidTag): self.decrypt(challenge, client, response, key_id="different-session")

    def test_fresh_sessions_have_distinct_salts_publics_identifiers_and_nonces(self):
        first, client = self.begin()
        first_result = self.finish(first, client)
        second, client = self.begin()
        second_result = self.finish(second, client)
        for field in ("id", "salt", "serverPublic"): self.assertNotEqual(first[field], second[field])
        self.assertNotEqual(first_result["nonce"], second_result["nonce"])

    def test_fixed_width_key_hash_includes_leading_zero_padding(self):
        context = pairing.PairingContext()
        self.assertEqual(context.get_common_session_key(1), hashlib.sha256(b"\x00" * 255 + b"\x01").digest())
        self.assertNotEqual(context.get_common_session_key(1), hashlib.sha256(b"\x01").digest())


class PairingHTTPTests(unittest.TestCase):
    def setUp(self):
        self.pins = []
        self.manager = pairing.PairingManager(FINGERPRINT,
            lambda host: {"hostname": "Test", "apiToken": CONTROL, "widgetToken": WIDGET},
            show_pin=lambda name, pin: self.pins.append(pin))
        self.app = FastAPI()
        self.app.include_router(pairing.create_pairing_router(lambda: self.manager))
        self.client = TestClient(self.app, base_url="https://orbit.test", client=(PEER, 12345))
        self.client_public = SRPClientSession(pairing.PairingContext("unused")).public

    def tearDown(self):
        if self.manager is not None: self.manager.close()

    def test_bootstrap_endpoints_require_https_without_requiring_a_bearer_token(self):
        result = self.client.post("http://orbit.test/api/pair/start", json={"name": "iPhone", "clientPublic": self.client_public},
                                  headers={"X-Forwarded-Proto": "https"})
        self.assertEqual(result.status_code, 426)
        result = self.client.post("http://orbit.test/api/pair/finish", json={"id": "a" * 32, "proof": "0" * 64})
        self.assertEqual(result.status_code, 426)
        self.assertEqual(self.pins, [])
        result = self.client.post("/api/pair/start", json={"name": "iPhone", "clientPublic": self.client_public})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.headers["cache-control"], "no-store")
        self.assertEqual(len(self.pins), 1)

    def test_http_handshake_uses_real_client_and_encrypted_response(self):
        first = SRPClientSession(pairing.PairingContext("unused"))
        response = self.client.post("/api/pair/start", json={"clientPublic": first.public})
        self.assertEqual(response.status_code, 200)
        challenge = response.json()
        client = SRPClientSession(pairing.PairingContext(self.pins[-1]), private=first.private)
        client.process(challenge["serverPublic"], challenge["salt"])
        response = self.client.post("/api/pair/finish", json={"id": challenge["id"], "proof": ascii_hex(client.key_proof)})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        confirmation = response.json()
        self.assertTrue(client.verify_proof(confirmation["serverProof"].encode("ascii")))
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=challenge["id"].encode(), info=pairing.KEY_INFO).derive(bytes.fromhex(ascii_hex(client.key)))
        credentials = json.loads(AESGCM(key).decrypt(base64.b64decode(confirmation["nonce"]), base64.b64decode(confirmation["ciphertext"]), challenge["id"].encode()))
        self.assertEqual(credentials["apiToken"], CONTROL)
        self.assertEqual(credentials["certificateFingerprint"], FINGERPRINT.replace(":", "").lower())

    def test_unavailable_service_returns_actionable_error(self):
        self.manager.close()
        self.manager = None
        result = self.client.post("/api/pair/start", json={"clientPublic": self.client_public})
        self.assertEqual(result.status_code, 503)
        self.assertNotIn(CONTROL, result.text)

    def test_request_sizes_and_malformed_publics_are_rejected(self):
        for body in ({"clientPublic": "a" * 513}, {"name": "x" * 81, "clientPublic": self.client_public},
                     {"clientPublic": ""}, {"clientPublic": "00"}, {"clientPublic": "g" * 64}):
            self.assertIn(self.client.post("/api/pair/start", json=body).status_code, (400, 422))
        self.assertEqual(self.pins, [])

    def test_peer_is_socket_peer_not_a_forwarded_header(self):
        challenge = self.client.post("/api/pair/start", json={"clientPublic": self.client_public},
                                     headers={"X-Forwarded-For": OTHER_PEER}).json()
        self.assertEqual(self.manager._sessions[challenge["id"]]["peer"], PEER)
        other = TestClient(self.app, base_url="https://orbit.test", client=(OTHER_PEER, 55555))
        result = other.post("/api/pair/finish", json={"id": challenge["id"], "proof": "0" * 64}, headers={"X-Forwarded-For": PEER})
        self.assertEqual(result.status_code, 403)
        self.assertIn(challenge["id"], self.manager._sessions)


if __name__ == "__main__":
    unittest.main()
