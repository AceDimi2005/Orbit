import SwiftUI

struct TaskManagerView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var search = ""
    @State private var sortOrder: ProcessSortOrder = .memory
    @State private var selectedProcess: PCProcess?
    @Environment(\.scenePhase) private var scenePhase

    private var sortedProcesses: [PCProcess] {
        let filtered = vm.processes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || String($0.pid).contains(search) }
        return filtered.sorted { left, right in
            switch sortOrder {
            case .memory:
                if left.memoryMB != right.memoryMB { return (left.memoryMB ?? -1) > (right.memoryMB ?? -1) }
            case .cpu:
                if left.cpuPercent != right.cpuPercent { return (left.cpuPercent ?? -1) > (right.cpuPercent ?? -1) }
            case .gpu:
                if left.gpuPercent != right.gpuPercent { return (left.gpuPercent ?? -1) > (right.gpuPercent ?? -1) }
            case .vram:
                if left.vramMB != right.vramMB { return (left.vramMB ?? -1) > (right.vramMB ?? -1) }
            case .name:
                if left.name != right.name { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            }
            return left.pid < right.pid
        }
    }

    var body: some View {
        List {
            Section {
                if vm.isDemoMode {
                    Label("Preview processes · no PC actions", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Sort processes", selection: $sortOrder) {
                    ForEach(ProcessSortOrder.allCases) { order in Text(order.title).tag(order) }
                }
                .pickerStyle(.segmented)
                if let updated = vm.lastProcessesUpdated {
                    HStack {
                        Text("\(vm.processes.count) processes")
                        Spacer()
                        Text(updated, style: .time)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let status = vm.processGpuStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = vm.processesError {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
            if let status = vm.processActionStatus {
                Section { Text(status).font(.caption).foregroundStyle(.mint) }
            }
            Section("Running processes") {
                if vm.isLoadingProcesses && vm.processes.isEmpty {
                    HStack { ProgressView(); Text("Reading running processes…").padding(.leading, 8) }
                } else if sortedProcesses.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No processes available" : "No matching processes",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text(search.isEmpty ? "Keep Orbit Agent running on your PC." : "Try another name or PID."))
                } else {
                    ForEach(sortedProcesses) { process in processRow(process) }
                }
            }
        }
        .navigationTitle("Task Manager")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Application name or PID")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await vm.fetchProcesses() } } label: {
                    if vm.isLoadingProcesses { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(!vm.metrics.isOnline || vm.isLoadingProcesses)
                .accessibilityLabel("Refresh processes")
            }
        }
        .refreshable { await vm.fetchProcesses() }
        .task {
            while !Task.isCancelled {
                if scenePhase == .active { await vm.fetchProcesses() }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in selectedProcess = nil }
        .confirmationDialog("End \(selectedProcess?.name ?? "this application")?", isPresented: Binding(
            get: { selectedProcess != nil }, set: { if !$0 { selectedProcess = nil } }
        ), titleVisibility: .visible) {
            if let process = selectedProcess {
                Button("End task", role: .destructive) {
                    selectedProcess = nil
                    Task { await vm.endProcess(process) }
                }
            }
            Button("Cancel", role: .cancel) { selectedProcess = nil }
        } message: {
            Text("Stops the selected process on your PC. Unsaved work may be lost.")
        }
    }

    private func processRow(_ process: PCProcess) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: process.canTerminate ? "app.fill" : "lock.shield")
                    .foregroundStyle(process.canTerminate ? .cyan : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text("PID \(process.pid) · \(process.status)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if vm.endingProcessID == process.pid {
                    ProgressView()
                } else if process.canTerminate {
                    Button("End task", role: .destructive) { selectedProcess = process }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .disabled(vm.endingProcessID != nil || !vm.metrics.isOnline || vm.isDemoMode)
                        .accessibilityLabel("End task: \(process.name), PID \(process.pid)")
                } else {
                    Text("Protected")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                Text(process.cpuPercent.flatMap { $0.isFinite ? String(format: "CPU %.1f%%", $0) : nil } ?? "CPU —")
                Text(process.gpuPercent.flatMap { $0.isFinite ? String(format: "GPU %.1f%%", $0) : nil } ?? "GPU —")
                Text(process.memoryMB.flatMap { $0.isFinite ? String(format: "RAM %.0f MB", $0) : nil } ?? "RAM —")
                if let vram = process.vramMB, vram.isFinite, vram > 0 {
                    Text(String(format: "VRAM %.0f MB", vram))
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case memory, cpu, gpu, vram, name
    var id: String { rawValue }
    var title: String { switch self { case .memory: return "RAM"; case .cpu: return "CPU"; case .gpu: return "GPU"; case .vram: return "VRAM"; case .name: return "Name" } }
}

struct FPSSetupView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var copiedCommand: String?

    private var processName: String {
        let name = vm.metrics.activeGameProcess ?? "game.exe"
        return String(name.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(120))
    }
    private var quotedProcessName: String { "'" + processName.replacingOccurrences(of: "'", with: "''") + "'" }
    private var captureCommand: String {
        "New-Item -ItemType Directory -Force 'C:\\Orbit' | Out-Null\n.\\PresentMon.exe --process_name \(quotedProcessName) --output_file 'C:\\Orbit\\presentmon.csv' --v1_metrics --no_console_stats"
    }
    private var agentCommand: String {
        "$env:ORBIT_PRESENTMON_CSV = 'C:\\Orbit\\presentmon.csv'\n$env:ORBIT_GAME_PROCESSES = \(quotedProcessName)\n.\\start_agent.bat"
    }

    var body: some View {
        List {
            Section("MSI Afterburner + RTSS (Recommended)") {
                Label("Automatic FPS & Sensor Reading", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                Text("Install MSI Afterburner with RivaTuner Statistics Server (RTSS) included, and keep both open on your PC.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Download MSI Afterburner", destination: URL(string: "https://www.msi.com/Landing/afterburner/graphics-cards")!)
                    .font(.subheadline)
            }
            Section("Quick Checklist") {
                Label("1. In Afterburner → Settings → Monitoring, enable CPU/GPU Temp & Framerate.", systemImage: "1.circle.fill")
                    .font(.caption)
                Label("2. Keep RTSS running in the Windows system tray with Application detection level set to Low.", systemImage: "2.circle.fill")
                    .font(.caption)
                Label("3. Enable Game frame rate in Customize Dashboard.", systemImage: "3.circle.fill")
                    .font(.caption)
            }
            Section {
                DisclosureGroup("Advanced: PresentMon CSV fallback") {
                    Text("Use PresentMon if RTSS is blocked by anti-cheat.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("PresentMon Releases", destination: URL(string: "https://github.com/GameTechDev/PresentMon/releases")!)
                    command(captureCommand, id: "capture")
                    command(agentCommand, id: "agent")
                }
            }
        }
        .navigationTitle("Set up FPS")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func command(_ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
            Button {
                UIPasteboard.general.string = text
                copiedCommand = id
            } label: {
                Label(copiedCommand == id ? "Copied" : "Copy PowerShell commands", systemImage: copiedCommand == id ? "checkmark" : "doc.on.doc")
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

struct MonitoringSourcesView: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        List {
            Section("Windows Companion") {
                LabeledContent("Connection", value: vm.isDemoMode ? "Simulated preview" : (vm.metrics.isOnline ? "Connected" : "Unavailable"))
                LabeledContent("Version", value: vm.metrics.agentVersion ?? "Not connected")
                if vm.metrics.telemetryAvailable == false {
                    Text("Agent reachable, waiting for telemetry sample.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh connection", systemImage: "arrow.clockwise") { Task { await vm.refreshMetrics() } }
            }
            Section("Temperatures & Sensors") {
                LabeledContent("CPU sensor", value: vm.metrics.sensorSource ?? "Not connected")
                LabeledContent("GPU sensor", value: vm.metrics.gpuSource ?? "Not connected")
                LabeledContent("CPU temp", value: vm.metrics.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                LabeledContent("GPU temp", value: vm.metrics.gpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                if let status = vm.metrics.sensorStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                NavigationLink { FPSSetupView(vm: vm) } label: { Label("Set up Afterburner & RTSS", systemImage: "slider.horizontal.3") }
            }
            Section("Network & Game FPS") {
                LabeledContent("Adapter", value: vm.metrics.networkInterface ?? "Auto")
                LabeledContent("Download", value: traffic(vm.metrics.networkDownloadMBps))
                LabeledContent("Upload", value: traffic(vm.metrics.networkUploadMBps))
                LabeledContent("Detected game", value: vm.metrics.activeGameProcess ?? "None")
                LabeledContent("FPS", value: vm.metrics.fps.map { String(format: "%.1f", $0) } ?? "Unavailable")
                if let source = vm.metrics.fpsSource { LabeledContent("FPS source", value: source) }
            }
        }
        .navigationTitle("Monitoring Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func traffic(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        if value >= 1 { return String(format: "%.2f MB/s", value) }
        if value >= 0.001 { return String(format: "%.1f KB/s", value * 1000) }
        return String(format: "%.0f B/s", value * 1_000_000)
    }
}
