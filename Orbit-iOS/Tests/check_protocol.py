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
    payloads["legacy"] = legacy
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
precondition(legacy.fps == nil && legacy.volumeAvailable == nil)
let specs = try decode(PCSpecs.self, "specs")
precondition(specs.gpus.first?.vramGB == 32)
precondition(specs.motherboard.model == nil && specs.coolerName == nil)
let games = try decode([SunshineGame].self, "games")
precondition(games.count == 1 && games[0].cmd == nil)
print("PASS: agent/Swift contract, nullable sensors, legacy optional fields, full specs, Sunshine library")
''')
    binary = temporary / "protocol-check"
    subprocess.run(["swiftc", str(temporary / "Models.swift"), str(temporary / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temporary)], check=True)
