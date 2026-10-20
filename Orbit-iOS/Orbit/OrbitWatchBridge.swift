import Foundation
import SwiftUI
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@MainActor
final class OrbitWatchBridge: NSObject, ObservableObject {
    static let shared = OrbitWatchBridge()

    @Published private(set) var isWatchSupported = false
    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isWatchReachable = false
    @Published private(set) var lastWatchSync: Date?

    weak var viewModel: OrbitViewModel?
    private var lastContextPushTime: Date = .distantPast
    private var inputSocket: URLSessionWebSocketTask?
    private var inputClient: OrbitAPIClient?
    private var inputSocketHost: String = ""

    private override init() {
        super.init()
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            isWatchSupported = true
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        #endif
    }

    func attach(to viewModel: OrbitViewModel) {
        self.viewModel = viewModel
        pushStateToWatch(force: true)
    }

    func buildSyncPayload() -> [String: Any] {
        guard let vm = viewModel else { return [:] }
        let theme = OrbitTheme(rawValue: UserDefaults.standard.string(forKey: "orbit.theme") ?? "") ?? .ocean
        let ramPct = vm.metrics.ramTotalGB > 0 ? (vm.metrics.ramUsedGB / vm.metrics.ramTotalGB * 100.0) : 0.0
        let gamesList: [[String: String]] = vm.games.prefix(16).map {
            ["id": $0.id, "title": $0.title, "genre": $0.genre]
        }
        let pcsList: [[String: Any]] = vm.savedPCs.prefix(10).map { pc in
            [
                "id": pc.id,
                "name": pc.name,
                "address": pc.address,
                "agentPort": pc.agentPort,
                "securePort": pc.securePort,
                "certificateFingerprint": pc.certificateFingerprint,
                "macAddress": pc.macAddress,
                "subnetMask": pc.subnetMask,
                "broadcastAddress": pc.broadcastAddress,
                "wolPort": pc.wolPort,
                "lastKnownIPv4": pc.lastKnownIPv4 ?? "",
                "apiToken": PCProfileStore.token(pc.id)
            ]
        }

        var payload: [String: Any] = [
            "type": "stateSync",
            "timestamp": Date().timeIntervalSince1970,
            "selectedPCID": vm.selectedPCID,
            "pcName": vm.selectedPCName,
            "host": vm.cleanHost(),
            "agentPort": vm.agentPort,
            "securePort": vm.securePort,
            "certificateFingerprint": vm.certificateFingerprint,
            "apiToken": vm.apiToken,
            "widgetToken": vm.widgetToken ?? "",
            "macAddress": vm.pcMAC,
            "broadcastAddress": vm.wolTargetIP,
            "subnetMask": vm.subnetMask,
            "wolPort": vm.wolPort,
            "lastKnownIPv4": vm.lastKnownPCIPv4,
            "isOnline": vm.metrics.isOnline,
            "telemetryAvailable": vm.metrics.telemetryAvailable ?? false,
            "cpuUsage": vm.metrics.cpuUsage,
            "ramUsagePercent": ramPct,
            "ramUsedGB": vm.metrics.ramUsedGB,
            "ramTotalGB": vm.metrics.ramTotalGB,
            "volume": vm.metrics.volume,
            "isMuted": vm.metrics.isMuted,
            "uptimeSeconds": vm.metrics.uptimeSeconds,
            "pingMs": vm.pingMs,
            "isLiveActivityActive": vm.isDynamicIslandActive,
            "statusLog": vm.statusLog,
            "games": gamesList,
            "savedPCs": pcsList,
            "theme": theme.rawValue,
            "themeAccentHex": theme.accentHex,
            "themeSecondaryHex": theme.secondaryHex
        ]
        if let cpuTemp = vm.metrics.cpuTemp { payload["cpuTemp"] = cpuTemp }
        if let gpuUsage = vm.metrics.gpuUsage { payload["gpuUsage"] = gpuUsage }
        if let gpuTemp = vm.metrics.gpuTemp { payload["gpuTemp"] = gpuTemp }
        if let cpuPower = vm.metrics.cpuPowerWatts { payload["cpuPowerWatts"] = cpuPower }
        if let gpuPower = vm.metrics.gpuPowerWatts { payload["gpuPowerWatts"] = gpuPower }
        if let fps = vm.metrics.fps { payload["fps"] = fps }
        if let game = vm.metrics.activeGame { payload["activeGame"] = game }
        return payload
    }

    func pushStateToWatch(force: Bool = false) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable

        let now = Date()
        guard force || now.timeIntervalSince(lastContextPushTime) >= 2.0 else { return }
        lastContextPushTime = now

        let payload = buildSyncPayload()
        guard !payload.isEmpty else { return }
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        lastWatchSync = now
        #endif
    }

    func forwardCursorCommand(_ message: [String: Any]) async {
        guard let vm = viewModel, vm.metrics.isOnline, !vm.isDemoMode else { return }
        let dx = message["dx"] as? Int ?? 0
        let dy = message["dy"] as? Int ?? 0
        let click = message["click"] as? String ?? ""
        let scroll = message["scroll"] as? Int ?? 0
        let hscroll = message["hscroll"] as? Int ?? 0
        let drag = message["drag"] as? String ?? ""
        let normX = message["normX"] as? Double
        let normY = message["normY"] as? Double

        let hostKey = "\(vm.cleanHost()):\(vm.securePort):\(vm.agentPort)"
        if inputSocket == nil || inputSocketHost != hostKey {
            inputSocket?.cancel(with: .goingAway, reason: nil)
            inputSocket = nil
            inputClient = nil
            inputSocketHost = hostKey
            if vm.hasSecureConnection, let client = try? vm.companionClient(), let ws = try? client.inputWebSocket() {
                inputClient = client
                inputSocket = ws
                ws.resume()
            }
        }

        if let ws = inputSocket {
            var json: [String: Any] = ["dx": dx, "dy": dy, "click": click, "scroll": scroll, "hscroll": hscroll, "drag": drag]
            if let normX, let normY {
                json["normX"] = normX
                json["normY"] = normY
            }
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let text = String(data: data, encoding: .utf8) {
                do {
                    try await ws.send(.string(text))
                    return
                } catch {
                    inputSocket?.cancel(with: .goingAway, reason: nil)
                    inputSocket = nil
                }
            }
        }

        await vm.sendCursorInput(dx: dx, dy: dy, click: click, scroll: scroll, hscroll: hscroll, normX: normX, normY: normY, drag: drag)
    }

    private func handleIncomingWatchMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        guard let cmd = message["cmd"] as? String, let vm = viewModel else {
            replyHandler?(["status": "unavailable"])
            return
        }

        switch cmd {
        case "requestSync":
            let payload = buildSyncPayload()
            replyHandler?(payload)
        case "wake":
            Task {
                await vm.wakePC()
                pushStateToWatch(force: true)
                replyHandler?(buildSyncPayload())
            }
        case "powerAction":
            let action = message["action"] as? String ?? ""
            Task {
                await vm.sendPowerAction(action)
                pushStateToWatch(force: true)
                replyHandler?(buildSyncPayload())
            }
        case "volume":
            if let level = message["level"] as? Double {
                Task {
                    await vm.updateVolume(level)
                    pushStateToWatch(force: true)
                    replyHandler?(buildSyncPayload())
                }
            }
        case "cursor":
            Task {
                await forwardCursorCommand(message)
                replyHandler?(["status": "ok"])
            }
        case "toggleLiveActivity":
            vm.toggleDynamicIsland()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                pushStateToWatch(force: true)
                replyHandler?(buildSyncPayload())
            }
        case "launchGame":
            if let title = message["title"] as? String {
                let game = vm.games.first(where: { $0.title == title }) ?? SunshineGame(id: title, title: title, genre: "Watch Launch", iconSymbol: "gamecontroller.fill", accentHex: "#57C8FF")
                Task {
                    await vm.smartLaunch(game: game)
                    pushStateToWatch(force: true)
                    replyHandler?(buildSyncPayload())
                }
            }
        case "selectPC":
            if let id = message["id"] as? String, let profile = vm.savedPCs.first(where: { $0.id == id }) {
                vm.selectPC(profile)
                Task {
                    await vm.connect()
                    pushStateToWatch(force: true)
                    replyHandler?(buildSyncPayload())
                }
            }
        default:
            replyHandler?(["status": "unknown_cmd"])
        }
    }
}

#if canImport(WatchConnectivity)
extension OrbitWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isWatchPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
            if activationState == .activated {
                self.pushStateToWatch(force: true)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
            if session.isReachable {
                self.pushStateToWatch(force: true)
            }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleIncomingWatchMessage(message, replyHandler: nil)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.handleIncomingWatchMessage(message, replyHandler: replyHandler)
        }
    }
}
#endif
