import Foundation

/// One entry of the PC's event log (`GET /api/events`, DESIGN §1.6).
struct OrbitPCEvent: Decodable, Identifiable, Equatable, Sendable {
    /// The parts of `data` the apps use. Read leniently: an event with an unexpected `data` still decodes.
    struct Details: Decodable, Equatable, Sendable {
        /// `power.scheduled`: the countdown length in seconds.
        var delaySeconds: Double?
        /// `power.scheduled`: when the PC sleeps or shuts down (ISO 8601, UTC).
        var countdownEndsAt: String?

        init(delaySeconds: Double? = nil, countdownEndsAt: String? = nil) {
            self.delaySeconds = delaySeconds
            self.countdownEndsAt = countdownEndsAt
        }

        enum CodingKeys: String, CodingKey { case delaySeconds, countdownEndsAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            delaySeconds = try? container.decodeIfPresent(Double.self, forKey: .delaySeconds)
            countdownEndsAt = try? container.decodeIfPresent(String.self, forKey: .countdownEndsAt)
        }
    }

    var id: Int
    var ts: String
    var kind: String
    var level: String
    var title: String
    var body: String
    var data: Details?

    init(id: Int, ts: String, kind: String, level: String = "active", title: String, body: String, data: Details? = nil) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.level = level
        self.title = title
        self.body = body
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case id, ts, kind, level, title, body, data }

    /// Only `id` is required: one odd field must not stop every later alert from being read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        ts = (try? container.decodeIfPresent(String.self, forKey: .ts)) ?? ""
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        level = (try? container.decodeIfPresent(String.self, forKey: .level)) ?? "active"
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? ""
        data = try? container.decodeIfPresent(Details.self, forKey: .data)
    }

    /// `ts` is UTC with whole seconds, for example `2026-10-23T18:00:00Z`.
    var date: Date? { OrbitEventFeed.parseTimestamp(ts) }
}

/// `{"events": [...oldest first...], "latestID": 12, "more": false}`. Agents before 4.4 have no `more`.
struct OrbitPCEventPage: Decodable, Equatable, Sendable {
    var events: [OrbitPCEvent]
    var latestID: Int
    var more: Bool?
}

/// Turns the PC's event log into local notifications without repeats, floods or stale alerts.
///
/// Shared by the iPhone (foreground and background-refresh poller), its Notification Service Extension
/// (the delivered-ids store) and the Mac, and compiled on its own by `Tests/check_push_crypto.py`, so it
/// uses Foundation only.
enum OrbitEventFeed {
    /// Most notifications posted for one PC in one poll; older ones are skipped (newest win).
    static let maximumPerPoll = 5
    /// Downloads, watched apps and summaries older than this are history, not news.
    static let maximumAge: TimeInterval = 12 * 60 * 60
    /// "PC is online", temperature and power outcomes only matter while they're current.
    static let shortLivedMaximumAge: TimeInterval = 15 * 60
    /// A "sleeping in 60 s" alert is shown until this long after its countdown ends, then it's dropped:
    /// its Cancel button can only fail by then.
    static let powerScheduledGrace: TimeInterval = 30
    /// The longest countdown the PC accepts (`delaySeconds` 30–600).
    static let maximumPowerDelay: TimeInterval = 600
    /// Alerts at least this old say how long ago they happened ("2 hours ago: …").
    static let agePrefixThreshold: TimeInterval = 5 * 60
    /// Pages read in one poll (50 events each).
    static let maximumPages = 6
    static let pageSize = 50

    struct Result: Equatable {
        /// Events to show, oldest first.
        var toPost: [OrbitPCEvent]
        /// The id to remember and pass as `since` next time.
        var cursor: Int
        /// True when the PC's log was new to us or recreated: nothing was posted on purpose.
        var resynced: Bool
        /// The highest id the PC's log has handed out. Delivered ids above it belong to an older log of
        /// this PC (it was reinstalled or its log was reset); see `OrbitDeliveredStore.reconcile`.
        var latestID: Int
    }

    /// Reads the events after `cursor`.
    ///
    /// - `cursor == nil` (first poll for this PC): only learns `latestID`, so turning alerts on never
    ///   floods the phone with the PC's history.
    /// - `delivered`: the ids already shown (by a push, or an earlier poll). Only those are skipped, so an
    ///   older event a push didn't show (pushes arrive out of order, or APNs kept only the newest one) is
    ///   still posted.
    /// - `holdBack`: with instant pushes working, an event younger than this is left for the push and
    ///   looked at again on the next poll (the cursor stops before it), so the two never race.
    /// - `fetch(since, limit)` performs `GET /api/events?since=&limit=`.
    static func poll(cursor: Int?, delivered: OrbitDeliveredIDs, holdBack: TimeInterval? = nil, now: Date = Date(),
                     fetch: @Sendable (_ since: Int?, _ limit: Int) async throws -> OrbitPCEventPage) async throws -> Result {
        guard let start = cursor, start >= 0 else {
            let page = try await fetch(nil, 1)
            return Result(toPost: [], cursor: max(0, page.latestID), resynced: true, latestID: max(0, page.latestID))
        }
        var position = start
        var delivered = delivered
        var latest = start
        var candidates: [OrbitPCEvent] = []
        pages: for _ in 0..<maximumPages {
            let page = try await fetch(position, pageSize)
            if page.latestID < position {
                // Ids only grow on a PC, so a smaller latestID means its log was recreated.
                return Result(toPost: [], cursor: max(0, page.latestID), resynced: true, latestID: max(0, page.latestID))
            }
            latest = page.latestID
            // Delivered ids above anything this log ever handed out came from an older log of the PC.
            if delivered.maxID > page.latestID { delivered = OrbitDeliveredIDs(floor: start) }
            for event in page.events.sorted(by: { $0.id < $1.id }) where event.id > position {
                if let holdBack, let date = event.date, now.timeIntervalSince(date) < holdBack {
                    break pages
                }
                position = event.id
                if !delivered.contains(event.id), isFresh(event, now: now) { candidates.append(event) }
            }
            guard page.more == true, !page.events.isEmpty else {
                // Caught up: every id up to latestID was returned or has expired, unless we held one back.
                position = max(position, page.latestID)
                break
            }
        }
        return Result(toPost: Array(candidates.suffix(maximumPerPoll)), cursor: position, resynced: false, latestID: latest)
    }

    /// How long after it happened an event is still worth a notification.
    static func maximumAge(of event: OrbitPCEvent) -> TimeInterval {
        switch event.kind {
        case "pc.online", "pc.offline", "temperature.high", "power.cancelled", "power.executing":
            return shortLivedMaximumAge
        case "power.scheduled":
            let delay = min(max(event.data?.delaySeconds ?? 60, 0), maximumPowerDelay)
            return delay + powerScheduledGrace
        default:
            return maximumAge
        }
    }

    static func isFresh(_ event: OrbitPCEvent, now: Date) -> Bool {
        if event.kind == "power.scheduled", let end = event.data?.countdownEndsAt.flatMap(parseTimestamp) {
            return now.timeIntervalSince(end) <= powerScheduledGrace
        }
        guard let date = event.date else { return true }
        return now.timeIntervalSince(date) <= maximumAge(of: event)
    }

    /// The notification text. An alert that arrives late (background refresh, a Mac waking up, a push
    /// APNs held) says how long ago it happened, so "CPU at 96 °C" isn't mistaken for news.
    static func displayBody(_ body: String, date: Date?, now: Date) -> String {
        guard let date else { return body }
        let age = now.timeIntervalSince(date)
        guard age >= agePrefixThreshold else { return body }
        let ago = agoText(age)
        return body.isEmpty ? ago.prefix(1).uppercased() + ago.dropFirst() : "\(ago): \(body)"
    }

    static func displayBody(_ event: OrbitPCEvent, now: Date) -> String {
        displayBody(event.body, date: event.date, now: now)
    }

    /// "12 min ago", "1 hour ago", "3 hours ago", "2 days ago" (English, like the rest of the app).
    static func agoText(_ age: TimeInterval) -> String {
        let minutes = max(1, Int(age / 60))
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// The user-facing group an event kind belongs to (Mac filters, iPhone icons).
    enum Category: String, CaseIterable {
        case downloads, temperature, tasks, power, online, summary, other
    }

    static func category(of kind: String) -> Category {
        switch kind {
        case "download.finished", "download.failed", "downloads.allFinished": return .downloads
        case "temperature.high": return .temperature
        case "task.finished": return .tasks
        case "power.scheduled", "power.cancelled", "power.executing": return .power
        case "pc.online", "pc.offline": return .online
        case "summary.ready": return .summary
        default: return .other
        }
    }

    /// Notification identifier for one event of one PC; posting it twice replaces instead of stacking.
    static func notificationIdentifier(pcID: String, eventID: Int) -> String {
        "orbit.event.\(pcID).\(eventID)"
    }

    /// Category identifier of alerts that carry a "Cancel" action (the PC is about to sleep or shut down).
    static let powerScheduledCategory = "orbit.power.scheduled"
    static let eventCategory = "orbit.pc.event"
    static let cancelPowerAction = "orbit.power.cancel"

    static func notificationCategory(for kind: String) -> String {
        kind == "power.scheduled" ? powerScheduledCategory : eventCategory
    }
}

// MARK: - Alerts already shown

/// The event ids of one PC that were already shown, by a push or by the app's own poller.
///
/// A set, not a high-water mark: pushes can arrive out of order (iOS runs several extension instances at
/// once and APNs doesn't keep order) or coalesced (APNs keeps only the newest push for a phone that is
/// offline), and an older event nobody showed yet must still be shown. Holds the newest `capacity` ids;
/// ids at or below `floor` (older than that window, or before the PC's log was recreated) count as shown.
/// Each id keeps when this device recorded it, which tells an older log's ids from a newer event's.
struct OrbitDeliveredIDs: Codable, Equatable, Sendable {
    static let capacity = 200

    private(set) var floor: Int
    /// Ascending, all above `floor`, at most `capacity`.
    private(set) var ids: [Int]
    /// When each id was recorded (seconds since 1970, this device's clock), parallel to `ids`.
    private(set) var recordedAt: [Double]

    init(floor: Int = 0, ids: [Int] = [], recordedAt: [Double] = []) {
        self.floor = max(0, floor)
        self.ids = []
        self.recordedAt = []
        let times = Dictionary(zip(ids, recordedAt), uniquingKeysWith: { first, _ in first })
        for id in Set(ids).sorted() { insert(id, at: times[id] ?? 0) }
    }

    enum CodingKeys: String, CodingKey { case floor, ids, recordedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(floor: (try? container.decodeIfPresent(Int.self, forKey: .floor)) ?? 0,
                  ids: (try? container.decodeIfPresent([Int].self, forKey: .ids)) ?? [],
                  recordedAt: (try? container.decodeIfPresent([Double].self, forKey: .recordedAt)) ?? [])
    }

    var maxID: Int { max(floor, ids.last ?? 0) }

    func contains(_ id: Int) -> Bool {
        id <= floor || ids[insertionIndex(id)...].first == id
    }

    /// Returns false when the id counted as shown already.
    @discardableResult
    mutating func insert(_ id: Int, at time: Double = 0) -> Bool {
        guard id > floor else { return false }
        let index = insertionIndex(id)
        if index < ids.count, ids[index] == id { return false }
        ids.insert(id, at: index)
        recordedAt.insert(time, at: index)
        while ids.count > Self.capacity {
            floor = ids.removeFirst()
            recordedAt.removeFirst()
        }
        return true
    }

    /// True when something recorded before `time` is above anything the PC's log has handed out
    /// (`latestID`): the log was recreated. An id recorded after `time` can belong to an event newer than
    /// the reply that said `latestID` (its push arrived while the poll was running), so it proves nothing.
    func belongsToOlderLog(latestID: Int, recordedBefore time: Double) -> Bool {
        floor > latestID || zip(ids, recordedAt).contains { $0.0 > latestID && $0.1 < time }
    }

    /// Starts over from `floor`, keeping only what was recorded at or after `time`.
    func restarted(floor: Int, keepingFrom time: Double) -> OrbitDeliveredIDs {
        var fresh = OrbitDeliveredIDs(floor: floor)
        for (id, at) in zip(ids, recordedAt) where at >= time { fresh.insert(id, at: at) }
        return fresh
    }

    /// The first index whose id is not below `id`.
    private func insertionIndex(_ id: Int) -> Int {
        var low = 0, high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if ids[middle] < id { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// `OrbitDeliveredIDs` for every PC in one small JSON file, shared by the iPhone app and its Notification
/// Service Extension through the App Group container.
///
/// Every change is a read-modify-write under an exclusive `flock` on a lock file next to it, so the app and
/// any number of extension instances never lose each other's ids, and the record of what was shown never
/// goes backwards. The lock is held for microseconds, never across an `await`.
struct OrbitDeliveredStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    func ids(for pcID: String) -> OrbitDeliveredIDs {
        withLock { $0[pcID] } ?? OrbitDeliveredIDs()
    }

    /// Marks an event as shown. Returns false when it was shown already (show nothing, or show it silently).
    @discardableResult
    func record(_ eventID: Int, for pcID: String, at date: Date = Date()) -> Bool {
        guard eventID > 0, !pcID.isEmpty else { return true }
        return withLock { map in
            var entry = map[pcID] ?? OrbitDeliveredIDs()
            guard entry.insert(eventID, at: date.timeIntervalSince1970) else { return false }
            map[pcID] = entry
            return true
        }
    }

    /// After a poll that started at `pollStartedAt` and learned the PC's `latestID`: when the PC's log was
    /// recreated (reinstall, reset; ids start again from 1), what was recorded before the poll belongs to the
    /// old log, so everything up to `floor` counts as shown and nothing above. `logRecreated` says the poll
    /// saw it directly (the log shrank below the cursor); otherwise ids recorded before the poll that are
    /// above `latestID` prove it.
    func reconcile(_ pcID: String, latestID: Int, floor: Int, pollStartedAt: Date, logRecreated: Bool = false) {
        let started = pollStartedAt.timeIntervalSince1970
        withLock { map in
            guard let entry = map[pcID],
                  logRecreated || entry.belongsToOlderLog(latestID: latestID, recordedBefore: started) else { return }
            map[pcID] = entry.restarted(floor: min(floor, latestID), keepingFrom: started)
        }
    }

    func forget(_ pcID: String) {
        withLock { map in map.removeValue(forKey: pcID) }
    }

    // MARK: File and lock

    @discardableResult
    private func withLock<T>(_ body: (inout [String: OrbitDeliveredIDs]) -> T) -> T {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(fileURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        var map = load()
        let before = map
        let result = body(&map)
        if map != before { save(map) }
        return result
    }

    private func load() -> [String: OrbitDeliveredIDs] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: OrbitDeliveredIDs].self, from: data) else { return [:] }
        return map
    }

    private func save(_ map: [String: OrbitDeliveredIDs]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        #if os(iOS)
        // The extension writes while the iPhone is locked (after the first unlock since it started).
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: fileURL, options: .atomic)
        #endif
    }
}
