"""The companion window: a local web UI on 127.0.0.1 only, opened as an app window.

How a session starts: the tray (left click) asks for a one-time launch code, valid for
60 seconds, and opens `msedge --app=http://127.0.0.1:8767/open?code=…` (or the default
browser). The code is exchanged once for an HttpOnly, SameSite=Strict session cookie and
the address bar is redirected to `/` so the code is gone.

Every request is checked before anything else:
- the Host header must be 127.0.0.1:<port> or localhost:<port> (DNS rebinding),
- API calls need the session cookie and the `X-Orbit-Window` header, which a page from
  another origin cannot send without a CORS preflight this server never answers,
- state-changing calls must come from this origin (Origin header),
- responses carry a nonce-based Content-Security-Policy and are never cached.

The server knows nothing about devices or settings itself: the agent passes a backend
object (see `WindowBackend`), which is faked in the tests.
"""
import hmac
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
import webbrowser

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool

from orbit_window_ui import render_page

WINDOW_PORT = int(os.getenv("ORBIT_WINDOW_PORT", "8767"))
COOKIE = "orbit_window"
LAUNCH_SECONDS = 60
SESSION_IDLE_SECONDS = 12 * 3600
MAX_SESSIONS = 8
WINDOW_SIZE = "1180,820"


class WindowSessions:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self._codes = {}
        self._sessions = {}
        self._lock = threading.Lock()

    def issue_launch_code(self):
        code = secrets.token_urlsafe(32)
        now = self.clock()
        with self._lock:
            self._codes = {key: expires for key, expires in self._codes.items() if expires > now}
            self._codes[code] = now + LAUNCH_SECONDS
        return code

    def redeem(self, code):
        """A new session for a valid, unused, unexpired code; None otherwise. Codes work once."""
        if not isinstance(code, str) or not code:
            return None
        now = self.clock()
        with self._lock:
            match = next((key for key in self._codes if hmac.compare_digest(key, code)), None)
            expires = self._codes.pop(match, None) if match else None
            if expires is None or expires <= now:
                return None
            session = secrets.token_urlsafe(32)
            self._sessions[session] = now
            while len(self._sessions) > MAX_SESSIONS:
                oldest = min(self._sessions, key=self._sessions.get)
                del self._sessions[oldest]
            return session

    def valid(self, session):
        if not isinstance(session, str) or not session:
            return False
        now = self.clock()
        with self._lock:
            match = next((key for key in self._sessions if hmac.compare_digest(key, session)), None)
            if match is None:
                return False
            if now - self._sessions[match] > SESSION_IDLE_SECONDS:
                del self._sessions[match]
                return False
            self._sessions[match] = now
            return True

    def end_all(self):
        with self._lock:
            self._sessions.clear()
            self._codes.clear()


class WindowBackend:
    """What the window can read and change; the agent implements it (orbit_agent.AgentWindowBackend)."""

    def overview(self): raise NotImplementedError
    def devices(self): raise NotImplementedError
    def update_device(self, device_id, name=None, scopes=None): raise NotImplementedError
    def remove_device(self, device_id): raise NotImplementedError
    def add_manual_device(self): raise NotImplementedError
    def activity(self, before=None, category=None, limit=50): raise NotImplementedError
    def settings(self): raise NotImplementedError
    def update_settings(self, changes): raise NotImplementedError
    def set_boot_task(self, enabled): raise NotImplementedError
    def diagnostics(self, force=False): raise NotImplementedError
    def fix(self, kind, interface_index=None): raise NotImplementedError
    def check_updates(self): raise NotImplementedError
    def install_update(self): raise NotImplementedError
    def restart(self): raise NotImplementedError


class DeviceChange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str | None = Field(default=None, min_length=1, max_length=60)
    scopes: list[str] | None = Field(default=None, max_length=5)


class SettingsChange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    runAtStartup: StrictBool | None = None
    notifications: dict | None = None
    monitoring: dict | None = None
    updates: dict | None = None


class BootTaskChange(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: StrictBool


class FixRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: str = Field(pattern=r"^(firewall|privateNetwork)$")
    interfaceIndex: int | None = Field(default=None, ge=1, le=999_999)


SECURITY_HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
                    "Referrer-Policy": "no-referrer", "Cross-Origin-Opener-Policy": "same-origin",
                    "Cross-Origin-Resource-Policy": "same-origin"}


def create_window_app(backend, sessions, port=WINDOW_PORT):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    origins = {f"http://{host}" for host in hosts}

    @app.middleware("http")
    async def guard(request: Request, call_next):
        host = (request.headers.get("host") or "").lower()
        if host not in hosts:
            return JSONResponse({"detail": "Open Orbit from its icon in the Windows tray."}, status_code=403,
                                headers=SECURITY_HEADERS)
        if request.url.path.startswith("/local/api/"):
            if request.headers.get("x-orbit-window") != "1" or not sessions.valid(request.cookies.get(COOKIE)):
                return JSONResponse({"detail": "This window has expired. Open Orbit from the tray again.", "code": "session"},
                                    status_code=401, headers=SECURITY_HEADERS)
            if request.method not in ("GET", "HEAD") and request.headers.get("origin") not in origins:
                return JSONResponse({"detail": "Changes are accepted only from the Orbit window."}, status_code=403,
                                    headers=SECURITY_HEADERS)
        response = await call_next(request)
        for key, value in SECURITY_HEADERS.items():
            response.headers.setdefault(key, value)
        return response

    def page(request, signed_in):
        nonce = secrets.token_urlsafe(16)
        csp = (f"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; img-src 'self' data:; "
               "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        return HTMLResponse(render_page(nonce, signed_in), headers={"Content-Security-Policy": csp})

    @app.get("/")
    def index(request: Request):
        return page(request, sessions.valid(request.cookies.get(COOKIE)))

    @app.get("/open")
    def open_window(code: str = Query("", max_length=128)):
        session = sessions.redeem(code)
        response = RedirectResponse("/", status_code=303)
        if session:
            response.set_cookie(COOKIE, session, httponly=True, samesite="strict", path="/")
        return response

    def run(operation):
        try:
            return operation()
        except KeyError as error:
            raise HTTPException(404, "This device is no longer paired.") from error
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        except PermissionError as error:
            raise HTTPException(409, str(error)) from error
        except OSError as error:
            raise HTTPException(503, str(error) or "Windows could not do this.") from error

    @app.get("/local/api/overview")
    def overview():
        return run(backend.overview)

    @app.get("/local/api/devices")
    def devices():
        return run(backend.devices)

    @app.patch("/local/api/devices/{device_id}")
    def change_device(device_id: str, body: DeviceChange):
        if body.name is None and body.scopes is None:
            raise HTTPException(422, "Send a new name or access.")
        return run(lambda: backend.update_device(device_id, body.name, body.scopes))

    @app.delete("/local/api/devices/{device_id}")
    def remove_device(device_id: str):
        return run(lambda: backend.remove_device(device_id))

    @app.post("/local/api/devices/manual")
    def manual_device():
        return run(backend.add_manual_device)

    @app.get("/local/api/activity")
    def activity(before: int | None = Query(None, ge=1), category: str | None = Query(None, max_length=20),
                 limit: int = Query(50, ge=1, le=200)):
        return run(lambda: backend.activity(before, category, limit))

    @app.get("/local/api/settings")
    def settings():
        return run(backend.settings)

    @app.patch("/local/api/settings")
    def change_settings(body: SettingsChange):
        changes = body.model_dump(exclude_none=True)
        if not changes:
            raise HTTPException(422, "Send at least one setting.")
        return run(lambda: backend.update_settings(changes))

    @app.post("/local/api/settings/boot-task")
    def boot_task(body: BootTaskChange):
        return run(lambda: backend.set_boot_task(body.enabled))

    @app.get("/local/api/diagnostics")
    def diagnostics(force: bool = False):
        return run(lambda: backend.diagnostics(force))

    @app.post("/local/api/diagnostics/fix")
    def fix(body: FixRequest):
        if body.kind == "privateNetwork" and body.interfaceIndex is None:
            raise HTTPException(422, "Choose the network to make Private.")
        return run(lambda: backend.fix(body.kind, body.interfaceIndex))

    @app.post("/local/api/updates/check")
    def check_updates():
        return run(backend.check_updates)

    @app.post("/local/api/updates/install")
    def install_update():
        return run(backend.install_update)

    @app.post("/local/api/restart")
    def restart():
        return run(backend.restart)

    return app


def find_edge(environ=os.environ, exists=os.path.isfile, registry=None):
    """msedge.exe from the usual install folders or Windows' App Paths, or None."""
    candidates = []
    for variable in ("PROGRAMFILES(X86)", "ProgramFiles(x86)", "PROGRAMFILES", "ProgramFiles", "LOCALAPPDATA"):
        base = environ.get(variable)
        if base:
            candidates.append(str(Path(base) / "Microsoft" / "Edge" / "Application" / "msedge.exe"))
    if registry is None and os.name == "nt":
        import winreg as registry
    if registry is not None:
        for root in (registry.HKEY_CURRENT_USER, registry.HKEY_LOCAL_MACHINE):
            try:
                with registry.OpenKey(root, r"Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe") as key:
                    candidates.append(registry.QueryValueEx(key, "")[0])
            except OSError:
                continue
    return next((candidate for candidate in candidates if candidate and exists(candidate)), None)


def open_app_window(url, edge=None, launcher=None, browser=webbrowser.open):
    """An app-style window (no tabs or address bar) in Edge, else the default browser."""
    edge = edge if edge is not None else find_edge()
    if edge:
        launch = launcher or (lambda arguments: subprocess.Popen(arguments, close_fds=True))
        launch([edge, f"--app={url}", f"--window-size={WINDOW_SIZE}", "--no-first-run"])
        return "edge"
    browser(url)
    return "browser"
