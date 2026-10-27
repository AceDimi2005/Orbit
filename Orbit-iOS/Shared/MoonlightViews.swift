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
            if let title = runningAppTitle { return "\(title) is running on \(pcName). Resume the stream to keep playing, or quit it here." }
            return "Paired with Sunshine. \(apps.count) app\(apps.count == 1 ? "" : "s") ready to stream here with video, audio and controller input."
        }
        if reachable { return "Sunshine answered on \(activeAddress). Pair once (PIN) and Orbit can stream \(pcName) right here." }
        return "Sunshine was not found on \(activeAddress). Install Sunshine on the PC and allow it through the firewall."
    }
}

/// Shortcuts the Orbit agent on the PC offers while pairing: typing the PIN into Sunshine for
/// the user (with a Sunshine web UI login saved on the PC) and starting Sunshine.
struct MoonlightPairingAutomation {
    var canSubmitPIN: Bool
    var canStartSunshine: Bool
    var sunshineRunning: Bool
    var client: () throws -> OrbitAPIClient

    func submitPIN(_ pin: String) async throws {
        do {
            _ = try await client().data("/api/sunshine/pin", method: "POST",
                                        query: [URLQueryItem(name: "pin", value: pin), URLQueryItem(name: "name", value: MoonlightHostCoordinator.pairingName)])
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Orbit PC Companion 4.3.0 and older send the PIN the way Sunshine took it before 2026.
            if message.contains("HTTP 400 to the PIN request") {
                throw MoonlightError(message: "\(message) Update Orbit PC Companion on the PC to 4.3.1 or later for Sunshine 2026, or enter the PIN in Sunshine's web UI.")
            }
            throw error
        }
    }

    func saveLogin(username: String, password: String) async throws {
        let _: MoonlightAgentLoginResult = try await client().send("/api/sunshine/credentials", body: MoonlightAgentLogin(username: username, password: password))
    }

    func startSunshine() async throws {
        _ = try await client().data("/api/sunshine/start", method: "POST")
    }
}

private struct MoonlightAgentLogin: Encodable { let username: String; let password: String }
private struct MoonlightAgentLoginResult: Decodable { let status: String; let canSubmitPin: Bool }

/// PIN pairing walkthrough. Sunshine blocks the first request until the PIN is entered on
/// the PC, so this view shows the code and the current stage, and can have the agent type it.
struct MoonlightPairingView: View {
    @ObservedObject var host: MoonlightHostCoordinator
    var pcName: String
    var accent: Color
    var automation: MoonlightPairingAutomation? = nil
    var onDone: () -> Void
    @State private var loginSaved = false
    @State private var showsLogin = false
    @State private var username = ""
    @State private var password = ""
    @State private var automationMessage: String?
    @State private var automationBusy = false

    private var canPairAutomatically: Bool { (automation?.canSubmitPIN ?? false) || loginSaved }

    private var digits: [String] {
        let pin = host.pairingPIN ?? "····"
        return pin.map { String($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair with Sunshine")
                    .font(.title2.weight(.bold))
                Text("\(pcName) · \(host.activeAddress)")
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

            if let automation { automationSection(automation) }

            VStack(alignment: .leading, spacing: 8) {
                step(1, canPairAutomatically ? "Tap Pair automatically. Orbit generates a PIN and the agent on the PC types it into Sunshine." : "Tap Start to generate a PIN. Orbit asks Sunshine to pair and waits.")
                step(2, canPairAutomatically ? "If Sunshine asks, confirm the new device in its web UI." : "On the PC open Sunshine's web UI, PIN page, and enter the PIN with a device name.")
                step(3, "Orbit verifies the host certificate and stores the pairing. From then on, Stream connects straight away.")
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
                    if let automation, canPairAutomatically {
                        Button { pairAutomatically(automation) } label: { Label("Pair automatically", systemImage: "wand.and.stars") }
                            .disabled(!host.isConfigured || automationBusy)
                    }
                    Button(canPairAutomatically ? "Enter PIN myself" : "Start") { host.beginPairing() }
                        .disabled(!host.isConfigured)
                    Button("Close", role: .cancel) { onDone() }
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    /// Starts pairing, then asks the agent to type the PIN once Sunshine has the request open.
    private func pairAutomatically(_ automation: MoonlightPairingAutomation) {
        host.beginPairing()
        guard let pin = host.pairingPIN else { return }
        automationMessage = "Sending the PIN to \(pcName)…"
        run {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard host.isPairing, host.pairingPIN == pin else { return }
            try await automation.submitPIN(pin)
            automationMessage = "PIN entered on the PC. Finishing the handshake…"
        }
    }

    @ViewBuilder private func automationSection(_ automation: MoonlightPairingAutomation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !automation.sunshineRunning {
                HStack(spacing: 10) {
                    Label("Sunshine is not running on \(pcName).", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    if automation.canStartSunshine {
                        Button("Start Sunshine") {
                            run { try await automation.startSunshine(); automationMessage = "Sunshine is starting on the PC. Try again in a few seconds." }
                        }
                        .disabled(automationBusy)
                    }
                }
            }
            if canPairAutomatically {
                Label("The Orbit agent on \(pcName) can type the PIN into Sunshine for you.", systemImage: "wand.and.stars")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 1)) { showsLogin.toggle() } } label: {
                    HStack {
                        Label("Let Orbit type the PIN for you", systemImage: "wand.and.stars").font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold)).rotationEffect(.degrees(showsLogin ? 180 : 0))
                    }
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                #endif
                if showsLogin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save the Sunshine web UI login once. It stays on the PC next to the agent token; Orbit only asks the agent to enter PINs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TextField("Sunshine username", text: $username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        SecureField("Sunshine password", text: $password)
                        Button("Save on PC") {
                            let name = username, secret = password
                            run {
                                try await automation.saveLogin(username: name, password: secret)
                                loginSaved = true
                                password = ""
                                automationMessage = "Login saved on \(pcName). Orbit will enter PINs for you."
                            }
                        }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || automationBusy)
                    }
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if let automationMessage {
                Text(automationMessage).font(.caption).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        automationBusy = true
        Task { @MainActor in
            defer { automationBusy = false }
            do { try await work() } catch {
                automationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
