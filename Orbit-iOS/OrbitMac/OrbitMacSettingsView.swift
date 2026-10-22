import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Settings scene (⌘,)

/// Settings window: General, Appearance, Connection and About tabs.
/// Controls stay native; only the Appearance preview uses the glass design system.
struct MacSettingsView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme

    var body: some View {
        TabView {
            MacSettingsGeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacSettingsAppearanceTab()
                .tabItem { Label("Accent Color", systemImage: "paintpalette") }
            MacSettingsConnectionTab()
                .tabItem { Label("Connection", systemImage: "network") }
            MacSettingsAboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 540, maxHeight: .infinity)
        .tint(theme.accent)
        .onAppear { MacSettingsDefaults.register() }
    }
}

/// Registration-domain defaults so the view model's raw `UserDefaults` reads
/// (`mac.notifyOnline`, `mac.refreshInterval`) agree with the toggles shown here.
private enum MacSettingsDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "mac.menuBarEnabled": true,
            "mac.menuBarMetric": "cpu",
            "mac.refreshInterval": 2.0,
            "mac.notifyOnline": true,
            "mac.previewAutoStart": true,
            "mac.pointerSpeed": 1.4
        ])
    }
}

private enum MacSettingsMenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, fps, temp, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU load"
        case .gpu: return "GPU load"
        case .ram: return "Memory"
        case .fps: return "FPS"
        case .temp: return "CPU temperature"
        case .none: return "Icon only"
        }
    }
}

// MARK: - General

private struct MacSettingsGeneralTab: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.refreshInterval") private var refreshInterval: Double = 2
    @AppStorage("mac.notifyOnline") private var notifyOnline = true
    @AppStorage("mac.previewAutoStart") private var previewAutoStart = true
    @AppStorage("mac.pointerSpeed") private var pointerSpeed: Double = 1.4
    @AppStorage("mac.autoOpenMoonlight") private var autoOpenMoonlight = false
    @AppStorage(MacStreamBackend.storageKey) private var streamBackendRaw = MacStreamBackend.orbit.rawValue
    @State private var launchAtLogin = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var permissionPoll: Task<Void, Never>?

    private static let intervals: [Double] = [1, 2, 3, 5, 10]

    var body: some View {
        Form {
            startupSection
            menuBarSection
            telemetrySection
            notificationSection
            controlSection
            dataSection
        }
        .formStyle(.grouped)
        .onAppear { readLoginStatus() }
        .task { await refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginStatus()
            Task { await refreshNotificationStatus() }
        }
        .onChange(of: refreshInterval) { _, _ in vm.startPolling() }
        .onDisappear { permissionPoll?.cancel(); permissionPoll = nil }
    }

    // MARK: Sections

    private var startupSection: some View {
        Section {
            Toggle("Launch Orbit at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Startup")
        } footer: {
            if let loginError {
                Text(loginError).foregroundStyle(.orange)
            } else {
                Text("Orbit keeps checking on your PC in the background, so the menu bar stays current.")
            }
        }
    }

    private var menuBarSection: some View {
        Section {
            Toggle("Show Orbit in the menu bar", isOn: $vm.menuBarEnabled)
            Picker("Show in the Menu Bar", selection: $vm.menuBarMetric) {
                ForEach(MacSettingsMenuBarMetric.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .disabled(!vm.menuBarEnabled)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Hidden while the PC is offline or doesn't report that reading.")
        }
    }

    private var telemetrySection: some View {
        Section {
            Picker("Check the PC Every", selection: $refreshInterval) {
                ForEach(Self.intervals, id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            }
            LabeledContent("Last update", value: vm.lastUpdated.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
        } header: {
            Text("Readings")
        } footer: {
            Text("More often means smoother charts and a little more work for both computers.")
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle("Notify when the PC comes online", isOn: $notifyOnline)
            LabeledContent("Permission") {
                HStack(spacing: 10) {
                    Text(notificationStatusText).foregroundStyle(.secondary)
                    if notificationStatus == .denied {
                        Button("Open System Settings") { openNotificationSettings() }
                            .controlSize(.small)
                    } else {
                        Button("Allow Notifications…") { requestNotifications() }
                            .controlSize(.small)
                            .disabled(notificationStatus == .authorized)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("A notification when your PC comes back online.")
        }
    }

    private var controlSection: some View {
        Section {
            Toggle("Show the screen as soon as Screen opens", isOn: $previewAutoStart)
            LabeledContent("Pointer speed") {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $pointerSpeed, in: 0.5...3, step: 0.1)
                        .frame(maxWidth: 200)
                        .accessibilityLabel("Pointer speed")
                    Image(systemName: "hare").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("\(MacFormat.decimal(pointerSpeed, digits: 1))×")
                        .font(.callout.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Picker("Stream with", selection: $streamBackendRaw) {
                ForEach(MacStreamBackend.allCases) { backend in Text(backend.title).tag(backend.rawValue) }
            }
            Toggle("Open Moonlight after launching a game", isOn: $autoOpenMoonlight)
        } header: {
            Text("Remote and Screen")
        } footer: {
            Text("Pointer speed is how far the PC's pointer moves for each swipe in Remote.")
        }
    }

    private var dataSection: some View {
        Section {
            Toggle("Demo Mode", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
        } header: {
            Text("Demo")
        } footer: {
            Text("Sample readings that never reach a PC. Turn it off to see your own PC again.")
        }
    }

    // MARK: Helpers

    private static func intervalTitle(_ seconds: Double) -> String {
        seconds == 1 ? "Every second" : "Every \(Int(seconds.rounded())) seconds"
    }

    private func readLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        readLoginStatus()
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized?, .provisional?: return "Allowed"
        case .denied?: return "Denied"
        case .notDetermined?: return "Not requested yet"
        default: return "—"
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    /// The view model's request has no completion callback, so poll the status for
    /// up to 30 s while the system prompt is open; `didBecomeActive` covers the rest.
    private func requestNotifications() {
        OrbitMacViewModel.requestNotificationPermission()
        permissionPoll?.cancel()
        permissionPoll = Task {
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await refreshNotificationStatus()
                if notificationStatus != .notDetermined { return }
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Appearance

private struct MacSettingsAppearanceTab: View {
    @AppStorage("mac.theme") private var selectedTheme: MacTheme = .noir
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showsProPaywall = false

    var body: some View {
        Form {
            Section {
                preview
            } footer: {
                Text("The canvas stays black; the accent marks what you can click and what is live. Your iPhone has the same colors.")
            }
            Section("Included") {
                swatches(MacTheme.allCases.filter { !$0.isPro })
            }
            Section {
                swatches(MacTheme.allCases.filter(\.isPro))
            } header: {
                Text("Orbit Pro")
            } footer: {
                if !proStore.isProUnlocked { Text("These colors come with Orbit Pro.") }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsProPaywall) { OrbitProUnlockView(accent: selectedTheme.accent) { showsProPaywall = false } }
    }

    private var preview: some View {
        HStack(spacing: 16) {
            OrbitMark(status: .online, size: 40, tint: selectedTheme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Running cool and quiet")
                    .font(.headline)
                OrbitMeter(fraction: 0.62, style: AnyShapeStyle(selectedTheme.accent))
                    .frame(width: 180)
            }
            Spacer()
            Text(selectedTheme.title)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .animation(OrbitMotion.standard, value: selectedTheme)
    }

    /// Eager rows: a lazy grid inside a grouped `Form` row can measure a zero height on macOS.
    private func swatches(_ options: [MacTheme]) -> some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                let locked = option.isPro && !proStore.isProUnlocked
                MacSettingsThemeSwatch(option: option, isSelected: option == selectedTheme, isLocked: locked) {
                    if locked {
                        showsProPaywall = true
                    } else {
                        withAnimation(OrbitMotion.standard) { selectedTheme = option }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// One accent: a color dot with a ring when chosen, its name, a lock when it needs Orbit Pro.
private struct MacSettingsThemeSwatch: View {
    let option: MacTheme
    let isSelected: Bool
    var isLocked = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(option.accent)
                        .frame(width: 28, height: 28)
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .opacity(isSelected ? 1 : 0)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38)
                .scaleEffect(hovered ? 1.06 : 1)
                Text(option.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(OrbitMotion.quick, value: hovered)
        .help(option.title + (isLocked ? " · Orbit Pro" : ""))
        .accessibilityLabel(option.title + (isLocked ? ", Orbit Pro" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MacSettingsWakeDraft: Equatable {
    var macAddress = ""
    var autoBroadcast = true
    var broadcastAddress = ""
    var wolPort = "9"

    init() {}
    init(_ pc: MacSavedPC) {
        macAddress = pc.macAddress
        autoBroadcast = pc.autoCalcBroadcast
        broadcastAddress = pc.broadcastAddress
        wolPort = String(pc.wolPort)
    }

    var cleanedMAC: String { macAddress.filter { !":-. ".contains($0) } }
    var macIsValid: Bool { cleanedMAC.isEmpty || (cleanedMAC.count == 12 && cleanedMAC.allSatisfy { $0.isHexDigit }) }
    var port: Int? {
        guard let value = Int(wolPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }
    var isValid: Bool { macIsValid && port != nil }
}

private struct MacSettingsConnectionTab: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var draft = MacSettingsWakeDraft()
    @State private var baseline = MacSettingsWakeDraft()
    @State private var loadedPCID = ""
    @State private var saveNotice: String?
    @State private var confirmForget = false

    private var isDirty: Bool { draft != baseline }

    var body: some View {
        Group {
            if let pc = vm.currentPC {
                form(for: pc)
            } else {
                emptyState
            }
        }
        .onAppear { load() }
        .onChange(of: vm.selectedPCID) { _, _ in load(force: true) }
        .onChange(of: vm.savedPCs) { _, _ in load() }
    }

    // MARK: Form

    private func form(for pc: MacSavedPC) -> some View {
        Form {
            if vm.isDemoMode { demoRow }
            if let error = vm.connectionError, !vm.metrics.isOnline, !vm.isDemoMode {
                Section {
                    MacNotice(title: "Connection problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            summarySection(pc)
            wakeSection(pc)
            actionsSection(pc)
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget \(pc.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget PC", role: .destructive) { vm.removePC(pc) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved address, certificate fingerprint and pairing token are removed from this Mac. You can pair again at any time from My PCs.")
        }
    }

    private var demoRow: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Demo mode is on. The paired PC is not being contacted.")
                    .font(.callout)
                Spacer()
                Button("Leave Demo Mode") { vm.setDemoMode(false) }
                    .controlSize(.small)
            }
        }
    }

    private func summarySection(_ pc: MacSavedPC) -> some View {
        Section {
            LabeledContent("Name", value: pc.name.isEmpty ? "—" : pc.name)
            LabeledContent("Host", value: pc.address.isEmpty ? "—" : pc.address)
            LabeledContent("Ports", value: "\(pc.securePort) secure · \(pc.agentPort) discovery")
            LabeledContent("Last known IPv4", value: pc.lastKnownIPv4.isEmpty ? "—" : pc.lastKnownIPv4)
            LabeledContent("Status") {
                MacStatusPill(text: statusText, tint: statusTint, pulsing: vm.metrics.isOnline && !vm.isDemoMode)
            }
            LabeledContent("Channel") {
                MacStatusPill(text: pc.isSecure ? "Encrypted" : "Legacy", tint: pc.isSecure ? .mint : .orange, icon: pc.isSecure ? "lock.fill" : "lock.open")
            }
            LabeledContent("Fingerprint") {
                HStack(alignment: .top, spacing: 8) {
                    Text(groupedFingerprint(pc.certificateFingerprint))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    Button { copyFingerprint(pc.certificateFingerprint) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(MacIconButtonStyle(size: 22))
                        .help("Copy fingerprint")
                        .accessibilityLabel("Copy fingerprint")
                        .disabled(pc.certificateFingerprint.isEmpty)
                }
            }
            LabeledContent("Agent version", value: agentVersionText)
            LabeledContent("Pairing token", value: vm.token(for: pc).isEmpty ? "Not stored" : "Stored in Keychain")
        } header: {
            Text("Paired PC")
        } footer: {
            if pc.isSecure {
                Text("Orbit for Mac only talks to your PC over the encrypted, certificate-pinned channel on the secure port. Unencrypted legacy connections are never used.")
            } else {
                Text("This profile has no valid certificate fingerprint, so Orbit cannot connect. Pair again from My PCs to pin the agent's certificate.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func wakeSection(_ pc: MacSavedPC) -> some View {
        Section {
            TextField("MAC address", text: $draft.macAddress, prompt: Text("AA:BB:CC:DD:EE:FF"))
                .font(.body.monospacedDigit())
                .autocorrectionDisabled()
            Toggle("Calculate broadcast address automatically", isOn: $draft.autoBroadcast)
            if draft.autoBroadcast {
                LabeledContent("Broadcast address", value: computedBroadcast(pc).isEmpty ? "—" : computedBroadcast(pc))
            } else {
                TextField("Broadcast address", text: $draft.broadcastAddress, prompt: Text("192.168.1.255"))
                    .autocorrectionDisabled()
            }
            TextField("UDP port", text: $draft.wolPort, prompt: Text("9"))
            HStack(spacing: 10) {
                Button("Save") { save(pc) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty || !draft.isValid)
                Button("Revert") { load(force: true) }
                    .disabled(!isDirty)
                Spacer()
                if let saveNotice {
                    Label(saveNotice, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.mint)
                }
            }
        } header: {
            Text("Wake-on-LAN")
        } footer: {
            if !draft.macIsValid {
                Text("Enter 12 hexadecimal digits, for example AA:BB:CC:DD:EE:FF.").foregroundStyle(.orange)
            } else if draft.port == nil {
                Text("The UDP port must be between 1 and 65535.").foregroundStyle(.orange)
            } else {
                Text("Orbit fills the MAC address and subnet from the agent the first time it connects. Edit them only if your network needs it.")
            }
        }
    }

    private func actionsSection(_ pc: MacSavedPC) -> some View {
        Section {
            HStack(spacing: 10) {
                Button { vm.resetConnection(); Task { await vm.refreshMetrics() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .disabled(vm.isDemoMode)
                    .help("Drop the current session and connect again")
                Button { Task { await vm.wakePC() } } label: { Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power") }
                    .disabled(vm.isWaking || vm.metrics.isOnline || pc.macAddress.isEmpty)
                    .help("Send a Wake-on-LAN packet")
                Spacer()
                Button(role: .destructive) { confirmForget = true } label: { Label("Forget this PC…", systemImage: "trash") }
            }
            if !vm.statusBanner.isEmpty {
                Text(vm.statusBanner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } header: {
            Text("Connection")
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            MacEmptyState(
                icon: "desktopcomputer",
                title: vm.isDemoMode ? "Demo mode · no PC paired" : "No PC paired",
                message: "Pair your Windows PC with the 6-digit code shown by Orbit Agent, or import the PC you already paired on your iPhone.",
                tint: theme.accent,
                actionTitle: "Open My PCs…",
                action: { openPCs() }
            )
            if vm.isDemoMode {
                Button("Leave Demo Mode") { vm.setDemoMode(false) }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if vm.isWaking { return "Waking…" }
        return vm.metrics.isOnline ? "Online" : "Offline"
    }
    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        return vm.metrics.isOnline ? .mint : .orange
    }
    /// `metrics` keeps the last reading after the PC drops offline, so the version
    /// is only shown while the agent is actually reachable.
    private var agentVersionText: String {
        guard vm.metrics.isOnline, let version = vm.metrics.agentVersion, !version.isEmpty else { return "—" }
        return version
    }

    private func load(force: Bool = false) {
        guard let pc = vm.currentPC else {
            loadedPCID = ""
            draft = MacSettingsWakeDraft()
            baseline = draft
            saveNotice = nil
            return
        }
        guard force || pc.id != loadedPCID || !isDirty else { return }
        let fresh = MacSettingsWakeDraft(pc)
        draft = fresh
        baseline = fresh
        loadedPCID = pc.id
        if force { saveNotice = nil }
    }

    private func computedBroadcast(_ pc: MacSavedPC) -> String {
        if !pc.broadcastAddress.isEmpty { return pc.broadcastAddress }
        guard !pc.lastKnownIPv4.isEmpty, !pc.subnetMask.isEmpty else { return "" }
        return OrbitMacViewModel.broadcast(ip: pc.lastKnownIPv4, mask: pc.subnetMask)
    }

    private func save(_ pc: MacSavedPC) {
        guard let port = draft.port, draft.macIsValid else { return }
        var updated = pc
        updated.macAddress = draft.macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.autoCalcBroadcast = draft.autoBroadcast
        updated.broadcastAddress = draft.autoBroadcast
            ? computedBroadcast(pc)
            : draft.broadcastAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.wolPort = port
        vm.savePC(updated, token: vm.token(for: pc), select: false)
        let fresh = MacSettingsWakeDraft(updated)
        draft = fresh
        baseline = fresh
        loadedPCID = updated.id
        saveNotice = "Saved"
    }

    private func groupedFingerprint(_ raw: String) -> String {
        let normalized = OrbitAPIClient.normalizedFingerprint(raw).uppercased()
        guard !normalized.isEmpty else { return "—" }
        var groups: [String] = []
        var current = ""
        for character in normalized {
            current.append(character)
            if current.count == 4 { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: " ")
    }

    private func copyFingerprint(_ raw: String) {
        let normalized = OrbitAPIClient.normalizedFingerprint(raw)
        guard !normalized.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(normalized, forType: .string)
        saveNotice = "Fingerprint copied"
    }

    private func openPCs() {
        vm.selectedSection = .pcs
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - About

private struct MacSettingsAboutTab: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @State private var confirmInstall = false
    @State private var showsAcknowledgements = false
    @State private var showsProPaywall = false

    private static let repositoryURL = "https://github.com/AceDimi2005/Orbit"
    private static let companionURL = "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip"

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var copyright: String { Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© Orbit" }
    /// Live value only; the last reading lingers in `metrics` after the PC goes offline.
    private var installedAgentVersion: String {
        guard vm.metrics.isOnline, let version = vm.metrics.agentVersion, !version.isEmpty else { return "—" }
        return version
    }

    var body: some View {
        Form {
            identitySection
            agentSection
            linksSection
            Section {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsAcknowledgements) {
            OrbitAcknowledgementsView(accent: theme.accent) { showsAcknowledgements = false }
        }
        .sheet(isPresented: $showsProPaywall) { OrbitProUnlockView(accent: theme.accent) { showsProPaywall = false } }
        .confirmationDialog("Install the agent update on \(vm.currentPC?.name ?? "your PC")?", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Install Update") { Task { await vm.applyAgentUpdate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Windows agent downloads the latest release from GitHub and replaces itself. You may need to restart the PC Companion from the Windows tray afterwards.")
        }
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Orbit for Mac")
                        .font(.title3.weight(.bold))
                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Your Windows PC from your Mac: how it's doing, power, remote control, its screen, sound, files and games, over an encrypted connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var agentSection: some View {
        Section {
            LabeledContent("Installed on PC", value: installedAgentVersion)
            LabeledContent("Latest release", value: vm.agentLatestVersion ?? "—")
            HStack(spacing: 10) {
                Button { Task { await vm.checkAgentUpdate() } } label: { Label("Check for Agent Update", systemImage: "arrow.triangle.2.circlepath") }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(vm.isCheckingUpdate)
                if vm.agentUpdateAvailable {
                    Button { confirmInstall = true } label: { Label("Install Update on PC", systemImage: "arrow.down.circle") }
                        .disabled(vm.isCheckingUpdate || !vm.metrics.isOnline || vm.isDemoMode)
                }
                if vm.isCheckingUpdate { ProgressView().controlSize(.small) }
                Spacer()
                if vm.agentUpdateAvailable {
                    MacStatusPill(text: "Update available", tint: .orange, icon: "arrow.down.circle.fill")
                } else if vm.agentLatestVersion != nil {
                    MacStatusPill(text: "Up to date", tint: .mint, icon: "checkmark")
                }
            }
            if let message = vm.agentUpdateMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Windows agent")
        } footer: {
            Text(vm.metrics.isOnline || vm.isDemoMode
                 ? "The agent checks GitHub for its own latest release; nothing is downloaded until you confirm."
                 : "Connect to your PC to check its agent version, or download the companion from GitHub below.")
        }
    }

    private var linksSection: some View {
        Section {
            Button { open(Self.repositoryURL) } label: { Label("Orbit on GitHub", systemImage: "link") }
            Button { open(Self.companionURL) } label: { Label("Download Windows Companion (.zip)", systemImage: "arrow.down.doc") }
            Button { open(OrbitThirdPartyNotices.sunshineDownloadURL.absoluteString) } label: { Label("Download Sunshine for Windows (game streaming)", systemImage: "sun.max") }
            Button { showsProPaywall = true } label: { Label(OrbitProStore.shared.isProUnlocked ? "Orbit Pro · Active" : "Orbit Pro…", systemImage: "crown.fill") }
            Button { showsAcknowledgements = true } label: { Label("Acknowledgements & Licenses", systemImage: "doc.text") }
        } header: {
            Text("Links")
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
