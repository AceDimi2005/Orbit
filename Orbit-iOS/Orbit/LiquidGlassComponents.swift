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

/// A restrained material surface shared by every screen. The improved style uses
/// an opaque tinted surface with a soft specular edge; the classic style keeps
/// translucent materials. Both respect Reduce Transparency.
struct LiquidGlassCard: ViewModifier {
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 22
    var tint: Color = .white
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if style == .improved || reduceTransparency {
                    shape
                        .fill(theme.surface)
                        .overlay {
                            shape.fill(
                                LinearGradient(
                                    colors: [tint.opacity(elevated ? 0.12 : 0.07), tint.opacity(0.015), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay { shape.fill(tint.opacity(elevated ? 0.09 : 0.05)) }
                }
            }
            .overlay {
                // Specular top edge + soft outer hairline.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(elevated ? 0.26 : 0.18), .white.opacity(0.06), tint.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(style == .improved ? 0.28 : 0.18), radius: elevated ? 22 : 12, y: elevated ? 10 : 5)
            .shadow(color: (reduceGlow ? Color.clear : tint).opacity(elevated ? 0.12 : 0.0), radius: 30, y: 8)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 22, tint: Color = .white, elevated: Bool = false) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tint: tint, elevated: elevated))
    }
}

// MARK: - Ambient background

struct OrbitAmbientBackground: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var isOnline: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                theme.background
                LinearGradient(
                    colors: [theme.background.opacity(0), .black.opacity(0.35)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                if !reduceGlow && !reduceTransparency {
                    let strength = style == .improved ? 0.9 : 1.25
                    Ellipse()
                        .fill(theme.accent.opacity(0.13 * strength))
                        .frame(width: size.width * 1.15, height: size.height * 0.42)
                        .blur(radius: 110)
                        .offset(x: -size.width * 0.30 + (drift ? 26 : -14), y: -size.height * 0.30 + (drift ? 18 : -10))
                    Ellipse()
                        .fill(theme.secondary.opacity(0.10 * strength))
                        .frame(width: size.width * 0.95, height: size.height * 0.38)
                        .blur(radius: 120)
                        .offset(x: size.width * 0.38 + (drift ? -22 : 12), y: size.height * 0.22 + (drift ? -14 : 16))
                    Circle()
                        .fill((isOnline ? theme.accent : Color.orange).opacity(0.06 * strength))
                        .frame(width: size.width * 0.7)
                        .blur(radius: 90)
                        .offset(x: size.width * 0.1, y: size.height * 0.62 + (drift ? 20 : -8))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) { drift = true }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Theme extras

extension OrbitTheme {
    /// A complementary tone used for gradients, secondary glows and hero rings.
    var secondary: Color {
        switch self {
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

/// Rounded-square icon badge used for rows, tiles and headers.
struct OrbitIconBadge: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 36
    var filled: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    filled
                        ? LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(.white.opacity(filled ? 0.22 : 0.08), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Small eyebrow-style header for grouped content.
struct OrbitSectionHeader<Trailing: View>: View {
    var title: String
    var icon: String? = nil
    var tint: Color? = nil
    var trailing: Trailing
    @Environment(\.orbitAccent) private var accent

    init(_ title: String, icon: String? = nil, tint: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint ?? accent)
            }
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

extension OrbitSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, tint: Color? = nil) {
        self.init(title, icon: icon, tint: tint) { EmptyView() }
    }
}

/// Capsule status indicator, optionally pulsing while live.
struct OrbitStatusPill: View {
    var text: String
    var tint: Color
    var pulsing: Bool = false
    var icon: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            } else {
                ZStack {
                    if pulsing && !reduceMotion {
                        Circle().fill(tint.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .scaleEffect(pulse ? 2.2 : 1)
                            .opacity(pulse ? 0 : 0.8)
                    }
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                .frame(width: 10, height: 10)
            }
            Text(text)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .onAppear {
            guard pulsing && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
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
                    .shadow(color: reduceGlow ? .clear : tint.opacity(0.55), radius: 6)
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

struct OrbitSparkline: View {
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && haptic { OrbitHaptics.tap() }
            }
    }
}

extension ButtonStyle where Self == OrbitPressableStyle {
    static var orbitPressable: OrbitPressableStyle { OrbitPressableStyle() }
}

/// Prominent gradient call-to-action.
struct OrbitProminentButtonStyle: ButtonStyle {
    var colors: [Color]
    var foreground: Color = .black
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: (colors.first ?? .clear).opacity(configuration.isPressed ? 0.15 : 0.35), radius: 16, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Subtle translucent secondary button.
struct OrbitGlassButtonStyle: ButtonStyle {
    var tint: Color = .white
    var cornerRadius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint == .white ? Color.white : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tint.opacity(tint == .white ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Square quick-action tile used on the dashboard and remote.
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.85) : tint)
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(0.055)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.4) : .white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.orbitPressable)
        .accessibilityLabel(title)
    }
}

// MARK: - Metric card

struct HardwareMetricCard: View {
    @AppStorage("orbit.monochromeMetrics") private var monochrome = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    private var metricAccent: Color { monochrome ? theme.accent : accent }
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                    OrbitSparkline(values: history, tint: metricAccent.opacity(0.9), lineWidth: 1.6)
                        .frame(height: 30)
                        .padding(.leading, 56)
                        .padding(.bottom, 2)
                        .opacity(0.75)
                }
                Text(valueText)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .shadow(color: reduceGlow ? .clear : metricAccent.opacity(0.25), radius: 10)
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
                            .shadow(color: reduceGlow ? .clear : barTint.opacity(0.6), radius: 4)
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

struct OrbitMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image("OrbitMark")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

struct OrbitNotice: View {
    var title: String
    var message: String
    var icon: String = "info.circle.fill"
    var tint: Color = .cyan

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint)
    }
}

/// Friendly placeholder with an optional action, used instead of bare text.
struct OrbitEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = .cyan
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 64, height: 64)
                Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1).frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(tint)
            }
            VStack(spacing: 4) {
                Text(title).font(.headline.weight(.bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(OrbitGlassButtonStyle(tint: tint))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

/// Applies the Orbit look to a `List`/`Form`: hidden system background with
/// the ambient theme behind it. Combine with `.orbitRow()` on sections.
struct OrbitListChrome: ViewModifier {
    var isOnline: Bool
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(OrbitAmbientBackground(isOnline: isOnline))
    }
}

struct OrbitRowBackground: ViewModifier {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    var tint: Color?
    func body(content: Content) -> some View {
        content.listRowBackground(
            ZStack {
                theme.surface.opacity(style == .improved ? 0.92 : 0.6)
                if let tint { tint.opacity(0.06) }
            }
        )
    }
}

extension View {
    func orbitListChrome(isOnline: Bool = true) -> some View { modifier(OrbitListChrome(isOnline: isOnline)) }
    func orbitRow(tint: Color? = nil) -> some View { modifier(OrbitRowBackground(tint: tint)) }
}

/// Labelled value used in hero cards (e.g. "PING  4 ms").
struct OrbitStatChip: View {
    var label: String
    var value: String
    var tint: Color = .white
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint.opacity(0.9))
            }
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
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
