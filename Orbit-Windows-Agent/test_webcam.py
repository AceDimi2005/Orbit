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
    def __init__(self, values):
        self.values = values

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeRegistry:
    """HKLM only, with separate 64-bit and 32-bit views like Windows (KEY_WOW64_64KEY / 32KEY)."""
    HKEY_LOCAL_MACHINE = 0x80000002
    KEY_READ = 0x20019

    def __init__(self):
        self.keys = {}
        self.opened = []

    def set(self, view, path, name, value):
        self.keys.setdefault((view, path.lower()), {})[name.lower()] = value

    def create(self, view, path):
        self.keys.setdefault((view, path.lower()), {})

    def OpenKey(self, root, path, reserved=0, access=0):
        assert root == self.HKEY_LOCAL_MACHINE
        assert access & self.KEY_READ == self.KEY_READ
        view = access & 0x300
        self.opened.append((view, path))
        values = self.keys.get((view, path.lower()))
        if values is None:
            raise FileNotFoundError(2, "The system cannot find the file specified")
        return FakeKey(values)

    def QueryValueEx(self, key, name):
        if name.lower() not in key.values:
            raise FileNotFoundError(2, "The system cannot find the file specified")
        return key.values[name.lower()], 1


class WindowsEnvironment(unittest.TestCase):
    """A pretend x64 Windows: temporary ProgramData, SystemRoot and LocalAppData, a fake registry."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.program_data = self.root / "ProgramData"
        self.system_root = self.root / "Windows"
        self.local = self.root / "Local"
        for folder in (self.program_data, self.system_root, self.local):
            folder.mkdir()
        environment = {"PROGRAMDATA": str(self.program_data), "SystemRoot": str(self.system_root),
                       "LOCALAPPDATA": str(self.local)}
        self.registry = FakeRegistry()
        for patcher in (patch.dict(os.environ, environment),
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

    def install_files(self):
        folder = self.folder()
        folder.mkdir(parents=True, exist_ok=True)
        for name in webcam.DLL_SHA256:
            shutil.copyfile(WEBCAM_DIR / name, folder / name)

    def register(self, paths=None, listed=True):
        folder = self.folder()
        for target in self.layout().targets:
            value = (paths or {}).get(target.name, str(folder / target.name))
            self.registry.set(target.view, webcam.INPROC_KEY, "", value)
            self.registry.set(target.view, webcam.INPROC_KEY, "ThreadingModel", "Both")
            if listed:
                self.registry.set(target.view, webcam.CATEGORY_INSTANCE_KEY, "FriendlyName", webcam.CAMERA_NAME)


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
        with patch.dict(os.environ, {"PROGRAMDATA": "/pd"}):
            self.assertEqual(webcam.install_directory(), Path("/pd") / "Orbit" / "Webcam" / expected)


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

class SourceTests(WindowsEnvironment):
    def test_bundled_dlls_are_used_without_any_download(self):
        download = Mock(side_effect=AssertionError("no download"))
        sources = webcam.ensure_sources(self.layout(), download)
        self.assertEqual(sources, {name: WEBCAM_DIR / name for name in ("softcam64.dll", "softcam32.dll")})

    def test_a_missing_bundled_dll_is_downloaded_from_the_trusted_raw_url_and_cached(self):
        fetch = Mock(side_effect=lambda url, **kwargs: (WEBCAM_DIR / url.rsplit("/", 1)[1]).read_bytes())
        empty = self.root / "agent-without-dlls"
        empty.mkdir()
        with patch.object(webcam, "bundled_directories", return_value=[empty]):
            sources = webcam.ensure_sources(self.layout(), lambda name: webcam.download_dll(name, fetch=fetch))
            cache = webcam.cache_directory()
            self.assertEqual(sources["softcam64.dll"], cache / "softcam64.dll")
            self.assertTrue(webcam.is_verified(cache / "softcam32.dll", "softcam32.dll", use_cache=False))
            urls = [call.args[0] for call in fetch.call_args_list]
            self.assertEqual(urls, ["https://raw.githubusercontent.com/AceDimi2005/Orbit/main/Orbit-Windows-Agent/webcam/"
                                    + name for name in ("softcam64.dll", "softcam32.dll")])
            for call in fetch.call_args_list:
                orbit_updater.validate_github_url(call.args[0])
                self.assertEqual(call.kwargs["accept"], "application/octet-stream")
            fetch.reset_mock()
            webcam.ensure_sources(self.layout(), lambda name: webcam.download_dll(name, fetch=fetch))
            fetch.assert_not_called()  # the cache is reused

    def test_a_download_with_another_hash_is_refused_and_not_kept(self):
        fetch = Mock(return_value=b"MZ not the pinned build")
        with self.assertRaises(webcam.InstallError) as raised:
            webcam.download_dll("softcam64.dll", fetch=fetch)
        self.assertEqual(raised.exception.status, 503)
        self.assertIn("different version", raised.exception.message)
        self.assertFalse((webcam.cache_directory() / "softcam64.dll").exists())

    def test_download_failures_are_explained(self):
        cases = ((urllib.error.HTTPError("u", 404, "Not Found", {}, None), "HTTP 404"),
                 (urllib.error.URLError("offline"), "internet connection"), (TimeoutError("slow"), "internet connection"))
        for error, text in cases:
            with self.subTest(error=error):
                with self.assertRaises(webcam.InstallError) as raised:
                    webcam.download_dll("softcam32.dll", fetch=Mock(side_effect=error))
                self.assertEqual(raised.exception.status, 503)
                self.assertIn(text, raised.exception.message)

    def test_precopy_copies_verified_files_and_reports_what_it_could_not_copy(self):
        folder = self.folder()
        sources = {name: WEBCAM_DIR / name for name in webcam.DLL_SHA256}
        self.assertEqual(webcam.precopy(sources, folder), [])
        self.assertTrue(webcam.files_installed(self.layout(), folder))
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["softcam32.dll", "softcam64.dll"])
        with patch.object(webcam.os, "replace", side_effect=PermissionError("protected")):
            (folder / "softcam32.dll").write_bytes(b"damaged")
            self.assertEqual(webcam.precopy(sources, folder), ["softcam32.dll"])
        self.assertFalse(any(p.name.endswith(".tmp") for p in folder.iterdir()))


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


class ScriptTests(WindowsEnvironment):
    def script(self, layout=None, sources=None):
        layout = layout or self.layout()
        sources = sources or {target.name: WEBCAM_DIR / target.name for target in layout.targets}
        return webcam.elevation_script(layout, self.folder(), sources)

    def test_the_script_protects_the_folder_verifies_hashes_and_registers_both_views(self):
        script = self.script()
        statements = script.split("; ")
        root, folder = str(self.program_data / "Orbit"), str(self.folder())
        icacls = webcam.ps_quote(os.path.join(str(self.system_root), "System32", "icacls.exe"))
        self.assertEqual(statements[0], "trap { exit 90 }")
        self.assertIn(f"& {icacls} '{root}' /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null", statements)
        self.assertIn(f"& {icacls} '{root}' /reset /T /C /Q 2>&1 | Out-Null", statements)
        protect = next(s for s in statements if "/inheritance:r" in s)
        for grant in ("'*S-1-5-18:(OI)(CI)F'", "'*S-1-5-32-544:(OI)(CI)F'", "'*S-1-5-32-545:(OI)(CI)RX'",
                      "'*S-1-15-2-1:(OI)(CI)RX'", "'*S-1-15-2-2:(OI)(CI)RX'"):
            self.assertIn(grant, protect)
        self.assertNotIn(" /T ", protect)  # the children inherit from the protected root
        for name, digest in GIVEN_PINS.items():
            self.assertEqual(script.count(digest.upper()), 2)
        regsvr64 = webcam.ps_quote(os.path.join(str(self.system_root), "System32", "regsvr32.exe"))
        regsvr32 = webcam.ps_quote(os.path.join(str(self.system_root), "SysWOW64", "regsvr32.exe"))
        dll64 = webcam.ps_quote(os.path.join(folder, "softcam64.dll"))
        dll32 = webcam.ps_quote(os.path.join(folder, "softcam32.dll"))
        first = statements.index(f"& {regsvr64} /s {dll64} 2>&1 | Out-Null")
        second = statements.index(f"& {regsvr32} /s {dll32} 2>&1 | Out-Null")
        self.assertLess(statements.index("if ($LASTEXITCODE -ne 0) { exit 12 }"), first)
        self.assertLess(first, second)
        # When the 32-bit registration fails, the 64-bit one is removed again: nothing half applied.
        failure64, failure32 = "; ".join(statements[first + 1:second]), "; ".join(statements[second + 1:])
        self.assertNotIn("/u /s", failure64)
        self.assertIn("exit (30 + $c)", failure64)
        self.assertIn(f"& {regsvr64} /u /s {dll64} 2>&1 | Out-Null", failure32)
        self.assertIn("exit (40 + $c)", failure32)
        self.assertEqual(statements[-1], "exit 0")
        self.assertNotIn('"', script)
        self.assertTrue(_balanced(script))

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
        script = webcam.elevation_script(layout, webcam.install_directory(), sources)
        path = self.root / "script.ps1"
        path.write_text(script, encoding="utf-8-sig")
        check = ("$t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("
                 f"'{path}', [ref]$t, [ref]$e); foreach ($x in $e) {{ Write-Output $x.Message }}; exit $e.Count")
        result = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", check],
                                capture_output=True, text=True, timeout=120)
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
                                timeout=120)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8-sig"), text)


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
        def run(executable, parameters, timeout):
            self.elevations.append((executable, parameters, timeout))
            if error is not None:
                raise error
            if register:
                self.register()
            return code
        return run

    def install(self, **kwargs):
        kwargs.setdefault("download", Mock(side_effect=AssertionError("no download")))
        return webcam.install_webcam(progress=self.stages.append, **kwargs)

    def test_a_fresh_pc_copies_then_prompts_once_and_verifies_the_registry(self):
        self.assertEqual(self.install(elevate=self.elevate()), "installed")
        self.assertEqual(len(self.elevations), 1)
        executable, parameters, timeout = self.elevations[0]
        self.assertEqual(executable, self.layout().powershell)
        self.assertTrue(parameters.endswith('"'))
        self.assertIn("/setowner", parameters)
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

    def test_declining_the_prompt_registers_nothing(self):
        with self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=self.elevate(error=webcam.ElevationDeclined()))
        self.assertEqual(raised.exception.status, 403)
        self.assertIn("declined", raised.exception.message)
        self.assertFalse(webcam.registration_state(self.layout()).ok)
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
        with self.assertLogs("orbit.webcam", "WARNING"), self.assertRaises(webcam.InstallError) as raised:
            self.install(elevate=self.elevate(code=0, register=False))
        self.assertIn("not registered correctly", raised.exception.message)
        self.assertNotIn("iPhone webcam is set up", [call.args[0] for call in self.notify.call_args_list])

    def test_exit_codes_map_to_plain_words(self):
        layout = self.layout()
        registration = webcam.Registration(False, "missing", {})
        cases = {10: "prepare the webcam folder", 20: "Close apps", 21: "changed during setup",
                 35: "regsvr32 error 5", 90: "script failed", 77: "code 77"}
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

    def test_an_older_orbit_folder_is_recognised(self):
        older = self.program_data / "Orbit" / "Webcam" / "0123456789abcdef"
        self.register(paths={name: str(older / name) for name in webcam.DLL_SHA256})
        self.assertEqual(webcam.registration_state(self.layout()).problem, "olderOrbit")

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
        release.set()
        self.assertEqual(first.result(5), "installed")
        self.assertEqual(calls, [1])
        self.assertFalse(installer.installing)
        self.assertIsNone(installer.stage)

    def test_a_failure_is_remembered_until_the_next_setup(self):
        installer = webcam.Installer(Mock(side_effect=webcam.InstallError(403, "Declined.")))
        with self.assertRaises(webcam.InstallError):
            installer.start().result(5)
        self.assertEqual(installer.last_error, "Declined.")
        installer._runner = Mock(return_value="installed")
        self.assertEqual(installer.start().result(5), "installed")
        self.assertIsNone(installer.last_error)

    def test_unexpected_errors_become_a_plain_message(self):
        installer = webcam.Installer(Mock(side_effect=RuntimeError("boom")))
        with self.assertLogs("orbit.webcam", "ERROR"):
            with self.assertRaises(webcam.InstallError) as raised:
                installer.start().result(5)
        self.assertEqual(raised.exception.status, 503)
        self.assertNotIn("boom", raised.exception.message)


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
            library = webcam.SoftcamLibrary.load(Path("C:/ProgramData/Orbit/Webcam/x/softcam64.dll"))
        cdll.assert_called_once_with(str(Path("C:/ProgramData/Orbit/Webcam/x/softcam64.dll")))
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
    def __init__(self):
        self.created, self.deleted, self.frames = [], [], []
        self.connected = False
        self.refuse = False
        self.handle = 0x5C0F0

    def create(self, width, height, fps):
        if self.refuse:
            return None
        self.handle += 1
        self.created.append((width, height, fps, self.handle))
        return self.handle

    def delete(self, camera):
        self.deleted.append(camera)

    def send(self, camera, bgr):
        self.frames.append((camera, bgr))

    def is_connected(self, camera):
        return self.connected


class CameraManagerTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("GRACE_SECONDS", 0.15), ("CONNECTION_POLL_SECONDS", 0.02)):
            patcher = patch.object(webcam, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.library = FakeLibrary()
        self.events = []
        self.manager = webcam.CameraManager(library_loader=lambda: self.library, converter=lambda data, w, h: data,
                                            emit=self.events.append)
        self.addCleanup(self.manager.close)

    def start(self, sender, camera_format=(1280, 720, 30), on_replaced=None):
        return self.manager.start_sender(sender, camera_format, on_replaced).result(3)

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

    def test_a_newer_sender_replaces_the_older_one(self):
        replaced = threading.Event()
        self.start("a", on_replaced=replaced.set)
        self.start("b")
        self.assertTrue(replaced.wait(3))
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
        self.installer = webcam.Installer(Mock(return_value="installed"))

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


# /ws/camera ----------------------------------------------------------------------------------------

WSS = "wss://testserver/ws/camera"
HELLO = json.dumps({"width": 640, "height": 360, "fps": 30})


class CameraSocketTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("GRACE_SECONDS", 0.15), ("CONNECTION_POLL_SECONDS", 0.02), ("STATUS_INTERVAL", 0.02),
                            ("HELLO_TIMEOUT", 2.0)):
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
            self.assertEqual(self.read_json(socket)["code"], "cameraUnavailable")
            self.assertEqual(self.closed_with(socket), 4003)

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
