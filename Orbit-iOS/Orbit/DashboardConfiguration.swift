import Foundation

enum DashboardMetric: String, CaseIterable, Identifiable, Codable {
    case cpuLoad, gpuLoad, memory, storage, vram, cpuPower, gpuPower
    case cpuTemperature, gpuTemperature, coolantTemperature, cpuClock
    case network, diskActivity, uptime, fps, cpuFan, gpuFan

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuLoad: return "Processor"
        case .gpuLoad: return "Graphics"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .vram: return "Video memory"
        case .cpuPower: return "CPU power"
        case .gpuPower: return "GPU power"
        case .cpuTemperature: return "CPU temperature"
        case .gpuTemperature: return "GPU temperature"
        case .coolantTemperature: return "Coolant"
        case .cpuClock: return "CPU clock"
        case .network: return "Network traffic"
        case .diskActivity: return "Disk activity"
        case .uptime: return "Uptime"
        case .fps: return "Game frame rate"
        case .cpuFan: return "CPU fan"
        case .gpuFan: return "GPU fan"
        }
    }
    var symbol: String {
        switch self {
        case .cpuLoad, .cpuClock: return "cpu"
        case .gpuLoad: return "square.stack.3d.up"
        case .memory, .vram: return "memorychip"
        case .storage, .diskActivity: return "internaldrive"
        case .cpuPower, .gpuPower: return "bolt.fill"
        case .cpuTemperature, .gpuTemperature: return "thermometer.medium"
        case .coolantTemperature: return "drop.fill"
        case .network: return "arrow.up.arrow.down"
        case .uptime: return "clock"
        case .fps: return "gamecontroller"
        case .cpuFan, .gpuFan: return "fanblades"
        }
    }
}

enum LiveActivityFocus: String, CaseIterable, Codable, Identifiable {
    case overview, gaming, power
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Stable raw-value storage tolerates newer, removed, or reordered card types.
struct DashboardConfiguration: Equatable, Codable {
    var metricOrder: [DashboardMetric]
    var visibleMetrics: [DashboardMetric]
    var columnCount: Int
    var showsGame: Bool
    var showsVolume: Bool
    var showsQuickControls: Bool
    var showsSpecifications: Bool
    var showsConnectionStatus: Bool
    var activityFocus: LiveActivityFocus

    var orderedVisibleMetrics: [DashboardMetric] {
        metricOrder.filter { visibleMetrics.contains($0) }
    }

    static var balanced: Self {
        Self(visibleMetrics: [.cpuLoad, .gpuLoad, .memory, .storage, .vram, .gpuPower])
    }
    static var gaming: Self {
        Self(metricOrder: [.fps, .gpuLoad, .vram, .cpuLoad, .gpuPower, .cpuPower, .gpuTemperature, .cpuTemperature],
             visibleMetrics: [.fps, .gpuLoad, .vram, .cpuLoad, .gpuPower, .cpuPower, .gpuTemperature, .cpuTemperature],
             activityFocus: .gaming)
    }
    static var workstation: Self {
        Self(metricOrder: [.cpuLoad, .memory, .cpuClock, .cpuPower, .network, .diskActivity, .storage, .uptime],
             visibleMetrics: [.cpuLoad, .memory, .cpuClock, .cpuPower, .network, .diskActivity, .storage, .uptime])
    }
    static var cooling: Self {
        Self(metricOrder: [.cpuTemperature, .gpuTemperature, .coolantTemperature, .cpuFan, .gpuFan, .cpuPower, .gpuPower],
             visibleMetrics: [.cpuTemperature, .gpuTemperature, .coolantTemperature, .cpuFan, .gpuFan, .cpuPower, .gpuPower],
             activityFocus: .power)
    }
    static var allMetrics: Self { Self(visibleMetrics: DashboardMetric.allCases) }

    init(metricOrder: [DashboardMetric] = DashboardMetric.allCases,
         visibleMetrics: [DashboardMetric] = [.cpuLoad, .gpuLoad, .memory, .storage, .vram, .gpuPower],
         columnCount: Int = 2, showsGame: Bool = true, showsVolume: Bool = true,
         showsQuickControls: Bool = true, showsSpecifications: Bool = true,
         showsConnectionStatus: Bool = true, activityFocus: LiveActivityFocus = .overview) {
        self.metricOrder = metricOrder
        self.visibleMetrics = visibleMetrics
        self.columnCount = columnCount
        self.showsGame = showsGame
        self.showsVolume = showsVolume
        self.showsQuickControls = showsQuickControls
        self.showsSpecifications = showsSpecifications
        self.showsConnectionStatus = showsConnectionStatus
        self.activityFocus = activityFocus
        normalize()
    }

    mutating func setVisible(_ metric: DashboardMetric, _ visible: Bool) {
        visibleMetrics.removeAll { $0 == metric }
        if visible { visibleMetrics.append(metric) }
    }

    mutating func normalize() {
        var seen = Set<DashboardMetric>()
        metricOrder = (metricOrder + DashboardMetric.allCases).filter { seen.insert($0).inserted }
        seen.removeAll()
        visibleMetrics = visibleMetrics.filter { seen.insert($0).inserted }
        columnCount = columnCount == 1 ? 1 : 2
    }

    private enum CodingKeys: String, CodingKey {
        case metricOrder, visibleMetrics, columnCount, showsGame, showsVolume, showsQuickControls
        case showsSpecifications, showsConnectionStatus, activityFocus
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.balanced
        metricOrder = try c.decodeIfPresent([String].self, forKey: .metricOrder)?.compactMap(DashboardMetric.init(rawValue:)) ?? defaults.metricOrder
        visibleMetrics = try c.decodeIfPresent([String].self, forKey: .visibleMetrics)?.compactMap(DashboardMetric.init(rawValue:)) ?? defaults.visibleMetrics
        columnCount = try c.decodeIfPresent(Int.self, forKey: .columnCount) ?? 2
        showsGame = try c.decodeIfPresent(Bool.self, forKey: .showsGame) ?? true
        showsVolume = try c.decodeIfPresent(Bool.self, forKey: .showsVolume) ?? true
        showsQuickControls = try c.decodeIfPresent(Bool.self, forKey: .showsQuickControls) ?? true
        showsSpecifications = try c.decodeIfPresent(Bool.self, forKey: .showsSpecifications) ?? true
        showsConnectionStatus = try c.decodeIfPresent(Bool.self, forKey: .showsConnectionStatus) ?? true
        activityFocus = LiveActivityFocus(rawValue: try c.decodeIfPresent(String.self, forKey: .activityFocus) ?? "overview") ?? .overview
        normalize()
    }
}
