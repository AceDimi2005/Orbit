"""Read-only hardware inventory and optional PresentMon integration.

Missing sensors return None. Inventory does not assume a particular PC vendor.
"""
import csv
import ctypes
import io
import json
import math
import os
import platform
import socket
import subprocess
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import psutil

GIB = 1024 ** 3
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def as_list(value):
    return value if isinstance(value, list) else ([value] if isinstance(value, dict) else [])


def powershell_json(script, timeout=20):
    output = subprocess.check_output(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
         "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); " + script],
        encoding="utf-8-sig", errors="replace", timeout=timeout,
        creationflags=CREATE_NO_WINDOW, stderr=subprocess.DEVNULL,
    )
    return json.loads(output.strip())


def query_windows_inventory():
    # One PowerShell invocation; a missing CIM class must not discard other classes.
    return powershell_json(r"""
    $ErrorActionPreference = 'SilentlyContinue'
    $result = @{
      cpu = @(Get-CimInstance Win32_Processor | Select-Object Name,Manufacturer,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
      board = @(Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer,Product)
      bios = @(Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion)
      memory = @(Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer,PartNumber,Capacity,ConfiguredClockSpeed,DeviceLocator)
      gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
      disk = @(Get-CimInstance Win32_DiskDrive | Select-Object Model,Size,InterfaceType,MediaType)
      os = @(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture)
    }
    $result | ConvertTo-Json -Depth 5 -Compress
    """)


def volume_inventory():
    result = []
    seen = set()
    for disk in psutil.disk_partitions(all=False):
        if disk.mountpoint in seen or "cdrom" in disk.opts or not disk.fstype:
            continue
        try:
            usage = psutil.disk_usage(disk.mountpoint)
        except (OSError, PermissionError):
            continue
        seen.add(disk.mountpoint)
        result.append({"mountpoint": disk.mountpoint, "fileSystem": disk.fstype,
                       "totalGB": round(usage.total / GIB, 2), "usedGB": round(usage.used / GIB, 2)})
    return result


def network_inventory():
    result = []
    for name, addresses in psutil.net_if_addrs().items():
        ipv4 = [a.address for a in addresses if a.family == socket.AF_INET and not a.address.startswith("127.")]
        if not ipv4:
            continue
        mac = next((a.address.replace("-", ":").upper() for a in addresses
                    if a.family == psutil.AF_LINK), "")
        result.append({"name": name, "macAddress": mac, "ipv4Addresses": ipv4})
    return result


def basic_specs():
    return {
        "hostname": socket.gethostname(), "osName": platform.system(),
        "osVersion": platform.version(), "architecture": platform.machine(),
        "cpu": {"name": platform.processor() or None, "manufacturer": None,
                "physicalCores": psutil.cpu_count(logical=False), "logicalCores": psutil.cpu_count(),
                "maxClockMHz": None},
        "motherboard": {"manufacturer": None, "model": None, "biosVersion": None},
        "memory": {"totalGB": round(psutil.virtual_memory().total / GIB, 2), "modules": []},
        "gpus": [], "disks": [], "volumes": volume_inventory(),
        "networkAdapters": network_inventory(), "coolerName": None,
        "detectedAt": timestamp(), "source": "System APIs (basic inventory)",
    }


def inventory_from_cim(raw, specs):
    cpus = as_list(raw.get("cpu"))
    if cpus:
        specs["cpu"] = {
            "name": " / ".join(str(c.get("Name", "")).strip() for c in cpus),
            "manufacturer": cpus[0].get("Manufacturer"),
            "physicalCores": sum(int(c.get("NumberOfCores") or 0) for c in cpus) or None,
            "logicalCores": sum(int(c.get("NumberOfLogicalProcessors") or 0) for c in cpus) or None,
            "maxClockMHz": number(cpus[0].get("MaxClockSpeed")),
        }
    boards, bios = as_list(raw.get("board")), as_list(raw.get("bios"))
    if boards:
        specs["motherboard"].update(manufacturer=boards[0].get("Manufacturer"), model=boards[0].get("Product"))
    if bios:
        specs["motherboard"]["biosVersion"] = bios[0].get("SMBIOSBIOSVersion")
    specs["memory"]["modules"] = [
        {"manufacturer": m.get("Manufacturer"), "partNumber": (m.get("PartNumber") or "").strip() or None,
         "capacityGB": round(float(m.get("Capacity") or 0) / GIB, 2) or None,
         "speedMHz": number(m.get("ConfiguredClockSpeed")) or None, "slot": m.get("DeviceLocator")}
        for m in as_list(raw.get("memory"))
    ]
    # AdapterRAM in Win32_VideoController is uint32 and truncates modern VRAM sizes.
    # Leave VRAM unknown unless nvidia-smi reports a reliable 64-bit capacity.
    specs["gpus"] = [{"name": g.get("Name"), "driverVersion": g.get("DriverVersion"), "vramGB": None}
                     for g in as_list(raw.get("gpu"))]
    specs["disks"] = [{"name": d.get("Model"), "sizeGB": round(float(d.get("Size") or 0) / GIB, 2) or None,
                       "interfaceType": d.get("InterfaceType"), "mediaType": d.get("MediaType")}
                      for d in as_list(raw.get("disk"))]
    systems = as_list(raw.get("os"))
    if systems:
        specs.update(osName=systems[0].get("Caption") or specs["osName"],
                     osVersion=systems[0].get("Version") or specs["osVersion"],
                     architecture=systems[0].get("OSArchitecture") or specs["architecture"])
    specs["source"] = "Windows CIM + psutil"
    specs["detectedAt"] = timestamp()
    return specs


def nvidia_metrics():
    try:
        output = subprocess.check_output([
            "nvidia-smi", "--query-gpu=name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total,driver_version",
            "--format=csv,noheader,nounits"], encoding="utf-8", timeout=2,
            creationflags=CREATE_NO_WINDOW, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return []
    result = []
    for values in csv.reader(io.StringIO(output)):
        if len(values) < 7:
            continue
        values = [v.strip() for v in values]
        used, total = number(values[4]), number(values[5])
        result.append({"gpuName": values[0], "gpuTemp": number(values[1]), "gpuUsage": number(values[2]),
                       "gpuPowerWatts": number(values[3]), "vramUsedGB": round(used / 1024, 2) if used is not None else None,
                       "vramTotalGB": round(total / 1024, 2) if total is not None else None,
                       "driverVersion": values[6]})
    return result


def collect_specs():
    specs = basic_specs()
    if os.name == "nt":
        try:
            specs = inventory_from_cim(query_windows_inventory(), specs)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            specs["source"] = "Basic inventory; Windows CIM unavailable"
    for gpu in nvidia_metrics():
        existing = next((g for g in specs["gpus"] if g["name"] == gpu["gpuName"]), None)
        entry = {"name": gpu["gpuName"], "driverVersion": gpu["driverVersion"], "vramGB": gpu["vramTotalGB"]}
        if existing is not None:
            existing.update(entry)
        else:
            specs["gpus"].append(entry)
    return specs


def temperature_metrics():
    """Use real sensors only; ACPI thermal zones are not CPU-package temperatures."""
    result = {"cpuTemp": None, "liquidTemp": None}
    if os.name == "nt":
        try:
            sensors = powershell_json(r"""
            $ErrorActionPreference = 'Stop'
            @(Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor |
              Where-Object SensorType -eq 'Temperature' |
              Select-Object Name,Identifier,Value) | ConvertTo-Json -Compress
            """, timeout=4)
            for sensor in as_list(sensors):
                label = str(sensor.get("Name", "")).lower()
                identifier = str(sensor.get("Identifier", "")).lower()
                value = number(sensor.get("Value"))
                if value is None:
                    continue
                if "cpu" in identifier and ("package" in label or "tctl" in label or "tdie" in label):
                    result["cpuTemp"] = value
                if "liquid" in label or "coolant" in label:
                    result["liquidTemp"] = value
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            pass
    else:
        for name, entries in getattr(psutil, "sensors_temperatures", lambda: {})().items():
            if name.lower() not in {"coretemp", "k10temp", "cpu_thermal"}:
                continue
            valid = [e.current for e in entries if number(e.current) is not None]
            if valid:
                result["cpuTemp"] = max(valid)
    return result


def foreground_pid():
    if os.name != "nt":
        return None
    pid = ctypes.c_ulong()
    user32 = ctypes.windll.user32
    user32.GetForegroundWindow.restype = ctypes.c_void_p
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), ctypes.byref(pid))
    return pid.value


def detect_game(configured=None):
    """Recognize user-selected exe names or games in standard launcher libraries."""
    configured = configured or {n.strip().lower(): Path(n.strip()).stem
                                for n in os.getenv("ORBIT_GAME_PROCESSES", "").split(";") if n.strip()}
    foreground = foreground_pid()
    candidates = []
    for process in psutil.process_iter(["pid", "name", "exe", "create_time"]):
        try:
            info = process.info
            name = (info.get("name") or "").lower()
            path = (info.get("exe") or "").replace("\\", "/").lower()
            library = any(part in path for part in ("/steamapps/common/", "/epic games/", "/gog games/"))
            helper = any(part in name for part in ("crash", "launcher", "unins", "helper", "webhelper", "setup", "anticheat"))
            if name in configured or (library and not helper and name.endswith(".exe")):
                candidates.append({"name": configured.get(name) or Path(info["name"]).stem,
                                   "process": info["name"], "pid": info["pid"],
                                   "foreground": info["pid"] == foreground, "created": info.get("create_time") or 0})
        except (psutil.Error, OSError):
            continue
    return max(candidates, key=lambda g: (g["foreground"], g["created"]), default=None)


def read_presentmon(path, game, now=None):
    """Read a bounded tail, isolate the game/PID/swap chain, reject stale frames.

    FPS is application present rate, not displayed/generated-frame FPS. Supported
    CSVs have Application, ProcessID, SwapChainAddress, TimeInSeconds/TimeInMs,
    and MsBetweenPresents (case-insensitive).
    """
    def missing(reason):
        return {"fps": None, "fpsSource": None, "fpsUnavailableReason": reason}
    if not game:
        return missing("No supported game process detected")
    if not path:
        return missing("Configure ORBIT_PRESENTMON_CSV to enable FPS")
    now = time.time() if now is None else now
    try:
        file = Path(path)
        if now - file.stat().st_mtime > 5:
            return missing("PresentMon capture is stale or stopped")
        with file.open("rb") as stream:
            header = stream.readline().decode("utf-8-sig").strip()
            header_end = stream.tell()
            stream.seek(0, 2)
            start = max(header_end, stream.tell() - 262144)
            stream.seek(start)
            if start > header_end:
                stream.readline()  # Skip the first potentially partial record.
            data = stream.read().decode("utf-8", errors="replace")
        # The writer may currently be halfway through the final CSV record.
        if data and not data.endswith("\n"):
            data = data.rsplit("\n", 1)[0] if "\n" in data else ""
        fields = [h.strip().lower() for h in next(csv.reader([header]))]
        time_column = "timeinseconds" if "timeinseconds" in fields else "timeinms"
        required = {"application", "processid", "swapchainaddress", "msbetweenpresents", time_column}
        if not required.issubset(fields):
            return missing("Unsupported PresentMon CSV; use --v1_metrics")
        latest = 0.0
        groups = defaultdict(list)
        for row in csv.DictReader(io.StringIO(data), fieldnames=fields):
            t = number(row.get(time_column))
            if t is None:
                continue
            t = t / 1000 if time_column == "timeinms" else t
            latest = max(latest, t)
            if (row.get("application") or "").lower() != game["process"].lower() or row.get("processid") != str(game["pid"]):
                continue
            duration = number(row.get("msbetweenpresents"))
            if duration is not None and 0 < duration <= 1000:
                groups[row.get("swapchainaddress")].append((t, duration))
        samples = [[d for t, d in rows if latest - t <= 2] for rows in groups.values()]
        frames = max(samples, key=len, default=[])
        if len(frames) < 2:
            return missing("Waiting for fresh frames from the active game")
        return {"fps": round(1000 * len(frames) / sum(frames), 1),
                "fpsSource": "PresentMon · application FPS", "fpsUnavailableReason": None}
    except (OSError, ValueError, csv.Error):
        return missing("PresentMon CSV is missing or unreadable")
