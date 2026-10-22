import MoonlightCore
import SwiftUI

// MARK: - Stream window

/// The `stream` window: shows the live session and closes itself once the stream ends.
struct MacStreamWindowView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var stream = MoonlightStreamController.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if stream.isPresented {
                MoonlightStreamScreen(controller: stream, accent: theme.accent)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                    Text("No stream running").font(.headline)
                    Text("Choose a game in Play and press Stream, or press ⇧⌘S for the desktop.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: stream.isPresented) { _, presented in
            if !presented { dismissWindow(id: "stream") }
        }
    }
}
