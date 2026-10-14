import SwiftUI

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.15), tint.opacity(0.03), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.45),
                                tint.opacity(0.28),
                                .white.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 10)
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
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.08)
                .ignoresSafeArea()

            Circle()
                .fill(isOnline ? Color.cyan.opacity(0.26) : Color.indigo.opacity(0.2))
                .frame(width: 390, height: 390)
                .blur(radius: 95)
                .offset(x: -130, y: -230)

            Circle()
                .fill(isOnline ? Color.blue.opacity(0.24) : Color.purple.opacity(0.18))
                .frame(width: 350, height: 350)
                .blur(radius: 100)
                .offset(x: 140, y: 210)
        }
        .animation(.easeInOut(duration: 1.0), value: isOnline)
    }
}

struct DynamicIslandLiveBar: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.metrics.isOnline ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(vm.metrics.hostname)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Text(vm.metrics.activeGame ?? vm.islandModeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 8) {
                    Label("\(Int(vm.metrics.cpuTemp))°", systemImage: "cpu")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                    Label("\(Int(vm.metrics.gpuTemp))°", systemImage: "flame.fill")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.mint)
                }
            }

            if isExpanded {
                Divider().overlay(.white.opacity(0.15))

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU Power")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(Int(vm.metrics.gpuPowerWatts)) W")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.mint)
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ping")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(vm.pingMs) ms")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.cyan)
                    }

                    Spacer()

                    Button {
                        vm.toggleDynamicIsland()
                    } label: {
                        Text("Dismiss")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.25), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: isExpanded ? 26 : 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 26 : 30, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .cyan.opacity(0.25), radius: 14, x: 0, y: 6)
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isExpanded.toggle()
            }
        }
    }
}

struct HardwareMetricCard: View {
    let title: String
    let subtitle: String
    let valueText: String
    let progress: Double
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Spacer()

                Text(valueText)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * min(1, max(0, progress))))
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 6)
        }
        .padding(18)
        .liquidGlass(cornerRadius: 22, tint: accent)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 180, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
