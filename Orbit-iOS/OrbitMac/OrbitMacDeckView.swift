import AppKit
import SwiftUI

// Buttons on the Mac (DESIGN F4): the custom button deck stored on the PC and shared with the iPhone,
// Apple Watch and Apple TV. A "Buttons" section in the sidebar's Control group (grid of `MacActionTile`,
// reorder, delete, add from presets), the first four buttons in the menu bar popover, a "Buttons" menu
// with ⌃⌘1…⌃⌘9, and `orbit://deck` (`orbit://deck/<id>` asks before running that button).
// Everything runs through `OrbitMacViewModel`; feature detection uses `GET /api/capabilities`.

// MARK: - State

@MainActor
final class MacDeckModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready
        /// The PC's agent predates the deck.
        case unsupported
        case failed(String)
    }

    struct Feedback: Equatable {
        var message: String
        var isError: Bool
        var date = Date()
    }

    @Published fileprivate(set) var buttons: [OrbitRemoteDeckButton] = []
    @Published fileprivate(set) var phase: Phase = .idle
    @Published fileprivate(set) var runningButtonID: String?
    @Published fileprivate(set) var isSaving = false
    @Published var lastResult: Feedback?
    /// A button waiting for its confirmation, asked by the Buttons page (from the grid, the menu bar,
    /// the Buttons menu or an `orbit://deck/<id>` link). Set it with `OrbitMacViewModel.askDeckConfirmation`.
    @Published var pendingConfirmation: OrbitRemoteDeckButton?
    fileprivate var loadedAt: Date?
    fileprivate var scope = ""
    /// A button asked for by `orbit://deck/<id>`, kept only until the deck loads or `linkLifetime` passes,
    /// so a question never pops up long after the link was opened.
    fileprivate var pendingLinkID: String?
    fileprivate var pendingLinkDate: Date?
    fileprivate var confirmationRequest = UUID()

    static let linkLifetime: TimeInterval = 30
    /// A confirmation that is not on screen after this long (no main window) is dropped.
    static let confirmationShowDeadline: TimeInterval = 4

    /// Called when the PC or demo mode changes (`OrbitMacViewModel.resetConnection`).
    func reset() {
        buttons = []
        phase = .idle
        runningButtonID = nil
        isSaving = false
        lastResult = nil
        pendingConfirmation = nil
        pendingLinkID = nil
        pendingLinkDate = nil
        loadedAt = nil
        scope = ""
    }
}

/// Body of `PUT /api/deck`. `baseUpdatedAt` makes the PC refuse the save (409) when another device
/// saved after this Mac read the deck, instead of silently overwriting that change.
private struct MacDeckUpload: Encodable {
    let buttons: [OrbitRemoteDeckJSON]
    let baseUpdatedAt: String?
}

/// Brings Orbit's main window forward. `openWindow(id:)` on a WindowGroup adds another window, so it
/// is used only when no main window is on screen.
@MainActor
enum MacMainWindow {
    private static func isMain(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier == "main" || identifier.hasPrefix("main-")
    }

    static var isOnScreen: Bool {
        NSApp.windows.contains { isMain($0) && $0.isVisible && !$0.isMiniaturized }
    }

    static func show(_ openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: { isMain($0) && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MacDeckChange {
    case add(OrbitRemoteDeckButton)
    case delete(OrbitRemoteDeckButton)
    /// Moves a button in front of another one (`nil` = to the end).
    case move(OrbitRemoteDeckButton, before: String?)
    case shift(OrbitRemoteDeckButton, by: Int)

    fileprivate var doneMessage: String {
        switch self {
        case let .add(button): return "Added “\(button.displayTitle)” to every device"
        case let .delete(button): return "Deleted “\(button.displayTitle)” from every device"
        case let .move(button, _), let .shift(button, _): return "Moved “\(button.displayTitle)”"
        }
    }

    fileprivate func apply(to list: inout [OrbitRemoteDeckButton]) throws {
        switch self {
        case let .add(button):
            list.append(button)
        case let .delete(button):
            list.removeAll { $0.id == button.id }
        case let .move(button, before):
            guard let from = list.firstIndex(where: { $0.id == button.id }) else { throw OrbitError(message: "That button is no longer on your PC.") }
            let moved = list.remove(at: from)
            if let before, let to = list.firstIndex(where: { $0.id == before }) { list.insert(moved, at: to) } else { list.append(moved) }
        case let .shift(button, offset):
            guard let from = list.firstIndex(where: { $0.id == button.id }) else { throw OrbitError(message: "That button is no longer on your PC.") }
            let moved = list.remove(at: from)
            list.insert(moved, at: min(list.count, max(0, from + offset)))
        }
    }
}

// MARK: - View model

extension OrbitMacViewModel {
    private var deckScope: String { "\(currentPC?.id ?? "")#\(generation)#\(isDemoMode)" }

    var deckIsAvailable: Bool { isDemoMode || (metrics.isOnline && currentPC != nil) }

    /// Loads the deck of the current PC. `silent` keeps the grid and only reports errors when it is empty.
    func refreshDeck(silent: Bool = false) async {
        let model = deck
        let scope = deckScope
        if isDemoMode {
            // Demo edits stay until demo mode ends; the PC is never contacted.
            if model.scope != scope || model.buttons.isEmpty { model.buttons = OrbitRemoteDeck.demo.buttons }
            model.scope = scope
            model.phase = .ready
            model.loadedAt = Date()
            resolveDeckLink()
            return
        }
        guard let pc = currentPC else { model.reset(); return }
        if model.scope != scope {
            model.buttons = []
            model.phase = .idle
            model.loadedAt = nil
            model.scope = scope
        }
        guard metrics.isOnline else { return }
        if model.buttons.isEmpty { model.phase = .loading }
        let version = generation
        let client: OrbitAPIClient
        do { client = try self.client(for: pc) } catch {
            model.phase = .failed((error as? OrbitError)?.message ?? error.localizedDescription)
            return
        }
        let outcome = await OrbitRemoteDeckService.load(get: { try await client.data($0) }, status: { ($0 as? OrbitError)?.statusCode })
        guard version == generation, model.scope == scope else { return }
        switch outcome {
        case let .deck(loaded):
            if model.buttons != loaded.buttons { model.buttons = loaded.buttons }
            model.phase = .ready
            model.loadedAt = Date()
            resolveDeckLink()
        case .unsupported:
            model.buttons = []
            model.phase = .unsupported
            model.loadedAt = Date()
            if model.pendingLinkID != nil {
                model.pendingLinkID = nil
                model.pendingLinkDate = nil
                model.lastResult = .init(message: OrbitRemoteDeckService.updateAgentMessage, isError: true)
            }
        case let .failed(message):
            if model.buttons.isEmpty { model.phase = .failed(message) } else if !silent { model.lastResult = .init(message: message, isError: true) }
        }
    }

    func refreshDeckIfStale(maxAge: TimeInterval = 60) async {
        let model = deck
        guard model.scope != deckScope || model.loadedAt.map({ Date().timeIntervalSince($0) > maxAge }) ?? true else { return }
        await refreshDeck(silent: true)
    }

    func isDeckButtonLocked(_ button: OrbitRemoteDeckButton) -> Bool {
        let index = deck.buttons.firstIndex { $0.id == button.id } ?? 0
        return OrbitRemoteDeck.isLocked(index: index, proUnlocked: OrbitProStore.shared.isProUnlocked || isDemoMode)
    }

    /// Runs at once, or asks first for power buttons (the Buttons page shows the question). Callers
    /// outside the main window show it first (`MacMainWindow.show`).
    func requestDeckRun(_ button: OrbitRemoteDeckButton) {
        if button.needsConfirmation && !isDeckButtonLocked(button) {
            askDeckConfirmation(button)
        } else {
            Task { await runDeckButton(button) }
        }
    }

    /// Shows the Buttons page with the question. If it is still not on screen a few seconds later
    /// (no main window), the question is dropped rather than appearing whenever the window opens next.
    func askDeckConfirmation(_ button: OrbitRemoteDeckButton) {
        let model = deck
        if selectedSection != .deck { selectedSection = .deck }
        model.pendingConfirmation = button
        let request = UUID()
        model.confirmationRequest = request
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MacDeckModel.confirmationShowDeadline))
            guard let self, model.confirmationRequest == request, model.pendingConfirmation?.id == button.id,
                  !(self.selectedSection == .deck && MacMainWindow.isOnScreen) else { return }
            model.pendingConfirmation = nil
        }
    }

    func runDeckButton(_ button: OrbitRemoteDeckButton) async {
        let model = deck
        guard model.runningButtonID == nil else { return }
        let title = button.displayTitle
        guard !isDeckButtonLocked(button) else {
            model.lastResult = .init(message: "Orbit Pro unlocks buttons beyond the first \(OrbitRemoteDeck.freeButtonLimit).", isError: true)
            return
        }
        if isDemoMode {
            model.lastResult = .init(message: "Demo · “\(title)” would run on your PC", isError: false)
            statusBanner = "Demo · \(title)"
            return
        }
        guard metrics.isOnline, let pc = currentPC else {
            model.lastResult = .init(message: "Connect to your PC first. Power it on from the sidebar if it's asleep.", isError: true)
            return
        }
        let version = generation
        let client: OrbitAPIClient
        do { client = try self.client(for: pc) } catch {
            model.lastResult = .init(message: (error as? OrbitError)?.message ?? error.localizedDescription, isError: true)
            return
        }
        model.runningButtonID = button.id
        defer { if model.runningButtonID == button.id { model.runningButtonID = nil } }
        let outcome = await OrbitRemoteDeckService.run(buttonID: button.id, post: { try await client.data($0, method: "POST") },
                                                       status: { ($0 as? OrbitError)?.statusCode })
        guard version == generation else { return }
        switch outcome {
        case let .done(detail):
            let text = detail ?? "“\(title)” ran on \(pc.name)"
            model.lastResult = .init(message: text, isError: false)
            statusBanner = text
            if button.powerAction != nil {
                metrics.isOnline = false
                wasOnline = false
                stopPreview()
            }
        case let .failed(message, missing):
            model.lastResult = .init(message: message, isError: true)
            statusBanner = "\(title) failed: \(message)"
            if missing { await refreshDeck(silent: true) }
        case .unsupported:
            model.phase = .unsupported
            model.lastResult = .init(message: OrbitRemoteDeckService.updateAgentMessage, isError: true)
        }
    }

    /// Edits start from the PC's current deck, so changes made meanwhile on another device are kept;
    /// `PUT /api/deck` then replaces the whole deck.
    @discardableResult
    func editDeck(_ change: MacDeckChange) async -> Bool {
        let model = deck
        guard !model.isSaving else { return false }
        if isDemoMode {
            var list = model.buttons
            try? change.apply(to: &list)
            model.buttons = list
            model.lastResult = .init(message: "Demo · changes stay on this Mac until you leave demo mode.", isError: false)
            return true
        }
        guard metrics.isOnline, let pc = currentPC else {
            model.lastResult = .init(message: "Connect to your PC to change its buttons.", isError: true)
            return false
        }
        let version = generation
        model.isSaving = true
        defer { model.isSaving = false }
        do {
            let client = try self.client(for: pc)
            var saved: [OrbitRemoteDeckButton] = []
            // Read, change, save with the deck's updatedAt. When another device saved in between, the
            // PC answers 409: read its newer deck and apply the change once more on top of it.
            for attempt in 1...2 {
                let latest = try JSONDecoder().decode(OrbitRemoteDeck.self, from: try await client.data("/api/deck"))
                var list = latest.buttons
                try change.apply(to: &list)
                guard list.count <= OrbitRemoteDeck.maxButtons else {
                    throw OrbitError(message: "Your PC keeps up to \(OrbitRemoteDeck.maxButtons) buttons. Delete one first.")
                }
                saved = list
                do {
                    let upload = MacDeckUpload(buttons: list.map(\.json), baseUpdatedAt: latest.updatedAt)
                    let reply: OrbitRemoteDeckJSON = try await client.send("/api/deck", method: "PUT", body: upload)
                    if reply["buttons"] != nil, let data = try? JSONEncoder().encode(reply),
                       let echoed = try? JSONDecoder().decode(OrbitRemoteDeck.self, from: data) {
                        saved = echoed.buttons
                    }
                    break
                } catch is DecodingError {
                    break // Saved; the PC just answered with something other than the deck.
                } catch let error as OrbitError where error.statusCode == 409 && attempt == 1 && latest.updatedAt != nil {
                    continue
                }
            }
            guard version == generation else { return false }
            model.buttons = saved
            model.phase = .ready
            model.loadedAt = Date()
            model.lastResult = .init(message: change.doneMessage, isError: false)
            return true
        } catch {
            guard version == generation else { return false }
            let status = (error as? OrbitError)?.statusCode
            let message = status == 404 && OrbitRemoteDeckService.isMissingRoute(error)
                ? OrbitRemoteDeckService.updateAgentMessage
                : OrbitRemoteDeckService.message(for: error, status: status, running: false)
            model.lastResult = .init(message: "Couldn't save the buttons. \(message)", isError: true)
            await refreshDeck(silent: true)
            return false
        }
    }

    /// `orbit://deck` opens Buttons; `orbit://deck/<id>` (or `orbit://deck/run/<id>`) also asks
    /// before running that button: a link from anywhere never presses keys on the PC by itself.
    func openDeck(from url: URL) {
        selectedSection = .deck
        let model = deck
        let parts = url.pathComponents.filter { $0 != "/" }
        let id = parts.first == "run" ? parts.dropFirst().first : parts.first
        guard let id, OrbitRemoteDeck.isValidButtonID(id) else { return }
        guard isDemoMode || currentPC != nil else {
            model.lastResult = .init(message: "Pair a PC first, then open the link again.", isError: true)
            return
        }
        let requested = Date()
        model.pendingLinkID = id
        model.pendingLinkDate = requested
        resolveDeckLink()
        Task { await refreshDeckIfStale(maxAge: 10) }
        // Orbit may have just launched and still be connecting; give it a moment, then let the link go.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MacDeckModel.linkLifetime))
            guard let self, model.pendingLinkID == id, model.pendingLinkDate == requested else { return }
            model.pendingLinkID = nil
            model.pendingLinkDate = nil
            model.lastResult = .init(message: "Couldn't reach \(self.selectedPCName) to run that button. Open the link again when the PC is online.", isError: true)
        }
    }

    private func resolveDeckLink() {
        let model = deck
        guard let id = model.pendingLinkID, model.phase == .ready || isDemoMode else { return }
        let requested = model.pendingLinkDate
        model.pendingLinkID = nil
        model.pendingLinkDate = nil
        guard let requested, Date().timeIntervalSince(requested) <= MacDeckModel.linkLifetime else { return }
        guard let button = model.buttons.first(where: { $0.id == id }) else {
            model.lastResult = .init(message: "That button isn't on \(isDemoMode ? "the example PC" : selectedPCName) anymore.", isError: true)
            return
        }
        if isDeckButtonLocked(button) {
            model.lastResult = .init(message: "Orbit Pro unlocks buttons beyond the first \(OrbitRemoteDeck.freeButtonLimit).", isError: true)
        } else {
            askDeckConfirmation(button)
        }
    }
}

// MARK: - Presets

/// Ready-made buttons the Mac can add. Everything else (custom shortcuts, apps, websites, typed text,
/// OBS scenes, sequences) is built in Orbit on iPhone.
struct MacDeckPreset: Identifiable {
    let group: String
    let title: String
    let symbol: String
    let color: String
    let action: OrbitRemoteDeckJSON
    var confirm = false
    var id: String { "\(group)/\(title)" }

    func makeButton() -> OrbitRemoteDeckButton {
        OrbitRemoteDeckButton(id: UUID().uuidString.lowercased(), title: title, symbol: symbol, color: color, confirm: confirm, action: action)
    }

    private static func hotkey(_ keys: String...) -> OrbitRemoteDeckJSON {
        .object(["type": .string("hotkey"), "keys": .array(keys.map { .string($0) })])
    }
    private static func system(_ name: String) -> OrbitRemoteDeckJSON { .object(["type": .string("system"), "name": .string(name)]) }
    private static func media(_ name: String) -> OrbitRemoteDeckJSON { .object(["type": .string("media"), "name": .string(name)]) }
    private static func obs(_ request: String) -> OrbitRemoteDeckJSON {
        .object(["type": .string("obs"), "request": .string(request), "data": .object([:])])
    }

    static let groups: [(String, [MacDeckPreset])] = {
        let all = [
            MacDeckPreset(group: "Voice chat", title: "Mute Discord", symbol: "mic.slash.fill", color: "#5865F2", action: hotkey("ctrl", "shift", "m")),
            MacDeckPreset(group: "Voice chat", title: "Deafen Discord", symbol: "headphones", color: "#5865F2", action: hotkey("ctrl", "shift", "d")),
            MacDeckPreset(group: "Clips", title: "Game Bar clip", symbol: "film.stack", color: "#30D158", action: hotkey("win", "alt", "g")),
            MacDeckPreset(group: "Clips", title: "NVIDIA clip", symbol: "film.stack", color: "#76B900", action: hotkey("alt", "f10")),
            MacDeckPreset(group: "Clips", title: "AMD clip", symbol: "film.stack", color: "#ED1C24", action: hotkey("ctrl", "shift", "s")),
            MacDeckPreset(group: "OBS", title: "Record", symbol: "record.circle.fill", color: "#FF453A", action: obs("ToggleRecord")),
            MacDeckPreset(group: "OBS", title: "Go live", symbol: "dot.radiowaves.left.and.right", color: "#BF5AF2", action: obs("ToggleStream")),
            MacDeckPreset(group: "OBS", title: "Save replay", symbol: "clock.arrow.circlepath", color: "#FF9F0A", action: obs("SaveReplayBuffer")),
            MacDeckPreset(group: "Windows", title: "Screenshot", symbol: "camera.viewfinder", color: "#64D2FF", action: system("screenshot")),
            MacDeckPreset(group: "Windows", title: "Task Manager", symbol: "list.bullet.rectangle.portrait.fill", color: "#0A84FF", action: hotkey("ctrl", "shift", "esc")),
            MacDeckPreset(group: "Windows", title: "Show desktop", symbol: "menubar.dock.rectangle", color: "#5EDBFF", action: system("show_desktop")),
            MacDeckPreset(group: "Windows", title: "Lock PC", symbol: "lock.fill", color: "#5EDBFF", action: system("lock")),
            MacDeckPreset(group: "Windows", title: "Sleep PC", symbol: "moon.fill", color: "#5E5CE6", action: system("sleep"), confirm: true),
            MacDeckPreset(group: "Media", title: "Play / Pause", symbol: "playpause.fill", color: "#FF375F", action: media("playpause")),
            MacDeckPreset(group: "Media", title: "Next track", symbol: "forward.end.fill", color: "#FF375F", action: media("next")),
            MacDeckPreset(group: "Media", title: "Previous track", symbol: "backward.end.fill", color: "#FF375F", action: media("previous")),
            MacDeckPreset(group: "Media", title: "Mute PC", symbol: "speaker.slash.fill", color: "#FF9F0A", action: media("mute")),
            MacDeckPreset(group: "Media", title: "Volume up", symbol: "speaker.plus.fill", color: "#FF9F0A", action: media("volumeup")),
            MacDeckPreset(group: "Media", title: "Volume down", symbol: "speaker.minus.fill", color: "#FF9F0A", action: media("volumedown"))
        ]
        var order: [String] = []
        for preset in all where !order.contains(preset.group) { order.append(preset.group) }
        return order.map { group in (group, all.filter { $0.group == group }) }
    }()
}

// MARK: - Buttons section

struct MacDeckView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @ObservedObject var deck: MacDeckModel
    @ObservedObject private var store = OrbitProStore.shared
    @Environment(\.macTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing: Bool
    @State private var pendingDelete: OrbitRemoteDeckButton?
    @State private var showsPaywall = false
    @State private var dropTargetID: String?
    /// DEBUG snapshots render the page without its scroll view (`MacDeckSnapshot`).
    private let isSnapshot: Bool

    init(deck: MacDeckModel, isSnapshot: Bool = false, editing: Bool = false) {
        self.deck = deck
        self.isSnapshot = isSnapshot
        _isEditing = State(initialValue: editing)
    }

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 10)]
    private var loadKey: String { "\(vm.selectedPCID)|\(vm.generation)|\(vm.metrics.isOnline)|\(vm.isDemoMode)" }
    private var canEdit: Bool { vm.deckIsAvailable && deck.phase == .ready && !deck.isSaving }

    var body: some View {
        if isSnapshot {
            page.padding(22)
        } else {
            MacPage { page }
                .task(id: loadKey) {
                    await vm.refreshDeck(silent: !deck.buttons.isEmpty)
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { break }
                        await vm.refreshDeck(silent: true)
                    }
                }
                .onChange(of: vm.deckIsAvailable) { _, available in if !available { isEditing = false } }
                .confirmationDialog(deck.pendingConfirmation?.confirmationTitle ?? "Run this button?",
                                    isPresented: Binding(get: { deck.pendingConfirmation != nil }, set: { if !$0 { deck.pendingConfirmation = nil } }),
                                    titleVisibility: .visible) {
                    if let button = deck.pendingConfirmation {
                        Button(button.confirmationButton, role: button.powerAction == nil || button.powerAction == "sleep" ? nil : .destructive) {
                            deck.pendingConfirmation = nil
                            Task { await vm.runDeckButton(button) }
                        }
                    }
                    Button("Cancel", role: .cancel) { deck.pendingConfirmation = nil }
                } message: {
                    Text(deck.pendingConfirmation?.confirmationMessage(pcName: vm.selectedPCName) ?? "")
                }
                .confirmationDialog("Delete “\(pendingDelete?.displayTitle ?? "")”?",
                                    isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible) {
                    if let button = pendingDelete {
                        Button("Delete Button", role: .destructive) {
                            pendingDelete = nil
                            Task { await vm.editDeck(.delete(button)) }
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text(vm.isDemoMode ? "Demo changes aren't saved." : "It disappears from the PC and from all your devices.")
                }
                .sheet(isPresented: $showsPaywall) { OrbitProUnlockView(accent: theme.accent) { showsPaywall = false } }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if vm.isDemoMode {
                MacNotice(title: "Demo mode", message: "Sample buttons. Running one only shows what would happen, and edits aren't saved to a PC.", icon: "play.rectangle.on.rectangle.fill", tint: .orange)
            }
            content
            if let result = deck.lastResult {
                Label(result.message, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(result.isError ? Color.orange : Color.mint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Text("Build custom buttons (keyboard shortcuts, apps, websites, typed text, OBS scenes and sequences) in Orbit on iPhone: Tools → Buttons. Every change shows up here, on Apple Watch and on Apple TV. ⌃⌘1…⌃⌘9 run the first nine from any window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.15), value: deck.lastResult)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            MacIconBadge(systemName: "square.grid.2x2.fill", tint: theme.accent, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Buttons")
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if deck.phase == .loading || deck.isSaving {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await vm.refreshDeck() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MacIconButtonStyle())
            .disabled(!vm.deckIsAvailable || deck.phase == .loading)
            .help("Refresh buttons")
            if isSnapshot {
                // ImageRenderer cannot draw the AppKit pop-up button behind a Menu.
                Label("Add", systemImage: "plus").font(.body.weight(.semibold))
            } else {
                addMenu
            }
            Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                .buttonStyle(MacHoverButtonStyle(tint: isEditing ? .mint : .white, prominent: isEditing))
                .disabled(!canEdit || deck.buttons.isEmpty)
                .help("Reorder and delete buttons")
        }
        .padding(16)
        .macGlass(cornerRadius: 18, tint: theme.accent)
    }

    private var subtitle: String {
        if vm.isDemoMode { return "Sample buttons for the example PC" }
        guard let pc = vm.currentPC else { return "Pair a PC to use its buttons" }
        let count = deck.buttons.count
        let stored = "Stored on \(pc.name), shared by all your devices"
        return count == 0 ? stored : "\(count) button\(count == 1 ? "" : "s") · \(stored)"
    }

    private var addMenu: some View {
        Menu {
            ForEach(MacDeckPreset.groups, id: \.0) { group, presets in
                Section(group) {
                    ForEach(presets) { preset in
                        Button {
                            add(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!canEdit)
        .help("Add a ready-made button")
    }

    private func add(_ preset: MacDeckPreset) {
        if !store.isProUnlocked && !vm.isDemoMode && deck.buttons.count >= OrbitRemoteDeck.freeButtonLimit {
            showsPaywall = true
            return
        }
        Task { await vm.editDeck(.add(preset.makeButton())) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if vm.currentPC == nil && !vm.isDemoMode {
            MacEmptyState(icon: "desktopcomputer", title: "Pair a PC first", message: "Buttons live on your Windows PC. Pair it in My PCs or import it from your iPhone.", tint: theme.accent, actionTitle: "Open My PCs") {
                vm.selectedSection = .pcs
            }
            .macGlass(cornerRadius: 18)
        } else if !vm.deckIsAvailable {
            VStack(alignment: .leading, spacing: 14) {
                MacEmptyState(icon: "moon.zzz.fill", title: "\(vm.selectedPCName) is offline", message: "Buttons run when the PC is on and Orbit is running on it.", tint: .orange, actionTitle: vm.isWaking ? "Waking…" : "Power On") {
                    Task { await vm.wakePC() }
                }
                if !deck.buttons.isEmpty { grid.disabled(true) }
            }
            .macGlass(cornerRadius: 18)
        } else if deck.phase == .unsupported {
            MacEmptyState(icon: "arrow.down.circle.fill", title: "Update Orbit on your PC", message: OrbitRemoteDeckService.updateAgentMessage, tint: .orange, actionTitle: vm.isCheckingUpdate ? "Checking…" : "Check for Update") {
                Task { await vm.checkAgentUpdate() }
            }
            .macGlass(cornerRadius: 18)
            if let message = vm.agentUpdateMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } else if !deck.buttons.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if isEditing {
                    Label("Drag a button onto another to move it there. Changes are saved to the PC and show up on every device.", systemImage: "hand.draw")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                grid
                if !store.isProUnlocked && !vm.isDemoMode && deck.buttons.count > OrbitRemoteDeck.freeButtonLimit {
                    proNotice
                }
            }
            .padding(16)
            .macGlass(cornerRadius: 18)
        } else if case let .failed(message) = deck.phase {
            MacEmptyState(icon: "exclamationmark.triangle.fill", title: "Couldn't load the buttons", message: message, tint: .orange, actionTitle: "Try Again") {
                Task { await vm.refreshDeck() }
            }
            .macGlass(cornerRadius: 18)
        } else if deck.phase == .ready {
            emptyDeck
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading buttons from \(vm.selectedPCName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .macGlass(cornerRadius: 18)
        }
    }

    private var emptyDeck: some View {
        VStack(spacing: 4) {
            MacEmptyState(icon: "square.grid.2x2", title: "No buttons yet", message: "Add a ready-made button with Add above, or build your own in Orbit on iPhone: mute Discord, save a clip, start recording in OBS, open an app and more.", tint: theme.accent)
        }
        .macGlass(cornerRadius: 18)
    }

    private var proNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill").foregroundStyle(.yellow)
            Text("The first \(OrbitRemoteDeck.freeButtonLimit) buttons are free. Orbit Pro unlocks the rest.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unlock") { showsPaywall = true }
                .buttonStyle(MacHoverButtonStyle(tint: .yellow))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(deck.buttons) { button in
                if isEditing {
                    editTile(button)
                } else {
                    runTile(button)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: deck.buttons)
    }

    private func runTile(_ button: OrbitRemoteDeckButton) -> some View {
        let locked = vm.isDeckButtonLocked(button)
        return MacActionTile(title: button.displayTitle,
                             icon: locked ? "lock.fill" : button.displaySymbol,
                             tint: locked ? .secondary : button.tint(fallback: theme.accent),
                             isActive: deck.runningButtonID == button.id,
                             minHeight: 84) {
            if locked { showsPaywall = true } else { vm.requestDeckRun(button) }
        }
        .disabled(!vm.deckIsAvailable || (deck.runningButtonID != nil && deck.runningButtonID != button.id))
        .help(locked ? "Orbit Pro unlocks this button" : "\(button.displayTitle) · \(button.subtitle)")
        .contextMenu {
            Button(button.needsConfirmation ? "Run…" : "Run") {
                if locked { showsPaywall = true } else { vm.requestDeckRun(button) }
            }
            Divider()
            Button("Move Earlier") { Task { await vm.editDeck(.shift(button, by: -1)) } }
                .disabled(!canEdit || deck.buttons.first?.id == button.id)
            Button("Move Later") { Task { await vm.editDeck(.shift(button, by: 1)) } }
                .disabled(!canEdit || deck.buttons.last?.id == button.id)
            Button("Move to Start") { Task { await vm.editDeck(.move(button, before: deck.buttons.first?.id)) } }
                .disabled(!canEdit || deck.buttons.first?.id == button.id)
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = button }
                .disabled(!canEdit)
        }
    }

    /// Edit mode: a plain tile (not a button) so it can be dragged; drop it on another tile to move it there.
    @ViewBuilder
    private func editTile(_ button: OrbitRemoteDeckButton) -> some View {
        if isSnapshot {
            editTileFace(button) // ImageRenderer cannot draw AppKit drag sources.
        } else {
            editTileFace(button)
                .draggable(button.id) {
                    Label(button.displayTitle, systemImage: button.displaySymbol)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .dropDestination(for: String.self) { items, _ in
                    dropTargetID = nil
                    guard let id = items.first, id != button.id, let dragged = deck.buttons.first(where: { $0.id == id }) else { return false }
                    let from = deck.buttons.firstIndex { $0.id == id } ?? 0
                    let to = deck.buttons.firstIndex { $0.id == button.id } ?? 0
                    // Dropping on a later tile puts the button after it, on an earlier tile before it.
                    let before: String? = from < to ? (to + 1 < deck.buttons.count ? deck.buttons[to + 1].id : nil) : button.id
                    Task { await vm.editDeck(.move(dragged, before: before)) }
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTargetID = button.id } else if dropTargetID == button.id { dropTargetID = nil }
                }
                .disabled(!canEdit)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(button.displayTitle)
                .accessibilityAction(named: "Move earlier") { Task { await vm.editDeck(.shift(button, by: -1)) } }
                .accessibilityAction(named: "Move later") { Task { await vm.editDeck(.shift(button, by: 1)) } }
                .accessibilityAction(named: "Delete") { pendingDelete = button }
        }
    }

    private func editTileFace(_ button: OrbitRemoteDeckButton) -> some View {
        let tint = button.tint(fallback: theme.accent)
        let isTarget = dropTargetID == button.id
        return VStack(spacing: 7) {
            Image(systemName: button.displaySymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 20)
            Text(button.displayTitle)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(isTarget ? 0.12 : 0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isTarget ? tint : Color.white.opacity(0.16), style: StrokeStyle(lineWidth: isTarget ? 2 : 1, dash: isTarget ? [] : [4, 3]))
        )
        .overlay(alignment: .topLeading) {
            Button {
                pendingDelete = button
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 1.0, green: 0.45, blue: 0.48))
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Delete “\(button.displayTitle)”")
            .accessibilityLabel("Delete \(button.displayTitle)")
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(8)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - Menu bar popover row

/// The first four buttons under the popover's power row.
struct MacMenuBarDeckRow: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @ObservedObject var deck: MacDeckModel
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let first = Array(deck.buttons.prefix(4))
        // Hidden (and taking no room) while offline, on older agents or without buttons. The popover
        // refreshes stale buttons with `macDeckAutoRefresh` on its root.
        Group {
            if vm.deckIsAvailable && !first.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("BUTTONS")
                            .font(.system(.caption2, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Button("All Buttons") { openSection() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                    HStack(spacing: 6) {
                        ForEach(first) { button in
                            MacActionTile(title: button.displayTitle, icon: button.displaySymbol,
                                          tint: button.tint(fallback: theme.accent),
                                          isActive: deck.runningButtonID == button.id, minHeight: 50) {
                                tap(button)
                            }
                            .disabled(deck.runningButtonID != nil && deck.runningButtonID != button.id)
                            .help("\(button.displayTitle) · \(button.subtitle)")
                        }
                    }
                    if let result = deck.lastResult, Date().timeIntervalSince(result.date) < 30 {
                        Text(result.message)
                            .font(.caption2)
                            .foregroundStyle(result.isError ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func tap(_ button: OrbitRemoteDeckButton) {
        if button.needsConfirmation {
            // Ask in the main window, where the question has room and cannot vanish with the popover.
            openSection()
            vm.askDeckConfirmation(button)
        } else {
            Task { await vm.runDeckButton(button) }
        }
    }

    private func openSection() {
        vm.selectedSection = .deck
        MacMainWindow.show(openWindow)
    }
}

extension View {
    /// Loads the deck when the menu bar popover opens, at most once a minute.
    func macDeckAutoRefresh(_ vm: OrbitMacViewModel) -> some View {
        task(id: "\(vm.selectedPCID)|\(vm.metrics.isOnline)|\(vm.isDemoMode)") { await vm.refreshDeckIfStale(maxAge: 60) }
    }
}

// MARK: - Buttons menu

/// Menu bar "Buttons" menu: the first nine buttons with ⌃⌘1…⌃⌘9.
struct MacDeckCommands: View {
    @ObservedObject var vm: OrbitMacViewModel
    @ObservedObject var deck: MacDeckModel
    /// The app's `openWindow` (commands may fire while the main window is closed).
    let openWindow: OpenWindowAction

    var body: some View {
        Button("Show Buttons") {
            vm.selectedSection = .deck
            MacMainWindow.show(openWindow)
        }
        Divider()
        if deck.buttons.isEmpty {
            Text(deck.phase == .unsupported ? "Update Orbit on your PC to use buttons" : "No buttons loaded")
        }
        ForEach(Array(deck.buttons.prefix(9).enumerated()), id: \.element.id) { index, button in
            Button(button.needsConfirmation ? "\(button.displayTitle)…" : button.displayTitle) {
                if button.needsConfirmation || vm.isDeckButtonLocked(button) {
                    // The question appears on the Buttons page, so make sure it is on screen.
                    vm.selectedSection = .deck
                    MacMainWindow.show(openWindow)
                }
                vm.requestDeckRun(button)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
            .disabled(!vm.deckIsAvailable || vm.isDeckButtonLocked(button))
        }
        Divider()
        Button("Refresh Buttons") { Task { await vm.refreshDeck() } }
            .disabled(!vm.deckIsAvailable)
    }
}

#if DEBUG
// MARK: - Snapshot for reviews

/// `ORBIT_DECK_SNAPSHOT=/path/buttons.png OrbitMac.app/Contents/MacOS/OrbitMac -mac.demoMode YES -mac.savedPCs.v1 ''`
/// renders the Buttons page, its edit mode and the menu bar popover to PNG files and exits, without a
/// window or a network call. `ORBIT_DECK_SNAPSHOT_DECK=deck.json` (a `GET /api/deck` reply) and
/// `ORBIT_DECK_SNAPSHOT_PC=name` show a real deck as if that PC were online.
enum MacDeckSnapshot {
    @MainActor static func run(output: String) -> Never {
        let environment = ProcessInfo.processInfo.environment
        let vm = OrbitMacViewModel()
        vm.pollTask?.cancel()
        let model = vm.deck
        if let path = environment["ORBIT_DECK_SNAPSHOT_DECK"], let data = FileManager.default.contents(atPath: path),
           let deck = try? JSONDecoder().decode(OrbitRemoteDeck.self, from: data) {
            vm.isDemoMode = false
            vm.savedPCs = [MacSavedPC(id: "snapshot", name: environment["ORBIT_DECK_SNAPSHOT_PC"] ?? "Gaming PC", address: "192.0.2.10")]
            vm.selectedPCID = "snapshot"
            vm.metrics = .demo
            vm.metrics.isOnline = true
            model.buttons = deck.buttons
            model.lastResult = .init(message: "Pressed Ctrl+Shift+M", isError: false)
        } else {
            vm.isDemoMode = true
            model.buttons = OrbitRemoteDeck.demo.buttons
            model.lastResult = .init(message: "Demo · “Mute Discord” would run on your PC", isError: false)
        }
        model.phase = .ready
        let base = URL(fileURLWithPath: output)
        let stem = base.deletingPathExtension().path
        render(MacDeckView(deck: model, isSnapshot: true), width: 980, to: base, vm: vm)
        render(MacDeckView(deck: model, isSnapshot: true, editing: true), width: 980, to: URL(fileURLWithPath: stem + "-editing.png"), vm: vm)
        // The popover's own sliders and menus are AppKit controls ImageRenderer cannot draw; show the new row.
        render(MacMenuBarDeckRow(deck: model).padding(14), width: 340, to: URL(fileURLWithPath: stem + "-menubar.png"), vm: vm)
        print("Wrote \(base.path), \(stem)-editing.png and \(stem)-menubar.png")
        exit(0)
    }

    @MainActor private static func render<V: View>(_ view: V, width: CGFloat, to url: URL, vm: OrbitMacViewModel) {
        let content = view
            .environmentObject(vm)
            .macAppearance()
            .environment(\.colorScheme, .dark)
            .frame(width: width)
            .background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { print("Could not render \(url.lastPathComponent)"); return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
