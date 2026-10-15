"""Validate real read-only agent JSON with the production widget snapshot model.

Uses only mocked agent state. Does not start a server or access a physical PC.
"""
import copy
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Orbit-Windows-Agent'))
import orbit_agent as agent

source = (ROOT / 'Orbit-iOS/OrbitWidgets/OrbitTelemetryWidgets.swift').read_text()
enum_body = source.split('enum OrbitWidgetMetric: String, AppEnum {', 1)[1].split('    static var', 1)[0]
assert re.search(r'case .*cpuUsage', enum_body)
model = source.split('private struct OrbitWidgetSnapshot: Decodable {', 1)[1].split('private struct OrbitPCWidgetEntry:', 1)[0]
model = 'private struct OrbitWidgetSnapshot: Decodable {' + model
swift_source = 'import Foundation\nenum OrbitWidgetMetric: String, CaseIterable {' + enum_body + '}\n' + model
state = copy.deepcopy(agent.STATE)
state.update(telemetryAvailable=True, lastUpdated='2025-01-01T00:00:00+00:00', cpuUsage=45, gpuUsage=80,
             ramUsedGB=16, ramTotalGB=32, vramUsedGB=6, vramTotalGB=12, cpuPowerWatts=62.5,
             gpuPowerWatts=210, cpuClockMHz=4250, cpuFanRPM=900, gpuFanPercent=42, cpuTemp=52,
             gpuTemp=65, liquidTemp=31, diskReadMBps=12.5, diskWriteMBps=4.5,
             networkDownloadMBps=1.3, networkUploadMBps=0.2, fps=144, activeGame='Example')
with patch.object(agent, 'WIDGET_TOKEN', 'test-read-only-widget-token'), patch.object(agent, 'STATE', state), \
     patch.object(agent, 'LAST_TELEMETRY', time.monotonic()), patch.object(agent, 'LAST_SENSOR', time.monotonic()):
    snapshot = agent.widget_status('Bearer test-read-only-widget-token')
with tempfile.TemporaryDirectory(prefix='orbit-widget-contract-') as directory:
    root = Path(directory)
    (root / 'snapshot.json').write_text(json.dumps(snapshot, allow_nan=False))
    test = r'''
@main struct WidgetContractTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let snapshot = try JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data)
        precondition(snapshot.measuredAt?.timeIntervalSince1970 == 1735689600)
        precondition(snapshot.value(.vramUsage) == 50 && snapshot.value(.ramUsage) == 50)
        precondition(snapshot.formatted(.cpuPower) == "63 W" && snapshot.formatted(.gpuFan) == "42%")
        precondition(snapshot.value(.cpuClock) == 4250 && snapshot.value(.networkUpload) == 0.2)
        precondition(snapshot.value(.fps) == 144 && snapshot.gameName == "Example")
        for metric in OrbitWidgetMetric.allCases { precondition(snapshot.value(metric) != nil, "Missing mapping: \(metric)") }
        let invalid = try JSONDecoder().decode(OrbitWidgetSnapshot.self, from: Data(#"{"timestamp":1e300,"cpu_power":1e300,"cpu_usage":200,"vram_used":4,"vram_total":0,"gpu_fan":-1}"#.utf8))
        precondition(invalid.measuredAt == nil && invalid.formatted(.cpuPower) == "—")
        precondition(invalid.value(.cpuUsage) == nil && invalid.value(.vramUsage) == nil && invalid.value(.gpuFan) == nil)
        let empty = try JSONDecoder().decode(OrbitWidgetSnapshot.self, from: Data("{}".utf8))
        precondition(empty.measuredAt == nil && empty.formatted(.fps) == "—")
        print("PASS: widget/agent JSON contract, 18 metric mappings, VRAM ratios, units, original timestamp, missing and invalid sensors")
    }
}
'''
    (root / 'Tests.swift').write_text(swift_source + test)
    binary = root / 'check'
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'Tests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'snapshot.json')], check=True)
