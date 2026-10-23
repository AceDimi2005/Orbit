import MoonlightCore
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var isShowingProFromURL = false
    @StateObject private var vm = OrbitViewModel()
    @ObservedObject private var stream = MoonlightStreamController.shared
    @ObservedObject private var notificationRouter = OrbitNotificationRouter.shared
    @AppStorage("orbit.theme") private var rootTheme: OrbitTheme = .noir
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(vm: vm)
                .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            GameLibraryView(vm: vm)
                .tabItem { Label("Stream", systemImage: "play.rectangle.fill") }
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
        .onChange(of: selectedTab) { _, _ in OrbitHaptics.selection() }
        .overlay {
            if vm.smartLaunchStep != .idle {
                SmartLaunchOverlay(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.smartLaunchStep)
        .fullScreenCover(isPresented: $vm.isShowingStreamView) {
            MoonlightStreamView(vm: vm)
        }
        .fullScreenCover(isPresented: $stream.isPresented) {
            MoonlightStreamScreen(controller: stream, accent: rootTheme.accent)
        }
        .onChange(of: vm.metrics.sessionLocked, initial: true) { _, locked in stream.pcLocked = locked == true }
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
            OrbitProStore.shared.start()
        }
        .onChange(of: scenePhase) { _, phase in
            vm.setAppActive(phase == .active)
            if phase == .active { OrbitProStore.shared.refreshIfNeeded() }
        }
        .onReceive(OrbitProStore.shared.$isProUnlocked) { _ in OrbitProLockdown.enforce() }
        .onReceive(OrbitProStore.shared.$hasVerifiedEntitlements) { _ in OrbitProLockdown.enforce() }
        .sheet(isPresented: $isShowingProFromURL) { OrbitProPaywallView() }
        .sheet(isPresented: $notificationRouter.showsNotifications) {
            NavigationStack { NotificationsSettingsView(vm: vm, showsDoneButton: true) }
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "orbit" else { return }
            switch url.host?.lowercased() {
            case "pro": isShowingProFromURL = true
            case "remote": selectedTab = 2
            case "library": selectedTab = 1
            case "settings": selectedTab = 3
            case "files": selectedTab = 4
            case "notifications": OrbitNotificationRouter.shared.showsNotifications = true
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
        // Applied last so presented sheets, covers and overlays inherit the theme environment.
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Overview

struct DashboardView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var pendingAction: PowerConfirmation?
    @State private var isShowingCustomization = false
    @State private var isShowingPCs = false
    @State private var isShowingDiscovery = false
    @State private var wakePulse = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func adaptiveColumns(for availableWidth: CGFloat) -> [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12)]
        }
        let targetCount: Int
        if availableWidth >= 980 {
            targetCount = 4
        } else if availableWidth >= 640 {
            targetCount = 3
        } else {
            targetCount = vm.dashboardConfiguration.columnCount
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, targetCount))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let isWideScreen = geo.size.width >= 700 || horizontalSizeClass == .regular
                ZStack {
                    OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                    ScrollView(showsIndicators: false) {
                        overviewColumn(width: min(geo.size.width - 36, 1400), isWide: isWideScreen)
                            .frame(maxWidth: 1400)
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .padding(.bottom, 28)
                            .frame(maxWidth: .infinity)
                            .animation(.snappy(duration: 0.35), value: vm.metrics.isOnline)
                            .animation(.snappy(duration: 0.35), value: vm.metrics.activeGame)
                    }
                    .refreshable { await vm.refreshMetrics() }
                }
            }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        OrbitHaptics.press()
                        vm.toggleDynamicIsland()
                    } label: {
                        Image(systemName: vm.isDynamicIslandActive ? "capsule.portrait.tophalf.filled" : "waveform.path.ecg")
                            .foregroundStyle(vm.isDynamicIslandActive ? .mint : .primary)
                            .symbolEffect(.pulse, isActive: vm.isDynamicIslandActive)
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
                        OrbitHaptics.warning()
                        Task { await vm.sendPowerAction(action.rawValue) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            } message: {
                Text(pendingAction?.message ?? "")
            }
        }
    }

    @ViewBuilder
    private func overviewColumn(width: CGFloat, isWide: Bool) -> some View {
        VStack(spacing: 16) {
            if vm.isDemoMode { previewNotice }
            heroCard
            if vm.metrics.isOnline {
                if vm.dashboardConfiguration.showsGame, let game = vm.metrics.activeGame { activeGameCard(game) }
                if vm.metrics.telemetryAvailable == false {
                    OrbitNotice(title: "Syncing sensors…", message: "Collecting the first readings from your PC. Cards appear as soon as the agent reports them.", icon: "waveform.path.ecg", tint: theme.accent)
                } else {
                    metricsGrid(width: width)
                }
                if isWide && vm.dashboardConfiguration.showsVolume && vm.dashboardConfiguration.showsQuickControls {
                    HStack(spacing: 14) {
                        volumeCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                        powerCard.frame(maxWidth: .infinity)
                    }
                } else {
                    if vm.dashboardConfiguration.showsVolume { volumeCard }
                    if vm.dashboardConfiguration.showsQuickControls { powerCard }
                }
                if vm.dashboardConfiguration.showsSpecifications { specsLink }
            } else {
                offlineCard
                if vm.dashboardConfiguration.showsSpecifications { specsLink }
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
            .buttonStyle(OrbitGlassButtonStyle(tint: .orange, cornerRadius: 20))
            .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 16, tint: .orange)
    }

    // MARK: Hero

    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        return vm.metrics.isOnline ? .mint : .orange
    }

    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if vm.isWakingUp { return "Waking…" }
        if vm.metrics.isOnline, vm.metrics.sessionLocked == true { return "Locked" }
        return vm.metrics.isOnline ? "Online" : "Offline"
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    OrbitRingGauge(
                        progress: vm.metrics.isOnline && vm.metrics.telemetryAvailable != false ? vm.metrics.cpuUsage / 100 : nil,
                        lineWidth: 5,
                        tint: theme.accent
                    )
                    .frame(width: 58, height: 58)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(vm.metrics.isOnline ? AnyShapeStyle(theme.heroGradient) : AnyShapeStyle(Color.secondary))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
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
                        HStack(spacing: 6) {
                            Text(vm.isConfigured || vm.isDemoMode ? vm.metrics.hostname : "Select PC")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .accessibilityLabel(vm.isConfigured || vm.isDemoMode ? vm.metrics.hostname : "Select PC")
                    .accessibilityHint("Switches the connected PC")

                    HStack(spacing: 6) {
                        OrbitStatusPill(text: statusText, tint: statusTint, pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                        if vm.metrics.isOnline && !vm.isDemoMode {
                            OrbitStatChip(label: "Ping", value: "\(vm.pingMs) ms")
                        }
                        if vm.metrics.isOnline && vm.metrics.telemetryAvailable != false {
                            OrbitStatChip(label: "Up", value: vm.metrics.formattedUptime)
                        }
                    }
                }

                Spacer(minLength: 4)

                VStack(spacing: 8) {
                    heroIconButton(
                        icon: vm.isDynamicIslandActive ? "capsule.portrait.tophalf.filled" : "capsule.portrait",
                        tint: vm.isDynamicIslandActive ? .mint : theme.accent,
                        active: vm.isDynamicIslandActive,
                        label: vm.isDynamicIslandActive ? "Stop Live Activity" : "Start Live Activity"
                    ) {
                        OrbitHaptics.press()
                        vm.toggleDynamicIsland()
                    }
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                    .opacity(!vm.isDynamicIslandActive && !vm.metrics.isOnline ? 0.4 : 1)

                    heroIconButton(icon: "slider.horizontal.3", tint: theme.accent, active: false, label: "Customize cards") {
                        isShowingCustomization = true
                    }
                }
            }

            if vm.metrics.isOnline && !vm.isDemoMode {
                HStack(spacing: 8) {
                    OrbitStatChip(label: "Link", value: vm.hasSecureConnection ? "Encrypted" : "HTTP", icon: vm.hasSecureConnection ? "lock.fill" : "lock.open")
                    if let version = vm.metrics.agentVersion {
                        OrbitStatChip(label: "Agent", value: version)
                    }
                    if let source = vm.metrics.sensorSource, !source.isEmpty {
                        OrbitStatChip(label: "Sensors", value: source)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 24, tint: theme.accent, elevated: true)
    }

    private func heroIconButton(icon: String, tint: Color, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.07)), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(active ? 0.25 : 0.08), lineWidth: 1))
                .foregroundStyle(active ? Color.black.opacity(0.85) : tint)
        }
        .buttonStyle(.orbitPressable)
        .accessibilityLabel(label)
    }

    // MARK: Metrics

    @ViewBuilder
    private func metricsGrid(width: CGFloat) -> some View {
        if vm.dashboardConfiguration.orderedVisibleMetrics.isEmpty {
            Button { isShowingCustomization = true } label: {
                OrbitNotice(title: "No cards selected", message: "Tap to choose which hardware metrics appear here.", icon: "slider.horizontal.3", tint: theme.accent)
            }
            .buttonStyle(.orbitPressable)
        } else {
            LazyVGrid(columns: adaptiveColumns(for: width), spacing: 12) {
                ForEach(vm.dashboardConfiguration.orderedVisibleMetrics) { metric in
                    metricCard(metric)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3), value: vm.dashboardConfiguration.orderedVisibleMetrics)
        }
    }

    @ViewBuilder
    private func metricCard(_ metric: DashboardMetric) -> some View {
        let series = vm.history.series(for: metric)
        switch metric {
        case .cpuLoad:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                valueText: percent(vm.metrics.cpuUsage), progress: vm.metrics.cpuUsage / 100,
                icon: metric.symbol, accent: metric.accent,
                detail: cpuDetail, history: series, showsRing: true
            )
        case .gpuLoad:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                valueText: vm.metrics.gpuUsage.map(percent) ?? "—", progress: vm.metrics.gpuUsage.map { $0 / 100 },
                icon: metric.symbol, accent: metric.accent, detail: gpuDetail, history: series, showsRing: true
            )
        case .memory:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("memory", detected: "System RAM"),
                valueText: vm.metrics.ramTotalGB > 0 ? "\(decimal(vm.metrics.ramUsedGB)) GB" : "—",
                progress: vm.metrics.ramTotalGB > 0 ? vm.metrics.ramUsedGB / vm.metrics.ramTotalGB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ramTotalGB > 0 ? "of \(decimal(vm.metrics.ramTotalGB, digits: 0)) GB · \(percent(vm.metrics.ramUsedGB / vm.metrics.ramTotalGB * 100))" : nil,
                history: series, showsRing: true
            )
        case .storage:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("storage", detected: vm.specs?.disks.first?.name ?? "System Drive"),
                valueText: vm.metrics.ssdTotalTB > 0 ? "\(decimal(vm.metrics.ssdUsedTB, digits: 2)) TB" : "—",
                progress: vm.metrics.ssdTotalTB > 0 ? vm.metrics.ssdUsedTB / vm.metrics.ssdTotalTB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ssdTotalTB > 0 ? "of \(decimal(vm.metrics.ssdTotalTB, digits: 2)) TB · \(decimal(max(0, vm.metrics.ssdTotalTB - vm.metrics.ssdUsedTB), digits: 2)) TB free" : nil,
                showsRing: true
            )
        case .vram:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                valueText: vm.metrics.vramUsedGB.map { "\(decimal($0)) GB" } ?? "—",
                progress: vramProgress, icon: metric.symbol, accent: metric.accent,
                detail: vramDetail, history: series, showsRing: true
            )
        case .cpuPower:
            sensorCard(metric, value: vm.metrics.cpuPowerWatts, unit: "W",
                       subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                       detail: "Package power",
                       progress: vm.metrics.cpuPowerWatts.map { min(max($0 / 200.0, 0.04), 1) }, history: series)
        case .gpuPower:
            sensorCard(metric, value: vm.metrics.gpuPowerWatts, unit: "W",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                       detail: "Board power",
                       progress: vm.metrics.gpuPowerWatts.map { min(max($0 / 400.0, 0.04), 1) }, history: series)
        case .cpuTemperature:
            sensorCard(metric, value: vm.metrics.cpuTemp, unit: "°C",
                       subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                       detail: vm.metrics.sensorSource ?? "Core sensor",
                       progress: vm.metrics.cpuTemp.map { min(max(($0 - 25.0) / 70.0, 0.05), 1) }, history: series)
        case .gpuTemperature:
            sensorCard(metric, value: vm.metrics.gpuTemp, unit: "°C",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                       detail: vm.metrics.gpuSource ?? "GPU thermal",
                       progress: vm.metrics.gpuTemp.map { min(max(($0 - 25.0) / 70.0, 0.05), 1) }, history: series)
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
                               detail: vm.metrics.cpuClockSource, history: series)
        case .network:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.networkInterface ?? "Network",
                               valueText: transferRate(vm.metrics.networkDownloadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.networkUploadMBps.map { "↑ \(transferRate($0))" }, history: series)
        case .diskActivity:
            HardwareMetricCard(title: metric.title, subtitle: "Disk Throughput",
                               valueText: transferRate(vm.metrics.diskReadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.diskWriteMBps.map { "Write \(transferRate($0))" }, history: series)
        case .uptime:
            HardwareMetricCard(title: metric.title, subtitle: "Active session",
                               valueText: vm.metrics.formattedUptime, progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" })
        case .fps:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.activeGame ?? "No active game",
                               valueText: vm.metrics.fps.map { "\(Int($0.rounded())) FPS" } ?? "—",
                               progress: vm.metrics.fps.map { min(max($0 / 165.0, 0.05), 1) },
                               icon: metric.symbol, accent: metric.accent,
                               detail: fpsDetail, history: series)
        case .cpuFan:
            sensorCard(metric, value: vm.metrics.cpuFanRPM, unit: "RPM", subtitle: "CPU Cooler", detail: nil,
                       progress: vm.metrics.cpuFanRPM.map { min(max($0 / 2400.0, 0.05), 1) })
        case .gpuFan:
            sensorCard(metric, value: vm.metrics.gpuFanPercent, unit: "%", subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName), detail: nil,
                       progress: vm.metrics.gpuFanPercent.map { min(max($0 / 100.0, 0), 1) })
        }
    }

    private func sensorCard(_ metric: DashboardMetric, value: Double?, unit: String, subtitle: String, detail: String?, progress: Double? = nil, history: [Double] = []) -> some View {
        HardwareMetricCard(
            title: metric.title,
            subtitle: subtitle,
            valueText: value.map { "\(Int($0.rounded()))\(unit == "°C" || unit == "%" ? "" : " ")\(unit)" } ?? "—",
            progress: progress,
            icon: metric.symbol,
            accent: metric.accent,
            detail: value == nil ? nil : detail,
            history: history
        )
    }

    private var vramProgress: Double? {
        guard let used = vm.metrics.vramUsedGB, let total = vm.metrics.vramTotalGB, total > 0 else { return nil }
        return used / total
    }

    private var vramDetail: String? {
        guard let used = vm.metrics.vramUsedGB else { return nil }
        if let total = vm.metrics.vramTotalGB, total > 0 { return "of \(decimal(total)) GB · \(percent(used / total * 100))" }
        return nil
    }

    private func transferRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1 { return "\(decimal(value)) MB/s" }
        if value >= 0.001 { return "\(decimal(value * 1000, digits: 1)) KB/s" }
        return "\(decimal(value * 1_000_000, digits: 0)) B/s"
    }

    private var cpuDetail: String? {
        var parts: [String] = []
        if let temperature = vm.metrics.cpuTemp { parts.append("\(Int(temperature))°C") }
        if let clock = vm.metrics.cpuClockMHz { parts.append("\(decimal(clock / 1000, digits: 2)) GHz") }
        if let watts = vm.metrics.cpuPowerWatts { parts.append("\(Int(watts)) W") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var gpuDetail: String? {
        var parts: [String] = []
        if let temperature = vm.metrics.gpuTemp { parts.append("\(Int(temperature))°C") }
        if let watts = vm.metrics.gpuPowerWatts { parts.append("\(Int(watts)) W") }
        if let fan = vm.metrics.gpuFanPercent { parts.append("Fan \(Int(fan))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var fpsDetail: String? {
        guard let fps = vm.metrics.fps, fps > 0 else { return vm.metrics.fpsSource }
        let frametime = decimal(1000 / fps, digits: 1)
        if let source = vm.metrics.fpsSource { return "\(frametime) ms · \(source)" }
        return "\(frametime) ms frametime"
    }

    /// Game card colour: the single accent in Noir, mint elsewhere.
    private var gameTint: Color { theme.isFlat ? theme.accent : .mint }

    private func activeGameCard(_ title: String) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: "gamecontroller.fill", tint: gameTint, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("PLAYING NOW")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(gameTint)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if let fps = vm.metrics.fps, fps > 0 {
                    Text("\(decimal(1000 / fps, digits: 1)) ms frametime\(vm.metrics.fpsSource.map { " · \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                if vm.history.fps.count >= 3 {
                    OrbitSparkline(values: vm.history.fps, tint: gameTint, lineWidth: 1.5)
                        .frame(width: 92, height: 30)
                        .opacity(0.6)
                }
                if let fps = vm.metrics.fps {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(fps.rounded()))")
                            .font(.system(size: 28, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(gameTint)
                            .contentTransition(.numericText())
                            .shadow(color: reduceGlow || theme.isFlat ? .clear : gameTint.opacity(0.45), radius: 10)
                        Text("FPS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("FPS —")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 20, tint: gameTint)
    }

    private var specsLink: some View {
        NavigationLink { FullSpecsView(vm: vm) } label: {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: "cpu", tint: theme.accent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hardware Specifications")
                        .font(.subheadline.weight(.semibold))
                    Text(specsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .liquidGlass(cornerRadius: 18)
        }
        .buttonStyle(.orbitPressable)
    }

    private var specsSummary: String {
        if let specs = vm.specs {
            let parts = [specs.cpu.name, specs.gpus.first?.name].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return vm.metrics.isOnline ? "CPU, GPU, memory, board, storage & network" : "Last detected hardware"
    }

    private var volumeCard: some View {
        HStack(spacing: 12) {
            Button {
                OrbitHaptics.tap()
                Task { await vm.sendPowerAction("mute") }
            } label: {
                OrbitIconBadge(
                    systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tint: vm.metrics.isMuted ? .orange : theme.accent,
                    size: 38
                )
            }
            .buttonStyle(.orbitPressable)
            .accessibilityLabel(vm.metrics.isMuted ? "Unmute PC" : "Mute PC")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("PC Volume")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Text(vm.metrics.volumeAvailable == false ? "—" : (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%"))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(vm.metrics.isMuted ? .orange : .white)
                        .contentTransition(.numericText())
                }
                Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                    vm.isDraggingVolume = editing
                    if !editing { OrbitHaptics.tap() }
                }
                .tint(vm.metrics.isMuted ? .orange : theme.accent)
                .accessibilityLabel("PC volume")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlass(cornerRadius: 20)
        .disabled(!vm.metrics.isOnline || vm.metrics.volumeAvailable == false)
    }

    private var powerCard: some View {
        HStack(spacing: 10) {
            OrbitActionTile(title: "Lock", icon: "lock.fill", tint: theme.accent) { Task { await vm.sendPowerAction("lock") } }
            OrbitActionTile(title: "Display", icon: "display", tint: theme.accent) { Task { await vm.sendPowerAction("restore_display") } }
            OrbitActionTile(title: "Preview", icon: "rectangle.on.rectangle", tint: theme.accent) { vm.openDesktopPreview() }
            Menu {
                Button("Sleep", systemImage: "moon.fill") { pendingAction = .sleep }
                Button("Restart", systemImage: "arrow.clockwise") { pendingAction = .restart }
                Button("Shut Down", systemImage: "power", role: .destructive) { pendingAction = .shutdown }
            } label: {
                VStack(spacing: 7) {
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(height: 20)
                    Text("Power")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.orange.opacity(0.22), lineWidth: 1))
            }
            .accessibilityLabel("Power options")
        }
        .padding(12)
        .liquidGlass(cornerRadius: 20)
        .disabled(!vm.metrics.isOnline)
    }

    private var offlineCard: some View {
        VStack(spacing: 20) {
            Button {
                OrbitHaptics.press()
                Task { await vm.wakePC() }
            } label: {
                ZStack {
                    if !reduceMotion && !reduceGlow {
                        Circle()
                            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 104, height: 104)
                            .scaleEffect(wakePulse ? 1.35 : 1)
                            .opacity(wakePulse ? 0 : 0.8)
                    }
                    Circle()
                        .fill(theme.accent.opacity(0.10))
                        .frame(width: 104, height: 104)
                    Circle()
                        .strokeBorder(theme.heroGradient, lineWidth: 1.5)
                        .frame(width: 104, height: 104)
                    if vm.isWakingUp {
                        ProgressView().controlSize(.large).tint(theme.accent)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(theme.heroGradient)
                            .shadow(color: reduceGlow ? .clear : theme.accent.opacity(0.6), radius: 14)
                    }
                }
            }
            .buttonStyle(.orbitPressable)
            .disabled(vm.isWakingUp || !vm.isConfigured || vm.pcMAC.isEmpty)
            .accessibilityLabel("Wake PC")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { wakePulse = true }
            }

            VStack(spacing: 5) {
                Text(vm.isWakingUp ? "Waking PC…" : (vm.isConfigured ? "PC Offline" : "Pair Your PC"))
                    .font(.title3.weight(.bold))
                Text(vm.isConfigured
                     ? (vm.pcMAC.isEmpty ? "Connect once while the PC is on to save its MAC address for Wake-on-LAN." : "Tap the power ring to send Wake-on-LAN, or retry the connection.")
                     : "Pair over your local network with the 6-digit code shown on Windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 10) {
                Button {
                    isShowingDiscovery = true
                } label: {
                    Label(vm.isConfigured ? "Find PC" : "Find my PC", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                .frame(maxWidth: 220)

                if vm.isConfigured {
                    Button {
                        OrbitHaptics.tap()
                        Task { await vm.connect() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                } else {
                    ShareLink(
                        item: URL(string: "https://github.com/AceDimi2005/Orbit")!,
                        subject: Text("Orbit PC Companion for Windows"),
                        message: Text("Download the Orbit PC Companion for Windows here: https://github.com/AceDimi2005/Orbit")
                    ) {
                        Label("Get PC App", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                }
            }

            if !vm.statusLog.isEmpty && vm.isConfigured {
                Text(vm.statusLog)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 24, tint: theme.accent, elevated: true)
    }
}

// MARK: - Dashboard customization

struct DashboardCustomizationView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.orbitTheme) private var theme
    @State private var draft: DashboardConfiguration

    init(vm: OrbitViewModel) {
        self.vm = vm
        _draft = State(initialValue: vm.dashboardConfiguration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            presetButton("Balanced", icon: "square.grid.2x2", configuration: .balanced)
                            presetButton("Gaming", icon: "gamecontroller", configuration: .gaming)
                            presetButton("Work", icon: "hammer", configuration: .workstation)
                            presetButton("Cooling", icon: "fanblades", configuration: .cooling)
                            presetButton("All", icon: "rectangle.grid.3x2", configuration: .allMetrics)
                        }
                        .padding(.horizontal, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                    Picker("Grid Layout", selection: $draft.columnCount) {
                        Text("1 Column").tag(1)
                        Text("2 Columns").tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Presets")
                }
                .orbitRow()

                Section {
                    ForEach(draft.metricOrder) { metric in
                        let visible = draft.visibleMetrics.contains(metric)
                        HStack(spacing: 12) {
                            OrbitIconBadge(systemName: metric.symbol, tint: metric.accent, size: 30)
                                .opacity(visible ? 1 : 0.5)
                            Text(metric.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(visible ? .white : .secondary)
                            Spacer(minLength: 4)
                            Button {
                                OrbitHaptics.selection()
                                withAnimation(.snappy) { draft.setVisible(metric, !visible) }
                            } label: {
                                Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(visible ? theme.accent : .secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(visible ? "Hide \(metric.title)" : "Show \(metric.title)")
                        }
                    }
                    .onMove { source, destination in draft.metricOrder.move(fromOffsets: source, toOffset: destination) }
                } header: {
                    HStack {
                        Text("Cards")
                        Spacer()
                        Text("\(draft.orderedVisibleMetrics.count) active")
                    }
                } footer: {
                    Text("Drag to reorder. Cards for sensors your PC does not report show “—” instead of estimated values.")
                }
                .orbitRow()

                Section("Sections") {
                    Toggle("Active Game Banner", isOn: $draft.showsGame)
                    Toggle("Volume Slider", isOn: $draft.showsVolume)
                    Toggle("Quick Power Bar", isOn: $draft.showsQuickControls)
                    Toggle("Hardware Specs Link", isOn: $draft.showsSpecifications)
                }
                .orbitRow()
            }
            .orbitListChrome()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        OrbitHaptics.success()
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
        let selected = draft == configuration
        return Button {
            OrbitHaptics.selection()
            withAnimation(.snappy) { draft = configuration }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.bold))
            }
            .frame(width: 78, height: 64)
            .foregroundStyle(selected ? Color.black.opacity(0.85) : .white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(theme.heroGradient) : AnyShapeStyle(Color.white.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.borderless)
    }
}

extension DashboardMetric {
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
    var isEmbeddedInDuo = false
    @State private var searchText = ""
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @ObservedObject private var stream = MoonlightStreamController.shared
    @State private var showsPairing = false
    @State private var showsStreamSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.orbitTheme) private var theme

    /// Agent library first; when it is empty but Sunshine is paired, Sunshine's own list fills in.
    private var libraryGames: [SunshineGame] {
        if !vm.games.isEmpty || !sunshine.isPaired { return vm.games }
        return sunshine.apps.map { SunshineGame(id: "sunshine-\($0.id)", title: $0.title, genre: $0.supportsHDR ? "Sunshine · HDR" : "Sunshine", iconSymbol: "gamecontroller.fill", accentHex: "5CDBFF") }
    }
    private var filteredGames: [SunshineGame] {
        searchText.isEmpty ? libraryGames : libraryGames.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
    private var sunshineKey: String { "\(vm.selectedPCID)|\(vm.cleanHost())|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)" }
    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode }

    /// The agent on the PC can type the pairing PIN and start Sunshine (agent 4.3+).
    private var pairingAutomation: MoonlightPairingAutomation? {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return nil }
        return MoonlightPairingAutomation(canSubmitPIN: vm.sunshineInfo?.canSubmitPin ?? false, canStartSunshine: vm.sunshineInfo?.canStart ?? false,
                                          sunshineRunning: vm.sunshineInfo?.running ?? true, client: { try vm.companionClient() })
    }

    private func syncSunshine() async {
        guard !vm.isDemoMode else { return }
        sunshine.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                           httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    private var adaptiveGameColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: 160, maximum: 300), spacing: 14)]
    }

    var body: some View {
        Group {
            if isEmbeddedInDuo {
                libraryContent
            } else {
                NavigationStack {
                    ZStack {
                        OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                        libraryContent
                    }
                    .navigationTitle("Stream")
                    .searchable(text: $searchText, prompt: "Search games & apps")
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                OrbitHaptics.tap()
                                Task { await vm.fetchSunshineApps(); await sunshine.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(!vm.metrics.isOnline)
                            .accessibilityLabel("Refresh library")

                            Menu {
                                Button("Stream Settings…", systemImage: "slider.horizontal.3") { showsStreamSettings = true }
                                Button("Desktop Preview", systemImage: "display") {
                                    vm.openDesktopPreview()
                                }
                                .disabled(!vm.metrics.isOnline)
                                Divider()
                                if sunshine.isPaired {
                                    Button("Quit Sunshine Session", systemImage: "stop.circle") { Task { await sunshine.quitRunningApp() } }
                                        .disabled(!sunshine.isBusy)
                                    Button("Forget Sunshine Pairing", systemImage: "link.badge.minus", role: .destructive) { sunshine.forgetPairing() }
                                } else {
                                    Button("Pair with Sunshine…", systemImage: "link") { showsPairing = true }
                                        .disabled(!vm.metrics.isOnline || vm.isDemoMode)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("Stream Menu")
                        }
                    }
                }
            }
        }
        .task(id: sunshineKey) { await syncSunshine() }
        .sheet(isPresented: $showsPairing) {
            MoonlightPairingView(host: sunshine, pcName: vm.selectedPCName, accent: theme.accent, automation: pairingAutomation) { showsPairing = false }
                .presentationDetents([.large])
                .presentationBackground(theme.background)
        }
        .sheet(isPresented: $showsStreamSettings) {
            MoonlightStreamSettingsView(store: streamSettings, accent: theme.accent, hostSupportsHEVC: sunshine.hostSupportsHEVC) { showsStreamSettings = false }
                .presentationBackground(theme.background)
        }
    }

    private var libraryContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if !vm.metrics.isOnline {
                    OrbitNotice(title: "PC Offline", message: "Connect or wake your PC to stream or launch Sunshine apps.", icon: "wifi.slash", tint: .orange)
                } else if !vm.isDemoMode {
                    streamHero
                }
                if filteredGames.isEmpty {
                    OrbitEmptyState(
                        icon: searchText.isEmpty ? "gamecontroller" : "magnifyingglass",
                        title: searchText.isEmpty ? "No Sunshine Apps" : "No Matches",
                        message: searchText.isEmpty ? "Apps configured in Sunshine on your PC appear here automatically." : "Try a different search term.",
                        tint: theme.accent,
                        actionTitle: searchText.isEmpty && vm.metrics.isOnline ? "Refresh" : nil,
                        action: { Task { await vm.fetchSunshineApps() } }
                    )
                    .padding(.vertical, 24)
                } else {
                    OrbitSectionHeader("Apps", icon: "square.grid.2x2") {
                        Text(canStream ? "Tap to stream · hold for more" : "Tap to launch on the PC")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: adaptiveGameColumns, spacing: 14) {
                        ForEach(filteredGames) { game in
                            let app = sunshine.app(titled: game.title)
                            GameCoverCard(
                                game: game,
                                artwork: app.flatMap { sunshine.artwork[$0.id] },
                                isRunning: app != nil && app?.id == sunshine.info?.currentGame,
                                streamsHere: canStream && app != nil,
                                onLaunch: { play(game) },
                                onStream: canStream ? app.map { app in { startStream(app) } } : nil,
                                onLaunchOnPC: { OrbitHaptics.press(); Task { await vm.smartLaunch(game: game) } },
                                onSettings: { showsStreamSettings = true }
                            )
                            .disabled(!vm.metrics.isOnline)
                            .opacity(vm.metrics.isOnline ? 1 : 0.55)
                            .onAppear { if let app { sunshine.loadArtwork(for: app) } }
                        }
                    }
                }
            }
            .frame(maxWidth: 1400)
            .padding(isEmbeddedInDuo ? 12 : 18)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await vm.fetchSunshineApps(); await sunshine.refresh() }
    }

    private var sunshineTint: Color {
        switch sunshine.statusTone {
        case .good: return .mint
        case .active: return theme.accent
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    private var settingsSummary: String {
        let settings = streamSettings.settings
        let size = settings.pixelSize(hostSupportsHEVC: sunshine.hostSupportsHEVC)
        var parts = [size.shortTitle, "\(settings.frameRate) fps", "\(settings.bitrateKbps(for: size) / 1000) Mbps"]
        parts.append(settings.codec == .h264 ? "H.264" : (MoonlightDeviceCapabilities.supportsHEVC ? "HEVC" : "H.264"))
        if settings.requestsHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }

    /// The Stream PC card: pairing state, the running session and the one-tap desktop stream.
    private var streamHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: "play.rectangle.fill", tint: theme.accent, size: 44, filled: sunshine.isPaired)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stream \(vm.selectedPCName)")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        OrbitStatusPill(text: sunshine.statusText, tint: sunshineTint, pulsing: sunshine.isBusy)
                        if sunshine.isPaired {
                            OrbitStatChip(label: "Apps", value: "\(sunshine.apps.count)")
                        } else if sunshine.reachable, let info = sunshine.info, !info.hostname.isEmpty {
                            OrbitStatChip(label: "Host", value: info.hostname)
                        }
                    }
                }
                Spacer(minLength: 6)
                if sunshine.isRefreshing { ProgressView().tint(theme.accent) }
            }

            Text(sunshine.summary(pcName: vm.selectedPCName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = sunshine.lastError, !sunshine.isPairing {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if sunshine.isPaired {
                HStack(spacing: 10) {
                    Button {
                        OrbitHaptics.press()
                        if let app = sunshine.desktopApp { startStream(app) }
                    } label: {
                        Label(sunshine.isBusy ? "Resume Stream" : "Stream Desktop", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                    .disabled(!canStream || sunshine.desktopApp == nil)

                    Button {
                        OrbitHaptics.tap()
                        showsStreamSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 46)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                    .accessibilityLabel("Stream settings")

                    if vm.metrics.sessionLocked == true {
                        Button {
                            OrbitHaptics.press()
                            if let app = sunshine.desktopApp { startStream(app, promptUnlock: true) }
                        } label: {
                            Image(systemName: "lock.open.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 46)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(OrbitGlassButtonStyle(tint: .yellow, cornerRadius: 16))
                        .disabled(!canStream || sunshine.desktopApp == nil)
                        .accessibilityLabel("Unlock the PC through the stream")
                    }

                    if sunshine.isBusy {
                        Button {
                            OrbitHaptics.warning()
                            Task { await sunshine.quitRunningApp() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 46)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(OrbitGlassButtonStyle(tint: .orange, cornerRadius: 16))
                        .accessibilityLabel("Quit the running app")
                    }
                }
                Text(settingsSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    OrbitHaptics.tap()
                    showsPairing = true
                } label: {
                    Label("Pair with Sunshine", systemImage: "link")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                .disabled(!sunshine.reachable)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 24, tint: theme.accent, elevated: true)
    }

    /// Tap on a card: stream here when possible, otherwise launch on the PC.
    private func play(_ game: SunshineGame) {
        OrbitHaptics.press()
        if canStream, let app = sunshine.app(titled: game.title) {
            startStream(app)
        } else {
            Task { await vm.smartLaunch(game: game) }
        }
    }

    private func startStream(_ app: MoonlightApp, promptUnlock: Bool = false) {
        stream.begin(.init(host: sunshine, app: app, pcName: vm.selectedPCName, settings: streamSettings.settings, promptUnlock: promptUnlock))
    }
}

struct GameCoverCard: View {
    let game: SunshineGame
    var artwork: Data? = nil
    var isRunning = false
    var streamsHere = false
    let onLaunch: () -> Void
    var onStream: (() -> Void)? = nil
    var onLaunchOnPC: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.orbitTheme) private var theme

    private var accent: Color { theme.isFlat ? theme.accent : Color(hex: game.accentHex) }

    var body: some View {
        Button(action: onLaunch) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.isFlat ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(LinearGradient(
                            colors: [accent.opacity(0.55), accent.opacity(0.16), Color.black.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )))
                    if artwork != nil {
                        MoonlightArtwork(data: artwork)
                    } else {
                        if !theme.isFlat {
                            Circle()
                                .fill(accent.opacity(0.35))
                                .frame(width: 120, height: 120)
                                .blur(radius: 30)
                                .offset(x: 30, y: 30)
                        }
                        Image(systemName: game.iconSymbol)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(theme.isFlat ? Color.white.opacity(0.9) : .white)
                            .shadow(color: reduceGlow || theme.isFlat ? .clear : accent.opacity(0.8), radius: 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if isRunning {
                        Text("RUNNING")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(accent, in: Capsule())
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    Image(systemName: streamsHere ? "play.rectangle.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.92), in: Circle())
                        .padding(10)
                }
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(streamsHere ? "Tap to stream" : (game.genre.isEmpty ? "Sunshine app" : game.genre))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 10)
            }
            .padding(12)
            .liquidGlass(cornerRadius: 22, tint: accent)
        }
        .buttonStyle(.orbitPressable)
        .contextMenu {
            if let onStream { Button("Stream Here", systemImage: "play.rectangle.fill", action: onStream) }
            if let onLaunchOnPC { Button("Launch on PC Only", systemImage: "desktopcomputer", action: onLaunchOnPC) }
            if let onSettings { Button("Stream Settings…", systemImage: "slider.horizontal.3", action: onSettings) }
        }
        .accessibilityLabel(streamsHere ? "Stream \(game.title)" : "Launch \(game.title) on PC")
    }
}

// MARK: - Remote

/// Multitouch trackpad backed by UIKit gesture recognisers: one finger moves,
/// two fingers scroll, a two-finger tap right-clicks and a long press holds the
/// left button for drag. Movement is coalesced before reaching the network.
struct OrbitTrackpadSurface: UIViewRepresentable {
    var sensitivity: Double
    var onMove: (Int, Int) -> Void
    var onScroll: (Int, Int) -> Void
    var onClick: (String) -> Void
    var onDrag: (Bool) -> Void
    var onTouch: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMove(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        move.delegate = coordinator

        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = coordinator

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.delegate = coordinator

        let secondaryTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSecondaryTap(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        secondaryTap.delegate = coordinator

        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.38
        hold.allowableMovement = 8
        hold.delegate = coordinator

        [move, scroll, tap, secondaryTap, hold].forEach { view.addGestureRecognizer($0) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OrbitTrackpadSurface
        private var lastTranslation: CGPoint = .zero
        private var pendingX = 0.0
        private var pendingY = 0.0
        private var lastFlush = Date.distantPast
        private var scrollTranslation: CGPoint = .zero
        private var scrollRemainderY = 0.0
        private var scrollRemainderX = 0.0
        private var isHolding = false
        private var isPanning = false

        init(parent: OrbitTrackpadSurface) { self.parent = parent }

        /// Only the trackpad's own recognisers run together; the enclosing
        /// ScrollView keeps UIKit's default exclusivity so the page does not
        /// scroll while the cursor is being moved.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view === gestureRecognizer.view
        }

        @objc func handleMove(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                isPanning = true
                lastTranslation = .zero
                pendingX = 0; pendingY = 0
                parent.onTouch(recognizer.location(in: view))
            case .changed:
                let translation = recognizer.translation(in: view)
                pendingX += Double(translation.x - lastTranslation.x) * parent.sensitivity
                pendingY += Double(translation.y - lastTranslation.y) * parent.sensitivity
                lastTranslation = translation
                parent.onTouch(recognizer.location(in: view))
                if Date().timeIntervalSince(lastFlush) >= 0.024 { flush() }
            case .ended, .cancelled, .failed:
                flush()
                isPanning = false
                lastTranslation = .zero
                parent.onTouch(nil)
            default:
                break
            }
        }

        private func flush() {
            let dx = Int(pendingX)
            let dy = Int(pendingY)
            guard dx != 0 || dy != 0 else { return }
            pendingX -= Double(dx)
            pendingY -= Double(dy)
            lastFlush = Date()
            parent.onMove(dx, dy)
        }

        @objc func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                scrollTranslation = .zero
                scrollRemainderX = 0; scrollRemainderY = 0
            case .changed:
                let translation = recognizer.translation(in: view)
                scrollRemainderY += Double(translation.y - scrollTranslation.y)
                scrollRemainderX += Double(translation.x - scrollTranslation.x)
                scrollTranslation = translation
                let stepSize = 16.0
                let verticalSteps = Int(scrollRemainderY / stepSize)
                let horizontalSteps = Int(scrollRemainderX / stepSize)
                if verticalSteps != 0 || horizontalSteps != 0 {
                    scrollRemainderY -= Double(verticalSteps) * stepSize
                    scrollRemainderX -= Double(horizontalSteps) * stepSize
                    // Natural scrolling: fingers down moves content down (wheel up).
                    parent.onScroll(max(-8, min(8, verticalSteps)), max(-8, min(8, -horizontalSteps)))
                }
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !isHolding else { return }
            parent.onClick("left")
        }

        @objc func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onClick("right")
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                // A slow, precise nudge must stay a plain cursor move.
                guard !isPanning else { return }
                isHolding = true
                parent.onDrag(true)
            case .ended, .cancelled, .failed:
                guard isHolding else { return }
                isHolding = false
                flush()
                parent.onDrag(false)
            default:
                break
            }
        }
    }
}

struct QuickRemoteView: View {
    @ObservedObject var vm: OrbitViewModel
    var isEmbeddedInDuo = false
    @State private var keyboardInput = ""
    @State private var confirmCloseApp = false
    @State private var touchPoint: CGPoint?
    @State private var isDragging = false
    @State private var showsGamepad = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.remote.sensitivity") private var sensitivity = 2.0
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        Group {
            if isEmbeddedInDuo {
                remoteContent
            } else {
                NavigationStack {
                    ZStack {
                        OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                        remoteContent
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
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { keyboardFocused = false }
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
        }
    }

    private var remoteContent: some View {
        GeometryReader { geo in
            let isSplitRemote = geo.size.width >= 680 && !isEmbeddedInDuo
            let trackpadHeight = max(200, min(360, geo.size.height * (isSplitRemote ? 0.5 : 0.32)))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if !vm.metrics.isOnline {
                        OrbitNotice(title: "PC Offline", message: "Connect to your PC to use the trackpad, keyboard, and media controls.", icon: "wifi.slash", tint: .orange)
                    }
                    Group {
                        if isSplitRemote {
                            HStack(alignment: .top, spacing: 16) {
                                trackpad(height: trackpadHeight)
                                    .frame(maxWidth: .infinity)
                                VStack(spacing: 16) {
                                    keyboard
                                    mediaControls
                                    gamepad
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                trackpad(height: trackpadHeight)
                                keyboard
                                mediaControls
                                gamepad
                            }
                        }
                    }
                    .disabled(!vm.metrics.isOnline)
                    .opacity(vm.metrics.isOnline ? 1 : 0.5)
                }
                .frame(maxWidth: 1400)
                .padding(isEmbeddedInDuo ? 12 : 18)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Trackpad

    private func trackpad(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Trackpad", systemImage: "hand.draw.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                sensitivityPicker
            }

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.055), Color.white.opacity(0.025)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isDragging ? theme.accent.opacity(0.7) : .white.opacity(0.08), lineWidth: isDragging ? 1.5 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isDragging)

                VStack(spacing: 8) {
                    Image(systemName: isDragging ? "hand.tap.fill" : "cursorarrow.motionlines")
                        .font(.system(size: 30, weight: .light))
                        .contentTransition(.symbolEffect(.replace))
                    Text(isDragging ? "Dragging · release to drop" : "Drag to move · Tap to click · Two fingers scroll · Hold to drag")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(isDragging ? theme.accent.opacity(0.8) : .white.opacity(0.26))
                .padding(.horizontal, 20)
                .allowsHitTesting(false)

                if let touchPoint {
                    Circle()
                        .fill(theme.accent.opacity(0.22))
                        .frame(width: 46, height: 46)
                        .overlay(Circle().strokeBorder(theme.accent.opacity(0.6), lineWidth: 1))
                        .shadow(color: reduceGlow || theme.isFlat ? .clear : theme.accent.opacity(0.6), radius: 14)
                        .position(touchPoint)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }

                OrbitTrackpadSurface(
                    sensitivity: sensitivity,
                    onMove: { dx, dy in
                        guard vm.metrics.isOnline else { return }
                        Task { await vm.sendCursorInput(dx: dx, dy: dy) }
                    },
                    onScroll: { vertical, horizontal in
                        guard vm.metrics.isOnline else { return }
                        Task { await vm.sendCursorInput(scroll: vertical, hscroll: horizontal) }
                    },
                    onClick: { button in
                        guard vm.metrics.isOnline else { return }
                        OrbitHaptics.tap()
                        Task { await vm.sendCursorInput(click: button) }
                    },
                    onDrag: { active in
                        guard vm.metrics.isOnline else { return }
                        OrbitHaptics.press()
                        withAnimation(.snappy) { isDragging = active }
                        Task { await vm.sendCursorInput(drag: active ? "down" : "up") }
                    },
                    onTouch: { point in
                        withAnimation(.easeOut(duration: 0.18)) { touchPoint = point }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .allowsHitTesting(vm.metrics.isOnline)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityLabel("PC trackpad")
            .accessibilityHint("Drag to move the cursor, tap to click, use two fingers to scroll, hold to drag")
            .accessibilityAction(named: "Scroll up") { Task { await vm.sendCursorInput(scroll: 3) } }
            .accessibilityAction(named: "Scroll down") { Task { await vm.sendCursorInput(scroll: -3) } }
            .accessibilityAction(named: "Left click") { Task { await vm.sendCursorInput(click: "left") } }
            .accessibilityAction(named: "Right click") { Task { await vm.sendCursorInput(click: "right") } }
            .accessibilityAction(named: isDragging ? "Drop" : "Start drag") {
                let next = !isDragging
                isDragging = next
                Task { await vm.sendCursorInput(drag: next ? "down" : "up") }
            }

            HStack(spacing: 8) {
                remoteButton("Left", icon: "computermouse") { await vm.sendCursorInput(click: "left") }
                remoteButton("Middle", icon: "scroll") { await vm.sendCursorInput(click: "middle") }
                remoteButton("Right", icon: "contextualmenu.and.cursorarrow") { await vm.sendCursorInput(click: "right") }
                remoteButton("Double", icon: "cursorarrow.click.2") { await vm.sendCursorInput(click: "double") }
                OrbitActionTile(title: isDragging ? "Drop" : "Drag", icon: isDragging ? "hand.point.up.left.fill" : "hand.point.up.left", tint: theme.accent, isActive: isDragging, minHeight: 52) {
                    guard vm.metrics.isOnline else { return }
                    let next = !isDragging
                    withAnimation(.snappy) { isDragging = next }
                    Task { await vm.sendCursorInput(drag: next ? "down" : "up") }
                }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, tint: theme.accent)
        .onDisappear {
            if isDragging {
                isDragging = false
                Task { await vm.sendCursorInput(drag: "up") }
            }
        }
    }

    private var sensitivityPicker: some View {
        HStack(spacing: 4) {
            ForEach([("Slow", 1.2), ("Normal", 2.0), ("Fast", 3.0)], id: \.0) { label, value in
                let selected = abs(sensitivity - value) < 0.05
                Button {
                    OrbitHaptics.selection()
                    sensitivity = value
                } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(selected ? theme.accent.opacity(0.22) : .white.opacity(0.05), in: Capsule())
                        .foregroundStyle(selected ? theme.accent : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Cursor speed")
    }

    // MARK: Keyboard

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keyboard", systemImage: "keyboard.fill")
                .font(.subheadline.weight(.bold))
            HStack(spacing: 8) {
                TextField("Type text to send…", text: $keyboardInput)
                    .submitLabel(.send)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyboardFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(keyboardFocused ? theme.accent.opacity(0.5) : .white.opacity(0.06), lineWidth: 1))
                    .onSubmit(sendCurrentText)
                Button(action: sendCurrentText) {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(keyboardInput.isEmpty ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(theme.heroGradient), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(keyboardInput.isEmpty ? Color.secondary : Color.black.opacity(0.85))
                }
                .buttonStyle(.orbitPressable)
                .disabled(keyboardInput.isEmpty)
                .accessibilityLabel("Send text")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                keyButton("Enter", key: "ENTER", icon: "return")
                keyButton("Backspace", key: "BACKSPACE", icon: "delete.left")
                keyButton("Space", key: "SPACE", icon: "space")
                keyButton("Esc", key: "ESC", icon: "escape")
                keyButton("Win", key: "WIN", icon: "command")
                keyButton("Tab", key: "TAB", icon: "arrow.right.to.line")
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22)
    }

    private func keyButton(_ title: String, key: String, icon: String) -> some View {
        Button {
            OrbitHaptics.tap()
            Task { await vm.sendKeyboardInput(key: key) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.orbitPressable)
    }

    // MARK: Media & shortcuts

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Media & Desktop", systemImage: "play.tv.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if vm.metrics.activeGame != nil {
                    Button {
                        confirmCloseApp = true
                    } label: {
                        Label("Quit Game", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .orange, cornerRadius: 20))
                }
            }
            HStack(spacing: 8) {
                remoteButton("Prev", icon: "backward.end.fill") { await vm.sendPowerAction("media_prev") }
                remoteButton("Play", icon: "playpause.fill") { await vm.sendPowerAction("media_play_pause") }
                remoteButton("Next", icon: "forward.end.fill") { await vm.sendPowerAction("media_next") }
                remoteButton("Vol −", icon: "speaker.minus.fill") { await vm.sendPowerAction("volume_down") }
                remoteButton("Vol +", icon: "speaker.plus.fill") { await vm.sendPowerAction("volume_up") }
                remoteButton(vm.metrics.isMuted ? "Unmute" : "Mute", icon: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: vm.metrics.isMuted ? .orange : nil) {
                    await vm.sendPowerAction("mute")
                }
            }
            HStack(spacing: 8) {
                remoteButton("Desktop", icon: "menubar.dock.rectangle") { await vm.sendPowerAction("show_desktop") }
                remoteButton("Task View", icon: "rectangle.3.group") { await vm.sendPowerAction("task_view") }
                remoteButton("Alt+Tab", icon: "macwindow.on.rectangle") { await vm.sendPowerAction("alt_tab") }
                remoteButton("Fullscreen", icon: "arrow.up.left.and.arrow.down.right") { await vm.sendPowerAction("fullscreen") }
                remoteButton("Screenshot", icon: "camera.viewfinder") { await vm.sendPowerAction("screenshot") }
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22)
    }

    // MARK: Gamepad (keyboard-mapped)

    private var gamepad: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                OrbitHaptics.selection()
                withAnimation(.snappy) { showsGamepad.toggle() }
            } label: {
                HStack {
                    Label("Gamepad", systemImage: "gamecontroller.fill")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("WASD · Space · Esc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsGamepad ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsGamepad ? "Hide gamepad" : "Show gamepad")

            if showsGamepad {
                HStack(alignment: .center, spacing: 18) {
                    VStack(spacing: 6) {
                        padButton("UP", icon: "arrowtriangle.up.fill")
                        HStack(spacing: 6) {
                            padButton("LEFT", icon: "arrowtriangle.left.fill")
                            Circle().fill(.white.opacity(0.05)).frame(width: 44, height: 44)
                            padButton("RIGHT", icon: "arrowtriangle.right.fill")
                        }
                        padButton("DOWN", icon: "arrowtriangle.down.fill")
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        padButton("Y", label: "Y", tint: .yellow)
                        HStack(spacing: 6) {
                            padButton("X", label: "X", tint: .blue)
                            Circle().fill(.white.opacity(0.05)).frame(width: 44, height: 44)
                            padButton("B", label: "B", tint: .red)
                        }
                        padButton("A", label: "A", tint: .green)
                    }
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22)
    }

    private func padButton(_ button: String, icon: String? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        Button {
            OrbitHaptics.tap()
            Task { await vm.sendGamepadButton(button) }
        } label: {
            ZStack {
                Circle()
                    .fill((tint ?? theme.accent).opacity(0.16))
                Circle()
                    .strokeBorder((tint ?? theme.accent).opacity(0.3), lineWidth: 1)
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(tint ?? theme.accent)
                } else if let label {
                    Text(label).font(.system(size: 15, weight: .heavy)).foregroundStyle(tint ?? theme.accent)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.orbitPressable)
        .accessibilityLabel("Gamepad \(label ?? button.capitalized)")
    }

    private func remoteButton(_ title: String, icon: String, tint: Color? = nil, action: @escaping () async -> Void) -> some View {
        Button {
            OrbitHaptics.tap()
            Task { await action() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint ?? .white)
                    .frame(height: 18)
                Text(title)
                    .font(.system(.caption2, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 2)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.orbitPressable)
    }

    private func sendCurrentText() {
        guard vm.metrics.isOnline, !keyboardInput.isEmpty else { return }
        let text = keyboardInput
        keyboardInput = ""
        OrbitHaptics.success()
        Task { await vm.sendKeyboardInput(text: text) }
    }
}

// MARK: - Launch overlay & stream placeholder

struct SmartLaunchOverlay: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    OrbitRingGauge(progress: stepProgress, lineWidth: 5, tint: theme.accent)
                        .frame(width: 72, height: 72)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.heroGradient)
                }
                Text(vm.activeStreamingGame?.title ?? "Connecting to PC").font(.headline)
                Text(vm.smartLaunchStep.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(26)
            .frame(maxWidth: 300)
            .liquidGlass(tint: theme.accent, elevated: true)
        }
    }

    private var stepProgress: Double {
        switch vm.smartLaunchStep {
        case .idle: return 0
        case .checkingPC: return 0.15
        case .sendingWoL: return 0.3
        case .waitingBoot: return 0.45
        case .handshaking: return 0.65
        case .launchingGame: return 0.85
        case .streaming: return 1
        }
    }
}

/// Desktop preview: JPEG frames from the agent's `/ws/stream` socket. Game video with
/// audio and controller input stays in Moonlight; this is for a quick look at the desktop.
struct MoonlightStreamView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()
                if let frame = vm.liveFrameImage {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Live desktop of \(vm.selectedPCName)")
                } else if let error = vm.streamError {
                    OrbitEmptyState(icon: "exclamationmark.triangle", title: "Preview interrupted", message: error, tint: .orange,
                                    actionTitle: "Retry") { vm.startLiveScreenFeed() }
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(theme.accent)
                        Text("Connecting to \(vm.selectedPCName)…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Desktop Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { vm.stopStreaming(putPCToSleep: false) }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("Snapshots only, no audio. For games open Moonlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { vm.startLiveScreenFeed() }
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
    @Environment(\.orbitTheme) private var theme
    @State private var isConnecting = false
    @State private var isShowingDashboardCustomization = false
    @State private var isShowingDiscovery = false
    @State private var isShowingProPaywall = false
    @State private var isShowingPrivacy = false
    @State private var isShowingAcknowledgements = false
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        OrbitMark(size: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vm.isConfigured ? vm.selectedPCName : "Orbit Companion")
                                .font(.headline.weight(.bold))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                OrbitStatusPill(text: vm.isDemoMode ? "Demo" : (vm.metrics.isOnline ? (vm.metrics.sessionLocked == true ? "Locked" : "Online") : "Offline"),
                                                tint: vm.metrics.isOnline && !vm.isDemoMode ? (vm.metrics.sessionLocked == true ? .yellow : .mint) : .orange,
                                                pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                                if vm.metrics.isOnline, let version = vm.metrics.agentVersion {
                                    Text("Agent \(version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        Button("Pair PC") { isShowingDiscovery = true }
                            .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 20))
                            .font(.caption.weight(.bold))
                    }
                    .padding(.vertical, 4)

                    NavigationLink { PCProfilesView(vm: vm) } label: {
                        settingsRow("Saved PCs & Profiles", icon: "desktopcomputer", tint: theme.accent, detail: "\(vm.savedPCs.count)")
                    }
                }
                .orbitRow(tint: theme.accent)

                Section {
                    Button {
                        isShowingProPaywall = true
                    } label: {
                        HStack {
                            settingsRow("Orbit Pro", icon: "crown.fill", tint: .yellow)
                            Spacer()
                            Text(proStore.isProUnlocked ? "ACTIVE" : (proStore.displayPrice ?? "PRO"))
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.yellow.opacity(0.2), in: Capsule())
                                .foregroundStyle(.yellow)
                        }
                    }
                    if let status = proStore.statusMessage {
                        Text(status).font(.caption).foregroundStyle(.yellow)
                    }
                }
                .orbitRow(tint: .yellow)

                pcCompanionUpdateSection

                Section("Personalization & iOS") {
                    NavigationLink { AppearanceSettingsView() } label: {
                        settingsRow("Themes & Home Screen Icons", icon: "paintpalette.fill", tint: .pink, detail: theme.title)
                    }
                    Button { isShowingDashboardCustomization = true } label: {
                        settingsRow("Customize Overview Cards", icon: "slider.horizontal.3", tint: theme.accent)
                    }
                    NavigationLink { LiveActivitySettingsView(vm: vm) } label: {
                        settingsRow("Dynamic Island & Live Activity", icon: "capsule.portrait.tophalf.filled", tint: .mint, detail: vm.isDynamicIslandActive ? "Active" : "Off")
                    }
                    NavigationLink { NotificationsSettingsView(vm: vm) } label: {
                        settingsRow("Notifications & PC Alerts", icon: "bell.badge.fill", tint: .red,
                                    detail: UserDefaults.standard.bool(forKey: OrbitNotificationPreferences.enabledKey) ? "On" : "Off")
                    }
                    NavigationLink { WidgetHelpView(vm: vm) } label: {
                        settingsRow("Widgets, Control Center & Siri", icon: "square.grid.2x2.fill", tint: .orange)
                    }
                    NavigationLink { AppleWatchCompanionHelpView(vm: vm) } label: {
                        settingsRow("Apple Watch", icon: "applewatch.radiowaves.left.and.right", tint: .green)
                    }
                }
                .orbitRow()

                Section("Hardware & Diagnostics") {
                    NavigationLink { FullSpecsView(vm: vm) } label: {
                        settingsRow("Hardware Specifications", icon: "cpu", tint: .indigo)
                    }
                    NavigationLink { MonitoringSourcesView(vm: vm) } label: {
                        settingsRow("Sensor Sources", icon: "waveform.path.ecg", tint: .teal)
                    }
                    NavigationLink { FPSSetupView(vm: vm) } label: {
                        settingsRow("FPS Counter Setup", icon: "speedometer", tint: .mint)
                    }
                }
                .orbitRow()

                connectionSection
                wakeSection

                Section("Preferences & Legal") {
                    Toggle(isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) })) {
                        settingsRow("Demo Mode (Sample Data)", icon: "sparkles", tint: .orange)
                    }
                    Toggle(isOn: $vm.autoOpenMoonlight) {
                        settingsRow("Auto-Open Moonlight on Launch", icon: "arrow.up.forward.app", tint: .purple)
                    }
                    Button {
                        if isPresentedAsSheet { dismiss() }
                        vm.showOnboarding = true
                    } label: {
                        settingsRow("Run Setup Walkthrough", icon: "wand.and.stars", tint: theme.accent)
                    }
                    Button {
                        isShowingPrivacy = true
                    } label: {
                        settingsRow("Privacy Policy & Terms", icon: "hand.raised.fill", tint: .gray)
                    }
                    Button {
                        isShowingAcknowledgements = true
                    } label: {
                        settingsRow("Acknowledgements & Licenses", icon: "doc.text.fill", tint: .gray)
                    }
                }
                .orbitRow()
            }
            .orbitListChrome(isOnline: vm.metrics.isOnline)
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
            .sheet(isPresented: $isShowingAcknowledgements) {
                OrbitAcknowledgementsView(accent: theme.accent)
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

    private func settingsRow(_ title: String, icon: String, tint: Color, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 30)
            Text(title)
                .foregroundStyle(.white)
            if let detail {
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var pcCompanionUpdateSection: some View {
        Section {
            LabeledContent("Installed Agent", value: vm.metrics.agentVersion ?? "—")
            if let latest = vm.agentLatestVersion {
                LabeledContent("Latest on GitHub", value: latest)
            }
            Button {
                Task { await vm.checkPCCompanionUpdate() }
            } label: {
                HStack {
                    settingsRow(vm.isCheckingAgentUpdate ? "Checking GitHub…" : "Check for PC Companion Update", icon: "arrow.triangle.2.circlepath", tint: theme.accent)
                    Spacer()
                    if vm.isCheckingAgentUpdate { ProgressView() }
                }
            }
            .disabled(vm.isCheckingAgentUpdate)

            if vm.agentUpdateAvailable {
                Button {
                    Task { await vm.applyPCCompanionUpdate() }
                } label: {
                    settingsRow("Install Update on PC Now", icon: "arrow.down.circle.fill", tint: .mint)
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
                settingsRow("Send PC Companion Link to PC", icon: "square.and.arrow.up", tint: .blue)
            }

            Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip")!) {
                settingsRow("Download Windows Companion (.zip)", icon: "arrow.down.doc.fill", tint: .blue)
            }

            Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                settingsRow("Open GitHub Repository", icon: "arrow.up.right.square", tint: .gray)
            }
        } header: {
            Text("PC Companion Updates (GitHub)")
        }
        .orbitRow()
    }

    private var connectionSection: some View {
        Section("Manual Connection") {
            DisclosureGroup {
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
            } label: {
                settingsRow("Connection & Ports", icon: "network", tint: .blue)
            }
        }
        .orbitRow()
    }

    private var wakeSection: some View {
        Section("Wake-on-LAN") {
            DisclosureGroup {
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
            } label: {
                settingsRow("Wake-on-LAN Settings", icon: "power", tint: .green)
            }
            Button {
                OrbitHaptics.press()
                Task { await vm.wakePC() }
            } label: {
                settingsRow("Send Wake Packet Now", icon: "bolt.fill", tint: .green)
            }
            .disabled(!vm.isConfigured || vm.pcMAC.isEmpty || vm.isWakingUp)
        }
        .orbitRow()
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
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            Section("Home & Lock Screen Widgets") {
                widgetRow("Power & Quick Controls", detail: "Interactive Power On (Wake), Sleep & Shut Down buttons directly on Home Screen", icon: "power.circle.fill", tint: .green)
                widgetRow("PC Overview & Gaming", detail: "CPU, GPU, RAM, VRAM, FPS & temps with On/Off buttons (Small, Medium, Large)", icon: "desktopcomputer", tint: theme.accent)
                widgetRow("Specialty Panels", detail: "Dedicated Power, Temperatures, Cooling, Storage & Network widgets", icon: "bolt.fill", tint: .orange)
                widgetRow("Single PC Metric", detail: "Pick any 1 of 18 sensors for Home or Lock Screen", icon: "waveform.path.ecg", tint: .purple)
            }
            .orbitRow()

            Section("Control Center & Siri (iOS 18+)") {
                widgetRow("Control Center Buttons", detail: "Swipe down Control Center → tap + → Add a Control → search Orbit to add Power On, Sleep, or Shut Down buttons", icon: "switch.2", tint: .mint)
                widgetRow("Siri & Shortcuts", detail: "Say \"Hey Siri, power on my PC with Orbit\", \"Lock my PC with Orbit\" or \"How is my PC doing in Orbit\"", icon: "mic.fill", tint: .pink)
            }
            .orbitRow()

            OrbitShortcutsHelpSections()

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
            .orbitRow()

            Section("Quick Tip") {
                Text("Long-press any Orbit widget and tap Edit Widget to switch between paired PCs or change its colour theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Widgets & Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pairedPCs = OrbitWidgetConnectionStore.connections() }
        .orbitAppearance()
    }

    private func widgetRow(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 36)
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
    @State private var page = 0
    @State private var showsDiscovery = false
    @State private var isTesting = false
    @State private var connectionPassed = false
    @State private var didTest = false
    @FocusState private var focusedField: Bool
    @Environment(\.orbitTheme) private var theme

    private let introPages: [(icon: String, title: String, text: String, tint: Color)] = [
        ("gauge.with.dots.needle.67percent", "Your PC,\nwithin reach.", "Live CPU, GPU, memory, power and FPS telemetry on iPhone, iPad, Apple Watch, Apple TV and the Dynamic Island.", OrbitTheme.noir.accent),
        ("computermouse.fill", "Control the whole desk.", "Trackpad, keyboard, media keys, per-app audio mixer, file transfers and a remote task manager.", OrbitTheme.noir.accent),
        ("lock.shield.fill", "Private by design.", "Everything stays on your local network. Pairing uses a one-time 6-digit code, TLS 1.3 and certificate pinning. No cloud, no accounts.", OrbitTheme.noir.accent)
    ]

    private var lastIntroPage: Int { introPages.count - 1 }
    private var setupPage: Int { introPages.count }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                VStack(spacing: 0) {
                    TabView(selection: $page) {
                        ForEach(Array(introPages.enumerated()), id: \.offset) { index, item in
                            introPage(item)
                                .tag(index)
                        }
                        setupStep
                            .tag(setupPage)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.snappy, value: page)

                    footer
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if page < setupPage {
                        Button("Skip") { withAnimation(.snappy) { page = setupPage } }
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.hasCompletedOnboarding {
                        Button("Close") { vm.showOnboarding = false }
                    }
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
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }

    private func introPage(_ item: (icon: String, title: String, text: String, tint: Color)) -> some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.12))
                    .frame(width: 180, height: 180)
                    .blur(radius: 10)
                Circle()
                    .strokeBorder(LinearGradient(colors: [item.tint, item.tint.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    .frame(width: 150, height: 150)
                Image(systemName: item.icon)
                    .font(.system(size: 60, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [.white, item.tint], startPoint: .top, endPoint: .bottom))
                    .shadow(color: item.tint.opacity(0.6), radius: 20)
            }
            VStack(spacing: 12) {
                Text(item.title)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 28)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0...setupPage, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? theme.accent : .white.opacity(0.2))
                        .frame(width: index == page ? 22 : 7, height: 7)
                        .animation(.snappy, value: page)
                }
            }
            if page < setupPage {
                Button {
                    OrbitHaptics.selection()
                    withAnimation(.snappy) { page = min(setupPage, page + 1) }
                } label: {
                    HStack {
                        Text(page == lastIntroPage ? "Set up my PC" : "Continue")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                .frame(maxWidth: 420)
            }
        }
    }

    private var setupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    OrbitMark(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect your PC")
                            .font(.system(size: 26, weight: .bold))
                        Text("Two steps, about a minute.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                connectionForm
                VStack(spacing: 10) {
                    Button {
                        focusedField = false
                        OrbitHaptics.success()
                        vm.hasCompletedOnboarding = true
                        vm.showOnboarding = false
                    } label: {
                        HStack { Text("Continue to Orbit"); Spacer(); Image(systemName: "arrow.right") }
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))
                    .disabled(!connectionPassed || !vm.metrics.isOnline)
                    .opacity(!connectionPassed || !vm.metrics.isOnline ? 0.5 : 1)

                    Button("Try Demo Mode") {
                        focusedField = false
                        vm.setDemoMode(true)
                        vm.hasCompletedOnboarding = true
                        vm.showOnboarding = false
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                stepLabel(1, "Install on your Windows PC", tint: theme.accent)
                Text("Download Orbit PC Companion on your Windows PC and run install_orbit.bat. It lives in the system tray.")
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
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 12))

                    Link(destination: URL(string: "https://github.com/AceDimi2005/Orbit")!) {
                        Label("GitHub Page", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .white, cornerRadius: 12))
                }
            }

            Divider().overlay(.white.opacity(0.12))

            stepLabel(2, "Pair with the 6-digit code", tint: theme.accent)
            Text("Keep Orbit Companion running on Windows, then tap Find my PC. The code appears on your PC screen.")
                .font(.caption).foregroundStyle(.secondary)

            Button {
                OrbitHaptics.press()
                showsDiscovery = true
            } label: {
                Label("Find my PC", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(OrbitProminentButtonStyle(colors: theme.heroGradientColors))

            if connectionPassed {
                Label("Paired securely · \(vm.selectedPCName)", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.mint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                            if connectionPassed { OrbitHaptics.success() } else { OrbitHaptics.error() }
                        }
                    } label: {
                        HStack {
                            if isTesting { ProgressView().tint(theme.accent) }
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
        .liquidGlass(tint: theme.accent, elevated: true)
        .animation(.snappy, value: connectionPassed)
    }

    private func stepLabel(_ number: Int, _ title: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(tint, in: Circle())
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Hardware inventory

struct FullSpecsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showNames = false
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: vm.metrics.isOnline ? "checkmark.seal.fill" : "clock", tint: vm.metrics.isOnline ? .mint : .secondary, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.isDemoMode ? "Demo Hardware" : (vm.metrics.isOnline ? "Detected Hardware" : "Cached Hardware"))
                            .font(.subheadline.weight(.semibold))
                        if let source = vm.specs?.source {
                            Text(source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Rename") { showNames = true }
                        .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 20))
                        .font(.caption.weight(.bold))
                }
            }
            .orbitRow(tint: theme.accent)
            if let specs = vm.specs {
                inventory(specs)
            } else if vm.isLoadingSpecs {
                Section { HStack { ProgressView(); Text("Reading hardware…").padding(.leading, 8) } }
                    .orbitRow()
            } else {
                Section {
                    OrbitEmptyState(icon: "cpu", title: "No Specs Loaded", message: vm.specsError ?? "Connect to your PC to read hardware specifications.", tint: theme.accent)
                }
                .orbitRow()
            }
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
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
        Section {
            specRow("Computer", specs.hostname)
            specRow("OS", specs.osName)
            specRow("Version", specs.osVersion)
            specRow("Architecture", specs.architecture)
        } header: { sectionHeader("System", icon: "desktopcomputer", tint: theme.accent) }
        .orbitRow()
        Section {
            displayName("cpu")
            specRow("Model", specs.cpu.name)
            specRow("Cores / Threads", specs.cpu.physicalCores.map { "\($0)C / \(specs.cpu.logicalCores ?? $0)T" })
            specRow("Max Clock", specs.cpu.maxClockMHz.map { "\(decimal($0 / 1000, digits: 2)) GHz" })
            specRow("Temperature", vm.metrics.cpuTemp.map { "\(decimal($0))°C" })
        } header: { sectionHeader("Processor", icon: "cpu", tint: .cyan) }
        .orbitRow()
        Section {
            displayName("gpu")
            if specs.gpus.isEmpty { specRow("GPU", nil) }
            ForEach(Array(specs.gpus.enumerated()), id: \.offset) { index, gpu in
                if index > 0 { Divider() }
                specRow("Model", gpu.name)
                specRow("VRAM", gpu.vramGB.map { "\(decimal($0)) GB" })
                specRow("Driver", gpu.driverVersion)
            }
        } header: { sectionHeader("Graphics", icon: "square.stack.3d.up", tint: .mint) }
        .orbitRow()
        Section {
            displayName("memory")
            specRow("Installed", specs.memory.totalGB.map { "\(decimal($0)) GB" })
            ForEach(Array(specs.memory.modules.enumerated()), id: \.offset) { index, module in
                DisclosureGroup(module.slot ?? "Slot \(index + 1)") {
                    specRow("Part", module.partNumber)
                    specRow("Capacity", module.capacityGB.map { "\(decimal($0)) GB" })
                    specRow("Speed", module.speedMHz.map { "\(decimal($0, digits: 0)) MHz" })
                }
            }
        } header: { sectionHeader("Memory", icon: "memorychip", tint: Color(red: 0.68, green: 0.65, blue: 0.98)) }
        .orbitRow()
        Section {
            displayName("motherboard")
            specRow("Board", [specs.motherboard.manufacturer, specs.motherboard.model].compactMap { $0 }.joined(separator: " "))
            specRow("BIOS", specs.motherboard.biosVersion)
            displayName("cooler")
            specRow("Cooler", specs.coolerName)
        } header: { sectionHeader("Motherboard & Cooling", icon: "fanblades", tint: .blue) }
        .orbitRow()
        Section {
            displayName("storage")
            ForEach(Array(specs.disks.enumerated()), id: \.offset) { index, disk in
                DisclosureGroup(disk.name ?? "Drive \(index + 1)") {
                    specRow("Capacity", disk.sizeGB.map { "\(decimal($0)) GB" })
                    specRow("Type", [disk.interfaceType, disk.mediaType].compactMap { $0 }.joined(separator: " · "))
                }
            }
            ForEach(Array(specs.volumes.enumerated()), id: \.offset) { _, volume in
                if let mount = volume.mountpoint {
                    specRow(mount, volumeDescription(volume))
                }
            }
        } header: { sectionHeader("Storage", icon: "internaldrive", tint: .orange) }
        .orbitRow()
        if !specs.networkAdapters.isEmpty {
            Section {
                ForEach(Array(specs.networkAdapters.enumerated()), id: \.offset) { index, adapter in
                    DisclosureGroup(adapter.name ?? "Adapter \(index + 1)") {
                        specRow("MAC", adapter.macAddress)
                        specRow("IPv4", adapter.ipv4Addresses.isEmpty ? nil : adapter.ipv4Addresses.joined(separator: ", "))
                    }
                }
            } header: { sectionHeader("Network", icon: "network", tint: .teal) }
            .orbitRow()
        }
    }

    private func volumeDescription(_ volume: PCSpecs.Volume) -> String? {
        var parts: [String] = []
        if let used = volume.usedGB, let total = volume.totalGB, total > 0 {
            parts.append("\(decimal(used, digits: 0)) / \(decimal(total, digits: 0)) GB")
        } else if let total = volume.totalGB {
            parts.append("\(decimal(total, digits: 0)) GB")
        }
        if let fs = volume.fileSystem { parts.append(fs) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(title)
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
                Section {
                    ForEach(components, id: \.0) { key, title in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            TextField(detectedName(key), text: Binding(get: { names[key] ?? "" }, set: { names[key] = $0 }))
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Custom Labels")
                } footer: {
                    Text("Labels replace detected component names on the Overview cards for this PC only.")
                }
                .orbitRow()
                Section {
                    Button("Reset to Detected Names", role: .destructive) { names = [:] }
                }
                .orbitRow()
            }
            .orbitListChrome()
            .navigationTitle("Custom Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        for (key, _) in components { vm.setComponentOverride(key, value: names[key] ?? "") }
                        OrbitHaptics.success()
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
