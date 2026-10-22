"""Hardening regressions: secrets, frozen builds, private clipboard, preview pacing, updates.

Nothing here touches the real clipboard, screen, network or installed files: native
boundaries are mocked and every file lives in a temporary folder.
"""
import asyncio
import ctypes
import io
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
import zipfile

from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import orbit_agent as agent
import orbit_desktop as desktop
import orbit_files as files
import orbit_paths
import orbit_screen as screen
import orbit_tray as tray
import orbit_updater as updater

AGENT_FOLDER = Path(__file__).resolve().parent
TOKEN = "hardening-test-token-with-more-than-24-chars"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def files_client():
    def authorized(request: Request):
        if request.headers.get("authorization") != "Bearer control":
            raise HTTPException(401, "Control token required")
    app = FastAPI()
    app.include_router(files.create_files_router(authorized))
    return TestClient(app, base_url="https://test", headers={"Authorization": "Bearer control"})


class SecretFileTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name).resolve()
        self.client = files_client()

    def tearDown(self):
        self.client.close()
        self.folder.cleanup()

    def test_sunshine_login_is_hidden_and_refused_everywhere(self):
        (self.root / ".orbit-sunshine-login").write_text('{"username": "a", "password": "b"}')
        (self.root / ".orbit-devices.json").write_text("{}")
        (self.root / "notes.txt").write_text("allowed")
        listing = self.client.get("/api/files/list", params={"path": str(self.root)}).json()
        self.assertEqual([row["name"] for row in listing["entries"]], ["notes.txt"])
        for name in (".orbit-sunshine-login", ".orbit-devices.json"):
            path = str(self.root / name)
            self.assertEqual(self.client.get("/api/files/download", params={"path": path}).status_code, 403)
            self.assertEqual(self.client.post("/api/files/rename", json={"path": path, "name": "x.txt"}).status_code, 403)
            self.assertEqual(self.client.post("/api/files/mkdir", json={"parent": str(self.root), "name": name}).status_code, 403)
        self.assertEqual(self.client.post("/api/files/upload", params={"directory": str(self.root), "name": ".orbit-sunshine-login"},
                                          content=b"x").status_code, 403)

    def test_custom_sunshine_login_path_and_registered_secrets_are_protected(self):
        custom = self.root / "sunshine-login.json"
        custom.write_text("secret")
        with patch.dict(files.os.environ, {"ORBIT_SUNSHINE_LOGIN_FILE": str(custom)}):
            self.assertEqual(self.client.get("/api/files/download", params={"path": str(custom)}).status_code, 403)
        registered = self.root / "registry.db"
        registered.write_text("secret")
        with patch.object(orbit_paths, "_PROTECTED", [registered.absolute()]):
            self.assertEqual(self.client.get("/api/files/download", params={"path": str(registered)}).status_code, 403)
            self.assertEqual(self.client.get("/api/files/list", params={"path": str(self.root)}).json()["total"], 1)

    def test_agent_registers_its_own_secret_files(self):
        protected = orbit_paths.registered_protected_paths()
        for path in (agent.TOKEN_PATH, agent.WIDGET_TOKEN_PATH, agent.SUNSHINE_CREDENTIALS_PATH):
            self.assertIn(Path(path).absolute(), protected)

    def test_sunshine_login_file_is_private_and_replaced_atomically(self):
        target = self.root / ".orbit-sunshine-login"
        agent.write_private_file(target, '{"username": "a", "password": "b"}')
        agent.write_private_file(target, '{"username": "c", "password": "d"}')
        self.assertEqual(target.read_text(), '{"username": "c", "password": "d"}')
        self.assertEqual([item.name for item in self.root.iterdir()], [".orbit-sunshine-login"])
        if os.name != "nt":
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)


class FrozenBuildTests(unittest.TestCase):
    def test_runtime_directory_follows_the_executable_not_meipass(self):
        with tempfile.TemporaryDirectory() as folder:
            installed = Path(folder) / "Orbit"
            unpacked = Path(folder) / "_MEI12345"
            installed.mkdir()
            unpacked.mkdir()
            with patch.object(orbit_paths.sys, "frozen", True, create=True), \
                 patch.object(orbit_paths.sys, "executable", str(installed / "OrbitCompanion.exe")), \
                 patch.object(orbit_paths.sys, "_MEIPASS", str(unpacked), create=True):
                self.assertEqual(orbit_paths.runtime_directory(), installed.resolve())
                self.assertEqual(orbit_paths.program_directories(), [installed.resolve(), unpacked.resolve()])
                with self.assertRaises(updater.FrozenBuildError):
                    updater._default_target()

    def test_source_build_runtime_directory_is_the_agent_folder(self):
        self.assertEqual(orbit_paths.runtime_directory(), AGENT_FOLDER)
        self.assertEqual(files.AGENT_DIRECTORY, AGENT_FOLDER.absolute())

    def test_files_api_never_writes_into_the_unpack_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            unpacked = Path(folder).resolve() / "_MEI1"
            unpacked.mkdir()
            client = files_client()
            self.addCleanup(client.close)
            with patch.object(files.orbit_paths, "program_directories", return_value=[AGENT_FOLDER, unpacked]):
                response = client.post("/api/files/mkdir", json={"parent": str(unpacked), "name": "planted"})
            self.assertEqual(response.status_code, 403)
            self.assertFalse((unpacked / "planted").exists())


class TokenDisplayTests(unittest.TestCase):
    def test_mask_keeps_only_the_last_four_characters(self):
        self.assertEqual(orbit_paths.mask_secret("abcdefghijklmnopqrstuvwxyz1234"), "••••••••1234")
        self.assertEqual(orbit_paths.mask_secret("abc"), "••••••••")

    def test_background_log_never_receives_the_token(self):
        network = {"ipAddress": "192.168.1.20"}
        background = "\n".join(agent.startup_banner(network, TOKEN, "AA:BB", interactive=False))
        self.assertNotIn(TOKEN, background)
        self.assertNotIn(TOKEN[-4:], background)
        console = "\n".join(agent.startup_banner(network, TOKEN, "AA:BB", interactive=True))
        self.assertNotIn(TOKEN, console)
        self.assertIn("••••••••" + TOKEN[-4:], console)

    def test_log_file_is_not_an_interactive_console(self):
        with tempfile.TemporaryFile("w+") as log:
            self.assertFalse(orbit_paths.interactive_console(log))
        self.assertFalse(orbit_paths.interactive_console(None) and sys.stdout is None)

    def test_pairing_code_stays_out_of_the_windows_background_log(self):
        import orbit_pairing
        output = io.StringIO()
        with patch.object(orbit_pairing.os, "name", "nt"), patch.object(orbit_pairing.orbit_paths, "interactive_console", return_value=False), \
             patch.object(orbit_pairing.threading, "Thread"), patch("sys.stdout", output):
            orbit_pairing.display_pin("iPhone", "123456")
        self.assertNotIn("123456", output.getvalue())


class ClipboardFake:
    def __init__(self):
        self.user = MagicMock()
        self.kernel = MagicMock()
        self.user.CreateWindowExW.return_value = 123
        self.user.OpenClipboard.return_value = True
        self.user.EmptyClipboard.return_value = True
        self.user.SetClipboardData.side_effect = lambda fmt, handle: handle
        self.formats = {}
        self.user.RegisterClipboardFormatW.side_effect = lambda name: self.formats.setdefault(name, 0xC000 + len(self.formats))
        self.sequence = 41
        self.user.GetClipboardSequenceNumber.side_effect = lambda: self.sequence
        self.buffers = {}
        self.next_handle = 1000

        def allocate(flags, size):
            self.next_handle += 1
            self.buffers[self.next_handle] = ctypes.create_string_buffer(size)
            return self.next_handle
        self.kernel.GlobalAlloc.side_effect = allocate
        self.kernel.GlobalLock.side_effect = lambda handle: ctypes.addressof(self.buffers[handle])

    def clipboard(self):
        return desktop.WindowsClipboard((self.user, self.kernel))


class PrivateClipboardTests(unittest.TestCase):
    def test_private_copy_is_excluded_from_history_and_cloud_sync(self):
        native = ClipboardFake()
        sequence = native.clipboard().write("secret-token", exclude_from_history=True)
        self.assertEqual(sequence, 41)
        self.assertEqual(set(native.formats), {"ExcludeClipboardContentFromMonitorProcessing",
                                               "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"})
        written = {call.args[0]: native.buffers[call.args[1]].raw for call in native.user.SetClipboardData.call_args_list}
        self.assertEqual(written[13], "secret-token".encode("utf-16-le") + b"\0\0")
        self.assertEqual(written[native.formats["CanIncludeInClipboardHistory"]], b"\0\0\0\0")
        self.assertEqual(written[native.formats["CanUploadToCloudClipboard"]], b"\0\0\0\0")
        native.kernel.GlobalFree.assert_not_called()

    def test_regular_copy_from_the_app_stays_a_normal_copy(self):
        native = ClipboardFake()
        native.clipboard().write("hello")
        native.user.RegisterClipboardFormatW.assert_not_called()
        self.assertEqual(native.user.SetClipboardData.call_count, 1)

    def test_private_copy_is_cleared_only_if_nothing_else_was_copied(self):
        native = ClipboardFake()
        self.assertTrue(native.clipboard().clear_if_unchanged(41))
        native.user.EmptyClipboard.reset_mock()
        native.sequence = 42  # the user copied something else meanwhile
        self.assertFalse(native.clipboard().clear_if_unchanged(41))
        native.user.EmptyClipboard.assert_not_called()

    def test_copy_private_text_schedules_the_clear(self):
        native = ClipboardFake()
        timers = []

        class Timer:
            def __init__(self, delay, function):
                timers.append((delay, function))
                self.daemon = False

            def start(self):
                pass
        desktop.copy_private_text("token-value", clear_after=60, clipboard_factory=native.clipboard, timer_factory=Timer)
        self.assertEqual(timers[0][0], 60)
        timers[0][1]()
        native.user.EmptyClipboard.assert_called()

    def test_tray_copies_the_token_privately(self):
        icon = tray.OrbitTrayIcon(status_provider=lambda: {}, on_stop=lambda: None, token_provider=lambda: TOKEN,
                                  apis=(MagicMock(), MagicMock(), MagicMock()))
        with patch.object(desktop, "copy_private_text") as private, patch.object(desktop.WindowsClipboard, "write") as plain:
            self.assertEqual(icon.execute_command(tray.ID_COPY_TOKEN), "token_copied")
        private.assert_called_once_with(TOKEN)
        plain.assert_not_called()


class FakeGrab:
    def __init__(self, delay=0.0, frames=None):
        self.delay = delay
        self.frames = frames or [b"\x10\x20\x30\x00" * 4]
        self.calls = 0
        self.monitors = [{"all": True}, {"left": 0, "top": 0, "width": 2, "height": 2}]
        self.closed = False

    def grab(self, monitor):
        time.sleep(self.delay)
        data = self.frames[min(self.calls, len(self.frames) - 1)]
        self.calls += 1
        return SimpleNamespace(size=(2, 2), bgra=data)

    def close(self):
        self.closed = True


class ScreenPreviewTests(unittest.TestCase):
    def test_capture_and_encode_run_on_the_preview_thread_not_the_event_loop(self):
        grab = FakeGrab(delay=0.05)
        source = screen.FrameSource(capture_factory=lambda: grab)
        sent, ticks = [], []

        async def run():
            loop_thread = threading.current_thread().name

            async def ticker():
                while True:
                    ticks.append(time.monotonic())
                    await asyncio.sleep(0.005)
            task = asyncio.create_task(ticker())

            async def send(data):
                sent.append(data)
            # Frames differ so every one is encoded and sent.
            grab.frames = [bytes([value, 0, 0, 0]) * 4 for value in range(10)]
            await screen.stream_frames(send, source, max_frames=3)
            task.cancel()
            return loop_thread
        loop_thread = asyncio.run(run())
        self.assertEqual(len(sent), 3)
        self.assertTrue(all(frame.startswith(b"\xff\xd8") for frame in sent))  # JPEG
        self.assertTrue(source.thread_names)
        self.assertTrue(all(name.startswith("orbit-screen") for name in source.thread_names))
        self.assertNotIn(loop_thread, source.thread_names)
        # The loop kept running while each 50 ms grab was in progress.
        self.assertGreater(len(ticks), 10)
        time.sleep(0.05)
        self.assertTrue(grab.closed)

    def test_unchanged_screen_is_not_reencoded_but_kept_alive(self):
        grab = FakeGrab()
        source = screen.FrameSource(capture_factory=lambda: grab)
        sent = []
        clock = {"now": 0.0}

        async def fake_sleep(seconds):
            clock["now"] += max(seconds, 0.2)

        async def send(data):
            sent.append(data)

        async def run():
            await screen.stream_frames(send, source, clock=lambda: clock["now"], sleep=fake_sleep, max_frames=3)
        asyncio.run(run())
        # Same pixels: the first frame, then only keepalive re-sends of the same bytes.
        self.assertEqual(len(set(sent)), 1)
        self.assertGreaterEqual(grab.calls, 6)

    def test_pacing_slows_down_for_slow_capture_or_link_and_quality_adapts(self):
        self.assertAlmostEqual(screen.next_interval(0.001, 0.001), screen.MIN_INTERVAL)
        self.assertAlmostEqual(screen.next_interval(0.1, 0.0), 0.15)
        self.assertEqual(screen.next_interval(5, 5), screen.MAX_INTERVAL)
        self.assertEqual(screen.next_quality(0, 1.0), 1)
        self.assertEqual(screen.next_quality(len(screen.QUALITY_STEPS) - 1, 1.0), len(screen.QUALITY_STEPS) - 1)
        self.assertEqual(screen.next_quality(1, 0.0), 0)

    def test_missing_display_is_reported(self):
        grab = FakeGrab()
        grab.monitors = [{"all": True}]
        source = screen.FrameSource(capture_factory=lambda: grab)

        async def run():
            await screen.stream_frames(lambda data: None, source, max_frames=1)
        with self.assertRaises(screen.NoDisplay):
            asyncio.run(run())

    def test_endpoint_streams_frames_and_limits_concurrent_previews(self):
        grab = FakeGrab()
        client = TestClient(agent.app)
        self.addCleanup(client.close)
        with patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent, "HAS_SCREEN_CAPTURE", True), \
             patch.object(agent, "screen_frame_source", lambda: screen.FrameSource(capture_factory=lambda: grab)):
            with client.websocket_connect("/ws/stream", headers=AUTH) as websocket:
                self.assertTrue(websocket.receive_bytes().startswith(b"\xff\xd8"))
            busy = screen.StreamSlots(limit=0)
            with patch.object(agent, "SCREEN_STREAMS", busy):
                with client.websocket_connect("/ws/stream", headers=AUTH) as websocket:
                    with self.assertRaises(WebSocketDisconnect) as refused:
                        websocket.receive_bytes()
                self.assertEqual(refused.exception.code, 1013)


class UpdateApplyTests(unittest.TestCase):
    def setUp(self):
        self.token = patch.object(agent, "API_TOKEN", TOKEN)
        self.token.start()
        self.http = TestClient(agent.app)
        self.https = TestClient(agent.app, base_url="https://testserver")

    def tearDown(self):
        self.http.close()
        self.https.close()
        self.token.stop()

    def test_apply_needs_https_and_is_refused_in_a_frozen_build(self):
        with patch("orbit_updater.check_for_updates") as check, patch("orbit_updater.apply_update") as apply:
            self.assertEqual(self.http.post("/api/update/apply", headers=AUTH).status_code, 426)
            with patch.object(agent.orbit_paths, "is_frozen", return_value=True):
                response = self.https.post("/api/update/apply", headers=AUTH)
            self.assertEqual(response.status_code, 409)
            self.assertIn("OrbitCompanion.exe", response.json()["detail"])
            check.assert_not_called()
            apply.assert_not_called()

    def test_apply_reports_files_and_dependency_status(self):
        info = {"updateAvailable": True, "latestVersion": "5.1.0", "downloadUrl": "https://codeload.github.com/x.zip"}
        result = updater.UpdateResult(files=["orbit_agent.py", "requirements.txt"], dependencies="installed")
        with patch("orbit_updater.check_for_updates", return_value=info), patch("orbit_updater.apply_update", return_value=result):
            body = self.https.post("/api/update/apply", headers=AUTH).json()
        self.assertEqual(body["status"], "updated")
        self.assertEqual(body["updatedFiles"], ["orbit_agent.py", "requirements.txt"])
        self.assertEqual(body["dependencies"], "installed")
        self.assertTrue(body["restartRequired"])


def archive(files_by_name):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as output:
        for name, text in files_by_name.items():
            output.writestr("Orbit-main/Orbit-Windows-Agent/" + name, text)
    return buffer.getvalue()


class DependencyUpdateTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.target = Path(self.folder.name).resolve()
        (self.target / "orbit_agent.py").write_text('AGENT_VERSION = "5.0.0"\n')
        (self.target / "requirements.txt").write_text("fastapi>=0.115,<1\n")
        python = self.target / ".venv" / "Scripts" / "python.exe"
        python.parent.mkdir(parents=True)
        python.write_bytes(b"MZ")
        self.python = python

    def tearDown(self):
        self.folder.cleanup()

    def apply(self, files_by_name, runner):
        with patch.object(updater, "_fetch_bytes", return_value=archive(files_by_name)):
            return updater.apply_update("https://codeload.github.com/x.zip", target_dir=self.target, pip_runner=runner)

    def test_changed_requirements_are_installed_into_the_private_venv(self):
        calls = []
        result = self.apply({"orbit_agent.py": 'AGENT_VERSION = "5.1.0"\n', "requirements.txt": "fastapi>=0.115,<1\nnewdep>=1\n"},
                            lambda command: calls.append(command) or SimpleNamespace(returncode=0, stdout="", stderr=""))
        self.assertEqual(result.dependencies, "installed")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], [str(self.python), "-m", "pip", "install"])
        self.assertEqual(calls[0][-2:], ["-r", str(self.target.resolve() / "requirements.txt")])

    def test_unchanged_requirements_do_not_run_pip(self):
        runner = MagicMock()
        result = self.apply({"orbit_agent.py": 'AGENT_VERSION = "5.1.0"\n', "requirements.txt": "fastapi>=0.115,<1\n"}, runner)
        self.assertEqual(result.dependencies, "unchanged")
        runner.assert_not_called()

    def test_pip_failure_is_reported_not_hidden(self):
        result = self.apply({"orbit_agent.py": "x = 1\n", "requirements.txt": "other\n"},
                            lambda command: SimpleNamespace(returncode=1, stdout="", stderr="Access is denied"))
        self.assertEqual(result.dependencies, "failed")
        self.assertIn("install_orbit.bat", result.dependencyMessage)

    def test_without_a_private_venv_the_owner_is_told_to_run_the_installer(self):
        self.python.unlink()
        runner = MagicMock()
        result = self.apply({"orbit_agent.py": "x = 1\n", "requirements.txt": "other\n"}, runner)
        self.assertEqual(result.dependencies, "manual")
        runner.assert_not_called()

    def test_sunshine_login_is_never_overwritten_by_an_update(self):
        (self.target / ".orbit-sunshine-login").write_text("mine")
        self.apply({"orbit_agent.py": "x = 1\n", ".orbit-sunshine-login": "theirs"}, MagicMock())
        self.assertEqual((self.target / ".orbit-sunshine-login").read_text(), "mine")


class VersionTests(unittest.TestCase):
    def test_every_version_string_matches_the_agent(self):
        self.assertEqual(agent.AGENT_VERSION, "5.0.0")
        version = re.escape(agent.AGENT_VERSION)
        self.assertRegex((AGENT_FOLDER / "install_orbit.bat").read_text(), rf"Orbit PC Companion {version} - Windows Installer")
        self.assertRegex((AGENT_FOLDER / "start_agent.bat").read_text(), rf"title Orbit PC Companion {version}")
        launcher = (AGENT_FOLDER / "OrbitCompanion.cs").read_text()
        self.assertIn(f'AssemblyVersion("{agent.AGENT_VERSION}.0")', launcher)
        self.assertIn(f'AssemblyFileVersion("{agent.AGENT_VERSION}.0")', launcher)
        self.assertIn(f"**{agent.AGENT_VERSION}**", (AGENT_FOLDER / "README.md").read_text())
        for name in ("orbit_tray.py", "orbit_pairing.py", "orbit_updater.py"):
            self.assertNotRegex((AGENT_FOLDER / name).read_text(), r'"4\.\d\.\d"|Agent 4\.1|Updater/4')

    def test_updater_reads_the_literal_version_line_old_agents_look_for(self):
        source = (AGENT_FOLDER / "orbit_agent.py").read_text()
        self.assertEqual(updater._AGENT_VERSION_ASSIGN_RE.search(source).group(1), agent.AGENT_VERSION)

    def test_build_script_lists_every_orbit_module(self):
        script = (AGENT_FOLDER / "build_exe.bat").read_text()
        for module in sorted(AGENT_FOLDER.glob("orbit_*.py")):
            if module.stem != "orbit_agent":
                self.assertIn(f'--hidden-import "{module.stem}"', script)


if __name__ == "__main__":
    unittest.main()
