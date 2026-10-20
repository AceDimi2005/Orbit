import SwiftUI

// SwiftUI pieces for the Sunshine/Moonlight integration, shared by iOS, tvOS and macOS.

enum MoonlightStatusTone { case neutral, good, warning, active }

extension MoonlightHostCoordinator {
    var statusTone: MoonlightStatusTone {
        if isPairing { return .active }
        if !isConfigured { return .neutral }
        if !isPaired { return reachable ? .neutral : .warning }
        if !reachable { return .warning }
        return isBusy ? .active : .good
    }

    /// One-line explanation shown under the status.
    func summary(pcName: String) -> String {
        if !isConfigured { return "Select a PC to see its Sunshine host." }
        if isPairing { return "Type the PIN on the PC. Sunshine keeps the request open until you do." }
        if isPaired {
            if !reachable { return "Paired, but Sunshine on \(pcName) is not answering. Check that Sunshine is running." }
            if let title = runningAppTitle { return "\(title) is running on \(pcName). Open Moonlight and choose Resume to watch it, or quit it here." }
            return "Paired with Sunshine. \(apps.count) app\(apps.count == 1 ? "" : "s") with box art; video streaming runs in the Moonlight app."
        }
        if reachable { return "Sunshine answered on \(address). Pair once so Orbit can read its app list, show box art and stop sessions." }
        return "Sunshine was not found on \(address). Install Sunshine on the PC and allow it through the firewall."
    }
}

/// PIN pairing walkthrough. Sunshine blocks the first request until the PIN is entered on
/// the PC, so this view simply shows the code and the current stage.
struct MoonlightPairingView: View {
    @ObservedObject var host: MoonlightHostCoordinator
    var pcName: String
    var accent: Color
    var onDone: () -> Void

    private var digits: [String] {
        let pin = host.pairingPIN ?? "····"
        return pin.map { String($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair with Sunshine")
                    .font(.title2.weight(.bold))
                Text("\(pcName) · \(host.address)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(Array(digits.enumerated()), id: \.offset) { _, digit in
                    Text(digit)
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(host.isPairing ? accent : Color.white.opacity(0.12), lineWidth: 1))
                }
            }
            .frame(maxWidth: 360)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(host.pairingPIN.map { "Pairing PIN \($0.map(String.init).joined(separator: " "))" } ?? "No PIN yet")

            if let stage = host.pairingStage {
                Label(stage, systemImage: host.isPairing ? "hourglass" : "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(host.isPairing ? accent : .green)
            }
            if let error = host.lastError {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Tap Start to generate a PIN. Orbit asks Sunshine to pair and waits.")
                step(2, "On the PC open Sunshine's web UI, PIN page, and enter the PIN with a device name.")
                step(3, "Orbit verifies the host certificate and stores the pairing. Moonlight keeps its own pairing; pair it separately for video.")
            }
            if let url = host.pairingPageURL {
                #if os(tvOS)
                Text("PIN page on the PC: \(url.absoluteString) (also https://localhost:47990/pin on the PC itself)")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Link(destination: url) {
                    Label("Open the Sunshine PIN page", systemImage: "safari")
                        .font(.callout.weight(.semibold))
                }
                .tint(accent)
                Text("The page uses Sunshine's self-signed certificate, so the browser shows a warning once. On the PC itself it is https://localhost:\(url.port ?? 47990)/pin.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }

            HStack(spacing: 12) {
                if host.isPairing {
                    Button("Cancel", role: .cancel) { host.cancelPairing() }
                } else if host.isPaired {
                    Button("Done") { onDone() }
                } else {
                    Button("Start") { host.beginPairing() }
                        .disabled(!host.isConfigured)
                    Button("Close", role: .cancel) { onDone() }
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
                .background(accent.opacity(0.14), in: Circle())
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Box art from Sunshine (`/appasset`) or nothing; callers draw their own placeholder.
struct MoonlightArtwork: View {
    var data: Data?

    var body: some View {
        if let data, let image = Self.image(data) {
            image.resizable().scaledToFill()
        }
    }

    private static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}
