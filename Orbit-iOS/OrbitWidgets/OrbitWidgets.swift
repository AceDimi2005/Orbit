import ActivityKit
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
        OrbitMonitorActivity()
    }
}

private enum OrbitWidgetStyle {
    static let accent = Color(red: 0.25, green: 0.84, blue: 0.96)
    static let background = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let dashboardURL = URL(string: "orbit://dashboard")!
}

private struct ShortcutEntry: TimelineEntry {
    var date: Date
}

private struct ShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutEntry { ShortcutEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ShortcutEntry) -> Void) {
        completion(ShortcutEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShortcutEntry>) -> Void) {
        completion(Timeline(entries: [ShortcutEntry(date: Date())], policy: .never))
    }
}

struct OrbitShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OrbitShortcuts", provider: ShortcutProvider()) { _ in
            OrbitShortcutsView()
                .containerBackground(OrbitWidgetStyle.background.gradient, for: .widget)
        }
        .configurationDisplayName("Orbit controls")
        .description("Open your dashboard, remote, or Wake-on-LAN controls. Live PC readings are available in the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct OrbitShortcutsView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .widgetURL(OrbitWidgetStyle.dashboardURL)
                .accessibilityLabel("Open Orbit PC dashboard")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                Label("Orbit", systemImage: "desktopcomputer")
                    .font(.headline)
                Text("Open PC controls").font(.caption)
            }
            .widgetURL(OrbitWidgetStyle.dashboardURL)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(spacing: 8) {
                    shortcut("Monitor", symbol: "waveform.path.ecg", route: "dashboard")
                    shortcut("Remote", symbol: "computermouse", route: "remote")
                    shortcut("Wake PC", symbol: "power", route: "wake")
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                header
                Spacer(minLength: 0)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(OrbitWidgetStyle.accent)
                Text("Your PC, closer.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Open dashboard ↗")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .widgetURL(OrbitWidgetStyle.dashboardURL)
        }
    }

    private var header: some View {
        HStack {
            Label("ORBIT", systemImage: "circle.hexagongrid.fill")
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(OrbitWidgetStyle.accent)
            Spacer()
            if family == .systemMedium {
                Text("PC COMPANION")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func shortcut(_ title: String, symbol: String, route: String) -> some View {
        Link(destination: URL(string: "orbit://\(route)")!) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(OrbitWidgetStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct OrbitMonitorActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitActivityAttributes.self) { context in
            OrbitLiveActivityPanel(context: context)
                .activityBackgroundTint(OrbitWidgetTheme(rawValue: context.state.accent ?? "ocean")?.background ?? OrbitWidgetStyle.background)
                .activitySystemActionForegroundColor(accent(context))
                .widgetURL(OrbitWidgetStyle.dashboardURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.pcName, systemImage: "desktopcomputer")
                        .font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(accent(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(OrbitActivityPresentation(context).status)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OrbitLiveActivityPanel(context: context, island: true)
                }
            } compactLeading: {
                Image(systemName: OrbitActivityPresentation(context).primarySymbol)
                    .foregroundStyle(accent(context))
            } compactTrailing: {
                let view = OrbitActivityPresentation(context)
                if view.fresh {
                    Text(view.primaryValue).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(accent(context))
                } else {
                    Image(systemName: "pause.fill").foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: OrbitActivityPresentation(context).fresh ? "desktopcomputer" : "pause.circle")
                    .foregroundStyle(accent(context))
            }
            .widgetURL(OrbitWidgetStyle.dashboardURL)
            .keylineTint(accent(context))
        }
    }
    private func accent(_ context: ActivityViewContext<OrbitActivityAttributes>) -> Color {
        OrbitWidgetTheme(rawValue: context.state.accent ?? "ocean")?.accent ?? OrbitWidgetStyle.accent
    }
}

private struct OrbitActivityPresentation {
    var context: ActivityViewContext<OrbitActivityAttributes>
    init(_ context: ActivityViewContext<OrbitActivityAttributes>) { self.context = context }
    var state: OrbitActivityAttributes.ContentState { context.state }
    var fresh: Bool { state.isConnected && state.telemetryAvailable != false && state.isPaused != true && !context.isStale }
    var status: String {
        if !state.isConnected { return "Offline" }
        if state.isPaused == true || context.isStale { return "Open to refresh" }
        if state.telemetryAvailable == false { return "Waiting for sensors" }
        return "Updated"
    }
    var primary: String {
        if let metric = state.primaryMetric, metric != "automatic" { return metric }
        switch state.focus {
        case "gaming": return "fps"
        case "power": return "gpuPower"
        default: return "cpu"
        }
    }
    var primarySymbol: String {
        switch primary {
        case "fps": "gamecontroller"
        case "gpu", "vram": "square.stack.3d.up"
        case "ram": "memorychip"
        case "cpuPower", "gpuPower": "bolt.fill"
        default: "cpu"
        }
    }
    var primaryValue: String { value(primary) }
    var primaryTitle: String { title(primary) }
    var metrics: [String] {
        switch state.focus {
        case "gaming": ["fps", "vram", "gpu"]
        case "power": ["cpuPower", "gpuPower", "gpu"]
        default: ["cpu", "gpu", "ram"]
        }
    }
    func title(_ metric: String) -> String {
        switch metric {
        case "cpu": "CPU"
        case "gpu": "GPU"
        case "ram": "RAM"
        case "fps": "Game FPS"
        case "cpuPower": "CPU power"
        case "gpuPower": "GPU power"
        case "vram": "VRAM"
        default: "PC"
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
        case "vram": return state.vramUsedGB.map { String(format: "%.1f GB", $0) } ?? "—"
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
    private var accent: Color { OrbitWidgetTheme(rawValue: context.state.accent ?? "ocean")?.accent ?? OrbitWidgetStyle.accent }
    private var detailed: Bool { context.state.style == "detailed" }
    private var minimal: Bool { context.state.style == "minimal" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !island {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(accent)
                    Text(context.attributes.pcName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(presentation.status).font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            if minimal {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(presentation.primaryValue).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accent)
                    Text(presentation.primaryTitle).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(presentation.metrics, id: \.self) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.title(metric)).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.65))
                            Text(presentation.value(metric)).font(.system(.title3, design: .rounded, weight: .semibold))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if context.state.showGame != false || context.state.showTimestamp != false {
                HStack(spacing: 8) {
                    if context.state.showGame != false {
                        Text(presentation.fresh ? context.state.gameName ?? "PC monitoring" : "Open Orbit for fresh readings")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if context.state.showTimestamp != false { Text(context.state.lastUpdated, style: .time) }
                }.font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
            if detailed || island {
                HStack(spacing: 14) {
                    Link(destination: OrbitWidgetStyle.dashboardURL) {
                        Label("Open Orbit", systemImage: "arrow.up.right")
                    }
                    Spacer()
                    Button(intent: StopOrbitLiveActivityIntent()) { Label("Stop", systemImage: "stop.circle") }
                        .buttonStyle(.plain)
                }.font(.caption.weight(.semibold)).foregroundStyle(accent)
            }
        }
        .foregroundStyle(.white)
        .padding(island ? 6 : 16)
    }
}
