import SwiftUI

struct CompanionToolsView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var showsSettings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        OrbitMark(size: 46)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(vm.isDemoMode ? "Explore Orbit" : vm.selectedPCName).font(.headline)
                            Label(vm.hasSecureConnection ? "Encrypted companion connection" : "Set up your secure connection", systemImage: vm.hasSecureConnection ? "lock.fill" : "lock.open")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                    NavigationLink { PCProfilesView(vm: vm) } label: { Label("My PCs", systemImage: "desktopcomputer.and.arrow.down") }
                }
                Section("Your PC, closer") {
                    NavigationLink { ClipboardView(vm: vm) } label: { tool("Clipboard", detail: "Send text and links between devices", icon: "doc.on.clipboard") }
                    NavigationLink { AudioMixerView(vm: vm) } label: { tool("Audio mixer", detail: "Volume and mute for each application", icon: "slider.vertical.3") }
                    NavigationLink { SessionHistoryView(vm: vm) } label: { tool("Sessions & graphs", detail: "Review game performance and recordings", icon: "chart.xyaxis.line") }
                    NavigationLink { TaskManagerView(vm: vm) } label: { tool("Task Manager", detail: "Running applications and processes", icon: "list.bullet.rectangle") }
                }
                Section("Setup & details") {
                    NavigationLink { FullSpecsView(vm: vm) } label: { Label("PC specifications", systemImage: "cpu") }
                    NavigationLink { MonitoringSourcesView(vm: vm) } label: { Label("Monitoring sources", systemImage: "waveform.path.ecg") }
                    Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .navigationTitle("Tools")
            .sheet(isPresented: $showsSettings) { SettingsView(vm: vm, isPresentedAsSheet: true) }
        }
    }
    private func tool(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).foregroundStyle(.cyan).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
