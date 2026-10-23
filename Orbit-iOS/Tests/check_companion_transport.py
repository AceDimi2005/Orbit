"""Real loopback TLS + production Swift client, no Windows actions or user files.

Requires macOS Swift and the agent's dev dependencies. The server disables the
application lifespan so no monitoring workers, real tokens or private DB start.
"""
import hashlib
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
from cryptography import x509
import uvicorn
from fastapi import Request
from starlette.responses import RedirectResponse
import orbit_agent as agent
from orbit_history import SessionRecorder
from orbit_tls import ensure_tls_identity

TOKEN = "loopback-test-control-token-not-a-real-secret"
requests_seen = []


@agent.app.middleware("http")
async def count_requests(request: Request, call_next):
    requests_seen.append(request.url.path)
    return await call_next(request)


@agent.app.get("/api/transport-test-redirect")
def redirect():
    return RedirectResponse("http://127.0.0.1:1/token-must-never-reach-this-host", status_code=302)


SWIFT = r'''
import Foundation
import CryptoKit
private struct Status: Decodable { var agentVersion: String? }
private struct FilePage: Decodable { var total: Int }
private struct UploadReply: Decodable { var name: String; var sizeBytes: Int }
private struct Rename: Encodable { var path: String; var name: String }
private struct Result: Decodable { var ok: Bool }
@main struct Check {
    static func main() async throws {
        let args = CommandLine.arguments
        let client = try OrbitAPIClient(host: "127.0.0.1", port: Int(args[1])!, token: args[2], fingerprint: args[3])
        let directory = args[4]
        let source = URL(fileURLWithPath: args[5])
        let expected = try Data(contentsOf: source)
        let status: Status = try await client.get("/api/status")
        precondition(status.agentVersion == args[6])
        let page: FilePage = try await client.get(path: "/api/files/list", query: ["path": directory])
        precondition(page.total == 0)
        let uploaded = try await client.upload(path: "/api/files/upload", query: ["directory": directory, "name": "roundtrip.bin"], file: source, progress: { value in precondition(value >= 0 && value <= 1) })
        let upload = try JSONDecoder().decode(UploadReply.self, from: uploaded)
        precondition(upload.sizeBytes == expected.count)
        let second = try await client.uploadAvoidingConflicts(directory: directory, name: "roundtrip.bin", file: source, progress: { _ in })
        precondition(second == "roundtrip (2).bin", "duplicate upload must be renamed, got \(second)")
        let third = try await client.uploadAvoidingConflicts(directory: directory, name: "roundtrip.bin", file: source, progress: { _ in })
        precondition(third == "roundtrip (3).bin", "second duplicate must be renamed, got \(third)")
        let listed: FilePage = try await client.get(path: "/api/files/list", query: ["path": directory])
        precondition(listed.total == 3)
        precondition(OrbitFileNames.windowsSafe("a:b*c?.jpg") == "a_b_c_.jpg")
        precondition(OrbitFileNames.windowsSafe("CON.txt") == "_CON.txt")
        precondition(OrbitFileNames.windowsSafe("photo. ") == "photo")
        precondition(OrbitFileNames.windowsSafe("...") == nil)
        precondition(OrbitFileNames.windowsSafe(String(repeating: "x", count: 300) + ".heic")!.count <= 180)
        precondition(OrbitFileNames.windowsSafe(String(repeating: "x", count: 300) + ".heic")!.hasSuffix(".heic"))
        precondition(OrbitFileNames.numbered("IMG_0001.JPG", attempt: 4) == "IMG_0001 (4).JPG")
        precondition(OrbitFileNames.numbered("README", attempt: 2) == "README (2)")
        let local = try await client.download(path: "/api/files/download", query: ["path": directory + "/roundtrip.bin"], progress: { value in precondition(value >= 0 && value <= 1) })
        let actual = try Data(contentsOf: local)
        precondition(SHA256.hash(data: expected) == SHA256.hash(data: actual))
        try FileManager.default.removeItem(at: local.deletingLastPathComponent())
        let renamed: Result = try await client.send("/api/files/rename", body: Rename(path: directory + "/roundtrip.bin", name: "renamed.bin"))
        precondition(renamed.ok)
        do {
            let _: Status = try await client.get("/api/transport-test-redirect")
            fatalError("A redirect must not be followed")
        } catch { }
        let wrong = try OrbitAPIClient(host: "127.0.0.1", port: Int(args[1])!, token: args[2], fingerprint: String(repeating: "0", count: 64))
        do {
            let _: Status = try await wrong.get("/api/status")
            fatalError("Wrong certificate fingerprint was accepted")
        } catch { }
        print("PASS: native Swift pinned HTTPS, 5 MiB streamed upload/download and SHA256 match, duplicate names renamed instead of overwritten, Windows-safe names, mutation, refused redirect, rejected certificate")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="orbit-transport-check-") as temporary:
        root = Path(temporary).resolve()
        files = root / "files"
        files.mkdir()
        source = root / "source.bin"
        source.write_bytes(bytes(range(256)) * (5 * 1024 * 1024 // 256))
        # The cert intentionally doesn't match 127.0.0.1: the verified PC pin,
        # rather than a DHCP address, authenticates this private TLS identity.
        with patch("orbit_tls.local_names", return_value=[x509.DNSName("old-pc-address.invalid")]):
            cert, key, fingerprint = ensure_tls_identity(root / "tls")
        swift = root / "Check.swift"
        swift.write_text(SWIFT)
        binary = root / "check"
        # The production client and its production error type, nothing else from the app.
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Orbit-iOS/Orbit/OrbitAPIClient.swift"),
                        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"), str(swift), "-o", str(binary)], check=True)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        agent.API_TOKEN = TOKEN
        agent.HISTORY_RECORDER = SessionRecorder(root / "history.sqlite3")
        server = uvicorn.Server(uvicorn.Config(agent.app, host="127.0.0.1", port=port, lifespan="off",
                                ssl_certfile=str(cert), ssl_keyfile=str(key), proxy_headers=False,
                                access_log=False, log_level="error"))
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        try:
            for _ in range(200):
                if server.started:
                    break
                time.sleep(.025)
            assert server.started, "Local TLS server did not start"
            subprocess.run([str(binary), str(port), TOKEN, fingerprint, str(files), str(source), agent.AGENT_VERSION], check=True, timeout=30)
            assert requests_seen.count("/api/status") == 1, requests_seen
            assert requests_seen.count("/api/transport-test-redirect") == 1
            assert "token-must-never-reach-this-host" not in " ".join(requests_seen)
            assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256((files / "renamed.bin").read_bytes()).digest()
        finally:
            server.should_exit = True
            thread.join(5)
            agent.HISTORY_RECORDER.close()
            agent.HISTORY_RECORDER = None
        assert not thread.is_alive(), "Local TLS server did not stop"


if __name__ == "__main__": main()
