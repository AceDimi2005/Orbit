import Combine
import Foundation
import MoonlightCore
#if os(macOS)
import AppKit
#endif

// Sunshine side of starting a stream: the HTTPS launch/resume request and the parameters the
// MoonlightCore engine needs afterwards. Pairing and app lists live in MoonlightClient.swift.

/// The frame a stream asks for, decided once when the stream is requested. The `/launch` mode and the
/// session's video configuration both use it, so they agree even if the screen changes in between (the
/// launch request can take seconds, and on the Mac the Stream window opens after it was sent).
struct MoonlightStreamTarget: Equatable {
    var size: MoonlightStreamSize
    /// macOS: the display `size` was measured on; the Stream window goes full screen there.
    var displayID: UInt32?

    /// iPhone and iPad: the whole panel (`UIScreen.nativeBounds`). Apple TV: its 16:9 output mode.
    /// Mac: the full-screen area of the display in front.
    @MainActor
    static func make(settings: MoonlightStreamSettings, hostSupportsHEVC: Bool?) -> MoonlightStreamTarget {
        #if os(macOS)
        return make(settings: settings, hostSupportsHEVC: hostSupportsHEVC, screen: NSApp.keyWindow?.screen ?? NSScreen.main)
        #else
        return MoonlightStreamTarget(size: settings.streamSize(native: MoonlightDeviceCapabilities.nativePixelSize, hostSupportsHEVC: hostSupportsHEVC))
        #endif
    }

    #if os(macOS)
    /// Sized for what a full-screen window covers on `screen` (below the notch, in physical pixels).
    @MainActor
    static func make(settings: MoonlightStreamSettings, hostSupportsHEVC: Bool?, screen: NSScreen?) -> MoonlightStreamTarget {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return MoonlightStreamTarget(size: settings.streamSize(native: .zero, hostSupportsHEVC: hostSupportsHEVC))
        }
        return MoonlightStreamTarget(size: settings.streamSize(native: MoonlightDeviceCapabilities.nativePixelSize(of: screen), hostSupportsHEVC: hostSupportsHEVC),
                                     displayID: MoonlightDeviceCapabilities.displayID(of: screen))
    }
    #endif
}

/// Another app is already running on the host.
struct MoonlightStreamBusyError: LocalizedError {
    let runningAppID: Int
    let runningTitle: String?
    var errorDescription: String? { "\(runningTitle ?? "Another app") is already running on the PC." }
}

extension MoonlightClient {
    struct LaunchResult {
        var rtspSessionURL: String?
        var resumed: Bool
    }

    /// `/launch` or `/resume`. Sunshine blocks until the app has started, so the timeout is long.
    static func launch(_ transport: MoonlightTransport, appID: Int, settings: MoonlightStreamSettings, size: MoonlightStreamSize,
                       remoteInputKey: Data, remoteInputKeyID: UInt32, resume: Bool) async throws -> LaunchResult {
        let configuration = Int(settings.audio.configuration)
        let surroundInfo = ((configuration >> 16) & 0xFFFF) << 16 | ((configuration >> 8) & 0xFF)
        var query: [(String, String)] = [
            ("appid", String(appID)),
            ("mode", "\(size.width)x\(size.height)x\(settings.frameRate)"),
            ("additionalStates", "1"),
            ("sops", settings.optimizeGameSettings ? "1" : "0"),
            ("rikey", MoonlightEncoding.hex(remoteInputKey)),
            ("rikeyid", String(remoteInputKeyID)),
            ("localAudioPlayMode", settings.playAudioOnHost ? "1" : "0"),
            ("surroundAudioInfo", String(surroundInfo)),
            ("remoteControllersBitmap", "0"),
            ("gcmap", "0"),
            ("gcpersist", "0"),
            ("corever", "1"),
        ]
        if settings.requestsHDR {
            query += [("hdrMode", "1"), ("clientHdrCapVersion", "0"), ("clientHdrCapSupportedFlagsInUint32", "0"),
                      ("clientHdrCapMetaDataId", "NV_STATIC_METADATA_TYPE_1"), ("clientHdrCapDisplayData", "0x0x0x0x0x0x0x0x0x0x0")]
        }
        let node = try await transport.xml(secure: true, path: resume ? "/resume" : "/launch", query: query, timeout: 120)
        let flag = resume ? node.value("resume") : node.value("gamesession")
        guard let flag, flag != "0" else {
            throw MoonlightError(message: resume ? "Sunshine could not resume the running app." : "Sunshine could not start the app. Check its command in the Sunshine web UI.")
        }
        return LaunchResult(rtspSessionURL: node.value("sessionUrl0"), resumed: resume)
    }
}

extension MoonlightHostCoordinator {
    /// Target for the "Stream PC" button: Sunshine's Desktop entry, else the first app.
    var desktopApp: MoonlightApp? {
        apps.first { $0.title.caseInsensitiveCompare("Desktop") == .orderedSame } ?? apps.first
    }

    /// Launches (or resumes) `app` on the host at `size` and returns what the engine needs to connect,
    /// including that size. When another app is running, `quitRunningApp` decides whether to end it first.
    func prepareStream(app: MoonlightApp, settings: MoonlightStreamSettings, size: MoonlightStreamSize, quitRunningApp: Bool) async throws -> MoonlightConnectionParameters {
        do {
            return try await launchForStream(app: app, settings: settings, size: size, quitRunningApp: quitRunningApp)
        } catch let error as MoonlightError where error.untrusted {
            pairingWasRefused(error)
            throw error
        }
    }

    private func launchForStream(app: MoonlightApp, settings: MoonlightStreamSettings, size: MoonlightStreamSize, quitRunningApp: Bool) async throws -> MoonlightConnectionParameters {
        let transport = try await streamingTransport()
        let info = try await MoonlightClient.serverInfo(transport, secure: true)
        var resume = false
        if info.currentGame != 0 {
            if info.currentGame == app.id {
                resume = true
            } else if quitRunningApp {
                try await MoonlightClient.quit(transport)
                try await Task.sleep(nanoseconds: 800_000_000)
            } else {
                throw MoonlightStreamBusyError(runningAppID: info.currentGame, runningTitle: apps.first { $0.id == info.currentGame }?.title)
            }
        }
        let key = MoonlightCrypto.random(16)
        let keyID = UInt32.random(in: 1..<UInt32(Int32.max))
        let result = try await MoonlightClient.launch(transport, appID: app.id, settings: settings, size: size, remoteInputKey: key, remoteInputKeyID: keyID, resume: resume)
        Task { await refresh() }
        return MoonlightConnectionParameters(
            address: address, appVersion: info.appVersion, gfeVersion: info.gfeVersion, rtspSessionURL: result.rtspSessionURL,
            serverCodecModeSupport: Int32(truncatingIfNeeded: info.serverCodecModeSupport),
            remoteInputKey: key, remoteInputKeyID: keyID, appName: app.title, hostName: hostDisplayName, streamSize: size
        )
    }
}

extension MoonlightHostCoordinator {
    /// Signs in to a PC that sits at its lock screen without showing any video: a short headless
    /// stream session carries Enter, the password as keystrokes and Enter again, then ends. Used by
    /// the Apple Watch (through the iPhone), which has no stream of its own. The password only
    /// lives in memory for the duration of the call.
    @MainActor
    func unlockThroughStream(password: String, settings: MoonlightStreamSettings, timeout: TimeInterval = 25) async throws {
        guard !password.isEmpty else { throw MoonlightError(message: "Enter the Windows password.") }
        if apps.isEmpty { await refresh() }
        guard let app = desktopApp else { throw MoonlightError(message: "Sunshine publishes no app to open the sign-in screen with.") }
        let controller = MoonlightStreamController.shared
        if let live = controller.session, live.isActive, live.phase == .streaming {
            // A visible stream is already running: type into it instead of opening a second session.
            try await Self.typeSignIn(password, into: live)
            return
        }
        guard controller.session == nil || controller.session?.isActive != true else {
            throw MoonlightError(message: "A stream is starting right now; try again in a moment.")
        }
        var fast = settings
        fast.hdr = false
        fast.framePacing = false
        let size = MoonlightStreamTarget.make(settings: fast, hostSupportsHEVC: info?.supportsHEVC).size
        let parameters = try await prepareStream(app: app, settings: fast, size: size, quitRunningApp: false)
        let session = MoonlightStreamSession(settings: fast)
        session.start(parameters: parameters, settings: fast, headless: true)
        defer { session.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while session.phase != .streaming {
            if case .failed(let message) = session.phase { throw MoonlightError(message: message) }
            if case .ended(let message) = session.phase { throw MoonlightError(message: message ?? "The connection ended before signing in.") }
            guard Date() < deadline else { throw MoonlightError(message: "The PC did not answer in time.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Self.typeSignIn(password, into: session)
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    @MainActor
    private static func typeSignIn(_ password: String, into session: MoonlightStreamSession) async throws {
        session.tapKey(virtualKey: MoonlightVirtualKey.enter)   // leave the lock screen's clock
        try await Task.sleep(nanoseconds: 1_200_000_000)
        session.sendText(password)
        try await Task.sleep(nanoseconds: 400_000_000)
        session.tapKey(virtualKey: MoonlightVirtualKey.enter)
    }
}

/// App-wide stream state: one request at a time, presented full screen by the root view.
@MainActor
final class MoonlightStreamController: ObservableObject {
    static let shared = MoonlightStreamController()

    struct Request: Identifiable {
        let id = UUID()
        let host: MoonlightHostCoordinator
        let app: MoonlightApp
        let pcName: String
        var settings: MoonlightStreamSettings
        /// Size (and on the Mac, display) of this stream, decided once here. Retries and "watch it instead"
        /// keep it, so `/launch` and the session never disagree.
        let target: MoonlightStreamTarget
        var quitRunningApp = false
        /// Open the sign-in prompt as soon as the stream runs (the PC sits at its lock screen).
        var promptUnlock = false

        /// `target` defaults to this device's screen (the Mac: the display in front).
        @MainActor
        init(host: MoonlightHostCoordinator, app: MoonlightApp, pcName: String, settings: MoonlightStreamSettings,
             target: MoonlightStreamTarget? = nil, quitRunningApp: Bool = false, promptUnlock: Bool = false) {
            self.host = host
            self.app = app
            self.pcName = pcName
            self.settings = settings
            self.target = target ?? MoonlightStreamTarget.make(settings: settings, hostSupportsHEVC: host.info?.supportsHEVC)
            self.quitRunningApp = quitRunningApp
            self.promptUnlock = promptUnlock
        }
    }

    @Published var isPresented = false
    /// Mirrors the agent's `sessionLocked`, so the stream overlay can offer "Unlock PC".
    @Published var pcLocked = false
    @Published private(set) var request: Request?
    @Published private(set) var session: MoonlightStreamSession?
    @Published private(set) var launchError: String?
    @Published private(set) var busyError: MoonlightStreamBusyError?
    @Published private(set) var isLaunching = false

    private var launchTask: Task<Void, Never>?

    /// Starts the launch request and presents the stream screen.
    func begin(_ request: Request) {
        if let session, session.isActive { session.stop() }
        self.request = request
        session = nil
        launchError = nil
        busyError = nil
        isPresented = true
        launch()
    }

    func retry() {
        launchError = nil
        busyError = nil
        session = nil
        launch()
    }

    /// The user confirmed ending whatever runs on the host so this app can start.
    func quitRunningAppAndLaunch() {
        request?.quitRunningApp = true
        retry()
    }

    private func launch() {
        guard let request else { return }
        launchTask?.cancel()
        isLaunching = true
        launchTask = Task { [weak self] in
            defer { self?.isLaunching = false }
            do {
                let parameters = try await request.host.prepareStream(app: request.app, settings: request.settings, size: request.target.size,
                                                                      quitRunningApp: request.quitRunningApp)
                guard let self, !Task.isCancelled, self.request?.id == request.id else { return }
                let session = MoonlightStreamSession(settings: request.settings)
                self.session = session
                session.start(parameters: parameters, settings: request.settings)
            } catch let error as MoonlightStreamBusyError {
                self?.busyError = error
            } catch {
                guard !Task.isCancelled else { return }
                self?.launchError = (error as? MoonlightError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Instead of quitting the running app, stream it.
    func streamRunningAppInstead() {
        guard let busyError, let request, let running = request.host.apps.first(where: { $0.id == busyError.runningAppID }) else { return }
        self.request = Request(host: request.host, app: running, pcName: request.pcName, settings: request.settings, target: request.target, quitRunningApp: false)
        retry()
    }

    /// Ends the stream; optionally asks Sunshine to quit the app too.
    func end(quitApp: Bool) {
        launchTask?.cancel()
        launchTask = nil
        let host = request?.host
        let shouldQuit = quitApp || (request?.settings.quitAppOnDisconnect ?? false)
        session?.stop()
        if shouldQuit, let host { Task { await host.quitRunningApp() } }
        isPresented = false
        session = nil
        request = nil
        launchError = nil
        busyError = nil
    }
}
