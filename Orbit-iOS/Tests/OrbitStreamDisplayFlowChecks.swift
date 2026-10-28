import Foundation

// The Second Screen session and the Fill Screen model (Shared/OrbitStreamDisplayModels.swift) driven against a
// scripted PC, a fake Sunshine host and a fake stream screen: start, stop, failures, PC switches while a read runs,
// cancelled reads, the Desktop quit rule, normal streams while a second screen runs or was left on, demo mode.
// Run by OrbitStreamDisplayChecks --unit (Tests/check_stream_display.py).

/// The PC: answers like orbit_stream_display.py, and can hold a status read until `release()`.
@MainActor
final class ScriptedDisplayPC: OrbitStreamDisplayService {
    var features: Set<String>? = ["streamDisplay", "secondScreen"]
    var state: OrbitStreamDisplayStatus
    var statusError: Error?
    var secondScreenOnError: Error?
    var secondScreenOffError: Error?
    var fillError: Error?
    var startSunshineError: Error?
    /// `placement` in /second-screen answers.
    var placement = "done"
    /// Holds the next status read until `release()`.
    var holdNextStatus = false
    /// Runs when Sunshine is started (the check flips the state there).
    var onStartSunshine: (() -> Void)?
    private(set) var calls: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ state: OrbitStreamDisplayStatus) { self.state = state }

    var statusReads: Int { calls.filter { $0 == "status" }.count }
    var isHolding: Bool { !held.isEmpty }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func features() async throws -> Set<String>? {
        calls.append("features")
        return features
    }

    func status() async throws -> OrbitStreamDisplayStatus {
        calls.append("status")
        // Answered as the PC was when asked, however long the answer takes.
        let asked = state
        if holdNextStatus {
            holdNextStatus = false
            await withCheckedContinuation { held.append($0) }
        }
        if let statusError { throw statusError }
        return asked
    }

    func addMode(size: OrbitDisplaySize, refreshRate: Int) async throws -> OrbitStreamDisplayResult {
        calls.append("modes \(size.key)@\(refreshRate)")
        state.virtualDisplay.resolutions.append(size.key)
        state.virtualDisplay.modes.append("\(size.key)@\(refreshRate)")
        return result(changed: true)
    }

    func setFill(enabled: Bool, onlyDisplay: Bool) async throws -> OrbitStreamDisplayResult {
        calls.append("fill \(enabled ? "on" : "off")")
        if let fillError { throw fillError }
        state.fill = .init(enabled: enabled, onlyDisplay: onlyDisplay)
        state.config.outputName = enabled || state.secondScreen.active ? state.virtualDisplay.deviceId : nil
        return result(changed: true)
    }

    func setSecondScreen(enabled: Bool, size: OrbitDisplaySize?, refreshRate: Int, position: String) async throws -> OrbitStreamDisplayResult {
        calls.append(enabled ? "second on \(size?.key ?? "-") \(position)" : "second off")
        if enabled, let secondScreenOnError { throw secondScreenOnError }
        if !enabled, let secondScreenOffError { throw secondScreenOffError }
        let changed = state.secondScreen.active != enabled || (enabled && state.secondScreen.position != position)
        state.secondScreen.active = enabled
        state.secondScreen.position = enabled ? position : state.secondScreen.position
        state.secondScreen.placement = enabled ? placement : nil
        var answer = result(changed: changed)
        answer.placement = enabled ? placement : nil
        return answer
    }

    func revert() async throws -> OrbitStreamDisplayResult {
        calls.append("revert")
        state.fill = .init()
        state.secondScreen.active = false
        return result(changed: true)
    }

    func saveSunshineLogin(username: String, password: String) async throws {
        calls.append("login \(username)")
        state.loginSaved = true
    }

    func startSunshine() async throws {
        calls.append("start sunshine")
        if let startSunshineError { throw startSunshineError }
        onStartSunshine?()
    }

    private func result(changed: Bool) -> OrbitStreamDisplayResult {
        var answer = OrbitStreamDisplayResult()
        answer.changed = changed
        answer.restarted = changed
        answer.sunshineReady = changed ? true : nil
        answer.display = state
        return answer
    }
}

/// Sunshine as the session sees it.
@MainActor
final class FakeSunshineHost: OrbitSecondScreenHost {
    var isPaired = true
    var reachable = true
    var lastError: String?
    var lastRefreshed: Date?
    var isRefreshing = false
    var desktopAppID: Int? = 5
    var runningAppID: Int?
    private(set) var refreshes = 0
    private(set) var quits = 0
    /// Runs on every refresh (a check can change the world there, as a user would meanwhile).
    var onRefresh: (() -> Void)?

    func refresh() async {
        refreshes += 1
        lastRefreshed = Date()
        onRefresh?()
    }

    func quitRunningApp() async {
        quits += 1
        runningAppID = nil
    }
}

/// The stream screen.
@MainActor
final class FakeStreamScreen: OrbitSecondScreenStreams {
    var otherStreamIsOpen = false
    var secondScreenIsOpen = false
    var onPresentationChange: (@MainActor (Bool) -> Void)?
    private(set) var ends = 0
    private(set) var launches: [Int] = []

    /// What the launch closure does in the apps: open the stream of that app.
    func launch(_ appID: Int) -> Bool {
        launches.append(appID)
        secondScreenIsOpen = true
        onPresentationChange?(true)
        return true
    }

    func endSecondScreen() {
        ends += 1
        secondScreenIsOpen = false
        onPresentationChange?(false)
    }
}

@MainActor
enum OrbitStreamDisplayFlowChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        OrbitStreamDisplayChecks.expect(condition(), label)
    }

    static func run() async {
        await refreshAcrossAPCSwitch()
        await cancelledAndFailedReads()
        await startAndStop()
        await startStopsWhenSomethingElseStarted()
        await stopFailureAndTheDesktopRule()
        await sessionPCAndNormalStreams()
        await lightChecksAndDemo()
        await fillModelFlows()
    }

    // MARK: Helpers

    static let size = OrbitDisplaySize(width: 2732, height: 2048)

    static func ready() -> OrbitStreamDisplayStatus {
        var status = OrbitStreamDisplayChecks.ready(listing: ["1920x1080", "2732x2048"])
        status.sunshineRunning = true
        status.virtualDisplay.modes = ["1920x1080@60", "2732x2048@60"]
        return status
    }

    static func context(_ pcID: String, _ pc: ScriptedDisplayPC, online: Bool = true, demo: Bool = false) -> OrbitStreamDisplayContext {
        OrbitStreamDisplayContext(pcID: pcID, pcName: pcID, isDemo: demo, isOnline: online, hasPC: true, canStartSunshine: true,
                                  makeClient: { throw OrbitError(message: "The checks have no real PC.") }, makeService: { pc })
    }

    static func fastSession(_ screen: FakeStreamScreen) -> OrbitSecondScreenSession {
        var timing = OrbitSecondScreenSession.Timing()
        timing.sunshineQuickPoll = 1_000_000
        timing.sunshinePoll = 1_000_000
        timing.hostBusyPoll = 1_000_000
        timing.placementCheck = 1_000_000
        timing.idlePoll = 1_000_000
        timing.sunshineStartPoll = 1_000_000
        return OrbitSecondScreenSession(streams: screen, timing: timing)
    }

    /// Waits (at most 4 s) until `condition` holds.
    static func wait(_ label: String, _ condition: () -> Bool) async {
        for _ in 0..<4000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(false, "timed out: \(label)")
    }

    static func facts(_ host: FakeSunshineHost) -> OrbitSecondScreenSession.HostFacts {
        .init(isPaired: host.isPaired, reachable: host.reachable, hasDesktopApp: host.desktopAppID != nil)
    }

    // MARK: Reads

    /// A PC switch while the first PC's read is still running: the next PC's read starts at once, nothing stays
    /// stuck on "Checking", and the earlier answer never lands on the next PC.
    static func refreshAcrossAPCSwitch() async {
        OrbitStreamDisplayFeatureCache.forget()
        let session = fastSession(FakeStreamScreen())
        var stateA = ready()
        stateA.reason = "A"
        let pcA = ScriptedDisplayPC(stateA)
        pcA.holdNextStatus = true
        var stateB = ready()
        stateB.reason = "B"
        let pcB = ScriptedDisplayPC(stateB)
        let first = Task { await session.refresh(context: context("A", pcA)) }
        await wait("A's read reaches the PC") { pcA.isHolding }
        expect(session.isRefreshing && session.availability == .checking, "reading A")
        // Switching PCs (the Mac's PC menu) while A's read runs; the sheet's next read is not forced.
        await session.refresh(context: context("B", pcB))
        expect(session.statusPCID == "B" && session.availability == .available && session.status?.reason == "B",
               "the next PC's read is not blocked by the earlier PC's")
        expect(!session.isRefreshing, "nothing keeps showing Checking after the switch")
        pcA.release()
        await first.value
        expect(session.statusPCID == "B" && session.status?.reason == "B" && !session.isRefreshing, "the earlier PC's late answer is dropped")

        // A slow read, then a forced one: the older answer never replaces the newer one.
        let pcC = ScriptedDisplayPC(ready())
        await session.refresh(context: context("C", pcC))
        pcC.holdNextStatus = true
        let slow = Task { await session.refresh(context: context("C", pcC)) }
        await wait("the slow read reaches the PC") { pcC.isHolding }
        pcC.state.secondScreen.active = true
        await session.refresh(context: context("C", pcC), force: true)
        expect(session.isActiveOnPC("C"), "the forced read lands")
        pcC.release()
        await slow.value
        expect(session.isActiveOnPC("C"), "the slower, older read does not undo it")
    }

    static func cancelledAndFailedReads() async {
        OrbitStreamDisplayFeatureCache.forget()
        let session = fastSession(FakeStreamScreen())
        let pc = ScriptedDisplayPC(ready())
        pc.statusError = URLError(.cancelled)
        await session.refresh(context: context("A", pc))
        expect(session.availability == .unknown && session.problem == nil, "a cancelled first read is no failure")
        pc.statusError = nil
        await session.refresh(context: context("A", pc))
        expect(session.availability == .available, "the next read works")
        pc.statusError = URLError(.cancelled)
        await session.refresh(context: context("A", pc), force: true)
        expect(session.problem == nil && session.availability == .available, "a cancelled later read shows nothing")
        pc.statusError = OrbitError(message: "Sunshine answered HTTP 500.", statusCode: 502)
        await session.refresh(context: context("A", pc), force: true)
        expect(session.problem?.title == "Sunshine didn't answer", "a failed later read is shown")
        pc.statusError = nil
        await session.refresh(context: context("A", pc), force: true)
        expect(session.problem == nil, "the next read that works clears it")
        pc.statusError = URLError(.timedOut)
        await session.refresh(context: context("A", pc), force: true, quiet: true)
        expect(session.problem == nil, "a quiet (background) read never shows its failure")
    }

    // MARK: Start and stop

    static func startAndStop() async {
        OrbitStreamDisplayFeatureCache.forget()
        let screen = FakeStreamScreen()
        let session = fastSession(screen)
        let pc = ScriptedDisplayPC(ready())
        let host = FakeSunshineHost()
        let ctx = context("A", pc)
        await session.refresh(context: ctx)
        expect(session.startBlocker(context: ctx, host: facts(host), size: size) == nil, "a ready PC can start")
        expect(session.startBlocker(context: ctx, host: nil, size: size) == "Checking A…", "a screen host still on the earlier PC waits")
        session.startSession(context: ctx, host: host, size: size, refreshRate: 60, position: .left) { screen.launch($0) }
        expect(session.isBusy && session.sessionPCID == "A", "busy at once")
        await wait("the stream opens") { session.isStreaming }
        expect(pc.calls.contains("second on 2732x2048 left"), "the PC gets this screen's size and side")
        expect(screen.launches == [5] && host.refreshes >= 1, "Sunshine's Desktop streams once Sunshine answered after the change")
        expect(session.problem == nil && session.isActiveOnPC("A"), "on, without a problem")
        expect(session.checkNormalStream(pcID: "A") == .streamingHere, "a normal stream never replaces it")

        // The stream ends (its controls): the Desktop session this device launched closes, then the display turns off.
        pc.state.streamActive = true   // the stream's sockets close a moment later
        host.runningAppID = 5
        host.onRefresh = { pc.state.streamActive = false }
        screen.endSecondScreen()
        await wait("the session ends") { !session.isBusy && session.phase == .idle }
        expect(host.quits == 1, "the Desktop session this device launched is closed")
        expect(pc.calls.last == "second off" && !session.isActiveOnPC("A"), "the virtual display turns off")
        expect(session.notice?.message == "The second screen is off. Sunshine on A streams the main monitor again.", "says where Sunshine goes back to")
        expect(session.sessionPCID == nil && session.problem == nil, "nothing left over")
    }

    /// Something started between Start and the stream: the session stops before streaming, the virtual display
    /// stays on, and Turn Off still reaches the PC.
    static func startStopsWhenSomethingElseStarted() async {
        OrbitStreamDisplayFeatureCache.forget()
        let screen = FakeStreamScreen()
        let session = fastSession(screen)
        let pc = ScriptedDisplayPC(ready())
        let host = FakeSunshineHost()
        let ctx = context("A", pc)
        await session.refresh(context: ctx)
        // The user starts a game on this device while Sunshine restarts.
        host.onRefresh = { screen.otherStreamIsOpen = true }
        session.startSession(context: ctx, host: host, size: size, refreshRate: 60, position: .right) { screen.launch($0) }
        await wait("the start stops") { !session.isBusy }
        expect(screen.launches.isEmpty && session.problem?.title == "Another stream opened", "the other stream is never replaced")
        expect(session.sessionPCID == "A" && session.isActiveOnPC("A"), "the virtual display stays on, and the session keeps its PC")
        screen.otherStreamIsOpen = false
        host.onRefresh = nil

        // Someone starts streaming from the PC meanwhile.
        let busyPC = ScriptedDisplayPC(ready())
        let busy = context("B", busyPC)
        let screen2 = FakeStreamScreen()
        let session3 = fastSession(screen2)
        await session3.refresh(context: busy)
        host.onRefresh = { busyPC.state.streamActive = true }
        session3.startSession(context: busy, host: host, size: size, refreshRate: 60, position: .right) { screen2.launch($0) }
        await wait("the start stops for someone else's stream") { !session3.isBusy }
        expect(screen2.launches.isEmpty && session3.problem?.title == "Someone is streaming", "never collides with someone else's stream")
        host.onRefresh = nil

        // "Show It Here" while another device streams the second screen: blocked before anything is sent.
        let shared = ScriptedDisplayPC(ready())
        shared.state.secondScreen.active = true
        shared.state.streamActive = true
        let showCtx = context("C", shared)
        let screen4 = FakeStreamScreen()
        let session4 = fastSession(screen4)
        await session4.refresh(context: showCtx)
        expect(session4.startBlocker(context: showCtx, host: facts(host), size: size) == "Someone is streaming from C right now. End that stream first.",
               "Show It Here waits for the other device's stream")
        // Pressed anyway (the read was older): the PC's answer still stops it, and nothing here owns that display.
        session4.startSession(context: showCtx, host: host, size: size, refreshRate: 60, position: .right) { screen4.launch($0) }
        await wait("Show It Here stops") { !session4.isBusy }
        expect(screen4.launches.isEmpty && session4.problem?.title == "Someone is streaming" && session4.sessionPCID == nil,
               "the second screen another device turned on is left to it")

        // The PC refuses the start (409 while an app runs): nothing is kept.
        let refusing = ScriptedDisplayPC(ready())
        refusing.secondScreenOnError = OrbitError(message: "An app is still running in Sunshine.", statusCode: 409)
        let screen5 = FakeStreamScreen()
        let session5 = fastSession(screen5)
        await session5.refresh(context: context("D", refusing))
        session5.startSession(context: context("D", refusing), host: host, size: size, refreshRate: 60, position: .right) { screen5.launch($0) }
        await wait("the refused start ends") { !session5.isBusy }
        expect(session5.problem == OrbitStreamDisplayProblem(title: "Not possible right now", message: "An app is still running in Sunshine.")
               && session5.sessionPCID == nil, "a refused start shows the PC's sentence")
    }

    static func stopFailureAndTheDesktopRule() async {
        // The rule itself.
        typealias Session = OrbitSecondScreenSession
        expect(Session.shouldQuitDesktop(runningAppID: 5, launchedAppID: 5, desktopAppID: 5, streamActive: true), "this device's own Desktop session closes")
        expect(!Session.shouldQuitDesktop(runningAppID: 5, launchedAppID: nil, desktopAppID: 5, streamActive: true),
               "someone else watching the Desktop is never cut off")
        expect(Session.shouldQuitDesktop(runningAppID: 5, launchedAppID: nil, desktopAppID: 5, streamActive: false), "a Desktop left running closes")
        expect(!Session.shouldQuitDesktop(runningAppID: 9, launchedAppID: 5, desktopAppID: 5, streamActive: false), "never another app")
        expect(!Session.shouldQuitDesktop(runningAppID: nil, launchedAppID: 5, desktopAppID: 5, streamActive: false), "nothing running, nothing to close")

        // Turn Off for a second screen left on while another device watches its Desktop: no quit; the PC's 409 shows,
        // and Turn Off can try again.
        OrbitStreamDisplayFeatureCache.forget()
        let screen = FakeStreamScreen()
        let session = fastSession(screen)
        let pc = ScriptedDisplayPC(ready())
        pc.state.secondScreen.active = true
        pc.state.secondScreen.position = "right"
        pc.state.streamActive = true
        pc.secondScreenOffError = OrbitError(message: "Someone is streaming from this PC right now.", statusCode: 409)
        let host = FakeSunshineHost()
        host.runningAppID = 5
        let ctx = context("A", pc)
        await session.refresh(context: ctx)
        expect(session.isLeftOn("A") && session.checkNormalStream(pcID: "A") == .leftOn, "left on: normal streams ask first")
        session.stopSession(context: ctx, host: host)
        await wait("Turn Off ends") { !session.isBusy }
        expect(host.quits == 0, "the other device's session stays")
        expect(session.problem?.message == "Someone is streaming from this PC right now." && session.sessionPCID == "A",
               "the 409 shows, and the session keeps the PC for another try")
        pc.secondScreenOffError = nil
        pc.state.streamActive = false
        session.stopSession(context: ctx, host: host)
        await wait("the second Turn Off ends") { !session.isBusy }
        expect(!session.isActiveOnPC("A") && session.problem == nil && session.sessionPCID == nil, "the next Turn Off works")
        expect(host.quits == 1, "the Desktop left running is closed once nobody watches it")
    }

    /// A session for one PC while another PC is selected; normal streams while it starts or runs.
    static func sessionPCAndNormalStreams() async {
        OrbitStreamDisplayFeatureCache.forget()
        let screen = FakeStreamScreen()
        let session = fastSession(screen)
        let pcA = ScriptedDisplayPC(ready())
        let pcB = ScriptedDisplayPC(ready())
        pcB.state.secondScreen.active = true   // left on there by another device
        let host = FakeSunshineHost()
        await session.refresh(context: context("A", pcA))
        pcA.holdNextStatus = true   // the start's final check waits, so the start can be watched mid-way
        session.startSession(context: context("A", pcA), host: host, size: size, refreshRate: 60, position: .right) { screen.launch($0) }
        await wait("the start reaches its last check") { pcA.isHolding }
        expect(session.checkNormalStream(pcID: "A") == .starting, "no normal stream while it starts")
        pcA.release()
        await wait("streaming A") { session.isStreaming }

        // The main window switches to B while this device streams A's second screen.
        await session.refresh(context: context("B", pcB))
        expect(session.isLeftOn("B") && !session.canTurnOff("B"), "B's left-on second screen cannot be turned off while A streams here")
        expect(session.startBlocker(context: context("B", pcB), host: facts(host), size: size) == "A second screen is running for A. Turn it off there first.",
               "one second screen at a time")
        session.stopSession(context: context("B", pcB), host: host)
        expect(screen.ends == 0 && session.isStreaming, "Turn Off for B never ends A's stream")
        expect(session.checkNormalStream(pcID: "B") == .streamingHere, "no normal stream while this device is a second screen")

        // The stream ends: A turns off, and B can be turned off next.
        screen.endSecondScreen()
        await wait("A turns off") { !session.isBusy && session.phase == .idle }
        await session.refresh(context: context("B", pcB))
        expect(session.canTurnOff("B") && session.checkNormalStream(pcID: "B") == .leftOn, "B's left-on second screen comes back to the user")
        expect(session.checkNormalStream(pcID: "A") == .go, "a PC without a second screen streams as usual")
    }

    static func lightChecksAndDemo() async {
        OrbitStreamDisplayFeatureCache.forget()
        let session = fastSession(FakeStreamScreen())
        let pc = ScriptedDisplayPC(ready())
        pc.state.secondScreen.active = true
        await session.checkIfLeftOn(context: context("A", pc))
        await session.checkIfLeftOn(context: context("A", pc))
        expect(pc.statusReads == 1 && session.isLeftOn("A"), "the Stream tab's check reads the PC at most every two minutes")
        await session.checkIfLeftOn(context: context("A", pc, online: false))
        expect(pc.statusReads == 1, "never while the PC is offline")
        let older = ScriptedDisplayPC(ready())
        older.features = nil
        await session.checkIfLeftOn(context: context("Old", older))
        await session.checkIfLeftOn(context: context("Old", older))
        expect(older.statusReads == 0 && older.calls.filter { $0 == "features" }.count == 1 && !session.isLeftOn("Old"),
               "an older companion costs one capabilities request")

        // Demo mode: Start shows the "on" state without a PC; Turn Off goes back.
        let screen = FakeStreamScreen()
        let demoSession = fastSession(screen)
        let nobody = ScriptedDisplayPC(ready())
        let demo = context("demo", nobody, demo: true)
        await demoSession.refresh(context: demo)
        demoSession.startSession(context: demo, host: FakeSunshineHost(), size: size, refreshRate: 60, position: .left) { screen.launch($0) }
        expect(demoSession.isActiveOnPC("demo") && demoSession.status?.secondScreen.position == "left" && demoSession.notice?.kind == .demo,
               "demo: Start shows the second screen on")
        demoSession.move(to: .right, context: demo, refreshRate: 60)
        expect(demoSession.status?.secondScreen.position == "right", "demo: the side changes")
        demoSession.stopSession(context: demo, host: nil)
        expect(!demoSession.isActiveOnPC("demo") && nobody.calls.isEmpty && screen.launches.isEmpty, "demo: nothing is sent or streamed")
    }

    // MARK: Fill Screen

    static func fillModelFlows() async {
        OrbitStreamDisplayFeatureCache.forget()
        let model = OrbitFillScreenSetupModel()
        model.sunshineStartPoll = 1_000_000
        let pcA = ScriptedDisplayPC(ready())
        pcA.statusError = URLError(.cancelled)
        model.configure(context("A", pcA))
        await model.load(force: true)
        expect(model.availability == .unknown && model.outcome == nil, "a cancelled read is no failure")
        pcA.statusError = nil

        // Another PC while a read runs: the next PC's read starts at once, the earlier answer is dropped.
        pcA.holdNextStatus = true
        let slow = Task { await model.load(force: true) }
        await wait("A's read reaches the PC") { pcA.isHolding }
        var stateB = ready()
        stateB.reason = "B"
        let pcB = ScriptedDisplayPC(stateB)
        model.configure(context("B", pcB))
        await model.load()
        expect(model.availability == .available && model.status?.reason == "B" && !model.isRefreshing, "the next PC reads at once")
        pcA.release()
        await slow.value
        expect(model.status?.reason == "B", "the earlier PC's answer is dropped")

        // A failed later read, then one that works.
        pcB.statusError = URLError(.timedOut)
        await model.load(force: true)
        expect(model.outcome?.title == "Couldn't check again", "a failed later read is shown")
        pcB.statusError = nil
        await model.load(force: true)
        expect(model.outcome == nil, "the next read that works clears it")

        // Set Up This PC, then Turn Off while the second screen stays on.
        await model.setUp(size: size, refreshRate: 60, onlyDisplay: false)
        expect(pcB.calls.contains("fill on") && model.status?.fillsScreen(size: size, refreshRate: 60) == true, "Set Up This PC")
        pcB.state.secondScreen.active = true
        await model.turnOff()
        expect(model.outcome?.message.contains("Second Screen is still on") == true, "Turn Off says the second screen still shows the extra display")
        pcB.fillError = OrbitError(message: "Someone is streaming from this PC right now.", statusCode: 409)
        await model.turnOff()
        expect(model.outcome?.title == "Not possible right now" && model.outcome?.isError == true && model.work == nil, "a refused change shows the PC's sentence")

        // Sunshine stopped: Start Sunshine, then the page reads the PC until Sunshine answers.
        var stopped = ready()
        stopped.sunshineRunning = false
        stopped.sunshineVersion = nil
        stopped.sunshineSupported = nil
        let pcC = ScriptedDisplayPC(stopped)
        model.configure(context("C", pcC))
        await model.load()
        expect(model.setUpBlocker() == "Start Sunshine on the PC first.", "Set Up waits for Sunshine")
        var reads = 0
        pcC.onStartSunshine = { reads = pcC.statusReads }
        await model.startSunshine()
        expect(pcC.calls.contains("start sunshine") && model.work == nil && model.outcome?.title == "Sunshine is still starting", "Sunshine that never answers is said so")
        pcC.onStartSunshine = {
            pcC.state.sunshineRunning = true
            pcC.state.sunshineVersion = "2026.1017.152030"
            pcC.state.sunshineSupported = true
        }
        await model.startSunshine()
        expect(model.status?.sunshineStopped == false && model.outcome == nil && model.work == nil && pcC.statusReads > reads,
               "Start Sunshine reads the PC again until Sunshine answers")
    }
}
