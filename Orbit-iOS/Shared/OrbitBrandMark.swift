import SwiftUI

/// Orbit's logo: a ring that opens at the top for its satellite, like a power light. Drawn with shapes
/// (the same geometry as the app icon), so it stays sharp from a 12 pt Dynamic Island badge to a
/// full-size onboarding mark, and the satellite takes the theme accent.
struct OrbitBrandMark: View {
    /// The satellite's colour (the theme accent).
    var tint: Color = OrbitBrandMark.defaultTint
    /// The ring's colour.
    var ring: Color = .white.opacity(0.94)
    /// A soft light around the satellite; turn it off where the system tints content.
    var glow: Bool = true

    static let defaultTint = Color(red: 0.039, green: 0.518, blue: 1.0)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                OrbitBrandRingShape()
                    .stroke(ring, style: StrokeStyle(lineWidth: side * OrbitBrandGeometry.stroke, lineCap: .round))
                Circle()
                    .fill(tint)
                    .frame(width: side * OrbitBrandGeometry.satellite * 2, height: side * OrbitBrandGeometry.satellite * 2)
                    .shadow(color: glow ? tint.opacity(0.85) : .clear, radius: side * 0.06)
                    .offset(y: -side * OrbitBrandGeometry.radius)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Proportions of the mark, relative to its size (from the app icon's 676-unit drawing).
enum OrbitBrandGeometry {
    /// Ring centre line radius.
    static let radius: CGFloat = 290.0 / 676.0
    static let stroke: CGFloat = 96.0 / 676.0
    static let satellite: CGFloat = 66.0 / 676.0
    static let margin: CGFloat = 40.0 / 676.0

    /// Half of the opening around the satellite, in radians.
    static var halfGap: Double {
        Double((satellite + margin + stroke / 2) / radius)
    }
}

/// The ring, open at the top.
struct OrbitBrandRingShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let top = -Double.pi / 2
        var path = Path()
        path.addArc(center: center, radius: size * OrbitBrandGeometry.radius,
                    startAngle: .radians(top + OrbitBrandGeometry.halfGap),
                    endAngle: .radians(top - OrbitBrandGeometry.halfGap + 2 * .pi),
                    clockwise: false)
        return path
    }
}
