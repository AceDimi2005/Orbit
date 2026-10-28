import AVFoundation
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// What the HTTPS launch/resume request produced; everything LiStartConnection needs.
public struct MoonlightConnectionParameters: Equatable, Sendable {
    public var address: String
    public var appVersion: String
    public var gfeVersion: String
    public var rtspSessionURL: String?
    public var serverCodecModeSupport: Int32
    /// 16-byte AES key shared with the host for input/control encryption.
    public var remoteInputKey: Data
    public var remoteInputKeyID: UInt32
    public var appName: String
    public var hostName: String
    /// The `mode=` size the launch request asked the host for. The session's video configuration uses the
    /// same frame, so the two can never disagree.
    public var streamSize: MoonlightStreamSize

    public init(address: String, appVersion: String, gfeVersion: String = "", rtspSessionURL: String? = nil, serverCodecModeSupport: Int32,
                remoteInputKey: Data, remoteInputKeyID: UInt32, appName: String, hostName: String, streamSize: MoonlightStreamSize) {
        self.address = address
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.rtspSessionURL = rtspSessionURL
        self.serverCodecModeSupport = serverCodecModeSupport
        self.remoteInputKey = remoteInputKey
        self.remoteInputKeyID = remoteInputKeyID
        self.appName = appName
        self.hostName = hostName
        self.streamSize = streamSize
    }
}

public struct MoonlightStreamStatistics: Equatable, Sendable {
    public var receivedFrames = 0
    public var droppedFrames = 0
    public var framesPerSecond = 0
    public var averageHostLatencyMs: Double?
    public var roundTripMs: Int?
    public var roundTripVarianceMs: Int?
    public var pendingFrames = 0
    public var codec = ""
    public var width = 0
    public var height = 0
    public var frameRate = 0
    public var bitrateKbps = 0
    public var hdr = false
    public init() {}
}

public enum MoonlightMouseButton: Int32, Sendable {
    case left = 1, middle = 2, right = 3, back = 4, forward = 5
}

public struct MoonlightKeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = MoonlightKeyModifiers(rawValue: 0x01)
    public static let control = MoonlightKeyModifiers(rawValue: 0x02)
    public static let alt = MoonlightKeyModifiers(rawValue: 0x04)
    public static let meta = MoonlightKeyModifiers(rawValue: 0x08)
}

public enum MoonlightTouchEvent: UInt8, Sendable {
    case hover = 0, down = 1, up = 2, move = 3, cancel = 4
}

/// One streaming session: owns the connection thread, renderer, audio and controllers.
/// The library is a process-wide singleton, so only one session streams at a time.
@MainActor
public final class MoonlightStreamSession: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting(stage: String)
        case streaming
        case failed(message: String)
        case ended(message: String?)

        public var isTerminal: Bool {
            switch self {
            case .failed, .ended: return true
            default: return false
            }
        }
        public var isActive: Bool {
            switch self {
            case .connecting, .streaming: return true
            default: return false
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var statistics = MoonlightStreamStatistics()
    @Published public private(set) var isHDR = false
    @Published public private(set) var connectionIsPoor = false
    @Published public private(set) var logLines: [String] = []

    public let renderer = MoonlightVideoRenderer()
    public private(set) var settings: MoonlightStreamSettings
    public private(set) var parameters: MoonlightConnectionParameters?

    private var core: MoonlightSessionCore?
    private var statisticsTimer: Timer?
    private var stopping = false
    private var keepAwake: MoonlightKeepAwake?
    /// The frame this session streams at, fixed by the launch request.
    public private(set) var streamSize: MoonlightStreamSize?
    private var bitrateKbps = 0

    public init(settings: MoonlightStreamSettings = MoonlightStreamSettings()) {
        self.settings = settings
    }

    public var isActive: Bool { core != nil }

    // MARK: Lifecycle

    /// `headless` runs the connection without decoding video, playing audio or forwarding
    /// controllers: enough to carry keyboard input (for example signing in to a locked PC).
    public func start(parameters: MoonlightConnectionParameters, settings: MoonlightStreamSettings, headless: Bool = false) {
        guard core == nil else { return }
        self.settings = settings
        self.parameters = parameters
        phase = .connecting(stage: "Preparing")
        isHDR = false
        connectionIsPoor = false
        statistics = MoonlightStreamStatistics()
        logLines = []

        let box = MoonlightConnectionBox()
        LiInitializeServerInformation(&box.serverInfo)
        box.serverInfo.address = box.retain(parameters.address)
        box.serverInfo.serverInfoAppVersion = box.retain(parameters.appVersion)
        if !parameters.gfeVersion.isEmpty { box.serverInfo.serverInfoGfeVersion = box.retain(parameters.gfeVersion) }
        if let url = parameters.rtspSessionURL, !url.isEmpty { box.serverInfo.rtspSessionUrl = box.retain(url) }
        box.serverInfo.serverCodecModeSupport = parameters.serverCodecModeSupport

        LiInitializeStreamConfiguration(&box.streamConfig)
        let size = parameters.streamSize
        streamSize = size
        bitrateKbps = settings.bitrateKbps(for: size)
        box.streamConfig.width = Int32(size.width)
        box.streamConfig.height = Int32(size.height)
        box.streamConfig.fps = Int32(settings.frameRate)
        box.streamConfig.bitrate = Int32(bitrateKbps)
        box.streamConfig.packetSize = settings.packetSize.bytes
        box.streamConfig.streamingRemotely = settings.packetSize == .remote ? STREAM_CFG_REMOTE : STREAM_CFG_AUTO
        box.streamConfig.audioConfiguration = settings.audio.configuration
        box.streamConfig.supportedVideoFormats = settings.supportedVideoFormats
        box.streamConfig.clientRefreshRateX100 = Int32(MoonlightDeviceCapabilities.maximumFrameRate * 100)
        box.streamConfig.colorSpace = COLORSPACE_REC_709
        box.streamConfig.colorRange = COLOR_RANGE_LIMITED
        box.streamConfig.encryptionFlags = Int32(bitPattern: 0xFFFF_FFFF) // ENCFLG_ALL
        withUnsafeMutableBytes(of: &box.streamConfig.remoteInputAesKey) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            _ = parameters.remoteInputKey.prefix(16).copyBytes(to: raw)
        }
        withUnsafeMutableBytes(of: &box.streamConfig.remoteInputAesIv) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            var keyID = parameters.remoteInputKeyID.bigEndian
            withUnsafeBytes(of: &keyID) { raw.copyMemory(from: $0) }
        }

        LiInitializeVideoCallbacks(&box.videoCallbacks)
        box.videoCallbacks.setup = { format, width, height, frameRate, _, _ in
            MoonlightSessionCore.current?.rendererSetup(format: format, width: width, height: height, frameRate: frameRate) ?? -1
        }
        box.videoCallbacks.start = { MoonlightSessionCore.current?.rendererStart() }
        box.videoCallbacks.stop = { MoonlightSessionCore.current?.rendererStop() }
        box.videoCallbacks.cleanup = { MoonlightSessionCore.current?.rendererCleanup() }
        box.videoCallbacks.capabilities = CAPABILITY_PULL_RENDERER | CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC

        LiInitializeAudioCallbacks(&box.audioCallbacks)
        box.audioCallbacks.`init` = { _, configuration, _, _ in
            guard let configuration, let core = MoonlightSessionCore.current else { return -1 }
            return core.silent ? 0 : core.audio.initialize(configuration.pointee)
        }
        box.audioCallbacks.start = { if let core = MoonlightSessionCore.current, !core.silent { core.audio.start() } }
        box.audioCallbacks.stop = { if let core = MoonlightSessionCore.current, !core.silent { core.audio.stop() } }
        box.audioCallbacks.cleanup = { if let core = MoonlightSessionCore.current, !core.silent { core.audio.cleanup() } }
        box.audioCallbacks.decodeAndPlaySample = { data, length in
            if let core = MoonlightSessionCore.current, !core.silent { core.audio.decodeAndPlay(data, length: length) }
        }
        box.audioCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION

        LiInitializeConnectionCallbacks(&box.connectionCallbacks)
        box.connectionCallbacks.stageStarting = { stage in MoonlightSessionCore.current?.stageStarting(stage) }
        box.connectionCallbacks.stageComplete = { _ in }
        box.connectionCallbacks.stageFailed = { stage, code in MoonlightSessionCore.current?.stageFailed(stage, code: code) }
        box.connectionCallbacks.connectionStarted = { MoonlightSessionCore.current?.connectionStarted() }
        box.connectionCallbacks.connectionTerminated = { code in MoonlightSessionCore.current?.connectionTerminated(code) }
        box.connectionCallbacks.rumble = { number, low, high in MoonlightSessionCore.current?.controllers.rumble(controller: number, low: low, high: high) }
        box.connectionCallbacks.connectionStatusUpdate = { status in MoonlightSessionCore.current?.connectionStatus(status) }
        box.connectionCallbacks.setHdrMode = { enabled in MoonlightSessionCore.current?.hdrChanged(enabled) }
        OrbitMoonlightInstallLogCallback(&box.connectionCallbacks)
        OrbitMoonlightSetLogSink { message in
            guard let message else { return }
            MoonlightSessionCore.current?.log(String(cString: message))
        }

        let core = MoonlightSessionCore(session: self, renderer: renderer, box: box, framePacing: settings.framePacing, headless: headless,
                                        silent: headless || settings.muteLocalAudio)
        self.core = core
        MoonlightSessionCore.setCurrent(core)
        if !headless {
            core.controllers.start()
            setKeepAwake(true, reason: "Orbit is streaming \(parameters.appName) from \(parameters.hostName)")
        }

        let thread = Thread {
            // The library is a singleton: make sure any previous connection is fully torn down.
            LiStopConnection()
            let result = LiStartConnection(&box.serverInfo, &box.streamConfig, &box.connectionCallbacks,
                                           &box.videoCallbacks, &box.audioCallbacks, nil, 0, nil, 0)
            core.startFinished(result)
        }
        thread.name = "Orbit Moonlight Connection"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Ends the stream. Safe to call from any state.
    public func stop() {
        guard let core, !stopping else { return }
        stopping = true
        LiInterruptConnection()
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            LiStopConnection()
            // Keep the session alive until teardown has run: it stops the controllers, clears the active core
            // and lets go of the keep-awake hold even when the UI has already dropped this session.
            Task { @MainActor [self] in self.finishTeardown(core: core, message: nil, failed: false) }
        }
    }

    private func finishTeardown(core finishing: MoonlightSessionCore, message: String?, failed: Bool) {
        guard core === finishing else { return }
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        finishing.controllers.stop()
        renderer.reset()
        if MoonlightSessionCore.current === finishing { MoonlightSessionCore.setCurrent(nil) }
        core = nil
        stopping = false
        setKeepAwake(false)
        if !phase.isTerminal {
            phase = failed ? .failed(message: message ?? "The connection failed.") : .ended(message: message)
        }
    }

    // MARK: Events from the core (main actor)

    func handleStage(_ name: String) {
        if !phase.isTerminal { phase = .connecting(stage: name) }
    }

    func handleStarted() {
        phase = .streaming
        statisticsTimer?.invalidate()
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickStatistics() }
        }
    }

    func handleFailure(core failing: MoonlightSessionCore, message: String) {
        finishTeardown(core: failing, message: message, failed: true)
    }

    func handleTermination(core ending: MoonlightSessionCore, code: Int32) {
        let message = Self.terminationMessage(code)
        finishTeardown(core: ending, message: message, failed: code != 0 && phase != .streaming)
    }

    func handleHDR(_ enabled: Bool) { isHDR = enabled }
    func handleConnectionStatus(poor: Bool) { connectionIsPoor = poor }
    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private func tickStatistics() {
        guard let core else { return }
        let sample = core.counters.tick()
        var stats = statistics
        stats.framesPerSecond = sample.framesPerSecond
        stats.receivedFrames = sample.received
        stats.droppedFrames = sample.dropped
        stats.averageHostLatencyMs = sample.averageHostLatencyMs
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        if LiGetEstimatedRttInfo(&rtt, &variance) {
            stats.roundTripMs = Int(rtt)
            stats.roundTripVarianceMs = Int(variance)
        }
        stats.pendingFrames = Int(LiGetPendingVideoFrames())
        stats.codec = renderer.codecName
        let size = renderer.videoSize
        stats.width = Int(size.width)
        stats.height = Int(size.height)
        stats.frameRate = settings.frameRate
        stats.bitrateKbps = bitrateKbps
        stats.hdr = isHDR
        statistics = stats
    }

    private func setKeepAwake(_ enabled: Bool, reason: String = "Orbit is streaming from your PC") {
        keepAwake?.release()
        keepAwake = enabled ? MoonlightKeepAwake(reason: reason) : nil
    }

    static func terminationMessage(_ code: Int32) -> String? {
        switch code {
        case 0: return nil
        case -100: return "No video arrived from the PC. Make sure UDP ports 47998–48000 reach it (firewall, router)."
        case -101: return "Video arrived but no frame could be decoded. Try H.264 or a lower resolution."
        case -102: return "The PC ended the session before it started."
        case -103: return "The PC is showing protected content that cannot be streamed."
        case -104: return "The PC could not convert video frames."
        default: return "The connection was lost (error \(code))."
        }
    }

    // MARK: Input (callable from any thread)

    nonisolated public var hostSupportsTouch: Bool { LiGetHostFeatureFlags() & UInt32(LI_FF_PEN_TOUCH_EVENTS) != 0 }

    nonisolated public func sendMouseMove(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        LiSendMouseMoveEvent(Int16(clamping: dx), Int16(clamping: dy))
    }

    nonisolated public func sendMousePosition(x: Int, y: Int, referenceWidth: Int, referenceHeight: Int) {
        LiSendMousePositionEvent(Int16(clamping: x), Int16(clamping: y), Int16(clamping: referenceWidth), Int16(clamping: referenceHeight))
    }

    nonisolated public func sendMouseButton(_ button: MoonlightMouseButton, pressed: Bool) {
        LiSendMouseButtonEvent(pressed ? 0x07 : 0x08, button.rawValue)
    }

    nonisolated public func click(_ button: MoonlightMouseButton) {
        LiSendMouseButtonEvent(0x07, button.rawValue)
        LiSendMouseButtonEvent(0x08, button.rawValue)
    }

    /// Scroll in high-resolution units: 120 is one wheel notch.
    nonisolated public func sendScroll(vertical: Int, horizontal: Int) {
        if vertical != 0 { LiSendHighResScrollEvent(Int16(clamping: vertical)) }
        if horizontal != 0 { LiSendHighResHScrollEvent(Int16(clamping: horizontal)) }
    }

    nonisolated public func sendKey(virtualKey: Int16, pressed: Bool, modifiers: MoonlightKeyModifiers = []) {
        // 0x80 in the high byte tells the host the code is already a Windows VK code.
        let code = Int16(bitPattern: 0x8000 | UInt16(bitPattern: virtualKey))
        LiSendKeyboardEvent(code, pressed ? 0x03 : 0x04, CChar(bitPattern: modifiers.rawValue))
    }

    nonisolated public func tapKey(virtualKey: Int16, modifiers: MoonlightKeyModifiers = []) {
        sendKey(virtualKey: virtualKey, pressed: true, modifiers: modifiers)
        sendKey(virtualKey: virtualKey, pressed: false, modifiers: modifiers)
    }

    nonisolated public func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { _ = LiSendUtf8TextEvent($0, UInt32(buffer.count)) }
        }
    }

    nonisolated public func sendTouch(_ event: MoonlightTouchEvent, pointerID: UInt32, x: Float, y: Float, pressure: Float) {
        LiSendTouchEvent(event.rawValue, pointerID, x, y, pressure, 0, 0, UInt16(LI_ROT_UNKNOWN))
    }

    nonisolated public func requestKeyframe() { LiRequestIdrFrame() }
}

// MARK: - Keep awake

/// Keeps the screen on while a stream plays: the idle timer on iPhone, iPad and Apple TV, a display-sleep
/// power assertion on the Mac. Let go by `release()` or, as a safety net, when the hold itself goes away.
final class MoonlightKeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    #if os(macOS)
    private var assertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    #endif

    @MainActor
    init(reason: String) {
        #if os(macOS)
        var id = IOPMAssertionID(0)
        hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
        assertionID = id
        #else
        MoonlightIdleTimer.hold()
        #endif
    }

    /// Safe to call more than once and from any thread.
    func release() {
        lock.lock()
        let wasHeld = held
        held = false
        lock.unlock()
        guard wasHeld else { return }
        #if os(macOS)
        if hasAssertion { IOPMAssertionRelease(assertionID) }
        #else
        if Thread.isMainThread {
            MainActor.assumeIsolated { MoonlightIdleTimer.letGo() }
        } else {
            Task { @MainActor in MoonlightIdleTimer.letGo() }
        }
        #endif
    }

    #if os(macOS)
    /// For tests: whether the power assertion was granted and is still held.
    var holdsPowerAssertion: Bool {
        lock.lock(); defer { lock.unlock() }
        return held && hasAssertion
    }
    #endif

    deinit { release() }
}

#if os(iOS) || os(tvOS)
/// Counts the holds so a stream that ends late cannot turn the idle timer back on under a newer stream. The apps
/// take a hold of their own too (for example while waiting for the PC to finish a slow change), so that ending
/// it never lets the screen lock under a running stream. Every `hold()` needs exactly one `letGo()`.
@MainActor
public enum MoonlightIdleTimer {
    private static var holds = 0

    public static func hold() {
        holds += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    public static func letGo() {
        holds = max(0, holds - 1)
        if holds == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
#endif

// MARK: - Shared state reachable from the library's threads

/// Everything the C callbacks need. Registered as the single active core while a session runs.
final class MoonlightSessionCore: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var activeCore: MoonlightSessionCore?

    static var current: MoonlightSessionCore? {
        registryLock.lock(); defer { registryLock.unlock() }
        return activeCore
    }
    static func setCurrent(_ core: MoonlightSessionCore?) {
        registryLock.lock(); activeCore = core; registryLock.unlock()
    }

    weak var session: MoonlightStreamSession?
    let renderer: MoonlightVideoRenderer
    let audio = MoonlightAudioRenderer()
    let controllers = MoonlightControllerBridge()
    let counters = MoonlightFrameCounters()
    let box: MoonlightConnectionBox
    let framePacing: Bool
    /// No decoding, audio or controllers; frames are acknowledged and dropped.
    let headless: Bool
    /// The host's audio is received but not played here (headless sessions, `muteLocalAudio`).
    let silent: Bool
    private let lock = NSLock()
    private var renderThread: MoonlightRenderThread?
    private var failureMessage: String?

    init(session: MoonlightStreamSession, renderer: MoonlightVideoRenderer, box: MoonlightConnectionBox, framePacing: Bool, headless: Bool = false,
         silent: Bool = false) {
        self.session = session
        self.renderer = renderer
        self.box = box
        self.framePacing = framePacing
        self.headless = headless
        self.silent = headless || silent
    }

    private func onMain(_ body: @escaping @MainActor (MoonlightStreamSession) -> Void) {
        Task { @MainActor [weak self] in
            guard let session = self?.session else { return }
            body(session)
        }
    }

    // Video
    func rendererSetup(format: Int32, width: Int32, height: Int32, frameRate: Int32) -> Int32 {
        if !headless { renderer.setup(videoFormat: format, width: width, height: height, frameRate: frameRate, framePacing: framePacing) }
        counters.reset()
        return 0
    }
    func rendererStart() {
        lock.lock()
        renderThread?.stop()
        let thread = MoonlightRenderThread(renderer: headless ? nil : renderer, counters: counters)
        renderThread = thread
        lock.unlock()
        thread.start()
    }
    func rendererStop() {
        lock.lock()
        let thread = renderThread
        renderThread = nil
        lock.unlock()
        thread?.stop()
    }
    func rendererCleanup() { if !headless { renderer.reset() } }

    // Connection
    func stageStarting(_ stage: Int32) {
        let name = String(cString: LiGetStageName(stage))
        onMain { $0.handleStage(name) }
    }
    func stageFailed(_ stage: Int32, code: Int32) {
        let name = String(cString: LiGetStageName(stage))
        var message = "\(name) failed (error \(code))."
        let ports = LiGetPortFlagsFromStage(stage)
        if ports != 0 {
            var buffer = [CChar](repeating: 0, count: 256)
            LiStringifyPortFlags(ports, ", ", &buffer, Int32(buffer.count))
            let list = String(cString: buffer)
            if !list.isEmpty { message += " Check that these ports reach the PC: \(list)." }
        }
        lock.lock(); failureMessage = message; lock.unlock()
    }
    func startFinished(_ result: Int32) {
        guard result != 0 else { return }
        lock.lock(); let message = failureMessage ?? "Could not start the stream (error \(result))."; lock.unlock()
        LiStopConnection()
        onMain { [self] in $0.handleFailure(core: self, message: message) }
    }
    func connectionStarted() { onMain { $0.handleStarted() } }
    func connectionTerminated(_ code: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            LiStopConnection()
            onMain { $0.handleTermination(core: self, code: code) }
        }
    }
    func connectionStatus(_ status: Int32) { onMain { $0.handleConnectionStatus(poor: status == CONN_STATUS_POOR) } }
    func hdrChanged(_ enabled: Bool) {
        renderer.setHDR(enabled: enabled)
        onMain { $0.handleHDR(enabled) }
    }
    func log(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onMain { $0.appendLog(trimmed) }
    }
}

/// Keeps the C structures and strings alive for the whole connection.
final class MoonlightConnectionBox: @unchecked Sendable {
    var serverInfo = SERVER_INFORMATION()
    var streamConfig = STREAM_CONFIGURATION()
    var connectionCallbacks = CONNECTION_LISTENER_CALLBACKS()
    var videoCallbacks = DECODER_RENDERER_CALLBACKS()
    var audioCallbacks = AUDIO_RENDERER_CALLBACKS()
    private var strings: [UnsafeMutablePointer<CChar>] = []

    func retain(_ string: String) -> UnsafePointer<CChar>? {
        guard let copy = strdup(string) else { return nil }
        strings.append(copy)
        return UnsafePointer(copy)
    }

    deinit { strings.forEach { free($0) } }
}

/// Pulls decoded units from the library and hands them to the renderer.
final class MoonlightRenderThread: Thread {
    /// nil in headless sessions: frames are completed as "rendered" and dropped.
    private let renderer: MoonlightVideoRenderer?
    private let counters: MoonlightFrameCounters
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var running = true

    init(renderer: MoonlightVideoRenderer?, counters: MoonlightFrameCounters) {
        self.renderer = renderer
        self.counters = counters
        super.init()
        name = "Orbit Moonlight Render"
        qualityOfService = .userInteractive
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    override func main() {
        while isRunning {
            var handle: VIDEO_FRAME_HANDLE?
            var unit: PDECODE_UNIT?
            guard LiWaitForNextVideoFrame(&handle, &unit) else {
                usleep(2000)
                continue
            }
            guard let unit else {
                LiCompleteVideoFrame(handle, -1)
                continue
            }
            counters.record(unit.pointee)
            LiCompleteVideoFrame(handle, renderer?.submit(unit) ?? 0)
        }
        completion.signal()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        LiWakeWaitForVideoFrame()
        _ = completion.wait(timeout: .now() + 1)
    }
}

/// Frame bookkeeping shared between the render thread and the statistics timer.
final class MoonlightFrameCounters: @unchecked Sendable {
    struct Sample { var framesPerSecond: Int; var received: Int; var dropped: Int; var averageHostLatencyMs: Double? }

    private let lock = NSLock()
    private var lastFrameNumber: Int32 = 0
    private var received = 0
    private var dropped = 0
    private var framesSinceTick = 0
    private var latencySum = 0.0
    private var latencyCount = 0

    func reset() {
        lock.lock()
        lastFrameNumber = 0; received = 0; dropped = 0; framesSinceTick = 0; latencySum = 0; latencyCount = 0
        lock.unlock()
    }

    func record(_ unit: DECODE_UNIT) {
        lock.lock()
        if lastFrameNumber != 0, unit.frameNumber > lastFrameNumber + 1 { dropped += Int(unit.frameNumber - lastFrameNumber - 1) }
        lastFrameNumber = unit.frameNumber
        received += 1
        framesSinceTick += 1
        if unit.frameHostProcessingLatency != 0 {
            latencySum += Double(unit.frameHostProcessingLatency) / 10 // tenths of a millisecond
            latencyCount += 1
        }
        lock.unlock()
    }

    func tick() -> Sample {
        lock.lock(); defer { lock.unlock() }
        let sample = Sample(framesPerSecond: framesSinceTick, received: received, dropped: dropped,
                            averageHostLatencyMs: latencyCount > 0 ? latencySum / Double(latencyCount) : nil)
        framesSinceTick = 0
        latencySum = 0
        latencyCount = 0
        return sample
    }
}
