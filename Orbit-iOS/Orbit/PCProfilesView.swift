import SwiftUI
import Security
import Network

struct SavedPC: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var address: String
    var agentPort = 8765
    var securePort = 8766
    var certificateFingerprint = ""
    var macAddress = ""
    var subnetMask = "255.255.255.0"
    var broadcastAddress = ""
    var wolPort = 9
    var autoCalcBroadcast = true
    var lastKnownIPv4: String? = nil
    /// Bonjour `.local` name of the agent, used to find the PC again if its IPv4 changes.
    var bonjourHost: String? = nil
}

struct OrbitSyncedPCItem: Codable {
    var id: String
    var name: String
    var address: String
    var agentPort: Int
    var securePort: Int
    var certificateFingerprint: String
    var macAddress: String
    var subnetMask: String
    var broadcastAddress: String
    var wolPort: Int
    var lastKnownIPv4: String
    var apiToken: String
    var isSelected: Bool
}

final class OrbitAppleTVSyncBroadcaster: @unchecked Sendable {
    static let shared = OrbitAppleTVSyncBroadcaster()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.dimitrie.orbit.tvsync")
    private var latestPayloadData = Data("[]".utf8)

    func publishCurrentProfiles() {
        let profiles = PCProfileStore.load()
        let selectedID = UserDefaults.standard.string(forKey: "selectedPCID") ?? ""
        let items: [OrbitSyncedPCItem] = profiles.map { p in
            OrbitSyncedPCItem(
                id: p.id,
                name: p.name,
                address: p.address,
                agentPort: p.agentPort,
                securePort: p.securePort,
                certificateFingerprint: p.certificateFingerprint,
                macAddress: p.macAddress,
                subnetMask: p.subnetMask,
                broadcastAddress: p.broadcastAddress,
                wolPort: p.wolPort,
                lastKnownIPv4: p.lastKnownIPv4 ?? "",
                apiToken: PCProfileStore.token(p.id),
                isSelected: p.id == selectedID
            )
        }
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        queue.async {
            self.latestPayloadData = encoded
        }
        // 1. iCloud Key-Value Store (syncs across iPhone & Apple TV on same Apple ID)
        NSUbiquitousKeyValueStore.default.set(encoded, forKey: "orbit.syncedPCs.v1")
        NSUbiquitousKeyValueStore.default.synchronize()
        // 2. Shared App Group UserDefaults
        UserDefaults(suiteName: "group.com.dimitrie.orbit")?.set(encoded, forKey: "orbit.syncedPCs.v1")
        // 3. Simulator host bridge for testing iPhone + Apple TV simulators on the same Mac
        #if targetEnvironment(simulator)
        try? encoded.write(to: URL(fileURLWithPath: "/tmp/orbit_synced_pcs.json"), options: .atomic)
        #endif
        startBonjourServerIfNeeded()
    }

    func startBonjourServerIfNeeded() {
        queue.async {
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            guard let nwListener = try? NWListener(using: params) else { return }
            nwListener.service = NWListener.Service(name: "Orbit-iPhone-Sync", type: "_orbit-iphone._tcp")
            nwListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                let data = self.latestPayloadData
                connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            nwListener.start(queue: self.queue)
            self.listener = nwListener
        }
    }
}

enum PCProfileStore {
    static func load() -> [SavedPC] {
        guard let data = UserDefaults.standard.data(forKey: "savedPCs.v1"), let profiles = try? JSONDecoder().decode([SavedPC].self, from: data) else { return [] }
        return profiles
    }
    static func save(_ profiles: [SavedPC]) {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "savedPCs.v1") }
        OrbitAppleTVSyncBroadcaster.shared.publishCurrentProfiles()
    }
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OrbitSavedPC", kSecAttrAccount as String: id]
    }
    static func token(_ id: String) -> String {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func saveToken(_ value: String, for id: String) {
        let query = query(id), data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        OrbitAppleTVSyncBroadcaster.shared.publishCurrentProfiles()
    }
    static func removeToken(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
        OrbitAppleTVSyncBroadcaster.shared.publishCurrentProfiles()
    }
}

@MainActor
extension OrbitViewModel {
    func acceptPairing(_ credentials: PCPairingCredentials, discoveredHost: String, bonjourHost: String = "") throws {
        let fingerprint = OrbitAPIClient.normalizedFingerprint(credentials.certificateFingerprint)
        guard OrbitAPIClient.validFingerprint(fingerprint), !discoveredHost.isEmpty else { throw OrbitError(message: "Invalid PC pairing response.") }
        // Store the plain IPv4 address. The agent reports the adapter address the phone
        // actually connected through, which beats a `.local` name for Wake-on-LAN and VPNs.
        let address = IPv4Address(discoveredHost) != nil ? discoveredHost : (IPv4Address(credentials.ipAddress) != nil ? credentials.ipAddress : discoveredHost)
        var profile = savedPCs.first(where: { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == fingerprint }) ?? SavedPC(name: credentials.hostname, address: address)
        profile.name = credentials.hostname; profile.address = address
        let fallbackName = bonjourHost.isEmpty ? (discoveredHost.hasSuffix(".local") ? discoveredHost : "") : bonjourHost
        if !fallbackName.isEmpty { profile.bonjourHost = fallbackName }
        profile.agentPort = credentials.agentPort; profile.securePort = credentials.securePort
        profile.certificateFingerprint = fingerprint; profile.macAddress = credentials.macAddress
        profile.subnetMask = credentials.subnetMask; profile.broadcastAddress = credentials.broadcastAddress
        profile.lastKnownIPv4 = credentials.ipAddress
        profile.autoCalcBroadcast = true
        savePC(profile, token: credentials.apiToken)
        widgetToken = credentials.widgetToken
        do {
            try OrbitWidgetConnectionStore.save(
                id: profile.id,
                name: profile.name,
                host: profile.address,
                port: profile.securePort,
                readOnlyToken: credentials.widgetToken,
                certificateSHA256: fingerprint,
                controlToken: credentials.apiToken,
                macAddress: profile.macAddress,
                broadcastAddress: profile.broadcastAddress,
                subnetMask: profile.subnetMask,
                wolPort: profile.wolPort,
                lastKnownIPv4: profile.lastKnownIPv4
            )
            try OrbitWidgetConnectionStore.setDefault(id: profile.id)
        } catch { widgetSetupError = error.localizedDescription }
    }
    var selectedPCStorageKey: String {
        if let profile = savedPCs.first(where: { $0.id == selectedPCID && $0.address == cleanHost() && $0.agentPort == agentPort }) { return profile.id }
        return "\(cleanHost().lowercased()):\(agentPort)"
    }
    var selectedPCName: String { savedPCs.first(where: { $0.id == selectedPCID })?.name ?? metrics.hostname }
    var hasSecureConnection: Bool { OrbitAPIClient.validFingerprint(certificateFingerprint) }
    func companionClient() throws -> OrbitAPIClient {
        guard !isDemoMode else { throw OrbitError(message: "Connect a real PC to use Files, clipboard, mixer and session history.") }
        return try OrbitAPIClient(host: cleanHost(), port: securePort, token: apiToken, fingerprint: certificateFingerprint)
    }
    func savePC(_ profile: SavedPC, token: String, select: Bool = true) {
        if select { persistSelectedPC() }
        var profile = profile
        profile.address = profile.address.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(profile.certificateFingerprint)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        PCProfileStore.saveToken(cleanToken, for: profile.id)
        if let index = savedPCs.firstIndex(where: { $0.id == profile.id }) { savedPCs[index] = profile } else { savedPCs.append(profile) }
        PCProfileStore.save(savedPCs)
        OrbitWidgetConnectionStore.syncPowerProfile(
            id: profile.id,
            name: profile.name,
            host: profile.address,
            port: profile.securePort,
            certificateSHA256: profile.certificateFingerprint,
            controlToken: cleanToken,
            macAddress: profile.macAddress,
            broadcastAddress: profile.broadcastAddress,
            subnetMask: profile.subnetMask,
            wolPort: profile.wolPort,
            lastKnownIPv4: profile.lastKnownIPv4
        )
        if select { selectPC(profile, persistCurrent: false) }
        OrbitWatchBridge.shared.pushStateToWatch(force: true)
    }
    func persistSelectedPC() {
        guard let index = savedPCs.firstIndex(where: { $0.id == selectedPCID && $0.address == cleanHost() && $0.agentPort == agentPort }) else { return }
        savedPCs[index].macAddress = pcMAC; savedPCs[index].subnetMask = subnetMask
        savedPCs[index].broadcastAddress = wolTargetIP; savedPCs[index].wolPort = wolPort
        savedPCs[index].autoCalcBroadcast = autoCalcBroadcast
        savedPCs[index].lastKnownIPv4 = lastKnownPCIPv4
        savedPCs[index].securePort = securePort; savedPCs[index].certificateFingerprint = certificateFingerprint
        PCProfileStore.save(savedPCs)
        PCProfileStore.saveToken(apiToken, for: savedPCs[index].id)
        let p = savedPCs[index]
        OrbitWidgetConnectionStore.syncPowerProfile(
            id: p.id,
            name: p.name,
            host: p.address,
            port: p.securePort,
            certificateSHA256: p.certificateFingerprint,
            controlToken: apiToken,
            macAddress: p.macAddress,
            broadcastAddress: p.broadcastAddress,
            subnetMask: p.subnetMask,
            wolPort: p.wolPort,
            lastKnownIPv4: p.lastKnownIPv4
        )
    }
    func saveCurrentConnection() {
        guard isConfigured, !isDemoMode else { return }
        var profile = savedPCs.first(where: { $0.id == selectedPCID }) ?? SavedPC(name: metrics.isOnline ? metrics.hostname : "My PC", address: cleanHost())
        profile.address = cleanHost(); profile.agentPort = agentPort; profile.securePort = securePort
        profile.certificateFingerprint = certificateFingerprint
        profile.macAddress = pcMAC; profile.subnetMask = subnetMask; profile.broadcastAddress = wolTargetIP
        profile.wolPort = wolPort; profile.autoCalcBroadcast = autoCalcBroadcast
        profile.lastKnownIPv4 = lastKnownPCIPv4
        savePC(profile, token: apiToken, select: false)
        selectedPCID = profile.id; UserDefaults.standard.set(profile.id, forKey: "selectedPCID")
    }
    func selectPC(_ profile: SavedPC, persistCurrent: Bool = true) {
        if persistCurrent { persistSelectedPC() }
        isDemoMode = false
        selectedPCID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "selectedPCID")
        pcIP = profile.address; agentPort = profile.agentPort
        apiToken = PCProfileStore.token(profile.id)
        securePort = profile.securePort; certificateFingerprint = profile.certificateFingerprint
        pcMAC = profile.macAddress; subnetMask = profile.subnetMask
        wolTargetIP = profile.broadcastAddress; wolPort = profile.wolPort; autoCalcBroadcast = profile.autoCalcBroadcast
        lastKnownPCIPv4 = profile.lastKnownIPv4 ?? ""
        resetConnection()
        OrbitWatchBridge.shared.pushStateToWatch(force: true)
        try? OrbitWidgetConnectionStore.setDefault(id: profile.id)
        Task { await connect() }
    }
    func removePC(_ profile: SavedPC) {
        try? OrbitWidgetConnectionStore.remove(id: profile.id)
        PCProfileStore.removeToken(profile.id)
        savedPCs.removeAll { $0.id == profile.id }; PCProfileStore.save(savedPCs)
        if selectedPCID == profile.id {
            selectedPCID = ""; UserDefaults.standard.removeObject(forKey: "selectedPCID")
            pcIP = ""; apiToken = ""; certificateFingerprint = ""; pcMAC = ""; wolTargetIP = ""
            if let next = savedPCs.first { selectPC(next) }
        }
    }
}

struct PCProfilesView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var editing: SavedPC?
    @State private var removing: SavedPC?
    @State private var showsDiscovery = false
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: "desktopcomputer.and.arrow.down", tint: theme.accent, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(vm.savedPCs.count) saved PC\(vm.savedPCs.count == 1 ? "" : "s")")
                            .font(.headline.weight(.bold))
                        Text("Each PC keeps its own address, token, certificate and Wake-on-LAN settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                Button {
                    OrbitHaptics.tap()
                    showsDiscovery = true
                } label: {
                    Label("Find a PC nearby", systemImage: "dot.radiowaves.left.and.right")
                        .fontWeight(.semibold)
                }
                Button {
                    editing = SavedPC(name: "", address: "")
                } label: {
                    Label("Add manually", systemImage: "plus")
                }
            }
            .orbitRow(tint: theme.accent)

            Section("Your computers") {
                if vm.savedPCs.isEmpty {
                    OrbitEmptyState(icon: "desktopcomputer", title: "No saved PCs", message: "Pair a PC with the 6-digit code shown by Orbit Agent, or add one manually.", tint: theme.accent)
                }
                ForEach(vm.savedPCs) { profile in
                    profileRow(profile)
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = profile }
                            Button("Edit", systemImage: "pencil") { editing = profile }
                                .tint(theme.accent)
                        }
                }
            }
            .orbitRow()

            Section {
                Text("Orbit Agent appears automatically on your local network. Select it and enter the temporary code shown on your PC; addresses, tokens, the certificate and Wake-on-LAN details are filled in automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("A different certificate is rejected before any token or file is sent, so compare the fingerprint with the PC if you ever set one up by hand.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Encrypted connection")
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("My PCs")
        .sheet(item: $editing) { profile in PCProfileEditor(vm: vm, profile: profile) }
        .sheet(isPresented: $showsDiscovery) { PCDiscoveryView(vm: vm) }
        .confirmationDialog("Remove \(removing?.name ?? "this PC")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let profile = removing { Button("Remove saved PC", role: .destructive) { vm.removePC(profile); removing = nil } }
        } message: { Text("This removes its saved connection from this phone. It does not change files on the PC.") }
    }

    private func profileRow(_ profile: SavedPC) -> some View {
        let selected = profile.id == vm.selectedPCID
        let secure = OrbitAPIClient.validFingerprint(profile.certificateFingerprint)
        let online = selected && vm.metrics.isOnline && !vm.isDemoMode
        return HStack(spacing: 12) {
            Button {
                OrbitHaptics.selection()
                vm.selectPC(profile)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        OrbitRingGauge(progress: online && vm.metrics.telemetryAvailable != false ? vm.metrics.cpuUsage / 100 : nil, lineWidth: 3, tint: selected ? theme.accent : .secondary)
                            .frame(width: 42, height: 42)
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? theme.accent : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(profile.name).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            if selected {
                                OrbitStatusPill(text: online ? "Online" : "Selected", tint: online ? .mint : theme.accent, pulsing: online)
                            }
                        }
                        Text(profile.address + (profile.lastKnownIPv4.map { $0.isEmpty || $0 == profile.address ? "" : " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 8) {
                            Label(secure ? "TLS pinned" : "Secure setup needed", systemImage: secure ? "lock.fill" : "lock.open")
                                .foregroundStyle(secure ? Color.mint : Color.orange)
                            if !profile.macAddress.isEmpty {
                                Label("Wake-on-LAN", systemImage: "power").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2.weight(.medium))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { editing = profile } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(profile.name)")
        }
        .padding(.vertical, 4)
    }
}

private struct PCProfileEditor: View {
    @ObservedObject var vm: OrbitViewModel
    @State var profile: SavedPC
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.orbitTheme) private var theme
    private var valid: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !profile.address.isEmpty && !profile.address.contains("/") && !profile.address.contains(":") &&
        (1...65535).contains(profile.agentPort) && (1...65535).contains(profile.securePort) && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (profile.certificateFingerprint.isEmpty || OrbitAPIClient.validFingerprint(profile.certificateFingerprint))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Name, for example Gaming PC", text: $profile.name)
                    TextField("PC address", text: $profile.address).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Pairing token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .orbitRow()
                Section("Encrypted connection") {
                    TextField("Secure port", value: $profile.securePort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Certificate SHA-256 fingerprint", text: $profile.certificateFingerprint, axis: .vertical)
                        .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...5)
                    Text("Copy the certificate fingerprint shown in the Orbit Agent window on this PC. Keep it when updating the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .orbitRow()
                Section {
                    DisclosureGroup("Wake-on-LAN and legacy settings") {
                        TextField("Legacy agent port", value: $profile.agentPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                        TextField("MAC address", text: $profile.macAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Subnet mask", text: $profile.subnetMask).keyboardType(.decimalPad)
                        TextField("Broadcast address", text: $profile.broadcastAddress).keyboardType(.decimalPad)
                        TextField("Wake port", value: $profile.wolPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                        Toggle("Calculate broadcast automatically", isOn: $profile.autoCalcBroadcast)
                    }
                }
                .orbitRow()
                if !profile.certificateFingerprint.isEmpty && !OrbitAPIClient.validFingerprint(profile.certificateFingerprint) {
                    Text("The fingerprint must contain 64 hexadecimal characters; colons and spaces are accepted.").font(.caption).foregroundStyle(.orange)
                        .orbitRow()
                }
            }
            .orbitListChrome()
            .navigationTitle("PC connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { OrbitHaptics.success(); vm.savePC(profile, token: token); dismiss() }.disabled(!valid).fontWeight(.semibold) }
            }
            .onAppear { token = PCProfileStore.token(profile.id) }
        }
        .orbitAppearance()
    }
}
