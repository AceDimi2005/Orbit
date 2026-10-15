"""Decode real agent payload shapes with the production Swift data models.

Run with the Windows agent's development Python environment on macOS (Swift required).
No agent server, hardware commands, or network connections are started.
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
import orbit_agent
from orbit_hardware import basic_specs

source = (ROOT / "Orbit-iOS/Orbit/ModelsAndServices.swift").read_text()
models = "import Foundation\n" + source.split("struct PCMetrics: Codable", 1)[1].split("final class WakeOnLANService", 1)[0]
models = models.replace("import Foundation\n", "import Foundation\nstruct PCMetrics: Codable", 1)

with tempfile.TemporaryDirectory(prefix="orbit-protocol-") as directory:
    temporary = Path(directory)
    status = copy.deepcopy(orbit_agent.STATE)
    specs = basic_specs()
    specs["gpus"] = [{"name": "Test GPU", "driverVersion": None, "vramGB": 32}]
    payloads = {"status": status, "specs": specs, "games": [{"id": "1", "title": "Test game", "genre": "Sunshine library", "iconSymbol": "gamecontroller.fill", "accentHex": "#57C8FF", "isFavorite": False}]}
    legacy = copy.deepcopy(status)
    for key in ("fps", "fpsSource", "fpsUnavailableReason", "activeGameProcess", "lastUpdated", "volumeAvailable", "telemetryAvailable"):
        legacy.pop(key)
    for key in ("cpuPowerWatts", "cpuClockMHz", "cpuClockSource", "cpuFanRPM", "gpuFanPercent", "diskReadMBps", "diskWriteMBps", "networkUploadMBps", "networkDownloadMBps"):
        legacy.pop(key, None)
    payloads["legacy"] = legacy
    extended = copy.deepcopy(status)
    extended.update(cpuPowerWatts=62.5, gpuPowerWatts=210, cpuClockMHz=4200, cpuClockSource="System · nominal clock",
                    cpuFanRPM=900, gpuFanPercent=40, diskReadMBps=25.4, diskWriteMBps=5.2, networkDownloadMBps=8.1, networkUploadMBps=1.3)
    payloads["extended"] = extended
    payloads["processes"] = {"processes": [{"pid": 42, "name": "Example.exe", "createTime": 1234567.125,
                                          "memoryMB": 250, "cpuPercent": None, "status": "running", "canTerminate": True}],
                             "capturedAt": 1234568, "totalCount": 1}
    for name, payload in payloads.items():
        (temporary / f"{name}.json").write_text(json.dumps(payload, allow_nan=False))
    (temporary / "Models.swift").write_text(models)
    (temporary / "main.swift").write_text(r'''
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
}
let status = try decode(PCMetrics.self, "status")
precondition(status.cpuTemp == nil && status.fps == nil && status.hdrEnabled == nil)
precondition(status.volumeAvailable == false && status.telemetryAvailable == false)
let legacy = try decode(PCMetrics.self, "legacy")
precondition(legacy.fps == nil && legacy.volumeAvailable == nil && legacy.cpuPowerWatts == nil && legacy.networkDownloadMBps == nil)
let extended = try decode(PCMetrics.self, "extended")
precondition(extended.cpuPowerWatts == 62.5 && extended.cpuClockMHz == 4200 && extended.diskReadMBps == 25.4)
precondition(extended.cpuClockSource == "System · nominal clock" && extended.networkUploadMBps == 1.3)
let processes = try decode(PCProcessList.self, "processes")
precondition(processes.processes.first?.createTime == 1234567.125 && processes.processes.first?.originGeneration == nil)
let specs = try decode(PCSpecs.self, "specs")
precondition(specs.gpus.first?.vramGB == 32)
precondition(specs.motherboard.model == nil && specs.coolerName == nil)
let games = try decode([SunshineGame].self, "games")
precondition(games.count == 1 && games[0].cmd == nil)
print("PASS: agent/Swift contract, nullable sensors, legacy optional fields, extended telemetry, process identities, full specs, Sunshine library")
''')
    binary = temporary / "protocol-check"
    subprocess.run(["swiftc", str(temporary / "Models.swift"), str(temporary / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temporary)], check=True)
