"""Read-only sensor regressions; external hardware and Windows queries are mocked."""
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import orbit_hardware as hardware


def sensor(name, kind, value, identifier, parent=None):
    return {"Name": name, "SensorType": kind, "Value": value,
            "Identifier": identifier, "Parent": parent}


def leaf(name, kind, value, identifier, **extra):
    return {"Text": name, "Type": kind, "Value": value, "SensorId": identifier, **extra}


def tree(children, identifier="/intelcpu/0", name="Example CPU"):
    return {"Children": [{"HardwareId": identifier, "Text": name, "Children": children}]}


class SensorParsingTests(unittest.TestCase):
    def test_core_only_cpu_hottest_measured_core_not_distance(self):
        readings = [sensor("CPU Core #1", "Temperature", 50, "/intelcpu/0/temperature/1"),
                    sensor("CPU Core #2", "Temperature", 64, "/intelcpu/0/temperature/2"),
                    sensor("CPU Core #1 Distance to TjMax", "Temperature", 95, "/intelcpu/0/temperature/3"),
                    sensor("GPU Core", "Temperature", 90, "/gpu-amd/0/temperature/0")]
        self.assertEqual(hardware.librehardware_metrics(readings)["cpuTemp"], 64)

    def test_package_preferred_and_sensor_order_independent(self):
        readings = [sensor("CPU Core #1", "Temperature", 80, "/intelcpu/0/temperature/1"),
                    sensor("CPU Package", "Temperature", 62, "/intelcpu/0/temperature/0"),
                    sensor("CPU Package", "Temperature", 99, "/intelcpu/1/temperature/0")]
        result = hardware.librehardware_metrics(readings)
        self.assertEqual(result["cpuTemp"], 62)
        self.assertEqual(hardware.librehardware_metrics(list(reversed(readings))), result)

    def test_malformed_parent_does_not_hide_sensor_identifier(self):
        result = hardware.librehardware_metrics(sensor("CPU (Tctl/Tdie)", "Temperature", 58,
                                                     "/amdcpu/0/temperature/0", "invalid"))
        self.assertEqual(result["cpuTemp"], 58)

    def test_gpu_core_not_vram_or_hotspot_temperature(self):
        readings = [sensor("GPU Memory", "Temperature", 96, "/gpu-amd/0/temperature/1"),
                    sensor("GPU Hot Spot", "Temperature", 90, "/gpu-amd/0/temperature/7"),
                    sensor("GPU Core", "Temperature", 65, "/gpu-amd/0/temperature/0"),
                    sensor("GPU Package", "Power", 120, "/gpu-amd/0/power/3"),
                    sensor("GPU Core", "Power", 80, "/gpu-amd/0/power/0"),
                    sensor("GPU Core", "Load", 55, "/gpu-amd/0/load/0")]
        result = hardware.librehardware_metrics(readings)
        self.assertEqual(result["gpuTemp"], 65)
        self.assertEqual(result["gpuPowerWatts"], 120)
        self.assertEqual(result["gpuUsage"], 55)
        self.assertIsNone(hardware.librehardware_metrics(readings[:2])["gpuTemp"])

    def test_two_gpus_never_merge_readings(self):
        readings = [sensor("GPU Core", "Temperature", 65, "/gpu-nvidia/0/temperature/0"),
                    sensor("GPU Package", "Power", 120, "/gpu-amd/0/power/3")]
        result = hardware.librehardware_metrics(readings)
        self.assertEqual(result["gpuTemp"], 65)
        self.assertIsNone(result["gpuPowerWatts"])

    def test_current_http_raw_celsius_explicit_memory_units_gpu_name(self):
        document = tree([leaf("GPU Core", "Temperature", "149 °F", "/gpu-amd/0/temperature/0", RawValue=65),
                         leaf("GPU Memory Used", "Data", "4.0 GB", "/gpu-amd/0/data/0", RawValue=4 * 1024 ** 3),
                         leaf("GPU Memory Total", "Data", "8192 MB", "/gpu-amd/0/data/2", RawValue=8 * 1024 ** 3)],
                        "/gpu-amd/0", "AMD Example GPU")
        result = hardware.librehardware_metrics(hardware.librehardware_http_sensors(document))
        self.assertEqual(result["gpuTemp"], 65)
        self.assertEqual(result["vramUsedGB"], 4)
        self.assertEqual(result["vramTotalGB"], 8)
        self.assertEqual(result["gpuSensorName"], "AMD Example GPU")

    def test_old_http_decimal_comma_fahrenheit_no_hardware_id(self):
        document = {"Text": "PC", "Children": [{"Text": "CPU", "Children": [
            leaf("CPU Package", "Temperature", "149,0 °F", "/intelcpu/0/temperature/0"),
            leaf("CPU Package", "Power", "40,5 W", "/intelcpu/0/power/0"),
            leaf("CPU Core #1", "Clock", "4,1 GHz", "/intelcpu/0/clock/1")]}]}
        result = hardware.librehardware_metrics(hardware.librehardware_http_sensors(document))
        self.assertAlmostEqual(result["cpuTemp"], 65)
        self.assertEqual(result["cpuPowerWatts"], 40.5)
        self.assertEqual(result["cpuClockMHz"], 4100)

    def test_null_raw_value_never_resurrects_formatted_value(self):
        document = tree([leaf("CPU Package", "Temperature", "65 °C", "/intelcpu/0/temperature/0", RawValue=None)])
        result = hardware.librehardware_metrics(hardware.librehardware_http_sensors(document))
        self.assertIsNone(result["cpuTemp"])

    def test_memory_never_guesses_raw_units(self):
        document = tree([leaf("GPU Memory Used", "Data", "", "/gpu-amd/0/data/0", RawValue=8192)], "/gpu-amd/0")
        result = hardware.librehardware_metrics(hardware.librehardware_http_sensors(document))
        self.assertIsNone(result["vramUsedGB"])

    def test_invalid_nonfinite_readings_stay_unavailable(self):
        readings = [sensor("CPU Package", "Temperature", "NaN", "/amdcpu/0/temperature/0"),
                    sensor("GPU Core", "Temperature", -1, "/gpu-amd/0/temperature/0"),
                    sensor("GPU Core", "Load", 101, "/gpu-amd/0/load/0")]
        self.assertTrue(all(v is None for v in hardware.librehardware_metrics(readings).values()))


class SensorSourceTests(unittest.TestCase):
    def setUp(self):
        self.windows = patch.object(hardware.os, "name", "nt")
        self.windows.start()
        self.addCleanup(self.windows.stop)
        # The clock label reads platform.system() too; Linux would report a live clock.
        self.system = patch.object(hardware.platform, "system", return_value="Windows")
        self.system.start()
        self.addCleanup(self.system.stop)
        self.clock = patch.object(hardware.psutil, "cpu_freq", return_value=None)
        self.clock.start()
        self.addCleanup(self.clock.stop)

    def test_http_success_skips_powershell(self):
        with patch.object(hardware, "query_librehardware_http", return_value=[
                 sensor("CPU Package", "Temperature", 68, "/intelcpu/0/temperature/0")]), \
             patch.object(hardware, "powershell_json") as query:
            result = hardware.sensor_metrics()
        query.assert_not_called()
        self.assertEqual(result["cpuTemp"], 68)
        self.assertEqual(result["sensorSource"], "LibreHardwareMonitor · HTTP")
        self.assertIn("connected", result["sensorStatus"])

    def test_http_failure_uses_legacy_wmi_single_object(self):
        with patch.object(hardware, "query_librehardware_http", side_effect=OSError), \
             patch.object(hardware, "powershell_json", return_value=sensor(
                 "CPU Package", "Temperature", 64, "/intelcpu/0/temperature/0")) as query:
            result = hardware.sensor_metrics()
        self.assertEqual(result["cpuTemp"], 64)
        self.assertIn("OpenHardwareMonitor", query.call_args.args[0])
        self.assertEqual(result["sensorSource"], "Hardware monitor · WMI")

    def test_missing_monitor_status_no_fake_temperature(self):
        with patch.object(hardware, "query_librehardware_http", side_effect=OSError), \
             patch.object(hardware, "powershell_json", return_value=[]), \
             patch.object(hardware.psutil, "cpu_freq", return_value=SimpleNamespace(current=3200)):
            result = hardware.sensor_metrics()
        self.assertIsNone(result["cpuTemp"])
        self.assertIsNone(result["sensorSource"])
        self.assertIn("Remote Web Server", result["sensorStatus"])
        self.assertIn("8085", result["sensorStatus"])
        self.assertEqual(result["cpuClockSource"], "System · nominal clock")

    def test_connected_gpu_only_monitor_status(self):
        with patch.object(hardware, "query_librehardware_http", return_value=[
                 sensor("GPU Core", "Temperature", 55, "/gpu-amd/0/temperature/0")]):
            result = hardware.sensor_metrics()
        self.assertIsNone(result["cpuTemp"])
        self.assertEqual(result["gpuTemp"], 55)
        self.assertIn("no CPU temperature", result["sensorStatus"])

    def test_local_http_only_and_proxy_bypassed(self):
        with patch.dict(hardware.os.environ, {"ORBIT_LHM_URL": "http://127.0.0.1:8085"}), \
             patch.object(hardware.urllib.request, "build_opener") as make_opener:
            make_opener.return_value.open.return_value = io.BytesIO(json.dumps(tree([])).encode())
            self.assertEqual(hardware.query_librehardware_http(), [])
            request = make_opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, "http://127.0.0.1:8085/data.json")
            self.assertEqual(make_opener.call_args.args[0].proxies, {})
        for url in ("https://127.0.0.1:8085/data.json", "http://example.com/data.json",
                    "http://127.0.0.1.example.com/data.json", "file:///C:/sensors.json",
                    "http://user:pass@localhost/data.json"):
            with self.subTest(url=url), patch.dict(hardware.os.environ, {"ORBIT_LHM_URL": url}), \
                 self.assertRaises(ValueError):
                hardware.query_librehardware_http()

    def test_oversized_http_rejected(self):
        with patch.dict(hardware.os.environ, {}, clear=True), \
             patch.object(hardware.urllib.request, "build_opener") as make_opener:
            make_opener.return_value.open.return_value = io.BytesIO(b" " * 2_000_001)
            with self.assertRaises(ValueError):
                hardware.query_librehardware_http()


if __name__ == "__main__":
    unittest.main()
