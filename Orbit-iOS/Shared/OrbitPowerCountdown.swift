import Foundation

// Windows' 30-second warning after Shut Down or Restart from Orbit (the PC's `powerCountdown`
// feature, Orbit-Windows-Agent/orbit_power_countdown.py). The answer to the action carries
// `"countdownSeconds": 30`, `/api/status` and `/api/watch/summary` report the countdown while it
// runs, and `POST /api/power/cancel` stops it. Older PCs send none of this: the apps then mark the
// PC offline right after the action, as they always did.

/// `"powerCountdown"` in `/api/status` and `/api/watch/summary`.
struct OrbitPowerCountdownReport: Codable, Equatable {
    var action: String
    var remainingSeconds: Double
    var endsAt: String?
}

/// A countdown as an app shows it, counted on the device between the PC's answers.
struct OrbitPowerCountdown: Equatable {
    static let actions: Set<String> = ["shutdown", "restart"]
    /// The scroll id of the view that shows it: pages scroll there when a countdown starts, since
    /// Shut Down and Restart usually sit further down than the countdown with Cancel.
    static let scrollID = "orbit.powerCountdown"
    /// No PC counts down longer; anything bigger is a garbled answer.
    static let longest: TimeInterval = 600

    var action: String
    var until: Date

    init(action: String, until: Date) {
        self.action = action
        self.until = until
    }

    /// `seconds` from `start`; nil for other actions or nonsense values.
    init?(action: String, seconds: Double?, from start: Date = Date()) {
        guard Self.actions.contains(action), let seconds, seconds.isFinite, seconds > 0 else { return nil }
        self.init(action: action, until: start.addingTimeInterval(min(seconds, Self.longest)))
    }

    /// From the answer to `POST /api/action/shutdown|restart`; nil when the PC doesn't count down.
    init?(action: String, response data: Data, receivedAt: Date = Date()) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        self.init(action: action, seconds: (json?["countdownSeconds"] as? NSNumber)?.doubleValue, from: receivedAt)
    }

    /// From the PC's status, counted from when the answer arrived.
    init?(_ report: OrbitPowerCountdownReport?, receivedAt: Date = Date()) {
        guard let report else { return nil }
        self.init(action: report.action, seconds: report.remainingSeconds, from: receivedAt)
    }

    /// From `"powerCountdown"` in `/api/status` read without a model (the Watch's fallback).
    init?(json: Any?, receivedAt: Date = Date()) {
        guard let json = json as? [String: Any], let action = json["action"] as? String else { return nil }
        self.init(action: action, seconds: (json["remainingSeconds"] as? NSNumber)?.doubleValue, from: receivedAt)
    }

    /// From the iPhone's message to the Watch (`relayPayload`). The end is a moment in time, so a
    /// message delivered late still ends the countdown when the PC does.
    init?(relay: Any?) {
        guard let relay = relay as? [String: Any], let action = relay["action"] as? String, Self.actions.contains(action),
              let until = (relay["until"] as? NSNumber)?.doubleValue, until.isFinite else { return nil }
        let end = Date(timeIntervalSince1970: until)
        guard end.timeIntervalSinceNow < Self.longest else { return nil }
        self.init(action: action, until: end)
    }

    var isRestart: Bool { action == "restart" }
    var symbol: String { isRestart ? "arrow.clockwise" : "power" }
    var cancelTitle: String { isRestart ? "Cancel Restart" : "Cancel Shutdown" }
    var cancelledMessage: String { isRestart ? "Restart cancelled" : "Shutdown cancelled" }

    /// Whole seconds left, rounded up ("0:27" until the last moment, never "0:00" while it runs).
    func secondsLeft(at date: Date = Date()) -> Int {
        let left = (until.timeIntervalSince(date) * 1000).rounded() / 1000
        return max(0, Int(left.rounded(.up)))
    }

    func isRunning(at date: Date = Date()) -> Bool { secondsLeft(at: date) > 0 }

    /// "0:27".
    func clock(at date: Date = Date()) -> String {
        let seconds = secondsLeft(at: date)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "Shutting down in 0:27" while it runs, "Shutting down…" once Windows has started.
    func summary(at date: Date = Date()) -> String {
        let verb = isRestart ? "Restarting" : "Shutting down"
        return isRunning(at: date) ? "\(verb) in \(clock(at: date))" : "\(verb)…"
    }

    /// For VoiceOver: "Shutting down in 27 seconds".
    func spokenSummary(at date: Date = Date()) -> String {
        let verb = isRestart ? "Restarting" : "Shutting down"
        let seconds = secondsLeft(at: date)
        guard seconds > 0 else { return "\(verb) now" }
        return "\(verb) in \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }

    /// The line under the summary.
    func detail(at date: Date = Date()) -> String {
        if isRunning(at: date) { return "Windows shows the same warning on the PC." }
        return isRestart ? "Orbit reconnects when Windows is back." : "The PC is turning off."
    }

    /// For the iPhone's message to the Watch: `["action": "shutdown", "until": 1790000030.0]`.
    var relayPayload: [String: Any] { ["action": action, "until": until.timeIntervalSince1970] }
}

/// One app's view of the countdown, kept in step with the PC.
struct OrbitPowerCountdownTracker: Equatable {
    /// After the countdown ends, "Shutting down…" stays until the PC stops answering, at most this long.
    static let finishingGrace: TimeInterval = 30

    private(set) var countdown: OrbitPowerCountdown?
    /// When this device last changed the countdown (sent the action, or cancelled it). An answer to
    /// a request that left before then can't know about the change, so it is ignored.
    private var changedAt = Date.distantPast

    /// After Shut Down or Restart was sent (with the countdown from its answer), or Cancel worked (nil).
    mutating func set(_ countdown: OrbitPowerCountdown?, at date: Date = Date()) {
        self.countdown = countdown
        changedAt = date
    }

    /// What the PC said in an answer to a request that left at `requestedAt`.
    mutating func apply(_ incoming: OrbitPowerCountdown?, requestedAt: Date, receivedAt: Date = Date()) {
        guard requestedAt >= changedAt else { return }
        if let incoming {
            // Keep the time this device counts with when it's that close, so seconds don't jump.
            if let current = countdown, current.action == incoming.action,
               abs(current.until.timeIntervalSince(incoming.until)) < 1.5 { return }
            countdown = incoming
        } else if let current = countdown, current.until.timeIntervalSince(receivedAt) > 1 {
            // Cancelled on the PC or from another device. A countdown at its end stays: the PC stops
            // listing it once Windows starts shutting down.
            countdown = nil
        }
    }

    /// The PC didn't answer. A countdown still running stays (one missed answer isn't the end);
    /// one that ended is over.
    mutating func pcUnreachable(at date: Date = Date()) {
        if let current = countdown, !current.isRunning(at: date) { countdown = nil }
    }

    /// Counting down: Cancel still works.
    func running(at date: Date = Date()) -> OrbitPowerCountdown? {
        countdown.flatMap { $0.isRunning(at: date) ? $0 : nil }
    }

    /// Running, or ended moments ago while Windows shuts down.
    func visible(at date: Date = Date()) -> OrbitPowerCountdown? {
        countdown.flatMap { $0.until.addingTimeInterval(Self.finishingGrace) > date ? $0 : nil }
    }
}
