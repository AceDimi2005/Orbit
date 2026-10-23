import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        OrbitShortcutsWidget()
        OrbitOverviewWidget()
        OrbitGamingWidget()
        OrbitPowerWidget()
        OrbitThermalWidget()
        OrbitCoolingWidget()
        OrbitStorageWidget()
        OrbitNetworkWidget()
        OrbitMetricWidget()
        OrbitDeckWidget()
        OrbitMonitorActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            OrbitWakeControlCenterWidget()
            OrbitShutdownControlCenterWidget()
            OrbitSleepControlCenterWidget()
            OrbitDeckControl()
        }
    }
}

private enum OrbitWidgetStyle {
    static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let background = Color.black
    static let dashboardURL = URL(string: "orbit://dashboard")!
    static let remoteURL = URL(string: "orbit://remote")!
}

private struct ShortcutEntry: TimelineEntry {
    var date: Date
    var pcName: String
    var feedback: String?
}

private struct ShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutEntry {
        ShortcutEntry(date: Date(), pcName: "Your PC", feedback: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (ShortcutEntry) -> Void) {
        let name = OrbitWidgetConnectionStore.defaultConnection()?.name ?? "Your PC"
        completion(ShortcutEntry(date: Date(), pcName: name, feedback: OrbitWidgetConnectionStore.recentPowerFeedback()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShortcutEntry>) -> Void) {
        let name = OrbitWidgetConnectionStore.defaultConnection()?.name ?? "Your PC"
        let feedback = OrbitWidgetConnectionStore.recentPowerFeedback()
        var entries = [ShortcutEntry(date: Date(), pcName: name, feedback: feedback)]
        if feedback != nil {
            entries.append(ShortcutEntry(date: Date().addingTimeInterval(45), pcName: name, feedback: nil))
        }
        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct OrbitShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitShortcuts", provider: ShortcutProvider()) { entry in
            OrbitShortcutsView(entry: entry)
                .containerBackground(OrbitWidgetStyle.background, for: .widget)
        }
        .configurationDisplayName("Orbit Power & Quick Controls")
        .description("Interactive Power On (Wake-on-LAN), Shut Down, Sleep, and instant shortcuts to your PC.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct OrbitShortcutsView: View {
    var entry: ShortcutEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "power")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Power On PC with Orbit")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                    Text(entry.pcName)
                        .lineLimit(1)
                }
                .font(.caption.weight(.bold))
                HStack(spacing: 6) {
                    OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                        Label("Wake", systemImage: "power")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Text("·").foregroundStyle(.secondary)
                    OrbitProPowerButton(intent: OrbitShutdownPCIntent()) {
                        Label("Off", systemImage: "power.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .systemMedium:
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(spacing: 8) {
                    powerActionButton(
                        title: "Power On",
                        subtitle: "Wake-on-LAN",
                        symbol: "power",
                        tint: Color(red: 0.35, green: 0.94, blue: 0.66),
                        intent: OrbitWakePCIntent()
                    )
                    powerActionButton(
                        title: "Sleep",
                        subtitle: "Standby",
                        symbol: "moon.zzz.fill",
                        tint: Color(red: 1.0, green: 0.78, blue: 0.36),
                        intent: OrbitSleepPCIntent()
                    )
                    powerActionButton(
                        title: "Shut Down",
                        subtitle: "Turn Off",
                        symbol: "power.circle.fill",
                        tint: Color(red: 1.0, green: 0.45, blue: 0.48),
                        intent: OrbitShutdownPCIntent()
                    )
                }
                HStack(spacing: 8) {
                    shortcutPill("Overview", symbol: "gauge.with.dots.needle.33percent", route: "dashboard", tint: OrbitWidgetStyle.accent)
                    shortcutPill("Remote", symbol: "computermouse.fill", route: "remote", tint: Color(red: 0.71, green: 0.58, blue: 1))
                }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                header
                Spacer(minLength: 0)
                OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .bold))
                        Text("Power On")
                            .font(.system(size: 12, weight: .bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color(red: 0.38, green: 0.96, blue: 0.68))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.30), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)

                OrbitProPowerButton(intent: OrbitShutdownPCIntent()) {
                    HStack(spacing: 8) {
                        Image(systemName: "power.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Shut Down")
                            .font(.system(size: 12, weight: .bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.52, blue: 0.54))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.28), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(entry.pcName.uppercased(), systemImage: "desktopcomputer")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OrbitWidgetStyle.accent)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let feedback = entry.feedback {
                Text(feedback)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.mint)
                    .lineLimit(1)
            } else if family == .systemMedium {
                Text("POWER & REMOTE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func powerActionButton<I: AppIntent>(title: String, subtitle: String, symbol: String, tint: Color, intent: I) -> some View {
        OrbitProPowerButton(intent: intent) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.20))
                            .frame(width: 26, height: 26)
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(tint.opacity(0.26), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func shortcutPill(_ title: String, symbol: String, route: String, tint: Color) -> some View {
        Link(destination: URL(string: "orbit://\(route)")!) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - iOS 18+ Control Center, Lock Screen & Action Button Controls

@available(iOSApplicationExtension 18.0, *)
struct OrbitWakeControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.wake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitWakePCIntent()) {
                Label("Power On PC", systemImage: "power")
            }
        }
        .displayName("Power On PC (Wake)")
        .description("Turns on your paired PC using Wake-on-LAN directly from Control Center or Lock Screen.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct OrbitShutdownControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.shutdown"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitShutdownPCIntent()) {
                Label("Shut Down PC", systemImage: "power.circle.fill")
            }
        }
        .displayName("Shut Down PC")
        .description("Safely shuts down your paired Windows PC from Control Center.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct OrbitSleepControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.sleep"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitSleepPCIntent()) {
                Label("Sleep PC", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Sleep PC")
        .description("Puts your paired Windows PC into sleep mode from Control Center.")
    }
}

// MARK: - Live Activity & Dynamic Island

struct OrbitMonitorActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitActivityAttributes.self) { context in
            OrbitLiveActivityPanel(context: context)
                .activityBackgroundTint(OrbitWidgetTheme(rawValue: context.state.accent ?? "noir")?.background ?? OrbitWidgetStyle.background)
                .activitySystemActionForegroundColor(accent(context))
                .widgetURL(OrbitWidgetStyle.dashboardURL)
        } dynamicIsland: { context in
            let view = OrbitActivityPresentation(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent(context))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.pcName)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                            if let game = context.state.gameName, !game.isEmpty, view.fresh {
                                Text(game)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(accent(context))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(view.fresh ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(view.shortStatus)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: Capsule())
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OrbitLiveActivityPanel(context: context, island: true)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: view.primarySymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent(context))
                    Text(view.compactTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            } compactTrailing: {
                if view.fresh {
                    Text(view.primaryValue)
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(accent(context))
                } else {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                if let progress = view.progress(view.primary), view.fresh {
                    Gauge(value: progress) {
                        Image(systemName: view.primarySymbol)
                    } currentValueLabel: {
                        Image(systemName: view.primarySymbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent(context))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(accent(context))
                } else {
                    Image(systemName: view.fresh ? view.primarySymbol : "pause.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent(context))
                }
            }
            .widgetURL(OrbitWidgetStyle.dashboardURL)
            .keylineTint(accent(context))
        }
        .applyWatchSmartStackSupport()
    }

    private func accent(_ context: ActivityViewContext<OrbitActivityAttributes>) -> Color {
        OrbitWidgetTheme(rawValue: context.state.accent ?? "noir")?.accent ?? OrbitWidgetStyle.accent
    }
}

private extension WidgetConfiguration {
    func applyWatchSmartStackSupport() -> some WidgetConfiguration {
        if #available(iOSApplicationExtension 18.0, *) {
            return self.supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

private struct OrbitActivityPresentation {
    var context: ActivityViewContext<OrbitActivityAttributes>
    init(_ context: ActivityViewContext<OrbitActivityAttributes>) { self.context = context }
    var state: OrbitActivityAttributes.ContentState { context.state }
    var fresh: Bool { state.isConnected && state.telemetryAvailable != false && state.isPaused != true && !context.isStale }
    var status: String {
        if !state.isConnected { return "Offline" }
        if state.isPaused == true || context.isStale { return "Paused · tap to refresh" }
        if state.telemetryAvailable == false { return "Waiting for sensors" }
        return "Live"
    }
    var shortStatus: String {
        if !state.isConnected { return "Offline" }
        if state.isPaused == true || context.isStale { return "Paused" }
        if state.telemetryAvailable == false { return "Waiting" }
        return "Live"
    }
    var primary: String {
        if let metric = state.primaryMetric, metric != "automatic" { return metric }
        switch state.focus {
        case "gaming": return "fps"
        case "power": return "gpuPower"
        default: return "cpu"
        }
    }
    var primarySymbol: String { symbol(primary) }
    var primaryValue: String { value(primary) }
    var primaryTitle: String { title(primary) }
    var compactTitle: String {
        switch primary {
        case "fps": "FPS"
        case "gpu": "GPU"
        case "vram": "VRAM"
        case "ram": "RAM"
        case "cpuPower", "gpuPower": "PWR"
        default: "CPU"
        }
    }
    var metrics: [String] {
        switch state.focus {
        case "gaming": ["fps", "gpu", "vram"]
        case "power": ["cpuPower", "gpuPower", "gpu"]
        default: ["cpu", "gpu", "ram"]
        }
    }
    func symbol(_ metric: String) -> String {
        switch metric {
        case "fps": "gamecontroller.fill"
        case "gpu", "vram": "rectangle.3.group"
        case "ram": "memorychip"
        case "cpuPower", "gpuPower": "bolt.fill"
        default: "cpu"
        }
    }
    func title(_ metric: String) -> String {
        switch metric {
        case "cpu": "CPU"
        case "gpu": "GPU"
        case "ram": "RAM"
        case "fps": "FPS"
        case "cpuPower": "CPU W"
        case "gpuPower": "GPU W"
        case "vram": "VRAM"
        default: "PC"
        }
    }
    func color(_ metric: String, fallback: Color) -> Color {
        if (state.accent ?? "noir") == "noir" { return fallback }
        return switch metric {
        case "cpu": Color(red: 0.25, green: 0.84, blue: 0.96)
        case "gpu", "vram": Color(red: 0.71, green: 0.58, blue: 1)
        case "ram", "fps": Color(red: 0.40, green: 0.91, blue: 0.69)
        case "cpuPower", "gpuPower": Color(red: 1, green: 0.78, blue: 0.36)
        default: fallback
        }
    }
    func progress(_ metric: String) -> Double? {
        guard fresh else { return nil }
        switch metric {
        case "cpu":
            guard let v = state.cpuUsage, v.isFinite else { return nil }
            return min(max(v / 100.0, 0), 1)
        case "gpu":
            guard let v = state.gpuUsage, v.isFinite else { return nil }
            return min(max(v / 100.0, 0), 1)
        case "ram":
            guard let v = state.ramUsage, v.isFinite else { return nil }
            return min(max(v / 100.0, 0), 1)
        case "fps":
            guard let v = state.fps, v.isFinite else { return nil }
            return min(max(v / 165.0, 0.05), 1)
        case "cpuPower":
            guard let v = state.cpuPowerWatts, v.isFinite else { return nil }
            return min(max(v / 200.0, 0.05), 1)
        case "gpuPower":
            guard let v = state.gpuPowerWatts, v.isFinite else { return nil }
            return min(max(v / 400.0, 0.05), 1)
        case "vram":
            guard let v = state.vramUsedGB, v.isFinite else { return nil }
            return min(max(v / 16.0, 0.05), 1)
        default:
            return nil
        }
    }
    func value(_ metric: String) -> String {
        guard fresh else { return "—" }
        switch metric {
        case "cpu": return number(state.cpuUsage, suffix: "%")
        case "gpu": return number(state.gpuUsage, suffix: "%")
        case "ram": return number(state.ramUsage, suffix: "%")
        case "fps": return number(state.fps)
        case "cpuPower": return number(state.cpuPowerWatts, suffix: "W")
        case "gpuPower": return number(state.gpuPowerWatts, suffix: "W")
        case "vram": return state.vramUsedGB.map { String(format: "%.1fG", $0) } ?? "—"
        case "cpuTemp": return number(state.cpuTemp, suffix: "°")
        case "gpuTemp": return number(state.gpuTemp, suffix: "°")
        default: return "—"
        }
    }
    private func number(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000 else { return "—" }
        return "\(Int(value.rounded()))\(suffix)"
    }
}

private struct OrbitLiveActivityPanel: View {
    var context: ActivityViewContext<OrbitActivityAttributes>
    var island = false
    private var presentation: OrbitActivityPresentation { OrbitActivityPresentation(context) }
    private var accent: Color { OrbitWidgetTheme(rawValue: context.state.accent ?? "noir")?.accent ?? OrbitWidgetStyle.accent }
    private var detailed: Bool { context.state.style == "detailed" }
    private var minimal: Bool { context.state.style == "minimal" }

    var body: some View {
        if #available(iOSApplicationExtension 18.0, *), !island {
            WatchAwareLiveActivityContainer(context: context, watchContent: {
                watchSmartStackView
            }, standardContent: {
                standardBody
            })
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: island ? 8 : 10) {
            if !island {
                lockScreenHeader
            }
            if minimal && !island {
                minimalRow
            } else {
                metricsGrid
                if detailed && !island {
                    secondaryRow
                }
            }
            footerRow
        }
        .foregroundStyle(.white)
        .padding(.horizontal, island ? 6 : 16)
        .padding(.vertical, island ? 4 : 14)
    }

    private var watchSmartStackView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(presentation.fresh ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(context.attributes.pcName)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let game = context.state.gameName, !game.isEmpty, presentation.fresh {
                    Text(game)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                } else {
                    Text(presentation.shortStatus)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            HStack(spacing: 6) {
                ForEach(presentation.metrics, id: \.self) { metric in
                    let tint = presentation.color(metric, fallback: accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.title(metric))
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(tint)
                        Text(presentation.value(metric))
                            .font(.system(size: 13.5, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            HStack(spacing: 6) {
                OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                    Label("Power On", systemImage: "power")
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.22), in: Capsule())
                        .foregroundStyle(Color(red: 0.45, green: 0.96, blue: 0.68))
                }
                .buttonStyle(.plain)

                OrbitProPowerButton(intent: OrbitShutdownPCIntent()) {
                    Label("Shut Down", systemImage: "power.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.22), in: Capsule())
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var lockScreenHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
            }
            Text(context.attributes.pcName)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            if context.state.showGame != false, let game = context.state.gameName, !game.isEmpty, presentation.fresh {
                Text("· \(game)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle()
                    .fill(presentation.fresh ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(presentation.shortStatus)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private var minimalRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.primaryTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(presentation.primaryValue)
                    .font(.system(size: 32, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 8)
            if let progress = presentation.progress(presentation.primary) {
                Gauge(value: progress) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: presentation.primarySymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(accent)
            }
        }
    }

    private var metricsGrid: some View {
        HStack(spacing: 8) {
            ForEach(presentation.metrics, id: \.self) { metric in
                let tint = presentation.color(metric, fallback: accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: presentation.symbol(metric))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                        Text(presentation.title(metric))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                    Text(presentation.value(metric))
                        .font(.system(size: island ? 18 : 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.10))
                            Capsule()
                                .fill(tint.gradient)
                                .frame(width: max(4, geo.size.width * (presentation.progress(metric) ?? 0)))
                        }
                    }
                    .frame(height: 3.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.7)
                )
            }
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 8) {
            secondaryPill(label: "CPU", value: presentation.value("cpuTemp"), icon: "thermometer.medium")
            secondaryPill(label: "GPU", value: presentation.value("gpuTemp"), icon: "thermometer.medium")
            secondaryPill(label: "CPU W", value: presentation.value("cpuPower"), icon: "bolt.fill")
            secondaryPill(label: "GPU W", value: presentation.value("gpuPower"), icon: "bolt.fill")
            secondaryPill(label: "VRAM", value: presentation.value("vram"), icon: "memorychip")
        }
    }

    private func secondaryPill(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent.opacity(0.85))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            if detailed || island {
                Link(destination: OrbitWidgetStyle.dashboardURL) {
                    Label("App", systemImage: "gauge.with.dots.needle.33percent")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.16), in: Capsule())
                }
                OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                    Label("On", systemImage: "power")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color(red: 0.45, green: 0.96, blue: 0.68))
                }
                .buttonStyle(.plain)
                OrbitProPowerButton(intent: OrbitShutdownPCIntent()) {
                    Label("Off", systemImage: "power.circle.fill")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 2)
                Button(intent: StopOrbitLiveActivityIntent()) {
                    Image(systemName: "xmark.circle.fill")
                        .padding(4)
                        .background(.white.opacity(0.10), in: Circle())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            } else {
                Text(presentation.fresh ? (context.state.gameName ?? "Active session") : presentation.status)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if context.state.showTimestamp != false {
                    Text(context.state.lastUpdated, style: .time)
                }
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(detailed || island ? accent : .white.opacity(0.6))
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct WatchAwareLiveActivityContainer<WatchContent: View, StandardContent: View>: View {
    var context: ActivityViewContext<OrbitActivityAttributes>
    @Environment(\.activityFamily) private var activityFamily
    @ViewBuilder var watchContent: () -> WatchContent
    @ViewBuilder var standardContent: () -> StandardContent

    var body: some View {
        if activityFamily == .small {
            watchContent()
        } else {
            standardContent()
        }
    }
}


// MARK: - Orbit Pro gate for interactive power buttons

/// Runs the power intent with Orbit Pro; without it the same label opens Orbit's upgrade sheet.
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
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(2.5)
                        .background(Color.yellow, in: Circle())
                }
            }
        }
    }
}
