import XCTest
@testable import MoonlightCore

/// The key bar above the software keyboard: latching modifiers, what typed characters turn into while one is
/// latched, the one-tap shortcuts and the row itself.
final class KeyBarTests: XCTestCase {
    private let win = MoonlightModifierKey.windows.virtualKey
    private let ctrl = MoonlightModifierKey.control.virtualKey
    private let alt = MoonlightModifierKey.alt.virtualKey
    private let shift = MoonlightModifierKey.shift.virtualKey
    private let keyC: Int16 = 0x43
    private let keyD: Int16 = 0x44
    private let keyV: Int16 = 0x56

    private func down(_ key: Int16, _ modifiers: MoonlightKeyModifiers = []) -> MoonlightKeyOutput { .key(key, pressed: true, modifiers: modifiers) }
    private func up(_ key: Int16, _ modifiers: MoonlightKeyModifiers = []) -> MoonlightKeyOutput { .key(key, pressed: false, modifiers: modifiers) }

    // MARK: Latching

    func testATapAppliesToTheNextKeyOnly() {
        var latch = MoonlightModifierLatch()
        XCTAssertEqual(latch.tap(.control, at: 0), [down(ctrl, .control)], "the modifier goes down on the PC right away")
        XCTAssertEqual(latch.state(of: .control), .oneShot)
        XCTAssertEqual(latch.held, .control)

        XCTAssertEqual(latch.type("c"), [down(keyC, .control), up(keyC, .control), up(ctrl)], "Ctrl + typed c is Ctrl+C, then Ctrl lets go")
        XCTAssertEqual(latch.state(of: .control), .off)
        XCTAssertEqual(latch.type("c"), [.text("c")], "the next character is plain text again")
    }

    func testADoubleTapLocksUntilTappedAgain() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.control, at: 10)
        XCTAssertEqual(latch.tap(.control, at: 10.2), [], "locking keeps the key down, nothing new is sent")
        XCTAssertEqual(latch.state(of: .control), .locked)

        XCTAssertEqual(latch.type("c"), [down(keyC, .control), up(keyC, .control)])
        XCTAssertEqual(latch.type("v"), [down(keyV, .control), up(keyV, .control)], "a locked modifier stays down between keys")
        XCTAssertEqual(latch.state(of: .control), .locked)

        XCTAssertEqual(latch.tap(.control, at: 20), [up(ctrl)])
        XCTAssertEqual(latch.state(of: .control), .off)
        XCTAssertTrue(latch.isIdle)
    }

    func testTheDoubleTapWindowIsInclusiveAndASlowSecondTapTurnsTheModifierOff() {
        var quick = MoonlightModifierLatch()
        _ = quick.tap(.shift, at: 1)
        _ = quick.tap(.shift, at: 1 + MoonlightModifierLatch.doubleTapInterval)
        XCTAssertEqual(quick.state(of: .shift), .locked)

        var slow = MoonlightModifierLatch()
        _ = slow.tap(.shift, at: 1)
        XCTAssertEqual(slow.tap(.shift, at: 1.5), [up(shift)])
        XCTAssertEqual(slow.state(of: .shift), .off)

        var skewed = MoonlightModifierLatch()
        _ = skewed.tap(.shift, at: 5)
        XCTAssertEqual(skewed.tap(.shift, at: 4.9), [up(shift)], "a clock going backwards never locks")
    }

    func testWindowsTappedOnAndOffWithoutAKeyIsAPressOfItsOwn() {
        var latch = MoonlightModifierLatch()
        // On a PC keyboard pressing and releasing Win alone opens Start; the bar behaves the same way.
        XCTAssertEqual(latch.tap(.windows, at: 0), [down(win, .meta)])
        XCTAssertEqual(latch.tap(.windows, at: 2), [up(win)])
        XCTAssertTrue(latch.isIdle)
    }

    func testVoiceOverCanLockDirectly() {
        var latch = MoonlightModifierLatch()
        XCTAssertEqual(latch.lock(.alt), [down(alt, .alt)])
        XCTAssertEqual(latch.state(of: .alt), .locked)
        XCTAssertEqual(latch.lock(.alt), [])
        XCTAssertEqual(latch.tap(.alt, at: 0), [up(alt)])

        _ = latch.tap(.alt, at: 50)
        XCTAssertEqual(latch.lock(.alt), [], "a one-shot modifier is already down")
        XCTAssertEqual(latch.state(of: .alt), .locked)
    }

    func testSeveralOneShotModifiersCombineAndLetGoTogether() {
        var latch = MoonlightModifierLatch()
        XCTAssertEqual(latch.tap(.control, at: 0), [down(ctrl, .control)])
        XCTAssertEqual(latch.tap(.alt, at: 0.1), [down(alt, [.control, .alt])])
        XCTAssertEqual(latch.type("t"), [down(0x54, [.control, .alt]), up(0x54, [.control, .alt]), up(alt, .control), up(ctrl)])
        XCTAssertTrue(latch.isIdle)
    }

    // MARK: Typing while latched

    func testCharactersThatNeedShiftGetItAroundTheKey() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.control, at: 0)
        XCTAssertEqual(latch.type("C"), [down(shift, [.control, .shift]), down(keyC, [.control, .shift]), up(keyC, [.control, .shift]),
                                          up(shift, .control), up(ctrl)])
    }

    func testALatchedShiftIsNotPressedTwice() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.shift, at: 0)
        _ = latch.tap(.shift, at: 0.1)
        XCTAssertEqual(latch.type("A"), [down(0x41, .shift), up(0x41, .shift)])
        XCTAssertEqual(latch.type("1"), [down(0x31, .shift), up(0x31, .shift)], "Shift applies to whatever is typed, like on a PC")
    }

    func testAOneShotModifierCoversTheFirstCharacterOfAPaste() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.control, at: 0)
        XCTAssertEqual(latch.type("cv"), [down(keyC, .control), up(keyC, .control), up(ctrl), .text("v")])
    }

    func testCharactersWithoutAKeyStillGoOutAsTextAndUseTheLatch() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.alt, at: 0)
        XCTAssertEqual(latch.type("ș"), [.text("ș"), up(alt)])
        XCTAssertTrue(latch.isIdle)
    }

    func testNewlineSpaceAndBackspaceTakeTheLatchToo() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.alt, at: 0)
        XCTAssertEqual(latch.type("\n"), [down(MoonlightVirtualKey.enter, .alt), up(MoonlightVirtualKey.enter, .alt), up(alt)], "Alt+Enter")
        _ = latch.tap(.windows, at: 1)
        XCTAssertEqual(latch.type(" "), [down(MoonlightVirtualKey.space, .meta), up(MoonlightVirtualKey.space, .meta), up(win)], "Win+Space")
        _ = latch.tap(.control, at: 2)
        XCTAssertEqual(latch.deleteBackward(), [down(MoonlightVirtualKey.back, .control), up(MoonlightVirtualKey.back, .control), up(ctrl)],
                       "Ctrl+Backspace deletes a word")
    }

    func testWithNothingLatchedTypingIsUnchanged() {
        var latch = MoonlightModifierLatch()
        XCTAssertEqual(latch.type("Hello, ăîș 👋"), [.text("Hello, ăîș 👋")])
        XCTAssertEqual(latch.type("\n"), [down(MoonlightVirtualKey.enter), up(MoonlightVirtualKey.enter)])
        XCTAssertEqual(latch.type("line\nbreak"), [.text("line\nbreak")])
        XCTAssertEqual(latch.type(""), [])
        XCTAssertEqual(latch.deleteBackward(), [down(MoonlightVirtualKey.back), up(MoonlightVirtualKey.back)])
    }

    // MARK: Bar keys

    func testBarKeysGoDownAndUpWithTheFinger() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.shift, at: 0)
        XCTAssertEqual(latch.press(0x25), [down(0x25, .shift)])
        XCTAssertEqual(latch.press(0x25), [], "a key that is already down is not pressed again")
        XCTAssertEqual(latch.pressedKeys, [0x25])
        XCTAssertEqual(latch.release(0x25), [up(0x25, .shift), up(shift)], "Shift+← selects, then Shift lets go")
        XCTAssertEqual(latch.release(0x25), [], "a key that is not down is not released again")
    }

    func testLockedAltWalksTheAppSwitcher() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.alt, at: 0)
        _ = latch.tap(.alt, at: 0.1)
        var sent: [MoonlightKeyOutput] = []
        for _ in 0..<3 { sent += latch.press(MoonlightVirtualKey.tab) + latch.release(MoonlightVirtualKey.tab) }
        XCTAssertEqual(sent, Array(repeating: [down(MoonlightVirtualKey.tab, .alt), up(MoonlightVirtualKey.tab, .alt)], count: 3).flatMap { $0 })
        XCTAssertEqual(latch.tap(.alt, at: 3), [up(alt)], "letting go of Alt picks the window")
    }

    func testHidingTheKeyboardLetsGoOfEverything() {
        var latch = MoonlightModifierLatch()
        _ = latch.lock(.alt)
        _ = latch.tap(.control, at: 0)
        _ = latch.press(MoonlightVirtualKey.tab)
        XCTAssertEqual(latch.releaseAll(), [up(MoonlightVirtualKey.tab, [.control, .alt]), up(alt, .control), up(ctrl)])
        XCTAssertTrue(latch.isIdle)
        XCTAssertEqual(latch.release(MoonlightVirtualKey.tab), [], "the finger lifting afterwards sends nothing")
        XCTAssertEqual(latch.releaseAll(), [])
    }

    func testAHardwareKeyUsesUpOnlyOneShotModifiers() {
        var latch = MoonlightModifierLatch()
        _ = latch.lock(.shift)
        _ = latch.tap(.control, at: 0)
        XCTAssertTrue(latch.hasOneShot)
        XCTAssertEqual(latch.releaseOneShots(), [up(ctrl, .shift)])
        XCTAssertEqual(latch.releaseOneShots(), [])
        XCTAssertEqual(latch.state(of: .shift), .locked)
        XCTAssertFalse(latch.hasOneShot)
    }

    // MARK: Shortcuts

    func testShortcutKeyMap() {
        let expected: [MoonlightKeyBarShortcut: (MoonlightKeyChord, String)] = [
            .switchApp: (MoonlightKeyChord([.alt], 0x09), "Alt+Tab"),
            .taskView: (MoonlightKeyChord([.windows], 0x09), "Win+Tab"),
            .desktop: (MoonlightKeyChord([.windows], 0x44), "Win+D"),
            .gameBar: (MoonlightKeyChord([.windows], 0x47), "Win+G"),
            .taskManager: (MoonlightKeyChord([.control, .shift], 0x1B), "Ctrl+Shift+Esc"),
            .screenshot: (MoonlightKeyChord([], 0x2C), "PrtSc"),
            .closeWindow: (MoonlightKeyChord([.alt], 0x73), "Alt+F4"),
        ]
        XCTAssertEqual(Set(expected.keys), Set(MoonlightKeyBarShortcut.allCases))
        for (shortcut, (chord, caption)) in expected {
            XCTAssertEqual(shortcut.chord, chord, "\(shortcut)")
            XCTAssertEqual(shortcut.chord.caption, caption, "\(shortcut)")
            XCTAssertEqual(shortcut.needsConfirmation, shortcut == .closeWindow, "only Alt+F4 asks first")
            XCTAssertFalse(shortcut.title.isEmpty)
            XCTAssertFalse(shortcut.spokenName.isEmpty)
        }
    }

    func testShortcutsPressTheirModifiersAroundTheKey() {
        var latch = MoonlightModifierLatch()
        XCTAssertEqual(latch.perform(MoonlightKeyBarShortcut.desktop.chord), [down(win, .meta), down(keyD, .meta), up(keyD, .meta), up(win)])
        XCTAssertEqual(latch.perform(MoonlightKeyBarShortcut.taskManager.chord),
                       [down(ctrl, .control), down(shift, [.control, .shift]), down(0x1B, [.control, .shift]), up(0x1B, [.control, .shift]),
                        up(shift, .control), up(ctrl)])
        XCTAssertEqual(latch.perform(MoonlightKeyBarShortcut.screenshot.chord), [down(0x2C), up(0x2C)])
        XCTAssertTrue(latch.isIdle)
    }

    func testALatchedModifierJoinsAShortcut() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.shift, at: 0)
        XCTAssertEqual(latch.perform(MoonlightKeyBarShortcut.switchApp.chord),
                       [down(alt, [.alt, .shift]), down(0x09, [.alt, .shift]), up(0x09, [.alt, .shift]), up(alt, .shift), up(shift)],
                       "Shift + Alt+Tab goes backwards through the apps")
    }

    func testAShortcutDoesNotPressALatchedModifierAgain() {
        var latch = MoonlightModifierLatch()
        _ = latch.tap(.windows, at: 0)
        XCTAssertEqual(latch.perform(MoonlightKeyBarShortcut.desktop.chord), [down(keyD, .meta), up(keyD, .meta), up(win)])
    }

    // MARK: Mapping and layout

    func testTypedCharactersMapToUSKeys() {
        func key(_ character: Character) -> [Int16]? { MoonlightVirtualKey.fromCharacter(character).map { [$0.virtualKey, $0.shift ? 1 : 0] } }
        XCTAssertEqual(key("a"), [0x41, 0])
        XCTAssertEqual(key("z"), [0x5A, 0])
        XCTAssertEqual(key("Z"), [0x5A, 1])
        XCTAssertEqual(key("0"), [0x30, 0])
        XCTAssertEqual(key("9"), [0x39, 0])
        XCTAssertEqual(key("!"), [0x31, 1])
        XCTAssertEqual(key(")"), [0x30, 1])
        XCTAssertEqual(key("/"), [0xBF, 0])
        XCTAssertEqual(key("?"), [0xBF, 1])
        XCTAssertEqual(key("-"), [0xBD, 0])
        XCTAssertEqual(key("~"), [0xC0, 1])
        XCTAssertEqual(key(" "), [MoonlightVirtualKey.space, 0])
        XCTAssertEqual(key("\n"), [MoonlightVirtualKey.enter, 0])
        XCTAssertEqual(key("\r\n"), [MoonlightVirtualKey.enter, 0])
        XCTAssertEqual(key("\t"), [MoonlightVirtualKey.tab, 0])
        XCTAssertNil(key("ș"))
        XCTAssertNil(key("é"))
        XCTAssertNil(key("👋"))
    }

    func testModifierKeysAreRecognised() {
        for key: Int16 in [0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5] {
            XCTAssertTrue(MoonlightVirtualKey.isModifier(key), "VK \(key)")
        }
        for key: Int16 in [0x09, 0x0D, 0x1B, 0x25, 0x2E, 0x41, 0x70] {
            XCTAssertFalse(MoonlightVirtualKey.isModifier(key), "VK \(key)")
        }
        for modifier in MoonlightModifierKey.allCases { XCTAssertTrue(MoonlightVirtualKey.isModifier(modifier.virtualKey)) }
    }

    func testTheRowStartsWithTheModifiersAndHoldsEveryKeyOnce() {
        let groups = MoonlightKeyBarLayout.groups
        XCTAssertEqual(groups.first, [.modifier(.windows), .modifier(.control), .modifier(.alt), .modifier(.shift)])
        let items = groups.flatMap { $0 }
        XCTAssertEqual(items.count, Set(items).count, "no key appears twice")

        let keys = items.compactMap { item -> MoonlightBarKey? in if case .key(let key) = item { return key } else { return nil } }
        for key in [MoonlightBarKey.escape, .tab, .delete, .left, .up, .down, .right, .home, .end, .pageUp, .pageDown] {
            XCTAssertTrue(keys.contains(key), key.title)
        }
        let functionKeys = keys.filter { $0.title.hasPrefix("F") }
        XCTAssertEqual(functionKeys.map(\.virtualKey), Array(0x70...0x7B), "F1–F12")
        XCTAssertEqual(functionKeys.map(\.title), (1...12).map { "F\($0)" })
        XCTAssertEqual(Set(keys.map(\.virtualKey)).count, keys.count)
        XCTAssertEqual(MoonlightBarKey.delete.virtualKey, 0x2E, "Del is forward delete")
        XCTAssertEqual([MoonlightBarKey.left, .up, .right, .down].map(\.virtualKey), [0x25, 0x26, 0x27, 0x28])

        let shortcuts = items.compactMap { item -> MoonlightKeyBarShortcut? in if case .shortcut(let shortcut) = item { return shortcut } else { return nil } }
        XCTAssertEqual(shortcuts, MoonlightKeyBarShortcut.allCases)
        XCTAssertEqual(shortcuts.last, .closeWindow, "Alt+F4 sits at the end of the shortcuts")
    }

    func testKeyNames() {
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x43), "C")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x37), "7")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x73), "F4")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x7B), "F12")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x2C), "PrtSc")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0xA2), "Ctrl")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0x5B), "Win")
        XCTAssertEqual(MoonlightVirtualKey.name(of: 0xFF), "VK 0xFF")
    }
}
