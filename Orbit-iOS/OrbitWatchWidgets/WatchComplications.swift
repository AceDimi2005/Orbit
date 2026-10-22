import SwiftUI
import WidgetKit

// Complication views. Compiled into the widget extension and into the watch app, whose DEBUG
// gallery draws them without a watch face. Each complication shows one fact.

/// One complication's data: the PC, where it stands and its last readings.
struct WatchComplicationEntry: TimelineEntry {
    var date: Date
    var pcName: String
    /// A PC is set up on this watch.
    var isPaired: Bool
    /// The PC answered recently enough to trust the readings.
    var isOnline: Bool
    var isLocked: Bool
    var telemetry: WatchTelemetry
    var updatedAt: Date?
    var tintHex: String = ""

    var status: WatchPCStatus {
        guard isPaired else { return .setup }
        guard isOnline else { return .offline }
        return isLocked ? .locked : .online
    }

    var tint: Color { Color(orbitHex: tintHex) ?? OrbitPalette.accent }

    /// Readings are shown only while the PC is online and reporting them.
    var showsReadings: Bool { status == .online && telemetry.telemetryAvailable != false }

    /// The headline the glance page would show.
    var headline: String { showsReadings ? telemetry.headline : status.title }

    static var sample: WatchComplicationEntry {
        WatchComplicationEntry(
            date: .now, pcName: "Gaming PC", isPaired: true, isOnline: true, isLocked: false,
            telemetry: WatchTelemetry(isOnline: true, cpuUsage: 14, cpuTemp: 46, gpuUsage: 9, gpuTemp: 41,
                                      ramUsedGB: 11, ramTotalGB: 32, telemetryAvailable: true),
            updatedAt: .now)
    }
}

/// The temperature a complication follows.
enum WatchComplicationComponent {
    case processor, graphics

    var shortName: String { self == .processor ? "CPU" : "GPU" }
    var name: String { self == .processor ? "Processor" : "Graphics" }

    func temperature(_ telemetry: WatchTelemetry) -> Double? {
        let value = self == .processor ? telemetry.cpuTemp : telemetry.gpuTemp
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

// MARK: - Tint

extension EnvironmentValues {
    /// DEBUG gallery only: stands in for a tinted watch face, since accented rendering
    /// happens in the face, not in an app. Always nil inside the widget extension.
    @Entry var complicationPreviewTint: Color? = nil
}

extension View {
    /// The part of a complication that takes the face's tint. In full color it uses `color`.
    func complicationAccent(_ color: Color) -> some View {
        modifier(ComplicationAccent(color: color))
    }
}

private struct ComplicationAccent: ViewModifier {
    var color: Color
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.complicationPreviewTint) private var previewTint

    func body(content: Content) -> some View {
        let style = mode == .fullColor ? color : (previewTint ?? color)
        content
            .foregroundStyle(style)
            .tint(style)
            .widgetAccentable()
    }
}

/// Status colors only exist in full color; tinted faces draw them in the primary color.
private struct StatusColor: ViewModifier {
    var color: Color
    @Environment(\.widgetRenderingMode) private var mode

    func body(content: Content) -> some View {
        content.foregroundStyle(mode == .fullColor ? color : .primary)
    }
}

private extension View {
    func complicationStatusColor(_ color: Color) -> some View { modifier(StatusColor(color: color)) }
}

// MARK: - Mark

/// The Orbit mark for complications: the ring stays in the face's primary color and the
/// satellite takes the tint, so tinted faces still tell online, asleep and locked apart
/// (locked adds a small lock, since amber is lost when the face tints everything).
struct WatchComplicationMark: View {
    var status: WatchPCStatus
    var tint: Color

    private var dimmed: Bool { status == .offline }

    private var satelliteColor: Color {
        switch status {
        case .locked: return OrbitPalette.caution
        case .offline: return .white
        default: return tint
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                OrbitRingShape()
                    .stroke(style: StrokeStyle(lineWidth: size * OrbitMarkGeometry.stroke, lineCap: .round))
                    .foregroundStyle(.primary)
                    .opacity(dimmed ? 0.45 : 1)
                Circle()
                    .frame(width: size * OrbitMarkGeometry.satellite * 2, height: size * OrbitMarkGeometry.satellite * 2)
                    .offset(y: -size * OrbitMarkGeometry.radius)
                    .complicationAccent(satelliteColor)
                    .opacity(dimmed ? 0.45 : 1)
                if status == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.27, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Status

/// Whether the PC is on, asleep or locked. The mark is the circular complication.
struct WatchStatusComplication: View {
    var entry: WatchComplicationEntry
    var family: WidgetFamily

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.pcName), \(entry.headline)")
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            WatchComplicationMark(status: entry.status, tint: entry.tint)
                .padding(3)
        case .accessoryCorner:
            WatchComplicationMark(status: entry.status, tint: entry.tint)
                .padding(2)
                .widgetLabel { Text(cornerLabel) }
        case .accessoryInline:
            Text("\(entry.pcName) · \(inlineStatus)")
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    WatchComplicationMark(status: entry.status, tint: entry.tint)
                        .frame(width: 15, height: 15)
                    Text(entry.pcName)
                        .font(.headline)
                        .lineLimit(1)
                        .complicationAccent(entry.tint)
                }
                Text(entry.headline)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var cornerLabel: String {
        switch entry.status {
        case .online: return "PC on"
        case .locked: return "PC locked"
        case .setup: return "Set up"
        default: return "PC asleep"
        }
    }

    /// One word: the inline slot is too short for the takeaway.
    private var inlineStatus: String {
        switch entry.status {
        case .online: return entry.telemetry.isHot ? "Hot" : "Online"
        case .offline: return "Offline"
        case .setup: return "Not set up"
        default: return entry.status.title
        }
    }

    /// The third line: the two glance readings while online, otherwise when Orbit last heard from it.
    private var detail: String {
        if entry.showsReadings {
            return WatchVitals.glance(entry.telemetry).map(Self.compact).joined(separator: " · ")
        }
        switch entry.status {
        case .setup: return "Pair it in Orbit on iPhone"
        case .locked: return "Waiting for your password"
        default:
            guard let updatedAt = entry.updatedAt else { return "Open Orbit to check" }
            return "Seen \(updatedAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// "CPU 46°", "GPU 12%", "118 fps": short enough for one complication line.
    private static func compact(_ vital: OrbitVital) -> String {
        let value = vital.value ?? "—"
        switch vital.kind {
        case .fps: return "\(value) fps"
        case .memory: return "RAM \(value) GB"
        default:
            let name = vital.label == "Processor" ? "CPU" : "GPU"
            return "\(name) \(value)\(vital.unit ?? "")"
        }
    }
}

// MARK: - Temperature

/// One temperature: the processor's or the graphics card's.
struct WatchTemperatureComplication: View {
    var entry: WatchComplicationEntry
    var family: WidgetFamily
    var component: WatchComplicationComponent

    private var value: Double? { entry.showsReadings ? component.temperature(entry.telemetry) : nil }
    private var text: String { value.map { "\(Int($0.rounded()))°" } ?? "—" }
    /// Normal readings take the accent; hot ones turn warm and then red, as everywhere in Orbit.
    private var color: Color { (value ?? 0) >= 80 ? OrbitPalette.temperature(value) : entry.tint }
    private var gaugeValue: Double { min(100, max(20, value ?? 20)) }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(component.name) temperature")
            .accessibilityValue(value.map { "\(Int($0.rounded())) degrees" } ?? "No reading")
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: gaugeValue, in: 20...100) {
                Text(component.shortName)
            } currentValueLabel: {
                Text(text)
                    .monospacedDigit()
                    .complicationStatusColor((value ?? 0) >= 80 ? color : .primary)
            }
            .gaugeStyle(.accessoryCircular)
            .complicationAccent(color)
        case .accessoryCorner:
            Text(text)
                .font(.orbitReading(18))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .complicationStatusColor((value ?? 0) >= 80 ? color : .primary)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: gaugeValue, in: 20...100) {
                        Text(component.shortName)
                    } currentValueLabel: {
                        Text(text)
                    } minimumValueLabel: {
                        Text(component.shortName)
                    } maximumValueLabel: {
                        Text("")
                    }
                    .complicationAccent(color)
                }
        case .accessoryInline:
            Text("\(component.shortName) \(text)")
        default:
            VStack(alignment: .leading, spacing: 0) {
                Text(component.name)
                    .font(.headline)
                    .complicationAccent(entry.tint)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text)
                        .font(.orbitReading(21))
                        .monospacedDigit()
                        .complicationStatusColor((value ?? 0) >= 80 ? color : .primary)
                    Text(value == nil ? subtitle : entry.pcName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Gauge(value: gaugeValue, in: 20...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .complicationAccent(color)
                    .opacity(value == nil ? 0.35 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var subtitle: String {
        switch entry.status {
        case .online: return "No sensor"
        case .locked: return "Locked"
        case .setup: return "No PC yet"
        default: return "Asleep or off"
        }
    }
}

// MARK: - Frame rate

/// The frame rate of the game running on the PC.
struct WatchFrameRateComplication: View {
    var entry: WatchComplicationEntry
    var family: WidgetFamily

    private var game: String? { entry.showsReadings ? entry.telemetry.game : nil }
    private var fps: Int? {
        guard game != nil, let fps = entry.telemetry.fps, fps.isFinite, fps > 0 else { return nil }
        return Int(fps.rounded())
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(game.map { "\($0), frame rate" } ?? "Frame rate")
            .accessibilityValue(fps.map { "\($0) frames per second" } ?? "No game running")
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if let fps {
                    VStack(spacing: -2) {
                        Text("\(fps)")
                            .font(.orbitReading(20))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                        Text("fps")
                            .font(.system(size: 11, weight: .medium))
                            .complicationAccent(entry.tint)
                    }
                    .padding(.horizontal, 4)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 18, weight: .medium))
                        .complicationAccent(entry.tint)
                        .opacity(0.6)
                }
            }
        case .accessoryCorner:
            Group {
                if let fps {
                    Text("\(fps)")
                        .font(.orbitReading(18))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 17, weight: .medium))
                        .complicationAccent(entry.tint)
                }
            }
            .widgetCurvesContent()
            .widgetLabel { Text(fps == nil ? "No game" : "fps") }
        case .accessoryInline:
            if let fps, let game {
                Text("\(fps) fps · \(game)")
            } else {
                Text("No game running")
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(game ?? "Frame Rate")
                    .font(.headline)
                    .lineLimit(1)
                    .complicationAccent(entry.tint)
                if let fps {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(fps)")
                            .font(.orbitReading(26))
                            .monospacedDigit()
                        Text("fps")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No game running")
                        .font(.headline)
                    Text(entry.status == .online ? "Shows while you play" : entry.status.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Control

/// Opens the pointer: the pad, clicks and scrolling.
struct WatchControlComplication: View {
    var entry: WatchComplicationEntry
    var family: WidgetFamily

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: family == .accessoryCorner ? 15 : 19, weight: .semibold))
                .complicationAccent(entry.tint)
        }
        .widgetLabel { Text("Control") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Control \(entry.pcName)")
    }
}
