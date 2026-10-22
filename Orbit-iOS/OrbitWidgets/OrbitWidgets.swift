import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        OrbitOverviewWidget()
        OrbitGamingWidget()
        OrbitThermalWidget()
        OrbitPowerWidget()
        OrbitCoolingWidget()
        OrbitStorageWidget()
        OrbitNetworkWidget()
        OrbitMetricWidget()
        OrbitShortcutsWidget()
        OrbitMonitorActivity()
        OrbitWakeControlCenterWidget()
        OrbitSleepControlCenterWidget()
        OrbitShutdownControlCenterWidget()
    }
}

// MARK: - Power buttons

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
            OrbitPowerButtonsView(entry: entry)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) { OrbitPalette.surface }
        }
        .configurationDisplayName("Power Buttons")
        .description("Wake, sleep or shut down your PC. Comes with Orbit Pro.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// Wake comes first and takes the accent; sleep and shut down sit beside it, quieter.
private struct OrbitPowerButtonsView: View {
    var entry: ShortcutEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .accessoryCircular:
            OrbitProPowerButton(intent: OrbitWakePCIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "power")
                        .font(.system(size: 22, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wake \(entry.pcName)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    OrbitWidgetMark(status: .online, size: 12)
                    Text(entry.pcName)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    accessoryButton("Wake", systemImage: "power", intent: OrbitWakePCIntent())
                    accessoryButton("Sleep", systemImage: "moon", intent: OrbitSleepPCIntent())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    tile("Wake", systemImage: "power", prominent: true, intent: OrbitWakePCIntent())
                    tile("Sleep", systemImage: "moon", prominent: false, intent: OrbitSleepPCIntent())
                    tile("Shut Down", systemImage: "power.circle", prominent: false, intent: OrbitShutdownPCIntent())
                }
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 8)
                wide("Wake", systemImage: "power", prominent: true, intent: OrbitWakePCIntent())
                HStack(spacing: 8) {
                    compact("Sleep", systemImage: "moon", intent: OrbitSleepPCIntent())
                    compact("Shut Down", systemImage: "power.circle", intent: OrbitShutdownPCIntent())
                }
                .padding(.top, 8)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                OrbitWidgetMark(status: .online, size: 15)
                Text(entry.pcName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let feedback = entry.feedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var quietFill: Color {
        renderingMode == .fullColor ? OrbitPalette.well : Color.primary.opacity(0.14)
    }

    private func fill(prominent: Bool) -> some View {
        ContainerRelativeShape()
            .fill(prominent ? OrbitPalette.accent : quietFill)
            .widgetAccentable(prominent)
    }

    private func wide<I: AppIntent>(_ title: String, systemImage: String, prominent: Bool, intent: I) -> some View {
        OrbitProPowerButton(intent: intent) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background { fill(prominent: prominent) }
        }
        .buttonStyle(.plain)
    }

    private func compact<I: AppIntent>(_ title: String, systemImage: String, intent: I) -> some View {
        OrbitProPowerButton(intent: intent) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background { fill(prominent: false) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func tile<I: AppIntent>(_ title: String, systemImage: String, prominent: Bool, intent: I) -> some View {
        OrbitProPowerButton(intent: intent) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { fill(prominent: prominent) }
        }
        .buttonStyle(.plain)
    }

    private func accessoryButton<I: AppIntent>(_ title: String, systemImage: String, intent: I) -> some View {
        OrbitProPowerButton(intent: intent) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Control Center, Lock Screen and Action button

struct OrbitWakeControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.wake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitWakePCIntent()) {
                Label("Wake PC", systemImage: "power")
            }
        }
        .displayName("Wake PC")
        .description("Turns on your PC over the network. Comes with Orbit Pro.")
    }
}

struct OrbitSleepControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.sleep"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitSleepPCIntent()) {
                Label("Sleep PC", systemImage: "moon")
            }
        }
        .displayName("Sleep PC")
        .description("Puts your PC to sleep. Comes with Orbit Pro.")
    }
}

struct OrbitShutdownControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.shutdown"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitShutdownPCIntent()) {
                Label("Shut Down PC", systemImage: "power.circle")
            }
        }
        .displayName("Shut Down PC")
        .description("Shuts down your PC. Comes with Orbit Pro.")
    }
}

// MARK: - Live Activity

struct OrbitMonitorActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitActivityAttributes.self) { context in
            OrbitActivityContent(context: context)
                .activityBackgroundTint(Color.black.opacity(0.62))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "orbit://dashboard"))
        } dynamicIsland: { context in
            let snapshot = OrbitActivitySnapshot(pcName: context.attributes.pcName, state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbitWidgetMark(status: snapshot.markStatus, size: 34, accent: snapshot.accent)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OrbitActivityExpandedTrailing(snapshot: snapshot)
                        .padding(.trailing, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(snapshot.headline)
                            .font(.headline)
                            .lineLimit(1)
                        Text(snapshot.subline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !snapshot.readings.isEmpty {
                        OrbitGlanceReadingsRow(readings: snapshot.readings, valueSize: 22, accent: snapshot.accent)
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                    }
                }
            } compactLeading: {
                OrbitActivityCompactLeading(snapshot: snapshot)
                    .padding(.leading, 2)
            } compactTrailing: {
                OrbitActivityCompactTrailing(snapshot: snapshot)
                    .padding(.trailing, 2)
            } minimal: {
                OrbitWidgetMark(status: snapshot.markStatus, size: 18, accent: snapshot.accent)
            }
            .widgetURL(URL(string: "orbit://dashboard"))
            .keylineTint(snapshot.accent)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen, or the Smart Stack on Apple Watch.
private struct OrbitActivityContent: View {
    var context: ActivityViewContext<OrbitActivityAttributes>
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        let snapshot = OrbitActivitySnapshot(pcName: context.attributes.pcName, state: context.state, isStale: context.isStale)
        if activityFamily == .small {
            OrbitActivitySmall(snapshot: snapshot)
        } else {
            OrbitActivityLockScreen(snapshot: snapshot)
        }
    }
}

/// Apple Watch's Smart Stack: the mark and the takeaway, then two readings.
private struct OrbitActivitySmall: View {
    var snapshot: OrbitActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                OrbitWidgetMark(status: snapshot.markStatus, size: 16, accent: snapshot.accent)
                Text(snapshot.headline)
                    .font(.headline)
                    .lineLimit(1)
            }
            if snapshot.readings.isEmpty {
                Text(snapshot.subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                OrbitGlanceReadingsRow(readings: Array(snapshot.readings.prefix(2)), valueSize: 22, showsMeters: false, accent: snapshot.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

/// Right of the camera when expanded: Wake while the PC is off, else the frame rate while
/// a game runs, the reading you chose, or the time of the reading.
private struct OrbitActivityExpandedTrailing: View {
    var snapshot: OrbitActivitySnapshot

    var body: some View {
        if !snapshot.state.isConnected {
            OrbitWakeButton(accent: snapshot.accent)
        } else if let reading = snapshot.chosenReading ?? snapshot.compactFrameRate {
            VStack(alignment: .trailing, spacing: 0) {
                OrbitGlanceValue(reading: reading, size: 26)
                Text(reading.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else if snapshot.isLive, snapshot.state.showTimestamp != false {
            Text(snapshot.state.lastUpdated, style: .time)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
