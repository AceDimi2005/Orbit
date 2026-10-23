import SwiftUI

@main
struct OrbitTVApp: App {
    @StateObject private var viewModel = OrbitTVViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            OrbitTVRootView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    viewModel.setAppActive(newPhase == .active)
                    if newPhase == .active { OrbitProStore.shared.refreshIfNeeded() }
                }
                .onAppear { OrbitProStore.shared.start() }
                #if DEBUG
                .onAppear {
                    // Screenshots in the headless tvOS Simulator (no remote to change tabs):
                    // `SIMCTL_CHILD_ORBIT_TV_TAB=1 xcrun simctl launch <device> com.dimitrie.orbit`
                    let environment = ProcessInfo.processInfo.environment
                    if let tab = environment["ORBIT_TV_TAB"].flatMap(Int.init) { viewModel.selectedTab = tab }
                    // `ORBIT_TV_DEMO=1` turns demo mode on after the launch-time iPhone sync (which would turn it off).
                    if environment["ORBIT_TV_DEMO"] == "1" {
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            viewModel.setDemoMode(true)
                        }
                    }
                }
                #endif
        }
    }
}
