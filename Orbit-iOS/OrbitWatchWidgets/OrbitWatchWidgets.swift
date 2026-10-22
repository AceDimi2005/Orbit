import SwiftUI
import WidgetKit

/// Complications and Smart Stack widgets. Each shows one fact; tapping opens the page of the
/// watch app where you act on it. Power actions are never one tap away on a watch face.
@main
struct OrbitWatchWidgets: WidgetBundle {
    var body: some Widget {
        OrbitWatchStatusWidget()
        OrbitWatchProcessorTemperatureWidget()
        OrbitWatchGraphicsTemperatureWidget()
        OrbitWatchFrameRateWidget()
        OrbitWatchControlWidget()
    }
}

// MARK: - Timeline

/// Reads the snapshot the watch app saves after every poll. The watch only hears from the PC
/// while the app runs, so a snapshot older than `freshness` is shown as last seen, not live.
struct WatchComplicationProvider: TimelineProvider {
    private static let appGroupID = "group.com.dimitrie.orbit"
    private static let snapshotKey = "Orbit.WatchSnapshot.v1"
    private static let freshness: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> WatchComplicationEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(context.isPreview ? .sample : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        let now = Date()
        var entries = [entry(at: now)]
        // Turn into "last seen" by itself once the reading is too old to trust.
        if let updatedAt = entries[0].updatedAt, entries[0].isOnline {
            let stale = updatedAt.addingTimeInterval(Self.freshness)
            if stale > now { entries.append(entry(at: stale)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.freshness))))
    }

    private func entry(at date: Date) -> WatchComplicationEntry {
        let store = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let fallbackName = OrbitWidgetConnectionStore.defaultConnection()?.name ?? "Your PC"
        guard let snapshot = store.dictionary(forKey: Self.snapshotKey)
                ?? UserDefaults.standard.dictionary(forKey: Self.snapshotKey) else {
            return WatchComplicationEntry(date: date, pcName: fallbackName,
                                          isPaired: OrbitWidgetConnectionStore.defaultConnection() != nil,
                                          isOnline: false, isLocked: false, telemetry: WatchTelemetry(), updatedAt: nil)
        }
        func reading(_ key: String) -> Double? {
            guard let value = snapshot[key] as? Double, value >= 0 else { return nil }
            return value
        }
        let timestamp = snapshot["timestamp"] as? Double ?? 0
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        let fresh = updatedAt.map { date.timeIntervalSince($0) < Self.freshness } ?? false
        let isOnline = (snapshot["isOnline"] as? Bool ?? false) && fresh
        let game = snapshot["activeGame"] as? String ?? ""
        let telemetry = WatchTelemetry(
            isOnline: isOnline,
            cpuUsage: snapshot["cpuUsage"] as? Double ?? 0,
            cpuTemp: reading("cpuTemp"),
            gpuUsage: reading("gpuUsage"),
            gpuTemp: reading("gpuTemp"),
            ramUsedGB: snapshot["ramUsedGB"] as? Double ?? 0,
            ramTotalGB: snapshot["ramTotalGB"] as? Double ?? 0,
            activeGame: game.isEmpty ? nil : game,
            fps: reading("fps").flatMap { $0 > 0 ? $0 : nil },
            telemetryAvailable: snapshot["telemetryAvailable"] as? Bool ?? true,
            sessionLocked: snapshot["sessionLocked"] as? Bool ?? false)
        let selectedID = snapshot["selectedPCID"] as? String ?? ""
        let host = snapshot["host"] as? String ?? ""
        return WatchComplicationEntry(
            date: date,
            pcName: snapshot["pcName"] as? String ?? fallbackName,
            isPaired: !selectedID.isEmpty || !host.isEmpty || OrbitWidgetConnectionStore.defaultConnection() != nil,
            isOnline: isOnline,
            isLocked: telemetry.sessionLocked == true,
            telemetry: telemetry,
            updatedAt: updatedAt,
            tintHex: snapshot["tintHex"] as? String ?? "")
    }
}

// MARK: - Widgets

/// Whether the PC is on, asleep or locked.
struct OrbitWatchStatusWidget: Widget {
    // The kind of the first watch complication, so faces that had it keep a complication.
    let kind = "OrbitWatchTelemetry"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationContainer(url: "orbitwatch://glance") { family in
                WatchStatusComplication(entry: entry, family: family)
            }
        }
        .configurationDisplayName("PC Status")
        .description("Whether your PC is on, asleep or locked.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct OrbitWatchProcessorTemperatureWidget: Widget {
    let kind = "OrbitWatchProcessorTemperature"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationContainer(url: "orbitwatch://glance") { family in
                WatchTemperatureComplication(entry: entry, family: family, component: .processor)
            }
        }
        .configurationDisplayName("Processor Temperature")
        .description("How warm your PC's processor is.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct OrbitWatchGraphicsTemperatureWidget: Widget {
    let kind = "OrbitWatchGraphicsTemperature"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationContainer(url: "orbitwatch://glance") { family in
                WatchTemperatureComplication(entry: entry, family: family, component: .graphics)
            }
        }
        .configurationDisplayName("Graphics Temperature")
        .description("How warm your PC's graphics card is.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct OrbitWatchFrameRateWidget: Widget {
    let kind = "OrbitWatchFrameRate"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationContainer(url: "orbitwatch://media") { family in
                WatchFrameRateComplication(entry: entry, family: family)
            }
        }
        .configurationDisplayName("Frame Rate")
        .description("The frame rate of the game running on your PC.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

/// Opens the pointer page. Kept under the Air Mouse kind it replaces.
struct OrbitWatchControlWidget: Widget {
    let kind = "OrbitWatchAirMouse"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationContainer(url: "orbitwatch://control") { family in
                WatchControlComplication(entry: entry, family: family)
            }
        }
        .configurationDisplayName("Control")
        .description("Opens the pointer, clicks and scrolling for your PC.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

/// Reads the family and sets the deep link and the Smart Stack background: Orbit's solid
/// content surface (faces drop it; tinted modes desaturate it).
private struct WatchComplicationContainer<Content: View>: View {
    var url: String
    @ViewBuilder var content: (WidgetFamily) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content(family)
            .widgetURL(URL(string: url))
            .containerBackground(for: .widget) { OrbitPalette.surface }
    }
}
