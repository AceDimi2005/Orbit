import Foundation
import Security
import UserNotifications

/// What the iPhone app and its Notification Service Extension share for PC alerts, all in the App Group:
///
/// - `deviceID` (App Group defaults `Orbit.PushDeviceID.v1`): one random uppercase UUID per install. The
///   PC uses it as the device's name at the relay and as the AES-GCM associated data.
/// - One 32-byte key per (this device, PC) pair in the App Group keychain: service `Orbit.PushKey.v1`,
///   account = the PC's profile id, `AfterFirstUnlockThisDeviceOnly` so the extension can read it while
///   the iPhone is locked (after the first unlock since boot).
/// - The highest event id shown for each PC (App Group defaults `Orbit.DeliveredEvents.v1`, profile id →
///   id), written by the extension and by the app's own poller, so an alert never shows twice.
enum OrbitPushStore {
    static let keyService = "Orbit.PushKey.v1"
    static let deviceIDKey = "Orbit.PushDeviceID.v1"
    static let deliveredKey = "Orbit.DeliveredEvents.v1"

    static var appGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String,
              value.hasPrefix("group."), !value.contains("$(") else { return nil }
        return value
    }

    /// App Group defaults, or nil when the group is missing from the signature (then nothing is shared).
    static var sharedDefaults: UserDefaults? {
        guard let appGroup, FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    // MARK: Device ID

    /// This install's device ID. The app creates it; the extension only reads it (`create: false`).
    static func deviceID(create: Bool) -> String? {
        let store = sharedDefaults ?? (create ? .standard : nil)
        if let existing = store?.string(forKey: deviceIDKey), isValidDeviceID(existing) { return existing }
        guard create, let store else { return nil }
        let fresh = UUID().uuidString
        store.set(fresh, forKey: deviceIDKey)
        return fresh
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

    // MARK: Delivered events

    static func deliveredEventID(for pcID: String) -> Int {
        let map = (sharedDefaults ?? .standard).dictionary(forKey: deliveredKey) as? [String: Int]
        return map?[pcID] ?? 0
    }

    /// Returns false when the id was already recorded (the alert was shown before).
    @discardableResult
    static func recordDelivered(_ eventID: Int, for pcID: String) -> Bool {
        guard eventID > 0, !pcID.isEmpty else { return true }
        let store = sharedDefaults ?? .standard
        var map = (store.dictionary(forKey: deliveredKey) as? [String: Int]) ?? [:]
        guard eventID > (map[pcID] ?? 0) else { return false }
        map[pcID] = eventID
        store.set(map, forKey: deliveredKey)
        return true
    }

    /// For a PC whose event log was recreated (ids start again from 1).
    static func resetDelivered(for pcID: String, to eventID: Int) {
        let store = sharedDefaults ?? .standard
        var map = (store.dictionary(forKey: deliveredKey) as? [String: Int]) ?? [:]
        map[pcID] = max(0, eventID)
        store.set(map, forKey: deliveredKey)
    }

    static func forgetDelivered(for pcID: String) {
        let store = sharedDefaults ?? .standard
        var map = (store.dictionary(forKey: deliveredKey) as? [String: Int]) ?? [:]
        map.removeValue(forKey: pcID)
        store.set(map, forKey: deliveredKey)
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
    static func decrypted(_ original: UNNotificationContent) -> UNMutableNotificationContent? {
        guard let ciphertext = original.userInfo["o"] as? String,
              let deviceID = OrbitPushStore.deviceID(create: false) else { return nil }
        let keys = OrbitPushStore.allKeys()
        guard !keys.isEmpty, let opened = OrbitPushCrypto.open(ciphertext, keys: keys, deviceID: deviceID),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return nil }
        let message = opened.message
        content.title = message.title
        content.body = message.body
        if !message.pc.isEmpty { content.threadIdentifier = message.pc }
        content.categoryIdentifier = OrbitEventFeed.notificationCategory(for: message.kind)
        content.userInfo["link"] = message.link
        content.userInfo["pcID"] = opened.id
        content.userInfo["eventID"] = message.id
        content.userInfo["kind"] = message.kind
        content.userInfo.removeValue(forKey: "o")
        // The app's own poller may have shown this event already (it records the same ids). An
        // extension can't hide a push, so this copy arrives silently and the app removes it later.
        if message.id > 0, !OrbitPushStore.recordDelivered(message.id, for: opened.id) {
            content.userInfo[duplicateKey] = true
            content.sound = nil
            content.interruptionLevel = .passive
        }
        return content
    }
}
