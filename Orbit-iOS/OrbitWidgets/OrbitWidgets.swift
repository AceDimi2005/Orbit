import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// iOS registers at most ten widgets from one bundle block and silently drops the rest: when the
/// Buttons widget became the tenth entry, the Live Activity (eleventh) lost its descriptor and every
/// activity was ended right after it started ("Activity had no descriptor"). So the activity comes
/// first, and the telemetry widgets live in their own nested bundle. Keep every block at ten or fewer.
@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        OrbitMonitorActivity()
        OrbitShortcutsWidget()
        OrbitDeckWidget()
        OrbitTelemetryWidgets().body
        if #available(iOSApplicationExtension 18.0, *) {
            OrbitWakeControlCenterWidget()
            OrbitShutdownControlCenterWidget()
            OrbitSleepControlCenterWidget()
            OrbitDeckControl()
        }
    }
}

/// The eight telemetry widgets, nested so the main bundle stays under the ten-widget limit.
struct OrbitTelemetryWidgets: WidgetBundle {
    var body: some Widget {
        OrbitOverviewWidget()
        OrbitGamingWidget()
        OrbitPowerWidget()
        OrbitThermalWidget()
        OrbitCoolingWidget()
        OrbitStorageWidget()
        OrbitNetworkWidget()
        OrbitMetricWidget()
    }
}

// MARK: - Shared look

enum OrbitWidgetStyle {
    static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let base = Color(red: 0.025, green: 0.03, blue: 0.045)
    static let dashboardURL = URL(string: "orbit://dashboard")!
    static let remoteURL = URL(string: "orbit://remote")!
    static let live = Color(red: 0.30, green: 0.92, blue: 0.62)
    static let caution = Color(red: 1.0, green: 0.74, blue: 0.32)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
}

/// Widget background: the theme's dark base with a soft light from the top-left corner.
struct OrbitWidgetBackdrop: View {
    var accent: Color = OrbitWidgetStyle.accent
    var base: Color = OrbitWidgetStyle.base

    var body: some View {
        ZStack {
            base
            RadialGradient(colors: [accent.opacity(0.22), accent.opacity(0)], center: UnitPoint(x: 0.04, y: 0), startRadius: 0, endRadius: 230)
            LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

/// The Orbit mark, a title and an optional trailing status.
struct OrbitWidgetHeader<Trailing: View>: View {
    var title: String
    var accent: Color
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            OrbitBrandMark(tint: accent)
                .frame(width: 15, height: 15)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

extension OrbitWidgetHeader where Trailing == EmptyView {
    init(title: String, accent: Color) {
        self.init(title: title, accent: accent) { EmptyView() }
    }
}

// MARK: - Power buttons (Orbit Pro)

enum OrbitPowerAction {
    case wake, sleep, shutdown

    var title: String {
        switch self {
        case .wake: "Power On"
        case .sleep: "Sleep"
        case .shutdown: "Shut Down"
        }
    }

    var subtitle: String {
        switch self {
        case .wake: "Wake-on-LAN"
        case .sleep: "Standby"
        case .shutdown: "Turn off"
        }
    }

    var symbol: String {
        switch self {
        case .wake: "power"
        case .sleep: "moon.zzz.fill"
        case .shutdown: "power.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .wake: OrbitWidgetStyle.live
        case .sleep: OrbitWidgetStyle.caution
        case .shutdown: OrbitWidgetStyle.danger
        }
    }
}

/// Runs a power action with Orbit Pro; without it the same label opens the Orbit Pro sheet and is drawn
/// as locked (`content(true)`).
struct OrbitPowerGate<Content: View>: View {
    var action: OrbitPowerAction
    var pcID: String? = nil
    @ViewBuilder var content: (_ locked: Bool) -> Content

    var body: some View {
        if OrbitProEntitlement.cachedIsUnlocked {
            switch action {
            case .wake:
                Button(intent: OrbitWidgetWakePCIntent(pcID: pcID)) { content(false) }.buttonStyle(.plain)
            case .sleep:
                Button(intent: OrbitWidgetSleepPCIntent(pcID: pcID)) { content(false) }.buttonStyle(.plain)
            case .shutdown:
                Button(intent: OrbitWidgetShutdownPCIntent(pcID: pcID)) { content(false) }.buttonStyle(.plain)
            }
        } else {
            Link(destination: OrbitProEntitlement.upgradeURL) { content(true) }
        }
    }
}

/// A capsule power button: icon and title in the action's colour, or a lock while Orbit Pro is off.
struct OrbitPowerPill: View {
    var action: OrbitPowerAction
    var compact = false
    var pcID: String? = nil
    var showsTitle = true

    var body: some View {
        OrbitPowerGate(action: action, pcID: pcID) { locked in
            HStack(spacing: 5) {
                Image(systemName: locked ? "lock.fill" : action.symbol)
                    .font(.system(size: compact ? 10 : 11, weight: .bold))
                if showsTitle {
                    Text(action.title)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(locked ? Color.white.opacity(0.6) : action.tint)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 28 : 32)
            .background((locked ? Color.white.opacity(0.07) : action.tint.opacity(0.16)), in: Capsule())
            .overlay(Capsule().strokeBorder(locked ? Color.white.opacity(0.1) : action.tint.opacity(0.32), lineWidth: 0.7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(locked ? "\(action.title), needs Orbit Pro" : action.title)
        }
    }
}

/// A square power tile with a round icon, title and subtitle (Power & Quick Controls widget).
struct OrbitPowerTile: View {
    var action: OrbitPowerAction
    var showsSubtitle = true

    var body: some View {
        OrbitPowerGate(action: action) { locked in
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: locked ? "lock.fill" : action.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(locked ? Color.white.opacity(0.6) : action.tint)
                    .frame(width: 30, height: 30)
                    .background((locked ? Color.white.opacity(0.08) : action.tint.opacity(0.18)), in: Circle())
                Spacer(minLength: 6)
                Text(action.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if showsSubtitle {
                    Text(locked ? "Orbit Pro" : action.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder((locked ? Color.white : action.tint).opacity(locked ? 0.08 : 0.24), lineWidth: 0.8)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(locked ? "\(action.title), needs Orbit Pro" : action.title)
        }
    }
}

/// A full-width power row with a round icon, title and subtitle (small Power & Quick Controls widget,
/// where two square tiles side by side would cut "Power On" and "Shut Down" short).
struct OrbitPowerRow: View {
    var action: OrbitPowerAction

    var body: some View {
        OrbitPowerGate(action: action) { locked in
            HStack(spacing: 9) {
                Image(systemName: locked ? "lock.fill" : action.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(locked ? Color.white.opacity(0.6) : action.tint)
                    .frame(width: 28, height: 28)
                    .background((locked ? Color.white.opacity(0.08) : action.tint.opacity(0.18)), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(action.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(locked ? "Orbit Pro" : action.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder((locked ? Color.white : action.tint).opacity(locked ? 0.08 : 0.24), lineWidth: 0.8)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(locked ? "\(action.title), needs Orbit Pro" : action.title)
        }
    }
}

/// Runs the power intent with Orbit Pro; without it the same label opens Orbit's upgrade sheet.
/// Prefer `OrbitPowerGate`, which lets the label draw its own locked state.
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
                label
                    .opacity(0.7)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(3)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    }
            }
        }
    }
}

// MARK: - Power & Quick Controls widget

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
                .containerBackground(for: .widget) { OrbitWidgetBackdrop() }
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
            OrbitPowerGate(action: .wake) { locked in
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: locked ? "lock.fill" : "power")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .accessibilityLabel("Power On PC with Orbit")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    OrbitBrandMark(tint: .white, ring: .white, glow: false)
                        .frame(width: 12, height: 12)
                    Text(entry.pcName)
                        .lineLimit(1)
                }
                .font(.caption.weight(.bold))
                HStack(spacing: 8) {
                    OrbitPowerGate(action: .wake) { locked in
                        Label("Wake", systemImage: locked ? "lock.fill" : "power")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    OrbitPowerGate(action: .shutdown) { locked in
                        Label("Off", systemImage: locked ? "lock.fill" : "power.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
        case .systemMedium:
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(spacing: 8) {
                    OrbitPowerTile(action: .wake)
                    OrbitPowerTile(action: .sleep)
                    OrbitPowerTile(action: .shutdown)
                }
                HStack(spacing: 8) {
                    shortcutPill("Overview", symbol: "gauge.with.dots.needle.33percent", url: OrbitWidgetStyle.dashboardURL)
                    shortcutPill("Remote", symbol: "computermouse.fill", url: OrbitWidgetStyle.remoteURL)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 7) {
                header
                OrbitPowerRow(action: .wake)
                OrbitPowerRow(action: .shutdown)
            }
        }
    }

    private var header: some View {
        OrbitWidgetHeader(title: entry.pcName, accent: OrbitWidgetStyle.accent) {
            if let feedback = entry.feedback {
                Text(feedback)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(OrbitWidgetStyle.live)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func shortcutPill(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OrbitWidgetStyle.accent)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
        }
    }
}

// MARK: - iOS 18+ Control Center, Lock Screen & Action Button Controls

@available(iOSApplicationExtension 18.0, *)
struct OrbitWakeControlCenterWidget: ControlWidget {
    static let kind: String = "com.dimitrie.orbit.control.wake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OrbitWidgetWakePCIntent()) {
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
            ControlWidgetButton(action: OrbitWidgetShutdownPCIntent()) {
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
            ControlWidgetButton(action: OrbitWidgetSleepPCIntent()) {
                Label("Sleep PC", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Sleep PC")
        .description("Puts your paired Windows PC into sleep mode from Control Center.")
    }
}
