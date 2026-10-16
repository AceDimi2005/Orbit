import SwiftUI

enum OrbitVisualStyle: String, CaseIterable, Identifiable {
    case improved, classic
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String { self == .improved ? "Clear surfaces, stronger contrast and quieter details." : "The original translucent cards and ambient glow." }
}
enum OrbitTheme: String, CaseIterable, Identifiable {
    case ocean, aurora, violet, ember, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var accent: Color {
        switch self {
        case .ocean: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .aurora: Color(red: 0.45, green: 0.92, blue: 0.73)
        case .violet: Color(red: 0.76, green: 0.66, blue: 1)
        case .ember: Color(red: 1, green: 0.70, blue: 0.43)
        case .graphite: Color(red: 0.82, green: 0.88, blue: 0.97)
        }
    }
    var background: Color {
        switch self {
        case .ocean: Color(red: 0.025, green: 0.045, blue: 0.075)
        case .aurora: Color(red: 0.025, green: 0.055, blue: 0.045)
        case .violet: Color(red: 0.045, green: 0.03, blue: 0.075)
        case .ember: Color(red: 0.075, green: 0.04, blue: 0.025)
        case .graphite: Color(red: 0.04, green: 0.045, blue: 0.055)
        }
    }
    var surface: Color {
        switch self {
        case .ocean: Color(red: 0.075, green: 0.10, blue: 0.145)
        case .aurora: Color(red: 0.065, green: 0.115, blue: 0.095)
        case .violet: Color(red: 0.11, green: 0.085, blue: 0.16)
        case .ember: Color(red: 0.145, green: 0.09, blue: 0.065)
        case .graphite: Color(red: 0.095, green: 0.105, blue: 0.125)
        }
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
    var body: some View {
        Form {
            Section {
                Picker("Interface", selection: $style) {
                    ForEach(OrbitVisualStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(style.detail).font(.subheadline).foregroundStyle(.secondary)
            } header: { Text("Make Orbit yours") }
            Section("Colour theme") {
                ForEach(OrbitTheme.allCases) { item in
                    Button { theme = item } label: {
                        HStack(spacing: 13) {
                            Circle().fill(item.accent).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                            Text(item.title).foregroundStyle(.primary)
                            Spacer()
                            if theme == item { Image(systemName: "checkmark.circle.fill").foregroundStyle(item.accent) }
                        }.padding(.vertical, 5)
                    }.accessibilityAddTraits(theme == item ? .isSelected : [])
                }
            }
            Section("Readability") {
                Toggle("One accent for all metric cards", isOn: $monochromeMetrics)
                Toggle("Reduce background glow", isOn: $reduceGlow)
                Text("Orbit respects the text size and Reduce Motion settings on your iPhone. Larger accessibility text uses a single dashboard column.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                HardwareMetricCard(title: "Processor", subtitle: "Your detected CPU", valueText: "24%", progress: 0.24,
                                   icon: "cpu", accent: theme.accent, detail: "Example reading · 48°C")
                    .padding(.vertical, 8)
                    .listRowBackground(theme.background)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .orbitAppearance()
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
                Label(vm.isDynamicIslandActive ? "Live Activity is running" : "Live Activity is stopped", systemImage: vm.isDynamicIslandActive ? "waveform.path.ecg" : "pause.circle")
                    .foregroundStyle(vm.isDynamicIslandActive ? .mint : .secondary)
                Button { vm.toggleDynamicIsland() } label: {
                    Label(vm.isDynamicIslandActive ? "Stop Live Activity" : "Start Live Activity", systemImage: vm.isDynamicIslandActive ? "stop.circle" : "play.circle")
                }.disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                if let error = vm.liveActivityError { Text(error).font(.caption).foregroundStyle(.orange) }
            } header: { Text("Lock Screen & Dynamic Island") } footer: {
                Text("Start while connected to your PC. iOS chooses where it appears; Dynamic Island requires a compatible iPhone. Allow Live Activities for Orbit in iPhone Settings.")
            }
            Section("Layout") {
                Picker("Lock Screen style", selection: $style) {
                    Text("Standard").tag("standard")
                    Text("Minimal").tag("minimal")
                    Text("Detailed").tag("detailed")
                }
                Picker("Metric group", selection: $vm.dashboardConfiguration.activityFocus) {
                    ForEach(LiveActivityFocus.allCases) { Text($0.title).tag($0) }
                }
                Picker("Compact Island reading", selection: $primaryMetric) {
                    Text("Automatic").tag("automatic")
                    Text("CPU load").tag("cpu")
                    Text("GPU load").tag("gpu")
                    Text("RAM usage").tag("ram")
                    Text("Game FPS").tag("fps")
                    Text("CPU power").tag("cpuPower")
                    Text("GPU power").tag("gpuPower")
                    Text("VRAM used").tag("vram")
                }
                Picker("Accent", selection: $accent) {
                    ForEach(OrbitTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show game name", isOn: $showGame)
                Toggle("Show update time", isOn: $showTimestamp)
            }
            Section {
                Picker("Update interval", selection: $interval) {
                    Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("15 seconds").tag(15)
                }
                Text("Updates arrive while Orbit can run. Switching apps or locking the phone may pause monitoring; expired values are replaced with a refresh prompt. Changes apply on the next update.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Widget snapshots follow a separate schedule managed by iOS. They do not refresh every few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Freshness") }
        }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .orbitAppearance()
    }
}
