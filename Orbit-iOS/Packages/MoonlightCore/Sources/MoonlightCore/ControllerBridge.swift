import Foundation
import GameController
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Forwards connected game controllers (and the Siri Remote on tvOS) to the host and plays rumble.
final class MoonlightControllerBridge {
    private var observers: [NSObjectProtocol] = []
    private var slots: [ObjectIdentifier: Int] = [:]
    private var controllers: [Int: GCController] = [:]
    private var rumblers: [Int: MoonlightRumble] = [:]
    private var remoteLastPoint: CGPoint?
    private var active = false

    private var activeMask: Int16 { controllers.keys.reduce(Int16(0)) { $0 | Int16(1 << $1) } }

    @MainActor
    func start() {
        guard !active else { return }
        active = true
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.detach(controller) }
        })
        GCController.controllers().forEach(attach)
    }

    @MainActor
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in controllers.values {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.dpad.valueChangedHandler = nil
            controller.microGamepad?.buttonA.pressedChangedHandler = nil
            controller.microGamepad?.buttonX.pressedChangedHandler = nil
        }
        rumblers.values.forEach { $0.stop() }
        rumblers.removeAll()
        controllers.removeAll()
        slots.removeAll()
        remoteLastPoint = nil
        active = false
    }

    /// Called from a library thread.
    func rumble(controller index: UInt16, low: UInt16, high: UInt16) {
        DispatchQueue.main.async { [self] in
            guard active, let controller = controllers[Int(index)] else { return }
            if rumblers[Int(index)] == nil { rumblers[Int(index)] = MoonlightRumble(controller: controller) }
            rumblers[Int(index)]?.set(intensity: Float(max(low, high)) / 65535)
        }
    }

    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard slots[key] == nil else { return }
        if let pad = controller.extendedGamepad {
            guard let slot = (0..<4).first(where: { controllers[$0] == nil }) else { return }
            slots[key] = slot
            controllers[slot] = controller
            let type: Int32
            if pad is GCXboxGamepad { type = LI_CTYPE_XBOX }
            else if pad is GCDualShockGamepad || pad is GCDualSenseGamepad { type = LI_CTYPE_PS }
            else if controller.productCategory.localizedCaseInsensitiveContains("switch") || controller.productCategory.localizedCaseInsensitiveContains("nintendo") { type = LI_CTYPE_NINTENDO }
            else { type = LI_CTYPE_UNKNOWN }
            var capabilities = Int32(LI_CCAP_ANALOG_TRIGGERS)
            if controller.haptics != nil { capabilities |= LI_CCAP_RUMBLE }
            var supported = A_FLAG | B_FLAG | X_FLAG | Y_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG | LB_FLAG | RB_FLAG
                | PLAY_FLAG | BACK_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG
            if pad is GCDualShockGamepad || pad is GCDualSenseGamepad { supported |= TOUCHPAD_FLAG }
            LiSendControllerArrivalEvent(UInt8(slot), UInt16(bitPattern: activeMask), UInt8(type), UInt32(supported), UInt16(capabilities))
            pad.valueChangedHandler = { [weak self] pad, _ in self?.send(pad, slot: slot) }
            send(pad, slot: slot)
        } else if let micro = controller.microGamepad {
            attachRemote(controller, micro)
        }
    }

    private func detach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard let slot = slots.removeValue(forKey: key) else { return }
        controllers.removeValue(forKey: slot)
        rumblers.removeValue(forKey: slot)?.stop()
        // Zeroed state with the updated mask tells the host the pad is gone.
        LiSendMultiControllerEvent(Int16(slot), activeMask, 0, 0, 0, 0, 0, 0, 0)
    }

    private func send(_ pad: GCExtendedGamepad, slot: Int) {
        var flags: Int32 = 0
        if pad.buttonA.isPressed { flags |= A_FLAG }
        if pad.buttonB.isPressed { flags |= B_FLAG }
        if pad.buttonX.isPressed { flags |= X_FLAG }
        if pad.buttonY.isPressed { flags |= Y_FLAG }
        if pad.dpad.up.isPressed { flags |= UP_FLAG }
        if pad.dpad.down.isPressed { flags |= DOWN_FLAG }
        if pad.dpad.left.isPressed { flags |= LEFT_FLAG }
        if pad.dpad.right.isPressed { flags |= RIGHT_FLAG }
        if pad.leftShoulder.isPressed { flags |= LB_FLAG }
        if pad.rightShoulder.isPressed { flags |= RB_FLAG }
        if pad.buttonMenu.isPressed { flags |= PLAY_FLAG }
        if pad.buttonOptions?.isPressed == true { flags |= BACK_FLAG }
        if pad.buttonHome?.isPressed == true { flags |= SPECIAL_FLAG }
        if pad.leftThumbstickButton?.isPressed == true { flags |= LS_CLK_FLAG }
        if pad.rightThumbstickButton?.isPressed == true { flags |= RS_CLK_FLAG }
        if let dualShock = pad as? GCDualShockGamepad, dualShock.touchpadButton.isPressed { flags |= TOUCHPAD_FLAG }
        if let dualSense = pad as? GCDualSenseGamepad, dualSense.touchpadButton.isPressed { flags |= TOUCHPAD_FLAG }

        func trigger(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        func axis(_ value: Float) -> Int16 { Int16(max(-32768, min(32767, (value * 32767).rounded()))) }
        LiSendMultiControllerEvent(Int16(slot), activeMask, flags,
                                   trigger(pad.leftTrigger.value), trigger(pad.rightTrigger.value),
                                   axis(pad.leftThumbstick.xAxis.value), axis(pad.leftThumbstick.yAxis.value),
                                   axis(pad.rightThumbstick.xAxis.value), axis(pad.rightThumbstick.yAxis.value))
    }

    /// Siri Remote: the touch surface moves the pointer, click is a left click, play/pause a right click.
    private func attachRemote(_ controller: GCController, _ micro: GCMicroGamepad) {
        slots[ObjectIdentifier(controller)] = -1
        micro.reportsAbsoluteDpadValues = true
        micro.allowsRotation = true
        micro.dpad.valueChangedHandler = { [weak self] _, x, y in self?.remoteMoved(x: x, y: y) }
        micro.buttonA.pressedChangedHandler = { _, _, pressed in LiSendMouseButtonEvent(pressed ? 0x07 : 0x08, BUTTON_LEFT) }
        micro.buttonX.pressedChangedHandler = { _, _, pressed in LiSendMouseButtonEvent(pressed ? 0x07 : 0x08, BUTTON_RIGHT) }
    }

    private func remoteMoved(x: Float, y: Float) {
        if x == 0, y == 0 { remoteLastPoint = nil; return }
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        defer { remoteLastPoint = point }
        guard let last = remoteLastPoint else { return }
        let dx = Int(((point.x - last.x) * 900).rounded())
        let dy = Int(((last.y - point.y) * 900).rounded())
        if dx != 0 || dy != 0 { LiSendMouseMoveEvent(Int16(clamping: dx), Int16(clamping: dy)) }
    }
}

/// Continuous haptic player driven by the host's rumble values.
final class MoonlightRumble {
    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var playing = false

    init(controller: GCController) {
        engine = controller.haptics?.createEngine(withLocality: .default)
        try? engine?.start()
    }

    func set(intensity: Float) {
        guard let engine else { return }
        if intensity <= 0.02 {
            if playing { try? player?.stop(atTime: CHHapticTimeImmediate); playing = false }
            return
        }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                                      relativeTime: 0, duration: 3600)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []) {
                player = try? engine.makeAdvancedPlayer(with: pattern)
            }
        }
        guard let player else { return }
        if !playing {
            try? engine.start()
            try? player.start(atTime: CHHapticTimeImmediate)
            playing = true
        }
        try? player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)],
                                   atTime: CHHapticTimeImmediate)
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop(completionHandler: nil)
        playing = false
    }
    #else
    init(controller: GCController) {}
    func set(intensity: Float) {}
    func stop() {}
    #endif
}
