import AVFoundation
import SwiftUI
import UIKit

// iPhone as a PC webcam (DESIGN F10), the connection side: the PC's webcam status and setup
// (`GET /api/webcam`, `POST /api/webcam/install|uninstall`) and the camera WebSocket (`WS /ws/camera`).
// The JSON types and the frame pipeline are in `OrbitWebcamPipeline.swift`. Contract: `orbit_webcam.py`.

/// Settings kept between visits.
enum OrbitWebcamPreferences {
    static let resolutionKey = "orbit.webcam.resolution"
    static let fpsKey = "orbit.webcam.fps"
    static let lensKey = "orbit.webcam.lens"
}

// MARK: - Camera socket

/// `WS /ws/camera` on the PC's encrypted port: the hello, the PC's text replies and binary JPEG frames.
final class OrbitWebcamSocket: OrbitWebcamFrameSink, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    /// Keeps the pinned session alive as long as the socket.
    let client: OrbitAPIClient

    init(client: OrbitAPIClient) throws {
        self.client = client
        task = try client.cameraWebSocket()
        task.maximumMessageSize = 64 * 1024
    }

    func open(_ format: OrbitWebcamFormat) async throws {
        task.resume()
        let hello = try JSONEncoder().encode(format)
        try await task.send(.string(String(decoding: hello, as: UTF8.self)))
    }

    func next() async throws -> OrbitWebcamMessage {
        guard case .string(let text) = try await task.receive() else { return .other }
        return OrbitWebcamMessage.parse(text)
    }

    func send(_ jpeg: Data, completion: @escaping (Error?) -> Void) {
        task.send(.data(jpeg), completionHandler: completion)
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// The HTTP status of a refused WebSocket handshake.
    var handshakeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}

/// Why the camera stream ended, in plain words.
struct OrbitWebcamStreamEnd: Error {
    let message: String
    /// The PC said why (its `error`/`code` message): don't reconnect on our own.
    let fromPC: Bool
    var code: String? = nil
}

// MARK: - Model

/// The webcam screen's state for the selected PC. Demo mode runs the camera and the encoder but never
/// touches the network.
@MainActor
final class OrbitWebcamModel: ObservableObject {
    enum StreamPhase: Equatable {
        case idle
        case connecting
        case streaming
        case reconnecting(attempt: Int)

        var isActive: Bool { self != .idle }
    }

    enum SetupPhase: Equatable {
        case idle
        case installing
        case removing
    }

    struct Note: Equatable {
        enum Kind { case info, warning, error }
        var title: String
        var message: String
        var icon: String
        var kind: Kind
    }

    // PC
    @Published private(set) var features: OrbitPCFeatures = .unknown
    @Published private(set) var featuresError: String?
    @Published private(set) var status: OrbitWebcamPCStatus?
    @Published private(set) var statusError: String?
    @Published private(set) var isLoadingStatus = false
    @Published private(set) var setupPhase: SetupPhase = .idle
    @Published private(set) var setupMessage: String?
    @Published private(set) var setupError: String?
    @Published private(set) var clipboardMessage: String?
    // Streaming
    @Published private(set) var phase: StreamPhase = .idle
    @Published private(set) var appConnected = false
    @Published private(set) var cameraName = "DirectShow Softcam"
    @Published private(set) var sentFPS: Double = 0
    @Published private(set) var megabitsPerSecond: Double = 0
    @Published private(set) var streamFormat: OrbitWebcamFormat?
    /// Why streaming stopped or can't continue (cleared by the next start).
    @Published private(set) var streamNote: Note?
    /// This device stopped streaming a moment ago and the PC may still count it in `clients`.
    @Published private var justStopped = false
    // Camera
    @Published private(set) var cameraState: OrbitWebcamCamera.State = .idle
    @Published private(set) var cameraAccess: AVAuthorizationStatus = .notDetermined
    @Published private(set) var isThermalLimited = false
    @Published var isDimmed = false {
        didSet { camera.setPreviewEnabled(!isDimmed) }
    }
    // Choices (kept between visits)
    @Published var resolution: OrbitWebcamResolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: OrbitWebcamPreferences.resolutionKey); applyCaptureSettings() }
    }
    @Published var frameRate: Int {
        didSet { UserDefaults.standard.set(frameRate, forKey: OrbitWebcamPreferences.fpsKey); applyCaptureSettings() }
    }
    @Published var lens: OrbitWebcamLens {
        didSet { UserDefaults.standard.set(lens.rawValue, forKey: OrbitWebcamPreferences.lensKey); applyCaptureSettings() }
    }

    /// Webcam screens on screen right now. `orbit://webcam` opens no second one while one shows: two
    /// screens would run two capture sessions that interrupt each other.
    private static var screensOnScreen = 0
    static var isOnScreen: Bool { screensOnScreen > 0 }

    let camera = OrbitWebcamCamera()
    /// Which built-in cameras exist (looked up once: a lookup per redraw costs a device discovery).
    let hasBothCameras: Bool
    let hasAnyCamera: Bool
    private let pipeline = OrbitWebcamPipeline()
    private(set) var isDemo = false
    private(set) var pcName = "your PC"
    private(set) var pcID = ""
    private var link: OrbitPCLink?
    private var isOnline = false
    private var hasSecureConnection = false
    private var isVisible = false
    private var generation = 0
    private var streamGeneration = 0
    private var socket: OrbitWebcamSocket?
    /// When the camera socket last heard from the PC.
    private var lastHeardAt = Date()
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var lastStatsAt = Date()
    private var slowSeconds = 0
    private var fastSeconds = 0
    private var idleTimerBefore: Bool?
    private var thermalObserver: NSObjectProtocol?
    private var cameraStarted = false
    /// The setup/removal request came back with 202 (or got lost), so the status poll decides how it
    /// ended. Until then a poll must not end it: it may land before the PC even started the setup.
    private var setupAwaitsPoll = false

    /// Reconnects after a dropped connection: the PC keeps the camera for 5 s, so apps that use it
    /// barely notice a quick reconnect.
    private static let reconnectDelays: [Double] = [0.5, 1.5, 3, 5]
    /// How long the camera socket may stay silent: the PC answers the hello at once and then sends
    /// {"connected":…} every 5 s.
    private static let silenceTimeout: Double = 15
    /// The PC holds the setup's answer for up to 90 s (then 202). A request timeout longer than the
    /// session's 20 s applies as well: URLSession uses the request's own `timeoutInterval`.
    private static let setupTimeout: TimeInterval = 120

    init() {
        let defaults = UserDefaults.standard
        resolution = OrbitWebcamResolution(rawValue: defaults.string(forKey: OrbitWebcamPreferences.resolutionKey) ?? "") ?? .hd720
        let savedFPS = defaults.integer(forKey: OrbitWebcamPreferences.fpsKey)
        frameRate = [15, 30].contains(savedFPS) ? savedFPS : 30
        let hasFront = OrbitWebcamCamera.hasCamera(.front), hasBack = OrbitWebcamCamera.hasCamera(.back)
        hasBothCameras = hasFront && hasBack
        hasAnyCamera = hasFront || hasBack
        let savedLens = OrbitWebcamLens(rawValue: defaults.string(forKey: OrbitWebcamPreferences.lensKey) ?? "") ?? .front
        lens = (savedLens == .front ? hasFront : hasBack) ? savedLens : (hasBack && !hasFront ? .back : .front)
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        camera.onState = { [weak self] state in self?.cameraStateChanged(state) }
        camera.setFrameHandler { [pipeline] buffer, time in pipeline.handle(buffer, time: time) }
    }

    // MARK: Lifecycle

    /// The screen appeared, or the selected PC / connection changed.
    func configure(_ vm: OrbitViewModel) {
        let newLink = OrbitPCLink.current(vm)
        let changed = vm.isDemoMode != isDemo || newLink?.id != link?.id || vm.connectionID != generation
        isOnline = vm.metrics.isOnline
        hasSecureConnection = vm.hasSecureConnection
        pcName = vm.isDemoMode ? "Demo PC" : vm.selectedPCName
        guard changed || !isVisible else { return }
        if phase.isActive {
            let message = newLink?.id != link?.id || vm.isDemoMode != isDemo
                ? "You switched to another PC."
                : "The connection to \(pcName) changed. Tap Start Streaming to go on."
            stopStreaming(note: Note(title: "Streaming stopped", message: message, icon: "arrow.left.arrow.right", kind: .info))
        }
        generation = vm.connectionID
        isDemo = vm.isDemoMode
        link = newLink
        pcID = vm.isDemoMode ? "" : vm.selectedPCID
        features = .unknown; featuresError = nil
        status = nil; statusError = nil
        setupPhase = .idle; setupAwaitsPoll = false; setupMessage = nil; setupError = nil; clipboardMessage = nil
        if isDemo {
            features = .available(agentVersion: nil, features: ["webcam"])
            status = .demo
        }
    }

    func appear(_ vm: OrbitViewModel) {
        configure(vm)
        if !isVisible { Self.screensOnScreen += 1 }
        isVisible = true
        observeThermalState()
        startCameraIfAllowed()
        startPolling()
    }

    func disappear() {
        if isVisible { Self.screensOnScreen = max(0, Self.screensOnScreen - 1) }
        isVisible = false
        if phase.isActive {
            // Shown when the screen comes back (another tab, for example): the camera only runs here.
            stopStreaming(note: Note(title: "Streaming stopped", message: "You left the Webcam screen, so the camera turned off. Tap Start Streaming to go on.",
                                     icon: "pause.circle.fill", kind: .info))
        }
        isDimmed = false
        pollTask?.cancel(); pollTask = nil
        stopCamera()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
    }

    func onlineChanged(_ online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { startPolling() }
    }

    private func stopBecauseOffline() {
        stopStreaming(note: Note(title: "Streaming stopped", message: "\(pcName) went offline or to sleep. Wake the PC, then tap Start Streaming.",
                                 icon: "wifi.slash", kind: .error))
        OrbitHaptics.error()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // iOS turns the camera off for apps that aren't on screen: end the stream cleanly
            // instead of sending a frozen picture.
            if self.phase.isActive {
                // iOS suspends Orbit a moment after it leaves the screen, and a socket closed then reaches
                // the PC only when Orbit comes back: until then apps on the PC would show the last picture.
                // A few seconds of background time let the close go out now.
                let backgroundTime = OrbitBackgroundTask(name: "Orbit webcam: closing the camera connection")
                stopStreaming(note: Note(title: "Streaming stopped",
                                         message: "Orbit left the screen, and iOS turns the camera off for apps that aren't on screen. Tap Start Streaming to go on.",
                                         icon: "moon.zzz.fill", kind: .warning))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    backgroundTime.end()
                }
            }
            isDimmed = false
            stopCamera()
            pollTask?.cancel(); pollTask = nil
        case .active:
            if isVisible {
                startCameraIfAllowed()
                startPolling()
            }
        default:
            break
        }
    }

    // MARK: Camera

    var captureSettings: OrbitWebcamCaptureSettings {
        if isThermalLimited { return OrbitWebcamCaptureSettings(lens: lens, resolution: .hd720, fps: 15) }
        return OrbitWebcamCaptureSettings(lens: lens, resolution: resolution, fps: frameRate)
    }


    func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
                if granted { self.startCameraIfAllowed() }
            }
        }
    }

    private func startCameraIfAllowed() {
        guard isVisible else { return }
        if !camera.usesSyntheticFrames {
            cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
            guard hasAnyCamera else {
                cameraState = .failed("This \(OrbitWebcamDevice.word) has no camera Orbit can use.")
                return
            }
            switch cameraAccess {
            case .authorized: break
            case .notDetermined: requestCameraAccess(); return
            default: return
            }
        }
        cameraStarted = true
        camera.start(captureSettings)
    }

    private func stopCamera() {
        guard cameraStarted else { return }
        cameraStarted = false
        camera.stop()
    }

    private func applyCaptureSettings() {
        if cameraStarted { camera.update(captureSettings) }
        updatePipelineFormat()
    }

    var canUseCamera: Bool {
        camera.usesSyntheticFrames || (cameraAccess == .authorized && hasAnyCamera)
    }

    private func cameraStateChanged(_ state: OrbitWebcamCamera.State) {
        cameraState = state
    }

    func switchLens() {
        guard hasBothCameras else { return }
        lens = lens == .front ? .back : .front
        OrbitHaptics.selection()
    }

    // MARK: Heat

    private func observeThermalState() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalStateChanged() }
        }
        thermalStateChanged()
    }

    /// Serious or critical heat: capture 720p at 15 fps. The PC keeps the camera format it was given
    /// and scales the smaller frames up, so apps on the PC keep the camera open.
    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical || Self.forcesHeat
        guard hot != isThermalLimited else { return }
        isThermalLimited = hot
        applyCaptureSettings()
    }

    #if DEBUG
    /// `ORBIT_WEBCAM_FORCE_HOT=1` (Debug): behave as if the device were hot, for checks in the Simulator.
    private static var forcesHeat: Bool { ProcessInfo.processInfo.environment["ORBIT_WEBCAM_FORCE_HOT"] == "1" }
    #else
    private static let forcesHeat = false
    #endif

    private func updatePipelineFormat() {
        let format = streamFormat ?? OrbitWebcamFormat(width: resolution.width, height: resolution.height, fps: frameRate)
        if isThermalLimited {
            // 16:9 at most 1280×720, never more than the announced size.
            let width = min(format.width, 1280), height = min(format.height, 720)
            pipeline.setFrameFormat(width: width, height: height, fps: min(format.fps, 15))
        } else {
            pipeline.setFrameFormat(width: format.width, height: format.height, fps: format.fps)
        }
    }

    // MARK: Status from the PC

    var supportsWebcam: Bool { features.has("webcam") }

    /// What keeps a real PC from being used now (nil when it can be); demo mode never has one.
    var pcProblem: (title: String, message: String, icon: String)? {
        if isDemo { return nil }
        if pcID.isEmpty { return ("Pair a PC first", "Find and pair your Windows PC in My PCs, then come back to use this \(OrbitWebcamDevice.word) as its webcam.", "desktopcomputer") }
        if !hasSecureConnection || link == nil { return ("Needs the encrypted connection", "Pair \(pcName) again in My PCs. The camera only travels over Orbit's encrypted connection.", "lock.trianglebadge.exclamationmark") }
        if !isOnline { return ("\(pcName) is offline", "Wake the PC or check that Orbit PC Companion is running, then try again.", "wifi.slash") }
        if features == .olderAgent || (features.isKnown && !supportsWebcam) {
            return ("Update Orbit PC Companion", "The agent on \(pcName) doesn't have the webcam yet. Update it from Settings › Check for PC Companion Update, then come back.", "arrow.down.circle.fill")
        }
        return nil
    }

    func refresh() async {
        guard !isDemo else { return }
        await loadStatus(force: true)
    }

    private func startPolling() {
        guard !isDemo, isVisible else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // The model is held only while it asks the PC, never while it waits.
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One status poll; returns the seconds until the next one (sooner while a setup runs).
    private func pollOnce() async -> Double {
        await loadStatus(force: false)
        let busy = setupPhase != .idle || status?.isBusy == true
        return busy ? 2 : (phase.isActive ? 5 : 8)
    }

    /// The PC drops this phone from `clients` a moment after its socket closes: ask again then, so
    /// the screen doesn't report another device streaming until the next regular poll.
    private func refreshStatusSoon() {
        guard !isDemo, isVisible else { return }
        justStopped = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.isVisible, UIApplication.shared.applicationState == .active else {
                self?.justStopped = false
                return
            }
            await self.loadStatus(force: false)
            self.justStopped = false
        }
    }

    /// Another iPhone or iPad streams to this PC's webcam right now (the PC's `clients`, not counting
    /// this device's own stream or the one it just stopped).
    var otherDeviceStreaming: Bool {
        guard !isDemo, !phase.isActive, !justStopped, let clients = status?.clients else { return false }
        return clients > 0
    }

    private func loadStatus(force: Bool) async {
        guard !isDemo, let link, isOnline, hasSecureConnection else { return }
        let version = generation
        isLoadingStatus = true
        defer { if version == generation { isLoadingStatus = false } }
        do {
            let found = try await OrbitFeatureStore.shared.features(for: link, maxAge: force ? 0 : 120)
            guard version == generation else { return }
            features = found
            featuresError = nil
        } catch {
            guard version == generation else { return }
            featuresError = OrbitPlainError.describe(error)
            return
        }
        guard supportsWebcam else { return }
        do {
            let reply: OrbitWebcamPCStatus = try await link.client.get("/api/webcam")
            guard version == generation else { return }
            status = reply
            statusError = nil
            if let name = reply.cameraName, !name.isEmpty, !phase.isActive { cameraName = name }
            finishSetupIfDone(reply)
        } catch {
            guard version == generation else { return }
            statusError = OrbitPlainError.describe(error)
        }
    }

    // MARK: Setup on the PC

    /// `POST /api/webcam/install`: one Windows administrator prompt on the PC. The PC answers within
    /// 90 s (202 while the prompt is still open), so the request may wait up to 2 minutes.
    func installOnPC() {
        guard !isDemo, let link, setupPhase == .idle else { return }
        let version = generation
        setupPhase = .installing
        setupAwaitsPoll = false
        setupMessage = nil; setupError = nil
        OrbitHaptics.tap()
        // Ask the PC every 2 s from now on (not at the next regular poll), so "Approve the Windows prompt"
        // shows as soon as the PC opens it. The answer to the request itself comes only after that prompt.
        startPolling()
        Task {
            do {
                let data = try await link.client.data("/api/webcam/install", method: "POST", timeout: Self.setupTimeout)
                guard version == generation else { return }
                let reply = try JSONDecoder().decode(OrbitWebcamPCStatus.self, from: data)
                status = reply
                switch reply.status {
                case "waitingForApproval":
                    // Still waiting for the person at the PC: the status poll finishes it.
                    setupAwaitsPoll = true
                    startPolling()
                case "alreadyInstalled":
                    setupPhase = .idle
                    setupMessage = "The webcam was already set up on \(pcName)."
                    OrbitHaptics.success()
                default:
                    setupPhase = .idle
                    setupMessage = "The webcam is set up on \(pcName). Apps that were already open need a restart to find the \"\(reply.cameraName ?? cameraName)\" camera."
                    OrbitHaptics.success()
                }
            } catch {
                guard version == generation else { return }
                await setupRequestFailed(error, removing: false)
            }
        }
    }

    /// `POST /api/webcam/uninstall`: same single prompt.
    func removeFromPC() {
        guard !isDemo, let link, setupPhase == .idle else { return }
        if phase.isActive { stopStreaming(note: nil) }
        let version = generation
        setupPhase = .removing
        setupAwaitsPoll = false
        setupMessage = nil; setupError = nil
        OrbitHaptics.tap()
        startPolling()
        Task {
            do {
                let data = try await link.client.data("/api/webcam/uninstall", method: "POST", timeout: Self.setupTimeout)
                guard version == generation else { return }
                let reply = try JSONDecoder().decode(OrbitWebcamPCStatus.self, from: data)
                status = reply
                switch reply.status {
                case "waitingForApproval":
                    setupAwaitsPoll = true
                    startPolling()
                case "notInstalled":
                    setupPhase = .idle
                    setupMessage = "The webcam wasn't set up on \(pcName), so there was nothing to remove."
                default:
                    setupPhase = .idle
                    setupMessage = reply.filesLeft == true
                        ? "The webcam was removed from \(pcName). Some of its files are still in use; restart the PC and remove it again to delete them."
                        : "The webcam was removed from \(pcName)."
                    OrbitHaptics.success()
                }
            } catch {
                guard version == generation else { return }
                await setupRequestFailed(error, removing: true)
            }
        }
    }

    private func setupRequestFailed(_ error: Error, removing: Bool) async {
        if let orbit = error as? OrbitError, orbit.statusCode != nil {
            // The PC's own sentence (declined prompt, missing Visual C++ runtime with the winget
            // commands, ARM, not signed in, download or registration problems).
            setupPhase = .idle
            setupError = orbit.message
            OrbitHaptics.error()
            await loadStatus(force: false)
            return
        }
        // The answer got lost on the way (Wi-Fi, a timeout): the setup may still be running on the
        // PC, so ask it.
        await loadStatus(force: false)
        if status?.isBusy == true {
            setupAwaitsPoll = true
            startPolling()
            return
        }
        setupPhase = .idle
        if let pcError = status?.installError, !pcError.isEmpty {
            setupError = pcError
        } else if status?.isSetUp == true, !removing {
            setupMessage = "The webcam is set up on \(pcName)."
        } else {
            setupError = (removing ? "Couldn't remove the webcam. " : "Couldn't set up the webcam. ") + OrbitPlainError.describe(error)
        }
        OrbitHaptics.error()
    }

    /// Ends a setup or removal that the PC finished while Orbit was polling (after a 202).
    private func finishSetupIfDone(_ reply: OrbitWebcamPCStatus) {
        guard setupPhase != .idle, setupAwaitsPoll, !reply.isBusy else { return }
        let removing = setupPhase == .removing
        setupPhase = .idle
        setupAwaitsPoll = false
        if let error = reply.installError, !error.isEmpty {
            setupError = error
            OrbitHaptics.error()
        } else if removing {
            setupMessage = reply.isSetUp ? nil : "The webcam was removed from \(pcName)."
            if reply.isSetUp { setupError = "Windows still lists the webcam on \(pcName). Try removing it again." }
        } else if reply.isSetUp {
            setupMessage = "The webcam is set up on \(pcName). Apps that were already open need a restart to find the \"\(reply.cameraName ?? cameraName)\" camera."
            OrbitHaptics.success()
        } else {
            setupError = reply.reason ?? "The setup on \(pcName) didn't finish. Try again."
        }
    }

    /// Puts the winget commands for the Visual C++ runtime on the PC's clipboard, ready to paste
    /// into Terminal there.
    func sendRuntimeCommandsToPC() {
        guard let link, let commands = status?.runtime?.commands, !commands.isEmpty else { return }
        let text = commands.joined(separator: "\r\n")
        clipboardMessage = nil
        Task {
            struct Body: Encodable { let text: String }
            struct Reply: Decodable { let status: String? }
            do {
                let _: Reply = try await link.client.send("/api/clipboard", method: "PUT", body: Body(text: text))
                clipboardMessage = "Copied to \(pcName)'s clipboard. Open Terminal on the PC, paste and press Enter."
                OrbitHaptics.success()
            } catch {
                clipboardMessage = "Couldn't reach the PC's clipboard. \(OrbitPlainError.describe(error))"
            }
        }
    }

    func copyRuntimeCommands() {
        guard let commands = status?.runtime?.commands, !commands.isEmpty else { return }
        UIPasteboard.general.string = commands.joined(separator: "\n")
        clipboardMessage = "Copied to this \(OrbitWebcamDevice.word)'s clipboard."
        OrbitHaptics.success()
    }

    // MARK: Streaming

    /// Why Start can't be used now (nil when it can).
    var startBlocker: String? {
        if !canUseCamera { return "Allow camera access first." }
        if case .failed(let message) = cameraState { return message }
        if isDemo { return nil }
        if let problem = pcProblem { return problem.title + "." }
        if !features.isKnown { return featuresError == nil ? "Checking what \(pcName) can do…" : "Couldn't reach \(pcName)." }
        if setupPhase != .idle || status?.isBusy == true { return "Wait for the setup on \(pcName) to finish." }
        if status?.isUnsupportedPC == true { return "\(pcName) can't run the webcam." }
        if let status, !status.isSetUp { return "Set up the webcam on \(pcName) first." }
        return nil
    }

    var announcedFormat: OrbitWebcamFormat {
        var format = OrbitWebcamFormat(width: resolution.width, height: resolution.height, fps: frameRate)
        if let status, !status.accepts(width: format.width, height: format.height, fps: format.fps) {
            format = OrbitWebcamFormat(width: 1280, height: 720, fps: min(frameRate, status.limits?.maxFPS ?? 30))
        }
        return format
    }

    func startStreaming() {
        guard !phase.isActive, startBlocker == nil, isDemo || link != nil else { return }
        streamNote = nil
        appConnected = false
        streamGeneration += 1
        let format = announcedFormat
        streamFormat = format
        updatePipelineFormat()
        pipeline.currentQuality = OrbitWebcamPipeline.bestQuality
        keepScreenAwake(true)
        startStats()
        OrbitHaptics.press()
        if isDemo {
            phase = .streaming
            pipeline.setSink(OrbitWebcamDiscardSink())
            return
        }
        guard let link else { return }
        phase = .connecting
        let token = streamGeneration
        streamTask = Task { [weak self] in await self?.run(link: link, format: format, token: token) }
    }

    func stopStreaming() {
        stopStreaming(note: nil)
        OrbitHaptics.tap()
    }

    private func stopStreaming(note: Note?) {
        let wasConnected = phase.isActive && !isDemo
        streamGeneration += 1
        streamTask?.cancel(); streamTask = nil
        pipeline.setSink(nil)
        socket?.close(); socket = nil
        if wasConnected { refreshStatusSoon() }
        phase = .idle
        appConnected = false
        streamFormat = nil
        isDimmed = false
        updatePipelineFormat()
        stopStats()
        keepScreenAwake(false)
        if let note { streamNote = note }
    }

    /// Connects, streams until the connection ends, and reconnects after a dropped connection.
    private func run(link: OrbitPCLink, format: OrbitWebcamFormat, token: Int) async {
        var attempt = 0
        var isRetry = false
        while token == streamGeneration, !Task.isCancelled {
            let (end, streamed) = await connectAndStream(link: link, format: format, token: token, isRetry: isRetry)
            guard token == streamGeneration, !Task.isCancelled else { return }
            pipeline.setSink(nil)
            socket?.close(); socket = nil
            guard let end else { return }
            // A connection that streamed earns a fresh set of quick retries (a long call may see
            // several short Wi-Fi drops); only failures in a row use them up.
            if streamed { attempt = 0 }
            isRetry = true
            if end.fromPC || attempt >= Self.reconnectDelays.count || !isVisible {
                let title = end.fromPC ? "Streaming stopped by \(pcName)" : "Streaming stopped"
                // This also asks the PC for its status again a moment later (from a fresh task: this
                // one is cancelled now), so "removed from this PC" shows the setup button again.
                stopStreaming(note: Note(title: title, message: end.message, icon: "exclamationmark.triangle.fill", kind: .error))
                OrbitHaptics.error()
                return
            }
            // Two quick retries failed and Orbit can't reach the PC at all either: it went to sleep or
            // left the network, so stop instead of showing "Reconnecting…" for another minute. (A short
            // Wi-Fi drop is still ridden out: it rarely outlasts the first two retries.)
            if !isOnline && attempt >= 2 {
                stopBecauseOffline()
                return
            }
            phase = .reconnecting(attempt: attempt + 1)
            try? await Task.sleep(for: .seconds(Self.reconnectDelays[attempt]))
            attempt += 1
        }
    }

    /// One connection. Returns why it ended (nil when it was closed on purpose) and whether the PC
    /// got as far as "ready".
    private func connectAndStream(link: OrbitPCLink, format: OrbitWebcamFormat, token: Int, isRetry: Bool) async -> (OrbitWebcamStreamEnd?, Bool) {
        let socket: OrbitWebcamSocket
        do { socket = try OrbitWebcamSocket(client: link.client) }
        catch { return (OrbitWebcamStreamEnd(message: OrbitPlainError.describe(error), fromPC: true), false) }
        self.socket = socket
        // The PC answers the hello with "ready" (or why it can't) within a couple of seconds, and then
        // says {"connected":…} at least every 5 s. Silence for longer than `silenceTimeout` means the
        // connection is gone (the PC went to sleep, the Wi-Fi dropped) even while TCP hasn't noticed:
        // close it, so the reconnect logic takes over instead of a frozen "Live".
        lastHeardAt = Date()
        let watchdog = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastHeardAt) > Self.silenceTimeout {
                    socket?.close()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        var ready = false
        var pcFailure: OrbitWebcamStreamEnd?
        do {
            try await socket.open(format)
            while true {
                let message = try await socket.next()
                guard token == streamGeneration else { return (nil, ready) }
                lastHeardAt = Date()
                switch message {
                case .ready(let width, let height, let fps, let name):
                    ready = true
                    if let name, !name.isEmpty { cameraName = name }
                    // The PC's camera format is the one that counts (it matches the hello today).
                    if width > 0, height > 0, fps > 0, OrbitWebcamFormat(width: width, height: height, fps: fps) != streamFormat {
                        streamFormat = OrbitWebcamFormat(width: width, height: height, fps: fps)
                        updatePipelineFormat()
                    }
                    phase = .streaming
                    pipeline.setSink(socket)
                    if isRetry { streamNote = nil }
                case .connected(let connected):
                    if connected && !appConnected { OrbitHaptics.success() }
                    appConnected = connected
                case .failure(let code, let message):
                    // The PC closes right after saying why.
                    pcFailure = OrbitWebcamStreamEnd(message: message, fromPC: true, code: code)
                case .other:
                    break
                }
            }
        } catch {
            guard token == streamGeneration, !Task.isCancelled else { return (nil, ready) }
            if let pcFailure { return (pcFailure, ready) }
            return (OrbitWebcamStreamEnd(message: describe(error, socket: socket, ready: ready), fromPC: !ready && isRefusal(socket)), ready)
        }
    }

    private func isRefusal(_ socket: OrbitWebcamSocket) -> Bool {
        if let status = socket.handshakeStatus, status >= 400 { return true }
        return socket.client.pinFailureMessage != nil
    }

    private func describe(_ error: Error, socket: OrbitWebcamSocket, ready: Bool) -> String {
        if let pin = socket.client.pinFailureMessage { return pin }
        switch socket.handshakeStatus {
        case 401, 403: return "\(pcName) refused the camera connection. Pair the PC again in My PCs."
        case 404: return "The agent on \(pcName) doesn't have the webcam yet. Update Orbit PC Companion."
        case 426: return "The webcam needs Orbit's encrypted connection. Pair \(pcName) again in My PCs."
        default: break
        }
        if !ready {
            // No WebSocket handshake at all: the PC didn't answer (asleep, another network, firewall).
            guard socket.handshakeStatus == 101 else {
                return "Couldn't reach \(pcName). Check that the PC is awake, on the same network, and that Orbit PC Companion is running."
            }
            if (error as? URLError)?.code == .cancelled {
                return "\(pcName) didn't get the camera ready in time. Try again."
            }
            return "\(pcName) closed the camera connection before it was ready. Try again, or restart Orbit PC Companion on the PC."
        }
        return "Lost the connection to \(pcName). Check that the PC is awake and on the same network."
    }

    // MARK: Numbers on screen

    private func startStats() {
        stopStats()
        _ = pipeline.takeStats()
        lastStatsAt = Date()
        slowSeconds = 0; fastSeconds = 0
        sentFPS = 0; megabitsPerSecond = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStats() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStats() {
        statsTimer?.invalidate(); statsTimer = nil
        sentFPS = 0; megabitsPerSecond = 0
    }

    /// Frames per second and bitrate. When the network can't keep up (frames dropped because the
    /// previous one is still on its way), JPEG quality steps down; it climbs back once it can.
    private func updateStats() {
        let now = Date()
        let seconds = max(0.25, now.timeIntervalSince(lastStatsAt))
        lastStatsAt = now
        let stats = pipeline.takeStats()
        #if DEBUG
        if ProcessInfo.processInfo.environment["ORBIT_WEBCAM_SELFTEST"] != nil {
            print("webcam-selftest: stats frames \(stats.frames) bytes \(stats.bytes) dropped \(stats.dropped) failed \(stats.failed) · \(pipeline.debugState)")
        }
        #endif
        sentFPS = Double(stats.frames) / seconds
        megabitsPerSecond = Double(stats.bytes) * 8 / seconds / 1_000_000
        guard phase == .streaming else { return }
        let target = Double(isThermalLimited ? min(15, streamFormat?.fps ?? 15) : (streamFormat?.fps ?? frameRate))
        if stats.dropped > 0 && sentFPS < target * 0.75 {
            slowSeconds += 1; fastSeconds = 0
            if slowSeconds >= 3 {
                pipeline.currentQuality -= 0.1
                slowSeconds = 0
            }
        } else if sentFPS >= target * 0.9 {
            fastSeconds += 1; slowSeconds = 0
            if fastSeconds >= 5 {
                pipeline.currentQuality += 0.05
                fastSeconds = 0
            }
        }
    }

    // MARK: Screen

    private func keepScreenAwake(_ awake: Bool) {
        if awake {
            if idleTimerBefore == nil { idleTimerBefore = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let before = idleTimerBefore {
            UIApplication.shared.isIdleTimerDisabled = before
            idleTimerBefore = nil
        }
    }

    #if DEBUG
    private var selfTestStarted = false

    /// `ORBIT_WEBCAM_SELFTEST=install,start,wait:10,lens,dim,stop,remove` (Debug): runs the same calls
    /// as the screen's buttons, one after another, and prints the state after each step, for
    /// end-to-end checks without taps (the Simulator panel). Steps wait for the screen to be ready.
    func runSelfTestIfRequested() {
        guard !selfTestStarted, let script = ProcessInfo.processInfo.environment["ORBIT_WEBCAM_SELFTEST"] else { return }
        selfTestStarted = true
        let steps = script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { [weak self] in
            for step in steps {
                guard let self else { return }
                await self.selfTestStep(step)
                self.printSelfTestState(after: step)
            }
            print("webcam-selftest: done")
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func selfTestStep(_ step: String) async {
        switch step {
        case "install":
            await waitUntil(30) { status != nil || pcProblem != nil }
            installOnPC()
            await waitUntil(150) { setupPhase == .idle }
        case "remove":
            await waitUntil(30) { status != nil }
            removeFromPC()
            await waitUntil(150) { setupPhase == .idle }
        case "start":
            await waitUntil(30) { startBlocker == nil && (isDemo || status?.isReady == true) }
            startStreaming()
            await waitUntil(20) { phase == .streaming || phase == .idle }
        case "stop": stopStreaming()
        case "lens": switchLens()
        case "dim": isDimmed = true
        case "undim": isDimmed = false
        case "refresh": await refresh()
        case "pcclipboard":
            await waitUntil(30) { status?.runtime?.commands?.isEmpty == false }
            sendRuntimeCommandsToPC()
            await waitUntil(10) { clipboardMessage != nil }
        case "1080p": resolution = .hd1080
        case "720p": resolution = .hd720
        case "15fps": frameRate = 15
        case "30fps": frameRate = 30
        default:
            if step.hasPrefix("wait:"), let seconds = Double(step.dropFirst(5)) {
                try? await Task.sleep(for: .seconds(seconds))
            } else if step.hasPrefix("waitfor:") {
                // waitfor:connected / waitfor:idle
                let what = step.dropFirst(8)
                await waitUntil(60) { what == "connected" ? appConnected : (what == "idle" ? phase == .idle : false) }
            } else {
                print("webcam-selftest: unknown step \(step)")
            }
        }
    }

    private func printSelfTestState(after step: String) {
        let pc = status.map { "installed \($0.installed ?? false) registered \($0.registered ?? false) clients \($0.clients ?? -1) busy \($0.isBusy) reason \($0.reason ?? "none")" } ?? "status none (\(statusError ?? featuresError ?? "-"))"
        print("webcam-selftest: after \(step) · phase \(phase) · app connected \(appConnected) · \(String(format: "%.1f fps %.2f Mbps", sentFPS, megabitsPerSecond)) · format \(streamFormat.map { "\($0.width)x\($0.height)@\($0.fps)" } ?? "-") · hot \(isThermalLimited) · encoder \(pipeline.usesHardwareEncoder ? "VideoToolbox" : "CoreImage") · quality \(pipeline.currentQuality) · lens \(lens.rawValue) · dimmed \(isDimmed) · camera \(cameraState)")
        print("webcam-selftest:   pc: \(pc) · setup message \(setupMessage ?? "-") · setup error \(setupError ?? "-") · clipboard \(clipboardMessage ?? "-") · note \(streamNote.map { "\($0.title): \($0.message)" } ?? "-") · blocker \(startBlocker ?? "-")")
    }
    #endif
}
