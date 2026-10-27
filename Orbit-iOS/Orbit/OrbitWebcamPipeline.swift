import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

// iPhone as a PC webcam (DESIGN F10): the parts that need no camera, screen or network. The PC's
// webcam JSON, the camera socket's text messages and the frame pipeline (JPEG encoding with at most
// one frame on its way). `Tests/check_webcam_contract.py` compiles this file on its own against the
// real agent (`orbit_webcam.py`), so keep it free of UIKit, AVFoundation and other app types.

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
    struct Stats { var frames = 0; var bytes = 0; var dropped = 0; var failed = 0 }

    private let lock = NSLock()
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

    /// Whether the last frame was encoded by VideoToolbox (false after it fell back to Core Image).
    var usesHardwareEncoder: Bool {
        lock.lock(); defer { lock.unlock() }; return hardwareEncoder
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
        let token = epoch
        let (width, height, quality) = (self.width, self.height, self.quality)
        lock.unlock()

        let encoded = encoder.encode(buffer, width: width, height: height, quality: quality)
        let hardware = encoder.usesVideoToolbox
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

/// Turns camera frames into JPEG images of exactly the size the PC expects (16:9). Frames of another
/// shape (the device held upright, or a smaller capture while it is hot) are scaled to fit on black.
/// Encodes with VideoToolbox (the hardware JPEG encoder on iPhone and iPad); falls back to Core Image
/// when VideoToolbox can't. Used from one queue at a time.
final class OrbitWebcamJPEGEncoder {
    private(set) var usesVideoToolbox = true
    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var sessionQuality = -1.0
    private var videoToolboxFailures = 0
    private var frameNumber: Int64 = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    deinit { invalidateSession() }

    func encode(_ buffer: CVPixelBuffer, width: Int, height: Int, quality: Double) -> Data? {
        let frame: CVPixelBuffer
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height {
            frame = buffer
        } else {
            guard let fitted = fit(buffer, width: width, height: height) else { return nil }
            frame = fitted
        }
        if usesVideoToolbox {
            if let data = encodeWithVideoToolbox(frame, width: width, height: height, quality: quality), Self.isJPEG(data) {
                videoToolboxFailures = 0
                return data
            }
            videoToolboxFailures += 1
            if videoToolboxFailures >= 3 {
                usesVideoToolbox = false
                invalidateSession()
            }
        }
        return encodeWithCoreImage(frame, quality: quality)
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
                // No JPEG encoder here (the Simulator): that won't change, so use Core Image from now on.
                #if DEBUG
                print("webcam: VideoToolbox JPEG session unavailable (\(status)); using Core Image")
                #endif
                videoToolboxFailures = 3
                return nil
            }
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
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

    private func encodeWithCoreImage(_ buffer: CVPixelBuffer, quality: Double) -> Data? {
        let option = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace, options: [option: quality])
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
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
        let y = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
        let picture = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        let composed = picture.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        context.render(composed, to: target, bounds: canvas, colorSpace: colorSpace)
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
