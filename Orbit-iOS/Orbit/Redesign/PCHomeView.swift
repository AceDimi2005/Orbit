import MoonlightCore
import SwiftUI

/// The PC tab: what the PC is doing right now, and everything you can do to it.
/// The navigation title is the PC's name; tapping it switches PCs.
struct PCHomeView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @Binding var tab: OrbitTab

    @State private var showsDiscovery = false
    @State private var showsPCs = false
    @State private var showsTrackpad = false
    @State private var showsClipboard = false
    @State private var showsMixer = false
    @State private var showsCustomize = false
    @State private var vital: DashboardMetric?
    @State private var confirmation: PCPowerAction?
    @EnvironmentObject private var companion: PCCompanion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OrbitMetrics.sectionSpacing) {
                    PCStatusHeader(vm: vm, state: state)
                    PCPowerStatus()
                    switch state {
                    case .setup:
                        PCSetupCard(vm: vm, showsDiscovery: $showsDiscovery)
                    case .offline, .connecting, .waking:
                        PCOfflineSection(vm: vm, state: state)
                    case .online, .locked, .demo:
                        onlineContent
                    }
                }
                .padding(.horizontal, OrbitMetrics.gutter)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .animation(OrbitMotion.standard, value: state)
            }
            .background(OrbitPalette.canvas)
            .navigationTitle(vm.isConfigured || vm.isDemoMode ? vm.selectedPCName : "Your PC")
            .toolbarTitleMenu { pcMenu }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { vm.isShowingIPConfigSheet = true }
                        .tint(.primary)
                }
            }
            .refreshable { await vm.refreshMetrics() }
            .navigationDestination(for: PCHomeDestination.self) { destination in
                switch destination {
                case .processes: TaskManagerView(vm: vm)
                case .specs: FullSpecsView(vm: vm)
                case .sessions:
                    OrbitProGate(title: "Sessions", message: "Recorded sessions with frame rate, temperature and power history are part of Orbit Pro.") {
                        SessionHistoryView(vm: vm)
                    }
                case .sources: MonitoringSourcesView(vm: vm)
                }
            }
        }
        .sheet(isPresented: $showsDiscovery) { PCDiscoveryView(vm: vm) }
        .sheet(isPresented: $showsPCs) { NavigationStack { PCProfilesView(vm: vm, showsCloseButton: true) } }
        .sheet(isPresented: $showsClipboard) { NavigationStack { ClipboardView(vm: vm) } }
        .sheet(isPresented: $showsMixer) { NavigationStack { AudioMixerView(vm: vm) } }
        .sheet(isPresented: $showsCustomize) { DashboardCustomizationView(vm: vm) }
        .sheet(item: $vital) { metric in VitalDetailView(vm: vm, metric: metric) }
        .fullScreenCover(isPresented: $showsTrackpad) { TrackpadScreen(vm: vm) }
        .confirmationDialog(confirmation?.question ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action.confirmTitle, role: action == .lock ? nil : .destructive) {
                    confirmation = nil
                    OrbitHaptics.warning()
                    Task {
                        await vm.sendPowerAction(action.rawValue)
                        companion.noteSent(action.rawValue)
                        // Orbit Companion 5 gives Windows 30 seconds, counted down at the top.
                        await companion.refreshPower()
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.explanation ?? "")
        }
    }

    private var state: PCHomeState { PCHomeState(vm: vm) }

    // MARK: Online

    @ViewBuilder
    private var onlineContent: some View {
        if state == .demo { PCDemoBanner(vm: vm, showsDiscovery: $showsDiscovery) }
        if state == .locked { PCLockedCard(vm: vm, sunshine: sunshine) }
        if let game = vm.metrics.activeGame, !game.isEmpty {
            PCNowPlayingCard(vm: vm, sunshine: sunshine, game: game, tab: $tab)
        }
        PCVitalsSection(vm: vm, vital: $vital, showsCustomize: $showsCustomize)
        PCControlsSection(vm: vm, showsTrackpad: $showsTrackpad, showsClipboard: $showsClipboard, confirmation: $confirmation)
        PCSoundSection(vm: vm, showsMixer: $showsMixer)
        PCActivitySection(vm: vm)
        PCAboutSection(vm: vm)
    }

    // MARK: PC menu

    @ViewBuilder
    private var pcMenu: some View {
        if !vm.savedPCs.isEmpty {
            Section {
                ForEach(vm.savedPCs) { pc in
                    Button {
                        OrbitHaptics.selection()
                        vm.selectPC(pc)
                    } label: {
                        if pc.id == vm.selectedPCID {
                            Label(pc.name, systemImage: "checkmark")
                        } else {
                            Text(pc.name)
                        }
                    }
                }
            }
        }
        Section {
            Button("Add PC…", systemImage: "plus") { showsDiscovery = true }
            if !vm.savedPCs.isEmpty {
                Button("Manage PCs…", systemImage: "desktopcomputer") { showsPCs = true }
            }
        }
        Section {
            Toggle(isOn: Binding(get: { vm.isDynamicIslandActive }, set: { _ in vm.toggleDynamicIsland() })) {
                Label("Show on Lock Screen", systemImage: "platter.filled.top.iphone")
            }
            .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
        }
    }
}

enum PCHomeDestination: Hashable {
    case processes, specs, sessions, sources
}

/// What the PC tab should show.
enum PCHomeState: Equatable {
    case setup, demo, connecting, waking, online, locked, offline

    @MainActor
    init(vm: OrbitViewModel) {
        if vm.isDemoMode { self = .demo }
        else if !vm.isConfigured { self = .setup }
        else if vm.metrics.isOnline { self = vm.metrics.sessionLocked == true ? .locked : .online }
        else if vm.isWakingUp { self = .waking }
        else if vm.lastConnectionFailed { self = .offline }
        else { self = .connecting }
    }

    var markStatus: OrbitMark.Status {
        switch self {
        case .online, .demo: return .online
        case .locked: return .locked
        case .connecting, .waking: return .working
        case .offline: return .offline
        case .setup: return .plain
        }
    }
}

// MARK: - Header

private struct PCStatusHeader: View {
    @ObservedObject var vm: OrbitViewModel
    var state: PCHomeState

    var body: some View {
        HStack(spacing: 16) {
            OrbitMark(status: state.markStatus, size: 46)
                .padding(4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .setup: return "No PC yet"
        case .demo, .online: return OrbitTakeaway(vm.metrics).headline
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        case .locked: return "Locked"
        case .offline: return "Asleep or off"
        }
    }

    private var detail: String {
        switch state {
        case .setup: return "Add a Windows PC to get started."
        case .demo: return "Sample data · nothing is sent to a PC"
        case .connecting: return "Reaching Orbit Companion on \(vm.cleanHost())"
        case .waking: return "Sent the wake-up signal. This takes up to a minute."
        case .online, .locked:
            var parts: [String] = ["Online"]
            if vm.pingMs > 0 { parts.append("\(vm.pingMs) ms") }
            if vm.metrics.uptimeSeconds > 0 { parts.append("up \(OrbitFormat.duration(seconds: vm.metrics.uptimeSeconds))") }
            if state == .locked { parts[0] = "Windows is locked" }
            return parts.joined(separator: " · ")
        case .offline:
            let reach = vm.pcMAC.isEmpty ? "Orbit can't reach it right now." : "Orbit can wake it over your network."
            guard let last = vm.lastUpdated else { return reach }
            return "Last update \(last.formatted(date: .omitted, time: .shortened)). \(reach)"
        }
    }
}



// MARK: - Setup, demo, offline

private struct PCSetupCard: View {
    @ObservedObject var vm: OrbitViewModel
    @Binding var showsDiscovery: Bool

    var body: some View {
        VStack(spacing: 18) {
            OrbitMark(status: .online, size: 88)
                .padding(.top, 24)
            VStack(spacing: 8) {
                Text("Your PC, from your iPhone")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Install Orbit Companion on your Windows PC, then pair with the code it shows. Orbit finds it on your network.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button {
                    OrbitHaptics.tap()
                    showsDiscovery = true
                } label: {
                    Text("Find My PC")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .orbitGlassButton(prominent: true)
                Button("Try the Demo") { vm.setDemoMode(true) }
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

private struct PCDemoBanner: View {
    @ObservedObject var vm: OrbitViewModel
    @Binding var showsDiscovery: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("You're looking at sample data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Connect a PC") {
                vm.setDemoMode(false)
                showsDiscovery = true
            }
            .font(.subheadline.weight(.semibold))
        }
        .orbitSurface(padding: 14, radius: 18)
    }
}

private struct PCOfflineSection: View {
    @ObservedObject var vm: OrbitViewModel
    var state: PCHomeState
    @State private var showsSettings = false

    private var canWake: Bool { !vm.pcMAC.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state != .connecting {
                Button {
                    OrbitHaptics.press()
                    Task { await vm.wakePC() }
                } label: {
                    HStack(spacing: 10) {
                        if state == .waking {
                            ProgressView()
                        } else {
                            Image(systemName: "power")
                        }
                        Text(state == .waking ? "Waking…" : "Wake PC")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .orbitGlassButton(prominent: true)
                .disabled(!canWake || state == .waking)

                if !canWake {
                    Text("To wake this PC, Orbit needs its network address. Connect once while the PC is on and Orbit remembers it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Is Orbit Companion running on the PC?", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                Text(vm.statusLog)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await vm.refreshMetrics() } }
                    .font(.subheadline.weight(.semibold))
            }
            .orbitSurface()
            .opacity(state == .offline ? 1 : 0)
            .frame(height: state == .offline ? nil : 0)
            .clipped()
        }
    }
}

// MARK: - Locked & now playing

private struct PCLockedCard: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared

    private var canUnlock: Bool { sunshine.isPaired && sunshine.reachable && sunshine.desktopApp != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows is waiting for your password")
                .font(.headline)
            Text(canUnlock
                 ? "Orbit opens the sign-in screen and types the password you enter, once. It's never saved."
                 : "Pair Orbit with Sunshine in Play to sign in from here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                OrbitHaptics.press()
                if let app = sunshine.desktopApp {
                    MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                                 settings: settings.settings, promptUnlock: true))
                }
            } label: {
                Label("Unlock", systemImage: "lock.open")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .orbitGlassButton(prominent: true)
            .disabled(!canUnlock)
        }
        .orbitSurface()
    }
}

private struct PCNowPlayingCard: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    var game: String
    @Binding var tab: OrbitTab
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared

    private var app: MoonlightApp? {
        guard sunshine.isPaired, sunshine.reachable, !vm.isDemoMode else { return nil }
        return sunshine.app(titled: game) ?? sunshine.desktopApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Playing now")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(game)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
            }
            HStack(alignment: .top, spacing: 28) {
                OrbitReading(label: "Frame rate", value: vm.metrics.fps.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }, unit: "fps", valueSize: 34)
                OrbitReading(label: "Graphics", value: OrbitFormat.percent(vm.metrics.gpuUsage), unit: "%", valueSize: 34,
                             valueColor: OrbitPalette.load(vm.metrics.gpuUsage.map { $0 / 100 }))
                OrbitReading(label: "GPU", value: OrbitFormat.temperature(vm.metrics.gpuTemp), valueSize: 34,
                             valueColor: OrbitPalette.temperature(vm.metrics.gpuTemp))
            }
            HStack(spacing: 10) {
                Button {
                    OrbitHaptics.press()
                    if let app {
                        MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                                     settings: settings.settings, promptUnlock: false))
                    } else {
                        tab = .play
                    }
                } label: {
                    Label(app == nil ? "Open Play" : "Stream Here", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .orbitGlassButton(prominent: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                OrbitPalette.surface
                if let data = app.flatMap({ sunshine.artwork[$0.id] }), let artwork = UIImage(data: data) {
                    // The game's own art, pushed far back so the type stays legible.
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 28)
                        .opacity(0.55)
                    LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.surfaceRadius, style: .continuous))
        }
        .onAppear { if let app { sunshine.loadArtwork(for: app) } }
    }
}
