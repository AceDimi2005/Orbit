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

    func entities(for identifiers: [String]) async throws -> [OrbitDeckPCEntity] {
        OrbitWidgetConnectionStore.connections().filter { identifiers.contains($0.id) }.map(OrbitDeckPCEntity.init)
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

    /// A button the cache no longer has (for example a Shortcut made before the deck changed).
    init(unresolved identifier: String) {
        let parts = Self.split(identifier)
        id = identifier
        pcID = parts.pcID
        buttonID = parts.buttonID
        title = "Button"
        symbol = OrbitDeckButton.defaultSymbol
        color = OrbitDeckButton.defaultColor
        pcName = OrbitWidgetConnectionStore.connections().first { $0.id == parts.pcID }?.name ?? "PC"
        needsConfirmation = false
        index = 0
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
        let connections = OrbitWidgetConnectionStore.connections()
        let wantedID = pc?.id ?? (button.pcID.isEmpty ? nil : button.pcID)
        let connection = wantedID.flatMap { id in connections.first { $0.id == id } }
            ?? (wantedID == nil ? OrbitWidgetConnectionStore.defaultConnection() : nil)
        guard let connection else {
            throw OrbitDeckRequestError(message: connections.isEmpty ? "Pair your PC in Orbit first." : "That PC isn't paired with Orbit anymore.")
        }

        let deck = OrbitDeckCache.deck(for: connection.id)
        let index = deck?.buttons.firstIndex { $0.id == button.buttonID }
        if pc != nil, connection.id != button.pcID, deck != nil, index == nil {
            throw OrbitDeckRequestError(message: "“\(button.title)” isn't one of \(connection.name)'s buttons.")
        }
        let current = index.flatMap { deck?.buttons[$0] }
        let title = current?.displayTitle ?? button.title
        #if os(iOS)
        if let index, !OrbitDeckLimits.isIncludedForFree(index: index), !OrbitProEntitlement.cachedIsUnlocked {
            throw OrbitProRequiredError()
        }
        #endif

        if current?.needsConfirmation ?? button.needsConfirmation {
            let confirmed = try await $button.requestConfirmation(for: button, dialog: "Run “\(title)” on \(connection.name)?")
            guard confirmed else { return .result(dialog: "Okay, nothing was sent to \(connection.name).") }
        }

        guard let token = try? OrbitWidgetConnectionStore.controlToken(for: connection.id), !token.isEmpty else {
            let message = "Open Orbit once to allow buttons for \(connection.name)."
            OrbitDeckCache.recordFeedback(message)
            OrbitDeckSurfaces.reload()
            throw OrbitDeckRequestError(message: message)
        }

        do {
            let target = OrbitDeckHTTP.Target(host: connection.host, port: connection.port, fingerprint: connection.certificateSHA256, token: token)
            let reply = try await OrbitDeckHTTP.runButton(id: button.buttonID, on: target)
            let detail = reply.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = detail.isEmpty ? "\(title) · done" : "\(title) · \(detail)"
            OrbitDeckCache.recordFeedback(message)
            OrbitDeckSurfaces.reload()
            return .result(dialog: IntentDialog(stringLiteral: message))
        } catch {
            var message = OrbitDeckRequestError.message(for: error, pcName: connection.name)
            if message == OrbitDeckRequestError.unreachable { message = "\(connection.name) isn't reachable. Wake it from Orbit and try again." }
            OrbitDeckCache.recordFeedback(message)
            OrbitDeckSurfaces.reload()
            throw OrbitDeckRequestError(message: message, statusCode: (error as? OrbitDeckRequestError)?.statusCode)
        }
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
