import AppKit
import SwiftUI

/// Task manager: searchable, sortable process table with auto-refresh and End Task.
/// Readings the agent does not report are shown as "—", never estimated.
struct MacProcessesView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @AppStorage("mac.processesAutoRefresh") private var autoRefresh = true
    @AppStorage("mac.processesInterval") private var interval = 5
    @State private var query = ""
    @State private var selection = Set<MacProcess.ID>()
    @State private var sortOrder: [KeyPathComparator<MacProcess>] = [KeyPathComparator(\MacProcess.cpuSortValue, order: .reverse)]
    @State private var pendingEnd: [MacProcess] = []
    @State private var showsEndDialog = false
    @FocusState private var searchFocused: Bool

    private static let intervals = [2, 5, 10]

    var body: some View {
        Group {
            if vm.currentPC == nil && !vm.isDemoMode {
                MacPage { notPairedState }
            } else if !vm.metrics.isOnline {
                MacPage { offlineState }
            } else {
                content
            }
        }
        .task(id: refreshKey) { await runRefreshLoop() }
        .task(id: vm.processActionStatus) { await autoDismissActionStatus() }
        .onChange(of: vm.selectedPCID) { _, _ in
            selection = []
            query = ""
            pendingEnd = []
            showsEndDialog = false
            Task { await vm.refreshProcesses() }
        }
        .onChange(of: vm.processes) { _, processes in
            let ids = Set(processes.map(\.id))
            selection = selection.filter { ids.contains($0) }
        }
        .confirmationDialog(endDialogTitle, isPresented: $showsEndDialog, titleVisibility: .visible) {
            Button(endButtonTitle, role: .destructive) { confirmEnd() }
            Button("Cancel", role: .cancel) { pendingEnd = [] }
        } message: {
            Text(endDialogMessage)
        }
    }

    // MARK: - Derived state

    private var pcName: String { vm.isDemoMode ? "Example PC" : (vm.currentPC?.name ?? vm.metrics.hostname) }
    private var dangerTint: Color { Color(red: 1.0, green: 0.45, blue: 0.48) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Processes matching the search box, unsorted.
    private var matching: [MacProcess] {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return vm.processes }
        return vm.processes.filter { $0.name.lowercased().contains(needle) || String($0.pid).contains(needle) }
    }
    private var filtered: [MacProcess] { matching.sorted(using: sortOrder) }
    private var selectedProcesses: [MacProcess] { vm.processes.filter { selection.contains($0.id) } }
    private var canEndSelection: Bool {
        !selectedProcesses.isEmpty && selectedProcesses.allSatisfy(\.canTerminate) && vm.endingProcessID == nil
    }
    /// Demo mode simulates Wake-on-LAN in `vm.wakePC()`, so it can always "wake".
    private var canWake: Bool { vm.isDemoMode || !(vm.currentPC?.macAddress.isEmpty ?? true) }
    private var isLive: Bool { autoRefresh && vm.metrics.isOnline && !vm.isDemoMode }
    private var statusPillText: String { vm.isDemoMode ? "Demo" : (isLive ? "Live" : "Paused") }
    private var statusPillTint: Color {
        if vm.isDemoMode { return .orange }
        return isLive ? .mint : .secondary
    }
    private var capturedText: String {
        vm.processesCapturedAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—"
    }

    private var cpuTotal: Double? {
        let values = vm.processes.compactMap(\.cpuPercent).filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private var memoryTotalMB: Double? {
        let values = vm.processes.compactMap(\.memoryMB).filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private var topProcess: MacProcess? {
        vm.processes.filter { $0.cpuPercent != nil }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
    }
    private var processCountText: String {
        let total = vm.processes.count
        return trimmedQuery.isEmpty ? "\(total)" : "\(matching.count) of \(total)"
    }

    private var refreshKey: MacProcessesRefreshKey {
        MacProcessesRefreshKey(enabled: autoRefresh, interval: interval, pcID: vm.selectedPCID, online: vm.metrics.isOnline, demo: vm.isDemoMode)
    }

    private var headerSubtitle: String? {
        if vm.isDemoMode { return "Demo mode · simulated processes" }
        guard let captured = vm.processesCapturedAt else { return vm.isLoadingProcesses ? "Reading processes…" : nil }
        let total = vm.processes.count
        var parts = ["\(total) process\(total == 1 ? "" : "es")"]
        if !trimmedQuery.isEmpty { parts.append("\(matching.count) match\(matching.count == 1 ? "" : "es")") }
        parts.append("captured \(captured.formatted(date: .omitted, time: .standard))")
        parts.append(autoRefresh ? "auto-refresh every \(interval) s" : "auto-refresh off")
        return parts.joined(separator: " · ")
    }

    private var endDialogTitle: String {
        if pendingEnd.count == 1, let process = pendingEnd.first { return "End \(process.name)?" }
        return "End \(pendingEnd.count) tasks?"
    }
    private var endButtonTitle: String { pendingEnd.count == 1 ? "End Task" : "End \(pendingEnd.count) Tasks" }
    private var endDialogMessage: String {
        let names = pendingEnd.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
        return "Orbit will terminate \(names) on \(pcName). Any unsaved work in the application will be lost."
    }
    private var endHelpText: String {
        if vm.endingProcessID != nil { return "Waiting for the previous End Task to finish" }
        if selectedProcesses.isEmpty { return "Select a process to end it (⌘⌫)" }
        if !selectedProcesses.allSatisfy(\.canTerminate) { return "The selection includes a protected process that cannot be ended" }
        return "End the selected task (⌘⌫)"
    }

    private var emptyMessage: String {
        vm.isDemoMode ? "The simulated process list is empty." : "The PC did not report any running applications. Refresh to ask again."
    }
    private var emptyActionTitle: String? { vm.isDemoMode ? nil : "Refresh" }

    private var offlineTitle: String { vm.isWaking ? "Waking \(pcName)…" : "\(pcName) is offline" }
    private var offlineMessage: String {
        if canWake { return "Send a Wake-on-LAN packet to see what is running on the PC, or retry the connection from the Overview." }
        return "Connect to your PC to see its running applications. Orbit saves the MAC address for Wake-on-LAN after the first connection."
    }
    private var offlineActionTitle: String? {
        if vm.isWaking { return nil }
        return canWake ? "Power On" : "Retry"
    }

    // MARK: - Async helpers

    @MainActor
    private func runRefreshLoop() async {
        await vm.refreshProcesses()
        guard autoRefresh, !vm.isDemoMode else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(max(1, interval))) } catch { return }
            guard vm.metrics.isOnline else { return }
            await vm.refreshProcesses()
        }
    }

    @MainActor
    private func autoDismissActionStatus() async {
        guard vm.processActionStatus != nil else { return }
        do { try await Task.sleep(for: .seconds(8)) } catch { return }
        vm.processActionStatus = nil
    }

    // MARK: - Actions

    private func requestEnd(_ processes: [MacProcess]) {
        let targets = processes.filter(\.canTerminate)
        guard !targets.isEmpty, vm.endingProcessID == nil else { return }
        pendingEnd = targets
        showsEndDialog = true
    }

    private func confirmEnd() {
        let targets = pendingEnd
        pendingEnd = []
        showsEndDialog = false
        guard !targets.isEmpty else { return }
        Task {
            for process in targets { await vm.endProcess(process) }
        }
    }

    private func performOfflineAction() {
        if canWake {
            Task { await vm.wakePC() }
        } else {
            Task { await vm.refreshMetrics() }
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Process helpers

    private static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".exe") { value.removeLast(4) }
        return value
    }

    private func isActiveGame(_ process: MacProcess) -> Bool {
        let name = Self.normalized(process.name)
        guard !name.isEmpty else { return false }
        let candidates = [vm.metrics.activeGame, vm.metrics.activeGameProcess].compactMap { $0 }.map(Self.normalized).filter { !$0.isEmpty }
        return candidates.contains(name)
    }

    private func glyph(for process: MacProcess) -> String {
        if isActiveGame(process) { return "gamecontroller.fill" }
        return process.canTerminate ? "app.fill" : "lock.shield.fill"
    }

    private func badgeTint(for process: MacProcess) -> Color {
        if isActiveGame(process) { return .mint }
        return process.canTerminate ? theme.accent : .secondary
    }

    private func meterTint(for cpu: Double?) -> Color {
        guard let cpu, cpu.isFinite else { return theme.accent }
        if cpu >= 80 { return dangerTint }
        if cpu >= 40 { return .orange }
        return theme.accent
    }

    private static func memoryLabel(_ megabytes: Double?) -> String {
        guard let megabytes, megabytes.isFinite, megabytes >= 0 else { return "—" }
        if megabytes >= 1024 { return "\(MacFormat.decimal(megabytes / 1024, digits: 1)) GB" }
        return "\(Int(megabytes.rounded())) MB"
    }

    private func detailLine(_ process: MacProcess) -> String {
        var parts = ["PID \(process.pid)", process.status.capitalized]
        if let started = process.startedDate { parts.append("since \(started.formatted(date: .abbreviated, time: .shortened))") }
        if let engine = process.gpuEngine, !engine.isEmpty { parts.append("GPU \(engine)") }
        if let vram = process.vramMB, vram.isFinite, vram > 0 { parts.append("VRAM \(Self.memoryLabel(vram))") }
        if let shared = process.sharedGpuMemoryMB, shared.isFinite, shared > 0 { parts.append("shared \(Self.memoryLabel(shared))") }
        if !process.canTerminate { parts.append("protected") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Happy path layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            notices
            summaryRow
            tableCard
        }
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        MacSectionHeader("Running applications", subtitle: headerSubtitle, icon: "list.bullet.rectangle.portrait.fill") {
            HStack(spacing: 8) {
                MacStatusPill(text: statusPillText, tint: statusPillTint, pulsing: isLive)
                    .id(isLive) // MacStatusPill only starts its pulse onAppear; re-create it when Live toggles.
                searchField
                Toggle(isOn: $autoRefresh) { Text("Auto") }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Refresh the list automatically while this page is open")
                Picker("Interval", selection: $interval) {
                    ForEach(Self.intervals, id: \.self) { seconds in
                        Text("\(seconds) s").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 66)
                .disabled(!autoRefresh)
                .help("Auto-refresh interval")
                .accessibilityLabel("Auto-refresh interval")
                refreshButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Button {
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("Search processes (⌘F)")
            .accessibilityLabel("Search processes")
            TextField("Name or PID", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.callout))
                .focused($searchFocused)
                .onExitCommand {
                    query = ""
                    searchFocused = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 200)
        .background(.white.opacity(searchFocused ? 0.10 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(searchFocused ? theme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var refreshButton: some View {
        Button {
            Task { await vm.refreshProcesses() }
        } label: {
            if vm.isLoadingProcesses {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(MacIconButtonStyle(size: 26))
        .disabled(vm.isLoadingProcesses)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Refresh processes (⇧⌘R)")
        .accessibilityLabel("Refresh processes")
    }

    @ViewBuilder
    private var notices: some View {
        if let error = vm.processesError {
            dismissible(MacNotice(title: "Processes unavailable", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)) {
                vm.processesError = nil
            }
        }
        if let status = vm.processActionStatus {
            dismissible(MacNotice(title: "End Task", message: status, icon: "checkmark.circle.fill", tint: theme.accent)) {
                vm.processActionStatus = nil
            }
        }
    }

    private func dismissible<Content: View>(_ notice: Content, dismiss: @escaping () -> Void) -> some View {
        notice.overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MacIconButtonStyle(size: 22))
            .padding(8)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    MacStatChip(label: "Processes", value: processCountText, icon: "square.stack.3d.up.fill", tint: theme.accent)
                    MacStatChip(label: "CPU", value: MacFormat.percent(cpuTotal), icon: "cpu", tint: MacMetric.cpuLoad.accent)
                    MacStatChip(label: "Memory", value: Self.memoryLabel(memoryTotalMB), icon: "memorychip", tint: MacMetric.memory.accent)
                    MacStatChip(label: "Top", value: topProcess?.name ?? "—", icon: "flame.fill", tint: .orange)
                    MacStatChip(label: "Captured", value: capturedText, icon: "clock")
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 12) {
                if let captured = vm.processesCapturedAt {
                    (Text("Updated ") + Text(captured, style: .relative) + Text(" ago"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let status = vm.processGpuStatus, !status.isEmpty {
                    Label(status, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Table card

    private var tableCard: some View {
        VStack(spacing: 0) {
            tableToolbar
            Divider().overlay(.white.opacity(0.08))
            tableBody
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .macGlass(cornerRadius: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tableToolbar: some View {
        HStack(spacing: 10) {
            if selectedProcesses.count == 1, let process = selectedProcesses.first {
                selectionSummary(process)
            } else if selectedProcesses.count > 1 {
                Text("\(selectedProcesses.count) processes selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a process to inspect it or end it. Right-click for more options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if vm.endingProcessID != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Ending…")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
            Button {
                copy(selectedProcesses.map(\.name).joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(MacIconButtonStyle(size: 26))
            .disabled(selectedProcesses.isEmpty)
            .help("Copy process name")
            .accessibilityLabel("Copy process name")
            Button {
                requestEnd(selectedProcesses)
            } label: {
                Label("End Task…", systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(MacHoverButtonStyle(tint: dangerTint))
            .disabled(!canEndSelection)
            .keyboardShortcut(.delete, modifiers: .command)
            .help(endHelpText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func selectionSummary(_ process: MacProcess) -> some View {
        HStack(spacing: 8) {
            MacIconBadge(systemName: glyph(for: process), tint: badgeTint(for: process), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.system(.caption, weight: .bold))
                    .lineLimit(1)
                Text(detailLine(process))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var tableBody: some View {
        if vm.isLoadingProcesses && vm.processes.isEmpty {
            loadingState
        } else if vm.processes.isEmpty {
            MacEmptyState(
                icon: "list.bullet.rectangle.portrait",
                title: "No processes reported",
                message: emptyMessage,
                tint: theme.accent,
                actionTitle: emptyActionTitle
            ) {
                Task { await vm.refreshProcesses() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matching.isEmpty {
            VStack(spacing: 8) {
                Text("No processes match “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear Search") { query = "" }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            processTable
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading processes from \(pcName)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var processTable: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { process in
                nameCell(process)
            }
            .width(min: 180, ideal: 280)
            TableColumn("PID", value: \.pid) { process in
                Text(verbatim: String(process.pid))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 72, max: 96)
            TableColumn("CPU", value: \.cpuSortValue) { process in
                cpuCell(process)
            }
            .width(min: 116, ideal: 150, max: 220)
            TableColumn("Memory", value: \.memorySortValue) { process in
                Text(Self.memoryLabel(process.memoryMB))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 84, ideal: 104, max: 150)
            TableColumn("GPU", value: \.gpuSortValue) { process in
                gpuCell(process)
            }
            .width(min: 84, ideal: 130, max: 200)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: MacProcess.ID.self) { ids in
            contextMenuItems(for: ids)
        }
    }

    private func nameCell(_ process: MacProcess) -> some View {
        let ending = vm.endingProcessID == process.pid
        return HStack(spacing: 8) {
            if ending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                MacIconBadge(systemName: glyph(for: process), tint: badgeTint(for: process), size: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(process.name)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(ending ? Color.orange : Color.white.opacity(0.92))
                    .lineLimit(1)
                if ending {
                    Text("Ending…").font(.caption2).foregroundStyle(.orange)
                } else if isActiveGame(process) {
                    Text("Playing now").font(.caption2).foregroundStyle(.mint)
                } else if !process.canTerminate {
                    Text("Protected").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(ending ? 0.75 : 1)
    }

    private func cpuCell(_ process: MacProcess) -> some View {
        HStack(spacing: 8) {
            MacProcessesMeter(fraction: process.cpuFraction, tint: meterTint(for: process.cpuPercent))
                .frame(width: 64, height: 5)
            Text(MacFormat.percent(process.cpuPercent))
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPU \(MacFormat.percent(process.cpuPercent))")
    }

    private func gpuCell(_ process: MacProcess) -> some View {
        HStack(spacing: 6) {
            Text(MacFormat.percent(process.gpuPercent))
                .font(.callout.monospacedDigit())
            if let vram = process.vramMB, vram.isFinite, vram > 0 {
                Text(Self.memoryLabel(vram))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<MacProcess.ID>) -> some View {
        let targets = vm.processes.filter { ids.contains($0.id) }
        if targets.isEmpty {
            Button("Refresh") { Task { await vm.refreshProcesses() } }
        } else {
            Button(targets.count == 1 ? "End Task…" : "End \(targets.count) Tasks…", role: .destructive) {
                requestEnd(targets)
            }
            .disabled(!targets.allSatisfy(\.canTerminate) || vm.endingProcessID != nil)
            Divider()
            Button(targets.count == 1 ? "Copy Name" : "Copy Names") {
                copy(targets.map(\.name).joined(separator: "\n"))
            }
            Button(targets.count == 1 ? "Copy PID" : "Copy PIDs") {
                copy(targets.map { String($0.pid) }.joined(separator: "\n"))
            }
            if targets.count == 1, let process = targets.first {
                Button("Copy Details") { copy("\(process.name) · \(detailLine(process))") }
            }
        }
    }

    // MARK: - Not paired / offline

    private var notPairedState: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSectionHeader("Running applications", icon: "list.bullet.rectangle.portrait.fill")
            MacEmptyState(
                icon: "list.bullet.rectangle.portrait",
                title: "Pair your PC",
                message: "Running applications on your Windows PC appear here once Orbit is connected. Import the PC you paired on iPhone, or pair directly with the 6-digit code shown by Orbit Agent.",
                tint: theme.accent,
                actionTitle: "Pair or import a PC"
            ) {
                vm.selectedSection = .pcs
            }
            .macGlass(cornerRadius: 22, tint: theme.accent, elevated: true)
        }
    }

    private var offlineState: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSectionHeader("Running applications", subtitle: vm.connectionError, icon: "list.bullet.rectangle.portrait.fill")
            VStack(spacing: 6) {
                MacEmptyState(
                    icon: "power",
                    title: offlineTitle,
                    message: offlineMessage,
                    tint: .orange,
                    actionTitle: offlineActionTitle
                ) {
                    performOfflineAction()
                }
                if vm.isWaking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 20)
                }
            }
            .macGlass(cornerRadius: 22, tint: .orange, elevated: true)
        }
    }
}

// MARK: - Helpers

/// Identity of the auto-refresh loop; any change restarts the `.task`.
private struct MacProcessesRefreshKey: Hashable {
    var enabled: Bool
    var interval: Int
    var pcID: String
    var online: Bool
    var demo: Bool
}

/// Thin capsule meter used in the CPU column. `nil` draws only the track.
private struct MacProcessesMeter: View {
    var fraction: Double?
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geometry.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Non-optional sort keys for the table (unreported readings sort last) and
/// small presentation helpers. File-private so other pages are unaffected.
fileprivate extension MacProcess {
    var cpuSortValue: Double { cpuPercent.flatMap { $0.isFinite ? $0 : nil } ?? -1 }
    var memorySortValue: Double { memoryMB.flatMap { $0.isFinite ? $0 : nil } ?? -1 }
    var gpuSortValue: Double { gpuPercent.flatMap { $0.isFinite ? $0 : nil } ?? -1 }
    var cpuFraction: Double? { cpuPercent.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil } }
    /// Start time is reported as Unix seconds; placeholder values (such as demo rows) stay "—".
    var startedDate: Date? { createTime.isFinite && createTime > 946_684_800 ? Date(timeIntervalSince1970: createTime) : nil }
}
