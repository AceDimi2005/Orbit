import SwiftUI
import Security

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
}

enum PCProfileStore {
    static func load() -> [SavedPC] {
        guard let data = UserDefaults.standard.data(forKey: "savedPCs.v1"), let profiles = try? JSONDecoder().decode([SavedPC].self, from: data) else { return [] }
        return profiles
    }
    static func save(_ profiles: [SavedPC]) {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "savedPCs.v1") }
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
    }
    static func removeToken(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

@MainActor
extension OrbitViewModel {
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
        PCProfileStore.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: profile.id)
        if let index = savedPCs.firstIndex(where: { $0.id == profile.id }) { savedPCs[index] = profile } else { savedPCs.append(profile) }
        PCProfileStore.save(savedPCs)
        if select { selectPC(profile, persistCurrent: false) }
    }
    func persistSelectedPC() {
        guard let index = savedPCs.firstIndex(where: { $0.id == selectedPCID && $0.address == cleanHost() && $0.agentPort == agentPort }) else { return }
        savedPCs[index].macAddress = pcMAC; savedPCs[index].subnetMask = subnetMask
        savedPCs[index].broadcastAddress = wolTargetIP; savedPCs[index].wolPort = wolPort
        savedPCs[index].autoCalcBroadcast = autoCalcBroadcast
        savedPCs[index].securePort = securePort; savedPCs[index].certificateFingerprint = certificateFingerprint
        PCProfileStore.save(savedPCs)
        PCProfileStore.saveToken(apiToken, for: savedPCs[index].id)
    }
    func saveCurrentConnection() {
        guard isConfigured, !isDemoMode else { return }
        var profile = savedPCs.first(where: { $0.id == selectedPCID }) ?? SavedPC(name: metrics.isOnline ? metrics.hostname : "My PC", address: cleanHost())
        profile.address = cleanHost(); profile.agentPort = agentPort; profile.securePort = securePort
        profile.certificateFingerprint = certificateFingerprint
        profile.macAddress = pcMAC; profile.subnetMask = subnetMask; profile.broadcastAddress = wolTargetIP
        profile.wolPort = wolPort; profile.autoCalcBroadcast = autoCalcBroadcast
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
        resetConnection()
        Task { await connect() }
    }
    func removePC(_ profile: SavedPC) {
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
    var body: some View {
        List {
            Section {
                Text("Save each PC once. Switching keeps its address, token, Wake-on-LAN settings and certificate separate.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Your computers") {
                ForEach(vm.savedPCs) { profile in
                    HStack(spacing: 14) {
                        Button { vm.selectPC(profile) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: profile.id == vm.selectedPCID ? "desktopcomputer.and.arrow.down" : "desktopcomputer").foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.address).font(.caption).foregroundStyle(.secondary)
                                    Label(OrbitAPIClient.validFingerprint(profile.certificateFingerprint) ? "Encrypted connection ready" : "Secure setup needed", systemImage: OrbitAPIClient.validFingerprint(profile.certificateFingerprint) ? "lock.fill" : "lock.open")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if profile.id == vm.selectedPCID { Spacer(); Image(systemName: "checkmark").foregroundStyle(.mint) }
                            }
                        }.buttonStyle(.plain)
                        Button { editing = profile } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(profile.name)")
                    }
                    .swipeActions { Button("Remove", role: .destructive) { removing = profile } }
                }
                Button("Add a PC", systemImage: "plus") { editing = SavedPC(name: "", address: "") }
            }
            Section("Encrypted connection") {
                Text("Orbit Agent 4.0.0 starts HTTPS on port 8766 and prints a certificate fingerprint. Copy that fingerprint from the PC into its saved profile. Files, clipboard, mixer and history use this verified connection.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The existing pairing token is still required. Compare the fingerprint with the PC; a different certificate is rejected before sending your token or files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("My PCs")
        .sheet(item: $editing) { profile in PCProfileEditor(vm: vm, profile: profile) }
        .confirmationDialog("Remove \(removing?.name ?? "this PC")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let profile = removing { Button("Remove saved PC", role: .destructive) { vm.removePC(profile); removing = nil } }
        } message: { Text("This removes its saved connection from this phone. It does not change files on the PC.") }
    }
}

private struct PCProfileEditor: View {
    @ObservedObject var vm: OrbitViewModel
    @State var profile: SavedPC
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss
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
                Section("Encrypted connection") {
                    TextField("Secure port", value: $profile.securePort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Certificate SHA-256 fingerprint", text: $profile.certificateFingerprint, axis: .vertical)
                        .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...5)
                    Text("Copy the certificate fingerprint shown in the Orbit Agent window on this PC. Keep it when updating the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                if !profile.certificateFingerprint.isEmpty && !OrbitAPIClient.validFingerprint(profile.certificateFingerprint) {
                    Text("The fingerprint must contain 64 hexadecimal characters; colons and spaces are accepted.").font(.caption).foregroundStyle(.orange)
                }
            }
            .navigationTitle("PC connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { vm.savePC(profile, token: token); dismiss() }.disabled(!valid) }
            }
            .onAppear { token = PCProfileStore.token(profile.id) }
        }
    }
}
