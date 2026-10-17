import CoreMotion
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

struct WatchPCProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var address: String
    var agentPort: Int = 8765
    var securePort: Int = 8766
    var certificateFingerprint: String = ""
    var macAddress: String = ""
    var subnetMask: String = "255.255.255.0"
    var broadcastAddress: String = ""
    var wolPort: Int = 9
    var lastKnownIPv4: String = ""
    var apiToken: String = ""
}

struct WatchSunshineGame: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var genre: String
}

enum WatchCursorMode: String, CaseIterable, Identifiable {
    case gyroGlide = "Gyro Glide"
    case laserPointer = "Laser Pointer"
    case touchPad = "Touchpad"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .gyroGlide: "gyroscope"
        case .laserPointer: "scope"
        case .touchPad: "hand.draw.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .gyroGlide: "Tilt & turn wrist to glide cursor"
        case .laserPointer: "Point wrist directly at screen area"
        case .touchPad: "Swipe screen & scroll with Crown"
        }
    }
}

struct WatchSummaryResponse: Decodable {
    var hostname: String?
    var agentVersion: String?
    var isOnline: Bool?
    var telemetryAvailable: Bool?
    var cpuUsage: Double?
    var cpuTemp: Double?
    var gpuUsage: Double?
    var gpuTemp: Double?
    var ramUsagePercent: Double?
    var ramUsedGB: Double?
    var ramTotalGB: Double?
    var cpuPowerWatts: Double?
    var gpuPowerWatts: Double?
    var activeGame: String?
    var fps: Double?
    var volume: Double?
    var isMuted: Bool?
    var uptimeSeconds: Int?
}

@MainActor
final class OrbitWatchViewModel: NSObject, ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var pcName: String = "Your PC"
    @Published var selectedPCID: String = ""
    @Published var host: String = ""
    @Published var agentPort: Int = 8765
    @Published var securePort: Int = 8766
    @Published var certificateFingerprint: String = ""
    @Published var apiToken: String = ""
    @Published var macAddress: String = ""
    @Published var broadcastAddress: String = ""
    @Published var subnetMask: String = "255.255.255.0"
    @Published var wolPort: Int = 9
    @Published var lastKnownIPv4: String = ""

    @Published var isOnline: Bool = false
    @Published var isPhoneReachable: Bool = false
    @Published var telemetryAvailable: Bool = false
    @Published var cpuUsage: Double = 0
    @Published var cpuTemp: Double? = nil
    @Published var gpuUsage: Double? = nil
    @Published var gpuTemp: Double? = nil
    @Published var ramUsagePercent: Double = 0
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var cpuPowerWatts: Double? = nil
    @Published var gpuPowerWatts: Double? = nil
    @Published var activeGame: String? = nil
    @Published var fps: Double? = nil
    @Published var volume: Double = 40
    @Published var isMuted: Bool = false
    @Published var uptimeSeconds: Int = 0
    @Published var pingMs: Int = 0
    @Published var isLiveActivityActive: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var isWaking: Bool = false
    @Published var savedPCs: [WatchPCProfile] = []
    @Published var games: [WatchSunshineGame] = []

    // Wrist Motion Air Mouse state
    @Published var isMotionCursorActive: Bool = false
    @Published var motionMode: WatchCursorMode = .gyroGlide
    @Published var sensitivity: Double = 1.2
    @Published var isDragLocked: Bool = false
    @Published var cursorIndicatorOffset: CGSize = .zero
    @Published var crownScrollAccumulator: Double = 0.0

    private let motionManager = CMMotionManager()
    private var neutralPitch: Double?
    private var neutralRoll: Double?
    private var neutralYaw: Double?
    private var smoothedDX: Double = 0
    private var smoothedDY: Double = 0
    private var lastMotionSentAt: Date = .distantPast
    private var lastCrownScrollValue: Double = 0
    private var lastVolumeSentAt: Date = .distantPast
    private var thermalAlertTriggered: Bool = false

    private var pollTask: Task<Void, Never>?
    private var appActive: Bool = true
    private var inputWebSocket: URLSessionWebSocketTask?
    private var inputSession: URLSession?
    private var inputDelegate: WatchPinnedTLSDelegate?

    private static let appGroupID = "group.com.dimitrie.orbit"
    private static let snapshotKey = "Orbit.WatchSnapshot.v1"

    override init() {
        super.init()
        loadCachedState()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        startPollingLoop()
    }

    var formattedUptime: String {
        guard uptimeSeconds > 0 else { return "—" }
        return "\(uptimeSeconds / 3600)h \((uptimeSeconds % 3600) / 60)m"
    }

    var hasDirectCredentials: Bool {
        !host.isEmpty && !apiToken.isEmpty
    }

    var hasSecureTLS: Bool {
        let clean = certificateFingerprint.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        return clean.count == 64 && clean.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if active {
            startPollingLoop()
            requestSyncFromPhone()
        } else {
            stopMotionCursor()
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func handleDeepLink(_ url: URL) {
        let hostOrPath = (url.host ?? url.path).lowercased()
        if hostOrPath.contains("power") || hostOrPath.contains("wake") {
            selectedTab = 1
            if hostOrPath.contains("wake") {
                Task { await wakePC() }
            }
        } else if hostOrPath.contains("cursor") || hostOrPath.contains("mouse") || hostOrPath.contains("remote") {
            selectedTab = 2
        } else if hostOrPath.contains("media") || hostOrPath.contains("volume") {
            selectedTab = 3
        } else {
            selectedTab = 0
        }
    }

    // MARK: - Polling & Sync

    func startPollingLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTelemetry()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func requestSyncFromPhone() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if !session.receivedApplicationContext.isEmpty {
            applyPhonePayload(session.receivedApplicationContext)
        }
        if session.isReachable {
            isPhoneReachable = true
            session.sendMessage(["cmd": "requestSync"]) { [weak self] reply in
                Task { @MainActor in
                    self?.applyPhonePayload(reply)
                }
            } errorHandler: { _ in }
        }
    }

    func refreshTelemetry() async {
        guard appActive else { return }
        if !hasDirectCredentials, let widgetConn = OrbitWidgetConnectionStore.defaultConnection() {
            host = widgetConn.host
            securePort = widgetConn.port
            certificateFingerprint = widgetConn.certificateSHA256
            pcName = widgetConn.name
            macAddress = widgetConn.macAddress ?? macAddress
            broadcastAddress = widgetConn.broadcastAddress ?? broadcastAddress
            subnetMask = widgetConn.subnetMask ?? subnetMask
            wolPort = widgetConn.wolPort ?? wolPort
            lastKnownIPv4 = widgetConn.lastKnownIPv4 ?? lastKnownIPv4
            if let token = try? OrbitWidgetConnectionStore.controlToken(for: widgetConn.id), !token.isEmpty {
                apiToken = token
            }
        }

        if hasDirectCredentials {
            let start = Date()
            do {
                let data = try await performPCRequest(path: "/api/watch/summary", method: "GET")
                let summary = try JSONDecoder().decode(WatchSummaryResponse.self, from: data)
                isOnline = summary.isOnline ?? true
                telemetryAvailable = summary.telemetryAvailable ?? true
                if let name = summary.hostname, !name.isEmpty { pcName = name }
                cpuUsage = summary.cpuUsage ?? 0
                cpuTemp = summary.cpuTemp
                gpuUsage = summary.gpuUsage
                gpuTemp = summary.gpuTemp
                ramUsagePercent = summary.ramUsagePercent ?? 0
                ramUsedGB = summary.ramUsedGB ?? 0
                ramTotalGB = summary.ramTotalGB ?? 0
                cpuPowerWatts = summary.cpuPowerWatts
                gpuPowerWatts = summary.gpuPowerWatts
                activeGame = summary.activeGame
                fps = summary.fps
                if Date().timeIntervalSince(lastVolumeSentAt) > 2.5 {
                    volume = summary.volume ?? volume
                }
                isMuted = summary.isMuted ?? isMuted
                uptimeSeconds = summary.uptimeSeconds ?? uptimeSeconds
                pingMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
                statusMessage = "Live · \(pingMs) ms"
                checkThermalHapticAlert()
                saveSnapshotForComplications()
                return
            } catch {
                // Fallback to /api/status for 4.1.0 PC Companion agents
                if let data = try? await performPCRequest(path: "/api/status", method: "GET"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isOnline = true
                    telemetryAvailable = (json["telemetryAvailable"] as? Bool) ?? true
                    if let name = json["hostname"] as? String, !name.isEmpty { pcName = name }
                    cpuUsage = (json["cpuUsage"] as? Double) ?? 0
                    cpuTemp = json["cpuTemp"] as? Double
                    gpuUsage = json["gpuUsage"] as? Double
                    gpuTemp = json["gpuTemp"] as? Double
                    ramUsedGB = (json["ramUsedGB"] as? Double) ?? 0
                    ramTotalGB = (json["ramTotalGB"] as? Double) ?? 0
                    ramUsagePercent = ramTotalGB > 0 ? (ramUsedGB / ramTotalGB * 100.0) : 0
                    cpuPowerWatts = json["cpuPowerWatts"] as? Double
                    gpuPowerWatts = json["gpuPowerWatts"] as? Double
                    activeGame = json["activeGame"] as? String
                    fps = json["fps"] as? Double
                    if Date().timeIntervalSince(lastVolumeSentAt) > 2.5 {
                        volume = (json["volume"] as? Double) ?? volume
                    }
                    isMuted = (json["isMuted"] as? Bool) ?? isMuted
                    uptimeSeconds = (json["uptimeSeconds"] as? Int) ?? uptimeSeconds
                    pingMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
                    statusMessage = "Live · \(pingMs) ms"
                    checkThermalHapticAlert()
                    saveSnapshotForComplications()
                    return
                }
            }
        }

        // If direct LAN didn't respond, request fresh state via iPhone WatchConnectivity
        if WCSession.isSupported() && WCSession.default.isReachable {
            requestSyncFromPhone()
        }
    }

    private func checkThermalHapticAlert() {
        let maxTemp = max(cpuTemp ?? 0, gpuTemp ?? 0)
        if maxTemp >= 88 {
            if !thermalAlertTriggered {
                thermalAlertTriggered = true
                WKInterfaceDevice.current().play(.notification)
            }
        } else if maxTemp < 82 {
            thermalAlertTriggered = false
        }
    }

    // MARK: - Power, Media & Desktop Actions

    func wakePC() async {
        guard !isWaking else { return }
        isWaking = true
        defer { isWaking = false }
        WKInterfaceDevice.current().play(.start)
        statusMessage = "Sending Wake-on-LAN…"

        // 1. Relay via iPhone if reachable
        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "wake"], replyHandler: { [weak self] reply in
                Task { @MainActor in self?.applyPhonePayload(reply) }
            }, errorHandler: nil)
        }

        // 2. Also send UDP Magic Packet directly from Watch over Wi-Fi / shared store
        do {
            _ = try await OrbitWidgetPowerService.wakePC(id: selectedPCID.isEmpty ? nil : selectedPCID)
            statusMessage = "Magic Packet sent"
            WKInterfaceDevice.current().play(.success)
        } catch {
            if sendDirectMagicPacket() {
                statusMessage = "Magic Packet sent"
                WKInterfaceDevice.current().play(.success)
            } else if WCSession.isSupported() && WCSession.default.isReachable {
                statusMessage = "Wake sent via iPhone"
            } else {
                statusMessage = "Pair PC on iPhone first"
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    func sendPowerAction(_ action: String) async {
        WKInterfaceDevice.current().play(.click)
        let label = action.replacingOccurrences(of: "_", with: " ").capitalized
        statusMessage = "Sending \(label)…"

        if hasDirectCredentials {
            do {
                _ = try await performPCRequest(path: "/api/action/\(action)", method: "POST")
                statusMessage = "\(label) sent"
                if ["shutdown", "sleep", "restart"].contains(action) {
                    isOnline = false
                    stopMotionCursor()
                }
                if action == "mute" { isMuted.toggle() }
                WKInterfaceDevice.current().play(.success)
                saveSnapshotForComplications()
                return
            } catch {
                // Fall through to iPhone relay
            }
        }

        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "powerAction", "action": action], replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.applyPhonePayload(reply)
                    self?.statusMessage = "\(label) sent"
                }
            }, errorHandler: nil)
            return
        }

        // Fallback to OrbitWidgetPowerService for shutdown/sleep/restart
        if ["shutdown", "sleep", "restart", "lock"].contains(action) {
            if let message = try? await OrbitWidgetPowerService.sendPowerAction(action, id: selectedPCID.isEmpty ? nil : selectedPCID) {
                statusMessage = message
            }
        }
    }

    func setPCVolume(_ newVolume: Double) {
        let clamped = min(100, max(0, newVolume.rounded()))
        guard abs(clamped - volume) >= 1 else { return }
        volume = clamped
        lastVolumeSentAt = Date()

        Task {
            if hasDirectCredentials {
                if (try? await performPCRequest(path: "/api/volume", method: "POST", query: [URLQueryItem(name: "level", value: "\(Int(clamped))")])) != nil {
                    return
                }
            }
            if WCSession.isSupported() && WCSession.default.isReachable {
                WCSession.default.sendMessage(["cmd": "volume", "level": clamped], replyHandler: nil, errorHandler: nil)
            }
        }
    }

    func togglePhoneLiveActivity() {
        WKInterfaceDevice.current().play(.click)
        guard WCSession.isSupported() && WCSession.default.isReachable else {
            statusMessage = "Open Orbit on iPhone nearby"
            return
        }
        statusMessage = isLiveActivityActive ? "Stopping Live Activity…" : "Starting Live Activity…"
        WCSession.default.sendMessage(["cmd": "toggleLiveActivity"]) { [weak self] reply in
            Task { @MainActor in
                self?.applyPhonePayload(reply)
            }
        } errorHandler: { _ in }
    }

    func launchGame(_ game: WatchSunshineGame) {
        WKInterfaceDevice.current().play(.start)
        statusMessage = "Launching \(game.title)…"
        Task {
            if hasDirectCredentials && isOnline {
                if (try? await performPCRequest(path: "/api/sunshine/launch", method: "POST", query: [URLQueryItem(name: "app", value: game.title)])) != nil {
                    statusMessage = "Launched \(game.title)"
                    WKInterfaceDevice.current().play(.success)
                    return
                }
            }
            if WCSession.isSupported() && WCSession.default.isReachable {
                WCSession.default.sendMessage(["cmd": "launchGame", "title": game.title], replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        self?.applyPhonePayload(reply)
                        self?.statusMessage = "Launched \(game.title)"
                    }
                }, errorHandler: nil)
            }
        }
    }

    func selectPC(_ profile: WatchPCProfile) {
        WKInterfaceDevice.current().play(.click)
        selectedPCID = profile.id
        pcName = profile.name
        host = profile.address
        agentPort = profile.agentPort
        securePort = profile.securePort
        certificateFingerprint = profile.certificateFingerprint
        macAddress = profile.macAddress
        subnetMask = profile.subnetMask
        broadcastAddress = profile.broadcastAddress
        wolPort = profile.wolPort
        lastKnownIPv4 = profile.lastKnownIPv4
        apiToken = profile.apiToken
        resetInputWebSocket()

        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(["cmd": "selectPC", "id": profile.id], replyHandler: { [weak self] reply in
                Task { @MainActor in self?.applyPhonePayload(reply) }
            }, errorHandler: nil)
        }
        Task { await refreshTelemetry() }
    }

    // MARK: - Wrist Motion Air Mouse (Gyro & Laser Pointer)

    func toggleMotionCursor() {
        if isMotionCursorActive {
            stopMotionCursor()
        } else {
            startMotionCursor()
        }
    }

    func startMotionCursor() {
        guard motionMode != .touchPad else {
            isMotionCursorActive = false
            return
        }
        guard motionManager.isDeviceMotionAvailable else {
            statusMessage = "Wrist sensors unavailable in Simulator; use Touchpad"
            isMotionCursorActive = true
            return
        }
        WKInterfaceDevice.current().play(.start)
        isMotionCursorActive = true
        neutralPitch = nil
        neutralRoll = nil
        neutralYaw = nil
        smoothedDX = 0
        smoothedDY = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 28.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.processDeviceMotion(motion)
        }
        statusMessage = "Wrist Cursor Active"
    }

    func stopMotionCursor() {
        guard isMotionCursorActive else { return }
        motionManager.stopDeviceMotionUpdates()
        isMotionCursorActive = false
        cursorIndicatorOffset = .zero
        if isDragLocked {
            isDragLocked = false
            sendCursorPacket(drag: "up")
        }
        WKInterfaceDevice.current().play(.stop)
        statusMessage = "Wrist Cursor Paused"
    }

    func calibrateWristCenter() {
        neutralPitch = nil
        neutralRoll = nil
        neutralYaw = nil
        smoothedDX = 0
        smoothedDY = 0
        cursorIndicatorOffset = .zero
        WKInterfaceDevice.current().play(.click)
        statusMessage = "Wrist Centered"
        if motionMode == .laserPointer {
            sendCursorPacket(normX: 0.5, normY: 0.5)
        }
    }

    func toggleDragLock() {
        isDragLocked.toggle()
        WKInterfaceDevice.current().play(.directionUp)
        sendCursorPacket(drag: isDragLocked ? "down" : "up")
        statusMessage = isDragLocked ? "Drag Lock ON" : "Drag Released"
    }

    func handleCrownScrollChange(_ newValue: Double) {
        let delta = newValue - lastCrownScrollValue
        guard abs(delta) >= 0.35 else { return }
        lastCrownScrollValue = newValue
        let steps = max(-5, min(5, Int((delta * 2.2).rounded())))
        if steps != 0 {
            sendCursorPacket(scroll: steps)
        }
    }

    private func processDeviceMotion(_ motion: CMDeviceMotion) {
        guard isMotionCursorActive else { return }
        let pitch = motion.attitude.pitch
        let roll = motion.attitude.roll
        let yaw = motion.attitude.yaw

        if neutralPitch == nil {
            neutralPitch = pitch
            neutralRoll = roll
            neutralYaw = yaw
        }

        let dPitch = pitch - (neutralPitch ?? pitch)
        let dRoll = roll - (neutralRoll ?? roll)
        let dYaw = shortestAngleDelta(from: neutralYaw ?? yaw, to: yaw)

        let now = Date()
        guard now.timeIntervalSince(lastMotionSentAt) >= 0.036 else { return }

        switch motionMode {
        case .gyroGlide:
            // Combine wrist angular velocity (rotationRate) with tilt angle for natural Air Mouse feel
            let rateX = -motion.rotationRate.z + (dRoll * 1.45) - (dYaw * 1.15)
            let rateY = -motion.rotationRate.x + (dPitch * 1.55)

            let deadzone = 0.048
            let filteredX = abs(rateX) < deadzone ? 0 : (rateX - (rateX > 0 ? deadzone : -deadzone))
            let filteredY = abs(rateY) < deadzone ? 0 : (rateY - (rateY > 0 ? deadzone : -deadzone))

            let scale = 19.0 * sensitivity
            smoothedDX = smoothedDX * 0.35 + (filteredX * scale) * 0.65
            smoothedDY = smoothedDY * 0.35 + (filteredY * scale) * 0.65

            let dx = Int(smoothedDX.rounded())
            let dy = Int(smoothedDY.rounded())

            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8)) {
                cursorIndicatorOffset = CGSize(
                    width: max(-36, min(36, CGFloat(smoothedDX * 1.6))),
                    height: max(-26, min(26, CGFloat(smoothedDY * 1.6)))
                )
            }

            if dx != 0 || dy != 0 {
                lastMotionSentAt = now
                sendCursorPacket(dx: dx, dy: dy)
            }

        case .laserPointer:
            // Direct absolute mapping of wrist yaw & pitch to normalized PC screen [0..1]
            let spanYaw = 0.42 / max(0.5, sensitivity * 0.85)
            let spanPitch = 0.34 / max(0.5, sensitivity * 0.85)
            let normX = max(0.0, min(1.0, 0.5 - (dYaw / (spanYaw * 2.0)) + (dRoll / (spanYaw * 2.4))))
            let normY = max(0.0, min(1.0, 0.5 + (dPitch / (spanPitch * 2.0))))

            withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.82)) {
                cursorIndicatorOffset = CGSize(
                    width: CGFloat((normX - 0.5) * 72),
                    height: CGFloat((normY - 0.5) * 52)
                )
            }

            lastMotionSentAt = now
            sendCursorPacket(normX: normX, normY: normY)

        case .touchPad:
            break
        }
    }

    private func shortestAngleDelta(from a: Double, to b: Double) -> Double {
        var diff = b - a
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        return diff
    }

    func sendCursorPacket(
        dx: Int = 0,
        dy: Int = 0,
        click: String = "",
        scroll: Int = 0,
        hscroll: Int = 0,
        normX: Double? = nil,
        normY: Double? = nil,
        drag: String = ""
    ) {
        if !click.isEmpty {
            WKInterfaceDevice.current().play(.click)
        }

        var message: [String: Any] = [
            "cmd": "cursor",
            "dx": dx,
            "dy": dy,
            "click": click,
            "scroll": scroll,
            "hscroll": hscroll,
            "drag": drag
        ]
        if let normX, let normY {
            message["normX"] = normX
            message["normY"] = normY
        }

        // 1. Try direct low-latency WebSocket / HTTP to PC if credentials exist
        if hasDirectCredentials {
            Task {
                if await sendDirectWebSocketCursor(message) { return }
                var query = [
                    URLQueryItem(name: "dx", value: "\(dx)"),
                    URLQueryItem(name: "dy", value: "\(dy)"),
                    URLQueryItem(name: "click", value: click),
                    URLQueryItem(name: "scroll", value: "\(scroll)"),
                    URLQueryItem(name: "hscroll", value: "\(hscroll)"),
                    URLQueryItem(name: "drag", value: drag)
                ]
                if let normX, let normY {
                    query.append(URLQueryItem(name: "normX", value: String(format: "%.4f", normX)))
                    query.append(URLQueryItem(name: "normY", value: String(format: "%.4f", normY)))
                }
                if (try? await performPCRequest(path: "/api/input/cursor", method: "POST", query: query)) != nil {
                    return
                }
                if normX == nil && drag.isEmpty {
                    _ = try? await performPCRequest(path: "/api/input/mouse", method: "POST", query: [
                        URLQueryItem(name: "dx", value: "\(dx)"),
                        URLQueryItem(name: "dy", value: "\(dy)"),
                        URLQueryItem(name: "click", value: click),
                        URLQueryItem(name: "scroll", value: "\(scroll)")
                    ])
                }
            }
            return
        }

        // 2. Relay via iPhone WatchConnectivity
        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - Networking & Pinned TLS

    private func resetInputWebSocket() {
        inputWebSocket?.cancel(with: .goingAway, reason: nil)
        inputWebSocket = nil
        inputSession?.invalidateAndCancel()
        inputSession = nil
    }

    private func sendDirectWebSocketCursor(_ payload: [String: Any]) async -> Bool {
        guard hasDirectCredentials else { return false }
        if inputWebSocket == nil {
            var comps = URLComponents()
            comps.scheme = hasSecureTLS ? "wss" : "ws"
            comps.host = host
            comps.port = hasSecureTLS ? securePort : agentPort
            comps.path = "/ws/input"
            guard let url = comps.url else { return false }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            let delegate = hasSecureTLS ? WatchPinnedTLSDelegate(fingerprint: certificateFingerprint) : nil
            inputDelegate = delegate
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            inputSession = session
            let ws = session.webSocketTask(with: req)
            inputWebSocket = ws
            ws.resume()
        }
        guard let ws = inputWebSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try await ws.send(.string(text))
            return true
        } catch {
            resetInputWebSocket()
            return false
        }
    }

    private func performPCRequest(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = hasSecureTLS ? "https" : "http"
        comps.host = host
        comps.port = hasSecureTLS ? securePort : agentPort
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 3.0
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 4.0
        let delegate = hasSecureTLS ? WatchPinnedTLSDelegate(fingerprint: certificateFingerprint) : nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func sendDirectMagicPacket() -> Bool {
        let cleaned = macAddress.filter { !":-. ".contains($0) }
        guard cleaned.count == 12 else { return false }
        let chars = Array(cleaned)
        var mac: [UInt8] = []
        for i in stride(from: 0, to: 12, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return false }
            mac.append(b)
        }
        let packet = Array(repeating: UInt8(255), count: 6) + Array(repeating: mac, count: 16).flatMap { $0 }
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var enabled: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let targets = Set([broadcastAddress, lastKnownIPv4, host, "255.255.255.255"]).filter { !$0.isEmpty }
        var sent = false
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(max(1, min(65535, wolPort))).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            let count = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(sock, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            sent = sent || (count == packet.count)
        }
        return sent
    }

    // MARK: - Persistence & Complications Snapshot

    private func applyPhonePayload(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        if let id = payload["selectedPCID"] as? String { selectedPCID = id }
        if let name = payload["pcName"] as? String, !name.isEmpty { pcName = name }
        if let h = payload["host"] as? String, !h.isEmpty { host = h }
        if let ap = payload["agentPort"] as? Int { agentPort = ap }
        if let sp = payload["securePort"] as? Int { securePort = sp }
        if let fp = payload["certificateFingerprint"] as? String { certificateFingerprint = fp }
        if let tok = payload["apiToken"] as? String, !tok.isEmpty { apiToken = tok }
        if let mac = payload["macAddress"] as? String { macAddress = mac }
        if let bc = payload["broadcastAddress"] as? String { broadcastAddress = bc }
        if let sm = payload["subnetMask"] as? String { subnetMask = sm }
        if let wp = payload["wolPort"] as? Int { wolPort = wp }
        if let ip = payload["lastKnownIPv4"] as? String { lastKnownIPv4 = ip }
        if let online = payload["isOnline"] as? Bool { isOnline = online }
        if let avail = payload["telemetryAvailable"] as? Bool { telemetryAvailable = avail }
        if let cpu = payload["cpuUsage"] as? Double { cpuUsage = cpu }
        cpuTemp = payload["cpuTemp"] as? Double
        gpuUsage = payload["gpuUsage"] as? Double
        gpuTemp = payload["gpuTemp"] as? Double
        if let ramPct = payload["ramUsagePercent"] as? Double { ramUsagePercent = ramPct }
        if let ru = payload["ramUsedGB"] as? Double { ramUsedGB = ru }
        if let rt = payload["ramTotalGB"] as? Double { ramTotalGB = rt }
        cpuPowerWatts = payload["cpuPowerWatts"] as? Double
        gpuPowerWatts = payload["gpuPowerWatts"] as? Double
        fps = payload["fps"] as? Double
        activeGame = payload["activeGame"] as? String
        if let vol = payload["volume"] as? Double, Date().timeIntervalSince(lastVolumeSentAt) > 2.0 {
            volume = vol
        }
        if let muted = payload["isMuted"] as? Bool { isMuted = muted }
        if let up = payload["uptimeSeconds"] as? Int { uptimeSeconds = up }
        if let ping = payload["pingMs"] as? Int { pingMs = ping }
        if let la = payload["isLiveActivityActive"] as? Bool { isLiveActivityActive = la }

        if let rawGames = payload["games"] as? [[String: String]] {
            games = rawGames.compactMap { dict in
                guard let id = dict["id"], let title = dict["title"] else { return nil }
                return WatchSunshineGame(id: id, title: title, genre: dict["genre"] ?? "Sunshine")
            }
        }
        if let rawPCs = payload["savedPCs"] as? [[String: Any]] {
            savedPCs = rawPCs.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String,
                      let address = dict["address"] as? String else { return nil }
                return WatchPCProfile(
                    id: id,
                    name: name,
                    address: address,
                    agentPort: dict["agentPort"] as? Int ?? 8765,
                    securePort: dict["securePort"] as? Int ?? 8766,
                    certificateFingerprint: dict["certificateFingerprint"] as? String ?? "",
                    macAddress: dict["macAddress"] as? String ?? "",
                    subnetMask: dict["subnetMask"] as? String ?? "255.255.255.0",
                    broadcastAddress: dict["broadcastAddress"] as? String ?? "",
                    wolPort: dict["wolPort"] as? Int ?? 9,
                    lastKnownIPv4: dict["lastKnownIPv4"] as? String ?? "",
                    apiToken: dict["apiToken"] as? String ?? ""
                )
            }
        }

        // Sync credentials to shared OrbitWidgetConnectionStore on watchOS so Watch Complications can wake/control PC too
        if !selectedPCID.isEmpty && !host.isEmpty {
            OrbitWidgetConnectionStore.syncPowerProfile(
                id: selectedPCID,
                name: pcName,
                host: host,
                port: securePort,
                certificateSHA256: certificateFingerprint,
                controlToken: apiToken,
                macAddress: macAddress,
                broadcastAddress: broadcastAddress,
                subnetMask: subnetMask,
                wolPort: wolPort,
                lastKnownIPv4: lastKnownIPv4
            )
            try? OrbitWidgetConnectionStore.setDefault(id: selectedPCID)
        }

        statusMessage = isOnline ? "Synced · \(pcName)" : "Offline · \(pcName)"
        saveSnapshotForComplications()
    }

    private func saveSnapshotForComplications() {
        let store = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let snapshot: [String: Any] = [
            "pcName": pcName,
            "isOnline": isOnline,
            "cpuUsage": cpuUsage,
            "cpuTemp": cpuTemp ?? -1,
            "gpuUsage": gpuUsage ?? -1,
            "gpuTemp": gpuTemp ?? -1,
            "ramUsagePercent": ramUsagePercent,
            "fps": fps ?? -1,
            "activeGame": activeGame ?? "",
            "timestamp": Date().timeIntervalSince1970,
            "host": host,
            "agentPort": agentPort,
            "securePort": securePort,
            "certificateFingerprint": certificateFingerprint,
            "macAddress": macAddress,
            "broadcastAddress": broadcastAddress,
            "subnetMask": subnetMask,
            "wolPort": wolPort,
            "lastKnownIPv4": lastKnownIPv4
        ]
        store.set(snapshot, forKey: Self.snapshotKey)
        UserDefaults.standard.set(snapshot, forKey: Self.snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func loadCachedState() {
        let store = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        guard let snapshot = store.dictionary(forKey: Self.snapshotKey) ?? UserDefaults.standard.dictionary(forKey: Self.snapshotKey) else {
            return
        }
        pcName = snapshot["pcName"] as? String ?? "Your PC"
        isOnline = snapshot["isOnline"] as? Bool ?? false
        cpuUsage = snapshot["cpuUsage"] as? Double ?? 0
        let ct = snapshot["cpuTemp"] as? Double ?? -1
        cpuTemp = ct >= 0 ? ct : nil
        let gu = snapshot["gpuUsage"] as? Double ?? -1
        gpuUsage = gu >= 0 ? gu : nil
        let gt = snapshot["gpuTemp"] as? Double ?? -1
        gpuTemp = gt >= 0 ? gt : nil
        ramUsagePercent = snapshot["ramUsagePercent"] as? Double ?? 0
        let f = snapshot["fps"] as? Double ?? -1
        fps = f >= 0 ? f : nil
        let game = snapshot["activeGame"] as? String ?? ""
        activeGame = game.isEmpty ? nil : game
        host = snapshot["host"] as? String ?? ""
        agentPort = snapshot["agentPort"] as? Int ?? 8765
        securePort = snapshot["securePort"] as? Int ?? 8766
        certificateFingerprint = snapshot["certificateFingerprint"] as? String ?? ""
        macAddress = snapshot["macAddress"] as? String ?? ""
        broadcastAddress = snapshot["broadcastAddress"] as? String ?? ""
        subnetMask = snapshot["subnetMask"] as? String ?? "255.255.255.0"
        wolPort = snapshot["wolPort"] as? Int ?? 9
        lastKnownIPv4 = snapshot["lastKnownIPv4"] as? String ?? ""
    }
}

extension OrbitWatchViewModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if !context.isEmpty {
                self.applyPhonePayload(context)
            }
            self.requestSyncFromPhone()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if reachable {
                self.requestSyncFromPhone()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyPhonePayload(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.applyPhonePayload(message)
        }
    }
}

private final class WatchPinnedTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(certificate) as Data
        let received = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard received == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
