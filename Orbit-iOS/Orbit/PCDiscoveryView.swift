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
    @Published private(set) var message = "Keep Orbit Companion open on the PC, on the same network as this iPhone."
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredOrbitPC] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true; computers = []; resolved = [:]
        message = "Keep Orbit Companion open on the PC, on the same network as this iPhone."
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
        message = "Orbit can't search your network. Allow Local Network for Orbit in the iPhone's Settings, then try again."
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
        message = computers.isEmpty ? "Keep Orbit Companion open on the PC, on the same network as this iPhone." : "Choose your PC. It shows a code to type here."
    }
}

/// Six code cells over a hidden text field, so the system keyboard, one-time-code
/// autofill and VoiceOver keep working.
private struct OrbitPINField: View {
    @Binding var pin: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            TextField("Six-digit code", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(isFocused)
                .opacity(0.02)
                .frame(height: 1)
                .accessibilityLabel("Code shown on your PC")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digits = Array(pin)
                    let digit = index < digits.count ? String(digits[index]) : ""
                    let active = isFocused.wrappedValue && index == min(pin.count, 5)
                    Text(digit)
                        .font(.orbitReading(30))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(OrbitPalette.well, in: RoundedRectangle(cornerRadius: OrbitMetrics.controlRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OrbitMetrics.controlRadius, style: .continuous)
                                .strokeBorder(.tint, lineWidth: 2)
                                .opacity(active ? 1 : 0)
                        }
                        .contentTransition(.numericText())
                        .animation(OrbitMotion.quick, value: pin)
                        .animation(OrbitMotion.quick, value: active)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused.wrappedValue = true }
            .accessibilityHidden(true)
        }
    }
}

/// Adding a PC: Orbit finds Orbit Companion on the network, the PC shows a six-digit code,
/// and the code proves both sides before the connection is saved.
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
    @State private var showsProPaywall = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pinFocused: Bool

    private let companionURL = URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!

    var body: some View {
        NavigationStack {
            OrbitPage(spacing: 26) {
                if let candidate {
                    pairing(candidate)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    searching
                        .transition(.opacity)
                }
                if let error {
                    OrbitInlineStatus(text: error, kind: .problem)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
                Text("The code proves it's your PC. Orbit then keeps the connection in this iPhone's Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .animation(OrbitMotion.standard, value: candidate)
            .animation(OrbitMotion.standard, value: error)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(candidate == nil ? "Add a PC" : "Pair")
            .navigationBarTitleDisplayMode(.inline)
            .orbitCloseButton { dismiss() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { pinFocused = false }
                }
            }
            .sheet(isPresented: $showsProPaywall) { OrbitProPaywallView() }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop(); task?.cancel(); attempt = UUID(); handshake = nil; pin = "" }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }

    // MARK: Searching

    @ViewBuilder
    private var searching: some View {
        VStack(spacing: 12) {
            OrbitMark(status: discovery.computers.isEmpty ? .working : .online, size: 64)
                .padding(.top, 12)
                .padding(.bottom, 6)
            Text(foundTitle)
                .font(.title2.weight(.bold))
                .contentTransition(.opacity)
            Text(discovery.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)

        OrbitGroup("On This Network", trailing: {
            Button("Search Again") {
                OrbitHaptics.tap()
                discovery.stop()
                discovery.start()
            }
        }) {
            if discovery.computers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .padding(.vertical, 12)
            }
            ForEach(discovery.computers) { pc in
                let allowed = vm.canAddNewPC || isSaved(pc)
                Button {
                    if allowed {
                        OrbitHaptics.press()
                        begin(pc)
                    } else {
                        showsProPaywall = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pc.name.isEmpty ? "Windows PC" : pc.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(pc.version.isEmpty ? pc.host : "\(pc.host) · Orbit Companion \(pc.version)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if allowed {
                            Text("Pair")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        } else {
                            Image(systemName: "lock")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(allowed ? "Pair with \(pc.name.isEmpty ? "Windows PC" : pc.name)" : "\(pc.name), needs Orbit Pro")
            }
        }
        .animation(OrbitMotion.standard, value: discovery.computers)

        if !vm.canAddNewPC {
            VStack(alignment: .leading, spacing: 6) {
                Text("Orbit keeps one PC. You can pair yours again; to add another, remove it in Manage PCs or unlock Orbit Pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Unlock Orbit Pro") { showsProPaywall = true }
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 4)
            .padding(.top, -14)
        }

        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Get Orbit Companion")
            VStack(alignment: .leading, spacing: 14) {
                Text("Install it on the Windows PC and keep it running in the system tray. Allow it on private networks if Windows asks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(item: companionURL,
                          subject: Text("Orbit Companion for Windows"),
                          message: Text("Orbit Companion for Windows: unzip it and run install_orbit.bat.")) {
                    Label("Send the Download to Your PC", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                    Label("Open on GitHub", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .orbitSurface()
        }
    }

    /// A PC already saved here, which can always be paired again.
    private func isSaved(_ pc: DiscoveredOrbitPC) -> Bool {
        vm.savedPCs.contains { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == pc.fingerprint }
    }

    private var foundTitle: String {
        switch discovery.computers.count {
        case 0: return "Looking for your PC"
        case 1: return "Found your PC"
        default: return "Found \(discovery.computers.count) PCs"
        }
    }

    // MARK: Pairing

    private func pairing(_ candidate: DiscoveredOrbitPC) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                OrbitMark(status: paired ? .online : (busy ? .working : .online), size: 46)
                    .padding(2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name.isEmpty ? "Your PC" : candidate.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(candidate.host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !paired && !busy {
                    Button("Change") { resetAttempt() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.top, 8)

            if paired {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paired")
                        .font(.title2.weight(.bold))
                    Text("Connecting to \(candidate.name.isEmpty ? "your PC" : candidate.name)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if handshake != nil {
                codeEntry(candidate)
            } else if busy {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Showing a code on your PC…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your PC shows a six-digit code in Orbit Companion. Ask for a new one if it closed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        OrbitHaptics.tap()
                        begin(candidate)
                    } label: {
                        Text("Show a New Code")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .orbitGlassButton(prominent: true)
                }
            }
        }
        .animation(OrbitMotion.standard, value: handshake == nil)
        .animation(OrbitMotion.standard, value: paired)
        .animation(OrbitMotion.standard, value: busy)
    }

    private func codeEntry(_ candidate: DiscoveredOrbitPC) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type the code your PC shows")
                    .font(.headline)
                Text("It's in the Orbit Companion window on Windows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            OrbitPINField(pin: $pin, isFocused: $pinFocused)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if pin.count == 6 { OrbitHaptics.selection() }
                }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = (expiresAt ?? .distantPast) <= context.date
                VStack(alignment: .leading, spacing: 14) {
                    if let expiresAt, !expired {
                        Text("The code works for \(expiresAt, style: .timer) more.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("The code expired. Ask your PC for a new one.")
                            .font(.footnote)
                            .foregroundStyle(OrbitPalette.warm)
                    }
                    Button {
                        OrbitHaptics.press()
                        finish()
                    } label: {
                        Text(busy ? "Checking…" : "Pair")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .orbitGlassButton(prominent: true)
                    .disabled(busy || pin.count != 6 || expired)
                    if expired && !busy {
                        Button("Show a New Code") { begin(candidate) }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Pairing steps

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
