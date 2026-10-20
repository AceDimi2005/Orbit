import Foundation

/// In-memory stand-in for iCloud Key-Value Storage.
final class MemoryStore: OrbitSyncedKeyValueStore {
    var values: [String: Data] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data; writes += 1 }
    func synchronize() -> Bool { true }
}

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition { print("FAIL: \(message) (\(file):\(line))"); exit(1) }
}

let fingerprint = String(repeating: "ab", count: 32)
func item(id: String = "pc-1", name: String = "PC2-Dimitrie", address: String = "192.168.1.196", fingerprint fp: String = fingerprint,
          lastKnownIPv4: String = "192.168.1.196", token: String = "token-1", selected: Bool = false, updatedAt: Double? = nil,
          bonjourHost: String? = nil) -> OrbitSyncedPCItem {
    OrbitSyncedPCItem(id: id, name: name, address: address, agentPort: 8765, securePort: 8766, certificateFingerprint: fp,
                      macAddress: "AA:BB:CC:DD:EE:FF", subnetMask: "255.255.255.0", broadcastAddress: "192.168.1.255", wolPort: 9,
                      lastKnownIPv4: lastKnownIPv4, apiToken: token, isSelected: selected, bonjourHost: bonjourHost, updatedAt: updatedAt)
}

@main
enum OrbitPCSyncTests {
    static func main() {
        // 1. A Bonjour `.local` address becomes the numeric IPv4, the name stays as the fallback.
        let normalized = OrbitPCCloudSync.normalized(item(address: "orbit-ce5f12ab34cd.local", lastKnownIPv4: "192.168.1.196"))
        check(normalized.address == "192.168.1.196", "address should switch to the last known IPv4, got \(normalized.address)")
        check(normalized.bonjourHost == "orbit-ce5f12ab34cd.local", "the .local name must be kept as bonjourHost")
        let untouched = OrbitPCCloudSync.normalized(item(address: "100.64.0.9", lastKnownIPv4: "192.168.1.196"))
        check(untouched.address == "100.64.0.9", "an explicit IPv4 (VPN) address must not be replaced")
        let noIPv4 = OrbitPCCloudSync.normalized(item(address: "orbit-ce5f.local", lastKnownIPv4: ""))
        check(noIPv4.address == "orbit-ce5f.local" && noIPv4.bonjourHost == "orbit-ce5f.local", "without a known IPv4 the name stays")

        // 2. Legacy 4.2 payloads (no optional fields) still decode.
        let legacyJSON = #"[{"id":"legacy","name":"Old","address":"10.0.0.2","agentPort":8765,"securePort":8766,"certificateFingerprint":"","macAddress":"","subnetMask":"255.255.255.0","broadcastAddress":"","wolPort":9,"lastKnownIPv4":"","apiToken":"t","isSelected":true}]"#
        let legacyStore = MemoryStore()
        legacyStore.values[OrbitPCCloudSync.itemsKey] = Data(legacyJSON.utf8)
        let legacy = OrbitPCCloudSync.cloudItems(from: legacyStore)
        check(legacy.count == 1 && legacy[0].updatedAt == nil && legacy[0].name == "Old", "legacy item decodes with nil optionals")

        // 3. The same PC is matched by its agent certificate even when the ids differ (paired separately on two devices).
        let store = MemoryStore()
        OrbitPCCloudSync.now = { 1_000 }
        let fromiPhone = item(id: "iphone-id", token: "token-iphone", selected: true, updatedAt: 900)
        check(OrbitPCCloudSync.publish(local: [fromiPhone], to: store), "first publish writes")
        OrbitPCCloudSync.now = { 2_000 }
        let fromMac = item(id: "mac-id", name: "PC2-Dimitrie (renamed)", token: "", updatedAt: 1_500)
        check(OrbitPCCloudSync.publish(local: [fromMac], to: store), "second device merges and writes")
        var cloud = OrbitPCCloudSync.cloudItems(from: store)
        check(cloud.count == 1, "fingerprint match keeps one PC, got \(cloud.count)")
        check(cloud[0].name == "PC2-Dimitrie (renamed)", "the newer edit wins")
        check(cloud[0].apiToken == "token-iphone", "a missing token is filled from the other copy")

        // 4. Nothing is written when the merge equals iCloud (no ping-pong between devices), selection aside.
        let writesBefore = store.writes
        check(!OrbitPCCloudSync.publish(local: [cloud[0]], to: store), "republishing identical data must not write")
        var reselected = cloud[0]; reselected.isSelected = true
        check(!OrbitPCCloudSync.publish(local: [reselected], to: store), "selection differences alone must not write")
        check(store.writes == writesBefore, "store untouched")

        // 5. A removal propagates: deleted on the Mac after the iPhone's last edit → gone for the iPhone too,
        //    while a PC edited after the removal comes back.
        OrbitPCCloudSync.now = { 3_000 }
        check(OrbitPCCloudSync.publish(local: [], removing: [OrbitPCCloudSync.identity(of: cloud[0])], to: store), "removal writes")
        check(OrbitPCCloudSync.importableItems(from: store).isEmpty, "removed PC is not importable")
        let stale = item(id: "iphone-id", updatedAt: 2_500)
        OrbitPCCloudSync.publish(local: [stale], to: store)
        check(OrbitPCCloudSync.importableItems(from: store).isEmpty, "a copy older than the removal stays removed")
        let revived = item(id: "iphone-id", updatedAt: 3_500)
        OrbitPCCloudSync.publish(local: [revived], to: store)
        cloud = OrbitPCCloudSync.importableItems(from: store)
        check(cloud.count == 1 && cloud[0].updatedAt == 3_500, "a PC paired again after the removal is back")

        // 6. Different PCs (different fingerprints) live side by side; an item without a fingerprint is keyed by id.
        let other = item(id: "pc-2", name: "Laptop", address: "192.168.1.50", fingerprint: String(repeating: "cd", count: 32), lastKnownIPv4: "192.168.1.50", updatedAt: 3_600)
        let manual = item(id: "manual", name: "Manual", address: "10.1.1.1", fingerprint: "", lastKnownIPv4: "", updatedAt: 3_600)
        OrbitPCCloudSync.publish(local: [other, manual], to: store)
        let all = OrbitPCCloudSync.importableItems(from: store)
        check(all.count == 3, "three distinct PCs expected, got \(all.count)")
        check(OrbitPCCloudSync.identity(of: manual) == "id:manual", "no fingerprint → id identity")
        check(OrbitPCCloudSync.identity(fingerprint: "AB:CD" + String(repeating: "ab", count: 30), id: "x").hasPrefix("fp:"), "fingerprints normalize")

        print("PASS: iCloud PC sync merge, .local → IPv4 normalisation, legacy payloads, fingerprint matching, token fill-in, no-op republish and removals")
    }
}
