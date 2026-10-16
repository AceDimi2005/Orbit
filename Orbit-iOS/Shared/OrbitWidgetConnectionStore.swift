import Foundation
import Security
import WidgetKit

struct OrbitWidgetConnection: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var certificateSHA256: String
}

/// Only widget-scoped, read-only credentials are shared. The control token never
/// leaves the app's private Keychain. App Groups supply this Keychain access group.
enum OrbitWidgetConnectionStore {
    private static let service = "Orbit.WidgetReadOnly.v1"
    private static let profilesKey = "Orbit.WidgetConnections.v1"
    private static let selectedKey = "Orbit.WidgetDefaultPC.v1"
    private static var group: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String,
              value.hasPrefix("group."), !value.contains("$(") else { return nil }
        return value
    }
    enum StoreError: LocalizedError {
        case unavailable, invalidConnection, credential(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Widget sharing is unavailable. Enable the same App Group for Orbit and OrbitWidgets in Xcode."
            case .invalidConnection: "The PC's encrypted widget connection is incomplete. Pair the PC again in Orbit."
            case .credential: "iOS could not save widget access securely. Unlock the iPhone and check the App Group signing settings."
            }
        }
    }
    private static func defaults() throws -> UserDefaults {
        guard let group, FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group) else { throw StoreError.unavailable }
        return defaults
    }
    static func connections() -> [OrbitWidgetConnection] {
        guard let data = try? defaults().data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([OrbitWidgetConnection].self, from: data)) ?? []
    }
    static func defaultConnection() -> OrbitWidgetConnection? {
        let entries = connections()
        let selected = try? defaults().string(forKey: selectedKey)
        return entries.first { $0.id == selected } ?? entries.first
    }
    static func save(id: String, name: String, host: String, port: Int, readOnlyToken: String, certificateSHA256: String) throws {
        let fingerprint = certificateSHA256.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !id.isEmpty, !host.isEmpty, !host.contains("/"), !host.contains(":"), (1...65535).contains(port),
              !readOnlyToken.isEmpty, !readOnlyToken.contains(where: { $0.isNewline }),
              fingerprint.count == 64, fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw StoreError.invalidConnection }
        let defaults = try defaults()
        let query = try keychainQuery(id: id)
        let value = Data(readOnlyToken.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = value
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.credential(status) }
        let entry = OrbitWidgetConnection(id: id, name: String(name.prefix(80)), host: host, port: port, certificateSHA256: fingerprint)
        var entries = connections()
        entries.removeAll { $0.id == id }; entries.append(entry)
        defaults.set(try JSONEncoder().encode(entries), forKey: profilesKey)
        if defaults.string(forKey: selectedKey) == nil { defaults.set(id, forKey: selectedKey) }
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func setDefault(id: String) throws {
        try defaults().set(id, forKey: selectedKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func remove(id: String) throws {
        let defaults = try defaults()
        let status = SecItemDelete(try keychainQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.credential(status) }
        defaults.set(try JSONEncoder().encode(connections().filter { $0.id != id }), forKey: profilesKey)
        if defaults.string(forKey: selectedKey) == id { defaults.removeObject(forKey: selectedKey) }
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func readOnlyToken(for id: String) throws -> String {
        var query = try keychainQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw StoreError.credential(status) }
        return token
    }
    private static func keychainQuery(id: String) throws -> [String: Any] {
        guard let group else { throw StoreError.unavailable }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: id, kSecAttrAccessGroup as String: group]
    }
}
