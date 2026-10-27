"""Check Fill Screen setup and Second Screen (Shared/OrbitStreamDisplay.swift) against the agent.

1. Compiles Shared/OrbitStreamDisplay.swift with the production OrbitAPIClient.swift and OrbitError.swift
   plus Tests/OrbitStreamDisplayTests.swift, and runs the model checks (`--unit`): lenient decoding,
   request bodies, the readiness checks and their wording, plain-words errors.
2. When the agent has orbit_stream_display.py and its Python dependencies are installed (run with the
   agent's venv), serves the real `/api/stream/display` router over loopback TLS, backed by the agent
   tests' fakes for Sunshine, the Virtual Display Driver and Windows (nothing on this Mac is touched),
   and runs the app's requests through the pinned production client: capabilities, status, adding a
   size, Fill Screen on/off, the 409 during a stream and the 428 without a login, a running app,
   Second Screen on/off, revert, a PC without the driver, and an older agent (404).
"""
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
AGENT = ROOT / "Orbit-Windows-Agent"
sys.dont_write_bytecode = True

PHONE = ("2556", "1178")
IPAD = ("2732", "2048")
TOKEN = "stream-display-check-token-0123456789"


def compile_checks(directory):
    binary = Path(directory) / "stream-display-checks"
    subprocess.run([
        "swiftc", "-parse-as-library",
        str(ROOT / "Orbit-iOS/Shared/OrbitStreamDisplay.swift"),
        str(ROOT / "Orbit-iOS/Orbit/OrbitAPIClient.swift"),
        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"),
        str(ROOT / "Orbit-iOS/Tests/OrbitStreamDisplayTests.swift"),
        "-o", str(binary),
    ], check=True)
    return binary


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Server:
    """A uvicorn TLS server in a thread for one FastAPI app."""

    def __init__(self, app, cert, key):
        import uvicorn
        self.port = free_port()
        self.server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=self.port, lifespan="off", ssl_certfile=str(cert),
                                                    ssl_keyfile=str(key), access_log=False, log_level="error"))
        self.thread = threading.Thread(target=self.server.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        for _ in range(400):
            if self.server.started:
                return self
            time.sleep(0.025)
        raise SystemExit("FAIL: the loopback TLS server did not start")

    def __exit__(self, *exc):
        self.server.should_exit = True
        self.thread.join(5)


def agent_round_trip(binary, directory):
    if not (AGENT / "orbit_stream_display.py").exists():
        print("SKIP: agent round trip — this agent has no orbit_stream_display.py yet")
        return
    sys.path.insert(0, str(AGENT))
    try:
        from cryptography import x509  # noqa: F401
        from fastapi import FastAPI, Header, HTTPException, Request
        from unittest.mock import patch
        import orbit_stream_display as sd
        from orbit_tls import ensure_tls_identity
        import test_stream_display as fakes  # the agent tests' fakes: Sunshine, the driver, Windows
    except Exception as error:  # agent dependencies missing (run with the test venv)
        print(f"SKIP: agent round trip ({type(error).__name__}: {error}); run with the agent's Python environment")
        return

    with patch("orbit_tls.local_names", return_value=[x509.DNSName("stream-display-check.invalid")]):
        cert, key, fingerprint = ensure_tls_identity(Path(directory) / "tls")

    def make_app(service, features=("streamDisplay", "secondScreen")):
        def verify(authorization: str = Header(None)):
            if authorization != f"Bearer {TOKEN}":
                raise HTTPException(401, "Invalid Orbit token")

        def secure(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(426, "Encrypted connection needed")

        app = FastAPI()
        if features is not None:
            @app.get("/api/capabilities")
            def capabilities(authorization: str = Header(None)):
                verify(authorization)
                return {"agentVersion": "4.4.0", "features": list(features)}
        app.include_router(sd.create_stream_display_router(verify, secure, service))
        return app

    def run(port, *command):
        output = subprocess.run([str(binary), "--live", str(port), TOKEN, fingerprint, *command], check=True, timeout=120,
                                capture_output=True, text=True).stdout.strip()
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            raise SystemExit(f"FAIL: {' '.join(command)} printed {output!r}")

    def check(condition, label, detail=None):
        if not condition:
            raise SystemExit(f"FAIL: {label}" + (f"\n  {json.dumps(detail, indent=1)[:2000]}" if detail is not None else ""))

    folder = Path(directory) / "pc"
    folder.mkdir()
    service, sunshine, platform, ps, store = fakes.make_service(folder)
    platform.offered_after_pipe = True
    try:
        with Server(make_app(service), cert, key) as server:
            port = server.port
            features = run(port, "features")
            check({"streamDisplay", "secondScreen"} <= set(features.get("features", [])), "capabilities list streamDisplay and secondScreen", features)

            # No Sunshine login: the app asks for it first, and changes answer 428 in plain words.
            sunshine.login = False
            status = run(port, "status", *PHONE)
            check(status["loginSaved"] is False and status["checks"][0] == "login=missing", "no login: the login check comes first", status)
            check(status["shortfall"] == "Orbit needs your Sunshine login to set up Test-PC.", "no login: shortfall", status)
            check(status["secondScreenBlocker"] == "Save your Sunshine login on the PC first.", "no login blocks the second screen", status)
            refused = run(port, "fill", "on", *PHONE)
            check(refused.get("error", {}).get("status") == 428 and refused["error"]["title"] == "Sunshine login needed"
                  and "login" in refused["error"]["message"], "fill without a login is 428 in plain words", refused)

            # Login saved: everything but this screen's size and Fill Screen itself.
            sunshine.login = True
            status = run(port, "status", *PHONE)
            check(status["driverUsable"] and not status["lists"] and not status["fillsScreen"] and status["fillReady"], "ready PC without the size", status)
            check(status["checks"] == ["login=done", "sunshine=done", "driver=done", "size=missing", "sunshineTarget=missing"], "checks before setup", status)
            check(status["shortfall"] == "Test-PC's virtual display doesn't offer 2556 × 1178 yet.", "shortfall names the size", status)

            # Set Up This PC: the size, then Fill Screen.
            added = run(port, "modes", *PHONE, "120")
            check(added.get("changed") is True and added["display"]["lists"] is True and added["display"]["listsAtRate"] is True,
                  "adding the phone's size", added)
            same = run(port, "modes", *PHONE, "120")
            check(same.get("changed") is False and same.get("reload") == "notNeeded", "the same size again changes nothing", same)
            # The app reads the agent's "WxH@R" modes per refresh rate: 100 Hz is not listed until it is added.
            at100 = run(port, "status", *PHONE, "100")
            check(at100["lists"] is True and at100["listsAtRate"] is False, "a refresh rate the driver lacks is not listed", at100)
            added100 = run(port, "modes", *PHONE, "100")
            check(added100.get("changed") is True and added100["display"]["listsAtRate"] is True, "adding the stream's refresh rate", added100)
            filled = run(port, "fill", "on", *PHONE)
            check(filled.get("changed") is True and filled.get("restarted") is True and filled["display"]["fillsScreen"] is True
                  and filled["display"]["checks"] == ["login=done", "sunshine=done", "driver=done", "size=done", "sunshineTarget=done"],
                  "Fill Screen on: the PC fills the screen", filled)
            check(sunshine.conf.get("output_name") == fakes.VDD_ID and sunshine.conf.get("dd_configuration_option") == "ensure_primary",
                  "Sunshine points at the virtual display", sunshine.conf)
            only = run(port, "fill", "only", *PHONE)
            check(only["display"]["onlyDisplay"] is True and sunshine.conf.get("dd_configuration_option") == "ensure_only_display",
                  "turning the PC's monitor off while streaming", only)

            # A stream is running: nothing changes, and the 409 sentence reaches the app as is.
            ps.stream(True)
            busy = run(port, "fill", "off", *PHONE)
            check(busy.get("error", {}).get("status") == 409 and busy["error"]["title"] == "Not possible right now"
                  and busy["error"]["message"] == sd.STREAM_RUNNING, "fill off during a stream is 409 in plain words", busy)
            status = run(port, "status", *PHONE)
            check(status["streamActive"] is True and status["fillsScreen"] is True, "status during a stream", status)
            ps.stream(False)

            # An app left running in Sunshine.
            sunshine.current_game = 7
            status = run(port, "status", *IPAD)
            check(status["appRunning"] is True and status["secondScreenChecks"][-1] == "idle=missing", "a running app is flagged for the second screen", status)
            refused = run(port, "second", "on", *IPAD, "60", "left")
            check(refused.get("error", {}).get("status") == 409 and refused["error"]["message"] == sd.APP_RUNNING,
                  "second screen while an app runs is 409 in plain words", refused)
            sunshine.current_game = 0

            # Second Screen on and off (with Fill Screen still on).
            second = run(port, "second", "on", *IPAD, "60", "left")
            check(second["display"]["secondScreenActive"] is True and second["display"]["secondScreenPosition"] == "left"
                  and second.get("placement") in ("pending", "done", "manual"), "second screen on", second)
            if second.get("placement") == "pending":
                check(bool(second.get("placementHint")) and "left" in second["placementHint"], "pending placement comes with a hint", second)
            check(sunshine.conf.get("dd_configuration_option") == "ensure_active", "Sunshine extends the desktop with the virtual display", sunshine.conf)
            moved = run(port, "second", "on", *IPAD, "60", "right")
            check(moved["display"]["secondScreenPosition"] == "right" and moved.get("restarted") is False, "moving it needs no restart", moved)
            off = run(port, "second", "off", *IPAD)
            check(off["display"]["secondScreenActive"] is False and off["display"]["fillEnabled"] is True, "second screen off keeps Fill Screen", off)
            again = run(port, "second", "off", *IPAD)
            check(again.get("changed") is False and again.get("restarted") is False, "second screen off when already off changes nothing", again)

            # Undo Orbit's changes.
            reverted = run(port, "revert", *PHONE)
            check(reverted["display"]["fillEnabled"] is False and reverted["display"]["savedConfig"] is False
                  and sunshine.conf == fakes.ORIGINAL_CONFIG, "revert restores Sunshine's settings", reverted)
    finally:
        service.close()

    # A PC without the Virtual Display Driver: the app offers the winget command.
    bare_folder = Path(directory) / "bare"
    bare_folder.mkdir()
    bare_platform = fakes.FakePlatform(bare_folder, xml=None, instances=())
    bare, _, _, _, _ = fakes.make_service(bare_folder, platform=bare_platform)
    try:
        with Server(make_app(bare), cert, key) as server:
            status = run(server.port, "status", *PHONE)
            check(not status["driverUsable"] and status["offersInstallCommand"] and status["installCommand"] == sd.VDD_INSTALL_COMMAND
                  and status["checks"][2] == "driver=missing" and status["checks"][3] == "size=unknown", "no driver: offer the winget command", status)
            refused = run(server.port, "second", "on", *IPAD, "60", "right")
            check(refused.get("error", {}).get("status") == 409 and "Virtual Display Driver" in refused["error"]["message"],
                  "second screen without the driver is 409 with the install command", refused)
    finally:
        bare.close()

    # An agent older than /api/capabilities: 404 means "update the companion".
    older_folder = Path(directory) / "older"
    older_folder.mkdir()
    older, _, _, _, _ = fakes.make_service(older_folder)
    try:
        with Server(make_app(older, features=None), cert, key) as server:
            check(run(server.port, "features") == {"olderAgent": True}, "an agent without /api/capabilities reads as older")
    finally:
        older.close()

    print("PASS: the app's stream display requests work against the agent over pinned TLS: status, sizes, Fill Screen, "
          "the 428/409 sentences, a running app, Second Screen on/move/off, revert, no driver and an older agent")


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-stream-display-check-") as directory:
        binary = compile_checks(directory)
        subprocess.run([str(binary), "--unit"], check=True, timeout=60)
        agent_round_trip(binary, directory)


if __name__ == "__main__":
    main()
