import SwiftUI
import UIKit

/// The accent the app is drawn with. The stored names are the old theme names, so everyone
/// keeps their choice; the colors and names people see are `orbitTint` and `accentName`.
enum OrbitTheme: String, CaseIterable, Identifiable {
    // Included. Noir (Orbit Blue) is the default.
    case noir, ocean, aurora, violet, ember, graphite
    // Orbit Pro
    case cyberpunk, solarGold, crimson, matrix, arctic, sakura

    var id: String { rawValue }

    var isPro: Bool {
        switch self {
        case .noir, .ocean, .aurora, .violet, .ember, .graphite: false
        case .cyberpunk, .solarGold, .crimson, .matrix, .arctic, .sakura: true
        }
    }

    static var freeThemes: [OrbitTheme] { allCases.filter { !$0.isPro } }
    static var proThemes: [OrbitTheme] { allCases.filter { $0.isPro } }
}

enum OrbitAppIcon: String, CaseIterable, Identifiable {
    // Raw values are the alternate icon names (Shared/Icons/AppIcon-*.icon); they stay
    // stable so people keep the icon they picked.
    case classic = "default"
    case neon = "AppIcon-Neon"
    case gold = "AppIcon-Gold"
    case crimson = "AppIcon-Crimson"
    case matrix = "AppIcon-Matrix"
    case minimal = "AppIcon-Minimal"

    var id: String { rawValue }

    var iconName: String? {
        self == .classic ? nil : rawValue
    }

    var title: String {
        switch self {
        case .classic: "Graphite"
        case .neon: "Blue"
        case .gold: "Gold"
        case .crimson: "Red"
        case .matrix: "Green"
        case .minimal: "Light"
        }
    }

    var isPro: Bool { self != .classic }

    /// The icon the Home Screen shows right now (the system remembers it, not Orbit).
    static var current: OrbitAppIcon {
        OrbitAppIcon(rawValue: UIApplication.shared.alternateIconName ?? "default") ?? .classic
    }

    // The colors below mirror Tools/generate_orbit_icons.py, so the picker shows the
    // icon people will get (its default, light appearance).

    var backgroundTop: Color {
        switch self {
        case .classic, .crimson, .matrix: Self.p3(0.235, 0.247, 0.282)
        case .neon: Self.p3(0.169, 0.471, 1.0)
        case .gold: Self.p3(0.204, 0.180, 0.141)
        case .minimal: Self.p3(0.965, 0.965, 0.973)
        }
    }

    var backgroundBottom: Color {
        switch self {
        case .classic, .crimson, .matrix: Self.p3(0.063, 0.066, 0.078)
        case .neon: Self.p3(0.035, 0.153, 0.502)
        case .gold: Self.p3(0.051, 0.043, 0.031)
        case .minimal: Self.p3(0.820, 0.824, 0.847)
        }
    }

    var ringColor: Color {
        switch self {
        case .gold: Self.p3(0.902, 0.722, 0.298)
        case .minimal: Self.p3(0.110, 0.110, 0.122)
        default: .white
        }
    }

    var satelliteColor: Color {
        switch self {
        case .classic, .minimal: Self.p3(0.039, 0.518, 1.0)
        case .crimson: Self.p3(1.0, 0.271, 0.227)
        case .matrix: Self.p3(0.188, 0.820, 0.345)
        case .neon, .gold: .white
        }
    }

    private static func p3(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.displayP3, red: red, green: green, blue: blue)
    }
}

/// An app icon drawn from the same geometry as the real one: the mark on its background,
/// with a light rim where the glass catches the light.
struct OrbitAppIconPreview: View {
    var icon: OrbitAppIcon
    var size: CGFloat = 60

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        // The ring's outer edge spans 630 of the icon's 1024 points.
        let mark = size * 630 / 1024
        ZStack {
            shape.fill(LinearGradient(colors: [icon.backgroundTop, icon.backgroundBottom], startPoint: .top, endPoint: .bottom))
            OrbitRingShape()
                .stroke(icon.ringColor, style: StrokeStyle(lineWidth: mark * OrbitMarkGeometry.stroke, lineCap: .round))
                .frame(width: mark, height: mark)
            Circle()
                .fill(icon.satelliteColor)
                .frame(width: mark * OrbitMarkGeometry.satellite * 2, height: mark * OrbitMarkGeometry.satellite * 2)
                .offset(y: -mark * OrbitMarkGeometry.radius)
        }
        .frame(width: size, height: size)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, size / 120))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Orbit Pro

// The purchase itself lives in Shared/OrbitProStore.swift (shared with tvOS and macOS); the
// paywall and the gate are in OrbitProViews.swift.

/// Puts free-tier choices back when Orbit Pro is not (or no longer) owned, e.g. after a refund.
enum OrbitProLockdown {
    @MainActor static func enforce() {
        let store = OrbitProStore.shared
        guard store.hasVerifiedEntitlements, !store.isProUnlocked else { return }
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "orbit.theme"), OrbitTheme(rawValue: raw)?.isPro == true {
            defaults.set(OrbitTheme.noir.rawValue, forKey: "orbit.theme")
            NSUbiquitousKeyValueStore.default.set(OrbitTheme.noir.rawValue, forKey: "orbit.theme")
        }
        if let raw = defaults.string(forKey: "orbit.activity.accent"), OrbitTheme(rawValue: raw)?.isPro == true {
            defaults.set(OrbitTheme.noir.rawValue, forKey: "orbit.activity.accent")
        }
        if let raw = defaults.string(forKey: "orbit.appIcon"), OrbitAppIcon(rawValue: raw)?.isPro == true {
            defaults.set(OrbitAppIcon.classic.rawValue, forKey: "orbit.appIcon")
        }
        if UIApplication.shared.supportsAlternateIcons,
           let current = UIApplication.shared.alternateIconName,
           OrbitAppIcon(rawValue: current)?.isPro == true {
            UIApplication.shared.setAlternateIconName(nil)
        }
    }
}


// MARK: - Appearance environment

/// The accent and the dark appearance, applied at the root so sheets, covers and overlays
/// presented from there get them too.
struct OrbitAppearanceModifier: ViewModifier {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    func body(content: Content) -> some View {
        content
            .tint(theme.orbitTint)
            .preferredColorScheme(.dark)
            .environment(\.orbitAccent, theme.orbitTint)
    }
}

private struct OrbitAccentKey: EnvironmentKey { static let defaultValue = OrbitPalette.accent }

extension EnvironmentValues {
    var orbitAccent: Color { get { self[OrbitAccentKey.self] } set { self[OrbitAccentKey.self] = newValue } }
}

extension View { func orbitAppearance() -> some View { modifier(OrbitAppearanceModifier()) } }
