import AppKit
import MoonlightCore
import SwiftUI

/// Play: the PC's games with their art, streamed to this Mac or started on the PC. The card at
/// the top says whether streaming is ready and offers the one thing to do next.
struct MacLibraryView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    /// Owned by the window, shared with the PC page.
    @ObservedObject var sunshine: MoonlightHostCoordinator
    /// False only for DEBUG snapshots: SwiftUI's image renderer draws nothing inside a ScrollView.
    var scrolls = true
    @ObservedObject private var stream = MoonlightStreamController.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @AppStorage(MacStreamBackend.storageKey) private var streamBackendRaw = MacStreamBackend.orbit.rawValue
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var launchingID: String?
    @State private var launchStatus: String?
    @State private var moonlightInstalled: Bool?
    @State private var showsPairing = false
    @State private var showsStreamSettings = false
    @State private var confirmsForgetPairing = false

    private static let refreshFailurePrefix = "Could not refresh the Sunshine library"
    private static let launchWarningPrefixes = ["Could not", "Launch stopped", "Moonlight"]

    private var pcName: String { vm.selectedPCName }
    private var streamBackend: MacStreamBackend { MacStreamBackend(rawValue: streamBackendRaw) ?? .orbit }
    private var usesMoonlightApp: Bool { streamBackend == .moonlight }

    /// Built-in streaming needs the Sunshine pairing; the Moonlight app only needs the PC online.
    private var canStream: Bool {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return false }
        return usesMoonlightApp ? moonlightInstalled == true : (sunshine.isPaired && sunshine.reachable)
    }

    /// Favorites first, then Sunshine's order; the desktop has its own button above.
    private var games: [MacSunshineGame] {
        let ordered = (vm.games.filter(\.isFavorite) + vm.games.filter { !$0.isFavorite })
            .filter { $0.title.caseInsensitiveCompare("Desktop") != .orderedSame }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.genre.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { page } } else { page }
        }
        .background(OrbitPalette.canvas)
        .searchable(text: $search, placement: .toolbar, prompt: "Games and apps")
        .toolbar {
            ToolbarItem {
                Button("Stream Settings", systemImage: "slider.horizontal.3") {
                    if usesMoonlightApp { vm.openMoonlight() } else { showsStreamSettings = true }
                }
                .help(usesMoonlightApp ? "Resolution, bitrate and codec are set in the Moonlight app" : "Resolution, frame rate, bitrate, codec, HDR, audio and input")
            }
        }
        .task {
            moonlightInstalled = Self.detectMoonlight()
            await refreshLibrary()
            await vm.refreshLibrary()
        }
        .onChange(of: vm.pendingStreamAction, initial: true) { _, action in
            guard let action else { return }
            vm.pendingStreamAction = nil
            switch action {
            case .desktop: streamDesktop()
            case .settings: showsStreamSettings = true
            }
        }
        .onChange(of: vm.selectedPCID) { _, _ in
            search = ""
            launchingID = nil
            launchStatus = nil
        }
        .sheet(isPresented: $showsPairing) {
            MoonlightPairingView(host: sunshine, pcName: pcName, accent: .accentColor, automation: pairingAutomation) { showsPairing = false }
                .frame(width: 520)
                .background(OrbitPalette.canvas)
        }
        .sheet(isPresented: $showsStreamSettings) {
            MoonlightStreamSettingsView(store: streamSettings, accent: .accentColor, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) { showsStreamSettings = false }
                .frame(width: 560, height: 680)
                .background(OrbitPalette.canvas)
        }
        .confirmationDialog("Forget the Sunshine pairing?", isPresented: $confirmsForgetPairing, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) { sunshine.forgetPairing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit stops streaming from \(pcName) until you pair again. Remove \"\(MoonlightHostCoordinator.deviceName)\" in Sunshine on the PC too if you no longer want it listed.")
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 30) {
            streamCard
            if let launchStatus { statusRow(launchStatus) }
            library
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 44)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: Stream card

    @ViewBuilder
    private var streamCard: some View {
        if vm.isDemoMode {
            card(title: "Sample library", message: "Connect a PC to stream its games to this Mac.") {
                Button("Connect a PC…") { vm.setDemoMode(false); vm.selectedSection = .pcs }
                    .buttonStyle(MacHoverButtonStyle(prominent: true))
            }
        } else if vm.currentPC == nil {
            card(title: "No PC yet", message: "Pair your Windows PC to stream its desktop and games here.") {
                Button("Pair a PC…") { vm.selectedSection = .pcs }
                    .buttonStyle(MacHoverButtonStyle(prominent: true))
            }
        } else if !vm.metrics.isOnline {
            card(title: "Your PC is asleep or off", message: "Wake it to play your games here or start them on the PC.") {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWaking ? "Waking…" : "Wake PC", systemImage: "power")
                }
                .buttonStyle(MacHoverButtonStyle(prominent: true))
                .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty != false)
            }
        } else if usesMoonlightApp {
            card(title: "Streams open in Moonlight",
                 message: moonlightInstalled == true
                    ? "Stream buttons hand the session to the Moonlight app, with its own settings. Pair Moonlight with \(pcName) once inside Moonlight."
                    : "The Moonlight app isn't installed on this Mac. Get it, or switch back to streaming inside Orbit.") {
                if moonlightInstalled == true {
                    Button {
                        vm.streamInMoonlight(appTitle: sunshine.desktopApp?.title ?? "Desktop")
                    } label: {
                        Label("Stream Desktop", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(MacHoverButtonStyle(prominent: true))
                } else {
                    Button("Get Moonlight") { vm.openMoonlight() }
                        .buttonStyle(MacHoverButtonStyle(prominent: true))
                }
            }
        } else if sunshine.isPairing {
            card(title: "Pairing with Sunshine…", message: sunshine.pairingStage ?? "Waiting for the PC.") {
                Button("Cancel") { sunshine.cancelPairing() }
                    .buttonStyle(MacHoverButtonStyle())
            }
        } else if sunshine.isPaired && sunshine.reachable {
            card(title: sunshine.isBusy ? "A stream is open" : "Stream your PC", message: settingsSummary, live: true) {
                Button {
                    if let app = sunshine.desktopApp { start(app) }
                } label: {
                    Label(sunshine.isBusy ? "Resume" : "Stream Desktop", systemImage: "play.fill")
                }
                .buttonStyle(MacHoverButtonStyle(prominent: true))
                .disabled(sunshine.desktopApp == nil)
                .help("Stream the PC's desktop in its own window (⇧⌘S)")
                if vm.metrics.sessionLocked == true {
                    Button {
                        if let app = sunshine.desktopApp { start(app, unlock: true) }
                    } label: {
                        Label("Unlock…", systemImage: "lock.open")
                    }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Opens the sign-in screen and types the password you enter, once. It's never saved.")
                }
                if sunshine.isBusy {
                    Button("End Stream") { Task { await sunshine.quitRunningApp() } }
                        .buttonStyle(MacHoverButtonStyle())
                        .help("Ask Sunshine to end the running app and its stream")
                }
            }
        } else if sunshine.reachable {
            let automatic = pairingAutomation?.canSubmitPIN == true
            card(title: "Stream games to this Mac",
                 message: automatic
                    ? "Pair Orbit with Sunshine on your PC once. Orbit types the code on the PC for you."
                    : "Pair Orbit with Sunshine on your PC once, with the code Orbit shows.") {
                Button(automatic ? "Pair Automatically" : "Pair with Sunshine…") { showsPairing = true }
                    .buttonStyle(MacHoverButtonStyle(prominent: true))
            }
        } else {
            card(title: "Sunshine isn't answering",
                 message: sunshine.isPaired
                    ? "Start Sunshine on \(pcName) to stream. You can still start games on the PC."
                    : "Install or start Sunshine on \(pcName) to stream its games here. You can still start them on the PC.") {
                Button("Try Again") { Task { await sunshine.refresh() } }
                    .buttonStyle(MacHoverButtonStyle())
                    .disabled(sunshine.isRefreshing)
            }
        }
    }

    /// The card's frame: title, one line of state, actions, and the streaming menu.
    private func card<Actions: View>(title: String, message: String, live: Bool = false, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if sunshine.isRefreshing { ProgressView().controlSize(.small) }
                streamingMenu
            }
            HStack(spacing: 10) {
                actions()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var streamingMenu: some View {
        Menu {
            Picker("Stream With", selection: $streamBackendRaw) {
                ForEach(MacStreamBackend.allCases) { backend in Text(backend.title).tag(backend.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh Library") { Task { await refreshLibrary(); await vm.refreshLibrary(rescan: vm.library != nil); await sunshine.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(vm.isDemoMode || !vm.metrics.isOnline)
            if let url = sunshineWebURL {
                Button("Open Sunshine on the PC") { NSWorkspace.shared.open(url) }
            }
            if sunshine.isPaired {
                Divider()
                Button("Forget Sunshine Pairing…") { confirmsForgetPairing = true }
            } else if sunshine.reachable && !usesMoonlightApp {
                Divider()
                Button("Pair with Sunshine…") { showsPairing = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(MacIconButtonStyle(size: 30))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Streaming options")
        .accessibilityLabel("Streaming options")
    }

    private var settingsSummary: String {
        let settings = streamSettings.settings
        var parts = ["\(settings.pixelSize.height)p", "\(settings.frameRate) fps", "\(settings.bitrateKbps / 1000) Mbps"]
        parts.append(settings.codec == .h264 || !MoonlightDeviceCapabilities.supportsHEVC ? "H.264" : "HEVC")
        if settings.requestsHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }

    /// Sunshine's web UI on the PC (its default port is 47990).
    private var sunshineWebURL: URL? {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return nil }
        let host = pc.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(":"), !host.contains("/") else { return nil }
        return URL(string: "https://\(host):\(vm.sunshineInfo?.webUIPort ?? 47990)/")
    }

    /// The agent on the PC can type the pairing PIN and start Sunshine (agent 4.3+).
    private var pairingAutomation: MoonlightPairingAutomation? {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return nil }
        return MoonlightPairingAutomation(canSubmitPIN: vm.sunshineInfo?.canSubmitPin ?? false, canStartSunshine: vm.sunshineInfo?.canStart ?? false,
                                          sunshineRunning: vm.sunshineInfo?.running ?? true, client: { try vm.client() })
    }

    private func statusRow(_ status: String) -> some View {
        let failed = Self.launchWarningPrefixes.contains { status.hasPrefix($0) }
        return HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(failed ? OrbitPalette.warm : OrbitPalette.online)
            Text(status)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                launchStatus = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        if vm.isDemoMode || (vm.currentPC != nil && vm.metrics.isOnline) {
            if vm.library != nil {
                storeLibrary
                if !otherSunshineApps.isEmpty {
                    gameSection(search.isEmpty ? "More in Sunshine" : "In Sunshine", loading: false) {
                        ForEach(otherSunshineApps) { sunshineTile($0) }
                    }
                }
            } else {
                sunshineLibrary
            }
        }
    }

    // Orbit Companion 5: games installed through Steam, Epic and GOG.

    private var libraryGames: [OrbitLibraryGame] {
        let all = vm.library?.games ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.storeName.localizedCaseInsensitiveContains(query) }
    }

    /// Sunshine apps no installed game already stands for (Steam Big Picture, emulators…).
    private var otherSunshineApps: [MacSunshineGame] {
        let covered = Set((vm.library?.games ?? []).compactMap { $0.sunshineApp?.lowercased() })
        return games.filter { !covered.contains($0.title.lowercased()) }
    }

    @ViewBuilder
    private var storeLibrary: some View {
        let shown = libraryGames
        if shown.isEmpty && search.isEmpty {
            gameSection("Library", loading: vm.isLoadingLibrary) {
                EmptyView()
            } empty: {
                placeholder(symbol: "square.grid.2x2", title: "No games found",
                            message: "Orbit looks for games installed with Steam, Epic Games and GOG on the PC.") {
                    Button("Look Again") { Task { await vm.refreshLibrary(rescan: true) } }
                        .buttonStyle(MacHoverButtonStyle())
                }
            }
        } else if shown.isEmpty {
            if otherSunshineApps.isEmpty {
                placeholder(symbol: "magnifyingglass", title: "No matches", message: "Try another name.")
            }
        } else {
            gameSection(search.isEmpty ? "Library" : "Results", loading: vm.isLoadingLibrary) {
                ForEach(shown) { libraryTile($0) }
            }
        }
    }

    private func libraryTile(_ game: OrbitLibraryGame) -> some View {
        let app = game.sunshineApp.flatMap { sunshine.app(titled: $0) }
        let streamAction: (() -> Void)? = {
            guard canStream else { return nil }
            if usesMoonlightApp, let name = game.sunshineApp { return { vm.streamInMoonlight(appTitle: name) } }
            return app.map { app in { start(app) } }
        }()
        return MacLibraryCoverTile(game: game,
                                   isLaunching: launchingID == game.id,
                                   canStart: game.canLaunch && vm.metrics.isOnline,
                                   onStream: streamAction,
                                   onStart: { launchStoreGame(game) })
    }

    private func launchStoreGame(_ game: OrbitLibraryGame) {
        guard launchingID == nil else { return }
        launchingID = game.id
        launchStatus = nil
        Task { @MainActor in
            await vm.launch(game)
            if launchingID == game.id { launchingID = nil }
            launchStatus = vm.statusBanner
        }
    }

    // Sunshine's own list, for companions before 5.

    @ViewBuilder
    private var sunshineLibrary: some View {
        if vm.isLoadingGames && vm.games.isEmpty {
            gameSection("Library", loading: true) { EmptyView() } empty: {
                placeholder(symbol: nil, title: "Reading your library…", message: "Orbit asks the PC for the games Sunshine publishes.")
            }
        } else if games.isEmpty && search.isEmpty {
            gameSection("Library", loading: false) { EmptyView() } empty: {
                placeholder(symbol: "square.grid.2x2", title: "No games yet",
                            message: "Games you add to Sunshine on the PC appear here. In Sunshine, choose Applications, then Add.") {
                    if let url = sunshineWebURL {
                        Button("Open Sunshine on the PC") { NSWorkspace.shared.open(url) }
                            .buttonStyle(MacHoverButtonStyle())
                    }
                }
            }
        } else if games.isEmpty {
            placeholder(symbol: "magnifyingglass", title: "No matches", message: "Try another name.")
        } else {
            gameSection(search.isEmpty ? "Library" : "Results", loading: vm.isLoadingGames) {
                ForEach(games) { sunshineTile($0) }
            }
        }
    }

    private func gameSection<Tiles: View, Empty: View>(_ title: String, loading: Bool, @ViewBuilder tiles: () -> Tiles,
                                                       @ViewBuilder empty: () -> Empty = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            OrbitSectionHeader(title) {
                if loading { ProgressView().controlSize(.small) }
            }
            empty()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                tiles()
            }
        }
    }

    private func sunshineTile(_ game: MacSunshineGame) -> some View {
        let app = sunshine.app(titled: game.title)
        let running = (app != nil && app?.id == sunshine.info?.currentGame)
            || vm.metrics.activeGame.map { $0.caseInsensitiveCompare(game.title) == .orderedSame } == true
        let streamAction: (() -> Void)? = {
            guard canStream else { return nil }
            if usesMoonlightApp { return { vm.streamInMoonlight(appTitle: game.title) } }
            return app.map { app in { start(app) } }
        }()
        return MacGameTile(title: game.title,
                           subtitle: game.isFavorite ? "Favorite" : nil,
                           artwork: app.flatMap { sunshine.artwork[$0.id] }.flatMap(NSImage.init(data:)),
                           isRunning: running,
                           isLaunching: launchingID == game.id,
                           canStart: vm.metrics.isOnline || vm.isDemoMode,
                           command: game.cmd,
                           onStream: streamAction,
                           onStart: { launch(game) })
            .onAppear { if let app { sunshine.loadArtwork(for: app) } }
    }

    private func placeholder<Action: View>(symbol: String?, title: String, message: String, @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Actions

    private func start(_ app: MoonlightApp, unlock: Bool = false) {
        stream.begin(.init(host: sunshine, app: app, pcName: pcName, settings: streamSettings.settings, promptUnlock: unlock))
        openWindow(id: "stream")
    }

    /// ⇧⌘S: stream the desktop, or ask for what is missing first.
    private func streamDesktop() {
        if vm.isDemoMode { launchStatus = "The demo can't stream. Connect a PC to stream it here."; return }
        guard vm.metrics.isOnline else { launchStatus = "Launch stopped: \(pcName) is asleep or off."; return }
        if usesMoonlightApp { vm.streamInMoonlight(appTitle: sunshine.desktopApp?.title ?? "Desktop"); return }
        if canStream, let app = sunshine.desktopApp {
            start(app)
        } else if !sunshine.isPaired {
            if sunshine.reachable { showsPairing = true } else { launchStatus = "Could not reach Sunshine on \(pcName). Is it running?" }
        } else if sunshine.desktopApp == nil {
            launchStatus = "Could not find the desktop in Sunshine. Add Desktop in Sunshine's applications, then refresh."
        }
    }

    @MainActor
    private func refreshLibrary() async {
        guard !vm.isDemoMode, vm.currentPC != nil, vm.metrics.isOnline else { return }
        await vm.refreshGames()
        if vm.statusBanner.hasPrefix(Self.refreshFailurePrefix) { launchStatus = vm.statusBanner }
    }

    /// Starts a game on the PC through the agent; the outcome comes back in `statusBanner`.
    private func launch(_ game: MacSunshineGame) {
        guard launchingID == nil else { return }
        let pcID = vm.selectedPCID
        let demo = vm.isDemoMode
        launchingID = game.id
        launchStatus = nil
        Task { @MainActor in
            await vm.launchGame(game)
            if launchingID == game.id { launchingID = nil }
            guard vm.selectedPCID == pcID, vm.isDemoMode == demo else { return }
            launchStatus = vm.statusBanner
        }
    }

    private static func detectMoonlight() -> Bool {
        if let url = URL(string: "moonlight://"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.moonlight-stream.Moonlight") != nil
    }
}

// MARK: - Tile

/// A game's cover and name. Pointing at it offers Stream and Start on PC; double-click streams.
private struct MacGameTile: View {
    var title: String
    var subtitle: String?
    var artwork: NSImage?
    var isRunning: Bool
    var isLaunching: Bool
    var canStart: Bool
    var command: String? = nil
    var onStream: (() -> Void)?
    var onStart: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacGameCover(title: title, artwork: artwork)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isRunning {
                        Label("Playing", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .orbitGlass()
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hovered || isLaunching {
                        HStack(spacing: 8) {
                            if let onStream {
                                Button(action: onStream) {
                                    Label("Stream", systemImage: "play.fill")
                                }
                                .buttonStyle(MacHoverButtonStyle(prominent: true))
                            }
                            Button(action: onStart) {
                                if isLaunching {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Start on PC", systemImage: "desktopcomputer")
                                        .labelStyle(.iconOnly)
                                }
                            }
                            .buttonStyle(MacHoverButtonStyle())
                            .disabled(!canStart || isLaunching)
                            .help("Start \(title) on the PC")
                        }
                        .padding(10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .scaleEffect(hovered ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(OrbitMotion.quick, value: hovered)
        .onTapGesture(count: 2) { if let onStream { onStream() } else if canStart { onStart() } }
        .contextMenu {
            if let onStream { Button("Stream on This Mac", action: onStream) }
            Button("Start on PC", action: onStart).disabled(!canStart)
            Divider()
            Button("Copy Name") { copy(title) }
            if let command, !command.isEmpty { Button("Copy Command") { copy(command) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Stream") { onStream?() }
        .accessibilityAction(named: "Start on PC") { onStart() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// An installed game from Steam, Epic or GOG; its cover comes from the PC.
private struct MacLibraryCoverTile: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var game: OrbitLibraryGame
    var isLaunching: Bool
    var canStart: Bool
    var onStream: (() -> Void)?
    var onStart: () -> Void
    @State private var cover: NSImage?

    var body: some View {
        MacGameTile(title: game.title, subtitle: game.storeName, artwork: cover, isRunning: game.isRunning,
                    isLaunching: isLaunching, canStart: canStart, onStream: onStream, onStart: onStart)
            .task(id: game.coverID) { cover = await vm.cover(for: game) }
    }
}

/// The game's art, or a quiet symbol when there is none (the name is right below).
struct MacGameCover: View {
    var title: String
    var artwork: NSImage?

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                OrbitPalette.well
                Image(systemName: title.localizedCaseInsensitiveContains("steam") ? "play.rectangle" : "gamecontroller")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .background(OrbitPalette.surface)
    }
}
