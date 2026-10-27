import CoreMotion
import Foundation
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
    /// Agent 4.3+: true while Windows shows the sign-in or lock screen.
    var sessionLocked: Bool?
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
    /// The selected PC's secondary address from the iPhone (for example its Tailscale address).
    @Published var secondaryHost: String = ""
    /// The Watch's own requests go to `secondaryHost` because the PC's LAN address (`host`) did not answer.
    @Published private(set) var directUsesSecondary = false

    @Published private(set) var lastTelemetryAt: Date?
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
    /// True while the PC shows its sign-in or lock screen (agent 4.3+).
    @Published var sessionLocked: Bool = false
    @Published var isUnlocking: Bool = false
    @Published var savedPCs: [WatchPCProfile] = []
    @Published var games: [WatchSunshineGame] = []
    /// The PC's custom buttons for the Buttons page (OrbitWatchDeck.swift).
    let deck = WatchDeckStore()

    // Wrist Motion Air Mouse state
    @Published var isMotionCursorActive: Bool = false
    @Published var motionMode: WatchCursorMode = .gyroGlide
    @Published var sensitivity: Double = 1.2 {
        didSet {
            let safe = sensitivity.isFinite ? min(3, max(0.4, sensitivity)) : 1.2
            if sensitivity != safe { sensitivity = safe }
            UserDefaults.standard.set(safe, forKey: "Orbit.WatchSensitivity")
        }
    }
    @Published private(set) var cursorStatusMessage = "Choose a mode to control your PC"
    @Published private(set) var cursorRouteLabel = "Not connected"
    @Published private(set) var lastCursorDeliveryAt: Date?
    @Published private(set) var isCursorSending = false
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
    private var httpClient: OrbitWatchHTTPClient?
    private var httpTarget: OrbitWatchControlTarget?
    private var cursorQueue: OrbitCursorCommandQueue?
    private var cursorTarget: OrbitWatchControlTarget?
    // Retain this until retirement: a queued release can be cancelled while a
    // previously dispatched press is still completing. UI drag state alone is insufficient.
    private var cursorMayNeedRelease = false
    private var cursorFailureHandled = false
    private var volumeQueue: VolumeCommandQueue?
    private var volumeTarget: OrbitWatchControlTarget?
    private var avoidPhoneUntil: Date = .distantPast
    private var lastPhoneContextAt: Double = 0
    private var pendingSelection: (id: String, until: Date)?

    var target: OrbitWatchControlTarget {
        OrbitWatchControlTarget(id: selectedPCID, host: host, agentPort: agentPort,
                                securePort: securePort, fingerprint: certificateFingerprint, token: apiToken)
    }
    var isMotionAvailable: Bool { motionManager.isDeviceMotionAvailable }
    var isTelemetryFresh: Bool {
        isOnline && lastTelemetryAt.map { (0...12).contains(Date().timeIntervalSince($0)) } == true
    }
    var canControlPC: Bool { hasDirectCredentials || (phoneCanRelay && !selectedPCID.isEmpty) }
    var phoneCanRelay: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    private static let appGroupID = "group.com.dimitrie.orbit"
    private static let snapshotKey = "Orbit.WatchSnapshot.v1"

    override init() {
        super.init()
        loadCachedState()
        if let mode = WatchCursorMode(rawValue: UserDefaults.standard.string(forKey: "Orbit.WatchCursorMode") ?? "") { motionMode = mode }
        if let value = UserDefaults.standard.object(forKey: "Orbit.WatchSensitivity") as? Double { sensitivity = value }
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
            volumeQueue?.cancel()
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
        } else if hostOrPath.contains("button") || hostOrPath.contains("deck") {
            selectedTab = WatchDeckStore.tab
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
        isPhoneReachable = phoneCanRelay
        if phoneCanRelay {
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
            selectedPCID = widgetConn.id
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
            let requestedTarget = target
            let start = Date()
            do {
                let data = try await performPCRequest(path: "/api/watch/summary", method: "GET")
                let summary = try JSONDecoder().decode(WatchSummaryResponse.self, from: data)
                guard requestedTarget == target else { return }
                lastTelemetryAt = Date()
                isOnline = summary.isOnline ?? true
                sessionLocked = summary.sessionLocked ?? false
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
                statusMessage = directUsesSecondary ? "Live · Remote · \(pingMs) ms" : "Live · \(pingMs) ms"
                checkThermalHapticAlert()
                saveSnapshotForComplications()
                return
            } catch {
                // Fallback to /api/status for 4.1.0 PC Companion agents
                if let data = try? await performPCRequest(path: "/api/status", method: "GET"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    guard requestedTarget == target else { return }
                    lastTelemetryAt = Date()
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
                    statusMessage = directUsesSecondary ? "Live · Remote · \(pingMs) ms" : "Live · \(pingMs) ms"
                    checkThermalHapticAlert()
                    saveSnapshotForComplications()
                    return
                }
                // Nothing answered on this address: the next poll tries the PC's other one (LAN ↔ secondary).
                if requestedTarget == target, canUseSecondaryAddress, (error as? URLError).map({ $0.code != .cancelled }) == true {
                    directUsesSecondary.toggle()
                }
            }
        }

        if !isTelemetryFresh { isOnline = false }
        // A relay can still work when the last telemetry sample is stale.
        if phoneCanRelay {
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
        // watchOS does not permit BSD UDP sockets. The paired iPhone sends WoL.
        guard phoneCanRelay else {
            statusMessage = "Open Orbit on your nearby iPhone to wake this PC"
            WKInterfaceDevice.current().play(.failure)
            return
        }
        statusMessage = "Sending Wake-on-LAN via iPhone…"
        do {
            let destination = target
            let reply = try await sendPCMessage(["cmd": "wake"], to: destination)
            guard target == destination else { return }
            applyPhonePayload(reply)
            statusMessage = "Wake packet sent via iPhone · waiting for PC"
            WKInterfaceDevice.current().play(.success)
        } catch {
            statusMessage = "Wake failed: \(error.localizedDescription)"
            WKInterfaceDevice.current().play(.failure)
        }
    }

    /// Signs in to the locked PC: the password goes to the iPhone over the encrypted Watch link,
    /// which types it through a short Sunshine stream (the only channel that reaches the Windows
    /// sign-in screen). Nothing is stored on either device.
    func unlockPC(password: String) async {
        guard !isUnlocking, !password.isEmpty else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        guard phoneCanRelay else {
            statusMessage = "Open Orbit on your nearby iPhone to unlock this PC"
            WKInterfaceDevice.current().play(.failure)
            return
        }
        statusMessage = "Signing in through iPhone…"
        do {
            let destination = target
            var message: [String: Any] = ["cmd": "unlockPC", "password": password]
            message["pcID"] = destination.id
            message["host"] = destination.host
            let reply = try await sendPhoneMessage(message, timeout: 40)
            guard reply["status"] as? String == "sent" else {
                throw WatchControlError(reply["message"] as? String ?? "iPhone could not sign in to the PC.")
            }
            statusMessage = "Sign-in sent · the PC should unlock"
            WKInterfaceDevice.current().play(.success)
        } catch {
            statusMessage = "Unlock failed: \(error.localizedDescription)"
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func sendPowerAction(_ action: String) async {
        WKInterfaceDevice.current().play(.click)
        let label = action.replacingOccurrences(of: "_", with: " ").capitalized
        let destination = target
        statusMessage = "Sending \(label)…"
        do {
            // The paired phone also works when the Watch only has Bluetooth.
            // Choose one route; an unconfirmed media toggle must not be replayed.
            if phoneCanRelay {
                _ = try await sendPCMessage(["cmd": "powerAction", "action": action], to: destination)
            } else {
                _ = try await client(for: destination).data(path: "/api/action/\(action)", method: "POST")
            }
            guard target == destination else { return }
            statusMessage = "\(label) sent"
            if ["shutdown", "sleep", "restart"].contains(action) { isOnline = false; stopMotionCursor() }
            if action == "mute" { isMuted.toggle() }
            WKInterfaceDevice.current().play(.success)
            saveSnapshotForComplications()
        } catch {
            guard target == destination else { return }
            statusMessage = "\(label) failed: \(error.localizedDescription)"
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func setPCVolume(_ newVolume: Double) {
        guard newVolume.isFinite, canControlPC else { return }
        let clamped = min(100, max(0, newVolume.rounded()))
        guard abs(clamped - volume) >= 1 else { return }
        volume = clamped
        lastVolumeSentAt = Date()
        let destination = target
        if volumeTarget != destination {
            volumeQueue?.cancel()
            volumeTarget = destination
            volumeQueue = VolumeCommandQueue { [weak self] level in
                guard let self, self.target == destination else { return }
                do {
                    _ = try await self.client(for: destination).data(path: "/api/volume", method: "POST",
                        query: [URLQueryItem(name: "level", value: "\(Int(level))")])
                } catch {
                    guard self.target == destination else { return }
                    do {
                        _ = try await self.sendPCMessage(["cmd": "volume", "level": level], to: destination)
                    } catch { self.statusMessage = "Volume: \(error.localizedDescription)" }
                }
            }
        }
        volumeQueue?.enqueue(clamped)
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
        let destination = target
        statusMessage = "Launching \(game.title)…"
        Task {
            do {
                if phoneCanRelay {
                    _ = try await sendPCMessage(["cmd": "launchGame", "title": game.title], to: destination)
                } else {
                    _ = try await client(for: destination).data(path: "/api/sunshine/launch", method: "POST",
                        query: [URLQueryItem(name: "app", value: game.title)])
                }
                guard target == destination else { return }
                statusMessage = "Launched \(game.title)"
                WKInterfaceDevice.current().play(.success)
            } catch {
                guard target == destination else { return }
                statusMessage = "Launch failed: \(error.localizedDescription)"
            }
        }
    }

    func selectPC(_ profile: WatchPCProfile) {
        WKInterfaceDevice.current().play(.click)
        retireCursorPipeline()
        volumeQueue?.cancel()
        lastTelemetryAt = nil
        isOnline = false
        pendingSelection = (profile.id, Date().addingTimeInterval(10))
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
        guard !isMotionCursorActive, canControlPC else {
            if !canControlPC { cursorStatusMessage = "Pair your PC in Orbit on iPhone first" }
            return
        }
        guard motionMode != .touchPad else {
            isMotionCursorActive = false
            return
        }
        guard motionManager.isDeviceMotionAvailable else {
            cursorStatusMessage = "Wrist sensors unavailable · use Touchpad"
            isMotionCursorActive = false
            return
        }
        WKInterfaceDevice.current().play(.start)
        isMotionCursorActive = true
        neutralPitch = nil
        neutralRoll = nil
        neutralYaw = nil
        smoothedDX = 0
        smoothedDY = 0
        lastMotionSentAt = .distantPast
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.stopMotionCursor()
                self.cursorStatusMessage = "Motion: \(error.localizedDescription)"
                return
            }
            guard let motion else { return }
            self.processDeviceMotion(motion)
        }
        cursorStatusMessage = "Move your wrist · waiting for PC confirmation"
    }

    func stopMotionCursor() {
        let wasActive = isMotionCursorActive
        motionManager.stopDeviceMotionUpdates()
        isMotionCursorActive = false
        // Pause also cancels queued clicks/presses. Only a release may follow an
        // in-flight request, so old input never catches up after leaving this page.
        cursorQueue?.cancel()
        cursorIndicatorOffset = .zero
        resetCrownScroll()
        isDragLocked = false
        if cursorMayNeedRelease {
            cursorQueue?.enqueue(OrbitCursorPacket(drag: "up"))
        }
        if wasActive {
            WKInterfaceDevice.current().play(.stop)
            cursorStatusMessage = "Cursor paused"
        }
    }

    func setCursorMode(_ mode: WatchCursorMode) {
        stopMotionCursor()
        motionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "Orbit.WatchCursorMode")
        cursorStatusMessage = mode == .touchPad ? "Swipe the pad to move your PC cursor" : "Tap Start, then move your wrist"
    }

    func resetCrownScroll() {
        lastCrownScrollValue = 0
        crownScrollAccumulator = 0
    }

    func calibrateWristCenter() {
        neutralPitch = nil
        neutralRoll = nil
        neutralYaw = nil
        smoothedDX = 0
        smoothedDY = 0
        cursorIndicatorOffset = .zero
        WKInterfaceDevice.current().play(.click)
        cursorStatusMessage = "Hold this position · wrist center reset"
        if motionMode == .laserPointer {
            sendCursorPacket(normX: 0.5, normY: 0.5)
        }
    }

    func toggleDragLock() {
        guard canControlPC else { cursorStatusMessage = "Connect your PC first"; return }
        isDragLocked.toggle()
        WKInterfaceDevice.current().play(.directionUp)
        sendCursorPacket(drag: isDragLocked ? "down" : "up")
        cursorStatusMessage = isDragLocked ? "Holding left button · tap Release when done" : "Drag released"
    }

    func handleCrownScrollChange(_ newValue: Double) {
        guard newValue.isFinite else { return }
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
        guard now.timeIntervalSince(lastMotionSentAt) >= 0.030 else { return }

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
        dx: Int = 0, dy: Int = 0, click: String = "", scroll: Int = 0, hscroll: Int = 0,
        normX: Double? = nil, normY: Double? = nil, drag: String = ""
    ) {
        guard canControlPC else {
            cursorStatusMessage = "Connect your PC or open Orbit on your nearby iPhone"
            return
        }
        if !click.isEmpty { WKInterfaceDevice.current().play(.click) }
        let destination = target
        if cursorTarget != destination {
            // Initializing the first queue must not stop the gyro that just started
            // or clear a first drag press. Retire only an existing PC pipeline.
            if cursorTarget != nil { retireCursorPipeline() }
            cursorTarget = destination
            // The destination is captured, so queued input can never move a newly selected PC.
            cursorQueue = OrbitCursorCommandQueue(minimumInterval: .milliseconds(12), send: { [weak self] packet in
                guard let self else { throw CancellationError() }
                try await self.deliverCursor(packet, to: destination)
            }, onFailure: { [weak self] error in
                guard let self, self.target == destination else { return }
                // A failed button-up must not recursively queue another button-up
                // forever when both routes are offline. One recovery release is
                // attempted after the original failure, then user input is required.
                if self.cursorFailureHandled { self.cursorMayNeedRelease = false }
                self.cursorFailureHandled = true
                self.stopMotionCursor()
                self.cursorStatusMessage = "Cursor paused: \(error.localizedDescription)"
                self.cursorRouteLabel = "Connection needs attention"
                WKInterfaceDevice.current().play(.failure)
            })
        }
        if drag != "up" { cursorFailureHandled = false }
        if drag == "down" { cursorMayNeedRelease = true }
        cursorQueue?.enqueue(OrbitCursorPacket(dx: dx, dy: dy, click: click, scroll: scroll,
            hscroll: hscroll, normX: normX, normY: normY, drag: drag))
    }

    private func retireCursorPipeline() {
        motionManager.stopDeviceMotionUpdates()
        isMotionCursorActive = false
        cursorIndicatorOffset = .zero
        if let queue = cursorQueue {
            queue.cancel()
            // Release on the old destination after any in-flight press completes.
            if cursorMayNeedRelease { queue.enqueue(OrbitCursorPacket(drag: "up")) }
            Task { await queue.flush() }
        }
        isDragLocked = false
        cursorMayNeedRelease = false
        cursorQueue = nil
        cursorTarget = nil
        isCursorSending = false
        lastCursorDeliveryAt = nil
        cursorRouteLabel = "Not connected"
        resetCrownScroll()
    }

    private func deliverCursor(_ packet: OrbitCursorPacket, to destination: OrbitWatchControlTarget) async throws {
        if target == destination { isCursorSending = true }
        defer { if target == destination { isCursorSending = false } }
        // A reachable paired iPhone can relay over Bluetooth even when the Watch
        // has no direct Wi-Fi route to the PC. Prefer that supported route first.
        let usePhone = phoneCanRelay && Date() >= avoidPhoneUntil
        do {
            let route: String
            if usePhone {
                route = "Via iPhone · confirmed"
                try await relayCursor(packet, to: destination)
            } else {
                route = "Direct HTTP\(destination.hasSecureTLS ? "S" : "") · confirmed"
                if !destination.hasCredentials, phoneCanRelay {
                    try await relayCursor(packet, to: destination)
                } else {
                    try await client(for: destination).sendCursor(packet)
                }
            }
            guard target == destination, !Task.isCancelled else { return }
            if packet.isReleaseOnly { cursorMayNeedRelease = false }
            lastCursorDeliveryAt = Date()
            cursorRouteLabel = route
            cursorStatusMessage = isMotionCursorActive ? "Controlling your PC · tap Pause to stop" : "PC confirmed your input"
        } catch {
            // Do not replay an unacknowledged click: it might already have executed.
            // Switch route for the next fresh command instead.
            if usePhone { avoidPhoneUntil = Date().addingTimeInterval(10) }
            else { avoidPhoneUntil = .distantPast }
            // Button-up is idempotent and safe to deliver by the other route.
            if packet.isReleaseOnly {
                if usePhone {
                    try await client(for: destination).sendCursor(packet)
                    if target == destination { cursorMayNeedRelease = false }
                    return
                }
                if phoneCanRelay {
                    try await relayCursor(packet, to: destination)
                    if target == destination { cursorMayNeedRelease = false }
                    return
                }
            }
            throw error
        }
    }

    private func relayCursor(_ packet: OrbitCursorPacket, to destination: OrbitWatchControlTarget) async throws {
        guard phoneCanRelay else { throw WatchControlError("Open Orbit on your nearby iPhone") }
        var message = try JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any] ?? [:]
        message["cmd"] = "cursor"
        message["pcID"] = destination.id
        message["host"] = destination.host
        message["expiresAt"] = Date().addingTimeInterval(5).timeIntervalSince1970
        let reply = try await sendPhoneMessage(message)
        guard reply["status"] as? String == "sent" else {
            throw WatchControlError(reply["message"] as? String ?? "Update Orbit on iPhone, then reconnect your PC")
        }
    }

    // MARK: - Supported watchOS HTTP networking

    func client(for destination: OrbitWatchControlTarget) throws -> OrbitWatchHTTPClient {
        let routed = routedTarget(destination)
        if httpTarget != routed || httpClient == nil {
            httpClient = try OrbitWatchHTTPClient(target: routed)
            httpTarget = routed
        }
        return httpClient!
    }

    /// Only with certificate pinning: the token never crosses another network in clear.
    private var canUseSecondaryAddress: Bool { hasSecureTLS && !secondaryHost.isEmpty && secondaryHost.caseInsensitiveCompare(host) != .orderedSame }

    /// `destination` on the address the Watch's own requests use now: the PC's secondary address while its LAN
    /// address does not answer. Relays through the iPhone keep naming the PC by its LAN address.
    private func routedTarget(_ destination: OrbitWatchControlTarget) -> OrbitWatchControlTarget {
        guard directUsesSecondary, canUseSecondaryAddress, destination == target else { return destination }
        return OrbitWatchControlTarget(id: destination.id, host: secondaryHost, agentPort: destination.agentPort,
                                       securePort: destination.securePort, fingerprint: destination.fingerprint, token: destination.token)
    }

    private func performPCRequest(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        try await client(for: target).data(path: path, method: method, query: query)
    }

    private func sendPCMessage(_ fields: [String: Any], to destination: OrbitWatchControlTarget) async throws -> [String: Any] {
        var message = fields
        message["pcID"] = destination.id
        message["host"] = destination.host
        message["expiresAt"] = Date().addingTimeInterval(5).timeIntervalSince1970
        let reply = try await sendPhoneMessage(message)
        guard reply["status"] as? String == "sent", reply["pcID"] as? String == destination.id else {
            throw WatchControlError(reply["message"] as? String ?? "iPhone did not confirm the PC command. Update Orbit on both devices.")
        }
        return reply
    }

    func sendPhoneMessage(_ message: [String: Any], timeout: TimeInterval = 6) async throws -> [String: Any] {
        guard phoneCanRelay else { throw WatchControlError("Open Orbit on your nearby iPhone") }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = WatchReplyWaiter(continuation)
            WCSession.default.sendMessage(message, replyHandler: { payload in
                Task { @MainActor in reply.finish(.success(payload)) }
            }, errorHandler: { error in
                Task { @MainActor in reply.finish(.failure(error)) }
            })
            reply.timeout = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                reply.finish(.failure(WatchControlError("iPhone did not confirm the command. Check its connection.")))
            }
        }
    }

    // MARK: - Persistence & Complications Snapshot

    private func applyPhonePayload(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        let contextTime = payload["timestamp"] as? Double ?? 0
        guard contextTime >= lastPhoneContextAt else { return }
        let incomingID = payload["selectedPCID"] as? String ?? selectedPCID
        if let pendingSelection, Date() < pendingSelection.until, incomingID != pendingSelection.id { return }
        if incomingID == pendingSelection?.id { pendingSelection = nil }
        lastPhoneContextAt = contextTime
        let incomingTarget = OrbitWatchControlTarget(
            id: incomingID, host: payload["host"] as? String ?? host,
            agentPort: payload["agentPort"] as? Int ?? agentPort,
            securePort: payload["securePort"] as? Int ?? securePort,
            fingerprint: payload["certificateFingerprint"] as? String ?? certificateFingerprint,
            token: payload["apiToken"] as? String ?? apiToken)
        if incomingTarget != target {
            retireCursorPipeline()
            volumeQueue?.cancel()
            lastTelemetryAt = nil
            isOnline = false
        }
        selectedPCID = incomingID
        if let name = payload["pcName"] as? String, !name.isEmpty { pcName = name }
        host = incomingTarget.host
        agentPort = incomingTarget.agentPort
        securePort = incomingTarget.securePort
        certificateFingerprint = incomingTarget.fingerprint
        apiToken = incomingTarget.token
        if let mac = payload["macAddress"] as? String { macAddress = mac }
        if let bc = payload["broadcastAddress"] as? String { broadcastAddress = bc }
        if let sm = payload["subnetMask"] as? String { subnetMask = sm }
        if let wp = payload["wolPort"] as? Int { wolPort = wp }
        if let ip = payload["lastKnownIPv4"] as? String { lastKnownIPv4 = ip }
        if let secondary = payload["secondaryHost"] as? String {
            secondaryHost = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
            // The iPhone keeps checking the LAN address; follow the path it found.
            directUsesSecondary = (payload["usingSecondary"] as? Bool ?? false) && canUseSecondaryAddress
        }
        if let la = payload["isLiveActivityActive"] as? Bool { isLiveActivityActive = la }

        // Context delivery time does not make a cached PC sample fresh. Older phone
        // samples must not overwrite a newer direct HTTPS response from the Watch.
        let sampleTime = payload["telemetryTimestamp"] as? Double ?? 0
        let sampleDate = Date(timeIntervalSince1970: sampleTime)
        if payload["isDemoMode"] as? Bool != true,
           sampleTime > 0, sampleDate <= Date().addingTimeInterval(3),
           sampleDate >= (lastTelemetryAt ?? .distantPast) {
            lastTelemetryAt = sampleDate
            isOnline = (payload["isOnline"] as? Bool ?? false) && Date().timeIntervalSince(sampleDate) <= 12
            sessionLocked = payload["sessionLocked"] as? Bool ?? false
            telemetryAvailable = payload["telemetryAvailable"] as? Bool ?? false
            cpuUsage = payload["cpuUsage"] as? Double ?? 0
            cpuTemp = payload["cpuTemp"] as? Double
            gpuUsage = payload["gpuUsage"] as? Double
            gpuTemp = payload["gpuTemp"] as? Double
            ramUsagePercent = payload["ramUsagePercent"] as? Double ?? 0
            ramUsedGB = payload["ramUsedGB"] as? Double ?? 0
            ramTotalGB = payload["ramTotalGB"] as? Double ?? 0
            cpuPowerWatts = payload["cpuPowerWatts"] as? Double
            gpuPowerWatts = payload["gpuPowerWatts"] as? Double
            fps = payload["fps"] as? Double
            activeGame = payload["activeGame"] as? String
            if let vol = payload["volume"] as? Double, Date().timeIntervalSince(lastVolumeSentAt) > 2 {
                volume = min(100, max(0, vol))
            }
            isMuted = payload["isMuted"] as? Bool ?? isMuted
            uptimeSeconds = payload["uptimeSeconds"] as? Int ?? uptimeSeconds
            pingMs = payload["pingMs"] as? Int ?? 0
            checkThermalHapticAlert()
        }

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
                lastKnownIPv4: lastKnownIPv4,
                secondaryHost: canUseSecondaryAddress ? secondaryHost : ""
            )
            try? OrbitWidgetConnectionStore.setDefault(id: selectedPCID)
        }

        deck.applyPhonePayload(payload)
        statusMessage = isOnline ? "Synced · \(pcName)" : "Offline · \(pcName)"
        saveSnapshotForComplications()
    }

    private func saveSnapshotForComplications() {
        let store = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let snapshot: [String: Any] = [
            "pcName": pcName,
            "selectedPCID": selectedPCID,
            "isOnline": isTelemetryFresh,
            "cpuUsage": cpuUsage,
            "cpuTemp": cpuTemp ?? -1,
            "gpuUsage": gpuUsage ?? -1,
            "gpuTemp": gpuTemp ?? -1,
            "ramUsagePercent": ramUsagePercent,
            "fps": fps ?? -1,
            "activeGame": activeGame ?? "",
            "timestamp": lastTelemetryAt?.timeIntervalSince1970 ?? 0,
            "host": host,
            "agentPort": agentPort,
            "securePort": securePort,
            "certificateFingerprint": certificateFingerprint,
            "macAddress": macAddress,
            "broadcastAddress": broadcastAddress,
            "subnetMask": subnetMask,
            "wolPort": wolPort,
            "lastKnownIPv4": lastKnownIPv4,
            "secondaryHost": secondaryHost
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
        selectedPCID = snapshot["selectedPCID"] as? String ?? ""
        let sampleTime = snapshot["timestamp"] as? Double ?? 0
        lastTelemetryAt = sampleTime > 0 ? Date(timeIntervalSince1970: sampleTime) : nil
        isOnline = (snapshot["isOnline"] as? Bool ?? false) && lastTelemetryAt.map { (0...12).contains(Date().timeIntervalSince($0)) } == true
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
        secondaryHost = snapshot["secondaryHost"] as? String ?? ""
        if !selectedPCID.isEmpty { apiToken = (try? OrbitWidgetConnectionStore.controlToken(for: selectedPCID)) ?? "" }
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


private struct WatchControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private final class WatchReplyWaiter {
    private var continuation: CheckedContinuation<[String: Any], Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }
    func finish(_ result: Result<[String: Any], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}
