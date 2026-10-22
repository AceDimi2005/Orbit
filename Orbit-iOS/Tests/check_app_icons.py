"""App icons and the Task Manager–style audio mixer order, agent to Swift.

The real agent code builds the payloads (Windows APIs mocked), and the production
Swift models of iPhone, Mac and Apple TV decode them. The shared icon store runs
against the agent's real /api/icons reply. Run with the agent's development Python
environment on macOS (Swift required); nothing listens on the network.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
from fastapi.testclient import TestClient

import orbit_agent
import orbit_desktop
import orbit_icons
import orbit_processes


def swift_block(text, header):
    """The source of one declaration, from its header to the matching brace."""
    start = text.index(header)
    depth, index = 0, text.index("{", start)
    while True:
        character = text[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1] + "\n"
        index += 1


def session(instance, pid, name, executable, state, display=None):
    volume = MagicMock()
    volume.GetMasterVolume.return_value = 0.5
    volume.GetMute.return_value = False
    process = MagicMock()
    process.name.return_value = name
    process.create_time.return_value = 1700000000.5
    process.exe.return_value = executable
    item = SimpleNamespace(InstanceIdentifier=instance, ProcessId=pid, State=state,
                           Process=None if pid == 0 else process, SimpleAudioVolume=volume)
    if display:
        item.DisplayName = display
    return item


@contextmanager
def listed(items):
    yield items


PNG = orbit_icons.encode_png(2, 2, bytes([255, 64, 0, 255]) * 4)
registry = orbit_icons.IconRegistry(extractor=lambda path, index: PNG if path.endswith("Spotify.exe") else None)

with patch.object(orbit_desktop, "ICONS", registry), patch.object(orbit_processes, "ICONS", registry):
    items = [
        session("sys", 0, "System sounds", None, 0),
        session("helper", 30, "nvcontainer.exe", "C:\\NVIDIA\\nvcontainer.exe", 1),
        session("chat", 20, "Discord.exe", "C:\\Discord\\Discord.exe", 0),
        session("music", 21, "Spotify.exe", "C:\\Spotify\\Spotify.exe", 1),
        session("browser", 22, "chrome.exe", "C:\\Chrome\\chrome.exe", 1, display="Google Chrome"),
    ]
    with patch.object(orbit_desktop, "_audio_sessions", lambda: listed(items)), \
         patch.object(orbit_desktop, "_application_context", return_value=({20, 21, 99}, {"c:\\chrome\\chrome.exe"})), \
         patch.object(orbit_desktop, "_file_description", side_effect=lambda path: {"C:\\Spotify\\Spotify.exe": "Spotify"}.get(path)):
        sessions = orbit_desktop.list_audio_sessions()
    legacy_sessions = [{key: row[key] for key in ("id", "pid", "name", "volume", "isMuted", "processCreateTime",
                                                  "outputDeviceID", "outputDeviceName")} for row in sessions]

    process = MagicMock()
    process.info = {"pid": 21, "name": "Spotify.exe", "create_time": 1700000000.5,
                    "memory_info": SimpleNamespace(rss=128 * 1024 * 1024), "cpu_times": SimpleNamespace(user=1, system=1),
                    "status": "running", "username": "PC\\Player", "exe": "C:\\Spotify\\Spotify.exe"}
    with patch.object(orbit_processes.psutil, "process_iter", return_value=[process]), \
         patch.object(orbit_processes, "_protected_pids", return_value={0, 4}), \
         patch.object(orbit_processes, "_gpu_snapshot", return_value=({}, "No GPU counters in this check")):
        processes = orbit_processes.collect_processes()

    spotify = next(row["iconID"] for row in sessions if row["name"] == "Spotify.exe")
    discord = next(row["iconID"] for row in sessions if row["name"] == "Discord.exe")
    assert processes["processes"][0]["iconID"] == spotify, "the same executable has one icon ID everywhere"
    with patch.object(orbit_agent, "API_TOKEN", "check-only-token-with-more-than-24-characters"), \
         patch.object(orbit_agent, "ICONS", registry):
        client = TestClient(orbit_agent.app)
        reply = client.get(f"/api/icons?ids={spotify},{discord},{'0' * 32}",
                           headers={"Authorization": "Bearer check-only-token-with-more-than-24-characters"})
        client.close()
    assert reply.status_code == 200, reply.text
    icons = reply.json()

expected_order = [(row["displayName"], row["kind"]) for row in sessions]
assert expected_order == [("Google Chrome", "app"), ("Spotify", "app"), ("Discord", "app"),
                          ("nvcontainer", "background"), ("System sounds", "system")], expected_order

ios_source = (ROOT / "Orbit-iOS/Orbit/DesktopToolsView.swift").read_text()
ios_models = (ROOT / "Orbit-iOS/Orbit/ModelsAndServices.swift").read_text()
mac_models = (ROOT / "Orbit-iOS/OrbitMac/OrbitMacModels.swift").read_text()
tv_models = (ROOT / "Orbit-iOS/OrbitTV/OrbitTVViewModel.swift").read_text()
models = "import Foundation\n" + "".join([
    swift_block(ios_source, "private struct AudioMixerSession:").replace("private struct", "struct", 1),
    swift_block(ios_models, "struct PCProcess:"),
    swift_block(mac_models, "struct MacAudioSession:"),
    swift_block(mac_models, "struct MacProcess:"),
    swift_block(tv_models, "struct TVAudioSession:"),
    swift_block(tv_models, "struct TVProcessItem:"),
    swift_block(mac_models, "struct OrbitError:"),
])

MAIN = r'''
import Foundation
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
}
struct Sessions<Session: Decodable>: Decodable { let sessions: [Session] }
struct Processes<Process: Decodable>: Decodable { let processes: [Process] }

let iphone = try load(Sessions<AudioMixerSession>.self, "sessions").sessions
let mac = try load(Sessions<MacAudioSession>.self, "sessions").sessions
let tv = try load(Sessions<TVAudioSession>.self, "sessions").sessions
precondition(iphone.map(\.title) == ["Google Chrome", "Spotify", "Discord", "nvcontainer", "System sounds"])
precondition(mac.map(\.title) == iphone.map(\.title) && tv.map(\.title) == iphone.map(\.title))
precondition(iphone[0].detail == "chrome.exe · PID 22" && iphone[4].detail == "Windows system sounds")
precondition(tv[1].detail == "Spotify.exe • PID 21" && tv[4].detail == "System sounds")
precondition(iphone.map { $0.isActive ?? false } == [true, true, false, true, false])
for groups in [OrbitAudioSessionKind.groups(iphone, kind: \.kind).map(\.title),
               OrbitAudioSessionKind.groups(mac, kind: \.kind).map(\.title),
               OrbitAudioSessionKind.groups(tv, kind: \.kind).map(\.title)] {
    precondition(groups == ["Apps (3)", "Background processes (1)", "Windows (1)"], "\(groups)")
}
let grouped = OrbitAudioSessionKind.groups(mac, kind: \.kind)
precondition(grouped[0].sessions.map(\.name) == ["chrome.exe", "Spotify.exe", "Discord.exe"])
precondition(OrbitAudioSessionKind(agentValue: "future-kind") == .background && OrbitAudioSessionKind(agentValue: nil) == .background)

// Agents before 4.4: no names, groups or icons. One list in the agent's order.
let legacy = try load(Sessions<MacAudioSession>.self, "legacy").sessions
precondition(legacy.allSatisfy { $0.kind == nil && $0.iconID == nil && $0.displayName == nil && $0.title == $0.name })
let legacyGroups = OrbitAudioSessionKind.groups(legacy, kind: \.kind)
precondition(legacyGroups.count == 1 && legacyGroups[0].title == "Applications" && legacyGroups[0].sessions.count == 5)
precondition(OrbitAudioSessionKind.groups([MacAudioSession](), kind: \.kind).isEmpty)

let spotifyIcon = mac[1].iconID!
let discordIcon = mac[2].iconID!
let iphoneProcesses = try load(Processes<PCProcess>.self, "processes").processes
let macProcesses = try load(Processes<MacProcess>.self, "processes").processes
let tvProcesses = try load(Processes<TVProcessItem>.self, "processes").processes
precondition(iphoneProcesses[0].iconID == spotifyIcon && macProcesses[0].iconID == spotifyIcon && tvProcesses[0].iconID == spotifyIcon)
precondition(OrbitAppIconStore.isValid(spotifyIcon) && !OrbitAppIconStore.isValid("../" + String(spotifyIcon.dropFirst(3))))

let agentReply = try load(OrbitAppIconBatch.self, "icons")
precondition(agentReply.icons[spotifyIcon] != nil && agentReply.icons[discordIcon]! == nil)

final class Calls { var batches: [[String]] = [] }

@MainActor
func checkStore() async throws {
    // Batching: one screen of rows shares a request, at most 48 IDs each.
    let calls = Calls()
    let store = OrbitAppIconStore()
    store.configure(scope: "pc-1") { ids in
        calls.batches.append(ids)
        return OrbitAppIconBatch(icons: agentReply.icons.filter { ids.contains($0.key) })
    }
    precondition(store.scopeVersion == 1)
    store.configure(scope: "pc-1") { ids in
        calls.batches.append(ids)
        return OrbitAppIconBatch(icons: agentReply.icons.filter { ids.contains($0.key) })
    }
    precondition(store.scopeVersion == 1, "the same PC again keeps its icons")
    let filler = (0..<48).map { String(format: "%032x", $0 + 1) }
    for id in [spotifyIcon, discordIcon] + filler { store.request(id) }
    store.request(spotifyIcon)
    store.request("not-an-icon-id")
    store.request(nil)
    try await Task.sleep(for: .milliseconds(400))
    precondition(calls.batches.map(\.count) == [48, 2], "\(calls.batches.map(\.count))")
    precondition(calls.batches[0].prefix(2) == [spotifyIcon, discordIcon])
    let image = store.image(for: spotifyIcon)
    precondition(image != nil && image!.size == NSSize(width: 2, height: 2))
    precondition(store.image(for: discordIcon) == nil && store.image(for: filler[0]) == nil)
    // Settled IDs, with or without an icon, are never asked for again.
    for id in [spotifyIcon, discordIcon, filler[0]] { store.request(id) }
    try await Task.sleep(for: .milliseconds(200))
    precondition(calls.batches.count == 2)
    // Another PC starts from scratch.
    store.configure(scope: "pc-2") { ids in
        calls.batches.append(ids)
        return OrbitAppIconBatch(icons: [:])
    }
    precondition(store.images.isEmpty && store.image(for: spotifyIcon) == nil && store.scopeVersion == 2)
    store.request(spotifyIcon)
    try await Task.sleep(for: .milliseconds(200))
    precondition(calls.batches.count == 3 && calls.batches[2] == [spotifyIcon])

    // An agent before 4.4 answers 404: stop asking that PC.
    let old = Calls()
    let legacyStore = OrbitAppIconStore()
    legacyStore.configure(scope: "old") { ids in
        old.batches.append(ids)
        throw OrbitError(message: "Not Found", statusCode: 404)
    }
    legacyStore.request(spotifyIcon)
    try await Task.sleep(for: .milliseconds(200))
    legacyStore.request(discordIcon)
    try await Task.sleep(for: .milliseconds(200))
    precondition(old.batches.count == 1)

    // A dropped connection: retry later, not in a loop.
    let flaky = Calls()
    let flakyStore = OrbitAppIconStore()
    flakyStore.configure(scope: "flaky") { ids in
        flaky.batches.append(ids)
        throw URLError(.timedOut)
    }
    flakyStore.request(spotifyIcon)
    try await Task.sleep(for: .milliseconds(200))
    flakyStore.request(spotifyIcon)
    try await Task.sleep(for: .milliseconds(200))
    precondition(flaky.batches.count == 1)

    // Requests made before the PC is known wait for it.
    let early = Calls()
    let earlyStore = OrbitAppIconStore()
    earlyStore.request(spotifyIcon)
    try await Task.sleep(for: .milliseconds(150))
    earlyStore.configure(scope: "late") { ids in
        early.batches.append(ids)
        return OrbitAppIconBatch(icons: agentReply.icons.filter { ids.contains($0.key) })
    }
    try await Task.sleep(for: .milliseconds(300))
    precondition(early.batches == [[spotifyIcon]] && earlyStore.image(for: spotifyIcon) != nil)
}

try await checkStore()
print("PASS: Task Manager–style mixer order and groups on iPhone, Mac and Apple TV, legacy agents, opaque icon IDs in process and audio rows, /api/icons decoding, batched icon loading, 404 and offline handling, PC switches")
'''

with tempfile.TemporaryDirectory(prefix="orbit-icons-") as directory:
    temporary = Path(directory)
    for name, payload in {"sessions": {"sessions": sessions, "available": True},
                          "legacy": {"sessions": legacy_sessions, "available": True},
                          "processes": processes, "icons": icons}.items():
        (temporary / f"{name}.json").write_text(json.dumps(payload, allow_nan=False))
    (temporary / "Models.swift").write_text(models)
    (temporary / "main.swift").write_text(MAIN)
    binary = temporary / "icons-check"
    subprocess.run(["swiftc", "-swift-version", "5",
                    str(ROOT / "Orbit-iOS/Shared/OrbitAppIcons.swift"), str(temporary / "Models.swift"),
                    str(temporary / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temporary)], check=True)
