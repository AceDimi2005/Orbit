import SwiftUI
import Foundation

struct DiscoveredOrbitPC: Identifiable, Equatable {
    var id: String { fingerprint }
    let name: String
    let host: String
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
        guard running, let data = sender.txtRecordData(), let host = sender.hostName else { return }
        let text = NetService.dictionary(fromTXTRecord: data)
        func value(_ key: String) -> String { text[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let fingerprint = OrbitAPIClient.normalizedFingerprint(value("fingerprint"))
        guard OrbitAPIClient.validFingerprint(fingerprint), (1...65535).contains(sender.port),
              value("pairing") == "orbit-srp6a-sha256-2048-v1" else { return }
        // A Bonjour hostname lets the OS select the reachable adapter when a PC
        // also advertises VPN/virtual adapters. No credential is used for discovery.
        resolved[sender.name] = DiscoveredOrbitPC(name: String(value("name").prefix(80)), host: host,
                                                port: sender.port, fingerprint: fingerprint, version: value("version"))
        publish()
    }
    private func publish() {
        computers = Dictionary(resolved.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        message = computers.isEmpty ? "Keep Orbit Agent 4.1.0 open on your PC. Both devices must be on the same local network." : "Choose your PC to show a one-use pairing code on Windows."
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
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var attempt = UUID()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let candidate {
                    Section {
                        Label(candidate.name.isEmpty ? "Your PC" : candidate.name, systemImage: "desktopcomputer")
                            .font(.headline)
                        Text("A six-digit code appears in the Orbit Agent window and a Windows dialog. Enter it here; no tokens or addresses need copying.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if handshake != nil {
                            TextField("Six-digit code", text: $pin)
                                .font(.system(.title, design: .monospaced, weight: .semibold))
                                .keyboardType(.numberPad).textContentType(.oneTimeCode).focused($pinFocused)
                                .onChange(of: pin) { _, value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                                .accessibilityLabel("Pairing code shown on your PC")
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let expired = (expiresAt ?? .distantPast) <= context.date
                                if let expiresAt, !expired {
                                    HStack { Text("Code expires in"); Text(expiresAt, style: .timer).monospacedDigit() }
                                        .font(.caption).foregroundStyle(.secondary)
                                } else { Text("Code expired. Request a new one.").font(.callout).foregroundStyle(.orange) }
                                Button("Pair this PC", systemImage: "lock.shield") { finish() }
                                    .disabled(busy || pin.count != 6 || expired)
                                if expired && !busy { Button("Get a new code") { begin(candidate) } }
                            }
                        }
                        if busy { HStack { ProgressView(); Text(handshake == nil ? "Showing a code on your PC…" : "Verifying and saving your PC…") }.font(.callout) }
                        if !busy && handshake == nil { Button("Request a new code", systemImage: "arrow.clockwise") { begin(candidate) } }
                    } header: { Text("Pair securely") }
                    Section {
                        Button("Choose a different PC") { resetAttempt() }
                    }
                } else {
                    Section {
                        Label("Find your PC", systemImage: "desktopcomputer.and.arrow.down").font(.headline)
                        Text(discovery.message).font(.subheadline).foregroundStyle(.secondary)
                        Text("Keep Orbit Agent 4.1.0 running. Allow Orbit on Windows Private networks if the firewall asks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Nearby computers") {
                        if discovery.computers.isEmpty {
                            HStack(spacing: 12) { ProgressView(); Text("Looking for Orbit PCs…").foregroundStyle(.secondary) }
                        }
                        ForEach(discovery.computers) { pc in
                            Button { begin(pc) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "desktopcomputer").font(.title2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pc.name.isEmpty ? "Orbit PC" : pc.name).foregroundStyle(.primary)
                                        Text("Orbit Agent \(pc.version)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                                }.padding(.vertical, 5)
                            }
                        }
                        Button("Search again", systemImage: "arrow.clockwise") { discovery.stop(); discovery.start() }
                    }
                    Section {
                        Text("Discovery does not share access tokens. The temporary code verifies the connection before your PC's credentials are saved securely.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) } }
            }
            .navigationTitle("Connect a PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop(); task?.cancel(); attempt = UUID(); handshake = nil; pin = "" }
        }
    }

    private func begin(_ pc: DiscoveredOrbitPC) {
        resetAttempt(); candidate = pc; busy = true
        let identifier = attempt
        task = Task {
            do {
                let connection = try OrbitPairingHandshake(host: pc.host, port: pc.port, fingerprint: pc.fingerprint)
                let seconds = try await connection.begin(name: "Orbit on iPhone")
                guard identifier == attempt, !Task.isCancelled else { return }
                handshake = connection; expiresAt = Date().addingTimeInterval(Double(seconds)); pinFocused = true
            } catch { if identifier == attempt, !Task.isCancelled { self.error = error.localizedDescription } }
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
                try vm.acceptPairing(credentials, discoveredHost: candidate.host)
                self.handshake = nil; pin = ""
                await vm.connect()
                guard identifier == attempt, !Task.isCancelled else { return }
                onPaired?(); dismiss()
            } catch {
                if identifier == attempt, !Task.isCancelled { self.error = error.localizedDescription; self.handshake = nil; pin = "" }
            }
            if identifier == attempt { busy = false }
        }
    }
    private func resetAttempt() {
        task?.cancel(); attempt = UUID(); candidate = nil; handshake = nil; pin = ""; expiresAt = nil; busy = false; error = nil
    }
}
