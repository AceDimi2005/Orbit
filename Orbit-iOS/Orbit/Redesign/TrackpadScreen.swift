import SwiftUI

/// The phone becomes the PC's trackpad: the whole screen is the touch surface, with the
/// mouse buttons, keyboard and media keys on a glass bar under your thumb.
struct TrackpadScreen: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("orbit.remote.sensitivity") private var sensitivity = 2.0
    @State private var touchPoint: CGPoint?
    @State private var isDragging = false
    @State private var hasTouched = false
    @State private var typing = ""
    @State private var confirmsCloseGame = false
    @FocusState private var keyboardFocused: Bool

    private var online: Bool { vm.metrics.isOnline && !vm.isDemoMode }

    var body: some View {
        NavigationStack {
            surface
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .background(OrbitPalette.canvas)
                .safeAreaBar(edge: .bottom) { controls }
                .navigationTitle("Trackpad")
                .navigationSubtitle(online ? vm.selectedPCName : "Not connected")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                    ToolbarItemGroup(placement: .keyboard) { keyboardKeys }
                }
                .background {
                    // A hidden field drives the system keyboard; every keystroke goes straight to the PC.
                    TextField("", text: $typing)
                        .focused($keyboardFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                        .onChange(of: typing) { _, text in
                            guard !text.isEmpty else { return }
                            typing = ""
                            Task { await vm.sendKeyboardInput(text: text) }
                        }
                        .onSubmit {
                            Task { await vm.sendKeyboardInput(key: "ENTER") }
                            keyboardFocused = true
                        }
                }
                .confirmationDialog("Close the game in front?", isPresented: $confirmsCloseGame, titleVisibility: .visible) {
                    Button("Close Game", role: .destructive) { Task { await vm.sendPowerAction("kill_game") } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Asks the game in the foreground on the PC to close.")
                }
        }
        .onDisappear {
            if isDragging { Task { await vm.sendCursorInput(drag: "up") } }
        }
    }

    // MARK: Surface

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(OrbitPalette.surface)
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(isDragging ? AnyShapeStyle(.tint) : AnyShapeStyle(OrbitPalette.hairline), lineWidth: isDragging ? 2 : 1)
            if !hasTouched || !online {
                VStack(spacing: 10) {
                    Image(systemName: online ? "hand.point.up.left" : "wifi.slash")
                        .font(.system(size: 34, weight: .light))
                    Text(online ? "Move with one finger, scroll with two.\nTap to click, hold to drag." : "Connect to your PC to use the trackpad.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if let touchPoint {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 52, height: 52)
                    .position(touchPoint)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            OrbitTrackpadSurface(
                sensitivity: sensitivity,
                onMove: { dx, dy in
                    guard online else { return }
                    Task { await vm.sendCursorInput(dx: dx, dy: dy) }
                },
                onScroll: { vertical, horizontal in
                    guard online else { return }
                    Task { await vm.sendCursorInput(scroll: vertical, hscroll: horizontal) }
                },
                onClick: { button in
                    guard online else { return }
                    OrbitHaptics.tap()
                    Task { await vm.sendCursorInput(click: button) }
                },
                onDrag: { active in
                    guard online else { return }
                    OrbitHaptics.press()
                    withAnimation(OrbitMotion.quick) { isDragging = active }
                    Task { await vm.sendCursorInput(drag: active ? "down" : "up") }
                },
                onTouch: { point in
                    if point != nil, !hasTouched { withAnimation(OrbitMotion.standard) { hasTouched = true } }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { touchPoint = point }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .allowsHitTesting(online)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PC trackpad")
        .accessibilityHint("Drag to move the pointer, tap to click, two fingers to scroll, hold to drag")
        .accessibilityAction(named: "Left click") { Task { await vm.sendCursorInput(click: "left") } }
        .accessibilityAction(named: "Right click") { Task { await vm.sendCursorInput(click: "right") } }
        .accessibilityAction(named: "Scroll up") { Task { await vm.sendCursorInput(scroll: 3) } }
        .accessibilityAction(named: "Scroll down") { Task { await vm.sendCursorInput(scroll: -3) } }
    }

    // MARK: Bottom controls

    private var controls: some View {
        OrbitGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                barButton("Left Click", systemImage: "cursorarrow.click") { await vm.sendCursorInput(click: "left") }
                barButton("Right Click", systemImage: "contextualmenu.and.cursorarrow") { await vm.sendCursorInput(click: "right") }
                Button {
                    OrbitHaptics.press()
                    let next = !isDragging
                    withAnimation(OrbitMotion.quick) { isDragging = next }
                    Task { await vm.sendCursorInput(drag: next ? "down" : "up") }
                } label: {
                    Label(isDragging ? "Drop" : "Drag", systemImage: isDragging ? "hand.raised.fill" : "hand.draw")
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 26)
                }
                .orbitGlassButton(prominent: isDragging)
                Button {
                    OrbitHaptics.tap()
                    keyboardFocused.toggle()
                } label: {
                    Label("Keyboard", systemImage: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 26)
                }
                .orbitGlassButton()
                mediaMenu
            }
            .controlSize(.large)
            .disabled(!online)
        }
        .padding(.bottom, 8)
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            OrbitHaptics.tap()
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
        }
        .orbitGlassButton()
    }

    private var mediaMenu: some View {
        Menu {
            Section {
                Button("Play or Pause", systemImage: "playpause") { send("media_play_pause") }
                Button("Next", systemImage: "forward") { send("media_next") }
                Button("Previous", systemImage: "backward") { send("media_prev") }
            }
            Section {
                Button("Volume Up", systemImage: "speaker.plus") { send("volume_up") }
                Button("Volume Down", systemImage: "speaker.minus") { send("volume_down") }
                Button(vm.metrics.isMuted ? "Unmute" : "Mute", systemImage: vm.metrics.isMuted ? "speaker.wave.2" : "speaker.slash") { send("mute") }
            }
        } label: {
            Label("Media", systemImage: "playpause")
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
        }
        .orbitGlassButton()
    }

    private var moreMenu: some View {
        Menu {
            Picker("Pointer Speed", selection: $sensitivity) {
                Text("Slow").tag(1.2)
                Text("Normal").tag(2.0)
                Text("Fast").tag(3.0)
            }
            .pickerStyle(.menu)
            Section("Windows") {
                Button("Show Desktop", systemImage: "menubar.dock.rectangle") { send("show_desktop") }
                Button("Task View", systemImage: "rectangle.3.group") { send("task_view") }
                Button("Switch Window", systemImage: "macwindow.on.rectangle") { send("alt_tab") }
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { send("fullscreen") }
                Button("Screenshot", systemImage: "camera.viewfinder") { send("screenshot") }
            }
            Section {
                Button("See the Screen", systemImage: "display") { vm.openDesktopPreview() }
                if vm.metrics.activeGame != nil {
                    Button("Close Game…", systemImage: "xmark.square", role: .destructive) { confirmsCloseGame = true }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(!online)
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var keyboardKeys: some View {
        keyboardKey("Escape", key: "ESC", systemImage: "escape")
        keyboardKey("Tab", key: "TAB", systemImage: "arrow.right.to.line")
        keyboardKey("Windows", key: "WIN", systemImage: "square.grid.2x2")
        Spacer()
        keyboardKey("Delete", key: "BACKSPACE", systemImage: "delete.left")
        keyboardKey("Return", key: "ENTER", systemImage: "return")
    }

    private func keyboardKey(_ title: String, key: String, systemImage: String) -> some View {
        Button(title, systemImage: systemImage) {
            OrbitHaptics.tap()
            Task { await vm.sendKeyboardInput(key: key) }
        }
    }

    private func send(_ action: String) {
        OrbitHaptics.tap()
        Task { await vm.sendPowerAction(action) }
    }
}
