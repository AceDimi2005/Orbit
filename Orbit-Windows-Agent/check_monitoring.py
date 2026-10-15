"""Read-only local source check. Does not start a server, create tokens or control apps."""
import json
import time

from orbit_agent import AGENT_VERSION
from orbit_hardware import IOCounterRates, detect_game, io_metrics, nvidia_metrics, read_fps, sensor_metrics


def monitoring_report():
    sensors = sensor_metrics()
    rates = IOCounterRates()
    io_metrics(rates)
    # Windows can defer the CSV's write timestamp while PresentMon holds it
    # open. Two reads let frame progress establish freshness independently.
    read_fps(detect_game())
    time.sleep(1.1)
    traffic = io_metrics(rates)
    frames = read_fps(detect_game())
    return {
        "agentVersion": AGENT_VERSION,
        "sensorSource": sensors.get("sensorSource"),
        "sensorStatus": sensors.get("sensorStatus"),
        "cpuTemp": sensors.get("cpuTemp"),
        "cpuPowerWatts": sensors.get("cpuPowerWatts"),
        "hardwareMonitorGpuTemp": sensors.get("gpuTemp"),
        "hardwareMonitorGpuSource": sensors.get("gpuSensorSource"),
        "nvidia": nvidia_metrics(),
        "network": traffic,
        "frames": frames,
        "note": "Afterburner/RTSS are detected locally. Missing sensor/FPS sources stay null. This check does not install or start monitoring tools.",
    }


if __name__ == "__main__":
    print(json.dumps(monitoring_report(), indent=2, ensure_ascii=True, allow_nan=False))
