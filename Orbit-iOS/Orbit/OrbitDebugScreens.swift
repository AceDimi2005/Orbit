#if DEBUG
import SwiftUI

/// DEBUG builds only: `-OrbitDebugScreen <name>` opens one screen at launch, so screenshots
/// can be taken without tapping through the app. Screens that are pushed in the app open
/// full screen in their own navigation stack; sheets open as sheets.
struct OrbitDebugScreenModifier: ViewModifier {
    @ObservedObject var vm: OrbitViewModel
    @State private var screen = UserDefaults.standard.string(forKey: "OrbitDebugScreen")
    @State private var cover: OrbitDebugScreen?
    @State private var sheet: OrbitDebugScreen?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $cover) { item in
                NavigationStack { item.view(vm: vm) }
                    .orbitAppearance()
            }
            .sheet(item: $sheet) { item in
                item.view(vm: vm)
                    .orbitAppearance()
            }
            .task {
                guard let name = screen, let item = OrbitDebugScreen(rawValue: name) else { return }
                screen = nil
                try? await Task.sleep(for: .seconds(1.5))
                switch item {
                case .screen: vm.openDesktopPreview()
                case .launch:
                    vm.activeStreamingGame = SunshineGame(id: "debug", title: "Example game", genre: "", iconSymbol: "gamecontroller", accentHex: "0A84FF")
                    vm.smartLaunchStep = .waitingBoot
                default:
                    if item.isSheet { sheet = item } else { cover = item }
                }
            }
    }
}

enum OrbitDebugScreen: String, Identifiable {
    case taskManager, specs, sessions, sources, fps, mixer, clipboard, readings, discovery, profiles
    case liveActivity, widgets, watch, pro, privacy, gate, names, screen, launch

    var id: String { rawValue }

    var isSheet: Bool {
        switch self {
        case .mixer, .clipboard, .readings, .discovery, .profiles, .pro, .privacy, .names: return true
        default: return false
        }
    }

    @MainActor @ViewBuilder
    func view(vm: OrbitViewModel) -> some View {
        switch self {
        case .taskManager: TaskManagerView(vm: vm)
        case .specs: FullSpecsView(vm: vm)
        case .sessions: SessionHistoryView(vm: vm)
        case .sources: MonitoringSourcesView(vm: vm)
        case .fps: FPSSetupView(vm: vm)
        case .mixer: NavigationStack { AudioMixerView(vm: vm) }
        case .clipboard: NavigationStack { ClipboardView(vm: vm) }
        case .readings: DashboardCustomizationView(vm: vm)
        case .discovery: PCDiscoveryView(vm: vm)
        case .profiles: NavigationStack { PCProfilesView(vm: vm, showsCloseButton: true) }
        case .liveActivity: LiveActivitySettingsView(vm: vm)
        case .widgets: WidgetHelpView(vm: vm)
        case .watch: AppleWatchCompanionHelpView(vm: vm)
        case .pro: OrbitProPaywallView()
        case .privacy: OrbitPrivacyPolicyView()
        case .gate:
            OrbitProGate(title: "Sessions", message: "Recorded sessions with frame rate, temperature and power history are part of Orbit Pro.") {
                EmptyView()
            }
        case .names: ComponentNamesView(vm: vm)
        case .screen, .launch: EmptyView()
        }
    }
}
#endif
