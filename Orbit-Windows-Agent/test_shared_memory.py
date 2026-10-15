"""Windows mapping lifecycle tests using an in-process buffer, never a PC app."""
import ctypes
import unittest
from unittest.mock import Mock, patch

import orbit_shared_memory as memory


class SharedMemoryTests(unittest.TestCase):
    def api(self, data=b"monitoring data"):
        buffer = ctypes.create_string_buffer(data)
        address = ctypes.addressof(buffer)
        api = Mock()
        api.OpenFileMappingW.return_value = 42
        api.MapViewOfFile.return_value = address
        def query(view, region, length):
            region._obj.BaseAddress = address
            region._obj.AllocationBase = address
            region._obj.RegionSize = len(data)
            region._obj.State = 0x1000
            region._obj.Protect = 0x02
            return length
        api.VirtualQuery.side_effect = query
        return api, buffer

    def test_existing_mapping_is_read_only_bounded_and_closed(self):
        api, buffer = self.api()
        with patch.object(memory.os, "name", "nt"), patch.object(memory, "_windows_api", return_value=api):
            self.assertEqual(memory.read_mapping("MAHMSharedMemory", 7), b"monitor")
        api.OpenFileMappingW.assert_called_once_with(memory.FILE_MAP_READ, False, "MAHMSharedMemory")
        api.MapViewOfFile.assert_called_once_with(42, memory.FILE_MAP_READ, 0, 0, 0)
        api.UnmapViewOfFile.assert_called_once_with(ctypes.addressof(buffer))
        api.CloseHandle.assert_called_once_with(42)
        api.CreateFileMappingW.assert_not_called()

    def test_no_mapping_never_creates_one(self):
        api, _ = self.api()
        api.OpenFileMappingW.return_value = None
        with patch.object(memory.os, "name", "nt"), patch.object(memory, "_windows_api", return_value=api):
            with self.assertRaises(OSError): memory.read_mapping("RTSSSharedMemoryV2")
        api.MapViewOfFile.assert_not_called()
        api.CloseHandle.assert_not_called()
        api.CreateFileMappingW.assert_not_called()

    def test_failed_map_closes_handle(self):
        api, _ = self.api()
        api.MapViewOfFile.return_value = None
        with patch.object(memory.os, "name", "nt"), patch.object(memory, "_windows_api", return_value=api):
            with self.assertRaises(OSError): memory.read_mapping("example")
        api.CloseHandle.assert_called_once_with(42)
        api.UnmapViewOfFile.assert_not_called()

    def test_failed_query_unmaps_and_closes(self):
        api, buffer = self.api()
        api.VirtualQuery.side_effect = None
        api.VirtualQuery.return_value = 0
        with patch.object(memory.os, "name", "nt"), patch.object(memory, "_windows_api", return_value=api):
            with self.assertRaises(OSError): memory.read_mapping("example")
        api.UnmapViewOfFile.assert_called_once_with(ctypes.addressof(buffer))
        api.CloseHandle.assert_called_once_with(42)

    def test_unstable_snapshot_is_rejected_and_resources_closed(self):
        api, _ = self.api()
        with patch.object(memory.os, "name", "nt"), patch.object(memory, "_windows_api", return_value=api), \
             patch.object(memory.ctypes, "string_at", side_effect=[b"a", b"b", b"c", b"d"]):
            with self.assertRaises(OSError): memory.read_mapping("example")
        api.UnmapViewOfFile.assert_called_once()
        api.CloseHandle.assert_called_once_with(42)

    def test_invalid_limits_names_and_non_windows_are_rejected(self):
        for limit in (0, -1, 8 * 1024 * 1024 + 1, True, "100"):
            with self.assertRaises(ValueError): memory.read_mapping("example", limit)
        for name in ("", None, "bad\0name"):
            with self.assertRaises(ValueError): memory.read_mapping(name)
        with patch.object(memory.os, "name", "posix"):
            with self.assertRaises(OSError): memory.read_mapping("example")


if __name__ == "__main__":
    unittest.main()
