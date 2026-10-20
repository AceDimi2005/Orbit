import ActivityKit
import AppIntents
import Foundation

/// Shared by the app and its WidgetKit extension. No shared container is needed:
/// ActivityKit delivers this small snapshot to the system-owned presentation.
struct OrbitActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var cpuUsage: Double?
        var gpuUsage: Double?
        var ramUsage: Double?
        var fps: Double?
        var gameName: String?
        var isConnected: Bool
        var lastUpdated: Date
        var vramUsedGB: Double? = nil
        var vramTotalGB: Double? = nil
        var cpuPowerWatts: Double? = nil
        var gpuPowerWatts: Double? = nil
        var focus: String? = nil
        var telemetryAvailable: Bool? = nil
        var style: String? = nil
        var primaryMetric: String? = nil
        var accent: String? = nil
        var showGame: Bool? = nil
        var showTimestamp: Bool? = nil
        var updateInterval: Int? = nil
        var isPaused: Bool? = nil
        var cpuTemp: Double? = nil
        var gpuTemp: Double? = nil
    }

    var pcName: String
}

/// App-local preferences are copied into ActivityKit content. The extension does
/// not need to read the app's defaults to render the selected appearance.
struct OrbitActivityPreferences: Equatable {
    var style: String
    var primaryMetric: String
    var accent: String
    var showGame: Bool
    var showTimestamp: Bool
    var interval: Int
    init(defaults: UserDefaults = .standard) {
        let style = defaults.string(forKey: "orbit.activity.style") ?? "standard"
        self.style = ["standard", "minimal", "detailed"].contains(style) ? style : "standard"
        let metric = defaults.string(forKey: "orbit.activity.primaryMetric") ?? "automatic"
        primaryMetric = ["automatic", "cpu", "gpu", "ram", "fps", "cpuPower", "gpuPower", "vram"].contains(metric) ? metric : "automatic"
        let accent = defaults.string(forKey: "orbit.activity.accent") ?? "noir"
        let knownAccents = ["noir", "ocean", "aurora", "violet", "ember", "graphite", "cyberpunk", "solarGold", "crimson", "matrix", "arctic", "sakura"]
        self.accent = knownAccents.contains(accent) ? accent : "noir"
        showGame = defaults.object(forKey: "orbit.activity.showGame") as? Bool ?? true
        showTimestamp = defaults.object(forKey: "orbit.activity.showTimestamp") as? Bool ?? true
        let interval = defaults.integer(forKey: "orbit.activity.interval")
        self.interval = [5, 10, 15].contains(interval) ? interval : 5
    }
    var staleInterval: TimeInterval { TimeInterval(max(15, interval * 3)) }
}

struct StopOrbitLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Orbit Live Activity"
    static var description = IntentDescription("Remove the current Orbit monitoring activity from the Lock Screen and Dynamic Island.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        for activity in Activity<OrbitActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
