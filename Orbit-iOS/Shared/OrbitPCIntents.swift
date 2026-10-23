import AppIntents
import Foundation

// Free Shortcuts actions for a paired PC (DESIGN.md F3). Wake, Sleep, Shut Down and Restart stay
// in OrbitPowerIntents.swift with their Orbit Pro check.
//
// Every action takes an optional `pc` (empty = the default PC), checks its input first, answers
// with one sentence, and stops with a plain-language `OrbitIntentError` when the PC is off, the
// Orbit Companion on it is too old, or Orbit is in Demo Mode. The work itself lives in
// `OrbitPCActions`, which Orbit's debug self-test also calls.
//
// Compiled into Orbit only. iOS runs an intent that the widget extension also compiles in the
// widget process whenever Orbit is closed, and App Shortcuts (Siri phrases) fail there with
// "Couldn't find AppShortcutsProvider". The entity, client and models these intents use are shared
// with OrbitWidgets, so a widget button or control can get its own intent type later.

// MARK: - What each action does

enum OrbitPCActions {
    static func lock(pc: OrbitPCEntity?) async throws -> String {
        let client = try OrbitIntentClient.resolve(pc)
        try await client.data("POST", "/api/action/lock")
        OrbitWidgetConnectionStore.recordPowerFeedback("Locked \(client.pcName)")
        return "Locked \(client.pcName)."
    }

    static func setVolume(_ level: Int, pc: OrbitPCEntity?) async throws -> String {
        guard (0...100).contains(level) else { throw OrbitIntentError.invalid("Choose a volume from 0 to 100.") }
        let client = try OrbitIntentClient.resolve(pc)
        let reply = try await client.data("POST", "/api/volume", query: [URLQueryItem(name: "level", value: String(level))])
        let state = try? JSONDecoder().decode(VolumeReply.self, from: reply)
        var message = "Set \(client.pcName)'s volume to \(level)%."
        if state?.isMuted == true, level > 0 { message += " The PC is muted, so use Toggle PC Mute to hear it." }
        return message
    }

    static func toggleMute(pc: OrbitPCEntity?) async throws -> String {
        let client = try OrbitIntentClient.resolve(pc)
        let before = try? await client.get(OrbitPCStatusReport.self, "/api/status")
        try await client.data("POST", "/api/action/mute")
        guard before?.volumeAvailable == true, let wasMuted = before?.isMuted else { return "Toggled mute on \(client.pcName)." }
        // The agent re-reads the mute state about once a second; report what the PC actually did.
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let muted = (try? await client.get(OrbitPCStatusReport.self, "/api/status"))?.isMuted, muted != wasMuted {
                return muted ? "Muted \(client.pcName)." : "Unmuted \(client.pcName)."
            }
        }
        return "Toggled mute on \(client.pcName)."
    }

    static func media(_ action: OrbitPCMediaAction, pc: OrbitPCEntity?) async throws -> String {
        let client = try OrbitIntentClient.resolve(pc)
        try await client.data("POST", "/api/action/\(action.agentAction)")
        switch action {
        case .playPause: return "Sent Play/Pause to \(client.pcName)."
        case .next: return "Skipped to the next track on \(client.pcName)."
        case .previous: return "Went back a track on \(client.pcName)."
        }
    }

    static func copyToClipboard(_ text: String, pc: OrbitPCEntity?) async throws -> String {
        let text = try OrbitIntentInput.clipboardText(text)
        let client = try OrbitIntentClient.resolve(pc)
        try await client.send("PUT", "/api/clipboard", json: ["text": text])
        // The text itself is never repeated: Siri would read a copied password out loud.
        return "Copied \(characters(text.count)) to \(client.pcName)'s clipboard."
    }

    static func typeText(_ text: String, pc: OrbitPCEntity?) async throws -> String {
        let text = try OrbitIntentInput.typedText(text)
        let client = try OrbitIntentClient.resolve(pc)
        // Windows shows the sign-in screen on a secure desktop: keystrokes would be lost there, and
        // Orbit never types a Windows password through this route.
        if let status = try? await client.get(OrbitPCStatusReport.self, "/api/status"), status.sessionLocked == true {
            throw OrbitIntentError("\(client.pcName) is locked. Unlock it first, because Orbit doesn't type on the Windows sign-in screen.")
        }
        try await client.data("POST", "/api/input/keyboard", query: [URLQueryItem(name: "text", value: text)])
        return "Typed \(characters(text.count)) on \(client.pcName)."
    }

    static func open(_ url: URL, pc: OrbitPCEntity?) async throws -> String {
        try await open(link: OrbitIntentInput.webLink(url), pc: pc)
    }

    static func open(link: String, pc: OrbitPCEntity?) async throws -> String {
        let link = try OrbitIntentInput.webLink(link)
        let client = try OrbitIntentClient.resolve(pc)
        try await client.require(feature: "openUrl")
        try await client.send("POST", "/api/open-url", json: ["url": link])
        return "Opened \(OrbitIntentInput.displayLink(link)) on \(client.pcName)."
    }

    /// Names from Sunshine's app list on the PC (`GET /api/sunshine/apps`).
    static func sunshineApps(pc: OrbitPCEntity?) async throws -> [String] {
        let client = try OrbitIntentClient.resolve(pc)
        return try await client.get([OrbitSunshineAppEntry].self, "/api/sunshine/apps").map(\.title)
    }

    static func launch(_ name: String, pc: OrbitPCEntity?) async throws -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted.count <= 200 else { throw OrbitIntentError.invalid("Choose a game from Sunshine's app list.") }
        let client = try OrbitIntentClient.resolve(pc)
        let apps = try await client.get([OrbitSunshineAppEntry].self, "/api/sunshine/apps").map(\.title)
        guard !apps.isEmpty else {
            throw OrbitIntentError("\(client.pcName) has no apps in Sunshine yet. Add your games in Sunshine's web page under Applications, then try again.")
        }
        guard let match = match(wanted, in: apps) else {
            let names = apps.prefix(6).joined(separator: ", ") + (apps.count > 6 ? "…" : "")
            throw OrbitIntentError.invalid("“\(wanted)” isn't in \(client.pcName)'s Sunshine app list. Choose one of: \(names).")
        }
        try await client.data("POST", "/api/sunshine/launch", query: [URLQueryItem(name: "app", value: match)])
        return "Launching \(match) on \(client.pcName)."
    }

    static func reading(_ reading: OrbitPCReading, pc: OrbitPCEntity?) async throws -> (value: Double, dialog: String) {
        let client = try OrbitIntentClient.resolve(pc)
        let report = try await client.get(OrbitPCStatusReport.self, "/api/status")
        guard let value = report.value(reading) else { throw OrbitIntentError(report.missingReason(reading, pc: client.pcName)) }
        return (value, report.readingSentence(reading, value: value, pc: client.pcName))
    }

    /// One sentence. A PC that does not answer is a status too ("isn't reachable"), not a failure,
    /// so automations can branch on it.
    static func status(pc: OrbitPCEntity?) async throws -> String {
        let client = try OrbitIntentClient.resolve(pc, timeout: 5)
        do {
            return try await client.get(OrbitPCStatusReport.self, "/api/status").statusSentence(pc: client.pcName)
        } catch let error as OrbitIntentError where error.kind == .unreachable {
            return OrbitPCStatusReport.offlineSentence(pc: client.pcName)
        }
    }

    static func sleepWhenDownloadsFinish(_ action: OrbitPCPowerAfterAction, delaySeconds: Int, pc: OrbitPCEntity?) async throws -> String {
        guard OrbitIntentInput.powerAfterDelay.contains(delaySeconds) else {
            throw OrbitIntentError.invalid("Choose a countdown from 30 seconds to 10 minutes (30–600 seconds).")
        }
        let client = try OrbitIntentClient.resolve(pc)
        let features = try await client.features()
        guard features.contains("powerAfter") else { throw OrbitIntentError.olderCompanion(client.pcName) }
        try await client.send("PUT", "/api/power/after", json: OrbitPowerAfterRequest(action: action.rawValue, delaySeconds: delaySeconds))
        var downloads: OrbitDownloadsReport?
        if features.contains("downloads") {
            downloads = try? await client.get(OrbitDownloadsReport.self, "/api/downloads")
        }
        return OrbitDownloadsReport.powerAfterSentence(downloads, action: action, delaySeconds: delaySeconds, pc: client.pcName)
    }

    // MARK: Helpers

    private struct VolumeReply: Decodable { var isMuted: Bool? }

    private static func characters(_ count: Int) -> String { count == 1 ? "1 character" : "\(count) characters" }

    /// Exact name (any case) first; otherwise the only app whose name contains what was asked
    /// ("cyberpunk" → "Cyberpunk 2077"), which helps with names spoken to Siri.
    static func match(_ wanted: String, in apps: [String]) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if let exact = apps.first(where: { $0.compare(wanted, options: options) == .orderedSame }) { return exact }
        let partial = apps.filter { $0.range(of: wanted, options: options) != nil }
        return partial.count == 1 ? partial[0] : nil
    }
}

// MARK: - Intents

struct LockPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock PC"
    static let description = IntentDescription("Locks Windows on your PC, like pressing Windows+L.", categoryName: "Power")
    static let openAppWhenRun = false

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Lock \(\.$pc)") }

    init() {}
    init(pc: OrbitPCEntity?) { self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.lock(pc: pc)))
    }
}

struct SetPCVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set PC Volume"
    static let description = IntentDescription("Sets your PC's master volume from 0 to 100 percent.", categoryName: "Sound")
    static let openAppWhenRun = false

    @Parameter(title: "Volume", description: "From 0 to 100 percent.", default: 50, controlStyle: .field, inclusiveRange: (0, 100),
               requestValueDialog: "What volume should the PC use, from 0 to 100?")
    var level: Int

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$pc) volume to \(\.$level)%") }

    init() {}
    init(level: Int, pc: OrbitPCEntity? = nil) { self.level = level; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.setVolume(level, pc: pc)))
    }
}

struct TogglePCMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle PC Mute"
    static let description = IntentDescription("Mutes your PC's sound, or unmutes it if it's already muted.", categoryName: "Sound")
    static let openAppWhenRun = false

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Toggle mute on \(\.$pc)") }

    init() {}
    init(pc: OrbitPCEntity?) { self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.toggleMute(pc: pc)))
    }
}

struct PCMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Control PC Media"
    static let description = IntentDescription("Plays or pauses, or skips the track in whatever is playing on your PC (Spotify, YouTube, games…).",
                                               categoryName: "Sound")
    static let openAppWhenRun = false

    @Parameter(title: "Action", default: .playPause)
    var action: OrbitPCMediaAction

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) on \(\.$pc)") }

    init() {}
    init(action: OrbitPCMediaAction, pc: OrbitPCEntity? = nil) { self.action = action; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.media(action, pc: pc)))
    }
}

struct SendTextToPCClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Text to PC Clipboard"
    static let description = IntentDescription("Puts text on your PC's clipboard, ready to paste with Ctrl+V.", categoryName: "Text & Links")
    static let openAppWhenRun = false
    /// Puts input on the PC (typing, the clipboard, a link or a game), so it runs only while this
    /// iPhone is unlocked: Siri on a locked iPhone asks to unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What should Orbit copy to the PC?")
    var text: String

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Copy \(\.$text) to \(\.$pc)'s clipboard") }

    init() {}
    init(text: String, pc: OrbitPCEntity? = nil) { self.text = text; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.isEmpty else { throw $text.needsValueError("What should Orbit copy to the PC?") }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.copyToClipboard(text, pc: pc)))
    }
}

struct TypeTextOnPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Type Text on PC"
    static let description = IntentDescription("Types text into the window that's in front on your PC, as if you typed it on its keyboard (up to 1,000 characters).",
                                               categoryName: "Text & Links")
    static let openAppWhenRun = false
    /// Puts input on the PC (typing, the clipboard, a link or a game), so it runs only while this
    /// iPhone is unlocked: Siri on a locked iPhone asks to unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What should Orbit type on the PC?")
    var text: String

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Type \(\.$text) on \(\.$pc)") }

    init() {}
    init(text: String, pc: OrbitPCEntity? = nil) { self.text = text; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.isEmpty else { throw $text.needsValueError("What should Orbit type on the PC?") }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.typeText(text, pc: pc)))
    }
}

struct OpenURLOnPCIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Link on PC"
    static let description = IntentDescription("Opens a web link in your PC's default browser.", categoryName: "Text & Links")
    static let openAppWhenRun = false
    /// Puts input on the PC (typing, the clipboard, a link or a game), so it runs only while this
    /// iPhone is unlocked: Siri on a locked iPhone asks to unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Link", requestValueDialog: "Which link should open on the PC?")
    var url: URL

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$url) on \(\.$pc)") }

    init() {}
    init(url: URL, pc: OrbitPCEntity? = nil) { self.url = url; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.open(url, pc: pc)))
    }
}

/// Offers the names in Sunshine's app list on the PC chosen in the same action.
struct OrbitSunshineAppOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<LaunchPCGameIntent>(\.$pc)
    var launch

    func results() async throws -> [String] {
        try await OrbitPCActions.sunshineApps(pc: launch?.pc)
    }
}

struct LaunchPCGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Game on PC"
    static let description = IntentDescription("Starts a game or app from Sunshine's app list on your PC.", categoryName: "Games")
    static let openAppWhenRun = false
    /// Puts input on the PC (typing, the clipboard, a link or a game), so it runs only while this
    /// iPhone is unlocked: Siri on a locked iPhone asks to unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Game", description: "A name from Sunshine's app list on the PC.",
               requestValueDialog: "Which game should start on the PC?", optionsProvider: OrbitSunshineAppOptionsProvider())
    var name: String

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Launch \(\.$name) on \(\.$pc)") }

    init() {}
    init(name: String, pc: OrbitPCEntity? = nil) { self.name = name; self.pc = pc }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $name.needsValueError("Which game should start on the PC?")
        }
        return .result(dialog: IntentDialog(stringLiteral: try await OrbitPCActions.launch(name, pc: pc)))
    }
}

struct GetPCReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PC Reading"
    static let description = IntentDescription("Gets one live reading from your PC as a number: temperatures in °C, loads in %, power in watts, or game FPS.",
                                               categoryName: "Status")
    static let openAppWhenRun = false

    @Parameter(title: "Reading", default: .cpuTemperature)
    var reading: OrbitPCReading

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$reading) of \(\.$pc)") }

    init() {}
    init(reading: OrbitPCReading, pc: OrbitPCEntity? = nil) { self.reading = reading; self.pc = pc }

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let result = try await OrbitPCActions.reading(reading, pc: pc)
        return .result(value: result.value, dialog: IntentDialog(stringLiteral: result.dialog))
    }
}

struct GetPCStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PC Status"
    static let description = IntentDescription("Describes your PC in one sentence: whether it's on or locked, the game it's running, and its loads and temperatures. If the PC is off or asleep, the result says so.",
                                               categoryName: "Status")
    static let openAppWhenRun = false

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get the status of \(\.$pc)") }

    init() {}
    init(pc: OrbitPCEntity?) { self.pc = pc }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = try await OrbitPCActions.status(pc: pc)
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct SleepWhenDownloadsFinishIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep PC When Downloads Finish"
    static let description = IntentDescription("Waits for the Steam, Epic and GOG downloads on your PC to finish, then puts it to sleep or shuts it down after a countdown you can cancel in Orbit. If nothing is downloading yet, it waits for the next download.",
                                               categoryName: "Power")
    static let openAppWhenRun = false
    // Stays runnable on a locked iPhone (the default policy): its bedtime automation ("Sleep Focus
    // on") usually runs while the iPhone is locked, Siri's Pro "Shut Down PC" already works there,
    // and the PC cancels the countdown by itself when someone uses its keyboard or mouse.

    @Parameter(title: "Action", default: .sleep)
    var action: OrbitPCPowerAfterAction

    @Parameter(title: "Countdown (seconds)", description: "How long the PC counts down once its downloads are done, from 30 to 600 seconds. Using the PC during the countdown keeps it on.",
               default: 60, controlStyle: .field, inclusiveRange: (30, 600))
    var delaySeconds: Int

    @Parameter(title: "PC", description: "Leave empty to use your default PC.")
    var pc: OrbitPCEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) \(\.$pc) when downloads finish") { \.$delaySeconds }
    }

    init() {}
    init(action: OrbitPCPowerAfterAction, delaySeconds: Int = 60, pc: OrbitPCEntity? = nil) {
        self.action = action
        self.delaySeconds = delaySeconds
        self.pc = pc
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await OrbitPCActions.sleepWhenDownloadsFinish(action, delaySeconds: delaySeconds, pc: pc)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}
