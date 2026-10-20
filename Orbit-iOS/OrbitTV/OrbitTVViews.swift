import MoonlightCore
import SwiftUI
import UIKit

// MARK: - tvOS design tokens

/// Noir palette: black background, flat surfaces and a single accent. Amber and coral
/// stay reserved for warnings and destructive actions.
enum TVPalette {
    static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let secondary = accent
    static let mint = accent
    static let purple = accent
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.48)
    static let background = Color.black
    static let surface = Color(red: 0.063, green: 0.063, blue: 0.07)
    static let hairline = Color.white.opacity(0.14)
}

/// Formats an optional reading. Missing sensors are shown as “—”, never as 0.
private func tvValue(_ value: Double?, _ format: String, suffix: String = "") -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: format, value) + suffix
}

struct TVAmbientBackground: View {
    var isOnline: Bool

    var body: some View {
        TVPalette.background.ignoresSafeArea()
    }
}

struct TVGlassCard: ViewModifier {
    var tint: Color = .white
    var cornerRadius: CGFloat = 24
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(elevated ? Color(red: 0.08, green: 0.08, blue: 0.09) : TVPalette.surface))
            .overlay(shape.strokeBorder(TVPalette.hairline, lineWidth: 1))
    }
}

extension View {
    func tvGlass(tint: Color = .white, cornerRadius: CGFloat = 24, elevated: Bool = false) -> some View {
        modifier(TVGlassCard(tint: tint, cornerRadius: cornerRadius, elevated: elevated))
    }
}

struct TVRing: View {
    var progress: Double?
    var tint: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            if let progress {
                let clamped = min(1, max(0, progress))
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.5), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * clamped)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy(duration: 0.5), value: clamped)
            }
        }
        .accessibilityHidden(true)
    }
}

struct TVSectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var tint: Color
    var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, tint: Color = TVPalette.accent, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Capsule().fill(tint).frame(width: 5, height: 22)
                    Text(title.uppercased())
                        .font(.system(size: 17, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(tint)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 15)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension TVSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, tint: Color = TVPalette.accent) {
        self.init(title, subtitle: subtitle, tint: tint) { EmptyView() }
    }
}

struct TVStatusPill: View {
    var text: String
    var tint: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
            } else {
                Circle().fill(tint).frame(width: 9, height: 9)
            }
            Text(text)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TVStatChip: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Custom tvOS Focusable Styles (Prevents tvOS default button text-wrapping)

struct TVActionPillStyle: ButtonStyle {
    var tint: Color = TVPalette.accent
    var isDestructive: Bool = false
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVActionPillBody(
            configuration: configuration,
            tint: isDestructive ? TVPalette.coral : tint,
            isProminent: isProminent
        )
    }

    private struct TVActionPillBody: View {
        let configuration: Configuration
        let tint: Color
        let isProminent: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 19, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isFocused ? Color.black.opacity(0.88) : Color.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isFocused
                                ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : (isProminent ? AnyShapeStyle(tint.opacity(0.24)) : AnyShapeStyle(Color.white.opacity(0.08)))
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.white.opacity(0.9) : tint.opacity(isProminent ? 0.6 : 0.28),
                            lineWidth: isFocused ? 2.5 : 1
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(duration: 0.22), value: isFocused)
        }
    }
}

struct TVSurfaceCardStyle: ButtonStyle {
    var accent: Color = TVPalette.accent
    var cornerRadius: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        TVSurfaceCardBody(configuration: configuration, accent: accent, cornerRadius: cornerRadius)
    }

    private struct TVSurfaceCardBody: View {
        let configuration: Configuration
        let accent: Color
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .background(shape.fill(isFocused ? Color(red: 0.11, green: 0.11, blue: 0.12) : TVPalette.surface))
                .overlay(
                    shape.strokeBorder(
                        isFocused ? accent : TVPalette.hairline,
                        lineWidth: isFocused ? 3 : 1
                    )
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.03 : 1.0))
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.spring(duration: 0.22), value: isFocused)
        }
    }
}

// MARK: - Root Apple TV View

struct OrbitTVRootView: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @ObservedObject private var stream = MoonlightStreamController.shared
    @State private var showShutdownConfirm = false
    @State private var showRestartConfirm = false

    var body: some View {
        ZStack {
            TVAmbientBackground(isOnline: vm.metrics.isOnline)

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
            Task { await vm.sendAction("media_play_pause") }
        }
        .fullScreenCover(isPresented: $stream.isPresented) {
            MoonlightStreamScreen(controller: stream, accent: TVPalette.accent)
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

// MARK: - Tab 1: Command Wall (Dashboard + Power Deck)

struct TVDashboardTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var showShutdownConfirm: Bool
    @Binding var showRestartConfirm: Bool

    private let telemetryColumns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 4)
    private let quickActionColumns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 6)

    private var hasTelemetry: Bool { (vm.metrics.isOnline || vm.isDemoMode) && vm.metrics.telemetryAvailable != false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVHeroPowerDeck(
                    showShutdownConfirm: $showShutdownConfirm,
                    showRestartConfirm: $showRestartConfirm
                )

                if !hasTelemetry && vm.metrics.isOnline {
                    HStack(spacing: 18) {
                        ProgressView().tint(TVPalette.accent)
                        Text("Collecting the first readings from \(vm.metrics.hostname)…")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(24)
                    .tvGlass(tint: TVPalette.accent)
                }

                LazyVGrid(columns: telemetryColumns, spacing: 22) {
                    TVTelemetryCard(
                        title: "CPU Load",
                        primaryValue: hasTelemetry ? tvValue(vm.metrics.cpuUsage, "%.0f", suffix: "%") : "—",
                        secondaryBadge: hasTelemetry ? tvValue(vm.metrics.cpuTemp, "%.0f", suffix: "°C") : "—",
                        subtitle: vm.metrics.cpuName,
                        footerLeft: footer(tvValue(vm.metrics.cpuClockMHz, "%.0f", suffix: " MHz"), tvValue(vm.metrics.cpuPowerWatts, "%.0f", suffix: " W")),
                        footerRight: vm.peakCPUTemp > 0 ? String(format: "Peak %.0f°C", vm.peakCPUTemp) : "",
                        accent: TVPalette.accent,
                        progress: hasTelemetry ? vm.metrics.cpuUsage / 100.0 : nil,
                        sparkline: hasTelemetry ? vm.cpuHistory : []
                    )

                    TVTelemetryCard(
                        title: "GPU Core",
                        primaryValue: hasTelemetry ? tvValue(vm.metrics.gpuUsage, "%.0f", suffix: "%") : "—",
                        secondaryBadge: hasTelemetry ? tvValue(vm.metrics.gpuTemp, "%.0f", suffix: "°C") : "—",
                        subtitle: vm.metrics.gpuName,
                        footerLeft: footer(vm.metrics.gpuFanPercent.map { String(format: "Fan %.0f%%", $0) } ?? "—", tvValue(vm.metrics.gpuPowerWatts, "%.0f", suffix: " W")),
                        footerRight: vm.peakGPUTemp > 0 ? String(format: "Peak %.0f°C", vm.peakGPUTemp) : "",
                        accent: TVPalette.purple,
                        progress: hasTelemetry ? vm.metrics.gpuUsage.map { $0 / 100.0 } : nil,
                        sparkline: hasTelemetry && vm.metrics.gpuUsage != nil ? vm.gpuHistory : []
                    )

                    TVTelemetryCard(
                        title: "Live FPS",
                        primaryValue: (vm.metrics.fps ?? 0) > 0 ? tvValue(vm.metrics.fps, "%.0f") : (hasTelemetry && vm.metrics.activeGame == nil ? "Idle" : "—"),
                        secondaryBadge: hasTelemetry ? (vm.metrics.fpsSource ?? "No FPS source") : "—",
                        subtitle: vm.metrics.activeGame ?? "No game detected",
                        footerLeft: (vm.metrics.fps ?? 0) > 0 ? String(format: "%.1f ms frametime", 1000.0 / max(1.0, vm.metrics.fps ?? 60)) : "Standby",
                        footerRight: vm.peakFPS > 0 ? String(format: "Peak %.0f FPS", vm.peakFPS) : "",
                        accent: TVPalette.mint,
                        progress: (vm.metrics.fps ?? 0) > 0 ? min(1.0, (vm.metrics.fps ?? 0) / 165.0) : nil,
                        sparkline: (vm.metrics.fps ?? 0) > 0 ? vm.fpsHistory : []
                    )

                    TVTelemetryCard(
                        title: "System RAM",
                        primaryValue: hasTelemetry && vm.metrics.ramTotalGB > 0 ? String(format: "%.0f%%", vm.metrics.ramUsagePercent) : "—",
                        secondaryBadge: vm.metrics.ramTotalGB > 0 ? String(format: "%.1f / %.0f GB", vm.metrics.ramUsedGB, vm.metrics.ramTotalGB) : "—",
                        subtitle: "System memory",
                        footerLeft: vm.metrics.ramTotalGB > 0 ? String(format: "Free %.1f GB", max(0, vm.metrics.ramTotalGB - vm.metrics.ramUsedGB)) : "—",
                        footerRight: "",
                        accent: TVPalette.mint,
                        progress: hasTelemetry && vm.metrics.ramTotalGB > 0 ? vm.metrics.ramUsagePercent / 100.0 : nil,
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "GPU VRAM",
                        primaryValue: vm.metrics.vramUsedGB != nil && (vm.metrics.vramTotalGB ?? 0) > 0 ? String(format: "%.0f%%", vm.metrics.vramUsagePercent) : tvValue(vm.metrics.vramUsedGB, "%.1f", suffix: " GB"),
                        secondaryBadge: vm.metrics.vramUsedGB != nil ? "\(tvValue(vm.metrics.vramUsedGB, "%.1f")) / \(tvValue(vm.metrics.vramTotalGB, "%.0f")) GB" : "—",
                        subtitle: "Dedicated video memory",
                        footerLeft: vm.metrics.vramTotalGB.flatMap { total in vm.metrics.vramUsedGB.map { String(format: "Free %.1f GB", max(0, total - $0)) } } ?? "—",
                        footerRight: "",
                        accent: TVPalette.accent,
                        progress: (vm.metrics.vramTotalGB ?? 0) > 0 && vm.metrics.vramUsedGB != nil ? vm.metrics.vramUsagePercent / 100.0 : nil,
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "Network I/O",
                        primaryValue: hasTelemetry ? tvValue(vm.metrics.networkDownloadMBps, "%.1f", suffix: " MB/s") : "—",
                        secondaryBadge: vm.metrics.networkUploadMBps.map { String(format: "↑ %.1f MB/s", $0) } ?? "—",
                        subtitle: "Download · Upload",
                        footerLeft: vm.metrics.isOnline && !vm.isDemoMode ? "Ping \(max(1, vm.pingMs)) ms" : (vm.isDemoMode ? "Preview" : "—"),
                        footerRight: vm.metrics.isOnline ? "Active" : "Standby",
                        accent: TVPalette.accent,
                        progress: vm.metrics.networkDownloadMBps.map { min(1.0, $0 / 100.0) },
                        sparkline: []
                    )

                    TVTelemetryCard(
                        title: "Storage",
                        primaryValue: vm.metrics.ssdTotalTB > 0 ? String(format: "%.0f%%", vm.metrics.ssdUsagePercent) : "—",
                        secondaryBadge: vm.metrics.ssdTotalTB > 0 ? String(format: "%.2f / %.1f TB", vm.metrics.ssdUsedTB, vm.metrics.ssdTotalTB) : "—",
                        subtitle: "Primary system drive",
                        footerLeft: vm.metrics.diskReadMBps.map { String(format: "R %.1f MB/s", $0) } ?? "—",
                        footerRight: vm.metrics.diskWriteMBps.map { String(format: "W %.1f MB/s", $0) } ?? "",
                        accent: TVPalette.accent,
                        progress: vm.metrics.ssdTotalTB > 0 ? vm.metrics.ssdUsagePercent / 100.0 : nil,
                        sparkline: []
                    )

                    let hasPower = vm.metrics.cpuPowerWatts != nil || vm.metrics.gpuPowerWatts != nil
                    let totalWatts = (vm.metrics.cpuPowerWatts ?? 0) + (vm.metrics.gpuPowerWatts ?? 0)
                    TVTelemetryCard(
                        title: "Thermal & Power",
                        primaryValue: hasPower && hasTelemetry ? String(format: "%.0f W", totalWatts) : "—",
                        secondaryBadge: hasTelemetry ? (vm.metrics.liquidTemp.map { String(format: "Liquid %.1f°C", $0) } ?? "No coolant sensor") : "—",
                        subtitle: hasTelemetry ? (hasPower ? "CPU package + GPU board" : "No power sensor reported") : "—",
                        footerLeft: vm.peakPowerWatts > 0 ? String(format: "Peak %.0f W", vm.peakPowerWatts) : "—",
                        footerRight: vm.metrics.uptimeSeconds > 0 ? "Up \(vm.metrics.formattedUptime)" : "",
                        accent: TVPalette.accent,
                        progress: hasPower && hasTelemetry ? min(1.0, totalWatts / 500.0) : nil,
                        sparkline: []
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    TVSectionHeader("Living Room Quick Controls", subtitle: "Volume, media and display from the Siri Remote") {
                        Text(vm.statusBanner)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TVPalette.accent)
                            .lineLimit(1)
                    }

                    LazyVGrid(columns: quickActionColumns, spacing: 18) {
                        TVQuickActionCard(title: "Volume −", subtitle: "Step Down", icon: "speaker.minus.fill", tint: TVPalette.accent) {
                            Task { await vm.sendAction("volume_down") }
                        }
                        TVQuickActionCard(title: vm.metrics.isMuted ? "Unmute" : "Mute", subtitle: vm.metrics.isMuted ? "Audio muted" : "Audio on", icon: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: TVPalette.amber) {
                            Task { await vm.sendAction("mute") }
                        }
                        TVQuickActionCard(title: "Volume +", subtitle: "Step Up", icon: "speaker.plus.fill", tint: TVPalette.accent) {
                            Task { await vm.sendAction("volume_up") }
                        }
                        TVQuickActionCard(title: "Play / Pause", subtitle: "Media Key", icon: "playpause.fill", tint: TVPalette.mint) {
                            Task { await vm.sendAction("media_play_pause") }
                        }
                        TVQuickActionCard(title: "Next Track", subtitle: "Skip Forward", icon: "forward.fill", tint: TVPalette.purple) {
                            Task { await vm.sendAction("media_next") }
                        }
                        TVQuickActionCard(title: "Toggle HDR", subtitle: "Win + Alt + B", icon: "sparkles.tv.fill", tint: .yellow) {
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

    private func footer(_ left: String, _ right: String) -> String {
        let parts = [left, right].filter { $0 != "—" && !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " • ")
    }
}

// MARK: - Hero Power Deck (Start / Wake-on-LAN & Shut Down)

struct TVHeroPowerDeck: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @Binding var showShutdownConfirm: Bool
    @Binding var showRestartConfirm: Bool

    var body: some View {
        HStack(spacing: 28) {
            HStack(spacing: 22) {
                ZStack {
                    TVRing(progress: vm.metrics.isOnline && vm.metrics.telemetryAvailable != false ? vm.metrics.cpuUsage / 100 : nil, tint: statusColor, lineWidth: 7)
                        .frame(width: 92, height: 92)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(
                            vm.metrics.isOnline
                                ? AnyShapeStyle(LinearGradient(colors: [TVPalette.accent, TVPalette.secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        Text(vm.metrics.hostname)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        TVStatusPill(text: statusText, tint: statusColor)
                    }

                    Text("\(vm.metrics.cpuName) • \(vm.metrics.gpuName)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        if vm.metrics.isOnline && !vm.isDemoMode {
                            TVStatChip(label: "Ping", value: "\(max(1, vm.pingMs)) ms")
                        }
                        if vm.metrics.uptimeSeconds > 0 {
                            TVStatChip(label: "Up", value: vm.metrics.formattedUptime)
                        }
                        if let version = vm.metrics.agentVersion {
                            TVStatChip(label: "Agent", value: version)
                        }
                        if let game = vm.metrics.activeGame, !game.isEmpty {
                            TVStatusPill(text: "Playing \(game)\((vm.metrics.fps ?? 0) > 0 ? " • \(Int(vm.metrics.fps ?? 0)) FPS" : "")", tint: TVPalette.mint, icon: "gamecontroller.fill")
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 14) {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power.circle.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.mint, isProminent: true))

                Button {
                    showShutdownConfirm = true
                } label: {
                    Label("Shut Down", systemImage: "power")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.coral, isDestructive: true, isProminent: true))

                Button {
                    Task { await vm.sendAction("sleep") }
                } label: {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

                Button {
                    showRestartConfirm = true
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))

                Button {
                    Task { await vm.sendAction("lock") }
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
            }
            .focusSection()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .tvGlass(tint: statusColor, cornerRadius: 28, elevated: true)
    }

    private var statusColor: Color {
        if vm.metrics.isOnline && !vm.isDemoMode { return TVPalette.mint }
        if vm.isDemoMode { return TVPalette.accent }
        return .orange
    }

    private var statusText: String {
        if vm.metrics.isOnline && !vm.isDemoMode { return "ONLINE" }
        if vm.isDemoMode { return "PREVIEW" }
        return vm.isWaking ? "WAKING" : "OFFLINE"
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
    let progress: Double?
    let sparkline: [Double]

    private var liveSparkline: [Double] {
        let finite = sparkline.filter { $0.isFinite }
        // A buffer that is still all zeros has not received readings yet.
        return finite.contains { $0 != 0 } ? finite : []
    }

    var body: some View {
        Button(action: {}) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(accent)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(secondaryBadge)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .center, spacing: 14) {
                    Text(primaryValue)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .shadow(color: accent.opacity(0.35), radius: 14)
                    Spacer(minLength: 0)
                    if progress != nil {
                        TVRing(progress: progress, tint: accent, lineWidth: 6)
                            .frame(width: 44, height: 44)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if liveSparkline.count > 2 {
                    ZStack {
                        TVSparklineShape(points: liveSparkline, closed: true)
                            .fill(LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                        TVSparklineShape(points: liveSparkline)
                            .stroke(
                                LinearGradient(colors: [accent.opacity(0.45), accent], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                    }
                    .frame(height: 34)
                    .padding(.vertical, 2)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                            if let progress, progress.isFinite {
                                Capsule()
                                    .fill(LinearGradient(colors: [accent.opacity(0.7), accent], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(8, geo.size.width * min(1.0, max(0.0, progress))))
                                    .shadow(color: accent.opacity(0.6), radius: 6)
                            }
                        }
                    }
                    .frame(height: 8)
                    .padding(.vertical, 15)
                }

                HStack(spacing: 6) {
                    Text(footerLeft)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(footerRight)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVSurfaceCardStyle(accent: accent))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(primaryValue), \(secondaryBadge)")
    }
}

struct TVSparklineShape: Shape {
    let points: [Double]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let minVal = points.min() ?? 0
        let maxVal = max(minVal + 1, points.max() ?? 100)
        let stepX = rect.width / CGFloat(points.count - 1)
        let inset: CGFloat = 2
        var coordinates: [CGPoint] = []
        for (index, val) in points.enumerated() {
            let normalized = (val - minVal) / (maxVal - minVal)
            let x = CGFloat(index) * stepX
            let y = rect.maxY - inset - CGFloat(normalized) * (rect.height - inset * 2)
            coordinates.append(CGPoint(x: x, y: y))
        }
        path.move(to: coordinates[0])
        for index in 1..<coordinates.count {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        if let last = coordinates.last { path.addLine(to: last) }
        if closed, let last = coordinates.last, let first = coordinates.first {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
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
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 17, weight: .bold))
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
        .buttonStyle(TVSurfaceCardStyle(accent: tint, cornerRadius: 20))
    }
}

/// Large empty-state banner with optional wake/pair shortcuts.
struct TVEmptyBanner: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    var icon: String
    var tint: Color
    var title: String
    var message: String
    var showsPowerActions: Bool = true

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 68, height: 68)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if showsPowerActions && !vm.metrics.isOnline {
                Button {
                    Task { await vm.wakePC() }
                } label: {
                    Label("Power On PC", systemImage: "power.circle.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.mint, isProminent: true))

                Button {
                    vm.selectedTab = 4
                } label: {
                    Label("My PCs", systemImage: "desktopcomputer")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: tint)
        .focusSection()
    }
}

// MARK: - Tab 2: Desktop Controls, Sunshine Game Launcher & Video Streaming (Coming Soon)

struct TVControlsAndGamesTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @ObservedObject private var stream = MoonlightStreamController.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @State private var showsStreamSettings = false

    private var canStream: Bool { sunshine.isPaired && sunshine.reachable && vm.metrics.isOnline && !vm.isDemoMode }

    private func startStream(_ app: MoonlightApp) {
        stream.begin(.init(host: sunshine, app: app, pcName: vm.metrics.hostname, settings: streamSettings.settings))
    }

    /// Generates the PIN and has the Orbit agent type it into Sunshine (login saved from iPhone or Mac).
    private func pairAutomatically() {
        sunshine.beginPairing()
        guard let pin = sunshine.pairingPIN else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard sunshine.isPairing, sunshine.pairingPIN == pin else { return }
            do {
                _ = try await vm.client().data("/api/sunshine/pin", method: "POST",
                                               query: [URLQueryItem(name: "pin", value: pin), URLQueryItem(name: "name", value: MoonlightHostCoordinator.deviceName)])
            } catch {
                vm.statusBanner = "Automatic PIN entry failed: \(error.localizedDescription)"
            }
        }
    }

    private let desktopColumns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
    private let gameColumns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)

    private var sunshineKey: String { "\(vm.currentPC?.id ?? "")|\(vm.currentPC?.address ?? "")|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)|\(vm.isDemoMode)" }

    private func syncSunshine() async {
        guard !vm.isDemoMode, let pc = vm.currentPC else { return }
        sunshine.configure(pcID: pc.id, address: pc.address, httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        if vm.metrics.isOnline { await sunshine.refresh() }
    }

    private var streamSettingsSummary: String {
        let settings = streamSettings.settings
        let size = settings.pixelSize
        var parts = ["\(size.height)p", "\(settings.frameRate) fps", "\(settings.bitrateKbps / 1000) Mbps"]
        parts.append(settings.codec == .h264 || !MoonlightDeviceCapabilities.supportsHEVC ? "H.264" : "HEVC")
        if settings.requestsHDR { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }

    private var sunshineTint: Color {
        switch sunshine.statusTone {
        case .good: return TVPalette.mint
        case .active: return TVPalette.accent
        case .warning: return TVPalette.amber
        case .neutral: return Color.secondary
        }
    }

    /// Sunshine host card: pairing, running session and the Moonlight hand-off.
    private var sunshineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(sunshine.isPaired ? TVPalette.accent : Color.white.opacity(0.08))
                        .frame(width: 68, height: 68)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(sunshine.isPaired ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("Sunshine on \(vm.metrics.hostname)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        TVStatusPill(text: sunshine.statusText, tint: sunshineTint)
                    }
                    Text(sunshine.summary(pcName: vm.metrics.hostname))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let error = sunshine.lastError, !sunshine.isPairing {
                        Text(error).font(.system(size: 14)).foregroundStyle(TVPalette.amber).lineLimit(2)
                    }
                }
                Spacer()
                if sunshine.isPairing {
                    Button { sunshine.cancelPairing() } label: { Label("Cancel", systemImage: "xmark") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))
                } else if sunshine.isPaired {
                    if sunshine.isBusy {
                        Button { Task { await sunshine.quitRunningApp() } } label: { Label("Quit Session", systemImage: "stop.fill") }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))
                    }
                    Button { Task { await sunshine.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                    Button { sunshine.forgetPairing() } label: { Label("Forget", systemImage: "link.badge.minus") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                } else {
                    if vm.sunshineInfo?.canSubmitPin == true {
                        Button { pairAutomatically() } label: { Label("Pair automatically", systemImage: "wand.and.stars") }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
                            .disabled(!sunshine.reachable)
                    }
                    Button { sunshine.beginPairing() } label: { Label(vm.sunshineInfo?.canSubmitPin == true ? "Pair with PIN" : "Pair with Sunshine", systemImage: "link") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: vm.sunshineInfo?.canSubmitPin != true))
                        .disabled(!sunshine.reachable)
                }
            }
            if sunshine.isPairing, let pin = sunshine.pairingPIN {
                HStack(spacing: 18) {
                    HStack(spacing: 10) {
                        ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                            Text(String(digit))
                                .font(.system(size: 40, weight: .bold).monospacedDigit())
                                .frame(width: 64, height: 76)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TVPalette.accent, lineWidth: 2))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sunshine.pairingStage ?? "Waiting for the PIN…")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TVPalette.accent)
                        Text("On the PC open Sunshine's web UI, PIN page (https://localhost:\((vm.sunshineInfo?.webUIPort ?? 47990)))/pin), type this PIN and a device name.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: TVPalette.accent)
        .focusSection()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    TVSectionHeader("Windows Desktop & Display", subtitle: "Control active windows, take PC screenshots, or switch HDR directly from your Siri Remote") {
                        Text(vm.statusBanner)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TVPalette.accent)
                            .lineLimit(1)
                    }

                    LazyVGrid(columns: desktopColumns, spacing: 20) {
                        TVQuickActionCard(title: "Show Desktop", subtitle: "Minimize All (Win + D)", icon: "menubar.dock.rectangle", tint: TVPalette.accent) {
                            Task { await vm.sendAction("show_desktop") }
                        }
                        TVQuickActionCard(title: "Task View", subtitle: "Virtual Desktops (Win + Tab)", icon: "rectangle.3.group.fill", tint: TVPalette.purple) {
                            Task { await vm.sendAction("task_view") }
                        }
                        TVQuickActionCard(title: "Switch Window", subtitle: "Next App (Alt + Tab)", icon: "macwindow.on.rectangle", tint: TVPalette.mint) {
                            Task { await vm.sendAction("alt_tab") }
                        }
                        TVQuickActionCard(title: "PC Screenshot", subtitle: "Save to PC Pictures", icon: "camera.viewfinder", tint: TVPalette.accent) {
                            Task { await vm.sendAction("screenshot") }
                        }
                        TVQuickActionCard(title: "Fullscreen", subtitle: "Press F11", icon: "arrow.up.left.and.arrow.down.right", tint: TVPalette.accent) {
                            Task { await vm.sendAction("fullscreen") }
                        }
                        TVQuickActionCard(title: "Extend Display", subtitle: "DisplaySwitch /extend", icon: "display.2", tint: TVPalette.accent) {
                            Task { await vm.sendAction("restore_display") }
                        }
                        TVQuickActionCard(title: "Lock PC", subtitle: "Lock workstation", icon: "lock.fill", tint: TVPalette.accent) {
                            Task { await vm.sendAction("lock") }
                        }
                        TVQuickActionCard(title: "Quit Game", subtitle: "Close foreground game", icon: "xmark.octagon.fill", tint: TVPalette.coral) {
                            Task { await vm.sendAction("kill_game") }
                        }
                    }
                    .focusSection()
                }

                VStack(alignment: .leading, spacing: 16) {
                    TVSectionHeader("Stream & Launch", subtitle: canStream ? "Press an app to stream it to this Apple TV" : "Pair with Sunshine to stream here; apps launch on the PC meanwhile", tint: TVPalette.purple) {
                        Button {
                            Task { await vm.refreshGames(); await sunshine.refresh() }
                        } label: {
                            Label("Refresh Library", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.purple))
                    }
                    .focusSection()

                    if !vm.isDemoMode, vm.currentPC != nil, vm.metrics.isOnline { sunshineCard }

                    if vm.games.isEmpty {
                        TVEmptyBanner(
                            icon: "gamecontroller.fill",
                            tint: TVPalette.purple,
                            title: vm.metrics.isOnline ? "No Sunshine apps found" : "PC offline — library unavailable",
                            message: vm.metrics.isOnline
                                ? "Add applications in Sunshine on your PC and press Refresh Library to display them here."
                                : "Power on or connect to your PC to load your Sunshine library."
                        )
                    } else {
                        LazyVGrid(columns: gameColumns, spacing: 22) {
                            ForEach(vm.games) { game in
                                let app = sunshine.app(titled: game.title)
                                let isRunning = app != nil && app?.id == sunshine.info?.currentGame
                                Button {
                                    if canStream, let app { startStream(app) } else { Task { await vm.launchGame(game) } }
                                } label: {
                                    HStack(spacing: 18) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(Color.white.opacity(0.08))
                                                .frame(width: 68, height: 68)
                                            if let app, let data = sunshine.artwork[app.id] {
                                                MoonlightArtwork(data: data)
                                                    .frame(width: 68, height: 68)
                                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                            } else {
                                                Image(systemName: game.iconSymbol)
                                                    .font(.system(size: 28, weight: .semibold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .onAppear { if let app { sunshine.loadArtwork(for: app) } }

                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(game.title)
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(game.genre)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Image(systemName: "play.fill")
                                                Text(isRunning ? (canStream ? "Running · press to resume" : "Running on PC") : (canStream && app != nil ? "Press to stream" : "Press to launch"))
                                            }
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(isRunning || vm.metrics.activeGame == game.title ? TVPalette.mint : TVPalette.accent)
                                            .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.accent))
                            }
                        }
                        .focusSection()
                    }
                }

                HStack(spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(canStream ? TVPalette.accent : Color.white.opacity(0.08))
                            .frame(width: 76, height: 76)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(canStream ? Color.black.opacity(0.85) : TVPalette.accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(canStream ? "Stream \(vm.metrics.hostname) to this Apple TV" : "Stream your PC on the big screen")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(canStream
                             ? "\(streamSettingsSummary). Game controllers paired with the Apple TV are forwarded; the Siri Remote works as a trackpad."
                             : "Pair Orbit with Sunshine above. Video, audio and controller input then run right here, no Moonlight app needed.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button {
                        if let app = sunshine.desktopApp { startStream(app) }
                    } label: {
                        Label(sunshine.isBusy ? "Resume Stream" : "Stream Desktop", systemImage: "play.fill")
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
                    .disabled(!canStream || sunshine.desktopApp == nil)

                    Button { showsStreamSettings = true } label: { Label("Stream Settings", systemImage: "slider.horizontal.3") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                }
                .padding(24)
                .tvGlass(tint: TVPalette.accent)
                .focusSection()
            }
            .sheet(isPresented: $showsStreamSettings) {
                MoonlightStreamSettingsView(store: streamSettings, accent: TVPalette.accent, hostSupportsHEVC: sunshine.info.map(\.supportsHEVC)) { showsStreamSettings = false }
            }
            .onAppear {
                #if DEBUG
                if UserDefaults.standard.string(forKey: "orbitStreamSettings") != nil { showsStreamSettings = true }
                #endif
            }
            .task(id: sunshineKey) { await syncSunshine() }
            .padding(.horizontal, 52)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .onAppear {
            Task { await vm.refreshGames() }
        }
    }
}

private extension Color {
    init(tvHex: String) {
        let hex = tvHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let rgb = hex.count == 6 ? value : 0x4DD9F7
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Tab 3: Living Room Audio & Media Center

struct TVAudioAndMediaTab: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @State private var sessionForOutputPicker: TVAudioSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 18) {
                            ZStack {
                                TVRing(progress: (vm.metrics.isOnline || vm.isDemoMode) ? vm.metrics.volume / 100 : nil, tint: vm.metrics.isMuted ? TVPalette.amber : TVPalette.accent, lineWidth: 7)
                                    .frame(width: 84, height: 84)
                                Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(vm.metrics.isMuted ? TVPalette.amber : TVPalette.accent)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("MASTER PC AUDIO")
                                    .font(.system(size: 15, weight: .bold))
                                    .tracking(1.3)
                                    .foregroundStyle(TVPalette.accent)
                                Text(vm.metrics.isMuted ? "Muted" : (vm.metrics.isOnline || vm.isDemoMode ? "\(Int(vm.metrics.volume))%" : "Offline"))
                                    .font(.system(size: 38, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(vm.metrics.isMuted ? TVPalette.amber : .white)
                                    .contentTransition(.numericText())
                            }
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Button {
                                Task { await vm.adjustMasterVolume(by: -10) }
                            } label: {
                                Label("−10%", systemImage: "speaker.wave.1.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

                            Button {
                                Task { await vm.sendAction("volume_down") }
                            } label: {
                                Label("−5%", systemImage: "speaker.minus.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

                            Button {
                                Task { await vm.sendAction("mute") }
                            } label: {
                                Label(vm.metrics.isMuted ? "Unmute" : "Mute", systemImage: "speaker.slash.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.amber, isProminent: vm.metrics.isMuted))

                            Button {
                                Task { await vm.sendAction("volume_up") }
                            } label: {
                                Label("+5%", systemImage: "speaker.plus.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

                            Button {
                                Task { await vm.adjustMasterVolume(by: 10) }
                            } label: {
                                Label("+10%", systemImage: "speaker.wave.3.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tvGlass(tint: TVPalette.accent, elevated: true)
                    .focusSection()

                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("NOW PLAYING TRANSPORT")
                                .font(.system(size: 15, weight: .bold))
                                .tracking(1.3)
                                .foregroundStyle(TVPalette.mint)
                            Spacer()
                            Text("Siri Remote Play/Pause works here too")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 14) {
                            Button {
                                Task { await vm.sendAction("media_prev") }
                            } label: {
                                Label("Prev", systemImage: "backward.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.mint))

                            Button {
                                Task { await vm.sendAction("media_play_pause") }
                            } label: {
                                Label("Play / Pause", systemImage: "playpause.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.mint, isProminent: true))

                            Button {
                                Task { await vm.sendAction("media_next") }
                            } label: {
                                Label("Next", systemImage: "forward.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.mint))
                        }

                        if let game = vm.metrics.activeGame, !game.isEmpty {
                            TVStatusPill(text: "Game audio: \(game)", tint: TVPalette.mint, icon: "gamecontroller.fill")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tvGlass(tint: TVPalette.mint)
                    .focusSection()
                }

                VStack(alignment: .leading, spacing: 16) {
                    TVSectionHeader("Per-Application Audio Mixer", subtitle: "Adjust individual app volume or route audio to any of your PC's output devices", tint: TVPalette.purple) {
                        Button {
                            Task { await vm.refreshAudioMixer() }
                        } label: {
                            Label("Refresh Mixer", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.purple))
                    }
                    .focusSection()

                    if vm.audioSessions.isEmpty {
                        TVEmptyBanner(
                            icon: "speaker.wave.3.fill",
                            tint: TVPalette.purple,
                            title: vm.metrics.isOnline ? "No active audio streams on PC" : "PC offline — audio mixer unavailable",
                            message: vm.metrics.isOnline
                                ? "Start a game, browser, or media app on your PC and press Refresh Mixer."
                                : "Connect or power on your PC to control per-application volume and output devices."
                        )
                    } else {
                        ForEach(vm.audioSessions) { session in
                            audioSessionRow(session)
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

    private func audioSessionRow(_ session: TVAudioSession) -> some View {
        let tint: Color = session.isMuted ? TVPalette.amber : TVPalette.accent
        return HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: session.isMuted ? "speaker.slash.fill" : (session.pid == 0 ? "speaker.wave.2.bubble.fill" : "app.fill"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(session.pid == 0 ? "System sounds" : "PID \(session.pid)") • \(session.outputDeviceName ?? "Windows default output")")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 340, alignment: .leading)

            HStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 220, height: 12)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(
                            width: max(10, 220.0 * CGFloat(min(100, max(0, session.volume)) / 100.0)),
                            height: 12
                        )
                        .shadow(color: tint.opacity(0.6), radius: 6)
                        .animation(.snappy(duration: 0.3), value: session.volume)
                }

                Text("\(Int(session.volume))%")
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(session.isMuted ? TVPalette.amber : .white)
                    .frame(width: 58, alignment: .trailing)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 10)

            HStack(spacing: 12) {
                Button {
                    Task { await vm.adjustAppVolume(session, by: -10) }
                } label: {
                    Text("−10%")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

                Button {
                    Task { await vm.toggleAppMute(session) }
                } label: {
                    Label(session.isMuted ? "Unmute" : "Mute", systemImage: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.amber, isProminent: session.isMuted))

                Button {
                    Task { await vm.adjustAppVolume(session, by: 10) }
                } label: {
                    Text("+10%")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))

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
                .buttonStyle(TVActionPillStyle(tint: TVPalette.purple, isProminent: true))
                .disabled(!vm.audioRoutingAvailable && !vm.isDemoMode)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .tvGlass(tint: tint, cornerRadius: 22)
        .focusSection()
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
            TVAmbientBackground(isOnline: vm.metrics.isOnline)

            VStack(alignment: .leading, spacing: 24) {
                TVSectionHeader("Select Audio Output", subtitle: "Route \(currentSession.name) (PID \(currentSession.pid)) to any audio output device on your PC (\(vm.audioOutputs.count) available)", tint: TVPalette.purple) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                }

                if vm.audioOutputs.isEmpty {
                    Text("No Windows audio output devices reported by the PC Companion yet.")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tvGlass()
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
                                            .foregroundStyle(isSelected ? TVPalette.mint : TVPalette.purple)
                                            .frame(width: 40)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(device.name)
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(isSelected ? "Current output for \(currentSession.name)" : "Press Select on Siri Remote to route audio here")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(isSelected ? TVPalette.mint : Color.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if isSelected {
                                            TVStatusPill(text: "ACTIVE", tint: TVPalette.mint, icon: "checkmark.circle.fill")
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 18)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(TVSurfaceCardStyle(accent: isSelected ? TVPalette.mint : TVPalette.purple))
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

    private var sortedProcesses: [TVProcessItem] {
        vm.processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TVSectionHeader("Windows Process Monitor", subtitle: "\(vm.processes.count) processes • sorted by CPU • select an unresponsive app to end it") {
                    if let msg = vm.processStatusMessage {
                        Text(msg)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TVPalette.accent)
                            .lineLimit(1)
                            .padding(.trailing, 12)
                    }
                    Button {
                        Task { await vm.refreshProcesses() }
                    } label: {
                        Label(vm.isLoadingProcesses ? "Refreshing…" : "Refresh Processes", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                }
                .focusSection()

                if vm.processes.isEmpty {
                    TVEmptyBanner(
                        icon: "list.bullet.rectangle.portrait.fill",
                        tint: TVPalette.accent,
                        title: vm.metrics.isOnline ? "Loading Windows processes…" : "PC offline — process list unavailable",
                        message: vm.metrics.isOnline
                            ? "Press Refresh Processes to fetch running applications from your PC."
                            : "Connect or power on your PC to monitor live CPU, GPU, RAM, and VRAM usage per process."
                    )
                } else {
                    ForEach(sortedProcesses) { proc in
                        HStack(spacing: 22) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill((proc.canTerminate ? TVPalette.accent : Color.secondary).opacity(0.16))
                                    .frame(width: 52, height: 52)
                                Image(systemName: proc.canTerminate ? "app.fill" : "lock.shield.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(proc.canTerminate ? TVPalette.accent : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(proc.name)
                                    .font(.system(size: 21, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("PID \(proc.pid) • \(proc.status.capitalized)\(proc.canTerminate ? "" : " • Protected")")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 300, alignment: .leading)

                            TVMetricPill(label: "CPU", value: tvValue(proc.cpuPercent, "%.1f", suffix: "%"), tint: TVPalette.accent, fraction: proc.cpuPercent.map { $0 / 100 })
                            TVMetricPill(label: "GPU", value: tvValue(proc.gpuPercent, "%.1f", suffix: "%"), tint: TVPalette.purple, fraction: proc.gpuPercent.map { $0 / 100 })
                            TVMetricPill(label: "RAM", value: tvValue(proc.memoryMB, "%.0f", suffix: " MB"), tint: TVPalette.mint, fraction: proc.memoryMB.flatMap { vm.metrics.ramTotalGB > 0 ? $0 / (vm.metrics.ramTotalGB * 1024) : nil })
                            TVMetricPill(label: "VRAM", value: tvValue(proc.vramMB, "%.0f", suffix: " MB"), tint: TVPalette.accent, fraction: proc.vramMB.flatMap { mb in vm.metrics.vramTotalGB.flatMap { $0 > 0 ? mb / ($0 * 1024) : nil } })

                            Spacer(minLength: 12)

                            Button {
                                processToKill = proc
                            } label: {
                                Label("End Task", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.coral, isDestructive: true))
                            .disabled(!proc.canTerminate)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .tvGlass(cornerRadius: 22)
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
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value == "—" ? Color.secondary : Color.white)
                .lineLimit(1)
                .contentTransition(.numericText())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    if let fraction, fraction.isFinite {
                        Capsule().fill(tint)
                            .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 150, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .fill(TVPalette.accent.opacity(0.18))
                    .frame(width: 68, height: 68)
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(TVPalette.accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("IMPORT PAIRED PC FROM IPHONE")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(TVPalette.accent)
                Text(vm.iPhoneSyncStatusMessage ?? "Already paired your PC on your iPhone? Open Orbit on your iPhone (or use iCloud) to import its address, certificate, MAC address and token automatically.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button {
                Task { await vm.syncFromiPhone(silent: false) }
            } label: {
                Label(
                    vm.isSyncingFromiPhone ? "Syncing from iPhone…" : "Sync PC from iPhone",
                    systemImage: "arrow.triangle.2.circlepath.iphone"
                )
            }
            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))

            Button {
                vm.setDemoMode(!vm.isDemoMode)
            } label: {
                Label(
                    vm.isDemoMode ? "Disable Demo Mode" : "Enable Demo Mode",
                    systemImage: "sparkles.tv"
                )
            }
            .buttonStyle(TVActionPillStyle(tint: TVPalette.purple, isProminent: vm.isDemoMode))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: TVPalette.accent, elevated: true)
        .focusSection()
    }

    @ViewBuilder
    private var savedPCsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TVSectionHeader("Saved Workstations", subtitle: vm.savedPCs.isEmpty ? nil : "\(vm.savedPCs.count) saved • the active PC is used for every tab")

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
                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.accent))
            } else {
                ForEach(vm.savedPCs) { pc in
                    let selected = vm.selectedPCID == pc.id
                    let live = selected && vm.metrics.isOnline && !vm.isDemoMode
                    HStack(spacing: 20) {
                        ZStack {
                            TVRing(progress: live && vm.metrics.telemetryAvailable != false ? vm.metrics.cpuUsage / 100 : nil, tint: live ? TVPalette.mint : TVPalette.accent, lineWidth: 5)
                                .frame(width: 58, height: 58)
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(live ? TVPalette.mint : TVPalette.accent)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Text(pc.name)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if selected {
                                    TVStatusPill(text: live ? "ONLINE" : "ACTIVE", tint: live ? TVPalette.mint : TVPalette.accent)
                                }
                            }
                            Text("\(pc.address):\(pc.securePort) • MAC \(pc.macAddress.isEmpty ? "not saved" : pc.macAddress) • \(pc.certificateFingerprint.isEmpty ? "no certificate" : "TLS pinned")")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            vm.selectPC(pc)
                        } label: {
                            Text(selected ? "Active PC" : "Connect")
                        }
                        .buttonStyle(TVActionPillStyle(tint: selected ? TVPalette.mint : TVPalette.accent, isProminent: selected))

                        Button {
                            vm.selectPC(pc)
                            Task { await vm.wakePC() }
                        } label: {
                            Label("Wake", systemImage: "power")
                        }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.mint))

                        Button {
                            vm.deletePC(pc)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.coral, isDestructive: true))
                    }
                    .padding(22)
                    .tvGlass(tint: live ? TVPalette.mint : .white, cornerRadius: 22)
                    .focusSection()
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var bonjourDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TVSectionHeader("Discovered on Local Network", subtitle: "Bonjour _orbit._tcp • pair with the 6-digit code shown on the PC", tint: TVPalette.purple) {
                Button {
                    vm.startDiscovery()
                } label: {
                    Label(vm.isScanningNetwork ? "Re-Scan Network" : "Scan Network", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.purple))
            }
            .focusSection()

            if vm.discoveredPCs.isEmpty {
                Button {
                    vm.startDiscovery()
                } label: {
                    HStack(spacing: 16) {
                        if vm.isScanningNetwork {
                            ProgressView().tint(TVPalette.purple)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 24))
                                .foregroundStyle(TVPalette.purple)
                        }
                        Text(vm.isScanningNetwork
                             ? "Scanning the local network for Orbit Windows Companion… Press Down for manual IP pairing."
                             : "No PCs discovered via Bonjour yet. Press here to re-scan or move down for manual IP pairing.")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.purple))
            } else {
                ForEach(vm.discoveredPCs) { pc in
                    HStack(spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(TVPalette.purple.opacity(0.18))
                                .frame(width: 52, height: 52)
                            Image(systemName: "wifi")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(TVPalette.purple)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pc.name)
                                .font(.system(size: 20, weight: .bold))
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
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.purple, isProminent: true))
                    }
                    .padding(22)
                    .tvGlass(tint: TVPalette.purple, cornerRadius: 22)
                    .focusSection()
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var manualPairingSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader("Manual Pair by IP & 6-Digit PIN", subtitle: "Select the address field to open the keyboard, then choose Probe & Pair PC. Pairing uses SRP-6a; no token is typed.", tint: TVPalette.mint)

            HStack(spacing: 20) {
                Button {
                    showIPAlert = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "network")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(TVPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("PC IPv4 ADDRESS")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(TVPalette.accent)
                            Text(manualHost.isEmpty ? "Select to enter PC IP (e.g. 192.168.1.50)" : manualHost)
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
                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.accent))

                Button {
                    showPortAlert = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PORT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TVPalette.accent)
                        Text(manualPort.isEmpty ? "8765" : manualPort)
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(width: 190, alignment: .leading)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.accent))

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
                        if vm.isProbingManualHost {
                            ProgressView().tint(TVPalette.mint)
                        } else {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(TVPalette.mint)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CONNECT & PAIR")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(TVPalette.mint)
                            Text(vm.isProbingManualHost ? "Probing PC…" : "Probe & Pair PC")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
                }
                .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.mint))
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
                                .foregroundStyle(TVPalette.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("6-DIGIT PIN SHOWN ON \(target.name.uppercased())")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(TVPalette.mint)
                                Text(vm.pairingPIN.isEmpty ? "Select to enter the 6-digit PIN" : vm.pairingPIN)
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
                    .buttonStyle(TVSurfaceCardStyle(accent: TVPalette.mint))

                    Button {
                        Task { await vm.finishPINPairing() }
                    } label: {
                        Label(vm.isPairingInProgress ? "Verifying PIN…" : "Verify PIN & Save PC", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.mint, isProminent: true))
                    .disabled(vm.isPairingInProgress || vm.pairingPIN.trimmingCharacters(in: .whitespaces).count < 4)
                }
                .padding(.top, 6)
                .focusSection()
            }

            if let error = vm.pairingErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: TVPalette.mint)
        .focusSection()
    }
}
