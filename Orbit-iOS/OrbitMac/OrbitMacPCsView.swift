import AppKit
import SwiftUI

// MARK: - Page

/// My PCs: saved profiles, Bonjour discovery, PIN pairing, manual addresses,
/// iPhone import and demo mode. Pairing tokens stay in the Keychain; the page
/// only ever shows fields that `MacSavedPC` actually stores.
struct MacPCsView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @State private var manualHost = ""
    @State private var manualPort = "\(MacPcsFormat.defaultDiscoveryPort)"
    @State private var showsRename = false
    @State private var renameTarget: MacSavedPC?
    @State private var renameDraft = ""
    @State private var showsForget = false
    @State private var forgetTarget: MacSavedPC?
    @State private var lastPairingTarget: MacDiscoveredPC?
    @State private var showsProPaywall = false

    private var cardColumns: [GridItem] { [GridItem(.adaptive(minimum: 360, maximum: 620), spacing: 12, alignment: .top)] }

    /// The sheet stays up through the success state: `finishPairing` clears
    /// `pairingTarget` but sets `justPaired`; closing calls `cancelPairing()`,
    /// which only resets pairing state and leaves the saved PC in place.
    private var pairingPresented: Binding<Bool> {
        Binding(get: { vm.pairingTarget != nil || vm.justPaired }, set: { if !$0 { vm.cancelPairing() } })
    }

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 22) {
                if vm.isDemoMode { demoBanner }
                if !vm.canAddNewPC { proLimitBanner }
                savedSection
                nearbySection
                manualSection
                iPhoneSection
                demoSection
            }
        }
        .onAppear {
            vm.startDiscovery()
            if let target = vm.pairingTarget { lastPairingTarget = target }
        }
        .onDisappear { vm.stopDiscovery() }
        .onChange(of: vm.selectedPCID) { _, _ in vm.startDiscovery() }
        .onChange(of: vm.pairingTarget) { _, target in if let target { lastPairingTarget = target } }
        .sheet(isPresented: pairingPresented) {
            MacPcsPairingSheet(target: lastPairingTarget).environmentObject(vm)
        }
        .alert("Rename PC", isPresented: $showsRename, presenting: renameTarget) { pc in
            TextField("Name", text: $renameDraft)
            Button("Save") { commitRename(pc) }
            Button("Cancel", role: .cancel) { }
        } message: { pc in
            Text("Choose how “\(pc.name)” appears on this Mac. The PC itself is not renamed.")
        }
        .confirmationDialog("Forget this PC?", isPresented: $showsForget, titleVisibility: .visible, presenting: forgetTarget) { pc in
            Button("Forget \(pc.name)", role: .destructive) { vm.removePC(pc) }
            Button("Cancel", role: .cancel) { }
        } message: { pc in
            Text("Removes \(pc.name) and its pairing token from this Mac. Pair again or import from your iPhone to restore it.")
        }
    }

    // MARK: Orbit Pro limit

    private var proLimitBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.yellow)
            Text("The free version keeps one PC. You can re-pair it any time; Orbit Pro saves as many PCs as you like.")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Orbit Pro…") { showsProPaywall = true }
                .buttonStyle(MacHoverButtonStyle(tint: .yellow))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .yellow)
        .sheet(isPresented: $showsProPaywall) { OrbitProUnlockView(accent: theme.accent) { showsProPaywall = false } }
    }

    // MARK: Demo banner

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo mode · simulated data. Connect to a saved PC or switch demo off below to go live.")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Leave Demo Mode") { vm.setDemoMode(false) }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .orange)
    }

    // MARK: Your PCs

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Your PCs",
                             subtitle: vm.savedPCs.isEmpty ? "Nothing is paired on this Mac yet" : "Select a PC to connect. Pairing tokens stay in your Keychain.",
                             icon: "desktopcomputer") {
                if !vm.savedPCs.isEmpty { MacStatChip(label: "Saved", value: "\(vm.savedPCs.count)") }
            }
            if vm.savedPCs.isEmpty {
                MacEmptyState(icon: "desktopcomputer",
                              title: "No PCs paired yet",
                              message: "Pair a nearby PC, enter its address manually, or import the one you already paired on your iPhone. Everything you need is below.",
                              tint: theme.accent,
                              actionTitle: "Import from iPhone",
                              action: { Task { await vm.syncFromiPhone(silent: false) } })
                    .macGlass(cornerRadius: 18)
            } else {
                if let notice = connectionNotice { notice }
                LazyVGrid(columns: cardColumns, spacing: 12) {
                    ForEach(vm.savedPCs) { pc in
                        MacPcsSavedCard(pc: pc,
                                        onRename: { beginRename(pc) },
                                        onForget: { forgetTarget = pc; showsForget = true })
                    }
                }
            }
        }
    }

    /// Offline / connecting banner for the selected PC. Demo mode has no real link to report on.
    private var connectionNotice: MacNotice? {
        guard let pc = vm.currentPC, !vm.isDemoMode, !vm.metrics.isOnline else { return nil }
        if vm.isWaking {
            return MacNotice(title: "Waking \(pc.name)…", message: vm.statusBanner, icon: "power", tint: .orange)
        }
        if let error = vm.connectionError {
            return MacNotice(title: "\(pc.name) is offline", message: error, icon: "wifi.exclamationmark", tint: .orange)
        }
        return MacNotice(title: "Connecting to \(pc.name)…", message: "Orbit retries every few seconds. If the PC is asleep, use Wake Now in its Wake-on-LAN settings.", icon: "antenna.radiowaves.left.and.right", tint: theme.accent)
    }

    private func beginRename(_ pc: MacSavedPC) {
        renameTarget = pc
        renameDraft = pc.name
        showsRename = true
    }

    private func commitRename(_ pc: MacSavedPC) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var updated = vm.savedPCs.first(where: { $0.id == pc.id }) else { return }
        updated.name = name
        vm.savePC(updated, token: nil, select: false)
    }

    // MARK: Nearby

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Nearby", subtitle: "PCs running Orbit Agent on this network (Bonjour)", icon: "dot.radiowaves.left.and.right") {
                if vm.isScanning { MacStatusPill(text: "Scanning", tint: theme.accent, pulsing: true) }
                Button { rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MacIconButtonStyle(size: 26))
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Rescan (⇧⌘R)")
                    .accessibilityLabel("Rescan for nearby PCs")
            }
            VStack(spacing: 8) {
                if vm.discoveredPCs.isEmpty {
                    nearbyEmpty
                } else {
                    ForEach(vm.discoveredPCs) { pc in
                        MacPcsDiscoveredRow(pc: pc, saved: savedMatch(for: pc))
                    }
                }
                if let error = vm.pairingError, vm.pairingTarget == nil, !vm.justPaired {
                    pairingErrorNotice(error)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private var nearbyEmpty: some View {
        HStack(spacing: 12) {
            if vm.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.isScanning ? "Listening for Orbit Agent…" : "Discovery is paused")
                    .font(.subheadline.weight(.semibold))
                Text("Start Orbit Agent on the PC and keep both devices on the same network. Allow Local Network access for Orbit if macOS asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func pairingErrorNotice(_ error: String) -> some View {
        HStack(spacing: 10) {
            MacNotice(title: "Pairing problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
            Button { vm.cancelPairing() } label: { Image(systemName: "xmark") }
                .buttonStyle(MacIconButtonStyle(size: 26))
                .help("Dismiss")
                .accessibilityLabel("Dismiss pairing error")
        }
    }

    private func savedMatch(for pc: MacDiscoveredPC) -> MacSavedPC? {
        let fingerprint = OrbitAPIClient.normalizedFingerprint(pc.fingerprint)
        guard !fingerprint.isEmpty else { return nil }
        return vm.savedPCs.first { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == fingerprint }
    }

    private func rescan() {
        vm.discoveredPCs = []
        vm.startDiscovery()
    }

    // MARK: Manual

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("By Address", subtitle: "Pair by address when Bonjour is blocked (VLANs, guest Wi-Fi, firewalls)", icon: "number")
            HStack(alignment: .bottom, spacing: 10) {
                MacPcsField(title: "Host or IPv4", placeholder: "192.168.1.50", text: $manualHost, monospaced: true, submit: { probeManual() })
                MacPcsField(title: "Discovery port", placeholder: "\(MacPcsFormat.defaultDiscoveryPort)", text: $manualPort, monospaced: true, width: 130, submit: { probeManual() })
                Button { probeManual() } label: {
                    HStack(spacing: 6) {
                        if vm.isProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(vm.isProbing ? "Finding…" : "Find")
                    }
                }
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                .disabled(vm.isProbing || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Ask the agent at this address for its certificate fingerprint")
            }
            Text("Orbit asks the agent's public discovery endpoint (default port \(MacPcsFormat.defaultDiscoveryPort)) for its certificate fingerprint, then opens the PIN sheet. Found PCs also appear under Nearby.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func probeManual() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !vm.isProbing else { return }
        var port = MacPcsFormat.defaultDiscoveryPort
        if let parsed = Int(manualPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(parsed) { port = parsed }
        Task { await vm.probeManualHost(host, discoveryPort: port) }
    }

    // MARK: From iPhone

    private var iPhoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("From iPhone", subtitle: "Reuse the PC you already paired in Orbit for iOS", icon: "iphone")
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    iPhoneHint("icloud", "Same Apple Account", "Sign in to iCloud on both devices; the pairing syncs through iCloud Key-Value Storage.")
                    iPhoneHint("wifi", "Same Wi-Fi", "Or open Orbit on your iPhone on this network; the Mac finds it over Bonjour and copies the pairing.")
                }
                Spacer(minLength: 8)
                Button { Task { await vm.syncFromiPhone(silent: false) } } label: {
                    HStack(spacing: 6) {
                        if vm.isSyncingFromiPhone {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(vm.isSyncingFromiPhone ? "Looking…" : "Import from iPhone")
                    }
                }
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                .disabled(vm.isSyncingFromiPhone)
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Import paired PCs from your iPhone (⇧⌘I)")
            }
            if let message = vm.iPhoneSyncMessage {
                MacNotice(title: syncNoticeTitle(message), message: message, icon: syncNoticeIcon(message), tint: syncNoticeTint(message))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func iPhoneHint(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MacIconBadge(systemName: icon, tint: theme.accent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func syncNoticeTitle(_ message: String) -> String {
        if message.hasPrefix("Imported") { return "Import complete" }
        if message.hasPrefix("No iPhone") { return "No iPhone found" }
        return "Looking for your iPhone"
    }
    private func syncNoticeIcon(_ message: String) -> String {
        if message.hasPrefix("Imported") { return "checkmark.circle.fill" }
        if message.hasPrefix("No iPhone") { return "exclamationmark.triangle.fill" }
        return "antenna.radiowaves.left.and.right"
    }
    private func syncNoticeTint(_ message: String) -> Color {
        if message.hasPrefix("Imported") { return .mint }
        if message.hasPrefix("No iPhone") { return .orange }
        return theme.accent
    }

    // MARK: Demo

    private var demoSection: some View {
        HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: "sparkles", tint: .orange, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Demo Mode").font(.system(.headline, weight: .bold))
                Text("Explore every section with simulated readings. Nothing is sent to a PC and your saved PCs stay untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) })) { Text("Demo Mode") }
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Demo Mode")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: vm.isDemoMode ? .orange : .white)
    }
}

// MARK: - Saved PC card

private struct MacPcsSavedCard: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    let pc: MacSavedPC
    var onRename: () -> Void
    var onForget: () -> Void
    @State private var macDraft = ""
    @State private var broadcastDraft = ""
    @State private var wolPortDraft = ""
    @State private var wolRelayDraft = ""
    @State private var wolExpanded = false
    @State private var hovered = false

    private var isSelected: Bool { vm.currentPC?.id == pc.id }
    private var isLive: Bool { isSelected && !vm.isDemoMode && vm.metrics.isOnline }

    private var status: (text: String, tint: Color, pulsing: Bool)? {
        guard isSelected else { return nil }
        if vm.isDemoMode { return (text: "Demo", tint: Color.orange, pulsing: false) }
        if vm.isWaking { return (text: "Waking…", tint: Color.orange, pulsing: true) }
        if vm.metrics.isOnline { return (text: "Online", tint: Color.mint, pulsing: true) }
        if vm.connectionError == nil { return (text: "Connecting…", tint: theme.accent, pulsing: true) }
        return (text: "Offline", tint: Color.orange, pulsing: false)
    }

    private var connectTitle: String {
        guard isSelected, !vm.isDemoMode else { return "Connect" }
        return vm.metrics.isOnline ? "Connected" : "Reconnect"
    }

    private var macDigits: String { macDraft.filter { !":-. ".contains($0) } }
    private var macValid: Bool { macDigits.isEmpty || (macDigits.count == 12 && macDigits.allSatisfy { $0.isASCII && $0.isHexDigit }) }
    private var portValid: Bool {
        guard let port = Int(wolPortDraft.trimmingCharacters(in: .whitespaces)) else { return false }
        return (1...65535).contains(port)
    }
    private var wakeDirty: Bool {
        macDraft.trimmingCharacters(in: .whitespacesAndNewlines) != pc.macAddress
            || broadcastDraft.trimmingCharacters(in: .whitespacesAndNewlines) != pc.broadcastAddress
            || wolPortDraft.trimmingCharacters(in: .whitespaces) != "\(pc.wolPort)"
            || wolRelayDraft.trimmingCharacters(in: .whitespacesAndNewlines) != pc.wolRelay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chips
            fingerprintRow
            wakeOnLan
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: isSelected ? theme.accent : .white, elevated: isSelected, hovered: hovered)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .onHover { hovered = $0 }
        .macHoverLift()
        .onAppear { loadDrafts() }
        .onChange(of: pc) { _, _ in if !wolExpanded { loadDrafts() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MacIconBadge(systemName: "desktopcomputer", tint: isSelected ? theme.accent : Color.secondary, size: 40, filled: isSelected)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pc.name.isEmpty ? "Unnamed PC" : pc.name)
                        .font(.system(.headline, weight: .bold))
                        .lineLimit(1)
                    Button { onRename() } label: { Image(systemName: "pencil") }
                        .buttonStyle(MacIconButtonStyle(size: 22))
                        .help("Rename")
                        .accessibilityLabel("Rename \(pc.name)")
                    Spacer(minLength: 4)
                    if let status {
                        MacStatusPill(text: status.text, tint: status.tint, pulsing: status.pulsing)
                    }
                }
                Text("\(pc.address):\(pc.securePort)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    MacStatusPill(text: pc.isSecure ? "Encrypted" : "Legacy", tint: pc.isSecure ? Color.mint : Color.orange, icon: pc.isSecure ? "lock.fill" : "lock.open")
                    MacStatChip(label: "Agent port", value: "\(pc.agentPort)")
                    if isLive { MacStatChip(label: "Ping", value: "\(vm.pingMs) ms") }
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            MacStatChip(label: "IPv4", value: pc.lastKnownIPv4.isEmpty ? "—" : pc.lastKnownIPv4, icon: "network")
            MacStatChip(label: "MAC", value: pc.macAddress.isEmpty ? "—" : pc.macAddress, icon: "wave.3.right")
        }
    }

    private var fingerprintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: pc.isSecure ? "checkmark.shield.fill" : "shield.slash")
                .font(.caption.weight(.bold))
                .foregroundStyle(pc.isSecure ? Color.mint : Color.secondary)
            Text(MacPcsFormat.shortFingerprint(pc.certificateFingerprint))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .textSelection(.enabled)
            if pc.isSecure {
                Text("…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pair again to enable the encrypted connection.").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if pc.isSecure {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pc.certificateFingerprint, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(MacIconButtonStyle(size: 22))
                .help("Copy the full certificate fingerprint")
                .accessibilityLabel("Copy fingerprint")
            }
        }
    }

    private var wakeOnLan: some View {
        DisclosureGroup(isExpanded: $wolExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    MacPcsField(title: "MAC address", placeholder: "AA:BB:CC:11:22:33", text: $macDraft, monospaced: true)
                    MacPcsField(title: "Broadcast", placeholder: pc.autoCalcBroadcast ? "Automatic" : "192.168.1.255", text: $broadcastDraft, monospaced: true)
                    MacPcsField(title: "UDP port", placeholder: "9", text: $wolPortDraft, monospaced: true, width: 84)
                }
                MacPcsField(title: "Wake relay for remote access (optional)", placeholder: "router.example.net or 100.64.0.1:9", text: $wolRelayDraft, monospaced: true)
                Text(wakeHint)
                    .font(.caption)
                    .foregroundStyle(macValid && portValid ? Color.secondary : Color.orange)
                HStack(spacing: 8) {
                    Button("Save") { saveWake() }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                        .disabled(!wakeDirty || !macValid || !portValid)
                    Button { Task { await vm.wakePC() } } label: { Label("Wake Now", systemImage: "power") }
                        .buttonStyle(MacHoverButtonStyle(tint: .mint))
                        .disabled(!isSelected || vm.isDemoMode || vm.isWaking || vm.metrics.isOnline || pc.macAddress.isEmpty)
                        .help(isSelected ? "Send a Wake-on-LAN packet" : "Connect to this PC first to wake it from here")
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Wake-on-LAN", systemImage: "power")
                .font(.subheadline.weight(.semibold))
        }
    }

    private var wakeHint: String {
        if !macValid { return "MAC addresses have 12 hex digits, for example AA:BB:CC:11:22:33." }
        if !portValid { return "The UDP port must be between 1 and 65535 (9 is standard)." }
        if pc.macAddress.isEmpty { return "Connect once while the PC is on and Orbit fills these in automatically. Leave Broadcast empty to keep it automatic." }
        return pc.autoCalcBroadcast ? "Broadcast is updated automatically from the PC's network. Enter one to override it." : "Broadcast is set manually. Clear it to let Orbit calculate it again."
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { vm.selectPC(pc) } label: { Label(connectTitle, systemImage: "bolt.horizontal.fill") }
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: !isLive))
                .disabled(isLive)
                .help(isLive ? "Already connected" : "Make this the active PC")
            Spacer()
            Button(role: .destructive) { onForget() } label: { Label("Forget…", systemImage: "trash") }
                .buttonStyle(MacHoverButtonStyle(tint: Color(red: 1.0, green: 0.45, blue: 0.48)))
                .help("Remove this PC and its pairing token from this Mac")
        }
    }

    private func loadDrafts() {
        macDraft = pc.macAddress
        broadcastDraft = pc.broadcastAddress
        wolPortDraft = "\(pc.wolPort)"
        wolRelayDraft = pc.wolRelay
    }

    private func saveWake() {
        guard var updated = vm.savedPCs.first(where: { $0.id == pc.id }) else { return }
        let mac = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let broadcast = broadcastDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.macAddress = mac
        if broadcast != updated.broadcastAddress {
            updated.broadcastAddress = broadcast
            updated.autoCalcBroadcast = broadcast.isEmpty
        }
        if let port = Int(wolPortDraft.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) {
            updated.wolPort = port
        }
        updated.wolRelay = wolRelayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.savePC(updated, token: nil, select: false)
        macDraft = updated.macAddress
        broadcastDraft = updated.broadcastAddress
        wolPortDraft = "\(updated.wolPort)"
        wolRelayDraft = updated.wolRelay
    }
}

// MARK: - Discovered PC row

private struct MacPcsDiscoveredRow: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    let pc: MacDiscoveredPC
    let saved: MacSavedPC?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            MacIconBadge(systemName: "desktopcomputer", tint: saved == nil ? theme.accent : Color.mint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(pc.name.isEmpty ? pc.host : pc.name)
                        .font(.system(.subheadline, weight: .bold))
                        .lineLimit(1)
                    if saved != nil {
                        MacStatusPill(text: "Paired", tint: .mint, icon: "checkmark.seal.fill")
                    }
                }
                Text("\(pc.host):\(pc.securePort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    MacStatChip(label: "Agent", value: pc.agentVersion.isEmpty ? "—" : pc.agentVersion)
                    MacStatChip(label: "Secure port", value: "\(pc.securePort)")
                    MacStatChip(label: "ID", value: MacPcsFormat.shortFingerprint(pc.fingerprint, groups: 2), icon: "checkmark.shield")
                }
            }
            Spacer(minLength: 8)
            if let saved {
                Button { vm.selectPC(saved) } label: { Label("Connect", systemImage: "bolt.horizontal.fill") }
                    .buttonStyle(MacHoverButtonStyle(tint: .mint))
                    .help("Connect to \(saved.name)")
            } else {
                Button { Task { await vm.beginPairing(with: pc) } } label: { Label("Pair", systemImage: "link") }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                    .disabled(vm.isPairing)
                    .help("Request a pairing PIN from this PC")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovered ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Pairing sheet

private struct MacPcsPairingSheet: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    var target: MacDiscoveredPC?
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    private var targetName: String { vm.pairingTarget?.name ?? target?.name ?? vm.currentPC?.name ?? "your PC" }
    private var targetHost: String? { (vm.pairingTarget ?? target).map { "\($0.host):\($0.securePort)" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if vm.justPaired {
                success
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    pairingBody(now: context.date)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(MacAmbientBackground())
        .onExitCommand { vm.cancelPairing() }
        .onAppear { pinFocused = true }
        .onChange(of: vm.pairingExpiresAt) { _, value in if value != nil { pinFocused = true } }
        .onChange(of: pin) { _, newValue in
            let filtered = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(8))
            if filtered != newValue { pin = filtered }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MacIconBadge(systemName: vm.justPaired ? "checkmark.seal.fill" : "link", tint: vm.justPaired ? Color.mint : theme.accent, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.justPaired ? "Paired" : "Pair with \(targetName)")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let targetHost {
                    Text(targetHost)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pairing

    private func pairingBody(now: Date) -> some View {
        let expired = vm.pairingExpiresAt.map { $0 <= now } ?? false
        return VStack(alignment: .leading, spacing: 16) {
            Text("Enter the 6-digit PIN shown on your PC")
                .font(.subheadline.weight(.semibold))
            Text("Orbit Agent shows the code in its window and as a Windows notification. Each request issues a new code.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                pinField(expired: expired)
                countdown(now: now)
            }
            if let status = statusText(now: now) {
                Text(status).font(.caption).foregroundStyle(expired ? Color.orange : Color.secondary)
            }
            if let error = vm.pairingError {
                MacNotice(title: "Pairing failed", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
            }
            actionRow(expired: expired)
        }
    }

    private func pinField(expired: Bool) -> some View {
        TextField("000000", text: $pin)
            .textFieldStyle(.plain)
            .font(.system(size: 36, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .focused($pinFocused)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(pinFocused ? theme.accent.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1))
            .onSubmit { submit(expired: expired) }
            .disabled(vm.isPairing || vm.pairingExpiresAt == nil || expired)
            .accessibilityLabel("Pairing PIN")
    }

    @ViewBuilder
    private func countdown(now: Date) -> some View {
        if let expiresAt = vm.pairingExpiresAt {
            let remaining = max(0, expiresAt.timeIntervalSince(now))
            let fraction = vm.pairingLifetime > 0 ? remaining / vm.pairingLifetime : 0
            ZStack {
                MacRing(progress: fraction, lineWidth: 5, tint: remaining <= 15 ? Color.orange : theme.accent)
                    .frame(width: 64, height: 64)
                VStack(spacing: 0) {
                    Text("\(Int(remaining.rounded()))")
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                    Text("sec").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(remaining.rounded())) seconds remaining")
        } else {
            ZStack {
                MacRing(progress: nil, lineWidth: 5, tint: theme.accent)
                    .frame(width: 64, height: 64)
                if vm.isPairing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusText(now: Date) -> String? {
        if let expiresAt = vm.pairingExpiresAt {
            if expiresAt <= now { return "The code expired. Request a new one to try again." }
            return vm.isPairing ? "Checking the PIN with \(targetName)…" : nil
        }
        if vm.isPairing { return "Asking \(targetName) for a pairing code…" }
        return vm.pairingError == nil ? "Request a code to start pairing." : nil
    }

    private func canSubmit(expired: Bool) -> Bool {
        vm.pairingExpiresAt != nil && !expired && !vm.isPairing && pin.count >= 4
    }

    private func submit(expired: Bool) {
        guard canSubmit(expired: expired) else { return }
        Task { await vm.finishPairing(pin: pin) }
    }

    private func actionRow(expired: Bool) -> some View {
        HStack(spacing: 10) {
            Button("Cancel") { vm.cancelPairing() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(MacHoverButtonStyle())
            Spacer()
            if (vm.pairingExpiresAt == nil || expired) && !vm.isPairing, let target = vm.pairingTarget ?? target {
                Button { pin = ""; Task { await vm.beginPairing(with: target) } } label: { Label("Request New Code", systemImage: "arrow.clockwise") }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            }
            Button { submit(expired: expired) } label: {
                HStack(spacing: 6) {
                    if vm.isPairing && vm.pairingExpiresAt != nil { ProgressView().controlSize(.small) }
                    Text(vm.isPairing && vm.pairingExpiresAt != nil ? "Pairing…" : "Pair")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
            .disabled(!canSubmit(expired: expired))
        }
    }

    // MARK: Success

    private var success: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.mint.opacity(0.14)).frame(width: 84, height: 84)
                Circle().strokeBorder(Color.mint.opacity(0.35), lineWidth: 1).frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.mint)
            }
            .accessibilityHidden(true)
            Text("\(vm.currentPC?.name ?? targetName) is paired")
                .font(.headline.weight(.bold))
            Text("The pairing token is stored in your Keychain and this PC is now selected. Orbit connects automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Spacer()
                Button("Done") { vm.cancelPairing() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: true))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Field

/// Labelled text field on a glass surface, shared by the manual and Wake-on-LAN forms.
private struct MacPcsField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var width: CGFloat? = nil
    var submit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .onSubmit(submit)
                .accessibilityLabel(title)
        }
        .frame(width: width)
    }
}

// MARK: - Helpers

private enum MacPcsFormat {
    /// Public discovery port of Orbit Agent (`/api/discover`), the default `probeManualHost` expects.
    static let defaultDiscoveryPort = 8765

    /// First `groups × 4` hex characters of a fingerprint, grouped for reading; "—" when none is stored.
    static func shortFingerprint(_ value: String, groups: Int = 4) -> String {
        let normalized = OrbitAPIClient.normalizedFingerprint(value)
        guard !normalized.isEmpty else { return "—" }
        let head = Array(normalized.prefix(max(1, groups) * 4))
        var parts: [String] = []
        var index = 0
        while index < head.count {
            let end = min(index + 4, head.count)
            parts.append(String(head[index..<end]))
            index = end
        }
        return parts.joined(separator: " ")
    }
}
