import MoonlightCore
import SwiftUI
import UIKit

// Second Screen on iPhone and iPad (DESIGN F9, Orbit Pro, Labs): Tools › Second Screen. The PC gets a
// virtual display at this device's exact size, next to its monitor, and Orbit streams it here with direct
// touch. Ending the stream turns it off again (`OrbitSecondScreenSession`).

extension OrbitViewModel {
    /// The selected PC, for the Fill Screen setup in Stream Settings and for Second Screen. Demo mode is a PC of
    /// its own ("demo"), so the sample state never mixes with what the paired PC reported.
    var streamDisplayContext: OrbitStreamDisplayContext {
        let name = isDemoMode ? (metrics.hostname.isEmpty ? "Preview PC" : metrics.hostname) : selectedPCName
        return OrbitStreamDisplayContext(pcID: isDemoMode ? "demo" : selectedPCID, pcName: name.isEmpty ? "your PC" : name, isDemo: isDemoMode,
                                         isOnline: metrics.isOnline, hasPC: isDemoMode || isConfigured, canStartSunshine: sunshineInfo?.canStart ?? false,
                                         makeClient: { try self.companionClient() })
    }
}

struct SecondScreenView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @AppStorage(OrbitSecondScreenPosition.storageKey) private var positionRaw = OrbitSecondScreenPosition.right.rawValue
    @AppStorage(OrbitSecondScreenScaleTip.dismissedKey) private var scaleTipDismissed = false
    @Environment(\.orbitTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPairing = false
    @State private var confirmStop = false
    @State private var confirmRevert = false
    @State private var savingLogin = false
    @State private var loginMessage: String?
    @State private var loginFailed = false
    @State private var quittingApp = false

    private var context: OrbitStreamDisplayContext { vm.streamDisplayContext }
    private var pcName: String { context.pcName }
    private var position: OrbitSecondScreenPosition { OrbitSecondScreenPosition(rawValue: positionRaw) ?? .right }
    private var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    private var streamSettingsForScreen: MoonlightStreamSettings { OrbitSecondScreenSession.streamSettings(from: streamSettings.settings) }
    private var target: MoonlightStreamTarget { MoonlightStreamTarget.make(settings: streamSettingsForScreen, hostSupportsHEVC: sunshine.hostSupportsHEVC) }
    private var refreshRate: Int { OrbitSecondScreenSession.refreshRate(for: streamSettingsForScreen) }
    /// The PC's state, when it belongs to the selected PC.
    private var status: OrbitStreamDisplayStatus? { session.statusPCID == context.pcID ? session.status : nil }
    private var isActiveOnPC: Bool { status?.secondScreen.active == true }
    /// The running session (if any) belongs to this PC.
    private var sessionIsHere: Bool { session.sessionPCID == nil || session.sessionPCID == context.pcID }
    private var sunshineReady: Bool { vm.isDemoMode || (sunshine.isPaired && sunshine.reachable) }
    private var syncKey: String { "\(vm.selectedPCID)|\(vm.cleanHost())|\(vm.metrics.isOnline)|\(vm.sunshineInfo?.httpPort ?? 0)|\(vm.isDemoMode)" }

    private var pairingAutomation: MoonlightPairingAutomation? {
        guard vm.metrics.isOnline, !vm.isDemoMode else { return nil }
        return MoonlightPairingAutomation(canSubmitPIN: vm.sunshineInfo?.canSubmitPin ?? false, canStartSunshine: vm.sunshineInfo?.canStart ?? false,
                                          sunshineRunning: vm.sunshineInfo?.running ?? true, client: { try vm.companionClient() })
    }

    var body: some View {
        ZStack {
            OrbitAmbientBackground(isOnline: vm.metrics.isOnline || vm.isDemoMode)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    messages
                    availabilityNotice
                    if showsSetup {
                        OrbitSectionHeader("What it needs", icon: "checklist")
                        requirementsCard
                        OrbitSectionHeader("Where it goes", icon: "rectangle.split.2x1")
                        positionCard
                    }
                    actionCard
                    OrbitSectionHeader("How it works", icon: "info.circle")
                    howItWorksCard
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await reload(force: true) }
        }
        .navigationTitle("Second Screen")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: syncKey) {
            await reload(force: false)
            // Stay current while the page is open (another device starting or ending a stream, say).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                if !session.isBusy, !session.isStreaming, vm.metrics.isOnline, !vm.isDemoMode { await session.refresh(context: context, quiet: true) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload(force: true) } }
        }
        .sheet(isPresented: $showsPairing) {
            MoonlightPairingView(host: sunshine, pcName: pcName, accent: theme.accent, automation: pairingAutomation) { showsPairing = false }
                .presentationDetents([.large])
                .presentationBackground(theme.background)
        }
        .confirmationDialog("Turn off the second screen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { session.stop(context: context, host: sunshine) }
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

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                OrbitIconBadge(systemName: "rectangle.on.rectangle", tint: .blue, size: 48, filled: isActiveOnPC)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Second Screen").font(.title3.weight(.bold))
                        labsBadge
                    }
                    OrbitStatusPill(text: heroStatus.text, tint: heroStatus.tint, pulsing: session.isBusy || session.isStreaming)
                }
                Spacer(minLength: 0)
            }
            Text("Use this \(deviceName) as an extra monitor for \(pcName). Windows sees a new display next to your main one: drag windows onto it and use them with touch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .liquidGlass(cornerRadius: 22, tint: .blue, elevated: true)
    }

    private var labsBadge: some View {
        Text("LABS")
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue, in: Capsule())
            .accessibilityLabel("Labs feature, in beta")
    }

    private var heroStatus: (text: String, tint: Color) {
        if !sessionIsHere { return ("Running on \(session.sessionPCName)", .orange) }
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

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let problem = session.problem, sessionIsHere {
            messageCard(title: problem.title, message: problem.message, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let notice = session.notice, sessionIsHere {
            messageCard(title: notice.title, message: notice.message, icon: notice.symbol, tint: notice.kind == .done ? .mint : (notice.kind == .note ? .cyan : .orange))
        }
        if let hint = session.placementHint, sessionIsHere, isActiveOnPC || session.isStreaming {
            messageCard(title: "Put it on the \(status?.secondScreen.position ?? position.rawValue)", message: hint, icon: "arrow.left.and.right.square", tint: .cyan)
        }
        // Once, from the first start: Windows sizes text for a desktop monitor on the new display.
        if !scaleTipDismissed, sessionIsHere, session.isStarting || session.isStreaming || isActiveOnPC {
            HStack(alignment: .top, spacing: 12) {
                OrbitIconBadge(systemName: "textformat.size", tint: .cyan, size: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text too small?").font(.subheadline.weight(.semibold))
                    Text(OrbitSecondScreenScaleTip.message(device: "this \(deviceName)"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Got It") { scaleTipDismissed = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .liquidGlass(cornerRadius: 18, tint: .cyan)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        if !context.hasPC {
            // Nothing to check yet: without a paired PC the session only knows that it is "offline".
            messageCard(title: "Pair a PC first", message: "Find and pair your PC in My PCs, then come back to use this \(deviceName) as its second screen.",
                        icon: "desktopcomputer", tint: .orange)
        } else {
            pcAvailabilityNotice
        }
    }

    @ViewBuilder
    private var pcAvailabilityNotice: some View {
        switch session.availability {
        case .offline:
            messageCard(title: "\(pcName) is offline", message: "Wake it or connect to it to use it with a second screen.", icon: "wifi.slash", tint: .orange)
        case .olderAgent:
            messageCard(title: "Update Orbit PC Companion", message: "The companion on \(pcName) doesn't support Second Screen yet. \(OrbitStreamDisplayErrors.updateHint)", icon: "arrow.down.circle.fill", tint: .orange)
        case .failed(let problem):
            messageCard(title: problem.title, message: problem.message, icon: "exclamationmark.triangle.fill", tint: .orange)
        case .unknown, .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking \(pcName)…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 18)
        case .demo:
            messageCard(title: "Demo mode", message: "This is a sample PC. Pair your own PC to use this \(deviceName) as its second screen.", icon: "sparkles", tint: .orange)
        case .available:
            EmptyView()
        }
    }

    private func messageCard(title: String, message: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .liquidGlass(cornerRadius: 18, tint: tint)
        .accessibilityElement(children: .combine)
    }

    // MARK: Requirements

    private var hostChecks: [OrbitDisplayCheck] {
        OrbitSecondScreenSession.hostChecks(host: sunshine, isDemo: vm.isDemoMode, pcName: pcName)
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(hostChecks) { check in
                VStack(alignment: .leading, spacing: 8) {
                    OrbitDisplayCheckRow(check: check)
                    if check.kind == .pairing, check.state == .missing {
                        Button { showsPairing = true } label: { Label("Pair with Sunshine…", systemImage: "link") }
                            .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
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
        .liquidGlass(cornerRadius: 20)
    }

    @ViewBuilder
    private func checkAction(_ check: OrbitDisplayCheck, status: OrbitStreamDisplayStatus) -> some View {
        switch check.kind {
        case .login where check.state == .missing:
            // Missing, or turned down by Sunshine (not while Sunshine is stopped: the login may be fine).
            OrbitSunshineLoginForm(pcName: pcName, isSaving: savingLogin, accent: theme.accent) { name, secret in
                await saveLogin(username: name, password: secret)
            }
        case .sunshine where status.sunshineStopped && context.canStartSunshine:
            OrbitStartSunshineButton(pcName: pcName, isStarting: session.isStartingSunshine, accent: theme.accent) {
                Task {
                    await session.startSunshine(context: context)
                    await sunshine.refresh()
                }
            }
        case .driver where check.state != .done && status.offersInstallCommand:
            OrbitDriverInstallCommand(command: status.driverInstallCommand, accent: theme.accent)
        case .idle where status.appRunning == true && status.streamActive != true && sunshine.isPaired:
            // Only an app left running with nobody watching: quitting it never ends someone's stream.
            Button {
                quittingApp = true
                Task {
                    await sunshine.quitRunningApp()
                    await session.refresh(context: context, force: true)
                    quittingApp = false
                }
            } label: {
                Label(quittingApp ? "Quitting…" : "Quit \(sunshine.runningAppTitle ?? "the app") in Sunshine", systemImage: "stop.fill")
            }
            .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
            .disabled(quittingApp)
        default:
            EmptyView()
        }
    }

    // MARK: Position

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Side", selection: Binding(get: { position }, set: { newValue in
                positionRaw = newValue.rawValue
                OrbitHaptics.selection()
                if isActiveOnPC { session.move(to: newValue, context: context, baseSettings: streamSettings.settings) }
            })) {
                ForEach(OrbitSecondScreenPosition.allCases) { side in Text(side.title).tag(side) }
            }
            .pickerStyle(.segmented)
            .disabled(session.isBusy || session.isMoving || !sessionIsHere)
            .accessibilityLabel("Side of your main monitor")

            arrangementDiagram

            VStack(alignment: .leading, spacing: 4) {
                Text("Windows puts the virtual display to the \(position.rawValue) of your main monitor: move the mouse past that edge to reach it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Size: \(target.size.description) at \(refreshRate) Hz, every pixel of this \(deviceName).")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if session.isMoving {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Moving it…").font(.caption) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    private var arrangementDiagram: some View {
        let monitor = VStack(spacing: 4) {
            Image(systemName: "display").font(.system(size: 30, weight: .regular))
            Text(pcName).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        let device = VStack(spacing: 4) {
            Image(systemName: deviceName == "iPad" ? "ipad.landscape" : "iphone.landscape").font(.system(size: 26, weight: .regular))
            Text("This \(deviceName)").font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        return HStack(spacing: 10) {
            if position == .left { device; monitor } else { monitor; device }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: position)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This \(deviceName) sits to the \(position.rawValue) of \(pcName)'s main monitor")
    }

    // MARK: Action

    private var startBlocker: String? {
        session.startBlocker(context: context, host: sunshine, size: target.size.displaySize)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.phase {
            case .preparing(let message) where sessionIsHere:
                OrbitDisplayWorkRow(title: message, waitsForPrompt: status?.lists(target.size.displaySize, refreshRate: refreshRate) != true,
                                    detail: "Then Sunshine restarts on the PC to use it. This can take up to a minute.")
            case .waitingForSunshine where sessionIsHere:
                OrbitDisplayWorkRow(title: "Waiting for Sunshine to restart…", detail: "The stream opens as soon as Sunshine answers again.")
            case .stopping(let message) where sessionIsHere:
                OrbitDisplayWorkRow(title: message, detail: "Sunshine restarts on the PC to put its display settings back.")
            default:
                if isActiveOnPC && sessionIsHere {
                    Text("The second screen is on").font(.headline)
                    Text(session.isStreaming ? "It is streaming to this \(deviceName)." : "\(pcName) still has the virtual display. Show it here again, or turn it off so Sunshine \(status?.fill.enabled == true ? "goes back to Fill Screen" : "streams the main monitor").")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { start() } label: { Label("Show It Here", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent))
                            .disabled(startBlocker != nil || session.isStreaming)
                        Button(role: .destructive) { confirmStop = true } label: { Label("Turn Off", systemImage: "power").frame(maxWidth: .infinity) }
                            .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
                    }
                } else {
                    Button { start() } label: {
                        Label("Start Second Screen", systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(OrbitProminentButtonStyle(colors: [theme.accent, theme.secondary]))
                    .disabled(startBlocker != nil || session.isBusy)
                    .accessibilityHint(startBlocker ?? "Turns on the virtual display on \(pcName) and streams it here")
                    Text(startBlocker ?? "Orbit turns on the virtual display, Sunshine restarts once, then the stream opens here. End the stream to turn it off again.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            bullet("display.2", "Orbit adds a virtual display (the free Virtual Display Driver) at this \(deviceName)'s exact size and has Sunshine stream it, so it fills the screen.")
            bullet("hand.tap", "Touch works directly: tap to click and drag to move windows. A three-finger tap shows the stream controls.")
            bullet("rectangle.landscape.rotate", "Hold this \(deviceName) in landscape: Windows sees it as a landscape monitor.")
            bullet("speaker.wave.2", "Sound keeps playing on \(pcName), as with any other monitor; this \(deviceName) stays quiet.")
            bullet("textformat.size", OrbitSecondScreenScaleTip.message(device: "this \(deviceName)"))
            bullet("stop.circle", "Ending the stream turns the virtual display off and puts Sunshine's settings back. Normal streams then \(status?.fill.enabled == true ? "fill the screen again, as Fill Screen is on" : "show the main monitor again").")
            bullet("flask", canUndo
                   ? "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. If something looks wrong, Undo Orbit's Changes below puts Sunshine's display settings back."
                   : "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. Orbit saves Sunshine's display settings before changing them, so they can always be put back.")
            if canUndo {
                Button { confirmRevert = true } label: { Label("Undo Orbit's Changes…", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
                    .disabled(session.isBusy)
                    .accessibilityHint("Turns Fill Screen and the second screen off and puts Sunshine's display settings back")
                    .padding(.top, 4)
                    // On iPad the dialog points at this button.
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
        .liquidGlass(cornerRadius: 20)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 22).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func start() {
        OrbitHaptics.press()
        session.start(context: context, host: sunshine, baseSettings: streamSettings.settings, target: target, position: position) {}
    }

    private func reload(force: Bool) async {
        if !vm.isDemoMode, !vm.selectedPCID.isEmpty {
            sunshine.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                               httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
            if vm.metrics.isOnline { await sunshine.refresh() }
        }
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

/// The Stream tab's warning while the PC still has the second screen on (left on by a stream that ended without turning
/// it off, a closed app or another device): every stream from it then shows the extra display, not the main monitor.
/// Turn Off is never Pro-gated: it only undoes Orbit's change.
struct SecondScreenLeftOnBanner: View {
    @ObservedObject var vm: OrbitViewModel
    /// The Stream tab's Sunshine host: Turn Off closes a Desktop session left running with it.
    let host: MoonlightHostCoordinator
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @Environment(\.orbitTheme) private var theme
    /// Turn Off was selected here, for this PC: its progress and result show here too.
    @State private var turnedOffFor: String?

    private var context: OrbitStreamDisplayContext { vm.streamDisplayContext }
    private var pcID: String { context.pcID }
    private var mine: Bool { turnedOffFor == pcID && (session.sessionPCID == nil || session.sessionPCID == pcID) }

    var body: some View {
        if vm.metrics.isOnline || vm.isDemoMode {
            if mine, case .stopping(let step) = session.phase {
                card(title: "Turning off the second screen…", message: step, tint: .orange) { ProgressView().tint(.orange) }
            } else if session.isLeftOn(pcID) {
                card(title: "Second Screen is still on for \(context.pcName)",
                     message: "Until it's turned off, streams from \(context.pcName) show its extra virtual display, not the main monitor.",
                     tint: .orange) {
                    OrbitIconBadge(systemName: "rectangle.on.rectangle", tint: .orange, size: 34)
                } footer: {
                    if mine, let problem = session.problem {
                        Text("\(problem.title): \(problem.message)").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        OrbitHaptics.press()
                        turnedOffFor = pcID
                        session.stop(context: context, host: host)
                    } label: {
                        Label("Turn Off", systemImage: "power").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .orange))
                    .disabled(!session.canTurnOff(pcID))
                    .accessibilityHint("Turns the virtual display on \(context.pcName) off and puts Sunshine's display settings back")
                }
            } else if mine, let notice = session.notice, notice.kind != .note {
                card(title: notice.kind == .demo ? "Demo mode" : "Second Screen is off", message: notice.message, tint: .mint) {
                    OrbitIconBadge(systemName: notice.symbol, tint: .mint, size: 34)
                } footer: {
                    Button("OK") { turnedOffFor = nil }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(theme.accent)
                }
            }
        }
    }

    private func card<Icon: View, Footer: View>(title: String, message: String, tint: Color, @ViewBuilder icon: () -> Icon,
                                                @ViewBuilder footer: () -> Footer = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                footer()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
/// Screens of this feature without taps, for Simulator checks against a pretend PC (Debug builds only).
///
/// `ORBIT_STREAM_DISPLAY_SELFTEST=<mode>` (as `SIMCTL_CHILD_ORBIT_STREAM_DISPLAY_SELFTEST` with `xcrun simctl launch`)
/// waits for the paired PC to come online, then shows one screen full screen:
/// - `settings`: Stream Settings with Picture set to Fill Screen (the PC's readiness next to it);
/// - `fill`: the Fill the Screen page; `ORBIT_SELFTEST_ACTION=login,setup,only,off,revert` (any of them, in order)
///   runs those actions 3 s apart (`login` saves `ORBIT_SELFTEST_LOGIN`, "user:password", on the PC);
/// - `second`: Second Screen; `ORBIT_SELFTEST_ACTION=pair,start,close,off,revert,refresh` (any of them, in order): `pair`
///   pairs Orbit with Sunshine first (the companion types the PIN), `start` does what Start does, `close` closes the stream
///   as its Close button does, `off` is Turn Off, `revert` is Undo Orbit's Changes, `refresh` reads the PC again. Each
///   step prints the session's state.
/// - `library`: the Stream tab (with Second Screen's left-on banner); `ORBIT_SELFTEST_ACTION=guard,off` (in order): `guard`
///   asks to stream Desktop as tapping it does (the confirmation shows while the second screen is on), `off` is the
///   banner's Turn Off.
/// - `tools`: the Tools tab (the Second Screen tile's badge).
/// - `fill` also takes `start`: Start Sunshine (with Sunshine stopped on the PC).
/// `ORBIT_SELFTEST_SCROLL_Y=<points>|top|bottom` scrolls the screen there once it shows and after every step, for
/// screenshots of the lower parts.
enum OrbitStreamDisplaySelfTest {
    /// Scrolls the screen in front (its tallest scroll view) to `ORBIT_SELFTEST_SCROLL_Y`.
    @MainActor
    static func applyScroll() async {
        guard let value = ProcessInfo.processInfo.environment["ORBIT_SELFTEST_SCROLL_Y"] else { return }
        try? await Task.sleep(for: .milliseconds(800))   // the screen lays out what the last step changed
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        func scrollViews(in view: UIView) -> [UIScrollView] {
            var found: [UIScrollView] = []
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { found.append(scroll) }
            for subview in view.subviews { found += scrollViews(in: subview) }
            return found
        }
        guard let root = top?.view, let scroll = scrollViews(in: root).max(by: { $0.contentSize.height < $1.contentSize.height }) else { return }
        let lowest = -scroll.adjustedContentInset.top
        let highest = max(lowest, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let wanted = value == "bottom" ? highest : (value == "top" ? lowest : (Double(value).map { CGFloat($0) } ?? lowest))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(wanted, lowest), highest)), animated: false)
    }

    static func start(mode: String) {
        Task { @MainActor in
            var model: OrbitViewModel?
            for _ in 0..<80 {
                if let vm = OrbitWatchBridge.shared.viewModel, vm.metrics.isOnline || vm.isDemoMode { model = vm; break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let vm = model else { print("selftest: no PC online"); return }
            try? await Task.sleep(for: .seconds(1))
            if mode == "settings" || mode == "fill" { MoonlightStreamSettingsStore.shared.settings.aspect = .native }
            let host = UIHostingController(rootView: OrbitStreamDisplaySelfTestScreen(vm: vm, mode: mode).orbitAppearance().preferredColorScheme(.dark))
            host.modalPresentationStyle = .fullScreen
            host.overrideUserInterfaceStyle = .dark
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            top?.present(host, animated: false)
            print("selftest: showing \(mode) for \(vm.selectedPCName)")
        }
    }
}

private struct OrbitStreamDisplaySelfTestScreen: View {
    @ObservedObject var vm: OrbitViewModel
    let mode: String
    @ObservedObject private var store = MoonlightStreamSettingsStore.shared
    @StateObject private var fill = OrbitFillScreenSetupModel()
    @Environment(\.orbitTheme) private var theme

    var body: some View {
        switch mode {
        case "settings":
            MoonlightStreamSettingsView(store: store, accent: theme.accent, hostSupportsHEVC: MoonlightHostStore.record(for: vm.selectedPCID)?.supportsHEVC,
                                        displaySetup: vm.streamDisplayContext) {}
                .task {
                    try? await Task.sleep(for: .seconds(4))   // the PC's readiness arrives
                    await OrbitStreamDisplaySelfTest.applyScroll()
                }
        case "fill":
            NavigationStack {
                MoonlightFillScreenSetupView(model: fill, size: store.settings.pixelSize(hostSupportsHEVC: nil), refreshRate: store.settings.frameRate,
                                             optimizeGameSettings: $store.settings.optimizeGameSettings, accent: theme.accent)
            }
            .task {
                await vm.fetchSunshineApps()   // whether the companion can start Sunshine (`sunshineInfo`)
                fill.configure(vm.streamDisplayContext)
                await fill.load(force: true)
                await OrbitStreamDisplaySelfTest.applyScroll()
                let environment = ProcessInfo.processInfo.environment
                // Comma-separated, run in order 3 s apart; `login` saves ORBIT_SELFTEST_LOGIN ("user:password").
                for action in (environment["ORBIT_SELFTEST_ACTION"] ?? "").split(separator: ",").map(String.init) {
                    try? await Task.sleep(for: .seconds(3))
                    let size = store.settings.pixelSize(hostSupportsHEVC: nil).displaySize
                    switch action {
                    case "login":
                        let parts = (environment["ORBIT_SELFTEST_LOGIN"] ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2 { _ = await fill.saveLogin(username: parts[0], password: parts[1]) }
                    case "setup": await fill.setUp(size: size, refreshRate: store.settings.frameRate, onlyDisplay: false)
                    case "only": await fill.setOnlyDisplay(true)
                    case "off": await fill.turnOff()
                    case "revert": await fill.revert()
                    case "start": await fill.startSunshine()
                    default: break
                    }
                    let fills = fill.status?.fillsScreen(size: size, refreshRate: store.settings.frameRate) == true
                    print("selftest: \(action) → \(fill.outcome.map { "\($0.title): \($0.message)" } ?? "no outcome") · fills \(fills)")
                    await OrbitStreamDisplaySelfTest.applyScroll()
                }
            }
        case "library":
            OrbitStreamDisplayLibrarySelfTestScreen(vm: vm)
        case "tools":
            CompanionToolsView(vm: vm)
                .task {
                    try? await Task.sleep(for: .seconds(5))   // the light read arrives
                    print("selftest: tools · second screen on \(OrbitSecondScreenSession.shared.isActiveOnPC(vm.streamDisplayContext.pcID))")
                    await OrbitStreamDisplaySelfTest.applyScroll()
                }
        default:
            OrbitSecondScreenSelfTestScreen(vm: vm)
        }
    }
}

/// The Stream tab with scripted steps (`OrbitStreamDisplaySelfTest`, mode `library`).
private struct OrbitStreamDisplayLibrarySelfTestScreen: View {
    @ObservedObject var vm: OrbitViewModel
    @StateObject private var host = MoonlightHostCoordinator()
    @State private var check: OrbitSecondScreenStreamCheck?

    var body: some View {
        GameLibraryView(vm: vm)
            .secondScreenStreamGuard($check, context: vm.streamDisplayContext, host: host)
            .task { await run() }
    }

    private func run() async {
        await vm.fetchSunshineApps()   // Sunshine's ports on this PC (`sunshineInfo`)
        host.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                       httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        await host.refresh()
        let session = OrbitSecondScreenSession.shared
        try? await Task.sleep(for: .seconds(4))   // the library's own light read arrives
        let pcID = vm.streamDisplayContext.pcID
        print("selftest: library · left on \(session.isLeftOn(pcID)) · check \(session.checkNormalStream(pcID: pcID))")
        for action in (ProcessInfo.processInfo.environment["ORBIT_SELFTEST_ACTION"] ?? "").split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(3))
            switch action {
            case "guard":
                check = OrbitSecondScreenStreamCheck(pcID: pcID) { print("selftest: guard → Stream Anyway") }
                print("selftest: guard → \(check.map { "\($0.check)" } ?? "go")")
            case "off":
                session.stop(context: vm.streamDisplayContext, host: host)
                for _ in 0..<400 where session.isBusy { try? await Task.sleep(for: .milliseconds(500)) }
                print("selftest: off → left on \(session.isLeftOn(pcID)) · problem \(session.problem.map { "\($0.title): \($0.message)" } ?? "none") · notice \(session.notice?.message ?? "none") · this screen's Sunshine shows \(host.runningAppTitle ?? "nothing") running")
            default:
                break
            }
        }
    }
}

/// Second Screen with scripted steps (`OrbitStreamDisplaySelfTest`, mode `second`).
private struct OrbitSecondScreenSelfTestScreen: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var stream = MoonlightStreamController.shared
    @StateObject private var host = MoonlightHostCoordinator()
    @Environment(\.orbitTheme) private var theme
    @State private var showsScreen = false

    var body: some View {
        NavigationStack {
            if showsScreen { SecondScreenView(vm: vm) } else { ProgressView("Pairing with Sunshine…") }
        }
        // The app's root cannot present the stream over this test screen, so it is presented here.
        .fullScreenCover(isPresented: $stream.isPresented) { MoonlightStreamScreen(controller: stream, accent: theme.accent) }
        .task { await run() }
    }

    private func configureHost() async {
        await vm.fetchSunshineApps()   // Sunshine's ports on this PC (`sunshineInfo`)
        host.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                       httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        await host.refresh()
    }

    private func run() async {
        var actions = (ProcessInfo.processInfo.environment["ORBIT_SELFTEST_ACTION"] ?? "").split(separator: ",").map(String.init)
        // Like SecondScreenView's own coordinator: Turn Off closes a Desktop session left running with it.
        await configureHost()
        if actions.first == "pair" {
            actions.removeFirst()
            await pairWithSunshine()
        }
        showsScreen = true
        let session = OrbitSecondScreenSession.shared
        try? await Task.sleep(for: .seconds(3))   // the PC's readiness arrives
        await OrbitStreamDisplaySelfTest.applyScroll()
        for action in actions {
            try? await Task.sleep(for: .seconds(4))
            switch action {
            case "start":
                await configureHost()
                let base = MoonlightStreamSettingsStore.shared.settings
                let target = MoonlightStreamTarget.make(settings: OrbitSecondScreenSession.streamSettings(from: base), hostSupportsHEVC: host.hostSupportsHEVC)
                let position = OrbitSecondScreenPosition(rawValue: UserDefaults.standard.string(forKey: OrbitSecondScreenPosition.storageKey) ?? "") ?? .right
                print("selftest: start at \(target.size) · Sunshine \(vm.cleanHost()):\(vm.sunshineInfo?.httpPort ?? 0) paired \(host.isPaired)")
                session.start(context: vm.streamDisplayContext, host: host, baseSettings: base, target: target, position: position) {}
                await waitWhileBusy(session)
                try? await Task.sleep(for: .seconds(3))   // the stream request runs
            case "close":
                stream.end(quitApp: false)
                try? await Task.sleep(for: .seconds(1))
                await waitWhileBusy(session)
            case "off":
                session.stop(context: vm.streamDisplayContext, host: host)
                await waitWhileBusy(session)
            case "revert":
                session.revert(context: vm.streamDisplayContext)
                await waitWhileBusy(session)
            case "refresh":
                await session.refresh(context: vm.streamDisplayContext, force: true)
            default:
                break
            }
            print("selftest: \(action) → phase \(session.phase) · stream \(stream.isPresented ? "\(stream.request?.app.title ?? "?") (second screen \(stream.request?.secondScreen == true), \(stream.request?.target.size.description ?? ""))" : "closed") · error \(stream.launchError ?? "none") · problem \(session.problem.map { "\($0.title): \($0.message)" } ?? "none") · notice \(session.notice?.message ?? "none") · hint \(session.placementHint ?? "none")")
            if !stream.isPresented { await OrbitStreamDisplaySelfTest.applyScroll() }
        }
    }

    private func waitWhileBusy(_ session: OrbitSecondScreenSession) async {
        for _ in 0..<400 where session.isBusy { try? await Task.sleep(for: .milliseconds(500)) }
    }

    private func pairWithSunshine() async {
        let automation = MoonlightPairingAutomation(canSubmitPIN: true, canStartSunshine: false, sunshineRunning: true, client: { try vm.companionClient() })
        host.beginPairing()
        guard let pin = host.pairingPIN else { print("selftest: Sunshine pairing did not start · \(host.lastError ?? "")"); return }
        try? await Task.sleep(for: .milliseconds(1500))
        do { try await automation.submitPIN(pin) } catch { print("selftest: PIN not accepted: \(error.localizedDescription)") }
        for _ in 0..<240 where host.isPairing { try? await Task.sleep(for: .milliseconds(500)) }
        print("selftest: Sunshine pairing → paired \(host.isPaired) · \(host.pairingStage ?? host.lastError ?? "")")
    }
}
#endif
