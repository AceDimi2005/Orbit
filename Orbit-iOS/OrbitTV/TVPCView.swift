import MoonlightCore
import SwiftUI

/// PC: how the PC is doing, then everything you can do to it. A status header leads with one
/// sentence, the readings follow as calm tiles, and the action each state needs sits in reach.
struct TVPCView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tvToast) private var toast
    @State private var vital: OrbitVitalKind?
    @State private var confirmation: TVPowerAction?
    @State private var confirmsQuitGame = false
    @State private var showsAddPC = false
    @State private var showsPairing = false

    private var state: TVPCState { TVPCState(vm: vm) }

    var body: some View {
        ZStack {
            if state.isReachable {
                ScrollView {
                    content
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                }
                .scrollClipDisabled()
                .tvDebugScrollAnchor()
                .transition(.opacity)
            } else {
                TVPCStatusScreen(state: state) { showsAddPC = true }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : OrbitMotion.standard, value: state)
        .fullScreenCover(item: $vital) { kind in
            TVVitalDetailView(kind: kind)
        }
        .fullScreenCover(isPresented: $showsAddPC) {
            TVAddPCView { showsAddPC = false }
                .tvFullScreenPage()
        }
        .fullScreenCover(isPresented: $showsPairing) {
            TVSunshinePairingView(sunshine: sunshine)
        }
        .confirmationDialog(confirmation?.question(pcName: vm.pcName) ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action.confirmTitle, role: .destructive) {
                    confirmation = nil
                    Task {
                        if !(await vm.sendAction(action.rawValue)) { toast(vm.lastActionError) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.explanation ?? "")
        }
        .confirmationDialog("Quit \(vm.metrics.activeGame ?? "the game")?", isPresented: $confirmsQuitGame, titleVisibility: .visible) {
            Button("Quit Game", role: .destructive) {
                Task {
                    if !(await vm.sendAction("kill_game")) { toast(vm.lastActionError) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved progress in the game may be lost.")
        }
        .onChange(of: vm.selectedPCID) { _, _ in showsAddPC = false }
        #if DEBUG
        .task {
            switch TVDebugLaunch.sheet {
            case let name? where name.hasPrefix("vital"):
                // `vital` opens the first reading, `vital:memory` a given one.
                let wanted = name.split(separator: ":").dropFirst().first.map(String.init)
                try? await Task.sleep(for: .seconds(2))
                vital = OrbitVitalKind.allCases.first { $0.rawValue.lowercased() == wanted } ?? vm.tvVitals.first
            case "power": confirmation = .shutdown
            case "addpc": showsAddPC = true
            case "quitgame": confirmsQuitGame = true
            default: break
            }
        }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
            TVPCHeader(state: state, confirmation: $confirmation, showsAddPC: $showsAddPC)
            if state == .locked {
                TVLockedCard(sunshine: sunshine, showsPairing: $showsPairing)
            }
            if let game = vm.metrics.activeGame, !game.isEmpty {
                TVNowPlayingCard(sunshine: sunshine, game: game, confirmsQuit: $confirmsQuitGame)
            }
            TVVitalsSection(vital: $vital)
            TVControlSection()
        }
    }
}

// MARK: - Status screens

/// Setup, connecting, waking and offline: the mark, one sentence and the one action that
/// helps. Play, Sound and Activity show the same screen with their own reason to wake the PC.
struct TVPCStatusScreen: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var state: TVPCState
    /// What waking the PC is for on this screen ("play your games"); nil on the PC tab.
    var purpose: String? = nil
    var onAddPC: () -> Void

    var body: some View {
        VStack(spacing: 52) {
            // Setup shows the mark as it appears in the app icon: a white ring and its satellite.
            OrbitMark(status: state == .setup ? .online : state.markStatus, size: 180)
            VStack(spacing: 18) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Text(sentence)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
            }
            .accessibilityElement(children: .combine)
            // The action row keeps its height while empty, so the mark doesn't jump as the
            // state moves from connecting to asleep to waking.
            actions
                .frame(height: 100)
        }
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch state {
        case .setup: return "Add your PC"
        case .connecting: return "Connecting to \(vm.pcName)…"
        case .waking: return "Waking \(vm.pcName)…"
        default: return "\(vm.pcName) is asleep or off"
        }
    }

    private var sentence: String {
        switch state {
        case .setup:
            return "Install Orbit Companion on your Windows PC and pair it here. PCs you already use with Orbit on iPhone show up on their own."
        case .connecting:
            return "Reaching Orbit Companion at \(vm.currentPC?.address ?? "your PC")."
        case .waking:
            return "Sent the wake-up signal. This takes up to a minute."
        default:
            if let purpose { return vm.canWake ? "Wake it to \(purpose)." : "Turn it on to \(purpose)." }
            return vm.canWake
                ? "Orbit can wake it over your network."
                : "Turn it on and make sure Orbit Companion is running. Once Orbit has seen it on, it can wake it from here."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .setup:
            HStack(spacing: 32) {
                Button(action: onAddPC) {
                    Label("Add PC", systemImage: "plus")
                }
                .tvButton(prominent: true)
                Button("Try the Demo") { vm.setDemoMode(true) }
                    .tvButton()
            }
        case .offline:
            if vm.canWake {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label("Wake PC", systemImage: "power")
                }
                .tvButton(prominent: true)
            } else {
                Button {
                    Task { await vm.refreshMetrics() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .tvButton(prominent: true)
            }
        default:
            Color.clear
        }
    }
}

// MARK: - Header

private struct TVPCHeader: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var state: TVPCState
    @Binding var confirmation: TVPowerAction?
    @Binding var showsAddPC: Bool
    @Environment(\.tvToast) private var toast

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            OrbitMark(status: state.markStatus, size: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.pcName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 32)
            HStack(spacing: 28) {
                if vm.isDemoMode {
                    // The demo's way out: back to the saved PC, or to adding one.
                    Button(vm.currentPC == nil ? "Add PC" : "Exit Demo") {
                        let needsPC = vm.currentPC == nil
                        vm.setDemoMode(false)
                        if needsPC { showsAddPC = true }
                    }
                    .tvButton()
                }
                powerMenu
            }
        }
        .focusSection()
    }

    private var headline: String {
        state == .locked ? "Locked" : OrbitTakeaway(vm.metrics).headline
    }

    private var detail: String {
        if state == .demo { return "Sample data · nothing is sent to a PC" }
        var parts = [state == .locked ? "Windows is locked" : "Online"]
        if vm.pingMs > 0 { parts.append("\(vm.pingMs) ms") }
        if vm.metrics.uptimeSeconds > 0 { parts.append("up \(OrbitFormat.duration(seconds: vm.metrics.uptimeSeconds))") }
        return parts.joined(separator: " · ")
    }

    private var powerMenu: some View {
        Menu {
            if state != .locked {
                Button("Lock", systemImage: "lock") {
                    Task {
                        if !(await vm.sendAction("lock")) { toast(vm.lastActionError) }
                    }
                }
            }
            Button("Sleep", systemImage: "moon") { confirmation = .sleep }
            Button("Restart", systemImage: "arrow.clockwise") { confirmation = .restart }
            Button("Shut Down", systemImage: "power", role: .destructive) { confirmation = .shutdown }
        } label: {
            Label("Power", systemImage: "power")
        }
        .tvButton()
        .tvDebugFocus("power")
    }
}

// MARK: - Locked, now playing

private struct TVLockedCard: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Binding var showsPairing: Bool

    private var canUnlock: Bool { !vm.isDemoMode && sunshine.isPaired && sunshine.reachable && sunshine.desktopApp != nil }
    private var canPair: Bool { !vm.isDemoMode && sunshine.reachable && !sunshine.isPaired }

    var body: some View {
        HStack(alignment: .center, spacing: 48) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Windows is waiting for your password")
                    .font(.headline)
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 32)
            if canUnlock {
                Button {
                    if let app = sunshine.desktopApp {
                        tvBeginStream(app, host: sunshine, pcName: vm.pcName, promptUnlock: true)
                    }
                } label: {
                    Label("Unlock", systemImage: "lock.open")
                }
                .tvButton(prominent: true)
            } else if canPair {
                Button {
                    showsPairing = true
                } label: {
                    Label("Pair with Sunshine", systemImage: "link")
                }
                .tvButton(prominent: true)
            }
        }
        .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
        .focusSection()
    }

    private var sentence: String {
        if canUnlock { return "Orbit opens the sign-in screen and types the password you enter, once. It's never saved." }
        if canPair || vm.isDemoMode { return "Pair Orbit with Sunshine on the PC once, then sign in from here." }
        return "Sunshine isn't answering on the PC, so sign in on the PC itself."
    }
}

private struct TVNowPlayingCard: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    var game: String
    @Binding var confirmsQuit: Bool

    /// The running game, if Sunshine knows it; otherwise the desktop, so the stream shows it anyway.
    private var app: MoonlightApp? {
        guard sunshine.isPaired, sunshine.reachable, !vm.isDemoMode else { return nil }
        return sunshine.app(titled: game) ?? sunshine.desktopApp
    }

    private var artwork: Data? {
        sunshine.app(titled: game).flatMap { sunshine.artwork[$0.id] }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 44) {
            if let artwork {
                MoonlightArtwork(data: artwork)
                    .frame(width: 128, height: 192)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playing now")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(game)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(alignment: .top, spacing: 64) {
                    TVInlineReading(label: "Frame Rate", value: vm.metrics.fps.flatMap { $0 > 0 ? String(Int($0.rounded())) : nil }, unit: "fps")
                    TVInlineReading(label: "Graphics", value: OrbitFormat.percent(vm.metrics.gpuUsage), unit: "%",
                                    color: OrbitPalette.load(vm.metrics.gpuUsage.map { $0 / 100 }))
                    TVInlineReading(label: "GPU Temperature", value: OrbitFormat.temperature(vm.metrics.gpuTemp),
                                    color: OrbitPalette.temperature(vm.metrics.gpuTemp))
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 32)
            HStack(spacing: 28) {
                if let app {
                    Button {
                        tvBeginStream(app, host: sunshine, pcName: vm.pcName)
                    } label: {
                        Label("Stream to TV", systemImage: "play.fill")
                    }
                    .tvButton(prominent: true)
                }
                Button {
                    confirmsQuit = true
                } label: {
                    Label("Quit Game", systemImage: "xmark")
                }
                .tvButton()
            }
        }
        .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
        .focusSection()
        .onAppear { if let known = sunshine.app(titled: game) { sunshine.loadArtwork(for: known) } }
    }
}

/// A small reading for cards: label, number and unit. Missing readings are left out.
struct TVInlineReading: View {
    var label: String
    var value: String?
    var unit: String? = nil
    var color: Color = .primary

    var body: some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 6) {
                    Text(value)
                        .font(.orbitReading(52))
                        .foregroundStyle(color)
                        .orbitLiveNumber()
                    if let unit {
                        Text(unit)
                            .font(.orbitReading(26, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Readings

private struct TVVitalsSection: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Binding var vital: OrbitVitalKind?

    /// Four to a row; five sit in one row and six in two rows of three, so no tile is left alone.
    private var columns: [GridItem] {
        let count = vm.tvVitals.count
        let perRow = count == 5 ? 5 : (count == 6 ? 3 : 4)
        return Array(repeating: GridItem(.flexible(), spacing: TVMetrics.gridSpacing, alignment: .top), count: perRow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
            TVSectionTitle("Right Now")
            if vm.metrics.telemetryAvailable == false {
                Text("Waiting for the first readings from the PC…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
            } else {
                LazyVGrid(columns: columns, spacing: TVMetrics.gridSpacing) {
                    ForEach(vm.tvVitals) { kind in
                        Button {
                            vital = kind
                        } label: {
                            TVVitalTile(vital: vm.vital(kind))
                        }
                        .buttonStyle(.card)
                        .tvDebugFocus(kind == vm.tvVitals.first ? "tile" : "")
                    }
                }
            }
        }
        .focusSection()
    }
}

/// One reading as a large, calm tile: label, number, a detail line, and a meter or a trace.
struct TVVitalTile: View {
    var vital: OrbitVital

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vital.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: vital.unit == "%" ? 2 : 8) {
                Text(vital.value ?? "—")
                    .font(.orbitReading(84))
                    .foregroundStyle(vital.value == nil ? Color.secondary : vital.color)
                    .orbitLiveNumber()
                if let unit = vital.unit, vital.value != nil {
                    Text(unit)
                        .font(.orbitReading(36, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(vital.detail ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .orbitLiveNumber()
            Spacer(minLength: 20)
            if vital.fraction != nil {
                OrbitMeter(fraction: vital.fraction, style: AnyShapeStyle(vital.color == .primary ? Color.white : vital.color), height: 8)
            } else if vital.history.filter(\.isFinite).count > 1 {
                OrbitSparkline(values: vital.history, range: vital.historyRange, style: AnyShapeStyle(.tint), lineWidth: 3)
                    .frame(height: 40)
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 290, alignment: .topLeading)
        .background(OrbitPalette.surface)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Control

private struct TVControlSection: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @Environment(\.tvToast) private var toast

    private struct Shortcut: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let done: String
    }

    private let shortcuts = [
        Shortcut(id: "show_desktop", title: "Show Desktop", symbol: "menubar.dock.rectangle", done: "Showing the desktop"),
        Shortcut(id: "alt_tab", title: "Switch Window", symbol: "macwindow.on.rectangle", done: "Switched to the next window"),
        Shortcut(id: "fullscreen", title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right", done: "Pressed F11 on the PC"),
        Shortcut(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder", done: "Screenshot saved on the PC"),
        Shortcut(id: "toggle_hdr", title: "HDR On/Off", symbol: "sparkles.tv", done: "Switched HDR on the PC"),
        Shortcut(id: "restore_display", title: "Turn On Display", symbol: "display", done: "Turned the PC's displays back on")
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: TVMetrics.gridSpacing), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
            TVSectionTitle("Control")
            LazyVGrid(columns: columns, spacing: TVMetrics.gridSpacing) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        Task {
                            let sent = await vm.sendAction(shortcut.id)
                            toast(sent ? shortcut.done : vm.lastActionError)
                        }
                    } label: {
                        VStack(spacing: 16) {
                            Image(systemName: shortcut.symbol)
                                .font(.title3.weight(.regular))
                                .frame(height: 52)
                            Text(shortcut.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                        .padding(.horizontal, 12)
                        .background(OrbitPalette.surface)
                    }
                    .buttonStyle(.card)
                    .tvDebugFocus(shortcut.id == shortcuts.first?.id ? "control" : "")
                }
            }
        }
        .focusSection()
    }
}
