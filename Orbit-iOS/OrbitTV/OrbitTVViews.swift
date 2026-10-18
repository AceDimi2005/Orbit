import SwiftUI
import UIKit

// MARK: - Custom tvOS Focusable Styles (Prevents tvOS default button text-wrapping)

struct TVActionPillStyle: ButtonStyle {
    var tint: Color = .cyan
    var isDestructive: Bool = false
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVActionPillBody(
            configuration: configuration,
            tint: isDestructive ? .red : tint,
            isProminent: isProminent
        )
    }

    private struct TVActionPillBody: View {
        let configuration: Configuration
        let tint: Color
        let isProminent: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isFocused
                                ? tint
                                : (isProminent ? tint.opacity(0.28) : Color.white.opacity(0.09))
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.white : tint.opacity(isProminent ? 0.65 : 0.30),
                            lineWidth: isFocused ? 2.5 : 1
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.05 : 1.0))
                .shadow(color: isFocused ? tint.opacity(0.55) : .clear, radius: 16, y: 6)
                .animation(.spring(duration: 0.2), value: isFocused)
        }
    }
}

struct TVSurfaceCardStyle: ButtonStyle {
    var accent: Color = .cyan

    func makeBody(configuration: Configuration) -> some View {
        TVSurfaceCardBody(configuration: configuration, accent: accent)
    }

    private struct TVSurfaceCardBody: View {
        let configuration: Configuration
        let accent: Color
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            isFocused
                                ? Color.white.opacity(0.13)
                                : Color.white.opacity(0.06)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            isFocused ? accent : accent.opacity(0.26),
                            lineWidth: isFocused ? 3 : 1
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.025 : 1.0))
                .shadow(color: isFocused ? accent.opacity(0.42) : .clear, radius: 18, y: 8)
                .animation(.spring(duration: 0.2), value: isFocused)
        }
    }
}

// MARK: - Root Apple TV View

struct OrbitTVRootView: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var showShutdownConfirm = false
    @State private var showRestartConfirm = false

    var body: some View {
        ZStack {
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
                    showRestartConfirm: $showRestartConfirm
                )
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(0)

                TVControlsAndGamesTab()
                    .tabItem {
                        Label("Controls", systemImage: "gamecontroller.fill")
                    }
                    .tag(1)

                TVAudioAndMediaTab()
                    .tabItem {
                        Label("Audio", systemImage: "hifispeaker.2.fill")
                    }
                    .tag(2)

                TVTaskManagerTab()
                    .tabItem {
                        Label("Processes", systemImage: "cpu.fill")
                    }
                    .tag(3)

                TVPCsAndPairingTab()
                    .tabItem {
                        Label("My PCs", systemImage: "desktopcomputer")
                    }
                    .tag(4)
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

    private let telemetryColumns = [
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22)
    ]

    private let quickActionColumns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // Hero Status + Start / Shut Down Power Deck
                TVHeroPowerDeck(
                    showShutdownConfirm: $showShutdownConfirm,
                    showRestartConfirm: $showRestartConfirm
                )

                // 8-Card 4K Telemetry Grid
                LazyVGrid(columns: telemetryColumns, spacing: 22) {
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

                // Living Room Quick Controls Strip
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("LIVING ROOM QUICK CONTROLS")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(vm.statusBanner)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                    }

                    LazyVGrid(columns: quickActionColumns, spacing: 18) {
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
                            subtitle: "Win + Alt + B",
                            icon: "sparkles.tv.fill",
                            tint: .yellow
                        ) {
                            Task { await vm.sendAction("toggle_hdr") }
                        }
                    }
                }
            }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
    }
}

// MARK: - Hero Power Deck (Start / Wake-on-LAN & Shut Down)

struct TVHeroPowerDeck: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var showShutdownConfirm: Bool
    @Binding var showRestartConfirm: Bool

    var body: some View {
        HStack(spacing: 24) {
            // Left: PC Identity & Live Status
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
                        Text(vm.metrics.hostname)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(statusText)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.16), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Text("\(vm.metrics.cpuName) • \(vm.metrics.gpuName)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let game = vm.metrics.activeGame, !game.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "gamecontroller.fill")
                            Text("Playing \(game) • \(Int(vm.metrics.fps ?? 0)) FPS")
                                .lineLimit(1)
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                    }
                }
            }

            Spacer(minLength: 16)

            // Right: Single-line Power Controls (Start / Shut Down / Sleep / Restart / Lock)
            HStack(spacing: 14) {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWaking ? "Waking..." : "Power On (WoL)", systemImage: "power.circle.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))

                Button {
                    showShutdownConfirm = true
                } label: {
                    Label("Shut Down", systemImage: "power")
                }
                .buttonStyle(TVActionPillStyle(tint: .red, isDestructive: true, isProminent: true))

                Button {
                    Task { await vm.sendAction("sleep") }
                } label: {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: .indigo))

                Button {
                    showRestartConfirm = true
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(TVActionPillStyle(tint: .orange))

                Button {
                    Task { await vm.sendAction("lock") }
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: .cyan))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
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
        if vm.isDemoMode { return "PREVIEW" }
        return "OFFLINE"
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
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(accent)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(secondaryBadge)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text(primaryValue)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if sparkline.count > 2 {
                    TVSparklineShape(points: sparkline)
                        .stroke(
                            LinearGradient(
                                colors: [accent.opacity(0.45), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(height: 30)
                        .padding(.vertical, 2)
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
                    .frame(height: 8)
                    .padding(.vertical, 13)
                }

                HStack(spacing: 6) {
                    Text(footerLeft)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(footerRight)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVSurfaceCardStyle(accent: accent))
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
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVSurfaceCardStyle(accent: tint))
    }
}

// MARK: - Tab 2: Desktop Controls, Sunshine Game Launcher & Video Streaming (Coming Soon)

struct TVControlsAndGamesTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel

    private let desktopColumns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    private let gameColumns = [
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22),
        GridItem(.flexible(), spacing: 22)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Section 1: Windows Desktop & Window Controls
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WINDOWS DESKTOP & DISPLAY SHORTCUTS")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.cyan)
                            Text("Control active windows, take PC screenshots, or switch HDR directly from your Siri Remote")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(vm.statusBanner)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                    }

                    LazyVGrid(columns: desktopColumns, spacing: 20) {
                        TVQuickActionCard(
                            title: "Show Desktop",
                            subtitle: "Minimize All (Win + D)",
                            icon: "menubar.dock.rectangle",
                            tint: .cyan
                        ) {
                            Task { await vm.sendAction("show_desktop") }
                        }

                        TVQuickActionCard(
                            title: "Task View",
                            subtitle: "Virtual Desktops (Win + Tab)",
                            icon: "rectangle.3.group.fill",
                            tint: .purple
                        ) {
                            Task { await vm.sendAction("task_view") }
                        }

                        TVQuickActionCard(
                            title: "Switch Window",
                            subtitle: "Next App (Alt + Tab)",
                            icon: "macwindow.on.rectangle",
                            tint: .mint
                        ) {
                            Task { await vm.sendAction("alt_tab") }
                        }

                        TVQuickActionCard(
                            title: "PC Screenshot",
                            subtitle: "Save to PC Pictures",
                            icon: "camera.viewfinder",
                            tint: .orange
                        ) {
                            Task { await vm.sendAction("screenshot") }
                        }
                    }
                    .focusSection()
                }

                // Section 2: Sunshine Couch Game Launcher
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("COUCH GAME LAUNCHER (SUNSHINE & STEAM)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.purple)
                            Text("Auto-wakes your PC via Wake-on-LAN and starts the selected title on your PC")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 14) {
                            Button {
                                Task { await vm.refreshGames() }
                            } label: {
                                Label("Refresh Library", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan))

                            Button {
                                Task { await vm.sendAction("kill_game") }
                            } label: {
                                Label("Quit Active Game", systemImage: "xmark.octagon.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .red, isDestructive: true))
                        }
                    }
                    .focusSection()

                    if vm.games.isEmpty {
                        HStack(spacing: 22) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.purple.opacity(0.18))
                                    .frame(width: 68, height: 68)
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(.purple)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text(vm.metrics.isOnline ? "No Sunshine or Steam Games Found" : "PC Offline — Game Library Unavailable")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(vm.metrics.isOnline
                                     ? "Add applications in Sunshine on your PC and press 'Refresh Library' to display them here."
                                     : "Power on or connect to your PC to load your real Sunshine & Steam library.")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if !vm.metrics.isOnline {
                                Button {
                                    Task { await vm.wakePC() }
                                } label: {
                                    Label("Power On PC (WoL)", systemImage: "power.circle.fill")
                                }
                                .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))

                                Button {
                                    vm.selectedTab = 4
                                } label: {
                                    Label("My PCs", systemImage: "desktopcomputer")
                                }
                                .buttonStyle(TVActionPillStyle(tint: .cyan))
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )
                        )
                        .focusSection()
                    } else {
                        LazyVGrid(columns: gameColumns, spacing: 22) {
                            ForEach(vm.games) { game in
                                Button {
                                    Task { await vm.launchGame(game) }
                                } label: {
                                    HStack(spacing: 18) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(
                                                    LinearGradient(
                                                        colors: [.purple.opacity(0.55), .cyan.opacity(0.35)],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                                .frame(width: 64, height: 64)
                                            Image(systemName: game.iconSymbol)
                                                .font(.system(size: 26, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }

                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(game.title)
                                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(game.genre)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text("Press to Launch on PC")
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.cyan)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(TVSurfaceCardStyle(accent: .purple))
                            }
                        }
                        .focusSection()
                    }
                }

                // Section 3: Live PC Video Streaming — Coming Soon
                HStack(spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.cyan.opacity(0.16))
                            .frame(width: 76, height: 76)
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text("Live PC Desktop & Game Video Streaming")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text("COMING SOON")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.cyan, in: Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Text("Ultra-low-latency live video streaming from your Windows PC to Apple TV and iOS is currently in development and will arrive in an upcoming Orbit update.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.cyan.opacity(0.28), lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .onAppear {
            Task { await vm.refreshGames() }
        }
    }
}

// MARK: - Tab 3: Living Room Audio & Media Center

struct TVAudioAndMediaTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var sessionForOutputPicker: TVAudioSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Top Row: Master Volume & Now Playing Transport
                HStack(spacing: 22) {
                    // Master PC Audio Deck
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("MASTER PC AUDIO")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .tracking(1.3)
                                .foregroundStyle(.cyan)
                            Spacer()
                            Text(vm.metrics.isMuted ? "MUTED" : (vm.metrics.isOnline || vm.isDemoMode ? "\(Int(vm.metrics.volume))%" : "OFFLINE"))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(vm.metrics.isMuted ? .orange : .white)
                        }

                        HStack(spacing: 12) {
                            Button {
                                Task { await vm.adjustMasterVolume(by: -10) }
                            } label: {
                                Label("-10%", systemImage: "speaker.wave.1.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan))

                            Button {
                                Task { await vm.sendAction("volume_down") }
                            } label: {
                                Label("-5%", systemImage: "speaker.minus.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan))

                            Button {
                                Task { await vm.sendAction("mute") }
                            } label: {
                                Label(vm.metrics.isMuted ? "Unmute" : "Mute", systemImage: "speaker.slash.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .orange, isProminent: vm.metrics.isMuted))

                            Button {
                                Task { await vm.sendAction("volume_up") }
                            } label: {
                                Label("+5%", systemImage: "speaker.plus.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan))

                            Button {
                                Task { await vm.adjustMasterVolume(by: 10) }
                            } label: {
                                Label("+10%", systemImage: "speaker.wave.3.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan, isProminent: true))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                    .focusSection()

                    // Now Playing Transport Deck
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("NOW PLAYING TRANSPORT")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .tracking(1.3)
                                .foregroundStyle(.green)
                            Spacer()
                            Text("Siri Remote Play/Pause")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 14) {
                            Button {
                                Task { await vm.sendAction("prev_track") }
                            } label: {
                                Label("Prev", systemImage: "backward.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .green))

                            Button {
                                Task { await vm.sendAction("play_pause") }
                            } label: {
                                Label("Play / Pause", systemImage: "playpause.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))

                            Button {
                                Task { await vm.sendAction("next_track") }
                            } label: {
                                Label("Next", systemImage: "forward.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .green))
                        }
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                    .focusSection()
                }

                // Per-App Windows Core Audio Mixer
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PER-APPLICATION WINDOWS AUDIO MIXER")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.purple)
                            Text("Adjust individual app volume or open the Output Source menu to route audio across any of your PC's audio devices")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await vm.refreshAudioMixer() }
                        } label: {
                            Label("Refresh Mixer", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVActionPillStyle(tint: .purple))
                    }
                    .focusSection()

                    if vm.audioSessions.isEmpty {
                        HStack(spacing: 22) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.purple.opacity(0.18))
                                    .frame(width: 68, height: 68)
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(.purple)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text(vm.metrics.isOnline ? "No Active Audio Streams on PC" : "PC Offline — Audio Mixer Unavailable")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(vm.metrics.isOnline
                                     ? "Start a game, browser, or media app on your PC and press 'Refresh Mixer'."
                                     : "Connect or Power On your PC to control per-application volume and select audio output sources.")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if !vm.metrics.isOnline {
                                Button {
                                    Task { await vm.wakePC() }
                                } label: {
                                    Label("Power On PC (WoL)", systemImage: "power.circle.fill")
                                }
                                .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))

                                Button {
                                    vm.selectedTab = 4
                                } label: {
                                    Label("My PCs", systemImage: "desktopcomputer")
                                }
                                .buttonStyle(TVActionPillStyle(tint: .cyan))
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )
                        )
                        .focusSection()
                    } else {
                        ForEach(vm.audioSessions) { session in
                            HStack(spacing: 20) {
                                Image(systemName: session.isMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(session.isMuted ? .orange : .cyan)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.name)
                                        .font(.system(size: 21, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("PID \(session.pid) • \(session.outputDeviceName ?? "Windows Default Output")")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 340, alignment: .leading)

                                // Fixed-width volume bar so it never crushes sibling buttons
                                HStack(spacing: 14) {
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(width: 220, height: 12)
                                        Capsule()
                                            .fill(session.isMuted ? Color.orange : Color.cyan)
                                            .frame(
                                                width: max(10, 220.0 * CGFloat(min(100, max(0, session.volume)) / 100.0)),
                                                height: 12
                                            )
                                    }

                                    Text("\(Int(session.volume))%")
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundStyle(session.isMuted ? .orange : .white)
                                        .frame(width: 58, alignment: .trailing)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 10)

                                HStack(spacing: 12) {
                                    Button {
                                        Task { await vm.adjustAppVolume(session, by: -10) }
                                    } label: {
                                        Text("-10%")
                                    }
                                    .buttonStyle(TVActionPillStyle(tint: .cyan))

                                    Button {
                                        Task { await vm.toggleAppMute(session) }
                                    } label: {
                                        Label(session.isMuted ? "Unmute" : "Mute", systemImage: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    }
                                    .buttonStyle(TVActionPillStyle(tint: .orange, isProminent: session.isMuted))

                                    Button {
                                        Task { await vm.adjustAppVolume(session, by: 10) }
                                    } label: {
                                        Text("+10%")
                                    }
                                    .buttonStyle(TVActionPillStyle(tint: .cyan))

                                    // Separate Output Source Dropdown / Modal Menu Button supporting 10+ PC audio outputs
                                    Button {
                                        sessionForOutputPicker = session
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "hifispeaker.2.fill")
                                            Text("Output: \(shortDeviceLabel(session.outputDeviceName ?? "Default"))")
                                                .lineLimit(1)
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(TVActionPillStyle(tint: .purple, isProminent: true))
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                    )
                            )
                            .focusSection()
                        }
                    }
                }
            }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .onAppear {
            Task { await vm.refreshAudioMixer() }
        }
        .sheet(item: $sessionForOutputPicker) { targetSession in
            TVAudioOutputPickerSheet(session: targetSession)
                .environmentObject(vm)
        }
    }

    private func shortDeviceLabel(_ fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default" }
        if trimmed.count <= 22 { return trimmed }
        return String(trimmed.prefix(20)) + "…"
    }
}

struct TVAudioOutputPickerSheet: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Environment(\.dismiss) private var dismiss
    let session: TVAudioSession

    var currentSession: TVAudioSession {
        vm.audioSessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.12),
                    Color(red: 0.09, green: 0.06, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SELECT AUDIO OUTPUT SOURCE")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.purple)
                        Text("Route \(currentSession.name) (PID \(currentSession.pid)) to any audio output device on your PC (\(vm.audioOutputs.count) available)")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(TVActionPillStyle(tint: .cyan))
                }

                if vm.audioOutputs.isEmpty {
                    Text("No Windows audio output devices reported by the PC Companion yet.")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(vm.audioOutputs) { device in
                                let isSelected = (currentSession.outputDeviceID == device.id) || (currentSession.outputDeviceName == device.name)
                                Button {
                                    Task {
                                        await vm.routeAppAudio(currentSession, to: device.id)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 18) {
                                        Image(systemName: iconForDevice(device.name))
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundStyle(isSelected ? .green : .purple)
                                            .frame(width: 40)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(device.name)
                                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(isSelected ? "Current Active Output for \(currentSession.name)" : "Press Select on Siri Remote to route audio here")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if isSelected {
                                            HStack(spacing: 6) {
                                                Image(systemName: "checkmark.circle.fill")
                                                Text("ACTIVE")
                                            }
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(Color.green.opacity(0.18), in: Capsule())
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 18)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(TVSurfaceCardStyle(accent: isSelected ? .green : .purple))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(52)
        }
    }

    private func iconForDevice(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("tv") || lower.contains("oled") || lower.contains("hdmi") || lower.contains("displayport") {
            return "tv.and.hifispeaker.fill"
        }
        if lower.contains("headset") || lower.contains("arctis") || lower.contains("headphone") {
            return "headphones"
        }
        if lower.contains("optical") || lower.contains("digital") || lower.contains("s/pdif") {
            return "cable.coaxial"
        }
        if lower.contains("wave") || lower.contains("sonar") || lower.contains("virtual") {
            return "slider.horizontal.3"
        }
        return "hifispeaker.2.fill"
    }
}

// MARK: - Tab 4: Couch Task Manager

struct TVTaskManagerTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var processToKill: TVProcessItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WINDOWS PROCESS & RESOURCE MONITOR")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.cyan)
                        Text("Select any unresponsive game or background app with the Siri Remote to terminate it")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let msg = vm.processStatusMessage {
                        Text(msg)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .padding(.trailing, 12)
                    }
                    Button {
                        Task { await vm.refreshProcesses() }
                    } label: {
                        Label("Refresh Processes", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVActionPillStyle(tint: .cyan))
                }
                .focusSection()

                if vm.processes.isEmpty {
                    HStack(spacing: 22) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.cyan.opacity(0.18))
                                .frame(width: 68, height: 68)
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .symbolVariant(.fill)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.cyan)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(vm.metrics.isOnline ? "Loading Windows Processes…" : "PC Offline — Process List Unavailable")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(vm.metrics.isOnline
                                 ? "Press 'Refresh Processes' to fetch running applications from your PC."
                                 : "Connect or Power On your PC to monitor live CPU, GPU, RAM, and VRAM usage per process.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        if !vm.metrics.isOnline {
                            Button {
                                Task { await vm.wakePC() }
                            } label: {
                                Label("Power On PC (WoL)", systemImage: "power.circle.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))

                            Button {
                                vm.selectedTab = 4
                            } label: {
                                Label("My PCs", systemImage: "desktopcomputer")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .cyan))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                    .focusSection()
                } else {
                    ForEach(vm.processes) { proc in
                        HStack(spacing: 22) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proc.name)
                                    .font(.system(size: 21, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("PID \(proc.pid) • \(proc.status.capitalized)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 340, alignment: .leading)

                            TVMetricPill(label: "CPU", value: String(format: "%.1f%%", proc.cpuPercent ?? 0), tint: .cyan)
                            TVMetricPill(label: "GPU", value: String(format: "%.1f%%", proc.gpuPercent ?? 0), tint: .purple)
                            TVMetricPill(label: "RAM", value: String(format: "%.0f MB", proc.memoryMB ?? 0), tint: .mint)
                            TVMetricPill(label: "VRAM", value: String(format: "%.0f MB", proc.vramMB ?? 0), tint: .indigo)

                            Spacer(minLength: 12)

                            Button {
                                processToKill = proc
                            } label: {
                                Label("End Task", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: .red, isDestructive: true))
                            .disabled(!proc.canTerminate)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )
                        )
                        .focusSection()
                    }
                }
            }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 145, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Tab 5: My PCs, iPhone Sync, Bonjour Discovery & 6-Digit SRP PIN Pairing

struct TVPCsAndPairingTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var manualHost: String = ""
    @State private var manualPort: String = "8765"
    @State private var showIPAlert: Bool = false
    @State private var showPortAlert: Bool = false
    @State private var showPINAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                iphoneSyncSection
                savedPCsSection
                bonjourDiscoverySection
                manualPairingSection
            }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .onAppear {
            vm.startDiscovery()
            Task { await vm.syncFromiPhone(silent: true) }
        }
        .onDisappear {
            vm.stopDiscovery()
        }
        .alert("Enter PC IPv4 Address", isPresented: $showIPAlert) {
            TextField("e.g. 192.168.1.50", text: $manualHost)
            Button("Probe & Pair PC") {
                let port = Int(manualPort) ?? 8765
                Task {
                    await vm.probeManualHost(manualHost, discoveryPort: port)
                    if vm.activePairingTarget != nil {
                        showPINAlert = true
                    }
                }
            }
            Button("Save IP Only") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the local IPv4 address shown in the Orbit Companion tray app on your Windows PC.")
        }
        .alert("Enter Discovery Port", isPresented: $showPortAlert) {
            TextField("8765", text: $manualPort)
            Button("Done") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Default Orbit Windows Companion discovery port is 8765.")
        }
        .alert("Enter 6-Digit Pairing PIN", isPresented: $showPINAlert) {
            TextField("6-Digit PIN", text: $vm.pairingPIN)
            Button("Verify PIN & Pair") {
                Task { await vm.finishPINPairing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the 6-digit PIN currently displayed on \(vm.activePairingTarget?.name ?? "your PC").")
        }
    }

    @ViewBuilder
    private var iphoneSyncSection: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cyan.opacity(0.18))
                    .frame(width: 68, height: 68)
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("IMPORT PAIRED PC FROM IPHONE")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(.cyan)
                Text(vm.iPhoneSyncStatusMessage ?? "Already paired your PC on your iPhone? Open Orbit on your iPhone (or use iCloud) to import its IP, certificate, MAC address & token automatically.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button {
                Task { await vm.syncFromiPhone(silent: false) }
            } label: {
                Label(
                    vm.isSyncingFromiPhone ? "Syncing from iPhone..." : "Sync PC from iPhone",
                    systemImage: "arrow.triangle.2.circlepath.iphone"
                )
            }
            .buttonStyle(TVActionPillStyle(tint: .cyan, isProminent: true))

            Button {
                vm.setDemoMode(!vm.isDemoMode)
            } label: {
                Label(
                    vm.isDemoMode ? "Disable Demo Mode" : "Enable Demo Mode",
                    systemImage: "sparkles.tv"
                )
            }
            .buttonStyle(TVActionPillStyle(tint: .purple, isProminent: vm.isDemoMode))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.28), lineWidth: 1)
                )
        )
        .focusSection()
    }

    @ViewBuilder
    private var savedPCsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SAVED WORKSTATIONS")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.cyan)

            if vm.savedPCs.isEmpty {
                Button {
                    Task { await vm.syncFromiPhone(silent: false) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No saved PCs yet. Press here to sync from your iPhone, select a discovered PC below, or enter your PC's IP address.")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: .cyan))
            } else {
                ForEach(vm.savedPCs) { pc in
                    HStack(spacing: 20) {
                        Image(systemName: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                            .font(.system(size: 26))
                            .foregroundStyle(vm.selectedPCID == pc.id ? .green : .cyan)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(pc.name)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(pc.address):\(pc.securePort) • MAC: \(pc.macAddress.isEmpty ? "Auto" : pc.macAddress)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            vm.selectPC(pc)
                        } label: {
                            Text(vm.selectedPCID == pc.id ? "Active PC" : "Connect")
                        }
                        .buttonStyle(TVActionPillStyle(tint: vm.selectedPCID == pc.id ? .green : .cyan, isProminent: vm.selectedPCID == pc.id))

                        Button {
                            vm.selectPC(pc)
                            Task { await vm.wakePC() }
                        } label: {
                            Label("Wake (WoL)", systemImage: "power")
                        }
                        .buttonStyle(TVActionPillStyle(tint: .green))

                        Button {
                            vm.deletePC(pc)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(TVActionPillStyle(tint: .red, isDestructive: true))
                    }
                    .padding(22)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
                    .focusSection()
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var bonjourDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DISCOVERED ON LOCAL NETWORK (BONJOUR)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    vm.startDiscovery()
                } label: {
                    Label(vm.isScanningNetwork ? "Re-Scan Network" : "Scan Network", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(TVActionPillStyle(tint: .purple))
            }
            .focusSection()

            if vm.discoveredPCs.isEmpty {
                Button {
                    vm.startDiscovery()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 24))
                            .foregroundStyle(.purple)
                        Text(vm.isScanningNetwork
                             ? "Scanning local network for Orbit Windows Companion (_orbit._tcp)... Press Down for Manual IP Pairing."
                             : "No PCs discovered via Bonjour yet. Press here to re-scan or move down for Manual IP Pairing.")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: .purple))
            } else {
                ForEach(vm.discoveredPCs) { pc in
                    HStack(spacing: 20) {
                        Image(systemName: "wifi.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pc.name)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(pc.host):\(pc.securePort) • Companion v\(pc.agentVersion)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task {
                                await vm.beginPINPairing(with: pc)
                                if vm.activePairingTarget != nil {
                                    showPINAlert = true
                                }
                            }
                        } label: {
                            Label("Pair with 6-Digit PIN", systemImage: "lock.shield.fill")
                        }
                        .buttonStyle(TVActionPillStyle(tint: .purple, isProminent: true))
                    }
                    .padding(22)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
                    .focusSection()
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var manualPairingSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MANUAL PAIR BY IP & 6-DIGIT PIN (SRP ZERO-KNOWLEDGE)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.green)
                Text("Select 'PC IPv4 Address' with the Siri Remote to open the keyboard, then select 'Probe & Pair PC'")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Button {
                    showIPAlert = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "network")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PC IPv4 ADDRESS")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                            Text(manualHost.isEmpty ? "Click to Enter PC IP (e.g. 192.168.1.50)" : manualHost)
                                .font(.system(size: 19, weight: .bold, design: .monospaced))
                                .foregroundStyle(manualHost.isEmpty ? Color.secondary : Color.white)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "keyboard.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: .cyan))

                Button {
                    showPortAlert = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PORT")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        Text(manualPort.isEmpty ? "8765" : manualPort)
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(width: 190, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: .cyan))

                Button {
                    if manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showIPAlert = true
                    } else {
                        let port = Int(manualPort) ?? 8765
                        Task {
                            await vm.probeManualHost(manualHost, discoveryPort: port)
                            if vm.activePairingTarget != nil {
                                showPINAlert = true
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CONNECT & PAIR")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                            Text(vm.isProbingManualHost ? "Probing PC..." : "Probe & Pair PC")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: .green))
            }
            .focusSection()

            if let target = vm.activePairingTarget {
                HStack(spacing: 20) {
                    Button {
                        showPINAlert = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("6-DIGIT PIN SHOWN ON \(target.name.uppercased())")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.green)
                                Text(vm.pairingPIN.isEmpty ? "Click to Enter 6-Digit PIN" : vm.pairingPIN)
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(vm.pairingPIN.isEmpty ? Color.secondary : Color.white)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TVSurfaceCardStyle(accent: .green))

                    Button {
                        Task { await vm.finishPINPairing() }
                    } label: {
                        Label(vm.isPairingInProgress ? "Verifying PIN..." : "Verify PIN & Save PC", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(TVActionPillStyle(tint: .green, isProminent: true))
                    .disabled(vm.isPairingInProgress || vm.pairingPIN.trimmingCharacters(in: .whitespaces).count < 4)
                }
                .padding(.top, 6)
                .focusSection()
            }

            if let error = vm.pairingErrorMessage {
                Text(error)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.28), lineWidth: 1)
                )
        )
        .focusSection()
    }
}
