import SwiftUI

// Shared by the watch app and its complications (targets OrbitWatch and OrbitWatchWidgets).

/// The watch summary as the shared Orbit telemetry, so the takeaway, the colors and the
/// readings say exactly what the iPhone says. Readings the summary does not carry stay empty.
struct WatchTelemetry: OrbitTelemetry, Equatable {
    var isOnline = false
    var cpuUsage: Double = 0
    var cpuTemp: Double?
    var gpuUsage: Double?
    var gpuTemp: Double?
    var gpuPowerWatts: Double?
    var cpuPowerWatts: Double?
    var ramUsedGB: Double = 0
    var ramTotalGB: Double = 0
    var uptimeSeconds = 0
    var activeGame: String?
    var fps: Double?
    var telemetryAvailable: Bool?
    var sessionLocked: Bool?

    var cpuClockMHz: Double? { nil }
    var liquidTemp: Double? { nil }
    var cpuFanRPM: Double? { nil }
    var gpuFanPercent: Double? { nil }
    var diskReadMBps: Double? { nil }
    var diskWriteMBps: Double? { nil }
    var networkUploadMBps: Double? { nil }
    var networkDownloadMBps: Double? { nil }
    var vramUsedGB: Double? { nil }
    var vramTotalGB: Double? { nil }
    var ssdUsedTB: Double { 0 }
    var ssdTotalTB: Double { 0 }

    /// The running game's name, if one runs.
    var game: String? {
        guard let name = activeGame?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Hot enough that the takeaway says so (the same thresholds as `OrbitTakeaway`).
    var isHot: Bool {
        (cpuTemp ?? 0) >= 90 || (gpuTemp ?? 0) >= 85
    }

    /// The takeaway headline; while a game runs and nothing needs attention, the game's name.
    var headline: String {
        let takeaway = OrbitTakeaway(self).headline
        if takeaway == "In game", let game { return game }
        return takeaway
    }
}

/// The readings worth a glance at the wrist, labeled in plain words.
enum WatchVitals {
    /// Two readings: the frame rate and the graphics card while a game runs, otherwise the
    /// processor and the graphics card. Temperatures when the PC reports them, load otherwise.
    static func glance(_ telemetry: WatchTelemetry) -> [OrbitVital] {
        let processor = processor(telemetry)
        let graphics = graphics(telemetry)
        if telemetry.game != nil, let frameRate = frameRate(telemetry) {
            return [frameRate, graphics ?? processor]
        }
        if let graphics { return [processor, graphics] }
        if let memory = memory(telemetry) { return [processor, memory] }
        return [processor]
    }

    /// Processor temperature, or its load when the PC has no temperature sensor.
    static func processor(_ telemetry: WatchTelemetry) -> OrbitVital {
        let hasTemperature = telemetry.cpuTemp.map { $0.isFinite && $0 > 0 } ?? false
        return labeled(OrbitVital(hasTemperature ? .cpuTemperature : .cpuLoad, metrics: telemetry), "Processor")
    }

    /// Graphics temperature, or its load; nil when the PC reports neither.
    static func graphics(_ telemetry: WatchTelemetry) -> OrbitVital? {
        if let temperature = telemetry.gpuTemp, temperature.isFinite, temperature > 0 {
            return labeled(OrbitVital(.gpuTemperature, metrics: telemetry), "Graphics")
        }
        guard telemetry.gpuUsage?.isFinite == true else { return nil }
        return labeled(OrbitVital(.gpuLoad, metrics: telemetry), "Graphics")
    }

    static func frameRate(_ telemetry: WatchTelemetry) -> OrbitVital? {
        let vital = OrbitVital(.fps, metrics: telemetry)
        return vital.value == nil ? nil : labeled(vital, "Frame Rate")
    }

    static func memory(_ telemetry: WatchTelemetry) -> OrbitVital? {
        guard telemetry.ramTotalGB > 0 else { return nil }
        return labeled(OrbitVital(.memory, metrics: telemetry), "Memory")
    }

    private static func labeled(_ vital: OrbitVital, _ label: String) -> OrbitVital {
        var vital = vital
        vital.label = label
        return vital
    }
}

/// Where the PC stands, in the words both the app and the complications use.
enum WatchPCStatus: Equatable {
    case setup, connecting, waking, online, locked, offline

    var markStatus: OrbitMark.Status {
        switch self {
        case .setup: return .plain
        case .connecting, .waking: return .working
        case .online: return .online
        case .locked: return .locked
        case .offline: return .offline
        }
    }

    var title: String {
        switch self {
        case .setup: return "No PC yet"
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        case .online: return "Online"
        case .locked: return "Locked"
        case .offline: return "Asleep or off"
        }
    }
}

extension Color {
    /// A 6-digit hex color such as "0A84FF" or "#0A84FF"; nil for anything else.
    init?(orbitHex: String) {
        var text = orbitHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
