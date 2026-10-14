import SwiftUI

struct ContentView: View {
    @StateObject private var vm = OrbitViewModel()

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                DashboardView(vm: vm)
                    .tabItem {
                        Label("Dashboard", systemImage: "cpu.fill")
                    }

                GameLibraryView(vm: vm)
                    .tabItem {
                        Label("Sunshine", systemImage: "gamecontroller.fill")
                    }

                QuickRemoteView(vm: vm)
                    .tabItem {
                        Label("Remote", systemImage: "hand.point.up.braille.fill")
                    }

                WidgetsAndIslandPreviewView(vm: vm)
                    .tabItem {
                        Label("Widgets", systemImage: "rectangle.3.group.fill")
                    }

                SettingsView(vm: vm)
                    .tabItem {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
            }
            .tint(.cyan)
            .preferredColorScheme(.dark)

            if vm.isDynamicIslandActive {
                DynamicIslandLiveBar(vm: vm)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
            }

            if vm.smartLaunchStep != .idle {
                SmartLaunchOverlay(vm: vm)
                    .transition(.opacity.combined(with: .scale))
                    .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: $vm.isShowingStreamView) {
            MoonlightStreamView(vm: vm)
        }
        .sheet(isPresented: $vm.isShowingIPConfigSheet) {
            SettingsView(vm: vm)
        }
    }
}

// MARK: - 1. DASHBOARD VIEW

struct DashboardView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        headerCard

                        if vm.metrics.isOnline {
                            onlineDashboardContent
                        } else {
                            wakeOnLanHeroButton
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 32 : 18)
                    .padding(.top, vm.isDynamicIslandActive ? 54 : 16)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await vm.refreshMetrics()
                }
            }
            .navigationTitle("Orbit Control")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        vm.toggleDynamicIsland()
                    } label: {
                        Label(vm.isDynamicIslandActive ? "Island ON" : "Pin to Island", systemImage: "capsule.portrait.tophalf.filled")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(vm.isDynamicIslandActive ? .cyan : .white)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.metrics.isOnline ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(vm.isDemoMode ? "DEMO" : "LAN • \(vm.pingMs)ms")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlass(cornerRadius: 14)
                }
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(vm.metrics.isOnline ? Color.cyan.opacity(0.2) : Color.gray.opacity(0.15))
                    .frame(width: 64, height: 64)

                Image(systemName: vm.metrics.isOnline ? "desktopcomputer" : "power.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(vm.metrics.isOnline ? .cyan : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(vm.metrics.hostname)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    Text(vm.metrics.isOnline ? "ONLINE" : "OFFLINE")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (vm.metrics.isOnline ? Color.green : Color.red).opacity(0.22),
                            in: Capsule()
                        )
                        .foregroundStyle(vm.metrics.isOnline ? .green : .red)
                }

                Text(vm.statusLog)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)

                if let activeGame = vm.metrics.activeGame, vm.metrics.isOnline {
                    Label("Playing: \(activeGame)", systemImage: "gamecontroller.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }

            Spacer()

            if vm.metrics.isOnline {
                Button {
                    if let desktop = vm.games.last {
                        Task { await vm.smartLaunch(game: desktop) }
                    }
                } label: {
                    Label("Stream", systemImage: "play.tv.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.cyan, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
        .padding(20)
        .liquidGlass(cornerRadius: 26, tint: vm.metrics.isOnline ? .cyan : .gray)
    }

    private var onlineDashboardContent: some View {
        VStack(spacing: 22) {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                HardwareMetricCard(
                    title: vm.metrics.cpuName,
                    subtitle: "Load: \(Int(vm.metrics.cpuUsage))% • CCD0 V-Cache",
                    valueText: "\(Int(vm.metrics.cpuTemp))°C",
                    progress: vm.metrics.cpuTemp / 100.0,
                    icon: "cpu.fill",
                    accent: vm.metrics.cpuTemp > 78 ? .orange : .cyan
                )

                HardwareMetricCard(
                    title: vm.metrics.gpuName,
                    subtitle: "Load: \(Int(vm.metrics.gpuUsage))% • \(Int(vm.metrics.gpuPowerWatts))W",
                    valueText: "\(Int(vm.metrics.gpuTemp))°C",
                    progress: vm.metrics.gpuTemp / 100.0,
                    icon: "fanblades.fill",
                    accent: .mint
                )

                HardwareMetricCard(
                    title: "64GB DDR5 RAM",
                    subtitle: "VRAM: \(String(format: "%.1f", vm.metrics.vramUsedGB))/\(Int(vm.metrics.vramTotalGB)) GB",
                    valueText: String(format: "%.1f GB", vm.metrics.ramUsedGB),
                    progress: vm.metrics.ramUsedGB / max(1, vm.metrics.ramTotalGB),
                    icon: "memorychip.fill",
                    accent: .purple
                )

                HardwareMetricCard(
                    title: vm.metrics.coolerName,
                    subtitle: "Lian Li TL LCD • Coolant",
                    valueText: String(format: "%.1f°C", vm.metrics.liquidTemp),
                    progress: vm.metrics.liquidTemp / 60.0,
                    icon: "drop.fill",
                    accent: .blue
                )

                HardwareMetricCard(
                    title: "Samsung 9100 Pro",
                    subtitle: "PCIe 5.0 NVMe • \(String(format: "%.1f", vm.metrics.ssdTotalTB)) TB",
                    valueText: String(format: "%.2f TB", vm.metrics.ssdUsedTB),
                    progress: vm.metrics.ssdUsedTB / max(0.1, vm.metrics.ssdTotalTB),
                    icon: "internaldrive.fill",
                    accent: .indigo
                )

                HardwareMetricCard(
                    title: "System Uptime",
                    subtitle: vm.metrics.hdrEnabled ? "Windows HDR: ON" : "Windows HDR: OFF",
                    valueText: vm.metrics.formattedUptime,
                    progress: vm.metrics.gpuUsage / 100.0,
                    icon: "clock.fill",
                    accent: .teal
                )
            }

            // Master Volume Slider (Live Synced with Windows)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Windows Master Volume", systemImage: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(vm.metrics.volume))%")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                }

                HStack(spacing: 14) {
                    Button {
                        let newVal = max(0, vm.metrics.volume - 10)
                        vm.metrics.volume = newVal
                        Task { await vm.updateVolume(newVal) }
                    } label: {
                        Image(systemName: "speaker.minus.fill")
                            .padding(10)
                            .background(.white.opacity(0.1), in: Circle())
                    }

                    Slider(value: $vm.metrics.volume, in: 0...100, step: 1) { editing in
                        vm.isDraggingVolume = editing
                        Task { await vm.updateVolume(vm.metrics.volume) }
                    }
                    .tint(.cyan)

                    Button {
                        let newVal = min(100, vm.metrics.volume + 10)
                        vm.metrics.volume = newVal
                        Task { await vm.updateVolume(newVal) }
                    } label: {
                        Image(systemName: "speaker.plus.fill")
                            .padding(10)
                            .background(.white.opacity(0.1), in: Circle())
                    }

                    Button {
                        vm.metrics.isMuted.toggle()
                        Task { await vm.sendPowerAction("mute") }
                    } label: {
                        Image(systemName: vm.metrics.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .padding(10)
                            .background((vm.metrics.isMuted ? Color.red : Color.white).opacity(0.18), in: Circle())
                            .foregroundStyle(vm.metrics.isMuted ? .red : .white)
                    }
                }
            }
            .padding(20)
            .liquidGlass(cornerRadius: 24)

            // Quick Power & Display Controls
            VStack(alignment: .leading, spacing: 14) {
                Text("Quick Power & Display Controls")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 10) {
                    quickActionButton(title: "Lock", icon: "lock.fill", tint: .blue) {
                        await vm.sendPowerAction("lock")
                    }
                    quickActionButton(title: "Fix Display", icon: "display.trianglebadge.exclamationmark", tint: .cyan) {
                        await vm.sendPowerAction("restore_display")
                    }
                    quickActionButton(title: "HDR", icon: "sun.max.fill", tint: vm.metrics.hdrEnabled ? .yellow : .gray) {
                        await vm.sendPowerAction("toggle_hdr")
                    }
                    quickActionButton(title: "Sleep", icon: "moon.zzz.fill", tint: .indigo) {
                        await vm.sendPowerAction("sleep")
                    }
                    quickActionButton(title: "Restart", icon: "arrow.triangle.2.circlepath", tint: .orange) {
                        await vm.sendPowerAction("restart")
                    }
                    quickActionButton(title: "Shutdown", icon: "power", tint: .red) {
                        await vm.sendPowerAction("shutdown")
                    }
                }
            }
            .padding(20)
            .liquidGlass(cornerRadius: 24)
        }
    }

    private var wakeOnLanHeroButton: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            Button {
                Task { await vm.wakePC() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(vm.isWakingUp ? 0.35 : 0.15))
                        .frame(width: 210, height: 210)
                        .blur(radius: 25)
                        .scaleEffect(vm.isWakingUp ? 1.15 : 0.95)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: vm.isWakingUp)

                    VStack(spacing: 14) {
                        if vm.isWakingUp {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.cyan)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 52, weight: .bold))
                                .foregroundStyle(.cyan)
                        }

                        Text(vm.isWakingUp ? "WAKING RIG..." : "WAKE PC")
                            .font(.headline.weight(.heavy))
                            .tracking(1.5)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 180, height: 180)
                    .liquidGlass(cornerRadius: 90, tint: .cyan)
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isWakingUp)

            VStack(spacing: 8) {
                Text("PC Offline or Agent Unreachable")
                    .font(.title3.weight(.bold))
                Text("Tap WAKE PC to broadcast a Magic Packet to \(vm.pcMAC) (\(vm.pcIP)), or verify that orbit_agent.py is running on Windows.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await vm.refreshMetrics() }
                } label: {
                    Label("Retry Connection", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.14), in: Capsule())
                }

                Button {
                    vm.isShowingIPConfigSheet = true
                } label: {
                    Label("Configure IPs & MAC", systemImage: "network")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.cyan.opacity(0.22), in: Capsule())
                        .foregroundStyle(.cyan)
                }
            }

            Spacer(minLength: 20)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 30, tint: .indigo)
    }

    private func quickActionButton(title: String, icon: String, tint: Color, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 2. SUNSHINE GAME LIBRARY VIEW

struct GameLibraryView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var filteredGames: [SunshineGame] {
        if searchText.isEmpty { return vm.games }
        return vm.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 18), count: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Active Streaming Profile")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                Picker("Profile", selection: $vm.selectedProfile) {
                                    ForEach(StreamingProfile.allCases) { profile in
                                        Text(profile.rawValue).tag(profile)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.cyan)
                            }
                            Spacer()
                            Button {
                                Task { await vm.fetchSunshineApps() }
                            } label: {
                                Label("Sync Sunshine", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.cyan.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(16)
                        .liquidGlass(cornerRadius: 20, tint: .cyan)

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(filteredGames) { game in
                                GameCoverCard(game: game) {
                                    Task { await vm.smartLaunch(game: game) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 32 : 18)
                    .padding(.top, vm.isDynamicIslandActive ? 54 : 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Sunshine Library")
            .searchable(text: $searchText, prompt: "Search Sunshine games...")
        }
    }
}

struct GameCoverCard: View {
    let game: SunshineGame
    let onLaunch: () -> Void

    var body: some View {
        let accent = Color(hex: game.accentHex)

        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.55), accent.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 125)
                    .overlay(
                        Image(systemName: game.iconSymbol)
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    )

                if game.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(game.genre)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Button(action: onLaunch) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("Smart Launch")
                        .fontWeight(.bold)
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.14), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 24, tint: accent)
    }
}

// MARK: - 3. QUICK REMOTE VIEW (Throttled 60fps Trackpad, Clicks, Keyboard & Macros)

struct QuickRemoteView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var keyboardInput: String = ""
    @State private var lastDragLocation: CGPoint? = nil
    @State private var lastSentTime: Date = .distantPast
    @State private var accumulatedDX: Double = 0
    @State private var accumulatedDY: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Touchpad Card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Precision Windows Trackpad", systemImage: "hand.draw.fill")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Drag to move • Tap to Left Click")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            ZStack {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(.white.opacity(0.06))
                                    .frame(height: 230)
                                    .overlay(
                                        VStack(spacing: 8) {
                                            Image(systemName: "cursorarrow.motionlines")
                                                .font(.system(size: 40))
                                                .foregroundStyle(.cyan.opacity(0.4))
                                            Text(vm.statusLog)
                                                .font(.caption2)
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                    )
                                    .gesture(
                                        DragGesture(minimumDistance: 1)
                                            .onChanged { value in
                                                if let last = lastDragLocation {
                                                    accumulatedDX += (value.location.x - last.x) * 2.2
                                                    accumulatedDY += (value.location.y - last.y) * 2.2
                                                    let now = Date()
                                                    if now.timeIntervalSince(lastSentTime) >= 0.028 {
                                                        let sendX = Int(accumulatedDX)
                                                        let sendY = Int(accumulatedDY)
                                                        if sendX != 0 || sendY != 0 {
                                                            accumulatedDX = 0
                                                            accumulatedDY = 0
                                                            lastSentTime = now
                                                            Task { await vm.sendMouseInput(dx: sendX, dy: sendY) }
                                                        }
                                                    }
                                                }
                                                lastDragLocation = value.location
                                            }
                                            .onEnded { _ in
                                                let restX = Int(accumulatedDX)
                                                let restY = Int(accumulatedDY)
                                                if restX != 0 || restY != 0 {
                                                    Task { await vm.sendMouseInput(dx: restX, dy: restY) }
                                                }
                                                accumulatedDX = 0
                                                accumulatedDY = 0
                                                lastDragLocation = nil
                                            }
                                    )
                                    .simultaneousGesture(
                                        TapGesture()
                                            .onEnded {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                Task { await vm.sendMouseInput(click: "left") }
                                            }
                                    )
                            }

                            HStack(spacing: 10) {
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    Task { await vm.sendMouseInput(click: "left") }
                                } label: {
                                    Label("Left Click", systemImage: "computermouse.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(.cyan.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                                }

                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    Task { await vm.sendMouseInput(click: "double") }
                                } label: {
                                    Text("2x Click")
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                                }

                                Button {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    Task { await vm.sendMouseInput(click: "right") }
                                } label: {
                                    Label("Right Click", systemImage: "ContextualMenu")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(.purple.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    Task { await vm.sendMouseInput(scroll: 3) }
                                } label: {
                                    Label("Scroll Up", systemImage: "arrow.up")
                                        .font(.caption2.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }

                                Button {
                                    Task { await vm.sendMouseInput(scroll: -3) }
                                } label: {
                                    Label("Scroll Down", systemImage: "arrow.down")
                                        .font(.caption2.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        .padding(18)
                        .liquidGlass(cornerRadius: 26, tint: .cyan)

                        // Remote Keyboard & Special Windows Keys
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                TextField("Type text to send to Windows...", text: $keyboardInput)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                    .onSubmit {
                                        sendCurrentText()
                                    }

                                Button {
                                    sendCurrentText()
                                } label: {
                                    Image(systemName: "paperplane.fill")
                                        .padding(12)
                                        .background(Color.cyan, in: RoundedRectangle(cornerRadius: 14))
                                        .foregroundStyle(.black)
                                }
                            }

                            HStack(spacing: 8) {
                                ForEach(["ENTER", "BACKSPACE", "SPACE", "ESC", "WIN", "TAB"], id: \.self) { keyName in
                                    Button {
                                        Task { await vm.sendKeyboardInput(key: keyName) }
                                    } label: {
                                        Text(keyName)
                                            .font(.caption2.weight(.bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlass(cornerRadius: 22)

                        // Media & Gaming Macros
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Media & Gaming Macros")
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 12) {
                                macroButton("Prev", icon: "backward.fill", color: .cyan) {
                                    await vm.sendPowerAction("media_prev")
                                }
                                macroButton("Play/Pause", icon: "playpause.fill", color: .mint) {
                                    await vm.sendPowerAction("media_play_pause")
                                }
                                macroButton("Next", icon: "forward.fill", color: .cyan) {
                                    await vm.sendPowerAction("media_next")
                                }
                                macroButton("Alt+F4", icon: "xmark.octagon.fill", color: .red) {
                                    await vm.sendPowerAction("kill_game")
                                }
                            }
                        }
                        .padding(18)
                        .liquidGlass(cornerRadius: 24)
                    }
                    .padding(18)
                    .padding(.top, vm.isDynamicIslandActive ? 40 : 0)
                }
            }
            .navigationTitle("Quick Remote")
        }
    }

    private func sendCurrentText() {
        guard !keyboardInput.isEmpty else { return }
        let text = keyboardInput
        keyboardInput = ""
        Task { await vm.sendKeyboardInput(text: text) }
    }

    private func macroButton(_ title: String, icon: String, color: Color, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4. WIDGETS & DYNAMIC ISLAND VIEW

struct WidgetsAndIslandPreviewView: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Dynamic Island Live Activity", systemImage: "capsule.portrait.tophalf.filled")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { vm.isDynamicIslandActive },
                                    set: { _ in vm.toggleDynamicIsland() }
                                ))
                                .labelsHidden()
                                .tint(.cyan)
                            }
                            Text("Pins a real-time telemetry capsule to the top of the screen showing live CPU/GPU temperatures, wattage, and network ping.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(20)
                        .liquidGlass(cornerRadius: 24, tint: .cyan)

                        Text("iOS Home Screen Widgets (Synced Live)")
                            .font(.headline)

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Circle()
                                        .fill(vm.metrics.isOnline ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("ORBIT")
                                        .font(.caption2.weight(.heavy))
                                    Spacer()
                                    Image(systemName: "cpu.fill")
                                        .foregroundStyle(.cyan)
                                }
                                Spacer()
                                Text("\(Int(vm.metrics.cpuTemp))°C")
                                    .font(.system(.title, design: .rounded).weight(.bold))
                                Text("GPU: \(Int(vm.metrics.gpuTemp))°C • \(Int(vm.metrics.gpuPowerWatts))W")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(16)
                            .frame(width: 160, height: 160)
                            .liquidGlass(cornerRadius: 26, tint: .cyan)

                            VStack(spacing: 14) {
                                Text("Lock Screen Gauges")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                                HStack(spacing: 16) {
                                    Gauge(value: vm.metrics.cpuTemp, in: 0...100) {
                                        Text("CPU")
                                    } currentValueLabel: {
                                        Text("\(Int(vm.metrics.cpuTemp))°")
                                    }
                                    .gaugeStyle(.accessoryCircular)
                                    .tint(.cyan)

                                    Gauge(value: vm.metrics.gpuTemp, in: 0...100) {
                                        Text("GPU")
                                    } currentValueLabel: {
                                        Text("\(Int(vm.metrics.gpuTemp))°")
                                    }
                                    .gaugeStyle(.accessoryCircular)
                                    .tint(.mint)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .liquidGlass(cornerRadius: 26, tint: .mint)
                        }
                    }
                    .padding(18)
                    .padding(.top, vm.isDynamicIslandActive ? 40 : 0)
                }
            }
            .navigationTitle("Widgets & Island")
        }
    }
}

// MARK: - 5. SMART LAUNCH OVERLAY & STREAM VIEW

struct SmartLaunchOverlay: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.cyan)

                Text("Smart Launch: \(vm.activeStreamingGame?.title ?? "PC")")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                Text(vm.smartLaunchStep.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.cyan)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 350)
            .liquidGlass(cornerRadius: 28, tint: .cyan)
        }
    }
}

struct MoonlightStreamView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showHUD = true
    @State private var showVirtualPad = true

    var body: some View {
        ZStack {
            if let liveImage = vm.liveFrameImage {
                Image(uiImage: liveImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) {
                        withAnimation { showHUD.toggle() }
                    }
            } else {
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.07, blue: 0.14), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .onTapGesture(count: 2) {
                    withAnimation { showHUD.toggle() }
                }

                VStack(spacing: 14) {
                    Image(systemName: vm.activeStreamingGame?.iconSymbol ?? "play.tv.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.cyan)

                    Text("Streaming: \(vm.activeStreamingGame?.title ?? "Desktop")")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text("\(vm.selectedProfile.rawValue) • \(vm.selectedProfile.bitrateMbps) Mbps")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))

                    Button {
                        vm.openNativeMoonlight()
                    } label: {
                        Label("Open in Moonlight App (120Hz HDR)", systemImage: "arrow.up.forward.app.fill")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Color.cyan, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .padding(.top, 8)
                }
            }

            if showHUD {
                VStack {
                    HStack(spacing: 14) {
                        Label("120 FPS", systemImage: "speedometer")
                        Label("\(vm.pingMs) ms", systemImage: "wifi")
                        Label("\(Int(vm.metrics.gpuTemp))°C", systemImage: "flame.fill")

                        Spacer()

                        Button {
                            showVirtualPad.toggle()
                        } label: {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(showVirtualPad ? .cyan : .white)
                        }

                        Menu {
                            Button("Disconnect Stream", role: .cancel) {
                                vm.stopStreaming(putPCToSleep: false)
                            }
                            Button("Quit Game & Put PC to Sleep", role: .destructive) {
                                vm.stopStreaming(putPCToSleep: true)
                            }
                        } label: {
                            Label("Exit", systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .liquidGlass(cornerRadius: 20, tint: .cyan)
                    .padding()

                    Spacer()

                    if showVirtualPad {
                        HStack {
                            HStack(spacing: 10) {
                                ForEach(["LEFT", "UP", "DOWN", "RIGHT"], id: \.self) { dir in
                                    Button {
                                        Task { await vm.sendGamepadButton(dir) }
                                    } label: {
                                        Text(dir.prefix(1))
                                            .font(.headline.bold())
                                            .frame(width: 44, height: 44)
                                            .background(.ultraThinMaterial, in: Circle())
                                    }
                                }
                            }

                            Spacer()

                            HStack(spacing: 14) {
                                ForEach(["A", "B", "X", "Y"], id: \.self) { btn in
                                    Button {
                                        Task { await vm.sendGamepadButton(btn) }
                                    } label: {
                                        Text(btn)
                                            .font(.headline.bold())
                                            .frame(width: 48, height: 48)
                                            .background(.ultraThinMaterial, in: Circle())
                                    }
                                }
                            }
                        }
                        .padding(28)
                    }
                }
            }
        }
    }
}

// MARK: - 6. SETTINGS VIEW (Full In-App IP, Subnet, Broadcast & MAC Editor)

struct SettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        focusedField = false
                        Task { await vm.scanLANForPC() }
                    } label: {
                        HStack {
                            if vm.isScanningLAN {
                                ProgressView().tint(.cyan)
                                    .padding(.trailing, 6)
                                Text("Scanning Local Network (1-254)...")
                                    .fontWeight(.bold)
                            } else {
                                Label("Scan LAN & Auto-Fill PC IPs", systemImage: "antenna.radiowaves.left.and.right")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .disabled(vm.isScanningLAN)

                    Button {
                        focusedField = false
                        Task { await vm.fetchNetworkConfigFromPC() }
                    } label: {
                        Label("Pull Exact MAC & Broadcast from PC", systemImage: "arrow.down.doc.fill")
                            .foregroundStyle(.mint)
                    }
                } header: {
                    Text("1-Tap Automatic Configuration")
                } footer: {
                    Text("Automatically finds your PC on Wi-Fi/LAN and fills in the IPv4, MAC address, Subnet Mask, and Broadcast IP.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PC IPv4 Address (Windows Rig)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("192.168.1.196", text: $vm.pcIP)
                            .font(.body.monospaced())
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField)
                            .onChange(of: vm.pcIP) { _, _ in
                                vm.recalculateBroadcastIfNeeded()
                            }
                    }

                    Toggle("Auto-Calculate Broadcast IP", isOn: $vm.autoCalcBroadcast)
                        .onChange(of: vm.autoCalcBroadcast) { _, _ in
                            vm.recalculateBroadcastIfNeeded()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Broadcast IP (for Wake-on-LAN)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("192.168.1.255", text: $vm.wolTargetIP)
                            .font(.body.monospaced())
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subnet Mask")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("255.255.255.0", text: $vm.subnetMask)
                            .font(.body.monospaced())
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField)
                            .onChange(of: vm.subnetMask) { _, _ in
                                vm.recalculateBroadcastIfNeeded()
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("PC Ethernet/Wi-Fi MAC Address")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("AA:BB:CC:11:22:33", text: $vm.pcMAC)
                            .font(.body.monospaced())
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .focused($focusedField)
                    }
                } header: {
                    Text("Manual IP & Wake-on-LAN Configuration")
                }

                Section("Ports & Security") {
                    LabeledContent("Wake-on-LAN UDP Port") {
                        TextField("9", value: $vm.wolPort, format: .number)
                            .font(.body.monospaced())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField)
                    }
                    LabeledContent("Orbit Agent Port (TCP)") {
                        TextField("8765", value: $vm.agentPort, format: .number)
                            .font(.body.monospaced())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField)
                    }
                    LabeledContent("Sunshine Port (HTTPS)") {
                        TextField("47989", value: $vm.sunshinePort, format: .number)
                            .font(.body.monospaced())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField)
                    }
                    LabeledContent("API Token") {
                        TextField("endspec-secret-token", text: $vm.apiToken)
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField)
                    }
                }

                Section("Test & Diagnostics") {
                    Button {
                        focusedField = false
                        vm.isDemoMode = false
                        Task { await vm.refreshMetrics() }
                    } label: {
                        Label("Save & Test Connection to PC", systemImage: "checkmark.circle.fill")
                            .fontWeight(.bold)
                            .foregroundStyle(.cyan)
                    }

                    Button {
                        focusedField = false
                        Task { await vm.wakePC() }
                    } label: {
                        Label("Send Wake-on-LAN Magic Packet Now", systemImage: "power.circle.fill")
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }

                    Button {
                        focusedField = false
                        Task { await vm.sendPowerAction("restore_display") }
                    } label: {
                        Label("Force Wake / Restore PC Monitor", systemImage: "display")
                            .foregroundStyle(.orange)
                    }

                    Toggle("Demo Mode (Simulated Data)", isOn: $vm.isDemoMode)
                    Toggle("Auto-Handoff to Moonlight App", isOn: $vm.autoOpenMoonlight)

                    Text(vm.statusLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Network & IPs")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = false
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
