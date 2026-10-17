import SwiftUI
import WatchKit

enum OrbitWatchPalette {
    static let accent = Color(red: 0.25, green: 0.84, blue: 0.96)
    static let purple = Color(red: 0.71, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.94, blue: 0.66)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.48)
    static let cardBackground = Color.white.opacity(0.08)
}

struct OrbitWatchRootView: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
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

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

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
                                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(OrbitWatchPalette.mint)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(OrbitWatchPalette.mint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    metricTile(
                        title: "CPU",
                        value: vm.isOnline ? "\(Int(vm.cpuUsage.rounded()))%" : "—",
                        detail: vm.cpuTemp.map { "\(Int($0.rounded()))°C" } ?? "Load",
                        progress: vm.isOnline ? vm.cpuUsage / 100.0 : 0,
                        tint: OrbitWatchPalette.accent,
                        icon: "cpu"
                    )
                    metricTile(
                        title: "GPU",
                        value: vm.isOnline && vm.gpuUsage != nil ? "\(Int((vm.gpuUsage ?? 0).rounded()))%" : "—",
                        detail: vm.gpuTemp.map { "\(Int($0.rounded()))°C" } ?? "Graphics",
                        progress: vm.isOnline ? (vm.gpuUsage ?? 0) / 100.0 : 0,
                        tint: OrbitWatchPalette.purple,
                        icon: "rectangle.3.group"
                    )
                    metricTile(
                        title: "RAM",
                        value: vm.isOnline ? "\(Int(vm.ramUsagePercent.rounded()))%" : "—",
                        detail: vm.ramTotalGB > 0 ? String(format: "%.1fG", vm.ramUsedGB) : "Memory",
                        progress: vm.isOnline ? vm.ramUsagePercent / 100.0 : 0,
                        tint: OrbitWatchPalette.mint,
                        icon: "memorychip"
                    )
                    metricTile(
                        title: "PWR",
                        value: totalWattsText,
                        detail: vm.isOnline ? vm.formattedUptime : "Offline",
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
                            vm.isOnline ? "Air Mouse" : "Power On",
                            systemImage: vm.isOnline ? "gyroscope" : "power"
                        )
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            (vm.isOnline ? OrbitWatchPalette.accent : OrbitWatchPalette.mint).opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(vm.isOnline ? OrbitWatchPalette.accent : OrbitWatchPalette.mint)
                    }
                    .buttonStyle(.plain)

                    Button {
                        vm.togglePhoneLiveActivity()
                    } label: {
                        Image(systemName: vm.isLiveActivityActive ? "capsule.portrait.tophalf.filled" : "sparkles.rectangle.stack")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 30)
                            .background(
                                (vm.isLiveActivityActive ? OrbitWatchPalette.mint : Color.white).opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .sheet(isPresented: $showPCSwitcher) {
            List {
                ForEach(vm.savedPCs) { pc in
                    Button {
                        vm.selectPC(pc)
                        showPCSwitcher = false
                    } label: {
                        HStack {
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
                                    .foregroundStyle(OrbitWatchPalette.accent)
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
            Circle()
                .fill(vm.isOnline ? OrbitWatchPalette.mint : Color.orange)
                .frame(width: 7, height: 7)
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

            Button {
                Task { await vm.refreshTelemetry() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .padding(5)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var totalWattsText: String {
        guard vm.isOnline else { return "—" }
        let total = (vm.cpuPowerWatts ?? 0) + (vm.gpuPowerWatts ?? 0)
        return total > 0 ? "\(Int(total.rounded()))W" : "Live"
    }

    private var totalWattsProgress: Double {
        guard vm.isOnline else { return 0 }
        let total = (vm.cpuPowerWatts ?? 0) + (vm.gpuPowerWatts ?? 0)
        return min(1.0, max(0.05, total / 450.0))
    }

    private func metricTile(title: String, value: String, detail: String, progress: Double, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                Text(detail)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(3, geo.size.width * min(1, max(0, progress))))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .foregroundStyle(OrbitWatchPalette.accent)
                    Spacer()
                }

                // Primary Power On & Shut Down buttons
                HStack(spacing: 6) {
                    Button {
                        Task { await vm.wakePC() }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "power")
                                .font(.system(size: 16, weight: .bold))
                            Text("Power On")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(OrbitWatchPalette.mint.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(OrbitWatchPalette.mint)
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmAction = "shutdown"
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "power.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Shut Down")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(OrbitWatchPalette.coral.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(OrbitWatchPalette.coral)
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    actionTile("Sleep", icon: "moon.zzz.fill", tint: OrbitWatchPalette.amber) {
                        await vm.sendPowerAction("sleep")
                    }
                    actionTile("Lock PC", icon: "lock.fill", tint: OrbitWatchPalette.accent) {
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
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                LazyVGrid(columns: columns, spacing: 6) {
                    actionTile("Desktop", icon: "menubar.dock.rectangle", tint: OrbitWatchPalette.accent) {
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
                    actionTile("Extend", icon: "display.2", tint: .indigo) {
                        await vm.sendPowerAction("restore_display")
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
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
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .foregroundStyle(OrbitWatchPalette.accent)
                    Text(vm.motionMode.rawValue)
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    Button {
                        cycleMode()
                    } label: {
                        Text("Mode")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(OrbitWatchPalette.accent.opacity(0.20), in: Capsule())
                            .foregroundStyle(OrbitWatchPalette.accent)
                    }
                    .buttonStyle(.plain)
                }

                // Radar / Trackpad Arena with live Wrist Motion Crosshair + Crown Scroll
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    vm.isMotionCursorActive ? OrbitWatchPalette.accent : Color.white.opacity(0.14),
                                    lineWidth: vm.isMotionCursorActive ? 1.4 : 0.8
                                )
                        )

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
                        .fill(vm.isMotionCursorActive ? OrbitWatchPalette.accent : Color.white.opacity(0.45))
                        .frame(width: 14, height: 14)
                        .shadow(color: vm.isMotionCursorActive ? OrbitWatchPalette.accent.opacity(0.8) : .clear, radius: 6)
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
                            .padding(.vertical, 6)
                            .background(
                                (vm.isMotionCursorActive ? OrbitWatchPalette.mint : OrbitWatchPalette.accent).opacity(0.24),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .foregroundStyle(vm.isMotionCursorActive ? OrbitWatchPalette.mint : OrbitWatchPalette.accent)
                        }
                        .buttonStyle(.plain)

                        Button {
                            vm.calibrateWristCenter()
                        } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 32, height: 28)
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
                            Image(systemName: vm.isDragLocked ? "lock.fill" : "hand.Point.up.left.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Drag")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            vm.isDragLocked ? OrbitWatchPalette.amber.opacity(0.28) : OrbitWatchPalette.cardBackground,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
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
                                    abs(vm.sensitivity - value) < 0.15 ? OrbitWatchPalette.accent.opacity(0.26) : Color.white.opacity(0.07),
                                    in: Capsule()
                                )
                                .foregroundStyle(abs(vm.sensitivity - value) < 0.15 ? OrbitWatchPalette.accent : .white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
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
                // Digital Crown Volume Card
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Crown Volume", systemImage: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(OrbitWatchPalette.accent)
                        Spacer()
                        Text(vm.isMuted ? "Muted" : "\(Int(crownVolume.rounded()))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(vm.isMuted ? OrbitWatchPalette.coral : .white)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(OrbitWatchPalette.accent.gradient)
                                .frame(width: max(4, geo.size.width * (crownVolume / 100.0)))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(8)
                .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                    mediaButton("playpause.fill", tint: OrbitWatchPalette.accent) { await vm.sendPowerAction("media_play_pause") }
                    mediaButton("forward.end.fill") { await vm.sendPowerAction("media_next") }
                    mediaButton(vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: vm.isMuted ? OrbitWatchPalette.coral : .white) {
                        await vm.sendPowerAction("mute")
                    }
                }

                if !vm.games.isEmpty {
                    Text("SUNSHINE GAMES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    ForEach(vm.games.prefix(8)) { game in
                        Button {
                            vm.launchGame(game)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(OrbitWatchPalette.mint)
                                Text(game.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func mediaButton(_ icon: String, tint: Color = .white, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
