import Combine
import Foundation
#if os(iOS)
import MoonlightCore
import UIKit
#endif

// The stateful parts of the Fill Screen setup (DESIGN F5) and Second Screen (F9) on iPhone/iPad and Mac: what the
// screens show, the order of the PC calls and how they recover from failures, PC switches and cancelled reads.
//
// Foundation and Combine only (plus MoonlightCore's idle timer on iPhone/iPad), so Tests/check_stream_display.py
// compiles this file and drives both models against a scripted PC. Sunshine hosts and the stream screen come in
// through the small protocols below; their Moonlight adapters are in Streaming/OrbitSecondScreen.swift.

// MARK: - Slow changes

/// Keeps the app working while the PC takes its time (someone walks over to approve an administrator
/// prompt): iPhone/iPad keep the screen on and finish the request if Orbit goes to the background;
/// the Mac keeps App Nap away.
@MainActor
final class OrbitLongRequestGuard {
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var holdsIdleTimer = false
    #elseif os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    init(reason: String) {
        #if os(iOS)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // iOS calls this on the main thread when the time is up and expects the task to end right here.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        // Counted together with the streams' holds, so a change that ends while a stream runs never lets the
        // screen lock under that stream.
        MoonlightIdleTimer.hold()
        holdsIdleTimer = true
        #elseif os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        #endif
    }

    /// Safe to call more than once.
    func end() {
        #if os(iOS)
        if holdsIdleTimer {
            holdsIdleTimer = false
            MoonlightIdleTimer.letGo()
        }
        endBackgroundTask()
        #elseif os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

// MARK: - Fill Screen setup

@MainActor
final class OrbitFillScreenSetupModel: ObservableObject {
    enum Availability: Equatable {
        case unknown, checking, available, demo, offline
        /// The PC's agent predates the setup (no `streamDisplay` feature, or no /api/capabilities at all).
        case olderAgent
        case failed(OrbitStreamDisplayProblem)
    }

    enum Work: Equatable {
        case addingSize(OrbitDisplaySize)
        case configuringSunshine
        case changingMonitor
        case turningOff
        case reverting
        case savingLogin
        case startingSunshine

        /// Adding a screen size can show an administrator prompt on the PC.
        var waitsForPrompt: Bool { if case .addingSize = self { return true }; return false }
    }

    struct Outcome: Equatable {
        var title: String
        var message: String
        var isError: Bool
        /// A failed read ("Couldn't check again"): the next read that works clears it.
        var fromRead = false
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var status: OrbitStreamDisplayStatus?
    @Published private(set) var work: Work?
    @Published var outcome: Outcome?
    @Published private var reads = OrbitStatusReads()
    private(set) var context: OrbitStreamDisplayContext?
    private var loadedAt: Date?
    /// Changes started for an earlier PC (or before demo mode changed) never land on this one.
    private var generation = 0
    /// How long "Start Sunshine" waits between checks (the checks in Tests/ shorten it).
    var sunshineStartPoll: UInt64 = 2_000_000_000

    var isRefreshing: Bool { reads.isReading }
    var pcName: String { context?.pcName ?? "your PC" }

    /// Hands over the PC the settings belong to; another PC (or demo mode) starts from scratch.
    func configure(_ context: OrbitStreamDisplayContext?) {
        guard context?.identity != self.context?.identity else {
            self.context = context
            return
        }
        generation += 1
        _ = reads.select(context?.identity ?? "")
        self.context = context
        status = nil
        outcome = nil
        work = nil
        loadedAt = nil
        availability = context == nil ? .unknown : (context!.isDemo ? .demo : (context!.isOnline ? .unknown : .offline))
        if context?.isDemo == true { status = .demo() }
    }

    /// Reads the PC's readiness (at most every 20 s unless `force`).
    func load(force: Bool = false) async {
        guard let context else { return }
        if context.isDemo { availability = .demo; if status == nil { status = .demo() }; return }
        guard context.isOnline else { availability = .offline; return }
        if !force, availability == .available, status != nil, let loadedAt, Date().timeIntervalSince(loadedAt) < 20 { return }
        guard let token = reads.begin(force: force) else { return }
        defer { reads.end(token) }
        if status == nil { availability = .checking }
        do {
            let service = try context.service()
            let features = try await OrbitStreamDisplayFeatureCache.features(for: context.pcID, service: service, force: force)
            guard reads.isCurrent(token) else { return }
            guard let features, features.contains(OrbitStreamDisplayFeature.fill) else {
                status = nil
                availability = .olderAgent
                return
            }
            let fetched = try await service.status()
            guard reads.isNewest(token) else { return }
            reads.applied(token)
            status = fetched
            availability = .available
            loadedAt = Date()
            if outcome?.fromRead == true { outcome = nil }
        } catch {
            guard reads.isCurrent(token) else { return }
            if OrbitStreamDisplayErrors.isCancellation(error) {
                // The screen went away or asked again: nothing to report.
                if status == nil, availability == .checking { availability = .unknown }
                return
            }
            let problem = OrbitStreamDisplayErrors.describe(error)
            if status == nil {
                availability = .failed(problem)
            } else {
                outcome = Outcome(title: "Couldn't check again", message: problem.message, isError: true, fromRead: true)
            }
        }
    }

    var canChange: Bool {
        guard work == nil, let status, let context else { return false }
        return (context.isDemo || (context.isOnline && availability == .available)) && status.loginSaved
    }

    /// Something keeps "Set Up This PC" from working, in plain words (nil: it can run).
    func setUpBlocker() -> String? {
        guard let status else { return nil }
        if !status.loginSaved { return "Save the Sunshine login first." }
        if status.sunshineStopped { return "Start Sunshine on the PC first." }
        if status.loginRejected { return "Save the Sunshine login again first: Sunshine didn't accept it." }
        if status.sunshineSupported == false { return "Update Sunshine on the PC first." }
        if !status.driverUsable { return "Install the Virtual Display Driver on the PC first." }
        return nil
    }

    /// "Set Up This PC": adds this screen's size to the virtual display when it is missing (maybe one
    /// administrator prompt on the PC), then points Sunshine at the virtual display.
    func setUp(size: OrbitDisplaySize, refreshRate: Int, onlyDisplay: Bool) async {
        guard work == nil, let context else { return }
        outcome = nil
        if context.isDemo {
            work = .addingSize(size)
            try? await Task.sleep(nanoseconds: 900_000_000)
            work = .configuringSunshine
            try? await Task.sleep(nanoseconds: 700_000_000)
            let listed = (status?.virtualDisplay.resolutions ?? []).compactMap(Self.size(fromKey:)) + [size]
            status = .demo(listing: listed, rates: (status?.virtualDisplay.refreshRates ?? []) + [OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate)],
                           fillOn: true)
            work = nil
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC. On your own PC this adds \(size) to the virtual display and points Sunshine at it.", isError: false)
            return
        }
        guard setUpBlocker() == nil else { return }
        let service: any OrbitStreamDisplayService
        do { service = try context.service() } catch { report(error); return }
        let version = generation
        let rate = OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate)
        let keepAwake = OrbitLongRequestGuard(reason: "Setting up the PC for full-screen streaming")
        defer { keepAwake.end() }
        do {
            var restartNote: String?
            var addedSize = false
            if status?.lists(size, refreshRate: rate) != true {
                work = .addingSize(size)
                let added = try await service.addMode(size: size, refreshRate: rate)
                guard version == generation else { return }
                addedSize = added.changed
                if let display = added.display { status = display }
                // The driver could not be restarted now: it reads its sizes again when it next starts.
                if added.reload == "nextStart" { restartNote = OrbitStreamDisplayAPI.nextStartNote(size: size, pcName: context.pcName) }
            }
            work = .configuringSunshine
            let result = try await service.setFill(enabled: true, onlyDisplay: onlyDisplay)
            guard version == generation else { return }
            if let display = result.display { status = display }
            loadedAt = Date()
            work = nil
            var message: String
            if result.changed {
                message = "Sunshine on \(context.pcName) now streams the virtual display in this screen's shape. Start a stream to try it."
            } else if addedSize {
                // Fill Screen was already on (set up from another device): only this screen's size was missing.
                message = "\(context.pcName)'s virtual display now offers \(size) at \(rate) Hz, and Sunshine already streams it. Start a stream to try it."
            } else {
                message = "Everything was already set up on \(context.pcName)."
            }
            if result.sunshineReady == false { message += " Sunshine is still restarting: give it a few seconds." }
            if let restartNote { message += " \(restartNote)" }
            if let warning = result.cleanWarning { message += " \(warning)" }
            if status?.secondScreen.active == true {
                message += " Second Screen is still on, so streams show the extra display until you turn it off."
            }
            let filled = status?.fillsScreen(size: size, refreshRate: rate) == true && restartNote == nil && status?.secondScreen.active != true
            outcome = Outcome(title: filled ? "\(context.pcName) fills this screen" : "Set up, with a note", message: message, isError: false)
        } catch {
            guard version == generation else { return }
            work = nil
            report(error, waitedForChange: true)
            await refreshQuietly(service, version: version)
        }
    }

    /// Changes "Turn off the PC's monitor while streaming" while Fill Screen is on.
    func setOnlyDisplay(_ enabled: Bool) async {
        let success = enabled ? "The PC's own monitor now turns off while you stream." : "The PC's own monitor stays on while you stream."
        await change(.changingMonitor, success: { _ in success }) { service in
            try await service.setFill(enabled: true, onlyDisplay: enabled)
        } demo: { status in
            status.fill.onlyDisplay = enabled
        }
    }

    /// "Turn Off": Sunshine streams the PC's monitor again (Orbit's keys go back to what they were), unless the
    /// second screen keeps it on the virtual display.
    func turnOff() async {
        let pcName = pcName
        await change(.turningOff, success: { OrbitStreamDisplayMessages.fillOff(display: $0.display, pcName: pcName) }) { service in
            try await service.setFill(enabled: false, onlyDisplay: false)
        } demo: { status in
            status = .demo(listing: status.virtualDisplay.resolutions.compactMap(Self.size(fromKey:)), rates: status.virtualDisplay.refreshRates, fillOn: false)
        }
    }

    /// "Undo Orbit's changes": Fill Screen and the second screen off, Sunshine's settings from before Orbit.
    func revert() async {
        let success = "Sunshine's display settings on \(pcName) are back to how they were before Orbit changed them."
        await change(.reverting, success: { _ in success }) { service in
            try await service.revert()
        } demo: { status in
            status = .demo(listing: status.virtualDisplay.resolutions.compactMap(Self.size(fromKey:)), rates: status.virtualDisplay.refreshRates, fillOn: false)
        }
    }

    /// Saves Sunshine's web UI login on the PC (the same route the pairing screen uses).
    func saveLogin(username: String, password: String) async -> Bool {
        guard work == nil, let context else { return false }
        outcome = nil
        if context.isDemo {
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC.", isError: false)
            return true
        }
        let version = generation
        work = .savingLogin
        defer { if version == generation { work = nil } }
        do {
            try await context.service().saveSunshineLogin(username: username, password: password)
            guard version == generation else { return false }
            work = nil
            await load(force: true)
            guard version == generation else { return true }
            if let status, status.sunshineStopped {
                outcome = Outcome(title: "Login saved", message: "Orbit checks it once Sunshine runs on \(context.pcName).", isError: false)
            } else if let status, status.loginUnconfirmed, let reason = status.reason {
                // Saved on the PC, but Sunshine refused it (or its web UI did not answer).
                outcome = Outcome(title: status.loginRejected ? "Saved, but Sunshine didn't accept it" : "Saved, but not checked yet", message: reason, isError: true)
            } else {
                outcome = Outcome(title: "Login saved", message: "Orbit can now change Sunshine's display settings on \(context.pcName).", isError: false)
            }
            return true
        } catch {
            guard version == generation else { return false }
            report(error)
            return false
        }
    }

    /// "Start Sunshine": the companion starts it, then Orbit checks the PC again until Sunshine answers.
    func startSunshine() async {
        guard work == nil, let context, !context.isDemo else { return }
        outcome = nil
        let version = generation
        work = .startingSunshine
        defer { if version == generation { work = nil } }
        do {
            try await context.service().startSunshine()
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: sunshineStartPoll)
                guard version == generation else { return }
                await load(force: true)
                guard version == generation else { return }
                if status?.sunshineStopped == false { return }
            }
            outcome = Outcome(title: "Sunshine is still starting", message: "Check again in a moment. If it doesn't start, open Sunshine on \(context.pcName).", isError: true)
        } catch {
            guard version == generation else { return }
            report(error)
        }
    }

    private func change(_ kind: Work, success: @escaping (OrbitStreamDisplayResult) -> String,
                        request: @escaping (any OrbitStreamDisplayService) async throws -> OrbitStreamDisplayResult,
                        demo: (inout OrbitStreamDisplayStatus) -> Void) async {
        guard work == nil, let context else { return }
        outcome = nil
        if context.isDemo {
            work = kind
            try? await Task.sleep(nanoseconds: 600_000_000)
            if var current = status { demo(&current); status = current }
            work = nil
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC.", isError: false)
            return
        }
        let service: any OrbitStreamDisplayService
        do { service = try context.service() } catch { report(error); return }
        let version = generation
        let keepAwake = OrbitLongRequestGuard(reason: "Changing Sunshine's display settings")
        defer { keepAwake.end() }
        work = kind
        do {
            let result = try await request(service)
            guard version == generation else { return }
            if let display = result.display { status = display }
            loadedAt = Date()
            work = nil
            var message = result.changed ? success(result) : "Nothing needed to change on \(context.pcName)."
            if result.sunshineReady == false { message += " Sunshine is still restarting: give it a few seconds." }
            if let warning = result.cleanWarning { message += " \(warning)" }
            outcome = Outcome(title: "Done", message: message, isError: false)
        } catch {
            guard version == generation else { return }
            work = nil
            report(error, waitedForChange: true)
            await refreshQuietly(service, version: version)
        }
    }

    private func report(_ error: Error, waitedForChange: Bool = false) {
        let problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: waitedForChange)
        outcome = Outcome(title: problem.title, message: problem.message, isError: true)
    }

    /// After a failed change: show what the PC has now (a size may have been added before Sunshine refused).
    private func refreshQuietly(_ service: any OrbitStreamDisplayService, version: Int) async {
        guard let fetched = try? await service.status(), version == generation else { return }
        status = fetched
        loadedAt = Date()
    }

    nonisolated static func size(fromKey key: String) -> OrbitDisplaySize? {
        let parts = key.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return OrbitDisplaySize(width: width, height: height)
    }
}

// MARK: - Second Screen

enum OrbitSecondScreenPosition: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }

    static let storageKey = "orbit.secondScreen.position"
}

/// Sunshine on the session's PC, as the second screen uses it. In the apps this is a `MoonlightHostCoordinator`
/// of the session's own: another screen switching PCs never points it at another PC.
@MainActor
protocol OrbitSecondScreenHost: AnyObject {
    var isPaired: Bool { get }
    var reachable: Bool { get }
    var lastError: String? { get }
    /// When Sunshine last answered with its server info and app list.
    var lastRefreshed: Date? { get }
    var isRefreshing: Bool { get }
    /// Sunshine's app titled Desktop.
    var desktopAppID: Int? { get }
    /// The app Sunshine reports as running (nil: none, or not known).
    var runningAppID: Int? { get }
    func refresh() async
    func quitRunningApp() async
}

/// The stream screen on this device (`MoonlightStreamController.shared` in the apps).
@MainActor
protocol OrbitSecondScreenStreams: AnyObject {
    /// A stream other than the second screen's is open here.
    var otherStreamIsOpen: Bool { get }
    /// The second screen's stream is open here.
    var secondScreenIsOpen: Bool { get }
    /// Called with the new state each time the stream screen opens or closes.
    var onPresentationChange: (@MainActor (Bool) -> Void)? { get set }
    /// Closes the second screen's stream; the app keeps running on the PC (the session closes it).
    func endSecondScreen()
}

/// Second Screen (Orbit Pro, Labs): the PC gets a virtual display next to its monitor (POST
/// /api/stream/display/second-screen) and this device streams Sunshine's "Desktop" app at its own native size,
/// so that display fills it. Ending the stream turns the virtual display off again, whichever screen is open
/// at the time, so the app keeps one session (`shared`, in Streaming/OrbitSecondScreen.swift).
@MainActor
final class OrbitSecondScreenSession: ObservableObject {
    enum Availability: Equatable {
        case unknown, checking, available, demo, offline
        /// The PC's agent has no `secondScreen` feature (or predates /api/capabilities).
        case olderAgent
        case failed(OrbitStreamDisplayProblem)
    }

    enum Phase: Equatable {
        case idle
        /// Talking to the PC (turning it on: maybe an administrator prompt, then a Sunshine restart).
        case preparing(String)
        /// The PC restarted Sunshine; waiting for it to answer before streaming.
        case waitingForSunshine
        case streaming
        /// Ending the stream and turning the virtual display off.
        case stopping(String)
    }

    /// A message shown after a change.
    struct Notice: Equatable {
        enum Kind: Equatable { case done, note, demo }
        var kind: Kind
        var message: String

        var title: String {
            switch kind {
            case .done: return "Done"
            case .note: return "Note"
            case .demo: return "Demo mode"
            }
        }
        var symbol: String {
            switch kind {
            case .done: return "checkmark.circle.fill"
            case .note: return "info.circle.fill"
            case .demo: return "sparkles"
            }
        }
    }

    /// What a normal (not second-screen) stream on this device runs into (`checkNormalStream`).
    enum StreamCheck: Equatable {
        case go
        /// Orbit is turning the second screen on (`sessionPCName`).
        case starting
        /// Orbit is turning the second screen off (`sessionPCName`).
        case stopping
        /// This device shows the second screen right now.
        case streamingHere
        /// The PC still has the second screen on: a stream from it shows the extra display.
        case leftOn
    }

    /// What Sunshine offers the second screen, for `startBlocker`.
    struct HostFacts: Equatable {
        var isPaired: Bool
        var reachable: Bool
        var hasDesktopApp: Bool
    }

    /// The result of saving Sunshine's login: `saved` on the PC, `accepted` also by Sunshine, a sentence for the form.
    struct LoginResult: Equatable {
        var saved: Bool
        var accepted: Bool
        var message: String
    }

    /// How long the flows wait (the checks in Tests/ shorten every wait).
    struct Timing {
        /// Waiting for Sunshine to answer again after its restart: 4 quick tries, then slower ones (about 25 s).
        var sunshineAttempts = 20
        var sunshineQuickAttempts = 4
        var sunshineQuickPoll: UInt64 = 700_000_000
        var sunshinePoll: UInt64 = 1_500_000_000
        /// Waiting for another screen's refresh of the same host to end, per try (at most 50 tries).
        var hostBusyPoll: UInt64 = 200_000_000
        /// Reading the side the virtual display ended up on, after the stream started.
        var placementCheck: UInt64 = 9_000_000_000
        /// Waiting for the stream's sockets to close before turning the virtual display off.
        var idleAttempts = 8
        var idlePoll: UInt64 = 1_500_000_000
        /// "Start Sunshine": time between checks (6 at most).
        var sunshineStartPoll: UInt64 = 2_000_000_000
    }

    @Published private(set) var availability: Availability = .unknown
    /// The PC's state, from the last read or change.
    @Published private(set) var status: OrbitStreamDisplayStatus?
    /// The PC `status` and `availability` belong to.
    @Published private(set) var statusPCID: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var problem: OrbitStreamDisplayProblem?
    /// A short message after a change (or a caveat that came with it).
    @Published private(set) var notice: Notice?
    /// How to put the screen on the chosen side in Windows when Orbit could not do it.
    @Published private(set) var placementHint: String?
    @Published private(set) var isMoving = false
    @Published private(set) var isStartingSunshine = false
    @Published private var reads = OrbitStatusReads()

    /// The PC the running session belongs to (set while starting, streaming or stopping, and kept after a start
    /// that left the virtual display on, so Turn Off reaches the same PC).
    private(set) var sessionPCID: String?
    private(set) var sessionPCName = "your PC"
    private var sessionService: (any OrbitStreamDisplayService)?
    private var sessionHost: (any OrbitSecondScreenHost)?
    private var sessionSize: OrbitDisplaySize?
    private var sessionRefreshRate = 60
    /// The Desktop app this device launched for the session (nil: none, for example a second screen left on).
    private var launchedAppID: Int?
    /// When `status` was read, for `checkIfLeftOn`.
    private var statusReadAt: Date?
    /// `problem` came from a failed read (the next read that works clears it), not from a change.
    private var problemFromRead = false
    private let streams: any OrbitSecondScreenStreams
    var timing: Timing

    init(streams: any OrbitSecondScreenStreams, timing: Timing = Timing()) {
        self.streams = streams
        self.timing = timing
        // Ending the second screen's stream (its controls, closing the window, a failed connection closed by the
        // user) turns the virtual display off.
        streams.onPresentationChange = { [weak self] presented in self?.streamPresentationChanged(presented) }
    }

    var isRefreshing: Bool { reads.isReading }

    var isBusy: Bool {
        switch phase {
        case .preparing, .waitingForSunshine, .stopping: return true
        case .idle, .streaming: return false
        }
    }

    var isStreaming: Bool { phase == .streaming }

    /// Turning the second screen on (before its stream opens).
    var isStarting: Bool {
        switch phase {
        case .preparing, .waitingForSunshine: return true
        case .idle, .streaming, .stopping: return false
        }
    }

    /// Why Start cannot run yet because of what Orbit knows about the PC (nil: the PC was checked).
    func availabilityBlocker(pcName: String) -> String? {
        switch availability {
        case .available, .demo: return nil
        case .olderAgent: return "Update Orbit PC Companion on \(pcName) first."
        case .offline: return "\(pcName) is offline."
        case .failed: return "Orbit couldn't check \(pcName). Check again in a moment."
        case .unknown, .checking: return "Checking \(pcName)…"
        }
    }

    /// The PC reports the second screen as on (this device or another one turned it on).
    func isActiveOnPC(_ pcID: String) -> Bool { statusPCID == pcID && status?.secondScreen.active == true }

    /// The PC still shows the second screen although this device neither streams it nor is turning it on or off:
    /// left on by a stream that ended without turning it off, or by another device. Streams then show the extra
    /// display instead of the main monitor.
    func isLeftOn(_ pcID: String) -> Bool {
        isActiveOnPC(pcID) && !(sessionPCID == pcID && (isBusy || isStreaming))
    }

    /// What keeps Start (or Show It Here) from running, in plain words (nil: it can start). `size` is what this
    /// screen streams at; `host` is nil while the screen's Sunshine host is not known yet.
    func startBlocker(context: OrbitStreamDisplayContext, host: HostFacts?, size: OrbitDisplaySize) -> String? {
        if context.isDemo { return nil }
        if !context.hasPC { return "Pair a PC first." }
        if let sessionPCID, sessionPCID != context.pcID { return "A second screen is running for \(sessionPCName). Turn it off there first." }
        if streams.otherStreamIsOpen { return "End the stream that's open first." }
        if let blocker = availabilityBlocker(pcName: context.pcName) { return blocker }
        guard statusPCID == context.pcID, let status else { return "Checking \(context.pcName)…" }
        guard let host else { return "Checking \(context.pcName)…" }
        if !host.isPaired { return "Pair Orbit with Sunshine first." }
        if !host.reachable { return "Sunshine isn't answering on \(context.pcName)." }
        if !host.hasDesktopApp { return "Add a Desktop app in Sunshine first." }
        if let blocker = status.secondScreenBlocker { return blocker }
        // Someone else's stream (when the second screen is already on, nothing restarts, so the PC would not refuse).
        if status.streamActive == true, !isStreaming { return "Someone is streaming from \(context.pcName) right now. End that stream first." }
        if !size.isAcceptedByPC { return "This screen's size (\(size)) is outside what the PC accepts (640 × 480 to 7680 × 4320)." }
        return nil
    }

    /// What a normal stream of `pcID` on this device runs into: never replace the second screen's stream, and ask
    /// first while that PC still shows the extra display.
    func checkNormalStream(pcID: String) -> StreamCheck {
        if streams.secondScreenIsOpen || phase == .streaming { return .streamingHere }
        switch phase {
        case .preparing, .waitingForSunshine: return .starting
        case .stopping: return .stopping
        case .idle, .streaming: break
        }
        return isActiveOnPC(pcID) ? .leftOn : .go
    }

    // MARK: Reading the PC

    /// Reads the PC's state. A read for another PC than before forgets what the screens showed; a read still running
    /// for an earlier PC neither lands here nor keeps this one from starting. `quiet`: a failure is not shown as a
    /// problem (background checks).
    func refresh(context: OrbitStreamDisplayContext, force: Bool = false, quiet: Bool = false) async {
        if reads.select(context.pcID) {
            statusPCID = context.pcID
            status = nil
            statusReadAt = nil
            availability = .unknown
            if sessionPCID == nil { problem = nil; problemFromRead = false; notice = nil; placementHint = nil }
        }
        if context.isDemo {
            availability = .demo
            if status == nil { status = .demo() }
            return
        }
        guard context.isOnline else { availability = .offline; return }
        guard let token = reads.begin(force: force) else { return }
        defer { reads.end(token) }
        if status == nil { availability = .checking }
        do {
            let service = try context.service()
            let features = try await OrbitStreamDisplayFeatureCache.features(for: context.pcID, service: service, force: force)
            guard reads.isCurrent(token) else { return }
            guard let features, features.contains(OrbitStreamDisplayFeature.secondScreen) else {
                status = nil
                availability = .olderAgent
                return
            }
            let fetched = try await service.status()
            guard reads.isNewest(token) else { return }
            reads.applied(token)
            apply(fetched, pcID: context.pcID)
            availability = .available
            if problemFromRead { problem = nil; problemFromRead = false }
        } catch {
            guard reads.isCurrent(token) else { return }
            if OrbitStreamDisplayErrors.isCancellation(error) {
                // The screen went away or asked again: nothing went wrong on the PC.
                if status == nil, availability == .checking { availability = .unknown }
                return
            }
            let described = OrbitStreamDisplayErrors.describe(error)
            if status == nil {
                availability = .failed(described)
            } else if !quiet, !isBusy, problem == nil || problemFromRead {
                // Never in place of what a change reported (Turn Off's 409, say): that still applies.
                problem = described
                problemFromRead = true
            }
        }
    }

    /// A light read for the Stream tab, Tools and the Mac's Stream page: whether the PC still has the second screen
    /// on. At most every `maxAge` seconds per PC, never in demo mode or while a session changes something; agents
    /// without the feature are remembered by the feature cache, so they cost no request.
    func checkIfLeftOn(context: OrbitStreamDisplayContext, maxAge: TimeInterval = 120) async {
        guard context.hasPC, !context.isDemo, context.isOnline, !isBusy else { return }
        if statusPCID == context.pcID, availability == .available, let statusReadAt, Date().timeIntervalSince(statusReadAt) < maxAge { return }
        await refresh(context: context, quiet: true)
    }

    /// Turn Off can run for `pcID` now: nothing is changing, and this device does not stream another PC's second screen.
    func canTurnOff(_ pcID: String) -> Bool {
        !isBusy && !(isStreaming && sessionPCID != pcID)
    }

    private func apply(_ fetched: OrbitStreamDisplayStatus, pcID: String) {
        guard statusPCID == pcID else { return }
        status = fetched
        statusReadAt = Date()
        if !fetched.secondScreen.active, sessionPCID == nil { placementHint = nil }
        if fetched.secondScreen.placement == "done" { placementHint = nil }
    }

    /// Saves Sunshine's web UI login on the PC (the route pairing uses) and reads the PC again.
    func saveLogin(context: OrbitStreamDisplayContext, username: String, password: String) async -> LoginResult {
        if context.isDemo { return LoginResult(saved: true, accepted: true, message: "Demo mode: nothing was sent to a PC.") }
        do {
            try await context.service().saveSunshineLogin(username: username, password: password)
            await refresh(context: context, force: true)
            if statusPCID == context.pcID, let status {
                if status.sunshineStopped {
                    return LoginResult(saved: true, accepted: false, message: "Saved on \(context.pcName). Orbit checks it once Sunshine runs.")
                }
                if status.loginUnconfirmed, let reason = status.reason {
                    return LoginResult(saved: true, accepted: false, message: status.loginRejected
                                       ? "Saved on \(context.pcName), but Sunshine didn't accept it: \(reason)"
                                       : "Saved on \(context.pcName), but Orbit couldn't check it yet: \(reason)")
                }
            }
            return LoginResult(saved: true, accepted: true, message: "Login saved on \(context.pcName).")
        } catch {
            return LoginResult(saved: false, accepted: false, message: OrbitStreamDisplayErrors.describe(error).message)
        }
    }

    /// "Start Sunshine": the companion starts it, then Orbit reads the PC again until Sunshine answers.
    func startSunshine(context: OrbitStreamDisplayContext) async {
        guard !context.isDemo, !isStartingSunshine else { return }
        isStartingSunshine = true
        defer { isStartingSunshine = false }
        do {
            try await context.service().startSunshine()
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: timing.sunshineStartPoll)
                await refresh(context: context, force: true)
                if statusPCID == context.pcID, status?.sunshineStopped == false { return }
            }
        } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            problemFromRead = false
        }
    }

    // MARK: Start

    /// Turns the virtual display on (at `size`) and streams the PC's Desktop onto this screen: `launch` opens the
    /// stream of that Sunshine app on `host` and returns false when the app is gone. `host` belongs to this
    /// session alone.
    func startSession(context: OrbitStreamDisplayContext, host: any OrbitSecondScreenHost, size: OrbitDisplaySize, refreshRate: Int,
                      position: OrbitSecondScreenPosition, launch: @escaping @MainActor (_ appID: Int) -> Bool) {
        guard !isBusy, phase != .streaming else { return }
        problem = nil
        problemFromRead = false
        notice = nil
        if context.isDemo {
            let wasOn = status?.secondScreen.active == true
            status = (status ?? .demo()).demoWithSecondScreen(true, position: position.rawValue)
            notice = Notice(kind: .demo, message: wasOn
                            ? "With your own PC, Orbit would now stream its virtual display here. Nothing was sent to a PC."
                            : "With your own PC, Orbit would now add a \(size) virtual display next to its monitor and stream it here. Nothing was sent to a PC.")
            return
        }
        guard !streams.otherStreamIsOpen else {
            problem = OrbitStreamDisplayProblem(title: "A stream is open", message: "End the stream that's open first, then start the second screen.")
            return
        }
        guard size.isAcceptedByPC else {
            problem = OrbitStreamDisplayProblem(title: "Screen size not supported", message: "The PC accepts virtual displays from 640 × 480 to 7680 × 4320; this screen streams at \(size).")
            return
        }
        let service: any OrbitStreamDisplayService
        do { service = try context.service() } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            return
        }
        // "Show It Here": the virtual display is on already (maybe turned on by another device).
        let wasOn = statusPCID == context.pcID && status?.secondScreen.active == true
        sessionPCID = context.pcID
        sessionPCName = context.pcName
        sessionService = service
        sessionHost = host
        sessionSize = size
        sessionRefreshRate = OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate)
        launchedAppID = nil
        placementHint = nil
        // Busy right away, so a second tap cannot start another request.
        phase = .preparing("Turning on the virtual display on \(context.pcName)…")
        Task { await runStart(context: context, host: host, service: service, size: size, position: position, wasOn: wasOn, launch: launch) }
    }

    private func runStart(context: OrbitStreamDisplayContext, host: any OrbitSecondScreenHost, service: any OrbitStreamDisplayService,
                          size: OrbitDisplaySize, position: OrbitSecondScreenPosition, wasOn: Bool, launch: @escaping @MainActor (Int) -> Bool) async {
        // Stopping before the stream opens: when this start turned the virtual display on, the session keeps the PC
        // and host so Turn Off reaches them; when it was on already, nothing here belongs to this device.
        func stopBeforeStreaming(_ reason: OrbitStreamDisplayProblem) {
            problem = reason
            problemFromRead = false
            finishSession(keepingHost: !wasOn)
        }
        let keepAwake = OrbitLongRequestGuard(reason: "Turning on the second screen")
        let result: OrbitStreamDisplayResult
        do {
            result = try await service.setSecondScreen(enabled: true, size: size, refreshRate: sessionRefreshRate, position: position.rawValue)
        } catch {
            keepAwake.end()
            problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            finishSession()
            await refreshAfterChange(service: service, pcID: context.pcID)
            return
        }
        keepAwake.end()
        if let display = result.display { apply(display, pcID: context.pcID) }
        placementHint = Self.hint(placement: result.placement, hint: result.placementHint)
        let notes = [result.reload == "nextStart" ? OrbitStreamDisplayAPI.nextStartNote(size: size, pcName: context.pcName) : nil,
                     result.cleanWarning].compactMap { $0 }
        if !notes.isEmpty { notice = Notice(kind: .note, message: notes.joined(separator: " ")) }
        // The second screen was on already (nothing restarted), and someone streams from the PC right now:
        // streaming here would collide with their session.
        if result.display?.streamActive == true {
            stopBeforeStreaming(Self.someoneStreams(pcName: context.pcName))
            return
        }

        // Sunshine restarted to use the virtual display: wait until it answers and lists its apps again. Only an
        // answer read after the change counts (the host still holds the one from before the restart).
        phase = .waitingForSunshine
        let changedAt = Date()
        var desktop: Int?
        for attempt in 0..<timing.sunshineAttempts {
            await refreshNow(host)
            if host.isPaired, host.reachable, (host.lastRefreshed ?? .distantPast) >= changedAt, let app = host.desktopAppID {
                desktop = app
                break
            }
            if !host.isPaired { break }
            try? await Task.sleep(nanoseconds: attempt < timing.sunshineQuickAttempts ? timing.sunshineQuickPoll : timing.sunshinePoll)
        }
        guard host.isPaired else {
            stopBeforeStreaming(OrbitStreamDisplayProblem(title: "Pair Sunshine first", message: "Orbit isn't paired with Sunshine on \(context.pcName) any more. Pair it again, then start the second screen. Until then the virtual display stays on: select Turn Off to undo it."))
            return
        }
        guard let desktop else {
            stopBeforeStreaming(host.reachable
                ? OrbitStreamDisplayProblem(title: "No Desktop app in Sunshine", message: "Add an app named Desktop in Sunshine's web UI (Applications › Add New, no command), then start again. The virtual display stays on until you select Turn Off.")
                : OrbitStreamDisplayProblem(title: "Sunshine didn't come back", message: "Sunshine on \(context.pcName) is still restarting. Select Start again in a moment, or Turn Off to undo the change."))
            return
        }
        // Nothing may have started meanwhile: a stream on this device, or someone else's stream from the PC.
        if let fresh = try? await service.status() {
            apply(fresh, pcID: context.pcID)
            if fresh.streamActive == true {
                stopBeforeStreaming(Self.someoneStreams(pcName: context.pcName))
                return
            }
        }
        if streams.otherStreamIsOpen {
            stopBeforeStreaming(OrbitStreamDisplayProblem(title: "Another stream opened", message: "A stream started on this device meanwhile, so Orbit didn't replace it. The virtual display on \(context.pcName) stays on: Show It Here once that stream ends, or Turn Off."))
            return
        }
        launchedAppID = desktop
        phase = .streaming
        guard launch(desktop) else {
            launchedAppID = nil
            stopBeforeStreaming(OrbitStreamDisplayProblem(title: "No Desktop app in Sunshine", message: "Sunshine on \(context.pcName) no longer lists its Desktop app. The virtual display stays on until you select Turn Off."))
            return
        }

        // Orbit moves the virtual display to the chosen side once Sunshine puts it on the desktop: read the
        // result a little later, so a "do it in Windows Settings" hint shows when that did not work.
        if result.placement == "pending" {
            try? await Task.sleep(nanoseconds: timing.placementCheck)
            guard phase == .streaming, sessionPCID == context.pcID, let fetched = try? await service.status() else { return }
            apply(fetched, pcID: context.pcID)
            if fetched.secondScreen.placement == "manual" {
                placementHint = Self.hint(placement: "manual", hint: nil, position: position)
            }
        }
    }

    private static func someoneStreams(pcName: String) -> OrbitStreamDisplayProblem {
        OrbitStreamDisplayProblem(title: "Someone is streaming", message: "Someone is streaming from \(pcName) right now, so Orbit didn't open the second screen here. The virtual display stays on: Show It Here once that stream ends, or Turn Off.")
    }

    /// A fresh server info and app list. `refresh()` returns at once while another refresh of the host runs, so
    /// wait for that one to end first (at most 50 tries).
    private func refreshNow(_ host: any OrbitSecondScreenHost) async {
        for _ in 0..<50 where host.isRefreshing { try? await Task.sleep(nanoseconds: timing.hostBusyPoll) }
        await host.refresh()
    }

    static func hint(placement: String?, hint: String?, position: OrbitSecondScreenPosition? = nil) -> String? {
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty, placement != "done" { return hint }
        guard placement == "manual" else { return nil }
        let side = position?.rawValue ?? "chosen side"
        return "To move it yourself: open Windows Settings › System › Display, drag the screen named 'VDD by MTT' to the \(side) of your main display and select Apply."
    }

    // MARK: Stop

    private func streamPresentationChanged(_ presented: Bool) {
        guard !presented, phase == .streaming else { return }
        phase = .stopping("Ending the stream…")
        Task { await runStop() }
    }

    /// "Turn Off": ends the second screen's stream (which then turns the virtual display off), or turns off a
    /// virtual display left on (by a stream that already ended, or by another device). `host`: Sunshine on that PC,
    /// to close a Desktop session left running there (the PC restarts Sunshine only once nothing runs in it).
    func stopSession(context: OrbitStreamDisplayContext, host: (any OrbitSecondScreenHost)?) {
        // Another PC's second screen streams here: one session at a time (the screens disable Turn Off then).
        guard canTurnOff(context.pcID) else { return }
        problem = nil
        problemFromRead = false
        notice = nil
        if context.isDemo {
            status = (status ?? .demo()).demoWithSecondScreen(false)
            notice = Notice(kind: .demo, message: "Nothing was sent to a PC.")
            return
        }
        if phase == .streaming, streams.secondScreenIsOpen {
            streams.endSecondScreen()   // `streamPresentationChanged` continues with `runStop`
            return
        }
        if sessionPCID != context.pcID || sessionService == nil {
            do { sessionService = try context.service() } catch {
                problem = OrbitStreamDisplayErrors.describe(error)
                return
            }
            sessionPCID = context.pcID
            sessionPCName = context.pcName
            sessionHost = host
            launchedAppID = nil
        } else if sessionHost == nil {
            sessionHost = host
        }
        phase = .stopping("Turning off the second screen…")
        Task { await runStop() }
    }

    /// Ending the second screen closes Sunshine's Desktop session first (Sunshine keeps it open after a disconnect,
    /// and the PC restarts Sunshine only once nothing runs in it). Only the Desktop, never another app, and never a
    /// session someone else is watching right now, unless this device launched it itself.
    static func shouldQuitDesktop(runningAppID: Int?, launchedAppID: Int?, desktopAppID: Int?, streamActive: Bool?) -> Bool {
        guard let running = runningAppID, running != 0 else { return false }
        guard running == launchedAppID || running == desktopAppID else { return false }
        return launchedAppID != nil || streamActive != true
    }

    private func runStop() async {
        guard let service = sessionService, let pcID = sessionPCID else { phase = .idle; return }
        let pcName = sessionPCName
        let keepAwake = OrbitLongRequestGuard(reason: "Turning off the second screen")
        defer { keepAwake.end() }
        if let host = sessionHost, host.isPaired {
            let before = try? await service.status()
            if let before { apply(before, pcID: pcID) }
            await refreshNow(host)
            if Self.shouldQuitDesktop(runningAppID: host.runningAppID, launchedAppID: launchedAppID, desktopAppID: host.desktopAppID,
                                      streamActive: before?.streamActive) {
                phase = .stopping("Closing the Desktop session in Sunshine…")
                await host.quitRunningApp()
            }
        }
        phase = .stopping("Turning off the virtual display on \(pcName)…")
        // The stream's sockets take a moment to close after the session ends.
        for attempt in 0..<timing.idleAttempts {
            guard let current = try? await service.status() else { break }
            apply(current, pcID: pcID)
            if !current.isBusy || attempt == timing.idleAttempts - 1 { break }
            try? await Task.sleep(nanoseconds: timing.idlePoll)
        }
        let before = statusPCID == pcID ? status : nil
        do {
            let result = try await service.setSecondScreen(enabled: false, size: nil, refreshRate: sessionRefreshRate,
                                                           position: before?.secondScreen.position ?? "right")
            if let display = result.display { apply(display, pcID: pcID) }
            notice = Notice(kind: .done, message: OrbitStreamDisplayMessages.secondScreenOff(result, before: before, pcName: pcName))
            placementHint = nil
            launchedAppID = nil
            finishSession()
        } catch {
            problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            problemFromRead = false
            // Keep the PC and host so Turn Off can try again; the PC still has the virtual display on.
            phase = .idle
            await refreshAfterChange(service: service, pcID: pcID)
        }
    }

    // MARK: Undo

    /// "Undo Orbit's Changes": Fill Screen and the second screen off, and Sunshine's display settings back to how
    /// they were before Orbit changed them (POST /api/stream/display/revert). Never while this device streams.
    func revert(context: OrbitStreamDisplayContext) {
        guard !isBusy, phase != .streaming, sessionPCID == nil || sessionPCID == context.pcID else { return }
        problem = nil
        problemFromRead = false
        notice = nil
        if context.isDemo {
            status = .demo()
            notice = Notice(kind: .demo, message: "Nothing was sent to a PC.")
            return
        }
        let service: any OrbitStreamDisplayService
        do { service = try context.service() } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            return
        }
        phase = .stopping("Putting Sunshine's settings back on \(context.pcName)…")
        Task {
            let keepAwake = OrbitLongRequestGuard(reason: "Undoing Orbit's display changes")
            defer { keepAwake.end() }
            do {
                let result = try await service.revert()
                if let display = result.display { apply(display, pcID: context.pcID) }
                var message = result.changed
                    ? "Sunshine's display settings on \(context.pcName) are back to how they were before Orbit changed them."
                    : "Nothing needed to change on \(context.pcName)."
                if result.sunshineReady == false { message += " Sunshine is still restarting: give it a few seconds." }
                if let warning = result.cleanWarning { message += " \(warning)" }
                notice = Notice(kind: .done, message: message)
                placementHint = nil
                launchedAppID = nil
                finishSession()
            } catch {
                problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
                problemFromRead = false
                phase = .idle
                await refreshAfterChange(service: service, pcID: context.pcID)
            }
        }
    }

    // MARK: Moving it

    /// Puts the virtual display on the other side while it is on (no Sunshine restart is needed for that).
    /// `refreshRate`: the second screen's stream rate, when the PC does not report the one it was turned on with.
    func move(to position: OrbitSecondScreenPosition, context: OrbitStreamDisplayContext, refreshRate: Int) {
        guard statusPCID == context.pcID, let status, status.secondScreen.active, status.secondScreen.position != position.rawValue,
              !isBusy, !isMoving else { return }
        if context.isDemo {
            self.status = status.demoWithSecondScreen(true, position: position.rawValue)
            return
        }
        guard let size = (sessionPCID == context.pcID ? sessionSize : nil) ?? status.secondScreen.size else { return }
        let service: any OrbitStreamDisplayService
        do { service = try (sessionPCID == context.pcID ? sessionService : nil) ?? context.service() } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            return
        }
        let rate = status.secondScreen.refreshRate ?? refreshRate
        isMoving = true
        problem = nil
        problemFromRead = false
        Task {
            defer { isMoving = false }
            do {
                let result = try await service.setSecondScreen(enabled: true, size: size, refreshRate: rate, position: position.rawValue)
                if let display = result.display { apply(display, pcID: context.pcID) }
                placementHint = Self.hint(placement: result.placement, hint: result.placementHint, position: position)
            } catch {
                problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
                problemFromRead = false
            }
        }
    }

    // MARK: Helpers

    private func finishSession(keepingHost: Bool = false) {
        phase = .idle
        if !keepingHost {
            sessionPCID = nil
            sessionService = nil
            sessionHost = nil
            sessionSize = nil
        }
    }

    private func refreshAfterChange(service: any OrbitStreamDisplayService, pcID: String) async {
        guard let fetched = try? await service.status() else { return }
        apply(fetched, pcID: pcID)
    }
}
