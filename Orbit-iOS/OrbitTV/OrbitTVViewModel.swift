import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import SwiftUI
import UIKit

struct OrbitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TVPCMetrics: Codable {
    var hostname: String = "Gaming PC"
    var agentVersion: String? = nil
    var cpuName: String = "Processor"
    var gpuName: String = "Graphics"
    var isOnline: Bool = false
    var cpuTemp: Double? = nil
    var cpuUsage: Double = 0
    var liquidTemp: Double? = nil
    var gpuTemp: Double? = nil
    var gpuUsage: Double? = nil
    var gpuPowerWatts: Double? = nil
    var cpuPowerWatts: Double? = nil
    var cpuClockMHz: Double? = nil
    var cpuFanRPM: Double? = nil
    var gpuFanPercent: Double? = nil
    var diskReadMBps: Double? = nil
    var diskWriteMBps: Double? = nil
    var networkUploadMBps: Double? = nil
    var networkDownloadMBps: Double? = nil
    var vramUsedGB: Double? = nil
    var vramTotalGB: Double? = nil
    var ramUsedGB: Double = 0
    var ramTotalGB: Double = 0
    var ssdUsedTB: Double = 0
    var ssdTotalTB: Double = 0
    var uptimeSeconds: Int = 0
    var activeGame: String? = nil
    var volume: Double = 50
    var isMuted: Bool = false
    var fps: Double? = nil
    var fpsSource: String? = nil
    var telemetryAvailable: Bool? = nil

    var formattedUptime: String {
        guard uptimeSeconds > 0 else { return "0h 0m" }
        return "\(uptimeSeconds / 3600)h \((uptimeSeconds % 3600) / 60)m"
    }

    var ramUsagePercent: Double {
        guard ramTotalGB > 0 else { return 0 }
        return min(100, max(0, ramUsedGB / ramTotalGB * 100.0))
    }

    var vramUsagePercent: Double {
        guard let used = vramUsedGB, let total = vramTotalGB, total > 0 else { return 0 }
        return min(100, max(0, used / total * 100.0))
    }

    var ssdUsagePercent: Double {
        guard ssdTotalTB > 0 else { return 0 }
        return min(100, max(0, ssdUsedTB / ssdTotalTB * 100.0))
    }

    static var demo: TVPCMetrics {
        var m = TVPCMetrics()
        m.hostname = "Living Room Rig"
        m.agentVersion = "4.2.0 · preview"
        m.cpuName = "AMD Ryzen 7 7800X3D"
        m.gpuName = "NVIDIA GeForce RTX 4080 SUPER"
        m.isOnline = true
        m.telemetryAvailable = true
        m.cpuUsage = 32
        m.cpuTemp = 54
        m.cpuClockMHz = 4850
        m.cpuPowerWatts = 64
        m.cpuFanRPM = 1080
        m.liquidTemp = 34.5
        m.gpuUsage = 78
        m.gpuTemp = 63
        m.gpuPowerWatts = 245
        m.gpuFanPercent = 58
        m.ramUsedGB = 14.8
        m.ramTotalGB = 32.0
        m.vramUsedGB = 9.4
        m.vramTotalGB = 16.0
        m.ssdUsedTB = 0.84
        m.ssdTotalTB = 2.0
        m.diskReadMBps = 128.4
        m.diskWriteMBps = 24.2
        m.networkDownloadMBps = 42.6
        m.networkUploadMBps = 4.8
        m.uptimeSeconds = 15420
        m.activeGame = "Cyberpunk 2077"
        m.fps = 138
        m.fpsSource = "RTSS / PresentMon"
        m.volume = 60
        m.isMuted = false
        return m
    }
}

struct TVSavedPC: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
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
}

struct TVDiscoveredPC: Identifiable, Equatable {
    var id: String { "\(host):\(securePort)" }
    var name: String
    var host: String
    var discoveryPort: Int
    var securePort: Int
    var fingerprint: String
    var agentVersion: String
}

struct TVSunshineGame: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let genre: String
    let iconSymbol: String
    let accentHex: String
}

struct TVAudioSession: Codable, Identifiable, Equatable {
    let id: String
    let pid: Int
    let name: String
    var volume: Double
    var isMuted: Bool
    var processCreateTime: Double?
    var outputDeviceID: String?
    var outputDeviceName: String?
}

struct TVAudioOutputDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct TVProcessItem: Codable, Identifiable, Equatable {
    var pid: Int
    var name: String
    var createTime: Double
    var memoryMB: Double?
    var cpuPercent: Double?
    var gpuPercent: Double?
    var vramMB: Double?
    var status: String
    var canTerminate: Bool
    var id: String { "\(pid):\(createTime)" }
}

private struct TVProcessListReply: Decodable {
    var processes: [TVProcessItem]
    var capturedAt: Double
    var totalCount: Int
}

private struct TVAudioSessionsReply: Decodable {
    let sessions: [TVAudioSession]
    let available: Bool
}

private struct TVAudioOutputsReply: Decodable {
    let devices: [TVAudioOutputDevice]
    let routingAvailable: Bool
}

private struct TVAudioSessionChange: Encodable {
    let id: String
    var volume: Double?
    var isMuted: Bool?
}

private struct TVAudioSessionReply: Decodable {
    let status: String
    let session: TVAudioSession
}

private struct TVAudioRouteChange: Encodable {
    let id: String
    let expectedCreateTime: Double
    let deviceID: String
}

private struct TVAudioRouteReply: Decodable {
    let status: String
}

@MainActor
final class OrbitTVViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var savedPCs: [TVSavedPC] = []
    @Published var selectedPCID: String = UserDefaults.standard.string(forKey: "tv.selectedPCID") ?? ""
    @Published var isDemoMode: Bool = UserDefaults.standard.bool(forKey: "tv.demoMode")

    @Published var metrics = TVPCMetrics()
    @Published var pingMs: Int = 0
    @Published var statusBanner: String = "Select Pair New PC or enable Preview Mode to explore"
    @Published var isWaking: Bool = false

    // Rolling sparkline history & session peaks
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 24)
    @Published var gpuHistory: [Double] = Array(repeating: 0, count: 24)
    @Published var fpsHistory: [Double] = Array(repeating: 0, count: 24)
    @Published var peakCPUTemp: Double = 0
    @Published var peakGPUTemp: Double = 0
    @Published var peakFPS: Double = 0
    @Published var peakPowerWatts: Double = 0

    // Games & Live Desktop Stream
    @Published var games: [TVSunshineGame] = []
    @Published var liveFrameImage: UIImage?
    @Published var isStreamingScreen: Bool = false
    @Published var streamStatus: String = "Press Start Stream to view your PC desktop on Apple TV"

    // Audio Mixer
    @Published var audioSessions: [TVAudioSession] = []
    @Published var audioOutputs: [TVAudioOutputDevice] = []
    @Published var audioRoutingAvailable: Bool = false

    // Task Manager
    @Published var processes: [TVProcessItem] = []
    @Published var isLoadingProcesses: Bool = false
    @Published var processStatusMessage: String?

    // Discovery & 6-Digit PIN Pairing
    @Published var discoveredPCs: [TVDiscoveredPC] = []
    @Published var isScanningNetwork: Bool = false
    @Published var activePairingTarget: TVDiscoveredPC?
    @Published var pairingPIN: String = ""
    @Published var isPairingInProgress: Bool = false
    @Published var pairingErrorMessage: String?

    private var activeHandshake: OrbitPairingHandshake?
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamWebSocket: URLSessionWebSocketTask?
    private var streamClient: OrbitAPIClient?
    private var browser: NWBrowser?
    private var appActive: Bool = true
    private var hasSyncedExtras: Bool = false

    private static let savedPCsKey = "tv.savedPCs.v1"

    init() {
        loadSavedPCs()
        if savedPCs.isEmpty && !isDemoMode {
            // Enable demo mode initially if no PC is paired yet so the 4K dashboard is immediately interactive
            setDemoMode(true)
        } else if isDemoMode {
            applyDemoData()
        }
        startPollingLoop()
    }

    var currentPC: TVSavedPC? {
        savedPCs.first(where: { $0.id == selectedPCID }) ?? savedPCs.first
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if active {
            startPollingLoop()
        } else {
            stopScreenStream()
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        UserDefaults.standard.set(enabled, forKey: "tv.demoMode")
        if enabled {
            applyDemoData()
        } else {
            metrics = TVPCMetrics()
            statusBanner = currentPC != nil ? "Connecting to \(currentPC!.name)…" : "Pair your PC in the My PCs tab"
            Task { await refreshMetrics() }
        }
    }

    private func applyDemoData() {
        metrics = .demo
        pingMs = 2
        statusBanner = "Preview Mode · Simulated 4K Telemetry"
        cpuHistory = [24, 28, 31, 29, 35, 38, 33, 30, 28, 34, 39, 41, 36, 32, 30, 29, 33, 37, 35, 31, 29, 34, 33, 32]
        gpuHistory = [68, 72, 75, 74, 79, 82, 80, 77, 75, 78, 84, 85, 81, 79, 76, 74, 78, 82, 80, 77, 76, 79, 78, 78]
        fpsHistory = [132, 136, 140, 138, 134, 129, 135, 139, 142, 137, 133, 131, 136, 140, 141, 139, 137, 134, 136, 138, 140, 139, 137, 138]
        peakCPUTemp = 61
        peakGPUTemp = 67
        peakFPS = 144
        peakPowerWatts = 325
        games = [
            TVSunshineGame(id: "1", title: "Cyberpunk 2077", genre: "Action RPG · HDR", iconSymbol: "gamecontroller.fill", accentHex: "#FCEE09"),
            TVSunshineGame(id: "2", title: "Forza Horizon 5", genre: "Racing · 4K 120Hz", iconSymbol: "car.fill", accentHex: "#FF5883"),
            TVSunshineGame(id: "3", title: "Elden Ring", genre: "Action RPG", iconSymbol: "shield.lefthalf.filled", accentHex: "#E5B85B"),
            TVSunshineGame(id: "4", title: "Baldur's Gate 3", genre: "CRPG", iconSymbol: "sparkles", accentHex: "#9D7BFF"),
            TVSunshineGame(id: "5", title: "Steam Big Picture", genre: "Launcher · Couch UI", iconSymbol: "tv.and.mediabox.fill", accentHex: "#3FD5F6"),
            TVSunshineGame(id: "6", title: "Desktop Stream", genre: "Windows 11 Pro", iconSymbol: "display", accentHex: "#59F0A8")
        ]
        audioSessions = [
            TVAudioSession(id: "demo-1", pid: 4100, name: "Cyberpunk2077.exe", volume: 85, isMuted: false, processCreateTime: 1, outputDeviceID: "tv-1", outputDeviceName: "LG OLED TV (NVIDIA High Definition Audio)"),
            TVAudioSession(id: "demo-2", pid: 5210, name: "Discord.exe", volume: 70, isMuted: false, processCreateTime: 2, outputDeviceID: "tv-2", outputDeviceName: "Wireless Gaming Headset"),
            TVAudioSession(id: "demo-3", pid: 6320, name: "Spotify.exe", volume: 40, isMuted: false, processCreateTime: 3, outputDeviceID: "tv-1", outputDeviceName: "LG OLED TV (NVIDIA High Definition Audio)"),
            TVAudioSession(id: "demo-4", pid: 7110, name: "Chrome.exe", volume: 50, isMuted: true, processCreateTime: 4, outputDeviceID: "tv-1", outputDeviceName: "LG OLED TV (NVIDIA High Definition Audio)")
        ]
        audioOutputs = [
            TVAudioOutputDevice(id: "tv-1", name: "LG OLED TV (NVIDIA High Definition Audio)"),
            TVAudioOutputDevice(id: "tv-2", name: "Wireless Gaming Headset"),
            TVAudioOutputDevice(id: "tv-3", name: "Desktop Studio Monitors")
        ]
        audioRoutingAvailable = true
        processes = [
            TVProcessItem(pid: 4100, name: "Cyberpunk2077.exe", createTime: 1, memoryMB: 6420, cpuPercent: 24.5, gpuPercent: 76.2, vramMB: 8940, status: "running", canTerminate: true),
            TVProcessItem(pid: 5210, name: "Discord.exe", createTime: 2, memoryMB: 540, cpuPercent: 2.1, gpuPercent: 1.4, vramMB: 210, status: "running", canTerminate: true),
            TVProcessItem(pid: 6320, name: "Spotify.exe", createTime: 3, memoryMB: 380, cpuPercent: 1.2, gpuPercent: 0.4, vramMB: 115, status: "running", canTerminate: true),
            TVProcessItem(pid: 8420, name: "sunshine.exe", createTime: 4, memoryMB: 290, cpuPercent: 3.4, gpuPercent: 4.8, vramMB: 340, status: "running", canTerminate: true),
            TVProcessItem(pid: 7110, name: "chrome.exe", createTime: 5, memoryMB: 1420, cpuPercent: 1.8, gpuPercent: 0.9, vramMB: 420, status: "running", canTerminate: true)
        ]
    }

    // MARK: - Polling & Connection

    func startPollingLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func client(for pc: TVSavedPC? = nil) throws -> OrbitAPIClient {
        guard let target = pc ?? currentPC else {
            throw OrbitError(message: "Pair your PC first in the My PCs tab.")
        }
        let token = readToken(for: target.id)
        return try OrbitAPIClient(
            host: target.address,
            port: target.securePort,
            token: token,
            fingerprint: target.certificateFingerprint
        )
    }

    func refreshMetrics() async {
        guard appActive else { return }
        if isDemoMode {
            // Subtle live fluctuation in demo mode so gauges feel alive on TV
            let jitter = Double.random(in: -2.5...2.5)
            metrics.cpuUsage = min(99, max(8, (metrics.cpuUsage + jitter).rounded()))
            metrics.gpuUsage = min(99, max(15, ((metrics.gpuUsage ?? 75) + Double.random(in: -3...3)).rounded()))
            metrics.fps = min(165, max(90, ((metrics.fps ?? 138) + Double.random(in: -4...4)).rounded()))
            appendHistorySample()
            return
        }
        guard let pc = currentPC else {
            metrics.isOnline = false
            statusBanner = "Pair your PC with a 6-digit PIN in the My PCs tab"
            return
        }
        let start = Date()
        do {
            let apiClient = try client(for: pc)
            let fetched: TVPCMetrics = try await apiClient.get("/api/status")
            metrics = fetched
            pingMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
            statusBanner = "Connected to \(pc.name) · \(pc.address) · \(pingMs) ms"
            appendHistorySample()
            if !hasSyncedExtras {
                hasSyncedExtras = true
                await refreshGames()
                await refreshAudioMixer()
                await refreshProcesses()
            }
        } catch {
            metrics.isOnline = false
            pingMs = 0
            statusBanner = (error as? OrbitError)?.message ?? "\(pc.name) is offline · Press Power On to send Wake-on-LAN"
        }
    }

    private func appendHistorySample() {
        cpuHistory.append(metrics.cpuUsage)
        if cpuHistory.count > 24 { cpuHistory.removeFirst() }
        gpuHistory.append(metrics.gpuUsage ?? 0)
        if gpuHistory.count > 24 { gpuHistory.removeFirst() }
        fpsHistory.append(metrics.fps ?? 0)
        if fpsHistory.count > 24 { fpsHistory.removeFirst() }

        if let ct = metrics.cpuTemp, ct > peakCPUTemp { peakCPUTemp = ct }
        if let gt = metrics.gpuTemp, gt > peakGPUTemp { peakGPUTemp = gt }
        if let f = metrics.fps, f > peakFPS { peakFPS = f }
        let watts = (metrics.cpuPowerWatts ?? 0) + (metrics.gpuPowerWatts ?? 0)
        if watts > peakPowerWatts { peakPowerWatts = watts }
    }

    // MARK: - Power, Wake-on-LAN & Desktop Actions

    func wakePC() async {
        guard !isWaking else { return }
        isWaking = true
        defer { isWaking = false }

        if isDemoMode {
            metrics.isOnline = true
            statusBanner = "Preview Mode · Wake-on-LAN Magic Packet simulated"
            return
        }
        guard let pc = currentPC else {
            statusBanner = "Pair your PC first to save its MAC address for Wake-on-LAN."
            return
        }
        let cleaned = pc.macAddress.filter { !":-. ".contains($0) }
        guard cleaned.count == 12 else {
            statusBanner = "Connect to \(pc.name) once while it is on to save its MAC address."
            return
        }
        let chars = Array(cleaned)
        var mac: [UInt8] = []
        for i in stride(from: 0, to: 12, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return }
            mac.append(b)
        }
        let packet = Array(repeating: UInt8(255), count: 6) + Array(repeating: mac, count: 16).flatMap { $0 }
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }
        var enabled: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let targets = Set([pc.broadcastAddress, pc.lastKnownIPv4, pc.address, "255.255.255.255"]).filter { !$0.isEmpty }
        var sent = false
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(max(1, min(65535, pc.wolPort))).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            for _ in 0..<3 {
                let count = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(sock, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || (count == packet.count)
            }
        }
        statusBanner = sent ? "Wake-on-LAN Magic Packet sent to \(pc.name) · waiting for PC to boot…" : "Could not send Wake packet"
    }

    func sendAction(_ action: String) async {
        let label = action.replacingOccurrences(of: "_", with: " ").capitalized
        if isDemoMode {
            if ["shutdown", "sleep", "restart"].contains(action) {
                metrics.isOnline = false
            } else if action == "mute" {
                metrics.isMuted.toggle()
            } else if action == "kill_game" {
                metrics.activeGame = nil
                metrics.fps = nil
            }
            statusBanner = "Preview Command Sent · \(label)"
            return
        }
        do {
            let apiClient = try client()
            _ = try await apiClient.data("/api/action/\(action)", method: "POST")
            statusBanner = "Executed \(label) on \(currentPC?.name ?? "PC")"
            if ["shutdown", "sleep", "restart"].contains(action) {
                metrics.isOnline = false
                stopScreenStream()
            } else if action == "mute" {
                metrics.isMuted.toggle()
            }
        } catch {
            statusBanner = "Action failed: \(error.localizedDescription)"
        }
    }

    func adjustMasterVolume(by delta: Double) async {
        let target = min(100, max(0, (metrics.volume + delta).rounded()))
        metrics.volume = target
        if isDemoMode {
            statusBanner = "Master Volume · \(Int(target))%"
            return
        }
        do {
            let apiClient = try client()
            _ = try await apiClient.data("/api/volume", method: "POST", query: [URLQueryItem(name: "level", value: "\(Int(target))")])
            statusBanner = "Master Volume · \(Int(target))%"
        } catch {
            statusBanner = "Volume change failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sunshine Games & Live Desktop Stream on Apple TV

    func refreshGames() async {
        guard !isDemoMode, metrics.isOnline else { return }
        if let apiClient = try? client(),
           let fetched: [TVSunshineGame] = try? await apiClient.get("/api/sunshine/apps") {
            games = fetched
        }
    }

    func launchGame(_ game: TVSunshineGame) async {
        if isDemoMode {
            metrics.activeGame = game.title
            metrics.fps = 120
            statusBanner = "Preview · Launched \(game.title)"
            return
        }
        if !metrics.isOnline {
            await wakePC()
        }
        do {
            let apiClient = try client()
            _ = try await apiClient.data("/api/sunshine/launch", method: "POST", query: [URLQueryItem(name: "app", value: game.title)])
            statusBanner = "Launched \(game.title) on \(currentPC?.name ?? "PC")"
            startScreenStream()
        } catch {
            statusBanner = "Could not launch \(game.title): \(error.localizedDescription)"
        }
    }

    func toggleScreenStream() {
        if isStreamingScreen {
            stopScreenStream()
        } else {
            startScreenStream()
        }
    }

    func startScreenStream() {
        stopScreenStream()
        if isDemoMode {
            isStreamingScreen = true
            streamStatus = "Preview Stream Active · Connect a real PC to stream its live desktop at 720p/20fps"
            return
        }
        guard metrics.isOnline else {
            streamStatus = "Connect to your PC first to start the live desktop monitor."
            return
        }
        do {
            let apiClient = try client()
            streamClient = apiClient
            let ws = try apiClient.webSocket()
            streamWebSocket = ws
            ws.resume()
            isStreamingScreen = true
            streamStatus = "Streaming live desktop from \(currentPC?.name ?? "PC")…"
            streamTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let msg = try await ws.receive()
                        guard !Task.isCancelled else { break }
                        if case .data(let data) = msg, let image = UIImage(data: data) {
                            self?.liveFrameImage = image
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.isStreamingScreen = false
                        self?.streamStatus = "Desktop stream ended."
                    }
                }
            }
        } catch {
            streamStatus = error.localizedDescription
        }
    }

    func stopScreenStream() {
        streamTask?.cancel()
        streamTask = nil
        streamWebSocket?.cancel(with: .goingAway, reason: nil)
        streamWebSocket = nil
        streamClient = nil
        liveFrameImage = nil
        isStreamingScreen = false
        streamStatus = "Stream paused"
    }

    // MARK: - Audio Mixer on Apple TV

    func refreshAudioMixer() async {
        if isDemoMode { return }
        guard metrics.isOnline, let apiClient = try? client() else { return }
        if let reply: TVAudioSessionsReply = try? await apiClient.get("/api/audio/sessions"), reply.available {
            audioSessions = reply.sessions
        }
        if let outputsReply: TVAudioOutputsReply = try? await apiClient.get("/api/audio/outputs") {
            audioOutputs = outputsReply.devices
            audioRoutingAvailable = outputsReply.routingAvailable
        }
    }

    func adjustAppVolume(_ session: TVAudioSession, by delta: Double) async {
        guard let idx = audioSessions.firstIndex(where: { $0.id == session.id }) else { return }
        let newVol = min(100, max(0, (audioSessions[idx].volume + delta).rounded()))
        audioSessions[idx].volume = newVol
        if isDemoMode { return }
        if let apiClient = try? client() {
            let body = TVAudioSessionChange(id: session.id, volume: newVol, isMuted: nil)
            let _: TVAudioSessionReply? = try? await apiClient.send("/api/audio/session", body: body)
        }
    }

    func toggleAppMute(_ session: TVAudioSession) async {
        guard let idx = audioSessions.firstIndex(where: { $0.id == session.id }) else { return }
        audioSessions[idx].isMuted.toggle()
        let muted = audioSessions[idx].isMuted
        if isDemoMode { return }
        if let apiClient = try? client() {
            let body = TVAudioSessionChange(id: session.id, volume: nil, isMuted: muted)
            let _: TVAudioSessionReply? = try? await apiClient.send("/api/audio/session", body: body)
        }
    }

    func routeAppAudio(_ session: TVAudioSession, to deviceID: String) async {
        if isDemoMode {
            if let idx = audioSessions.firstIndex(where: { $0.id == session.id }),
               let dev = audioOutputs.first(where: { $0.id == deviceID }) {
                audioSessions[idx].outputDeviceID = dev.id
                audioSessions[idx].outputDeviceName = dev.name
            }
            return
        }
        guard let created = session.processCreateTime, let apiClient = try? client() else { return }
        let body = TVAudioRouteChange(id: session.id, expectedCreateTime: created, deviceID: deviceID)
        let _: TVAudioRouteReply? = try? await apiClient.send("/api/audio/route", body: body)
        await refreshAudioMixer()
    }

    // MARK: - Task Manager on Apple TV

    func refreshProcesses() async {
        if isDemoMode { return }
        guard metrics.isOnline, !isLoadingProcesses else { return }
        isLoadingProcesses = true
        defer { isLoadingProcesses = false }
        if let apiClient = try? client(),
           let reply: TVProcessListReply = try? await apiClient.get("/api/processes") {
            processes = reply.processes
        }
    }

    func terminateProcess(_ process: TVProcessItem) async {
        if isDemoMode {
            processes.removeAll { $0.id == process.id }
            processStatusMessage = "Terminated \(process.name) (Preview)"
            return
        }
        do {
            let apiClient = try client()
            _ = try await apiClient.data(
                "/api/processes/\(process.pid)/terminate",
                method: "POST",
                query: [URLQueryItem(name: "expectedCreateTime", value: String(process.createTime))]
            )
            processStatusMessage = "Sent End Task to \(process.name)"
            await refreshProcesses()
        } catch {
            processStatusMessage = "Could not end \(process.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Bonjour Discovery & 6-Digit PIN Pairing

    func startDiscovery() {
        discoveredPCs = []
        isScanningNetwork = true
        browser?.cancel()

        let params = NWParameters()
        params.includePeerToPeer = true
        let nwBrowser = NWBrowser(for: .bonjour(type: "_orbit._tcp", domain: nil), using: params)
        browser = nwBrowser

        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                self.resolveEndpoint(result.endpoint)
            }
        }
        nwBrowser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isScanningNetwork = false
    }

    nonisolated private func resolveEndpoint(_ endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let inner = conn.currentPath?.remoteEndpoint,
               case .hostPort(let host, _) = inner {
                let rawHost = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                conn.cancel()
                Task { @MainActor in
                    await self?.probeHost(rawHost, port: 8765)
                }
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: .global())
    }

    func probeManualHost(_ hostInput: String, discoveryPort: Int = 8765) async {
        let clean = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isScanningNetwork = true
        defer { isScanningNetwork = false }
        await probeHost(clean, port: discoveryPort)
    }

    private func probeHost(_ host: String, port: Int) async {
        guard let url = URL(string: "http://\(host):\(port)/api/discover") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["service"] as? String == "orbit-agent",
              let fp = json["fingerprint"] as? String,
              OrbitAPIClient.validFingerprint(fp) else { return }

        let item = TVDiscoveredPC(
            name: (json["name"] as? String) ?? host,
            host: host,
            discoveryPort: port,
            securePort: (json["securePort"] as? Int) ?? 8766,
            fingerprint: fp,
            agentVersion: (json["agentVersion"] as? String) ?? "4.2.0"
        )
        if !discoveredPCs.contains(where: { $0.id == item.id }) {
            discoveredPCs.append(item)
        }
    }

    func beginPINPairing(with target: TVDiscoveredPC) async {
        pairingErrorMessage = nil
        pairingPIN = ""
        isPairingInProgress = true
        defer { isPairingInProgress = false }
        do {
            let handshake = try OrbitPairingHandshake(host: target.host, port: target.securePort, fingerprint: target.fingerprint)
            _ = try await handshake.begin(name: "Apple TV · Orbit")
            activeHandshake = handshake
            activePairingTarget = target
        } catch {
            pairingErrorMessage = error.localizedDescription
        }
    }

    func finishPINPairing() async {
        guard let handshake = activeHandshake, let target = activePairingTarget else { return }
        isPairingInProgress = true
        pairingErrorMessage = nil
        defer { isPairingInProgress = false }
        do {
            let creds = try await handshake.finish(pin: pairingPIN.trimmingCharacters(in: .whitespacesAndNewlines))
            var profile = savedPCs.first(where: { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == OrbitAPIClient.normalizedFingerprint(creds.certificateFingerprint) })
                ?? TVSavedPC(name: creds.hostname, address: target.host)
            profile.name = creds.hostname
            profile.address = target.host
            profile.agentPort = creds.agentPort
            profile.securePort = creds.securePort
            profile.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(creds.certificateFingerprint)
            profile.macAddress = creds.macAddress
            profile.subnetMask = creds.subnetMask
            profile.broadcastAddress = creds.broadcastAddress
            profile.lastKnownIPv4 = creds.ipAddress

            saveToken(creds.apiToken, for: profile.id)
            if let idx = savedPCs.firstIndex(where: { $0.id == profile.id }) {
                savedPCs[idx] = profile
            } else {
                savedPCs.append(profile)
            }
            persistSavedPCs()
            activeHandshake = nil
            activePairingTarget = nil
            pairingPIN = ""
            selectPC(profile)
            selectedTab = 0
        } catch {
            pairingErrorMessage = error.localizedDescription
        }
    }

    func selectPC(_ profile: TVSavedPC) {
        selectedPCID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "tv.selectedPCID")
        hasSyncedExtras = false
        setDemoMode(false)
    }

    func deletePC(_ profile: TVSavedPC) {
        savedPCs.removeAll { $0.id == profile.id }
        persistSavedPCs()
        if selectedPCID == profile.id {
            selectedPCID = savedPCs.first?.id ?? ""
            UserDefaults.standard.set(selectedPCID, forKey: "tv.selectedPCID")
        }
    }

    // MARK: - Keychain & Profile Storage

    private func loadSavedPCs() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedPCsKey),
              let decoded = try? JSONDecoder().decode([TVSavedPC].self, from: data) else { return }
        savedPCs = decoded
        if selectedPCID.isEmpty, let first = savedPCs.first {
            selectedPCID = first.id
        }
    }

    private func persistSavedPCs() {
        if let data = try? JSONEncoder().encode(savedPCs) {
            UserDefaults.standard.set(data, forKey: Self.savedPCsKey)
        }
    }

    private func saveToken(_ token: String, for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "OrbitTVSavedPC",
            kSecAttrAccount as String: id
        ]
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func readToken(for id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "OrbitTVSavedPC",
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
