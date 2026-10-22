import SwiftUI

/// A quick look at the PC's screen: pictures from Orbit Companion, without sound. Games
/// stream from Play, with sound and controllers.
struct MoonlightStreamView: View {
    @ObservedObject var vm: OrbitViewModel
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitPalette.canvas
                    .ignoresSafeArea()
                if let frame = vm.liveFrameImage {
                    Image(uiImage: frame)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("The screen of \(vm.selectedPCName)")
                        .transition(.opacity)
                } else if let error = vm.streamError {
                    OrbitEmptyMessage(systemImage: "display", title: "The screen isn't updating",
                                      message: error, actionTitle: vm.isDemoMode ? nil : "Try Again") {
                        vm.startLiveScreenFeed()
                    }
                } else {
                    VStack(spacing: 16) {
                        OrbitMark(status: .working, size: 44)
                        Text("Connecting to \(vm.selectedPCName)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .animation(OrbitMotion.standard, value: vm.liveFrameImage == nil)
            .navigationTitle("Screen")
            .navigationSubtitle(vm.selectedPCName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { vm.stopStreaming(putPCToSleep: false) }
                        .tint(.primary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("A quick look, without sound. To play, stream the game from Play.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            .onAppear { vm.startLiveScreenFeed() }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }
}
