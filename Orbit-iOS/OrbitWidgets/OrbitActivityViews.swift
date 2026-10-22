import AppIntents
import SwiftUI
import WidgetKit

// Live Activity content, shared by the widget extension (Lock Screen, Dynamic Island, Smart
// Stack) and the app (the preview in Settings), so both always draw the same thing.

/// The accent colors by their stored names. The same values as `OrbitTheme.orbitTint` in
/// the app; widgets and the Live Activity only know the name.
enum OrbitAccentPalette {
    static func color(_ name: String?) -> Color {
        switch name ?? "noir" {
        case "ocean": return Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255)
        case "aurora": return Color(red: 102 / 255, green: 212 / 255, blue: 207 / 255)
        case "violet": return Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
        case "ember": return OrbitPalette.warm
        case "graphite": return Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)
        case "cyberpunk": return Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255)
        case "solarGold": return Color(red: 230 / 255, green: 184 / 255, blue: 76 / 255)
        case "crimson": return OrbitPalette.critical
        case "matrix": return OrbitPalette.online
        case "arctic": return Color(red: 154 / 255, green: 216 / 255, blue: 255 / 255)
        case "sakura": return Color(red: 255 / 255, green: 143 / 255, blue: 183 / 255)
        default: return OrbitPalette.accent
        }
    }

    static let proNames: Set<String> = ["cyberpunk", "solarGold", "crimson", "matrix", "arctic", "sakura"]
}

// MARK: - Mark

/// The Orbit mark for widgets and the Live Activity: the ring takes the primary color and
/// the satellite takes the tint, so tinted and clear Home Screens color only the satellite.
struct OrbitWidgetMark: View {
    enum Status { case online, paused, offline, locked }

    var status: Status = .online
    var size: CGFloat = 24
    var accent: Color = OrbitPalette.accent

    var body: some View {
        ZStack {
            OrbitRingShape()
                .stroke(ringStyle, style: StrokeStyle(lineWidth: size * OrbitMarkGeometry.stroke, lineCap: .round))
            Circle()
                .fill(satelliteStyle)
                .frame(width: size * OrbitMarkGeometry.satellite * 2, height: size * OrbitMarkGeometry.satellite * 2)
                .offset(y: -size * OrbitMarkGeometry.radius)
                .widgetAccentable()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var ringStyle: Color {
        switch status {
        case .online, .locked: return .primary
        case .paused: return .primary.opacity(0.55)
        case .offline: return .primary.opacity(0.3)
        }
    }

    private var satelliteStyle: Color {
        switch status {
        case .online: return accent
        case .locked: return OrbitPalette.caution
        case .paused: return .primary.opacity(0.55)
        case .offline: return .primary.opacity(0.3)
        }
    }
}

// MARK: - Readings

/// One reading, sized for widgets and the Live Activity.
struct OrbitGlanceReading: Identifiable {
    var id: String
    var label: String
    var value: String
    var unit: String?
    /// "CPU", "GPU"… for the Dynamic Island's compact presentation; nil when the unit says it.
    var shortLabel: String? = nil
    /// 0…1 for a meter; nil when a meter would mean nothing (frame rate, watts).
    var fraction: Double?
    var color: Color = .primary
}

/// A column of readings: label, condensed number with its unit, an optional meter. Columns
/// keep their meters aligned when some readings have none.
struct OrbitGlanceReadingsRow: View {
    var readings: [OrbitGlanceReading]
    var valueSize: CGFloat = 24
    var showsMeters = true
    var accent: Color = OrbitPalette.accent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(readings) { reading in
                VStack(alignment: .leading, spacing: 3) {
                    Text(reading.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    OrbitGlanceValue(reading: reading, size: valueSize)
                    if showsMeters {
                        OrbitGlanceMeter(fraction: reading.fraction, color: reading.color, accent: accent)
                            .padding(.top, 3)
                            .opacity(reading.fraction == nil ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(reading.label) \(reading.value)\(reading.unit.map { " \($0)" } ?? "")")
            }
        }
    }
}

/// A number with its unit, condensed like the app's live readings.
struct OrbitGlanceValue: View {
    var reading: OrbitGlanceReading
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: reading.unit == "%" ? 0 : 3) {
            // Degrees sit with the number at full size, as in the app ("52°").
            Text(reading.unit == "°" ? reading.value + "°" : reading.value)
                .font(.orbitReading(size))
                .foregroundStyle(reading.color)
            if let unit = reading.unit, unit != "°" {
                Text(unit)
                    .font(.orbitReading(size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .orbitLiveNumber()
    }
}

/// A thin meter: a track and a fill that takes the tint unless the reading needs attention.
struct OrbitGlanceMeter: View {
    var fraction: Double?
    var color: Color = .primary
    var accent: Color = OrbitPalette.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                Capsule()
                    .fill(color == .primary ? accent : color)
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction ?? 0))))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Live Activity model

/// What the Live Activity shows, worked out from its content state.
struct OrbitActivitySnapshot {
    enum Style { case minimal, standard, detailed }

    var pcName: String
    var state: OrbitActivityAttributes.ContentState
    var isStale: Bool

    var accent: Color { OrbitAccentPalette.color(state.accent) }

    var style: Style {
        switch state.style {
        case "minimal": return .minimal
        case "detailed": return .detailed
        default: return .standard
        }
    }

    /// The numbers are current: connected, sensors reporting, not paused and not stale.
    var isLive: Bool { state.isConnected && state.telemetryAvailable != false && state.isPaused != true && !isStale }

    var markStatus: OrbitWidgetMark.Status {
        if !state.isConnected { return .offline }
        return isLive ? .online : .paused
    }

    var game: String? {
        guard isLive, state.showGame != false, let game = state.gameName?.trimmingCharacters(in: .whitespaces), !game.isEmpty else { return nil }
        return game
    }

    /// One sentence about the PC, like the PC tab's header.
    var headline: String {
        if !state.isConnected { return "Asleep or off" }
        if state.isPaused == true || isStale { return "Paused" }
        if state.telemetryAvailable == false { return "Waiting for readings" }
        let takeaway = OrbitTakeaway(OrbitActivityTelemetry(state: state)).headline
        if takeaway == "In game", let game { return game }
        return takeaway
    }

    var subline: String {
        if !state.isConnected { return "\(pcName) · Wake it to see its readings" }
        if state.isPaused == true || isStale { return "\(pcName) · Open Orbit to update" }
        if let game, headline != game { return "\(pcName) · \(game)" }
        return pcName
    }

    // MARK: Readings

    func reading(_ key: String) -> OrbitGlanceReading? {
        guard isLive else { return nil }
        let s = state
        switch key {
        case "cpu":
            guard let v = Self.finite(s.cpuUsage) else { return nil }
            return OrbitGlanceReading(id: key, label: "Processor", value: "\(Int(v.rounded()))", unit: "%", shortLabel: "CPU",
                                      fraction: v / 100, color: OrbitPalette.load(v / 100))
        case "gpu":
            guard let v = Self.finite(s.gpuUsage) else { return nil }
            return OrbitGlanceReading(id: key, label: "Graphics", value: "\(Int(v.rounded()))", unit: "%", shortLabel: "GPU",
                                      fraction: v / 100, color: OrbitPalette.load(v / 100))
        case "ram":
            guard let v = Self.finite(s.ramUsage) else { return nil }
            return OrbitGlanceReading(id: key, label: "Memory", value: "\(Int(v.rounded()))", unit: "%", shortLabel: "RAM",
                                      fraction: v / 100, color: OrbitPalette.load(v / 100))
        case "fps":
            guard let v = Self.finite(s.fps), v > 0 else { return nil }
            return OrbitGlanceReading(id: key, label: "Frame Rate", value: "\(Int(v.rounded()))", unit: "fps")
        case "cpuTemp":
            guard let v = Self.finite(s.cpuTemp) else { return nil }
            return OrbitGlanceReading(id: key, label: "CPU", value: "\(Int(v.rounded()))", unit: "°", shortLabel: "CPU",
                                      fraction: v / 100, color: OrbitPalette.temperature(v))
        case "gpuTemp":
            guard let v = Self.finite(s.gpuTemp) else { return nil }
            return OrbitGlanceReading(id: key, label: "GPU", value: "\(Int(v.rounded()))", unit: "°", shortLabel: "GPU",
                                      fraction: v / 100, color: OrbitPalette.temperature(v))
        case "cpuPower":
            guard let v = Self.finite(s.cpuPowerWatts) else { return nil }
            return OrbitGlanceReading(id: key, label: "CPU Power", value: "\(Int(v.rounded()))", unit: "W", shortLabel: "CPU")
        case "gpuPower":
            guard let v = Self.finite(s.gpuPowerWatts) else { return nil }
            return OrbitGlanceReading(id: key, label: "GPU Power", value: "\(Int(v.rounded()))", unit: "W", shortLabel: "GPU")
        case "vram":
            guard let v = Self.finite(s.vramUsedGB) else { return nil }
            let fraction = Self.finite(s.vramTotalGB).flatMap { $0 > 0 ? v / $0 : nil }
            return OrbitGlanceReading(id: key, label: "Video Memory", value: v.formatted(.number.precision(.fractionLength(1))), unit: "GB",
                                      shortLabel: "VRAM", fraction: fraction, color: OrbitPalette.load(fraction))
        default:
            return nil
        }
    }

    /// Three readings for the chosen focus; missing sensors are skipped, never shown as zero.
    var readings: [OrbitGlanceReading] {
        let preferred: [String]
        switch state.focus {
        case "gaming": preferred = ["fps", "gpu", "gpuTemp"]
        case "power": preferred = ["cpuPower", "gpuPower", "gpu"]
        default: preferred = ["cpu", "gpu", "ram"]
        }
        let fallback = ["cpu", "gpu", "ram", "cpuTemp", "gpuTemp", "fps", "vram"]
        var keys: [String] = []
        for key in preferred + fallback where !keys.contains(key) && reading(key) != nil {
            keys.append(key)
            if keys.count == 3 { break }
        }
        return keys.compactMap(reading)
    }

    /// Temperatures and power, for the detailed style.
    var details: String? {
        let parts = [reading("cpuTemp").map { "CPU \($0.value)°" }, reading("gpuTemp").map { "GPU \($0.value)°" },
                     reading("cpuPower").map { "\($0.value) W" }, reading("gpuPower").map { "\($0.value) W" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The reading chosen for the Dynamic Island, when not automatic.
    var chosenReading: OrbitGlanceReading? {
        guard let metric = state.primaryMetric, metric != "automatic" else { return nil }
        return reading(metric)
    }

    /// The compact Dynamic Island: the frame rate while a game runs, otherwise the two
    /// temperatures (or the two loads when the PC has no temperature sensors).
    var compactPair: (OrbitGlanceReading, OrbitGlanceReading)? {
        if let cpu = reading("cpuTemp"), let gpu = reading("gpuTemp") { return (cpu, gpu) }
        if let cpu = reading("cpu"), let other = reading("gpu") ?? reading("ram") { return (cpu, other) }
        return nil
    }

    var compactFrameRate: OrbitGlanceReading? {
        guard state.gameName?.isEmpty == false else { return nil }
        return reading("fps")
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// The content state as the shared readings model, so the takeaway reads the same everywhere.
struct OrbitActivityTelemetry: OrbitTelemetry {
    var state: OrbitActivityAttributes.ContentState

    var isOnline: Bool { state.isConnected }
    var cpuUsage: Double { state.cpuUsage ?? 0 }
    var cpuTemp: Double? { state.cpuTemp }
    var gpuUsage: Double? { state.gpuUsage }
    var gpuTemp: Double? { state.gpuTemp }
    var gpuPowerWatts: Double? { state.gpuPowerWatts }
    var cpuPowerWatts: Double? { state.cpuPowerWatts }
    var cpuClockMHz: Double? { nil }
    var liquidTemp: Double? { nil }
    var cpuFanRPM: Double? { nil }
    var gpuFanPercent: Double? { nil }
    var diskReadMBps: Double? { nil }
    var diskWriteMBps: Double? { nil }
    var networkUploadMBps: Double? { nil }
    var networkDownloadMBps: Double? { nil }
    var vramUsedGB: Double? { state.vramUsedGB }
    var vramTotalGB: Double? { state.vramTotalGB }
    /// The activity carries memory as a percentage; as GB of 100 the ratio is the same.
    var ramUsedGB: Double { state.ramUsage ?? 0 }
    var ramTotalGB: Double { state.ramUsage == nil ? 0 : 100 }
    var ssdUsedTB: Double { 0 }
    var ssdTotalTB: Double { 0 }
    var uptimeSeconds: Int { 0 }
    var activeGame: String? { state.gameName }
    var fps: Double? { state.fps }
    var telemetryAvailable: Bool? { state.telemetryAvailable }
    var sessionLocked: Bool? { nil }
}

// MARK: - Dynamic Island

/// A reading as the compact Dynamic Island shows it: "CPU 52°", or "144 fps".
struct OrbitCompactReading: View {
    var reading: OrbitGlanceReading

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let label = reading.shortLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(reading.value + (reading.shortLabel == nil ? " " : "") + (reading.unit ?? ""))
                .font(.system(size: 15, weight: .semibold).width(.condensed))
                .foregroundStyle(reading.color)
                .monospacedDigit()
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Left of the camera: the CPU temperature, or the mark when the right side carries the
/// frame rate or the reading you chose.
struct OrbitActivityCompactLeading: View {
    var snapshot: OrbitActivitySnapshot

    var body: some View {
        if snapshot.isLive, snapshot.chosenReading == nil, snapshot.compactFrameRate == nil, let pair = snapshot.compactPair {
            OrbitCompactReading(reading: pair.0)
        } else {
            OrbitWidgetMark(status: snapshot.markStatus, size: 18, accent: snapshot.accent)
        }
    }
}

/// Right of the camera: the GPU temperature, the frame rate while a game runs, or the
/// reading you chose.
struct OrbitActivityCompactTrailing: View {
    var snapshot: OrbitActivitySnapshot

    var body: some View {
        if !snapshot.isLive {
            Text(snapshot.state.isConnected ? "Paused" : "Off")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if let reading = snapshot.chosenReading ?? snapshot.compactFrameRate {
            OrbitCompactReading(reading: reading)
        } else if let pair = snapshot.compactPair {
            OrbitCompactReading(reading: pair.1)
        } else if let reading = snapshot.readings.first {
            OrbitCompactReading(reading: reading)
        }
    }
}

// MARK: - Lock Screen

/// The Lock Screen and banner presentation: the mark, the takeaway, three readings and the
/// game while one runs. The minimal style keeps one reading; the detailed style adds
/// temperatures and power.
struct OrbitActivityLockScreen: View {
    var snapshot: OrbitActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                OrbitWidgetMark(status: snapshot.markStatus, size: 30, accent: snapshot.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.headline)
                        .font(.headline)
                        .lineLimit(1)
                    Text(snapshot.subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            if snapshot.style != .minimal, !snapshot.readings.isEmpty {
                OrbitGlanceReadingsRow(readings: snapshot.readings, valueSize: 26, accent: snapshot.accent)
                if snapshot.style == .detailed, let details = snapshot.details {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var trailing: some View {
        if !snapshot.state.isConnected {
            OrbitWakeButton(accent: snapshot.accent)
        } else if snapshot.style == .minimal, let reading = snapshot.chosenReading ?? snapshot.readings.first {
            VStack(alignment: .trailing, spacing: 0) {
                OrbitGlanceValue(reading: reading, size: 30)
                Text(reading.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else if snapshot.state.showTimestamp != false, snapshot.isLive {
            Text(snapshot.state.lastUpdated, style: .time)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Wakes the PC from a widget or the Live Activity (with Orbit Pro; otherwise it opens the
/// Orbit Pro sheet).
struct OrbitWakeButton: View {
    var pcID: String? = nil
    var accent: Color = OrbitPalette.accent

    var body: some View {
        OrbitProPowerButton(intent: OrbitWakePCIntent(pcID: pcID)) {
            Label("Wake", systemImage: "power")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    Capsule()
                        .fill(accent)
                        .widgetAccentable()
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wake the PC")
    }
}

// MARK: - Orbit Pro gate for power buttons

/// Runs the power intent with Orbit Pro; without it, the same label opens Orbit's upgrade sheet
/// and carries a small lock.
struct OrbitProPowerButton<I: AppIntent, Label: View>: View {
    let intent: I
    let label: Label

    init(intent: I, @ViewBuilder label: () -> Label) {
        self.intent = intent
        self.label = label()
    }

    var body: some View {
        if OrbitProEntitlement.cachedIsUnlocked {
            Button(intent: intent) { label }
        } else {
            Link(destination: OrbitProEntitlement.upgradeURL) {
                label.overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(3)
                        .background(Color.white, in: Circle())
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Needs Orbit Pro")
                }
            }
        }
    }
}
