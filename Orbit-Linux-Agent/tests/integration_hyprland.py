"""Opt-in live check using only disposable Orbit-owned headless outputs.

Run manually with --run. Sunshine is a fake; physical outputs are excluded from
all power/focus operations and compared before/after. No pointer input is sent.
"""
import argparse
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Orbit-Linux-Agent"), str(ROOT / "Orbit-Windows-Agent"), str(Path(__file__).parent)]
from orbit_linux_backend import Commands
from orbit_linux_display import HyprlandDisplays, LinuxStreamDisplayService, mode
from orbit_settings import SettingsStore
from orbit_stream_display import SunshineActivity
from test_display import Sunshine


class TestOutputs(HyprlandDisplays):
    def __init__(self, commands):
        super().__init__(commands)
        self.created = set()

    def monitors(self):
        rows = super().monitors()
        for row in rows:
            if row["name"] not in self.created:
                # Keep their geometry as placement anchors, but never power off
                # or focus an existing monitor through a test hook.
                row["dpmsStatus"] = False
                row["focused"] = False
        return rows

    def create(self, name):
        assert super().find(name) is None
        self.created.add(name)
        super().create(name)

    def destroy(self, name):
        assert name in self.created
        super().destroy(name)

    def power(self, name, enabled):
        assert name in self.created
        super().power(name, enabled)

    def configure(self, name, requested, position="right"):
        try:
            return super().configure(name, requested, position)
        except Exception:
            print("Requested:", name, requested, position)
            print("Observed:", [{key: row.get(key) for key in ("name", "width", "height", "refreshRate", "x", "y", "scale", "disabled")} for row in self.monitors()])
            raise

    def focus(self, name):
        assert name in self.created
        super().focus(name)


def snapshot(platform):
    fields = ("name", "width", "height", "refreshRate", "x", "y", "scale", "transform", "disabled", "dpmsStatus", "colorManagementPreset")
    return [{key: row.get(key) for key in fields} for row in HyprlandDisplays.monitors(platform) if row["name"] not in platform.created]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--grim", default="grim")
    args = parser.parse_args()
    platform = TestOutputs(Commands())
    before = snapshot(platform)
    base = "ORBIT-" + uuid.uuid4().hex[:16]
    with tempfile.TemporaryDirectory(prefix="orbit-display-check-") as directory:
        store = SettingsStore(Path(directory) / "settings.json")
        sunshine = Sunshine()
        service = LinuxStreamDisplayService(sunshine, platform, lambda: store, activity=lambda: SunshineActivity(), hook_launcher=["unused-test-hook"])
        try:
            platform.create(base)
            platform.configure(base, mode(1280, 720, 60))
            service.set_second_screen(True, 1920, 1080, 60, "right")
            target = service.state()["output"]
            assert platform.find(target)["width"] == 1920
            assert service.status()["secondScreen"]["active"]
            service.ensure_mode(1280, 720, 60)
            from PIL import Image
            jpeg = platform.commands.run(args.grim, "-o", target, "-t", "jpeg", "-", timeout=10)
            with Image.open(io.BytesIO(jpeg)) as picture:
                assert picture.size == (1280, 720), picture.size
            service.set_second_screen(False)
            assert platform.find(target) is None
            service.set_fill(True, only_display=True)
            service.stream_hook(True, {"SUNSHINE_CLIENT_WIDTH": "1280", "SUNSHINE_CLIENT_HEIGHT": "720", "SUNSHINE_CLIENT_FPS": "60"})
            assert base in service.state()["darkened"]
            service.stream_hook(False)
            assert platform.find(base)["dpmsStatus"]
            service.revert()
            assert sunshine.settings["output_name"] == "DP-1"
            print("PASS: Hyprland virtual output creation, mode changes, placement, grim capture, stream hooks and restoration")
        finally:
            try:
                service.revert()
            finally:
                for name in platform.created:
                    platform.destroy(name)
            assert snapshot(platform) == before, "Existing output state changed"
            print("PASS: existing monitor geometry, power and color state unchanged; temporary outputs removed")


if __name__ == "__main__":
    main()
