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
                }
        }
    }
}
