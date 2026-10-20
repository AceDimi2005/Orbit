"""Compile and run the production Foundation cursor queue without any devices.

No agent, network connections, mouse operations, or Watch simulator are started.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="orbit-watch-cursor-") as directory:
    binary = Path(directory) / "cursor-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
        str(ROOT / "Orbit-iOS/Shared/OrbitCursorPipeline.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitCursorPipelineTests.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
