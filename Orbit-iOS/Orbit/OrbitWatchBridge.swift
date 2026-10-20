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
    private var inputClient: OrbitAPIClient?
    private var inputClientIdentity: CursorRelayIdentity?

    private struct CursorRelayIdentity: Equatable {
        let pcID: String
        let host: String
        let agentPort: Int
        let securePort: Int
        let token: String
        let fingerprint: String
    }

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
            "telemetryTimestamp": vm.lastUpdated?.timeIntervalSince1970 ?? 0,
            "isDemoMode": vm.isDemoMode,
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
            "savedPCs": pcsList
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

    /// A reply confirms the PC accepted this command, not merely that the phone
    /// received a WatchConnectivity message. The target is frozen before awaiting.
    func forwardCursorCommand(_ message: [String: Any]) async -> [String: Any] {
        do {
            guard let vm = viewModel else {
                throw OrbitError(message: "Open Orbit on your iPhone and reconnect your PC.")
            }
            guard !vm.isDemoMode else {
                throw OrbitError(message: "Exit Demo Mode on iPhone to control a real PC.")
            }
            let packetData = try JSONSerialization.data(withJSONObject: message)
            let packet = try JSONDecoder().decode(OrbitCursorPacket.self, from: packetData).validated()
            let now = Date().timeIntervalSince1970
            let deadline = message["expiresAt"] as? Double
            if !packet.isReleaseOnly {
                guard let deadline, deadline.isFinite, deadline > now else {
                    throw OrbitError(message: "The cursor command expired. Try again.")
                }
            }
            guard let pcID = message["pcID"] as? String, !pcID.isEmpty,
                  let requestedHost = message["host"] as? String, !requestedHost.isEmpty,
                  let profile = vm.savedPCs.first(where: {
                      $0.id == pcID && Self.normalizedHost($0.address) == Self.normalizedHost(requestedHost)
                  }) else {
                throw OrbitError(message: "The Watch PC is no longer saved on iPhone. Sync Orbit again.")
            }
            let isCurrentPC = vm.selectedPCID == pcID
                && Self.normalizedHost(vm.cleanHost()) == Self.normalizedHost(requestedHost)
            guard isCurrentPC || packet.isReleaseOnly else {
                throw OrbitError(message: "The selected PC changed on iPhone. Sync Orbit before moving the cursor.")
            }

            let identity: CursorRelayIdentity
            if isCurrentPC {
                identity = CursorRelayIdentity(pcID: pcID, host: vm.cleanHost(), agentPort: vm.agentPort,
                                               securePort: vm.securePort, token: vm.apiToken,
                                               fingerprint: OrbitAPIClient.normalizedFingerprint(vm.certificateFingerprint))
            } else {
                // Only release a previously held button on an old saved PC. Never
                // reinterpret an old motion/click as input for the newly selected PC.
                identity = CursorRelayIdentity(pcID: pcID, host: profile.address, agentPort: profile.agentPort,
                                               securePort: profile.securePort, token: PCProfileStore.token(profile.id),
                                               fingerprint: OrbitAPIClient.normalizedFingerprint(profile.certificateFingerprint))
            }
            let client: OrbitAPIClient
            if let cached = inputClient, inputClientIdentity == identity {
                client = cached
            } else {
                client = try isCurrentPC ? vm.companionClient() : OrbitAPIClient(
                    host: identity.host, port: identity.securePort, token: identity.token, fingerprint: identity.fingerprint)
                inputClient = client
                inputClientIdentity = identity
            }
            var query = [
                URLQueryItem(name: "dx", value: String(packet.dx)),
                URLQueryItem(name: "dy", value: String(packet.dy)),
                URLQueryItem(name: "click", value: packet.click),
                URLQueryItem(name: "scroll", value: String(packet.scroll)),
                URLQueryItem(name: "hscroll", value: String(packet.hscroll)),
                URLQueryItem(name: "drag", value: packet.drag)
            ]
            if let x = packet.normX, let y = packet.normY {
                query.append(URLQueryItem(name: "normX", value: String(x)))
                query.append(URLQueryItem(name: "normY", value: String(y)))
            }
            // iPhone polling can be suspended while it relays Watch commands, so
            // stale telemetry must not gate a genuine, authenticated HTTP attempt.
            let remaining = packet.isReleaseOnly ? 4 : min(4, (deadline ?? now) - Date().timeIntervalSince1970)
            guard remaining > 0 else { throw OrbitError(message: "The cursor command expired. Try again.") }
            let data = try await Self.sendCursorRequest(client: client, query: query, timeout: remaining)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard result?["status"] as? String == "sent" else {
                throw OrbitError(message: "The PC did not confirm the cursor command. Update the Orbit PC Companion.")
            }
            return ["status": "sent", "pcID": pcID]
        } catch {
            return ["status": "failed", "message": error.localizedDescription]
        }
    }

    private static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func sendCursorRequest(client: OrbitAPIClient, query: [URLQueryItem], timeout: Double) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await client.data("/api/input/cursor", method: "POST", query: query) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OrbitError(message: "The PC did not respond to cursor control. Check the companion and local network.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
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
                let result = await forwardCursorCommand(message)
                replyHandler?(result)
                if result["status"] as? String == "failed", let failure = result["message"] as? String {
                    vm.statusLog = "Watch cursor: \(failure)"
                }
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
