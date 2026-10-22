import MoonlightCore
import SwiftUI

/// Play: your games with their art, streamed to this iPhone or started on the PC.
struct PlayView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var search = ""
    @State private var selected: SunshineGame?
    @State private var showsPairing = false
    @State private var showsSettings = false
    @Namespace private var covers
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode }

    /// The agent's list first; when it is empty but Sunshine is paired, Sunshine's own list.
    private var games: [SunshineGame] {
        let all: [SunshineGame]
        if !vm.games.isEmpty || !sunshine.isPaired {
            all = vm.games
        } else {
            all = sunshine.apps.map { SunshineGame(id: "sunshine-\($0.id)", title: $0.title, genre: $0.supportsHDR ? "HDR" : "",
                                                   iconSymbol: "gamecontroller.fill", accentHex: "0A84FF") }
        }
        let visible = all.filter { $0.title.caseInsensitiveCompare("Desktop") != .orderedSame }
        return search.isEmpty ? visible : visible.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible(), spacing: 14)] }
        return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OrbitMetrics.sectionSpacing) {
                    streamCard
                    if games.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            OrbitSectionHeader(search.isEmpty ? "Library" : "Results")
                            LazyVGrid(columns: columns, spacing: 22) {
                                ForEach(games) { game in
                                    Button {
                                        OrbitHaptics.tap()
                                        selected = game
                                    } label: {
                                        GameTile(game: game, artwork: artwork(for: game), isRunning: isRunning(game))
                                    }
                                    .buttonStyle(PCTileButtonStyle())
                                    .matchedTransitionSource(id: game.id, in: covers)
                                    .onAppear { if let app = sunshine.app(titled: game.title) { sunshine.loadArtwork(for: app) } }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, OrbitMetrics.gutter)
                .padding(.bottom, 36)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(OrbitPalette.canvas)
            .navigationTitle("Play")
            .searchable(text: $search, prompt: "Games and apps")
            .refreshable { await vm.fetchSunshineApps(); await sunshine.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stream Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                        .tint(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) { moreMenu.tint(.primary) }
            }
            .sheet(item: $selected) { game in
                GameDetailView(vm: vm, sunshine: sunshine, game: game, showsSettings: $showsSettings)
                    .navigationTransition(.zoom(sourceID: game.id, in: covers))
            }
            .sheet(isPresented: $showsPairing) {
                MoonlightPairingView(host: sunshine, pcName: vm.selectedPCName, accent: theme.orbitTint, automation: pairingAutomation) {
                    showsPairing = false
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showsSettings) {
                MoonlightStreamSettingsView(store: settings, accent: theme.orbitTint, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) {
                    showsSettings = false
                }
            }
        }
    }

    private func artwork(for game: SunshineGame) -> UIImage? {
        guard let app = sunshine.app(titled: game.title), let data = sunshine.artwork[app.id] else { return nil }
        return UIImage(data: data)
    }

    private func isRunning(_ game: SunshineGame) -> Bool {
        if let app = sunshine.app(titled: game.title), app.id == sunshine.info?.currentGame { return true }
        return vm.metrics.activeGame.map { $0.caseInsensitiveCompare(game.title) == .orderedSame } ?? false
    }

    private var pairingAutomation: MoonlightPairingAutomation? {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return nil }
        return MoonlightPairingAutomation(canSubmitPIN: vm.sunshineInfo?.canSubmitPin ?? false, canStartSunshine: vm.sunshineInfo?.canStart ?? false,
                                          sunshineRunning: vm.sunshineInfo?.running ?? true, client: { try vm.companionClient() })
    }

    // MARK: Stream card

    @ViewBuilder
    private var streamCard: some View {
        if !vm.metrics.isOnline && !vm.isDemoMode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your PC is asleep or off")
                    .font(.headline)
                Text("Wake it to play your games here or start them on the PC.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    OrbitHaptics.press()
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWakingUp ? "Waking…" : "Wake PC", systemImage: "power")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .orbitGlassButton(prominent: true)
                .disabled(vm.pcMAC.isEmpty || vm.isWakingUp)
            }
            .orbitSurface()
        } else if canStream {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sunshine.isBusy ? "A stream is open" : "Stream your PC")
                            .font(.headline)
                        Text(settingsSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .orbitLiveNumber()
                    }
                    Spacer(minLength: 8)
                }
                HStack(spacing: 10) {
                    Button {
                        OrbitHaptics.press()
                        if let app = sunshine.desktopApp { begin(app) }
                    } label: {
                        Label(sunshine.isBusy ? "Resume" : "Stream Desktop", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .orbitGlassButton(prominent: true)
                    .disabled(sunshine.desktopApp == nil)
                    if sunshine.isBusy {
                        Button {
                            OrbitHaptics.warning()
                            Task { await sunshine.quitRunningApp() }
                        } label: {
                            Label("End", systemImage: "stop.fill")
                                .font(.headline)
                                .padding(.vertical, 4)
                        }
                        .orbitGlassButton()
                    }
                }
            }
            .orbitSurface()
        } else if vm.metrics.isOnline && !vm.isDemoMode {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stream games to this iPhone")
                    .font(.headline)
                Text(sunshine.reachable
                     ? "Pair Orbit with Sunshine on your PC once. Orbit can type the pairing code on the PC for you."
                     : "Install Sunshine on the PC to stream games and the desktop here. You can still start games on the PC.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if sunshine.reachable {
                    Button {
                        OrbitHaptics.tap()
                        showsPairing = true
                    } label: {
                        Label("Pair with Sunshine", systemImage: "link")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .orbitGlassButton(prominent: true)
                }
            }
            .orbitSurface()
        }
    }

    private var settingsSummary: String {
        let current = settings.settings
        var parts = ["\(current.pixelSize.height)p", "\(current.frameRate) fps", "\(current.bitrateKbps / 1000) Mbps"]
        if current.requestsHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }

    private func begin(_ app: MoonlightApp) {
        MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                     settings: settings.settings, promptUnlock: false))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No games yet" : "No matches")
                .font(.headline)
            Text(search.isEmpty ? "Games you add to Sunshine on the PC appear here." : "Try another name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var moreMenu: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await vm.fetchSunshineApps(); await sunshine.refresh() } }
                .disabled(!vm.metrics.isOnline)
            Button("See the Screen", systemImage: "display") { vm.openDesktopPreview() }
                .disabled(!vm.metrics.isOnline)
            Divider()
            if sunshine.isPaired {
                Button("End Stream on PC", systemImage: "stop.circle") { Task { await sunshine.quitRunningApp() } }
                    .disabled(!sunshine.isBusy)
                Button("Forget Sunshine Pairing", systemImage: "link.badge.minus", role: .destructive) { sunshine.forgetPairing() }
            } else {
                Button("Pair with Sunshine…", systemImage: "link") { showsPairing = true }
                    .disabled(!vm.metrics.isOnline || vm.isDemoMode)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }
}

// MARK: - Tile

private struct GameTile: View {
    var game: SunshineGame
    var artwork: UIImage?
    var isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameArtwork(game: game, artwork: artwork)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isRunning {
                        Label("Playing", systemImage: "play.fill")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .orbitGlass()
                            .padding(8)
                    }
                }
            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A game's cover, or a quiet typographic cover when Sunshine has no art for it.
struct GameArtwork: View {
    var game: SunshineGame
    var artwork: UIImage?

    var body: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // The name is shown with the cover, so the placeholder doesn't repeat it.
                OrbitPalette.well
                Image(systemName: game.title.localizedCaseInsensitiveContains("steam") ? "play.rectangle" : "gamecontroller")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .background(OrbitPalette.surface)
    }
}

// MARK: - Detail

private struct GameDetailView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    var game: SunshineGame
    @Binding var showsSettings: Bool
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    private var app: MoonlightApp? { sunshine.app(titled: game.title) }
    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode && app != nil }
    private var artwork: UIImage? { app.flatMap { sunshine.artwork[$0.id] }.flatMap(UIImage.init(data:)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GameArtwork(game: game, artwork: artwork)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .frame(maxWidth: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(.largeTitle.weight(.bold))
                        if !game.genre.isEmpty {
                            Text(game.genre)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 10) {
                        Button {
                            OrbitHaptics.press()
                            if let app {
                                dismiss()
                                MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                                             settings: settings.settings, promptUnlock: false))
                            }
                        } label: {
                            Label("Stream to iPhone", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .orbitGlassButton(prominent: true)
                        .disabled(!canStream)

                        Button {
                            OrbitHaptics.press()
                            dismiss()
                            Task { await vm.smartLaunch(game: game) }
                        } label: {
                            Label("Start on PC", systemImage: "desktopcomputer")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .orbitGlassButton()
                        .disabled(!vm.metrics.isOnline || vm.isDemoMode)
                    }
                    if !canStream && vm.metrics.isOnline && !vm.isDemoMode {
                        Text(sunshine.isPaired ? "Sunshine doesn't list this game, so it can only start on the PC." : "Pair with Sunshine to stream games here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        dismiss()
                        showsSettings = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stream quality")
                                    .font(.subheadline.weight(.medium))
                                Text("\(settings.settings.pixelSize.height)p · \(settings.settings.frameRate) fps · \(settings.settings.bitrateKbps / 1000) Mbps")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .orbitSurface(padding: 16, radius: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .onAppear { if let app { sunshine.loadArtwork(for: app) } }
    }
}
