import SwiftUI
import UserNotifications
import WatchKit

// Present page (DESIGN F8): a slide show remote on the wrist. Tap = next slide, Digital Crown = next /
// previous (one detent per slide), slide x / y and the talk time, with optional haptic reminders every
// few minutes.
//
// Commands go through the iPhone (bridge command `presentation`, see Orbit/OrbitWatchPresentationRelay.swift)
// when it is reachable, otherwise straight to the PC (`OrbitWatchHTTPClient.presentationAction`). An
// action is sent once on one route: an unanswered slide change may already have happened. Reads
// (`action: "state"`) may try the other route.

// MARK: - Store

@MainActor
final class WatchPresentationStore: ObservableObject {
    /// Tab tag of the Present page in `OrbitWatchRootView` (`orbitwatch://present` opens it).
    static let tab = 5
    static let reminderChoices = [1, 2, 3, 5, 10, 15, 20, 30]
    static let maxQueued = 3
    /// A tap still waiting after this long is dropped with the ones after it, as on iPhone. A slide change takes
    /// well under a second through the iPhone relay, so quick Crown turns still all go out.
    static let maxQueueWait: TimeInterval = 2.5
    /// The slide show on the page counts as not up to date after this many failed reads in a row, or once a
    /// failed read comes this long after the last good one.
    static let staleAfterFailedReads = 2
    static let staleAfterSeconds: TimeInterval = 6

    enum Phase: Equatable {
        case idle, loading, ready
        /// The PC's agent has no presentation remote.
        case unsupported
        /// No PC to talk to: the iPhone isn't nearby and the Watch has no direct credentials.
        case needsPhone
        case failed(String)
    }

    @Published private(set) var state: OrbitPresentationState?
    @Published private(set) var phase: Phase = .idle
    /// The iPhone is in demo mode: a pretend deck, nothing is sent.
    @Published private(set) var isDemo = false
    @Published private(set) var timer = OrbitPresentationTimer() {
        didSet { if timer != oldValue { saveTalk() } }
    }
    @Published var message: String?
    /// The slide show shown is from an earlier read: the last reads failed (iPhone or PC gone). Says why.
    @Published private(set) var staleReason: String?
    @Published private(set) var pending = 0
    /// "Via iPhone" or "Direct to PC" for the last exchange.
    @Published private(set) var route = ""
    @Published var remindersOn: Bool {
        didSet {
            UserDefaults.standard.set(remindersOn, forKey: Self.remindersKey)
            if remindersOn && !oldValue {
                resumeStoppedReminders()
                Task { await requestReminderPermission() }
            }
            updateReminders()
        }
    }
    @Published var reminderMinutes: Int {
        didSet {
            UserDefaults.standard.set(reminderMinutes, forKey: Self.minutesKey)
            if reminderMinutes != oldValue { resumeStoppedReminders() }
            updateReminders()
        }
    }
    /// nil until asked; false when notifications are off for Orbit on this Watch (then the page taps you
    /// itself while it is open).
    @Published private(set) var notificationsAllowed: Bool?
    /// When the talk started whose reminders "Stop Reminders" (on a reminder) ended.
    @Published private(set) var remindersStoppedFor: Date?

    private var demo = OrbitPresentationDemo()
    private(set) var pcID = "" {
        didSet { if pcID != oldValue { saveTalk() } }
    }
    private var queue = OrbitPresentationQueue(capacity: WatchPresentationStore.maxQueued,
                                                maxWait: WatchPresentationStore.maxQueueWait)
    private var queueGeneration = 0
    private var failedReads = 0
    private var lastGoodReadAt: Date?
    private var actionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    /// Reminders counted when the page last checked (nil: not counted yet), for the in-app taps.
    private var lastReminderCount: Int?

    private static let remindersKey = "Orbit.WatchPresentReminders"
    private static let minutesKey = "Orbit.WatchPresentReminderMinutes"
    /// The running talk timer and its PC. watchOS may end Orbit in the background in the middle of a talk;
    /// the next launch picks the talk up again, so the page and the planned reminders still agree.
    private static let talkKey = "Orbit.WatchPresentTalk.v1"
    /// A talk timer older than this is not picked up again (it was most likely never stopped).
    private static let maxRestoredTalk: TimeInterval = 6 * 3600

    private struct SavedTalk: Codable {
        var pcID: String
        var timer: OrbitPresentationTimer
    }

    init() {
        remindersOn = UserDefaults.standard.bool(forKey: Self.remindersKey)
        let minutes = UserDefaults.standard.integer(forKey: Self.minutesKey)
        reminderMinutes = Self.reminderChoices.contains(minutes) ? minutes : 5
        remindersStoppedFor = WatchPresentationReminders.stoppedTalkStart
        restoreTalk()
        let reminders = WatchPresentationReminders.shared
        reminders.activate()
        reminders.onStop = { [weak self] talkStart in self?.remindersStopped(forTalkStartedAt: talkStart) }
        // Plans the reminders of a talk picked up again, or removes the ones an earlier run left behind.
        updateReminders()
        if remindersOn { Task { await refreshPermission() } }
    }

    private func restoreTalk() {
        guard let data = UserDefaults.standard.data(forKey: Self.talkKey),
              let saved = try? JSONDecoder().decode(SavedTalk.self, from: data),
              !saved.pcID.isEmpty, saved.timer.isRunning,
              let elapsed = saved.timer.elapsed(at: Date()), elapsed < Self.maxRestoredTalk else {
            UserDefaults.standard.removeObject(forKey: Self.talkKey)
            return
        }
        pcID = saved.pcID
        timer = saved.timer
    }

    /// Keeps a running timer of a real PC's talk (never the demo deck's).
    private func saveTalk() {
        let defaults = UserDefaults.standard
        guard !isDemo, !pcID.isEmpty, pcID != "demo", timer.isRunning,
              let data = try? JSONEncoder().encode(SavedTalk(pcID: pcID, timer: timer)) else {
            defaults.removeObject(forKey: Self.talkKey)
            return
        }
        defaults.set(data, forKey: Self.talkKey)
    }

    /// Reads the iPhone's demo flag from its sync payload (older iPhone apps send it too).
    func applyPhonePayload(_ payload: [String: Any]) {
        guard let demoMode = payload["isDemoMode"] as? Bool, demoMode != isDemo else { return }
        cancelQueue()
        isDemo = demoMode
        demo = OrbitPresentationDemo()
        state = nil
        markRead()
        timer.reset()
        phase = .idle
        message = nil
        updateReminders()
    }

    func apply(_ new: OrbitPresentationState, pcID: String, route: String) {
        if pcID != self.pcID {
            // Another PC: forget the old one's slide show, and don't send it the taps still waiting.
            if !self.pcID.isEmpty { cancelQueue() }
            self.pcID = pcID
            timer.reset()
            state = nil
        }
        let old = state
        if old != new { state = new }
        markRead(Date())
        if phase != .ready { phase = .ready }
        if self.route != route { self.route = route }
        let now = Date()
        updateTimer { $0.sync(with: new, now: now) }
        if let old, new.isShowingSlide, !old.isShowingSlide || old.slide != new.slide {
            WKInterfaceDevice.current().play(.click)
        }
        updateReminders()
    }

    func readFailed(_ phase: Phase) {
        // Keep the last state on screen; a busy PowerPoint or a slow iPhone is usually brief. After a couple of
        // failed reads in a row (or one long after the last good read) the page says it isn't up to date.
        if case .failed(let reason) = phase, state != nil {
            failedReads += 1
            let longAgo = lastGoodReadAt.map { Date().timeIntervalSince($0) > Self.staleAfterSeconds } ?? true
            if failedReads >= Self.staleAfterFailedReads || longAgo, staleReason != reason { staleReason = reason }
            return
        }
        if self.phase != phase { self.phase = phase }
    }

    /// A good read (`at`), or nothing read yet (nil: another PC, demo mode switched).
    private func markRead(_ at: Date? = nil) {
        failedReads = 0
        lastGoodReadAt = at
        if staleReason != nil { staleReason = nil }
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Demo

    func demoTick() {
        apply(demo.state(at: Date()), pcID: "demo", route: "Demo")
    }

    func performDemo(_ action: OrbitPresentationAction, slide: Int?) {
        do {
            let reply = try demo.perform(action, slide: slide, now: Date())
            let now = Date()
            updateTimer { $0.note(action, via: reply.via, now: now) }
            if let state = reply.presentation { apply(state, pcID: "demo", route: "Demo") }
            if !action.isMove { show(reply.detail) }
        } catch let refusal as OrbitPresentationDemo.Refusal {
            WKInterfaceDevice.current().play(.failure)
            show(refusal.message)
        } catch {
            show(error.localizedDescription)
        }
    }

    // MARK: Action queue

    /// Adds an action; returns false when too many are already waiting (fast Crown turns). Taps waiting behind
    /// an action that failed (`dropWaiting`) or took longer than `maxQueueWait` are not sent.
    func enqueue(_ action: OrbitPresentationAction, slide: Int?, run: @escaping (OrbitPresentationAction, Int?) async -> Void) -> Bool {
        guard queue.append(action, slide: slide, now: Date()) else { return false }
        pending = queue.count
        guard actionTask == nil else { return true }
        let generation = queueGeneration
        actionTask = Task { [weak self] in
            while let self, generation == self.queueGeneration, let next = self.queue.first, !Task.isCancelled {
                await run(next.action, next.slide)
                // The queue was cleared meanwhile (another PC, demo mode): leave the new one alone.
                guard generation == self.queueGeneration else { return }
                let skipped = self.queue.finishFirst(now: Date())
                self.pending = self.queue.count
                if skipped > 0 {
                    WKInterfaceDevice.current().play(.retry)
                    // The PC took a while: short enough for the two-line caption.
                    self.show("\(OrbitPresentationText.skippedTapsShort(skipped)) Check the slide, then tap again.")
                }
            }
            if let self, generation == self.queueGeneration { self.actionTask = nil }
        }
        return true
    }

    /// The action in flight failed or may have happened anyway: the taps waiting behind it are dropped (they were
    /// made before its outcome could be seen). Returns how many.
    func dropWaiting() -> Int {
        let dropped = queue.dropWaiting()
        pending = queue.count
        return dropped
    }

    func cancelQueue() {
        queueGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        queue.removeAll()
        pending = 0
    }

    func noteSent(_ action: OrbitPresentationAction, reply: OrbitPresentationActionReply?) {
        let now = Date()
        updateTimer { $0.note(action, via: reply?.via ?? "keys", now: now) }
        updateReminders()
    }

    // MARK: Timer and reminders

    /// Changes the talk timer, publishing only a real change (every read applies the PC's show time).
    private func updateTimer(_ change: (inout OrbitPresentationTimer) -> Void) {
        var copy = timer
        change(&copy)
        if copy != timer { timer = copy }
    }

    /// "Restart timer": from zero now. During PowerPoint's show it is the Watch's own timer until that show ends,
    /// so the next read doesn't put PowerPoint's show time back (and the reminders count from now).
    func restartTimer() {
        let now = Date()
        updateTimer { $0.startByHand(now: now) }
        lastReminderCount = nil
        updateReminders()
    }

    func resetTimer() {
        updateTimer { $0.resetByHand() }
        lastReminderCount = nil
        updateReminders()
    }

    /// "Stop Reminders" was chosen on a reminder of this talk. A new start of the timer, another interval
    /// or turning the switch on again brings them back. (The PC's show time moves the timer's start by at
    /// most a second or two, see `OrbitPresentationTimer.resyncTolerance`.)
    var remindersStoppedForThisTalk: Bool {
        guard let stopped = remindersStoppedFor, let start = timer.startedAt else { return false }
        return abs(stopped.timeIntervalSince(start)) < 5
    }

    /// "Stop Reminders" on a reminder; `WatchPresentationReminders` already removed the planned ones.
    private func remindersStopped(forTalkStartedAt start: Date?) {
        remindersStoppedFor = start ?? timer.startedAt
        updateReminders()
    }

    private func resumeStoppedReminders() {
        guard remindersStoppedFor != nil else { return }
        remindersStoppedFor = nil
        WatchPresentationReminders.clearStopped()
    }

    private func updateReminders() {
        WatchPresentationReminders.shared.update(startedAt: timer.startedAt, running: timer.isRunning,
                                                 minutes: reminderMinutes, enabled: remindersOn && !remindersStoppedForThisTalk)
    }

    /// Called about every second while the page is open. Without notification permission the page taps
    /// the wrist itself at each reminder (only while Orbit is open).
    func checkInAppReminder(now: Date) {
        guard remindersOn, !remindersStoppedForThisTalk, notificationsAllowed == false, timer.isRunning,
              let elapsed = timer.elapsed(at: now) else {
            lastReminderCount = nil
            return
        }
        let count = Int(elapsed / TimeInterval(reminderMinutes * 60))
        guard let last = lastReminderCount else {
            lastReminderCount = count
            return
        }
        if count > last {
            lastReminderCount = count
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func requestReminderPermission() async {
        notificationsAllowed = await WatchPresentationReminders.shared.requestAuthorization()
        updateReminders()
    }

    private func refreshPermission() async {
        notificationsAllowed = await WatchPresentationReminders.shared.isAuthorized()
    }
}

// MARK: - Reminders

/// Haptic reminders every N minutes of talk time, scheduled as local notifications so they arrive with the
/// wrist down and Orbit in the background. While Orbit is in front, the delegate plays the haptic instead
/// of showing a banner over the page.
final class WatchPresentationReminders: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = WatchPresentationReminders()
    static let prefix = "orbit.present.reminder."
    static let categoryID = "orbit.present.reminder"
    static let stopActionID = "orbit.present.reminder.stop"
    /// Reminders planned at a time (watchOS keeps 64 pending per app). While Orbit runs, the window moves
    /// forward at every reminder; with the wrist down the ones already planned still arrive.
    static let slots = 48
    /// No reminder is planned further ahead than this.
    static let horizon: TimeInterval = 3 * 3600
    static let identifiers = (0..<slots).map { prefix + String($0) }
    /// When the talk started whose reminders "Stop Reminders" ended (seconds since 1970). Written here, so it
    /// also works when watchOS starts Orbit in the background just to deliver that answer.
    private static let stoppedKey = "Orbit.WatchPresentRemindersStoppedFor"
    /// Each reminder carries the start of its talk.
    private static let talkStartKey = "talkStart"

    /// "Stop Reminders" was chosen on a reminder of the talk that started then.
    @MainActor var onStop: ((Date?) -> Void)?
    /// What is planned: nil until the first update after launch (an earlier run may have left reminders
    /// pending), "" when nothing is.
    @MainActor private var signature: String?
    @MainActor private var activated = false

    static var stoppedTalkStart: Date? {
        (UserDefaults.standard.object(forKey: stoppedKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func clearStopped() {
        UserDefaults.standard.removeObject(forKey: stoppedKey)
    }

    /// Called from `OrbitWatchApp.init` (before launch finishes, as the delegate of a notification answer
    /// must be) and again by the Present page's store.
    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            // Keeps any other category the Watch app registers.
            let center = UNUserNotificationCenter.current()
            let stop = UNNotificationAction(identifier: Self.stopActionID, title: "Stop Reminders", options: [])
            let category = UNNotificationCategory(identifier: Self.categoryID, actions: [stop], intentIdentifiers: [])
            let existing = await center.notificationCategories()
            center.setNotificationCategories(existing.filter { $0.identifier != Self.categoryID }.union([category]))
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Plans the reminders again when the timer, the interval, the switch or the next reminder changed (it is
    /// called on every read of the slide show, so the window keeps moving while Orbit runs).
    @MainActor
    func update(startedAt: Date?, running: Bool, minutes: Int, enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        guard enabled, running, let startedAt, minutes > 0 else {
            if signature != "" {
                // Also right after launch: an earlier run's reminders must not outlive its talk.
                signature = ""
                center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
                center.removeDeliveredNotifications(withIdentifiers: Self.identifiers)
            }
            return
        }
        let plan = OrbitPresentationReminderPlan.upcoming(startedAt: startedAt, now: Date(), minutes: minutes,
                                                          limit: Self.slots, horizon: Self.horizon)
        let wanted = "\(Int(startedAt.timeIntervalSince1970.rounded()))-\(minutes)-\(plan.first?.number ?? 0)"
        guard wanted != signature else { return }
        signature = wanted
        center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
        for (slot, reminder) in plan.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Presentation"
            content.body = "\(OrbitPresentationText.spokenDuration(TimeInterval(reminder.number * minutes * 60))) since the slide show started."
            content.sound = .default
            content.threadIdentifier = "orbit.present"
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.talkStartKey: startedAt.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.delay), repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + String(slot), content: content, trigger: trigger))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.identifier.hasPrefix(Self.prefix) else {
            completionHandler([.banner, .sound])
            return
        }
        DispatchQueue.main.async { WKInterfaceDevice.current().play(.notification) }
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        guard response.actionIdentifier == Self.stopActionID, content.categoryIdentifier == Self.categoryID else {
            completionHandler()
            return
        }
        // Done right here: the Present page's store may not exist yet (Orbit started just for this answer).
        let talkStart = content.userInfo[Self.talkStartKey] as? Double
        if let talkStart { UserDefaults.standard.set(talkStart, forKey: Self.stoppedKey) }
        center.removePendingNotificationRequests(withIdentifiers: Self.identifiers)
        center.removeDeliveredNotifications(withIdentifiers: Self.identifiers)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.signature = ""
                self.onStop?(talkStart.map(Date.init(timeIntervalSince1970:)))
            }
        }
        completionHandler()
    }
}

// MARK: - Talking to the PC

private struct WatchPresentationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension OrbitWatchViewModel {
    /// One read of the slide show (iPhone first, then the PC directly).
    func refreshPresentation() async {
        let store = presentation
        if store.isDemo { store.demoTick(); return }
        guard !selectedPCID.isEmpty || hasDirectCredentials else { store.readFailed(.needsPhone); return }
        let destination = target
        var phoneError: Error?
        if phoneCanRelay {
            do {
                let reply = try await relayPresentation("state", slide: nil, to: destination)
                guard target == destination else { return }
                if let state = reply.state {
                    store.apply(state, pcID: destination.id, route: "Via iPhone")
                    return
                }
            } catch let error as WatchPresentationRelayFailure {
                guard target == destination else { return }
                switch error {
                case .olderAgent: store.readFailed(.unsupported); return
                case .olderPhone: break // read directly below
                case .noAnswer: phoneError = error
                case .failed(let message): phoneError = WatchPresentationError(message)
                }
            } catch {
                phoneError = error
            }
        }
        guard destination.hasCredentials else {
            if let phoneError { store.readFailed(.failed(Self.presentationMessage(phoneError))) } else { store.readFailed(.needsPhone) }
            return
        }
        guard destination.hasSecureTLS else {
            store.readFailed(.failed("The presentation remote needs Orbit's encrypted connection. Pair the PC again on iPhone."))
            return
        }
        do {
            let data = try await client(for: destination).presentationState()
            let state = try JSONDecoder().decode(OrbitPresentationState.self, from: data)
            guard target == destination else { return }
            store.apply(state, pcID: destination.id, route: "Direct to PC")
        } catch OrbitWatchHTTPError.presentationUnavailable {
            guard target == destination else { return }
            store.readFailed(.unsupported)
        } catch {
            guard target == destination else { return }
            store.readFailed(.failed(Self.presentationMessage(phoneError ?? error)))
        }
    }

    /// Tap, Crown detent or a button on the More sheet.
    func sendPresentation(_ action: OrbitPresentationAction, slide: Int? = nil) {
        let store = presentation
        if store.isDemo {
            store.performDemo(action, slide: slide)
            return
        }
        guard canControlPC else {
            store.show("Open Orbit on your nearby iPhone, or pair your PC there first.")
            WKInterfaceDevice.current().play(.failure)
            return
        }
        let accepted = store.enqueue(action, slide: slide) { [weak self] action, slide in
            await self?.performPresentation(action, slide: slide)
        }
        if !accepted { WKInterfaceDevice.current().play(.retry) }
    }

    private func performPresentation(_ action: OrbitPresentationAction, slide: Int?) async {
        let store = presentation
        let destination = target
        do {
            var reply: OrbitPresentationActionReply?
            var route = "Direct to PC"
            if phoneCanRelay {
                do {
                    let relayed = try await relayPresentation(action.rawValue, slide: slide, to: destination)
                    reply = OrbitPresentationActionReply(action: action.rawValue, via: relayed.via, detail: relayed.detail,
                                                         presentation: relayed.state)
                    route = "Via iPhone"
                } catch WatchPresentationRelayFailure.olderPhone {
                    // The iPhone app doesn't know this command yet, so nothing ran there: go direct.
                    reply = try await directPresentationAction(action, slide: slide, to: destination)
                }
            } else {
                reply = try await directPresentationAction(action, slide: slide, to: destination)
            }
            guard target == destination else { return }
            store.noteSent(action, reply: reply)
            if let state = reply?.presentation {
                store.apply(state, pcID: destination.id, route: route)
            } else {
                Task { await refreshPresentation() }
            }
            if !action.isMove, let detail = reply?.detail, !detail.isEmpty { store.show(detail) }
            if action.isMove, reply?.presentation?.isShowingSlide != true { WKInterfaceDevice.current().play(.click) }
        } catch {
            guard target == destination else { return }
            // Taps made while this one was on its way aren't sent after a failure (the slide may have changed).
            let skipped = store.dropWaiting()
            if case WatchPresentationRelayFailure.olderAgent = error { store.readFailed(.unsupported) }
            if case OrbitWatchHTTPError.presentationUnavailable = error { store.readFailed(.unsupported) }
            let message = Self.presentationMessage(error, action: action)
            // The skipped count first: the caption has two lines.
            store.show(skipped > 0 ? "\(OrbitPresentationText.skippedTapsShort(skipped)) \(message)" : message)
            WKInterfaceDevice.current().play(.failure)
            Task { await refreshPresentation() }
        }
    }

    private func directPresentationAction(_ action: OrbitPresentationAction, slide: Int?,
                                          to destination: OrbitWatchControlTarget) async throws -> OrbitPresentationActionReply? {
        guard destination.hasCredentials else { throw WatchPresentationError("Open Orbit on your nearby iPhone.") }
        guard destination.hasSecureTLS else {
            throw WatchPresentationError("The presentation remote needs Orbit's encrypted connection. Pair the PC again on iPhone.")
        }
        let data = try await client(for: destination).presentationAction(action.rawValue, slide: slide)
        return try? JSONDecoder().decode(OrbitPresentationActionReply.self, from: data)
    }

    fileprivate struct RelayedPresentation {
        var state: OrbitPresentationState?
        var via = ""
        var detail = ""
    }

    fileprivate func relayPresentation(_ action: String, slide: Int?, to destination: OrbitWatchControlTarget) async throws -> RelayedPresentation {
        var message: [String: Any] = [
            "cmd": "presentation", "action": action, "pcID": destination.id, "host": destination.host,
            "expiresAt": Date().addingTimeInterval(5).timeIntervalSince1970
        ]
        if let slide { message["slide"] = slide }
        let reply: [String: Any]
        do {
            reply = try await sendPhoneMessage(message, timeout: action == "state" ? 7 : 12)
        } catch {
            throw WatchPresentationRelayFailure.noAnswer
        }
        switch reply["status"] as? String {
        case "sent":
            guard reply["pcID"] as? String == destination.id else {
                throw WatchPresentationRelayFailure.failed("Your iPhone didn't confirm the slide show command. Update Orbit on both devices.")
            }
            var relayed = RelayedPresentation()
            if let data = reply["presentation"] as? Data { relayed.state = try? JSONDecoder().decode(OrbitPresentationState.self, from: data) }
            relayed.via = reply["via"] as? String ?? ""
            relayed.detail = reply["detail"] as? String ?? ""
            return relayed
        case "unknown_cmd", "unavailable":
            throw WatchPresentationRelayFailure.olderPhone
        default:
            if reply["code"] as? String == "olderAgent" { throw WatchPresentationRelayFailure.olderAgent }
            throw WatchPresentationRelayFailure.failed(reply["message"] as? String ?? "Your iPhone couldn't reach the slide show. Try again.")
        }
    }

    fileprivate static func presentationMessage(_ error: Error, action: OrbitPresentationAction? = nil) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return action == nil ? "Your PC didn't answer in time." : "Your PC didn't answer in time. The slide may still have changed."
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach your PC. Wake it or check its connection."
            default: break
            }
        }
        if case WatchPresentationRelayFailure.olderAgent = error { return OrbitPresentationText.olderAgent }
        if case WatchPresentationRelayFailure.noAnswer = error, action != nil {
            return "Your iPhone didn't answer. The slide may still have changed."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private enum WatchPresentationRelayFailure: LocalizedError {
    case olderAgent
    /// The iPhone app doesn't know the `presentation` command (or has no PC loaded); nothing ran there.
    case olderPhone
    /// No reply from the iPhone in time (or WatchConnectivity failed): an action may still have reached the PC.
    case noAnswer
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .olderAgent: return OrbitPresentationText.olderAgent
        case .olderPhone: return "Update Orbit on your iPhone to present from your watch."
        case .noAnswer: return "Your iPhone didn't answer in time."
        case .failed(let message): return message
        }
    }
}

// MARK: - Page

struct WatchPresentPage: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @ObservedObject var store: WatchPresentationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var crown: Double = 0
    @State private var lastDetent = 0
    @State private var showsMore = false
    @FocusState private var crownFocused: Bool

    private var isOnScreen: Bool { vm.selectedTab == WatchPresentationStore.tab && scenePhase == .active }

    var body: some View {
        VStack(spacing: 6) {
            header
            bigButton
            HStack(spacing: 6) {
                smallButton("Previous slide", symbol: "chevron.backward") { vm.sendPresentation(.previous) }
                smallButton("More slide show controls", symbol: "ellipsis") {
                    WKInterfaceDevice.current().play(.click)
                    showsMore = true
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .focusable(true)
        .focusEffectDisabled()
        .focused($crownFocused)
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 1, sensitivity: .low,
                              isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in crownMoved(value) }
        .onChange(of: vm.selectedTab) { _, tab in if tab == WatchPresentationStore.tab { crownFocused = true } }
        .onAppear {
            if vm.selectedTab == WatchPresentationStore.tab { crownFocused = true }
            #if DEBUG
            // `ORBIT_WATCH_PRESENT_MORE=1`: the More sheet, for screenshots without taps.
            if ProcessInfo.processInfo.environment["ORBIT_WATCH_PRESENT_MORE"] == "1" {
                Task { try? await Task.sleep(for: .seconds(6)); showsMore = true }
            }
            #endif
        }
        .task(id: isOnScreen) {
            guard isOnScreen else { return }
            #if DEBUG
            WatchPresentSelfTest.runIfRequested(vm: vm)
            #endif
            var lastRead = Date.distantPast
            while !Task.isCancelled {
                if Date().timeIntervalSince(lastRead) >= 2 {
                    lastRead = Date()
                    await vm.refreshPresentation()
                }
                store.checkInAppReminder(now: Date())
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $showsMore) {
            WatchPresentMoreSheet(vm: vm, store: store)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.footnote)
                .foregroundStyle(OrbitWatchPalette.accent)
                .accessibilityHidden(true)
            Text("Present")
                .font(.headline.weight(.bold))
            Spacer(minLength: 2)
            elapsed
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var elapsed: some View {
        Group {
            if store.timer.isRunning, let start = store.timer.startedAt {
                Text(start, style: .timer)
            } else {
                Text(store.timer.elapsed(at: Date()).map(OrbitPresentationText.clock) ?? "0:00")
            }
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(store.timer.isRunning ? OrbitWatchPalette.accent : .secondary)
        .lineLimit(1)
        .accessibilityLabel("Elapsed time")
    }

    // MARK: Big button (tap = next)

    private var bigButton: some View {
        let state = store.state
        // Only while PowerPoint's editor is in front (where next is refused). A deck merely open in PowerPoint
        // behind another app keeps the tap as next: Start would press F5 in that app (a browser reloads).
        let startsShow = state?.isBlocked == true
        return Button {
            WKInterfaceDevice.current().play(.click)
            vm.sendPresentation(startsShow ? .start : .next)
        } label: {
            VStack(spacing: 3) {
                bigTitle(state, startsShow: startsShow)
                Text(bigCaption(state, startsShow: startsShow))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OrbitWatchPalette.accent.opacity(enabled ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(OrbitWatchPalette.accent.opacity(store.pending > 0 ? 0.6 : 0.2), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(startsShow ? "Start slide show" : "Next slide")
        .accessibilityValue(spokenValue(state))
        .accessibilityHint("Turn the Digital Crown to go forward or back")
    }

    private func spokenValue(_ state: OrbitPresentationState?) -> String {
        let position = state?.spokenPosition ?? ""
        guard isStale else { return position }
        return position.isEmpty ? "Not updated" : "\(position), not updated"
    }

    /// The slide show on screen is from an earlier read (the iPhone or the PC stopped answering).
    private var isStale: Bool { store.staleReason != nil && blockingMessage == nil && !store.isDemo }

    private var enabled: Bool {
        store.isDemo || (vm.canControlPC && store.phase != .unsupported && store.phase != .needsPhone)
    }

    @ViewBuilder
    private func bigTitle(_ state: OrbitPresentationState?, startsShow: Bool) -> some View {
        if let message = blockingMessage {
            Image(systemName: message.symbol)
                .font(.title3)
                .foregroundStyle(OrbitWatchPalette.amber)
        } else if let state, state.isShowingSlide, state.showState == .running || state.showState == .paused {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(state.slide)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("/\(state.slides)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .opacity(isStale ? 0.4 : 1)
        } else if let state, state.running {
            Text(state.showState == .black ? "Black" : state.showState == .white ? "White" : "End")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .opacity(isStale ? 0.4 : 1)
        } else {
            Image(systemName: startsShow ? "play.fill" : "chevron.forward")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(OrbitWatchPalette.accent)
        }
    }

    private func bigCaption(_ state: OrbitPresentationState?, startsShow: Bool) -> String {
        if let message = store.message { return message }
        if let blocking = blockingMessage { return blocking.text }
        if isStale, let reason = store.staleReason { return "Not updated · \(reason)" }
        guard let state else { return "Tap for the next slide" }
        if startsShow { return state.isReadyInEditor && !state.title.isEmpty ? "Start “\(state.title)”" : "Start the slide show" }
        if state.isShowingSlide {
            switch state.showState {
            case .black, .white: return "Tap to show the slide"
            default: return state.slideTitle.isEmpty ? "Tap for next" : state.slideTitle
            }
        }
        if state.showState == .done { return "Tap to end the show" }
        return "Presses → on the PC"
    }

    private var blockingMessage: (text: String, symbol: String)? {
        guard !store.isDemo else { return nil }
        if !vm.canControlPC || store.phase == .needsPhone {
            return ("Open Orbit on your iPhone, or pair your PC there.", "iphone.and.arrow.forward")
        }
        switch store.phase {
        case .unsupported: return ("Update the Orbit agent on your PC.", "arrow.down.circle")
        case .failed(let text) where store.state == nil: return (text, "exclamationmark.triangle.fill")
        default: return nil
        }
    }

    private func smallButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(OrbitWatchPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Crown

    private func crownMoved(_ value: Double) {
        let detent = Int(value.rounded())
        let delta = detent - lastDetent
        guard delta != 0 else { return }
        lastDetent = detent
        guard enabled else { return }
        let action: OrbitPresentationAction = delta > 0 ? .next : .previous
        for _ in 0..<min(abs(delta), 2) { vm.sendPresentation(action) }
    }
}

#if DEBUG
/// `ORBIT_WATCH_PRESENT_SELFTEST=next,next,previous` together with `ORBIT_WATCH_LINK=orbitwatch://present` (as
/// `SIMCTL_CHILD_` variables of `xcrun simctl launch`): once the Present page is on screen, sends these actions
/// the way a tap or a Crown detent does, `ORBIT_WATCH_PRESENT_SELFTEST_GAP` seconds apart (4 by default), and
/// prints what the page shows after each one. `burst:next:3` sends three taps 0.2 s apart, `timer:restart` and
/// `timer:reset` press the More sheet's timer buttons, `wait:N` waits N seconds and prints the page.
/// `ORBIT_WATCH_PRESENT_TEST_PC='host|token|securePort|fingerprint'`
/// points the Watch straight at a PC over HTTPS (the presentation remote needs it), for a Simulator without a
/// paired iPhone. `ORBIT_WATCH_PRESENT_REMINDERS=<minutes>` turns the haptic reminders on and prints what is
/// scheduled. Debug builds only; use it with a pretend PC.
@MainActor
enum WatchPresentSelfTest {
    private static var started = false
    private static var usedTestPC = false
    private static var checkedReminders = false

    static func runIfRequested(vm: OrbitWatchViewModel) {
        let environment = ProcessInfo.processInfo.environment
        if !usedTestPC, let spec = environment["ORBIT_WATCH_PRESENT_TEST_PC"] {
            usedTestPC = true
            let parts = spec.split(separator: "|").map(String.init)
            if parts.count == 4, let port = Int(parts[2]) {
                vm.selectedPCID = "watch-selftest-pc"
                vm.pcName = "Test PC"
                vm.host = parts[0]
                vm.apiToken = parts[1]
                vm.securePort = port
                vm.certificateFingerprint = parts[3]
                print("WATCH_PRESENT_SELFTEST using \(parts[0]):\(port) directly")
            } else {
                print("WATCH_PRESENT_SELFTEST ORBIT_WATCH_PRESENT_TEST_PC must be host|token|securePort|fingerprint")
            }
        }
        if !checkedReminders, let minutes = environment["ORBIT_WATCH_PRESENT_REMINDERS"].flatMap(Int.init) {
            // Turns the reminders on (as the switch does) and lists what is scheduled once the timer runs.
            checkedReminders = true
            vm.presentation.reminderMinutes = WatchPresentationStore.reminderChoices.contains(minutes) ? minutes : 1
            vm.presentation.remindersOn = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                    .filter { $0.identifier.hasPrefix(WatchPresentationReminders.prefix) }
                    .compactMap { request -> (Date, String)? in
                        guard let date = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() else { return nil }
                        return (date, request.content.body)
                    }
                    .sorted { $0.0 < $1.0 }
                let elapsed = vm.presentation.timer.elapsed(at: Date()).map(OrbitPresentationText.clock) ?? "-"
                print("WATCH_PRESENT_SELFTEST reminders: \(pending.count) pending, timer \(elapsed), next in \(pending.prefix(3).map { "\(Int($0.0.timeIntervalSinceNow))s “\($0.1)”" })")
            }
        }
        guard !started, let plan = environment["ORBIT_WATCH_PRESENT_SELFTEST"], !plan.isEmpty else { return }
        started = true
        let gap = environment["ORBIT_WATCH_PRESENT_SELFTEST_GAP"].flatMap(Double.init) ?? 4
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(5, gap)))
            print("WATCH_PRESENT_SELFTEST ready: \(summary(vm.presentation))")
            for (index, step) in plan.split(separator: ",").enumerated() {
                let parts = step.split(separator: ":").map(String.init)
                // `timer:restart` / `timer:reset` (the More sheet's buttons), `wait:N` (N seconds, then the page).
                if parts.first == "timer" || parts.first == "wait" {
                    if parts.first == "timer" {
                        if parts.dropFirst().first == "reset" { vm.presentation.resetTimer() } else { vm.presentation.restartTimer() }
                    }
                    let seconds = parts.first == "wait" ? parts.dropFirst().first.flatMap(Double.init) ?? 5 : 4.5
                    try? await Task.sleep(for: .seconds(seconds)) // timer: two reads of the PC's show time later
                    print("WATCH_PRESENT_SELFTEST step \(index + 1) \(step): \(summary(vm.presentation))")
                    try? await Task.sleep(for: .seconds(gap))
                    continue
                }
                // `burst:next:3`: taps 0.2 s apart, like Crown detents while the PC is slow.
                let burst = parts.first == "burst"
                let words = burst ? Array(parts.dropFirst()) : parts
                guard let first = words.first, let action = OrbitPresentationAction(rawValue: first) else {
                    print("WATCH_PRESENT_SELFTEST step \(index + 1) \(step): unknown action")
                    continue
                }
                for _ in 0..<(burst ? (words.count > 1 ? Int(words[1]) ?? 3 : 3) : 1) {
                    vm.sendPresentation(action)
                    if burst { try? await Task.sleep(for: .milliseconds(200)) }
                }
                for _ in 0..<150 where vm.presentation.pending > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(600))
                print("WATCH_PRESENT_SELFTEST step \(index + 1) \(step): \(summary(vm.presentation))")
                try? await Task.sleep(for: .seconds(gap))
            }
            print("WATCH_PRESENT_SELFTEST done")
        }
    }

    private static func summary(_ store: WatchPresentationStore) -> String {
        let shown = store.state.map { "\($0.positionText ?? "-") \($0.showState.rawValue) · control \($0.control.rawValue)" } ?? "no state"
        let elapsed = store.timer.elapsed(at: Date()).map(OrbitPresentationText.clock) ?? "-"
        let source = store.timer.isFollowingPC ? "PowerPoint" : (store.timer.overridesPC ? "own" : "Orbit")
        return "\(store.phase) · \(shown) · route \(store.route.isEmpty ? "-" : store.route) · timer \(store.timer.isRunning ? "running" : "stopped") \(elapsed) (\(source)) · stale \(store.staleReason ?? "-") · message \(store.message ?? "-")"
    }
}
#endif

// MARK: - More controls

private struct WatchPresentMoreSheet: View {
    @ObservedObject var vm: OrbitWatchViewModel
    @ObservedObject var store: WatchPresentationStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsEnd = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Slide show")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                WatchActionButton(title: store.state?.running == true ? "Restart from slide 1" : "Start slide show", symbol: "play.fill", prominent: true) {
                    run(.start)
                }
                WatchActionButton(title: "Start from current slide", symbol: "play.circle") { run(.startCurrent) }
                WatchActionButton(title: store.state?.showState == .black ? "Show the slide" : "Black screen", symbol: "rectangle.fill") { run(.black) }
                WatchActionButton(title: store.state?.showState == .white ? "Show the slide" : "White screen", symbol: "rectangle") { run(.white) }
                WatchActionButton(title: "End slide show", symbol: "stop.fill", tint: OrbitWatchPalette.amber) {
                    WKInterfaceDevice.current().play(.click)
                    confirmsEnd = true
                }

                WatchSectionLabel(title: "Timer")
                if let note = timerNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                WatchActionButton(title: "Restart timer", symbol: "timer") {
                    WKInterfaceDevice.current().play(.click)
                    store.restartTimer()
                }
                WatchActionButton(title: "Reset timer", symbol: "arrow.counterclockwise", enabled: store.timer.startedAt != nil) {
                    WKInterfaceDevice.current().play(.click)
                    store.resetTimer()
                }
                Toggle(isOn: $store.remindersOn) {
                    Text("Tap reminders").font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 4)
                if store.remindersOn {
                    Picker("Every", selection: $store.reminderMinutes) {
                        ForEach(WatchPresentationStore.reminderChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text(reminderFooter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WatchSectionLabel(title: "How it works")
                Text(howItWorks)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .confirmationDialog("End the slide show?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("End slide show", role: .destructive) {
                run(.end)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var reminderFooter: String {
        if store.notificationsAllowed == false {
            return "Notifications are off for Orbit, so reminders tap you only while this page is open. Turn them on in the Watch app on iPhone."
        }
        if store.remindersStoppedForThisTalk {
            return "Stopped for this talk. Restart the timer or pick another interval to get them again."
        }
        let every = store.reminderMinutes == 1 ? "minute" : "\(store.reminderMinutes) minutes"
        // Reminders are notifications: outside Silent Mode the watch also plays its alert sound.
        return "A tap on your wrist every \(every) of talk time, also with the screen off. Turn on Silent Mode so they make no sound. Stop Reminders on a reminder ends them for this talk."
    }

    /// Where the talk time comes from, while it matters.
    private var timerNote: String? {
        if store.timer.isFollowingPC { return "Shows PowerPoint's own show time." }
        if store.timer.overridesPC { return "Your own timer until this slide show ends." }
        return nil
    }

    private var howItWorks: String {
        if store.isDemo { return "Demo mode on iPhone: a pretend deck, nothing reaches a PC." }
        var text = store.state?.controlExplanation.detail ?? "Tap for the next slide, turn the Crown to go forward or back."
        if !store.route.isEmpty { text += " Route: \(store.route)." }
        return text
    }

    private func run(_ action: OrbitPresentationAction) {
        WKInterfaceDevice.current().play(.click)
        vm.sendPresentation(action)
        dismiss()
    }
}
