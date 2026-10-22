import SwiftUI
import Charts

private struct OrbitHistoryStatistic: Decodable {
    let average: Double?
    let peak: Double?
    let count: Int
}

private struct OrbitHistorySession: Decodable, Identifiable {
    let id: String
    let name: String
    let gameProcess: String?
    let kind: String
    let status: String
    let startedAt: Double
    let endedAt: Double?
    let durationSeconds: Double
    let sampleCount: Int
    let statistics: [String: OrbitHistoryStatistic]

    var startedDate: Date { Date(timeIntervalSince1970: startedAt) }
    var isRecording: Bool { status == "recording" }
    var durationLabel: String {
        let seconds = max(0, Int(durationSeconds))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    var statusLabel: String {
        switch status {
        case "recording": return "Recording"
        case "interrupted": return "Interrupted"
        default: return "Completed"
        }
    }
}

private struct OrbitHistoryList: Decodable {
    let sessions: [OrbitHistorySession]
    let activeSession: OrbitHistorySession?
}

private struct OrbitHistorySample: Decodable {
    let timestamp: Double
    let segment: Int
    let metricSegments: [String: Int]?
    let telemetryAvailable: Bool
    let cpuUsage: Double?
    let gpuUsage: Double?
    let cpuTemp: Double?
    let gpuTemp: Double?
    let fps: Double?
    let cpuPowerWatts: Double?
    let gpuPowerWatts: Double?
    let ramUsedGB: Double?
    let vramUsedGB: Double?
    let networkUploadMBps: Double?
    let networkDownloadMBps: Double?

    func value(for metric: OrbitHistoryMetric) -> Double? {
        guard telemetryAvailable else { return nil }
        switch metric {
        case .cpuUsage: return cpuUsage
        case .gpuUsage: return gpuUsage
        case .cpuTemp: return cpuTemp
        case .gpuTemp: return gpuTemp
        case .fps: return fps
        case .cpuPowerWatts: return cpuPowerWatts
        case .gpuPowerWatts: return gpuPowerWatts
        case .ramUsedGB: return ramUsedGB
        case .vramUsedGB: return vramUsedGB
        case .networkUploadMBps: return networkUploadMBps
        case .networkDownloadMBps: return networkDownloadMBps
        }
    }
}

private struct OrbitHistoryDetail: Decodable {
    let session: OrbitHistorySession
    let samples: [OrbitHistorySample]
    let downsampled: Bool
    let sampleIntervalSeconds: Double
}

private enum OrbitHistoryMetric: String, CaseIterable, Identifiable {
    case fps, cpuUsage, gpuUsage, cpuTemp, gpuTemp, cpuPowerWatts, gpuPowerWatts
    case ramUsedGB, vramUsedGB, networkDownloadMBps, networkUploadMBps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fps: return "Frame Rate"
        case .cpuUsage: return "Processor"
        case .gpuUsage: return "Graphics"
        case .cpuTemp: return "CPU Temperature"
        case .gpuTemp: return "GPU Temperature"
        case .cpuPowerWatts: return "CPU Power"
        case .gpuPowerWatts: return "GPU Power"
        case .ramUsedGB: return "Memory"
        case .vramUsedGB: return "Video Memory"
        case .networkDownloadMBps: return "Receiving"
        case .networkUploadMBps: return "Sending"
        }
    }

    /// Unit for chart axes and VoiceOver.
    var unit: String {
        switch self {
        case .fps: return "fps"
        case .cpuUsage, .gpuUsage: return "%"
        case .cpuTemp, .gpuTemp: return "°C"
        case .cpuPowerWatts, .gpuPowerWatts: return "W"
        case .ramUsedGB, .vramUsedGB: return "GB"
        case .networkUploadMBps, .networkDownloadMBps: return "MB/s"
        }
    }

    func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        switch self {
        case .fps: return "\(Int(value.rounded())) fps"
        case .cpuUsage, .gpuUsage: return "\(Int(value.rounded()))%"
        case .cpuTemp, .gpuTemp: return "\(Int(value.rounded()))°"
        case .cpuPowerWatts, .gpuPowerWatts: return "\(Int(value.rounded())) W"
        case .ramUsedGB, .vramUsedGB: return value.formatted(.number.precision(.fractionLength(1))) + " GB"
        case .networkUploadMBps, .networkDownloadMBps: return OrbitFormat.rate(value) ?? "—"
        }
    }
}

private extension OrbitHistorySession {
    var durationText: String {
        let seconds = max(0, Int(durationSeconds))
        if seconds < 60 { return "\(seconds) s" }
        return OrbitFormat.duration(seconds: seconds)
    }

    var startedText: String {
        startedDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The figure that sums the session up: the average frame rate for games, else the processor.
    var summary: (value: String, label: String)? {
        if let fps = statistics["fps"]?.average, fps.isFinite, (statistics["fps"]?.count ?? 0) > 0 {
            return ("\(Int(fps.rounded())) fps", "average")
        }
        if let cpu = statistics["cpuUsage"]?.average, cpu.isFinite, (statistics["cpuUsage"]?.count ?? 0) > 0 {
            return ("\(Int(cpu.rounded()))%", "processor")
        }
        return nil
    }
}

private struct OrbitHistoryStartBody: Encodable { let name: String? }
private struct OrbitHistoryEmptyBody: Encodable {}
private struct OrbitHistoryStopResponse: Decodable { let session: OrbitHistorySession? }
private struct OrbitHistoryDeleteResponse: Decodable { let deleted: Bool }

/// Recorded sessions: Orbit Companion records the readings while a game runs (or while a
/// recording you start runs) and keeps them on the PC.
struct SessionHistoryView: View {
    @ObservedObject var vm: OrbitViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: OrbitHistoryList?
    @State private var historyConnection: Int?
    @State private var isLoading = false
    @State private var isActing = false
    @State private var error: String?
    @State private var showStart = false
    @State private var sessionName = ""
    @State private var pendingDelete: OrbitHistorySession?

    private var saved: [OrbitHistorySession] { history?.sessions.filter { !$0.isRecording } ?? [] }

    var body: some View {
        List {
            if !saved.isEmpty || history?.activeSession != nil {
                Section {
                    header
                        .listRowBackground(Color.clear)
                }
            }

            if let error {
                Section { OrbitInlineStatus(text: error, kind: .problem) }
            }

            if let active = history?.activeSession {
                Section("Recording Now") {
                    sessionLink(active)
                    Button(role: .destructive) {
                        OrbitHaptics.warning()
                        beginAction { client, connection in
                            Task { await stopRecording(client: client, connection: connection) }
                        }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle")
                    }
                    .disabled(!canAct)
                }
            }

            Section {
                if isLoading && history == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading sessions…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                } else if saved.isEmpty && history?.activeSession == nil {
                    emptyMessage
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(saved) { session in
                        sessionLink(session)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                                    .disabled(!canAct)
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                                    .disabled(!canAct)
                            }
                    }
                }
            } header: {
                if !saved.isEmpty { Text("Saved") }
            } footer: {
                Text("Sessions stay on the PC: up to 100 of them, for 30 days. Only readings, session names and game names are saved.")
            }
        }
        .listStyle(.insetGrouped)
        .orbitListBackground()
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Record", systemImage: "record.circle") {
                    OrbitHaptics.tap()
                    showStart = true
                }
                .tint(.primary)
                .disabled(!canAct || history?.activeSession?.kind == "manual")
            }
        }
        .refreshable { await load() }
        .task(id: vm.connectionID) {
            history = nil; error = nil; showStart = false; pendingDelete = nil
            historyConnection = nil; isActing = false; isLoading = false
            while !Task.isCancelled {
                if scenePhase == .active { await load() }
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .alert("Record a Session", isPresented: $showStart) {
            TextField("Name (optional)", text: $sessionName)
            Button("Record") {
                let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                sessionName = ""
                beginAction { client, connection in
                    Task { await startRecording(name: name.isEmpty ? nil : String(name.prefix(100)), client: client, connection: connection) }
                }
            }
            Button("Cancel", role: .cancel) { sessionName = "" }
        } message: {
            Text("The PC records until you stop it or Orbit Companion closes. A game session that is running now ends here.")
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            if let session = pendingDelete {
                Button("Delete Session", role: .destructive) {
                    pendingDelete = nil
                    beginAction { client, connection in
                        Task { await delete(session, client: client, connection: connection) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its readings are removed from the PC.")
        }
    }

    private var canAct: Bool { vm.metrics.isOnline && !vm.isDemoMode && !isActing && historyConnection == vm.connectionID }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.title3.weight(.semibold))
            Text(subline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if history?.activeSession != nil { return "Recording now" }
        return saved.count == 1 ? "1 session" : "\(saved.count) sessions"
    }

    private var subline: String {
        if !vm.metrics.isOnline { return "Connect to your PC to record or open sessions." }
        return "Orbit records on its own while a game runs."
    }

    @ViewBuilder
    private var emptyMessage: some View {
        if vm.isDemoMode {
            OrbitEmptyMessage(systemImage: "chart.xyaxis.line", title: "Sessions need your own PC",
                              message: "Recording is off in demo mode.")
        } else if !vm.metrics.isOnline {
            OrbitEmptyMessage(systemImage: "desktopcomputer", title: "Your PC isn't connected",
                              message: "Sessions are kept on the PC. Connect to it to see them.")
        } else {
            OrbitEmptyMessage(systemImage: "chart.xyaxis.line", title: "No sessions yet",
                              message: "Orbit records on its own while a game runs. You can also record any time.",
                              actionTitle: canAct ? "Start a Recording" : nil) { showStart = true }
        }
    }

    @MainActor private func beginAction(_ action: (OrbitAPIClient, Int) -> Void) {
        guard canAct else { return }
        do {
            // Capture the selected PC during the tap, before scheduling work, so a later
            // PC switch cannot redirect a queued action.
            let client = try vm.companionClient()
            let connection = vm.connectionID
            isActing = true
            action(client, connection)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sessionLink(_ session: OrbitHistorySession) -> some View {
        NavigationLink {
            OrbitHistoryDetailView(vm: vm, session: session, originConnection: vm.connectionID)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if session.isRecording {
                            Circle()
                                .fill(OrbitPalette.critical)
                                .frame(width: 7, height: 7)
                            Text("Recording · \(session.durationText)")
                        } else {
                            Text("\(session.startedText) · \(session.durationText)")
                        }
                        if session.status == "interrupted" {
                            Text("Interrupted")
                                .foregroundStyle(OrbitPalette.warm)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .orbitLiveNumber()
                }
                Spacer(minLength: 8)
                if let summary = session.summary {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(summary.value)
                            .font(.subheadline.weight(.semibold))
                            .orbitLiveNumber()
                        Text(summary.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        guard !vm.isDemoMode else { history = nil; error = nil; return }
        let connection = vm.connectionID
        isLoading = true
        defer { if connection == vm.connectionID { isLoading = false } }
        do {
            let client = try vm.companionClient()
            let result: OrbitHistoryList = try await client.get("/api/history/sessions")
            guard connection == vm.connectionID, !Task.isCancelled else { return }
            history = result; historyConnection = connection; error = nil
        } catch {
            guard connection == vm.connectionID, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func startRecording(name: String?, client: OrbitAPIClient, connection: Int) async {
        defer { if connection == vm.connectionID { isActing = false } }
        guard connection == vm.connectionID, !vm.isDemoMode else { return }
        do {
            let _: OrbitHistorySession = try await client.send("/api/history/start", body: OrbitHistoryStartBody(name: name))
            guard connection == vm.connectionID else { return }
            await load()
        } catch {
            guard connection == vm.connectionID else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func stopRecording(client: OrbitAPIClient, connection: Int) async {
        defer { if connection == vm.connectionID { isActing = false } }
        guard connection == vm.connectionID, !vm.isDemoMode else { return }
        do {
            let _: OrbitHistoryStopResponse = try await client.send("/api/history/stop", body: OrbitHistoryEmptyBody())
            guard connection == vm.connectionID else { return }
            await load()
        } catch {
            guard connection == vm.connectionID else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func delete(_ session: OrbitHistorySession, client: OrbitAPIClient, connection: Int) async {
        defer { if connection == vm.connectionID { isActing = false } }
        guard connection == vm.connectionID, !vm.isDemoMode else { return }
        do {
            let _: OrbitHistoryDeleteResponse = try await client.send("/api/history/sessions/\(session.id)", method: "DELETE", body: OrbitHistoryEmptyBody())
            guard connection == vm.connectionID else { return }
            await load()
        } catch {
            guard connection == vm.connectionID else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct OrbitHistoryChartPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
}

/// One session: a chart of the reading you pick, its low, average and peak, and every
/// reading the session recorded.
private struct OrbitHistoryDetailView: View {
    @ObservedObject var vm: OrbitViewModel
    let session: OrbitHistorySession
    @State private var originConnection: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: OrbitHistoryDetail?
    @State private var selectedMetric: OrbitHistoryMetric = .fps
    @State private var selectedTime: Date?
    @State private var error: String?
    @State private var isLoading = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir

    init(vm: OrbitViewModel, session: OrbitHistorySession, originConnection: Int) {
        self.vm = vm
        self.session = session
        _originConnection = State(initialValue: originConnection)
    }

    private var samePC: Bool { originConnection == vm.connectionID && !vm.isDemoMode }
    private var currentSession: OrbitHistorySession { detail?.session ?? session }

    /// Readings this session has; every reading while it is still loading.
    private var recordedMetrics: [OrbitHistoryMetric] {
        let present = OrbitHistoryMetric.allCases.filter { (currentSession.statistics[$0.rawValue]?.count ?? 0) > 0 }
        return present.isEmpty ? OrbitHistoryMetric.allCases : present
    }

    private var chartPoints: [OrbitHistoryChartPoint] {
        var points: [OrbitHistoryChartPoint] = []
        var lineSegment = 0
        var previousSourceSegment: Int?
        var missingReading = false
        for (index, sample) in (detail?.samples ?? []).enumerated() {
            guard let value = sample.value(for: selectedMetric), value.isFinite else {
                missingReading = true
                continue
            }
            let sourceSegment = sample.metricSegments?[selectedMetric.rawValue] ?? sample.segment
            if missingReading || previousSourceSegment != sourceSegment { lineSegment += 1 }
            points.append(OrbitHistoryChartPoint(id: index, date: Date(timeIntervalSince1970: sample.timestamp),
                                                 value: value, segment: lineSegment))
            previousSourceSegment = sourceSegment
            missingReading = false
        }
        return points
    }

    private var selectedPoint: OrbitHistoryChartPoint? {
        guard let selectedTime else { return nil }
        return chartPoints.min { abs($0.date.timeIntervalSince(selectedTime)) < abs($1.date.timeIntervalSince(selectedTime)) }
    }

    var body: some View {
        Group {
            if !samePC {
                OrbitEmptyMessage(systemImage: "desktopcomputer", title: "This session is on another PC",
                                  message: "Go back to see the sessions of the PC you're using now.")
                    .frame(maxHeight: .infinity)
                    .background(OrbitPalette.canvas)
            } else {
                OrbitPage {
                    summary
                    if let error {
                        OrbitInlineStatus(text: error, kind: .problem)
                            .padding(.horizontal, 4)
                    }
                    chartSection
                    allReadings
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .onChange(of: selectedMetric) { _, _ in selectedTime = nil }
        .onChange(of: vm.connectionID) { _, _ in detail = nil; error = nil; selectedTime = nil }
        .task {
            while !Task.isCancelled && samePC {
                if scenePhase == .active { await load() }
                if detail?.session.isRecording == false { break }
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if currentSession.isRecording {
                    OrbitStatusLabel(text: "Recording", color: OrbitPalette.critical, pulsing: true)
                } else if currentSession.status == "interrupted" {
                    OrbitStatusLabel(text: "Interrupted", color: OrbitPalette.warm)
                }
                Text(currentSession.kind == "auto" ? "Game session" : "Recording you started")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("\(currentSession.startedDate.formatted(date: .abbreviated, time: .shortened)) · \(currentSession.durationText)")
                .font(.title3.weight(.semibold))
                .orbitLiveNumber()
            if let game = currentSession.gameProcess, !game.isEmpty {
                Text(game)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if currentSession.status == "interrupted" {
                Text("Orbit Companion stopped before the session ended, so it ends at the last saved reading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                Picker("Reading", selection: $selectedMetric) {
                    ForEach(recordedMetrics) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedMetric.title)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .tint(.primary)
            .accessibilityLabel("Reading shown: \(selectedMetric.title)")

            if isLoading && detail == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading readings…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if chartPoints.isEmpty {
                Text("No \(selectedMetric.title.lowercased()) readings in this session. Orbit doesn't fill in missing values.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
                    .orbitSurface()
            } else {
                chart
                stats
            }

            Text(detail?.downsampled == true
                 ? "The chart shows a selection of the readings; average and peak use all of them. Gaps are missing readings."
                 : "A reading every 5 seconds. Gaps are missing readings. Touch the chart to see one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(chartPoints) { point in
                AreaMark(x: .value("Time", point.date), y: .value(selectedMetric.unit, point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(LinearGradient(colors: [theme.orbitTint.opacity(0.28), theme.orbitTint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(selectedMetric.unit, point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected time", point.date))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(selectedMetric.formatted(point.value))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text(point.date, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OrbitPalette.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(OrbitPalette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(OrbitPalette.hairline)
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartYScale(domain: .automatic(includesZero: selectedMetric == .cpuUsage || selectedMetric == .gpuUsage))
        .chartXSelection(value: $selectedTime)
        .frame(height: 210)
        .padding(.top, 18)
        .animation(OrbitMotion.standard, value: selectedMetric)
        .accessibilityLabel("\(selectedMetric.title) during the session")
    }

    private var stats: some View {
        let statistic = currentSession.statistics[selectedMetric.rawValue]
        let values = chartPoints.map(\.value)
        return HStack(spacing: 0) {
            stat("Low", values.min().map { selectedMetric.formatted($0) } ?? "—")
            stat("Average", selectedMetric.formatted(statistic?.average))
            stat("Peak", selectedMetric.formatted(statistic?.peak))
        }
        .orbitSurface(padding: 16, radius: 22)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.orbitReading(24))
                .orbitLiveNumber()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: All readings

    @ViewBuilder
    private var allReadings: some View {
        let recorded = OrbitHistoryMetric.allCases.filter { (currentSession.statistics[$0.rawValue]?.count ?? 0) > 0 }
        if !recorded.isEmpty {
            OrbitGroup("All Readings", footer: "Power is what each part draws, not the whole PC. Only readings the PC reported count.") {
                ForEach(recorded) { metric in
                    let statistic = currentSession.statistics[metric.rawValue]
                    Button {
                        OrbitHaptics.selection()
                        withAnimation(OrbitMotion.standard) { selectedMetric = metric }
                    } label: {
                        HStack(spacing: 12) {
                            Text(metric.title)
                                .foregroundStyle(.primary)
                            if metric == selectedMetric {
                                Image(systemName: "chart.xyaxis.line")
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Shown in the chart")
                            }
                            Spacer(minLength: 12)
                            Text("\(metric.formatted(statistic?.average)) avg · \(metric.formatted(statistic?.peak)) peak")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @MainActor private func load() async {
        guard samePC, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try vm.companionClient()
            let response: OrbitHistoryDetail = try await client.get("/api/history/sessions/\(session.id)")
            guard samePC, !Task.isCancelled else { return }
            detail = response; error = nil
            if selectedMetric == .fps, response.session.statistics["fps"]?.count == 0 {
                selectedMetric = .cpuUsage
            }
        } catch {
            guard samePC, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
