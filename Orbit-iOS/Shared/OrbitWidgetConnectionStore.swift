import AppIntents
import CryptoKit
import Darwin
import Foundation
import Security
import WidgetKit

struct OrbitWidgetConnection: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var certificateSHA256: String
    var macAddress: String? = nil
    var broadcastAddress: String? = nil
    var subnetMask: String? = nil
    var wolPort: Int? = nil
    var lastKnownIPv4: String? = nil
}

/// Shared connection and credential store backed by the App Group container and Keychain.
/// Supports read-only telemetry tokens for timeline polling as well as authenticated
/// power actions (Wake-on-LAN, Shutdown, Sleep, Restart) triggered by interactive
/// Home Screen Widgets, Control Center Widgets, and Siri Shortcuts.
enum OrbitWidgetConnectionStore {
    private static let service = "Orbit.WidgetReadOnly.v1"
    private static let controlService = "Orbit.WidgetControl.v1"
    private static let profilesKey = "Orbit.WidgetConnections.v1"
    private static let selectedKey = "Orbit.WidgetDefaultPC.v1"
    private static let powerStatusKey = "Orbit.WidgetPowerStatus.v1"
    private static let powerStatusTimeKey = "Orbit.WidgetPowerStatusTime.v1"

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

    private static var fallbackDefaults: UserDefaults {
        (try? defaults()) ?? .standard
    }

    /// Called after this process saves, renames or removes a PC or changes the default PC. Orbit sets
    /// it to refresh the PC names Siri understands (App Shortcut parameters); the widgets and the
    /// watch leave it nil.
    nonisolated(unsafe) static var connectionsDidChange: (() -> Void)?

    static func connections() -> [OrbitWidgetConnection] {
        guard let data = fallbackDefaults.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([OrbitWidgetConnection].self, from: data)) ?? []
    }

    static func defaultConnection() -> OrbitWidgetConnection? {
        let entries = connections()
        let selected = fallbackDefaults.string(forKey: selectedKey)
        return entries.first { $0.id == selected } ?? entries.first
    }

    static func save(
        id: String,
        name: String,
        host: String,
        port: Int,
        readOnlyToken: String,
        certificateSHA256: String,
        controlToken: String? = nil,
        macAddress: String? = nil,
        broadcastAddress: String? = nil,
        subnetMask: String? = nil,
        wolPort: Int? = nil,
        lastKnownIPv4: String? = nil
    ) throws {
        let fingerprint = certificateSHA256.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !id.isEmpty, !host.isEmpty, !host.contains("/"), !host.contains(":"), (1...65535).contains(port),
              !readOnlyToken.isEmpty, !readOnlyToken.contains(where: { $0.isNewline }),
              fingerprint.count == 64, fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw StoreError.invalidConnection }
        let storeDefaults = try defaults()
        try saveKeychainItem(value: readOnlyToken, id: id, serviceName: service)
        if let controlToken, !controlToken.isEmpty, !controlToken.contains(where: { $0.isNewline }) {
            try? saveKeychainItem(value: controlToken, id: id, serviceName: controlService)
        }
        let existing = connections().first { $0.id == id }
        let entry = OrbitWidgetConnection(
            id: id,
            name: String(name.prefix(80)),
            host: host,
            port: port,
            certificateSHA256: fingerprint,
            macAddress: macAddress ?? existing?.macAddress,
            broadcastAddress: broadcastAddress ?? existing?.broadcastAddress,
            subnetMask: subnetMask ?? existing?.subnetMask,
            wolPort: wolPort ?? existing?.wolPort ?? 9,
            lastKnownIPv4: lastKnownIPv4 ?? existing?.lastKnownIPv4
        )
        var entries = connections()
        entries.removeAll { $0.id == id }
        entries.append(entry)
        let encoded = try JSONEncoder().encode(entries)
        storeDefaults.set(encoded, forKey: profilesKey)
        UserDefaults.standard.set(encoded, forKey: profilesKey)
        if storeDefaults.string(forKey: selectedKey) == nil {
            storeDefaults.set(id, forKey: selectedKey)
            UserDefaults.standard.set(id, forKey: selectedKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
        connectionsDidChange?()
    }

    static func syncPowerProfile(
        id: String,
        name: String,
        host: String,
        port: Int,
        certificateSHA256: String,
        controlToken: String,
        macAddress: String,
        broadcastAddress: String,
        subnetMask: String,
        wolPort: Int,
        lastKnownIPv4: String?
    ) {
        let fingerprint = certificateSHA256.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !id.isEmpty, !host.isEmpty else { return }
        if !controlToken.isEmpty {
            try? saveKeychainItem(value: controlToken, id: id, serviceName: controlService)
        }
        var entries = connections()
        let existing = entries.first { $0.id == id }
        let entry = OrbitWidgetConnection(
            id: id,
            name: String(name.prefix(80)),
            host: host,
            port: port,
            certificateSHA256: fingerprint.count == 64 ? fingerprint : (existing?.certificateSHA256 ?? ""),
            macAddress: macAddress.isEmpty ? existing?.macAddress : macAddress,
            broadcastAddress: broadcastAddress.isEmpty ? existing?.broadcastAddress : broadcastAddress,
            subnetMask: subnetMask.isEmpty ? (existing?.subnetMask ?? "255.255.255.0") : subnetMask,
            wolPort: (1...65535).contains(wolPort) ? wolPort : (existing?.wolPort ?? 9),
            lastKnownIPv4: (lastKnownIPv4?.isEmpty == false) ? lastKnownIPv4 : existing?.lastKnownIPv4
        )
        entries.removeAll { $0.id == id }
        entries.append(entry)
        if let encoded = try? JSONEncoder().encode(entries) {
            (try? defaults())?.set(encoded, forKey: profilesKey)
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
        connectionsDidChange?()
    }

    static func setDefault(id: String) throws {
        UserDefaults.standard.set(id, forKey: selectedKey)
        try defaults().set(id, forKey: selectedKey)
        WidgetCenter.shared.reloadAllTimelines()
        connectionsDidChange?()
    }

    static func remove(id: String) throws {
        let storeDefaults = try defaults()
        let status = SecItemDelete(try keychainQuery(id: id, serviceName: service) as CFDictionary)
        _ = SecItemDelete(try keychainQuery(id: id, serviceName: controlService) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.credential(status) }
        let remaining = try JSONEncoder().encode(connections().filter { $0.id != id })
        clearSnapshot(for: id)
        storeDefaults.set(remaining, forKey: profilesKey)
        UserDefaults.standard.set(remaining, forKey: profilesKey)
        if storeDefaults.string(forKey: selectedKey) == id { storeDefaults.removeObject(forKey: selectedKey) }
        WidgetCenter.shared.reloadAllTimelines()
        connectionsDidChange?()
    }

    static func readOnlyToken(for id: String) throws -> String {
        try readKeychainItem(id: id, serviceName: service)
    }

    static func controlToken(for id: String) throws -> String {
        if let shared = try? readKeychainItem(id: id, serviceName: controlService), !shared.isEmpty {
            return shared
        }
        // Fallback to private app keychain when invoked in-process (e.g. Siri / App Shortcuts)
        let appQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "OrbitSavedPC",
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(appQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        throw StoreError.credential(errSecItemNotFound)
    }

    // MARK: Snapshot cache shared with the widgets

    private static let snapshotPrefix = "Orbit.WidgetSnapshot.v1."
    private static let snapshotReloadKey = "Orbit.WidgetSnapshotReload.v1"

    /// The app writes the latest `/api/widget/status`-shaped reading here after every poll, so a
    /// widget timeline can render immediately from what the app just saw instead of opening its
    /// own connection (which also fails when the PC is asleep or Local Network access is pending).
    static func cacheSnapshot(_ json: Data, for id: String, reloadInterval: TimeInterval = 60) {
        guard !id.isEmpty, json.count <= 64 * 1024 else { return }
        let store = fallbackDefaults
        store.set(json, forKey: snapshotPrefix + id)
        store.set(Date().timeIntervalSince1970, forKey: snapshotPrefix + id + ".at")
        let lastReload = store.double(forKey: snapshotReloadKey)
        guard Date().timeIntervalSince1970 - lastReload >= reloadInterval else { return }
        store.set(Date().timeIntervalSince1970, forKey: snapshotReloadKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Cached reading for a PC if it is younger than `maxAge`.
    static func cachedSnapshot(for id: String, maxAge: TimeInterval) -> Data? {
        let store = fallbackDefaults
        let written = store.double(forKey: snapshotPrefix + id + ".at")
        guard written > 0, Date().timeIntervalSince1970 - written <= maxAge else { return nil }
        return store.data(forKey: snapshotPrefix + id)
    }

    static func clearSnapshot(for id: String) {
        let store = fallbackDefaults
        store.removeObject(forKey: snapshotPrefix + id)
        store.removeObject(forKey: snapshotPrefix + id + ".at")
    }

    static func recordPowerFeedback(_ message: String) {
        let store = fallbackDefaults
        store.set(message, forKey: powerStatusKey)
        store.set(Date().timeIntervalSince1970, forKey: powerStatusTimeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func recentPowerFeedback() -> String? {
        let store = fallbackDefaults
        let timestamp = store.double(forKey: powerStatusTimeKey)
        guard timestamp > 0, Date().timeIntervalSince1970 - timestamp < 45 else { return nil }
        return store.string(forKey: powerStatusKey)
    }

    private static func saveKeychainItem(value: String, id: String, serviceName: String) throws {
        let query = try keychainQuery(id: id, serviceName: serviceName)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.credential(status) }
    }

    private static func readKeychainItem(id: String, serviceName: String) throws -> String {
        var query = try keychainQuery(id: id, serviceName: serviceName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw StoreError.credential(status)
        }
        return token
    }

    private static func keychainQuery(id: String, serviceName: String) throws -> [String: Any] {
        guard let group else { throw StoreError.unavailable }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id,
            kSecAttrAccessGroup as String: group
        ]
    }
}

// The Send to PC share extension compiles this file for the store above only
// (SWIFT_ACTIVE_COMPILATION_CONDITIONS ORBIT_SHARE_EXTENSION): no power service and no App Intents there.
#if !ORBIT_SHARE_EXTENSION

// MARK: - Background Power Service for Widgets, Control Center & Siri

enum OrbitWidgetPowerService {
    private final class PinnedTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        let fingerprint: String
        init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }

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

    private static func resolveConnection(id: String?) -> OrbitWidgetConnection? {
        if let id, let match = OrbitWidgetConnectionStore.connections().first(where: { $0.id == id }) {
            return match
        }
        return OrbitWidgetConnectionStore.defaultConnection()
    }

    static func wakePC(id: String? = nil) async throws -> String {
        guard let connection = resolveConnection(id: id) else {
            OrbitWidgetConnectionStore.recordPowerFeedback("Pair your PC in Orbit first")
            return "Pair your PC in Orbit first."
        }
        let macRaw = (connection.macAddress ?? UserDefaults.standard.string(forKey: "pcMAC") ?? "").filter { !":-. ".contains($0) }
        guard macRaw.count == 12 else {
            OrbitWidgetConnectionStore.recordPowerFeedback("Open Orbit once while PC is on to save MAC")
            return "Connect to \(connection.name) once in Orbit to save its Wake-on-LAN MAC address."
        }
        let chars = Array(macRaw)
        var macBytes: [UInt8] = []
        for i in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else {
                return "Invalid MAC address for \(connection.name)."
            }
            macBytes.append(byte)
        }
        let packet = Array(repeating: UInt8(255), count: 6) + Array(repeating: macBytes, count: 16).flatMap { $0 }
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return "Could not open UDP socket." }
        defer { Darwin.close(sock) }
        var broadcastEnabled: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnabled, socklen_t(MemoryLayout<Int32>.size))

        let port = UInt16((1...65535).contains(connection.wolPort ?? 9) ? (connection.wolPort ?? 9) : 9)
        let ipv4 = ipv4Address(host: connection.host, fallback: connection.lastKnownIPv4 ?? "")
        let calculatedBroadcast = broadcastAddress(ip: ipv4, mask: connection.subnetMask ?? "255.255.255.0")
        let targets = Set([connection.broadcastAddress ?? "", calculatedBroadcast, ipv4, "255.255.255.255"]).filter { !$0.isEmpty }

        var sent = false
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            for _ in 0..<3 {
                let written = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(sock, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || (written == packet.count)
            }
        }
        let message = sent ? "Wake packet sent to \(connection.name)" : "Could not send Wake packet"
        OrbitWidgetConnectionStore.recordPowerFeedback(message)
        return message
    }

    static func sendPowerAction(_ action: String, id: String? = nil) async throws -> String {
        guard ["shutdown", "sleep", "restart", "lock"].contains(action) else {
            return "Unsupported action."
        }
        guard let connection = resolveConnection(id: id) else {
            OrbitWidgetConnectionStore.recordPowerFeedback("Pair your PC in Orbit first")
            return "Pair your PC in Orbit first."
        }
        guard let token = try? OrbitWidgetConnectionStore.controlToken(for: connection.id),
              !token.isEmpty,
              connection.certificateSHA256.count == 64 else {
            OrbitWidgetConnectionStore.recordPowerFeedback("Open Orbit to refresh widget control")
            return "Open Orbit once to authorize widget power control for \(connection.name)."
        }

        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = connection.host
        parts.port = connection.port
        parts.path = "/api/action/\(action)"
        guard let url = parts.url else { return "Invalid PC address." }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config, delegate: PinnedTLSDelegate(fingerprint: connection.certificateSHA256), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let label = switch action {
                case "shutdown": "Shutting down"
                case "sleep": "Sleeping"
                case "lock": "Locked"
                default: "Restarting"
                }
                // A PC with Windows' 30-second warning says how long it waits; Orbit can still cancel.
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let delay = (json?["countdownSeconds"] as? NSNumber)?.intValue ?? 0
                let message = delay > 0
                    ? "\(label) \(connection.name) in \(delay) seconds. Open Orbit to cancel."
                    : "\(label) \(connection.name)"
                OrbitWidgetConnectionStore.recordPowerFeedback(message)
                return message
            } else {
                let message = "\(connection.name) rejected \(action)"
                OrbitWidgetConnectionStore.recordPowerFeedback(message)
                return message
            }
        } catch {
            let message = "\(connection.name) is offline or unreachable"
            OrbitWidgetConnectionStore.recordPowerFeedback(message)
            return message
        }
    }

    private static func ipv4Address(host: String, fallback: String) -> String {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return host }
        return inet_pton(AF_INET, fallback, &addr) == 1 ? fallback : ""
    }

    private static func broadcastAddress(ip: String, mask: String) -> String {
        var addr = in_addr(), subnet = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1, inet_pton(AF_INET, mask, &subnet) == 1 else { return "" }
        var broadcast = in_addr(s_addr: addr.s_addr | ~subnet.s_addr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }
}

// The Pro power intents (Power On, Shut Down, Sleep, Restart) live in OrbitPowerIntents.swift, compiled
// into the app and the watch only: the widget extension and Control Center use their own types
// (OrbitWidgets/OrbitWidgetPowerIntents.swift). See that file for why.

#endif // !ORBIT_SHARE_EXTENSION
