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

    @Environment(\.orbitTheme) private var theme

    private var topConsumer: PCProcess? {
        vm.processes.max { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: "list.bullet.rectangle.portrait.fill", tint: .orange, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(vm.processes.count) processes")
                            .font(.headline.weight(.bold))
                            .contentTransition(.numericText())
                        if let top = topConsumer, let cpu = top.cpuPercent, cpu.isFinite {
                            Text("Busiest: \(top.name) · \(String(format: "%.0f%% CPU", cpu))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if let updated = vm.lastProcessesUpdated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if vm.isLoadingProcesses { ProgressView().tint(theme.accent) }
                }
                .padding(.vertical, 2)
                if vm.isDemoMode {
                    Label("Preview processes · no PC actions", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Sort processes", selection: $sortOrder) {
                    ForEach(ProcessSortOrder.allCases) { order in Text(order.title).tag(order) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sortOrder) { _, _ in OrbitHaptics.selection() }
                if let status = vm.processGpuStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .orbitRow(tint: .orange)
            if let error = vm.processesError {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    .orbitRow(tint: .orange)
            }
            if let status = vm.processActionStatus {
                Section { Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.mint) }
                    .orbitRow(tint: .mint)
            }
            Section("Running processes") {
                if vm.isLoadingProcesses && vm.processes.isEmpty {
                    HStack { ProgressView(); Text("Reading running processes…").padding(.leading, 8) }
                } else if sortedProcesses.isEmpty {
                    OrbitEmptyState(icon: search.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                                    title: search.isEmpty ? "No processes available" : "No matching processes",
                                    message: search.isEmpty ? "Keep Orbit Agent running on your PC." : "Try another name or PID.",
                                    tint: .orange)
                } else {
                    ForEach(sortedProcesses) { process in processRow(process) }
                }
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                OrbitIconBadge(systemName: process.canTerminate ? "app.fill" : "lock.shield.fill", tint: process.canTerminate ? theme.accent : .secondary, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("PID \(process.pid) · \(process.status)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if vm.endingProcessID == process.pid {
                    ProgressView()
                } else if process.canTerminate {
                    Button("End task") { selectedProcess = process }
                        .buttonStyle(OrbitGlassButtonStyle(tint: .red, cornerRadius: 18))
                        .font(.caption.weight(.bold))
                        .disabled(vm.endingProcessID != nil || !vm.metrics.isOnline || vm.isDemoMode)
                        .accessibilityLabel("End task: \(process.name), PID \(process.pid)")
                } else {
                    Text("Protected")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.05), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                usageChip("CPU", value: process.cpuPercent, unit: "%", fraction: process.cpuPercent.map { $0 / 100 }, tint: .cyan)
                usageChip("GPU", value: process.gpuPercent, unit: "%", fraction: process.gpuPercent.map { $0 / 100 }, tint: .mint)
                usageChip("RAM", value: process.memoryMB, unit: " MB", fraction: process.memoryMB.flatMap { mb in vm.metrics.ramTotalGB > 0 ? mb / (vm.metrics.ramTotalGB * 1024) : nil }, tint: Color(red: 0.68, green: 0.65, blue: 0.98), digits: 0)
                if let vram = process.vramMB, vram.isFinite, vram > 0 {
                    usageChip("VRAM", value: vram, unit: " MB", fraction: vm.metrics.vramTotalGB.flatMap { total in total > 0 ? vram / (total * 1024) : nil }, tint: .orange, digits: 0)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func usageChip(_ label: String, value: Double?, unit: String, fraction: Double?, tint: Color, digits: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(value.flatMap { $0.isFinite ? String(format: "%.\(digits)f%@", $0, unit) : nil } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    if let fraction, fraction.isFinite {
                        Capsule().fill(tint.gradient)
                            .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: "speedometer", tint: .mint, size: 36, filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic FPS & Sensor Reading").font(.subheadline.weight(.semibold))
                        Text(vm.metrics.fps.map { String(format: "Live: %.0f FPS", $0) } ?? "No FPS reading yet")
                            .font(.caption).foregroundStyle(vm.metrics.fps == nil ? .secondary : .mint)
                    }
                }
                Text("Install MSI Afterburner with RivaTuner Statistics Server (RTSS) included, and keep both open on your PC.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Download MSI Afterburner", destination: URL(string: "https://www.msi.com/Landing/afterburner/graphics-cards")!)
                    .font(.subheadline)
            }
            .orbitRow(tint: .mint)
            Section("Quick Checklist") {
                Label("1. In Afterburner → Settings → Monitoring, enable CPU/GPU Temp & Framerate.", systemImage: "1.circle.fill")
                    .font(.caption)
                Label("2. Keep RTSS running in the Windows system tray with Application detection level set to Low.", systemImage: "2.circle.fill")
                    .font(.caption)
                Label("3. Enable Game frame rate in Customize Dashboard.", systemImage: "3.circle.fill")
                    .font(.caption)
            }
            .orbitRow()
            Section {
                DisclosureGroup("Advanced: PresentMon CSV fallback") {
                    Text("Use PresentMon if RTSS is blocked by anti-cheat.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("PresentMon Releases", destination: URL(string: "https://github.com/GameTechDev/PresentMon/releases")!)
                    command(captureCommand, id: "capture")
                    command(agentCommand, id: "agent")
                }
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
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
                HStack {
                    Text("Connection")
                    Spacer()
                    OrbitStatusPill(
                        text: vm.isDemoMode ? "Simulated preview" : (vm.metrics.isOnline ? "Connected" : "Unavailable"),
                        tint: vm.metrics.isOnline && !vm.isDemoMode ? .mint : .orange,
                        pulsing: vm.metrics.isOnline && !vm.isDemoMode
                    )
                }
                LabeledContent("Version", value: vm.metrics.agentVersion ?? "Not connected")
                if vm.metrics.telemetryAvailable == false {
                    Text("Agent reachable, waiting for telemetry sample.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh connection", systemImage: "arrow.clockwise") { Task { await vm.refreshMetrics() } }
            }
            .orbitRow()
            Section("Temperatures & Sensors") {
                LabeledContent("CPU sensor", value: vm.metrics.sensorSource ?? "Not connected")
                LabeledContent("GPU sensor", value: vm.metrics.gpuSource ?? "Not connected")
                LabeledContent("CPU temp", value: vm.metrics.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                LabeledContent("GPU temp", value: vm.metrics.gpuTemp.map { String(format: "%.1f°C", $0) } ?? "Unavailable")
                if let status = vm.metrics.sensorStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                NavigationLink { FPSSetupView(vm: vm) } label: { Label("Set up Afterburner & RTSS", systemImage: "slider.horizontal.3") }
            }
            .orbitRow()
            Section("Network & Game FPS") {
                LabeledContent("Adapter", value: vm.metrics.networkInterface ?? "Auto")
                LabeledContent("Download", value: traffic(vm.metrics.networkDownloadMBps))
                LabeledContent("Upload", value: traffic(vm.metrics.networkUploadMBps))
                LabeledContent("Detected game", value: vm.metrics.activeGameProcess ?? "None")
                LabeledContent("FPS", value: vm.metrics.fps.map { String(format: "%.1f", $0) } ?? "Unavailable")
                if let source = vm.metrics.fpsSource { LabeledContent("FPS source", value: source) }
            }
            .orbitRow()
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
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
