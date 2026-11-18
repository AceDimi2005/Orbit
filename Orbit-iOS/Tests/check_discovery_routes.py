"""Compile and run production Bonjour candidate selection checks (macOS or Linux with Swift)."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="orbit-discovery-check-") as temporary:
    binary = Path(temporary) / "discovery-checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "6",
        str(ROOT / "Orbit-iOS/Orbit/OrbitDiscoveryRoute.swift"),
        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitDiscoveryRouteTests.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
