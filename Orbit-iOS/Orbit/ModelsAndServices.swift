import Foundation
import Network
import SwiftUI
import Darwin

// MARK: - 1. Data Models

struct PCMetrics: Codable {
    var hostname: String
    var cpuName: String
    var motherboard: String
    var coolerName: String
    var isOnline: Bool
    var cpuTemp: Double
    var cpuUsage: Double
    var liquidTemp: Double
    var gpuName: String
    var gpuTemp: Double
    var gpuUsage: Double
    var gpuPowerWatts: Double
    var vramUsedGB: Double
    var vramTotalGB: Double
    var ramUsedGB: Double
    var ramTotalGB: Double
    var ssdUsedTB: Double
    var ssdTotalTB: Double
    var uptimeSeconds: Int
    var activeGame: String?
    var volume: Double
    var isMuted: Bool
    var hdrEnabled: Bool

    var formattedUptime: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

struct PCNetworkConfigResponse: Codable {
    var hostname: String
    var ipAddress: String
    var subnetMask: String
    var broadcastAddress: String
    var macAddress: String
    var agentPort: Int
}

struct SunshineGame: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let genre: String
    let iconSymbol: String
    let accentHex: String
    var cmd: String? = nil
    var isFavorite: Bool = false
}

enum StreamingProfile: String, CaseIterable, Identifiable {
    case balanced = "1080p • 60 FPS (Balanced)"
    case competitive = "1440p • 120 FPS (Low Latency)"
    case ultra = "4K • 120 FPS (HDR / HEVC)"

    var id: String { rawValue }

    var bitrateMbps: Int {
        switch self {
        case .balanced: return 35
        case .competitive: return 80
        case .ultra: return 150
        }
    }
}

enum SmartLaunchStep: String {
    case idle = ""
    case checkingPC = "Checking PC power state..."
    case sendingWoL = "PC is Offline. Sending Magic Packet..."
    case waitingBoot = "Waiting for Windows & Sunshine service..."
    case handshaking = "Verifying Sunshine GameStream handshake..."
    case launchingGame = "Launching executable on PC..."
    case streaming = "Stream session active!"
}

// MARK: - 2. Low-Level BSD Socket Wake-on-LAN Service (with SO_BROADCAST)

final class WakeOnLANService {
    static func calculateBroadcastAddress(ip: String, subnetMask: String) -> String {
        var ipAddr = in_addr()
        var maskAddr = in_addr()
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMask = subnetMask.trimmingCharacters(in: .whitespacesAndNewlines)

        guard inet_pton(AF_INET, cleanIP, &ipAddr) == 1,
              inet_pton(AF_INET, cleanMask, &maskAddr) == 1 else {
            let parts = cleanIP.split(separator: ".")
            if parts.count == 4 {
                return "\(parts[0]).\(parts[1]).\(parts[2]).255"
            }
            return "192.168.1.255"
        }

        let broadcastInt = ipAddr.s_addr | ~maskAddr.s_addr
        var broadcastAddr = in_addr(s_addr: broadcastInt)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &broadcastAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
            return String(cString: buffer)
        }
        return "192.168.1.255"
    }

    static func sendMagicPacket(
        macAddress: String,
        pcIP: String,
        targetBroadcastIP: String,
        subnetMask: String,
        port: UInt16
    ) async throws {
        let cleanedMAC = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanedMAC.count == 12 else {
            throw NSError(domain: "WoL", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid MAC address (12 hex chars required)."])
        }

        var macBytes: [UInt8] = []
        var index = cleanedMAC.startIndex
        for _ in 0..<6 {
            let nextIndex = cleanedMAC.index(index, offsetBy: 2)
            guard let byte = UInt8(cleanedMAC[index..<nextIndex], radix: 16) else {
                throw NSError(domain: "WoL", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HEX byte in MAC."])
            }
            macBytes.append(byte)
            index = nextIndex
        }

        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        let autoBroadcast = calculateBroadcastAddress(ip: pcIP, subnetMask: subnetMask)
        let explicitBroadcast = targetBroadcastIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryBroadcast = explicitBroadcast.isEmpty ? autoBroadcast : explicitBroadcast

        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            throw NSError(domain: "WoL", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not open UDP socket."])
        }
        defer { Darwin.close(sock) }

        var broadcastEnable: Int32 = 1
        Darwin.setsockopt(
            sock,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnable,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let destinations = Array(Set([primaryBroadcast, autoBroadcast, pcIP, "255.255.255.255"]))
        let ports = Array(Set([port, 9, 7]))

        for _ in 0..<3 {
            for destIP in destinations {
                for destPort in ports {
                    var addr = sockaddr_in()
                    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = destPort.bigEndian
                    guard inet_pton(AF_INET, destIP, &addr.sin_addr) == 1 else { continue }

                    packet.withUnsafeBytes { rawBuf in
                        guard let basePtr = rawBuf.baseAddress else { return }
                        withUnsafePointer(to: &addr) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                                _ = Darwin.sendto(
                                    sock,
                                    basePtr,
                                    packet.count,
                                    0,
                                    sockaddrPtr,
                                    socklen_t(MemoryLayout<sockaddr_in>.size)
                                )
                            }
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }
}

// MARK: - 3. Main ViewModel (Orbit Controller)

@MainActor
final class OrbitViewModel: ObservableObject {
    // Persistent User-Configurable Network Settings (Editable directly in the iOS App)
    @AppStorage("pcIP") var pcIP: String = "192.168.1.196"
    @AppStorage("wolTargetIP") var wolTargetIP: String = "192.168.1.255"
    @AppStorage("subnetMask") var subnetMask: String = "255.255.255.0"
    @AppStorage("pcMAC") var pcMAC: String = "AA:BB:CC:11:22:33"
    @AppStorage("wolPort") var wolPort: Int = 9
    @AppStorage("agentPort") var agentPort: Int = 8765
    @AppStorage("sunshinePort") var sunshinePort: Int = 47989
    @AppStorage("apiToken") var apiToken: String = "endspec-secret-token"
    @AppStorage("autoCalcBroadcast") var autoCalcBroadcast: Bool = true
    @AppStorage("demoMode") var isDemoMode: Bool = false
    @AppStorage("autoOpenMoonlight") var autoOpenMoonlight: Bool = false

    @Published var metrics = PCMetrics(
        hostname: "ASTRAL-9950X3D",
        cpuName: "AMD Ryzen 9 9950X3D",
        motherboard: "ASUS ROG Crosshair X870E Extreme",
        coolerName: "TRYX Panorama SE 360 AIO",
        isOnline: true,
        cpuTemp: 48.0,
        cpuUsage: 14.0,
        liquidTemp: 32.5,
        gpuName: "ROG Astral RTX 5090 OC",
        gpuTemp: 52.0,
        gpuUsage: 18.0,
        gpuPowerWatts: 125.0,
        vramUsedGB: 4.8,
        vramTotalGB: 32.0,
        ramUsedGB: 16.4,
        ramTotalGB: 64.0,
        ssdUsedTB: 1.4,
        ssdTotalTB: 4.0,
        uptimeSeconds: 14520,
        activeGame: nil,
        volume: 65.0,
        isMuted: false,
        hdrEnabled: true
    )

    @Published var selectedProfile: StreamingProfile = .ultra
    @Published var isWakingUp: Bool = false
    @Published var isScanningLAN: Bool = false
    @Published var smartLaunchStep: SmartLaunchStep = .idle
    @Published var activeStreamingGame: SunshineGame? = nil
    @Published var isShowingStreamView: Bool = false
    @Published var isShowingIPConfigSheet: Bool = false
    @Published var statusLog: String = "Ready to connect..."
    @Published var pingMs: Int = 2
    @Published var isDynamicIslandActive: Bool = false
    @Published var islandModeText: String = "Monitoring Rig"
    @Published var liveFrameImage: UIImage? = nil
    @Published var isDraggingVolume: Bool = false

    @Published var games: [SunshineGame] = [
        SunshineGame(id: "1", title: "Cyberpunk 2077", genre: "Path Tracing • DLSS 4", iconSymbol: "bolt.shield.fill", accentHex: "#FCEE09", isFavorite: true),
        SunshineGame(id: "2", title: "Counter-Strike 2", genre: "Competitive FPS • 240Hz", iconSymbol: "scope", accentHex: "#FF8C00", isFavorite: true),
        SunshineGame(id: "3", title: "Forza Horizon 5", genre: "Sim Racing • Fanatec DD", iconSymbol: "steeringwheel", accentHex: "#FF2A85", isFavorite: true),
        SunshineGame(id: "4", title: "Assetto Corsa", genre: "Racing Sim • Telemetry", iconSymbol: "flag.checkered.2.crossed", accentHex: "#00E5FF", isFavorite: false),
        SunshineGame(id: "5", title: "Ready or Not", genre: "Tactical FPS • Co-op", iconSymbol: "shield.lefthalf.filled", accentHex: "#3B82F6", isFavorite: false),
        SunshineGame(id: "6", title: "Windows 11 Desktop", genre: "Full Sunshine Stream", iconSymbol: "display", accentHex: "#8B5CF6", isFavorite: false)
    ]

    private var monitoringTask: Task<Void, Never>?
    private var streamWebSocket: URLSessionWebSocketTask?
    private var lastVolumeChangeTime: Date = .distantPast
    private var hasAutoSyncedNetworkInfo: Bool = false

    private lazy var fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.0
        return URLSession(configuration: config)
    }()

    init() {
        startMonitoringLoop()
    }

    func startMonitoringLoop() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func cleanHost() -> String {
        pcIP.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    func recalculateBroadcastIfNeeded() {
        if autoCalcBroadcast {
            wolTargetIP = WakeOnLANService.calculateBroadcastAddress(ip: cleanHost(), subnetMask: subnetMask)
        }
    }

    // Automatically pulls the PC's exact MAC address, Subnet Mask, and Broadcast IP when connected
    func fetchNetworkConfigFromPC() async {
        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/network-info") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        if let (data, response) = try? await fastSession.data(for: request),
           let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
           let netInfo = try? JSONDecoder().decode(PCNetworkConfigResponse.self, from: data) {
            if !netInfo.ipAddress.isEmpty && netInfo.ipAddress != "127.0.0.1" {
                self.pcIP = netInfo.ipAddress
            }
            if !netInfo.macAddress.isEmpty && netInfo.macAddress != "00:00:00:00:00:00" {
                self.pcMAC = netInfo.macAddress
            }
            if !netInfo.subnetMask.isEmpty {
                self.subnetMask = netInfo.subnetMask
            }
            if !netInfo.broadcastAddress.isEmpty {
                self.wolTargetIP = netInfo.broadcastAddress
            }
            self.hasAutoSyncedNetworkInfo = true
            self.statusLog = "Auto-synced IP (\(self.pcIP)), MAC & Broadcast (\(self.wolTargetIP))"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // Scans the local /24 subnet in parallel to automatically find the PC running Orbit Agent
    func scanLANForPC() async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isScanningLAN = true
        isDemoMode = false

        let parts = cleanHost().split(separator: ".")
        let prefix = parts.count == 4 ? "\(parts[0]).\(parts[1]).\(parts[2])" : "192.168.1"
        statusLog = "Scanning \(prefix).1 - 254 on port \(agentPort)..."

        let port = self.agentPort
        let token = self.apiToken

        let foundConfig: PCNetworkConfigResponse? = await withTaskGroup(of: PCNetworkConfigResponse?.self) { group in
            let scanConfig = URLSessionConfiguration.ephemeral
            scanConfig.timeoutIntervalForRequest = 0.45
            scanConfig.timeoutIntervalForResource = 0.55
            let scanSession = URLSession(configuration: scanConfig)

            for i in 1...254 {
                let candidateIP = "\(prefix).\(i)"
                group.addTask {
                    guard let url = URL(string: "http://\(candidateIP):\(port)/api/network-info") else { return nil }
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    if let (data, resp) = try? await scanSession.data(for: req),
                       let http = resp as? HTTPURLResponse, http.statusCode == 200,
                       var decoded = try? JSONDecoder().decode(PCNetworkConfigResponse.self, from: data) {
                        decoded.ipAddress = candidateIP
                        return decoded
                    }
                    return nil
                }
            }

            for await result in group {
                if let valid = result {
                    group.cancelAll()
                    return valid
                }
            }
            return nil
        }

        isScanningLAN = false
        if let config = foundConfig {
            self.pcIP = config.ipAddress
            if !config.macAddress.isEmpty { self.pcMAC = config.macAddress }
            if !config.subnetMask.isEmpty { self.subnetMask = config.subnetMask }
            if !config.broadcastAddress.isEmpty {
                self.wolTargetIP = config.broadcastAddress
            } else {
                recalculateBroadcastIfNeeded()
            }
            self.statusLog = "Found \(config.hostname) at \(config.ipAddress)!"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await refreshMetrics()
        } else {
            self.statusLog = "No PC found on \(prefix).x:\(agentPort). Check if Agent is running."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func refreshMetrics() async {
        if isDemoMode {
            guard metrics.isOnline else { return }
            let isGaming = metrics.activeGame != nil
            metrics.cpuTemp = min(84, max(40, metrics.cpuTemp + Double.random(in: -1.3...1.5)))
            metrics.gpuTemp = min(76, max(36, metrics.gpuTemp + Double.random(in: -1.1...1.3)))
            metrics.liquidTemp = min(40, max(29, metrics.liquidTemp + Double.random(in: -0.2...0.3)))
            metrics.cpuUsage = isGaming ? Double.random(in: 42...74) : Double.random(in: 6...22)
            metrics.gpuUsage = isGaming ? Double.random(in: 88...99) : Double.random(in: 4...16)
            metrics.gpuPowerWatts = isGaming ? Double.random(in: 420...565) : Double.random(in: 65...140)
            metrics.vramUsedGB = isGaming ? 18.6 : 4.2
            metrics.ramUsedGB = isGaming ? 29.4 : 18.2
            metrics.uptimeSeconds += 1
            pingMs = Int.random(in: 1...3)
            statusLog = "Demo Mode Active (Simulated)"
            return
        }

        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/status?t=\(Date().timeIntervalSince1970)") else {
            statusLog = "Invalid IP address format"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let startTime = DispatchTime.now()
        do {
            let (data, response) = try await fastSession.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                statusLog = "Auth Error: Check API Token"
                return
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            let decoded = try JSONDecoder().decode(PCMetrics.self, from: data)

            let currentSliderVol = self.metrics.volume
            let recentlyChangedVolume = Date().timeIntervalSince(lastVolumeChangeTime) < 2.0

            self.metrics = decoded
            if isDraggingVolume || recentlyChangedVolume {
                self.metrics.volume = currentSliderVol
            }
            self.pingMs = max(1, Int(elapsed))
            self.statusLog = "Connected • \(host) (\(self.pingMs) ms)"

            // Auto-populate MAC address & Broadcast IP on first successful connection
            if !hasAutoSyncedNetworkInfo {
                await fetchNetworkConfigFromPC()
            }
        } catch {
            self.metrics.isOnline = false
            self.statusLog = "Offline • Target WoL: \(wolTargetIP) (\(pcMAC))"
        }
    }

    func fetchSunshineApps() async {
        guard !isDemoMode else { return }
        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/sunshine/apps") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await fastSession.data(for: request),
           let fetched = try? JSONDecoder().decode([SunshineGame].self, from: data),
           !fetched.isEmpty {
            withAnimation { self.games = fetched }
            self.statusLog = "Synced \(fetched.count) games from Sunshine"
        }
    }

    func wakePC() async {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        isWakingUp = true
        recalculateBroadcastIfNeeded()
        islandModeText = "Waking PC (WoL)..."
        statusLog = "Sending Magic Packet to \(wolTargetIP) (\(pcMAC))..."

        do {
            try await WakeOnLANService.sendMagicPacket(
                macAddress: pcMAC,
                pcIP: cleanHost(),
                targetBroadcastIP: wolTargetIP,
                subnetMask: subnetMask,
                port: UInt16(wolPort)
            )
            statusLog = "Magic Packet sent to \(wolTargetIP):\(wolPort)!"
        } catch {
            statusLog = "WoL Error: \(error.localizedDescription)"
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        isWakingUp = false
        if isDemoMode {
            withAnimation(.spring()) {
                metrics.isOnline = true
                statusLog = "PC is Awake!"
            }
        } else {
            await refreshMetrics()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func sendPowerAction(_ action: String) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        if isDemoMode {
            statusLog = "Demo Command: \(action.uppercased())"
            if action == "sleep" || action == "shutdown" {
                withAnimation(.spring()) {
                    metrics.isOnline = false
                    metrics.activeGame = nil
                }
            } else if action == "toggle_hdr" {
                metrics.hdrEnabled.toggle()
            } else if action == "mute" {
                metrics.isMuted.toggle()
            } else if action == "kill_game" {
                metrics.activeGame = nil
            }
            return
        }

        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/action/\(action)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await fastSession.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                statusLog = "Executed: \(action.uppercased())"
                if action == "sleep" || action == "shutdown" {
                    withAnimation { metrics.isOnline = false }
                }
            }
        } catch {
            statusLog = "Failed: \(action.uppercased())"
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await refreshMetrics()
    }

    func updateVolume(_ newVolume: Double) async {
        lastVolumeChangeTime = Date()
        guard !isDemoMode else { return }
        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/volume?level=\(Int(newVolume))") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        _ = try? await fastSession.data(for: request)
    }

    func sendMouseInput(dx: Int = 0, dy: Int = 0, click: String = "", scroll: Int = 0) async {
        guard !isDemoMode else { return }
        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/input/mouse?dx=\(dx)&dy=\(dy)&click=\(click)&scroll=\(scroll)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        _ = try? await fastSession.data(for: request)
    }

    func sendKeyboardInput(text: String = "", key: String = "") async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !isDemoMode else { return }
        let host = cleanHost()
        let encText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://\(host):\(agentPort)/api/input/keyboard?text=\(encText)&key=\(encKey)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        _ = try? await fastSession.data(for: request)
    }

    func smartLaunch(game: SunshineGame) async {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        activeStreamingGame = game

        withAnimation { smartLaunchStep = .checkingPC }
        try? await Task.sleep(nanoseconds: 500_000_000)

        if !metrics.isOnline {
            withAnimation { smartLaunchStep = .sendingWoL }
            recalculateBroadcastIfNeeded()
            try? await WakeOnLANService.sendMagicPacket(
                macAddress: pcMAC,
                pcIP: cleanHost(),
                targetBroadcastIP: wolTargetIP,
                subnetMask: subnetMask,
                port: UInt16(wolPort)
            )
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            withAnimation { smartLaunchStep = .waitingBoot }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            metrics.isOnline = true
        }

        withAnimation { smartLaunchStep = .handshaking }
        try? await Task.sleep(nanoseconds: 600_000_000)

        withAnimation { smartLaunchStep = .launchingGame }
        if !isDemoMode {
            let host = cleanHost()
            if let encodedTitle = game.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "http://\(host):\(agentPort)/api/sunshine/launch?app=\(encodedTitle)") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
                _ = try? await fastSession.data(for: request)
            }
        }
        metrics.activeGame = game.title
        try? await Task.sleep(nanoseconds: 700_000_000)

        withAnimation {
            smartLaunchStep = .idle
            isShowingStreamView = true
        }
        startLiveScreenFeed()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if autoOpenMoonlight {
            openNativeMoonlight()
        }
    }

    func openNativeMoonlight() {
        if let url = URL(string: "moonlight://") {
            UIApplication.shared.open(url)
        }
    }

    func startLiveScreenFeed() {
        streamWebSocket?.cancel(with: .goingAway, reason: nil)
        guard !isDemoMode else { return }
        let host = cleanHost()
        if let wsURL = URL(string: "ws://\(host):\(agentPort)/ws/stream?token=\(apiToken)") {
            let ws = fastSession.webSocketTask(with: wsURL)
            self.streamWebSocket = ws
            ws.resume()
            receiveNextWebSocketFrame()
        }
    }

    private func receiveNextWebSocketFrame() {
        streamWebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .data(let data) = message, let img = UIImage(data: data) {
                    Task { @MainActor in
                        self.liveFrameImage = img
                        self.receiveNextWebSocketFrame()
                    }
                } else {
                    Task { @MainActor in self.receiveNextWebSocketFrame() }
                }
            case .failure:
                break
            }
        }
    }

    func sendGamepadButton(_ key: String) async {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        guard !isDemoMode else { return }
        let host = cleanHost()
        guard let url = URL(string: "http://\(host):\(agentPort)/api/input/gamepad?button=\(key)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        _ = try? await fastSession.data(for: request)
    }

    func stopStreaming(putPCToSleep: Bool = false) {
        streamWebSocket?.cancel(with: .goingAway, reason: nil)
        streamWebSocket = nil
        liveFrameImage = nil
        withAnimation {
            isShowingStreamView = false
            metrics.activeGame = nil
        }
        if putPCToSleep {
            Task { await sendPowerAction("sleep") }
        } else {
            // Automatically ensure physical monitor stays awake after closing stream
            Task { await sendPowerAction("restore_display") }
        }
    }

    func toggleDynamicIsland() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            isDynamicIslandActive.toggle()
        }
    }
}
