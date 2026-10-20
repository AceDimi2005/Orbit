"""Exercise the production Watch HTTP sender through native URLSession mocks.

No external network, Windows agent, simulator, or real cursor is used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="orbit-watch-http-") as directory:
    binary = Path(directory) / "watch-http-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        str(ROOT / "Orbit-iOS/Shared/OrbitCursorPipeline.swift"),
        str(ROOT / "Orbit-iOS/Shared/OrbitWatchHTTPClient.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitWatchHTTPClientTests.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
