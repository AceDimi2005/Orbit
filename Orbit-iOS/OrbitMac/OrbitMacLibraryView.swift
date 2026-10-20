import AppKit
import SwiftUI

/// Sunshine game library: the applications the PC publishes for Moonlight
/// streaming, with one-click launch and a Now Playing banner.
struct MacLibraryView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    /// Same key and default as Settings and `OrbitMacViewModel.launchGame`, which
    /// reads it with `UserDefaults.bool` (absent → off), so the three always agree.
    @AppStorage("mac.autoOpenMoonlight") private var autoOpenMoonlight = false
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    @State private var search = ""
    @State private var launchingID: String?
    @State private var launchStatus: String?
    @State private var loadError: String?
    @State private var confirmStop = false
    @State private var moonlightInstalled: Bool?

    private static let refreshFailurePrefix = "Could not refresh the Sunshine library"
    private static let launchWarningPrefixes = ["Could not", "Launch stopped", "Moonlight is not installed"]
    /// Computed rather than a stored static so no non-Sendable value lives in
    /// static storage under strict concurrency checking.
    private static var nowPlayingGradient: LinearGradient {
        LinearGradient(
            colors: [Color.mint.opacity(0.16), Color.mint.opacity(0.03), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    private static let moonlightSite = "https://moonlight-stream.org"
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                header
                if vm.isDemoMode { demoNotice }
                content
                footer
            }
        }
        .task { await initialLoad() }
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
        MacSectionHeader("Library", subtitle: "Apps published by Sunshine on \(pcName)", icon: "gamecontroller.fill") {
            HStack(spacing: 10) {
                if vm.isLoadingGames && !vm.games.isEmpty {
                    ProgressView().controlSize(.small)
                }
                searchField
                autoOpenToggle
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

    private var autoOpenToggle: some View {
        Toggle("Open Moonlight after launch", isOn: $autoOpenMoonlight)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
            .help("After Sunshine starts the app, Orbit opens Moonlight on this Mac so you can connect to the stream.")
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
            moonlightPill
            Spacer(minLength: 0)
        }
    }

    private var moonlightPill: some View {
        Group {
            switch moonlightInstalled {
            case .some(true):
                MacStatusPill(text: "Moonlight installed", tint: .mint, icon: "checkmark.circle.fill")
            case .some(false):
                MacStatusPill(text: "Moonlight not found", tint: .orange, icon: "exclamationmark.circle.fill")
            case .none:
                MacStatusPill(text: "Checking Moonlight…", tint: .secondary, icon: "ellipsis.circle")
            }
        }
        .help("Orbit looks for the Moonlight app on this Mac. Streaming needs it installed.")
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
                MacLibraryTile(
                    game: game,
                    symbol: MacLibraryIcon.symbol(for: game),
                    accent: MacLibraryIcon.accent(for: game, fallback: theme.accent),
                    isLaunching: launchingID == game.id,
                    isBusy: launchingID != nil,
                    onLaunch: { launch(game) }
                )
            }
        }
        .animation(.snappy(duration: 0.25), value: filteredGames)
    }

    // MARK: - Now Playing

    private func nowPlaying(_ title: String) -> some View {
        HStack(spacing: 14) {
            MacIconBadge(systemName: "gamecontroller.fill", tint: .mint, size: 46, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("NOW PLAYING")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.mint)
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .lineLimit(1)
                nowPlayingDetails
            }
            Spacer(minLength: 8)
            if fpsHistory.count >= 3 {
                MacSparkline(values: fpsHistory, tint: .mint, lineWidth: 1.6)
                    .frame(width: 150, height: 34)
                    .opacity(0.7)
            }
            fpsReadout
            Button { confirmStop = true } label: { Label("Stop Game", systemImage: "stop.fill") }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
                .help("Ask the PC to end the running game")
            Button { vm.openMoonlight() } label: { Label("Open Moonlight", systemImage: "play.tv") }
                .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: true))
                .help("Open Moonlight on this Mac")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.nowPlayingGradient))
        .macGlass(cornerRadius: 20, tint: .mint, elevated: true)
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
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.mint)
                .contentTransition(.numericText())
                .shadow(color: reduceGlow ? .clear : .mint.opacity(0.45), radius: 10)
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
        switch moonlightInstalled {
        case .some(true): return "Moonlight is installed on this Mac. Launch an app above, then pick \(pcName) in Moonlight to start streaming."
        case .some(false): return "Moonlight is not installed on this Mac. Download it free from moonlight-stream.org to stream the apps in this library."
        case .none: return "Checking whether Moonlight is installed on this Mac…"
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: "play.tv", tint: theme.accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stream with Moonlight").font(.subheadline.weight(.semibold))
                Text(footerMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if moonlightInstalled == false {
                Button { open(Self.moonlightSite) } label: { Label("Get Moonlight", systemImage: "arrow.down.circle") }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Open moonlight-stream.org in your browser")
            }
            if let url = sunshineWebURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Sunshine Web UI", systemImage: "globe") }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Open \(url.absoluteString) — Sunshine's default Web UI port is 47990")
            }
            Button {
                vm.openMoonlight()
                moonlightInstalled = Self.detectMoonlight()
            } label: {
                Label("Open Moonlight", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
            .keyboardShortcut("m", modifiers: [.command, .option])
            .help("Open Moonlight, or its download page if it is not installed (⌥⌘M)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: theme.accent)
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
    let isLaunching: Bool
    let isBusy: Bool
    let onLaunch: () -> Void
    @State private var hovered = false
    @FocusState private var launchFocused: Bool

    init(game: MacSunshineGame, symbol: String, accent: Color, isLaunching: Bool, isBusy: Bool, onLaunch: @escaping () -> Void) {
        self.game = game
        self.symbol = symbol
        self.accent = accent
        self.isLaunching = isLaunching
        self.isBusy = isBusy
        self.onLaunch = onLaunch
    }

    private var showsLaunch: Bool { hovered || launchFocused || isLaunching }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                MacIconBadge(systemName: symbol, tint: accent, size: 56, filled: showsLaunch)
                Spacer(minLength: 0)
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
        .onTapGesture(count: 2) { if !isBusy { onLaunch() } }
        .contextMenu { contextItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(game.title)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(game.title)
                .font(.system(.headline, design: .rounded, weight: .bold))
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
            Text("Double-click to launch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(showsLaunch ? 0 : 1)
                .accessibilityHidden(true)
            Button(action: onLaunch) {
                HStack(spacing: 6) {
                    if isLaunching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isLaunching ? "Launching…" : "Launch")
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
