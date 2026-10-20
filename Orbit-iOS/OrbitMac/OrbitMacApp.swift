import AppKit
import SwiftUI

@main
struct OrbitMacApp: App {
    @StateObject private var viewModel = OrbitMacViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
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
                .onChange(of: scenePhase) { _, phase in viewModel.setAppActive(phase != .background) }
                .onOpenURL { url in handle(url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("PC") {
                Button("Refresh Now") { Task { await viewModel.refreshMetrics() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Power On (Wake-on-LAN)") { Task { await viewModel.wakePC() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(viewModel.isWaking || viewModel.currentPC == nil)
                Button("Lock PC") { Task { await viewModel.sendAction("lock") } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Sleep") { Task { await viewModel.sendAction("sleep") } }
                    .disabled(!viewModel.metrics.isOnline)
                Button("Restart…") { viewModel.selectedSection = .overview; NotificationCenter.default.post(name: .macConfirmPower, object: "restart") }
                    .disabled(!viewModel.metrics.isOnline)
                Button("Shut Down…") { viewModel.selectedSection = .overview; NotificationCenter.default.post(name: .macConfirmPower, object: "shutdown") }
                    .disabled(!viewModel.metrics.isOnline)
                Divider()
                Button(viewModel.metrics.isMuted ? "Unmute PC" : "Mute PC") { Task { await viewModel.sendAction("mute") } }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Volume Up") { viewModel.adjustVolume(by: 5) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(!viewModel.metrics.isOnline)
                Button("Volume Down") { viewModel.adjustVolume(by: -5) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(!viewModel.metrics.isOnline)
                Divider()
                Button(viewModel.isStreaming ? "Stop Desktop Preview" : "Start Desktop Preview") {
                    if viewModel.isStreaming { viewModel.stopPreview() } else { viewModel.selectedSection = .preview; viewModel.startPreview() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!viewModel.metrics.isOnline && !viewModel.isStreaming)
                Button("Open Desktop Preview Window") { openWindow(id: "preview") }
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
                    if viewModel.savedPCs.isEmpty { Text("No saved PCs") }
                    Divider()
                    Button("Pair a PC…") { viewModel.selectedSection = .pcs }
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

        Window("Desktop Preview", id: "preview") {
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
        .menuBarExtraStyle(.window)
    }

    /// `orbit://` deep links shared with the iOS app.
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "orbit" else { return }
        switch url.host?.lowercased() {
        case "remote": viewModel.selectedSection = .remote
        case "files": viewModel.selectedSection = .files
        case "library": viewModel.selectedSection = .library
        case "preview": viewModel.selectedSection = .preview
        case "settings", "pcs": viewModel.selectedSection = .pcs
        case "wake": Task { await viewModel.wakePC() }
        case "sleep": Task { await viewModel.sendAction("sleep") }
        case "shutdown": Task { await viewModel.sendAction("shutdown") }
        case "restart": Task { await viewModel.sendAction("restart") }
        default: viewModel.selectedSection = .overview
        }
    }
}

extension Notification.Name {
    /// Posted by menu commands; the Overview shows the confirmation dialog.
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
            Image(systemName: vm.metrics.isOnline || vm.isDemoMode ? "circle.hexagongrid.circle.fill" : "circle.hexagongrid.circle")
            if let text { Text(text).monospacedDigit() }
        }
    }
}
