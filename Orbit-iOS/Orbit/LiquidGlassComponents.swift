import SwiftUI

/// A restrained material surface shared by the monitoring and remote screens.
struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.035))
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
    var isOnline: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.035, green: 0.045, blue: 0.065)
            Ellipse()
                .fill((isOnline ? Color.cyan : .indigo).opacity(0.10))
                .frame(width: 430, height: 350)
                .blur(radius: 100)
                .offset(x: -140, y: -130)
        }
        .ignoresSafeArea()
    }
}

struct HardwareMetricCard: View {
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
                    .foregroundStyle(accent)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
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
                    .frame(minHeight: 30, alignment: .topLeading)
                Text(detail ?? "Sensor unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(minHeight: 28, alignment: .topLeading)
            }

            GeometryReader { geometry in
                if let progress, progress.isFinite {
                    Capsule()
                        .fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(accent.opacity(0.85))
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                        }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, tint: accent)
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
