import Foundation

/// One entry of the PC's event log (`GET /api/events`, DESIGN §1.6).
struct OrbitPCEvent: Decodable, Identifiable, Equatable, Sendable {
    var id: Int
    var ts: String
    var kind: String
    var level: String
    var title: String
    var body: String

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
/// Shared by the iPhone (foreground and background-refresh poller) and the Mac, and compiled on its
/// own by `Tests/check_push_crypto.py`, so it uses Foundation only.
enum OrbitEventFeed {
    /// Most notifications posted for one PC in one poll; older ones are skipped (newest win).
    static let maximumPerPoll = 5
    /// Alerts older than this are history, not news.
    static let maximumAge: TimeInterval = 12 * 60 * 60
    /// A "sleeping in 60 s" alert is meaningless after the countdown.
    static let powerScheduledMaximumAge: TimeInterval = 10 * 60
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
        /// The highest id the PC's log has handed out. A stored "delivered" id above it belongs to an
        /// older log of this PC (it was reinstalled or its log was reset) and should be lowered.
        var latestID: Int
    }

    /// Reads the events after `cursor`.
    ///
    /// - `cursor == nil` (first poll for this PC): only learns `latestID`, so turning alerts on never
    ///   floods the phone with the PC's history.
    /// - `delivered`: the highest id already shown (by a push, or an earlier poll). Older ids are skipped.
    /// - `holdBack`: with instant pushes working, an event younger than this is left for the push and
    ///   looked at again on the next poll (the cursor stops before it), so the two never race.
    /// - `fetch(since, limit)` performs `GET /api/events?since=&limit=`.
    static func poll(cursor: Int?, delivered: Int, holdBack: TimeInterval? = nil, now: Date = Date(),
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
            // A "delivered" mark above anything this log ever handed out came from an older log of the PC.
            if delivered > page.latestID { delivered = start }
            for event in page.events.sorted(by: { $0.id < $1.id }) where event.id > position {
                if let holdBack, let date = event.date, now.timeIntervalSince(date) < holdBack {
                    break pages
                }
                position = event.id
                if event.id > delivered, isFresh(event, now: now) { candidates.append(event) }
            }
            guard page.more == true, !page.events.isEmpty else {
                // Caught up: every id up to latestID was returned or has expired, unless we held one back.
                position = max(position, page.latestID)
                break
            }
        }
        return Result(toPost: Array(candidates.suffix(maximumPerPoll)), cursor: position, resynced: false, latestID: latest)
    }

    static func isFresh(_ event: OrbitPCEvent, now: Date) -> Bool {
        guard let date = event.date else { return true }
        let age = now.timeIntervalSince(date)
        if event.kind == "power.scheduled", age > powerScheduledMaximumAge { return false }
        return age <= maximumAge
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
