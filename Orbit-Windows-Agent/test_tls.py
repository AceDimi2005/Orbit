"""A TLS identity is local, persistent and never silently changes on an error."""
import os
import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
import socket
import ssl
import tempfile
import unittest
from unittest.mock import patch

import httpx
from fastapi import FastAPI, Request

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

import orbit_tls as tls


class TLSIdentityTests(unittest.TestCase):
    def test_certificate_fingerprint_matches_der_and_survives_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            certificate, key, fingerprint = tls.ensure_tls_identity(folder)
            original_key = key.read_bytes()
            parsed = x509.load_pem_x509_certificate(certificate.read_bytes())
            self.assertEqual(fingerprint.replace(":", "").lower(), parsed.fingerprint(hashes.SHA256()).hex())
            self.assertEqual(tls.ensure_tls_identity(folder), (certificate, key, fingerprint))
            self.assertEqual(key.read_bytes(), original_key)
            san = parsed.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            self.assertIn("localhost", san.get_values_for_type(x509.DNSName))
            self.assertEqual(parsed.public_key().key_size, 256)
            if os.name != "nt": self.assertEqual(key.stat().st_mode & 0o777, 0o600)

    def test_missing_half_does_not_overwrite_the_existing_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            certificate, key, _ = tls.ensure_tls_identity(folder)
            original = certificate.read_bytes()
            key.unlink()
            with self.assertRaises(RuntimeError): tls.ensure_tls_identity(folder)
            self.assertEqual(certificate.read_bytes(), original)
            self.assertFalse(key.exists())

    def test_different_private_key_is_rejected_without_rotating_certificate(self):
        with tempfile.TemporaryDirectory() as folder:
            certificate, key, _ = tls.ensure_tls_identity(folder)
            original = certificate.read_bytes()
            wrong = ec.generate_private_key(ec.SECP256R1())
            key.write_bytes(wrong.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            with self.assertRaises(RuntimeError): tls.ensure_tls_identity(folder)
            self.assertEqual(certificate.read_bytes(), original)


class DualServerTests(unittest.IsolatedAsyncioTestCase):
    async def test_legacy_and_secure_listeners_share_one_clean_lifespan(self):
        events = []
        @asynccontextmanager
        async def lifespan(app):
            events.append("start")
            yield
            events.append("stop")
        app = FastAPI(lifespan=lifespan)
        @app.get("/")
        def scheme(request: Request): return {"scheme": request.url.scheme}
        def port():
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                return sock.getsockname()[1]
        first, second = port(), port()
        while second == first: second = port()
        with tempfile.TemporaryDirectory() as directory:
            cert, key, _ = tls.ensure_tls_identity(directory)
            context = ssl.create_default_context(cafile=str(cert))
            task = asyncio.create_task(tls.serve_both(app, "127.0.0.1", first, second, cert, key))
            try:
                async with httpx.AsyncClient(trust_env=False, timeout=1, verify=context) as client:
                    for _ in range(100):
                        try:
                            insecure = await client.get(f"http://127.0.0.1:{first}/")
                            secure = await client.get(f"https://127.0.0.1:{second}/")
                            break
                        except httpx.ConnectError:
                            await asyncio.sleep(.025)
                    else: self.fail("Local HTTP and TLS listeners did not start")
                    self.assertEqual(insecure.json(), {"scheme": "http"})
                    self.assertEqual(secure.json(), {"scheme": "https"})
                    self.assertEqual(events, ["start"])
            finally:
                task.cancel()
                with self.assertRaises(asyncio.CancelledError): await task
            self.assertEqual(events, ["start", "stop"])


if __name__ == "__main__": unittest.main()
