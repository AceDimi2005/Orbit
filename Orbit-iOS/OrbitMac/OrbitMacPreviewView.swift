import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared stream lifecycle

/// Number of canvases currently showing the stream (section page and detached window).
/// The stream is stopped only when the last one disappears, so moving the preview
/// into its own window never interrupts it.
@MainActor
fileprivate final class MacPreviewViewerCount {
    static var count = 0
}

fileprivate enum MacPreviewText {
    static func fps(_ value: Double, hasFrame: Bool) -> String {
        guard hasFrame, value.isFinite else { return "— fps" }
        return "\(Int(value.rounded())) fps"
    }
    /// Pixel dimensions of the decoded frame (NSImage.size is in points and follows the JPEG DPI).
    static func pixelSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
    static func frameSize(_ image: NSImage?) -> String {
        guard let image else { return "—" }
        let size = pixelSize(image)
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

fileprivate struct MacPreviewShortcut: Identifiable {
    let keys: String
    let label: String
    var id: String { keys }
}

// MARK: - Section page

/// Desktop Preview section: status hero, live canvas with click-to-control, guide and options.
struct MacPreviewView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mac.previewAutoStart") private var autoStart = true
    @AppStorage("mac.previewAlwaysOnTop") private var alwaysOnTop = false

    private static let shortcuts: [MacPreviewShortcut] = [
        MacPreviewShortcut(keys: "⌘⇧D", label: "Start or stop the preview"),
        MacPreviewShortcut(keys: "⌘⌥D", label: "Open the preview window"),
        MacPreviewShortcut(keys: "⌘⇧K", label: "Turn Control on or off"),
        MacPreviewShortcut(keys: "⌘⇧C", label: "Copy a snapshot"),
        MacPreviewShortcut(keys: "⌘⇧S", label: "Save a snapshot as PNG"),
        MacPreviewShortcut(keys: "⌘⇧T", label: "Always on top (window)")
    ]

    var body: some View {
        MacPage {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                if let error = vm.streamError {
                    MacNotice(title: "Preview interrupted", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                MacPreviewCanvas(isWindowed: false, showsInlineError: false)
                HStack(alignment: .top, spacing: 14) {
                    guideCard.frame(maxWidth: .infinity)
                    optionsCard.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Hero

    private var statusText: String {
        if vm.isDemoMode { return "Demo" }
        if !vm.isConfigured { return "Not paired" }
        if vm.isStreaming { return "Streaming" }
        return vm.metrics.isOnline ? "Paused" : "Offline"
    }
    private var statusTint: Color {
        if vm.isDemoMode { return .orange }
        if !vm.isConfigured { return .secondary }
        if vm.isStreaming { return .red }
        return vm.metrics.isOnline ? theme.accent : .orange
    }
    private var summary: String {
        if !vm.isConfigured { return "Pair your PC to stream its desktop here." }
        if vm.isDemoMode { return "Demo mode simulates telemetry only. Pair a PC to stream a real desktop." }
        if !vm.metrics.isOnline { return "\(vm.selectedPCName) is offline. Wake it to start the preview." }
        if vm.isStreaming { return "Streaming \(vm.selectedPCName)'s desktop over the encrypted link. Turn on Control to click, drag, scroll and type." }
        return "Press play to stream \(vm.selectedPCName)'s desktop as JPEG frames over the encrypted link."
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            MacIconBadge(systemName: "display", tint: theme.accent, size: 48, filled: vm.isStreaming)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Desktop Preview")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                    MacStatusPill(text: statusText, tint: statusTint, pulsing: vm.isStreaming)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                heroChips
            }
            Spacer(minLength: 8)
            Button {
                openWindow(id: "preview")
            } label: {
                Label("Open in Window", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            .help("Open the preview in its own window (⌘⌥D)")
        }
        .padding(18)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    private var heroChips: some View {
        HStack(spacing: 8) {
            if vm.isConfigured {
                MacStatChip(label: "PC", value: vm.selectedPCName, icon: "desktopcomputer")
            }
            if vm.metrics.isOnline && !vm.isDemoMode {
                MacStatChip(label: "Ping", value: "\(vm.pingMs) ms")
                MacStatChip(label: "Link", value: vm.currentPC?.isSecure == true ? "Encrypted" : "—", icon: "lock.fill")
            }
            MacStatChip(label: "Rate", value: MacPreviewText.fps(vm.previewFPS, hasFrame: vm.isStreaming && vm.previewFrame != nil), icon: "speedometer")
            MacStatChip(label: "Frame", value: MacPreviewText.frameSize(vm.previewFrame), icon: "aspectratio")
        }
        .lineLimit(1)
    }

    // MARK: Guide & options

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Control", subtitle: "Turn on Control above the picture to drive the PC", icon: "cursorarrow.click.2")
            guideRow("Click and drag", "Press on the picture to click; hold and move to drag. Right-click opens context menus, the middle button works too.", icon: "cursorarrow.click")
            guideRow("Scroll", "The mouse wheel or trackpad scrolls whatever is under the PC cursor.", icon: "arrow.up.and.down")
            guideRow("Type", "Printable keys, Return, Delete, Tab, Space and Esc go to the PC while the picture has focus. ⌘ shortcuts stay on the Mac.", icon: "keyboard")
            guideRow("Precise at any size", "Positions are sent as a fraction of the frame, so clicks land correctly however large the window is.", icon: "scope")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func guideRow(_ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MacIconBadge(systemName: icon, tint: theme.accent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader("Options", icon: "slider.horizontal.3")
            optionRow("Start automatically", "Begin streaming when this page or the preview window opens and the PC is online.", isOn: $autoStart)
            optionRow("Keep the window on top", "The detached preview floats above other apps and follows you across Spaces.", isOn: $alwaysOnTop)
            Divider().overlay(.white.opacity(0.1))
            Text("Shortcuts")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(Self.shortcuts) { shortcut in
                HStack(spacing: 10) {
                    Text(shortcut.keys)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .frame(width: 64, alignment: .leading)
                    Text(shortcut.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func optionRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Detached window

/// Content of the `Window(id: "preview")` scene: full-bleed canvas with its own HUD.
struct MacPreviewWindowView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.previewAlwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        ZStack {
            MacAmbientBackground(isOnline: vm.metrics.isOnline)
            MacPreviewCanvas(isWindowed: true, showsInlineError: true)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .background(
            MacPreviewWindowLevel(floating: alwaysOnTop)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
    }
}

/// Grabs the hosting window and toggles its level between normal and floating.
fileprivate struct MacPreviewWindowLevel: NSViewRepresentable {
    var floating: Bool

    func makeNSView(context: Context) -> MacPreviewWindowLevelView {
        let view = MacPreviewWindowLevelView()
        view.floating = floating
        return view
    }

    func updateNSView(_ nsView: MacPreviewWindowLevelView, context: Context) {
        nsView.floating = floating
        nsView.apply()
    }
}

@MainActor
fileprivate final class MacPreviewWindowLevelView: NSView {
    var floating = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        window.level = floating ? .floating : .normal
        if floating {
            window.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            window.collectionBehavior.remove(.canJoinAllSpaces)
        }
    }
}

// MARK: - Canvas shared by the page and the window

fileprivate struct MacPreviewCanvas: View {
    var isWindowed: Bool
    var showsInlineError: Bool

    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("mac.previewAutoStart") private var autoStart = true
    @AppStorage("mac.previewAlwaysOnTop") private var alwaysOnTop = false
    @State private var controlEnabled = false
    @State private var keyboardCaptured = false
    @State private var snapshotMessage: String?
    @State private var snapshotTask: Task<Void, Never>?

    /// A real, online PC is selected: the only state in which frames can flow.
    private var canStream: Bool { vm.isConfigured && !vm.isDemoMode && vm.metrics.isOnline }

    private var aspect: CGFloat {
        guard let image = vm.previewFrame, image.size.width > 0, image.size.height > 0 else { return 16 / 9 }
        return min(3, max(1, image.size.width / image.size.height))
    }

    var body: some View {
        Group {
            if isWindowed {
                surface
            } else {
                surface.aspectRatio(aspect, contentMode: .fit)
            }
        }
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: vm.metrics.isOnline) { _, online in handleOnlineChange(online) }
        .onChange(of: vm.selectedPCID) { _, _ in
            controlEnabled = false
            syncStream()
        }
        .onChange(of: vm.isStreaming) { _, streaming in
            if !streaming { controlEnabled = false }
        }
        .onChange(of: controlEnabled) { _, enabled in
            if !enabled { keyboardCaptured = false }
        }
    }

    private var surface: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fitted = fittedRect(in: size)
            ZStack {
                Color.black
                content(size: size)
                if controlEnabled, vm.isStreaming, let rect = fitted {
                    controlOverlay(in: rect)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) {
            if vm.isConfigured && !vm.isDemoMode { hud }
        }
        .overlay(alignment: .bottom) { bottomOverlay }
        .padding(8)
        .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
    }

    // MARK: Picture & placeholders

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if !vm.isConfigured {
            MacEmptyState(icon: "desktopcomputer", title: "Pair your PC",
                          message: "Import the PC you already paired on your iPhone, or pair directly with the 6-digit code shown by Orbit Agent on Windows.",
                          tint: theme.accent, actionTitle: "Open My PCs") { goToPCs() }
        } else if vm.isDemoMode {
            MacEmptyState(icon: "sparkles", title: "Demo mode",
                          message: "The desktop preview streams real frames from a paired PC, so there is nothing to simulate here.",
                          tint: .orange, actionTitle: "Pair a PC") {
                vm.setDemoMode(false)
                goToPCs()
            }
        } else if !vm.metrics.isOnline {
            MacEmptyState(icon: "power", title: "\(vm.selectedPCName) is offline",
                          message: vm.connectionError ?? "Wake the PC or check that Orbit Agent is running. The preview starts as soon as it is back.",
                          tint: .orange, actionTitle: vm.isWaking ? "Waking…" : "Power On") {
                Task { await vm.wakePC() }
            }
            .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty == true)
        } else {
            ZStack {
                if let image = vm.previewFrame {
                    if vm.isStreaming {
                        frameImage(image, size: size)
                    } else {
                        frameImage(image, size: size)
                            .opacity(0.35)
                            .blur(radius: 8)
                    }
                }
                if !vm.isStreaming {
                    playPlaceholder
                } else if vm.previewFrame == nil {
                    connectingPlaceholder
                }
            }
        }
    }

    private func frameImage(_ image: NSImage, size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Live desktop of \(vm.selectedPCName)")
    }

    private var playPlaceholder: some View {
        VStack(spacing: 16) {
            MacPreviewPlayButton(tint: theme.accent) { vm.startPreview() }
            VStack(spacing: 4) {
                Text(vm.previewFrame == nil ? "Start the desktop preview" : "Preview paused")
                    .font(.headline.weight(.bold))
                Text("Streams \(vm.selectedPCName)'s screen as JPEG frames over the encrypted link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
    }

    private var connectingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Connecting to the desktop stream…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: HUD

    private var hud: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                if vm.isStreaming {
                    MacStatusPill(text: "LIVE", tint: .red, pulsing: true)
                } else if canStream {
                    MacStatusPill(text: "Paused", tint: .secondary, icon: "pause.fill")
                } else {
                    MacStatusPill(text: "Offline", tint: .orange, icon: "bolt.slash.fill")
                }
                hudChip(MacPreviewText.fps(vm.previewFPS, hasFrame: vm.isStreaming && vm.previewFrame != nil), icon: "speedometer")
                hudChip(MacPreviewText.frameSize(vm.previewFrame), icon: "aspectratio")
                if controlEnabled {
                    hudChip(keyboardCaptured ? "Keys → PC" : "Click the picture to type", icon: "keyboard", tint: theme.accent)
                }
            }
            .padding(.leading, isWindowed ? 62 : 0)
            Spacer(minLength: 8)
            HStack(spacing: 8) { hudButtons }
        }
        .padding(10)
        .background(
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func hudChip(_ text: String, icon: String, tint: Color = .white) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(.caption, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var hudButtons: some View {
        Button(action: copySnapshot) {
            Image(systemName: "camera.on.rectangle")
        }
        .buttonStyle(MacIconButtonStyle(size: 28))
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(vm.previewFrame == nil)
        .help("Copy snapshot to the clipboard (⌘⇧C)")
        .accessibilityLabel("Copy snapshot")

        Button(action: saveSnapshot) {
            Image(systemName: "square.and.arrow.down")
        }
        .buttonStyle(MacIconButtonStyle(size: 28))
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(vm.previewFrame == nil)
        .help("Save snapshot as PNG… (⌘⇧S)")
        .accessibilityLabel("Save snapshot")

        Button {
            controlEnabled.toggle()
        } label: {
            Label("Control", systemImage: controlEnabled ? "cursorarrow.click.2" : "cursorarrow")
        }
        .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: controlEnabled))
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(!vm.isStreaming)
        .help(controlEnabled ? "Stop sending clicks and keys to the PC (⌘⇧K)" : "Send clicks, scrolling and typing to the PC (⌘⇧K)")

        if isWindowed {
            Button {
                alwaysOnTop.toggle()
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(MacIconButtonStyle(tint: alwaysOnTop ? theme.accent : .white, size: 28))
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help(alwaysOnTop ? "Stop floating above other windows (⌘⇧T)" : "Always on top (⌘⇧T)")
            .accessibilityLabel("Always on top")
        } else {
            Button {
                openWindow(id: "preview")
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .buttonStyle(MacIconButtonStyle(size: 28))
            .help("Open in a separate window (⌘⌥D)")
            .accessibilityLabel("Open in window")
        }

        Button {
            if vm.isStreaming { vm.stopPreview() } else { vm.startPreview() }
        } label: {
            Label(vm.isStreaming ? "Stop" : "Start", systemImage: vm.isStreaming ? "stop.fill" : "play.fill")
        }
        .buttonStyle(MacHoverButtonStyle(tint: vm.isStreaming ? .orange : theme.accent, prominent: !vm.isStreaming))
        .disabled(!vm.isStreaming && !canStream)
        .help(vm.isStreaming ? "Stop the desktop preview (⌘⇧D)" : "Start the desktop preview (⌘⇧D)")

        if isWindowed {
            Button {
                dismissWindow(id: "preview")
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MacIconButtonStyle(size: 28))
            .help("Close window (⌘W)")
            .accessibilityLabel("Close preview window")
        }
    }

    private var bottomOverlay: some View {
        VStack(spacing: 8) {
            if let message = snapshotMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(.caption, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsInlineError, let error = vm.streamError {
                MacNotice(title: "Preview interrupted", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    .frame(maxWidth: 560)
            }
        }
        .padding(12)
    }

    // MARK: Control overlay geometry

    /// Rect of the picture inside the canvas after aspect-fit scaling (same maths as `Image.aspectRatio(.fit)`).
    private func fittedRect(in size: CGSize) -> CGRect? {
        guard let image = vm.previewFrame, size.width > 0, size.height > 0 else { return nil }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func controlOverlay(in rect: CGRect) -> some View {
        MacPreviewControlOverlay(vm: vm, keyboardCaptured: $keyboardCaptured)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(theme.accent.opacity(keyboardCaptured ? 0.9 : 0.5), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel("Remote control surface for \(vm.selectedPCName)")
    }

    // MARK: Lifecycle

    private func attach() {
        MacPreviewViewerCount.count += 1
        syncStream()
    }

    private func detach() {
        MacPreviewViewerCount.count = max(0, MacPreviewViewerCount.count - 1)
        controlEnabled = false
        snapshotTask?.cancel()
        if MacPreviewViewerCount.count == 0 { vm.stopPreview() }
    }

    /// Starts the stream when auto-start is on and a real PC is online.
    private func syncStream() {
        guard autoStart, canStream, !vm.isStreaming else { return }
        vm.startPreview()
    }

    private func handleOnlineChange(_ online: Bool) {
        if online {
            syncStream()
        } else {
            controlEnabled = false
            if vm.isStreaming { vm.stopPreview() }
        }
    }

    private func goToPCs() {
        vm.selectedSection = .pcs
        if isWindowed { openWindow(id: "main") }
    }

    // MARK: Snapshots

    private func copySnapshot() {
        guard let image = vm.previewFrame else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let written = pasteboard.writeObjects([image])
        flash(written ? "Snapshot copied to the clipboard" : "Could not copy the snapshot")
    }

    private func saveSnapshot() {
        guard let image = vm.previewFrame, let png = pngData(from: image) else {
            flash("No frame to save yet")
            return
        }
        let safeName = vm.selectedPCName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let panel = NSSavePanel()
        panel.message = "Save the current preview frame as a PNG image."
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Orbit \(safeName) \(MacPreviewText.fileStamp.string(from: Date())).png"
        Task { @MainActor in
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
                flash("Saved \(url.lastPathComponent)")
            } catch {
                flash("Could not save: \(error.localizedDescription)")
            }
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func flash(_ message: String) {
        snapshotTask?.cancel()
        withAnimation(.snappy(duration: 0.25)) { snapshotMessage = message }
        snapshotTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { snapshotMessage = nil }
        }
    }
}

// MARK: - Play button

fileprivate struct MacPreviewPlayButton: View {
    var tint: Color
    var action: () -> Void
    @State private var hovered = false
    @AppStorage("mac.reduceGlow") private var reduceGlow = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 2)
                .frame(width: 84, height: 84)
                .glassEffect(.regular.tint(tint).interactive(), in: Circle())
                .scaleEffect(hovered ? 1.04 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(OrbitMotion.quick, value: hovered)
        .help("Start the desktop preview")
        .accessibilityLabel("Start desktop preview")
    }
}

// MARK: - Input overlay (click-to-control)

fileprivate enum MacPreviewInputEvent {
    case pointerDown(x: Double, y: Double)
    case pointerMove(x: Double, y: Double)
    case pointerUp(x: Double, y: Double)
    case click(button: String, x: Double, y: Double)
    case scroll(vertical: Int, horizontal: Int)
    case text(String)
    case key(String)
}

/// Transparent AppKit view laid exactly over the picture. It turns pointer and key
/// events into normalised (0…1, origin top-left) input for the agent.
@MainActor
fileprivate final class MacPreviewInputView: NSView {
    var onEvent: (@MainActor (MacPreviewInputEvent) -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?

    private var lastMoveSent = Date.distantPast
    private var scrollRemainderY = 0.0
    private var scrollRemainderX = 0.0

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        _ = window.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return super.resignFirstResponder()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// Normalised position of an event. AppKit's origin is bottom-left; the PC expects 0 at the top.
    private func normalized(_ event: NSEvent) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let x = min(1, max(0, point.x / bounds.width))
        let y = min(1, max(0, 1 - point.y / bounds.height))
        return CGPoint(x: x, y: y)
    }

    // The agent's drag "down"/"up" are a real button press and release, so a press without
    // movement is already a click on Windows and double-clicks come from Windows' own timing.
    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        guard let point = normalized(event) else { return }
        lastMoveSent = Date()
        onEvent?(.pointerDown(x: Double(point.x), y: Double(point.y)))
    }

    override func mouseDragged(with event: NSEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastMoveSent) >= 1.0 / 30.0, let point = normalized(event) else { return }
        lastMoveSent = now
        onEvent?(.pointerMove(x: Double(point.x), y: Double(point.y)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = normalized(event) else { return }
        onEvent?(.pointerUp(x: Double(point.x), y: Double(point.y)))
    }

    override func rightMouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let point = normalized(event) else { return }
        onEvent?(.click(button: "right", x: Double(point.x), y: Double(point.y)))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let point = normalized(event) else { return }
        onEvent?(.click(button: "middle", x: Double(point.x), y: Double(point.y)))
    }

    override func scrollWheel(with event: NSEvent) {
        var deltaY = Double(event.scrollingDeltaY)
        var deltaX = Double(event.scrollingDeltaX)
        if event.hasPreciseScrollingDeltas {
            // Trackpads report points; about 12 pt per wheel notch keeps the feel close to a mouse.
            deltaY /= 12
            deltaX /= 12
        }
        scrollRemainderY += deltaY
        scrollRemainderX += deltaX
        let stepsY = Int(scrollRemainderY.rounded(.towardZero))
        let stepsX = Int(scrollRemainderX.rounded(.towardZero))
        scrollRemainderY -= Double(stepsY)
        scrollRemainderX -= Double(stepsX)
        guard stepsY != 0 || stepsX != 0 else { return }
        // Positive deltaY is "wheel up" on the Mac and WHEEL_DELTA > 0 is "up" on Windows; horizontal is mirrored.
        onEvent?(.scroll(vertical: max(-20, min(20, stepsY)), horizontal: max(-20, min(20, -stepsX))))
    }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return }
        switch event.keyCode {
        case 36, 76: onEvent?(.key("ENTER"))
        case 51: onEvent?(.key("BACKSPACE"))
        case 48: onEvent?(.key("TAB"))
        case 53: onEvent?(.key("ESC"))
        case 49: onEvent?(.key("SPACE"))
        default:
            guard let characters = event.characters else { return }
            let printable = characters.filter { character in
                character.unicodeScalars.allSatisfy { scalar in
                    scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
                }
            }
            guard !printable.isEmpty else { return }
            onEvent?(.text(printable))
        }
    }
}

fileprivate struct MacPreviewControlOverlay: NSViewRepresentable {
    let vm: OrbitMacViewModel
    @Binding var keyboardCaptured: Bool

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    func makeNSView(context: Context) -> MacPreviewInputView {
        let view = MacPreviewInputView()
        let coordinator = context.coordinator
        view.onEvent = { [weak coordinator] event in coordinator?.enqueue(event) }
        view.onFocusChange = { [weak coordinator] focused in coordinator?.onFocus?(focused) }
        return view
    }

    func updateNSView(_ nsView: MacPreviewInputView, context: Context) {
        let binding = $keyboardCaptured
        context.coordinator.onFocus = { focused in
            // Focus can change while SwiftUI is mid-update (the view just got attached); defer the state write.
            Task { @MainActor in binding.wrappedValue = focused }
        }
    }

    static func dismantleNSView(_ nsView: MacPreviewInputView, coordinator: Coordinator) {
        nsView.onEvent = nil
        nsView.onFocusChange = nil
        coordinator.onFocus = nil
        coordinator.cancel()
    }

    /// Serialises input so a drag "up" can never overtake the moves before it.
    @MainActor
    final class Coordinator {
        let vm: OrbitMacViewModel
        var onFocus: ((Bool) -> Void)?
        private var chain: Task<Void, Never>?

        init(vm: OrbitMacViewModel) { self.vm = vm }

        func enqueue(_ event: MacPreviewInputEvent) {
            let previous = chain
            let model = vm
            chain = Task { @MainActor in
                await previous?.value
                guard !Task.isCancelled else { return }
                await Coordinator.deliver(event, to: model)
            }
        }

        func cancel() {
            chain?.cancel()
            chain = nil
        }

        private static func deliver(_ event: MacPreviewInputEvent, to vm: OrbitMacViewModel) async {
            switch event {
            case let .pointerDown(x, y):
                await vm.sendCursor(normX: x, normY: y, drag: "down")
            case let .pointerMove(x, y):
                await vm.sendCursor(normX: x, normY: y)
            case let .pointerUp(x, y):
                await vm.sendCursor(normX: x, normY: y, drag: "up")
            case let .click(button, x, y):
                await vm.sendCursor(click: button, normX: x, normY: y)
            case let .scroll(vertical, horizontal):
                await vm.sendCursor(scroll: vertical, hscroll: horizontal)
            case let .text(text):
                await vm.sendKeyboard(text: text)
            case let .key(key):
                await vm.sendKeyboard(key: key)
            }
        }
    }
}
