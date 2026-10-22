import MoonlightCore
import SwiftUI

/// Main window: the PC switcher and Orbit's places in the sidebar, the chosen place on the
/// right. The same places as on iPhone (PC, Play, Files), with the tools the iPhone opens
/// from its PC tab given their own room.
struct MacRootView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingPower: MacPowerConfirmation?
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @ObservedObject private var stream = MoonlightStreamController.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 212, ideal: 232, max: 290)
        } detail: {
            detail
                .id(vm.selectedSection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OrbitPalette.canvas)
                .navigationTitle(vm.selectedSection.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
        }
        .animation(OrbitMotion.quick, value: vm.selectedSection)
        .task(id: sunshineKey) { await syncSunshine() }
        .onChange(of: vm.metrics.sessionLocked, initial: true) { _, locked in stream.pcLocked = locked == true }
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

    private var subtitle: String {
        if vm.selectedSection == .pcs { return "" }
        return vm.isDemoMode ? "Demo" : (vm.currentPC?.name ?? "No PC yet")
    }

    // MARK: Sunshine

    /// One Sunshine connection for the whole window: the PC page (unlock, now playing) and
    /// Play share it, so pairing and the library are never fetched twice.
    private var sunshineKey: String {
        "\(vm.selectedPCID)|\(vm.currentPC?.address ?? "")|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)|\(vm.isDemoMode)"
    }

    private func syncSunshine() async {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return }
        sunshine.configure(pcID: pc.id, address: pc.address, httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(vm.selectedSection) }, set: { if let value = $0 { vm.selectedSection = value } })) {
            Section {
                MacPCSwitcher()
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
                ForEach(MacSection.mainGroup) { row($0) }
            }
            Section("Control") {
                ForEach(MacSection.controlGroup) { row($0) }
            }
            Section("Monitor") {
                ForEach(MacSection.monitorGroup) { row($0) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: MacSection) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(section.title)
                Spacer(minLength: 4)
                badge(for: section)
            }
        } icon: {
            Image(systemName: section.symbol)
        }
        .tag(section)
    }

    @ViewBuilder
    private func badge(for section: MacSection) -> some View {
        switch section {
        case .preview where vm.isStreaming:
            Text("Live").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        case .library where stream.isPresented:
            Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
        case .sessions where vm.historyList?.activeSession != nil:
            Circle().fill(OrbitPalette.critical).frame(width: 6, height: 6)
                .accessibilityLabel("Recording")
        case .files where vm.transfer != nil:
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch vm.selectedSection {
        case .overview: MacPCPage(sunshine: sunshine) { vm.selectedSection = .pcs }
        case .library: MacLibraryView(sunshine: sunshine)
        case .files: MacFilesView()
        case .remote: MacRemoteView()
        case .preview: MacPreviewView()
        case .audio: MacAudioView()
        case .clipboard: MacClipboardView()
        case .processes: MacProcessesView()
        case .sessions:
            if OrbitProStore.shared.isProUnlocked { MacSessionsView() } else { MacProLockedPage(title: "History", message: "Recorded sessions with frame rate, temperature and power graphs are part of Orbit Pro.") }
        case .pcs: MacPCsView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.metrics.isOnline && !vm.isDemoMode {
                HStack(spacing: 8) {
                    Button {
                        Task { await vm.sendAction("mute") }
                    } label: {
                        Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(vm.metrics.isMuted ? OrbitPalette.warm : .secondary)
                    .help(vm.metrics.isMuted ? "Unmute the PC (⇧⌘M)" : "Mute the PC (⇧⌘M)")
                    Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100) { editing in
                        vm.isDraggingVolume = editing
                    }
                    .frame(width: 110)
                    .disabled(vm.metrics.volumeAvailable == false)
                    .accessibilityLabel("PC volume")
                }
                .padding(.horizontal, 6)
            }
            Button {
                Task { await vm.refreshMetrics() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            Menu {
                if vm.metrics.isOnline {
                    Button("Lock", systemImage: "lock") { Task { await vm.sendAction("lock") } }
                    Button("Turn On Display", systemImage: "display") { Task { await vm.sendAction("restore_display") } }
                    Button("Toggle HDR", systemImage: "sun.max") { Task { await vm.sendAction("toggle_hdr") } }
                    Divider()
                    Button("Sleep…", systemImage: "moon") { pendingPower = .sleep }
                    Button("Restart…", systemImage: "arrow.clockwise") { pendingPower = .restart }
                    Button("Shut Down…", systemImage: "power", role: .destructive) { pendingPower = .shutdown }
                } else {
                    Button(vm.isWaking ? "Waking…" : "Wake PC", systemImage: "power") { Task { await vm.wakePC() } }
                        .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty != false)
                }
            } label: {
                Label("Power", systemImage: "power")
            }
            .disabled(vm.currentPC == nil || vm.isDemoMode)
            .help("Power")
        }
    }
}

/// The PC at the top of the sidebar: its state at a glance, and a menu to switch PCs,
/// add one or manage them.
struct MacPCSwitcher: View {
    @EnvironmentObject var vm: OrbitMacViewModel

    private var state: MacPCState { MacPCState(vm: vm) }

    private var status: String {
        switch state {
        case .setup: return "Not paired"
        case .demo: return "Demo"
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        case .locked: return "Locked"
        case .offline: return "Offline"
        case .online: return OrbitTakeaway(vm.metrics).headline
        }
    }

    var body: some View {
        Menu {
            if !vm.savedPCs.isEmpty {
                Section {
                    ForEach(vm.savedPCs) { pc in
                        Button {
                            vm.selectPC(pc)
                        } label: {
                            if pc.id == vm.selectedPCID && !vm.isDemoMode { Label(pc.name, systemImage: "checkmark") } else { Text(pc.name) }
                        }
                    }
                }
            }
            Button("Add PC…") { vm.selectedSection = .pcs }
            if !vm.savedPCs.isEmpty {
                Button("Manage PCs…") { vm.selectedSection = .pcs }
            }
            Divider()
            Toggle("Demo Mode", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
        } label: {
            HStack(spacing: 10) {
                OrbitMark(status: state.markStatus, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.isConfigured ? vm.selectedPCName : "No PC yet")
                        .font(.headline)
                        .lineLimit(1)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(vm.selectedSection == .pcs ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch PCs")
        .accessibilityLabel("\(vm.isConfigured ? vm.selectedPCName : "No PC yet"), \(status)")
        .accessibilityHint("Switch, add or manage PCs")
    }
}

enum MacPowerConfirmation: String {
    case sleep, restart, shutdown
    var title: String {
        switch self {
        case .sleep: "Put the PC to sleep?"
        case .restart: "Restart the PC?"
        case .shutdown: "Shut down the PC?"
        }
    }
    var button: String {
        switch self {
        case .sleep: "Sleep"
        case .restart: "Restart"
        case .shutdown: "Shut Down"
        }
    }
    var message: String {
        self == .sleep ? "You can wake it again from Orbit." : "Unsaved work in open apps on the PC may be lost."
    }
}

// MARK: - Orbit Pro locked page

struct MacProLockedPage: View {
    let title: String
    let message: String
    @Environment(\.macTheme) private var theme
    @State private var showsPaywall = false

    var body: some View {
        VStack(spacing: 14) {
            OrbitMark(status: .plain, size: 44, tint: .secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Unlock Orbit Pro…") { showsPaywall = true }
                .buttonStyle(MacHoverButtonStyle(prominent: true))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsPaywall) { OrbitProUnlockView(accent: theme.accent) { showsPaywall = false } }
    }
}
