import Foundation

/// Windows virtual-key codes, which is what Sunshine expects from Moonlight clients.
public enum MoonlightVirtualKey {
    public static let back: Int16 = 0x08
    public static let tab: Int16 = 0x09
    public static let enter: Int16 = 0x0D
    public static let shift: Int16 = 0x10
    public static let control: Int16 = 0x11
    public static let alt: Int16 = 0x12
    public static let escape: Int16 = 0x1B
    public static let space: Int16 = 0x20
    public static let leftWindows: Int16 = 0x5B
    public static let delete: Int16 = 0x2E
    public static let printScreen: Int16 = 0x2C

    /// Shift, Control, Alt, Windows (either side) and Caps Lock: keys that change other keys rather than
    /// being one, so they do not use up a key bar modifier latched for "the next key".
    public static func isModifier(_ virtualKey: Int16) -> Bool {
        switch virtualKey {
        case shift, control, alt, 0x14, 0x5B, 0x5C, 0xA0...0xA5: return true
        default: return false
        }
    }

    /// The key that types `character` on a US layout, and whether it needs Shift. Letters and digits sit on
    /// the same keys on most layouts, which is what shortcuts use. nil for anything else (é, ș, emoji).
    public static func fromCharacter(_ character: Character) -> (virtualKey: Int16, shift: Bool)? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.isASCII else {
            // "\r\n" is one Character made of two scalars.
            return character == "\r\n" ? (enter, false) : nil
        }
        let value = Int16(scalar.value)
        switch scalar {
        case "a"..."z": return (value - 0x20, false)
        case "A"..."Z": return (value, true)
        case "0"..."9": return (value, false)
        case " ": return (space, false)
        case "\n", "\r": return (enter, false)
        case "\t": return (tab, false)
        default: break
        }
        let punctuation: [Character: (Int16, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true), "%": (0x35, true),
            "^": (0x36, true), "&": (0x37, true), "*": (0x38, true), "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true), "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true), "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true), ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true), "`": (0xC0, false), "~": (0xC0, true),
            ",": (0xBC, false), "<": (0xBC, true), ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
        ]
        return punctuation[character].map { (virtualKey: $0.0, shift: $0.1) }
    }

    /// Short names as printed on PC keycaps ("Esc", "PgUp", "F4", "C"), for captions and logs.
    public static func name(of virtualKey: Int16) -> String {
        switch virtualKey {
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(virtualKey)))
        case back: return "Backspace"
        case tab: return "Tab"
        case enter: return "Enter"
        case escape: return "Esc"
        case space: return "Space"
        case delete: return "Del"
        case printScreen: return "PrtSc"
        case 0x2D: return "Ins"
        case 0x21: return "PgUp"
        case 0x22: return "PgDn"
        case 0x23: return "End"
        case 0x24: return "Home"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        case 0x14: return "Caps Lock"
        case 0x70...0x87: return "F\(virtualKey - 0x6F)"
        case 0x5B, 0x5C: return "Win"
        case shift, 0xA0, 0xA1: return "Shift"
        case control, 0xA2, 0xA3: return "Ctrl"
        case alt, 0xA4, 0xA5: return "Alt"
        case 0xBA: return ";"
        case 0xBB: return "="
        case 0xBC: return ","
        case 0xBD: return "-"
        case 0xBE: return "."
        case 0xBF: return "/"
        case 0xC0: return "`"
        case 0xDB: return "["
        case 0xDC: return "\\"
        case 0xDD: return "]"
        case 0xDE: return "'"
        default: return "VK 0x" + String(UInt16(bitPattern: virtualKey), radix: 16, uppercase: true)
        }
    }

    /// Maps a USB HID keyboard usage (UIKeyboardHIDUsage / GCKeyCode raw value) to a VK code.
    public static func fromHIDUsage(_ usage: Int) -> Int16? {
        switch usage {
        case 0x04...0x1D: return Int16(0x41 + (usage - 0x04))          // a–z
        case 0x1E...0x26: return Int16(0x31 + (usage - 0x1E))          // 1–9
        case 0x27: return 0x30                                          // 0
        case 0x28: return enter
        case 0x29: return escape
        case 0x2A: return back
        case 0x2B: return tab
        case 0x2C: return space
        case 0x2D: return 0xBD // -
        case 0x2E: return 0xBB // =
        case 0x2F: return 0xDB // [
        case 0x30: return 0xDD // ]
        case 0x31: return 0xDC // backslash
        case 0x32: return 0xDC // non-US #
        case 0x33: return 0xBA // ;
        case 0x34: return 0xDE // '
        case 0x35: return 0xC0 // `
        case 0x36: return 0xBC // ,
        case 0x37: return 0xBE // .
        case 0x38: return 0xBF // /
        case 0x39: return 0x14 // caps lock
        case 0x3A...0x45: return Int16(0x70 + (usage - 0x3A))          // F1–F12
        case 0x46: return 0x2C // print screen
        case 0x47: return 0x91 // scroll lock
        case 0x48: return 0x13 // pause
        case 0x49: return 0x2D // insert
        case 0x4A: return 0x24 // home
        case 0x4B: return 0x21 // page up
        case 0x4C: return delete
        case 0x4D: return 0x23 // end
        case 0x4E: return 0x22 // page down
        case 0x4F: return 0x27 // right
        case 0x50: return 0x25 // left
        case 0x51: return 0x28 // down
        case 0x52: return 0x26 // up
        case 0x53: return 0x90 // num lock
        case 0x54: return 0x6F // keypad /
        case 0x55: return 0x6A // keypad *
        case 0x56: return 0x6D // keypad -
        case 0x57: return 0x6B // keypad +
        case 0x58: return enter
        case 0x59...0x61: return Int16(0x61 + (usage - 0x59))          // keypad 1–9
        case 0x62: return 0x60 // keypad 0
        case 0x63: return 0x6E // keypad .
        case 0x64: return 0xE2 // non-US backslash
        case 0x65: return 0x5D // application / menu
        case 0x68...0x73: return Int16(0x7C + (usage - 0x68))          // F13–F24
        case 0xE0: return 0xA2 // left control
        case 0xE1: return 0xA0 // left shift
        case 0xE2: return 0xA4 // left alt
        case 0xE3: return 0x5B // left command → Windows key
        case 0xE4: return 0xA3 // right control
        case 0xE5: return 0xA1 // right shift
        case 0xE6: return 0xA5 // right alt
        case 0xE7: return 0x5C // right command → Windows key
        default: return nil
        }
    }

    /// Maps a macOS (Carbon) virtual key code from NSEvent.keyCode to a VK code.
    public static func fromMacKeyCode(_ keyCode: UInt16) -> Int16? {
        switch keyCode {
        case 0x00: return 0x41 // a
        case 0x0B: return 0x42 // b
        case 0x08: return 0x43 // c
        case 0x02: return 0x44 // d
        case 0x0E: return 0x45 // e
        case 0x03: return 0x46 // f
        case 0x05: return 0x47 // g
        case 0x04: return 0x48 // h
        case 0x22: return 0x49 // i
        case 0x26: return 0x4A // j
        case 0x28: return 0x4B // k
        case 0x25: return 0x4C // l
        case 0x2E: return 0x4D // m
        case 0x2D: return 0x4E // n
        case 0x1F: return 0x4F // o
        case 0x23: return 0x50 // p
        case 0x0C: return 0x51 // q
        case 0x0F: return 0x52 // r
        case 0x01: return 0x53 // s
        case 0x11: return 0x54 // t
        case 0x20: return 0x55 // u
        case 0x09: return 0x56 // v
        case 0x0D: return 0x57 // w
        case 0x07: return 0x58 // x
        case 0x10: return 0x59 // y
        case 0x06: return 0x5A // z
        case 0x1D: return 0x30 // 0
        case 0x12: return 0x31
        case 0x13: return 0x32
        case 0x14: return 0x33
        case 0x15: return 0x34
        case 0x17: return 0x35
        case 0x16: return 0x36
        case 0x1A: return 0x37
        case 0x1C: return 0x38
        case 0x19: return 0x39 // 9
        case 0x24: return enter
        case 0x30: return tab
        case 0x31: return space
        case 0x33: return back
        case 0x35: return escape
        case 0x37: return 0x5B // command → Windows
        case 0x36: return 0x5C // right command
        case 0x38: return 0xA0 // shift
        case 0x3C: return 0xA1 // right shift
        case 0x39: return 0x14 // caps lock
        case 0x3A: return 0xA4 // option
        case 0x3D: return 0xA5 // right option
        case 0x3B: return 0xA2 // control
        case 0x3E: return 0xA3 // right control
        case 0x7A: return 0x70 // F1
        case 0x78: return 0x71
        case 0x63: return 0x72
        case 0x76: return 0x73
        case 0x60: return 0x74
        case 0x61: return 0x75
        case 0x62: return 0x76
        case 0x64: return 0x77
        case 0x65: return 0x78
        case 0x6D: return 0x79
        case 0x67: return 0x7A
        case 0x6F: return 0x7B // F12
        case 0x69: return 0x7C // F13
        case 0x6B: return 0x7D // F14
        case 0x71: return 0x7E // F15
        case 0x72: return 0x2D // help → insert
        case 0x73: return 0x24 // home
        case 0x74: return 0x21 // page up
        case 0x75: return delete // forward delete
        case 0x77: return 0x23 // end
        case 0x79: return 0x22 // page down
        case 0x7B: return 0x25 // left
        case 0x7C: return 0x27 // right
        case 0x7D: return 0x28 // down
        case 0x7E: return 0x26 // up
        case 0x1B: return 0xBD // -
        case 0x18: return 0xBB // =
        case 0x21: return 0xDB // [
        case 0x1E: return 0xDD // ]
        case 0x2A: return 0xDC // backslash
        case 0x29: return 0xBA // ;
        case 0x27: return 0xDE // '
        case 0x32: return 0xC0 // `
        case 0x2B: return 0xBC // ,
        case 0x2F: return 0xBE // .
        case 0x2C: return 0xBF // /
        case 0x47: return 0x90 // clear → num lock
        case 0x4B: return 0x6F // keypad /
        case 0x43: return 0x6A // keypad *
        case 0x4E: return 0x6D // keypad -
        case 0x45: return 0x6B // keypad +
        case 0x4C: return enter // keypad enter
        case 0x41: return 0x6E // keypad .
        case 0x52: return 0x60 // keypad 0
        case 0x53: return 0x61
        case 0x54: return 0x62
        case 0x55: return 0x63
        case 0x56: return 0x64
        case 0x57: return 0x65
        case 0x58: return 0x66
        case 0x59: return 0x67
        case 0x5B: return 0x68
        case 0x5C: return 0x69 // keypad 9
        default: return nil
        }
    }
}
