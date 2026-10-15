import ActivityKit
import Combine
import Foundation

@MainActor
final class OrbitLiveActivityCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private var activity: Activity<OrbitActivityAttributes>?
    private var stateTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast

    init() {
        if let existing = Activity<OrbitActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) {
            observe(existing)
        }
    }

    deinit { stateTask?.cancel() }

    func start(pcName: String, cpuUsage: Double?, gpuUsage: Double?, ramUsage: Double?, fps: Double?, gameName: String?, vramUsedGB: Double? = nil, vramTotalGB: Double? = nil, cpuPowerWatts: Double? = nil, gpuPowerWatts: Double? = nil, focus: String = "overview", telemetryAvailable: Bool = true) async {
        lastError = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "Live Activities are unavailable or disabled. Enable them for Orbit in iPhone Settings."
            return
        }
        if isActive {
            await update(cpuUsage: cpuUsage, gpuUsage: gpuUsage, ramUsage: ramUsage, fps: fps, gameName: gameName, isConnected: true, vramUsedGB: vramUsedGB, vramTotalGB: vramTotalGB, cpuPowerWatts: cpuPowerWatts, gpuPowerWatts: gpuPowerWatts, focus: focus, telemetryAvailable: telemetryAvailable)
            return
        }
        let state = snapshot(cpuUsage: cpuUsage, gpuUsage: gpuUsage, ramUsage: ramUsage, fps: fps, gameName: gameName, isConnected: true, vramUsedGB: vramUsedGB, vramTotalGB: vramTotalGB, cpuPowerWatts: cpuPowerWatts, gpuPowerWatts: gpuPowerWatts, focus: focus, telemetryAvailable: telemetryAvailable)
        do {
            let created = try Activity.request(
                attributes: OrbitActivityAttributes(pcName: String(pcName.prefix(80))),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)),
                pushType: nil
            )
            lastPublishedAt = Date()
            observe(created)
        } catch {
            lastError = "Could not start Live Activity: \(error.localizedDescription)"
        }
    }

    /// Called after successful polling, or once with isConnected=false on failure.
    /// iOS may suspend polling when Orbit is in the background. The stale date
    /// makes that limitation visible instead of presenting old numbers as live.
    func update(cpuUsage: Double?, gpuUsage: Double?, ramUsage: Double?, fps: Double?, gameName: String?, isConnected: Bool, vramUsedGB: Double? = nil, vramTotalGB: Double? = nil, cpuPowerWatts: Double? = nil, gpuPowerWatts: Double? = nil, focus: String = "overview", telemetryAvailable: Bool = true) async {
        guard let activity, isActive else { return }
        let connectionChanged = activity.content.state.isConnected != isConnected
        let availabilityChanged = activity.content.state.telemetryAvailable != telemetryAvailable
        guard connectionChanged || availabilityChanged || Date().timeIntervalSince(lastPublishedAt) >= 5 else { return }
        lastPublishedAt = Date()
        let state = snapshot(cpuUsage: cpuUsage, gpuUsage: gpuUsage, ramUsage: ramUsage, fps: fps, gameName: gameName, isConnected: isConnected, vramUsedGB: vramUsedGB, vramTotalGB: vramTotalGB, cpuPowerWatts: cpuPowerWatts, gpuPowerWatts: gpuPowerWatts, focus: focus, telemetryAvailable: telemetryAvailable)
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)))
    }

    func stop() async {
        stateTask?.cancel()
        stateTask = nil
        activity = nil
        isActive = false
        lastError = nil
        // End any restored session too, so a relaunch cannot leave a duplicate.
        for existing in Activity<OrbitActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observe(_ activity: Activity<OrbitActivityAttributes>) {
        self.activity = activity
        isActive = true
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if state == .ended || state == .dismissed {
                    self.isActive = false
                    self.activity = nil
                    return
                }
            }
        }
    }

    private func snapshot(cpuUsage: Double?, gpuUsage: Double?, ramUsage: Double?, fps: Double?, gameName: String?, isConnected: Bool, vramUsedGB: Double?, vramTotalGB: Double?, cpuPowerWatts: Double?, gpuPowerWatts: Double?, focus: String, telemetryAvailable: Bool) -> OrbitActivityAttributes.ContentState {
        func percentage(_ value: Double?) -> Double? {
            guard telemetryAvailable, let value, value.isFinite else { return nil }
            return min(100, max(0, value))
        }
        func nonnegative(_ value: Double?) -> Double? {
            telemetryAvailable ? value.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 ? $0 : nil } : nil
        }
        return OrbitActivityAttributes.ContentState(
            cpuUsage: percentage(cpuUsage), gpuUsage: percentage(gpuUsage), ramUsage: percentage(ramUsage),
            fps: telemetryAvailable ? fps.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100_000 ? $0 : nil } : nil,
            gameName: telemetryAvailable ? gameName.map { String($0.prefix(80)) } : nil,
            isConnected: isConnected, lastUpdated: Date(),
            vramUsedGB: nonnegative(vramUsedGB), vramTotalGB: nonnegative(vramTotalGB),
            cpuPowerWatts: nonnegative(cpuPowerWatts), gpuPowerWatts: nonnegative(gpuPowerWatts),
            focus: ["overview", "gaming", "power"].contains(focus) ? focus : "overview",
            telemetryAvailable: telemetryAvailable
        )
    }
}
