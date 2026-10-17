import SwiftUI

/// A restrained material surface shared by the monitoring and remote screens.
struct LiquidGlassCard: ViewModifier {
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 22
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .background {
                if style == .improved || reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(theme.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [tint.opacity(0.055), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.045))
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 22, tint: Color = .white) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tint: tint))
    }
}

struct OrbitAmbientBackground: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var isOnline: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                theme.background
                if !reduceGlow && !reduceTransparency {
                    Ellipse()
                        .fill(theme.accent.opacity(style == .improved ? 0.08 : 0.14))
                        .frame(width: 420, height: 320)
                        .blur(radius: 95)
                        .offset(x: -120, y: -120)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

struct HardwareMetricCard: View {
    @AppStorage("orbit.monochromeMetrics") private var monochrome = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    private var metricAccent: Color { monochrome ? theme.accent : accent }
    let title: String
    let subtitle: String
    let valueText: String
    let progress: Double?
    let icon: String
    let accent: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(metricAccent.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(metricAccent)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .improved ? Color.white.opacity(0.92) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            Text(valueText)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minHeight: 28, alignment: .topLeading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.07))
                    if let progress, progress.isFinite {
                        Capsule()
                            .fill(metricAccent.gradient)
                            .frame(width: max(4, geometry.size.width * min(1, max(0, progress))))
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

struct OrbitMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image("OrbitMark")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
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
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint)
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
