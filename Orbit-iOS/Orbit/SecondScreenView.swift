import MoonlightCore
import SwiftUI
import UIKit

// Second Screen on iPhone and iPad (DESIGN F9, Orbit Pro, Labs): Tools › Second Screen. The PC gets a
// virtual display at this device's exact size, next to its monitor, and Orbit streams it here with direct
// touch. Ending the stream turns it off again (`OrbitSecondScreenSession`).

extension OrbitViewModel {
    /// The selected PC, for the Fill Screen setup in Stream Settings and for Second Screen.
    var streamDisplayContext: OrbitStreamDisplayContext {
        OrbitStreamDisplayContext(pcID: selectedPCID, pcName: selectedPCName.isEmpty ? "your PC" : selectedPCName, isDemo: isDemoMode,
                                  isOnline: metrics.isOnline, makeClient: { try self.companionClient() })
    }
}

struct SecondScreenView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var session = OrbitSecondScreenSession.shared
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @StateObject private var sunshine = MoonlightHostCoordinator()
    @AppStorage(OrbitSecondScreenPosition.storageKey) private var positionRaw = OrbitSecondScreenPosition.right.rawValue
    @Environment(\.orbitTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPairing = false
    @State private var confirmStop = false
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
    private var status: OrbitStreamDisplayStatus? { session.statusPCID == vm.selectedPCID ? session.status : nil }
    private var isActiveOnPC: Bool { status?.secondScreen.active == true }
    /// The running session (if any) belongs to this PC.
    private var sessionIsHere: Bool { session.sessionPCID == nil || session.sessionPCID == vm.selectedPCID }
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
        .task(id: syncKey) { await reload(force: false) }
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
    }

    @ViewBuilder
    private var availabilityNotice: some View {
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
        case .login where check.state != .done:
            OrbitSunshineLoginForm(pcName: pcName, isSaving: savingLogin, accent: theme.accent) { name, secret in
                await saveLogin(username: name, password: secret)
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
                OrbitDisplayWorkRow(title: message, detail: "Sunshine restarts on the PC to show the main monitor again.")
            default:
                if isActiveOnPC && sessionIsHere {
                    Text("The second screen is on").font(.headline)
                    Text(session.isStreaming ? "It is streaming to this \(deviceName)." : "\(pcName) still has the virtual display. Show it here again, or turn it off so Sunshine streams the main monitor.")
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
            bullet("stop.circle", "Ending the stream turns the virtual display off and puts Sunshine's settings back. Normal streams then show the main monitor again.")
            bullet("flask", "Labs: this relies on the driver and on Sunshine switching displays, which can behave differently on some PCs. If something looks wrong, use Undo Orbit's Changes in Stream Settings › Fill Screen.")
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

#if DEBUG
/// Screens of this feature without taps, for Simulator checks against a pretend PC (Debug builds only).
///
/// `ORBIT_STREAM_DISPLAY_SELFTEST=<mode>` (as `SIMCTL_CHILD_ORBIT_STREAM_DISPLAY_SELFTEST` with `xcrun simctl launch`)
/// waits for the paired PC to come online, then shows one screen full screen:
/// - `settings`: Stream Settings with Picture set to Fill Screen (the PC's readiness next to it);
/// - `fill`: the Fill the Screen page; `ORBIT_SELFTEST_ACTION=login,setup,only,off,revert` (any of them, in order)
///   runs those actions 3 s apart (`login` saves `ORBIT_SELFTEST_LOGIN`, "user:password", on the PC);
/// - `second`: Second Screen.
enum OrbitStreamDisplaySelfTest {
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
        case "fill":
            NavigationStack {
                MoonlightFillScreenSetupView(model: fill, size: store.settings.pixelSize(hostSupportsHEVC: nil), refreshRate: store.settings.frameRate,
                                             optimizeGameSettings: $store.settings.optimizeGameSettings, accent: theme.accent)
            }
            .task {
                fill.configure(vm.streamDisplayContext)
                await fill.load(force: true)
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
                    default: break
                    }
                    let fills = fill.status?.fillsScreen(size: size, refreshRate: store.settings.frameRate) == true
                    print("selftest: \(action) → \(fill.outcome.map { "\($0.title): \($0.message)" } ?? "no outcome") · fills \(fills)")
                }
            }
        default:
            NavigationStack { SecondScreenView(vm: vm) }
        }
    }
}
#endif
