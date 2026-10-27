#if !os(tvOS)
import MoonlightCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Fill Screen setup on the PC (DESIGN F5), iPhone/iPad and Mac: Stream Settings reads the PC's readiness
// from GET /api/stream/display and sets it up (POST …/modes with this screen's stream size, then …/fill).
// The second screen (F9) reuses the context, the feature cache and the small views at the bottom.
// Apple TV always streams 16:9 and has none of this.

/// The PC a stream-display screen talks to. `makeClient` builds a pinned client for it when needed.
struct OrbitStreamDisplayContext {
    let pcID: String
    let pcName: String
    let isDemo: Bool
    let isOnline: Bool
    /// A PC is paired (or demo mode is on). Without one, Stream Settings only lists the steps.
    let hasPC: Bool
    let makeClient: @MainActor () throws -> OrbitAPIClient

    /// Changes when the screens must forget what they read (another PC, demo mode, back online).
    var identity: String { "\(pcID)|\(isDemo)|\(isOnline)|\(hasPC)" }
}

/// `GET /api/capabilities` per PC for these screens: 10 minutes, 2 minutes for an older agent (404).
@MainActor
enum OrbitStreamDisplayFeatureCache {
    private static var entries: [String: (features: Set<String>?, at: Date)] = [:]

    static func features(for pcID: String, client: OrbitAPIClient, force: Bool = false) async throws -> Set<String>? {
        if !force, let entry = entries[pcID], Date().timeIntervalSince(entry.at) < (entry.features == nil ? 120 : 600) { return entry.features }
        let found = try await OrbitStreamDisplayAPI.features(client)
        entries[pcID] = (found, Date())
        return found
    }
}

/// Keeps the app working while the PC takes its time (someone walks over to approve an administrator
/// prompt): iPhone/iPad keep the screen on and finish the request if Orbit goes to the background;
/// the Mac keeps App Nap away.
@MainActor
final class OrbitLongRequestGuard {
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var heldIdleTimer = false
    #elseif os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    init(reason: String) {
        #if os(iOS)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // iOS calls this on the main thread when the time is up and expects the task to end right here.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        if !UIApplication.shared.isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = true
            heldIdleTimer = true
        }
        #elseif os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        #endif
    }

    func end() {
        #if os(iOS)
        if heldIdleTimer {
            heldIdleTimer = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        endBackgroundTask()
        #elseif os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

// MARK: - Model

@MainActor
final class OrbitFillScreenSetupModel: ObservableObject {
    enum Availability: Equatable {
        case unknown, checking, available, demo, offline
        /// The PC's agent predates the setup (no `streamDisplay` feature, or no /api/capabilities at all).
        case olderAgent
        case failed(OrbitStreamDisplayProblem)
    }

    enum Work: Equatable {
        case addingSize(OrbitDisplaySize)
        case configuringSunshine
        case changingMonitor
        case turningOff
        case reverting
        case savingLogin

        /// Adding a screen size can show an administrator prompt on the PC.
        var waitsForPrompt: Bool { if case .addingSize = self { return true }; return false }
    }

    struct Outcome: Equatable {
        var title: String
        var message: String
        var isError: Bool
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var status: OrbitStreamDisplayStatus?
    @Published private(set) var work: Work?
    @Published private(set) var isRefreshing = false
    @Published var outcome: Outcome?
    private(set) var context: OrbitStreamDisplayContext?
    private var loadedAt: Date?
    private var generation = 0

    var pcName: String { context?.pcName ?? "your PC" }

    /// Hands over the PC the settings belong to; another PC (or demo mode) starts from scratch.
    func configure(_ context: OrbitStreamDisplayContext?) {
        guard context?.identity != self.context?.identity else {
            self.context = context
            return
        }
        generation += 1
        self.context = context
        status = nil
        outcome = nil
        work = nil
        loadedAt = nil
        isRefreshing = false
        availability = context == nil ? .unknown : (context!.isDemo ? .demo : (context!.isOnline ? .unknown : .offline))
        if context?.isDemo == true { status = .demo() }
    }

    /// Reads the PC's readiness (at most every 20 s unless `force`).
    func load(force: Bool = false) async {
        guard let context else { return }
        if context.isDemo { availability = .demo; if status == nil { status = .demo() }; return }
        guard context.isOnline else { availability = .offline; return }
        if !force, availability == .available, status != nil, let loadedAt, Date().timeIntervalSince(loadedAt) < 20 { return }
        guard !isRefreshing else { return }
        let version = generation
        isRefreshing = true
        defer { if version == generation { isRefreshing = false } }
        if status == nil { availability = .checking }
        do {
            let client = try context.makeClient()
            let features = try await OrbitStreamDisplayFeatureCache.features(for: context.pcID, client: client, force: force)
            guard version == generation else { return }
            guard let features, features.contains(OrbitStreamDisplayFeature.fill) else {
                status = nil
                availability = .olderAgent
                return
            }
            let fetched = try await OrbitStreamDisplayAPI.status(client)
            guard version == generation else { return }
            status = fetched
            availability = .available
            loadedAt = Date()
        } catch {
            guard version == generation else { return }
            let problem = OrbitStreamDisplayErrors.describe(error)
            if status == nil { availability = .failed(problem) } else { outcome = Outcome(title: "Couldn't check again", message: problem.message, isError: true) }
        }
    }

    var canChange: Bool {
        guard work == nil, let status, let context else { return false }
        return (context.isDemo || (context.isOnline && availability == .available)) && status.loginSaved
    }

    /// Something keeps "Set Up This PC" from working, in plain words (nil: it can run).
    func setUpBlocker() -> String? {
        guard let status else { return nil }
        if !status.loginSaved { return "Save the Sunshine login first." }
        if status.sunshineSupported == false { return "Update Sunshine on the PC first." }
        if !status.driverUsable { return "Install the Virtual Display Driver on the PC first." }
        return nil
    }

    /// "Set Up This PC": adds this screen's size to the virtual display when it is missing (maybe one
    /// administrator prompt on the PC), then points Sunshine at the virtual display.
    func setUp(size: OrbitDisplaySize, refreshRate: Int, onlyDisplay: Bool) async {
        guard work == nil, let context else { return }
        outcome = nil
        if context.isDemo {
            work = .addingSize(size)
            try? await Task.sleep(nanoseconds: 900_000_000)
            work = .configuringSunshine
            try? await Task.sleep(nanoseconds: 700_000_000)
            let listed = (status?.virtualDisplay.resolutions ?? []).compactMap(Self.size(fromKey:)) + [size]
            status = .demo(listing: listed, rates: (status?.virtualDisplay.refreshRates ?? []) + [OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate)],
                           fillOn: true)
            work = nil
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC. On your own PC this adds \(size) to the virtual display and points Sunshine at it.", isError: false)
            return
        }
        guard setUpBlocker() == nil else { return }
        let client: OrbitAPIClient
        do { client = try context.makeClient() } catch { report(error); return }
        let version = generation
        let rate = OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate)
        let keepAwake = OrbitLongRequestGuard(reason: "Setting up the PC for full-screen streaming")
        defer { keepAwake.end() }
        do {
            var restartNote: String?
            var addedSize = false
            if status?.lists(size, refreshRate: rate) != true {
                work = .addingSize(size)
                let added = try await OrbitStreamDisplayAPI.addMode(client, size: size, refreshRate: rate)
                guard version == generation else { return }
                addedSize = added.changed
                if let display = added.display { status = display }
                // The driver could not be restarted now: it reads its sizes again when it next starts.
                if added.reload == "nextStart" { restartNote = OrbitStreamDisplayAPI.nextStartNote(size: size, pcName: context.pcName) }
            }
            work = .configuringSunshine
            let result = try await OrbitStreamDisplayAPI.setFill(client, enabled: true, onlyDisplay: onlyDisplay)
            guard version == generation else { return }
            if let display = result.display { status = display }
            loadedAt = Date()
            work = nil
            var message: String
            if result.changed {
                message = "Sunshine on \(context.pcName) now streams the virtual display in this screen's shape. Start a stream to try it."
            } else if addedSize {
                // Fill Screen was already on (set up from another device): only this screen's size was missing.
                message = "\(context.pcName)'s virtual display now offers \(size) at \(rate) Hz, and Sunshine already streams it. Start a stream to try it."
            } else {
                message = "Everything was already set up on \(context.pcName)."
            }
            if result.sunshineReady == false { message += " Sunshine is still restarting: give it a few seconds." }
            if let restartNote { message += " \(restartNote)" }
            if let warning = result.cleanWarning { message += " \(warning)" }
            let filled = status?.fillsScreen(size: size, refreshRate: rate) == true && restartNote == nil
            outcome = Outcome(title: filled ? "\(context.pcName) fills this screen" : "Set up, with a note", message: message, isError: false)
        } catch {
            guard version == generation else { return }
            work = nil
            report(error, waitedForChange: true)
            await refreshQuietly(client, version: version)
        }
    }

    /// Changes "Turn off the PC's monitor while streaming" while Fill Screen is on.
    func setOnlyDisplay(_ enabled: Bool) async {
        await change(.changingMonitor, success: enabled ? "The PC's own monitor now turns off while you stream." : "The PC's own monitor stays on while you stream.") { client in
            try await OrbitStreamDisplayAPI.setFill(client, enabled: true, onlyDisplay: enabled)
        } demo: { status in
            status.fill.onlyDisplay = enabled
        }
    }

    /// "Turn Off": Sunshine streams the PC's monitor again (Orbit's keys go back to what they were).
    func turnOff() async {
        await change(.turningOff, success: "Fill Screen is off on \(pcName). Sunshine streams its main monitor again.") { client in
            try await OrbitStreamDisplayAPI.setFill(client, enabled: false)
        } demo: { status in
            status = .demo(listing: status.virtualDisplay.resolutions.compactMap(Self.size(fromKey:)), rates: status.virtualDisplay.refreshRates, fillOn: false)
        }
    }

    /// "Undo Orbit's changes": Fill Screen and the second screen off, Sunshine's settings from before Orbit.
    func revert() async {
        await change(.reverting, success: "Sunshine's display settings on \(pcName) are back to how they were before Orbit changed them.") { client in
            try await OrbitStreamDisplayAPI.revert(client)
        } demo: { status in
            status = .demo(listing: status.virtualDisplay.resolutions.compactMap(Self.size(fromKey:)), rates: status.virtualDisplay.refreshRates, fillOn: false)
        }
    }

    /// Saves Sunshine's web UI login on the PC (the same route the pairing screen uses).
    func saveLogin(username: String, password: String) async -> Bool {
        guard work == nil, let context else { return false }
        outcome = nil
        if context.isDemo {
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC.", isError: false)
            return true
        }
        let version = generation
        work = .savingLogin
        defer { if version == generation { work = nil } }
        do {
            let automation = MoonlightPairingAutomation(canSubmitPIN: false, canStartSunshine: false, sunshineRunning: true, client: { try context.makeClient() })
            try await automation.saveLogin(username: username, password: password)
            guard version == generation else { return false }
            work = nil
            await load(force: true)
            if let status, status.loginSaved, status.sunshineVersion == nil, let reason = status.reason {
                // Saved on the PC, but Sunshine refused it (or did not answer).
                outcome = Outcome(title: "Saved, but Sunshine didn't accept it", message: reason, isError: true)
            } else {
                outcome = Outcome(title: "Login saved", message: "Orbit can now change Sunshine's display settings on \(context.pcName).", isError: false)
            }
            return true
        } catch {
            guard version == generation else { return false }
            report(error)
            return false
        }
    }

    private func change(_ kind: Work, success: String, request: @escaping (OrbitAPIClient) async throws -> OrbitStreamDisplayResult,
                        demo: (inout OrbitStreamDisplayStatus) -> Void) async {
        guard work == nil, let context else { return }
        outcome = nil
        if context.isDemo {
            work = kind
            try? await Task.sleep(nanoseconds: 600_000_000)
            if var current = status { demo(&current); status = current }
            work = nil
            outcome = Outcome(title: "Demo mode", message: "Nothing was sent to a PC.", isError: false)
            return
        }
        let client: OrbitAPIClient
        do { client = try context.makeClient() } catch { report(error); return }
        let version = generation
        let keepAwake = OrbitLongRequestGuard(reason: "Changing Sunshine's display settings")
        defer { keepAwake.end() }
        work = kind
        do {
            let result = try await request(client)
            guard version == generation else { return }
            if let display = result.display { status = display }
            loadedAt = Date()
            work = nil
            var message = result.changed ? success : "Nothing needed to change on \(context.pcName)."
            if result.sunshineReady == false { message += " Sunshine is still restarting: give it a few seconds." }
            if let warning = result.cleanWarning { message += " \(warning)" }
            outcome = Outcome(title: "Done", message: message, isError: false)
        } catch {
            guard version == generation else { return }
            work = nil
            report(error, waitedForChange: true)
            await refreshQuietly(client, version: version)
        }
    }

    private func report(_ error: Error, waitedForChange: Bool = false) {
        let problem = OrbitStreamDisplayErrors.describe(error, waitedForChange: waitedForChange)
        outcome = Outcome(title: problem.title, message: problem.message, isError: true)
    }

    /// After a failed change: show what the PC has now (a size may have been added before Sunshine refused).
    private func refreshQuietly(_ client: OrbitAPIClient, version: Int) async {
        guard let fetched = try? await OrbitStreamDisplayAPI.status(client), version == generation else { return }
        status = fetched
        loadedAt = Date()
    }

    nonisolated static func size(fromKey key: String) -> OrbitDisplaySize? {
        let parts = key.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return OrbitDisplaySize(width: width, height: height)
    }
}

extension MoonlightStreamSize {
    var displaySize: OrbitDisplaySize { OrbitDisplaySize(width: width, height: height) }
}

// MARK: - Shared pieces

/// Copies text to the clipboard on iPhone, iPad and Mac.
enum OrbitClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// One requirement with its state icon.
struct OrbitDisplayCheckRow: View {
    let check: OrbitDisplayCheck

    private var icon: (name: String, tint: Color) {
        switch check.state {
        case .done: return ("checkmark.circle.fill", .mint)
        case .missing: return ("exclamationmark.circle.fill", .orange)
        case .unknown: return ("questionmark.circle", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.tint)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.callout.weight(.semibold))
                if let detail = check.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.title): \(check.state == .done ? "done" : (check.state == .missing ? "needed" : "not known"))")
        .accessibilityValue(check.detail ?? "")
    }
}

/// The Virtual Display Driver's winget command, selectable, with Copy and a link to the project.
struct OrbitDriverInstallCommand: View {
    let command: String
    var accent: Color
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Install command: \(command)")
            HStack(spacing: 14) {
                Button {
                    OrbitClipboard.copy(command)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Link(destination: OrbitStreamDisplayStatus.driverURL) {
                    Label("About the driver", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .tint(accent)
        }
    }
}

/// Saves Sunshine's web UI login on the PC.
struct OrbitSunshineLoginForm: View {
    var pcName: String
    var isSaving: Bool
    var accent: Color
    var onSave: (_ username: String, _ password: String) async -> Bool
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Sunshine username", text: $username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                #endif
            SecureField("Sunshine password", text: $password)
                #if os(iOS)
                .textContentType(.password)
                #endif
            HStack(spacing: 10) {
                Button {
                    let name = username.trimmingCharacters(in: .whitespaces), secret = password
                    Task {
                        if await onSave(name, secret) { password = "" }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(isSaving ? "Saving…" : "Save on \(pcName)")
                    }
                }
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isSaving)
                Spacer(minLength: 0)
            }
            Text("The login you use for Sunshine's web UI on the PC. It is stored on the PC next to Orbit's token, never on this device.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .tint(accent)
    }
}

/// "Approve the Windows PowerShell prompt on your PC" and the other waits, while the PC works.
struct OrbitDisplayWorkRow: View {
    let title: String
    var waitsForPrompt = false
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if waitsForPrompt {
                    Text("Approve the Windows PowerShell prompt on your PC.")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.yellow)
                    Text("Windows may ask once for administrator permission to add a screen size. Approve it within a minute; if you decline or nobody answers, nothing changes.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A success or error line after a change (or a note, with its own `symbol` and `tint`).
struct OrbitDisplayOutcomeRow: View {
    let title: String
    let message: String
    let isError: Bool
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol ?? (isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(tint ?? (isError ? Color.orange : Color.mint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stream Settings: the PC's readiness next to the Picture control

struct MoonlightFillScreenStatusRow: View {
    @ObservedObject var model: OrbitFillScreenSetupModel
    let size: OrbitDisplaySize
    /// The stream's frame rate: the virtual display needs the size at this refresh rate.
    let refreshRate: Int

    private struct Appearance {
        var icon: String
        var tint: Color
        var title: String
        var detail: String?
        var spinning = false
    }

    private var appearance: Appearance {
        let pc = model.pcName
        switch model.availability {
        case .unknown, .checking:
            return Appearance(icon: "", tint: .secondary, title: "Checking \(pc)…", spinning: true)
        case .offline:
            return Appearance(icon: "wifi.slash", tint: .secondary, title: "\(pc) is offline", detail: "Orbit checks its setup when it's back.")
        case .olderAgent:
            return Appearance(icon: "arrow.down.circle", tint: .secondary, title: "Set up \(pc) by hand",
                              detail: "Update Orbit PC Companion on the PC to check and set this up from here.")
        case .failed(let problem):
            return Appearance(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't check \(pc)", detail: problem.message)
        case .available, .demo:
            guard let status = model.status else { return Appearance(icon: "", tint: .secondary, title: "Checking \(pc)…", spinning: true) }
            if status.secondScreen.active {
                // Sunshine streams the extra display then, whatever Fill Screen's state.
                return Appearance(icon: "rectangle.on.rectangle", tint: .blue, title: "Second Screen is on for \(pc)",
                                  detail: "Until it's turned off, streams show the extra display next to \(pc)'s monitor, not the main one.")
            }
            if let shortfall = status.fillShortfall(size: size, refreshRate: OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate), pcName: pc) {
                return Appearance(icon: "exclamationmark.triangle.fill", tint: .orange, title: "\(pc) isn't set up to fill this screen",
                                  detail: "\(shortfall) Until then you still see black bars.")
            }
            return Appearance(icon: "checkmark.seal.fill", tint: .mint, title: "\(pc) fills this screen",
                              detail: "Its virtual display switches to \(size) for each stream.")
        }
    }

    var body: some View {
        let look = appearance
        // A spinner has no text baseline, so it is centred on the title instead.
        HStack(alignment: look.spinning ? .center : .firstTextBaseline, spacing: 10) {
            if look.spinning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: look.icon).foregroundStyle(look.tint).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.callout.weight(.semibold))
                if let detail = look.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The setup page

/// "Fill the Screen": what the PC has, "Set Up This PC", turning it off and undoing Orbit's changes.
struct MoonlightFillScreenSetupView: View {
    @ObservedObject var model: OrbitFillScreenSetupModel
    let size: MoonlightStreamSize
    let refreshRate: Int
    @Binding var optimizeGameSettings: Bool
    let accent: Color
    @State private var onlyDisplay = false
    @State private var confirmRevert = false

    private var displaySize: OrbitDisplaySize { size.displaySize }
    /// The refresh rate the virtual display needs: the stream's frame rate.
    private var rate: Int { OrbitStreamDisplayAPI.clampedRefreshRate(refreshRate) }
    private var pcName: String { model.pcName }

    var body: some View {
        Form {
            Section {
                Text("Fill Screen asks \(pcName) for a \(size.description) picture at \(refreshRate) fps, the shape of this screen. It fills the screen edge to edge once the PC can output exactly that size, which Orbit sets up with a virtual display.")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("This screen")
            }

            switch model.availability {
            case .unknown, .checking:
                Section { HStack(spacing: 10) { ProgressView(); Text("Checking \(pcName)…").foregroundStyle(.secondary) } }
            case .offline:
                Section {
                    OrbitDisplayOutcomeRow(title: "\(pcName) is offline", message: "Wake it or connect to it, then check again. The steps below work by hand too.", isError: true)
                }
                manualSections
            case .olderAgent:
                Section {
                    OrbitDisplayOutcomeRow(title: "Update Orbit PC Companion", message: "The companion on \(pcName) can't set this up yet. Update it from Settings, or follow the steps below by hand.", isError: true)
                }
                manualSections
            case .failed(let problem):
                Section {
                    OrbitDisplayOutcomeRow(title: problem.title, message: problem.message, isError: true)
                    Button("Check Again") { Task { await model.load(force: true) } }
                }
                manualSections
            case .available, .demo:
                if let status = model.status {
                    checksSection(status)
                    actionsSection(status)
                    optionsSection(status)
                    advancedSection(status)
                    Section {
                        DisclosureGroup("Set it up by hand") {
                            MoonlightFillScreenManualSteps(size: size, optimizeGameSettings: optimizeGameSettings, accent: accent)
                        }
                    } footer: {
                        Text("Orbit changes only Sunshine's output_name, dd_configuration_option, dd_resolution_option and dd_refresh_rate_option. It saves your previous Sunshine settings on the PC first and puts them back when you turn this off. Sunshine restarts to apply them, never during a stream.")
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Fill the Screen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(force: true) }
        #endif
        .tint(accent)
        .task { await model.load() }
        .onAppear { onlyDisplay = model.status?.fill.onlyDisplay ?? false }
        .onChange(of: model.status?.fill.onlyDisplay) { _, value in if let value, model.status?.fill.enabled == true { onlyDisplay = value } }
        .confirmationDialog("Undo Orbit's changes on \(pcName)?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Undo Changes", role: .destructive) { Task { await model.revert() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fill Screen and the second screen turn off, and Sunshine's display settings go back to how they were before Orbit changed them. Sunshine restarts once. Screen sizes added to the virtual display stay; they do no harm.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func checksSection(_ status: OrbitStreamDisplayStatus) -> some View {
        let checks = status.fillChecks(size: displaySize, refreshRate: rate)
        Section {
            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 10) {
                    OrbitDisplayCheckRow(check: check)
                    if check.kind == .login, check.state != .done {
                        OrbitSunshineLoginForm(pcName: pcName, isSaving: model.work == .savingLogin, accent: accent) { name, secret in
                            await model.saveLogin(username: name, password: secret)
                        }
                    }
                    if check.kind == .driver, check.state != .done, status.offersInstallCommand {
                        OrbitDriverInstallCommand(command: status.driverInstallCommand, accent: accent)
                    }
                }
                .padding(.vertical, 2)
            }
            // The PC's own words when no row above says why it isn't ready (for example Sunshine not listing
            // the virtual display yet).
            if let note = status.pcNote, !checks.contains(where: { $0.detail == note }) {
                OrbitDisplayOutcomeRow(title: "Note from \(pcName)", message: note, isError: true)
            }
            if !optimizeGameSettings {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Optimize game settings", isOn: $optimizeGameSettings)
                    Text("Needed for Fill Screen: it lets Sunshine switch the virtual display to this size for each stream.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if status.isBusy {
                let streaming = status.streamActive == true
                OrbitDisplayOutcomeRow(title: streaming ? "A stream is running" : "An app is running in Sunshine",
                                       message: streaming
                                           ? "Sunshine has to restart to use new display settings, so Orbit changes them only between streams. End the stream first."
                                           : "Sunshine has to restart to use new display settings, which would close the app. Quit it from a stream first (End stream › Quit on PC).",
                                       isError: true)
            }
            if status.secondScreen.active {
                OrbitDisplayOutcomeRow(title: "Second Screen is on",
                                       message: "Until you turn Second Screen off, Sunshine streams the virtual display as an extra monitor next to \(pcName)'s own.",
                                       isError: false, symbol: "rectangle.on.rectangle", tint: .blue)
            }
        } header: {
            HStack {
                Text(pcName)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if model.availability == .demo { Text("Demo mode: sample PC. Nothing is sent anywhere.") }
        }
    }

    @ViewBuilder
    private func actionsSection(_ status: OrbitStreamDisplayStatus) -> some View {
        Section {
            if let work = model.work {
                OrbitDisplayWorkRow(title: workTitle(work), waitsForPrompt: work.waitsForPrompt, detail: workDetail(work))
            } else if status.fillsScreen(size: displaySize, refreshRate: rate) {
                Label("\(pcName) is set up to fill this screen", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.mint)
                    .font(.callout.weight(.semibold))
            } else {
                let blocked = !model.canChange || model.setUpBlocker() != nil || !displaySize.isAcceptedByPC
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await model.setUp(size: displaySize, refreshRate: refreshRate, onlyDisplay: onlyDisplay) }
                    } label: {
                        // Dark text on the light accent, like the apps' own prominent buttons.
                        Label("Set Up This PC", systemImage: "wand.and.stars")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                            .foregroundStyle(blocked ? Color.secondary : Color.black.opacity(0.85))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(blocked)
                    .accessibilityHint(setUpCaption(status))
                    Text(setUpCaption(status)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                // The centred button title would otherwise start the row separator mid-row.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            if let outcome = model.outcome {
                OrbitDisplayOutcomeRow(title: outcome.title, message: outcome.message, isError: outcome.isError)
            }
            if model.work == nil {
                if status.fill.enabled {
                    Button("Turn Off Fill Screen on \(pcName)") { Task { await model.turnOff() } }
                        .disabled(!model.canChange)
                }
                if status.savedConfig.available {
                    Button("Undo Orbit's Changes…", role: .destructive) { confirmRevert = true }
                        .disabled(!model.canChange)
                }
                Button("Check Again") { Task { await model.load(force: true) } }
                    .disabled(model.isRefreshing)
            }
        } header: {
            Text("Set up")
        }
    }

    @ViewBuilder
    private func optionsSection(_ status: OrbitStreamDisplayStatus) -> some View {
        if status.driverUsable, status.loginSaved {
            Section {
                Toggle("Turn off the PC's monitor while streaming", isOn: Binding(get: { onlyDisplay }, set: { value in
                    onlyDisplay = value
                    if status.fill.enabled, value != status.fill.onlyDisplay { Task { await model.setOnlyDisplay(value) } }
                }))
                .disabled(model.work != nil)
            } footer: {
                Text("Sunshine then shows only the virtual display during a stream, so nothing appears on the PC's own screen. Off: the virtual display becomes the main display and the monitor stays on as a second one.")
            }
        }
    }

    @ViewBuilder
    private func advancedSection(_ status: OrbitStreamDisplayStatus) -> some View {
        Section {
            DisclosureGroup("Sunshine's display settings") {
                settingRow("output_name", status.config.outputName.map { $0 == status.virtualDisplay.deviceId ? "the virtual display" : $0 })
                settingRow("dd_configuration_option", status.config.configurationOption)
                settingRow("dd_resolution_option", status.config.resolutionOption)
                settingRow("dd_refresh_rate_option", status.config.refreshRateOption)
                if let version = status.sunshineVersion { settingRow("Sunshine", version) }
                if !status.virtualDisplay.resolutions.isEmpty {
                    settingRow("Virtual display sizes", status.virtualDisplay.resolutions.map { $0.replacingOccurrences(of: "x", with: " × ") }.joined(separator: ", "))
                }
                if status.savedConfig.available {
                    settingRow("Saved before Orbit", status.savedConfig.savedAt.flatMap(Self.dateText) ?? "yes")
                }
            }
        }
    }

    @ViewBuilder
    private var manualSections: some View {
        Section {
            MoonlightFillScreenManualSteps(size: size, optimizeGameSettings: optimizeGameSettings, accent: accent)
        } header: {
            Text("Set it up by hand")
        }
    }

    // MARK: Text

    private func settingRow(_ name: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.caption.monospaced())
            Spacer(minLength: 12)
            Text(value ?? "not set").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func workTitle(_ work: OrbitFillScreenSetupModel.Work) -> String {
        switch work {
        case .addingSize(let size): return "Adding \(size) to the virtual display on \(pcName)…"
        case .configuringSunshine: return "Pointing Sunshine at the virtual display…"
        case .changingMonitor: return "Changing what Sunshine shows while streaming…"
        case .turningOff: return "Turning Fill Screen off on \(pcName)…"
        case .reverting: return "Putting Sunshine's settings back…"
        case .savingLogin: return "Saving the login on \(pcName)…"
        }
    }

    private func workDetail(_ work: OrbitFillScreenSetupModel.Work) -> String? {
        switch work {
        case .configuringSunshine, .changingMonitor, .turningOff, .reverting:
            return "Sunshine restarts on the PC to use the new settings. This takes a few seconds."
        case .addingSize, .savingLogin:
            return nil
        }
    }

    /// Under "Set Up This PC": what stops it, or what it will do.
    private func setUpCaption(_ status: OrbitStreamDisplayStatus) -> String {
        if let blocker = model.setUpBlocker() { return blocker }
        if !displaySize.isAcceptedByPC {
            return "\(displaySize) is outside what the PC accepts (640 × 480 to 7680 × 4320). Choose another resolution."
        }
        return setUpHint(status)
    }

    private func setUpHint(_ status: OrbitStreamDisplayStatus) -> String {
        var steps: [String] = []
        if !status.lists(displaySize, refreshRate: rate) {
            steps.append("adds \(displaySize) at \(rate) Hz to the virtual display (Windows may ask for administrator approval on the PC)")
        }
        if !status.sunshineStreamsVirtualDisplay { steps.append("points Sunshine at it and restarts Sunshine once") }
        guard !steps.isEmpty else { return "Applies the settings again." }
        return "Orbit " + steps.joined(separator: ", then ") + "."
    }

    private static func dateText(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? { formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: iso) }()
        return date?.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - By hand (older companions, or anyone who prefers it)

/// What Fill Screen needs on the PC, in plain steps. Sunshine only fills a non-16:9 screen when one of the
/// PC's displays can switch to that exact size; otherwise it adds the bars itself.
struct MoonlightFillScreenManualSteps: View {
    let size: MoonlightStreamSize
    let optimizeGameSettings: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Install a virtual display on the PC, for example the free Virtual Display Driver. In Terminal on the PC:")
            OrbitDriverInstallCommand(command: OrbitStreamDisplayStatus.defaultInstallCommand, accent: accent)
            step(2, "Add \(size.description) to the virtual display's resolutions, at the frame rate you stream at.")
            step(3, "In Sunshine's web UI, under Audio/Video, choose the virtual display as the display to stream and let Sunshine change its resolution to the one the client asks for.")
            step(4, optimizeGameSettings
                 ? "Keep Optimize game settings on in Stream Settings: it is what lets Sunshine switch the display to this size."
                 : "Turn on Optimize game settings in Stream Settings: without it Sunshine never switches the display to this size.")
            Text("On the PC, the Orbit companion's tray menu (Set up full-screen streaming) walks through the same steps. Change Sunshine's settings between streams: Sunshine restarts to apply them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The steps alone, for Stream Settings opened without a PC (or an older companion).
struct MoonlightFillScreenHelpView: View {
    let size: MoonlightStreamSize
    let optimizeGameSettings: Bool
    let accent: Color

    var body: some View {
        Form {
            Section {
                Text("Orbit asks the PC for a \(size.description) picture, the shape of this screen. Sunshine can only send a full picture in that shape when one of the PC's displays can switch to exactly that size. A normal monitor cannot, so Sunshine fits the 16:9 desktop into the frame and adds black bars itself. Nothing breaks: you simply still see bars.")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Why there are black bars")
            }
            Section {
                MoonlightFillScreenManualSteps(size: size, optimizeGameSettings: optimizeGameSettings, accent: accent)
            } header: {
                Text("Set up the PC")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Fill the Screen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(accent)
    }
}
#endif
