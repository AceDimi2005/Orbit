import AppIntents
import SwiftUI
import WidgetKit

// The Buttons widget (small: 4 buttons, medium: 8) and the Buttons control for Control Center.
// Both read the deck Orbit cached for the PC; a tap runs `RunDeckButtonIntent` in the background.
// Buttons that need a confirmation (sleep, restart, shut down…) open Orbit, which asks first, and
// buttons beyond the free six open the Orbit Pro sheet for free users.

struct OrbitDeckWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Buttons"
    static var description = IntentDescription("Choose the PC whose buttons the widget shows.")

    @Parameter(title: "PC")
    var pc: OrbitDeckPCEntity?

    init() {}
}

private struct OrbitDeckEntry: TimelineEntry {
    enum State { case ready, noPC, noButtons }

    var date: Date
    var state: State
    var pcID: String?
    var pcName: String
    var buttons: [OrbitDeckButtonEntity] = []
    var isPro = false
    var feedback: String?
    var isPreview = false

    static func sample(date: Date = Date()) -> OrbitDeckEntry {
        let buttons = OrbitDeckSamples.demoDeck.buttons.enumerated().map {
            OrbitDeckButtonEntity(button: $0.element, index: $0.offset, pcID: "", pcName: "Your PC")
        }
        return OrbitDeckEntry(date: date, state: .ready, pcID: nil, pcName: "Your PC", buttons: buttons, isPro: true, isPreview: true)
    }
}

private struct OrbitDeckProvider: AppIntentTimelineProvider {
    typealias Intent = OrbitDeckWidgetIntent
    typealias Entry = OrbitDeckEntry

    func placeholder(in context: Context) -> Entry { .sample() }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        let entry = load(configuration, feedback: nil)
        if context.isPreview && entry.state != .ready { return .sample() }
        return entry
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let now = Date()
        if let recent = OrbitDeckCache.recentFeedback() {
            // The result line, then the plain widget again once the line expires.
            let withFeedback = load(configuration, feedback: recent.message, date: now)
            var later = withFeedback
            later.date = recent.expires
            later.feedback = nil
            return Timeline(entries: [withFeedback, later], policy: .after(now.addingTimeInterval(60 * 60)))
        }
        return Timeline(entries: [load(configuration, feedback: nil, date: now)], policy: .after(now.addingTimeInterval(60 * 60)))
    }

    private func load(_ configuration: Intent, feedback: String?, date: Date = Date()) -> Entry {
        let connections = OrbitWidgetConnectionStore.connections()
        let connection = configuration.pc.flatMap { pc in connections.first { $0.id == pc.id } } ?? OrbitWidgetConnectionStore.defaultConnection()
        guard let connection else {
            return Entry(date: date, state: .noPC, pcID: nil, pcName: "Orbit", feedback: feedback)
        }
        let buttons = OrbitDeckEntities.buttons(pcID: connection.id)
        return Entry(date: date, state: buttons.isEmpty ? .noButtons : .ready, pcID: connection.id, pcName: connection.name,
                     buttons: buttons, isPro: OrbitProEntitlement.cachedIsUnlocked, feedback: feedback)
    }
}

struct OrbitDeckWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: OrbitDeckSurfaces.widgetKind, intent: OrbitDeckWidgetIntent.self, provider: OrbitDeckProvider()) { entry in
            OrbitDeckWidgetView(entry: entry)
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Buttons")
        .description("Run your Orbit buttons on the PC: Discord mute, clips, OBS, media and more.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct OrbitDeckWidgetView: View {
    var entry: OrbitDeckEntry
    @Environment(\.widgetFamily) private var family

    private static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    private var slots: Int { family == .systemMedium ? 8 : 4 }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: family == .systemMedium ? 4 : 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            switch entry.state {
            case .ready:
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(entry.buttons.prefix(slots)), id: \.id) { button in
                        tile(button)
                    }
                    if entry.buttons.count < slots {
                        Link(destination: OrbitDeckSurfaces.deckURL(pcID: entry.pcID)) { addTile }
                    }
                }
                .frame(maxHeight: .infinity)
            case .noPC:
                message("Pair your PC in Orbit to use buttons here.", symbol: "desktopcomputer")
            case .noButtons:
                message("Open Buttons in Orbit to make your first button.", symbol: "square.grid.3x2.fill")
            }
        }
        .widgetURL(OrbitDeckSurfaces.deckURL(pcID: entry.pcID))
    }

    private var header: some View {
        // For half a minute after a tap the header shows the result instead of the PC name.
        HStack(spacing: 5) {
            if let feedback = entry.feedback {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(feedback)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Image(systemName: "square.grid.3x2.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(entry.pcName.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(entry.feedback == nil ? Self.accent : Color.mint)
    }

    @ViewBuilder
    private func tile(_ button: OrbitDeckButtonEntity) -> some View {
        let locked = !entry.isPro && !OrbitDeckLimits.isIncludedForFree(index: button.index)
        if entry.isPreview {
            tileLabel(button, locked: false)
        } else if locked {
            Link(destination: OrbitProEntitlement.upgradeURL) { tileLabel(button, locked: true) }
        } else if button.needsConfirmation {
            // Widgets cannot ask "Are you sure?", so Orbit opens and asks.
            Link(destination: OrbitDeckSurfaces.deckURL(buttonID: button.buttonID, pcID: button.pcID)) { tileLabel(button, locked: false) }
        } else {
            Button(intent: RunDeckButtonIntent(button: button)) { tileLabel(button, locked: false) }
                .buttonStyle(.plain)
        }
    }

    private func tileLabel(_ button: OrbitDeckButtonEntity, locked: Bool) -> some View {
        let tint = OrbitDeckColor.color(button.color)
        return VStack(spacing: 4) {
            Image(systemName: button.symbol)
                .font(.system(size: family == .systemMedium ? 17 : 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 22)
            Text(button.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 3)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(tint.opacity(0.32), lineWidth: 0.8))
        .overlay(alignment: .topTrailing) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(2.5)
                    .background(Color.yellow, in: Circle())
                    .padding(3)
            } else if button.needsConfirmation {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? "\(button.title), needs Orbit Pro" : button.title)
    }

    private var addTile: some View {
        Image(systemName: "plus")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])))
            .accessibilityLabel("Add a button in Orbit")
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.accent)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Control Center (iOS 18+)

@available(iOSApplicationExtension 18.0, *)
struct OrbitDeckControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: OrbitDeckSurfaces.controlKind, provider: OrbitDeckControlProvider()) { value in
            ControlWidgetButton(action: RunDeckButtonIntent(button: value.button)) {
                Label(value.title, systemImage: value.symbol)
            }
        }
        .displayName("Orbit Button")
        .description("Runs one of your Orbit buttons on your PC. Make buttons in Orbit → Buttons.")
        .promptsForUserConfiguration()
    }
}

@available(iOSApplicationExtension 18.0, *)
struct OrbitDeckControlProvider: AppIntentControlValueProvider {
    struct Value {
        var button: OrbitDeckButtonEntity?
        var title: String
        var symbol: String
    }

    func previewValue(configuration: OrbitDeckControlIntent) -> Value {
        guard let button = configuration.button else { return Value(button: nil, title: "Orbit Button", symbol: "square.grid.3x2.fill") }
        return Value(button: button, title: button.title, symbol: button.symbol)
    }

    func currentValue(configuration: OrbitDeckControlIntent) async throws -> Value {
        guard let chosen = configuration.button else { return Value(button: nil, title: "Choose a button", symbol: "square.grid.3x2.fill") }
        // The cache has the button's current name and symbol if it was edited since.
        let fresh = OrbitDeckEntities.buttons(pcID: chosen.pcID).first { $0.buttonID == chosen.buttonID } ?? chosen
        return Value(button: fresh, title: fresh.title, symbol: fresh.symbol)
    }
}
