import AppKit
import MoonlightCore
import SwiftUI

/// Stream section: the PC desktop and the apps Sunshine publishes, streamed in Orbit's own
/// window with video, audio, mouse, keyboard and controllers; launch-only stays available.
struct MacLibraryView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    @AppStorage(MacStreamBackend.storageKey) private var streamBackendRaw = MacStreamBackend.orbit.rawValue
    @State private var search = ""
    @State private var launchingID: String?
    @State private var launchStatus: String?
    @State private var loadError: String?
    @State private var confirmStop = false
    @State private var moonlightInstalled: Bool?
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @ObservedObject private var stream = MoonlightStreamController.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showsPairing = false
    @State private var showsStreamSettings = false
    @State private var confirmForgetPairing = false

    private static let refreshFailurePrefix = "Could not refresh the Sunshine library"
    private static let launchWarningPrefixes = ["Could not", "Launch stopped", "Moonlight is not installed"]
    private static let moonlightSite = "https://moonlight-stream.org"
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    private var sunshineKey: String { "\(vm.selectedPCID)|\(vm.currentPC?.address ?? "")|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)|\(vm.isDemoMode)" }

    private func syncSunshine() async {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return }
        sunshine.configure(pcID: pc.id, address: pc.address, httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                header
                if vm.isDemoMode { demoNotice }
                if vm.isDemoMode || vm.currentPC != nil { streamHero }
                content
                footer
            }
        }
        .task { await initialLoad() }
        .task(id: sunshineKey) { await syncSunshine() }
        .onChange(of: vm.pendingStreamAction, initial: true) { _, action in
            guard let action else { return }
            vm.pendingStreamAction = nil
            switch action {
            case .desktop: streamDesktop()
            case .settings: showsStreamSettings = true
            }
        }
        .sheet(isPresented: $showsPairing) {
            MoonlightPairingView(host: sunshine, pcName: pcName, accent: theme.accent, automation: pairingAutomation) { showsPairing = false }
                .frame(width: 520)
                .background(theme.background)
        }
        .sheet(isPresented: $showsStreamSettings) {
            MoonlightStreamSettingsView(store: streamSettings, accent: theme.accent, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) { showsStreamSettings = false }
                .frame(width: 560, height: 680)
                .background(theme.background)
        }
        .confirmationDialog("Forget the Sunshine pairing?", isPresented: $confirmForgetPairing, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) { sunshine.forgetPairing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit drops its Sunshine pairing for \(pcName). Remove \"\(MoonlightHostCoordinator.deviceName)\" in Sunshine's web UI too if you no longer want it listed.")
        }
        .onChange(of: vm.selectedPCID) { _, _ in
            search = ""
            launchingID = nil
            launchStatus = nil
            loadError = nil
            Task { await refresh() }
        }
        // The view model also refreshes the library on its own (first poll after
        // reconnecting), so drop a stale failure notice once apps arrive that way.
        .onChange(of: vm.games) { _, games in
            if !games.isEmpty { loadError = nil }
        }
        .confirmationDialog("Stop the running game?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Game", role: .destructive) { Task { await vm.sendAction("kill_game") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit asks \(pcName) to end \(vm.metrics.activeGame ?? "the active game"). Unsaved progress may be lost.")
        }
    }

    // MARK: - Derived state

    private var pcName: String { vm.selectedPCName }
    private var fpsHistory: [Double] { vm.history.values(for: .fps) }
    private var favoriteCount: Int { vm.games.filter(\.isFavorite).count }
    private var fpsText: String { vm.metrics.fps.flatMap { $0 > 0 ? "\(Int($0.rounded()))" : nil } ?? "—" }

    /// Favourites first, then the order Sunshine reports; filtered by the local search box.
    private var filteredGames: [MacSunshineGame] {
        let ordered = vm.games.filter(\.isFavorite) + vm.games.filter { !$0.isFavorite }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { game in
            game.title.localizedCaseInsensitiveContains(query)
                || game.genre.localizedCaseInsensitiveContains(query)
                || (game.cmd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Sunshine's Web UI on the paired PC (its documented default port is 47990).
    private var sunshineWebURL: URL? {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return nil }
        let host = pc.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(":"), !host.contains("/") else { return nil }
        return URL(string: "https://\(host):47990/")
    }

    // MARK: - Header

    private var header: some View {
        MacSectionHeader("Stream", subtitle: "Play \(pcName) on this Mac: desktop or any Sunshine app, with audio, mouse, keyboard and controllers", icon: "play.rectangle.fill") {
            HStack(spacing: 10) {
                if vm.isLoadingGames && !vm.games.isEmpty {
                    ProgressView().controlSize(.small)
                }
                searchField
                refreshButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
                .font(.callout)
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 210)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var refreshButton: some View {
        Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(MacIconButtonStyle(size: 26))
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(vm.isDemoMode || !vm.metrics.isOnline || vm.isLoadingGames)
            .help("Refresh the Sunshine app list (⌥⌘R)")
            .accessibilityLabel("Refresh library")
    }

    private var demoNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo mode · simulated library. Launching only updates the preview telemetry.")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Pair a PC") { vm.setDemoMode(false); vm.selectedSection = .pcs }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .orange)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if vm.currentPC == nil && !vm.isDemoMode {
            unpairedState
        } else if !vm.metrics.isOnline {
            offlineState
        } else {
            statsRow
            if let game = vm.metrics.activeGame, !game.isEmpty { nowPlaying(game) }
            if let launchStatus { launchStatusRow(launchStatus) }
            if let loadError {
                MacNotice(title: "Library unavailable", message: loadError, icon: "exclamationmark.triangle.fill", tint: .orange)
            }
            libraryBody
        }
    }

    @ViewBuilder
    private var libraryBody: some View {
        if vm.isLoadingGames && vm.games.isEmpty {
            loadingCard
        } else if vm.games.isEmpty {
            if loadError == nil { emptyState }
            addAppsNotice
        } else if filteredGames.isEmpty {
            filteredEmpty
        } else {
            grid
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            MacStatChip(label: "Apps", value: "\(vm.games.count)", icon: "square.grid.2x2")
            if favoriteCount > 0 {
                MacStatChip(label: "Favorites", value: "\(favoriteCount)", icon: "star.fill", tint: .yellow)
            }
            if !search.isEmpty {
                MacStatChip(label: "Matching", value: "\(filteredGames.count)", icon: "magnifyingglass")
            }
            Spacer(minLength: 0)
        }
    }

    private var sunshineTint: Color {
        switch sunshine.statusTone {
        case .good: return .mint
        case .active: return theme.accent
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    private var heroTint: Color {
        if vm.isDemoMode { return .orange }
        if !vm.metrics.isOnline { return .orange }
        return sunshineTint
    }

    private var heroStatus: String {
        if vm.isDemoMode { return "Demo" }
        if !vm.metrics.isOnline { return "PC offline" }
        return sunshine.statusText
    }

    private var heroMessage: String {
        if vm.isDemoMode { return "Pair your Windows PC in My PCs. Orbit then streams its desktop and games right here, with video, audio, mouse, keyboard and controllers." }
        if !vm.metrics.isOnline { return "Power the PC on and Orbit reconnects by itself. Streaming needs the PC awake and Sunshine running." }
        if usesMoonlightApp { return "Stream buttons hand the session to the Moonlight app on this Mac. Switch to Orbit for built-in streaming with mouse and keyboard capture (⌃⌥⇧Z releases, ⌃⌥⇧Q ends)." }
        return sunshine.summary(pcName: pcName)
    }

    /// The Stream card: pairing state, running session, the one-click desktop stream and the
    /// settings in use. Same card as at the top of the iPhone's Stream tab.
    private var streamHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                MacIconBadge(systemName: "play.rectangle.fill", tint: heroTint, size: 46, filled: sunshine.isPaired && vm.metrics.isOnline)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Stream \(pcName)")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        MacStatusPill(text: heroStatus, tint: heroTint, pulsing: sunshine.isBusy && vm.metrics.isOnline)
                        if !vm.isDemoMode, vm.metrics.isOnline {
                            if sunshine.isPaired {
                                MacStatChip(label: "Apps", value: "\(sunshine.apps.count)")
                            } else if sunshine.reachable, let info = sunshine.info, !info.hostname.isEmpty {
                                MacStatChip(label: "Host", value: info.hostname)
                            }
                        }
                    }
                    Text(heroMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !vm.isDemoMode, vm.metrics.isOnline, let error = sunshine.lastError, !sunshine.isPairing {
                        Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if sunshine.isRefreshing || sunshine.isPairing { ProgressView().controlSize(.small) }
                backendPicker
            }
            HStack(spacing: 10) {
                if vm.isDemoMode {
                    Button { vm.setDemoMode(false); vm.selectedSection = .pcs } label: { Label("Pair a PC", systemImage: "desktopcomputer") }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                    streamSettingsButton
                } else if !vm.metrics.isOnline {
                    Button { Task { await vm.wakePC() } } label: { Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power") }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                        .disabled(vm.isWaking)
                        .help("Send a Wake-on-LAN packet")
                    streamSettingsButton
                } else if usesMoonlightApp {
                    streamDesktopButton
                    streamSettingsButton
                    if moonlightInstalled == false {
                        Button { open(Self.moonlightSite) } label: { Label("Get Moonlight", systemImage: "arrow.down.circle") }
                            .buttonStyle(MacHoverButtonStyle())
                            .help("Open moonlight-stream.org in your browser")
                    }
                    Spacer(minLength: 0)
                    if let url = sunshineWebURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Sunshine Web UI", systemImage: "globe") }
                            .buttonStyle(MacHoverButtonStyle())
                            .help("Open \(url.absoluteString)")
                    }
                } else if sunshine.isPairing {
                    Button { sunshine.cancelPairing() } label: { Label("Cancel Pairing", systemImage: "xmark") }
                        .buttonStyle(MacHoverButtonStyle(tint: .orange))
                } else if sunshine.isPaired {
                    streamDesktopButton
                    streamSettingsButton
                    if vm.metrics.sessionLocked == true {
                        Button {
                            if let app = sunshine.desktopApp { startStream(app, promptUnlock: true) }
                        } label: { Label("Unlock PC…", systemImage: "lock.open.fill") }
                            .buttonStyle(MacHoverButtonStyle(tint: .yellow))
                            .disabled(!canStream || sunshine.desktopApp == nil)
                            .help("Open the stream at the sign-in screen and type the Windows password there (nothing is saved)")
                    }
                    if sunshine.isBusy {
                        Button { Task { await sunshine.quitRunningApp() } } label: { Label("Quit Session", systemImage: "stop.fill") }
                            .buttonStyle(MacHoverButtonStyle(tint: .orange))
                            .help("Ask Sunshine to end the running app and its stream")
                    }
                    Spacer(minLength: 0)
                    Button { Task { await sunshine.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(MacIconButtonStyle(size: 26))
                        .disabled(sunshine.isRefreshing)
                        .help("Refresh Sunshine status")
                        .accessibilityLabel("Refresh Sunshine status")
                    Button { confirmForgetPairing = true } label: { Image(systemName: "link.badge.minus") }
                        .buttonStyle(MacIconButtonStyle(size: 26))
                        .help("Forget the Sunshine pairing")
                        .accessibilityLabel("Forget the Sunshine pairing")
                } else {
                    let automatic = pairingAutomation?.canSubmitPIN == true
                    Button { showsPairing = true } label: {
                        Label(automatic ? "Pair automatically" : "Pair with Sunshine", systemImage: automatic ? "wand.and.stars" : "link")
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: sunshine.reachable))
                    .disabled(!sunshine.reachable)
                    .help(sunshine.reachable ? "Pair Orbit with Sunshine once; afterwards Stream connects straight away" : "Sunshine did not answer on the PC")
                    streamSettingsButton
                    Spacer(minLength: 0)
                    if let url = sunshineWebURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Sunshine Web UI", systemImage: "globe") }
                            .buttonStyle(MacHoverButtonStyle())
                            .help("Open \(url.absoluteString)")
                    }
                }
            }
            Text(usesMoonlightApp ? (moonlightInstalled == true ? "Streams open in the Moonlight app with its own settings; pair Moonlight with the PC once." : "The Moonlight app is not installed on this Mac.") : settingsSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 20, tint: heroTint, elevated: true)
    }

    private var unpairedState: some View {
        VStack(spacing: 0) {
            MacEmptyState(
                icon: "desktopcomputer",
                title: "No PC paired",
                message: "Pair your Windows PC, or import the one you already paired on your iPhone, to browse the apps Sunshine publishes for streaming.",
                tint: theme.accent,
                actionTitle: "Pair or import a PC",
                action: { vm.selectedSection = .pcs }
            )
            Button("Try Demo Mode") { vm.setDemoMode(true) }
                .buttonStyle(MacHoverButtonStyle())
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private var offlineMessage: String {
        var text = "Connect to your PC to load the apps Sunshine publishes. Send a Wake-on-LAN packet or retry the connection."
        if let error = vm.connectionError, !error.isEmpty { text += "\n\(error)" }
        return text
    }

    /// Wake-on-LAN and reconnect outcomes only reach `statusBanner`; show them here
    /// unless the banner just repeats the offline message already in the card.
    private var offlineBanner: String? {
        let banner = vm.statusBanner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !banner.isEmpty, !banner.hasPrefix("\(pcName) is offline") else { return nil }
        return banner
    }

    private var offlineState: some View {
        VStack(spacing: 0) {
            MacEmptyState(
                icon: "wifi.slash",
                title: "\(pcName) is offline",
                message: offlineMessage,
                tint: .orange,
                actionTitle: vm.isWaking ? "Waking…" : "Power On",
                action: { Task { await vm.wakePC() } }
            )
            .disabled(vm.isWaking)
            HStack(spacing: 10) {
                Button { Task { await vm.refreshMetrics() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(MacHoverButtonStyle())
                Button { vm.selectedSection = .pcs } label: { Label("My PCs", systemImage: "desktopcomputer") }
                    .buttonStyle(MacHoverButtonStyle())
            }
            if let banner = offlineBanner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .macGlass(cornerRadius: 22, tint: .orange, elevated: true)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading the Sunshine app list…").font(.subheadline.weight(.semibold))
                Text("Orbit asks the agent on \(pcName) for the applications Sunshine publishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 16, tint: theme.accent)
    }

    private var emptyState: some View {
        MacEmptyState(
            icon: "square.grid.2x2",
            title: "No apps published",
            message: "Sunshine on \(pcName) has not published any applications yet, so there is nothing to launch. Add apps in the Sunshine Web UI, then refresh.",
            tint: theme.accent,
            actionTitle: "Refresh",
            action: { Task { await refresh() } }
        )
        .macGlass(cornerRadius: 22, tint: theme.accent)
    }

    private var addAppsNotice: some View {
        MacNotice(
            title: "How to add apps",
            message: "On the PC, open the Sunshine Web UI (default https://localhost:47990), choose Applications → Add, give the app a name and its command or executable, then Save. Orbit lists it after the next refresh.",
            icon: "plus.app",
            tint: theme.accent
        )
    }

    private var filteredEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No apps match “\(search)”").font(.subheadline.weight(.semibold))
            Text("\(vm.games.count) app\(vm.games.count == 1 ? " is" : "s are") published on \(pcName). Clear the search to see them all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Search") { search = "" }
                .buttonStyle(MacHoverButtonStyle())
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .macGlass(cornerRadius: 18)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(filteredGames) { game in
                let app = sunshine.app(titled: game.title)
                MacLibraryTile(
                    game: game,
                    symbol: MacLibraryIcon.symbol(for: game),
                    accent: theme.isFlat ? theme.accent : MacLibraryIcon.accent(for: game, fallback: theme.accent),
                    artwork: app.flatMap { sunshine.artwork[$0.id] },
                    isRunning: app != nil && app?.id == sunshine.info?.currentGame,
                    isLaunching: launchingID == game.id,
                    isBusy: launchingID != nil,
                    onLaunch: { launch(game) },
                    onStream: canStream ? (usesMoonlightApp ? { vm.streamInMoonlight(appTitle: game.title) } : app.map { app in { startStream(app) } }) : nil,
                    onSettings: usesMoonlightApp ? nil : { showsStreamSettings = true }
                )
                .onAppear { if let app { sunshine.loadArtwork(for: app) } }
            }
        }
        .animation(.snappy(duration: 0.25), value: filteredGames)
    }

    // MARK: - Now Playing

    private var gameTint: Color { theme.isFlat ? theme.accent : .mint }
    private var nowPlayingGradient: LinearGradient {
        LinearGradient(colors: [gameTint.opacity(theme.isFlat ? 0.08 : 0.16), gameTint.opacity(0.03), .clear], startPoint: .leading, endPoint: .trailing)
    }

    private func nowPlaying(_ title: String) -> some View {
        HStack(spacing: 14) {
            MacIconBadge(systemName: "gamecontroller.fill", tint: gameTint, size: 46, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("NOW PLAYING")
                    .font(.system(.caption2, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(gameTint)
                Text(title)
                    .font(.system(.title3, weight: .bold))
                    .lineLimit(1)
                nowPlayingDetails
            }
            Spacer(minLength: 8)
            if fpsHistory.count >= 3 {
                MacSparkline(values: fpsHistory, tint: gameTint, lineWidth: 1.6)
                    .frame(width: 150, height: 34)
                    .opacity(0.7)
            }
            fpsReadout
            Button { confirmStop = true } label: { Label("Stop Game", systemImage: "stop.fill") }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
                .help("Ask the PC to end the running game")
            Button {
                if !usesMoonlightApp, canStream, let app = sunshine.app(titled: title) { startStream(app) } else { vm.streamInMoonlight(appTitle: title) }
            } label: { Label("Stream", systemImage: usesMoonlightApp ? "arrow.up.forward.app" : "play.rectangle.fill") }
                .buttonStyle(MacHoverButtonStyle(tint: gameTint, prominent: true))
                .disabled(!canStream)
                .help(usesMoonlightApp ? "Open this app's stream in the Moonlight app" : "Watch and control this app from this Mac")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(nowPlayingGradient))
        .macGlass(cornerRadius: 20, tint: gameTint, elevated: true)
    }

    @ViewBuilder
    private var nowPlayingDetails: some View {
        HStack(spacing: 8) {
            if let process = vm.metrics.activeGameProcess, !process.isEmpty {
                MacStatChip(label: "Process", value: process, icon: "terminal")
            }
            if let fps = vm.metrics.fps, fps > 0 {
                MacStatChip(label: "Frametime", value: "\(MacFormat.decimal(1000 / fps, digits: 1)) ms", icon: "timer")
                if let source = vm.metrics.fpsSource, !source.isEmpty {
                    MacStatChip(label: "Source", value: source)
                }
            } else if let reason = vm.metrics.fpsUnavailableReason, !reason.isEmpty {
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var fpsReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(fpsText)
                .font(.system(size: 32, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(gameTint)
                .contentTransition(.numericText())
                .shadow(color: reduceGlow ? .clear : gameTint.opacity(0.45), radius: 10)
            Text("FPS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fpsText) frames per second")
    }

    private func launchStatusRow(_ status: String) -> some View {
        let failed = Self.launchWarningPrefixes.contains { status.hasPrefix($0) }
        return HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Color.orange : Color.mint)
            Text(status).font(.caption.weight(.medium)).lineLimit(2)
            Spacer(minLength: 8)
            Button { launchStatus = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(MacIconButtonStyle(size: 22))
                .help("Dismiss")
                .accessibilityLabel("Dismiss launch status")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: failed ? .orange : .mint)
    }

    // MARK: - Footer

    private var footerMessage: String {
        if usesMoonlightApp {
            return "Stream buttons open the Moonlight app (`Moonlight stream <pc> \"<app>\"`). Pair Moonlight with \(pcName) once inside Moonlight."
        }
        if sunshine.isPaired {
            return "Press Stream on an app, or Stream Desktop above, to play \(pcName) in its own window (⇧⌘S). Click the video to capture the mouse and keyboard; ⌃⌥⇧Z releases them and ⌃⌥⇧Q ends the stream."
        }
        return "Pair with Sunshine once (PIN) and Orbit streams \(pcName) here with full mouse, keyboard and controller input."
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: "play.tv", tint: theme.accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Streaming").font(.subheadline.weight(.semibold))
                Text(footerMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let url = sunshineWebURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Sunshine Web UI", systemImage: "globe") }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Open \(url.absoluteString) — Sunshine's default Web UI port is 47990")
            }
            if usesMoonlightApp {
                Button {
                    vm.openMoonlight()
                    moonlightInstalled = Self.detectMoonlight()
                } label: {
                    Label(moonlightInstalled == true ? "Moonlight App" : "Get Moonlight", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(MacHoverButtonStyle())
                .keyboardShortcut("m", modifiers: [.command, .option])
                .help("Open the Moonlight app, or its download page if it is not installed (⌥⌘M)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: theme.accent)
    }

    // MARK: - Streaming

    private var streamBackend: MacStreamBackend {
        get { MacStreamBackend(rawValue: streamBackendRaw) ?? .orbit }
        nonmutating set { streamBackendRaw = newValue.rawValue }
    }
    private var usesMoonlightApp: Bool { streamBackend == .moonlight }
    /// Built-in streaming needs the Sunshine pairing; the Moonlight app only needs the PC online.
    private var canStream: Bool {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return false }
        return usesMoonlightApp ? moonlightInstalled == true : (sunshine.isPaired && sunshine.reachable)
    }

    private var backendPicker: some View {
        Picker("Stream with", selection: Binding(get: { streamBackend }, set: { streamBackend = $0 })) {
            ForEach(MacStreamBackend.allCases) { backend in Text(backend.title).tag(backend) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .help("Built-in streaming inside Orbit, or hand the session to the separate Moonlight app")
    }

    /// The agent on the PC can type the pairing PIN and start Sunshine (agent 4.3+).
    private var pairingAutomation: MoonlightPairingAutomation? {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return nil }
        return MoonlightPairingAutomation(canSubmitPIN: vm.sunshineInfo?.canSubmitPin ?? false, canStartSunshine: vm.sunshineInfo?.canStart ?? false,
                                          sunshineRunning: vm.sunshineInfo?.running ?? true, client: { try vm.client() })
    }

    private var streamDesktopButton: some View {
        Button {
            if usesMoonlightApp { vm.streamInMoonlight(appTitle: sunshine.desktopApp?.title ?? "Desktop") }
            else if let app = sunshine.desktopApp { startStream(app) }
        } label: {
            Label(sunshine.isBusy ? "Resume Stream" : "Stream Desktop", systemImage: usesMoonlightApp ? "arrow.up.forward.app" : "play.rectangle.fill")
        }
        .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
        .disabled(!canStream || (!usesMoonlightApp && sunshine.desktopApp == nil))
        .help(usesMoonlightApp ? "Open the desktop stream in the Moonlight app (⇧⌘S)" : (sunshine.desktopApp == nil ? "Sunshine publishes no apps yet" : "Stream the PC desktop in a window (⇧⌘S)"))
    }

    @ViewBuilder
    private var streamSettingsButton: some View {
        if usesMoonlightApp {
            Button { vm.openMoonlight() } label: { Label("Moonlight Settings", systemImage: "arrow.up.forward.app") }
                .buttonStyle(MacHoverButtonStyle())
                .help("Resolution, bitrate and codec are set inside the Moonlight app")
        } else {
            Button { showsStreamSettings = true } label: { Label("Stream Settings", systemImage: "slider.horizontal.3") }
                .buttonStyle(MacHoverButtonStyle())
                .help("Resolution, frame rate, bitrate, codec, HDR, audio, input and network")
        }
    }

    /// ⇧⌘S and the hero button: stream the desktop, or start pairing when that is still missing.
    private func streamDesktop() {
        if vm.isDemoMode { launchStatus = "Demo mode: pair a real PC in My PCs to stream it here."; return }
        guard vm.metrics.isOnline else { launchStatus = "\(pcName) is offline. Power it on, then press Stream Desktop again."; return }
        if usesMoonlightApp { vm.streamInMoonlight(appTitle: sunshine.desktopApp?.title ?? "Desktop"); return }
        if canStream, let app = sunshine.desktopApp {
            startStream(app)
        } else if !sunshine.isPaired {
            if sunshine.reachable { showsPairing = true } else { launchStatus = "Sunshine did not answer on \(pcName). Is it running?" }
        } else if sunshine.desktopApp == nil {
            launchStatus = "Sunshine publishes no apps yet. Add Desktop in its web UI, then refresh."
        }
    }

    private var settingsSummary: String {
        let settings = streamSettings.settings
        let size = settings.pixelSize(hostSupportsHEVC: sunshine.info?.supportsHEVC)
        var parts = [size.shortTitle, "\(settings.frameRate) fps", "\(settings.bitrateKbps(for: size) / 1000) Mbps"]
        parts.append(settings.codec == .h264 || !MoonlightDeviceCapabilities.supportsHEVC ? "H.264" : "HEVC")
        if settings.requestsHDR { parts.append("HDR") }
        parts.append(settings.audio.title)
        return parts.joined(separator: " · ")
    }

    private func startStream(_ app: MoonlightApp, promptUnlock: Bool = false) {
        // Sized for the display the Stream window will fill: the open Stream window's, else the one in front.
        let target = MoonlightStreamTarget.make(settings: streamSettings.settings, hostSupportsHEVC: sunshine.info?.supportsHEVC,
                                                screen: MacStreamWindowController.shared.targetScreen())
        stream.begin(.init(host: sunshine, app: app, pcName: pcName, settings: streamSettings.settings, target: target, promptUnlock: promptUnlock))
        openWindow(id: "stream")
    }

    // MARK: - Actions

    @MainActor
    private func initialLoad() async {
        moonlightInstalled = Self.detectMoonlight()
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard !vm.isDemoMode, vm.currentPC != nil, vm.metrics.isOnline else { return }
        loadError = nil
        await vm.refreshGames()
        if vm.statusBanner.hasPrefix(Self.refreshFailurePrefix) { loadError = vm.statusBanner }
    }

    /// Launches through the view model, which also opens Moonlight when the
    /// `mac.autoOpenMoonlight` preference is on, and surfaces the outcome.
    /// `launchGame` returns `Void`, so the result is read back from `statusBanner`
    /// right after the await (same actor, no suspension in between). If the user
    /// switched PCs meanwhile the banner belongs to the new PC and is ignored.
    private func launch(_ game: MacSunshineGame) {
        guard launchingID == nil else { return }
        let pcID = vm.selectedPCID
        let demo = vm.isDemoMode
        launchingID = game.id
        launchStatus = nil
        Task { @MainActor in
            await vm.launchGame(game)
            // Always release the busy flag, even when the outcome is discarded
            // below, so the tiles never stay disabled after a PC/demo switch.
            if launchingID == game.id { launchingID = nil }
            guard vm.selectedPCID == pcID, vm.isDemoMode == demo else { return }
            launchStatus = vm.statusBanner
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private static func detectMoonlight() -> Bool {
        if let url = URL(string: "moonlight://"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.moonlight-stream.Moonlight") != nil
    }
}

// MARK: - Tile

/// Tall glass card for one Sunshine app. Launch appears on hover, keyboard focus or while launching.
private struct MacLibraryTile: View {
    let game: MacSunshineGame
    let symbol: String
    let accent: Color
    var artwork: Data? = nil
    var isRunning = false
    let isLaunching: Bool
    let isBusy: Bool
    let onLaunch: () -> Void
    var onStream: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    @State private var hovered = false
    @FocusState private var launchFocused: Bool

    private var showsLaunch: Bool { hovered || launchFocused || isLaunching }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                if artwork != nil {
                    MoonlightArtwork(data: artwork)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                } else {
                    MacIconBadge(systemName: symbol, tint: accent, size: 56, filled: showsLaunch)
                }
                Spacer(minLength: 0)
                if isRunning {
                    MacStatusPill(text: "Running", tint: accent, pulsing: true)
                }
                if game.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.yellow)
                        .help("Marked as a favourite")
                        .accessibilityLabel("Favourite")
                }
            }
            titleBlock
            Spacer(minLength: 0)
            launchArea
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .macGlass(cornerRadius: 18, tint: accent, hovered: hovered)
        .macHoverLift()
        .onHover { hovered = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(count: 2) { if let onStream { onStream() } else if !isBusy { onLaunch() } }
        .contextMenu { contextItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(game.title)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(game.title)
                .font(.system(.headline, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            if !game.genre.isEmpty {
                Text(game.genre)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let cmd = game.cmd, !cmd.isEmpty {
                Text(cmd)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cmd)
            }
        }
    }

    private var launchArea: some View {
        ZStack(alignment: .leading) {
            Text(onStream != nil ? "Double-click to stream" : "Double-click to launch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(showsLaunch ? 0 : 1)
                .accessibilityHidden(true)
            Button(action: { if let onStream { onStream() } else { onLaunch() } }) {
                HStack(spacing: 6) {
                    if isLaunching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: onStream != nil ? "play.rectangle.fill" : "play.fill")
                    }
                    Text(isLaunching ? "Launching…" : (onStream != nil ? "Stream" : "Launch"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle(tint: accent, prominent: true))
            .focused($launchFocused)
            .disabled(isBusy && !isLaunching)
            .opacity(showsLaunch ? 1 : 0)
            .help("Launch \(game.title) through Sunshine")
            .accessibilityLabel("Launch \(game.title)")
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.15), value: showsLaunch)
    }

    @ViewBuilder
    private var contextItems: some View {
        Button { onLaunch() } label: { Label("Launch", systemImage: "play.fill") }
            .disabled(isBusy)
        if let onStream {
            Button { onStream() } label: { Label("Stream", systemImage: "play.rectangle.fill") }
        }
        if let onSettings {
            Button { onSettings() } label: { Label("Stream Settings…", systemImage: "slider.horizontal.3") }
        }
        Button { copy(game.title) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
        if let cmd = game.cmd, !cmd.isEmpty {
            Button { copy(cmd) } label: { Label("Copy Command", systemImage: "terminal") }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Icon & accent resolution

/// Picks a glyph for an app: the symbol the agent reports when it is a real SF
/// Symbol, otherwise an honest name-based fallback.
private enum MacLibraryIcon {
    static func symbol(for game: MacSunshineGame) -> String {
        let provided = game.iconSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if !provided.isEmpty, NSImage(systemSymbolName: provided, accessibilityDescription: nil) != nil {
            return provided
        }
        let name = game.title.lowercased()
        if name.contains("desktop") { return "display" }
        if name.contains("big picture") || name.contains("playnite") || name.contains("launcher") { return "play.rectangle.fill" }
        return "gamecontroller.fill"
    }

    static func accent(for game: MacSunshineGame, fallback: Color) -> Color {
        let hex = game.accentHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return fallback }
        return Color(hex: hex)
    }
}


// MARK: - Stream window

/// The `stream` window: shows the live session, goes full screen when a stream starts (setting
/// `mac.streamFullScreen`) and leaves full screen before it closes itself once the stream ends.
struct MacStreamWindowView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var stream = MoonlightStreamController.shared
    @AppStorage(MacStreamWindowController.fullScreenKey) private var opensInFullScreen = true
    /// The stream ended and the window is on its way out (leaving full screen first): stay black.
    @State private var closing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if stream.isPresented {
                MoonlightStreamScreen(controller: stream, accent: theme.accent)
            } else if !closing {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                    Text("No stream running").font(.headline)
                    Text("Choose an app in Stream and press Stream, or press ⇧⌘S for the desktop.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .background(MacStreamWindowAccessor { window in
            MacStreamWindowController.shared.attach(window)
            presentCurrentStream()
        })
        .onAppear {
            closing = false
            presentCurrentStream()
        }
        .onChange(of: stream.request?.id) { _, _ in presentCurrentStream() }
        .onChange(of: stream.isPresented) { _, presented in
            if presented {
                closing = false
                presentCurrentStream()
            } else {
                closing = true
                // Closing a full-screen window would leave an empty black Space behind: leave full screen first.
                MacStreamWindowController.shared.leaveFullScreen {
                    if !MoonlightStreamController.shared.isPresented { dismissWindow(id: "stream") }
                }
            }
        }
    }

    private func presentCurrentStream() {
        guard stream.isPresented, let request = stream.request else { return }
        MacStreamWindowController.shared.streamStarted(request.id, displayID: request.target.displayID, fullScreen: opensInFullScreen)
    }
}

/// Hands the hosting `NSWindow` to `MacStreamWindowController` once the view is in it.
private struct MacStreamWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> MacStreamWindowAccessorView {
        let view = MacStreamWindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: MacStreamWindowAccessorView, context: Context) {
        nsView.onWindow = onWindow
    }
}

@MainActor
private final class MacStreamWindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

/// The Stream window's full-screen life: entering true full screen on the display the stream was sized
/// for, and leaving it (waiting for the animation) before the window is dismissed, so no empty Space is
/// left behind. Full-screen changes made by the user (green button, ⌃⌥⇧F) go through the same
/// notifications, so the state stays right whoever started them.
@MainActor
final class MacStreamWindowController {
    static let shared = MacStreamWindowController()
    /// "Open streams in full screen" in Settings › General.
    nonisolated static let fullScreenKey = "mac.streamFullScreen"

    /// Full screen wanted for the current stream, on `displayID` (nil: wherever the window is).
    private struct PendingEnter { let displayID: UInt32? }

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// A full-screen animation is running; AppKit ignores toggles until it ends.
    private var transitioning = false
    private var transitionWatchdog: Task<Void, Never>?
    private var handledStreamID: UUID?
    private var pendingEnter: PendingEnter?
    private var exitCompletions: [() -> Void] = []
    private var exitGeneration = 0

    /// The display a new stream should be sized for: the open Stream window's, else the one in front.
    func targetScreen() -> NSScreen? {
        if let window, window.isVisible, let screen = window.screen { return screen }
        return NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window
        transitioning = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        let center = NotificationCenter.default
        let events: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, true),
            (NSWindow.didEnterFullScreenNotification, false), (NSWindow.didExitFullScreenNotification, false),
        ]
        for (name, starts) in events {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if starts { self?.transitionStarted() } else { self?.transitionEnded() }
                }
            })
        }
        if pendingEnter != nil { enterWhenReady() }
    }

    /// A stream was requested in the window. Each stream asks once, so leaving full screen by hand sticks
    /// for that stream (reconnecting keeps it).
    func streamStarted(_ id: UUID, displayID: UInt32?, fullScreen: Bool) {
        guard id != handledStreamID else { return }
        handledStreamID = id
        pendingEnter = fullScreen ? PendingEnter(displayID: displayID) : nil
        if fullScreen { enterWhenReady() }
    }

    /// Leaves full screen if needed, then calls `completion` (right away when the window is not full screen).
    func leaveFullScreen(then completion: @escaping () -> Void) {
        pendingEnter = nil
        handledStreamID = nil
        guard let window, transitioning || window.styleMask.contains(.fullScreen) else { completion(); return }
        exitCompletions.append(completion)
        exitGeneration += 1
        let generation = exitGeneration
        if !transitioning { window.toggleFullScreen(nil) }
        // Never strand the window if AppKit does not report the end of the animation.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.exitGeneration == generation else { return }
            self.finishExit()
        }
    }

    private func transitionStarted() {
        transitioning = true
        transitionWatchdog?.cancel()
        transitionWatchdog = Task { [weak self] in
            // AppKit reports a failed transition only to the window's delegate, which SwiftUI owns.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transitionEnded()
        }
    }

    private func transitionEnded() {
        transitionWatchdog?.cancel()
        transitionWatchdog = nil
        transitioning = false
        guard let window else { return }
        if !exitCompletions.isEmpty {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { finishExit() }
            return
        }
        if pendingEnter != nil { enterWhenReady() }
    }

    private func finishExit() {
        let completions = exitCompletions
        exitCompletions = []
        completions.forEach { $0() }
    }

    /// Enters full screen once the window is on screen and no animation or exit is under way.
    private func enterWhenReady(attempt: Int = 0) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: attempt == 0 ? 50_000_000 : 100_000_000)
            self?.enterIfReady(attempt: attempt)
        }
    }

    private func enterIfReady(attempt: Int) {
        guard let pending = pendingEnter else { return }
        guard let window, window.isVisible else {
            // SwiftUI has not shown the window yet; `attach` tries again once it has.
            if attempt < 30 { enterWhenReady(attempt: attempt + 1) }
            return
        }
        guard !transitioning, exitCompletions.isEmpty else { return }   // `transitionEnded` resumes
        pendingEnter = nil
        guard !window.styleMask.contains(.fullScreen) else { return }
        move(window, toDisplay: pending.displayID)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    /// Full screen happens on the window's display, so it first moves to the display the stream was sized for.
    private func move(_ window: NSWindow, toDisplay displayID: UInt32?) {
        guard let displayID,
              let screen = NSScreen.screens.first(where: { MoonlightDeviceCapabilities.displayID(of: $0) == displayID }),
              window.screen.flatMap({ MoonlightDeviceCapabilities.displayID(of: $0) }) != displayID else { return }
        let area = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        window.setFrame(frame, display: true)
    }
}
