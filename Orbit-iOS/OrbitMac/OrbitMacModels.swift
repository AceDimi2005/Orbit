import Foundation
import SwiftUI

// MARK: - Errors

struct OrbitError: LocalizedError {
    let message: String
    /// HTTP status from the PC when the error is a reply (409 = name taken, 401 = token rejected…).
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

// MARK: - Telemetry

/// Mirrors `/api/status`. Missing sensors stay optional and are never estimated.
struct MacPCMetrics: Codable {
    var hostname: String = "Your PC"
    var agentVersion: String? = nil
    var sensorSource: String? = nil
    var sensorStatus: String? = nil
    var gpuSource: String? = nil
    var networkInterface: String? = nil
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
    var cpuPowerWatts: Double? = nil
    var cpuClockMHz: Double? = nil
    var cpuClockSource: String? = nil
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
    var volume: Double = 0
    var isMuted: Bool = false
    var hdrEnabled: Bool? = nil
    /// Agent 4.3+: true while Windows shows the sign-in or lock screen.
    var sessionLocked: Bool? = nil
    var fps: Double? = nil
    var fpsSource: String? = nil
    var fpsUnavailableReason: String? = nil
    var activeGameProcess: String? = nil
    var lastUpdated: String? = nil
    var volumeAvailable: Bool? = nil
    var telemetryAvailable: Bool? = nil

    var hasTelemetry: Bool { isOnline && telemetryAvailable != false }
    var formattedUptime: String {
        guard uptimeSeconds > 0 else { return "—" }
        let days = uptimeSeconds / 86_400
        let hours = (uptimeSeconds % 86_400) / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes)m"
    }
    var ramUsagePercent: Double? { ramTotalGB > 0 ? min(100, max(0, ramUsedGB / ramTotalGB * 100)) : nil }
    var vramUsagePercent: Double? {
        guard let used = vramUsedGB, let total = vramTotalGB, total > 0 else { return nil }
        return min(100, max(0, used / total * 100))
    }
    var ssdUsagePercent: Double? { ssdTotalTB > 0 ? min(100, max(0, ssdUsedTB / ssdTotalTB * 100)) : nil }
    var totalPowerWatts: Double? {
        guard cpuPowerWatts != nil || gpuPowerWatts != nil else { return nil }
        return (cpuPowerWatts ?? 0) + (gpuPowerWatts ?? 0)
    }

    static var demo: MacPCMetrics {
        var m = MacPCMetrics()
        m.hostname = "Example PC"
        m.agentVersion = "4.2.0 · preview"
        m.cpuName = "Example 8-core processor"
        m.gpuName = "Example graphics card"
        m.sensorSource = "Simulated preview"
        m.sensorStatus = "Simulated temperature readings"
        m.gpuSource = "Simulated preview"
        m.networkInterface = "Example Ethernet"
        m.isOnline = true
        m.telemetryAvailable = true
        m.cpuTemp = 48; m.cpuUsage = 24; m.gpuTemp = 56; m.gpuUsage = 36
        m.cpuPowerWatts = 58; m.cpuClockMHz = 4250; m.cpuClockSource = "Simulated preview"
        m.cpuFanRPM = 980; m.gpuFanPercent = 42
        m.diskReadMBps = 42.6; m.diskWriteMBps = 12.8
        m.networkUploadMBps = 0.84; m.networkDownloadMBps = 8.6
        m.gpuPowerWatts = 110; m.ramUsedGB = 12.4; m.ramTotalGB = 32
        m.vramUsedGB = 4; m.vramTotalGB = 12; m.ssdUsedTB = 0.68; m.ssdTotalTB = 1.82
        m.uptimeSeconds = 10_200; m.volume = 40; m.volumeAvailable = true
        m.activeGame = "Example game"; m.fps = 118; m.fpsSource = "Simulated preview"
        return m
    }
}

struct MacPCSpecs: Codable {
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

    static var demo: MacPCSpecs {
        MacPCSpecs(
            hostname: "Example PC",
            osName: "Windows 11 Pro", osVersion: "24H2 (26100)", architecture: "64-bit (AMD64)",
            cpu: CPU(name: "Example 8-core processor", manufacturer: "Example", physicalCores: 8, logicalCores: 16, maxClockMHz: 5050),
            motherboard: Motherboard(manufacturer: "Example", model: "Example board", biosVersion: "1.0"),
            memory: Memory(totalGB: 32, modules: [
                MemoryModule(manufacturer: "Example", partNumber: "EX-6000", capacityGB: 16, speedMHz: 6000, slot: "DIMM A2"),
                MemoryModule(manufacturer: "Example", partNumber: "EX-6000", capacityGB: 16, speedMHz: 6000, slot: "DIMM B2")
            ]),
            gpus: [GPU(name: "Example graphics card", driverVersion: "1.0", vramGB: 12)],
            disks: [Disk(name: "Example NVMe SSD", sizeGB: 1863, interfaceType: "NVMe", mediaType: "SSD")],
            volumes: [Volume(mountpoint: "C:\\", fileSystem: "NTFS", totalGB: 1862, usedGB: 680)],
            networkAdapters: [NetworkAdapter(name: "Example Ethernet", macAddress: "AA:BB:CC:11:22:33", ipv4Addresses: ["192.168.1.50"])],
            coolerName: "Example AIO", detectedAt: nil, source: "Simulated preview"
        )
    }
}

struct MacNetworkConfig: Codable {
    var hostname: String; var ipAddress: String; var subnetMask: String
    var broadcastAddress: String; var macAddress: String; var agentPort: Int
    /// The PC's Tailscale IPv4 addresses (newer agents), offered as its secondary address.
    var tailscaleAddresses: [String]? = nil
}

// MARK: - Rolling history for sparklines

enum MacMetric: String, CaseIterable, Identifiable, Codable {
    case cpuLoad, gpuLoad, memory, vram, storage, cpuPower, gpuPower
    case cpuTemperature, gpuTemperature, coolantTemperature, cpuClock
    case network, diskActivity, uptime, fps, cpuFan, gpuFan

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuLoad: "Processor"
        case .gpuLoad: "Graphics"
        case .memory: "Memory"
        case .vram: "Video memory"
        case .storage: "Storage"
        case .cpuPower: "CPU power"
        case .gpuPower: "GPU power"
        case .cpuTemperature: "CPU temperature"
        case .gpuTemperature: "GPU temperature"
        case .coolantTemperature: "Coolant"
        case .cpuClock: "CPU clock"
        case .network: "Network"
        case .diskActivity: "Disk activity"
        case .uptime: "Uptime"
        case .fps: "Frame rate"
        case .cpuFan: "CPU fan"
        case .gpuFan: "GPU fan"
        }
    }
    var symbol: String {
        switch self {
        case .cpuLoad, .cpuClock: "cpu"
        case .gpuLoad: "square.stack.3d.up"
        case .memory, .vram: "memorychip"
        case .storage, .diskActivity: "internaldrive"
        case .cpuPower, .gpuPower: "bolt.fill"
        case .cpuTemperature, .gpuTemperature: "thermometer.medium"
        case .coolantTemperature: "drop.fill"
        case .network: "arrow.up.arrow.down"
        case .uptime: "clock"
        case .fps: "gamecontroller"
        case .cpuFan, .gpuFan: "fanblades"
        }
    }
    var accent: Color {
        switch self {
        case .cpuLoad, .cpuTemperature, .cpuClock, .cpuFan: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .gpuLoad, .gpuTemperature, .gpuFan, .fps: Color(red: 0.35, green: 0.94, blue: 0.66)
        case .memory, .vram: Color(red: 0.68, green: 0.65, blue: 0.98)
        case .storage, .diskActivity, .cpuPower, .gpuPower: Color(red: 0.97, green: 0.73, blue: 0.44)
        case .coolantTemperature, .network, .uptime: Color(red: 0.48, green: 0.72, blue: 1)
        }
    }
    static let defaultDashboard: [MacMetric] = [.cpuLoad, .gpuLoad, .memory, .vram, .cpuPower, .gpuPower, .cpuTemperature, .gpuTemperature, .storage, .network, .fps]
}

/// Ring buffers behind the sparklines. Only reported readings are stored.
struct MacMetricHistory: Equatable {
    static let capacity = 60
    private(set) var series: [MacMetric: [Double]] = [:]

    func values(for metric: MacMetric) -> [Double] { series[metric] ?? [] }

    mutating func append(_ m: MacPCMetrics) {
        guard m.hasTelemetry else { return }
        push(.cpuLoad, m.cpuUsage)
        push(.gpuLoad, m.gpuUsage)
        push(.memory, m.ramTotalGB > 0 ? m.ramUsedGB : nil)
        push(.vram, m.vramUsedGB)
        push(.cpuPower, m.cpuPowerWatts)
        push(.gpuPower, m.gpuPowerWatts)
        push(.cpuTemperature, m.cpuTemp)
        push(.gpuTemperature, m.gpuTemp)
        push(.coolantTemperature, m.liquidTemp)
        push(.cpuClock, m.cpuClockMHz)
        push(.network, m.networkDownloadMBps)
        push(.diskActivity, m.diskReadMBps)
        push(.fps, (m.fps ?? 0) > 0 ? m.fps : nil)
        push(.cpuFan, m.cpuFanRPM)
        push(.gpuFan, m.gpuFanPercent)
    }

    private mutating func push(_ metric: MacMetric, _ value: Double?) {
        guard let value, value.isFinite else { series[metric] = []; return }
        var buffer = series[metric] ?? []
        buffer.append(value)
        if buffer.count > Self.capacity { buffer.removeFirst(buffer.count - Self.capacity) }
        series[metric] = buffer
    }

    mutating func reset() { series = [:] }
}

struct MacSessionPeaks: Equatable {
    var cpuTemp: Double? = nil
    var gpuTemp: Double? = nil
    var fps: Double? = nil
    var power: Double? = nil
    mutating func observe(_ m: MacPCMetrics) {
        guard m.hasTelemetry else { return }
        if let value = m.cpuTemp { cpuTemp = max(cpuTemp ?? value, value) }
        if let value = m.gpuTemp { gpuTemp = max(gpuTemp ?? value, value) }
        if let value = m.fps, value > 0 { fps = max(fps ?? value, value) }
        if let value = m.totalPowerWatts { power = max(power ?? value, value) }
    }
}

// MARK: - Processes, games, audio

struct MacProcess: Codable, Identifiable, Hashable {
    var pid: Int
    var name: String
    var createTime: Double
    var memoryMB: Double?
    var cpuPercent: Double?
    var gpuPercent: Double? = nil
    var vramMB: Double? = nil
    var sharedGpuMemoryMB: Double? = nil
    var gpuEngine: String? = nil
    var status: String
    var canTerminate: Bool
    /// Agent 4.4+: opaque ID for `GET /api/icons`; nil when the executable has no icon.
    var iconID: String? = nil
    var id: String { "\(pid):\(createTime)" }
}

struct MacProcessList: Decodable {
    var processes: [MacProcess]
    var capturedAt: Double
    var totalCount: Int
    var gpuMetricsAvailable: Bool?
    var gpuMetricsStatus: String?
    var gpuMetricsSource: String?
}

struct MacSunshineGame: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let genre: String
    let iconSymbol: String
    let accentHex: String
    var cmd: String? = nil
    var isFavorite: Bool = false
}

/// `/api/sunshine/info` (agent 4.2+): Sunshine's ports on the PC.
struct MacSunshineInfo: Codable, Equatable {
    var installed: Bool
    var running: Bool
    var httpPort: Int
    var httpsPort: Int
    var webUIPort: Int
    var name: String
    var appCount: Int
    /// Agent 4.3+: it can type pairing PINs into Sunshine (saved web UI login) and start Sunshine.
    var canSubmitPin: Bool? = nil
    var canStart: Bool? = nil
}

struct MacAudioSession: Codable, Identifiable, Hashable {
    let id: String
    let pid: Int
    let name: String
    var volume: Double
    var isMuted: Bool
    var processCreateTime: Double?
    var outputDeviceID: String?
    var outputDeviceName: String?
    /// Agent 4.4+: the name Windows' own mixer shows, whether a stream plays right now,
    /// the Task Manager group (app, background, system) and the icon.
    var displayName: String? = nil
    var isActive: Bool? = nil
    var kind: String? = nil
    var iconID: String? = nil

    var title: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }
}

struct MacAudioOutput: Codable, Identifiable, Hashable { let id: String; let name: String }
struct MacAudioOutputsReply: Decodable { let devices: [MacAudioOutput]; let routingAvailable: Bool; let routingUnavailableReason: String? }
struct MacAudioSessionsReply: Decodable { let sessions: [MacAudioSession]; let available: Bool }
struct MacAudioSessionChange: Encodable { let id: String; var volume: Double?; var isMuted: Bool? }
struct MacAudioSessionReply: Decodable { let status: String; let session: MacAudioSession }
struct MacAudioRouteChange: Encodable { let id: String; let expectedCreateTime: Double; let deviceID: String }
struct MacAudioRouteReply: Decodable { let status: String; let pid: Int; let deviceID: String }

// MARK: - Clipboard

struct MacClipboardPayload: Decodable { let text: String; let available: Bool }
struct MacClipboardWrite: Encodable { let text: String }
struct MacSimpleStatus: Decodable { let status: String }

// MARK: - Files

struct MacFileLocation: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let kind: String
    var id: String { path }
    var symbol: String {
        switch kind {
        case "external": return "externaldrive.fill"
        case "shortcut":
            let lower = name.lowercased()
            if lower.contains("desktop") { return "menubar.dock.rectangle" }
            if lower.contains("download") { return "arrow.down.circle.fill" }
            if lower.contains("document") { return "doc.text.fill" }
            if lower.contains("picture") || lower.contains("photo") { return "photo.fill" }
            if lower.contains("video") || lower.contains("movie") { return "film.fill" }
            if lower.contains("music") { return "music.note" }
            return "folder.fill"
        default: return "internaldrive.fill"
        }
    }
}

struct MacFileRoots: Decodable { let roots: [MacFileLocation]; let shortcuts: [MacFileLocation] }

struct MacFileEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let modifiedAt: String?
    let canPreview: Bool
    var id: String { path }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    var modifiedDate: Date? {
        guard let modifiedAt else { return nil }
        return Self.fractionalFormatter.date(from: modifiedAt) ?? Self.plainFormatter.date(from: modifiedAt)
    }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var sizeLabel: String {
        guard let sizeBytes else { return isDirectory ? "—" : "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return "photo.fill"
        case "mp4", "mov", "mkv", "avi", "webm": return "film.fill"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "7z", "rar", "tar", "gz": return "doc.zipper"
        case "exe", "msi", "bat", "cmd": return "app.badge"
        case "txt", "md", "log", "json", "xml", "csv", "ini", "yaml", "yml": return "doc.text.fill"
        case "py", "swift", "js", "ts", "cs", "cpp", "c", "h", "java", "rs", "go": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
    var tint: Color {
        if isDirectory { return Color(red: 0.30, green: 0.85, blue: 0.97) }
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return .pink
        case "mp4", "mov", "mkv", "avi", "webm": return .purple
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return .orange
        case "pdf": return .red
        case "zip", "7z", "rar", "tar", "gz": return .yellow
        case "exe", "msi", "bat", "cmd": return .green
        case "py", "swift", "js", "ts", "cs", "cpp", "c", "h", "java", "rs", "go": return .mint
        default: return .secondary
        }
    }
}

struct MacFilePage: Decodable {
    let path: String
    let parentPath: String?
    let entries: [MacFileEntry]
    let total: Int
    let offset: Int
    let limit: Int
    let truncated: Bool?
}

struct MacArchiveJob: Decodable {
    let id: String
    let name: String
    let status: String
    let progress: Double
    let totalBytes: Int64
    let totalEntries: Int
    let archiveBytes: Int64?
    let error: String?
}

struct MacFileResult: Decodable { let ok: Bool; let path: String? }
struct MacFileNameRequest: Encodable { let parent: String; let name: String }
struct MacFileRenameRequest: Encodable { let path: String; let name: String }
struct MacFileMoveRequest: Encodable { let path: String; let destinationDirectory: String }
struct MacFilePathRequest: Encodable { let path: String }
struct MacFileFavorite: Codable, Identifiable, Hashable { let name: String; let path: String; var id: String { path } }

enum MacFileSort: String, CaseIterable, Identifiable {
    case name, size, modified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date modified"
        }
    }
}

struct MacTransferState: Equatable {
    var title: String
    var progress: Double = 0
    var indeterminate: Bool = false
    var phase: String = "encrypted transfer"
    var bytesPerSecond: Double = 0
}

// MARK: - Session history

struct MacHistoryStatistic: Decodable, Hashable { let average: Double?; let peak: Double?; let count: Int }

struct MacHistorySession: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let gameProcess: String?
    let kind: String
    let status: String
    let startedAt: Double
    let endedAt: Double?
    let durationSeconds: Double
    let sampleCount: Int
    let statistics: [String: MacHistoryStatistic]

    var startedDate: Date { Date(timeIntervalSince1970: startedAt) }
    var isRecording: Bool { status == "recording" }
    var durationLabel: String {
        let seconds = max(0, Int(durationSeconds))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    var statusLabel: String {
        switch status {
        case "recording": "Recording"
        case "interrupted": "Interrupted"
        default: "Completed"
        }
    }
}

struct MacHistoryList: Decodable { let sessions: [MacHistorySession]; let activeSession: MacHistorySession? }

struct MacHistorySample: Decodable {
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

    func value(for metric: MacHistoryMetric) -> Double? {
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

struct MacHistoryDetail: Decodable {
    let session: MacHistorySession
    let samples: [MacHistorySample]
    let downsampled: Bool
    let sampleIntervalSeconds: Double
}

enum MacHistoryMetric: String, CaseIterable, Identifiable {
    case fps, cpuUsage, gpuUsage, cpuTemp, gpuTemp, cpuPowerWatts, gpuPowerWatts
    case ramUsedGB, vramUsedGB, networkDownloadMBps, networkUploadMBps

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fps: "Frame rate"
        case .cpuUsage: "CPU load"
        case .gpuUsage: "GPU load"
        case .cpuTemp: "CPU temperature"
        case .gpuTemp: "GPU temperature"
        case .cpuPowerWatts: "CPU power"
        case .gpuPowerWatts: "GPU power"
        case .ramUsedGB: "RAM used"
        case .vramUsedGB: "VRAM used"
        case .networkDownloadMBps: "Download"
        case .networkUploadMBps: "Upload"
        }
    }
    var unit: String {
        switch self {
        case .fps: "FPS"
        case .cpuUsage, .gpuUsage: "%"
        case .cpuTemp, .gpuTemp: "°C"
        case .cpuPowerWatts, .gpuPowerWatts: "W"
        case .ramUsedGB, .vramUsedGB: "GB"
        case .networkUploadMBps, .networkDownloadMBps: "MB/s"
        }
    }
    var color: Color {
        switch self {
        case .fps: .mint
        case .cpuUsage, .cpuTemp, .cpuPowerWatts: .cyan
        case .gpuUsage, .gpuTemp, .gpuPowerWatts: .purple
        case .ramUsedGB, .vramUsedGB: .orange
        case .networkUploadMBps, .networkDownloadMBps: .blue
        }
    }
    func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let digits = self == .networkUploadMBps || self == .networkDownloadMBps ? 3 : 1
        return value.formatted(.number.precision(.fractionLength(digits))) + " " + unit
    }
}

struct MacHistoryStartBody: Encodable { let name: String? }
struct MacHistoryEmptyBody: Encodable {}
struct MacHistoryStopResponse: Decodable { let session: MacHistorySession? }
struct MacHistoryDeleteResponse: Decodable { let deleted: Bool }

// MARK: - PCs, discovery and sync

struct MacSavedPC: Codable, Identifiable, Equatable, Hashable {
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
    var autoCalcBroadcast: Bool = true
    var lastKnownIPv4: String = ""
    var bonjourHost: String? = nil
    /// Seconds since 1970 of the last edit; newer copies win when devices sync through iCloud.
    var updatedAt: Double? = nil
    /// Extra Wake-on-LAN target (`host` or `host:port`), for example a router reachable over Tailscale.
    var wolRelay: String = ""
    /// Second address of the PC (its Tailscale IPv4 or MagicDNS name), used while `address` does not answer.
    /// Optional so PCs saved before it existed still decode. Never a Wake-on-LAN target.
    var secondaryAddress: String? = nil

    var isSecure: Bool { OrbitAPIClient.validFingerprint(certificateFingerprint) }
    var syncIdentity: String { OrbitPCCloudSync.identity(fingerprint: certificateFingerprint, id: id) }
    /// `secondaryAddress` when it is usable: a bare host different from `address`, on a pinned (encrypted) connection.
    var secondaryHost: String { isSecure ? OrbitAddressRoute.cleanedSecondary(secondaryAddress ?? "", primary: address) : "" }

    func syncedItem(token: String, selected: Bool) -> OrbitSyncedPCItem {
        OrbitSyncedPCItem(id: id, name: name, address: address, agentPort: agentPort, securePort: securePort,
                          certificateFingerprint: certificateFingerprint, macAddress: macAddress, subnetMask: subnetMask,
                          broadcastAddress: broadcastAddress, wolPort: wolPort, lastKnownIPv4: lastKnownIPv4, apiToken: token,
                          isSelected: selected, bonjourHost: bonjourHost, autoCalcBroadcast: autoCalcBroadcast, updatedAt: updatedAt, origin: "Mac",
                          wolRelay: wolRelay.isEmpty ? nil : wolRelay,
                          secondaryAddress: secondaryAddress?.isEmpty == false ? secondaryAddress : nil)
    }

    init(from item: OrbitSyncedPCItem) {
        id = item.id; name = item.name; address = item.address; agentPort = item.agentPort; securePort = item.securePort
        certificateFingerprint = item.certificateFingerprint; macAddress = item.macAddress; subnetMask = item.subnetMask
        broadcastAddress = item.broadcastAddress; wolPort = item.wolPort; autoCalcBroadcast = item.autoCalcBroadcast ?? true
        lastKnownIPv4 = item.lastKnownIPv4; bonjourHost = item.bonjourHost; updatedAt = item.updatedAt
        wolRelay = item.wolRelay ?? ""
        secondaryAddress = item.secondaryAddress?.isEmpty == false ? item.secondaryAddress : nil
    }

    init(id: String = UUID().uuidString, name: String, address: String, agentPort: Int = 8765, securePort: Int = 8766, certificateFingerprint: String = "",
         macAddress: String = "", subnetMask: String = "255.255.255.0", broadcastAddress: String = "", wolPort: Int = 9, autoCalcBroadcast: Bool = true,
         lastKnownIPv4: String = "", bonjourHost: String? = nil, updatedAt: Double? = nil) {
        self.id = id; self.name = name; self.address = address; self.agentPort = agentPort; self.securePort = securePort
        self.certificateFingerprint = certificateFingerprint; self.macAddress = macAddress; self.subnetMask = subnetMask
        self.broadcastAddress = broadcastAddress; self.wolPort = wolPort; self.autoCalcBroadcast = autoCalcBroadcast
        self.lastKnownIPv4 = lastKnownIPv4; self.bonjourHost = bonjourHost; self.updatedAt = updatedAt
    }
}

struct MacDiscoveredPC: Identifiable, Equatable, Hashable {
    var id: String { fingerprint.isEmpty ? "\(host):\(securePort)" : fingerprint }
    var name: String
    var host: String
    var discoveryPort: Int
    var securePort: Int
    var fingerprint: String
    var agentVersion: String
}

/// Payload published by the iPhone app over iCloud KVS, the App Group and `_orbit-iphone._tcp`.
/// Shared with iPhone and Apple TV through iCloud; see Shared/OrbitPCSync.swift.
typealias MacSyncedPCItem = OrbitSyncedPCItem

// MARK: - Navigation

enum MacSection: String, CaseIterable, Identifiable, Codable {
    case overview, remote, preview, files, processes, audio, clipboard, sessions, library, pcs, deck

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .remote: "Remote"
        case .preview: "Desktop Preview"
        case .files: "Files"
        case .processes: "Processes"
        case .audio: "Audio Mixer"
        case .clipboard: "Clipboard"
        case .sessions: "Sessions"
        case .library: "Stream"
        case .pcs: "My PCs"
        case .deck: "Buttons"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .remote: "computermouse.fill"
        case .preview: "display"
        case .files: "folder.fill"
        case .processes: "list.bullet.rectangle.portrait.fill"
        case .audio: "slider.vertical.3"
        case .clipboard: "doc.on.clipboard.fill"
        case .sessions: "chart.xyaxis.line"
        case .library: "play.rectangle.fill"
        case .pcs: "desktopcomputer"
        case .deck: "square.grid.2x2.fill"
        }
    }
    /// ⌘1 … ⌘0 (and ⌘B for Buttons) shortcuts in the View menu.
    var shortcutKey: Character {
        switch self {
        case .overview: "1"
        case .remote: "2"
        case .preview: "3"
        case .files: "4"
        case .processes: "5"
        case .audio: "6"
        case .clipboard: "7"
        case .sessions: "8"
        case .library: "9"
        case .pcs: "0"
        case .deck: "b"
        }
    }
    static let monitorGroup: [MacSection] = [.overview, .sessions, .processes]
    static let controlGroup: [MacSection] = [.remote, .deck, .preview, .audio, .clipboard, .files, .library]
    static let setupGroup: [MacSection] = [.pcs]
}

// MARK: - Formatting helpers shared by the Mac views

enum MacFormat {
    static func decimal(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }
    static func whole(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        let separator = unit == "°C" || unit == "%" ? "" : " "
        return "\(Int(value.rounded()))\(separator)\(unit)"
    }
    static func transferRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1 { return "\(decimal(value)) MB/s" }
        if value >= 0.001 { return "\(decimal(value * 1000, digits: 1)) KB/s" }
        return "\(decimal(value * 1_000_000, digits: 0)) B/s"
    }
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Queued by menu commands (⇧⌘S, Stream Settings…); the Stream section runs it once it is on screen.
enum MacStreamAction: Equatable {
    case desktop, settings
}

/// Where "Stream" opens a session on the Mac: inside Orbit, or in the separate Moonlight app.
enum MacStreamBackend: String, CaseIterable, Identifiable {
    case orbit, moonlight
    var id: String { rawValue }
    var title: String { self == .orbit ? "Orbit" : "Moonlight app" }
    static let storageKey = "mac.streamBackend"
}
