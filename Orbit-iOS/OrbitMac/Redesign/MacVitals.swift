import Charts
import SwiftUI

// MARK: - Readings

extension MacPCMetrics: OrbitTelemetry {}

extension OrbitVital {
    /// A reading from the Mac app's model, with its recent history.
    @MainActor
    init(_ metric: MacMetric, vm: OrbitMacViewModel) {
        self.init(OrbitVitalKind(rawValue: metric.rawValue) ?? .cpuLoad, metrics: vm.metrics, history: vm.history.values(for: metric))
    }
}

/// One reading on the PC page: label, value, a detail line and a meter or a sparkline.
/// Clicking it opens the last minutes as a chart.
struct MacVitalTile: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var metric: MacMetric
    @State private var showsDetail = false
    @State private var hovered = false

    private var vital: OrbitVital { OrbitVital(metric, vm: vm) }

    var body: some View {
        let vital = vital
        Button {
            showsDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                OrbitReading(label: vital.label, value: vital.value, unit: vital.unit, detail: vital.detail,
                             valueSize: 32, valueColor: vital.color)
                Spacer(minLength: 0)
                if vital.fraction != nil {
                    OrbitMeter(fraction: vital.fraction, style: AnyShapeStyle(vital.color == .primary ? Color.white : vital.color))
                } else if vital.history.filter(\.isFinite).count > 1 {
                    OrbitSparkline(values: vital.history, range: vital.historyRange, style: AnyShapeStyle(.tint))
                        .frame(height: 22)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(18)
            .background(hovered ? OrbitPalette.well : OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(MacPressStyle())
        .onHover { hovered = $0 }
        .animation(OrbitMotion.quick, value: hovered)
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            MacVitalDetail(metric: metric)
                .environmentObject(vm)
        }
        .help("Show the last few minutes")
        .accessibilityHint("Shows the last few minutes as a chart")
    }
}

/// A reading up close: the live value, the last minutes as a chart, low/average/high.
struct MacVitalDetail: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    var metric: MacMetric

    private var vital: OrbitVital { OrbitVital(metric, vm: vm) }
    private var samples: [(index: Int, value: Double)] {
        vital.history.enumerated().compactMap { $0.element.isFinite ? ($0.offset, $0.element) : nil }
    }

    var body: some View {
        let vital = vital
        VStack(alignment: .leading, spacing: 18) {
            OrbitReading(label: vital.label, value: vital.value, unit: vital.unit, detail: vital.detail,
                         valueSize: 44, valueColor: vital.color)
            if samples.count > 1 {
                Chart(samples, id: \.index) { sample in
                    AreaMark(x: .value("Reading", sample.index), y: .value(vital.label, sample.value))
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.26), Color.accentColor.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Reading", sample.index), y: .value(vital.label, sample.value))
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
                .frame(height: 150)
                .animation(OrbitMotion.standard, value: samples.count)
                .accessibilityLabel("\(vital.label) over the last few minutes")
                stats
            } else {
                Text("The chart fills in as readings arrive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private var autoRange: ClosedRange<Double> {
        let values = samples.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max(1, (high - low) * 0.2)
        return max(0, low - pad)...(high + pad)
    }

    private var stats: some View {
        let values = samples.map(\.value)
        let average = values.reduce(0, +) / Double(max(1, values.count))
        return HStack(spacing: 0) {
            stat("Low", values.min())
            stat("Average", average)
            stat("High", values.max())
        }
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value.map(format) ?? "—")
                .font(.orbitReading(22))
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

/// Presses in a touch on mouse-down, like the system's own controls.
struct MacPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(OrbitMotion.quick, value: configuration.isPressed)
    }
}
