import AppKit
import MoonlightCore
import SwiftUI

@main
struct OrbitMacApp: App {
    @StateObject private var viewModel = OrbitMacViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        // `ORBIT_IDENTITY_SELFTEST=1 OrbitMac.app/Contents/MacOS/OrbitMac` prints the Keychain state of the
        // Sunshine client identity from inside the sandboxed, signed app and exits.
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["ORBIT_SUNSHINE_SELFTEST"] { MacSunshineSelfTest.run(mode: mode) }
        switch environment["ORBIT_IDENTITY_SELFTEST"] {
        case "1":
            print(MoonlightIdentityStore.diagnostics())
            exit(0)
        case "reset":
            MoonlightIdentityStore.reset()
            print(MoonlightIdentityStore.diagnostics())
            exit(0)
        case "kvs":
            // State of iCloud Key-Value Storage as this Mac sees it.
            let store = NSUbiquitousKeyValueStore.default
            let synced = store.synchronize()
            let items = OrbitPCCloudSync.cloudItems()
            print("synchronize: \(synced); keys: \(store.dictionaryRepresentation.keys.sorted())")
            print("synced PCs: \(items.count)" + items.map { " · \($0.name) \($0.address) origin=\($0.origin ?? "legacy") token=\($0.apiToken.isEmpty ? "no" : "yes")" }.joined())
            print("removed: \(OrbitPCCloudSync.removed())")
            exit(0)
        case "export":
            print((try? MoonlightIdentityStore.currentCertificatePEM()) ?? "no identity")
            exit(0)
        case "tls":
            // ORBIT_TLS_URL=https://127.0.0.1:47984/serverinfo ORBIT_TLS_SERVER_CERT=/path/server.der
            // The sandbox cannot read files outside the container, so the server certificate comes in base64.
            guard let url = environment["ORBIT_TLS_URL"].flatMap(URL.init(string:)),
                  let der = environment["ORBIT_TLS_SERVER_CERT_B64"].flatMap({ Data(base64Encoded: $0) }) else {
                print("ORBIT_TLS_URL and ORBIT_TLS_SERVER_CERT_B64 are required"); exit(2)
            }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                print(await MoonlightIdentityStore.probeTLS(url: url, serverCertificateDER: der))
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        default:
            break
        }
        #endif
        // Ocean used to be the implicit default; installs that never chose another theme move to Noir once.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "mac.theme.noirMigrated") {
            defaults.set(true, forKey: "mac.theme.noirMigrated")
            if defaults.string(forKey: "mac.theme") == "ocean" { defaults.set("noir", forKey: "mac.theme") }
        }
    }

    var body: some Scene {
        WindowGroup("Orbit", id: "main") {
            MacRootView()
                .environmentObject(viewModel)
                .macAppearance()
                .frame(minWidth: 980, minHeight: 640)
                .onChange(of: scenePhase) { _, phase in
                    viewModel.setAppActive(phase != .background)
                    if phase == .active { OrbitProStore.shared.refreshIfNeeded() }
                }
                .onAppear {
                    OrbitProStore.shared.start()
                    #if DEBUG
                    MacSnapshot.scheduleIfRequested(vm: viewModel)
                    #endif
                }
                .onReceive(OrbitProStore.shared.$isProUnlocked) { _ in MacProLockdown.enforce() }
                .onReceive(OrbitProStore.shared.$hasVerifiedEntitlements) { _ in MacProLockdown.enforce() }
                .onOpenURL { url in handle(url) }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("PC") {
                Button("Refresh Now") { Task { await viewModel.refreshMetrics() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Wake PC") { Task { await viewModel.wakePC() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(viewModel.isWaking || viewModel.currentPC == nil)
                Button("Lock") { Task { await viewModel.sendAction("lock") } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Sleep…") { viewModel.selectedSection = .overview; NotificationCenter.default.post(name: .macConfirmPower, object: "sleep") }
                    .disabled(!viewModel.metrics.isOnline)
                Button("Restart…") { viewModel.selectedSection = .overview; NotificationCenter.default.post(name: .macConfirmPower, object: "restart") }
                    .disabled(!viewModel.metrics.isOnline)
                Button("Shut Down…") { viewModel.selectedSection = .overview; NotificationCenter.default.post(name: .macConfirmPower, object: "shutdown") }
                    .disabled(!viewModel.metrics.isOnline)
                Divider()
                Button(viewModel.metrics.isMuted ? "Unmute" : "Mute") { Task { await viewModel.sendAction("mute") } }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Volume Up") { viewModel.adjustVolume(by: 5) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Volume Down") { viewModel.adjustVolume(by: -5) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(!viewModel.metrics.isOnline)
                Divider()
                Button("Stream Desktop") { viewModel.selectedSection = .library; viewModel.pendingStreamAction = .desktop }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!viewModel.metrics.isOnline || viewModel.isDemoMode)
                Button("Stream Settings…") { viewModel.selectedSection = .library; viewModel.pendingStreamAction = .settings }
                Divider()
                Button(viewModel.isStreaming ? "Stop Watching the Screen" : "Watch the Screen") {
                    if viewModel.isStreaming { viewModel.stopPreview() } else { viewModel.selectedSection = .preview; viewModel.startPreview() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!viewModel.metrics.isOnline && !viewModel.isStreaming)
                Button("Open Screen in a Window") { openWindow(id: "preview") }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                Divider()
                Menu("Switch PC") {
                    ForEach(viewModel.savedPCs) { pc in
                        Button {
                            viewModel.selectPC(pc)
                        } label: {
                            if pc.id == viewModel.selectedPCID { Label(pc.name, systemImage: "checkmark") } else { Text(pc.name) }
                        }
                    }
                    if viewModel.savedPCs.isEmpty { Text("No PCs yet") }
                    Divider()
                    Button("Add PC…") { viewModel.selectedSection = .pcs }
                    Button("Manage PCs…") { viewModel.selectedSection = .pcs }
                }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(MacSection.allCases) { section in
                    Button(section.title) { viewModel.selectedSection = section }
                        .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Orbit on GitHub") {
                    if let url = URL(string: "https://github.com/AceDimi2005/Orbit") { NSWorkspace.shared.open(url) }
                }
                Button("Download Windows Companion (.zip)") {
                    if let url = URL(string: "https://github.com/AceDimi2005/Orbit/raw/main/Orbit-Windows-Agent.zip") { NSWorkspace.shared.open(url) }
                }
            }
        }

        Window("Screen", id: "preview") {
            MacPreviewWindowView()
                .environmentObject(viewModel)
                .macAppearance()
                .frame(minWidth: 720, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)

        Window("Stream", id: "stream") {
            MacStreamWindowView()
                .environmentObject(viewModel)
                .macAppearance()
                .frame(minWidth: 960, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 900)

        Settings {
            MacSettingsView()
                .environmentObject(viewModel)
                .macAppearance()
        }

        // `isInserted` must never be bound straight to `@AppStorage`: AppKit reports the
        // status item's visibility back through KVO on every scene update, SwiftUI then
        // writes the (unchanged) value to UserDefaults, the App body re-evaluates, the
        // scene updates again… and the main thread spins at 100 % until the app stops
        // responding. The guarded binding below only publishes real changes.
        MenuBarExtra(isInserted: Binding(
            get: { viewModel.menuBarEnabled },
            set: { value in if viewModel.menuBarEnabled != value { viewModel.menuBarEnabled = value } }
        )) {
            MacMenuBarView()
                .environmentObject(viewModel)
                .macAppearance()
        } label: {
            MacMenuBarLabel(metric: viewModel.menuBarMetric)
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.menu)
    }

    /// `orbit://` deep links shared with the iOS app.
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "orbit" else { return }
        switch url.host?.lowercased() {
        case "remote": viewModel.selectedSection = .remote
        case "files": viewModel.selectedSection = .files
        case "library", "stream": viewModel.selectedSection = .library
        case "preview": viewModel.selectedSection = .preview
        case "settings", "pcs": viewModel.selectedSection = .pcs
        case "wake": Task { await viewModel.wakePC() }
        // A link alone never powers a PC down: anything on the Mac can open a URL.
        case "sleep", "shutdown", "restart":
            viewModel.selectedSection = .overview
            NotificationCenter.default.post(name: .macConfirmPower, object: url.host?.lowercased())
        default: viewModel.selectedSection = .overview
        }
    }
}

extension Notification.Name {
    /// Posted by menu commands and links; the main window asks before powering the PC down.
    static let macConfirmPower = Notification.Name("OrbitMac.confirmPower")
}

/// Compact status item label: Orbit glyph plus the chosen live metric.
struct MacMenuBarLabel: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var metric: String

    private var text: String? {
        guard vm.metrics.hasTelemetry else { return vm.isDemoMode ? "Demo" : nil }
        switch metric {
        case "gpu": return vm.metrics.gpuUsage.map { "GPU \(Int($0.rounded()))%" }
        case "ram": return vm.metrics.ramUsagePercent.map { "RAM \(Int($0.rounded()))%" }
        case "fps": return vm.metrics.fps.flatMap { $0 > 0 ? "\(Int($0.rounded())) FPS" : nil }
        case "temp": return vm.metrics.cpuTemp.map { "\(Int($0.rounded()))°C" }
        case "none": return nil
        default: return "CPU \(Int(vm.metrics.cpuUsage.rounded()))%"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // A template image: the menu bar colors it like every other status item.
            Image("OrbitMenuBarMark")
                .accessibilityLabel("Orbit")
            if let text { Text(text).monospacedDigit() }
        }
    }
}

#if DEBUG
/// `ORBIT_SNAPSHOT=1 ORBIT_SNAPSHOT_SECTIONS=overview,library OrbitMac.app/Contents/MacOS/OrbitMac` shows each
/// section in turn and saves the main window as `Snapshots/<section>.png` in the app's Application
/// Support folder (inside its container), so layouts can be checked without screen recording.
/// `ORBIT_SNAPSHOT_DELAY` (seconds before the first one, default 8) and `ORBIT_SNAPSHOT_QUIT=1` are optional.
enum MacSnapshot {
    @MainActor static func scheduleIfRequested(vm: OrbitMacViewModel) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ORBIT_SNAPSHOT"] == "1" else { return }
        let names = (environment["ORBIT_SNAPSHOT_SECTIONS"] ?? "overview").split(separator: ",").map(String.init)
        let delay = Double(environment["ORBIT_SNAPSHOT_DELAY"] ?? "") ?? 8
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            for name in names {
                guard let section = MacSection(rawValue: name) else { continue }
                vm.selectedSection = section
                try? await Task.sleep(for: .seconds(3))
                save(name)
                render(name, section: section, vm: vm)
            }
            if environment["ORBIT_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    /// SwiftUI's own renderer, for pages whose window capture leaves parts out.
    @MainActor private static func render(_ name: String, section: MacSection, vm: OrbitMacViewModel) {
        let sunshine = MoonlightHostCoordinator()
        if let pc = vm.currentPC { sunshine.configure(pcID: pc.id, address: pc.address) }
        let content: AnyView
        switch section {
        case .overview: content = AnyView(MacPCPage(sunshine: sunshine, scrolls: false) {})
        case .library: content = AnyView(MacLibraryView(sunshine: sunshine, scrolls: false))
        default: return
        }
        let page = content
            .environmentObject(vm)
            .macAppearance()
            .environment(\.colorScheme, .dark)
            .frame(width: 1060)
            .background(Color.black)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("render: failed"); return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name)-rendered.png")
        try? png.write(to: file)
        print("render: \(file.path)")
    }

    @MainActor private static func save(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("snapshot: no window"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("snapshot: \(file.path)")
    }
}

/// `ORBIT_SUNSHINE_SELFTEST=status|pair|stream|file|agent OrbitMac.app/Contents/MacOS/OrbitMac` runs the
/// Sunshine steps for the selected PC (or `ORBIT_PC_ID`) from inside the signed, sandboxed app
/// with the same code the UI uses, prints every result and exits. `pair` lets the agent type the
/// PIN (Sunshine web UI login saved on the PC); `stream` runs a headless stream of the Desktop app
/// for `ORBIT_STREAM_SECONDS` (default 12); `file` prints `ORBIT_FILE_PATH` from the PC; `agent` calls
/// `ORBIT_AGENT_PATH` with `ORBIT_AGENT_METHOD` (default GET) and prints the reply.
enum MacSunshineSelfTest {
    private final class Flag: @unchecked Sendable { var done = false }

    static func run(mode: String) -> Never {
        let flag = Flag()
        Task { @MainActor in
            await perform(mode: mode)
            flag.done = true
        }
        while !flag.done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        exit(0)
    }

    private static func describe(_ error: Error) -> String {
        "\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) [\(type(of: error))]"
    }

    private static func fingerprint(_ data: Data?) -> String {
        data.map { String(MoonlightEncoding.hex(MoonlightCrypto.sha256($0)).prefix(16)) } ?? "-"
    }

    @MainActor private static func report(_ host: MoonlightHostCoordinator) {
        let record = host.record
        print("Coordinator: paired \(host.isPaired) · reachable \(host.reachable) · identity \(record?.clientIdentity.map { "per-host \($0.id.prefix(8)) cert \(fingerprint($0.certificateDER))" } ?? "shared") · apps \(host.apps.map(\.title)) · running \(host.runningAppTitle ?? "-") · error \(host.lastError ?? "-")")
    }

    @MainActor private static func perform(mode: String) async {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "mac.savedPCs.v1"),
              let pcs = try? JSONDecoder().decode([MacSavedPC].self, from: data), !pcs.isEmpty else {
            print("No saved PCs in this container.")
            return
        }
        let wanted = environment["ORBIT_PC_ID"] ?? defaults.string(forKey: "mac.selectedPCID") ?? ""
        let pc = pcs.first { $0.id == wanted } ?? pcs[0]
        for item in pcs {
            print("PC \(item.id == pc.id ? "*" : " ") \(item.name) · \(item.address):\(item.securePort) · id \(item.id) · token \(MacTokenStore.token(for: item.id).isEmpty ? "missing" : "present")")
        }
        let api: OrbitAPIClient
        do {
            api = try OrbitAPIClient(host: pc.address, port: pc.securePort, token: MacTokenStore.token(for: pc.id), fingerprint: pc.certificateFingerprint)
        } catch {
            print("Agent client: \(describe(error))")
            return
        }

        if mode == "agent", let path = environment["ORBIT_AGENT_PATH"] {
            // One call to the agent, for example `/api/update/check` or POST `/api/update/apply`.
            let method = environment["ORBIT_AGENT_METHOD"] ?? "GET"
            do {
                print(String(decoding: try await api.data(path, method: method), as: UTF8.self))
            } catch {
                print("Agent \(method) \(path) failed: \(describe(error))")
            }
            return
        }

        if mode == "file", let path = environment["ORBIT_FILE_PATH"] {
            do {
                let data = try await api.data("/api/files/download", query: [URLQueryItem(name: "path", value: path)])
                FileHandle.standardOutput.write(data)
            } catch {
                print("Download failed: \(describe(error))")
            }
            return
        }

        var info: MacSunshineInfo?
        do {
            let raw = try await api.data("/api/sunshine/info")
            print("Agent /api/sunshine/info: \(String(decoding: raw, as: UTF8.self))")
            info = try? JSONDecoder().decode(MacSunshineInfo.self, from: raw)
        } catch {
            print("Agent /api/sunshine/info failed: \(describe(error))")
        }
        for stored in MoonlightHostStore.records() {
            print("Stored pairing: pcID \(stored.pcID) · address \(stored.address) · paired \(stored.isPaired) · at \(stored.pairedAt.map { "\($0)" } ?? "-") · identity \(stored.clientIdentity.map { "per-host \($0.id.prefix(8))" } ?? "shared") · server \(stored.serverUniqueID ?? "-")")
        }

        let host = MoonlightHostCoordinator()
        host.configure(pcID: pc.id, address: pc.address, httpPort: info?.httpPort ?? 47989, httpsPort: info?.httpsPort ?? 47984)
        await host.refresh()
        report(host)

        if mode == "pair" {
            host.beginPairing()
            guard let pin = host.pairingPIN else {
                print("Pairing did not start.")
                return
            }
            print("Pairing with PIN \(pin); the agent types it after 1.5 s (as the Pair automatically button does)…")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let automation = MoonlightPairingAutomation(canSubmitPIN: true, canStartSunshine: false, sunshineRunning: true, client: { api })
            do {
                try await automation.submitPIN(pin)
                print("Agent accepted the PIN.")
            } catch {
                print("Agent PIN entry failed: \(describe(error))")
                host.cancelPairing()
            }
            let started = Date()
            while host.isPairing, Date().timeIntervalSince(started) < 170 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            print("Pairing finished: stage \(host.pairingStage ?? "-")")
            report(host)
        }

        if mode == "stream" {
            guard let app = host.desktopApp else {
                print("No Sunshine app to stream.")
                return
            }
            let settings = MoonlightStreamSettingsStore.shared.settings
            let seconds = Double(environment["ORBIT_STREAM_SECONDS"] ?? "") ?? 12
            do {
                let started = Date()
                let parameters = try await host.prepareStream(app: app, settings: settings, quitRunningApp: false)
                print("Launch/resume of \(app.title) answered after \(String(format: "%.1f", Date().timeIntervalSince(started))) s; connecting…")
                let session = MoonlightStreamSession(settings: settings)
                session.start(parameters: parameters, settings: settings, headless: true)
                var streamingSince: Date?
                while Date().timeIntervalSince(started) < seconds + 30 {
                    if session.phase.isTerminal { break }
                    if session.phase == .streaming, streamingSince == nil {
                        streamingSince = Date()
                        print("Streaming \(String(format: "%.1f", Date().timeIntervalSince(started))) s after the launch request.")
                    }
                    if let since = streamingSince, Date().timeIntervalSince(since) >= seconds { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let stats = session.statistics
                print("Phase: \(session.phase)")
                print("Statistics: received \(stats.receivedFrames) · dropped \(stats.droppedFrames) · \(stats.framesPerSecond) fps · RTT \(stats.roundTripMs.map(String.init) ?? "-") ms · \(stats.codec) \(stats.width)x\(stats.height)@\(stats.frameRate) · \(stats.bitrateKbps) kbps")
                for line in session.logLines.suffix(60) { print("  log: \(line)") }
                session.stop()
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch let busy as MoonlightStreamBusyError {
                print("Busy: \(busy.errorDescription ?? "another app is running") (app id \(busy.runningAppID))")
            } catch {
                print("Stream failed: \(describe(error))")
                report(host)
            }
        }
    }
}
#endif
