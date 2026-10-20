import SwiftUI

/// Main window: sidebar with the paired PC and sections, detail on the right.
struct MacRootView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingPower: MacPowerConfirmation?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            ZStack {
                MacAmbientBackground(isOnline: vm.metrics.isOnline)
                detail
                    .id(vm.selectedSection)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.18), value: vm.selectedSection)
            .navigationTitle(vm.selectedSection.title)
            .navigationSubtitle(vm.isDemoMode ? "Demo mode" : (vm.currentPC?.name ?? "No PC paired"))
            .toolbar { toolbarContent }
        }
        .background(theme.background)
        .onReceive(NotificationCenter.default.publisher(for: .macConfirmPower)) { note in
            if let raw = note.object as? String, let action = MacPowerConfirmation(rawValue: raw) { pendingPower = action }
        }
        .confirmationDialog(pendingPower?.title ?? "Confirm", isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }), titleVisibility: .visible) {
            if let action = pendingPower {
                Button(action.button, role: .destructive) {
                    pendingPower = nil
                    Task { await vm.sendAction(action.rawValue) }
                }
            }
            Button("Cancel", role: .cancel) { pendingPower = nil }
        } message: {
            Text(pendingPower?.message ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(vm.selectedSection) }, set: { if let value = $0 { vm.selectedSection = value } })) {
            Section {
                pcHeader
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            Section("Monitor") {
                ForEach(MacSection.monitorGroup) { sidebarRow($0) }
            }
            Section("Control") {
                ForEach(MacSection.controlGroup) { sidebarRow($0) }
            }
            Section("Setup") {
                ForEach(MacSection.setupGroup) { sidebarRow($0) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.background.opacity(0.6))
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private func sidebarRow(_ section: MacSection) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if section == .preview && vm.isStreaming {
                    Circle().fill(.red).frame(width: 7, height: 7)
                } else if section == .sessions, vm.historyList?.activeSession != nil {
                    Circle().fill(.red).frame(width: 7, height: 7)
                } else if section == .files, vm.transfer != nil {
                    ProgressView().controlSize(.mini)
                }
            }
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(vm.selectedSection == section ? theme.accent : .secondary)
        }
        .tag(section)
    }

    private var pcHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    MacRing(progress: vm.metrics.hasTelemetry ? vm.metrics.cpuUsage / 100 : nil, lineWidth: 4, tint: theme.accent)
                        .frame(width: 44, height: 44)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vm.metrics.isOnline || vm.isDemoMode ? AnyShapeStyle(theme.heroGradient) : AnyShapeStyle(Color.secondary))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Menu {
                        ForEach(vm.savedPCs) { pc in
                            Button {
                                vm.selectPC(pc)
                            } label: {
                                if pc.id == vm.selectedPCID { Label(pc.name, systemImage: "checkmark") } else { Text(pc.name) }
                            }
                        }
                        Divider()
                        Button("Pair a PC…") { vm.selectedSection = .pcs }
                        Button(vm.isDemoMode ? "Leave Demo Mode" : "Demo Mode") { vm.setDemoMode(!vm.isDemoMode) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(vm.isConfigured ? vm.selectedPCName : "No PC")
                                .font(.system(.subheadline, weight: .bold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    MacStatusPill(text: statusText, tint: statusTint, pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                }
                Spacer(minLength: 0)
            }
            if vm.metrics.isOnline && !vm.isDemoMode {
                HStack(spacing: 6) {
                    MacStatChip(label: "Ping", value: "\(vm.pingMs) ms")
                    MacStatChip(label: "Up", value: vm.metrics.formattedUptime)
                }
            }
        }
        .padding(10)
        .macGlass(cornerRadius: 14, tint: theme.accent)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.wakePC() }
            } label: {
                Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power")
                    .font(.system(.caption, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: !vm.metrics.isOnline))
            .disabled(vm.isWaking || vm.currentPC == nil || vm.metrics.isOnline)
            .help("Send a Wake-on-LAN packet")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(MacIconButtonStyle())
            .help("Settings")
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if vm.isWaking { return "Waking…" }
        if vm.currentPC == nil { return "Not paired" }
        return vm.metrics.isOnline ? "Online" : "Offline"
    }
    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        return vm.metrics.isOnline ? .mint : (vm.currentPC == nil ? .secondary : .orange)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch vm.selectedSection {
        case .overview: MacOverviewView(pendingPower: $pendingPower)
        case .remote: MacRemoteView()
        case .preview: MacPreviewView()
        case .files: MacFilesView()
        case .processes: MacProcessesView()
        case .audio: MacAudioView()
        case .clipboard: MacClipboardView()
        case .sessions: MacSessionsView()
        case .library: MacLibraryView()
        case .pcs: MacPCsView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.metrics.isOnline && !vm.isDemoMode {
                HStack(spacing: 8) {
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(vm.metrics.isMuted ? .orange : .secondary)
                    Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100) { editing in
                        vm.isDraggingVolume = editing
                    }
                    .frame(width: 110)
                    .disabled(vm.metrics.volumeAvailable == false)
                    Text(vm.metrics.volumeAvailable == false ? "—" : "\(Int(vm.metrics.volume))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("PC volume")
            }
            Button {
                Task { await vm.refreshMetrics() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            Menu {
                Button("Lock PC", systemImage: "lock") { Task { await vm.sendAction("lock") } }
                Button("Sleep", systemImage: "moon") { Task { await vm.sendAction("sleep") } }
                Button("Restart…", systemImage: "arrow.clockwise") { pendingPower = .restart }
                Button("Shut Down…", systemImage: "power", role: .destructive) { pendingPower = .shutdown }
                Divider()
                Button("Toggle HDR", systemImage: "sun.max") { Task { await vm.sendAction("toggle_hdr") } }
                Button("Extend Display", systemImage: "display.2") { Task { await vm.sendAction("restore_display") } }
            } label: {
                Image(systemName: "power.circle")
            }
            .disabled(!vm.metrics.isOnline)
            .help("Power & display")
        }
    }
}

enum MacPowerConfirmation: String {
    case sleep, restart, shutdown
    var title: String {
        switch self {
        case .sleep: "Put your PC to sleep?"
        case .restart: "Restart your PC?"
        case .shutdown: "Shut down your PC?"
        }
    }
    var button: String {
        switch self {
        case .sleep: "Sleep PC"
        case .restart: "Restart PC"
        case .shutdown: "Shut Down PC"
        }
    }
    var message: String {
        self == .sleep ? "Wake-on-LAN must be enabled to wake the PC remotely." : "Save your open work on the PC before continuing."
    }
}
