import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

// iPhone as a PC webcam (DESIGN F10): the parts that need no camera, screen or network. The PC's
// webcam JSON, the camera socket's text messages, the screen's decisions (what keeps Start disabled, the
// setup and removal on the PC, reconnecting) and the frame pipeline (JPEG encoding with at most one frame
// on its way). `Tests/check_webcam_contract.py` compiles this file on its own against the real agent
// (`orbit_webcam.py`), so keep it free of UIKit, AVFoundation and other app types.

// MARK: - PC API

/// `GET /api/webcam`, and the body of `POST /api/webcam/install|uninstall` (the same fields plus
/// `status` and, for a removal, `filesLeft`). Every field is optional so a newer or older agent still
/// decodes.
struct OrbitWebcamPCStatus: Decodable, Equatable {
    struct Runtime: Decodable, Equatable {
        var ok: Bool?
        var required: String?
        var x64: String?
        var x86: String?
        var missing: [String]?
        var commands: [String]?
    }

    struct Limits: Decodable, Equatable {
        var minWidth: Int?
        var minHeight: Int?
        var maxWidth: Int?
        var maxHeight: Int?
        var minFPS: Int?
        var maxFPS: Int?
        var maxFrameBytes: Int?
    }

    var installed: Bool?
    var registered: Bool?
    var active: Bool?
    var clients: Int?
    var width: Int?
    var height: Int?
    var fps: Int?
    var reason: String?
    var connected: Bool?
    var installing: Bool?
    var uninstalling: Bool?
    var installStage: String?
    var installError: String?
    var runtime: Runtime?
    var cameraName: String?
    var softcamVersion: String?
    var limits: Limits?
    /// Only in install/uninstall replies.
    var status: String?
    var filesLeft: Bool?

    var isSetUp: Bool { installed == true && registered == true }
    /// Set up, nothing running, nothing in the way: a phone may stream.
    var isReady: Bool { isSetUp && reason == nil && !isBusy }
    var isBusy: Bool { installing == true || uninstalling == true }
    var runtimeMissing: Bool { runtime?.ok == false }
    /// The PC can't run the webcam at all (Windows on ARM): the agent then skips the runtime check
    /// (`runtime` is null) and says why in `reason`. Setup would only fail, so it isn't offered.
    var isUnsupportedPC: Bool { runtime == nil && installed != true && reason?.isEmpty == false }

    /// Whether the PC accepts this camera format (`limits`; the agent refuses others with badHello).
    func accepts(width: Int, height: Int, fps: Int) -> Bool {
        guard let limits else { return true }
        if let maxWidth = limits.maxWidth, width > maxWidth { return false }
        if let maxHeight = limits.maxHeight, height > maxHeight { return false }
        if let maxFPS = limits.maxFPS, fps > maxFPS { return false }
        if let minFPS = limits.minFPS, fps < minFPS { return false }
        return true
    }

    static let demo = OrbitWebcamPCStatus(installed: true, registered: true, active: false, clients: 0, width: 1280, height: 720, fps: 30,
                                          reason: nil, connected: false, installing: false, uninstalling: false, installStage: nil,
                                          installError: nil, runtime: Runtime(ok: true, required: "14.44", x64: "14.44.35211", x86: "14.44.35211", missing: [], commands: []),
                                          cameraName: "DirectShow Softcam", softcamVersion: "1.8.1", limits: nil, status: nil, filesLeft: nil)
}

/// The camera format announced in the hello (`{"width":1280,"height":720,"fps":30}`).
struct OrbitWebcamFormat: Equatable, Codable {
    var width: Int
    var height: Int
    var fps: Int

    /// What the hello announces for the chosen size and rate: exactly that when the PC accepts it (its
    /// `limits`), otherwise 720p at the nearest rate the PC takes.
    static func announced(width: Int, height: Int, fps: Int, status: OrbitWebcamPCStatus?) -> OrbitWebcamFormat {
        guard let status, !status.accepts(width: width, height: height, fps: fps) else {
            return OrbitWebcamFormat(width: width, height: height, fps: fps)
        }
        var rate = min(fps, status.limits?.maxFPS ?? 30)
        if let minFPS = status.limits?.minFPS { rate = max(rate, minFPS) }
        return OrbitWebcamFormat(width: 1280, height: 720, fps: rate)
    }
}

// MARK: - Camera socket messages

/// A text message from the PC on `WS /ws/camera`.
enum OrbitWebcamMessage: Equatable {
    /// The PC created its camera (`{"ready":true,"width":…,"height":…,"fps":…,"cameraName":…}`).
    case ready(width: Int, height: Int, fps: Int, cameraName: String?)
    /// Whether an app on the PC opened the camera (`{"connected":bool}`, on change and every 5 s).
    case connected(Bool)
    /// Why the PC is about to close the socket (`{"error":"<sentence>","code":"<code>"}`).
    case failure(code: String, message: String)
    case other

    static func parse(_ text: String) -> OrbitWebcamMessage {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .other }
        if let error = object["error"] as? String {
            return .failure(code: object["code"] as? String ?? "", message: error)
        }
        if object["ready"] as? Bool == true {
            return .ready(width: object["width"] as? Int ?? 0, height: object["height"] as? Int ?? 0,
                          fps: object["fps"] as? Int ?? 0, cameraName: object["cameraName"] as? String)
        }
        if let connected = object["connected"] as? Bool { return .connected(connected) }
        return .other
    }
}

/// Why the camera stream ended, in plain words.
struct OrbitWebcamStreamEnd: Error, Equatable {
    let message: String
    /// The PC said why (its `error`/`code` message) or refused the connection: don't reconnect on our own.
    let fromPC: Bool
    var code: String? = nil

    /// A connection that ended without the PC saying why.
    /// - handshakeStatus: the HTTP status of the WebSocket handshake (101 once accepted; nil when the PC
    ///   never answered).
    /// - pinFailure: why the certificate pin refused the PC (that counts as the PC refusing).
    /// - ready: the PC got as far as `{"ready":true}`.
    /// - cancelled: the task was cancelled (Orbit closed it because the PC went silent).
    static func lost(pcName: String, handshakeStatus: Int?, pinFailure: String?, ready: Bool, cancelled: Bool) -> OrbitWebcamStreamEnd {
        let refused = !ready && ((handshakeStatus ?? 0) >= 400 || pinFailure != nil)
        return OrbitWebcamStreamEnd(message: describe(pcName: pcName, handshakeStatus: handshakeStatus, pinFailure: pinFailure,
                                                      ready: ready, cancelled: cancelled),
                                    fromPC: refused)
    }

    private static func describe(pcName: String, handshakeStatus: Int?, pinFailure: String?, ready: Bool, cancelled: Bool) -> String {
        if let pinFailure { return pinFailure }
        switch handshakeStatus {
        case 401, 403: return "\(pcName) refused the camera connection. Pair the PC again in My PCs."
        case 404: return "The agent on \(pcName) doesn't have the webcam yet. Update Orbit PC Companion."
        case 426: return "The webcam needs Orbit's encrypted connection. Pair \(pcName) again in My PCs."
        case let status? where status >= 400:
            return "\(pcName) refused the camera connection (error \(status)). Try again, or restart Orbit PC Companion on the PC."
        default: break
        }
        if !ready {
            // No WebSocket handshake at all: the PC didn't answer (asleep, another network, firewall).
            guard handshakeStatus == 101 else {
                return "Couldn't reach \(pcName). Check that the PC is awake, on the same network, and that Orbit PC Companion is running."
            }
            if cancelled { return "\(pcName) didn't get the camera ready in time. Try again." }
            return "\(pcName) closed the camera connection before it was ready. Try again, or restart Orbit PC Companion on the PC."
        }
        return "Lost the connection to \(pcName). Check that the PC is awake and on the same network."
    }

    /// The PC's own reason (`{"error":…,"code":…}`, sent right before it closes): never reconnected on our own.
    static func said(_ message: OrbitWebcamMessage) -> OrbitWebcamStreamEnd? {
        guard case .failure(let code, let sentence) = message else { return nil }
        return OrbitWebcamStreamEnd(message: sentence, fromPC: true, code: code)
    }

    static func keepsDropping(pcName: String) -> String {
        "The connection to \(pcName) keeps dropping. Try again, or restart Orbit PC Companion on the PC."
    }
}

// MARK: - Decisions

/// What the webcam screen knows right now, as plain values (`OrbitWebcamModel` fills it in).
struct OrbitWebcamSituation: Equatable {
    var isDemo = false
    var pcName = "your PC"
    /// "iPhone" or "iPad".
    var device = "iPhone"
    /// A PC is selected.
    var hasPC = true
    /// The PC is paired with the certificate-pinned connection the camera needs.
    var hasSecureLink = true
    /// Orbit reaches the PC (its status polls answer).
    var isOnline = true
    /// The webcam's own requests got no answer from the PC's local-network address, the only one the
    /// camera uses (never a secondary, VPN address), although Orbit reaches the PC.
    var localNetworkUnreachable = false
    var featuresKnown = false
    var featuresFailed = false
    /// `GET /api/capabilities` lists "webcam" (an older agent answers 404 and has none).
    var supportsWebcam = false
    /// Camera permission and a camera (or the Debug test source).
    var canUseCamera = true
    /// The camera's own failure sentence.
    var cameraFailure: String? = nil
    var setupRunning = false
    var status: OrbitWebcamPCStatus? = nil
    var statusFailed = false
}

enum OrbitWebcamReadiness {
    struct Problem: Equatable {
        var title: String
        var message: String
        var icon: String
    }

    /// What keeps a real PC from being used now (nil when nothing does; demo mode never has one).
    static func pcProblem(_ s: OrbitWebcamSituation) -> Problem? {
        if s.isDemo { return nil }
        if !s.hasPC {
            return Problem(title: "Pair a PC first", message: "Find and pair your Windows PC in My PCs, then come back to use this \(s.device) as its webcam.",
                           icon: "desktopcomputer")
        }
        if !s.hasSecureLink {
            return Problem(title: "Needs the encrypted connection", message: "Pair \(s.pcName) again in My PCs. The camera only travels over Orbit's encrypted connection.",
                           icon: "lock.trianglebadge.exclamationmark")
        }
        if !s.isOnline {
            return Problem(title: "\(s.pcName) is offline", message: "Wake the PC or check that Orbit PC Companion is running, then try again.", icon: "wifi.slash")
        }
        if s.featuresKnown && !s.supportsWebcam {
            return Problem(title: "Update Orbit PC Companion",
                           message: "The agent on \(s.pcName) doesn't have the webcam yet. Update it from Settings › Check for PC Companion Update, then come back.",
                           icon: "arrow.down.circle.fill")
        }
        if s.localNetworkUnreachable {
            return Problem(title: "Can't reach \(s.pcName) on this network",
                           message: "The webcam works over your local network only. Check that this \(s.device) is on the same Wi-Fi network as \(s.pcName) and that Orbit PC Companion is running there.",
                           icon: "wifi.exclamationmark")
        }
        return nil
    }

    /// Why Start can't be used now (nil when it can).
    static func startBlocker(_ s: OrbitWebcamSituation) -> String? {
        if !s.canUseCamera { return "Allow camera access first." }
        if let failure = s.cameraFailure { return failure }
        if s.isDemo { return nil }
        if let problem = pcProblem(s) { return problem.title + "." }
        if !s.featuresKnown { return s.featuresFailed ? "Couldn't reach \(s.pcName)." : "Checking what \(s.pcName) can do…" }
        if s.setupRunning || s.status?.isBusy == true { return "Wait for the setup on \(s.pcName) to finish." }
        guard let status = s.status else {
            return s.statusFailed ? "Couldn't read the webcam status of \(s.pcName)." : "Reading the webcam status of \(s.pcName)…"
        }
        if status.isUnsupportedPC { return "\(s.pcName) can't run the webcam." }
        if !status.isSetUp { return "Set up the webcam on \(s.pcName) first." }
        return nil
    }
}

/// The setup and removal on the PC (`POST /api/webcam/install|uninstall`, then status polls) as plain
/// decisions: what the screen says, whether the polls still decide how it ends, and whether webcam
/// files may be left on the PC (then "Remove" stays offered). `OrbitWebcamModel` feeds it the PC's answers.
struct OrbitWebcamSetupFlow: Equatable {
    enum Operation: Equatable { case install, remove }
    /// How an operation ended (the model plays the matching haptic).
    enum Ending: Equatable { case success, failure, quiet }

    private(set) var operation: Operation?
    /// The request came back with 202 (the Windows prompt is still open) or its answer got lost, so the
    /// status polls decide how it ends. Until then a poll must not end it: it may land before the PC
    /// even started.
    private(set) var awaitsPoll = false
    private(set) var message: String?
    private(set) var error: String?
    /// What the last ending said about leftover webcam files (nil: nothing). After any phone streamed,
    /// Orbit PC Companion itself keeps a webcam file loaded, so a removal often leaves one behind.
    private(set) var filesMayBeLeft: Bool?
    private var wasSetUp = false

    var isRunning: Bool { operation != nil }

    /// Starts one (false while one runs). `current` is what the PC said before it.
    mutating func begin(_ operation: Operation, current: OrbitWebcamPCStatus?) -> Bool {
        guard self.operation == nil else { return false }
        self = OrbitWebcamSetupFlow()
        self.operation = operation
        wasSetUp = current?.isSetUp == true
        return true
    }

    /// The PC or the connection changed: forget it.
    mutating func reset() { self = OrbitWebcamSetupFlow() }

    /// The answer to the request: 200 (finished) or 202 (the Windows prompt is still open).
    mutating func answered(_ reply: OrbitWebcamPCStatus, pcName: String, cameraName: String) -> Ending? {
        guard let operation else { return nil }
        if reply.status == "waitingForApproval" || (reply.status == nil && reply.isBusy) {
            awaitsPoll = true
            return nil
        }
        switch operation {
        case .install:
            if reply.status == "alreadyInstalled" {
                return finish(message: "The webcam was already set up on \(pcName).", filesLeft: false)
            }
            if reply.status == "installed" || reply.isSetUp {
                return finish(message: Self.setUp(pcName, reply.cameraName ?? cameraName), filesLeft: false)
            }
            return finish(error: reply.installError ?? "The setup on \(pcName) didn't finish. Try again.")
        case .remove:
            if reply.status == "notInstalled" {
                // Removal is also offered after a removal that may have left files: none were left.
                let message = wasSetUp ? "The webcam wasn't set up on \(pcName), so there was nothing to remove."
                                       : "Nothing of the webcam is left on \(pcName)."
                return finish(message: message, filesLeft: false, ending: .quiet)
            }
            if reply.isSetUp && reply.status != "uninstalled" {
                return finish(error: Self.stillListed(pcName))
            }
            switch reply.filesLeft {
            case true?:
                return finish(message: "The webcam was removed from \(pcName). Some of its files are still in use: restart the PC, then remove the webcam again to delete them.",
                              filesLeft: true)
            case false?:
                return finish(message: "The webcam was removed from \(pcName).", filesLeft: false)
            case nil:
                return finish(message: Self.removedMaybeFilesLeft(pcName), filesLeft: true)
            }
        }
    }

    /// The PC refused with its own sentence (the HTTP error's detail: the Windows prompt was declined,
    /// the Visual C++ runtime is missing with the winget commands, Windows on ARM, nobody signed in, …).
    mutating func refused(_ sentence: String) -> Ending? {
        guard operation != nil else { return nil }
        return finish(error: sentence)
    }

    /// The answer got lost on the way (Wi-Fi, a timeout). `status` is what the PC says now (nil when that
    /// couldn't be read either): the operation may still run there, or have finished.
    mutating func answerLost(_ reason: String, status: OrbitWebcamPCStatus?, pcName: String, cameraName: String) -> Ending? {
        guard let operation else { return nil }
        if let status {
            if status.isBusy {
                awaitsPoll = true
                return nil
            }
            if let failure = status.installError, !failure.isEmpty { return finish(error: failure) }
            if operation == .install, status.isSetUp {
                return finish(message: Self.setUp(pcName, status.cameraName ?? cameraName), filesLeft: false)
            }
            if operation == .remove, wasSetUp, !status.isSetUp {
                return finish(message: Self.removedMaybeFilesLeft(pcName), filesLeft: true)
            }
        }
        return finish(error: (operation == .install ? "Couldn't set up the webcam. " : "Couldn't remove the webcam. ") + reason)
    }

    /// A status poll while the operation runs: ends it once the PC finished (after a 202 or a lost answer).
    mutating func polled(_ status: OrbitWebcamPCStatus, pcName: String, cameraName: String) -> Ending? {
        guard let operation, awaitsPoll, !status.isBusy else { return nil }
        if let failure = status.installError, !failure.isEmpty { return finish(error: failure) }
        switch operation {
        case .install:
            if status.isSetUp { return finish(message: Self.setUp(pcName, status.cameraName ?? cameraName), filesLeft: false) }
            return finish(error: "The setup on \(pcName) didn't finish. Try again.")
        case .remove:
            if status.isSetUp { return finish(error: Self.stillListed(pcName)) }
            // GET /api/webcam doesn't say whether files were left behind.
            return finish(message: Self.removedMaybeFilesLeft(pcName), filesLeft: true)
        }
    }

    private mutating func finish(message: String? = nil, error: String? = nil, filesLeft: Bool? = nil, ending: Ending? = nil) -> Ending {
        operation = nil
        awaitsPoll = false
        self.message = message
        self.error = error
        filesMayBeLeft = filesLeft
        return ending ?? (error == nil ? .success : .failure)
    }

    private static func setUp(_ pcName: String, _ cameraName: String) -> String {
        "The webcam is set up on \(pcName). Apps that were already open need a restart to find the \"\(cameraName)\" camera."
    }

    private static func stillListed(_ pcName: String) -> String {
        "Windows still lists the webcam on \(pcName). Try removing it again."
    }

    private static func removedMaybeFilesLeft(_ pcName: String) -> String {
        "The webcam was removed from \(pcName). If an app on the PC or Orbit PC Companion still had the camera loaded, restart the PC and remove the webcam again to delete its last files."
    }
}

/// When the camera connection ends without being closed on purpose: connect again (how soon) or stop.
/// The PC keeps its camera for 5 s after a phone drops, so apps on the PC barely notice a quick reconnect.
struct OrbitWebcamReconnectPolicy: Equatable {
    static let delays: [Double] = [0.5, 1.5, 3, 5]
    /// A connection that streamed at least this long earns a fresh set of quick retries (a long call may
    /// see several short Wi-Fi drops); shorter ones keep using them up.
    static let stableSeconds: Double = 10
    /// This many connections that ended after "ready" within `dropWindow` seconds stop streaming: a PC
    /// that takes the camera and drops it again at once would otherwise be reconnected to forever.
    static let maxDrops = 5
    static let dropWindow: Double = 60
    /// After this many retries, a PC that Orbit can't reach at all went to sleep or left the network:
    /// stop instead of showing "Reconnecting…" for another minute.
    static let offlineAfter = 2

    enum Decision: Equatable {
        /// Wait `delay` seconds, then connect again; `attempt` counts the retries in a row (1, 2, …).
        case reconnect(delay: Double, attempt: Int)
        case stop(Stop)
    }

    enum Stop: Equatable {
        /// The PC refused or said why: show its sentence.
        case pcSaidWhy
        case leftScreen
        case keepsDropping
        /// The quick retries are used up: show why the last connection ended.
        case gaveUp
        /// Orbit can't reach the PC at all.
        case offline
    }

    private(set) var retriesInARow = 0
    private(set) var dropTimes: [Double] = []

    /// - streamedFor: seconds between "ready" and the end (nil when the PC never got that far).
    /// - now: seconds on any steady clock.
    mutating func ended(fromPC: Bool, streamedFor: Double?, isOnline: Bool, isVisible: Bool, now: Double) -> Decision {
        if fromPC { return .stop(.pcSaidWhy) }
        if !isVisible { return .stop(.leftScreen) }
        if let streamedFor {
            dropTimes = dropTimes.filter { now - $0 < Self.dropWindow } + [now]
            if dropTimes.count >= Self.maxDrops { return .stop(.keepsDropping) }
            if streamedFor >= Self.stableSeconds { retriesInARow = 0 }
        }
        guard retriesInARow < Self.delays.count else { return .stop(.gaveUp) }
        if !isOnline && retriesInARow >= Self.offlineAfter { return .stop(.offline) }
        let delay = Self.delays[retriesInARow]
        retriesInARow += 1
        return .reconnect(delay: delay, attempt: retriesInARow)
    }
}

// MARK: - Frame pipeline

/// Where encoded frames go: the camera socket, or nowhere in demo mode.
protocol OrbitWebcamFrameSink: AnyObject {
    func send(_ jpeg: Data, completion: @escaping (Error?) -> Void)
}

/// Demo mode: frames are encoded (so the numbers are real) and dropped.
final class OrbitWebcamDiscardSink: OrbitWebcamFrameSink {
    func send(_ jpeg: Data, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async { completion(nil) }
    }
}

/// Camera frames → JPEG → sink, with at most one frame on its way: a frame that arrives while the
/// previous one is still being encoded or sent is dropped, so a slow network never builds a queue
/// (and a delay) behind it. Called on the camera's video queue.
final class OrbitWebcamPipeline: @unchecked Sendable {
    struct Stats {
        var frames = 0
        var bytes = 0
        var dropped = 0
        var failed = 0
        /// Whether the last frame taken was portrait (the device held upright), nil when none was taken.
        var portrait: Bool?
    }

    private let lock = NSLock()
    /// Held while the encoder works, so a reset from another thread waits for the frame in progress.
    private let encoderLock = NSLock()
    private let encoder = OrbitWebcamJPEGEncoder()
    private var sink: OrbitWebcamFrameSink?
    private var epoch = 0
    private var inFlight = false
    private var width = 1280
    private var height = 720
    private var fps = 30
    private var quality = 0.6
    private var lastFrameTime: CMTime?
    private var stats = Stats()
    private var hardwareEncoder = true

    static let bestQuality = 0.6
    static let lowestQuality = 0.35

    /// Starts (or stops, with nil) sending to `sink`. A frame still on its way to an old sink no
    /// longer counts.
    func setSink(_ sink: OrbitWebcamFrameSink?) {
        lock.lock()
        self.sink = sink
        epoch &+= 1
        inFlight = false
        lastFrameTime = nil
        lock.unlock()
    }

    /// The size and rate of the JPEGs (the hello's format, or less while the device is hot).
    func setFrameFormat(width: Int, height: Int, fps: Int) {
        lock.lock(); self.width = width; self.height = height; self.fps = max(1, fps); lock.unlock()
    }

    var currentQuality: Double {
        get { lock.lock(); defer { lock.unlock() }; return quality }
        set { lock.lock(); quality = min(Self.bestQuality, max(Self.lowestQuality, newValue)); lock.unlock() }
    }

    /// Whether VideoToolbox encodes the frames (false after it fell back to Core Image).
    var usesHardwareEncoder: Bool {
        lock.lock(); defer { lock.unlock() }; return hardwareEncoder
    }

    /// Back to VideoToolbox with a fresh session (streaming stopped, or Orbit is in the foreground again:
    /// iOS may have invalidated the hardware session meanwhile). Waits for a frame being encoded.
    func resetEncoder() {
        encoderLock.lock()
        encoder.reset()
        encoderLock.unlock()
        lock.lock(); hardwareEncoder = true; lock.unlock()
    }

    #if DEBUG
    private var debugSeen = 0
    private var debugEncoded = 0
    var debugState: String {
        lock.lock(); defer { lock.unlock() }
        return "seen \(debugSeen) encoded \(debugEncoded) inFlight \(inFlight) sink \(sink != nil) \(width)x\(height)@\(fps)"
    }
    #endif

    /// Counters since the last call.
    func takeStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        let result = stats
        stats = Stats()
        return result
    }

    func handle(_ buffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        #if DEBUG
        debugSeen += 1
        #endif
        guard let sink else { lock.unlock(); return }
        if inFlight {
            stats.dropped += 1
            lock.unlock()
            return
        }
        // Keep to the announced frame rate even if the camera delivers more.
        if let last = lastFrameTime, time.isValid, last.isValid,
           CMTimeGetSeconds(CMTimeSubtract(time, last)) < 0.8 / Double(fps) {
            lock.unlock()
            return
        }
        inFlight = true
        lastFrameTime = time
        stats.portrait = CVPixelBufferGetHeight(buffer) > CVPixelBufferGetWidth(buffer)
        let token = epoch
        let (width, height, quality) = (self.width, self.height, self.quality)
        lock.unlock()

        encoderLock.lock()
        let encoded = encoder.encode(buffer, width: width, height: height, quality: quality)
        let hardware = encoder.usesVideoToolbox
        encoderLock.unlock()
        lock.lock(); hardwareEncoder = hardware; lock.unlock()
        guard let jpeg = encoded else {
            lock.lock()
            if token == epoch { inFlight = false; stats.failed += 1 }
            lock.unlock()
            return
        }
        #if DEBUG
        lock.lock(); debugEncoded += 1; lock.unlock()
        #endif
        sink.send(jpeg) { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            if token == self.epoch {
                self.inFlight = false
                if error == nil {
                    self.stats.frames += 1
                    self.stats.bytes += jpeg.count
                } else {
                    self.stats.failed += 1
                }
            }
            self.lock.unlock()
        }
    }
}

// MARK: - JPEG encoding

/// When VideoToolbox's JPEG encoder is used. A frame it fails goes to Core Image, and the next frame gets
/// a fresh session (iOS can invalidate hardware sessions, for example after Orbit was in the background,
/// or when media services reset). Only when fresh sessions keep failing does Core Image take over, until
/// the next reset (each stream starts with VideoToolbox again).
struct OrbitWebcamEncoderHealth: Equatable {
    /// Failed frames in a row (the first session and two fresh ones) before Core Image takes over.
    static let failuresBeforeFallback = 3
    private(set) var usesVideoToolbox: Bool
    private(set) var failuresInARow = 0

    init(usesVideoToolbox: Bool = true) { self.usesVideoToolbox = usesVideoToolbox }

    mutating func encoded() { failuresInARow = 0 }

    mutating func failed() {
        failuresInARow += 1
        if failuresInARow >= Self.failuresBeforeFallback { usesVideoToolbox = false }
    }

    mutating func reset() { self = OrbitWebcamEncoderHealth() }
}

/// Turns camera frames into JPEG images of exactly the size the PC expects (16:9). Frames of another
/// shape (the device held upright, or a smaller capture while it is hot) are scaled to fit on black.
/// Encodes with VideoToolbox (the hardware JPEG encoder on iPhone and iPad); falls back to Core Image
/// when VideoToolbox can't. Takes the camera's 4:2:0 YCbCr frames as they are, and BGRA. Used from one
/// thread at a time.
///
/// Colours: every JPEG decoder (Pillow on the PC included) reads JPEG as BT.601 YCbCr. VideoToolbox
/// converts to that only for a buffer that says which matrix it uses, and only when the session asks for
/// BT.601; otherwise it wrote BT.709 values (pure red arrived as 232, 0, 3). Core Image reads frames as
/// sRGB, so it keeps the camera's tones like VideoToolbox does (left alone, it brightened mid-grey from
/// 128 to 139 for BT.709-tagged camera frames).
final class OrbitWebcamJPEGEncoder {
    private(set) var health: OrbitWebcamEncoderHealth
    var usesVideoToolbox: Bool { health.usesVideoToolbox }
    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var sessionQuality = -1.0
    private var frameNumber: Int64 = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    /// `videoToolbox: false` starts with Core Image (tests); `reset()` goes back to VideoToolbox.
    init(videoToolbox: Bool = true) {
        health = OrbitWebcamEncoderHealth(usesVideoToolbox: videoToolbox)
    }

    deinit { invalidateSession() }

    func encode(_ buffer: CVPixelBuffer, width: Int, height: Int, quality: Double) -> Data? {
        let frame: CVPixelBuffer
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height {
            frame = buffer
        } else {
            guard let fitted = fit(buffer, width: width, height: height) else { return nil }
            frame = fitted
        }
        if health.usesVideoToolbox {
            if let data = encodeWithVideoToolbox(frame, width: width, height: height, quality: quality), Self.isJPEG(data) {
                health.encoded()
                return data
            }
            // A dead session (kVTInvalidSessionErr after Orbit was in the background, a media services
            // reset) stays dead: the next frame gets a new one.
            invalidateSession()
            health.failed()
        }
        return encodeWithCoreImage(frame, quality: quality)
    }

    /// VideoToolbox again, with a new session for the next frame.
    func reset() {
        invalidateSession()
        health.reset()
    }

    /// The PC only accepts JPEG (`FF D8 FF`).
    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8 && data[data.startIndex + 2] == 0xFF
    }

    private func encodeWithVideoToolbox(_ buffer: CVPixelBuffer, width: Int, height: Int, quality: Double) -> Data? {
        if session == nil || sessionSize != (width, height) {
            invalidateSession()
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                    codecType: kCMVideoCodecType_JPEG, encoderSpecification: nil,
                                                    imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            guard status == noErr, let created else {
                // No JPEG encoder here (the Simulator), or none right now: Core Image takes this frame.
                #if DEBUG
                print("webcam: VideoToolbox JPEG session unavailable (\(status)); using Core Image")
                #endif
                return nil
            }
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            // JPEG's own matrix (see the type's note).
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            VTCompressionSessionPrepareToEncodeFrames(created)
            session = created
            sessionSize = (width, height)
            sessionQuality = -1
        }
        guard let session else { return nil }
        if abs(sessionQuality - quality) > 0.001 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: Float(quality)))
            sessionQuality = quality
        }
        Self.tagMatrixIfMissing(buffer)
        frameNumber += 1
        let output = OrbitWebcamEncodedFrame()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                                                     presentationTimeStamp: CMTime(value: frameNumber, timescale: 30),
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { return }
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            if copied == kCMBlockBufferNoErr { output.set(data) }
        }
        guard status == noErr else {
            #if DEBUG
            print("webcam: VideoToolbox JPEG encode failed (\(status))")
            #endif
            return nil
        }
        // JPEG frames don't depend on each other; waiting here keeps exactly one frame in the encoder.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return output.value
    }

    /// Camera frames say which YCbCr matrix they use; the fitted canvas and test frames may not.
    private static func tagMatrixIfMissing(_ buffer: CVPixelBuffer) {
        guard CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil else { return }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isYCbCr = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Untagged YCbCr video is BT.709 at HD sizes; RGB only needs a matrix to convert with.
        let matrix = isYCbCr && max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)) >= 1280
            ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }

    private func picture(_ buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
    }

    private func encodeWithCoreImage(_ buffer: CVPixelBuffer, quality: Double) -> Data? {
        let option = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: picture(buffer), colorSpace: colorSpace, options: [option: quality])
    }

    /// Scales the frame to fit `width` × `height`, centred on black.
    private func fit(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target) == kCVReturnSuccess, let target else { return nil }
        let source = picture(buffer)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
        let y = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
        let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        let composed = placed.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        context.render(composed, to: target, bounds: canvas, colorSpace: colorSpace)
        CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        return target
    }

    private func invalidateSession() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sessionSize = (0, 0)
    }
}

/// The JPEG VideoToolbox hands back (from its own thread).
private final class OrbitWebcamEncodedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var value: Data? { lock.lock(); defer { lock.unlock() }; return data }
}
