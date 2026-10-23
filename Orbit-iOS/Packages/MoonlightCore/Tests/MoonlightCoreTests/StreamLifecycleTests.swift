import Foundation
import GameController
import XCTest
@testable import MoonlightCore
#if os(macOS)
import AppKit
#endif

/// What happens around a stream's start and end: controller handlers handed from one stream to the next,
/// and (on the Mac) Orbit's own keyboard chords never leaving a key held on the PC.
final class StreamLifecycleTests: XCTestCase {
    // MARK: Controllers

    @MainActor
    func testAStreamTornDownLateLeavesTheNextStreamsControllerHandlers() throws {
        let pad = GCController.withExtendedGamepad()
        guard let gamepad = pad.extendedGamepad else { throw XCTSkip("No virtual gamepad here") }
        let first = MoonlightControllerBridge()
        first.start()
        first.attach(pad)
        XCTAssertNotNil(gamepad.valueChangedHandler)
        XCTAssertTrue(first.ownsControllers)

        // A second stream starts before the first one's teardown has run.
        let second = MoonlightControllerBridge()
        second.start()
        second.attach(pad)
        XCTAssertTrue(second.ownsControllers)
        XCTAssertFalse(first.ownsControllers)

        first.stop()
        XCTAssertNotNil(gamepad.valueChangedHandler, "the first stream's late teardown must not clear the second stream's handler")
        XCTAssertTrue(second.ownsControllers)

        second.stop()
        XCTAssertNil(gamepad.valueChangedHandler, "the stream that owns the handlers clears them when it ends")
        XCTAssertFalse(second.ownsControllers)
    }

    @MainActor
    func testStoppingTheOnlyStreamClearsItsHandlers() throws {
        let pad = GCController.withExtendedGamepad()
        guard let gamepad = pad.extendedGamepad else { throw XCTSkip("No virtual gamepad here") }
        let bridge = MoonlightControllerBridge()
        bridge.start()
        bridge.attach(pad)
        XCTAssertNotNil(gamepad.valueChangedHandler)
        bridge.stop()
        XCTAssertNil(gamepad.valueChangedHandler)
        bridge.stop()   // a second stop is harmless
        XCTAssertNil(gamepad.valueChangedHandler)
    }

    // MARK: Mac keyboard chords

    #if os(macOS)
    /// Stands in for the rest of the responder chain so plain keys that are not forwarded do not beep.
    private final class QuietResponder: NSResponder {
        var keyDowns = 0
        override func keyDown(with event: NSEvent) { keyDowns += 1 }
        override func keyUp(with event: NSEvent) {}
    }

    private let chord: NSEvent.ModifierFlags = [.control, .option, .shift]
    private let keyF: UInt16 = 0x03
    private let keyZ: UInt16 = 0x06

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) throws -> NSEvent {
        let character = code == keyF ? "f" : "z"
        return try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                              characters: character, charactersIgnoringModifiers: character, isARepeat: isRepeat, keyCode: code))
    }

    @MainActor
    private func makeSurface() -> (MoonlightStreamSurfaceView, QuietResponder) {
        let view = MoonlightStreamSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let next = QuietResponder()
        view.nextResponder = next
        return (view, next)
    }

    @MainActor
    func testAChordKeyWhoseKeyUpWentMissingGetsItsNextKeyUp() throws {
        let (view, next) = makeSurface()
        view.keyDown(with: try key(.keyDown, keyF, chord))   // toggles full screen (no window here) and is remembered
        XCTAssertEqual(view.chordKeys, [keyF])

        // The key-up was lost (the window changed Space); the next plain press must not inherit the swallowing.
        view.keyDown(with: try key(.keyDown, keyF))
        XCTAssertTrue(view.chordKeys.isEmpty)
        XCTAssertEqual(next.keyDowns, 1, "a plain press is handled normally")
    }

    @MainActor
    func testAChordKeyStillHeldAfterTheModifiersAreUpDoesNotRepeatToThePC() throws {
        let (view, next) = makeSurface()
        view.keyDown(with: try key(.keyDown, keyF, chord))
        view.keyDown(with: try key(.keyDown, keyF, repeat: true))
        XCTAssertEqual(view.chordKeys, [keyF], "auto-repeat of the chord key is swallowed")
        XCTAssertEqual(next.keyDowns, 0)
        view.keyUp(with: try key(.keyUp, keyF))
        XCTAssertTrue(view.chordKeys.isEmpty, "its key-up is swallowed once and forgotten")
    }

    @MainActor
    func testReleasingCaptureForgetsHeldChordKeys() throws {
        let (view, _) = makeSurface()
        view.keyDown(with: try key(.keyDown, keyZ, chord))   // Z releases capture, then remembers the key
        XCTAssertEqual(view.chordKeys, [keyZ])
        view.releaseCapture()   // what losing key-window status does
        XCTAssertTrue(view.chordKeys.isEmpty)
    }
    #endif
}
