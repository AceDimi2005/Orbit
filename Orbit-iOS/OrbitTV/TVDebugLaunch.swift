#if DEBUG
import SwiftUI

/// Screenshot hooks for the tvOS Simulator, which has no Siri Remote here. Debug builds only:
///
///     xcrun simctl launch <udid> com.dimitrie.orbit -OrbitNoSync YES \
///         -OrbitInitialTab sound -OrbitState demo -OrbitSheet output
///
/// - `-OrbitInitialTab pc|play|sound|activity|settings` opens that place.
/// - `-OrbitState demo|locked|waking|asleep|connecting` puts the app in that state (`locked` and
///   `asleep` use the sample data; `waking` pretends a wake-up signal just went out;
///   `connecting` stops polling before the PC has answered).
/// - `-OrbitSheet <name>` opens a sheet or dialog on the chosen place: `vital`, `power`,
///   `quitgame`, `addpc` (PC); `game`, `pairing`, `quality` (Play); `output` (Sound); `endtask`
///   (Activity); `addpc`, `pc`, `pro`, `acknowledgements`, `settings-pairing` (Settings).
/// - `-OrbitNoDiscovery YES` keeps the Add PC page from browsing the network.
/// - `-OrbitScrollToEnd YES` starts the places' scroll views at their end.
/// - `-OrbitFocus <id>` moves focus to a control marked with `.tvDebugFocus(<id>)`, to check
///   how it looks focused (`tile`, `control`, `power`, `poster`, `mixer`, `mixer-last`, `media`,
///   `process`, `sort`, `row-sunshine`, `row-addpc`).
/// - `-OrbitNoSync YES` and `-OrbitDebugToken <token>` (read by the view model) keep a run on
///   the seeded PC only.
enum TVDebugLaunch {
    private static var defaults: UserDefaults { .standard }

    static var tab: Int? {
        switch defaults.string(forKey: "OrbitInitialTab")?.lowercased() {
        case "pc": return 0
        case "play": return 1
        case "sound": return 2
        case "activity": return 3
        case "settings": return 4
        default: return nil
        }
    }

    static var state: String? { defaults.string(forKey: "OrbitState")?.lowercased() }
    static var sheet: String? { defaults.string(forKey: "OrbitSheet")?.lowercased() }
    static var discoveryOff: Bool { defaults.bool(forKey: "OrbitNoDiscovery") }
    static var scrollToEnd: Bool { defaults.bool(forKey: "OrbitScrollToEnd") }
    static var focus: String? { defaults.string(forKey: "OrbitFocus")?.lowercased() }
    /// `-OrbitToast <text>` shows a confirmation toast a moment after launch.
    static var toast: String? { defaults.string(forKey: "OrbitToast") }

    @MainActor
    static func apply(to vm: OrbitTVViewModel) {
        if let tab { vm.selectedTab = tab }
        switch state {
        case "demo":
            vm.setDemoMode(true)
        case "locked":
            vm.setDemoMode(true)
            vm.metrics.sessionLocked = true
        case "asleep":
            vm.setDemoMode(true)
            vm.metrics.isOnline = false
        case "waking":
            vm.wakeSentAt = Date()
        case "connecting":
            // Stop polling once the first attempt is over, and show the PC as not answered yet.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                vm.setAppActive(false)
                vm.metrics.isOnline = false
                vm.lastConnectionFailed = false
            }
        default:
            break
        }
    }
}

/// Focuses the marked control a moment after launch when `-OrbitFocus` names it.
struct TVDebugFocusModifier: ViewModifier {
    let id: String
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .task {
                guard TVDebugLaunch.focus == id.lowercased() else { return }
                try? await Task.sleep(for: .seconds(2.5))
                focused = true
            }
    }
}
#endif
