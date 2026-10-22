import MoonlightCore
import SwiftUI

/// While a game runs on the PC, a mini player sits above the tab bar on every tab:
/// the game, its frame rate, and one tap to stream it here.
struct NowPlayingAccessoryModifier: ViewModifier {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator

    private var isPlaying: Bool {
        vm.metrics.isOnline && !(vm.metrics.activeGame ?? "").isEmpty
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isPlaying) {
                NowPlayingAccessory(vm: vm, sunshine: sunshine)
            }
        } else {
            content
        }
    }
}

private struct NowPlayingAccessory: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    @ObservedObject private var settings = MoonlightStreamSettingsStore.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var game: String { vm.metrics.activeGame ?? "" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(game)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if placement != .inline {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let app = streamableApp {
                Button {
                    OrbitHaptics.press()
                    MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                                 settings: settings.settings, promptUnlock: false))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Stream \(game)")
            }
        }
        .padding(.horizontal, 14)
    }

    private var detail: String {
        var parts: [String] = []
        if let fps = vm.metrics.fps, fps.isFinite { parts.append("\(Int(fps.rounded())) fps") }
        if let gpu = vm.metrics.gpuUsage, gpu.isFinite { parts.append("GPU \(Int(gpu.rounded()))%") }
        parts.append(vm.selectedPCName)
        return parts.joined(separator: " · ")
    }

    /// The running game, if Sunshine knows it; otherwise the desktop, so the stream shows it anyway.
    private var streamableApp: MoonlightApp? {
        guard sunshine.isPaired, sunshine.reachable, !vm.isDemoMode else { return nil }
        return sunshine.app(titled: game) ?? sunshine.desktopApp
    }
}
