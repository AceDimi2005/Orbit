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
import re
import socket
import subprocess
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import psutil

GIB = 1024 ** 3
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
SENSOR_FIELDS = ("cpuTemp", "liquidTemp", "cpuPowerWatts", "cpuFanRPM", "cpuClockMHz", "cpuClockSource")
GPU_SENSOR_FIELDS = ("gpuTemp", "gpuUsage", "gpuPowerWatts", "gpuFanPercent", "vramUsedGB", "vramTotalGB")
RATE_FIELDS = ("diskReadMBps", "diskWriteMBps", "networkUploadMBps", "networkDownloadMBps")


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
            "nvidia-smi", "--query-gpu=name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total,driver_version,fan.speed",
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
                       "driverVersion": values[6], "gpuFanPercent": number(values[7]) if len(values) > 7 else None})
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


def librehardware_metrics(sensors):
    """Read actual CPU/GPU sensors from one package and one adapter at a time."""
    result = dict.fromkeys(SENSOR_FIELDS + GPU_SENSOR_FIELDS + ("gpuSensorName",))
    readings = []
    gpu_names = {}
    for sensor in as_list(sensors):
        if not isinstance(sensor, dict):
            continue
        value = number(sensor.get("Value"))
        if value is None or value < 0:
            continue
        label = " ".join(str(sensor.get("Name", "")).lower().split())
        identifier = str(sensor.get("Identifier") or "").lower()
        parent = str(sensor.get("Parent") or "").lower()
        cpu = re.match(r"^/(?:intelcpu|amdcpu|cpu)/(\d+)(?:/|$)", parent)
        if not cpu:
            cpu = re.match(r"^/(?:intelcpu|amdcpu|cpu)/(\d+)(?:/|$)", identifier)
        gpu = re.match(r"^/(gpu-(?:nvidia|amd|ati|intel))/([^/]+)(?:/|$)", parent)
        if not gpu:
            gpu = re.match(r"^/(gpu-(?:nvidia|amd|ati|intel))/([^/]+)(?:/|$)", identifier)
        if gpu and sensor.get("HardwareName"):
            gpu_names[(gpu[1], gpu[2])] = str(sensor["HardwareName"]).strip() or None
        readings.append((str(sensor.get("SensorType") or "").lower(), label, identifier,
                         int(cpu[1]) if cpu else None, value,
                         (gpu[1], gpu[2]) if gpu else None))
    # Prefer CPU 0 (or the first available package) consistently across types.
    cpu_index = min((r[3] for r in readings if r[3] is not None), default=None)
    selected = [r for r in readings if r[3] is not None and r[3] == cpu_index]
    temperatures = sorted((r for r in selected if r[0] == "temperature" and
                           any(part in r[1] for part in ("package", "tctl", "tdie"))),
                          key=lambda r: ("package" not in r[1], "tdie" not in r[1], r[2]))
    if temperatures:
        result["cpuTemp"] = temperatures[0][4]
    else:
        # Some CPUs expose only cores/CCD sensors, without a package reading.
        cores = [r[4] for r in selected if r[0] == "temperature" and
                 re.match(r"^(?:cpu )?(?:core(?:s|\s|#|$)|ccd(?:\s|#|\d|$))", r[1]) and
                 "distance" not in r[1] and "tjmax" not in r[1]]
        if cores:
            result["cpuTemp"] = max(cores)
    packages = sorted((r for r in selected if r[0] == "power" and r[1] in {"cpu package", "package"}),
                      key=lambda r: r[2])
    if packages:
        result["cpuPowerWatts"] = packages[0][4]
    clocks = [r[4] for r in selected if r[0] == "clock" and
              re.match(r"^(?:cpu )?core(?:\s|#|$)", r[1]) and r[4] > 0]
    if clocks:
        result["cpuClockMHz"] = round(sum(clocks) / len(clocks), 1)
        result["cpuClockSource"] = "LibreHardwareMonitor · core average"
    # A generic Fan #1 or pump cannot reliably be identified as the CPU fan.
    fans = sorted((r for r in readings if r[0] == "fan" and
                   re.match(r"^cpu(?:\s|_)?fan(?:\s|#|$)", r[1])), key=lambda r: r[2])
    if fans:
        result["cpuFanRPM"] = fans[0][4]
    liquids = sorted((r for r in readings if r[0] == "temperature" and
                      ("liquid" in r[1] or "coolant" in r[1])), key=lambda r: r[2])
    if liquids:
        result["liquidTemp"] = liquids[0][4]

    adapters = {r[5] for r in readings if r[5] is not None}
    if adapters:
        # Align the fallback with nvidia-smi when present. Never mix two GPUs.
        rank = {"gpu-nvidia": 0, "gpu-amd": 1, "gpu-ati": 1, "gpu-intel": 2}
        adapter = min(adapters, key=lambda item: (rank[item[0]], item[1]))
        result["gpuSensorName"] = gpu_names.get(adapter)
        gpu_readings = sorted((r for r in readings if r[5] == adapter), key=lambda r: r[2])
        for field, kind, names in (
            ("gpuTemp", "temperature", ("gpu core", "gpu temperature")),
            ("gpuUsage", "load", ("gpu core", "gpu d3d 3d", "d3d 3d")),
            ("gpuPowerWatts", "power", ("gpu package", "gpu power", "gpu total", "gpu board power")),
            ("gpuFanPercent", "control", ("gpu fan",)),
            ("vramUsedGB", "gib", ("gpu memory used", "d3d dedicated memory used")),
            ("vramTotalGB", "gib", ("gpu memory total", "d3d dedicated memory total")),
        ):
            for name in names:
                value = next((r[4] for r in gpu_readings if r[0] == kind and r[1] == name), None)
                if value is not None:
                    result[field] = round(value, 2) if kind == "gib" else value
                    break
        for field in ("gpuUsage", "gpuFanPercent"):
            if result[field] is not None and result[field] > 100:
                result[field] = None
    return result


def _http_sensor_value(node):
    """Normalize the HTTP server's units; RawValue temperatures are always Celsius."""
    kind = str(node.get("Type") or "").lower()
    raw = number(node.get("RawValue"))
    if "RawValue" in node and raw is None:
        return None, kind
    text = str(node.get("Value") or "").strip().replace("\u2212", "-")
    match = re.fullmatch(r"(-?\d+(?:[.,]\d+)?)\s*(.*)", text)
    value = number(match[1].replace(",", ".")) if match else None
    unit = match[2].strip().lower() if match else ""
    if kind in {"data", "smalldata"}:
        # LHM changed Data from GiB/MiB to bytes. The formatted unit is explicit
        # in every version, so do not guess raw memory units from magnitude.
        scales = {"b": 1 / GIB, "kb": 1 / 1024 ** 2, "kib": 1 / 1024 ** 2,
                  "mb": 1 / 1024, "mib": 1 / 1024, "gb": 1, "gib": 1,
                  "tb": 1024, "tib": 1024}
        return (value * scales[unit], "gib") if value is not None and unit in scales else (None, "gib")
    if raw is not None:
        return raw, kind
    if value is None:
        return None, kind
    if kind == "temperature":
        if unit in {"°f", "f"}:
            return (value - 32) * 5 / 9, kind
        return (value, kind) if unit in {"°c", "c"} else (None, kind)
    if kind == "clock":
        return (value * {"mhz": 1, "ghz": 1000, "khz": .001}[unit], kind) if unit in {"mhz", "ghz", "khz"} else (None, kind)
    expected = {"power": "w", "fan": "rpm", "load": "%", "control": "%"}
    return (value, kind) if expected.get(kind) == unit else (None, kind)


def librehardware_http_sensors(document):
    """Flatten official data.json (including old versions without HardwareId)."""
    sensors = []
    pending = [(node, "", None) for node in as_list(document)]
    while pending:
        node, parent, hardware_name = pending.pop()
        if not isinstance(node, dict):
            continue
        if node.get("HardwareId"):
            parent = str(node["HardwareId"])
            hardware_name = node.get("Text")
        identifier = node.get("SensorId")
        if identifier:
            value, kind = _http_sensor_value(node)
            sensors.append({"Name": node.get("Text"), "SensorType": kind, "Value": value,
                            "Identifier": identifier, "Parent": parent, "HardwareName": hardware_name})
        pending.extend((child, parent, hardware_name) for child in as_list(node.get("Children")))
    return sensors


def query_librehardware_http():
    """Read LHM on this PC only; bypass proxy settings for the loopback endpoint."""
    url = os.getenv("ORBIT_LHM_URL", "http://127.0.0.1:8085/data.json").strip()
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.username or parsed.password:
        raise ValueError("ORBIT_LHM_URL must be a local HTTP URL, e.g. http://127.0.0.1:8085/data.json")
    if parsed.path in {"", "/"}:
        url = url.rstrip("/") + "/data.json"
    # A local sensor source must not redirect to a remote host.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, file_pointer, code, message, headers, new_url):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=2) as response:
        payload = response.read(2_000_001)
    if len(payload) > 2_000_000:
        raise ValueError("LibreHardwareMonitor JSON is too large")
    return librehardware_http_sensors(json.loads(payload.decode("utf-8-sig")))


def _platform_sensor_metrics():
    """Use exposed sensors only; clock fallback is explicitly marked nominal."""
    result = dict.fromkeys(SENSOR_FIELDS + GPU_SENSOR_FIELDS + ("gpuSensorName", "sensorSource", "sensorStatus"))
    if os.name == "nt":
        # New LHM versions removed WMI. Prefer their HTTP API, then retain WMI
        # compatibility for older LHM/OpenHardwareMonitor installations.
        try:
            sensors = query_librehardware_http()
            result.update(librehardware_metrics(sensors))
            if sensors:
                result["sensorSource"] = "LibreHardwareMonitor · HTTP"
        except (OSError, ValueError, TypeError):
            pass
        if result["sensorSource"] is None:
            try:
                sensors = powershell_json(r"""
                $ErrorActionPreference = 'Stop'
                $sensors = @()
                foreach ($namespace in @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor')) {
                  try {
                    $sensors = @(Get-CimInstance -Namespace $namespace -ClassName Sensor -ErrorAction Stop |
                      Where-Object { $_.SensorType -in @('Temperature','Power','Fan','Clock','Load','Control') } |
                      Select-Object Name,Identifier,Parent,SensorType,Value)
                    if ($sensors.Count -gt 0) { break }
                  } catch { }
                }
                ConvertTo-Json -InputObject @($sensors) -Compress
                """, timeout=4)
                wmi = librehardware_metrics(sensors)
                result.update({key: value for key, value in wmi.items() if value is not None})
                if sensors:
                    result["sensorSource"] = "Hardware monitor · WMI"
            except (OSError, subprocess.SubprocessError, ValueError, TypeError):
                pass
    else:
        try:
            for name, entries in getattr(psutil, "sensors_temperatures", lambda: {})().items():
                if name.lower() not in {"coretemp", "k10temp", "cpu_thermal"}:
                    continue
                valid = [number(e.current) for e in entries if number(e.current) is not None and e.current >= 0]
                if valid:
                    result["cpuTemp"] = max(valid)
                    result["sensorSource"] = "System sensors"
        except (AttributeError, OSError, RuntimeError, NotImplementedError):
            pass
    if result["cpuTemp"] is not None:
        result["sensorStatus"] = "Temperature sensors connected."
    elif result["sensorSource"] is not None:
        result["sensorStatus"] = "Hardware monitor connected, but no CPU temperature sensor was exposed. Check sensor access and CPU support."
    elif os.name == "nt":
        result["sensorStatus"] = "Open LibreHardwareMonitor as administrator and enable Options → Remote Web Server → Run (port 8085)."
    else:
        result["sensorStatus"] = "No supported temperature sensors are exposed by this system."
    if result["cpuClockMHz"] is None:
        try:
            frequency = psutil.cpu_freq()
            current = number(frequency.current) if frequency is not None else None
            if current is not None and current > 0:
                result["cpuClockMHz"] = round(current, 1)
                result["cpuClockSource"] = "System · current clock" if platform.system() == "Linux" else "System · nominal clock"
        except (AttributeError, OSError, RuntimeError, NotImplementedError):
            pass
    return result


def sensor_metrics():
    """Prefer Afterburner, retaining optional system/LHM sensor coverage.

    CPU fields can fill gaps from explicitly identified monitor sensors. GPU
    fields always come from a single adapter/source, even when incomplete.
    """
    from orbit_afterburner import afterburner_metrics
    primary = afterburner_metrics() if os.name == "nt" else {}
    fallback = _platform_sensor_metrics()
    if not primary.get("sensorSource"):
        fallback["gpuSensorSource"] = fallback.get("sensorSource")
        if os.name == "nt" and not fallback.get("sensorSource"):
            fallback["sensorStatus"] = (
                "Start MSI Afterburner and enable the desired Active hardware monitoring graphs in Settings → Monitoring. "
                "Alternatively, open LibreHardwareMonitor and enable Options → Remote Web Server → Run (port 8085)."
            )
        return fallback

    result = {key: primary.get(key) for key in SENSOR_FIELDS + GPU_SENSOR_FIELDS + ("gpuSensorName",)}
    providers = []
    if any(primary.get(key) is not None for key in SENSOR_FIELDS if key != "cpuClockSource"):
        providers.append(primary["sensorSource"])
    for key in SENSOR_FIELDS:
        if key == "cpuClockSource" or result[key] is not None or fallback.get(key) is None:
            continue
        result[key] = fallback[key]
        if key == "cpuClockMHz":
            result["cpuClockSource"] = fallback.get("cpuClockSource")
        if fallback.get("sensorSource") and fallback["sensorSource"] not in providers:
            providers.append(fallback["sensorSource"])
    if any(primary.get(key) is not None for key in GPU_SENSOR_FIELDS):
        result["gpuSensorSource"] = primary.get("gpuSensorSource") or primary["sensorSource"]
    else:
        result.update({key: fallback.get(key) for key in GPU_SENSOR_FIELDS + ("gpuSensorName",)})
        result["gpuSensorSource"] = fallback.get("sensorSource")
    result["sensorSource"] = " + ".join(providers) or primary["sensorSource"]
    result["sensorStatus"] = (
        "Temperature sensors connected."
        if result["cpuTemp"] is not None else
        "Hardware monitor connected, but no CPU temperature sensor was exposed. Enable CPU temperature in Afterburner Monitoring, or use LibreHardwareMonitor for unsupported sensors."
    )
    return result


def read_fps(game=None):
    """Use RTSS automatically; a configured PresentMon capture is a fallback."""
    from orbit_rtss import read_rtss
    rtss = read_rtss(game)
    if rtss.get("fps") is not None:
        return rtss
    path = os.getenv("ORBIT_PRESENTMON_CSV") or os.getenv("ORBIT_PRESENTATION_CSV")
    if not path:
        return rtss
    captured = read_presentmon(path, game)
    if captured.get("fps") is not None:
        return captured
    return {"fps": None, "fpsSource": None,
            "fpsUnavailableReason": f"{rtss.get('fpsUnavailableReason', 'RTSS unavailable')} · PresentMon: {captured.get('fpsUnavailableReason', 'Capture unavailable')}"}


def temperature_metrics():
    """Compatibility wrapper for clients that need only the historic temperatures."""
    readings = sensor_metrics()
    return {key: readings[key] for key in ("cpuTemp", "liquidTemp")}


class IOCounterRates:
    """Per-device monotonic deltas in decimal MB/s; no invented first/reset rate.

    A hotplugged or reset device primes itself without dropping healthy devices.
    Missing counters invalidate only that device/direction until its next sample.
    """
    def __init__(self):
        self.previous = {}

    def sample(self, disks, networks, now=None):
        now = number(time.monotonic() if now is None else now)
        result = dict.fromkeys(RATE_FIELDS)
        if now is None:
            return result

        def byte_count(value):
            # Preserve integers: casting large lifetime counters to float first
            # erases small deltas (and low traffic) once a counter exceeds 2**53.
            value = value if isinstance(value, int) else number(value)
            return value if value is not None and value >= 0 else None

        for group, counters, pairs in (
            ("disk", disks, (("read_bytes", "diskReadMBps"), ("write_bytes", "diskWriteMBps"))),
            ("network", networks, (("bytes_sent", "networkUploadMBps"), ("bytes_recv", "networkDownloadMBps"))),
        ):
            previous = self.previous.get(group)
            if previous and now <= previous[0]:
                # A duplicate/backward clock must not replace the last valid
                # baseline and turn the next interval into a fabricated spike.
                continue
            snapshot = {name: {attribute: byte_count(getattr(counter, attribute, None)) for attribute, _ in pairs}
                        for name, counter in (counters or {}).items()}
            self.previous[group] = (now, snapshot) if snapshot else None
            if not previous or not snapshot:
                continue
            elapsed = now - previous[0]
            for attribute, field in pairs:
                deltas = []
                for name, values in snapshot.items():
                    old, new = previous[1].get(name, {}).get(attribute), values[attribute]
                    if old is None or new is None or new < old:
                        continue
                    deltas.append(new - old)
                if deltas:
                    # Leave formatting to clients; 3 decimal places hides all
                    # activity below 500 bytes/s and makes idle links look stuck.
                    result[field] = sum(deltas) / elapsed / 1_000_000
        return result


def network_counters_for_monitoring(counters):
    """Select active interfaces, excluding local/tunnel duplication when known.

    psutil exposes no portable physical-adapter flag. Only exclude confidently
    identified loopback/virtual adapters; an exact ORBIT_NETWORK_INTERFACE lets
    custom networks and VPNs select their intended accounting boundary.
    """
    if counters is None:
        return None
    configured = os.getenv("ORBIT_NETWORK_INTERFACE", "").strip().casefold()
    if configured:
        return {name: values for name, values in counters.items() if name.casefold() == configured}
    try:
        stats = psutil.net_if_stats()
    except (OSError, RuntimeError, NotImplementedError):
        stats = {}
    try:
        addresses = psutil.net_if_addrs()
    except (OSError, RuntimeError, NotImplementedError):
        addresses = {}
    selected = {}
    for name, values in counters.items():
        label = name.strip().casefold()
        if ("loopback" in label or re.match(r"^lo\d*$", label) or
                re.match(r"^(?:utun|tun|tap|veth|vmnet|vboxnet)\d*(?:\W|$)", label) or
                label.startswith(("vethernet", "vmware network adapter", "virtualbox", "docker", "isatap", "teredo",
                                  "tailscale", "wireguard", "zerotier", "hamachi"))):
            continue
        status = stats.get(name)
        flags = str(getattr(status, "flags", "")).casefold().split(",")
        if status is not None and (not status.isup or "loopback" in flags):
            continue
        ips = [address.address.split("%", 1)[0] for address in addresses.get(name, [])
               if address.family in (socket.AF_INET, socket.AF_INET6)]
        if ips and all(ip.startswith("127.") or ip == "::1" for ip in ips):
            continue
        selected[name] = values
    return selected


def io_metrics(rates):
    # Disable psutil's wrap cache so a reset can be recognized and re-primed.
    try:
        disks = psutil.disk_io_counters(perdisk=True, nowrap=False)
    except (OSError, RuntimeError, NotImplementedError):
        disks = None
    try:
        networks = psutil.net_io_counters(pernic=True, nowrap=False)
    except (OSError, RuntimeError, NotImplementedError):
        networks = None
    networks = network_counters_for_monitoring(networks)
    result = rates.sample(disks, networks)
    result["networkInterface"] = ", ".join(sorted(networks)) if networks else None
    return result


def foreground_pid():
    if os.name != "nt":
        return None
    pid = ctypes.c_ulong()
    user32 = ctypes.windll.user32
    user32.GetForegroundWindow.restype = ctypes.c_void_p
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    window = user32.GetForegroundWindow()
    if not window:
        return None
    user32.GetWindowThreadProcessId(window, ctypes.byref(pid))
    return pid.value or None


def _exe_name(value):
    # Windows paths must also normalize correctly in tests on macOS/Linux.
    return str(value or "").replace("\\", "/").rsplit("/", 1)[-1].strip().lower()


def _game_process_names():
    return {_exe_name(n): _exe_name(n).removesuffix(".exe")
            for n in os.getenv("ORBIT_GAME_PROCESSES", "").split(";") if n.strip()}


def detect_game(configured=None):
    """Recognize user-selected exe names or games in standard launcher libraries."""
    configured = _game_process_names() if configured is None else {
        _exe_name(name): title for name, title in configured.items()}
    foreground = foreground_pid()
    candidates = []
    for process in psutil.process_iter(["pid", "name", "exe", "create_time"]):
        try:
            info = process.info
            name = _exe_name(info.get("name"))
            path = (info.get("exe") or "").replace("\\", "/").lower()
            library = any(part in path for part in ("/steamapps/common/", "/epic games/", "/gog games/"))
            helper = any(part in name for part in ("crash", "launcher", "unins", "helper", "webhelper", "setup", "anticheat"))
            if name in configured or (library and not helper and name.endswith(".exe")):
                candidates.append({"name": configured.get(name) or name.removesuffix(".exe"),
                                   "process": info["name"], "pid": info["pid"],
                                   "foreground": info["pid"] == foreground, "created": info.get("create_time") or 0})
        except (psutil.Error, OSError):
            continue
    return max(candidates, key=lambda g: (g["foreground"], g["created"]), default=None)


# Remember actual frame progress: Windows can defer LastWriteTime updates until
# the capture closes its write handle. Merely touching an old CSV is not progress.
_PRESENTMON_PROGRESS = {}
_PRESENTMON_DESKTOP_PROCESSES = {
    "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe",
    "chromium.exe", "browser.exe", "msedgewebview2.exe", "discord.exe",
    "dwm.exe", "explorer.exe", "applicationframehost.exe", "taskmgr.exe",
    "steam.exe", "epicgameslauncher.exe", "galaxyclient.exe", "obs64.exe",
    "cmd.exe", "powershell.exe", "pwsh.exe", "windowsterminal.exe",
    "python.exe", "pythonw.exe", "code.exe", "devenv.exe", "orbit.exe",
    "shellexperiencehost.exe", "searchhost.exe", "startmenuexperiencehost.exe",
}


def _presentmon_game(rows):
    """A live foreground capture can identify games installed outside libraries.

    Do not guess a game from the busiest background process: browsers, desktop
    composition, overlays and media applications also submit frames.
    """
    foreground = foreground_pid()
    if not foreground:
        return None
    names = {row["process"] for row in rows if row["pid"] == foreground}
    if not names:
        return None
    configured = _game_process_names()
    try:
        process = psutil.Process(foreground)
        name = _exe_name(process.name())
        if not process.is_running() or name not in names:
            return None
        helper = any(part in name for part in ("launcher", "helper", "crash", "anticheat", "unins", "setup"))
        if name not in configured and (name in _PRESENTMON_DESKTOP_PROCESSES or helper or not name.endswith(".exe")):
            return None
        return {"name": configured.get(name) or name.removesuffix(".exe"),
                "process": name, "pid": foreground, "foreground": True}
    except (psutil.Error, OSError):
        return None


def _presentmon_fresh(file, stat, game, chain, marker, now):
    key = (str(file.resolve()), game["pid"], chain)
    previous = _PRESENTMON_PROGRESS.get(key)
    identity = (stat.st_dev, stat.st_ino)
    if previous is None or previous["identity"] != identity or now < previous["seen"]:
        advanced = min(now, stat.st_mtime)
    elif marker != previous["marker"]:
        advanced = now
    else:
        advanced = previous["advanced"]
    _PRESENTMON_PROGRESS[key] = {"identity": identity, "marker": marker,
                                 "advanced": advanced, "seen": now}
    # A long-running agent must not accumulate every historical capture/PID.
    while len(_PRESENTMON_PROGRESS) > 64:
        del _PRESENTMON_PROGRESS[next(iter(_PRESENTMON_PROGRESS))]
    return now - advanced <= 5


def read_presentmon(path, game, now=None):
    """Read bounded live CSV data, keeping process and swap-chain FPS separate.

    Support legacy v1, current default metrics, and native v2 CPU frame timing.
    FPS is measured from frame intervals, never inferred from GPU utilization.
    Native v2's FrameTime is a CPU frame-start interval rather than displayed FPS.
    """
    def missing(reason):
        return {"fps": None, "fpsSource": None, "fpsUnavailableReason": reason}

    path = path or os.getenv("ORBIT_PRESENTMON_CSV") or os.getenv("ORBIT_PRESENTATION_CSV")
    if not path or not str(path).strip():
        return missing("Configure ORBIT_PRESENTMON_CSV and start a live PresentMon capture")
    now = time.time() if now is None else now
    try:
        file = Path(os.path.expandvars(str(path).strip().strip('"'))).expanduser()
        with file.open("rb") as stream:
            header = stream.readline(32768).decode("utf-8-sig", errors="replace").strip()
            header_end = stream.tell()
            stream.seek(0, 2)
            start = max(header_end, stream.tell() - 524288)
            stream.seek(start)
            if start > header_end:
                stream.readline(32768)  # Skip a potentially partial record.
            data = stream.read(524288).decode("utf-8", errors="replace")
            stat = os.fstat(stream.fileno())
        if not header:
            return missing("PresentMon CSV is empty; start recording frames")
        # A writer can be halfway through its final CSV record.
        if data and not data.endswith("\n"):
            data = data.rsplit("\n", 1)[0] if "\n" in data else ""
        fields = [h.strip().lower() for h in next(csv.reader([header]))]
        time_units = (("timeinseconds", 1), ("timeinms", .001),
                      ("cpustarttimeinseconds", 1), ("cpustarttimeinms", .001),
                      ("cpustartqpctimeinms", .001), ("cpustartqpctime", .001),
                      ("cpustarttime", .001))
        timing = next(((field, unit) for field, unit in time_units if field in fields), None)
        interval = "msbetweenpresents" if "msbetweenpresents" in fields else "frametime"
        required = {"application", "processid", "swapchainaddress", interval}
        if not timing or not required.issubset(fields):
            return missing("Unsupported PresentMon CSV; use --v1_metrics without --qpc_time or --date_time")
        time_column, scale = timing
        latest = 0.0
        rows = []
        for values in csv.reader(io.StringIO(data)):
            if len(values) != len(fields):
                continue
            row = dict(zip(fields, (value.strip() for value in values)))
            t, duration = number(row.get(time_column)), number(row.get(interval))
            if t is None or t < 0:
                continue
            t *= scale
            latest = max(latest, t)
            pid = row.get("processid", "")
            chain = row.get("swapchainaddress")
            if not pid.isdecimal() or not chain or duration is None or not 0 < duration <= 60000:
                continue
            # Generated/repeated frames are not extra application CPU frames.
            if row.get("frametype", "application").lower().replace(" ", "") not in {
                "application", "notset", "unspecified", "0", "1", "2"
            }:
                continue
            rows.append({"process": _exe_name(row.get("application")), "pid": int(pid),
                         "chain": chain.lower(), "time": t, "duration": duration})
        selected = game
        if not game or game.get("foreground") is False:
            selected = _presentmon_game(rows) or game
        if not selected:
            return missing("No game detected; focus the game or set ORBIT_GAME_PROCESSES to its executable name")
        groups = defaultdict(list)
        for row in rows:
            if row["process"] == _exe_name(selected["process"]) and row["pid"] == selected["pid"] and latest - row["time"] <= 2:
                groups[row["chain"]].append((row["time"], row["duration"]))
        chain, frames = max(groups.items(), key=lambda item: len(item[1]), default=(None, []))
        if len(frames) < 2:
            return missing("Waiting for fresh frames from the active game; check PresentMon's --process_name and the CSV path")
        if not _presentmon_fresh(file, stat, selected, chain, max(t for t, _ in frames), now):
            return missing("PresentMon capture is stale or stopped; keep recording to the configured CSV")
        result = {"fps": round(1000 * len(frames) / sum(d for _, d in frames), 1),
                  "fpsSource": "PresentMon · application FPS" if interval == "msbetweenpresents" else "PresentMon · CPU frame FPS",
                  "fpsUnavailableReason": None}
        if selected is not game:
            result.update(activeGame=selected["name"], activeGameProcess=selected["process"])
        return result
    except FileNotFoundError:
        return missing("PresentMon CSV does not exist; start PresentMon with --output_file matching ORBIT_PRESENTMON_CSV")
    except (OSError, ValueError, csv.Error):
        return missing("PresentMon CSV is unreadable; check the configured path and file permissions")
