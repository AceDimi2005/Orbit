"""Notifications on the PC itself (tray balloons, which Windows 10 and 11 show as toasts).

`orbit_agent`'s `__main__` registers the tray icon's `show_notification` with `set_notifier`.
Without a tray (the boot-time instance, tests, other platforms) `notify` does nothing. The user
can turn PC toasts off from the phone: settings section `alerts`, key `pcToasts` (default on).
"""
import logging
import threading
import unicodedata

LOGGER = logging.getLogger("orbit.notify")
# NOTIFYICONDATAW.szInfoTitle is WCHAR[64] and szInfo WCHAR[256], both including the terminator.
# WCHARs are UTF-16 code units: an emoji or another character outside the BMP takes two, and
# ctypes refuses text that does not fit ("string too long"), so limits count UTF-16 units.
TITLE_LIMIT = 63
MESSAGE_LIMIT = 255

_LOCK = threading.Lock()
_NOTIFIER = None


def set_notifier(notifier):
    """Registers `notifier(title, message)`; None removes it."""
    global _NOTIFIER
    if notifier is not None and not callable(notifier):
        raise TypeError("The notifier must be callable")
    with _LOCK:
        _NOTIFIER = notifier


def has_notifier():
    with _LOCK:
        return _NOTIFIER is not None


def toasts_enabled():
    """The user's `alerts.pcToasts` choice; on when it was never set or cannot be read."""
    try:
        import orbit_settings
        alerts = orbit_settings.shared_store().get("alerts", {})
    except Exception:
        LOGGER.debug("Could not read the PC toast setting", exc_info=True)
        return True
    return not (isinstance(alerts, dict) and alerts.get("pcToasts") is False)


def utf16_length(text):
    """Length in UTF-16 code units, which is what Windows' WCHAR buffers (and NSString) count."""
    return len(text) + sum(1 for char in text if ord(char) > 0xFFFF)


def fit_utf16(text, units):
    """The longest prefix of `text`, cut between characters, that fits in `units` UTF-16 code units."""
    units = max(0, int(units))
    if len(text) <= units // 2 or utf16_length(text) <= units:
        return text
    used = 0
    for index, char in enumerate(text):
        used += 2 if ord(char) > 0xFFFF else 1
        if used > units:
            return text[:index]
    return text


def clean_text(value, limit):
    """One line of plain text: control and invisible formatting characters become spaces, lone
    surrogates (which UTF-8 cannot encode) become U+FFFD, runs of whitespace collapse, and text
    longer than `limit` UTF-16 code units is cut to fit, ending with an ellipsis."""
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    cleaned = []
    for char in text:
        category = unicodedata.category(char)
        if category in ("Cc", "Cf", "Zl", "Zp"):
            cleaned.append(" ")
        elif category == "Cs":
            cleaned.append("\ufffd")
        else:
            cleaned.append(char)
    text = " ".join("".join(cleaned).split())
    if utf16_length(text) > limit:
        text = fit_utf16(text, limit - 1).rstrip() + "…"
    return text


def notify(title, message):
    """Shows a PC toast when a notifier is registered and toasts are on. Never raises.

    Returns True when the notifier reported that the toast was shown.
    """
    with _LOCK:
        notifier = _NOTIFIER
    if notifier is None or not toasts_enabled():
        return False
    shown_title = clean_text(title, TITLE_LIMIT) or "Orbit"
    shown_message = clean_text(message, MESSAGE_LIMIT)
    if not shown_message:
        # Windows shows no balloon without message text.
        shown_title, shown_message = "Orbit", clean_text(title, MESSAGE_LIMIT) or "Orbit"
    try:
        return bool(notifier(shown_title, shown_message))
    except Exception:
        LOGGER.warning("Could not show a PC notification", exc_info=True)
        return False
