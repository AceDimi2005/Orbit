import ActivityKit
import Foundation

/// Shared by the app and its WidgetKit extension. No shared container is needed:
/// ActivityKit delivers this small snapshot to the system-owned presentation.
struct OrbitActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var cpuUsage: Double?
        var gpuUsage: Double?
        var ramUsage: Double?
        var fps: Double?
        var gameName: String?
        var isConnected: Bool
        var lastUpdated: Date
    }

    var pcName: String
}
