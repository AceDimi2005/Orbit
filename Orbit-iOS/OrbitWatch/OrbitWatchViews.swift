import SwiftUI
import WatchKit

enum OrbitWatchPalette {
    static let accent = Color(red: 0.25, green: 0.84, blue: 0.96)
    static let secondary = Color(red: 0.42, green: 0.52, blue: 1.0)
    static let purple = Color(red: 0.71, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.94, blue: 0.66)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.48)
    static let cardBackground = Color.white.opacity(0.08)
}

private extension Color {
    init?(watchHex hex: String) {
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}

extension OrbitWatchViewModel {
    /// Accent synced from the iPhone theme; falls back to Orbit cyan.
    var accent: Color { Color(watchHex: accentHex) ?? OrbitWatchPalette.accent }
    var secondaryAccent: Color { Color(watchHex: secondaryHex) ?? OrbitWatchPalette.secondary }
}

// MARK: - Shared watch primitives

private struct WatchPageBackground: View {
    var accent: Color
    var secondary: Color
    var isOnline: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.05, blue: 0.09), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(accent.opacity(isOnline ? 0.30 : 0.14))
                .frame(width: 180, height: 180)
                .blur(radius: 48)
                .offset(x: -70, y: -90)
            Circle()
                .fill(secondary.opacity(0.18))
                .frame(width: 160, height: 160)
                .blur(radius: 50)
                .offset(x: 80, y: 110)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func watchPage(_ vm: OrbitWatchViewModel) -> some View {
        containerBackground(for: .tabView) {
            WatchPageBackground(accent: vm.accent, secondary: vm.secondaryAccent, isOnline: vm.isOnline)
        }
    }

    func watchCard(_ tint: Color = .white, cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
    }
}

private struct WatchRing: View {
    var progress: Double?
    var tint: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.5), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * min(1, max(0, progress)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.55), radius: 4)
                    .animation(.snappy(duration: 0.4), value: progress)
            }
        }
    }
}

private struct WatchGradientButton: View {
    var title: String
    var icon: String
    var colors: [Color]
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
            .shadow(color: (colors.first ?? .clear).opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct OrbitWatchRootView: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
        NavigationStack {
            TabView(selection: $vm.selectedTab) {
                WatchCockpitPage(vm: vm)
                    .tag(0)

                WatchPowerDeckPage(vm: vm)
                    .tag(1)

                WatchMotionCursorPage(vm: vm)
                    .tag(2)

                WatchMediaAndGamesPage(vm: vm)
                    .tag(3)
            }
            .tabViewStyle(.verticalPage)
        }
        .tint(vm.accent)
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab != 2 && vm.isMotionCursorActive {
                vm.stopMotionCursor()
            }
        }
    }
}

// MARK: - Page 1: Live Cockpit & Smart Stack Live Activity

private struct WatchCockpitPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var showPCSwitcher = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                headerBar

                if let game = vm.activeGame, !game.isEmpty, vm.isOnline {
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OrbitWatchPalette.mint)
                        Text(game)
                            .font(.system(size: 11.5, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let fps = vm.fps, fps > 0 {
                            Text("\(Int(fps.rounded())) FPS")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(OrbitWatchPalette.mint)
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .watchCard(OrbitWatchPalette.mint, cornerRadius: 11)
                }

                HStack(spacing: 8) {
                    ringTile(
                        title: "CPU",
                        value: vm.isOnline && vm.telemetryAvailable ? "\(Int(vm.cpuUsage.rounded()))" : "—",
                        unit: "%",
                        detail: vm.cpuTemp.map { "\(Int($0.rounded()))°" } ?? "Load",
                        progress: vm.isOnline && vm.telemetryAvailable ? vm.cpuUsage / 100.0 : nil,
                        tint: vm.accent
                    )
                    ringTile(
                        title: "GPU",
                        value: vm.isOnline ? vm.gpuUsage.map { "\(Int($0.rounded()))" } ?? "—" : "—",
                        unit: "%",
                        detail: vm.gpuTemp.map { "\(Int($0.rounded()))°" } ?? "Graphics",
                        progress: vm.isOnline ? vm.gpuUsage.map { $0 / 100.0 } : nil,
                        tint: OrbitWatchPalette.purple
                    )
                }

                HStack(spacing: 8) {
                    barTile(
                        title: "RAM",
                        value: vm.isOnline && vm.ramTotalGB > 0 ? "\(Int(vm.ramUsagePercent.rounded()))%" : "—",
                        detail: vm.ramTotalGB > 0 ? String(format: "%.1f / %.0f GB", vm.ramUsedGB, vm.ramTotalGB) : "Memory",
                        progress: vm.isOnline ? vm.ramUsagePercent / 100.0 : nil,
                        tint: OrbitWatchPalette.mint,
                        icon: "memorychip"
                    )
                    barTile(
                        title: "PWR",
                        value: totalWattsText,
                        detail: vm.isOnline ? "Up \(vm.formattedUptime)" : "Offline",
                        progress: totalWattsProgress,
                        tint: OrbitWatchPalette.amber,
                        icon: "bolt.fill"
                    )
                }

                HStack(spacing: 6) {
                    Button {
                        if vm.isOnline {
                            vm.selectedTab = 2
                        } else {
                            Task { await vm.wakePC() }
                        }
                    } label: {
                        Label(
                            vm.isOnline ? "Air Mouse" : (vm.isWaking ? "Waking…" : "Power On"),
                            systemImage: vm.isOnline ? "gyroscope" : "power"
                        )
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(.black.opacity(0.85))
                        .background(
                            LinearGradient(colors: vm.isOnline ? [vm.accent, vm.secondaryAccent] : [OrbitWatchPalette.mint, Color(red: 0.36, green: 0.80, blue: 0.98)], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isWaking)

                    Button {
                        vm.togglePhoneLiveActivity()
                    } label: {
                        Image(systemName: vm.isLiveActivityActive ? "capsule.portrait.tophalf.filled" : "capsule.portrait")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 32)
                            .background(
                                (vm.isLiveActivityActive ? OrbitWatchPalette.mint : Color.white).opacity(vm.isLiveActivityActive ? 0.28 : 0.12),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .foregroundStyle(vm.isLiveActivityActive ? OrbitWatchPalette.mint : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toggle Live Activity")
                }

                Text(vm.statusMessage)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .navigationTitle("Orbit")
        .watchPage(vm)
        .sheet(isPresented: $showPCSwitcher) {
            List {
                ForEach(vm.savedPCs) { pc in
                    Button {
                        vm.selectPC(pc)
                        showPCSwitcher = false
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(pc.id == vm.selectedPCID ? vm.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pc.name)
                                    .font(.footnote.weight(.bold))
                                Text(pc.address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pc.id == vm.selectedPCID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(vm.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Switch PC")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(vm.isOnline ? OrbitWatchPalette.mint : Color.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: (vm.isOnline ? OrbitWatchPalette.mint : Color.orange).opacity(0.8), radius: 4)
            }
            Button {
                if vm.savedPCs.count > 1 {
                    showPCSwitcher = true
                } else {
                    Task { await vm.refreshTelemetry() }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(vm.pcName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if vm.savedPCs.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 2)

            if vm.isOnline && vm.pingMs > 0 {
                Text("\(vm.pingMs) ms")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await vm.refreshTelemetry() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .padding(5)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
    }

    private var totalWattsText: String {
        guard vm.isOnline else { return "—" }
        guard vm.cpuPowerWatts != nil || vm.gpuPowerWatts != nil else { return "—" }
        let total = (vm.cpuPowerWatts ?? 0) + (vm.gpuPowerWatts ?? 0)
        return "\(Int(total.rounded()))W"
    }

    private var totalWattsProgress: Double? {
        guard vm.isOnline, vm.cpuPowerWatts != nil || vm.gpuPowerWatts != nil else { return nil }
        let total = (vm.cpuPowerWatts ?? 0) + (vm.gpuPowerWatts ?? 0)
        return min(1.0, max(0.03, total / 450.0))
    }

    private func ringTile(title: String, value: String, unit: String, detail: String, progress: Double?, tint: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                WatchRing(progress: progress, tint: tint, lineWidth: 5)
                VStack(spacing: -1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(value)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if value != "—" {
                            Text(unit)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 58, height: 58)
            Text(detail)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .watchCard(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)\(unit) \(detail)")
    }

    private func barTile(title: String, value: String, detail: String, progress: Double?, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    if let progress {
                        Capsule()
                            .fill(tint.gradient)
                            .frame(width: max(3, geo.size.width * min(1, max(0, progress))))
                            .shadow(color: tint.opacity(0.6), radius: 3)
                    }
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .watchCard(tint)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page 2: Power & Desktop Shortcuts Deck

private struct WatchPowerDeckPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var confirmAction: String?

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Power & System", systemImage: "bolt.shield.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(vm.accent)
                    Spacer()
                    Text(vm.isOnline ? "Online" : "Offline")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(vm.isOnline ? OrbitWatchPalette.mint : .orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((vm.isOnline ? OrbitWatchPalette.mint : Color.orange).opacity(0.16), in: Capsule())
                }

                HStack(spacing: 6) {
                    WatchGradientButton(title: vm.isWaking ? "Waking…" : "Power On", icon: "power", colors: [OrbitWatchPalette.mint, Color(red: 0.36, green: 0.80, blue: 0.98)]) {
                        Task { await vm.wakePC() }
                    }
                    .disabled(vm.isWaking)
                    WatchGradientButton(title: "Shut Down", icon: "power.circle.fill", colors: [OrbitWatchPalette.coral, Color(red: 1.0, green: 0.62, blue: 0.40)]) {
                        confirmAction = "shutdown"
                    }
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    actionTile("Sleep", icon: "moon.zzz.fill", tint: OrbitWatchPalette.amber) {
                        await vm.sendPowerAction("sleep")
                    }
                    actionTile("Lock PC", icon: "lock.fill", tint: vm.accent) {
                        await vm.sendPowerAction("lock")
                    }
                    actionTile("Restart", icon: "arrow.triangle.2.circlepath", tint: .orange) {
                        confirmAction = "restart"
                    }
                    actionTile("Quit Game", icon: "xmark.octagon.fill", tint: OrbitWatchPalette.coral) {
                        await vm.sendPowerAction("kill_game")
                    }
                }

                Text("DESKTOP SHORTCUTS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                LazyVGrid(columns: columns, spacing: 6) {
                    actionTile("Desktop", icon: "menubar.dock.rectangle", tint: vm.accent) {
                        await vm.sendPowerAction("show_desktop")
                    }
                    actionTile("Task View", icon: "rectangle.3.group", tint: OrbitWatchPalette.purple) {
                        await vm.sendPowerAction("task_view")
                    }
                    actionTile("Alt+Tab", icon: "macwindow.on.rectangle", tint: .cyan) {
                        await vm.sendPowerAction("alt_tab")
                    }
                    actionTile("Screenshot", icon: "camera.viewfinder", tint: OrbitWatchPalette.mint) {
                        await vm.sendPowerAction("screenshot")
                    }
                    actionTile("HDR", icon: "sun.max.fill", tint: OrbitWatchPalette.amber) {
                        await vm.sendPowerAction("toggle_hdr")
                    }
                    actionTile("Display", icon: "display.2", tint: .indigo) {
                        await vm.sendPowerAction("restore_display")
                    }
                }

                Text(vm.statusMessage)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .navigationTitle("Power")
        .watchPage(vm)
        .confirmationDialog(
            confirmAction == "restart" ? "Restart your PC?" : "Shut down your PC?",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = confirmAction {
                Button(action == "restart" ? "Restart PC" : "Shut Down PC", role: .destructive) {
                    confirmAction = nil
                    Task { await vm.sendPowerAction(action) }
                }
            }
            Button("Cancel", role: .cancel) { confirmAction = nil }
        }
    }

    private func actionTile(_ title: String, icon: String, tint: Color, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .watchCard(tint, cornerRadius: 11)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Page 3: Wrist Motion Air Mouse & Trackpad ("Gyro Cursor")

private struct WatchMotionCursorPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var lastTouchPoint: CGPoint?
    @FocusState private var isCrownFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: vm.motionMode.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(vm.accent)
                    Text(vm.motionMode.rawValue)
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    Button {
                        cycleMode()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8, weight: .bold))
                            Text("Mode")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(vm.accent.opacity(0.20), in: Capsule())
                        .foregroundStyle(vm.accent)
                    }
                    .buttonStyle(.plain)
                }

                // Radar / Trackpad Arena with live Wrist Motion Crosshair + Crown Scroll
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [vm.accent.opacity(vm.isMotionCursorActive ? 0.16 : 0.08), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    vm.isMotionCursorActive ? vm.accent : Color.white.opacity(0.14),
                                    lineWidth: vm.isMotionCursorActive ? 1.4 : 0.8
                                )
                        )
                        .shadow(color: vm.isMotionCursorActive ? vm.accent.opacity(0.4) : .clear, radius: 8)

                    // Crosshair Grid Lines
                    Path { path in
                        path.move(to: CGPoint(x: 75, y: 8))
                        path.addLine(to: CGPoint(x: 75, y: 66))
                        path.move(to: CGPoint(x: 16, y: 37))
                        path.addLine(to: CGPoint(x: 134, y: 37))
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                    // Live Gyro / Touch Indicator Dot
                    Circle()
                        .fill(vm.isMotionCursorActive ? vm.accent : Color.white.opacity(0.45))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: vm.isMotionCursorActive ? vm.accent.opacity(0.9) : .clear, radius: 7)
                        .offset(vm.cursorIndicatorOffset)

                    VStack {
                        Spacer()
                        Text(vm.isMotionCursorActive ? "Tilt wrist · Tap to click · Crown scrolls" : "Tap to click · Drag or Start Gyro")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.bottom, 4)
                    }
                }
                .frame(height: 74)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if let last = lastTouchPoint {
                                let dx = Int(((value.location.x - last.x) * 2.4 * vm.sensitivity).rounded())
                                let dy = Int(((value.location.y - last.y) * 2.4 * vm.sensitivity).rounded())
                                if dx != 0 || dy != 0 {
                                    vm.sendCursorPacket(dx: dx, dy: dy)
                                }
                            }
                            lastTouchPoint = value.location
                        }
                        .onEnded { _ in
                            lastTouchPoint = nil
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        vm.sendCursorPacket(click: "left")
                    }
                )
                .focusable(true)
                .focused($isCrownFocused)
                .digitalCrownRotation(
                    $vm.crownScrollAccumulator,
                    from: -1000,
                    through: 1000,
                    by: 0.5,
                    sensitivity: .medium,
                    isContinuous: true,
                    isHapticFeedbackEnabled: true
                )
                .onChange(of: vm.crownScrollAccumulator) { _, newValue in
                    vm.handleCrownScrollChange(newValue)
                }

                // Start/Stop Wrist Motion + Recenter Row
                if vm.motionMode != .touchPad {
                    HStack(spacing: 6) {
                        Button {
                            vm.toggleMotionCursor()
                            isCrownFocused = true
                        } label: {
                            Label(
                                vm.isMotionCursorActive ? "Stop Gyro" : "Start Gyro",
                                systemImage: vm.isMotionCursorActive ? "pause.fill" : "gyroscope"
                            )
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(.black.opacity(0.85))
                            .background(
                                LinearGradient(colors: vm.isMotionCursorActive ? [OrbitWatchPalette.mint, Color(red: 0.36, green: 0.80, blue: 0.98)] : [vm.accent, vm.secondaryAccent], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            vm.calibrateWristCenter()
                        } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 32, height: 30)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Calibrate Wrist Center")
                    }
                }

                // Mouse Click & Drag Lock Buttons
                HStack(spacing: 5) {
                    clickButton("Left", icon: "computermouse.fill") {
                        vm.sendCursorPacket(click: "left")
                    }
                    clickButton("Right", icon: "contextualmenu.and.cursorarrow") {
                        vm.sendCursorPacket(click: "right")
                    }
                    clickButton("2x", icon: "cursorarrow.click.2") {
                        vm.sendCursorPacket(click: "double")
                    }
                    Button {
                        vm.toggleDragLock()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: vm.isDragLocked ? "lock.fill" : "hand.point.up.left.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Drag")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            vm.isDragLocked ? OrbitWatchPalette.amber.opacity(0.30) : OrbitWatchPalette.cardBackground,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(vm.isDragLocked ? OrbitWatchPalette.amber.opacity(0.6) : .clear, lineWidth: 1))
                        .foregroundStyle(vm.isDragLocked ? OrbitWatchPalette.amber : .white)
                    }
                    .buttonStyle(.plain)
                }

                // Sensitivity Selector
                HStack(spacing: 4) {
                    Text("Speed")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach([("Low", 0.7), ("Med", 1.2), ("Fast", 1.8), ("Max", 2.5)], id: \.0) { label, value in
                        Button {
                            WKInterfaceDevice.current().play(.click)
                            vm.sensitivity = value
                        } label: {
                            Text(label)
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    abs(vm.sensitivity - value) < 0.15 ? vm.accent.opacity(0.26) : Color.white.opacity(0.07),
                                    in: Capsule()
                                )
                                .foregroundStyle(abs(vm.sensitivity - value) < 0.15 ? vm.accent : .white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .navigationTitle("Air Mouse")
        .watchPage(vm)
        .onAppear {
            isCrownFocused = true
        }
    }

    private func cycleMode() {
        WKInterfaceDevice.current().play(.click)
        let all = WatchCursorMode.allCases
        if let idx = all.firstIndex(of: vm.motionMode) {
            let next = all[(idx + 1) % all.count]
            vm.motionMode = next
            if next == .touchPad {
                vm.stopMotionCursor()
            } else if vm.isMotionCursorActive {
                vm.startMotionCursor()
            }
        }
    }

    private func clickButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 8.5, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Page 4: Crown Volume, Media & Sunshine Games

private struct WatchMediaAndGamesPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var crownVolume: Double = 40
    @FocusState private var isVolumeCrownFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Digital Crown Volume Ring
                HStack(spacing: 8) {
                    ZStack {
                        WatchRing(progress: crownVolume / 100.0, tint: vm.isMuted ? OrbitWatchPalette.coral : vm.accent, lineWidth: 5)
                        VStack(spacing: 0) {
                            Image(systemName: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(vm.isMuted ? OrbitWatchPalette.coral : vm.accent)
                            Text(vm.isMuted ? "Muted" : "\(Int(crownVolume.rounded()))")
                                .font(.system(size: vm.isMuted ? 10 : 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Crown Volume")
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(vm.isOnline ? "Turn the Crown" : "PC offline")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Button {
                            Task { await vm.sendPowerAction("mute") }
                        } label: {
                            Text(vm.isMuted ? "Unmute" : "Mute")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background((vm.isMuted ? OrbitWatchPalette.coral : Color.white).opacity(vm.isMuted ? 0.24 : 0.12), in: Capsule())
                                .foregroundStyle(vm.isMuted ? OrbitWatchPalette.coral : .white)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .watchCard(vm.accent)
                .focusable(true)
                .focused($isVolumeCrownFocused)
                .digitalCrownRotation(
                    $crownVolume,
                    from: 0,
                    through: 100,
                    by: 2,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .onChange(of: crownVolume) { _, newValue in
                    vm.setPCVolume(newValue)
                }
                .onAppear {
                    crownVolume = vm.volume
                    isVolumeCrownFocused = true
                }
                .onChange(of: vm.volume) { _, newValue in
                    if abs(crownVolume - newValue) >= 2 {
                        crownVolume = newValue
                    }
                }

                // Media Transport Row
                HStack(spacing: 5) {
                    mediaButton("backward.end.fill") { await vm.sendPowerAction("media_prev") }
                    mediaButton("playpause.fill", tint: vm.accent, prominent: true) { await vm.sendPowerAction("media_play_pause") }
                    mediaButton("forward.end.fill") { await vm.sendPowerAction("media_next") }
                }

                if !vm.games.isEmpty {
                    Text("SUNSHINE GAMES")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    ForEach(vm.games.prefix(8)) { game in
                        Button {
                            vm.launchGame(game)
                        } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(LinearGradient(colors: [OrbitWatchPalette.mint.opacity(0.5), OrbitWatchPalette.mint.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 26, height: 26)
                                    Image(systemName: "gamecontroller.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(game.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Text(game.genre)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(OrbitWatchPalette.mint)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .watchCard(OrbitWatchPalette.mint, cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(vm.isOnline ? "No Sunshine apps on this PC yet." : "Connect to your PC to see Sunshine games.")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .navigationTitle("Media")
        .watchPage(vm)
    }

    private func mediaButton(_ icon: String, tint: Color = .white, prominent: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: prominent ? 14 : 12, weight: .bold))
                .foregroundStyle(prominent ? .black.opacity(0.85) : tint)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    prominent
                        ? AnyShapeStyle(LinearGradient(colors: [vm.accent, vm.secondaryAccent], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(OrbitWatchPalette.cardBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
