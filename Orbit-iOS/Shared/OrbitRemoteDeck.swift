import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The custom button deck (DESIGN F4) as the Apple Watch, Mac and Apple TV apps see it.
//
// The deck lives on the PC (`GET /api/deck` → `{"buttons":[Button],"updatedAt":"ISO"}`) and is shared
// by every device; the iPhone builds it. These apps show it, run buttons by id
// (`POST /api/deck/buttons/{id}/run` → `{"status":"done","detail":"…"}`), and the Mac can reorder,
// delete and add preset buttons with `PUT /api/deck {"buttons":[…]}`, which replaces the whole deck.
// Buttons are therefore kept as raw JSON, so fields this build does not know survive a Mac edit.
//
// Compiled into OrbitWatch, OrbitMac and OrbitTV only (not the iPhone app, which has its own deck
// models). Keep it free of other app types.

/// Any JSON value. Integers stay integers, so `delayMs: 200` is sent back as `200`, not `200.0`.
enum OrbitRemoteDeckJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case number(Double)
    case string(String)
    case array([OrbitRemoteDeckJSON])
    case object([String: OrbitRemoteDeckJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OrbitRemoteDeckJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: OrbitRemoteDeckJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    var string: String? { if case let .string(value) = self { return value }; return nil }
    var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
    var array: [OrbitRemoteDeckJSON]? { if case let .array(value) = self { return value }; return nil }
    var object: [String: OrbitRemoteDeckJSON]? { if case let .object(value) = self { return value }; return nil }
    subscript(key: String) -> OrbitRemoteDeckJSON? { object?[key] }
}

/// One button of the deck: `{"id","title","symbol","color","action":{…}}` plus an optional
/// `"confirm": true` (required by the PC for sleep, shut down and restart).
struct OrbitRemoteDeckButton: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    var color: String
    var confirm: Bool
    var action: OrbitRemoteDeckJSON
    /// Keys this build does not use, sent back unchanged when the Mac saves the deck.
    var extra: [String: OrbitRemoteDeckJSON] = [:]

    init(id: String, title: String, symbol: String, color: String, confirm: Bool = false, action: OrbitRemoteDeckJSON) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.confirm = confirm
        self.action = action
    }

    /// A button from the PC. Returns nil when it has no usable id, so one broken button never hides the rest.
    init?(json: OrbitRemoteDeckJSON) {
        guard var fields = json.object,
              let id = fields.removeValue(forKey: "id")?.string, OrbitRemoteDeck.isValidButtonID(id) else { return nil }
        self.id = id
        title = (fields.removeValue(forKey: "title")?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        symbol = fields.removeValue(forKey: "symbol")?.string ?? ""
        color = fields.removeValue(forKey: "color")?.string ?? ""
        confirm = fields.removeValue(forKey: "confirm")?.bool ?? false
        action = fields.removeValue(forKey: "action") ?? .object([:])
        extra = fields
    }

    /// The compact form the iPhone puts in the Watch sync payload (`OrbitWatchDeckSync.payload`):
    /// `{"id","title","symbol","color","confirm","type","power"}`. Buttons run by id, so the full
    /// action never travels to the Watch.
    init?(watchSummary dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String, OrbitRemoteDeck.isValidButtonID(id) else { return nil }
        self.id = id
        title = (dictionary["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        symbol = dictionary["symbol"] as? String ?? ""
        color = dictionary["color"] as? String ?? ""
        confirm = dictionary["confirm"] as? Bool ?? false
        let type = dictionary["type"] as? String ?? ""
        var action: [String: OrbitRemoteDeckJSON] = ["type": .string(type)]
        if let power = dictionary["power"] as? String, OrbitRemoteDeck.powerActions.contains(power) {
            let step: OrbitRemoteDeckJSON = .object(["type": .string("system"), "name": .string(power)])
            if type == "sequence" { action["steps"] = .array([step]) } else { action = step.object ?? action }
        }
        self.action = .object(action)
    }

    var json: OrbitRemoteDeckJSON {
        var fields = extra
        fields["id"] = .string(id)
        fields["title"] = .string(title)
        fields["symbol"] = .string(symbol)
        fields["color"] = .string(color)
        if confirm { fields["confirm"] = .bool(true) }
        fields["action"] = action
        return .object(fields)
    }
}

extension OrbitRemoteDeckButton {
    var actionType: String { action["type"]?.string ?? "" }

    /// `sleep`, `shutdown` or `restart` when this button (or a step of its sequence) turns the PC off.
    var powerAction: String? { Self.powerAction(in: action) }

    private static func powerAction(in action: OrbitRemoteDeckJSON) -> String? {
        switch action["type"]?.string {
        case "system":
            let name = action["name"]?.string ?? ""
            return OrbitRemoteDeck.powerActions.contains(name) ? name : nil
        case "sequence":
            return action["steps"]?.array?.lazy.compactMap { powerAction(in: $0) }.first
        default:
            return nil
        }
    }

    /// Power buttons are always confirmed on the device first; the PC also insists on `confirm`.
    var needsConfirmation: Bool { confirm || powerAction != nil }

    var displayTitle: String { title.isEmpty ? "Button" : title }

    var confirmationTitle: String {
        switch powerAction {
        case "sleep": return "Put your PC to sleep?"
        case "restart": return "Restart your PC?"
        case "shutdown": return "Shut down your PC?"
        default: return "Run “\(displayTitle)”?"
        }
    }

    var confirmationButton: String {
        switch powerAction {
        case "sleep": return "Sleep PC"
        case "restart": return "Restart PC"
        case "shutdown": return "Shut Down PC"
        default: return "Run"
        }
    }

    func confirmationMessage(pcName: String) -> String {
        switch powerAction {
        case "sleep": return "“\(displayTitle)” puts \(pcName) to sleep. Wake-on-LAN must be on to wake it remotely."
        case "restart", "shutdown": return "“\(displayTitle)” turns off \(pcName). Save your open work first."
        default: return "This button runs on \(pcName)."
        }
    }

    /// The button's color, kept readable on Orbit's black background.
    func tint(fallback: Color) -> Color {
        guard let rgb = OrbitRemoteDeck.rgb(fromHex: color) else { return fallback }
        let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
        guard luminance >= 0.12 else { return fallback }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// The SF Symbol to draw: the button's own, or one that fits its action when this OS lacks it.
    var displaySymbol: String {
        if !symbol.isEmpty, OrbitRemoteDeck.symbolExists(symbol) { return symbol }
        switch actionType {
        case "hotkey": return "keyboard"
        case "text": return "text.cursor"
        case "openUrl": return "link"
        case "launch": return "app.badge"
        case "media": return "playpause.fill"
        case "obs": return "record.circle"
        case "sequence": return "list.number"
        case "system": return powerAction == nil ? "desktopcomputer" : "power"
        default: return "square.grid.2x2.fill"
        }
    }

    /// One short line about what the button does ("Ctrl + Shift + M", "OBS · Record", "3 steps").
    var summary: String { Self.summary(of: action) }

    /// The line under a button's title: `summary`, unless it only repeats the title ("Screenshot" →
    /// "Screenshot"); then the kind of action, or that it asks first.
    var subtitle: String {
        let text = summary
        let normalized = { (value: String) in value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let title = normalized(displayTitle)
        let repeatsTitle = normalized(text) == title || (!normalized(text).isEmpty && title.contains(normalized(text)))
        if needsConfirmation { return repeatsTitle ? "Asks before it runs" : "\(text) · asks first" }
        guard repeatsTitle else { return text }
        switch actionType {
        case "system": return "Windows action"
        case "media": return "Media key"
        case "hotkey": return "Keyboard shortcut"
        case "obs": return "OBS Studio"
        case "openUrl": return "Link"
        case "launch": return "App"
        case "text": return "Typed text"
        default: return "Runs on your PC"
        }
    }

    private static func summary(of action: OrbitRemoteDeckJSON) -> String {
        switch action["type"]?.string ?? "" {
        case "hotkey":
            let keys = (action["keys"]?.array ?? []).compactMap(\.string).map(keyName)
            return keys.isEmpty ? "Keyboard shortcut" : keys.joined(separator: " + ")
        case "text":
            let text = (action["text"]?.string ?? "").replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? "Types text" : "Types “\(text.count > 22 ? String(text.prefix(21)) + "…" : text)”"
        case "openUrl":
            let url = URL(string: action["url"]?.string ?? "")
            let scheme = url?.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https", let host = url?.host, !host.isEmpty {
                return "Opens \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
            }
            if !scheme.isEmpty { return "Opens \(appName(forScheme: scheme))" }
            return "Opens a link"
        case "launch":
            if let name = action["name"]?.string ?? action["appName"]?.string, !name.isEmpty { return "Opens \(name)" }
            return "Opens an app"
        case "system":
            return systemName(action["name"]?.string ?? "")
        case "media":
            switch action["name"]?.string ?? "" {
            case "playpause": return "Play / pause"
            case "next": return "Next track"
            case "previous": return "Previous track"
            case "mute": return "Mute or unmute"
            case "volumeup": return "Volume up"
            case "volumedown": return "Volume down"
            default: return "Media"
            }
        case "obs":
            let data = action["data"]
            switch action["request"]?.string ?? "" {
            case "SetCurrentProgramScene":
                let scene = data?["sceneName"]?.string ?? ""
                return scene.isEmpty ? "OBS · Switch scene" : "OBS · \(scene)"
            case "StartRecord": return "OBS · Start recording"
            case "StopRecord": return "OBS · Stop recording"
            case "ToggleRecord": return "OBS · Record"
            case "ToggleStream": return "OBS · Stream"
            case "SaveReplayBuffer": return "OBS · Save replay"
            case "StartReplayBuffer": return "OBS · Start replay buffer"
            case "ToggleInputMute":
                let input = data?["inputName"]?.string ?? ""
                return input.isEmpty ? "OBS · Mute input" : "OBS · Mute \(input)"
            default: return "OBS"
            }
        case "sequence":
            let count = action["steps"]?.array?.count ?? 0
            return count == 1 ? "1 step" : "\(count) steps"
        default:
            return "Custom action"
        }
    }

    private static func keyName(_ key: String) -> String {
        switch key.lowercased() {
        case "ctrl": return "Ctrl"
        case "shift": return "Shift"
        case "alt": return "Alt"
        case "win": return "Win"
        case "esc": return "Esc"
        case "enter": return "Enter"
        case "tab": return "Tab"
        case "space": return "Space"
        case "backspace": return "Backspace"
        case "delete": return "Del"
        case "pageup": return "Page Up"
        case "pagedown": return "Page Down"
        case "printscreen": return "Print Screen"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "playpause": return "Play/Pause"
        case "volumeup": return "Volume Up"
        case "volumedown": return "Volume Down"
        case "volumemute": return "Mute"
        case "nexttrack": return "Next Track"
        case "prevtrack": return "Previous Track"
        default:
            let lower = key.lowercased()
            if lower.count <= 3 { return lower.uppercased() }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
    }

    private static func systemName(_ name: String) -> String {
        switch name {
        case "lock": return "Lock the PC"
        case "sleep": return "Sleep"
        case "shutdown": return "Shut down"
        case "restart": return "Restart"
        case "show_desktop": return "Show desktop"
        case "screenshot": return "Screenshot"
        case "task_view": return "Task View"
        case "alt_tab": return "Switch app"
        case "mute": return "Mute or unmute"
        case "toggle_hdr": return "Toggle HDR"
        case "restore_display": return "Extend displays"
        case "kill_game": return "Quit the game"
        case "fullscreen": return "Full screen (F11)"
        case "volume_up": return "Volume up"
        case "volume_down": return "Volume down"
        case "media_play_pause": return "Play / pause"
        case "media_next": return "Next track"
        case "media_prev": return "Previous track"
        default: return name.isEmpty ? "Windows action" : name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func appName(forScheme scheme: String) -> String {
        switch scheme.lowercased() {
        case "steam": return "Steam"
        case "com.epicgames.launcher": return "Epic Games"
        case "spotify": return "Spotify"
        case "discord": return "Discord"
        case "ms-settings": return "Windows Settings"
        default: return scheme
        }
    }
}

/// `GET /api/deck`. Buttons that cannot be read are skipped instead of failing the whole deck.
struct OrbitRemoteDeck: Decodable, Hashable, Sendable {
    var buttons: [OrbitRemoteDeckButton]
    var updatedAt: String?

    /// The PC keeps at most this many buttons.
    static let maxButtons = 64
    /// Buttons that work without Orbit Pro (the first ones in the deck's order).
    static let freeButtonLimit = 6
    /// Feature string in `GET /api/capabilities` for agents that have the deck.
    static let feature = "deck"
    static let powerActions: Set<String> = ["sleep", "shutdown", "restart"]

    init(buttons: [OrbitRemoteDeckButton], updatedAt: String? = nil) {
        self.buttons = buttons
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case buttons, updatedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([OrbitRemoteDeckJSON].self, forKey: .buttons) ?? []
        var seen = Set<String>()
        buttons = raw.compactMap(OrbitRemoteDeckButton.init(json:)).filter { seen.insert($0.id).inserted }
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Ids go into a URL path (`/api/deck/buttons/{id}/run`): letters, digits, `-` and `_` only.
    static func isValidButtonID(_ id: String) -> Bool {
        (1...64).contains(id.unicodeScalars.count) && id.unicodeScalars.allSatisfy(buttonIDCharacters.contains)
    }

    private static let buttonIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    static func runPath(for id: String) -> String? {
        isValidButtonID(id) ? "/api/deck/buttons/\(id)/run" : nil
    }

    /// Whether the button at `index` needs Orbit Pro on this device.
    static func isLocked(index: Int, proUnlocked: Bool) -> Bool {
        !proUnlocked && index >= freeButtonLimit
    }

    static func rgb(fromHex value: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }

    static func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }

    /// Sample buttons for demo mode. Running them never reaches a PC.
    static let demo = OrbitRemoteDeck(buttons: [
        OrbitRemoteDeckButton(id: "demo-discord-mute", title: "Mute Discord", symbol: "mic.slash.fill", color: "#FF453A",
                              action: .object(["type": .string("hotkey"), "keys": .array([.string("ctrl"), .string("shift"), .string("m")])])),
        OrbitRemoteDeckButton(id: "demo-clip", title: "Save clip", symbol: "film.stack", color: "#30D158",
                              action: .object(["type": .string("hotkey"), "keys": .array([.string("alt"), .string("f10")])])),
        OrbitRemoteDeckButton(id: "demo-record", title: "Record", symbol: "record.circle.fill", color: "#FF375F",
                              action: .object(["type": .string("obs"), "request": .string("ToggleRecord"), "data": .object([:])])),
        OrbitRemoteDeckButton(id: "demo-screenshot", title: "Screenshot", symbol: "camera.viewfinder", color: "#64D2FF",
                              action: .object(["type": .string("system"), "name": .string("screenshot")])),
        OrbitRemoteDeckButton(id: "demo-task-manager", title: "Task Manager", symbol: "list.bullet.rectangle.portrait.fill", color: "#0A84FF",
                              action: .object(["type": .string("hotkey"), "keys": .array([.string("ctrl"), .string("shift"), .string("esc")])])),
        OrbitRemoteDeckButton(id: "demo-play-pause", title: "Play / Pause", symbol: "playpause.fill", color: "#BF5AF2",
                              action: .object(["type": .string("media"), "name": .string("playpause")])),
        OrbitRemoteDeckButton(id: "demo-lock", title: "Lock PC", symbol: "lock.fill", color: "#5EDBFF",
                              action: .object(["type": .string("system"), "name": .string("lock")])),
        OrbitRemoteDeckButton(id: "demo-sleep", title: "Sleep", symbol: "moon.fill", color: "#5E5CE6", confirm: true,
                              action: .object(["type": .string("system"), "name": .string("sleep")]))
    ], updatedAt: nil)
}

/// Shared rules for loading and running the deck from the Mac and Apple TV (the Watch runs buttons
/// through `OrbitWatchHTTPClient.runDeckButton`). Errors become sentences people can act on.
enum OrbitRemoteDeckService {
    enum LoadOutcome: Sendable {
        case deck(OrbitRemoteDeck)
        /// The PC's agent predates the deck (`/api/capabilities` is missing or has no `deck`).
        case unsupported
        case failed(String)
    }

    enum RunOutcome: Sendable {
        case done(String?)
        /// `missing` is true when the PC no longer has that button (deleted on another device).
        case failed(String, missing: Bool)
        case unsupported
    }

    static let updateAgentMessage = "Buttons need the latest Orbit agent on your PC. Update it from the Orbit icon in the Windows tray, then try again."

    private struct Capabilities: Decodable { var features: [String]? }

    /// `GET /api/capabilities`, then `GET /api/deck`. `status` reads the HTTP status out of an error.
    static func load(get: (String) async throws -> Data, status: (Error) -> Int?) async -> LoadOutcome {
        do {
            let capabilities = try JSONDecoder().decode(Capabilities.self, from: try await get("/api/capabilities"))
            guard capabilities.features?.contains(OrbitRemoteDeck.feature) == true else { return .unsupported }
        } catch {
            if status(error) == 404 { return .unsupported }
            return .failed(message(for: error, status: status(error), running: false))
        }
        do {
            return .deck(try JSONDecoder().decode(OrbitRemoteDeck.self, from: try await get("/api/deck")))
        } catch is DecodingError {
            return .failed("Your PC sent buttons this app can't read. Update Orbit on this device and on the PC.")
        } catch {
            if status(error) == 404 { return .unsupported }
            return .failed(message(for: error, status: status(error), running: false))
        }
    }

    /// `POST /api/deck/buttons/{id}/run`. Never retried: a lost reply can follow keys the PC already pressed.
    static func run(buttonID: String, post: (String) async throws -> Data, status: (Error) -> Int?) async -> RunOutcome {
        guard let path = OrbitRemoteDeck.runPath(for: buttonID) else {
            return .failed("That button is no longer on your PC. Refresh the buttons and try again.", missing: true)
        }
        do {
            let data = try await post(path)
            return .done(detail(from: data))
        } catch {
            let code = status(error)
            if code == 404 {
                if isMissingRoute(error) { return .unsupported }
                return .failed(message(for: error, status: code, running: true), missing: true)
            }
            return .failed(message(for: error, status: code, running: true), missing: false)
        }
    }

    /// The `detail` sentence of a run reply, when the PC sent one.
    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String else { return nil }
        let trimmed = String(detail.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// FastAPI answers an unknown route with the bare detail "Not Found"; the deck's own 404s are sentences.
    static func isMissingRoute(_ error: Error) -> Bool {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text == "Not Found" || text.hasPrefix("PC returned error 404")
    }

    /// Where this device pairs a PC again: the Watch has no My PCs screen, it pairs through the iPhone.
    static var pairAgainHint: String {
        #if os(watchOS)
        return "Pair this PC again in Orbit on iPhone."
        #else
        return "Pair it again in My PCs."
        #endif
    }

    static func message(for error: Error, status: Int?, running: Bool) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return running ? "Your PC didn't answer in time. The button may still have run." : "Your PC didn't answer. Check that it's awake and Orbit is running on it."
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return "Can't reach your PC. Check that it's on and on the same network."
            case .cancelled:
                return "The request was cancelled."
            default:
                break
            }
        }
        switch status {
        case 401, 403: return "Your PC didn't accept this device. \(pairAgainHint)"
        case 426: return "Your PC asked for a secure connection. \(pairAgainHint)"
        default: break
        }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "Something went wrong on your PC. Try again." : text
    }
}
