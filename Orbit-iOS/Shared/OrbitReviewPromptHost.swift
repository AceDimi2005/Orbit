#if os(iOS) || os(macOS)
import StoreKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The StoreKit side of the rating prompt (rules in OrbitReviewPrompt.swift): the root view hands its
// `requestReview` action and its list of blockers to `OrbitReviewPrompter.shared`, screens that must not be
// interrupted pause it, and the days are counted each time Orbit comes to the front.

extension View {
    /// On the root view of the window that shows the rating prompt. `blockers` names what the app has on screen
    /// that the prompt must not interrupt; alerts and Orbit being in the background are checked here.
    func orbitReviewPromptHost(blockers: @escaping @MainActor () -> Set<OrbitReviewPromptBlocker>) -> some View {
        modifier(OrbitReviewPromptHostModifier(blockers: blockers))
    }

    /// No rating prompt while this view is on screen (the Orbit Pro paywall).
    func orbitPausesReviewPrompt(_ blocker: OrbitReviewPromptBlocker) -> some View {
        modifier(OrbitReviewPromptPause(blocker: blocker))
    }
}

private struct OrbitReviewPromptHostModifier: ViewModifier {
    let blockers: @MainActor () -> Set<OrbitReviewPromptBlocker>
    @Environment(\.requestReview) private var requestReview
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                let prompter = OrbitReviewPrompter.shared
                let appBlockers = blockers
                prompter.blockers = { appBlockers().union(OrbitReviewPromptScreen.blockers()) }
                let action = requestReview
                prompter.attachPresenter(id) { action() }
                OrbitReviewPromptScreen.startCountingDays()
                #if DEBUG
                OrbitReviewPromptScreen.runSelfTestIfAsked()
                #endif
            }
            .onDisappear { OrbitReviewPrompter.shared.detachPresenter(id) }
    }
}

private struct OrbitReviewPromptPause: ViewModifier {
    let blocker: OrbitReviewPromptBlocker
    @State private var isPausing = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isPausing else { return }
                isPausing = true
                OrbitReviewPrompter.shared.pause(blocker)
            }
            .onDisappear {
                guard isPausing else { return }
                isPausing = false
                OrbitReviewPrompter.shared.resume(blocker)
            }
    }
}

/// What the platform knows about the screen, and the day counter.
@MainActor
enum OrbitReviewPromptScreen {
    private static var activationObserver: NSObjectProtocol?

    /// Counts today when Orbit is in front now, and every day it comes to the front later. Launches in the
    /// background (refresh, notifications, widgets) never count.
    static func startCountingDays() {
        if activationObserver == nil {
            #if os(iOS)
            let name = UIApplication.didBecomeActiveNotification
            #else
            let name = NSApplication.didBecomeActiveNotification
            #endif
            activationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { OrbitReviewPrompter.shared.appOpened() }
            }
        }
        if isInFront { OrbitReviewPrompter.shared.appOpened() }
    }

    static func blockers() -> Set<OrbitReviewPromptBlocker> {
        var result = Set<OrbitReviewPromptBlocker>()
        if !isInFront { result.insert(.notInFront) }
        if isShowingAlert { result.insert(.alert) }
        return result
    }

    private static var isInFront: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApp?.isActive == true
        #endif
    }

    /// SwiftUI alerts and confirmation dialogs are UIAlertControllers on iOS; on the Mac they, and sheets such
    /// as the paywall, are attached to their window.
    private static var isShowingAlert: Bool {
        #if os(iOS)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var presented = window.rootViewController?.presentedViewController
                while let controller = presented {
                    if controller is UIAlertController { return true }
                    presented = controller.presentedViewController
                }
            }
        }
        return false
        #else
        guard let app = NSApp else { return false }
        return app.modalWindow != nil || app.windows.contains { $0.isVisible && $0.attachedSheet != nil }
        #endif
    }

    #if DEBUG
    private static var ranSelfTest = false

    /// `ORBIT_REVIEW_PROMPT_SELFTEST=1` (in the simulator `SIMCTL_CHILD_ORBIT_REVIEW_PROMPT_SELFTEST`) checks the
    /// prompt without a PC: 4 seconds after launch it prints what blocks it, plays a good moment, and 4 seconds
    /// later prints whether StoreKit was asked. `ORBIT_REVIEW_PROMPT_DAYS=n` first sets the day count to n.
    static func runSelfTestIfAsked() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ORBIT_REVIEW_PROMPT_SELFTEST"] != nil, !ranSelfTest else { return }
        ranSelfTest = true
        let storage = OrbitReviewPromptDefaultsStorage()
        if let days = environment["ORBIT_REVIEW_PROMPT_DAYS"].flatMap(Int.init) {
            var record = storage.load()
            record.activeDays = days
            storage.save(record)
        }
        // Unbuffered: `simctl launch --stdout=<file>` would otherwise only get the lines when the app exits.
        func say(_ line: String) { FileHandle.standardOutput.write(Data(("review prompt self-test: " + line + "\n").utf8)) }
        Task { @MainActor in
            let prompter = OrbitReviewPrompter.shared
            try? await Task.sleep(for: .seconds(4))
            let before = storage.load()
            say("days \(before.activeDays), asked \(before.lastRequestVersion ?? "never"), " +
                "blockers \(prompter.currentBlockers().map(\.rawValue).sorted()), decision \(prompter.decision())")
            prompter.noteGoodMoment(.connected)
            try? await Task.sleep(for: .seconds(4))
            let after = storage.load()
            say("StoreKit asked: \(after.lastRequestDate != before.lastRequestDate) (version \(after.lastRequestVersion ?? "none"))")
        }
    }
    #endif
}
#endif
