import Foundation

// Standalone Foundation contract check, including on Linux. Network methods fail
// deliberately: pinned TLS and SwiftUI still need the Apple SDK test suite.
final class OrbitAPIClient: @unchecked Sendable {
    func withTimeout(_ seconds: TimeInterval) throws -> OrbitAPIClient { self }
    func get<T: Decodable>(_ path: String) async throws -> T { throw OrbitError(message: "No network in this check") }
    func send<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T { throw OrbitError(message: "No network in this check") }
    func data(_ path: String, method: String) async throws -> Data { throw OrbitError(message: "No network in this check") }
}

@main
struct OrbitLinuxDisplayChecks {
    static func main() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let states = try JSONDecoder().decode([String: OrbitStreamDisplayStatus].self, from: fixture)
        let phone = OrbitDisplaySize(width: 2556, height: 1178)
        let fill = states["fill"]!
        precondition(fill.isLinux && fill.driverUsable && !fill.offersInstallCommand)
        precondition(fill.fillsScreen(size: phone, refreshRate: 60))
        precondition(fill.fillChecks(size: phone, refreshRate: 60).allSatisfy { $0.state == .done })
        precondition(fill.hdrSupported == false && fill.hdrReason?.contains("SDR") == true)
        precondition(fill.secondScreenBlocker == nil)
        let second = states["second"]!
        precondition(second.secondScreen.active && second.secondScreen.position == "left")
        precondition(second.secondScreen.size == OrbitDisplaySize(width: 1920, height: 1080))
        let restored = states["restored"]!
        precondition(!restored.fill.enabled && !restored.secondScreen.active && !restored.savedConfig.available)
        let unsupported = states["unsupported"]!
        precondition(!unsupported.driverUsable && !unsupported.offersInstallCommand)
        precondition(unsupported.driverBlocker == unsupported.reason)
        let older = try JSONDecoder().decode(OrbitStreamDisplayStatus.self, from: Data("{}".utf8))
        precondition(!older.isLinux && older.hdrSupported == nil)
        print("PASS: Linux display API fixtures decode into the production Swift model; Fill Screen, Second Screen, HDR notice, restoration and unsupported desktop checks")
    }
}
