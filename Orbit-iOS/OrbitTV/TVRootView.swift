import MoonlightCore
import SwiftUI

/// The Apple TV app: five places in the top tab bar, named for what is in them. The tags
/// keep the old order (0 PC … 4 Settings), so `tv.initialTab` and the jump to the PC after
/// pairing still land in the right place.
struct OrbitTVRootView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @ObservedObject private var stream = MoonlightStreamController.shared
    @ObservedObject private var proStore = OrbitProStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accent: Color = OrbitPalette.accent
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            Tab("PC", systemImage: "desktopcomputer", value: 0) {
                TVPCView(sunshine: sunshine)
            }
            Tab("Play", systemImage: "gamecontroller", value: 1) {
                TVPlayView(sunshine: sunshine)
            }
            Tab("Sound", systemImage: "speaker.wave.2", value: 2) {
                TVSoundView()
            }
            Tab("Activity", systemImage: "list.bullet", value: 3) {
                TVActivityView()
            }
            Tab("Settings", systemImage: "gearshape", value: 4) {
                TVSettingsView(sunshine: sunshine)
            }
        }
        .background(OrbitPalette.canvas.ignoresSafeArea())
        .tint(accent)
        .environment(\.tvAccent, accent)
        .environment(\.tvToast, TVToastAction { showToast($0) })
        .overlay(alignment: .bottom) { toastView }
        // The remote's Play/Pause button plays and pauses media on the PC from every screen.
        .onPlayPauseCommand {
            Task { await vm.sendAction("media_play_pause") }
        }
        .fullScreenCover(isPresented: $stream.isPresented) {
            MoonlightStreamScreen(controller: stream, accent: accent)
        }
        .onChange(of: vm.metrics.sessionLocked, initial: true) { _, locked in stream.pcLocked = locked == true }
        .task(id: sunshineKey) { await syncSunshine() }
        .onAppear {
            accent = TVAccent.current
            #if DEBUG
            TVDebugLaunch.apply(to: vm)
            if let text = TVDebugLaunch.toast {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    showToast(text, for: .seconds(30))
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            accent = TVAccent.current
        }
        .onChange(of: proStore.isProUnlocked) { _, _ in accent = TVAccent.current }
    }

    // MARK: Sunshine

    private var sunshineKey: String {
        "\(vm.currentPC?.id ?? "")|\(vm.currentPC?.address ?? "")|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)|\(vm.isDemoMode)"
    }

    private func syncSunshine() async {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return }
        sunshine.configure(pcID: pc.id, address: pc.address,
                           httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    // MARK: Toast

    private func showToast(_ text: String, for duration: Duration = .seconds(3)) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : OrbitMotion.standard) { toast = text }
        AccessibilityNotification.Announcement(text).post()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : OrbitMotion.standard) { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.vertical, 22)
                .orbitGlass()
                .frame(maxWidth: 1100)
                .padding(.bottom, 20)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

/// Starts a Sunshine stream of `app` on this Apple TV.
@MainActor
func tvBeginStream(_ app: MoonlightApp, host: MoonlightHostCoordinator, pcName: String, promptUnlock: Bool = false) {
    MoonlightStreamController.shared.begin(.init(host: host, app: app, pcName: pcName,
                                                 settings: MoonlightStreamSettingsStore.shared.settings,
                                                 promptUnlock: promptUnlock))
}

/// One line about the stream quality: "1080p · 60 fps · 20 Mbps · HEVC".
@MainActor
func tvStreamSummary() -> String {
    let settings = MoonlightStreamSettingsStore.shared.settings
    var parts = ["\(settings.pixelSize.height)p", "\(settings.frameRate) fps", "\(settings.bitrateKbps / 1000) Mbps"]
    parts.append(settings.codec == .h264 || !MoonlightDeviceCapabilities.supportsHEVC ? "H.264" : "HEVC")
    if settings.requestsHDR { parts.append("HDR") }
    return parts.joined(separator: " · ")
}
