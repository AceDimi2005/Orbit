"""Send to PC links: strict validation, the ShellExecuteW call and POST /api/open-url."""
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_links as links

TOKEN = "test-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class ValidationTests(unittest.TestCase):
    def test_ordinary_web_links_are_accepted_unchanged(self):
        for url in ("https://example.com", "http://example.com/", "HTTPS://Example.com/Path?q=1&b=%22x%22#top",
                    "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "http://192.168.1.20:8080/status",
                    "http://[::1]:3000/", "https://xn--mnchen-3ya.de/", "https://münchen.de/straße",
                    "http://localhost:5173/app", "https://example.com/a(b)c;d=e,f*g!h$i'j~k+l",
                    "https://example.com/" + "a" * (links.MAX_URL_LENGTH - len("https://example.com/"))):
            with self.subTest(url=url[:80]):
                self.assertEqual(links.validate_url(url), url)

    def test_other_schemes_are_rejected(self):
        for url in ("file:///C:/Windows/System32/calc.exe", "javascript:alert(1)", "ms-msdt:/id PCWDiagnostic",
                    "ftp://example.com/file", "C:\\Windows\\System32\\calc.exe", "calc.exe", "steam://run/620",
                    "data:text/html,hi", "vbscript:msgbox", "mailto:a@example.com", "//example.com/path",
                    "example.com", "search-ms:query=x", "ms-settings:display", "shell:startup"):
            with self.subTest(url=url):
                with self.assertRaises(links.LinkError) as refused:
                    links.validate_url(url)
                self.assertIsInstance(refused.exception, ValueError)

    def test_credentials_in_the_link_are_rejected(self):
        for url in ("https://user:pass@example.com/", "https://user@example.com", "http://:@example.com",
                    "https://example.com@evil.example/", "https://a%40b@example.com", "https://@example.com"):
            with self.subTest(url=url):
                with self.assertRaises(links.LinkError) as refused:
                    links.validate_url(url)
                self.assertIn("user name or password", str(refused.exception))

    def test_overlong_links_are_rejected(self):
        url = "https://example.com/" + "a" * (links.MAX_URL_LENGTH - len("https://example.com/") + 1)
        self.assertEqual(len(url), links.MAX_URL_LENGTH + 1)
        with self.assertRaises(links.LinkError) as refused:
            links.validate_url(url)
        self.assertIn("4,096", str(refused.exception))

    def test_control_invisible_and_whitespace_characters_are_rejected(self):
        for character in ("\x00", "\n", "\r", "\t", "\x07", "\x1b", "\x7f", "\x85", " ", "\u00a0", "\u2028",
                          "\u202e", "\u200b", "\ufeff", "\u3000", "\ud800"):
            for position in ("start", "middle", "end"):
                url = {"start": character + "https://example.com/a",
                       "middle": "https://example.com/a" + character + "b",
                       "end": "https://example.com/a" + character}[position]
                with self.subTest(character=hex(ord(character)), position=position):
                    with self.assertRaises(links.LinkError) as refused:
                        links.validate_url(url)
                    self.assertIn("control characters", str(refused.exception))

    def test_characters_that_must_be_percent_encoded_are_rejected(self):
        for character in '"<>\\^`{|}':
            with self.subTest(character=character):
                with self.assertRaises(links.LinkError):
                    links.validate_url(f"https://example.com/a{character}b")
        # A quote must never reach the browser's command line: no argument injection.
        with self.assertRaises(links.LinkError):
            links.validate_url('https://example.com/" --gpu-launcher="calc.exe')

    def test_broken_hosts_and_ports_are_rejected(self):
        for url in ("https://", "https:///path", "https:example.com", "http:/example.com", "https://:443/",
                    "https://exa%41mple.com/", "https://example.com:99999/", "https://example.com:port/",
                    "https://[::1/", "https://exa$mple.com/", "https://a:b:c/"):
            with self.subTest(url=url):
                with self.assertRaises(links.LinkError):
                    links.validate_url(url)

    def test_non_text_and_empty_values_are_rejected(self):
        for value in (None, "", 42, b"https://example.com", ["https://example.com"]):
            with self.subTest(value=value):
                with self.assertRaises(links.LinkError):
                    links.validate_url(value)

    def test_other_schemes_can_be_allowed_explicitly_with_the_same_character_rules(self):
        self.assertEqual(links.validate_url("steam://rungameid/620", {"steam"}), "steam://rungameid/620")
        self.assertEqual(links.validate_url("ms-settings:display", {"ms-settings"}), "ms-settings:display")
        with self.assertRaises(links.LinkError):
            links.validate_url("steam:", {"steam"})
        with self.assertRaises(links.LinkError):
            links.validate_url('steam://run/620" -evil', {"steam"})
        with self.assertRaises(links.LinkError):
            links.validate_url("https://example.com", {"steam"})

    def test_display_form_for_the_toast(self):
        self.assertEqual(links.display_url("https://www.example.com/articles/42?utm_source=x#c"), "www.example.com/articles/42")
        self.assertEqual(links.display_url("https://example.com/"), "example.com")
        self.assertEqual(len(links.display_url("https://example.com/" + "a" * 500)), 120)


class ShellExecuteTests(unittest.TestCase):
    def windll(self, result=42, com=0):
        windll = MagicMock()
        windll.shell32.ShellExecuteW.return_value = result
        windll.ole32.CoInitializeEx.return_value = com
        return windll

    def test_link_goes_to_shell_execute_open_with_com_initialized(self):
        windll = self.windll()
        with patch.object(links.os, "name", "nt"), patch.object(links, "_library", lambda name: getattr(windll, name)):
            self.assertEqual(links.open_url("https://example.com/a?b=1"), "https://example.com/a?b=1")
        windll.shell32.ShellExecuteW.assert_called_once_with(None, "open", "https://example.com/a?b=1", None, None, links.SW_SHOWNORMAL)
        windll.ole32.CoInitializeEx.assert_called_once_with(None, links.COINIT_APARTMENTTHREADED | links.COINIT_DISABLE_OLE1DDE)
        windll.ole32.CoUninitialize.assert_called_once_with()
        windll.user32.AllowSetForegroundWindow.assert_called_once_with(links.ASFW_ANY)

    def test_prototypes_live_on_private_handles_not_the_shared_windll(self):
        windll = self.windll()
        shared = MagicMock()
        with patch.object(links.os, "name", "nt"), patch.object(links, "_library", lambda name: getattr(windll, name)), \
             patch.object(links.ctypes, "windll", shared, create=True):
            links.open_url("https://example.com")
        self.assertEqual(shared.mock_calls, [])
        self.assertEqual(windll.shell32.ShellExecuteW.restype, links.ctypes.c_void_p)
        self.assertEqual(len(windll.shell32.ShellExecuteW.argtypes), 6)

    def test_private_handles_are_loaded_once_per_dll(self):
        loaded = []

        def fake_windll(name):
            loaded.append(name)
            return MagicMock(name=name)
        with patch.object(links, "_LIBRARIES", {}), patch.object(links.ctypes, "WinDLL", fake_windll, create=True):
            first = links._library("shell32")
            self.assertIs(links._library("shell32"), first)
            links._library("ole32")
        self.assertEqual(loaded, ["shell32", "ole32"])

    def test_com_already_in_another_mode_is_left_alone(self):
        windll = self.windll(com=-2147417850)  # RPC_E_CHANGED_MODE
        with patch.object(links.os, "name", "nt"), patch.object(links, "_library", lambda name: getattr(windll, name)):
            links.open_url("https://example.com")
        windll.ole32.CoUninitialize.assert_not_called()

    def test_shell_execute_failures_are_os_errors_in_plain_words(self):
        for result, message in ((links.SE_ERR_NOASSOC, "no default web browser"), (2, "could not open"), (None, "could not open")):
            windll = self.windll(result=result)
            with self.subTest(result=result), patch.object(links.os, "name", "nt"), \
                 patch.object(links, "_library", lambda name: getattr(windll, name)):
                with self.assertRaises(OSError) as failed:
                    links.open_url("https://example.com")
                self.assertIn(message, str(failed.exception))
                windll.ole32.CoUninitialize.assert_called_once_with()

    def test_invalid_links_never_reach_windows(self):
        windll = self.windll()
        with patch.object(links.os, "name", "nt"), patch.object(links, "_library", lambda name: getattr(windll, name)):
            with self.assertRaises(links.LinkError):
                links.open_url("file:///C:/Windows/System32/calc.exe")
        windll.shell32.ShellExecuteW.assert_not_called()

    def test_off_windows_nothing_is_opened(self):
        with patch.object(links.os, "name", "posix"), self.assertRaises(OSError):
            links.open_url("https://example.com")


class OpenURLRouteTests(unittest.TestCase):
    def setUp(self):
        token = patch.object(agent, "API_TOKEN", TOKEN)
        token.start()
        self.addCleanup(token.stop)
        self.client = TestClient(agent.app, base_url="https://testserver")
        self.addCleanup(self.client.close)

    def test_requires_token_and_https(self):
        with patch.object(agent.orbit_links, "open_url") as opened:
            self.assertEqual(self.client.post("/api/open-url", json={"url": "https://example.com"}).status_code, 401)
            self.assertEqual(self.client.post("/api/open-url", json={"url": "https://example.com"},
                                              headers={"Authorization": "Bearer wrong"}).status_code, 401)
            response = self.client.post("http://testserver/api/open-url", json={"url": "https://example.com"}, headers=AUTH)
            self.assertEqual(response.status_code, 426)
            opened.assert_not_called()

    def test_opens_the_link_and_shows_a_pc_toast(self):
        with patch.object(agent, "require_windows"), patch.object(agent.orbit_links, "open_url") as opened, \
             patch.object(agent.orbit_notify, "notify") as toast:
            response = self.client.post("/api/open-url", json={"url": "https://example.com/story?id=7"}, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "opened"})
        opened.assert_called_once_with("https://example.com/story?id=7")
        toast.assert_called_once_with("Opened a link from your iPhone", "example.com/story")

    def test_invalid_links_are_422_and_never_opened(self):
        with patch.object(agent, "require_windows"), patch.object(agent.orbit_links, "open_url") as opened, \
             patch.object(agent.orbit_notify, "notify") as toast:
            for url in ("file:///C:/Windows/System32/calc.exe", "https://user:pw@example.com", "https://example.com/\n",
                        "https://example.com/" + "a" * 5000, "javascript:alert(1)", ""):
                with self.subTest(url=url[:60]):
                    response = self.client.post("/api/open-url", json={"url": url}, headers=AUTH)
                    self.assertEqual(response.status_code, 422)
                    self.assertIsInstance(response.json()["detail"], str)
            for body in ({}, {"url": 5}, {"url": None}, {"link": "https://example.com"}):
                with self.subTest(body=body):
                    self.assertEqual(self.client.post("/api/open-url", json=body, headers=AUTH).status_code, 422)
            opened.assert_not_called()
            toast.assert_not_called()

    def test_off_windows_boot_mode_and_windows_failures(self):
        with patch.object(agent.os, "name", "posix"), patch.object(agent.orbit_links, "open_url") as opened:
            self.assertEqual(self.client.post("/api/open-url", json={"url": "https://example.com"}, headers=AUTH).status_code, 501)
            opened.assert_not_called()
        with patch.object(agent, "require_windows"), patch.object(agent, "BOOT_MODE", True), \
             patch.object(agent.orbit_links, "open_url") as opened:
            response = self.client.post("/api/open-url", json={"url": "https://example.com"}, headers=AUTH)
            self.assertEqual(response.status_code, 409)
            self.assertIn("Sign in", response.json()["detail"])
            opened.assert_not_called()
        with patch.object(agent, "require_windows"), patch.object(agent.orbit_notify, "notify") as toast, \
             patch.object(agent.orbit_links, "open_url", side_effect=OSError("Windows has no default web browser to open this link.")):
            response = self.client.post("/api/open-url", json={"url": "https://example.com"}, headers=AUTH)
        self.assertEqual(response.status_code, 503)
        self.assertIn("default web browser", response.json()["detail"])
        toast.assert_not_called()

    def test_full_path_down_to_shell_execute(self):
        windll = MagicMock()
        windll.shell32.ShellExecuteW.return_value = 42
        windll.ole32.CoInitializeEx.return_value = 0
        with patch.object(agent, "require_windows"), patch.object(links.os, "name", "nt"), \
             patch.object(links, "_library", lambda name: getattr(windll, name)), patch.object(agent.orbit_notify, "notify"):
            response = self.client.post("/api/open-url", json={"url": "https://example.com/x"}, headers=AUTH)
        self.assertEqual(response.status_code, 200)
        windll.shell32.ShellExecuteW.assert_called_once_with(None, "open", "https://example.com/x", None, None, 1)


if __name__ == "__main__":
    unittest.main()
