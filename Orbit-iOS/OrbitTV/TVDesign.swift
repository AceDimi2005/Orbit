import SwiftUI

// Apple TV pieces built on the shared Orbit design system (Shared/Design). Content sits on
// solid surfaces, controls use system glass, and the tvOS focus effect is the only highlight.

// MARK: - Layout

/// Spacing inside the TV safe area. The system already keeps content 80 pt from the sides and
/// 60 pt from the top and bottom; focused items grow, so neighbours leave room for the lift.
enum TVMetrics {
    static let sectionSpacing: CGFloat = 72
    static let titleSpacing: CGFloat = 26
    static let gridSpacing: CGFloat = 44
    static let tileRadius: CGFloat = 30
    static let rowRadius: CGFloat = 26
    static let surfacePadding: CGFloat = 40
    /// Width of the left column on two-column pages (Settings, sheets).
    static let sideColumn: CGFloat = 600
}

// MARK: - Accent

/// The accent picked in Orbit on iPhone, which syncs through iCloud as `orbit.theme`. The
/// colors match `OrbitTheme.orbitTint`; Pro accents fall back to Orbit Blue without Orbit Pro.
enum TVAccent {
    static let themeKey = "orbit.theme"

    private static let tints: [String: Color] = [
        "noir": OrbitPalette.accent,
        "ocean": Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255),
        "aurora": Color(red: 102 / 255, green: 212 / 255, blue: 207 / 255),
        "violet": Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255),
        "ember": OrbitPalette.warm,
        "graphite": Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255),
        "cyberpunk": Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255),
        "solarGold": Color(red: 230 / 255, green: 184 / 255, blue: 76 / 255),
        "crimson": OrbitPalette.critical,
        "matrix": OrbitPalette.online,
        "arctic": Color(red: 154 / 255, green: 216 / 255, blue: 255 / 255),
        "sakura": Color(red: 255 / 255, green: 143 / 255, blue: 183 / 255)
    ]
    private static let proThemes: Set<String> = ["cyberpunk", "solarGold", "crimson", "matrix", "arctic", "sakura"]

    @MainActor
    static var current: Color {
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: themeKey) ?? UserDefaults.standard.string(forKey: themeKey)
        guard let raw, let tint = tints[raw] else { return OrbitPalette.accent }
        if proThemes.contains(raw), !OrbitProStore.shared.isProUnlocked { return OrbitPalette.accent }
        return tint
    }
}

private struct TVAccentKey: EnvironmentKey {
    static let defaultValue: Color = OrbitPalette.accent
}

extension EnvironmentValues {
    /// The accent as a concrete color, for APIs that take one (stream screen, charts).
    var tvAccent: Color {
        get { self[TVAccentKey.self] }
        set { self[TVAccentKey.self] = newValue }
    }
}

// MARK: - Toast

/// A short confirmation for actions that change nothing on the TV itself ("Screenshot saved
/// on the PC") and for failures. Shown by the root view at the bottom of the screen.
struct TVToastAction {
    var show: (String) -> Void
    func callAsFunction(_ text: String) { show(text) }
}

private struct TVToastKey: EnvironmentKey {
    static let defaultValue = TVToastAction { _ in }
}

extension EnvironmentValues {
    var tvToast: TVToastAction {
        get { self[TVToastKey.self] }
        set { self[TVToastKey.self] = newValue }
    }
}

// MARK: - Text

/// A section title in Title Case with an optional quiet trailing note.
struct TVSectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
            trailing()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension TVSectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// List buttons would otherwise draw their label in the app's accent color; rows read as
/// plain white text like the tvOS Settings app, dimmed when the row is unavailable.
private struct TVRowLabelModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? Color.primary : Color.secondary)
    }
}

extension View {
    func tvRowLabel() -> some View { modifier(TVRowLabelModifier()) }
}

/// A list section header in Title Case (tvOS capitalizes list headers unless told not to).
struct TVListHeader: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(nil)
    }
}

// MARK: - Controls

extension View {
    /// Debug builds only: `-OrbitFocus <id>` focuses this control, for simulator screenshots
    /// of focus states. Release builds compile it away.
    @ViewBuilder
    func tvDebugFocus(_ id: String) -> some View {
        #if DEBUG
        modifier(TVDebugFocusModifier(id: id))
        #else
        self
        #endif
    }

    /// Debug builds only: `-OrbitScrollToEnd YES` starts a scroll view at its end, for
    /// simulator screenshots of what sits below the fold.
    @ViewBuilder
    func tvDebugScrollAnchor() -> some View {
        #if DEBUG
        if TVDebugLaunch.scrollToEnd { defaultScrollAnchor(.bottom) } else { self }
        #else
        self
        #endif
    }

    /// System glass buttons. The accent fills the one primary action on a screen; every other
    /// button stays monochrome so the accent keeps its meaning.
    @ViewBuilder
    func tvButton(prominent: Bool = false) -> some View {
        if prominent {
            orbitGlassButton(prominent: true)
        } else {
            orbitGlassButton().tint(nil)
        }
    }
}

/// A round glass button that only shows a symbol; the title is its VoiceOver label.
struct TVIconButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
        }
        .tvButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
    }
}

/// A Windows app icon; while it loads, and for apps without one, the name's first letter on
/// a quiet tile (or a symbol, for Windows' own sounds).
struct TVAppIcon: View {
    @ObservedObject var store: OrbitAppIconStore
    var iconID: String?
    var name: String
    var size: CGFloat
    var dimmed = false
    var symbol: String? = nil

    var body: some View {
        OrbitAppIconView(store: store, iconID: iconID, size: size, dimmed: dimmed) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .medium))
                } else {
                    Text(monogram)
                        .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(OrbitPalette.well, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .opacity(dimmed ? 0.6 : 1)
            .accessibilityHidden(true)
        }
    }

    private var monogram: String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

// MARK: - Pages

extension View {
    /// A page presented with `fullScreenCover`: it fills the screen on the solid canvas, inside
    /// the TV safe area. (tvOS 26 sheets are floating glass cards, so they are kept for short
    /// choices only.) The Menu button on the remote goes back.
    func tvFullScreenPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OrbitPalette.canvas.ignoresSafeArea())
    }
}

/// The tvOS two-column page: a picture and a few words on the left, the list on the right.
struct TVSplitPage<Side: View, Content: View>: View {
    @ViewBuilder var side: () -> Side
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 90) {
            VStack(alignment: .center, spacing: 28) {
                side()
            }
            .multilineTextAlignment(.center)
            .frame(width: TVMetrics.sideColumn)
            .frame(maxHeight: .infinity)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - PC state

/// What a screen should show for the current PC.
enum TVPCState: Equatable {
    case setup, demo, connecting, waking, online, locked, offline

    @MainActor
    init(vm: OrbitTVViewModel) {
        if !vm.isDemoMode && vm.currentPC == nil {
            self = .setup
        } else if vm.metrics.isOnline {
            if vm.metrics.sessionLocked == true { self = .locked } else { self = vm.isDemoMode ? .demo : .online }
        } else if vm.isWaking || vm.isBooting {
            self = .waking
        } else if vm.isDemoMode || vm.lastConnectionFailed {
            self = .offline
        } else {
            self = .connecting
        }
    }

    /// The PC answers and its readings and controls can be shown.
    var isReachable: Bool { self == .online || self == .demo || self == .locked }

    var markStatus: OrbitMark.Status {
        switch self {
        case .online, .demo: return .online
        case .locked: return .locked
        case .connecting, .waking: return .working
        case .offline: return .offline
        case .setup: return .plain
        }
    }
}

/// Power actions that change the PC's state, with the words used to confirm them.
enum TVPowerAction: String, Identifiable {
    case sleep, restart, shutdown

    var id: String { rawValue }

    func question(pcName: String) -> String {
        switch self {
        case .sleep: return "Put \(pcName) to sleep?"
        case .restart: return "Restart \(pcName)?"
        case .shutdown: return "Shut down \(pcName)?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutdown: return "Shut Down"
        }
    }

    var explanation: String {
        switch self {
        case .sleep: return "You can wake it again from Orbit."
        case .restart, .shutdown: return "Unsaved work in open apps on the PC may be lost."
        }
    }
}

// MARK: - Model helpers

extension TVPCMetrics: OrbitTelemetry {}

extension OrbitTVViewModel {
    /// The PC's name as the person saved it, or what the PC reports.
    var pcName: String {
        if isDemoMode { return metrics.hostname }
        return currentPC?.name ?? metrics.hostname
    }

    /// Orbit has the PC's network card address, so Wake-on-LAN can reach it.
    var canWake: Bool { isDemoMode || !(currentPC?.macAddress ?? "").isEmpty }

    /// A wake-up signal went out recently and the PC has not answered yet.
    var isBooting: Bool {
        guard let sent = wakeSentAt else { return false }
        return Date().timeIntervalSince(sent) < 90
    }

    /// Sunshine is installed but not running, and Orbit Companion can start it (agent 4.3+).
    var canStartSunshine: Bool {
        guard let info = sunshineInfo else { return false }
        return info.installed && !info.running && info.canStart == true
    }

    /// Asks Orbit Companion to start Sunshine on the PC, then reads the library again.
    func startSunshineOnPC(refreshing host: MoonlightHostCoordinator) async throws {
        try await MoonlightPairingAutomation(canSubmitPIN: false, canStartSunshine: true, sunshineRunning: false,
                                             client: { try self.client() }).startSunshine()
        try? await Task.sleep(for: .seconds(4))
        await refreshGames()
        await host.refresh()
    }

    /// The reason the last PC action failed, in the PC's own words.
    var lastActionError: String {
        let prefix = "Action failed: "
        return statusBanner.hasPrefix(prefix) ? String(statusBanner.dropFirst(prefix.count)) : statusBanner
    }

    func vital(_ kind: OrbitVitalKind) -> OrbitVital {
        OrbitVital(kind, metrics: metrics, history: history(for: kind))
    }

    func history(for kind: OrbitVitalKind) -> [Double] {
        switch kind {
        case .cpuLoad: return cpuHistory
        case .gpuLoad: return gpuHistory
        case .fps: return fpsHistory
        default: return []
        }
    }

    /// Up to eight readings for the PC tab, in the order people look for them, leaving out
    /// anything this PC does not report. Temperatures, clocks and power appear in the details.
    var tvVitals: [OrbitVitalKind] {
        var kinds: [OrbitVitalKind] = [.cpuLoad, .gpuLoad, .memory, .fps, .vram, .storage, .network, .diskActivity]
        if !vital(.gpuLoad).hasData { kinds.insert(.gpuTemperature, at: 2) }
        kinds += [.cpuPower, .gpuPower, .coolantTemperature]
        return Array(kinds.filter { vital($0).hasData }.prefix(8))
    }
}

/// Short numbers for process rows.
enum TVFormat {
    static func percent(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        if value > 0, value < 10 { return value.formatted(.number.precision(.fractionLength(1))) + "%" }
        return "\(Int(value.rounded()))%"
    }

    static func memory(megabytes: Double?) -> String? {
        guard let value = megabytes, value.isFinite, value >= 0 else { return nil }
        if value >= 1024 { return (value / 1024).formatted(.number.precision(.fractionLength(1))) + " GB" }
        return "\(Int(value.rounded())) MB"
    }

    /// "Cyberpunk2077.exe" → "Cyberpunk2077": the extension adds nothing from the couch.
    static func processName(_ name: String) -> String {
        name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }
}
