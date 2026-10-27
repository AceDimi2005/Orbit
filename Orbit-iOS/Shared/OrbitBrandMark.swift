import SwiftUI

/// Orbit's logo, the app icon's art without its background: a blue glass planet, a glowing ring that
/// passes behind it at the top and in front of it at the bottom, and an amber moon riding the ring.
/// Drawn with shapes instead of the bitmap, so it stays sharp from a 14 pt Dynamic Island badge up
/// to an onboarding mark, on any background.
struct OrbitBrandMark: View {
    /// The ring's glow (the theme accent); the ring itself stays white like the icon.
    var tint: Color = OrbitBrandMark.ringGlow
    /// Kept for callers that recolour the ring (Lock Screen accessories, which render in one colour).
    var ring: Color = .white
    /// The soft light around the ring and moon; turn it off where the system tints content.
    var glow: Bool = true

    static let ringGlow = Color(red: 0.55, green: 0.86, blue: 1.0)
    private static let tilt = Angle.degrees(-22)
    /// Where the moon sits on the ring (degrees from the right end, negative = up, before the tilt).
    private static let moonAngle = -58.0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ringWidth = side * 0.98
            let ringHeight = side * 0.40
            let stroke = max(1.2, side * 0.06)
            ZStack {
                // The whole ring first; the planet then covers its far side, and the near half is drawn
                // again on top in the same colours, so no seam shows where it starts and ends.
                ringPath(width: ringWidth, height: ringHeight, stroke: stroke, nearHalfOnly: false, side: side)
                planet(side: side)
                ringPath(width: ringWidth, height: ringHeight, stroke: stroke, nearHalfOnly: true, side: side)
                moon(side: side, ringWidth: ringWidth, ringHeight: ringHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func ringPath(width: CGFloat, height: CGFloat, stroke: CGFloat, nearHalfOnly: Bool, side: CGFloat) -> some View {
        Ellipse()
            .trim(from: 0, to: nearHalfOnly ? 0.5 : 1)
            .stroke(
                LinearGradient(colors: [ring, ring.opacity(0.92), Color(red: 0.86, green: 0.96, blue: 1)], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
            )
            .frame(width: width, height: height)
            .shadow(color: glow && !nearHalfOnly ? tint.opacity(0.95) : .clear, radius: side * 0.05)
            .shadow(color: glow && !nearHalfOnly ? tint.opacity(0.55) : .clear, radius: side * 0.11)
            .rotationEffect(Self.tilt)
    }

    private func planet(side: CGFloat) -> some View {
        let diameter = side * 0.5
        return ZStack {
            // Body: light blue on the lit side to deep blue at the rim.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.52, green: 0.80, blue: 0.98),
                            Color(red: 0.20, green: 0.50, blue: 0.86),
                            Color(red: 0.07, green: 0.24, blue: 0.58)
                        ],
                        center: UnitPoint(x: 0.36, y: 0.32),
                        startRadius: 0,
                        endRadius: diameter * 0.72
                    )
                )
            // Soft bands, like the icon's gas-giant stripes.
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.30),
                            .init(color: .white.opacity(0.12), location: 0.40),
                            .init(color: .clear, location: 0.50),
                            .init(color: Color(red: 0.05, green: 0.2, blue: 0.5).opacity(0.25), location: 0.62),
                            .init(color: .clear, location: 0.72)
                        ],
                        startPoint: UnitPoint(x: 0.2, y: 0.1),
                        endPoint: UnitPoint(x: 0.8, y: 0.9)
                    )
                )
            // Rim light.
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color(red: 0.6, green: 0.95, blue: 1).opacity(0.9), .clear], startPoint: .bottomTrailing, endPoint: .topLeading),
                    lineWidth: max(0.5, side * 0.014)
                )
            // Specular highlight, upper left.
            Ellipse()
                .fill(.white.opacity(0.85))
                .frame(width: diameter * 0.16, height: diameter * 0.11)
                .offset(x: -diameter * 0.12, y: -diameter * 0.17)
                .blur(radius: max(0.4, side * 0.012))
        }
        .frame(width: diameter, height: diameter)
    }

    private func moon(side: CGFloat, ringWidth: CGFloat, ringHeight: CGFloat) -> some View {
        let radians = Self.moonAngle * .pi / 180
        let x = cos(radians) * ringWidth / 2
        let y = sin(radians) * ringHeight / 2
        let tilt = Self.tilt.radians
        let rotatedX = x * cos(tilt) - y * sin(tilt)
        let rotatedY = x * sin(tilt) + y * cos(tilt)
        let diameter = max(3, side * 0.17)
        return Circle()
            .fill(
                RadialGradient(
                    colors: [Color(red: 1.0, green: 0.93, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.18), Color(red: 0.93, green: 0.40, blue: 0.08)],
                    center: UnitPoint(x: 0.35, y: 0.32),
                    startRadius: 0,
                    endRadius: diameter * 0.62
                )
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: glow ? Color(red: 1, green: 0.6, blue: 0.2).opacity(0.6) : .clear, radius: side * 0.04)
            .offset(x: rotatedX, y: rotatedY)
    }
}
