"""Bounded, read-only snapshots of existing Windows monitoring mappings.

OpenFileMapping never creates a segment when the monitoring app is absent. No
SDK binaries, injection, OSD commands or write access are needed by Orbit.
"""
import ctypes
import os


FILE_MAP_READ = 0x0004
MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024


class _MemoryBasicInformation(ctypes.Structure):
    # Native pointer alignment accounts for the x64 PartitionId/padding slot.
    # RegionSize is at offset 24 on x64 and 12 on x86, per the Win32 ABI.
    _fields_ = [("BaseAddress", ctypes.c_void_p),
                ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", ctypes.c_uint32),
                ("RegionSize", ctypes.c_size_t),
                ("State", ctypes.c_uint32),
                ("Protect", ctypes.c_uint32),
                ("Type", ctypes.c_uint32)]


def _windows_api():
    try:
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    except (AttributeError, OSError) as error:
        raise OSError("Windows shared monitoring APIs are unavailable") from error
    kernel.OpenFileMappingW.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_wchar_p]
    kernel.OpenFileMappingW.restype = ctypes.c_void_p
    kernel.MapViewOfFile.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                     ctypes.c_uint32, ctypes.c_size_t]
    kernel.MapViewOfFile.restype = ctypes.c_void_p
    kernel.VirtualQuery.argtypes = [ctypes.c_void_p, ctypes.POINTER(_MemoryBasicInformation), ctypes.c_size_t]
    kernel.VirtualQuery.restype = ctypes.c_size_t
    kernel.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
    kernel.UnmapViewOfFile.restype = ctypes.c_int
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    return kernel


def read_mapping(name, max_bytes=MAX_SNAPSHOT_BYTES):
    """Copy an existing named mapping; callers validate their SDK's header.

    Mapping zero bytes exposes the existing view. VirtualQuery bounds the copy
    to committed readable pages, with a further 8 MiB application limit. Two
    equal copies avoid publishing a snapshot while its producer is updating it.
    Handles and views are released on every path, including parser retries.
    """
    if not isinstance(name, str) or not name or "\0" in name:
        raise ValueError("A valid monitoring mapping name is required")
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or not 1 <= max_bytes <= MAX_SNAPSHOT_BYTES:
        raise ValueError("Monitoring snapshot limit must be between 1 byte and 8 MiB")
    if os.name != "nt":
        raise OSError("Windows shared monitoring data is unavailable on this system")
    kernel = _windows_api()
    handle = kernel.OpenFileMappingW(FILE_MAP_READ, False, name)
    if not handle:
        raise OSError("Monitoring shared memory is unavailable; start the monitoring app in the same Windows session")
    view = None
    try:
        view = kernel.MapViewOfFile(handle, FILE_MAP_READ, 0, 0, 0)
        if not view:
            raise OSError("Windows denied read access to monitoring shared memory")
        region = _MemoryBasicInformation()
        size = kernel.VirtualQuery(view, ctypes.byref(region), ctypes.sizeof(region))
        if size != ctypes.sizeof(region) or region.State != 0x1000 or region.Protect & (0x01 | 0x100):
            raise OSError("Monitoring memory is not a committed readable view")
        offset = int(view) - (region.BaseAddress or 0)
        count = min(max_bytes, region.RegionSize - offset)
        if offset < 0 or count <= 0 or region.AllocationBase != int(view):
            raise OSError("Monitoring memory has an invalid view boundary")
        previous = ctypes.string_at(view, count)
        for _ in range(3):
            current = ctypes.string_at(view, count)
            if current == previous:
                return current
            previous = current
        raise OSError("Monitoring data changed during reading; waiting for a complete sample")
    finally:
        if view:
            kernel.UnmapViewOfFile(view)
        kernel.CloseHandle(handle)
