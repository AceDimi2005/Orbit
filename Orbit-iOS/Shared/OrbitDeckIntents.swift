import AppIntents
import Foundation
import SwiftUI
import WidgetKit

// Siri, Shortcuts, the Buttons widget and the Buttons control (DESIGN F4). Compiled into Orbit and
// OrbitWidgets. Buttons come from the App Group cache the app writes (`OrbitDeckCache`), so they can be
// listed without reaching the PC; running one calls `POST /api/deck/buttons/{id}/run` over pinned HTTPS.

enum OrbitDeckSurfaces {
    static let widgetKind = "OrbitDeck"
    static let controlKind = "com.dimitrie.orbit.control.deck"

    /// Asks the Buttons widget and control to redraw from the cache.
    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: controlKind)
        }
    }

    /// `orbit://deck`, optionally pointing at one button (the app then asks before running it).
    static func deckURL(buttonID: String? = nil, pcID: String? = nil) -> URL {
        var parts = URLComponents()
        parts.scheme = "orbit"
        parts.host = "deck"
        var items: [URLQueryItem] = []
        if let buttonID, !buttonID.isEmpty { items.append(URLQueryItem(name: "button", value: buttonID)) }
        if let pcID, !pcID.isEmpty { items.append(URLQueryItem(name: "pc", value: pcID)) }
        parts.queryItems = items.isEmpty ? nil : items
        return parts.url ?? URL(string: "orbit://deck")!
    }
}

extension OrbitDeckColor {
    static func color(_ hex: String) -> Color {
        let value = components(hex)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1)
    }
}

// MARK: - Entities

// INTEGRATION NOTE (DESIGN F3): Shared/OrbitPCEntity.swift (Shortcuts actions, built in parallel) adds the
// shared `OrbitPCEntity` with the same id (the PC profile id) and name. Before release, delete
// `OrbitDeckPCEntity` and `OrbitDeckPCQuery` and use `OrbitPCEntity` in `RunDeckButtonIntent.pc`,
// `OrbitDeckWidgetIntent.pc` and the `@IntentParameterDependency` below, so Shortcuts shows one "PC" type
// and saved widget configurations never have to change type later.
struct OrbitDeckPCEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "PC")
    static var defaultQuery = OrbitDeckPCQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ connection: OrbitWidgetConnection) {
        self.init(id: connection.id, name: connection.name)
    }
}

struct OrbitDeckPCQuery: EntityQuery {
    init() {}

    /// A PC removed from Orbit comes back as a "Removed PC" placeholder instead of nothing: an empty value
    /// would quietly run the button on another PC; the placeholder stops the run with an explanation.
    func entities(for identifiers: [String]) async throws -> [OrbitDeckPCEntity] {
        let saved = OrbitWidgetConnectionStore.connections()
        return identifiers.map { id in saved.first { $0.id == id }.map(OrbitDeckPCEntity.init) ?? OrbitDeckPCEntity(id: id, name: "Removed PC") }
    }

    func suggestedEntities() async throws -> [OrbitDeckPCEntity] {
        OrbitDeckEntities.connections().map(OrbitDeckPCEntity.init)
    }

    func defaultResult() async -> OrbitDeckPCEntity? {
        OrbitWidgetConnectionStore.defaultConnection().map(OrbitDeckPCEntity.init)
    }
}

/// One button of one PC's deck. The id is `<pc id>|<button id>` so the same button id on two PCs
/// stays two entities.
struct OrbitDeckButtonEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Orbit Button")
    static var defaultQuery = OrbitDeckButtonQuery()

    var id: String
    var pcID: String
    var buttonID: String
    var title: String
    var symbol: String
    var color: String
    var pcName: String
    var needsConfirmation: Bool
    /// Position in the deck; buttons from the 7th on need Orbit Pro.
    var index: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(pcName)", image: .init(systemName: symbol))
    }

    init(button: OrbitDeckButton, index: Int, pcID: String, pcName: String) {
        id = Self.identifier(pcID: pcID, buttonID: button.id)
        self.pcID = pcID
        buttonID = button.id
        title = button.displayTitle
        symbol = button.symbol
        color = button.color
        self.pcName = pcName
        needsConfirmation = button.needsConfirmation
        self.index = index
    }

    /// A button the cache doesn't have (a Shortcut made before the deck changed, or synced from another
    /// device). Assumed to need a confirmation and Orbit Pro until the PC's copy says otherwise; running
    /// it always checks the PC's copy first (`OrbitDeckIntentRunner`).
    init(unresolved identifier: String) {
        let parts = Self.split(identifier)
        id = identifier
        pcID = parts.pcID
        buttonID = parts.buttonID
        title = "Button"
        symbol = OrbitDeckButton.defaultSymbol
        color = OrbitDeckButton.defaultColor
        pcName = OrbitWidgetConnectionStore.connections().first { $0.id == parts.pcID }?.name ?? "PC"
        needsConfirmation = true
        index = OrbitDeckLimits.maxButtons
    }

    static func identifier(pcID: String, buttonID: String) -> String { "\(pcID)|\(buttonID)" }

    static func split(_ identifier: String) -> (pcID: String, buttonID: String) {
        guard let bar = identifier.firstIndex(of: "|") else { return ("", identifier) }
        return (String(identifier[..<bar]), String(identifier[identifier.index(after: bar)...]))
    }
}

enum OrbitDeckEntities {
    /// Paired PCs, the default one first.
    static func connections() -> [OrbitWidgetConnection] {
        let all = OrbitWidgetConnectionStore.connections()
        guard let preferred = OrbitWidgetConnectionStore.defaultConnection() else { return all }
        return [preferred] + all.filter { $0.id != preferred.id }
    }

    static func buttons(pcID: String? = nil) -> [OrbitDeckButtonEntity] {
        connections().filter { pcID == nil || $0.id == pcID }.flatMap { connection -> [OrbitDeckButtonEntity] in
            let deck = OrbitDeckCache.deck(for: connection.id)?.buttons ?? []
            return deck.enumerated().map { OrbitDeckButtonEntity(button: $0.element, index: $0.offset, pcID: connection.id, pcName: connection.name) }
        }
    }
}

struct OrbitDeckButtonQuery: EntityStringQuery {
    @IntentParameterDependency<RunDeckButtonIntent>(\.$pc) var runIntent

    init() {}

    private var pcFilter: String? { runIntent?.pc.id }

    func entities(for identifiers: [String]) async throws -> [OrbitDeckButtonEntity] {
        let known = OrbitDeckEntities.buttons()
        return identifiers.map { identifier in known.first { $0.id == identifier } ?? OrbitDeckButtonEntity(unresolved: identifier) }
    }

    func entities(matching string: String) async throws -> [OrbitDeckButtonEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = OrbitDeckEntities.buttons(pcID: pcFilter)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.pcName.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [OrbitDeckButtonEntity] {
        OrbitDeckEntities.buttons(pcID: pcFilter)
    }
}

// MARK: - Run a button

/// A button checked against the deck the PC has right now, ready to run.
struct OrbitDeckPreparedRun {
    let connection: OrbitWidgetConnection
    let target: OrbitDeckHTTP.Target
    let button: OrbitDeckButton
    let index: Int

    var title: String { button.displayTitle }
    var needsConfirmation: Bool { button.needsConfirmation }
    var entity: OrbitDeckButtonEntity {
        OrbitDeckButtonEntity(button: button, index: index, pcID: connection.id, pcName: connection.name)
    }
}

/// What Siri, Shortcuts, the widget and the control share. Every run first reads the deck from the PC
/// (`GET /api/deck`, also refreshing the cache): the cached copy can be out of date (another device may
/// have turned this button into a sleep button) or miss the button entirely (a Shortcut synced through
/// iCloud), and both must fail closed. The confirmation and the free-plan check use the PC's copy.
enum OrbitDeckIntentRunner {
    static func prepare(button: OrbitDeckButtonEntity, pc: OrbitDeckPCEntity?) async throws -> OrbitDeckPreparedRun {
        let connections = OrbitWidgetConnectionStore.connections()
        let wantedID = pc?.id ?? (button.pcID.isEmpty ? nil : button.pcID)
        let connection = wantedID.flatMap { id in connections.first { $0.id == id } }
            ?? (wantedID == nil ? OrbitWidgetConnectionStore.defaultConnection() : nil)
        guard let connection else {
            throw failure(connections.isEmpty ? "Pair your PC in Orbit first." : "That PC isn't paired with Orbit anymore.", pcID: nil)
        }
        guard let token = try? OrbitWidgetConnectionStore.controlToken(for: connection.id), !token.isEmpty else {
            throw failure("Open Orbit once to allow buttons for \(connection.name).", pcID: connection.id)
        }
        let target = OrbitDeckHTTP.Target(host: connection.host, port: connection.port, fingerprint: connection.certificateSHA256, token: token)

        let deck: OrbitDeck
        do {
            let fetched = try await OrbitDeckHTTP.fetchDeck(on: target, pcID: connection.id)
            if fetched.changed { OrbitDeckSurfaces.reload() }
            deck = fetched.deck
        } catch {
            throw failure(message(for: error, connection: connection), pcID: connection.id, statusCode: (error as? OrbitDeckRequestError)?.statusCode)
        }

        guard let index = deck.buttons.firstIndex(where: { $0.id == button.buttonID }) else {
            if pc != nil, connection.id != button.pcID {
                throw failure("“\(button.title)” isn't one of \(connection.name)'s buttons.", pcID: connection.id)
            }
            throw failure("“\(button.title)” isn't on \(connection.name) anymore. Open Buttons in Orbit to see the current buttons.", pcID: connection.id)
        }
        #if os(iOS)
        if !OrbitDeckLimits.isIncludedForFree(index: index), !OrbitProEntitlement.cachedIsUnlocked {
            record("“\(deck.buttons[index].displayTitle)” needs Orbit Pro.", success: false, pcID: connection.id)
            throw OrbitProRequiredError()
        }
        #endif
        return OrbitDeckPreparedRun(connection: connection, target: target, button: deck.buttons[index], index: index)
    }

    /// `POST /api/deck/buttons/{id}/run`; returns the result line (also shown on the widget).
    static func run(_ prepared: OrbitDeckPreparedRun) async throws -> String {
        do {
            let reply = try await OrbitDeckHTTP.runButton(id: prepared.button.id, on: prepared.target)
            let detail = reply.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = detail.isEmpty ? "\(prepared.title) · done" : "\(prepared.title) · \(detail)"
            record(message, success: true, pcID: prepared.connection.id)
            return message
        } catch {
            throw failure(message(for: error, connection: prepared.connection), pcID: prepared.connection.id,
                          statusCode: (error as? OrbitDeckRequestError)?.statusCode)
        }
    }

    /// For a widget or control, which cannot ask "Are you sure?" in place.
    static func confirmInOrbitMessage(_ prepared: OrbitDeckPreparedRun) -> String {
        "Open Orbit to confirm “\(prepared.title)”."
    }

    static func record(_ message: String, success: Bool, pcID: String?) {
        OrbitDeckCache.recordFeedback(message, success: success, pcID: pcID)
        OrbitDeckSurfaces.reload()
    }

    private static func failure(_ message: String, pcID: String?, statusCode: Int? = nil) -> OrbitDeckRequestError {
        record(message, success: false, pcID: pcID)
        return OrbitDeckRequestError(message: message, statusCode: statusCode)
    }

    private static func message(for error: Error, connection: OrbitWidgetConnection) -> String {
        let message = OrbitDeckRequestError.message(for: error, pcName: connection.name)
        return message == OrbitDeckRequestError.unreachable ? "\(connection.name) isn't reachable. Wake it from Orbit and try again." : message
    }
}

/// Siri and Shortcuts: asks before running a button that needs it.
struct RunDeckButtonIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Orbit Button"
    static var description = IntentDescription("Runs one of the buttons you made in Orbit → Buttons on your PC, such as Mute Discord or Save Replay.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Button")
    var button: OrbitDeckButtonEntity?

    @Parameter(title: "PC", description: "Leave empty to use the PC the button belongs to.")
    var pc: OrbitDeckPCEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$button)") { \.$pc }
    }

    init() {}

    init(button: OrbitDeckButtonEntity?, pc: OrbitDeckPCEntity? = nil) {
        self.button = button
        self.pc = pc
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let button else {
            throw $button.needsValueError("Which button should Orbit run?")
        }
        let prepared = try await OrbitDeckIntentRunner.prepare(button: button, pc: pc)
        if prepared.needsConfirmation {
            // Asks about the button as the PC has it now, not as the Shortcut remembers it. Where no
            // prompt can be shown the request throws, so nothing runs.
            let confirmed = try await $button.requestConfirmation(for: prepared.entity, dialog: "Run “\(prepared.title)” on \(prepared.connection.name)?")
            guard confirmed else { return .result(dialog: "Okay, nothing was sent to \(prepared.connection.name).") }
        }
        let message = try await OrbitDeckIntentRunner.run(prepared)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// The Buttons widget and the Orbit Button control. Neither can ask "Are you sure?", so a button that
/// needs a confirmation (by the PC's current copy) opens Orbit, which asks (iOS 18.2 and later), or is
/// not run at all. Hidden from Shortcuts, which use `RunDeckButtonIntent`.
struct RunDeckButtonFromWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Orbit Button from a Widget"
    static var description = IntentDescription("Runs an Orbit button from the Buttons widget or the Orbit Button control.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Button")
    var button: OrbitDeckButtonEntity?

    init() {}

    init(button: OrbitDeckButtonEntity?) {
        self.button = button
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let button else {
            let message = "Choose a button for this control: touch and hold it, then edit it."
            OrbitDeckIntentRunner.record(message, success: false, pcID: nil)
            throw OrbitDeckRequestError(message: message)
        }
        let prepared = try await OrbitDeckIntentRunner.prepare(button: button, pc: nil)
        if prepared.needsConfirmation {
            let link = OrbitDeckSurfaces.deckURL(buttonID: prepared.button.id, pcID: prepared.connection.id)
            if #available(iOS 18.2, *) {
                return .result(opensIntent: OpenURLIntent(link), dialog: IntentDialog(stringLiteral: "Confirm “\(prepared.title)” in Orbit."))
            }
            let message = OrbitDeckIntentRunner.confirmInOrbitMessage(prepared)
            OrbitDeckIntentRunner.record(message, success: false, pcID: prepared.connection.id)
            throw OrbitDeckRequestError(message: message)
        }
        let message = try await OrbitDeckIntentRunner.run(prepared)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - Control Center configuration

@available(iOS 18.0, *)
struct OrbitDeckControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a Button"
    static var description = IntentDescription("The Orbit button this control runs.")

    @Parameter(title: "Button")
    var button: OrbitDeckButtonEntity?

    init() {}
}
