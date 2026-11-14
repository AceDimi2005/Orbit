"""Display mode (Win+P) and default audio devices, end to end between the agent and the apps' Swift code.

The agent's real routes run on loopback TLS (lifespan off, like check_companion_transport) with Windows
replaced by fakes: a display topology that answers like SetDisplayConfig, and pycaw's AudioUtilities with
two outputs and two inputs. Nothing on this Mac changes. The production Swift client
(Orbit/OrbitAPIClient.swift) and the screens' shared state (Shared/OrbitPCDisplayAudio.swift, used by the
iPhone, Mac and Apple TV apps) then switch modes and default devices through them, and an agent without
these routes (404) shows up as "update the PC Companion". The client-side refusal rule is compared with the
agent's on the same display lists.

Run with the venv python (needs fastapi, uvicorn, cryptography): python3 Orbit-iOS/Tests/check_display_audio.py
"""
from contextlib import contextmanager
import enum
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
from cryptography import x509  # noqa: E402
from fastapi import FastAPI  # noqa: E402
import uvicorn  # noqa: E402
import orbit_agent as agent  # noqa: E402
import orbit_desktop as desktop  # noqa: E402
import orbit_display_mode as display_mode  # noqa: E402
from orbit_tls import ensure_tls_identity  # noqa: E402

TOKEN = "display-audio-check-token-not-a-real-secret"


def display(name, connection="HDMI", active=True, built_in=False, virtual=False):
    return {"name": name, "connection": connection, "active": active, "builtIn": built_in, "virtual": virtual}


class FakeTopology:
    """SetDisplayConfig as Windows answers it: the mode changes on success, `code` is the Win32 error."""

    def __init__(self):
        self.listed = [display("DELL U2723QE", "DisplayPort"), display("LG TV SSCR2", "HDMI", active=False)]
        self.mode = "internal"
        self.code = 0
        self.applied = []

    def displays(self):
        listed = [dict(item) for item in self.listed]
        if self.mode in ("clone", "extend"):
            for item in listed:
                item["active"] = True
        elif self.mode == "external":
            listed[0]["active"], listed[1]["active"] = False, True
        else:
            listed[0]["active"], listed[1]["active"] = True, False
        return listed[:len(self.listed)]

    def current_mode(self):
        return self.mode

    def apply(self, mode):
        self.applied.append(mode)
        if self.code == 0:
            self.mode = mode
        return self.code


class ERole(enum.Enum):
    eConsole = 0
    eMultimedia = 1
    eCommunications = 2


class FakeAudioUtilities:
    def __init__(self):
        self.devices = {0: [SimpleNamespace(id="{0.0.0.00000000}.{speakers}", FriendlyName="Speakers (Realtek Audio)"),
                            SimpleNamespace(id="{0.0.0.00000000}.{headset}", FriendlyName="Headset Earphone (Arctis Nova)")],
                        1: [SimpleNamespace(id="{0.0.1.00000000}.{mic}", FriendlyName="Microphone (Arctis Nova)"),
                            SimpleNamespace(id="{0.0.1.00000000}.{webcam}", FriendlyName="Microphone (USB Webcam)")]}
        self.defaults = {(0, 0): "{0.0.0.00000000}.{speakers}", (0, 1): "{0.0.0.00000000}.{speakers}",
                         (0, 2): "{0.0.0.00000000}.{headset}", (1, 0): "{0.0.1.00000000}.{mic}",
                         (1, 1): "{0.0.1.00000000}.{mic}", (1, 2): "{0.0.1.00000000}.{mic}"}
        self.calls = []

    def GetAllDevices(self, data_flow, device_state):
        return list(self.devices[data_flow])

    def GetDeviceEnumerator(self):
        utilities = self

        class Endpoint:
            def __init__(self, identifier):
                self.identifier = identifier

            def GetId(self):
                return self.identifier

        class Enumerator:
            def GetDefaultAudioEndpoint(self, flow, role):
                return Endpoint(utilities.defaults[(flow, role)])
        return Enumerator()

    def SetDefaultDevice(self, identifier, roles):
        self.calls.append((identifier, [role.name for role in roles]))
        flow = 0 if identifier.startswith("{0.0.0") else 1
        for role in roles:
            self.defaults[(flow, role.value)] = identifier


SWIFT = r'''
import Foundation

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL line \(line): \(message)"); exit(1) }
}

@main struct Check {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let client = try OrbitAPIClient(host: "127.0.0.1", port: Int(args[1])!, token: args[3], fingerprint: args[4])
        let older = try OrbitAPIClient(host: "127.0.0.1", port: Int(args[2])!, token: args[3], fingerprint: args[4])
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[5]))) as! [[String: Any]]

        // The API names are the agent's, in Win+P order.
        check(OrbitDisplayMode.allCases.map(\.rawValue) == ["internal", "clone", "extend", "external"], "mode names")
        check(OrbitDisplayMode.allCases.map(\.title) == ["PC screen only", "Duplicate", "Extend", "Second screen only"], "titles")

        // Display mode screen.
        let screen = OrbitDisplayModeController()
        await screen.refresh { client }
        check(screen.error == nil && !screen.olderAgent, "read: \(String(describing: screen.error))")
        check(screen.status?.available == true && screen.status?.currentMode == .pcScreenOnly, "starts on PC screen only")
        check(screen.status?.displays.map(\.name) == ["DELL U2723QE", "LG TV SSCR2"], "displays")
        check(screen.status?.displays.map(\.active) == [true, false] && screen.status?.displays[1].detail == "HDMI · Off", "display state")
        check(OrbitDisplayMode.allCases.allSatisfy { screen.status?.refusal(for: $0) == nil }, "two displays allow every mode")
        for mode in [OrbitDisplayMode.extend, .duplicate, .secondScreenOnly, .pcScreenOnly] {
            await screen.select(mode) { client }
            check(screen.error == nil && screen.switching == nil, "switch to \(mode): \(String(describing: screen.error))")
            check(screen.status?.currentMode == mode && screen.message == "The PC switched to \(mode.title).", "after \(mode)")
        }
        check(screen.status?.displays.map(\.active) == [true, false], "PC screen only again")
        // Windows refuses (the lock screen): the agent's words reach the screen, the mode stays.
        await screen.select(.extend) { older }   // a client for the other PC: answers 404 to the switch
        check(screen.error != nil && screen.status?.currentMode == .pcScreenOnly, "a failed switch keeps the mode")
        try Data("lock".utf8).write(to: URL(fileURLWithPath: args[6]))
        try await Task.sleep(for: .milliseconds(50))
        await screen.select(.extend) { client }
        check(screen.error?.contains("lock screen") == true && screen.status?.currentMode == .pcScreenOnly, "lock screen: \(String(describing: screen.error))")
        // A switch for a PC that is no longer on screen lands nowhere.
        screen.reset()
        check(screen.status == nil && screen.error == nil && screen.message == nil, "reset")

        // An older PC Companion.
        let oldScreen = OrbitDisplayModeController()
        await oldScreen.refresh { older }
        check(oldScreen.olderAgent && oldScreen.status == nil && oldScreen.error == nil, "older agent (display)")

        // The refusal rule matches the agent's on the same displays.
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: item["status"]!)
            let status = try JSONDecoder().decode(OrbitDisplayModeStatus.self, from: data)
            let refused = item["refused"] as! [String: Bool]
            for mode in OrbitDisplayMode.allCases {
                check((status.refusal(for: mode) != nil) == refused[mode.rawValue]!, "refusal \(mode.rawValue) for \(item["status"]!)")
            }
        }

        // Default devices.
        let audio = OrbitAudioDefaultsController()
        await audio.refresh { client }
        check(audio.error == nil && !audio.olderAgent, "devices: \(String(describing: audio.error))")
        guard let devices = audio.devices else { check(false, "no devices"); return }
        check(devices.outputs.map(\.name) == ["Speakers (Realtek Audio)", "Headset Earphone (Arctis Nova)"], "outputs")
        check(devices.inputs.map(\.name) == ["Microphone (Arctis Nova)", "Microphone (USB Webcam)"], "inputs")
        check(devices.current(.output)?.name == "Speakers (Realtek Audio)" && devices.outputs[1].isDefaultCommunication, "output defaults")
        check(devices.current(.input)?.name == "Microphone (Arctis Nova)", "input default")
        await audio.choose(devices.outputs[1], flow: .output) { client }
        check(audio.error == nil && audio.changing == nil, "choose output: \(String(describing: audio.error))")
        check(audio.devices?.current(.output)?.id == devices.outputs[1].id && audio.devices?.outputs[1].isDefaultCommunication == true, "new output")
        check(audio.devices?.current(.input)?.id == devices.inputs[0].id, "input untouched")
        await audio.choose(devices.inputs[1], flow: .input) { client }
        check(audio.devices?.current(.input)?.name == "Microphone (USB Webcam)", "new input")
        // Choosing the current default sends nothing.
        await audio.choose(audio.devices!.inputs[1], flow: .input) { client }
        // A device that disconnected meanwhile: the agent's 409 becomes the screen's error.
        await audio.choose(OrbitAudioDevice(id: "{gone}", name: "Bluetooth", isDefault: false, isDefaultCommunication: false), flow: .output) { client }
        check(audio.error?.contains("disconnected") == true, "gone: \(String(describing: audio.error))")
        // A poll right after an answer is skipped; maxAge 0 always asks.
        await audio.refresh({ client }, maxAge: 60)
        await audio.refresh { client }
        check(audio.error == nil, "refresh clears the error")

        let oldAudio = OrbitAudioDefaultsController()
        await oldAudio.refresh { older }
        check(oldAudio.olderAgent && oldAudio.devices == nil, "older agent (audio)")

        // Demo mode never talks to a PC.
        let demo = OrbitAudioDefaultsController()
        demo.showDemo()
        demo.chooseDemo(OrbitAudioDevices.demo.outputs[2], flow: .output)
        check(demo.devices?.current(.output)?.id == "out-3" && demo.devices?.current(.input)?.id == "in-1", "demo")
        print("SWIFT OK")
    }
}
'''


def main():
    topology = FakeTopology()
    utilities = FakeAudioUtilities()
    cases = []
    for listed in ([display("A")], [display("A"), display("B")],
                   [display("A"), display("Virtual display", "Virtual", virtual=True)],
                   [display("A", built_in=True), display("V", "Virtual", virtual=True), display("TV", active=False)],
                   []):
        status = {"available": True, "reason": None, "mode": "extend", "displays": listed}
        cases.append({"status": status, "refused": {mode: display_mode.refusal(mode, listed) is not None
                                                   for mode in display_mode.MODES}})

    @contextmanager
    def core_audio():
        yield utilities

    requests = []
    old_agent = FastAPI()  # A PC Companion before these features: every path here is 404.

    with tempfile.TemporaryDirectory(prefix="orbit-display-audio-") as directory:
        root = Path(directory)
        lock_flag = root / "lock-flag"

        def apply(mode):
            if lock_flag.exists():
                requests.append(("refused", mode))
                return display_mode.ERROR_ACCESS_DENIED
            return FakeTopology.apply(topology, mode)

        topology.apply = apply
        (root / "cases.json").write_text(json.dumps(cases), encoding="utf-8")
        with patch("orbit_tls.local_names", return_value=[x509.DNSName("old-pc-address.invalid")]):
            cert, key, fingerprint = ensure_tls_identity(root / "tls")
        (root / "Check.swift").write_text(SWIFT, encoding="utf-8")
        binary = root / "check"
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Orbit-iOS/Orbit/OrbitAPIClient.swift"),
                        str(ROOT / "Orbit-iOS/Shared/OrbitError.swift"), str(ROOT / "Orbit-iOS/Shared/OrbitPCDisplayAudio.swift"),
                        str(root / "Check.swift"), "-o", str(binary)], check=True)
        ports = []
        for _ in range(2):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                ports.append(probe.getsockname()[1])
        servers = [uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, lifespan="off", ssl_certfile=str(cert),
                                                 ssl_keyfile=str(key), access_log=False, log_level="error"))
                   for app, port in ((agent.app, ports[0]), (old_agent, ports[1]))]
        with patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent.DISPLAY_MODE, "_platform", topology), \
                patch.object(agent.DISPLAY_MODE, "_desktop_available", lambda: True), \
                patch.object(desktop, "_core_audio", core_audio), \
                patch.dict(sys.modules, {"pycaw": SimpleNamespace(), "pycaw.constants": SimpleNamespace(ERole=ERole)}):
            threads = [threading.Thread(target=server.run, daemon=True) for server in servers]
            for thread in threads:
                thread.start()
            try:
                for _ in range(200):
                    if all(server.started for server in servers):
                        break
                    time.sleep(.025)
                assert all(server.started for server in servers), "Local TLS servers did not start"
                subprocess.run([str(binary), str(ports[0]), str(ports[1]), TOKEN, fingerprint, str(root / "cases.json"),
                                str(lock_flag)], check=True, timeout=60)
            finally:
                for server in servers:
                    server.should_exit = True
                for thread in threads:
                    thread.join(5)
    assert topology.applied == ["extend", "clone", "external", "internal"], topology.applied
    assert requests == [("refused", "extend")], requests
    assert [call[0] for call in utilities.calls] == ["{0.0.0.00000000}.{headset}", "{0.0.1.00000000}.{webcam}"], utilities.calls
    assert all(call[1] == ["eConsole", "eMultimedia", "eCommunications"] for call in utilities.calls), utilities.calls
    print("PASS: the iPhone, Mac and Apple TV screens read the PC's display mode and displays, switch between PC screen only, "
          "Duplicate, Extend and Second screen only, show Windows' refusal (lock screen) and keep the mode, refuse the same "
          "switches the PC refuses, choose the default output and input (every role, calls too), report a device that "
          "disconnected, and show an older PC Companion (404) as an update")


if __name__ == "__main__":
    main()
