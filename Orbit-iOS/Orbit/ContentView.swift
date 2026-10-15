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
        .tint(.cyan)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : vm.dashboardConfiguration.columnCount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if vm.isDemoMode { previewNotice }
                        computerHeader
                        if vm.metrics.isOnline {
                            if vm.dashboardConfiguration.showsGame, let game = vm.metrics.activeGame { activeGameCard(game) }
                            if vm.metrics.telemetryAvailable == false {
                                OrbitNotice(title: "Reading your PC", message: "The agent is connected and collecting its first hardware readings.", icon: "waveform.path.ecg")
                            } else {
                                metricsGrid
                            }
                            if vm.dashboardConfiguration.showsSpecifications { specsLink }
                            if vm.dashboardConfiguration.showsVolume { volumeCard }
                            if vm.dashboardConfiguration.showsQuickControls { powerCard }
                        } else {
                            offlineCard
                            if vm.dashboardConfiguration.showsSpecifications { specsLink }
                        }
                        if vm.dashboardConfiguration.showsConnectionStatus {
                            Text(vm.statusLog)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await vm.refreshMetrics() }
            }
            .navigationTitle("Your PC")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { isShowingPCs = true } label: { Image(systemName: "desktopcomputer.and.arrow.down") }
                        .accessibilityLabel("Switch PC")
                    Button { isShowingCustomization = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Customize dashboard")
                    Button { vm.isShowingIPConfigSheet = true } label: {
                        Image(systemName: "network")
                    }
                    .accessibilityLabel("Connection settings")
                }
            }
            .sheet(isPresented: $isShowingCustomization) {
                DashboardCustomizationView(vm: vm)
            }
            .sheet(isPresented: $isShowingPCs) { NavigationStack { PCProfilesView(vm: vm) } }
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
        OrbitNotice(title: "Preview mode", message: "Sample data. Connect your PC in Settings to see real readings.", icon: "sparkles", tint: .orange)
    }

    private var computerHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(vm.metrics.isOnline ? .cyan : .secondary)
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 7) {
                Text(vm.isConfigured || vm.isDemoMode ? vm.metrics.hostname : "Meet your PC companion")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.metrics.isOnline ? Color.mint : .orange)
                        .frame(width: 6, height: 6)
                    Text(vm.isDemoMode ? "Sample PC" : (vm.metrics.isOnline ? "Connected · \(vm.pingMs) ms" : "Not connected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if vm.metrics.isOnline && vm.metrics.telemetryAvailable != false {
                    Text("Uptime \(vm.metrics.formattedUptime)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let date = vm.lastUpdated {
                    Text("Last seen \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .liquidGlass(tint: .cyan)
    }

    @ViewBuilder
    private var metricsGrid: some View {
        if vm.dashboardConfiguration.orderedVisibleMetrics.isEmpty {
            Button { isShowingCustomization = true } label: {
                OrbitNotice(title: "Make room for what matters", message: "Choose the readings you want on your dashboard.", icon: "slider.horizontal.3")
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
                detail: vm.metrics.cpuTemp.map { "\(Int($0))°C · CPU load" } ?? "CPU load · temperature unavailable"
            )
        case .gpuLoad:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                valueText: vm.metrics.gpuUsage.map(percent) ?? "—", progress: vm.metrics.gpuUsage.map { $0 / 100 },
                icon: metric.symbol, accent: metric.accent, detail: gpuDetail
            )
        case .memory:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("memory", detected: "System memory"),
                valueText: vm.metrics.ramTotalGB > 0 ? "\(decimal(vm.metrics.ramUsedGB)) GB" : "—",
                progress: vm.metrics.ramTotalGB > 0 ? vm.metrics.ramUsedGB / vm.metrics.ramTotalGB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ramTotalGB > 0 ? "\(decimal(vm.metrics.ramTotalGB)) GB total · in use" : "Memory unavailable"
            )
        case .storage:
            HardwareMetricCard(
                title: metric.title, subtitle: vm.componentName("storage", detected: vm.specs?.disks.first?.name ?? "Local storage"),
                valueText: vm.metrics.ssdTotalTB > 0 ? "\(decimal(vm.metrics.ssdUsedTB, digits: 2)) TB" : "—",
                progress: vm.metrics.ssdTotalTB > 0 ? vm.metrics.ssdUsedTB / vm.metrics.ssdTotalTB : nil,
                icon: metric.symbol, accent: metric.accent,
                detail: vm.metrics.ssdTotalTB > 0 ? "\(decimal(vm.metrics.ssdTotalTB, digits: 2)) TB total · used" : "Storage unavailable"
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
                       detail: "CPU package power sensor")
        case .gpuPower:
            sensorCard(metric, value: vm.metrics.gpuPowerWatts, unit: "W",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName),
                       detail: "Reported graphics power draw")
        case .cpuTemperature:
            sensorCard(metric, value: vm.metrics.cpuTemp, unit: "°C",
                       subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName), detail: "Processor temperature")
        case .gpuTemperature:
            sensorCard(metric, value: vm.metrics.gpuTemp, unit: "°C",
                       subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName), detail: "Graphics temperature")
        case .coolantTemperature:
            sensorCard(metric, value: vm.metrics.liquidTemp, unit: "°C",
                       subtitle: vm.componentName("cooler", detected: vm.metrics.coolerName), detail: "Liquid cooler sensor")
        case .cpuClock:
            HardwareMetricCard(title: metric.title, subtitle: vm.componentName("cpu", detected: vm.metrics.cpuName),
                               valueText: vm.metrics.cpuClockMHz.map { "\(decimal($0 / 1000, digits: 2)) GHz" } ?? "—", progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.cpuClockMHz == nil ? "Clock sensor unavailable" : (vm.metrics.cpuClockSource ?? "Reported clock"))
        case .network:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.networkInterface ?? "Selected network adapters",
                               valueText: transferRate(vm.metrics.networkDownloadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.networkDownloadMBps == nil && vm.metrics.networkUploadMBps == nil ? "Traffic counters unavailable" : "↓ Download · ↑ \(transferRate(vm.metrics.networkUploadMBps)) upload")
        case .diskActivity:
            HardwareMetricCard(title: metric.title, subtitle: "All physical drives",
                               valueText: transferRate(vm.metrics.diskReadMBps), progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.diskReadMBps == nil && vm.metrics.diskWriteMBps == nil ? "Drive counters unavailable" : "Read · \(transferRate(vm.metrics.diskWriteMBps)) write")
        case .uptime:
            HardwareMetricCard(title: metric.title, subtitle: "Since the last Windows boot",
                               valueText: vm.metrics.formattedUptime, progress: nil,
                               icon: metric.symbol, accent: metric.accent, detail: "Fast Startup may preserve uptime")
        case .fps:
            HardwareMetricCard(title: metric.title, subtitle: vm.metrics.activeGame ?? "No game detected",
                               valueText: vm.metrics.fps.map { "\(Int($0.rounded())) FPS" } ?? "—", progress: nil,
                               icon: metric.symbol, accent: metric.accent,
                               detail: vm.metrics.fps == nil ? (vm.metrics.fpsUnavailableReason ?? "An active frame-rate source is required") : "From \(vm.metrics.fpsSource ?? "your PC")")
        case .cpuFan:
            sensorCard(metric, value: vm.metrics.cpuFanRPM, unit: "RPM", subtitle: "Processor cooling", detail: "Reported CPU fan speed")
        case .gpuFan:
            sensorCard(metric, value: vm.metrics.gpuFanPercent, unit: "%", subtitle: vm.componentName("gpu", detected: vm.metrics.gpuName), detail: "Reported GPU fan speed")
        }
    }

    private func sensorCard(_ metric: DashboardMetric, value: Double?, unit: String, subtitle: String, detail: String) -> some View {
        HardwareMetricCard(title: metric.title, subtitle: subtitle,
                           valueText: value.map { "\(Int($0.rounded()))\(unit == "°C" || unit == "%" ? "" : " ")\(unit)" } ?? "—", progress: nil,
                           icon: metric.symbol, accent: metric.accent,
                           detail: value == nil ? (vm.metrics.sensorStatus ?? "Sensor unavailable · check PC sensor setup") : detail)
    }

    private var vramProgress: Double? {
        guard let used = vm.metrics.vramUsedGB, let total = vm.metrics.vramTotalGB, total > 0 else { return nil }
        return used / total
    }

    private var vramDetail: String {
        guard vm.metrics.vramUsedGB != nil else { return "VRAM usage sensor unavailable" }
        if let total = vm.metrics.vramTotalGB, total > 0 { return "\(decimal(total)) GB total · dedicated memory" }
        return "Dedicated memory · capacity unavailable"
    }

    private func transferRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1 { return "\(decimal(value)) MB/s" }
        if value >= 0.001 { return "\(decimal(value * 1000, digits: 1)) KB/s" }
        return "\(decimal(value * 1_000_000, digits: 0)) B/s"
    }

    private var gpuDetail: String {
        var parts: [String] = []
        if let temperature = vm.metrics.gpuTemp { parts.append("\(Int(temperature))°C") }
        if let watts = vm.metrics.gpuPowerWatts { parts.append("\(Int(watts)) W") }
        if parts.isEmpty { return vm.metrics.gpuUsage == nil ? "GPU sensors unavailable" : "GPU load · temperature unavailable" }
        return parts.joined(separator: " · ")
    }

    private func activeGameCard(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW PLAYING").font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(title).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let fps = vm.metrics.fps {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(fps.rounded()))").font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text("FPS").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if vm.metrics.fps == nil {
                Text(vm.metrics.fpsUnavailableReason ?? "FPS requires an active frame-rate source on your PC.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let source = vm.metrics.fpsSource {
                Text("Frame rate from \(source)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .liquidGlass(tint: .mint)
    }

    private var specsLink: some View {
        NavigationLink { FullSpecsView(vm: vm) } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full PC specifications").font(.subheadline.weight(.semibold))
                    Text("Hardware, storage and component names").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(18)
            .liquidGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private var volumeCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("PC volume", systemImage: vm.metrics.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(vm.metrics.volumeAvailable == false ? "Unavailable" : (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%"))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button {
                    Task { await vm.sendPowerAction("mute") }
                } label: {
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(vm.metrics.isMuted ? "Unmute PC" : "Mute PC")
                Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                    vm.isDraggingVolume = editing
                }
                .accessibilityLabel("PC volume")
            }
            if vm.metrics.volumeAvailable == false {
                Text("The PC’s audio service is not reporting volume controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .liquidGlass(cornerRadius: 22)
        .disabled(!vm.metrics.isOnline || vm.metrics.volumeAvailable == false)
    }

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quick controls").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Sleep", systemImage: "moon") { pendingAction = .sleep }
                    Button("Restart", systemImage: "arrow.clockwise") { pendingAction = .restart }
                    Button("Shut down", systemImage: "power", role: .destructive) { pendingAction = .shutdown }
                } label: {
                    Label("Power", systemImage: "power").font(.subheadline)
                }
            }
            HStack(spacing: 10) {
                controlButton("Lock", icon: "lock") { Task { await vm.sendPowerAction("lock") } }
                controlButton("Wake display", icon: "display") { Task { await vm.sendPowerAction("restore_display") } }
                controlButton("Preview", icon: "rectangle.on.rectangle") { vm.openDesktopPreview() }
            }
        }
        .padding(20)
        .liquidGlass(cornerRadius: 22)
        .disabled(!vm.metrics.isOnline)
    }

    private func controlButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }

    private var offlineCard: some View {
        VStack(spacing: 20) {
            Button {
                Task { await vm.wakePC() }
            } label: {
                ZStack {
                    Circle().fill(.cyan.opacity(0.08)).frame(width: 118, height: 118)
                    Circle().strokeBorder(.cyan.opacity(0.2), lineWidth: 1).frame(width: 118, height: 118)
                    if vm.isWakingUp {
                        ProgressView().controlSize(.large).tint(.cyan)
                    } else {
                        Image(systemName: "power").font(.system(size: 38, weight: .light)).foregroundStyle(.cyan)
                    }
                }
            }
            .disabled(vm.isWakingUp || !vm.isConfigured || vm.pcMAC.isEmpty)
            .accessibilityLabel("Wake PC")
            VStack(spacing: 8) {
                Text(vm.isWakingUp ? "Waking your PC…" : "Wake your PC")
                    .font(.title3.weight(.semibold))
                Text(vm.isConfigured ? "Your PC is asleep or the Orbit agent is unreachable. Wake-on-LAN needs a configured MAC address and a compatible network." : "Connect your Windows PC to see live hardware readings and use remote controls.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Connect PC", systemImage: "network") { vm.showOnboarding = true }
                    .buttonStyle(.borderedProminent).tint(.cyan).foregroundStyle(.black)
                if vm.isConfigured {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await vm.connect() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .liquidGlass(tint: .cyan)
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
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your readings. Your layout.")
                            .font(.title3.weight(.semibold))
                        Text("Keep the essentials close, or build a dashboard for your next gaming session.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetButton("Balanced", icon: "square.grid.2x2", configuration: .balanced)
                            presetButton("Gaming", icon: "gamecontroller", configuration: .gaming)
                            presetButton("Work", icon: "hammer", configuration: .workstation)
                            presetButton("Cooling", icon: "fanblades", configuration: .cooling)
                            presetButton("Everything", icon: "rectangle.grid.3x2", configuration: .allMetrics)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Picker("Columns", selection: $draft.columnCount) {
                        Text("One column").tag(1)
                        Text("Two columns").tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Layout") } footer: {
                    Text("Larger accessibility text automatically uses one column.")
                }
                Section {
                    ForEach(draft.metricOrder) { metric in
                        HStack(spacing: 12) {
                            Image(systemName: metric.symbol)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(metric.accent)
                                .frame(width: 32, height: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(metric.title).font(.subheadline.weight(.medium))
                                Text(metric.explanation).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                draft.setVisible(metric, !draft.visibleMetrics.contains(metric))
                            } label: {
                                Image(systemName: draft.visibleMetrics.contains(metric) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(draft.visibleMetrics.contains(metric) ? Color.cyan : .secondary)
                                    .frame(width: 32, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(metric.title), \(draft.visibleMetrics.contains(metric) ? "shown" : "hidden")")
                            .accessibilityHint("Double tap to \(draft.visibleMetrics.contains(metric) ? "hide" : "show") this reading")
                        }
                    }
                    .onMove { source, destination in draft.metricOrder.move(fromOffsets: source, toOffset: destination) }
                } header: {
                    HStack {
                        Text("Readings")
                        Spacer()
                        Text("\(draft.orderedVisibleMetrics.count) selected")
                    }
                } footer: {
                    Text("Tap a circle to show or hide a reading. Drag the handles to reorder. Sensor support depends on your hardware and the PC agent; unavailable readings display a dash.")
                }
                Section {
                    Toggle("Now playing", isOn: $draft.showsGame)
                    Toggle("PC volume", isOn: $draft.showsVolume)
                    Toggle("Quick controls", isOn: $draft.showsQuickControls)
                    Toggle("PC specifications", isOn: $draft.showsSpecifications)
                    Toggle("Connection status", isOn: $draft.showsConnectionStatus)
                } header: { Text("Additional sections") } footer: {
                    Text("CPU and GPU wattage describe those components only. They do not measure your PC’s total wall power.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize dashboard")
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
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }

    private func presetButton(_ title: String, icon: String, configuration: DashboardConfiguration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { draft = configuration }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .foregroundStyle(draft == configuration ? Color.cyan : .primary)
            .background(draft == configuration ? Color.cyan.opacity(0.10) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(draft == configuration ? Color.cyan.opacity(0.35) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Apply \(title.lowercased()) preset")
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

    var explanation: String {
        switch self {
        case .cpuLoad: return "Processor utilization"
        case .gpuLoad: return "Graphics utilization"
        case .memory: return "System memory in use"
        case .storage: return "Used and total storage"
        case .vram: return "Dedicated graphics memory"
        case .cpuPower: return "Processor package wattage"
        case .gpuPower: return "Graphics power in watts"
        case .cpuTemperature: return "Processor temperature"
        case .gpuTemperature: return "Graphics temperature"
        case .coolantTemperature: return "Liquid cooling temperature"
        case .cpuClock: return "Reported clock frequency"
        case .network: return "Download and upload rates"
        case .diskActivity: return "Drive read and write rates"
        case .uptime: return "Time since Windows started"
        case .fps: return "Active game frame rate"
        case .cpuFan: return "Processor fan speed in RPM"
        case .gpuFan: return "Graphics fan speed in percent"
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
        self == .sleep ? "Your remote connection will close. Wake-on-LAN must be configured to wake the PC again." : "Save your work first. Open apps and your remote connection will close."
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
                    VStack(alignment: .leading, spacing: 20) {
                        OrbitNotice(title: "Your Sunshine library", message: "Launch an app on your PC, then open Moonlight for game streaming. Orbit also offers a lightweight desktop preview.", icon: "gamecontroller")
                        if vm.isDemoMode {
                            OrbitNotice(title: "Sample library", message: "These games are examples. Connect your PC to load your own apps.", icon: "sparkles", tint: .orange)
                        }
                        if !vm.metrics.isOnline {
                            OrbitNotice(title: "PC not connected", message: "Connect or wake your PC from Overview to load and launch apps.", icon: "wifi.slash", tint: .orange)
                        }
                        if filteredGames.isEmpty {
                            ContentUnavailableView(searchText.isEmpty ? "Your library starts here" : "No matching apps", systemImage: "square.grid.2x2", description: Text(searchText.isEmpty ? "Add apps to Sunshine on your PC, then refresh your library." : "Try another search."))
                                .padding(.vertical, 32)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 14) {
                                ForEach(filteredGames) { game in
                                    GameCoverCard(game: game) { Task { await vm.smartLaunch(game: game) } }
                                        .disabled(!vm.metrics.isOnline)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await vm.fetchSunshineApps() }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search your apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await vm.fetchSunshineApps() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!vm.metrics.isOnline)
                        .accessibilityLabel("Refresh library")
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
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [Color(hex: game.accentHex).opacity(0.25), Color(hex: game.accentHex).opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: game.iconSymbol)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(Color(hex: game.accentHex))
                }
                .frame(height: 108)
                Text(game.title).font(.headline).lineLimit(2).frame(minHeight: 42, alignment: .topLeading)
                HStack {
                    Text("Launch on PC").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.cyan)
                }
            }
            .padding(14)
            .liquidGlass(cornerRadius: 22)
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

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if !vm.metrics.isOnline {
                            OrbitNotice(title: "Connect your PC first", message: "Remote controls become available when the Orbit agent is connected.", icon: "wifi.slash", tint: .orange)
                        } else if vm.isDemoMode {
                            OrbitNotice(title: "Preview controls", message: "These controls are simulated while preview mode is enabled.", icon: "sparkles", tint: .orange)
                        }
                        VStack(spacing: 20) {
                            trackpad
                            keyboard
                            mediaControls
                        }
                        .disabled(!vm.metrics.isOnline)
                        .opacity(vm.metrics.isOnline ? 1 : 0.5)
                        Text(vm.statusLog).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 720)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Remote")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { TaskManagerView(vm: vm) } label: { Label("Task Manager", systemImage: "list.bullet.rectangle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { vm.openDesktopPreview() } label: { Label("Desktop preview", systemImage: "display") }
                        .disabled(!vm.metrics.isOnline)
                }
            }
            .confirmationDialog("Close the active game?", isPresented: $confirmCloseApp, titleVisibility: .visible) {
                Button("Close game", role: .destructive) { Task { await vm.sendPowerAction("kill_game") } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Orbit asks the detected foreground game to close. Save your progress first; the game may ask you to confirm on the PC.")
            }
        }
    }

    private var trackpad: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Trackpad", systemImage: "hand.draw").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Drag to move · tap to click").font(.caption2).foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.035))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 32, weight: .light))
                        Text("Your PC, at your fingertips").font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.28))
                    .allowsHitTesting(false)
                }
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.05), lineWidth: 1) }
                .frame(height: 220)
                .contentShape(RoundedRectangle(cornerRadius: 20))
                .gesture(DragGesture(minimumDistance: 1).onChanged(handleDrag).onEnded { _ in finishDrag() })
                .simultaneousGesture(TapGesture().onEnded {
                    guard vm.metrics.isOnline else { return }
                    Task { await vm.sendMouseInput(click: "left") }
                })
                .allowsHitTesting(vm.metrics.isOnline)
                .accessibilityLabel("PC trackpad. Drag to move the pointer, tap to click.")
            HStack(spacing: 10) {
                remoteButton("Left click", icon: "computermouse") { await vm.sendMouseInput(click: "left") }
                remoteButton("Double", icon: "cursorarrow.click.2") { await vm.sendMouseInput(click: "double") }
                remoteButton("Right click", icon: "line.3.horizontal") { await vm.sendMouseInput(click: "right") }
            }
            HStack(spacing: 10) {
                remoteButton("Scroll up", icon: "arrow.up") { await vm.sendMouseInput(scroll: 3) }
                remoteButton("Scroll down", icon: "arrow.down") { await vm.sendMouseInput(scroll: -3) }
            }
        }
        .padding(18)
        .liquidGlass(tint: .cyan)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Keyboard", systemImage: "keyboard").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                TextField("Send text to your PC", text: $keyboardInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(sendCurrentText)
                Button(action: sendCurrentText) {
                    Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 44, height: 44)
                        .background(.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(keyboardInput.isEmpty)
                .accessibilityLabel("Send text")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(["ENTER", "BACKSPACE", "SPACE", "ESC", "WIN", "TAB"], id: \.self) { key in
                    Button { Task { await vm.sendKeyboardInput(key: key) } } label: {
                        Text(key == "WIN" ? "Windows" : key.capitalized)
                            .font(.caption).frame(maxWidth: .infinity, minHeight: 40)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .liquidGlass(cornerRadius: 22)
    }

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Media & apps").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                remoteButton("Previous", icon: "backward.end.fill") { await vm.sendPowerAction("media_prev") }
                remoteButton("Play / pause", icon: "playpause.fill") { await vm.sendPowerAction("media_play_pause") }
                remoteButton("Next", icon: "forward.end.fill") { await vm.sendPowerAction("media_next") }
            }
            Button { confirmCloseApp = true } label: {
                HStack {
                    Label("Close active game", systemImage: "xmark.square")
                    Spacer()
                    Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                }
                .font(.caption).padding(.vertical, 10)
            }
            .tint(.orange)
        }
        .padding(18)
        .liquidGlass(cornerRadius: 22)
    }

    private func remoteButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
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
            VStack(spacing: 20) {
                ProgressView().controlSize(.large).tint(.cyan)
                Text(vm.activeStreamingGame?.title ?? "Connecting to your PC").font(.headline)
                Text(vm.smartLaunchStep.rawValue).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: 320)
            .liquidGlass(tint: .cyan)
        }
    }
}

/// The agent sends JPEG screenshots. Game streaming is handled by the separate Moonlight app.
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
                    ContentUnavailableView(vm.streamError == nil ? "Waiting for the desktop" : "Desktop preview unavailable", systemImage: "display", description: Text(vm.streamError ?? (vm.isDemoMode ? "Desktop images are available when your PC is connected." : "Keep the Orbit agent running on your PC. A desktop capture will appear here.")))
                }
            }
            .navigationTitle("Desktop preview")
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
                VStack(spacing: 5) {
                    if let error = vm.streamError {
                        Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("Try again", systemImage: "arrow.clockwise") { vm.startLiveScreenFeed() }
                            .font(.caption).padding(.bottom, 5).disabled(vm.isDemoMode || !vm.metrics.isOnline)
                    }
                    Text("JPEG desktop preview").font(.caption.weight(.medium))
                    Text("Use Moonlight for smooth game streaming and audio. Configure quality inside Moonlight.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(.ultraThinMaterial)
            }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var isShowingDashboardCustomization = false
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        OrbitMark(size: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Orbit").font(.title3.weight(.semibold))
                            Text("A little closer to your PC.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    NavigationLink { FullSpecsView(vm: vm) } label: {
                        Label("PC specifications", systemImage: "cpu")
                    }
                    NavigationLink { PCProfilesView(vm: vm) } label: {
                        Label("My PCs & encrypted connection", systemImage: "desktopcomputer.and.arrow.down")
                    }
                    NavigationLink { TaskManagerView(vm: vm) } label: {
                        Label("Task Manager", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink { FPSSetupView(vm: vm) } label: {
                        Label("Set up FPS", systemImage: "speedometer")
                    }
                    NavigationLink { MonitoringSourcesView(vm: vm) } label: {
                        Label("Monitoring sources", systemImage: "waveform.path.ecg")
                    }
                    Button("Connection walkthrough", systemImage: "sparkles") {
                        if isPresentedAsSheet { dismiss() }
                        vm.showOnboarding = true
                    }
                }
                connectionSection
                wakeSection
                Section {
                    Toggle("Preview mode", isOn: Binding(get: { vm.isDemoMode }, set: { vm.setDemoMode($0) }))
                    Toggle("Open Moonlight after launch", isOn: $vm.autoOpenMoonlight)
                    Button { isShowingDashboardCustomization = true } label: {
                        Label("Customize dashboard", systemImage: "slider.horizontal.3")
                    }
                } header: { Text("Experience") } footer: {
                    Text("Preview mode uses sample data. For game streaming, install Moonlight and pair it with Sunshine on your PC.")
                }
                Section {
                    Toggle("Live Activity", isOn: Binding(get: { vm.isDynamicIslandActive }, set: { enabled in
                        if enabled != vm.isDynamicIslandActive { vm.toggleDynamicIsland() }
                    }))
                    .disabled(!vm.metrics.isOnline && !vm.isDynamicIslandActive)
                    Picker("Live Activity focus", selection: $vm.dashboardConfiguration.activityFocus) {
                        ForEach(LiveActivityFocus.allCases) { focus in
                            Text(focus.title).tag(focus)
                        }
                    }
                    NavigationLink {
                        WidgetHelpView(vm: vm)
                    } label: { Label("Home Screen widgets", systemImage: "square.grid.2x2") }
                } header: { Text("At a glance") } footer: {
                    Text("Live Activities appear on the Lock Screen and on supported Dynamic Islands. Readings update while Orbit is open and become stale in the background; continuous background monitoring is not enabled.")
                }
                Section("Connection status") {
                    Label(vm.isDemoMode ? "Preview data" : (vm.metrics.isOnline ? "PC connected" : "PC not connected"), systemImage: vm.metrics.isOnline ? "checkmark.circle" : "wifi.slash")
                        .foregroundStyle(vm.metrics.isOnline ? .mint : .orange)
                    Text(vm.statusLog).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let lastUpdated = vm.lastUpdated {
                        LabeledContent("Last update", value: lastUpdated.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $isShowingDashboardCustomization) {
                DashboardCustomizationView(vm: vm)
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
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }

    private var connectionSection: some View {
        Section {
            labeledField("PC address", placeholder: "e.g. 192.168.1.100", text: $vm.pcIP)
                .onChange(of: vm.pcIP) { _, _ in vm.recalculateBroadcastIfNeeded() }
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent access token").font(.caption).foregroundStyle(.secondary)
                SecureField("Token shown by your PC agent", text: $vm.apiToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
            }
            Button {
                focusedField = false
                isConnecting = true
                vm.saveCurrentConnection()
                Task { await vm.connect(); isConnecting = false }
            } label: {
                HStack {
                    Label(isConnecting ? "Connecting…" : "Save & test connection", systemImage: "network")
                    Spacer()
                    if isConnecting { ProgressView() }
                }
            }
            .disabled(isConnecting || !vm.isConfigured)
            DisclosureGroup("Advanced network settings") {
                Button {
                    focusedField = false
                    Task { await vm.scanLANForPC() }
                } label: {
                    HStack {
                        Label(vm.isScanningLAN ? "Scanning network…" : "Find PC on local network", systemImage: "antenna.radiowaves.left.and.right")
                        if vm.isScanningLAN { Spacer(); ProgressView() }
                    }
                }
                .disabled(vm.isScanningLAN)
                portField("Agent port", value: $vm.agentPort)
                labeledField("Subnet mask", placeholder: "255.255.255.0", text: $vm.subnetMask)
                    .onChange(of: vm.subnetMask) { _, _ in vm.recalculateBroadcastIfNeeded() }
                Toggle("Calculate broadcast automatically", isOn: $vm.autoCalcBroadcast)
                    .onChange(of: vm.autoCalcBroadcast) { _, _ in vm.recalculateBroadcastIfNeeded() }
                labeledField("Broadcast address", placeholder: "e.g. 192.168.1.255", text: $vm.wolTargetIP)
                    .disabled(vm.autoCalcBroadcast)
                portField("Wake-on-LAN port", value: $vm.wolPort)
            }
        } header: { Text("Your Windows PC") } footer: {
            Text("Run the Orbit agent on your PC and connect both devices to the same trusted network. Enter the address and token shown by the agent.")
        }
    }

    private var wakeSection: some View {
        Section {
            labeledField("PC MAC address", placeholder: "AA:BB:CC:DD:EE:FF", text: $vm.pcMAC)
            Button("Detect network details from PC", systemImage: "arrow.down.circle") {
                Task { await vm.fetchNetworkConfigFromPC() }
            }
            .disabled(!vm.metrics.isOnline || vm.isDemoMode)
            Button("Wake PC", systemImage: "power") { Task { await vm.wakePC() } }
                .disabled(!vm.isConfigured || vm.pcMAC.isEmpty || vm.isWakingUp)
        } header: { Text("Wake-on-LAN") } footer: {
            Text("Enable Wake-on-LAN in your PC’s firmware and network adapter settings. Keep the PC connected to power; wired Ethernet is usually the most reliable option.")
        }
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
    @State private var tokenCopied = false

    var body: some View {
        List {
            Section {
                Label("A view for every moment", systemImage: "square.grid.2x2")
                    .font(.headline)
                Text("Choose Overview, Gaming, Power, Thermals or a single reading. Launcher widgets keep your overview, library and remote controls one tap away.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    tokenCopied = false
                    Task { await vm.prepareWidgetAccess() }
                } label: {
                    HStack {
                        Label(vm.isLoadingWidgetToken ? "Preparing…" : "Prepare widget access", systemImage: "key")
                        Spacer()
                        if vm.isLoadingWidgetToken { ProgressView() }
                    }
                }
                .disabled(!vm.metrics.isOnline || vm.isDemoMode || vm.isLoadingWidgetToken)
                if vm.isConfigured {
                    LabeledContent("PC address", value: vm.cleanHost())
                        .font(.subheadline).textSelection(.enabled)
                    LabeledContent("Agent port", value: "\(vm.agentPort)")
                        .font(.subheadline)
                }
                if let token = vm.widgetToken {
                    Button {
                        UIPasteboard.general.string = token
                        tokenCopied = true
                    } label: {
                        Label(tokenCopied ? "Widget token copied" : "Copy read-only widget token", systemImage: tokenCopied ? "checkmark.circle" : "doc.on.doc")
                    }
                }
                if let error = vm.widgetSetupError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Pair your monitoring widgets") } footer: {
                Text("Connect your PC first. Monitoring widgets use a separate read-only token. Enter this widget token when editing a widget; it cannot control your PC.")
            }
            Section("Add a widget") {
                instruction(1, "Touch and hold your Home Screen, then choose Edit and Add Widget.")
                instruction(2, "Search for Orbit and choose a widget and size.")
                instruction(3, "Touch and hold the widget, then choose Edit Widget. Enter the PC address, agent port and read-only widget token.")
            }
            Section {
                Text("iOS schedules widget refreshes. Readings are snapshots, not a continuous stream, and are marked stale after 15 minutes. The PC must be reachable on your network to update.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("For a recent reading on your Lock Screen or Dynamic Island, start a Live Activity while connected to your PC.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } header: { Text("Refresh behavior") }
        }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(width: 24, height: 24)
                .background(.cyan.opacity(0.08), in: Circle())
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - First-run setup

struct OnboardingView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var isTesting = false
    @State private var connectionPassed = false
    @State private var didTest = false
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        welcome
                        connectionForm
                        VStack(spacing: 12) {
                            Button {
                                focusedField = false
                                vm.hasCompletedOnboarding = true
                                vm.showOnboarding = false
                            } label: {
                                HStack { Text("Continue to my PC"); Spacer(); Image(systemName: "arrow.right") }
                                    .font(.headline).padding(18).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan).foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .disabled(!connectionPassed || !vm.metrics.isOnline)
                            Button("Explore with sample data") {
                                focusedField = false
                                vm.setDemoMode(true)
                                vm.hasCompletedOnboarding = true
                                vm.showOnboarding = false
                            }
                            .font(.subheadline).padding(10)
                            Text("Your PC stays in your control. Orbit connects over your local network.")
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        .tint(.cyan).preferredColorScheme(.dark)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            OrbitMark(size: 84)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your PC.\nWithin reach.")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Meet Orbit, your everyday Windows companion.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                feature("Live insights", icon: "waveform.path.ecg")
                feature("Wake on LAN", icon: "power")
                feature("Remote control", icon: "computermouse")
            }
            .padding(.vertical, 6)
        }
    }

    private func feature(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(.cyan)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your PC").font(.headline)
                Text("Start Orbit Agent 4.0.0 on Windows, then copy its address, access token and certificate fingerprint. Both devices should use the same Wi-Fi or local network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("PC address").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("e.g. 192.168.1.100", text: $vm.pcIP)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                    .padding(13).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: vm.pcIP) { _, _ in connectionPassed = false; didTest = false; vm.recalculateBroadcastIfNeeded() }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Agent access token").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                SecureField("Paste your PC’s token", text: $vm.apiToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                    .padding(13).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: vm.apiToken) { _, _ in connectionPassed = false; didTest = false }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("PC certificate fingerprint").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("Paste Certificate SHA-256 from the PC", text: $vm.certificateFingerprint, axis: .vertical)
                    .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField)
                    .lineLimit(2...4).padding(13).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: vm.certificateFingerprint) { _, _ in connectionPassed = false; didTest = false }
                Text("This verifies your PC before sending the token. It also enables encrypted Files, clipboard, audio mixer and history.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Custom agent port") {
                TextField("Secure port 8766", value: $vm.securePort, format: .number.grouping(.never))
                    .keyboardType(.numberPad).focused($focusedField)
                    .onChange(of: vm.securePort) { _, _ in connectionPassed = false; didTest = false }
                TextField("8765", value: $vm.agentPort, format: .number.grouping(.never))
                    .keyboardType(.numberPad).focused($focusedField)
                    .onChange(of: vm.agentPort) { _, _ in connectionPassed = false; didTest = false }
                    .padding(.top, 10)
            }
            .font(.caption).foregroundStyle(.secondary)
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
                    Label(isTesting ? "Connecting…" : "Test connection", systemImage: "network")
                    Spacer()
                    if connectionPassed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint) }
                }
                .font(.subheadline.weight(.semibold)).padding(.vertical, 4)
            }
            .disabled(isTesting || !vm.isConfigured || !vm.hasSecureConnection)
            if didTest {
                Label(connectionPassed ? "Connected. Your hardware is detected automatically." : vm.statusLog, systemImage: connectionPassed ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(connectionPassed ? .mint : .orange)
            }
        }
        .padding(20)
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
                if vm.isDemoMode {
                    Label("Sample hardware · preview mode", systemImage: "sparkles").foregroundStyle(.orange)
                } else {
                    Label(vm.metrics.isOnline ? "Detected by your PC" : "Last known hardware", systemImage: vm.metrics.isOnline ? "checkmark.seal" : "clock")
                        .foregroundStyle(vm.metrics.isOnline ? .mint : .secondary)
                }
                Text("Hardware is discovered automatically. Add a display name for a custom build or a component Windows cannot identify.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Customize component names", systemImage: "pencil") { showNames = true }
            }
            if let specs = vm.specs {
                inventory(specs)
            } else if vm.isLoadingSpecs {
                Section { HStack { ProgressView(); Text("Reading PC specifications…").padding(.leading, 8) } }
            } else {
                Section {
                    ContentUnavailableView("No specifications yet", systemImage: "cpu", description: Text(vm.specsError ?? "Connect your PC to detect its hardware. You can still enter your own component names."))
                }
            }
            if let error = vm.specsError, vm.specs != nil {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("PC specifications")
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
            specRow("Operating system", specs.osName)
            specRow("Version", specs.osVersion)
            specRow("Architecture", specs.architecture)
            specRow("Detected", specs.detectedAt)
        }
        Section("Processor") {
            displayName("cpu")
            specRow("Model", specs.cpu.name)
            specRow("Manufacturer", specs.cpu.manufacturer)
            specRow("Physical cores", specs.cpu.physicalCores.map(String.init))
            specRow("Threads", specs.cpu.logicalCores.map(String.init))
            specRow("Maximum clock", specs.cpu.maxClockMHz.map { "\(decimal($0 / 1000, digits: 2)) GHz" })
            specRow("Temperature", vm.metrics.cpuTemp.map { "\(decimal($0))°C" })
        }
        Section("Graphics") {
            displayName("gpu")
            if specs.gpus.isEmpty { specRow("GPU", nil) }
            ForEach(Array(specs.gpus.enumerated()), id: \.offset) { index, gpu in
                if index > 0 { Divider() }
                specRow("Model", gpu.name)
                specRow("Video memory", gpu.vramGB.map { "\(decimal($0)) GB" })
                specRow("Driver", gpu.driverVersion)
            }
            if let used = vm.metrics.vramUsedGB, let total = vm.metrics.vramTotalGB {
                specRow("VRAM in use", "\(decimal(used)) / \(decimal(total)) GB")
            }
            specRow("Temperature", vm.metrics.gpuTemp.map { "\(decimal($0))°C" })
            specRow("Power", vm.metrics.gpuPowerWatts.map { "\(decimal($0, digits: 0)) W" })
        }
        Section("Memory") {
            displayName("memory")
            specRow("Installed", specs.memory.totalGB.map { "\(decimal($0)) GB" })
            ForEach(Array(specs.memory.modules.enumerated()), id: \.offset) { index, module in
                DisclosureGroup(module.slot ?? "Module \(index + 1)") {
                    specRow("Manufacturer", module.manufacturer)
                    specRow("Part number", module.partNumber)
                    specRow("Capacity", module.capacityGB.map { "\(decimal($0)) GB" })
                    specRow("Reported speed", module.speedMHz.map { "\(decimal($0, digits: 0)) MHz" })
                }
            }
        }
        Section("Motherboard & cooling") {
            displayName("motherboard")
            specRow("Manufacturer", specs.motherboard.manufacturer)
            specRow("Motherboard", specs.motherboard.model)
            specRow("BIOS", specs.motherboard.biosVersion)
            displayName("cooler")
            specRow("Detected cooler", specs.coolerName)
            specRow("Coolant temperature", vm.metrics.liquidTemp.map { "\(decimal($0))°C" })
        }
        Section("Storage devices") {
            displayName("storage")
            if specs.disks.isEmpty { specRow("Disks", nil) }
            ForEach(Array(specs.disks.enumerated()), id: \.offset) { index, disk in
                DisclosureGroup(disk.name ?? "Disk \(index + 1)") {
                    specRow("Capacity", disk.sizeGB.map { "\(decimal($0)) GB" })
                    specRow("Interface", disk.interfaceType)
                    specRow("Media", disk.mediaType)
                }
            }
        }
        Section("Volumes") {
            ForEach(Array(specs.volumes.enumerated()), id: \.offset) { index, volume in
                DisclosureGroup(volume.mountpoint ?? "Volume \(index + 1)") {
                    specRow("File system", volume.fileSystem)
                    specRow("Capacity", volume.totalGB.map { "\(decimal($0)) GB" })
                    specRow("Used", volume.usedGB.map { "\(decimal($0)) GB" })
                }
            }
        }
        Section("Network adapters") {
            ForEach(Array(specs.networkAdapters.enumerated()), id: \.offset) { index, adapter in
                DisclosureGroup(adapter.name ?? "Adapter \(index + 1)") {
                    specRow("MAC address", adapter.macAddress)
                    specRow("IPv4", adapter.ipv4Addresses.isEmpty ? nil : adapter.ipv4Addresses.joined(separator: "\n"))
                }
            }
        }
        Section {
            Text("“Not reported” means the PC could not provide this information. Hardware sensor support varies; Orbit never substitutes an estimate for a missing temperature or frame rate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func displayName(_ key: String) -> some View {
        if let name = vm.componentOverrides[key], !name.isEmpty {
            specRow("Your \(key) name", name)
        }
    }

    private func specRow(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Not reported")
                .font(.subheadline)
                .foregroundStyle(value == nil || value?.isEmpty == true ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
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
                    Text("Personalize the labels shown for this PC. Leave a field empty to use its detected name. Measurements and detected specifications remain unchanged.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Component names") {
                    ForEach(components, id: \.0) { key, title in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            TextField(detectedName(key), text: Binding(get: { names[key] ?? "" }, set: { names[key] = $0 }))
                                .autocorrectionDisabled()
                        }
                        .padding(.vertical, 3)
                    }
                }
                Section {
                    Button("Use detected names", role: .destructive) { names = [:] }
                } footer: { Text("Names are saved separately for this PC.") }
            }
            .navigationTitle("Component names")
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
        .tint(.cyan).preferredColorScheme(.dark)
        .onAppear { names = vm.componentOverrides }
    }

    private func detectedName(_ key: String) -> String {
        switch key {
        case "cpu": return vm.specs?.cpu.name ?? "Detected processor"
        case "gpu": return vm.specs?.gpus.first?.name ?? "Detected graphics card"
        case "memory": return vm.specs?.memory.totalGB.map { "\(decimal($0)) GB installed" } ?? "Detected memory"
        case "motherboard": return vm.specs?.motherboard.model ?? "Detected motherboard"
        case "cooler": return vm.specs?.coolerName ?? "e.g. your cooler’s model"
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
