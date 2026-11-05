import SwiftUI
import Foundation
import UIKit

struct DiscoveredOrbitPC: Identifiable, Equatable, Sendable {
    var id: String { fingerprint }
    let name: String
    /// Only routes that answered a read-only, certificate-pinned discovery probe.
    var endpoints: [OrbitDiscoveryEndpoint]
    /// Bonjour hostname kept as a fallback for when the PC's address changes.
    let bonjourHost: String
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
    private var probes: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var checkedConnections = false

    func start() {
        guard !running else { return }
        running = true; computers = []; resolved = [:]; checkedConnections = false
        message = "Searching your local network…"
        browser.delegate = self
        browser.searchForServices(ofType: "_orbit._tcp.", inDomain: "local.")
    }
    func stop() {
        running = false; browser.stop()
        for service in services { service.stop(); service.delegate = nil }
        services = []
        for probe in probes.values { probe.cancel() }
        probes = [:]; generations = [:]
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard running else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        service.stop(); service.delegate = nil
        services.removeAll { $0 == service }
        probes.removeValue(forKey: service.name)?.cancel()
        generations.removeValue(forKey: service.name)
        resolved.removeValue(forKey: service.name)
        publish()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery is unavailable. Allow Local Network access for Orbit in iPhone Settings, then try again. You can also use manual setup."
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard running, services.contains(sender), let data = sender.txtRecordData() else { return }
        let text = NetService.dictionary(fromTXTRecord: data)
        func value(_ key: String) -> String { text[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let fingerprint = OrbitAPIClient.normalizedFingerprint(value("fingerprint"))
        guard OrbitAPIClient.validFingerprint(fingerprint), (1...65535).contains(sender.port),
              value("pairing") == "orbit-srp6a-sha256-2048-v1" else { return }
        let bonjourHost = (sender.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let addresses = OrbitDiscoveryEndpoint.ipv4Addresses(from: sender.addresses ?? [])
        // The hostname can recover from stale address records, but is still probed.
        let hosts = addresses + (bonjourHost.isEmpty ? [] : [bonjourHost])
        let endpoints = OrbitDiscoveryEndpoint.bounded(hosts.map { OrbitDiscoveryEndpoint(host: $0, port: sender.port) })
        guard !endpoints.isEmpty else { return }
        let pc = DiscoveredOrbitPC(name: String(value("name").prefix(80)), endpoints: endpoints, bonjourHost: bonjourHost,
                                   fingerprint: fingerprint, version: value("version"))
        let key = sender.name, generation = UUID()
        probes[key]?.cancel()
        resolved.removeValue(forKey: key)
        generations[key] = generation
        probes[key] = Task {
            do {
                let reachable = try await OrbitDiscoveryRouteSelector().reachable(pc.endpoints) { endpoint in
                    try await Self.probe(endpoint, fingerprint: fingerprint)
                }
                guard running, generations[key] == generation, !Task.isCancelled else { return }
                if !reachable.isEmpty {
                    var verified = pc
                    verified.endpoints = reachable
                    resolved[key] = verified
                }
                checkedConnections = true
                probes.removeValue(forKey: key)
                publish()
            } catch {
                // Cancelled/replaced discoveries must not republish stale routes.
                guard running, generations[key] == generation, !Task.isCancelled else { return }
                checkedConnections = true
                probes.removeValue(forKey: key)
                publish()
            }
        }
        publish()
    }

    nonisolated static func probe(_ endpoint: OrbitDiscoveryEndpoint, fingerprint: String) async throws {
        let transport = try OrbitAPIClient(host: endpoint.host, port: endpoint.port, token: "",
                                           fingerprint: fingerprint, pairingOnly: true, requestTimeout: 2)
        try await transport.probeDiscovery()
    }

    private func publish() {
        computers = Dictionary(resolved.values.map { ($0.id, $0) }, uniquingKeysWith: { first, other in
            var merged = first
            merged.endpoints = OrbitDiscoveryEndpoint.bounded(first.endpoints + other.endpoints)
            return merged
        }).values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !computers.isEmpty {
            message = "Choose your PC to show a one-use pairing code on Windows. Only reachable connections are shown."
        } else if !probes.isEmpty {
            message = "Checking which PC connections are reachable…"
        } else if checkedConnections {
            message = "No advertised address responded with a verified Orbit connection. Check the PC’s network and firewall, then search again or use manual setup."
        } else {
            message = "Keep Orbit Agent open on your PC. Both devices must be on the same local network."
        }
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
    @State private var selectedEndpoint: OrbitDiscoveryEndpoint?
    @State private var checkingConnection = false
    @State private var handshake: OrbitPairingHandshake?
    @State private var pin = ""
    @State private var expiresAt: Date?
    @State private var codeLifetime: Double = 120
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var attempt = UUID()
    @State private var paired = false
    @State private var showsProPaywall = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.orbitTheme) private var theme
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if !vm.canAddNewPC {
                            VStack(alignment: .leading, spacing: 10) {
                                OrbitNotice(title: "One PC in the free version", message: "You can re-pair the PC you already saved. To add another one, remove it in My PCs or unlock Orbit Pro.", icon: "lock.fill", tint: .yellow)
                                Button {
                                    showsProPaywall = true
                                } label: {
                                    Label("Unlock Orbit Pro", systemImage: "crown.fill")
                                }
                                .buttonStyle(OrbitProminentButtonStyle(colors: [Color(red: 1.0, green: 0.86, blue: 0.36), Color(red: 0.96, green: 0.68, blue: 0.22)]))
                            }
                        }
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
                .sheet(isPresented: $showsProPaywall) { OrbitProPaywallView() }
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
                            Text("Orbit Agent \(pc.version) · Automatic connection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(pc.endpoints.map { "\($0.host):\($0.port)" }.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
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
                    Text("Orbit Agent \(candidate.version) · \(selectedEndpoint?.host ?? "Checking connection")")
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
                    Text("Orbit checks the PC’s connection before requesting a six-digit code in the Orbit Agent window and a Windows dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !busy {
                        Button {
                            OrbitHaptics.tap()
                            begin(candidate)
                        } label: {
                            Label("Retry connection", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                    }
                }
            }

            if busy {
                HStack(spacing: 10) {
                    ProgressView().tint(theme.accent)
                    Text(checkingConnection ? "Checking PC connections…" : handshake == nil ? (paired ? "Connecting to your PC…" : "Showing a code on your PC…") : "Verifying and saving your PC…")
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
        resetAttempt(); candidate = pc; busy = true; checkingConnection = true
        let identifier = attempt
        task = Task {
            do {
                let endpoint = try await OrbitDiscoveryRouteSelector().select(pc.endpoints) { endpoint in
                    try await OrbitPCDiscovery.probe(endpoint, fingerprint: pc.fingerprint)
                }
                guard identifier == attempt, !Task.isCancelled else { return }
                selectedEndpoint = endpoint; checkingConnection = false
                // Never race or automatically retry a POST: the agent permits one
                // active session and binds it to this peer for the entire handshake.
                let connection = try OrbitPairingHandshake(host: endpoint.host, port: endpoint.port, fingerprint: pc.fingerprint)
                let seconds: Int
                do { seconds = try await connection.begin(name: "Orbit on \(UIDevice.current.model)") }
                catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                    throw OrbitError(message: "The connection was lost while requesting a code. A code may already be active on your PC. Wait two minutes for it to expire, then retry.")
                }
                guard identifier == attempt, !Task.isCancelled else { return }
                handshake = connection; codeLifetime = Double(seconds); expiresAt = Date().addingTimeInterval(Double(seconds)); pinFocused = true
            } catch {
                if identifier == attempt, !Task.isCancelled {
                    self.error = error.localizedDescription
                    OrbitHaptics.error()
                }
            }
            if identifier == attempt { busy = false; checkingConnection = false }
        }
    }
    private func finish() {
        guard let handshake, let candidate, let selectedEndpoint, !busy else { return }
        let code = pin, identifier = attempt
        busy = true; error = nil; pinFocused = false
        task = Task {
            do {
                let credentials = try await handshake.finish(pin: code)
                guard identifier == attempt, !Task.isCancelled else { return }
                try vm.acceptPairing(credentials, discoveredHost: selectedEndpoint.host, bonjourHost: candidate.bonjourHost)
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
            if identifier == attempt { busy = false; checkingConnection = false }
        }
    }
    private func resetAttempt() {
        task?.cancel(); attempt = UUID(); selectedEndpoint = nil; checkingConnection = false; candidate = nil; handshake = nil; pin = ""; expiresAt = nil; busy = false; error = nil; paired = false
    }
}
