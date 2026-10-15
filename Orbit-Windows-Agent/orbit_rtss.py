"""Read-only game FPS from RivaTuner Statistics Server's documented v2 mapping.

Layout reference: RTSS SDK Include/RTSSSharedMemory.h, RTSS_SHARED_MEMORY and
RTSS_SHARED_MEMORY_APP_ENTRY. Entry offsets/sizes come from the mapping header;
only the stable v2 prefix is read. No OSD, capture, limiter or profile is changed.
"""
import ctypes
import math
import os
import struct
import time

import psutil

from orbit_hardware import foreground_pid
from orbit_shared_memory import read_mapping

MAPPING_NAME = "RTSSSharedMemoryV2"
MAX_MAPPING_BYTES = 8 * 1024 * 1024
HEADER_BYTES = 36
APP_PREFIX_BYTES = 284
DWORD_MASK = 0xFFFFFFFF
STALE_SECONDS = 5
_PROGRESS = {}
_DESKTOP_PROCESSES = {
    "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe",
    "chromium.exe", "browser.exe", "msedgewebview2.exe", "discord.exe",
    "dwm.exe", "explorer.exe", "applicationframehost.exe", "taskmgr.exe",
    "steam.exe", "epicgameslauncher.exe", "galaxyclient.exe", "obs64.exe",
    "cmd.exe", "powershell.exe", "pwsh.exe", "windowsterminal.exe",
    "python.exe", "pythonw.exe", "code.exe", "devenv.exe", "orbit.exe",
    "shellexperiencehost.exe", "searchhost.exe", "startmenuexperiencehost.exe",
}


def _exe_name(value):
    return str(value or "").replace("\\", "/").rsplit("/", 1)[-1].strip().lower()


def _tick_count_ms():
    """RTSS uses DWORD millisecond uptime; handle its approximately 49-day wrap."""
    if os.name != "nt":
        # The transport is Windows-only; the fallback keeps mocked tests portable.
        return int(time.monotonic() * 1000) & DWORD_MASK
    kernel32 = ctypes.windll.kernel32
    kernel32.GetTickCount64.argtypes = []
    kernel32.GetTickCount64.restype = ctypes.c_ulonglong
    return kernel32.GetTickCount64() & DWORD_MASK


def _app_array_end(data):
    if len(data) < HEADER_BYTES:
        raise ValueError("RTSS header is incomplete")
    signature, version, entry_size, offset, count = struct.unpack_from("<5I", data)
    if signature != 0x52545353 or version >> 16 != 2:
        raise ValueError("RTSS shared memory is uninitialized or has an unsupported version")
    end = offset + count * entry_size
    if entry_size < APP_PREFIX_BYTES or offset < HEADER_BYTES or count > 4096 or entry_size > MAX_MAPPING_BYTES or end > MAX_MAPPING_BYTES:
        raise ValueError("RTSS application array exceeds the snapshot limit")
    return end


def parse_rtss(data, tick_ms=None):
    """Return instantaneous FPS entries from a bounded SDK-layout byte snapshot.

    ``tick_ms`` is optional current DWORD uptime, used to reject stale/future
    measurements. Invalid mapping layouts raise ValueError; empty or unready
    application slots are skipped. This parser performs no OS operations.
    """
    if not isinstance(data, (bytes, bytearray, memoryview)) or not HEADER_BYTES <= len(data) <= MAX_MAPPING_BYTES:
        raise ValueError("RTSS shared-memory snapshot has an invalid size")
    end = _app_array_end(data)
    signature, version, entry_size, offset, count = struct.unpack_from("<5I", data)
    # The SDK's C/C++ multichar 'RTSS' is 0x52545353 (bytes SSTR on Windows).
    if end > len(data):
        raise ValueError("RTSS application array exceeds the shared-memory snapshot")
    if tick_ms is not None:
        if isinstance(tick_ms, bool) or not isinstance(tick_ms, int) or tick_ms < 0:
            raise ValueError("RTSS freshness requires nonnegative millisecond uptime")
        tick_ms &= DWORD_MASK
    entries = []
    for index in range(count):
        start = offset + index * entry_size
        pid = struct.unpack_from("<I", data, start)[0]
        if not pid:
            continue
        name_bytes = bytes(data[start + 4:start + 264])
        if b"\0" not in name_bytes:
            continue
        name = name_bytes.split(b"\0", 1)[0].decode("mbcs" if os.name == "nt" else "cp1252", errors="replace")
        name = _exe_name(name)
        time0, time1, frames = struct.unpack_from("<3I", data, start + 268)
        elapsed = (time1 - time0) & DWORD_MASK
        # These are SDK instantaneous fields, distinct from benchmark/session
        # dwStatTime*/dwStatFramerateAvg fields, which can retain old results.
        if not name or not time0 or not frames or not 0 < elapsed <= 60000:
            continue
        if tick_ms is not None:
            age = (tick_ms - time1) & DWORD_MASK
            # timeGetTime and GetTickCount can differ by one Windows timer tick.
            # Allow that small skew; large future timestamps are invalid.
            if age > STALE_SECONDS * 1000 and age < (1 << 32) - 250:
                continue
        fps = 1000.0 * frames / elapsed
        if not math.isfinite(fps) or not 0 < fps <= 10000:
            continue
        entries.append({"pid": pid, "process": name, "fps": fps,
                        "time0": time0, "time1": time1, "frames": frames})
    return entries


def _live_identity(entry):
    try:
        process = psutil.Process(entry["pid"])
        if not process.is_running() or process.status() == psutil.STATUS_ZOMBIE or _exe_name(process.name()) != entry["process"]:
            return None
        created = process.create_time()
        if not isinstance(created, (int, float)) or not math.isfinite(created) or created <= 0:
            return None
        return entry["pid"], entry["process"], created
    except (psutil.Error, OSError):
        return None


def _foreground_game(entries):
    foreground = foreground_pid()
    configured = {_exe_name(name) for name in os.getenv("ORBIT_GAME_PROCESSES", "").split(";") if name.strip()}
    for entry in entries:
        name = entry["process"]
        if entry["pid"] != foreground:
            continue
        helper = any(part in name for part in ("launcher", "helper", "crash", "anticheat", "unins", "setup"))
        if name not in configured and (name in _DESKTOP_PROCESSES or helper or not name.endswith(".exe")):
            continue
        identity = _live_identity(entry)
        if identity is not None:
            return entry, identity
    return None


def read_rtss(game=None, now=None):
    """Read current game FPS; missing sources return explicit unavailable status.

    ``now`` is an optional monotonic-seconds clock for deterministic progression
    tests. Freshness also checks RTSS's measurement timestamp against OS uptime.
    """
    def missing(reason):
        return {"fps": None, "fpsSource": None, "fpsUnavailableReason": reason}

    try:
        # Skip large unused OSD regions, which may change on every rendered
        # frame. Validate the header before trusting its requested array size.
        header = read_mapping(MAPPING_NAME, max_bytes=HEADER_BYTES)
        needed = _app_array_end(header)
        snapshot = read_mapping(MAPPING_NAME, max_bytes=needed)
        if snapshot[:20] != header[:20]:
            raise ValueError("RTSS application layout changed while reading")
        entries = parse_rtss(snapshot, _tick_count_ms())
    except (OSError, ValueError, struct.error):
        _PROGRESS.clear()
        return missing("Start RivaTuner Statistics Server (RTSS) alongside MSI Afterburner to enable game FPS")
    if not entries:
        return missing("Waiting for fresh RTSS frames; launch a game and enable its RTSS application detection")

    selected = None
    if game:
        for entry in entries:
            if entry["pid"] == game.get("pid") and entry["process"] == _exe_name(game.get("process")):
                identity = _live_identity(entry)
                if identity is not None:
                    selected = entry, identity
                    break
    if not game or game.get("foreground") is False:
        selected = _foreground_game(entries) or selected
    if selected is None:
        return missing("No matching RTSS game detected; focus the game or configure ORBIT_GAME_PROCESSES")

    entry, identity = selected
    now = time.monotonic() if now is None else now
    if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now):
        return missing("RTSS frame freshness could not be verified")
    marker = entry["time0"], entry["time1"], entry["frames"]
    previous = _PROGRESS.get(identity)
    advanced = now if previous is None or now < previous["seen"] or marker != previous["marker"] else previous["advanced"]
    _PROGRESS[identity] = {"marker": marker, "advanced": advanced, "seen": now}
    while len(_PROGRESS) > 64:
        del _PROGRESS[next(iter(_PROGRESS))]
    if now - advanced > STALE_SECONDS:
        return missing("RTSS frames are stale; keep the game running and check RTSS application detection")

    result = {"fps": round(entry["fps"], 2 if entry["fps"] < 1 else 1),
              "fpsSource": "RTSS · game FPS", "fpsUnavailableReason": None}
    if not game or entry["pid"] != game.get("pid"):
        result.update(activeGame=entry["process"].removesuffix(".exe"), activeGameProcess=entry["process"])
    return result
