"""Compile the production Foundation model against Linux display service replies.

Requires swiftc and the Linux test dependencies. Does not test Apple UI or TLS.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
from test_display import Displays, Sunshine, LinuxStreamDisplayService, SettingsStore, SunshineActivity


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-swift-display-") as directory:
        directory = Path(directory)
        store = SettingsStore(directory / "settings.json")
        displays = Displays()
        service = LinuxStreamDisplayService(Sunshine(), displays, lambda: store, activity=lambda: SunshineActivity())
        service.ensure_mode(2556, 1178, 60)
        service.set_fill(True)
        states = {"fill": service.status()}
        service.set_second_screen(True, 1920, 1080, 60, "left")
        states["second"] = service.status()
        service.revert()
        states["restored"] = service.status()
        displays.supported = False
        states["unsupported"] = service.status()
        fixture = directory / "status.json"
        fixture.write_text(json.dumps(states))
        binary = directory / "check"
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Orbit-iOS/Shared/OrbitStreamDisplay.swift"),
                        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"), str(ROOT / "Orbit-iOS/Tests/OrbitLinuxDisplayChecks.swift"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(fixture)], check=True)


if __name__ == "__main__":
    main()
