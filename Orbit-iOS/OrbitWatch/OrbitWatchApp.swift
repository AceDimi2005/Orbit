import SwiftUI
import WatchKit

@main
struct OrbitWatchApp: App {
    @StateObject private var viewModel = OrbitWatchViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            OrbitWatchRootView(vm: viewModel)
                .onChange(of: scenePhase) { _, newPhase in
                    viewModel.setAppActive(newPhase == .active)
                }
                .onOpenURL { url in
                    viewModel.handleDeepLink(url)
                }
                #if DEBUG
                .onAppear {
                    // A PC reached directly over plain HTTP, for testing without a paired iPhone:
                    // `SIMCTL_CHILD_ORBIT_WATCH_TEST_PC='192.168.1.20|<token>|8765' xcrun simctl launch <device> com.dimitrie.orbit.watchkitapp`
                    if let spec = ProcessInfo.processInfo.environment["ORBIT_WATCH_TEST_PC"] {
                        viewModel.useTestPC(spec)
                    }
                    // The watchOS Simulator cannot open URLs; for screenshots:
                    // `SIMCTL_CHILD_ORBIT_WATCH_LINK=orbitwatch://buttons xcrun simctl launch <device> com.dimitrie.orbit.watchkitapp`
                    if let link = ProcessInfo.processInfo.environment["ORBIT_WATCH_LINK"].flatMap(URL.init(string:)) {
                        viewModel.handleDeepLink(link)
                    }
                }
                #endif
        }
    }
}
