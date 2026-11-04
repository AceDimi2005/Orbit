import Foundation

// Compiled by check_settings_sync.py with Shared/OrbitSettingsSync.swift and Shared/OrbitPCSync.swift.
// Devices are simulated with in-memory stores; values round-trip through binary property lists, as they do in
// UserDefaults and iCloud key-value storage (numbers come back as NSNumber, strings as NSString…).

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition { print("FAIL: \(message) (\(file):\(line))"); exit(1) }
}

func roundTrip(_ value: Any) -> Any {
    let data = try! PropertyListSerialization.data(fromPropertyList: ["x": value], format: .binary, options: 0)
    let back = try! PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    return back["x"]!
}

/// A device's UserDefaults.
final class MemoryDefaults: OrbitSettingsLocalStore {
    var values: [String: Any] = [:]
    var writes = 0
    func explicitValues() -> [String: Any] { values }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        if let value { values[key] = roundTrip(value) } else { values.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { writes += 1; values.removeValue(forKey: key) }
}

/// iCloud key-value storage as one device sees it.
final class MemoryCloud: OrbitSettingsCloudStore {
    var values: [String: Any] = [:]
    var writes = 0
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        if let value { values[key] = roundTrip(value) } else { values.removeValue(forKey: key) }
    }
    func synchronize() -> Bool { true }
    func copy() -> MemoryCloud { let other = MemoryCloud(); other.values = values; return other }
}

nonisolated(unsafe) var macHasPro = false
let themes: Set<String> = ["noir", "ocean", "aurora", "violet", "ember", "graphite", "cyberpunk", "solarGold"]
let proThemes: Set<String> = ["cyberpunk", "solarGold"]

let iPhoneEngine = OrbitSettingsSyncEngine(
    settings: [
        OrbitSyncedSetting("theme", local: "orbit.theme", .string, isUsable: { themes.contains($0 as? String ?? "") }),
        OrbitSyncedSetting("reduceGlow", local: "orbit.reduceGlow", .bool),
        OrbitSyncedSetting("ios.haptics", local: "orbit.haptics", .bool),
        OrbitSyncedSetting("ios.activity.interval", local: "orbit.activity.interval", .int, isUsable: { [5, 10, 15].contains($0 as? Int ?? 0) }),
    ],
    families: [
        OrbitSyncedSettingFamily(cloud: "ios.dashboard.", local: "dashboardLayout.v1.", .data, excluding: ["preview"]),
        OrbitSyncedSettingFamily(cloud: "ios.componentNames.", local: "hardwareOverrides.", .stringDictionary, excluding: ["preview"]),
    ],
    origin: "iPhone")
var iPadEngine: OrbitSettingsSyncEngine { var engine = iPhoneEngine; engine.origin = "iPad"; return engine }
let macEngine = OrbitSettingsSyncEngine(
    settings: [
        OrbitSyncedSetting("theme", local: "mac.theme", .string, isUsable: { value in
            guard let raw = value as? String, themes.contains(raw) else { return false }
            return !proThemes.contains(raw) || macHasPro
        }),
        OrbitSyncedSetting("reduceGlow", local: "mac.reduceGlow", .bool),
        OrbitSyncedSetting("mac.refreshInterval", .double, isUsable: { (1...10).contains($0 as? Double ?? 0) }),
    ],
    families: [], origin: "Mac")

func synced(_ local: MemoryDefaults, _ key: String) -> OrbitSettingEntry? {
    OrbitSettingEntry(plist: (local.values[OrbitSettingsSyncEngine.stateKey] as? [String: Any])?[key])
}
func cloudEntry(_ cloud: MemoryCloud, _ key: String) -> OrbitSettingEntry? {
    OrbitSettingEntry(plist: (cloud.values[OrbitSettingsSyncEngine.cloudKey] as? [String: Any])?[key])
}

func settingsChecks() {
    // 1. The first device uploads the values the user set; registered defaults never get here, so unset keys stay out.
    let cloud = MemoryCloud()
    let iPhone = MemoryDefaults()
    iPhone.set("ocean", forKey: "orbit.theme")
    iPhone.set(true, forKey: "orbit.reduceGlow")
    iPhone.set("unrelated", forKey: "selectedPCID")
    var outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 1_000)
    check(outcome.wroteCloud && Set(outcome.published) == ["orbit.theme", "orbit.reduceGlow"], "first device publishes its values, got \(outcome.published)")
    check(cloudEntry(cloud, "theme")?.value as? String == "ocean" && cloudEntry(cloud, "theme")?.origin == "iPhone", "iCloud holds the theme")
    check(cloudEntry(cloud, "ios.haptics") == nil, "a setting never set is not uploaded")
    check((cloud.values[OrbitSettingsSyncEngine.cloudKey] as? [String: Any])?.keys.contains("selectedPCID") == false, "untracked keys never sync")
    check(synced(iPhone, "orbit.theme")?.updatedAt == 1_000, "the device remembers what it synced")

    // 2. Running again changes nothing: no write to iCloud, no write to the defaults.
    let cloudWrites = cloud.writes, localWrites = iPhone.writes
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 1_010)
    check(!outcome.wroteCloud && outcome.applied.isEmpty && cloud.writes == cloudWrites && iPhone.writes == localWrites, "an idle pass writes nothing")
    check(cloudEntry(cloud, "ios.haptics") == nil && synced(iPhone, "orbit.haptics")?.updatedAt == 0, "an unset setting has a local baseline and nothing in iCloud")

    // 3. A Mac joining takes iCloud's theme (shared name, its own local key) over a value it never synced, and
    //    uploads what iCloud doesn't have yet.
    let mac = MemoryDefaults()
    mac.set("violet", forKey: "mac.theme")
    mac.set(3.0, forKey: "mac.refreshInterval")
    outcome = macEngine.run(local: mac, cloud: cloud, now: 1_100)
    check(mac.values["mac.theme"] as? String == "ocean", "joining device takes iCloud's theme, got \(mac.values["mac.theme"] ?? "nil")")
    check(mac.values["mac.reduceGlow"] as? Bool == true, "shared reduceGlow arrives on the Mac")
    check(outcome.applied.contains("mac.theme") && outcome.published == ["mac.refreshInterval"], "applied \(outcome.applied), published \(outcome.published)")
    check(macEngine.run(local: mac, cloud: cloud, now: 1_101).wroteCloud == false, "the Mac's next pass is idle")

    // 4. An edit on the Mac wins on the iPhone; the iPhone ignores the Mac-only setting.
    mac.set("ember", forKey: "mac.theme")
    outcome = macEngine.run(local: mac, cloud: cloud, now: 1_200)
    check(outcome.published == ["mac.theme"], "the Mac publishes its edit")
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 1_210)
    check(iPhone.values["orbit.theme"] as? String == "ember" && outcome.applied == ["orbit.theme"], "the iPhone applies the Mac's theme")
    check(iPhone.values["mac.refreshInterval"] == nil, "Mac-only settings stay off the iPhone")

    // 5. A device with a slow clock still wins with an edit made after what it saw.
    iPhone.set("aurora", forKey: "orbit.theme")
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 50)
    let stamped = cloudEntry(cloud, "theme")?.updatedAt ?? 0
    check(stamped > 1_200, "a local edit is stamped after everything seen, got \(stamped)")
    _ = macEngine.run(local: mac, cloud: cloud, now: 1_300)
    check(mac.values["mac.theme"] as? String == "aurora", "the slow-clock edit still reaches the Mac")

    // 6. Two devices write at the same moment and one write overwrites the other in iCloud: the newest edit
    //    still wins everywhere, and the other device's change to a different setting is not lost.
    let phoneView = cloud.copy(), macView = cloud.copy()
    iPhone.set("graphite", forKey: "orbit.theme")
    iPhone.set(false, forKey: "orbit.reduceGlow")
    _ = iPhoneEngine.run(local: iPhone, cloud: phoneView, now: 2_000)
    mac.set("violet", forKey: "mac.theme")
    _ = macEngine.run(local: mac, cloud: macView, now: 1_900)
    cloud.values = macView.values   // the Mac's write reached iCloud last and replaced the iPhone's
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 2_010)
    check(Set(outcome.published) == ["orbit.theme", "orbit.reduceGlow"], "the iPhone writes back what iCloud lost, got \(outcome.published)")
    _ = macEngine.run(local: mac, cloud: cloud, now: 2_020)
    check(mac.values["mac.theme"] as? String == "graphite", "the newer edit (iPhone, 2000) beats the later write (Mac, 1900)")
    check(mac.values["mac.reduceGlow"] as? Bool == false, "the iPhone's other change survives the race")
    check(iPhoneEngine.run(local: iPhone, cloud: cloud, now: 2_030).wroteCloud == false
          && macEngine.run(local: mac, cloud: cloud, now: 2_031).wroteCloud == false, "after the race both devices are idle")

    // 7. A removal travels as a tombstone and removes the value on the other iPhone/iPad.
    let iPad = MemoryDefaults()
    iPhone.set(false, forKey: "orbit.haptics")
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 3_000)
    _ = iPadEngine.run(local: iPad, cloud: cloud, now: 3_010)
    check(iPad.values["orbit.haptics"] as? Bool == false && iPad.values["orbit.theme"] as? String == "graphite", "the iPad joins")
    iPhone.removeObject(forKey: "orbit.haptics")
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 3_100)
    check(outcome.published == ["orbit.haptics"], "removing a synced value publishes a tombstone")
    let tombstone = cloudEntry(cloud, "ios.haptics")
    check(tombstone != nil && tombstone?.value == nil && (tombstone?.updatedAt ?? 0) >= 3_100, "the tombstone has a time and no value")
    outcome = iPadEngine.run(local: iPad, cloud: cloud, now: 3_110)
    check(iPad.values["orbit.haptics"] == nil && outcome.applied == ["orbit.haptics"], "the iPad removes the value too")
    check(iPadEngine.run(local: iPad, cloud: cloud, now: 3_120).wroteCloud == false, "a tombstone does not bounce back")
    iPad.set(true, forKey: "orbit.haptics")
    _ = iPadEngine.run(local: iPad, cloud: cloud, now: 3_200)
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 3_210)
    check(iPhone.values["orbit.haptics"] as? Bool == true, "a newer value replaces the tombstone")

    // 8. A Pro theme from another device waits on a device without Orbit Pro, without writes, until Pro is there.
    iPhone.set("cyberpunk", forKey: "orbit.theme")
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 4_000)
    let macWrites = cloud.writes
    outcome = macEngine.run(local: mac, cloud: cloud, now: 4_010)
    check(mac.values["mac.theme"] as? String == "graphite" && outcome.applied.isEmpty && cloud.writes == macWrites, "no Pro: the Mac keeps its theme and writes nothing")
    macHasPro = true
    outcome = macEngine.run(local: mac, cloud: cloud, now: 4_020)
    check(mac.values["mac.theme"] as? String == "cyberpunk", "with Pro the waiting theme applies")
    macHasPro = false

    // 9. The Pro lockdown after a refund changes the theme on this device only.
    mac.set("noir", forKey: "mac.theme")
    macEngine.adoptLocalValues(forKeys: ["mac.theme"], local: mac)
    outcome = macEngine.run(local: mac, cloud: cloud, now: 4_100)
    check(outcome.published.isEmpty && cloudEntry(cloud, "theme")?.value as? String == "cyberpunk", "the lockdown's Noir stays on this Mac")
    check(mac.values["mac.theme"] as? String == "noir", "and the Pro theme is not put back on it")

    // 10. Values of the wrong type, unknown names or out of range never apply; a local value of the wrong type
    //     is neither published nor overwritten.
    var bucket = cloud.values[OrbitSettingsSyncEngine.cloudKey] as! [String: Any]
    bucket["ios.haptics"] = OrbitSettingEntry(value: "yes", updatedAt: 5_000, origin: "Future").plist
    bucket["ios.activity.interval"] = OrbitSettingEntry(value: 7, updatedAt: 5_000, origin: "Future").plist
    bucket["theme"] = OrbitSettingEntry(value: "neon", updatedAt: 5_000, origin: "Future").plist
    bucket["future.setting"] = OrbitSettingEntry(value: 1, updatedAt: 5_000, origin: "Future").plist
    cloud.set(bucket, forKey: OrbitSettingsSyncEngine.cloudKey)
    let iPhoneTheme = iPhone.values["orbit.theme"] as? String
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 5_010)
    check(iPhone.values["orbit.haptics"] as? Bool == true && iPhone.values["orbit.activity.interval"] == nil
          && iPhone.values["orbit.theme"] as? String == iPhoneTheme, "unusable values are ignored")
    iPhone.set(true, forKey: "orbit.theme")   // corrupt local value
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 5_020)
    check(cloudEntry(cloud, "theme")?.value as? String == "neon" && iPhone.values["orbit.theme"] as? Bool == true, "a corrupt local value is left alone")
    iPhone.set("ocean", forKey: "orbit.theme")
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 5_030)
    check(cloudEntry(cloud, "theme")?.value as? String == "ocean", "a real edit replaces the unusable entry")
    check((cloud.values[OrbitSettingsSyncEngine.cloudKey] as? [String: Any])?["future.setting"] != nil, "entries this build doesn't know are kept")
    iPhone.set(10, forKey: "orbit.activity.interval")
    _ = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 5_040)
    _ = iPadEngine.run(local: iPad, cloud: cloud, now: 5_050)
    check(iPad.values["orbit.activity.interval"] as? Int == 10, "an integer setting syncs")

    // 11. Per-PC overview cards and component names sync by key; demo mode's layout stays on the device; a value
    //     that is too large stays local.
    let layout = Data(#"{"columnCount":1,"visibleMetrics":["fps"]}"#.utf8)
    iPhone.set(layout, forKey: "dashboardLayout.v1.AA:BB:CC:DD:EE:FF")
    iPhone.set(Data("demo".utf8), forKey: "dashboardLayout.v1.preview")
    iPhone.set(["cpu": "Ryzen 7 7800X3D (delidded)"], forKey: "hardwareOverrides.AA:BB:CC:DD:EE:FF")
    iPhone.set(Data(count: OrbitSettingKind.maxDataBytes + 1), forKey: "dashboardLayout.v1.huge")
    outcome = iPhoneEngine.run(local: iPhone, cloud: cloud, now: 6_000)
    check(Set(outcome.published) == ["dashboardLayout.v1.AA:BB:CC:DD:EE:FF", "hardwareOverrides.AA:BB:CC:DD:EE:FF"], "family keys publish, got \(outcome.published)")
    outcome = iPadEngine.run(local: iPad, cloud: cloud, now: 6_010)
    check(iPad.values["dashboardLayout.v1.AA:BB:CC:DD:EE:FF"] as? Data == layout, "the layout arrives on the iPad")
    check((iPad.values["hardwareOverrides.AA:BB:CC:DD:EE:FF"] as? [String: String])?["cpu"] == "Ryzen 7 7800X3D (delidded)", "component names arrive")
    check(iPad.values["dashboardLayout.v1.preview"] == nil && iPad.values["dashboardLayout.v1.huge"] == nil, "demo and oversized layouts stay local")
    check(Set(outcome.applied) == ["dashboardLayout.v1.AA:BB:CC:DD:EE:FF", "hardwareOverrides.AA:BB:CC:DD:EE:FF"], "the iPad reports which keys changed")

    // 12. Forgetting the synced state (switch back on, new iCloud account) joins afresh: iCloud wins.
    mac.set("violet", forKey: "mac.theme")
    OrbitSettingsSyncEngine.forgetSyncedState(local: mac)
    _ = macEngine.run(local: mac, cloud: cloud, now: 7_000)
    check(mac.values["mac.theme"] as? String == "ocean", "after forgetting, iCloud's theme wins over the local one")

    // 13. Decision table spot checks.
    let entry = OrbitSettingEntry(value: "a", updatedAt: 10, origin: "x")
    if case .record(let e) = OrbitSettingsSyncEngine.decide(local: nil, synced: nil, cloud: nil, now: 1, origin: "y", usable: { _ in true }) {
        check(e.updatedAt == 0 && e.value == nil, "nothing anywhere: a baseline at time 0")
    } else { check(false, "nothing anywhere: record a baseline") }
    let baseline = OrbitSettingEntry(value: nil, updatedAt: 0, origin: "y")
    if case .keep = OrbitSettingsSyncEngine.decide(local: nil, synced: baseline, cloud: nil, now: 1, origin: "y", usable: { _ in true }) {} else { check(false, "a baseline is never published") }
    if case .publish(let e) = OrbitSettingsSyncEngine.decide(local: true, synced: baseline, cloud: entry, now: 5, origin: "y", usable: { _ in true }) {
        check(e.updatedAt > 10, "a first edit after the baseline beats what iCloud held")
    } else { check(false, "first edit after a baseline: publish") }
    if case .record = OrbitSettingsSyncEngine.decide(local: "a", synced: nil, cloud: entry, now: 1, origin: "y", usable: { _ in true }) {} else { check(false, "same value: record") }
    if case .publish(let e) = OrbitSettingsSyncEngine.decide(local: "a", synced: entry, cloud: nil, now: 99, origin: "y", usable: { _ in true }) {
        check(e.updatedAt == 10, "a lost entry is written back unchanged")
    } else { check(false, "iCloud lost it: publish") }
    print("settings sync: first upload, idle passes, joining, edits, slow clocks, write races, tombstones, Pro themes, lockdown, validation, per-PC layouts, rejoin: OK")
}

func switchChecks() {
    // "Sync with iCloud" off: the saved-PC sync neither reads nor writes iCloud, and remembers removals for later.
    let suite = "orbit-settings-sync-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    OrbitCloudSyncSwitch.defaults = defaults
    OrbitPCCloudSync.localDefaults = defaults
    check(OrbitCloudSyncSwitch.isOn, "the switch is on by default")

    final class PCStore: OrbitSyncedKeyValueStore {
        var values: [String: Data] = [:]
        var writes = 0
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value as? Data; writes += 1 }
        func synchronize() -> Bool { true }
    }
    let fp = String(repeating: "cd", count: 32)
    func pc(_ id: String, updatedAt: Double) -> OrbitSyncedPCItem {
        OrbitSyncedPCItem(id: id, name: "PC2-Dimitrie", address: "192.168.1.196", agentPort: 8765, securePort: 8766, certificateFingerprint: fp,
                          macAddress: "AA:BB:CC:DD:EE:FF", subnetMask: "255.255.255.0", broadcastAddress: "192.168.1.255", wolPort: 9,
                          lastKnownIPv4: "192.168.1.196", apiToken: "token", isSelected: true, updatedAt: updatedAt)
    }
    let store = PCStore()
    OrbitPCCloudSync.now = { 100 }
    check(OrbitPCCloudSync.publish(local: [pc("a", updatedAt: 50)], to: store), "on: the PC is published")
    let identity = OrbitPCCloudSync.identity(of: pc("a", updatedAt: 50))

    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let observer = NotificationCenter.default.addObserver(forName: OrbitCloudSyncSwitch.changedNotification, object: nil, queue: nil) { _ in counter.value += 1 }
    var posted: Int { counter.value }
    OrbitCloudSyncSwitch.set(false)
    OrbitCloudSyncSwitch.set(false)
    check(!OrbitCloudSyncSwitch.isOn && posted == 1, "turning it off posts one change")
    let writes = store.writes
    OrbitPCCloudSync.now = { 200 }
    check(!OrbitPCCloudSync.publish(local: [], removing: [identity], to: store), "off: nothing is written")
    check(store.writes == writes, "off: iCloud untouched")
    check(OrbitPCCloudSync.cloudItems(from: store).isEmpty && OrbitPCCloudSync.importableItems(from: store).isEmpty, "off: nothing is read from iCloud")
    check(OrbitPCCloudSync.pendingRemovals()[identity] == 200, "off: the removal waits on the device")
    check(OrbitPCCloudSync.removed(from: store)[identity] == 200, "a waiting removal already counts locally")

    OrbitCloudSyncSwitch.set(true)
    NotificationCenter.default.removeObserver(observer)
    check(posted == 2, "turning it on posts a change")
    check(OrbitPCCloudSync.importableItems(from: store).isEmpty, "back on: the removed PC does not come back from iCloud")
    OrbitPCCloudSync.now = { 300 }
    check(OrbitPCCloudSync.publish(local: [], to: store), "back on: the waiting removal is published")
    check(OrbitPCCloudSync.removed(from: store)[identity] == 200 && OrbitPCCloudSync.cloudItems(from: store).isEmpty, "the removal keeps its time and the PC is gone")
    check(OrbitPCCloudSync.pendingRemovals().isEmpty, "and no longer waits")
    // A PC edited elsewhere after the removal comes back (the newest change wins).
    check(OrbitPCCloudSync.publish(local: [pc("b", updatedAt: 250)], to: store), "a newer edit is published")
    check(OrbitPCCloudSync.importableItems(from: store).count == 1, "an edit newer than the removal wins")
    print("iCloud switch: off reads and writes nothing, removals wait and publish later: OK")
}

@main
enum OrbitSettingsSyncTests {
    static func main() {
        settingsChecks()
        switchChecks()
    }
}
