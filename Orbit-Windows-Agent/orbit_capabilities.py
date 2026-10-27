"""Which optional features this agent has (`GET /api/capabilities`).

Clients ask once per connection and show a feature only when its string is listed. An agent
without this route (404) is an older agent with none of them. A feature registers its string
when its routes are wired into the app, so the list always matches what the agent can do.
"""
import re
import threading

# Every feature string the apps know about. Registering anything else is a programming error,
# because no client would ever look for it.
KNOWN_FEATURES = (
    "events", "alerts", "downloads", "tasks", "powerAfter", "push", "openUrl", "hotkeys", "deck",
    "obs", "energy", "summary", "presentation", "streamDisplay", "secondScreen", "webcam", "powerCountdown",
)
_FEATURE_NAME = re.compile(r"^[a-z][A-Za-z0-9]{0,39}$")

_LOCK = threading.Lock()
_FEATURES = []
_AGENT_VERSION = ""


def register_feature(name):
    """Adds a feature string once; registering the same feature again changes nothing."""
    if not isinstance(name, str) or not _FEATURE_NAME.match(name):
        raise ValueError(f"Invalid feature name: {name!r}")
    if name not in KNOWN_FEATURES:
        raise ValueError(f"Unknown feature name: {name!r}. Add it to KNOWN_FEATURES and DESIGN.md first.")
    with _LOCK:
        if name not in _FEATURES:
            _FEATURES.append(name)


def unregister_feature(name):
    """Removes a feature string (for a feature that turned out to be unavailable, and for tests)."""
    with _LOCK:
        if name in _FEATURES:
            _FEATURES.remove(name)


def registered_features():
    with _LOCK:
        return list(_FEATURES)


def has_feature(name):
    with _LOCK:
        return name in _FEATURES


def set_agent_version(version):
    global _AGENT_VERSION
    if not isinstance(version, str) or not version:
        raise ValueError("The agent version must be a non-empty string")
    with _LOCK:
        _AGENT_VERSION = version


def capabilities_payload(agent_version=None):
    """`{"agentVersion": "4.4.0", "features": ["events", ...]}` in registration order."""
    with _LOCK:
        return {"agentVersion": agent_version or _AGENT_VERSION, "features": list(_FEATURES)}
