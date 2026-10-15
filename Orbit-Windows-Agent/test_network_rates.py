"""Regression tests for counter continuity and network interface selection."""
import os
import socket
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import orbit_hardware as hardware


def nic(sent=0, received=0):
    return SimpleNamespace(bytes_sent=sent, bytes_recv=received)


class NetworkContinuityTests(unittest.TestCase):
    def test_new_adapter_does_not_discard_stable_adapter_or_count_its_lifetime_bytes(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic(0, 0)}, now=10)
        result = rates.sample({}, {"Ethernet": nic(2_000_000, 5_000_000),
                                   "VPN": nic(10**12, 10**12)}, now=11)
        self.assertEqual(result["networkUploadMBps"], 2)
        self.assertEqual(result["networkDownloadMBps"], 5)

    def test_removing_adapter_keeps_stable_adapter_working(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic(0, 0), "VPN": nic(10**12, 10**12)}, now=10)
        result = rates.sample({}, {"Ethernet": nic(1_000_000, 3_000_000)}, now=11)
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 3)

    def test_one_reset_does_not_hide_other_adapter_and_recovers_next_interval(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic(), "Wi-Fi": nic(10**12, 10**12)}, now=10)
        result = rates.sample({}, {"Ethernet": nic(1_000_000, 3_000_000), "Wi-Fi": nic()}, now=11)
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 3)
        result = rates.sample({}, {"Ethernet": nic(2_000_000, 6_000_000),
                                   "Wi-Fi": nic(4_000_000, 5_000_000)}, now=12)
        self.assertEqual(result["networkUploadMBps"], 5)
        self.assertEqual(result["networkDownloadMBps"], 8)

    def test_one_missing_counter_keeps_other_direction_and_other_adapter(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic(), "Wi-Fi": nic()}, now=1)
        result = rates.sample({}, {"Ethernet": nic(1_000_000, 3_000_000),
                                   "Wi-Fi": nic(None, 2_000_000)}, now=2)
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 5)

    def test_small_rates_keep_byte_precision_in_decimal_mb(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic()}, now=1)
        result = rates.sample({}, {"Ethernet": nic(50, 500)}, now=3.5)
        self.assertAlmostEqual(result["networkUploadMBps"], .00002)
        self.assertAlmostEqual(result["networkDownloadMBps"], .0002)

    def test_large_lifetime_counters_keep_small_deltas(self):
        rates = hardware.IOCounterRates()
        counter = 2**60
        rates.sample({}, {"Ethernet": nic(counter, counter)}, now=1)
        result = rates.sample({}, {"Ethernet": nic(counter + 10, counter + 100)}, now=2)
        self.assertAlmostEqual(result["networkUploadMBps"], .00001)
        self.assertAlmostEqual(result["networkDownloadMBps"], .0001)

    def test_non_increasing_time_does_not_replace_last_valid_baseline(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic()}, now=10)
        duplicate = rates.sample({}, {"Ethernet": nic(1_000_000, 1_000_000)}, now=10)
        backwards = rates.sample({}, {"Ethernet": nic(2_000_000, 2_000_000)}, now=9)
        self.assertIsNone(duplicate["networkUploadMBps"])
        self.assertIsNone(backwards["networkUploadMBps"])
        result = rates.sample({}, {"Ethernet": nic(3_000_000, 3_000_000)}, now=13)
        self.assertEqual(result["networkUploadMBps"], 1)

    def test_invalid_time_does_not_poison_later_measurements(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic()}, now=1)
        result = rates.sample({}, {"Ethernet": nic(1_000_000, 1_000_000)}, now=float("nan"))
        self.assertIsNone(result["networkUploadMBps"])
        result = rates.sample({}, {"Ethernet": nic(2_000_000, 2_000_000)}, now=3)
        self.assertEqual(result["networkUploadMBps"], 1)

    def test_reappearing_adapter_primes_again(self):
        rates = hardware.IOCounterRates()
        rates.sample({}, {"Ethernet": nic(10**12, 10**12)}, now=1)
        rates.sample({}, {}, now=2)
        result = rates.sample({}, {"Ethernet": nic(10**12 + 1, 10**12 + 1)}, now=3)
        self.assertIsNone(result["networkUploadMBps"])
        result = rates.sample({}, {"Ethernet": nic(10**12 + 2, 10**12 + 2)}, now=4)
        self.assertAlmostEqual(result["networkUploadMBps"], .000001)

    def test_disk_hotplug_does_not_invalidate_other_disk(self):
        rates = hardware.IOCounterRates()
        rates.sample({"disk0": SimpleNamespace(read_bytes=0, write_bytes=0)}, {}, now=1)
        result = rates.sample({"disk0": SimpleNamespace(read_bytes=1_000_000, write_bytes=2_000_000),
                               "disk1": SimpleNamespace(read_bytes=10**12, write_bytes=10**12)}, {}, now=2)
        self.assertEqual(result["diskReadMBps"], 1)
        self.assertEqual(result["diskWriteMBps"], 2)


class NetworkSelectionTests(unittest.TestCase):
    def measure(self, names, *, stats=None, addresses=None, configured="", metadata_error=False):
        rates = hardware.IOCounterRates()
        baseline = {name: nic() for name in names}
        current = {name: nic(1_000_000, 2_000_000) for name in names}
        with patch.dict(os.environ, {"ORBIT_NETWORK_INTERFACE": configured}), \
             patch.object(hardware.psutil, "disk_io_counters", return_value={}), \
             patch.object(hardware.psutil, "net_io_counters", side_effect=[baseline, current]), \
             patch.object(hardware.psutil, "net_if_stats", return_value=stats or {},
                          side_effect=OSError if metadata_error else None), \
             patch.object(hardware.psutil, "net_if_addrs", return_value=addresses or {},
                          side_effect=OSError if metadata_error else None), \
             patch.object(hardware.time, "monotonic", side_effect=[1, 2]):
            hardware.io_metrics(rates)
            return hardware.io_metrics(rates)

    def test_loopback_and_obvious_virtual_adapters_are_not_double_counted(self):
        result = self.measure(["Ethernet", "lo", "Loopback Pseudo-Interface 1", "vEthernet (WSL)",
                               "VMware Network Adapter VMnet8", "utun1", "Tailscale"])
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkDownloadMBps"], 2)
        self.assertEqual(result["networkInterface"], "Ethernet")

    def test_stats_identify_down_interfaces_and_loopback_flags(self):
        result = self.measure(["Ethernet", "Wi-Fi", "Custom adapter"], stats={
            "Ethernet": SimpleNamespace(isup=True, flags="up,broadcast,running"),
            "Wi-Fi": SimpleNamespace(isup=False),
            "Custom adapter": SimpleNamespace(isup=True, flags="up,loopback,running"),
        })
        self.assertEqual(result["networkUploadMBps"], 1)

    def test_loopback_addresses_identify_renamed_loopback_adapter(self):
        result = self.measure(["Ethernet", "Custom adapter"], addresses={
            "Custom adapter": [SimpleNamespace(family=socket.AF_INET, address="127.0.0.1"),
                               SimpleNamespace(family=socket.AF_INET6, address="::1")],
            "Ethernet": [SimpleNamespace(family=socket.AF_INET, address="192.168.1.10")],
        })
        self.assertEqual(result["networkUploadMBps"], 1)

    def test_multiple_real_interfaces_are_summed(self):
        result = self.measure(["Ethernet", "Wi-Fi"])
        self.assertEqual(result["networkUploadMBps"], 2)
        self.assertEqual(result["networkDownloadMBps"], 4)

    def test_explicit_interface_is_case_insensitive_and_can_select_virtual(self):
        result = self.measure(["Ethernet", "Tailscale"], configured=" tailscale ")
        self.assertEqual(result["networkUploadMBps"], 1)
        self.assertEqual(result["networkInterface"], "Tailscale")

    def test_missing_explicit_interface_does_not_silently_measure_another(self):
        result = self.measure(["Ethernet"], configured="Wi-Fi")
        self.assertIsNone(result["networkUploadMBps"])
        self.assertIsNone(result["networkDownloadMBps"])
        self.assertIsNone(result["networkInterface"])

    def test_optional_metadata_failure_does_not_discard_available_counters(self):
        result = self.measure(["Ethernet", "lo"], metadata_error=True)
        self.assertEqual(result["networkUploadMBps"], 1)


if __name__ == "__main__":
    unittest.main()
