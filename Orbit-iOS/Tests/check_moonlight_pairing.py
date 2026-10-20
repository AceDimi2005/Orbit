"""Pair the production Swift Moonlight client with an in-process Sunshine mock.

python3 Orbit-iOS/Tests/check_moonlight_pairing.py
Needs `cryptography` (the agent's requirements) and the Xcode command line tools.
No Sunshine host, Moonlight app or network beyond 127.0.0.1 is used.
"""
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mock_sunshine  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PIN = f"{secrets.randbelow(10_000):04d}"
server, port, state = mock_sunshine.start(PIN)
try:
    with tempfile.TemporaryDirectory(prefix="orbit-moonlight-") as directory:
        binary = Path(directory) / "moonlight-tests"
        pem = Path(directory) / "client.pem"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-parse-as-library",
            str(ROOT / "Orbit-iOS/Shared/MoonlightClient.swift"),
            str(ROOT / "Orbit-iOS/Tests/MoonlightClientTests.swift"),
            "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(port), PIN, str(pem)], check=True, timeout=120)

        # The certificate the Swift code generated must be a valid self-signed X.509 for OpenSSL,
        # which is what Sunshine uses to parse and store paired clients.
        subprocess.run(["openssl", "x509", "-in", str(pem), "-noout", "-subject", "-dates"], check=True, capture_output=True)
        subprocess.run(["openssl", "verify", "-CAfile", str(pem), str(pem)], check=True, capture_output=True)
        assert list(state.paired) == ["0123456789ABCDEF"], state.paired
        assert state.paired["0123456789ABCDEF"] == pem.read_bytes(), "Sunshine stored a different certificate than the client wrote"
        phases = [args.get("phrase") or next(k for k in ("clientchallenge", "serverchallengeresp", "clientpairingsecret") if k in args)
                  for path, args in state.requests if path == "/pair"]
        # One failed attempt (wrong PIN stops after stage 3) followed by a full five-stage run.
        assert phases == ["getservercert", "clientchallenge", "serverchallengeresp",
                          "getservercert", "clientchallenge", "serverchallengeresp", "clientpairingsecret", "pairchallenge"], phases
        assert all(args.get("devicename") == "Orbit Test" for path, args in state.requests if path == "/pair"), "device name sent"
finally:
    server.shutdown()
print("PASS: Swift Moonlight client pairs with the mock Sunshine host and produces an OpenSSL-valid client certificate")
