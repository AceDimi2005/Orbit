"""Update channels: version order, stable/beta selection, no downgrade, beta downloads, the tray item.

GitHub is a dictionary of fake replies; nothing touches the network, the registry or a real tray.
"""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error
import zipfile

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_settings
import orbit_tray as tray
import orbit_updater as updater
import orbit_webcam as webcam

OWNER_REPO = "AceDimi2005/Orbit"
RAW = f"https://raw.githubusercontent.com/{OWNER_REPO}/"
RELEASES = f"https://api.github.com/repos/{OWNER_REPO}/releases?per_page=20"
TOKEN = "test-only-token-with-more-than-24-characters"


def agent_source(version):
    return f'"""Orbit agent."""\nimport os\n\nAGENT_VERSION = "{version}"\n'.encode()


class FakeGitHub:
    """Answers GitHub URLs from a dictionary; anything else is a 404 (like a missing branch)."""

    def __init__(self, main=None, beta=None, releases=()):
        self.replies = {RELEASES: json.dumps(list(releases)).encode()}
        if main is not None:
            self.replies[RAW + "main/Orbit-Windows-Agent/orbit_agent.py"] = agent_source(main)
        if beta is not None:
            self.replies[RAW + "beta/Orbit-Windows-Agent/orbit_agent.py"] = agent_source(beta)
        self.urls = []

    def __call__(self, request, timeout=6.0):
        url = request.full_url
        self.urls.append(url)
        if url in self.replies:
            return io.BytesIO(self.replies[url])
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)


def release(tag, prerelease=False, asset=True):
    item = {"tag_name": tag, "name": f"Orbit PC Companion {tag}", "body": "Notes", "prerelease": prerelease,
            "html_url": f"https://github.com/{OWNER_REPO}/releases/tag/{tag}"}
    if asset:
        item["assets"] = [{"name": "Orbit-Windows-Agent.zip",
                           "browser_download_url": f"https://github.com/{OWNER_REPO}/releases/download/{tag}/Orbit-Windows-Agent.zip"}]
    return item


class TempSettings(unittest.TestCase):
    """Every test gets its own settings.json as the agent's shared store."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = orbit_settings.SettingsStore(Path(folder.name) / "settings.json")
        orbit_settings.set_shared_store(self.store)
        self.addCleanup(orbit_settings.set_shared_store, None)


class VersionTests(unittest.TestCase):
    def test_stable_is_newer_than_rc_beta_and_alpha_of_the_same_number(self):
        ordered = ["4.5.1", "4.5.2", "4.5.10", "4.6.0a1", "4.6.0b1", "4.6.0b2", "4.6.0b10", "4.6.0rc1", "4.6.0",
                   "4.6.1b1", "4.6.1"]
        for shuffled in (list(reversed(ordered)), ordered[3:] + ordered[:3]):
            self.assertEqual(sorted(shuffled, key=updater.parse_version), ordered)
        for older, newer in zip(ordered, ordered[1:]):
            with self.subTest(older=older, newer=newer):
                self.assertTrue(updater.is_newer_version(newer, older))
                self.assertFalse(updater.is_newer_version(older, newer))
        self.assertFalse(updater.is_newer_version("4.6", "4.6.0"))
        self.assertFalse(updater.is_newer_version("v4.6.0-beta.2", "4.6.0b2"))
        # The old digits-only parser read 4.6.0b1 as 4.6.0: a beta must never count as the release.
        self.assertTrue(updater.is_newer_version("4.6.0", "4.6.0b1"))

    def test_tags_and_titles_normalize_to_one_scheme(self):
        cases = {
            "4.6.0": ("4.6.0", "4.6.0", False),
            "v4.1.0": ("4.1.0", "4.1.0", False),
            "pc-v4.6.0b1": ("4.6.0b1", "4.6.0 beta 1", True),
            "pc-v4.6.0-beta.1": ("4.6.0b1", "4.6.0 beta 1", True),
            "Orbit PC Companion 4.6.0 beta 2": ("4.6.0b2", "4.6.0 beta 2", True),
            "4.6.0beta3": ("4.6.0b3", "4.6.0 beta 3", True),
            "4.6.0rc1": ("4.6.0rc1", "4.6.0 RC 1", True),
            "4.6.0 RC 2": ("4.6.0rc2", "4.6.0 RC 2", True),
            "4.6.0a1": ("4.6.0a1", "4.6.0 alpha 1", True),
            "4.6.0-alpha": ("4.6.0a0", "4.6.0 alpha 0", True),
            # Words that only start like a stage are not one.
            "Orbit 4.3.0 and more": ("4.3.0", "4.3.0", False),
            "Orbit 4.3.0 a new tray": ("4.3.0", "4.3.0", False),
            "4.3.0 better sensors": ("4.3.0", "4.3.0", False),
        }
        for text, (normalized, shown, prerelease) in cases.items():
            with self.subTest(text=text):
                self.assertEqual(updater.normalize_version_string(text), normalized)
                self.assertEqual(updater.display_version(text), shown)
                self.assertEqual(updater.is_prerelease(text), prerelease)
                self.assertEqual(updater.display_version(normalized), shown)  # round trip
        self.assertEqual(updater.display_version("4.0.0 · preview"), "4.0.0")
        self.assertEqual(updater.display_version("no version"), "no version")
        self.assertEqual(updater.parse_version("no version"), updater.parse_version("0"))
        self.assertFalse(updater.is_prerelease(None))


class ChannelSettingTests(TempSettings):
    def test_channel_defaults_to_stable_and_is_saved_in_the_updates_section(self):
        self.assertEqual(updater.current_channel(), "stable")
        self.assertFalse(updater.beta_notice_shown())
        self.assertEqual(updater.set_channel("beta"), "beta")
        self.assertEqual(updater.current_channel(), "beta")
        self.assertEqual(json.loads(self.store.path.read_text())["updates"], {"channel": "beta"})
        updater.mark_beta_notice_shown()
        self.assertTrue(updater.beta_notice_shown())
        self.assertEqual(updater.set_channel("stable"), "stable")
        self.assertEqual(self.store.get("updates"), {"channel": "stable", "betaNoticeShown": True})
        with self.assertRaises(ValueError):
            updater.set_channel("nightly")

    def test_unknown_or_damaged_values_mean_stable(self):
        for value in ({"channel": "BETA"}, {"channel": " beta "}):
            self.store.replace("updates", value)
            self.assertEqual(updater.current_channel(), "beta")
        for value in ({"channel": "nightly"}, {"channel": None}, "beta", [], {}):
            with self.subTest(value=value):
                self.store.replace("updates", value)
                self.assertEqual(updater.current_channel(), "stable")
        broken = MagicMock()
        broken.get.side_effect = OSError("locked")
        with self.assertLogs("orbit.updater", "WARNING"):
            self.assertEqual(updater.current_channel(broken), "stable")


class ChannelSelectionTests(TempSettings):
    def check(self, current, github, channel):
        return updater.check_for_updates(current, opener=github, channel=channel)

    def test_stable_ignores_the_beta_branch(self):
        github = FakeGitHub(main="4.5.2", beta="4.6.0b1")
        info = self.check("4.5.2", github, "stable")
        self.assertFalse(info["updateAvailable"])
        self.assertEqual((info["latestVersion"], info["channel"], info["source"]), ("4.5.2", "stable", "github_main"))
        self.assertFalse(any("/beta/" in url for url in github.urls))

    def test_beta_offers_the_beta_branch_and_downloads_it(self):
        info = self.check("4.5.2", FakeGitHub(main="4.5.2", beta="4.6.0b1"), "beta")
        self.assertTrue(info["updateAvailable"])
        self.assertEqual(info["latestVersion"], "4.6.0b1")
        self.assertEqual(info["latestVersionDisplay"], "4.6.0 beta 1")
        self.assertEqual(info["currentVersionDisplay"], "4.5.2")
        self.assertEqual((info["channel"], info["source"]), ("beta", "github_beta"))
        self.assertTrue(info["latestIsPrerelease"])
        self.assertFalse(info["currentIsPrerelease"])
        self.assertEqual(info["downloadUrl"], "https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta")
        updater.validate_github_url(info["downloadUrl"])

    def test_without_a_channel_argument_the_saved_channel_is_used(self):
        github = FakeGitHub(main="4.5.2", beta="4.6.0b1")
        self.assertFalse(updater.check_for_updates("4.5.2", opener=github)["updateAvailable"])
        updater.set_channel("beta")
        info = updater.check_for_updates("4.5.2", opener=github)
        self.assertEqual((info["channel"], info["latestVersion"]), ("beta", "4.6.0b1"))

    def test_turning_beta_off_never_downgrades(self):
        info = self.check("4.6.0b2", FakeGitHub(main="4.5.2", beta="4.6.0b2"), "stable")
        self.assertFalse(info["updateAvailable"])
        self.assertTrue(info["currentIsPrerelease"])
        self.assertEqual(info["currentVersionDisplay"], "4.6.0 beta 2")
        # The stable release of the same number replaces the beta.
        info = self.check("4.6.0b2", FakeGitHub(main="4.6.0", beta="4.6.0b2"), "stable")
        self.assertTrue(info["updateAvailable"])
        self.assertEqual(info["downloadUrl"], "https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/main")

    def test_beta_moves_on_to_a_newer_stable_build_and_stable_wins_a_tie(self):
        info = self.check("4.6.0b2", FakeGitHub(main="4.6.0", beta="4.6.0b2"), "beta")
        self.assertEqual((info["latestVersion"], info["source"]), ("4.6.0", "github_main"))
        info = self.check("4.5.2", FakeGitHub(main="4.6.0", beta="4.6.0"), "beta")
        self.assertEqual(info["source"], "github_main")
        # A hotfix on main that beta has not caught up with yet.
        info = self.check("4.6.0b1", FakeGitHub(main="4.5.3", beta="4.6.0b1"), "beta")
        self.assertFalse(info["updateAvailable"])

    def test_a_missing_beta_branch_falls_back_to_main(self):
        github = FakeGitHub(main="4.5.3")
        info = self.check("4.5.2", github, "beta")
        self.assertTrue(info["updateAvailable"])
        self.assertEqual((info["latestVersion"], info["channel"]), ("4.5.3", "beta"))
        self.assertIn(RAW + "beta/Orbit-Windows-Agent/orbit_agent.py", github.urls)

    def test_a_pre_release_version_on_main_never_reaches_stable_pcs(self):
        github = FakeGitHub(main="4.6.0b1", releases=[release("pc-v4.5.2")])
        info = self.check("4.5.1", github, "stable")
        self.assertEqual(info["latestVersion"], "4.5.2")
        with self.assertRaises(RuntimeError):
            self.check("4.5.1", FakeGitHub(main="4.6.0b1"), "stable")

    def test_github_pre_releases_are_only_for_the_beta_channel(self):
        releases = [release("pc-v4.6.0b3", prerelease=True), release("pc-v4.6.0", prerelease=True),
                    release("pc-v4.5.2"), release("ios-v9.9.9")]
        stable = self.check("4.5.1", FakeGitHub(main="4.5.1", releases=releases), "stable")
        self.assertEqual((stable["latestVersion"], stable["source"]), ("4.5.2", "github_release"))
        beta = self.check("4.5.1", FakeGitHub(main="4.5.1", releases=releases), "beta")
        # GitHub's pre-release box counts even when the number looks stable.
        self.assertEqual((beta["latestVersion"], beta["source"]), ("4.6.0", "github_prerelease"))
        self.assertTrue(beta["latestIsPrerelease"])
        self.assertEqual(beta["downloadUrl"],
                         f"https://github.com/{OWNER_REPO}/releases/download/pc-v4.6.0/Orbit-Windows-Agent.zip")
        bare = self.check("4.5.1", FakeGitHub(main="4.5.1", releases=[release("pc-v4.6.0b3", True, asset=False)]), "beta")
        self.assertEqual(bare["downloadUrl"], "https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta")

    def test_offline_is_still_an_error(self):
        def offline(request, timeout=6.0):
            raise urllib.error.URLError("offline")
        with self.assertRaises(RuntimeError):
            self.check("4.5.2", offline, "beta")


class BetaDownloadTests(unittest.TestCase):
    def test_branch_urls_are_trusted_and_only_main_or_beta(self):
        self.assertEqual(updater.branch_download_url("beta"),
                         "https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta")
        self.assertEqual(updater.branch_download_url("main"),
                         "https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/main")
        updater.validate_github_url(updater.branch_download_url("beta"))
        for branch in ("../main", "release", ""):
            with self.assertRaises(ValueError):
                updater.branch_download_url(branch)

    def test_the_beta_branch_zip_installs_like_main(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("Orbit-beta/Orbit-Windows-Agent/orbit_agent.py", 'AGENT_VERSION = "4.6.0b1"\n')
            zf.writestr("Orbit-beta/Orbit-Windows-Agent/.orbit-token", "never-copied")
        requested = []

        def opener(request, timeout=6.0):
            requested.append(request.full_url)
            return io.BytesIO(archive.getvalue())
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / ".orbit-token").write_text("kept", encoding="utf-8")
            updated = updater.download_and_apply_update(updater.branch_download_url("beta"), target_dir=folder,
                                                        opener=opener)
            self.assertEqual(updated, ["orbit_agent.py"])
            self.assertIn("4.6.0b1", (Path(folder) / "orbit_agent.py").read_text(encoding="utf-8"))
            self.assertEqual((Path(folder) / ".orbit-token").read_text(encoding="utf-8"), "kept")
        self.assertEqual(requested, ["https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta"])


class WebcamRefTests(TempSettings):
    def refs(self, version):
        with patch.object(webcam, "_agent_version", return_value=version):
            return webcam.download_refs()

    def test_beta_builds_look_on_the_beta_branch_before_main(self):
        self.assertEqual(self.refs("4.6.0b1"), ["pc-v4.6.0b1", "beta", "main"])
        self.assertEqual(self.refs("4.6.0rc2"), ["pc-v4.6.0rc2", "beta", "main"])
        self.assertEqual(self.refs("4.5.2"), ["pc-v4.5.2", "main"])
        updater.set_channel("beta")
        self.assertEqual(self.refs("4.5.2"), ["pc-v4.5.2", "main", "beta"])
        self.assertEqual(self.refs("4.6.0b1"), ["pc-v4.6.0b1", "beta", "main"])
        # Anything that is not a canonical version never becomes part of a URL.
        self.assertEqual(self.refs("4.6.0-beta.1/../x"), ["main", "beta"])

    def test_the_beta_branch_dll_url_is_trusted(self):
        url = webcam.download_url("softcam64.dll", "beta")
        self.assertEqual(url, RAW + "beta/Orbit-Windows-Agent/webcam/softcam64.dll")
        updater.validate_github_url(url)


class TrayBetaItemTests(TempSettings):
    def make_icon(self, answer=tray.IDOK, version="4.5.2", checker=None):
        user32, shell32, kernel32 = MagicMock(), MagicMock(), MagicMock()
        kernel32.GetConsoleWindow.return_value = 0
        shell32.Shell_NotifyIconW.return_value = 1
        user32.MessageBoxW.return_value = answer
        self.checks = []

        def default_checker(current):
            self.checks.append(updater.current_channel(self.store))
            return {"currentVersion": current, "latestVersion": current, "updateAvailable": False,
                    "channel": updater.current_channel(self.store), "repository": OWNER_REPO}
        icon = tray.OrbitTrayIcon(status_provider=lambda: {"agentVersion": version}, on_stop=lambda: None,
                                  startup_manager=MagicMock(is_enabled=MagicMock(return_value=False)),
                                  boot_task=MagicMock(is_installed=MagicMock(return_value=False)),
                                  update_checker=checker or default_checker, apis=(user32, shell32, kernel32),
                                  settings_store=self.store)
        icon._hwnd = 555
        return icon, user32

    def item(self, icon):
        return next(item for item in icon.build_menu_items() if item.get("id") == tray.ID_BETA_UPDATES)

    def dialog_titles(self, user32):
        return [call.args[2] for call in user32.MessageBoxW.call_args_list]

    def test_menu_item_is_checkable_and_follows_the_setting(self):
        icon, _ = self.make_icon()
        self.assertEqual(self.item(icon)["label"], "Beta updates")
        self.assertFalse(self.item(icon)["checked"])
        updater.set_channel("beta", self.store)
        self.assertTrue(self.item(icon)["checked"])
        ids = [item.get("id") for item in icon.build_menu_items()]
        self.assertEqual(ids.index(tray.ID_BETA_UPDATES), ids.index(tray.ID_CHECK_UPDATES) + 1)

    def test_first_time_on_explains_then_checks_for_a_beta(self):
        icon, user32 = self.make_icon()
        outcome = icon.toggle_beta_updates()
        self.assertEqual(outcome["status"], "beta_on")
        self.assertEqual(updater.current_channel(self.store), "beta")
        self.assertTrue(updater.beta_notice_shown(self.store))
        self.assertEqual(self.dialog_titles(user32)[0], tray.BETA_NOTICE_TITLE)
        self.assertIn("bugs", tray.BETA_NOTICE_TEXT)
        self.assertIn("never goes back to an older one", tray.BETA_NOTICE_TEXT)
        self.assertEqual(self.checks, ["beta"])  # the update check ran on the beta channel

        # Off: saved at once, no dialog and no update check.
        user32.MessageBoxW.reset_mock()
        self.assertEqual(icon.toggle_beta_updates()["status"], "beta_off")
        self.assertEqual(updater.current_channel(self.store), "stable")
        user32.MessageBoxW.assert_not_called()
        self.assertEqual(self.checks, ["beta"])

        # On again: the explanation is not repeated.
        self.assertEqual(icon.toggle_beta_updates()["status"], "beta_on")
        self.assertNotIn(tray.BETA_NOTICE_TITLE, self.dialog_titles(user32))
        self.assertEqual(self.checks, ["beta", "beta"])

    def test_turning_off_on_a_beta_build_says_it_is_kept(self):
        icon, _ = self.make_icon(version="4.6.0b2")
        updater.set_channel("beta", self.store)
        with patch.object(icon, "show_notification") as toast:
            self.assertEqual(icon.toggle_beta_updates()["status"], "beta_off")
        title, text = toast.call_args.args
        self.assertEqual(title, "Beta updates are off")
        self.assertIn("keeps beta build 4.6.0 beta 2 until a newer stable version", text)
        self.assertEqual(self.checks, [])  # no update check, so nothing is ever downgraded

    def test_cancel_keeps_stable(self):
        icon, _ = self.make_icon(answer=2)  # IDCANCEL
        self.assertEqual(icon.toggle_beta_updates()["status"], "cancelled")
        self.assertEqual(updater.current_channel(self.store), "stable")
        self.assertFalse(updater.beta_notice_shown(self.store))
        self.assertEqual(self.checks, [])

    def test_menu_command_runs_on_a_helper_thread(self):
        icon, _ = self.make_icon()
        with patch.object(icon, "toggle_beta_updates_async") as start:
            self.assertEqual(icon.execute_command(tray.ID_BETA_UPDATES), "beta_toggle_started")
        start.assert_called_once_with()

    def test_beta_versions_are_shown_in_words(self):
        icon, _ = self.make_icon(version="4.6.0b1")
        self.assertEqual(icon.build_menu_items()[0]["label"], "Orbit PC Companion 4.6.0 beta 1")
        self.assertIn("4.6.0 beta 1", icon.format_tooltip())

    def test_up_to_date_on_a_beta_build_with_beta_off_explains_why(self):
        icon, user32 = self.make_icon(version="4.6.0b2", checker=lambda current: {
            "currentVersion": current, "latestVersion": "4.5.2", "updateAvailable": False, "channel": "stable",
            "repository": OWNER_REPO})
        self.assertEqual(icon.perform_update_check()["status"], "up_to_date")
        text = user32.MessageBoxW.call_args.args[1]
        self.assertIn("beta build 4.6.0 beta 2", text)
        self.assertIn("Beta updates are off", text)

    def test_update_prompt_names_the_beta_channel(self):
        installed = []
        icon, user32 = self.make_icon(answer=tray.IDYES, checker=lambda current: {
            "currentVersion": current, "latestVersion": "4.6.0b1", "updateAvailable": True, "channel": "beta",
            "downloadUrl": updater.branch_download_url("beta"), "repository": OWNER_REPO})
        icon.update_installer = lambda url: installed.append(url) or ["orbit_agent.py"]
        self.assertEqual(icon.perform_update_check()["status"], "updated")
        self.assertEqual(installed, ["https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta"])
        prompt = user32.MessageBoxW.call_args_list[0].args[1]
        self.assertIn("Latest version: 4.6.0 beta 1", prompt)
        self.assertIn("Updates: Beta", prompt)

    def test_the_real_checker_gets_the_trays_channel(self):
        icon, _ = self.make_icon()
        icon.update_checker = None
        updater.set_channel("beta", self.store)
        reply = {"currentVersion": "4.5.2", "latestVersion": "4.5.2", "updateAvailable": False, "channel": "beta"}
        with patch.object(updater, "check_for_updates", return_value=reply) as check:
            icon.perform_update_check()
        check.assert_called_once_with("4.5.2", channel="beta")


class AgentChannelTests(TempSettings):
    def setUp(self):
        super().setUp()
        for patcher in (patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent.orbit_energy, "start")):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.client = TestClient(agent.app)
        self.addCleanup(self.client.close)
        self.auth = {"Authorization": f"Bearer {TOKEN}"}

    def test_status_and_update_check_report_the_channel(self):
        self.assertEqual(self.client.get("/api/status", headers=self.auth).json()["updateChannel"], "stable")
        updater.set_channel("beta")
        self.assertEqual(self.client.get("/api/status", headers=self.auth).json()["updateChannel"], "beta")
        self.assertEqual(agent.tray_status_snapshot()["updateChannel"], "beta")
        github = FakeGitHub(main=agent.AGENT_VERSION, beta="99.0.0b1")
        with patch.object(updater, "urlopen", github):
            reply = self.client.get("/api/update/check", headers=self.auth).json()
        self.assertEqual((reply["channel"], reply["latestVersion"]), ("beta", "99.0.0b1"))
        self.assertEqual(reply["latestVersionDisplay"], "99.0.0 beta 1")
        self.assertTrue(reply["updateAvailable"])

    def test_turning_beta_off_never_downgrades_through_the_api(self):
        github = FakeGitHub(main="0.1.0", beta="0.1.0b1")
        with patch.object(agent, "AGENT_VERSION", "99.0.0b1"), patch.object(updater, "urlopen", github), \
             patch.object(updater, "download_and_apply_update") as install:
            reply = self.client.post("/api/update/apply", headers=self.auth).json()
        self.assertEqual(reply["status"], "up_to_date")
        install.assert_not_called()


if __name__ == "__main__":
    unittest.main()
