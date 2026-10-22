import SwiftUI

// MARK: - Meter

/// A thin capsule meter. `nil` draws only the track, so a missing reading never looks like zero.
struct OrbitMeter: View {
    var fraction: Double?
    var style: AnyShapeStyle = AnyShapeStyle(.primary)
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OrbitPalette.track)
                if let fraction, fraction.isFinite {
                    Capsule()
                        .fill(style)
                        .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                        .animation(OrbitMotion.standard, value: fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Sparkline

/// A quiet line of recent readings with a faint fill under it. Scales to the given range,
/// or to the readings themselves when no range is given.
struct OrbitSparkline: View {
    var values: [Double]
    var range: ClosedRange<Double>? = nil
    var style: AnyShapeStyle = AnyShapeStyle(.tint)
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values.filter(\.isFinite), in: proxy.size, range: range)
            if points.count > 1 {
                ZStack {
                    Self.area(points, height: proxy.size.height)
                        .fill(style)
                        .opacity(0.2)
                        .mask(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Self.line(points)
                        .stroke(style, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func points(_ values: [Double], in size: CGSize, range: ClosedRange<Double>?) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let low = range?.lowerBound ?? (values.min() ?? 0)
        var high = range?.upperBound ?? (values.max() ?? 1)
        if high - low < 0.0001 { high = low + 1 }
        let inset: CGFloat = 1
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (min(high, max(low, value)) - low) / (high - low)
            return CGPoint(x: x, y: inset + (size.height - inset * 2) * (1 - CGFloat(normalized)))
        }
    }

    private static func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private static func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        path.addLines(points)
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Reading

/// One live reading: a small label, a big number with its unit, an optional detail line.
/// Missing readings show an em dash, never a made-up zero.
struct OrbitReading: View {
    var label: String
    var value: String?
    var unit: String? = nil
    var detail: String? = nil
    var valueSize: CGFloat = 40
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 4) {
                Text(value ?? "—")
                    .font(.orbitReading(valueSize))
                    .foregroundStyle(value == nil ? Color.secondary : valueColor)
                    .orbitLiveNumber()
                if let unit, value != nil {
                    Text(unit)
                        .font(.orbitReading(valueSize * 0.45, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .orbitLiveNumber()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Surfaces & headers

extension View {
    /// Grouped content on the canvas: a quiet, solid surface. Glass is for controls only.
    func orbitSurface(padding: CGFloat = 18, radius: CGFloat = OrbitMetrics.surfaceRadius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A section title with an optional trailing action, set in plain sentence case.
struct OrbitSectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 12)
            trailing()
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 4)
    }
}

extension OrbitSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - Status

/// A small status light with a label: online, asleep, locked…
struct OrbitStatusLabel: View {
    var text: String
    var color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(pulsing && !reduceMotion && dim ? 0.35 : 1)
                .animation(pulsing && !reduceMotion ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: dim)
                .onAppear { dim = pulsing }
                .onChange(of: pulsing) { _, value in dim = value }
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

enum OrbitFormat {
    static func percent(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(Int(value.rounded()))
    }

    static func temperature(_ celsius: Double?) -> String? {
        guard let celsius, celsius.isFinite, celsius > -50 else { return nil }
        return "\(Int(celsius.rounded()))°"
    }

    static func gigabytes(_ value: Double?, digits: Int = 1) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : digits)))
    }

    static func watts(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return "\(Int(value.rounded())) W"
    }

    static func rate(_ megabytesPerSecond: Double?) -> String? {
        guard let value = megabytesPerSecond, value.isFinite, value >= 0 else { return nil }
        if value >= 1 { return value.formatted(.number.precision(.fractionLength(1))) + " MB/s" }
        return (value * 1000).formatted(.number.precision(.fractionLength(0))) + " KB/s"
    }

    static func duration(seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours >= 24 { return "\(hours / 24) d \(hours % 24) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}
