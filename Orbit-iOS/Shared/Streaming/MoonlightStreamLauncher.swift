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

    /// Launches (or resumes) `app` on the host at `size` (kept within H.264's limit when the host no longer
    /// offers HEVC) and returns what the engine needs to connect, including the size actually requested.
    /// When another app is running, `quitRunningApp` decides whether to end it first.
    func prepareStream(app: MoonlightApp, settings: MoonlightStreamSettings, size: MoonlightStreamSize, quitRunningApp: Bool) async throws -> MoonlightConnectionParameters {
        do {
            return try await launchForStream(app: app, settings: settings, size: size, quitRunningApp: quitRunningApp)
        } catch let error as MoonlightError where error.untrusted {
            pairingWasRefused(error)
            throw error
        }
    }

    private func launchForStream(app: MoonlightApp, settings: MoonlightStreamSettings, size: MoonlightStreamSize, quitRunningApp: Bool) async throws -> MoonlightConnectionParameters {
        // The PC's LAN address, or its secondary address (for example Tailscale) when only that answers; the stream uses it too.
        let (transport, info, hostAddress) = try await streamingConnection()
        // `size` was chosen from what the host reported earlier. One that has stopped offering HEVC since then
        // streams H.264, which ends at 4096 pixels per side; `/launch` and the session both get the result.
        let streamSize = MoonlightStreamSettings.size(size, forHostSupportingHEVC: info.supportsHEVC)
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
        let result = try await MoonlightClient.launch(transport, appID: app.id, settings: settings, size: streamSize, remoteInputKey: key, remoteInputKeyID: keyID, resume: resume)
        Task { await refresh() }
        return MoonlightConnectionParameters(
            address: hostAddress, appVersion: info.appVersion, gfeVersion: info.gfeVersion, rtspSessionURL: result.rtspSessionURL,
            serverCodecModeSupport: Int32(truncatingIfNeeded: info.serverCodecModeSupport),
            remoteInputKey: key, remoteInputKeyID: keyID, appName: app.title, hostName: hostDisplayName, streamSize: streamSize
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
        let size = MoonlightStreamTarget.make(settings: fast, hostSupportsHEVC: hostSupportsHEVC).size
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

    /// Enter (leaves the lock screen's clock), the password as keystrokes, Enter. Used by the headless
    /// unlock above, the "Unlock PC" stream (`MoonlightStreamController`) and the in-stream unlock sheet.
    @MainActor
    static func typeSignIn(_ password: String, into session: MoonlightStreamSession) async throws {
        session.tapKey(virtualKey: MoonlightVirtualKey.enter)   // leave the lock screen's clock
        try await Task.sleep(nanoseconds: 1_200_000_000)
        session.sendText(password)
        try await Task.sleep(nanoseconds: 400_000_000)
        session.tapKey(virtualKey: MoonlightVirtualKey.enter)
    }
}

/// The Windows password of an "Unlock PC" stream, on its way to the sign-in screen. It lives only in
/// memory, in this one object that every copy of the stream request shares: `take()` hands it out once
/// and forgets it, and the controller discards it as soon as the stream fails or ends. It is never
/// stored, logged or sent anywhere but as keystrokes through the stream (Windows' secure desktop
/// accepts nothing else, so never through the agent's keyboard API).
@MainActor
final class MoonlightSignInSecret {
    private var password: String?

    init(password: String) { self.password = password.isEmpty ? nil : password }

    var isPending: Bool { password != nil }

    func take() -> String? {
        defer { password = nil }
        return password
    }

    func discard() { password = nil }
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
        /// The PC sits at its lock screen: the overlay offers "Unlock PC", and without `signIn` the
        /// sign-in prompt opens as soon as the stream runs.
        var promptUnlock = false
        /// "Unlock PC": the password asked for before the stream started, typed automatically once it
        /// runs. Shared by every copy of the request and cleared after typing or when the stream fails.
        let signIn: MoonlightSignInSecret?

        /// `target` defaults to this device's screen (the Mac: the display in front).
        @MainActor
        init(host: MoonlightHostCoordinator, app: MoonlightApp, pcName: String, settings: MoonlightStreamSettings,
             target: MoonlightStreamTarget? = nil, quitRunningApp: Bool = false, promptUnlock: Bool = false,
             signIn: MoonlightSignInSecret? = nil) {
            self.host = host
            self.app = app
            self.pcName = pcName
            self.settings = settings
            self.target = target ?? MoonlightStreamTarget.make(settings: settings, hostSupportsHEVC: host.hostSupportsHEVC)
            self.quitRunningApp = quitRunningApp
            self.promptUnlock = promptUnlock || signIn != nil
            self.signIn = signIn
        }
    }

    /// Automatic sign-in of an "Unlock PC" stream.
    enum SignInState: Equatable {
        /// Nothing to type for this stream.
        case none
        /// The password waits in memory until the stream runs.
        case waiting
        /// Enter · password · Enter are on their way.
        case typing
        /// Typed; the password is gone.
        case sent
        /// The stream failed or ended before the password could be typed. It was not sent and is gone.
        case dropped
    }

    @Published var isPresented = false
    /// Mirrors the agent's `sessionLocked`, so the stream overlay can offer "Unlock PC".
    @Published var pcLocked = false
    @Published private(set) var request: Request?
    @Published private(set) var session: MoonlightStreamSession?
    @Published private(set) var launchError: String?
    @Published private(set) var busyError: MoonlightStreamBusyError?
    @Published private(set) var isLaunching = false
    /// Where the automatic sign-in of an "Unlock PC" stream stands.
    @Published private(set) var signInState: SignInState = .none

    private var launchTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?

    /// Starts the launch request and presents the stream screen. With `present: false` the screen
    /// waits for `presentPendingStream()`: a sheet that started the stream (the "Unlock PC" prompt)
    /// calls it once it has closed, so the launch runs while the sheet animates away.
    func begin(_ request: Request, present: Bool = true) {
        if let session, session.isActive { session.stop() }
        signInTask?.cancel()
        signInTask = nil
        if let previous = self.request?.signIn, previous !== request.signIn { previous.discard() }
        self.request = request
        session = nil
        launchError = nil
        busyError = nil
        signInState = request.signIn?.isPending == true ? .waiting : .none
        if present {
            isPresented = true
        } else {
            // Never leave a requested stream unseen, whatever happens to the sheet.
            let id = request.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.request?.id == id else { return }
                self.presentPendingStream()
            }
        }
        launch()
    }

    /// Presents a stream that `begin(_:present: false)` started.
    func presentPendingStream() {
        guard request != nil, !isPresented else { return }
        isPresented = true
    }

    func retry() {
        launchError = nil
        busyError = nil
        signInTask?.cancel()
        signInTask = nil
        session = nil
        // "Quit it and stream" after a busy host keeps the password; after a failure it is gone.
        if request?.signIn?.isPending == true { signInState = .waiting }
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
                if let secret = request.signIn, secret.isPending { self.typeSignInWhenStreaming(secret, session: session, requestID: request.id) }
                session.start(parameters: parameters, settings: request.settings)
            } catch let error as MoonlightStreamBusyError {
                // The user decides next ("Quit it and stream", "Watch it instead", Cancel); the password waits.
                self?.busyError = error
            } catch {
                guard !Task.isCancelled else { return }
                self?.dropSignIn()
                self?.launchError = (error as? MoonlightError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Types the password once `session` streams (Windows then shows its sign-in screen), or drops it
    /// when the session fails or ends first.
    private func typeSignInWhenStreaming(_ secret: MoonlightSignInSecret, session: MoonlightStreamSession, requestID: UUID) {
        signInTask?.cancel()
        signInState = .waiting
        signInTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.request?.id == requestID, self.session === session else { secret.discard(); return }
                switch session.phase {
                case .streaming:
                    self.signInState = .typing
                    // Let the first frames arrive and the input channel settle before the first key.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, session.phase == .streaming, let password = secret.take() else {
                        if !Task.isCancelled { self.dropSignIn() }
                        return
                    }
                    do {
                        try await MoonlightHostCoordinator.typeSignIn(password, into: session)
                        self.signInState = .sent
                    } catch {
                        // Cancelled while typing: the stream ended or was closed.
                        if self.signInState == .typing { self.signInState = .dropped }
                    }
                    return
                case .failed, .ended:
                    self.dropSignIn()
                    return
                default:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// The stream failed before the password was typed: forget it, and say so.
    private func dropSignIn() {
        guard let secret = request?.signIn else { return }
        secret.discard()
        if signInState == .waiting || signInState == .typing { signInState = .dropped }
    }

    /// Instead of quitting the running app, stream it.
    func streamRunningAppInstead() {
        guard let busyError, let request, let running = request.host.apps.first(where: { $0.id == busyError.runningAppID }) else { return }
        self.request = Request(host: request.host, app: running, pcName: request.pcName, settings: request.settings, target: request.target,
                               quitRunningApp: false, promptUnlock: request.promptUnlock, signIn: request.signIn)
        retry()
    }

    /// Ends the stream; optionally asks Sunshine to quit the app too.
    func end(quitApp: Bool) {
        launchTask?.cancel()
        launchTask = nil
        signInTask?.cancel()
        signInTask = nil
        request?.signIn?.discard()
        signInState = .none
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
