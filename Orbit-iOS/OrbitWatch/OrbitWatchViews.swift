import SwiftUI
import WatchKit

/// Noir palette: black, one accent; amber and coral are reserved for warnings.
enum OrbitWatchPalette {
    static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let purple = accent
    static let mint = accent
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.48)
    static let cardBackground = Color.white.opacity(0.09)
}

/// Asks for the Windows password and hands it to the iPhone, which types it through the stream.
struct WatchUnlockSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to \(vm.pcName)")
                    .font(.headline)
                SecureField("Windows password", text: $password)
                Text("Typed on the PC's sign-in screen through your iPhone and the encrypted stream. Not saved anywhere.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WatchActionButton(title: vm.isUnlocking ? "Signing in…" : "Unlock", symbol: "lock.open.fill", tint: OrbitWatchPalette.mint, prominent: true, enabled: !password.isEmpty && !vm.isUnlocking) {
                    let typed = password
                    password = ""
                    Task {
                        await vm.unlockPC(password: typed)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Unlock PC")
    }
}

struct OrbitWatchRootView: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            WatchCockpitPage(vm: vm).tag(0)
            WatchPowerDeckPage(vm: vm).tag(1)
            WatchDeckPage(vm: vm, deck: vm.deck).tag(WatchDeckStore.tab)
            WatchPresentPage(vm: vm, store: vm.presentation).tag(WatchPresentationStore.tab)
            WatchMotionCursorPage(vm: vm).tag(2)
            WatchMediaAndGamesPage(vm: vm).tag(3)
        }
        // Horizontal paging leaves the Digital Crown available to scroll each page.
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .background(Color.black)
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab != 2 { vm.stopMotionCursor() }
        }
    }
}

// MARK: - Shared watch components

struct WatchPageHeading: View {
    let title: String
    let symbol: String
    var tint: Color = OrbitWatchPalette.accent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            Text(title)
                .font(.headline.weight(.bold))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(.top, 2)
    }
}

struct WatchConnectionLine: View {
    @ObservedObject var vm: OrbitWatchViewModel
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 3) {
                if !compact {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.isTelemetryFresh ? OrbitWatchPalette.mint : OrbitWatchPalette.amber)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(vm.pcName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 4) {
                    if compact {
                        Circle()
                            .fill(vm.isTelemetryFresh ? OrbitWatchPalette.mint : OrbitWatchPalette.amber)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                    Text(freshness(at: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if vm.isTelemetryFresh && vm.pingMs > 0 {
                        Text("· \(vm.pingMs) ms")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func freshness(at date: Date) -> String {
        guard let updated = vm.lastTelemetryAt else {
            return vm.hasDirectCredentials ? "Waiting for PC" : "Sync with iPhone"
        }
        let elapsed = max(0, Int(date.timeIntervalSince(updated)))
        if vm.isTelemetryFresh { return "Live" }
        if elapsed < 60 { return "Updated \(elapsed)s ago" }
        if elapsed < 3600 { return "Updated \(elapsed / 60)m ago" }
        return "Updated \(elapsed / 3600)h ago"
    }
}

struct WatchFeedback: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

struct WatchActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = OrbitWatchPalette.accent
    var prominent = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(enabled ? tint : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                prominent ? tint.opacity(enabled ? 0.20 : 0.05) : OrbitWatchPalette.cardBackground,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

struct WatchSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 7)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WatchOfflineHint: View {
    @ObservedObject var vm: OrbitWatchViewModel

    var body: some View {
        if !vm.isOnline {
            Label(
                vm.hasDirectCredentials ? "Wake your PC or check its connection." : "Pair your PC in Orbit on iPhone, then open both apps to sync.",
                systemImage: vm.hasDirectCredentials ? "wifi.exclamationmark" : "iphone.and.arrow.forward"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Overview

private struct WatchCockpitPage: View {
    @State private var showUnlock = false
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showPCSwitcher = false

    private var hasReadings: Bool { vm.isTelemetryFresh && vm.telemetryAvailable }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 7), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                WatchConnectionLine(vm: vm, compact: true)

                if !vm.hasDirectCredentials && vm.savedPCs.isEmpty {
                    pairingCard
                } else {
                    if let game = vm.activeGame, !game.isEmpty, hasReadings {
                        gameCard(game)
                    }

                    LazyVGrid(columns: columns, spacing: 7) {
                        metricTile("CPU", symbol: "cpu", value: hasReadings ? "\(Int(vm.cpuUsage.rounded()))%" : "—", detail: temperature(vm.cpuTemp), progress: hasReadings ? vm.cpuUsage / 100 : nil, tint: OrbitWatchPalette.accent)
                        metricTile("GPU", symbol: "rectangle.3.group", value: percentage(vm.gpuUsage), detail: temperature(vm.gpuTemp), progress: hasReadings ? vm.gpuUsage.map { $0 / 100 } : nil, tint: OrbitWatchPalette.purple)
                        metricTile("RAM", symbol: "memorychip", value: hasReadings ? "\(Int(vm.ramUsagePercent.rounded()))%" : "—", detail: hasReadings && vm.ramTotalGB > 0 ? String(format: "%.1f / %.0f GB", vm.ramUsedGB, vm.ramTotalGB) : "Memory", progress: hasReadings ? vm.ramUsagePercent / 100 : nil, tint: OrbitWatchPalette.mint)
                        metricTile("Power", symbol: "bolt.fill", value: componentPower, detail: powerDetail, progress: nil, tint: OrbitWatchPalette.amber)
                    }

                    if vm.isOnline && !vm.telemetryAvailable {
                        Text("PC connected. Monitoring data is not available yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WatchOfflineHint(vm: vm)

                    WatchActionButton(title: vm.isOnline ? "Control your PC" : (vm.isWaking ? "Waking PC…" : "Wake PC"), symbol: vm.isOnline ? "cursorarrow.motionlines" : "power", tint: vm.isOnline ? OrbitWatchPalette.accent : OrbitWatchPalette.mint, prominent: true, enabled: !vm.isWaking) {
                        if vm.isOnline { vm.selectedTab = 2 }
                        else { Task { await vm.wakePC() } }
                    }
                    if vm.isOnline && vm.sessionLocked {
                        WatchActionButton(title: vm.isUnlocking ? "Signing in…" : "Unlock PC", symbol: "lock.open.fill", tint: OrbitWatchPalette.mint, prominent: true, enabled: !vm.isUnlocking && vm.isPhoneReachable) {
                            showUnlock = true
                        }
                        .sheet(isPresented: $showUnlock) { WatchUnlockSheet(vm: vm) }
                    }
                }

                WatchSectionLabel(title: "Quick access")
                HStack(spacing: 7) {
                    quickLink("System", symbol: "power", tab: 1, tint: OrbitWatchPalette.mint)
                    quickLink("Audio", symbol: "speaker.wave.2.fill", tab: 3, tint: OrbitWatchPalette.purple)
                }

                WatchActionButton(title: vm.isLiveActivityActive ? "Stop Live Activity" : "Start Live Activity", symbol: "waveform.path", tint: vm.isLiveActivityActive ? OrbitWatchPalette.mint : OrbitWatchPalette.accent, enabled: vm.isPhoneReachable) {
                    vm.togglePhoneLiveActivity()
                }
                Text("Live Activity on your iPhone. Keep Orbit open there to refresh readings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WatchFeedback(message: vm.statusMessage)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showPCSwitcher) { pcSwitcher }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Button { showPCSwitcher = true } label: {
                HStack(spacing: 5) {
                    Text(vm.pcName)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(OrbitWatchPalette.accent)
                }
                .frame(minHeight: 34, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose PC. Current PC: \(vm.pcName)")
            Spacer(minLength: 0)
            Button { Task { await vm.refreshTelemetry() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(OrbitWatchPalette.cardBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh PC readings")
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.title2)
                .foregroundStyle(OrbitWatchPalette.accent)
            Text("Your PC. On your wrist.")
                .font(.headline)
            Text("Pair your Windows PC in Orbit on iPhone. Open both apps nearby to bring your PCs to Apple Watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WatchActionButton(title: "Sync from iPhone", symbol: "arrow.triangle.2.circlepath", prominent: true) {
                vm.requestSyncFromPhone()
            }
        }
        .padding(11)
        .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private var pcSwitcher: some View {
        NavigationStack {
            List {
                if vm.savedPCs.isEmpty {
                    Text("Pair and save PCs in Orbit on iPhone, then sync them to your watch.")
                        .font(.footnote)
                }
                ForEach(vm.savedPCs) { pc in
                    Button {
                        vm.selectPC(pc)
                        showPCSwitcher = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(OrbitWatchPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pc.name).font(.footnote.weight(.semibold))
                                Text(pc.address).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if pc.id == vm.selectedPCID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(OrbitWatchPalette.mint)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button("Sync from iPhone") { vm.requestSyncFromPhone() }
            }
            .navigationTitle("Your PCs")
        }
    }

    private func gameCard(_ game: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("NOW PLAYING", systemImage: "gamecontroller.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OrbitWatchPalette.mint)
            Text(game)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let fps = vm.fps, fps > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(fps.rounded()))").font(.title2.weight(.bold)).monospacedDigit()
                    Text("FPS").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitWatchPalette.mint.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
    }

    private func quickLink(_ title: String, symbol: String, tab: Int, tint: Color) -> some View {
        Button { vm.selectedTab = tab } label: {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func metricTile(_ title: String, symbol: String, value: String, detail: String, progress: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            Text(value)
                .font(.system(.title3).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                GeometryReader { geometry in
                    Capsule().fill(Color.white.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint)
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .padding(9)
        .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func percentage(_ value: Double?) -> String {
        guard hasReadings, let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func temperature(_ value: Double?) -> String {
        guard hasReadings, let value else { return "Temperature —" }
        return "\(Int(value.rounded()))°C"
    }

    private var componentPower: String {
        guard hasReadings, vm.cpuPowerWatts != nil || vm.gpuPowerWatts != nil else { return "—" }
        return "\(Int(((vm.cpuPowerWatts ?? 0) + (vm.gpuPowerWatts ?? 0)).rounded())) W"
    }

    private var powerDetail: String {
        guard hasReadings else { return "Component power" }
        if vm.cpuPowerWatts != nil && vm.gpuPowerWatts != nil { return "CPU + GPU" }
        if vm.cpuPowerWatts != nil { return "CPU only" }
        if vm.gpuPowerWatts != nil { return "GPU only" }
        return "Sensor unavailable"
    }
}

// MARK: - Power and desktop shortcuts

private struct WatchPowerDeckPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var confirmAction: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var controlsEnabled: Bool { vm.canControlPC }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 7), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                WatchPageHeading(title: "System", symbol: "power", tint: OrbitWatchPalette.mint)
                WatchConnectionLine(vm: vm)
                WatchOfflineHint(vm: vm)
                WatchActionButton(title: vm.isWaking ? "Waking PC…" : "Wake PC", symbol: "power", tint: OrbitWatchPalette.mint, prominent: true, enabled: !vm.isWaking && (!vm.macAddress.isEmpty || vm.isPhoneReachable)) {
                    Task { await vm.wakePC() }
                }
                LazyVGrid(columns: columns, spacing: 7) {
                    systemTile("Lock", symbol: "lock.fill", tint: OrbitWatchPalette.accent) { send("lock") }
                    systemTile("Sleep", symbol: "moon.fill", tint: OrbitWatchPalette.purple) { confirmAction = "sleep" }
                }

                WatchSectionLabel(title: "Desktop")
                WatchActionButton(title: "Show desktop", symbol: "menubar.dock.rectangle", enabled: controlsEnabled) { send("show_desktop") }
                WatchActionButton(title: "Switch app", symbol: "macwindow.on.rectangle", enabled: controlsEnabled) { send("alt_tab") }
                WatchActionButton(title: "Task View", symbol: "rectangle.3.group", tint: OrbitWatchPalette.purple, enabled: controlsEnabled) { send("task_view") }
                WatchActionButton(title: "Take screenshot", symbol: "camera.viewfinder", tint: OrbitWatchPalette.mint, enabled: controlsEnabled) { send("screenshot") }

                WatchSectionLabel(title: "Display")
                WatchActionButton(title: "Toggle HDR", symbol: "sun.max.fill", tint: OrbitWatchPalette.amber, enabled: controlsEnabled) { send("toggle_hdr") }
                WatchActionButton(title: "Extend displays", symbol: "display.2", tint: OrbitWatchPalette.purple, enabled: controlsEnabled) { send("restore_display") }

                WatchSectionLabel(title: "Power controls")
                WatchActionButton(title: "Quit current game", symbol: "xmark.app", tint: OrbitWatchPalette.coral, enabled: controlsEnabled && vm.activeGame != nil) { confirmAction = "kill_game" }
                WatchActionButton(title: "Restart PC", symbol: "arrow.clockwise", tint: OrbitWatchPalette.amber, enabled: controlsEnabled) { confirmAction = "restart" }
                WatchActionButton(title: "Shut down PC", symbol: "power.circle.fill", tint: OrbitWatchPalette.coral, enabled: controlsEnabled) { confirmAction = "shutdown" }
                WatchFeedback(message: vm.statusMessage)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 22)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
            if let action = confirmAction {
                Button(confirmationButton(action), role: action == "sleep" ? nil : .destructive) {
                    confirmAction = nil
                    send(action)
                }
            }
            Button("Cancel", role: .cancel) { confirmAction = nil }
        } message: {
            Text(confirmAction == "kill_game" ? "Unsaved game progress may be lost." : "This affects \(vm.pcName). Save your work first.")
        }
    }

    private func send(_ action: String) { Task { await vm.sendPowerAction(action) } }

    private func systemTile(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3).foregroundStyle(controlsEnabled ? tint : .secondary)
                Text(title).font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 5)
            .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
    }

    private var confirmationTitle: String {
        switch confirmAction {
        case "sleep": "Put your PC to sleep?"
        case "restart": "Restart your PC?"
        case "kill_game": "Quit the current game?"
        default: "Shut down your PC?"
        }
    }

    private func confirmationButton(_ action: String) -> String {
        switch action {
        case "sleep": "Sleep PC"
        case "restart": "Restart PC"
        case "kill_game": "Quit Game"
        default: "Shut Down PC"
        }
    }
}

// MARK: - Air Mouse and touchpad

private struct WatchMotionCursorPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var lastTouchPoint: CGPoint?
    @State private var showModes = false
    @State private var showSettings = false
    @State private var crownScrolling = false
    @FocusState private var isCrownFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var controlsEnabled: Bool { vm.canControlPC }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 7), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                WatchPageHeading(title: "Air Mouse", symbol: "cursorarrow.motionlines")
                WatchConnectionLine(vm: vm)
                WatchOfflineHint(vm: vm)

                Button { showModes = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: vm.motionMode.symbol).foregroundStyle(OrbitWatchPalette.accent)
                        Text(vm.motionMode.rawValue).font(.footnote.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cursor mode: \(vm.motionMode.rawValue). Choose mode")

                if vm.motionMode != .touchPad {
                    WatchActionButton(title: vm.isMotionCursorActive ? "Pause motion" : "Start motion", symbol: vm.isMotionCursorActive ? "pause.fill" : "gyroscope", tint: vm.isMotionCursorActive ? OrbitWatchPalette.amber : OrbitWatchPalette.accent, prominent: true, enabled: (controlsEnabled && vm.isMotionAvailable) || vm.isMotionCursorActive) {
                        vm.toggleMotionCursor()
                    }
                }

                if vm.motionMode != .touchPad && !vm.isMotionAvailable {
                    Text("Wrist sensors are unavailable. Choose Touchpad to control your PC.")
                        .font(.caption2)
                        .foregroundStyle(OrbitWatchPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                cursorTransportStatus
                cursorPad

                if vm.isMotionCursorActive {
                    WatchActionButton(title: "Recenter wrist", symbol: "scope", tint: OrbitWatchPalette.mint) {
                        vm.calibrateWristCenter()
                    }
                    Text("Hold your wrist comfortably, then recenter.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: columns, spacing: 7) {
                    mouseButton("Left click", symbol: "cursorarrow.click") { vm.sendCursorPacket(click: "left") }
                    mouseButton("Right click", symbol: "cursorarrow.and.square.on.square.dashed") { vm.sendCursorPacket(click: "right") }
                    mouseButton("Double click", symbol: "cursorarrow.click.2") { vm.sendCursorPacket(click: "double") }
                    mouseButton(vm.isDragLocked ? "Release drag" : "Hold to drag", symbol: vm.isDragLocked ? "hand.raised.fill" : "hand.point.up.left.fill", tint: vm.isDragLocked ? OrbitWatchPalette.amber : .white) { vm.toggleDragLock() }
                }
                if vm.isDragLocked {
                    Label("Mouse button held. Tap Release drag when done.", systemImage: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(OrbitWatchPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WatchActionButton(title: crownScrolling ? "Done scrolling" : "Scroll with Crown", symbol: "digitalcrown.horizontal.arrow.counterclockwise", tint: crownScrolling ? OrbitWatchPalette.mint : OrbitWatchPalette.accent, enabled: controlsEnabled) {
                    vm.resetCrownScroll()
                    crownScrolling.toggle()
                    isCrownFocused = crownScrolling
                }
                if crownScrolling {
                    Text("Turn the Digital Crown to scroll your PC. Tap Done to scroll this page again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WatchActionButton(title: "Speed & help", symbol: "slider.horizontal.3", enabled: true) { showSettings = true }
                WatchFeedback(message: vm.statusMessage)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showModes) { modePicker }
        .sheet(isPresented: $showSettings) { cursorSettings }
        .onDisappear {
            lastTouchPoint = nil
            crownScrolling = false
            isCrownFocused = false
            vm.stopMotionCursor()
        }
        .onChange(of: vm.selectedTab) { _, newValue in
            if newValue != 2 {
                crownScrolling = false
                isCrownFocused = false
                lastTouchPoint = nil
            }
        }
        .onChange(of: controlsEnabled) { _, enabled in
            if !enabled {
                crownScrolling = false
                isCrownFocused = false
                lastTouchPoint = nil
            }
        }
    }

    private var cursorTransportStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if vm.isCursorSending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(OrbitWatchPalette.accent)
                }
                Text(vm.cursorRouteLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OrbitWatchPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(vm.cursorStatusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var cursorPad: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OrbitWatchPalette.accent.opacity(vm.isMotionCursorActive ? 0.10 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(controlsEnabled ? OrbitWatchPalette.accent.opacity(0.38) : Color.white.opacity(0.10), lineWidth: 1)
                    }
                Path { path in
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    path.move(to: CGPoint(x: center.x, y: 14))
                    path.addLine(to: CGPoint(x: center.x, y: geometry.size.height - 14))
                    path.move(to: CGPoint(x: 14, y: center.y))
                    path.addLine(to: CGPoint(x: geometry.size.width - 14, y: center.y))
                }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                Circle()
                    .strokeBorder(OrbitWatchPalette.accent.opacity(0.20), lineWidth: 1)
                    .frame(width: 36, height: 36)
                Image(systemName: vm.isMotionCursorActive ? "cursorarrow" : "hand.draw.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(controlsEnabled ? OrbitWatchPalette.accent : .secondary)
                    .offset(vm.isMotionCursorActive ? vm.cursorIndicatorOffset : .zero)
                    .accessibilityHidden(true)
                VStack {
                    HStack(spacing: 4) {
                        Circle().fill(vm.isMotionCursorActive ? OrbitWatchPalette.mint : Color.gray).frame(width: 4, height: 4)
                        Text(vm.isMotionCursorActive ? "MOTION ON" : "TOUCHPAD")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    Text("Swipe to move · Tap to click")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard controlsEnabled else { return }
                    if let last = lastTouchPoint {
                        let dx = Int(((value.location.x - last.x) * 2.4 * vm.sensitivity).rounded())
                        let dy = Int(((value.location.y - last.y) * 2.4 * vm.sensitivity).rounded())
                        if dx != 0 || dy != 0 { vm.sendCursorPacket(dx: dx, dy: dy) }
                    }
                    lastTouchPoint = value.location
                }
                .onEnded { _ in lastTouchPoint = nil }
            )
            .simultaneousGesture(TapGesture().onEnded {
                if controlsEnabled { vm.sendCursorPacket(click: "left") }
            })
            .focusable(crownScrolling)
            .focused($isCrownFocused)
            .digitalCrownRotation($vm.crownScrollAccumulator, from: -1000, through: 1000, by: 0.5, sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true)
            .onChange(of: vm.crownScrollAccumulator) { _, value in
                if crownScrolling && controlsEnabled { vm.handleCrownScrollChange(value) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PC touchpad")
            .accessibilityHint("Swipe to move the PC pointer. Tap to left click. Mouse buttons are below.")
            .accessibilityAction(named: "Left click") { if controlsEnabled { vm.sendCursorPacket(click: "left") } }
            .accessibilityAction(named: "Right click") { if controlsEnabled { vm.sendCursorPacket(click: "right") } }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 150 : 112)
    }

    private var modePicker: some View {
        NavigationStack {
            List {
                ForEach(WatchCursorMode.allCases) { mode in
                    Button {
                        vm.setCursorMode(mode)
                        WKInterfaceDevice.current().play(.click)
                        showModes = false
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Image(systemName: mode.symbol).foregroundStyle(OrbitWatchPalette.accent)
                                Text(mode.rawValue).font(.footnote.weight(.semibold))
                                Spacer(minLength: 0)
                                if mode == vm.motionMode {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OrbitWatchPalette.mint)
                                }
                            }
                            Text(mode.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Cursor mode")
        }
    }

    private var cursorSettings: some View {
        NavigationStack {
            List {
                Section("Pointer speed") {
                    ForEach([("Precise", 0.7), ("Balanced", 1.2), ("Fast", 1.8), ("Very fast", 2.5)], id: \.0) { label, value in
                        Button {
                            vm.sensitivity = value
                            WKInterfaceDevice.current().play(.click)
                        } label: {
                            HStack {
                                Text(label).font(.footnote)
                                Spacer(minLength: 0)
                                if abs(vm.sensitivity - value) < 0.15 {
                                    Image(systemName: "checkmark").foregroundStyle(OrbitWatchPalette.accent)
                                }
                            }
                            .frame(minHeight: 30)
                        }
                    }
                }
                Section("How to use") {
                    helpRow("1", title: "Connect", detail: "Keep your PC and Orbit Companion running. Your watch connects directly or through Orbit on iPhone.")
                    helpRow("2", title: "Find your center", detail: "Hold your wrist in a comfortable position. Start motion, then move your wrist gently. Recenter whenever you change position.")
                    helpRow("3", title: "Choose your style", detail: "Gyro Glide moves the pointer with wrist motion. Laser Pointer maps your wrist position to the screen. Touchpad works with screen swipes.")
                    helpRow("4", title: "Take a break", detail: "Pause motion before lowering your wrist. Leaving Air Mouse also pauses motion and releases drag.")
                }
            }
            .navigationTitle("Mouse settings")
        }
    }

    private func helpRow(_ number: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(number). \(title)").font(.footnote.weight(.semibold)).foregroundStyle(OrbitWatchPalette.accent)
            Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }

    private func mouseButton(_ title: String, symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(controlsEnabled ? tint : .secondary)
                Text(title).font(.caption2.weight(.semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(vm.isDragLocked && title == "Release drag" ? OrbitWatchPalette.amber.opacity(0.13) : OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled && !(vm.isDragLocked && title == "Release drag"))
    }
}

// MARK: - Audio, media, and game launching

private struct WatchMediaAndGamesPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @State private var crownVolume: Double = 40
    @State private var volumeControlActive = false
    @State private var showGames = false
    @FocusState private var isVolumeCrownFocused: Bool

    private var controlsEnabled: Bool { vm.canControlPC }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WatchPageHeading(title: "Audio", symbol: "speaker.wave.2.fill", tint: OrbitWatchPalette.purple)
                WatchConnectionLine(vm: vm)
                WatchOfflineHint(vm: vm)

                volumeCard
                HStack(spacing: 7) {
                    mediaButton("Previous track", symbol: "backward.end.fill") { await vm.sendPowerAction("media_prev") }
                    mediaButton("Play or pause", symbol: "playpause.fill", tint: OrbitWatchPalette.accent, prominent: true) { await vm.sendPowerAction("media_play_pause") }
                    mediaButton("Next track", symbol: "forward.end.fill") { await vm.sendPowerAction("media_next") }
                }
                WatchActionButton(title: vm.isMuted ? "Unmute PC" : "Mute PC", symbol: vm.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill", tint: vm.isMuted ? OrbitWatchPalette.amber : OrbitWatchPalette.purple, enabled: controlsEnabled) {
                    Task { await vm.sendPowerAction("mute") }
                }

                if let game = vm.activeGame, !game.isEmpty, vm.isOnline {
                    WatchSectionLabel(title: "Playing on PC")
                    Label(game, systemImage: "gamecontroller.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(OrbitWatchPalette.mint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OrbitWatchPalette.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }
                WatchActionButton(title: "PC game library", symbol: "gamecontroller.fill", tint: OrbitWatchPalette.mint, enabled: !vm.games.isEmpty) { showGames = true }
                Text(vm.games.isEmpty ? "Configured Sunshine apps appear after syncing with Orbit on iPhone." : "Launch a configured Sunshine app on your PC.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WatchFeedback(message: vm.statusMessage)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showGames) { gameLibrary }
        .onAppear { crownVolume = vm.volume }
        .onChange(of: vm.volume) { _, value in
            if abs(crownVolume - value) >= 1 { crownVolume = value }
        }
        .onChange(of: vm.selectedTab) { _, value in
            if value != 3 { finishVolumeControl() }
        }
        .onChange(of: controlsEnabled) { _, enabled in
            if !enabled { finishVolumeControl() }
        }
        .onDisappear { finishVolumeControl() }
    }

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(vm.isMuted ? "Muted" : "PC volume")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(vm.isMuted ? OrbitWatchPalette.amber : .secondary)
                Spacer(minLength: 0)
                Image(systemName: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.footnote)
                    .foregroundStyle(OrbitWatchPalette.purple)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(controlsEnabled ? "\(Int(crownVolume.rounded()))" : "—")
                    .font(.system(.largeTitle).weight(.bold))
                    .monospacedDigit()
                Text("%").font(.footnote).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(OrbitWatchPalette.purple)
                            .frame(width: geometry.size.width * min(1, max(0, crownVolume / 100)))
                    }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            HStack(spacing: 7) {
                volumeStep("Decrease volume", symbol: "minus", amount: -5)
                volumeStep("Increase volume", symbol: "plus", amount: 5)
            }
            Button {
                volumeControlActive.toggle()
                isVolumeCrownFocused = volumeControlActive
            } label: {
                Label(volumeControlActive ? "Done adjusting" : "Adjust with Crown", systemImage: "digitalcrown.horizontal.arrow.counterclockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OrbitWatchPalette.purple)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .disabled(!controlsEnabled)
            if volumeControlActive {
                Text("Turn the Crown to change PC volume. Tap Done when finished.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(OrbitWatchPalette.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(OrbitWatchPalette.purple.opacity(volumeControlActive ? 0.5 : 0.10), lineWidth: 1)
        }
        .focusable(volumeControlActive)
        .focused($isVolumeCrownFocused)
        .digitalCrownRotation($crownVolume, from: 0, through: 100, by: 1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownVolume) { _, value in
            // Telemetry changes update the display without becoming another volume command.
            if volumeControlActive && controlsEnabled && abs(value - vm.volume) >= 1 { vm.setPCVolume(value) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PC volume")
        .accessibilityValue(controlsEnabled ? "\(Int(crownVolume.rounded())) percent" : "Unavailable")
    }

    private var gameLibrary: some View {
        NavigationStack {
            List(vm.games) { game in
                Button {
                    vm.launchGame(game)
                    showGames = false
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(OrbitWatchPalette.mint)
                        Text(game.title).font(.footnote.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
                .disabled(!controlsEnabled)
            }
            .navigationTitle("PC games")
        }
    }

    private func finishVolumeControl() {
        volumeControlActive = false
        isVolumeCrownFocused = false
    }

    private func volumeStep(_ title: String, symbol: String, amount: Double) -> some View {
        Button {
            let value = min(100, max(0, vm.volume + amount))
            crownVolume = value
            vm.setPCVolume(value)
            WKInterfaceDevice.current().play(.click)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .accessibilityLabel(title)
    }

    private func mediaButton(_ title: String, symbol: String, tint: Color = .white, prominent: Bool = false, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(controlsEnabled ? tint : .secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(prominent ? tint.opacity(0.18) : OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
        .accessibilityLabel(title)
    }
}
