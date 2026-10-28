import AppKit
import MoonlightCore
import SwiftUI

// Second Screen on the Mac (DESIGN F9, Orbit Pro, Labs): a card on the Stream page and PC › Use This Mac
// as a Second Screen… open this sheet. The PC gets a virtual display at the size of the Mac display in
// front, and the Stream window shows it in full screen. Ending the stream turns it off again
// (`OrbitSecondScreenSession`, shared with the iPhone and iPad).

extension OrbitMacViewModel {
    /// The selected PC, for the Fill Screen setup in Stream Settings and for Second Screen.
    var streamDisplayContext: OrbitStreamDisplayContext {
        OrbitStreamDisplayContext(pcID: isDemoMode ? "demo" : (currentPC?.id ?? ""), pcName: selectedPCName.isEmpty ? "your PC" : selectedPCName,
                                  isDemo: isDemoMode, isOnline: metrics.isOnline, hasPC: isDemoMode || currentPC != nil,
                                  canStartSunshine: sunshineInfo?.canStart ?? false, makeClient: { try self.client() })
    }
}

/// The Stream page's entry point. It also warns while the PC still has the second screen on although this Mac does
/// not stream it (left on by a stream that ended without turning it off, a quit app or another device): every stream
/// from it then shows the extra display. Turn Off there is never Pro-gated: it only undoes Orbit's change.
struct MacSecondScreenCard: View {
    let context: OrbitStreamDisplayContext
    /// The Stream page's Sunshine host: Turn Off closes a Desktop session left running with it.
    let host: MoonlightHostCoordinator
    var onOpen: () -> Void
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @Environment(\.macTheme) private var theme

    private var pcName: String { context.pcName }
    private var pcID: String { context.pcID }
    private var leftOn: Bool { session.isLeftOn(pcID) && (context.isOnline || context.isDemo) }
    private var stoppingHere: Bool {
        if case .stopping = session.phase, session.sessionPCID == pcID { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                MacIconBadge(systemName: "rectangle.on.rectangle", tint: leftOn ? .orange : .blue, size: 38, filled: session.isStreaming || leftOn)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Second Screen").font(.subheadline.weight(.semibold))
                        MacLabsBadge()
                        if session.isStreaming {
                            MacStatusPill(text: "On", tint: .mint, pulsing: true)
                        } else if session.isBusy {
                            MacStatusPill(text: "Working…", tint: theme.accent, pulsing: true)
                        } else if session.isActiveOnPC(pcID) {
                            MacStatusPill(text: "On", tint: leftOn ? .orange : .mint)
                        }
                    }
                    Text("Use this Mac as an extra display for \(pcName): Windows gets a new monitor next to its own, shown here in full screen.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onOpen) { Label("Set Up…", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(MacHoverButtonStyle(tint: .blue))
                    .help("Use this Mac as a second screen for \(pcName) (Orbit Pro, Labs)")
            }
            if stoppingHere {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Turning off the second screen on \(session.sessionPCName)…").font(.caption).foregroundStyle(.secondary)
                }
            } else if leftOn {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still on for \(pcName)").font(.caption.weight(.semibold))
                        Text("Until it's turned off, streams from \(pcName) show its extra virtual display, not the main monitor.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let problem = session.problem, session.sessionPCID == nil || session.sessionPCID == pcID {
                            Text("\(problem.title): \(problem.message)").font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { session.stop(context: context, host: host) } label: { Label("Turn Off", systemImage: "power") }
                        .buttonStyle(MacHoverButtonStyle(tint: .orange))
                        .disabled(!session.canTurnOff(pcID))
                        .help("Turns the virtual display on \(pcName) off and puts Sunshine's display settings back")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: leftOn ? .orange : .blue)
        .task(id: context.identity) { await session.checkIfLeftOn(context: context) }
    }
}

struct MacLabsBadge: View {
    var body: some View {
        Text("LABS")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue, in: Capsule())
            .accessibilityLabel("Labs feature")
    }
}

/// The sheet: requirements, side, Start / Turn Off.
struct MacSecondScreenSheet: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @ObservedObject var host: MoonlightHostCoordinator
    /// Closes the sheet and opens Sunshine pairing on the Stream page.
    var onPair: () -> Void
    var onClose: () -> Void
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @ObservedObject private var store = OrbitProStore.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @AppStorage(OrbitSecondScreenPosition.storageKey) private var positionRaw = OrbitSecondScreenPosition.right.rawValue
    @AppStorage(OrbitSecondScreenScaleTip.dismissedKey) private var scaleTipDismissed = false
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmStop = false
    @State private var confirmRevert = false
    @State private var savingLogin = false
    @State private var loginMessage: String?
    @State private var loginFailed = false
    @State private var quittingApp = false

    private var context: OrbitStreamDisplayContext { vm.streamDisplayContext }
    private var pcName: String { context.pcName }
    private var position: OrbitSecondScreenPosition { OrbitSecondScreenPosition(rawValue: positionRaw) ?? .right }
    private var settingsForScreen: MoonlightStreamSettings { OrbitSecondScreenSession.streamSettings(from: streamSettings.settings) }
    /// Sized for the display the Stream window fills: the open Stream window's, else the one in front.
    private var target: MoonlightStreamTarget {
        MoonlightStreamTarget.make(settings: settingsForScreen, hostSupportsHEVC: host.hostSupportsHEVC, screen: MacStreamWindowController.shared.targetScreen())
    }
    private var refreshRate: Int { OrbitSecondScreenSession.refreshRate(for: settingsForScreen) }
    private var status: OrbitStreamDisplayStatus? { session.statusPCID == context.pcID ? session.status : nil }
    private var isActiveOnPC: Bool { status?.secondScreen.active == true }
    private var sessionIsHere: Bool { session.sessionPCID == nil || session.sessionPCID == context.pcID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if store.isProUnlocked {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusCard
                        messages
                        availabilityNotice
                        if showsSetup {
                            MacSectionHeader("What it needs", icon: "checklist")
                            requirementsCard
                            MacSectionHeader("Where it goes", icon: "rectangle.split.2x1")
                            positionCard
                        }
                        actionCard
                        howItWorks
                    }
                    .padding(20)
                }
            } else {
                MacProLockedPage(title: "Second Screen", message: "Using this Mac as an extra display for your PC is part of Orbit Pro.")
            }
        }
        .frame(width: 640, height: 700)
        .background(theme.background)
        .task(id: context.identity) {
            await reload(force: false)
            // Stay current while the sheet is open (another device starting or ending a stream, say).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                if store.isProUnlocked, !session.isBusy, !session.isStreaming, vm.metrics.isOnline, !vm.isDemoMode {
                    await session.refresh(context: context, quiet: true)
                }
            }
        }
        .confirmationDialog("Turn off the second screen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { session.stop(context: context, host: host) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orbit ends the stream, turns the virtual display on \(pcName) off and puts Sunshine's display settings back.")
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

    /// The Sunshine login form is on screen (the login is missing, or Sunshine turned it down).
    private var showsLoginForm: Bool {
        store.isProUnlocked && showsSetup && status?.secondScreenChecks.contains { $0.kind == .login && $0.state == .missing } == true
    }

    // MARK: Header and status

    private var header: some View {
        HStack(spacing: 10) {
            Text("Second Screen").font(.title3.weight(.bold))
            MacLabsBadge()
            Spacer()
            if session.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(MacIconButtonStyle(size: 26))
                .help("Check the PC again")
                .accessibilityLabel("Check the PC again")
                .disabled(session.isRefreshing || !store.isProUnlocked)
            Button("Done", action: onClose)
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                // Return belongs to the Sunshine login form while it shows (AppKit gives the default button Return
                // before a text field), so typing a password and pressing Return saves it instead of closing the sheet.
                .keyboardShortcut(showsLoginForm ? nil : .defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: (text: String, tint: Color) {
        if !sessionIsHere { return ("Running for \(session.sessionPCName)", .orange) }
        switch session.phase {
        case .preparing, .waitingForSunshine: return ("Starting…", theme.accent)
        case .stopping: return ("Turning off…", .orange)
        case .streaming: return ("Streaming", .mint)
        case .idle: break
        }
        if vm.isDemoMode { return ("Demo", .orange) }
        if !context.hasPC { return ("No PC", .secondary) }
        if !vm.metrics.isOnline { return ("PC offline", .orange) }
        return isActiveOnPC ? ("On", .mint) : ("Off", .secondary)
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: "rectangle.on.rectangle", tint: .blue, size: 46, filled: isActiveOnPC)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("This Mac as a display for \(pcName)").font(.headline).lineLimit(1)
                    MacStatusPill(text: statusText.text, tint: statusText.tint, pulsing: session.isBusy || session.isStreaming)
                }
                Text("Windows sees a new monitor next to its own. Orbit streams it here in full screen, with the mouse and keyboard captured as in any stream.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .macGlass(cornerRadius: 18, tint: .blue, elevated: true)
    }

    @ViewBuilder
    private var messages: some View {
        if let problem = session.problem, sessionIsHere {
            message(problem.title, problem.message, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let notice = session.notice, sessionIsHere {
            message(notice.title, notice.message, icon: notice.symbol, tint: notice.kind == .done ? .mint : (notice.kind == .note ? .cyan : .orange))
        }
        if let hint = session.placementHint, sessionIsHere, isActiveOnPC || session.isStreaming {
            message("Put it on the \(status?.secondScreen.position ?? position.rawValue)", hint, icon: "arrow.left.and.right.square", tint: .cyan)
        }
        // Once, from the first start: Windows sizes text for a desktop monitor on the new display.
        if !scaleTipDismissed, sessionIsHere, session.isStarting || session.isStreaming || isActiveOnPC {
            HStack(alignment: .top, spacing: 12) {
                MacIconBadge(systemName: "textformat.size", tint: .cyan, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text too small?").font(.subheadline.weight(.semibold))
                    Text(OrbitSecondScreenScaleTip.message(device: "this Mac"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Got It") { scaleTipDismissed = true }
                    .buttonStyle(MacHoverButtonStyle(tint: .cyan))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macGlass(cornerRadius: 16, tint: .cyan)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        if !context.hasPC {
            // Nothing to check yet: without a paired PC the session only knows that it is "offline".
            message("Pair a PC first", "Pair your PC in My PCs, or import the one you paired on your iPhone, then come back to use this Mac as its second screen.",
                    icon: "desktopcomputer", tint: .orange)
        } else {
            pcAvailabilityNotice
        }
    }

    @ViewBuilder
    private var pcAvailabilityNotice: some View {
        switch session.availability {
        case .offline:
            message("\(pcName) is offline", "Wake it or connect to it to use this Mac as its second screen.", icon: "wifi.slash", tint: .orange)
        case .olderAgent:
            message("Update Orbit PC Companion", "The companion on \(pcName) doesn't support Second Screen yet. \(OrbitStreamDisplayErrors.updateHint)", icon: "arrow.down.circle.fill", tint: .orange)
        case .failed(let problem):
            message(problem.title, problem.message, icon: "exclamationmark.triangle.fill", tint: .orange)
        case .unknown, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking \(pcName)…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macGlass(cornerRadius: 16)
        case .demo:
            message("Demo mode", "This is a sample PC. Pair your own PC to use this Mac as its second screen.", icon: "sparkles", tint: .orange)
        case .available:
            EmptyView()
        }
    }

    private func message(_ title: String, _ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MacIconBadge(systemName: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 16, tint: tint)
        .accessibilityElement(children: .combine)
    }

    // MARK: Requirements

    private var hostChecks: [OrbitDisplayCheck] {
        OrbitSecondScreenSession.hostChecks(host: host, isDemo: vm.isDemoMode, pcName: pcName)
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(hostChecks) { check in
                VStack(alignment: .leading, spacing: 8) {
                    OrbitDisplayCheckRow(check: check)
                    if check.kind == .pairing, check.state == .missing {
                        Button(action: onPair) { Label("Pair with Sunshine…", systemImage: "link") }
                            .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                            .disabled(!vm.metrics.isOnline)
                    }
                }
            }
            if let status {
                ForEach(status.secondScreenChecks) { check in
                    VStack(alignment: .leading, spacing: 8) {
                        OrbitDisplayCheckRow(check: check)
                        checkAction(check, status: status)
                    }
                }
                // The PC's own words when it isn't ready for another reason (Start may still sort it out).
                if let note = status.pcNote {
                    OrbitDisplayOutcomeRow(title: "Note from \(pcName)", message: note, isError: false, symbol: "info.circle.fill", tint: .cyan)
                }
            }
            if let loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(loginFailed ? Color.orange : theme.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    @ViewBuilder
    private func checkAction(_ check: OrbitDisplayCheck, status: OrbitStreamDisplayStatus) -> some View {
        switch check.kind {
        case .login where check.state == .missing:
            // Missing, or turned down by Sunshine (not while Sunshine is stopped: the login may be fine).
            OrbitSunshineLoginForm(pcName: pcName, isSaving: savingLogin, accent: theme.accent) { name, secret in
                await saveLogin(username: name, password: secret)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 380, alignment: .leading)
        case .sunshine where status.sunshineStopped && context.canStartSunshine:
            OrbitStartSunshineButton(pcName: pcName, isStarting: session.isStartingSunshine, accent: theme.accent) {
                Task {
                    await session.startSunshine(context: context)
                    await host.refresh()
                }
            }
        case .driver where check.state != .done && status.offersInstallCommand:
            OrbitDriverInstallCommand(command: status.driverInstallCommand, accent: theme.accent)
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
            .buttonStyle(MacHoverButtonStyle(tint: .orange))
            .disabled(quittingApp)
        default:
            EmptyView()
        }
    }

    // MARK: Side

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Side of the PC's main monitor", selection: Binding(get: { position }, set: { newValue in
                positionRaw = newValue.rawValue
                if isActiveOnPC { session.move(to: newValue, context: context, baseSettings: streamSettings.settings) }
            })) {
                ForEach(OrbitSecondScreenPosition.allCases) { side in Text(side.title).tag(side) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .disabled(session.isBusy || session.isMoving || !sessionIsHere)

            HStack(spacing: 10) {
                if position == .left { macTile; monitorTile } else { monitorTile; macTile }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: position)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("This Mac sits to the \(position.rawValue) of \(pcName)'s main monitor")

            Text("Windows puts the virtual display to the \(position.rawValue) of its main monitor: move the PC's mouse past that edge to reach it. You can change the side while it's on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Size: \(target.size.description) at \(refreshRate) Hz, the full-screen area of the display in front.")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if session.isMoving {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Moving it…").font(.caption) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: theme.accent)
    }

    private var monitorTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "display").font(.system(size: 28))
            Text(pcName).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var macTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "laptopcomputer").font(.system(size: 28))
            Text("This Mac").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: Action

    private var startBlocker: String? {
        session.startBlocker(context: context, host: host, size: target.size.displaySize)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch session.phase {
            case .preparing(let text) where sessionIsHere:
                OrbitDisplayWorkRow(title: text, waitsForPrompt: status?.lists(target.size.displaySize, refreshRate: refreshRate) != true,
                                    detail: "Then Sunshine restarts on the PC to use it. This can take up to a minute.")
            case .waitingForSunshine where sessionIsHere:
                OrbitDisplayWorkRow(title: "Waiting for Sunshine to restart…", detail: "The Stream window opens as soon as Sunshine answers again.")
            case .stopping(let text) where sessionIsHere:
                OrbitDisplayWorkRow(title: text, detail: "Sunshine restarts on the PC to put its display settings back.")
            default:
                if isActiveOnPC && sessionIsHere {
                    Text("The second screen is on").font(.headline)
                    Text(session.isStreaming ? "It is streaming in the Stream window. Press ⌃⌥⇧Q there, or Turn Off here, to stop it." : "\(pcName) still has the virtual display. Show it here again, or turn it off so Sunshine \(status?.fill.enabled == true ? "goes back to Fill Screen" : "streams the main monitor").")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if !session.isStreaming {
                            Button { start() } label: { Label("Show It Here", systemImage: "play.fill") }
                                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                                .disabled(startBlocker != nil)
                        }
                        Button { confirmStop = true } label: { Label("Turn Off", systemImage: "power") }
                            .buttonStyle(MacHoverButtonStyle(tint: .orange))
                    }
                } else {
                    HStack(spacing: 12) {
                        Button { start() } label: { Label("Start Second Screen", systemImage: "rectangle.on.rectangle") }
                            .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                            .disabled(startBlocker != nil || session.isBusy)
                            .help(startBlocker ?? "Turns on the virtual display on \(pcName) and streams it here in full screen")
                        Spacer(minLength: 0)
                    }
                    Text(startBlocker ?? "Orbit turns on the virtual display, Sunshine restarts once, then the Stream window opens in full screen. End the stream to turn it off again.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18, tint: theme.accent)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            bullet("display.2", "Orbit adds a virtual display (the free Virtual Display Driver) at this display's size and has Sunshine stream it, so it fills the screen.")
            bullet("speaker.wave.2", "Sound keeps playing on \(pcName), as with any other monitor; this Mac stays quiet.")
            bullet("textformat.size", OrbitSecondScreenScaleTip.message(device: "this Mac"))
            bullet("stop.circle", "Ending the stream turns the virtual display off and puts Sunshine's settings back. Normal streams then \(status?.fill.enabled == true ? "fill the screen again, as Fill Screen is on" : "show the main monitor again").")
            bullet("flask", canUndo
                   ? "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. If something looks wrong, Undo Orbit's Changes below puts Sunshine's display settings back."
                   : "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. Orbit saves Sunshine's display settings before changing them, so they can always be put back.")
            if canUndo {
                Button { confirmRevert = true } label: { Label("Undo Orbit's Changes…", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(MacHoverButtonStyle(tint: .orange))
                    .disabled(session.isBusy)
                    .help("Turns Fill Screen and the second screen off and puts Sunshine's display settings back")
                    .padding(.top, 4)
                    .confirmationDialog("Undo Orbit's changes on \(pcName)?", isPresented: $confirmRevert, titleVisibility: .visible) {
                        Button("Undo Changes", role: .destructive) { session.revert(context: context) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Fill Screen and the second screen turn off, and Sunshine's display settings go back to how they were before Orbit changed them. Sunshine restarts once.")
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 18)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 20).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func start() {
        let open = openWindow
        session.start(context: context, host: host, baseSettings: streamSettings.settings, target: target, position: position) {
            open(id: "stream")
        }
    }

    private func reload(force: Bool) async {
        guard store.isProUnlocked else { return }
        if force, !vm.isDemoMode, vm.metrics.isOnline { await host.refresh() }
        await session.refresh(context: context, force: force)
    }

    private func saveLogin(username: String, password: String) async -> Bool {
        savingLogin = true
        loginMessage = nil
        defer { savingLogin = false }
        let result = await session.saveLogin(context: context, username: username, password: password)
        loginMessage = result.message
        loginFailed = !result.accepted
        return result.saved
    }
}
