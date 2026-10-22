import MoonlightCore
import SwiftUI

/// Settings, in the order people look for things: your PCs, how Orbit looks, where it
/// shows up outside the app, streaming, and the fine print.
struct SettingsHubView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @Environment(\.dismiss) private var dismiss
    @State private var showsDiscovery = false
    @State private var showsPro = false
    @State private var showsPrivacy = false
    @State private var showsLicenses = false
    @State private var showsStreamSettings = false
    @State private var showsCustomize = false

    var body: some View {
        NavigationStack {
            Form {
                proSection

                Section("PCs") {
                    ForEach(vm.savedPCs) { pc in
                        Button {
                            OrbitHaptics.selection()
                            vm.selectPC(pc)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pc.name)
                                        .foregroundStyle(.primary)
                                    Text(pc.address)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if pc.id == vm.selectedPCID {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(theme.orbitTint)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    Button("Add PC…", systemImage: "plus") { showsDiscovery = true }
                    if !vm.savedPCs.isEmpty {
                        NavigationLink("Manage PCs") { PCProfilesView(vm: vm) }
                    }
                    if vm.isConfigured {
                        NavigationLink("Connection & Wake") { PCConnectionSettingsView(vm: vm) }
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        AccentSettingsView()
                    } label: {
                        LabeledContent("Accent Color") {
                            HStack(spacing: 8) {
                                Text(theme.accentName)
                                Circle().fill(theme.orbitTint).frame(width: 14, height: 14)
                            }
                        }
                    }
                    NavigationLink("App Icon") { AppearanceSettingsView() }
                    Button("Readings on the PC Tab…") { showsCustomize = true }
                }

                Section {
                    Toggle(isOn: Binding(get: { vm.isDynamicIslandActive }, set: { _ in vm.toggleDynamicIsland() })) {
                        Text("Show on Lock Screen")
                    }
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                    NavigationLink("Live Activity") { LiveActivitySettingsView(vm: vm) }
                    NavigationLink("Widgets, Controls and Siri") { WidgetHelpView(vm: vm) }
                    NavigationLink("Apple Watch") { AppleWatchCompanionHelpView(vm: vm) }
                } header: {
                    Text("Outside the App")
                } footer: {
                    Text("The Live Activity keeps your PC's temperatures and frame rate on the Lock Screen and in the Dynamic Island.")
                }

                Section("Streaming") {
                    Button {
                        showsStreamSettings = true
                    } label: {
                        LabeledContent("Quality") {
                            Text("\(streamSettings.settings.pixelSize.height)p · \(streamSettings.settings.frameRate) fps")
                        }
                    }
                    .foregroundStyle(.primary)
                    Toggle("Open Moonlight After Starting a Game", isOn: $vm.autoOpenMoonlight)
                }

                Section("Readings") {
                    NavigationLink("Sensor Sources") { MonitoringSourcesView(vm: vm) }
                    NavigationLink("Frame Rate Counter") { FPSSetupView(vm: vm) }
                }

                Section {
                    Toggle("Demo Mode", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
                    Button("Show the Welcome Tour") {
                        dismiss()
                        vm.showOnboarding = true
                    }
                    Button("Privacy") { showsPrivacy = true }
                    Button("Licenses") { showsLicenses = true }
                } header: {
                    Text("About")
                } footer: {
                    Text("Orbit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Made for Windows PCs with Orbit Companion.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrbitPalette.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .tint(.primary)
                }
            }
            .sheet(isPresented: $showsDiscovery) { PCDiscoveryView(vm: vm) }
            .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
            .sheet(isPresented: $showsPrivacy) { OrbitPrivacyPolicyView() }
            .sheet(isPresented: $showsLicenses) { OrbitAcknowledgementsView(accent: theme.orbitTint) }
            .sheet(isPresented: $showsCustomize) { DashboardCustomizationView(vm: vm) }
            .sheet(isPresented: $showsStreamSettings) {
                MoonlightStreamSettingsView(store: streamSettings, accent: theme.orbitTint, hostSupportsHEVC: nil) {
                    showsStreamSettings = false
                }
            }
            .alert("Live Activity unavailable", isPresented: Binding(get: { vm.liveActivityError != nil }, set: { if !$0 { vm.liveActivityError = nil } })) {
                Button("OK") { vm.liveActivityError = nil }
            } message: {
                Text(vm.liveActivityError ?? "Live Activities could not be started.")
            }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
    }

    private var proSection: some View {
        Section {
            Button {
                showsPro = true
            } label: {
                HStack(spacing: 14) {
                    OrbitMark(status: .online, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proStore.isProUnlocked ? "Orbit Pro" : "Unlock Orbit Pro")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(proStore.isProUnlocked ? "Thank you. Everything is unlocked on all your devices." : "More PCs, sessions, accent colors, icons and power widgets.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !proStore.isProUnlocked, let price = proStore.displayPrice {
                        Text(price)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.orbitTint)
                    }
                }
                .padding(.vertical, 4)
            }
            .tint(.primary)
            if let status = proStore.statusMessage {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Connection & wake

/// The current PC's address, ports, token and Wake-on-LAN details, plus Companion updates.
struct PCConnectionSettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var isConnecting = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                field("Address", placeholder: "192.168.1.100", text: $vm.pcIP)
                    .onChange(of: vm.pcIP) { _, _ in vm.recalculateBroadcastIfNeeded() }
                LabeledContent("Access Token") {
                    SecureField("Paste token", text: $vm.apiToken)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                }
                port("Secure Port", value: $vm.securePort)
                port("Legacy Port", value: $vm.agentPort)
                Button {
                    focused = false
                    isConnecting = true
                    vm.saveCurrentConnection()
                    Task { await vm.connect(); isConnecting = false }
                } label: {
                    HStack {
                        Text(isConnecting ? "Connecting…" : "Save and Connect")
                        Spacer()
                        if isConnecting { ProgressView() }
                    }
                }
                .disabled(isConnecting || !vm.isConfigured)
            } header: {
                Text("Connection")
            } footer: {
                Text("Pairing fills these in. Change them only if your PC's address changed.")
            }

            Section {
                field("MAC Address", placeholder: "AA:BB:CC:DD:EE:FF", text: $vm.pcMAC)
                field("Subnet Mask", placeholder: "255.255.255.0", text: $vm.subnetMask)
                    .onChange(of: vm.subnetMask) { _, _ in vm.recalculateBroadcastIfNeeded() }
                Toggle("Broadcast Address from Subnet", isOn: $vm.autoCalcBroadcast)
                    .onChange(of: vm.autoCalcBroadcast) { _, _ in vm.recalculateBroadcastIfNeeded() }
                field("Broadcast Address", placeholder: "192.168.1.255", text: $vm.wolTargetIP)
                    .disabled(vm.autoCalcBroadcast)
                port("Port", value: $vm.wolPort)
                Button("Read Network Details from the PC") { Task { await vm.fetchNetworkConfigFromPC() } }
                    .disabled(!vm.metrics.isOnline || vm.isDemoMode)
                Button("Send Wake Signal Now") {
                    OrbitHaptics.press()
                    Task { await vm.wakePC() }
                }
                .disabled(!vm.isConfigured || vm.pcMAC.isEmpty || vm.isWakingUp)
            } header: {
                Text("Wake-on-LAN")
            } footer: {
                Text("Orbit learns these while the PC is on. The PC's network card must have Wake-on-LAN turned on.")
            }

            Section {
                LabeledContent("Installed", value: vm.metrics.agentVersion ?? "—")
                if let latest = vm.agentLatestVersion {
                    LabeledContent("Latest", value: latest)
                }
                Button {
                    Task { await vm.checkPCCompanionUpdate() }
                } label: {
                    HStack {
                        Text(vm.isCheckingAgentUpdate ? "Checking…" : "Check for Update")
                        Spacer()
                        if vm.isCheckingAgentUpdate { ProgressView() }
                    }
                }
                .disabled(vm.isCheckingAgentUpdate)
                if vm.agentUpdateAvailable {
                    Button("Install Update on the PC") { Task { await vm.applyPCCompanionUpdate() } }
                        .disabled(vm.isCheckingAgentUpdate || !vm.metrics.isOnline)
                }
                if let message = vm.agentUpdateMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                ShareLink(item: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!,
                          subject: Text("Orbit Companion for Windows"),
                          message: Text("Orbit Companion for Windows")) {
                    Text("Send Companion Download to the PC")
                }
            } header: {
                Text("Orbit Companion")
            }
        }
        .scrollContentBackground(.hidden)
        .background(OrbitPalette.canvas)
        .navigationTitle("Connection & Wake")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
        }
    }

    private func port(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("Port", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
        }
    }
}

// MARK: - Accent

/// Accent colors. The canvas stays black; the accent marks what you can touch and what is live.
struct AccentSettingsView: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showsPro = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                preview
                group("Included", OrbitTheme.freeThemes)
                group("Orbit Pro", OrbitTheme.proThemes)
            }
            .padding(.horizontal, OrbitMetrics.gutter)
            .padding(.bottom, 32)
        }
        .background(OrbitPalette.canvas)
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
    }

    private var preview: some View {
        HStack(spacing: 16) {
            OrbitMark(status: .online, size: 44, tint: theme.orbitTint)
            VStack(alignment: .leading, spacing: 6) {
                Text("Running cool and quiet")
                    .font(.headline)
                OrbitMeter(fraction: 0.62, style: AnyShapeStyle(theme.orbitTint))
                    .frame(width: 160)
            }
        }
        .orbitSurface()
        .animation(OrbitMotion.standard, value: theme)
    }

    private func group(_ title: String, _ themes: [OrbitTheme]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader(title)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(themes) { option in
                    let locked = option.isPro && !proStore.isProUnlocked
                    Button {
                        if locked {
                            showsPro = true
                        } else {
                            OrbitHaptics.selection()
                            withAnimation(OrbitMotion.standard) { theme = option }
                            NSUbiquitousKeyValueStore.default.set(option.rawValue, forKey: "orbit.theme")
                        }
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(option.orbitTint).frame(width: 44, height: 44)
                                if theme == option {
                                    Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 54, height: 54)
                                }
                                if locked {
                                    Image(systemName: "lock.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 56, height: 56)
                            Text(option.accentName)
                                .font(.caption)
                                .foregroundStyle(theme == option ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.accentName + (locked ? ", Orbit Pro" : ""))
                    .accessibilityAddTraits(theme == option ? .isSelected : [])
                }
            }
        }
    }
}

extension OrbitTheme {
    /// Plain color names for the redesigned accent picker; stored values stay the same.
    var accentName: String {
        switch self {
        case .noir: return "Orbit Blue"
        case .ocean: return "Teal"
        case .aurora: return "Mint"
        case .violet: return "Indigo"
        case .ember: return "Orange"
        case .graphite: return "Graphite"
        case .cyberpunk: return "Pink"
        case .solarGold: return "Gold"
        case .crimson: return "Red"
        case .matrix: return "Green"
        case .arctic: return "Ice"
        case .sakura: return "Rose"
        }
    }
}
