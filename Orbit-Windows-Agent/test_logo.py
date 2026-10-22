"""The Orbit mark's geometry, its SVG, the icon frames, the tray's click and theme handling."""
import math
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import orbit_logo as logo
import orbit_tray as tray


def frames_of(raw):
    _, kind, count = struct.unpack_from("<HHH", raw, 0)
    result = []
    for index in range(count):
        width, height, _, _, _, depth, size, offset = struct.unpack_from("<BBBBHHII", raw, 6 + 16 * index)
        result.append((width or 256, depth, size, offset))
    return kind, result


class GeometryTests(unittest.TestCase):
    def test_the_brief_numbers(self):
        self.assertAlmostEqual(logo.HALF_ANGLE, 154 / 290)
        self.assertEqual(logo.RING_RADIUS + logo.STROKE / 2, logo.UNITS / 2)  # D is the ring's outer diameter
        self.assertEqual(logo.HEIGHT, 694)
        (x1, y1), (x2, y2) = logo.arc_endpoints(0, 0)
        # The cap ends 40 units before the satellite: their centres are 66 + 40 + 48 apart along the ring.
        gap_along_ring = logo.RING_RADIUS * logo.HALF_ANGLE
        self.assertAlmostEqual(gap_along_ring, 66 + 40 + 48)
        self.assertAlmostEqual(x1, -x2)
        self.assertAlmostEqual(y1, -logo.RING_RADIUS * math.cos(logo.HALF_ANGLE))

    def test_svg(self):
        svg = logo.logo_svg(24)
        self.assertIn('viewBox="-9 -18 694 694"', svg)
        self.assertIn('stroke-width="96" stroke-linecap="round"', svg)
        self.assertIn('<circle cx="338" cy="48" r="66" fill="#0A84FF"/>', svg)
        self.assertIn('A290 290 0 1 1', svg)
        self.assertIn('width="24" height="24"', svg)


class IconTests(unittest.TestCase):
    def test_tray_frames_are_the_bare_mark_and_large_frames_the_graphite_tile(self):
        frames = logo.icon_frames()
        self.assertEqual(sorted(frames), [16, 20, 24, 32, 40, 48, 64, 256])
        small = frames[32]
        self.assertEqual(small.getpixel((0, 31))[3], 0)  # transparent corner
        satellite = small.getpixel((16, 2))
        self.assertGreater(satellite[2], 200)  # blue at the top centre
        ring_pixels = [small.getpixel((x, 16)) for x in range(32)]
        self.assertTrue(any(pixel[3] > 200 and min(pixel[:3]) > 200 for pixel in ring_pixels))  # white ring
        tile = frames[256]
        self.assertEqual(tile.getpixel((0, 0))[3], 0)  # rounded corner
        top, bottom = tile.getpixel((128, 4)), tile.getpixel((128, 251))
        self.assertGreater(sum(top[:3]), sum(bottom[:3]))  # graphite #2C2E34 down to #0A0A0C
        self.assertEqual(top[3], 255)

    def test_ico_container_and_the_bundled_file(self):
        raw = logo.build_ico(logo.icon_frames())
        kind, frames = frames_of(raw)
        self.assertEqual(kind, 1)
        self.assertEqual([frame[0] for frame in frames], [16, 20, 24, 32, 40, 48, 64, 256])
        self.assertTrue(all(depth == 32 and offset + size <= len(raw) for _, depth, size, offset in frames))
        self.assertTrue(raw[frames[-1][3]:].startswith(b"\x89PNG"))
        bundled = Path(tray.ICON_PATH).read_bytes()
        self.assertEqual([frame[0] for frame in frames_of(bundled)[1]], [16, 20, 24, 32, 40, 48, 64, 256])

    def test_light_taskbar_icon_has_a_dark_ring(self):
        with tempfile.TemporaryDirectory() as folder:
            path = tray.light_taskbar_icon(folder)
            self.assertTrue(path.is_file())
            self.assertEqual([frame[0] for frame in frames_of(path.read_bytes())[1]], list(logo.TRAY_SIZES))
        mark = logo.render_mark(32, ring="#1C1C1E")
        darkest = min(sum(pixel[:3]) for pixel in mark.getdata() if pixel[3] > 250)
        self.assertLess(darkest, 120)

    def test_taskbar_theme_from_the_registry(self):
        class Registry:
            HKEY_CURRENT_USER = "HKCU"

            def __init__(self, value):
                self.value = value

            def OpenKey(self, root, path):
                if self.value is None:
                    raise OSError(path)
                return MagicMock(__enter__=lambda s: s, __exit__=lambda *a: False)

            def QueryValueEx(self, key, name):
                return self.value, 4
        self.assertTrue(tray.taskbar_uses_light_theme(Registry(1)))
        self.assertFalse(tray.taskbar_uses_light_theme(Registry(0)))
        self.assertFalse(tray.taskbar_uses_light_theme(Registry(None)))


class TrayClickTests(unittest.TestCase):
    def make(self, on_open=None):
        user32, shell32, kernel32 = MagicMock(), MagicMock(), MagicMock()
        icon = tray.OrbitTrayIcon(status_provider=lambda: {"agentVersion": "5.0.0"}, on_stop=lambda: None,
                                  apis=(user32, shell32, kernel32), on_open=on_open, boot_task=MagicMock(is_installed=lambda: False))
        icon._hwnd = 99
        return icon, user32

    def test_left_click_opens_the_window_right_click_the_menu(self):
        opened = []
        icon, user32 = self.make(on_open=lambda: opened.append(True))
        with patch.object(icon, "_show_context_menu") as menu:
            icon._wnd_proc(99, tray.WM_TRAYICON, 0, tray.WM_LBUTTONUP)
            icon._wnd_proc(99, tray.WM_TRAYICON, 0, tray.WM_LBUTTONDBLCLK)  # the double click's second half
            self.assertEqual(opened, [True])
            menu.assert_not_called()
            icon._wnd_proc(99, tray.WM_TRAYICON, 0, tray.WM_RBUTTONUP)
            menu.assert_called_once()

    def test_without_a_window_left_click_still_shows_the_menu(self):
        icon, _ = self.make()
        with patch.object(icon, "_show_context_menu") as menu:
            icon._wnd_proc(99, tray.WM_TRAYICON, 0, tray.WM_LBUTTONUP)
        menu.assert_called_once()

    def test_menu_starts_with_open_orbit_as_the_default_item(self):
        opened = []
        icon, _ = self.make(on_open=lambda: opened.append(True))
        items = icon.build_menu_items()
        self.assertEqual((items[0]["id"], items[0]["label"], items[0]["default"]), (tray.ID_OPEN_WINDOW, "Open Orbit", True))
        self.assertEqual(icon.execute_command(tray.ID_OPEN_WINDOW), "window_opened")
        self.assertEqual(opened, [True])

    def test_theme_change_reloads_the_icon(self):
        icon, user32 = self.make()
        with patch.object(icon, "_reload_icons") as reload:
            icon._wnd_proc(99, tray.WM_SETTINGCHANGE, 0, 0)
        reload.assert_called_once()


if __name__ == "__main__":
    unittest.main()
