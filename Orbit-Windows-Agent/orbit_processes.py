"""Small process snapshots and identity-checked Windows End Task operations.

The HTTP layer owns authentication and the Windows platform guard. On Windows,
psutil's terminate() uses TerminateProcess: applications can lose unsaved work.
Neither executable paths nor command lines are included in process snapshots.
"""

import math
import os
import threading
import time

import psutil


MAX_COLLECTION_SECONDS = 1.8
TERMINATION_WAIT_SECONDS = 1.0
PROTECTED_NAMES = frozenset({
    "system", "system idle process", "registry", "memory compression", "secure system",
    "smss.exe", "csrss.exe", "wininit.exe", "services.exe", "lsass.exe", "lsaiso.exe",
    "winlogon.exe", "svchost.exe", "fontdrvhost.exe", "dwm.exe", "sihost.exe",
    "audiodg.exe", "conhost.exe", "spoolsv.exe", "sppsvc.exe", "wudfhost.exe",
    "taskhostw.exe", "securityhealthservice.exe", "msmpeng.exe", "nissrv.exe",
})
PROCESS_ATTRIBUTES = ("pid", "name", "create_time", "memory_info", "cpu_times", "status", "username")
_cpu_samples = {}
_sample_lock = threading.Lock()


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


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
    try:
        protected_pids = _protected_pids()
    except PermissionError:
        protected_pids = None
    logical_cpus = psutil.cpu_count() or 1
    processes = []
    seen = set()
    truncated = False
    try:
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
                processes.append({
                    "pid": pid,
                    "name": name,
                    "createTime": created,
                    "memoryMB": round(rss / (1024 * 1024), 1) if rss is not None and rss >= 0 else None,
                    "cpuPercent": _cpu_percent(identity, info.get("cpu_times"), sampled_at, logical_cpus),
                    "status": status,
                    "canTerminate": _can_terminate(pid, name, info.get("username"), status, protected_pids),
                })
            except (psutil.Error, OSError):
                # Processes may exit while a snapshot is being assembled.
                continue
    except (psutil.Error, OSError):
        truncated = True
    with _sample_lock:
        # Do not let old process identities grow for the lifetime of the agent.
        for identity in list(_cpu_samples):
            if identity not in seen:
                del _cpu_samples[identity]
    processes.sort(key=lambda row: (-int(row["canTerminate"]), -(row["memoryMB"] or 0), row["name"].casefold(), row["pid"]))
    return {"processes": processes, "capturedAt": captured_at, "totalCount": len(processes), "truncated": truncated}


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
