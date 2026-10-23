"""Check the Shortcuts actions' models against the real agent.

Compiles `Shared/OrbitIntentModels.swift` with a small Swift driver and feeds it JSON produced by the
agent's own code (status snapshots, the Sunshine app list, FastAPI error bodies). Then compares the
Swift input checks with the agent's validators (links, typed text, clipboard size) and checks that
every action name and feature string the actions use exists in the agent.

Uses only mocked agent state. Does not start a server or access a physical PC.
Run with the venv python (needs fastapi and httpx): python3 Orbit-iOS/Tests/check_intents.py
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Orbit-Windows-Agent'))
import orbit_agent as agent  # noqa: E402
import orbit_capabilities  # noqa: E402
import orbit_desktop  # noqa: E402
import orbit_links  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from pydantic import ValidationError  # noqa: E402

TOKEN = 'check-intents-token-0123456789abcdef'


def snapshot(telemetry_age=0.0, sensor_age=0.0, **values):
    state = copy.deepcopy(agent.STATE)
    state.update(values)
    now = time.monotonic()
    with patch.object(agent, 'STATE', state), patch.object(agent, 'LAST_TELEMETRY', now - telemetry_age), \
            patch.object(agent, 'LAST_SENSOR', now - sensor_age):
        return agent.status_snapshot()


full = snapshot(telemetryAvailable=True, lastUpdated='2026-10-24T10:00:00+00:00', hostname='Intents-PC',
                cpuUsage=24.4, gpuUsage=96.5, cpuTemp=62.4, gpuTemp=71.0, ramUsedGB=12.4, ramTotalGB=32,
                fps=143.6, cpuPowerWatts=58.25, gpuPowerWatts=210, activeGame='cyberpunk2077',
                sessionLocked=False, isMuted=False, volumeAvailable=True, volume=40, gpuSource='NVIDIA SMI')
# Sensor cache expired: temperatures and CPU power disappear; NVIDIA readings stay.
stale_sensors = snapshot(sensor_age=60, telemetryAvailable=True, hostname='Intents-PC', cpuUsage=3, gpuUsage=1,
                         cpuTemp=40, gpuTemp=35, ramUsedGB=8, ramTotalGB=16, cpuPowerWatts=20, gpuPowerWatts=15,
                         gpuSource='NVIDIA SMI', activeGame=None, fps=None,
                         fpsUnavailableReason='No game is running', sessionLocked=True)
# Telemetry stopped: the agent clears only LIVE_OPTIONAL_FIELDS, so CPU load and memory keep their last values.
stale_telemetry = snapshot(telemetry_age=60, telemetryAvailable=True, hostname='Intents-PC', cpuUsage=3,
                           ramUsedGB=8, ramTotalGB=16)
# Right after the agent starts: no sample yet, CPU load and memory are placeholder zeros.
agent_start = snapshot(telemetry_age=60, hostname='Intents-PC')
assert stale_sensors['cpuTemp'] is None and stale_sensors['gpuTemp'] == 35 and stale_sensors['sensorStatus']
assert stale_telemetry['telemetryAvailable'] is False and stale_telemetry['cpuUsage'] == 3 and stale_telemetry['ramUsedGB'] == 8
assert agent_start['telemetryAvailable'] is False and agent_start['cpuUsage'] == 0.0

with patch.object(agent, 'API_TOKEN', TOKEN), patch.object(agent, 'sunshine_entries', lambda: [
        {'name': 'Desktop'}, {'name': 'Cyberpunk 2077', 'detached': ['steam://rungameid/1091500']},
        {'name': 'Notepad', 'cmd': 'notepad.exe'}, {'cmd': 'unnamed.exe'}]):
    sunshine_apps = agent.get_sunshine_apps(f'Bearer {TOKEN}')
    capabilities = agent.get_capabilities(f'Bearer {TOKEN}')

with patch.object(agent, 'API_TOKEN', TOKEN):
    client = TestClient(agent.app)
    missing_route = client.get('/api/does-not-exist', headers={'Authorization': f'Bearer {TOKEN}'})
    wrong_method = client.delete('/api/status', headers={'Authorization': f'Bearer {TOKEN}'})
    bad_volume = client.post('/api/volume', headers={'Authorization': f'Bearer {TOKEN}'})
assert missing_route.status_code == 404 and wrong_method.status_code == 405 and bad_volume.status_code == 422

# Links: the Swift check must accept exactly what orbit_links.validate_url accepts.
LINKS = [
    'https://example.com', 'http://example.com/path?q=1+2#top', 'HTTPS://EXAMPLE.COM/A', 'https://example.com:8443/x',
    'https://192.168.1.10:8080/', 'https://[::1]:8443/', 'https://xn--mnchen-3ya.de/', 'https://example.com/%20spaced',
    'https://example.com:/x', 'https://sub.domain-name.example.co.uk/a_b-c.d~e',
    'ftp://example.com/file', 'javascript:alert(1)', 'file:///C:/Windows', 'steam://rungameid/1', 'example.com',
    'https://user:secret@example.com', 'https://user@example.com', 'https://', 'https:example.com', 'https:///path',
    'https://exa mple.com', 'https://example.com/"quoted"', 'https://example.com/a\\b', 'https://example.com/{x}',
    'https://example.com/a|b', 'https://example.com:99999/', 'https://example.com:abc/', 'https://exa%41mple.com/',
    'https://example.com/\u200bzero-width', 'https://example.com/' + 'a' * 4100, 'https://example.com/' + 'a' * 4000,
]
python_links = {}
for link in LINKS:
    try:
        orbit_links.validate_url(link)
        python_links[link] = True
    except ValueError:
        python_links[link] = False

# Addresses typed into the Link field without a scheme (Swift adds https:// to the first group only).
TYPED_LINKS = {
    'localhost:3000': 'https://localhost:3000', '192.168.1.20:8080/x': 'https://192.168.1.20:8080/x',
    'example.com:8080/x': 'https://example.com:8080/x', 'example.com': 'https://example.com',
    'Example.COM:443#top': 'https://Example.COM:443#top', 'intranet:80?q=1': 'https://intranet:80?q=1',
    '[::1]:8443/': 'https://[::1]:8443/', 'https://example.com': 'https://example.com',
    'javascript:alert(1)': 'javascript:alert(1)', 'mailto:someone@example.com': 'mailto:someone@example.com',
    'ftp://example.com/file': 'ftp://example.com/file', 'user:secret@example.com': 'user:secret@example.com',
}

TYPED = {'line breaks': 'a\nb\r\nc', 'max composed': '\u00e9' * 1000, 'too long composed': '\u00e9' * 1001,
         'max decomposed': 'e\u0301' * 500, 'too long decomposed': 'e\u0301' * 501, 'emoji': 'hi \U0001F3AE',
         'empty': ''}
python_typed = {name: (len(text) <= 1000 and all(ord(ch) <= 0xFFFF for ch in text) and text != '')
                for name, text in TYPED.items()}

CLIPBOARD = {'max bmp': 'x' * (orbit_desktop.MAX_CLIPBOARD_BYTES // 2 - 1),
             'too long bmp': 'x' * (orbit_desktop.MAX_CLIPBOARD_BYTES // 2),
             'too long astral': '\U0001F600' * (orbit_desktop.MAX_CLIPBOARD_BYTES // 4),
             'null': 'a\0b', 'normal': 'C++ & ünïcode ✓'}
python_clipboard = {}
for name, text in CLIPBOARD.items():
    try:
        orbit_desktop.ClipboardWrite(text=text)
        python_clipboard[name] = True
    except ValidationError:
        python_clipboard[name] = False

fixtures = {
    'full': full, 'staleSensors': stale_sensors, 'staleTelemetry': stale_telemetry, 'agentStart': agent_start,
    'olderAgent': {'hostname': 'Old-PC', 'cpuUsage': 5},
    'invalid': {'hostname': 'Odd-PC', 'telemetryAvailable': True, 'cpuUsage': 400, 'cpuTemp': 1e300,
                'gpuUsage': 'busy', 'ramUsedGB': 40, 'ramTotalGB': 32, 'fps': -3, 'isMuted': 'no'},
    'sunshineApps': sunshine_apps, 'capabilities': capabilities,
    'errors': [
        {'name': 'missing route', 'status': missing_route.status_code, 'body': missing_route.text},
        {'name': 'wrong method', 'status': wrong_method.status_code, 'body': wrong_method.text},
        {'name': 'validation', 'status': bad_volume.status_code, 'body': bad_volume.text},
        {'name': 'token', 'status': 401, 'body': json.dumps({'detail': 'Invalid Orbit token'})},
        {'name': 'unknown app', 'status': 404, 'body': json.dumps({'detail': 'Application was not found in Sunshine'})},
        {'name': 'not windows', 'status': 501, 'body': json.dumps({'detail': 'PC controls require Windows'})},
        {'name': 'busy', 'status': 503, 'body': json.dumps({'detail': 'Windows could not execute this action'})},
        {'name': 'html', 'status': 502, 'body': '<html>Bad gateway</html>'},
    ],
    # GET /api/downloads shapes (DESIGN F1). Only queued/downloading/staging hold the rule back.
    'downloads': {'downloads': [{'id': 'steam:620', 'state': 'downloading'}, {'id': 'steam:730', 'state': 'finished'},
                                {'id': 'epic:Fortnite', 'state': 'paused'}, {'id': 'steam:1', 'state': 'failed'}],
                  'active': True},
    'downloadsPausedOnly': {'downloads': [{'id': 'epic:Fortnite', 'state': 'paused'}, {'id': 'steam:730', 'state': 'finished'}],
                            'active': False},
    'downloadsNone': {'downloads': [], 'active': False, 'stores': {'steam': True, 'epic': False, 'gog': False}},
    'downloadsTwo': {'downloads': [{'id': 'steam:1', 'state': 'queued'}, {'id': 'gog:2', 'state': 'staging'}], 'active': True},
    'links': LINKS, 'typed': TYPED, 'clipboard': CLIPBOARD, 'typedLinks': list(TYPED_LINKS),
}

DRIVER = r'''
import Foundation

@main struct IntentContractTests {
    static func status(_ object: Any) throws -> OrbitPCStatusReport {
        try JSONDecoder().decode(OrbitPCStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() throws {
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var output: [String: Any] = [:]

        // Full gaming snapshot from status_snapshot().
        let full = try status(input["full"]!)
        precondition(full.value(.cpuTemperature) == 62.4 && full.value(.gpuTemperature) == 71)
        precondition(full.value(.cpuUsage) == 24.4 && full.value(.gpuUsage) == 96.5)
        precondition(full.value(.memoryUsage) == 38.8, "memory \(String(describing: full.value(.memoryUsage)))")
        precondition(full.value(.fps) == 143.6 && full.value(.cpuPower) == 58.3 && full.value(.gpuPower) == 210)
        precondition(full.value(.totalPower) == 268.3)
        for reading in OrbitPCReading.allCases { precondition(full.value(reading) != nil, "missing \(reading)") }
        let temperature = full.readingSentence(.cpuTemperature, value: 62.4, pc: "Intents-PC")
        precondition(temperature == "Intents-PC's CPU temperature is 62 °C.", temperature)
        let power = full.readingSentence(.totalPower, value: 268.3, pc: "Intents-PC")
        precondition(power == "Intents-PC's CPU and GPU power draw is 268 W (CPU 58 W + GPU 210 W).", power)
        precondition(full.readingSentence(.memoryUsage, value: 38.8, pc: "P") == "P's memory use is 39%.")
        precondition(full.readingSentence(.fps, value: 143.6, pc: "P") == "P's game FPS is 144 FPS.")
        let sentence = full.statusSentence(pc: "Intents-PC")
        precondition(sentence == "Intents-PC is on, running cyberpunk2077 at 144 FPS: CPU 24% at 62 °C, GPU 97% at 71 °C, memory 39% used.", sentence)
        output["statusFull"] = sentence

        // Expired sensors: temperatures and CPU power missing, the PC is locked, no game.
        let stale = try status(input["staleSensors"]!)
        precondition(stale.value(.cpuTemperature) == nil && stale.value(.gpuTemperature) == 35 && stale.value(.cpuPower) == nil)
        precondition(stale.value(.totalPower) == 15 && stale.value(.fps) == nil && stale.sessionLocked == true)
        precondition(stale.readingSentence(.totalPower, value: 15, pc: "P") == "P's CPU and GPU power draw is 15 W (GPU only; the PC doesn't report CPU power).")
        let missingTemp = stale.missingReason(.cpuTemperature, pc: "Intents-PC")
        precondition(missingTemp.hasPrefix("Intents-PC isn't reporting its CPU temperature right now. Hardware sensor readings expired"), missingTemp)
        precondition(stale.missingReason(.fps, pc: "P") == "No game is running on P, so there's no FPS to read.")
        let locked = stale.statusSentence(pc: "Intents-PC")
        precondition(locked == "Intents-PC is on but locked: CPU 3%, GPU 1% at 35 °C, memory 50% used.", locked)
        output["statusLocked"] = locked

        let staleTelemetry = try status(input["staleTelemetry"]!)
        precondition(staleTelemetry.telemetryAvailable == false && staleTelemetry.value(.cpuTemperature) == nil)
        // The agent keeps the last CPU load and memory while telemetry is stale: never report them as live.
        precondition(staleTelemetry.cpuUsage == 3 && staleTelemetry.memoryUsage == 50)
        for reading in OrbitPCReading.allCases { precondition(staleTelemetry.value(reading) == nil, "stale \(reading)") }
        precondition(staleTelemetry.missingReason(.cpuUsage, pc: "P") == "P isn't reporting live readings right now. Try again in a few seconds.")
        let agentStart = try status(input["agentStart"]!)
        precondition(agentStart.value(.cpuUsage) == nil && agentStart.value(.memoryUsage) == nil)
        precondition(staleTelemetry.missingReason(.gpuUsage, pc: "P") == "P isn't reporting live readings right now. Try again in a few seconds.")
        precondition(staleTelemetry.statusSentence(pc: "P") == "P is on, but it isn't reporting live readings right now.")

        let older = try status(input["olderAgent"]!)
        precondition(older.value(.cpuUsage) == 5 && older.value(.gpuUsage) == nil && older.sessionLocked == nil)
        precondition(older.statusSentence(pc: "Old-PC") == "Old-PC is on: CPU 5%.")

        let odd = try status(input["invalid"]!)
        precondition(odd.cpuUsage == nil && odd.cpuTemp == nil && odd.gpuUsage == nil && odd.memoryUsage == nil && odd.fps == nil && odd.isMuted == nil)
        precondition(odd.statusSentence(pc: "Odd-PC") == "Odd-PC is on.")
        precondition(OrbitPCStatusReport.offlineSentence(pc: "P") == "P isn't reachable right now. It may be asleep, turned off or on another network.")

        // Sunshine list and capabilities straight from the agent's route functions.
        let apps = try JSONDecoder().decode([OrbitSunshineAppEntry].self, from: JSONSerialization.data(withJSONObject: input["sunshineApps"]!))
        precondition(apps.map(\.title) == ["Desktop", "Cyberpunk 2077", "Notepad", "Sunshine App 4"], "\(apps.map(\.title))")
        let capabilities = try JSONDecoder().decode(OrbitAgentCapabilities.self, from: JSONSerialization.data(withJSONObject: input["capabilities"]!))
        precondition(!capabilities.features.isEmpty)
        output["features"] = capabilities.features

        // FastAPI error bodies → one sentence each.
        var errors: [String: [String]] = [:]
        for case let entry as [String: Any] in input["errors"] as! [Any] {
            let error = OrbitIntentError.reply(status: entry["status"] as! Int, detail: OrbitIntentError.detail(from: Data((entry["body"] as! String).utf8)), pc: "Intents-PC")
            errors[entry["name"] as! String] = ["\(error.kind)", error.message]
        }
        precondition(errors["missing route"]?[0] == "olderCompanion" && errors["wrong method"]?[0] == "olderCompanion")
        precondition(errors["token"]?[0] == "accessRevoked" && errors["validation"]?[0] == "general")
        precondition(errors["unknown app"]?[1] == "Application was not found in Sunshine.")
        precondition(errors["not windows"]?[1] == "This action only works when Orbit Companion runs on Windows.")
        precondition(errors["busy"]?[1] == "Windows could not execute this action.")
        precondition(errors["html"]?[1].hasPrefix("Intents-PC couldn't do that (error 502).") == true)
        output["errors"] = errors

        // Sleep PC When Downloads Finish: the PC fires the rule a minute after the last download that
        // was active since the rule was set stops, then counts down; with nothing downloading it waits.
        func downloadsReport(_ key: String) throws -> OrbitDownloadsReport {
            try JSONDecoder().decode(OrbitDownloadsReport.self, from: JSONSerialization.data(withJSONObject: input[key]!))
        }
        let downloads = try downloadsReport("downloads")
        precondition(downloads.activeCount == 1 && downloads.pausedCount == 1 && downloads.active == true)
        var powerAfter: [String: String] = [:]
        powerAfter["active"] = OrbitDownloadsReport.powerAfterSentence(downloads, action: .sleep, delaySeconds: 60, pc: "P")
        precondition(powerAfter["active"] == "P will sleep about 2 minutes after its download finishes. Paused downloads don't count. You can cancel this in Orbit.", powerAfter["active"]!)
        let pausedOnly = try downloadsReport("downloadsPausedOnly")
        precondition(pausedOnly.activeCount == 0 && pausedOnly.pausedCount == 1)
        powerAfter["pausedOnly"] = OrbitDownloadsReport.powerAfterSentence(pausedOnly, action: .shutdown, delaySeconds: 60, pc: "P")
        precondition(powerAfter["pausedOnly"] == "P isn't downloading anything right now, so it will wait for the next Steam, Epic or GOG download and shut down about 2 minutes after it finishes. Paused downloads count once you resume them. You can cancel this in Orbit.", powerAfter["pausedOnly"]!)
        powerAfter["none"] = OrbitDownloadsReport.powerAfterSentence(try downloadsReport("downloadsNone"), action: .sleep, delaySeconds: 90, pc: "P")
        precondition(powerAfter["none"] == "P isn't downloading anything right now, so it will wait for the next Steam, Epic or GOG download and sleep about 2 minutes 30 seconds after it finishes. You can cancel this in Orbit.", powerAfter["none"]!)
        powerAfter["two"] = OrbitDownloadsReport.powerAfterSentence(try downloadsReport("downloadsTwo"), action: .sleep, delaySeconds: 30, pc: "P")
        precondition(powerAfter["two"] == "P will sleep about 90 seconds after its 2 downloads finish. You can cancel this in Orbit.", powerAfter["two"]!)
        powerAfter["unknown"] = OrbitDownloadsReport.powerAfterSentence(nil, action: .shutdown, delaySeconds: 600, pc: "P")
        precondition(powerAfter["unknown"] == "P will shut down about 11 minutes after its downloads finish. You can cancel this in Orbit.", powerAfter["unknown"]!)
        output["powerAfterSentences"] = powerAfter
        output["downloadsActiveStates"] = OrbitDownloadsReport.activeStates.sorted()
        output["downloadsQuietSeconds"] = OrbitDownloadsReport.quietSeconds

        // Input checks, compared with the agent's validators by the Python side.
        var links: [String: Bool] = [:]
        for case let link as String in input["links"] as! [Any] { links[link] = (try? OrbitIntentInput.webLink(link)) != nil }
        output["links"] = links
        var typed: [String: Bool] = [:]
        for (name, text) in input["typed"] as! [String: String] { typed[name] = (try? OrbitIntentInput.typedText(text)) != nil }
        output["typed"] = typed
        let normalized = try OrbitIntentInput.typedText("a\nb\r\nc")
        precondition(normalized == "a\rb\rc")
        var clipboard: [String: Bool] = [:]
        for (name, text) in input["clipboard"] as! [String: String] { clipboard[name] = (try? OrbitIntentInput.clipboardText(text)) != nil }
        output["clipboard"] = clipboard
        let bare = try OrbitIntentInput.webLink(URL(string: "example.com/page")!)
        precondition(bare == "https://example.com/page", bare)
        // Typed without a scheme: URL parsing reads "localhost:3000" as the scheme "localhost".
        for (typed, expected) in [("localhost:3000", "https://localhost:3000"), ("example.com:8080/x", "https://example.com:8080/x"),
                                  ("myserver:8080?q=1", "https://myserver:8080?q=1")] {
            let link = try OrbitIntentInput.webLink(URL(string: typed)!)
            precondition(link == expected, link)
        }
        var typedLinks: [String: String] = [:]
        for case let link as String in input["typedLinks"] as! [Any] {
            typedLinks[link] = OrbitIntentInput.withScheme(link)
        }
        output["typedLinks"] = typedLinks
        for refused in ["javascript:alert(1)", "mailto:someone@example.com", "ftp://example.com/file", "steam://rungameid/1", "user:secret@example.com"] {
            precondition((try? OrbitIntentInput.webLink(URL(string: refused)!)) == nil, refused)
        }
        precondition(OrbitIntentInput.displayLink("https://example.com/watch?v=1") == "example.com/watch")
        precondition(OrbitIntentInput.delayPhrase(60) == "1 minute" && OrbitIntentInput.delayPhrase(90) == "90 seconds" && OrbitIntentInput.delayPhrase(600) == "10 minutes")
        precondition(OrbitIntentInput.powerAfterDelay == 30...600)

        // Request bodies and the agent names the actions use.
        let body = try JSONEncoder().encode(OrbitPowerAfterRequest(action: OrbitPCPowerAfterAction.shutdown.rawValue, delaySeconds: 90))
        output["powerAfter"] = try JSONSerialization.jsonObject(with: body)
        output["actions"] = ["lock", "mute"] + OrbitPCMediaAction.allCases.map(\.agentAction)
        output["powerAfterActions"] = OrbitPCPowerAfterAction.allCases.map(\.rawValue)
        output["readings"] = OrbitPCReading.allCases.map(\.rawValue)

        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='orbit-intents-check-') as directory:
    root = Path(directory)
    (root / 'input.json').write_text(json.dumps(fixtures, allow_nan=False))
    (root / 'Driver.swift').write_text(DRIVER)
    binary = root / 'check'
    subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'Orbit-iOS/Shared/OrbitIntentModels.swift'),
                    str(root / 'Driver.swift'), '-o', str(binary)], check=True)
    result = json.loads(subprocess.run([str(binary), str(root / 'input.json')], check=True,
                                       stdout=subprocess.PIPE, text=True).stdout)

mismatched = {link: (result['links'][link], python_links[link]) for link in LINKS if result['links'][link] != python_links[link]}
assert not mismatched, f'Swift and orbit_links disagree (swift, python): {mismatched}'
assert result['typed'] == python_typed, (result['typed'], python_typed)
assert result['clipboard'] == python_clipboard, (result['clipboard'], python_clipboard)
assert result['powerAfter'] == {'trigger': 'downloads', 'action': 'shutdown', 'delaySeconds': 90, 'taskID': None}, result['powerAfter']
assert set(result['actions']) <= agent.ACTIONS, set(result['actions']) - agent.ACTIONS
assert not set(result['actions']) & agent.POWER_ACTIONS
assert set(result['powerAfterActions']) <= agent.POWER_ACTIONS
for feature in ('openUrl', 'powerAfter', 'downloads'):
    assert feature in orbit_capabilities.KNOWN_FEATURES, feature
assert 'openUrl' in result['features'], result['features']
assert len(result['readings']) == 9
assert result['typedLinks'] == TYPED_LINKS, {k: v for k, v in result['typedLinks'].items() if TYPED_LINKS[k] != v}
for typed, link in TYPED_LINKS.items():
    accepted = True
    try:
        orbit_links.validate_url(link)
    except ValueError:
        accepted = False
    # Everything Swift turns into an https link is a link the agent opens; the rest stays refused.
    assert accepted == link.startswith('https://'), (typed, link, accepted)

# Sleep PC When Downloads Finish vs the agent's rule (orbit_downloads / orbit_power_after, DESIGN F1): the
# real PowerAfter and DownloadsWatcher with one pretend launcher, as the sentences above describe them.
# Those modules arrive with the F1 agent work; until they're in this checkout only the Swift side runs.
try:
    import orbit_downloads
    import orbit_power_after
except ImportError:
    power_after_note = 'power-after timing (F1 agent modules not in this checkout, skipped)'
else:
    assert set(result['downloadsActiveStates']) == set(orbit_downloads.ACTIVE_STATES), orbit_downloads.ACTIVE_STATES
    assert 'paused' not in orbit_downloads.ACTIVE_STATES
    assert result['downloadsQuietSeconds'] == orbit_power_after.DOWNLOADS_QUIET_SECONDS
    import types
    from unittest.mock import MagicMock

    def power_after_machine(observations):
        """A PowerAfter whose downloads come from `observations` ({id: state}); `perform` only records."""
        clock = [1000.0]
        done = []
        launcher = types.SimpleNamespace(present=lambda: True, scan=lambda tracked: [
            orbit_downloads.Observation(ident, 'steam', ident, 'complete' if state == 'finished' else state, 0.5, 5, 10)
            for ident, state in observations.items()])
        watcher = orbit_downloads.DownloadsWatcher(monotonic=lambda: clock[0], clock=lambda: clock[0], emit=MagicMock(),
                                                   scanners={'steam': launcher})
        watcher.poll()
        machine = orbit_power_after.PowerAfter(perform=done.append, downloads=lambda: watcher, emit=MagicMock(),
                                               monotonic=lambda: clock[0], clock=lambda: clock[0], idle_seconds=lambda: None)

        def advance(seconds):
            results = []
            for _ in range(int(seconds)):
                clock[0] += 1
                watcher.poll()
                results.append(machine.tick())
            return [r for r in results if r]
        def change(ident, state):
            observations[ident] = state
            watcher.poll()  # the launcher reports the change now; then time runs
        return machine, change, advance, done

    # One active download and one paused before the rule ("about 2 minutes after its download finishes",
    # "paused downloads don't count").
    machine, change, advance, done = power_after_machine({'steam:620': 'downloading', 'epic:1': 'paused'})
    machine.set_rule({'trigger': 'downloads', 'action': 'sleep', 'delaySeconds': 60, 'taskID': None})
    assert advance(600) == [] and done == []  # still downloading
    change('steam:620', 'finished')
    assert advance(orbit_power_after.DOWNLOADS_QUIET_SECONDS - 1) == []
    assert advance(1) == ['scheduled']
    assert advance(59) == [] and advance(1) == ['executed'] and done == ['sleep'], done

    # Nothing active, only a paused download ("waits for the next download", "count once you resume them").
    machine, change, advance, done = power_after_machine({'epic:1': 'paused'})
    machine.set_rule({'trigger': 'downloads', 'action': 'shutdown', 'delaySeconds': 60, 'taskID': None})
    assert advance(3600) == [] and done == [], 'a rule set while nothing downloads must wait for a download'
    change('epic:1', 'downloading')  # resumed
    assert advance(120) == []
    change('epic:1', 'finished')
    assert advance(59) == [] and advance(1) == ['scheduled']
    assert advance(60) == ['executed'] and done == ['shutdown'], done
    power_after_note = 'power-after timing matches orbit_power_after (active, paused and idle cases)'

print(f"PASS: Shortcuts actions vs agent: status/readings ({len(result['readings'])} readings, units, missing, stale and "
      f"invalid sensors), status sentences, Sunshine list, {len(result['errors'])} error replies, {len(LINKS)} links match "
      f"orbit_links, {len(TYPED_LINKS)} typed addresses, typed text and clipboard limits match the agent, power-after "
      f"body and {len(result['powerAfterSentences'])} downloads sentences, action names; {power_after_note}")
