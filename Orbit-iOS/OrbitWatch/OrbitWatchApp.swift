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
        }
    }
}
