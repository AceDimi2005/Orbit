#!/usr/bin/env python3
"""Install a per-user launcher and desktop entry for this checkout. No sudo."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Orbit-Linux-Agent"))
from orbit_linux import Startup


def main():
    if sys.platform != "linux" or os.geteuid() == 0:
        raise SystemExit("Run this installer as your ordinary Linux desktop user.")
    environment = ROOT / ".venv-linux"
    if not (environment / "bin/python").is_file():
        venv.EnvBuilder(with_pip=True).create(environment)
    python = environment / "bin/python"
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(ROOT / "Orbit-Linux-Agent/requirements.txt")], check=True)
    arguments = [str(python), str(ROOT / "Orbit-Linux-Agent/orbit_linux.py")]
    launcher = Path.home() / ".local/bin/orbit-companion"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text("#!/bin/sh\nexec " + shlex.join(arguments) + ' "$@"\n')
    launcher.chmod(0o755)
    data = Path(os.getenv("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    entry = data / "applications/orbit-companion.desktop"
    entry.parent.mkdir(parents=True, exist_ok=True)
    entry.write_text(Startup(arguments).contents())
    print(f"Installed {launcher}\nKeep this checkout at {ROOT}. Launch Orbit from your application menu.\nUse the tray's Start at login option to enable autostart.")


if __name__ == "__main__":
    main()
