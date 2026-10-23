import SwiftUI

// The Send to PC sheet in Orbit's default "Noir" look (Orbit/Appearance.swift and
// Orbit/LiquidGlassComponents.swift): pure black, flat surfaces with a hairline, one cyan accent,
// white glyphs on neutral tiles and colour reserved for status. The extension cannot compile the
// app's design files (they pull in StoreKit and app state), so these are small local copies.

enum ShareTheme {
    static let background = Color.black
    static let surface = Color(red: 0.063, green: 0.063, blue: 0.07)
    static let raised = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.14)
    static let accent = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let success = Color(red: 0.30, green: 0.88, blue: 0.52)
    static let warning = Color(red: 1.0, green: 0.69, blue: 0.26)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let secondaryText = Color.white.opacity(0.64)
    static let maxContentWidth: CGFloat = 560
}

/// Flat card: opaque surface with a visible hairline (Noir's `liquidGlass`).
struct ShareCard: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(ShareTheme.surface))
            .overlay(shape.strokeBorder(ShareTheme.hairline, lineWidth: 1))
    }
}

extension View {
    func shareCard(cornerRadius: CGFloat = 20) -> some View { modifier(ShareCard(cornerRadius: cornerRadius)) }
}

/// Rounded-square icon tile (Noir's `OrbitIconBadge`).
struct ShareIconBadge: View {
    var systemName: String
    var tint: Color = .white
    var filled = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(.white.opacity(filled ? 0.22 : 0.10), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(filled ? Color.black.opacity(0.85) : (tint == .white ? Color.white.opacity(0.92) : tint))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Eyebrow header above a group (Noir's `OrbitSectionHeader`).
struct ShareSectionHeader: View {
    var title: String
    var icon: String?

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ShareTheme.accent)
                    .accessibilityHidden(true)
            }
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Capsule status indicator (Noir's `OrbitStatusPill`).
struct ShareStatusPill: View {
    var text: String
    var tint: Color
    var showsSpinner = false

    var body: some View {
        HStack(spacing: 6) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

/// Main call to action: solid accent with black text (Noir's `OrbitProminentButtonStyle`).
struct ShareProminentButtonStyle: ButtonStyle {
    var tint: Color = ShareTheme.accent
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(Color.black.opacity(0.9))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 15)
            .padding(.horizontal, 12)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.45)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Secondary action on a neutral tile (Noir's `OrbitGlassButtonStyle`, full width).
struct ShareSecondaryButtonStyle: ButtonStyle {
    var tint: Color = .white
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(tint == .white ? Color.white : tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(tint.opacity(tint == .white ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Inline message with an icon (Noir's `OrbitNotice`).
struct ShareNotice: View {
    var title: String
    var message: String
    var icon: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShareIconBadge(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ShareTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shareCard(cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
