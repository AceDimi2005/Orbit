import Foundation
import MoonlightCore
import SwiftUI
import UIKit
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
            "sessionLocked": vm.metrics.sessionLocked == true,
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
        // The watch takes the accent chosen on iPhone (RRGGBB; empty means Orbit Blue).
        let theme = OrbitTheme(rawValue: UserDefaults.standard.string(forKey: "orbit.theme") ?? "") ?? .noir
        payload["tintHex"] = theme == .noir ? "" : Self.hex(theme.orbitTint)
        return payload
    }

    private static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
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

    private static func sendCursorRequest(client: OrbitAPIClient, query: [URLQueryItem], timeout: Double, path: String = "/api/input/cursor") async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await client.data(path, method: "POST", query: query) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OrbitError(message: "The PC did not respond to cursor control. Check the companion and local network.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Bind every remote control to a PC, and acknowledge the actual operation.
    /// The normal iPhone UI methods intentionally consume errors for UI feedback;
    /// using them here would report success even when no PC received the command.
    private func forwardPCCommand(_ message: [String: Any]) async -> [String: Any] {
        do {
            guard let vm = viewModel, !vm.isDemoMode,
                  let pcID = message["pcID"] as? String, !pcID.isEmpty,
                  pcID == vm.selectedPCID,
                  let host = message["host"] as? String,
                  Self.normalizedHost(host) == Self.normalizedHost(vm.cleanHost()),
                  let deadline = message["expiresAt"] as? Double, deadline.isFinite,
                  deadline > Date().timeIntervalSince1970 else {
                throw OrbitError(message: "Sync the selected PC with your iPhone, then try again.")
            }
            let cmd = message["cmd"] as? String ?? ""
            if cmd == "wake" {
                guard (1...65535).contains(vm.wolPort) else { throw OrbitError(message: "Invalid Wake-on-LAN port.") }
                let ip = WakeOnLANService.ipv4ForWake(host: vm.cleanHost(), knownAddress: vm.lastKnownPCIPv4)
                // Return as soon as UDP accepts the packet. Waiting for the PC to
                // boot here would exceed WatchConnectivity's interactive deadline.
                try await WakeOnLANService.sendMagicPacket(macAddress: vm.pcMAC, pcIP: ip,
                    targetBroadcastIP: vm.wolTargetIP, subnetMask: vm.subnetMask, port: UInt16(vm.wolPort))
            } else {
                let client = try vm.companionClient()
                let path: String
                var query: [URLQueryItem] = []
                switch cmd {
                case "powerAction":
                    let action = message["action"] as? String ?? ""
                    let allowed = ["lock", "sleep", "restart", "shutdown", "mute", "volume_up", "volume_down",
                                   "media_play_pause", "media_next", "media_prev", "toggle_hdr", "restore_display",
                                   "kill_game", "show_desktop", "task_view", "alt_tab", "screenshot", "fullscreen"]
                    guard allowed.contains(action) else { throw OrbitError(message: "Unsupported PC action.") }
                    path = "/api/action/" + action
                case "volume":
                    guard let level = message["level"] as? Double, level.isFinite else { throw OrbitError(message: "Invalid volume.") }
                    path = "/api/volume"
                    query = [URLQueryItem(name: "level", value: String(Int(min(100, max(0, level.rounded())))))]
                case "launchGame":
                    guard let title = message["title"] as? String, !title.isEmpty, title.count <= 200 else {
                        throw OrbitError(message: "Select a game from your PC library.")
                    }
                    path = "/api/sunshine/launch"
                    query = [URLQueryItem(name: "app", value: title)]
                default: throw OrbitError(message: "Unsupported PC command.")
                }
                let timeout = min(4, deadline - Date().timeIntervalSince1970)
                guard timeout > 0 else { throw OrbitError(message: "The command expired. Try again.") }
                _ = try await Self.sendCursorRequest(client: client, query: query, timeout: timeout, path: path)
                if vm.selectedPCID == pcID, Self.normalizedHost(vm.cleanHost()) == Self.normalizedHost(host) {
                    if cmd == "volume", let level = message["level"] as? Double { vm.metrics.volume = min(100, max(0, level.rounded())) }
                    if cmd == "powerAction", let action = message["action"] as? String {
                        if ["sleep", "restart", "shutdown"].contains(action) { vm.metrics.isOnline = false }
                        if action == "mute" { vm.metrics.isMuted.toggle() }
                    }
                }
            }
            return ["status": "sent", "pcID": pcID]
        } catch { return ["status": "failed", "message": error.localizedDescription] }
    }

    /// The Watch asked to sign in to the locked PC: the password it sent is typed through a short
    /// headless Sunshine stream (the only channel that reaches the Windows sign-in screen) and
    /// then forgotten.
    @MainActor
    private func unlockPC(_ message: [String: Any]) async -> [String: Any] {
        guard let vm = viewModel, !vm.isDemoMode else { return ["status": "failed", "message": "Connect a real PC first."] }
        guard let password = message["password"] as? String, !password.isEmpty, password.count <= 256 else {
            return ["status": "failed", "message": "Enter the Windows password on the watch."]
        }
        #if canImport(UIKit)
        let task = UIApplication.shared.beginBackgroundTask(withName: "OrbitUnlockPC")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        #endif
        let host = MoonlightHostCoordinator()
        host.configure(pcID: vm.selectedPCID, address: vm.cleanHost(),
                       httpPort: vm.sunshineInfo?.httpPort ?? 47989, httpsPort: vm.sunshineInfo?.httpsPort ?? 47984)
        guard host.isPaired else {
            return ["status": "failed", "message": "Pair Orbit with Sunshine on the iPhone first; the sign-in goes through the stream."]
        }
        do {
            try await host.unlockThroughStream(password: password, settings: MoonlightStreamSettingsStore.shared.settings)
            return ["status": "sent", "pcID": vm.selectedPCID]
        } catch {
            return ["status": "failed", "message": (error as? MoonlightError)?.message ?? error.localizedDescription]
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
        case "wake", "powerAction", "volume", "launchGame":
            Task {
                let result = await forwardPCCommand(message)
                replyHandler?(result)
                if result["status"] as? String == "failed", let failure = result["message"] as? String {
                    vm.statusLog = "Watch: \(failure)"
                }
            }
        case "unlockPC":
            Task {
                let result = await unlockPC(message)
                replyHandler?(result)
                if result["status"] as? String == "failed", let failure = result["message"] as? String {
                    vm.statusLog = "Watch unlock: \(failure)"
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
