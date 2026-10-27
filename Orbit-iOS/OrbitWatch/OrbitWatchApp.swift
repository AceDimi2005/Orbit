import SwiftUI
import WatchKit

@main
struct OrbitWatchApp: App {
    @StateObject private var viewModel = OrbitWatchViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before launch finishes: "Stop Reminders" on a presentation reminder can start Orbit in the background.
        WatchPresentationReminders.shared.activate()
    }

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
