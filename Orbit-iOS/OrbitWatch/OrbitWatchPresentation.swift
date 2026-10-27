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
    @Published private(set) var timer = OrbitPresentationTimer()
    @Published var message: String?
    @Published private(set) var pending = 0
    /// "Via iPhone" or "Direct to PC" for the last exchange.
    @Published private(set) var route = ""
    @Published var remindersOn: Bool {
        didSet {
            UserDefaults.standard.set(remindersOn, forKey: Self.remindersKey)
            if remindersOn && !oldValue { Task { await requestReminderPermission() } }
            updateReminders()
        }
    }
    @Published var reminderMinutes: Int {
        didSet {
            UserDefaults.standard.set(reminderMinutes, forKey: Self.minutesKey)
            updateReminders()
        }
    }
    /// nil until asked; false when notifications are off for Orbit on this Watch (then the page taps you
    /// itself while it is open).
    @Published private(set) var notificationsAllowed: Bool?

    private var demo = OrbitPresentationDemo()
    private(set) var pcID = ""
    private var queue: [(action: OrbitPresentationAction, slide: Int?)] = []
    private var queueGeneration = 0
    private var actionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var lastReminderCount = 0

    private static let remindersKey = "Orbit.WatchPresentReminders"
    private static let minutesKey = "Orbit.WatchPresentReminderMinutes"

    init() {
        remindersOn = UserDefaults.standard.bool(forKey: Self.remindersKey)
        let minutes = UserDefaults.standard.integer(forKey: Self.minutesKey)
        reminderMinutes = Self.reminderChoices.contains(minutes) ? minutes : 5
        WatchPresentationReminders.shared.activate()
        if remindersOn { Task { await refreshPermission() } }
    }

    /// Reads the iPhone's demo flag from its sync payload (older iPhone apps send it too).
    func applyPhonePayload(_ payload: [String: Any]) {
        guard let demoMode = payload["isDemoMode"] as? Bool, demoMode != isDemo else { return }
        cancelQueue()
        isDemo = demoMode
        demo = OrbitPresentationDemo()
        state = nil
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
        // Keep the last state on screen; a busy PowerPoint or a slow iPhone is usually brief.
        if case .failed = phase, state != nil { return }
        if self.phase != phase { self.phase = phase }
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

    /// Adds an action; returns false when too many are already waiting (fast Crown turns).
    func enqueue(_ action: OrbitPresentationAction, slide: Int?, run: @escaping (OrbitPresentationAction, Int?) async -> Void) -> Bool {
        guard queue.count < Self.maxQueued else { return false }
        queue.append((action, slide))
        pending = queue.count
        guard actionTask == nil else { return true }
        let generation = queueGeneration
        actionTask = Task { [weak self] in
            while let self, generation == self.queueGeneration, let next = self.queue.first, !Task.isCancelled {
                await run(next.action, next.slide)
                // The queue was cleared meanwhile (another PC, demo mode): leave the new one alone.
                guard generation == self.queueGeneration else { return }
                if !self.queue.isEmpty { self.queue.removeFirst() }
                self.pending = self.queue.count
            }
            if let self, generation == self.queueGeneration { self.actionTask = nil }
        }
        return true
    }

    func cancelQueue() {
        queueGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        queue = []
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

    func restartTimer() {
        timer.start(now: Date())
        lastReminderCount = 0
        updateReminders()
    }

    func resetTimer() {
        timer.reset()
        lastReminderCount = 0
        updateReminders()
    }

    private func updateReminders() {
        WatchPresentationReminders.shared.update(startedAt: timer.startedAt, running: timer.isRunning,
                                                 minutes: reminderMinutes, enabled: remindersOn)
    }

    /// Called about every second while the page is open. Without notification permission the page taps
    /// the wrist itself at each reminder (only while Orbit is open).
    func checkInAppReminder(now: Date) {
        guard remindersOn, notificationsAllowed == false, timer.isRunning, let elapsed = timer.elapsed(at: now) else {
            lastReminderCount = 0
            return
        }
        let count = Int(elapsed / TimeInterval(reminderMinutes * 60))
        if lastReminderCount == 0 { lastReminderCount = count; return }
        if count > lastReminderCount {
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
    static let slots = 12
    /// No reminder is scheduled further ahead than this.
    static let horizon: TimeInterval = 3 * 3600

    private var signature: String?
    private var activated = false

    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Replaces the scheduled reminders when the timer, the interval or the switch changed.
    @MainActor
    func update(startedAt: Date?, running: Bool, minutes: Int, enabled: Bool) {
        let wanted: String? = if enabled, running, let startedAt { "\(Int(startedAt.timeIntervalSince1970))-\(minutes)" } else { nil }
        guard wanted != signature else { return }
        signature = wanted
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<Self.slots).map { Self.prefix + String($0) })
        guard let startedAt, wanted != nil, minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        let now = Date()
        var index = Int(max(0, now.timeIntervalSince(startedAt)) / interval) + 1
        for slot in 0..<Self.slots {
            let delay = startedAt.addingTimeInterval(TimeInterval(index) * interval).timeIntervalSince(now)
            guard delay <= Self.horizon else { break }
            let content = UNMutableNotificationContent()
            content.title = "Presentation"
            content.body = "\(index * minutes) minutes since the slide show started."
            content.sound = .default
            content.threadIdentifier = "orbit.present"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + String(slot), content: content, trigger: trigger))
            index += 1
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
            if case WatchPresentationRelayFailure.olderAgent = error { store.readFailed(.unsupported) }
            if case OrbitWatchHTTPError.presentationUnavailable = error { store.readFailed(.unsupported) }
            store.show(Self.presentationMessage(error, action: action))
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
        .accessibilityValue(state?.spokenPosition ?? "")
        .accessibilityHint("Turn the Digital Crown to go forward or back")
    }

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
        } else if let state, state.running {
            Text(state.showState == .black ? "Black" : state.showState == .white ? "White" : "End")
                .font(.system(.title2, design: .rounded).weight(.bold))
        } else {
            Image(systemName: startsShow ? "play.fill" : "chevron.forward")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(OrbitWatchPalette.accent)
        }
    }

    private func bigCaption(_ state: OrbitPresentationState?, startsShow: Bool) -> String {
        if let message = store.message { return message }
        if let blocking = blockingMessage { return blocking.text }
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
/// prints what the page shows after each one. `ORBIT_WATCH_PRESENT_TEST_PC='host|token|securePort|fingerprint'`
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
                guard let action = OrbitPresentationAction(rawValue: String(step)) else {
                    print("WATCH_PRESENT_SELFTEST step \(index + 1) \(step): unknown action")
                    continue
                }
                vm.sendPresentation(action)
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
        return "\(store.phase) · \(shown) · route \(store.route.isEmpty ? "-" : store.route) · timer \(store.timer.isRunning ? "running" : "stopped") · message \(store.message ?? "-")"
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
                    Text(store.notificationsAllowed == false
                         ? "Notifications are off for Orbit, so reminders tap you only while this page is open. Turn them on in the Watch app on iPhone."
                         : "A tap on your wrist every \(store.reminderMinutes) minute\(store.reminderMinutes == 1 ? "" : "s") of talk time, also with the screen off.")
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
