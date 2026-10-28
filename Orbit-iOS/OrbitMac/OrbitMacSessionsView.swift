import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Sessions: start and stop telemetry recordings on the PC Companion and chart
/// the captured samples (frame rate, loads, temperatures, power, memory, network).
@MainActor
struct MacSessionsView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme
    @State private var selectedID: String?
    @State private var newSessionName = ""
    @State private var pendingDelete: MacHistorySession?
    @State private var detail: MacHistoryDetail?
    @State private var detailError: String?
    @State private var isLoadingDetail = false
    @State private var loadToken = UUID()
    @State private var selectedMetric: MacHistoryMetric = .fps
    @State private var hoveredDate: Date?
    @State private var exportMessage: String?

    // MARK: Derived state

    private var canRecord: Bool { vm.metrics.isOnline && !vm.isDemoMode && !vm.isHistoryActing }
    private var activeSession: MacHistorySession? { vm.historyList?.activeSession }

    /// Newest first; the active recording is included even if the list omits it.
    private var sortedSessions: [MacHistorySession] {
        guard let list = vm.historyList else { return [] }
        var all = list.sessions
        if let active = list.activeSession, !all.contains(where: { $0.id == active.id }) { all.append(active) }
        return all.sorted { $0.startedAt > $1.startedAt }
    }
    private var selectedSession: MacHistorySession? {
        guard let selectedID else { return nil }
        return sortedSessions.first { $0.id == selectedID }
    }
    /// Pinned to `String` so `confirmationDialog` resolves its `StringProtocol` overload instead of
    /// inferring the literal as `LocalizedStringKey`.
    private var deleteDialogTitle: String {
        pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete recording?"
    }

    // MARK: Body

    var body: some View {
        Group {
            if vm.currentPC == nil && !vm.isDemoMode {
                MacPage { unpairedState }
            } else {
                pageLayout
            }
        }
        .task {
            await vm.refreshHistory()
            selectNewestIfNeeded()
        }
        .onChange(of: vm.selectedPCID) { _, _ in
            selectedID = nil
            detail = nil
            detailError = nil
            Task {
                await vm.refreshHistory()
                selectNewestIfNeeded()
            }
        }
        .onChange(of: vm.metrics.isOnline) { _, online in
            guard online else { return }
            Task {
                await vm.refreshHistory()
                selectNewestIfNeeded()
                // The detail could not load while offline; fetch it now that the PC is reachable again.
                if let selectedID, detail?.session.id != selectedID { await loadSelectedDetail() }
            }
        }
        .onChange(of: sortedSessions.map(\.id)) { _, ids in
            if let current = selectedID, !ids.contains(current) { selectedID = nil }
            selectNewestIfNeeded()
        }
        .task(id: vm.historyList?.activeSession?.id) { await pollWhileRecording() }
        .task(id: selectedID) { await loadSelectedDetail() }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let session = pendingDelete {
                Button("Delete Recording", role: .destructive) {
                    pendingDelete = nil
                    if selectedID == session.id {
                        selectedID = nil
                        detail = nil
                        detailError = nil
                    }
                    Task { await vm.deleteSession(session) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The recorded samples are removed from the PC. This cannot be undone.")
        }
    }

    private var pageLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.isDemoMode { demoNotice }
            MacThisMonthCard()
            recordingCard
            if let error = vm.historyError {
                MacNotice(title: "Session history problem", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
            }
            content
        }
        .frame(maxWidth: 1180, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: States

    private var unpairedState: some View {
        MacEmptyState(
            icon: "desktopcomputer",
            title: "Pair your PC",
            message: "Recordings are captured and stored by the PC Companion. Pair a PC, or import the one from your iPhone, to record and browse sessions.",
            tint: theme.accent,
            actionTitle: "Pair or import a PC",
            action: { vm.selectedSection = .pcs }
        )
        .padding(.top, 40)
    }

    private var demoNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Demo mode · recordings need a paired PC")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Pair a PC") { vm.setDemoMode(false); vm.selectedSection = .pcs }
                .buttonStyle(MacHoverButtonStyle(tint: .orange))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .macGlass(cornerRadius: 14, tint: .orange)
    }

    @ViewBuilder
    private var content: some View {
        if vm.historyList != nil {
            if sortedSessions.isEmpty {
                stateCard {
                    MacEmptyState(
                        icon: "record.circle",
                        title: "No recordings yet",
                        message: "Start one while gaming to capture FPS and temperatures.",
                        tint: theme.accent,
                        actionTitle: canRecord ? "Start recording" : nil,
                        action: { startRecording() }
                    )
                }
            } else {
                splitView
            }
        } else if vm.isDemoMode {
            stateCard {
                MacEmptyState(
                    icon: "record.circle",
                    title: "Recordings need a paired PC",
                    message: "Demo mode simulates live telemetry only. Pair a PC to record sessions and chart FPS, loads, temperatures and power over time.",
                    tint: .orange,
                    actionTitle: "Pair a PC",
                    action: { vm.setDemoMode(false); vm.selectedSection = .pcs }
                )
            }
        } else if vm.isLoadingHistory {
            stateCard { loadingView }
        } else if !vm.metrics.isOnline {
            stateCard {
                MacEmptyState(
                    icon: "wifi.slash",
                    title: "\(vm.currentPC?.name ?? "Your PC") is offline",
                    message: "Recordings are stored on the PC. Power it on to browse past sessions or start a new one.",
                    tint: .orange,
                    actionTitle: vm.isWaking ? "Waking…" : "Power On",
                    action: { Task { await vm.wakePC() } }
                )
            }
        } else if vm.historyError != nil {
            stateCard {
                MacEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Could not load recordings",
                    message: "Check that the PC Companion is up to date, then try again.",
                    tint: .orange,
                    actionTitle: "Try again",
                    action: { Task { await vm.refreshHistory() } }
                )
            }
        } else {
            stateCard { loadingView }
        }
    }

    private func stateCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .macGlass(cornerRadius: 22, tint: theme.accent)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading recordings…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
    }

    // MARK: Recording card

    private var recordHint: String {
        if vm.isDemoMode { return "Demo mode simulates live telemetry only. Pair a PC to record." }
        if !vm.metrics.isOnline { return "Connect to your PC to start capturing FPS, loads, temperatures and power." }
        return "Captures FPS, CPU/GPU load, temperatures, power, memory and network until you stop."
    }

    private var recordingCard: some View {
        let isRecording = activeSession != nil
        let tint: Color = isRecording ? .red : theme.accent
        return HStack(alignment: .center, spacing: 14) {
            MacIconBadge(systemName: isRecording ? "record.circle.fill" : "record.circle", tint: tint, size: 44, filled: isRecording)
            if let active = activeSession {
                activeRecordingContent(active)
            } else {
                idleRecordingContent
            }
        }
        .padding(18)
        .macGlass(cornerRadius: 22, tint: tint, elevated: isRecording)
    }

    private func activeRecordingContent(_ active: MacHistorySession) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(active.name.isEmpty ? "Untitled session" : active.name)
                        .font(.system(.title3, weight: .bold))
                        .lineLimit(1)
                    MacStatusPill(text: "Recording", tint: .red, pulsing: true)
                }
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        MacStatChip(label: "Elapsed", value: Self.elapsed(from: active.startedDate, to: context.date), icon: "timer", tint: .red)
                    }
                    MacStatChip(label: "Started", value: active.startedDate.formatted(date: .omitted, time: .shortened), icon: "clock")
                    if active.sampleCount > 0 {
                        MacStatChip(label: "Samples", value: "\(active.sampleCount)", icon: "waveform.path.ecg")
                    }
                    if let process = active.gameProcess, !process.isEmpty {
                        MacStatChip(label: "Game", value: process, icon: "gamecontroller.fill")
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if vm.isHistoryActing { ProgressView().controlSize(.small) }
            Button {
                Task { await vm.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(MacHoverButtonStyle(tint: .red, prominent: true))
            .disabled(!canRecord)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Stop recording (⌥⌘R)")
        }
    }

    private var idleRecordingContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("Record a session")
                    .font(.system(.title3, weight: .bold))
                Text(recordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            TextField("Session name (optional)", text: $newSessionName)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .frame(width: 230)
                .onSubmit { startRecording() }
                .disabled(!canRecord)
                .accessibilityLabel("Session name")
            if vm.isHistoryActing { ProgressView().controlSize(.small) }
            Button {
                startRecording()
            } label: {
                Label("Start", systemImage: "record.circle")
            }
            .buttonStyle(MacHoverButtonStyle(tint: .red, prominent: canRecord))
            .disabled(!canRecord)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Start recording (⌥⌘R)")
        }
    }

    // MARK: Split view

    private var splitView: some View {
        HStack(alignment: .top, spacing: 14) {
            sessionsColumn
            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSectionHeader("Recordings", subtitle: "\(sortedSessions.count) on \(vm.currentPC?.name ?? "PC")", icon: "list.bullet") {
                if vm.isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await vm.refreshHistory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(MacIconButtonStyle(size: 24))
                    .disabled(!vm.metrics.isOnline)
                    .help("Refresh recordings")
                    .accessibilityLabel("Refresh recordings")
                }
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(sortedSessions) { session in
                        Button {
                            selectedID = session.id
                        } label: {
                            MacSessionsRow(session: session, isSelected: session.id == selectedID, accent: theme.accent)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete…", role: .destructive) { pendingDelete = session }
                                .disabled(!canRecord)
                        }
                        .accessibilityLabel("\(session.name), \(session.statusLabel), \(session.durationLabel)")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
        .macGlass(cornerRadius: 18)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = selectedSession {
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    detailHeader(session)
                    if let detailError {
                        MacNotice(title: "Could not load samples", message: detailError, icon: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if let detail {
                        if detail.samples.isEmpty {
                            MacEmptyState(
                                icon: "waveform.path.ecg",
                                title: "No samples yet",
                                message: detail.session.isRecording ? "The PC Companion is still collecting readings. The chart appears as soon as the first samples arrive." : "This recording ended before any telemetry was captured.",
                                tint: theme.accent
                            )
                        } else {
                            metricPicker
                            chartCard(detail)
                        }
                    } else if isLoadingDetail {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading samples…").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                    }
                    if let exportMessage {
                        Text(exportMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .macGlass(cornerRadius: 18)
        } else {
            MacEmptyState(
                icon: "chart.xyaxis.line",
                title: "Select a recording",
                message: "Pick a session on the left to chart its frame rate, loads, temperatures, power, memory and network over time.",
                tint: theme.accent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .macGlass(cornerRadius: 18)
        }
    }

    // MARK: Detail

    private func statusTint(_ session: MacHistorySession) -> Color {
        if session.isRecording { return .red }
        return session.status == "interrupted" ? .orange : .mint
    }

    private func detailHeader(_ selected: MacHistorySession) -> some View {
        let session = detail?.session.id == selected.id ? (detail?.session ?? selected) : selected
        return HStack(alignment: .top, spacing: 12) {
            MacIconBadge(systemName: session.kind == "auto" ? "gamecontroller.fill" : "record.circle", tint: statusTint(session), size: 40, filled: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(session.name.isEmpty ? "Untitled session" : session.name)
                        .font(.system(.title3, weight: .bold))
                        .lineLimit(1)
                    MacStatusPill(text: session.statusLabel, tint: statusTint(session), pulsing: session.isRecording)
                }
                detailChips(session)
            }
            Spacer(minLength: 8)
            detailActions(session)
        }
    }

    private func detailChips(_ session: MacHistorySession) -> some View {
        HStack(spacing: 8) {
            MacStatChip(label: "Started", value: session.startedDate.formatted(.dateTime.day().month().year().hour().minute()), icon: "calendar")
            MacStatChip(label: "Duration", value: session.durationSeconds > 0 ? session.durationLabel : "—", icon: "clock")
            MacStatChip(label: "Samples", value: session.sampleCount > 0 ? "\(session.sampleCount)" : "—", icon: "waveform.path.ecg")
            if let detail, detail.session.id == session.id {
                if detail.sampleIntervalSeconds > 0 {
                    MacStatChip(label: "Interval", value: Self.intervalLabel(detail.sampleIntervalSeconds), icon: "metronome")
                }
                if detail.downsampled {
                    MacStatChip(label: "Plotted", value: "\(detail.samples.count)", icon: "arrow.down.right.and.arrow.up.left")
                }
            }
            if let process = session.gameProcess, !process.isEmpty {
                MacStatChip(label: "Game", value: process, icon: "gamecontroller.fill")
            }
        }
        .lineLimit(1)
    }

    private static func intervalLabel(_ seconds: Double) -> String {
        let digits = seconds < 10 ? 1 : 0
        return "\(MacFormat.decimal(seconds, digits: digits)) s"
    }

    private func detailActions(_ session: MacHistorySession) -> some View {
        HStack(spacing: 8) {
            if isLoadingDetail {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                Button {
                    Task { await loadSelectedDetail() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MacIconButtonStyle(size: 28))
                .disabled(!vm.metrics.isOnline)
                .help("Reload samples")
                .accessibilityLabel("Reload samples")
            }
            Button {
                exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            .disabled(detail == nil || detail?.samples.isEmpty == true)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Export every sample with all metric columns (⇧⌘E)")
            Button(role: .destructive) {
                pendingDelete = session
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(MacIconButtonStyle(tint: .orange, size: 28))
            .disabled(!canRecord)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Delete recording… (⌘⌫)")
            .accessibilityLabel("Delete recording")
        }
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $selectedMetric) {
            ForEach(MacHistoryMetric.allCases) { metric in
                Text(metric.macSessionsShortTitle).tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .onChange(of: selectedMetric) { _, _ in hoveredDate = nil }
    }

    private func chartCard(_ detail: MacHistoryDetail) -> some View {
        let points = chartPoints(for: detail)
        let hovered = hoveredPoint(in: points)
        let stats = MacSessionsStats(values: points.map(\.value))
        return VStack(alignment: .leading, spacing: 12) {
            MacSectionHeader(selectedMetric.title, subtitle: points.isEmpty ? nil : "\(points.count) readings · \(selectedMetric.unit)", icon: "chart.xyaxis.line", tint: selectedMetric.color) {
                if let hovered {
                    Text("\(selectedMetric.formatted(hovered.value)) · \(hovered.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hover the chart to inspect a reading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if points.isEmpty {
                MacEmptyState(
                    icon: "questionmark.circle",
                    title: "No \(selectedMetric.title.lowercased()) readings",
                    message: "The PC did not report this sensor during the recording. Pick another metric above.",
                    tint: selectedMetric.color
                )
            } else {
                chart(points, hovered: hovered)
            }
            statsRow(stats, session: detail.session)
            agentSummary(detail.session)
        }
        .padding(14)
        .macGlass(cornerRadius: 16, tint: selectedMetric.color)
    }

    private func chart(_ points: [MacSessionsChartPoint], hovered: MacSessionsChartPoint?) -> some View {
        let metric = selectedMetric
        let areaFill = LinearGradient(colors: [metric.color.opacity(0.34), metric.color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment), stacking: .unstacked)
                    .foregroundStyle(areaFill)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(metric.color)
                    .lineStyle(strokeStyle)
                    .interpolationMethod(.monotone)
            }
            if let hovered {
                RuleMark(x: .value("Hovered time", hovered.date))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PointMark(x: .value("Hovered time", hovered.date), y: .value(metric.title, hovered.value))
                    .foregroundStyle(metric.color)
                    .symbolSize(60)
            }
        }
        .chartLegend(.hidden)
        .chartYAxisLabel(metric.unit)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel()
            }
        }
        .chartYScale(domain: .automatic(includesZero: metric.macSessionsIncludesZero))
        .chartOverlay { proxy in hoverOverlay(proxy: proxy, hovered: hovered) }
        .frame(height: 260)
        .accessibilityLabel("\(metric.title) over time in \(metric.unit)")
    }

    private func hoverOverlay(proxy: ChartProxy, hovered: MacSessionsChartPoint?) -> some View {
        GeometryReader { geometry in
            let plotRect: CGRect = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if plotRect.contains(location) {
                            hoveredDate = proxy.value(atX: location.x - plotRect.minX, as: Date.self)
                        } else {
                            hoveredDate = nil
                        }
                    case .ended:
                        hoveredDate = nil
                    @unknown default:
                        hoveredDate = nil
                    }
                }
            if let hovered, let x = proxy.position(forX: hovered.date) {
                let lower = plotRect.minX + 64
                let upper = max(lower, plotRect.maxX - 64)
                MacSessionsHoverCard(value: selectedMetric.formatted(hovered.value), time: hovered.date, tint: selectedMetric.color)
                    .position(x: min(max(plotRect.minX + x, lower), upper), y: plotRect.minY + 24)
                    .allowsHitTesting(false)
            }
        }
    }

    private func statsRow(_ stats: MacSessionsStats, session: MacHistorySession) -> some View {
        let metric = selectedMetric
        return HStack(spacing: 8) {
            MacStatChip(label: "Min", value: metric.formatted(stats.minimum), icon: "arrow.down.to.line", tint: metric.color)
            MacStatChip(label: "Avg", value: metric.formatted(stats.average), icon: "equal", tint: metric.color)
            MacStatChip(label: "Max", value: metric.formatted(stats.maximum), icon: "arrow.up.to.line", tint: metric.color)
            MacStatChip(label: "Samples", value: stats.count > 0 ? "\(stats.count)" : "—", icon: "waveform.path.ecg")
            MacStatChip(label: "Duration", value: session.durationSeconds > 0 ? session.durationLabel : "—", icon: "clock")
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func agentSummary(_ session: MacHistorySession) -> some View {
        if let stat = session.statistics[selectedMetric.rawValue] {
            HStack(spacing: 8) {
                Text("Reported by the PC")
                    .font(.system(.caption2, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.5))
                MacStatChip(label: "Avg", value: selectedMetric.formatted(stat.average))
                MacStatChip(label: "Peak", value: selectedMetric.formatted(stat.peak))
                MacStatChip(label: "Readings", value: "\(stat.count)")
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        }
    }

    // MARK: Data helpers

    private func chartPoints(for detail: MacHistoryDetail) -> [MacSessionsChartPoint] {
        var points: [MacSessionsChartPoint] = []
        points.reserveCapacity(detail.samples.count)
        var lineSegment = 0
        var previousSource: Int?
        var gap = false
        for (index, sample) in detail.samples.enumerated() {
            guard let value = sample.value(for: selectedMetric), value.isFinite else {
                gap = true
                continue
            }
            let source = sample.metricSegments?[selectedMetric.rawValue] ?? sample.segment
            if gap || previousSource != source { lineSegment += 1 }
            points.append(MacSessionsChartPoint(id: index, date: Date(timeIntervalSince1970: sample.timestamp), value: value, segment: lineSegment))
            previousSource = source
            gap = false
        }
        return points
    }

    private func hoveredPoint(in points: [MacSessionsChartPoint]) -> MacSessionsChartPoint? {
        guard let hoveredDate, !points.isEmpty else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hoveredDate)) < abs($1.date.timeIntervalSince(hoveredDate)) }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%ld:%02ld:%02ld", hours, minutes, seconds) : String(format: "%02ld:%02ld", minutes, seconds)
    }

    // MARK: Actions

    private func selectNewestIfNeeded() {
        if selectedID == nil, let first = sortedSessions.first { selectedID = first.id }
    }

    private func startRecording() {
        guard canRecord else { return }
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await vm.startRecording(name: trimmed.isEmpty ? nil : trimmed)
            if let active = vm.historyList?.activeSession {
                newSessionName = ""
                selectedID = active.id
            }
        }
    }

    private func loadSelectedDetail(showsSpinner: Bool = true) async {
        if showsSpinner {
            // Silent refreshes (recording poll) keep the hover reading and the last export note in place.
            hoveredDate = nil
            exportMessage = nil
        }
        guard let session = selectedSession else {
            detail = nil
            detailError = nil
            return
        }
        if detail?.session.id != session.id { detail = nil }
        guard !vm.isDemoMode else {
            detailError = "Demo mode has no recordings. Pair a PC to record sessions."
            return
        }
        guard vm.metrics.isOnline else {
            detailError = "Connect to \(vm.currentPC?.name ?? "your PC") to load the samples for this recording."
            return
        }
        let token = UUID()
        loadToken = token
        if showsSpinner { isLoadingDetail = true }
        detailError = nil
        // Whichever load is the latest clears the spinner, so a silent refresh that supersedes a
        // spinner load (recording just ended) cannot leave `isLoadingDetail` stuck at true.
        defer { if loadToken == token { isLoadingDetail = false } }
        do {
            let loaded = try await vm.loadSessionDetail(session)
            guard loadToken == token, !Task.isCancelled else { return }
            detail = loaded
        } catch {
            guard loadToken == token, !Task.isCancelled else { return }
            detailError = (error as? OrbitError)?.message ?? error.localizedDescription
        }
    }

    private func pollWhileRecording() async {
        guard vm.historyList?.activeSession != nil else {
            // A recording just ended: a loaded detail still says "recording", so refresh it once for the final status and stats.
            if detail?.session.isRecording == true, selectedSession != nil { await loadSelectedDetail(showsSpinner: false) }
            return
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled, vm.metrics.isOnline, !vm.isDemoMode else { continue }
            await vm.refreshHistory()
            if !Task.isCancelled, !isLoadingDetail, selectedSession?.isRecording == true {
                await loadSelectedDetail(showsSpinner: false)
            }
        }
    }

    // MARK: CSV export

    private func exportCSV() {
        guard let detail, !detail.samples.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Recording"
        panel.prompt = "Export"
        panel.nameFieldStringValue = Self.exportFileName(for: detail.session)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.csv(for: detail).write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Exported \(detail.samples.count) samples to \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private static func exportFileName(for session: MacHistorySession) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = session.name.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: session.startedDate)
        return "\(base.isEmpty ? "Orbit session" : base) \(stamp).csv"
    }

    /// One row per sample: timestamp, ISO time, segment, telemetry flag, then every metric column.
    private static func csv(for detail: MacHistoryDetail) -> String {
        let iso = ISO8601DateFormatter()
        let metrics = MacHistoryMetric.allCases
        var lines: [String] = []
        lines.reserveCapacity(detail.samples.count + 1)
        lines.append((["timestamp", "time_iso8601", "segment", "telemetry_available"] + metrics.map(\.rawValue)).joined(separator: ","))
        for sample in detail.samples {
            var fields: [String] = [
                String(sample.timestamp),
                iso.string(from: Date(timeIntervalSince1970: sample.timestamp)),
                String(sample.segment),
                sample.telemetryAvailable ? "1" : "0"
            ]
            for metric in metrics {
                if let value = sample.value(for: metric), value.isFinite {
                    fields.append(String(value))
                } else {
                    fields.append("")
                }
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Rows & chart helpers

private struct MacSessionsRow: View {
    let session: MacHistorySession
    let isSelected: Bool
    let accent: Color
    @State private var hovered = false

    private var tint: Color {
        if session.isRecording { return .red }
        return session.status == "interrupted" ? .orange : accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MacIconBadge(systemName: session.kind == "auto" ? "gamecontroller.fill" : "record.circle", tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.name.isEmpty ? "Untitled session" : session.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if session.isRecording {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    } else if session.status == "interrupted" {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                Text(session.startedDate.formatted(.dateTime.day().month().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 9, weight: .bold))
                    Text(session.durationSeconds > 0 ? session.durationLabel : "—")
                    if session.sampleCount > 0 {
                        Text("·")
                        Text("\(session.sampleCount) samples")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? tint.opacity(0.18) : Color.white.opacity(hovered ? 0.07 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
    }
}

private struct MacSessionsChartPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
}

private struct MacSessionsStats {
    let minimum: Double?
    let average: Double?
    let maximum: Double?
    let count: Int

    init(values: [Double]) {
        let finite = values.filter { $0.isFinite }
        count = finite.count
        minimum = finite.min()
        maximum = finite.max()
        average = finite.isEmpty ? nil : finite.reduce(0, +) / Double(finite.count)
    }
}

private struct MacSessionsHoverCard: View {
    let value: String
    let time: Date
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(time, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}

/// Short labels for the segmented metric picker; the full titles live on `MacHistoryMetric.title`.
private extension MacHistoryMetric {
    var macSessionsShortTitle: String {
        switch self {
        case .fps: "FPS"
        case .cpuUsage: "CPU"
        case .gpuUsage: "GPU"
        case .cpuTemp: "CPU °C"
        case .gpuTemp: "GPU °C"
        case .cpuPowerWatts: "CPU W"
        case .gpuPowerWatts: "GPU W"
        case .ramUsedGB: "RAM"
        case .vramUsedGB: "VRAM"
        case .networkDownloadMBps: "Down"
        case .networkUploadMBps: "Up"
        }
    }
    var macSessionsIncludesZero: Bool { self == .cpuUsage || self == .gpuUsage }
}
