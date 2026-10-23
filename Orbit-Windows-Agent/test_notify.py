"""PC toasts: the notifier hook, the pcToasts setting and the tray wiring in __main__."""
import ast
import ctypes
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import orbit_notify as notify
import orbit_settings as settings
import orbit_tray as tray


class NotifyTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.store = settings.SettingsStore(Path(self.folder.name) / "settings.json")
        settings.set_shared_store(self.store)
        self.addCleanup(settings.set_shared_store, None)
        self.addCleanup(notify.set_notifier, None)

    def test_without_notifier_nothing_happens(self):
        notify.set_notifier(None)
        self.assertFalse(notify.has_notifier())
        self.assertFalse(notify.notify("Title", "Message"))

    def test_notifier_gets_cleaned_text_and_its_result_is_reported(self):
        shown = MagicMock(return_value=True)
        notify.set_notifier(shown)
        self.assertTrue(notify.has_notifier())
        self.assertTrue(notify.notify("  Download\nfinished\t", "Portal 2\r\nis ready\x00 to play‮"))
        shown.assert_called_once_with("Download finished", "Portal 2 is ready to play")
        shown.return_value = False
        self.assertFalse(notify.notify("Title", "Message"))

    def test_long_text_is_cut_to_the_tray_limits_with_an_ellipsis(self):
        shown = MagicMock(return_value=True)
        notify.set_notifier(shown)
        notify.notify("T" * 200, "M" * 1000)
        title, message = shown.call_args.args
        self.assertEqual(len(title), notify.TITLE_LIMIT)
        self.assertEqual(len(message), notify.MESSAGE_LIMIT)
        self.assertTrue(title.endswith("…") and message.endswith("…"))

    def test_empty_message_still_shows_a_balloon(self):
        shown = MagicMock(return_value=True)
        notify.set_notifier(shown)
        notify.notify("Opened a link", "")
        shown.assert_called_once_with("Orbit", "Opened a link")
        shown.reset_mock()
        notify.notify(None, None)
        shown.assert_called_once_with("Orbit", "Orbit")

    def test_pc_toasts_setting_is_respected_and_defaults_to_on(self):
        shown = MagicMock(return_value=True)
        notify.set_notifier(shown)
        self.assertTrue(notify.toasts_enabled())
        self.store.update("alerts", {"temperature": {"enabled": True}})
        self.assertTrue(notify.toasts_enabled())
        self.store.update("alerts", {"pcToasts": False})
        self.assertFalse(notify.toasts_enabled())
        self.assertFalse(notify.notify("Hidden", "Toasts are off"))
        shown.assert_not_called()
        self.store.update("alerts", {"pcToasts": True})
        self.assertTrue(notify.notify("Shown", "Toasts are on"))
        self.store.replace("alerts", "not a dict")
        self.assertTrue(notify.toasts_enabled())

    def test_unreadable_setting_keeps_toasts_on(self):
        broken = MagicMock()
        broken.get.side_effect = RuntimeError("store unavailable")
        settings.set_shared_store(broken)
        self.assertTrue(notify.toasts_enabled())

    def test_failing_notifier_never_raises(self):
        notify.set_notifier(MagicMock(side_effect=OSError("tray gone")))
        with self.assertLogs("orbit.notify", "WARNING"):
            self.assertFalse(notify.notify("Title", "Message"))

    def test_notifier_must_be_callable(self):
        with self.assertRaises(TypeError):
            notify.set_notifier("not callable")


class TrayWiringTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(notify.set_notifier, None)
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        settings.set_shared_store(settings.SettingsStore(Path(folder.name) / "settings.json"))
        self.addCleanup(settings.set_shared_store, None)

    def test_notify_reaches_the_tray_balloon(self):
        user32, shell32, kernel32 = MagicMock(), MagicMock(), MagicMock()
        shell32.Shell_NotifyIconW.return_value = 1
        icon = tray.OrbitTrayIcon(status_provider=lambda: {"agentVersion": "4.4.0"}, on_stop=lambda: None,
                                  apis=(user32, shell32, kernel32))
        notify.set_notifier(icon.show_notification)
        # Before the tray window exists the balloon is not shown.
        self.assertFalse(notify.notify("File received", "Received photo.jpg (2.4 MB) in Downloads"))
        icon._hwnd = 4242
        self.assertTrue(notify.notify("File received", "Received photo.jpg (2.4 MB) in Downloads"))
        message, data = shell32.Shell_NotifyIconW.call_args.args
        self.assertEqual(message, tray.NIM_MODIFY)
        structure = data._obj
        self.assertEqual(structure.szInfoTitle, "File received")
        self.assertEqual(structure.szInfo, "Received photo.jpg (2.4 MB) in Downloads")
        self.assertTrue(structure.uFlags & tray.NIF_INFO)

    def test_main_registers_the_tray_notifier_and_removes_it_on_exit(self):
        source = (Path(__file__).resolve().parent / "orbit_agent.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        main_blocks = [node for node in tree.body if isinstance(node, ast.If)
                       and isinstance(node.test, ast.Compare) and getattr(node.test.left, "id", None) == "__name__"
                       and any(getattr(comparator, "value", None) == "__main__" for comparator in node.test.comparators)
                       and any(isinstance(child, ast.Try) for child in node.body)]
        self.assertEqual(len(main_blocks), 1)
        calls = [ast.unparse(node) for node in sorted((node for node in ast.walk(main_blocks[0]) if isinstance(node, ast.Call)),
                                                      key=lambda node: (node.lineno, node.col_offset))]
        self.assertIn("orbit_notify.set_notifier(tray.show_notification)", calls)
        self.assertIn("orbit_notify.set_notifier(None)", calls)
        register = calls.index("orbit_notify.set_notifier(tray.show_notification)")
        self.assertLess(calls.index("tray.start()"), register)


if __name__ == "__main__":
    unittest.main()
