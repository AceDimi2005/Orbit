#if !os(tvOS)
import Combine
import Foundation
import MoonlightCore

// Second Screen (DESIGN F9, Orbit Pro, Labs), iPhone/iPad and Mac: the PC gets a virtual display next to
// its monitor (POST /api/stream/display/second-screen) and this device streams Sunshine's "Desktop" app
// at its own native size, so that display fills it. Ending the stream turns the virtual display off again,
// whichever screen is open at the time, so this lives in an app-wide session object.

enum OrbitSecondScreenPosition: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }

    static let storageKey = "orbit.secondScreen.position"
}

@MainActor
final class OrbitSecondScreenSession: ObservableObject {
    static let shared = OrbitSecondScreenSession()

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
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMoving = false

    /// The PC the running session belongs to (set while starting, streaming or stopping).
    private(set) var sessionPCID: String?
    private(set) var sessionPCName = "your PC"
    private var sessionClient: OrbitAPIClient?
    private var sessionHost: MoonlightHostCoordinator?
    private var sessionSize: OrbitDisplaySize?
    private var sessionRefreshRate = 60
    private var launchedAppID: Int?
    private var refreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Ending the second screen's stream (overlay, closing the window, a failed connection closed by the
        // user) turns the virtual display off. Read on the next turn, after the controller has changed.
        MoonlightStreamController.shared.$isPresented
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] presented in
                MainActor.assumeIsolated { self?.streamPresentationChanged(presented) }
            }
            .store(in: &cancellables)
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .waitingForSunshine, .stopping: return true
        case .idle, .streaming: return false
        }
    }

    var isStreaming: Bool { phase == .streaming }

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

    /// What keeps Start from running, in plain words (nil: it can start). `size` is what this screen streams at.
    func startBlocker(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator, size: OrbitDisplaySize) -> String? {
        if context.isDemo { return nil }
        if let sessionPCID, sessionPCID != context.pcID { return "A second screen is running for \(sessionPCName). Turn it off there first." }
        if let blocker = availabilityBlocker(pcName: context.pcName) { return blocker }
        guard statusPCID == context.pcID, let status else { return "Checking \(context.pcName)…" }
        if !host.isPaired { return "Pair Orbit with Sunshine first." }
        if !host.reachable { return "Sunshine isn't answering on \(context.pcName)." }
        if Self.desktopApp(in: host) == nil { return "Add a Desktop app in Sunshine first." }
        if let blocker = status.secondScreenBlocker { return blocker }
        if !size.isAcceptedByPC { return "This screen's size (\(size)) is outside what the PC accepts (640 × 480 to 7680 × 4320)." }
        return nil
    }

    /// The checks Orbit makes itself before streaming: Sunshine's pairing with Orbit and the Desktop app.
    static func hostChecks(host: MoonlightHostCoordinator, isDemo: Bool, pcName: String) -> [OrbitDisplayCheck] {
        let pairing = "Sunshine paired with Orbit"
        if isDemo { return [OrbitDisplayCheck(kind: .pairing, title: pairing, detail: "Sample PC", state: .done)] }
        if !host.isPaired {
            return [OrbitDisplayCheck(kind: .pairing, title: pairing,
                                      detail: "Orbit streams the second screen itself, so it needs the Sunshine pairing that Stream uses.", state: .missing)]
        }
        if !host.reachable {
            return [OrbitDisplayCheck(kind: .pairing, title: pairing, detail: host.lastError ?? "Sunshine isn't answering on \(pcName).", state: .unknown)]
        }
        let desktop = desktopApp(in: host)
        return [
            OrbitDisplayCheck(kind: .pairing, title: pairing, detail: nil, state: .done),
            OrbitDisplayCheck(kind: .desktopApp, title: "Desktop app in Sunshine",
                              detail: desktop == nil ? "Add an app named Desktop in Sunshine's web UI (Applications › Add New, no command)." : nil,
                              state: desktop == nil ? .missing : .done)
        ]
    }

    /// The result of saving Sunshine's login: `saved` on the PC, `accepted` also by Sunshine, a sentence for the form.
    struct LoginResult: Equatable {
        var saved: Bool
        var accepted: Bool
        var message: String
    }

    /// Saves Sunshine's web UI login on the PC (the route pairing uses) and reads the PC again.
    func saveLogin(context: OrbitStreamDisplayContext, username: String, password: String) async -> LoginResult {
        if context.isDemo { return LoginResult(saved: true, accepted: true, message: "Demo mode: nothing was sent to a PC.") }
        do {
            let automation = MoonlightPairingAutomation(canSubmitPIN: false, canStartSunshine: false, sunshineRunning: true,
                                                        client: { try context.makeClient() })
            try await automation.saveLogin(username: username, password: password)
            await refresh(context: context, force: true)
            if statusPCID == context.pcID, let status, status.loginSaved, status.sunshineVersion == nil, let reason = status.reason {
                return LoginResult(saved: true, accepted: false, message: "Saved on \(context.pcName), but Sunshine didn't accept it: \(reason)")
            }
            return LoginResult(saved: true, accepted: true, message: "Login saved on \(context.pcName).")
        } catch {
            return LoginResult(saved: false, accepted: false, message: OrbitStreamDisplayErrors.describe(error).message)
        }
    }

    /// The stream settings a second screen uses: Fill Screen at the native size (every pixel of this screen),
    /// Sunshine applying it (Optimize game settings), touches landing where you touch, no HDR.
    static func streamSettings(from base: MoonlightStreamSettings) -> MoonlightStreamSettings {
        var settings = base
        settings.aspect = .native
        settings.resolution = .native
        settings.optimizeGameSettings = true
        settings.quitAppOnDisconnect = false
        settings.hdr = false
        #if os(iOS)
        settings.touchMode = .touchscreen
        #endif
        return settings
    }

    /// The refresh rate asked of the virtual display: the stream's frame rate.
    static func refreshRate(for settings: MoonlightStreamSettings) -> Int {
        OrbitStreamDisplayAPI.clampedRefreshRate(min(settings.frameRate, max(60, MoonlightDeviceCapabilities.maximumFrameRate)))
    }

    // MARK: Reading the PC

    func refresh(context: OrbitStreamDisplayContext, force: Bool = false) async {
        if statusPCID != context.pcID {
            refreshGeneration += 1
            statusPCID = context.pcID
            status = nil
            availability = .unknown
            if sessionPCID == nil { problem = nil; notice = nil; placementHint = nil }
        }
        if context.isDemo {
            availability = .demo
            if status == nil { status = .demo() }
            return
        }
        guard context.isOnline else { availability = .offline; return }
        guard !isRefreshing || force else { return }
        let version = refreshGeneration
        isRefreshing = true
        defer { if version == refreshGeneration { isRefreshing = false } }
        if status == nil { availability = .checking }
        do {
            let client = try context.makeClient()
            let features = try await OrbitStreamDisplayFeatureCache.features(for: context.pcID, client: client, force: force)
            guard version == refreshGeneration else { return }
            guard let features, features.contains(OrbitStreamDisplayFeature.secondScreen) else {
                status = nil
                availability = .olderAgent
                return
            }
            let fetched = try await OrbitStreamDisplayAPI.status(client)
            guard version == refreshGeneration else { return }
            apply(fetched, pcID: context.pcID)
            availability = .available
        } catch {
            guard version == refreshGeneration else { return }
            let described = OrbitStreamDisplayErrors.describe(error)
            if status == nil { availability = .failed(described) } else if !isBusy { problem = described }
        }
    }

    private func apply(_ fetched: OrbitStreamDisplayStatus, pcID: String) {
        guard statusPCID == pcID else { return }
        status = fetched
        if !fetched.secondScreen.active, sessionPCID == nil { placementHint = nil }
        if fetched.secondScreen.placement == "done" { placementHint = nil }
    }

    // MARK: Start

    /// Turns the virtual display on (at `target`'s size) and streams the PC's Desktop onto this screen.
    /// `onStreamBegan` runs right after the stream is requested (the Mac opens its Stream window there).
    func start(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator, baseSettings: MoonlightStreamSettings,
               target: MoonlightStreamTarget, position: OrbitSecondScreenPosition, onStreamBegan: @escaping @MainActor () -> Void) {
        guard !isBusy, phase != .streaming else { return }
        problem = nil
        notice = nil
        if context.isDemo {
            notice = Notice(kind: .demo, message: "Nothing was sent to a PC. Pair your own PC to use this device as its second screen.")
            return
        }
        let client: OrbitAPIClient
        do { client = try context.makeClient() } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            return
        }
        let settings = Self.streamSettings(from: baseSettings)
        let size = target.size.displaySize
        guard size.isAcceptedByPC else {
            problem = OrbitStreamDisplayProblem(title: "Screen size not supported", message: "The PC accepts virtual displays from 640 × 480 to 7680 × 4320; this screen streams at \(size).")
            return
        }
        sessionPCID = context.pcID
        sessionPCName = context.pcName
        sessionClient = client
        sessionHost = host
        sessionSize = size
        sessionRefreshRate = Self.refreshRate(for: settings)
        placementHint = nil
        // Busy right away, so a second tap cannot start another request.
        phase = .preparing("Turning on the virtual display on \(context.pcName)…")
        Task { await runStart(context: context, host: host, client: client, settings: settings, target: target, position: position, onStreamBegan: onStreamBegan) }
    }

    private func runStart(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator, client: OrbitAPIClient, settings: MoonlightStreamSettings,
                          target: MoonlightStreamTarget, position: OrbitSecondScreenPosition, onStreamBegan: @escaping @MainActor () -> Void) async {
        let keepAwake = OrbitLongRequestGuard(reason: "Turning on the second screen")
        let result: OrbitStreamDisplayResult
        do {
            result = try await OrbitStreamDisplayAPI.setSecondScreen(client, enabled: true, size: target.size.displaySize,
                                                                     refreshRate: sessionRefreshRate, position: position.rawValue)
        } catch {
            keepAwake.end()
            problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            finishSession()
            await refreshAfterChange(client: client, pcID: context.pcID)
            return
        }
        keepAwake.end()
        if let display = result.display { apply(display, pcID: context.pcID) }
        placementHint = Self.hint(placement: result.placement, hint: result.placementHint)
        let notes = [result.reload == "nextStart" ? OrbitStreamDisplayAPI.nextStartNote(size: target.size.displaySize, pcName: context.pcName) : nil,
                     result.cleanWarning].compactMap { $0 }
        if !notes.isEmpty { notice = Notice(kind: .note, message: notes.joined(separator: " ")) }

        // Sunshine restarted to use the virtual display: wait until it answers and lists its apps again. Only an
        // answer read after the change counts (the coordinator still holds the one from before the restart).
        phase = .waitingForSunshine
        let changedAt = Date()
        var desktop: MoonlightApp?
        for attempt in 0..<20 {
            await Self.refreshNow(host)
            if host.isPaired, host.reachable, (host.lastRefreshed ?? .distantPast) >= changedAt, let app = Self.desktopApp(in: host) {
                desktop = app
                break
            }
            if !host.isPaired { break }
            try? await Task.sleep(nanoseconds: attempt < 4 ? 700_000_000 : 1_500_000_000)
        }
        guard host.isPaired else {
            problem = OrbitStreamDisplayProblem(title: "Pair Sunshine first", message: "Orbit isn't paired with Sunshine on \(context.pcName) any more. Pair it again, then start the second screen. Until then the virtual display stays on: select Turn Off to undo it.")
            finishSession(keepingHost: true)
            return
        }
        guard let desktop else {
            if host.reachable {
                problem = OrbitStreamDisplayProblem(title: "No Desktop app in Sunshine", message: "Add an app named Desktop in Sunshine's web UI (Applications › Add New, no command), then start again. The virtual display stays on until you select Turn Off.")
            } else {
                problem = OrbitStreamDisplayProblem(title: "Sunshine didn't come back", message: "Sunshine on \(context.pcName) is still restarting. Select Start again in a moment, or Turn Off to undo the change.")
            }
            finishSession(keepingHost: true)
            return
        }

        let request = MoonlightStreamController.Request(host: host, app: desktop, pcName: context.pcName, settings: settings, target: target, secondScreen: true)
        launchedAppID = desktop.id
        phase = .streaming
        MoonlightStreamController.shared.begin(request)
        onStreamBegan()

        // Orbit moves the virtual display to the chosen side once Sunshine puts it on the desktop: read the
        // result a little later, so a "do it in Windows Settings" hint shows when that did not work.
        if result.placement == "pending" {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard phase == .streaming, sessionPCID == context.pcID, let fetched = try? await OrbitStreamDisplayAPI.status(client) else { return }
            apply(fetched, pcID: context.pcID)
            if fetched.secondScreen.placement == "manual" {
                placementHint = Self.hint(placement: "manual", hint: nil, position: position)
            }
        }
    }

    /// A fresh server info and app list. `refresh()` returns at once while another screen's refresh runs, so
    /// wait for that one to end first (at most 10 s).
    private static func refreshNow(_ host: MoonlightHostCoordinator) async {
        for _ in 0..<50 where host.isRefreshing { try? await Task.sleep(nanoseconds: 200_000_000) }
        await host.refresh()
    }

    /// The Sunshine app to stream: the one titled Desktop (never another app as a fallback).
    static func desktopApp(in host: MoonlightHostCoordinator) -> MoonlightApp? {
        host.apps.first { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Desktop") == .orderedSame }
    }

    private static func hint(placement: String?, hint: String?, position: OrbitSecondScreenPosition? = nil) -> String? {
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

    /// "Turn Off": ends the second screen's stream (which then turns the virtual display off), or turns off
    /// a virtual display left on (by a stream that already ended, or by another device).
    func stop(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator?) {
        guard !isBusy else { return }
        problem = nil
        notice = nil
        if context.isDemo {
            status = .demo()
            notice = Notice(kind: .demo, message: "Nothing was sent to a PC.")
            return
        }
        let controller = MoonlightStreamController.shared
        if phase == .streaming, controller.isPresented, controller.request?.secondScreen == true {
            controller.end(quitApp: false)   // `streamPresentationChanged` continues with `runStop`
            return
        }
        if sessionPCID != context.pcID || sessionClient == nil {
            do { sessionClient = try context.makeClient() } catch {
                problem = OrbitStreamDisplayErrors.describe(error)
                return
            }
            sessionPCID = context.pcID
            sessionPCName = context.pcName
            sessionHost = host
        }
        phase = .stopping("Ending the stream…")
        Task { await runStop() }
    }

    private func runStop() async {
        guard let client = sessionClient, let pcID = sessionPCID else { phase = .idle; return }
        let pcName = sessionPCName
        let keepAwake = OrbitLongRequestGuard(reason: "Turning off the second screen")
        defer { keepAwake.end() }
        // Sunshine keeps the Desktop session open after a disconnect, and the PC restarts Sunshine only once
        // nothing runs in it: close that session first. Only the Desktop, never another app, and never a
        // stream another device is watching right now (unless this device just streamed it itself).
        if let host = sessionHost, host.isPaired {
            let before = try? await OrbitStreamDisplayAPI.status(client)
            if let before { apply(before, pcID: pcID) }
            await Self.refreshNow(host)
            let ownSession = launchedAppID != nil
            if let current = host.info?.currentGame, current != 0, ownSession || before?.streamActive != true,
               current == launchedAppID || current == Self.desktopApp(in: host)?.id {
                phase = .stopping("Closing the Desktop session in Sunshine…")
                await host.quitRunningApp()
            }
        }
        phase = .stopping("Turning off the virtual display on \(pcName)…")
        // The stream's sockets take a moment to close after the session ends.
        for attempt in 0..<8 {
            guard let current = try? await OrbitStreamDisplayAPI.status(client) else { break }
            apply(current, pcID: pcID)
            if !current.isBusy || attempt == 7 { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        do {
            let result = try await OrbitStreamDisplayAPI.setSecondScreen(client, enabled: false, size: nil, refreshRate: sessionRefreshRate,
                                                                         position: status?.secondScreen.position ?? "right")
            if let display = result.display { apply(display, pcID: pcID) }
            var message = result.changed
                ? "The second screen is off. Sunshine on \(pcName) streams the main monitor again."
                : "The second screen is off."
            if let warning = result.cleanWarning { message += " \(warning)" }
            notice = Notice(kind: .done, message: message)
            placementHint = nil
            launchedAppID = nil
            finishSession()
        } catch {
            problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            // Keep the client and host so Turn Off can try again; the PC still has the virtual display on.
            phase = .idle
            await refreshAfterChange(client: client, pcID: pcID)
        }
    }

    // MARK: Moving it

    /// Puts the virtual display on the other side while it is on (no Sunshine restart is needed for that).
    func move(to position: OrbitSecondScreenPosition, context: OrbitStreamDisplayContext, baseSettings: MoonlightStreamSettings) {
        guard let status, status.secondScreen.active, status.secondScreen.position != position.rawValue, !isBusy, !isMoving else { return }
        if context.isDemo {
            var demo = status
            demo.secondScreen.position = position.rawValue
            self.status = demo
            return
        }
        guard let size = (sessionPCID == context.pcID ? sessionSize : nil) ?? status.secondScreen.size else { return }
        let client: OrbitAPIClient
        do { client = try (sessionPCID == context.pcID ? sessionClient : nil) ?? context.makeClient() } catch {
            problem = OrbitStreamDisplayErrors.describe(error)
            return
        }
        let refreshRate = status.secondScreen.refreshRate ?? Self.refreshRate(for: Self.streamSettings(from: baseSettings))
        isMoving = true
        problem = nil
        Task {
            defer { isMoving = false }
            do {
                let result = try await OrbitStreamDisplayAPI.setSecondScreen(client, enabled: true, size: size, refreshRate: refreshRate, position: position.rawValue)
                if let display = result.display { apply(display, pcID: context.pcID) }
                placementHint = Self.hint(placement: result.placement, hint: result.placementHint, position: position)
            } catch {
                problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: true)
            }
        }
    }

    // MARK: Helpers

    private func finishSession(keepingHost: Bool = false) {
        phase = .idle
        if !keepingHost {
            sessionPCID = nil
            sessionClient = nil
            sessionHost = nil
            sessionSize = nil
        }
    }

    private func refreshAfterChange(client: OrbitAPIClient, pcID: String) async {
        guard let fetched = try? await OrbitStreamDisplayAPI.status(client) else { return }
        apply(fetched, pcID: pcID)
    }
}
#endif
