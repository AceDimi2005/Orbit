import AppIntents
import Foundation

// Shortcuts actions (App Intents): the parts that do not touch the network or the App Group.
//
// Compiled into Orbit and OrbitWidgets. `Tests/check_intents.py` compiles this file on its own
// against real agent JSON, so keep it free of other app types (Foundation and AppIntents only).

// MARK: - Errors

/// The failure every Orbit Shortcuts action reports: one plain sentence that Shortcuts and Siri
/// show as is.
struct OrbitIntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    enum Kind: Equatable { case general, noPC, removedPC, demo, needsSetup, unreachable, localNetwork, certificate, accessRevoked, olderCompanion, invalidInput }

    let kind: Kind
    let message: String

    init(_ message: String, kind: Kind = .general) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }

    static let noPC = OrbitIntentError("Pair a PC in Orbit first, then run this action again.", kind: .noPC)
    static let removedPC = OrbitIntentError("This shortcut uses a PC that is no longer saved in Orbit. Edit the shortcut and choose another PC.", kind: .removedPC)
    static let demo = OrbitIntentError("Orbit is in Demo Mode, so it won't contact a PC. Turn off Demo Mode in Orbit's Settings and pair your PC to use this action.", kind: .demo)

    static func needsSetup(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("Open Orbit once while \(pc) is connected, so Shortcuts can control it.", kind: .needsSetup)
    }
    static func unreachable(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("\(pc) isn't reachable. Make sure it's turned on and on the same network as this device, then try again.", kind: .unreachable)
    }
    static func localNetworkDenied(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("Orbit needs Local Network access to reach \(pc). Turn it on in Settings → Privacy & Security → Local Network.", kind: .localNetwork)
    }
    static func certificateChanged(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("\(pc)'s security certificate doesn't match the one Orbit paired with. Pair the PC again in Orbit.", kind: .certificate)
    }
    static func secureConnectionFailed(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("Orbit couldn't open an encrypted connection to \(pc). Pair the PC again in Orbit.", kind: .certificate)
    }
    static func accessRevoked(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("\(pc) didn't accept Orbit's access key. Pair the PC again in Orbit.", kind: .accessRevoked)
    }
    static func olderCompanion(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("This action needs a newer Orbit Companion on \(pc). Update it from Orbit: Settings → PC Companion Updates.", kind: .olderCompanion)
    }
    static func unexpectedReply(_ pc: String) -> OrbitIntentError {
        OrbitIntentError("\(pc) sent a reply Orbit doesn't understand. Update Orbit Companion on the PC, then try again.")
    }
    static func invalid(_ message: String) -> OrbitIntentError {
        OrbitIntentError(message, kind: .invalidInput)
    }

    /// The sentence for a reply outside 200–299. `detail` is the agent's FastAPI `detail`, which the
    /// agent always writes as a sentence for the user.
    static func reply(status: Int, detail: String?, pc: String) -> OrbitIntentError {
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = (detail?.isEmpty == false && detail != "Not Found" && detail != "Method Not Allowed") ? detail : nil
        switch status {
        case 401:
            return .accessRevoked(pc)
        case 404 where usable == nil, 405:
            // FastAPI's own "Not Found" means the route does not exist: an agent from before this action.
            return .olderCompanion(pc)
        case 501:
            return OrbitIntentError("This action only works when Orbit Companion runs on Windows.")
        default:
            if let usable { return OrbitIntentError(sentence(usable)) }
            return OrbitIntentError("\(pc) couldn't do that (error \(status)). Try again, or update Orbit Companion on the PC.")
        }
    }

    /// FastAPI's `detail`: a sentence, or for validation errors a list whose first entry has `msg`.
    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = object["detail"] as? String { return text }
        if let list = object["detail"] as? [[String: Any]], let message = list.first?["msg"] as? String { return message }
        return nil
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }
}

// MARK: - Choices shown in Shortcuts

/// A live reading `Get PC Reading` returns, always in the unit Orbit shows everywhere.
enum OrbitPCReading: String, AppEnum, CaseIterable {
    case cpuTemperature, gpuTemperature, cpuUsage, gpuUsage, memoryUsage, fps, cpuPower, gpuPower, totalPower

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PC Reading")
    static let caseDisplayRepresentations: [OrbitPCReading: DisplayRepresentation] = [
        .cpuTemperature: "CPU temperature (°C)",
        .gpuTemperature: "GPU temperature (°C)",
        .cpuUsage: "CPU load (%)",
        .gpuUsage: "GPU load (%)",
        .memoryUsage: "Memory used (%)",
        .fps: "Game FPS",
        .cpuPower: "CPU power (W)",
        .gpuPower: "GPU power (W)",
        .totalPower: "CPU + GPU power (W)"
    ]

    /// Lower-case name for sentences ("Gaming PC's CPU temperature is 62 °C").
    var title: String {
        switch self {
        case .cpuTemperature: "CPU temperature"
        case .gpuTemperature: "GPU temperature"
        case .cpuUsage: "CPU load"
        case .gpuUsage: "GPU load"
        case .memoryUsage: "memory use"
        case .fps: "game FPS"
        case .cpuPower: "CPU power draw"
        case .gpuPower: "GPU power draw"
        case .totalPower: "CPU and GPU power draw"
        }
    }

    var unit: String {
        switch self {
        case .cpuTemperature, .gpuTemperature: "°C"
        case .cpuUsage, .gpuUsage, .memoryUsage: "%"
        case .fps: "FPS"
        case .cpuPower, .gpuPower, .totalPower: "W"
        }
    }

    /// "62 °C", "45%", "144 FPS", "230 W".
    func formatted(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero).grouping(.never))
        return unit == "%" ? number + "%" : number + " " + unit
    }
}

/// `PC Media` buttons, mapped onto the agent's `/api/action/{name}` media keys.
enum OrbitPCMediaAction: String, AppEnum, CaseIterable {
    case playPause, next, previous

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media Control")
    static let caseDisplayRepresentations: [OrbitPCMediaAction: DisplayRepresentation] = [
        .playPause: "Play/Pause",
        .next: "Next Track",
        .previous: "Previous Track"
    ]

    var agentAction: String {
        switch self {
        case .playPause: "media_play_pause"
        case .next: "media_next"
        case .previous: "media_prev"
        }
    }
}

/// What the PC does once its downloads finish (`PUT /api/power/after`).
enum OrbitPCPowerAfterAction: String, AppEnum, CaseIterable {
    case sleep, shutdown

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Power Action")
    static let caseDisplayRepresentations: [OrbitPCPowerAfterAction: DisplayRepresentation] = [
        .sleep: "Sleep",
        .shutdown: "Shut Down"
    ]

    var verb: String { self == .sleep ? "sleep" : "shut down" }
}

// MARK: - Agent replies

/// The parts of `GET /api/status` the Shortcuts actions read. Every field is optional and decoded on
/// its own, so an older or newer agent never breaks an action, and impossible sensor values
/// (a 400 % load, a 1e300 W reading) count as missing instead of being reported.
struct OrbitPCStatusReport: Decodable {
    var hostname: String?
    var telemetryAvailable: Bool?
    var cpuUsage: Double?
    var gpuUsage: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var ramUsedGB: Double?
    var ramTotalGB: Double?
    var fps: Double?
    var fpsUnavailableReason: String?
    var cpuPowerWatts: Double?
    var gpuPowerWatts: Double?
    var activeGame: String?
    var sensorStatus: String?
    var isMuted: Bool?
    var volume: Double?
    var volumeAvailable: Bool?
    var sessionLocked: Bool?

    private enum CodingKeys: String, CodingKey {
        case hostname, telemetryAvailable, cpuUsage, gpuUsage, cpuTemp, gpuTemp, ramUsedGB, ramTotalGB, fps
        case fpsUnavailableReason, cpuPowerWatts, gpuPowerWatts, activeGame, sensorStatus, isMuted, volume
        case volumeAvailable, sessionLocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys, _ range: ClosedRange<Double>) -> Double? {
            guard let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite, range.contains(value) else { return nil }
            return value
        }
        func text(_ key: CodingKeys) -> String? {
            let value = (try? c.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func flag(_ key: CodingKeys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: key) }
        hostname = text(.hostname)
        telemetryAvailable = flag(.telemetryAvailable)
        cpuUsage = number(.cpuUsage, 0...100)
        gpuUsage = number(.gpuUsage, 0...100)
        cpuTemp = number(.cpuTemp, -40...150)
        gpuTemp = number(.gpuTemp, -40...150)
        ramUsedGB = number(.ramUsedGB, 0...65_536)
        ramTotalGB = number(.ramTotalGB, 0...65_536)
        fps = number(.fps, 0...2_000)
        fpsUnavailableReason = text(.fpsUnavailableReason)
        cpuPowerWatts = number(.cpuPowerWatts, 0...2_000)
        gpuPowerWatts = number(.gpuPowerWatts, 0...2_000)
        activeGame = text(.activeGame)
        sensorStatus = text(.sensorStatus)
        isMuted = flag(.isMuted)
        volume = number(.volume, 0...100)
        volumeAvailable = flag(.volumeAvailable)
        sessionLocked = flag(.sessionLocked)
    }

    var memoryUsage: Double? {
        guard let used = ramUsedGB, let total = ramTotalGB, total > 0, used <= total else { return nil }
        return used / total * 100
    }

    /// The reading in its unit, rounded to one decimal; nil when the PC does not report it.
    func value(_ reading: OrbitPCReading) -> Double? {
        let raw: Double?
        switch reading {
        case .cpuTemperature: raw = cpuTemp
        case .gpuTemperature: raw = gpuTemp
        case .cpuUsage: raw = cpuUsage
        case .gpuUsage: raw = gpuUsage
        case .memoryUsage: raw = memoryUsage
        case .fps: raw = fps
        case .cpuPower: raw = cpuPowerWatts
        case .gpuPower: raw = gpuPowerWatts
        case .totalPower:
            raw = (cpuPowerWatts == nil && gpuPowerWatts == nil) ? nil : (cpuPowerWatts ?? 0) + (gpuPowerWatts ?? 0)
        }
        return raw.map { ($0 * 10).rounded() / 10 }
    }

    /// "Gaming PC's CPU temperature is 62 °C." (total power names the parts it adds up).
    func readingSentence(_ reading: OrbitPCReading, value: Double, pc: String) -> String {
        var sentence = "\(pc)'s \(reading.title) is \(reading.formatted(value))"
        if reading == .totalPower {
            switch (cpuPowerWatts, gpuPowerWatts) {
            case let (cpu?, gpu?): sentence += " (CPU \(reading.formatted(cpu)) + GPU \(reading.formatted(gpu)))"
            case (nil, _?): sentence += " (GPU only; the PC doesn't report CPU power)"
            case (_?, nil): sentence += " (CPU only; the PC doesn't report GPU power)"
            default: break
            }
        }
        return sentence + "."
    }

    /// Why a reading is missing, in one sentence.
    func missingReason(_ reading: OrbitPCReading, pc: String) -> String {
        if telemetryAvailable == false {
            return "\(pc) isn't reporting live readings right now. Try again in a few seconds."
        }
        switch reading {
        case .fps:
            let reason = fpsUnavailableReason.map { " \(Self.sentence($0))" } ?? ""
            return activeGame == nil ? "No game is running on \(pc), so there's no FPS to read." : "\(pc) isn't measuring the game's FPS right now.\(reason)"
        case .cpuTemperature, .gpuTemperature, .cpuPower, .gpuPower, .totalPower:
            let reason = sensorStatus.map { " \(Self.sentence($0))" } ?? ""
            return "\(pc) isn't reporting its \(reading.title) right now.\(reason)"
        case .cpuUsage, .gpuUsage, .memoryUsage:
            return "\(pc) isn't reporting its \(reading.title) right now."
        }
    }

    /// One friendly sentence about the PC, for `Get PC Status`.
    func statusSentence(pc: String) -> String {
        var head = "\(pc) is on"
        if sessionLocked == true { head += " but locked" }
        if let game = activeGame {
            head += ", running \(game)"
            if let fps, fps > 0 { head += " at \(OrbitPCReading.fps.formatted(fps))" }
        }
        guard telemetryAvailable != false else {
            return head + ", but it isn't reporting live readings right now."
        }
        var parts: [String] = []
        if let usage = cpuUsage {
            parts.append("CPU \(OrbitPCReading.cpuUsage.formatted(usage))" + (cpuTemp.map { " at \(OrbitPCReading.cpuTemperature.formatted($0))" } ?? ""))
        } else if let temp = cpuTemp {
            parts.append("CPU at \(OrbitPCReading.cpuTemperature.formatted(temp))")
        }
        if let usage = gpuUsage {
            parts.append("GPU \(OrbitPCReading.gpuUsage.formatted(usage))" + (gpuTemp.map { " at \(OrbitPCReading.gpuTemperature.formatted($0))" } ?? ""))
        } else if let temp = gpuTemp {
            parts.append("GPU at \(OrbitPCReading.gpuTemperature.formatted(temp))")
        }
        if let memory = memoryUsage { parts.append("memory \(OrbitPCReading.memoryUsage.formatted(memory)) used") }
        return parts.isEmpty ? head + "." : head + ": " + parts.joined(separator: ", ") + "."
    }

    static func offlineSentence(pc: String) -> String {
        "\(pc) isn't reachable right now. It may be asleep, turned off or on another network."
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }
}

/// One entry of `GET /api/sunshine/apps`.
struct OrbitSunshineAppEntry: Decodable {
    var id: String?
    var title: String
}

/// `GET /api/capabilities`.
struct OrbitAgentCapabilities: Decodable {
    var agentVersion: String?
    var features: [String]
}

/// `PUT /api/power/after` body (DESIGN.md F1). `taskID` is always sent, as `null` for downloads.
struct OrbitPowerAfterRequest: Encodable {
    var trigger = "downloads"
    var action: String
    var delaySeconds: Int
    var taskID: String? = nil

    private enum CodingKeys: String, CodingKey { case trigger, action, delaySeconds, taskID }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encode(delaySeconds, forKey: .delaySeconds)
        try c.encode(taskID, forKey: .taskID)
    }
}

/// `GET /api/downloads` (only what the dialog needs).
struct OrbitDownloadsReport: Decodable {
    struct Item: Decodable { var state: String? }
    var downloads: [Item]?
    var active: Bool?

    var unfinishedCount: Int {
        (downloads ?? []).filter { ["queued", "downloading", "staging", "paused"].contains($0.state ?? "") }.count
    }
}

// MARK: - Input checks

/// Checks Shortcuts input before anything is sent, with the same limits the agent enforces, so
/// users get a clear sentence instead of a raw validation error.
enum OrbitIntentInput {
    /// `/api/input/keyboard` types at most 1000 characters (Python `len`, i.e. Unicode scalars).
    static let maxTypedCharacters = 1000
    /// `PUT /api/clipboard`: UTF-16 text plus its terminator must fit in 1 MiB.
    static let maxClipboardUTF16Units = 1024 * 1024 / 2 - 1
    /// `POST /api/open-url` (`orbit_links.MAX_URL_LENGTH`).
    static let maxURLLength = 4096
    static let powerAfterDelay = 30...600

    /// Text for `Type Text on PC`. Line breaks become Enter presses (a bare line feed would be
    /// typed as Ctrl+Enter by Windows, which sends messages in many chat apps).
    static func typedText(_ text: String) throws -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard !normalized.isEmpty else { throw OrbitIntentError.invalid("There's no text to type.") }
        guard normalized.unicodeScalars.count <= maxTypedCharacters else {
            throw OrbitIntentError.invalid("Orbit can type up to \(maxTypedCharacters) characters at a time. Use Copy Text to PC Clipboard for longer text.")
        }
        guard normalized.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF }) else {
            throw OrbitIntentError.invalid("Emoji and some symbols can't be typed on the PC. Use Copy Text to PC Clipboard instead.")
        }
        return normalized
    }

    static func clipboardText(_ text: String) throws -> String {
        guard !text.isEmpty else { throw OrbitIntentError.invalid("There's no text to copy.") }
        guard !text.unicodeScalars.contains("\0") else {
            throw OrbitIntentError.invalid("This text contains a hidden null character, which the PC clipboard can't hold.")
        }
        guard text.utf16.count <= maxClipboardUTF16Units else {
            throw OrbitIntentError.invalid("This text is too long for the PC clipboard (about 500,000 characters at most).")
        }
        return text
    }

    private static let forbiddenURLCharacters = Set("\"<>\\^`{|}")

    /// The link `Open Link on PC` sends: http or https, a host, no user name or password, at most
    /// 4096 characters and nothing that must be percent-encoded (same rules as `orbit_links`).
    /// A bare "example.com" gets https:// in front.
    static func webLink(_ url: URL) throws -> String {
        var text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.scheme == nil, !text.isEmpty, !text.hasPrefix("/") {
            text = "https://" + text
        }
        return try webLink(text)
    }

    static func webLink(_ text: String) throws -> String {
        guard !text.isEmpty else { throw OrbitIntentError.invalid("There's no link to open.") }
        guard text.unicodeScalars.count <= maxURLLength else {
            throw OrbitIntentError.invalid("This link is longer than 4,096 characters, so it can't be opened on the PC.")
        }
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if [.control, .format, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator].contains(category) {
                throw OrbitIntentError.invalid("This link contains spaces or invisible characters.")
            }
        }
        guard !text.contains(where: { forbiddenURLCharacters.contains($0) }) else {
            throw OrbitIntentError.invalid("This link contains characters such as quotes or backslashes that must be percent-encoded.")
        }
        guard let colon = text.firstIndex(of: ":") else {
            throw OrbitIntentError.invalid("Only http and https links can be opened on the PC.")
        }
        let scheme = text[..<colon].lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw OrbitIntentError.invalid("Only http and https links can be opened on the PC.")
        }
        let rest = text[text.index(after: colon)...]
        guard rest.hasPrefix("//") else {
            throw OrbitIntentError.invalid("This link has no website address. Use a full link such as https://example.com.")
        }
        let authority = rest.dropFirst(2).prefix { !"/?#".contains($0) }
        guard !authority.contains("@") else {
            throw OrbitIntentError.invalid("Links that contain a user name or password can't be opened from Orbit.")
        }
        var host = Substring(authority)
        var port: Substring = ""
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw OrbitIntentError.invalid("This link's website address isn't valid.") }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { port = after.dropFirst() } else if !after.isEmpty { throw OrbitIntentError.invalid("This link's website address isn't valid.") }
            host = host[host.index(after: host.startIndex)..<close]
        } else if let portColon = host.lastIndex(of: ":") {
            port = host[host.index(after: portColon)...]
            host = host[..<portColon]
        }
        guard !host.isEmpty else {
            throw OrbitIntentError.invalid("This link has no website address. Use a full link such as https://example.com.")
        }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || "-._:".contains($0) }) else {
            throw OrbitIntentError.invalid("This link's website address isn't valid.")
        }
        if !port.isEmpty {
            guard port.allSatisfy(\.isASCII), let number = Int(port), (0...65535).contains(number) else {
                throw OrbitIntentError.invalid("This link has an invalid port number.")
            }
        }
        return text
    }

    /// "1 minute", "90 seconds", "10 minutes".
    static func delayPhrase(_ seconds: Int) -> String {
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }

    /// The short form of a link for dialogs: host and path, like the PC's own toast.
    static func displayLink(_ text: String) -> String {
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return text }
        let path = components.path == "/" ? "" : components.path
        let short = host + path
        return short.count <= 80 ? short : String(short.prefix(79)) + "…"
    }
}
