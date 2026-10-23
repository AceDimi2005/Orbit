import CryptoKit
import Foundation
import Security

// The custom button deck (DESIGN F4): the JSON model of `GET/PUT /api/deck`, the catalogues the editor
// offers (key names, Windows actions, media keys, OBS requests), the App Group cache the widgets,
// Control Center and Siri read, and a small pinned HTTPS call that runs one button from an extension.
//
// Foundation only: `Tests/check_deck_contract.py` compiles this file on its own, so keep it free of
// SwiftUI, AppIntents and other app types. The deck lives on the PC and every device shares it.

// MARK: - Limits

enum OrbitDeckLimits {
    /// Buttons a free user can add and run; Orbit Pro lifts the limit up to `maxButtons`.
    static let freeButtons = 6
    /// What `PUT /api/deck` accepts.
    static let maxButtons = 64
    static let maxSequenceSteps = 8
    static let maxTitleLength = 40
    /// The agent types at most 1,000 characters at a time (`/api/input/keyboard`).
    static let maxTextLength = 1000
    static let maxURLLength = 4096
    /// A shortcut presses at most 5 keys (`orbit_input.MAX_CHORD_KEYS`).
    static let maxChordKeys = 5
    static let defaultSequenceDelayMs = 150
    static let maxSequenceDelayMs = 5000

    static func canAddButton(existingCount: Int, isPro: Bool) -> Bool {
        existingCount < (isPro ? maxButtons : min(freeButtons, maxButtons))
    }

    /// Whether the button at `index` (0-based, in deck order) can run without Orbit Pro.
    static func isIncludedForFree(index: Int) -> Bool { index < freeButtons }
}

// MARK: - Free-form JSON (OBS request data, actions from newer apps)

enum OrbitDeckJSON: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OrbitDeckJSON])
    case array([OrbitDeckJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: OrbitDeckJSON].self) { self = .object(value) }
        else if let value = try? container.decode([OrbitDeckJSON].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var intValue: Int? {
        if case .number(let value) = self, value.rounded() == value, abs(value) <= Double(Int32.max) { return Int(value) }
        return nil
    }
    var arrayValue: [OrbitDeckJSON]? { if case .array(let value) = self { return value }; return nil }
    var objectValue: [String: OrbitDeckJSON]? { if case .object(let value) = self { return value }; return nil }
}

// MARK: - Actions

/// One deck action, tagged by `type` exactly as the agent stores it. The JSON object is kept as it
/// came from the PC, so a button made by a newer Orbit (an action type or field this version does not
/// know) survives a save from this device untouched; only an action the user edits is rebuilt.
struct OrbitDeckAction: Codable, Hashable {
    private(set) var raw: [String: OrbitDeckJSON]

    enum Kind: Hashable {
        case hotkey(keys: [String])
        case text(String)
        case openURL(String)
        case launch(appID: String)
        case system(name: String)
        case media(name: String)
        case obs(request: String, data: [String: OrbitDeckJSON])
        case sequence(steps: [OrbitDeckAction], delayMs: Int)
        /// A type (or a malformed action) this app cannot edit; `type` is what the PC sent.
        case unsupported(type: String)
    }

    init(_ kind: Kind) {
        switch kind {
        case .hotkey(let keys): raw = ["type": .string("hotkey"), "keys": .array(keys.map { .string($0) })]
        case .text(let text): raw = ["type": .string("text"), "text": .string(text)]
        case .openURL(let url): raw = ["type": .string("openUrl"), "url": .string(url)]
        case .launch(let appID): raw = ["type": .string("launch"), "appID": .string(appID)]
        case .system(let name): raw = ["type": .string("system"), "name": .string(name)]
        case .media(let name): raw = ["type": .string("media"), "name": .string(name)]
        case .obs(let request, let data): raw = ["type": .string("obs"), "request": .string(request), "data": .object(data)]
        case .sequence(let steps, let delayMs):
            raw = ["type": .string("sequence"), "steps": .array(steps.map { .object($0.raw) }), "delayMs": .number(Double(delayMs))]
        case .unsupported(let type): raw = ["type": .string(type)]
        }
    }

    init(raw: [String: OrbitDeckJSON]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try [String: OrbitDeckJSON](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    static func hotkey(_ keys: [String]) -> OrbitDeckAction { OrbitDeckAction(.hotkey(keys: keys)) }
    static func system(_ name: String) -> OrbitDeckAction { OrbitDeckAction(.system(name: name)) }
    static func media(_ name: String) -> OrbitDeckAction { OrbitDeckAction(.media(name: name)) }
    static func obs(_ request: String, _ data: [String: OrbitDeckJSON] = [:]) -> OrbitDeckAction { OrbitDeckAction(.obs(request: request, data: data)) }

    var type: String { raw["type"]?.stringValue ?? "" }

    var kind: Kind {
        switch type {
        case "hotkey":
            guard let keys = raw["keys"]?.arrayValue?.compactMap(\.stringValue), keys.count == raw["keys"]?.arrayValue?.count else { break }
            return .hotkey(keys: keys)
        case "text":
            guard let text = raw["text"]?.stringValue else { break }
            return .text(text)
        case "openUrl":
            guard let url = raw["url"]?.stringValue else { break }
            return .openURL(url)
        case "launch":
            guard let appID = raw["appID"]?.stringValue else { break }
            return .launch(appID: appID)
        case "system":
            guard let name = raw["name"]?.stringValue else { break }
            return .system(name: name)
        case "media":
            guard let name = raw["name"]?.stringValue else { break }
            return .media(name: name)
        case "obs":
            guard let request = raw["request"]?.stringValue else { break }
            return .obs(request: request, data: raw["data"]?.objectValue ?? [:])
        case "sequence":
            guard let items = raw["steps"]?.arrayValue else { break }
            let steps = items.compactMap { $0.objectValue.map(OrbitDeckAction.init(raw:)) }
            guard steps.count == items.count else { break }
            return .sequence(steps: steps, delayMs: raw["delayMs"]?.intValue ?? OrbitDeckLimits.defaultSequenceDelayMs)
        default:
            break
        }
        return .unsupported(type: type)
    }

    var isSequence: Bool { type == "sequence" }

    /// Sleep, shut down and restart, alone or as a step of a sequence (as the agent's `is_power_action`):
    /// the button must carry `confirm: true` and every device asks first.
    var isPowerAction: Bool { powerActionName != nil }

    /// `sleep`, `restart` or `shutdown` when this action (or one of its sequence steps) turns the PC off.
    var powerActionName: String? {
        switch kind {
        case .system(let name):
            return OrbitDeckCatalog.powerSystemActions.contains(name) ? name : nil
        case .sequence(let steps, _):
            return steps.lazy.compactMap(\.powerActionName).first
        default:
            return nil
        }
    }

    /// A short line for the tile and the editor, such as "Ctrl+Shift+M" or "OBS · Save replay".
    var summary: String {
        switch kind {
        case .hotkey(let keys): return keys.isEmpty ? "Shortcut" : OrbitDeckKeys.chordLabel(keys)
        case .text(let text): return text.isEmpty ? "Types text" : "Types “\(text.prefix(24))\(text.count > 24 ? "…" : "")”"
        case .openURL(let url): return url.isEmpty ? "Opens a link" : "Opens \(Self.shortURL(url))"
        case .launch: return "Opens an app"
        case .system(let name): return OrbitDeckCatalog.systemAction(name)?.title ?? "Windows action"
        case .media(let name): return "Media · \(OrbitDeckCatalog.mediaAction(name)?.title ?? name)"
        case .obs(let request, let data):
            if request == "SetCurrentProgramScene", let scene = data["sceneName"]?.stringValue { return "OBS · Scene “\(scene)”" }
            if request == "ToggleInputMute", let input = data["inputName"]?.stringValue { return "OBS · Mute “\(input)”" }
            return "OBS · \(OrbitDeckCatalog.obsShortTitles[request] ?? request)"
        case .sequence(let steps, _): return steps.count == 1 ? "Sequence · 1 step" : "Sequence · \(steps.count) steps"
        case .unsupported: return "Made by a newer Orbit"
        }
    }

    private static func shortURL(_ value: String) -> String {
        var text = value
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.count > 28 ? String(text.prefix(27)) + "…" : text
    }

    /// The agent's rule: a step that turns the PC off would cut the steps after it short.
    static let powerStepProblem = "Sleep, restart and shut down can only be the last step of a sequence."

    /// Whether step `index` of `steps` is a power action placed before the last step.
    static func isMisplacedPowerStep(_ steps: [OrbitDeckAction], at index: Int) -> Bool {
        steps.indices.contains(index) && index < steps.count - 1 && steps[index].isPowerAction
    }

    /// Why the agent would refuse this action, in plain words; nil when it is fine to save.
    func validationProblem(asStep: Bool = false) -> String? {
        switch kind {
        case .hotkey(let keys):
            if keys.isEmpty { return "Choose at least one key for the shortcut." }
            if keys.count > OrbitDeckLimits.maxChordKeys { return "A shortcut can have at most \(OrbitDeckLimits.maxChordKeys) keys." }
            if keys.contains(where: { !OrbitDeckKeys.isKnown($0) }) { return "This shortcut uses a key Orbit can't press." }
            if Set(keys.map { $0.lowercased() }).count != keys.count { return "Each key can appear only once in a shortcut." }
            if Set(["ctrl", "alt", "delete"]).isSubset(of: Set(keys.map { $0.lowercased() })) {
                return "Windows doesn't accept Ctrl+Alt+Delete from apps. Use the Lock action instead."
            }
            return nil
        case .text(let text):
            if text.isEmpty { return "Enter the text to type." }
            if text.count > OrbitDeckLimits.maxTextLength { return "Text can be at most \(OrbitDeckLimits.maxTextLength) characters." }
            return nil
        case .openURL(let url):
            return OrbitDeckCatalog.urlProblem(url)
        case .launch(let appID):
            return appID.isEmpty ? "Choose an app to open." : nil
        case .system(let name):
            // Sleep, restart and shut down are fine as a step; the sequence checks they come last.
            return OrbitDeckCatalog.systemAction(name) == nil ? "Choose a Windows action." : nil
        case .media(let name):
            return OrbitDeckCatalog.mediaAction(name) == nil ? "Choose a media key." : nil
        case .obs(let request, let data):
            guard OrbitDeckCatalog.obsRequest(request) != nil else { return "Choose what OBS should do." }
            if request == "SetCurrentProgramScene", (data["sceneName"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Choose the OBS scene to switch to."
            }
            if request == "ToggleInputMute", (data["inputName"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter the name of the OBS audio source to mute."
            }
            return nil
        case .sequence(let steps, let delayMs):
            if asStep { return "A sequence can't contain another sequence." }
            if steps.isEmpty { return "Add at least one step to the sequence." }
            if steps.count > OrbitDeckLimits.maxSequenceSteps { return "A sequence can have at most \(OrbitDeckLimits.maxSequenceSteps) steps." }
            if !(0...OrbitDeckLimits.maxSequenceDelayMs).contains(delayMs) { return "Choose a pause between steps of at most 5 seconds." }
            for (index, step) in steps.enumerated() {
                if let problem = step.validationProblem(asStep: true) { return "Step \(index + 1): \(problem)" }
            }
            if steps.dropLast().contains(where: \.isPowerAction) { return Self.powerStepProblem }
            return nil
        case .unsupported:
            return nil
        }
    }
}

// MARK: - Buttons and the deck

struct OrbitDeckButton: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    /// `#RRGGBB`
    var color: String
    var action: OrbitDeckAction
    /// Sleep, shut down and restart buttons carry `true`; the agent refuses them otherwise.
    var confirm: Bool?

    static let defaultSymbol = "square.grid.2x2.fill"
    static let defaultColor = "#0A84FF"

    init(id: String = OrbitDeckButton.newID(), title: String, symbol: String, color: String, action: OrbitDeckAction, confirm: Bool? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.action = action
        self.confirm = confirm
        normalizeConfirmation()
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    private enum CodingKeys: String, CodingKey { case id, title, symbol, color, action, confirm }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Button"
        let symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? ""
        self.symbol = symbol.isEmpty ? Self.defaultSymbol : symbol
        let color = (try? container.decodeIfPresent(String.self, forKey: .color)) ?? ""
        self.color = OrbitDeckColor.normalized(color) ?? Self.defaultColor
        action = (try? container.decode(OrbitDeckAction.self, forKey: .action)) ?? OrbitDeckAction(.unsupported(type: ""))
        confirm = try? container.decodeIfPresent(Bool.self, forKey: .confirm)
        // The agent always sends "confirm": false; keep the same normal form the editor writes, so an
        // untouched button compares equal after a round trip through the editor.
        normalizeConfirmation()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(color, forKey: .color)
        try container.encode(action, forKey: .action)
        if confirm == true { try container.encode(true, forKey: .confirm) }
    }

    /// Whether the app asks before running it: always for power actions, else when the user chose so.
    var needsConfirmation: Bool { confirm == true || action.isPowerAction }

    /// Power buttons always carry `confirm: true`, as the agent requires.
    mutating func normalizeConfirmation() {
        if action.isPowerAction { confirm = true } else if confirm != true { confirm = nil }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Button" : trimmed
    }

    func validationProblem() -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the button a name." }
        if title.count > OrbitDeckLimits.maxTitleLength { return "Button names can be at most \(OrbitDeckLimits.maxTitleLength) characters." }
        return action.validationProblem()
    }

    /// The first new or changed button the agent would refuse. Buttons exactly as the PC sent them are
    /// skipped: the PC already accepted them, even when they use something this version of Orbit
    /// doesn't check the same way (a button made on another device, by a script or a newer app).
    static func firstProblem(in buttons: [OrbitDeckButton], unchangedFrom original: [OrbitDeckButton]) -> (button: OrbitDeckButton, problem: String)? {
        let saved = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for button in buttons where saved[button.id] != button {
            if let problem = button.validationProblem() { return (button, problem) }
        }
        return nil
    }
}

/// `GET /api/deck` → `{"buttons":[Button],"updatedAt":"ISO"}`. A button the app cannot read at all
/// (no id) is skipped rather than failing the whole deck.
struct OrbitDeck: Codable, Hashable {
    var buttons: [OrbitDeckButton]
    var updatedAt: String?

    init(buttons: [OrbitDeckButton], updatedAt: String? = nil) {
        self.buttons = buttons
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case buttons, updatedAt }
    private struct Lossy: Decodable {
        let button: OrbitDeckButton?
        init(from decoder: Decoder) throws { button = try? OrbitDeckButton(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([Lossy].self, forKey: .buttons)
        var seen = Set<String>()
        buttons = items.compactMap(\.button).filter { seen.insert($0.id).inserted }
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    static func decode(_ data: Data) -> OrbitDeck? {
        try? JSONDecoder().decode(OrbitDeck.self, from: data)
    }
}

/// Body of `PUT /api/deck`. `baseUpdatedAt` is the `updatedAt` of the deck the edit started from: the
/// agent refuses the save with 409 when another device saved in between, instead of overwriting it.
/// Left out (nil) it replaces the deck unconditionally.
struct OrbitDeckUpdate: Encodable {
    let buttons: [OrbitDeckButton]
    var baseUpdatedAt: String? = nil
}

/// Body of `POST /api/deck/run`.
struct OrbitDeckRunRequest: Encodable {
    let action: OrbitDeckAction
}

/// `POST /api/deck/buttons/{id}/run` → `{"status":"done","detail":"…"}`.
struct OrbitDeckRunReply: Decodable {
    let status: String?
    let detail: String?
}

/// `GET /api/deck/obs`.
struct OrbitDeckOBSStatus: Decodable, Hashable {
    var installed = false
    var enabled = false
    var connected = false
    var scenes: [String] = []
    var currentScene: String?
    var recording = false
    var streaming = false
    var replayBuffer = false
    var reason: String?

    init(installed: Bool = false, enabled: Bool = false, connected: Bool = false, scenes: [String] = [], currentScene: String? = nil,
         recording: Bool = false, streaming: Bool = false, replayBuffer: Bool = false, reason: String? = nil) {
        self.installed = installed; self.enabled = enabled; self.connected = connected; self.scenes = scenes
        self.currentScene = currentScene; self.recording = recording; self.streaming = streaming
        self.replayBuffer = replayBuffer; self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case installed, enabled, connected, scenes, currentScene, recording, streaming, replayBuffer, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installed = (try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? false
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        connected = (try? c.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        scenes = (try? c.decodeIfPresent([String].self, forKey: .scenes)) ?? []
        currentScene = try? c.decodeIfPresent(String.self, forKey: .currentScene)
        recording = (try? c.decodeIfPresent(Bool.self, forKey: .recording)) ?? false
        streaming = (try? c.decodeIfPresent(Bool.self, forKey: .streaming)) ?? false
        replayBuffer = (try? c.decodeIfPresent(Bool.self, forKey: .replayBuffer)) ?? false
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }

    /// One sentence about OBS for the editor.
    var explanation: String {
        if connected { return scenes.isEmpty ? "OBS is connected." : "OBS is connected · \(scenes.count) scene\(scenes.count == 1 ? "" : "s")." }
        if let reason, !reason.isEmpty { return reason }
        if !installed { return "OBS Studio isn't installed on this PC. You can still add OBS buttons for later." }
        if !enabled { return "Turn on the WebSocket server in OBS (Tools → WebSocket Server Settings)." }
        return "OBS isn't running right now. OBS buttons work while it's open."
    }
}

/// `GET /api/deck/apps` → `{"apps":[{"id":"sha1 of path","name":"Spotify","iconID":"…"}]}`.
struct OrbitDeckApp: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let iconID: String?
}

struct OrbitDeckAppList: Decodable {
    let apps: [OrbitDeckApp]

    private enum CodingKeys: String, CodingKey { case apps }
    private struct Lossy: Decodable {
        let app: OrbitDeckApp?
        init(from decoder: Decoder) throws { app = try? OrbitDeckApp(from: decoder) }
    }

    init(apps: [OrbitDeckApp]) { self.apps = apps }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decode([Lossy].self, forKey: .apps).compactMap(\.app)
    }
}

/// `GET /api/capabilities` → `{"agentVersion":"4.4.0","features":[…]}`. 404 means an older agent.
struct OrbitDeckCapabilities: Decodable {
    let agentVersion: String?
    let features: [String]

    private enum CodingKeys: String, CodingKey { case agentVersion, features }
    init(agentVersion: String?, features: [String]) { self.agentVersion = agentVersion; self.features = features }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentVersion = try? c.decodeIfPresent(String.self, forKey: .agentVersion)
        features = (try? c.decodeIfPresent([String].self, forKey: .features)) ?? []
    }

    var hasDeck: Bool { features.contains("deck") }
    var hasOBS: Bool { features.contains("obs") }
}

// MARK: - Key names (orbit_input.KEY_NAMES)

enum OrbitDeckKeys {
    static let modifiers = ["ctrl", "shift", "alt", "win"]

    /// Every non-modifier key the agent can press, grouped for the key picker. Mirrors
    /// `orbit_input._build_keys()`; `check_deck_contract.py` compares the two.
    static let groups: [(title: String, keys: [String])] = [
        ("Letters", "abcdefghijklmnopqrstuvwxyz".map(String.init)),
        ("Numbers", (0...9).map(String.init)),
        ("Function keys", (1...24).map { "f\($0)" }),
        ("Common", ["enter", "esc", "tab", "space", "backspace", "delete", "insert", "printscreen", "pause", "menu"]),
        ("Navigation", ["up", "down", "left", "right", "home", "end", "pageup", "pagedown"]),
        ("Symbols", ["minus", "equals", "comma", "period", "slash", "backslash", "semicolon", "quote", "bracketleft", "bracketright", "grave"]),
        ("Number pad", (0...9).map { "numpad\($0)" }),
        ("Media", ["playpause", "nexttrack", "prevtrack", "stop", "volumeup", "volumedown", "volumemute"]),
        ("Lock keys", ["capslock", "numlock", "scrolllock"])
    ]

    static let allKeys: Set<String> = Set(modifiers + groups.flatMap(\.keys))

    static func isKnown(_ key: String) -> Bool { allKeys.contains(key.lowercased()) }
    static func isModifier(_ key: String) -> Bool { modifiers.contains(key.lowercased()) }

    private static let labels: [String: String] = [
        "ctrl": "Ctrl", "shift": "Shift", "alt": "Alt", "win": "Win", "esc": "Esc", "pageup": "Page Up",
        "pagedown": "Page Down", "printscreen": "Print Screen", "capslock": "Caps Lock", "numlock": "Num Lock",
        "scrolllock": "Scroll Lock", "backspace": "Backspace", "volumeup": "Volume Up", "volumedown": "Volume Down",
        "volumemute": "Mute", "playpause": "Play/Pause", "nexttrack": "Next Track", "prevtrack": "Previous Track",
        "minus": "-", "equals": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "bracketleft": "[", "bracketright": "]", "grave": "`",
        "up": "↑", "down": "↓", "left": "←", "right": "→"
    ]

    /// "Ctrl", "M", "F10", "Page Up"… as the agent's `chord_label` writes them.
    static func label(_ key: String) -> String {
        let name = key.lowercased()
        if let label = labels[name] { return label }
        if name.count == 1 || (name.hasPrefix("f") && Int(name.dropFirst()) != nil) { return name.uppercased() }
        if name.hasPrefix("numpad"), let digit = name.last { return "Num \(digit)" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Long name for the picker list ("Up arrow" instead of "↑").
    static func pickerLabel(_ key: String) -> String {
        switch key {
        case "up": return "Up arrow"
        case "down": return "Down arrow"
        case "left": return "Left arrow"
        case "right": return "Right arrow"
        case "minus": return "Minus (-)"
        case "equals": return "Equals (=)"
        case "comma": return "Comma (,)"
        case "period": return "Period (.)"
        case "slash": return "Slash (/)"
        case "backslash": return "Backslash (\\)"
        case "semicolon": return "Semicolon (;)"
        case "quote": return "Quote (')"
        case "bracketleft": return "Left bracket ([)"
        case "bracketright": return "Right bracket (])"
        case "grave": return "Grave accent (`)"
        case "menu": return "Menu key"
        case "space": return "Space"
        case "enter": return "Enter"
        case "tab": return "Tab"
        case "delete": return "Delete"
        case "insert": return "Insert"
        case "home": return "Home"
        case "end": return "End"
        case "pause": return "Pause"
        case "stop": return "Stop (media)"
        default: return label(key)
        }
    }

    /// Modifiers first (Ctrl, Shift, Alt, Win), then the other keys in the order given.
    static func ordered(_ keys: [String]) -> [String] {
        let lowered = keys.map { $0.lowercased() }
        return modifiers.filter(lowered.contains) + lowered.filter { !isModifier($0) }
    }

    static func chordLabel(_ keys: [String]) -> String {
        ordered(keys).map(label).joined(separator: "+")
    }
}

// MARK: - Catalogues

struct OrbitDeckChoice: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String
}

enum OrbitDeckCatalog {
    /// `system {name}`: names `perform_action` accepts.
    static let systemActions: [OrbitDeckChoice] = [
        OrbitDeckChoice(id: "lock", title: "Lock PC", symbol: "lock.fill"),
        OrbitDeckChoice(id: "show_desktop", title: "Show desktop", symbol: "menubar.dock.rectangle"),
        OrbitDeckChoice(id: "task_view", title: "Task view", symbol: "rectangle.3.group"),
        OrbitDeckChoice(id: "alt_tab", title: "Switch window (Alt+Tab)", symbol: "rectangle.on.rectangle"),
        OrbitDeckChoice(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder"),
        OrbitDeckChoice(id: "fullscreen", title: "Full screen (F11)", symbol: "arrow.up.left.and.arrow.down.right"),
        OrbitDeckChoice(id: "toggle_hdr", title: "Toggle HDR", symbol: "sun.max.fill"),
        OrbitDeckChoice(id: "restore_display", title: "Restore displays", symbol: "display.2"),
        OrbitDeckChoice(id: "kill_game", title: "Close the game", symbol: "xmark.square.fill"),
        OrbitDeckChoice(id: "sleep", title: "Sleep", symbol: "moon.zzz.fill"),
        OrbitDeckChoice(id: "restart", title: "Restart", symbol: "arrow.clockwise.circle.fill"),
        OrbitDeckChoice(id: "shutdown", title: "Shut down", symbol: "power")
    ]
    static let powerSystemActions: Set<String> = ["sleep", "restart", "shutdown"]

    /// Other names `perform_action` accepts. The editor offers these as media keys instead, but a button
    /// made on another device or by a script may use them, so they are shown, kept and saved as they are.
    static let otherSystemActions: [OrbitDeckChoice] = [
        OrbitDeckChoice(id: "mute", title: "Mute", symbol: "speaker.slash.fill"),
        OrbitDeckChoice(id: "volume_up", title: "Volume up", symbol: "speaker.wave.3.fill"),
        OrbitDeckChoice(id: "volume_down", title: "Volume down", symbol: "speaker.wave.1.fill"),
        OrbitDeckChoice(id: "media_play_pause", title: "Play/Pause", symbol: "playpause.fill"),
        OrbitDeckChoice(id: "media_next", title: "Next track", symbol: "forward.fill"),
        OrbitDeckChoice(id: "media_prev", title: "Previous track", symbol: "backward.fill")
    ]

    /// `media {name}`.
    static let mediaActions: [OrbitDeckChoice] = [
        OrbitDeckChoice(id: "playpause", title: "Play/Pause", symbol: "playpause.fill"),
        OrbitDeckChoice(id: "next", title: "Next track", symbol: "forward.fill"),
        OrbitDeckChoice(id: "previous", title: "Previous track", symbol: "backward.fill"),
        OrbitDeckChoice(id: "mute", title: "Mute", symbol: "speaker.slash.fill"),
        OrbitDeckChoice(id: "volumeup", title: "Volume up", symbol: "speaker.wave.3.fill"),
        OrbitDeckChoice(id: "volumedown", title: "Volume down", symbol: "speaker.wave.1.fill")
    ]

    /// `obs {request, data}`: the agent's allowlist.
    static let obsRequests: [OrbitDeckChoice] = [
        OrbitDeckChoice(id: "ToggleRecord", title: "Start or stop recording", symbol: "record.circle"),
        OrbitDeckChoice(id: "StartRecord", title: "Start recording", symbol: "record.circle.fill"),
        OrbitDeckChoice(id: "StopRecord", title: "Stop recording", symbol: "stop.circle.fill"),
        OrbitDeckChoice(id: "ToggleStream", title: "Start or stop streaming", symbol: "dot.radiowaves.left.and.right"),
        OrbitDeckChoice(id: "SaveReplayBuffer", title: "Save replay", symbol: "clock.arrow.circlepath"),
        OrbitDeckChoice(id: "StartReplayBuffer", title: "Start replay buffer", symbol: "gobackward"),
        OrbitDeckChoice(id: "SetCurrentProgramScene", title: "Switch scene", symbol: "rectangle.on.rectangle"),
        OrbitDeckChoice(id: "ToggleInputMute", title: "Mute or unmute a source", symbol: "mic.slash.fill")
    ]

    /// Short names for tiles ("OBS · Toggle recording").
    static let obsShortTitles: [String: String] = [
        "ToggleRecord": "Toggle recording", "StartRecord": "Start recording", "StopRecord": "Stop recording",
        "ToggleStream": "Toggle stream", "SaveReplayBuffer": "Save replay", "StartReplayBuffer": "Start replay buffer",
        "SetCurrentProgramScene": "Switch scene", "ToggleInputMute": "Toggle mute"
    ]

    /// Link schemes the agent opens (`openUrl`).
    static let urlSchemes = ["http", "https", "steam", "com.epicgames.launcher", "spotify", "discord", "ms-settings"]

    static func systemAction(_ name: String) -> OrbitDeckChoice? {
        systemActions.first { $0.id == name } ?? otherSystemActions.first { $0.id == name }
    }
    static func mediaAction(_ name: String) -> OrbitDeckChoice? { mediaActions.first { $0.id == name } }
    static func obsRequest(_ name: String) -> OrbitDeckChoice? { obsRequests.first { $0.id == name } }

    static func urlProblem(_ value: String) -> String? {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return "Enter the link to open." }
        if url.count > OrbitDeckLimits.maxURLLength { return "This link is too long." }
        if url.contains(where: { $0.isWhitespace || "\"<>\\^`{|}".contains($0) }) {
            return "This link contains spaces or characters such as quotes that must be percent-encoded."
        }
        guard let colon = url.firstIndex(of: ":") else { return "Start the link with https:// (or steam://, spotify:, discord://…)." }
        let scheme = url[..<colon].lowercased()
        guard urlSchemes.contains(scheme) else {
            return "Orbit can open web links and steam://, com.epicgames.launcher://, spotify:, discord:// and ms-settings: links."
        }
        if scheme == "http" || scheme == "https" {
            guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty,
                  url.dropFirst(scheme.count).hasPrefix("://") else { return "Use a full web address such as https://example.com." }
            if components.user != nil || components.password != nil { return "Links with a user name or password can't be opened from Orbit." }
        }
        return nil
    }
}

// MARK: - Colors

enum OrbitDeckColor {
    /// Swatches offered by the editor.
    static let palette = ["#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#66D4CF", "#40C8E0", "#64D2FF", "#0A84FF",
                          "#5E5CE6", "#BF5AF2", "#FF375F", "#AC8E68", "#8E8E93", "#5865F2", "#76B900", "#ED1C24"]

    /// `#RRGGBB` in upper case, or nil when `value` is not a 6-digit hex colour.
    static func normalized(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + hex.uppercased()
    }

    static func components(_ value: String) -> (red: Double, green: Double, blue: Double) {
        let hex = String((normalized(value) ?? OrbitDeckButton.defaultColor).dropFirst())
        let number = UInt32(hex, radix: 16) ?? 0x0A84FF
        return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - Sample deck (demo mode and previews)

enum OrbitDeckSamples {
    static let demoDeck = OrbitDeck(buttons: [
        OrbitDeckButton(id: "demo-mute", title: "Mute Discord", symbol: "mic.slash.fill", color: "#5865F2", action: .hotkey(["ctrl", "shift", "m"])),
        OrbitDeckButton(id: "demo-deafen", title: "Deafen", symbol: "headphones", color: "#5865F2", action: .hotkey(["ctrl", "shift", "d"])),
        OrbitDeckButton(id: "demo-clip", title: "Clip that", symbol: "film", color: "#76B900", action: .hotkey(["alt", "f10"])),
        OrbitDeckButton(id: "demo-record", title: "Record", symbol: "record.circle", color: "#FF453A", action: .obs("ToggleRecord")),
        OrbitDeckButton(id: "demo-scene", title: "BRB scene", symbol: "rectangle.on.rectangle", color: "#64D2FF",
                        action: .obs("SetCurrentProgramScene", ["sceneName": .string("BRB")])),
        OrbitDeckButton(id: "demo-play", title: "Play/Pause", symbol: "playpause.fill", color: "#FF375F", action: .media("playpause"))
    ], updatedAt: nil)

    static let demoOBS = OrbitDeckOBSStatus(installed: true, enabled: true, connected: true,
                                            scenes: ["Gaming", "Just Chatting", "Starting Soon", "BRB"], currentScene: "Gaming")

    static let demoApps = OrbitDeckAppList(apps: [
        OrbitDeckApp(id: "demo-discord", name: "Discord", iconID: nil),
        OrbitDeckApp(id: "demo-obs", name: "OBS Studio", iconID: nil),
        OrbitDeckApp(id: "demo-spotify", name: "Spotify", iconID: nil),
        OrbitDeckApp(id: "demo-steam", name: "Steam", iconID: nil)
    ])
}

// MARK: - App Group cache (widgets, Control Center, Siri, Apple Watch)

/// The last `GET /api/deck` reply per PC (the PUT reply has the same shape), under `Orbit.Deck.v1.<pcID>`
/// in the App Group defaults. The app writes it whenever it fetches or saves the deck, and so does a
/// widget, control or Siri run, which reads the deck from the PC before running a button.
enum OrbitDeckCache {
    static let keyPrefix = "Orbit.Deck.v1."
    private static let feedbackKey = "Orbit.DeckFeedback.v1"
    private static let feedbackTimeKey = "Orbit.DeckFeedbackTime.v1"
    private static let feedbackSuccessKey = "Orbit.DeckFeedbackSuccess.v1"
    private static let feedbackPCKey = "Orbit.DeckFeedbackPC.v1"
    private static let maxBytes = 512 * 1024

    private static var defaults: UserDefaults {
        if let group = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String,
           group.hasPrefix("group."), !group.contains("$("),
           let shared = UserDefaults(suiteName: group) {
            return shared
        }
        return .standard
    }

    static func key(for pcID: String) -> String { keyPrefix + pcID }

    /// Stores the reply when it is a deck. Returns true when the stored bytes changed.
    @discardableResult
    static func store(_ json: Data, for pcID: String) -> Bool {
        guard !pcID.isEmpty, json.count <= maxBytes, OrbitDeck.decode(json) != nil else { return false }
        let store = defaults
        if store.data(forKey: key(for: pcID)) == json { return false }
        store.set(json, forKey: key(for: pcID))
        return true
    }

    static func data(for pcID: String) -> Data? {
        guard !pcID.isEmpty else { return nil }
        return defaults.data(forKey: key(for: pcID))
    }

    static func deck(for pcID: String) -> OrbitDeck? {
        data(for: pcID).flatMap(OrbitDeck.decode)
    }

    static func remove(pcID: String) {
        guard !pcID.isEmpty else { return }
        defaults.removeObject(forKey: key(for: pcID))
    }

    /// A short result line the Buttons widget shows for half a minute after a tap. `pcID` is the PC the
    /// button ran on (nil when no PC could be chosen), so a widget set to another PC doesn't show it.
    static func recordFeedback(_ message: String, success: Bool, pcID: String?) {
        let store = defaults
        store.set(String(message.prefix(120)), forKey: feedbackKey)
        store.set(success, forKey: feedbackSuccessKey)
        store.set(pcID ?? "", forKey: feedbackPCKey)
        store.set(Date().timeIntervalSince1970, forKey: feedbackTimeKey)
    }

    /// The last result for `pcID` (or one that names no PC) if it is younger than `maxAge`.
    static func recentFeedback(for pcID: String?, maxAge: TimeInterval = 30) -> (message: String, success: Bool, expires: Date)? {
        let store = defaults
        let time = store.double(forKey: feedbackTimeKey)
        guard time > 0, let message = store.string(forKey: feedbackKey) else { return nil }
        let age = Date().timeIntervalSince1970 - time
        guard age >= 0, age < maxAge else { return nil }
        let recordedPC = store.string(forKey: feedbackPCKey) ?? ""
        guard recordedPC.isEmpty || recordedPC == pcID else { return nil }
        return (message, store.bool(forKey: feedbackSuccessKey), Date(timeIntervalSince1970: time + maxAge))
    }
}

// MARK: - Plain-words errors

struct OrbitDeckRequestError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }

    static let unreachable = "Your PC isn't reachable. Wake it from Orbit and try again."

    /// Turns a transport error into a sentence; an error that already carries one is kept.
    static func message(for error: Error, pcName: String? = nil) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                if let pcName, !pcName.isEmpty { return "\(pcName) isn't reachable. Wake it from Orbit and try again." }
                return unreachable
            case .cancelled:
                return "The request was cancelled."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                return "The PC's security certificate changed. Pair the PC again in Orbit."
            default:
                return "Orbit couldn't reach the PC (\(urlError.localizedDescription))."
            }
        }
        return error.localizedDescription
    }

    static let olderAgent = "Buttons need a newer Orbit agent on the PC. Update it, then try again."

    /// A 404 whose body is FastAPI's own "Not Found" (or nothing): the agent has no such route.
    static func isMissingRoute(_ detail: String?) -> Bool {
        let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text == "Not Found"
    }

    /// A 404 from running a button that means the button itself is gone from the PC. The agent also
    /// answers 404 when an app the button opens left the Start menu (or such a sequence step failed);
    /// those replies carry their own sentence and the button is still there.
    static func isMissingButton(status: Int?, detail: String?) -> Bool {
        guard status == 404 else { return false }
        let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isMissingRoute(text) || text.hasPrefix("PC returned error")
            || text.hasPrefix("This button is no longer on the PC") || text.hasPrefix("This button isn't on the PC")
    }
}

// MARK: - Running a button from an extension

/// A pinned HTTPS call for widgets, Control Center and Siri, which cannot use the app's client. The
/// server certificate must match the paired SHA-256 fingerprint; redirects are refused.
enum OrbitDeckHTTP {
    struct Target {
        let host: String
        let port: Int
        let fingerprint: String
        let token: String
    }

    static func runButton(id: String, on target: Target, timeout: TimeInterval = 10) async throws -> OrbitDeckRunReply {
        guard !id.isEmpty, id.count <= 128,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else {
            throw OrbitDeckRequestError(message: "This button can't be run. Open Orbit to refresh your buttons.")
        }
        let data = try await request(path: "/api/deck/buttons/\(encoded)/run", method: "POST", on: target, timeout: timeout)
        return (try? JSONDecoder().decode(OrbitDeckRunReply.self, from: data)) ?? OrbitDeckRunReply(status: "done", detail: nil)
    }

    /// `GET /api/deck`, stored in the cache for `pcID`. `changed` tells whether the cached copy changed
    /// (the widget and the control then need to redraw).
    static func fetchDeck(on target: Target, pcID: String, timeout: TimeInterval = 6) async throws -> (deck: OrbitDeck, changed: Bool) {
        let data: Data
        do {
            data = try await request(path: "/api/deck", method: "GET", on: target, timeout: timeout)
        } catch let error as OrbitDeckRequestError where error.statusCode == 404 {
            throw OrbitDeckRequestError(message: OrbitDeckRequestError.olderAgent, statusCode: 404)
        }
        guard let deck = OrbitDeck.decode(data) else {
            throw OrbitDeckRequestError(message: "The PC sent buttons this version of Orbit can't read. Update Orbit and try again.")
        }
        return (deck, OrbitDeckCache.store(data, for: pcID))
    }

    static func request(path: String, method: String, body: Data? = nil, on target: Target, timeout: TimeInterval) async throws -> Data {
        let fingerprint = target.fingerprint.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !target.host.isEmpty, !target.host.contains("/"), !target.host.contains(":"), (1...65535).contains(target.port),
              fingerprint.count == 64, !target.token.isEmpty else {
            throw OrbitDeckRequestError(message: "Open Orbit once to refresh this PC's connection.")
        }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = target.host
        parts.port = target.port
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw OrbitDeckRequestError(message: "The PC address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = PinnedDelegate(fingerprint: fingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if delegate.rejectedCertificate {
                throw OrbitDeckRequestError(message: "The PC's security certificate changed. Pair the PC again in Orbit.")
            }
            throw OrbitDeckRequestError(message: OrbitDeckRequestError.message(for: error))
        }
        guard let http = response as? HTTPURLResponse else { throw OrbitDeckRequestError(message: "The PC did not return a valid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw OrbitDeckRequestError(message: describe(status: http.statusCode, detail: detail), statusCode: http.statusCode)
        }
        return data
    }

    /// The agent's sentence when it sent one, else a plain explanation of the status code.
    static func describe(status: Int, detail: String?) -> String {
        if status == 404 && OrbitDeckRequestError.isMissingRoute(detail) { return OrbitDeckRequestError.olderAgent }
        if let detail, !detail.isEmpty, status != 401 { return detail }
        switch status {
        case 401: return "The PC rejected Orbit's token. Open Orbit and pair the PC again."
        case 404: return "This button isn't on the PC anymore. Open Buttons in Orbit to refresh."
        case 426: return "Buttons need Orbit's encrypted connection. Pair the PC again in Orbit."
        case 501: return "Buttons need the Orbit agent on Windows."
        default: return "The PC couldn't run the button (error \(status))."
        }
    }

    private final class PinnedDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let fingerprint: String
        private(set) var rejectedCertificate = false
        init(fingerprint: String) { self.fingerprint = fingerprint }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let received = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            guard received == fingerprint,
                  SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                rejectedCertificate = true
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
