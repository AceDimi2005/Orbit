import Foundation

// Compiled by check_review_prompt.py with Shared/OrbitReviewPrompt.swift. The clock, the calendar, the storage and
// the 2.5-second wait are all fakes: nothing is stored on this Mac and StoreKit is never called.

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition { print("FAIL: \(message) (\(file):\(line))"); exit(1) }
}

let day: TimeInterval = 86_400
let start = ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z")!
let bucharest: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
    return calendar
}()

@main
struct OrbitReviewPromptTests {
    @MainActor
    static func main() async {
        checkDays()
        checkRules()
        await checkPrompter()
        await checkBlockers()
    }
}

// MARK: - Counting days

func checkDays() {
    var record = OrbitReviewPromptRecord()
    check(record.noteOpened(on: start, calendar: bucharest), "the first day counts")
    check(!record.noteOpened(on: start.addingTimeInterval(60), calendar: bucharest), "a second launch the same day does not count")
    check(!record.noteOpened(on: start.addingTimeInterval(8 * 3600), calendar: bucharest), "nor one late in the evening")
    check(record.activeDays == 1, "one day after three launches, got \(record.activeDays)")
    // 10:00 UTC + 12 h = 00:00 in Bucharest (UTC+2): a new day there, although still the same UTC date.
    check(record.noteOpened(on: start.addingTimeInterval(12 * 3600), calendar: bucharest), "midnight in the device's time zone starts a new day")
    check(record.recentDays == ["2026-11-17", "2026-11-18"], "day stamps \(record.recentDays)")
    // The clock is set back to a day already counted, then forward again.
    check(!record.noteOpened(on: start, calendar: bucharest), "a day already counted does not count again")
    check(record.noteOpened(on: start.addingTimeInterval(3 * day), calendar: bucharest), "a later day counts")
    check(record.activeDays == 3, "three different days, got \(record.activeDays)")
    for index in 0..<30 { record.noteOpened(on: start.addingTimeInterval(TimeInterval(10 + index) * day), calendar: bucharest) }
    check(record.activeDays == 33 && record.recentDays.count == OrbitReviewPromptRecord.rememberedDays,
          "33 days, \(OrbitReviewPromptRecord.rememberedDays) remembered; got \(record.activeDays) and \(record.recentDays.count)")
    let encoded = try! JSONEncoder().encode(record)
    check(try! JSONDecoder().decode(OrbitReviewPromptRecord.self, from: encoded) == record, "the record survives a JSON round trip")
    check(OrbitReviewPromptRecord.defaultsKey == "orbit.reviewPrompt.v1", "storage key")
    print("days: launches on the same day, midnight in the local time zone, clock set back, JSON round trip: OK")
}

// MARK: - The rules

let policy = OrbitReviewPromptPolicy()

func record(days: Int, askedAt: Date? = nil, version: String? = nil) -> OrbitReviewPromptRecord {
    var record = OrbitReviewPromptRecord()
    record.activeDays = days
    record.lastRequestDate = askedAt
    record.lastRequestVersion = version
    return record
}

func decide(_ record: OrbitReviewPromptRecord, version: String = "1.1", now: Date = start, lastError: Date? = nil,
            blockers: Set<OrbitReviewPromptBlocker> = []) -> OrbitReviewPromptPolicy.Decision {
    policy.decide(record: record, version: version, now: now, lastError: lastError, blockers: blockers)
}

func checkRules() {
    check(policy.requiredActiveDays == 5 && policy.minimumDaysBetweenRequests == 120, "5 days, 120 days between requests")
    check((2...3).contains(policy.delayAfterGoodMoment), "the delay is 2–3 seconds, got \(policy.delayAfterGoodMoment)")
    // Fewer than 5 days.
    for days in 0..<5 { check(decide(record(days: days)) == .tooFewDays(days), "\(days) day(s) is too few") }
    check(decide(record(days: 5)) == .ask, "5 days, never asked: ask")
    check(decide(record(days: 40)) == .ask, "40 days: ask")
    // Demo mode and everything else on screen that must not be interrupted.
    check(decide(record(days: 9), blockers: [.demoMode]) == .blocked([.demoMode]), "never in demo mode")
    for blocker in OrbitReviewPromptBlocker.allCases {
        check(decide(record(days: 9), blockers: [blocker]) == .blocked([blocker]), "blocked by \(blocker)")
    }
    check(decide(record(days: 2), blockers: [.demoMode, .stream]) == .blocked([.demoMode, .stream]), "every blocker is reported")
    // The same version.
    check(decide(record(days: 9, askedAt: start.addingTimeInterval(-400 * day), version: "1.1")) == .alreadyAskedThisVersion,
          "at most once per version, even a year later")
    check(decide(record(days: 9, askedAt: start.addingTimeInterval(-400 * day), version: "1.1"), version: " 1.1\n") == .alreadyAskedThisVersion,
          "the version is compared without spaces")
    // 120 days between requests.
    let asked = start
    check(decide(record(days: 9, askedAt: asked, version: "1.1"), version: "1.2", now: asked.addingTimeInterval(119 * day)) == .askedRecently,
          "a new version 119 days later waits")
    check(decide(record(days: 9, askedAt: asked, version: "1.1"), version: "1.2", now: asked.addingTimeInterval(120 * day - 1)) == .askedRecently,
          "one second short of 120 days waits")
    check(decide(record(days: 9, askedAt: asked, version: "1.1"), version: "1.2", now: asked.addingTimeInterval(120 * day)) == .ask,
          "a new version 120 days later asks")
    check(decide(record(days: 9, askedAt: asked.addingTimeInterval(30 * day), version: "1.1"), version: "1.2", now: asked) == .askedRecently,
          "a request in the future (clock set back) counts as recent")
    // Errors.
    check(decide(record(days: 9), lastError: start.addingTimeInterval(-10)) == .afterError, "not right after an error")
    check(decide(record(days: 9), lastError: start.addingTimeInterval(-299)) == .afterError, "nor 5 minutes after it")
    check(decide(record(days: 9), lastError: start.addingTimeInterval(-300)) == .ask, "5 minutes after an error: ask")
    check(decide(record(days: 9), lastError: start.addingTimeInterval(600)) == .afterError, "an error in the future (clock set back) is recent")
    // No version, no request.
    check(decide(record(days: 9), version: "") == .unknownVersion, "no version: no request")
    print("rules: fewer than 5 days, demo mode and every blocker, once per version, 120 days, errors: OK")
}

// MARK: - The prompter, with a fake clock and a wait the test opens

final class MemoryStorage: OrbitReviewPromptStorage {
    var record = OrbitReviewPromptRecord()
    var saves = 0
    func load() -> OrbitReviewPromptRecord { record }
    func save(_ record: OrbitReviewPromptRecord) { self.record = record; saves += 1 }
}

/// Stands in for the 2.5-second delay: the prompter waits until the test calls `open()`.
@MainActor
final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var requestedDelays: [TimeInterval] = []
    var isWaiting: Bool { !waiting.isEmpty }
    func wait(_ seconds: TimeInterval) async {
        requestedDelays.append(seconds)
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume() }
    }
}

/// The device's clock and app version, which the tests move.
@MainActor
final class FakeSystem {
    var clock = start
    var version = "1.1"
}

@MainActor
final class Device {
    let storage = MemoryStorage()
    let gate = Gate()
    let system = FakeSystem()
    var clock: Date { get { system.clock } set { system.clock = newValue } }
    var version: String { get { system.version } set { system.version = newValue } }
    var onScreen = Set<OrbitReviewPromptBlocker>()
    var prompts = 0
    let prompter: OrbitReviewPrompter

    init() {
        let storage = storage, gate = gate, system = system
        prompter = OrbitReviewPrompter(storage: storage, version: { system.version }, now: { system.clock },
                                       calendar: { bucharest }, wait: { await gate.wait($0) })
        prompter.blockers = { [unowned self] in self.onScreen }
        prompter.attachPresenter(UUID()) { [unowned self] in self.prompts += 1 }
    }

    /// Orbit opened on `count` different days, one per day from today; the clock ends on the last.
    func open(days count: Int) {
        for _ in 0..<count {
            prompter.appOpened()
            prompter.appOpened()
            clock = clock.addingTimeInterval(day)
        }
        clock = clock.addingTimeInterval(-day)
    }

    /// A good moment, then the delay runs out.
    func goodMoment(_ moment: OrbitReviewPrompter.Moment = .connected) async {
        prompter.noteGoodMoment(moment)
        await letDelayPass()
    }

    func letDelayPass() async {
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        await prompter.settle()
    }
}

@MainActor
func checkPrompter() async {
    // Four days: nothing, not even a wait.
    let device = Device()
    device.open(days: 4)
    check(device.storage.record.activeDays == 4, "four days counted, got \(device.storage.record.activeDays)")
    device.prompter.noteGoodMoment(.deckButton)
    check(!device.prompter.isWaiting && device.gate.requestedDelays.isEmpty, "with 4 days the prompter does not even wait")
    await device.letDelayPass()
    check(device.prompts == 0, "no prompt with fewer than 5 days")

    // The fifth day: the prompt comes after the delay, not before.
    device.clock = device.clock.addingTimeInterval(day)
    device.prompter.appOpened()
    device.prompter.noteGoodMoment(.powerAction)
    for _ in 0..<10 { await Task.yield() }
    check(device.prompter.isWaiting && device.gate.isWaiting, "the prompt waits for the delay")
    check(device.gate.requestedDelays == [2.5], "the delay asked for is 2.5 s, got \(device.gate.requestedDelays)")
    check(device.prompts == 0, "no prompt before the delay is over")
    device.prompter.noteGoodMoment(.deckButton)
    await device.letDelayPass()
    check(device.prompts == 1, "one prompt after the delay, even with two good moments; got \(device.prompts)")
    check(device.storage.record.lastRequestVersion == "1.1" && device.storage.record.lastRequestDate == device.clock,
          "the request is remembered with its version and date")

    // The same version never asks again, even months later.
    device.clock = device.clock.addingTimeInterval(200 * day)
    await device.goodMoment()
    check(device.prompts == 1, "the same version does not ask twice")

    // A new version 30 days after the request waits; 120 days after it, it asks.
    let askedAt = device.storage.record.lastRequestDate!
    device.version = "1.2"
    device.clock = askedAt.addingTimeInterval(30 * day)
    await device.goodMoment()
    check(device.prompts == 1, "a new version 30 days later waits for the 120 days")
    device.clock = askedAt.addingTimeInterval(121 * day)
    await device.goodMoment()
    check(device.prompts == 2 && device.storage.record.lastRequestVersion == "1.2", "a new version 121 days later asks")
    print("prompter: under 5 days, the 2.5 s delay, one prompt per moment burst, once per version, 120 days: OK")
}

@MainActor
func checkBlockers() async {
    // Demo mode: never, however many days.
    let device = Device()
    device.open(days: 12)
    device.onScreen = [.demoMode]
    await device.goodMoment(.deckButton)
    await device.goodMoment(.powerAction)
    check(device.prompts == 0 && device.gate.requestedDelays.isEmpty, "never in demo mode")
    check(device.storage.record.lastRequestVersion == nil, "demo mode does not use up the version")

    // Something appears during the delay (an alert, a stream, the paywall…): the prompt is dropped, not kept for later.
    device.onScreen = []
    device.prompter.noteGoodMoment(.connected)
    for _ in 0..<10 { await Task.yield() }
    device.onScreen = [.alert]
    await device.letDelayPass()
    check(device.prompts == 0 && device.storage.record.lastRequestDate == nil, "an alert during the delay drops the prompt")
    device.onScreen = []
    await device.letDelayPass()
    check(device.prompts == 0, "a dropped prompt does not come back by itself")

    // The paywall pauses it (counted, so two copies need two resumes) and drops a waiting prompt.
    device.prompter.noteGoodMoment(.connected)
    for _ in 0..<10 { await Task.yield() }
    device.prompter.pause(.paywall)
    check(!device.prompter.isWaiting, "the paywall drops a waiting prompt")
    device.prompter.pause(.paywall)
    device.prompter.resume(.paywall)
    check(device.prompter.decision() == .blocked([.paywall]), "one paywall is still open")
    device.prompter.resume(.paywall)
    device.prompter.resume(.paywall)
    check(device.prompter.decision() == .ask, "both closed (an extra resume is harmless)")
    await device.letDelayPass()
    check(device.prompts == 0, "no prompt from the dropped moment")

    // An error during the delay drops it; good moments in the next 5 minutes do nothing; after that they ask.
    device.prompter.noteGoodMoment(.connected)
    for _ in 0..<10 { await Task.yield() }
    device.prompter.noteError()
    check(!device.prompter.isWaiting, "an error drops a waiting prompt")
    await device.letDelayPass()
    check(device.prompts == 0, "no prompt after an error")
    device.clock = device.clock.addingTimeInterval(4 * 60)
    await device.goodMoment()
    check(device.prompts == 0, "no prompt 4 minutes after an error")
    device.clock = device.clock.addingTimeInterval(61)
    await device.goodMoment()
    check(device.prompts == 1, "5 minutes after the error, a good moment asks")

    // No root view to show it (Mac main window closed): not in front.
    let other = Device()
    other.open(days: 6)
    let id = UUID()
    other.prompter.attachPresenter(id) {}
    other.prompter.detachPresenter(UUID())
    check(other.prompter.decision() == .ask, "detaching another view keeps the presenter")
    other.prompter.detachPresenter(id)
    check(other.prompter.decision() == .blocked([.notInFront]), "without a presenter: not in front")
    print("prompter: demo mode, a blocker or the paywall during the delay, errors and the 5-minute pause, no window: OK")
}
