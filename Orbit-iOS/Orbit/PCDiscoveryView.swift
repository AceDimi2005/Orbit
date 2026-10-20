import SwiftUI
import Foundation
import UIKit

struct DiscoveredOrbitPC: Identifiable, Equatable {
    var id: String { fingerprint }
    let name: String
    /// IPv4 address when Bonjour resolved one, otherwise the `.local` hostname.
    let host: String
    /// Bonjour hostname kept as a fallback for when the PC's address changes.
    let bonjourHost: String
    let port: Int
    let fingerprint: String
    let version: String
}

@MainActor
final class OrbitPCDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var computers: [DiscoveredOrbitPC] = []
    @Published private(set) var message = "Searching your local network…"
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredOrbitPC] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true; computers = []; resolved = [:]
        message = "Searching your local network…"
        browser.delegate = self
        browser.searchForServices(ofType: "_orbit._tcp.", inDomain: "local.")
    }
    func stop() {
        running = false; browser.stop()
        for service in services { service.stop(); service.delegate = nil }
        services = []
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard running else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        resolved.removeValue(forKey: service.name)
        publish()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery is unavailable. Allow Local Network access for Orbit in iPhone Settings, then try again. You can also use manual setup."
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard running, let data = sender.txtRecordData() else { return }
        let text = NetService.dictionary(fromTXTRecord: data)
        func value(_ key: String) -> String { text[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let fingerprint = OrbitAPIClient.normalizedFingerprint(value("fingerprint"))
        guard OrbitAPIClient.validFingerprint(fingerprint), (1...65535).contains(sender.port),
              value("pairing") == "orbit-srp6a-sha256-2048-v1" else { return }
        // Prefer the resolved IPv4 address over the Bonjour `.local` name: the plain
        // address is what Wake-on-LAN, Tailscale and other VPN/relay setups need, and
        // mDNS names are not resolvable outside the local link. The name is kept as a
        // fallback so a PC whose DHCP lease changes can still be found again.
        let bonjourHost = (sender.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = Self.ipv4Address(from: sender.addresses ?? []) ?? bonjourHost
        guard !host.isEmpty else { return }
        resolved[sender.name] = DiscoveredOrbitPC(name: String(value("name").prefix(80)), host: host, bonjourHost: bonjourHost,
                                                port: sender.port, fingerprint: fingerprint, version: value("version"))
        publish()
    }
    /// First routable IPv4 address in a list of `sockaddr` records from `NetService.addresses`.
    static func ipv4Address(from addresses: [Data]) -> String? {
        for address in addresses where address.count >= MemoryLayout<sockaddr_in>.size {
            var storage = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &storage) { address.copyBytes(to: $0, count: MemoryLayout<sockaddr_in>.size) }
            guard storage.sin_family == sa_family_t(AF_INET) else { continue }
            var raw = storage.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buffer)
            if text.hasPrefix("127.") || text.hasPrefix("169.254.") || text == "0.0.0.0" { continue }
            return text
        }
        return nil
    }
    private func publish() {
        computers = Dictionary(resolved.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        message = computers.isEmpty ? "Keep Orbit Agent open on your PC. Both devices must be on the same local network." : "Choose your PC to show a one-use pairing code on Windows."
    }
}

/// Animated radar used while Bonjour is searching.
private struct OrbitRadarView: View {
    var tint: Color
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var ripple = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(tint.opacity(0.18 - Double(index) * 0.04), lineWidth: 1)
                    .frame(width: 60 + CGFloat(index) * 44, height: 60 + CGFloat(index) * 44)
            }
            if isActive && !reduceMotion {
                Circle()
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 60, height: 60)
                    .scaleEffect(ripple ? 2.6 : 1)
                    .opacity(ripple ? 0 : 0.9)
                AngularGradient(colors: [tint.opacity(0), tint.opacity(0.55)], center: .center, startAngle: .degrees(0), endAngle: .degrees(360))
                    .clipShape(Circle())
                    .frame(width: 148, height: 148)
                    .mask {
                        Circle()
                            .trim(from: 0.62, to: 1)
                            .stroke(style: StrokeStyle(lineWidth: 74))
                            .frame(width: 74, height: 74)
                    }
                    .rotationEffect(.degrees(sweep ? 360 : 0))
            }
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 60, height: 60)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 160, height: 160)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sweep = true }
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) { ripple = true }
        }
        .accessibilityHidden(true)
    }
}

/// Six-cell one-time-code field backed by a hidden text field so the system
/// keyboard, autofill and VoiceOver keep working.
private struct OrbitPINField: View {
    @Binding var pin: String
    var tint: Color
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            TextField("Six-digit code", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(isFocused)
                .opacity(0.02)
                .frame(height: 1)
                .accessibilityLabel("Pairing code shown on your PC")
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    let digits = Array(pin)
                    let digit = index < digits.count ? String(digits[index]) : ""
                    let active = isFocused.wrappedValue && index == min(pin.count, 5)
                    Text(digit)
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(active ? tint : (digit.isEmpty ? .white.opacity(0.1) : tint.opacity(0.45)), lineWidth: active ? 2 : 1)
                        )
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: pin)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused.wrappedValue = true }
        }
    }
}

struct PCDiscoveryView: View {
    @ObservedObject var vm: OrbitViewModel
    var onPaired: (() -> Void)? = nil
    @StateObject private var discovery = OrbitPCDiscovery()
    @State private var candidate: DiscoveredOrbitPC?
    @State private var handshake: OrbitPairingHandshake?
    @State private var pin = ""
    @State private var expiresAt: Date?
    @State private var codeLifetime: Double = 120
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var attempt = UUID()
    @State private var paired = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.orbitTheme) private var theme
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if let candidate {
                            pairingCard(candidate)
                        } else {
                            searchCard
                            nearbyCard
                            needAppCard
                        }
                        if let error {
                            OrbitNotice(title: "Pairing problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        Text("Discovery never shares access tokens. The one-time code proves both sides share the same secret before your PC’s credentials are saved to the Keychain.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .frame(maxWidth: 560)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: candidate)
                    .animation(.snappy, value: error)
                    .animation(.snappy, value: discovery.computers)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(candidate == nil ? "Connect a PC" : "Pair securely")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { pinFocused = false }
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop(); task?.cancel(); attempt = UUID(); handshake = nil; pin = "" }
        }
        .orbitAppearance()
    }

    // MARK: Search

    private var searchCard: some View {
        VStack(spacing: 14) {
            OrbitRadarView(tint: theme.accent, isActive: discovery.computers.isEmpty)
            VStack(spacing: 6) {
                Text(discovery.computers.isEmpty ? "Looking for Orbit PCs…" : "\(discovery.computers.count) PC\(discovery.computers.count == 1 ? "" : "s") found")
                    .font(.title3.weight(.bold))
                    .contentTransition(.numericText())
                Text(discovery.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                OrbitStatChip(label: "Service", value: "_orbit._tcp", icon: "antenna.radiowaves.left.and.right")
                OrbitStatChip(label: "Pairing", value: "SRP-6a", icon: "lock.shield.fill")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 24, tint: theme.accent, elevated: true)
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Nearby computers", systemImage: "desktopcomputer")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button {
                    OrbitHaptics.tap()
                    discovery.stop(); discovery.start()
                } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 20))
            }
            if discovery.computers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(theme.accent)
                    Text("Keep Orbit Agent running in the Windows system tray. Allow it on Private networks if the firewall asks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            ForEach(discovery.computers) { pc in
                Button {
                    OrbitHaptics.press()
                    begin(pc)
                } label: {
                    HStack(spacing: 12) {
                        OrbitIconBadge(systemName: "desktopcomputer", tint: theme.accent, size: 42, filled: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pc.name.isEmpty ? "Orbit PC" : pc.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Orbit Agent \(pc.version) · \(pc.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("Pair")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(theme.heroGradient, in: Capsule())
                    }
                    .padding(12)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1))
                }
                .buttonStyle(.orbitPressable)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22)
    }

    private var needAppCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Need the Windows PC app?", systemImage: "arrow.down.app.fill")
                .font(.subheadline.weight(.bold))
            Text("Install Orbit PC Companion on your Windows computer first, then keep it running in the system tray.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ShareLink(
                    item: URL(string: "https://github.com/AceDimi2005/Orbit")!,
                    subject: Text("Orbit PC Companion for Windows"),
                    message: Text("Download the Orbit PC Companion for Windows: https://github.com/AceDimi2005/Orbit (Direct ZIP: https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip)")
                ) {
                    Label("Send to PC", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 12))
                Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!) {
                    Label("Download .zip", systemImage: "arrow.down.doc.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: .white, cornerRadius: 12))
            }
            Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                Label("Open GitHub (AceDimi2005/Orbit)", systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OrbitGlassButtonStyle(tint: .white, cornerRadius: 12))
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22)
    }

    // MARK: Pairing

    private func pairingCard(_ candidate: DiscoveredOrbitPC) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: paired ? "checkmark.seal.fill" : "desktopcomputer", tint: paired ? .mint : theme.accent, size: 46, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name.isEmpty ? "Your PC" : candidate.name)
                        .font(.headline.weight(.bold))
                    Text("Orbit Agent \(candidate.version) · \(candidate.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Change") { resetAttempt() }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .white, cornerRadius: 20))
                    .font(.caption.weight(.bold))
            }

            if paired {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.mint)
                    Text("Paired securely")
                        .font(.title3.weight(.bold))
                    Text("Credentials are stored in the Keychain. Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if handshake != nil {
                VStack(spacing: 12) {
                    Text("Enter the six-digit code shown on your PC")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    OrbitPINField(pin: $pin, tint: theme.accent, isFocused: $pinFocused)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if pin.count == 6 { OrbitHaptics.selection() }
                        }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let expired = (expiresAt ?? .distantPast) <= context.date
                        VStack(spacing: 12) {
                            if let expiresAt, !expired {
                                HStack(spacing: 8) {
                                    OrbitRingGauge(progress: remainingFraction(at: context.date), lineWidth: 3, tint: theme.accent)
                                        .frame(width: 18, height: 18)
                                    Text("Code expires in")
                                    Text(expiresAt, style: .timer).monospacedDigit().fontWeight(.bold)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Label("Code expired. Request a new one.", systemImage: "clock.badge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            Button {
                                OrbitHaptics.press()
                                finish()
                            } label: {
                                Label(busy ? "Verifying…" : "Pair this PC", systemImage: "lock.shield")
                            }
                            .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                            .disabled(busy || pin.count != 6 || expired)
                            .opacity(busy || pin.count != 6 || expired ? 0.55 : 1)
                            if expired && !busy {
                                Button("Get a new code") { begin(candidate) }
                                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Text("A six-digit code appears in the Orbit Agent window and a Windows dialog. Nothing needs copying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !busy {
                        Button {
                            OrbitHaptics.tap()
                            begin(candidate)
                        } label: {
                            Label("Request a new code", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                    }
                }
            }

            if busy {
                HStack(spacing: 10) {
                    ProgressView().tint(theme.accent)
                    Text(handshake == nil ? (paired ? "Connecting to your PC…" : "Showing a code on your PC…") : "Verifying and saving your PC…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 24, tint: paired ? .mint : theme.accent, elevated: true)
        .animation(.snappy, value: handshake == nil)
        .animation(.snappy, value: paired)
        .animation(.snappy, value: busy)
    }

    private func remainingFraction(at date: Date) -> Double {
        guard let expiresAt, codeLifetime > 0 else { return 0 }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / codeLifetime))
    }

    private func begin(_ pc: DiscoveredOrbitPC) {
        resetAttempt(); candidate = pc; busy = true
        let identifier = attempt
        task = Task {
            do {
                let connection = try OrbitPairingHandshake(host: pc.host, port: pc.port, fingerprint: pc.fingerprint)
                let seconds = try await connection.begin(name: "Orbit on \(UIDevice.current.model)")
                guard identifier == attempt, !Task.isCancelled else { return }
                handshake = connection; codeLifetime = Double(seconds); expiresAt = Date().addingTimeInterval(Double(seconds)); pinFocused = true
            } catch {
                if identifier == attempt, !Task.isCancelled {
                    self.error = error.localizedDescription
                    OrbitHaptics.error()
                }
            }
            if identifier == attempt { busy = false }
        }
    }
    private func finish() {
        guard let handshake, let candidate, !busy else { return }
        let code = pin, identifier = attempt
        busy = true; error = nil; pinFocused = false
        task = Task {
            do {
                let credentials = try await handshake.finish(pin: code)
                guard identifier == attempt, !Task.isCancelled else { return }
                try vm.acceptPairing(credentials, discoveredHost: candidate.host, bonjourHost: candidate.bonjourHost)
                self.handshake = nil; pin = ""; paired = true
                OrbitHaptics.success()
                await vm.connect()
                guard identifier == attempt, !Task.isCancelled else { return }
                onPaired?(); dismiss()
            } catch {
                if identifier == attempt, !Task.isCancelled {
                    self.error = error.localizedDescription; self.handshake = nil; pin = ""; paired = false
                    OrbitHaptics.error()
                }
            }
            if identifier == attempt { busy = false }
        }
    }
    private func resetAttempt() {
        task?.cancel(); attempt = UUID(); candidate = nil; handshake = nil; pin = ""; expiresAt = nil; busy = false; error = nil; paired = false
    }
}
