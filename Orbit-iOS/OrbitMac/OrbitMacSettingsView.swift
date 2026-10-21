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
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
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
                Text("Orbit keeps polling your PC in the background so the menu bar readout stays current.")
            }
        }
    }

    private var menuBarSection: some View {
        Section {
            Toggle("Show Orbit in the menu bar", isOn: $vm.menuBarEnabled)
            Picker("Menu bar readout", selection: $vm.menuBarMetric) {
                ForEach(MacSettingsMenuBarMetric.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .disabled(!vm.menuBarEnabled)
        } header: {
            Text("Menu bar")
        } footer: {
            Text("The readout is hidden while the PC is offline or does not report that sensor. Nothing is estimated.")
        }
    }

    private var telemetrySection: some View {
        Section {
            Picker("Refresh interval", selection: $refreshInterval) {
                ForEach(Self.intervals, id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            }
            LabeledContent("Last update", value: vm.lastUpdated.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
        } header: {
            Text("Telemetry")
        } footer: {
            Text("Shorter intervals give smoother sparklines and cost a little more network and CPU on both machines. Changes apply immediately.")
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
            Text("Orbit posts a notification when a paired PC reconnects. macOS asks for permission the first time.")
        }
    }

    private var controlSection: some View {
        Section {
            Toggle("Start the desktop preview automatically", isOn: $previewAutoStart)
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
            Toggle("Open Moonlight after launching a game", isOn: $autoOpenMoonlight)
        } header: {
            Text("Remote & preview")
        } footer: {
            Text("Pointer speed scales trackpad movement sent to the PC from the Remote section.")
        }
    }

    private var dataSection: some View {
        Section {
            Toggle("Demo mode", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
        } header: {
            Text("Data")
        } footer: {
            Text("Demo mode shows clearly labelled simulated readings and never contacts a PC. Turn it off to reconnect to your paired PC.")
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
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.theme") private var selectedTheme: MacTheme = .noir
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    @AppStorage("mac.monochromeMetrics") private var monochrome = false

    /// Eager grid: a lazy container inside a `List`-backed grouped `Form` row can
    /// measure a zero height on macOS, so the swatches are laid out in fixed rows.
    private static let swatchColumns = 4
    private var themeRows: [[MacTheme]] {
        let all = MacTheme.allCases
        return stride(from: 0, to: all.count, by: Self.swatchColumns).map { start in
            Array(all[start..<min(start + Self.swatchColumns, all.count)])
        }
    }

    var body: some View {
        Form {
            Section {
                themeGrid
                    .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("Applies to every Orbit window, the menu bar popover and the preview below.")
            }
            Section {
                Toggle("Reduce glow", isOn: $reduceGlow)
                Toggle("Monochrome metrics", isOn: $monochrome)
            } header: {
                Text("Effects")
            } footer: {
                Text("Reduce glow removes the ambient blur and value halos. Monochrome metrics colour every card with the theme accent instead of per-sensor colours.")
            }
            Section {
                previewRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Preview")
            } footer: {
                Text(vm.metrics.hasTelemetry ? "Live readings from \(vm.selectedPCName)." : "Cards show “—” until a PC reports readings.")
            }
        }
        .formStyle(.grouped)
    }

    private var themeGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(themeRows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(themeRows[rowIndex]) { option in
                        MacSettingsThemeSwatch(option: option, isSelected: option == selectedTheme) {
                            withAnimation(.snappy(duration: 0.25)) { selectedTheme = option }
                        }
                    }
                }
            }
        }
    }

    // Only live readings feed the preview; stale values linger in `metrics` after
    // the PC drops offline, so everything is gated on `hasTelemetry`.
    private var cpuLoad: Double? { vm.metrics.hasTelemetry ? vm.metrics.cpuUsage : nil }
    private var gpuLoad: Double? { vm.metrics.hasTelemetry ? vm.metrics.gpuUsage : nil }
    private var cpuTemperatureText: String? {
        guard vm.metrics.hasTelemetry, let temp = vm.metrics.cpuTemp else { return nil }
        return "\(Int(temp.rounded()))°C"
    }
    private var gpuTemperatureText: String? {
        guard vm.metrics.hasTelemetry, let temp = vm.metrics.gpuTemp else { return nil }
        return "\(Int(temp.rounded()))°C"
    }

    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if vm.currentPC == nil { return "Not paired" }
        return vm.metrics.isOnline ? "Online" : "Offline"
    }
    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        return vm.metrics.isOnline ? .mint : (vm.currentPC == nil ? .secondary : .orange)
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MacStatusPill(text: statusText, tint: statusTint, pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                MacStatChip(label: "Link", value: vm.currentPC?.isSecure == true ? "Encrypted" : "—", icon: "lock.fill")
                MacStatChip(label: "Up", value: vm.metrics.formattedUptime)
                Spacer(minLength: 0)
                Button("Reset to Noir") { withAnimation(.snappy(duration: 0.25)) { selectedTheme = .noir } }
                    .buttonStyle(MacHoverButtonStyle(tint: selectedTheme.accent, prominent: true))
                    .disabled(selectedTheme == .noir)
            }
            HStack(spacing: 10) {
                MacMetricCard(title: MacMetric.cpuLoad.title, subtitle: vm.metrics.cpuName, valueText: MacFormat.percent(cpuLoad), progress: cpuLoad.map { $0 / 100 },
                              icon: MacMetric.cpuLoad.symbol, accent: MacMetric.cpuLoad.accent, detail: cpuTemperatureText,
                              history: vm.history.values(for: .cpuLoad), showsRing: true)
                MacMetricCard(title: MacMetric.gpuLoad.title, subtitle: vm.metrics.gpuName, valueText: MacFormat.percent(gpuLoad), progress: gpuLoad.map { $0 / 100 },
                              icon: MacMetric.gpuLoad.symbol, accent: MacMetric.gpuLoad.accent, detail: gpuTemperatureText,
                              history: vm.history.values(for: .gpuLoad), showsRing: true)
            }
        }
        .padding(14)
        .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selectedTheme.background) }
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
    }
}

/// One theme tile: gradient fill, background dot, checkmark when selected.
private struct MacSettingsThemeSwatch: View {
    let option: MacTheme
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    private var borderColor: Color {
        if isSelected { return Color.white.opacity(0.95) }
        return Color.white.opacity(hovered ? 0.35 : 0.12)
    }
    private var glowOpacity: Double { (isSelected || hovered) ? 0.35 : 0 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                tile
                Text(option.title)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tile: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(option.heroGradient)
                .frame(height: 56)
                .overlay(alignment: .bottomLeading) { backgroundDot }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                )
                .shadow(color: option.accent.opacity(glowOpacity), radius: 10, y: 4)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    .padding(5)
            }
        }
    }

    private var backgroundDot: some View {
        Circle()
            .fill(option.background)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            .padding(7)
    }
}

// MARK: - Connection

/// Editable Wake-on-LAN fields, compared against a baseline to detect edits.
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
                    Text("Native companion for the Orbit Windows agent: telemetry, remote control, desktop preview and files over an encrypted local link.")
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
            Button { showsAcknowledgements = true } label: { Label("Acknowledgements & Licenses", systemImage: "doc.text") }
        } header: {
            Text("Links")
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
