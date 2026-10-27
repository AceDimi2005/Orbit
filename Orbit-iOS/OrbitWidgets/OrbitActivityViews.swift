import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Live Activity & Dynamic Island
//
// The Lock Screen banner, the Dynamic Island (compact, minimal and expanded) and the Smart Stack on
// Apple Watch / CarPlay. iOS lets Orbit update the activity only while the app runs, so a reading can
// be minutes old when the phone is locked: it then stays on screen, dimmed, with the time it was taken,
// instead of turning into dashes (which looked like the activity had stopped working).

struct OrbitMonitorActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitActivityAttributes.self) { context in
            let look = OrbitActivityLook(context)
            OrbitActivityLockScreen(context: context)
                .activityBackgroundTint(look.background)
                .activitySystemActionForegroundColor(look.accent)
                .widgetURL(OrbitActivityLook.dashboardURL)
        } dynamicIsland: { context in
            let look = OrbitActivityLook(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbitIslandLeading(look: look)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OrbitIslandTrailing(look: look)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OrbitIslandBottom(look: look)
                }
            } compactLeading: {
                OrbitBrandMark(tint: look.accent)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 1)
            } compactTrailing: {
                OrbitIslandCompactValue(look: look)
            } minimal: {
                OrbitIslandMinimal(look: look)
            }
            .widgetURL(OrbitActivityLook.dashboardURL)
            .keylineTint(look.accent)
        }
        .orbitSmartStackFamilies()
    }
}

private extension WidgetConfiguration {
    /// Apple Watch Smart Stack and CarPlay show the `.small` family (iOS 18+).
    func orbitSmartStackFamilies() -> some WidgetConfiguration {
        if #available(iOSApplicationExtension 18.0, *) {
            return supplementalActivityFamilies([.small, .medium])
        } else {
            return self
        }
    }
}

// MARK: - What the views show

/// Everything the Live Activity views derive from one ActivityKit snapshot.
struct OrbitActivityLook {
    static let dashboardURL = URL(string: "orbit://dashboard")!

    let context: ActivityViewContext<OrbitActivityAttributes>
    init(_ context: ActivityViewContext<OrbitActivityAttributes>) { self.context = context }

    var state: OrbitActivityAttributes.ContentState { context.state }
    var pcName: String { context.attributes.pcName }
    var theme: OrbitWidgetTheme { OrbitWidgetTheme(rawValue: state.accent ?? "noir") ?? .noir }
    var accent: Color { theme.accent }
    var background: Color {
        theme == .noir ? Color(red: 0.015, green: 0.02, blue: 0.035).opacity(0.94) : theme.background.opacity(0.94)
    }
    var style: String { ["standard", "minimal", "detailed"].contains(state.style ?? "") ? state.style! : "standard" }

    enum Status { case live, stale, offline, waiting }

    /// The PC answered and its sensors report, even if the reading is a little old.
    var hasReadings: Bool { state.isConnected && state.telemetryAvailable != false }
    /// The app pushed this reading recently (within three update intervals).
    var isLive: Bool { hasReadings && state.isPaused != true && !context.isStale }

    var status: Status {
        if !state.isConnected { return .offline }
        if state.telemetryAvailable == false { return .waiting }
        return isLive ? .live : .stale
    }

    var statusTint: Color {
        switch status {
        case .live: Color(red: 0.30, green: 0.92, blue: 0.62)
        case .stale, .waiting: Color(red: 1.0, green: 0.74, blue: 0.32)
        case .offline: Color(red: 1.0, green: 0.42, blue: 0.40)
        }
    }

    var statusText: Text {
        switch status {
        case .live: Text("LIVE")
        case .stale: Text(state.lastUpdated, style: .time)
        case .offline: Text("Offline")
        case .waiting: Text("Waiting")
        }
    }

    /// Second line under the PC name.
    var subtitle: Text {
        switch status {
        case .live:
            if state.showGame != false, let game = state.gameName, !game.isEmpty { return Text(game) }
            return Text(focusTitle)
        case .stale: return Text("Last reading · open Orbit to refresh")
        case .offline: return Text("Asleep, off or out of reach")
        case .waiting: return Text("Waiting for the PC's sensors")
        }
    }

    var subtitleIsGame: Bool {
        status == .live && state.showGame != false && !(state.gameName ?? "").isEmpty
    }

    var focusTitle: String {
        switch state.focus {
        case "gaming": "Gaming monitor"
        case "power": "Power monitor"
        default: "Live monitor"
        }
    }

    // MARK: Metrics

    var metrics: [String] {
        switch state.focus {
        case "gaming": ["fps", "gpu", "vram"]
        case "power": ["cpuPower", "gpuPower", "gpu"]
        default: ["cpu", "gpu", "ram"]
        }
    }

    /// The metric of the compact island and the minimal layout.
    var primary: String {
        if let metric = state.primaryMetric, metric != "automatic" { return metric }
        switch state.focus {
        case "gaming": return "fps"
        case "power": return "gpuPower"
        default: return "cpu"
        }
    }

    /// Extra readings of the detailed layout: whatever the three main cells don't already show.
    var detailMetrics: [String] {
        ["cpuTemp", "gpuTemp", "cpuPower", "gpuPower", "vram"].filter { !metrics.contains($0) }.prefix(4).map { $0 }
    }

    func title(_ metric: String) -> String {
        switch metric {
        case "cpu": "CPU"
        case "gpu": "GPU"
        case "ram": "RAM"
        case "fps": "FPS"
        case "cpuPower": "CPU POWER"
        case "gpuPower": "GPU POWER"
        case "vram": "VRAM"
        case "cpuTemp": "CPU"
        case "gpuTemp": "GPU"
        default: "PC"
        }
    }

    func symbol(_ metric: String) -> String {
        switch metric {
        case "fps": "gamecontroller.fill"
        case "gpu", "vram": "rectangle.3.group.fill"
        case "ram": "memorychip.fill"
        case "cpuPower", "gpuPower": "bolt.fill"
        case "cpuTemp", "gpuTemp": "thermometer.medium"
        default: "cpu.fill"
        }
    }

    func tint(_ metric: String) -> Color {
        guard theme != .noir else { return accent }
        return switch metric {
        case "cpu", "cpuTemp": Color(red: 0.25, green: 0.84, blue: 0.96)
        case "gpu", "vram", "gpuTemp": Color(red: 0.71, green: 0.58, blue: 1)
        case "ram", "fps": Color(red: 0.40, green: 0.91, blue: 0.69)
        case "cpuPower", "gpuPower": Color(red: 1, green: 0.78, blue: 0.36)
        default: accent
        }
    }

    /// The number and its unit, drawn in two sizes.
    func reading(_ metric: String) -> (value: String, unit: String) {
        guard hasReadings else { return ("—", "") }
        func whole(_ value: Double?, _ unit: String, max limit: Double = 1_000_000) -> (String, String) {
            guard let value, value.isFinite, value >= 0, value <= limit else { return ("—", "") }
            return ("\(Int(value.rounded()))", unit)
        }
        switch metric {
        case "cpu": return whole(state.cpuUsage, "%", max: 100)
        case "gpu": return whole(state.gpuUsage, "%", max: 100)
        case "ram": return whole(state.ramUsage, "%", max: 100)
        case "fps": return whole(state.fps, "fps")
        case "cpuPower": return whole(state.cpuPowerWatts, "W")
        case "gpuPower": return whole(state.gpuPowerWatts, "W")
        case "cpuTemp": return whole(state.cpuTemp, "°", max: 150)
        case "gpuTemp": return whole(state.gpuTemp, "°", max: 150)
        case "vram":
            guard let used = state.vramUsedGB, used.isFinite, used >= 0 else { return ("—", "") }
            return (String(format: used >= 10 ? "%.0f" : "%.1f", used), "GB")
        default: return ("—", "")
        }
    }

    func progress(_ metric: String) -> Double? {
        guard hasReadings else { return nil }
        func ratio(_ value: Double?, _ full: Double, floor: Double = 0) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value / full, floor), 1)
        }
        switch metric {
        case "cpu": return ratio(state.cpuUsage, 100)
        case "gpu": return ratio(state.gpuUsage, 100)
        case "ram": return ratio(state.ramUsage, 100)
        case "fps": return ratio(state.fps, 165, floor: 0.04)
        case "cpuPower": return ratio(state.cpuPowerWatts, 200, floor: 0.04)
        case "gpuPower": return ratio(state.gpuPowerWatts, 450, floor: 0.04)
        case "cpuTemp": return state.cpuTemp.map { min(max(($0 - 25) / 70, 0.04), 1) }
        case "gpuTemp": return state.gpuTemp.map { min(max(($0 - 25) / 65, 0.04), 1) }
        case "vram":
            guard let used = state.vramUsedGB, used.isFinite else { return nil }
            if let total = state.vramTotalGB, total > 0 { return min(max(used / total, 0.04), 1) }
            return min(max(used / 16, 0.04), 1)
        default: return nil
        }
    }
}

// MARK: - Lock Screen

private struct OrbitActivityLockScreen: View {
    let context: ActivityViewContext<OrbitActivityAttributes>

    var body: some View {
        if #available(iOSApplicationExtension 18.0, *) {
            OrbitActivityFamilySwitch(context: context)
        } else {
            OrbitActivityBanner(look: OrbitActivityLook(context))
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct OrbitActivityFamilySwitch: View {
    let context: ActivityViewContext<OrbitActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            OrbitActivitySmartStack(look: OrbitActivityLook(context))
        } else {
            OrbitActivityBanner(look: OrbitActivityLook(context))
        }
    }
}

private struct OrbitActivityBanner: View {
    let look: OrbitActivityLook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitActivityHeader(look: look, markSize: 32)
            switch look.status {
            case .offline:
                OrbitActivityOfflineRow(look: look)
            default:
                if look.style == "minimal" {
                    OrbitActivityHeroRow(look: look)
                } else {
                    HStack(spacing: 8) {
                        ForEach(look.metrics, id: \.self) { metric in
                            OrbitActivityMetricCell(look: look, metric: metric, size: .regular)
                        }
                    }
                    if look.style == "detailed" {
                        OrbitActivityDetailRow(look: look)
                        OrbitActivityActionRow(look: look)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .foregroundStyle(.white)
        .background(alignment: .topLeading) {
            // A soft light behind the logo, in the theme colour.
            RadialGradient(colors: [look.accent.opacity(0.22), .clear], center: UnitPoint(x: 0.08, y: 0.1), startRadius: 2, endRadius: 190)
        }
    }
}

private struct OrbitActivityHeader: View {
    let look: OrbitActivityLook
    var markSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            OrbitBrandMark(tint: look.accent)
                .frame(width: markSize, height: markSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(look.pcName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                look.subtitle
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(look.subtitleIsGame ? look.accent : .white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            OrbitActivityStatusBadge(look: look)
        }
    }
}

private struct OrbitActivityStatusBadge: View {
    let look: OrbitActivityLook

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(look.statusTint)
                .frame(width: 6, height: 6)
                .shadow(color: look.statusTint.opacity(0.9), radius: 3)
            look.statusText
                .font(.system(size: 10.5, weight: .bold))
                .tracking(look.status == .live ? 0.9 : 0.2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(look.status == .live ? look.statusTint : .white.opacity(0.82))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(look.statusTint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(look.statusTint.opacity(0.28), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
    }
}

/// Label, number with unit, and a thin bar.
private struct OrbitActivityMetricCell: View {
    enum Size { case regular, compact }
    let look: OrbitActivityLook
    let metric: String
    var size: Size

    var body: some View {
        let tint = look.tint(metric)
        let reading = look.reading(metric)
        let compact = size == .compact
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 4) {
                Image(systemName: look.symbol(metric))
                    .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(look.title(metric))
                    .font(.system(size: compact ? 9 : 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(reading.value)
                    .font(.system(size: compact ? 19 : 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !reading.unit.isEmpty {
                    Text(reading.unit)
                        .font(.system(size: compact ? 10.5 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .opacity(look.isLive ? 1 : 0.55)
            OrbitActivityBar(progress: look.progress(metric), tint: tint, dimmed: !look.isLive)
                .frame(height: compact ? 3 : 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 7 : 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 0.7)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(look.title(metric)) \(reading.value) \(reading.unit)")
    }
}

private struct OrbitActivityBar: View {
    var progress: Double?
    var tint: Color
    var dimmed: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if let progress {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.height, proxy.size.width * progress))
                        .shadow(color: tint.opacity(dimmed ? 0 : 0.55), radius: 3)
                }
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}

/// Minimal layout: one large reading and a ring.
private struct OrbitActivityHeroRow: View {
    let look: OrbitActivityLook

    var body: some View {
        let metric = look.primary
        let reading = look.reading(metric)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(look.title(metric))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.55))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(reading.value)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(reading.unit)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(look.tint(metric))
                .opacity(look.isLive ? 1 : 0.55)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            OrbitActivityRing(progress: look.progress(metric), tint: look.tint(metric), dimmed: !look.isLive, lineWidth: 6) {
                Image(systemName: look.symbol(metric))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(look.tint(metric))
            }
            .frame(width: 58, height: 58)
        }
    }
}

private struct OrbitActivityRing<Center: View>: View {
    var progress: Double?
    var tint: Color
    var dimmed: Bool
    var lineWidth: CGFloat
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * progress)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(dimmed ? 0 : 0.5), radius: 3)
            }
            center()
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}

/// Detailed layout: temperatures, power and VRAM in small chips.
private struct OrbitActivityDetailRow: View {
    let look: OrbitActivityLook

    var body: some View {
        HStack(spacing: 6) {
            ForEach(look.detailMetrics, id: \.self) { metric in
                let reading = look.reading(metric)
                HStack(spacing: 4) {
                    Image(systemName: look.symbol(metric))
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(look.tint(metric))
                    Text(look.title(metric) == "CPU POWER" ? "CPU" : (look.title(metric) == "GPU POWER" ? "GPU" : look.title(metric)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 1)
                    Text(reading.value + reading.unit)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .opacity(look.isLive ? 1 : 0.55)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.05), in: Capsule())
            }
        }
    }
}

/// Power On while the PC is away; Sleep and Shut Down while it runs; Open and Stop always.
private struct OrbitActivityActionRow: View {
    let look: OrbitActivityLook
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if look.status == .offline {
                OrbitPowerPill(action: .wake, compact: compact)
            } else {
                OrbitPowerPill(action: .sleep, compact: compact)
                OrbitPowerPill(action: .shutdown, compact: compact)
            }
            Spacer(minLength: 4)
            Link(destination: OrbitActivityLook.dashboardURL) {
                OrbitActivityRoundIcon(symbol: "arrow.up.forward.app.fill", tint: look.accent, compact: compact)
            }
            .accessibilityLabel("Open Orbit")
            Button(intent: StopOrbitLiveActivityIntent()) {
                OrbitActivityRoundIcon(symbol: "xmark", tint: .white, compact: compact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End Live Activity")
        }
    }
}

private struct OrbitActivityRoundIcon: View {
    var symbol: String
    var tint: Color
    var compact: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 11 : 12, weight: .bold))
            .foregroundStyle(tint.opacity(0.9))
            .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
            .background(.white.opacity(0.09), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.7))
    }
}

/// The PC is off or unreachable: say so and offer Power On (Wake-on-LAN).
private struct OrbitActivityOfflineRow: View {
    let look: OrbitActivityLook

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(look.statusTint)
                .frame(width: 40, height: 40)
                .background(look.statusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("PC is offline")
                    .font(.system(size: 14, weight: .semibold))
                Text("Last seen \(Text(look.state.lastUpdated, style: .time))")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 6)
            OrbitPowerPill(action: .wake, compact: false)
            Button(intent: StopOrbitLiveActivityIntent()) {
                OrbitActivityRoundIcon(symbol: "xmark", tint: .white, compact: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End Live Activity")
        }
    }
}

// MARK: - Dynamic Island

private struct OrbitIslandLeading: View {
    let look: OrbitActivityLook

    var body: some View {
        HStack(spacing: 8) {
            OrbitBrandMark(tint: look.accent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(look.pcName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                look.subtitle
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(look.subtitleIsGame ? look.accent : .white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.top, 2)
    }
}

private struct OrbitIslandTrailing: View {
    let look: OrbitActivityLook

    var body: some View {
        let metric = look.primary
        let reading = look.reading(metric)
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(reading.value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(reading.unit)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .opacity(0.7)
            }
            .foregroundStyle(look.isLive ? look.tint(metric) : .white.opacity(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Circle().fill(look.statusTint).frame(width: 5, height: 5)
                Text(look.status == .live ? look.title(metric) : (look.status == .stale ? "LAST" : look.title(metric)))
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.trailing, 6)
        .padding(.top, 2)
    }
}

private struct OrbitIslandBottom: View {
    let look: OrbitActivityLook

    var body: some View {
        VStack(spacing: 8) {
            if look.status == .offline {
                OrbitActivityOfflineRow(look: look)
            } else {
                HStack(spacing: 6) {
                    ForEach(look.metrics, id: \.self) { metric in
                        OrbitActivityMetricCell(look: look, metric: metric, size: .compact)
                    }
                }
                OrbitActivityActionRow(look: look, compact: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct OrbitIslandCompactValue: View {
    let look: OrbitActivityLook

    var body: some View {
        if look.status == .offline {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(look.statusTint)
                .padding(.trailing, 2)
        } else {
            let reading = look.reading(look.primary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(reading.value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(reading.unit)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .opacity(0.75)
            }
            .foregroundStyle(look.isLive ? look.tint(look.primary) : .white.opacity(0.5))
            .lineLimit(1)
            .padding(.trailing, 2)
        }
    }
}

private struct OrbitIslandMinimal: View {
    let look: OrbitActivityLook

    var body: some View {
        OrbitActivityRing(progress: look.progress(look.primary), tint: look.accent, dimmed: !look.isLive, lineWidth: 2.4) {
            OrbitBrandMark(tint: look.accent, glow: false)
                .padding(3.5)
        }
        .padding(1)
    }
}

// MARK: - Apple Watch Smart Stack and CarPlay

private struct OrbitActivitySmartStack: View {
    let look: OrbitActivityLook

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                OrbitBrandMark(tint: look.accent)
                    .frame(width: 18, height: 18)
                Text(look.pcName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Circle()
                    .fill(look.statusTint)
                    .frame(width: 6, height: 6)
            }
            if look.status == .offline {
                Text("PC is offline")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                HStack(spacing: 8) {
                    ForEach(look.metrics, id: \.self) { metric in
                        let reading = look.reading(metric)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(look.title(metric) == "CPU POWER" ? "CPU W" : (look.title(metric) == "GPU POWER" ? "GPU W" : look.title(metric)))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(look.tint(metric))
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text(reading.value)
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                Text(reading.unit)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .opacity(0.6)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .opacity(look.isLive ? 1 : 0.55)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
