"""Provider routing regressions, independent of Windows and real monitoring apps."""
import unittest
from unittest.mock import patch

import orbit_afterburner as afterburner
import orbit_hardware as hardware
import orbit_rtss as rtss


def sensors(**values):
    result = dict.fromkeys(hardware.SENSOR_FIELDS + hardware.GPU_SENSOR_FIELDS + ("sensorSource", "sensorStatus", "gpuSensorName"))
    result.update(values)
    return result


class SensorRoutingTests(unittest.TestCase):
    def read(self, primary, fallback):
        with patch.object(hardware.os, "name", "nt"), \
             patch.object(afterburner, "afterburner_metrics", return_value=primary), \
             patch.object(hardware, "_platform_sensor_metrics", return_value=fallback):
            return hardware.sensor_metrics()

    def test_afterburner_cpu_wins_with_actual_lhm_gap_filling(self):
        result = self.read(sensors(cpuTemp=55, sensorSource="MSI Afterburner"),
                           sensors(cpuTemp=65, cpuPowerWatts=40, cpuClockMHz=4200,
                                   cpuClockSource="LibreHardwareMonitor · core average", sensorSource="LibreHardwareMonitor · HTTP"))
        self.assertEqual(result["cpuTemp"], 55)
        self.assertEqual(result["cpuPowerWatts"], 40)
        self.assertEqual(result["cpuClockMHz"], 4200)
        self.assertEqual(result["cpuClockSource"], "LibreHardwareMonitor · core average")
        self.assertEqual(result["sensorSource"], "MSI Afterburner + LibreHardwareMonitor · HTTP")

    def test_gpu_readings_from_different_adapters_never_fill_each_other(self):
        result = self.read(sensors(cpuTemp=55, gpuTemp=60, gpuSensorName="First GPU", sensorSource="MSI Afterburner"),
                           sensors(gpuTemp=65, gpuPowerWatts=180, vramTotalGB=12, gpuSensorName="Other GPU", sensorSource="LibreHardwareMonitor · HTTP"))
        self.assertEqual(result["gpuTemp"], 60)
        self.assertEqual(result["gpuSensorName"], "First GPU")
        self.assertEqual(result["gpuSensorSource"], "MSI Afterburner")
        self.assertIsNone(result["gpuPowerWatts"])
        self.assertIsNone(result["vramTotalGB"])

    def test_fallback_gpu_retains_its_provider_when_cpu_is_afterburner(self):
        result = self.read(sensors(cpuTemp=55, sensorSource="MSI Afterburner"),
                           sensors(gpuTemp=65, gpuSensorName="AMD GPU", sensorSource="LibreHardwareMonitor · HTTP"))
        self.assertEqual(result["sensorSource"], "MSI Afterburner")
        self.assertEqual(result["gpuSensorSource"], "LibreHardwareMonitor · HTTP")
        self.assertEqual(result["gpuTemp"], 65)

    def test_absent_afterburner_preserves_legacy_monitor(self):
        result = self.read(sensors(), sensors(cpuTemp=55, sensorSource="Hardware monitor · WMI"))
        self.assertEqual(result["cpuTemp"], 55)
        self.assertEqual(result["sensorSource"], "Hardware monitor · WMI")

    def test_legacy_wmi_can_fill_power_even_when_afterburner_has_temperature(self):
        primary = sensors(cpuTemp=55, sensorSource="MSI Afterburner")
        with patch.object(hardware.os, "name", "nt"), \
             patch.object(afterburner, "afterburner_metrics", return_value=primary), \
             patch.object(hardware, "query_librehardware_http", side_effect=OSError), \
             patch.object(hardware.psutil, "cpu_freq", return_value=None), \
             patch.object(hardware, "powershell_json", return_value=[
                 {"Name": "CPU Package", "SensorType": "Power", "Value": 80,
                  "Identifier": "/intelcpu/0/power/0"}]) as query:
            result = hardware.sensor_metrics()
        query.assert_called_once()
        self.assertEqual(result["cpuTemp"], 55)
        self.assertEqual(result["cpuPowerWatts"], 80)
        self.assertIn("MSI Afterburner", result["sensorSource"])
        self.assertIn("Hardware monitor · WMI", result["sensorSource"])

    def test_empty_monitor_has_actionable_setup_without_fake_temperatures(self):
        result = self.read(sensors(), sensors())
        self.assertIsNone(result["cpuTemp"])
        self.assertIn("MSI Afterburner", result["sensorStatus"])
        self.assertIn("Remote Web Server", result["sensorStatus"])


class FPSRoutingTests(unittest.TestCase):
    game = {"pid": 42, "process": "example.exe"}

    def test_rtss_wins_and_does_not_read_csv(self):
        result = {"fps": 144, "fpsSource": "RTSS · game FPS", "fpsUnavailableReason": None}
        with patch.object(rtss, "read_rtss", return_value=result), patch.object(hardware, "read_presentmon") as csv, \
             patch.dict(hardware.os.environ, {"ORBIT_PRESENTMON_CSV": "example.csv"}, clear=True):
            self.assertEqual(hardware.read_fps(self.game), result)
        csv.assert_not_called()

    def test_configured_presentmon_remains_fallback(self):
        captured = {"fps": 120, "fpsSource": "PresentMon · application FPS"}
        with patch.object(rtss, "read_rtss", return_value={"fps": None}), \
             patch.object(hardware, "read_presentmon", return_value=captured) as csv, \
             patch.dict(hardware.os.environ, {"ORBIT_PRESENTMON_CSV": "example.csv"}, clear=True):
            self.assertEqual(hardware.read_fps(self.game), captured)
        csv.assert_called_once_with("example.csv", self.game)

    def test_unconfigured_csv_preserves_rtss_setup_reason(self):
        result = {"fps": None, "fpsSource": None, "fpsUnavailableReason": "Start RTSS"}
        with patch.object(rtss, "read_rtss", return_value=result), patch.object(hardware, "read_presentmon") as csv, \
             patch.dict(hardware.os.environ, {}, clear=True):
            self.assertEqual(hardware.read_fps(self.game), result)
        csv.assert_not_called()

    def test_both_failure_reasons_are_visible_with_legacy_csv_alias(self):
        with patch.object(rtss, "read_rtss", return_value={"fps": None, "fpsUnavailableReason": "Start RTSS"}), \
             patch.object(hardware, "read_presentmon", return_value={"fps": None, "fpsUnavailableReason": "Capture stopped"}) as csv, \
             patch.dict(hardware.os.environ, {"ORBIT_PRESENTATION_CSV": "example.csv"}, clear=True):
            result = hardware.read_fps(self.game)
        self.assertIsNone(result["fps"])
        self.assertIn("RTSS", result["fpsUnavailableReason"])
        self.assertIn("Capture stopped", result["fpsUnavailableReason"])
        csv.assert_called_once_with("example.csv", self.game)


if __name__ == "__main__":
    unittest.main()
