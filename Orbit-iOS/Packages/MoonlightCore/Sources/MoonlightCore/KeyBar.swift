import Foundation

// The extra PC keys shown above the software keyboard on iPhone and iPad (the UIKit row itself is in
// KeyBarView.swift). Everything here is plain logic so it can be tested on any platform.

// MARK: - Keys on the bar

/// A modifier on the key bar. Each one stands for the left-hand key on a PC keyboard.
public enum MoonlightModifierKey: Int, CaseIterable, Hashable, Sendable {
    case windows, control, alt, shift

    public var virtualKey: Int16 {
        switch self {
        case .windows: return 0x5B   // VK_LWIN
        case .control: return 0xA2   // VK_LCONTROL
        case .alt: return 0xA4       // VK_LMENU
        case .shift: return 0xA0     // VK_LSHIFT
        }
    }

    public var flag: MoonlightKeyModifiers {
        switch self {
        case .windows: return .meta
        case .control: return .control
        case .alt: return .alt
        case .shift: return .shift
        }
    }

    /// As printed on PC keycaps and in shortcut captions ("Win+D").
    public var title: String {
        switch self {
        case .windows: return "Win"
        case .control: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        }
    }

    public var spokenName: String {
        switch self {
        case .windows: return "Windows key"
        case .control: return "Control"
        case .alt: return "Alt"
        case .shift: return "Shift"
        }
    }
}

/// A plain key: down while the finger is on it, like a real key, so holding one repeats on the PC.
public struct MoonlightBarKey: Hashable, Sendable {
    public let virtualKey: Int16
    public let title: String
    /// SF Symbol drawn instead of the title (arrows).
    public let symbol: String?
    public let spokenName: String

    public init(virtualKey: Int16, title: String, symbol: String? = nil, spokenName: String) {
        self.virtualKey = virtualKey
        self.title = title
        self.symbol = symbol
        self.spokenName = spokenName
    }

    public static let escape = MoonlightBarKey(virtualKey: MoonlightVirtualKey.escape, title: "Esc", spokenName: "Escape")
    public static let tab = MoonlightBarKey(virtualKey: MoonlightVirtualKey.tab, title: "Tab", spokenName: "Tab")
    /// Forward delete; the software keyboard has its own backspace.
    public static let delete = MoonlightBarKey(virtualKey: MoonlightVirtualKey.delete, title: "Del", spokenName: "Delete")
    public static let left = MoonlightBarKey(virtualKey: 0x25, title: "←", symbol: "arrow.left", spokenName: "Left arrow")
    public static let up = MoonlightBarKey(virtualKey: 0x26, title: "↑", symbol: "arrow.up", spokenName: "Up arrow")
    public static let down = MoonlightBarKey(virtualKey: 0x28, title: "↓", symbol: "arrow.down", spokenName: "Down arrow")
    public static let right = MoonlightBarKey(virtualKey: 0x27, title: "→", symbol: "arrow.right", spokenName: "Right arrow")
    public static let home = MoonlightBarKey(virtualKey: 0x24, title: "Home", spokenName: "Home")
    public static let end = MoonlightBarKey(virtualKey: 0x23, title: "End", spokenName: "End")
    public static let pageUp = MoonlightBarKey(virtualKey: 0x21, title: "PgUp", spokenName: "Page up")
    public static let pageDown = MoonlightBarKey(virtualKey: 0x22, title: "PgDn", spokenName: "Page down")

    /// F1–F24 (the bar shows F1–F12).
    public static func function(_ number: Int) -> MoonlightBarKey {
        let clamped = min(max(number, 1), 24)
        return MoonlightBarKey(virtualKey: Int16(0x6F + clamped), title: "F\(clamped)", spokenName: "F\(clamped)")
    }
}

/// Modifiers plus one key, pressed in order and let go in reverse.
public struct MoonlightKeyChord: Hashable, Sendable {
    public var modifiers: [MoonlightModifierKey]
    public var key: Int16

    public init(_ modifiers: [MoonlightModifierKey] = [], _ key: Int16) {
        self.modifiers = modifiers
        self.key = key
    }

    public var flags: MoonlightKeyModifiers { modifiers.reduce(into: []) { $0.insert($1.flag) } }

    /// "Ctrl+Shift+Esc".
    public var caption: String { (modifiers.map(\.title) + [MoonlightVirtualKey.name(of: key)]).joined(separator: "+") }
}

/// One-tap Windows shortcuts at the end of the bar.
public enum MoonlightKeyBarShortcut: String, CaseIterable, Hashable, Sendable {
    case switchApp, taskView, desktop, gameBar, taskManager, screenshot, closeWindow

    public var chord: MoonlightKeyChord {
        switch self {
        case .switchApp: return MoonlightKeyChord([.alt], MoonlightVirtualKey.tab)
        case .taskView: return MoonlightKeyChord([.windows], MoonlightVirtualKey.tab)
        case .desktop: return MoonlightKeyChord([.windows], 0x44)                         // D
        case .gameBar: return MoonlightKeyChord([.windows], 0x47)                         // G
        case .taskManager: return MoonlightKeyChord([.control, .shift], MoonlightVirtualKey.escape)
        case .screenshot: return MoonlightKeyChord([], MoonlightVirtualKey.printScreen)
        case .closeWindow: return MoonlightKeyChord([.alt], 0x73)                         // F4
        }
    }

    public var title: String {
        switch self {
        case .switchApp: return "Switch App"
        case .taskView: return "Task View"
        case .desktop: return "Desktop"
        case .gameBar: return "Game Bar"
        case .taskManager: return "Task Manager"
        case .screenshot: return "Screenshot"
        case .closeWindow: return "Close"
        }
    }

    /// What VoiceOver says; the keys follow as the hint.
    public var spokenName: String {
        switch self {
        case .switchApp: return "Switch to the previous app"
        case .taskView: return "Task View"
        case .desktop: return "Show the desktop"
        case .gameBar: return "Xbox Game Bar"
        case .taskManager: return "Task Manager"
        case .screenshot: return "Print Screen"
        case .closeWindow: return "Close the window in front"
        }
    }

    /// Alt+F4 can lose unsaved work, so it asks first instead of firing on a stray tap.
    public var needsConfirmation: Bool { self == .closeWindow }
}

public enum MoonlightKeyBarItem: Hashable, Sendable {
    case modifier(MoonlightModifierKey)
    case key(MoonlightBarKey)
    case shortcut(MoonlightKeyBarShortcut)
}

public enum MoonlightKeyBarLayout {
    /// Left to right, with a gap between groups: what is needed most sits where the row starts.
    public static let groups: [[MoonlightKeyBarItem]] = [
        MoonlightModifierKey.allCases.map { .modifier($0) },
        [.key(.escape), .key(.tab), .key(.delete)],
        [.key(.left), .key(.up), .key(.down), .key(.right)],
        [.key(.home), .key(.end), .key(.pageUp), .key(.pageDown)],
        MoonlightKeyBarShortcut.allCases.map { .shortcut($0) },
        (1...12).map { .key(.function($0)) },
    ]
}

// MARK: - Latching modifiers

public enum MoonlightLatch: Hashable, Sendable {
    case off
    /// Applies to the next key, then lets go.
    case oneShot
    /// Stays down until tapped again.
    case locked
}

/// What the key bar or the software keyboard asks the PC to do.
public enum MoonlightKeyOutput: Equatable, Sendable {
    case key(Int16, pressed: Bool, modifiers: MoonlightKeyModifiers)
    case text(String)
}

/// The key bar's modifiers and every key sent while one is latched.
///
/// Tap a modifier and it applies to the next key only; tap it twice quickly and it stays locked until it is
/// tapped again. A latched modifier is held down on the PC the whole time, exactly like a finger on a real
/// key, so it also combines with hardware keys, clicks and repeated presses (locked Alt + Tab, Tab, Tab walks
/// the app switcher). Tapping it off without using it presses it on its own: Win opens Start.
/// Characters typed on the software keyboard while a modifier is latched go out as key presses instead of
/// text, so Ctrl + "c" is Ctrl+C.
public struct MoonlightModifierLatch: Equatable, Sendable {
    /// Two taps closer together than this lock the modifier.
    public static let doubleTapInterval: TimeInterval = 0.35

    private var states: [MoonlightModifierKey: MoonlightLatch] = [:]
    private var latchedAt: [MoonlightModifierKey: TimeInterval] = [:]
    /// Plain keys from the bar that are down on the PC right now, oldest first.
    public private(set) var pressedKeys: [Int16] = []

    public init() {}

    public func state(of modifier: MoonlightModifierKey) -> MoonlightLatch { states[modifier] ?? .off }

    /// Every latched modifier (held down on the PC).
    public var held: MoonlightKeyModifiers {
        MoonlightModifierKey.allCases.reduce(into: []) { flags, modifier in
            if state(of: modifier) != .off { flags.insert(modifier.flag) }
        }
    }

    public var isAnyLatched: Bool { MoonlightModifierKey.allCases.contains { state(of: $0) != .off } }
    public var hasOneShot: Bool { MoonlightModifierKey.allCases.contains { state(of: $0) == .oneShot } }
    /// Nothing latched and no bar key down.
    public var isIdle: Bool { !isAnyLatched && pressedKeys.isEmpty }

    // MARK: Modifiers

    /// Off → next key only → (a second tap within `doubleTapInterval`) locked; any other tap turns it off.
    public mutating func tap(_ modifier: MoonlightModifierKey, at time: TimeInterval) -> [MoonlightKeyOutput] {
        switch state(of: modifier) {
        case .off:
            states[modifier] = .oneShot
            latchedAt[modifier] = time
            return [.key(modifier.virtualKey, pressed: true, modifiers: held)]
        case .oneShot:
            if let start = latchedAt[modifier], time >= start, time <= start + Self.doubleTapInterval {
                states[modifier] = .locked
                return []
            }
            return letGo(modifier)
        case .locked:
            return letGo(modifier)
        }
    }

    /// Straight to locked (VoiceOver's "Lock" action, where a quick double tap is not practical).
    public mutating func lock(_ modifier: MoonlightModifierKey) -> [MoonlightKeyOutput] {
        switch state(of: modifier) {
        case .off:
            states[modifier] = .locked
            return [.key(modifier.virtualKey, pressed: true, modifiers: held)]
        case .oneShot:
            states[modifier] = .locked
            return []
        case .locked:
            return []
        }
    }

    /// Lets go of the modifiers that were latched for one key only. Called after every key, including
    /// hardware keys that combined with them on the PC.
    public mutating func releaseOneShots() -> [MoonlightKeyOutput] {
        MoonlightModifierKey.allCases.reversed().filter { state(of: $0) == .oneShot }.flatMap { letGo($0) }
    }

    /// Lets go of everything: bar keys still down, then every latched modifier. Used when the keyboard hides.
    public mutating func releaseAll() -> [MoonlightKeyOutput] {
        var outputs = pressedKeys.reversed().map { MoonlightKeyOutput.key($0, pressed: false, modifiers: held) }
        pressedKeys = []
        for modifier in MoonlightModifierKey.allCases.reversed() { outputs += letGo(modifier) }
        return outputs
    }

    private mutating func letGo(_ modifier: MoonlightModifierKey) -> [MoonlightKeyOutput] {
        guard state(of: modifier) != .off else { return [] }
        states[modifier] = nil
        latchedAt[modifier] = nil
        return [.key(modifier.virtualKey, pressed: false, modifiers: held)]
    }

    // MARK: Keys

    /// A bar key going down. A second press of a key that is already down is ignored.
    public mutating func press(_ key: Int16) -> [MoonlightKeyOutput] {
        guard !pressedKeys.contains(key) else { return [] }
        pressedKeys.append(key)
        return [.key(key, pressed: true, modifiers: held)]
    }

    /// A bar key coming up; one-shot modifiers are done after it. Keys that are not down are ignored, so a
    /// finger lifted after `releaseAll()` sends nothing.
    public mutating func release(_ key: Int16) -> [MoonlightKeyOutput] {
        guard let index = pressedKeys.firstIndex(of: key) else { return [] }
        pressedKeys.remove(at: index)
        return [.key(key, pressed: false, modifiers: held)] + releaseOneShots()
    }

    /// Presses the chord's modifiers that are not latched already, taps the key, lets go of what it pressed,
    /// then of the one-shot modifiers. Latched ones join in: Shift latched + Alt+Tab is Alt+Shift+Tab.
    public mutating func perform(_ chord: MoonlightKeyChord) -> [MoonlightKeyOutput] {
        var outputs: [MoonlightKeyOutput] = []
        var modifiers = held
        var pressedHere: [MoonlightModifierKey] = []
        for modifier in chord.modifiers where !modifiers.contains(modifier.flag) {
            modifiers.insert(modifier.flag)
            pressedHere.append(modifier)
            outputs.append(.key(modifier.virtualKey, pressed: true, modifiers: modifiers))
        }
        outputs.append(.key(chord.key, pressed: true, modifiers: modifiers))
        outputs.append(.key(chord.key, pressed: false, modifiers: modifiers))
        for modifier in pressedHere.reversed() {
            modifiers.remove(modifier.flag)
            outputs.append(.key(modifier.virtualKey, pressed: false, modifiers: modifiers))
        }
        return outputs + releaseOneShots()
    }

    // MARK: Software keyboard

    /// Text from the software keyboard. With nothing latched it goes out as text (any language, emoji) and a
    /// lone newline as Enter, as before. While a modifier is latched each character becomes a key press with
    /// it (Ctrl + "c" → Ctrl+C); a one-shot modifier covers the first character only and the rest is text.
    /// Characters with no key on a US layout still go out as text.
    public mutating func type(_ text: String) -> [MoonlightKeyOutput] {
        guard !text.isEmpty else { return [] }
        guard isAnyLatched else { return plainText(text) }
        var outputs: [MoonlightKeyOutput] = []
        var rest = ""
        for character in text {
            guard isAnyLatched else { rest.append(character); continue }
            if let mapped = MoonlightVirtualKey.fromCharacter(character) {
                outputs += perform(MoonlightKeyChord(mapped.shift ? [.shift] : [], mapped.virtualKey))
            } else {
                outputs.append(.text(String(character)))
                outputs += releaseOneShots()
            }
        }
        return outputs + plainText(rest)
    }

    /// The software keyboard's backspace; with Ctrl latched it deletes a word.
    public mutating func deleteBackward() -> [MoonlightKeyOutput] {
        perform(MoonlightKeyChord([], MoonlightVirtualKey.back))
    }

    private mutating func plainText(_ text: String) -> [MoonlightKeyOutput] {
        guard !text.isEmpty else { return [] }
        return text == "\n" ? perform(MoonlightKeyChord([], MoonlightVirtualKey.enter)) : [.text(text)]
    }
}
