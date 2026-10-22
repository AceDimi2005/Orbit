import SwiftUI

/// Orbit on Apple Watch: whether the watch is ready, and what it does.
struct AppleWatchCompanionHelpView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var watchBridge = OrbitWatchBridge.shared

    var body: some View {
        OrbitPage {
            HStack(spacing: 16) {
                Image(systemName: "applewatch")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 50)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                    OrbitStatusLabel(text: statusText, color: statusColor, pulsing: watchBridge.isWatchReachable)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 14) {
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    OrbitHaptics.tap()
                    watchBridge.pushStateToWatch(force: true)
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .orbitGlassButton()
                .disabled(!watchBridge.isWatchPaired)
                if watchBridge.isWatchPaired, let lastSync = watchBridge.lastWatchSync {
                    Text("Last synced at \(lastSync.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .orbitSurface()

            VStack(alignment: .leading, spacing: 12) {
                OrbitSectionHeader("On Your Wrist")
                VStack(alignment: .leading, spacing: 22) {
                    OrbitFeatureRow(systemImage: "gauge.with.needle", title: "See how it's doing",
                                    text: "Your PC's status and main readings, as soon as you raise your wrist.")
                    OrbitFeatureRow(systemImage: "hand.point.up.left", title: "Move the pointer",
                                    text: "Tilt your wrist or swipe the screen, and scroll with the Digital Crown.")
                    OrbitFeatureRow(systemImage: "power", title: "Wake it, sleep it, shut it down",
                                    text: "Power works straight from the watch, and asks before turning anything off.")
                    OrbitFeatureRow(systemImage: "speaker.wave.2", title: "Change the volume",
                                    text: "Turn the Digital Crown to set the PC's volume.")
                    OrbitFeatureRow(systemImage: "applewatch.watchface", title: "On your watch face",
                                    text: "Add Orbit to a watch face or the Smart Stack. The Live Activity appears there too.")
                }
                .orbitSurface()
            }

            Text("Your watch reaches the PC through this iPhone, or on its own when both are on the same Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headline: String {
        if !watchBridge.isWatchSupported { return "Orbit on Apple Watch" }
        if watchBridge.isWatchPaired && watchBridge.isWatchAppInstalled { return "Orbit is on your watch" }
        return "Orbit on Apple Watch"
    }

    private var statusText: String {
        if !watchBridge.isWatchSupported { return "Not available on this device" }
        if watchBridge.isWatchReachable { return "Connected" }
        if watchBridge.isWatchPaired { return watchBridge.isWatchAppInstalled ? "Installed" : "Not installed" }
        return "No watch paired"
    }

    private var statusColor: Color {
        if watchBridge.isWatchReachable { return OrbitPalette.online }
        if watchBridge.isWatchPaired && watchBridge.isWatchAppInstalled { return .secondary }
        return OrbitPalette.warm
    }

    private var guidance: String {
        if !watchBridge.isWatchSupported { return "Use an iPhone paired with an Apple Watch to put Orbit on your wrist." }
        if watchBridge.isWatchReachable { return "Your PCs and readings reach the watch right away." }
        if watchBridge.isWatchPaired && watchBridge.isWatchAppInstalled { return "Open Orbit on the watch to connect. Your PCs sync on their own." }
        if watchBridge.isWatchPaired { return "Install Orbit from the Watch app on this iPhone, in Available Apps." }
        return "Pair an Apple Watch with this iPhone to use Orbit on it."
    }
}
