import Foundation

// Full-screen streaming ("Fill Screen", DESIGN F5) and the virtual second screen (F9): the contract with
// `orbit_stream_display.py` on the PC (features `streamDisplay` and `secondScreen` in GET /api/capabilities)
// and the checks the apps show from it.
//
// Foundation only. Compiled into the iPhone/iPad and Mac apps, and by Tests/check_stream_display.py next
// to OrbitAPIClient.swift, OrbitError.swift and OrbitStreamDisplayModels.swift, so keep it free of other app types.

enum OrbitStreamDisplayFeature {
    /// Fill Screen setup: GET /api/stream/display, POST …/modes, …/fill, …/revert.
    static let fill = "streamDisplay"
    /// POST /api/stream/display/second-screen.
    static let secondScreen = "secondScreen"
}

/// A screen size in pixels, landscape.
struct OrbitDisplaySize: Equatable, Hashable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int

    /// "2556x1179", how the PC lists the virtual display's sizes.
    var key: String { "\(width)x\(height)" }
    var description: String { "\(width) × \(height)" }
    /// The PC accepts 640×480 up to 7680×4320 (`ModeBody`).
    var isAcceptedByPC: Bool { (640...7680).contains(width) && (480...4320).contains(height) }
}

// MARK: - GET /api/stream/display

/// What the PC reports. Every field is optional on the wire so an older or newer agent never breaks the
/// screen; missing values read as "not known".
struct OrbitStreamDisplayStatus: Decodable, Equatable, Sendable {
    struct VirtualDisplay: Decodable, Equatable, Sendable {
        var installed = false
        /// "vdd" (Virtual Display Driver), "sudovda" (not supported) or nil.
        var driver: String?
        var modes: [String] = []
        var resolutions: [String] = []
        var refreshRates: [Int] = []
        var settingsError: String?
        /// running | disabled | problem | notPresent | unknown | notFound
        var deviceStatus: String?
        var deviceId: String?
        var deviceIdReason: String?
        var attached: Bool?

        init() {}

        private enum CodingKeys: String, CodingKey {
            case installed, driver, modes, resolutions, refreshRates, settingsError, deviceStatus, deviceId, deviceIdReason, attached
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            installed = (try? values.decodeIfPresent(Bool.self, forKey: .installed)) ?? false
            driver = try? values.decodeIfPresent(String.self, forKey: .driver)
            modes = (try? values.decodeIfPresent([String].self, forKey: .modes)) ?? []
            resolutions = (try? values.decodeIfPresent([String].self, forKey: .resolutions)) ?? []
            refreshRates = (try? values.decodeIfPresent([Int].self, forKey: .refreshRates)) ?? []
            settingsError = try? values.decodeIfPresent(String.self, forKey: .settingsError)
            deviceStatus = try? values.decodeIfPresent(String.self, forKey: .deviceStatus)
            deviceId = try? values.decodeIfPresent(String.self, forKey: .deviceId)
            deviceIdReason = try? values.decodeIfPresent(String.self, forKey: .deviceIdReason)
            attached = try? values.decodeIfPresent(Bool.self, forKey: .attached)
        }
    }

    /// The four Sunshine settings Orbit changes, as Sunshine has them now.
    struct SunshineConfig: Decodable, Equatable, Sendable {
        var configurationOption: String?
        var resolutionOption: String?
        var refreshRateOption: String?
        var outputName: String?

        init() {}

        private enum CodingKeys: String, CodingKey {
            case configurationOption = "dd_configuration_option"
            case resolutionOption = "dd_resolution_option"
            case refreshRateOption = "dd_refresh_rate_option"
            case outputName = "output_name"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            configurationOption = try? values.decodeIfPresent(String.self, forKey: .configurationOption)
            resolutionOption = try? values.decodeIfPresent(String.self, forKey: .resolutionOption)
            refreshRateOption = try? values.decodeIfPresent(String.self, forKey: .refreshRateOption)
            outputName = try? values.decodeIfPresent(String.self, forKey: .outputName)
        }
    }

    struct Fill: Decodable, Equatable, Sendable {
        var enabled = false
        /// Sunshine shows only the virtual display while streaming (the PC's monitor goes dark).
        var onlyDisplay = false

        init(enabled: Bool = false, onlyDisplay: Bool = false) {
            self.enabled = enabled
            self.onlyDisplay = onlyDisplay
        }

        private enum CodingKeys: String, CodingKey { case enabled, onlyDisplay }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? values.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            onlyDisplay = (try? values.decodeIfPresent(Bool.self, forKey: .onlyDisplay)) ?? false
        }
    }

    struct SecondScreen: Decodable, Equatable, Sendable {
        var active = false
        var position: String?
        var width: Int?
        var height: Int?
        var refreshRate: Int?
        /// done | pending (Orbit places it once the stream starts) | manual | nil
        var placement: String?

        init() {}

        private enum CodingKeys: String, CodingKey { case active, position, width, height, refreshRate, placement }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            active = (try? values.decodeIfPresent(Bool.self, forKey: .active)) ?? false
            position = try? values.decodeIfPresent(String.self, forKey: .position)
            width = try? values.decodeIfPresent(Int.self, forKey: .width)
            height = try? values.decodeIfPresent(Int.self, forKey: .height)
            refreshRate = try? values.decodeIfPresent(Int.self, forKey: .refreshRate)
            placement = try? values.decodeIfPresent(String.self, forKey: .placement)
        }

        /// The size it was turned on with, when the PC reports one.
        var size: OrbitDisplaySize? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return OrbitDisplaySize(width: width, height: height)
        }
    }

    struct SavedConfig: Decodable, Equatable, Sendable {
        var available = false
        var savedAt: String?

        init() {}

        private enum CodingKeys: String, CodingKey { case available, savedAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            available = (try? values.decodeIfPresent(Bool.self, forKey: .available)) ?? false
            savedAt = try? values.decodeIfPresent(String.self, forKey: .savedAt)
        }
    }

    var sunshineVersion: String?
    var sunshineRunning: Bool?
    var loginSaved = false
    /// True from Sunshine 2025.118, which switches displays per stream; nil when it could not be read.
    var sunshineSupported: Bool?
    /// A stream is running right now (Sunshine's stream sockets are open); nil = could not tell.
    var streamActive: Bool?
    /// An app is still running in Sunshine (a client left without quitting it); nil = could not tell.
    var appRunning: Bool?
    var virtualDisplay = VirtualDisplay()
    var config = SunshineConfig()
    var fill = Fill()
    /// Nothing stops Fill Screen from working (it may still be turned off: see `fill`).
    var fillReady = false
    var secondScreen = SecondScreen()
    var savedConfig = SavedConfig()
    var installCommand: String?
    /// The first problem, in plain words; nil when `fillReady`.
    var reason: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case sunshineVersion, sunshineRunning, loginSaved, sunshineSupported, streamActive, appRunning, virtualDisplay, config, fill,
             fillReady, secondScreen, savedConfig, installCommand, reason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sunshineVersion = try? values.decodeIfPresent(String.self, forKey: .sunshineVersion)
        sunshineRunning = try? values.decodeIfPresent(Bool.self, forKey: .sunshineRunning)
        loginSaved = (try? values.decodeIfPresent(Bool.self, forKey: .loginSaved)) ?? false
        sunshineSupported = try? values.decodeIfPresent(Bool.self, forKey: .sunshineSupported)
        streamActive = try? values.decodeIfPresent(Bool.self, forKey: .streamActive)
        appRunning = try? values.decodeIfPresent(Bool.self, forKey: .appRunning)
        virtualDisplay = (try? values.decodeIfPresent(VirtualDisplay.self, forKey: .virtualDisplay)) ?? VirtualDisplay()
        config = (try? values.decodeIfPresent(SunshineConfig.self, forKey: .config)) ?? SunshineConfig()
        fill = (try? values.decodeIfPresent(Fill.self, forKey: .fill)) ?? Fill()
        fillReady = (try? values.decodeIfPresent(Bool.self, forKey: .fillReady)) ?? false
        secondScreen = (try? values.decodeIfPresent(SecondScreen.self, forKey: .secondScreen)) ?? SecondScreen()
        savedConfig = (try? values.decodeIfPresent(SavedConfig.self, forKey: .savedConfig)) ?? SavedConfig()
        installCommand = try? values.decodeIfPresent(String.self, forKey: .installCommand)
        reason = try? values.decodeIfPresent(String.self, forKey: .reason)
    }

    /// The winget command for the Virtual Display Driver (the PC sends it; this is the same text).
    static let defaultInstallCommand = "winget install -e --id VirtualDrivers.Virtual-Display-Driver"
    static let driverURL = URL(string: "https://github.com/VirtualDrivers/Virtual-Display-Driver")!

    var driverInstallCommand: String {
        let command = installCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? Self.defaultInstallCommand : command
    }
}

// MARK: - POST replies and bodies

/// Every POST answers `{changed, restarted, sunshineReady, warning, …, display}`.
struct OrbitStreamDisplayResult: Decodable, Equatable, Sendable {
    var changed = false
    var restarted = false
    /// Sunshine answers again after its restart (nil when it was not restarted).
    var sunshineReady: Bool?
    /// Done, but with a caveat worth showing (for example "Sunshine keeps the display it uses now").
    var warning: String?
    /// /modes and /second-screen: notNeeded | pipe | driverRestart | nextStart
    var reload: String?
    /// An administrator prompt was approved on the PC.
    var elevated: Bool?
    /// /second-screen: done | pending | manual
    var placement: String?
    var placementHint: String?
    var display: OrbitStreamDisplayStatus?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case changed, restarted, sunshineReady, warning, reload, elevated, placement, placementHint, display
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        changed = (try? values.decodeIfPresent(Bool.self, forKey: .changed)) ?? false
        restarted = (try? values.decodeIfPresent(Bool.self, forKey: .restarted)) ?? false
        sunshineReady = try? values.decodeIfPresent(Bool.self, forKey: .sunshineReady)
        warning = try? values.decodeIfPresent(String.self, forKey: .warning)
        reload = try? values.decodeIfPresent(String.self, forKey: .reload)
        elevated = try? values.decodeIfPresent(Bool.self, forKey: .elevated)
        placement = try? values.decodeIfPresent(String.self, forKey: .placement)
        placementHint = try? values.decodeIfPresent(String.self, forKey: .placementHint)
        display = try? values.decodeIfPresent(OrbitStreamDisplayStatus.self, forKey: .display)
    }

    /// The warning in plain words, without blank values.
    var cleanWarning: String? {
        guard let text = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

struct OrbitStreamDisplayModeBody: Encodable, Equatable {
    let width: Int
    let height: Int
    let refreshRate: Int
}

struct OrbitStreamDisplayFillBody: Encodable, Equatable {
    let enabled: Bool
    let onlyDisplay: Bool
}

struct OrbitSecondScreenBody: Encodable, Equatable {
    let enabled: Bool
    let width: Int?
    let height: Int?
    let refreshRate: Int
    let position: String

    private enum CodingKeys: String, CodingKey { case enabled, width, height, refreshRate, position }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        // Only sent when turning it on: the PC needs both sides then and ignores them otherwise.
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encode(refreshRate, forKey: .refreshRate)
        try container.encode(position, forKey: .position)
    }
}

// MARK: - Requests

enum OrbitStreamDisplayAPI {
    static let statusPath = "/api/stream/display"
    /// The PC may wait for an administrator prompt (up to 60 s) and for Sunshine to restart (up to 25 s):
    /// changes get two minutes before the app gives up waiting.
    static let changeTimeout: TimeInterval = 120

    /// `GET /api/capabilities`: the feature strings, or nil for an agent older than capabilities (404).
    static func features(_ client: OrbitAPIClient) async throws -> Set<String>? {
        struct Reply: Decodable { var features: [String]? }
        do {
            let reply: Reply = try await client.get("/api/capabilities")
            return Set(reply.features ?? [])
        } catch let error as OrbitError where error.statusCode == 404 {
            return nil
        }
    }

    static func status(_ client: OrbitAPIClient) async throws -> OrbitStreamDisplayStatus {
        try await client.get(statusPath)
    }

    /// Adds a size to the virtual display (the PC may show one administrator prompt).
    static func addMode(_ client: OrbitAPIClient, size: OrbitDisplaySize, refreshRate: Int) async throws -> OrbitStreamDisplayResult {
        let body = OrbitStreamDisplayModeBody(width: size.width, height: size.height, refreshRate: clampedRefreshRate(refreshRate))
        return try await client.withTimeout(changeTimeout).send("\(statusPath)/modes", body: body)
    }

    static func setFill(_ client: OrbitAPIClient, enabled: Bool, onlyDisplay: Bool = false) async throws -> OrbitStreamDisplayResult {
        try await client.withTimeout(changeTimeout).send("\(statusPath)/fill", body: OrbitStreamDisplayFillBody(enabled: enabled, onlyDisplay: enabled && onlyDisplay))
    }

    static func setSecondScreen(_ client: OrbitAPIClient, enabled: Bool, size: OrbitDisplaySize?, refreshRate: Int, position: String) async throws -> OrbitStreamDisplayResult {
        let body = OrbitSecondScreenBody(enabled: enabled, width: enabled ? size?.width : nil, height: enabled ? size?.height : nil,
                                         refreshRate: clampedRefreshRate(refreshRate), position: position == "left" ? "left" : "right")
        return try await client.withTimeout(changeTimeout).send("\(statusPath)/second-screen", body: body)
    }

    /// Turns Fill Screen and the second screen off and puts back Sunshine's settings from before Orbit.
    static func revert(_ client: OrbitAPIClient) async throws -> OrbitStreamDisplayResult {
        let data = try await client.withTimeout(changeTimeout).data("\(statusPath)/revert", method: "POST")
        return try JSONDecoder().decode(OrbitStreamDisplayResult.self, from: data)
    }

    /// The PC accepts 24–500 Hz.
    static func clampedRefreshRate(_ value: Int) -> Int { min(max(value, 24), 500) }

    /// A size was saved, but the driver could not be restarted to offer it (`reload: "nextStart"`).
    static func nextStartNote(size: OrbitDisplaySize, pcName: String) -> String {
        "The virtual display offers \(size) once its driver starts again, for example after you restart \(pcName)."
    }
}

// MARK: - The PC, as the screens use it

/// Everything the Fill Screen setup and Second Screen ask of the PC. `OrbitStreamDisplayHTTPService` talks to the
/// companion; the checks in Tests/ replace it with a scripted PC.
protocol OrbitStreamDisplayService: AnyObject, Sendable {
    /// GET /api/capabilities: the feature strings, or nil for an agent older than capabilities (404).
    func features() async throws -> Set<String>?
    func status() async throws -> OrbitStreamDisplayStatus
    func addMode(size: OrbitDisplaySize, refreshRate: Int) async throws -> OrbitStreamDisplayResult
    func setFill(enabled: Bool, onlyDisplay: Bool) async throws -> OrbitStreamDisplayResult
    func setSecondScreen(enabled: Bool, size: OrbitDisplaySize?, refreshRate: Int, position: String) async throws -> OrbitStreamDisplayResult
    func revert() async throws -> OrbitStreamDisplayResult
    /// Saves Sunshine's web UI login on the PC (POST /api/sunshine/credentials, the route pairing uses).
    func saveSunshineLogin(username: String, password: String) async throws
    /// Starts Sunshine on the PC (POST /api/sunshine/start).
    func startSunshine() async throws
}

final class OrbitStreamDisplayHTTPService: OrbitStreamDisplayService, @unchecked Sendable {
    let client: OrbitAPIClient

    init(client: OrbitAPIClient) { self.client = client }

    func features() async throws -> Set<String>? { try await OrbitStreamDisplayAPI.features(client) }
    func status() async throws -> OrbitStreamDisplayStatus { try await OrbitStreamDisplayAPI.status(client) }

    func addMode(size: OrbitDisplaySize, refreshRate: Int) async throws -> OrbitStreamDisplayResult {
        try await OrbitStreamDisplayAPI.addMode(client, size: size, refreshRate: refreshRate)
    }

    func setFill(enabled: Bool, onlyDisplay: Bool) async throws -> OrbitStreamDisplayResult {
        try await OrbitStreamDisplayAPI.setFill(client, enabled: enabled, onlyDisplay: onlyDisplay)
    }

    func setSecondScreen(enabled: Bool, size: OrbitDisplaySize?, refreshRate: Int, position: String) async throws -> OrbitStreamDisplayResult {
        try await OrbitStreamDisplayAPI.setSecondScreen(client, enabled: enabled, size: size, refreshRate: refreshRate, position: position)
    }

    func revert() async throws -> OrbitStreamDisplayResult { try await OrbitStreamDisplayAPI.revert(client) }

    func saveSunshineLogin(username: String, password: String) async throws {
        struct Login: Encodable { let username: String; let password: String }
        struct Saved: Decodable { let status: String }
        let _: Saved = try await client.send("/api/sunshine/credentials", body: Login(username: username, password: password))
    }

    func startSunshine() async throws {
        _ = try await client.data("/api/sunshine/start", method: "POST")
    }
}

/// The PC a stream-display screen talks to. `service()` builds a pinned client for it when needed.
struct OrbitStreamDisplayContext {
    let pcID: String
    let pcName: String
    let isDemo: Bool
    let isOnline: Bool
    /// A PC is paired (or demo mode is on). Without one, Stream Settings only lists the steps.
    let hasPC: Bool
    /// The companion can start Sunshine on the PC (`/api/sunshine/info` `canStart`).
    var canStartSunshine = false
    let makeClient: @MainActor () throws -> OrbitAPIClient
    /// Replaces the companion's HTTP API (the checks in Tests/ use a scripted PC).
    var makeService: (@MainActor () throws -> any OrbitStreamDisplayService)? = nil

    init(pcID: String, pcName: String, isDemo: Bool, isOnline: Bool, hasPC: Bool, canStartSunshine: Bool = false,
         makeClient: @escaping @MainActor () throws -> OrbitAPIClient, makeService: (@MainActor () throws -> any OrbitStreamDisplayService)? = nil) {
        self.pcID = pcID
        self.pcName = pcName
        self.isDemo = isDemo
        self.isOnline = isOnline
        self.hasPC = hasPC
        self.canStartSunshine = canStartSunshine
        self.makeClient = makeClient
        self.makeService = makeService
    }

    /// Changes when the screens must forget what they read (another PC, demo mode, back online).
    var identity: String { "\(pcID)|\(isDemo)|\(isOnline)|\(hasPC)" }

    @MainActor
    func service() throws -> any OrbitStreamDisplayService {
        if let makeService { return try makeService() }
        return OrbitStreamDisplayHTTPService(client: try makeClient())
    }
}

/// `GET /api/capabilities` per PC for these screens: 10 minutes, 2 minutes for an older agent (404).
@MainActor
enum OrbitStreamDisplayFeatureCache {
    private static var entries: [String: (features: Set<String>?, at: Date)] = [:]

    static func features(for pcID: String, service: any OrbitStreamDisplayService, force: Bool = false) async throws -> Set<String>? {
        if !force, let entry = entries[pcID], Date().timeIntervalSince(entry.at) < (entry.features == nil ? 120 : 600) { return entry.features }
        let found = try await service.features()
        entries[pcID] = (found, Date())
        return found
    }

    /// For the checks in Tests/.
    static func forget() { entries = [:] }
}

/// Which PC a screen's reads belong to and which reads are still running, so a slow read for one PC never lands
/// on the next PC's screen, and never keeps the next PC's first read from starting.
struct OrbitStatusReads: Equatable {
    struct Token: Equatable {
        fileprivate let generation: Int
        fileprivate let id: Int
    }

    private(set) var pcID: String?
    private var generation = 0
    private var nextID = 0
    private var running: Set<Int> = []
    /// The newest read whose answer was shown.
    private var appliedID = 0

    /// A read for the current PC is running.
    var isReading: Bool { !running.isEmpty }

    /// Reads now belong to `pcID`. True when that is another PC than before: the caller forgets what it showed,
    /// and reads still running for the earlier PC no longer count.
    mutating func select(_ pcID: String) -> Bool {
        guard pcID != self.pcID else { return false }
        self.pcID = pcID
        generation += 1
        running = []
        return true
    }

    /// Starts a read for the current PC: nil when one already runs (unless `force`).
    mutating func begin(force: Bool = false) -> Token? {
        if isReading, !force { return nil }
        nextID += 1
        running.insert(nextID)
        return Token(generation: generation, id: nextID)
    }

    /// The read still belongs to the current PC.
    func isCurrent(_ token: Token) -> Bool { token.generation == generation }

    /// The read belongs to the current PC and no read started after it has been shown yet: a slow, older answer
    /// never replaces a newer one.
    func isNewest(_ token: Token) -> Bool { token.generation == generation && token.id > appliedID }

    /// The read's answer is shown.
    mutating func applied(_ token: Token) {
        guard token.generation == generation else { return }
        appliedID = max(appliedID, token.id)
    }

    mutating func end(_ token: Token) {
        guard token.generation == generation else { return }
        running.remove(token.id)
    }
}

// MARK: - Checks shown in the apps

/// One line of "what this needs", already worded for the screen.
struct OrbitDisplayCheck: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case login, sunshine, driver, size, sunshineTarget, idle
        /// Checked by the apps themselves (Second Screen): Orbit's Sunshine pairing and the Desktop app.
        case pairing, desktopApp
    }
    enum State: Equatable, Sendable { case done, missing, unknown }

    let kind: Kind
    let title: String
    let detail: String?
    let state: State
    var id: Kind { kind }
}

extension OrbitStreamDisplayStatus {
    /// The Virtual Display Driver is there and usable (not SudoVDA, not turned off, settings readable).
    var driverUsable: Bool {
        virtualDisplay.installed && virtualDisplay.driver == "vdd" && virtualDisplay.deviceStatus != "disabled" && virtualDisplay.settingsError == nil
    }

    /// The virtual display already offers `size`, at `refreshRate` when one is given. The PC lists every
    /// size at every refresh rate of the driver ("2556x1179@120"), so a size missing the stream's frame rate
    /// still needs adding; an agent that lists no modes is judged by the size alone.
    func lists(_ size: OrbitDisplaySize, refreshRate: Int? = nil) -> Bool {
        if let refreshRate, !virtualDisplay.modes.isEmpty {
            return virtualDisplay.modes.contains("\(size.key)@\(refreshRate)")
        }
        return virtualDisplay.resolutions.contains(size.key) || virtualDisplay.modes.contains { $0.hasPrefix(size.key + "@") }
    }

    /// Sunshine is set to stream the virtual display (Fill Screen on, pointed at the driver's display).
    /// Without a usable driver Fill Screen can still be on, but then Sunshine only has the real monitors.
    var sunshineStreamsVirtualDisplay: Bool {
        guard fill.enabled, driverUsable else { return false }
        guard let device = virtualDisplay.deviceId else { return config.outputName != nil }
        return config.outputName == device
    }

    /// Something is running in Sunshine right now, so it cannot restart.
    var isBusy: Bool { streamActive == true || appRunning == true }

    /// Sunshine isn't running on the PC (the PC found no Sunshine process, so it could not read its settings).
    var sunshineStopped: Bool { sunshineRunning == false && sunshineVersion == nil }

    /// A login is saved, but Orbit could not read Sunshine's settings with it although Sunshine runs.
    var loginUnconfirmed: Bool { loginSaved && sunshineVersion == nil && !sunshineStopped }

    /// Sunshine turned the saved login down, so it has to be saved again. The PC words that as a rejected
    /// login; its other reasons (the web UI unreachable, or refusing requests from the PC) are not the login's fault.
    var loginRejected: Bool {
        guard loginUnconfirmed else { return false }
        guard let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains("login")
    }

    /// The PC's own reason when no other row explains it: the login, Sunshine and the driver are fine, yet
    /// Fill Screen is not ready (Sunshine does not list the virtual display yet, the driver's settings file is
    /// missing, …). Problems that have a row of their own (login, Sunshine, driver) are left out.
    var pcNote: String? {
        guard !fillReady, loginSaved, sunshineVersion != nil, sunshineSupported != false, driverUsable,
              let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Why the driver row is not done, in plain words.
    var driverProblem: String? {
        if driverUsable { return nil }
        if virtualDisplay.driver == "sudovda" {
            return "SudoVDA (from Apollo) is installed, but Orbit works with the free Virtual Display Driver. Install it in Terminal on the PC:"
        }
        if virtualDisplay.installed, virtualDisplay.deviceStatus == "disabled" {
            return "The Virtual Display Driver is turned off in Device Manager on the PC. Turn it on, then check again."
        }
        if let error = virtualDisplay.settingsError, !error.isEmpty { return error }
        return "Install the free Virtual Display Driver on the PC. In Terminal on the PC:"
    }

    /// The driver problem as a sentence of its own, for under the Start button (the driver row above it shows the
    /// install command).
    var driverBlocker: String? {
        if driverUsable { return nil }
        if virtualDisplay.driver == "sudovda" {
            return "Install the free Virtual Display Driver on the PC first: Orbit doesn't work with SudoVDA. The command is above."
        }
        if virtualDisplay.installed, virtualDisplay.deviceStatus == "disabled" {
            return "Turn the Virtual Display Driver back on in Device Manager on the PC first."
        }
        if let error = virtualDisplay.settingsError, !error.isEmpty { return error }
        return "Install the free Virtual Display Driver on the PC first. The command is above."
    }

    /// True when the driver row should offer the install command.
    var offersInstallCommand: Bool {
        !driverUsable && (virtualDisplay.driver == nil || virtualDisplay.driver == "sudovda" || !virtualDisplay.installed)
    }

    private func sunshineCheck() -> OrbitDisplayCheck {
        if sunshineStopped {
            return OrbitDisplayCheck(kind: .sunshine, title: "Sunshine running on the PC",
                                     detail: "Sunshine isn't running on the PC. Start it there, then check again.", state: .missing)
        }
        let version = sunshineVersion.map { "Sunshine \($0)" }
        switch sunshineSupported {
        case true?:
            return OrbitDisplayCheck(kind: .sunshine, title: "Sunshine can switch displays", detail: version, state: .done)
        case false?:
            return OrbitDisplayCheck(kind: .sunshine, title: "Sunshine can switch displays",
                                     detail: "Update Sunshine on the PC to 2025.118 or newer\(version.map { " (it has \($0))" } ?? "").", state: .missing)
        case nil:
            return OrbitDisplayCheck(kind: .sunshine, title: "Sunshine can switch displays",
                                     detail: loginSaved ? "Orbit reads it once it can reach Sunshine's web UI." : "Orbit reads it once the login is saved.", state: .unknown)
        }
    }

    /// Saved and accepted (Orbit read Sunshine's settings with it), missing or turned down by Sunshine (`.missing`:
    /// the screens offer the login form), or not known yet (Sunshine stopped or its web UI unreachable).
    private var loginCheck: OrbitDisplayCheck {
        let title = "Sunshine login saved on the PC"
        if !loginSaved {
            return OrbitDisplayCheck(kind: .login, title: title,
                                     detail: "Orbit uses Sunshine's web UI login to change its display settings. It stays on the PC.", state: .missing)
        }
        if sunshineVersion != nil { return OrbitDisplayCheck(kind: .login, title: title, detail: nil, state: .done) }
        if sunshineStopped {
            return OrbitDisplayCheck(kind: .login, title: title, detail: "Saved. Orbit checks it once Sunshine runs.", state: .unknown)
        }
        if loginRejected {
            return OrbitDisplayCheck(kind: .login, title: title, detail: reason ?? "Sunshine didn't accept the saved login. Save it again.", state: .missing)
        }
        return OrbitDisplayCheck(kind: .login, title: title, detail: reason ?? "Orbit couldn't sign in to Sunshine's web UI with it.", state: .unknown)
    }

    private var driverCheck: OrbitDisplayCheck {
        OrbitDisplayCheck(kind: .driver, title: "Virtual Display Driver", detail: driverUsable ? "Installed on the PC" : driverProblem,
                          state: driverUsable ? .done : .missing)
    }

    /// The checks behind Fill Screen for a stream of `size` at `refreshRate` fps, in the order the PC needs them.
    func fillChecks(size: OrbitDisplaySize, refreshRate: Int? = nil) -> [OrbitDisplayCheck] {
        var checks = [loginCheck, sunshineCheck(), driverCheck]
        let listed = lists(size, refreshRate: refreshRate)
        let mode = refreshRate.map { "\(size) at \($0) Hz" } ?? size.description
        checks.append(OrbitDisplayCheck(kind: .size, title: "Virtual display offers \(mode)",
                                        detail: listed ? nil : (driverUsable ? "Set Up This PC adds it. Windows may ask for administrator approval on the PC once." : nil),
                                        state: listed ? .done : (driverUsable ? .missing : .unknown)))
        let target = sunshineStreamsVirtualDisplay
        var targetDetail: String?
        if target {
            targetDetail = fill.onlyDisplay ? "The PC's own monitor turns off while you stream." : "It becomes the PC's main display while you stream."
        } else if fill.enabled, !driverUsable {
            targetDetail = "Fill Screen is on, but without the virtual display Sunshine can only switch the PC's own monitor, which rarely has this screen's shape."
        } else if fill.enabled, let reason {
            targetDetail = reason
        } else if fill.enabled {
            targetDetail = "Sunshine is set to stream another display. Set Up This PC points it at the virtual display again."
        } else {
            targetDetail = "Set Up This PC turns it on. Sunshine restarts once, between streams."
        }
        checks.append(OrbitDisplayCheck(kind: .sunshineTarget, title: "Sunshine streams the virtual display", detail: targetDetail,
                                        state: target ? .done : .missing))
        return checks
    }

    /// Fill Screen fills this screen edge to edge: everything is set up for `size` (at `refreshRate` fps).
    func fillsScreen(size: OrbitDisplaySize, refreshRate: Int? = nil) -> Bool {
        loginSaved && sunshineSupported != false && driverUsable && lists(size, refreshRate: refreshRate) && sunshineStreamsVirtualDisplay && fillReady
    }

    /// One sentence for next to the Picture control when the PC is not ready, or nil when it is.
    func fillShortfall(size: OrbitDisplaySize, refreshRate: Int? = nil, pcName: String) -> String? {
        if fillsScreen(size: size, refreshRate: refreshRate) { return nil }
        if !loginSaved { return "Orbit needs your Sunshine login to set up \(pcName)." }
        if sunshineStopped { return "Sunshine isn't running on \(pcName)." }
        if loginRejected { return "Sunshine on \(pcName) didn't accept the saved login." }
        if loginUnconfirmed { return "Orbit can't reach Sunshine's web UI on \(pcName)." }
        if sunshineSupported == false { return "Sunshine on \(pcName) is too old to switch displays." }
        if !driverUsable {
            return virtualDisplay.installed && virtualDisplay.deviceStatus == "disabled"
                ? "The Virtual Display Driver is turned off on \(pcName)."
                : "\(pcName) needs the free Virtual Display Driver."
        }
        if !lists(size) { return "\(pcName)'s virtual display doesn't offer \(size) yet." }
        if let refreshRate, !lists(size, refreshRate: refreshRate) { return "\(pcName)'s virtual display doesn't offer \(size) at \(refreshRate) Hz yet." }
        if !fill.enabled { return "Sunshine on \(pcName) still streams the main monitor." }
        return reason ?? "\(pcName) isn't set up for this screen yet."
    }

    /// What keeps Second Screen from starting, in plain words (nil: it can start). Problems the PC fixes
    /// itself (Sunshine not listing the driver yet) do not block; a running app or stream is shown apart.
    var secondScreenBlocker: String? {
        if !loginSaved { return "Save your Sunshine login on the PC first." }
        if sunshineStopped { return "Start Sunshine on the PC first." }
        if loginRejected { return "Save your Sunshine login again first: Sunshine didn't accept it." }
        if sunshineSupported == false { return "Update Sunshine on the PC to 2025.118 or newer." }
        if !driverUsable { return driverBlocker }
        return nil
    }

    /// The Second Screen requirements as checks (Sunshine pairing and apps are checked by the app itself).
    var secondScreenChecks: [OrbitDisplayCheck] {
        var checks = [loginCheck, sunshineCheck(), driverCheck]
        let idleDetail: String?
        let idleState: OrbitDisplayCheck.State
        if streamActive == true {
            idleDetail = "Someone is streaming from the PC right now. End that stream first."
            idleState = .missing
        } else if appRunning == true {
            idleDetail = "An app is still running in Sunshine. Sunshine restarts to turn the second screen on, which would close it."
            idleState = .missing
        } else if streamActive == nil || appRunning == nil {
            idleDetail = "Orbit could not check. It asks again when you start."
            idleState = .unknown
        } else {
            idleDetail = nil
            idleState = .done
        }
        checks.append(OrbitDisplayCheck(kind: .idle, title: "Nothing running in Sunshine", detail: idleDetail, state: idleState))
        return checks
    }
}

// MARK: - Messages after a change

enum OrbitStreamDisplayMessages {
    /// After Fill Screen is turned off (`display`: the PC's state afterwards).
    static func fillOff(display: OrbitStreamDisplayStatus?, pcName: String) -> String {
        if display?.secondScreen.active == true {
            // The second screen keeps Sunshine on the virtual display (as an extra monitor) until it is turned off.
            return "Fill Screen is off on \(pcName). Second Screen is still on, so streams show the extra display until you turn it off."
        }
        return "Fill Screen is off on \(pcName). Sunshine streams its main monitor again."
    }

    /// After the second screen is turned off; `before`: the PC's state before (Fill Screen may stay on underneath).
    static func secondScreenOff(_ result: OrbitStreamDisplayResult, before: OrbitStreamDisplayStatus?, pcName: String) -> String {
        let fillStaysOn = (result.display ?? before)?.fill.enabled == true
        var message: String
        if !result.changed {
            message = "The second screen is off."
        } else if fillStaysOn {
            message = "The second screen is off. Sunshine on \(pcName) is back to Fill Screen for your streams."
        } else {
            message = "The second screen is off. Sunshine on \(pcName) streams the main monitor again."
        }
        if let warning = result.cleanWarning { message += " \(warning)" }
        return message
    }
}

/// Windows sizes text on the new display as for a desktop monitor, so it looks tiny on a phone, tablet or laptop screen.
enum OrbitSecondScreenScaleTip {
    /// Set once the tip was dismissed (it shows from the first start until then).
    static let dismissedKey = "orbit.secondScreen.scaleTipDismissed"

    /// `device`: "this iPhone", "this iPad", "this Mac".
    static func message(device: String) -> String {
        "Windows may size text on the new display for a desktop monitor, so it looks tiny on \(device). In Windows Settings › System › Display, select the new display and set Scale to 200%, or the largest it offers. Windows remembers it."
    }
}

// MARK: - Plain-words errors

struct OrbitStreamDisplayProblem: Equatable, Sendable {
    var title: String
    var message: String
}

enum OrbitStreamDisplayErrors {
    /// Where the app updates the companion on the PC.
    static var updateHint: String {
        #if os(macOS)
        return "Update it from Settings › About › Check for Agent Update."
        #else
        return "Update it from Settings › Check for PC Companion Update."
        #endif
    }

    /// The request was cancelled (the screen went away, or asked again): nothing went wrong on the PC, so
    /// nothing is shown.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// `waitedForChange`: the request was one of the slow changes (an administrator prompt, a restart).
    static func describe(_ error: Error, waitedForChange: Bool = false) -> OrbitStreamDisplayProblem {
        if let orbit = error as? OrbitError {
            switch orbit.statusCode {
            case 428?: return OrbitStreamDisplayProblem(title: "Sunshine login needed", message: orbit.message)
            case 409?: return OrbitStreamDisplayProblem(title: "Not possible right now", message: orbit.message)
            case 502?: return OrbitStreamDisplayProblem(title: "Sunshine didn't answer", message: orbit.message)
            case 503?: return OrbitStreamDisplayProblem(title: "Windows refused a step", message: orbit.message)
            case 404?:
                return OrbitStreamDisplayProblem(title: "Update Orbit PC Companion", message: "This needs a newer Orbit PC Companion on the PC. \(updateHint)")
            case 501?: return OrbitStreamDisplayProblem(title: "Windows only", message: "This works only when Orbit PC Companion runs on Windows.")
            case 422?: return OrbitStreamDisplayProblem(title: "The PC refused the request", message: orbit.message)
            case 401?: return OrbitStreamDisplayProblem(title: "Pairing token rejected", message: orbit.message)
            default: return OrbitStreamDisplayProblem(title: "Something went wrong", message: orbit.message)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut where waitedForChange:
                return OrbitStreamDisplayProblem(title: "No answer yet",
                                                 message: "The PC didn't answer within two minutes. Check again in a moment: the change may already be done. If an administrator prompt from Orbit is still open on the PC, close it; it no longer changes anything.")
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
                return OrbitStreamDisplayProblem(title: "PC not reachable",
                                                 message: "Your PC didn't answer. Check that it's awake, on the same network, and that Orbit PC Companion is running.")
            case .cancelled:
                return OrbitStreamDisplayProblem(title: "Cancelled", message: "The request was cancelled before the PC answered.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return OrbitStreamDisplayProblem(title: "PC identity changed", message: "The PC's identity didn't match. Pair it again in My PCs.")
            default: break
            }
        }
        if error is DecodingError {
            return OrbitStreamDisplayProblem(title: "Unexpected reply", message: "Your PC sent a reply Orbit doesn't understand. Update Orbit PC Companion and Orbit.")
        }
        return OrbitStreamDisplayProblem(title: "Something went wrong", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

// MARK: - Demo data

extension OrbitStreamDisplayStatus {
    /// A PC with everything installed; `fillOn`, `listing` and `rates` decide what is already set up.
    static func demo(listing sizes: [OrbitDisplaySize] = [], rates: [Int] = [], fillOn: Bool = false, secondScreenOn: Bool = false,
                     position: String = "right") -> OrbitStreamDisplayStatus {
        var status = OrbitStreamDisplayStatus()
        status.sunshineVersion = "2026.1017.152030"
        status.sunshineRunning = true
        status.loginSaved = true
        status.sunshineSupported = true
        status.streamActive = false
        status.appRunning = false
        status.virtualDisplay.installed = true
        status.virtualDisplay.driver = "vdd"
        status.virtualDisplay.deviceStatus = "running"
        status.virtualDisplay.deviceId = "{00000000-0000-4000-8000-000000000001}"
        let base = [OrbitDisplaySize(width: 1920, height: 1080), OrbitDisplaySize(width: 2560, height: 1440), OrbitDisplaySize(width: 3840, height: 2160)]
        var listed: [OrbitDisplaySize] = []
        for size in base + sizes where !listed.contains(size) { listed.append(size) }
        let refreshRates = Array(Set([60, 120] + rates)).sorted()
        status.virtualDisplay.resolutions = listed.map(\.key)
        status.virtualDisplay.refreshRates = refreshRates
        status.virtualDisplay.modes = listed.flatMap { size in refreshRates.map { "\(size.key)@\($0)" } }
        status.fill = Fill(enabled: fillOn, onlyDisplay: false)
        if fillOn || secondScreenOn {
            status.config.outputName = status.virtualDisplay.deviceId
            status.config.configurationOption = secondScreenOn ? "ensure_active" : "ensure_primary"
            status.config.resolutionOption = "auto"
            status.config.refreshRateOption = fillOn ? "auto" : nil
            status.savedConfig.available = true
        }
        status.secondScreen.active = secondScreenOn
        status.secondScreen.position = secondScreenOn ? position : nil
        status.secondScreen.placement = secondScreenOn ? "done" : nil
        status.fillReady = true
        status.installCommand = defaultInstallCommand
        return status
    }

    /// Demo mode: the same sample PC with the second screen turned on (on `position`) or off again.
    func demoWithSecondScreen(_ on: Bool, position: String = "right") -> OrbitStreamDisplayStatus {
        var status = self
        status.secondScreen.active = on
        status.secondScreen.position = on ? position : nil
        status.secondScreen.placement = on ? "done" : nil
        if on {
            status.config.outputName = virtualDisplay.deviceId
            status.config.configurationOption = "ensure_active"
            status.config.resolutionOption = "auto"
            status.savedConfig.available = true
        } else if fill.enabled {
            status.config.configurationOption = fill.onlyDisplay ? "ensure_only_display" : "ensure_primary"
            status.config.refreshRateOption = "auto"
        } else {
            status.config = SunshineConfig()
            status.savedConfig.available = false
        }
        return status
    }
}
