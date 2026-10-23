import SwiftUI
import UIKit

// Buttons (DESIGN F4): a grid of big one-tap buttons that run shortcuts, OBS requests, media keys,
// links and apps on the PC. The deck is stored on the PC (`GET/PUT /api/deck`) and shared by every
// device; Orbit caches the last copy per PC for the widget, Control Center and Siri.

/// `orbit://deck[?button=<id>&pc=<pc id>]` from the Buttons widget or anywhere else.
struct OrbitDeckLink: Identifiable {
    let id = UUID()
    let buttonID: String?

    /// Switches Orbit to the PC the link names (when it is saved and not already selected), so the
    /// sheet shows that PC's buttons.
    @MainActor
    init(url: URL, vm: OrbitViewModel) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let button = items.first { $0.name == "button" }?.value ?? ""
        buttonID = button.isEmpty ? nil : String(button.prefix(128))
        if let pc = items.first(where: { $0.name == "pc" })?.value, !pc.isEmpty, pc != vm.selectedPCID, !vm.isDemoMode,
           let profile = vm.savedPCs.first(where: { $0.id == pc }) {
            vm.selectPC(profile)
        }
    }
}

struct OrbitDeckToast: Identifiable, Equatable {
    enum Kind { case success, failure, info }
    let id = UUID()
    let message: String
    let kind: Kind
}

/// Loads, runs and saves the deck of the selected PC.
@MainActor
final class OrbitDeckStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case demo
        case notPaired
        case insecure
        case olderAgent(version: String?)
        case offline
        case failed(String)

        var isOlderAgent: Bool { if case .olderAgent = self { return true }; return false }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deck = OrbitDeck(buttons: [])
    /// True while the grid shows the cached copy instead of what the PC just sent.
    @Published private(set) var isShowingCachedDeck = false
    @Published private(set) var capabilities: OrbitDeckCapabilities?
    /// Buttons whose request is in flight; different buttons can run at the same time.
    @Published private(set) var runningButtonIDs: Set<String> = []
    @Published private(set) var isSaving = false
    @Published var toast: OrbitDeckToast?
    @Published private(set) var obs: OrbitDeckOBSStatus?
    @Published private(set) var obsError: String?
    @Published private(set) var isLoadingOBS = false
    @Published private(set) var apps: [OrbitDeckApp]?
    @Published private(set) var appsError: String?
    @Published private(set) var isLoadingApps = false

    private weak var vm: OrbitViewModel?
    private var demoDeck = OrbitDeckSamples.demoDeck
    private var loadedPCID: String?
    private var loadTask: Task<Void, Never>?
    private var loadToken = 0
    private var toastTask: Task<Void, Never>?

    func attach(_ vm: OrbitViewModel) { self.vm = vm }

    var canEdit: Bool { phase == .ready || phase == .demo }
    var canRun: Bool { phase == .ready || phase == .demo }
    var isDemo: Bool { phase == .demo }
    var supportsOBS: Bool { phase == .demo || capabilities?.hasOBS == true }

    /// Starts a load that a disappearing view or an ended pull-to-refresh cannot cancel halfway
    /// (a newer load or going offline still replaces it), and waits for it.
    func refresh() async {
        reloadSoon()
        await loadTask?.value
    }

    /// Reloads from the PC (or the demo deck). Shows the cached copy at once while it loads.
    /// Only called through `reloadSoon()`/`refresh()`, so loads never overlap.
    private func load() async {
        guard let vm else { return }
        loadToken &+= 1
        let token = loadToken
        let phaseBefore = phase
        defer {
            // A load that ended early (cancelled, superseded) must not leave the spinner behind.
            if token == loadToken && phase == .loading {
                phase = (phaseBefore == .loading || phaseBefore == .idle) ? .failed("Loading was interrupted. Pull down to try again.") : phaseBefore
            }
        }
        let generation = vm.connectionID
        if vm.isDemoMode {
            deck = demoDeck
            isShowingCachedDeck = false
            capabilities = OrbitDeckCapabilities(agentVersion: nil, features: ["deck", "obs"])
            loadedPCID = nil
            phase = .demo
            return
        }
        guard vm.isConfigured else {
            deck = OrbitDeck(buttons: [])
            phase = .notPaired
            return
        }
        let pcID = vm.selectedPCID
        if loadedPCID != pcID || phase == .idle || phase == .notPaired || phase == .demo {
            deck = OrbitDeckCache.deck(for: pcID) ?? OrbitDeck(buttons: [])
            isShowingCachedDeck = !deck.buttons.isEmpty
            capabilities = nil
            obs = nil
            apps = nil
            loadedPCID = pcID
        }
        guard vm.hasSecureConnection else { phase = .insecure; return }
        guard vm.metrics.isOnline else { phase = .offline; return }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { phase = .failed(error.localizedDescription); return }
        if phase != .ready { phase = .loading }

        do {
            let capabilities: OrbitDeckCapabilities
            do {
                capabilities = try JSONDecoder().decode(OrbitDeckCapabilities.self, from: try await client.data("/api/capabilities"))
            } catch let error as OrbitError where error.statusCode == 404 {
                guard generation == vm.connectionID else { return }
                phase = .olderAgent(version: nil)
                return
            }
            guard generation == vm.connectionID else { return }
            self.capabilities = capabilities
            guard capabilities.hasDeck else { phase = .olderAgent(version: capabilities.agentVersion); return }
            try await fetchDeck(client: client, pcID: pcID, generation: generation)
            guard generation == vm.connectionID else { return }
            phase = .ready
        } catch let error as OrbitError where error.statusCode == 404 {
            guard generation == vm.connectionID else { return }
            phase = .olderAgent(version: capabilities?.agentVersion)
        } catch {
            guard generation == vm.connectionID, !Task.isCancelled else { return }
            phase = isUnreachable(error) ? .offline : .failed(OrbitDeckRequestError.message(for: error, pcName: vm.selectedPCName))
        }
    }

    private func fetchDeck(client: OrbitAPIClient, pcID: String, generation: Int) async throws {
        let data = try await client.data("/api/deck")
        guard let decoded = OrbitDeck.decode(data) else {
            throw OrbitError(message: "The PC sent buttons this version of Orbit can't read. Update Orbit and try again.")
        }
        guard generation == vm?.connectionID else { return }
        deck = decoded
        isShowingCachedDeck = false
        if OrbitDeckCache.store(data, for: pcID) { OrbitDeckSurfaces.reload() }
    }

    private func isUnreachable(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet].contains(code)
    }

    /// The PC stopped answering the status poll: keep the buttons on screen but stop sending.
    func markOffline() {
        guard vm?.isDemoMode == false, phase == .ready || phase == .loading else { return }
        loadTask?.cancel()
        phase = .offline
    }

    func reloadSoon() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    // MARK: Running

    func run(_ button: OrbitDeckButton) async {
        guard let vm, canRun, !runningButtonIDs.contains(button.id) else { return }
        OrbitHaptics.press()
        if phase == .demo {
            runningButtonIDs.insert(button.id)
            try? await Task.sleep(for: .milliseconds(350))
            runningButtonIDs.remove(button.id)
            OrbitHaptics.success()
            show("\(button.displayTitle) · demo, nothing was sent", kind: .info)
            return
        }
        guard button.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }), !button.id.isEmpty else {
            OrbitHaptics.error()
            show("This button can't be run from here. Edit it and save the buttons again.", kind: .failure)
            return
        }
        let generation = vm.connectionID
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch {
            OrbitHaptics.error()
            show(error.localizedDescription, kind: .failure)
            return
        }
        runningButtonIDs.insert(button.id)
        defer { runningButtonIDs.remove(button.id) }
        do {
            let data = try await client.data("/api/deck/buttons/\(button.id)/run", method: "POST")
            guard generation == vm.connectionID else { return }
            let reply = try? JSONDecoder().decode(OrbitDeckRunReply.self, from: data)
            let detail = reply?.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            OrbitHaptics.success()
            show(detail.isEmpty ? "\(button.displayTitle) · done" : "\(button.displayTitle) · \(detail)", kind: .success)
        } catch {
            guard generation == vm.connectionID else { return }
            OrbitHaptics.error()
            let status = (error as? OrbitError)?.statusCode
            if status == 404 {
                show("“\(button.displayTitle)” isn't on the PC anymore. Refreshing your buttons…", kind: .failure)
                reloadSoon()
            } else if isUnreachable(error) {
                show("\(vm.selectedPCName) isn't reachable. Wake it and try again.", kind: .failure)
            } else if let status, status != 401, let detail = (error as? OrbitError)?.message {
                show(detail, kind: .failure)
            } else {
                show(OrbitDeckRequestError.message(for: error, pcName: vm.selectedPCName), kind: .failure)
            }
        }
    }

    func show(_ message: String, kind: OrbitDeckToast.Kind) {
        let toast = OrbitDeckToast(message: message, kind: kind)
        self.toast = toast
        UIAccessibility.post(notification: .announcement, argument: message)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(kind == .failure ? 4.5 : 3))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.toast = nil
        }
    }

    // MARK: Saving

    /// `PUT /api/deck` with the whole list, then reads it back so the cache is exactly what the PC has.
    func save(_ buttons: [OrbitDeckButton]) async throws {
        guard let vm else { return }
        if phase == .demo {
            demoDeck = OrbitDeck(buttons: buttons)
            deck = demoDeck
            return
        }
        guard phase == .ready else { throw OrbitError(message: "Connect to the PC to save your buttons.") }
        let generation = vm.connectionID
        let pcID = vm.selectedPCID
        let client = try vm.companionClient()
        isSaving = true
        defer { isSaving = false }
        do {
            let _: SaveReply = try await client.send("/api/deck", method: "PUT", body: OrbitDeckUpdate(buttons: buttons))
        } catch {
            throw OrbitError(message: isUnreachable(error) ? "\(vm.selectedPCName) isn't reachable, so your changes weren't saved. Wake it and try again."
                                                            : OrbitDeckRequestError.message(for: error, pcName: vm.selectedPCName))
        }
        guard generation == vm.connectionID else { return }
        do {
            try await fetchDeck(client: client, pcID: pcID, generation: generation)
        } catch {
            // Saved on the PC; show what was sent until the next refresh.
            deck = OrbitDeck(buttons: buttons)
        }
    }

    private struct SaveReply: Decodable {}

    // MARK: Editor data

    func loadOBS() async {
        guard let vm, !isLoadingOBS else { return }
        if phase == .demo { obs = OrbitDeckSamples.demoOBS; return }
        guard capabilities?.hasOBS == true, let client = try? vm.companionClient() else { return }
        let generation = vm.connectionID
        isLoadingOBS = true
        defer { isLoadingOBS = false }
        do {
            let status = try JSONDecoder().decode(OrbitDeckOBSStatus.self, from: try await client.data("/api/deck/obs"))
            guard generation == vm.connectionID else { return }
            obs = status
            obsError = nil
        } catch {
            guard generation == vm.connectionID else { return }
            obsError = OrbitDeckRequestError.message(for: error, pcName: vm.selectedPCName)
        }
    }

    func loadApps() async {
        guard let vm, !isLoadingApps else { return }
        if phase == .demo { apps = OrbitDeckSamples.demoApps.apps; return }
        guard let client = try? vm.companionClient() else { return }
        let generation = vm.connectionID
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            let list = try JSONDecoder().decode(OrbitDeckAppList.self, from: try await client.data("/api/deck/apps"))
            guard generation == vm.connectionID else { return }
            apps = list.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            appsError = nil
            vm.prepareAppIcons()
        } catch {
            guard generation == vm.connectionID else { return }
            appsError = OrbitDeckRequestError.message(for: error, pcName: vm.selectedPCName)
        }
    }

    func appName(for id: String) -> String? { apps?.first { $0.id == id }?.name }
}

// MARK: - Buttons screen

struct DeckView: View {
    @ObservedObject var vm: OrbitViewModel
    /// From `orbit://deck?button=…`: the app asks before running that button (widgets can't ask).
    var focusButtonID: String? = nil
    var showsDoneButton = false

    @StateObject private var store = OrbitDeckStore()
    @ObservedObject private var proStore = OrbitProStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var showsEditor = false
    @State private var editorStartsWithPresets = false
    @State private var showsPaywall = false
    @State private var pendingConfirmation: OrbitDeckButton?
    @State private var handledFocus = false

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)] }

    var body: some View {
        ZStack {
            OrbitAmbientBackground(isOnline: vm.metrics.isOnline || vm.isDemoMode)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    notices
                    content
                    footer
                }
                .frame(maxWidth: 1100)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh() }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
        .navigationTitle("Buttons")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorStartsWithPresets = false
                    showsEditor = true
                } label: {
                    Label("Edit Buttons", systemImage: "slider.horizontal.3")
                }
                .disabled(!store.canEdit)
                .accessibilityLabel("Edit buttons")
            }
        }
        .sheet(isPresented: $showsEditor) {
            DeckEditorView(vm: vm, store: store, startsWithPresets: editorStartsWithPresets)
        }
        .sheet(isPresented: $showsPaywall) { OrbitProPaywallView() }
        .confirmationDialog(
            pendingConfirmation.map { "Run “\($0.displayTitle)”?" } ?? "Run this button?",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { button in
            Button(confirmTitle(for: button), role: button.action.isPowerAction ? .destructive : nil) {
                Task { await store.run(button) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { button in
            Text(confirmMessage(for: button))
        }
        .task {
            store.attach(vm)
            await store.refresh()
            handleFocus()
        }
        .onChange(of: vm.connectionID) { _, _ in store.reloadSoon() }
        .onChange(of: vm.isDemoMode) { _, _ in store.reloadSoon() }
        .onChange(of: vm.metrics.isOnline) { _, online in
            if online && (store.phase == .offline || store.phase == .idle) { store.reloadSoon() }
            if !online { store.markOffline() }
        }
        .onChange(of: store.phase) { _, _ in handleFocus() }
        .orbitAppearance()
    }

    // MARK: Sections

    private var headerCard: some View {
        HStack(spacing: 14) {
            OrbitIconBadge(systemName: "square.grid.3x2.fill", tint: theme.accent, size: 44, filled: store.canRun)
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.isDemoMode ? "Demo Mode" : vm.selectedPCName.isEmpty ? "Your PC" : vm.selectedPCName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    OrbitStatusPill(text: statusText, tint: statusTint, pulsing: store.phase == .loading)
                    if !store.deck.buttons.isEmpty && !hidesButtons {
                        OrbitStatChip(label: "Buttons", value: countText)
                    }
                }
            }
            Spacer(minLength: 0)
            if store.phase == .loading {
                ProgressView().tint(theme.accent)
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 20, tint: theme.accent, elevated: true)
    }

    /// Saved buttons stay hidden when this PC can't run them at all (older agent, no encryption).
    private var hidesButtons: Bool { store.phase == .insecure || store.phase.isOlderAgent }

    private var statusText: String {
        switch store.phase {
        case .ready: return store.isShowingCachedDeck ? "Saved copy" : "Ready"
        case .demo: return "Sample buttons"
        case .loading, .idle: return "Loading"
        case .offline: return "Offline"
        case .insecure: return "Not encrypted"
        case .olderAgent: return "Update needed"
        case .notPaired: return "No PC"
        case .failed: return "Problem"
        }
    }

    private var statusTint: Color {
        switch store.phase {
        case .ready, .demo: return .mint
        case .loading, .idle: return theme.accent
        default: return .orange
        }
    }

    private var countText: String {
        let count = store.deck.buttons.count
        if proStore.isProUnlocked { return "\(count)" }
        return "\(min(count, OrbitDeckLimits.freeButtons))/\(OrbitDeckLimits.freeButtons) free"
    }

    @ViewBuilder
    private var notices: some View {
        switch store.phase {
        case .demo:
            OrbitNotice(title: "Demo mode", message: "These are sample buttons. Taps send nothing, and edits last until you leave this screen. Connect a PC to make your own.", icon: "sparkles", tint: theme.accent)
        case .offline:
            VStack(alignment: .leading, spacing: 10) {
                OrbitNotice(title: "PC offline",
                            message: store.deck.buttons.isEmpty ? "Wake your PC to load its buttons." : "Showing the buttons Orbit saved. Wake your PC to use them.",
                            icon: "wifi.slash", tint: .orange)
                Button {
                    OrbitHaptics.tap()
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWakingUp ? "Waking…" : "Wake PC", systemImage: "power")
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
                .disabled(vm.isWakingUp || vm.pcMAC.isEmpty)
            }
        case .insecure:
            OrbitNotice(title: "Encrypted connection needed", message: "Buttons work over Orbit's encrypted connection. Pair this PC again with Find my PC to turn it on.", icon: "lock.shield.fill", tint: .orange)
        case .olderAgent(let version):
            OrbitNotice(title: "Update the Orbit agent",
                        message: "Buttons need a newer Orbit agent on your PC\(version.map { " (this one is \($0))" } ?? ""). Update it from Settings → PC Companion, then come back.",
                        icon: "arrow.down.circle.fill", tint: .orange)
        case .notPaired:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                OrbitNotice(title: "Couldn't load your buttons", message: message, icon: "exclamationmark.triangle.fill", tint: .orange)
                Button("Try Again") { store.reloadSoon() }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
            }
        case .ready where store.isShowingCachedDeck:
            EmptyView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if hidesButtons {
            EmptyView()
        } else if store.phase == .notPaired {
            OrbitEmptyState(icon: "desktopcomputer", title: "Pair a PC first", message: "Buttons run on your Windows PC. Pair it from the Tools tab, or try Demo Mode in Settings.", tint: theme.accent)
                .liquidGlass(cornerRadius: 22, tint: theme.accent)
        } else if store.deck.buttons.isEmpty {
            if store.canEdit {
                OrbitEmptyState(icon: "square.grid.3x2.fill", title: "No buttons yet",
                                message: "Make one-tap buttons for Discord mute, clips, OBS, media keys, links and apps.",
                                tint: theme.accent, actionTitle: "Add a Button") {
                    editorStartsWithPresets = true
                    showsEditor = true
                }
                .liquidGlass(cornerRadius: 22, tint: theme.accent)
            } else if store.phase == .loading || store.phase == .idle {
                HStack { Spacer(); ProgressView("Loading buttons…"); Spacer() }
                    .padding(.vertical, 40)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(store.deck.buttons.enumerated()), id: \.element.id) { index, button in
                    tile(button, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if (!store.deck.buttons.isEmpty && !hidesButtons) || store.canEdit {
            VStack(alignment: .leading, spacing: 6) {
                if store.phase != .demo {
                    Text("Buttons are saved on \(vm.selectedPCName.isEmpty ? "your PC" : vm.selectedPCName) and shared with every iPhone, iPad and Mac paired with it.")
                }
                if !proStore.isProUnlocked {
                    Text("Free: \(OrbitDeckLimits.freeButtons) buttons. Orbit Pro: up to \(OrbitDeckLimits.maxButtons).")
                }
                Text("Add the Buttons widget or the Orbit Button control (iOS 18) to run them without opening Orbit.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    // MARK: Tiles

    private func tile(_ button: OrbitDeckButton, index: Int) -> some View {
        let tint = OrbitDeckColor.color(button.color)
        let locked = !proStore.isProUnlocked && !OrbitDeckLimits.isIncludedForFree(index: index)
        let running = store.runningButtonIDs.contains(button.id)
        let enabled = store.canRun
        return Button {
            tap(button, locked: locked)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 46, height: 46)
                        if running {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: button.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.82))
                        }
                    }
                    Spacer(minLength: 4)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(5)
                            .background(Color.yellow, in: Circle())
                    } else if button.needsConfirmation {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Text(button.displayTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
                Text(button.action.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .liquidGlass(cornerRadius: 22, tint: tint)
            .opacity(enabled || locked ? 1 : 0.5)
        }
        .buttonStyle(OrbitPressableStyle(scale: 0.95, haptic: false))
        .disabled(!enabled && !locked)
        .contextMenu {
            if store.canRun && !locked {
                Button("Run", systemImage: "play.fill") { tap(button, locked: false) }
            }
            if store.canEdit {
                Button("Edit Buttons", systemImage: "slider.horizontal.3") {
                    editorStartsWithPresets = false
                    showsEditor = true
                }
            }
        }
        .accessibilityLabel(button.displayTitle)
        .accessibilityHint(locked ? "Needs Orbit Pro" : button.action.summary)
    }

    private func tap(_ button: OrbitDeckButton, locked: Bool) {
        if locked {
            OrbitHaptics.warning()
            showsPaywall = true
            return
        }
        if button.needsConfirmation {
            OrbitHaptics.warning()
            pendingConfirmation = button
            return
        }
        Task { await store.run(button) }
    }

    private func confirmTitle(for button: OrbitDeckButton) -> String {
        if case .system(let name) = button.action.kind {
            switch name {
            case "sleep": return "Sleep PC"
            case "restart": return "Restart PC"
            case "shutdown": return "Shut Down PC"
            default: break
            }
        }
        return "Run"
    }

    private func confirmMessage(for button: OrbitDeckButton) -> String {
        let pc = vm.isDemoMode ? "the demo PC" : (vm.selectedPCName.isEmpty ? "your PC" : vm.selectedPCName)
        if case .system(let name) = button.action.kind {
            switch name {
            case "sleep": return "\(pc.prefix(1).uppercased() + pc.dropFirst()) will go to sleep."
            case "restart": return "\(pc.prefix(1).uppercased() + pc.dropFirst()) will restart. Unsaved work in open apps may be lost."
            case "shutdown": return "\(pc.prefix(1).uppercased() + pc.dropFirst()) will shut down. Unsaved work in open apps may be lost."
            default: break
            }
        }
        return "\(button.action.summary) on \(pc)."
    }

    private func handleFocus() {
        guard !handledFocus, let focusButtonID, store.canRun else { return }
        handledFocus = true
        guard let index = store.deck.buttons.firstIndex(where: { $0.id == focusButtonID }) else { return }
        let button = store.deck.buttons[index]
        if !proStore.isProUnlocked && !OrbitDeckLimits.isIncludedForFree(index: index) {
            showsPaywall = true
        } else {
            pendingConfirmation = button
        }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.kind == .failure ? "exclamationmark.triangle.fill" : (toast.kind == .success ? "checkmark.circle.fill" : "info.circle.fill"))
                    .foregroundStyle(toast.kind == .failure ? .orange : (toast.kind == .success ? .mint : theme.accent))
                Text(toast.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: 560)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { store.toast = nil }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
