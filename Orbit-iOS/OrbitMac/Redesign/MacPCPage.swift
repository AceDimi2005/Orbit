import MoonlightCore
import SwiftUI

/// What the PC page should show.
enum MacPCState: Equatable {
    case setup, demo, connecting, waking, online, locked, offline

    @MainActor
    init(vm: OrbitMacViewModel) {
        if vm.isDemoMode { self = .demo }
        else if vm.currentPC == nil { self = .setup }
        else if vm.metrics.isOnline { self = vm.metrics.sessionLocked == true ? .locked : .online }
        else if vm.isWaking { self = .waking }
        else if vm.connectionError != nil { self = .offline }
        else { self = .connecting }
    }

    var markStatus: OrbitMark.Status {
        switch self {
        case .online, .demo: return .online
        case .locked: return .locked
        case .connecting, .waking: return .working
        case .offline: return .offline
        case .setup: return .plain
        }
    }
}

/// The PC page: how the PC is doing in one sentence, the readings it reports, its sound,
/// what is using it and what it is. Everything else lives in the sidebar.
struct MacPCPage: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @ObservedObject var sunshine: MoonlightHostCoordinator
    /// False only for DEBUG snapshots: SwiftUI's image renderer draws nothing inside a ScrollView.
    var scrolls = true
    var managePCs: () -> Void
    @State private var showsCustomizer = false
    @State private var confirmsQuitGame = false
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared

    private var state: MacPCState { MacPCState(vm: vm) }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { page }
            } else {
                page
            }
        }
        .background(OrbitPalette.canvas)
        .sheet(isPresented: $showsCustomizer) { MacDashboardCustomizer().environmentObject(vm) }
        .confirmationDialog("Quit \(vm.metrics.activeGame ?? "the game")?", isPresented: $confirmsQuitGame, titleVisibility: .visible) {
            Button("Quit Game", role: .destructive) { Task { await vm.sendAction("kill_game") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit asks the game on \(vm.selectedPCName) to close. Unsaved progress may be lost.")
        }
        .task(id: "\(vm.selectedPCID)|\(vm.metrics.isOnline)|\(vm.isDemoMode)") {
            // "Using the Most" stays current while the page is open.
            guard vm.metrics.isOnline, !vm.isDemoMode else { return }
            while !Task.isCancelled {
                await vm.refreshProcesses()
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 34) {
            header
            MacPowerStatus()
            switch state {
            case .setup: setup
            case .connecting, .waking, .offline: unreachable
            case .online, .locked, .demo: online
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 44)
        .frame(maxWidth: 1080, alignment: .leading)
        .frame(maxWidth: .infinity)
        .animation(OrbitMotion.standard, value: state)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            OrbitMark(status: state.markStatus, size: 58)
                .padding(2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 16)
            headerAction
        }
    }

    private var headline: String {
        switch state {
        case .setup: return "No PC yet"
        case .demo, .online: return OrbitTakeaway(vm.metrics).headline
        case .connecting: return "Connecting…"
        case .waking: return "Waking up…"
        case .locked: return "Locked"
        case .offline: return "Asleep or off"
        }
    }

    private var detail: String {
        switch state {
        case .setup: return "Add a Windows PC to get started."
        case .demo: return "Sample data · nothing is sent to a PC"
        case .connecting: return "Reaching Orbit Companion on \(vm.currentPC?.address ?? "the PC")"
        case .waking: return "Sent the wake-up signal. This takes up to a minute."
        case .online, .locked:
            var parts = [state == .locked ? "Windows is locked" : "Online"]
            if vm.pingMs > 0 { parts.append("\(vm.pingMs) ms") }
            if vm.metrics.uptimeSeconds > 0 { parts.append("up \(OrbitFormat.duration(seconds: vm.metrics.uptimeSeconds))") }
            return parts.joined(separator: " · ")
        case .offline:
            let reach = canWake ? "Orbit can wake it over your network." : "Orbit can't reach it right now."
            guard let last = vm.lastUpdated else { return reach }
            return "Last update \(last.formatted(date: .omitted, time: .shortened)). \(reach)"
        }
    }

    private var canWake: Bool { !(vm.currentPC?.macAddress.isEmpty ?? true) }
    private var desktop: MoonlightApp? {
        guard !vm.isDemoMode, sunshine.isPaired, sunshine.reachable else { return nil }
        return sunshine.desktopApp
    }

    @ViewBuilder
    private var headerAction: some View {
        switch state {
        case .offline:
            Button {
                Task { await vm.wakePC() }
            } label: {
                Label("Wake PC", systemImage: "power")
            }
            .buttonStyle(MacHoverButtonStyle(prominent: true))
            .disabled(!canWake)
            .help(canWake ? "Send a Wake-on-LAN packet" : "Connect once while the PC is on so Orbit learns its network address")
        case .locked:
            Button {
                if let desktop { stream(desktop, unlock: true) } else { vm.selectedSection = .library }
            } label: {
                Label(desktop == nil ? "Set Up Unlock…" : "Unlock…", systemImage: "lock.open")
            }
            .buttonStyle(MacHoverButtonStyle(prominent: true))
            .help(desktop == nil
                  ? "Pair Orbit with Sunshine in Play to sign in from this Mac"
                  : "Opens the sign-in screen and types the password you enter, once. It's never saved.")
        case .demo:
            Button("Connect a PC…") {
                vm.setDemoMode(false)
                managePCs()
            }
            .buttonStyle(MacHoverButtonStyle(prominent: true))
        default:
            EmptyView()
        }
    }

    // MARK: Online

    @ViewBuilder
    private var online: some View {
        if let game = vm.metrics.activeGame, !game.isEmpty {
            nowPlaying(game)
        }
        rightNow
        // The volume lives in the toolbar on every page, so the PC page doesn't repeat it.
        HStack(alignment: .top, spacing: 16) {
            usingTheMost.frame(maxWidth: .infinity)
            thisPC.frame(maxWidth: .infinity)
        }
    }

    private func nowPlaying(_ game: String) -> some View {
        let app = desktop == nil ? nil : (sunshine.app(titled: game) ?? sunshine.desktopApp)
        return HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Playing Now")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(game)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            OrbitReading(label: "Frame Rate", value: vm.metrics.fps.flatMap { $0 > 0 && $0.isFinite ? String(Int($0.rounded())) : nil },
                         unit: "fps", valueSize: 30)
            OrbitReading(label: "Graphics", value: OrbitFormat.percent(vm.metrics.gpuUsage), unit: "%", valueSize: 30,
                         valueColor: OrbitPalette.load(vm.metrics.gpuUsage.map { $0 / 100 }))
            HStack(spacing: 10) {
                Button {
                    if let app { stream(app, unlock: false) } else { vm.selectedSection = .library }
                } label: {
                    Label("Stream", systemImage: "play.fill")
                }
                .buttonStyle(MacHoverButtonStyle(prominent: true))
                .disabled(vm.isDemoMode)
                Button("Quit Game…") { confirmsQuitGame = true }
                    .buttonStyle(MacHoverButtonStyle())
                    .disabled(vm.isDemoMode)
            }
        }
        .padding(20)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var shownMetrics: [MacMetric] {
        let chosen = vm.dashboardMetrics.isEmpty ? [.cpuLoad, .gpuLoad, .memory, .storage] : vm.dashboardMetrics
        return chosen.filter { OrbitVital($0, vm: vm).hasData }
    }

    private var rightNow: some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader("Right Now") {
                Button("Edit") { showsCustomizer = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("Choose and order the readings")
            }
            if vm.metrics.telemetryAvailable == false, !vm.isDemoMode {
                Text("Waiting for the first readings from the PC…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .orbitSurface(padding: 18, radius: 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(shownMetrics) { MacVitalTile(metric: $0) }
                }
                .animation(OrbitMotion.standard, value: shownMetrics)
            }
        }
    }

    // MARK: Using the most

    /// Busiest first (processor or graphics, whichever is higher), then the biggest in memory,
    /// so a quiet PC still lists what is holding its memory rather than a row of 0 %.
    private var topProcesses: [MacProcess] {
        func load(_ process: MacProcess) -> Int { Int(max(process.cpuPercent ?? 0, process.gpuPercent ?? 0).rounded()) }
        return Array(vm.processes.filter { ($0.cpuPercent ?? 0) > 0 || ($0.memoryMB ?? 0) > 0 }
            .sorted { (load($0), $0.memoryMB ?? -1) > (load($1), $1.memoryMB ?? -1) }
            .prefix(4))
    }

    private var usingTheMost: some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader("Using the Most") {
                Button("Activity") { vm.selectedSection = .processes }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(vm.isDemoMode)
            }
            VStack(spacing: 0) {
                if topProcesses.isEmpty {
                    Text(vm.isDemoMode ? "Activity is not part of the demo." : (vm.isLoadingProcesses ? "Reading processes…" : "Nothing is busy right now."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(topProcesses.enumerated()), id: \.element.id) { index, process in
                        if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                        MacProcessSummaryRow(process: process)
                    }
                }
            }
            .orbitSurface(padding: 18, radius: 20)
        }
    }

    // MARK: This PC

    private var thisPC: some View {
        VStack(alignment: .leading, spacing: 14) {
            OrbitSectionHeader("This PC")
            VStack(spacing: 0) {
                ForEach(Array(specRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                    specCell(row)
                }
            }
            .orbitSurface(padding: 18, radius: 20)
        }
    }

    private var specRows: [(String, String)] {
        let m = vm.metrics
        var rows: [(String, String)] = []
        if let specs = vm.specs {
            rows.append(("Processor", specs.cpu.name ?? m.cpuName))
            rows.append(("Graphics", join([gpu(in: specs)?.name ?? m.gpuName, gpu(in: specs)?.vramGB.map { "\(OrbitFormat.gigabytes($0, digits: 0) ?? "") GB" }])))
            rows.append(("Memory", join([specs.memory.totalGB.map { "\(OrbitFormat.gigabytes($0, digits: 0) ?? "") GB" }, specs.memory.modules.first?.speedMHz.map { "\(Int($0)) MHz" }])))
            rows.append(("Storage", specs.disks.compactMap(\.name).prefix(2).joined(separator: ", ")))
            rows.append(("Motherboard", join([specs.motherboard.manufacturer.map(Self.shortVendor), specs.motherboard.model])))
            rows.append(("Windows", Self.windows(name: specs.osName, version: specs.osVersion)))
        } else {
            rows.append(("Processor", m.cpuName))
            rows.append(("Graphics", m.gpuName))
            if m.ramTotalGB > 0 { rows.append(("Memory", "\(OrbitFormat.gigabytes(m.ramTotalGB, digits: 0) ?? "") GB")) }
        }
        if let version = m.agentVersion, !vm.isDemoMode { rows.append(("Orbit Companion", version)) }
        return rows.filter { !$0.1.isEmpty }
    }

    /// The graphics card the readings come from, not a virtual display adapter listed first.
    private func gpu(in specs: MacPCSpecs) -> MacPCSpecs.GPU? {
        let live = vm.metrics.gpuName.lowercased()
        if let match = specs.gpus.first(where: { ($0.name ?? "").lowercased() == live }) { return match }
        return specs.gpus.max { ($0.vramGB ?? 0) < ($1.vramGB ?? 0) } ?? specs.gpus.first
    }

    /// "ASUSTeK COMPUTER INC." reads as "ASUS" everywhere else.
    static func shortVendor(_ name: String) -> String {
        let known = ["asustek": "ASUS", "micro-star": "MSI", "gigabyte": "GIGABYTE", "asrock": "ASRock",
                     "dell": "Dell", "hewlett": "HP", "lenovo": "Lenovo", "nzxt": "NZXT"]
        let lower = name.lowercased()
        return known.first { lower.contains($0.key) }?.value ?? name
    }

    /// "Microsoft Windows 11 Pro" + "10.0.26300" → "Windows 11 Pro (build 26300)".
    static func windows(name: String?, version: String?) -> String {
        let product = (name ?? "").replacingOccurrences(of: "Microsoft ", with: "")
        let build = version?.split(separator: ".").last.map(String.init)
        guard let build, !build.isEmpty else { return product }
        return product.isEmpty ? "Build \(build)" : "\(product) (build \(build))"
    }

    private func specCell(_ row: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.0)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(row.1)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 10)
    }

    private func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Setup & unreachable

    private var setup: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Your PC, from your Mac")
                    .font(.title.weight(.semibold))
                Text("Install Orbit Companion on your Windows PC, then pair with the code it shows. PCs you added on your iPhone appear here through iCloud.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Pair a PC…", action: managePCs)
                    .buttonStyle(MacHoverButtonStyle(prominent: true))
                Button("Try the Demo") { vm.setDemoMode(true) }
                    .buttonStyle(MacHoverButtonStyle())
            }
            .padding(.top, 4)
            Link("Download Orbit Companion for Windows", destination: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!)
                .font(.callout)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private var unreachable: some View {
        if state == .offline {
            VStack(alignment: .leading, spacing: 10) {
                Text("Is Orbit Companion running on the PC?")
                    .font(.headline)
                Text(vm.connectionError ?? "Orbit could not reach it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Try Again") { Task { await vm.refreshMetrics() } }
                        .buttonStyle(MacHoverButtonStyle())
                    Button("Manage PCs…", action: managePCs)
                        .buttonStyle(MacHoverButtonStyle())
                }
                .padding(.top, 4)
            }
            .orbitSurface(padding: 20, radius: 20)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    // MARK: Streaming

    private func stream(_ app: MoonlightApp, unlock: Bool) {
        MoonlightStreamController.shared.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName,
                                                     settings: streamSettings.settings, promptUnlock: unlock))
        openWindow(id: "stream")
    }
}

/// A process in a short list: its Windows icon, name, processor share and memory.
struct MacProcessSummaryRow: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var process: MacProcess

    var body: some View {
        HStack(spacing: 12) {
            OrbitAppIconView(store: vm.appIcons, iconID: process.iconID, size: 22) {
                OrbitIconMonogram(name: process.name, size: 22)
            }
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(process.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .fontWeight(.semibold)
                .orbitLiveNumber()
                .frame(minWidth: 40, alignment: .trailing)
            Text(process.memoryMB.map { $0 >= 1024 ? String(format: "%.1f GB", $0 / 1024) : "\(Int($0)) MB" } ?? "—")
                .foregroundStyle(.secondary)
                .orbitLiveNumber()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
