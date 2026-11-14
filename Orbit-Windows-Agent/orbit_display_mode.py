"""Windows' projection mode from the apps, like Win+P (feature displayMode).

The four modes of the Win+P panel: PC screen only, Duplicate, Extend and Second screen only.

* `GET /api/display/mode` says which one Windows uses now and lists the displays Windows sees
  (name, connection, whether each shows the desktop now).
* `POST /api/display/mode` with `{"mode": "internal" | "clone" | "extend" | "external"}` switches,
  exactly like the panel: `SetDisplayConfig` with one `SDC_TOPOLOGY_*` flag. Windows keeps the
  layout of each mode in its display database and remembers the choice, so resolutions and
  positions come back the way the user left them.

`QueryDisplayConfig(QDC_DATABASE_CURRENT)` gives the mode in use; `QDC_ALL_PATHS` gives every
display Windows can drive, with `DisplayConfigGetDeviceInfo` for its name. Native calls use a
private `WinDLL` with full prototypes, and structures with fixed-size fields, so the layouts are
the same on every platform the tests run on.

Two switches are refused before Windows is asked, because they can only fail or leave the user in
the dark: anything but "PC screen only" with a single display connected, and "Second screen only"
when the only other display is a virtual one (Orbit's Second Screen or Fill Screen driver), which
would turn the real monitor off.
"""
import ctypes
import logging
import os
import threading
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

LOGGER = logging.getLogger("orbit.displaymode")

# Win+P order. The values are the API names; the titles are the ones Windows shows.
MODES = ("internal", "clone", "extend", "external")
MODE_TITLES = {"internal": "PC screen only", "clone": "Duplicate", "extend": "Extend",
               "external": "Second screen only"}

QDC_ALL_PATHS = 0x00000001
QDC_DATABASE_CURRENT = 0x00000004
SDC_TOPOLOGY_INTERNAL = 0x00000001
SDC_TOPOLOGY_CLONE = 0x00000002
SDC_TOPOLOGY_EXTEND = 0x00000004
SDC_TOPOLOGY_EXTERNAL = 0x00000008
SDC_APPLY = 0x00000080
DISPLAYCONFIG_PATH_ACTIVE = 0x00000001
DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2

# DISPLAYCONFIG_TOPOLOGY_ID values happen to equal the SDC_TOPOLOGY_* flags.
SET_FLAGS = {"internal": SDC_TOPOLOGY_INTERNAL, "clone": SDC_TOPOLOGY_CLONE,
             "extend": SDC_TOPOLOGY_EXTEND, "external": SDC_TOPOLOGY_EXTERNAL}
TOPOLOGY_MODES = {1: "internal", 2: "clone", 4: "extend", 8: "external"}

ERROR_SUCCESS = 0
ERROR_ACCESS_DENIED = 5
ERROR_GEN_FAILURE = 31
ERROR_NOT_SUPPORTED = 50
ERROR_INVALID_PARAMETER = 87
ERROR_INSUFFICIENT_BUFFER = 122
ERROR_BAD_CONFIGURATION = 1610

# DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY → what the apps show as the connection.
OUTPUT_INTERNAL = 0x80000000
OUTPUT_EMBEDDED = {6, 11, 13, OUTPUT_INTERNAL}  # LVDS, embedded DisplayPort, embedded UDI, internal
OUTPUT_VIRTUAL = 17  # indirect virtual
CONNECTIONS = {
    0: "VGA", 1: "S-Video", 2: "Composite", 3: "Component", 4: "DVI", 5: "HDMI", 6: "Built-in",
    8: "D-Terminal", 9: "SDI", 10: "DisplayPort", 11: "Built-in", 12: "UDI", 13: "Built-in",
    14: "TV dongle", 15: "Wireless", 16: "USB", 17: "Virtual", 18: "USB-C", OUTPUT_INTERNAL: "Built-in",
}
# The Virtual Display Driver's monitor (same value as orbit_stream_display.VDD_MONITOR_ID) and
# SudoVDA's, the driver Apollo installs.
VIRTUAL_MONITOR_IDS = ("MTT1337", "SMKD1CE")


class DisplayModeError(Exception):
    """A switch that did not happen; `status` is the HTTP status for the apps."""

    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


# -- structures (fixed-size fields: the same layout on every platform) ---------------------------

class LUID(ctypes.Structure):
    _fields_ = [("LowPart", ctypes.c_uint32), ("HighPart", ctypes.c_int32)]


class DISPLAYCONFIG_RATIONAL(ctypes.Structure):
    _fields_ = [("Numerator", ctypes.c_uint32), ("Denominator", ctypes.c_uint32)]


class DISPLAYCONFIG_PATH_SOURCE_INFO(ctypes.Structure):
    _fields_ = [("adapterId", LUID), ("id", ctypes.c_uint32), ("modeInfoIdx", ctypes.c_uint32),
                ("statusFlags", ctypes.c_uint32)]


class DISPLAYCONFIG_PATH_TARGET_INFO(ctypes.Structure):
    _fields_ = [("adapterId", LUID), ("id", ctypes.c_uint32), ("modeInfoIdx", ctypes.c_uint32),
                ("outputTechnology", ctypes.c_uint32), ("rotation", ctypes.c_uint32),
                ("scaling", ctypes.c_uint32), ("refreshRate", DISPLAYCONFIG_RATIONAL),
                ("scanLineOrdering", ctypes.c_uint32), ("targetAvailable", ctypes.c_int32),
                ("statusFlags", ctypes.c_uint32)]


class DISPLAYCONFIG_PATH_INFO(ctypes.Structure):
    _fields_ = [("sourceInfo", DISPLAYCONFIG_PATH_SOURCE_INFO),
                ("targetInfo", DISPLAYCONFIG_PATH_TARGET_INFO), ("flags", ctypes.c_uint32)]


class DISPLAYCONFIG_MODE_INFO(ctypes.Structure):
    # The union holds a 64-bit pixel rate, so it is 8-byte aligned: 6 × uint64 keeps that.
    _fields_ = [("infoType", ctypes.c_uint32), ("id", ctypes.c_uint32), ("adapterId", LUID),
                ("union", ctypes.c_uint64 * 6)]


class DISPLAYCONFIG_DEVICE_INFO_HEADER(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("size", ctypes.c_uint32), ("adapterId", LUID),
                ("id", ctypes.c_uint32)]


class DISPLAYCONFIG_TARGET_DEVICE_NAME(ctypes.Structure):
    # WCHAR is 2 bytes on Windows; c_uint16 keeps that everywhere (decoded by `_wide_text`).
    _fields_ = [("header", DISPLAYCONFIG_DEVICE_INFO_HEADER), ("flags", ctypes.c_uint32),
                ("outputTechnology", ctypes.c_uint32), ("edidManufactureId", ctypes.c_uint16),
                ("edidProductCodeId", ctypes.c_uint16), ("connectorInstance", ctypes.c_uint32),
                ("monitorFriendlyDeviceName", ctypes.c_uint16 * 64),
                ("monitorDevicePath", ctypes.c_uint16 * 128)]


def _wide_text(array):
    data = bytes(array)
    text = data.decode("utf-16-le", errors="replace")
    return text.split("\0", 1)[0].strip()


# -- pure helpers --------------------------------------------------------------------------------

def connection_name(output_technology):
    return CONNECTIONS.get(int(output_technology) & 0xFFFFFFFF, "Other")


def is_virtual(output_technology, device_path):
    if int(output_technology) & 0xFFFFFFFF == OUTPUT_VIRTUAL:
        return True
    path = (device_path or "").casefold()
    return any(marker.casefold() in path for marker in VIRTUAL_MONITOR_IDS)


def displays_from_paths(paths, describe):
    """One entry per display Windows can drive, in Windows' order.

    `paths` are DISPLAYCONFIG_PATH_INFO from QDC_ALL_PATHS: every source × target pair, so a display
    shows up many times. A display counts when any of its paths says `targetAvailable`; it shows the
    desktop when any of its paths is active. `describe(path)` returns (friendly name, device path,
    output technology) for the path's target, or None when Windows has no name for it.
    """
    order, found = [], {}
    for path in paths:
        target = path.targetInfo
        key = (int(target.adapterId.LowPart), int(target.adapterId.HighPart), int(target.id))
        entry = found.get(key)
        if entry is None:
            entry = found[key] = {"path": path, "available": False, "active": False}
            order.append(key)
        entry["available"] = entry["available"] or bool(target.targetAvailable)
        if path.flags & DISPLAYCONFIG_PATH_ACTIVE:
            entry["active"] = True
            entry["path"] = path
    displays = []
    for key in order:
        entry = found[key]
        if not entry["available"]:
            continue
        path = entry["path"]
        technology = int(path.targetInfo.outputTechnology) & 0xFFFFFFFF
        name, device_path = "", ""
        try:
            described = describe(path)
        except OSError:
            described = None
        if described:
            name, device_path, named_technology = described
            if named_technology is not None:
                technology = int(named_technology) & 0xFFFFFFFF
        built_in = technology in OUTPUT_EMBEDDED
        virtual = is_virtual(technology, device_path)
        if not name:
            name = "Built-in display" if built_in else ("Virtual display" if virtual else f"Display {len(displays) + 1}")
        displays.append({"name": name[:120], "connection": connection_name(technology), "active": entry["active"],
                         "builtIn": built_in, "virtual": virtual})
    return displays


def refusal(mode, displays):
    """The reason a switch is refused before asking Windows, or None."""
    if mode == "internal":
        return None
    if len(displays) < 2:
        return (f"Only one display is connected to the PC. Connect and turn on a second display to use "
                f"{MODE_TITLES[mode]}.")
    if mode == "external" and sum(1 for display in displays if not display["virtual"]) < 2:
        return ("The only other display is a virtual one (used for streaming). Second screen only would turn your "
                "monitor off, so Orbit didn't switch.")
    return None


def apply_error(mode, code):
    title = MODE_TITLES[mode]
    if code == ERROR_ACCESS_DENIED:
        return DisplayModeError(409, "Windows didn't allow a display change right now. Sign in to Windows on the PC "
                                     "(the lock screen blocks display changes) and try again.")
    if code == ERROR_NOT_SUPPORTED:
        return DisplayModeError(409, f"The PC's graphics driver doesn't support {title}.")
    if code in (ERROR_GEN_FAILURE, ERROR_INVALID_PARAMETER, ERROR_BAD_CONFIGURATION):
        return DisplayModeError(409, f"Windows couldn't switch to {title}. Check that the second display is "
                                     "connected and turned on.")
    return DisplayModeError(503, f"Windows couldn't change the display mode (error {code}).")


# -- Windows ------------------------------------------------------------------------------------

class WindowsDisplayTopology:
    """Everything this feature asks Windows. Tests replace it with a fake."""

    def __init__(self, user32=None):
        self._user32_override = user32
        self._user32 = None

    def user32(self):
        if self._user32 is None:
            library = self._user32_override
            if library is None:
                loader = getattr(ctypes, "WinDLL", None)
                if loader is None:
                    raise OSError("This needs Windows.")
                library = loader("user32", use_last_error=True)
            u32 = ctypes.POINTER(ctypes.c_uint32)
            library.GetDisplayConfigBufferSizes.argtypes = [ctypes.c_uint32, u32, u32]
            library.GetDisplayConfigBufferSizes.restype = ctypes.c_long
            library.QueryDisplayConfig.argtypes = [ctypes.c_uint32, u32, ctypes.POINTER(DISPLAYCONFIG_PATH_INFO), u32,
                                                   ctypes.POINTER(DISPLAYCONFIG_MODE_INFO), u32]
            library.QueryDisplayConfig.restype = ctypes.c_long
            library.SetDisplayConfig.argtypes = [ctypes.c_uint32, ctypes.POINTER(DISPLAYCONFIG_PATH_INFO), ctypes.c_uint32,
                                                 ctypes.POINTER(DISPLAYCONFIG_MODE_INFO), ctypes.c_uint32]
            library.SetDisplayConfig.restype = ctypes.c_long
            library.DisplayConfigGetDeviceInfo.argtypes = [ctypes.POINTER(DISPLAYCONFIG_DEVICE_INFO_HEADER)]
            library.DisplayConfigGetDeviceInfo.restype = ctypes.c_long
            self._user32 = library
        return self._user32

    def _query(self, flags):
        user32 = self.user32()
        for _ in range(4):  # The configuration can change between the size query and the read.
            path_count, mode_count = ctypes.c_uint32(), ctypes.c_uint32()
            status = user32.GetDisplayConfigBufferSizes(flags, ctypes.byref(path_count), ctypes.byref(mode_count))
            if status != ERROR_SUCCESS:
                raise OSError(status, f"GetDisplayConfigBufferSizes failed ({status})")
            paths = (DISPLAYCONFIG_PATH_INFO * max(1, path_count.value))()
            modes = (DISPLAYCONFIG_MODE_INFO * max(1, mode_count.value))()
            topology = ctypes.c_uint32()
            status = user32.QueryDisplayConfig(flags, ctypes.byref(path_count), paths, ctypes.byref(mode_count), modes,
                                               ctypes.byref(topology) if flags & QDC_DATABASE_CURRENT else None)
            if status == ERROR_INSUFFICIENT_BUFFER:
                continue
            if status != ERROR_SUCCESS:
                raise OSError(status, f"QueryDisplayConfig failed ({status})")
            return list(paths[:path_count.value]), topology.value
        raise OSError(ERROR_INSUFFICIENT_BUFFER, "The display configuration kept changing")

    def current_mode(self):
        """"internal", "clone", "extend", "external", or None for a layout outside the four."""
        _, topology = self._query(QDC_DATABASE_CURRENT)
        return TOPOLOGY_MODES.get(topology)

    def _describe(self, path):
        request = DISPLAYCONFIG_TARGET_DEVICE_NAME()
        request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        request.header.size = ctypes.sizeof(DISPLAYCONFIG_TARGET_DEVICE_NAME)
        request.header.adapterId = path.targetInfo.adapterId
        request.header.id = path.targetInfo.id
        if self.user32().DisplayConfigGetDeviceInfo(ctypes.byref(request.header)) != ERROR_SUCCESS:
            return None
        return (_wide_text(request.monitorFriendlyDeviceName), _wide_text(request.monitorDevicePath),
                request.outputTechnology)

    def displays(self):
        paths, _ = self._query(QDC_ALL_PATHS)
        return displays_from_paths(paths, self._describe)

    def apply(self, mode):
        """The Win32 error code: 0 when Windows switched."""
        return int(self.user32().SetDisplayConfig(0, None, 0, None, SDC_APPLY | SET_FLAGS[mode]))


# -- service ------------------------------------------------------------------------------------

class DisplayModeService:
    def __init__(self, platform=None, desktop_available=lambda: True):
        self._platform = platform
        self._desktop_available = desktop_available
        self._lock = threading.Lock()

    def platform(self):
        if self._platform is None:
            if os.name != "nt":
                raise DisplayModeError(501, "Display modes need Windows.")
            self._platform = WindowsDisplayTopology()
        return self._platform

    def _require_desktop(self):
        if not self._desktop_available():
            raise DisplayModeError(409, "Sign in to Windows on the PC first. Display modes change on the signed-in desktop.")

    def status(self):
        try:
            self._require_desktop()
            platform = self.platform()
            displays = platform.displays()
            mode = platform.current_mode()
        except DisplayModeError as error:
            return {"available": False, "reason": error.detail, "mode": None, "displays": []}
        except OSError as error:
            LOGGER.warning("Could not read the display configuration: %s", error)
            return {"available": False, "reason": "Windows couldn't read the display configuration. Try again in a moment.",
                    "mode": None, "displays": []}
        return {"available": True, "reason": None, "mode": mode, "displays": displays}

    def set_mode(self, mode):
        if mode not in SET_FLAGS:
            raise DisplayModeError(422, "Choose PC screen only, Duplicate, Extend or Second screen only.")
        with self._lock:
            self._require_desktop()
            platform = self.platform()
            try:
                displays = platform.displays()
            except OSError as error:
                raise DisplayModeError(503, "Windows couldn't read the display configuration. Try again in a moment.") from error
            reason = refusal(mode, displays)
            if reason:
                raise DisplayModeError(409, reason)
            try:
                code = platform.apply(mode)
            except OSError as error:
                raise DisplayModeError(503, "Windows couldn't change the display mode.") from error
            if code != ERROR_SUCCESS:
                LOGGER.warning("SetDisplayConfig(%s) failed with %s", mode, code)
                raise apply_error(mode, code)
            LOGGER.info("Display mode: %s", MODE_TITLES[mode])
        return self.status()


class DisplayModeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    mode: Literal["internal", "clone", "extend", "external"]


def create_display_mode_router(verify_token, require_https, service):
    router = APIRouter(prefix="/api/display", dependencies=[Depends(verify_token), Depends(require_https)])

    @router.get("/mode")
    def get_mode():
        return service.status()

    @router.post("/mode")
    def post_mode(body: DisplayModeBody):
        try:
            return service.set_mode(body.mode)
        except DisplayModeError as error:
            raise HTTPException(error.status, error.detail) from error

    return router
