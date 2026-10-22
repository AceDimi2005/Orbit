"""Small process snapshots and identity-checked Windows End Task operations.

The HTTP layer owns authentication and the Windows platform guard. On Windows,
psutil's terminate() uses TerminateProcess: applications can lose unsaved work.
Neither executable paths nor command lines are included in process snapshots;
icons are referenced by opaque IDs (see orbit_icons).
"""

import math
import os
import ctypes
import re
import threading
import time

import psutil

from orbit_icons import ICONS


MAX_COLLECTION_SECONDS = 1.8
TERMINATION_WAIT_SECONDS = 1.0
PROTECTED_NAMES = frozenset({
    "system", "system idle process", "registry", "memory compression", "secure system",
    "smss.exe", "csrss.exe", "wininit.exe", "services.exe", "lsass.exe", "lsaiso.exe",
    "winlogon.exe", "svchost.exe", "fontdrvhost.exe", "dwm.exe", "sihost.exe",
    "audiodg.exe", "conhost.exe", "spoolsv.exe", "sppsvc.exe", "wudfhost.exe",
    "taskhostw.exe", "securityhealthservice.exe", "msmpeng.exe", "nissrv.exe",
})
PROCESS_ATTRIBUTES = ("pid", "name", "create_time", "memory_info", "cpu_times", "status", "username", "exe")
_cpu_samples = {}
_sample_lock = threading.Lock()
_gpu_identities = set()
_gpu_reader = None
_gpu_lock = threading.Lock()


class _PdhNumber(ctypes.Union):
    _fields_ = [("longValue", ctypes.c_int32), ("doubleValue", ctypes.c_double),
                ("largeValue", ctypes.c_int64)]


class _PdhValue(ctypes.Structure):
    _anonymous_ = ("number",)
    _fields_ = [("CStatus", ctypes.c_uint32), ("number", _PdhNumber)]


class _PdhItem(ctypes.Structure):
    _fields_ = [("szName", ctypes.c_wchar_p), ("FmtValue", _PdhValue)]


class _WindowsGPUCounters:
    """Documented PDH API; English paths also work on localized Windows.

    References: Microsoft PdhAddEnglishCounterW / PdhGetFormattedCounterArrayW,
    and devblogs.microsoft.com/directx/gpus-in-the-task-manager/.
    Queries stay open so utilization uses two real snapshots without sleeping.
    """
    PATHS = {"gpuPercent": r"\GPU Engine(*)\Utilization Percentage",
             "vramMB": r"\GPU Process Memory(*)\Dedicated Usage",
             "sharedGpuMemoryMB": r"\GPU Process Memory(*)\Shared Usage"}

    def __init__(self, api=None):
        if api is None:
            if os.name != "nt":
                raise OSError("Per-process GPU counters require Windows WDDM 2.0 or later.")
            api = ctypes.WinDLL("pdh", use_last_error=True)
        self.api = api
        self.query = ctypes.c_void_p()
        self.counters = {}
        self.initialized = False
        for name, arguments in (
            ("PdhOpenQueryW", [ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p)]),
            ("PdhAddEnglishCounterW", [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p)]),
            ("PdhCollectQueryData", [ctypes.c_void_p]),
            ("PdhGetFormattedCounterArrayW", [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]),
            ("PdhCloseQuery", [ctypes.c_void_p]),
        ):
            function = getattr(api, name)
            function.argtypes = arguments; function.restype = ctypes.c_uint32
        if api.PdhOpenQueryW(None, 0, ctypes.byref(self.query)) != 0:
            raise OSError("Windows performance counters could not be opened.")
        for field, path in self.PATHS.items():
            counter = ctypes.c_void_p()
            if api.PdhAddEnglishCounterW(self.query, path, 0, ctypes.byref(counter)) == 0:
                self.counters[field] = counter
        if not self.counters:
            self.close()
            raise OSError("The GPU driver does not expose Windows GPU process counters (WDDM 2.0+ required).")

    def close(self):
        if self.query:
            self.api.PdhCloseQuery(self.query)
            self.query = ctypes.c_void_p()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def _values(self, counter):
        # Instance count can change between calls. Re-probe bounded buffers when
        # needed; never reuse a partially filled array or invalid status value.
        for _ in range(3):
            size, count = ctypes.c_uint32(), ctypes.c_uint32()
            status = self.api.PdhGetFormattedCounterArrayW(counter, 0x200 | 0x1000, ctypes.byref(size), ctypes.byref(count), None)
            if status == 0 and size.value == 0:
                return []
            if status != 0x800007D2 or not 0 < size.value <= 4 * 1024 * 1024:
                return []
            buffer = ctypes.create_string_buffer(size.value)
            allocated = size.value
            status = self.api.PdhGetFormattedCounterArrayW(counter, 0x200 | 0x1000, ctypes.byref(size), ctypes.byref(count), buffer)
            if status == 0x800007D2:
                continue
            if status != 0 or count.value > 100_000 or count.value * ctypes.sizeof(_PdhItem) > allocated:
                return []
            items = ctypes.cast(buffer, ctypes.POINTER(_PdhItem))
            result = []
            for index in range(count.value):
                item = items[index]
                value = float(item.FmtValue.doubleValue)
                if item.FmtValue.CStatus in (0, 1) and math.isfinite(value) and value >= 0 and item.szName:
                    result.append((item.szName, value))
            return result
        return []

    def snapshot(self):
        if self.api.PdhCollectQueryData(self.query) != 0:
            raise OSError("Windows GPU process counters are unavailable for this sample.")
        was_initialized = self.initialized
        self.initialized = True
        result = {}
        for field, counter in self.counters.items():
            if field == "gpuPercent" and not was_initialized:
                continue
            for name, value in dict(self._values(counter)).items():
                match = re.match(r"^pid_(\d+)_", name, re.IGNORECASE)
                if not match:
                    continue
                pid = int(match.group(1))
                row = result.setdefault(pid, {})
                if field == "gpuPercent":
                    level = min(100.0, value)
                    if row.get(field, -1) < level:
                        row[field] = round(level, 1)
                        engine = re.search(r"_engtype_(.+?)(?:#\d+)?$", name, re.IGNORECASE)
                        row["gpuEngine"] = engine.group(1)[:60] if engine else None
                else:
                    row[field] = row.get(field, 0.0) + value / (1024 * 1024)
        return result


def _gpu_snapshot():
    global _gpu_reader
    if os.name != "nt":
        return {}, "Per-process GPU readings require Windows WDDM 2.0+ counters."
    with _gpu_lock:
        try:
            if _gpu_reader is None:
                _gpu_reader = _WindowsGPUCounters()
            return _gpu_reader.snapshot(), None
        except (OSError, ValueError, AttributeError) as error:
            if _gpu_reader is not None:
                _gpu_reader.close(); _gpu_reader = None
            return {}, str(error)


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def _icon_id(executable):
    if not isinstance(executable, str) or not executable:
        return None
    try:
        return ICONS.register(executable)
    except Exception:
        return None


def _protected_pids():
    """Fail closed if the parent chain cannot be inspected."""
    own_pid = os.getpid()
    try:
        parents = psutil.Process(own_pid).parents()
    except psutil.Error as exc:
        raise PermissionError("Cannot verify the agent's parent processes.") from exc
    return {0, 4, own_pid, *(parent.pid for parent in parents)}


def _service_account(username):
    if not isinstance(username, str) or not username.strip():
        return True
    normalized = username.strip().replace("/", "\\").casefold()
    account = normalized.rsplit("\\", 1)[-1]
    return (account in {"system", "local service", "network service", "s-1-5-18", "s-1-5-19", "s-1-5-20"}
            or normalized.startswith(("nt service\\", "window manager\\", "font driver host\\")))


def _can_terminate(pid, name, username, status, protected_pids):
    return (protected_pids is not None and pid not in protected_pids
            and isinstance(name, str) and bool(name.strip())
            and name.casefold() not in PROTECTED_NAMES
            and not name.casefold().endswith(".sys")
            and not _service_account(username)
            and status not in (psutil.STATUS_DEAD, psutil.STATUS_ZOMBIE))


def _cpu_percent(identity, cpu_times, sampled_at, logical_cpus):
    if cpu_times is None:
        return None
    user = _number(getattr(cpu_times, "user", None))
    system = _number(getattr(cpu_times, "system", None))
    if user is None or system is None or user < 0 or system < 0:
        return None
    total = user + system
    with _sample_lock:
        previous = _cpu_samples.get(identity)
        _cpu_samples[identity] = (total, sampled_at)
    if previous is None:
        return None
    elapsed = sampled_at - previous[1]
    difference = total - previous[0]
    if elapsed <= 0 or difference < 0:
        return None
    # Match Task Manager's whole-machine scale: all cores together are 100%.
    return round(min(100.0, max(0.0, difference / elapsed / logical_cpus * 100)), 1)


def collect_processes():
    """Return a bounded, nonblocking snapshot; CPU needs a previous snapshot."""
    started = time.monotonic()
    captured_at = time.time()
    gpu, gpu_error = _gpu_snapshot()
    with _sample_lock:
        previous_gpu_identities = set(_gpu_identities)
    try:
        protected_pids = _protected_pids()
    except PermissionError:
        protected_pids = None
    logical_cpus = psutil.cpu_count() or 1
    processes = []
    seen = set()
    truncated = False
    try:
        # psutil 6+ reuses Process objects without checking PID reuse. Its cached
        # create_time must not turn a replacement process into the old row.
        clear_cache = getattr(psutil.process_iter, "cache_clear", None)
        if callable(clear_cache):
            clear_cache()
        for process in psutil.process_iter(attrs=PROCESS_ATTRIBUTES, ad_value=None):
            sampled_at = time.monotonic()
            if sampled_at - started >= MAX_COLLECTION_SECONDS:
                truncated = True
                break
            try:
                info = process.info
                pid = info.get("pid")
                created = _number(info.get("create_time"))
                name = info.get("name")
                # A stable creation time is required for every selectable row.
                if not isinstance(pid, int) or isinstance(pid, bool) or pid < 0 or created is None or created <= 0:
                    continue
                if not isinstance(name, str) or not name.strip():
                    continue
                identity = (pid, created)
                seen.add(identity)
                rss = _number(getattr(info.get("memory_info"), "rss", None))
                status = info.get("status") or "unknown"
                graphics = {}
                # PDH identifies processes by PID. Prime once for this exact
                # process lifetime, and recheck a fresh object before attaching
                # readings so a recycled PID does not inherit an old interval.
                if identity in previous_gpu_identities and created <= captured_at and pid in gpu:
                    try:
                        if psutil.Process(pid).create_time() == created:
                            graphics = gpu[pid]
                    except (psutil.Error, OSError):
                        pass
                row = {
                    "pid": pid,
                    "name": name,
                    "createTime": created,
                    "memoryMB": round(rss / (1024 * 1024), 1) if rss is not None and rss >= 0 else None,
                    "cpuPercent": _cpu_percent(identity, info.get("cpu_times"), sampled_at, logical_cpus),
                    "status": status,
                    "canTerminate": _can_terminate(pid, name, info.get("username"), status, protected_pids),
                    "gpuPercent": graphics.get("gpuPercent"),
                    "gpuEngine": graphics.get("gpuEngine"),
                    "vramMB": round(graphics["vramMB"], 1) if graphics.get("vramMB") is not None else None,
                    "sharedGpuMemoryMB": round(graphics["sharedGpuMemoryMB"], 1) if graphics.get("sharedGpuMemoryMB") is not None else None,
                    "iconID": _icon_id(info.get("exe")),
                }
                processes.append(row)
            except (psutil.Error, OSError):
                # Processes may exit while a snapshot is being assembled.
                continue
    except (psutil.Error, OSError):
        truncated = True
    with _sample_lock:
        _gpu_identities.clear(); _gpu_identities.update(seen)
        # Do not let old process identities grow for the lifetime of the agent.
        for identity in list(_cpu_samples):
            if identity not in seen:
                del _cpu_samples[identity]
    processes.sort(key=lambda row: (-int(row["canTerminate"]), -(row["memoryMB"] or 0), row["name"].casefold(), row["pid"]))
    return {"processes": processes, "capturedAt": captured_at, "totalCount": len(processes), "truncated": truncated,
            "gpuMetricsAvailable": gpu_error is None,
            "gpuMetricsStatus": gpu_error or "Windows GPU counters; the first process snapshot needs a second sample. GPU % uses its busiest engine. — means no valid counter for this process or driver. Dedicated/shared memory can include allocations shared between applications.",
            "gpuMetricsSource": "Windows PDH · GPU Engine / GPU Process Memory" if gpu_error is None else None}


def _verified_process(pid, expected_create_time, protected_pids):
    try:
        # Always construct a fresh Process; create_time() is cached per object.
        process = psutil.Process(pid)
        if process.create_time() != expected_create_time:
            raise ProcessLookupError("The process changed. Refresh the process list before ending it.")
        name = process.name()
        status = process.status()
        username = process.username()
        if not _can_terminate(pid, name, username, status, protected_pids):
            raise PermissionError("This system process or agent process is protected.")
        return process, name
    except (psutil.NoSuchProcess, psutil.ZombieProcess) as exc:
        raise ProcessLookupError("The process is no longer running. Refresh the process list.") from exc
    except psutil.AccessDenied as exc:
        raise PermissionError("Windows denied access to this process.") from exc


def _wait_for_exit(process):
    try:
        process.wait(timeout=TERMINATION_WAIT_SECONDS)
        return True
    except psutil.NoSuchProcess:
        return True
    except psutil.TimeoutExpired:
        return False


def terminate_process(pid, expected_create_time, force=False):
    """End only the selected process identity; never escalate implicitly.

    Windows terminate() is forceful even when force=False. The optional flag
    permits a second kill request after a bounded wait, with identity rechecked.
    A timeout returns ``terminating`` so clients do not claim confirmed exit.
    """
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise ValueError("A positive integer process ID is required.")
    expected = _number(expected_create_time)
    if expected is None or expected <= 0:
        raise ValueError("The process creation time from the latest process list is required.")
    if not isinstance(force, bool):
        raise ValueError("The force option must be true or false.")
    protected_pids = _protected_pids()
    if pid in protected_pids:
        raise PermissionError("This system process or agent process is protected.")
    process, name = _verified_process(pid, expected, protected_pids)
    forced = False
    try:
        process.terminate()
        exited = _wait_for_exit(process)
        if not exited and force:
            # A reused PID must never receive the second termination request.
            process, name = _verified_process(pid, expected, _protected_pids())
            process.kill()
            forced = True
            exited = _wait_for_exit(process)
    except (psutil.NoSuchProcess, psutil.ZombieProcess):
        exited = True
    except psutil.AccessDenied as exc:
        raise PermissionError("Windows denied permission to end this process.") from exc
    return {"pid": pid, "name": name, "status": "terminated" if exited else "terminating", "forced": forced}
