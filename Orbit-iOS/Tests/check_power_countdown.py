"""Check Windows' 30-second warning after Shut Down or Restart, end to end between the agent and Swift.

The agent's real routes run in-process (FastAPI TestClient) with shutdown.exe replaced by a fake that
answers like Windows; nothing shuts down, and no server or PC is involved. Their JSON is then read by
`Shared/OrbitPowerCountdown.swift` and the status models of the Watch, the Mac and Apple TV (sliced
out of their sources), and the tracker every app uses is put through late answers, cancels from another
device and the end of the countdown.

Run with the venv python (needs fastapi and httpx): python3 Orbit-iOS/Tests/check_power_countdown.py
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Orbit-Windows-Agent"))
import orbit_agent as agent  # noqa: E402
import orbit_power_countdown as countdown  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

TOKEN = "check-power-countdown-token-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class FakeShutdown:
    """shutdown.exe as Windows answers: one countdown at a time, `/a` with nothing pending is 1116."""

    def __init__(self):
        self.calls = []
        self.pending = False

    def __call__(self, arguments):
        self.calls.append(arguments)
        if arguments[1] == "/a":
            if not self.pending:
                return countdown.ERROR_NO_SHUTDOWN_IN_PROGRESS
            self.pending = False
            return 0
        if self.pending:
            return countdown.ERROR_SHUTDOWN_IS_SCHEDULED
        self.pending = True
        return 0


windows = FakeShutdown()
replies = {}
with patch.object(agent, "API_TOKEN", TOKEN), patch.object(agent, "require_windows"), \
        patch.object(agent, "POWER_COUNTDOWN", countdown.PowerCountdown(runner=windows)), \
        patch.object(agent, "BEFORE_POWER_HOOKS", []), patch.object(agent, "POWER_CANCELLED_HOOKS", []), \
        patch.object(agent.ctypes, "windll", MagicMock(), create=True), patch.object(agent.subprocess, "run"):
    client = TestClient(agent.app)
    features = client.get("/api/capabilities", headers=AUTH).json()["features"]
    assert "powerCountdown" in features, features
    replies["shutdown"] = client.post("/api/action/shutdown", headers=AUTH).json()
    replies["status"] = client.get("/api/status", headers=AUTH).json()
    replies["watch"] = client.get("/api/watch/summary", headers=AUTH).json()
    replies["cancel"] = client.post("/api/power/cancel", headers=AUTH).json()
    replies["idleStatus"] = client.get("/api/status", headers=AUTH).json()
    replies["idleWatch"] = client.get("/api/watch/summary", headers=AUTH).json()
    nothing = client.post("/api/power/cancel", headers=AUTH)
    assert nothing.status_code == 409, nothing.status_code
    replies["nothing"] = nothing.json()
    replies["restart"] = client.post("/api/action/restart", headers=AUTH).json()
    replies["sleep"] = client.post("/api/action/sleep", headers=AUTH).json()
    client.post("/api/power/cancel", headers=AUTH)
    client.close()

assert replies["shutdown"] == {"status": "sent", "executed": "shutdown", "countdownSeconds": 30}, replies["shutdown"]
assert replies["status"]["powerCountdown"]["action"] == "shutdown", replies["status"]["powerCountdown"]
assert replies["cancel"] == {"status": "cancelled", "action": "shutdown"}, replies["cancel"]
assert replies["idleStatus"]["powerCountdown"] is None and replies["idleWatch"]["powerCountdown"] is None
assert replies["sleep"] == {"status": "sent", "executed": "sleep"}, replies["sleep"]
assert windows.calls[0] == ["shutdown", "/s", "/t", "30", "/c", countdown.shutdown_comment("shutdown")], windows.calls
# What an agent without the countdown answers to Shut Down.
replies["legacy"] = {"status": "sent", "executed": "shutdown"}

watch_source = (ROOT / "Orbit-iOS/OrbitWatch/OrbitWatchViewModel.swift").read_text(encoding="utf-8")
start = watch_source.index("struct WatchSummaryResponse: Decodable {")
watch_summary = watch_source[start:watch_source.index("\n}\n", start) + 3]
mac_source = (ROOT / "Orbit-iOS/OrbitMac/OrbitMacModels.swift").read_text(encoding="utf-8")
start = mac_source.index("struct MacPCMetrics: Codable {")
mac_metrics = mac_source[start:mac_source.index("\n}\n", start) + 3]
tv_source = (ROOT / "Orbit-iOS/OrbitTV/OrbitTVViewModel.swift").read_text(encoding="utf-8")
start = tv_source.index("struct TVPCMetrics: Codable {")
tv_metrics = tv_source[start:tv_source.index("\n}\n", start) + 3]
assert "var powerCountdown: OrbitPowerCountdownReport?" in watch_summary
assert "var powerCountdown: OrbitPowerCountdownReport? = nil" in mac_metrics
assert "var powerCountdown: OrbitPowerCountdownReport? = nil" in tv_metrics

MAIN = r'''
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
func data(_ name: String) -> Data { try! Data(contentsOf: root.appendingPathComponent(name + ".json")) }
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL line \(line): \(message)"); exit(1) }
}
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

// The answer to Shut Down starts the countdown; older agents and other actions don't.
let started = OrbitPowerCountdown(action: "shutdown", response: data("shutdown"), receivedAt: t0)!
check(started.secondsLeft(at: t0) == 30 && started.summary(at: t0) == "Shutting down in 0:30", "start")
check(started.summary(at: at(3.2)) == "Shutting down in 0:27", "ticks down")
check(started.summary(at: at(29.9)) == "Shutting down in 0:01" && started.isRunning(at: at(29.9)), "never 0:00 while running")
check(!started.isRunning(at: at(30)) && started.summary(at: at(30)) == "Shutting down…", "ends")
check(started.detail(at: t0) == "Windows shows the same warning on the PC." && started.detail(at: at(31)) == "The PC is turning off.", "detail")
check(started.cancelTitle == "Cancel Shutdown" && started.cancelledMessage == "Shutdown cancelled" && started.symbol == "power", "words")
check(started.spokenSummary(at: at(3.2)) == "Shutting down in 27 seconds" && started.spokenSummary(at: at(29.5)) == "Shutting down in 1 second"
      && started.spokenSummary(at: at(31)) == "Shutting down now", "VoiceOver")
check(OrbitPowerCountdown(action: "shutdown", response: data("legacy")) == nil, "older agents mark the PC offline as before")
check(OrbitPowerCountdown(action: "sleep", response: data("sleep")) == nil, "sleep stays immediate")
check(OrbitPowerCountdown(action: "lock", response: data("shutdown")) == nil, "only shutdown and restart count down")
let restart = OrbitPowerCountdown(action: "restart", response: data("restart"), receivedAt: t0)!
check(restart.summary(at: t0) == "Restarting in 0:30" && restart.cancelTitle == "Cancel Restart"
      && restart.detail(at: at(31)) == "Orbit reconnects when Windows is back.", "restart")

// The PC's status, as the iPhone (PCMetrics, check_protocol), the Mac, Apple TV and the Watch decode it.
struct Status: Decodable { var powerCountdown: OrbitPowerCountdownReport? }
let status = try! JSONDecoder().decode(Status.self, from: data("status"))
let mac = try! JSONDecoder().decode(MacPCMetrics.self, from: data("status"))
let tv = try! JSONDecoder().decode(TVPCMetrics.self, from: data("status"))
let watch = try! JSONDecoder().decode(WatchSummaryResponse.self, from: data("watch"))
for report in [status.powerCountdown, mac.powerCountdown, tv.powerCountdown, watch.powerCountdown] {
    let shown = OrbitPowerCountdown(report, receivedAt: t0)
    check(shown?.action == "shutdown" && (29...30).contains(shown?.secondsLeft(at: t0) ?? 0), "status report \(String(describing: report))")
}
check(try! JSONDecoder().decode(MacPCMetrics.self, from: data("idleStatus")).powerCountdown == nil, "Mac idle")
check(try! JSONDecoder().decode(TVPCMetrics.self, from: data("idleStatus")).powerCountdown == nil, "Apple TV idle")
check(try! JSONDecoder().decode(WatchSummaryResponse.self, from: data("idleWatch")).powerCountdown == nil, "Watch idle")
// The Watch's fallback reads /api/status without a model.
let raw = try! JSONSerialization.jsonObject(with: data("status")) as! [String: Any]
check(OrbitPowerCountdown(json: raw["powerCountdown"], receivedAt: t0)?.secondsLeft(at: t0) == OrbitPowerCountdown(status.powerCountdown, receivedAt: t0)?.secondsLeft(at: t0), "fallback")
let idleRaw = try! JSONSerialization.jsonObject(with: data("idleStatus")) as! [String: Any]
check(OrbitPowerCountdown(json: idleRaw["powerCountdown"]) == nil, "fallback idle (JSON null)")
// Nonsense never becomes a countdown, and nothing counts longer than ten minutes.
check(OrbitPowerCountdown(OrbitPowerCountdownReport(action: "shutdown", remainingSeconds: -4), receivedAt: t0) == nil, "negative")
check(OrbitPowerCountdown(OrbitPowerCountdownReport(action: "hibernate", remainingSeconds: 20), receivedAt: t0) == nil, "action")
check(OrbitPowerCountdown(OrbitPowerCountdownReport(action: "restart", remainingSeconds: 1e9), receivedAt: t0)?.secondsLeft(at: t0) == 600, "clamped")

// The iPhone tells the Watch when the countdown ends, through a property list (WatchConnectivity).
let message: [String: Any] = ["type": "stateSync", "powerCountdown": started.relayPayload]
let wire = try! PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0)
let received = try! PropertyListSerialization.propertyList(from: wire, format: nil) as! [String: Any]
check(OrbitPowerCountdown(relay: received["powerCountdown"]) == started, "relay round trip")
check(OrbitPowerCountdown(relay: nil) == nil && OrbitPowerCountdown(relay: ["action": "sleep", "until": 1.0]) == nil, "relay junk")

// The tracker every app uses.
var tracker = OrbitPowerCountdownTracker()
tracker.set(started, at: t0)
// A status answer to a request that left before Shut Down doesn't know about it yet.
tracker.apply(nil, requestedAt: at(-1), receivedAt: at(0.5))
check(tracker.running(at: at(1)) == started, "a late answer from before the action is ignored")
// The PC's own count, within a second and a half, doesn't make the seconds jump.
tracker.apply(OrbitPowerCountdown(action: "shutdown", until: at(30.8)), requestedAt: at(2), receivedAt: at(2.1))
check(tracker.countdown?.until == started.until, "close enough keeps the device's count")
tracker.apply(OrbitPowerCountdown(action: "shutdown", until: at(26)), requestedAt: at(3), receivedAt: at(3.1))
check(tracker.countdown?.until == at(26), "further off follows the PC")
// Cancelled from another device: the PC stops listing it while time is left.
tracker.apply(nil, requestedAt: at(5), receivedAt: at(5.1))
check(tracker.countdown == nil && tracker.visible(at: at(5.2)) == nil, "cancelled elsewhere")
// Started from another device: it appears with the next answer.
tracker.apply(OrbitPowerCountdown(action: "restart", until: at(36)), requestedAt: at(6), receivedAt: at(6.1))
check(tracker.running(at: at(7))?.action == "restart", "started elsewhere")
// Cancel here; an answer from before the cancel still lists it, and is ignored.
tracker.set(nil, at: at(8))
tracker.apply(OrbitPowerCountdown(action: "restart", until: at(36)), requestedAt: at(7.5), receivedAt: at(8.2))
check(tracker.countdown == nil, "a late answer from before Cancel is ignored")
// At the end Windows starts shutting down and the PC stops listing it: "Shutting down…" stays.
tracker.set(started, at: t0)
tracker.apply(nil, requestedAt: at(30.2), receivedAt: at(30.4))
check(tracker.running(at: at(30.5)) == nil && tracker.visible(at: at(30.5)) == started, "finishing stays visible")
check(tracker.visible(at: at(30 + OrbitPowerCountdownTracker.finishingGrace + 0.1)) == nil, "but not for long")
// One missed answer mid-countdown keeps it; once it ended, the PC going quiet clears it.
var flaky = OrbitPowerCountdownTracker()
flaky.set(started, at: t0)
flaky.pcUnreachable(at: at(10))
check(flaky.running(at: at(10)) == started, "a missed answer keeps a running countdown")
flaky.pcUnreachable(at: at(31))
check(flaky.countdown == nil, "the PC went away at the end")
print("PASS: Shut Down and Restart answer with Windows' 30-second countdown, /api/status and /api/watch/summary report it, Cancel stops it (409 once nothing waits), older agents and sleep stay immediate, the iPhone relays the end time to the Watch, and every app's tracker ignores late answers, follows cancels and starts from other devices, and shows the end until the PC goes away")
'''

with tempfile.TemporaryDirectory(prefix="orbit-power-countdown-") as directory:
    temporary = Path(directory)
    for name, payload in replies.items():
        (temporary / f"{name}.json").write_text(json.dumps(payload), encoding="utf-8")
    (temporary / "Models.swift").write_text("import Foundation\n\n" + watch_summary + "\n" + mac_metrics + "\n" + tv_metrics, encoding="utf-8")
    (temporary / "main.swift").write_text(MAIN, encoding="utf-8")
    binary = temporary / "power-countdown-check"
    subprocess.run(["swiftc", str(ROOT / "Orbit-iOS/Shared/OrbitPowerCountdown.swift"), str(temporary / "Models.swift"),
                    str(temporary / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temporary)], check=True)
