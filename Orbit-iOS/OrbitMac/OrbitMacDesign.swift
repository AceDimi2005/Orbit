import SwiftUI
import AppKit

// MARK: - Theme

/// Puts the free theme back when Orbit Pro is not (or no longer) owned, e.g. after a refund.
enum MacProLockdown {
    @MainActor static func enforce() {
        let store = OrbitProStore.shared
        guard store.hasVerifiedEntitlements, !store.isProUnlocked else { return }
        if let raw = UserDefaults.standard.string(forKey: "mac.theme"), MacTheme(rawValue: raw)?.isPro == true {
            UserDefaults.standard.set(MacTheme.noir.rawValue, forKey: "mac.theme")
        }
    }
}

enum MacTheme: String, CaseIterable, Identifiable {
    /// The six exclusive themes are part of Orbit Pro, as on iPhone.
    var isPro: Bool { [.cyberpunk, .solarGold, .crimson, .matrix, .arctic, .sakura].contains(self) }

    case noir, ocean, aurora, violet, ember, graphite, cyberpunk, solarGold, crimson, matrix, arctic, sakura

    var id: String { rawValue }
    /// Noir: pure black, one accent, flat surfaces, no glow. The default.
    var isFlat: Bool { self == .noir }
    var hairline: Color { isFlat ? .white.opacity(0.14) : .white.opacity(0.10) }
    var title: String {
        switch self {
        case .noir: "Noir"
        case .ocean: "Ocean"
        case .aurora: "Aurora"
        case .violet: "Violet"
        case .ember: "Ember"
        case .graphite: "Graphite"
        case .cyberpunk: "Cyberpunk"
        case .solarGold: "Solar Gold"
        case .crimson: "Crimson"
        case .matrix: "Matrix"
        case .arctic: "Arctic"
        case .sakura: "Sakura"
        }
    }
    var accent: Color {
        switch self {
        case .noir: Color(red: 0.36, green: 0.86, blue: 1.0)
        case .ocean: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .aurora: Color(red: 0.45, green: 0.92, blue: 0.73)
        case .violet: Color(red: 0.76, green: 0.66, blue: 1)
        case .ember: Color(red: 1, green: 0.70, blue: 0.43)
        case .graphite: Color(red: 0.82, green: 0.88, blue: 0.97)
        case .cyberpunk: Color(red: 1.0, green: 0.18, blue: 0.68)
        case .solarGold: Color(red: 0.98, green: 0.82, blue: 0.34)
        case .crimson: Color(red: 1.0, green: 0.32, blue: 0.38)
        case .matrix: Color(red: 0.18, green: 0.98, blue: 0.42)
        case .arctic: Color(red: 0.62, green: 0.92, blue: 1.0)
        case .sakura: Color(red: 1.0, green: 0.62, blue: 0.82)
        }
    }
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
    var background: Color {
        switch self {
        case .noir: .black
        case .ocean: Color(red: 0.035, green: 0.05, blue: 0.085)
        case .aurora: Color(red: 0.03, green: 0.06, blue: 0.05)
        case .violet: Color(red: 0.05, green: 0.035, blue: 0.085)
        case .ember: Color(red: 0.08, green: 0.045, blue: 0.03)
        case .graphite: Color(red: 0.045, green: 0.05, blue: 0.06)
        case .cyberpunk: Color(red: 0.065, green: 0.025, blue: 0.10)
        case .solarGold: Color(red: 0.07, green: 0.055, blue: 0.025)
        case .crimson: Color(red: 0.08, green: 0.025, blue: 0.035)
        case .matrix: Color(red: 0.02, green: 0.06, blue: 0.03)
        case .arctic: Color(red: 0.03, green: 0.06, blue: 0.10)
        case .sakura: Color(red: 0.075, green: 0.035, blue: 0.065)
        }
    }
    var surface: Color {
        switch self {
        case .noir: Color(red: 0.063, green: 0.063, blue: 0.07)
        case .ocean: Color(red: 0.085, green: 0.11, blue: 0.16)
        case .aurora: Color(red: 0.07, green: 0.12, blue: 0.10)
        case .violet: Color(red: 0.115, green: 0.09, blue: 0.17)
        case .ember: Color(red: 0.15, green: 0.095, blue: 0.07)
        case .graphite: Color(red: 0.10, green: 0.11, blue: 0.13)
        case .cyberpunk: Color(red: 0.125, green: 0.055, blue: 0.19)
        case .solarGold: Color(red: 0.135, green: 0.11, blue: 0.055)
        case .crimson: Color(red: 0.155, green: 0.06, blue: 0.075)
        case .matrix: Color(red: 0.045, green: 0.115, blue: 0.065)
        case .arctic: Color(red: 0.07, green: 0.12, blue: 0.175)
        case .sakura: Color(red: 0.14, green: 0.08, blue: 0.125)
        }
    }
    var heroGradient: LinearGradient {
        LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var heroColors: [Color] { [accent, secondary] }
}

private struct MacThemeKey: EnvironmentKey { static let defaultValue = MacTheme.noir }
extension EnvironmentValues {
    var macTheme: MacTheme { get { self[MacThemeKey.self] } set { self[MacThemeKey.self] = newValue } }
}

/// Applies the Orbit look to a scene root: theme tint, dark appearance and the
/// theme environment value.
struct MacAppearanceModifier: ViewModifier {
    @AppStorage("mac.theme") private var theme: MacTheme = .noir
    func body(content: Content) -> some View {
        content
            .tint(theme.accent)
            .environment(\.macTheme, theme)
            .preferredColorScheme(.dark)
    }
}
extension View { func macAppearance() -> some View { modifier(MacAppearanceModifier()) } }

// MARK: - Backgrounds & surfaces

struct MacAmbientBackground: View {
    @AppStorage("mac.theme") private var theme: MacTheme = .noir
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    var isOnline: Bool = true

    // Static glow: the previous perpetual drift re-rendered three large blurs on
    // every frame and cost real CPU while the window sat idle. Noir is plain black.
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                theme.background
                if !reduceGlow && !theme.isFlat {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                    Ellipse()
                        .fill(theme.accent.opacity(0.14))
                        .frame(width: max(600, size.width * 0.9), height: max(320, size.height * 0.45))
                        .blur(radius: 130)
                        .offset(x: -size.width * 0.3, y: -size.height * 0.3)
                    Ellipse()
                        .fill(theme.secondary.opacity(0.11))
                        .frame(width: max(500, size.width * 0.7), height: max(300, size.height * 0.4))
                        .blur(radius: 140)
                        .offset(x: size.width * 0.35, y: size.height * 0.25)
                    Circle()
                        .fill((isOnline ? theme.accent : Color.orange).opacity(0.05))
                        .frame(width: max(400, size.width * 0.5))
                        .blur(radius: 110)
                        .offset(x: size.width * 0.05, y: size.height * 0.6)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Glass card: opaque themed surface with a specular edge. Shadows are cast by
/// the silhouette only so glyphs inside never bleed.
struct MacGlassCard: ViewModifier {
    @AppStorage("mac.theme") private var theme: MacTheme = .noir
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    var cornerRadius: CGFloat = 18
    var tint: Color = .white
    var elevated: Bool = false
    var hovered: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if theme.isFlat {
                        shape.fill(hovered ? Color(red: 0.085, green: 0.085, blue: 0.095) : theme.surface)
                    } else {
                        shape.fill(theme.surface.opacity(0.92))
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(elevated || hovered ? 0.14 : 0.07), tint.opacity(0.015), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
                .compositingGroup()
                .shadow(color: .black.opacity(theme.isFlat ? 0 : 0.30), radius: elevated ? 22 : 10, y: elevated ? 10 : 4)
                .shadow(color: elevated && !reduceGlow && !theme.isFlat ? tint.opacity(0.12) : .clear, radius: 28, y: 8)
            }
            .overlay {
                if theme.isFlat {
                    shape.strokeBorder(hovered ? Color.white.opacity(0.22) : theme.hairline, lineWidth: 1)
                } else {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(hovered ? 0.30 : (elevated ? 0.24 : 0.16)), .white.opacity(0.05), tint.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
    }
}

extension View {
    func macGlass(cornerRadius: CGFloat = 18, tint: Color = .white, elevated: Bool = false, hovered: Bool = false) -> some View {
        modifier(MacGlassCard(cornerRadius: cornerRadius, tint: tint, elevated: elevated, hovered: hovered))
    }
}

/// Lifts a card slightly while the pointer is over it.
struct MacHoverLift: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered && !reduceMotion ? 1.012 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
            .onHover { hovered = $0 }
    }
}
extension View { func macHoverLift() -> some View { modifier(MacHoverLift()) } }

// MARK: - Primitives

struct MacIconBadge: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 30
    var filled: Bool = false
    @Environment(\.macTheme) private var theme

    private var fillStyle: AnyShapeStyle {
        if theme.isFlat {
            return filled ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.08))
        }
        return filled
            ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(fillStyle)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(.white.opacity(filled ? 0.22 : (theme.isFlat ? 0.10 : 0.08)), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(filled ? Color.black.opacity(0.85) : (theme.isFlat ? Color.white.opacity(0.92) : tint))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MacSectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var icon: String?
    var tint: Color?
    var trailing: Trailing
    @Environment(\.macTheme) private var theme

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, tint: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint ?? theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(.caption, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.62))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 2)
    }
}

extension MacSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil, tint: Color? = nil) {
        self.init(title, subtitle: subtitle, icon: icon, tint: tint) { EmptyView() }
    }
}

struct MacStatusPill: View {
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
                .font(.system(.caption, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            guard pulsing && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct MacStatChip: View {
    var label: String
    var value: String
    var icon: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint.opacity(0.9))
            }
            Text(label.uppercased())
                .font(.system(.caption2, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct MacRing: View {
    var progress: Double?
    var lineWidth: CGFloat = 6
    var tint: Color
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    @Environment(\.macTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            if let progress {
                let clamped = min(1, max(0, progress))
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * clamped)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: reduceGlow || theme.isFlat ? .clear : tint.opacity(0.5), radius: 6)
                    .animation(.snappy(duration: 0.45), value: clamped)
            }
        }
        .accessibilityHidden(true)
    }
}

struct MacSparklineShape: Shape {
    var values: [Double]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let finite = values.filter { $0.isFinite }
        guard finite.count > 1, rect.width > 0, rect.height > 0 else { return path }
        let minimum = finite.min() ?? 0
        let maximum = finite.max() ?? 1
        let span = max(maximum - minimum, 0.0001)
        let step = rect.width / CGFloat(finite.count - 1)
        let inset: CGFloat = 2
        let points: [CGPoint] = finite.enumerated().map { index, value in
            let normalized = CGFloat((value - minimum) / span)
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - inset - normalized * (rect.height - inset * 2))
        }
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
}

struct MacSparkline: View {
    var values: [Double]
    var tint: Color
    var lineWidth: CGFloat = 1.8
    var showsFill: Bool = true

    var body: some View {
        ZStack {
            if showsFill {
                MacSparklineShape(values: values, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            }
            MacSparklineShape(values: values)
                .stroke(
                    LinearGradient(colors: [tint.opacity(0.35), tint], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// Pointer-aware button: subtle hover highlight, press scale, disabled dimming.
struct MacHoverButtonStyle: ButtonStyle {
    var tint: Color = .white
    var prominent: Bool = false
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        MacHoverButtonBody(configuration: configuration, tint: tint, prominent: prominent, cornerRadius: cornerRadius)
    }

    private struct MacHoverButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        let cornerRadius: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.macTheme) private var theme

        var body: some View {
            configuration.label
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : (tint == .white ? Color.white : tint))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            prominent
                                ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(tint.opacity(tint == .white ? (hovered ? 0.14 : 0.08) : (hovered ? 0.22 : 0.13)))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(prominent ? .white.opacity(0.25) : tint.opacity(hovered ? 0.35 : 0.18), lineWidth: 1)
                )
                .shadow(color: prominent && !theme.isFlat ? tint.opacity(hovered ? 0.45 : 0.3) : .clear, radius: 12, y: 5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Borderless icon button used in toolbars and card corners.
struct MacIconButtonStyle: ButtonStyle {
    var tint: Color = .white
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        MacIconButtonBody(configuration: configuration, tint: tint, size: size)
    }

    private struct MacIconButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let size: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint == .white ? Color.white.opacity(0.9) : tint)
                .frame(width: size, height: size)
                .background(Color.white.opacity(hovered ? 0.12 : 0.06), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(hovered ? 0.18 : 0.08), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
                .contentShape(Circle())
        }
    }
}

/// Square tile with icon + title used for quick actions.
struct MacActionTile: View {
    var title: String
    var icon: String
    var tint: Color
    var isActive: Bool = false
    var minHeight: CGFloat = 62
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.85) : tint)
                    .frame(height: 20)
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hovered ? 0.10 : 0.055)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.4) : .white.opacity(hovered ? 0.16 : 0.07), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Cards

struct MacMetricCard: View {
    @AppStorage("mac.monochromeMetrics") private var monochrome = false
    @AppStorage("mac.theme") private var theme: MacTheme = .noir
    @AppStorage("mac.reduceGlow") private var reduceGlow = false
    let title: String
    let subtitle: String
    let valueText: String
    let progress: Double?
    let icon: String
    let accent: Color
    var detail: String? = nil
    var history: [Double] = []
    var showsRing: Bool = false

    private var metricAccent: Color { monochrome || theme.isFlat ? theme.accent : accent }
    private var glow: Bool { !reduceGlow && !theme.isFlat }
    private var isHot: Bool { progress != nil && (progress ?? 0) >= 0.9 }
    private var barTint: Color { isHot ? Color(red: 1.0, green: 0.42, blue: 0.38) : metricAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MacIconBadge(systemName: icon, tint: metricAccent, size: 26)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsRing, let progress {
                    MacRing(progress: progress, lineWidth: 3.5, tint: barTint)
                        .frame(width: 22, height: 22)
                }
            }
            ZStack(alignment: .bottomLeading) {
                if history.count >= 3 {
                    MacSparkline(values: history, tint: metricAccent.opacity(0.9), lineWidth: 1.6)
                        .frame(height: 30)
                        .padding(.leading, 70)
                        .padding(.bottom, 2)
                        .opacity(0.75)
                }
                Text(valueText)
                    .font(.system(size: 28, weight: .bold))
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
                        .font(.caption2)
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
        .macGlass(cornerRadius: 18, tint: metricAccent)
        .macHoverLift()
        .accessibilityElement(children: .combine)
    }
}

struct MacNotice: View {
    var title: String
    var message: String
    var icon: String = "info.circle.fill"
    var tint: Color = .cyan

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MacIconBadge(systemName: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGlass(cornerRadius: 16, tint: tint)
    }
}

struct MacEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = .cyan
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 68, height: 68)
                Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1).frame(width: 68, height: 68)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint)
            }
            VStack(spacing: 4) {
                Text(title).font(.headline.weight(.bold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(MacHoverButtonStyle(tint: tint))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }
}

/// Standard content column used by every section: constrained width, padding.
struct MacPage<Content: View>: View {
    var maxWidth: CGFloat = 1180
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: true) {
            content
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let rgb = hex.count == 6 ? value : 0x4DD9F7
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}
