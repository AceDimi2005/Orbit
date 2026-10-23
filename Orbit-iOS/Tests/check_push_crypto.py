"""Seal PC alerts in Python exactly like the Windows agent (DESIGN F1, Orbit-Push-Relay/PROTOCOL.md §6)
and open them with the production Swift code the iPhone and its Notification Service Extension use.

Also runs the shared event-feed logic (local fallback poller on iPhone and Mac) against scripted
`GET /api/events` pages: first run, paging, dedupe against pushes, hold-back, recreated logs, stale alerts.

Needs the `cryptography` package (use the agent's development venv) and `swiftc`. Nothing touches the
network, the keychain or a device.
"""
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover - environment problem, not a test failure
    sys.exit("check_push_crypto.py needs the 'cryptography' package: run it with the agent's development venv.")

ROOT = Path(__file__).resolve().parents[2]
FAILURES = []


def check(condition, message):
    if not condition:
        FAILURES.append(message)


def pad(plain: bytes) -> bytes:
    return plain + b" " * (-len(plain) % 128)


def seal(key: bytes, device_id: str, message, *, raw: bytes = None) -> str:
    """The agent's `seal` from PROTOCOL.md §6 (compact JSON, space padding to 128, AES-256-GCM, AAD = deviceID)."""
    plain = raw if raw is not None else json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    plain = pad(plain)
    assert len(plain) % 128 == 0
    nonce = os.urandom(12)
    sealed = AESGCM(key).encrypt(nonce, plain, device_id.encode("utf-8"))
    return base64.b64encode(nonce + sealed).decode("ascii")


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def message(**overrides):
    base = {"v": 1, "pc": "Pretend-PC", "id": 41, "kind": "download.finished", "title": "Portal 2 finished downloading",
            "body": "Steam finished Portal 2 (12.4 GB).", "ts": 1729700000, "link": "orbit://notifications"}
    base.update(overrides)
    return base


device = str(uuid.uuid4()).upper()
other_device = str(uuid.uuid4()).upper()
key_a, key_b, key_c, stranger = (AESGCM.generate_key(bit_length=256) for _ in range(4))
three_keys = [{"id": "PC-A", "key": b64(key_a)}, {"id": "PC-B", "key": b64(key_b)}, {"id": "PC-C", "key": b64(key_c)}]
only_b = [{"id": "PC-B", "key": b64(key_b)}]

crypto_cases = []
expected = {}


def add(name, ciphertext, keys, device_id=device, expect=None):
    crypto_cases.append({"name": name, "ciphertext": ciphertext, "deviceID": device_id, "keys": keys})
    expected[name] = expect


# 1. The right PC is found among several stored keys.
add("third of three keys", seal(key_c, device, message()), three_keys,
    expect={"ok": True, "pcID": "PC-C", "title": "Portal 2 finished downloading", "id": 41})
add("single key", seal(key_b, device, message(id=7, kind="temperature.high", title="CPU at 96 °C", body="Above 90 °C for 30 s.")), only_b,
    expect={"ok": True, "pcID": "PC-B", "id": 7, "kind": "temperature.high", "title": "CPU at 96 °C", "body": "Above 90 °C for 30 s."})

# 2. Padding: plaintext that is already a multiple of 128 bytes (no spaces added), and the largest the relay allows.
exact = message(body="")
plain = json.dumps(exact, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
exact["body"] = "x" * (256 - len(plain))
exact_plain = json.dumps(exact, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
check(len(exact_plain) == 256, f"test setup: exact plaintext should be 256 bytes, got {len(exact_plain)}")
add("no padding needed", seal(key_b, device, exact), only_b, expect={"ok": True, "body": exact["body"]})
big = message(body="")
big_plain = json.dumps(big, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
big["body"] = "y" * (2048 - len(big_plain))
big_ct = seal(key_b, device, big)
check(len(big_ct) <= 3072, f"a 2048-byte padded alert must fit the relay's 3072 characters, got {len(big_ct)}")
add("2048-byte plaintext", big_ct, only_b, expect={"ok": True, "bodyLength": 1000})

# 3. Text: Romanian, emoji, quotes, control characters and links.
add("unicode", seal(key_a, device, message(pc="Birou-Dimi", title="Descărcare gata 🎮", body="„Șah” a terminat: 100 %")), three_keys,
    expect={"ok": True, "pcID": "PC-A", "pc": "Birou-Dimi", "title": "Descărcare gata 🎮", "body": "„Șah” a terminat: 100 %"})
add("control characters", seal(key_b, device, message(title="Bad\u0007 title\u0000", body="line one\nline two\t!")), only_b,
    expect={"ok": True, "title": "Bad title", "body": "line one\nline two!"})
add("foreign link", seal(key_b, device, message(link="https://evil.example/phish")), only_b, expect={"ok": True, "link": "orbit://notifications"})
add("missing link", seal(key_b, device, {k: v for k, v in message().items() if k != "link"}), only_b, expect={"ok": True, "link": "orbit://notifications"})
add("other orbit link", seal(key_b, device, message(link="orbit://remote")), only_b, expect={"ok": True, "link": "orbit://remote"})
add("empty title and body", seal(key_b, device, message(title="", body="")), only_b,
    expect={"ok": True, "title": "Orbit", "body": "Your PC sent an alert. Open Orbit."})
add("offline message", seal(key_b, device, message(id=0, kind="pc.offline", title="PC offline", body="Pretend-PC stopped responding.")), only_b,
    expect={"ok": True, "id": 0, "kind": "pc.offline", "title": "PC offline"})
add("fractional timestamp", seal(key_b, device, message(ts=1729700000.75)), only_b, expect={"ok": True, "ts": 1729700000.75})
add("base64 with a newline", seal(key_b, device, message()) + "\n", only_b, expect={"ok": True})

# 4. Things that must not open.
good = seal(key_b, device, message())
raw = base64.b64decode(good)
add("wrong key", seal(stranger, device, message()), only_b, expect={"ok": False, "error": "authentication"})
add("wrong key among several", seal(stranger, device, message()), three_keys, expect={"ok": False, "error": "none"})
add("wrong AAD (another device)", seal(key_b, other_device, message()), only_b, expect={"ok": False, "error": "authentication"})
add("AAD case matters", seal(key_b, device.lower(), message()), only_b, expect={"ok": False, "error": "authentication"})
add("truncated by one byte", b64(raw[:-1]), only_b, expect={"ok": False, "error": "authentication"})
add("tag cut off", b64(raw[:-16]), only_b, expect={"ok": False, "error": "authentication"})
add("28 bytes", b64(raw[:28]), only_b, expect={"ok": False, "error": "malformed"})
add("nonce only", b64(raw[:12]), only_b, expect={"ok": False, "error": "malformed"})
flipped = bytearray(raw)
flipped[20] ^= 0x01
add("one bit flipped", b64(bytes(flipped)), only_b, expect={"ok": False, "error": "authentication"})
nonce_flipped = bytearray(raw)
nonce_flipped[0] ^= 0x80
add("nonce changed", b64(bytes(nonce_flipped)), only_b, expect={"ok": False, "error": "authentication"})
add("not base64", "%%% not base64 %%%", only_b, expect={"ok": False, "error": "malformed"})
add("empty", "", only_b, expect={"ok": False, "error": "malformed"})
add("short key", seal(key_b, device, message()), [{"id": "PC-B", "key": b64(key_b[:31])}], expect={"ok": False, "error": "malformed"})
add("too long", "A" * 5000, only_b, expect={"ok": False, "error": "malformed"})
add("empty device ID", seal(key_b, "", message()), only_b, device_id="", expect={"ok": False, "error": "malformed"})
add("version 2", seal(key_b, device, message(v=2)), only_b, expect={"ok": False, "error": "unsupported"})
add("version as text", seal(key_b, device, message(v="1")), only_b, expect={"ok": False, "error": "unsupported"})
add("not JSON", seal(key_b, device, None, raw=b"hello there"), only_b, expect={"ok": False, "error": "unsupported"})
add("JSON array", seal(key_b, device, None, raw=b"[1,2,3]"), only_b, expect={"ok": False, "error": "unsupported"})
add("only padding", seal(key_b, device, None, raw=b" "), only_b, expect={"ok": False, "error": "unsupported"})

# --- Event feed scenarios -------------------------------------------------------------------------
NOW = 1_800_000_000.0


def ts(age_seconds):
    return datetime.fromtimestamp(NOW - age_seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event(identifier, age=30, kind="download.finished", level="active"):
    return {"id": identifier, "ts": ts(age), "kind": kind, "level": level, "title": f"Event {identifier}", "body": "", "data": {}}


def page(events, latest, more=False):
    return {"events": events, "latestID": latest, "more": more}


feed_cases = []
feed_expected = {}


def scenario(name, cursor, steps, expect, delivered=0, hold_back=None):
    feed_cases.append({"name": name, "cursor": cursor, "delivered": delivered, "holdBack": hold_back, "now": NOW, "steps": steps})
    feed_expected[name] = expect


scenario("first run never replays history", None,
         [{"since": None, "limit": 1, "page": page([event(42)], 42)}],
         {"toPost": [], "cursor": 42, "resynced": True, "fetches": [[-1, 1]]})
scenario("brand-new PC log", None, [{"since": None, "limit": 1, "page": page([], 0)}],
         {"toPost": [], "cursor": 0, "resynced": True})
scenario("new events", 40, [{"since": 40, "limit": 50, "page": page([event(41), event(42)], 42)}],
         {"toPost": [41, 42], "cursor": 42, "resynced": False, "fetches": [[40, 50]]})
scenario("pushes already showed some", 40, [{"since": 40, "limit": 50, "page": page([event(41), event(42), event(43)], 43)}],
         {"toPost": [43], "cursor": 43}, delivered=42)
scenario("nothing new", 42, [{"since": 42, "limit": 50, "page": page([], 42)}], {"toPost": [], "cursor": 42})
scenario("expired gap jumps to latestID", 40, [{"since": 40, "limit": 50, "page": page([], 57)}], {"toPost": [], "cursor": 57})
scenario("paging keeps the newest five", 40, [
    {"since": 40, "limit": 50, "page": page([event(i) for i in range(41, 91)], 95, more=True)},
    {"since": 90, "limit": 50, "page": page([event(i) for i in range(91, 96)], 95)},
], {"toPost": [91, 92, 93, 94, 95], "cursor": 95, "fetches": [[40, 50], [90, 50]]})
scenario("hold back a fresh event for the push", 40,
         [{"since": 40, "limit": 50, "page": page([event(41, age=100), event(42, age=10), event(43, age=5)], 43)}],
         {"toPost": [41], "cursor": 41}, hold_back=45)
scenario("held-back event comes later", 41,
         [{"since": 41, "limit": 50, "page": page([event(42, age=60), event(43, age=50)], 43)}],
         {"toPost": [42, 43], "cursor": 43}, hold_back=45)
scenario("held-back event the push delivered", 41,
         [{"since": 41, "limit": 50, "page": page([event(42, age=60)], 42)}],
         {"toPost": [], "cursor": 42}, delivered=42, hold_back=45)
scenario("recreated log on the PC", 500, [{"since": 500, "limit": 50, "page": page([], 3)}],
         {"toPost": [], "cursor": 3, "resynced": True})
scenario("stale alerts are skipped but read", 40, [{"since": 40, "limit": 50, "page": page([
    event(41, age=13 * 3600), event(42, age=11 * 60, kind="power.scheduled", level="timeSensitive"),
    event(43, age=5 * 60, kind="power.scheduled", level="timeSensitive"), event(44, age=60, kind="temperature.high")], 44)}],
         {"toPost": [43, 44], "cursor": 44})
scenario("out-of-order and repeated ids", 40, [{"since": 40, "limit": 50, "page": page([event(43), event(41), event(40), event(42)], 43)}],
         {"toPost": [41, 42, 43], "cursor": 43})
scenario("older agent without more", 40, [{"since": 40, "limit": 50, "page": {"events": [event(41)], "latestID": 41}}],
         {"toPost": [41], "cursor": 41})
scenario("PC unreachable", 40, [], {"error": True, "fetches": [[40, 50]]})

cases = {"crypto": crypto_cases, "feed": feed_cases, "newKeys": 64}

with tempfile.TemporaryDirectory(prefix="orbit-push-crypto-") as directory:
    temporary = Path(directory)
    binary = temporary / "push-crypto-tests"
    sources = [ROOT / "Orbit-iOS/Shared/OrbitPushCrypto.swift", ROOT / "Orbit-iOS/Shared/OrbitEventFeed.swift",
               ROOT / "Orbit-iOS/Tests/OrbitPushCryptoTests.swift"]
    # Swift 6 strict concurrency: the shared files must also build for future targets.
    subprocess.run(["swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                    *map(str, sources), "-o", str(binary)], check=True)
    cases_path = temporary / "cases.json"
    cases_path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
    completed = subprocess.run([str(binary), str(cases_path)], check=True, capture_output=True, timeout=60)
    output = json.loads(completed.stdout)

results = {item["name"]: item for item in output["crypto"]}
check(len(results) == len(crypto_cases), "every crypto case must report a result")
for name, expect in expected.items():
    result = results.get(name)
    if result is None:
        check(False, f"{name}: no result")
        continue
    check(result["ok"] == expect["ok"], f"{name}: expected ok={expect['ok']}, got {result}")
    if not expect["ok"]:
        check(result.get("error") == expect["error"], f"{name}: expected error {expect['error']}, got {result.get('error')}")
        continue
    if not result["ok"]:
        continue
    got = result["message"]
    if "pcID" in expect:
        check(result["pcID"] == expect["pcID"], f"{name}: opened with {result['pcID']}, expected {expect['pcID']}")
    for field in ("id", "kind", "title", "body", "pc", "link", "ts"):
        if field in expect:
            check(got[field] == expect[field], f"{name}: {field} = {got[field]!r}, expected {expect[field]!r}")
    if "bodyLength" in expect:
        check(len(got["body"]) == expect["bodyLength"] and got["body"].endswith("…"),
              f"{name}: long bodies are cut to {expect['bodyLength']} characters with an ellipsis, got {len(got['body'])}")
    check(got["link"].startswith("orbit://"), f"{name}: only orbit:// links may open, got {got['link']}")

feed = {item["name"]: item for item in output["feed"]}
for name, expect in feed_expected.items():
    result = feed.get(name)
    if result is None:
        check(False, f"feed {name}: no result")
        continue
    if expect.get("error"):
        check("error" in result, f"feed {name}: a failing fetch must throw, got {result}")
    else:
        check("error" not in result, f"feed {name}: unexpected error {result.get('error')}")
        for field in ("toPost", "cursor", "resynced"):
            if field in expect:
                check(result.get(field) == expect[field], f"feed {name}: {field} = {result.get(field)!r}, expected {expect[field]!r}")
        check(result["unusedSteps"] == 0, f"feed {name}: {result['unusedSteps']} scripted pages were never read")
    if "fetches" in expect:
        check(result["fetches"] == expect["fetches"], f"feed {name}: fetches {result['fetches']}, expected {expect['fetches']}")

keys = output["keys"]
check(keys["allRightSize"] and keys["distinct"] == keys["count"] == 64, f"fresh keys must be 32 random bytes each: {keys}")
check(output["categories"] == {
    "download.finished": "downloads", "downloads.allFinished": "downloads", "temperature.high": "temperature",
    "task.finished": "tasks", "power.scheduled": "power", "pc.online": "online", "pc.offline": "online",
    "summary.ready": "summary", "webcam.connected": "other"}, f"categories: {output['categories']}")
check(output["powerCategory"] == "orbit.power.scheduled" and output["otherCategory"] == "orbit.pc.event", "notification categories")
check(output["identifier"] == "orbit.event.PC-1.12", f"notification identifier: {output['identifier']}")

if FAILURES:
    print("\n".join(f"FAIL: {failure}" for failure in FAILURES))
    sys.exit(1)
print(f"OK: {len(crypto_cases)} sealed alerts (Python → Swift), {len(feed_cases)} event-feed scenarios, 64 fresh keys")
