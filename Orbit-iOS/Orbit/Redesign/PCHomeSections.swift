import SwiftUI

// MARK: - Vitals

/// One reading as the PC tab shows it.
struct PCVital {
    var label: String
    var value: String?
    var unit: String?
    var detail: String?
    var fraction: Double?
    var color: Color = .primary
    var history: [Double] = []
    var historyRange: ClosedRange<Double>? = nil

    @MainActor
    init(_ metric: DashboardMetric, vm: OrbitViewModel) {
        let m = vm.metrics
        label = metric.title
        history = vm.history.series(for: metric)
        switch metric {
        case .cpuLoad:
            value = OrbitFormat.percent(m.cpuUsage); unit = "%"
            fraction = m.cpuUsage / 100
            color = OrbitPalette.load(fraction)
            detail = Self.join([OrbitFormat.temperature(m.cpuTemp), m.cpuClockMHz.map { Self.gigahertz($0) }])
            historyRange = 0...100
        case .gpuLoad:
            value = OrbitFormat.percent(m.gpuUsage); unit = "%"
            fraction = m.gpuUsage.map { $0 / 100 }
            color = OrbitPalette.load(fraction)
            detail = Self.join([OrbitFormat.temperature(m.gpuTemp), OrbitFormat.watts(m.gpuPowerWatts)])
            historyRange = 0...100
        case .memory:
            value = m.ramTotalGB > 0 ? OrbitFormat.gigabytes(m.ramUsedGB) : nil; unit = "GB"
            fraction = m.ramTotalGB > 0 ? m.ramUsedGB / m.ramTotalGB : nil
            color = OrbitPalette.load(fraction)
            detail = m.ramTotalGB > 0 ? "of \(OrbitFormat.gigabytes(m.ramTotalGB, digits: 0) ?? "") GB" : nil
        case .storage:
            value = m.ssdTotalTB > 0 ? OrbitFormat.gigabytes(m.ssdUsedTB, digits: 2) : nil; unit = "TB"
            fraction = m.ssdTotalTB > 0 ? m.ssdUsedTB / m.ssdTotalTB : nil
            color = OrbitPalette.load(fraction)
            detail = m.ssdTotalTB > 0 ? "of \(OrbitFormat.gigabytes(m.ssdTotalTB, digits: 2) ?? "") TB" : nil
        case .vram:
            value = OrbitFormat.gigabytes(m.vramUsedGB); unit = "GB"
            if let used = m.vramUsedGB, let total = m.vramTotalGB, total > 0 {
                fraction = used / total
                detail = "of \(OrbitFormat.gigabytes(total, digits: 0) ?? "") GB"
            }
            color = OrbitPalette.load(fraction)
        case .cpuPower:
            value = m.cpuPowerWatts.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }; unit = "W"
            detail = "Processor package"
        case .gpuPower:
            value = m.gpuPowerWatts.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }; unit = "W"
            detail = "Graphics card"
        case .cpuTemperature:
            value = OrbitFormat.temperature(m.cpuTemp)
            fraction = m.cpuTemp.map { $0 / 100 }
            color = OrbitPalette.temperature(m.cpuTemp)
            historyRange = 20...100
        case .gpuTemperature:
            value = OrbitFormat.temperature(m.gpuTemp)
            fraction = m.gpuTemp.map { $0 / 100 }
            color = OrbitPalette.temperature(m.gpuTemp)
            historyRange = 20...100
        case .coolantTemperature:
            value = OrbitFormat.temperature(m.liquidTemp)
            detail = "Liquid loop"
        case .cpuClock:
            value = m.cpuClockMHz.flatMap { $0.isFinite && $0 > 0 ? ($0 / 1000).formatted(.number.precision(.fractionLength(2))) : nil }
            unit = "GHz"
            detail = m.cpuClockSource
        case .network:
            value = OrbitFormat.rate(m.networkDownloadMBps).map { $0.components(separatedBy: " ").first ?? $0 }
            unit = m.networkDownloadMBps.map { $0 >= 1 ? "MB/s" : "KB/s" }
            detail = OrbitFormat.rate(m.networkUploadMBps).map { "↑ \($0)" }
        case .diskActivity:
            value = OrbitFormat.rate(m.diskReadMBps).map { $0.components(separatedBy: " ").first ?? $0 }
            unit = m.diskReadMBps.map { $0 >= 1 ? "MB/s" : "KB/s" }
            detail = OrbitFormat.rate(m.diskWriteMBps).map { "Writing \($0)" }
        case .uptime:
            value = m.uptimeSeconds > 0 ? OrbitFormat.duration(seconds: m.uptimeSeconds) : nil
            detail = "Since the last restart"
        case .fps:
            value = m.fps.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }; unit = "fps"
            detail = m.activeGame ?? m.fpsUnavailableReason
        case .cpuFan:
            value = m.cpuFanRPM.flatMap { $0.isFinite ? String(Int($0.rounded())) : nil }; unit = "rpm"
        case .gpuFan:
            value = OrbitFormat.percent(m.gpuFanPercent); unit = "%"
            fraction = m.gpuFanPercent.map { $0 / 100 }
        }
    }

    private static func join(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private static func gigahertz(_ mhz: Double) -> String {
        (mhz / 1000).formatted(.number.precision(.fractionLength(2))) + " GHz"
    }
}

struct PCVitalsSection: View {
    @ObservedObject var vm: OrbitViewModel
    @Binding var vital: DashboardMetric?
    @Binding var showsCustomize: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The chosen readings this PC actually reports. A card with nothing to show is left out
    /// rather than drawn empty (a PC without NVIDIA sensors has no GPU power, for example).
    private var metrics: [DashboardMetric] {
        let configured = vm.dashboardConfiguration.orderedVisibleMetrics
        let chosen = configured.isEmpty ? [.cpuLoad, .gpuLoad, .memory, .storage] : configured
        return chosen.filter { metric in
            let vital = PCVital(metric, vm: vm)
            return vital.value != nil || vital.history.contains(where: \.isFinite)
        }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    private func tile(_ metric: DashboardMetric) -> some View {
        Button {
            OrbitHaptics.tap()
            vital = metric
        } label: {
            PCVitalTile(vital: PCVital(metric, vm: vm))
        }
        .buttonStyle(PCTileButtonStyle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Right Now") {
                Button("Edit") { showsCustomize = true }
            }
            if vm.metrics.telemetryAvailable == false {
                Text("Waiting for the first readings from the PC…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .orbitSurface()
            } else {
                let shown = metrics
                let paired = columns.count > 1 && shown.count % 2 == 1 ? Array(shown.dropLast()) : shown
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(paired) { metric in tile(metric) }
                }
                if paired.count < shown.count, let last = shown.last {
                    tile(last)
                }
            }
        }
    }
}

struct PCVitalTile: View {
    var vital: PCVital

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OrbitReading(label: vital.label, value: vital.value, unit: vital.unit, detail: vital.detail,
                         valueSize: 34, valueColor: vital.color)
            Spacer(minLength: 0)
            if vital.fraction != nil {
                OrbitMeter(fraction: vital.fraction, style: AnyShapeStyle(vital.color == .primary ? Color.white : vital.color))
            } else if vital.history.filter(\.isFinite).count > 1 {
                OrbitSparkline(values: vital.history, range: vital.historyRange, style: AnyShapeStyle(.tint))
                    .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .orbitSurface(padding: 16, radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Tiles press in a little, right on touch-down.
struct PCTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(OrbitMotion.quick, value: configuration.isPressed)
    }
}

// MARK: - Controls

struct PCControlsSection: View {
    @ObservedObject var vm: OrbitViewModel
    @Binding var showsTrackpad: Bool
    @Binding var showsClipboard: Bool
    @Binding var confirmation: PCPowerAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Control")
            HStack(spacing: 12) {
                tile("Trackpad", systemImage: "hand.point.up.left") { showsTrackpad = true }
                tile("Screen", systemImage: "display") { vm.openDesktopPreview() }
                tile("Clipboard", systemImage: "doc.on.clipboard") { showsClipboard = true }
                Menu {
                    Button("Lock", systemImage: "lock") { Task { await vm.sendPowerAction("lock") } }
                    Button("Turn On Display", systemImage: "display") { Task { await vm.sendPowerAction("restore_display") } }
                    Divider()
                    Button("Sleep", systemImage: "moon") { confirmation = .sleep }
                    Button("Restart", systemImage: "arrow.clockwise") { confirmation = .restart }
                    Button("Shut Down", systemImage: "power", role: .destructive) { confirmation = .shutdown }
                } label: {
                    PCControlTileLabel(title: "Power", systemImage: "power")
                }
                .buttonStyle(PCTileButtonStyle())
            }
            .disabled(vm.isDemoMode)
        }
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            OrbitHaptics.tap()
            action()
        } label: {
            PCControlTileLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(PCTileButtonStyle())
    }
}

struct PCControlTileLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .frame(height: 26)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Sound

struct PCSoundSection: View {
    @ObservedObject var vm: OrbitViewModel
    @Binding var showsMixer: Bool

    private var available: Bool { vm.metrics.volumeAvailable != false && !vm.isDemoMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Sound") {
                Button("Apps") { showsMixer = true }
                    .disabled(vm.isDemoMode)
            }
            HStack(spacing: 14) {
                Button {
                    OrbitHaptics.tap()
                    Task { await vm.sendPowerAction("mute") }
                } label: {
                    Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(vm.metrics.isMuted ? OrbitPalette.warm : .primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.metrics.isMuted ? "Unmute the PC" : "Mute the PC")
                Slider(value: Binding(get: { vm.metrics.volume }, set: { vm.setVolume($0) }), in: 0...100, step: 1) { editing in
                    vm.isDraggingVolume = editing
                }
                .accessibilityLabel("PC volume")
                Text(available ? (vm.metrics.isMuted ? "Muted" : "\(Int(vm.metrics.volume))%") : "—")
                    .font(.subheadline.weight(.semibold))
                    .orbitLiveNumber()
                    .foregroundStyle(vm.metrics.isMuted ? OrbitPalette.warm : .secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .orbitSurface(padding: 16, radius: 22)
            .disabled(!available)
        }
    }
}

// MARK: - Activity

struct PCActivitySection: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.scenePhase) private var scenePhase

    private var top: [PCProcess] {
        Array(vm.processes.filter { ($0.cpuPercent ?? 0) > 0 || ($0.memoryMB ?? 0) > 0 }
            .sorted { ($0.cpuPercent ?? -1, $0.memoryMB ?? -1) > ($1.cpuPercent ?? -1, $1.memoryMB ?? -1) }
            .prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("Using the Most") {
                NavigationLink("Task Manager", value: PCHomeDestination.processes)
            }
            VStack(spacing: 0) {
                if top.isEmpty {
                    Text(vm.isLoadingProcesses ? "Reading processes…" : "Open Task Manager to see what's running.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, process in
                        if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                        PCProcessRow(vm: vm, process: process)
                    }
                }
            }
            .orbitSurface(padding: 16, radius: 22)
        }
        .task(id: vm.connectionID) {
            vm.prepareAppIcons()
            while !Task.isCancelled {
                if scenePhase == .active && vm.metrics.isOnline && !vm.isDemoMode { await vm.fetchProcesses() }
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
            }
        }
    }
}

struct PCProcessRow: View {
    @ObservedObject var vm: OrbitViewModel
    var process: PCProcess

    var body: some View {
        HStack(spacing: 12) {
            OrbitAppIconView(store: vm.appIcons, iconID: process.iconID, size: 30) {
                Image(systemName: "app")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            Text(process.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(process.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.subheadline.weight(.semibold))
                .orbitLiveNumber()
            Text(process.memoryMB.map { $0 >= 1024 ? String(format: "%.1f GB", $0 / 1024) : "\(Int($0)) MB" } ?? "—")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .orbitLiveNumber()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - About

struct PCAboutSection: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OrbitSectionHeader("This PC")
            VStack(spacing: 0) {
                row("Processor", vm.metrics.cpuName)
                Divider().overlay(OrbitPalette.hairline)
                row("Graphics", vm.metrics.gpuName)
                if vm.metrics.ramTotalGB > 0 {
                    Divider().overlay(OrbitPalette.hairline)
                    row("Memory", "\(OrbitFormat.gigabytes(vm.metrics.ramTotalGB, digits: 0) ?? "") GB")
                }
                Divider().overlay(OrbitPalette.hairline)
                link("Specifications", .specs)
                Divider().overlay(OrbitPalette.hairline)
                link("Sessions", .sessions)
                Divider().overlay(OrbitPalette.hairline)
                link("Monitoring Sources", .sources)
            }
            .orbitSurface(padding: 16, radius: 22)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    private func link(_ title: String, _ destination: PCHomeDestination) -> some View {
        NavigationLink(value: destination) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
