"""Compile and run the iCloud saved-PC sync merge logic against an in-memory store.

Also covers the optional per-PC "Secondary IP" (`secondaryAddress`: a Tailscale IPv4 or MagicDNS name):
payloads from older apps decode without it, it is synced and trimmed, clearing it on a newer edit sticks,
and `OrbitAddressRoute` keeps requests on the LAN address whenever that answers.

No iCloud account, network or device is touched.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="orbit-pc-sync-") as directory:
    binary = Path(directory) / "pc-sync-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        str(ROOT / "Orbit-iOS/Shared/OrbitPCSync.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitPCSyncTests.swift"),
        "-o", str(binary),
    ], check=True)
    result = subprocess.run([str(binary)], check=True, timeout=30, capture_output=True, text=True)
    print(result.stdout, end="")
    assert "secondary addresses and the LAN/secondary route" in result.stdout, "the secondary address checks did not run"
