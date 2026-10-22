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


/// The window canvas: plain black, so content and glass carry the hierarchy.
struct MacAmbientBackground: View {
    var isOnline: Bool = true

    var body: some View {
        OrbitPalette.canvas.ignoresSafeArea()
    }
}


/// Grouped content on a quiet solid surface; it brightens slightly under the pointer.
struct MacGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tint: Color = .white
    var elevated: Bool = false
    var hovered: Bool = false

    func body(content: Content) -> some View {
        content.background(hovered ? OrbitPalette.well : OrbitPalette.surface,
                           in: RoundedRectangle(cornerRadius: max(cornerRadius, 14), style: .continuous))
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


/// A plain symbol; color is kept for status, not decoration.
struct MacIconBadge: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 30
    var filled: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}


/// A section title in Title Case, an optional one-line subtitle and a trailing control.
struct MacSectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var icon: String?
    var tint: Color?
    var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, tint: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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


/// A status light with its label; it pulses while something is live.
struct MacStatusPill: View {
    var text: String
    var tint: Color
    var pulsing: Bool = false
    var icon: String? = nil

    var body: some View {
        Group {
            if let icon {
                Label {
                    Text(text).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                .font(.callout)
            } else {
                OrbitStatusLabel(text: text, color: tint, pulsing: pulsing)
                    .font(.callout)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}


/// A small labelled value ("Ping 4 ms").
struct MacStatChip: View {
    var label: String
    var value: String
    var icon: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .font(.callout)
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


/// Buttons on the Mac: glass capsules; prominent ones are tinted with the accent.
struct MacHoverButtonStyle: ButtonStyle {
    var tint: Color = .white
    var prominent: Bool = false
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        MacHoverButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct MacHoverButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(prominent ? Color.white : (tint == .white ? Color.primary : tint))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(prominent ? .regular.tint(tint == .white ? OrbitPalette.accent : tint).interactive() : .regular.interactive(), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(OrbitMotion.quick, value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}


/// Round glass icon buttons for toolbars and card corners.
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
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(tint == .white ? Color.primary : tint)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(OrbitMotion.quick, value: configuration.isPressed)
                .contentShape(Circle())
        }
    }
}


/// A quick action: a symbol over a short label on a quiet surface; accent-filled while active.
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
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 6)
            .background(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(hovered ? OrbitPalette.well : OrbitPalette.surface),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: hovered)
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


/// An inline note: a symbol, a short title and a line or two of explanation.
struct MacNotice: View {
    var title: String
    var message: String
    var icon: String = "info.circle.fill"
    var tint: Color = .cyan

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}


/// A calm placeholder with an optional action.
struct MacEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = .cyan
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(MacHoverButtonStyle(tint: tint == .cyan ? .white : tint, prominent: true))
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 32)
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
