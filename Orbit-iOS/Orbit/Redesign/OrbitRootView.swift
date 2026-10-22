import MoonlightCore
import SwiftUI
import UIKit

enum OrbitTab: Hashable {
    case pc, play, files
}

/// The app: three places, named for what is in them. Settings and the PC switcher live
/// in the PC tab's navigation bar; trackpad, clipboard and the mixer open from the PC tab.
struct OrbitRootView: View {
    @StateObject private var vm = OrbitViewModel()
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @StateObject private var companion = PCCompanion()
    @ObservedObject private var stream = MoonlightStreamController.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var tab: OrbitTab = .pc
    @State private var showsPro = false
    @State private var confirmation: PCPowerAction?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            Tab("PC", systemImage: "desktopcomputer", value: OrbitTab.pc) {
                PCHomeView(vm: vm, sunshine: sunshine, tab: $tab)
            }
            Tab("Play", systemImage: "gamecontroller", value: OrbitTab.play) {
                PlayView(vm: vm, sunshine: sunshine)
            }
            Tab("Files", systemImage: "folder", value: OrbitTab.files) {
                // Files owns its navigation stack, so folders push like the Files app.
                PCFilesView(vm: vm)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(NowPlayingAccessoryModifier(vm: vm, sunshine: sunshine))
        #if DEBUG
        .modifier(OrbitDebugScreenModifier(vm: vm))
        #endif
        .tint(theme.orbitTint)
        .onChange(of: tab) { _, _ in OrbitHaptics.selection() }
        .task(id: sunshineKey) { await syncSunshine() }
        .task(id: "\(vm.connectionID)|\(vm.metrics.isOnline)|\(vm.isDemoMode)") {
            // Orbit Companion 5: what the PC can do, and any power timer or countdown pending.
            companion.attach(vm)
            companion.reset(for: "\(vm.connectionID)|\(vm.isDemoMode)")
            guard vm.metrics.isOnline, !vm.isDemoMode else { return }
            await companion.refreshCapabilities()
            while !Task.isCancelled {
                await companion.refreshPower()
                let soon = companion.power?.timer?.state == "countdown" || (companion.power?.timer?.remainingSeconds ?? .max) < 90
                do { try await Task.sleep(for: .seconds(soon ? 3 : 15)) } catch { break }
            }
        }
        .environmentObject(companion)
        .overlay {
            if vm.smartLaunchStep != .idle {
                SmartLaunchOverlay(vm: vm).transition(.opacity)
            }
        }
        .animation(OrbitMotion.standard, value: vm.smartLaunchStep)
        .fullScreenCover(isPresented: $vm.isShowingStreamView) {
            MoonlightStreamView(vm: vm)
        }
        .fullScreenCover(isPresented: $stream.isPresented) {
            MoonlightStreamScreen(controller: stream, accent: theme.orbitTint)
        }
        .onChange(of: vm.metrics.sessionLocked, initial: true) { _, locked in stream.pcLocked = locked == true }
        .sheet(isPresented: $vm.showOnboarding) {
            WelcomeView(vm: vm)
                .interactiveDismissDisabled(!vm.hasCompletedOnboarding)
        }
        .sheet(isPresented: $vm.isShowingIPConfigSheet) {
            SettingsHubView(vm: vm)
                .environmentObject(companion)
        }
        .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
        .confirmationDialog(confirmation?.question ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action.confirmTitle, role: .destructive) {
                    confirmation = nil
                    OrbitHaptics.warning()
                    Task {
                        await vm.sendPowerAction(action.rawValue)
                        companion.noteSent(action.rawValue)
                        await companion.refreshPower()
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.explanation ?? "")
        }
        .onAppear {
            vm.setAppActive(scenePhase == .active)
            if !vm.hasCompletedOnboarding { vm.showOnboarding = true }
            OrbitProStore.shared.start()
        }
        .onChange(of: scenePhase) { _, phase in
            vm.setAppActive(phase == .active)
            if phase == .active { OrbitProStore.shared.refreshIfNeeded() }
        }
        .onReceive(OrbitProStore.shared.$isProUnlocked) { _ in OrbitProLockdown.enforce() }
        .onReceive(OrbitProStore.shared.$hasVerifiedEntitlements) { _ in OrbitProLockdown.enforce() }
        .onOpenURL(perform: open)
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }

    private var sunshineKey: String {
        "\(vm.selectedPCID)|\(vm.cleanHost())|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)"
    }

    private func syncSunshine() async {
        guard !vm.isDemoMode else { return }
        sunshine.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                           httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    /// `orbit://` links. Links that would power the PC down ask first: anything on the
    /// phone can open a URL, so a link alone must never shut a computer down.
    private func open(_ url: URL) {
        guard url.scheme?.lowercased() == "orbit" else { return }
        switch url.host?.lowercased() {
        case "pro": showsPro = true
        case "library", "play": tab = .play
        case "files": tab = .files
        case "settings": vm.isShowingIPConfigSheet = true
        case "wake":
            tab = .pc
            Task { await vm.wakePC() }
        case "shutdown": tab = .pc; confirmation = .shutdown
        case "sleep": tab = .pc; confirmation = .sleep
        case "restart": tab = .pc; confirmation = .restart
        default: tab = .pc
        }
    }
}

/// Power actions that change the PC's state, with the words used to confirm them.
enum PCPowerAction: String, Identifiable {
    case sleep, restart, shutdown, lock

    var id: String { rawValue }

    var question: String {
        switch self {
        case .sleep: return "Put the PC to sleep?"
        case .restart: return "Restart the PC?"
        case .shutdown: return "Shut down the PC?"
        case .lock: return "Lock the PC?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutdown: return "Shut Down"
        case .lock: return "Lock"
        }
    }

    var explanation: String {
        switch self {
        case .sleep: return "You can wake it again from Orbit."
        case .restart, .shutdown: return "Unsaved work in open apps on the PC may be lost."
        case .lock: return "Windows shows the sign-in screen."
        }
    }

    var systemImage: String {
        switch self {
        case .sleep: return "moon"
        case .restart: return "arrow.clockwise"
        case .shutdown: return "power"
        case .lock: return "lock"
        }
    }
}

extension OrbitTheme {
    /// The accent used by the redesigned app: one color for interactive and live elements.
    var orbitTint: Color { OrbitAccent.color(theme: rawValue) }
}
