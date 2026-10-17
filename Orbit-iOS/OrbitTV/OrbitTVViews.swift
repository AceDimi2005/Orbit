import SwiftUI
import UIKit

// MARK: - Root Apple TV View

struct OrbitTVRootView: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var showShutdownConfirm = false
    @State private var showRestartConfirm = false
    @State private var isFullscreenMonitor = false

    var body: some View {
        ZStack {
            // Deep space living-room background
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.09),
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                    Color(red: 0.02, green: 0.03, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            TabView(selection: $vm.selectedTab) {
                TVDashboardTab(
                    showShutdownConfirm: $showShutdownConfirm,
                    showRestartConfirm: $showRestartConfirm,
                    onOpenLiveMonitor: {
                        vm.selectedTab = 1
                        vm.startScreenStream()
                    }
                )
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(0)

                TVMonitorAndGamesTab(isFullscreenMonitor: $isFullscreenMonitor)
                    .tabItem {
                        Label("Monitor & Games", systemImage: "play.tv.fill")
                    }
                    .tag(1)

                TVAudioAndMediaTab()
                    .tabItem {
                        Label("Audio & Media", systemImage: "hifispeaker.2.fill")
                    }
                    .tag(2)

                TVTaskManagerTab()
                    .tabItem {
                        Label("Task Manager", systemImage: "cpu.fill")
                    }
                    .tag(3)

                TVPCsAndPairingTab()
                    .tabItem {
                        Label("My PCs", systemImage: "desktopcomputer")
                    }
                    .tag(4)
            }

            // Bottom status banner
            if !vm.statusBanner.isEmpty {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: vm.metrics.isOnline ? "bolt.horizontal.circle.fill" : "sparkles.tv")
                            .font(.callout)
                            .foregroundStyle(.cyan)
                        Text(vm.statusBanner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 22)
                }
            }
        }
        .onPlayPauseCommand {
            Task { await vm.sendAction("play_pause") }
        }
        .confirmationDialog(
            "Shut Down \(vm.metrics.hostname)?",
            isPresented: $showShutdownConfirm,
            titleVisibility: .visible
        ) {
            Button("Shut Down PC Now", role: .destructive) {
                Task { await vm.sendAction("shutdown") }
            }
            Button("Put PC to Sleep") {
                Task { await vm.sendAction("sleep") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Make sure any open work on \(vm.metrics.hostname) is saved before shutting down.")
        }
        .confirmationDialog(
            "Restart \(vm.metrics.hostname)?",
            isPresented: $showRestartConfirm,
            titleVisibility: .visible
        ) {
            Button("Restart PC Now", role: .destructive) {
                Task { await vm.sendAction("restart") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your PC will reboot and reconnect automatically once Windows starts.")
        }
    }
}

// MARK: - Tab 1: 4K Command Wall (Dashboard + Power Deck)

struct TVDashboardTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var showShutdownConfirm: Bool
    @Binding var showRestartConfirm: Bool
    var onOpenLiveMonitor: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 28),
        GridItem(.flexible(), spacing: 28),
        GridItem(.flexible(), spacing: 28),
        GridItem(.flexible(), spacing: 28)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                // Top Hero Status + Power Control Bar
                TVHeroPowerDeck(
                    showShutdownConfirm: $showShutdownConfirm,
                    showRestartConfirm: $showRestartConfirm,
                    onOpenLiveMonitor: onOpenLiveMonitor
                )

                // 8-Card 4K Telemetry Grid
                LazyVGrid(columns: columns, spacing: 28) {
                    TVTelemetryCard(
                        title: "CPU LOAD",
                        primaryValue: String(format: "%.0f%%", vm.metrics.cpuUsage),
                        secondaryBadge: String(format: "%.0f°C", vm.metrics.cpuTemp ?? 0),
                        subtitle: vm.metrics.cpuName,
                        footerLeft: String(format: "%.0f MHz • %.0fW", vm.metrics.cpuClockMHz ?? 0, vm.metrics.cpuPowerWatts ?? 0),
                        footerRight: String(format: "Peak %.0f°C", vm.peakCPUTemp),
                        accent: .cyan,
                        progress: vm.metrics.cpuUsage / 100.0,
                        sparkline: vm.cpuHistory
                    )

                    TVTelemetryCard(
                        title: "GPU CORE",
                        primaryValue: String(format: "%.0f%%", vm.metrics.gpuUsage ?? 0),
                        secondaryBadge: String(format: "%.0f°C", vm.metrics.gpuTemp ?? 0),
                        subtitle: vm.metrics.gpuName,
                        footerLeft: String(format: "Fan %.0f%% • %.0fW", vm.metrics.gpuFanPercent ?? 0, vm.metrics.gpuPowerWatts ?? 0),
                        footerRight: String(format: "Peak %.0f°C", vm.peakGPUTemp),
                        accent: .purple,
                        progress: (vm.metrics.gpuUsage ?? 0) / 100.0,
                        sparkline: vm.gpuHistory
                    )

                    TVTelemetryCard(
                        title: "LIVE FPS",
                        primaryValue: (vm.metrics.fps ?? 0) > 0 ? String(format: "%.0f", vm.metrics.fps ?? 0) : "IDLE",
                        secondaryBadge: vm.metrics.fpsSource ?? "PresentMon",
                        subtitle: vm.metrics.activeGame ?? "Desktop Telemetry",
                        footerLeft: (vm.metrics.fps ?? 0) > 0 ? String(format: "%.1f ms frame", 1000.0 / max(1.0, vm.metrics.fps ?? 60)) : "Standby",
                        footerRight: String(format: "Peak %.0f FPS", vm.peakFPS),
                        accent: .green,
                        progress: min(1.0, (vm.metrics.fps ?? 0) / 165.0),
                        sparkline: vm.fpsHistory
                    )

                    TVTelemetryCard(
                        title: "SYSTEM RAM",
                        primaryValue: String(format: "%.0f%%", vm.metrics.ramUsagePercent),
                        secondaryBadge: String(format: "%.1f / %.0f GB", vm.metrics.ramUsedGB, vm.metrics.ramTotalGB),
                        subtitle: "DDR5 Dual-Channel",
                        footerLeft: String(format: "Free %.1f GB", max(0, vm.metrics.ramTotalGB - vm.metrics.ramUsedGB)),
                        footerRight: "Healthy",
                        accent: .mint,
                        progress: vm.metrics.ramUsagePercent / 100.0,
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "GPU VRAM",
                        primaryValue: String(format: "%.0f%%", vm.metrics.vramUsagePercent),
                        secondaryBadge: String(format: "%.1f / %.0f GB", vm.metrics.vramUsedGB ?? 0, vm.metrics.vramTotalGB ?? 0),
                        subtitle: "Dedicated Video Memory",
                        footerLeft: String(format: "Fan %.0f%%", vm.metrics.gpuFanPercent ?? 0),
                        footerRight: "PCIe Gen4",
                        accent: .indigo,
                        progress: vm.metrics.vramUsagePercent / 100.0,
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "NETWORK I/O",
                        primaryValue: String(format: "%.1f MB/s", vm.metrics.networkDownloadMBps ?? 0),
                        secondaryBadge: String(format: "↑ %.1f MB/s", vm.metrics.networkUploadMBps ?? 0),
                        subtitle: "LAN Ethernet / Wi-Fi",
                        footerLeft: "Ping \(max(1, vm.pingMs)) ms",
                        footerRight: vm.metrics.isOnline ? "Active" : "Standby",
                        accent: .blue,
                        progress: min(1.0, (vm.metrics.networkDownloadMBps ?? 0) / 100.0),
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "NVMe STORAGE",
                        primaryValue: String(format: "%.0f%%", vm.metrics.ssdUsagePercent),
                        secondaryBadge: String(format: "%.2f / %.1f TB", vm.metrics.ssdUsedTB, vm.metrics.ssdTotalTB),
                        subtitle: "Primary System Drive",
                        footerLeft: String(format: "R: %.1f MB/s", vm.metrics.diskReadMBps ?? 0),
                        footerRight: String(format: "W: %.1f MB/s", vm.metrics.diskWriteMBps ?? 0),
                        accent: .orange,
                        progress: vm.metrics.ssdUsagePercent / 100.0,
                        sparkline: []
                    )

                    let totalWatts = (vm.metrics.cpuPowerWatts ?? 0) + (vm.metrics.gpuPowerWatts ?? 0)
                    TVTelemetryCard(
                        title: "THERMAL & POWER",
                        primaryValue: String(format: "%.0fW", totalWatts),
                        secondaryBadge: vm.metrics.liquidTemp != nil ? String(format: "Liquid %.1f°C", vm.metrics.liquidTemp!) : "Air / AIO",
                        subtitle: "Total CPU + GPU Package",
                        footerLeft: String(format: "Peak %.0fW", vm.peakPowerWatts),
                        footerRight: "Up \(vm.metrics.formattedUptime)",
                        accent: .pink,
                        progress: min(1.0, totalWatts / 500.0),
                        sparkline: []
                    )
                }

                // Living Room Quick Actions Strip
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("LIVING ROOM QUICK CONTROLS")
                            .font(.callout.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Tip: Press Play/Pause on your Siri Remote anytime to control PC media")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 22) {
                        TVQuickActionCard(
                            title: "Volume -",
                            subtitle: "Step Down",
                            icon: "speaker.minus.fill",
                            tint: .cyan
                        ) {
                            Task { await vm.sendAction("volume_down") }
                        }

                        TVQuickActionCard(
                            title: "Mute Audio",
                            subtitle: vm.metrics.isMuted ? "Muted" : "Unmuted",
                            icon: "speaker.slash.fill",
                            tint: .orange
                        ) {
                            Task { await vm.sendAction("mute") }
                        }

                        TVQuickActionCard(
                            title: "Volume +",
                            subtitle: "Step Up",
                            icon: "speaker.plus.fill",
                            tint: .cyan
                        ) {
                            Task { await vm.sendAction("volume_up") }
                        }

                        TVQuickActionCard(
                            title: "Play / Pause",
                            subtitle: "Media Key",
                            icon: "playpause.fill",
                            tint: .green
                        ) {
                            Task { await vm.sendAction("play_pause") }
                        }

                        TVQuickActionCard(
                            title: "Next Track",
                            subtitle: "Skip Forward",
                            icon: "forward.fill",
                            tint: .purple
                        ) {
                            Task { await vm.sendAction("next_track") }
                        }

                        TVQuickActionCard(
                            title: "Toggle HDR",
                            subtitle: "Win+Alt+B",
                            icon: "sparkles.tv.fill",
                            tint: .yellow
                        ) {
                            Task { await vm.sendAction("toggle_hdr") }
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - Hero Power Deck (Start / Wake-on-LAN & Shut Down)

struct TVHeroPowerDeck: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var showShutdownConfirm: Bool
    @Binding var showRestartConfirm: Bool
    var onOpenLiveMonitor: () -> Void

    var body: some View {
        HStack(spacing: 30) {
            // Left: PC Identity & Live Status
            HStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 78, height: 78)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(vm.metrics.hostname)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusText)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(statusColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.16), in: Capsule())
                    }

                    Text("\(vm.metrics.cpuName) • \(vm.metrics.gpuName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let game = vm.metrics.activeGame, !game.isEmpty {
                        Label("Playing \(game) (\(Int(vm.metrics.fps ?? 0)) FPS)", systemImage: "gamecontroller.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            // Right: Prominent Power On (Start) & Shut Down Controls
            HStack(spacing: 18) {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWaking ? "Waking..." : "Power On (WoL)", systemImage: "power.circle.fill")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .tint(.green)

                Button {
                    showShutdownConfirm = true
                } label: {
                    Label("Shut Down", systemImage: "power")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .tint(.red)

                Button {
                    Task { await vm.sendAction("sleep") }
                } label: {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .tint(.indigo)

                Button {
                    showRestartConfirm = true
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise.circle.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .tint(.orange)

                Button {
                    Task { await vm.sendAction("lock") }
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                Button {
                    onOpenLiveMonitor()
                } label: {
                    Label("Live Screen", systemImage: "tv.inset.filled")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .tint(.cyan)
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var statusColor: Color {
        if vm.metrics.isOnline && !vm.isDemoMode { return .green }
        if vm.isDemoMode { return .cyan }
        return .orange
    }

    private var statusText: String {
        if vm.metrics.isOnline && !vm.isDemoMode { return "ONLINE" }
        if vm.isDemoMode { return "PREVIEW DEMO" }
        return "OFFLINE • READY FOR WOL"
    }
}

// MARK: - Telemetry Card & Sparkline

struct TVTelemetryCard: View {
    let title: String
    let primaryValue: String
    let secondaryBadge: String
    let subtitle: String
    let footerLeft: String
    let footerRight: String
    let accent: Color
    let progress: Double
    let sparkline: [Double]

    var body: some View {
        Button(action: {}) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(accent)
                    Spacer()
                    Text(secondaryBadge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(accent)
                }

                Text(primaryValue)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if sparkline.count > 2 {
                    TVSparklineShape(points: sparkline)
                        .stroke(
                            LinearGradient(
                                colors: [accent.opacity(0.5), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                        .frame(height: 36)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(accent)
                                .frame(width: max(8, geo.size.width * min(1.0, max(0.0, progress))))
                        }
                    }
                    .frame(height: 10)
                    .padding(.vertical, 13)
                }

                HStack {
                    Text(footerLeft)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(footerRight)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.card)
    }
}

struct TVSparklineShape: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let minVal = points.min() ?? 0
        let maxVal = max(minVal + 1, points.max() ?? 100)
        let stepX = rect.width / CGFloat(points.count - 1)

        for (index, val) in points.enumerated() {
            let normalized = (val - minVal) / (maxVal - minVal)
            let x = CGFloat(index) * stepX
            let y = rect.height - CGFloat(normalized) * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

struct TVQuickActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.card)
    }
}

// MARK: - Tab 2: Big Screen Live Monitor & Couch Game Launcher

struct TVMonitorAndGamesTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var isFullscreenMonitor: Bool

    private let gameColumns = [
        GridItem(.flexible(), spacing: 26),
        GridItem(.flexible(), spacing: 26),
        GridItem(.flexible(), spacing: 26)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                // Live PC Desktop Monitor Card
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LIVE PC DESKTOP MONITOR")
                                .font(.callout.weight(.bold))
                                .tracking(1.6)
                                .foregroundStyle(.cyan)
                            Text("Watch renders, downloads, or game queues from your living room couch (view-only mode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 16) {
                            Button {
                                vm.toggleScreenStream()
                            } label: {
                                Label(
                                    vm.isStreamingScreen ? "Stop Stream" : "Start Live View",
                                    systemImage: vm.isStreamingScreen ? "stop.circle.fill" : "play.tv.fill"
                                )
                            }
                            .tint(vm.isStreamingScreen ? .red : .cyan)

                            Button {
                                Task { await vm.sendAction("show_desktop") }
                            } label: {
                                Label("Show Desktop", systemImage: "menubar.dock.rectangle")
                            }

                            Button {
                                Task { await vm.sendAction("task_view") }
                            } label: {
                                Label("Task View", systemImage: "rectangle.3.group.fill")
                            }

                            Button {
                                Task { await vm.sendAction("alt_tab") }
                            } label: {
                                Label("Alt + Tab", systemImage: "macwindow.on.rectangle")
                            }

                            Button {
                                Task { await vm.sendAction("screenshot") }
                            } label: {
                                Label("Screenshot", systemImage: "camera.viewfinder")
                            }
                        }
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .strokeBorder(Color.cyan.opacity(0.30), lineWidth: 1.5)
                            )

                        if let frame = vm.liveFrameImage {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .padding(8)
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "tv.and.mediabox")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.cyan.opacity(0.75))
                                Text(vm.streamStatus)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Optimized for 10-foot Apple TV viewing • No mouse cursor required")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(44)
                        }
                    }
                    .frame(height: 440)
                }

                // Sunshine Couch Game Launcher
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("COUCH GAMING & SUNSHINE LAUNCHER")
                                .font(.callout.weight(.bold))
                                .tracking(1.6)
                                .foregroundStyle(.purple)
                            Text("Auto-wakes your PC via Wake-on-LAN and launches your game ready for controller play")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 16) {
                            Button {
                                Task { await vm.refreshGames() }
                            } label: {
                                Label("Refresh Library", systemImage: "arrow.clockwise")
                            }

                            Button(role: .destructive) {
                                Task { await vm.sendAction("kill_game") }
                            } label: {
                                Label("Quit Active Game", systemImage: "xmark.octagon.fill")
                            }
                            .tint(.red)
                        }
                    }

                    LazyVGrid(columns: gameColumns, spacing: 26) {
                        ForEach(vm.games) { game in
                            Button {
                                Task { await vm.launchGame(game) }
                            } label: {
                                HStack(spacing: 20) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [.purple.opacity(0.6), .cyan.opacity(0.4)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 74, height: 74)
                                        Image(systemName: game.iconSymbol)
                                            .font(.title2)
                                            .foregroundStyle(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(game.title)
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(game.genre)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Tap with Siri Remote to Start")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.cyan)
                                    }
                                    Spacer()
                                }
                                .padding(22)
                                .background(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .onDisappear {
            vm.stopScreenStream()
        }
    }
}

// MARK: - Tab 3: Living Room Audio & Media Center

struct TVAudioAndMediaTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                // Master Volume & Media Transport Deck
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("MASTER PC AUDIO (\(Int(vm.metrics.volume))%)")
                            .font(.callout.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.cyan)

                        HStack(spacing: 18) {
                            Button {
                                Task { await vm.adjustMasterVolume(by: -10) }
                            } label: {
                                Label("-10%", systemImage: "speaker.wave.1.fill")
                            }

                            Button {
                                Task { await vm.sendAction("volume_down") }
                            } label: {
                                Label("-5%", systemImage: "speaker.minus.fill")
                            }

                            Button {
                                Task { await vm.sendAction("mute") }
                            } label: {
                                Label(vm.metrics.isMuted ? "Unmute" : "Mute", systemImage: "speaker.slash.fill")
                            }
                            .tint(.orange)

                            Button {
                                Task { await vm.sendAction("volume_up") }
                            } label: {
                                Label("+5%", systemImage: "speaker.plus.fill")
                            }

                            Button {
                                Task { await vm.adjustMasterVolume(by: 10) }
                            } label: {
                                Label("+10%", systemImage: "speaker.wave.3.fill")
                            }
                            .tint(.cyan)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                    VStack(alignment: .leading, spacing: 18) {
                        Text("NOW PLAYING TRANSPORT")
                            .font(.callout.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.green)

                        HStack(spacing: 18) {
                            Button {
                                Task { await vm.sendAction("prev_track") }
                            } label: {
                                Label("Prev", systemImage: "backward.fill")
                            }

                            Button {
                                Task { await vm.sendAction("play_pause") }
                            } label: {
                                Label("Play / Pause", systemImage: "playpause.fill")
                            }
                            .tint(.green)

                            Button {
                                Task { await vm.sendAction("next_track") }
                            } label: {
                                Label("Next", systemImage: "forward.fill")
                            }
                        }
                    }
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }

                // Per-App Windows Core Audio Mixer
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PER-APPLICATION WINDOWS AUDIO MIXER")
                                .font(.callout.weight(.bold))
                                .tracking(1.5)
                                .foregroundStyle(.purple)
                            Text("Adjust individual game, voice chat, or browser volume and route audio to TV HDMI or Headset")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await vm.refreshAudioMixer() }
                        } label: {
                            Label("Refresh Mixer", systemImage: "arrow.clockwise")
                        }
                    }

                    ForEach(vm.audioSessions) { session in
                        HStack(spacing: 24) {
                            Image(systemName: session.isMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                                .font(.title)
                                .foregroundStyle(session.isMuted ? .orange : .cyan)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.name)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                                Text("PID \(session.pid) • Volume \(Int(session.volume))% • \(session.outputDeviceName ?? "Default Output")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 340, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.10))
                                    Capsule()
                                        .fill(session.isMuted ? Color.orange : Color.cyan)
                                        .frame(width: max(10, geo.size.width * CGFloat(min(100, max(0, session.volume)) / 100.0)))
                                }
                            }
                            .frame(height: 14)

                            HStack(spacing: 14) {
                                Button {
                                    Task { await vm.adjustAppVolume(session, by: -10) }
                                } label: {
                                    Text("-10%")
                                }

                                Button {
                                    Task { await vm.toggleAppMute(session) }
                                } label: {
                                    Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                }
                                .tint(session.isMuted ? .orange : .gray)

                                Button {
                                    Task { await vm.adjustAppVolume(session, by: 10) }
                                } label: {
                                    Text("+10%")
                                }

                                ForEach(vm.audioOutputs.prefix(2)) { device in
                                    Button {
                                        Task { await vm.routeAppAudio(session, to: device.id) }
                                    } label: {
                                        Label(device.name.components(separatedBy: " ").first ?? "Output", systemImage: "hifispeaker.fill")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(22)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .onAppear {
            Task { await vm.refreshAudioMixer() }
        }
    }
}

// MARK: - Tab 4: Couch Task Manager & Session Peaks

struct TVTaskManagerTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var processToKill: TVProcessItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WINDOWS PROCESS & RESOURCE MONITOR")
                            .font(.callout.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.cyan)
                        Text("Select any unresponsive game or background hog with the Siri Remote to terminate it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await vm.refreshProcesses() }
                    } label: {
                        Label("Refresh Processes", systemImage: "arrow.clockwise")
                    }
                }

                if let msg = vm.processStatusMessage {
                    Text(msg)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }

                ForEach(vm.processes) { proc in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proc.name)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("PID \(proc.pid) • \(proc.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 320, alignment: .leading)

                        TVMetricPill(label: "CPU", value: String(format: "%.1f%%", proc.cpuPercent ?? 0), tint: .cyan)
                        TVMetricPill(label: "GPU", value: String(format: "%.1f%%", proc.gpuPercent ?? 0), tint: .purple)
                        TVMetricPill(label: "RAM", value: String(format: "%.0f MB", proc.memoryMB ?? 0), tint: .mint)
                        TVMetricPill(label: "VRAM", value: String(format: "%.0f MB", proc.vramMB ?? 0), tint: .indigo)

                        Spacer()

                        Button(role: .destructive) {
                            processToKill = proc
                        } label: {
                            Label("End Task", systemImage: "xmark.circle.fill")
                        }
                        .tint(.red)
                        .disabled(!proc.canTerminate)
                    }
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .onAppear {
            Task { await vm.refreshProcesses() }
        }
        .confirmationDialog(
            "End Process \(processToKill?.name ?? "")?",
            isPresented: Binding(
                get: { processToKill != nil },
                set: { if !$0 { processToKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let proc = processToKill {
                Button("Terminate \(proc.name) (PID \(proc.pid))", role: .destructive) {
                    Task { await vm.terminateProcess(proc) }
                    processToKill = nil
                }
            }
            Button("Cancel", role: .cancel) {
                processToKill = nil
            }
        }
    }
}

struct TVMetricPill: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 140, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Tab 5: My PCs, Bonjour Discovery & 6-Digit SRP PIN Pairing

struct TVPCsAndPairingTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var manualHost: String = ""
    @State private var manualPort: String = "8765"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                // Saved PCs Section
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("SAVED WORKSTATIONS")
                            .font(.callout.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.cyan)
                        Spacer()
                        Button {
                            vm.setDemoMode(!vm.isDemoMode)
                        } label: {
                            Label(
                                vm.isDemoMode ? "Disable Demo Mode" : "Enable Demo Mode",
                                systemImage: "sparkles.tv"
                            )
                        }
                    }

                    if vm.savedPCs.isEmpty {
                        Text("No saved PCs yet. Select a discovered PC below or enter an IP address to pair with a 6-digit PIN.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.05)))
                    } else {
                        ForEach(vm.savedPCs) { pc in
                            HStack(spacing: 24) {
                                Image(systemName: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                                    .font(.title2)
                                    .foregroundStyle(vm.selectedPCID == pc.id ? .green : .cyan)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pc.name)
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                    Text("\(pc.address):\(pc.securePort) • MAC: \(pc.macAddress.isEmpty ? "Auto" : pc.macAddress)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    vm.selectPC(pc)
                                } label: {
                                    Text(vm.selectedPCID == pc.id ? "Active PC" : "Connect")
                                }
                                .tint(vm.selectedPCID == pc.id ? .green : .cyan)

                                Button {
                                    vm.selectPC(pc)
                                    Task { await vm.wakePC() }
                                } label: {
                                    Label("Wake (WoL)", systemImage: "power")
                                }

                                Button(role: .destructive) {
                                    vm.deletePC(pc)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .padding(22)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
                        }
                    }
                }

                // Automatic Bonjour Discovery on Local LAN
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("DISCOVERED ON LOCAL NETWORK (BONJOUR)")
                            .font(.callout.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.purple)
                        Spacer()
                        Button {
                            vm.startDiscovery()
                        } label: {
                            Label(vm.isScanningNetwork ? "Scanning..." : "Scan Network", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }

                    if vm.discoveredPCs.isEmpty {
                        Text("Press 'Scan Network' or enter your PC IP below to discover Orbit Windows Companion (_orbit._tcp)...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.05)))
                    } else {
                        ForEach(vm.discoveredPCs) { pc in
                            HStack(spacing: 24) {
                                Image(systemName: "wifi.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pc.name)
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                    Text("\(pc.host):\(pc.securePort) • Companion v\(pc.agentVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await vm.beginPINPairing(with: pc) }
                                } label: {
                                    Label("Pair with 6-Digit PIN", systemImage: "lock.shield.fill")
                                }
                                .tint(.purple)
                            }
                            .padding(22)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
                        }
                    }
                }

                // Manual IP + 6-Digit SRP PIN Pairing Box
                VStack(alignment: .leading, spacing: 18) {
                    Text("PAIR BY IP & 6-DIGIT PIN (SRP ZERO-KNOWLEDGE)")
                        .font(.callout.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.green)

                    HStack(spacing: 20) {
                        TextField("PC IP Address (e.g. 192.168.1.50)", text: $manualHost)
                            .frame(width: 420)

                        TextField("Port", text: $manualPort)
                            .frame(width: 140)

                        Button {
                            let port = Int(manualPort) ?? 8765
                            Task { await vm.probeManualHost(manualHost, discoveryPort: port) }
                        } label: {
                            Label("Probe PC", systemImage: "magnifyingglass.circle.fill")
                        }
                        .tint(.cyan)
                    }

                    if let target = vm.activePairingTarget {
                        HStack(spacing: 20) {
                            TextField("Enter 6-Digit PIN shown on \(target.name)", text: $vm.pairingPIN)
                                .frame(width: 420)

                            Button {
                                Task { await vm.finishPINPairing() }
                            } label: {
                                Label(vm.isPairingInProgress ? "Pairing..." : "Verify PIN & Pair", systemImage: "checkmark.shield.fill")
                            }
                            .tint(.green)
                            .disabled(vm.isPairingInProgress || vm.pairingPIN.trimmingCharacters(in: .whitespaces).count < 4)
                        }
                    }

                    if let error = vm.pairingErrorMessage {
                        Text(error)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.06)))
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .onAppear {
            vm.startDiscovery()
        }
        .onDisappear {
            vm.stopDiscovery()
        }
    }
}
