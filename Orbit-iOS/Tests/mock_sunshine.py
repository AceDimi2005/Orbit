"""In-process Sunshine (NVIDIA GameStream) HTTP mock for protocol tests.

Implements the five-step PIN pairing exchange exactly as Sunshine's `nvhttp.cpp`
does (AES-128-ECB, SHA-256, RSA PKCS#1 v1.5 signatures over the certificate
signature bytes), plus /serverinfo, /applist, /appasset and /cancel. Everything is
served over plain HTTP on one port so the Swift client can be exercised without a
TLS identity in the Keychain; the real app uses HTTPS with the client certificate
for the authenticated calls.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import datetime
import hashlib
import secrets
import threading
from urllib.parse import parse_qs, urlparse
from xml.sax.saxutils import escape

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.x509.oid import NameOID

FAKE_PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
APPS = [(1, "Desktop", False), (2, "Steam Big Picture", True)]


def aes_ecb(key, data, encrypt):
    cipher = Cipher(algorithms.AES(key), modes.ECB())
    op = cipher.encryptor() if encrypt else cipher.decryptor()
    return op.update(data) + op.finalize()


class MockState:
    def __init__(self, pin):
        self.pin = pin
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Sunshine Gamestream Host")])
        now = datetime.datetime.now(datetime.timezone.utc)
        self.cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                     .public_key(self.key.public_key()).serial_number(x509.random_serial_number())
                     .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
                     .sign(self.key, hashes.SHA256()))
        self.cert_pem = self.cert.public_bytes(serialization.Encoding.PEM)
        self.sessions = {}
        self.paired = {}          # uniqueid -> client certificate PEM
        self.current_game = 0
        self.requests = []
        self.lock = threading.Lock()


def xml(root_attrs, body=""):
    attrs = " ".join(f'{k}="{escape(str(v))}"' for k, v in root_attrs.items())
    return f'<?xml version="1.0" encoding="utf-8"?>\n<root {attrs}>{body}</root>'.encode()


class Handler(BaseHTTPRequestHandler):
    state = None

    def log_message(self, *args):
        pass

    def reply(self, body, content_type="text/xml", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        args = {k: v[0] for k, v in parse_qs(url.query).items()}
        state = self.state
        with state.lock:
            state.requests.append((url.path, dict(args)))
            uid = args.get("uniqueid", "")
            if url.path == "/serverinfo":
                paired = 1 if uid in state.paired else 0
                body = (f"<hostname>MockSunshine</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion>"
                        f"<uniqueid>MOCK</uniqueid><HttpsPort>{self.server.server_port}</HttpsPort><ExternalPort>{self.server.server_port}</ExternalPort>"
                        f"<mac>00:11:22:33:44:55</mac><LocalIP>127.0.0.1</LocalIP><ServerCodecModeSupport>65793</ServerCodecModeSupport>"
                        f"<PairStatus>{paired}</PairStatus><currentgame>{state.current_game}</currentgame>"
                        f"<state>{'SUNSHINE_SERVER_BUSY' if state.current_game else 'SUNSHINE_SERVER_FREE'}</state>")
                return self.reply(xml({"status_code": 200}, body))
            if url.path == "/pair":
                return self.reply(self.pair(state, uid, args))
            if url.path == "/applist":
                if uid not in state.paired:
                    return self.reply(xml({"status_code": 401, "status_message": "not paired"}), status=401)
                apps = "".join(f"<App><IsHdrSupported>{1 if hdr else 0}</IsHdrSupported><AppTitle>{escape(title)}</AppTitle><ID>{app_id}</ID></App>"
                               for app_id, title, hdr in APPS)
                return self.reply(xml({"status_code": 200}, apps))
            if url.path == "/appasset":
                return self.reply(FAKE_PNG, content_type="image/png")
            if url.path == "/cancel":
                state.current_game = 0
                return self.reply(xml({"status_code": 200}, "<cancel>1</cancel>"))
            if url.path == "/launch":
                state.current_game = int(args.get("appid", "0"))
                return self.reply(xml({"status_code": 200}, "<gamesession>1</gamesession>"))
        return self.reply(xml({"status_code": 404, "status_message": "not found"}), status=404)

    def pair(self, state, uid, args):
        if not uid:
            return xml({"status_code": 400, "status_message": "Missing uniqueid parameter"})
        if args.get("phrase") == "getservercert":
            salt = bytes.fromhex(args["salt"])
            client_pem = bytes.fromhex(args["clientcert"])
            client_cert = x509.load_pem_x509_certificate(client_pem)
            key = hashlib.sha256(salt + state.pin.encode()).digest()[:16]
            state.sessions[uid] = {"key": key, "client_cert": client_cert, "client_pem": client_pem, "phase": 1}
            return xml({"status_code": 200}, f"<paired>1</paired><plaincert>{state.cert_pem.hex().upper()}</plaincert>")
        if args.get("phrase") == "pairchallenge":
            paired = 1 if uid in state.paired else 0
            return xml({"status_code": 200}, f"<paired>{paired}</paired>")
        session = state.sessions.get(uid)
        if session is None:
            return xml({"status_code": 400, "status_message": "Invalid uniqueid"})
        if "clientchallenge" in args and session["phase"] == 1:
            challenge = aes_ecb(session["key"], bytes.fromhex(args["clientchallenge"]), False)
            server_secret = secrets.token_bytes(16)
            server_challenge = secrets.token_bytes(16)
            digest = hashlib.sha256(challenge + state.cert.signature + server_secret).digest()
            session.update(server_secret=server_secret, server_challenge=server_challenge, phase=2)
            encrypted = aes_ecb(session["key"], digest + server_challenge, True)
            return xml({"status_code": 200}, f"<paired>1</paired><challengeresponse>{encrypted.hex().upper()}</challengeresponse>")
        if "serverchallengeresp" in args and session["phase"] == 2:
            session["client_hash"] = aes_ecb(session["key"], bytes.fromhex(args["serverchallengeresp"]), False)
            signature = state.key.sign(session["server_secret"], padding.PKCS1v15(), hashes.SHA256())
            session["phase"] = 3
            return xml({"status_code": 200}, f"<paired>1</paired><pairingsecret>{(session['server_secret'] + signature).hex().upper()}</pairingsecret>")
        if "clientpairingsecret" in args and session["phase"] == 3:
            payload = bytes.fromhex(args["clientpairingsecret"])
            secret, signature = payload[:16], payload[16:]
            expected = hashlib.sha256(session["server_challenge"] + session["client_cert"].signature + secret).digest()
            ok = expected == session["client_hash"]
            try:
                session["client_cert"].public_key().verify(signature, secret, padding.PKCS1v15(), hashes.SHA256())
            except Exception:
                ok = False
            del state.sessions[uid]
            if ok:
                state.paired[uid] = session["client_pem"]
            return xml({"status_code": 200}, f"<paired>{1 if ok else 0}</paired>")
        del state.sessions[uid]
        return xml({"status_code": 400, "status_message": "Invalid pairing request"})


def start(pin):
    """Start the mock on a free localhost port. Returns (server, port, state)."""
    state = MockState(pin)
    handler = type("BoundHandler", (Handler,), {"state": state})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_port, state
