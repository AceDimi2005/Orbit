import Charts
import SwiftUI

/// One reading up close, as a full-screen page: the live value and the readings that go with
/// it on the left; on the right the last minute as a chart, or for capacities how much is in
/// use and free; underneath, the processes responsible.
struct TVVitalDetailView: View {
    @EnvironmentObject private var vm: OrbitTVViewModel
    var kind: OrbitVitalKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tvAccent) private var accent

    private var vital: OrbitVital { vm.vital(kind) }

    private var samples: [(index: Int, value: Double)] {
        vital.history.enumerated().compactMap { $0.element.isFinite ? ($0.offset, $0.element) : nil }
    }

    /// The part this reading comes from, when the PC names it.
    private var hardware: String? {
        switch kind {
        case .cpuLoad, .cpuTemperature, .cpuPower, .cpuClock, .cpuFan: return named(vm.metrics.cpuName, placeholder: "Processor")
        case .gpuLoad, .gpuTemperature, .gpuPower, .gpuFan, .vram: return named(vm.metrics.gpuName, placeholder: "Graphics")
        default: return nil
        }
    }

    private var related: [OrbitVitalKind] {
        let kinds: [OrbitVitalKind]
        switch kind {
        case .cpuLoad: kinds = [.cpuTemperature, .cpuClock, .cpuPower, .cpuFan, .coolantTemperature]
        case .gpuLoad: kinds = [.gpuTemperature, .gpuPower, .gpuFan, .vram, .fps]
        case .fps: kinds = [.gpuLoad, .gpuTemperature, .cpuLoad]
        case .vram: kinds = [.gpuLoad, .memory]
        case .memory: kinds = [.vram]
        case .storage: kinds = [.diskActivity]
        case .diskActivity: kinds = [.storage]
        case .network: kinds = []
        case .gpuTemperature: kinds = [.gpuPower, .gpuFan]
        case .cpuPower, .gpuPower: kinds = [.cpuPower, .gpuPower].filter { $0 != kind }
        default: kinds = []
        }
        return kinds.filter { vm.vital($0).hasData }
    }

    private var processes: [TVProcessItem] {
        let sorted: [TVProcessItem]
        switch kind {
        case .cpuLoad, .cpuPower, .cpuTemperature, .cpuClock:
            sorted = vm.processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
        case .gpuLoad, .gpuPower, .gpuTemperature, .fps:
            sorted = vm.processes.filter { $0.gpuPercent != nil }.sorted { ($0.gpuPercent ?? -1) > ($1.gpuPercent ?? -1) }
        case .vram:
            sorted = vm.processes.filter { $0.vramMB != nil }.sorted { ($0.vramMB ?? -1) > ($1.vramMB ?? -1) }
        case .memory:
            sorted = vm.processes.sorted { ($0.memoryMB ?? -1) > ($1.memoryMB ?? -1) }
        default:
            return []
        }
        return Array(sorted.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 56) {
            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vital.label)
                        .font(.title2.weight(.semibold))
                    if let hardware {
                        Text(hardware)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 32)
                Button("Done") { dismiss() }
                    .tvButton()
            }
            HStack(alignment: .top, spacing: 96) {
                summary
                    .frame(width: 520, alignment: .topLeading)
                panel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !processes.isEmpty { usingTheMost }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tvFullScreenPage()
        .task {
            if [.cpuLoad, .gpuLoad, .memory, .vram, .fps, .cpuPower, .gpuPower, .cpuTemperature, .gpuTemperature].contains(kind) {
                await vm.refreshProcesses()
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        switch kind {
        case .network:
            directions(("Receiving", vm.metrics.networkDownloadMBps), ("Sending", vm.metrics.networkUploadMBps))
        case .diskActivity:
            directions(("Reading", vm.metrics.diskReadMBps), ("Writing", vm.metrics.diskWriteMBps))
        default:
            reading
        }
    }

    /// Transfer rates: both directions as equals, since neither is "the" value.
    private func directions(_ first: (String, Double?), _ second: (String, Double?)) -> some View {
        VStack(alignment: .leading, spacing: 44) {
            ForEach([first, second], id: \.0) { direction in
                let rate = Self.rate(direction.1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(direction.0)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(rate.value)
                            .font(.orbitReading(120))
                            .orbitLiveNumber()
                        Text(rate.unit)
                            .font(.orbitReading(48, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func rate(_ megabytesPerSecond: Double?) -> (value: String, unit: String) {
        guard let value = megabytesPerSecond, value.isFinite, value >= 0 else { return ("—", "") }
        if value >= 1 { return (value.formatted(.number.precision(.fractionLength(1))), "MB/s") }
        return ((value * 1000).formatted(.number.precision(.fractionLength(0))), "KB/s")
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: vital.unit == "%" ? 2 : 10) {
                    Text(vital.value ?? "—")
                        .font(.orbitReading(150))
                        .foregroundStyle(vital.value == nil ? Color.secondary : vital.color)
                        .orbitLiveNumber()
                    if let unit = vital.unit, vital.value != nil {
                        Text(unit)
                            .font(.orbitReading(60, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                if let detail = vital.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .orbitLiveNumber()
                }
            }
            .accessibilityElement(children: .combine)
            if !related.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 32) {
                    ForEach(related) { other in
                        let reading = vm.vital(other)
                        TVInlineReading(label: reading.label, value: reading.value, unit: reading.unit, color: reading.color)
                    }
                }
            }
        }
    }

    // MARK: Right-hand panel

    @ViewBuilder
    private var panel: some View {
        switch kind {
        case .memory:
            capacity(used: vm.metrics.ramTotalGB > 0 ? vm.metrics.ramUsedGB : nil, total: vm.metrics.ramTotalGB, unit: "GB", digits: 1)
        case .storage:
            capacity(used: vm.metrics.ssdTotalTB > 0 ? vm.metrics.ssdUsedTB : nil, total: vm.metrics.ssdTotalTB, unit: "TB", digits: 2)
        case .vram:
            capacity(used: vm.metrics.vramUsedGB, total: vm.metrics.vramTotalGB ?? 0, unit: "GB", digits: 1)
        default:
            chart
        }
    }

    @ViewBuilder
    private var chart: some View {
        if samples.count > 1 {
            VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
                TVSectionTitle("Last Minute") {
                    Text(statsLine)
                        .orbitLiveNumber()
                }
                Chart(samples, id: \.index) { sample in
                    AreaMark(x: .value("Sample", sample.index), y: .value(vital.label, sample.value))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Sample", sample.index), y: .value(vital.label, sample.value))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: vital.historyRange ?? autoRange)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(OrbitPalette.hairline)
                        AxisValueLabel().foregroundStyle(.secondary).font(.caption)
                    }
                }
                .frame(height: 250)
                .padding(TVMetrics.surfacePadding)
                .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: TVMetrics.tileRadius, style: .continuous))
                .accessibilityLabel("\(vital.label) over the last minute")
            }
        } else if vital.historyRange != nil || kind == .fps {
            Text("The chart fills in as readings arrive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 250)
                .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
        }
    }

    /// Used, free and total, with one thick meter.
    @ViewBuilder
    private func capacity(used: Double?, total: Double, unit: String, digits: Int) -> some View {
        if let used, total > 0 {
            let fraction = used / total
            VStack(alignment: .leading, spacing: 40) {
                OrbitMeter(fraction: fraction, style: AnyShapeStyle(OrbitPalette.load(fraction) == .primary ? Color.white : OrbitPalette.load(fraction)), height: 16)
                HStack(alignment: .top, spacing: 64) {
                    TVInlineReading(label: "In Use", value: OrbitFormat.percent(fraction * 100), unit: "%")
                    TVInlineReading(label: "Free", value: OrbitFormat.gigabytes(max(0, total - used), digits: digits), unit: unit)
                    TVInlineReading(label: "Total", value: OrbitFormat.gigabytes(total, digits: digits), unit: unit)
                }
            }
            .orbitSurface(padding: TVMetrics.surfacePadding, radius: TVMetrics.tileRadius)
            .padding(.top, 30)
        }
    }

    private var statsLine: String {
        let values = samples.map(\.value)
        guard let low = values.min(), let high = values.max(), !values.isEmpty else { return "" }
        let average = values.reduce(0, +) / Double(values.count)
        return "Low \(format(low)) · Average \(format(average)) · High \(format(high))"
    }

    private var autoRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max(1, (high - low) * 0.2)
        return max(0, low - pad)...(high + pad)
    }

    private func format(_ value: Double) -> String {
        let number = String(Int(value.rounded()))
        switch kind {
        case .cpuLoad, .gpuLoad: return number + "%"
        case .fps: return number + " fps"
        default: return number
        }
    }

    // MARK: Processes

    private var usingTheMost: some View {
        VStack(alignment: .leading, spacing: TVMetrics.titleSpacing) {
            TVSectionTitle("Using the Most")
            HStack(alignment: .top, spacing: TVMetrics.gridSpacing) {
                ForEach(processes) { process in
                    HStack(spacing: 24) {
                        TVAppIcon(store: vm.appIcons, iconID: process.iconID, name: TVFormat.processName(process.name), size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TVFormat.processName(process.name))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(value(for: process) ?? "—")
                                .font(.orbitReading(44))
                                .orbitLiveNumber()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: TVMetrics.rowRadius, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
                // Fewer than four keep the same width as four.
                ForEach(processes.count..<4, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
    }

    private func value(for process: TVProcessItem) -> String? {
        switch kind {
        case .gpuLoad, .gpuPower, .gpuTemperature, .fps: return TVFormat.percent(process.gpuPercent)
        case .vram: return TVFormat.memory(megabytes: process.vramMB)
        case .memory: return TVFormat.memory(megabytes: process.memoryMB)
        default: return TVFormat.percent(process.cpuPercent)
        }
    }

    private func named(_ name: String, placeholder: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == placeholder || trimmed == "Unavailable" ? nil : trimmed
    }
}
