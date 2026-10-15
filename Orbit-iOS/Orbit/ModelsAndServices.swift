import Foundation
import Network
import SwiftUI
import Darwin
import Combine
import Security

// Missing sensors stay optional. An unavailable temperature is never estimated from load.
struct PCMetrics: Codable {
    var hostname: String = "Your PC"
    var cpuName: String = "Processor"
    var motherboard: String = "Unavailable"
    var coolerName: String = "Unavailable"
    var isOnline: Bool = false
    var cpuTemp: Double? = nil
    var cpuUsage: Double = 0
    var liquidTemp: Double? = nil
    var gpuName: String = "Graphics"
    var gpuTemp: Double? = nil
    var gpuUsage: Double? = nil
    var gpuPowerWatts: Double? = nil
    var vramUsedGB: Double? = nil
    var vramTotalGB: Double? = nil
    var ramUsedGB: Double = 0
    var ramTotalGB: Double = 0
    var ssdUsedTB: Double = 0
    var ssdTotalTB: Double = 0
    var uptimeSeconds: Int = 0
    var activeGame: String? = nil
    var volume: Double = 0
    var isMuted: Bool = false
    var hdrEnabled: Bool? = nil
    var fps: Double? = nil
    var fpsSource: String? = nil
    var fpsUnavailableReason: String? = nil
    var activeGameProcess: String? = nil
    var lastUpdated: String? = nil
    var volumeAvailable: Bool? = nil
    var telemetryAvailable: Bool? = nil

    var formattedUptime: String { "\(uptimeSeconds / 3600)h \((uptimeSeconds % 3600) / 60)m" }
    static var demo: PCMetrics {
        var m = PCMetrics()
        m.hostname = "Preview PC"
        m.cpuName = "Example 8-core processor"
        m.gpuName = "Example graphics card"
        m.isOnline = true
        m.cpuTemp = 48; m.cpuUsage = 24; m.gpuTemp = 56; m.gpuUsage = 36
        m.gpuPowerWatts = 110; m.ramUsedGB = 12.4; m.ramTotalGB = 32
        m.vramUsedGB = 4; m.vramTotalGB = 12; m.ssdUsedTB = 0.68; m.ssdTotalTB = 1.82
        m.uptimeSeconds = 10200; m.volume = 40
        m.activeGame = "Example game"; m.fps = 118; m.fpsSource = "Simulated preview"
        return m
    }
}

struct PCSpecs: Codable {
    struct CPU: Codable { var name: String?; var manufacturer: String?; var physicalCores: Int?; var logicalCores: Int?; var maxClockMHz: Double? }
    struct Motherboard: Codable { var manufacturer: String?; var model: String?; var biosVersion: String? }
    struct MemoryModule: Codable { var manufacturer: String?; var partNumber: String?; var capacityGB: Double?; var speedMHz: Double?; var slot: String? }
    struct Memory: Codable { var totalGB: Double?; var modules: [MemoryModule] }
    struct GPU: Codable { var name: String?; var driverVersion: String?; var vramGB: Double? }
    struct Disk: Codable { var name: String?; var sizeGB: Double?; var interfaceType: String?; var mediaType: String? }
    struct Volume: Codable { var mountpoint: String?; var fileSystem: String?; var totalGB: Double?; var usedGB: Double? }
    struct NetworkAdapter: Codable { var name: String?; var macAddress: String?; var ipv4Addresses: [String] }
    var hostname: String
    var osName: String?; var osVersion: String?; var architecture: String?
    var cpu: CPU; var motherboard: Motherboard; var memory: Memory
    var gpus: [GPU]; var disks: [Disk]; var volumes: [Volume]; var networkAdapters: [NetworkAdapter]
    var coolerName: String?; var detectedAt: String?; var source: String?
}

struct PCNetworkConfigResponse: Codable {
    var hostname: String; var ipAddress: String; var subnetMask: String
    var broadcastAddress: String; var macAddress: String; var agentPort: Int
}
struct SunshineGame: Identifiable, Codable, Hashable {
    let id: String; let title: String; let genre: String; let iconSymbol: String; let accentHex: String
    var cmd: String? = nil
    var isFavorite: Bool = false
}
enum SmartLaunchStep: String {
    case idle = ""
    case checkingPC = "Checking your PC…"
    case sendingWoL = "Sending Wake-on-LAN…"
    case waitingBoot = "Waiting for the PC agent…"
    case handshaking = "Connecting to the agent…"
    case launchingGame = "Requesting game launch…"
    case streaming = "Opening desktop preview…"
}

struct OrbitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WakeOnLANService {
    static func calculateBroadcastAddress(ip: String, subnetMask: String) -> String {
        var addr = in_addr(), mask = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1, inet_pton(AF_INET, subnetMask, &mask) == 1 else { return "" }
        var broadcast = in_addr(s_addr: addr.s_addr | ~mask.s_addr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }
    static func sendMagicPacket(macAddress: String, pcIP: String, targetBroadcastIP: String, subnetMask: String, port: UInt16) async throws {
        let cleaned = macAddress.filter { !":-. ".contains($0) }
        guard cleaned.count == 12, port > 0 else { throw OrbitError(message: "Enter a valid MAC address and UDP port (1–65535).") }
        let chars = Array(cleaned)
        var mac: [UInt8] = []
        for i in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { throw OrbitError(message: "The MAC address must contain six hexadecimal pairs.") }
            mac.append(byte)
        }
        guard mac.contains(where: { $0 != 0 }), mac != Array(repeating: 255, count: 6) else { throw OrbitError(message: "Enter your PC network adapter’s MAC address.") }
        let packet = Array(repeating: UInt8(255), count: 6) + Array(repeating: mac, count: 16).flatMap { $0 }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw OrbitError(message: "Could not open a Wake-on-LAN socket.") }
        defer { Darwin.close(socket) }
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw OrbitError(message: "Could not enable network broadcast.") }
        let calculated = calculateBroadcastAddress(ip: pcIP, subnetMask: subnetMask)
        let primary = targetBroadcastIP.isEmpty ? calculated : targetBroadcastIP
        guard !primary.isEmpty else { throw OrbitError(message: "Check the PC IPv4 address and subnet mask.") }
        var sent = false
        for target in Set([primary, calculated, pcIP]) where !target.isEmpty {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            for _ in 0..<3 {
                let count = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(socket, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || count == packet.count
            }
        }
        guard sent else { throw OrbitError(message: "Wake packet could not be sent. Check local network permission and Wi-Fi.") }
    }
}

private enum TokenStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OrbitAgent", kSecAttrAccount as String: "apiToken"]
    static func read() -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return String(data: data, encoding: .utf8) ?? "" }
        // Migrate an existing installation without retaining the old shared secret default.
        let old = UserDefaults.standard.string(forKey: "apiToken") ?? ""
        let token = old == "endspec-secret-token" ? "" : old
        save(token); UserDefaults.standard.removeObject(forKey: "apiToken")
        return token
    }
    static func save(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

@MainActor
final class OrbitViewModel: ObservableObject {
    @Published var pcIP = UserDefaults.standard.string(forKey: "pcIP") ?? "" { didSet { UserDefaults.standard.set(pcIP, forKey: "pcIP"); if oldValue != pcIP { pcMAC = ""; wolTargetIP = "" }; resetConnection() } }
    @Published var agentPort = (UserDefaults.standard.object(forKey: "agentPort") as? Int) ?? 8765 { didSet { UserDefaults.standard.set(agentPort, forKey: "agentPort"); resetConnection() } }
    @Published var apiToken = TokenStore.read() { didSet { TokenStore.save(apiToken); resetConnection() } }
    @AppStorage("wolTargetIP") var wolTargetIP = ""
    @AppStorage("subnetMask") var subnetMask = "255.255.255.0"
    @AppStorage("pcMAC") var pcMAC = ""
    @AppStorage("wolPort") var wolPort = 9
    @AppStorage("autoCalcBroadcast") var autoCalcBroadcast = true
    @AppStorage("demoMode") var isDemoMode = false
    @AppStorage("autoOpenMoonlight") var autoOpenMoonlight = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @Published var showOnboarding = false
    @Published var metrics = PCMetrics()
    @Published var specs: PCSpecs?
    @Published var specsError: String?
    @Published var isLoadingSpecs = false
    @Published var componentOverrides: [String: String] = [:]
    @Published var isWakingUp = false
    @Published var isScanningLAN = false
    @Published var smartLaunchStep: SmartLaunchStep = .idle
    @Published var activeStreamingGame: SunshineGame?
    @Published var isShowingStreamView = false
    @Published var isShowingIPConfigSheet = false
    @Published var statusLog = "Connect your PC to get started"
    @Published var pingMs = 0
    @Published var isDynamicIslandActive = false
    @Published var liveFrameImage: UIImage?
    @Published var isDraggingVolume = false
    @Published var games: [SunshineGame] = []
    @Published var lastUpdated: Date?
    @Published var streamError: String?
    @Published var liveActivityError: String?
    private let activity = OrbitLiveActivityCoordinator()
    private var activitySubscription: AnyCancellable?
    private var monitoringTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamWebSocket: URLSessionWebSocketTask?
    private lazy var volumeCommands = VolumeCommandQueue { [weak self] value in
        guard let self else { return }
        await self.sendInput("/api/volume", values: ["level": String(Int(value))])
    }
    private var lastVolumeChangeTime: Date = .distantPast
    private var lastSpecsAttempt: Date = .distantPast
    private var hasSynced = false
    private var isRefreshing = false
    private var appActive = true
    private var generation = 0
    private var currentIdentity = ""
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 3; c.timeoutIntervalForResource = 5
        return URLSession(configuration: c)
    }()
    var isConfigured: Bool { !cleanHost().isEmpty && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(agentPort) }
    init() {
        showOnboarding = !hasCompletedOnboarding
        loadOverrides()
        activitySubscription = activity.$isActive.sink { [weak self] value in self?.isDynamicIslandActive = value }
        if isDemoMode { metrics = .demo; games = Self.demoGames }
        startMonitoringLoop()
    }
    private static var demoGames: [SunshineGame] {
        [SunshineGame(id: "demo", title: "Example game", genre: "Simulated preview", iconSymbol: "gamecontroller.fill", accentHex: "5EDBD5")]
    }
    private func resetConnection() {
        generation += 1
        volumeCommands.cancel()
        lastVolumeChangeTime = .distantPast; isDraggingVolume = false
        metrics = PCMetrics(); specs = nil; games = []; lastUpdated = nil; pingMs = 0
        hasSynced = false; currentIdentity = ""; lastSpecsAttempt = .distantPast
        statusLog = "Connection settings changed — ready to connect"
        stopScreenFeed(); isShowingStreamView = false; activeStreamingGame = nil; loadOverrides()
        Task { await activity.stop() }
    }
    func cleanHost() -> String {
        pcIP.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func url(_ path: String, query: [URLQueryItem] = [], scheme: String = "http") throws -> URL {
        guard isConfigured, !cleanHost().contains("/"), !cleanHost().contains(":") else { throw OrbitError(message: "Enter the PC IPv4 address or hostname, agent port and pairing token.") }
        var c = URLComponents(); c.scheme = scheme; c.host = cleanHost(); c.port = agentPort; c.path = path; c.queryItems = query.isEmpty ? nil : query
        guard let u = c.url else { throw OrbitError(message: "The PC address is invalid.") }; return u
    }
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        var r = URLRequest(url: try url(path, query: query)); r.httpMethod = method
        r.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw OrbitError(message: "The PC did not return a valid response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw OrbitError(message: "Pairing token rejected. Copy the token shown by Orbit Agent.") }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw OrbitError(message: detail ?? "Agent returned error \(http.statusCode).")
        }
        return data
    }
    func recalculateBroadcastIfNeeded() {
        if autoCalcBroadcast { wolTargetIP = WakeOnLANService.calculateBroadcastAddress(ip: cleanHost(), subnetMask: subnetMask) }
    }
    func setAppActive(_ active: Bool) {
        appActive = active
        if active { startMonitoringLoop(); if isShowingStreamView { startLiveScreenFeed() } } else { monitoringTask?.cancel(); monitoringTask = nil; stopScreenFeed() }
    }
    func startMonitoringLoop() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    func setDemoMode(_ enabled: Bool) {
        resetConnection(); isDemoMode = enabled; loadOverrides()
        if enabled { metrics = .demo; games = Self.demoGames; statusLog = "Preview • simulated data"; lastUpdated = Date() }
        else { Task { await refreshMetrics() } }
    }
    func connect() async {
        if isDemoMode { setDemoMode(false) }
        hasSynced = false; lastSpecsAttempt = .distantPast
        let version = generation
        // Wait for an existing poll so “Test connection” reports its real result.
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard generation == version, appActive else { return }
        }
        await refreshMetrics()
    }
    func refreshMetrics() async {
        guard !isRefreshing, appActive else { return }
        if isDemoMode { statusLog = "Preview • simulated data"; return }
        guard isConfigured else { metrics.isOnline = false; statusLog = "Add your PC address and pairing token in Settings"; return }
        isRefreshing = true; defer { isRefreshing = false }
        let version = generation
        let start = Date()
        do {
            let data = try await request("/api/status")
            let decoded = try JSONDecoder().decode(PCMetrics.self, from: data)
            guard generation == version, !Task.isCancelled else { return }
            let sliderVolume = metrics.volume
            metrics = decoded
            if isDraggingVolume || volumeCommands.isSending || start <= lastVolumeChangeTime || Date().timeIntervalSince(lastVolumeChangeTime) < 2 { metrics.volume = sliderVolume }
            pingMs = max(1, Int(Date().timeIntervalSince(start) * 1000)); lastUpdated = Date()
            statusLog = "Connected • \(cleanHost())"
            await updateLiveActivity()
            guard generation == version, !Task.isCancelled else { return }
            if !hasSynced {
                await fetchNetworkConfigFromPC()
                guard generation == version, !Task.isCancelled else { return }
                await fetchSunshineApps()
                guard generation == version, !Task.isCancelled else { return }
                hasSynced = true
            }
            if specs == nil && Date().timeIntervalSince(lastSpecsAttempt) > 30 { await fetchSpecs() }
        } catch {
            guard generation == version, !Task.isCancelled else { return }
            metrics.isOnline = false; metrics.fps = nil; pingMs = 0
            statusLog = (error as? OrbitError)?.message ?? "PC unreachable • check Wi-Fi and Orbit Agent"
            await updateLiveActivity()
        }
    }
    func fetchNetworkConfigFromPC() async {
        guard !isDemoMode else { return }
        let version = generation
        do {
            let info = try JSONDecoder().decode(PCNetworkConfigResponse.self, from: await request("/api/network-info"))
            guard generation == version else { return }
            if !info.macAddress.isEmpty { pcMAC = info.macAddress }
            if !info.subnetMask.isEmpty { subnetMask = info.subnetMask }
            if autoCalcBroadcast && !info.broadcastAddress.isEmpty { wolTargetIP = info.broadcastAddress }
            let previouslyEnteredNames = componentOverrides
            currentIdentity = info.macAddress.isEmpty ? info.hostname : info.macAddress
            let hasSavedNames = UserDefaults.standard.object(forKey: overrideKey) != nil
            loadOverrides()
            if !hasSavedNames, !previouslyEnteredNames.isEmpty {
                componentOverrides = previouslyEnteredNames
                UserDefaults.standard.set(previouslyEnteredNames, forKey: overrideKey)
            }
        } catch { if version == generation { statusLog = "Network details unavailable: \(error.localizedDescription)" } }
    }
    func fetchSpecs() async {
        guard !isLoadingSpecs else { return }
        if isDemoMode { specsError = "Connect to your PC to detect its full specifications."; return }
        isLoadingSpecs = true; specsError = nil; lastSpecsAttempt = Date()
        defer { isLoadingSpecs = false }
        let version = generation
        do {
            let result = try JSONDecoder().decode(PCSpecs.self, from: await request("/api/specs"))
            guard version == generation else { return }; specs = result
        } catch { if version == generation { specsError = "Could not read specifications. Check that the updated Orbit Agent is running." } }
    }
    private var overrideKey: String { "hardwareOverrides.\(isDemoMode ? "preview" : (currentIdentity.isEmpty ? cleanHost() : currentIdentity))" }
    private func loadOverrides() { componentOverrides = UserDefaults.standard.dictionary(forKey: overrideKey) as? [String: String] ?? [:] }
    func setComponentOverride(_ key: String, value: String) {
        let clean = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if clean.isEmpty { componentOverrides.removeValue(forKey: key) } else { componentOverrides[key] = clean }
        UserDefaults.standard.set(componentOverrides, forKey: overrideKey)
    }
    func componentName(_ key: String, detected: String) -> String { componentOverrides[key] ?? detected }
    func fetchSunshineApps() async {
        guard !isDemoMode else { return }
        let version = generation
        do {
            let fetched = try JSONDecoder().decode([SunshineGame].self, from: await request("/api/sunshine/apps"))
            guard version == generation else { return }; games = fetched
        } catch { if version == generation { statusLog = "Could not refresh the Sunshine library: \(error.localizedDescription)" } }
    }
    func scanLANForPC() async {
        guard !isScanningLAN else { return }
        guard !apiToken.isEmpty, (1...65535).contains(agentPort) else { statusLog = "Enter the agent’s pairing token and port first."; return }
        let parts = cleanHost().split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { statusLog = "Enter an IPv4 address on your PC’s network first (for example 192.168.1.10)."; return }
        isScanningLAN = true; defer { isScanningLAN = false }
        let prefix = parts.prefix(3).joined(separator: "."), token = apiToken, port = agentPort, version = generation
        statusLog = "Searching \(prefix).x…"
        let found: PCNetworkConfigResponse? = await withTaskGroup(of: PCNetworkConfigResponse?.self) { group in
            let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 0.6; c.timeoutIntervalForResource = 0.8
            let scanSession = URLSession(configuration: c); defer { scanSession.invalidateAndCancel() }
            func enqueue(_ i: Int) {
                group.addTask {
                    guard !Task.isCancelled, let u = URL(string: "http://\(prefix).\(i):\(port)/api/network-info") else { return nil }
                    let discoveryURL = u.deletingLastPathComponent().appendingPathComponent("discover")
                    guard let (discoveryData, discoveryResponse) = try? await scanSession.data(from: discoveryURL),
                          (discoveryResponse as? HTTPURLResponse)?.statusCode == 200,
                          let discovery = try? JSONSerialization.jsonObject(with: discoveryData) as? [String: Any],
                          discovery["service"] as? String == "orbit-agent", !Task.isCancelled else { return nil }
                    var r = URLRequest(url: u); r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    guard let (data, response) = try? await scanSession.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200, var info = try? JSONDecoder().decode(PCNetworkConfigResponse.self, from: data) else { return nil }
                    info.ipAddress = "\(prefix).\(i)"; return info
                }
            }
            for i in 1...16 { enqueue(i) }
            var next = 17
            while let result = await group.next() {
                if let result { group.cancelAll(); return result }
                if next <= 254 { enqueue(next); next += 1 }
            }
            return nil
        }
        guard version == generation else { return }
        if let found {
            pcIP = found.ipAddress; pcMAC = found.macAddress; subnetMask = found.subnetMask
            recalculateBroadcastIfNeeded(); await connect()
        } else { statusLog = "No matching agent on \(prefix).x. Check token, firewall and PC address." }
    }
    func wakePC() async {
        guard !isWakingUp else { return }
        if isDemoMode { metrics = .demo; statusLog = "Preview • simulated wake"; return }
        guard (1...65535).contains(wolPort) else { statusLog = "Wake port must be between 1 and 65535."; return }
        isWakingUp = true; defer { isWakingUp = false }
        let version = generation
        recalculateBroadcastIfNeeded()
        do {
            try await WakeOnLANService.sendMagicPacket(macAddress: pcMAC, pcIP: cleanHost(), targetBroadcastIP: wolTargetIP, subnetMask: subnetMask, port: UInt16(wolPort))
            statusLog = "Wake packet sent • waiting for PC"
            for _ in 0..<15 {
                try await Task.sleep(for: .seconds(2))
                guard generation == version else { return }
                await refreshMetrics()
                guard generation == version else { return }
                if metrics.isOnline { statusLog = "PC connected"; return }
            }
            statusLog = "Wake packet sent, but PC has not responded. Check BIOS, Ethernet settings, and iOS broadcast restrictions. See the setup guide."
        } catch { if generation == version { statusLog = error.localizedDescription } }
    }
    func sendPowerAction(_ action: String) async {
        if isDemoMode {
            if ["sleep", "shutdown", "restart"].contains(action) { metrics.isOnline = false }
            if action == "mute" { metrics.isMuted.toggle() }
            if action == "kill_game" { metrics.activeGame = nil; metrics.fps = nil }
            statusLog = "Preview command • \(action)"; return
        }
        guard metrics.isOnline else { statusLog = "Connect to your PC first."; return }
        let version = generation
        do {
            _ = try await request("/api/action/\(action)", method: "POST")
            guard generation == version else { return }
            statusLog = "Command sent • \(action.replacingOccurrences(of: "_", with: " "))"
            if ["sleep", "shutdown", "restart"].contains(action) { metrics.isOnline = false; await activity.stop() }
        } catch { if generation == version { statusLog = error.localizedDescription } }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite, metrics.isOnline, metrics.volumeAvailable != false else { return }
        let level = min(100, max(0, value)).rounded()
        metrics.volume = level
        lastVolumeChangeTime = Date()
        guard !isDemoMode else { return }
        volumeCommands.enqueue(level)
    }
    func updateVolume(_ value: Double) async {
        setVolume(value)
        await volumeCommands.flush()
    }
    private func sendInput(_ path: String, values: [String: String]) async {
        guard !isDemoMode, metrics.isOnline else { return }
        let version = generation
        do { _ = try await request(path, method: "POST", query: values.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        catch { if generation == version { statusLog = "Command failed: \(error.localizedDescription)" } }
    }
    func sendMouseInput(dx: Int = 0, dy: Int = 0, click: String = "", scroll: Int = 0) async { await sendInput("/api/input/mouse", values: ["dx": "\(dx)", "dy": "\(dy)", "click": click, "scroll": "\(scroll)"]) }
    func sendKeyboardInput(text: String = "", key: String = "") async { await sendInput("/api/input/keyboard", values: ["text": text, "key": key]) }
    func sendGamepadButton(_ key: String) async { await sendInput("/api/input/gamepad", values: ["button": key]) }
    func smartLaunch(game: SunshineGame) async {
        guard smartLaunchStep == .idle else { return }
        let version = generation
        activeStreamingGame = game; smartLaunchStep = .checkingPC
        defer { smartLaunchStep = .idle }
        if !metrics.isOnline { smartLaunchStep = .waitingBoot; await wakePC() }
        guard version == generation, !Task.isCancelled else { return }
        guard metrics.isOnline else { statusLog = "Launch stopped: PC is not connected."; return }
        smartLaunchStep = .launchingGame
        if !isDemoMode {
            do { _ = try await request("/api/sunshine/launch", method: "POST", query: [URLQueryItem(name: "app", value: game.title)]) }
            catch { if generation == version { statusLog = "Could not launch: \(error.localizedDescription)" }; return }
        }
        guard version == generation, !Task.isCancelled else { return }
        if autoOpenMoonlight { openNativeMoonlight() } else { openDesktopPreview() }
    }
    func openDesktopPreview() { guard metrics.isOnline else { return }; isShowingStreamView = true; startLiveScreenFeed() }
    func openNativeMoonlight() {
        guard let u = URL(string: "moonlight://") else { return }
        UIApplication.shared.open(u, options: [:]) { [weak self] opened in
            if !opened { Task { @MainActor in self?.statusLog = "Install Moonlight and pair it with Sunshine to stream games." } }
        }
    }
    func startLiveScreenFeed() {
        stopScreenFeed(); streamError = nil
        guard !isDemoMode else { streamError = "Desktop preview is unavailable in demo mode."; return }
        do {
            let u = try url("/ws/stream", scheme: "ws")
            var r = URLRequest(url: u); r.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            let ws = session.webSocketTask(with: r); streamWebSocket = ws; ws.resume()
            streamTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard !Task.isCancelled else { break }
                        if case .data(let data) = message, let img = UIImage(data: data) { self?.liveFrameImage = img }
                    }
                } catch { if !Task.isCancelled { self?.streamError = "Desktop preview disconnected. Check the PC capture permission and agent." } }
            }
        } catch { streamError = error.localizedDescription }
    }
    private func stopScreenFeed() {
        streamTask?.cancel(); streamTask = nil; streamWebSocket?.cancel(with: .goingAway, reason: nil); streamWebSocket = nil; liveFrameImage = nil
    }
    func stopStreaming(putPCToSleep: Bool = false) {
        stopScreenFeed(); isShowingStreamView = false
        if putPCToSleep { Task { await sendPowerAction("sleep") } }
    }
    func toggleDynamicIsland() {
        Task {
            if activity.isActive { await activity.stop() }
            else {
                guard metrics.isOnline else { liveActivityError = "Connect to your PC before starting a Live Activity."; return }
                await activity.start(pcName: metrics.hostname, cpuUsage: metrics.telemetryAvailable == false ? nil : metrics.cpuUsage, gpuUsage: metrics.gpuUsage, ramUsage: metrics.ramTotalGB > 0 ? metrics.ramUsedGB / metrics.ramTotalGB * 100 : nil, fps: metrics.fps, gameName: metrics.activeGame)
                liveActivityError = activity.lastError
            }
        }
    }
    private func updateLiveActivity() async {
        guard activity.isActive else { return }
        await activity.update(cpuUsage: metrics.telemetryAvailable == false ? nil : metrics.cpuUsage, gpuUsage: metrics.gpuUsage, ramUsage: metrics.ramTotalGB > 0 ? metrics.ramUsedGB / metrics.ramTotalGB * 100 : nil, fps: metrics.fps, gameName: metrics.activeGame, isConnected: metrics.isOnline)
    }
}
