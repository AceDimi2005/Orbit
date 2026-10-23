"""Full-screen streaming and the virtual second screen (orbit_stream_display).

Every Windows API, Sunshine and the process list are fakes: nothing here touches the network,
the registry, the displays or the Virtual Display Driver of the machine running the tests.
"""
import base64
import ctypes
import http.client
import io
import json
from pathlib import Path
import re
import socket
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
import urllib.error
import xml.etree.ElementTree as ET

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.testclient import TestClient

import orbit_settings
import orbit_stream_display as sd
import orbit_tray as tray

VDD_ID = "{9a7f2e1c-4b3d-5e6f-8a9b-0c1d2e3f4a5b}"
MONITOR_ID = "{daeac860-f4db-5208-b1f5-cf59444fb768}"
PARSEC_ID = "{1f2e3d4c-5b6a-7980-a1b2-c3d4e5f60718}"

VDD_XML = """<?xml version='1.0' encoding='utf-8'?>
<!-- Virtual Display Driver (HDR) - configuration file -->
<vdd_settings>

    <!-- === BASIC DRIVER CONFIGURATION === -->
    <monitors>
        <count>1</count>
    </monitors>

    <gpu>
        <friendlyname>default</friendlyname>
    </gpu>

    <global>
        <!-- Global refresh rates - applied to all resolutions -->
        <g_refresh_rate>60</g_refresh_rate>
        <g_refresh_rate>90</g_refresh_rate>
        <g_refresh_rate>144</g_refresh_rate>
    </global>

    <resolutions>
        <resolution>
            <width>1920</width>
            <height>1080</height>
            <refresh_rate>60</refresh_rate>
        </resolution>
        <resolution>
            <width>3840</width>
            <height>2160</height>
            <refresh_rate>60</refresh_rate>
        </resolution>
    </resolutions>

    <logging>
        <SendLogsThroughPipe>true</SendLogsThroughPipe>
        <logging>false</logging>
        <debuglogging>false</debuglogging> <!-- WARNING: Debug logging creates large files -->
    </logging>

    <edid_integration>
        <enabled>false</enabled>
        <edid_profile_path>EDID/monitor_profile.xml</edid_profile_path>
    </edid_integration>

    <!-- === REMOVED SECTIONS ===
    </resolutions> inside a comment must not confuse anything
    === -->

</vdd_settings>
<!-- trailing note kept by Orbit -->
"""

LOG_2025_INACTIVE = f"""[2025-01-25 19:41:57.120]: Info: Sunshine version: v2025.118.151840
[2025-01-25 19:41:57.388]: Info: Currently available display devices:
[
  {{
    "device_id": "{VDD_ID}",
    "display_name": "",
    "friendly_name": "VDD by MTT",
    "info": null
  }},
  {{
    "device_id": "{MONITOR_ID}",
    "display_name": "\\\\\\\\.\\\\DISPLAY1",
    "friendly_name": "ROG PG279Q",
    "info": {{
      "hdr_state": null,
      "origin_point": {{"x": 0, "y": 0}},
      "primary": true,
      "refresh_rate": {{"type": "double", "value": 119.998}},
      "resolution": {{"height": 1440, "width": 2560}},
      "resolution_scale": {{"type": "rational", "value": {{"denominator": 100, "numerator": 100}}}}
    }}
  }}
]
[2025-01-25 19:41:57.390]: Info: Configuration UI available at [https://localhost:47990]
"""

LOG_2026_EDID_CRLF = (
    "[2026-10-17 15:20:30.001]: Info: Sunshine version: 2026.1017.152030\r\n"
    "[2026-10-17 15:20:30.512]: Info: Currently available display devices:\r\n"
    "[\r\n"
    "  {\r\n"
    f'    "device_id": "{PARSEC_ID}",\r\n'
    '    "display_name": "",\r\n'
    '    "edid": {"manufacturer_id": "PSC", "product_code": "0001", "serial_number": 0},\r\n'
    '    "friendly_name": "Parsec Virtual Display",\r\n'
    '    "info": null\r\n'
    "  },\r\n"
    "  {\r\n"
    f'    "device_id": "{VDD_ID}",\r\n'
    '    "display_name": "\\\\\\\\.\\\\DISPLAY3",\r\n'
    '    "edid": {"manufacturer_id": "MTT", "product_code": "1337", "serial_number": 7911},\r\n'
    '    "friendly_name": "Generic Monitor",\r\n'
    '    "info": {"hdr_state": null, "origin_point": {"x": 2560, "y": 0}, "primary": false,\r\n'
    '             "refresh_rate": {"type": "rational", "value": {"denominator": 1, "numerator": 60}},\r\n'
    '             "resolution": {"height": 1080, "width": 1920}, "resolution_scale": null}\r\n'
    "  }\r\n"
    "]\r\n"
)

LOG_NEWER_LIST_WINS = f"""[2026-03-01 10:00:00.000]: Info: Currently available display devices:
[
  {{"device_id": "{MONITOR_ID}", "display_name": "\\\\\\\\.\\\\DISPLAY1", "friendly_name": "DELL U2720Q", "info": null}}
]
[2026-03-01 10:05:00.000]: Info: Recovered the available display layout, but settings for an unavailable display are still pending. Will retry once devices are added or removed. Currently available devices:
[
  {{"device_id": "{MONITOR_ID}", "display_name": "\\\\\\\\.\\\\DISPLAY1", "friendly_name": "DELL U2720Q", "info": null}},
  {{"device_id": "{VDD_ID}", "display_name": "", "friendly_name": "VDD by MTT", "info": null}}
]
"""

LOG_NO_VDD = f"""[2026-03-01 10:00:00.000]: Info: Currently available display devices:
[
  {{"device_id": "{MONITOR_ID}", "display_name": "\\\\\\\\.\\\\DISPLAY1", "friendly_name": "DELL U2720Q", "info": null}}
]
"""

LOG_OLD_SUNSHINE = """[2024-08-01 10:00:00.000]: Info: Sunshine version: v0.23.1
[2024-08-01 10:00:00.100]: Info: Monitor 1 found: \\\\.\\DISPLAY1
"""

LOG_TRUNCATED = LOG_NO_VDD.replace("DELL U2720Q", "VDD by MTT").replace(MONITOR_ID, VDD_ID) + (
    "[2026-03-01 11:00:00.000]: Info: Currently available display devices:\n[\n  {\"device_id\": \"{abc")

LOG_PREFIXED_LINES = (
    "[2026-05-01 09:00:00.000]: Info: Currently available display devices:\n"
    "[2026-05-01 09:00:00.000]: Info: [\n"
    f"[2026-05-01 09:00:00.000]: Info:   {{\"device_id\": \"{VDD_ID}\", \"friendly_name\": \"VDD by MTT\"}}\n"
    "[2026-05-01 09:00:00.000]: Info: ]\n"
)

ORIGINAL_CONFIG = {"sunshine_name": "Gaming-PC", "port": "47989", "min_log_level": "info",
                   "encoder": "nvenc", "dd_configuration_option": "disabled", "global_prep_cmd": "[]"}


def make_store(folder):
    return orbit_settings.SettingsStore(Path(folder) / "settings.json")


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakePs:
    """The few psutil calls stream detection makes."""

    def __init__(self):
        self.sunshine_pid = 4100
        self.sunshine_running = True
        self.sunshine_name = "sunshine.exe"
        self.listening = False  # Sunshine's own TCP listeners (web UI, RTSP) in net_connections
        self.connections = []
        self.fail_connections = False

    def process_iter(self, attrs=None):
        yield SimpleNamespace(pid=4, info={"name": "System"})
        if self.sunshine_running:
            yield SimpleNamespace(pid=self.sunshine_pid, info={"name": self.sunshine_name})
        yield SimpleNamespace(pid=7000, info={"name": "obs64.exe"})

    def net_connections(self, kind="inet"):
        if self.fail_connections:
            raise PermissionError("access denied")
        listeners = []
        if self.sunshine_running and self.listening:
            listeners = [SimpleNamespace(pid=self.sunshine_pid, type=socket.SOCK_STREAM, status="LISTEN",
                                         laddr=SimpleNamespace(ip="0.0.0.0", port=port)) for port in (47990, 48010)]
        return listeners + list(self.connections)

    def stream(self, active=True):
        self.connections = [SimpleNamespace(pid=self.sunshine_pid, type=socket.SOCK_DGRAM,
                                            laddr=SimpleNamespace(ip="0.0.0.0", port=47998), status="NONE")] if active else []


class FakeSunshine:
    """Sunshine's web API as orbit_stream_display uses it, keeping config like Sunshine does."""

    def __init__(self, ps, config=None, version="2026.1017.152030", logs=LOG_2025_INACTIVE):
        self.ps = ps
        self.conf = dict(ORIGINAL_CONFIG if config is None else config)
        self.version = version
        self.log_text = logs
        self.logs_after_restart = None
        self.saved = []
        self.restarts = 0
        self.login = True
        self.unreachable = False
        self.on_save = None
        self.current_game = 0  # /serverinfo currentgame: an app id while an app runs in Sunshine
        self.server_info_error = None
        self.server_info_calls = 0

    def login_saved(self):
        return self.login

    def server_info(self):
        self.server_info_calls += 1
        if self.server_info_error is not None:
            raise self.server_info_error
        if not self.ps.sunshine_running:
            raise ConnectionRefusedError("nothing listens on 47989")
        return self.current_game, "SUNSHINE_SERVER_BUSY" if self.current_game else "SUNSHINE_SERVER_FREE"

    def _check(self):
        if not self.login:
            raise sd.DisplaySetupError(428, sd.LOGIN_MISSING)
        if self.unreachable:
            raise sd.DisplaySetupError(502, sd.SUNSHINE_UNREACHABLE)

    def config(self):
        self._check()
        return dict(self.conf), self.version

    def save_config(self, settings):
        self._check()
        self.saved.append(dict(settings))
        # Sunshine writes every key it gets and drops empty values (confighttp.cpp saveConfig).
        self.conf = {key: value for key, value in settings.items() if value not in (None, "")}
        if self.on_save:
            self.on_save(len(self.saved))

    def restart(self):
        self._check()
        self.restarts += 1
        self.ps.sunshine_pid += 1
        if self.logs_after_restart is not None:
            self.log_text = self.logs_after_restart

    def logs(self):
        self._check()
        return self.log_text


class FakePlatform:
    """The Windows side: the driver's files and devices, the displays, the pipe and UAC."""

    def __init__(self, folder, xml=VDD_XML, instances=("ROOT\\DISPLAY\\0000",), status="running"):
        self.folder = Path(folder)
        self.settings_file = self.folder / "VirtualDisplayDriver" / sd.VDD_SETTINGS_NAME
        if xml is not None:
            self.settings_file.parent.mkdir(parents=True, exist_ok=True)
            self.settings_file.write_bytes(xml.encode("utf-8") if isinstance(xml, str) else xml)
        self.instances = list(instances)
        self.status = status
        self.writable = True
        self.sudovda = False
        self.displays = [sd.Display(name="\\\\.\\DISPLAY1", adapter="NVIDIA GeForce RTX 4080", monitor_id="\\\\?\\DISPLAY#GSM5B7F#",
                                    attached=True, primary=True, vdd=False, x=0, y=0, width=2560, height=1440, refresh=144),
                         sd.Display(name="\\\\.\\DISPLAY3", adapter="Virtual Display Driver", monitor_id="\\\\?\\DISPLAY#MTT1337#5&1",
                                    attached=False, primary=False, vdd=True)]
        self.pipe_commands = []
        self.pipe_error = None
        self.pipe_breaks_driver = False
        self.offered_after_pipe = False
        self.elevated_scripts = []
        self.elevation = "approve"  # approve | decline | timeout | busy | fail | code:N
        self.approve_delay = 0.0  # seconds between the prompt and its approval
        self.helper_busy = 0  # what the helper's own stream check finds: 0 idle, 1 streaming, 2 cannot tell
        self.helper_exit_codes = []
        self.driver_restarts = 0
        self.moves = []
        self.move_result = True

    # registry / devices
    def vdd_settings_path(self):
        return self.settings_file

    def vdd_instances(self):
        return list(self.instances)

    def device_status(self, instance):
        return self.status

    def sudovda_installed(self):
        return self.sudovda

    # files
    def read_file(self, path):
        return Path(path).read_bytes()

    def write_file_as_user(self, path, data):
        if not self.writable:
            raise sd.NeedsElevation("Access is denied")
        Path(path).write_bytes(data)

    # pipe
    def send_pipe_command(self, command):
        sd.encode_pipe_command(command)
        self.pipe_commands.append(command)
        if self.pipe_error:
            raise self.pipe_error
        if self.pipe_breaks_driver:
            self.status = "problem"
        return {"handled": True, "reply": ""}

    # displays
    def list_displays(self):
        return [sd.Display(**vars(display)) for display in self.displays]

    def display_offers_mode(self, name, width, height, refresh):
        return self.offered_after_pipe

    def move_display(self, name, x, y):
        self.moves.append((name, x, y))
        if self.move_result:
            for display in self.displays:
                if display.name == name:
                    display.x, display.y = x, y
        return self.move_result

    # elevation: runs the helper script like PowerShell would (deadline, stream check, file, restart)
    def run_elevated(self, script):
        self.elevated_scripts.append(script)
        if self.elevation == "decline":
            raise sd.ElevationDeclined(sd.UAC_DECLINED)
        if self.elevation == "timeout":
            raise sd.ElevationTimedOut(sd.PROMPT_TIMEOUT)
        if self.elevation == "busy":
            raise sd.ElevationBusy(sd.PROMPT_STILL_OPEN)
        if self.elevation == "fail":
            raise sd.ElevationFailed("The administrator helper did not finish in time.")
        if self.elevation.startswith("code:"):
            return int(self.elevation[5:])
        code = self._interpret(helper_values(script))
        self.helper_exit_codes.append(code)
        return code

    def _interpret(self, values):
        import hashlib
        import time as clock
        if sd.dotnet_ticks(clock.time() + self.approve_delay) > values["deadline"]:
            return 6
        if values["devices"] and self.helper_busy:
            return 7 if self.helper_busy == 1 else 8
        if values["source"]:
            data = Path(values["source"]).read_bytes()
            if hashlib.sha256(data).hexdigest().upper() != values["expected"]:
                return 3
            Path(values["target"]).write_bytes(data)
        if values["devices"]:
            if self.status == "problem":
                self.status = "running"
            self.driver_restarts += 1
        return 0


_PS_TEXT = re.compile(r"\(\[System\.Text\.Encoding\]::UTF8\.GetString\(\[System\.Convert\]::FromBase64String\('([A-Za-z0-9+/=]*)'\)\)\)")


def helper_values(script):
    """The values build_helper_script put into the script, decoded."""
    def text(line_name):
        line = next(line for line in script.splitlines() if line.startswith(f"${line_name} = "))
        return base64.b64decode(_PS_TEXT.search(line).group(1)).decode("utf-8")
    devices_line = next(line for line in script.splitlines() if line.startswith("$devices = @("))
    pids_line = next(line for line in script.splitlines() if line.startswith("$knownSunshine = @("))
    return {"source": text("source"), "target": text("target"), "expected": text("expected"),
            "backup": text("backupName"),
            "devices": [base64.b64decode(item).decode("utf-8") for item in _PS_TEXT.findall(devices_line)],
            "deadline": int(re.search(r"UtcNow\.Ticks -gt (\d+)\) \{ exit 6 \}", script).group(1)),
            "basePort": int(re.search(r"^\$basePort = (\d+)\r?$", script, re.M).group(1)),
            "pids": [int(item) for item in re.findall(r"\d+", pids_line)]}


def make_service(folder, ps=None, sunshine=None, platform=None, clock=None):
    ps = ps or FakePs()
    clock = clock or FakeClock()
    sunshine = sunshine or FakeSunshine(ps)
    platform = platform or FakePlatform(folder)
    store = make_store(folder)
    service = sd.StreamDisplayService(sunshine, store_provider=lambda: store, platform=platform, ps=ps,
                                      clock=clock, sleep=clock.sleep, restart_timeout=10.0,
                                      staging_directory=Path(folder) / "staging", start_placer=False)
    return service, sunshine, platform, ps, store


def make_client(service):
    def verify(authorization: str = Header(None)):
        if authorization != "Bearer control":
            raise HTTPException(401, "Invalid Orbit token")

    def secure(request: Request):
        if request.url.scheme != "https":
            raise HTTPException(426, "Encrypted connection needed")

    app = FastAPI()
    app.include_router(sd.create_stream_display_router(verify, secure, service))
    return TestClient(app, base_url="https://pc.local"), {"Authorization": "Bearer control"}


class ConfigMergeTests(unittest.TestCase):
    def test_merge_keeps_every_key_drops_meta_and_sets_only_managed_keys(self):
        current = {**ORIGINAL_CONFIG, "status": True, "platform": "windows", "version": "2026.1017.1"}
        target = sd.merge_sunshine_config(current, ORIGINAL_CONFIG, sd._fill_overrides(False, VDD_ID))
        for key, value in ORIGINAL_CONFIG.items():
            if key not in sd.MANAGED_KEYS:
                self.assertEqual(target[key], value)
        self.assertNotIn("status", target)
        self.assertNotIn("platform", target)
        self.assertNotIn("version", target)
        self.assertEqual(target["output_name"], VDD_ID)
        self.assertEqual(target["dd_configuration_option"], "ensure_primary")
        self.assertEqual(target["dd_resolution_option"], "auto")
        self.assertEqual(target["dd_refresh_rate_option"], "auto")
        self.assertEqual(set(target) - set(ORIGINAL_CONFIG), {"output_name", "dd_resolution_option", "dd_refresh_rate_option"})

    def test_merge_without_overrides_puts_original_values_back_and_forgets_new_keys(self):
        changed = {**ORIGINAL_CONFIG, "output_name": VDD_ID, "dd_configuration_option": "ensure_active",
                   "dd_resolution_option": "auto", "bitrate": "50000"}
        target = sd.merge_sunshine_config(changed, ORIGINAL_CONFIG, {})
        self.assertEqual(target, {**ORIGINAL_CONFIG, "bitrate": "50000"})

    def test_second_screen_overrides_win_over_fill(self):
        overrides = {**sd._fill_overrides(True, VDD_ID), **sd._second_screen_overrides(VDD_ID)}
        target = sd.merge_sunshine_config(ORIGINAL_CONFIG, ORIGINAL_CONFIG, overrides)
        self.assertEqual(target["dd_configuration_option"], "ensure_active")
        self.assertEqual(target["output_name"], VDD_ID)

    def test_sunshine_version_support(self):
        self.assertTrue(sd.sunshine_supports_display_settings("v2025.118.151840"))
        self.assertTrue(sd.sunshine_supports_display_settings("2026.1017.152030"))
        self.assertTrue(sd.sunshine_supports_display_settings("2025.1001.5"))
        self.assertFalse(sd.sunshine_supports_display_settings("2025.117.1"))
        self.assertFalse(sd.sunshine_supports_display_settings("v0.23.1"))
        self.assertIsNone(sd.sunshine_supports_display_settings("0.0.0"))
        self.assertIsNone(sd.sunshine_supports_display_settings(None))
        self.assertIsNone(sd.sunshine_supports_display_settings("nightly"))


class FillTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.addCleanup(self.service.close)
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def test_enable_posts_full_map_saves_previous_and_restarts(self):
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertTrue(body["changed"])
        self.assertTrue(body["restarted"])
        self.assertTrue(body["sunshineReady"])
        posted = self.sunshine.saved[-1]
        for key, value in ORIGINAL_CONFIG.items():
            if key not in sd.MANAGED_KEYS:
                self.assertEqual(posted[key], value, key)
        self.assertEqual(posted["output_name"], VDD_ID)
        self.assertEqual(posted["dd_configuration_option"], "ensure_primary")
        self.assertEqual(self.sunshine.restarts, 1)
        state = self.store.get("display")
        self.assertEqual(state["savedSunshineConfig"], ORIGINAL_CONFIG)
        self.assertEqual(state["lastSunshineConfig"], ORIGINAL_CONFIG)
        self.assertTrue(state["fill"]["enabled"])
        self.assertTrue(body["display"]["fill"]["enabled"])
        self.assertEqual(body["display"]["config"]["output_name"], VDD_ID)
        self.assertTrue(body["display"]["savedConfig"]["available"])

    def test_only_display_uses_ensure_only_display(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True, "onlyDisplay": True}, headers=self.headers)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_only_display")

    def test_disable_restores_the_previous_config_exactly(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        response = self.client.post("/api/stream/display/fill", json={"enabled": False}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)
        self.assertEqual(self.sunshine.restarts, 2)
        state = self.store.get("display")
        self.assertIsNone(state["savedSunshineConfig"])
        self.assertFalse(state["fill"]["enabled"])
        self.assertEqual(state["lastSunshineConfig"]["output_name"], VDD_ID)  # the revert can be undone too

    def test_disable_keeps_settings_the_user_changed_meanwhile(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.sunshine.conf["encoder"] = "quicksync"
        self.sunshine.conf["fec_percentage"] = "30"
        self.client.post("/api/stream/display/fill", json={"enabled": False}, headers=self.headers)
        self.assertEqual(self.sunshine.conf, {**ORIGINAL_CONFIG, "encoder": "quicksync", "fec_percentage": "30"})

    def test_enabling_again_changes_nothing_and_does_not_restart_even_during_a_stream(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.ps.stream(True)
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(response.json()["changed"])
        self.assertEqual(self.sunshine.restarts, 1)
        self.assertEqual(len(self.sunshine.saved), 1)

    def test_revert_route_turns_everything_off(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        response = self.client.post("/api/stream/display/revert", headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)

    def test_without_the_driver_fill_warns_and_leaves_output_name_alone(self):
        self.platform.instances = []
        self.platform.settings_file.unlink()
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["warning"], sd.NO_VDD_WARNING)
        self.assertNotIn("output_name", self.sunshine.conf)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_primary")

    def test_restarts_sunshine_once_when_it_started_before_the_driver(self):
        self.sunshine.log_text = LOG_NO_VDD
        self.sunshine.logs_after_restart = LOG_2025_INACTIVE
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.sunshine.restarts, 2)  # once to list the driver, once for the new settings

    def test_driver_missing_from_sunshine_even_after_restart_gives_a_warning(self):
        self.sunshine.log_text = LOG_NO_VDD
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["warning"], sd.VDD_NOT_IN_SUNSHINE)
        self.assertNotIn("output_name", self.sunshine.conf)

    def test_missing_login_is_428_and_status_says_so(self):
        self.sunshine.login = False
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 428)
        self.assertEqual(response.json()["detail"], sd.LOGIN_MISSING)
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertFalse(status["loginSaved"])
        self.assertFalse(status["fillReady"])
        self.assertEqual(status["reason"], sd.LOGIN_MISSING)
        self.assertEqual(self.sunshine.saved, [])

    def test_unreachable_sunshine_is_502(self):
        self.sunshine.unreachable = True
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 502)
        self.assertIn("Sunshine", response.json()["detail"])

    def test_old_sunshine_is_refused_before_any_change(self):
        self.sunshine.version = "v0.23.1"
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.SUNSHINE_TOO_OLD)
        self.assertEqual(self.sunshine.saved, [])

    def test_status_reports_ready_with_the_device_id_and_modes(self):
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertTrue(status["fillReady"], status["reason"])
        self.assertIsNone(status["reason"])
        self.assertEqual(status["sunshineVersion"], "2026.1017.152030")
        self.assertTrue(status["sunshineSupported"])
        self.assertTrue(status["loginSaved"])
        self.assertFalse(status["streamActive"])
        vdd = status["virtualDisplay"]
        self.assertTrue(vdd["installed"])
        self.assertEqual(vdd["driver"], "vdd")
        self.assertEqual(vdd["deviceId"], VDD_ID)
        self.assertEqual(vdd["deviceStatus"], "running")
        self.assertIn("1920x1080@144", vdd["modes"])
        self.assertEqual(vdd["refreshRates"], [60, 90, 144])
        self.assertFalse(vdd["attached"])
        self.assertEqual(status["config"], {"dd_configuration_option": "disabled", "dd_resolution_option": None,
                                            "dd_refresh_rate_option": None, "output_name": None})
        self.assertEqual(status["secondScreen"]["active"], False)
        self.assertEqual(status["installCommand"], sd.VDD_INSTALL_COMMAND)

    def test_status_without_driver_explains_the_install(self):
        self.platform.instances = []
        self.platform.settings_file.unlink()
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertFalse(status["virtualDisplay"]["installed"])
        self.assertIsNone(status["virtualDisplay"]["driver"])
        self.assertEqual(status["reason"], sd.VDD_MISSING)
        self.platform.sudovda = True
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertEqual(status["virtualDisplay"]["driver"], "sudovda")
        self.assertEqual(status["reason"], sd.SUDOVDA_ONLY)

    def test_validation_errors_are_422(self):
        self.assertEqual(self.client.post("/api/stream/display/fill", json={}, headers=self.headers).status_code, 422)
        self.assertEqual(self.client.post("/api/stream/display/modes", json={"width": 100, "height": 1179},
                                          headers=self.headers).status_code, 422)
        self.assertEqual(self.client.post("/api/stream/display/second-screen", json={"enabled": True},
                                          headers=self.headers).status_code, 422)
        self.assertEqual(self.client.post("/api/stream/display/second-screen",
                                          json={"enabled": True, "width": 2732, "height": 2048, "position": "top"},
                                          headers=self.headers).status_code, 422)

    def test_routes_need_the_token_and_https(self):
        insecure = TestClient(self.client.app, base_url="http://pc.local")
        self.addCleanup(insecure.close)
        for method, path, body in (("GET", "/api/stream/display", None), ("POST", "/api/stream/display/fill", {"enabled": True}),
                                   ("POST", "/api/stream/display/modes", {"width": 2556, "height": 1179}),
                                   ("POST", "/api/stream/display/second-screen", {"enabled": False}),
                                   ("POST", "/api/stream/display/revert", None)):
            with self.subTest(path=path):
                self.assertEqual(self.client.request(method, path, json=body).status_code, 401)
                self.assertEqual(insecure.request(method, path, json=body, headers=self.headers).status_code, 426)
        self.assertEqual(self.sunshine.saved, [])

    def test_windows_check_guards_changes_but_not_status(self):
        def not_windows():
            raise HTTPException(501, "PC controls require Windows")
        app = FastAPI()
        app.include_router(sd.create_stream_display_router(lambda: None, lambda: None, self.service, require_windows=not_windows))
        client = TestClient(app, base_url="https://pc.local")
        self.addCleanup(client.close)
        self.assertEqual(client.get("/api/stream/display").status_code, 200)
        self.assertEqual(client.post("/api/stream/display/fill", json={"enabled": True}).status_code, 501)
        self.assertEqual(self.sunshine.saved, [])


class RestartRefusalTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def test_running_stream_refuses_with_409_and_changes_nothing(self):
        self.ps.stream(True)
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.STREAM_RUNNING)
        self.assertEqual(self.sunshine.saved, [])
        self.assertEqual(self.sunshine.restarts, 0)
        self.assertEqual(self.store.get("display"), None)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)

    def test_stream_that_starts_after_the_post_rolls_the_config_back(self):
        self.sunshine.on_save = lambda count: self.ps.stream(True) if count == 1 else None
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(self.sunshine.restarts, 0)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)
        self.assertEqual(self.sunshine.saved[-1], ORIGINAL_CONFIG)
        self.assertIsNone(self.store.get("display"))

    def test_unknown_stream_state_refuses(self):
        self.ps.fail_connections = True
        with self.assertLogs("orbit.streamdisplay", level="WARNING"):
            response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.STREAM_UNKNOWN)
        self.assertEqual(self.sunshine.saved, [])

    def test_disable_during_a_stream_is_refused_and_keeps_the_feature_on(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.ps.stream(True)
        response = self.client.post("/api/stream/display/fill", json={"enabled": False}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertTrue(self.store.get("display")["fill"]["enabled"])
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)

    def test_sunshine_that_never_comes_back_is_reported_not_hidden(self):
        original_restart = self.sunshine.restart

        def restart_and_vanish():
            original_restart()
            self.sunshine.unreachable = True
        self.sunshine.restart = restart_and_vanish
        result = self.service.set_fill(True)
        self.assertTrue(result["restarted"])
        self.assertFalse(result["sunshineReady"])


class StreamDetectionTests(unittest.TestCase):
    def connection(self, pid, kind, port, status="NONE"):
        return SimpleNamespace(pid=pid, type=kind, laddr=SimpleNamespace(ip="0.0.0.0", port=port), status=status)

    def test_udp_stream_ports_of_sunshine_mean_a_stream(self):
        ps = FakePs()
        for port in (47998, 47999, 48000):
            ps.connections = [self.connection(ps.sunshine_pid, socket.SOCK_DGRAM, port)]
            self.assertTrue(sd.stream_activity(47989, ps), port)

    def test_rtsp_setup_connection_means_a_stream_is_starting(self):
        ps = FakePs()
        ps.connections = [self.connection(ps.sunshine_pid, socket.SOCK_STREAM, 48010, "ESTABLISHED")]
        self.assertTrue(sd.stream_activity(47989, ps))

    def test_listening_sockets_web_ui_and_other_programs_do_not_count(self):
        ps = FakePs()
        ps.connections = [self.connection(ps.sunshine_pid, socket.SOCK_STREAM, 48010, "LISTEN"),
                          self.connection(ps.sunshine_pid, socket.SOCK_STREAM, 47990, "ESTABLISHED"),
                          self.connection(ps.sunshine_pid, socket.SOCK_STREAM, 47984, "ESTABLISHED"),
                          self.connection(7000, socket.SOCK_DGRAM, 47998),
                          SimpleNamespace(pid=ps.sunshine_pid, type=socket.SOCK_DGRAM, laddr=(), status="NONE")]
        self.assertFalse(sd.stream_activity(47989, ps))

    def test_custom_base_port_moves_the_stream_ports(self):
        ps = FakePs()
        ps.connections = [self.connection(ps.sunshine_pid, socket.SOCK_DGRAM, 47998)]
        self.assertFalse(sd.stream_activity(50000, ps))
        ps.connections = [self.connection(ps.sunshine_pid, socket.SOCK_DGRAM, 50009)]
        self.assertTrue(sd.stream_activity(50000, ps))

    def test_no_sunshine_means_no_stream_and_errors_mean_unknown(self):
        ps = FakePs()
        ps.sunshine_running = False
        ps.fail_connections = True
        with self.assertLogs("orbit.streamdisplay", level="WARNING"):
            self.assertFalse(sd.stream_activity(47989, ps))
            # Something answers on Sunshine's port, but no process is known: cannot tell.
            self.assertIsNone(sd.stream_activity(47989, ps, lambda: (0, "SUNSHINE_SERVER_FREE")))
        ps.sunshine_running = True
        broken = MagicMock()
        broken.process_iter.side_effect = OSError("no access")
        with self.assertLogs("orbit.streamdisplay", level="WARNING"):
            self.assertIsNone(sd.stream_activity(47989, ps))
            self.assertIsNone(sd.stream_activity(47989, broken))


class VddXmlTests(unittest.TestCase):
    def test_adds_the_mode_keeps_everything_else_and_stays_valid(self):
        data = VDD_XML.encode("utf-8")
        new, after = sd.plan_vdd_modes(data, 2556, 1179, 120)
        text = new.decode("utf-8")
        ET.fromstring(text.split("?>", 1)[1].strip().split("\n<!-- trailing")[0].replace(
            "<!-- Virtual Display Driver (HDR) - configuration file -->", ""))
        self.assertTrue(text.startswith("<?xml version='1.0' encoding='utf-8'?>\n<!-- Virtual Display Driver (HDR)"))
        self.assertTrue(text.endswith("</vdd_settings>\n<!-- trailing note kept by Orbit -->\n"))
        for kept in ("<edid_profile_path>EDID/monitor_profile.xml</edid_profile_path>", "<SendLogsThroughPipe>true",
                     "<!-- WARNING: Debug logging creates large files -->", "<friendlyname>default</friendlyname>",
                     "</resolutions> inside a comment must not confuse anything", "<count>1</count>"):
            self.assertIn(kept, text)
        parsed = sd.parse_vdd_settings(new)
        self.assertEqual(parsed.sizes(), [(1920, 1080), (3840, 2160), (2560, 1440), (2556, 1179)])
        self.assertEqual(parsed.global_rates, [60, 90, 144, 120])
        self.assertTrue(parsed.has_mode(2556, 1179, 120))
        self.assertIn("2556x1179@120", after.mode_strings())
        self.assertIn("2560x1440@60", after.mode_strings())
        self.assertIn("        <resolution>\n            <width>2556</width>\n            <height>1179</height>\n"
                      "            <refresh_rate>120</refresh_rate>\n        </resolution>\n    </resolutions>", text)
        self.assertIn("        <g_refresh_rate>144</g_refresh_rate>\n        <g_refresh_rate>120</g_refresh_rate>\n    </global>", text)

    def test_is_idempotent(self):
        new, _ = sd.plan_vdd_modes(VDD_XML.encode("utf-8"), 2556, 1179, 120)
        again, settings = sd.plan_vdd_modes(new, 2556, 1179, 120)
        self.assertIsNone(again)
        self.assertTrue(settings.has_mode(2556, 1179, 120))
        # A size that exists with another rate only needs the global rate.
        third, _ = sd.plan_vdd_modes(new, 2556, 1179, 60)
        self.assertIsNone(third)

    def test_creates_missing_sections_in_pretty_and_compact_files(self):
        pretty = "<?xml version='1.0' encoding='utf-8'?>\n<vdd_settings>\n    <monitors>\n        <count>1</count>\n    </monitors>\n</vdd_settings>\n"
        new, settings = sd.plan_vdd_modes(pretty.encode(), 2732, 2048, 60)
        self.assertEqual(settings.sizes(), [(1920, 1080), (2560, 1440), (3840, 2160), (2732, 2048)])
        self.assertEqual(settings.global_rates, [60, 120])
        self.assertIn("\n    <global>\n        <g_refresh_rate>60</g_refresh_rate>", new.decode())
        compact = b"<vdd_settings><monitors><count>1</count></monitors><resolutions/></vdd_settings>"
        new, settings = sd.plan_vdd_modes(compact, 2732, 2048, 120)
        self.assertNotIn(b"\n", new)
        self.assertTrue(settings.has_mode(2732, 2048, 120))
        ET.fromstring(new)

    def test_keeps_a_byte_order_mark_and_reads_utf16(self):
        data = b"\xef\xbb\xbf" + VDD_XML.encode("utf-8")
        new, _ = sd.plan_vdd_modes(data, 2556, 1179, 120)
        self.assertTrue(new.startswith(b"\xef\xbb\xbf<?xml"))
        utf16 = b"\xff\xfe" + VDD_XML.replace("encoding='utf-8'", "encoding='utf-16'").encode("utf-16-le")
        new, _ = sd.plan_vdd_modes(utf16, 2556, 1179, 120)
        self.assertTrue(new.startswith(b"\xff\xfe"))
        self.assertTrue(sd.parse_vdd_settings(new).has_mode(2556, 1179, 120))

    def test_refuses_files_that_are_not_driver_settings(self):
        for data in (b"<settings><resolutions/></settings>", b"<vdd_settings><resolutions>", b"not xml",
                     b"<!DOCTYPE x [<!ENTITY a 'b'>]><vdd_settings/>"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                sd.plan_vdd_modes(data, 2556, 1179, 120)

    def test_tolerates_unreadable_numbers_and_never_removes_entries(self):
        odd = (b"<vdd_settings><global><g_refresh_rate>abc</g_refresh_rate></global><resolutions>"
               b"<resolution><width>x</width><height>1080</height><refresh_rate>60</refresh_rate></resolution>"
               b"</resolutions></vdd_settings>")
        new, settings = sd.plan_vdd_modes(odd, 1920, 1080, 60)
        self.assertIn(b"<g_refresh_rate>abc</g_refresh_rate>", new)
        self.assertIn(b"<width>x</width>", new)
        self.assertTrue(settings.has_mode(1920, 1080, 60))

    def test_refuses_to_grow_without_limit(self):
        many = "".join(f"<resolution><width>{1000 + i}</width><height>800</height><refresh_rate>60</refresh_rate></resolution>"
                       for i in range(sd.MAX_RESOLUTIONS))
        data = f"<vdd_settings><global><g_refresh_rate>60</g_refresh_rate><g_refresh_rate>120</g_refresh_rate></global><resolutions>{many}</resolutions></vdd_settings>"
        with self.assertRaises(sd.DisplaySetupError) as raised:
            sd.plan_vdd_modes(data.encode(), 2556, 1179, 120)
        self.assertEqual(raised.exception.status, 409)


class LogParsingTests(unittest.TestCase):
    def test_sunshine_2025_list_with_an_inactive_virtual_display(self):
        devices = sd.parse_display_devices(LOG_2025_INACTIVE)
        self.assertEqual([device["device_id"] for device in devices], [VDD_ID, MONITOR_ID])
        self.assertEqual(sd.pick_vdd_device(devices)["device_id"], VDD_ID)

    def test_crlf_log_with_edid_finds_the_driver_by_its_edid_next_to_parsec(self):
        devices = sd.parse_display_devices(LOG_2026_EDID_CRLF)
        self.assertEqual(len(devices), 2)
        self.assertEqual(sd.pick_vdd_device(devices)["device_id"], VDD_ID)

    def test_newest_list_wins(self):
        devices = sd.parse_display_devices(LOG_NEWER_LIST_WINS)
        self.assertEqual(sd.pick_vdd_device(devices)["device_id"], VDD_ID)

    def test_list_without_the_driver(self):
        devices = sd.parse_display_devices(LOG_NO_VDD)
        self.assertEqual(len(devices), 1)
        self.assertIsNone(sd.pick_vdd_device(devices))

    def test_old_sunshine_without_a_list(self):
        self.assertIsNone(sd.parse_display_devices(LOG_OLD_SUNSHINE))
        self.assertIsNone(sd.parse_display_devices(""))
        self.assertIsNone(sd.parse_display_devices(None))

    def test_truncated_newest_list_falls_back_to_the_previous_one(self):
        devices = sd.parse_display_devices(LOG_TRUNCATED)
        self.assertEqual(sd.pick_vdd_device(devices)["device_id"], VDD_ID)

    def test_prefixed_lines(self):
        devices = sd.parse_display_devices(LOG_PREFIXED_LINES)
        self.assertEqual(sd.pick_vdd_device(devices)["device_id"], VDD_ID)

    def test_device_id_reason_is_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            service, sunshine, *_ = make_service(folder)
            sunshine.log_text = LOG_NO_VDD
            self.assertEqual(service.vdd_device_id(refresh=True), (None, sd.VDD_NOT_IN_SUNSHINE))
            sunshine.log_text = LOG_OLD_SUNSHINE
            device_id, reason = service.vdd_device_id(refresh=True)
            self.assertIsNone(device_id)
            self.assertIn("does not list", reason)
            sunshine.login = False
            self.assertEqual(service.vdd_device_id(refresh=True), (None, sd.LOGIN_MISSING))


class PipeTests(unittest.TestCase):
    def test_command_encoding(self):
        self.assertEqual(sd.encode_pipe_command("RELOAD_DRIVER"), "RELOAD_DRIVER".encode("utf-16-le"))
        self.assertEqual(sd.encode_pipe_command("PING"), b"P\x00I\x00N\x00G\x00")
        for bad in ("", "x" * 128, "RELOAD\x00", "SETGPU \"Ünïcode\"", None):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                sd.encode_pipe_command(bad)

    def fake_kernel32(self, handle=0x1234):
        kernel32 = MagicMock()
        kernel32.CreateFileW.return_value = handle
        kernel32.SetNamedPipeHandleState.return_value = 1

        def write(handle_value, buffer, size, written, overlapped):
            self.written = bytes(buffer)[:size]
            written._obj.value = size
            return 1
        kernel32.WriteFile.side_effect = write
        kernel32.PeekNamedPipe.return_value = 0  # the driver handled the command and closed its end
        kernel32.CloseHandle.return_value = 1
        return kernel32

    def test_sends_one_utf16_message_and_closes_the_handle(self):
        kernel32 = self.fake_kernel32()
        result = sd.send_pipe_command("RELOAD_DRIVER", library=kernel32)
        self.assertTrue(result["handled"])
        name, access, share, security, disposition, flags, template = kernel32.CreateFileW.call_args.args
        self.assertEqual(name, "\\\\.\\pipe\\MTTVirtualDisplayPipe")
        self.assertEqual(access, sd.GENERIC_READ | sd.GENERIC_WRITE)
        self.assertEqual(disposition, sd.OPEN_EXISTING)
        mode = kernel32.SetNamedPipeHandleState.call_args.args[1]._obj
        self.assertEqual(mode.value, sd.PIPE_READMODE_MESSAGE)
        self.assertEqual(self.written, "RELOAD_DRIVER".encode("utf-16-le"))
        kernel32.CloseHandle.assert_called_once_with(0x1234)
        for function in ("CreateFileW", "WriteFile", "PeekNamedPipe", "ReadFile", "CloseHandle", "SetNamedPipeHandleState"):
            self.assertIsNotNone(getattr(kernel32, function).argtypes, function)
            self.assertIsNotNone(getattr(kernel32, function).restype, function)
        self.assertIs(kernel32.CreateFileW.restype, ctypes.wintypes.HANDLE)

    def test_missing_pipe_is_pipe_unavailable(self):
        kernel32 = self.fake_kernel32(handle=sd.INVALID_HANDLE_VALUE)
        with patch.object(sd, "_last_error", return_value=sd.ERROR_FILE_NOT_FOUND):
            with self.assertRaises(sd.PipeUnavailable):
                sd.send_pipe_command("RELOAD_DRIVER", library=kernel32)
        kernel32.WriteFile.assert_not_called()

    def test_short_write_is_an_error_and_still_closes(self):
        kernel32 = self.fake_kernel32()
        kernel32.WriteFile.side_effect = None
        kernel32.WriteFile.return_value = 0
        with self.assertRaises(OSError):
            sd.send_pipe_command("RELOAD_DRIVER", library=kernel32)
        kernel32.CloseHandle.assert_called_once()


class ElevationTests(unittest.TestCase):
    def fake_apis(self, code=0, succeed=True, system_folder="C:\\Windows\\System32"):
        shell32, kernel32 = MagicMock(), MagicMock()
        self.ole32 = MagicMock()
        self.ole32.CoInitializeEx.return_value = 0
        self.infos = []

        def system_directory(buffer, size):
            buffer.value = system_folder
            return len(system_folder)
        kernel32.GetSystemDirectoryW.side_effect = system_directory

        def execute(pointer):
            info = pointer._obj
            self.infos.append({field: getattr(info, field) for field, _ in sd.SHELLEXECUTEINFOW._fields_})
            if succeed:
                info.hProcess = 0x5678
            return 1 if succeed else 0
        shell32.ShellExecuteExW.side_effect = execute
        kernel32.WaitForSingleObject.return_value = sd.WAIT_OBJECT_0

        def exit_code(handle, pointer):
            pointer._obj.value = code
            return 1
        kernel32.GetExitCodeProcess.side_effect = exit_code
        return shell32, kernel32

    def test_runs_powershell_once_with_runas_and_an_encoded_script(self):
        shell32, kernel32 = self.fake_apis(code=0)
        script = sd.build_helper_script("C:\\Users\\Dimi's PC\\staged.xml", "C:\\VirtualDisplayDriver\\vdd_settings.xml",
                                        "ab" * 32, ["ROOT\\DISPLAY\\0000"])
        # The user's own environment must not choose which PowerShell the administrator approves.
        with patch.dict(sd.os.environ, {"SystemRoot": "C:\\Users\\Gamer\\evil", "windir": "C:\\Users\\Gamer\\evil"}):
            self.assertEqual(sd.run_elevated_powershell(script, shell32=shell32, kernel32=kernel32, ole32=self.ole32), 0)
        self.ole32.CoInitializeEx.assert_called_once_with(None, sd.COINIT_APARTMENTTHREADED | sd.COINIT_DISABLE_OLE1DDE)
        self.ole32.CoUninitialize.assert_called_once_with()
        info = self.infos[0]
        self.assertEqual(info["lpVerb"], "runas")
        self.assertEqual(info["lpFile"], "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        self.assertEqual(info["nShow"], sd.SW_HIDE)
        self.assertEqual(info["fMask"], sd.SEE_MASK_NOCLOSEPROCESS | sd.SEE_MASK_NOASYNC)
        self.assertEqual(info["cbSize"], ctypes.sizeof(sd.SHELLEXECUTEINFOW))
        encoded = info["lpParameters"].rsplit(" ", 1)[1]
        self.assertIn("-EncodedCommand", info["lpParameters"])
        self.assertEqual(base64.b64decode(encoded).decode("utf-16-le"), script)
        kernel32.WaitForSingleObject.assert_called_once()
        kernel32.CloseHandle.assert_called_once_with(0x5678)
        self.assertIsNotNone(shell32.ShellExecuteExW.argtypes)
        self.assertIs(shell32.ShellExecuteExW.restype, ctypes.wintypes.BOOL)
        self.assertIs(kernel32.WaitForSingleObject.restype, ctypes.wintypes.DWORD)
        self.assertIs(kernel32.GetSystemDirectoryW.restype, ctypes.wintypes.UINT)
        self.assertEqual(kernel32.GetSystemDirectoryW.argtypes, [ctypes.wintypes.LPWSTR, ctypes.wintypes.UINT])
        self.assertLess(len(info["lpParameters"]), 30000)  # CreateProcess takes at most 32767 characters

    def test_declined_prompt_and_timeout(self):
        shell32, kernel32 = self.fake_apis(succeed=False)
        with patch.object(sd, "_last_error", return_value=sd.ERROR_CANCELLED):
            with self.assertRaises(sd.ElevationDeclined):
                sd.run_elevated_powershell("exit 0", shell32=shell32, kernel32=kernel32, ole32=self.ole32)
        self.assertEqual(self.ole32.CoUninitialize.call_count, 1)
        with patch.object(sd, "_last_error", return_value=5):
            with self.assertRaises(sd.ElevationFailed):
                sd.run_elevated_powershell("exit 0", shell32=shell32, kernel32=kernel32, ole32=self.ole32)
        kernel32.WaitForSingleObject.assert_not_called()
        shell32, kernel32 = self.fake_apis()
        kernel32.WaitForSingleObject.return_value = sd.WAIT_TIMEOUT
        with self.assertRaises(sd.ElevationFailed):
            sd.run_elevated_powershell("exit 0", shell32=shell32, kernel32=kernel32, ole32=self.ole32)
        kernel32.CloseHandle.assert_called_once_with(0x5678)

    def test_helper_script_carries_paths_only_base64_checks_the_hash_and_always_enables_the_driver(self):
        script = sd.build_helper_script("C:\\Users\\O'Brien\\staged.xml", "D:\\VDD\\vdd_settings.xml", "ab" * 32,
                                        ["ROOT\\DISPLAY\\0000", "ROOT\\MTTVDD\\0001"], not_after=1_800_000_000,
                                        base_port=50000, sunshine_pids={4100, 77})
        values = helper_values(script)
        self.assertEqual(values["source"], "C:\\Users\\O'Brien\\staged.xml")
        self.assertEqual(values["target"], "D:\\VDD\\vdd_settings.xml")
        self.assertEqual(values["expected"], "AB" * 32)
        self.assertEqual(values["backup"], sd.VDD_BACKUP_NAME)
        self.assertEqual(values["devices"], ["ROOT\\DISPLAY\\0000", "ROOT\\MTTVDD\\0001"])
        self.assertEqual((values["basePort"], values["pids"]), (50000, [77, 4100]))
        self.assertEqual(values["deadline"], 1_800_000_000 * 10_000_000 + 621355968000000000)
        self.assertNotIn("O'Brien", script)
        self.assertNotIn("VDD\\vdd_settings", script)
        self.assertIn("if ($hash -ne $expected) { exit 3 }", script)
        self.assertRegex(script, r"finally \{[^}]*Enable-PnpDevice -InstanceId \$id")
        self.assertIn("$null -ne $original", script)
        restart_only = sd.build_helper_script(None, None, None, ["ROOT\\DISPLAY\\0000"])
        self.assertEqual(helper_values(restart_only)["source"], "")

    def test_helper_refuses_to_run_late_and_checks_for_a_stream_before_touching_anything(self):
        script = sd.build_helper_script("C:\\s.xml", "C:\\t.xml", "ab" * 32, ["ROOT\\DISPLAY\\0000"])
        lines = script.split("\r\n")
        deadline = next(index for index, line in enumerate(lines) if "UtcNow.Ticks -gt" in line)
        self.assertEqual(deadline, 2)  # right after $ErrorActionPreference, before anything else runs
        values = helper_values(script)
        import time as clock
        self.assertAlmostEqual((values["deadline"] - sd.dotnet_ticks(clock.time())) / 10_000_000,
                               sd.PROMPT_WAIT_SECONDS, delta=5)
        check = next(index for index, line in enumerate(lines) if line == "  $busy = @(Test-OrbitBusy)[-1]")
        self.assertEqual(lines[check - 1], "if ($devices.Count -gt 0) {")
        self.assertEqual(lines[check + 1], "  if ($busy -eq 1) { exit 7 }")
        self.assertEqual(lines[check + 2], "  if ($busy -ne 0) { exit 8 }")
        first_write = next(index for index, line in enumerate(lines) if "ReadAllBytes($source)" in line)
        first_restart = next(index for index, line in enumerate(lines) if "Disable-PnpDevice" in line)
        self.assertLess(check, first_write)
        self.assertLess(check, first_restart)
        for needed in ("Get-NetUDPEndpoint -ErrorAction Stop", "Get-NetTCPConnection -ErrorAction Stop",
                       "'/serverinfo'", "$request.Proxy = $null", "currentgame", "'*_SERVER_BUSY'", "'sunshine'"):
            self.assertIn(needed, script)
        self.assertTrue(script.isascii())

    def test_powershell_quoting_doubles_every_quote_character(self):
        self.assertEqual(sd._ps_quote("C:\\Users\\O\u2019Brien\\x"), "'C:\\Users\\O\u2019\u2019Brien\\x'")
        self.assertEqual(sd._ps_quote("a'b\u2018c\u201ad\u201be"), "'a''b\u2018\u2018c\u201a\u201ad\u201b\u201be'")
        path = "C:\\Users\\O\u2019Brien \u2018x\u2019\\AppData\\Local\\Orbit\\display\\vdd.xml"
        script = sd.build_helper_script(path, "C:\\VirtualDisplayDriver\\vdd_settings.xml", "ab" * 32, [])
        self.assertTrue(script.isascii())
        self.assertEqual(helper_values(script)["source"], path)
        for character in "\u2018\u2019\u201a\u201b":
            self.assertNotIn(character, script)

    def test_unanswered_prompt_stops_waiting_refuses_a_second_prompt_and_closes_a_late_approval(self):
        import threading
        shell32, kernel32 = self.fake_apis()
        release = threading.Event()
        entered = threading.Event()

        def blocked(pointer):
            entered.set()
            release.wait(10)  # nobody at the PC: ShellExecuteExW blocks until the prompt is answered
            pointer._obj.hProcess = 0x5678
            return 1
        shell32.ShellExecuteExW.side_effect = blocked
        self.addCleanup(release.set)
        with self.assertRaises(sd.ElevationTimedOut):
            sd.run_elevated_powershell("exit 0", prompt_timeout=0.2, shell32=shell32, kernel32=kernel32, ole32=self.ole32)
        self.assertTrue(entered.is_set())
        other_shell32, other_kernel32 = self.fake_apis()
        with self.assertRaises(sd.ElevationBusy):
            sd.run_elevated_powershell("exit 0", prompt_timeout=0.2, shell32=other_shell32, kernel32=other_kernel32,
                                       ole32=self.ole32)
        other_shell32.ShellExecuteExW.assert_not_called()
        kernel32.WaitForSingleObject.assert_not_called()
        pending = sd._PROMPT_THREAD
        release.set()  # approved much later: Orbit only closes the handle (the helper exits 6 by itself)
        pending.join(5)
        self.assertFalse(pending.is_alive())
        self.assertIsNone(sd._PROMPT_THREAD)
        kernel32.CloseHandle.assert_called_once_with(0x5678)
        kernel32.WaitForSingleObject.assert_not_called()
        shell32, kernel32 = self.fake_apis(code=0)  # the next request may ask again
        self.assertEqual(sd.run_elevated_powershell("exit 0", shell32=shell32, kernel32=kernel32, ole32=self.ole32), 0)

    def test_back_to_back_prompts_are_never_busy(self):
        for _ in range(25):  # an answered prompt frees the slot before Orbit even reads the result
            shell32, kernel32 = self.fake_apis(code=0)
            self.assertEqual(sd.run_elevated_powershell("exit 0", shell32=shell32, kernel32=kernel32, ole32=self.ole32), 0)
        self.assertIsNone(sd._PROMPT_THREAD)

    def test_system_folder_comes_from_windows_not_the_environment(self):
        _, kernel32 = self.fake_apis(system_folder="D:\\WINDOWS\\system32")
        self.assertEqual(sd.powershell_path(kernel32), "D:\\WINDOWS\\system32\\WindowsPowerShell\\v1.0\\powershell.exe")
        for broken in ("", "System32", "\\\\server\\share"):
            _, kernel32 = self.fake_apis(system_folder=broken)
            with self.subTest(folder=broken), self.assertRaises(sd.ElevationFailed):
                sd.powershell_path(kernel32)
        kernel32 = MagicMock()
        kernel32.GetSystemDirectoryW.return_value = 0
        with self.assertRaises(sd.ElevationFailed):
            sd.powershell_path(kernel32)

    @unittest.skipUnless(sys.platform == "win32", "Windows structure layout")
    def test_structure_sizes_match_the_windows_sdk(self):
        pointer = ctypes.sizeof(ctypes.c_void_p)
        self.assertEqual(ctypes.sizeof(sd.SHELLEXECUTEINFOW), 112 if pointer == 8 else 60)
        self.assertEqual(ctypes.sizeof(sd.DEVMODEW), 220)
        self.assertEqual(ctypes.sizeof(sd.DISPLAY_DEVICEW), 840)
        self.assertEqual(sd.DEVMODEW.dmPositionX.offset, 76)
        self.assertEqual(sd.DEVMODEW.dmPelsWidth.offset, 172)
        self.assertEqual(sd.DEVMODEW.dmDisplayFrequency.offset, 184)

    def test_structure_field_order(self):
        wchar, word, dword = ctypes.sizeof(ctypes.c_wchar), ctypes.sizeof(ctypes.wintypes.WORD), ctypes.sizeof(ctypes.wintypes.DWORD)
        self.assertEqual(sd.DEVMODEW.dmFields.offset, 32 * wchar + 4 * word)
        self.assertEqual(sd.DEVMODEW.dmPositionX.offset, 32 * wchar + 4 * word + dword)
        self.assertEqual(sd.DISPLAY_DEVICEW.StateFlags.offset, dword + 160 * wchar)


class ModesTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)
        self.original = self.platform.settings_file.read_bytes()

    def post(self, width=2556, height=1179, refresh=120):
        return self.client.post("/api/stream/display/modes", json={"width": width, "height": height, "refreshRate": refresh},
                                headers=self.headers)

    def test_user_writable_file_and_pipe_reload_that_works(self):
        self.platform.offered_after_pipe = True
        self.platform.displays[1].attached = True
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual((body["changed"], body["reload"], body["elevated"]), (True, "pipe", False))
        self.assertEqual(self.platform.pipe_commands, ["RELOAD_DRIVER"])
        self.assertEqual(self.platform.elevated_scripts, [])
        self.assertIn("2556x1179@120", body["display"]["virtualDisplay"]["modes"])

    def test_pipe_that_cannot_be_confirmed_falls_back_to_one_driver_restart_prompt(self):
        self.platform.pipe_error = sd.PipeUnavailable("no pipe")
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((response.json()["reload"], response.json()["elevated"]), ("driverRestart", True))
        self.assertEqual(len(self.platform.elevated_scripts), 1)
        values = helper_values(self.platform.elevated_scripts[0])
        self.assertEqual(values["source"], "")
        self.assertEqual(values["devices"], ["ROOT\\DISPLAY\\0000"])
        self.assertTrue(sd.parse_vdd_settings(self.platform.settings_file.read_bytes()).has_mode(2556, 1179, 120))

    def test_file_the_user_cannot_write_is_saved_by_the_elevated_helper(self):
        self.platform.writable = False
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual((body["changed"], body["reload"], body["elevated"]), (True, "driverRestart", True))
        self.assertEqual(len(self.platform.elevated_scripts), 1)
        self.assertEqual(self.platform.pipe_commands, [])
        self.assertTrue(sd.parse_vdd_settings(self.platform.settings_file.read_bytes()).has_mode(2556, 1179, 120))
        self.assertEqual(list((Path(self.folder.name) / "staging").iterdir()), [])  # staged copy removed

    def test_declined_prompt_leaves_the_file_unchanged(self):
        self.platform.writable = False
        self.platform.elevation = "decline"
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.UAC_DECLINED)
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)

    def test_declined_driver_restart_puts_the_old_file_back_when_the_pipe_never_reached_the_driver(self):
        self.platform.pipe_error = sd.PipeUnavailable("no pipe")
        self.platform.elevation = "decline"
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.UAC_DECLINED)
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)

    def test_declined_driver_restart_after_reload_keeps_the_new_file_and_says_so(self):
        self.platform.elevation = "decline"  # RELOAD_DRIVER was sent: the driver may already use the new list
        response = self.post()
        self.assertEqual(response.status_code, 409)
        detail = response.json()["detail"]
        self.assertIn("declined", detail)
        self.assertIn(sd.KEPT_NEW_SIZE, detail)
        self.assertNotIn("unchanged", detail)
        self.assertTrue(sd.parse_vdd_settings(self.platform.settings_file.read_bytes()).has_mode(2556, 1179, 120))

    def test_reload_that_broke_the_driver_is_restarted_and_reported(self):
        self.platform.pipe_breaks_driver = True
        self.platform.offered_after_pipe = True  # a stale mode list must not count while the device is failed
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((response.json()["reload"], response.json()["elevated"]), ("driverRestart", True))
        self.assertEqual(self.platform.driver_restarts, 1)
        self.assertEqual(response.json()["display"]["virtualDisplay"]["deviceStatus"], "running")
        self.platform.status = "running"
        self.platform.elevation = "decline"
        response = self.post(2388, 1668, 120)
        self.assertEqual(response.status_code, 409)
        self.assertIn(sd.DRIVER_STUCK, response.json()["detail"])
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertEqual(status["virtualDisplay"]["deviceStatus"], "problem")

    def test_pipe_reload_counts_when_the_virtual_display_is_off_the_desktop(self):
        self.platform.offered_after_pipe = True
        self.assertFalse(self.platform.displays[1].attached)  # Sunshine's ensure_* options keep it off between streams
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((response.json()["reload"], response.json()["elevated"]), ("pipe", False))
        self.assertEqual(self.platform.elevated_scripts, [])

    def test_unanswered_prompt_is_409_and_frees_the_feature(self):
        self.platform.writable = False
        self.platform.elevation = "timeout"
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.PROMPT_TIMEOUT)
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)
        self.platform.elevation = "busy"
        response = self.post()
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.PROMPT_STILL_OPEN))
        self.platform.elevation = "approve"
        self.assertEqual(self.post().status_code, 200)  # the lock was released: nothing stays BUSY

    def test_prompt_approved_too_late_changes_nothing(self):
        self.platform.writable = False
        self.platform.approve_delay = sd.PROMPT_WAIT_SECONDS + 5
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.PROMPT_TIMEOUT)
        self.assertEqual(self.platform.helper_exit_codes, [6])
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)
        self.assertEqual(self.platform.driver_restarts, 0)

    def test_helper_that_sees_a_stream_changes_nothing(self):
        self.platform.writable = False
        self.platform.helper_busy = 1  # a stream started while the prompt was open
        response = self.post()
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.HELPER_SAW_STREAM))
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)
        self.platform.helper_busy = 2
        response = self.post()
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_UNKNOWN))
        self.assertEqual(self.platform.driver_restarts, 0)
        script = self.platform.elevated_scripts[-1]
        self.assertEqual(helper_values(script)["basePort"], 47989)
        self.assertEqual(helper_values(script)["pids"], [self.ps.sunshine_pid])

    def test_staging_failure_is_503_in_plain_words(self):
        self.platform.writable = False
        with patch.object(self.service, "_staging_path", side_effect=PermissionError("denied")), \
                self.assertLogs("orbit.streamdisplay", level="ERROR"):
            response = self.post()
        self.assertEqual((response.status_code, response.json()["detail"]), (503, sd.STAGING_FAILED))
        self.assertEqual(self.platform.elevated_scripts, [])

    def test_app_running_in_sunshine_blocks_the_driver_restart(self):
        self.sunshine.current_game = 881448767
        response = self.post()
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.APP_RUNNING))
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)
        self.assertEqual(self.platform.pipe_commands, [])

    def test_helper_failure_is_503_in_plain_words(self):
        self.platform.writable = False
        self.platform.elevation = "code:5"
        response = self.post()
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], sd.HELPER_FAILURES[5])

    def test_disabled_driver_is_never_restarted(self):
        self.platform.status = "disabled"
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["reload"], "nextStart")
        self.assertEqual(self.platform.pipe_commands, [])
        self.assertEqual(self.platform.elevated_scripts, [])

    def test_known_mode_needs_nothing_even_during_a_stream(self):
        self.ps.stream(True)
        response = self.post(1920, 1080, 60)
        self.assertEqual(response.status_code, 409)  # 2560x1440 and 120 Hz are still missing
        self.platform.settings_file.write_bytes(sd.plan_vdd_modes(self.original, 1920, 1080, 60)[0])
        response = self.post(1920, 1080, 60)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((response.json()["changed"], response.json()["reload"]), (False, "notNeeded"))

    def test_change_during_a_stream_is_refused_and_nothing_is_written(self):
        self.ps.stream(True)
        self.assertEqual(self.post().status_code, 409)
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)

    def test_without_the_driver(self):
        self.platform.instances = []
        self.platform.settings_file.unlink()
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.VDD_MISSING)

    def test_boot_time_instance_never_changes_the_driver(self):
        self.service._desktop_available = lambda: False
        response = self.post()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.SIGN_IN_FIRST)
        self.assertEqual(self.platform.settings_file.read_bytes(), self.original)
        self.assertEqual((self.platform.pipe_commands, self.platform.elevated_scripts), ([], []))
        self.platform.displays[1].attached = True
        self.assertEqual(self.service._place("right"), "pending")
        self.assertEqual(self.platform.moves, [])


class SecondScreenTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.platform.offered_after_pipe = True
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def enable(self, position="right"):
        return self.client.post("/api/stream/display/second-screen",
                                json={"enabled": True, "width": 2732, "height": 2048, "refreshRate": 120, "position": position},
                                headers=self.headers)

    def test_enable_sets_sunshine_to_extend_with_the_virtual_display(self):
        self.platform.displays[1].attached = True
        self.platform.displays[1].x, self.platform.displays[1].width, self.platform.displays[1].height = -2732, 2732, 2048
        response = self.enable("right")
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_active")
        self.assertEqual(self.sunshine.conf["dd_resolution_option"], "auto")
        for key, value in ORIGINAL_CONFIG.items():
            if key not in sd.MANAGED_KEYS:
                self.assertEqual(self.sunshine.conf[key], value)
        self.assertTrue(sd.parse_vdd_settings(self.platform.settings_file.read_bytes()).has_mode(2732, 2048, 120))
        self.assertEqual(self.platform.moves, [("\\\\.\\DISPLAY3", 2560, 0)])
        self.assertEqual(body["placement"], "done")
        self.assertIsNone(body["placementHint"])
        self.assertTrue(body["restarted"])
        self.assertIn("2732x2048@120", body["modes"])
        self.assertEqual(body["display"]["secondScreen"]["active"], True)
        self.assertEqual(body["display"]["secondScreen"]["position"], "right")
        self.assertEqual(body["display"]["secondScreen"]["placement"], "done")
        self.assertEqual(self.store.get("display")["savedSunshineConfig"], ORIGINAL_CONFIG)

    def test_virtual_display_not_on_the_desktop_yet_is_pending_with_a_hint(self):
        response = self.enable("left")
        body = response.json()
        self.assertEqual(body["placement"], "pending")
        self.assertIn("left", body["placementHint"])
        self.assertEqual(self.platform.moves, [])

    def test_move_refused_by_windows_explains_the_manual_way(self):
        self.platform.displays[1].attached = True
        self.platform.displays[1].x, self.platform.displays[1].width = 2560, 1920
        self.platform.move_result = False
        body = self.enable("left").json()
        self.assertEqual(body["placement"], "manual")
        self.assertIn("Windows Settings > System > Display", body["placementHint"])

    def test_disable_restores_the_saved_config(self):
        self.enable()
        response = self.client.post("/api/stream/display/second-screen", json={"enabled": False}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)
        self.assertFalse(self.store.get("display")["secondScreen"]["active"])
        self.assertIsNone(self.store.get("display")["savedSunshineConfig"])

    def test_turning_the_second_screen_off_goes_back_to_fill_screen(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True, "onlyDisplay": True}, headers=self.headers)
        fill_config = dict(self.sunshine.conf)
        self.enable()
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_active")
        self.client.post("/api/stream/display/second-screen", json={"enabled": False}, headers=self.headers)
        self.assertEqual(self.sunshine.conf, fill_config)
        self.client.post("/api/stream/display/fill", json={"enabled": False}, headers=self.headers)
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)

    def test_needs_the_driver_and_changes_nothing_without_it(self):
        self.platform.instances = []
        self.platform.settings_file.unlink()
        response = self.enable()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.VDD_MISSING)
        self.assertEqual(self.sunshine.saved, [])
        self.assertEqual(self.sunshine.restarts, 0)

    def test_driver_unknown_to_sunshine_is_409_and_sunshine_keeps_its_settings(self):
        self.sunshine.log_text = LOG_NO_VDD
        response = self.enable()
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.VDD_NOT_IN_SUNSHINE)
        self.assertEqual(self.sunshine.saved, [])
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)

    def test_disable_when_off_changes_nothing(self):
        response = self.client.post("/api/stream/display/second-screen", json={"enabled": False}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(response.json()["changed"])
        self.assertEqual(self.sunshine.saved, [])

    def test_placement_targets_the_far_edge_of_the_desktop(self):
        displays = [sd.Display("\\\\.\\DISPLAY1", "GPU", "", True, True, False, 0, 0, 2560, 1440),
                    sd.Display("\\\\.\\DISPLAY2", "GPU", "", True, False, False, 2560, 200, 1920, 1080),
                    sd.Display("\\\\.\\DISPLAY3", "Virtual Display Driver", "MTT1337", True, False, True, -100, 0, 2732, 2048)]
        vdd, x, y, there = sd.StreamDisplayService.placement_target(displays, "right")
        self.assertEqual((vdd.name, x, y, there), ("\\\\.\\DISPLAY3", 4480, 0, False))
        vdd, x, y, there = sd.StreamDisplayService.placement_target(displays, "left")
        self.assertEqual((x, y, there), (-2732, 0, False))
        displays[2].x = -2732
        self.assertTrue(sd.StreamDisplayService.placement_target(displays, "left")[3])
        displays[2].attached = False
        self.assertIsNone(sd.StreamDisplayService.placement_target(displays, "left"))

    def test_placer_moves_the_display_when_a_stream_activates_it(self):
        self.store.replace("display", {"secondScreen": {"active": True, "position": "right"}})
        self.platform.displays[1].attached = True
        self.platform.displays[1].x, self.platform.displays[1].width = -1920, 1920
        placer = sd._Placer(self.service, "right")
        placer._stop_event = MagicMock()
        placer._stop_event.wait.side_effect = [False, False, True]
        placer.run()
        self.assertEqual(self.platform.moves, [("\\\\.\\DISPLAY3", 2560, 0)])  # moved once, then already there


class WindowsPlatformTests(unittest.TestCase):
    class Registry:
        HKEY_LOCAL_MACHINE = 0x80000002
        KEY_READ = 0x20019
        KEY_WOW64_64KEY = 0x0100
        REG_SZ = 1
        REG_EXPAND_SZ = 2
        REG_MULTI_SZ = 7

        def __init__(self, tree):
            self.tree = tree
            self.opened = []

        class Key:
            def __init__(self, path):
                self.path = path

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def Close(self):
                pass

        def OpenKey(self, key, sub, reserved=0, access=0):
            base = "HKLM" if key == self.HKEY_LOCAL_MACHINE else key.path
            path = base + "\\" + sub
            self.opened.append((path, access))
            if path.lower() not in {name.lower() for name in self.tree}:
                raise FileNotFoundError(path)
            return self.Key(next(name for name in self.tree if name.lower() == path.lower()))

        def QueryValueEx(self, key, name):
            values = self.tree[key.path]
            if name not in values:
                raise FileNotFoundError(name)
            return values[name]

        def EnumKey(self, key, index):
            prefix = key.path + "\\"
            children = sorted({name[len(prefix):].split("\\")[0] for name in self.tree if name.startswith(prefix)})
            if index >= len(children):
                raise OSError(259, "No more data")
            return children[index]

        def ExpandEnvironmentStrings(self, text):
            return text.replace("%SystemDrive%", "C:")

    def test_settings_path_from_the_registry_override_or_the_default(self):
        registry = self.Registry({"HKLM\\" + sd.VDD_REGISTRY_KEY: {"VDDPATH": ("%SystemDrive%\\Tools\\VDD\\", 2)}})
        platform = sd.WindowsDisplayPlatform(registry_provider=lambda: registry)
        self.assertEqual(str(platform.vdd_settings_path()).replace("/", "\\"), "C:\\Tools\\VDD\\vdd_settings.xml")
        self.assertEqual(registry.opened[0][1], registry.KEY_READ | registry.KEY_WOW64_64KEY)
        platform = sd.WindowsDisplayPlatform(registry_provider=lambda: self.Registry({}))
        self.assertEqual(str(platform.vdd_settings_path()).replace("/", "\\"), "C:\\VirtualDisplayDriver\\vdd_settings.xml")
        self.assertEqual(sd.WindowsDisplayPlatform(registry_provider=lambda: None).vdd_instances(), [])

    def test_finds_driver_instances_by_hardware_id(self):
        root = "HKLM\\" + sd.DEVICE_ENUM_ROOT
        registry = self.Registry({root: {}, root + "\\DISPLAY": {},
                                  root + "\\DISPLAY\\0000": {"HardwareID": (["Root\\MttVDD"], 7)},
                                  root + "\\DISPLAY\\0001": {"HardwareID": (["Root\\SudoMaker\\SudoVDA"], 7)},
                                  root + "\\SYSTEM": {}, root + "\\SYSTEM\\0002": {"HardwareID": ("ROOT\\MTTVDD", 1)},
                                  root + "\\LEGACY": {}, root + "\\LEGACY\\0000": {}})
        platform = sd.WindowsDisplayPlatform(registry_provider=lambda: registry)
        self.assertEqual(platform.vdd_instances(), ["ROOT\\DISPLAY\\0000", "ROOT\\SYSTEM\\0002"])

    def test_device_status_from_the_configuration_manager(self):
        cfgmgr = MagicMock()

        def locate(node, instance, flags):
            if instance == "missing":
                return sd.CR_NO_SUCH_DEVNODE
            node._obj.value = 77
            return sd.CR_SUCCESS
        cfgmgr.CM_Locate_DevNodeW.side_effect = locate
        status = {"value": sd.DN_STARTED, "problem": 0}

        def node_status(status_out, problem_out, node, flags):
            status_out._obj.value, problem_out._obj.value = status["value"], status["problem"]
            return sd.CR_SUCCESS
        cfgmgr.CM_Get_DevNode_Status.side_effect = node_status
        platform = sd.WindowsDisplayPlatform(library=lambda name: cfgmgr)
        self.assertEqual(platform.device_status("ROOT\\DISPLAY\\0000"), "running")
        status.update(value=sd.DN_HAS_PROBLEM, problem=sd.CM_PROB_DISABLED)
        self.assertEqual(platform.device_status("ROOT\\DISPLAY\\0000"), "disabled")
        status.update(problem=43)
        self.assertEqual(platform.device_status("ROOT\\DISPLAY\\0000"), "problem")
        self.assertEqual(platform.device_status("missing"), "notPresent")
        self.assertIsNotNone(cfgmgr.CM_Locate_DevNodeW.argtypes)
        broken = sd.WindowsDisplayPlatform(library=MagicMock(side_effect=OSError("This needs Windows.")))
        self.assertEqual(broken.device_status("x"), "unknown")

    def test_lists_displays_and_moves_the_virtual_one(self):
        user32 = MagicMock()
        adapters = [("\\\\.\\DISPLAY1", "NVIDIA GeForce RTX 4080", sd.DISPLAY_DEVICE_ATTACHED_TO_DESKTOP | sd.DISPLAY_DEVICE_PRIMARY_DEVICE,
                     "\\\\?\\DISPLAY#GSM5B7F#4&1", (0, 0, 2560, 1440, 144)),
                    ("\\\\.\\DISPLAY3", "Virtual Display Driver", sd.DISPLAY_DEVICE_ATTACHED_TO_DESKTOP,
                     "\\\\?\\DISPLAY#MTT1337#5&2", (2560, 0, 2732, 2048, 120))]

        def enum_devices(name, index, pointer, flags):
            device = pointer._obj
            if name is None:
                if index >= len(adapters):
                    return 0
                device.DeviceName, device.DeviceString, device.StateFlags = adapters[index][:3]
                return 1
            match = next(adapter for adapter in adapters if adapter[0] == name)
            self.assertEqual(flags, sd.EDD_GET_DEVICE_INTERFACE_NAME)
            device.DeviceID = match[3]
            return 1
        user32.EnumDisplayDevicesW.side_effect = enum_devices

        def enum_settings(name, mode_number, pointer, flags):
            mode = pointer._obj
            match = next(adapter for adapter in adapters if adapter[0] == name)
            if mode_number == sd.ENUM_CURRENT_SETTINGS:
                mode.dmPositionX, mode.dmPositionY, mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency = match[4]
                return 1
            modes = [(1920, 1080, 60), (2732, 2048, 120)]
            if mode_number >= len(modes):
                return 0
            mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency = modes[mode_number]
            return 1
        user32.EnumDisplaySettingsExW.side_effect = enum_settings
        user32.ChangeDisplaySettingsExW.return_value = sd.DISP_CHANGE_SUCCESSFUL
        platform = sd.WindowsDisplayPlatform(library=lambda name: user32)
        displays = platform.list_displays()
        self.assertEqual([(d.name, d.vdd, d.primary, d.x, d.width) for d in displays],
                         [("\\\\.\\DISPLAY1", False, True, 0, 2560), ("\\\\.\\DISPLAY3", True, False, 2560, 2732)])
        self.assertTrue(platform.display_offers_mode("\\\\.\\DISPLAY3", 2732, 2048, 120))
        self.assertFalse(platform.display_offers_mode("\\\\.\\DISPLAY3", 2556, 1179, 120))
        self.assertTrue(platform.move_display("\\\\.\\DISPLAY3", -2732, 0))
        first, second = user32.ChangeDisplaySettingsExW.call_args_list
        name, mode, window, flags, extra = first.args
        self.assertEqual(name, "\\\\.\\DISPLAY3")
        self.assertEqual((mode._obj.dmFields, mode._obj.dmPositionX, mode._obj.dmPositionY), (sd.DM_POSITION, -2732, 0))
        self.assertEqual(flags, sd.CDS_UPDATEREGISTRY | sd.CDS_NORESET)
        self.assertEqual(second.args, (None, None, None, 0, None))
        self.assertIsNotNone(user32.ChangeDisplaySettingsExW.argtypes)
        user32.ChangeDisplaySettingsExW.return_value = -1
        with self.assertLogs("orbit.streamdisplay", level="WARNING"):
            self.assertFalse(platform.move_display("\\\\.\\DISPLAY3", 0, 0))

    def test_user_write_needs_elevation_when_windows_refuses(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / sd.VDD_SETTINGS_NAME
            target.write_bytes(b"<vdd_settings/>")
            sd.WindowsDisplayPlatform.write_file_as_user(target, b"<vdd_settings><x/></vdd_settings>")
            self.assertEqual(target.read_bytes(), b"<vdd_settings><x/></vdd_settings>")
            self.assertEqual((Path(folder) / sd.VDD_BACKUP_NAME).read_bytes(), b"<vdd_settings/>")
            self.assertFalse((Path(folder) / (sd.VDD_SETTINGS_NAME + ".orbit-tmp")).exists())
            with patch.object(sd.os, "replace", side_effect=PermissionError("Access is denied")), \
                 patch.object(sd.time, "sleep"):
                with self.assertRaises(sd.NeedsElevation):
                    sd.WindowsDisplayPlatform.write_file_as_user(target, b"<vdd_settings/>")
            self.assertEqual(target.read_bytes(), b"<vdd_settings><x/></vdd_settings>")
            self.assertFalse((Path(folder) / (sd.VDD_SETTINGS_NAME + ".orbit-tmp")).exists())

    def test_library_is_private_and_needs_windows(self):
        with patch.object(sd, "_LIBRARIES", {}), patch.object(sd.ctypes, "WinDLL", None, create=True):
            with self.assertRaises(OSError):
                sd._library("kernel32")


class SunshineWebAPITests(unittest.TestCase):
    def api(self, credentials=("sunshine", "secret")):
        return sd.SunshineWebAPI(lambda: credentials, lambda: 47989)

    def reply(self, body, status=200):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = body if isinstance(body, bytes) else json.dumps(body).encode()
        return response

    def test_config_drops_meta_and_sends_basic_auth_to_the_web_ui_port(self):
        with patch.object(sd.urllib.request, "urlopen", return_value=self.reply(
                {**ORIGINAL_CONFIG, "status": True, "platform": "windows", "version": "2026.1017.152030"})) as opened:
            config, version = self.api().config()
        self.assertEqual(config, ORIGINAL_CONFIG)
        self.assertEqual(version, "2026.1017.152030")
        request = opened.call_args.args[0]
        self.assertEqual(request.full_url, "https://127.0.0.1:47990/api/config")
        self.assertEqual(request.get_header("Authorization"), "Basic " + base64.b64encode(b"sunshine:secret").decode())
        self.assertIsNone(request.get_header("Origin"))

    def test_save_config_posts_json_and_checks_the_status(self):
        with patch.object(sd.urllib.request, "urlopen", return_value=self.reply({"status": True})) as opened:
            self.api().save_config({"a": "1"})
        request = opened.call_args.args[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(json.loads(request.data), {"a": "1"})
        with patch.object(sd.urllib.request, "urlopen", return_value=self.reply({"status": False, "error": "disk full"})):
            with self.assertRaises(sd.DisplaySetupError) as raised:
                self.api().save_config({"a": "1"})
        self.assertEqual(raised.exception.status, 502)
        self.assertIn("disk full", raised.exception.detail)

    def test_http_errors_become_plain_statuses(self):
        def error(code, body=b"{}"):
            return urllib.error.HTTPError("https://127.0.0.1:47990/api/config", code, "x", {}, io.BytesIO(body))
        for code, status in ((401, 428), (403, 502), (500, 502)):
            with self.subTest(code=code), patch.object(sd.urllib.request, "urlopen", side_effect=error(code, b'{"error":"boom"}')):
                with self.assertRaises(sd.DisplaySetupError) as raised:
                    self.api().config()
                self.assertEqual(raised.exception.status, status)
        with patch.object(sd.urllib.request, "urlopen", side_effect=urllib.error.URLError(ConnectionRefusedError())):
            with self.assertRaises(sd.DisplaySetupError) as raised:
                self.api().config()
        self.assertEqual((raised.exception.status, raised.exception.detail), (502, sd.SUNSHINE_UNREACHABLE))
        with self.assertRaises(sd.DisplaySetupError) as raised:
            sd.SunshineWebAPI(lambda: None, lambda: 47989).config()
        self.assertEqual(raised.exception.status, 428)

    def test_restart_accepts_a_dropped_connection(self):
        for failure in (http.client.RemoteDisconnected("closed"), ConnectionResetError(), TimeoutError(),
                        urllib.error.URLError(ConnectionResetError())):
            with self.subTest(failure=failure), patch.object(sd.urllib.request, "urlopen", side_effect=failure):
                self.api().restart()
        with patch.object(sd.urllib.request, "urlopen", side_effect=urllib.error.URLError(ConnectionRefusedError())):
            with self.assertRaises(sd.DisplaySetupError):
                self.api().restart()

    def test_logs_are_text(self):
        with patch.object(sd.urllib.request, "urlopen", return_value=self.reply(LOG_2025_INACTIVE.encode())) as opened:
            self.assertEqual(self.api().logs(), LOG_2025_INACTIVE)
        self.assertEqual(opened.call_args.args[0].full_url, "https://127.0.0.1:47990/api/logs")


class TrayTests(unittest.TestCase):
    def test_menu_item_and_dialog_thread(self):
        icon = tray.OrbitTrayIcon(status_provider=lambda: {}, on_stop=lambda: None, boot_task=MagicMock(),
                                  startup_manager=MagicMock(is_enabled=MagicMock(return_value=False)))
        item = next(i for i in icon.build_menu_items() if i.get("id") == tray.ID_STREAM_DISPLAY_SETUP)
        self.assertEqual(item["label"], "Set up full-screen streaming…")
        self.assertTrue(item["enabled"])
        with patch.object(icon, "show_stream_display_setup") as shown:
            self.assertEqual(icon.execute_command(tray.ID_STREAM_DISPLAY_SETUP), "stream_display_setup_shown")
        shown.assert_called_once()
        with patch.object(sd, "run_tray_setup_dialog") as dialog:
            icon.show_stream_display_setup().join(5)
        dialog.assert_called_once_with(icon._show_message_box_sync, icon.show_notification)

    def test_dialog_explains_and_copies_the_command_on_yes(self):
        boxes, copied, notes = [], [], []
        driver = sd.VirtualDisplayInfo(driver="vdd")

        def box(text, title, flags):
            boxes.append((text, title, flags))
            return 6
        self.assertTrue(sd.run_tray_setup_dialog(box, lambda *a: notes.append(a), copied.append, virtual=driver))
        text = boxes[0][0]
        self.assertIn(sd.VDD_INSTALL_COMMAND, text)
        self.assertIn("output_name", text)
        self.assertIn("dd_configuration_option", text)
        self.assertIn("installed", text)
        self.assertEqual(copied, ["winget install -e --id VirtualDrivers.Virtual-Display-Driver"])
        self.assertEqual(len(notes), 1)
        boxes.clear()
        self.assertFalse(sd.run_tray_setup_dialog(lambda *a: 7, None, copied.append, virtual=sd.VirtualDisplayInfo()))
        self.assertEqual(len(copied), 1)

    def test_copy_failure_shows_the_command_instead(self):
        boxes = []

        def box(text, title, flags):
            boxes.append(text)
            return 6

        def broken(text):
            raise OSError("clipboard busy")
        with self.assertLogs("orbit.streamdisplay", level="ERROR"):
            self.assertFalse(sd.run_tray_setup_dialog(box, None, broken, virtual=sd.VirtualDisplayInfo()))
        self.assertIn(sd.VDD_INSTALL_COMMAND, boxes[-1])
        self.assertIn("not found", boxes[0])


SERVERINFO_IDLE = b"""<?xml version="1.0" encoding="utf-8"?>
<root status_code="200"><hostname>Gaming-PC</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>0123456789ABCDEF</uniqueid><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC><mac>00:00:00:00:00:00</mac><LocalIP>127.0.0.1</LocalIP><ServerCodecModeSupport>3843</ServerCodecModeSupport><PairStatus>0</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>"""
SERVERINFO_BUSY = SERVERINFO_IDLE.replace(b"<currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state>",
                                          b"<currentgame>881448767</currentgame><state>SUNSHINE_SERVER_BUSY</state>")


class SunshineActivityTests(unittest.TestCase):
    """A client that left without quitting leaves no sockets, but the app keeps running in Sunshine."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def test_app_running_without_a_stream_refuses_with_409_and_no_restart(self):
        self.sunshine.current_game = 881448767
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], sd.APP_RUNNING)
        self.assertEqual((self.sunshine.saved, self.sunshine.restarts), ([], 0))
        self.assertIsNone(self.store.get("display"))
        status = self.client.get("/api/stream/display", headers=self.headers).json()
        self.assertEqual((status["streamActive"], status["appRunning"]), (False, True))

    def test_app_running_blocks_turning_the_feature_off_and_the_second_screen(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.sunshine.current_game = 1
        for path, body in (("/api/stream/display/fill", {"enabled": False}), ("/api/stream/display/revert", None),
                           ("/api/stream/display/second-screen", {"enabled": True, "width": 2732, "height": 2048})):
            with self.subTest(path=path):
                response = self.client.post(path, json=body, headers=self.headers)
                self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.APP_RUNNING))
        self.assertEqual(self.sunshine.restarts, 1)
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)

    def test_unreadable_serverinfo_while_sunshine_runs_is_unknown(self):
        self.sunshine.server_info_error = ConnectionRefusedError("refused")
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_UNKNOWN))
        self.sunshine.server_info_error = ValueError("not XML")
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_UNKNOWN))
        self.assertEqual(self.sunshine.restarts, 0)

    def test_renamed_sunshine_is_found_by_its_listeners(self):
        self.ps.sunshine_name = "sunshine-nightly.exe"
        self.ps.listening = True
        self.ps.stream(True)
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_RUNNING))
        self.ps.stream(False)
        response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.restarts, 1)
        self.assertTrue(self.client.get("/api/stream/display", headers=self.headers).json()["sunshineRunning"])

    def test_sunshine_that_answers_without_a_known_process_is_unknown(self):
        self.ps.sunshine_name = "renamed.exe"  # no listener seen either (e.g. no access to its sockets)
        with self.assertLogs("orbit.streamdisplay", level="WARNING"):
            response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_UNKNOWN))
        self.assertEqual((self.sunshine.saved, self.sunshine.restarts), ([], 0))

    def test_activity_values(self):
        ps = FakePs()
        ps.sunshine_running = False
        refused = MagicMock(side_effect=ConnectionRefusedError())
        self.assertEqual(sd.sunshine_activity(47989, ps, refused), sd.SunshineActivity(frozenset(), False, False))
        ps.sunshine_running = True
        self.assertEqual(sd.sunshine_activity(47989, ps, lambda: (0, "SUNSHINE_SERVER_FREE")).busy, False)
        self.assertTrue(sd.sunshine_activity(47989, ps, lambda: (5, "SUNSHINE_SERVER_BUSY")).app_running)
        self.assertIsNone(sd.sunshine_activity(47989, ps, lambda: (None, None)).busy)
        ps.stream(True)
        activity = sd.sunshine_activity(47989, ps, lambda: (0, "SUNSHINE_SERVER_FREE"))
        self.assertEqual((activity.streaming, activity.app_running, activity.busy), (True, False, True))
        self.assertTrue(sd.stream_activity(47989, ps, lambda: (0, "SUNSHINE_SERVER_FREE")))

    def test_serverinfo_parsing(self):
        self.assertEqual(sd.parse_server_info(SERVERINFO_IDLE), (0, "SUNSHINE_SERVER_FREE"))
        self.assertEqual(sd.parse_server_info(SERVERINFO_BUSY), (881448767, "SUNSHINE_SERVER_BUSY"))
        self.assertFalse(sd.app_running_from(*sd.parse_server_info(SERVERINFO_IDLE)))
        self.assertTrue(sd.app_running_from(*sd.parse_server_info(SERVERINFO_BUSY)))
        self.assertTrue(sd.app_running_from(None, "SUNSHINE_SERVER_BUSY"))
        self.assertTrue(sd.app_running_from(3, None))
        self.assertIsNone(sd.app_running_from(None, None))
        for bad in (b"not xml", b"<!DOCTYPE r [<!ENTITY a 'b'>]><root><currentgame>&a;</currentgame></root>"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                sd.parse_server_info(bad)
        self.assertEqual(sd.parse_server_info(b"<root><currentgame>x</currentgame></root>"), (None, None))

    def test_serverinfo_request_goes_to_the_plain_http_port_without_login(self):
        connection = MagicMock()
        connection.getresponse.return_value = SimpleNamespace(status=200, read=lambda size: SERVERINFO_BUSY)
        with patch.object(sd.http.client, "HTTPConnection", return_value=connection) as opened:
            result = sd.SunshineWebAPI(lambda: None, lambda: 50000).server_info()
        self.assertEqual(result, (881448767, "SUNSHINE_SERVER_BUSY"))
        self.assertEqual(opened.call_args.args, ("127.0.0.1", 50000))
        method, path = connection.request.call_args.args
        self.assertEqual((method, path), ("GET", "/serverinfo"))
        self.assertNotIn("Authorization", connection.request.call_args.kwargs.get("headers", {}))
        connection.close.assert_called_once()
        connection.getresponse.return_value = SimpleNamespace(status=503, read=lambda size: b"")
        with patch.object(sd.http.client, "HTTPConnection", return_value=connection), self.assertRaises(ValueError):
            sd.SunshineWebAPI(lambda: None, lambda: 50000).server_info()


class LogSafetyTests(unittest.TestCase):
    def test_marker_inside_another_message_or_mid_line_is_ignored(self):
        injected = (LOG_NO_VDD + "[2026-03-01 10:06:00.000]: Warning: Could not open asset Currently available display "
                    f"devices: [{{\"device_id\": \"{VDD_ID}\", \"friendly_name\": \"VDD by MTT\"}}]\n")
        devices = sd.parse_display_devices(injected)
        self.assertEqual([device["device_id"] for device in devices], [MONITOR_ID])
        unprefixed = f'Currently available display devices:\n[{{"device_id": "{VDD_ID}", "friendly_name": "VDD by MTT"}}]\n'
        self.assertIsNone(sd.parse_display_devices(unprefixed))

    def test_device_ids_must_be_braced_uuids(self):
        self.assertTrue(sd.valid_device_id(VDD_ID))
        self.assertTrue(sd.valid_device_id(VDD_ID.upper()))
        for bad in (VDD_ID + "\n", VDD_ID + "\nglobal_prep_cmd = [{\"do\":\"cmd\",\"elevated\":true}]", VDD_ID[1:-1],
                    "\\\\.\\DISPLAY1", "", None, 5, "{" + "g" * 8 + VDD_ID[9:]):
            with self.subTest(bad=bad):
                self.assertFalse(sd.valid_device_id(bad))

    def test_unexpected_device_id_is_reported_not_used(self):
        log = LOG_2025_INACTIVE.replace(f'"device_id": "{VDD_ID}"', '"device_id": "' + VDD_ID + '\\\\nencoder = x"')
        with tempfile.TemporaryDirectory() as folder:
            service, sunshine, *_ = make_service(folder)
            sunshine.log_text = log
            with self.assertLogs("orbit.streamdisplay", level="WARNING"):
                self.assertEqual(service.vdd_device_id(refresh=True), (None, sd.DEVICE_ID_INVALID))
                result = service.set_fill(True)
            self.assertEqual(result["warning"], sd.DEVICE_ID_INVALID)
            self.assertNotIn("output_name", sunshine.conf)
            self.assertEqual(sunshine.restarts, 1)  # only for the settings: an odd id is no reason to restart

    def test_log_that_cannot_be_fetched_is_502_and_never_restarts_sunshine(self):
        with tempfile.TemporaryDirectory() as folder:
            service, sunshine, platform, ps, store = make_service(folder)
            platform.offered_after_pipe = True
            client, headers = make_client(service)
            self.addCleanup(client.close)
            sunshine.logs = MagicMock(side_effect=sd.DisplaySetupError(502, sd.SUNSHINE_UNREACHABLE))
            response = client.post("/api/stream/display/second-screen",
                                   json={"enabled": True, "width": 2732, "height": 2048}, headers=headers)
            self.assertEqual((response.status_code, response.json()["detail"]), (502, sd.SUNSHINE_UNREACHABLE))
            response = client.post("/api/stream/display/fill", json={"enabled": True}, headers=headers)
            self.assertEqual(response.status_code, 502)
            self.assertEqual((sunshine.restarts, sunshine.saved), (0, []))

    def test_log_without_a_display_list_does_not_restart_sunshine(self):
        with tempfile.TemporaryDirectory() as folder:
            service, sunshine, *_ = make_service(folder)
            sunshine.log_text = LOG_OLD_SUNSHINE  # e.g. Sunshine's log level is above Info
            result = service.set_fill(True)
            self.assertEqual(result["warning"], sd.NO_DEVICE_LIST)
            self.assertEqual(sunshine.restarts, 1)  # the settings change only


class SecondScreenOffTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.platform.offered_after_pipe = True
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def off(self):
        return self.client.post("/api/stream/display/second-screen", json={"enabled": False}, headers=self.headers)

    def test_off_when_already_off_never_asks_or_changes_sunshine(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        calls = (len(self.sunshine.saved), self.sunshine.restarts)
        self.sunshine.config = MagicMock(side_effect=AssertionError("Sunshine must not be asked"))
        self.sunshine.log_text = LOG_OLD_SUNSHINE
        result = self.service.set_second_screen(False)
        self.assertEqual((result["changed"], result["restarted"]), (False, False))
        self.assertEqual((len(self.sunshine.saved), self.sunshine.restarts), calls)
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.store.get("display")["outputName"], VDD_ID)

    def test_off_with_fill_on_uses_the_saved_id_even_when_the_log_fails(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual(self.client.post("/api/stream/display/second-screen", json={
            "enabled": True, "width": 2732, "height": 2048}, headers=self.headers).status_code, 200)
        self.sunshine.log_text = LOG_OLD_SUNSHINE
        self.sunshine.logs = MagicMock(side_effect=sd.DisplaySetupError(502, sd.SUNSHINE_UNREACHABLE))
        result = self.service.set_second_screen(False)
        self.assertEqual((result["changed"], result["restarted"]), (True, True))
        self.assertIsNone(result["warning"])
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_primary")
        self.assertEqual(self.store.get("display")["outputName"], VDD_ID)
        self.sunshine.logs.assert_not_called()

    def test_off_with_fill_on_keeps_the_current_display_when_no_id_is_known(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.client.post("/api/stream/display/second-screen", json={"enabled": True, "width": 2732, "height": 2048},
                         headers=self.headers)
        state = self.store.get("display")
        state["outputName"] = None  # e.g. settings.json edited by hand
        self.store.replace("display", state)
        self.sunshine.log_text = LOG_OLD_SUNSHINE
        response = self.off()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn("keeps the display it uses now", response.json()["warning"])
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_primary")

    def test_fill_off_with_the_second_screen_on_keeps_its_display(self):
        self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.client.post("/api/stream/display/second-screen", json={"enabled": True, "width": 2732, "height": 2048},
                         headers=self.headers)
        self.sunshine.logs = MagicMock(side_effect=sd.DisplaySetupError(502, sd.SUNSHINE_UNREACHABLE))
        response = self.client.post("/api/stream/display/fill", json={"enabled": False}, headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.sunshine.conf["output_name"], VDD_ID)
        self.assertEqual(self.sunshine.conf["dd_configuration_option"], "ensure_active")


class PlacerLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.service._start_placer = True
        self.addCleanup(self.service.close)
        self.platform.displays[1].attached = True
        self.platform.displays[1].x, self.platform.displays[1].width = -1920, 1920

    def test_placer_ends_once_the_second_screen_is_off(self):
        self.store.replace("display", {"secondScreen": {"active": False, "position": "right"}})
        placer = sd._Placer(self.service, "right")
        placer._stop_event = MagicMock()
        placer._stop_event.wait.side_effect = [False, False, True]
        placer.run()
        self.assertEqual(self.platform.moves, [])
        self.assertEqual(placer._stop_event.wait.call_count, 1)

    def test_placer_follows_the_saved_side(self):
        self.store.replace("display", {"secondScreen": {"active": True, "position": "left"}})
        self.platform.displays[1].x = 2560
        placer = sd._Placer(self.service, "right")
        placer._stop_event = MagicMock()
        placer._stop_event.wait.side_effect = [False, True]
        placer.run()
        self.assertEqual(self.platform.moves, [("\\\\.\\DISPLAY3", -1920, 0)])

    def test_stale_status_does_not_start_a_placer_after_the_second_screen_went_off(self):
        self.service._ensure_placer("right")  # state says off: nothing starts
        self.assertIsNone(self.service._placer)
        self.store.replace("display", {"secondScreen": {"active": True, "position": "left"}})
        with patch.object(sd._Placer, "start") as start:
            self.service._ensure_placer("right")
        start.assert_called_once()
        self.assertEqual(self.service._placer.position, "left")


class SettingsFailureTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service, self.sunshine, self.platform, self.ps, self.store = make_service(self.folder.name)
        self.client, self.headers = make_client(self.service)
        self.addCleanup(self.client.close)

    def test_settings_that_cannot_be_saved_are_503_and_sunshine_is_untouched(self):
        with patch.object(self.store, "replace", side_effect=PermissionError("denied")), \
                self.assertLogs("orbit.streamdisplay", level="ERROR"):
            response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (503, sd.SETTINGS_NOT_SAVED))
        self.assertEqual((self.sunshine.saved, self.sunshine.restarts), ([], 0))

    def test_failed_rollback_still_reports_the_real_error(self):
        self.sunshine.on_save = lambda count: self.ps.stream(True) if count == 1 else None
        with patch.object(self.store, "remove", side_effect=OSError("disk gone")), \
                self.assertLogs("orbit.streamdisplay", level="ERROR"):
            response = self.client.post("/api/stream/display/fill", json={"enabled": True}, headers=self.headers)
        self.assertEqual((response.status_code, response.json()["detail"]), (409, sd.STREAM_RUNNING))
        self.assertEqual(self.sunshine.conf, ORIGINAL_CONFIG)

    def test_unexpected_windows_error_is_503_not_500(self):
        with patch.object(self.service, "ensure_mode", side_effect=OSError(5, "Access is denied")), \
                self.assertLogs("orbit.streamdisplay", level="ERROR"):
            response = self.client.post("/api/stream/display/modes", json={"width": 2556, "height": 1179},
                                        headers=self.headers)
        self.assertEqual(response.status_code, 503)
        self.assertIn("Windows refused", response.json()["detail"])


if __name__ == "__main__":
    unittest.main()
