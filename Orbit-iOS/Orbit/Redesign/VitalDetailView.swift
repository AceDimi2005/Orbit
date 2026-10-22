import Charts
import SwiftUI

/// One reading up close: the live value, the last minutes as a chart, and for load
/// readings the processes responsible for it.
struct VitalDetailView: View {
    @ObservedObject var vm: OrbitViewModel
    var metric: DashboardMetric
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    private var vital: PCVital { PCVital(metric, vm: vm) }
    private var samples: [(index: Int, value: Double)] {
        vital.history.enumerated().compactMap { $0.element.isFinite ? ($0.offset, $0.element) : nil }
    }

    private var relatedProcesses: [PCProcess] {
        let sorted: [PCProcess]
        switch metric {
        case .cpuLoad, .cpuPower, .cpuTemperature, .cpuClock:
            sorted = vm.processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
        case .gpuLoad, .gpuPower, .gpuTemperature, .fps:
            sorted = vm.processes.sorted { ($0.gpuPercent ?? -1) > ($1.gpuPercent ?? -1) }
        case .vram:
            sorted = vm.processes.sorted { ($0.vramMB ?? -1) > ($1.vramMB ?? -1) }
        case .memory:
            sorted = vm.processes.sorted { ($0.memoryMB ?? -1) > ($1.memoryMB ?? -1) }
        default:
            return []
        }
        return Array(sorted.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OrbitMetrics.sectionSpacing) {
                    OrbitReading(label: vital.detail ?? " ", value: vital.value, unit: vital.unit, valueSize: 64, valueColor: vital.color)
                    chart
                    if !samples.isEmpty { stats }
                    if !relatedProcesses.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            OrbitSectionHeader("Using the Most")
                            VStack(spacing: 0) {
                                ForEach(Array(relatedProcesses.enumerated()), id: \.element.id) { index, process in
                                    if index > 0 { Divider().overlay(OrbitPalette.hairline) }
                                    PCProcessRow(vm: vm, process: process)
                                }
                            }
                            .orbitSurface(padding: 16, radius: 22)
                        }
                    }
                }
                .padding(.horizontal, OrbitMetrics.gutter)
                .padding(.bottom, 32)
            }
            .navigationTitle(vital.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .tint(.primary)
                }
            }
            .task {
                if !relatedProcesses.isEmpty || [.cpuLoad, .gpuLoad, .memory, .vram].contains(metric) {
                    await vm.fetchProcesses()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var chart: some View {
        if samples.count > 1 {
            Chart(samples, id: \.index) { sample in
                AreaMark(x: .value("Sample", sample.index), y: .value(vital.label, sample.value))
                    .foregroundStyle(LinearGradient(colors: [theme.orbitTint.opacity(0.28), theme.orbitTint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Sample", sample.index), y: .value(vital.label, sample.value))
                    .foregroundStyle(.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: vital.historyRange ?? autoRange)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(OrbitPalette.hairline)
                    AxisValueLabel().foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            .animation(OrbitMotion.standard, value: samples.count)
            .accessibilityLabel("\(vital.label) over the last few minutes")
        } else {
            Text("The chart fills in as readings arrive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .orbitSurface()
        }
    }

    private var autoRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max(1, (high - low) * 0.2)
        return max(0, low - pad)...(high + pad)
    }

    private var stats: some View {
        let values = samples.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        return HStack(spacing: 0) {
            stat("Low", values.min())
            stat("Average", average)
            stat("High", values.max())
        }
        .orbitSurface(padding: 16, radius: 22)
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value.map { format($0) } ?? "—")
                .font(.orbitReading(24))
                .orbitLiveNumber()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ value: Double) -> String {
        let number = value >= 100 ? String(Int(value.rounded())) : value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
        switch metric {
        case .cpuTemperature, .gpuTemperature, .coolantTemperature: return number + "°"
        case .cpuLoad, .gpuLoad, .gpuFan: return number + "%"
        default: return number + (vital.unit.map { " \($0)" } ?? "")
        }
    }
}
