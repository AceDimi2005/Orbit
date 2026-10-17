import SwiftUI

struct ContentView: View {
    @StateObject private var vm = OrbitViewModel()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(vm: vm)
                .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            GameLibraryView(vm: vm)
                .tabItem { Label("Library", systemImage: "gamecontroller.fill") }
                .tag(1)
            NavigationStack { PCFilesView(vm: vm) }
                .tabItem { Label("Files", systemImage: "folder.fill") }
                .tag(4)
            QuickRemoteView(vm: vm)
                .tabItem { Label("Remote", systemImage: "computermouse.fill") }
                .tag(2)
            CompanionToolsView(vm: vm)
                .tabItem { Label("Tools", systemImage: "square.stack.3d.up.fill") }
                .tag(3)
        }
        .orbitAppearance()
        .preferredColorScheme(.dark)
        .overlay {
            if vm.smartLaunchStep != .idle {
                SmartLaunchOverlay(vm: vm)
            }
        }
        .fullScreenCover(isPresented: $vm.isShowingStreamView) {
            MoonlightStreamView(vm: vm)
        }
        .sheet(isPresented: $vm.showOnboarding) {
            OnboardingView(vm: vm)
                .interactiveDismissDisabled(!vm.hasCompletedOnboarding)
        }
        .sheet(isPresented: $vm.isShowingIPConfigSheet) {
            SettingsView(vm: vm, isPresentedAsSheet: true)
        }
        .onAppear {
            vm.setAppActive(scenePhase == .active)
            if !vm.hasCompletedOnboarding { vm.showOnboarding = true }
        }
        .onChange(of: scenePhase) { _, phase in vm.setAppActive(phase == .active) }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "orbit" else { return }
            switch url.host?.lowercased() {
            case "remote": selectedTab = 2
            case "library": selectedTab = 1
            case "settings": selectedTab = 3
            case "files": selectedTab = 4
            case "wake":
                selectedTab = 0
                Task { await vm.wakePC() }
            case "shutdown":
                selectedTab = 0
                Task { await vm.sendPowerAction("shutdown") }
            case "sleep":
                selectedTab = 0
                Task { await vm.sendPowerAction("sleep") }
            case "restart":
                selectedTab = 0
                Task { await vm.sendPowerAction("restart") }
            default: selectedTab = 0
            }
        }
    }
}

// MARK: - Overview

struct DashboardView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var pendingAction: PowerConfirmation?
    @State private var isShowingCustomization = false
    @State private var isShowingPCs = false
    @State private var isShowingDiscovery = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : vm.dashboardConfiguration.columnCount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if vm.isDemoMode { previewNotice }
                        computerHeader
                        if vm.metrics.isOnline {
                            if vm.dashboardConfiguration.showsGame, let game = vm.metrics.activeGame { activeGameCard(game) }
                            if vm.metrics.telemetryAvailable == false {
                                OrbitNotice(title: "Syncing sensors…", message: "Collecting initial readings from your PC.", icon: "waveform.path.ecg")
                            } else {
                                metricsGrid
                            }
                            if vm.dashboardConfiguration.showsVolume { volumeCard }
                            if vm.dashboardConfiguration.showsQuickControls { powerCard }
                            if vm.dashboardConfiguration.showsSpecifications { specsLink }
                        } else {
                            offlineCard
                            if vm.dashboardConfiguration.showsSpecifications { specsLink }
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await vm.refreshMetrics() }
            }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        vm.toggleDynamicIsland()
                    } label: {
                        Image(systemName: vm.isDynamicIslandActive ? "capsule.portrait.tophalf.filled" : "waveform.path.ecg")
                            .foregroundStyle(vm.isDynamicIslandActive ? .mint : .primary)
                    }
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                    .accessibilityLabel(vm.isDynamicIslandActive ? "Stop Live Activity" : "Start Live Activity")

                    Menu {
                        Section("PC Connection") {
                            ForEach(vm.savedPCs) { pc in
                                Button {
                                    vm.selectPC(pc)
                                } label: {
                                    Label(pc.name, systemImage: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                                }
                            }
                            Button { isShowingDiscovery = true } label: {
                                Label("Pair New PC…", systemImage: "dot.radiowaves.left.and.right")
                            }
                            Button { isShowingPCs = true } label: {
                                Label("Manage PCs…", systemImage: "list.bullet")
                            }
                        }

                        Section("Dashboard Layout") {
                            Menu("Presets") {
                                Button("Balanced") { vm.dashboardConfiguration = .balanced }
                                Button("Gaming") { vm.dashboardConfiguration = .gaming }
                                Button("Workstation") { vm.dashboardConfiguration = .workstation }
                                Button("Cooling") { vm.dashboardConfiguration = .cooling }
                                Button("All Metrics") { vm.dashboardConfiguration = .allMetrics }
                            }
                            Button { isShowingCustomization = true } label: {
                                Label("Customize Cards…", systemImage: "slider.horizontal.3")
                            }
                        }

                        Section("Quick Actions") {
                            Button {
                                vm.toggleDynamicIsland()
                            } label: {
                                Label(vm.isDynamicIslandActive ? "Stop Live Activity" : "Start Live Activity", systemImage: "capsule.portrait.tophalf.filled")
                            }
                            .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)

                            Button { vm.openDesktopPreview() } label: {
                                Label("Desktop Preview", systemImage: "display")
                            }
                            .disabled(!vm.metrics.isOnline)

                            Menu("Power") {
                                Button("Lock PC", systemImage: "lock") { Task { await vm.sendPowerAction("lock") } }
                                Button("Wake Display", systemImage: "display") { Task { await vm.sendPowerAction("restore_display") } }
                                Divider()
                                Button("Sleep", systemImage: "moon") { pendingAction = .sleep }
                                Button("Restart", systemImage: "arrow.clockwise") { pendingAction = .restart }
                                Button("Shut Down", systemImage: "power", role: .destructive) { pendingAction = .shutdown }
                            }
                            .disabled(!vm.metrics.isOnline)
                        }

                        Divider()
                        Button { vm.isShowingIPConfigSheet = true } label: {
                            Label("Settings…", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Dashboard Menu")
                }
            }
            .sheet(isPresented: $isShowingCustomization) {
                DashboardCustomizationView(vm: vm)
            }
            .sheet(isPresented: $isShowingPCs) { NavigationStack { PCProfilesView(vm: vm) } }
            .sheet(isPresented: $isShowingDiscovery) { PCDiscoveryView(vm: vm) }
            .confirmationDialog(pendingAction?.title ?? "Confirm action", isPresented: Binding(
                get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
            ), titleVisibility: .visible) {
                if let action = pendingAction {
                    Button(action.button, role: .destructive) {
                        pendingAction = nil
                        Task { await vm.sendPowerAction(action.rawValue) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            } message: {
                Text(pendingAction?.message ?? "")
            }
        }
    }

    private var previewNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo Mode · Sample data")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Connect PC") {
                vm.setDemoMode(false)
                isShowingDiscovery = true
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16, tint: .orange)
    }

    private var computerHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill((vm.metrics.isOnline ? theme.accent : .secondary).opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(vm.metrics.isOnline ? theme.accent : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(vm.savedPCs) { pc in
                        Button {
                            vm.selectPC(pc)
                        } label: {
                            Label(pc.name, systemImage: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                        }
                    }
                    Divider()
                    Button { isShowingDiscovery = true } label: {
                        Label("Pair New PC…", systemImage: "plus.circle")
                    }
                    Button { isShowingPCs = true } label: {
                        Label("Manage PCs…", systemImage: "list.bullet")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(vm.isConfigured || vm.isDemoMode ? vm.metrics.hostname : "Select PC")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.metrics.isOnline ? Color.mint : .orange)
                        .frame(width: 7, height: 7)
                    Text(vm.isDemoMode ? "Demo" : (vm.metrics.isOnline ? "\(vm.pingMs) ms" : "Offline"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if vm.metrics.isOnline && vm.metrics.telemetryAvailable != false {
                        Text("· \(vm.metrics.formattedUptime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            if vm.metrics.isOnline {
                Button {
                    isShowingCustomization = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.07), in: Circle())
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Customize cards")
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, tint: theme.accent)
    }

    @ViewBuilder
    private var metricsGrid: some View {
        if vm.dashboardConfiguration.orderedVisibleMetrics.isEmpty {
            Button { isShowingCustomization = true } label: {
                OrbitNotice(title: "No cards selected", message: "Tap to choose hardware metrics.", icon: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(vm.dashboardConfiguration.orderedVisibleMetrics) { metric in
                    metricCard(metric)
                }
            }
        }
    }

    @ViewBuilder
    private func metricCard(_ metric: DashboardMetric) -> some View {
        switch metric {
        case .cpuLoad:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                valueText: percent(vm.metrics.cpuUsage), progress: vm.metrics.cpuUsage / 100,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.cpuTemp.map { "\(Int($0))°C" }
            )
        case .gpuLoad:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                valueText: vm.metrics.gpuUsage.map(percent) ?? "—", progress: vm.metrics.gpuUsage.map { $0 / 100 },
                icon: metric.symbol, accent: metric.accent, detail: gpuDetail
            )
        case .memory:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("memory", detected: "System RAM"),
                valueText: vm.metrics.ramTotalGB > 0 ? "\(decimal(vm.metrics.ramUsedGB)) GB" : "—",
                progress: vm.metrics.ramTotalGB > 0 ? vm.metrics.ramUsedGB / vm.metrics.ramTotalGB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ramTotalGB > 0 ? "of \(decimal(vm.metrics.ramTotalGB, digits: 0)) GB" : nil
            )
        case .storage:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("storage", detected: vm.specs?.disks.first?.name ?? "System Drive"),
                valueText: vm.metrics.ssdTotalTB > 0 ? "\(decimal(vm.metrics.ssdUsedTB, digits: 2)) TB" : "—",
                progress: vm.metrics.ssdTotalTB > 0 ? vm.metrics.ssdUsedTB / vm.metrics.ssdTotalTB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ssdTotalTB > 0 ? "of \(decimal(vm.metrics.ssdTotalTB, digits: 2)) TB" : nil
            )
        case .vram:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                valueText: vm.metrics.vramUsedGB.map { "\(decimal($0)) GB" } ?? "—",
                progress: vramProgress, icon: metric.symbol, accent: metric.accent,
                detail: vramDetail
            )
        case .cpuPower:
            sensorCard(metric, value: vm.metrics.cpuPowerWatts, unit: "W",
                       subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                       detail: "Package power",
                       progress: vm.metrics.cpuPowerWatts.map { min(max($0 / 200.0, 0.04), 1) })
        case .gpuPower:
            sensorCard(metric, value: vm.metrics.gpuPowerWatts, unit: "W",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                       detail: "Board power",
                       progress: vm.metrics.gpuPowerWatts.map { min(max($0 / 400.0, 0.04), 1) })
        case .cpuTemperature:
            sensorCard(metric, value: vm.metrics.cpuTemp, unit: "°C",
                       subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                       detail: "Core sensor",
                       progress: vm.metrics.cpuTemp.map { min(max(($0 - 25.0) / 70.0, 0.05), 1) })
        case .gpuTemperature:
            sensorCard(metric, value: vm.metrics.gpuTemp, unit: "°C",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                       detail: "GPU thermal",
                       progress: vm.metrics.gpuTemp.map { min(max(($0 - 25.0) / 70.0, 0.05), 1) })
        case .coolantTemperature:
            sensorCard(metric, value: vm.metrics.liquidTemp, unit: "°C",
                       subtitle: vm.componentName("cooler", detected: vm.metrics.coolerName),
                       detail: "Coolant loop",
                       progress: vm.metrics.liquidTemp.map { min(max(($0 - 20.0) / 30.0, 0.05), 1) })
        case .cpuClock:
            HardwareMetricCard(title: metric.title, subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                               valueText: vm.metrics.cpuClockMHz.map { "\(decimal($0 / 1000, digits: 2)) GHz" } ?? "—",
                               progress: vm.metrics.cpuClockMHz.map { min(max($0 / 5800.0, 0.1), 1) },
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.cpuClockSource)
        case .network:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.networkInterface ?? "Network",
                               valueText: transferRate(vm.metrics.networkDownloadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.networkUploadMBps.map { "↑ \(transferRate($0))" })
        case .diskActivity:
            HardwareMetricCard(title: metric.title, subtitle: "Disk Throughput",
                               valueText: transferRate(vm.metrics.diskReadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.diskWriteMBps.map { "W: \(transferRate($0))" })
        case .uptime:
            HardwareMetricCard(title: metric.title, subtitle: "Active session",
                               valueText: vm.metrics.formattedUptime, progress: nil,
                               icon: metric.symbol, accent: metric.accent, detail: nil)
        case .fps:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.activeGame ?? "No active game",
                               valueText: vm.metrics.fps.map { "\(Int($0.rounded())) FPS" } ?? "—",
                               progress: vm.metrics.fps.map { min(max($0 / 165.0, 0.05), 1) },
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.fpsSource)
        case .cpuFan:
            sensorCard(metric, value: vm.metrics.cpuFanRPM, unit: "RPM", subtitle: "CPU Cooler", detail: nil,
                       progress: vm.metrics.cpuFanRPM.map { min(max($0 / 2400.0, 0.05), 1) })
        case .gpuFan:
            sensorCard(metric, value: vm.metrics.gpuFanPercent, unit: "%", subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName), detail: nil,
                       progress: vm.metrics.gpuFanPercent.map { min(max($0 / 100.0, 0), 1) })
        }
    }

    private func sensorCard(_ metric: DashboardMetric, value: Double?, unit: String, subtitle: String, detail: String?, progress: Double? = nil) -> some View {
        HardwareMetricCard(
            title: metric.title,
            subtitle: subtitle,
            valueText: value.map { "\(Int($0.rounded()))\(unit == "°C" || unit == "%" ? "" : " ")\(unit)" } ?? "—",
            progress: progress,
            icon: metric.symbol,
            accent: metric.accent,
            detail: value == nil ? nil : detail
        )
    }

    private var vramProgress: Double? {
        guard let used = vm.metrics.vramUsedGB, let total = vm.metrics.vramTotalGB, total > 0 else { return nil }
        return used / total
    }

    private var vramDetail: String? {
        guard vm.metrics.vramUsedGB != nil else { return nil }
        if let total = vm.metrics.vramTotalGB, total > 0 { return "of \(decimal(total)) GB" }
        return nil
    }

    private func transferRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1 { return "\(decimal(value)) MB/s" }
        if value >= 0.001 { return "\(decimal(value * 1000, digits: 1)) KB/s" }
        return "\(decimal(value * 1_000_000, digits: 0)) B/s"
    }

    private var gpuDetail: String? {
        var parts: [String] = []
        if let temperature = vm.metrics.gpuTemp { parts.append("\(Int(temperature))°C") }
        if let watts = vm.metrics.gpuPowerWatts { parts.append("\(Int(watts)) W") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func activeGameCard(_ title: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.mint.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.mint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("PLAYING NOW")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.mint)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let fps = vm.metrics.fps {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(fps.rounded()))")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.mint)
                    Text("FPS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 20, tint: .mint)
    }

    private var specsLink: some View {
        NavigationLink { FullSpecsView(vm: vm) } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: "cpu").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                }
                Text("Hardware Specifications")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(15)
            .liquidGlass(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var volumeCard: some View {
        HStack(spacing: 12) {
            Button {
                Task { await vm.sendPowerAction("mute") }
            } label: {
                ZStack {
                    Circle()
                        .fill((vm.metrics.isMuted ? Color.orange : theme.accent).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(vm.metrics.isMuted ? .orange : theme.accent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.metrics.isMuted ? "Unmute PC" : "Mute PC")

            Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                vm.isDraggingVolume = editing
            }
            .accessibilityLabel("PC volume")

            Text(vm.metrics.volumeAvailable == false ? "—" : (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%"))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .liquidGlass(cornerRadius: 20)
        .disabled(!vm.metrics.isOnline || vm.metrics.volumeAvailable == false)
    }

    private var powerCard: some View {
        HStack(spacing: 10) {
            controlButton("Lock", icon: "lock.fill") { Task { await vm.sendPowerAction("lock") } }
            controlButton("Display", icon: "display") { Task { await vm.sendPowerAction("restore_display") } }
            controlButton("Preview", icon: "rectangle.on.rectangle") { vm.openDesktopPreview() }
            Menu {
                Button("Sleep", systemImage: "moon.fill") { pendingAction = .sleep }
                Button("Restart", systemImage: "arrow.clockwise") { pendingAction = .restart }
                Button("Shut Down", systemImage: "power", role: .destructive) { pendingAction = .shutdown }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                    Text("Power").font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 20)
        .disabled(!vm.metrics.isOnline)
    }

    private func controlButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var offlineCard: some View {
        VStack(spacing: 18) {
            Button {
                Task { await vm.wakePC() }
            } label: {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.10)).frame(width: 96, height: 96)
                    Circle().strokeBorder(theme.accent.opacity(0.25), lineWidth: 1.2).frame(width: 96, height: 96)
                    if vm.isWakingUp {
                        ProgressView().controlSize(.large).orbitAppearance()
                    } else {
                        Image(systemName: "power").font(.system(size: 32, weight: .medium)).foregroundStyle(theme.accent)
                    }
                }
            }
            .disabled(vm.isWakingUp || !vm.isConfigured || vm.pcMAC.isEmpty)
            .accessibilityLabel("Wake PC")

            VStack(spacing: 4) {
                Text(vm.isWakingUp ? "Waking PC…" : (vm.isConfigured ? "PC Offline" : "Pair Your PC"))
                    .font(.headline.weight(.bold))
                Text(vm.isConfigured ? "Tap power to send Wake-on-LAN or reconnect." : "Connect over your local network with a 6-digit code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Find PC", systemImage: "dot.radiowaves.left.and.right") { isShowingDiscovery = true }
                    .buttonStyle(.borderedProminent).orbitAppearance().foregroundStyle(.black)
                if vm.isConfigured {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await vm.connect() } }
                        .buttonStyle(.bordered)
                } else {
                    ShareLink(
                        item: URL(string: "https://github.com/AceDimi2005/Orbit")!,
                        subject: Text("Orbit PC Companion for Windows"),
                        message: Text("Download the Orbit PC Companion for Windows here: https://github.com/AceDimi2005/Orbit")
                    ) {
                        Label("Get PC App", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .liquidGlass(tint: theme.accent)
    }
}

// MARK: - Dashboard customization

struct DashboardCustomizationView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DashboardConfiguration

    init(vm: OrbitViewModel) {
        self.vm = vm
        _draft = State(initialValue: vm.dashboardConfiguration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetButton("Balanced", icon: "square.grid.2x2", configuration: .balanced)
                            presetButton("Gaming", icon: "gamecontroller", configuration: .gaming)
                            presetButton("Work", icon: "hammer", configuration: .workstation)
                            presetButton("Cooling", icon: "fanblades", configuration: .cooling)
                            presetButton("All", icon: "rectangle.grid.3x2", configuration: .allMetrics)
                        }
                    }
                    .padding(.vertical, 4)

                    Picker("Grid Layout", selection: $draft.columnCount) {
                        Text("1 Column").tag(1)
                        Text("2 Columns").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(draft.metricOrder) { metric in
                        HStack(spacing: 12) {
                            Image(systemName: metric.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(metric.accent)
                                .frame(width: 28, height: 32)
                            Text(metric.title)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 4)
                            Button {
                                draft.setVisible(metric, !draft.visibleMetrics.contains(metric))
                            } label: {
                                Image(systemName: draft.visibleMetrics.contains(metric) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(draft.visibleMetrics.contains(metric) ? Color.cyan : .secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { source, destination in draft.metricOrder.move(fromOffsets: source, toOffset: destination) }
                } header: {
                    HStack {
                        Text("Cards")
                        Spacer()
                        Text("\(draft.orderedVisibleMetrics.count) active")
                    }
                }

                Section("Sections") {
                    Toggle("Active Game Banner", isOn: $draft.showsGame)
                    Toggle("Volume Slider", isOn: $draft.showsVolume)
                    Toggle("Quick Power Bar", isOn: $draft.showsQuickControls)
                    Toggle("Hardware Specs Link", isOn: $draft.showsSpecifications)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        vm.dashboardConfiguration = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }

    private func presetButton(_ title: String, icon: String, configuration: DashboardConfiguration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { draft = configuration }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline.weight(.semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(width: 76, height: 62)
            .foregroundStyle(draft == configuration ? Color.cyan : .primary)
            .background(draft == configuration ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(draft == configuration ? Color.cyan.opacity(0.4) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.borderless)
    }
}

private extension DashboardMetric {
    var accent: Color {
        switch self {
        case .cpuLoad, .cpuTemperature, .cpuClock, .cpuFan: return .cyan
        case .gpuLoad, .gpuTemperature, .gpuFan, .fps: return .mint
        case .memory, .vram: return Color(red: 0.68, green: 0.65, blue: 0.98)
        case .storage, .diskActivity, .cpuPower, .gpuPower: return Color(red: 0.97, green: 0.73, blue: 0.44)
        case .coolantTemperature, .network, .uptime: return Color(red: 0.48, green: 0.72, blue: 1)
        }
    }
}

private enum PowerConfirmation: String {
    case sleep, restart, shutdown
    var title: String {
        switch self {
        case .sleep: return "Put your PC to sleep?"
        case .restart: return "Restart your PC?"
        case .shutdown: return "Shut down your PC?"
        }
    }
    var button: String {
        switch self {
        case .sleep: return "Sleep PC"
        case .restart: return "Restart PC"
        case .shutdown: return "Shut down PC"
        }
    }
    var message: String {
        self == .sleep ? "Wake-on-LAN must be enabled to wake the PC remotely." : "Save your open work on the PC before continuing."
    }
}

// MARK: - Library

struct GameLibraryView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var searchText = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var filteredGames: [SunshineGame] {
        searchText.isEmpty ? vm.games : vm.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !vm.metrics.isOnline {
                            OrbitNotice(title: "PC Offline", message: "Connect or wake your PC to launch Sunshine apps.", icon: "wifi.slash", tint: .orange)
                        }
                        if filteredGames.isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? "No Sunshine Apps" : "No Matches",
                                systemImage: "gamecontroller",
                                description: Text(searchText.isEmpty ? "Apps configured in Sunshine on your PC appear here automatically." : "Try a different search term.")
                            )
                            .padding(.vertical, 36)
                        } else {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                                spacing: 14
                            ) {
                                ForEach(filteredGames) { game in
                                    GameCoverCard(game: game) { Task { await vm.smartLaunch(game: game) } }
                                        .disabled(!vm.metrics.isOnline)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await vm.fetchSunshineApps() }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search games & apps")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.fetchSunshineApps() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!vm.metrics.isOnline)
                    .accessibilityLabel("Refresh library")

                    Menu {
                        Button("Open Moonlight", systemImage: "arrow.up.forward.app") {
                            vm.openNativeMoonlight()
                        }
                        Button("Desktop Preview", systemImage: "display") {
                            vm.openDesktopPreview()
                        }
                        .disabled(!vm.metrics.isOnline)
                        Divider()
                        Toggle("Auto-Open Moonlight on Launch", isOn: $vm.autoOpenMoonlight)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Library Menu")
                }
            }
        }
    }
}

struct GameCoverCard: View {
    let game: SunshineGame
    let onLaunch: () -> Void

    var body: some View {
        Button(action: onLaunch) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: game.accentHex).opacity(0.28), Color(hex: game.accentHex).opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: game.iconSymbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color(hex: game.accentHex))
                }
                .frame(height: 100)
                Text(game.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                HStack {
                    Text("Launch")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Launch \(game.title) on PC")
    }
}

// MARK: - Remote

struct QuickRemoteView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var keyboardInput = ""
    @State private var lastDragLocation: CGPoint?
    @State private var lastSentTime: Date = .distantPast
    @State private var accumulatedDX = 0.0
    @State private var accumulatedDY = 0.0
    @State private var confirmCloseApp = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if !vm.metrics.isOnline {
                            OrbitNotice(title: "PC Offline", message: "Connect to your PC to use trackpad, keyboard, and media controls.", icon: "wifi.slash", tint: .orange)
                        }
                        VStack(spacing: 16) {
                            trackpad
                            keyboard
                            mediaControls
                        }
                        .disabled(!vm.metrics.isOnline)
                        .opacity(vm.metrics.isOnline ? 1 : 0.5)
                    }
                    .frame(maxWidth: 720)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Remote")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        vm.openDesktopPreview()
                    } label: {
                        Image(systemName: "display")
                    }
                    .disabled(!vm.metrics.isOnline)
                    .accessibilityLabel("Desktop Preview")

                    Menu {
                        NavigationLink { TaskManagerView(vm: vm) } label: {
                            Label("Task Manager", systemImage: "list.bullet.rectangle")
                        }
                        NavigationLink { AudioMixerView(vm: vm) } label: {
                            Label("Audio Mixer", systemImage: "slider.vertical.3")
                        }
                        NavigationLink { ClipboardView(vm: vm) } label: {
                            Label("Clipboard Sync", systemImage: "doc.on.clipboard")
                        }
                        Divider()
                        Button("Toggle HDR", systemImage: "sun.max") {
                            Task { await vm.sendPowerAction("toggle_hdr") }
                        }
                        Button("Restore Display", systemImage: "display") {
                            Task { await vm.sendPowerAction("restore_display") }
                        }
                        Button("Lock PC", systemImage: "lock") {
                            Task { await vm.sendPowerAction("lock") }
                        }
                        Divider()
                        Button("Close Active Game", systemImage: "xmark.square", role: .destructive) {
                            confirmCloseApp = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(!vm.metrics.isOnline)
                    .accessibilityLabel("Remote Actions Menu")
                }
            }
            .confirmationDialog("Close the active game?", isPresented: $confirmCloseApp, titleVisibility: .visible) {
                Button("Close Game", role: .destructive) { Task { await vm.sendPowerAction("kill_game") } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sends a close request to the active foreground game on your PC.")
            }
        }
    }

    private var trackpad: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Trackpad", systemImage: "hand.draw.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        Task { await vm.sendMouseInput(scroll: 3) }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await vm.sendMouseInput(scroll: -3) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 28, weight: .light))
                        Text("Drag to move · Tap to click")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white.opacity(0.24))
                    .allowsHitTesting(false)
                }
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
                .frame(height: 200)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .gesture(DragGesture(minimumDistance: 1).onChanged(handleDrag).onEnded { _ in finishDrag() })
                .simultaneousGesture(TapGesture().onEnded {
                    guard vm.metrics.isOnline else { return }
                    Task { await vm.sendMouseInput(click: "left") }
                })
                .allowsHitTesting(vm.metrics.isOnline)
                .accessibilityLabel("PC trackpad")

            HStack(spacing: 8) {
                remoteButton("Left", icon: "computermouse") { await vm.sendMouseInput(click: "left") }
                remoteButton("Double", icon: "cursorarrow.click.2") { await vm.sendMouseInput(click: "double") }
                remoteButton("Right", icon: "contextualmenu.and.cursorarrow") { await vm.sendMouseInput(click: "right") }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keyboard", systemImage: "keyboard.fill")
                .font(.subheadline.weight(.bold))
            HStack(spacing: 8) {
                TextField("Type text to send…", text: $keyboardInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit(sendCurrentText)
                Button(action: sendCurrentText) {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(theme.accent)
                }
                .disabled(keyboardInput.isEmpty)
                .accessibilityLabel("Send text")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(["ENTER", "BACKSPACE", "SPACE", "ESC", "WIN", "TAB"], id: \.self) { key in
                    Button { Task { await vm.sendKeyboardInput(key: key) } } label: {
                        Text(key == "WIN" ? "Win" : (key == "BACKSPACE" ? "⌫ Back" : key.capitalized))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 20)
    }

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Media & Display", systemImage: "play.tv.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if vm.metrics.activeGame != nil {
                    Button {
                        confirmCloseApp = true
                    } label: {
                        Label("Quit Game", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                remoteButton("Prev", icon: "backward.end.fill") { await vm.sendPowerAction("media_prev") }
                remoteButton("Play/Pause", icon: "playpause.fill") { await vm.sendPowerAction("media_play_pause") }
                remoteButton("Next", icon: "forward.end.fill") { await vm.sendPowerAction("media_next") }
                remoteButton(vm.metrics.isMuted ? "Unmute" : "Mute", icon: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    await vm.sendPowerAction("mute")
                }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 20)
    }

    private func remoteButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline.weight(.semibold))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func handleDrag(_ value: DragGesture.Value) {
        guard vm.metrics.isOnline else { return }
        if let last = lastDragLocation {
            accumulatedDX += (value.location.x - last.x) * 2.2
            accumulatedDY += (value.location.y - last.y) * 2.2
            if Date().timeIntervalSince(lastSentTime) >= 0.028 { flushMovement() }
        }
        lastDragLocation = value.location
    }

    private func flushMovement() {
        let dx = Int(accumulatedDX)
        let dy = Int(accumulatedDY)
        guard dx != 0 || dy != 0 else { return }
        accumulatedDX -= Double(dx)
        accumulatedDY -= Double(dy)
        lastSentTime = Date()
        Task { await vm.sendMouseInput(dx: dx, dy: dy) }
    }

    private func finishDrag() {
        if vm.metrics.isOnline { flushMovement() }
        accumulatedDX = 0
        accumulatedDY = 0
        lastDragLocation = nil
    }

    private func sendCurrentText() {
        guard vm.metrics.isOnline, !keyboardInput.isEmpty else { return }
        let text = keyboardInput
        keyboardInput = ""
        Task { await vm.sendKeyboardInput(text: text) }
    }
}

// MARK: - Desktop preview

struct SmartLaunchOverlay: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).orbitAppearance()
                Text(vm.activeStreamingGame?.title ?? "Connecting to PC").font(.headline)
                Text(vm.smartLaunchStep.rawValue).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(26)
            .frame(maxWidth: 300)
            .liquidGlass(tint: .cyan)
        }
    }
}

struct MoonlightStreamView: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let frame = vm.liveFrameImage {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Current PC desktop screenshot")
                } else {
                    ContentUnavailableView(
                        vm.streamError == nil ? "Connecting to Desktop…" : "Preview Unavailable",
                        systemImage: "display",
                        description: Text(vm.streamError ?? "Waiting for live screen frames from Orbit PC Companion.")
                    )
                }
            }
            .navigationTitle("Desktop Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { vm.stopStreaming(putPCToSleep: false) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Moonlight", systemImage: "arrow.up.forward.app") { vm.openNativeMoonlight() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = vm.streamError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        Spacer()
                        Button("Retry") { vm.startLiveScreenFeed() }
                            .font(.caption.weight(.bold))
                            .disabled(vm.isDemoMode || !vm.metrics.isOnline)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var isShowingDashboardCustomization = false
    @State private var isShowingDiscovery = false
    @State private var isShowingProPaywall = false
    @State private var isShowingPrivacy = false
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        OrbitMark(size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.isConfigured ? vm.selectedPCName : "Orbit Companion")
                                .font(.headline.weight(.bold))
                            Text(vm.metrics.isOnline ? "Online · Agent \(vm.metrics.agentVersion ?? "4.1.0")" : vm.statusLog)
                                .font(.caption)
                                .foregroundStyle(vm.metrics.isOnline ? .mint : .secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Pair PC") { isShowingDiscovery = true }
                            .font(.caption.weight(.bold))
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .foregroundStyle(.black)
                    }
                    .padding(.vertical, 4)

                    NavigationLink { PCProfilesView(vm: vm) } label: {
                        Label("Saved PCs & Profiles", systemImage: "desktopcomputer")
                    }
                }

                Section("Orbit Pro & Purchases") {
                    Button {
                        isShowingProPaywall = true
                    } label: {
                        HStack {
                            Label(
                                proStore.isProUnlocked ? "Orbit Pro (Lifetime Unlocked)" : "Upgrade to Orbit Pro · \(proStore.displayPrice)",
                                systemImage: proStore.isProUnlocked ? "checkmark.seal.fill" : "crown.fill"
                            )
                            .foregroundStyle(proStore.isProUnlocked ? .mint : .yellow)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await proStore.restorePurchases() }
                    } label: {
                        HStack {
                            Label("Restore Purchases", systemImage: "arrow.clockwise.circle")
                            Spacer()
                            if proStore.isPurchasing { ProgressView() }
                        }
                    }
                    .disabled(proStore.isPurchasing)
                    if let status = proStore.statusMessage {
                        Text(status).font(.caption).foregroundStyle(.mint)
                    }
                }

                pcCompanionUpdateSection

                Section("Personalization & iOS") {
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Themes & Home Screen Icons", systemImage: "paintpalette")
                    }
                    Button { isShowingDashboardCustomization = true } label: {
                        Label("Customize Overview Cards", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { LiveActivitySettingsView(vm: vm) } label: {
                        HStack {
                            Label("Dynamic Island & Live Activity", systemImage: "capsule.portrait.tophalf.filled")
                            Spacer()
                            Text(vm.isDynamicIslandActive ? "Active" : "Off").font(.caption).foregroundStyle(vm.isDynamicIslandActive ? .mint : .secondary)
                        }
                    }
                    NavigationLink { WidgetHelpView(vm: vm) } label: {
                        Label("Widgets, Control Center & Siri", systemImage: "square.grid.2x2")
                    }
                }

                Section("Hardware & Diagnostics") {
                    NavigationLink { FullSpecsView(vm: vm) } label: {
                        Label("Hardware Specifications", systemImage: "cpu")
                    }
                    NavigationLink { MonitoringSourcesView(vm: vm) } label: {
                        Label("Sensor Sources", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink { FPSSetupView(vm: vm) } label: {
                        Label("FPS Counter Setup", systemImage: "speedometer")
                    }
                }

                connectionSection
                wakeSection

                Section("Preferences & Legal") {
                    Toggle("Demo Mode (Sample Data)", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
                    Toggle("Auto-Open Moonlight on Launch", isOn: $vm.autoOpenMoonlight)
                    Button("Run Setup Walkthrough", systemImage: "sparkles") {
                        if isPresentedAsSheet { dismiss() }
                        vm.showOnboarding = true
                    }
                    Button("Privacy Policy & Terms", systemImage: "hand.raised.fill") {
                        isShowingPrivacy = true
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $isShowingDashboardCustomization) {
                DashboardCustomizationView(vm: vm)
            }
            .sheet(isPresented: $isShowingDiscovery) {
                PCDiscoveryView(vm: vm)
            }
            .sheet(isPresented: $isShowingProPaywall) {
                OrbitProPaywallView()
            }
            .sheet(isPresented: $isShowingPrivacy) {
                OrbitPrivacyPolicyView()
            }
            .alert("Live Activity unavailable", isPresented: Binding(get: { vm.liveActivityError != nil }, set: { if !$0 { vm.liveActivityError = nil } })) {
                Button("OK") { vm.liveActivityError = nil }
            } message: {
                Text(vm.liveActivityError ?? "Live Activities could not be started.")
            }
            .toolbar {
                if isPresentedAsSheet {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = false }
                }
            }
        }
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }

    private var pcCompanionUpdateSection: some View {
        Section("PC Companion Updates (GitHub)") {
            LabeledContent("Installed Agent", value: vm.metrics.agentVersion ?? "4.1.0")
            if let latest = vm.agentLatestVersion {
                LabeledContent("Latest on GitHub", value: latest)
            }
            Button {
                Task { await vm.checkPCCompanionUpdate() }
            } label: {
                HStack {
                    Label(vm.isCheckingAgentUpdate ? "Checking GitHub…" : "Check for PC Companion Update", systemImage: "arrow.triangle.2.circlepath.circle")
                    Spacer()
                    if vm.isCheckingAgentUpdate { ProgressView() }
                }
            }
            .disabled(vm.isCheckingAgentUpdate)

            if vm.agentUpdateAvailable {
                Button {
                    Task { await vm.applyPCCompanionUpdate() }
                } label: {
                    Label("Install Update on PC Now", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.mint)
                        .fontWeight(.semibold)
                }
                .disabled(vm.isCheckingAgentUpdate || !vm.metrics.isOnline)
            }

            if let message = vm.agentUpdateMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(vm.agentUpdateAvailable ? .mint : .secondary)
            }

            ShareLink(
                item: URL(string: "https://github.com/AceDimi2005/Orbit")!,
                subject: Text("Orbit PC Companion for Windows"),
                message: Text("Download the Orbit PC Companion for Windows: https://github.com/AceDimi2005/Orbit (Direct ZIP: https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip)")
            ) {
                Label("Send PC Companion Link to PC", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
            }

            Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!) {
                Label("Download Windows Companion (.zip)", systemImage: "arrow.down.doc.fill")
                    .font(.subheadline)
            }

            Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                Label("Open GitHub Repository", systemImage: "arrow.up.right.square")
                    .font(.subheadline)
            }
        }
    }

    private var connectionSection: some View {
        Section("Manual Connection") {
            DisclosureGroup("Connection & Ports") {
                labeledField("PC Address", placeholder: "192.168.1.100", text: $vm.pcIP)
                    .onChange(of: vm.pcIP) { _, _ in vm.recalculateBroadcastIfNeeded() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Access Token").font(.caption).foregroundStyle(.secondary)
                    SecureField("Paste token", text: $vm.apiToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                }
                portField("HTTPS Port", value: $vm.securePort)
                portField("HTTP Port", value: $vm.agentPort)
                Button {
                    focusedField = false
                    isConnecting = true
                    vm.saveCurrentConnection()
                    Task { await vm.connect(); isConnecting = false }
                } label: {
                    HStack {
                        Label(isConnecting ? "Connecting…" : "Save & Connect", systemImage: "network")
                        Spacer()
                        if isConnecting { ProgressView() }
                    }
                }
                .disabled(isConnecting || !vm.isConfigured)
            }
        }
    }

    private var wakeSection: some View {
        Section("Wake-on-LAN") {
            DisclosureGroup("Wake-on-LAN Settings") {
                labeledField("MAC Address", placeholder: "AA:BB:CC:DD:EE:FF", text: $vm.pcMAC)
                labeledField("Subnet Mask", placeholder: "255.255.255.0", text: $vm.subnetMask)
                    .onChange(of: vm.subnetMask) { _, _ in vm.recalculateBroadcastIfNeeded() }
                Toggle("Auto Broadcast IP", isOn: $vm.autoCalcBroadcast)
                    .onChange(of: vm.autoCalcBroadcast) { _, _ in vm.recalculateBroadcastIfNeeded() }
                labeledField("Broadcast IP", placeholder: "192.168.1.255", text: $vm.wolTargetIP)
                    .disabled(vm.autoCalcBroadcast)
                portField("WoL Port", value: $vm.wolPort)
                Button("Sync Network Details from PC", systemImage: "arrow.down.circle") {
                    Task { await vm.fetchNetworkConfigFromPC() }
                }
                .disabled(!vm.metrics.isOnline || vm.isDemoMode)
            }
            Button("Send Wake Packet Now", systemImage: "power") { Task { await vm.wakePC() } }
                .disabled(!vm.isConfigured || vm.pcMAC.isEmpty || vm.isWakingUp)
        }
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.body.monospaced())
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
        }
        .padding(.vertical, 2)
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("Port", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($focusedField)
        }
    }
}

struct WidgetHelpView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var pairedPCs: [OrbitWidgetConnection] = []

    var body: some View {
        List {
            Section("Home & Lock Screen Widgets") {
                widgetRow("Power & Quick Controls", detail: "Interactive Power On (Wake), Sleep & Shut Down buttons directly on Home Screen", icon: "power.circle.fill", tint: .green)
                widgetRow("PC Overview & Gaming", detail: "CPU, GPU, RAM, VRAM, FPS & temps with On/Off buttons (Small, Medium, Large)", icon: "desktopcomputer", tint: .cyan)
                widgetRow("Specialty Panels", detail: "Dedicated Power, Temperatures, Cooling, Storage & Network widgets", icon: "bolt.fill", tint: .orange)
                widgetRow("Single PC Metric", detail: "Pick any 1 of 18 sensors for Home or Lock Screen", icon: "waveform.path.ecg", tint: .purple)
            }

            Section("Control Center & Siri (iOS 18+)") {
                widgetRow("Control Center Buttons", detail: "Swipe down Control Center → tap + → Add a Control → search Orbit to add Power On, Sleep, or Shut Down buttons", icon: "switch.2", tint: .mint)
                widgetRow("Siri & Shortcuts", detail: "Say \"Hey Siri, power on my PC with Orbit\" or \"Shut down my PC with Orbit\"", icon: "mic.fill", tint: .pink)
            }

            Section("Paired PCs for Widgets") {
                ForEach(pairedPCs) { pc in
                    Label(pc.name, systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.mint)
                }
                if pairedPCs.isEmpty {
                    Text("Pair a PC to enable automatic widget access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await vm.prepareWidgetAccess(); pairedPCs = OrbitWidgetConnectionStore.connections() }
                } label: {
                    HStack {
                        Label(vm.isLoadingWidgetToken ? "Syncing…" : "Sync Widget Credentials", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if vm.isLoadingWidgetToken { ProgressView() }
                    }
                }
                .disabled(!vm.metrics.isOnline || vm.isDemoMode || vm.isLoadingWidgetToken)
                if let error = vm.widgetSetupError { Text(error).font(.caption).foregroundStyle(.orange) }
            }

            Section("Quick Tip") {
                Text("Long-press any Orbit widget and tap Edit Widget to switch between paired PCs or change its color theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Widgets & Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pairedPCs = OrbitWidgetConnectionStore.connections() }
        .orbitAppearance()
    }

    private func widgetRow(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - First-run setup

struct OnboardingView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showsDiscovery = false
    @State private var isTesting = false
    @State private var connectionPassed = false
    @State private var didTest = false
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        welcome
                        connectionForm
                        VStack(spacing: 10) {
                            Button {
                                focusedField = false
                                vm.hasCompletedOnboarding = true
                                vm.showOnboarding = false
                            } label: {
                                HStack { Text("Continue"); Spacer(); Image(systemName: "arrow.right") }
                                    .font(.headline).padding(16).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan).foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .disabled(!connectionPassed || !vm.metrics.isOnline)

                            Button("Try Demo Mode") {
                                focusedField = false
                                vm.setDemoMode(true)
                                vm.hasCompletedOnboarding = true
                                vm.showOnboarding = false
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(8)
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vm.hasCompletedOnboarding {
                    ToolbarItem(placement: .topBarTrailing) { Button("Close") { vm.showOnboarding = false } }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = false }
                }
            }
        }
        .sheet(isPresented: $showsDiscovery) {
            PCDiscoveryView(vm: vm) {
                connectionPassed = vm.metrics.isOnline && !vm.isDemoMode; didTest = true
            }
        }
        .tint(.cyan).preferredColorScheme(.dark)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            OrbitMark(size: 76)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your PC,\nWithin Reach.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Live telemetry, remote control, and Dynamic Island.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                feature("Telemetry", icon: "waveform.path.ecg")
                feature("Wake on LAN", icon: "power")
                feature("Remote", icon: "computermouse.fill")
            }
            .padding(.vertical, 4)
        }
    }

    private func feature(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(.cyan)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Step 1 · Install on Windows PC", systemImage: "desktopcomputer.and.arrow.down")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
                Text("Download Orbit PC Companion on your Windows PC and run install_orbit.bat.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ShareLink(
                        item: URL(string: "https://github.com/AceDimi2005/Orbit")!,
                        subject: Text("Orbit PC Companion for Windows"),
                        message: Text("Download the Orbit PC Companion for Windows: https://github.com/AceDimi2005/Orbit (Direct ZIP: https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip)")
                    ) {
                        Label("Send Link to PC", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                        Label("GitHub Page", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider().overlay(.white.opacity(0.12))

            Label("Step 2 · Pair with 6-Digit Code", systemImage: "lock.shield")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.mint)
            Text("Keep Orbit Companion running on Windows and tap Find my PC below.")
                .font(.caption).foregroundStyle(.secondary)

            Button { showsDiscovery = true } label: {
                Label("Find my PC", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            if connectionPassed {
                Label("Paired securely", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.mint)
            }

            DisclosureGroup("Manual Setup") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("PC IP (e.g. 192.168.1.100)", text: $vm.pcIP)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                        .padding(11).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: vm.pcIP) { _, _ in connectionPassed = false; didTest = false; vm.recalculateBroadcastIfNeeded() }

                    SecureField("Pairing Token", text: $vm.apiToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                        .padding(11).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: vm.apiToken) { _, _ in connectionPassed = false; didTest = false }

                    TextField("Certificate SHA-256", text: $vm.certificateFingerprint, axis: .vertical)
                        .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                        .lineLimit(2...3).padding(11).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: vm.certificateFingerprint) { _, _ in connectionPassed = false; didTest = false }

                    Button {
                        focusedField = false
                        isTesting = true
                        Task {
                            await vm.connect()
                            connectionPassed = vm.metrics.isOnline && !vm.isDemoMode
                            didTest = true
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            if isTesting { ProgressView().tint(.cyan) }
                            Label(isTesting ? "Testing…" : "Test Connection", systemImage: "network")
                            Spacer()
                            if connectionPassed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint) }
                        }
                        .font(.subheadline.weight(.semibold)).padding(.vertical, 4)
                    }
                    .disabled(isTesting || !vm.isConfigured || !vm.hasSecureConnection)
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding(18)
        .liquidGlass(tint: .cyan)
    }
}

// MARK: - Hardware inventory

struct FullSpecsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showNames = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label(
                        vm.isDemoMode ? "Demo Hardware" : (vm.metrics.isOnline ? "Detected Hardware" : "Cached Hardware"),
                        systemImage: vm.metrics.isOnline ? "checkmark.seal.fill" : "clock"
                    )
                    .foregroundStyle(vm.metrics.isOnline ? .mint : .secondary)
                    Spacer()
                    Button("Rename") { showNames = true }
                        .font(.caption.weight(.bold))
                }
            }
            if let specs = vm.specs {
                inventory(specs)
            } else if vm.isLoadingSpecs {
                Section { HStack { ProgressView(); Text("Reading hardware…").padding(.leading, 8) } }
            } else {
                Section {
                    ContentUnavailableView("No Specs Loaded", systemImage: "cpu", description: Text(vm.specsError ?? "Connect to your PC to read hardware specifications."))
                }
            }
        }
        .navigationTitle("Specifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await vm.fetchSpecs() } } label: {
                    if vm.isLoadingSpecs { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(vm.isLoadingSpecs || !vm.metrics.isOnline)
                .accessibilityLabel("Refresh PC specifications")
            }
        }
        .sheet(isPresented: $showNames) { ComponentNamesView(vm: vm) }
        .task { if vm.specs == nil && vm.metrics.isOnline { await vm.fetchSpecs() } }
        .refreshable { if vm.metrics.isOnline { await vm.fetchSpecs() } }
    }

    @ViewBuilder
    private func inventory(_ specs: PCSpecs) -> some View {
        Section("System") {
            specRow("Computer", specs.hostname)
            specRow("OS", specs.osName)
            specRow("Version", specs.osVersion)
            specRow("Architecture", specs.architecture)
        }
        Section("Processor") {
            displayName("cpu")
            specRow("Model", specs.cpu.name)
            specRow("Cores / Threads", specs.cpu.physicalCores.map { "\($0)C / \(specs.cpu.logicalCores ?? $0)T" })
            specRow("Max Clock", specs.cpu.maxClockMHz.map { "\(decimal($0 / 1000, digits: 2)) GHz" })
            specRow("Temperature", vm.metrics.cpuTemp.map { "\(decimal($0))°C" })
        }
        Section("Graphics") {
            displayName("gpu")
            if specs.gpus.isEmpty { specRow("GPU", nil) }
            ForEach(Array(specs.gpus.enumerated()), id: \.offset) { index, gpu in
                if index > 0 { Divider() }
                specRow("Model", gpu.name)
                specRow("VRAM", gpu.vramGB.map { "\(decimal($0)) GB" })
                specRow("Driver", gpu.driverVersion)
            }
        }
        Section("Memory") {
            displayName("memory")
            specRow("Installed", specs.memory.totalGB.map { "\(decimal($0)) GB" })
            ForEach(Array(specs.memory.modules.enumerated()), id: \.offset) { index, module in
                DisclosureGroup(module.slot ?? "Slot \(index + 1)") {
                    specRow("Part", module.partNumber)
                    specRow("Capacity", module.capacityGB.map { "\(decimal($0)) GB" })
                    specRow("Speed", module.speedMHz.map { "\(decimal($0, digits: 0)) MHz" })
                }
            }
        }
        Section("Motherboard & Cooling") {
            displayName("motherboard")
            specRow("Board", [specs.motherboard.manufacturer, specs.motherboard.model].compactMap { $0 }.joined(separator: " "))
            specRow("BIOS", specs.motherboard.biosVersion)
            displayName("cooler")
            specRow("Cooler", specs.coolerName)
        }
        Section("Storage") {
            displayName("storage")
            ForEach(Array(specs.disks.enumerated()), id: \.offset) { index, disk in
                DisclosureGroup(disk.name ?? "Drive \(index + 1)") {
                    specRow("Capacity", disk.sizeGB.map { "\(decimal($0)) GB" })
                    specRow("Type", [disk.interfaceType, disk.mediaType].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    @ViewBuilder
    private func displayName(_ key: String) -> some View {
        if let name = vm.componentOverrides[key], !name.isEmpty {
            specRow("Custom Label", name)
        }
    }

    private func specRow(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(.subheadline)
                .foregroundStyle(value == nil || value?.isEmpty == true ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct ComponentNamesView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    private let components = [("cpu", "Processor"), ("gpu", "Graphics card"), ("memory", "Memory"), ("motherboard", "Motherboard"), ("cooler", "Cooler"), ("storage", "Storage")]

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom Labels") {
                    ForEach(components, id: \.0) { key, title in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            TextField(detectedName(key), text: Binding(get: { names[key] ?? "" }, set: { names[key] = $0 }))
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Button("Reset to Detected Names", role: .destructive) { names = [:] }
                }
            }
            .navigationTitle("Custom Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        for (key, _) in components { vm.setComponentOverride(key, value: names[key] ?? "") }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .orbitAppearance().preferredColorScheme(.dark)
        .onAppear { names = vm.componentOverrides }
    }

    private func detectedName(_ key: String) -> String {
        switch key {
        case "cpu": return vm.specs?.cpu.name ?? "Detected processor"
        case "gpu": return vm.specs?.gpus.first?.name ?? "Detected graphics card"
        case "memory": return vm.specs?.memory.totalGB.map { "\(decimal($0)) GB installed" } ?? "Detected memory"
        case "motherboard": return vm.specs?.motherboard.model ?? "Detected motherboard"
        case "cooler": return vm.specs?.coolerName ?? "Detected cooler"
        case "storage": return vm.specs?.disks.first?.name ?? "Detected storage"
        default: return "Use detected name"
        }
    }
}

private func decimal(_ value: Double, digits: Int = 1) -> String {
    guard value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(digits)))
}

private func percent(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return "\(Int(value.rounded()))%"
}
