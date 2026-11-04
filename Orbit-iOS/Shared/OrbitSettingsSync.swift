import Foundation

// iCloud sync of Orbit's settings (theme, overview cards, Live Activity and Mac preferences) between the
// user's devices, through the same iCloud key-value storage as the saved PCs (OrbitPCSync.swift) and behind
// the same "Sync with iCloud" switch (`OrbitCloudSyncSwitch`).
//
// Everything lives under one key, `orbit.settings.v1`: a dictionary of entries
// `{"v": value, "t": seconds since 1970, "o": device}` by setting name, where a missing "v" means the setting
// was removed (a tombstone, so a removal reaches every device). The newest entry wins, setting by setting.
// Each device also keeps, in its own defaults, the entry it last synced for every setting; a local value that
// differs from that entry is an edit made on this device. One sync pass applies these rules:
// - A local edit is published with a time after anything this device has seen, so it wins.
// - A newer entry from iCloud replaces the local value, unless this device can't use it (a Pro theme without
//   Orbit Pro, a value of the wrong type); such an entry is tried again on the next pass.
// - The first time a device syncs a setting, iCloud's entry wins over a value the device never synced, and a
//   value iCloud doesn't have yet is uploaded. Turning the switch back on, or a new iCloud account, starts over
//   the same way.
// - An entry iCloud lost, or holds in an older version (two devices wrote at the same moment), is written again.
// Nothing is written when nothing changed, so devices never bounce updates back and forth.
//
// Not synced here on purpose: what lives on the PC (Button Deck, electricity price and estimate settings,
// monthly summaries, session history: every device already reads the same copy from the PC), what belongs to
// one device (selected PC, stream quality, notification permission and push registration, webcam, pointer
// speed, Home Screen icon, demo mode) and every secret.
//
// Foundation only: `Tests/check_settings_sync.py` compiles this file with OrbitPCSync.swift and runs the rules.

/// The kind of property-list value a setting holds. A value of another kind from iCloud is never applied.
enum OrbitSettingKind: Sendable {
    case bool, int, double, string, stringArray, stringDictionary, data

    /// Largest value a setting may sync (strings in characters, collections in items, data in bytes).
    static let maxStringLength = 512
    static let maxItems = 128
    static let maxDataBytes = 32 * 1024

    func accepts(_ value: Any) -> Bool {
        switch self {
        case .bool: return value is Bool
        case .int: return value is Int
        case .double: return value is Double
        case .string: return (value as? String).map { $0.count <= Self.maxStringLength } ?? false
        case .stringArray:
            guard let items = value as? [String] else { return false }
            return items.count <= Self.maxItems && items.allSatisfy { $0.count <= Self.maxStringLength }
        case .stringDictionary:
            guard let items = value as? [String: String] else { return false }
            return items.count <= Self.maxItems && items.allSatisfy { $0.key.count <= Self.maxStringLength && $0.value.count <= Self.maxStringLength }
        case .data: return (value as? Data).map { $0.count <= Self.maxDataBytes } ?? false
        }
    }
}

/// One synced setting. `cloudKey` names it in iCloud: a shared name ("theme") lets the iPhone and the Mac share
/// one value even though each app keeps it under its own `localKey` in UserDefaults.
struct OrbitSyncedSetting: Sendable {
    let cloudKey: String
    let localKey: String
    let kind: OrbitSettingKind
    /// Extra check before a value from iCloud is applied here (a theme this app knows, Orbit Pro for Pro themes).
    let isUsable: @Sendable (Any) -> Bool

    init(_ cloudKey: String, local localKey: String? = nil, _ kind: OrbitSettingKind,
         isUsable: @escaping @Sendable (Any) -> Bool = { _ in true }) {
        self.cloudKey = cloudKey
        self.localKey = localKey ?? cloudKey
        self.kind = kind
        self.isUsable = isUsable
    }
}

/// Settings kept under one defaults key per PC, such as `dashboardLayout.v1.<PC identity>`: every local key
/// that starts with `localPrefix` syncs as `cloudPrefix` + the same suffix.
struct OrbitSyncedSettingFamily: Sendable {
    let cloudPrefix: String
    let localPrefix: String
    let kind: OrbitSettingKind
    /// Suffixes that stay on the device (for example "preview", demo mode's layout).
    let excludedSuffixes: Set<String>

    init(cloud cloudPrefix: String, local localPrefix: String, _ kind: OrbitSettingKind, excluding excludedSuffixes: Set<String> = []) {
        self.cloudPrefix = cloudPrefix
        self.localPrefix = localPrefix
        self.kind = kind
        self.excludedSuffixes = excludedSuffixes
    }
}

/// One setting's value as synced: `value` nil means it was removed.
struct OrbitSettingEntry: CustomStringConvertible {
    var value: Any?
    var updatedAt: Double
    var origin: String

    init(value: Any?, updatedAt: Double, origin: String) {
        self.value = value
        self.updatedAt = updatedAt
        self.origin = origin
    }

    init?(plist: Any?) {
        guard let dictionary = plist as? [String: Any], let time = dictionary["t"] as? Double, time.isFinite else { return nil }
        value = dictionary["v"]
        updatedAt = time
        origin = dictionary["o"] as? String ?? ""
    }

    var plist: [String: Any] {
        var dictionary: [String: Any] = ["t": updatedAt, "o": origin]
        if let value { dictionary["v"] = value }
        return dictionary
    }

    var description: String { "\(value.map { "\($0)" } ?? "removed")@\(updatedAt)" }

    /// Same property-list value (both nil counts as the same).
    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?):
            guard let object = left as AnyObject as? NSObject else { return false }
            return object.isEqual(right as AnyObject)
        default: return false
        }
    }
}

/// Where an app keeps its settings: UserDefaults in the apps, a dictionary in the tests.
protocol OrbitSettingsLocalStore: AnyObject {
    /// Values set on this device, by key (registered defaults are not values the user set).
    func explicitValues() -> [String: Any]
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

/// The app's own defaults domain, so registered defaults and the global domain are never synced.
final class OrbitUserDefaultsSettingsStore: OrbitSettingsLocalStore {
    let defaults: UserDefaults
    let domain: String?

    init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    func explicitValues() -> [String: Any] {
        if let domain, let values = defaults.persistentDomain(forName: domain) { return values }
        return [:]
    }

    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
}

/// Minimal surface of `NSUbiquitousKeyValueStore` for settings, so the rules can run against memory in tests.
protocol OrbitSettingsCloudStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: OrbitSettingsCloudStore {}

/// The sync rules, free of app state: one `run` reads the local values, this device's last synced entries and
/// iCloud's entries, then applies, publishes or records each setting.
struct OrbitSettingsSyncEngine {
    static let cloudKey = "orbit.settings.v1"
    /// This device's last synced entry per local key (in the local store, never synced).
    static let stateKey = "orbit.settingsSync.state.v1"
    /// iCloud allows 1 MB per app; settings stay far below, and a write that would come close is skipped.
    static let maxCloudBytes = 512 * 1024

    var settings: [OrbitSyncedSetting]
    var families: [OrbitSyncedSettingFamily]
    /// "iPhone", "iPad", "Mac": who last changed a setting, for diagnostics.
    var origin: String

    var isEmpty: Bool { settings.isEmpty && families.isEmpty }

    enum Decision: CustomStringConvertible {
        case keep
        /// Write this entry to iCloud (and remember it as synced).
        case publish(OrbitSettingEntry)
        /// Put iCloud's value into the local store (and remember the entry as synced).
        case apply(OrbitSettingEntry)
        /// The local value already matches: only remember the entry as synced.
        case record(OrbitSettingEntry)

        var description: String {
            switch self {
            case .keep: return "keep"
            case .publish(let entry): return "publish \(entry)"
            case .apply(let entry): return "apply \(entry)"
            case .record(let entry): return "record \(entry)"
            }
        }
    }

    /// The rules for one setting. `local` is this device's value (nil when unset), `synced` the entry this device
    /// last synced (nil if never), `cloud` iCloud's entry and `usable` whether a value from iCloud may be applied here.
    static func decide(local: Any?, synced: OrbitSettingEntry?, cloud: OrbitSettingEntry?, now: Double, origin: String,
                       usable: (Any) -> Bool) -> Decision {
        func canApply(_ entry: OrbitSettingEntry) -> Bool { entry.value.map(usable) ?? true }
        // A starting point at time 0: what this device had before it synced the setting. It is never published,
        // but any later local change counts as an edit.
        let baseline = OrbitSettingEntry(value: local, updatedAt: 0, origin: origin)
        guard let synced else {
            // Never synced on this device: iCloud's entry wins; a value iCloud doesn't have is uploaded.
            if let cloud {
                if OrbitSettingEntry.same(local, cloud.value) { return .record(cloud) }
                return canApply(cloud) ? .apply(cloud) : .record(baseline)
            }
            guard let local else { return .record(baseline) }
            return .publish(OrbitSettingEntry(value: local, updatedAt: now, origin: origin))
        }
        if !OrbitSettingEntry.same(local, synced.value) {
            // Edited here since the last sync: newer than anything this device has seen, even with a slow clock.
            let time = max(now, synced.updatedAt + 0.001, (cloud?.updatedAt ?? 0) + 0.001)
            return .publish(OrbitSettingEntry(value: local, updatedAt: time, origin: origin))
        }
        guard let cloud else { return synced.updatedAt > 0 ? .publish(synced) : .keep }   // iCloud lost it: put it back.
        if cloud.updatedAt > synced.updatedAt {
            if OrbitSettingEntry.same(local, cloud.value) { return .record(cloud) }
            return canApply(cloud) ? .apply(cloud) : .keep
        }
        if cloud.updatedAt < synced.updatedAt { return .publish(synced) }   // Another device wrote over it.
        return .keep
    }

    struct Outcome {
        var applied: [String] = []
        var published: [String] = []
        var wroteCloud = false
        /// The write was skipped because iCloud's settings would grow too large.
        var tooLarge = false
    }

    private struct Tracked {
        let cloudKey: String
        let localKey: String
        let kind: OrbitSettingKind
        let isUsable: @Sendable (Any) -> Bool
    }

    /// The settings to look at: the fixed ones plus every key of each family seen here, in the past or in iCloud.
    private func tracked(localValues: [String: Any], synced: [String: OrbitSettingEntry], cloud: [String: Any]) -> [Tracked] {
        var result = settings.map { Tracked(cloudKey: $0.cloudKey, localKey: $0.localKey, kind: $0.kind, isUsable: $0.isUsable) }
        for family in families {
            var suffixes = Set<String>()
            for key in localValues.keys where key.hasPrefix(family.localPrefix) { suffixes.insert(String(key.dropFirst(family.localPrefix.count))) }
            for key in synced.keys where key.hasPrefix(family.localPrefix) { suffixes.insert(String(key.dropFirst(family.localPrefix.count))) }
            for key in cloud.keys where key.hasPrefix(family.cloudPrefix) { suffixes.insert(String(key.dropFirst(family.cloudPrefix.count))) }
            for suffix in suffixes.sorted() where !suffix.isEmpty && !family.excludedSuffixes.contains(suffix) {
                result.append(Tracked(cloudKey: family.cloudPrefix + suffix, localKey: family.localPrefix + suffix, kind: family.kind, isUsable: { _ in true }))
            }
        }
        return result
    }

    /// One sync pass. Writes to iCloud and to the local store only when something changed.
    @discardableResult
    func run(local: OrbitSettingsLocalStore, cloud: OrbitSettingsCloudStore, now: Double) -> Outcome {
        var outcome = Outcome()
        guard !isEmpty else { return outcome }
        let localValues = local.explicitValues()
        let syncedBefore = (localValues[Self.stateKey] as? [String: Any] ?? [:]).compactMapValues(OrbitSettingEntry.init(plist:))
        var synced = syncedBefore
        let cloudRaw = cloud.object(forKey: Self.cloudKey) as? [String: Any] ?? [:]
        var cloudOut = cloudRaw
        var syncedChanged = false

        for item in tracked(localValues: localValues, synced: synced, cloud: cloudRaw) {
            let localValue = localValues[item.localKey]
            // A local value of another type than expected is left alone (never published, never overwritten).
            if let localValue, !item.kind.accepts(localValue) { continue }
            let decision = Self.decide(local: localValue, synced: synced[item.localKey],
                                       cloud: OrbitSettingEntry(plist: cloudRaw[item.cloudKey]), now: now, origin: origin,
                                       usable: { item.kind.accepts($0) && item.isUsable($0) })
            switch decision {
            case .keep:
                continue
            case .publish(let entry):
                cloudOut[item.cloudKey] = entry.plist
                synced[item.localKey] = entry
                outcome.published.append(item.localKey)
            case .apply(let entry):
                if let value = entry.value { local.set(value, forKey: item.localKey) } else { local.removeObject(forKey: item.localKey) }
                synced[item.localKey] = entry
                outcome.applied.append(item.localKey)
            case .record(let entry):
                synced[item.localKey] = entry
            }
            syncedChanged = true
        }

        if !outcome.published.isEmpty {
            let size = (try? PropertyListSerialization.data(fromPropertyList: cloudOut, format: .binary, options: 0).count) ?? Int.max
            if size <= Self.maxCloudBytes {
                cloud.set(cloudOut, forKey: Self.cloudKey)
                cloud.synchronize()
                outcome.wroteCloud = true
            } else {
                // Leave these settings unsynced (and unrecorded) rather than fill the user's iCloud.
                outcome.tooLarge = true
                for key in outcome.published { synced[key] = syncedBefore[key] }
                outcome.published = []
            }
        }
        if syncedChanged { local.set(synced.mapValues(\.plist), forKey: Self.stateKey) }
        return outcome
    }

    /// Takes the current local values of `keys` as already synced, without publishing them: for values this app
    /// changed on its own (Orbit Pro lockdown after a refund), which other devices must not receive.
    func adoptLocalValues(forKeys keys: [String], local: OrbitSettingsLocalStore) {
        let localValues = local.explicitValues()
        var synced = (localValues[Self.stateKey] as? [String: Any] ?? [:]).compactMapValues(OrbitSettingEntry.init(plist:))
        var changed = false
        for key in keys {
            guard let entry = synced[key], !OrbitSettingEntry.same(entry.value, localValues[key]) else { continue }
            synced[key] = OrbitSettingEntry(value: localValues[key], updatedAt: entry.updatedAt, origin: entry.origin)
            changed = true
        }
        if changed { local.set(synced.mapValues(\.plist), forKey: Self.stateKey) }
    }

    /// Forgets what this device synced, so the next pass joins iCloud afresh (iCloud's entries win).
    static func forgetSyncedState(local: OrbitSettingsLocalStore) {
        local.removeObject(forKey: stateKey)
    }
}

/// Runs the engine in the app: after launch, when the app becomes active, when iCloud reports a change from
/// another device and shortly after a setting changes here.
@MainActor
final class OrbitSettingsSync {
    static let shared = OrbitSettingsSync()
    /// Posted on the main thread after values from iCloud were written into UserDefaults; `userInfo["keys"]`
    /// lists their local keys. `@AppStorage` views update by themselves; models that copy a value read it again.
    static let appliedNotification = Notification.Name("OrbitSettingsSyncApplied")

    private(set) var engine = OrbitSettingsSyncEngine(settings: [], families: [], origin: "")
    private let local = OrbitUserDefaultsSettingsStore()
    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?
    private var isRunning = false

    private init() {}

    /// Starts syncing `settings` and `families` (once per launch).
    func start(settings: [OrbitSyncedSetting], families: [OrbitSyncedSettingFamily], origin: String) {
        guard observers.isEmpty else { return }
        engine = OrbitSettingsSyncEngine(settings: settings, families: families, origin: origin)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                            object: NSUbiquitousKeyValueStore.default, queue: nil) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in self?.cloudChanged(reason: reason) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.scheduleSync() }
            } else {
                Task { @MainActor in self?.scheduleSync() }
            }
        })
        observers.append(center.addObserver(forName: OrbitCloudSyncSwitch.changedNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.switchChanged() }
        })
        appBecameActive()
    }

    /// Asks iCloud for news and syncs now.
    func appBecameActive() {
        guard OrbitCloudSyncSwitch.isOn, !engine.isEmpty else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        syncNow()
    }

    /// Syncs about a second from now; changes made meanwhile go along in the same pass.
    func scheduleSync() {
        guard !isRunning, scheduled == nil, OrbitCloudSyncSwitch.isOn, !engine.isEmpty else { return }
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            self.scheduled = nil
            self.syncNow()
        }
    }

    func syncNow() {
        guard !isRunning, OrbitCloudSyncSwitch.isOn, !engine.isEmpty else { return }
        isRunning = true
        let outcome = engine.run(local: local, cloud: NSUbiquitousKeyValueStore.default, now: Date().timeIntervalSince1970)
        isRunning = false
        if outcome.tooLarge { print("Orbit settings sync: skipped a write, iCloud settings would exceed \(OrbitSettingsSyncEngine.maxCloudBytes) bytes") }
        guard !outcome.applied.isEmpty else { return }
        NotificationCenter.default.post(name: Self.appliedNotification, object: nil, userInfo: ["keys": outcome.applied])
    }

    /// See `OrbitSettingsSyncEngine.adoptLocalValues`.
    func adoptLocalValues(forKeys keys: [String]) {
        isRunning = true
        engine.adoptLocalValues(forKeys: keys, local: local)
        isRunning = false
    }

    private func cloudChanged(reason: Int?) {
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // Another iCloud account: its settings win, as on a new device.
            OrbitSettingsSyncEngine.forgetSyncedState(local: local)
        } else if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            print("Orbit settings sync: iCloud key-value storage is over its quota")
        }
        syncNow()
    }

    private func switchChanged() {
        guard OrbitCloudSyncSwitch.isOn else {
            scheduled?.cancel()
            scheduled = nil
            return
        }
        // Back on: join iCloud afresh, so changes made on other devices meanwhile win over old local state.
        OrbitSettingsSyncEngine.forgetSyncedState(local: local)
        appBecameActive()
    }
}
