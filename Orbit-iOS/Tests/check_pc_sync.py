"""Compile and run the iCloud saved-PC sync merge logic against an in-memory store.

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
    subprocess.run([str(binary)], check=True, timeout=30)
