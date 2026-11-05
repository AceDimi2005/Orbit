import Foundation
import os

// When Orbit asks for an App Store rating, on iPhone, iPad and Mac (Apple TV and Apple Watch have no such prompt).
//
// Every rule must hold:
// - Orbit was opened on at least 5 different days (days, not launches), counted on this device only: the record
//   lives in this device's UserDefaults and is not part of the iCloud settings sync;
// - something just went right: a connection to a real PC, or a Buttons deck button or power action that worked;
// - nothing is in the way: demo mode, onboarding, a stream (or the presentation remote, webcam, desktop preview),
//   an alert, the Orbit Pro paywall, Windows' Shut Down/Restart countdown, Orbit not in front, or an error in
//   the last 5 minutes;
// - this version (CFBundleShortVersionString) never asked, and the last request is at least 120 days old.
// The request goes out 2.5 seconds after the good moment, once the same checks pass again. StoreKit then decides
// whether the prompt really appears (at most three times a year; never in TestFlight builds).
//
// This file holds the rules and the timing only (Foundation, no UI), so Tests/check_review_prompt.py can run it.
// The StoreKit call and the platform checks are in OrbitReviewPromptHost.swift.

/// Something on screen that a rating prompt must never interrupt.
enum OrbitReviewPromptBlocker: String, CaseIterable, Sendable {
    case demoMode
    case onboarding
    /// A stream, Second Screen, the desktop preview, the presentation remote or the webcam.
    case stream
    /// An alert, a confirmation dialog or (Mac) a sheet over the window.
    case alert
    case paywall
    /// Windows counts down to Shut Down or Restart: its Cancel button must stay in reach.
    case powerCountdown
    /// Orbit is in the background, or (Mac) its main window is not the one in front.
    case notInFront
}

/// What this device remembers. Stored in UserDefaults under `defaultsKey`; never synced through iCloud.
struct OrbitReviewPromptRecord: Codable, Equatable, Sendable {
    static let defaultsKey = "orbit.reviewPrompt.v1"
    /// How many recent days are kept to recognise a day already counted.
    static let rememberedDays = 14

    /// Different days on which Orbit was opened.
    var activeDays = 0
    /// The latest of those days ("2026-11-04"), so a clock set back and forth does not count a day twice.
    var recentDays: [String] = []
    /// When Orbit last asked StoreKit for the prompt, and in which version.
    var lastRequestDate: Date?
    var lastRequestVersion: String?

    /// Counts the day of `date` once. Returns whether it was a new day.
    @discardableResult
    mutating func noteOpened(on date: Date, calendar: Calendar) -> Bool {
        let day = Self.dayStamp(date, calendar: calendar)
        guard !recentDays.contains(day) else { return false }
        activeDays += 1
        recentDays.append(day)
        if recentDays.count > Self.rememberedDays { recentDays.removeFirst(recentDays.count - Self.rememberedDays) }
        return true
    }

    mutating func noteRequested(version: String, at date: Date) {
        lastRequestDate = date
        lastRequestVersion = version
    }

    static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The rules. Pure: the same inputs always give the same answer.
struct OrbitReviewPromptPolicy: Equatable, Sendable {
    var requiredActiveDays = 5
    var minimumDaysBetweenRequests = 120
    /// No prompt this soon after something failed.
    var quietPeriodAfterError: TimeInterval = 5 * 60
    /// The prompt waits this long after the good moment, so it never lands on top of an animation.
    var delayAfterGoodMoment: TimeInterval = 2.5

    enum Decision: Equatable, Sendable {
        case ask
        case blocked(Set<OrbitReviewPromptBlocker>)
        case afterError
        case unknownVersion
        case tooFewDays(Int)
        case alreadyAskedThisVersion
        /// The last request is younger than `minimumDaysBetweenRequests` (or in the future: the clock moved back).
        case askedRecently
    }

    func decide(record: OrbitReviewPromptRecord, version: String, now: Date, lastError: Date?,
                blockers: Set<OrbitReviewPromptBlocker>) -> Decision {
        if !blockers.isEmpty { return .blocked(blockers) }
        // An error "in the future" means the clock moved back: still treated as recent.
        if let lastError, now.timeIntervalSince(lastError) < quietPeriodAfterError { return .afterError }
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return .unknownVersion }
        guard record.activeDays >= requiredActiveDays else { return .tooFewDays(record.activeDays) }
        if record.lastRequestVersion == version { return .alreadyAskedThisVersion }
        if let last = record.lastRequestDate,
           now.timeIntervalSince(last) < TimeInterval(minimumDaysBetweenRequests) * 86_400 { return .askedRecently }
        return .ask
    }
}

/// Where the record is kept.
protocol OrbitReviewPromptStorage {
    func load() -> OrbitReviewPromptRecord
    func save(_ record: OrbitReviewPromptRecord)
}

/// This device's UserDefaults (JSON under `OrbitReviewPromptRecord.defaultsKey`).
struct OrbitReviewPromptDefaultsStorage: OrbitReviewPromptStorage {
    func load() -> OrbitReviewPromptRecord {
        guard let data = UserDefaults.standard.data(forKey: OrbitReviewPromptRecord.defaultsKey),
              let record = try? JSONDecoder().decode(OrbitReviewPromptRecord.self, from: data) else { return OrbitReviewPromptRecord() }
        return record
    }

    func save(_ record: OrbitReviewPromptRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: OrbitReviewPromptRecord.defaultsKey)
    }
}

/// Counts the days, hears about good moments and errors, and asks the root view to show the prompt when the
/// policy allows it. The app tells it what is on screen through `blockers` and how to ask through a presenter
/// (both set by `orbitReviewPromptHost`).
@MainActor
final class OrbitReviewPrompter {
    static let shared = OrbitReviewPrompter()

    /// What just went right.
    enum Moment: String, Sendable {
        /// The selected PC (a real one, not demo mode) answered after being offline or not yet connected.
        case connected
        case deckButton
        case powerAction
    }

    /// Power actions whose success is a good moment. Media keys, volume and the like are not: they come in
    /// bursts while the user is busy with the remote.
    static let powerActions: Set<String> = ["lock", "sleep", "shutdown", "restart"]

    var policy = OrbitReviewPromptPolicy()
    /// What the app has on screen right now that the prompt must not interrupt.
    var blockers: @MainActor () -> Set<OrbitReviewPromptBlocker> = { [] }

    private let storage: OrbitReviewPromptStorage
    private let version: @MainActor () -> String
    private let now: @MainActor () -> Date
    private let calendar: @MainActor () -> Calendar
    private let wait: @MainActor (TimeInterval) async throws -> Void
    private let log = Logger(subsystem: "com.dimitrie.orbit", category: "ReviewPrompt")
    private var presenter: (id: UUID, present: @MainActor () -> Void)?
    private var pauses: [OrbitReviewPromptBlocker: Int] = [:]
    private var pending: Task<Void, Never>?
    private(set) var lastErrorDate: Date?

    init(storage: OrbitReviewPromptStorage = OrbitReviewPromptDefaultsStorage(),
         version: @escaping @MainActor () -> String = {
             Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
         },
         now: @escaping @MainActor () -> Date = { Date() },
         calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
         wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.storage = storage
        self.version = version
        self.now = now
        self.calendar = calendar
        self.wait = wait
    }

    var record: OrbitReviewPromptRecord { storage.load() }
    /// A good moment is waiting out its delay.
    var isWaiting: Bool { pending != nil }

    /// Orbit came to the front: counts today once.
    func appOpened() {
        var record = storage.load()
        if record.noteOpened(on: now(), calendar: calendar()) {
            storage.save(record)
            log.debug("Opened on a new day: \(record.activeDays) day(s)")
        }
    }

    /// Something failed. No prompt for a while, and a prompt waiting out its delay is dropped.
    func noteError() {
        lastErrorDate = now()
        cancelPending()
    }

    /// Something went right: asks for the prompt after `policy.delayAfterGoodMoment` if every rule holds then too.
    func noteGoodMoment(_ moment: Moment) {
        guard pending == nil else { return }
        let first = decision()
        guard first == .ask else {
            log.debug("\(moment.rawValue, privacy: .public): no prompt (\(String(describing: first), privacy: .public))")
            return
        }
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.wait(self.policy.delayAfterGoodMoment) } catch { return }
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.requestIfStillAllowed(after: moment)
        }
    }

    /// The decision for right now.
    func decision() -> OrbitReviewPromptPolicy.Decision {
        policy.decide(record: storage.load(), version: version(), now: now(), lastError: lastErrorDate, blockers: currentBlockers())
    }

    func currentBlockers() -> Set<OrbitReviewPromptBlocker> {
        var result = blockers()
        for (blocker, count) in pauses where count > 0 { result.insert(blocker) }
        if presenter == nil { result.insert(.notInFront) }
        return result
    }

    /// A screen that must not be interrupted (the paywall, onboarding…) is on screen. Counted: every
    /// `pause` needs one `resume`.
    func pause(_ blocker: OrbitReviewPromptBlocker) {
        pauses[blocker, default: 0] += 1
        cancelPending()
    }

    func resume(_ blocker: OrbitReviewPromptBlocker) {
        pauses[blocker] = max(0, (pauses[blocker] ?? 0) - 1)
    }

    /// The root view that shows the prompt. A newer one replaces the older; `detachPresenter` only removes its own.
    func attachPresenter(_ id: UUID, present: @escaping @MainActor () -> Void) {
        presenter = (id, present)
    }

    func detachPresenter(_ id: UUID) {
        guard presenter?.id == id else { return }
        presenter = nil
        cancelPending()
    }

    /// For tests: waits until a good moment's delay is over and its request (if any) went out.
    func settle() async {
        await pending?.value
    }

    private func requestIfStillAllowed(after moment: Moment) {
        let final = decision()
        guard final == .ask, let presenter = self.presenter else {
            log.debug("\(moment.rawValue, privacy: .public): prompt dropped after the delay (\(String(describing: final), privacy: .public))")
            return
        }
        var record = storage.load()
        record.noteRequested(version: version().trimmingCharacters(in: .whitespacesAndNewlines), at: now())
        storage.save(record)
        log.info("\(moment.rawValue, privacy: .public): asking StoreKit for the rating prompt")
        presenter.present()
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
