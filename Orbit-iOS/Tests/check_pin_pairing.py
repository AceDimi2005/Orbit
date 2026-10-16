"""Production Swift SRP client <-> Python agent over real loopback HTTPS.

macOS only; first run resolves the pinned Swift package and builds a small probe.
Uses temporary certificates and test credentials, never the agent's real state.
"""
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
import uvicorn
from fastapi import FastAPI
from orbit_pairing import PairingManager, create_pairing_router
from orbit_tls import ensure_tls_identity

SWIFT = r'''
import Foundation
struct OrbitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        let handshake = try OrbitPairingHandshake(host: "127.0.0.1", port: Int(args[1])!, fingerprint: args[2])
        let expiry = try await handshake.begin(name: "Native test iPhone")
        precondition(expiry == 120)
        guard let pin = readLine() else { fatalError("No test code") }
        if args[3] == "rejectIdentity" {
            do {
                _ = try await handshake.finish(pin: pin)
            } catch let error as OrbitError {
                precondition(error.message.contains("identity changed"))
                print("PASS: encrypted pairing credentials rejected when the certificate identity is substituted")
                return
            }
            fatalError("Substituted PC identity accepted")
        }
        let credentials = try await handshake.finish(pin: pin)
        precondition(credentials.apiToken == "native-pairing-control-token-for-test-only")
        precondition(credentials.widgetToken == "native-pairing-widget-token-for-test-only")
        precondition(credentials.hostname == "Test PC")
        precondition(credentials.macAddress == "02:00:00:00:00:01")
        precondition(credentials.securePort == Int(args[1])!)
        print("PASS: native Swift SRP PIN proof, mutual authentication, AES-GCM credentials and certificate binding")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-pin-check-") as temporary:
        root = Path(temporary).resolve()
        sources = root / "Sources" / "Probe"
        sources.mkdir(parents=True)
        for name in ("OrbitAPIClient.swift", "OrbitPairing.swift"):
            shutil.copy2(ROOT / "Orbit-iOS" / "Orbit" / name, sources / name)
        (sources / "Probe.swift").write_text(SWIFT)
        (root / "Package.swift").write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "OrbitPairingProbe", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/adam-fowler/swift-srp.git", revision: "1345dfeff4d1bc54fc36257325371df3d1d7a813")],
    targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "SRP", package: "swift-srp")])])
''')
        scratch = Path(tempfile.gettempdir()) / "orbit-pairing-swift-build"
        build = ["swift", "build", "--package-path", str(root), "--scratch-path", str(scratch)]
        subprocess.run(build, check=True, stdout=subprocess.DEVNULL)
        binary_dir = subprocess.check_output(build + ["--show-bin-path"], text=True).strip()
        cert, key, fingerprint = ensure_tls_identity(root / "tls")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
        codes = queue.Queue()
        dismissed = threading.Event()

        def show_code(name, code):
            codes.put(code)
            return dismissed.set

        manager = PairingManager(fingerprint, lambda host: {
            "hostname": "Test PC", "ipAddress": "127.0.0.1", "agentPort": 8765,
            "securePort": port, "macAddress": "02:00:00:00:00:01",
            "subnetMask": "255.0.0.0", "broadcastAddress": "127.255.255.255",
            "apiToken": "native-pairing-control-token-for-test-only",
            "widgetToken": "native-pairing-widget-token-for-test-only",
        }, show_pin=show_code)
        app = FastAPI()
        app.include_router(create_pairing_router(lambda: manager))
        server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, lifespan="off", proxy_headers=False,
                                ssl_certfile=str(cert), ssl_keyfile=str(key), access_log=False, log_level="error"))
        thread = threading.Thread(target=server.run, daemon=True); thread.start()
        process = None
        try:
            for _ in range(200):
                if server.started: break
                time.sleep(.025)
            assert server.started
            for mode in ("accept", "rejectIdentity"):
                dismissed.clear()
                if mode == "rejectIdentity":
                    # Simulate a relay returning an authentic encrypted payload
                    # for a different identity than bootstrap TLS advertised.
                    manager.fingerprint = "0" * 64
                process = subprocess.Popen([str(Path(binary_dir) / "Probe"), str(port), fingerprint, mode],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                code = codes.get(timeout=20)
                stdout, stderr = process.communicate(code + "\n", timeout=20)
                assert process.returncode == 0, stderr
                assert "PASS:" in stdout, stdout
                assert dismissed.is_set(), "The PC code display was not dismissed after pairing"
                print(stdout.strip())
        finally:
            if process is not None and process.poll() is None:
                process.kill(); process.communicate()
            server.should_exit = True; thread.join(5); manager.close()
        assert not thread.is_alive()


if __name__ == "__main__":
    main()
