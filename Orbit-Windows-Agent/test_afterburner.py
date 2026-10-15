"""Synthetic fixtures follow MSI's MAHM v2 SDK, without shipping vendor files."""
import struct
import unittest
from unittest.mock import patch

import orbit_afterburner as afterburner

NOW = 1_800_000_000
GLOBAL = 0xFFFFFFFF


def text(value):
    if isinstance(value, str):
        value = value.encode('cp1252')
    return value[:259].ljust(260, b'\0')


def entry(source, value, units, name='custom name', gpu=GLOBAL, localized='user-edited display label'):
    return (text(name) + text(units) + text(localized) + text('untrusted units') + text('%.1f') +
            struct.pack('<fffIII', value, 0, 100, 0, gpu, source))


def gpu(name='Example GPU', memory_kib=8 * 1024 ** 2):
    return text('VEN_1234&DEV_1234') + text('Chip family') + text(name) + text('driver') + text('BIOS') + struct.pack('<I', memory_kib)


def snapshot(entries=(), gpus=(), updated=NOW, version=0x20000, header_extra=b'', entry_extra=b'', gpu_extra=b''):
    return (struct.pack('<8I', 0x4D41484D, version, 32 + len(header_extra), len(entries), 1324 + len(entry_extra),
                        updated, len(gpus), 1304 + len(gpu_extra)) + header_extra +
            b''.join(value + entry_extra for value in entries) + b''.join(value + gpu_extra for value in gpus))


def read(entries=(), gpus=(), **kwargs):
    return afterburner.parse_afterburner(snapshot(entries, gpus, **kwargs), now=NOW)


class AfterburnerLayoutTests(unittest.TestCase):
    def test_sdk_v2_header_and_gpu_descriptor_offsets(self):
        result = read([entry(0, 63, '°C', gpu=0)], [gpu('Real GPU name')])
        self.assertEqual(result['gpuTemp'], 63)
        self.assertEqual(result['vramTotalGB'], 8)
        self.assertEqual(result['gpuSensorName'], 'Real GPU name')
        self.assertEqual(result['gpuSensorSource'], 'MSI Afterburner')
        self.assertEqual(result['sensorSource'], 'MSI Afterburner')

    def test_advertised_larger_strides_and_minor_versions(self):
        result = read([entry(0x80, 70, '°C', 'CPU temperature'), entry(0, 60, '°C', gpu=0)], [gpu('GPU')],
                      version=0x20001, header_extra=b'next', entry_extra=b'next', gpu_extra=b'next')
        self.assertEqual(result['cpuTemp'], 70)
        self.assertEqual(result['gpuTemp'], 60)
        self.assertEqual(result['gpuSensorName'], 'GPU')

    def test_bad_signatures_versions_truncation_and_overflow_are_rejected(self):
        valid = snapshot([entry(0x80, 70, '°C')])
        bad = [b'', valid[:31], valid[:-1]]
        for offset, value in [(0, 0), (0, 0xDEAD), (4, 0x10000), (4, 0x30000), (8, 28),
                              (12, 5000), (16, 1320), (16, 0xFFFFFFFC), (24, 65)]:
            changed = bytearray(valid)
            struct.pack_into('<I', changed, offset, value)
            bad.append(changed)
        for blob in bad:
            with self.subTest(length=len(blob)), self.assertRaises(ValueError):
                afterburner.parse_afterburner(blob, now=NOW)

    def test_truncated_gpu_array_rejected(self):
        with self.assertRaises(ValueError):
            afterburner.parse_afterburner(snapshot([], [gpu()])[:-1], now=NOW)

    def test_oversized_snapshot_rejected(self):
        with self.assertRaises(ValueError):
            afterburner.parse_afterburner(b'\0' * (8 * 1024 ** 2 + 1), now=NOW)

    def test_old_and_future_polling_time_rejected(self):
        for updated in (0, NOW - 16, NOW + 6):
            with self.subTest(updated=updated), self.assertRaises(ValueError):
                read([entry(0x80, 70, '°C')], updated=updated)
        self.assertEqual(read([entry(0x80, 70, '°C')], updated=NOW - 15)['cpuTemp'], 70)


class AfterburnerSensorTests(unittest.TestCase):
    def test_package_temperature_preferred_over_hotter_cores(self):
        result = read([entry(0x80, 65, '°C', 'CPU temperature'), entry(0x80, 80, '°C', 'CPU1 temperature')])
        self.assertEqual(result['cpuTemp'], 65)

    def test_core_only_temperature_is_measured_hottest_core(self):
        result = read([entry(0x80, 55, '°C', 'CPU1 temperature'), entry(0x80, 75, '°C', 'CPU2 temperature')])
        self.assertEqual(result['cpuTemp'], 75)

    def test_cpu_power_uses_package_watts_without_summing_cores(self):
        result = read([entry(0x100, 30, 'W', 'CPU1 power'), entry(0x100, 80, 'W', 'CPU power'),
                       entry(0x100, 40, 'W', 'CPU2 power'), entry(0x100, 95, '%', 'CPU package power')])
        self.assertEqual(result['cpuPowerWatts'], 80)
        self.assertIsNone(read([entry(0x100, 30, 'W', 'CPU1 power')])['cpuPowerWatts'])

    def test_clock_units_and_aggregate_preference(self):
        core = [entry(0xA0, 4000, 'MHz', 'CPU1 clock'), entry(0xA0, 5, 'GHz', 'CPU2 clock')]
        self.assertEqual(read(core)['cpuClockMHz'], 4500)
        self.assertIn('core average', read(core)['cpuClockSource'])
        aggregate = read(core + [entry(0xA0, 4200, 'MHz', 'CPU clock')])
        self.assertEqual(aggregate['cpuClockMHz'], 4200)

    def test_units_source_ids_and_localized_overrides_are_not_guessed(self):
        result = read([entry(0xF1, 90, '°C', 'CPU temperature'), entry(0x80, 80, '%', 'CPU temperature'),
                       entry(0xF2, 1000, 'RPM', 'CPU fan'), entry(0x11, 900, 'RPM', 'CPU fan', gpu=0),
                       entry(0xFF, 30, '°C', 'Coolant temperature'),
                       entry(0x80, 69, '°C', 'CPU temperature', localized='GPU temperature')], [gpu()])
        self.assertEqual(result['cpuTemp'], 69)
        self.assertIsNone(result['cpuFanRPM'])
        self.assertIsNone(result['liquidTemp'])
        self.assertIsNone(result['gpuFanPercent'])

    def test_gpu_absolute_watts_never_uses_relative_power_percent(self):
        result = read([entry(0x60, 90, '%', 'Power', gpu=0), entry(0x61, 150, 'W', 'Power', gpu=0)], [gpu()])
        self.assertEqual(result['gpuPowerWatts'], 150)
        for source, units in ((0x60, '%'), (0x60, 'W'), (0x61, '%')):
            with self.subTest(source=source, units=units):
                self.assertIsNone(read([entry(source, 90, units, gpu=0)], [gpu()])['gpuPowerWatts'])

    def test_gpu_metrics_stay_on_one_adapter(self):
        result = read([entry(0, 60, '°C', gpu=0), entry(0, 70, '°C', gpu=1), entry(0x61, 150, 'W', gpu=1)],
                      [gpu('First GPU'), gpu('Second GPU')])
        self.assertEqual(result['gpuTemp'], 60)
        self.assertIsNone(result['gpuPowerWatts'])
        self.assertEqual(result['gpuSensorName'], 'First GPU')

    def test_invalid_units_on_first_gpu_do_not_hide_second_adapter(self):
        result = read([entry(0, 60, '%', gpu=0), entry(0, 70, '°C', gpu=1)],
                      [gpu('First GPU'), gpu('Second GPU')])
        self.assertEqual(result['gpuTemp'], 70)
        self.assertEqual(result['gpuSensorName'], 'Second GPU')

    def test_used_vram_units_and_descriptor_kib_are_validated(self):
        result = read([entry(0x31, 4096, 'MB', gpu=0), entry(0x35, 999, 'MB', gpu=0)], [gpu()])
        self.assertEqual(result['vramUsedGB'], 4)
        self.assertEqual(result['vramTotalGB'], 8)
        self.assertIsNone(read([entry(0x31, 99, '%', gpu=0)], [gpu()])['vramUsedGB'])
        self.assertIsNone(read([entry(0x31, 99999, 'MB', gpu=0)], [gpu()])['vramUsedGB'])

    def test_load_and_fan_zero_percent_preserved_and_above_100_rejected(self):
        result = read([entry(0x30, 0, '%', gpu=0), entry(0x10, 0, '%', gpu=0)], [gpu()])
        self.assertEqual(result['gpuUsage'], 0)
        self.assertEqual(result['gpuFanPercent'], 0)
        self.assertIsNone(read([entry(0x30, 101, '%', gpu=0)], [gpu()])['gpuUsage'])

    def test_nonfinite_and_flt_max_unavailable_sentinel_are_ignored(self):
        for value in (float('nan'), float('inf'), -1, float.fromhex('0x1.fffffep+127')):
            with self.subTest(value=value):
                result = read([entry(0x80, value, '°C')])
                self.assertIsNone(result['cpuTemp'])

    def test_fahrenheit_explicitly_converted(self):
        self.assertAlmostEqual(read([entry(0x80, 149, '°F')])['cpuTemp'], 65)

    def test_empty_or_cpu_only_mapping_does_not_invent_gpu(self):
        result = read([entry(0x80, 60, '°C')], [gpu()])
        self.assertIsNone(result['gpuTemp'])
        self.assertIsNone(result['vramTotalGB'])
        self.assertIsNone(result['gpuSensorSource'])
        self.assertIsNone(read()['cpuTemp'])


class AfterburnerLiveTests(unittest.TestCase):
    def test_windows_reads_only_existing_mahm_mapping(self):
        with patch.object(afterburner.os, 'name', 'nt'), \
             patch.object(afterburner, 'read_mapping', return_value=snapshot([entry(0x80, 66, '°C')])) as mapping:
            result = afterburner.afterburner_metrics(now=NOW)
        self.assertEqual(result['cpuTemp'], 66)
        mapping.assert_called_once_with('MAHMSharedMemory', max_bytes=8 * 1024 ** 2)

    def test_mapping_failure_or_stale_snapshot_has_no_old_values(self):
        with patch.object(afterburner.os, 'name', 'nt'), \
             patch.object(afterburner, 'read_mapping', side_effect=OSError('unavailable')):
            result = afterburner.afterburner_metrics(now=NOW)
        self.assertIsNone(result['sensorSource'])
        self.assertIsNone(result['cpuTemp'])
        self.assertIn('Monitoring', result['sensorStatus'])
        with patch.object(afterburner.os, 'name', 'nt'), \
             patch.object(afterburner, 'read_mapping', return_value=snapshot([entry(0x80, 66, '°C')], updated=NOW - 20)):
            result = afterburner.afterburner_metrics(now=NOW)
        self.assertIsNone(result['cpuTemp'])
        self.assertIn('stale', result['sensorStatus'])

    def test_non_windows_never_opens_mapping(self):
        with patch.object(afterburner.os, 'name', 'posix'), patch.object(afterburner, 'read_mapping') as mapping:
            result = afterburner.afterburner_metrics(now=NOW)
        mapping.assert_not_called()
        self.assertIsNone(result['sensorSource'])


if __name__ == '__main__':
    unittest.main()
