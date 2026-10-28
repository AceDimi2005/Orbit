import SwiftUI

/// Windows' 30-second warning after Shut Down or Restart, counting down, with Cancel while it runs.
/// `compact` is the menu bar popover's version.
struct MacPowerCountdownBanner: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let countdown = vm.powerCountdown.visible(at: context.date) {
                let running = countdown.isRunning(at: context.date)
                HStack(alignment: .center, spacing: compact ? 10 : 12) {
                    MacIconBadge(systemName: countdown.symbol, tint: .orange, size: compact ? 26 : 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(countdown.summary(at: context.date))
                            .font((compact ? Font.callout : Font.subheadline).weight(.semibold).monospacedDigit())
                            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                        Text(vm.powerCancelError ?? countdown.detail(at: context.date))
                            .font(.caption)
                            .foregroundStyle(vm.powerCancelError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(countdown.spokenSummary(at: context.date))
                    Spacer(minLength: 8)
                    if running {
                        Button {
                            Task { await vm.cancelPowerCountdown() }
                        } label: {
                            if vm.isCancellingPower {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Cancel")
                            }
                        }
                        .buttonStyle(MacHoverButtonStyle(tint: .orange, prominent: true))
                        .disabled(vm.isCancellingPower)
                        .help(countdown.cancelTitle)
                        .accessibilityLabel(countdown.cancelTitle)
                    }
                }
                .padding(compact ? 10 : 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .macGlass(cornerRadius: compact ? 12 : 16, tint: .orange)
            }
        }
    }
}

/// Dashboard: hero card, live metric grid with sparklines, quick controls and specs.
struct MacOverviewView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var pendingPower: MacPowerConfirmation?
    @State private var showsCustomizer = false
    @AppStorage("mac.reduceGlow") private var reduceGlow = false

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 215, maximum: 320), spacing: 12)] }

    var body: some View {
        MacPage {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 16) {
                    if vm.isDemoMode { demoNotice }
                    heroCard
                    if vm.metrics.isOnline || vm.isDemoMode {
                        if vm.powerCountdown.visible() != nil { MacPowerCountdownBanner().id(OrbitPowerCountdown.scrollID) }
                        if let game = vm.metrics.activeGame, !game.isEmpty { activeGameCard(game) }
                        if vm.metrics.telemetryAvailable == false && !vm.isDemoMode {
                            MacNotice(title: "Syncing sensors…", message: "Collecting the first readings from your PC. Cards appear as soon as the agent reports them.", icon: "waveform.path.ecg", tint: theme.accent)
                        } else {
                            metricsHeader
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(vm.dashboardMetrics) { metric in
                                    metricCard(metric)
                                }
                            }
                            .animation(.snappy(duration: 0.3), value: vm.dashboardMetrics)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            quickControls.frame(maxWidth: .infinity)
                            specsCard.frame(maxWidth: .infinity)
                        }
                    } else {
                        offlineCard
                        specsCard
                    }
                }
                // Restart and Shut Down sit below the readings: bring the countdown with Cancel into view.
                .onChange(of: vm.powerCountdown.countdown) { old, new in
                    guard old == nil, new != nil else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                        proxy.scrollTo(OrbitPowerCountdown.scrollID, anchor: .top)
                    }
                }
            }
        }
        .sheet(isPresented: $showsCustomizer) { MacDashboardCustomizer().environmentObject(vm) }
    }

    // MARK: Hero

    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        return vm.metrics.isOnline ? .mint : (vm.currentPC == nil ? .secondary : .orange)
    }
    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if vm.isWaking { return "Waking…" }
        if vm.currentPC == nil { return "Not paired" }
        if vm.metrics.isOnline, vm.metrics.sessionLocked == true { return "Locked" }
        return vm.metrics.isOnline ? "Online" : "Offline"
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    MacRing(progress: vm.metrics.hasTelemetry ? vm.metrics.cpuUsage / 100 : nil, lineWidth: 6, tint: theme.accent)
                        .frame(width: 72, height: 72)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(vm.metrics.isOnline || vm.isDemoMode ? AnyShapeStyle(theme.heroGradient) : AnyShapeStyle(Color.secondary))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(vm.isConfigured ? vm.selectedPCName : "No PC paired")
                            .font(.system(size: 26, weight: .bold))
                            .lineLimit(1)
                        MacStatusPill(text: statusText, tint: statusTint, pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                    }
                    Text([vm.metrics.cpuName, vm.metrics.gpuName].filter { !$0.isEmpty && $0 != "Processor" && $0 != "Graphics" }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    MacChipFlow(spacing: 8, lineSpacing: 6) {
                        if vm.metrics.isOnline && !vm.isDemoMode {
                            MacStatChip(label: "Ping", value: vm.pingMs >= 1000 ? String(format: "%.1f s", Double(vm.pingMs) / 1000) : "\(vm.pingMs) ms")
                            // "Remote": the LAN address did not answer, so Orbit uses the PC's secondary address (still encrypted).
                            MacStatChip(label: "Link", value: vm.usingSecondaryAddress ? "Remote" : (vm.currentPC?.isSecure == true ? "Encrypted" : "—"),
                                        icon: vm.usingSecondaryAddress ? "point.3.connected.trianglepath.dotted" : "lock.fill")
                                .help(vm.usingSecondaryAddress ? "Connected through the secondary IP \(vm.currentPC.map { vm.connectionHost(for: $0) } ?? "")" : "Certificate-pinned connection")
                        }
                        if vm.metrics.hasTelemetry {
                            MacStatChip(label: "Up", value: vm.metrics.formattedUptime)
                        }
                        if let version = vm.metrics.agentVersion {
                            // A beta build of the companion reads "4.6.0 β1" (OrbitCompanionVersion).
                            MacStatChip(label: "Agent", value: OrbitCompanionVersion.compact(version) ?? version)
                                .help(OrbitCompanionVersion.isPrerelease(version)
                                      ? "Beta build \(OrbitCompanionVersion.display(version) ?? version) of the PC Companion" : "PC Companion \(version)")
                        }
                        if let source = vm.metrics.sensorSource, !source.isEmpty {
                            MacStatChip(label: "Sensors", value: source)
                        }
                        if let fps = vm.peaks.fps {
                            MacStatChip(label: "Peak", value: "\(Int(fps.rounded())) FPS")
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button {
                        Task { await vm.wakePC() }
                    } label: {
                        Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power")
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: !vm.metrics.isOnline))
                    .disabled(vm.isWaking || vm.currentPC == nil || vm.metrics.isOnline)
                    Button {
                        showsCustomizer = true
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                }
                .frame(width: 150)
            }
            if !vm.statusBanner.isEmpty {
                Text(vm.statusBanner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private var demoNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo mode · simulated data")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Pair a PC") { vm.setDemoMode(false); vm.selectedSection = .pcs }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .orange)
    }

    private var metricsHeader: some View {
        MacSectionHeader("Live telemetry", subtitle: vm.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .standard)) · \(vm.dashboardMetrics.count) cards" }, icon: "waveform.path.ecg") {
            Button {
                showsCustomizer = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(MacIconButtonStyle(size: 26))
            .help("Choose cards")
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func metricCard(_ metric: MacMetric) -> some View {
        let m = vm.metrics
        let series = vm.history.values(for: metric)
        switch metric {
        case .cpuLoad:
            MacMetricCard(title: metric.title, subtitle: m.cpuName, valueText: MacFormat.percent(m.cpuUsage), progress: m.cpuUsage / 100, icon: metric.symbol, accent: metric.accent,
                          detail: join([m.cpuTemp.map { "\(Int($0))°C" }, m.cpuClockMHz.map { "\(MacFormat.decimal($0 / 1000, digits: 2)) GHz" }, m.cpuPowerWatts.map { "\(Int($0)) W" }]),
                          history: series, showsRing: true)
        case .gpuLoad:
            MacMetricCard(title: metric.title, subtitle: m.gpuName, valueText: MacFormat.percent(m.gpuUsage), progress: m.gpuUsage.map { $0 / 100 }, icon: metric.symbol, accent: metric.accent,
                          detail: join([m.gpuTemp.map { "\(Int($0))°C" }, m.gpuPowerWatts.map { "\(Int($0)) W" }, m.gpuFanPercent.map { "Fan \(Int($0))%" }]),
                          history: series, showsRing: true)
        case .memory:
            MacMetricCard(title: metric.title, subtitle: "System RAM", valueText: m.ramTotalGB > 0 ? "\(MacFormat.decimal(m.ramUsedGB)) GB" : "—",
                          progress: m.ramTotalGB > 0 ? m.ramUsedGB / m.ramTotalGB : nil, icon: metric.symbol, accent: metric.accent,
                          detail: m.ramTotalGB > 0 ? "of \(MacFormat.decimal(m.ramTotalGB, digits: 0)) GB · \(MacFormat.percent(m.ramUsagePercent))" : nil,
                          history: series, showsRing: true)
        case .vram:
            MacMetricCard(title: metric.title, subtitle: m.gpuName, valueText: m.vramUsedGB.map { "\(MacFormat.decimal($0)) GB" } ?? "—",
                          progress: m.vramUsagePercent.map { $0 / 100 }, icon: metric.symbol, accent: metric.accent,
                          detail: m.vramTotalGB.flatMap { total in m.vramUsedGB != nil ? "of \(MacFormat.decimal(total)) GB · \(MacFormat.percent(m.vramUsagePercent))" : nil },
                          history: series, showsRing: true)
        case .storage:
            MacMetricCard(title: metric.title, subtitle: vm.specs?.disks.first?.name ?? "System drive", valueText: m.ssdTotalTB > 0 ? "\(MacFormat.decimal(m.ssdUsedTB, digits: 2)) TB" : "—",
                          progress: m.ssdUsagePercent.map { $0 / 100 }, icon: metric.symbol, accent: metric.accent,
                          detail: m.ssdTotalTB > 0 ? "of \(MacFormat.decimal(m.ssdTotalTB, digits: 2)) TB · \(MacFormat.decimal(max(0, m.ssdTotalTB - m.ssdUsedTB), digits: 2)) TB free" : nil,
                          showsRing: true)
        case .cpuPower:
            MacMetricCard(title: metric.title, subtitle: m.cpuName, valueText: MacFormat.whole(m.cpuPowerWatts, unit: "W"), progress: m.cpuPowerWatts.map { min(1, max(0.04, $0 / 200)) },
                          icon: metric.symbol, accent: metric.accent, detail: m.cpuPowerWatts == nil ? nil : "Package power", history: series)
        case .gpuPower:
            MacMetricCard(title: metric.title, subtitle: m.gpuName, valueText: MacFormat.whole(m.gpuPowerWatts, unit: "W"), progress: m.gpuPowerWatts.map { min(1, max(0.04, $0 / 400)) },
                          icon: metric.symbol, accent: metric.accent, detail: m.gpuPowerWatts == nil ? nil : "Board power", history: series)
        case .cpuTemperature:
            MacMetricCard(title: metric.title, subtitle: m.cpuName, valueText: MacFormat.whole(m.cpuTemp, unit: "°C"), progress: m.cpuTemp.map { min(1, max(0.05, ($0 - 25) / 70)) },
                          icon: metric.symbol, accent: metric.accent, detail: m.cpuTemp == nil ? nil : join([m.sensorSource, vm.peaks.cpuTemp.map { "Peak \(Int($0))°C" }]), history: series)
        case .gpuTemperature:
            MacMetricCard(title: metric.title, subtitle: m.gpuName, valueText: MacFormat.whole(m.gpuTemp, unit: "°C"), progress: m.gpuTemp.map { min(1, max(0.05, ($0 - 25) / 70)) },
                          icon: metric.symbol, accent: metric.accent, detail: m.gpuTemp == nil ? nil : join([m.gpuSource, vm.peaks.gpuTemp.map { "Peak \(Int($0))°C" }]), history: series)
        case .coolantTemperature:
            MacMetricCard(title: metric.title, subtitle: m.coolerName, valueText: MacFormat.whole(m.liquidTemp, unit: "°C"), progress: m.liquidTemp.map { min(1, max(0.05, ($0 - 20) / 30)) },
                          icon: metric.symbol, accent: metric.accent, detail: m.liquidTemp == nil ? nil : "Coolant loop", history: series)
        case .cpuClock:
            MacMetricCard(title: metric.title, subtitle: m.cpuName, valueText: m.cpuClockMHz.map { "\(MacFormat.decimal($0 / 1000, digits: 2)) GHz" } ?? "—",
                          progress: m.cpuClockMHz.map { min(1, max(0.1, $0 / 5800)) }, icon: metric.symbol, accent: metric.accent, detail: m.cpuClockSource, history: series)
        case .network:
            MacMetricCard(title: metric.title, subtitle: m.networkInterface ?? "Network", valueText: MacFormat.transferRate(m.networkDownloadMBps), progress: nil,
                          icon: metric.symbol, accent: metric.accent, detail: m.networkUploadMBps.map { "↑ \(MacFormat.transferRate($0))" }, history: series)
        case .diskActivity:
            MacMetricCard(title: metric.title, subtitle: "Disk throughput", valueText: MacFormat.transferRate(m.diskReadMBps), progress: nil,
                          icon: metric.symbol, accent: metric.accent, detail: m.diskWriteMBps.map { "Write \(MacFormat.transferRate($0))" }, history: series)
        case .uptime:
            MacMetricCard(title: metric.title, subtitle: "Active session", valueText: m.formattedUptime, progress: nil, icon: metric.symbol, accent: metric.accent,
                          detail: vm.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" })
        case .fps:
            MacMetricCard(title: metric.title, subtitle: m.activeGame ?? "No active game", valueText: m.fps.flatMap { $0 > 0 ? "\(Int($0.rounded())) FPS" : nil } ?? "—",
                          progress: m.fps.flatMap { $0 > 0 ? min(1, max(0.05, $0 / 165)) : nil }, icon: metric.symbol, accent: metric.accent,
                          detail: m.fps.flatMap { $0 > 0 ? join(["\(MacFormat.decimal(1000 / $0, digits: 1)) ms", m.fpsSource]) : m.fpsSource }, history: series)
        case .cpuFan:
            MacMetricCard(title: metric.title, subtitle: "CPU cooler", valueText: MacFormat.whole(m.cpuFanRPM, unit: "RPM"), progress: m.cpuFanRPM.map { min(1, max(0.05, $0 / 2400)) },
                          icon: metric.symbol, accent: metric.accent, history: series)
        case .gpuFan:
            MacMetricCard(title: metric.title, subtitle: m.gpuName, valueText: MacFormat.whole(m.gpuFanPercent, unit: "%"), progress: m.gpuFanPercent.map { min(1, max(0, $0 / 100)) },
                          icon: metric.symbol, accent: metric.accent, history: series)
        }
    }

    private func join(_ parts: [String?]) -> String? {
        let values = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func activeGameCard(_ title: String) -> some View {
        HStack(spacing: 12) {
            MacIconBadge(systemName: "gamecontroller.fill", tint: .mint, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("PLAYING NOW")
                    .font(.system(.caption2, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.mint)
                Text(title).font(.headline.weight(.bold)).lineLimit(1)
                if let fps = vm.metrics.fps, fps > 0 {
                    Text("\(MacFormat.decimal(1000 / fps, digits: 1)) ms frametime\(vm.metrics.fpsSource.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if vm.history.values(for: .fps).count >= 3 {
                MacSparkline(values: vm.history.values(for: .fps), tint: .mint, lineWidth: 1.6)
                    .frame(width: 160, height: 34)
                    .opacity(0.7)
            }
            if let fps = vm.metrics.fps, fps > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(fps.rounded()))")
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.mint)
                        .contentTransition(.numericText())
                        .shadow(color: reduceGlow ? .clear : .mint.opacity(0.45), radius: 10)
                    Text("FPS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            } else {
                Text("FPS —").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Button {
                Task { await vm.sendAction("kill_game") }
            } label: {
                Label("Quit Game", systemImage: "xmark.circle")
            }
            .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(15)
        .macGlass(cornerRadius: 18, tint: .mint)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Quick controls", icon: "bolt.fill")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                MacActionTile(title: "Lock", icon: "lock.fill", tint: theme.accent) { Task { await vm.sendAction("lock") } }
                MacActionTile(title: "Sleep", icon: "moon.fill", tint: .indigo) { pendingPower = .sleep }
                MacActionTile(title: "Restart", icon: "arrow.clockwise", tint: .orange) { pendingPower = .restart }
                MacActionTile(title: "Shut Down", icon: "power", tint: Color(red: 1.0, green: 0.45, blue: 0.48)) { pendingPower = .shutdown }
                MacActionTile(title: "Desktop", icon: "menubar.dock.rectangle", tint: theme.accent) { Task { await vm.sendAction("show_desktop") } }
                MacActionTile(title: "Screenshot", icon: "camera.viewfinder", tint: .mint) { Task { await vm.sendAction("screenshot") } }
                MacActionTile(title: "Preview", icon: "display", tint: theme.accent) { vm.selectedSection = .preview }
                MacActionTile(title: vm.metrics.isMuted ? "Unmute" : "Mute", icon: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: vm.metrics.isMuted ? .orange : theme.accent, isActive: vm.metrics.isMuted) { Task { await vm.sendAction("mute") } }
            }
        }
        .padding(16)
        .macGlass(cornerRadius: 18)
        .disabled(!vm.metrics.isOnline && !vm.isDemoMode)
    }

    private var specsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Hardware", icon: "cpu") {
                if vm.isLoadingSpecs {
                    ProgressView().controlSize(.small)
                } else if vm.metrics.isOnline && !vm.isDemoMode {
                    Button { Task { await vm.fetchSpecs() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(MacIconButtonStyle(size: 26))
                        .help("Refresh specifications")
                }
            }
            if let specs = vm.specs {
                VStack(alignment: .leading, spacing: 8) {
                    specRow("System", [specs.osName, specs.osVersion].compactMap { $0 }.joined(separator: " "), icon: "pc")
                    specRow("Processor", join([specs.cpu.name, specs.cpu.physicalCores.map { "\($0)C/\(specs.cpu.logicalCores ?? $0)T" }]), icon: "cpu")
                    specRow("Graphics", join([specs.gpus.first?.name, specs.gpus.first?.vramGB.map { "\(MacFormat.decimal($0)) GB" }]), icon: "square.stack.3d.up")
                    specRow("Memory", join([specs.memory.totalGB.map { "\(MacFormat.decimal($0, digits: 0)) GB" }, specs.memory.modules.first?.speedMHz.map { "\(Int($0)) MHz" }, specs.memory.modules.isEmpty ? nil : "\(specs.memory.modules.count) modules"]), icon: "memorychip")
                    specRow("Motherboard", join([specs.motherboard.manufacturer, specs.motherboard.model]), icon: "circle.grid.cross")
                    specRow("Storage", specs.disks.compactMap(\.name).prefix(2).joined(separator: ", "), icon: "internaldrive")
                    if let cooler = specs.coolerName, !cooler.isEmpty { specRow("Cooling", cooler, icon: "fanblades") }
                }
            } else if vm.specsError != nil {
                Text(vm.specsError ?? "").font(.caption).foregroundStyle(.orange)
            } else {
                Text(vm.metrics.isOnline ? "Reading hardware…" : "Connect to your PC to read hardware specifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func specRow(_ label: String, _ value: String?, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(theme.accent).frame(width: 16)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var offlineCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.10)).frame(width: 104, height: 104)
                Circle().strokeBorder(theme.heroGradient, lineWidth: 1.5).frame(width: 104, height: 104)
                if vm.isWaking {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(theme.heroGradient)
                        .shadow(color: reduceGlow ? .clear : theme.accent.opacity(0.6), radius: 14)
                }
            }
            VStack(spacing: 6) {
                Text(vm.isWaking ? "Waking PC…" : (vm.currentPC == nil ? "Pair your PC" : "\(vm.currentPC?.name ?? "PC") is offline"))
                    .font(.title2.weight(.bold))
                Text(vm.currentPC == nil
                     ? "Import the PC you already paired on your iPhone, or pair directly with the 6-digit code shown by Orbit Agent on Windows."
                     : (vm.currentPC?.macAddress.isEmpty == true
                        ? "Connect once while the PC is on so Orbit can save its MAC address for Wake-on-LAN."
                        : "Send a Wake-on-LAN packet or retry the connection."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if let error = vm.connectionError, vm.currentPC != nil {
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                }
            }
            HStack(spacing: 10) {
                if vm.currentPC == nil {
                    Button { vm.selectedSection = .pcs } label: { Label("Pair or import a PC", systemImage: "dot.radiowaves.left.and.right") }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                    Button("Try Demo Mode") { vm.setDemoMode(true) }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                } else {
                    Button { Task { await vm.wakePC() } } label: { Label("Power On", systemImage: "power") }
                        .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: true))
                        .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty == true)
                    Button { Task { await vm.refreshMetrics() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                    Button { vm.selectedSection = .pcs } label: { Label("My PCs", systemImage: "desktopcomputer") }
                        .buttonStyle(MacHoverButtonStyle())
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }
}

/// Sheet to pick and reorder the dashboard cards.
struct MacDashboardCustomizer: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macTheme) private var theme
    @State private var draft: [MacMetric] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Customize Overview").font(.title3.weight(.bold))
                Spacer()
                Button("Balanced") { draft = MacMetric.defaultDashboard }.buttonStyle(MacHoverButtonStyle())
                Button("Gaming") { draft = [.fps, .gpuLoad, .vram, .cpuLoad, .gpuPower, .cpuPower, .gpuTemperature, .cpuTemperature] }.buttonStyle(MacHoverButtonStyle())
                Button("Everything") { draft = MacMetric.allCases }.buttonStyle(MacHoverButtonStyle())
            }
            Text("Drag to reorder. Cards for sensors your PC does not report show “—” instead of estimated values.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(MacMetric.allCases) { metric in
                    let visible = draft.contains(metric)
                    HStack(spacing: 12) {
                        MacIconBadge(systemName: metric.symbol, tint: metric.accent, size: 26).opacity(visible ? 1 : 0.5)
                        Text(metric.title).foregroundStyle(visible ? .white : .secondary)
                        Spacer()
                        Toggle("", isOn: Binding(get: { visible }, set: { on in
                            if on { if !draft.contains(metric) { draft.append(metric) } } else { draft.removeAll { $0 == metric } }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 360)
            HStack {
                Text("\(draft.count) cards").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(MacHoverButtonStyle())
                Button("Done") { vm.dashboardMetrics = orderedDraft; dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .background(MacAmbientBackground())
        .onAppear { draft = vm.dashboardMetrics }
    }

    /// Keeps the existing order for cards that were already on the dashboard.
    private var orderedDraft: [MacMetric] {
        let existing = vm.dashboardMetrics.filter { draft.contains($0) }
        let added = draft.filter { !vm.dashboardMetrics.contains($0) }
        return existing + added
    }
}
