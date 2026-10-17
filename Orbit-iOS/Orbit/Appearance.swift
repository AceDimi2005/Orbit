import StoreKit
import SwiftUI
import UIKit

enum OrbitVisualStyle: String, CaseIterable, Identifiable {
    case improved, classic
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String { self == .improved ? "Crisp surfaces with high contrast." : "Translucent glass cards with ambient glow." }
}

enum OrbitTheme: String, CaseIterable, Identifiable {
    // Free themes
    case ocean, aurora, violet, ember, graphite
    // Orbit Pro themes
    case cyberpunk, solarGold, crimson, matrix, arctic, sakura

    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .ocean, .aurora, .violet, .ember, .graphite: false
        case .cyberpunk, .solarGold, .crimson, .matrix, .arctic, .sakura: true
        }
    }

    static var freeThemes: [OrbitTheme] { allCases.filter { !$0.isPro } }
    static var proThemes: [OrbitTheme] { allCases.filter { $0.isPro } }

    var accent: Color {
        switch self {
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

@MainActor
final class OrbitProStore: ObservableObject {
    static let shared = OrbitProStore()
    static let productID = "com.dimitrie.orbit.pro"
    static let isComingSoon = true

    @Published private(set) var isProUnlocked: Bool = true
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?

    var displayPrice: String {
        if Self.isComingSoon { return "Coming Soon" }
        return product?.displayPrice ?? "25,00 lei"
    }

    private init() {
        isProUnlocked = true
    }

    func loadProducts() async {
        guard !Self.isComingSoon else { return }
        do {
            let fetched = try await Product.products(for: [Self.productID])
            product = fetched.first
        } catch {}
    }

    func refreshEntitlements() async {
        guard !Self.isComingSoon else { return }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                unlockPro()
                return
            }
        }
    }

    func purchase() async {
        if Self.isComingSoon {
            statusMessage = "All Pro features are unlocked for free right now! Paid version coming soon."
            return
        }
        guard !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        statusMessage = nil
        defer { isPurchasing = false }

        if product == nil {
            await loadProducts()
        }

        guard let product else {
            statusMessage = "Orbit Pro will be available in an upcoming update!"
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    unlockPro()
                    statusMessage = "Thank you! Orbit Pro is now permanently unlocked."
                    await transaction.finish()
                } else {
                    errorMessage = "Purchase could not be verified by the App Store."
                }
            case .pending:
                statusMessage = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        if Self.isComingSoon {
            statusMessage = "Orbit Pro purchases are coming soon in an upcoming update."
            return
        }
        guard !isPurchasing else { return }
        isPurchasing = true
        errorMessage = nil
        statusMessage = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isProUnlocked {
                statusMessage = "Orbit Pro restored successfully."
            } else {
                statusMessage = "No previous Orbit Pro purchase found for this Apple Account."
            }
        } catch {
            errorMessage = "Could not restore purchases: \(error.localizedDescription)"
        }
    }

    private func unlockPro() {
        isProUnlocked = true
        UserDefaults.standard.set(true, forKey: "orbit.pro.unlocked")
        NSUbiquitousKeyValueStore.default.set(true, forKey: "orbit.pro.unlocked")
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

struct OrbitAppearanceModifier: ViewModifier {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    func body(content: Content) -> some View {
        content.tint(theme.accent).preferredColorScheme(.dark)
            .environment(\.orbitAccent, theme.accent)
            .environment(\.orbitImprovedStyle, style == .improved)
    }
}
private struct OrbitAccentKey: EnvironmentKey { static let defaultValue = OrbitTheme.ocean.accent }
private struct OrbitImprovedKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var orbitAccent: Color { get { self[OrbitAccentKey.self] } set { self[OrbitAccentKey.self] = newValue } }
    var orbitImprovedStyle: Bool { get { self[OrbitImprovedKey.self] } set { self[OrbitImprovedKey.self] = newValue } }
}
extension View { func orbitAppearance() -> some View { modifier(OrbitAppearanceModifier()) } }

struct AppearanceSettingsView: View {
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    @AppStorage("orbit.style") private var style: OrbitVisualStyle = .improved
    @AppStorage("orbit.monochromeMetrics") private var monochromeMetrics = false
    @AppStorage("orbit.reduceGlow") private var reduceGlow = false
    @AppStorage("orbit.appIcon") private var selectedIcon: OrbitAppIcon = .classic
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showPaywall = false
    @State private var iconError: String?

    var body: some View {
        Form {
            Section {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.yellow.opacity(0.18))
                                .frame(width: 38, height: 38)
                            Image(systemName: "crown.fill")
                                .foregroundStyle(.yellow)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Orbit Pro · Coming Soon")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text("All Pro themes & icons are unlocked for free right now")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("SOON")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.yellow)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Surface Style") {
                Picker("Interface", selection: $style) {
                    ForEach(OrbitVisualStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(style.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Standard Themes") {
                HStack(spacing: 10) {
                    ForEach(OrbitTheme.freeThemes) { item in
                        themeSwatch(item)
                    }
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 12) {
                    ForEach(OrbitTheme.proThemes) { item in
                        themeSwatch(item)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("Orbit Pro Themes")
                    Spacer()
                    Label("Unlocked for Testing", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.mint)
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 10)], spacing: 10) {
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
                HStack {
                    Text("Home Screen App Icon")
                    Spacer()
                    Label("Unlocked for Testing", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.mint)
                }
            }

            Section("Display Options") {
                Toggle("Single Accent Color", isOn: $monochromeMetrics)
                Toggle("Subtle Background Glow", isOn: Binding(get: { !reduceGlow }, set: { reduceGlow = !$0 }))
            }

            Section("Card Preview") {
                HardwareMetricCard(
                    title: "Processor",
                    subtitle: "AMD Ryzen 7 · 48°C",
                    valueText: "24%",
                    progress: 0.24,
                    icon: "cpu",
                    accent: theme.accent,
                    detail: "4.85 GHz"
                )
                .padding(.vertical, 4)
                .listRowBackground(theme.background)
            }
        }
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

    private func themeSwatch(_ item: OrbitTheme) -> some View {
        let locked = item.isPro && !proStore.isProUnlocked
        return Button {
            if locked {
                showPaywall = true
            } else {
                withAnimation(.snappy) { theme = item }
                NSUbiquitousKeyValueStore.default.set(item.rawValue, forKey: "orbit.theme")
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(item.accent.gradient)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .strokeBorder(theme == item ? .white : .white.opacity(0.18), lineWidth: theme == item ? 2.5 : 1)
                        )
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3.5)
                            .background(Color.yellow, in: Circle())
                            .offset(x: 4, y: -3)
                    }
                }
                Text(item.title)
                    .font(.caption2.weight(theme == item ? .bold : .medium))
                    .foregroundStyle(theme == item ? .white : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(theme == item ? .isSelected : [])
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
                                .frame(width: 76, height: 76)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.yellow, Color(red: 1.0, green: 0.72, blue: 0.25)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .padding(.top, 8)

                        Text("Orbit Pro")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Coming Soon · Exclusive themes, icons & advanced packs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        proFeatureRow(
                            icon: "paintpalette.fill",
                            tint: Color(red: 1.0, green: 0.22, blue: 0.70),
                            title: "6 Exclusive Luxury Themes",
                            subtitle: "Cyberpunk, Solar Gold, Crimson, Matrix, Arctic, and Sakura across app & widgets."
                        )
                        proFeatureRow(
                            icon: "app.badge.sparkles",
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
                    }
                    .padding(18)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )

                    if let status = store.statusMessage {
                        Label(status, systemImage: "sparkles")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.badge.sparkles.fill")
                                Text("Orbit Pro — Coming Soon")
                                    .font(.headline.weight(.bold))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.86, blue: 0.36), Color(red: 0.96, green: 0.68, blue: 0.22)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }

                        Button("Privacy & Terms") {
                            showPrivacy = true
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.03, green: 0.045, blue: 0.075).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrivacy) {
                OrbitPrivacyPolicyView()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func proFeatureRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
            }
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
                Section("Credentials & Keychain Security") {
                    Label("Encrypted iOS Keychain Storage", systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Pairing tokens are negotiated using SRP-6a (Secure Remote Password) and AES-GCM encryption, and are stored exclusively in your iPhone's hardware-backed Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Purchases & Family Sharing") {
                    Label("One-Time Non-Consumable Purchase", systemImage: "crown.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Orbit Pro is a one-time purchase processed by Apple via StoreKit 2. You can restore your purchase on any iPhone or iPad signed in to your Apple Account using Restore Purchases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Support & Open Source Companion") {
                    Link("GitHub Repository & Support", destination: URL(string: "https://github.com/AceDimi2005/Orbit")!)
                }
            }
            .navigationTitle("Privacy & Terms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct LiveActivitySettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @AppStorage("orbit.activity.style") private var style = "standard"
    @AppStorage("orbit.activity.primaryMetric") private var primaryMetric = "automatic"
    @AppStorage("orbit.activity.accent") private var accent = "ocean"
    @AppStorage("orbit.activity.interval") private var interval = 5
    @AppStorage("orbit.activity.showGame") private var showGame = true
    @AppStorage("orbit.activity.showTimestamp") private var showTimestamp = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill((vm.isDynamicIslandActive ? Color.mint : Color.secondary).opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: vm.isDynamicIslandActive ? "capsule.portrait.tophalf.filled" : "pause.circle")
                            .font(.system(size: 18, weight: .semibold))
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
                        vm.toggleDynamicIsland()
                    } label: {
                        Text(vm.isDynamicIslandActive ? "Stop" : "Start")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background((vm.isDynamicIslandActive ? Color.red : Color.mint).opacity(0.2), in: Capsule())
                            .foregroundStyle(vm.isDynamicIslandActive ? .red : .mint)
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                }
                .padding(.vertical, 4)

                if let error = vm.liveActivityError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

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
                    ForEach(OrbitTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }

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
        }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .orbitAppearance()
    }
}
