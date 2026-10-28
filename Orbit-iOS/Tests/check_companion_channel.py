"""PC Companion update channel and beta versions, agent to Swift.

The real agent answers `/api/status` and `/api/update/check` (GitHub is a fake dictionary), on the
stable and on the beta channel. The production Swift models of iPhone and Mac decode those replies,
and the shared `OrbitCompanionVersion` must read every version the same way the agent's
`orbit_updater` does ("4.6.0b1" is "4.6.0 beta 1", a pre-release). Run with the agent's development
Python environment on macOS (Swift required); nothing listens on the network.
"""
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
from fastapi.testclient import TestClient

import orbit_agent
import orbit_settings
import orbit_updater

TOKEN = "check-only-token-with-more-than-24-characters"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
RAW = "https://raw.githubusercontent.com/AceDimi2005/Orbit/"


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


def github(main, beta):
    replies = {
        "https://api.github.com/repos/AceDimi2005/Orbit/releases?per_page=20": b"[]",
        RAW + "main/Orbit-Windows-Agent/orbit_agent.py": f'AGENT_VERSION = "{main}"\n'.encode(),
        RAW + "beta/Orbit-Windows-Agent/orbit_agent.py": f'AGENT_VERSION = "{beta}"\n'.encode(),
    }

    def opener(request, timeout=6.0):
        if request.full_url in replies:
            return io.BytesIO(replies[request.full_url])
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)
    return opener


VERSIONS = ["4.5.2", "v4.5.2", "4.6.0b1", "4.6.0b12", "4.6.0rc2", "4.6.0a1", "4.6", "10.0.0b3"]
NOT_VERSIONS = ["4.0.0 · preview", "4.2.0 · preview", "", "beta", "4.6.0-beta.1", "4.6.0b", "4..0", "4.6.0x1"]

with tempfile.TemporaryDirectory(prefix="orbit-channel-") as directory:
    temporary = Path(directory)
    orbit_settings.set_shared_store(orbit_settings.SettingsStore(temporary / "settings.json"))
    replies = {}
    # No lifespan (no `with TestClient`): nothing starts in the background and the token stays patched.
    client = TestClient(orbit_agent.app)
    with patch.object(orbit_agent, "API_TOKEN", TOKEN), patch.object(orbit_agent, "AGENT_VERSION", "4.6.0b1"), \
         patch.dict(orbit_agent.STATE, {"agentVersion": "4.6.0b1"}):
        with patch.object(orbit_updater, "urlopen", github(main="4.5.2", beta="4.6.0b2")):
            for channel in ("stable", "beta"):
                orbit_updater.set_channel(channel)
                replies[f"status-{channel}"] = client.get("/api/status", headers=AUTH).json()
                replies[f"check-{channel}"] = client.get("/api/update/check", headers=AUTH).json()
    client.close()
    orbit_settings.set_shared_store(None)

    # What the agent promises, before Swift reads it.
    assert replies["status-stable"]["updateChannel"] == "stable"
    assert replies["status-beta"]["updateChannel"] == "beta"
    stable, beta = replies["check-stable"], replies["check-beta"]
    assert (stable["channel"], stable["updateAvailable"], stable["latestVersion"]) == ("stable", False, "4.5.2"), stable
    assert stable["currentVersionDisplay"] == "4.6.0 beta 1" and stable["currentIsPrerelease"], stable
    assert (beta["channel"], beta["updateAvailable"], beta["latestVersion"]) == ("beta", True, "4.6.0b2"), beta
    assert beta["downloadUrl"].endswith("/zip/refs/heads/beta"), beta

    expected = {text: {"display": orbit_updater.display_version(text),
                       "isPrerelease": orbit_updater.is_prerelease(text)} for text in VERSIONS}
    # An agent before 4.5.2: the same status without the channel.
    replies["status-old"] = {**{key: value for key, value in replies["status-stable"].items() if key != "updateChannel"},
                             "agentVersion": "4.5.1"}
    for name, payload in replies.items():
        (temporary / f"{name}.json").write_text(json.dumps(payload, allow_nan=False))
    (temporary / "expected.json").write_text(json.dumps(expected))
    (temporary / "not-versions.json").write_text(json.dumps(NOT_VERSIONS))

    ios = (ROOT / "Orbit-iOS/Orbit/ModelsAndServices.swift").read_text()
    mac = (ROOT / "Orbit-iOS/OrbitMac/OrbitMacModels.swift").read_text()
    (temporary / "Models.swift").write_text(
        "import Foundation\n" + swift_block(ios, "struct PCMetrics: Codable {") + swift_block(mac, "struct MacPCMetrics: Codable {"))
    (temporary / "main.swift").write_text(r'''
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
func load<T: Decodable>(_ type: T.Type, _ name: String) -> T {
    try! JSONDecoder().decode(type, from: Data(contentsOf: folder.appendingPathComponent("\(name).json")))
}
struct Expected: Decodable { let display: String; let isPrerelease: Bool }
struct Check: Decodable { let currentVersion: String?; let latestVersion: String?; let updateAvailable: Bool?; let releaseTitle: String?; let channel: String? }

// The agent's version reading and the apps' agree on every version the agent can report.
for (text, want) in load([String: Expected].self, "expected") {
    let display = OrbitCompanionVersion.display(text)
    precondition(display == want.display || (text.hasPrefix("v") && display == text), "\(text): \(display ?? "nil") vs \(want.display)")
    precondition(OrbitCompanionVersion.isPrerelease(text) == want.isPrerelease, "\(text) prerelease")
}
// Anything that is not a canonical version is shown as it is and never counts as a beta.
for text in load([String].self, "not-versions") {
    precondition(OrbitCompanionVersion.parts(text) == nil, "\(text) parsed")
    precondition(OrbitCompanionVersion.display(text) == text && OrbitCompanionVersion.compact(text) == text, text)
    precondition(!OrbitCompanionVersion.isPrerelease(text), text)
}
precondition(OrbitCompanionVersion.display("4.6.0b1") == "4.6.0 beta 1")
precondition(OrbitCompanionVersion.compact("4.6.0b1") == "4.6.0 β1" && OrbitCompanionVersion.compact("4.6.0rc2") == "4.6.0 RC2")
precondition(OrbitCompanionVersion.compact("4.6.0a3") == "4.6.0 α3" && OrbitCompanionVersion.compact("4.5.2") == "4.5.2")
precondition(OrbitCompanionVersion.display(nil) == nil && OrbitCompanionVersion.compact(nil) == nil)
precondition(OrbitCompanionVersion.isBetaChannel("beta") && OrbitCompanionVersion.isBetaChannel(" Beta "))
precondition(!OrbitCompanionVersion.isBetaChannel("stable") && !OrbitCompanionVersion.isBetaChannel(nil))

// iPhone and Mac read the channel from /api/status next to the version.
for channel in ["stable", "beta"] {
    let phone = load(PCMetrics.self, "status-\(channel)")
    let mac = load(MacPCMetrics.self, "status-\(channel)")
    precondition(phone.updateChannel == channel && mac.updateChannel == channel, channel)
    precondition(phone.agentVersion == "4.6.0b1" && OrbitCompanionVersion.isPrerelease(mac.agentVersion))
    precondition(OrbitCompanionVersion.isBetaChannel(phone.updateChannel) == (channel == "beta"))
}
// An older agent without the field still decodes.
let old = load(PCMetrics.self, "status-old"), oldMac = load(MacPCMetrics.self, "status-old")
precondition(old.updateChannel == nil && oldMac.updateChannel == nil && !OrbitCompanionVersion.isPrerelease(old.agentVersion))

// The update check on each channel: beta off keeps the beta build (no update), beta on offers the next beta.
let stable = load(Check.self, "check-stable"), beta = load(Check.self, "check-beta")
precondition(stable.updateAvailable == false && !OrbitCompanionVersion.isBetaChannel(stable.channel))
precondition(OrbitCompanionVersion.isPrerelease(stable.currentVersion) && !OrbitCompanionVersion.isPrerelease(stable.latestVersion))
precondition(beta.updateAvailable == true && OrbitCompanionVersion.isBetaChannel(beta.channel))
precondition(OrbitCompanionVersion.display(beta.latestVersion) == "4.6.0 beta 2")
print("PASS: update channel in /api/status and /api/update/check (stable and beta, no downgrade), iPhone and Mac models, beta version display")
''')
    binary = temporary / "channel-check"
    # Types the status models use from other shared files, on the branches that have them.
    support = [str(path) for path in (ROOT / "Orbit-iOS/Shared/OrbitPowerCountdown.swift",) if path.exists()]
    subprocess.run(["swiftc", "-swift-version", "5", "-Onone",
                    str(ROOT / "Orbit-iOS/Shared/OrbitCompanionVersion.swift"), *support, str(temporary / "Models.swift"),
                    str(temporary / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temporary)], check=True)
