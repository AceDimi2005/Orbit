import SwiftUI

/// The readings every Orbit app gets from `/api/status`. iPhone, Mac and Apple TV each
/// decode their own struct; they all conform, so readings are presented the same way.
protocol OrbitTelemetry {
    var isOnline: Bool { get }
    var cpuUsage: Double { get }
    var cpuTemp: Double? { get }
    var gpuUsage: Double? { get }
    var gpuTemp: Double? { get }
    var gpuPowerWatts: Double? { get }
    var cpuPowerWatts: Double? { get }
    var cpuClockMHz: Double? { get }
    var cpuClockSource: String? { get }
    var liquidTemp: Double? { get }
    var cpuFanRPM: Double? { get }
    var gpuFanPercent: Double? { get }
    var diskReadMBps: Double? { get }
    var diskWriteMBps: Double? { get }
    var networkUploadMBps: Double? { get }
    var networkDownloadMBps: Double? { get }
    var vramUsedGB: Double? { get }
    var vramTotalGB: Double? { get }
    var ramUsedGB: Double { get }
    var ramTotalGB: Double { get }
    var ssdUsedTB: Double { get }
    var ssdTotalTB: Double { get }
    var uptimeSeconds: Int { get }
    var activeGame: String? { get }
    var fps: Double? { get }
    var fpsUnavailableReason: String? { get }
    var telemetryAvailable: Bool? { get }
    var sessionLocked: Bool? { get }
}

extension OrbitTelemetry {
    var cpuClockSource: String? { nil }
    var fpsUnavailableReason: String? { nil }
}

/// Every reading a PC tab can show. Raw values match the apps' own metric enums.
enum OrbitVitalKind: String, CaseIterable, Identifiable {
    case cpuLoad, gpuLoad, memory, storage, vram, cpuPower, gpuPower
    case cpuTemperature, gpuTemperature, coolantTemperature, cpuClock
    case network, diskActivity, uptime, fps, cpuFan, gpuFan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuLoad: return "Processor"
        case .gpuLoad: return "Graphics"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .vram: return "Video Memory"
        case .cpuPower: return "CPU Power"
        case .gpuPower: return "GPU Power"
        case .cpuTemperature: return "CPU Temperature"
        case .gpuTemperature: return "GPU Temperature"
        case .coolantTemperature: return "Coolant"
        case .cpuClock: return "CPU Clock"
        case .network: return "Network"
        case .diskActivity: return "Disk"
        case .uptime: return "Uptime"
        case .fps: return "Frame Rate"
        case .cpuFan: return "CPU Fan"
        case .gpuFan: return "GPU Fan"
        }
    }
}

/// One reading, ready to draw: label, value and unit, a detail line, a 0…1 fraction for
/// meters, the color its state deserves and recent history for sparklines.
struct OrbitVital {
    var kind: OrbitVitalKind
    var label: String
    var value: String?
    var unit: String?
    var detail: String?
    var fraction: Double?
    var color: Color = .primary
    var history: [Double] = []
    var historyRange: ClosedRange<Double>? = nil

    /// A reading the PC actually reports (or reported recently).
    var hasData: Bool { value != nil || history.contains(where: \.isFinite) }

    init(_ kind: OrbitVitalKind, metrics m: some OrbitTelemetry, history: [Double] = []) {
        self.kind = kind
        label = kind.title
        self.history = history
        switch kind {
        case .cpuLoad:
            value = OrbitFormat.percent(m.cpuUsage); unit = "%"
            fraction = m.cpuUsage / 100
            color = OrbitPalette.load(fraction)
            detail = Self.join([OrbitFormat.temperature(m.cpuTemp), m.cpuClockMHz.flatMap(Self.gigahertz)])
            historyRange = 0...100
        case .gpuLoad:
            value = OrbitFormat.percent(m.gpuUsage); unit = "%"
            fraction = m.gpuUsage.map { $0 / 100 }
            color = OrbitPalette.load(fraction)
            detail = Self.join([OrbitFormat.temperature(m.gpuTemp), OrbitFormat.watts(m.gpuPowerWatts)])
            historyRange = 0...100
        case .memory:
            value = m.ramTotalGB > 0 ? OrbitFormat.gigabytes(m.ramUsedGB) : nil; unit = "GB"
            fraction = m.ramTotalGB > 0 ? m.ramUsedGB / m.ramTotalGB : nil
            color = OrbitPalette.load(fraction)
            detail = m.ramTotalGB > 0 ? "of \(OrbitFormat.gigabytes(m.ramTotalGB, digits: 0) ?? "") GB" : nil
        case .storage:
            value = m.ssdTotalTB > 0 ? OrbitFormat.gigabytes(m.ssdUsedTB, digits: 2) : nil; unit = "TB"
            fraction = m.ssdTotalTB > 0 ? m.ssdUsedTB / m.ssdTotalTB : nil
            color = OrbitPalette.load(fraction)
            detail = m.ssdTotalTB > 0 ? "of \(OrbitFormat.gigabytes(m.ssdTotalTB, digits: 2) ?? "") TB" : nil
        case .vram:
            value = OrbitFormat.gigabytes(m.vramUsedGB); unit = "GB"
            if let used = m.vramUsedGB, let total = m.vramTotalGB, total > 0 {
                fraction = used / total
                detail = "of \(OrbitFormat.gigabytes(total, digits: 0) ?? "") GB"
            }
            color = OrbitPalette.load(fraction)
        case .cpuPower:
            value = Self.whole(m.cpuPowerWatts); unit = "W"
            detail = "Processor package"
        case .gpuPower:
            value = Self.whole(m.gpuPowerWatts); unit = "W"
            detail = "Graphics card"
        case .cpuTemperature:
            value = OrbitFormat.temperature(m.cpuTemp)
            fraction = m.cpuTemp.map { $0 / 100 }
            color = OrbitPalette.temperature(m.cpuTemp)
            historyRange = 20...100
        case .gpuTemperature:
            value = OrbitFormat.temperature(m.gpuTemp)
            fraction = m.gpuTemp.map { $0 / 100 }
            color = OrbitPalette.temperature(m.gpuTemp)
            historyRange = 20...100
        case .coolantTemperature:
            value = OrbitFormat.temperature(m.liquidTemp)
            detail = "Liquid loop"
        case .cpuClock:
            value = m.cpuClockMHz.flatMap { $0.isFinite && $0 > 0 ? ($0 / 1000).formatted(.number.precision(.fractionLength(2))) : nil }
            unit = "GHz"
            detail = m.cpuClockSource
        case .network:
            (value, unit) = Self.rate(m.networkDownloadMBps)
            detail = OrbitFormat.rate(m.networkUploadMBps).map { "Sending \($0)" }
        case .diskActivity:
            (value, unit) = Self.rate(m.diskReadMBps)
            detail = OrbitFormat.rate(m.diskWriteMBps).map { "Writing \($0)" }
        case .uptime:
            value = m.uptimeSeconds > 0 ? OrbitFormat.duration(seconds: m.uptimeSeconds) : nil
            detail = "Since the last restart"
        case .fps:
            value = Self.whole(m.fps.flatMap { $0 > 0 ? $0 : nil }); unit = "fps"
            detail = m.activeGame ?? m.fpsUnavailableReason
        case .cpuFan:
            value = Self.whole(m.cpuFanRPM); unit = "rpm"
        case .gpuFan:
            value = OrbitFormat.percent(m.gpuFanPercent); unit = "%"
            fraction = m.gpuFanPercent.map { $0 / 100 }
        }
    }

    private static func whole(_ value: Double?) -> String? {
        value.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }
    }

    private static func join(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private static func gigahertz(_ mhz: Double) -> String? {
        guard mhz.isFinite, mhz > 0 else { return nil }
        return (mhz / 1000).formatted(.number.precision(.fractionLength(2))) + " GHz"
    }

    private static func rate(_ megabytesPerSecond: Double?) -> (String?, String?) {
        guard let value = megabytesPerSecond, value.isFinite, value >= 0 else { return (nil, nil) }
        if value >= 1 { return (value.formatted(.number.precision(.fractionLength(1))), "MB/s") }
        return ((value * 1000).formatted(.number.precision(.fractionLength(0))), "KB/s")
    }
}

/// One sentence about how the PC is doing, from the readings that matter most.
struct OrbitTakeaway {
    var headline: String

    init(_ m: some OrbitTelemetry) {
        if let temp = m.cpuTemp, temp >= 90 { headline = "Processor is hot · \(Int(temp))°"; return }
        if let temp = m.gpuTemp, temp >= 85 { headline = "Graphics card is hot · \(Int(temp))°"; return }
        if m.cpuUsage >= 85 { headline = "Processor is busy · \(Int(m.cpuUsage))%"; return }
        if let gpu = m.gpuUsage, gpu >= 90, m.activeGame == nil { headline = "Graphics card is busy · \(Int(gpu))%"; return }
        if m.ramTotalGB > 0, m.ramUsedGB / m.ramTotalGB >= 0.9 { headline = "Memory is almost full"; return }
        if let game = m.activeGame, !game.isEmpty { headline = "In game"; return }
        if let cpu = m.cpuTemp, cpu < 65, (m.gpuTemp ?? 0) < 65, m.cpuUsage < 30 { headline = "Running cool and quiet"; return }
        headline = m.cpuUsage < 30 ? "Quiet right now" : "Running smoothly"
    }
}
