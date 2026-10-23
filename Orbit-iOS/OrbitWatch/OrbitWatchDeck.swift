import SwiftUI
import WatchKit

// Buttons page (DESIGN F4): the custom buttons the user built in Orbit on iPhone, run from the wrist.
//
// The deck arrives two ways: in the iPhone's WatchConnectivity sync payload (key `deck`, built by
// `OrbitWatchDeckSync.payload` on the iPhone) and, when the Watch can reach the PC itself, straight from
// `GET /api/deck`. A tap goes through the iPhone (bridge command `runDeck`) when it is reachable,
// otherwise directly to `POST /api/deck/buttons/{id}/run`.

/// What the Buttons page shows. Kept apart from `OrbitWatchViewModel` so the page redraws only for its own changes.
@MainActor
final class WatchDeckStore: ObservableObject {
    /// Tab tag of the Buttons page in `OrbitWatchRootView` (`orbitwatch://buttons` opens it).
    static let tab = 4

    enum Phase: Equatable {
        case idle, loading, ready, unsupported
        /// The iPhone has not loaded this PC's buttons yet and the Watch cannot reach the PC.
        case notSynced
        case failed(String)
    }

    @Published private(set) var buttons: [OrbitRemoteDeckButton] = []
    /// The PC these buttons belong to.
    @Published private(set) var pcID = ""
    @Published private(set) var phase: Phase = .idle
    /// The iPhone is in demo mode: sample buttons that never reach a PC.
    @Published private(set) var isDemo = false
    /// Orbit Pro state last reported by the iPhone (the Watch has no StoreKit). Free: first 6 buttons.
    @Published private(set) var isProUnlocked = false
    @Published var runningButtonID: String?
    @Published var message: String?
    private var lastDirectFetch: (pcID: String, at: Date)?
    private var lastSaved: Data?
    /// The PC whose deck the Watch read itself (`GET /api/deck`) since launch, even if it was empty.
    private var directCopyPCID: String?
    /// `updatedAt` of the buttons shown (ISO 8601 from the PC, so newer sorts later).
    private var updatedAt: String?

    private static let storageKey = "Orbit.WatchDeck.v1"
    private struct Stored: Codable {
        var pcID: String
        var isPro: Bool
        var isDemo: Bool
        var buttons: [OrbitRemoteDeckJSON]
        /// `ready` when the buttons (even none) came from the PC or the iPhone's copy of its deck,
        /// `notSynced` when nobody had this PC's buttons yet. Missing in decks saved by the first build.
        var state: String?
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        pcID = stored.pcID
        isProUnlocked = stored.isPro
        isDemo = stored.isDemo
        buttons = stored.isDemo ? OrbitRemoteDeck.demo.buttons : stored.buttons.compactMap(OrbitRemoteDeckButton.init(json:))
        // An empty list only means "no buttons yet" when the PC's deck was really read; otherwise a
        // launch without the iPhone keeps saying how to bring the buttons over.
        if stored.isDemo || !buttons.isEmpty || stored.state == "ready" {
            phase = .ready
        } else if stored.state == "unsupported" {
            phase = .unsupported
        } else if !pcID.isEmpty {
            phase = .notSynced
        }
    }

    func buttons(for pcID: String) -> [OrbitRemoteDeckButton] {
        isDemo || pcID == self.pcID ? buttons : []
    }

    func index(of id: String) -> Int { buttons.firstIndex { $0.id == id } ?? 0 }

    func isLocked(_ button: OrbitRemoteDeckButton) -> Bool {
        OrbitRemoteDeck.isLocked(index: index(of: button.id), proUnlocked: isProUnlocked || isDemo)
    }

    /// Reads the `deck` key of an iPhone sync payload. Older iPhone apps send none; nothing changes then.
    func applyPhonePayload(_ payload: [String: Any]) {
        guard let raw = payload["deck"] as? [String: Any] else { return }
        let incomingPC = raw["pcID"] as? String ?? ""
        if let pro = raw["isPro"] as? Bool, pro != isProUnlocked { isProUnlocked = pro }
        if raw["demo"] as? Bool == true {
            // @Published announces every assignment, so only changes are assigned (the phone syncs every few seconds).
            if !isDemo { isDemo = true }
            if buttons != OrbitRemoteDeck.demo.buttons { buttons = OrbitRemoteDeck.demo.buttons }
            if pcID != incomingPC { pcID = incomingPC }
            if phase != .ready { phase = .ready }
            save()
            return
        }
        if isDemo {
            isDemo = false
            buttons = []
        }
        guard raw["cached"] as? Bool != false else {
            // The iPhone has no copy for this PC yet. Keep buttons the Watch fetched from the PC itself.
            if incomingPC != pcID {
                pcID = incomingPC
                buttons = []
                phase = .notSynced
            } else if buttons.isEmpty, directCopyPCID != incomingPC, phase == .idle || phase == .ready {
                phase = .notSynced
            }
            save()
            return
        }
        let stamp = raw["updatedAt"] as? String
        if pcID == incomingPC, let stamp, let updatedAt, stamp < updatedAt {
            return // The Watch read a newer deck from the PC itself; the iPhone's copy is older.
        }
        updatedAt = stamp
        let list = (raw["buttons"] as? [[String: Any]] ?? []).compactMap(OrbitRemoteDeckButton.init(watchSummary:))
        if pcID != incomingPC { pcID = incomingPC }
        if buttons != list { buttons = list }
        if phase != .ready { phase = .ready }
        save()
    }

    /// Whether to ask the PC directly (at most every 20 s per PC unless forced).
    func shouldFetchDirect(for pcID: String) -> Bool {
        guard let last = lastDirectFetch, last.pcID == pcID else { return true }
        return Date().timeIntervalSince(last.at) > 20
    }

    func beginDirectFetch(pcID: String) {
        lastDirectFetch = (pcID, Date())
        if pcID != self.pcID || buttons.isEmpty {
            if pcID != self.pcID { buttons = [] }
            self.pcID = pcID
            phase = .loading
        }
    }

    func finishDirectFetch(_ outcome: OrbitRemoteDeckService.LoadOutcome, pcID: String) {
        guard !isDemo else { return }
        switch outcome {
        case let .deck(deck):
            directCopyPCID = pcID
            updatedAt = deck.updatedAt
            self.pcID = pcID
            buttons = deck.buttons
            phase = .ready
            save()
        case .unsupported:
            self.pcID = pcID
            buttons = []
            updatedAt = nil
            phase = .unsupported
            save()
        case let .failed(reason):
            // Keep the buttons already shown; they still run through the iPhone.
            if buttons.isEmpty || pcID != self.pcID { phase = .failed(reason) }
        }
    }

    /// Keeps the last deck for launches without the iPhone. The phone syncs every few seconds, so
    /// unchanged decks are not written again.
    private func save() {
        let state: String? = switch phase {
        case .ready: "ready"
        case .unsupported: "unsupported"
        case .notSynced: "notSynced"
        default: nil
        }
        let stored = Stored(pcID: pcID, isPro: isProUnlocked, isDemo: isDemo, buttons: isDemo ? [] : buttons.map(\.json), state: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stored), data != lastSaved else { return }
        lastSaved = data
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

private struct WatchDeckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension OrbitWatchViewModel {
    /// Asks the iPhone for a fresh sync and, with direct credentials, the PC itself.
    func refreshDeck(force: Bool = false) {
        if phoneCanRelay { requestSyncFromPhone() }
        guard !deck.isDemo, hasDirectCredentials, !selectedPCID.isEmpty,
              force || deck.shouldFetchDirect(for: selectedPCID) else { return }
        let destination = target
        guard let client = try? client(for: destination) else { return }
        deck.beginDirectFetch(pcID: destination.id)
        Task {
            let outcome = await OrbitRemoteDeckService.load(
                get: { path in try await client.data(path: path) },
                status: { ($0 as? OrbitWatchHTTPError)?.statusCode })
            guard target == destination else { return }
            deck.finishDirectFetch(outcome, pcID: destination.id)
        }
    }

    func runDeckButton(_ button: OrbitRemoteDeckButton) async {
        guard deck.runningButtonID == nil else { return }
        let title = button.displayTitle
        if deck.isLocked(button) {
            deck.message = "Orbit Pro unlocks more than \(OrbitRemoteDeck.freeButtonLimit) buttons. Unlock it in Orbit on iPhone."
            WKInterfaceDevice.current().play(.failure)
            return
        }
        WKInterfaceDevice.current().play(.click)
        if deck.isDemo {
            deck.message = "Demo · “\(title)” ran. Exit demo mode on iPhone to use your PC."
            WKInterfaceDevice.current().play(.success)
            return
        }
        guard canControlPC else {
            deck.message = "Open Orbit on your nearby iPhone, or pair your PC there first."
            WKInterfaceDevice.current().play(.failure)
            return
        }
        let destination = target
        deck.runningButtonID = button.id
        deck.message = "Running “\(title)”…"
        defer { if deck.runningButtonID == button.id { deck.runningButtonID = nil } }
        do {
            let detail: String?
            if phoneCanRelay {
                detail = try await relayDeckRun(button.id, to: destination)
            } else {
                detail = try await client(for: destination).runDeckButton(id: button.id)
            }
            guard target == destination else { return }
            deck.message = detail ?? "“\(title)” done"
            if button.powerAction != nil {
                isOnline = false
                stopMotionCursor()
            }
            WKInterfaceDevice.current().play(.success)
        } catch {
            guard target == destination else { return }
            deck.message = Self.deckFailureMessage(error)
            WKInterfaceDevice.current().play(.failure)
            if case .deckRejected = error as? OrbitWatchHTTPError { refreshDeck(force: true) }
            if case .deckUnavailable = error as? OrbitWatchHTTPError { refreshDeck(force: true) }
        }
    }

    /// One route only: an unanswered button may already have run on the PC, so it is never replayed.
    /// The exception is an iPhone app that does not know `runDeck` yet; nothing ran there.
    private func relayDeckRun(_ id: String, to destination: OrbitWatchControlTarget) async throws -> String? {
        let message: [String: Any] = [
            "cmd": "runDeck", "buttonID": id, "pcID": destination.id, "host": destination.host,
            "expiresAt": Date().addingTimeInterval(5).timeIntervalSince1970
        ]
        let reply = try await sendPhoneMessage(message, timeout: 16)
        switch reply["status"] as? String {
        case "sent":
            guard reply["pcID"] as? String == destination.id else {
                throw WatchDeckError("Your iPhone didn't confirm the button. Update Orbit on both devices.")
            }
            return reply["detail"] as? String
        case "unknown_cmd":
            guard destination.hasCredentials else {
                throw WatchDeckError("Update Orbit on your iPhone to run buttons from your watch.")
            }
            return try await client(for: destination).runDeckButton(id: id)
        case "unavailable":
            throw WatchDeckError("Open Orbit on your iPhone, then try again.")
        default:
            throw WatchDeckError(reply["message"] as? String ?? "Your iPhone couldn't run the button. Try again.")
        }
    }

    private static func deckFailureMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "Your PC didn't answer in time. The button may still have run."
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach your PC. Wake it or check its connection."
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Page

struct WatchDeckPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @ObservedObject var deck: WatchDeckStore
    @State private var confirmButton: OrbitRemoteDeckButton?

    private var buttons: [OrbitRemoteDeckButton] { deck.buttons(for: vm.selectedPCID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                WatchPageHeading(title: "Buttons", symbol: "square.grid.2x2.fill")
                WatchConnectionLine(vm: vm)
                if !deck.isDemo { WatchOfflineHint(vm: vm) }
                content
                if deck.isDemo {
                    notice("Demo mode on iPhone: sample buttons that never reach a PC.", symbol: "play.rectangle.on.rectangle")
                }
                if let message = deck.message {
                    WatchFeedback(message: message)
                }
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 22)
        }
        .onAppear { vm.refreshDeck() }
        .onChange(of: vm.selectedTab) { _, tab in
            if tab == WatchDeckStore.tab { vm.refreshDeck() }
        }
        .onChange(of: vm.selectedPCID) { _, _ in deck.message = nil }
        .confirmationDialog(confirmButton?.confirmationTitle ?? "Run this button?",
                            isPresented: Binding(get: { confirmButton != nil }, set: { if !$0 { confirmButton = nil } }),
                            titleVisibility: .visible) {
            if let button = confirmButton {
                Button(button.confirmationButton, role: button.powerAction == "sleep" || button.powerAction == nil ? nil : .destructive) {
                    confirmButton = nil
                    Task { await vm.runDeckButton(button) }
                }
            }
            Button("Cancel", role: .cancel) { confirmButton = nil }
        } message: {
            Text(confirmButton?.confirmationMessage(pcName: vm.pcName) ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !buttons.isEmpty {
            ForEach(buttons) { button in
                row(button)
            }
            if !deck.isProUnlocked, !deck.isDemo, buttons.count > OrbitRemoteDeck.freeButtonLimit {
                Text("The first \(OrbitRemoteDeck.freeButtonLimit) buttons are free. Unlock Orbit Pro on iPhone for the rest.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !vm.hasDirectCredentials && vm.savedPCs.isEmpty && !deck.isDemo {
            EmptyView() // WatchOfflineHint already asks to pair the PC in Orbit on iPhone.
        } else if vm.selectedPCID != deck.pcID && !vm.selectedPCID.isEmpty && deck.phase != .loading {
            notice("Open Orbit on your iPhone nearby to bring this PC's buttons to your watch.", symbol: "iphone.and.arrow.forward")
            refreshButton
        } else {
            switch deck.phase {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading buttons…").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            case .unsupported:
                notice("Buttons need the latest Orbit agent on your PC. Update it from the Orbit icon in the Windows tray.", symbol: "arrow.down.circle")
                refreshButton
            case .notSynced:
                notice("Open Buttons in Orbit on iPhone once to bring them to your watch.", symbol: "iphone.and.arrow.forward")
                refreshButton
            case let .failed(reason):
                notice(reason, symbol: "exclamationmark.triangle.fill", tint: OrbitWatchPalette.amber)
                refreshButton
            case .ready:
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundStyle(OrbitWatchPalette.accent)
                    Text("No buttons yet")
                        .font(.footnote.weight(.semibold))
                    Text("Create them in Orbit on iPhone: Tools → Buttons. Mute Discord, clip a moment, start OBS and more.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        WatchActionButton(title: "Refresh", symbol: "arrow.clockwise", enabled: vm.isPhoneReachable || vm.hasDirectCredentials) {
            WKInterfaceDevice.current().play(.click)
            vm.refreshDeck(force: true)
        }
    }

    private func row(_ button: OrbitRemoteDeckButton) -> some View {
        let locked = deck.isLocked(button)
        let running = deck.runningButtonID == button.id
        let enabled = deck.isDemo || (vm.canControlPC && deck.runningButtonID == nil) || locked
        let tint = locked ? Color.secondary : button.tint(fallback: OrbitWatchPalette.accent)
        return Button {
            if locked || !button.needsConfirmation || deck.isDemo {
                Task { await vm.runDeckButton(button) }
            } else {
                WKInterfaceDevice.current().play(.click)
                confirmButton = button
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(tint.opacity(0.22))
                    Image(systemName: locked ? "lock.fill" : button.displaySymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
                Text(button.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(enabled ? Color.white : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if running {
                    ProgressView().controlSize(.mini)
                } else if button.needsConfirmation && !locked {
                    Image(systemName: "power")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(running ? tint.opacity(0.18) : OrbitWatchPalette.cardBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(locked ? "\(button.displayTitle), needs Orbit Pro" : button.displayTitle)
        .accessibilityHint(button.needsConfirmation ? "Asks before it runs on your PC" : "Runs on your PC")
    }

    private func notice(_ text: String, symbol: String, tint: Color = OrbitWatchPalette.accent) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
