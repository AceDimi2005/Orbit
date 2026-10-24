import Foundation
import SwiftUI
import UIKit
import UserNotifications

// PC alerts on iPhone and iPad (DESIGN F1): the APNs delegate, registration with every PC that offers
// instant pushes, the local fallback poller and the PC automation API (alerts, downloads, watched apps,
// "sleep when finished"). The screen itself is `NotificationsSettingsView`.

// MARK: - JSON value (keeps settings the app doesn't know about when it writes them back)

enum OrbitJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OrbitJSON])
    case object([String: OrbitJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([OrbitJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: OrbitJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers stay integers ("cpu": 90, not 90.0) for the PC's validation.
            if value.isFinite, value == value.rounded(), abs(value) < 9.0e15 { try container.encode(Int(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> OrbitJSON? {
        get { if case .object(let object) = self { return object[key] }; return nil }
        set {
            var object: [String: OrbitJSON] = [:]
            if case .object(let existing) = self { object = existing }
            object[key] = newValue
            self = .object(object)
        }
    }

    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var double: Double? { if case .number(let value) = self { return value }; return nil }
}

// MARK: - PC API models

/// `GET /api/capabilities`. A 404 means an agent older than these features.
struct OrbitCapabilities: Decodable {
    var agentVersion: String?
    var features: [String]
}

enum OrbitPCFeatures: Equatable {
    case unknown
    case olderAgent
    case available(agentVersion: String?, features: Set<String>)

    func has(_ feature: String) -> Bool {
        if case .available(_, let features) = self { return features.contains(feature) }
        return false
    }
    var isKnown: Bool { self != .unknown }
}

/// `GET/PUT /api/alerts` (full replace). Edits go into the PC's own object, so keys a newer agent adds
/// survive the round trip.
struct OrbitAlertSettings: Equatable {
    var raw: OrbitJSON

    static let fallback = OrbitAlertSettings(raw: .object([
        "temperature": .object(["enabled": .bool(true), "cpu": .number(90), "gpu": .number(85), "forSeconds": .number(30)]),
        "downloads": .object(["enabled": .bool(true)]),
        "tasks": .object(["enabled": .bool(true)]),
        "online": .object(["enabled": .bool(true)]),
        "summary": .object(["enabled": .bool(true)]),
        "pcToasts": .bool(true)
    ]))

    private func flag(_ section: String) -> Bool { raw[section]?["enabled"]?.bool ?? true }
    private mutating func setFlag(_ section: String, _ value: Bool) {
        var object = raw[section] ?? .object([:])
        object["enabled"] = .bool(value)
        raw[section] = object
    }
    private func temperature(_ key: String, default value: Int) -> Int {
        raw["temperature"]?[key]?.double.map { Int($0.rounded()) } ?? value
    }
    private mutating func setTemperature(_ key: String, _ value: Int) {
        var object = raw["temperature"] ?? .object([:])
        object[key] = .number(Double(value))
        raw["temperature"] = object
    }

    var temperatureEnabled: Bool { get { flag("temperature") } set { setFlag("temperature", newValue) } }
    var cpuLimit: Int { get { temperature("cpu", default: 90) } set { setTemperature("cpu", newValue) } }
    var gpuLimit: Int { get { temperature("gpu", default: 85) } set { setTemperature("gpu", newValue) } }
    var forSeconds: Int { get { temperature("forSeconds", default: 30) } set { setTemperature("forSeconds", newValue) } }
    var downloads: Bool { get { flag("downloads") } set { setFlag("downloads", newValue) } }
    var tasks: Bool { get { flag("tasks") } set { setFlag("tasks", newValue) } }
    var online: Bool { get { flag("online") } set { setFlag("online", newValue) } }
    var summary: Bool { get { flag("summary") } set { setFlag("summary", newValue) } }
    var pcToasts: Bool { get { raw["pcToasts"]?.bool ?? true } set { raw["pcToasts"] = .bool(newValue) } }
}

/// `GET /api/downloads`.
struct OrbitPCDownloads: Decodable, Equatable {
    struct Item: Decodable, Identifiable, Equatable {
        var id: String
        var store: String
        var name: String
        var state: String
        var progress: Double?
        var bytesDone: Double?
        var bytesTotal: Double?
        var updatedAt: String?
    }
    var downloads: [Item]
    var active: Bool
    var stores: [String: Bool]?
}

/// One app the PC watches (`GET/POST /api/tasks`).
struct OrbitWatchedTask: Decodable, Identifiable, Equatable {
    var id: String
    var pid: Int?
    var label: String
    var mode: String
    var state: String
    var startedAt: String?
    var finishedAt: String?
}

struct OrbitWatchedTasks: Decodable { var tasks: [OrbitWatchedTask] }

struct OrbitNewWatchedTask: Encodable {
    var pid: Int
    var createTime: Double
    var mode: String
    var idleMinutes: Int?
    var label: String
}

/// `GET /api/power/after`: `{"rule": null | {...}}`.
struct OrbitPowerRule: Decodable, Equatable {
    var trigger: String
    var taskID: String?
    var action: String
    var delaySeconds: Int?
    var state: String
    var countdownEndsAt: String?

    var countdownEnd: Date? { countdownEndsAt.flatMap(OrbitEventFeed.parseTimestamp) }
}

struct OrbitPowerAfter: Decodable { var rule: OrbitPowerRule? }

// OrbitPowerAfterRequest (PUT /api/power/after) is defined once in Shared/OrbitIntentModels.swift.

struct OrbitPushRegistration: Encodable {
    var deviceID: String
    var apnsToken: String
    var environment: String
    var key: String
    var deviceName: String
}

struct OrbitPushRegisterReply: Decodable {
    var status: String
    var relay: String?
}

/// `GET /api/push/status`.
struct OrbitPushStatus: Decodable, Equatable {
    struct Device: Decodable, Equatable {
        var deviceID: String
        var deviceName: String?
        var registeredAt: String?
        var lastDeliveryAt: String?
        var lastError: String?
    }
    var relayConfigured: Bool
    var devices: [Device]
}

// MARK: - Errors in plain words

enum OrbitPlainError {
    static func describe(_ error: Error) -> String {
        if let orbit = error as? OrbitError { return orbit.message }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
                return "Your PC didn't answer. Check that it's awake, on the same network, and that Orbit PC Companion is running."
            case .cancelled: return "The request was cancelled."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return "The PC's identity didn't match. Pair it again in My PCs."
            default: break
            }
        }
        if error is DecodingError { return "Your PC sent a reply Orbit doesn't understand. Update Orbit PC Companion and Orbit." }
        return error.localizedDescription
    }
}

// MARK: - A saved PC Orbit can talk to securely

/// One saved PC with a pinned HTTPS client. Built from the saved profiles, so it works without the
/// view model (background refresh, notification actions).
struct OrbitPCLink: Sendable {
    let id: String
    let name: String
    let client: OrbitAPIClient

    static func savedProfiles() -> [SavedPC] {
        guard let data = UserDefaults.standard.data(forKey: "savedPCs.v1"),
              let profiles = try? JSONDecoder().decode([SavedPC].self, from: data) else { return [] }
        return profiles
    }

    static func make(_ profile: SavedPC) -> OrbitPCLink? {
        let token = PCProfileStore.token(profile.id)
        guard !token.isEmpty,
              let client = try? OrbitAPIClient(host: profile.address, port: profile.securePort, token: token, fingerprint: profile.certificateFingerprint) else { return nil }
        return OrbitPCLink(id: profile.id, name: profile.name, client: client)
    }

    static func all() -> [OrbitPCLink] { savedProfiles().compactMap(make) }

    static func link(for id: String) -> OrbitPCLink? {
        savedProfiles().first { $0.id == id }.flatMap(make)
    }

    /// The PC selected in Orbit (the one the Overview shows).
    static func selected() -> OrbitPCLink? {
        guard !UserDefaults.standard.bool(forKey: "demoMode"),
              let id = UserDefaults.standard.string(forKey: "selectedPCID"), !id.isEmpty else { return nil }
        return link(for: id)
    }

    /// The view model's current connection.
    @MainActor
    static func current(_ vm: OrbitViewModel) -> OrbitPCLink? {
        guard !vm.isDemoMode, vm.hasSecureConnection, !vm.selectedPCID.isEmpty, let client = try? vm.companionClient() else { return nil }
        return OrbitPCLink(id: vm.selectedPCID, name: vm.selectedPCName, client: client)
    }
}

// MARK: - Feature detection

/// `GET /api/capabilities` per PC, cached for 10 minutes.
@MainActor
final class OrbitFeatureStore: ObservableObject {
    static let shared = OrbitFeatureStore()
    @Published private(set) var byPC: [String: OrbitPCFeatures] = [:]
    private var fetchedAt: [String: Date] = [:]

    func cached(_ pcID: String) -> OrbitPCFeatures { byPC[pcID] ?? .unknown }

    func features(for link: OrbitPCLink, maxAge: TimeInterval = 600) async throws -> OrbitPCFeatures {
        if let known = byPC[link.id], known.isKnown, let at = fetchedAt[link.id], Date().timeIntervalSince(at) < maxAge { return known }
        let result: OrbitPCFeatures
        do {
            let reply: OrbitCapabilities = try await link.client.get("/api/capabilities")
            result = .available(agentVersion: reply.agentVersion, features: Set(reply.features))
        } catch let error as OrbitError where error.statusCode == 404 {
            result = .olderAgent
        }
        byPC[link.id] = result
        fetchedAt[link.id] = Date()
        return result
    }

    func invalidate(_ pcID: String) {
        byPC[pcID] = nil
        fetchedAt[pcID] = nil
    }
}

// MARK: - Preferences

enum OrbitNotificationPreferences {
    static let enabledKey = "orbit.notifications.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var isDemoMode: Bool { UserDefaults.standard.bool(forKey: "demoMode") }

    /// Background refresh is worth scheduling while alerts are on, or while a PC still has to be told to
    /// forget this iPhone.
    static var needsBackgroundRefresh: Bool { isEnabled || OrbitPushUnregisterQueue.hasPending }

    /// Which APNs host the relay must use for this build's token. The signing profile decides, not the
    /// build configuration: a Release build run from Xcode still gets a development (sandbox) token.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        return apsEnvironment(fromProvisioningProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")) ?? "production"
        #endif
    }()

    /// `aps-environment` of an `embedded.mobileprovision` (development → sandbox). App Store and TestFlight
    /// builds carry no profile: production.
    static func apsEnvironment(fromProvisioningProfile url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else { return nil }
        return value == "development" ? "sandbox" : "production"
    }

    static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }
}

// MARK: - Ids in request paths

enum OrbitPathSegment {
    /// The id itself when it's safe as one path segment (`[A-Za-z0-9._-]`, which is all the PC hands out),
    /// else nil. Never pre-encode: `OrbitAPIClient` builds the URL with `URLComponents.path`, which encodes
    /// again (`%2D` would reach the PC as `%252D`).
    static func safe(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128, id != ".", id != "..",
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }) else { return nil }
        return id
    }
}

// MARK: - A request that must not hang

enum OrbitDeadline {
    /// Runs `operation`, giving up with `URLError(.timedOut)` after `seconds` (the client's own timeout is 20 s).
    static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }
}

// MARK: - PCs that still have to forget this iPhone

/// When alerts are turned off or a PC is removed, the PC must delete this device
/// (`DELETE /api/push/devices/{deviceID}`), or it keeps pushing alerts nothing can open any more. A PC
/// that's off or away at that moment stays in this queue, which is retried on launch, on every foreground
/// poll and in background refresh until the PC answers (200, or 404 from an agent without the route).
///
/// The queue sits in the app's own keychain (`Orbit.PushPendingUnregister.v1`), because each entry keeps
/// the PC's pairing token: a removed PC's profile and token are gone by the time it comes back.
@MainActor
enum OrbitPushUnregisterQueue {
    struct Entry: Codable, Equatable {
        var pcID: String
        var pcName: String
        var host: String
        var port: Int
        var fingerprint: String
        var token: String
        var deviceID: String
        var addedAt: Double
    }

    nonisolated static let service = "Orbit.PushPendingUnregister.v1"
    /// Give up on a PC that hasn't answered for this long (it was probably reset or thrown away).
    static let maximumAge: TimeInterval = 60 * 24 * 60 * 60
    static let maximumEntries = 32
    /// Between automatic retries (a PC that's off makes each attempt wait for the timeout).
    static let retryInterval: TimeInterval = 60
    private static var retryTask: Task<Void, Never>?
    private static var lastRetry = Date.distantPast

    nonisolated private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "queue"]
    }

    nonisolated static func entries() -> [Entry] {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    nonisolated static var hasPending: Bool { !entries().isEmpty }

    private static func save(_ entries: [Entry]) {
        _ = SecItemDelete(query as CFDictionary)
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Remembers that `profile` must forget `deviceID` (replacing an older entry for the same pair).
    static func add(_ profile: SavedPC, token: String, deviceID: String) {
        guard !token.isEmpty, !deviceID.isEmpty, OrbitAPIClient.validFingerprint(profile.certificateFingerprint) else { return }
        var list = entries().filter { !($0.pcID == profile.id && $0.deviceID == deviceID) }
        list.append(Entry(pcID: profile.id, pcName: profile.name, host: profile.address, port: profile.securePort,
                          fingerprint: profile.certificateFingerprint, token: token, deviceID: deviceID,
                          addedAt: Date().timeIntervalSince1970))
        save(Array(list.suffix(maximumEntries)))
    }

    /// The PC registered this device again (under this profile, or a new one after pairing it again): an old
    /// "forget" must never undo that.
    static func remove(pcID: String, deviceID: String) {
        let fingerprint = OrbitPCLink.savedProfiles().first { $0.id == pcID }.map { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) }
        let list = entries()
        let kept = list.filter { entry in
            guard entry.deviceID == deviceID else { return true }
            return entry.pcID != pcID && OrbitAPIClient.normalizedFingerprint(entry.fingerprint) != fingerprint
        }
        if kept.count != list.count { save(kept) }
    }

    /// Lets a running retry finish (registration waits for it, so a late DELETE can't undo a new registration).
    static func waitForRetry() async {
        await retryTask?.value
    }

    /// Tries every queued PC once. Automatic calls run at most once a minute; `force` tries now.
    static func retry(force: Bool = false) async {
        if let running = retryTask { await running.value; if !force { return } }
        guard !OrbitNotificationPreferences.isDemoMode, force || Date().timeIntervalSince(lastRetry) >= retryInterval else { return }
        guard !entries().isEmpty else { return }
        lastRetry = Date()
        let task = Task { await attemptAll() }
        retryTask = task
        await task.value
        // A forced retry may have started another round meanwhile; that one stays visible to waitForRetry.
        if retryTask == task { retryTask = nil }
    }

    private enum Outcome { case done, keep }

    private static func attemptAll() async {
        let now = Date().timeIntervalSince1970
        let profiles = OrbitPCLink.savedProfiles()
        let currentDeviceID = OrbitPushStore.deviceID(create: false)
        var pending: [(Entry, OrbitAPIClient)] = []
        var finished: [Entry] = []
        for entry in entries() {
            let profile = profiles.first { $0.id == entry.pcID }
            if now - entry.addedAt > maximumAge { finished.append(entry); continue }
            // Alerts are on again and the PC is still (or again) saved: registering replaces this device's
            // record, and a late DELETE would undo it.
            let fingerprint = OrbitAPIClient.normalizedFingerprint(entry.fingerprint)
            let savedAgain = profile != nil || profiles.contains { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == fingerprint }
            if OrbitNotificationPreferences.isEnabled, savedAgain, entry.deviceID == currentDeviceID {
                finished.append(entry); continue
            }
            // A saved PC may have a new address or token since; a removed one only has what was kept.
            let liveToken = profile.map { PCProfileStore.token($0.id) } ?? ""
            guard let client = try? OrbitAPIClient(host: profile?.address ?? entry.host, port: profile?.securePort ?? entry.port,
                                                   token: liveToken.isEmpty ? entry.token : liveToken,
                                                   fingerprint: profile?.certificateFingerprint ?? entry.fingerprint) else {
                finished.append(entry); continue
            }
            guard OrbitPathSegment.safe(entry.deviceID) != nil else { finished.append(entry); continue }
            pending.append((entry, client))
        }
        let results = await withTaskGroup(of: (Entry, Outcome).self) { group in
            for (entry, client) in pending {
                group.addTask {
                    let path = "/api/push/devices/" + entry.deviceID
                    do {
                        _ = try await OrbitDeadline.run(seconds: 8) { try await client.data(path, method: "DELETE") }
                        return (entry, .done)
                    } catch let error as OrbitError where [401, 403, 404].contains(error.statusCode ?? 0) {
                        // 404: an agent without push routes has nothing to forget. 401/403: the PC no longer
                        // accepts this pairing, so it can't be asked; retrying forever wouldn't help.
                        return (entry, .done)
                    } catch {
                        return (entry, .keep)
                    }
                }
            }
            var collected: [(Entry, Outcome)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        finished += results.filter { $0.1 == .done }.map(\.0)
        guard !finished.isEmpty else { return }
        // Entries added while this ran stay queued.
        save(entries().filter { !finished.contains($0) })
    }
}

// MARK: - Registration with each PC

/// Gets the APNs token and hands it, with a per-PC key, to every saved PC that offers instant pushes
/// (`POST /api/push/register`). The PC then sends encrypted alerts through the relay; the phone never
/// talks to the relay itself.
@MainActor
final class OrbitPushRegistrar: ObservableObject {
    static let shared = OrbitPushRegistrar()

    enum TokenState: Equatable {
        case none, requesting, ready(String), failed(String)
    }

    enum PCPhase: Equatable {
        case unknown, registering
        case registered(relayEnabled: Bool)
        case noPushSupport, olderAgent, needsSecureConnection
        case failed(String)
    }

    @Published private(set) var tokenState: TokenState = .none
    @Published private(set) var phases: [String: PCPhase] = [:]
    private var registeredToken: [String: String] = [:]
    private var inFlight: Set<String> = []
    nonisolated private static let tokenKey = "Orbit.PushToken.v1"
    nonisolated private static let relayKey = "Orbit.PushRelayActive.v1"

    /// Whether the PC said its relay is on for this device (the poller then leaves fresh events to the push).
    nonisolated static func relayActive(for pcID: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: relayKey) as? [String: Bool])?[pcID] ?? false
    }

    private static func setRelayActive(_ value: Bool?, for pcID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: relayKey) as? [String: Bool]) ?? [:]
        map[pcID] = value
        UserDefaults.standard.set(map, forKey: relayKey)
    }

    func phase(for pcID: String) -> PCPhase { phases[pcID] ?? .unknown }

    var token: String? {
        if case .ready(let token) = tokenState { return token }
        return nil
    }

    /// Asks iOS for the APNs token; the answer arrives in `OrbitAppDelegate`.
    func requestToken() {
        if token == nil { tokenState = .requesting }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func tokenReceived(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let previous = UserDefaults.standard.string(forKey: Self.tokenKey)
        tokenState = .ready(hex)
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        if previous != hex { registeredToken.removeAll() }
        // Every launch (and every new token) registers again, so a PC always holds the current token.
        Task { await registerAll() }
    }

    func tokenFailed(_ error: Error) {
        tokenState = .failed((error as NSError).localizedDescription)
    }

    /// Registers with every saved PC (in parallel, each on its own timeout). Demo mode never calls a PC;
    /// the poller registers once demo mode is turned off.
    func registerAll(force: Bool = false) async {
        guard OrbitNotificationPreferences.isEnabled, !OrbitNotificationPreferences.isDemoMode, token != nil else { return }
        let links = OrbitPCLink.all()
        for profile in OrbitPCLink.savedProfiles() where !links.contains(where: { $0.id == profile.id }) {
            phases[profile.id] = .needsSecureConnection
        }
        await withTaskGroup(of: Void.self) { group in
            for link in links {
                group.addTask { @MainActor in await self.register(link, force: force) }
            }
        }
    }

    /// Registers when this PC hasn't seen the current token during this run of the app.
    func ensureRegistered(_ link: OrbitPCLink) async {
        guard let token, registeredToken[link.id] != token else { return }
        await register(link)
    }

    func register(_ link: OrbitPCLink, force: Bool = false) async {
        guard OrbitNotificationPreferences.isEnabled, !OrbitNotificationPreferences.isDemoMode, let token, !inFlight.contains(link.id) else { return }
        if !force, registeredToken[link.id] == token { return }
        inFlight.insert(link.id)
        defer { inFlight.remove(link.id) }
        guard let deviceID = OrbitPushStore.deviceID(create: true) else {
            phases[link.id] = .failed("iOS couldn't store this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")'s alert ID securely. Unlock it and try again.")
            return
        }
        if phases[link.id] == nil || phases[link.id] == .unknown { phases[link.id] = .registering }
        // A "forget this iPhone" still on its way to this PC must not land after the new registration.
        await OrbitPushUnregisterQueue.waitForRetry()
        do {
            let features = try await OrbitFeatureStore.shared.features(for: link)
            if features == .olderAgent { phases[link.id] = .olderAgent; Self.setRelayActive(nil, for: link.id); return }
            guard features.has("push") else { phases[link.id] = .noPushSupport; Self.setRelayActive(nil, for: link.id); return }
            let key = try OrbitPushStore.ensureKey(for: link.id)
            OrbitPushStore.setPCName(link.name, for: link.id)
            let body = OrbitPushRegistration(deviceID: deviceID, apnsToken: token, environment: OrbitNotificationPreferences.environment,
                                             key: key.base64EncodedString(), deviceName: UIDevice.current.name)
            let reply: OrbitPushRegisterReply = try await link.client.send("/api/push/register", body: body)
            // Alerts may have been turned off while the PC answered.
            guard OrbitNotificationPreferences.isEnabled else { return }
            let relay = reply.relay == "enabled"
            phases[link.id] = .registered(relayEnabled: relay)
            registeredToken[link.id] = token
            Self.setRelayActive(relay, for: link.id)
            OrbitPushUnregisterQueue.remove(pcID: link.id, deviceID: deviceID)
        } catch {
            phases[link.id] = .failed(OrbitPlainError.describe(error))
        }
    }

    /// Alerts off on this iPhone: every PC that may know this device is told to forget it (now, or later
    /// through `OrbitPushUnregisterQueue` when it's unreachable), the keys are dropped, and the APNs token
    /// is given up so that a PC that never hears it gets "unregistered" from Apple through the relay.
    func unregisterAll() async {
        let profiles = OrbitPCLink.savedProfiles()
        if let deviceID = OrbitPushStore.deviceID(create: false) {
            // Every PC with an encrypted connection, key or not: a key can be gone while the PC still holds a
            // registration (removed and paired again), and a PC that never knew this device just says so.
            for profile in profiles {
                OrbitPushUnregisterQueue.add(profile, token: PCProfileStore.token(profile.id), deviceID: deviceID)
            }
        }
        for account in OrbitPushStore.keyAccounts() { OrbitPushStore.removeKey(for: account) }
        for profile in profiles { Self.setRelayActive(nil, for: profile.id) }
        registeredToken.removeAll()
        phases.removeAll()
        UIApplication.shared.unregisterForRemoteNotifications()
        tokenState = .none
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        await OrbitPushUnregisterQueue.retry(force: true)
    }

    /// A PC is being removed from Orbit: queue "forget this device" while its token still exists, and try it
    /// right away (the PC is usually online when someone removes it).
    func forget(_ profile: SavedPC) {
        if let deviceID = OrbitPushStore.deviceID(create: false),
           OrbitNotificationPreferences.isEnabled || OrbitPushStore.key(for: profile.id) != nil {
            OrbitPushUnregisterQueue.add(profile, token: PCProfileStore.token(profile.id), deviceID: deviceID)
        }
        OrbitPushStore.removeKey(for: profile.id)
        OrbitPushStore.forgetDelivered(for: profile.id)
        OrbitPushStore.setPCName(nil, for: profile.id)
        OrbitEventPoller.forgetCursor(for: profile.id)
        Self.setRelayActive(nil, for: profile.id)
        registeredToken[profile.id] = nil
        phases[profile.id] = nil
        OrbitFeatureStore.shared.invalidate(profile.id)
        Task { await OrbitPushUnregisterQueue.retry(force: true) }
    }
}

// MARK: - Turning alerts on and off

@MainActor
enum OrbitNotificationSwitch {
    /// Asks for permission (Time Sensitive comes with Orbit's entitlement), gets the APNs token and
    /// registers with the PCs. Returns a sentence to show when something stops it.
    static func enable() async -> String? {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var allowed = OrbitNotificationPreferences.isAuthorized(settings.authorizationStatus)
        if settings.authorizationStatus == .notDetermined {
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        guard allowed else {
            UserDefaults.standard.set(false, forKey: OrbitNotificationPreferences.enabledKey)
            return "Notifications are off for Orbit. Turn them on in iOS Settings › Notifications › Orbit, then try again."
        }
        UserDefaults.standard.set(true, forKey: OrbitNotificationPreferences.enabledKey)
        OrbitPushRegistrar.shared.requestToken()
        OrbitEventPoller.shared.preferencesChanged()
        return nil
    }

    static func disable() async {
        UserDefaults.standard.set(false, forKey: OrbitNotificationPreferences.enabledKey)
        OrbitEventPoller.shared.preferencesChanged()
        // Turning alerts on again starts from "now", never with what happened while they were off.
        OrbitEventPoller.forgetAllCursors()
        await OrbitPushRegistrar.shared.unregisterAll()
    }
}

// MARK: - Local fallback poller

/// Reads the selected PC's event log while Orbit is open (every 20 s) and during background refresh,
/// and posts what the instant pushes didn't already show. The first poll of a PC only learns where its
/// log ends, so turning alerts on never replays history.
@MainActor
final class OrbitEventPoller {
    static let shared = OrbitEventPoller()
    static let interval: TimeInterval = 20
    /// With instant pushes working, events younger than this are left to the push.
    static let pushGrace: TimeInterval = 45
    nonisolated private static let cursorKey = "Orbit.EventCursor.v1"
    private var loop: Task<Void, Never>?
    private var appActive = false
    private var isPolling = false

    nonisolated static func cursor(for pcID: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: cursorKey) as? [String: Int])?[pcID]
    }

    nonisolated static func setCursor(_ value: Int, for pcID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: cursorKey) as? [String: Int]) ?? [:]
        map[pcID] = value
        UserDefaults.standard.set(map, forKey: cursorKey)
    }

    nonisolated static func forgetCursor(for pcID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: cursorKey) as? [String: Int]) ?? [:]
        map.removeValue(forKey: pcID)
        UserDefaults.standard.set(map, forKey: cursorKey)
    }

    nonisolated static func forgetAllCursors() {
        UserDefaults.standard.removeObject(forKey: cursorKey)
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        preferencesChanged()
        // Runs with alerts off too: that's when a PC that was away still has to forget this iPhone.
        if active { Task { await OrbitPushUnregisterQueue.retry() } }
    }

    func preferencesChanged() {
        loop?.cancel()
        loop = nil
        guard appActive, OrbitNotificationPreferences.isEnabled else { return }
        loop = Task { [weak self] in
            await OrbitLocalAlerts.removeDuplicateDeliveries()
            var wasDemo = OrbitNotificationPreferences.isDemoMode
            while !Task.isCancelled {
                // Demo mode never registers with a PC; once it's off, every saved PC gets this iPhone's key.
                let isDemo = OrbitNotificationPreferences.isDemoMode
                if wasDemo, !isDemo { await OrbitPushRegistrar.shared.registerAll() }
                wasDemo = isDemo
                await OrbitPushUnregisterQueue.retry()
                _ = await self?.pollSelected(background: false)
                do { try await Task.sleep(for: .seconds(Self.interval)) } catch { break }
            }
        }
    }

    /// Background refresh: the queued "forget this iPhone" requests, then one poll of the selected PC.
    func backgroundCheck() async -> Bool {
        await OrbitPushUnregisterQueue.retry()
        return await pollSelected(background: true)
    }

    /// One poll of the selected PC. Returns true when the PC answered.
    @discardableResult
    func pollSelected(background: Bool) async -> Bool {
        guard OrbitNotificationPreferences.isEnabled, !isPolling, let link = OrbitPCLink.selected() else { return false }
        isPolling = true
        defer { isPolling = false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard OrbitNotificationPreferences.isAuthorized(settings.authorizationStatus) else { return false }
        if !background { await OrbitPushRegistrar.shared.ensureRegistered(link) }
        do {
            guard try await OrbitFeatureStore.shared.features(for: link).has("events") else { return true }
            let previous = Self.cursor(for: link.id)
            // Before the snapshot: an id the extension records after this belongs to this poll's time.
            let startedAt = Date()
            let delivered = OrbitPushStore.delivered(for: link.id)
            let holdBack: TimeInterval? = OrbitPushRegistrar.relayActive(for: link.id) ? Self.pushGrace : nil
            let client = link.client
            let result = try await OrbitEventFeed.poll(cursor: previous, delivered: delivered, holdBack: holdBack) { since, limit in
                var query = [URLQueryItem(name: "limit", value: String(limit))]
                if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
                return try await client.get("/api/events", query: query)
            }
            // The PC's log started over (reinstall, reset): what was recorded for its old log must not hide new alerts.
            OrbitPushStore.reconcileDelivered(for: link.id, latestID: result.latestID, floor: min(previous ?? result.cursor, result.cursor),
                                              pollStartedAt: startedAt, logRecreated: result.resynced && previous != nil)
            // Recording is the atomic check: an id the extension recorded meanwhile was shown by its push.
            for event in result.toPost where OrbitPushStore.recordDelivered(event.id, for: link.id) {
                await OrbitLocalAlerts.post(event, pcID: link.id, pcName: link.name)
            }
            Self.setCursor(result.cursor, for: link.id)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Posting and handling notifications

enum OrbitLocalAlerts {
    static let duplicateKey = OrbitPushContent.duplicateKey

    static func categories() -> Set<UNNotificationCategory> {
        let cancel = UNNotificationAction(identifier: OrbitEventFeed.cancelPowerAction, title: "Cancel", options: [])
        return [
            UNNotificationCategory(identifier: OrbitEventFeed.powerScheduledCategory, actions: [cancel], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: OrbitEventFeed.eventCategory, actions: [], intentIdentifiers: [], options: [])
        ]
    }

    static func post(_ event: OrbitPCEvent, pcID: String, pcName: String, now: Date = Date()) async {
        let content = UNMutableNotificationContent()
        content.title = event.title.isEmpty ? pcName : event.title
        // Same grouping and subtitle as the pushes the extension shows for this PC.
        content.subtitle = pcName
        content.body = OrbitEventFeed.displayBody(event, now: now)
        content.threadIdentifier = pcID
        content.categoryIdentifier = OrbitEventFeed.notificationCategory(for: event.kind)
        content.userInfo = ["link": OrbitPushCrypto.defaultLink, "pcID": pcID, "eventID": event.id, "kind": event.kind]
        switch event.level {
        case "passive": content.interruptionLevel = .passive
        case "timeSensitive": content.interruptionLevel = .timeSensitive; content.sound = .default
        default: content.interruptionLevel = .active; content.sound = .default
        }
        let request = UNNotificationRequest(identifier: OrbitEventFeed.notificationIdentifier(pcID: pcID, eventID: event.id), content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// A push the extension marked as already shown (the poller posted it first) is removed quietly.
    static func removeDuplicateDeliveries() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let duplicates = delivered.filter { ($0.request.content.userInfo[duplicateKey] as? Bool) == true }.map(\.request.identifier)
        if !duplicates.isEmpty { center.removeDeliveredNotifications(withIdentifiers: duplicates) }
    }

    /// "Cancel" on a "Sleeping in 60 s" alert. Only the PC that sent it is ever asked: falling back to the
    /// selected PC could cancel that PC's own, unrelated automatic sleep.
    static func cancelPower(pcID: String?) async {
        let link: OrbitPCLink?
        if let pcID, !pcID.isEmpty { link = OrbitPCLink.link(for: pcID) } else { link = OrbitPCLink.selected() }
        guard let link else {
            await postNote(title: "Couldn't cancel", body: "Orbit can't find that PC any more. Open Orbit to check it.")
            return
        }
        let client = link.client
        do {
            // Short, so the action finishes inside the background time iOS gives it.
            _ = try await OrbitDeadline.run(seconds: 10) { try await client.data("/api/power/after", method: "DELETE") }
        } catch let error as OrbitError where error.statusCode == 404 {
            // Nothing left to cancel (the rule already ended).
        } catch {
            await postNote(title: "Couldn't cancel on \(link.name)", body: OrbitPlainError.describe(error) + " Open Orbit to try again.")
        }
    }

    private static func postNote(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["link": OrbitPushCrypto.defaultLink]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orbit.note.\(UUID().uuidString)", content: content, trigger: nil))
    }
}

/// Opens the notifications screen when an alert is tapped or `orbit://notifications` is opened.
@MainActor
final class OrbitNotificationRouter: ObservableObject {
    static let shared = OrbitNotificationRouter()
    @Published var showsNotifications = false
    /// A monthly summary to open (`orbit://summary?month=YYYY-MM&pc=<id>`, or a tapped `summary.ready` alert).
    @Published var summaryRequest: OrbitSummaryRequest?
    /// `orbit://energy`: the Electricity Cost screen.
    @Published var showsEnergyCost = false

    func open(link: String?) {
        guard let link, let url = URL(string: link), url.scheme?.lowercased() == "orbit" else { return }
        switch url.host?.lowercased() {
        case "notifications": showsNotifications = true
        case "summary": summaryRequest = OrbitSummaryRequest(url: url)
        case "energy": showsEnergyCost = true
        default: break
        }
    }
}

// MARK: - App delegate

/// Extra background time for a notification action. Ends itself when iOS runs out of time, as iOS
/// requires (an app that doesn't end its task in time is terminated).
@MainActor
final class OrbitBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// APNs token and notification taps/actions (installed with `UIApplicationDelegateAdaptor` in `OrbitApp`).
final class OrbitAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(OrbitLocalAlerts.categories())
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["ORBIT_NOTIFY_SELFTEST"] { OrbitNotifySelfTest.start(mode: mode); return true }
        if let link = ProcessInfo.processInfo.environment["ORBIT_SELFTEST_OPEN_URL"] { OrbitNotifySelfTest.open(link) }
        #endif
        if OrbitNotificationPreferences.isEnabled {
            Task { @MainActor in OrbitPushRegistrar.shared.requestToken() }
        }
        // PCs that were away when they should have forgotten this device (also on a background launch).
        Task { @MainActor in await OrbitPushUnregisterQueue.retry(force: true) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in OrbitPushRegistrar.shared.tokenReceived(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in OrbitPushRegistrar.shared.tokenFailed(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if (notification.request.content.userInfo[OrbitLocalAlerts.duplicateKey] as? Bool) == true {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pcID = info["pcID"] as? String
        // A "summary is ready" alert opens that month's summary; every other alert keeps its own link.
        let link = OrbitSummaryRequest.link(forKind: info["kind"] as? String, pcID: pcID, deliveredAt: response.notification.date)
            ?? info["link"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case OrbitEventFeed.cancelPowerAction:
                let background = OrbitBackgroundTask(name: "Cancel PC power action")
                await OrbitLocalAlerts.cancelPower(pcID: pcID)
                background.end()
            case UNNotificationDefaultActionIdentifier:
                OrbitNotificationRouter.shared.open(link: link ?? OrbitPushCrypto.defaultLink)
            default:
                break
            }
            completionHandler()
        }
    }
}
