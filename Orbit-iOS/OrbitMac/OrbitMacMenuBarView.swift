import AppKit
import SwiftUI

/// The menu bar extra is a plain menu, like the system's own: how the PC is doing, a few
/// readings, the actions people reach for without opening the window, and the way back in.
struct MacMenuBarView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.openWindow) private var openWindow

    private var state: MacPCState { MacPCState(vm: vm) }
    private var online: Bool { vm.metrics.isOnline && !vm.isDemoMode }

    var body: some View {
        Text(statusLine)
        if vm.metrics.hasTelemetry || vm.isDemoMode {
            ForEach(readings, id: \.self) { Text($0) }
        }
        Divider()
        Button("Open Orbit") { open() }
        Divider()
        if online {
            Button(vm.metrics.isMuted ? "Unmute" : "Mute") { Task { await vm.sendAction("mute") } }
            Button("Lock") { Task { await vm.sendAction("lock") } }
            Button("Sleep…") { confirm(.sleep) }
            Button("Restart…") { confirm(.restart) }
            Button("Shut Down…") { confirm(.shutdown) }
        } else if vm.currentPC != nil && !vm.isDemoMode {
            Button(vm.isWaking ? "Waking…" : "Wake PC") { Task { await vm.wakePC() } }
                .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty != false)
        }
        if vm.savedPCs.count > 1 {
            Divider()
            Menu("Switch PC") {
                ForEach(vm.savedPCs) { pc in
                    Toggle(pc.name, isOn: Binding(get: { pc.id == vm.selectedPCID && !vm.isDemoMode }, set: { if $0 { vm.selectPC(pc) } }))
                }
            }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Orbit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let name = vm.isConfigured ? vm.selectedPCName : "No PC yet"
        let status: String
        switch state {
        case .setup: status = "not paired"
        case .demo: status = "demo"
        case .connecting: status = "connecting…"
        case .waking: status = "waking up…"
        case .locked: status = "locked"
        case .offline: status = "offline"
        case .online: status = OrbitTakeaway(vm.metrics).headline.lowercased(with: .current)
        }
        return "\(name) — \(status)"
    }

    /// Two or three lines of readings, the way they read on the PC page.
    private var readings: [String] {
        let m = vm.metrics
        var lines: [String] = []
        let cpu = [OrbitFormat.percent(m.cpuUsage).map { "\($0)%" }, OrbitFormat.temperature(m.cpuTemp)].compactMap { $0 }
        if !cpu.isEmpty { lines.append("Processor " + cpu.joined(separator: " · ")) }
        let gpu = [OrbitFormat.percent(m.gpuUsage).map { "\($0)%" }, OrbitFormat.temperature(m.gpuTemp)].compactMap { $0 }
        if !gpu.isEmpty { lines.append("Graphics " + gpu.joined(separator: " · ")) }
        if let game = m.activeGame, !game.isEmpty {
            let fps = m.fps.flatMap { $0 > 0 ? " · \(Int($0.rounded())) fps" : nil } ?? ""
            lines.append("Playing \(game)\(fps)")
        }
        return lines
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }

    /// Destructive actions are confirmed in the main window, never straight from a menu.
    private func confirm(_ action: MacPowerConfirmation) {
        open()
        NotificationCenter.default.post(name: .macConfirmPower, object: action.rawValue)
    }
}
