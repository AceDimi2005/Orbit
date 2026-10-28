import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// Driven by check_webcam_contract.py: `OrbitWebcamTests <fixtures folder> <output folder>`.
// Covers Orbit/OrbitWebcamPipeline.swift (the iPhone webcam, DESIGN F10) without a PC, a camera or a
// simulator: the real agent's `/api/webcam` JSON and `WS /ws/camera` messages (fixtures written by the
// driver), the screen's decisions (setup and removal on the PC, reconnecting, what keeps Start disabled,
// the announced format), the frame pipeline (one frame on its way, frame-rate cap, stale sinks, quality
// bounds) and the JPEG encoder. The hello and the JPEGs go to the output folder; the driver then hands
// them to the agent's own `parse_hello` and `jpeg_to_bgr`.

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
    static let pc = "Test PC"
    static let camera = "DirectShow Softcam"

    /// Like `precondition`, but the condition is evaluated once, eagerly (several conditions here call
    /// mutating decision methods), and in every build.
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        guard condition else { fatalError(message(), file: file, line: line) }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        expect(arguments.count == 3, "usage: OrbitWebcamTests <fixtures folder> <output folder>")
        let fixtures = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

        try decodesTheAgentStatus(fixtures)
        olderAndNewerAgentsStillDecode()
        try parsesTheAgentMessages(fixtures)
        try writesTheHello(output)
        try announcesAFormatThePCTakes(fixtures)
        try setupFlowFollowsTheAgent(fixtures)
        reconnectsWithoutLoopingForever()
        explainsLostConnections()
        try blocksStartForTheRightReasons(fixtures)
        pipelineSendsOneFrameAtATime()
        encoderRecoversFromFailedSessions()
        let encoders = try encodesJPEGs(output)
        print("PASS: webcam status/setup JSON from the agent (ready, Visual C++ runtime missing, waiting for the Windows prompt, Windows on ARM, install 200/202/403, uninstall 200/202), "
              + "older/newer agents, socket messages (ready, connected, badHello, replaced, notInstalled), announced format within the PC's limits, "
              + "setup/removal flow (202 then polls, declined prompt, lost answers, files left, nothing installed), reconnects (drops right after ready, unreachable PC, "
              + "PC refusals, long calls, offline), lost-connection sentences, Start blockers, at most one frame on its way, frame-rate cap, stale sinks, quality bounds, "
              + "VideoToolbox session recovery, JPEG via \(encoders)")
    }

    // MARK: PC JSON

    static func status(_ fixtures: URL, _ name: String) throws -> OrbitWebcamPCStatus {
        try JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    static func decodesTheAgentStatus(_ fixtures: URL) throws {
        let ready = try status(fixtures, "status-ready.json")
        expect(ready.isSetUp && ready.isReady && !ready.isBusy && !ready.runtimeMissing, "set-up PC: \(ready)")
        expect(ready.reason == nil && ready.cameraName == camera && ready.softcamVersion != nil, "set-up PC: \(ready)")
        expect(ready.width == 1280 && ready.height == 720 && ready.fps == 30 && ready.clients == 0 && ready.active == false, "format: \(ready)")
        expect(ready.runtime?.ok == true && ready.runtime?.commands == [], "runtime: \(String(describing: ready.runtime))")
        // The app offers 720p/1080p at 30/15 fps: all of them must pass the PC's own limits.
        for (width, height) in [(1280, 720), (1920, 1080)] {
            for fps in [15, 30] { expect(ready.accepts(width: width, height: height, fps: fps), "limits refuse \(width)x\(height)@\(fps)") }
        }
        expect(!ready.accepts(width: 2560, height: 1440, fps: 30) && !ready.accepts(width: 1280, height: 720, fps: 60)
                     && !ready.accepts(width: 1280, height: 720, fps: 10), "limits: \(String(describing: ready.limits))")

        let runtime = try status(fixtures, "status-runtime.json")
        expect(runtime.runtimeMissing && !runtime.isReady && !runtime.isSetUp, "runtime missing: \(runtime)")
        expect(runtime.runtime?.missing == ["x86"] && runtime.runtime?.commands == ["winget install Microsoft.VCRedist.2015+.x86"],
                     "runtime commands: \(String(describing: runtime.runtime))")
        expect(runtime.reason?.contains("winget install Microsoft.VCRedist.2015+.x86") == true, "runtime reason: \(String(describing: runtime.reason))")

        let waiting = try status(fixtures, "status-waiting.json")
        expect(waiting.isBusy && waiting.installing == true && waiting.installStage == "waitingForApproval" && !waiting.isReady,
                     "waiting for the prompt: \(waiting)")
        expect(waiting.reason?.isEmpty == false, "a busy PC explains itself")

        let arm = try status(fixtures, "status-arm.json")
        expect(arm.installed == false && arm.runtime == nil && arm.reason?.contains("ARM") == true && !arm.isReady, "Windows on ARM: \(arm)")
        // Setup is offered everywhere except on a PC that can't run the webcam at all.
        expect(arm.isUnsupportedPC && !ready.isUnsupportedPC && !runtime.isUnsupportedPC && !waiting.isUnsupportedPC,
                     "only Windows on ARM is unsupported")

        let installed = try status(fixtures, "install-200.json")
        expect(installed.status == "installed" && installed.isSetUp && !installed.isBusy, "install 200: \(installed)")
        let pending = try status(fixtures, "install-202.json")
        expect(pending.status == "waitingForApproval" && pending.isBusy && pending.installStage == "waitingForApproval", "install 202: \(pending)")
        let removed = try status(fixtures, "uninstall-200.json")
        expect(removed.status == "uninstalled" && removed.filesLeft == false, "uninstall 200: \(removed)")
        let removing = try status(fixtures, "status-removing.json")
        expect(removing.uninstalling == true && removing.isBusy && removing.installStage == "waitingForApproval", "removal waiting: \(removing)")
        let declined = try status(fixtures, "status-install-declined.json")
        expect(!declined.isBusy && !declined.isSetUp && declined.installError?.contains("declined") == true, "declined prompt: \(declined)")
    }

    static func olderAndNewerAgentsStillDecode() {
        let older = try? JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(#"{"installed":true,"registered":true}"#.utf8))
        expect(older?.isReady == true && older?.limits == nil && older?.accepts(width: 1920, height: 1080, fps: 30) == true, "older agent")
        let newer = try? JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(#"{"installed":false,"registered":false,"reason":"x","future":{"a":[1,2]},"limits":{"maxWidth":3840,"extra":1}}"#.utf8))
        expect(newer?.isSetUp == false && newer?.limits?.maxWidth == 3840, "newer agent")
        let demo = OrbitWebcamPCStatus.demo
        expect(demo.isReady && demo.runtime?.ok == true, "demo status")
    }

    static func announcesAFormatThePCTakes(_ fixtures: URL) throws {
        let ready = try status(fixtures, "status-ready.json")
        for (width, height, fps) in [(1280, 720, 30), (1920, 1080, 30), (1920, 1080, 15), (1280, 720, 15)] {
            expect(OrbitWebcamFormat.announced(width: width, height: height, fps: fps, status: ready) == OrbitWebcamFormat(width: width, height: height, fps: fps),
                         "the agent's limits take \(width)x\(height)@\(fps) as chosen")
        }
        expect(OrbitWebcamFormat.announced(width: 1920, height: 1080, fps: 30, status: nil) == OrbitWebcamFormat(width: 1920, height: 1080, fps: 30),
                     "no status yet: as chosen")
        let small = try JSONDecoder().decode(OrbitWebcamPCStatus.self, from: Data(#"{"installed":true,"registered":true,"limits":{"maxWidth":1280,"maxHeight":720,"minFPS":15,"maxFPS":24}}"#.utf8))
        expect(OrbitWebcamFormat.announced(width: 1920, height: 1080, fps: 30, status: small) == OrbitWebcamFormat(width: 1280, height: 720, fps: 24),
                     "a smaller PC camera: 720p at its highest rate")
        expect(OrbitWebcamFormat.announced(width: 1280, height: 720, fps: 10, status: ready) == OrbitWebcamFormat(width: 1280, height: 720, fps: 15),
                     "a rate below the PC's minimum is raised")
    }

    // MARK: Socket messages

    static func parsesTheAgentMessages(_ fixtures: URL) throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("messages.json"))
        let messages = try JSONDecoder().decode([String: String].self, from: data)
        func parsed(_ name: String) -> OrbitWebcamMessage {
            guard let text = messages[name] else { preconditionFailure("the driver wrote no \(name) message") }
            return OrbitWebcamMessage.parse(text)
        }
        expect(parsed("ready") == .ready(width: 1280, height: 720, fps: 30, cameraName: camera), "ready: \(parsed("ready"))")
        expect(parsed("connectedFalse") == .connected(false), "connected false: \(parsed("connectedFalse"))")
        expect(parsed("connectedTrue") == .connected(true), "connected true: \(parsed("connectedTrue"))")
        for (name, code) in [("badHello", "badHello"), ("replaced", "replaced"), ("notInstalled", "notInstalled")] {
            guard case .failure(let found, let sentence) = parsed(name), found == code, sentence.count > 10 else {
                preconditionFailure("\(name): \(parsed(name))")
            }
            // The PC said why: its sentence ends streaming, without reconnecting on our own.
            guard let end = OrbitWebcamStreamEnd.said(parsed(name)), end.fromPC, end.code == code, end.message == sentence else {
                preconditionFailure("\(name) as a stream end")
            }
            var policy = OrbitWebcamReconnectPolicy()
            expect(policy.ended(fromPC: end.fromPC, streamedFor: 30, isOnline: true, isVisible: true, now: 0) == .stop(.pcSaidWhy),
                         "\(name) stops streaming")
        }
        if case .failure(_, let sentence) = parsed("replaced") {
            expect(sentence == "Another device started using this PC's webcam.", "replaced sentence: \(sentence)")
        }
        expect(OrbitWebcamStreamEnd.said(parsed("ready")) == nil && OrbitWebcamStreamEnd.said(parsed("connectedTrue")) == nil, "only errors end it")
        expect(OrbitWebcamMessage.parse("not json") == .other && OrbitWebcamMessage.parse(#"{"keyframe":true}"#) == .other
                     && OrbitWebcamMessage.parse("[1,2]") == .other, "unknown messages are ignored")
    }

    static func writesTheHello(_ output: URL) throws {
        for (name, format) in [("hello-720.json", OrbitWebcamFormat(width: 1280, height: 720, fps: 30)),
                               ("hello-1080.json", OrbitWebcamFormat(width: 1920, height: 1080, fps: 15))] {
            // Exactly what OrbitWebcamSocket.open sends.
            try JSONEncoder().encode(format).write(to: output.appendingPathComponent(name))
        }
    }

    // MARK: Setup and removal on the PC

    static func setupFlowFollowsTheAgent(_ fixtures: URL) throws {
        let notSetUp = try status(fixtures, "status-runtime.json")
        let ready = try status(fixtures, "status-ready.json")
        let waiting = try status(fixtures, "status-waiting.json")
        let declined = try status(fixtures, "status-install-declined.json")
        let removing = try status(fixtures, "status-removing.json")
        let removedPolled = try status(fixtures, "status-removed.json")
        let refusal = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtures.appendingPathComponent("install-403.json")))
        guard let declinedSentence = refusal["detail"], declinedSentence.contains("declined") else { preconditionFailure("403 detail: \(refusal)") }

        // 202 (the Windows prompt is still open), polls while it is, then the person declines it.
        var flow = OrbitWebcamSetupFlow()
        let started = flow.begin(.install, current: notSetUp)
        let startedAgain = flow.begin(.install, current: notSetUp)
        expect(started && !startedAgain, "one operation at a time")
        expect(flow.polled(ready, pcName: pc, cameraName: camera) == nil && flow.isRunning, "a poll before the answer never ends it")
        expect(flow.answered(try status(fixtures, "install-202.json"), pcName: pc, cameraName: camera) == nil && flow.awaitsPoll, "202: the polls decide")
        expect(flow.polled(waiting, pcName: pc, cameraName: camera) == nil && flow.isRunning, "still waiting for the prompt")
        expect(flow.polled(declined, pcName: pc, cameraName: camera) == .failure && !flow.isRunning && flow.error == declined.installError,
                     "the PC's sentence for the declined prompt: \(String(describing: flow.error))")

        // 202, then approved: set up.
        expect(flow.begin(.install, current: notSetUp) && flow.error == nil && flow.message == nil, "a new operation clears the last one")
        _ = flow.answered(try status(fixtures, "install-202.json"), pcName: pc, cameraName: camera)
        expect(flow.polled(ready, pcName: pc, cameraName: camera) == .success && flow.message?.contains("set up on \(pc)") == true
                     && flow.message?.contains(camera) == true && flow.filesMayBeLeft == false, "set up after the prompt: \(String(describing: flow.message))")

        // 200 at once, and already set up.
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answered(try status(fixtures, "install-200.json"), pcName: pc, cameraName: camera) == .success && !flow.isRunning, "install 200")
        var already = ready
        already.status = "alreadyInstalled"
        _ = flow.begin(.install, current: ready)
        expect(flow.answered(already, pcName: pc, cameraName: camera) == .success && flow.message?.contains("already") == true, "already set up")

        // The PC's own refusal (403 declined, 409 runtime, ARM, …).
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.refused(declinedSentence) == .failure && flow.error == declinedSentence && !flow.isRunning, "403")

        // The answer got lost: still running on the PC, finished there, or never started.
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answerLost("Your PC didn't answer.", status: waiting, pcName: pc, cameraName: camera) == nil && flow.awaitsPoll, "still running: poll")
        expect(flow.polled(ready, pcName: pc, cameraName: camera) == .success, "then set up")
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answerLost("Your PC didn't answer.", status: ready, pcName: pc, cameraName: camera) == .success, "set up while the answer was lost")
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answerLost("Your PC didn't answer.", status: notSetUp, pcName: pc, cameraName: camera) == .failure
                     && flow.error == "Couldn't set up the webcam. Your PC didn't answer.", "never started: \(String(describing: flow.error))")
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answerLost("Your PC didn't answer.", status: declined, pcName: pc, cameraName: camera) == .failure
                     && flow.error == declined.installError, "failed on the PC while the answer was lost")
        _ = flow.begin(.install, current: notSetUp)
        expect(flow.answerLost("Your PC didn't answer.", status: nil, pcName: pc, cameraName: camera) == .failure, "PC unreadable")

        // Removal: 200 with nothing left, with files left, and nothing installed at all.
        _ = flow.begin(.remove, current: ready)
        expect(flow.answered(try status(fixtures, "uninstall-200.json"), pcName: pc, cameraName: camera) == .success
                     && flow.message == "The webcam was removed from \(pc)." && flow.filesMayBeLeft == false, "removed: \(String(describing: flow.message))")
        _ = flow.begin(.remove, current: ready)
        let filesLeft = try status(fixtures, "uninstall-200-files-left.json")
        expect(filesLeft.filesLeft == true, "files left fixture")
        expect(flow.answered(filesLeft, pcName: pc, cameraName: camera) == .success && flow.message?.contains("restart the PC") == true
                     && flow.filesMayBeLeft == true, "files left: \(String(describing: flow.message))")
        let nothing = try status(fixtures, "uninstall-200-not-installed.json")
        expect(nothing.status == "notInstalled", "not installed fixture")
        _ = flow.begin(.remove, current: removedPolled)
        expect(flow.answered(nothing, pcName: pc, cameraName: camera) == .quiet && flow.message == "Nothing of the webcam is left on \(pc)."
                     && flow.filesMayBeLeft == false, "leftovers already gone: \(String(describing: flow.message))")
        _ = flow.begin(.remove, current: ready)
        expect(flow.answered(nothing, pcName: pc, cameraName: camera) == .quiet && flow.message?.contains("nothing to remove") == true, "nothing to remove")

        // Removal: 202, polled while the prompt is open, then done. GET /api/webcam doesn't say whether files
        // were left, so the sentence says what to do if they were, and "Remove" stays offered.
        _ = flow.begin(.remove, current: ready)
        expect(flow.answered(try status(fixtures, "uninstall-202.json"), pcName: pc, cameraName: camera) == nil && flow.awaitsPoll, "removal 202")
        expect(flow.polled(removing, pcName: pc, cameraName: camera) == nil && flow.isRunning, "removal still waiting")
        expect(flow.polled(removedPolled, pcName: pc, cameraName: camera) == .success && flow.message?.contains("restart the PC and remove the webcam again") == true
                     && flow.filesMayBeLeft == true, "polled removal: \(String(describing: flow.message))")
        _ = flow.begin(.remove, current: ready)
        _ = flow.answered(try status(fixtures, "uninstall-202.json"), pcName: pc, cameraName: camera)
        expect(flow.polled(ready, pcName: pc, cameraName: camera) == .failure && flow.error?.contains("still lists") == true, "still registered")
        _ = flow.begin(.remove, current: ready)
        expect(flow.answerLost("Your PC didn't answer.", status: removedPolled, pcName: pc, cameraName: camera) == .success, "removed while the answer was lost")

        flow.reset()
        expect(!flow.isRunning && flow.message == nil && flow.error == nil && flow.filesMayBeLeft == nil, "reset")
    }

    // MARK: Reconnecting

    static func reconnectsWithoutLoopingForever() {
        let delays = OrbitWebcamReconnectPolicy.delays

        // The PC takes the camera and drops it again right after "ready", every time: a few quick tries,
        // then stop with a clear reason instead of reconnecting every half second forever.
        var policy = OrbitWebcamReconnectPolicy()
        var decisions: [OrbitWebcamReconnectPolicy.Decision] = []
        var now = 100.0
        while decisions.count < 20 {
            let decision = policy.ended(fromPC: false, streamedFor: 0.3, isOnline: true, isVisible: true, now: now)
            decisions.append(decision)
            if case .stop = decision { break }
            now += 1.5
        }
        let quickTries: [OrbitWebcamReconnectPolicy.Decision] = delays.enumerated().map { .reconnect(delay: $0.element, attempt: $0.offset + 1) }
        expect(decisions == quickTries + [.stop(.keepsDropping)], "drops right after ready: \(decisions)")

        // A PC that never answers: four quick retries, then the last connection's reason.
        policy = OrbitWebcamReconnectPolicy()
        for (index, delay) in delays.enumerated() {
            expect(policy.ended(fromPC: false, streamedFor: nil, isOnline: true, isVisible: true, now: Double(index)) == .reconnect(delay: delay, attempt: index + 1),
                         "retry \(index + 1)")
        }
        expect(policy.ended(fromPC: false, streamedFor: nil, isOnline: true, isVisible: true, now: 9) == .stop(.gaveUp), "gives up")

        // A long call with a short Wi-Fi drop every few minutes: always a quick reconnect.
        policy = OrbitWebcamReconnectPolicy()
        for drop in 0..<12 {
            expect(policy.ended(fromPC: false, streamedFor: 170, isOnline: true, isVisible: true, now: Double(drop) * 180) == .reconnect(delay: delays[0], attempt: 1),
                         "drop \(drop) of a long call")
        }
        // Streaming a while, then dropping every 12 s: that also counts as dropping all the time.
        policy = OrbitWebcamReconnectPolicy()
        var last: OrbitWebcamReconnectPolicy.Decision = .reconnect(delay: 0, attempt: 0)
        for drop in 0..<OrbitWebcamReconnectPolicy.maxDrops {
            last = policy.ended(fromPC: false, streamedFor: 11, isOnline: true, isVisible: true, now: Double(drop) * 12)
        }
        expect(last == .stop(.keepsDropping), "five drops within a minute: \(last)")
        // A retry that reaches "ready" but drops at once keeps counting retries.
        policy = OrbitWebcamReconnectPolicy()
        _ = policy.ended(fromPC: false, streamedFor: nil, isOnline: true, isVisible: true, now: 0)
        expect(policy.ended(fromPC: false, streamedFor: 2, isOnline: true, isVisible: true, now: 1) == .reconnect(delay: delays[1], attempt: 2), "short connection")
        expect(policy.ended(fromPC: false, streamedFor: 15, isOnline: true, isVisible: true, now: 20) == .reconnect(delay: delays[0], attempt: 1), "stable again")

        // Orbit can't reach the PC at all: stop after two retries.
        policy = OrbitWebcamReconnectPolicy()
        _ = policy.ended(fromPC: false, streamedFor: 40, isOnline: false, isVisible: true, now: 0)
        _ = policy.ended(fromPC: false, streamedFor: nil, isOnline: false, isVisible: true, now: 1)
        expect(policy.ended(fromPC: false, streamedFor: nil, isOnline: false, isVisible: true, now: 3) == .stop(.offline), "offline")

        policy = OrbitWebcamReconnectPolicy()
        expect(policy.ended(fromPC: true, streamedFor: nil, isOnline: true, isVisible: true, now: 0) == .stop(.pcSaidWhy), "refused")
        expect(policy.ended(fromPC: false, streamedFor: 30, isOnline: true, isVisible: false, now: 0) == .stop(.leftScreen), "left the screen")
    }

    static func explainsLostConnections() {
        func end(_ status: Int?, pin: String? = nil, ready: Bool = false, cancelled: Bool = false) -> OrbitWebcamStreamEnd {
            OrbitWebcamStreamEnd.lost(pcName: pc, handshakeStatus: status, pinFailure: pin, ready: ready, cancelled: cancelled)
        }
        let pin = end(nil, pin: "The PC's identity didn't match. Pair it again in My PCs.")
        expect(pin.fromPC && pin.message.contains("identity"), "pin: \(pin)")
        expect(end(401).fromPC && end(401).message.contains("Pair the PC again"), "401")
        expect(end(404).fromPC && end(404).message.contains("Update Orbit PC Companion"), "404")
        expect(end(426).fromPC && end(426).message.contains("encrypted"), "426")
        expect(end(500).fromPC && end(500).message.contains("error 500"), "500")
        // Reconnected on our own:
        expect(!end(nil).fromPC && end(nil).message.hasPrefix("Couldn't reach \(pc)."), "no answer: \(end(nil).message)")
        expect(!end(101, cancelled: true).fromPC && end(101, cancelled: true).message.contains("in time"), "silent PC")
        expect(!end(101).fromPC && end(101).message.contains("before it was ready"), "closed before ready")
        expect(!end(101, ready: true).fromPC && end(101, ready: true).message.hasPrefix("Lost the connection to \(pc)."), "lost after ready")
    }

    // MARK: Start

    static func blocksStartForTheRightReasons(_ fixtures: URL) throws {
        let ready = try status(fixtures, "status-ready.json")
        var good = OrbitWebcamSituation(pcName: pc, featuresKnown: true, supportsWebcam: true, status: ready)
        expect(OrbitWebcamReadiness.startBlocker(good) == nil && OrbitWebcamReadiness.pcProblem(good) == nil, "a set-up PC")

        func blocker(_ change: (inout OrbitWebcamSituation) -> Void) -> String? {
            var situation = good
            change(&situation)
            return OrbitWebcamReadiness.startBlocker(situation)
        }
        expect(blocker { $0.canUseCamera = false } == "Allow camera access first.", "camera access")
        expect(blocker { $0.cameraFailure = "The front camera could not start." } == "The front camera could not start.", "camera failure")
        expect(blocker { $0.hasPC = false } == "Pair a PC first.", "no PC")
        expect(blocker { $0.hasSecureLink = false } == "Needs the encrypted connection.", "no pinned link")
        expect(blocker { $0.isOnline = false } == "\(pc) is offline.", "offline")
        expect(blocker { $0.supportsWebcam = false } == "Update Orbit PC Companion.", "older agent")
        expect(blocker { $0.localNetworkUnreachable = true } == "Can't reach \(pc) on this network.", "another network")
        expect(blocker { $0.featuresKnown = false } == "Checking what \(pc) can do…", "capabilities not read yet")
        expect(blocker { $0.featuresKnown = false; $0.featuresFailed = true } == "Couldn't reach \(pc).", "capabilities failed")
        expect(blocker { $0.status = nil } == "Reading the webcam status of \(pc)…", "status not read yet")
        expect(blocker { $0.status = nil; $0.statusFailed = true } == "Couldn't read the webcam status of \(pc).", "status failed")
        expect(blocker { $0.setupRunning = true } == "Wait for the setup on \(pc) to finish.", "setup running")
        expect(blocker { $0.status = try? status(fixtures, "status-waiting.json") } == "Wait for the setup on \(pc) to finish.", "setup on the PC")
        expect(blocker { $0.status = try? status(fixtures, "status-runtime.json") } == "Set up the webcam on \(pc) first.", "not set up")
        expect(blocker { $0.status = try? status(fixtures, "status-arm.json") } == "\(pc) can't run the webcam.", "Windows on ARM")

        let elsewhere = OrbitWebcamReadiness.pcProblem({ var s = good; s.localNetworkUnreachable = true; return s }())
        expect(elsewhere?.message.contains("local network only") == true, "another network explained")
        // Demo mode: the preview and the encoder work without a PC.
        good = OrbitWebcamSituation(isDemo: true, hasPC: false, isOnline: false)
        expect(OrbitWebcamReadiness.startBlocker(good) == nil && OrbitWebcamReadiness.pcProblem(good) == nil, "demo")
    }

    // MARK: Pipeline

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    static func pipelineSendsOneFrameAtATime() {
        let pipeline = OrbitWebcamPipeline()
        pipeline.setFrameFormat(width: 1280, height: 720, fps: 30)
        let picture = testPicture(width: 1280, height: 720)

        pipeline.handle(picture, time: time(0))
        expect(pipeline.takeStats().frames == 0, "no sink, no frames")

        let sink = ManualSink()
        pipeline.setSink(sink)
        pipeline.handle(picture, time: time(1.0))
        expect(sink.sent.count == 1 && OrbitWebcamJPEGEncoder.isJPEG(sink.sent[0]), "the first frame goes out as JPEG")
        sink.deliverNext()
        var stats = pipeline.takeStats()
        expect(stats.frames == 1 && stats.bytes == sink.sent[0].count && stats.dropped == 0 && stats.failed == 0, "stats: \(stats)")
        expect(stats.portrait == false, "a landscape frame")

        // Never faster than the announced rate (a 60 fps camera feeding a 30 fps hello): measured from
        // the last frame that went out, and skipped frames are not "dropped" ones.
        pipeline.handle(picture, time: time(1.01))
        expect(sink.sent.count == 1 && pipeline.takeStats().dropped == 0, "a frame 10 ms after the last one is skipped")
        pipeline.handle(picture, time: time(1.04))
        expect(sink.sent.count == 2, "a frame 1/30 s later goes out")

        // The network hasn't taken that frame yet: newer frames are dropped, never queued.
        pipeline.handle(picture, time: time(1.08))
        pipeline.handle(picture, time: time(1.12))
        expect(sink.sent.count == 2 && sink.waiting == 1, "one frame on its way at most")
        sink.deliverNext(SendFailed())
        stats = pipeline.takeStats()
        expect(stats.failed == 1 && stats.frames == 0 && stats.dropped == 2, "a failed send counts as failed: \(stats)")

        // A frame still on its way to an old socket no longer counts once streaming moved on.
        pipeline.handle(picture, time: time(2.0))
        expect(sink.waiting == 1, "in flight to the old sink")
        let next = ManualSink()
        pipeline.setSink(next)
        sink.deliverNext()
        expect(pipeline.takeStats().frames == 0, "the old socket's frame is not counted")
        pipeline.handle(testPicture(width: 720, height: 1280), time: time(2.01))
        expect(next.sent.count == 1, "the new sink starts at once (no in-flight frame, no rate wait)")
        next.deliverNext()
        expect(pipeline.takeStats().portrait == true, "the device held upright")

        pipeline.setSink(nil)
        pipeline.handle(picture, time: time(3.0))
        expect(next.sent.count == 1, "nothing is sent after streaming stopped")
        pipeline.resetEncoder()
        expect(pipeline.usesHardwareEncoder, "a reset goes back to VideoToolbox")

        pipeline.currentQuality = 0.9
        expect(pipeline.currentQuality == OrbitWebcamPipeline.bestQuality, "quality is capped at 0.6")
        pipeline.currentQuality = 0.1
        expect(pipeline.currentQuality == OrbitWebcamPipeline.lowestQuality, "quality never drops below 0.35")
    }

    /// A failed frame drops the VideoToolbox session (the next frame gets a fresh one); only failures in
    /// a row with fresh sessions hand over to Core Image, and a reset gives VideoToolbox another chance.
    static func encoderRecoversFromFailedSessions() {
        var health = OrbitWebcamEncoderHealth()
        for _ in 1..<OrbitWebcamEncoderHealth.failuresBeforeFallback { health.failed() }
        expect(health.usesVideoToolbox, "fresh sessions get their chance")
        health.encoded()
        for _ in 1..<OrbitWebcamEncoderHealth.failuresBeforeFallback { health.failed() }
        expect(health.usesVideoToolbox && health.failuresInARow == OrbitWebcamEncoderHealth.failuresBeforeFallback - 1, "a frame that worked starts the count again")
        health.failed()
        expect(!health.usesVideoToolbox, "Core Image after failures in a row")
        health.reset()
        expect(health.usesVideoToolbox && health.failuresInARow == 0, "reset")
        let coreImage = OrbitWebcamJPEGEncoder(videoToolbox: false)
        expect(!coreImage.usesVideoToolbox, "Core Image encoder")
        coreImage.reset()
        expect(coreImage.usesVideoToolbox, "reset goes back to VideoToolbox")
    }

    // MARK: JPEG

    /// A frame drawn like a camera picture (BGRA, top row first): red band on top, blue at the bottom,
    /// green on the left, yellow on the right, mid-grey in between.
    static func testPicture(width: Int, height: Int) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let buffer = created else { preconditionFailure("pixel buffer \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // sRGB colours into an sRGB bitmap: no colour matching, so the bytes are exactly these colours.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            preconditionFailure("bitmap context")
        }
        // Core Graphics counts y from the bottom: the top band is at y = height - band.
        let w = CGFloat(width), h = CGFloat(height), band = min(w, h) * 0.1
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        }
        fill(CGRect(x: 0, y: 0, width: w, height: h), 0.5, 0.5, 0.5)
        fill(CGRect(x: 0, y: h - band, width: w, height: band), 1, 0, 0)
        fill(CGRect(x: 0, y: 0, width: w, height: band), 0, 0, 1)
        fill(CGRect(x: 0, y: band, width: band, height: h - 2 * band), 0, 1, 0)
        fill(CGRect(x: w - band, y: band, width: band, height: h - 2 * band), 1, 1, 0)
        return buffer
    }

    /// The same picture as the iPhone camera hands it over: 4:2:0 YCbCr, full range, tagged BT.709.
    static func cameraPicture(width: Int, height: Int) -> CVPixelBuffer {
        let source = testPicture(width: width, height: height)
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &created) == kCVReturnSuccess,
              let yuv = created else { preconditionFailure("4:2:0 buffer") }
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard let transfer else { preconditionFailure("pixel transfer") }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: yuv)
        expect(status == noErr, "pixel transfer \(status)")
        VTPixelTransferSessionInvalidate(transfer)
        let matrix = CVBufferCopyAttachment(yuv, kCVImageBufferYCbCrMatrixKey, nil) as? String
        expect(matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String), "tagged like the camera: \(String(describing: matrix))")
        return yuv
    }

    /// Landscape at the PC's size, the device held upright (pillarbox) and a bigger capture scaled down,
    /// drawn (BGRA) and as the camera delivers them (4:2:0, BT.709), through VideoToolbox (when this Mac
    /// has it) and Core Image: all must come out as 1280×720 JPEG with true colours (the driver checks
    /// them). Returns the encoders used.
    static func encodesJPEGs(_ output: URL) throws -> String {
        let videoToolbox = OrbitWebcamJPEGEncoder()
        let coreImage = OrbitWebcamJPEGEncoder(videoToolbox: false)
        for (encoderName, encoder) in [("", videoToolbox), ("-ci", coreImage)] {
            for (name, width, height) in [("landscape", 1280, 720), ("portrait", 720, 1280), ("downscaled", 1920, 1080)] {
                for (sourceName, picture) in [("", testPicture(width: width, height: height)), ("-camera", cameraPicture(width: width, height: height))] {
                    let file = name + sourceName + encoderName
                    guard let jpeg = encoder.encode(picture, width: 1280, height: 720, quality: OrbitWebcamPipeline.bestQuality) else {
                        preconditionFailure("\(file): no JPEG")
                    }
                    expect(OrbitWebcamJPEGEncoder.isJPEG(jpeg) && jpeg.count < 3 * 1024 * 1024, "\(file): not a JPEG the PC takes")
                    try jpeg.write(to: output.appendingPathComponent("\(file).jpg"))
                }
            }
        }
        expect(!coreImage.usesVideoToolbox, "the Core Image encoder stayed on Core Image")
        // Lower quality makes smaller frames (how the app keeps up on a slow network).
        let picture = cameraPicture(width: 1280, height: 720)
        guard let best = videoToolbox.encode(picture, width: 1280, height: 720, quality: OrbitWebcamPipeline.bestQuality),
              let lowest = videoToolbox.encode(picture, width: 1280, height: 720, quality: OrbitWebcamPipeline.lowestQuality) else {
            preconditionFailure("quality steps")
        }
        expect(lowest.count <= best.count, "quality \(OrbitWebcamPipeline.lowestQuality) is not smaller (\(lowest.count) vs \(best.count))")
        return (videoToolbox.usesVideoToolbox ? "VideoToolbox" : "Core Image (no VideoToolbox JPEG encoder here)") + " and Core Image"
    }
}
