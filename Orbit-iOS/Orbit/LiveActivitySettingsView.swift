import SwiftUI

/// The Live Activity: on or off, what it shows, its color and how often it updates. The
/// preview is drawn by the same views as the Lock Screen and the Dynamic Island.
struct LiveActivitySettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    @AppStorage("orbit.activity.style") private var style = "standard"
    @AppStorage("orbit.activity.primaryMetric") private var primaryMetric = "automatic"
    @AppStorage("orbit.activity.accent") private var accent = "noir"
    @AppStorage("orbit.activity.interval") private var interval = 5
    @AppStorage("orbit.activity.showGame") private var showGame = true
    @AppStorage("orbit.activity.showTimestamp") private var showTimestamp = true
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var showsPro = false

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            } footer: {
                Text("A preview with sample readings.")
            }

            Section {
                Toggle("Show on Lock Screen", isOn: Binding(get: { vm.isDynamicIslandActive }, set: { _ in vm.toggleDynamicIsland() }))
                    .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)
                if let error = vm.liveActivityError {
                    OrbitInlineStatus(text: error, kind: .problem)
                }
            } footer: {
                Text(vm.metrics.isOnline || vm.isDynamicIslandActive
                     ? "It also appears in the Dynamic Island, in StandBy and on Apple Watch."
                     : "Connect to your PC to start it.")
            }

            Section {
                Picker("Style", selection: $style) {
                    Text("Minimal").tag("minimal")
                    Text("Standard").tag("standard")
                    Text("Detailed").tag("detailed")
                }
                Picker("Readings", selection: $vm.dashboardConfiguration.activityFocus) {
                    Text("Load and Memory").tag(LiveActivityFocus.overview)
                    Text("Frame Rate and Graphics").tag(LiveActivityFocus.gaming)
                    Text("Power Draw").tag(LiveActivityFocus.power)
                }
                Picker("Dynamic Island", selection: $primaryMetric) {
                    Text("Automatic").tag("automatic")
                    Text("Processor").tag("cpu")
                    Text("Graphics").tag("gpu")
                    Text("Memory").tag("ram")
                    Text("Frame Rate").tag("fps")
                    Text("CPU Power").tag("cpuPower")
                    Text("GPU Power").tag("gpuPower")
                    Text("Video Memory").tag("vram")
                }
            } header: {
                Text("What It Shows")
            } footer: {
                Text("Automatic shows the two temperatures, or the frame rate while you play.")
            }

            Section {
                accentSwatches
                if accent != theme.rawValue {
                    Button("Use the App's Accent Color") {
                        OrbitHaptics.selection()
                        if !theme.isPro || proStore.isProUnlocked { accent = theme.rawValue }
                    }
                }
            } header: {
                Text("Color")
            }

            Section {
                Toggle("Show the Game", isOn: $showGame)
                Toggle("Show When It Updated", isOn: $showTimestamp)
                Picker("Update Every", selection: $interval) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("15 s").tag(15)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Details")
            } footer: {
                Text("iOS updates the Live Activity while Orbit is open or refreshing in the background. When it can't, the activity says it's paused instead of showing old numbers.")
            }
        }
        .orbitListBackground()
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPro) { OrbitProPaywallView() }
    }

    // MARK: Preview

    private var sample: OrbitActivitySnapshot {
        let state = OrbitActivityAttributes.ContentState(
            cpuUsage: 23, gpuUsage: 71, ramUsage: 46, fps: 144, gameName: "Example game", isConnected: true,
            lastUpdated: Date(), vramUsedGB: 6.2, vramTotalGB: 12, cpuPowerWatts: 63, gpuPowerWatts: 210,
            focus: vm.dashboardConfiguration.activityFocus.rawValue, telemetryAvailable: true, style: style,
            primaryMetric: primaryMetric, accent: accent, showGame: showGame, showTimestamp: showTimestamp,
            updateInterval: interval, isPaused: false, cpuTemp: 52, gpuTemp: 65)
        return OrbitActivitySnapshot(pcName: vm.isConfigured ? vm.selectedPCName : "Your PC", state: state, isStale: false)
    }

    private var preview: some View {
        let snapshot = sample
        return VStack(spacing: 14) {
            HStack(spacing: 0) {
                OrbitActivityCompactLeading(snapshot: snapshot)
                    .frame(width: 66, alignment: .leading)
                Spacer(minLength: 104)
                OrbitActivityCompactTrailing(snapshot: snapshot)
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(width: 264, height: 37)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(OrbitPalette.hairline, lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Dynamic Island preview")

            OrbitActivityLockScreen(snapshot: snapshot)
                .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Lock Screen preview: \(snapshot.headline)")
        }
        .animation(OrbitMotion.standard, value: style)
        .animation(OrbitMotion.standard, value: accent)
        .animation(OrbitMotion.standard, value: primaryMetric)
    }

    // MARK: Color

    private var accentSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 12) {
            ForEach(OrbitTheme.allCases) { option in
                let locked = option.isPro && !proStore.isProUnlocked
                let selected = accent == option.rawValue
                Button {
                    if locked {
                        showsPro = true
                    } else {
                        OrbitHaptics.selection()
                        withAnimation(OrbitMotion.standard) { accent = option.rawValue }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(option.orbitTint)
                            .frame(width: 30, height: 30)
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 2.5)
                            .frame(width: 38, height: 38)
                            .opacity(selected ? 1 : 0)
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accentName + (locked ? ", Orbit Pro" : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
