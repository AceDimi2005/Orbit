import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import VideoToolbox

// iPhone as a PC webcam (DESIGN F10), the camera side: capture and preview. The PC side
// (`orbit_webcam.py`) takes upright, unmirrored JPEG frames over `WS /ws/camera`; JPEG encoding is in
// `OrbitWebcamPipeline.swift`, the screen and the connection in `OrbitWebcamModel.swift` and `WebcamView.swift`.

// MARK: - Settings

enum OrbitWebcamLens: String, CaseIterable, Identifiable {
    case front, back
    var id: String { rawValue }
    var title: String { self == .front ? "Front" : "Back" }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
}

enum OrbitWebcamResolution: String, CaseIterable, Identifiable {
    case hd720, hd1080
    var id: String { rawValue }
    var title: String { self == .hd720 ? "720p" : "1080p" }
    var width: Int { self == .hd720 ? 1280 : 1920 }
    var height: Int { self == .hd720 ? 720 : 1080 }
    var preset: AVCaptureSession.Preset { self == .hd720 ? .hd1280x720 : .hd1920x1080 }
}

/// What the camera captures right now (lens, size, frame rate).
struct OrbitWebcamCaptureSettings: Equatable {
    var lens: OrbitWebcamLens
    var resolution: OrbitWebcamResolution
    var fps: Int
}

// MARK: - Camera

/// One AVCaptureSession for the webcam screen. Frames come out upright for the way the device is held
/// (landscape frames when it is sideways) and never mirrored; only the preview is mirrored for the front
/// camera, like a mirror. Frames for the PC are the camera's own 4:2:0 YCbCr (no conversion to BGRA), and
/// they flow only while something is sent. Everything that touches the session runs on `sessionQueue`.
///
/// In Debug builds without a camera (the Simulator), a synthetic source draws test frames instead, so
/// the whole pipeline can be checked end to end. Release builds never contain it.
final class OrbitWebcamCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case running
        case interrupted(String)
        case failed(String)
    }

    /// Hosted by `OrbitWebcamPreview`.
    let previewLayer: AVCaptureVideoPreviewLayer
    /// Called on the main queue.
    var onState: ((State) -> Void)?
    /// iOS refused the camera for this lens; the previous camera runs again (main queue).
    var onSwitchFailed: ((OrbitWebcamLens, String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dimitrie.orbit.webcam.session")
    private let videoQueue = DispatchQueue(label: "com.dimitrie.orbit.webcam.video", qos: .userInteractive)
    private let frameLock = NSLock()
    private var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var input: AVCaptureDeviceInput?
    // sessionQueue only.
    private var applied: OrbitWebcamCaptureSettings?
    private var wantsRunning = false
    private var sendsFrames = false
    private var restartedAfterError = false
    private var captureAngle: CGFloat?
    /// The camera whose rotation is followed (set before the main queue builds its coordinator).
    private var rotationFollowedDeviceID: String?
    // Main queue only.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    /// "iPhone" or "iPad", read once on the main thread (messages are built on other queues).
    private let deviceWord: String
    #if DEBUG
    let synthetic: OrbitWebcamSyntheticSource?
    #endif

    /// Whether this device has the camera for `lens` (always true for the Debug test source).
    static func hasCamera(_ lens: OrbitWebcamLens) -> Bool {
        #if DEBUG
        if OrbitWebcamSyntheticSource.isEnabled { return true }
        #endif
        return device(for: lens) != nil
    }

    static func device(for lens: OrbitWebcamLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
    }

    /// True when frames come from the Debug test source instead of a camera.
    var usesSyntheticFrames: Bool {
        #if DEBUG
        return synthetic != nil
        #else
        return false
        #endif
    }

    override init() {
        deviceWord = OrbitWebcamDevice.word
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        #if DEBUG
        synthetic = OrbitWebcamSyntheticSource.isEnabled ? OrbitWebcamSyntheticSource(queue: videoQueue) : nil
        #endif
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        rotationObservations.forEach { $0.invalidate() }
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    /// Gets every frame on the video queue (nil stops delivery).
    func setFrameHandler(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) {
        frameLock.lock(); frameHandler = handler; frameLock.unlock()
        #if DEBUG
        synthetic?.setDeliver(handler)
        #endif
    }

    private func deliver(_ buffer: CVPixelBuffer, _ time: CMTime) {
        frameLock.lock(); let handler = frameHandler; frameLock.unlock()
        handler?(buffer, time)
    }

    /// Applies the lens, size and frame rate, then runs the camera.
    func start(_ settings: OrbitWebcamCaptureSettings) {
        #if DEBUG
        if let synthetic {
            synthetic.start(settings)
            report(.running)
            return
        }
        #endif
        sessionQueue.async { [self] in
            wantsRunning = true
            restartedAfterError = false
            apply(settings)
        }
    }

    /// Changes lens, size or frame rate while running (a short gap in the frames, no new session).
    func update(_ settings: OrbitWebcamCaptureSettings) {
        #if DEBUG
        if let synthetic { synthetic.start(settings); return }
        #endif
        sessionQueue.async { [self] in
            guard wantsRunning, settings != applied else { return }
            apply(settings)
        }
    }

    /// Frames for the PC flow only while something is sent (the preview has its own connection and
    /// runs either way), so previewing costs no frames that would only be thrown away.
    func setSendsFrames(_ sends: Bool) {
        #if DEBUG
        if let synthetic { synthetic.sendsFrames = sends; return }
        #endif
        sessionQueue.async { [self] in
            sendsFrames = sends
            output.connection(with: .video)?.isEnabled = sends
        }
    }

    func stop() {
        #if DEBUG
        if let synthetic { synthetic.stop(); report(.idle); return }
        #endif
        sessionQueue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
            report(.idle)
        }
    }

    /// Pauses or resumes the on-screen preview (the frames for the PC keep flowing), to save power
    /// while the screen is dimmed.
    func setPreviewEnabled(_ enabled: Bool) {
        #if DEBUG
        synthetic?.previewEnabled = enabled
        #endif
        previewLayer.connection?.isEnabled = enabled
    }

    // MARK: Session (sessionQueue)

    /// Configures and runs the session. Reports `.running` after every change that worked, so a camera
    /// that failed before (a refused lens switch) shows as working again.
    private func apply(_ settings: OrbitWebcamCaptureSettings) {
        guard configure(settings) else { return }
        if !session.isRunning { session.startRunning() }
        if session.isRunning && !session.isInterrupted { report(.running) }
    }

    private func configure(_ settings: OrbitWebcamCaptureSettings) -> Bool {
        guard let device = Self.device(for: settings.lens) else {
            applied = nil
            report(.failed("This \(deviceWord) has no \(settings.lens.title.lowercased()) camera."))
            return false
        }
        session.beginConfiguration()
        if input?.device.uniqueID != device.uniqueID {
            let previous = input
            if let previous { session.removeInput(previous) }
            input = nil
            // iOS refuses a camera that can't do the session's current size (1080p, with the 720p front
            // camera of some iPads): add it at a size every camera has, and ask for the chosen one below.
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw OrbitError(message: "iOS can't use it right now.") }
                session.addInput(newInput)
                input = newInput
            } catch {
                // Put the previous camera back, so the preview and the PC keep a picture, and forget what was
                // applied, so the next change configures everything again.
                var restored: AVCaptureDevice?
                if let previous, session.canAddInput(previous) {
                    session.addInput(previous)
                    input = previous
                    restored = previous.device
                    if let preset = applied?.resolution.preset, session.canSetSessionPreset(preset) { session.sessionPreset = preset }
                    configureOutputConnection()
                }
                session.commitConfiguration()
                if let restored, let fps = applied?.fps { setFrameRate(fps, on: restored) }
                applied = nil
                let message = "The \(settings.lens.title.lowercased()) camera could not start. \(error.localizedDescription)"
                if restored != nil {
                    let lens = settings.lens
                    DispatchQueue.main.async { [weak self] in self?.onSwitchFailed?(lens, message) }
                } else {
                    report(.failed(message))
                }
                return false
            }
        }
        if !session.outputs.contains(output) {
            // The camera's own 4:2:0 YCbCr: VideoToolbox's JPEG encoder and Core Image take it as it is
            // (BGRA would cost a conversion there and back for every frame).
            let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let format = output.availableVideoPixelFormatTypes.contains(yuv) ? yuv : kCVPixelFormatType_32BGRA
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            // Frames that arrive while the previous one is still being handled are dropped by
            // AVFoundation: nothing queues up behind a slow network.
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // The chosen size when this camera has it, otherwise the closest one it has.
        if session.canSetSessionPreset(settings.resolution.preset) {
            session.sessionPreset = settings.resolution.preset
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        // iPad: keep the camera on in Split View, Slide Over and Stage Manager (otherwise iOS pauses it
        // as soon as another app shares the screen).
        if session.isMultitaskingCameraAccessSupported, !session.isMultitaskingCameraAccessEnabled {
            session.isMultitaskingCameraAccessEnabled = true
        }
        configureOutputConnection()
        session.commitConfiguration()
        setFrameRate(settings.fps, on: device)
        applied = settings
        if rotationFollowedDeviceID != device.uniqueID {
            // A new camera (first start or a lens switch) needs its own rotation coordinator.
            rotationFollowedDeviceID = device.uniqueID
            DispatchQueue.main.async { [weak self] in self?.followRotation(of: device) }
        }
        return true
    }

    /// The frames for the PC (each camera brings a new connection): flowing only while something is sent,
    /// never mirrored (the PC gets the true picture; apps there mirror their own self-view), upright.
    private func configureOutputConnection() {
        guard let connection = output.connection(with: .video) else { return }
        connection.isEnabled = sendsFrames
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if let captureAngle, connection.isVideoRotationAngleSupported(captureAngle) { connection.videoRotationAngle = captureAngle }
    }

    /// Locks the frame rate (a session preset resets it, so this runs after every change).
    private func setFrameRate(_ fps: Int, on device: AVCaptureDevice) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) + 0.01 && Double(fps) - 0.01 <= $0.maxFrameRate
        }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    // MARK: Orientation (main queue)

    /// Keeps the frames upright (level with the horizon) for the way the device is held, and the
    /// preview upright for the interface.
    private func followRotation(of device: AVCaptureDevice) {
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations = []
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = self?.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let self else { return }
                self.captureAngle = angle
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        })
    }

    // MARK: Frames (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: Interruptions

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        let message: String
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            message = "iOS turns the camera off while Orbit isn't on screen."
        case .videoDeviceInUseByAnotherClient:
            message = "Another app is using the camera. Close it to continue."
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            message = "The camera can't run while other apps share the screen."
        case .videoDeviceNotAvailableDueToSystemPressure:
            message = "Your \(deviceWord) is too hot to use the camera right now. Let it cool down."
        default:
            message = "The camera was interrupted."
        }
        report(.interrupted(message))
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        report(.running)
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        sessionQueue.async { [self] in
            guard wantsRunning else { return }
            if !restartedAfterError {
                restartedAfterError = true
                session.startRunning()
                if session.isRunning { report(.running); return }
            }
            report(.failed("The camera stopped unexpectedly. Leave this screen and open it again."))
        }
    }
}

enum OrbitWebcamDevice {
    /// "iPhone" or "iPad", for sentences (read it on the main thread).
    static var word: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

// MARK: - Preview

/// Shows the camera preview (or, in Debug builds without a camera, the test frames), fitted 16:9.
struct OrbitWebcamPreview: UIViewRepresentable {
    let camera: OrbitWebcamCamera

    func makeUIView(context: Context) -> OrbitWebcamPreviewHostView {
        let view = OrbitWebcamPreviewHostView()
        view.backgroundColor = .black
        view.host(camera.previewLayer)
        #if DEBUG
        if let synthetic = camera.synthetic { view.host(synthetic.previewLayer) }
        #endif
        return view
    }

    func updateUIView(_ uiView: OrbitWebcamPreviewHostView, context: Context) {}
}

final class OrbitWebcamPreviewHostView: UIView {
    private var hosted: [CALayer] = []

    func host(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        self.layer.addSublayer(layer)
        hosted.append(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A newer preview (the layout switched with the screen's width) may have taken a layer over.
        for layer in hosted where layer.superlayer === self.layer {
            // Keep a mirroring transform (Debug test source) while resizing.
            let transform = layer.transform
            layer.transform = CATransform3DIdentity
            layer.frame = bounds
            layer.transform = transform
        }
        CATransaction.commit()
    }
}

// MARK: - Debug test frames

#if DEBUG
/// Test frames for the Simulator, which has no camera (Debug builds only; `ORBIT_WEBCAM_SYNTHETIC=1`
/// turns it on for a Debug build on a device). Each frame is drawn upright: a red band on top, blue at
/// the bottom, green on the left and yellow on the right, with "ORBIT" and a frame counter, so the
/// PC's copy shows at a glance whether it arrived upright and unmirrored. Frames are portrait while the
/// interface is portrait, like a camera held upright, and reach the pipeline as the camera hands them
/// over: 4:2:0 YCbCr, full range, tagged BT.709.
final class OrbitWebcamSyntheticSource: @unchecked Sendable {
    static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["ORBIT_WEBCAM_SYNTHETIC"] == "1"
        #endif
    }

    let previewLayer = CALayer()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var deliver: ((CVPixelBuffer, CMTime) -> Void)?
    private var settings: OrbitWebcamCaptureSettings?
    private var portrait = false
    // Video queue only.
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var yuvPool: CVPixelBufferPool?
    private var yuvPoolSize = (width: 0, height: 0)
    private var transfer: VTPixelTransferSession?
    private var frameIndex = 0
    /// The parts of a frame that never move, drawn once per size and lens.
    private var background: (key: String, image: CGImage)?
    private var previewing = true
    private var sending = false
    private var orientationObserver: NSObjectProtocol?

    var previewEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return previewing }
        set { lock.lock(); previewing = newValue; lock.unlock() }
    }

    /// Like the camera: frames for the PC only while something is sent (the preview runs either way).
    var sendsFrames: Bool {
        get { lock.lock(); defer { lock.unlock() }; return sending }
        set { lock.lock(); sending = newValue; lock.unlock() }
    }

    init(queue: DispatchQueue) {
        self.queue = queue
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.backgroundColor = UIColor.black.cgColor
        DispatchQueue.main.async { [weak self] in
            self?.readOrientation()
            self?.orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                // The interface rotates a moment after the device.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.readOrientation() }
            }
        }
    }

    deinit {
        timer?.cancel()
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
    }

    private func readOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let isPortrait = scene.map { $0.interfaceOrientation.isPortrait } ?? true
        lock.lock(); portrait = isPortrait; lock.unlock()
    }

    func setDeliver(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) {
        lock.lock(); deliver = handler; lock.unlock()
    }

    func start(_ settings: OrbitWebcamCaptureSettings) {
        lock.lock()
        let unchanged = self.settings == settings && timer != nil
        self.settings = settings
        lock.unlock()
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The real preview mirrors the front camera.
            self.previewLayer.transform = settings.lens == .front ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            CATransaction.commit()
        }
        guard !unchanged else { return }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, settings.fps)), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock()
        let settings = self.settings
        let isPortrait = portrait
        let handler = sending ? deliver : nil
        let showPreview = previewing
        lock.unlock()
        guard let settings else { return }
        let (width, height) = isPortrait ? (settings.resolution.height, settings.resolution.width) : (settings.resolution.width, settings.resolution.height)
        frameIndex += 1
        // The on-screen preview needs far fewer pictures than the PC: about 10 a second.
        let wantsPreview = showPreview && frameIndex % max(1, settings.fps / 10) == 0
        guard handler != nil || wantsPreview else { return }
        guard let (buffer, preview) = draw(width: width, height: height, lens: settings.lens, preview: wantsPreview) else { return }
        if let handler { handler(cameraLike(buffer), CMClockGetTime(CMClockGetHostTimeClock())) }
        if let preview {
            DispatchQueue.main.async { [weak self] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.previewLayer.contents = preview
                CATransaction.commit()
            }
        }
    }

    /// Draws one frame into a pooled buffer (and, when asked, a copy for the preview).
    private func draw(width: Int, height: Int, lens: OrbitWebcamLens, preview: Bool) -> (CVPixelBuffer, CGImage?)? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let cg = Self.context(CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) else { return nil }
        let w = CGFloat(width), h = CGFloat(height), band = min(w, h) * 0.08
        let key = "\(width)x\(height)-\(lens.rawValue)"
        if background?.key != key, let image = Self.staticPicture(width: width, height: height) { background = (key, image) }
        // A CGImage drawn into the unflipped context lands upright, row for row.
        if let image = background?.image { cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        // Top-left origin, like UIKit.
        cg.translateBy(x: 0, y: h)
        cg.scaleBy(x: 1, y: -1)
        // A dot that circles, so motion and frame rate are visible.
        let angle = CGFloat(frameIndex) / 30 * .pi
        let radius = min(w, h) * 0.22
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: w / 2 + cos(angle) * radius - band / 2, y: h / 2 + sin(angle) * radius - band / 2, width: band, height: band))
        UIGraphicsPushContext(cg)
        let caption = NSAttributedString(string: "TEST FRAME \(frameIndex) · \(lens.title.uppercased()) · \(width)×\(height)",
                                         attributes: [.font: UIFont.monospacedSystemFont(ofSize: min(w, h) * 0.04, weight: .semibold), .foregroundColor: UIColor.white])
        caption.draw(at: CGPoint(x: band * 1.5, y: band * 1.4))
        UIGraphicsPopContext()
        return (buffer, preview ? cg.makeImage() : nil)
    }

    /// The drawn frame as the camera would hand it over (the drawn BGRA one if the conversion fails).
    private func cameraLike(_ bgra: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(bgra), height = CVPixelBufferGetHeight(bgra)
        if transfer == nil {
            var created: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created)
            if let created {
                VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
                VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            }
            transfer = created
        }
        if yuvPool == nil || yuvPoolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            yuvPool = created
            yuvPoolSize = (width, height)
        }
        var yuv: CVPixelBuffer?
        guard let transfer, let yuvPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, yuvPool, &yuv) == kCVReturnSuccess, let yuv,
              VTPixelTransferSessionTransferImage(transfer, from: bgra, to: yuv) == noErr else { return bgra }
        return yuv
    }

    private static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Background, the four coloured bands and the title.
    private static func staticPicture(width: Int, height: Int) -> CGImage? {
        guard let cg = context(nil, width: width, height: height, bytesPerRow: 0) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let w = CGFloat(width), h = CGFloat(height), band = min(w, h) * 0.08
        cg.setFillColor(UIColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.setFillColor(UIColor.red.cgColor); cg.fill(CGRect(x: 0, y: 0, width: w, height: band))
        cg.setFillColor(UIColor.blue.cgColor); cg.fill(CGRect(x: 0, y: h - band, width: w, height: band))
        cg.setFillColor(UIColor.green.cgColor); cg.fill(CGRect(x: 0, y: band, width: band, height: h - 2 * band))
        cg.setFillColor(UIColor.yellow.cgColor); cg.fill(CGRect(x: w - band, y: band, width: band, height: h - 2 * band))
        UIGraphicsPushContext(cg)
        let title = NSAttributedString(string: "ORBIT", attributes: [.font: UIFont.systemFont(ofSize: min(w, h) * 0.16, weight: .heavy), .foregroundColor: UIColor.white])
        let titleSize = title.size()
        title.draw(at: CGPoint(x: (w - titleSize.width) / 2, y: h * 0.5 - titleSize.height / 2))
        UIGraphicsPopContext()
        return cg.makeImage()
    }
}
#endif
