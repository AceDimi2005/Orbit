import SwiftUI

/// Orbit's design tokens. One accent (the satellite's light) for interactive and live
/// elements; status colors only where a reading needs attention; everything else is
/// white type on a black canvas and quiet surfaces.
enum OrbitPalette {
    /// Orbit Blue, the default accent. Themes may replace it; views read `.tint`.
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let online = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let caution = Color(red: 255 / 255, green: 214 / 255, blue: 10 / 255)
    static let warm = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let critical = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    static let canvas = Color.black
    /// Grouped content on the canvas (Apple's dark secondary grouped background).
    static let surface = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// Controls and wells inside a surface.
    static let well = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    static let hairline = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.12)

    /// Temperature readings stay white until they need attention.
    static func temperature(_ celsius: Double?) -> Color {
        guard let celsius, celsius.isFinite else { return .secondary }
        switch celsius {
        case ..<80: return .primary
        case ..<90: return warm
        default: return critical
        }
    }

    /// Load bars: white, turning warm and then red near saturation.
    static func load(_ fraction: Double?) -> Color {
        guard let fraction, fraction.isFinite else { return .secondary }
        switch fraction {
        case ..<0.85: return .primary
        case ..<0.95: return warm
        default: return critical
        }
    }
}

/// The accent colors people choose from. Every platform stores the choice under the same
/// theme names ("noir", "ocean", …); these are the colors and names the redesign shows.
enum OrbitAccent {
    /// Free on every device; the rest come with Orbit Pro.
    static let included = ["noir", "ocean", "aurora", "violet", "ember", "graphite"]
    static let pro = ["cyberpunk", "solarGold", "crimson", "matrix", "arctic", "sakura"]

    static func color(theme: String) -> Color {
        switch theme {
        case "ocean": return Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255)
        case "aurora": return Color(red: 102 / 255, green: 212 / 255, blue: 207 / 255)
        case "violet": return Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
        case "ember": return OrbitPalette.warm
        case "graphite": return Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)
        case "cyberpunk": return Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255)
        case "solarGold": return Color(red: 230 / 255, green: 184 / 255, blue: 76 / 255)
        case "crimson": return OrbitPalette.critical
        case "matrix": return OrbitPalette.online
        case "arctic": return Color(red: 154 / 255, green: 216 / 255, blue: 255 / 255)
        case "sakura": return Color(red: 255 / 255, green: 143 / 255, blue: 183 / 255)
        default: return OrbitPalette.accent
        }
    }

    static func name(theme: String) -> String {
        switch theme {
        case "ocean": return "Teal"
        case "aurora": return "Mint"
        case "violet": return "Indigo"
        case "ember": return "Orange"
        case "graphite": return "Graphite"
        case "cyberpunk": return "Pink"
        case "solarGold": return "Gold"
        case "crimson": return "Red"
        case "matrix": return "Green"
        case "arctic": return "Ice"
        case "sakura": return "Rose"
        default: return "Orbit Blue"
        }
    }
}

enum OrbitMetrics {
    /// Corner radius of grouped surfaces; controls inside them use the concentric radius.
    static let surfaceRadius: CGFloat = 26
    static let controlRadius: CGFloat = 16
    static let gutter: CGFloat = 16
    static let sectionSpacing: CGFloat = 28
}

enum OrbitMotion {
    /// Default: critically damped, no overshoot.
    static let standard = Animation.spring(duration: 0.4, bounce: 0)
    /// Things that move because a hand moved them (cards, sheets, the satellite settling).
    static let momentum = Animation.spring(duration: 0.45, bounce: 0.18)
    static let quick = Animation.spring(duration: 0.25, bounce: 0)
}

extension Font {
    /// Big live readings: SF Pro, condensed and semibold, like an instrument cluster.
    static func orbitReading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}

extension View {
    /// Live numbers: tabular digits that roll instead of jumping.
    func orbitLiveNumber() -> some View {
        monospacedDigit().contentTransition(.numericText())
    }
}
