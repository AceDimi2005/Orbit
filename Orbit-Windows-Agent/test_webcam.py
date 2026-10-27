"""iPhone webcam (orbit_webcam): pinned DLLs, setup with one UAC prompt, the camera worker,
the /ws/camera protocol and frame conversion. Every Windows API, the registry, the network and
the Softcam DLL are fakes; nothing is registered, elevated or downloaded."""
import concurrent.futures
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, Mock, patch
import urllib.error

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.testclient import TestClient
from PIL import Image
from starlette.websockets import WebSocketDisconnect

import orbit_updater
import orbit_webcam as webcam

TOKEN = "webcam-test-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
AGENT_DIR = Path(webcam.__file__).resolve().parent
WEBCAM_DIR = AGENT_DIR / "webcam"
GIVEN_PINS = {"softcam64.dll": "f62432a498c06b053eae3d437f445ff64e8b847be92b689e5ee01f0f2fdf911a",
              "softcam32.dll": "aa2e2d870a1d280d3f11382b0fdba5cb760a66830cc3d6353a03b3571f44c66d"}
RUNTIME_OK = (14, 44, 35211)
# The environment as it was before any test patched it. WindowsEnvironment points SystemRoot at a temporary
# folder, and a real powershell.exe started with that cannot load (error 8009001d), so tests that run the
# real PowerShell hand it this one.
REAL_ENVIRONMENT = dict(os.environ)


def wait_until(predicate, timeout=3.0, interval=0.01):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def make_jpeg(size, color=(200, 30, 10), mode="RGB", quality=95, painter=None, image_format="JPEG"):
    image = Image.new(mode, size, color)
    if painter is not None:
        painter(image)
    buffer = io.BytesIO()
    image.save(buffer, format=image_format, quality=quality)
    return buffer.getvalue()


class FakeKey:
    def __init__(self, view, path, values):
        self.view, self.path, self.values = view, path, values

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeRegistry:
    """HKLM only, with separate 64-bit and 32-bit views like Windows (KEY_WOW64_64KEY / 32KEY).
    Creating a key creates its parents, and EnumKey lists subkeys with their original names."""
    HKEY_LOCAL_MACHINE = 0x80000002
    KEY_READ = 0x20019

    def __init__(self):
        self.keys = {}    # (view, lower-case path) -> {lower-case value name: value}
        self.names = {}   # (view, lower-case path) -> the path as written
        self.opened = []

    def create(self, view, path):
        parts = path.split("\\")
        for index in range(1, len(parts) + 1):
            partial = "\\".join(parts[:index])
            self.keys.setdefault((view, partial.lower()), {})
            self.names.setdefault((view, partial.lower()), partial)
        return self.keys[(view, path.lower())]

    def set(self, view, path, name, value):
        self.create(view, path)[name.lower()] = value

    def delete_tree(self, view, path):
        prefix = path.lower()
        for key in [key for key in self.keys if key[0] == view and (key[1] == prefix or key[1].startswith(prefix + "\\"))]:
            del self.keys[key]
            self.names.pop(key, None)

    def OpenKey(self, root, path, reserved=0, access=0):
        assert root == self.HKEY_LOCAL_MACHINE
        assert access & self.KEY_READ == self.KEY_READ
        view = access & 0x300
        self.opened.append((view, path))
        values = self.keys.get((view, path.lower()))
        if values is None:
            raise FileNotFoundError(2, "The system cannot find the file specified")
        return FakeKey(view, path, values)

    def QueryValueEx(self, key, name):
        if name.lower() not in key.values:
            raise FileNotFoundError(2, "The system cannot find the file specified")
        return key.values[name.lower()], 1

    def EnumKey(self, key, index):
        prefix = key.path.lower() + "\\"
        children = sorted({self.names[candidate][len(prefix):].split("\\")[0]
                           for candidate in self.names if candidate[0] == key.view and candidate[1].startswith(prefix)})
        if index >= len(children):
            raise OSError(259, "No more data is available")
        return children[index]


class WindowsEnvironment(unittest.TestCase):
    """A pretend x64 Windows: temporary Program Files, SystemRoot and LocalAppData, a fake registry.
    `_is_windows` is off even on Windows (CI), so nothing touches the real Program Files."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.program_files = self.root / "Program Files"
        self.system_root = self.root / "Windows"
        self.local = self.root / "Local"
        for folder in (self.program_files, self.system_root, self.local):
            folder.mkdir()
        environment = {"ProgramW6432": str(self.program_files), "PROGRAMFILES": str(self.program_files),
                       "SystemRoot": str(self.system_root), "LOCALAPPDATA": str(self.local)}
        self.registry = FakeRegistry()
        for patcher in (patch.dict(os.environ, environment),
                        patch.object(webcam, "_is_windows", return_value=False),
                        patch.object(webcam, "_native_machine_from_windows", return_value="x64"),
                        patch.object(webcam, "process_bits", return_value=64),
                        patch.object(webcam, "winreg", self.registry)):
            patcher.start()
            self.addCleanup(patcher.stop)
        notify = patch.object(webcam.orbit_notify, "notify")
        self.notify = notify.start()
        self.addCleanup(notify.stop)
        webcam._HASH_CACHE.clear()

    def layout(self):
        return webcam.platform_layout()

    def folder(self):
        return webcam.install_directory()

    def set_runtime(self, x64=RUNTIME_OK, x86=RUNTIME_OK, view=webcam.KEY_WOW64_32KEY):
        for arch, version in (("x64", x64), ("x86", x86)):
            if version is None:
                continue
            path = webcam.VC_RUNTIME_KEY + "\\" + arch
            self.registry.set(view, path, "Installed", 1)
            self.registry.set(view, path, "Major", version[0])
            self.registry.set(view, path, "Minor", version[1])
            self.registry.set(view, path, "Bld", version[2])
            self.registry.set(view, path, "Version", "v%d.%d.%d.00" % version)

    def install_files(self, folder=None):
        folder = Path(folder) if folder is not None else self.folder()
        folder.mkdir(parents=True, exist_ok=True)
        for name in webcam.DLL_SHA256:
            shutil.copyfile(WEBCAM_DIR / name, folder / name)

    def register(self, paths=None, listed=True, instance=webcam.CAMERA_NAME, instance_clsid=webcam.CLSID):
        """What Softcam's DllRegisterServer writes: the CLSID's InprocServer32 and, through
        IFilterMapper2::RegisterFilter, Instance\\DirectShow Softcam with CLSID, FriendlyName and
        FilterData in the video input category."""
        folder = self.folder()
        for target in self.layout().targets:
            value = (paths or {}).get(target.name, str(folder / target.name))
            self.registry.set(target.view, webcam.INPROC_KEY, "", value)
            self.registry.set(target.view, webcam.INPROC_KEY, "ThreadingModel", "Both")
            if listed:
                key = webcam.INSTANCE_ROOT_KEY + "\\" + instance
                if instance_clsid is not None:
                    self.registry.set(target.view, key, "CLSID", instance_clsid)
                self.registry.set(target.view, key, "FriendlyName", webcam.CAMERA_NAME)
                self.registry.set(target.view, key, "FilterData", b"\x02\x00\x00\x00")

    def unregister(self):
        """What DllUnregisterServer removes in both views."""
        for target in self.layout().targets:
            self.registry.delete_tree(target.view, "SOFTWARE\\Classes\\CLSID\\" + webcam.CLSID)
            self.registry.delete_tree(target.view, webcam.CATEGORY_INSTANCE_KEY)


# Pinned files ----------------------------------------------------------------------------------

class PinnedFilesTests(unittest.TestCase):
    def test_pins_are_the_verified_build_and_match_the_committed_dlls(self):
        self.assertEqual(webcam.DLL_SHA256, GIVEN_PINS)
        for name, digest in GIVEN_PINS.items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((WEBCAM_DIR / name).read_bytes()).hexdigest(), digest)
                self.assertTrue(webcam.is_verified(WEBCAM_DIR / name, name, use_cache=False))

    def test_sha256sums_upstream_commit_and_licenses_travel_with_the_dlls(self):
        sums = {}
        for line in (WEBCAM_DIR / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
            digest, name = line.split(maxsplit=1)
            sums[name.strip()] = digest
        for name, digest in GIVEN_PINS.items():
            self.assertEqual(sums[name], digest)
        self.assertEqual((WEBCAM_DIR / "UPSTREAM_COMMIT").read_text(encoding="utf-8").strip(), webcam.SOFTCAM_COMMIT)
        # SHA256SUMS lists softcam's LICENSE under its artifact name; the copy here is renamed.
        self.assertEqual(hashlib.sha256((WEBCAM_DIR / "LICENSE-softcam.txt").read_bytes()).hexdigest(), sums["LICENSE"])
        self.assertEqual(hashlib.sha256((WEBCAM_DIR / "LICENSE-BaseClasses.txt").read_bytes()).hexdigest(),
                         sums["LICENSE-BaseClasses"])
        self.assertIn("Copyright (c) 2020 tshino", (WEBCAM_DIR / "LICENSE-softcam.txt").read_text(encoding="utf-8"))
        self.assertIn("Copyright (c) Microsoft Corporation",
                      (WEBCAM_DIR / "LICENSE-BaseClasses.txt").read_text(encoding="utf-8"))

    def test_third_party_notices_name_softcam_and_the_directshow_baseclasses(self):
        notices = (AGENT_DIR / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        for text in ("tshino/softcam", "Copyright (c) 2020 tshino", "DirectShow BaseClasses",
                     "Copyright (c) Microsoft Corporation", webcam.SOFTCAM_COMMIT):
            self.assertIn(text, notices)

    def test_a_changed_byte_is_never_verified(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "softcam64.dll"
            data = bytearray((WEBCAM_DIR / "softcam64.dll").read_bytes())
            data[1000] ^= 0xFF
            copy.write_bytes(bytes(data))
            self.assertFalse(webcam.is_verified(copy, "softcam64.dll", use_cache=False))
            self.assertFalse(webcam.is_verified(Path(folder) / "missing.dll", "softcam64.dll"))

    def test_the_install_folder_is_named_after_both_pins(self):
        expected = hashlib.sha256((f"softcam32.dll={GIVEN_PINS['softcam32.dll']}\n"
                                   f"softcam64.dll={GIVEN_PINS['softcam64.dll']}\n").encode()).hexdigest()[:16]
        self.assertEqual(webcam.INSTALL_ID, expected)
        with patch.object(webcam, "_is_windows", return_value=False), \
             patch.dict(os.environ, {"ProgramW6432": "/pf", "PROGRAMFILES": "/pf"}):
            self.assertEqual(webcam.install_directory(), Path("/pf") / "Orbit" / "Webcam" / expected)


# Which Windows ---------------------------------------------------------------------------------

class LayoutTests(WindowsEnvironment):
    def test_x64_windows_registers_both_dlls_with_the_matching_regsvr32_and_view(self):
        layout = self.layout()
        root = str(self.system_root)
        self.assertEqual([t.name for t in layout.targets], ["softcam64.dll", "softcam32.dll"])
        self.assertEqual(layout.targets[0].regsvr32, os.path.join(root, "System32", "regsvr32.exe"))
        self.assertEqual(layout.targets[1].regsvr32, os.path.join(root, "SysWOW64", "regsvr32.exe"))
        self.assertEqual([t.view for t in layout.targets], [webcam.KEY_WOW64_64KEY, webcam.KEY_WOW64_32KEY])
        self.assertEqual(layout.powershell, os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
        self.assertEqual(layout.sender_dll, "softcam64.dll")

    def test_a_32_bit_agent_on_x64_reaches_the_native_powershell_through_sysnative(self):
        with patch.object(webcam, "process_bits", return_value=32):
            layout = self.layout()
        self.assertIn("Sysnative", layout.powershell)
        self.assertEqual(layout.sender_dll, "softcam32.dll")
        self.assertIn("Sysnative", layout.runtime_dirs["x64"])
        # The elevated PowerShell is 64-bit, so its own paths keep the normal names.
        self.assertIn("System32", layout.targets[0].regsvr32)

    def test_32_bit_windows_only_has_the_32_bit_dll(self):
        with patch.object(webcam, "_native_machine_from_windows", return_value="x86"), \
             patch.object(webcam, "process_bits", return_value=32):
            layout = self.layout()
        self.assertEqual([(t.name, t.view) for t in layout.targets], [("softcam32.dll", 0)])
        self.assertIn("System32", layout.targets[0].regsvr32)

    def test_windows_on_arm_is_refused_in_plain_words(self):
        with patch.object(webcam, "_native_machine_from_windows", return_value="arm64"):
            with self.assertRaises(webcam.UnsupportedPC) as raised:
                self.layout()
            self.assertIn("Windows on ARM", str(raised.exception))
            with self.assertRaises(webcam.InstallError) as install:
                webcam.install_webcam(elevate=Mock(side_effect=AssertionError))
            self.assertEqual(install.exception.status, 409)

    def test_the_machine_falls_back_to_the_environment(self):
        with patch.object(webcam, "_native_machine_from_windows", return_value=None):
            for environment, expected in (({"PROCESSOR_ARCHITEW6432": "AMD64", "PROCESSOR_ARCHITECTURE": "x86"}, "x64"),
                                          ({"PROCESSOR_ARCHITECTURE": "ARM64"}, "arm64"),
                                          ({"PROCESSOR_ARCHITECTURE": "x86"}, "x86"), ({}, "x64")):
                with self.subTest(environment=environment), patch.dict(os.environ, environment):
                    for name in ("PROCESSOR_ARCHITEW6432", "PROCESSOR_ARCHITECTURE"):
                        if name not in environment:
                            os.environ.pop(name, None)
                    self.assertEqual(webcam.native_machine(), expected)


class NativeMachineTests(unittest.TestCase):
    def test_is_wow64_process2_types_and_result(self):
        kernel32 = MagicMock()

        def query(process, process_machine, native_machine):
            native_machine._obj.value = 0xAA64
            return 1
        kernel32.IsWow64Process2.side_effect = query
        with patch.object(webcam.ctypes, "WinDLL", create=True, return_value=kernel32):
            self.assertEqual(webcam._native_machine_from_windows(), "arm64")
        self.assertEqual(kernel32.IsWow64Process2.argtypes,
                         [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)])
        self.assertEqual(kernel32.IsWow64Process2.restype, ctypes.c_int)
        self.assertEqual(kernel32.GetCurrentProcess.restype, ctypes.c_void_p)

    def test_unknown_or_missing_api_gives_none(self):
        kernel32 = MagicMock()
        kernel32.IsWow64Process2.return_value = 0
        with patch.object(webcam.ctypes, "WinDLL", create=True, return_value=kernel32):
            self.assertIsNone(webcam._native_machine_from_windows())
        with patch.object(webcam.ctypes, "WinDLL", create=True, side_effect=AttributeError("no IsWow64Process2")):
            self.assertIsNone(webcam._native_machine_from_windows())


class WindowsFoldersTests(unittest.TestCase):
    """On Windows the folders the elevated step uses come from Windows itself, never from
    %SystemRoot%, %windir% or %ProgramFiles%, which a user can override for their own processes."""

    USER_OVERRIDES = {"SystemRoot": "C:\\Users\\Mallory\\FakeWindows", "windir": "C:\\Users\\Mallory\\FakeWindows",
                      "ProgramFiles": "C:\\Users\\Mallory\\FakeProgramFiles",
                      "ProgramW6432": "C:\\Users\\Mallory\\FakeProgramFiles"}

    def setUp(self):
        self.kernel32 = MagicMock()
        self.windows = "D:\\Windows"

        def get_windows_directory(buffer, size):
            buffer.value = self.windows
            return len(self.windows)
        self.kernel32.GetSystemWindowsDirectoryW.side_effect = get_windows_directory
        self.registry = FakeRegistry()
        for patcher in (patch.object(webcam, "_is_windows", return_value=True),
                        patch.object(webcam.ctypes, "WinDLL", create=True, return_value=self.kernel32),
                        patch.object(webcam, "_native_machine_from_windows", return_value="x64"),
                        patch.object(webcam, "process_bits", return_value=64),
                        patch.object(webcam, "winreg", self.registry),
                        patch.dict(os.environ, self.USER_OVERRIDES)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_the_windows_folder_comes_from_getsystemwindowsdirectoryw(self):
        self.assertEqual(webcam.system_root(), "D:\\Windows")
        function = self.kernel32.GetSystemWindowsDirectoryW
        self.assertEqual(function.argtypes, [ctypes.c_wchar_p, ctypes.c_uint])
        self.assertEqual(function.restype, ctypes.c_uint)
        layout = webcam.platform_layout()
        self.assertEqual(layout.powershell, os.path.join("D:\\Windows", "System32", "WindowsPowerShell", "v1.0",
                                                         "powershell.exe"))
        self.assertEqual(layout.targets[1].regsvr32, os.path.join("D:\\Windows", "SysWOW64", "regsvr32.exe"))
        self.assertNotIn("Mallory", repr(layout))

    def test_a_failed_call_falls_back_to_c_windows_not_the_environment(self):
        self.kernel32.GetSystemWindowsDirectoryW.side_effect = lambda buffer, size: 0
        self.assertEqual(webcam.system_root(), "C:\\Windows")
        with patch.object(webcam.ctypes, "WinDLL", create=True, side_effect=OSError("no kernel32")):
            self.assertEqual(webcam.system_root(), "C:\\Windows")

    def test_program_files_comes_from_the_64_bit_view_of_hklm(self):
        key = webcam.WINDOWS_CURRENT_VERSION_KEY
        self.registry.set(webcam.KEY_WOW64_64KEY, key, "ProgramFilesDir", "E:\\Apps\\Program Files")
        self.registry.set(webcam.KEY_WOW64_32KEY, key, "ProgramFilesDir", "E:\\Apps\\Program Files (x86)")
        expected = Path("E:\\Apps\\Program Files") / "Orbit" / "Webcam" / webcam.INSTALL_ID
        self.assertEqual(webcam.install_directory(), expected)
        with patch.object(webcam, "process_bits", return_value=32):  # a 32-bit agent too
            self.assertEqual(webcam.install_directory(), expected)

    def test_odd_or_missing_values_fall_back_to_program_files_on_the_windows_drive(self):
        key = webcam.WINDOWS_CURRENT_VERSION_KEY
        for value in (None, "%SystemDrive%\\Program Files", "Program Files", "E:\\", 7):
            with self.subTest(value=value):
                if value is not None:
                    self.registry.set(webcam.KEY_WOW64_64KEY, key, "ProgramFilesDir", value)
                self.assertEqual(webcam.program_files(), Path("D:\\Program Files"))

    def test_32_bit_windows_reads_its_only_view(self):
        self.registry.set(0, webcam.WINDOWS_CURRENT_VERSION_KEY, "ProgramFilesDir", "C:\\Program Files")
        with patch.object(webcam, "_native_machine_from_windows", return_value="x86"):
            self.assertEqual(webcam.program_files(), Path("C:\\Program Files"))


class RegistrationTests(WindowsEnvironment):
    """The camera counts as listed only when the video input category has a subkey whose CLSID value
    is Softcam's, like the one Softcam's DllRegisterServer creates."""

    def test_the_instance_key_is_the_one_softcams_registerfilter_call_creates(self):
        # RegisterFilter(CLSID, L"DirectShow Softcam", 0, &CLSID_VideoInputDeviceCategory, L"DirectShow Softcam", ...)
        self.assertEqual(webcam.CATEGORY_INSTANCE_KEY, "SOFTWARE\\Classes\\CLSID\\{860BB310-5D01-11D0-BD3B-00A0C911CE86}"
                                                       "\\Instance\\DirectShow Softcam")

    def test_softcams_own_category_entry_counts_in_both_views(self):
        self.install_files()
        self.register()
        self.assertEqual(webcam.registration_state(self.layout()), webcam.Registration(True, None, {
            name: str(self.folder() / name) for name in ("softcam64.dll", "softcam32.dll")}))

    def test_a_key_named_after_the_clsid_without_a_clsid_value_does_not_count(self):
        self.install_files()
        self.register(instance=webcam.CLSID, instance_clsid=None)
        self.assertEqual(webcam.registration_state(self.layout()).problem, "notListed")

    def test_any_subkey_whose_clsid_value_is_softcams_counts(self):
        self.install_files()
        self.register(instance="Some other name", instance_clsid=webcam.CLSID.lower())
        self.assertTrue(webcam.registration_state(self.layout()).ok)

    def test_other_filters_in_the_category_do_not_count(self):
        self.install_files()
        self.register(listed=False)
        for target in self.layout().targets:
            self.registry.set(target.view, webcam.INSTANCE_ROOT_KEY + "\\OBS Virtual Camera", "CLSID",
                              "{A3FCE0F5-3493-419F-958A-ABA1250EC20B}")
        self.assertEqual(webcam.registration_state(self.layout()).problem, "notListed")
        self.register(instance_clsid="{A3FCE0F5-3493-419F-958A-ABA1250EC20B}")  # our name, another filter
        self.assertEqual(webcam.registration_state(self.layout()).problem, "notListed")

    def test_each_view_needs_its_own_entry(self):
        self.install_files()
        self.register()
        self.registry.delete_tree(webcam.KEY_WOW64_32KEY, webcam.CATEGORY_INSTANCE_KEY)
        self.assertEqual(webcam.registration_state(self.layout()).problem, "notListed")

    def test_only_orbits_version_folders_count_as_orbits_dlls(self):
        older = webcam.webcam_root() / "0123456789abcdef"
        self.assertEqual(webcam.orbit_dll_path(str(older / "softcam64.dll"), "softcam64.dll"),
                         os.path.normpath(str(older / "softcam64.dll")))
        self.assertEqual(webcam.orbit_dll_path('"' + str(older / "softcam32.dll") + '"', "softcam32.dll"),
                         os.path.normpath(str(older / "softcam32.dll")))
        for value, name in ((str(older / "softcam64.dll"), "softcam32.dll"),
                            (str(webcam.webcam_root() / "softcam64.dll"), "softcam64.dll"),
                            (str(webcam.webcam_root() / "not-a-version" / "softcam64.dll"), "softcam64.dll"),
                            (str(older / "sub" / "softcam64.dll"), "softcam64.dll"),
                            ("%ProgramFiles%\\Orbit\\Webcam\\0123456789abcdef\\softcam64.dll", "softcam64.dll"),
                            (str(self.root / "Users" / "Orbit" / "Webcam" / "0123456789abcdef" / "softcam64.dll"),
                             "softcam64.dll"),
                            ("C:\\Program Files\\OtherCam\\softcam.dll", "softcam64.dll"), (None, "softcam64.dll"),
                            ("", "softcam64.dll")):
            with self.subTest(value=value):
                self.assertIsNone(webcam.orbit_dll_path(value, name))


# Visual C++ runtime ----------------------------------------------------------------------------

class RuntimeTests(WindowsEnvironment):
    def test_both_runtimes_at_14_44_are_enough(self):
        self.set_runtime()
        status = webcam.vc_runtime_status(self.layout())
        self.assertEqual(status, {"ok": True, "required": "14.44", "x64": "14.44.35211", "x86": "14.44.35211",
                                  "missing": [], "commands": []})

    def test_an_old_x86_runtime_is_reported_with_its_winget_command(self):
        self.set_runtime(x86=(14, 40, 33810))
        status = webcam.vc_runtime_status(self.layout())
        self.assertFalse(status["ok"])
        self.assertEqual(status["missing"], ["x86"])
        self.assertEqual(status["commands"], ["winget install Microsoft.VCRedist.2015+.x86"])
        message = webcam.runtime_message(status)
        self.assertIn("x86: version 14.40.33810 is too old", message)
        self.assertIn("winget install Microsoft.VCRedist.2015+.x86", message)
        self.assertNotIn("Microsoft.VCRedist.2015+.x64", message)
        self.assertIn("14.44", message)
        self.assertIn(webcam.VC_REDIST_PAGE, message)

    def test_missing_runtimes_list_both_commands(self):
        status = webcam.vc_runtime_status(self.layout())
        self.assertEqual(status["missing"], ["x64", "x86"])
        self.assertEqual(status["commands"], [webcam.WINGET_COMMANDS["x64"], webcam.WINGET_COMMANDS["x86"]])
        self.assertIn("x64: not installed; x86: not installed", webcam.runtime_message(status))

    def test_either_registry_view_counts_and_installed_must_be_1(self):
        self.set_runtime(view=webcam.KEY_WOW64_64KEY)
        self.assertTrue(webcam.vc_runtime_status(self.layout())["ok"])
        self.registry.set(webcam.KEY_WOW64_64KEY, webcam.VC_RUNTIME_KEY + "\\x86", "Installed", 0)
        self.assertEqual(webcam.vc_runtime_status(self.layout())["missing"], ["x86"])

    def test_the_version_string_is_used_without_major_and_minor(self):
        for arch in ("x64", "x86"):
            path = webcam.VC_RUNTIME_KEY + "\\" + arch
            self.registry.set(webcam.KEY_WOW64_32KEY, path, "Installed", 1)
            self.registry.set(webcam.KEY_WOW64_32KEY, path, "Version", "v14.50.35719.00")
        status = webcam.vc_runtime_status(self.layout())
        self.assertTrue(status["ok"])
        self.assertEqual(status["x64"], "14.50.35719")

    def test_dll_file_versions_cover_a_runtime_without_registry_keys(self):
        with patch.object(webcam, "_file_version", return_value=(14, 44, 35211)) as version:
            status = webcam.vc_runtime_status(self.layout())
        self.assertTrue(status["ok"])
        checked = {os.path.basename(call.args[0]) for call in version.call_args_list}
        self.assertEqual(checked, {"msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"})
        with patch.object(webcam, "_file_version", side_effect=lambda path: None if path.endswith("_1.dll") else (14, 44, 1)):
            self.assertEqual(webcam.vc_runtime_status(self.layout())["missing"], ["x64"])

    def test_32_bit_windows_checks_only_x86(self):
        self.set_runtime(x64=None, view=0)
        with patch.object(webcam, "_native_machine_from_windows", return_value="x86"), \
             patch.object(webcam, "process_bits", return_value=32):
            status = webcam.vc_runtime_status(self.layout())
        self.assertTrue(status["ok"])
        self.assertNotIn("x64", status)


class FileVersionTests(unittest.TestCase):
    def fake_version_dll(self, pointer_offset=40, signature=0xFEEF04BD):
        library = MagicMock()
        library.GetFileVersionInfoSizeW.return_value = 200

        def fill(path, handle, size, block):
            info = webcam.VS_FIXEDFILEINFO(dwSignature=signature, dwFileVersionMS=(14 << 16) | 44,
                                           dwFileVersionLS=(35211 << 16) | 0)
            ctypes.memmove(ctypes.addressof(block) + 40, ctypes.byref(info), ctypes.sizeof(info))
            return 1

        def query(block, name, pointer, length):
            self.assertEqual(name, "\\")
            pointer._obj.value = ctypes.addressof(block) + pointer_offset
            length._obj.value = ctypes.sizeof(webcam.VS_FIXEDFILEINFO)
            return 1
        library.GetFileVersionInfoW.side_effect = fill
        library.VerQueryValueW.side_effect = query
        return library

    def test_reads_vs_fixedfileinfo_with_exact_types(self):
        library = self.fake_version_dll()
        with tempfile.NamedTemporaryFile(suffix=".dll") as handle, \
             patch.object(webcam.ctypes, "WinDLL", create=True, return_value=library):
            self.assertEqual(webcam._file_version(handle.name), (14, 44, 35211))
        self.assertEqual(library.GetFileVersionInfoSizeW.restype, ctypes.c_uint32)
        self.assertEqual(library.GetFileVersionInfoW.argtypes,
                         [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p])
        self.assertEqual(library.VerQueryValueW.argtypes, [ctypes.c_void_p, ctypes.c_wchar_p,
                                                           ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)])

    def test_a_pointer_outside_the_block_or_a_bad_signature_is_ignored(self):
        with tempfile.NamedTemporaryFile(suffix=".dll") as handle:
            for library in (self.fake_version_dll(pointer_offset=10_000), self.fake_version_dll(signature=0)):
                with patch.object(webcam.ctypes, "WinDLL", create=True, return_value=library):
                    self.assertIsNone(webcam._file_version(handle.name))
        self.assertIsNone(webcam._file_version("/no/such/file.dll"))


# Getting verified DLLs ---------------------------------------------------------------------------

RAW = "https://raw.githubusercontent.com/AceDimi2005/Orbit/"


def http_error(code=404):
    return urllib.error.HTTPError("u", code, "Not Found", {}, None)


class SourceTests(WindowsEnvironment):
    def setUp(self):
        super().setUp()
        version = patch.object(webcam, "_agent_version", return_value="4.4.0")
        version.start()
        self.addCleanup(version.stop)

    def test_bundled_dlls_are_used_without_any_download(self):
        download = Mock(side_effect=AssertionError("no download"))
        sources = webcam.ensure_sources(self.layout(), download)
        self.assertEqual(sources, {name: WEBCAM_DIR / name for name in ("softcam64.dll", "softcam32.dll")})

    def test_the_installed_folder_is_a_verified_source(self):
        self.install_files()
        empty = self.root / "agent-without-dlls"
        empty.mkdir()
        with patch.object(webcam, "bundled_directories", return_value=[empty]):
            sources = webcam.ensure_sources(self.layout(), Mock(side_effect=AssertionError("no download")))
        self.assertEqual(sources, {name: self.folder() / name for name in ("softcam64.dll", "softcam32.dll")})
        (self.folder() / "softcam32.dll").write_bytes(b"MZ damaged")
        with patch.object(webcam, "bundled_directories", return_value=[empty]):
            download = Mock(return_value=WEBCAM_DIR / "softcam32.dll")
            sources = webcam.ensure_sources(self.layout(), download)
        download.assert_called_once_with("softcam32.dll")  # a changed file is never a source

    def test_a_missing_bundled_dll_is_downloaded_from_the_release_tag_and_cached(self):
        fetch = Mock(side_effect=lambda url, **kwargs: (WEBCAM_DIR / url.rsplit("/", 1)[1]).read_bytes())
        empty = self.root / "agent-without-dlls"
        empty.mkdir()
        with patch.object(webcam, "bundled_directories", return_value=[empty]):
            sources = webcam.ensure_sources(self.layout(), lambda name: webcam.download_dll(name, fetch=fetch))
            cache = webcam.cache_directory()
            self.assertEqual(sources["softcam64.dll"], cache / "softcam64.dll")
            self.assertTrue(webcam.is_verified(cache / "softcam32.dll", "softcam32.dll", use_cache=False))
            urls = [call.args[0] for call in fetch.call_args_list]
            self.assertEqual(urls, [RAW + "pc-v4.4.0/Orbit-Windows-Agent/webcam/" + name
                                    for name in ("softcam64.dll", "softcam32.dll")])
            for call in fetch.call_args_list:
                orbit_updater.validate_github_url(call.args[0])
                self.assertEqual(call.kwargs["accept"], "application/octet-stream")
            fetch.reset_mock()
            webcam.ensure_sources(self.layout(), lambda name: webcam.download_dll(name, fetch=fetch))
            fetch.assert_not_called()  # the cache is reused

    def test_without_the_release_tag_main_is_used(self):
        def fetch(url, **kwargs):
            if "/pc-v4.4.0/" in url:
                raise http_error(404)
            return (WEBCAM_DIR / url.rsplit("/", 1)[1]).read_bytes()
        fetch = Mock(side_effect=fetch)
        self.assertTrue(webcam.is_verified(webcam.download_dll("softcam64.dll", fetch=fetch), "softcam64.dll"))
        self.assertEqual([call.args[0] for call in fetch.call_args_list],
                         [RAW + "pc-v4.4.0/Orbit-Windows-Agent/webcam/softcam64.dll",
                          RAW + "main/Orbit-Windows-Agent/webcam/softcam64.dll"])

    def test_refs_are_the_release_tag_then_main(self):
        self.assertEqual(webcam.download_refs(), ["pc-v4.4.0", "main"])
        for version in ("", "4.4", "4.4.0-beta", "../main"):
            with self.subTest(version=version), patch.object(webcam, "_agent_version", return_value=version):
                self.assertEqual(webcam.download_refs(), ["main"])

    def test_a_download_with_another_hash_is_refused_and_not_kept(self):
        fetch = Mock(return_value=b"MZ not the pinned build")
        with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.InstallError) as raised:
            webcam.download_dll("softcam64.dll", fetch=fetch)
        self.assertEqual(raised.exception.status, 503)
        self.assertIn("different version", raised.exception.message)
        self.assertEqual(fetch.call_count, 2)
        self.assertFalse((webcam.cache_directory() / "softcam64.dll").exists())

    def test_a_tag_with_another_build_falls_back_to_main(self):
        def fetch(url, **kwargs):
            return b"MZ other build" if "/pc-v4.4.0/" in url else (WEBCAM_DIR / "softcam32.dll").read_bytes()
        with self.assertLogs("orbit.webcam", "WARNING"):
            path = webcam.download_dll("softcam32.dll", fetch=fetch)
        self.assertTrue(webcam.is_verified(path, "softcam32.dll", use_cache=False))

    def test_download_failures_are_explained(self):
        cases = ((http_error(404), "HTTP 404", 2), (urllib.error.URLError("offline"), "internet connection", 1),
                 (TimeoutError("slow"), "internet connection", 1))
        for error, text, calls in cases:
            with self.subTest(error=error):
                fetch = Mock(side_effect=error)
                with self.assertRaises(webcam.InstallError) as raised:
                    webcam.download_dll("softcam32.dll", fetch=fetch)
                self.assertEqual(raised.exception.status, 503)
                self.assertIn(text, raised.exception.message)
                self.assertEqual(fetch.call_count, calls)  # no second try when the PC is offline


class AgentVersionTests(unittest.TestCase):
    def test_the_release_tag_follows_the_agent_version_in_the_capabilities(self):
        with patch.object(webcam.orbit_capabilities, "capabilities_payload",
                          return_value={"agentVersion": "4.4.0", "features": []}):
            self.assertEqual(webcam.download_refs(), ["pc-v4.4.0", "main"])
        with patch.object(webcam.orbit_capabilities, "capabilities_payload", side_effect=RuntimeError("not set")):
            self.assertEqual(webcam.download_refs(), ["main"])


# The elevated step -------------------------------------------------------------------------------

def _balanced(script):
    """Braces and parentheses balance outside single-quoted strings."""
    depth = {"{": 0, "(": 0}
    pairs = {"}": "{", ")": "("}
    inside = False
    index = 0
    while index < len(script):
        character = script[index]
        if inside:
            if character in webcam._PS_QUOTES:
                if index + 1 < len(script) and script[index + 1] in webcam._PS_QUOTES:
                    index += 1
                else:
                    inside = False
        elif character in webcam._PS_QUOTES:
            inside = True
        elif character in depth:
            depth[character] += 1
        elif character in pairs:
            depth[pairs[character]] -= 1
            if depth[pairs[character]] < 0:
                return False
        index += 1
    return not inside and all(value == 0 for value in depth.values())


def _statements(script):
    """The script's top-level statements: split at "; " outside quotes, braces and parentheses."""
    statements, depth, inside, current, index = [], 0, False, [], 0
    while index < len(script):
        character = script[index]
        if inside:
            if character in webcam._PS_QUOTES:
                if index + 1 < len(script) and script[index + 1] in webcam._PS_QUOTES:
                    current.append(character)
                    index += 1
                else:
                    inside = False
        elif character in webcam._PS_QUOTES:
            inside = True
        elif character in "{(":
            depth += 1
        elif character in "})":
            depth -= 1
        elif depth == 0 and script.startswith("; ", index):
            statements.append("".join(current))
            current = []
            index += 2
            continue
        current.append(character)
        index += 1
    statements.append("".join(current))
    return statements


class ScriptTests(WindowsEnvironment):
    def script(self, layout=None, sources=None, previous=None):
        layout = layout or self.layout()
        sources = sources or {target.name: WEBCAM_DIR / target.name for target in layout.targets}
        return webcam.elevation_script(layout, self.folder(), sources, previous=previous)

    def paths(self):
        q = webcam.ps_quote
        folder = self.folder()
        return {"regsvr64": q(os.path.join(str(self.system_root), "System32", "regsvr32.exe")),
                "regsvr32": q(os.path.join(str(self.system_root), "SysWOW64", "regsvr32.exe")),
                "dll64": q(folder / "softcam64.dll"), "dll32": q(folder / "softcam32.dll")}

    def registration_steps(self, statements):
        p = self.paths()
        first = statements.index(f"& {p['regsvr64']} /s {p['dll64']} 2>&1 | Out-Null")
        second = statements.index(f"& {p['regsvr32']} /s {p['dll32']} 2>&1 | Out-Null")
        return first, second, statements[first + 1], statements[second + 1]

    def test_the_folder_is_in_program_files_which_only_administrators_can_write(self):
        self.assertEqual(self.folder(), self.program_files / "Orbit" / "Webcam" / webcam.INSTALL_ID)
        script = self.script()
        for text in ("icacls", "ProgramData", "/setowner", "/reset", "/grant", " /T "):
            self.assertNotIn(text, script)

    def test_the_script_checks_links_verifies_in_memory_then_registers_both_views(self):
        script = self.script()
        statements = _statements(script)
        q, folder = webcam.ps_quote, self.folder()
        self.assertEqual(statements[:3], ["trap { exit 90 }", "$step = 'orbit-webcam-install'",
                                          f"try {{ [void][IO.Directory]::CreateDirectory({q(folder)}) }} catch {{ exit 13 }}"])
        links = statements[3]
        self.assertTrue(links.startswith(f"foreach ($p in @({q(folder.parent.parent)}, {q(folder.parent)}, {q(folder)}))"),
                        links)
        self.assertIn("-band 1024", links)
        self.assertIn("exit 14", links)
        first, second, failure64, failure32 = self.registration_steps(statements)
        for name, digest in GIVEN_PINS.items():
            expected = digest.upper()
            destination = statements.index(f"$d = {q(folder / name)}")
            self.assertEqual(statements[destination + 1], f"$s = {q(WEBCAM_DIR / name)}")
            copy, verify = statements[destination + 2], statements[destination + 3]
            self.assertLess(statements.index(links), destination)
            self.assertLess(destination, first)
            # Read into memory, size-capped, hash checked, and only then written.
            read = copy.index("$b = [IO.File]::ReadAllBytes($s)")
            checked = copy.index(f".Replace('-', '') -ne '{expected}') {{ exit 21 }}")
            written = copy.index("[IO.File]::WriteAllBytes($d, $b)")
            self.assertLess(copy.index(f".Length -le {webcam.MAX_DLL_BYTES}"), read)
            self.assertLess(read, checked)
            self.assertLess(checked, written)
            self.assertIn("ComputeHash($b)", copy)
            self.assertEqual(verify, f"if ((Get-FileHash -LiteralPath $d -Algorithm SHA256 -ErrorAction Stop).Hash -ne "
                                     f"'{expected}') {{ Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue; "
                                     "exit 21 }")
            self.assertEqual(script.count(expected), 3)
        self.assertLess(first, second)
        # When the 32-bit registration fails on a fresh PC, the 64-bit one is removed again.
        p = self.paths()
        self.assertNotIn("/u /s", failure64)
        self.assertTrue(failure64.endswith("exit (30 + $c) }"))
        self.assertIn(f"& {p['regsvr64']} /u /s {p['dll64']} 2>&1 | Out-Null", failure32)
        self.assertTrue(failure32.endswith("exit (40 + $c) }"))
        cleanup = statements[-2]
        self.assertEqual(statements.index(cleanup), second + 2)
        self.assertTrue(cleanup.startswith(f"Get-ChildItem -LiteralPath {q(folder.parent)} -Directory -Force"), cleanup)
        for text in (f"$_.Name -ne '{webcam.INSTALL_ID}'", "'^[0-9a-f]{16}$'", "-band 1024) -eq 0",
                     "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue"):
            self.assertIn(text, cleanup)
        self.assertEqual(statements[-1], "exit 0")
        self.assertNotIn('"', script)
        self.assertTrue(_balanced(script))

    def test_an_upgrade_puts_the_older_orbit_webcam_back_when_the_32_bit_step_fails(self):
        older = webcam.webcam_root() / "0123456789abcdef"
        previous = {name: str(older / name) for name in ("softcam64.dll", "softcam32.dll")}
        script = self.script(previous=previous)
        _first, _second, failure64, failure32 = self.registration_steps(_statements(script))
        p, q = self.paths(), webcam.ps_quote
        old64, old32 = q(os.path.normpath(previous["softcam64.dll"])), q(os.path.normpath(previous["softcam32.dll"]))
        self.assertIn(f"if (Test-Path -LiteralPath {old64} -PathType Leaf) {{ & {p['regsvr64']} /s {old64} 2>&1 | "
                      f"Out-Null }} else {{ & {p['regsvr64']} /u /s {p['dll64']} 2>&1 | Out-Null }}", failure32)
        self.assertIn(f"if (Test-Path -LiteralPath {old32} -PathType Leaf) {{ & {p['regsvr32']} /s {old32} 2>&1 | "
                      "Out-Null }", failure32)
        self.assertIn(f"if (Test-Path -LiteralPath {old64} -PathType Leaf) {{ & {p['regsvr64']} /s {old64} 2>&1 | "
                      "Out-Null }", failure64)
        self.assertLess(failure32.index(old64), failure32.index("exit (40 + $c)"))
        self.assertTrue(_balanced(script))

    def test_a_view_already_registered_to_these_files_is_left_alone(self):
        p = self.paths()
        script = self.script(previous={"softcam64.dll": str(self.folder() / "softcam64.dll"), "softcam32.dll": None})
        _first, _second, failure64, failure32 = self.registration_steps(_statements(script))
        self.assertNotIn(p["dll64"], failure32)
        self.assertNotIn("/u /s", failure32)

    def test_another_programs_dll_is_never_run_elevated(self):
        p = self.paths()
        for other in ("C:\\Program Files\\OtherCam\\softcam.dll",
                      str(self.root / "Mallory" / "Orbit" / "Webcam" / "0123456789abcdef" / "softcam64.dll"),
                      "%ProgramFiles%\\Orbit\\Webcam\\0123456789abcdef\\softcam64.dll"):
            with self.subTest(other=other):
                script = self.script(previous={"softcam64.dll": other, "softcam32.dll": other})
                for text in ("OtherCam", "0123456789abcdef", "Mallory"):
                    self.assertNotIn(text, script)
                _first, _second, _failure64, failure32 = self.registration_steps(_statements(script))
                self.assertIn(f"& {p['regsvr64']} /u /s {p['dll64']} 2>&1 | Out-Null", failure32)

    def test_32_bit_windows_registers_one_dll_without_wow64(self):
        with patch.object(webcam, "_native_machine_from_windows", return_value="x86"), \
             patch.object(webcam, "process_bits", return_value=32):
            script = self.script()
        self.assertNotIn("SysWOW64", script)
        self.assertNotIn("softcam64", script)
        self.assertNotIn("/u /s", script)
        self.assertTrue(_balanced(script))

    def test_quotes_in_paths_are_escaped_for_powershell(self):
        self.assertEqual(webcam.ps_quote("C:\\Users\\D'Angelo"), "'C:\\Users\\D''Angelo'")
        self.assertEqual(webcam.ps_quote("C:\\Users\\D\u2019Angelo"), "'C:\\Users\\D\u2019\u2019Angelo'")
        self.assertEqual(webcam.ps_quote("C:\\$HOME `x & 100%"), "'C:\\$HOME `x & 100%'")
        for bad in ('C:\\a"b', "C:\\a\nb"):
            with self.assertRaises(webcam.InstallError):
                webcam.ps_quote(bad)
        sources = {"softcam64.dll": Path("C:/Users/D\u2019Angelo/softcam64.dll"),
                   "softcam32.dll": Path("C:/Users/O'Brien/softcam32.dll")}
        self.assertTrue(_balanced(self.script(sources=sources)))

    def test_parameters_wrap_the_script_in_one_argument(self):
        parameters = webcam.powershell_parameters("exit 0")
        self.assertEqual(parameters, '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "exit 0"')
        with self.assertRaises(ValueError):
            webcam.powershell_parameters('Write-Output "x"')

    @unittest.skipUnless(os.name == "nt" and shutil.which("powershell"), "needs Windows PowerShell")
    def test_windows_powershell_parses_the_script_without_errors(self):
        # Only PowerShell's parser runs; the script itself is never executed.
        layout = webcam.platform_layout()
        sources = {target.name: WEBCAM_DIR / target.name for target in layout.targets}
        older = webcam.webcam_root() / "0123456789abcdef"
        owned = {target.name: str(older / target.name) for target in layout.targets}
        scripts = {"install": webcam.elevation_script(layout, webcam.install_directory(), sources),
                   "upgrade": webcam.elevation_script(layout, webcam.install_directory(), sources, previous=owned),
                   "uninstall": webcam.uninstall_script(layout, owned)}
        for label, script in scripts.items():
            with self.subTest(script=label):
                path = self.root / f"{label}.ps1"
                path.write_text(script, encoding="utf-8-sig")
                check = ("$t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("
                         f"'{path}', [ref]$t, [ref]$e); foreach ($x in $e) {{ Write-Output $x.Message }}; exit $e.Count")
                result = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", check],
                                        capture_output=True, text=True, timeout=120, env=REAL_ENVIRONMENT)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(os.name == "nt" and shutil.which("powershell"), "needs Windows PowerShell")
    def test_the_command_line_hands_powershell_the_exact_quoted_text(self):
        # The same parameters the UAC prompt gets; this harmless script only writes a temp file.
        text = "C:\\Users\\D\u2019Angelo & O'Brien\\100% $HOME `n\\x"
        output = self.root / "out.txt"
        script = (f"Set-Content -LiteralPath {webcam.ps_quote(output)} -Value {webcam.ps_quote(text)} "
                  "-Encoding UTF8 -NoNewline; exit 7")
        powershell = shutil.which("powershell")
        result = subprocess.run(f'"{powershell}" {webcam.powershell_parameters(script)}', capture_output=True,
                                timeout=120, env=REAL_ENVIRONMENT)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8-sig"), text)


class UninstallScriptTests(WindowsEnvironment):
    def test_only_orbits_registrations_are_removed_then_the_folder(self):
        q = webcam.ps_quote
        older = webcam.webcam_root() / "0123456789abcdef"
        owned = {"softcam64.dll": str(older / "softcam64.dll"), "softcam32.dll": str(self.folder() / "softcam32.dll")}
        script = webcam.uninstall_script(self.layout(), owned)
        statements = _statements(script)
        self.assertEqual(statements[:2], ["trap { exit 90 }", "$step = 'orbit-webcam-uninstall'"])
        regsvr64 = q(os.path.join(str(self.system_root), "System32", "regsvr32.exe"))
        regsvr32 = q(os.path.join(str(self.system_root), "SysWOW64", "regsvr32.exe"))
        for statement, regsvr, path, classes, base in (
                (statements[2], regsvr64, owned["softcam64.dll"], "SOFTWARE\\Classes", 60),
                (statements[3], regsvr32, owned["softcam32.dll"], "SOFTWARE\\Classes\\WOW6432Node", 70)):
            with self.subTest(path=path):
                self.assertTrue(statement.startswith(f"if (Test-Path -LiteralPath {q(path)} -PathType Leaf) {{ "
                                                     f"& {regsvr} /u /s {q(path)} 2>&1 | Out-Null; "), statement)
                self.assertIn(f"exit ({base} + $c)", statement)
                # The DLL is gone: its keys are deleted directly, only in this view.
                root = "Registry::HKEY_LOCAL_MACHINE\\" + classes + "\\CLSID\\"
                self.assertIn(f"Remove-Item -LiteralPath {q(root + webcam.CLSID)} -Recurse", statement)
                self.assertIn(f"Get-ChildItem -LiteralPath {q(root + webcam.VIDEO_INPUT_CATEGORY + chr(92) + 'Instance')}",
                              statement)
                self.assertIn(f"$_.GetValue('CLSID') -eq {q(webcam.CLSID)}", statement)
        self.assertEqual(statements[4], f"$w = {q(webcam.webcam_root())}")
        self.assertIn("exit 14", statements[5])
        self.assertIn("[IO.Directory]::Delete($w)", statements[5])
        self.assertIn(f"[IO.Directory]::Delete({q(webcam.orbit_program_files())})", statements[5])
        self.assertIn("'^[0-9a-f]{16}$'", statements[5])
        self.assertEqual(statements[6:], ["if (Test-Path -LiteralPath $w) { exit 50 }", "exit 0"])
        self.assertNotIn('"', script)
        self.assertTrue(_balanced(script))

    def test_a_view_owned_by_another_program_is_not_touched(self):
        script = webcam.uninstall_script(self.layout(), {"softcam32.dll": str(self.folder() / "softcam32.dll")})
        self.assertNotIn("System32", script)
        self.assertNotIn("softcam64", script)
        self.assertIn("WOW6432Node", script)
        files_only = webcam.uninstall_script(self.layout(), {})
        self.assertNotIn("regsvr32", files_only)
        self.assertIn("exit 50", files_only)


class ElevationTests(unittest.TestCase):
    def setUp(self):
        self.shell32, self.kernel32, self.ole32 = MagicMock(), MagicMock(), MagicMock()
        self.ole32.CoInitializeEx.return_value = 0
        self.kernel32.WaitForSingleObject.return_value = webcam.WAIT_OBJECT_0
        self.exit_code = 0
        self.seen = {}

        def get_exit_code(handle, code):
            code._obj.value = self.exit_code
            return 1
        self.kernel32.GetExitCodeProcess.side_effect = get_exit_code
        libraries = {"shell32": self.shell32, "kernel32": self.kernel32, "ole32": self.ole32}
        for patcher in (patch.object(webcam.ctypes, "WinDLL", create=True,
                                     side_effect=lambda name, **kwargs: libraries[name]),
                        patch.object(webcam.ctypes, "get_last_error", create=True, return_value=0)):
            self.last_error = patcher.start()
            self.addCleanup(patcher.stop)

    def approve(self, handle=0x1234):
        def shell_execute(pointer):
            info = pointer._obj
            self.seen.update(cbSize=info.cbSize, fMask=info.fMask, verb=info.lpVerb, file=info.lpFile,
                             parameters=info.lpParameters, show=info.nShow, hwnd=info.hwnd)
            info.hProcess = handle
            return 1
        self.shell32.ShellExecuteExW.side_effect = shell_execute

    def test_one_runas_prompt_then_waits_for_the_exit_code(self):
        self.approve()
        self.exit_code = 0
        self.assertEqual(webcam.run_elevated("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                                             "-Command \"exit 0\"", timeout=5), 0)
        self.assertEqual(self.shell32.ShellExecuteExW.call_count, 1)
        self.assertEqual(self.seen["verb"], "runas")
        self.assertEqual(self.seen["file"], "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        self.assertEqual(self.seen["parameters"], "-Command \"exit 0\"")
        self.assertEqual(self.seen["show"], webcam.SW_HIDE)
        self.assertEqual(self.seen["fMask"], webcam.SEE_MASK_NOCLOSEPROCESS | webcam.SEE_MASK_NOASYNC)
        self.assertEqual(self.seen["cbSize"], ctypes.sizeof(webcam.SHELLEXECUTEINFOW))
        self.kernel32.WaitForSingleObject.assert_called_once_with(0x1234, 5000)
        self.kernel32.CloseHandle.assert_called_once_with(0x1234)
        self.ole32.CoInitializeEx.assert_called_once_with(None, webcam.COINIT_APARTMENTTHREADED | webcam.COINIT_DISABLE_OLE1DDE)
        self.ole32.CoUninitialize.assert_called_once_with()
        self.assertEqual(self.shell32.ShellExecuteExW.argtypes, [ctypes.POINTER(webcam.SHELLEXECUTEINFOW)])
        self.assertEqual(self.shell32.ShellExecuteExW.restype, ctypes.c_int)
        self.assertEqual(self.kernel32.WaitForSingleObject.argtypes, [ctypes.c_void_p, ctypes.c_uint32])
        self.assertEqual(self.kernel32.WaitForSingleObject.restype, ctypes.c_uint32)
        self.assertEqual(self.kernel32.GetExitCodeProcess.argtypes, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)])
        self.assertEqual(self.kernel32.CloseHandle.argtypes, [ctypes.c_void_p])

    def test_the_exit_code_of_the_script_is_returned(self):
        self.approve()
        self.exit_code = 43
        self.assertEqual(webcam.run_elevated("ps.exe", "x"), 43)

    def test_declining_the_prompt_is_its_own_error_and_nothing_waits(self):
        self.shell32.ShellExecuteExW.return_value = 0
        self.last_error.return_value = webcam.ERROR_CANCELLED
        with self.assertRaises(webcam.ElevationDeclined):
            webcam.run_elevated("ps.exe", "x")
        self.kernel32.WaitForSingleObject.assert_not_called()
        self.ole32.CoUninitialize.assert_called_once_with()

    def test_other_shell_errors_carry_their_code(self):
        self.shell32.ShellExecuteExW.return_value = 0
        self.last_error.return_value = 5
        with self.assertRaises(webcam.ElevationFailed) as raised:
            webcam.run_elevated("ps.exe", "x")
        self.assertEqual(raised.exception.code, 5)

    def test_a_hung_script_times_out_and_the_handle_is_closed(self):
        self.approve()
        self.kernel32.WaitForSingleObject.return_value = webcam.WAIT_TIMEOUT
        with self.assertRaises(TimeoutError):
            webcam.run_elevated("ps.exe", "x", timeout=1)
        self.kernel32.CloseHandle.assert_called_once_with(0x1234)

    def test_no_process_handle_means_unknown(self):
        self.approve(handle=0)
        self.assertIsNone(webcam.run_elevated("ps.exe", "x"))
        self.kernel32.WaitForSingleObject.assert_not_called()

    def test_shellexecuteinfow_has_the_windows_layout(self):
        self.assertEqual(ctypes.sizeof(webcam.SHELLEXECUTEINFOW), 112 if struct.calcsize("P") == 8 else 60)
        self.assertEqual(webcam.SHELLEXECUTEINFOW.hProcess.offset, 104 if struct.calcsize("P") == 8 else 56)


# Setup flow ------------------------------------------------------------------------------------

class InstallFlowTests(WindowsEnvironment):
    def setUp(self):
        super().setUp()
        self.set_runtime()
        self.stages = []
        self.elevations = []

    def elevate(self, code=0, register=True, error=None):
        """The approved prompt: what the elevated script does (copy, then register) is faked."""
        def run(executable, parameters, timeout):
            self.elevations.append((executable, parameters, timeout, self.folder().exists()))
            if error is not None:
                raise error
            if register:
                self.install_files()
                self.register()
            return code
        return run

    def install(self, **kwargs):
        kwargs.setdefault("download", Mock(side_effect=AssertionError("no download")))
        return webcam.install_webcam(progress=self.stages.append, **kwargs)

    def test_a_fresh_pc_prompts_once_and_verifies_the_registry(self):
        self.assertEqual(self.install(elevate=self.elevate()), "installed")
        self.assertEqual(len(self.elevations), 1)
        executable, parameters, timeout, folder_existed = self.elevations[0]
        self.assertEqual(executable, self.layout().powershell)
        self.assertTrue(parameters.endswith('"'))
        self.assertIn("CreateDirectory", parameters)
        self.assertNotIn("icacls", parameters)
        self.assertFalse(folder_existed)  # nothing is written to Program Files as the signed-in user
        self.assertEqual(timeout, webcam.ELEVATED_TIMEOUT_SECONDS)
        self.assertEqual(self.stages, ["preparing", "waitingForApproval", "verifying"])
        self.assertTrue(webcam.files_installed(self.layout()))
        self.assertTrue(webcam.registration_state(self.layout()).ok)
        titles = [call.args[0] for call in self.notify.call_args_list]
        self.assertEqual(titles, ["Approve the webcam setup", "iPhone webcam is set up"])

    def test_an_installed_pc_needs_no_prompt(self):
        self.install_files()
        self.register()
        self.assertEqual(self.install(elevate=Mock(side_effect=AssertionError("no prompt"))), "alreadyInstalled")
        self.notify.assert_not_called()

    def test_an_installed_pc_needs_no_source_files_or_download(self):
        self.install_files()
        self.register()
        empty = self.root / "agent-without-dlls"
        empty.mkdir()
        offline = Mock(side_effect=webcam.InstallError(503, "Could not download the webcam driver."))
        with patch.object(webcam, "bundled_directories", return_value=[empty]), \
             patch.object(webcam, "ensure_sources", side_effect=AssertionError("no sources needed")):
            self.assertEqual(self.install(elevate=Mock(side_effect=AssertionError("no prompt")), download=offline),
                             "alreadyInstalled")
        offline.assert_not_called()

    def test_declining_the_prompt_registers_and_writes_nothing(self):
        with self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=self.elevate(error=webcam.ElevationDeclined()))
        self.assertEqual(raised.exception.status, 403)
        self.assertIn("declined", raised.exception.message)
        self.assertFalse(webcam.registration_state(self.layout()).ok)
        self.assertFalse(self.folder().exists())
        self.assertNotIn("verifying", self.stages)

    def test_a_missing_runtime_stops_before_copying_or_prompting(self):
        self.registry.keys.clear()
        elevate = Mock(side_effect=AssertionError("no prompt"))
        with self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=elevate)
        self.assertEqual(raised.exception.status, 409)
        self.assertIn("winget install Microsoft.VCRedist.2015+.x64", raised.exception.message)
        self.assertIn("winget install Microsoft.VCRedist.2015+.x86", raised.exception.message)
        self.assertFalse(self.folder().exists())
        self.assertEqual(self.stages, [])

    def test_regsvr32_failing_to_load_the_dll_is_explained(self):
        with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=self.elevate(code=43, register=False))
        self.assertEqual(raised.exception.status, 503)
        self.assertIn("softcam32.dll", raised.exception.message)
        self.assertIn("could not load", raised.exception.message)
        self.assertIn(webcam.VC_REDIST_PAGE, raised.exception.message)

    def test_success_is_only_reported_after_the_registry_is_verified(self):
        def copied_but_not_listed(executable, parameters, timeout):
            self.install_files()
            self.register(listed=False)
            return 0
        with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=copied_but_not_listed)
        self.assertIn("not registered correctly", raised.exception.message)
        self.assertIn(webcam.REGISTRATION_MESSAGES["notListed"], raised.exception.message)
        self.assertNotIn("iPhone webcam is set up", [call.args[0] for call in self.notify.call_args_list])

    def test_exit_codes_map_to_plain_words(self):
        layout = self.layout()
        registration = webcam.Registration(False, "missing", {})
        cases = {13: "could not create the webcam folder", 14: "is a link", 20: "Close apps",
                 21: "changed during setup", 35: "regsvr32 error 5", 90: "script failed", 77: "code 77"}
        for code, text in cases.items():
            with self.subTest(code=code):
                self.assertIn(text, webcam.failure_message(code, layout, False, registration))
        self.assertIn("2 minutes", webcam.failure_message(None, layout, True, registration))

    def test_a_camera_registered_by_another_program_is_taken_over(self):
        self.register(paths={"softcam64.dll": "C:\\Program Files\\OtherCam\\softcam.dll"})
        self.install_files()
        state = webcam.registration_state(self.layout())
        self.assertEqual(state.problem, "otherProgram")
        self.assertEqual(self.install(elevate=self.elevate()), "installed")
        self.assertNotIn("OtherCam", self.elevations[0][1])  # its DLL is never run elevated

    def test_an_older_orbit_folder_is_recognised_and_restored_if_the_upgrade_fails(self):
        older = webcam.webcam_root() / "0123456789abcdef"
        self.install_files(older)
        self.register(paths={name: str(older / name) for name in webcam.DLL_SHA256})
        self.assertEqual(webcam.registration_state(self.layout()).problem, "olderOrbit")
        self.assertEqual(self.install(elevate=self.elevate()), "installed")
        parameters = self.elevations[0][1]
        self.assertIn(f"if (Test-Path -LiteralPath {webcam.ps_quote(os.path.normpath(str(older / 'softcam64.dll')))} "
                      "-PathType Leaf)", parameters)

    def test_a_missing_category_entry_is_not_registered(self):
        self.install_files()
        self.register(listed=False)
        self.assertEqual(webcam.registration_state(self.layout()).problem, "notListed")

    def test_a_timed_out_script_counts_only_when_the_registry_is_complete(self):
        with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=Mock(side_effect=TimeoutError()))
        self.assertEqual(raised.exception.status, 503)
        self.assertIn("2 minutes", raised.exception.message)

        def slow_but_done(executable, parameters, timeout):
            self.install_files()
            self.register()
            raise TimeoutError()
        self.assertEqual(self.install(elevate=slow_but_done), "installed")

    def test_powershell_missing_or_another_shell_error(self):
        for error, status, text in ((webcam.ElevationFailed(2), 503, "PowerShell was not found"),
                                    (webcam.ElevationFailed(5), 503, "error 5")):
            with self.subTest(code=error.code):
                with self.assertRaises(webcam.InstallError) as raised:
                    self.install(elevate=self.elevate(error=error))
                self.assertEqual(raised.exception.status, status)
                self.assertIn(text, raised.exception.message)


class UninstallFlowTests(WindowsEnvironment):
    def setUp(self):
        super().setUp()
        self.stages = []
        self.elevations = []
        self.camera = Mock()

    def elevate(self, code=0, unregister=True, delete_files=True, error=None):
        def run(executable, parameters, timeout):
            self.elevations.append((executable, parameters, timeout))
            if error is not None:
                raise error
            if unregister:
                self.unregister()
            if delete_files and webcam.webcam_root().exists():
                shutil.rmtree(webcam.webcam_root())
            return code
        return run

    def uninstall(self, **kwargs):
        return webcam.uninstall_webcam(progress=self.stages.append, camera=self.camera, **kwargs)

    def test_a_pc_without_orbits_webcam_needs_no_prompt(self):
        self.assertEqual(self.uninstall(elevate=Mock(side_effect=AssertionError("no prompt"))), "notInstalled")
        self.register(paths={name: "C:\\Program Files\\OtherCam\\softcam.dll" for name in webcam.DLL_SHA256})
        self.assertEqual(self.uninstall(elevate=Mock(side_effect=AssertionError("no prompt"))), "notInstalled")
        self.notify.assert_not_called()
        self.camera.end_all.assert_not_called()

    def test_removal_unregisters_with_one_prompt_and_ends_the_phones(self):
        self.install_files()
        self.register()
        self.assertEqual(self.uninstall(elevate=self.elevate()), "uninstalled")
        self.assertEqual(len(self.elevations), 1)
        executable, parameters, _timeout = self.elevations[0]
        self.assertEqual(executable, self.layout().powershell)
        self.assertIn("orbit-webcam-uninstall", parameters)
        self.assertEqual(parameters.count("/u /s"), 2)
        self.assertEqual(self.stages, ["preparing", "waitingForApproval", "verifying"])
        error = self.camera.end_all.call_args.args[0]
        self.assertEqual((error.code, error.close_code), ("notInstalled", webcam.CLOSE_NOT_INSTALLED))
        titles = [call.args[0] for call in self.notify.call_args_list]
        self.assertEqual(titles, ["Approve removing the webcam", "iPhone webcam removed"])
        self.assertFalse(webcam.webcam_files_left())

    def test_another_programs_view_is_left_alone(self):
        self.install_files()
        self.register(paths={"softcam64.dll": "C:\\Program Files\\OtherCam\\softcam.dll"})
        seen = []

        def only_32(executable, parameters, timeout):
            seen.append(parameters)
            self.registry.delete_tree(webcam.KEY_WOW64_32KEY, "SOFTWARE\\Classes\\CLSID\\" + webcam.CLSID)
            return 0
        self.assertEqual(self.uninstall(elevate=only_32), "uninstalled")
        self.assertNotIn("OtherCam", seen[0])
        self.assertEqual(seen[0].count("/u /s"), 1)
        self.assertEqual(webcam.registration_state(self.layout()).paths["softcam64.dll"],
                         "C:\\Program Files\\OtherCam\\softcam.dll")

    def test_leftover_files_alone_are_removed_with_a_prompt(self):
        self.install_files()
        self.assertEqual(self.uninstall(elevate=self.elevate(unregister=False)), "uninstalled")
        self.assertNotIn("regsvr32", self.elevations[0][1])

    def test_files_still_in_use_are_reported(self):
        self.install_files()
        self.register()
        self.assertEqual(self.uninstall(elevate=self.elevate(code=50, delete_files=False)), "uninstalled")
        self.assertTrue(webcam.webcam_files_left())
        self.assertIn("still in use", self.notify.call_args_list[-1].args[1])

    def test_declining_or_a_failed_removal_changes_nothing_and_says_why(self):
        self.install_files()
        self.register()
        with self.assertRaises(webcam.InstallError) as raised:
            self.uninstall(elevate=self.elevate(error=webcam.ElevationDeclined()))
        self.assertEqual(raised.exception.status, 403)
        self.assertIn("not removed", raised.exception.message)
        for code, text in ((63, "softcam64.dll, regsvr32 error 3"), (75, "softcam32.dll, regsvr32 error 5"),
                           (90, "script failed"), (0, "still lists")):
            with self.subTest(code=code), self.assertLogs("orbit.webcam", "WARNING"):
                with self.assertRaises(webcam.InstallError) as raised:
                    self.uninstall(elevate=self.elevate(code=code, unregister=False, delete_files=False))
                self.assertEqual(raised.exception.status, 503)
                self.assertIn(text, raised.exception.message)
        self.camera.end_all.assert_not_called()
        self.assertTrue(webcam.registration_state(self.layout()).ok)

    def test_windows_on_arm_is_refused(self):
        with patch.object(webcam, "_native_machine_from_windows", return_value="arm64"):
            with self.assertRaises(webcam.InstallError) as raised:
                self.uninstall(elevate=Mock(side_effect=AssertionError("no prompt")))
        self.assertEqual(raised.exception.status, 409)


class InstallerTests(unittest.TestCase):
    def test_one_setup_at_a_time_and_callers_share_it(self):
        release = threading.Event()
        calls = []

        def runner(progress):
            calls.append(1)
            progress("waitingForApproval")
            release.wait(5)
            return "installed"
        installer = webcam.Installer(runner)
        first = installer.start()
        self.assertTrue(wait_until(lambda: installer.stage == "waitingForApproval"))
        self.assertIs(installer.start(), first)
        self.assertTrue(installer.installing)
        self.assertFalse(installer.uninstalling)
        release.set()
        self.assertEqual(first.result(5), "installed")
        self.assertEqual(calls, [1])
        self.assertFalse(installer.installing)
        self.assertIsNone(installer.stage)

    def test_setup_and_removal_never_run_together(self):
        release = threading.Event()

        def runner(progress):
            release.wait(5)
            return "installed"
        installer = webcam.Installer(runner, Mock(return_value="uninstalled"))
        first = installer.start("install")
        with self.assertRaises(webcam.InstallError) as raised:
            installer.start("uninstall")
        self.assertEqual(raised.exception.status, 409)
        self.assertEqual(raised.exception.message, webcam.BUSY_MESSAGES["install"])
        release.set()
        self.assertEqual(first.result(5), "installed")
        removal = installer.start("uninstall")
        self.assertEqual(removal.result(5), "uninstalled")
        self.assertFalse(installer.uninstalling)
        with self.assertRaises(ValueError):
            installer.start("reboot")

    def test_a_failure_is_remembered_until_the_next_setup(self):
        installer = webcam.Installer(Mock(side_effect=webcam.InstallError(403, "Declined.")))
        with self.assertRaises(webcam.InstallError):
            installer.start().result(5)
        self.assertEqual(installer.last_error, "Declined.")
        installer._runner = Mock(return_value="installed")
        self.assertEqual(installer.start().result(5), "installed")
        self.assertIsNone(installer.last_error)

    def test_unexpected_errors_become_a_plain_message(self):
        installer = webcam.Installer(Mock(side_effect=RuntimeError("boom")), Mock(side_effect=RuntimeError("boom")))
        for operation, text in (("install", "setup"), ("uninstall", "removal")):
            with self.subTest(operation=operation), self.assertLogs("orbit.webcam", "ERROR"):
                with self.assertRaises(webcam.InstallError) as raised:
                    installer.start(operation).result(5)
                self.assertEqual(raised.exception.status, 503)
                self.assertNotIn("boom", raised.exception.message)
                self.assertIn(text, raised.exception.message)


# Frames ------------------------------------------------------------------------------------------

class FrameTests(unittest.TestCase):
    def pixel(self, bgr, width, x, y):
        offset = (y * width + x) * 3
        return tuple(bgr[offset:offset + 3])

    def assertClose(self, actual, expected, tolerance=12):
        self.assertTrue(all(abs(a - b) <= tolerance for a, b in zip(actual, expected)), (actual, expected))

    def test_same_size_frames_become_top_down_bgr(self):
        def halves(image):
            image.paste((0, 0, 255), (0, 360, 1280, 720))
        bgr = webcam.jpeg_to_bgr(make_jpeg((1280, 720), (255, 0, 0), painter=halves), 1280, 720)
        self.assertEqual(len(bgr), 1280 * 720 * 3)
        self.assertClose(self.pixel(bgr, 1280, 10, 10), (0, 0, 255))      # red, as B G R
        self.assertClose(self.pixel(bgr, 1280, 10, 710), (255, 0, 0))     # blue at the bottom

    def test_another_aspect_ratio_is_letterboxed(self):
        bgr = webcam.jpeg_to_bgr(make_jpeg((640, 480), (0, 200, 0)), 1280, 720)
        self.assertEqual(len(bgr), 1280 * 720 * 3)
        self.assertEqual(self.pixel(bgr, 1280, 50, 360), (0, 0, 0))       # left bar
        self.assertEqual(self.pixel(bgr, 1280, 1230, 360), (0, 0, 0))     # right bar
        self.assertClose(self.pixel(bgr, 1280, 640, 360), (0, 200, 0))
        self.assertClose(self.pixel(bgr, 1280, 170, 360), (0, 200, 0))    # bars are (1280 - 960) / 2 wide

    def test_bigger_frames_are_scaled_down(self):
        bgr = webcam.jpeg_to_bgr(make_jpeg((1920, 1080), (10, 20, 240)), 1280, 720)
        self.assertEqual(len(bgr), 1280 * 720 * 3)
        self.assertClose(self.pixel(bgr, 1280, 640, 360), (240, 20, 10))
        small = webcam.jpeg_to_bgr(make_jpeg((3840, 2160), (10, 20, 240)), 640, 360)
        self.assertEqual(len(small), 640 * 360 * 3)

    def test_grayscale_and_cmyk_jpegs_work(self):
        gray = webcam.jpeg_to_bgr(make_jpeg((320, 240), 128, mode="L"), 320, 240)
        self.assertClose(self.pixel(gray, 320, 5, 5), (128, 128, 128))
        cmyk = webcam.jpeg_to_bgr(make_jpeg((320, 240), (0, 0, 0, 0), mode="CMYK"), 320, 240)
        self.assertEqual(len(cmyk), 320 * 240 * 3)

    def test_anything_else_is_refused(self):
        jpeg = make_jpeg((320, 240))
        cases = {"png": make_jpeg((320, 240), image_format="PNG"), "garbage": b"\xff\xd8\xff\xe0" + b"\x00" * 64,
                 "truncated": jpeg[:len(jpeg) // 3], "tiny": make_jpeg((8, 8)), "empty": b""}
        for label, data in cases.items():
            with self.subTest(label=label), self.assertRaises(webcam.FrameError):
                webcam.jpeg_to_bgr(data, 320, 240)

    def test_frames_over_8_megapixels_are_refused_before_decoding(self):
        data = make_jpeg((4000, 2200), quality=10)
        with patch.object(Image.Image, "load", side_effect=AssertionError("decoded")):
            with self.assertRaises(webcam.FrameError):
                webcam.jpeg_to_bgr(data, 1280, 720)


# Softcam binding ---------------------------------------------------------------------------------

class SoftcamLibraryTests(unittest.TestCase):
    def callbacks(self):
        """Real C function pointers, so ctypes marshals arguments exactly as for the DLL."""
        seen = {"frames": [], "deleted": [], "waits": []}
        size = {"bytes": 0}

        @ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_float)
        def create(width, height, framerate):
            seen["create"] = (width, height, framerate)
            size["bytes"] = width * height * 3
            return 0 if width == 0 else 0x5C0F1

        @ctypes.CFUNCTYPE(None, ctypes.c_void_p)
        def delete(camera):
            seen["deleted"].append(camera)

        @ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)
        def send(camera, bits):
            seen["frames"].append((camera, ctypes.string_at(bits, size["bytes"])))

        @ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_float)
        def wait(camera, timeout):
            seen["waits"].append(timeout)
            return True

        @ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p)
        def connected(camera):
            return camera == 0x5C0F1

        dll = type("FakeSoftcam", (), {})()
        for name, function in (("scCreateCamera", create), ("scDeleteCamera", delete), ("scSendFrame", send),
                               ("scWaitForConnection", wait), ("scIsConnected", connected)):
            setattr(dll, name, function)
        return dll, seen

    def test_prototypes_match_softcam_h(self):
        dll = MagicMock()
        webcam.SoftcamLibrary(dll)
        self.assertEqual(dll.scCreateCamera.argtypes, [ctypes.c_int, ctypes.c_int, ctypes.c_float])
        self.assertEqual(dll.scCreateCamera.restype, ctypes.c_void_p)
        self.assertEqual(dll.scDeleteCamera.argtypes, [ctypes.c_void_p])
        self.assertIsNone(dll.scDeleteCamera.restype)
        self.assertEqual(dll.scSendFrame.argtypes, [ctypes.c_void_p, ctypes.c_void_p])
        self.assertIsNone(dll.scSendFrame.restype)
        self.assertEqual(dll.scWaitForConnection.argtypes, [ctypes.c_void_p, ctypes.c_float])
        self.assertEqual(dll.scWaitForConnection.restype, ctypes.c_bool)
        self.assertEqual(dll.scIsConnected.argtypes, [ctypes.c_void_p])
        self.assertEqual(dll.scIsConnected.restype, ctypes.c_bool)

    def test_calls_marshal_like_the_dll(self):
        dll, seen = self.callbacks()
        library = webcam.SoftcamLibrary(dll)
        camera = library.create(8, 4, 30)
        self.assertEqual(camera, 0x5C0F1)
        self.assertEqual(seen["create"], (8, 4, 30.0))
        frame = bytes(range(96))
        library.send(camera, frame)
        self.assertEqual(seen["frames"], [(0x5C0F1, frame)])
        self.assertTrue(library.is_connected(camera))
        self.assertTrue(library.wait_for_connection(camera, 0.5))
        self.assertEqual(seen["waits"], [0.5])
        library.delete(camera)
        self.assertEqual(seen["deleted"], [0x5C0F1])
        self.assertIsNone(library.create(0, 4, 30))  # NULL handle

    def test_loading_uses_cdll_with_the_full_path(self):
        dll = MagicMock()
        with patch.object(webcam.ctypes, "CDLL", return_value=dll) as cdll:
            library = webcam.SoftcamLibrary.load(Path("C:/Program Files/Orbit/Webcam/x/softcam64.dll"))
        cdll.assert_called_once_with(str(Path("C:/Program Files/Orbit/Webcam/x/softcam64.dll")))
        self.assertIsInstance(library, webcam.SoftcamLibrary)


class SenderLibraryTests(WindowsEnvironment):
    def setUp(self):
        super().setUp()
        patcher = patch.object(webcam, "_LIBRARY", None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_only_the_verified_installed_dll_of_this_bitness_is_loaded(self):
        with self.assertRaises(webcam.CameraError) as raised:
            webcam.load_sender_library()
        self.assertEqual(raised.exception.code, "notInstalled")
        self.install_files()
        with patch.object(webcam.SoftcamLibrary, "load", return_value="library") as load:
            self.assertEqual(webcam.load_sender_library(), "library")
            self.assertEqual(webcam.load_sender_library(), "library")
        load.assert_called_once_with(self.folder() / "softcam64.dll")

    def test_a_dll_windows_cannot_load_is_explained(self):
        self.install_files()
        with patch.object(webcam.SoftcamLibrary, "load", side_effect=OSError("[WinError 126]")):
            with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.CameraError) as raised:
                webcam.load_sender_library()
        self.assertEqual(raised.exception.code, "cameraUnavailable")
        self.assertIn("Visual C++", raised.exception.message)


# Camera worker -----------------------------------------------------------------------------------

class FakeLibrary:
    """Softcam as the worker sees it. `hold` is how long scCreateCamera keeps failing after a delete,
    like Softcam while an app's filter still maps the old camera's shared memory."""

    def __init__(self):
        self.created, self.deleted, self.frames = [], [], []
        self.connected = False
        self.refuse = False
        self.hold = 0.0
        self.deleted_at = None
        self.create_calls = 0
        self.handle = 0x5C0F0
        self.lock = threading.Lock()

    def create(self, width, height, fps):
        with self.lock:
            self.create_calls += 1
            if self.refuse or (self.deleted_at is not None and time.monotonic() - self.deleted_at < self.hold):
                return None
            self.handle += 1
            self.created.append((width, height, fps, self.handle))
            return self.handle

    def delete(self, camera):
        with self.lock:
            self.deleted.append(camera)
            self.deleted_at = time.monotonic()

    def send(self, camera, bgr):
        self.frames.append((camera, bgr))

    def is_connected(self, camera):
        return self.connected


class Ended:
    """An on_ended callback that remembers the CameraError it got."""

    def __init__(self):
        self.errors = []
        self.event = threading.Event()

    def __call__(self, error):
        self.errors.append(error)
        self.event.set()


class CameraManagerTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("GRACE_SECONDS", 0.15), ("CONNECTION_POLL_SECONDS", 0.02), ("CREATE_RETRY_SECONDS", 0.3),
                            ("CREATE_RETRY_INTERVAL", 0.01)):
            patcher = patch.object(webcam, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.library = FakeLibrary()
        self.events = []
        self.manager = webcam.CameraManager(library_loader=lambda: self.library, converter=lambda data, w, h: data,
                                            emit=self.events.append)
        self.addCleanup(self.manager.close)

    def start(self, sender, camera_format=(1280, 720, 30), on_ended=None):
        return self.manager.start_sender(sender, camera_format, on_ended).result(3)

    def test_the_first_sender_creates_the_camera_and_announces_it_once(self):
        self.assertEqual(self.start("a"), {"created": True, "width": 1280, "height": 720, "fps": 30})
        self.assertEqual(self.library.created[0][:3], (1280, 720, 30))
        self.assertEqual(self.events, [(1280, 720, 30)])
        self.assertEqual(self.manager.snapshot(), {"active": True, "clients": 1, "width": 1280, "height": 720,
                                                   "fps": 30, "connected": False})

    def test_only_the_newest_frame_waits_while_the_worker_is_busy(self):
        gate = threading.Event()
        converted = []

        def slow(data, width, height):
            converted.append(data)
            if data == b"A":
                gate.wait(3)
            return data
        self.manager._convert = slow
        self.start("a")
        self.manager.submit_frame("a", b"A")
        self.assertTrue(wait_until(lambda: converted == [b"A"]))
        for frame in (b"B", b"C", b"D", b"E"):
            self.manager.submit_frame("a", frame)
        gate.set()
        self.assertTrue(wait_until(lambda: len(self.library.frames) == 2))
        self.assertEqual([frame for _camera, frame in self.library.frames], [b"A", b"E"])
        self.assertEqual(self.manager.stats["dropped"], 3)
        self.assertEqual(self.manager.stats["received"], 5)

    def test_a_reconnect_within_the_grace_period_keeps_the_camera(self):
        self.start("a")
        self.manager.stop_sender("a")
        self.start("b")
        time.sleep(0.3)
        self.assertEqual(self.library.deleted, [])
        self.assertEqual(len(self.library.created), 1)
        self.assertEqual(len(self.events), 1)

    def test_the_camera_is_deleted_after_the_last_sender_left(self):
        self.start("a")
        handle = self.library.created[0][3]
        self.manager.stop_sender("a")
        self.assertTrue(wait_until(lambda: self.library.deleted == [handle]))
        self.assertFalse(self.manager.snapshot()["active"])
        self.start("b")  # a new session is announced again
        self.assertEqual(len(self.events), 2)

    def test_another_format_recreates_the_camera_without_a_second_announcement(self):
        self.start("a")
        self.start("b", (1920, 1080, 30))
        self.assertEqual([c[:3] for c in self.library.created], [(1280, 720, 30), (1920, 1080, 30)])
        self.assertEqual(self.library.deleted, [self.library.created[0][3]])
        self.assertEqual(len(self.events), 1)

    def test_another_format_waits_for_an_app_to_let_go_of_the_old_camera(self):
        self.library.hold = 0.1  # the app's filter notices at its next frame poll
        ended = Ended()
        self.start("a", on_ended=ended)
        self.assertEqual(self.start("b", (1920, 1080, 30))["created"], True)
        self.assertGreater(self.library.create_calls, 2)
        self.assertTrue(ended.event.wait(3))
        self.assertEqual([error.code for error in ended.errors], ["replaced"])
        self.assertEqual(self.manager.snapshot()["clients"], 1)
        self.assertEqual(len(self.events), 1)

    def test_when_a_new_format_cannot_start_every_phone_is_ended_and_the_session_resets(self):
        ended = Ended()
        self.start("a", on_ended=ended)
        self.library.hold = 60  # an app keeps the old camera open (its graph is stopped)
        started = time.monotonic()
        with self.assertRaises(webcam.CameraError) as raised:
            self.start("b", (1920, 1080, 30))
        self.assertGreaterEqual(time.monotonic() - started, 0.25)  # retried for CREATE_RETRY_SECONDS
        self.assertEqual((raised.exception.code, raised.exception.close_code),
                         ("cameraUnavailable", webcam.CLOSE_CAMERA_UNAVAILABLE))
        self.assertEqual(raised.exception.message, webcam.CAMERA_BUSY_MESSAGE)
        self.assertIn("may still have the previous camera open", webcam.CAMERA_BUSY_MESSAGE)
        self.assertTrue(ended.event.wait(3))
        self.assertEqual([(error.code, error.close_code) for error in ended.errors],
                         [("cameraUnavailable", webcam.CLOSE_CAMERA_UNAVAILABLE)])
        snapshot = self.manager.snapshot()
        self.assertEqual((snapshot["active"], snapshot["clients"]), (False, 0))
        self.assertFalse(self.manager.submit_frame("a", b"lost"))
        self.manager.stop_sender("a")  # the ended phone leaving changes nothing
        self.library.hold = 0
        self.assertTrue(self.start("c")["created"])
        self.assertEqual(len(self.events), 2)  # the next camera is a new session

    def test_close_interrupts_the_retries(self):
        self.library.refuse = True
        with patch.object(webcam, "CREATE_RETRY_SECONDS", 30):
            future = self.manager.start_sender("a", (1280, 720, 30))
            self.assertTrue(wait_until(lambda: self.library.create_calls > 0))
            started = time.monotonic()
            self.manager.close()
            with self.assertRaises(webcam.CameraError):
                future.result(3)
        self.assertLess(time.monotonic() - started, 2)

    def test_end_all_ends_every_phone_and_deletes_the_camera(self):
        ended = Ended()
        self.start("a", on_ended=ended)
        removed = webcam.CameraError("notInstalled", webcam.REMOVED_MESSAGE, webcam.CLOSE_NOT_INSTALLED)
        self.manager.end_all(removed).result(3)
        self.assertEqual(ended.errors, [removed])
        self.assertEqual(self.library.deleted, [self.library.created[0][3]])
        self.assertEqual(self.manager.snapshot()["clients"], 0)
        self.start("b")
        self.assertEqual(len(self.events), 2)

    def test_a_newer_sender_replaces_the_older_one(self):
        ended = Ended()
        self.start("a", on_ended=ended)
        self.start("b")
        self.assertTrue(ended.event.wait(3))
        self.assertEqual((ended.errors[0].code, ended.errors[0].close_code), ("replaced", webcam.CLOSE_REPLACED))
        self.assertFalse(self.manager.submit_frame("a", b"old"))
        self.assertTrue(self.manager.submit_frame("b", b"new"))
        self.assertEqual(self.manager.snapshot()["clients"], 1)
        self.manager.stop_sender("a")  # the replaced phone leaving changes nothing
        time.sleep(0.3)
        self.assertEqual(self.library.deleted, [])

    def test_the_app_connection_is_polled(self):
        self.start("a")
        self.assertFalse(self.manager.connected)
        self.library.connected = True
        self.assertTrue(wait_until(lambda: self.manager.connected))

    def test_a_refused_camera_or_missing_dll_fails_the_sender(self):
        self.library.refuse = True
        with self.assertRaises(webcam.CameraError) as raised:
            self.start("a")
        self.assertEqual(raised.exception.code, "cameraUnavailable")
        self.assertEqual(raised.exception.close_code, webcam.CLOSE_CAMERA_UNAVAILABLE)
        manager = webcam.CameraManager(library_loader=Mock(side_effect=webcam.CameraError("notInstalled", "x", 4001)))
        self.addCleanup(manager.close)
        with self.assertRaises(webcam.CameraError) as raised:
            manager.start_sender("a", (640, 480, 30)).result(3)
        self.assertEqual(raised.exception.code, "notInstalled")

    def test_bad_frames_are_counted_not_sent(self):
        self.manager._convert = Mock(side_effect=webcam.FrameError("bad"))
        self.start("a")
        self.manager.submit_frame("a", b"x")
        self.assertTrue(wait_until(lambda: self.manager.stats["bad"] == 1))
        self.assertEqual(self.library.frames, [])

    def test_close_deletes_the_camera(self):
        self.start("a")
        self.manager.close()
        self.assertEqual(self.library.deleted, [self.library.created[0][3]])


# Routes ------------------------------------------------------------------------------------------

def make_app(manager, installer, boot=False, windows=True):
    app = FastAPI()

    def verify(authorization: str = Header(None)):
        if authorization != f"Bearer {TOKEN}":
            raise HTTPException(status_code=401, detail="Invalid Orbit token")

    def require_https(request: Request):
        if request.url.scheme != "https":
            raise HTTPException(status_code=426, detail="Needs HTTPS")

    def require_windows():
        if not windows:
            raise HTTPException(status_code=501, detail="PC controls require Windows")

    app.include_router(webcam.create_webcam_router(verify, require_https, require_windows,
                                                   lambda value: value == f"Bearer {TOKEN}", boot_mode=lambda: boot,
                                                   manager=manager, installer=installer))
    return app


class RouteTests(WindowsEnvironment):
    def setUp(self):
        super().setUp()
        self.manager = webcam.CameraManager(library_loader=FakeLibrary)
        self.addCleanup(self.manager.close)
        self.installer = webcam.Installer(Mock(return_value="installed"), Mock(return_value="uninstalled"))

    def client(self, base_url="https://testserver", **kwargs):
        client = TestClient(make_app(self.manager, self.installer, **kwargs), base_url=base_url)
        self.addCleanup(client.close)
        return client

    def test_status_needs_the_token_and_https(self):
        self.assertEqual(self.client().get("/api/webcam").status_code, 401)
        self.assertEqual(self.client("http://testserver").get("/api/webcam", headers=AUTH).status_code, 426)
        self.assertEqual(self.client(windows=False).get("/api/webcam", headers=AUTH).status_code, 501)

    def test_status_of_a_pc_that_is_not_set_up(self):
        response = self.client().get("/api/webcam", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        body = response.json()
        for key in ("installed", "registered", "active", "clients", "width", "height", "fps", "reason"):
            self.assertIn(key, body)
        self.assertEqual((body["installed"], body["registered"], body["active"], body["clients"]), (False, False, False, 0))
        self.assertEqual((body["installing"], body["uninstalling"]), (False, False))
        self.assertEqual((body["width"], body["height"], body["fps"]), (1280, 720, 30))
        self.assertIn("winget install", body["reason"])  # no runtime in this fake registry
        self.assertEqual(body["runtime"]["missing"], ["x64", "x86"])
        self.assertEqual(body["limits"]["maxWidth"], 1920)
        self.assertEqual(body["cameraName"], "DirectShow Softcam")
        self.set_runtime()
        body = self.client().get("/api/webcam", headers=AUTH).json()
        self.assertEqual(body["reason"], webcam.REGISTRATION_MESSAGES["missing"])

    def test_status_of_a_ready_pc(self):
        self.set_runtime()
        self.install_files()
        self.register()
        body = self.client().get("/api/webcam", headers=AUTH).json()
        self.assertTrue(body["installed"] and body["registered"])
        self.assertIsNone(body["reason"])
        self.assertFalse(body["installing"])
        self.assertIsNone(body["installError"])
        body = self.client(boot=True).get("/api/webcam", headers=AUTH).json()
        self.assertIn("Sign in to Windows", body["reason"])

    def test_install_answers_with_the_result(self):
        response = self.client().post("/api/webcam/install", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "installed")

    def test_install_still_waiting_for_the_prompt_answers_202(self):
        release = threading.Event()

        def runner(progress):
            progress("waitingForApproval")
            release.wait(5)
            return "installed"
        self.installer = webcam.Installer(runner)
        client = self.client()
        with patch.object(webcam, "INSTALL_WAIT_SECONDS", 0.1):
            response = client.post("/api/webcam/install", headers=AUTH)
            self.assertEqual(response.status_code, 202)
            body = response.json()
            self.assertEqual(body["status"], "waitingForApproval")
            self.assertTrue(body["installing"])
            self.assertEqual(body["installStage"], "waitingForApproval")
            self.assertIn("approve the Windows prompt", client.get("/api/webcam", headers=AUTH).json()["reason"])
        release.set()
        self.assertTrue(wait_until(lambda: not self.installer.installing))

    def test_install_errors_keep_their_status_and_sentence(self):
        for error in (webcam.InstallError(403, "The prompt was declined."),
                      webcam.InstallError(409, "Install the Visual C++ runtime.")):
            with self.subTest(status=error.status):
                self.installer = webcam.Installer(Mock(side_effect=error))
                response = self.client().post("/api/webcam/install", headers=AUTH)
                self.assertEqual(response.status_code, error.status)
                self.assertEqual(response.json(), {"detail": error.message})
                self.assertEqual(self.client().get("/api/webcam", headers=AUTH).json()["installError"], error.message)

    def test_install_needs_a_signed_in_windows(self):
        self.assertEqual(self.client(boot=True).post("/api/webcam/install", headers=AUTH).status_code, 409)
        self.assertEqual(self.client(windows=False).post("/api/webcam/install", headers=AUTH).status_code, 501)
        self.assertEqual(self.client("http://testserver").post("/api/webcam/install", headers=AUTH).status_code, 426)
        self.assertEqual(self.client().post("/api/webcam/install").status_code, 401)
        self.installer._runner.assert_not_called()

    def test_uninstall_answers_with_the_result_and_whether_files_are_left(self):
        response = self.client().post("/api/webcam/uninstall", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        body = response.json()
        self.assertEqual((body["status"], body["filesLeft"]), ("uninstalled", False))
        self.assertIn("registered", body)
        self.install_files()  # a DLL that an open app still has loaded
        self.installer._uninstaller.return_value = "uninstalled"
        self.assertTrue(self.client().post("/api/webcam/uninstall", headers=AUTH).json()["filesLeft"])

    def test_uninstall_still_waiting_for_the_prompt_answers_202(self):
        release = threading.Event()

        def uninstaller(progress):
            progress("waitingForApproval")
            release.wait(5)
            return "uninstalled"
        self.installer = webcam.Installer(Mock(return_value="installed"), uninstaller)
        client = self.client()
        with patch.object(webcam, "INSTALL_WAIT_SECONDS", 0.1):
            response = client.post("/api/webcam/uninstall", headers=AUTH)
            self.assertEqual(response.status_code, 202)
            body = response.json()
            self.assertEqual((body["status"], body["uninstalling"], body["installing"]),
                             ("waitingForApproval", True, False))
            self.assertIn("approve the Windows prompt", client.get("/api/webcam", headers=AUTH).json()["reason"])
            # A setup meanwhile is refused, never a second prompt.
            conflict = client.post("/api/webcam/install", headers=AUTH)
            self.assertEqual(conflict.status_code, 409)
            self.assertEqual(conflict.json(), {"detail": webcam.BUSY_MESSAGES["uninstall"]})
        release.set()
        self.assertTrue(wait_until(lambda: not self.installer.uninstalling))

    def test_uninstall_errors_and_guards(self):
        self.installer = webcam.Installer(Mock(), Mock(side_effect=webcam.InstallError(403, "Declined.")))
        response = self.client().post("/api/webcam/uninstall", headers=AUTH)
        self.assertEqual((response.status_code, response.json()), (403, {"detail": "Declined."}))
        self.assertEqual(self.client().get("/api/webcam", headers=AUTH).json()["installError"], "Declined.")
        self.installer._uninstaller.reset_mock()
        self.assertEqual(self.client(boot=True).post("/api/webcam/uninstall", headers=AUTH).status_code, 409)
        self.assertEqual(self.client(windows=False).post("/api/webcam/uninstall", headers=AUTH).status_code, 501)
        self.assertEqual(self.client("http://testserver").post("/api/webcam/uninstall", headers=AUTH).status_code, 426)
        self.assertEqual(self.client().post("/api/webcam/uninstall").status_code, 401)
        self.installer._uninstaller.assert_not_called()


# /ws/camera ----------------------------------------------------------------------------------------

WSS = "wss://testserver/ws/camera"
HELLO = json.dumps({"width": 640, "height": 360, "fps": 30})


class CameraSocketTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("GRACE_SECONDS", 0.15), ("CONNECTION_POLL_SECONDS", 0.02), ("STATUS_INTERVAL", 0.02),
                            ("HELLO_TIMEOUT", 2.0), ("CREATE_RETRY_SECONDS", 0.2), ("CREATE_RETRY_INTERVAL", 0.01)):
            patcher = patch.object(webcam, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.ready = patch.object(webcam, "sender_readiness", return_value=None)
        self.readiness = self.ready.start()
        self.addCleanup(self.ready.stop)
        self.library = FakeLibrary()
        self.events = []
        self.manager = webcam.CameraManager(library_loader=lambda: self.library, emit=self.events.append)
        self.addCleanup(self.manager.close)
        self.client = TestClient(make_app(self.manager, webcam.Installer(Mock())), base_url="https://testserver")
        self.addCleanup(self.client.close)

    def connect(self, url=WSS, headers=AUTH):
        return self.client.websocket_connect(url, headers=headers)

    def read_json(self, socket):
        return json.loads(socket.receive_text())

    def read_until(self, socket, key):
        for _ in range(200):
            message = self.read_json(socket)
            if key in message:
                return message
        self.fail(f"no {key} message")

    def closed_with(self, socket):
        with self.assertRaises(WebSocketDisconnect) as raised:
            for _ in range(200):
                socket.receive_text()
        return raised.exception.code

    def test_tokens_in_the_url_plain_ws_and_wrong_tokens_are_refused_before_the_handshake(self):
        attempts = ((f"{WSS}?token={TOKEN}", AUTH), (f"{WSS}?access_token={TOKEN}", {}), (WSS, {}),
                    (WSS, {"Authorization": "Bearer wrong"}), ("/ws/camera", AUTH), ("ws://testserver/ws/camera", AUTH))
        for url, headers in attempts:
            with self.subTest(url=url, headers=headers):
                with self.assertRaises(WebSocketDisconnect) as raised:
                    with self.connect(url, headers):
                        pass
                self.assertEqual(raised.exception.code, 1008)
        self.assertEqual(self.library.created, [])

    def test_hello_ready_status_and_frames(self):
        with self.connect() as socket:
            socket.send_text(HELLO)
            self.assertEqual(self.read_json(socket), {"ready": True, "width": 640, "height": 360, "fps": 30,
                                                      "cameraName": "DirectShow Softcam"})
            self.assertEqual(self.read_json(socket), {"connected": False})
            self.assertEqual(self.library.created[0][:3], (640, 360, 30))
            socket.send_bytes(make_jpeg((1280, 720), (255, 0, 0)))
            self.assertTrue(wait_until(lambda: len(self.library.frames) == 1))
            camera, bgr = self.library.frames[0]
            self.assertEqual(len(bgr), 640 * 360 * 3)
            self.assertLess(bgr[0], 20)
            self.assertGreater(bgr[2], 230)
            self.library.connected = True
            self.assertEqual(self.read_until(socket, "connected"), {"connected": True})
        self.assertEqual(self.events, [(640, 360, 30)])
        self.assertTrue(wait_until(lambda: self.library.deleted == [camera]))

    def test_invalid_hellos_are_explained_then_closed(self):
        cases = ({"width": 642, "height": 360, "fps": 30}, {"width": 1924, "height": 1080, "fps": 30},
                 {"width": 1920, "height": 1084, "fps": 30}, {"width": 156, "height": 120, "fps": 30},
                 {"width": 640, "height": 360, "fps": 14}, {"width": 640, "height": 360, "fps": 31},
                 {"width": 640, "height": 360, "fps": 29.97}, {"width": True, "height": 360, "fps": 30},
                 {"width": "640", "height": 360, "fps": 30}, {"height": 360, "fps": 30}, [640, 360, 30])
        for hello in cases:
            with self.subTest(hello=hello), self.connect() as socket:
                socket.send_text(json.dumps(hello))
                message = self.read_json(socket)
                self.assertEqual(message["code"], "badHello")
                self.assertTrue(message["error"].endswith("."))
                self.assertEqual(self.closed_with(socket), 1008)
        for text in ("not json", '{"width": NaN, "height": 360, "fps": 30}'):
            with self.subTest(text=text), self.connect() as socket:
                socket.send_text(text)
                self.assertEqual(self.read_json(socket)["code"], "badHello")
        self.assertEqual(self.library.created, [])

    def test_frames_before_the_hello_a_long_hello_and_no_hello(self):
        with self.connect() as socket:
            socket.send_bytes(make_jpeg((64, 64)))
            self.assertEqual(self.read_json(socket)["code"], "badHello")
            self.assertEqual(self.closed_with(socket), 1008)
        with self.connect() as socket:
            socket.send_text(" " * (webcam.MAX_HELLO_CHARS + 1))
            self.assertEqual(self.read_json(socket)["code"], "badHello")
            self.assertEqual(self.closed_with(socket), 1009)
        with patch.object(webcam, "HELLO_TIMEOUT", 0.1), self.connect() as socket:
            self.assertEqual(self.read_json(socket)["code"], "badHello")
            self.assertEqual(self.closed_with(socket), 1008)

    def test_frames_must_be_jpeg_and_not_too_big(self):
        with self.connect() as socket:
            socket.send_text(HELLO)
            self.read_until(socket, "ready")
            socket.send_bytes(make_jpeg((64, 64), image_format="PNG"))
            self.assertEqual(self.read_until(socket, "error")["code"], "badFrame")
            self.assertEqual(self.closed_with(socket), 1003)
        with patch.object(webcam, "MAX_FRAME_BYTES", 1000), self.connect() as socket:
            socket.send_text(HELLO)
            self.read_until(socket, "ready")
            socket.send_bytes(b"\xff\xd8\xff" + b"\x00" * 1000)
            self.assertEqual(self.read_until(socket, "error")["code"], "frameTooLarge")
            self.assertEqual(self.closed_with(socket), 1009)

    def test_a_pc_that_is_not_ready_says_why(self):
        self.readiness.return_value = ("notInstalled", webcam.REGISTRATION_MESSAGES["missing"], 4001)
        with self.connect() as socket:
            self.assertEqual(self.read_json(socket), {"error": webcam.REGISTRATION_MESSAGES["missing"],
                                                      "code": "notInstalled"})
            self.assertEqual(self.closed_with(socket), 4001)
        self.assertEqual(self.library.created, [])

    def test_not_windows_and_an_unavailable_camera(self):
        client = TestClient(make_app(self.manager, webcam.Installer(Mock()), windows=False), base_url="https://testserver")
        self.addCleanup(client.close)
        with client.websocket_connect(WSS, headers=AUTH) as socket:
            self.assertEqual(self.read_json(socket)["code"], "unsupported")
            self.assertEqual(self.closed_with(socket), 4004)
        self.library.refuse = True
        with self.connect() as socket:
            socket.send_text(HELLO)
            self.assertEqual(self.read_json(socket), {"error": webcam.CAMERA_BUSY_MESSAGE, "code": "cameraUnavailable"})
            self.assertEqual(self.closed_with(socket), 4003)

    def test_a_new_format_that_cannot_start_ends_both_phones(self):
        with self.connect() as first:
            first.send_text(HELLO)
            self.read_until(first, "ready")
            self.library.hold = 60  # an app keeps the 640x360 camera open
            with self.connect() as second:
                second.send_text(json.dumps({"width": 1280, "height": 720, "fps": 30}))
                self.assertEqual(self.read_until(second, "error")["code"], "cameraUnavailable")
                self.assertEqual(self.closed_with(second), 4003)
            message = self.read_until(first, "error")
            self.assertEqual(message, {"error": webcam.CAMERA_BUSY_MESSAGE, "code": "cameraUnavailable"})
            self.assertEqual(self.closed_with(first), 4003)
        self.assertEqual(self.manager.snapshot()["clients"], 0)

    def test_removing_the_webcam_closes_the_phone_with_4001(self):
        with self.connect() as socket:
            socket.send_text(HELLO)
            self.read_until(socket, "ready")
            self.manager.end_all(webcam.CameraError("notInstalled", webcam.REMOVED_MESSAGE, webcam.CLOSE_NOT_INSTALLED))
            self.assertEqual(self.read_until(socket, "error"), {"error": webcam.REMOVED_MESSAGE, "code": "notInstalled"})
            self.assertEqual(self.closed_with(socket), 4001)
        self.assertEqual(self.library.deleted, [self.library.created[0][3]])

    def test_a_newer_connection_takes_over(self):
        with self.connect() as first:
            first.send_text(HELLO)
            self.read_until(first, "ready")
            with self.connect() as second:
                second.send_text(HELLO)
                self.read_until(second, "ready")
                message = self.read_until(first, "error")
                self.assertEqual(message["code"], "replaced")
                self.assertEqual(self.closed_with(first), 4002)
                second.send_bytes(make_jpeg((640, 360)))
                self.assertTrue(wait_until(lambda: len(self.library.frames) == 1))
        self.assertEqual(len(self.library.created), 1)
        self.assertEqual(len(self.events), 1)


class ReadinessTests(WindowsEnvironment):
    def test_sender_readiness(self):
        self.assertEqual(webcam.sender_readiness(boot_mode=True)[0], "unsupported")
        self.assertEqual(webcam.sender_readiness()[:2], ("notInstalled", webcam.REGISTRATION_MESSAGES["missing"]))
        self.install_files()
        self.register(paths={"softcam32.dll": "C:\\Other\\softcam.dll"})
        self.assertEqual(webcam.sender_readiness()[1], webcam.REGISTRATION_MESSAGES["otherProgram"])
        self.register()
        self.assertIsNone(webcam.sender_readiness())
        with patch.object(webcam, "_native_machine_from_windows", return_value="arm64"):
            self.assertEqual(webcam.sender_readiness()[2], webcam.CLOSE_UNSUPPORTED_PC)


if __name__ == "__main__":
    unittest.main()
