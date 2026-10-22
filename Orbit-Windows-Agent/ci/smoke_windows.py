"""Windows smoke test for CI: the real Windows code paths, read-only.

Runs on a GitHub windows-latest runner. It changes nothing that lasts: every file the
agent writes goes to a temporary folder, nothing is typed, clicked, copied, played,
shut down or elevated, and the agent's ports are free ports on this runner.

Checks: every module imports; the agent starts in console mode (no tray, no Bonjour) and
answers /api/discover, the authenticated read endpoints and the companion window, then
stops through its loopback hand-over; icons come out of notepad.exe and
AudioSrv.dll,-203; a file description is read; EnumWindows and the process list with icon
IDs work; a fixture Steam library parses; `powercfg /list` is read; the network and
firewall diagnosis runs; the SendInput structure has Windows' size.
"""
import ctypes
import importlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

AGENT = Path(__file__).resolve().parents[1]
STATE = Path(tempfile.mkdtemp(prefix="orbit-smoke-"))
# Every path the agent derives from these is set before any agent module is imported.
os.environ.update({"LOCALAPPDATA": str(STATE), "ORBIT_TOKEN_FILE": str(STATE / ".orbit-token"),
                   "ORBIT_WIDGET_TOKEN_FILE": str(STATE / ".orbit-widget-token"),
                   "ORBIT_SUNSHINE_LOGIN_FILE": str(STATE / ".orbit-sunshine-login"),
                   "ORBIT_HISTORY_FILE": str(STATE / "history.sqlite3"), "ORBIT_HOST": "127.0.0.1"})
sys.path.insert(0, str(AGENT))
sys.stdout.reconfigure(encoding="utf-8")
results = []


def check(name):
    def wrap(function):
        started = time.monotonic()
        try:
            detail = function()
            results.append((name, True, detail))
            print(f"PASS {name}" + (f": {detail}" if detail else ""), flush=True)
        except Exception as error:  # report every failure, then fail the job at the end
            results.append((name, False, repr(error)))
            print(f"FAIL {name}: {error!r}", flush=True)
        finally:
            print(f"     ({time.monotonic() - started:.1f} s)", flush=True)
        return function
    return wrap


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@check("import every orbit module")
def imports():
    names = sorted(path.stem for path in AGENT.glob("orbit_*.py"))
    for name in names:
        importlib.import_module(name)
    return f"{len(names)} modules"


@check("icons from notepad.exe and AudioSrv.dll,-203")
def icons():
    import orbit_icons
    windows = os.environ.get("SystemRoot", r"C:\Windows")
    notepad = orbit_icons.extract_icon_png(os.path.join(windows, "notepad.exe"))
    assert notepad and notepad.startswith(orbit_icons.PNG_SIGNATURE), "notepad.exe gave no PNG"
    location = orbit_icons.parse_icon_location(r"@%SystemRoot%\System32\AudioSrv.dll,-203")
    assert location and location[1] == -203, location
    speaker = orbit_icons.extract_icon_png(*location)
    assert speaker and speaker.startswith(orbit_icons.PNG_SIGNATURE), "AudioSrv.dll,-203 gave no PNG"
    registry = orbit_icons.IconRegistry()
    identity = registry.register(os.path.join(windows, "notepad.exe"))
    assert registry.lookup([identity])[identity], "the registry did not serve the icon"
    return f"notepad {len(notepad)} B, speaker {len(speaker)} B"


@check("file description")
def description():
    import orbit_desktop
    text = orbit_desktop._file_description(os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "notepad.exe"))
    assert text, "notepad.exe has no FileDescription"
    return text


@check("EnumWindows and the application context")
def windows():
    import orbit_desktop
    pids, executables = orbit_desktop._application_context()
    assert isinstance(pids, set) and isinstance(executables, set)
    return f"{len(pids)} windowed processes"


@check("process list with icon IDs")
def processes():
    import orbit_processes
    snapshot = orbit_processes.collect_processes()
    rows = snapshot["processes"]
    assert rows, "no processes"
    with_icons = [row for row in rows if row.get("iconID")]
    assert with_icons, "no process has an icon ID"
    return f"{len(rows)} processes, {len(with_icons)} with icons"


@check("fixture Steam library")
def steam():
    import orbit_library
    root = STATE / "Steam"
    other = STATE / "Games" / "SteamLibrary"
    (root / "steamapps").mkdir(parents=True)
    (other / "steamapps" / "common" / "Hades" / "x64").mkdir(parents=True)
    (other / "steamapps" / "common" / "Hades" / "x64" / "Hades.exe").write_bytes(b"MZ")
    (root / "steamapps" / "libraryfolders.vdf").write_text(
        '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n'
        % (str(root).replace("\\", "\\\\"), str(other).replace("\\", "\\\\")), encoding="utf-8")
    (other / "steamapps" / "appmanifest_1145360.acf").write_text(
        '"AppState"\n{\n\t"appid"\t\t"1145360"\n\t"name"\t\t"Hades"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"Hades"\n'
        '\t"SizeOnDisk"\t\t"15000000000"\n\t"LastPlayed"\t\t"1700000000"\n}\n', encoding="utf-8")
    cover = root / "appcache" / "librarycache" / "1145360" / "a1b2"
    cover.mkdir(parents=True)
    (cover / "library_600x900.jpg").write_bytes(b"\xff\xd8\xff\xe0" + b"\0" * 32)
    library = orbit_library.GameLibrary(sources=[orbit_library.SteamSource(root=root)])
    snapshot = library.snapshot([str(other / "steamapps" / "common" / "Hades" / "x64" / "Hades.exe")])
    game = snapshot["games"][0]
    assert (game["id"], game["title"], game["isRunning"], game["canLaunch"]) == ("steam:1145360", "Hades", True, True), game
    assert library.covers.read(game["coverID"])[1] == "image/jpeg"
    assert game["iconID"], "the game's exe has no icon ID"
    return json.dumps({key: game[key] for key in ("id", "title", "sizeBytes", "lastPlayedAt")})


@check("powercfg /list")
def power_plans():
    import orbit_power
    plans = orbit_power.WindowsPower().plans()
    assert plans, "no power plans"
    assert sum(plan["active"] for plan in plans) == 1, plans
    return ", ".join(f"{plan['name']}{' (active)' if plan['active'] else ''}" for plan in plans)


@check("network and firewall diagnosis (read-only)")
def diagnosis():
    import orbit_diagnostics
    report = orbit_diagnostics.Diagnostics(address=lambda: None, elevate=lambda script: (_ for _ in ()).throw(
        AssertionError("the smoke test must never elevate"))).report()
    assert report["verdict"]["state"] in ("ok", "warning", "problem", "unknown")
    if os.name == "nt" and not report["available"]:
        for name in ("PROFILES_SCRIPT", "RULES_SCRIPT", "ADDRESSES_SCRIPT"):  # what PowerShell said, for the log
            started = time.monotonic()
            completed = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", getattr(orbit_diagnostics, name)],
                                       capture_output=True, timeout=60, creationflags=orbit_diagnostics.CREATE_NO_WINDOW)
            print(f"     {name}: exit {completed.returncode} after {time.monotonic() - started:.1f} s, "
                  f"stdout {completed.stdout[:200]!r}, stderr {completed.stderr[:400]!r}", flush=True)
        raise AssertionError(f"the diagnosis is unavailable: {report.get('reason')}")
    profiles = ", ".join(f"{item['interface']} {item['category']}" for item in report["profiles"]) or "none"
    detail = f"{report['verdict']['title']}; network profiles: {profiles}"
    if os.name == "nt":
        assert len(report["firewall"]["rules"]) == 3, report["firewall"]
        # Why the readings end with "exit 0": the same reading without it, on a PC with no Orbit rule.
        bare = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                               orbit_diagnostics.RULES_SCRIPT[:-len(orbit_diagnostics.READ_END)]],
                              capture_output=True, timeout=60, creationflags=orbit_diagnostics.CREATE_NO_WINDOW)
        detail += f"; without 'exit 0' the firewall reading exits {bare.returncode}"
    return detail


@check("SendInput structure")
def send_input():
    import orbit_input
    expected = 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28
    assert ctypes.sizeof(orbit_input.INPUT) == expected, ctypes.sizeof(orbit_input.INPUT)
    keyboard = orbit_input.WindowsKeyboard()
    assert keyboard.scan(0x41) > 0, "MapVirtualKeyW gave no scan code for A"
    return f"{ctypes.sizeof(orbit_input.INPUT)} bytes"


@check("Edge for the companion window")
def edge():
    import orbit_window
    path = orbit_window.find_edge()
    assert path and Path(path).is_file(), "msedge.exe not found"
    return path


@check("agent in console mode")
def agent():
    ports = {"ORBIT_PORT": free_port(), "ORBIT_TLS_PORT": free_port(), "ORBIT_WINDOW_PORT": free_port()}
    environment = {**os.environ, "PYTHONUNBUFFERED": "1", **{key: str(value) for key, value in ports.items()}}
    process = subprocess.Popen([sys.executable, str(AGENT / "orbit_agent.py"), "--console", "--no-tray", "--no-discovery"],
                               cwd=str(AGENT), env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # the pinned fingerprint is checked below instead

    def call(url, token=None, method="GET", host=None):
        request = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        if host:
            request.add_header("Host", host)
        with urllib.request.urlopen(request, timeout=10, context=context if url.startswith("https") else None) as response:
            return response.status, json.loads(response.read() or b"{}") if "json" in response.headers.get("content-type", "") else response.read()

    token, output = None, ""
    try:
        discover = None
        for _ in range(150):
            try:
                _, discover = call(f"http://127.0.0.1:{ports['ORBIT_PORT']}/api/discover")
                break
            except OSError:
                if process.poll() is not None:
                    raise AssertionError(f"the agent exited with {process.returncode}")
                time.sleep(0.2)
        assert discover and discover["service"] == "orbit-agent", discover
        token = Path(os.environ["ORBIT_TOKEN_FILE"]).read_text(encoding="utf-8").strip()
        secure = f"https://127.0.0.1:{ports['ORBIT_TLS_PORT']}"
        with socket.create_connection(("127.0.0.1", ports["ORBIT_TLS_PORT"]), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                import hashlib
                fingerprint = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest().upper()
        assert discover["fingerprint"].replace(":", "") == fingerprint, "the certificate is not the advertised one"
        _, capabilities = call(f"{secure}/api/capabilities", token)
        assert capabilities["apiVersion"] == 2 and capabilities["deviceName"] == "Legacy device", capabilities
        for path in ("/api/status", "/api/specs", "/api/devices", "/api/power", "/api/library", "/api/settings",
                     "/api/activity", "/api/audio/outputs", "/api/processes", "/api/sunshine/info"):
            try:
                status, _ = call(secure + path, token)
            except urllib.error.HTTPError as error:
                status = error.code
            # 503: no audio device on a CI runner; 501 (PC controls need Windows) only off Windows.
            assert status in ((200, 503) if os.name == "nt" else (200, 501, 503)), (path, status)
        try:
            call(f"http://127.0.0.1:{ports['ORBIT_PORT']}/api/status", "not-a-token")
            raise AssertionError("a wrong token was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 401 and json.loads(error.read())["code"] == "invalid_token"
        status, page = call(f"http://127.0.0.1:{ports['ORBIT_WINDOW_PORT']}/", host=f"127.0.0.1:{ports['ORBIT_WINDOW_PORT']}")
        assert status == 200 and b"SIGNED_IN = false" in page
        try:
            call(f"http://127.0.0.1:{ports['ORBIT_WINDOW_PORT']}/", host="attacker.example")
            raise AssertionError("a foreign Host header was served")
        except urllib.error.HTTPError as error:
            assert error.code == 403
        status, reply = call(f"http://127.0.0.1:{ports['ORBIT_PORT']}/api/internal/handover", token, method="POST")
        assert reply["status"] == "stopping"
        process.wait(timeout=30)
        assert process.returncode == 0, f"exit code {process.returncode}"
    finally:
        if process.poll() is None:
            process.kill()
        output = process.communicate()[0] if process.stdout else ""
        print("     agent output:\n" + "\n".join("       " + line for line in (output or "").splitlines()[-25:]), flush=True)
    assert token and token not in (output or ""), "the token reached the console output"
    return f"ports {ports}"


failed = [name for name, passed, _ in results if not passed]
shutil.rmtree(STATE, ignore_errors=True)  # files still open in this process stay until the runner is recycled
print(f"\n{len(results) - len(failed)} of {len(results)} checks passed" + (f"; failed: {', '.join(failed)}" if failed else ""))
sys.exit(1 if failed else 0)
