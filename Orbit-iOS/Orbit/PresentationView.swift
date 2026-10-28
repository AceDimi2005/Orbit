import SwiftUI
import UIKit

// Presentation remote (DESIGN F8, free): next/previous, slide x / y, the current slide, speaker notes and a
// talk timer for the slide show running on the PC. PowerPoint is driven directly (COM) while its show runs;
// anything else (Google Slides, a PDF…) gets key presses in the window in front. The agent decides and says
// which (`control`); the models live in Shared/OrbitPresentationModels.swift.

// MARK: - Store

/// Reads `GET /api/presentation` about once a second while the screen is visible and sends actions one at
/// a time, in the order they were tapped. Demo mode uses `OrbitPresentationDemo` and never calls a PC.
@MainActor
final class OrbitPresentationStore: ObservableObject {
    /// One per app, so a talk timer started by key presses survives a trip to the Remote tab and back.
    static let shared = OrbitPresentationStore()

    enum Phase: Equatable {
        case idle, loading, ready, demo, notPaired, insecure, offline
        case olderAgent(version: String?)
        case failed(String)
    }

    struct Thumbnail: Equatable {
        let key: String
        let image: UIImage
    }

    struct QueuedAction: Equatable {
        let action: OrbitPresentationAction
        let slide: Int?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state: OrbitPresentationState?
    /// The last state stays on screen while the latest read failed (PowerPoint busy, Wi-Fi hiccup); this says why.
    @Published private(set) var staleReason: String?
    @Published private(set) var timer = OrbitPresentationTimer()
    /// The newest slide picture loaded; it can belong to the previous slide while the next one loads.
    @Published private(set) var thumbnail: Thumbnail?
    @Published private(set) var isLoadingThumbnail = false
    /// Actions waiting or in flight, oldest first.
    @Published private(set) var queue: [QueuedAction] = []
    /// What the last slide change did ("Went to the next slide.", "Pressed Right on the PC…").
    @Published private(set) var lastResult: String?
    @Published var toast: OrbitDeckToast?

    /// Width asked of the PC for slide pictures (bigger on iPad).
    var thumbnailWidth = 800

    private weak var vm: OrbitViewModel?
    private var identity = ""
    private var generation = 0
    private var demo = OrbitPresentationDemo()
    private var isDemo = false
    private var actionTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    /// PNG bytes per slide (key: PC, deck title, slide count, slide); decoded only when shown.
    private var thumbnailData: [String: Data] = [:]
    private var thumbnailOrder: [String] = []
    /// When a slide picture that failed may be asked for again.
    private var thumbnailRetryAt: [String: Date] = [:]
    private var consecutiveFailures = 0
    /// Reads in a row that got no answer at all (timeouts, no route), as opposed to the PC refusing one.
    private var unansweredReads = 0
    /// One pinned client per PC connection, so the once-a-second read reuses its TLS session.
    private var link: OrbitPCLink?
    /// Presentation screens on screen (the Tools tile and the Remote menu each push one, `orbit://presentation`
    /// opens one full screen).
    private var visibleViews = 0
    private var holdsIdleTimer = false
    /// When the last read finished; with two screens polling (`orbit://presentation` over a pushed one) they
    /// share the reads.
    private var lastReadAt = Date.distantPast

    static let maxQueued = 4
    private static let maxCachedThumbnails = 40
    private static let offlineAfterUnansweredReads = 3

    var isSending: Bool { !queue.isEmpty }
    var canControl: Bool { phase == .ready || phase == .demo }
    var isDemoMode: Bool { phase == .demo }

    /// Binds the store to the selected PC; a different PC, connection or demo setting starts over.
    func configure(_ vm: OrbitViewModel) {
        self.vm = vm
        let newIdentity = vm.isDemoMode ? "demo" : "\(vm.selectedPCID)#\(vm.connectionID)"
        guard newIdentity != identity else { return }
        identity = newIdentity
        generation &+= 1
        actionTask?.cancel(); actionTask = nil
        thumbnailTask?.cancel(); thumbnailTask = nil
        readTask?.cancel(); readTask = nil
        queue = []
        state = nil
        staleReason = nil
        lastResult = nil
        thumbnail = nil
        isLoadingThumbnail = false
        thumbnailData = [:]
        thumbnailOrder = []
        thumbnailRetryAt = [:]
        consecutiveFailures = 0
        unansweredReads = 0
        link = nil
        timer.reset()
        isDemo = vm.isDemoMode
        if isDemo { demo = OrbitPresentationDemo() }
        phase = .idle
        updateIdleTimer()
    }

    func setVisible(_ visible: Bool) {
        visibleViews = max(0, visibleViews + (visible ? 1 : -1))
        updateIdleTimer()
    }

    /// The polling loop; runs until the view's task is cancelled (screen hidden, app in the background).
    func poll() async {
        while !Task.isCancelled {
            if Date().timeIntervalSince(lastReadAt) >= 0.8 { await refresh() }
            let pause: Duration = phase == .ready || phase == .demo ? .seconds(1) : .seconds(3)
            try? await Task.sleep(for: pause)
        }
    }

    /// One read of the PC's presentation state. Reads never overlap: a read already running is awaited.
    func refresh() async {
        if let readTask { await readTask.value; return }
        let task = Task { await self.read() }
        readTask = task
        await task.value
        if readTask == task { readTask = nil }
        lastReadAt = Date()
    }

    private func read() async {
        // `configure` already ran for this PC: the view calls it before polling, and a new PC,
        // connection or demo setting restarts the view's polling task.
        guard let vm else { return }
        if isDemo {
            phase = .demo
            apply(demo.state(at: Date()))
            #if DEBUG
            runSelfTestIfRequested()
            #endif
            return
        }
        guard vm.isConfigured, !vm.selectedPCID.isEmpty else { phase = .notPaired; state = nil; return }
        guard vm.hasSecureConnection else { phase = .insecure; return }
        // One missed reply to the Overview's status poll marks the PC offline until the next one (2 s later).
        // Mid-talk the remote stays usable while the slide show itself still answers; "PC offline" shows once
        // three reads in a row went unanswered too.
        guard vm.metrics.isOnline || (phase == .ready && unansweredReads < Self.offlineAfterUnansweredReads) else {
            phase = .offline
            updateIdleTimer()
            return
        }
        guard let link = currentLink() else { phase = .failed("Orbit couldn't open the encrypted connection to this PC. Pair it again in My PCs."); return }
        let version = generation

        if phase != .ready {
            // While the screen says the agent is too old it asks the PC again every half minute, so an agent
            // updated meanwhile is found when the user comes back (capabilities are cached for 10 minutes).
            let maxAge: TimeInterval
            if case .olderAgent = phase { maxAge = 30 } else { maxAge = 600 }
            do {
                switch try await OrbitDeadline.run(seconds: 6, { try await OrbitFeatureStore.shared.features(for: link, maxAge: maxAge) }) {
                case .olderAgent:
                    guard version == generation else { return }
                    phase = .olderAgent(version: nil)
                    #if DEBUG
                    runSelfTestIfRequested() // `watch:` steps check the relay's answer for older agents
                    #endif
                    return
                case .available(let agentVersion, let features) where !features.contains("presentation"):
                    guard version == generation else { return }
                    phase = .olderAgent(version: agentVersion)
                    #if DEBUG
                    runSelfTestIfRequested()
                    #endif
                    return
                default:
                    break
                }
            } catch {
                guard version == generation, !Task.isCancelled else { return }
                phase = .failed(OrbitPlainError.describe(error))
                return
            }
            guard version == generation else { return }
            if state == nil { phase = .loading }
        }

        do {
            let client = link.client
            let data = try await OrbitDeadline.run(seconds: 6) { try await client.data("/api/presentation") }
            let decoded = try JSONDecoder().decode(OrbitPresentationState.self, from: data)
            guard version == generation else { return }
            phase = .ready
            staleReason = nil
            consecutiveFailures = 0
            unansweredReads = 0
            apply(decoded)
            #if DEBUG
            runSelfTestIfRequested()
            #endif
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            handleReadFailure(error, pcID: link.id)
        }
    }

    private func handleReadFailure(_ error: Error, pcID: String) {
        consecutiveFailures += 1
        if let orbit = error as? OrbitError, let status = orbit.statusCode {
            unansweredReads = 0 // the PC answered, just not with the slide show
            let message = OrbitPresentationText.failure(status: status, detail: Self.detail(of: orbit))
            switch status {
            case 404 where Self.detail(of: orbit) == nil:
                OrbitFeatureStore.shared.invalidate(pcID)
                phase = .olderAgent(version: nil)
            case 426:
                phase = .insecure
            case 401, 403, 501:
                // Nothing would work until the PC is paired again (or runs on Windows).
                phase = .failed(message)
            default:
                // The PC answered (503 while PowerPoint is busy…): keep the remote, which can still press keys.
                staleReason = message
                if phase != .ready { phase = .ready }
            }
            return
        }
        unansweredReads += 1
        staleReason = Self.transportMessage(error, action: nil)
        // The next read builds a fresh client from the current connection settings.
        link = nil
        if state == nil, consecutiveFailures >= 2 { phase = .failed(staleReason ?? "Couldn't read the slide show.") }
        else if phase != .ready { phase = .ready }
    }

    // MARK: Applying a state

    private func apply(_ new: OrbitPresentationState) {
        let old = state
        let now = Date()
        if old != new { state = new }
        updateTimer { $0.sync(with: new, now: now) }
        if let old, new.isShowingSlide, !old.isShowingSlide || old.slide != new.slide {
            slideChanged(to: new)
        }
        updateIdleTimer()
        loadThumbnailIfNeeded()
    }

    private func slideChanged(to state: OrbitPresentationState) {
        OrbitHaptics.tap()
        if UIAccessibility.isVoiceOverRunning, let position = state.spokenPosition {
            UIAccessibility.post(notification: .announcement, argument: position)
        }
    }

    // MARK: Actions

    /// Queues an action; actions run one after another so quick taps arrive in order.
    func send(_ action: OrbitPresentationAction, slide: Int? = nil) {
        guard canControl else { return }
        guard queue.count < Self.maxQueued else {
            OrbitHaptics.warning()
            return
        }
        if action.isMove { OrbitHaptics.selection() } else { OrbitHaptics.press() }
        queue.append(QueuedAction(action: action, slide: slide))
        guard actionTask == nil else { return }
        let version = generation
        actionTask = Task { [weak self] in
            while let self, version == self.generation, let next = self.queue.first, !Task.isCancelled {
                await self.perform(next, version: version)
                guard version == self.generation else { return }
                if !self.queue.isEmpty { self.queue.removeFirst() }
            }
            guard let self, version == self.generation else { return }
            self.actionTask = nil
            // Slide pictures wait while actions are queued (see `loadThumbnailIfNeeded`).
            self.loadThumbnailIfNeeded()
        }
    }

    private func perform(_ item: QueuedAction, version: Int) async {
        let action = item.action
        if isDemo {
            do {
                let reply = try demo.perform(action, slide: item.slide, now: Date())
                handle(reply, for: action)
            } catch let refusal as OrbitPresentationDemo.Refusal {
                fail(refusal.message)
            } catch {
                fail(error.localizedDescription)
            }
            return
        }
        guard let link = currentLink() else {
            fail("Connect to your PC first.")
            return
        }
        let body = OrbitPresentationActionBody(action: action, slide: item.slide)
        do {
            let client = link.client
            let reply: OrbitPresentationActionReply = try await OrbitDeadline.run(seconds: 10) {
                try await client.send(action.path, method: "POST", body: body)
            }
            guard version == generation else { return }
            handle(reply, for: action)
        } catch is DecodingError {
            // Done on the PC; the reply just wasn't readable. Read the state instead.
            guard version == generation else { return }
            lastResult = "Sent “\(action.title)”."
            await refresh()
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            if let orbit = error as? OrbitError, let status = orbit.statusCode {
                if status == 404, Self.detail(of: orbit) == nil {
                    OrbitFeatureStore.shared.invalidate(link.id)
                    phase = .olderAgent(version: nil)
                    return
                }
                fail(OrbitPresentationText.failure(status: status, detail: Self.detail(of: orbit)))
            } else {
                fail(Self.transportMessage(error, action: action))
                self.link = nil
            }
            // The PC may have changed something anyway (a slow PowerPoint); show what it has now.
            await refresh()
        }
    }

    private func handle(_ reply: OrbitPresentationActionReply, for action: OrbitPresentationAction) {
        let now = Date()
        updateTimer { $0.note(action, via: reply.via, now: now) }
        let before = state
        if let presentation = reply.presentation {
            apply(presentation)
        } else {
            Task { await refresh() }
        }
        let busyFallback = reply.usedKeys && reply.detail.hasPrefix("PowerPoint is busy")
        if action.isMove && !busyFallback {
            lastResult = reply.detail.isEmpty ? nil : reply.detail
            // A slide change the PC can't number (keys to Google Slides) still gets its haptic.
            let numbered = (reply.presentation ?? before)?.isShowingSlide == true
            if !numbered { OrbitHaptics.tap() }
        } else {
            lastResult = reply.detail.isEmpty ? lastResult : reply.detail
            OrbitHaptics.success()
            show(reply.detail.isEmpty ? "Done." : reply.detail, kind: busyFallback ? .info : .success)
        }
        updateIdleTimer()
    }

    private func fail(_ message: String) {
        OrbitHaptics.error()
        show(message, kind: .failure)
    }

    func resetTimer() {
        updateTimer { $0.reset() }
        updateIdleTimer()
    }

    func startTimerNow() {
        let now = Date()
        updateTimer { $0.start(now: now) }
        updateIdleTimer()
    }

    /// Changes the talk timer, publishing only a real change (every read applies the PC's show time).
    private func updateTimer(_ change: (inout OrbitPresentationTimer) -> Void) {
        var copy = timer
        change(&copy)
        if copy != timer { timer = copy }
    }

    func show(_ message: String, kind: OrbitDeckToast.Kind) {
        let toast = OrbitDeckToast(message: message, kind: kind)
        self.toast = toast
        UIAccessibility.post(notification: .announcement, argument: message)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(kind == .failure ? 4.5 : 3))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.toast = nil
        }
    }

    // MARK: Slide pictures

    var thumbnailKeyForCurrentSlide: String? {
        guard let state, state.canShowThumbnail else { return nil }
        return "\(identity)|\(state.title)|\(state.slides)|\(state.slide)"
    }

    private func loadThumbnailIfNeeded() {
        guard !isDemo, let key = thumbnailKeyForCurrentSlide, let state else { return }
        if thumbnail?.key == key { return }
        if let data = thumbnailData[key], let image = UIImage(data: data) {
            thumbnail = Thumbnail(key: key, image: image)
            return
        }
        if let retryAt = thumbnailRetryAt[key], Date() < retryAt { return }
        // Slide changes come first: PowerPoint does one thing at a time on the PC, and an export can take a
        // moment, so a picture is only asked for while no action waits (the queue calls back when it drains).
        guard queue.isEmpty, thumbnailTask == nil, let link = currentLink() else { return }
        let version = generation
        let slide = state.slide
        let width = thumbnailWidth
        isLoadingThumbnail = true
        thumbnailTask = Task { [weak self] in
            // A short pause, so quick taps skip the pictures of the slides in between.
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, version == self.generation else { return }
            guard self.thumbnailKeyForCurrentSlide == key, self.queue.isEmpty else {
                self.thumbnailTask = nil
                self.isLoadingThumbnail = false
                self.loadThumbnailIfNeeded()
                return
            }
            let client = link.client
            let result: Result<Data, Error>
            do {
                let data = try await OrbitDeadline.run(seconds: 14) {
                    try await client.data("/api/presentation/slide.png", query: [
                        URLQueryItem(name: "slide", value: String(slide)), URLQueryItem(name: "width", value: String(width))
                    ])
                }
                result = .success(data)
            } catch {
                result = .failure(error)
            }
            guard version == self.generation else { return }
            self.thumbnailTask = nil
            self.isLoadingThumbnail = false
            switch result {
            case .success(let data):
                if let image = UIImage(data: data) {
                    self.remember(data, for: key)
                    if self.thumbnailKeyForCurrentSlide == key || self.thumbnail == nil {
                        self.thumbnail = Thumbnail(key: key, image: image)
                    }
                } else {
                    self.thumbnailRetryAt[key] = Date().addingTimeInterval(60)
                }
            case .failure(let error):
                // No picture for this slide (404): ask again in a minute. PowerPoint busy or slow: in a few
                // seconds. Never in a loop.
                let missing = (error as? OrbitError)?.statusCode == 404
                self.thumbnailRetryAt[key] = Date().addingTimeInterval(missing ? 60 : 5)
            }
            self.loadThumbnailIfNeeded()
        }
    }

    private func remember(_ data: Data, for key: String) {
        thumbnailData[key] = data
        thumbnailOrder.removeAll { $0 == key }
        thumbnailOrder.append(key)
        while thumbnailOrder.count > Self.maxCachedThumbnails {
            thumbnailData[thumbnailOrder.removeFirst()] = nil
        }
    }

    // MARK: Screen stays on while presenting

    private func updateIdleTimer() {
        let presenting = visibleViews > 0 && (state?.running == true || timer.isRunning)
        if presenting {
            // Checked again on every read: a stream that ended meanwhile turns the idle timer back on.
            holdsIdleTimer = true
            if !UIApplication.shared.isIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = true }
        } else if holdsIdleTimer {
            holdsIdleTimer = false
            // A stream keeps the screen on by itself; only let go when none is showing.
            if !MoonlightStreamController.shared.isPresented { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    #if DEBUG
    // MARK: Self-test

    /// `ORBIT_PRESENT_SELFTEST=start,next,black,black,goto:7,end` (`SIMCTL_CHILD_ORBIT_PRESENT_SELFTEST` in the
    /// Simulator, with `ORBIT_SELFTEST_OPEN_URL=orbit://presentation`): once the screen has read the PC (or found
    /// that its agent is too old for the presentation remote), sends
    /// these actions through the same queue as the buttons, `ORBIT_PRESENT_SELFTEST_GAP` seconds apart (4 by
    /// default), and prints what the screen shows after each one (`PRESENT_SELFTEST step …`). Steps starting
    /// with `watch:` (`watch:state`, `watch:next`, `watch:goto:5`, `watch:otherpc:next`, `watch:expired:next`)
    /// send what the Watch's Present page sends through the iPhone bridge instead. Debug builds only; use it
    /// with a pretend PC.
    private var selfTestStarted = false

    private func runSelfTestIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard !selfTestStarted, let plan = environment["ORBIT_PRESENT_SELFTEST"], !plan.isEmpty else { return }
        selfTestStarted = true
        let gap = environment["ORBIT_PRESENT_SELFTEST_GAP"].flatMap(Double.init) ?? 4
        Task { @MainActor [weak self] in
            print("PRESENT_SELFTEST ready: \(self?.selfTestSummary ?? "")")
            for (index, step) in plan.split(separator: ",").enumerated() {
                try? await Task.sleep(for: .seconds(gap))
                guard let self else { return }
                let parts = step.split(separator: ":")
                if parts.first == "watch" {
                    await self.runWatchSelfTestStep(parts.dropFirst().map(String.init), label: "step \(index + 1) \(step)")
                    continue
                }
                guard let action = OrbitPresentationAction(rawValue: String(parts[0])) else {
                    print("PRESENT_SELFTEST step \(index + 1) \(step): unknown action")
                    continue
                }
                toast = nil
                send(action, slide: parts.count > 1 ? Int(parts[1]) : nil)
                while isSending { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(400))
                print("PRESENT_SELFTEST step \(index + 1) \(step): \(selfTestSummary)")
            }
            print("PRESENT_SELFTEST done")
        }
    }

    /// One Watch command (`OrbitWatchPresentationRelay`) through `OrbitWatchBridge`'s PC, host and deadline checks.
    private func runWatchSelfTestStep(_ parts: [String], label: String) async {
        guard let vm else { return }
        var words = parts
        var modifiers = Set<String>()
        while let first = words.first, ["otherpc", "otherhost", "expired"].contains(first) {
            modifiers.insert(first)
            words.removeFirst()
        }
        guard let action = words.first else { print("PRESENT_SELFTEST \(label): no action"); return }
        var message: [String: Any] = [
            "cmd": OrbitWatchPresentationRelay.command, "action": action,
            "pcID": modifiers.contains("otherpc") ? "another-pc" : vm.selectedPCID,
            "host": modifiers.contains("otherhost") ? "10.255.255.1" : vm.cleanHost(),
            "expiresAt": Date().addingTimeInterval(modifiers.contains("expired") ? -1 : 5).timeIntervalSince1970
        ]
        if words.count > 1, let slide = Int(words[1]) { message["slide"] = slide }
        let reply = await OrbitWatchBridge.shared.selfTestForward(message)
        let shown = (reply["presentation"] as? Data).flatMap { try? JSONDecoder().decode(OrbitPresentationState.self, from: $0) }
        let sentences = [reply["message"], reply["detail"]].compactMap { $0 as? String }.joined(separator: " ")
        print("PRESENT_SELFTEST \(label): watch reply \(reply["status"] as? String ?? "-") · \(sentences.isEmpty ? "-" : sentences) · via \(reply["via"] as? String ?? "-") · code \(reply["code"] as? String ?? "-") · state \(shown.map { "\($0.positionText ?? "-") \($0.showState.rawValue) · notes \($0.notes.isEmpty ? "none" : "SENT")" } ?? "none")")
    }

    private var selfTestSummary: String {
        let shown = state.map { "\($0.positionText ?? "-") \($0.showState.rawValue) · control \($0.control.rawValue) · running \($0.running)" } ?? "no state"
        return "\(phase) · \(shown) · timer \(timer.isRunning ? "running" : "stopped") · result \(lastResult ?? "-") · toast \(toast?.message ?? "-")"
    }

    /// `ORBIT_PRESENT_SELFTEST_ORIENTATION=landscape` turns the screen sideways when the remote opens, for
    /// screenshots of the landscape layout (the Simulator can't be rotated without taps).
    static func rotateForSelfTestIfRequested() {
        guard let wanted = ProcessInfo.processInfo.environment["ORBIT_PRESENT_SELFTEST_ORIENTATION"] else { return }
        Task { @MainActor in
            // After the screen has finished appearing: UIKit refuses to rotate during a presentation.
            try? await Task.sleep(for: .seconds(2))
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let mask: UIInterfaceOrientationMask = wanted == "landscape" ? .landscapeRight : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("PRESENT_SELFTEST rotation failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

    // MARK: Helpers

    private func currentLink() -> OrbitPCLink? {
        if let link { return link }
        guard let vm, let made = OrbitPCLink.current(vm) else { return nil }
        link = made
        return made
    }

    /// The agent's sentence, or nil for FastAPI's bare "Not Found" and replies without one.
    private static func detail(of error: OrbitError) -> String? {
        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || message == "Not Found" || message.hasPrefix("PC returned error ") { return nil }
        return message
    }

    private static func transportMessage(_ error: Error, action: OrbitPresentationAction?) -> String {
        if let url = error as? URLError, url.code == .timedOut {
            if let action, action != .startCurrent {
                return "Your PC didn't answer in time, so “\(action.title)” may still have happened. Check the slide before trying again."
            }
            return "Your PC didn't answer in time."
        }
        return OrbitPlainError.describe(error)
    }
}

// MARK: - Screen

struct PresentationView: View {
    @ObservedObject var vm: OrbitViewModel
    /// Opened full screen (`orbit://presentation`) rather than pushed.
    var showsDoneButton = false
    @ObservedObject private var store = OrbitPresentationStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.presentation.notesStep") private var notesStep = 0
    @ScaledMetric(relativeTo: .body) private var notesBaseSize: CGFloat = 17
    @State private var showsControlInfo = false
    @State private var showsGoTo = false
    @State private var goToText = ""
    @State private var confirmsEnd = false

    private struct PollKey: Equatable {
        let active: Bool
        let connection: Int
        let demo: Bool
        let online: Bool
        let pcID: String
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 640 && (proxy.size.width > proxy.size.height || proxy.size.width >= 900)
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline || vm.isDemoMode)
                content(size: proxy.size, wide: wide)
                    .frame(maxWidth: 1400)
                    .padding(.horizontal, wide ? 20 : 14)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { store.thumbnailWidth = wide || horizontalSizeClass == .regular ? 1280 : 800 }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
        .navigationTitle("Presentation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsControlInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("How Orbit controls the slides")
            }
        }
        .sheet(isPresented: $showsControlInfo) { PresentationControlInfoView(state: store.state, isDemo: store.isDemoMode) }
        .alert("Go to slide", isPresented: $showsGoTo) {
            TextField(goToPlaceholder, text: $goToText)
                .keyboardType(.numberPad)
            Button("Go") { goToSlide() }
            Button("Cancel", role: .cancel) { goToText = "" }
        } message: {
            Text(goToMessage)
        }
        .confirmationDialog("End the slide show?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("End Slide Show", role: .destructive) { store.send(.end) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.state?.running == true || store.timer.isRunning ? "The audience sees the end of the show." : "Orbit presses Esc on the PC.")
        }
        .task(id: PollKey(active: scenePhase == .active, connection: vm.connectionID, demo: vm.isDemoMode,
                          online: vm.metrics.isOnline, pcID: vm.selectedPCID)) {
            store.configure(vm)
            guard scenePhase == .active else { return }
            await store.poll()
        }
        .onAppear {
            store.setVisible(true)
            #if DEBUG
            OrbitPresentationStore.rotateForSelfTestIfRequested()
            // `ORBIT_PRESENT_SELFTEST_INFO=1`: the "How It Works" sheet, for screenshots without taps.
            if ProcessInfo.processInfo.environment["ORBIT_PRESENT_SELFTEST_INFO"] == "1" {
                Task { try? await Task.sleep(for: .seconds(3)); showsControlInfo = true }
            }
            #endif
        }
        .onDisappear { store.setVisible(false) }
        .accessibilityAction(.magicTap) { if store.canControl { store.send(.next) } }
        .orbitAppearance()
    }

    // MARK: Layout

    @ViewBuilder
    private func content(size: CGSize, wide: Bool) -> some View {
        switch store.phase {
        case .notPaired, .insecure, .olderAgent, .failed:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    notices
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        case .idle:
            lookingForShow
        case .loading where store.state == nil:
            lookingForShow
        default:
            if usesScrollingLayout {
                // Accessibility text sizes on iPhone: the remote can't fit on one screen with the slide and the
                // notes, so the page scrolls. Next stays right under the status; the slide and notes follow in full.
                ScrollView {
                    VStack(spacing: 10) {
                        statusCard
                        notices
                        remoteArea(minHeight: 200)
                            .frame(height: 220)
                        toolsRow
                        if showsSlideArea { slideAndNotesCard(scrollingNotes: false) }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
            } else if wide {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        slideCard(maxPictureHeight: size.height * 0.45)
                        notesCard
                    }
                    .frame(width: size.width * 0.54)
                    .frame(maxHeight: .infinity)
                    VStack(spacing: 12) {
                        statusCard
                        notices
                        remoteArea(minHeight: 130)
                        toolsRow
                    }
                    .frame(maxHeight: .infinity)
                }
            } else if horizontalSizeClass == .regular {
                // iPad in portrait: the big slide card over the notes, the remote below.
                VStack(spacing: 12) {
                    statusCard
                    notices
                    if showsSlideArea {
                        slideCard(maxPictureHeight: size.height * 0.3)
                        notesCard
                    } else {
                        Spacer(minLength: 0)
                    }
                    remoteArea(minHeight: 170)
                        .frame(height: max(170, min(size.height * 0.24, 280)))
                    toolsRow
                }
            } else {
                VStack(spacing: 10) {
                    statusCard
                    notices
                    if showsSlideArea {
                        slideAndNotesCard()
                    } else {
                        Spacer(minLength: 0)
                    }
                    remoteArea(minHeight: max(150, size.height * 0.30))
                        .frame(height: max(150, min(size.height * 0.34, 280)))
                    toolsRow
                }
            }
        }
    }

    private var showsSlideArea: Bool { store.state != nil }

    /// iPhone (portrait or landscape) with an accessibility text size; iPad has room for its own layouts.
    private var usesScrollingLayout: Bool {
        dynamicTypeSize.isAccessibilitySize && !(horizontalSizeClass == .regular && verticalSizeClass == .regular)
    }

    private var lookingForShow: some View {
        VStack(spacing: 14) {
            statusCard
            Spacer()
            ProgressView("Looking for a slide show…").tint(theme.accent)
            Spacer()
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OrbitStatusPill(text: statusText, tint: statusTint, pulsing: store.state?.running == true && !store.isDemoMode && store.staleReason == nil)
                    .layoutPriority(1)
                if store.isSending { ProgressView().controlSize(.small).tint(theme.accent) }
                Spacer(minLength: 4)
                if let state = store.state, store.canControl {
                    Button {
                        showsControlInfo = true
                    } label: {
                        // In a narrow column the status keeps its words and the chip shrinks to its icon.
                        ViewThatFits(in: .horizontal) {
                            Label(controlChipTitle(state), systemImage: controlChipIcon(state))
                                .lineLimit(1)
                                .fixedSize()
                            Image(systemName: controlChipIcon(state))
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(controlTint(state).opacity(0.16), in: Capsule())
                        .foregroundStyle(controlTint(state))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(state.controlExplanation.title). Explains how Orbit controls the slides.")
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                timerStat
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    stat(label: "Clock", value: context.date.formatted(date: .omitted, time: .shortened))
                }
                Spacer(minLength: 4)
                stat(label: "Slide", value: store.state?.positionText ?? "–", alignment: .trailing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Slide")
                    .accessibilityValue(store.state?.spokenPosition ?? "No slide shown")
            }
            if let reason = store.staleReason, store.phase == .ready {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 20, tint: theme.accent, elevated: true)
    }

    private var timerStat: some View {
        Menu {
            Button("Start Timer Now", systemImage: "timer") { store.startTimerNow() }
            Button("Reset Timer", systemImage: "arrow.counterclockwise") { store.resetTimer() }
                .disabled(store.timer.startedAt == nil)
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = store.timer.elapsed(at: context.date)
                stat(label: store.timer.isRunning || elapsed == nil ? "Elapsed" : "Stopped",
                     value: elapsed.map(OrbitPresentationText.clock) ?? "0:00",
                     tint: store.timer.isRunning ? theme.accent : .white)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(elapsed.map(OrbitPresentationText.spokenDuration) ?? "Not started")
                    .accessibilityHint("Opens timer options")
            }
        }
        .buttonStyle(.plain)
    }

    private func stat(label: String, value: String, tint: Color = .white, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch store.phase {
        case .demo, .ready: return store.state?.statusTitle ?? "Connecting"
        case .idle, .loading: return "Connecting"
        case .offline: return "PC offline"
        case .insecure: return "Not encrypted"
        case .olderAgent: return "Update needed"
        case .notPaired: return "No PC"
        case .failed: return "Problem"
        }
    }

    private var statusTint: Color {
        switch store.phase {
        case .ready, .demo:
            guard let state = store.state else { return theme.accent }
            if state.running { return .mint }
            // PowerPoint in front without a deck the PC can read (a dialog): worth a look.
            if state.isBlocked && !state.isReadyInEditor { return .orange }
            return theme.accent
        case .idle, .loading: return theme.accent
        default: return .orange
        }
    }

    private func controlChipTitle(_ state: OrbitPresentationState) -> String {
        switch state.control {
        case .powerpoint: return "PowerPoint"
        case .blocked: return "Start first"
        case .keys, .unknown: return "Keys"
        }
    }

    private func controlChipIcon(_ state: OrbitPresentationState) -> String {
        switch state.control {
        case .powerpoint: return "checkmark.seal.fill"
        case .blocked: return "play.circle.fill"
        case .keys, .unknown: return "keyboard"
        }
    }

    private func controlTint(_ state: OrbitPresentationState) -> Color {
        switch state.control {
        case .powerpoint: return .mint
        case .blocked: return .orange
        case .keys, .unknown: return theme.accent
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        switch store.phase {
        case .demo:
            // One slim line, so the slide and its notes keep their room on a phone.
            Label("Demo mode: a sample deck on a pretend PC. Nothing is sent to a computer.", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .offline:
            VStack(alignment: .leading, spacing: 10) {
                OrbitNotice(title: "PC offline", message: "Wake your PC, or check that it's on the same network as this device.", icon: "wifi.slash", tint: .orange)
                Button {
                    OrbitHaptics.tap()
                    Task { await vm.wakePC() }
                } label: {
                    Label(vm.isWakingUp ? "Waking…" : "Wake PC", systemImage: "power")
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
                .disabled(vm.isWakingUp || vm.pcMAC.isEmpty)
            }
        case .insecure:
            OrbitNotice(title: "Encrypted connection needed", message: OrbitPresentationText.needsEncryption, icon: "lock.shield.fill", tint: .orange)
        case .olderAgent(let version):
            OrbitNotice(title: "Update the Orbit agent",
                        message: "Presentation remote needs a newer Orbit agent on your PC\(version.map { " (this one is \($0))" } ?? ""). Update it from Settings → PC Companion, then come back.",
                        icon: "arrow.down.circle.fill", tint: .orange)
        case .notPaired:
            OrbitEmptyState(icon: "desktopcomputer", title: "Pair a PC first",
                            message: "The presentation remote controls slides on your Windows PC. Pair it from the Tools tab, or try Demo Mode in Settings.",
                            tint: theme.accent)
                .liquidGlass(cornerRadius: 22, tint: theme.accent)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                OrbitNotice(title: "Couldn't reach the slide show", message: message, icon: "exclamationmark.triangle.fill", tint: .orange)
                Button("Try Again") { Task { await store.refresh() } }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
            }
        default:
            EmptyView()
        }
    }

    // MARK: Slide and notes

    /// Portrait: the slide picture and title beside each other, notes below. `scrollingNotes: false` when the
    /// whole page scrolls (accessibility text sizes): the notes then take their full height.
    private func slideAndNotesCard(scrollingNotes: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = store.state, state.running {
                HStack(alignment: .top, spacing: 12) {
                    slidePicture(state)
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 110 : 150)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slideHeadline(state))
                            .font(.headline.weight(.bold))
                            .lineLimit(3)
                        Text(state.title.isEmpty ? " " : state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let seconds = state.slideElapsedSeconds, state.isShowingSlide {
                            Text("On this slide \(OrbitPresentationText.clock(TimeInterval(seconds)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(Color.white.opacity(0.08))
                notesBody(state, scrolls: scrollingNotes)
            } else if let state = store.state {
                preShow(state)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    /// Wide layouts: a big slide card…
    private func slideCard(maxPictureHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = store.state, state.running {
                slidePicture(state)
                    .frame(maxWidth: .infinity, maxHeight: max(120, maxPictureHeight))
                HStack(alignment: .firstTextBaseline) {
                    Text(slideHeadline(state))
                        .font(.headline.weight(.bold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if let seconds = state.slideElapsedSeconds, state.isShowingSlide {
                        Text("On this slide \(OrbitPresentationText.clock(TimeInterval(seconds)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let state = store.state {
                preShow(state)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    /// …and the notes below it.
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state = store.state, state.running {
                notesBody(state)
            } else {
                notesHeader
                Text("Speaker notes appear here while the PowerPoint slide show runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    private var notesHeader: some View {
        HStack(spacing: 8) {
            Label("Speaker notes", systemImage: "text.alignleft")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            // A compact pill, so the notes themselves keep the room.
            HStack(spacing: 0) {
                Button {
                    notesStep = max(-3, notesStep - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 42, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(notesStep <= -3)
                .accessibilityLabel("Smaller notes text")
                Rectangle()
                    .fill(theme.accent.opacity(0.25))
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)
                Button {
                    notesStep = min(8, notesStep + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 42, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(notesStep >= 8)
                .accessibilityLabel("Larger notes text")
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.accent)
            .background(theme.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.2), lineWidth: 1))
        }
    }

    private func notesBody(_ state: OrbitPresentationState, scrolls: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            notesHeader
            if scrolls {
                ScrollView { notesText(state) }
                    .scrollIndicators(.visible)
            } else {
                notesText(state)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notesText(_ state: OrbitPresentationState) -> some View {
        Group {
            if state.showState == .done {
                Text("End of slide show. Press Previous to go back to the last slide.")
                    .foregroundStyle(.secondary)
            } else if state.notes.isEmpty {
                Text(state.app == .powerpoint ? "No speaker notes on this slide." : "Speaker notes come from PowerPoint. With other presenters Orbit only presses keys.")
                    .foregroundStyle(.secondary)
            } else {
                Text(state.notes)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: notesBaseSize * (1 + 0.15 * CGFloat(notesStep))))
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("\(state.slide)-\(state.showState.rawValue)")
    }

    @ViewBuilder
    private func slidePicture(_ state: OrbitPresentationState) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            switch state.showState {
            case .black:
                shape.fill(Color.black)
                Text("Black screen").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            case .white:
                shape.fill(Color.white)
                Text("White screen").font(.caption.weight(.semibold)).foregroundStyle(.black.opacity(0.6))
            case .done:
                shape.fill(Color.black)
                Text("End of show").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            default:
                if store.isDemoMode {
                    PresentationDemoSlide(slide: state.slide, title: state.slideTitle)
                } else if let thumbnail = store.thumbnail, state.canShowThumbnail {
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .scaledToFit()
                        .opacity(thumbnail.key == store.thumbnailKeyForCurrentSlide ? 1 : 0.45)
                    if thumbnail.key != store.thumbnailKeyForCurrentSlide && store.isLoadingThumbnail {
                        ProgressView().tint(.white)
                    }
                } else {
                    shape.fill(Color.white.opacity(0.06))
                    VStack(spacing: 4) {
                        Image(systemName: state.thumbnails ? "photo" : "rectangle.on.rectangle.slash")
                            .font(.title3)
                        Text(state.canShowThumbnail ? "Loading slide…" : "No preview")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slideHeadline(state))
        .accessibilityAddTraits(.isImage)
    }

    private func slideHeadline(_ state: OrbitPresentationState) -> String {
        switch state.showState {
        case .done: return "End of slide show"
        case .black: return "Black screen"
        case .white: return "White screen"
        default:
            if !state.slideTitle.isEmpty { return state.slideTitle }
            return state.spokenPosition ?? "Slide show running"
        }
    }

    /// Before the show: what's waiting in PowerPoint, or how keys work, and Start.
    private func preShow(_ state: OrbitPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: preShowIcon(state), tint: state.isBlocked && !state.isReadyInEditor ? .orange : theme.accent, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preShowTitle(state))
                        .font(.headline.weight(.bold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    Text(preShowMessage(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Side by side, or stacked at accessibility text sizes so both labels stay readable.
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                Button {
                    store.send(.start)
                } label: {
                    Label("Start Slide Show", systemImage: "play.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(OrbitProminentButtonStyle(colors: [theme.accent, theme.secondary]))
                .disabled(!store.canControl)
                Button {
                    store.send(.startCurrent)
                } label: {
                    Text(state.isReadyInEditor && state.slide > 1 ? "From Slide \(state.slide)" : "From Current")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 16))
                .disabled(!store.canControl)
            }
            Spacer(minLength: 0)
        }
    }

    private func preShowIcon(_ state: OrbitPresentationState) -> String {
        if state.isReadyInEditor { return "rectangle.inset.filled.and.person.filled" }
        return state.isBlocked ? "hand.raised.fill" : "keyboard"
    }

    private func preShowTitle(_ state: OrbitPresentationState) -> String {
        if state.isReadyInEditor { return state.title.isEmpty ? "Ready in PowerPoint" : "Ready: \(state.title)" }
        if state.isBlocked { return "PowerPoint is in front" }
        if state.app == .powerpoint { return "No slide show yet" }
        return "Present from any app"
    }

    private func preShowMessage(_ state: OrbitPresentationState) -> String {
        let count = "\(state.slides) slide\(state.slides == 1 ? "" : "s")"
        if state.isBlocked {
            // PowerPoint's editor (or one of its dialogs) is in front: Start works, keys would edit the slides.
            if state.isReadyInEditor {
                return "\(count). PowerPoint is the window in front on the PC: start the slide show here, then use Next and Previous."
            }
            return state.controlExplanation.detail
        }
        if state.isReadyInEditor {
            // PowerPoint isn't the window in front (its editor would make this "blocked"), so the PC sends
            // Start to the app in front as F5, unless it can't tell which app that is.
            return "\(count). Start runs this slide show when PowerPoint is the window in front on the PC; with another app in front, Start presses F5 in that app. Notes, the slide picture and the timer follow PowerPoint's show."
        }
        return "No PowerPoint slide show is open, so Orbit presses keys on the PC. Click into your slides there (Google Slides, a PDF), then use Next and Previous. In a browser, start presenting on the PC: F5 would reload the page."
    }

    // MARK: Next / previous

    private func remoteArea(minHeight: CGFloat) -> some View {
        let state = store.state
        let blocked = state?.isBlocked == true
        return GeometryReader { proxy in
            HStack(spacing: 12) {
                Button {
                    store.send(.previous)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 30, weight: .bold))
                        Text("Back")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .liquidGlass(cornerRadius: 24, tint: .white)
                }
                .frame(width: max(84, proxy.size.width * 0.28))
                .accessibilityLabel("Previous slide")

                Button {
                    store.send(.next)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: min(64, max(40, proxy.size.height * 0.28)), weight: .heavy))
                        Text("Next")
                            .font(.title2.weight(.bold))
                        Text(nextCaption(state))
                            .font(.caption)
                            .foregroundStyle(.black.opacity(0.65))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(colors: blocked ? [Color.gray.opacity(0.55), Color.gray.opacity(0.4)] : [theme.accent, theme.secondary],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Next slide")
                .accessibilityValue(state?.spokenPosition ?? "")
                .accessibilityHint(blocked ? "Start the slide show first" : "")
            }
            .buttonStyle(OrbitPressableStyle(scale: 0.97, haptic: false))
            .disabled(!store.canControl)
            // A swipe (left = next, right = previous) wins over the buttons, so it never also counts as a tap
            // (two slides); a tap doesn't move far enough to start it.
            .highPriorityGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        guard store.canControl, abs(value.translation.width) > abs(value.translation.height) * 1.5,
                              abs(value.translation.width) > 60 else { return }
                        store.send(value.translation.width < 0 ? .next : .previous)
                    }
            )
        }
        .frame(minHeight: minHeight)
    }

    private func nextCaption(_ state: OrbitPresentationState?) -> String {
        guard let state else { return store.lastResult ?? " " }
        if state.isBlocked { return "Start the slide show first" }
        if state.running && state.showState == .done { return "Ends the slide show" }
        if state.showState == .black || state.showState == .white { return "Shows the slide again" }
        if state.isShowingSlide {
            return state.slide < state.slides ? "Slide \(state.slide + 1) of \(state.slides)" : "End of slide show"
        }
        // Key presses (Google Slides, a PDF): the PC can't number the slides, so say what the last press did.
        if let result = store.lastResult { return result }
        return state.control == .powerpoint ? " " : "Presses → on the PC"
    }

    // MARK: Tools

    private var toolsRow: some View {
        let state = store.state
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 3 : 5)
        return LazyVGrid(columns: columns, spacing: 8) {
            Menu {
                Button("From the Beginning", systemImage: "backward.end.fill") { store.send(.start) }
                Button("From the Current Slide", systemImage: "play.circle") { store.send(.startCurrent) }
            } label: {
                toolLabel(state?.running == true ? "Restart" : "Start", icon: "play.fill", tint: theme.accent)
            }
            .accessibilityLabel(state?.running == true ? "Restart the slide show" : "Start the slide show")

            Button { store.send(.black) } label: {
                toolLabel("Black", icon: "rectangle.fill", tint: .white, active: state?.showState == .black)
            }
            .accessibilityLabel(state?.showState == .black ? "Show the slide again" : "Black screen")

            Button { store.send(.white) } label: {
                toolLabel("White", icon: "rectangle", tint: .white, active: state?.showState == .white)
            }
            .accessibilityLabel(state?.showState == .white ? "Show the slide again" : "White screen")

            Button {
                goToText = ""
                showsGoTo = true
            } label: {
                toolLabel("Go to", icon: "number", tint: theme.accent)
            }
            .accessibilityLabel("Go to slide")

            Button { confirmsEnd = true } label: {
                toolLabel("End", icon: "stop.fill", tint: .orange)
            }
            .accessibilityLabel("End the slide show")
        }
        .buttonStyle(OrbitPressableStyle(scale: 0.95, haptic: false))
        .disabled(!store.canControl)
    }

    private func toolLabel(_ title: String, icon: String, tint: Color, active: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(active ? Color.black : tint)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(active ? tint : tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }

    // MARK: Go to slide

    private var goToRange: ClosedRange<Int> {
        if let slides = store.state?.slides, slides > 0, store.state?.app == .powerpoint { return 1...slides }
        return OrbitPresentationAction.slideRange
    }

    private var goToPlaceholder: String { "Slide number" }

    private var goToMessage: String {
        if let state = store.state, state.app == .powerpoint, state.slides > 0 {
            return "Choose a slide from 1 to \(state.slides)."
        }
        return "Orbit types the number and Enter on the PC, which most presenters understand."
    }

    private func goToSlide() {
        let digits = goToText.filter(\.isNumber)
        goToText = ""
        guard let number = Int(digits), goToRange.contains(number) else {
            store.show("Choose a slide from \(goToRange.lowerBound) to \(goToRange.upperBound).", kind: .failure)
            return
        }
        store.send(.goto, slide: number)
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.kind == .failure ? "exclamationmark.triangle.fill" : (toast.kind == .success ? "checkmark.circle.fill" : "info.circle.fill"))
                    .foregroundStyle(toast.kind == .failure ? .orange : (toast.kind == .success ? .mint : theme.accent))
                Text(toast.message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.bottom, 84)
            .frame(maxWidth: 560)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            // It sits over the Next area: taps go through to the remote, and it fades by itself (VoiceOver
            // already heard it as an announcement).
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Demo slide art

/// What a demo slide looks like (no PC, so no picture from PowerPoint).
private struct PresentationDemoSlide: View {
    let slide: Int
    let title: String

    private static let colors: [Color] = [.orange, .blue, .green, .purple, .yellow, .gray]

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 320
            ZStack(alignment: .topLeading) {
                Color(white: 0.97)
                VStack(alignment: .leading, spacing: 0) {
                    Self.colors[(max(slide, 1) - 1) % Self.colors.count]
                        .frame(height: 38 * scale)
                        .overlay(alignment: .leading) {
                            Text(title)
                                .font(.system(size: 17 * scale, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.leading, 14 * scale)
                        }
                    VStack(alignment: .leading, spacing: 9 * scale) {
                        ForEach(0..<3, id: \.self) { row in
                            Capsule()
                                .fill(Color.black.opacity(0.18))
                                .frame(width: (row == 2 ? 150 : 220) * scale, height: 7 * scale)
                        }
                    }
                    .padding(14 * scale)
                }
                Text("\(slide)")
                    .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.black.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8 * scale)
            }
        }
    }
}

// MARK: - How Orbit controls the slides

struct PresentationControlInfoView: View {
    let state: OrbitPresentationState?
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    var body: some View {
        NavigationStack {
            List {
                if let state {
                    Section("Right now") {
                        row(state.controlExplanation.title, detail: state.controlExplanation.detail,
                            icon: state.control == .powerpoint ? "checkmark.seal.fill" : (state.control == .blocked ? "play.circle.fill" : "keyboard"),
                            tint: state.control == .blocked ? .orange : (state.control == .powerpoint ? .mint : theme.accent))
                    }
                    .orbitRow()
                }
                Section("PowerPoint on the PC") {
                    row("Controlled directly", detail: "While a PowerPoint slide show runs, Orbit talks to PowerPoint itself. It shows slide x of y, the slide, your speaker notes and the show's own timer, and it works even if another window is in front.",
                        icon: "rectangle.inset.filled.and.person.filled", tint: .mint)
                    row("Before the show", detail: "Start begins the slide show from slide 1; From Current starts at the slide selected in PowerPoint. If PowerPoint's editor is in front, Orbit won't press Next or Black there, because the keys would change your slides.",
                        icon: "play.fill", tint: theme.accent)
                }
                .orbitRow()
                Section("Any other presenter") {
                    row("Key presses", detail: "Google Slides, a PDF viewer or Keynote in a browser get key presses: → and ← to move, F5 to start, Esc to end, B and W for a black or white screen, and the slide number plus Enter for Go to. Click into the slides on the PC once so they receive them.",
                        icon: "keyboard", tint: theme.accent)
                    row("Browsers", detail: "In a browser, F5 reloads the page. Start the presentation in Google Slides itself (Ctrl+F5 or the Slideshow button), then use Next and Previous here.",
                        icon: "safari", tint: .orange)
                    row("Timer", detail: "Without PowerPoint the PC can't tell when the show started, so the timer starts with Start or your first slide change. Tap it to restart or reset it.",
                        icon: "timer", tint: theme.accent)
                }
                .orbitRow()
                Section {
                    Text(isDemo ? "Demo mode never contacts a PC." : "Speaker notes and slide pictures travel only between this device and your PC, over Orbit's encrypted local connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .orbitRow()
            }
            .orbitListChrome(isOnline: true)
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .orbitAppearance()
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
