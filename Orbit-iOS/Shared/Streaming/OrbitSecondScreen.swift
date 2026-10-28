#if !os(tvOS)
import Combine
import Foundation
import MoonlightCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

// Second Screen (DESIGN F9) on iPhone/iPad and Mac, Moonlight side: the app-wide session wired to this device's
// stream screen, Sunshine hosts as the session uses them, the stream settings a second screen streams with, the
// entry points the screens call, and the guard for normal streams while a second screen runs or was left on.
// The session's logic itself is Foundation only: `OrbitSecondScreenSession` in Shared/OrbitStreamDisplayModels.swift.

extension OrbitSecondScreenSession {
    static let shared = OrbitSecondScreenSession(streams: MoonlightSecondScreenStreams())

    /// The stream settings a second screen uses: Fill Screen at the native size (every pixel of this screen),
    /// Sunshine applying it (Optimize game settings), touches landing where you touch, no HDR. An extra monitor
    /// leaves the PC's sound where it is: it keeps playing on the PC, and this device stays quiet.
    static func streamSettings(from base: MoonlightStreamSettings) -> MoonlightStreamSettings {
        var settings = base
        settings.aspect = .native
        settings.resolution = .native
        settings.optimizeGameSettings = true
        settings.quitAppOnDisconnect = false
        settings.hdr = false
        settings.playAudioOnHost = true
        settings.muteLocalAudio = true
        #if os(iOS)
        settings.touchMode = .touchscreen
        #endif
        return settings
    }

    /// The refresh rate asked of the virtual display: the stream's frame rate.
    static func refreshRate(for settings: MoonlightStreamSettings) -> Int {
        OrbitStreamDisplayAPI.clampedRefreshRate(min(settings.frameRate, max(60, MoonlightDeviceCapabilities.maximumFrameRate)))
    }

    /// The Sunshine app to stream: the one titled Desktop (never another app as a fallback).
    static func desktopApp(in host: MoonlightHostCoordinator) -> MoonlightApp? {
        host.apps.first { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Desktop") == .orderedSame }
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

    /// What keeps Start from running, in plain words (nil: it can start). `host` is the screen's Sunshine host;
    /// while it still belongs to the PC selected before, the screen is still checking.
    func startBlocker(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator, size: OrbitDisplaySize) -> String? {
        let known = context.isDemo || host.configuredPCID == context.pcID
        let facts = known ? HostFacts(isPaired: host.isPaired, reachable: host.reachable, hasDesktopApp: Self.desktopApp(in: host) != nil) : nil
        return startBlocker(context: context, host: facts, size: size)
    }

    /// Start (or Show It Here) from a screen. The session streams through a Sunshine host of its own, a copy of the
    /// screen's: the screen can switch PCs meanwhile without redirecting the session. `onStreamBegan` runs right
    /// after the stream is requested (the Mac opens its Stream window there).
    func start(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator, baseSettings: MoonlightStreamSettings,
               target: MoonlightStreamTarget, position: OrbitSecondScreenPosition, onStreamBegan: @escaping @MainActor () -> Void) {
        guard context.isDemo || host.configuredPCID == context.pcID else { return }
        let settings = Self.streamSettings(from: baseSettings)
        let own = context.isDemo ? host : host.detachedCopy()
        let pcName = context.pcName
        startSession(context: context, host: own, size: target.size.displaySize, refreshRate: Self.refreshRate(for: settings), position: position) { appID in
            guard let app = own.apps.first(where: { $0.id == appID }) else { return false }
            MoonlightStreamController.shared.begin(.init(host: own, app: app, pcName: pcName, settings: settings, target: target, secondScreen: true))
            onStreamBegan()
            return true
        }
    }

    /// Turn Off from a screen; `host` (the screen's Sunshine host, when it belongs to this PC) closes a Desktop
    /// session left running. The session uses a copy of it, like `start`.
    func stop(context: OrbitStreamDisplayContext, host: MoonlightHostCoordinator?) {
        let own = host.flatMap { !context.isDemo && $0.configuredPCID == context.pcID ? $0.detachedCopy() : nil }
        stopSession(context: context, host: own)
    }

    /// Moves the virtual display to the other side while it is on.
    func move(to position: OrbitSecondScreenPosition, context: OrbitStreamDisplayContext, baseSettings: MoonlightStreamSettings) {
        move(to: position, context: context, refreshRate: Self.refreshRate(for: Self.streamSettings(from: baseSettings)))
    }
}

/// The stream screen as the second screen session sees it: `MoonlightStreamController.shared`.
@MainActor
final class MoonlightSecondScreenStreams: OrbitSecondScreenStreams {
    var onPresentationChange: (@MainActor (Bool) -> Void)?
    private var subscription: AnyCancellable?

    init() {
        // Read on the next turn, after the controller has changed.
        subscription = MoonlightStreamController.shared.$isPresented
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] presented in
                MainActor.assumeIsolated { self?.onPresentationChange?(presented) }
            }
    }

    var otherStreamIsOpen: Bool {
        let controller = MoonlightStreamController.shared
        return controller.isPresented && controller.request?.secondScreen != true
    }

    var secondScreenIsOpen: Bool {
        let controller = MoonlightStreamController.shared
        return controller.isPresented && controller.request?.secondScreen == true
    }

    func endSecondScreen() {
        guard secondScreenIsOpen else { return }
        MoonlightStreamController.shared.end(quitApp: false)
    }
}

extension MoonlightHostCoordinator: OrbitSecondScreenHost {
    var desktopAppID: Int? { OrbitSecondScreenSession.desktopApp(in: self)?.id }

    var runningAppID: Int? {
        guard let current = info?.currentGame, current > 0 else { return nil }
        return current
    }
}

// MARK: - Normal streams while a second screen runs or was left on

/// A normal stream that has to wait for (or be confirmed because of) Second Screen. `start` begins it.
struct OrbitSecondScreenStreamCheck: Identifiable {
    let id = UUID()
    let check: OrbitSecondScreenSession.StreamCheck
    let start: () -> Void

    /// Nil when the stream can begin right away.
    @MainActor
    init?(pcID: String, start: @escaping () -> Void) {
        let check = OrbitSecondScreenSession.shared.checkNormalStream(pcID: pcID)
        guard check != .go else { return nil }
        self.check = check
        self.start = start
    }
}

private struct OrbitSecondScreenStreamGuard: ViewModifier {
    @Binding var pending: OrbitSecondScreenStreamCheck?
    let context: OrbitStreamDisplayContext
    let host: MoonlightHostCoordinator?
    @ObservedObject private var session = OrbitSecondScreenSession.shared

    private var thisDevice: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private var leftOn: Bool { pending?.check == .leftOn }

    private var refusal: String {
        let name = session.sessionPCName
        switch pending?.check {
        case .starting?: return "Orbit is turning on the second screen for \(name). Turn it off first to stream something else."
        case .stopping?: return "Orbit is turning off the second screen for \(name). Try again in a moment."
        default:
            #if os(macOS)
            return "This Mac is a second screen for \(name). Stop it first: Control-Option-Shift-Q in the Stream window, or Turn Off in Second Screen."
            #else
            return "This \(thisDevice) is a second screen for \(name). Stop it first: tap with three fingers and end the stream, or Turn Off in Tools › Second Screen."
            #endif
        }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Second Screen is still on for \(context.pcName)", isPresented: Binding(
                get: { leftOn }, set: { if !$0, leftOn { pending = nil } }), titleVisibility: .visible, presenting: pending) { request in
                if session.canTurnOff(context.pcID) {
                    Button("Turn Off Second Screen") { session.stop(context: context, host: host) }
                }
                Button("Stream Anyway") {
                    // After the dialog has gone: the stream screen is presented from the app's root.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        request.start()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Until it's turned off, streams from \(context.pcName) show its extra virtual display, not the main monitor.")
            }
            .alert("Second Screen", isPresented: Binding(get: { pending != nil && !leftOn }, set: { if !$0, !leftOn { pending = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refusal)
            }
    }
}

extension View {
    /// Shows what `OrbitSecondScreenStreamCheck` found: a refusal while a second screen runs here, or the choice
    /// to turn a second screen left on off first.
    func secondScreenStreamGuard(_ pending: Binding<OrbitSecondScreenStreamCheck?>, context: OrbitStreamDisplayContext,
                                 host: MoonlightHostCoordinator?) -> some View {
        modifier(OrbitSecondScreenStreamGuard(pending: pending, context: context, host: host))
    }
}
#endif
