"""Who may call what: one table maps every route to a scope, enforced in one place.

Every HTTP request passes the AccessMiddleware before routing. It finds the route,
looks up its policy, authenticates the bearer token (a paired device), requires
HTTPS where the policy says so, and checks the device's scopes. WebSockets are
checked by their handlers with the same policies (`websocket_principal`).

Errors are machine-readable and keep a human `detail`:
  401 {"code": "invalid_token" | "device_revoked", "detail": ...}
  403 {"code": "scope_missing", "scope": "files", "detail": ...}
  426 {"code": "https_required", "detail": ...}
"""
from contextvars import ContextVar
from dataclasses import dataclass, field
import time

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.routing import compile_path

from urllib.parse import parse_qsl

from orbit_devices import AccessError, SCOPES, scope_missing

READ, CONTROL, INPUT, FILES, ADMIN = SCOPES
STATE_CHANGING = frozenset({"POST", "PUT", "PATCH", "DELETE"})


def https_required():
    return AccessError(426, "https_required",
                       "This needs Orbit's encrypted connection (HTTPS port 8766). Update the app or pair this PC again.")


@dataclass(frozen=True)
class Policy:
    scope: str | None = None   # Required scope; None: any paired device.
    secure: bool = False       # HTTPS (port 8766) only.
    public: bool = False       # No device token: bootstrap, widget token or master token routes.
    category: str | None = None
    action: str | None = None
    log: bool | None = None    # Activity log; default: every state-changing request.

    def logs(self, method):
        return self.log if self.log is not None else method in STATE_CHANGING


P = Policy
PUBLIC = P(public=True)
# Unknown routes need the most trust; tests require an explicit policy for every route.
DEFAULT_POLICY = P(ADMIN, secure=True)

POLICIES = {
    # Bootstrap and routes with their own credential checks.
    ("GET", "/api/discover"): PUBLIC,
    ("POST", "/api/pair/start"): PUBLIC,
    ("POST", "/api/pair/finish"): PUBLIC,
    ("GET", "/api/widget/status"): PUBLIC,          # Read-only widget token, checked by the endpoint.
    ("POST", "/api/internal/handover"): PUBLIC,     # Master token from loopback only, checked by the endpoint.
    ("GET", "/api/capabilities"): P(None, secure=True),

    # read: status, hardware, history, library, power and audio state.
    ("GET", "/api/network-info"): P(READ),
    ("GET", "/api/specs"): P(READ),
    ("GET", "/api/status"): P(READ),
    ("GET", "/api/watch/summary"): P(READ),
    ("GET", "/api/processes"): P(READ),
    ("GET", "/api/icons"): P(READ),
    ("GET", "/api/sunshine/info"): P(READ),
    ("GET", "/api/sunshine/apps"): P(READ),
    ("GET", "/api/audio/sessions"): P(READ, secure=True),
    ("GET", "/api/audio/outputs"): P(READ, secure=True),
    ("GET", "/api/audio/microphone"): P(READ, secure=True),
    ("GET", "/api/history/sessions"): P(READ, secure=True),
    ("GET", "/api/history/sessions/{session_id}"): P(READ, secure=True),
    # The widget token it returns can only read, so reading is enough to set widgets up.
    ("POST", "/api/widget/pairing"): P(READ, secure=True, log=False),

    # control: actions, volume and audio, apps, Sunshine, history recording.
    ("POST", "/api/action/{action_name}"): P(CONTROL, category="system", action="action"),
    ("POST", "/api/volume"): P(CONTROL, category="audio", action="volume.set"),
    ("POST", "/api/processes/{pid}/terminate"): P(CONTROL, category="apps", action="process.end"),
    ("POST", "/api/audio/session"): P(CONTROL, secure=True, category="audio", action="audio.session"),
    ("POST", "/api/audio/route"): P(CONTROL, secure=True, category="audio", action="audio.route"),
    ("POST", "/api/audio/default"): P(CONTROL, secure=True, category="audio", action="audio.default"),
    ("POST", "/api/audio/microphone"): P(CONTROL, secure=True, category="audio", action="audio.microphone"),
    ("POST", "/api/sunshine/pin"): P(CONTROL, category="sunshine", action="sunshine.pin"),
    ("POST", "/api/sunshine/start"): P(CONTROL, category="sunshine", action="sunshine.start"),
    ("POST", "/api/sunshine/launch"): P(CONTROL, category="apps", action="sunshine.launch"),
    ("POST", "/api/history/start"): P(CONTROL, secure=True, category="history", action="history.start"),
    ("POST", "/api/history/stop"): P(CONTROL, secure=True, category="history", action="history.stop"),
    ("DELETE", "/api/history/sessions/{session_id}"): P(CONTROL, secure=True, category="history", action="history.delete"),

    # input: mouse, keyboard, gamepad keys, clipboard (the screen preview is a WebSocket).
    # Single input events are not logged one by one; an input session is.
    ("POST", "/api/input/mouse"): P(INPUT, log=False),
    ("POST", "/api/input/cursor"): P(INPUT, log=False),
    ("POST", "/api/input/keyboard"): P(INPUT, log=False),
    ("POST", "/api/input/gamepad"): P(INPUT, log=False),
    ("GET", "/api/clipboard"): P(INPUT, secure=True, category="clipboard", action="clipboard.read", log=True),
    ("PUT", "/api/clipboard"): P(INPUT, secure=True, category="clipboard", action="clipboard.write"),

    # files: everything under /api/files, HTTPS only.
    ("GET", "/api/files/roots"): P(FILES, secure=True),
    ("GET", "/api/files/list"): P(FILES, secure=True),
    ("GET", "/api/files/download"): P(FILES, secure=True, category="files", action="files.download", log=True),
    ("POST", "/api/files/upload"): P(FILES, secure=True, category="files", action="files.upload"),
    ("POST", "/api/files/mkdir"): P(FILES, secure=True, category="files", action="files.mkdir"),
    ("POST", "/api/files/rename"): P(FILES, secure=True, category="files", action="files.rename"),
    ("POST", "/api/files/move"): P(FILES, secure=True, category="files", action="files.move"),
    ("POST", "/api/files/trash"): P(FILES, secure=True, category="files", action="files.trash"),
    ("POST", "/api/files/archive"): P(FILES, secure=True, category="files", action="files.archive"),
    ("GET", "/api/files/archive/{identifier}"): P(FILES, secure=True),
    ("GET", "/api/files/archive/{identifier}/download"): P(FILES, secure=True, category="files",
                                                            action="files.archive.download", log=True),
    ("DELETE", "/api/files/archive/{identifier}"): P(FILES, secure=True, log=False),

    # admin: devices, settings, updates, the Sunshine login.
    ("GET", "/api/devices"): P(ADMIN, secure=True),
    ("POST", "/api/devices"): P(ADMIN, secure=True, category="devices", action="device.create"),
    ("PATCH", "/api/devices/{device_id}"): P(ADMIN, secure=True, category="devices", action="device.update"),
    # Admin, or a device removing itself ("Forget this PC"): checked by the endpoint.
    ("DELETE", "/api/devices/{device_id}"): P(None, secure=True, category="devices", action="device.revoke"),
    ("GET", "/api/update/check"): P(ADMIN),
    ("POST", "/api/update/apply"): P(ADMIN, secure=True, category="update", action="update.apply"),
    ("POST", "/api/sunshine/credentials"): P(ADMIN, secure=True, category="sunshine", action="sunshine.login.save"),
    ("DELETE", "/api/sunshine/credentials"): P(ADMIN, secure=True, category="sunshine", action="sunshine.login.remove"),

    # Power: the Windows countdown can be stopped from any device that may run power actions,
    # over HTTP too, so even the oldest Watch build can cancel what it started.
    ("POST", "/api/power/cancel"): P(CONTROL, category="power", action="power.cancel"),
    ("GET", "/api/power"): P(READ, secure=True),
    ("POST", "/api/power/timer"): P(CONTROL, secure=True, category="power", action="power.timer"),
    ("DELETE", "/api/power/timer"): P(CONTROL, secure=True, category="power", action="power.timer.cancel"),
    ("PUT", "/api/power/keep-awake"): P(CONTROL, secure=True, category="power", action="power.keepAwake"),
    ("DELETE", "/api/power/keep-awake"): P(CONTROL, secure=True, category="power", action="power.keepAwake.stop"),
    ("PUT", "/api/power/plan"): P(CONTROL, secure=True, category="power", action="power.plan"),

    # Game library.
    ("GET", "/api/library"): P(READ, secure=True),
    ("GET", "/api/library/covers/{cover_id}"): P(READ, secure=True),
    ("POST", "/api/library/rescan"): P(CONTROL, secure=True, log=False),
    ("POST", "/api/library/{game_id}/launch"): P(CONTROL, secure=True, category="apps", action="library.launch"),

    # Activity and settings belong to the owner.
    ("GET", "/api/activity"): P(ADMIN, secure=True),
    ("GET", "/api/settings"): P(ADMIN, secure=True),
    ("PATCH", "/api/settings"): P(ADMIN, secure=True, category="settings", action="settings.change"),
    ("GET", "/api/settings/notifications"): P(ADMIN, secure=True),
    ("PATCH", "/api/settings/notifications"): P(ADMIN, secure=True, category="settings", action="settings.notifications"),

    # WebSockets, enforced by their handlers.
    ("WS", "/ws/input"): P(INPUT),
    ("WS", "/ws/stream"): P(INPUT, category="screen", action="screen.view"),
}


@dataclass
class RequestContext:
    principal: object
    policy: Policy
    method: str
    path: str
    path_params: dict = field(default_factory=dict)
    query: dict = field(default_factory=dict)
    address: str | None = None
    started: float = field(default_factory=time.monotonic)
    notes: dict = field(default_factory=dict)


CURRENT = ContextVar("orbit_request", default=None)


def current_context():
    return CURRENT.get()


def current_principal():
    context = CURRENT.get()
    return context.principal if context is not None else None


def note(**values):
    """Let an endpoint describe what it did for the activity log (summary, action, category…)."""
    context = CURRENT.get()
    if context is not None:
        context.notes.update({key: value for key, value in values.items() if value is not None})


def policy_for(method, path, policies=None):
    method = "GET" if method == "HEAD" else method
    return (policies or POLICIES).get((method, path), DEFAULT_POLICY)


class PolicyTable:
    """Matches a request path against the route templates of the policy table itself, so
    enforcement never depends on how a FastAPI version stores included routers. A path
    no policy knows gets DEFAULT_POLICY (paired admin over HTTPS) before any 404/405."""

    def __init__(self, policies):
        self.entries = []
        for (method, template), policy in policies.items():
            if method == "WS":
                continue
            regex, _, convertors = compile_path(template)
            self.entries.append((len(convertors), regex, method, template, policy))
        # Literal paths before templated ones ("/api/library/rescan" before "/api/library/{id}").
        self.entries.sort(key=lambda entry: entry[0])

    def resolve(self, method, path):
        method = "GET" if method == "HEAD" else method
        known = None
        for _, regex, entry_method, template, policy in self.entries:
            match = regex.match(path)
            if match is None:
                continue
            if entry_method == method:
                return template, policy, match.groupdict()
            known = known or template
        return known, DEFAULT_POLICY, {}


def error_response(error):
    return JSONResponse(error.body(), status_code=error.status, headers=error.headers())


class AccessMiddleware:
    """Pure ASGI, so streamed uploads and downloads pass through untouched."""

    def __init__(self, app, *, authenticate, policies=None, observer=None):
        self.app = app
        self.authenticate = authenticate
        self.table = PolicyTable(policies or POLICIES)
        self.observer = observer

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        method = scope["method"]
        template, policy, path_params = self.table.resolve(method, scope.get("path", ""))
        if policy.public:
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        address = (scope.get("client") or (None,))[0]
        try:
            principal = self.authenticate(headers.get("authorization"), address)
        except AccessError as error:
            await error_response(error)(scope, receive, send)
            return
        query = dict(parse_qsl(scope.get("query_string", b"").decode("latin-1"), keep_blank_values=True))
        context = RequestContext(principal, policy, method, template or scope.get("path", ""), dict(path_params), query, address)
        try:
            if policy.secure and scope.get("scheme") not in ("https", "wss"):
                raise https_required()
            if not principal.has(policy.scope):
                raise scope_missing(policy.scope)
        except AccessError as error:
            # A paired device tried something it may not do: the owner sees it in the activity log.
            await error_response(error)(scope, receive, send)
            self._observe(context, error.status)
            return
        scope.setdefault("state", {})["orbit_principal"] = principal
        status = {"code": None}

        async def capture(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]
            await send(message)

        token = CURRENT.set(context)
        try:
            await self.app(scope, receive, capture)
        except Exception:
            status["code"] = status["code"] or 500
            raise
        finally:
            CURRENT.reset(token)
            self._observe(context, status["code"])

    def _observe(self, context, status):
        if self.observer is not None:
            try:
                self.observer(context, status)
            except Exception:
                pass


def websocket_principal(websocket, path, authenticate, policies=None):
    """The device behind a WebSocket, or None when it may not open this one."""
    policy = (policies or POLICIES).get(("WS", path), DEFAULT_POLICY)
    address = websocket.client.host if websocket.client else None
    try:
        principal = authenticate(websocket.headers.get("authorization"), address)
    except AccessError:
        return None
    if policy.secure and websocket.url.scheme not in ("https", "wss"):
        return None
    return principal if principal.has(policy.scope) else None
