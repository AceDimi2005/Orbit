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
        case .fps: return "Frame rate"
        case .cpuUsage: return "CPU load"
        case .gpuUsage: return "GPU load"
        case .cpuTemp: return "CPU temperature"
        case .gpuTemp: return "GPU temperature"
        case .cpuPowerWatts: return "CPU power"
        case .gpuPowerWatts: return "GPU power"
        case .ramUsedGB: return "RAM used"
        case .vramUsedGB: return "VRAM used"
        case .networkDownloadMBps: return "Download"
        case .networkUploadMBps: return "Upload"
        }
    }
    var unit: String {
        switch self {
        case .fps: return "FPS"
        case .cpuUsage, .gpuUsage: return "%"
        case .cpuTemp, .gpuTemp: return "°C"
        case .cpuPowerWatts, .gpuPowerWatts: return "W"
        case .ramUsedGB, .vramUsedGB: return "GB"
        case .networkUploadMBps, .networkDownloadMBps: return "MB/s"
        }
    }
    var color: Color {
        switch self {
        case .fps: return .mint
        case .cpuUsage, .cpuTemp, .cpuPowerWatts: return .cyan
        case .gpuUsage, .gpuTemp, .gpuPowerWatts: return .purple
        case .ramUsedGB, .vramUsedGB: return .orange
        case .networkUploadMBps, .networkDownloadMBps: return .blue
        }
    }
    func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let digits = self == .networkUploadMBps || self == .networkDownloadMBps ? 3 : 1
        return value.formatted(.number.precision(.fractionLength(digits))) + " " + unit
    }
}

private struct OrbitHistoryStartBody: Encodable { let name: String? }
private struct OrbitHistoryEmptyBody: Encodable {}
private struct OrbitHistoryStopResponse: Decodable { let session: OrbitHistorySession? }
private struct OrbitHistoryDeleteResponse: Decodable { let deleted: Bool }

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

    var body: some View {
        List {
            Section {
                if vm.isDemoMode {
                    Label("Preview mode · recording is disabled", systemImage: "sparkles")
                        .foregroundStyle(.orange)
                }
                Label("Game sessions are recorded automatically", systemImage: "gamecontroller")
                    .font(.subheadline)
                Text("Orbit Agent saves readings on this PC every 5 seconds. Start a manual session to record desktop work. Up to 100 sessions and 30 days of readings are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }

            if let active = history?.activeSession {
                Section("Recording now") {
                    sessionLink(active)
                    Button {
                        beginAction { client, connection in
                            Task { await stopRecording(client: client, connection: connection) }
                        }
                    } label: {
                        Label("Stop recording", systemImage: "stop.circle")
                            .foregroundStyle(.orange)
                    }
                    .disabled(!canAct)
                }
            }

            Section {
                if isLoading && history == nil {
                    HStack(spacing: 12) { ProgressView(); Text("Reading session history…") }
                } else if (history?.sessions.filter { !$0.isRecording }.isEmpty ?? true) {
                    ContentUnavailableView("No completed sessions", systemImage: "chart.xyaxis.line",
                                           description: Text("Play a detected game with Orbit Agent running, or start a manual recording."))
                } else if let history {
                    ForEach(history.sessions.filter { !$0.isRecording }) { session in
                        sessionLink(session)
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingDelete = session }
                                    .disabled(!canAct)
                            }
                    }
                }
            } header: {
                Text("Session history")
            } footer: {
                Text("Only monitoring values, session names and game process names are saved. Unavailable sensors stay empty. History remains on the selected PC.")
            }
        }
        .navigationTitle("Sessions & graphs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showStart = true } label: { Image(systemName: "plus.circle") }
                    .disabled(!canAct || history?.activeSession?.kind == "manual")
                    .accessibilityLabel("Start manual session")
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
        .alert("Record a PC session", isPresented: $showStart) {
            TextField("Session name (optional)", text: $sessionName)
            Button("Start recording") {
                let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                sessionName = ""
                beginAction { client, connection in
                    Task { await startRecording(name: name.isEmpty ? nil : String(name.prefix(100)), client: client, connection: connection) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A manual recording continues on the PC until you stop it or the agent closes. Starting one completes the current automatic game session.")
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            if let session = pendingDelete {
                Button("Delete session", role: .destructive) {
                    pendingDelete = nil
                    beginAction { client, connection in
                        Task { await delete(session, client: client, connection: connection) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The saved monitoring history for this session will be removed from the selected PC.")
        }
    }

    private var canAct: Bool { vm.metrics.isOnline && !vm.isDemoMode && !isActing && historyConnection == vm.connectionID }

    @MainActor private func beginAction(_ action: (OrbitAPIClient, Int) -> Void) {
        guard canAct else { return }
        do {
            // Capture the selected PC during the user's tap, before scheduling
            // work. A later PC switch cannot redirect a queued action.
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.kind == "auto" ? "gamecontroller" : "record.circle")
                    .foregroundStyle(session.isRecording ? .mint : .cyan)
                    .frame(width: 24).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(session.startedDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(session.durationLabel)
                        Text("·")
                        Text(session.statusLabel)
                        if let average = session.statistics["fps"]?.average, average.isFinite {
                            Text("·")
                            Text("\(average.formatted(.number.precision(.fractionLength(0)))) FPS avg")
                        }
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
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

    init(vm: OrbitViewModel, session: OrbitHistorySession, originConnection: Int) {
        self.vm = vm
        self.session = session
        _originConnection = State(initialValue: originConnection)
    }

    private var samePC: Bool { originConnection == vm.connectionID && !vm.isDemoMode }
    private var currentSession: OrbitHistorySession { detail?.session ?? session }
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
        List {
            if !samePC {
                ContentUnavailableView("PC changed", systemImage: "desktopcomputer",
                                       description: Text("Return to the session list to view history from the selected PC."))
            } else {
                Section {
                    HStack {
                        Label(currentSession.kind == "auto" ? "Game session" : "Manual recording",
                              systemImage: currentSession.kind == "auto" ? "gamecontroller" : "record.circle")
                        Spacer()
                        Text(currentSession.statusLabel).foregroundStyle(currentSession.isRecording ? .mint : .secondary)
                    }
                    .font(.caption)
                    LabeledContent("Started", value: currentSession.startedDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Duration", value: currentSession.durationLabel)
                    if let game = currentSession.gameProcess { LabeledContent("Game process", value: game).font(.caption) }
                    if currentSession.status == "interrupted" {
                        Text("The agent stopped before this session was completed. Its duration ends at the last saved reading.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                }

                Section {
                    Picker("Show graph", selection: $selectedMetric) {
                        ForEach(OrbitHistoryMetric.allCases) { metric in Text(metric.title).tag(metric) }
                    }
                    if isLoading && detail == nil {
                        HStack(spacing: 12) { ProgressView(); Text("Loading readings…") }
                    } else if chartPoints.isEmpty {
                        ContentUnavailableView("No \(selectedMetric.title.lowercased()) readings", systemImage: "waveform.path",
                                               description: Text("This sensor was unavailable during this session. Orbit does not estimate missing values."))
                    } else {
                        chart
                        HStack {
                            statistic("Average", value: currentSession.statistics[selectedMetric.rawValue]?.average)
                            Spacer()
                            statistic("Peak", value: currentSession.statistics[selectedMetric.rawValue]?.peak)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("\(selectedMetric.title) · \(selectedMetric.unit)")
                } footer: {
                    Text(detail?.downsampled == true
                         ? "The graph shows a selection of actual readings. Averages and peaks use every saved reading. Gaps indicate missing data."
                         : "Readings are sampled every 5 seconds. Gaps indicate missing data. Drag across the graph to inspect a reading.")
                }

                Section {
                    ForEach(OrbitHistoryMetric.allCases) { metric in
                        if let statistic = currentSession.statistics[metric.rawValue], statistic.count > 0 {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(metric.title).font(.subheadline)
                                HStack {
                                    Text("Avg \(metric.formatted(statistic.average))")
                                    Spacer()
                                    Text("Peak \(metric.formatted(statistic.peak))")
                                }
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Text("Session averages & peaks")
                } footer: {
                    Text("Power readings describe the measured component, not the entire PC. FPS depends on the monitoring source. Only available readings are included in averages.")
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

    private var chart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(x: .value("Time", point.date), y: .value(selectedMetric.unit, point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(selectedMetric.color)
                    .interpolationMethod(.linear)
                if chartPoints.count < 30 {
                    PointMark(x: .value("Time", point.date), y: .value(selectedMetric.unit, point.value))
                        .foregroundStyle(selectedMetric.color).symbolSize(14)
                }
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected time", point.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 6) {
                        VStack(spacing: 3) {
                            Text(selectedMetric.formatted(point.value)).font(.caption.weight(.semibold).monospacedDigit())
                            Text(point.date, format: .dateTime.hour().minute().second()).font(.caption2)
                        }
                        .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartYScale(domain: .automatic(includesZero: selectedMetric == .cpuUsage || selectedMetric == .gpuUsage))
        .chartXSelection(value: $selectedTime)
        .frame(height: 240)
        .padding(.vertical, 16)
        .accessibilityLabel("\(selectedMetric.title) history in \(selectedMetric.unit)")
    }

    private func statistic(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(selectedMetric.formatted(value)).font(.headline.monospacedDigit())
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
