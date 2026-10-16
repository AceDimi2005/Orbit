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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    Text(process.cpuPercent.flatMap { $0.isFinite ? String(format: "CPU %.1f%%", $0) : nil } ?? "CPU —")
                    Text(process.gpuPercent.flatMap { $0.isFinite ? String(format: "GPU %.1f%%", $0) : nil } ?? "GPU —")
                    Text(process.memoryMB.flatMap { $0.isFinite ? String(format: "RAM %.0f MB", $0) : nil } ?? "RAM —")
                }
                HStack(spacing: 18) {
                    Text(process.vramMB.flatMap { $0.isFinite ? String(format: "VRAM %.0f MB", $0) : nil } ?? "VRAM —")
                    Text(process.sharedGpuMemoryMB.flatMap { $0.isFinite ? String(format: "Shared GPU %.0f MB", $0) : nil } ?? "Shared GPU —")
                }
                if let engine = process.gpuEngine { Text("Busiest engine · \(engine)").font(.caption2).foregroundStyle(.secondary) }
                if !process.canTerminate { Text("Protected").foregroundStyle(.secondary) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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
            Section("MSI Afterburner + RTSS") {
                Text("Orbit Agent 3.2.0 reads FPS from RivaTuner Statistics Server automatically and supported sensors from MSI Afterburner. No CSV or pairing code is needed between these apps.")
                Text("Update the complete Windows agent folder first. The iPhone still connects to Orbit Agent with your existing PC address and pairing token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("1. Install and open both apps") {
                Link("Get MSI Afterburner from MSI", destination: URL(string: "https://www.msi.com/Landing/afterburner/graphics-cards")!)
                Text("Include RivaTuner Statistics Server (RTSS) during installation. Keep both apps running on the PC, in the same Windows user session as Orbit Agent.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("2. Enable monitoring") {
                Text("In Afterburner → Settings → Monitoring, tick the sensors you want under Active hardware monitoring graphs, including CPU/GPU temperature and Framerate when available. Click Apply.")
                Text("Show in On-Screen Display is optional if you want to check the readings on the PC. Orbit cannot read sensors that Afterburner does not expose; CPU power, VRAM capacity and fan readings depend on your hardware.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("3. Open a game") {
                Text("Open RTSS from the system tray. Set Application detection level to Low for the game and keep RTSS running. Show own statistics can be enabled temporarily to check that RTSS detects the game.")
                Text("Run the game, reconnect Orbit, and enable Game frame rate in Customize dashboard. Check Monitoring sources for the selected provider or the reason a reading is missing.")
                Text("Some games or anti-cheat systems block RTSS. FPS describes the application's frame rate and does not guarantee displayed or generated frames. PresentMon remains available below as a fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced: PresentMon CSV fallback") {
                    Text("Use this if RTSS cannot provide a recent reading. RTSS has priority when both sources are available.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Open official PresentMon releases", destination: URL(string: "https://github.com/GameTechDev/PresentMon/releases")!)
                    Text("Download the Console executable and rename it PresentMon.exe. Open PowerShell in its folder. Use the real game executable from Windows Task Manager → Details; this example uses \(processName). Start the capture and leave it open.")
                        .font(.caption).foregroundStyle(.secondary)
                    command(captureCommand, id: "capture")
                    Text("Stop Orbit Agent. In another PowerShell window in Orbit-Windows-Agent, set ORBIT_PRESENTMON_CSV and start the agent from that window.")
                        .font(.caption).foregroundStyle(.secondary)
                    command(agentCommand, id: "agent")
                    Text("Keep the game, capture and agent running. The CSV must contain recent frames for the game. Legacy, default and native v2 PresentMon CSV formats are supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Link("MSI monitoring guide", destination: URL(string: "https://www.msi.com/blog/msi-afterburner-on-screen-display/")!)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up FPS")
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
                if needsAgentUpdate && !vm.isDemoMode {
                    Text("MSI Afterburner and RTSS support needs Orbit Agent 3.2.0 or later. Stop the previous agent, copy the complete updated Orbit-Windows-Agent folder to your PC, then run start_agent.bat again. Updating the iPhone app does not update Windows automatically.")
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
                Text("Keep MSI Afterburner running and enable the desired sensors in Settings → Monitoring. Supported readings are detected automatically; NVIDIA driver readings take priority for GPU.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Optional: LibreHardwareMonitor sensors") {
                    Text("Use LibreHardwareMonitor if Afterburner does not expose a needed sensor. For recent versions, choose Options → Remote Web Server → Run on port 8085 and keep it open. Run as administrator if the sensors require it. Orbit reads available measurements and cannot create a missing sensor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink { FPSSetupView(vm: vm) } label: { Label("Set up Afterburner and RTSS", systemImage: "slider.horizontal.3") }
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
                    Text(vm.metrics.fpsUnavailableReason ?? "Keep RTSS running and open a game. Use Set up FPS to check the Windows setup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink { FPSSetupView(vm: vm) } label: { Label("Set up FPS", systemImage: "speedometer") }
                Text("RTSS is read automatically on the PC. PresentMon CSV is an optional fallback. Neither method requires a connection from the phone directly to Afterburner or RTSS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Monitoring sources")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var needsAgentUpdate: Bool {
        guard let version = vm.metrics.agentVersion else { return true }
        return version.compare("3.2.0", options: .numeric) == .orderedAscending
    }
    private func traffic(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        if value >= 1 { return String(format: "%.2f MB/s", value) }
        if value >= 0.001 { return String(format: "%.1f KB/s", value * 1000) }
        return String(format: "%.0f B/s", value * 1_000_000)
    }
}
