import StoreKit
import SwiftUI
import UIKit

enum OrbitVisualStyle: String, CaseIterable, Identifiable {
    case improved, classic
    var id: String { rawValue }
    var title: String { self == .improved ? "Crisp" : "Glass" }
    var detail: String { self == .improved ? "Opaque surfaces with high contrast and a soft specular edge." : "Translucent cards that let the ambient glow bleed through." }
}

enum OrbitTheme: String, CaseIterable, Identifiable {
    // Free themes. Noir is the default: pure black, one accent, no decoration.
    case noir, ocean, aurora, violet, ember, graphite
    // Orbit Pro themes
    case cyberpunk, solarGold, crimson, matrix, arctic, sakura

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noir: "Noir"
        case .ocean: "Ocean"
        case .aurora: "Aurora"
        case .violet: "Violet"
        case .ember: "Ember"
        case .graphite: "Graphite"
        case .cyberpunk: "Cyberpunk"
        case .solarGold: "Solar Gold"
        case .crimson: "Crimson"
        case .matrix: "Matrix"
        case .arctic: "Arctic"
        case .sakura: "Sakura"
        }
    }

    var isPro: Bool {
        switch self {
        case .noir, .ocean, .aurora, .violet, .ember, .graphite: false
        case .cyberpunk, .solarGold, .crimson, .matrix, .arctic, .sakura: true
        }
    }

    static var freeThemes: [OrbitTheme] { allCases.filter { !$0.isPro } }
    static var proThemes: [OrbitTheme] { allCases.filter { $0.isPro } }

    var accent: Color {
        switch self {
        case .noir: Color(red: 0.36, green: 0.86, blue: 1.0)
        case .ocean: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .aurora: Color(red: 0.45, green: 0.92, blue: 0.73)
        case .violet: Color(red: 0.76, green: 0.66, blue: 1)
        case .ember: Color(red: 1, green: 0.70, blue: 0.43)
        case .graphite: Color(red: 0.82, green: 0.88, blue: 0.97)
        case .cyberpunk: Color(red: 1.0, green: 0.18, blue: 0.68)
        case .solarGold: Color(red: 0.98, green: 0.82, blue: 0.34)
        case .crimson: Color(red: 1.0, green: 0.32, blue: 0.38)
        case .matrix: Color(red: 0.18, green: 0.98, blue: 0.42)
        case .arctic: Color(red: 0.62, green: 0.92, blue: 1.0)
        case .sakura: Color(red: 1.0, green: 0.62, blue: 0.82)
        }
    }

    var background: Color {
        switch self {
        case .noir: .black
        case .ocean: Color(red: 0.025, green: 0.045, blue: 0.075)
        case .aurora: Color(red: 0.025, green: 0.055, blue: 0.045)
        case .violet: Color(red: 0.045, green: 0.03, blue: 0.075)
        case .ember: Color(red: 0.075, green: 0.04, blue: 0.025)
        case .graphite: Color(red: 0.04, green: 0.045, blue: 0.055)
        case .cyberpunk: Color(red: 0.06, green: 0.02, blue: 0.095)
        case .solarGold: Color(red: 0.065, green: 0.05, blue: 0.02)
        case .crimson: Color(red: 0.075, green: 0.02, blue: 0.03)
        case .matrix: Color(red: 0.015, green: 0.055, blue: 0.025)
        case .arctic: Color(red: 0.025, green: 0.055, blue: 0.095)
        case .sakura: Color(red: 0.07, green: 0.03, blue: 0.06)
        }
    }

    var surface: Color {
        switch self {
        case .noir: Color(red: 0.063, green: 0.063, blue: 0.07)
        case .ocean: Color(red: 0.075, green: 0.10, blue: 0.145)
        case .aurora: Color(red: 0.065, green: 0.115, blue: 0.095)
        case .violet: Color(red: 0.11, green: 0.085, blue: 0.16)
        case .ember: Color(red: 0.145, green: 0.09, blue: 0.065)
        case .graphite: Color(red: 0.095, green: 0.105, blue: 0.125)
        case .cyberpunk: Color(red: 0.12, green: 0.05, blue: 0.18)
        case .solarGold: Color(red: 0.13, green: 0.105, blue: 0.05)
        case .crimson: Color(red: 0.15, green: 0.055, blue: 0.07)
        case .matrix: Color(red: 0.04, green: 0.11, blue: 0.06)
        case .arctic: Color(red: 0.065, green: 0.115, blue: 0.17)
        case .sakura: Color(red: 0.135, green: 0.075, blue: 0.12)
        }
    }

    /// Noir draws flat surfaces with a visible hairline, no ambient glow, no gradients
    /// and one accent for every metric. Primitives read this to drop their decoration.
    var isFlat: Bool { self == .noir }
    var hairline: Color { isFlat ? .white.opacity(0.14) : .white.opacity(0.10) }

    /// sRGB hex (without #) of the accent, shared with Apple Watch so the wrist
    /// app can follow the iPhone theme.
    var accentHex: String { Self.hex(accent) }
    var secondaryHex: String { Self.hex(secondary) }

    private static func hex(_ color: Color) -> String {
        let components = UIColor(color).cgColor.components ?? [0, 0, 0, 1]
        let r = Int((components.count > 0 ? components[0] : 0) * 255)
        let g = Int((components.count > 1 ? components[1] : 0) * 255)
        let b = Int((components.count > 2 ? components[2] : 0) * 255)
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

enum OrbitAppIcon: String, CaseIterable, Identifiable {
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
        case .classic: "Orbit Cyan"
        case .neon: "Cyber Neon"
        case .gold: "Solar Gold"
        case .crimson: "Crimson"
        case .matrix: "Matrix"
        case .minimal: "Titanium"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "Default"
        case .neon: "Pro · Magenta & Cyan"
        case .gold: "Pro · Obsidian Gold"
        case .crimson: "Pro · Carbon Ruby"
        case .matrix: "Pro · Phosphor Green"
        case .minimal: "Pro · Monochrome"
        }
    }

    var isPro: Bool { self != .classic }

    var primaryColor: Color {
        switch self {
        case .classic: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .neon: Color(red: 1.0, green: 0.18, blue: 0.72)
        case .gold: Color(red: 0.99, green: 0.82, blue: 0.32)
        case .crimson: Color(red: 1.0, green: 0.26, blue: 0.36)
        case .matrix: Color(red: 0.18, green: 0.98, blue: 0.44)
        case .minimal: Color(red: 0.88, green: 0.92, blue: 0.98)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .classic: Color(red: 0.14, green: 0.50, blue: 0.92)
        case .neon: Color(red: 0.18, green: 0.92, blue: 1.0)
        case .gold: Color(red: 0.78, green: 0.54, blue: 0.14)
        case .crimson: Color(red: 1.0, green: 0.52, blue: 0.30)
        case .matrix: Color(red: 0.08, green: 0.68, blue: 0.42)
        case .minimal: Color(red: 0.45, green: 0.50, blue: 0.60)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .classic: Color(red: 0.04, green: 0.07, blue: 0.13)
        case .neon: Color(red: 0.08, green: 0.02, blue: 0.14)
        case .gold: Color(red: 0.09, green: 0.07, blue: 0.03)
        case .crimson: Color(red: 0.11, green: 0.025, blue: 0.04)
        case .matrix: Color(red: 0.02, green: 0.08, blue: 0.035)
        case .minimal: Color(red: 0.09, green: 0.10, blue: 0.12)
        }
    }
}

// MARK: - StoreKit 2 Manager for Orbit Pro (One-Time Lifetime Unlock)

// Orbit Pro purchase logic lives in Shared/OrbitProStore.swift (shared with tvOS and macOS).

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

/// Shows `content` with Orbit Pro, otherwise an explanation and an unlock button.
struct OrbitProGate<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ObservedObject private var store = OrbitProStore.shared
    @State private var showsPaywall = false

    var body: some View {
        if store.isProUnlocked {
            content()
        } else {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                VStack(spacing: 16) {
                    OrbitIconBadge(systemName: "lock.fill", tint: .yellow, size: 56)
                    Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        showsPaywall = true
                    } label: {
                        Label("Unlock with Orbit Pro", systemImage: "crown.fill")
                    }
                    .buttonStyle(OrbitProminentButtonStyle(colors: [Color(red: 1.0, green: 0.86, blue: 0.36), Color(red: 0.96, green: 0.68, blue: 0.22)]))
                }
                .frame(maxWidth: 420)
                .padding(28)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsPaywall) { OrbitProPaywallView() }
        }
    }
}

// MARK: - Appearance environment

struct OrbitAppearanceModifier: ViewModifier {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    func body(content: Content) -> some View {
        content.tint(theme.accent).preferredColorScheme(.dark)
            .environment(\.orbitAccent, theme.accent)
            .environment(\.orbitTheme, theme)
            .environment(\.orbitImprovedStyle, style == .improved)
    }
}
private struct OrbitAccentKey: EnvironmentKey { static let defaultValue = OrbitTheme.noir.accent }
private struct OrbitThemeKey: EnvironmentKey { static let defaultValue = OrbitTheme.noir }
private struct OrbitImprovedKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var orbitAccent: Color { get { self[OrbitAccentKey.self] } set { self[OrbitAccentKey.self] = newValue } }
    var orbitTheme: OrbitTheme { get { self[OrbitThemeKey.self] } set { self[OrbitThemeKey.self] = newValue } }
    var orbitImprovedStyle: Bool { get { self[OrbitImprovedKey.self] } set { self[OrbitImprovedKey.self] = newValue } }
}
extension View { func orbitAppearance() -> some View { modifier(OrbitAppearanceModifier()) } }

// MARK: - Appearance settings

struct AppearanceSettingsView: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.monochromeMetrics") private var monochromeMetrics = false
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @AppStorage("orbit.haptics") private var hapticsEnabled = true
    @AppStorage("orbit.appIcon") private var selectedIcon: OrbitAppIcon = .classic
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showPaywall = false
    @State private var iconError: String?

    var body: some View {
        Form {
            Section {
                livePreview
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Preview · example data")
            }

            Section {
                themeStrip(OrbitTheme.freeThemes)
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
            } header: {
                Text("Themes")
            } footer: {
                Text("Noir keeps a black background and a single accent colour. Widgets and the Live Activity have their own colour pickers.")
            }
            .orbitRow()

            Section {
                themeStrip(OrbitTheme.proThemes)
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
            } header: {
                Text("More themes")
            }
            .orbitRow(tint: .yellow)

            Section {
                Picker("Surface", selection: $style) {
                    ForEach(OrbitVisualStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: style) { _, _ in OrbitHaptics.selection() }
                Text(style.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Surface Style")
            }
            .orbitRow()

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(OrbitAppIcon.allCases) { icon in
                        appIconTile(icon)
                    }
                }
                .padding(.vertical, 4)
                if let iconError {
                    Text(iconError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Home Screen Icon")
            }
            .orbitRow()

            Section {
                settingToggle("Single Accent Colour", icon: "paintbrush.pointed.fill", tint: theme.accent, isOn: $monochromeMetrics)
                settingToggle("Ambient Background Glow", icon: "sun.haze.fill", tint: .orange, isOn: Binding(get: { !reduceGlow }, set: { reduceGlow = !$0 }))
                settingToggle("Haptic Feedback", icon: "hand.tap.fill", tint: .mint, isOn: $hapticsEnabled)
            } header: {
                Text("Display & Feel")
            } footer: {
                Text("Single accent colours every metric with the theme tint instead of per-component colours.")
            }
            .orbitRow()

            Section {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        OrbitIconBadge(systemName: "crown.fill", tint: .yellow, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Orbit Pro")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text(proStore.isProUnlocked
                                 ? "Unlocked on all your devices"
                                 : "Exclusive themes, app icons, widgets & session graphs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(proStore.isProUnlocked ? "ACTIVE" : (proStore.displayPrice ?? "PRO"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.yellow)
                    }
                    .padding(.vertical, 2)
                }
            }
            .orbitRow(tint: .yellow)
        }
        .orbitListChrome()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            OrbitProPaywallView()
        }
        .onAppear {
            let current = UIApplication.shared.alternateIconName ?? "default"
            if let match = OrbitAppIcon(rawValue: current) {
                selectedIcon = match
            }
        }
        .orbitAppearance()
    }

    private var livePreview: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    OrbitRingGauge(progress: 0.68, lineWidth: 5, tint: theme.accent)
                        .frame(width: 48, height: 48)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.heroGradient)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example PC")
                        .font(.headline.weight(.bold))
                    HStack(spacing: 6) {
                        OrbitStatusPill(text: "Preview", tint: theme.accent, pulsing: false)
                        OrbitStatChip(label: "Ping", value: "4 ms")
                    }
                }
                Spacer()
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, tint: theme.accent, elevated: true)

            HStack(spacing: 10) {
                HardwareMetricCard(
                    title: "Processor", subtitle: "Ryzen 7 7800X3D", valueText: "24%", progress: 0.24,
                    icon: "cpu", accent: .cyan, detail: "48°C · 4.85 GHz",
                    history: [18, 22, 31, 27, 24, 29, 35, 26, 22, 24]
                )
                HardwareMetricCard(
                    title: "Graphics", subtitle: "RTX 4080 SUPER", valueText: "71%", progress: 0.71,
                    icon: "square.stack.3d.up", accent: .mint, detail: "63°C · 245 W",
                    history: [55, 62, 70, 74, 69, 72, 78, 75, 70, 71]
                )
            }
        }
        .padding(.horizontal, 2)
        .animation(.snappy, value: theme)
        .animation(.snappy, value: style)
        .animation(.snappy, value: monochromeMetrics)
    }

    private func themeStrip(_ themes: [OrbitTheme]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(themes) { item in themeSwatch(item) }
            }
            .padding(.horizontal, 6)
        }
    }

    private func settingToggle(_ title: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: icon, tint: tint, size: 30)
                Text(title)
            }
        }
        .onChange(of: isOn.wrappedValue) { _, _ in OrbitHaptics.selection() }
    }

    private func themeSwatch(_ item: OrbitTheme) -> some View {
        let locked = item.isPro && !proStore.isProUnlocked
        let selected = theme == item
        return Button {
            if locked {
                showPaywall = true
            } else {
                OrbitHaptics.selection()
                withAnimation(.snappy) { theme = item }
                NSUbiquitousKeyValueStore.default.set(item.rawValue, forKey: "orbit.theme")
            }
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(item.background)
                            .frame(width: 50, height: 50)
                        Circle()
                            .fill(LinearGradient(colors: [item.accent, item.secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 32, height: 32)
                            .shadow(color: item.accent.opacity(0.5), radius: selected ? 10 : 4)
                        Circle()
                            .strokeBorder(selected ? item.accent : .white.opacity(0.14), lineWidth: selected ? 2.5 : 1)
                            .frame(width: 50, height: 50)
                    }
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3.5)
                            .background(Color.yellow, in: Circle())
                            .offset(x: 2, y: -2)
                    } else if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(4)
                            .background(item.accent, in: Circle())
                            .offset(x: 2, y: -2)
                    }
                }
                Text(item.title)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? .white : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 66)
            .scaleEffect(selected ? 1.04 : 1)
            .animation(.snappy, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func appIconTile(_ icon: OrbitAppIcon) -> some View {
        let locked = icon.isPro && !proStore.isProUnlocked
        let isSelected = selectedIcon == icon
        return Button {
            if locked {
                showPaywall = true
                return
            }
            applyAppIcon(icon)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(icon.backgroundColor)
                        .frame(width: 54, height: 54)
                        .overlay(
                            ZStack {
                                Circle()
                                    .strokeBorder(icon.secondaryColor.opacity(0.45), lineWidth: 3.5)
                                    .frame(width: 36, height: 36)
                                Circle()
                                    .trim(from: 0.08, to: 0.82)
                                    .stroke(icon.primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .frame(width: 36, height: 36)
                                    .rotationEffect(.degrees(-35))
                                Circle()
                                    .fill(LinearGradient(colors: [icon.primaryColor, icon.secondaryColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 14, height: 14)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isSelected ? icon.primaryColor : .white.opacity(0.14), lineWidth: isSelected ? 2.2 : 1)
                        )
                        .shadow(color: isSelected ? icon.primaryColor.opacity(0.45) : .clear, radius: 10)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(4)
                            .background(Color.yellow, in: Circle())
                            .offset(x: 4, y: -4)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(icon.primaryColor)
                            .background(Circle().fill(.black))
                            .offset(x: 4, y: -4)
                    }
                }
                Text(icon.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.white.opacity(isSelected ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func applyAppIcon(_ icon: OrbitAppIcon) {
        iconError = nil
        guard UIApplication.shared.supportsAlternateIcons else {
            iconError = "Alternate app icons are not supported on this device."
            return
        }
        UIApplication.shared.setAlternateIconName(icon.iconName) { error in
            Task { @MainActor in
                if let error {
                    iconError = error.localizedDescription
                } else {
                    OrbitHaptics.success()
                    selectedIcon = icon
                }
            }
        }
    }
}

// MARK: - Orbit Pro Paywall & Legal Views (App Store Guideline 3.1.1 Compliant)

struct OrbitProPaywallView: View {
    @ObservedObject private var store = OrbitProStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.orbitAccent) private var accent
    @State private var showPrivacy = false

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: true)
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.yellow.opacity(0.32), accent.opacity(0.24)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 84, height: 84)
                                Circle()
                                    .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                                    .frame(width: 84, height: 84)
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.yellow, Color(red: 1.0, green: 0.72, blue: 0.25)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .shadow(color: .yellow.opacity(0.5), radius: 14)
                            }
                            .padding(.top, 8)

                            Text("Orbit Pro")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)

                            Text("One-time purchase · iPhone, iPad, Apple TV and Mac")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            proFeatureRow(
                                icon: "paintpalette.fill",
                                tint: Color(red: 1.0, green: 0.22, blue: 0.70),
                                title: "6 Exclusive Luxury Themes",
                                subtitle: "Cyberpunk, Solar Gold, Crimson, Matrix, Arctic, and Sakura across app, widgets & Apple Watch."
                            )
                            proFeatureRow(
                                icon: "app.badge.checkmark",
                                tint: Color(red: 0.99, green: 0.82, blue: 0.32),
                                title: "5 Custom Home Screen App Icons",
                                subtitle: "Switch your iPhone Home Screen icon between Neon, Gold, Crimson, Matrix, and Titanium."
                            )
                            proFeatureRow(
                                icon: "power.circle.fill",
                                tint: Color(red: 0.38, green: 0.96, blue: 0.68),
                                title: "Interactive Power & Control Center Widgets",
                                subtitle: "Power On (Wake-on-LAN), Sleep, and Shut Down directly from Home Screen, Control Center, and Siri."
                            )
                            proFeatureRow(
                                icon: "chart.xyaxis.line",
                                tint: accent,
                                title: "Multi-PC Profiles & Session Graphs",
                                subtitle: "Save unlimited PCs and inspect historical FPS, temperature, and power telemetry graphs."
                            )
                            proFeatureRow(
                                icon: "square.grid.3x2.fill",
                                tint: .pink,
                                title: "Unlimited Buttons",
                                subtitle: "Go past the 6 free buttons: up to 64 one-tap shortcuts, OBS controls and app launchers per PC."
                            )
                            proFeatureRow(
                                icon: "web.camera.fill",
                                tint: .green,
                                title: "iPhone as a Webcam (Beta)",
                                subtitle: "Use your iPhone or iPad camera in Zoom, Teams, Discord, OBS and browsers on your PC."
                            )
                        }
                        .padding(18)
                        .liquidGlass(cornerRadius: 22, tint: .yellow)

                        if store.isProUnlocked {
                            Label("Orbit Pro is active on this Apple Account", systemImage: "checkmark.seal.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if let error = store.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        } else if let status = store.statusMessage {
                            Label(status, systemImage: "sparkles")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.yellow)
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 12) {
                            if !store.isProUnlocked {
                                Button {
                                    OrbitHaptics.press()
                                    Task { await store.purchase() }
                                } label: {
                                    if store.isPurchasing {
                                        HStack(spacing: 8) { ProgressView().tint(.black); Text("Purchasing…") }
                                    } else {
                                        Label(purchaseTitle, systemImage: "crown.fill")
                                    }
                                }
                                .buttonStyle(OrbitProminentButtonStyle(colors: [Color(red: 1.0, green: 0.86, blue: 0.36), Color(red: 0.96, green: 0.68, blue: 0.22)]))
                                .disabled(store.isPurchasing || store.product == nil)
                            }

                            Button {
                                Task { await store.restorePurchases() }
                            } label: {
                                Label("Restore Purchases", systemImage: "arrow.clockwise")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .disabled(store.isPurchasing)

                            Button("Privacy & Terms") {
                                showPrivacy = true
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrivacy) {
                OrbitPrivacyPolicyView()
            }
            .task {
                if store.product == nil { await store.loadProducts() }
            }
        }
        .orbitAppearance()
    }

    private var purchaseTitle: String {
        switch store.productState {
        case .loaded: return "Unlock Orbit Pro · \(store.displayPrice ?? "")"
        case .unavailable: return "Orbit Pro is unavailable right now"
        case .idle, .loading: return "Loading price…"
        }
    }

    private func proFeatureRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct OrbitPrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("100% Local Network & Zero Tracking") {
                    Label("No Third-Party Analytics or Ads", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Orbit communicates directly between your iPhone and your own Windows PC over your local network (LAN) using TLS 1.3 and SHA-256 certificate pinning. No telemetry, files, clipboard text, or personal data are ever uploaded to external servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .orbitRow()
                Section("Credentials & Keychain Security") {
                    Label("Encrypted iOS Keychain Storage", systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Pairing tokens are negotiated using SRP-6a (Secure Remote Password) and AES-GCM encryption, and are stored exclusively in your iPhone's hardware-backed Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .orbitRow()
                Section("Purchases & Family Sharing") {
                    Label("One-Time Non-Consumable Purchase", systemImage: "crown.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Orbit Pro is a one-time purchase processed by Apple via StoreKit 2. You can restore your purchase on any iPhone or iPad signed in to your Apple Account using Restore Purchases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .orbitRow()
                Section("Support & Open Source Companion") {
                    Link("GitHub Repository & Support", destination: URL(string: "https://github.com/AceDimi2005/Orbit")!)
                }
                .orbitRow()
            }
            .orbitListChrome()
            .navigationTitle("Privacy & Terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .orbitAppearance()
    }
}

// MARK: - Live Activity settings

struct LiveActivitySettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @AppStorage("orbit.activity.style") private var style = "standard"
    @AppStorage("orbit.activity.primaryMetric") private var primaryMetric = "automatic"
    @AppStorage("orbit.activity.accent") private var accent = "noir"
    @AppStorage("orbit.activity.interval") private var interval = 5
    @AppStorage("orbit.activity.showGame") private var showGame = true
    @AppStorage("orbit.activity.showTimestamp") private var showTimestamp = true
    @Environment(\.orbitTheme) private var theme

    private var activityTheme: OrbitTheme { OrbitTheme(rawValue: accent) ?? .noir }

    var body: some View {
        Form {
            Section {
                islandPreview
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Preview · example data")
            }

            Section {
                HStack(spacing: 14) {
                    ZStack {
                        OrbitRingGauge(progress: vm.isDynamicIslandActive ? 1 : 0, lineWidth: 4, tint: .mint)
                            .frame(width: 44, height: 44)
                        Image(systemName: vm.isDynamicIslandActive ? "capsule.portrait.tophalf.filled" : "pause.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(vm.isDynamicIslandActive ? .mint : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.isDynamicIslandActive ? "Active on Lock Screen & Island" : "Live Activity Inactive")
                            .font(.subheadline.weight(.semibold))
                        Text(vm.metrics.isOnline ? vm.selectedPCName : "Connect to a PC to start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        OrbitHaptics.press()
                        vm.toggleDynamicIsland()
                    } label: {
                        Text(vm.isDynamicIslandActive ? "Stop" : "Start")
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: vm.isDynamicIslandActive ? .red : .mint, cornerRadius: 20))
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                }
                .padding(.vertical, 4)

                if let error = vm.liveActivityError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            .orbitRow(tint: .mint)

            Section("Appearance & Metrics") {
                Picker("Layout Style", selection: $style) {
                    Text("Standard").tag("standard")
                    Text("Minimal").tag("minimal")
                    Text("Detailed").tag("detailed")
                }
                .pickerStyle(.segmented)

                Picker("Panel Focus", selection: $vm.dashboardConfiguration.activityFocus) {
                    ForEach(LiveActivityFocus.allCases) { Text($0.title).tag($0) }
                }

                Picker("Compact Island Badge", selection: $primaryMetric) {
                    Text("Auto (by Focus)").tag("automatic")
                    Text("CPU Load").tag("cpu")
                    Text("GPU Load").tag("gpu")
                    Text("RAM Usage").tag("ram")
                    Text("Game FPS").tag("fps")
                    Text("CPU Power").tag("cpuPower")
                    Text("GPU Power").tag("gpuPower")
                    Text("VRAM Used").tag("vram")
                }

                Picker("Theme Accent", selection: $accent) {
                    ForEach(OrbitProStore.shared.isProUnlocked ? OrbitTheme.allCases : OrbitTheme.freeThemes) { item in
                        HStack {
                            Circle().fill(item.accent).frame(width: 10, height: 10)
                            Text(item.title)
                        }
                        .tag(item.rawValue)
                    }
                }
                Button("Match App Theme (\(theme.title))") {
                    OrbitHaptics.selection()
                    accent = theme.rawValue
                }
                .font(.subheadline)
                .disabled(accent == theme.rawValue)
            }
            .orbitRow()

            Section("Details & Refresh") {
                Toggle("Show Active Game", isOn: $showGame)
                Toggle("Show Timestamp", isOn: $showTimestamp)
                Picker("Refresh Interval", selection: $interval) {
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                    Text("15s").tag(15)
                }
                .pickerStyle(.segmented)
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .orbitAppearance()
    }

    /// A static mock of the Dynamic Island so the chosen accent and badge are
    /// visible without starting an activity.
    private var islandPreview: some View {
        let tint = activityTheme.accent
        let badge: String = {
            switch primaryMetric {
            case "gpu": return "GPU 71%"
            case "ram": return "RAM 46%"
            case "fps": return "118 FPS"
            case "cpuPower": return "58 W"
            case "gpuPower": return "245 W"
            case "vram": return "4.0 GB"
            default: return "CPU 24%"
            }
        }()
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                Capsule().fill(.black).frame(width: 70, height: 22)
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

            HStack(spacing: 12) {
                OrbitRingGauge(progress: 0.24, lineWidth: 4, tint: tint).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Example PC")
                        .font(.subheadline.weight(.bold))
                    Text(showGame ? "Playing Example game · \(style.capitalized)" : "Monitoring · \(style.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showTimestamp {
                    Text("5s")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(activityTheme.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        }
        .padding(.horizontal, 2)
        .animation(.snappy, value: accent)
        .animation(.snappy, value: primaryMetric)
    }
}
