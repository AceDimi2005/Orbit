#!/usr/bin/env python3
"""Linux entry point for the shared Orbit companion and Qt tray."""
import argparse
import asyncio
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]


def desktop_exec(arguments):
    # Desktop Entry Exec quoting is not shell quoting. Escape reserved characters
    # inside double quotes, and double field-code percent signs.
    return " ".join('"' + str(argument).replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$").replace("%", "%%") + '"' for argument in arguments)


class Startup:
    def __init__(self, arguments=None, directory=None):
        base = Path(os.getenv("XDG_CONFIG_HOME", str(Path.home() / ".config")))
        self.path = (Path(directory) if directory else base / "autostart") / "orbit-companion.desktop"
        self.arguments = arguments or ([os.environ["ORBIT_LAUNCHER"]] if os.environ.get("ORBIT_LAUNCHER") else [os.path.abspath(sys.executable), str(Path(__file__).resolve())])

    def enabled(self):
        return self.path.is_file()

    def contents(self):
        return ("[Desktop Entry]\nType=Application\nName=Orbit Linux Companion\n"
                "Comment=Secure phone companion for your Linux desktop\n"
                f"Exec={desktop_exec(self.arguments)}\n"
                f"Icon={Path(__file__).with_name('orbit-linux.svg')}\n"
                "Terminal=false\nCategories=Network;Utility;\nStartupNotify=false\n")

    def set_enabled(self, enabled):
        if enabled:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(self.contents(), encoding="utf-8")
        else:
            self.path.unlink(missing_ok=True)


def prepare_environment():
    data_home = Path(os.getenv("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    if not data_home.is_absolute():
        raise RuntimeError("XDG_DATA_HOME must be an absolute path.")
    directory = data_home / "Orbit"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise RuntimeError("Orbit's data directory must be owned by your user and cannot be a symbolic link.")
    directory.chmod(0o700)
    os.environ["ORBIT_PLATFORM"] = "linux"
    os.environ["LOCALAPPDATA"] = str(data_home)  # Shared services use this same private directory.
    os.environ["ORBIT_TOKEN_FILE"] = str(directory / ".orbit-token")
    os.environ["ORBIT_WIDGET_TOKEN_FILE"] = str(directory / ".orbit-widget-token")
    os.environ["ORBIT_SUNSHINE_LOGIN_FILE"] = str(directory / ".orbit-sunshine-login")
    os.environ["ORBIT_APP_DIRECTORY"] = str(ROOT)
    for name in ("ORBIT_TOKEN_FILE", "ORBIT_WIDGET_TOKEN_FILE", "ORBIT_SUNSHINE_LOGIN_FILE"):
        path = Path(os.environ[name])
        if path.is_symlink():
            raise RuntimeError(f"{path.name} cannot be a symbolic link.")
    # Prefer Wayland when DISPLAY is also present for XWayland clients.
    if os.getenv("WAYLAND_DISPLAY"):
        os.environ.setdefault("QT_QPA_PLATFORM", "wayland")
    sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
    return directory


def configure_sunshine(agent):
    import shutil
    base = Path(os.getenv("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    paths = [base / "sunshine/apps.json", Path.home() / ".var/app/dev.lizardbyte.app.Sunshine/config/sunshine/apps.json"]
    if os.getenv("ORBIT_SUNSHINE_APPS"):
        paths.insert(0, Path(os.environ["ORBIT_SUNSHINE_APPS"]))
    agent.SUNSHINE_APPS_PATHS = paths
    agent.SUNSHINE_CONF_PATHS = [path.with_name("sunshine.conf") for path in paths]
    if os.getenv("ORBIT_SUNSHINE_CONF"):
        agent.SUNSHINE_CONF_PATHS.insert(0, Path(os.environ["ORBIT_SUNSHINE_CONF"]))
    executable = shutil.which("sunshine")
    agent.SUNSHINE_EXECUTABLE_PATHS = [Path(executable)] if executable else []


def main():
    parser = argparse.ArgumentParser(description="Orbit Linux tray companion")
    parser.add_argument("--doctor", action="store_true", help="Report desktop helper availability without starting the server")
    parser.add_argument("--enable-startup", action="store_true")
    parser.add_argument("--disable-startup", action="store_true")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Use this entry point on Linux.")
    if os.geteuid() == 0:
        parser.error("Run Orbit as your signed-in desktop user, not as root.")
    if args.enable_startup or args.disable_startup:
        Startup().set_enabled(args.enable_startup)
        return
    directory = prepare_environment()
    import orbit_agent as agent
    configure_sunshine(agent)
    if args.doctor:
        print(json.dumps(agent.PLATFORM.diagnostics(), indent=2))
        return
    if not (os.getenv("WAYLAND_DISPLAY") or os.getenv("DISPLAY")):
        parser.error("Start Orbit from your graphical desktop so it inherits the Wayland/X11 and session D-Bus environment.")
    lock = os.open(directory / "companion.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        parser.exit(0, "Orbit is already running in the tray.\n")
    log_path = directory / "agent.log"
    handler = RotatingFileHandler(log_path, maxBytes=2 * 1024 * 1024, backupCount=2)
    logging.basicConfig(level=logging.INFO, handlers=[handler], format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Private credentials are generated before any listener starts, and never logged.
    from orbit_tls import ensure_tls_identity
    certificate, key, fingerprint = ensure_tls_identity(directory / "tls")
    agent.API_TOKEN = agent.load_api_token()
    agent.WIDGET_TOKEN = agent.load_widget_token()
    agent.CERTIFICATE_FINGERPRINT = fingerprint
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication
    from orbit_linux_tray import Tray
    import uvicorn
    application = QApplication(sys.argv[:1])
    application.setApplicationName("Orbit Linux Companion")
    application.setDesktopFileName("orbit-companion")
    application.setQuitOnLastWindowClosed(False)
    server = uvicorn.Server(uvicorn.Config(agent.app, host=os.getenv("ORBIT_HOST", "0.0.0.0"), port=agent.SECURE_PORT,
                                        ssl_certfile=str(certificate), ssl_keyfile=str(key), proxy_headers=False,
                                        access_log=False, timeout_graceful_shutdown=5, ws_max_size=4 * 1024 * 1024))
    def stop():
        server.should_exit = True
        agent.STOP_EVENT.set()
        tray.close()
        application.quit()
    tray = Tray(agent, stop, Startup(), log_path)
    agent.PAIRING_MANAGER = agent.PairingManager(fingerprint, agent.pairing_payload, show_pin=tray.show_pin)
    agent.ADVERTISEMENT = agent.OrbitAdvertisement(agent.SECURE_PORT, fingerprint, agent.AGENT_VERSION)
    agent.orbit_notify.set_notifier(lambda title, text: tray.notification.emit(title, text))
    failure = []
    def serve():
        try:
            asyncio.run(server.serve())
        except BaseException as error:
            failure.append(str(error))
            logging.getLogger("orbit").exception("Linux HTTPS server stopped")
    worker = threading.Thread(target=serve, name="orbit-https", daemon=True)
    worker.start()
    def check():
        if not worker.is_alive():
            if failure or not server.should_exit:
                tray.failure.emit("The HTTPS server stopped. Check the agent log for a port conflict or startup error.")
            stop()
    timer = QTimer()
    timer.timeout.connect(check)
    timer.start(200)
    signal.signal(signal.SIGINT, lambda *_: stop())
    signal.signal(signal.SIGTERM, lambda *_: stop())
    try:
        application.exec()
    finally:
        server.should_exit = True
        agent.STOP_EVENT.set()
        tray.close()
        worker.join(15)
        agent.PAIRING_MANAGER.close()
        agent.orbit_notify.set_notifier(None)
        try:
            agent.PLATFORM.release_input()
        except Exception:
            logging.getLogger("orbit").warning("Could not release Linux input during shutdown")
        os.close(lock)


if __name__ == "__main__":
    main()
