import SwiftUI

/// Orbit's mark: a ring that opens for its satellite. At rest the satellite sits at the
/// top like a power light; while Orbit connects to or wakes the PC it travels around the
/// ring, and it settles back at the top once the PC answers. The app icon is drawn from
/// the same geometry.
struct OrbitMark: View {
    enum Status: Equatable {
        /// The PC answers: a white ring and a lit satellite.
        case online
        /// Asleep, off or unreachable: everything dims.
        case offline
        /// Connecting or waking: the satellite orbits.
        case working
        /// Signed out or locked: the satellite turns amber.
        case locked
        /// Only the shape, in one color (menus, small badges).
        case plain
    }

    var status: Status = .online
    var size: CGFloat = 44
    /// The satellite's light; nil uses the environment's tint (the theme accent).
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            OrbitRingShape()
                .stroke(ringColor, style: StrokeStyle(lineWidth: size * OrbitMarkGeometry.stroke, lineCap: .round))
            Circle()
                .fill(satelliteStyle)
                .frame(width: size * OrbitMarkGeometry.satellite * 2, height: size * OrbitMarkGeometry.satellite * 2)
                .offset(y: -size * OrbitMarkGeometry.radius)
                .opacity(status == .working && reduceMotion ? (pulse ? 0.35 : 1) : 1)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .animation(.easeInOut(duration: 0.35), value: status)
        .task(id: status == .working && !reduceMotion) {
            guard status == .working else {
                settle()
                return
            }
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                return
            }
            // One linear turn at a time, so stopping can settle from wherever the satellite is.
            while !Task.isCancelled {
                withAnimation(.linear(duration: 1.3)) { angle += 360 }
                try? await Task.sleep(for: .seconds(1.3))
            }
        }
        .onChange(of: status) { _, newValue in
            if newValue != .working { settle() }
        }
        .accessibilityHidden(true)
    }

    private func settle() {
        pulse = false
        let rest = (angle / 360).rounded(.up) * 360
        guard rest != angle else { return }
        withAnimation(.spring(duration: 0.7, bounce: 0.18)) { angle = rest }
    }

    private var light: AnyShapeStyle { tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint) }

    private var ringColor: AnyShapeStyle {
        switch status {
        case .offline: return AnyShapeStyle(Color.white.opacity(0.28))
        case .plain: return light
        default: return AnyShapeStyle(Color.white.opacity(0.94))
        }
    }

    private var satelliteStyle: AnyShapeStyle {
        switch status {
        case .online, .working, .plain: return light
        case .offline: return AnyShapeStyle(Color.white.opacity(0.28))
        case .locked: return AnyShapeStyle(OrbitPalette.caution)
        }
    }
}

/// Proportions of the mark, relative to the ring's outer diameter.
enum OrbitMarkGeometry {
    /// Ring center line, as a fraction of the mark's size.
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
struct OrbitRingShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let top = -Double.pi / 2
        var path = Path()
        path.addArc(center: center, radius: size * OrbitMarkGeometry.radius,
                    startAngle: .radians(top + OrbitMarkGeometry.halfGap),
                    endAngle: .radians(top - OrbitMarkGeometry.halfGap + 2 * .pi),
                    clockwise: false)
        return path
    }
}
