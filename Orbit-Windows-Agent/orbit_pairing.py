"""LAN discovery and one-use PIN pairing. Credentials are encrypted by SRP, not the PIN.

SRP-6a uses the RFC 5054 2048-bit group and SHA-256, with fixed-width
proof encoding to interoperate with swift-srp. Bootstrap TLS is only a
transport: the SRP-encrypted response authenticates the real certificate.
"""
import base64
import ctypes
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import threading
import time
from collections import defaultdict, deque

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from srptools import SRPContext, SRPServerSession, constants

import orbit_paths

USERNAME = "orbit-pairing"
PROTOCOL = "orbit-srp6a-sha256-2048-v1"
KEY_INFO = b"Orbit PIN pairing v1"
PIN_SECONDS = 120


class PairingContext(SRPContext):
    """srptools arithmetic, with the fixed-width proof convention of swift-srp."""
    def __init__(self, password=None):
        super().__init__(USERNAME, password, prime=constants.PRIME_2048,
                         generator=constants.PRIME_2048_GEN, hash_func=hashlib.sha256,
                         bits_random=256, bits_salt=128)

    def get_common_session_key(self, premaster_secret):
        return self.hash(self.pad(premaster_secret), as_bytes=True)

    def get_common_session_key_proof(self, session_key, salt, server_public, client_public):
        left = hashlib.sha256(self.pad(self._prime)).digest()
        right = hashlib.sha256(self.pad(self._gen)).digest()
        return self.hash(bytes(a ^ b for a, b in zip(left, right)),
                         hashlib.sha256(USERNAME.encode()).digest(),
                         salt.to_bytes(16, "big") if isinstance(salt, int) else bytes(salt), self.pad(client_public),
                         self.pad(server_public), session_key, as_bytes=True)

    def get_common_session_key_proof_hash(self, session_key, session_key_proof, client_public):
        return self.hash(self.pad(client_public), session_key_proof, session_key, as_bytes=True)


def display_pin(name, pin):
    message = (f"Pair {name} with Orbit\n\nCode: {pin}\n\n"
               "Enter this code on your iPhone. It expires in 2 minutes and works once.\n"
               "If you did not request this connection, ignore the code.")
    # The code is only for the person at this PC: never into the background log file.
    if os.name != "nt" or orbit_paths.interactive_console():
        print("\n" + message + "\n", flush=True)
    cancelled = threading.Event()
    if os.name == "nt":
        def show():
            from ctypes import wintypes
            # The dialog owns a timer in its own message loop, so ignoring a
            # code cannot accumulate permanent windows or waiting threads.
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            title = "Orbit · Pair your iPhone · " + secrets.token_hex(6)
            timer_proc = ctypes.WINFUNCTYPE(None, wintypes.HWND, wintypes.UINT, ctypes.c_size_t, wintypes.DWORD)
            user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
            user32.FindWindowW.restype = wintypes.HWND
            user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_size_t, ctypes.c_ssize_t]
            user32.PostMessageW.restype = wintypes.BOOL
            user32.SetTimer.argtypes = [wintypes.HWND, ctypes.c_size_t, wintypes.UINT, timer_proc]
            user32.SetTimer.restype = ctypes.c_size_t
            user32.KillTimer.argtypes = [wintypes.HWND, ctypes.c_size_t]
            user32.KillTimer.restype = wintypes.BOOL
            user32.MessageBoxW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
            user32.MessageBoxW.restype = ctypes.c_int
            deadline = time.monotonic() + PIN_SECONDS
            @timer_proc
            def tick(hwnd, event, identifier, milliseconds):
                if cancelled.is_set() or time.monotonic() >= deadline:
                    window = user32.FindWindowW("#32770", title)
                    if window:
                        user32.PostMessageW(window, 0x0010, 0, 0)  # WM_CLOSE
            timer = user32.SetTimer(None, 0, 250, tick)
            if not timer:
                return  # The console still displays the code; never create an unbounded dialog.
            try:
                if not cancelled.is_set():
                    user32.MessageBoxW(None, message, title, 0x00040040)
            finally:
                user32.KillTimer(None, timer)
        threading.Thread(target=show, daemon=True, name="orbit-pairing-code").start()
    return cancelled.set


class PairingManager:
    def __init__(self, fingerprint, payload, show_pin=display_pin, clock=time.monotonic):
        self.fingerprint = fingerprint.replace(":", "").lower()
        self.payload = payload
        self.show_pin = show_pin
        self.clock = clock
        self._lock = threading.Lock()
        self._sessions = {}
        self._starts = defaultdict(deque)
        self._global_starts = deque()

    def start(self, peer, name, public):
        if not re.fullmatch(r"[0-9a-fA-F]{1,512}", public):
            raise HTTPException(400, "Invalid pairing key")
        context = PairingContext()
        value = int(public, 16)
        if value <= 0 or value >= context._prime:
            raise HTTPException(400, "Invalid pairing key")
        name = "".join(c for c in name if c.isprintable()).strip()[:60] or "iPhone"
        now = self.clock()
        with self._lock:
            for key in list(self._sessions):
                if self._sessions[key]["expires"] <= now:
                    self._dismiss(self._sessions.pop(key))
            # Bounded global and per-address rates also bound native PIN dialogs.
            peer_starts = self._starts.get(peer, deque())
            for queue in (peer_starts, self._global_starts):
                while queue and now - queue[0] >= 600:
                    queue.popleft()
            if len(peer_starts) >= 5 or len(self._global_starts) >= 10:
                raise HTTPException(429, "Too many pairing attempts. Wait 10 minutes and try again.")
            if self._sessions:
                raise HTTPException(409, "A pairing code is already active. Complete it or wait 2 minutes.")
            self._starts[peer] = peer_starts
            peer_starts.append(now); self._global_starts.append(now)
            # Expire unused peer buckets so unauthenticated traffic cannot grow memory indefinitely.
            for key in list(self._starts):
                if key != peer and (not self._starts[key] or now - self._starts[key][-1] >= 600):
                    del self._starts[key]
            pin = f"{secrets.randbelow(1000000):06d}"
            context = PairingContext(pin)
            # Fixed salt width includes a leading nonzero byte for srptools integer conversion.
            salt = bytes([secrets.randbelow(255) + 1]) + secrets.token_bytes(15)
            verifier = context.get_common_password_verifier(context.get_common_password_hash(int.from_bytes(salt, "big")))
            server = SRPServerSession(context, f"{verifier:x}", private=secrets.token_hex(32))
            server.process(public, salt.hex())
            identifier = secrets.token_urlsafe(24)
            self._sessions[identifier] = {"server": server, "peer": peer, "expires": now + PIN_SECONDS}
            result = {"id": identifier, "protocol": PROTOCOL, "salt": salt.hex(),
                      "serverPublic": server.public.zfill(512), "expiresIn": PIN_SECONDS}
        try:
            dismiss = self.show_pin(name, pin)
            with self._lock:
                if identifier in self._sessions:
                    self._sessions[identifier]["dismiss"] = dismiss
                elif callable(dismiss):
                    dismiss()
        except Exception:
            with self._lock:
                self._sessions.pop(identifier, None)
            raise HTTPException(503, "Could not display a pairing code on the PC")
        return result

    def finish(self, peer, identifier, proof, host):
        with self._lock:
            session = self._sessions.get(identifier)
            if session is None or session["expires"] <= self.clock():
                expired = self._sessions.pop(identifier, None)
                if expired is not None:
                    self._dismiss(expired)
                raise HTTPException(410, "Pairing code expired. Search for the PC and request a new code.")
            if not hmac.compare_digest(session["peer"], peer):
                raise HTTPException(403, "Pairing connection changed. Request a new code.")
            # One proof only: a wrong PIN consumes the session instead of creating an oracle.
            self._sessions.pop(identifier)
            self._dismiss(session)
        server = session["server"]
        expected = server.key_proof.decode("ascii") if isinstance(server.key_proof, bytes) else server.key_proof
        if not re.fullmatch(r"[0-9a-fA-F]{64}", proof) or not hmac.compare_digest(expected.lower(), proof.lower()):
            raise HTTPException(403, "Incorrect pairing code. Request a new code from the PC.")
        raw_key = bytes.fromhex(server.key.decode("ascii") if isinstance(server.key, bytes) else server.key)
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=identifier.encode(), info=KEY_INFO).derive(raw_key)
        payload = dict(self.payload(host))
        payload["certificateFingerprint"] = self.fingerprint
        nonce = secrets.token_bytes(12)
        ciphertext = AESGCM(key).encrypt(nonce, json.dumps(payload).encode(), identifier.encode())
        server_proof = server.key_proof_hash
        return {"serverProof": server_proof.decode("ascii") if isinstance(server_proof, bytes) else server_proof,
                "nonce": base64.b64encode(nonce).decode(), "ciphertext": base64.b64encode(ciphertext).decode()}

    def close(self):
        with self._lock:
            for session in self._sessions.values():
                self._dismiss(session)
            self._sessions.clear()

    @staticmethod
    def _dismiss(session):
        dismiss = session.get("dismiss")
        if callable(dismiss):
            dismiss()


class StartPairing(BaseModel):
    name: str = Field(default="iPhone", max_length=80)
    clientPublic: str = Field(min_length=1, max_length=512)


class FinishPairing(BaseModel):
    id: str = Field(min_length=20, max_length=80)
    proof: str = Field(min_length=64, max_length=64)


def create_pairing_router(manager):
    router = APIRouter(prefix="/api/pair")

    def service(request):
        if request.url.scheme != "https":
            raise HTTPException(426, "Pairing requires HTTPS")
        value = manager()
        if value is None:
            raise HTTPException(503, "Restart Orbit PC Companion on the PC to enable automatic pairing")
        return value

    @router.post("/start")
    def start(body: StartPairing, request: Request):
        from fastapi.responses import JSONResponse
        result = service(request).start(request.client.host, body.name, body.clientPublic)
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    @router.post("/finish")
    def finish(body: FinishPairing, request: Request):
        from fastapi.responses import JSONResponse
        local_address = (request.scope.get("server") or (None,))[0]
        result = service(request).finish(request.client.host, body.id, body.proof, local_address or request.url.hostname)
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    return router


class OrbitAdvertisement:
    def __init__(self, port, fingerprint, version):
        self.port = port; self.fingerprint = fingerprint; self.version = version
        self.zeroconf = None; self.info = None

    def start(self):
        import psutil
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
        addresses = sorted({a.address for entries in psutil.net_if_addrs().values() for a in entries
                            if a.family == socket.AF_INET and not a.address.startswith(("127.", "169.254."))})
        if not addresses:
            return
        self.zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
        suffix = self.fingerprint.replace(":", "").lower()[:12]
        host = socket.gethostname()
        self.info = ServiceInfo("_orbit._tcp.local.", f"Orbit {suffix}._orbit._tcp.local.",
                                parsed_addresses=addresses, port=self.port,
                                properties={"name": host, "version": self.version,
                                            "fingerprint": self.fingerprint.replace(":", "").lower(),
                                            "pairing": PROTOCOL}, server=f"orbit-{suffix}.local.")
        try:
            self.zeroconf.register_service(self.info)
        except BaseException:
            self.zeroconf.close(); self.zeroconf = None
            raise

    def close(self):
        if self.zeroconf is not None:
            try:
                if self.info is not None:
                    self.zeroconf.unregister_service(self.info)
            finally:
                self.zeroconf.close(); self.zeroconf = None
