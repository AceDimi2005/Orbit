import SwiftUI

/// A restrained material surface shared by the monitoring and remote screens.
struct LiquidGlassCard: ViewModifier {
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 24
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .background {
                if style == .improved || reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(theme.surface)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.035))
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, tint: Color = .white) -> some View {
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
                        .fill(theme.accent.opacity(style == .improved ? 0.06 : 0.12))
                        .frame(width: 430, height: 350)
                        .blur(radius: 100)
                        .offset(x: -140, y: -130)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(metricAccent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .improved ? Color.white.opacity(0.9) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }

            Text(valueText)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 4) {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 30, alignment: .topLeading)
                Text(detail ?? "Sensor unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28, alignment: .topLeading)
            }

            GeometryReader { geometry in
                if let progress, progress.isFinite {
                    Capsule()
                        .fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(metricAccent.opacity(0.85))
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                        }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: metricAccent)
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
    var icon: String = "info.circle"
    var tint: Color = .cyan

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
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
