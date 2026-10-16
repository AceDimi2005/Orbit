import SwiftUI

struct CompanionToolsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showsSettings = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .ocean
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        OrbitMark(size: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(vm.isDemoMode ? "Explore Orbit" : vm.selectedPCName).font(.title3.weight(.semibold))
                            Label(vm.hasSecureConnection ? "Paired securely" : "Ready when you are", systemImage: vm.hasSecureConnection ? "lock.shield" : "desktopcomputer")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    NavigationLink { PCProfilesView(vm: vm) } label: { tool("My PCs", detail: "Pair a computer or switch connections", icon: "desktopcomputer") }
                }
                Section("Everyday controls") {
                    NavigationLink { ClipboardView(vm: vm) } label: { tool("Clipboard", detail: "Text and links, in both directions", icon: "doc.on.clipboard") }
                    NavigationLink { AudioMixerView(vm: vm) } label: { tool("Audio mixer", detail: "Set the volume for each application", icon: "slider.vertical.3") }
                    NavigationLink { TaskManagerView(vm: vm) } label: { tool("Task Manager", detail: "See what is running on your PC", icon: "list.bullet.rectangle") }
                }
                Section("Understand your PC") {
                    NavigationLink { SessionHistoryView(vm: vm) } label: { tool("Sessions & graphs", detail: "Performance over time", icon: "chart.xyaxis.line") }
                    NavigationLink { FullSpecsView(vm: vm) } label: { tool("PC specifications", detail: "Your hardware, automatically detected", icon: "cpu") }
                    NavigationLink { MonitoringSourcesView(vm: vm) } label: { tool("Monitoring sources", detail: "Sensor availability and agent status", icon: "waveform.path.ecg") }
                }
                Section("Make it yours") {
                    NavigationLink { AppearanceSettingsView() } label: { tool("Appearance", detail: "Classic or Improved, with five colour themes", icon: "paintpalette") }
                    NavigationLink { WidgetHelpView(vm: vm) } label: { tool("Widgets", detail: "Your PCs at a glance", icon: "square.grid.2x2") }
                    NavigationLink { LiveActivitySettingsView(vm: vm) } label: { tool("Live Activity", detail: "Lock Screen and Dynamic Island", icon: "capsule.portrait.tophalf.filled") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView(vm: vm, isPresentedAsSheet: true) }
        }.orbitAppearance()
    }
    private func tool(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.accent).frame(width: 40, height: 40)
                .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}
