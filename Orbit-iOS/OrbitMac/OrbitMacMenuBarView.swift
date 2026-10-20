import SwiftUI

/// Menu bar popover: at-a-glance telemetry, volume and power without opening the window.
struct MacMenuBarView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if vm.metrics.hasTelemetry {
                HStack(spacing: 10) {
                    gauge("CPU", value: vm.metrics.cpuUsage, detail: vm.metrics.cpuTemp.map { "\(Int($0))°C" }, tint: MacMetric.cpuLoad.accent)
                    gauge("GPU", value: vm.metrics.gpuUsage, detail: vm.metrics.gpuTemp.map { "\(Int($0))°C" }, tint: MacMetric.gpuLoad.accent)
                    gauge("RAM", value: vm.metrics.ramUsagePercent, detail: vm.metrics.ramTotalGB > 0 ? "\(MacFormat.decimal(vm.metrics.ramUsedGB)) GB" : nil, tint: MacMetric.memory.accent)
                    gauge("VRAM", value: vm.metrics.vramUsagePercent, detail: vm.metrics.vramUsedGB.map { "\(MacFormat.decimal($0)) GB" }, tint: MacMetric.vram.accent)
                }
                HStack(spacing: 8) {
                    MacStatChip(label: "Power", value: MacFormat.whole(vm.metrics.totalPowerWatts, unit: "W"))
                    MacStatChip(label: "FPS", value: vm.metrics.fps.flatMap { $0 > 0 ? "\(Int($0.rounded()))" : nil } ?? "—")
                    MacStatChip(label: "Net", value: MacFormat.transferRate(vm.metrics.networkDownloadMBps))
                    Spacer()
                }
                if let game = vm.metrics.activeGame, !game.isEmpty {
                    Label(game, systemImage: "gamecontroller.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.mint)
                        .lineLimit(1)
                }
                volumeRow
            } else if vm.metrics.isOnline {
                Text("Collecting the first readings…").font(.caption).foregroundStyle(.secondary)
            }
            Divider().overlay(.white.opacity(0.1))
            HStack(spacing: 8) {
                if vm.metrics.isOnline {
                    menuButton("Lock", icon: "lock.fill", tint: theme.accent) { Task { await vm.sendAction("lock") } }
                    menuButton("Sleep", icon: "moon.fill", tint: .indigo) { Task { await vm.sendAction("sleep") } }
                    menuButton("Screenshot", icon: "camera.viewfinder", tint: .mint) { Task { await vm.sendAction("screenshot") } }
                } else {
                    menuButton(vm.isWaking ? "Waking…" : "Power On", icon: "power", tint: .mint) { Task { await vm.wakePC() } }
                        .disabled(vm.isWaking || vm.currentPC == nil)
                }
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Orbit", systemImage: "macwindow")
                }
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
            }
            HStack {
                if !vm.savedPCs.isEmpty {
                    Menu {
                        ForEach(vm.savedPCs) { pc in
                            Button(pc.name) { vm.selectPC(pc) }
                        }
                    } label: {
                        Label("Switch PC", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                Button("Quit Orbit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(MacAmbientBackground(isOnline: vm.metrics.isOnline))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                MacRing(progress: vm.metrics.hasTelemetry ? vm.metrics.cpuUsage / 100 : nil, lineWidth: 4, tint: theme.accent)
                    .frame(width: 40, height: 40)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.metrics.isOnline || vm.isDemoMode ? AnyShapeStyle(theme.heroGradient) : AnyShapeStyle(Color.secondary))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.isConfigured ? vm.selectedPCName : "No PC paired")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    MacStatusPill(text: vm.isDemoMode ? "Demo" : (vm.metrics.isOnline ? "Online" : (vm.currentPC == nil ? "Not paired" : "Offline")),
                                  tint: vm.isDemoMode ? .orange : (vm.metrics.isOnline ? .mint : (vm.currentPC == nil ? .secondary : .orange)),
                                  pulsing: vm.metrics.isOnline && !vm.isDemoMode)
                    if vm.metrics.isOnline && !vm.isDemoMode {
                        Text("\(vm.pingMs) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if vm.metrics.hasTelemetry {
                        Text("up \(vm.metrics.formattedUptime)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                Task { await vm.refreshMetrics() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MacIconButtonStyle(size: 26))
            .help("Refresh")
        }
    }

    private func gauge(_ title: String, value: Double?, detail: String?, tint: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                MacRing(progress: value.map { $0 / 100 }, lineWidth: 4.5, tint: tint)
                    .frame(width: 54, height: 54)
                VStack(spacing: -1) {
                    Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            Text(detail ?? "—")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 12, tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value.map { "\(Int($0.rounded())) percent" } ?? "unavailable")")
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await vm.sendAction("mute") }
            } label: {
                Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(MacIconButtonStyle(tint: vm.metrics.isMuted ? .orange : .white, size: 26))
            Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100) { editing in
                vm.isDraggingVolume = editing
            }
            .tint(vm.metrics.isMuted ? .orange : theme.accent)
            Text(vm.metrics.volumeAvailable == false ? "—" : (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%"))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(vm.metrics.isMuted ? .orange : .white)
                .frame(width: 44, alignment: .trailing)
        }
        .disabled(vm.metrics.volumeAvailable == false)
    }

    private func menuButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(MacHoverButtonStyle(tint: tint))
        .help(title)
    }
}
