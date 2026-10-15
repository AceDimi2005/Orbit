import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        OrbitShortcutsWidget()
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(context.attributes.pcName, systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    freshness(context)
                }
                readings(context)
                HStack {
                    Text(context.state.gameName ?? "PC monitoring")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(context.state.lastUpdated, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(OrbitWidgetStyle.background)
            .activitySystemActionForegroundColor(OrbitWidgetStyle.accent)
            .widgetURL(OrbitWidgetStyle.dashboardURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.pcName, systemImage: "desktopcomputer")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(OrbitWidgetStyle.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    freshness(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        readings(context)
                        HStack {
                            Text(context.state.gameName ?? "PC monitoring").lineLimit(1)
                            Spacer(minLength: 8)
                            Text(context.state.lastUpdated, style: .time)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(OrbitWidgetStyle.accent)
            } compactTrailing: {
                if !context.state.isConnected || context.isStale {
                    Image(systemName: "pause.fill").foregroundStyle(.secondary)
                } else if let fps = context.state.fps {
                    Text("\(Int(fps.rounded()))").monospacedDigit().foregroundStyle(OrbitWidgetStyle.accent)
                } else {
                    Text(percent(context.state.cpuUsage)).monospacedDigit().foregroundStyle(OrbitWidgetStyle.accent)
                }
            } minimal: {
                Image(systemName: context.isStale || !context.state.isConnected ? "pause.circle" : "desktopcomputer")
                    .foregroundStyle(OrbitWidgetStyle.accent)
            }
            .widgetURL(OrbitWidgetStyle.dashboardURL)
            .keylineTint(OrbitWidgetStyle.accent)
        }
    }

    private func freshness(_ context: ActivityViewContext<OrbitActivityAttributes>) -> some View {
        let text = !context.state.isConnected ? "Offline" : (context.isStale ? "Open to refresh" : "Updated")
        return Label(text, systemImage: context.isStale || !context.state.isConnected ? "pause.circle" : "checkmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(context.isStale || !context.state.isConnected ? .gray : OrbitWidgetStyle.accent)
    }

    private func readings(_ context: ActivityViewContext<OrbitActivityAttributes>) -> some View {
        let fresh = context.state.isConnected && !context.isStale
        return HStack(spacing: 12) {
            reading("CPU", value: fresh ? percent(context.state.cpuUsage) : "—")
            reading("GPU", value: fresh ? percent(context.state.gpuUsage) : "—")
            reading("RAM", value: fresh ? percent(context.state.ramUsage) : "—")
            if let fps = context.state.fps {
                reading("FPS", value: fresh ? String(Int(fps.rounded())) : "—")
            }
        }
    }

    private func reading(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}
