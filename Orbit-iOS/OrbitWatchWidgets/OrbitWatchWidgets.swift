import AppIntents
import SwiftUI
import WidgetKit

@main
struct OrbitWatchWidgets: WidgetBundle {
    var body: some Widget {
        OrbitWatchTelemetryWidget()
        OrbitWatchPowerWidget()
        OrbitWatchAirMouseWidget()
    }
}

private enum WatchWidgetPalette {
    static let accent = Color(red: 0.25, green: 0.84, blue: 0.96)
    static let purple = Color(red: 0.71, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.94, blue: 0.66)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.48)
    static let background = Color(red: 0.04, green: 0.06, blue: 0.11)
}

struct WatchTelemetryEntry: TimelineEntry {
    var date: Date
    var pcName: String
    var isOnline: Bool
    var cpuUsage: Double
    var cpuTemp: Double?
    var gpuUsage: Double?
    var gpuTemp: Double?
    var ramUsage: Double
    var fps: Double?
    var activeGame: String?
    var powerFeedback: String?

    static var placeholder: WatchTelemetryEntry {
        WatchTelemetryEntry(
            date: Date(),
            pcName: "Gaming PC",
            isOnline: true,
            cpuUsage: 28,
            cpuTemp: 52,
            gpuUsage: 46,
            gpuTemp: 59,
            ramUsage: 42,
            fps: 120,
            activeGame: nil,
            powerFeedback: nil
        )
    }
}

struct WatchTelemetryProvider: TimelineProvider {
    private static let appGroupID = "group.com.dimitrie.orbit"
    private static let snapshotKey = "Orbit.WatchSnapshot.v1"

    func placeholder(in context: Context) -> WatchTelemetryEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchTelemetryEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchTelemetryEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadEntry() -> WatchTelemetryEntry {
        let store = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let defaultName = OrbitWidgetConnectionStore.defaultConnection()?.name ?? "Your PC"
        let feedback = OrbitWidgetConnectionStore.recentPowerFeedback()

        guard let snap = store.dictionary(forKey: Self.snapshotKey) ?? UserDefaults.standard.dictionary(forKey: Self.snapshotKey) else {
            return WatchTelemetryEntry(
                date: Date(),
                pcName: defaultName,
                isOnline: false,
                cpuUsage: 0,
                cpuTemp: nil,
                gpuUsage: nil,
                gpuTemp: nil,
                ramUsage: 0,
                fps: nil,
                activeGame: nil,
                powerFeedback: feedback
            )
        }

        let ct = snap["cpuTemp"] as? Double ?? -1
        let gu = snap["gpuUsage"] as? Double ?? -1
        let gt = snap["gpuTemp"] as? Double ?? -1
        let f = snap["fps"] as? Double ?? -1
        let game = snap["activeGame"] as? String ?? ""

        return WatchTelemetryEntry(
            date: Date(),
            pcName: snap["pcName"] as? String ?? defaultName,
            isOnline: snap["isOnline"] as? Bool ?? false,
            cpuUsage: snap["cpuUsage"] as? Double ?? 0,
            cpuTemp: ct >= 0 ? ct : nil,
            gpuUsage: gu >= 0 ? gu : nil,
            gpuTemp: gt >= 0 ? gt : nil,
            ramUsage: snap["ramUsagePercent"] as? Double ?? 0,
            fps: f > 0 ? f : nil,
            activeGame: game.isEmpty ? nil : game,
            powerFeedback: feedback
        )
    }
}

// MARK: - 1. Watch Telemetry Complication & Smart Stack Card

struct OrbitWatchTelemetryWidget: Widget {
    let kind: String = "OrbitWatchTelemetry"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTelemetryProvider()) { entry in
            OrbitWatchTelemetryComplicationView(entry: entry)
                .containerBackground(WatchWidgetPalette.background.gradient, for: .widget)
        }
        .configurationDisplayName("Orbit PC Telemetry")
        .description("Live CPU, GPU, RAM, temperatures, and FPS on your Watch Face or Smart Stack.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

private struct OrbitWatchTelemetryComplicationView: View {
    var entry: WatchTelemetryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: entry.isOnline ? min(100, max(0, entry.cpuUsage)) : 0, in: 0...100) {
                Text("CPU")
            } currentValueLabel: {
                Text(entry.isOnline ? "\(Int(entry.cpuUsage.rounded()))%" : "OFF")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(WatchWidgetPalette.accent.gradient)
            .widgetURL(URL(string: "orbitwatch://cockpit"))

        case .accessoryCorner:
            Text(entry.isOnline ? "\(Int(entry.cpuUsage.rounded()))%" : "OFF")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(WatchWidgetPalette.accent)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: entry.isOnline ? min(100, max(0, entry.gpuUsage ?? entry.cpuUsage)) : 0, in: 0...100) {
                        Text("GPU")
                    } currentValueLabel: {
                        Text(entry.gpuTemp.map { "\(Int($0.rounded()))°" } ?? "PC")
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(WatchWidgetPalette.purple)
                }
                .widgetURL(URL(string: "orbitwatch://cockpit"))

        case .accessoryInline:
            if entry.isOnline {
                if let fps = entry.fps {
                    Text("\(entry.pcName) · \(Int(entry.cpuUsage.rounded()))% · \(Int(fps.rounded())) FPS")
                } else {
                    Text("\(entry.pcName) · CPU \(Int(entry.cpuUsage.rounded()))% · GPU \(Int((entry.gpuUsage ?? 0).rounded()))%")
                }
            } else {
                Text("\(entry.pcName) · Offline")
            }

        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.isOnline ? WatchWidgetPalette.mint : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(entry.pcName)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let fps = entry.fps, entry.isOnline {
                        Text("\(Int(fps.rounded())) FPS")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(WatchWidgetPalette.mint)
                    } else {
                        Text(entry.isOnline ? "LIVE" : "OFF")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    watchStatPill("CPU", value: entry.isOnline ? "\(Int(entry.cpuUsage.rounded()))%" : "—", tint: WatchWidgetPalette.accent)
                    watchStatPill("GPU", value: entry.isOnline && entry.gpuUsage != nil ? "\(Int((entry.gpuUsage ?? 0).rounded()))%" : "—", tint: WatchWidgetPalette.purple)
                    watchStatPill("RAM", value: entry.isOnline ? "\(Int(entry.ramUsage.rounded()))%" : "—", tint: WatchWidgetPalette.mint)
                }
            }
            .widgetURL(URL(string: "orbitwatch://cockpit"))
        }
    }

    private func watchStatPill(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 2. Watch Power & Shut Down Complication

struct OrbitWatchPowerWidget: Widget {
    let kind: String = "OrbitWatchPower"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTelemetryProvider()) { entry in
            OrbitWatchPowerComplicationView(entry: entry)
                .containerBackground(WatchWidgetPalette.background.gradient, for: .widget)
        }
        .configurationDisplayName("Orbit Power & Shut Down")
        .description("Wake-on-LAN Power On, Sleep, and Shut Down buttons right on your Watch Face and Smart Stack.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

private struct OrbitWatchPowerComplicationView: View {
    var entry: WatchTelemetryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: OrbitWakePCIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(WatchWidgetPalette.mint)
                }
            }
            .buttonStyle(.plain)

        case .accessoryCorner:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WatchWidgetPalette.mint)
            }
            .widgetLabel {
                Text(entry.pcName)
            }
            .widgetURL(URL(string: "orbitwatch://power"))

        default:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WatchWidgetPalette.accent)
                    Text(entry.pcName)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    if let feedback = entry.powerFeedback {
                        Text(feedback)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(WatchWidgetPalette.mint)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 5) {
                    Button(intent: OrbitWakePCIntent()) {
                        Label("On", systemImage: "power")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(WatchWidgetPalette.mint.opacity(0.22), in: Capsule())
                            .foregroundStyle(WatchWidgetPalette.mint)
                    }
                    .buttonStyle(.plain)

                    Button(intent: OrbitSleepPCIntent()) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.22), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)

                    Button(intent: OrbitShutdownPCIntent()) {
                        Label("Off", systemImage: "power.circle.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(WatchWidgetPalette.coral.opacity(0.22), in: Capsule())
                            .foregroundStyle(WatchWidgetPalette.coral)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 3. Watch Wrist Air Mouse Quick Launch Complication

struct OrbitWatchAirMouseWidget: Widget {
    let kind: String = "OrbitWatchAirMouse"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTelemetryProvider()) { entry in
            OrbitWatchAirMouseComplicationView(entry: entry)
                .containerBackground(WatchWidgetPalette.background.gradient, for: .widget)
        }
        .configurationDisplayName("Orbit Wrist Air Mouse")
        .description("Quickly open the Apple Watch Gyro Air Mouse & Trackpad to control your PC cursor.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

private struct OrbitWatchAirMouseComplicationView: View {
    var entry: WatchTelemetryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "gyroscope")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(WatchWidgetPalette.accent)
        }
        .widgetLabel {
            Text("Air Mouse")
        }
        .widgetURL(URL(string: "orbitwatch://cursor"))
    }
}
