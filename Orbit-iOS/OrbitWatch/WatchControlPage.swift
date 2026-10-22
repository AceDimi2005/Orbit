import SwiftUI
import WatchKit

/// Control: the watch as the PC's pointer. Swipe the pad to move, tap it to click; the
/// buttons under it right-click, double-click and hold for dragging. Wrist motion moves the
/// pointer with your arm, and the Digital Crown scrolls the PC once you hand it over.
struct WatchControlPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastTouch: CGPoint?
    @State private var hasTouched = false
    @State private var crownScrolling = false
    @State private var showsOptions = false
    @FocusState private var crownFocused: Bool

    private var enabled: Bool { vm.canControlPC }
    /// As tall as possible while the click buttons still fit on the first screen.
    private var padHeight: CGFloat { min(120, max(84, WatchScreen.bounds.height * 0.45)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                pad
                mouseButtons
                motionButton
                crownButton
                if vm.isMotionCursorActive {
                    Button {
                        vm.calibrateWristCenter()
                    } label: {
                        WatchButtonLabel(title: "Recenter", systemImage: "scope", alignment: .leading)
                    }
                    .watchButton()
                    .transition(.opacity)
                }
                if let status = statusLine {
                    WatchHint(status)
                        .padding(.top, 2)
                }
            }
            .watchAnimation(value: vm.isMotionCursorActive)
            .tint(vm.tint)
        }
        .watchDebugScrollAnchor()
        .navigationTitle("Control")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsOptions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Options and shortcuts")
            }
        }
        .sheet(isPresented: $showsOptions) { WatchControlOptionsSheet(vm: vm) }
        .onDisappear(perform: finish)
        .onChange(of: vm.selectedTab) { _, page in
            if page != WatchPage.control.rawValue { finish() }
        }
        .onChange(of: enabled) { _, isEnabled in
            if !isEnabled { finish() }
        }
        #if DEBUG
        .onAppear {
            if WatchDebugOptions.crownActive { crownScrolling = true }
            if WatchDebugOptions.sheet == "options" { showsOptions = true }
        }
        #endif
    }

    // MARK: Pad

    private var pad: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            shape.fill(OrbitPalette.surface)
            shape.strokeBorder(borderStyle, lineWidth: vm.isDragLocked || crownScrolling ? 2 : 1)
            padContent
        }
        .frame(height: padHeight)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard enabled else { return }
                    if !hasTouched { withAnimation(reduceMotion ? nil : OrbitMotion.quick) { hasTouched = true } }
                    if let last = lastTouch {
                        let dx = Int(((value.location.x - last.x) * 2.4 * vm.sensitivity).rounded())
                        let dy = Int(((value.location.y - last.y) * 2.4 * vm.sensitivity).rounded())
                        if dx != 0 || dy != 0 { vm.sendCursorPacket(dx: dx, dy: dy) }
                    }
                    lastTouch = value.location
                }
                .onEnded { _ in lastTouch = nil }
        )
        .simultaneousGesture(TapGesture().onEnded {
            if enabled { vm.sendCursorPacket(click: "left") }
        })
        .focusable(crownScrolling)
        .focused($crownFocused)
        .digitalCrownRotation($vm.crownScrollAccumulator, from: -1000, through: 1000, by: 0.5,
                              sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: vm.crownScrollAccumulator) { _, value in
            if crownScrolling && enabled { vm.handleCrownScrollChange(value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PC trackpad")
        .accessibilityValue(crownScrolling ? "The Digital Crown scrolls the PC" : "")
        .accessibilityHint("Swipe to move the pointer. Tap to click.")
        .accessibilityAction(named: "Left click") { if enabled { vm.sendCursorPacket(click: "left") } }
        .accessibilityAction(named: "Right click") { if enabled { vm.sendCursorPacket(click: "right") } }
        .accessibilityAction(named: "Scroll up") { if enabled { vm.sendCursorPacket(scroll: 3) } }
        .accessibilityAction(named: "Scroll down") { if enabled { vm.sendCursorPacket(scroll: -3) } }
    }

    private var borderStyle: AnyShapeStyle {
        if vm.isDragLocked || crownScrolling || vm.isMotionCursorActive { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(OrbitPalette.hairline)
    }

    @ViewBuilder
    private var padContent: some View {
        if !enabled {
            padHint("Connect to your PC to use the pointer.", systemImage: "wifi.slash")
        } else if crownScrolling {
            padHint("Turn the Digital Crown to scroll.", systemImage: "digitalcrown.horizontal.arrow.counterclockwise")
        } else if vm.isMotionCursorActive {
            Circle()
                .fill(.tint)
                .frame(width: 12, height: 12)
                .offset(vm.cursorIndicatorOffset)
                .accessibilityHidden(true)
        } else if !hasTouched {
            padHint("Swipe to move.\nTap to click.", systemImage: "hand.point.up.left")
        }
    }

    private func padHint(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3.weight(.light))
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Buttons

    private var mouseButtons: some View {
        HStack(spacing: 6) {
            mouseButton("Right", label: "Right click", systemImage: "contextualmenu.and.cursorarrow") {
                vm.sendCursorPacket(click: "right")
            }
            mouseButton("Double", label: "Double click", systemImage: "cursorarrow.click.2") {
                vm.sendCursorPacket(click: "double")
            }
            // Releasing stays possible even if the connection drops mid-drag.
            mouseButton(vm.isDragLocked ? "Release" : "Drag",
                        label: vm.isDragLocked ? "Release the mouse button" : "Hold the mouse button to drag",
                        systemImage: vm.isDragLocked ? "hand.raised.fill" : "hand.draw",
                        prominent: vm.isDragLocked, isEnabled: enabled || vm.isDragLocked) {
                vm.toggleDragLock()
            }
        }
    }

    private func mouseButton(_ title: String, label: String, systemImage: String, prominent: Bool = false,
                             isEnabled: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .frame(height: 19)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(WatchRowButtonStyle(prominent: prominent, tint: vm.tint))
        .disabled(!(isEnabled ?? enabled))
        .accessibilityLabel(label)
    }

    private var motionButton: some View {
        Button {
            if !vm.isMotionCursorActive && vm.motionMode == .touchPad { vm.setCursorMode(.gyroGlide) }
            vm.toggleMotionCursor()
        } label: {
            WatchButtonLabel(title: vm.isMotionCursorActive ? "Pause" : "Wrist Motion",
                             systemImage: vm.isMotionCursorActive ? "pause.fill" : "gyroscope",
                             alignment: .leading)
        }
        .watchButton(prominent: vm.isMotionCursorActive)
        .disabled(!vm.isMotionCursorActive && !(enabled && vm.isMotionAvailable))
        .accessibilityLabel(vm.isMotionCursorActive ? "Pause wrist motion" : "Move the pointer with your wrist")
    }

    private var crownButton: some View {
        Button {
            vm.resetCrownScroll()
            crownScrolling.toggle()
            crownFocused = crownScrolling
        } label: {
            WatchButtonLabel(title: crownScrolling ? "Done Scrolling" : "Scroll with Crown",
                             systemImage: crownScrolling ? "checkmark" : "digitalcrown.horizontal.arrow.counterclockwise",
                             alignment: .leading)
        }
        .watchButton(prominent: crownScrolling)
        .disabled(!enabled)
    }

    /// Only what you need to know right now: why it's unavailable, or what the pointer is doing.
    private var statusLine: String? {
        if !enabled { return nil }
        if !vm.isMotionAvailable && !vm.isMotionCursorActive && vm.motionMode != .touchPad {
            return "Wrist motion needs the watch's motion sensors."
        }
        if vm.isMotionCursorActive || vm.isDragLocked || vm.cursorRouteLabel == "Connection needs attention" {
            return vm.cursorStatusMessage
        }
        return nil
    }

    private func finish() {
        lastTouch = nil
        crownScrolling = false
        crownFocused = false
        vm.stopMotionCursor()
    }
}

// MARK: - Options

/// Pointer speed, wrist motion style and the Windows shortcuts the pad cannot reach.
struct WatchControlOptionsSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @Environment(\.dismiss) private var dismiss

    private static let speeds: [(String, Double)] = [("Precise", 0.7), ("Balanced", 1.2), ("Fast", 1.8), ("Very Fast", 2.5)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                list
                    .tint(vm.tint)
                    .watchDebugScrollToEnd(proxy)
            }
            .navigationTitle("Options")
            .containerBackground(OrbitPalette.canvas, for: .navigation)
        }
    }

    private var list: some View {
        List {
            Section("Windows") {
                shortcut("Show Desktop", systemImage: "menubar.dock.rectangle", action: "show_desktop")
                shortcut("Switch Window", systemImage: "macwindow.on.rectangle", action: "alt_tab")
                shortcut("Task View", systemImage: "rectangle.3.group", action: "task_view")
                shortcut("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: "fullscreen")
                shortcut("Screenshot", systemImage: "camera.viewfinder", action: "screenshot")
            }
            Section("Display") {
                shortcut("Turn On Display", systemImage: "display", action: "restore_display")
                shortcut("HDR On or Off", systemImage: "sun.max", action: "toggle_hdr")
            }
            Section("Pointer Speed") {
                ForEach(Self.speeds, id: \.0) { name, value in
                    choice(name, isSelected: abs(vm.sensitivity - value) < 0.15) {
                        vm.sensitivity = value
                    }
                }
            }
            Section {
                choice("Glide", detail: "Tilt and turn your wrist.", isSelected: vm.motionMode == .gyroGlide) {
                    vm.setCursorMode(.gyroGlide)
                }
                choice("Point", detail: "Aim your wrist at the screen.", isSelected: vm.motionMode == .laserPointer) {
                    vm.setCursorMode(.laserPointer)
                }
                .id("end")
            } header: {
                Text("Wrist Motion")
            } footer: {
                Text("Hold your wrist comfortably and tap Recenter whenever you change position. Leaving Control pauses wrist motion and releases a drag.")
            }
        }
    }

    private func shortcut(_ title: String, systemImage: String, action: String) -> some View {
        Button {
            Task { await vm.sendPowerAction(action) }
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!vm.canControlPC)
    }

    private func choice(_ title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            WKInterfaceDevice.current().play(.click)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
