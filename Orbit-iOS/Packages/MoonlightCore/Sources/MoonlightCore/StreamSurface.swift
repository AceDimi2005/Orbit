import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Lets SwiftUI reach into the platform view: software keyboard on iOS, mouse capture and full screen on macOS.
@MainActor
public final class MoonlightSurfaceHandle: ObservableObject {
    @Published public internal(set) var keyboardVisible = false
    @Published public internal(set) var mouseCaptured = false
    /// macOS: the stream's window is in full screen.
    @Published public internal(set) var isFullScreen = false
    weak var view: MoonlightStreamSurfaceView?

    public init() {}

    public func toggleKeyboard() {
        #if os(iOS)
        view?.setSoftwareKeyboard(visible: !keyboardVisible)
        #endif
    }

    public func releaseMouse() {
        #if os(macOS)
        view?.releaseCapture()
        #endif
    }

    public func captureMouse() {
        #if os(macOS)
        view?.capture()
        #endif
    }

    /// macOS: enters or leaves full screen (the same as Control-Option-Shift-F).
    public func toggleFullScreen() {
        #if os(macOS)
        view?.toggleFullScreen()
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// Hosts the video layer and turns touches, hardware keys and the software keyboard into input.
public final class MoonlightStreamSurfaceView: UIView {
    weak var handle: MoonlightSurfaceHandle?
    var onToggleOverlay: (() -> Void)?
    public var session: MoonlightStreamSession? {
        didSet {
            attachLayer()
            #if os(iOS)
            // A new connection starts with nothing held down on the PC.
            if oldValue !== session { resetKeyBar() }
            #endif
        }
    }
    public var settings = MoonlightStreamSettings() { didSet { applyMode() } }
    #if os(iOS)
    /// The key bar's latched modifiers and the bar keys that are down on the PC.
    private(set) var keyLatch = MoonlightModifierLatch()
    private(set) var keyBarView: MoonlightKeyBarView?
    /// Sees every key the key bar and the software keyboard send (the DEBUG key bar preview logs them).
    var keyOutputObserver: ((MoonlightKeyOutput) -> Void)?
    #endif

    private var videoLayer: AVSampleBufferDisplayLayer?
    private var lastPanPoint: CGPoint?
    private var lastScrollPoint: CGPoint?
    private var residual = CGPoint.zero
    private var dragging = false
    private var pointerIDs: [ObjectIdentifier: UInt32] = [:]
    private var nextPointerID: UInt32 = 1
    private var absoluteTouch: UITouch?
    private var softwareKeyboardVisible = false

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        #if os(iOS)
        recognizer.maximumNumberOfTouches = 1
        #endif
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        #if os(iOS)
        recognizer.numberOfTouchesRequired = 1
        #endif
        return recognizer
    }()
    private lazy var twoFingerTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        #if os(iOS)
        recognizer.numberOfTouchesRequired = 2
        #endif
        return recognizer
    }()
    private lazy var threeFingerTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        #if os(iOS)
        recognizer.numberOfTouchesRequired = 3
        #endif
        return recognizer
    }()
    private lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        #if os(iOS)
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        #endif
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 12
        recognizer.delegate = self
        return recognizer
    }()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        #if os(iOS)
        isMultipleTouchEnabled = true
        [panRecognizer, tapRecognizer, twoFingerTapRecognizer, threeFingerTapRecognizer, scrollRecognizer, longPressRecognizer].forEach(addGestureRecognizer)
        tapRecognizer.require(toFail: twoFingerTapRecognizer)
        applyMode()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    public override var canBecomeFirstResponder: Bool { true }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        #if os(iOS)
        if resigned, softwareKeyboardVisible { softwareKeyboardWentAway() }
        #endif
        return resigned
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
        #if os(iOS)
        if window == nil { releaseKeyBar() }
        #endif
    }

    private func attachLayer() {
        videoLayer?.removeFromSuperlayer()
        guard let session else { videoLayer = nil; return }
        install(session.renderer.displayLayer)
        session.renderer.onLayerReplaced = { [weak self] fresh in self?.install(fresh) }
    }

    private func install(_ fresh: AVSampleBufferDisplayLayer) {
        videoLayer?.removeFromSuperlayer()
        fresh.frame = bounds
        layer.addSublayer(fresh)
        videoLayer = fresh
    }

    private func applyMode() {
        #if os(iOS)
        let trackpad = settings.touchMode == .trackpad
        [panRecognizer, tapRecognizer, twoFingerTapRecognizer, scrollRecognizer, longPressRecognizer].forEach { $0.isEnabled = trackpad }
        #endif
    }

    /// Where the video is drawn inside the view (aspect-fit).
    private var videoRect: CGRect {
        let size = session?.renderer.videoSize ?? .zero
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: Trackpad gestures

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPanPoint = point
            residual = .zero
        case .changed:
            guard let last = lastPanPoint else { lastPanPoint = point; return }
            let scale = CGFloat(settings.trackpadSensitivity) * 2.2
            residual.x += (point.x - last.x) * scale
            residual.y += (point.y - last.y) * scale
            let dx = Int(residual.x.rounded(.towardZero))
            let dy = Int(residual.y.rounded(.towardZero))
            residual.x -= CGFloat(dx)
            residual.y -= CGFloat(dy)
            session?.sendMouseMove(dx: dx, dy: dy)
            lastPanPoint = point
        default:
            lastPanPoint = nil
            if dragging, longPressRecognizer.state != .changed {
                session?.sendMouseButton(.left, pressed: false)
                dragging = false
            }
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        session?.click(.left)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        session?.click(.right)
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onToggleOverlay?()
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began: lastScrollPoint = point
        case .changed:
            guard let last = lastScrollPoint else { lastScrollPoint = point; return }
            // Roughly 20 points of travel per wheel notch (120 units).
            session?.sendScroll(vertical: Int(((point.y - last.y) * 6).rounded()), horizontal: Int(((last.x - point.x) * 6).rounded()))
            lastScrollPoint = point
        default: lastScrollPoint = nil
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            dragging = true
            session?.sendMouseButton(.left, pressed: true)
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        case .ended, .cancelled, .failed:
            if dragging {
                session?.sendMouseButton(.left, pressed: false)
                dragging = false
            }
        default: break
        }
    }

    // MARK: Touchscreen mode

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard settings.touchMode == .touchscreen, let session else { super.touchesBegan(touches, with: event); return }
        for touch in touches { forward(touch, .down, session: session) }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard settings.touchMode == .touchscreen, let session else { super.touchesMoved(touches, with: event); return }
        for touch in touches { forward(touch, .move, session: session) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard settings.touchMode == .touchscreen, let session else { super.touchesEnded(touches, with: event); return }
        for touch in touches { forward(touch, .up, session: session) }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard settings.touchMode == .touchscreen, let session else { super.touchesCancelled(touches, with: event); return }
        for touch in touches { forward(touch, .cancel, session: session) }
    }

    private func forward(_ touch: UITouch, _ event: MoonlightTouchEvent, session: MoonlightStreamSession) {
        let rect = videoRect
        let location = touch.location(in: self)
        let normalizedX = Float(max(0, min(1, (location.x - rect.minX) / max(rect.width, 1))))
        let normalizedY = Float(max(0, min(1, (location.y - rect.minY) / max(rect.height, 1))))
        if session.hostSupportsTouch {
            let key = ObjectIdentifier(touch)
            let pointerID = pointerIDs[key] ?? { let id = nextPointerID; nextPointerID &+= 1; pointerIDs[key] = id; return id }()
            let pressure = touch.maximumPossibleForce > 0 ? Float(touch.force / touch.maximumPossibleForce) : 1
            session.sendTouch(event, pointerID: pointerID, x: normalizedX, y: normalizedY, pressure: event == .up || event == .cancel ? 0 : max(pressure, 0.01))
            if event == .up || event == .cancel { pointerIDs.removeValue(forKey: key) }
        } else {
            // Hosts without touch support get an absolute mouse: first finger only.
            let size = session.renderer.videoSize
            let x = Int(normalizedX * Float(max(size.width, 1)))
            let y = Int(normalizedY * Float(max(size.height, 1)))
            switch event {
            case .down where absoluteTouch == nil:
                absoluteTouch = touch
                session.sendMousePosition(x: x, y: y, referenceWidth: Int(size.width), referenceHeight: Int(size.height))
                session.sendMouseButton(.left, pressed: true)
            case .move where absoluteTouch === touch:
                session.sendMousePosition(x: x, y: y, referenceWidth: Int(size.width), referenceHeight: Int(size.height))
            case .up where absoluteTouch === touch, .cancel where absoluteTouch === touch:
                session.sendMouseButton(.left, pressed: false)
                absoluteTouch = nil
            default: break
            }
        }
    }

    // MARK: Hardware keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, pressed: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, pressed: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, pressed: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, pressed: Bool) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        #if os(iOS)
        var finishedKey = false
        defer {
            // A key bar modifier latched for one key combined with this hardware key on the PC; it is done now.
            if finishedKey, keyLatch.hasOneShot { updateKeys { $0.releaseOneShots() } }
        }
        #endif
        for press in presses {
            guard let key = press.key, let session, let virtualKey = MoonlightVirtualKey.fromHIDUsage(Int(key.keyCode.rawValue)) else {
                unhandled.insert(press)
                continue
            }
            // With the software keyboard up, printable characters arrive through insertText instead.
            if softwareKeyboardVisible, Self.isPrintable(virtualKey), key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty {
                continue
            }
            var modifiers = MoonlightKeyModifiers()
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
            if key.modifierFlags.contains(.command) { modifiers.insert(.meta) }
            session.sendKey(virtualKey: virtualKey, pressed: pressed, modifiers: modifiers)
            #if os(iOS)
            if !pressed, !MoonlightVirtualKey.isModifier(virtualKey) { finishedKey = true }
            #endif
        }
        return unhandled
    }

    private static func isPrintable(_ virtualKey: Int16) -> Bool {
        (0x30...0x39).contains(virtualKey) || (0x41...0x5A).contains(virtualKey) || (0xBA...0xC0).contains(virtualKey)
            || (0xDB...0xDE).contains(virtualKey) || virtualKey == MoonlightVirtualKey.space || (0x60...0x6F).contains(virtualKey)
    }

    #if os(iOS)
    public func setSoftwareKeyboard(visible: Bool) {
        softwareKeyboardVisible = visible
        handle?.keyboardVisible = visible
        if !visible { releaseKeyBar() }
        reloadInputViews()
        if visible { becomeFirstResponder() }
    }

    private let hiddenInputView = UIView(frame: .zero)
    public override var inputView: UIView? { softwareKeyboardVisible ? nil : hiddenInputView }
    /// The row of PC keys (Win, Ctrl, Alt, Shift, Esc, arrows, F-keys, shortcuts) rides on top of the keyboard.
    public override var inputAccessoryView: UIView? { softwareKeyboardVisible ? keyBar : nil }

    /// The keyboard went away without the Keyboard button: the iPad's hide key, or another field took focus.
    private func softwareKeyboardWentAway() {
        softwareKeyboardVisible = false
        releaseKeyBar()
        // This can happen while SwiftUI updates views (a sheet's field taking focus), so publish afterwards.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.softwareKeyboardVisible else { return }
            self.handle?.keyboardVisible = false
        }
    }

    // MARK: Key bar

    private var keyBar: MoonlightKeyBarView {
        if let keyBarView { return keyBarView }
        let bar = MoonlightKeyBarView()
        bar.onModifierTap = { [weak self] modifier in self?.updateKeys { $0.tap(modifier, at: CACurrentMediaTime()) } }
        bar.onModifierLock = { [weak self] modifier in self?.updateKeys { $0.lock(modifier) } }
        bar.onKeyDown = { [weak self] key in self?.updateKeys { $0.press(key) } }
        bar.onKeyUp = { [weak self] key in self?.updateKeys { $0.release(key) } }
        bar.onShortcut = { [weak self] shortcut in self?.updateKeys { $0.perform(shortcut.chord) } }
        bar.onHideKeyboard = { [weak self] in self?.setSoftwareKeyboard(visible: false) }
        bar.show(keyLatch)
        keyBarView = bar
        return bar
    }

    /// Changes the key latch, sends what the change produced and shows the modifiers' new state.
    private func updateKeys(_ change: (inout MoonlightModifierLatch) -> [MoonlightKeyOutput]) {
        let outputs = change(&keyLatch)
        for output in outputs {
            switch output {
            case let .key(key, pressed, modifiers): session?.sendKey(virtualKey: key, pressed: pressed, modifiers: modifiers)
            case let .text(text): session?.sendText(text)
            }
            keyOutputObserver?(output)
        }
        keyBarView?.show(keyLatch)
    }

    /// Lets go of every latched modifier and held bar key on the PC, so nothing stays stuck down.
    private func releaseKeyBar() {
        guard !keyLatch.isIdle else { return }
        updateKeys { $0.releaseAll() }
    }

    private func resetKeyBar() {
        keyLatch = MoonlightModifierLatch()
        keyBarView?.show(keyLatch)
    }

    @objc private func applicationWillResignActive() {
        releaseKeyBar()
    }
    #endif
}

extension MoonlightStreamSurfaceView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Long press + pan together make drag-and-drop possible.
        (gestureRecognizer === longPressRecognizer && otherGestureRecognizer === panRecognizer)
            || (gestureRecognizer === panRecognizer && otherGestureRecognizer === longPressRecognizer)
    }
}

#if os(iOS)
extension MoonlightStreamSurfaceView: UIKeyInput {
    public var hasText: Bool { true }

    /// Plain text (any language) as before; while a key bar modifier is latched, key presses with it (Ctrl + c).
    public func insertText(_ text: String) {
        updateKeys { $0.type(text) }
    }

    public func deleteBackward() {
        updateKeys { $0.deleteBackward() }
    }

    public var keyboardAppearance: UIKeyboardAppearance { get { .dark } set {} }
    public var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    public var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    public var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    public var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    public var smartDashesType: UITextSmartDashesType { get { .no } set {} }
}
#endif

public struct MoonlightStreamSurface: UIViewRepresentable {
    public var session: MoonlightStreamSession
    public var settings: MoonlightStreamSettings
    public var handle: MoonlightSurfaceHandle
    public var onToggleOverlay: () -> Void
    public var onEndStream: (() -> Void)?

    public init(session: MoonlightStreamSession, settings: MoonlightStreamSettings, handle: MoonlightSurfaceHandle,
                onToggleOverlay: @escaping () -> Void, onEndStream: (() -> Void)? = nil) {
        self.session = session
        self.settings = settings
        self.handle = handle
        self.onToggleOverlay = onToggleOverlay
        self.onEndStream = onEndStream
    }

    public func makeUIView(context: Context) -> MoonlightStreamSurfaceView {
        let view = MoonlightStreamSurfaceView(frame: .zero)
        view.handle = handle
        view.session = session
        view.settings = settings
        view.onToggleOverlay = onToggleOverlay
        handle.view = view
        return view
    }

    public func updateUIView(_ view: MoonlightStreamSurfaceView, context: Context) {
        view.settings = settings
        view.onToggleOverlay = onToggleOverlay
        if view.session !== session { view.session = session }
    }
}

#elseif canImport(AppKit)
import AppKit

/// Hosts the video layer; a click captures the mouse (relative movement, hidden cursor) and the
/// keyboard. Control+Option+Shift+Z or the overlay button releases them, Control+Option+Shift+F
/// toggles full screen and Control+Option+Shift+Q ends the stream.
public final class MoonlightStreamSurfaceView: NSView {
    weak var handle: MoonlightSurfaceHandle?
    var onToggleOverlay: (() -> Void)?
    /// ⌃⌥⇧Q: end the stream without hunting for the overlay.
    var onEndStream: (() -> Void)?
    public var session: MoonlightStreamSession? { didSet { attachLayer() } }
    public var settings = MoonlightStreamSettings()
    public private(set) var isCaptured = false

    private var videoLayer: AVSampleBufferDisplayLayer?
    private var modifierState = NSEvent.ModifierFlags()
    private var windowObservers: [NSObjectProtocol] = []
    /// Keys pressed as part of an Orbit chord; their key-up is swallowed too. Readable for tests.
    private(set) var chordKeys = Set<UInt16>()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            // Also forgets held chord keys: their key-ups go to whichever window is key now.
            self?.releaseCapture()
        })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.fullScreenChanged()
            })
        }
        // SwiftUI moves the view into its window while it updates views, where publishing is not allowed.
        DispatchQueue.main.async { [weak self] in self?.publishFullScreen() }
    }

    // MARK: Full screen

    public func toggleFullScreen() {
        guard let window else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    private func publishFullScreen() {
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if handle?.isFullScreen != fullScreen { handle?.isFullScreen = fullScreen }
    }

    private func fullScreenChanged() {
        publishFullScreen()
        // The window moved and resized; keep the hidden cursor over the video so clicks stay in the stream.
        if isCaptured { parkCursor() }
    }

    private func attachLayer() {
        videoLayer?.removeFromSuperlayer()
        guard let session else { videoLayer = nil; return }
        install(session.renderer.displayLayer)
        session.renderer.onLayerReplaced = { [weak self] fresh in self?.install(fresh) }
    }

    private func install(_ fresh: AVSampleBufferDisplayLayer) {
        videoLayer?.removeFromSuperlayer()
        fresh.frame = bounds
        layer?.addSublayer(fresh)
        videoLayer = fresh
    }

    // MARK: Capture

    public func capture() {
        guard !isCaptured else { return }
        isCaptured = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        parkCursor()
        window?.makeFirstResponder(self)
        handle?.mouseCaptured = true
    }

    /// Puts the hidden cursor over the middle of the view so it never leaves the window.
    private func parkCursor() {
        guard let window else { return }
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: center)
        // Core Graphics measures from the top of the primary display (the one with the menu bar), whichever
        // display the window is on.
        guard let primary = NSScreen.screens.first ?? window.screen else { return }
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y))
    }

    public func releaseCapture() {
        // The PC no longer gets keys, so no chord key-up needs swallowing either.
        chordKeys.removeAll()
        guard isCaptured else { return }
        isCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        releaseModifiers()
        handle?.mouseCaptured = false
    }

    private func releaseModifiers() {
        guard let session else { return }
        for (flag, key) in Self.modifierKeys where modifierState.contains(flag) {
            session.sendKey(virtualKey: key, pressed: false)
        }
        modifierState = []
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard isCaptured else { capture(); return }
        session?.sendMouseButton(.left, pressed: true)
    }
    public override func mouseUp(with event: NSEvent) { if isCaptured { session?.sendMouseButton(.left, pressed: false) } }
    public override func rightMouseDown(with event: NSEvent) { if isCaptured { session?.sendMouseButton(.right, pressed: true) } }
    public override func rightMouseUp(with event: NSEvent) { if isCaptured { session?.sendMouseButton(.right, pressed: false) } }
    public override func otherMouseDown(with event: NSEvent) { if isCaptured, let button = Self.button(for: event) { session?.sendMouseButton(button, pressed: true) } }
    public override func otherMouseUp(with event: NSEvent) { if isCaptured, let button = Self.button(for: event) { session?.sendMouseButton(button, pressed: false) } }
    public override func mouseMoved(with event: NSEvent) { relativeMove(event) }
    public override func mouseDragged(with event: NSEvent) { relativeMove(event) }
    public override func rightMouseDragged(with event: NSEvent) { relativeMove(event) }
    public override func otherMouseDragged(with event: NSEvent) { relativeMove(event) }

    private func relativeMove(_ event: NSEvent) {
        guard isCaptured else { return }
        session?.sendMouseMove(dx: Int(event.deltaX.rounded()), dy: Int(event.deltaY.rounded()))
    }

    private static func button(for event: NSEvent) -> MoonlightMouseButton? {
        switch event.buttonNumber {
        case 2: return .middle
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isCaptured, let session else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 120
        session.sendScroll(vertical: Int((event.scrollingDeltaY * factor).rounded()), horizontal: Int((-event.scrollingDeltaX * factor).rounded()))
    }

    // MARK: Keyboard

    private static let modifierKeys: [(NSEvent.ModifierFlags, Int16)] = [
        (.shift, 0xA0), (.control, 0xA2), (.option, 0xA4), (.command, 0x5B), (.capsLock, 0x14)
    ]

    public override func keyDown(with event: NSEvent) {
        if handleChord(event) { return }
        if chordKeys.contains(event.keyCode) {
            // Still held from a chord after the modifiers went up: its repeats are not for the PC either.
            if event.isARepeat { return }
            // A fresh press whose chord key-up never arrived: this press gets its own key-up.
            chordKeys.remove(event.keyCode)
        }
        guard isCaptured else { super.keyDown(with: event); return }
        guard let virtualKey = MoonlightVirtualKey.fromMacKeyCode(event.keyCode) else { return }
        session?.sendKey(virtualKey: virtualKey, pressed: true, modifiers: Self.modifiers(event.modifierFlags))
    }

    /// Orbit's own Control-Option-Shift chords. They work with or without capture and never reach the PC.
    private func handleChord(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains([.control, .option, .shift]) else { return false }
        switch event.keyCode {
        case 0x06: releaseCapture()                    // Z: give the mouse and keyboard back
        case 0x0C: releaseCapture(); onEndStream?()    // Q: end the stream
        case 0x03: if !event.isARepeat { toggleFullScreen() }   // F: full screen on or off
        default: return false
        }
        chordKeys.insert(event.keyCode)
        return true
    }

    public override func keyUp(with event: NSEvent) {
        // The PC never saw the chord's key go down, so it does not get the key going up either.
        if chordKeys.remove(event.keyCode) != nil { return }
        guard isCaptured, let virtualKey = MoonlightVirtualKey.fromMacKeyCode(event.keyCode) else { return }
        session?.sendKey(virtualKey: virtualKey, pressed: false, modifiers: Self.modifiers(event.modifierFlags))
    }

    public override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isCaptured, let session else { modifierState = flags; return }
        for (flag, key) in Self.modifierKeys where flags.contains(flag) != modifierState.contains(flag) {
            // Prefer the exact left/right key the event names when we have it.
            let specific = MoonlightVirtualKey.fromMacKeyCode(event.keyCode) ?? key
            session.sendKey(virtualKey: specific, pressed: flags.contains(flag), modifiers: Self.modifiers(flags))
        }
        modifierState = flags
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCaptured else { return super.performKeyEquivalent(with: event) }
        if event.type == .keyDown { keyDown(with: event) } else if event.type == .keyUp { keyUp(with: event) }
        return true
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> MoonlightKeyModifiers {
        var modifiers = MoonlightKeyModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.meta) }
        return modifiers
    }
}

public struct MoonlightStreamSurface: NSViewRepresentable {
    public var session: MoonlightStreamSession
    public var settings: MoonlightStreamSettings
    public var handle: MoonlightSurfaceHandle
    public var onToggleOverlay: () -> Void
    public var onEndStream: (() -> Void)?

    public init(session: MoonlightStreamSession, settings: MoonlightStreamSettings, handle: MoonlightSurfaceHandle,
                onToggleOverlay: @escaping () -> Void, onEndStream: (() -> Void)? = nil) {
        self.session = session
        self.settings = settings
        self.handle = handle
        self.onToggleOverlay = onToggleOverlay
        self.onEndStream = onEndStream
    }

    public func makeNSView(context: Context) -> MoonlightStreamSurfaceView {
        let view = MoonlightStreamSurfaceView(frame: .zero)
        view.handle = handle
        view.session = session
        view.settings = settings
        view.onToggleOverlay = onToggleOverlay
        view.onEndStream = onEndStream
        handle.view = view
        return view
    }

    public func updateNSView(_ view: MoonlightStreamSurfaceView, context: Context) {
        view.settings = settings
        view.onToggleOverlay = onToggleOverlay
        view.onEndStream = onEndStream
        if view.session !== session { view.session = session }
    }
}
#endif
