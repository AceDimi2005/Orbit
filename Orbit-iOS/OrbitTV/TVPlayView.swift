import MoonlightCore
import SwiftUI

/// Play: stream the PC to this TV, and the game library as posters. A game opens its own
/// page with "Stream to TV" and "Start on PC".
struct TVPlayView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared
    @Environment(\.tvAccent) private var accent
    @Environment(\.tvToast) private var toast
    @State private var selected: TVSunshineGame?
    @State private var showsPairing = false
    @State private var showsQuality = false
    @State private var showsAddPC = false
    @State private var confirmsEnd = false

    private var state: TVPCState { TVPCState(vm: vm) }
    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode }

    /// The agent's library first; when it is empty but Sunshine is paired, Sunshine's own list.
    private var games: [TVSunshineGame] {
        let all: [TVSunshineGame]
        if !vm.games.isEmpty || !sunshine.isPaired || vm.isDemoMode {
            all = vm.games
        } else {
            all = sunshine.apps.map { TVSunshineGame(id: "sunshine-\($0.id)", title: $0.title, genre: $0.supportsHDR ? "HDR" : "",
                                                     iconSymbol: "gamecontroller", accentHex: "0A84FF") }
        }
        return all.filter { $0.title.caseInsensitiveCompare("Desktop") != .orderedSame }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        Group {
            if state == .setup || (!vm.isDemoMode && !state.isReachable) {
                TVPCStatusScreen(state: state, purpose: "play your games") { showsAddPC = true }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
                        streamCard
                        library
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
                .tvDebugScrollAnchor()
            }
        }
        .fullScreenCover(item: $selected) { game in
            TVGameDetailView(game: game, sunshine: sunshine)
        }
        .fullScreenCover(isPresented: $showsPairing) {
            TVSunshinePairingView(sunshine: sunshine)
        }
        .fullScreenCover(isPresented: $showsQuality) {
            MoonlightStreamSettingsView(store: settings, accent: accent, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) {
                showsQuality = false
            }
            .tvFullScreenPage()
        }
        .fullScreenCover(isPresented: $showsAddPC) {
            TVAddPCView { showsAddPC = false }
                .tvFullScreenPage()
        }
        .onChange(of: vm.selectedPCID) { _, _ in showsAddPC = false }
        .confirmationDialog("End \(sunshine.runningAppTitle ?? "the stream") on \(vm.pcName)?", isPresented: $confirmsEnd,
                            titleVisibility: .visible) {
            Button("End", role: .destructive) {
                Task { await sunshine.quitRunningApp() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sunshine closes the app on the PC. Unsaved progress may be lost.")
        }
        .task {
            await vm.refreshGames()
            if vm.metrics.isOnline, !vm.isDemoMode { await sunshine.refresh() }
        }
        .onAppear {
            #if DEBUG
            // `-orbitStreamSettings resolution` opens the quality list straight away (screenshots).
            if UserDefaults.standard.string(forKey: "orbitStreamSettings") != nil { showsQuality = true }
            switch TVDebugLaunch.sheet {
            case "game": selected = games.first
            case "pairing": showsPairing = true
            case "quality": showsQuality = true
            default: break
            }
            #endif
        }
    }

    // MARK: Stream card

    @ViewBuilder
    private var streamCard: some View {
        if canStream {
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sunshine.runningAppTitle.map { "\($0) is running" } ?? "Stream \(vm.pcName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(tvStreamSummary())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                }
                Spacer(minLength: 32)
                HStack(spacing: 28) {
                    Button {
                        let running = sunshine.info.flatMap { info in sunshine.apps.first { $0.id == info.currentGame } }
                        if let app = running ?? sunshine.desktopApp { tvBeginStream(app, host: sunshine, pcName: vm.pcName) }
                    } label: {
                        Label(sunshine.isBusy ? "Resume" : "Stream Desktop", systemImage: "play.fill")
                    }
                    .tvButton(prominent: true)
                    .disabled(sunshine.desktopApp == nil)
                    if sunshine.isBusy {
                        Button {
                            confirmsEnd = true
                        } label: {
                            Label("End", systemImage: "stop.fill")
                        }
                        .tvButton()
                    }
                    Button {
                        showsQuality = true
                    } label: {
                        Label("Quality", systemImage: "slider.horizontal.3")
                    }
                    .tvButton()
                }
            }
            .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
            .focusSection()
        } else if vm.metrics.isOnline && !vm.isDemoMode {
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stream games to this TV")
                        .font(.headline)
                    Text(setupSentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 32)
                if sunshine.reachable {
                    Button {
                        showsPairing = true
                    } label: {
                        Label("Pair with Sunshine", systemImage: "link")
                    }
                    .tvButton(prominent: true)
                } else if vm.canStartSunshine {
                    Button {
                        startSunshine()
                    } label: {
                        Label("Start Sunshine", systemImage: "play")
                    }
                    .tvButton(prominent: true)
                }
            }
            .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
            .focusSection()
        }
    }

    private var setupSentence: String {
        if sunshine.reachable { return "Pair Orbit with Sunshine on the PC once. Games you start here then play on this TV." }
        if let info = vm.sunshineInfo, info.installed, !info.running {
            return "Sunshine is installed on the PC but isn't running. You can still start games on the PC."
        }
        return "Install Sunshine on the PC to stream games and the desktop here. You can still start games on the PC."
    }

    private func startSunshine() {
        toast("Starting Sunshine on the PC")
        Task {
            do {
                try await vm.startSunshineOnPC(refreshing: sunshine)
            } catch {
                toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
            TVSectionTitle("Library") {
                if !games.isEmpty { Text(games.count == 1 ? "1 game" : "\(games.count) games") }
            }
            if games.isEmpty {
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No games yet")
                            .font(.headline)
                        Text("Games you add to Sunshine on the PC appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 32)
                    Button {
                        Task { await vm.refreshGames(); await sunshine.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .tvButton()
                }
                .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 64) {
                    ForEach(games) { game in
                        Button {
                            selected = game
                        } label: {
                            TVPoster(game: game, artwork: artwork(for: game), isRunning: isRunning(game))
                        }
                        .buttonStyle(.borderless)
                        .tvDebugFocus(game.id == games.first?.id ? "poster" : "")
                        .onAppear { if let app = sunshine.app(titled: game.title) { sunshine.loadArtwork(for: app) } }
                    }
                }
            }
        }
        .focusSection()
    }

    private func artwork(for game: TVSunshineGame) -> Data? {
        sunshine.app(titled: game.title).flatMap { sunshine.artwork[$0.id] }
    }

    private func isRunning(_ game: TVSunshineGame) -> Bool {
        if let app = sunshine.app(titled: game.title), app.id == sunshine.info?.currentGame { return true }
        return vm.metrics.activeGame.map { $0.caseInsensitiveCompare(game.title) == .orderedSame } ?? false
    }
}

// MARK: - Poster

/// A 2:3 poster lockup. The borderless button style lifts the art when focused; the title
/// stays below it.
private struct TVPoster: View {
    var game: TVSunshineGame
    var artwork: Data?
    var isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVCoverArt(game: game, artwork: artwork)
                .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isRunning {
                    Text("Playing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A game's cover from Sunshine, or a quiet typographic cover when there is no art.
struct TVCoverArt: View {
    var game: TVSunshineGame
    var artwork: Data?
    var cornerRadius: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(OrbitPalette.surface)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let artwork {
                    MoonlightArtwork(data: artwork)
                } else {
                    // The name is shown with the cover, so the placeholder doesn't repeat it.
                    GeometryReader { proxy in
                        Image(systemName: Self.symbol(game.iconSymbol))
                            .font(.system(size: proxy.size.width * 0.24, weight: .light))
                            .foregroundStyle(.tertiary)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The outline version of the library's symbol, so covers stay quiet.
    private static func symbol(_ name: String) -> String {
        let base = name.replacingOccurrences(of: ".fill", with: "")
        return base.isEmpty ? "gamecontroller" : base
    }
}

// MARK: - Game page

struct TVGameDetailView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var game: TVSunshineGame
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tvToast) private var toast

    private var app: MoonlightApp? { sunshine.app(titled: game.title) }
    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode && app != nil }
    private var canStart: Bool { vm.metrics.isOnline || vm.isDemoMode }
    private var isRunning: Bool {
        if let app, app.id == sunshine.info?.currentGame { return true }
        return vm.metrics.activeGame.map { $0.caseInsensitiveCompare(game.title) == .orderedSame } ?? false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 110) {
            TVCoverArt(game: game, artwork: app.flatMap { sunshine.artwork[$0.id] }, cornerRadius: 28)
                .frame(width: 440)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(game.title)
                        .font(.title.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if !game.genre.isEmpty {
                        Text(game.genre)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if isRunning {
                        Text("Running on \(vm.pcName)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
                VStack(alignment: .leading, spacing: 28) {
                    // Only offered when it can work; the note below says what streaming needs.
                    if canStream {
                        Button {
                            if let app {
                                dismiss()
                                tvBeginStream(app, host: sunshine, pcName: vm.pcName)
                            }
                        } label: {
                            Label(isRunning ? "Resume on TV" : "Stream to TV", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .tvButton(prominent: true)
                    }
                    Button {
                        dismiss()
                        Task {
                            await vm.launchGame(game)
                            toast(vm.statusBanner.hasPrefix("Could not") ? vm.statusBanner : "Starting \(game.title) on \(vm.pcName)")
                        }
                    } label: {
                        Label("Start on PC", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                    }
                    .tvButton(prominent: !canStream)
                    .disabled(!canStart)
                }
                .frame(width: 620)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 760, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canStream {
                    Text(tvStreamSummary())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 60)
        .tvFullScreenPage()
        .onAppear { if let app { sunshine.loadArtwork(for: app) } }
    }

    private var note: String? {
        if vm.isDemoMode { return "This is the sample library. Starting a game only changes the sample data." }
        if !vm.metrics.isOnline { return "Wake the PC to play." }
        if !sunshine.isPaired { return "Pair with Sunshine to stream games to this TV." }
        if app == nil { return "Sunshine doesn't list this game, so it can only start on the PC." }
        return nil
    }
}

// MARK: - Sunshine pairing

/// Pairs Orbit with Sunshine on the PC. The code shows large on the left; Orbit Companion can
/// type it into Sunshine when it has the web UI login, otherwise the person types it on the PC.
struct TVSunshinePairingView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var confirmsForget = false

    private var canAutomate: Bool { vm.sunshineInfo?.canSubmitPin == true }
    private var digits: [String] { (sunshine.pairingPIN ?? "····").map { String($0) } }

    var body: some View {
        TVSplitPage {
            if sunshine.isPaired || unreachable {
                OrbitMark(status: sunshine.isPaired ? .online : .offline, size: 200)
            } else {
                HStack(spacing: 18) {
                    ForEach(Array(digits.enumerated()), id: \.offset) { _, digit in
                        Text(digit)
                            .font(.orbitReading(92))
                            .foregroundStyle(sunshine.pairingPIN == nil ? Color.secondary : Color.primary)
                            .frame(width: 118, height: 150)
                            .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sunshine.pairingPIN.map { "Pairing code \($0.map(String.init).joined(separator: " "))" } ?? "No code yet")
            }
            if let stage = sunshine.pairingStage {
                Text(stage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        } content: {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sunshine.isPaired ? "Paired with Sunshine" : "Pair with Sunshine")
                        .font(.title2.weight(.semibold))
                    Text("\(vm.pcName) · \(sunshine.address)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(instruction)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Orbit's own messages always show; Sunshine's connection error only once it answers,
                // since the sentence above already says it doesn't.
                if let error = message ?? (unreachable ? nil : sunshine.lastError), !sunshine.isPaired {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(OrbitPalette.warm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .frame(width: 620, alignment: .leading)
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .tvFullScreenPage()
        .confirmationDialog("Forget the Sunshine pairing?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { sunshine.forgetPairing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Apple TV stops streaming from \(vm.pcName) until you pair again.")
        }
    }

    /// Sunshine doesn't answer, so there's nothing to pair with yet.
    private var unreachable: Bool { !sunshine.reachable && !sunshine.isPaired && !sunshine.isPairing }

    private var instruction: String {
        if sunshine.isPaired { return "Games and the desktop now stream straight to this TV." }
        if unreachable {
            return vm.canStartSunshine
                ? "Sunshine is installed on \(vm.pcName) but isn't running."
                : "Sunshine isn't answering on \(vm.pcName). Install it or start it on the PC, then come back here."
        }
        if sunshine.isPairing {
            return canAutomate
                ? "Orbit Companion is typing the code into Sunshine on the PC."
                : "On the PC, open Sunshine's PIN page (https://localhost:\(vm.sunshineInfo?.webUIPort ?? 47990)/pin) and type this code with a device name."
        }
        return canAutomate
            ? "Orbit Companion types the code into Sunshine on the PC for you. It takes a few seconds."
            : "Orbit shows a code here; you type it into Sunshine's PIN page on the PC once."
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 28) {
            if sunshine.isPaired {
                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .tvButton(prominent: true)
                Button(role: .destructive) {
                    confirmsForget = true
                } label: {
                    Text("Forget Pairing").frame(maxWidth: .infinity)
                }
                .tvButton()
            } else if sunshine.isPairing {
                Button("Cancel") { sunshine.cancelPairing() }
                    .tvButton()
            } else if unreachable {
                if vm.canStartSunshine {
                    Button {
                        startSunshine()
                    } label: {
                        Label("Start Sunshine", systemImage: "play")
                            .frame(maxWidth: .infinity)
                    }
                    .tvButton(prominent: true)
                } else {
                    Button("Done") { dismiss() }
                        .tvButton()
                }
            } else {
                if canAutomate {
                    Button {
                        pairAutomatically()
                    } label: {
                        Label("Pair Automatically", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .tvButton(prominent: true)
                }
                Button {
                    message = nil
                    sunshine.beginPairing()
                } label: {
                    Label(canAutomate ? "Type the Code Myself" : "Show Code", systemImage: "number")
                        .frame(maxWidth: .infinity)
                }
                .tvButton(prominent: !canAutomate)
            }
        }
    }

    private func startSunshine() {
        message = nil
        Task {
            do {
                try await vm.startSunshineOnPC(refreshing: sunshine)
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Generates the code and has Orbit Companion type it into Sunshine once Sunshine has the
    /// request open.
    private func pairAutomatically() {
        message = nil
        sunshine.beginPairing()
        guard let pin = sunshine.pairingPIN else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard sunshine.isPairing, sunshine.pairingPIN == pin else { return }
            do {
                try await MoonlightPairingAutomation(canSubmitPIN: true, canStartSunshine: false, sunshineRunning: true,
                                                     client: { try vm.client() }).submitPIN(pin)
            } catch {
                message = "Orbit Companion couldn't type the code: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}
