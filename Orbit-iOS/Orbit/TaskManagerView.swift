import SwiftUI

/// Every process on the PC, like Windows Task Manager: the busiest one first, searchable,
/// and End Task behind a confirmation.
struct TaskManagerView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var search = ""
    @State private var sortOrder: ProcessSortOrder = .memory
    @State private var inspected: PCProcess?
    @State private var ending: PCProcess?
    @Environment(\.scenePhase) private var scenePhase

    private var canEnd: Bool { vm.metrics.isOnline && !vm.isDemoMode && vm.endingProcessID == nil }

    private var processes: [PCProcess] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? vm.processes : vm.processes.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        return filtered.sorted(by: sortOrder.precedes)
    }

    private var busiest: PCProcess? {
        vm.processes.max { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let error = vm.processesError, vm.metrics.isOnline || vm.processes.isEmpty == false {
                Section { OrbitInlineStatus(text: error, kind: .problem) }
            }
            if let status = vm.processActionStatus {
                Section { OrbitInlineStatus(text: status, kind: .success) }
            }
            Section {
                if processes.isEmpty {
                    emptyRow
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(processes) { process in row(process) }
                }
            } header: {
                if !processes.isEmpty { columnHeader }
            } footer: {
                if let status = vm.processGpuStatus, vm.processes.contains(where: { $0.gpuPercent != nil }) == false, !vm.processes.isEmpty {
                    Text(status)
                }
            }
        }
        .listStyle(.insetGrouped)
        .orbitListBackground()
        .navigationTitle("Task Manager")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name or PID")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(ProcessSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .tint(.primary)
            }
        }
        .onChange(of: sortOrder) { _, _ in OrbitHaptics.selection() }
        .refreshable { await vm.fetchProcesses() }
        .task(id: vm.connectionID) {
            vm.prepareAppIcons()
            while !Task.isCancelled {
                if scenePhase == .active { await vm.fetchProcesses() }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: vm.connectionID) { _, _ in inspected = nil; ending = nil }
        .sheet(item: $inspected) { process in
            ProcessDetailSheet(vm: vm, processID: process.id, fallback: process)
        }
        .endTaskConfirmation($ending, vm: vm)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .contentTransition(.opacity)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .orbitLiveNumber()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if vm.processes.isEmpty {
            if !vm.metrics.isOnline && !vm.isDemoMode { return "Not connected" }
            return "Reading processes…"
        }
        if let busiest, let cpu = busiest.cpuPercent, cpu.isFinite, cpu >= 1 {
            return "\(busiest.name) is busiest · \(Int(cpu.rounded()))%"
        }
        return "Nothing is busy right now"
    }

    private var detail: String {
        if vm.processes.isEmpty && !vm.metrics.isOnline && !vm.isDemoMode {
            return "Connect to your PC to see what's running."
        }
        var parts: [String] = []
        if !vm.processes.isEmpty { parts.append("\(vm.processes.count) processes") }
        if vm.isDemoMode {
            parts.append("sample data")
        } else if let updated = vm.lastProcessesUpdated {
            parts.append("updated \(updated.formatted(date: .omitted, time: .standard))")
        }
        return parts.isEmpty ? "Orbit Companion lists them every few seconds." : parts.joined(separator: " · ")
    }

    // MARK: Rows

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(search.isEmpty ? sortOrder.sectionTitle : "Results")
            Spacer(minLength: 8)
            ForEach(sortOrder.columns, id: \.self) { column in
                Text(column.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: column.width, alignment: .trailing)
            }
        }
    }

    private func row(_ process: PCProcess) -> some View {
        Button {
            OrbitHaptics.tap()
            inspected = process
        } label: {
            ProcessRowLabel(store: vm.appIcons, process: process, columns: sortOrder.columns,
                            highlighted: sortOrder.highlighted, isEnding: vm.endingProcessID == process.pid)
        }
        .tint(.primary)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if process.canTerminate && canEnd {
                Button("End Task", systemImage: "xmark.circle", role: .destructive) { ending = process }
            }
        }
        .contextMenu {
            if process.canTerminate {
                Button("End Task", systemImage: "xmark.circle", role: .destructive) { ending = process }
                    .disabled(!canEnd)
            }
            Button("Copy Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = process.name }
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        if !search.isEmpty {
            OrbitEmptyMessage(systemImage: "magnifyingglass", title: "No matches", message: "Try another name or PID.")
        } else if !vm.metrics.isOnline && !vm.isDemoMode {
            OrbitEmptyMessage(systemImage: "desktopcomputer", title: "Your PC isn't connected",
                              message: "Wake it or check that Orbit Companion is running.")
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading processes…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Row

private struct ProcessRowLabel: View {
    @ObservedObject var store: OrbitAppIconStore
    var process: PCProcess
    var columns: [ProcessColumn]
    var highlighted: ProcessColumn?
    var isEnding: Bool

    var body: some View {
        HStack(spacing: 10) {
            OrbitAppIconView(store: store, iconID: process.iconID, size: 30) {
                Image(systemName: "app")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            HStack(spacing: 5) {
                Text(process.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !process.canTerminate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Protected")
                }
            }
            Spacer(minLength: 8)
            if isEnding {
                ProgressView()
            } else {
                ForEach(columns, id: \.self) { column in
                    Text(column.value(process) ?? "—")
                        .font(highlighted == column ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(highlighted == column ? Color.primary : Color.secondary)
                        .orbitLiveNumber()
                        .lineLimit(1)
                        .frame(minWidth: column.width, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details and End Task")
    }
}

// MARK: - Detail

/// One process up close: what it uses, and End Task when Windows allows it.
private struct ProcessDetailSheet: View {
    @ObservedObject var vm: OrbitViewModel
    var processID: String
    var fallback: PCProcess
    @State private var ending: PCProcess?
    @Environment(\.dismiss) private var dismiss

    /// The latest reading of this process, while it still runs.
    private var process: PCProcess { vm.processes.first { $0.id == processID } ?? fallback }
    private var isRunning: Bool { vm.processes.contains { $0.id == processID } }
    private var canEnd: Bool { vm.metrics.isOnline && !vm.isDemoMode && vm.endingProcessID == nil && isRunning }

    private var readings: [(String, String, String)] {
        var list: [(String, String, String)] = []
        if let cpu = OrbitFormat.percent(process.cpuPercent) { list.append(("CPU", cpu, "%")) }
        if let gpu = OrbitFormat.percent(process.gpuPercent) { list.append(("GPU", gpu, "%")) }
        if let memory = Self.size(process.memoryMB) { list.append(("Memory", memory.0, memory.1)) }
        if let video = Self.size(process.vramMB), (process.vramMB ?? 0) > 0 { list.append(("Video Memory", video.0, video.1)) }
        return list
    }

    var body: some View {
        NavigationStack {
            OrbitPage(spacing: 22) {
                HStack(spacing: 14) {
                    OrbitAppIconView(store: vm.appIcons, iconID: process.iconID, size: 52) {
                        Image(systemName: "app")
                            .font(.title)
                            .foregroundStyle(.secondary)
                            .frame(width: 52, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(process.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(isRunning ? "\(process.status.capitalized) · PID \(String(process.pid))" : "No longer running")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                if !readings.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                                        GridItem(.flexible(), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        ForEach(readings, id: \.0) { label, value, unit in
                            OrbitReading(label: label, value: value, unit: unit, valueSize: 30)
                        }
                    }
                    .orbitSurface()
                }

                if let engine = process.gpuEngine, !engine.isEmpty {
                    OrbitRows {
                        OrbitValueRow("Graphics Engine", engine)
                        if let shared = OrbitScreenFormat.megabytes(process.sharedGpuMemoryMB), (process.sharedGpuMemoryMB ?? 0) > 0 {
                            OrbitValueRow("Shared Video Memory", shared)
                        }
                    }
                    .orbitSurface(padding: 16, radius: 22)
                }

                if process.canTerminate {
                    Button(role: .destructive) {
                        OrbitHaptics.press()
                        ending = process
                    } label: {
                        Label("End Task", systemImage: "xmark.circle")
                            .font(.headline)
                            .foregroundStyle(OrbitPalette.critical)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .orbitGlassButton()
                    .disabled(!canEnd)
                    Text("Ending a task closes it on the PC without saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    OrbitInlineStatus(text: "Windows protects this process, so Orbit can't end it.")
                        .padding(.horizontal, 4)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .orbitCloseButton { dismiss() }
            .endTaskConfirmation($ending, vm: vm) { dismiss() }
        }
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
    }

    private static func size(_ megabytes: Double?) -> (String, String)? {
        guard let megabytes, megabytes.isFinite, megabytes >= 0 else { return nil }
        if megabytes >= 1024 { return ((megabytes / 1024).formatted(.number.precision(.fractionLength(1))), "GB") }
        return (String(Int(megabytes.rounded())), "MB")
    }
}

// MARK: - End task

private extension View {
    /// Asks before ending a process; `after` runs once the request is on its way.
    func endTaskConfirmation(_ process: Binding<PCProcess?>, vm: OrbitViewModel, after: @escaping () -> Void = {}) -> some View {
        confirmationDialog("End \(process.wrappedValue?.name ?? "this task")?", isPresented: Binding(
            get: { process.wrappedValue != nil }, set: { if !$0 { process.wrappedValue = nil } }
        ), titleVisibility: .visible) {
            if let target = process.wrappedValue {
                Button("End Task", role: .destructive) {
                    process.wrappedValue = nil
                    OrbitHaptics.warning()
                    // The latest copy of the process: ending checks it is still the same one.
                    let current = vm.processes.first { $0.id == target.id } ?? target
                    Task { await vm.endProcess(current) }
                    after()
                }
            }
            Button("Cancel", role: .cancel) { process.wrappedValue = nil }
        } message: {
            Text("Unsaved work in it may be lost.")
        }
    }
}

// MARK: - Sorting

private enum ProcessColumn: Hashable {
    case cpu, memory, gpu, vram

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .vram: return "Video Memory"
        }
    }

    var width: CGFloat {
        switch self {
        case .cpu, .gpu: return 40
        case .memory, .vram: return 62
        }
    }

    func value(_ process: PCProcess) -> String? {
        switch self {
        case .cpu: return OrbitScreenFormat.percent(process.cpuPercent)
        case .gpu: return OrbitScreenFormat.percent(process.gpuPercent)
        case .memory: return OrbitScreenFormat.megabytes(process.memoryMB)
        case .vram: return OrbitScreenFormat.megabytes(process.vramMB)
        }
    }
}

private enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case memory, cpu, gpu, vram, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .vram: return "Video Memory"
        case .name: return "Name"
        }
    }

    var sectionTitle: String {
        switch self {
        case .name: return "By Name"
        default: return "By \(title)"
        }
    }

    /// Two columns per row: the processor and memory, or the graphics card and its memory.
    var columns: [ProcessColumn] {
        switch self {
        case .gpu, .vram: return [.gpu, .vram]
        default: return [.cpu, .memory]
        }
    }

    var highlighted: ProcessColumn? {
        switch self {
        case .memory: return .memory
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .vram: return .vram
        case .name: return nil
        }
    }

    func precedes(_ left: PCProcess, _ right: PCProcess) -> Bool {
        switch self {
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
