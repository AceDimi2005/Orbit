import MoonlightCore
import SwiftUI

struct CompanionToolsView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    @ObservedObject private var watchBridge = OrbitWatchBridge.shared
    @State private var showsSettings = false
    @State private var showsDiscovery = false
    @State private var showsProPaywall = false
    @State private var showsStreamSettings = false
    @ObservedObject private var streamSettings = MoonlightStreamSettingsStore.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 165, maximum: 340), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        pcSwitcherCard

                        OrbitSectionHeader("PC Control", icon: "slider.horizontal.3")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink { ClipboardView(vm: vm) } label: {
                                toolTile("Clipboard", subtitle: "Sync text & links", icon: "doc.on.clipboard.fill", tint: .cyan)
                            }
                            NavigationLink { AudioMixerView(vm: vm) } label: {
                                toolTile("Audio Mixer", subtitle: "Per-app volume & routing", icon: "slider.vertical.3", tint: .purple)
                            }
                            NavigationLink { TaskManagerView(vm: vm) } label: {
                                toolTile("Task Manager", subtitle: "Processes & end task", icon: "list.bullet.rectangle.portrait.fill", tint: .orange)
                            }
                            Button {
                                showsStreamSettings = true
                            } label: {
                                toolTile("Stream Settings", subtitle: "Resolution, bitrate, codec & HDR", icon: "play.rectangle.fill", tint: theme.accent)
                            }
                        }

                        OrbitSectionHeader("Diagnostics & History", icon: "waveform.path.ecg")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink {
                                OrbitProGate(title: "Session Graphs", message: "Recorded sessions with FPS, temperature and power history are part of Orbit Pro.") {
                                    SessionHistoryView(vm: vm)
                                }
                            } label: {
                                toolTile("Session Graphs", subtitle: "History, averages & peaks", icon: "chart.xyaxis.line", tint: .mint)
                            }
                            NavigationLink { FullSpecsView(vm: vm) } label: {
                                toolTile("Hardware Specs", subtitle: "Detected components", icon: "cpu.fill", tint: .indigo)
                            }
                            NavigationLink { MonitoringSourcesView(vm: vm) } label: {
                                toolTile("Sensor Status", subtitle: sensorSubtitle, icon: "sensor.tag.radiowaves.forward.fill", tint: .teal)
                            }
                            NavigationLink { PCProfilesView(vm: vm) } label: {
                                toolTile("My PCs", subtitle: "\(vm.savedPCs.count) saved connection\(vm.savedPCs.count == 1 ? "" : "s")", icon: "desktopcomputer", tint: theme.accent)
                            }
                        }

                        OrbitSectionHeader("Apple Ecosystem", icon: "sparkles")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink { AppleWatchCompanionHelpView(vm: vm) } label: {
                                toolTile("Apple Watch", subtitle: watchSubtitle, icon: "applewatch.radiowaves.left.and.right", tint: .green)
                            }
                            NavigationLink { LiveActivitySettingsView(vm: vm) } label: {
                                toolTile(
                                    "Live Activity",
                                    subtitle: vm.isDynamicIslandActive ? "Running on Island" : "Island & Lock Screen",
                                    icon: "capsule.portrait.tophalf.filled",
                                    tint: vm.isDynamicIslandActive ? .mint : .pink,
                                    badge: vm.isDynamicIslandActive ? "LIVE" : nil
                                )
                            }
                            NavigationLink { WidgetHelpView(vm: vm) } label: {
                                toolTile("Widgets & Siri", subtitle: "Home & Control Center", icon: "square.grid.2x2.fill", tint: .yellow)
                            }
                            NavigationLink { AppearanceSettingsView() } label: {
                                toolTile("Themes & Icons", subtitle: "\(theme.title) · App Icons", icon: "paintpalette.fill", tint: theme.accent)
                            }
                            Button {
                                showsSettings = true
                            } label: {
                                toolTile("Settings", subtitle: "Network, Wake-on-LAN & updates", icon: "gearshape.fill", tint: .gray)
                            }
                        }
                    }
                    .frame(maxWidth: 1380)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.orbitPressable)
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            vm.toggleDynamicIsland()
                        } label: {
                            Label(
                                vm.isDynamicIslandActive ? "Stop Live Activity" : "Start Live Activity",
                                systemImage: vm.isDynamicIslandActive ? "stop.circle" : "capsule.portrait.tophalf.filled"
                            )
                        }
                        .disabled(!vm.isDynamicIslandActive && !vm.metrics.isOnline)

                        Button {
                            showsDiscovery = true
                        } label: {
                            Label("Pair New PC…", systemImage: "dot.radiowaves.left.and.right")
                        }

                        if !vm.savedPCs.isEmpty {
                            Menu("Switch PC") {
                                ForEach(vm.savedPCs) { pc in
                                    Button {
                                        vm.selectPC(pc)
                                    } label: {
                                        Label(pc.name, systemImage: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            showsProPaywall = true
                        } label: {
                            Label("Orbit Pro", systemImage: "crown.fill")
                        }

                        Button {
                            showsSettings = true
                        } label: {
                            Label("Settings…", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Quick Actions Menu")
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView(vm: vm, isPresentedAsSheet: true) }
            .sheet(isPresented: $showsDiscovery) { PCDiscoveryView(vm: vm) }
            .sheet(isPresented: $showsProPaywall) { OrbitProPaywallView() }
            .sheet(isPresented: $showsStreamSettings) {
                // Sized for the selected PC's codecs, as the library's sheet and the streams it starts are.
                MoonlightStreamSettingsView(store: streamSettings, accent: theme.accent,
                                            hostSupportsHEVC: MoonlightHostStore.record(for: vm.selectedPCID)?.supportsHEVC) { showsStreamSettings = false }
                    .presentationBackground(theme.background)
            }
        }
        .orbitAppearance()
    }

    private var sensorSubtitle: String {
        if vm.isDemoMode { return "Simulated preview" }
        guard vm.metrics.isOnline else { return "Telemetry sources" }
        return vm.metrics.sensorSource ?? "Telemetry sources"
    }

    private var watchSubtitle: String {
        if watchBridge.isWatchReachable { return "Connected · live relay" }
        if watchBridge.isWatchPaired { return "Paired · Air Mouse & Smart Stack" }
        return "Air Mouse & Smart Stack"
    }

    private var orbitProCard: some View {
        Button {
            showsProPaywall = true
        } label: {
            HStack(spacing: 13) {
                OrbitIconBadge(systemName: "crown.fill", tint: .yellow, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit Pro")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(proStore.isProUnlocked ? "Unlocked on all your devices" : "Themes, icons, power widgets, unlimited PCs & graphs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(proStore.isProUnlocked ? "ACTIVE" : (proStore.displayPrice ?? "PRO"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.2), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            .padding(14)
            .liquidGlass(cornerRadius: 20, tint: .yellow)
        }
    }

    private var pcSwitcherCard: some View {
        HStack(spacing: 14) {
            ZStack {
                OrbitRingGauge(progress: vm.metrics.isOnline && vm.metrics.telemetryAvailable != false ? vm.metrics.cpuUsage / 100 : nil, lineWidth: 4, tint: theme.accent)
                    .frame(width: 48, height: 48)
                OrbitMark(size: 30)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.isDemoMode ? "Demo Mode" : vm.selectedPCName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    OrbitStatusPill(
                        text: vm.metrics.isOnline ? (vm.hasSecureConnection ? "Encrypted" : "Connected") : "Offline",
                        tint: vm.metrics.isOnline ? .mint : .orange,
                        pulsing: vm.metrics.isOnline && !vm.isDemoMode,
                        icon: vm.metrics.isOnline && vm.hasSecureConnection ? "lock.fill" : nil
                    )
                    if vm.metrics.isOnline && !vm.isDemoMode {
                        OrbitStatChip(label: "Ping", value: "\(vm.pingMs) ms")
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(vm.savedPCs) { pc in
                    Button {
                        vm.selectPC(pc)
                    } label: {
                        Label(pc.name, systemImage: vm.selectedPCID == pc.id ? "checkmark.circle.fill" : "desktopcomputer")
                    }
                }
                Divider()
                Button {
                    showsDiscovery = true
                } label: {
                    Label("Find a PC…", systemImage: "plus.circle")
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Switch")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(theme.accent.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.25), lineWidth: 1))
                .foregroundStyle(theme.accent)
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 20, tint: theme.accent, elevated: true)
    }

    private func toolTile(_ title: String, subtitle: String, icon: String, tint: Color, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrbitIconBadge(systemName: icon, tint: tint, size: 38)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: tint)
    }
}

struct AppleWatchCompanionHelpView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var watchBridge = OrbitWatchBridge.shared
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    var body: some View {
        ZStack {
            OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard

                    featureCard(
                        title: "Wrist Motion Air Mouse (Gyro Cursor)",
                        subtitle: "Move the PC cursor with your wrist",
                        icon: "gyroscope",
                        tint: .cyan,
                        points: [
                            "Open Orbit on Apple Watch and swipe to the Air Mouse page.",
                            "Tap Start Gyro and tilt or rotate your wrist to move the Windows cursor in real time.",
                            "Switch between Gyro Glide (velocity) and Laser Pointer (calibrated screen mapping) modes.",
                            "Turn the Digital Crown to scroll, and tap Left, Right, Double, or Drag Hold."
                        ]
                    )

                    featureCard(
                        title: "Power On, Shut Down & Quick Actions",
                        subtitle: "Full PC power & desktop shortcuts on your wrist",
                        icon: "power.circle.fill",
                        tint: .green,
                        points: [
                            "Power On (Wake-on-LAN) works both directly over Watch Wi-Fi and through your iPhone.",
                            "Trigger Shut Down, Sleep, Restart, or Lock Workstation with confirmation and wrist haptics.",
                            "Use Desktop Shortcuts on your wrist: Show Desktop, Task View, Alt+Tab, Screenshot, and Toggle HDR."
                        ]
                    )

                    featureCard(
                        title: "Live Activities & Watch Face Complications",
                        subtitle: "Smart Stack & Watch Face gauges",
                        icon: "applewatch.watchface",
                        tint: .purple,
                        points: [
                            "When you start an Orbit Live Activity on iPhone, it automatically appears in your Apple Watch Smart Stack with live CPU/GPU/FPS metrics and Power On / Shut Down buttons.",
                            "Add Orbit Complications (Circular, Corner, Rectangular, Inline) to any Watch Face to see live telemetry or wake your PC with one tap.",
                            "The Watch follows your iPhone theme (\(theme.title)) automatically."
                        ]
                    )
                }
                .frame(maxWidth: 900)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Apple Watch")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: "applewatch.radiowaves.left.and.right", tint: .green, size: 46, filled: watchBridge.isWatchReachable)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orbit for Apple Watch")
                        .font(.headline.weight(.bold))
                    HStack(spacing: 6) {
                        OrbitStatusPill(text: watchStatusTitle, tint: watchBridge.isWatchReachable ? .mint : (watchBridge.isWatchPaired ? .green : .secondary), pulsing: watchBridge.isWatchReachable)
                        if watchBridge.isWatchAppInstalled {
                            OrbitStatChip(label: "App", value: "Installed")
                        }
                    }
                }
                Spacer()
                Button {
                    OrbitHaptics.tap()
                    watchBridge.pushStateToWatch(force: true)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(OrbitGlassButtonStyle(tint: theme.accent, cornerRadius: 20))
            }
            Text(watchStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastSync = watchBridge.lastWatchSync {
                Text("Last synced \(lastSync.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 20, tint: .green, elevated: true)
    }

    private var watchStatusTitle: String {
        if watchBridge.isWatchReachable { return "Reachable" }
        if watchBridge.isWatchPaired { return "Paired" }
        return "Not paired"
    }

    private var watchStatusText: String {
        if !watchBridge.isWatchSupported {
            return "WatchConnectivity ready · automatic LAN & Bluetooth sync"
        }
        if watchBridge.isWatchReachable {
            return "Connected & reachable · telemetry, games and PC profiles are relayed live."
        }
        if watchBridge.isWatchPaired {
            return "Apple Watch paired · background context synced; open Orbit on the Watch for live relay."
        }
        return "Pair an Apple Watch with this iPhone to use Air Mouse, power controls and complications."
    }

    private func featureCard(title: String, subtitle: String, icon: String, tint: Color, points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: icon, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(tint)
                            .frame(width: 18, height: 18)
                            .background(tint.opacity(0.14), in: Circle())
                        Text(point)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, tint: tint)
    }
}
