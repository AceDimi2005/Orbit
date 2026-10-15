"""Read-only MSI Afterburner MAHM v2 hardware-monitor measurements.

Layout and identifiers follow MSI's SDK/Include/MAHMSharedMemory.h, mirrored at:
https://github.com/mmtylcn27/MSIAfterburnerPlugin/blob/main/MsiAfterburnerPlugin/MsiSdk/MAHMSharedMemory.h
The SDK documents 32-bit polling time, FLT_MAX for missing data, GPU indices,
relative versus absolute power, and GPU descriptor memory in KiB. No SDK binary
or header is redistributed. Custom/localized display names are not evaluated.
"""
import math
import os
import struct
import time

from orbit_shared_memory import read_mapping

_FIELDS = ("cpuTemp", "liquidTemp", "cpuPowerWatts", "cpuFanRPM", "cpuClockMHz", "cpuClockSource",
           "gpuTemp", "gpuUsage", "gpuPowerWatts", "gpuFanPercent", "vramUsedGB", "vramTotalGB",
           "gpuSensorName", "gpuSensorSource", "sensorSource", "sensorStatus")
_SIGNATURE = 0x4D41484D  # C DWORD 'MAHM'; little-endian bytes are b'MHAM'.
_HEADER = struct.Struct("<8I")
_ENTRY_SIZE = 5 * 260 + 24
_GPU_SIZE = 5 * 260 + 4
_MAX_BYTES = 8 * 1024 * 1024
_MAX_AGE = 15
_GLOBAL = 0xFFFFFFFF
_FLT_MAX = float.fromhex("0x1.fffffep+127")


def _empty(status):
    result = dict.fromkeys(_FIELDS)
    result["sensorStatus"] = status
    return result


def _text(blob):
    raw = blob.split(b"\0", 1)[0]
    # SDK strings are ANSI. UTF-8 is accepted too for synthetic/test producers;
    # native source names/units are stable English, not user-facing overrides.
    try:
        return raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace").strip()


def _unit(value):
    return value.casefold().replace(" ", "")


def _temperature(value, unit):
    unit = _unit(unit)
    if unit in {"°c", "c"}:
        return value
    if unit in {"°f", "f"}:
        return (value - 32) * 5 / 9
    return None


def parse_afterburner(data, now=None):
    """Parse one bounded MAHM snapshot; invalid/stale layouts raise ValueError.

    Only SDK source IDs with their expected units become measurements. GPU
    entries stay on a single adapter. Missing package power is never built by
    summing cores, and plugin or GPU fans cannot masquerade as a CPU fan.
    """
    if not isinstance(data, (bytes, bytearray, memoryview)) or not _HEADER.size <= len(data) <= _MAX_BYTES:
        raise ValueError("MSI Afterburner shared memory is incomplete or exceeds the size limit.")
    signature, version, header_size, count, entry_size, updated, gpu_count, gpu_size = _HEADER.unpack_from(data)
    if signature != _SIGNATURE:
        raise ValueError("MSI Afterburner shared memory is not initialized or has been closed.")
    if version >> 16 != 2:
        raise ValueError("Unsupported MSI Afterburner shared-memory version; MAHM v2 is required.")
    if (header_size < _HEADER.size or header_size > len(data) or header_size % 4 or
            entry_size < _ENTRY_SIZE or entry_size % 4 or count > 4096 or gpu_count > 64 or
            (gpu_count and (gpu_size < _GPU_SIZE or gpu_size % 4))):
        raise ValueError("MSI Afterburner shared-memory sizes are invalid.")
    gpu_start = header_size + count * entry_size
    if gpu_start + gpu_count * gpu_size > len(data):
        raise ValueError("MSI Afterburner shared-memory arrays are truncated.")
    now = time.time() if now is None else float(now)
    if not math.isfinite(now) or updated == 0 or not -5 <= now - updated <= _MAX_AGE:
        raise ValueError("MSI Afterburner sensor readings are stale; keep hardware monitoring running.")

    readings = []
    for index in range(count):
        offset = header_size + index * entry_size
        value, _minimum, _maximum, _flags, gpu, source = struct.unpack_from("<fffIII", data, offset + 1300)
        if not math.isfinite(value) or value == _FLT_MAX or value < 0:
            continue
        name = " ".join(_text(bytes(data[offset:offset + 260])).casefold().split())
        units = _text(bytes(data[offset + 260:offset + 520]))
        readings.append((source, gpu, name, units, value))

    result = _empty("MSI Afterburner connected, but CPU temperature is not enabled or available in Monitoring.")
    result["sensorSource"] = "MSI Afterburner"
    # CPU source IDs are global. The GPU index must not turn a GPU sensor or
    # a third-party plugin bearing a CPU-like display name into a CPU reading.
    cpu = [row for row in readings if row[1] == _GLOBAL]
    temperatures = [(row[2], _temperature(row[4], row[3])) for row in cpu if row[0] == 0x80]
    temperatures = [(name, value) for name, value in temperatures if value is not None]
    if temperatures:
        packages = [(name, value) for name, value in temperatures if name == "cpu temperature" or
                    any(token in name for token in ("package", "tctl", "tdie"))]
        result["cpuTemp"] = sorted(packages, key=lambda item: item[0])[0][1] if packages else max(value for _, value in temperatures)
        result["sensorStatus"] = "MSI Afterburner temperature sensors connected."
    power_names = {"cpu power", "cpu package", "cpu package power", "processor package power"}
    powers = sorted((row for row in cpu if row[0] == 0x100 and row[2] in power_names and _unit(row[3]) == "w"),
                    key=lambda row: row[2])
    if powers:
        result["cpuPowerWatts"] = powers[0][4]
    clocks = [(row[2], row[4] * {"mhz": 1, "ghz": 1000}[_unit(row[3])])
              for row in cpu if row[0] == 0xA0 and _unit(row[3]) in {"mhz", "ghz"} and row[4] > 0]
    aggregate = [value for name, value in clocks if name == "cpu clock"]
    if aggregate:
        result["cpuClockMHz"] = round(aggregate[0], 1)
        result["cpuClockSource"] = "MSI Afterburner · CPU clock"
    elif clocks:
        result["cpuClockMHz"] = round(sum(value for _, value in clocks) / len(clocks), 1)
        result["cpuClockSource"] = "MSI Afterburner · core average"

    # Validate IDs and units before selecting an adapter. A bogus/unsupported
    # metric on GPU 0 cannot hide valid measured sensors from GPU 1.
    gpu_values = []
    fields = {0x00: "gpuTemp", 0x10: "gpuFanPercent", 0x30: "gpuUsage",
              0x31: "vramUsedGB", 0x61: "gpuPowerWatts"}
    scales = {"b": 1 / 1024 ** 3, "kb": 1 / 1024 ** 2, "kib": 1 / 1024 ** 2,
              "mb": 1 / 1024, "mib": 1 / 1024, "gb": 1, "gib": 1}
    for source, gpu, _name, units, value in readings:
        field = fields.get(source)
        if field is None or gpu >= gpu_count:
            continue
        unit = _unit(units)
        if field == "gpuTemp":
            value = _temperature(value, units)
        elif field in {"gpuFanPercent", "gpuUsage"}:
            value = value if unit == "%" and value <= 100 else None
        elif field == "gpuPowerWatts":
            value = value if unit == "w" else None
        elif field == "vramUsedGB":
            value = round(value * scales[unit], 2) if unit in scales else None
        if value is not None:
            gpu_values.append((gpu, field, value))
    if gpu_values:
        selected = min(gpu for gpu, _, _ in gpu_values)
        for gpu, field, value in gpu_values:
            if gpu == selected and result[field] is None:
                result[field] = value
        offset = gpu_start + selected * gpu_size
        result["gpuSensorName"] = _text(bytes(data[offset + 520:offset + 780])) or None
        capacity = struct.unpack_from("<I", data, offset + 1300)[0]
        if capacity not in {0, _GLOBAL}:
            result["vramTotalGB"] = round(capacity / 1024 ** 2, 2)
        if result["vramUsedGB"] is not None and result["vramTotalGB"] is not None and result["vramUsedGB"] > result["vramTotalGB"]:
            result["vramUsedGB"] = None
        result["gpuSensorSource"] = "MSI Afterburner"
    return result


def afterburner_metrics(now=None):
    """Open existing monitoring memory on Windows; never start or control MSI."""
    if os.name != "nt":
        return _empty("MSI Afterburner monitoring requires Windows.")
    try:
        return parse_afterburner(read_mapping("MAHMSharedMemory", max_bytes=_MAX_BYTES), now=now)
    except (OSError, ValueError) as error:
        status = str(error) if isinstance(error, ValueError) else (
            "MSI Afterburner monitoring is unavailable; open Afterburner and enable the required graphs under Settings → Monitoring.")
        return _empty(status)
