"""Persistent per-PC TLS identity for encrypted companion features."""
import ipaddress
import os
import socket
import ssl
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psutil
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def data_directory():
    base = Path(os.getenv("LOCALAPPDATA") or (Path.home() / ".local" / "share"))
    return base / "Orbit"


def local_names():
    names = {"localhost", socket.gethostname().lower()}
    names.add(socket.gethostname().lower() + ".local")
    addresses = {ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("::1")}
    for entries in psutil.net_if_addrs().values():
        for entry in entries:
            if entry.family in (socket.AF_INET, socket.AF_INET6):
                try:
                    addresses.add(ipaddress.ip_address(entry.address.split("%", 1)[0]))
                except ValueError:
                    pass
    return [x509.DNSName(name.encode("idna").decode("ascii")) for name in sorted(names) if name] + [x509.IPAddress(address) for address in sorted(addresses, key=str)]


def ensure_tls_identity(directory=None):
    """Reuse the pinned identity. Invalid existing files never rotate silently."""
    directory = Path(directory) if directory is not None else data_directory() / "tls"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    certificate_path, key_path = directory / "server-cert.pem", directory / "server-key.pem"
    if certificate_path.exists() != key_path.exists():
        raise RuntimeError("Orbit TLS identity is incomplete. Restore both certificate and key, or remove both to pair this PC again.")
    if not certificate_path.exists():
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Orbit PC Companion")])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                       .public_key(key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=3650))
                       .add_extension(x509.SubjectAlternativeName(local_names()), critical=False)
                       .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                       .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                       .sign(key, hashes.SHA256()))
        key_bytes = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        # Never place a private key in the distributable agent folder.
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(key_bytes)
        try:
            certificate_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        except BaseException:
            key_path.unlink(missing_ok=True)
            raise
    certificate = x509.load_pem_x509_certificate(certificate_path.read_bytes())
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if certificate.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo):
        raise RuntimeError("Orbit TLS certificate and key do not match.")
    now = datetime.now(timezone.utc)
    if not certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc:
        raise RuntimeError("Orbit TLS certificate has expired or is not valid yet. Check the PC clock; a new identity requires pairing again.")
    fingerprint = certificate.fingerprint(hashes.SHA256()).hex().upper()
    return certificate_path, key_path, ":".join(fingerprint[index:index + 2] for index in range(0, len(fingerprint), 2))


async def serve_both(app, host, port, secure_port, certificate, key):
    """One application lifespan; legacy LAN clients and pinned HTTPS coexist."""
    import asyncio
    import uvicorn

    if not 1 <= port <= 65535 or not 1 <= secure_port <= 65535:
        raise ValueError("Orbit listening ports must be between 1 and 65535")
    if port == secure_port:
        raise ValueError("ORBIT_PORT and ORBIT_TLS_PORT must be different")
    common = dict(host=host, log_level="warning", access_log=False, proxy_headers=False)
    legacy = uvicorn.Server(uvicorn.Config(app, port=port, lifespan="on", **common))
    secure = uvicorn.Server(uvicorn.Config(app, port=secure_port, lifespan="off", ssl_certfile=str(certificate),
                                         ssl_keyfile=str(key), ssl_version=ssl.PROTOCOL_TLS_SERVER, **common))
    # Both servers must observe the same stop signal, and only one runs startup.
    async def run(server):
        if hasattr(server, "_serve"):
            await server._serve()
        else:
            server.install_signal_handlers = lambda: None
            await server.serve()
    tasks = [asyncio.create_task(run(legacy)), asyncio.create_task(run(secure))]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        legacy.should_exit = True; secure.should_exit = True
        await asyncio.gather(*tasks)
