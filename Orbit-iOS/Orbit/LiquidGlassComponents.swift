import SwiftUI
import UIKit

// MARK: - Haptics

/// Centralised haptic feedback. Every call respects the "Haptic Feedback" switch
/// in Appearance so the whole app can be silenced with one toggle.
enum OrbitHaptics {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "orbit.haptics") as? Bool ?? true
    }
    static func tap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func press() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Glass surface


/// Grouped content: a quiet solid surface (the redesign keeps Liquid Glass for controls).
struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tint: Color = .white
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content.background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: max(cornerRadius, 18), style: .continuous))
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 22, tint: Color = .white, elevated: Bool = false) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tint: tint, elevated: elevated))
    }
}

// MARK: - Ambient background


/// The canvas behind every screen: plain black.
struct OrbitAmbientBackground: View {
    var isOnline: Bool

    var body: some View {
        OrbitPalette.canvas.ignoresSafeArea()
    }
}

// MARK: - Theme extras

extension OrbitTheme {
    /// A complementary tone used for gradients, secondary glows and hero rings.
    var secondary: Color {
        switch self {
        case .noir: Color(red: 0.36, green: 0.86, blue: 1.0)
        case .ocean: Color(red: 0.42, green: 0.52, blue: 1.0)
        case .aurora: Color(red: 0.36, green: 0.80, blue: 0.98)
        case .violet: Color(red: 1.0, green: 0.55, blue: 0.82)
        case .ember: Color(red: 1.0, green: 0.42, blue: 0.48)
        case .graphite: Color(red: 0.55, green: 0.64, blue: 0.80)
        case .cyberpunk: Color(red: 0.18, green: 0.92, blue: 1.0)
        case .solarGold: Color(red: 1.0, green: 0.55, blue: 0.25)
        case .crimson: Color(red: 1.0, green: 0.56, blue: 0.30)
        case .matrix: Color(red: 0.55, green: 1.0, blue: 0.70)
        case .arctic: Color(red: 0.74, green: 0.72, blue: 1.0)
        case .sakura: Color(red: 0.96, green: 0.82, blue: 1.0)
        }
    }
    var heroGradient: LinearGradient {
        LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var heroGradientColors: [Color] { [accent, secondary] }
}

// MARK: - Shared primitives


/// A row or header symbol. Plain glyphs, no colored tiles: color is kept for status.
struct OrbitIconBadge: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 36
    var filled: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}


/// Section title in sentence case with an optional trailing control.
struct LegacyOrbitSectionHeader<Trailing: View>: View {
    var title: String
    var icon: String? = nil
    var tint: Color? = nil
    var trailing: Trailing

    init(_ title: String, icon: String? = nil, tint: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

extension LegacyOrbitSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, tint: Color? = nil) {
        self.init(title, icon: icon, tint: tint) { EmptyView() }
    }
}


/// A status light with its label; it pulses while something is live.
struct OrbitStatusPill: View {
    var text: String
    var tint: Color
    var pulsing: Bool = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                OrbitStatusLabel(text: text, color: tint, pulsing: pulsing)
                    .font(.footnote)
                    .lineLimit(1)
            }
        }
    }
}

/// Circular progress gauge with a soft glow. `progress` is clamped to 0…1.
struct OrbitRingGauge: View {
    var progress: Double?
    var lineWidth: CGFloat = 6
    var tint: Color
    var track: Color = .white.opacity(0.08)
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.orbitTheme) private var theme

    private var clamped: Double { min(1, max(0, progress ?? 0)) }

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if progress != nil {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * clamped)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy(duration: 0.45), value: clamped)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Smooth sparkline rendered from a short history buffer. Nothing is drawn for
/// fewer than three readings, so missing data stays visibly missing.
struct OrbitSparklineShape: Shape {
    var values: [Double]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Self.points(values, in: rect)
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        if closed, let last = points.last, let first = points.first {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    static func points(_ values: [Double], in rect: CGRect) -> [CGPoint] {
        let finite = values.filter { $0.isFinite }
        guard finite.count > 1, rect.width > 0, rect.height > 0 else { return [] }
        let minimum = finite.min() ?? 0
        let maximum = finite.max() ?? 1
        let span = max(maximum - minimum, 0.0001)
        let step = rect.width / CGFloat(finite.count - 1)
        let inset: CGFloat = 2
        return finite.enumerated().map { index, value in
            let normalized = CGFloat((value - minimum) / span)
            let y = rect.maxY - inset - normalized * (rect.height - inset * 2)
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: y)
        }
    }
}

struct LegacyOrbitSparkline: View {
    var values: [Double]
    var tint: Color
    var lineWidth: CGFloat = 1.8
    var showsFill: Bool = true

    var body: some View {
        ZStack {
            if showsFill {
                OrbitSparklineShape(values: values, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
            }
            OrbitSparklineShape(values: values)
                .stroke(
                    LinearGradient(colors: [tint.opacity(0.35), tint], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons & tiles

/// Scales and dims on press with a light haptic. Use for custom glass controls.
struct OrbitPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.86 : 1))
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && haptic { OrbitHaptics.tap() }
            }
    }
}

extension ButtonStyle where Self == OrbitPressableStyle {
    static var orbitPressable: OrbitPressableStyle { OrbitPressableStyle() }
}


/// The main action of a screen: a full-width tinted glass button.
struct OrbitProminentButtonStyle: ButtonStyle {
    var colors: [Color]
    var foreground: Color = .black
    var cornerRadius: CGFloat = 16
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(colors.first ?? OrbitPalette.accent).interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(OrbitMotion.quick, value: configuration.isPressed)
    }
}


/// A secondary action: a glass capsule. A tint other than white colors the label.
struct OrbitGlassButtonStyle: ButtonStyle {
    var tint: Color = .white
    var cornerRadius: CGFloat = 14
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint == .white ? Color.primary : tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(OrbitMotion.quick, value: configuration.isPressed)
    }
}


/// A square action: symbol over a short label, on a quiet surface; tinted while active.
struct OrbitActionTile: View {
    var title: String
    var icon: String
    var tint: Color
    var isActive: Bool = false
    var minHeight: CGFloat = 60
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 6)
            .background(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(OrbitPalette.well),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.orbitPressable)
        .accessibilityLabel(title)
    }
}

// MARK: - Metric card

struct HardwareMetricCard: View {
    @AppStorage("orbit.monochromeMetrics") private var monochrome = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    private var metricAccent: Color { monochrome || theme.isFlat ? theme.accent : accent }
    private var glow: Bool { !reduceGlow && !theme.isFlat }
    let title: String
    let subtitle: String
    let valueText: String
    let progress: Double?
    let icon: String
    let accent: Color
    var detail: String? = nil
    var history: [Double] = []
    var showsRing: Bool = false

    private var isHot: Bool { (progress ?? 0) >= 0.9 && progress != nil }
    private var barTint: Color { isHot ? Color(red: 1.0, green: 0.42, blue: 0.38) : metricAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OrbitIconBadge(systemName: icon, tint: metricAccent, size: 28)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(style == .improved ? Color.white.opacity(0.88) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if showsRing, let progress {
                    OrbitRingGauge(progress: progress, lineWidth: 3.5, tint: barTint)
                        .frame(width: 22, height: 22)
                }
            }

            ZStack(alignment: .bottomLeading) {
                if history.count >= 3 {
                    LegacyOrbitSparkline(values: history, tint: metricAccent.opacity(0.9), lineWidth: 1.6)
                        .frame(height: 30)
                        .padding(.leading, 56)
                        .padding(.bottom, 2)
                        .opacity(0.75)
                }
                Text(valueText)
                    .font(.system(.title, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .shadow(color: glow ? metricAccent.opacity(0.25) : .clear, radius: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.numericText())
                }
            }
            .frame(minHeight: 28, alignment: .topLeading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    if let progress, progress.isFinite {
                        Capsule()
                            .fill(LinearGradient(colors: [barTint.opacity(0.7), barTint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geometry.size.width * min(1, max(0, progress))))
                            .shadow(color: glow ? barTint.opacity(0.6) : .clear, radius: 4)
                            .animation(.snappy(duration: 0.4), value: progress)
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: metricAccent)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Misc


/// The Orbit mark, as used in older screens.
struct LegacyOrbitMark: View {
    var size: CGFloat = 72

    var body: some View {
        OrbitMark(status: .online, size: size * 0.8)
            .frame(width: size, height: size)
    }
}


/// An inline note: a symbol, a short title and one or two lines of explanation.
struct OrbitNotice: View {
    var title: String
    var message: String
    var icon: String = "info.circle.fill"
    var tint: Color = .cyan

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}


/// A calm placeholder for empty lists, with an optional action.
struct OrbitEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = .cyan
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(OrbitGlassButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}


/// Lists and forms on the black canvas.
struct OrbitListChrome: ViewModifier {
    var isOnline: Bool
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(OrbitPalette.canvas)
    }
}


struct OrbitRowBackground: ViewModifier {
    var tint: Color?
    func body(content: Content) -> some View {
        content.listRowBackground(OrbitPalette.surface)
    }
}

extension View {
    func orbitListChrome(isOnline: Bool = true) -> some View { modifier(OrbitListChrome(isOnline: isOnline)) }
    func orbitRow(tint: Color? = nil) -> some View { modifier(OrbitRowBackground(tint: tint)) }
}


/// A small labelled value ("Ping 4 ms").
struct OrbitStatChip: View {
    var label: String
    var value: String
    var tint: Color = .white
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .font(.footnote)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let rgb = hex.count == 6 ? value : 0x00B4FF
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}
