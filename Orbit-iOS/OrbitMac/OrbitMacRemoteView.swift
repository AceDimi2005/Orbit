import AppKit
import SwiftUI

// MARK: - Remote control page

/// Remote control: a pointer-capturing trackpad surface plus keyboard, media,
/// quick-action and gamepad cards. Cursor packets go through the view model's
/// coalesced `/ws/input` path; keys, gamepad buttons and actions use HTTP.
struct MacRemoteView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.pointerSpeed") private var pointerSpeed: Double = 1.4
    @State private var captureEnabled = false
    @State private var isCapturing = false
    @State private var isHovering = false
    @State private var typedText = ""
    @State private var inputNote: String?

    private var isUnpaired: Bool { vm.currentPC == nil && !vm.isDemoMode }
    private var isReady: Bool { vm.metrics.isOnline || vm.isDemoMode }
    private var isLive: Bool { vm.metrics.isOnline && !vm.isDemoMode }
    private var isConnecting: Bool { !isReady && !isUnpaired && vm.lastUpdated == nil && vm.connectionError == nil }
    private var hasActiveGame: Bool { !(vm.metrics.activeGame ?? "").isEmpty }
    private var canSendText: Bool { !typedText.isEmpty && typedText.count <= 1000 }

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                if vm.isDemoMode { demoNotice }
                heroRow
                if let error = vm.connectionError, !isReady, !isUnpaired {
                    MacNotice(title: "Connection problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                if isUnpaired {
                    unpairedCard
                } else {
                    controlColumns
                }
            }
        }
        .task { await vm.refreshMetrics() }
        .onChange(of: vm.selectedPCID) { _, _ in
            releaseCapture()
            typedText = ""
            inputNote = nil
            Task { await vm.refreshMetrics() }
        }
        .onChange(of: vm.metrics.isOnline) { _, online in
            if !online { releaseCapture() }
        }
        .onDisappear {
            releaseCapture()
            vm.closeInputSocket()
        }
    }

    // MARK: Hero




    /// One line: what this page does, or that the pointer is captured and how to let go.
    private var heroRow: some View {
        HStack(spacing: 12) {
            if isCapturing {
                Label("The pointer is captured. Press Esc to release it.", systemImage: "cursorarrow.rays")
                    .foregroundStyle(OrbitPalette.warm)
            } else {
                Text(isReady ? "Use this Mac's trackpad and keyboard on \(vm.selectedPCName)." : remoteUnavailableText)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                vm.selectedSection = .preview
            } label: {
                Label("Watch the Screen", systemImage: "display")
            }
            .buttonStyle(MacHoverButtonStyle())
            .help("See the PC's screen while you control it")
        }
        .font(.body)
    }

    private var remoteUnavailableText: String {
        if vm.isDemoMode { return "The demo doesn't send input anywhere." }
        if vm.currentPC == nil { return "Pair a PC to control it from here." }
        if isConnecting { return "Connecting…" }
        return "\(vm.selectedPCName) is asleep or off."
    }



    private var demoNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo mode · pointer, keyboard and gamepad input is not sent anywhere; media and quick actions only update the simulated status")
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Spacer()
            Button("Pair a PC") { vm.setDemoMode(false); vm.selectedSection = .pcs }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .orange)
    }

    private var unpairedCard: some View {
        MacEmptyState(
            icon: "computermouse.fill",
            title: "Pair your PC to use remote control",
            message: "Pair your PC, or use the one you added on your iPhone. The trackpad, keyboard and media controls appear here once it's connected.",
            tint: theme.accent,
            actionTitle: "Pair or import a PC"
        ) { vm.selectedSection = .pcs }
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    // MARK: Columns

    private var controlColumns: some View {
        HStack(alignment: .top, spacing: 14) {
            trackpadColumn.frame(maxWidth: .infinity)
            sideColumn.frame(width: 340)
        }
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.35)
        .overlay {
            if !isReady { offlineOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: isReady)
    }

    private var offlineOverlay: some View {
        let name = vm.currentPC?.name ?? "PC"
        let canWake = !(vm.currentPC?.macAddress.isEmpty ?? true)
        return VStack(spacing: 0) {
            if isConnecting || vm.isWaking {
                ProgressView().controlSize(.regular).padding(.top, 28)
                Text(vm.isWaking ? "Waking \(name)…" : "Connecting to \(name)…")
                    .font(.headline.weight(.bold))
                    .padding(.top, 12)
                Text("The controls appear as soon as the PC answers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
            } else {
                MacEmptyState(
                    icon: "wifi.slash",
                    title: "\(name) is offline",
                    message: vm.connectionError ?? "Remote needs the PC to be connected.",
                    tint: .orange,
                    actionTitle: canWake ? "Power On" : "Retry"
                ) {
                    Task {
                        if canWake { await vm.wakePC() } else { await vm.refreshMetrics() }
                    }
                }
            }
        }
        .frame(maxWidth: 460)
        .macGlass(cornerRadius: 22, tint: .orange, elevated: true)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sideColumn: some View {
        VStack(spacing: 14) {
            keyboardCard
            mediaCard
            quickActionsCard
            gamepadCard
        }
    }

    // MARK: Trackpad

    private var trackpadSubtitle: String {
        if isCapturing { return "The pointer and keys go to the PC. Press Esc to let go." }
        if captureEnabled { return "Move into the pad to hand the pointer to the PC" }
        if vm.isDemoMode { return "The demo doesn't move a real pointer" }
        return "Move the PC's pointer from here"
    }

    private var trackpadColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Trackpad", subtitle: trackpadSubtitle, icon: "hand.point.up.left.fill") {
                HStack(spacing: 10) {
                    if captureEnabled {
                        Button {
                            releaseCapture()
                        } label: {
                            Label("Release", systemImage: "escape")
                        }
                        .buttonStyle(MacHoverButtonStyle(tint: .orange))
                        .help("Release the pointer (⎋)")
                    }
                    Toggle("Capture pointer", isOn: $captureEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(.caption, weight: .semibold))
                        .disabled(!isLive)
                        .help(isLive ? "Lock the Mac pointer inside the pad and forward keystrokes · press ⎋ to release" : "Available when a real PC is connected")
                }
            }
            trackpadSurface
            mouseBar
        }
    }

    private var trackpadSurface: some View {
        ZStack {
            surfaceBackdrop
            MacRemoteTrackpadSurface(
                vm: vm,
                pointerSpeed: pointerSpeed,
                enabled: isReady,
                captureEnabled: $captureEnabled,
                isCapturing: $isCapturing,
                isHovering: $isHovering
            )
            .accessibilityLabel("Remote trackpad")
            .accessibilityHint("Move the pointer here to move the PC cursor. Click for a left click, right-click for a right click, scroll to scroll.")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
    }

    private var pointerStateText: String {
        if isCapturing { return "Captured" }
        if isHovering { return "On pad" }
        return "Free"
    }

    private var surfaceBackdrop: some View {
        let tint: Color = isCapturing ? .orange : theme.accent
        return ZStack {
            Color.clear
                .macGlass(cornerRadius: 22, tint: tint, elevated: true, hovered: isHovering || isCapturing)
            MacRemoteDotGrid(tint: tint)
                .padding(2)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            surfaceHint(tint: tint)
            VStack {
                HStack {
                    MacStatusPill(text: pointerStateText, tint: tint, pulsing: isCapturing, icon: isCapturing ? "cursorarrow.rays" : nil)
                    Spacer()
                    MacStatChip(label: "Speed", value: "\(MacFormat.decimal(pointerSpeed, digits: 1))×", icon: "gauge.with.needle")
                }
                Spacer()
            }
            .padding(14)
        }
        .allowsHitTesting(false)
    }

    private var hintDetail: String {
        if isCapturing { return "Keystrokes are forwarded to the PC · press ⎋ to release the pointer" }
        if captureEnabled { return "Capture is armed · enter the pad to lock the pointer" }
        if vm.isDemoMode { return "Pointer packets are not sent in demo mode" }
        return "Click, right-click, drag and scroll like a laptop trackpad"
    }

    private func surfaceHint(tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: isCapturing ? "cursorarrow.rays" : "cursorarrow.motionlines")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
            Text(isCapturing ? "Pointer captured" : (vm.isDemoMode ? "Demo trackpad" : "Move here to control the PC pointer"))
                .font(.system(.headline, weight: .bold))
            Text(hintDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .opacity(isHovering && !isCapturing ? 0.3 : 0.9)
        .animation(.easeOut(duration: 0.2), value: isHovering)
    }

    private var mouseBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(MacRemoteMouseButton.all) { button in
                    Button {
                        click(button.id)
                    } label: {
                        Label(button.title, systemImage: button.icon)
                    }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                    .help("\(button.title) click")
                }
                Spacer(minLength: 12)
                Image(systemName: "tortoise.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $pointerSpeed, in: 0.5...3.0, step: 0.1)
                    .frame(width: 140)
                    .help("Pointer speed")
                    .accessibilityLabel("Pointer speed")
                Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                Text("\(MacFormat.decimal(pointerSpeed, digits: 1))×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            Text("Move to point, click to click, scroll to scroll. Esc lets go of the pointer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .macGlass(cornerRadius: 16)
    }

    // MARK: Keyboard

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Keyboard", subtitle: inputNote ?? "Return sends the text to the PC", icon: "keyboard.fill")
            HStack(spacing: 8) {
                TextField("Type on your PC", text: $typedText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .onSubmit { sendTypedText() }
                Button {
                    sendTypedText()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(MacIconButtonStyle(tint: theme.accent, size: 32))
                .disabled(!canSendText)
                .help("Send text (Return)")
                .accessibilityLabel("Send text")
            }
            if typedText.count > 1000 {
                Text("Up to 1,000 characters at a time.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                ForEach(MacRemoteKeyChip.all) { chip in
                    Button {
                        sendKey(chip.id)
                    } label: {
                        Label(chip.title, systemImage: chip.icon)
                            .font(.system(.caption, weight: .semibold))
                    }
                    .buttonStyle(MacHoverButtonStyle())
                    .help("Send \(chip.title)")
                }
            }
        }
        .padding(16)
        .macGlass(cornerRadius: 18)
    }

    // MARK: Media

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Media", subtitle: "⌘⇧Space play/pause · ⌘⇧← → tracks", icon: "music.note")
            HStack(spacing: 8) {
                mediaButton("Previous track", icon: "backward.fill", action: "media_prev")
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                mediaButton("Play or pause", icon: "playpause.fill", action: "media_play_pause")
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
                mediaButton("Next track", icon: "forward.fill", action: "media_next")
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Spacer(minLength: 6)
                mediaButton("Volume down", icon: "speaker.minus.fill", action: "volume_down")
                Button {
                    Task { await vm.sendAction("mute") }
                } label: {
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(MacIconButtonStyle(tint: vm.metrics.isMuted ? .orange : .white, size: 34))
                .help(vm.metrics.isMuted ? "Unmute PC" : "Mute PC")
                .accessibilityLabel(vm.metrics.isMuted ? "Unmute" : "Mute")
                mediaButton("Volume up", icon: "speaker.plus.fill", action: "volume_up")
            }
            volumeRow
        }
        .padding(16)
        .macGlass(cornerRadius: 18)
    }

    private func mediaButton(_ title: String, icon: String, action: String) -> some View {
        Button {
            Task { await vm.sendAction(action) }
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(MacIconButtonStyle(size: 34))
        .help(title)
        .accessibilityLabel(title)
    }

    private var volumeRow: some View {
        let available = vm.metrics.volumeAvailable != false
        return HStack(spacing: 10) {
            Image(systemName: "speaker.wave.1.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100) { editing in
                vm.isDraggingVolume = editing
            }
            .disabled(!available)
            .accessibilityLabel("PC volume")
            Text(available ? MacFormat.percent(vm.metrics.volume) : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Quick actions

    private var quickActions: [MacRemoteQuickAction] {
        [
            MacRemoteQuickAction(id: "show_desktop", title: "Desktop", icon: "menubar.dock.rectangle", tint: theme.accent),
            MacRemoteQuickAction(id: "task_view", title: "Task View", icon: "rectangle.3.group", tint: theme.accent),
            MacRemoteQuickAction(id: "alt_tab", title: "Alt + Tab", icon: "rectangle.2.swap", tint: theme.accent),
            MacRemoteQuickAction(id: "screenshot", title: "Screenshot", icon: "camera.viewfinder", tint: .mint),
            MacRemoteQuickAction(id: "fullscreen", title: "Fullscreen", icon: "arrow.up.left.and.arrow.down.right", tint: .mint),
            MacRemoteQuickAction(id: "kill_game", title: "Quit Game", icon: "xmark.circle.fill", tint: .orange),
            MacRemoteQuickAction(id: "lock", title: "Lock", icon: "lock.fill", tint: theme.secondary),
            MacRemoteQuickAction(id: "toggle_hdr", title: "HDR", icon: "sun.max.fill", tint: .yellow),
            MacRemoteQuickAction(id: "sleep", title: "Sleep", icon: "moon.fill", tint: .indigo)
        ]
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Quick Actions", subtitle: hasActiveGame ? "Quit Game ends \(vm.metrics.activeGame ?? "the active game")" : "Sleep asks for confirmation", icon: "bolt.fill")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(quickActions) { item in
                    MacActionTile(title: item.title, icon: item.icon, tint: item.tint, isActive: item.id == "kill_game" && hasActiveGame) {
                        perform(item.id)
                    }
                    .disabled(item.id == "kill_game" && !hasActiveGame)
                }
            }
        }
        .padding(16)
        .macGlass(cornerRadius: 18)
    }

    // MARK: Gamepad

    private var gamepadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Gamepad", subtitle: "Buttons press W A S D, Space, Esc, E and R on the PC", icon: "gamecontroller.fill")
            HStack(alignment: .center, spacing: 0) {
                dpad
                Spacer(minLength: 12)
                faceButtons
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .macGlass(cornerRadius: 18)
    }

    private var dpad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 38, height: 38)
                padButton("UP", icon: "arrowtriangle.up.fill")
                Color.clear.frame(width: 38, height: 38)
            }
            GridRow {
                padButton("LEFT", icon: "arrowtriangle.left.fill")
                Circle().fill(.white.opacity(0.06)).frame(width: 38, height: 38)
                padButton("RIGHT", icon: "arrowtriangle.right.fill")
            }
            GridRow {
                Color.clear.frame(width: 38, height: 38)
                padButton("DOWN", icon: "arrowtriangle.down.fill")
                Color.clear.frame(width: 38, height: 38)
            }
        }
    }

    private var faceButtons: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 40, height: 40)
                faceButton("Y", tint: .yellow)
                Color.clear.frame(width: 40, height: 40)
            }
            GridRow {
                faceButton("X", tint: Color(red: 0.48, green: 0.72, blue: 1))
                Color.clear.frame(width: 40, height: 40)
                faceButton("B", tint: Color(red: 1.0, green: 0.45, blue: 0.48))
            }
            GridRow {
                Color.clear.frame(width: 40, height: 40)
                faceButton("A", tint: .mint)
                Color.clear.frame(width: 40, height: 40)
            }
        }
    }

    private func padButton(_ button: String, icon: String) -> some View {
        Button {
            gamepad(button)
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(MacIconButtonStyle(tint: theme.accent, size: 38))
        .help("D-pad \(button.capitalized)")
        .accessibilityLabel("D-pad \(button.capitalized)")
    }

    private func faceButton(_ button: String, tint: Color) -> some View {
        Button {
            gamepad(button)
        } label: {
            Text(button)
        }
        .buttonStyle(MacIconButtonStyle(tint: tint, size: 40))
        .help("Gamepad \(button)")
        .accessibilityLabel("Gamepad \(button)")
    }

    // MARK: Actions

    private func releaseCapture() {
        captureEnabled = false
        isCapturing = false
    }

    private func note(_ text: String) {
        inputNote = vm.isDemoMode ? "Demo mode · input is not sent to a PC" : text
    }

    private func click(_ button: String) {
        note("Sent \(button) click")
        Task { await vm.sendCursor(click: button) }
    }

    private func sendKey(_ key: String) {
        note("Sent \(key)")
        Task { await vm.sendKeyboard(key: key) }
    }

    private func sendTypedText() {
        guard canSendText else { return }
        let text = typedText
        typedText = ""
        note("Sent \(text.count) character\(text.count == 1 ? "" : "s")")
        Task { await vm.sendKeyboard(text: text) }
    }

    private func gamepad(_ button: String) {
        note("Sent gamepad \(button)")
        Task { await vm.sendGamepad(button) }
    }

    private func perform(_ action: String) {
        if action == "sleep" {
            NotificationCenter.default.post(name: .macConfirmPower, object: "sleep")
        } else {
            Task { await vm.sendAction(action) }
        }
    }
}

// MARK: - Static descriptors

private struct MacRemoteMouseButton: Identifiable {
    let id: String
    let title: String
    let icon: String
    static let all: [MacRemoteMouseButton] = [
        MacRemoteMouseButton(id: "left", title: "Left", icon: "computermouse.fill"),
        MacRemoteMouseButton(id: "middle", title: "Middle", icon: "scroll"),
        MacRemoteMouseButton(id: "right", title: "Right", icon: "contextualmenu.and.cursorarrow"),
        MacRemoteMouseButton(id: "double", title: "Double", icon: "cursorarrow.click.2")
    ]
}

private struct MacRemoteKeyChip: Identifiable {
    let id: String
    let title: String
    let icon: String
    static let all: [MacRemoteKeyChip] = [
        MacRemoteKeyChip(id: "ENTER", title: "Enter", icon: "return"),
        MacRemoteKeyChip(id: "BACKSPACE", title: "Backspace", icon: "delete.left"),
        MacRemoteKeyChip(id: "SPACE", title: "Space", icon: "space"),
        MacRemoteKeyChip(id: "ESC", title: "Esc", icon: "escape"),
        MacRemoteKeyChip(id: "TAB", title: "Tab", icon: "arrow.right.to.line"),
        MacRemoteKeyChip(id: "WIN", title: "Win", icon: "command")
    ]
}

private struct MacRemoteQuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
}

/// Subtle dot grid drawn under the trackpad surface.
private struct MacRemoteDotGrid: View {
    var tint: Color
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 26
            var x = spacing / 2
            while x < size.width {
                var y = spacing / 2
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(tint.opacity(0.10)))
                    y += spacing
                }
                x += spacing
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Trackpad surface (AppKit)

/// One batched cursor packet; consecutive movement-only packets are merged.
private struct MacRemotePacket {
    var dx = 0
    var dy = 0
    var scroll = 0
    var hscroll = 0
    var click = ""
    var drag = ""
    var isMovementOnly: Bool { click.isEmpty && drag.isEmpty }
}

private func macRemoteClamp(_ value: Int, _ limit: Int) -> Int { max(-limit, min(limit, value)) }

private struct MacRemoteTrackpadSurface: NSViewRepresentable {
    let vm: OrbitMacViewModel
    var pointerSpeed: Double
    var enabled: Bool
    @Binding var captureEnabled: Bool
    @Binding var isCapturing: Bool
    @Binding var isHovering: Bool

    @MainActor
    func makeNSView(context: Context) -> MacRemoteTrackpadView {
        let view = MacRemoteTrackpadView()
        configure(view)
        return view
    }

    @MainActor
    func updateNSView(_ view: MacRemoteTrackpadView, context: Context) {
        configure(view)
    }

    @MainActor
    static func dismantleNSView(_ view: MacRemoteTrackpadView, coordinator: ()) {
        view.endCapture(latch: false)
        view.viewModel = nil
    }

    @MainActor
    private func configure(_ view: MacRemoteTrackpadView) {
        view.viewModel = vm
        view.pointerSpeed = pointerSpeed
        view.onCaptureChange = { capturing in
            Task { @MainActor in
                isCapturing = capturing
                if !capturing { captureEnabled = false }
            }
        }
        view.onHoverChange = { hovering in
            Task { @MainActor in isHovering = hovering }
        }
        view.isEnabled = enabled
        view.captureEnabled = captureEnabled && enabled
    }
}

/// Transparent AppKit surface that turns local pointer, scroll and key events
/// into coalesced packets for the PC. All work happens on the main actor.
@MainActor
final class MacRemoteTrackpadView: NSView {
    weak var viewModel: OrbitMacViewModel?
    var pointerSpeed: Double = 1.4
    var onCaptureChange: ((Bool) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    var isEnabled = true {
        didSet { if !isEnabled { endCapture(latch: true) } }
    }

    /// Armed by the SwiftUI toggle; capture starts once the pointer is inside.
    var captureEnabled = false {
        didSet {
            if !captureEnabled {
                releaseLatch = false
                endCapture(latch: false)
            } else if !releaseLatch, pointerInside, isEnabled {
                beginCapture()
            }
        }
    }

    private(set) var isCapturing = false
    private var pointerInside = false
    private var cursorHidden = false
    /// After a user-initiated release, ignore a stale "armed" value until SwiftUI catches up.
    private var releaseLatch = false
    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    private var pendingDX: Double = 0
    private var pendingDY: Double = 0
    private var pendingScroll: Double = 0
    private var pendingHScroll: Double = 0
    private var flushTask: Task<Void, Never>?
    private var queue: [MacRemotePacket] = []
    private var worker: Task<Void, Never>?
    private var dragActive = false

    override var acceptsFirstResponder: Bool { true }

    deinit {
        flushTask?.cancel()
        worker?.cancel()
        let hidden = cursorHidden
        let capturing = isCapturing
        Task { @MainActor in
            if hidden { NSCursor.unhide() }
            if capturing { _ = CGAssociateMouseAndMouseCursorPosition(1) }
        }
    }

    // MARK: Lifecycle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endCapture(latch: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endCapture(latch: true) }
        }
    }

    override func removeFromSuperview() {
        endCapture(latch: false)
        super.removeFromSuperview()
    }

    // MARK: Capture

    func beginCapture() {
        guard !isCapturing, isEnabled, captureEnabled else { return }
        isCapturing = true
        _ = CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        window?.makeFirstResponder(self)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let swallow: Bool = MainActor.assumeIsolated {
                    guard let self, self.isCapturing, event.keyCode == 53 else { return false }
                    self.endCapture(latch: true)
                    return true
                }
                return swallow ? nil : event
            }
        }
        onCaptureChange?(true)
    }

    /// Restores the pointer. `latch` marks a release the SwiftUI toggle has not seen yet.
    func endCapture(latch: Bool) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        guard isCapturing else { return }
        isCapturing = false
        if latch { releaseLatch = true }
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        if dragActive {
            dragActive = false
            enqueue(MacRemotePacket(drag: "up"))
        }
        onCaptureChange?(false)
    }

    // MARK: Pointer events

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        onHoverChange?(true)
        if captureEnabled, isEnabled, !releaseLatch { beginCapture() }
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        onHoverChange?(false)
        pendingScroll = 0
        pendingHScroll = 0
    }

    override func mouseMoved(with event: NSEvent) { accumulate(event) }
    override func rightMouseDragged(with event: NSEvent) { accumulate(event) }
    override func otherMouseDragged(with event: NSEvent) { accumulate(event) }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        if !dragActive {
            dragActive = true
            flushMovementNow()
            enqueue(MacRemotePacket(drag: "down"))
        }
        accumulate(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        dragActive = false
        if captureEnabled, !releaseLatch { beginCapture() }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { super.mouseUp(with: event); return }
        flushMovementNow()
        if dragActive {
            dragActive = false
            enqueue(MacRemotePacket(drag: "up"))
        } else {
            // Each click is relayed as a single click; Windows coalesces two rapid
            // clicks into a double-click itself, so clickCount == 2 is not tripled.
            enqueue(MacRemotePacket(click: "left"))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { super.rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        flushMovementNow()
        enqueue(MacRemotePacket(click: "right"))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isEnabled, event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        flushMovementNow()
        enqueue(MacRemotePacket(click: "middle"))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, pointerInside || isCapturing else { super.scrollWheel(with: event); return }
        if event.hasPreciseScrollingDeltas {
            // Trackpads report points; roughly one wheel step per 14 pt.
            pendingScroll += event.scrollingDeltaY / 14
            pendingHScroll -= event.scrollingDeltaX / 14
        } else {
            // Wheels report whole lines. AppKit and Windows both treat positive as "up".
            pendingScroll += event.scrollingDeltaY.rounded(.awayFromZero)
            pendingHScroll -= event.scrollingDeltaX.rounded(.awayFromZero)
        }
        scheduleFlush()
    }

    // MARK: Keyboard (capture mode only)

    override func keyDown(with event: NSEvent) {
        guard isCapturing, isEnabled, let vm = viewModel, !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53:                       // Escape
            endCapture(latch: true)
        case 36, 76:                   // Return, keypad Enter
            Task { await vm.sendKeyboard(key: "ENTER") }
        case 51:                       // Delete
            Task { await vm.sendKeyboard(key: "BACKSPACE") }
        case 49:                       // Space
            Task { await vm.sendKeyboard(key: "SPACE") }
        case 48:                       // Tab
            Task { await vm.sendKeyboard(key: "TAB") }
        case 123, 124, 125, 126:       // Arrows: the agent has no arrow keys; absorbed locally
            break
        default:
            guard let text = event.characters, let scalar = text.unicodeScalars.first,
                  scalar.value >= 32, scalar.value != 127, !(0xF700...0xF8FF).contains(scalar.value) else { return }
            Task { await vm.sendKeyboard(text: text) }
        }
    }

    // MARK: Coalescing

    private func accumulate(_ event: NSEvent) {
        guard isEnabled, pointerInside || isCapturing else { return }
        pendingDX += event.deltaX * pointerSpeed
        pendingDY += event.deltaY * pointerSpeed
        scheduleFlush()
    }

    /// Flushes at most every ~16 ms so a fast pointer never produces one request per pixel.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            self.flushTask = nil
            self.flushMovementNow()
        }
    }

    private func flushMovementNow() {
        let dx = Int(pendingDX.rounded())
        let dy = Int(pendingDY.rounded())
        pendingDX -= Double(dx)
        pendingDY -= Double(dy)
        let scroll = Int(pendingScroll.rounded(.towardZero))
        let hscroll = Int(pendingHScroll.rounded(.towardZero))
        pendingScroll -= Double(scroll)
        pendingHScroll -= Double(hscroll)
        guard dx != 0 || dy != 0 || scroll != 0 || hscroll != 0 else { return }
        enqueue(MacRemotePacket(dx: dx, dy: dy, scroll: scroll, hscroll: hscroll))
    }

    /// Serial sender: preserves ordering (drag down → moves → drag up) and merges movement.
    private func enqueue(_ packet: MacRemotePacket) {
        guard viewModel != nil else { return }
        queue.append(packet)
        if queue.count > 256 { queue.removeFirst(queue.count - 256) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while true {
                guard let self, !self.queue.isEmpty else { break }
                var packet = self.queue.removeFirst()
                while packet.isMovementOnly, let next = self.queue.first, next.isMovementOnly {
                    packet.dx += next.dx
                    packet.dy += next.dy
                    packet.scroll += next.scroll
                    packet.hscroll += next.hscroll
                    self.queue.removeFirst()
                }
                guard let vm = self.viewModel else { break }
                await vm.sendCursor(
                    dx: macRemoteClamp(packet.dx, 10_000),
                    dy: macRemoteClamp(packet.dy, 10_000),
                    click: packet.click,
                    scroll: macRemoteClamp(packet.scroll, 100),
                    hscroll: macRemoteClamp(packet.hscroll, 100),
                    drag: packet.drag
                )
            }
            self?.worker = nil
        }
    }
}
