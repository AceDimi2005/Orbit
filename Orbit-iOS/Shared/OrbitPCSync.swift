import Foundation
import Network

/// One saved PC as exchanged between Orbit on iPhone, Apple TV and Mac through iCloud
/// Key-Value Storage and the iPhone's local-network relay. The first thirteen fields are
/// exactly what the 4.x apps wrote; the optional ones arrived in 4.3 and decode as nil before.
struct OrbitSyncedPCItem: Codable, Equatable {
    var id: String
    var name: String
    var address: String
    var agentPort: Int
    var securePort: Int
    var certificateFingerprint: String
    var macAddress: String
    var subnetMask: String
    var broadcastAddress: String
    var wolPort: Int
    var lastKnownIPv4: String
    var apiToken: String
    var isSelected: Bool
    /// Bonjour `.local` name of the agent, kept beside the numeric address.
    var bonjourHost: String? = nil
    var autoCalcBroadcast: Bool? = nil
    /// Seconds since 1970 of the last edit on the device that published it; nil for legacy items.
    var updatedAt: Double? = nil
    /// Device that last edited the item ("iPhone", "Apple TV", "Mac").
    var origin: String? = nil
}

/// Minimal surface of `NSUbiquitousKeyValueStore`, so the merge logic can run against an
/// in-memory store in tests.
protocol OrbitSyncedKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: OrbitSyncedKeyValueStore {}

/// iCloud sync of saved PCs. Every device publishes the union of what iCloud holds and what it
/// has locally: the same PC (same agent certificate, or the same id) keeps the newer copy, a PC
/// removed on one device disappears everywhere once the removal is newer than the last edit,
/// and nothing is written when the merged result already matches iCloud, so devices never
/// bounce updates back and forth.
enum OrbitPCCloudSync {
    static let itemsKey = "orbit.syncedPCs.v1"
    static let removedKey = "orbit.syncedPCs.removed.v1"
    nonisolated(unsafe) static var store: OrbitSyncedKeyValueStore = NSUbiquitousKeyValueStore.default
    nonisolated(unsafe) static var now: () -> Double = { Date().timeIntervalSince1970 }

    /// `fp:<sha256>` when the item carries a valid agent certificate fingerprint, else `id:<uuid>`.
    static func identity(of item: OrbitSyncedPCItem) -> String {
        identity(fingerprint: item.certificateFingerprint, id: item.id)
    }

    static func identity(fingerprint: String, id: String) -> String {
        let normalized = normalizedFingerprint(fingerprint)
        return normalized.isEmpty ? "id:\(id)" : "fp:\(normalized)"
    }

    /// Lower-case hex SHA-256 without separators, or "" when the value is not a fingerprint.
    static func normalizedFingerprint(_ value: String) -> String {
        let hex = value.lowercased().filter { $0.isHexDigit }
        return hex.count == 64 ? hex : ""
    }

    static func isIPv4(_ value: String) -> Bool { IPv4Address(value) != nil }

    /// Prefers a numeric IPv4 address over a Bonjour `.local` name: the name becomes the
    /// fallback (`bonjourHost`) and the last known IPv4 becomes the address.
    static func normalizedAddress(address: String, lastKnownIPv4: String, bonjourHost: String?) -> (address: String, bonjourHost: String?) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var fallback = bonjourHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback?.isEmpty == true { fallback = nil }
        if isIPv4(trimmed) { return (trimmed, fallback) }
        if trimmed.lowercased().hasSuffix(".local") { fallback = trimmed }
        if isIPv4(lastKnownIPv4) { return (lastKnownIPv4, fallback) }
        return (trimmed, fallback)
    }

    static func normalized(_ item: OrbitSyncedPCItem) -> OrbitSyncedPCItem {
        var copy = item
        let resolved = normalizedAddress(address: item.address, lastKnownIPv4: item.lastKnownIPv4, bonjourHost: item.bonjourHost)
        copy.address = resolved.address
        copy.bonjourHost = resolved.bonjourHost
        copy.certificateFingerprint = normalizedFingerprint(item.certificateFingerprint).isEmpty ? item.certificateFingerprint : normalizedFingerprint(item.certificateFingerprint)
        copy.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    // MARK: Reading

    static func cloudItems(from store: OrbitSyncedKeyValueStore = store) -> [OrbitSyncedPCItem] {
        guard let data = store.data(forKey: itemsKey), let items = try? JSONDecoder().decode([OrbitSyncedPCItem].self, from: data) else { return [] }
        return items.map(normalized)
    }

    /// Identity → time of removal, for PCs deleted on another device.
    static func removed(from store: OrbitSyncedKeyValueStore = store) -> [String: Double] {
        guard let data = store.data(forKey: removedKey), let removed = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return removed
    }

    /// What a device should import: iCloud's items minus the ones removed after their last edit.
    static func importableItems(from store: OrbitSyncedKeyValueStore = store) -> [OrbitSyncedPCItem] {
        let removed = removed(from: store)
        return cloudItems(from: store).filter { (removed[identity(of: $0)] ?? 0) <= ($0.updatedAt ?? 0) }
    }

    // MARK: Merging

    static func merge(cloud: [OrbitSyncedPCItem], local: [OrbitSyncedPCItem], removed: [String: Double]) -> [OrbitSyncedPCItem] {
        var result: [OrbitSyncedPCItem] = []
        var index: [String: Int] = [:]
        func upsert(_ candidate: OrbitSyncedPCItem, preferCandidate: Bool) {
            let item = normalized(candidate)
            let key = identity(of: item)
            if (removed[key] ?? 0) > (item.updatedAt ?? 0) { return }
            if let position = index[key] {
                let existing = result[position]
                var winner: OrbitSyncedPCItem
                var loser: OrbitSyncedPCItem
                if (item.updatedAt ?? 0) > (existing.updatedAt ?? 0) || ((item.updatedAt ?? 0) == (existing.updatedAt ?? 0) && preferCandidate) {
                    winner = item; loser = existing
                } else {
                    winner = existing; loser = item
                }
                if winner.apiToken.isEmpty { winner.apiToken = loser.apiToken }
                if !isIPv4(winner.address), isIPv4(loser.address) { winner.address = loser.address }
                if winner.lastKnownIPv4.isEmpty { winner.lastKnownIPv4 = loser.lastKnownIPv4 }
                if winner.bonjourHost == nil { winner.bonjourHost = loser.bonjourHost }
                if winner.macAddress.isEmpty { winner.macAddress = loser.macAddress }
                if preferCandidate { winner.isSelected = item.isSelected }
                result[position] = winner
            } else {
                index[key] = result.count
                result.append(item)
            }
        }
        for item in cloud { upsert(item, preferCandidate: false) }
        for item in local { upsert(item, preferCandidate: true) }
        return result
    }

    // MARK: Publishing

    /// Merges `local` into iCloud and writes only when something changed. `removing` lists the
    /// identities of PCs the user just deleted on this device. Returns true after a write.
    @discardableResult
    static func publish(local: [OrbitSyncedPCItem], removing: [String] = [], to store: OrbitSyncedKeyValueStore = store) -> Bool {
        let timestamp = now()
        var removed = removed(from: store)
        for key in removing { removed[key] = timestamp }
        let removedChanged = removed != self.removed(from: store)
        let cloud = cloudItems(from: store)
        let merged = merge(cloud: cloud, local: local, removed: removed)
        if !removedChanged, equivalent(merged, cloud) { return false }
        guard let data = try? JSONEncoder().encode(merged) else { return false }
        store.set(data, forKey: itemsKey)
        if removedChanged, let removedData = try? JSONEncoder().encode(removed) { store.set(removedData, forKey: removedKey) }
        store.synchronize()
        return true
    }

    /// Same PCs with the same fields, ignoring which one each device has selected.
    static func equivalent(_ lhs: [OrbitSyncedPCItem], _ rhs: [OrbitSyncedPCItem]) -> Bool {
        func canonical(_ items: [OrbitSyncedPCItem]) -> [OrbitSyncedPCItem] {
            items.map { var copy = $0; copy.isSelected = false; return copy }.sorted { identity(of: $0) < identity(of: $1) }
        }
        return canonical(lhs) == canonical(rhs)
    }
}
