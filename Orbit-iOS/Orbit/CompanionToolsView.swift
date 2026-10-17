import SwiftUI

struct CompanionToolsView: View {
    @ObservedObject var vm: OrbitViewModel
    @ObservedObject private var proStore = OrbitProStore.shared
    @State private var showsSettings = false
    @State private var showsDiscovery = false
    @State private var showsProPaywall = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 175, maximum: 340), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OrbitAmbientBackground(isOnline: vm.metrics.isOnline)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) {
                                pcSwitcherCard
                                orbitProCard
                            }
                            VStack(spacing: 14) {
                                pcSwitcherCard
                                orbitProCard
                            }
                        }

                        sectionHeader("PC Control", icon: "slider.horizontal.3")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink { ClipboardView(vm: vm) } label: {
                                toolTile("Clipboard", subtitle: "Sync text & links", icon: "doc.on.clipboard.fill", tint: .cyan)
                            }
                            NavigationLink { AudioMixerView(vm: vm) } label: {
                                toolTile("Audio Mixer", subtitle: "Per-app volume", icon: "slider.vertical.3", tint: .purple)
                            }
                            NavigationLink { TaskManagerView(vm: vm) } label: {
                                toolTile("Task Manager", subtitle: "Processes & apps", icon: "list.bullet.rectangle.portrait.fill", tint: .orange)
                            }
                            NavigationLink { PCFilesView(vm: vm) } label: {
                                toolTile("PC Files", subtitle: "Browse & download", icon: "folder.fill", tint: .blue)
                            }
                        }

                        sectionHeader("Diagnostics & History", icon: "waveform.path.ecg")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink { SessionHistoryView(vm: vm) } label: {
                                toolTile("Session Graphs", subtitle: "History & peaks", icon: "chart.xyaxis.line", tint: .mint)
                            }
                            NavigationLink { FullSpecsView(vm: vm) } label: {
                                toolTile("Hardware Specs", subtitle: "Detected components", icon: "cpu.fill", tint: .indigo)
                            }
                            NavigationLink { MonitoringSourcesView(vm: vm) } label: {
                                toolTile("Sensor Status", subtitle: "Telemetry sources", icon: "sensor.tag.radiowaves.forward.fill", tint: .teal)
                            }
                            NavigationLink { PCProfilesView(vm: vm) } label: {
                                toolTile("My PCs", subtitle: "Manage connections", icon: "desktopcomputer", tint: theme.accent)
                            }
                        }

                        sectionHeader("Personalization & iOS", icon: "sparkles")
                        LazyVGrid(columns: columns, spacing: 12) {
                            NavigationLink { LiveActivitySettingsView(vm: vm) } label: {
                                toolTile(
                                    "Live Activity",
                                    subtitle: vm.isDynamicIslandActive ? "Running on Island" : "Island & Lock Screen",
                                    icon: "capsule.portrait.tophalf.filled",
                                    tint: vm.isDynamicIslandActive ? .mint : .pink
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
                                toolTile("Settings", subtitle: "Network & updates", icon: "gearshape.fill", tint: .gray)
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
            .buttonStyle(.plain)
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
                            Label("Pair New PC...", systemImage: "dot.radiowaves.left.and.right")
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
                            Label("Orbit Pro · Coming Soon", systemImage: "crown.fill")
                        }

                        Button {
                            showsSettings = true
                        } label: {
                            Label("Settings...", systemImage: "gearshape")
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
        }
        .orbitAppearance()
    }

    private var orbitProCard: some View {
        Button {
            showsProPaywall = true
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "crown.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit Pro · Coming Soon")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("All 9 themes & 6 Home Screen icons unlocked for free testing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("SOON")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.2), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            .padding(14)
            .liquidGlass(cornerRadius: 18, tint: .yellow)
        }
    }

    private var pcSwitcherCard: some View {
        HStack(spacing: 14) {
            OrbitMark(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.isDemoMode ? "Demo Mode" : vm.selectedPCName)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.metrics.isOnline ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(vm.metrics.isOnline ? (vm.hasSecureConnection ? "Encrypted TLS" : "Connected") : "Offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
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
                    Label("Find a PC...", systemImage: "plus.circle")
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
                .foregroundStyle(theme.accent)
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 20, tint: theme.accent)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.accent)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func toolTile(_ title: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Spacer()
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
        .liquidGlass(cornerRadius: 18, tint: tint)
    }
}
