import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// Driven by check_webcam_contract.py: `OrbitWebcamTests <fixtures folder> <output folder>`.
// Covers Orbit/OrbitWebcamPipeline.swift (the iPhone webcam, DESIGN F10) without a PC, a camera or a
// simulator: the real agent's `/api/webcam` JSON and `WS /ws/camera` messages (fixtures written by the
// driver), the frame pipeline (one frame on its way, frame-rate cap, stale sinks, quality bounds) and
// the JPEG encoder. The hello and the JPEGs go to the output folder; the driver then hands them to
// the agent's own `parse_hello` and `jpeg_to_bgr`.

private struct SendFailed: Error {}

/// A sink that keeps each frame's completion until the test says the network delivered it.
private final class ManualSink: OrbitWebcamFrameSink {
    private(set) var sent: [Data] = []
    private var completions: [(Error?) -> Void] = []
    func send(_ jpeg: Data, completion: @escaping (Error?) -> Void) {
        sent.append(jpeg)
        completions.append(completion)
    }
    func deliverNext(_ error: Error? = nil) {
        precondition(!completions.isEmpty, "no frame on its way")
        completions.removeFirst()(error)
    }
    var waiting: Int { completions.count }
}

@main
private struct OrbitWebcamTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 3, "usage: OrbitWebcamTests <fixtures folder> <output folder>")
        let fixtures = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

        try decodesTheAgentStatus(fixtures)
        olderAndNewerAgentsStillDecode()
        try parsesTheAgentMessages(fixtures)
        try writesTheHello(output)
        pipelineSendsOneFrameAtATime()
        let encoder = try encodesJPEGs(output)
        print("PASS: webcam status/setup JSON from the agent (ready, Visual C++ runtime missing, waiting for the Windows prompt, Windows on ARM, install 200/202, uninstall), "
              + "older/newer agents, socket messages (ready, connected, badHello, replaced, notInstalled), at most one frame on its way, frame-rate cap, stale sinks, "
              + "quality bounds, JPEG via \(encoder)")
    }

    // MARK: PC JSON

    static func status(_ fixtures: URL, _ name: String) throws -> OrbitWebcamPCStatus {
        try JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    static func decodesTheAgentStatus(_ fixtures: URL) throws {
        let ready = try status(fixtures, "status-ready.json")
        precondition(ready.isSetUp && ready.isReady && !ready.isBusy && !ready.runtimeMissing, "set-up PC: \(ready)")
        precondition(ready.reason == nil && ready.cameraName == "DirectShow Softcam" && ready.softcamVersion != nil, "set-up PC: \(ready)")
        precondition(ready.width == 1280 && ready.height == 720 && ready.fps == 30 && ready.clients == 0 && ready.active == false, "format: \(ready)")
        precondition(ready.runtime?.ok == true && ready.runtime?.commands == [], "runtime: \(String(describing: ready.runtime))")
        // The app offers 720p/1080p at 30/15 fps: all of them must pass the PC's own limits.
        for (width, height) in [(1280, 720), (1920, 1080)] {
            for fps in [15, 30] { precondition(ready.accepts(width: width, height: height, fps: fps), "limits refuse \(width)x\(height)@\(fps)") }
        }
        precondition(!ready.accepts(width: 2560, height: 1440, fps: 30) && !ready.accepts(width: 1280, height: 720, fps: 60)
                     && !ready.accepts(width: 1280, height: 720, fps: 10), "limits: \(String(describing: ready.limits))")

        let runtime = try status(fixtures, "status-runtime.json")
        precondition(runtime.runtimeMissing && !runtime.isReady && !runtime.isSetUp, "runtime missing: \(runtime)")
        precondition(runtime.runtime?.missing == ["x86"] && runtime.runtime?.commands == ["winget install Microsoft.VCRedist.2015+.x86"],
                     "runtime commands: \(String(describing: runtime.runtime))")
        precondition(runtime.reason?.contains("winget install Microsoft.VCRedist.2015+.x86") == true, "runtime reason: \(String(describing: runtime.reason))")

        let waiting = try status(fixtures, "status-waiting.json")
        precondition(waiting.isBusy && waiting.installing == true && waiting.installStage == "waitingForApproval" && !waiting.isReady,
                     "waiting for the prompt: \(waiting)")
        precondition(waiting.reason?.isEmpty == false, "a busy PC explains itself")

        let arm = try status(fixtures, "status-arm.json")
        precondition(arm.installed == false && arm.runtime == nil && arm.reason?.contains("ARM") == true && !arm.isReady, "Windows on ARM: \(arm)")
        // Setup is offered everywhere except on a PC that can't run the webcam at all.
        precondition(arm.isUnsupportedPC && !ready.isUnsupportedPC && !runtime.isUnsupportedPC && !waiting.isUnsupportedPC,
                     "only Windows on ARM is unsupported")

        let installed = try status(fixtures, "install-200.json")
        precondition(installed.status == "installed" && installed.isSetUp && !installed.isBusy, "install 200: \(installed)")
        let pending = try status(fixtures, "install-202.json")
        precondition(pending.status == "waitingForApproval" && pending.isBusy && pending.installStage == "waitingForApproval", "install 202: \(pending)")
        let removed = try status(fixtures, "uninstall-200.json")
        precondition(removed.status == "uninstalled" && removed.filesLeft == false, "uninstall 200: \(removed)")
    }

    static func olderAndNewerAgentsStillDecode() {
        let older = try? JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(#"{"installed":true,"registered":true}"#.utf8))
        precondition(older?.isReady == true && older?.limits == nil && older?.accepts(width: 1920, height: 1080, fps: 30) == true, "older agent")
        let newer = try? JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(#"{"installed":false,"registered":false,"reason":"x","future":{"a":[1,2]},"limits":{"maxWidth":3840,"extra":1}}"#.utf8))
        precondition(newer?.isSetUp == false && newer?.limits?.maxWidth == 3840, "newer agent")
        let demo = OrbitWebcamPCStatus.demo
        precondition(demo.isReady && demo.runtime?.ok == true, "demo status")
    }

    // MARK: Socket messages

    static func parsesTheAgentMessages(_ fixtures: URL) throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("messages.json"))
        let messages = try JSONDecoder().decode([String: String].self, from: data)
        func parsed(_ name: String) -> OrbitWebcamMessage {
            guard let text = messages[name] else { preconditionFailure("the driver wrote no \(name) message") }
            return OrbitWebcamMessage.parse(text)
        }
        precondition(parsed("ready") == .ready(width: 1280, height: 720, fps: 30, cameraName: "DirectShow Softcam"), "ready: \(parsed("ready"))")
        precondition(parsed("connectedFalse") == .connected(false), "connected false: \(parsed("connectedFalse"))")
        precondition(parsed("connectedTrue") == .connected(true), "connected true: \(parsed("connectedTrue"))")
        for (name, code) in [("badHello", "badHello"), ("replaced", "replaced"), ("notInstalled", "notInstalled")] {
            guard case .failure(let found, let sentence) = parsed(name), found == code, sentence.count > 10 else {
                preconditionFailure("\(name): \(parsed(name))")
            }
        }
        if case .failure(_, let sentence) = parsed("replaced") {
            precondition(sentence == "Another device started using this PC's webcam.", "replaced sentence: \(sentence)")
        }
        precondition(OrbitWebcamMessage.parse("not json") == .other && OrbitWebcamMessage.parse(#"{"keyframe":true}"#) == .other
                     && OrbitWebcamMessage.parse("[1,2]") == .other, "unknown messages are ignored")
    }

    static func writesTheHello(_ output: URL) throws {
        for (name, format) in [("hello-720.json", OrbitWebcamFormat(width: 1280, height: 720, fps: 30)),
                               ("hello-1080.json", OrbitWebcamFormat(width: 1920, height: 1080, fps: 15))] {
            // Exactly what OrbitWebcamSocket.open sends.
            try JSONEncoder().encode(format).write(to: output.appendingPathComponent(name))
        }
    }

    // MARK: Pipeline

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    static func pipelineSendsOneFrameAtATime() {
        let pipeline = OrbitWebcamPipeline()
        pipeline.setFrameFormat(width: 1280, height: 720, fps: 30)
        let picture = testPicture(width: 1280, height: 720)

        pipeline.handle(picture, time: time(0))
        precondition(pipeline.takeStats().frames == 0, "no sink, no frames")

        let sink = ManualSink()
        pipeline.setSink(sink)
        pipeline.handle(picture, time: time(1.0))
        precondition(sink.sent.count == 1 && OrbitWebcamJPEGEncoder.isJPEG(sink.sent[0]), "the first frame goes out as JPEG")
        sink.deliverNext()
        var stats = pipeline.takeStats()
        precondition(stats.frames == 1 && stats.bytes == sink.sent[0].count && stats.dropped == 0 && stats.failed == 0, "stats: \(stats)")

        // Never faster than the announced rate (a 60 fps camera feeding a 30 fps hello): measured from
        // the last frame that went out, and skipped frames are not "dropped" ones.
        pipeline.handle(picture, time: time(1.01))
        precondition(sink.sent.count == 1 && pipeline.takeStats().dropped == 0, "a frame 10 ms after the last one is skipped")
        pipeline.handle(picture, time: time(1.04))
        precondition(sink.sent.count == 2, "a frame 1/30 s later goes out")

        // The network hasn't taken that frame yet: newer frames are dropped, never queued.
        pipeline.handle(picture, time: time(1.08))
        pipeline.handle(picture, time: time(1.12))
        precondition(sink.sent.count == 2 && sink.waiting == 1, "one frame on its way at most")
        sink.deliverNext(SendFailed())
        stats = pipeline.takeStats()
        precondition(stats.failed == 1 && stats.frames == 0 && stats.dropped == 2, "a failed send counts as failed: \(stats)")

        // A frame still on its way to an old socket no longer counts once streaming moved on.
        pipeline.handle(picture, time: time(2.0))
        precondition(sink.waiting == 1, "in flight to the old sink")
        let next = ManualSink()
        pipeline.setSink(next)
        sink.deliverNext()
        precondition(pipeline.takeStats().frames == 0, "the old socket's frame is not counted")
        pipeline.handle(picture, time: time(2.01))
        precondition(next.sent.count == 1, "the new sink starts at once (no in-flight frame, no rate wait)")
        next.deliverNext()

        pipeline.setSink(nil)
        pipeline.handle(picture, time: time(3.0))
        precondition(next.sent.count == 1, "nothing is sent after streaming stopped")

        pipeline.currentQuality = 0.9
        precondition(pipeline.currentQuality == OrbitWebcamPipeline.bestQuality, "quality is capped at 0.6")
        pipeline.currentQuality = 0.1
        precondition(pipeline.currentQuality == OrbitWebcamPipeline.lowestQuality, "quality never drops below 0.35")
    }

    // MARK: JPEG

    /// A frame as the camera hands it over (BGRA, top row first): red band on top, blue at the bottom,
    /// green on the left, yellow on the right, grey in between.
    static func testPicture(width: Int, height: Int) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let buffer = created else { preconditionFailure("pixel buffer \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            preconditionFailure("bitmap context")
        }
        // Core Graphics counts y from the bottom: the top band is at y = height - band.
        let w = CGFloat(width), h = CGFloat(height), band = min(w, h) * 0.1
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        }
        fill(CGRect(x: 0, y: 0, width: w, height: h), 0.5, 0.5, 0.5)
        fill(CGRect(x: 0, y: h - band, width: w, height: band), 1, 0, 0)
        fill(CGRect(x: 0, y: 0, width: w, height: band), 0, 0, 1)
        fill(CGRect(x: 0, y: band, width: band, height: h - 2 * band), 0, 1, 0)
        fill(CGRect(x: w - band, y: band, width: band, height: h - 2 * band), 1, 1, 0)
        return buffer
    }

    /// Landscape at the PC's size, the device held upright (pillarbox) and a bigger capture scaled
    /// down; all must come out as 1280×720 JPEG. Returns the encoder this Mac used.
    static func encodesJPEGs(_ output: URL) throws -> String {
        let encoder = OrbitWebcamJPEGEncoder()
        for (name, width, height) in [("landscape", 1280, 720), ("portrait", 720, 1280), ("downscaled", 1920, 1080)] {
            guard let jpeg = encoder.encode(testPicture(width: width, height: height), width: 1280, height: 720, quality: 0.6) else {
                preconditionFailure("\(name): no JPEG")
            }
            precondition(OrbitWebcamJPEGEncoder.isJPEG(jpeg) && jpeg.count < 3 * 1024 * 1024, "\(name): not a JPEG the PC takes")
            try jpeg.write(to: output.appendingPathComponent("\(name).jpg"))
        }
        // Lower quality makes smaller frames (how the app keeps up on a slow network).
        let picture = testPicture(width: 1280, height: 720)
        guard let best = encoder.encode(picture, width: 1280, height: 720, quality: OrbitWebcamPipeline.bestQuality),
              let lowest = encoder.encode(picture, width: 1280, height: 720, quality: OrbitWebcamPipeline.lowestQuality) else {
            preconditionFailure("quality steps")
        }
        precondition(lowest.count <= best.count, "quality \(OrbitWebcamPipeline.lowestQuality) is not smaller (\(lowest.count) vs \(best.count))")
        return encoder.usesVideoToolbox ? "VideoToolbox" : "Core Image"
    }
}
