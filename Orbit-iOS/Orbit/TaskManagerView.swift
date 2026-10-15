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
                    Label("Preview processes · no PC actions", systemImage: "sparkles").foregroundStyle(.orange)
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
                Text("CPU uses the whole PC as 100%. The first sample may be unavailable. Process usage refreshes while this screen is open.")
                    .font(.caption).foregroundStyle(.secondary)
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
                                           description: Text(search.isEmpty ? "Keep Orbit Agent running on your PC and refresh this screen." : "Try another application name or process ID."))
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
            Text("This stops the selected process on your PC. Unsaved work may be lost. Protected system processes cannot be ended here.")
        }
    }

    private func processRow(_ process: PCProcess) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: process.canTerminate ? "app" : "lock.shield")
                    .foregroundStyle(process.canTerminate ? .cyan : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(process.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text("PID \(process.pid) · \(process.status)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if vm.endingProcessID == process.pid {
                    ProgressView()
                } else {
                    Button("End task", role: .destructive) { selectedProcess = process }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .disabled(!process.canTerminate || vm.endingProcessID != nil || !vm.metrics.isOnline || vm.isDemoMode)
                        .accessibilityLabel("End task: \(process.name), PID \(process.pid)")
                }
            }
            HStack(spacing: 18) {
                Text(process.cpuPercent.flatMap { $0.isFinite ? String(format: "CPU %.1f%%", $0) : nil } ?? "CPU —")
                Text(process.memoryMB.flatMap { $0.isFinite ? String(format: "RAM %.0f MB", $0) : nil } ?? "RAM —")
                if !process.canTerminate { Text("Protected").foregroundStyle(.secondary) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case memory, cpu, name
    var id: String { rawValue }
    var title: String { switch self { case .memory: return "Memory"; case .cpu: return "CPU"; case .name: return "Name" } }
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
            Section {
                Text("The variable is ORBIT_PRESENTMON_CSV. Orbit reads a live PresentMon capture to show measured game FPS.")
                Text("Use the real game executable name from Windows Task Manager → Details. The current example is \(processName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("1. Get PresentMon Console") {
                Link("Open official PresentMon releases", destination: URL(string: "https://github.com/GameTechDev/PresentMon/releases")!)
                Text("Download the Console executable for your PC and rename it PresentMon.exe. Keep it in a folder you can open in PowerShell.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("2. Start a capture on Windows") {
                Text("Open PowerShell in the PresentMon folder. Replace game.exe with the game's real process name, then run this command and leave it open.")
                    .font(.subheadline).foregroundStyle(.secondary)
                command(captureCommand, id: "capture")
            }
            Section("3. Start Orbit Agent") {
                Text("Stop the agent if it is already running. Open another PowerShell window in the Orbit-Windows-Agent folder, set these variables, and start the agent from that window.")
                    .font(.subheadline).foregroundStyle(.secondary)
                command(agentCommand, id: "agent")
            }
            Section("4. Return to Orbit") {
                Text("Run the game, reconnect Orbit, and add the Game frame rate card in Customize dashboard. Keep both Windows windows open during the session.")
                Text("If the capture stops or the game cannot be detected, FPS becomes unavailable. The reading is application FPS, not a guarantee of displayed or generated frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up game FPS")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func command(_ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
            Button {
                UIPasteboard.general.string = text
                copiedCommand = id
            } label: {
                Label(copiedCommand == id ? "Copied" : "Copy PowerShell commands", systemImage: copiedCommand == id ? "checkmark" : "doc.on.doc")
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 6)
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

struct MonitoringSourcesView: View {
    @ObservedObject var vm: OrbitViewModel

    var body: some View {
        List {
            Section("Windows agent") {
                LabeledContent("Connection", value: vm.isDemoMode ? "Simulated preview" : (vm.metrics.isOnline ? "Connected" : "Unavailable"))
                LabeledContent("Reported version", value: vm.metrics.agentVersion ?? "Older agent or not connected")
                if vm.metrics.agentVersion == nil && !vm.isDemoMode {
                    Text("Copy the complete updated Orbit-Windows-Agent folder to your PC, stop the previous agent, then run start_agent.bat again. Updating the iPhone app does not update Windows automatically.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if vm.metrics.telemetryAvailable == false {
                    Text("The agent is reachable but has no recent telemetry sample. Readings stay unavailable until sampling resumes.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh connection", systemImage: "arrow.clockwise") { Task { await vm.refreshMetrics() } }
            }
            Section("Temperatures and power") {
                LabeledContent("CPU sensor provider", value: vm.metrics.sensorSource ?? "Not connected")
                LabeledContent("GPU sensor provider", value: vm.metrics.gpuSource ?? "Not connected")
                LabeledContent("CPU temperature", value: vm.metrics.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                LabeledContent("GPU temperature", value: vm.metrics.gpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                if let status = vm.metrics.sensorStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                Text("Recent LibreHardwareMonitor versions use a local web server. On the PC, open LibreHardwareMonitor and choose Options → Remote Web Server → Run. The default port is 8085. Run it as administrator if your hardware sensors need that access.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Orbit reads the local sensor data; it cannot create a temperature reading when the monitor or sensor is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Network traffic") {
                LabeledContent("Adapters", value: vm.metrics.networkInterface ?? "Waiting for interface counters")
                LabeledContent("Download", value: traffic(vm.metrics.networkDownloadMBps))
                LabeledContent("Upload", value: traffic(vm.metrics.networkUploadMBps))
                Text("The first sample needs one more reading to calculate speed. Traffic is measured in bytes per second: 1 MB/s equals 8 Mb/s. Very small transfers appear in B/s.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To monitor one specific adapter, set ORBIT_NETWORK_INTERFACE to its Windows name, for example Ethernet or Wi-Fi, before starting the agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Game FPS") {
                LabeledContent("Detected process", value: vm.metrics.activeGameProcess ?? "No game detected")
                LabeledContent("FPS", value: vm.metrics.fps.map { String(format: "%.1f", $0) } ?? "Unavailable")
                if let source = vm.metrics.fpsSource { LabeledContent("Source", value: source) }
                if vm.metrics.fps == nil {
                    Text(vm.metrics.fpsUnavailableReason ?? "Start PresentMon and configure its live CSV capture on the PC.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink { FPSSetupView(vm: vm) } label: { Label("Set up game FPS", systemImage: "speedometer") }
                Text("PresentMon must be recording while the game is running. Set ORBIT_PRESENTMON_CSV to the same file as PresentMon’s output. Orbit supports legacy, default and native v2 CSV formats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Monitoring sources")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func traffic(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        if value >= 1 { return String(format: "%.2f MB/s", value) }
        if value >= 0.001 { return String(format: "%.1f KB/s", value * 1000) }
        return String(format: "%.0f B/s", value * 1_000_000)
    }
}
