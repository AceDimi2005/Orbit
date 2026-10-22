"""Icon registry, PNG writer and packaged-app logo tests. No Windows API is called."""
import base64
import ctypes
import os
import struct
import tempfile
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import orbit_icons as icons


def png_pixels(data):
    """Decode the PNGs encode_png writes: (width, height, RGBA bytes)."""
    self_check = unittest.TestCase()
    self_check.assertTrue(data.startswith(icons.PNG_SIGNATURE))
    offset, width, height, idat = len(icons.PNG_SIGNATURE), None, None, b""
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset:offset + 4])
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        (crc,) = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])
        self_check.assertEqual(crc, zlib.crc32(kind + payload) & 0xFFFFFFFF)
        if kind == b"IHDR":
            width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", payload)
            self_check.assertEqual((depth, color), (8, 6))
        elif kind == b"IDAT":
            idat += payload
        offset += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 4
    rows = []
    for row in range(height):
        start = row * (stride + 1)
        self_check.assertEqual(raw[start], 0)
        rows.append(raw[start + 1:start + 1 + stride])
    return width, height, b"".join(rows)


class PNGTests(unittest.TestCase):
    def test_png_round_trip_keeps_every_pixel(self):
        rgba = bytes(range(256)) * 3  # 192 pixels of varied values
        data = icons.encode_png(16, 12, rgba)
        self.assertEqual(png_pixels(data), (16, 12, rgba))

    def test_png_opens_in_pillow_when_available(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        import io
        rgba = bytes([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40])
        image = Image.open(io.BytesIO(icons.encode_png(2, 2, rgba)))
        self.assertEqual((image.mode, image.size), ("RGBA", (2, 2)))
        self.assertEqual(image.tobytes(), rgba)

    def test_png_rejects_mismatched_sizes(self):
        with self.assertRaises(ValueError):
            icons.encode_png(2, 2, b"\0" * 15)
        for size in (0, -1, True, 5000):
            with self.assertRaises(ValueError):
                icons.encode_png(size, 1, b"")


class PixelTests(unittest.TestCase):
    def test_alpha_icons_swap_blue_and_red(self):
        bgra = bytes([1, 2, 3, 255, 10, 20, 30, 0])
        self.assertEqual(icons.bgra_to_rgba(bgra), bytes([3, 2, 1, 255, 30, 20, 10, 0]))

    def test_icons_without_alpha_use_the_and_mask(self):
        bgra = bytes([1, 2, 3, 0, 4, 5, 6, 0])
        mask = bytes([0, 0, 0, 0, 255, 255, 255, 0])  # black = opaque, white = transparent
        self.assertEqual(icons.bgra_to_rgba(bgra, mask), bytes([3, 2, 1, 255, 6, 5, 4, 0]))
        self.assertEqual(icons.bgra_to_rgba(bgra), bytes([3, 2, 1, 255, 6, 5, 4, 255]))


class PathTests(unittest.TestCase):
    def test_icon_locations_expand_windows_variables(self):
        with patch.dict(os.environ, {"SystemRoot": "C:\\Windows"}):
            self.assertEqual(icons.parse_icon_location("@%SystemRoot%\\System32\\AudioSrv.Dll,-203"),
                             ("C:\\Windows\\System32\\AudioSrv.Dll", -203))
        self.assertEqual(icons.parse_icon_location('"C:\\Apps\\Game.exe",2'), ("C:\\Apps\\Game.exe", 2))
        self.assertEqual(icons.parse_icon_location("C:\\Apps\\icon.ico"), ("C:\\Apps\\icon.ico", 0))
        for value in (None, "", "@", "relative\\app.exe,0", "\\\\server\\share\\app.exe", 7):
            self.assertIsNone(icons.parse_icon_location(value))

    def test_paths_must_be_local_and_absolute(self):
        self.assertEqual(icons.clean_icon_path(" C:\\Apps\\Game.exe "), "C:\\Apps\\Game.exe")
        self.assertEqual(icons.clean_icon_path("/Applications/Game"), "/Applications/Game")
        for value in ("", "game.exe", "\\\\server\\share\\a.exe", "\\\\?\\UNC\\server\\a.exe", "C:\\a\0b", None):
            self.assertIsNone(icons.clean_icon_path(value))

    def test_icon_id_lists_are_validated(self):
        one, two = "a" * 32, "b" * 32
        self.assertEqual(icons.parse_icon_ids(f"{one}, {two},{one}"), [one, two])
        for value in ("", ",", "A" * 32, "a" * 31, "../etc", ",".join(f"{index:032x}" for index in range(49))):
            with self.assertRaises(ValueError):
                icons.parse_icon_ids(value)


class RegistryTests(unittest.TestCase):
    PNG = icons.encode_png(1, 1, b"\xff\x00\x00\xff")

    def test_ids_are_opaque_stable_and_case_insensitive(self):
        registry = icons.IconRegistry(extractor=MagicMock(return_value=self.PNG), key=b"k" * 32)
        first = registry.register("C:\\Program Files\\Game\\Game.exe")
        self.assertRegex(first, r"^[0-9a-f]{32}$")
        self.assertNotIn("Game", first)
        self.assertEqual(registry.register("c:\\program files\\game\\GAME.EXE"), first)
        self.assertNotEqual(registry.register("C:\\Program Files\\Game\\Game.exe", -203), first)
        other = icons.IconRegistry(extractor=MagicMock(), key=b"z" * 32)
        self.assertNotEqual(other.register("C:\\Program Files\\Game\\Game.exe"), first)
        for value in (None, "", "Game.exe", 42):
            self.assertIsNone(registry.register(value))
        self.assertIsNone(registry.register("C:\\Game.exe", True))

    def test_lookup_extracts_once_and_leaves_out_unknown_ids(self):
        extractor = MagicMock(return_value=self.PNG)
        registry = icons.IconRegistry(extractor=extractor)
        identity = registry.register("C:\\Game.exe")
        unknown = "f" * 32
        self.assertEqual(registry.lookup([identity, unknown]), {identity: base64.b64encode(self.PNG).decode()})
        self.assertEqual(registry.lookup([identity]), {identity: base64.b64encode(self.PNG).decode()})
        extractor.assert_called_once_with("C:\\Game.exe", 0)

    def test_files_without_icons_stop_getting_ids(self):
        extractor = MagicMock(return_value=None)
        registry = icons.IconRegistry(extractor=extractor)
        identity = registry.register("C:\\Windows\\System32\\svchost.exe")
        self.assertEqual(registry.lookup([identity]), {identity: None})
        self.assertIsNone(registry.register("C:\\Windows\\System32\\svchost.exe"))
        self.assertEqual(registry.lookup([identity]), {identity: None})
        extractor.assert_called_once()

    def test_failures_are_retried_and_non_png_data_is_refused(self):
        extractor = MagicMock(side_effect=[OSError("busy"), b"GIF89a", self.PNG])
        registry = icons.IconRegistry(extractor=extractor)
        identity = registry.register("C:\\Game.exe")
        self.assertEqual(registry.lookup([identity]), {identity: None})  # transient: not cached
        self.assertEqual(registry.lookup([identity]), {identity: None})  # not a PNG: no icon
        self.assertEqual(registry.lookup([identity]), {identity: None})
        self.assertEqual(extractor.call_count, 2)

    def test_cache_and_sources_stay_bounded(self):
        registry = icons.IconRegistry(extractor=MagicMock(return_value=self.PNG))
        with patch.object(icons, "MAX_SOURCES", 3), patch.object(icons, "MAX_CACHE_BYTES", len(self.PNG) * 2):
            ids = [registry.register(f"C:\\App{index}.exe") for index in range(5)]
            self.assertEqual(len(registry._sources), 3)
            self.assertEqual(registry.lookup(ids[:2]), {})  # evicted sources are unknown again
            registry.lookup(ids[2:])
            self.assertLessEqual(registry._image_bytes, len(self.PNG) * 2)
            self.assertEqual(registry._image_bytes, sum(len(image) if image else icons._NO_ICON_COST
                                                        for image in registry._images.values()))


class PackageLogoTests(unittest.TestCase):
    MANIFEST = """<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10">
  <Properties><Logo>Assets\\StoreLogo.png</Logo></Properties>
  <Applications>
    <Application Id="Helper" Executable="Helper.exe">
      <uap:VisualElements Square44x44Logo="Assets\\HelperLogo.png" Square150x150Logo="Assets\\Wide.png" />
    </Application>
    <Application Id="App" Executable="VFS\\ProgramFilesX64\\Player\\Player.exe">
      <uap:VisualElements Square44x44Logo="Assets\\Square44x44Logo.png" Square150x150Logo="Assets\\Medium.png" />
    </Application>
  </Applications>
</Package>"""

    def package(self, files):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = folder.name
        with open(os.path.join(root, "AppxManifest.xml"), "w", encoding="utf-8") as handle:
            handle.write(self.MANIFEST)
        os.makedirs(os.path.join(root, "Assets"))
        os.makedirs(os.path.join(root, "VFS", "ProgramFilesX64", "Player"))
        for name, data in files.items():
            with open(os.path.join(root, "Assets", name), "wb") as handle:
                handle.write(data)
        return root, os.path.join(root, "VFS", "ProgramFilesX64", "Player", "Player.exe")

    @staticmethod
    def logo(tag):
        return icons.PNG_SIGNATURE + tag.encode()

    def test_matching_application_and_best_variant_are_chosen(self):
        files = {
            "Square44x44Logo.png": self.logo("plain"),
            "Square44x44Logo.scale-200.png": self.logo("scale200"),
            "Square44x44Logo.targetsize-48_altform-unplated.png": self.logo("unplated48"),
            "Square44x44Logo.targetsize-256_altform-unplated.png": self.logo("unplated256"),
            "Square44x44Logo.targetsize-256.png": self.logo("plated256"),
            "Square44x44Logo.targetsize-256_altform-lightunplated.png": self.logo("light"),
            "Square44x44Logo.contrast-white_targetsize-256_altform-unplated.png": self.logo("contrast"),
            "Square44x44LogoOther.targetsize-256.png": self.logo("other-file"),
            "HelperLogo.targetsize-256_altform-unplated.png": self.logo("helper"),
        }
        _, player = self.package(files)
        self.assertEqual(icons.package_logo_png(player), self.logo("unplated256"))

    def test_closest_size_that_is_big_enough_wins(self):
        _, player = self.package({
            "Square44x44Logo.targetsize-32_altform-unplated.png": self.logo("32"),
            "Square44x44Logo.targetsize-256_altform-unplated.png": self.logo("256"),
            "Square44x44Logo.targetsize-128_altform-unplated.png": self.logo("128"),
        })
        self.assertEqual(icons.package_logo_png(player), self.logo("128"))
        _, small_only = self.package({"Square44x44Logo.scale-100.png": self.logo("44"),
                                      "Square44x44Logo.scale-200.png": self.logo("88")})
        self.assertEqual(icons.package_logo_png(small_only), self.logo("88"))

    def test_falls_back_to_other_declared_logos(self):
        _, player = self.package({"Medium.scale-100.png": self.logo("medium")})
        self.assertEqual(icons.package_logo_png(player), self.logo("medium"))
        _, store_only = self.package({"StoreLogo.png": self.logo("store")})
        self.assertEqual(icons.package_logo_png(store_only), self.logo("store"))

    def test_non_png_oversized_and_unpackaged_files_have_no_logo(self):
        _, player = self.package({"Square44x44Logo.png": b"not a png"})
        self.assertIsNone(icons.package_logo_png(player))
        _, big = self.package({"Square44x44Logo.png": icons.PNG_SIGNATURE + b"0" * icons.MAX_ICON_BYTES})
        self.assertIsNone(icons.package_logo_png(big))
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(icons.package_logo_png(os.path.join(folder, "Game.exe")))

    def test_logo_paths_cannot_leave_the_package(self):
        root, _ = self.package({})
        self.assertIsNone(icons._best_logo_file(root, "..\\..\\secret.png", 44, 128))
        self.assertIsNone(icons._best_logo_file(root, "Assets\\Logo.jpg", 44, 128))

    def test_extract_uses_package_logo_off_windows_and_never_for_indexed_icons(self):
        _, player = self.package({"Square44x44Logo.png": self.logo("plain")})
        with patch.object(icons.os, "name", "posix"):
            self.assertEqual(icons.extract_icon_png(player), self.logo("plain"))
            self.assertIsNone(icons.extract_icon_png(player, -203))

    def test_windows_failures_are_reported_unless_a_logo_exists(self):
        _, player = self.package({"Square44x44Logo.png": self.logo("plain")})
        with patch.object(icons.os, "name", "nt"), \
             patch.object(icons, "windows_icon_png", side_effect=OSError("locked")):
            self.assertEqual(icons.extract_icon_png(player), self.logo("plain"))
            with self.assertRaises(OSError):
                icons.extract_icon_png("C:\\Missing\\Game.exe")
        with patch.object(icons.os, "name", "nt"), patch.object(icons, "windows_icon_png", return_value=None):
            self.assertIsNone(icons.extract_icon_png("C:\\Missing\\Game.exe"))


class WindowsIconFlowTests(unittest.TestCase):
    """Drives windows_icon_png with fake Win32 functions: handle cleanup and pixel paths."""

    def fake_api(self, result=0, alpha=True):
        calls = {"destroyed": [], "deleted": [], "dib": [], "contexts": []}
        color = bytes([10, 20, 30, 200 if alpha else 0]) * 4  # 2x2 BGRA
        mask = bytes([0, 0, 0, 0, 255, 255, 255, 0]) * 2      # each row: opaque, transparent

        def extract(path, index, flags, large, small, size):
            calls["extract"] = (path, index, flags, size)
            if result == 0:
                large._obj.value, small._obj.value = 501, 502
            return result

        def icon_info(icon, info):
            info._obj.hbmColor, info._obj.hbmMask = 601, 602
            return 1

        def measure(handle, size, bitmap):
            bitmap._obj.bmWidth, bitmap._obj.bmHeight = 2, 2
            return size

        def pixels(context, handle, start, lines, buffer, info, usage):
            data = color if handle == 601 else mask
            ctypes.memmove(buffer, data, len(data))
            header = info._obj.bmiHeader
            calls["dib"].append((handle, header.biHeight, header.biBitCount, context))
            return lines

        api = SimpleNamespace(
            shell32=SimpleNamespace(SHDefExtractIconW=extract),
            user32=SimpleNamespace(GetIconInfo=icon_info,
                                   DestroyIcon=lambda handle: calls["destroyed"].append(handle.value) or 1),
            gdi32=SimpleNamespace(GetObjectW=measure, CreateCompatibleDC=lambda _: 77,
                                  DeleteDC=lambda context: calls["contexts"].append(context) or 1,
                                  GetDIBits=pixels, DeleteObject=lambda handle: calls["deleted"].append(handle) or 1))
        return api, calls

    def run_flow(self, **options):
        api, calls = self.fake_api(**options)
        with patch.object(icons, "_windows_apis", return_value=api):
            return icons.windows_icon_png("C:\\Game.exe", 0), calls

    def test_alpha_icon_becomes_png_and_every_handle_is_released(self):
        image, calls = self.run_flow()
        self.assertEqual(png_pixels(image), (2, 2, bytes([30, 20, 10, 200]) * 4))
        self.assertEqual(calls["extract"], ("C:\\Game.exe", 0, 0, (16 << 16) | icons.ICON_PIXELS))
        self.assertEqual(calls["destroyed"], [501, 502])
        self.assertEqual(calls["deleted"], [601, 602])
        self.assertEqual(calls["dib"], [(601, -2, 32, 77)])  # top-down 32-bit rows, mask not needed
        self.assertEqual(calls["contexts"], [77])

    def test_icons_without_alpha_take_transparency_from_the_mask(self):
        image, calls = self.run_flow(alpha=False)
        self.assertEqual(png_pixels(image), (2, 2, bytes([30, 20, 10, 255, 30, 20, 10, 0]) * 2))
        self.assertEqual([entry[0] for entry in calls["dib"]], [601, 602])

    def test_files_without_icons_and_failures(self):
        image, calls = self.run_flow(result=1)  # S_FALSE
        self.assertIsNone(image)
        self.assertEqual(calls["destroyed"], [])
        with self.assertRaises(OSError):
            self.run_flow(result=-2147467259)  # E_FAIL


if __name__ == "__main__":
    unittest.main()
