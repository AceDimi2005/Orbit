import Foundation
import Security
import UserNotifications

/// What the iPhone app and its Notification Service Extension share for PC alerts, all in the App Group:
///
/// - `deviceID`: one random uppercase UUID per install, in the App Group keychain (service
///   `Orbit.PushDeviceID.v1`, `AfterFirstUnlockThisDeviceOnly`). The PC uses it as the device's name at the
///   relay and as the AES-GCM associated data. It lives in the keychain rather than in defaults so that two
///   devices restored from one backup never share it (the keys below never leave the device either).
/// - One 32-byte key per (this device, PC) pair in the App Group keychain: service `Orbit.PushKey.v1`,
///   account = the PC's profile id, `AfterFirstUnlockThisDeviceOnly` so the extension can read it while
///   the iPhone is locked (after the first unlock since boot).
/// - The event ids already shown for each PC (`OrbitDeliveredStore`, a file in the App Group container),
///   written by the extension and by the app's own poller, so an alert never shows twice.
/// - The PCs' names (App Group defaults `Orbit.PushPCNames.v1`, profile id → name) for the subtitle the
///   extension shows; the app writes them when it registers with a PC.
enum OrbitPushStore {
    static let keyService = "Orbit.PushKey.v1"
    static let deviceIDKey = "Orbit.PushDeviceID.v1"
    static let pcNamesKey = "Orbit.PushPCNames.v1"
    /// Builds before the delivered store kept `profile id → highest id` here.
    static let legacyDeliveredKey = "Orbit.DeliveredEvents.v1"

    static var appGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String,
              value.hasPrefix("group."), !value.contains("$(") else { return nil }
        return value
    }

    static var containerURL: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// App Group defaults, or nil when the group is missing from the signature (then nothing is shared).
    static var sharedDefaults: UserDefaults? {
        guard let appGroup, containerURL != nil else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    // MARK: Device ID

    private static func deviceIDQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceIDKey,
            kSecAttrAccount as String: "deviceID"
        ]
        if let appGroup { query[kSecAttrAccessGroup as String] = appGroup }
        return query
    }

    private static func storedDeviceID() -> String? {
        var query = deviceIDQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), isValidDeviceID(value) else { return nil }
        return value
    }

    private static func storeDeviceID(_ value: String) -> Bool {
        let query = deviceIDQuery()
        _ = SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// This install's device ID. The app creates it; the extension only reads it (`create: false`).
    /// Returns nil when iOS can't store it (then nothing is registered: the extension couldn't open alerts).
    static func deviceID(create: Bool) -> String? {
        if let stored = storedDeviceID() { return stored }
        // Earlier builds kept the ID in App Group defaults, which travel with backups.
        let legacy = sharedDefaults?.string(forKey: deviceIDKey).flatMap { isValidDeviceID($0) ? $0 : nil }
        guard create else { return legacy }
        // Keys are ThisDeviceOnly: if they're here, so was that ID (an update, not a restored backup), and
        // the PCs know this device by it. Without keys it may belong to the device the backup came from.
        let value = legacy.flatMap { keyAccounts().isEmpty ? nil : $0 } ?? UUID().uuidString
        guard storeDeviceID(value) else { return nil }
        sharedDefaults?.removeObject(forKey: deviceIDKey)
        return value
    }

    /// The relay's rule: 1–64 characters `[A-Za-z0-9][A-Za-z0-9._-]*`.
    static func isValidDeviceID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    // MARK: Keys

    enum KeyError: LocalizedError {
        case unavailable, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Orbit can't share alert keys with its notification extension. Reinstall Orbit or check the App Group in Xcode."
            case .keychain(let status): return "iOS couldn't store the alert key securely (error \(status)). Unlock your iPhone and try again."
            }
        }
    }

    private static func keyQuery(_ pcID: String?) throws -> [String: Any] {
        guard let appGroup else { throw KeyError.unavailable }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccessGroup as String: appGroup
        ]
        if let pcID { query[kSecAttrAccount as String] = pcID }
        return query
    }

    static func key(for pcID: String) -> Data? {
        guard !pcID.isEmpty, var query = try? keyQuery(pcID) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == OrbitPushCrypto.keyByteCount else { return nil }
        return data
    }

    /// The PC's key, created (and stored) on first use.
    static func ensureKey(for pcID: String) throws -> Data {
        if let existing = key(for: pcID) { return existing }
        let key = OrbitPushCrypto.newKey()
        let query = try keyQuery(pcID)
        _ = SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        return key
    }

    static func removeKey(for pcID: String) {
        guard !pcID.isEmpty, let query = try? keyQuery(pcID) else { return }
        SecItemDelete(query as CFDictionary)
    }

    /// The profile ids that have a key.
    static func keyAccounts() -> [String] {
        guard var query = try? keyQuery(nil) else { return [] }
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { !$0.isEmpty }
    }

    /// Every stored key, for the extension to try one after another.
    static func allKeys() -> [(id: String, key: Data)] {
        keyAccounts().compactMap { account in key(for: account).map { (account, $0) } }
    }

    // MARK: PC names (for the extension's subtitle)

    static func pcName(for pcID: String) -> String? {
        let name = (sharedDefaults?.dictionary(forKey: pcNamesKey) as? [String: String])?[pcID]
        return name?.isEmpty == false ? name : nil
    }

    static func setPCName(_ name: String?, for pcID: String) {
        guard let defaults = sharedDefaults, !pcID.isEmpty else { return }
        var map = (defaults.dictionary(forKey: pcNamesKey) as? [String: String]) ?? [:]
        guard map[pcID] != name else { return }
        map[pcID] = name
        defaults.set(map, forKey: pcNamesKey)
    }

    // MARK: Delivered events

    static var deliveredStore: OrbitDeliveredStore {
        let base = containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = containerURL == nil ? base.appendingPathComponent("Orbit", isDirectory: true)
            : base.appendingPathComponent("Library/Application Support/Orbit", isDirectory: true)
        return OrbitDeliveredStore(fileURL: directory.appendingPathComponent("DeliveredEvents.v2.json"))
    }

    static func delivered(for pcID: String) -> OrbitDeliveredIDs {
        deliveredStore.ids(for: pcID)
    }

    /// Returns false when the event was already shown.
    @discardableResult
    static func recordDelivered(_ eventID: Int, for pcID: String) -> Bool {
        deliveredStore.record(eventID, for: pcID)
    }

    /// For a PC whose event log was recreated (ids start again from 1); see `OrbitDeliveredStore.reconcile`.
    static func reconcileDelivered(for pcID: String, latestID: Int, floor: Int, pollStartedAt: Date, logRecreated: Bool) {
        deliveredStore.reconcile(pcID, latestID: latestID, floor: floor, pollStartedAt: pollStartedAt, logRecreated: logRecreated)
    }

    static func forgetDelivered(for pcID: String) {
        deliveredStore.forget(pcID)
        sharedDefaults?.removeObject(forKey: legacyDeliveredKey)
    }
}

// MARK: - What a pushed alert shows

/// Turns the relay's generic push ("Orbit — New alert from your PC", ciphertext in `o`) into the PC's real
/// alert. Used by the Notification Service Extension, and by the app's Debug self-test so the same code
/// runs against the real keychain in the Simulator (where `simctl push` skips service extensions).
enum OrbitPushContent {
    /// Set on a push whose event the app's poller already showed: it arrives silently and the app removes it.
    static let duplicateKey = "orbitDuplicate"

    /// The decrypted alert, or the generic text when no stored key opens it.
    static func process(_ original: UNNotificationContent) -> UNMutableNotificationContent {
        decrypted(original) ?? fallback(original)
    }

    static func fallback(_ original: UNNotificationContent) -> UNMutableNotificationContent {
        let content = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = OrbitPushCrypto.fallbackTitle
        content.body = OrbitPushCrypto.fallbackBody
        content.userInfo["link"] = OrbitPushCrypto.defaultLink
        content.userInfo.removeValue(forKey: "o")
        return content
    }

    /// The alert with its real text, or nil when no stored key opens it.
    static func decrypted(_ original: UNNotificationContent, now: Date = Date()) -> UNMutableNotificationContent? {
        guard let ciphertext = original.userInfo["o"] as? String,
              let deviceID = OrbitPushStore.deviceID(create: false) else { return nil }
        let keys = OrbitPushStore.allKeys()
        guard !keys.isEmpty,
              let outcome = OrbitPushCrypto.receive(ciphertext, keys: keys, deviceID: deviceID,
                                                    record: { OrbitPushStore.recordDelivered($0, for: $1) }),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return nil }
        let message = outcome.message
        let sentAt = message.timestamp > 0 ? Date(timeIntervalSince1970: message.timestamp) : nil
        content.title = message.title
        content.body = OrbitEventFeed.displayBody(message.body, date: sentAt, now: now)
        // Same grouping and subtitle as the alerts the app's poller posts for this PC.
        content.threadIdentifier = outcome.pcID
        content.subtitle = OrbitPushStore.pcName(for: outcome.pcID) ?? message.pc
        content.categoryIdentifier = OrbitEventFeed.notificationCategory(for: message.kind)
        if message.kind == "power.scheduled", let sentAt,
           now.timeIntervalSince(sentAt) > OrbitEventFeed.maximumPowerDelay + OrbitEventFeed.powerScheduledGrace {
            // Held by APNs past any countdown: a Cancel button could only fail.
            content.categoryIdentifier = OrbitEventFeed.eventCategory
        }
        content.userInfo["link"] = message.link
        content.userInfo["pcID"] = outcome.pcID
        content.userInfo["eventID"] = message.id
        content.userInfo["kind"] = message.kind
        content.userInfo.removeValue(forKey: "o")
        // The app's own poller showed this event already. An extension can't hide a push, so this copy
        // arrives silently and the app removes it later.
        if outcome.duplicate {
            content.userInfo[duplicateKey] = true
            content.sound = nil
            content.interruptionLevel = .passive
        }
        return content
    }
}
