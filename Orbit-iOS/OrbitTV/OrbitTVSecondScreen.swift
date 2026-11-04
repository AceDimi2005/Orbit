import MoonlightCore
import SwiftUI
import UIKit

// Second Screen on Apple TV (DESIGN F9, Orbit Pro, Labs): Controls › Second Screen. The PC gets a virtual display at
// the TV's output size (1080p or 4K) next to its monitor, and Orbit streams it here; the Siri Remote moves the PC's
// pointer. Ending the stream (Menu) turns the virtual display off again. The session, the PC calls and every check
// are shared with iPhone, iPad and Mac (`OrbitSecondScreenSession`, Shared/OrbitStreamDisplay*.swift); only the views
// are the TV's. Apple TV always streams 16:9, so it has no Fill Screen setup.

extension OrbitTVViewModel {
    /// The selected PC, for Second Screen. Demo mode is a PC of its own ("demo"), so the sample state never mixes with
    /// what the paired PC reported.
    var streamDisplayContext: OrbitStreamDisplayContext {
        let pc = currentPC
        let name = isDemoMode ? metrics.hostname : (pc?.name ?? metrics.hostname)
        return OrbitStreamDisplayContext(pcID: isDemoMode ? "demo" : (pc?.id ?? ""), pcName: name.isEmpty ? "your PC" : name,
                                         isDemo: isDemoMode, isOnline: metrics.isOnline, hasPC: isDemoMode || pc != nil,
                                         canStartSunshine: sunshineInfo?.canStart ?? false, makeClient: { try self.client() })
    }
}

struct TVLabsBadge: View {
    var body: some View {
        Text("LABS")
            .font(.system(size: 13, weight: .heavy))
            .tracking(1)
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(TVPalette.accent, in: Capsule())
            .accessibilityLabel("Labs feature")
    }
}

// MARK: - Controls tab entry

/// The Controls tab's entry point. It also warns while the PC still has the second screen on although this Apple TV
/// does not stream it (left on by a stream that ended without turning it off, or by another device): every stream from
/// it then shows the extra display. Turn Off here is never Pro-gated: it only undoes Orbit's change.
struct TVSecondScreenCard: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    /// The Controls tab's Sunshine host: Turn Off closes a Desktop session left running with it.
    let host: MoonlightHostCoordinator
    var onOpen: () -> Void
    @ObservedObject private var session = OrbitSecondScreenSession.shared

    private var context: OrbitStreamDisplayContext { vm.streamDisplayContext }
    private var pcID: String { context.pcID }
    private var pcName: String { context.pcName }
    private var leftOn: Bool { session.isLeftOn(pcID) && (context.isOnline || context.isDemo) }
    private var stoppingHere: Bool {
        if case .stopping = session.phase, session.sessionPCID == pcID { return true }
        return false
    }

    private var pill: (text: String, tint: Color)? {
        if session.isStreaming { return ("ON", TVPalette.accent) }
        if session.isBusy { return ("WORKING…", TVPalette.accent) }
        if session.isActiveOnPC(pcID) { return (leftOn ? "STILL ON" : "ON", leftOn ? TVPalette.amber : TVPalette.accent) }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(leftOn ? TVPalette.amber.opacity(0.22) : Color.white.opacity(0.08))
                    .frame(width: 76, height: 76)
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(leftOn ? TVPalette.amber : TVPalette.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Use this Apple TV as a second screen")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    TVLabsBadge()
                    if let pill { TVStatusPill(text: pill.text, tint: pill.tint) }
                }
                if stoppingHere {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Turning off the second screen on \(session.sessionPCName)…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else if leftOn {
                    Text("Second Screen is still on for \(pcName). Until it's turned off, streams from \(pcName) show its extra virtual display, not the main monitor.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TVPalette.amber)
                        .lineLimit(2)
                    if let problem = session.problem, session.sessionPCID == nil || session.sessionPCID == pcID {
                        Text("\(problem.title): \(problem.message)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TVPalette.amber)
                            .lineLimit(2)
                    }
                } else {
                    Text("Windows gets a new monitor next to its own, streamed here at the TV's size. The Siri Remote moves the PC's pointer. Orbit Pro.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if leftOn {
                Button { session.stop(context: context, host: host) } label: { Label("Turn Off", systemImage: "power") }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.amber, isProminent: true))
                    .disabled(!session.canTurnOff(pcID))
                    .accessibilityHint("Turns the virtual display on \(pcName) off and puts Sunshine's display settings back")
            }
            Button(action: onOpen) { Label("Second Screen", systemImage: "rectangle.on.rectangle") }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: !leftOn))
                .accessibilityHint("Use this Apple TV as a second screen for \(pcName) (Orbit Pro, Labs)")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: leftOn ? TVPalette.amber : TVPalette.accent)
        .focusSection()
        .task(id: context.identity) { await session.checkIfLeftOn(context: context) }
    }
}

// MARK: - The page

/// Requirements, side, Start / Turn Off. Presented full screen from the Controls tab: when the stream begins it closes
/// (`onStreamBegan`) and the tab presents the stream once the page has gone.
struct TVSecondScreenSheet: View {
    @EnvironmentObject var vm: OrbitTVViewModel
    @ObservedObject var host: MoonlightHostCoordinator
    /// Closes the page and pairs Orbit with Sunshine on the Controls tab.
    var onPair: () -> Void
    /// The second screen's stream was requested: close the page so the stream can show.
    var onStreamBegan: () -> Void
    var onClose: () -> Void
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @ObservedObject private var store = OrbitProStore.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @AppStorage(OrbitSecondScreenPosition.storageKey) private var positionRaw = OrbitSecondScreenPosition.right.rawValue
    @AppStorage(OrbitSecondScreenScaleTip.dismissedKey) private var scaleTipDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var focusSpace
    @State private var confirmStop = false
    @State private var confirmRevert = false
    @State private var showsPaywall = false
    @State private var savingLogin = false
    @State private var loginMessage: String?
    @State private var loginFailed = false
    @State private var quittingApp = false
    @FocusState fileprivate var readingHowItWorks: Bool

    private var context: OrbitStreamDisplayContext { vm.streamDisplayContext }
    private var pcName: String { context.pcName }
    private var position: OrbitSecondScreenPosition { OrbitSecondScreenPosition(rawValue: positionRaw) ?? .right }
    private var settingsForScreen: MoonlightStreamSettings { OrbitSecondScreenSession.streamSettings(from: streamSettings.settings) }
    /// The TV's output mode (Apple TV always streams 16:9, so this is 1920 × 1080 or 3840 × 2160).
    private var target: MoonlightStreamTarget { MoonlightStreamTarget.make(settings: settingsForScreen, hostSupportsHEVC: host.hostSupportsHEVC) }
    private var refreshRate: Int { OrbitSecondScreenSession.refreshRate(for: settingsForScreen) }
    /// The PC's state, when it belongs to the selected PC.
    private var status: OrbitStreamDisplayStatus? { session.statusPCID == context.pcID ? session.status : nil }
    private var isActiveOnPC: Bool { status?.secondScreen.active == true }
    /// The running session (if any) belongs to this PC.
    private var sessionIsHere: Bool { session.sessionPCID == nil || session.sessionPCID == context.pcID }

    var body: some View {
        ZStack {
            TVPalette.background.ignoresSafeArea()
            if store.isProUnlocked {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        availabilityNotice
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 22) {
                                actionCard
                                messages
                                if showsSetup { positionCard }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusSection()
                            VStack(alignment: .leading, spacing: 22) {
                                if showsSetup { requirementsCard }
                                howItWorksCard
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusSection()
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.top, 30)
                    .padding(.bottom, 50)
                }
                .focusScope(focusSpace)
            } else {
                lockedPage
            }
        }
        .task(id: context.identity) {
            await reload(force: false)
            // Stay current while the page is open (another device starting or ending a stream, say).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                if store.isProUnlocked, !session.isBusy, !session.isStreaming, vm.metrics.isOnline, !vm.isDemoMode {
                    await session.refresh(context: context, quiet: true)
                }
            }
        }
        #if DEBUG
        .task { await TVSecondScreenSelfTest.run(sheet: self) }
        #endif
        .sheet(isPresented: $showsPaywall) {
            OrbitProUnlockView(accent: TVPalette.accent, reason: "Using this Apple TV as an extra display for your PC is part of Orbit Pro.") { showsPaywall = false }
        }
        .confirmationDialog("Turn off the second screen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { session.stop(context: context, host: host) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit ends the stream, turns the virtual display on \(pcName) off and puts Sunshine's display settings back.")
        }
        .confirmationDialog("Undo Orbit's changes on \(pcName)?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Undo Changes", role: .destructive) { session.revert(context: context) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fill Screen and the second screen turn off, and Sunshine's display settings go back to how they were before Orbit changed them. Sunshine restarts once.")
        }
    }

    /// Orbit changed Sunshine's settings on this PC (the PC kept the previous ones) and nothing streams here.
    private var canUndo: Bool {
        status?.savedConfig.available == true && sessionIsHere && !session.isStreaming
    }

    private var showsSetup: Bool {
        switch session.availability {
        case .available, .demo: return true
        default: return false
        }
    }

    // MARK: Header

    private var statusText: (text: String, tint: Color) {
        if !sessionIsHere { return ("Running for \(session.sessionPCName)", TVPalette.amber) }
        switch session.phase {
        case .preparing, .waitingForSunshine: return ("Starting…", TVPalette.accent)
        case .stopping: return ("Turning off…", TVPalette.amber)
        case .streaming: return ("Streaming", TVPalette.accent)
        case .idle: break
        }
        if vm.isDemoMode { return ("Demo", TVPalette.amber) }
        if !context.hasPC { return ("No PC", Color.secondary) }
        if !vm.metrics.isOnline { return ("PC offline", TVPalette.amber) }
        return isActiveOnPC ? ("On", TVPalette.accent) : ("Off", Color.secondary)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text("Second Screen")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                    TVLabsBadge()
                    TVStatusPill(text: statusText.text, tint: statusText.tint)
                }
                Text("This Apple TV as an extra display for \(pcName). Windows sees a new monitor next to its own and Orbit streams it here.")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            if session.isRefreshing { ProgressView() }
            Button { Task { await reload(force: true) } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                .disabled(session.isRefreshing)
            Button(action: onClose) { Label("Done", systemImage: "checkmark") }
                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
        }
        .focusSection()
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let problem = session.problem, sessionIsHere {
            messageCard(problem.title, problem.message, icon: "exclamationmark.triangle.fill", tint: TVPalette.amber)
        }
        if let notice = session.notice, sessionIsHere {
            messageCard(notice.title, notice.message, icon: notice.symbol, tint: notice.kind == .demo ? TVPalette.amber : TVPalette.accent)
        }
        if let hint = session.placementHint, sessionIsHere, isActiveOnPC || session.isStreaming {
            messageCard("Put it on the \(status?.secondScreen.position ?? position.rawValue)", hint, icon: "arrow.left.and.right.square", tint: TVPalette.accent)
        }
        // Once, from the first start: Windows sizes text for a desktop monitor on the new display.
        if !scaleTipDismissed, sessionIsHere, session.isStarting || session.isStreaming || isActiveOnPC {
            VStack(alignment: .leading, spacing: 12) {
                messageRow("Text too small?", OrbitSecondScreenScaleTip.message(device: "this Apple TV"), icon: "textformat.size", tint: TVPalette.accent)
                Button { scaleTipDismissed = true } label: { Text("Got It") }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvGlass(tint: TVPalette.accent)
            .focusSection()
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        if !context.hasPC {
            // Nothing to check yet: without a paired PC the session only knows that it is "offline".
            messageCard("Pair a PC first", "Pair your PC in My PCs, or sync it from your iPhone, then come back to use this Apple TV as its second screen.",
                        icon: "desktopcomputer", tint: TVPalette.amber)
        } else {
            switch session.availability {
            case .offline:
                messageCard("\(pcName) is offline", "Wake it or connect to it to use this Apple TV as its second screen.", icon: "wifi.slash", tint: TVPalette.amber)
            case .olderAgent:
                messageCard("Update Orbit PC Companion", "The companion on \(pcName) doesn't support Second Screen yet. \(OrbitStreamDisplayErrors.updateHint)",
                            icon: "arrow.down.circle.fill", tint: TVPalette.amber)
            case .failed(let problem):
                messageCard(problem.title, problem.message, icon: "exclamationmark.triangle.fill", tint: TVPalette.amber)
            case .unknown, .checking:
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Checking \(pcName)…").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvGlass()
            case .demo:
                messageCard("Demo mode", "This is a sample PC. Pair your own PC to use this Apple TV as its second screen.", icon: "sparkles", tint: TVPalette.amber)
            case .available:
                EmptyView()
            }
        }
    }

    private func messageRow(_ title: String, _ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                Text(text).font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func messageCard(_ title: String, _ text: String, icon: String, tint: Color) -> some View {
        messageRow(title, text, icon: icon, tint: tint)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvGlass(tint: tint)
    }

    // MARK: Action

    private var startBlocker: String? {
        session.startBlocker(context: context, host: host, size: target.size.displaySize)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch session.phase {
            case .preparing(let text) where sessionIsHere:
                TVDisplayWorkRow(title: text, waitsForPrompt: status?.lists(target.size.displaySize, refreshRate: refreshRate) != true,
                                 detail: "Then Sunshine restarts on the PC to use it. This can take up to a minute.")
            case .waitingForSunshine where sessionIsHere:
                TVDisplayWorkRow(title: "Waiting for Sunshine to restart…", detail: "The stream opens as soon as Sunshine answers again.")
            case .stopping(let text) where sessionIsHere:
                TVDisplayWorkRow(title: text, detail: "Sunshine restarts on the PC to put its display settings back.")
            default:
                if isActiveOnPC && sessionIsHere {
                    Text("The second screen is on").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    Text(session.isStreaming
                         ? "It is streaming to this Apple TV. Press Menu on the Siri Remote during the stream to stop it."
                         : "\(pcName) still has the virtual display. Show it here again, or turn it off so Sunshine \(status?.fill.enabled == true ? "goes back to Fill Screen" : "streams the main monitor").")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        if !session.isStreaming {
                            Button { start() } label: { Label("Show It Here", systemImage: "play.fill") }
                                .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
                                .disabled(startBlocker != nil)
                                .prefersDefaultFocus(true, in: focusSpace)
                        }
                        Button { confirmStop = true } label: { Label("Turn Off", systemImage: "power") }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))
                            .disabled(!session.canTurnOff(context.pcID))
                    }
                    if let startBlocker, !session.isStreaming {
                        Text(startBlocker).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button { start() } label: { Label("Start Second Screen", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
                        .disabled(startBlocker != nil || session.isBusy)
                        .prefersDefaultFocus(true, in: focusSpace)
                        .accessibilityHint(startBlocker ?? "Turns on the virtual display on \(pcName) and streams it here")
                    Text(startBlocker ?? "Orbit turns on the virtual display, Sunshine restarts once, then the stream opens here. Press Menu during the stream to turn it off again.")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(startBlocker == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(TVPalette.amber))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass(tint: TVPalette.accent, elevated: true)
    }

    // MARK: Side

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHERE IT GOES").font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(TVPalette.accent)
            HStack(spacing: 16) {
                ForEach(OrbitSecondScreenPosition.allCases) { side in
                    Button { choose(side) } label: {
                        Label(side.title, systemImage: side == position ? "checkmark.circle.fill" : (side == .left ? "arrow.left" : "arrow.right"))
                    }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: side == position))
                    .disabled(session.isBusy || session.isMoving || !sessionIsHere)
                    .accessibilityAddTraits(side == position ? .isSelected : [])
                }
                if session.isMoving {
                    ProgressView()
                    Text("Moving it…").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Side of the PC's main monitor")

            HStack(spacing: 14) {
                if position == .left { tvTile; monitorTile } else { monitorTile; tvTile }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: position)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("This Apple TV sits to the \(position.rawValue) of \(pcName)'s main monitor")

            Text("Windows puts the virtual display to the \(position.rawValue) of its main monitor: move the pointer past that edge to reach it. You can change the side while it's on.")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Size: \(target.size.description) at \(refreshRate) Hz, this Apple TV's output.")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass()
    }

    private var monitorTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "display").font(.system(size: 34))
            Text(pcName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tvTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "appletv").font(.system(size: 34))
            Text("This Apple TV").font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(TVPalette.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(TVPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TVPalette.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: Requirements

    private var hostChecks: [OrbitDisplayCheck] {
        OrbitSecondScreenSession.hostChecks(host: host, isDemo: vm.isDemoMode, pcName: pcName)
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WHAT IT NEEDS").font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(TVPalette.accent)
            ForEach(hostChecks) { check in
                VStack(alignment: .leading, spacing: 10) {
                    TVDisplayCheckRow(check: check)
                    if check.kind == .pairing, check.state == .missing {
                        Button(action: onPair) { Label("Pair with Sunshine", systemImage: "link") }
                            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
                            .disabled(!vm.metrics.isOnline || !host.reachable)
                    }
                }
            }
            if let status {
                ForEach(status.secondScreenChecks) { check in
                    VStack(alignment: .leading, spacing: 10) {
                        TVDisplayCheckRow(check: check)
                        checkAction(check, status: status)
                    }
                }
                // The PC's own words when it isn't ready for another reason (Start may still sort it out).
                if let note = status.pcNote {
                    TVDisplayCheckRow(check: OrbitDisplayCheck(kind: .idle, title: "Note from \(pcName)", detail: note, state: .unknown))
                }
            }
            if let loginMessage {
                Text(loginMessage).font(.system(size: 16, weight: .medium)).foregroundStyle(loginFailed ? TVPalette.amber : TVPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass()
    }

    @ViewBuilder
    private func checkAction(_ check: OrbitDisplayCheck, status: OrbitStreamDisplayStatus) -> some View {
        switch check.kind {
        case .login where check.state == .missing:
            // Missing, or turned down by Sunshine (not while Sunshine is stopped: the login may be fine).
            TVSunshineLoginForm(pcName: pcName, isSaving: savingLogin) { name, secret in
                await saveLogin(username: name, password: secret)
            }
        case .sunshine where status.sunshineStopped && context.canStartSunshine:
            Button {
                Task {
                    await session.startSunshine(context: context)
                    await host.refresh()
                }
            } label: {
                Label(session.isStartingSunshine ? "Starting Sunshine…" : "Start Sunshine on \(pcName)", systemImage: "play.circle.fill")
            }
            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
            .disabled(session.isStartingSunshine)
        case .driver where check.state != .done && status.offersInstallCommand:
            VStack(alignment: .leading, spacing: 8) {
                Text(status.driverInstallCommand)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Install command: \(status.driverInstallCommand)")
                Text("On the PC, Orbit PC Companion's tray menu (Set up full-screen streaming…) copies this command for you.")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 42)
        case .idle where status.appRunning == true && status.streamActive != true && host.isPaired:
            // Only an app left running with nobody watching: quitting it never ends someone's stream.
            Button {
                quittingApp = true
                Task {
                    await host.quitRunningApp()
                    await session.refresh(context: context, force: true)
                    quittingApp = false
                }
            } label: {
                Label(quittingApp ? "Quitting…" : "Quit \(host.runningAppTitle ?? "the app") in Sunshine", systemImage: "stop.fill")
            }
            .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))
            .disabled(quittingApp)
        default:
            EmptyView()
        }
    }

    // MARK: How it works

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HOW IT WORKS").font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(TVPalette.accent)
            bullet("display.2", "Orbit adds a virtual display (the free Virtual Display Driver) at this Apple TV's output size and has Sunshine stream it, so it fills the TV.")
            bullet("appletvremote.gen4.fill", "The Siri Remote's touch surface moves the PC's pointer and a click selects; Play/Pause right-clicks. Game controllers paired with the Apple TV work too.")
            bullet("speaker.wave.2", "Sound keeps playing on \(pcName), as with any other monitor; this Apple TV stays quiet.")
            bullet("textformat.size", OrbitSecondScreenScaleTip.message(device: "this Apple TV"))
            bullet("stop.circle", "Menu ends the stream, which turns the virtual display off and puts Sunshine's settings back. Normal streams then \(status?.fill.enabled == true ? "fill the screen again, as Fill Screen is on" : "show the main monitor again").")
            bullet("flask", canUndo
                   ? "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. If something looks wrong, Undo Orbit's Changes puts Sunshine's display settings back."
                   : "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. Orbit saves Sunshine's display settings before changing them, so they can always be put back.")
            if canUndo {
                Button { confirmRevert = true } label: { Label("Undo Orbit's Changes…", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.amber))
                    .disabled(session.isBusy)
                    .accessibilityHint("Turns Fill Screen and the second screen off and puts Sunshine's display settings back")
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlass()
        // Without its Undo button nothing here takes focus, so the remote could never scroll down to the last lines:
        // the card itself takes focus then, with an outline.
        .focusable(!canUndo)
        .focused($readingHowItWorks)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(TVPalette.accent, lineWidth: readingHowItWorks && !canUndo ? 3 : 0))
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(TVPalette.accent).frame(width: 28).accessibilityHidden(true)
            Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Without Orbit Pro

    private var lockedPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(TVPalette.amber)
                .frame(width: 104, height: 104)
                .background(TVPalette.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            HStack(spacing: 14) {
                Text("Second Screen").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                TVLabsBadge()
            }
            Text("Using this Apple TV as an extra display for your PC is part of Orbit Pro.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button { showsPaywall = true } label: { Label("Unlock with Orbit Pro", systemImage: "crown.fill") }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.amber, isProminent: true))
                Button(action: onClose) { Text("Close") }
                    .buttonStyle(TVActionPillStyle(tint: TVPalette.accent))
            }
            .focusSection()
        }
        .frame(maxWidth: 1100)
        .padding(60)
    }

    // MARK: Actions

    private func choose(_ side: OrbitSecondScreenPosition) {
        guard side != position else { return }
        positionRaw = side.rawValue
        if isActiveOnPC { session.move(to: side, context: context, baseSettings: streamSettings.settings) }
    }

    fileprivate func start() {
        session.start(context: context, host: host, baseSettings: streamSettings.settings, target: target, position: position,
                      presentStream: false) { onStreamBegan() }
    }

    fileprivate func reload(force: Bool) async {
        guard store.isProUnlocked else { return }
        if !vm.isDemoMode, vm.metrics.isOnline, force || host.lastRefreshed == nil { await host.refresh() }
        await session.refresh(context: context, force: force)
    }

    fileprivate func saveLogin(username: String, password: String) async -> Bool {
        savingLogin = true
        loginMessage = nil
        defer { savingLogin = false }
        let result = await session.saveLogin(context: context, username: username, password: password)
        loginMessage = result.message
        loginFailed = !result.accepted
        return result.saved
    }
}

// MARK: - Rows

/// One requirement with its state icon, in the TV's type sizes.
private struct TVDisplayCheckRow: View {
    let check: OrbitDisplayCheck

    private var icon: (name: String, tint: Color) {
        switch check.state {
        case .done: return ("checkmark.circle.fill", TVPalette.accent)
        case .missing: return ("exclamationmark.circle.fill", TVPalette.amber)
        case .unknown: return ("questionmark.circle", Color.secondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(icon.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                if let detail = check.detail {
                    Text(detail).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.title): \(check.state == .done ? "done" : (check.state == .missing ? "needed" : "not known"))")
        .accessibilityValue(check.detail ?? "")
    }
}

/// "Approve the Windows PowerShell prompt on your PC" and the other waits, while the PC works.
private struct TVDisplayWorkRow: View {
    let title: String
    var waitsForPrompt = false
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ProgressView().padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                if waitsForPrompt {
                    Text("Approve the Windows PowerShell prompt on your PC.")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(TVPalette.amber)
                    Text("Windows may ask once for administrator permission to add a screen size. Approve it within a minute; if you decline or nobody answers, nothing changes.")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Saves Sunshine's web UI login on the PC (the route pairing uses). Each field opens the TV keyboard.
private struct TVSunshineLoginForm: View {
    var pcName: String
    var isSaving: Bool
    var onSave: (_ username: String, _ password: String) async -> Bool
    @State private var username = ""
    @State private var password = ""

    private var canSave: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSaving }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Sunshine username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField("Sunshine password", text: $password)
                .textContentType(.password)
            Button {
                let name = username.trimmingCharacters(in: .whitespaces), secret = password
                Task { if await onSave(name, secret) { password = "" } }
            } label: {
                Label(isSaving ? "Saving…" : "Save on \(pcName)", systemImage: "checkmark")
            }
            .buttonStyle(TVActionPillStyle(tint: TVPalette.accent, isProminent: true))
            .disabled(!canSave)
            Text("The login you use for Sunshine's web UI on the PC. It is stored on the PC next to Orbit's token, never on this Apple TV.")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 700, alignment: .leading)
        .padding(.leading, 42)
        .focusSection()
    }
}

#if DEBUG
/// Second Screen without a remote, for the headless tvOS Simulator (Debug builds only).
///
/// `ORBIT_TV_SECOND_SCREEN=1` (as `SIMCTL_CHILD_ORBIT_TV_SECOND_SCREEN` with `xcrun simctl launch`) opens Controls ›
/// Second Screen; `card` instead scrolls the Controls tab to its Second Screen card. `ORBIT_SELFTEST_ACTION=` runs steps
/// in order, 4 s apart, and prints the session's state after each: `start` (as Start does), `off` (Turn Off), `revert`
/// (Undo Orbit's Changes), `refresh` (Check Again), `left` / `right` (the side), `login` (saves `ORBIT_SELFTEST_LOGIN`,
/// "user:password", on the PC), `tip` (Got It on the text-size tip), `how` (focus on How it works, which scrolls there). `-orbit.pro.debugOverride "<true/>"` unlocks Orbit Pro.
/// `ORBIT_TV_TEST_PC="name|host|securePort|fingerprint|token"` saves that PC as paired (see `OrbitTVViewModel.debugAddTestPC`).
@MainActor
enum TVSecondScreenSelfTest {
    static var mode: String? { ProcessInfo.processInfo.environment["ORBIT_TV_SECOND_SCREEN"] }

    static func run(sheet: TVSecondScreenSheet) async {
        guard mode != nil else { return }
        let session = OrbitSecondScreenSession.shared
        try? await Task.sleep(for: .seconds(5))   // the PC's readiness arrives
        log("open", session)
        let environment = ProcessInfo.processInfo.environment
        for action in (environment["ORBIT_SELFTEST_ACTION"] ?? "").split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(4))
            let context = sheet.vm.streamDisplayContext
            switch action {
            case "start": sheet.start()
            case "off": session.stop(context: context, host: sheet.host)
            case "revert": session.revert(context: context)
            case "refresh": await sheet.reload(force: true)
            case "left", "right":
                UserDefaults.standard.set(action, forKey: OrbitSecondScreenPosition.storageKey)
                if session.isActiveOnPC(context.pcID), let side = OrbitSecondScreenPosition(rawValue: action) {
                    session.move(to: side, context: context, baseSettings: MoonlightStreamSettingsStore.shared.settings)
                }
            case "login":
                let parts = (environment["ORBIT_SELFTEST_LOGIN"] ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { _ = await sheet.saveLogin(username: parts[0], password: parts[1]) }
            case "tip":
                UserDefaults.standard.set(true, forKey: OrbitSecondScreenScaleTip.dismissedKey)
            case "how":
                sheet.$readingHowItWorks.wrappedValue = true
            default:
                break
            }
            for _ in 0..<400 where session.isBusy || session.isMoving { try? await Task.sleep(for: .milliseconds(500)) }
            log(action, session)
        }
    }

    private static func log(_ step: String, _ session: OrbitSecondScreenSession) {
        let stream = MoonlightStreamController.shared
        let pc = session.status
        print("selftest: \(step) → availability \(session.availability) · phase \(session.phase) · on \(pc?.secondScreen.active == true) (\(pc?.secondScreen.position ?? "-")) · stream \(stream.request.map { "\($0.app.title) second screen \($0.secondScreen) \($0.target.size)" } ?? "none") · problem \(session.problem.map { "\($0.title): \($0.message)" } ?? "none") · notice \(session.notice?.message ?? "none")")
    }
}
#endif
