import AppIntents
import Foundation
import SwiftUI
import WidgetKit
import Security
import CryptoKit

/// The PC chosen in a telemetry widget's configuration. Saved widget configurations refer to this
/// entity type by name, so it keeps its name and its identifiers (the PC profile id) instead of being
/// replaced by the shared `OrbitPCEntity` that Shortcuts actions use; renaming it would reset every
/// configured widget to the default PC. The lookups are shared with `OrbitPCEntity`.
struct OrbitWidgetPC: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Paired PC")
    static var defaultQuery = OrbitWidgetPCQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct OrbitWidgetPCQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [OrbitWidgetPC] {
        OrbitPCEntity.all().filter { identifiers.contains($0.id) }.map(OrbitWidgetPC.init)
    }
    func suggestedEntities() async throws -> [OrbitWidgetPC] {
        OrbitPCEntity.all().map(OrbitWidgetPC.init)
    }
    func defaultResult() async -> OrbitWidgetPC? {
        OrbitPCEntity.defaultPC().map(OrbitWidgetPC.init)
    }
}
extension OrbitWidgetPC {
    init(_ pc: OrbitPCEntity) { self.init(id: pc.id, name: pc.name) }
}
extension OrbitPCEntity {
    /// The same PC as a Shortcuts action parameter, for buttons in a configured widget.
    init(_ pc: OrbitWidgetPC) { self.init(id: pc.id, name: pc.name) }
}

/// Configuration intent for multi-metric panel widgets (Overview, Gaming, Power, Thermal, Cooling, Storage, Network).
/// Does not ask for a single metric because panel widgets display their full metric group automatically.
struct OrbitPanelWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Appearance & PC"
    static var description = IntentDescription("Choose a paired PC and visual theme.")
    @Parameter(title: "PC") var pc: OrbitWidgetPC?
    @Parameter(title: "Theme", default: .noir) var theme: OrbitWidgetTheme
    @Parameter(title: "Use one accent colour", default: false) var monochrome: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$pc)") { \.$theme; \.$monochrome }
    }
}

/// Configuration intent for the single-metric widget where the user picks one specific metric to watch.
struct OrbitPCWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose PC & Metric"
    static var description = IntentDescription("Choose a paired PC and the specific hardware metric to display.")
    @Parameter(title: "PC") var pc: OrbitWidgetPC?
    @Parameter(title: "Metric", default: .cpuUsage) var metric: OrbitWidgetMetric
    @Parameter(title: "Theme", default: .noir) var theme: OrbitWidgetTheme
    @Parameter(title: "Use one accent colour", default: false) var monochrome: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$pc) · \(\.$metric)") { \.$theme; \.$monochrome }
    }
}

enum OrbitWidgetTheme: String, AppEnum {
    case noir, ocean, aurora, violet, ember, graphite
    case cyberpunk, solarGold, crimson, matrix, arctic, sakura
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Theme")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .noir: "Noir", .ocean: "Ocean", .aurora: "Aurora", .violet: "Violet", .ember: "Ember", .graphite: "Graphite",
        .cyberpunk: "Cyberpunk (Pro)", .solarGold: "Solar Gold (Pro)", .crimson: "Crimson (Pro)",
        .matrix: "Matrix (Pro)", .arctic: "Arctic (Pro)", .sakura: "Sakura (Pro)"
    ]
    /// Noir uses one accent for every metric; the other themes colour metrics individually.
    var isFlat: Bool { self == .noir }
    var accent: Color {
        switch self {
        case .noir: Color(red: 0.36, green: 0.86, blue: 1.0)
        case .ocean: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .aurora: Color(red: 0.45, green: 0.92, blue: 0.73)
        case .violet: Color(red: 0.76, green: 0.66, blue: 1)
        case .ember: Color(red: 1, green: 0.70, blue: 0.43)
        case .graphite: Color(red: 0.82, green: 0.88, blue: 0.97)
        case .cyberpunk: Color(red: 1.0, green: 0.18, blue: 0.68)
        case .solarGold: Color(red: 0.98, green: 0.82, blue: 0.34)
        case .crimson: Color(red: 1.0, green: 0.32, blue: 0.38)
        case .matrix: Color(red: 0.18, green: 0.98, blue: 0.42)
        case .arctic: Color(red: 0.62, green: 0.92, blue: 1.0)
        case .sakura: Color(red: 1.0, green: 0.62, blue: 0.82)
        }
    }
    var background: Color {
        switch self {
        case .noir: .black
        case .ocean: Color(red: 0.035, green: 0.065, blue: 0.105)
        case .aurora: Color(red: 0.035, green: 0.08, blue: 0.07)
        case .violet: Color(red: 0.075, green: 0.05, blue: 0.115)
        case .ember: Color(red: 0.11, green: 0.06, blue: 0.045)
        case .graphite: Color(red: 0.065, green: 0.075, blue: 0.09)
        case .cyberpunk: Color(red: 0.07, green: 0.025, blue: 0.11)
        case .solarGold: Color(red: 0.085, green: 0.07, blue: 0.03)
        case .crimson: Color(red: 0.10, green: 0.03, blue: 0.04)
        case .matrix: Color(red: 0.02, green: 0.07, blue: 0.03)
        case .arctic: Color(red: 0.035, green: 0.075, blue: 0.12)
        case .sakura: Color(red: 0.09, green: 0.045, blue: 0.08)
        }
    }
}

enum OrbitWidgetMetric: String, AppEnum {
    case cpuUsage, gpuUsage, ramUsage, vramUsage, vramUsed, cpuPower, gpuPower
    case cpuTemperature, gpuTemperature, cpuClock, cpuFan, gpuFan, coolantTemperature
    case diskRead, diskWrite, networkDownload, networkUpload, fps

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .cpuUsage: "CPU load", .gpuUsage: "GPU load", .ramUsage: "RAM usage",
        .vramUsage: "VRAM usage", .vramUsed: "VRAM used", .cpuPower: "CPU power",
        .gpuPower: "GPU power", .cpuTemperature: "CPU temperature", .gpuTemperature: "GPU temperature",
        .cpuClock: "Reported CPU clock", .cpuFan: "CPU fan", .gpuFan: "GPU fan", .coolantTemperature: "Coolant temperature",
        .diskRead: "Disk read", .diskWrite: "Disk write", .networkDownload: "Network download",
        .networkUpload: "Network upload", .fps: "Game FPS"
    ]
    var title: String {
        switch self {
        case .cpuUsage: "CPU"
        case .gpuUsage: "GPU"
        case .ramUsage: "RAM"
        case .vramUsage, .vramUsed: "VRAM"
        case .cpuPower: "CPU power"
        case .gpuPower: "GPU power"
        case .cpuTemperature: "CPU temperature"
        case .gpuTemperature: "GPU temperature"
        case .cpuClock: "Reported clock"
        case .cpuFan: "CPU fan"
        case .gpuFan: "GPU fan"
        case .coolantTemperature: "Coolant"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .networkDownload: "Download"
        case .networkUpload: "Upload"
        case .fps: "Game FPS"
        }
    }
    var shortTitle: String {
        switch self {
        case .cpuTemperature: "CPU Temp"
        case .gpuTemperature: "GPU Temp"
        case .coolantTemperature: "Coolant"
        case .cpuPower: "CPU Power"
        case .gpuPower: "GPU Power"
        case .cpuClock: "Clock"
        case .networkDownload: "Down"
        case .networkUpload: "Up"
        default: title
        }
    }
    var symbol: String {
        switch self {
        case .cpuUsage, .cpuClock: "cpu"
        case .gpuUsage, .vramUsage, .vramUsed: "rectangle.3.group"
        case .ramUsage: "memorychip"
        case .cpuPower, .gpuPower: "bolt.fill"
        case .cpuTemperature, .gpuTemperature: "thermometer.medium"
        case .cpuFan, .gpuFan: "fanblades"
        case .coolantTemperature: "drop.fill"
        case .diskRead, .diskWrite: "internaldrive"
        case .networkDownload, .networkUpload: "arrow.up.arrow.down"
        case .fps: "gamecontroller.fill"
        }
    }
    var color: Color {
        switch self {
        case .cpuUsage, .cpuTemperature: Color(red: 0.25, green: 0.84, blue: 0.96)
        case .gpuUsage, .gpuTemperature, .vramUsage, .vramUsed: Color(red: 0.71, green: 0.58, blue: 1)
        case .cpuPower, .gpuPower, .cpuClock: Color(red: 1, green: 0.78, blue: 0.36)
        case .ramUsage, .fps, .networkDownload, .networkUpload: Color(red: 0.40, green: 0.91, blue: 0.69)
        case .cpuFan, .gpuFan, .coolantTemperature: Color(red: 0.36, green: 0.78, blue: 1)
        case .diskRead, .diskWrite: Color(red: 1, green: 0.55, blue: 0.42)
        }
    }
}

private struct OrbitWidgetSnapshot: Decodable {
    var pcName: String?
    var timestamp: Double?
    var telemetryAvailable: Bool?
    var cpuUsage: Double?
    var gpuUsage: Double?
    var ramUsage: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var vramUsed: Double?
    var vramTotal: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    var cpuClock: Double?
    var cpuFan: Double?
    var gpuFan: Double?
    var coolantTemp: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var networkDownload: Double?
    var networkUpload: Double?
    var fps: Double?
    var gameName: String?

    enum CodingKeys: String, CodingKey {
        case pcName = "pc_name", timestamp, telemetryAvailable = "telemetry_available"
        case cpuUsage = "cpu_usage", gpuUsage = "gpu_usage", ramUsage = "ram_usage"
        case cpuTemp = "cpu_temp", gpuTemp = "gpu_temp", vramUsed = "vram_used", vramTotal = "vram_total"
        case cpuPower = "cpu_power", gpuPower = "gpu_power", cpuClock = "cpu_clock"
        case cpuFan = "cpu_fan", gpuFan = "gpu_fan", coolantTemp = "coolant_temp"
        case diskRead = "disk_read", diskWrite = "disk_write"
        case networkDownload = "network_download", networkUpload = "network_upload"
        case fps, gameName = "game_name"
    }

    /// What the widget gallery and placeholders show.
    static var sample: OrbitWidgetSnapshot {
        OrbitWidgetSnapshot(
            pcName: "Gaming PC", timestamp: Date().timeIntervalSince1970, telemetryAvailable: true,
            cpuUsage: 34, gpuUsage: 71, ramUsage: 58, cpuTemp: 62, gpuTemp: 68, vramUsed: 9.4, vramTotal: 16,
            cpuPower: 78, gpuPower: 286, cpuClock: 4850, cpuFan: 1180, gpuFan: 54, coolantTemp: 33,
            diskRead: 182.4, diskWrite: 46.1, networkDownload: 38.2, networkUpload: 4.6, fps: 144, gameName: "Cyberpunk 2077"
        )
    }

    var measuredAt: Date? {
        guard let timestamp, timestamp.isFinite, timestamp > 0, timestamp < 253402300800 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    func value(_ metric: OrbitWidgetMetric) -> Double? {
        let raw: Double?
        switch metric {
        case .cpuUsage: raw = cpuUsage
        case .gpuUsage: raw = gpuUsage
        case .ramUsage: raw = ramUsage
        case .vramUsage:
            if let used = vramUsed, let total = vramTotal, total > 0 { raw = used / total * 100 } else { raw = nil }
        case .vramUsed: raw = vramUsed
        case .cpuPower: raw = cpuPower
        case .gpuPower: raw = gpuPower
        case .cpuTemperature: raw = cpuTemp
        case .gpuTemperature: raw = gpuTemp
        case .cpuClock: raw = cpuClock
        case .cpuFan: raw = cpuFan
        case .gpuFan: raw = gpuFan
        case .coolantTemperature: raw = coolantTemp
        case .diskRead: raw = diskRead
        case .diskWrite: raw = diskWrite
        case .networkDownload: raw = networkDownload
        case .networkUpload: raw = networkUpload
        case .fps: raw = fps
        }
        guard let raw, raw.isFinite, raw >= 0, raw <= 1_000_000_000 else { return nil }
        switch metric {
        case .cpuUsage, .gpuUsage, .ramUsage, .vramUsage, .gpuFan: return raw <= 100 ? raw : nil
        default: return raw
        }
    }

    /// The number and its unit, drawn in two sizes.
    func parts(_ metric: OrbitWidgetMetric) -> (value: String, unit: String) {
        guard let value = value(metric) else { return ("—", "") }
        switch metric {
        case .cpuUsage, .gpuUsage, .ramUsage, .vramUsage, .gpuFan: return ("\(Int(value.rounded()))", "%")
        case .vramUsed: return (String(format: value >= 10 ? "%.0f" : "%.1f", value), "GB")
        case .cpuPower, .gpuPower: return ("\(Int(value.rounded()))", "W")
        case .cpuTemperature, .gpuTemperature, .coolantTemperature: return ("\(Int(value.rounded()))", "°")
        case .cpuClock: return (String(format: "%.2f", value / 1000), "GHz")
        case .cpuFan: return ("\(Int(value.rounded()))", "rpm")
        case .diskRead, .diskWrite, .networkDownload, .networkUpload:
            if value >= 1 { return (String(format: value >= 100 ? "%.0f" : "%.1f", value), "MB/s") }
            if value >= 0.001 { return (String(format: "%.0f", value * 1000), "KB/s") }
            return ("\(Int((value * 1_000_000).rounded()))", "B/s")
        case .fps: return ("\(Int(value.rounded()))", "fps")
        }
    }

    func formatted(_ metric: OrbitWidgetMetric) -> String {
        let parts = parts(metric)
        guard !parts.unit.isEmpty else { return parts.value }
        return ["%", "°"].contains(parts.unit) ? parts.value + parts.unit : "\(parts.value) \(parts.unit)"
    }
}

private struct OrbitPCWidgetEntry: TimelineEntry {
    var date: Date
    var pc: OrbitWidgetPC?
    var metric: OrbitWidgetMetric = .cpuUsage
    var theme: OrbitWidgetTheme = .noir
    var monochrome: Bool = false
    var snapshot: OrbitWidgetSnapshot?
    /// Shown instead of readings when there are none at all (not paired, no access, never reached).
    var message: String?
    /// The reading is a few minutes old (or the PC didn't answer just now): the values stay on screen,
    /// dimmed, with the time they were taken.
    var isStale = false
    /// The PC didn't answer the last request.
    var isUnreachable = false

    var hasReadings: Bool { snapshot != nil && message == nil }
    var name: String { snapshot?.pcName ?? pc?.name ?? "Your PC" }
    var measuredAt: Date? { snapshot?.measuredAt }

    func formatted(_ metric: OrbitWidgetMetric) -> String {
        hasReadings ? snapshot?.formatted(metric) ?? "—" : "—"
    }

    func parts(_ metric: OrbitWidgetMetric) -> (value: String, unit: String) {
        guard hasReadings, let snapshot else { return ("—", "") }
        return snapshot.parts(metric)
    }

    func normalizedProgress(_ metric: OrbitWidgetMetric) -> Double? {
        guard hasReadings, let raw = snapshot?.value(metric) else { return nil }
        switch metric {
        case .cpuUsage, .gpuUsage, .ramUsage, .vramUsage, .gpuFan:
            return min(max(raw / 100.0, 0), 1)
        case .cpuTemperature, .gpuTemperature:
            return min(max((raw - 25.0) / 70.0, 0.05), 1)
        case .coolantTemperature:
            return min(max((raw - 20.0) / 30.0, 0.05), 1)
        case .cpuPower:
            return min(max(raw / 200.0, 0.04), 1)
        case .gpuPower:
            return min(max(raw / 450.0, 0.04), 1)
        case .fps:
            return min(max(raw / 165.0, 0.05), 1)
        case .cpuFan:
            return min(max(raw / 2500.0, 0.04), 1)
        case .cpuClock:
            return min(max(raw / 6000.0, 0.04), 1)
        case .vramUsed:
            if let total = snapshot?.vramTotal, total > 0 {
                return min(max(raw / total, 0.04), 1)
            }
            return min(max(raw / 16.0, 0.04), 1)
        default:
            return nil
        }
    }
}

private enum OrbitWidgetRequestError: Error {
    case address, token, denied, invalidResponse, unavailable

    var message: String {
        switch self {
        case .address: "Pair your PC in Orbit"
        case .token: "Open Orbit to enable widget access"
        case .denied: "Reconnect this PC in Orbit"
        case .invalidResponse: "Update Orbit on your PC"
        case .unavailable: "PC offline · open Orbit"
        }
    }

    /// Problems the user fixes in Orbit; showing old numbers would hide them.
    var needsAttention: Bool { self == .address || self == .token || self == .denied }
}

/// Never forward the read-only credential to a different address via redirects.
private final class OrbitWidgetSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let received = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard received == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum OrbitWidgetLoader {
    /// How old a reading may be before the widget dims it.
    static let freshFor: TimeInterval = 3 * 60
    /// The oldest reading still worth showing (dimmed) when the PC doesn't answer.
    static let keepFor: TimeInterval = 24 * 60 * 60

    static func timeline(for entry: OrbitPCWidgetEntry) -> Timeline<OrbitPCWidgetEntry> {
        var entries = [entry]
        // Dim the numbers by themselves once they get old, even if iOS refreshes the widget later.
        if entry.hasReadings, !entry.isStale, let measured = entry.measuredAt {
            let dimAt = measured.addingTimeInterval(freshFor)
            if dimAt > entry.date {
                var stale = entry
                stale.date = dimAt
                stale.isStale = true
                entries.append(stale)
            }
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    /// The app's own latest reading for this PC, if it is younger than `maxAge`.
    private static func cached(_ connection: OrbitWidgetConnection, maxAge: TimeInterval, now: Date) -> OrbitWidgetSnapshot? {
        guard let data = OrbitWidgetConnectionStore.cachedSnapshot(for: connection.id, maxAge: maxAge),
              let snapshot = try? JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data),
              snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt,
              now.timeIntervalSince(measured) <= maxAge, measured.timeIntervalSince(now) <= 60 else { return nil }
        return snapshot
    }

    static func load(pc: OrbitWidgetPC?, metric: OrbitWidgetMetric, theme: OrbitWidgetTheme, monochrome: Bool) async -> OrbitPCWidgetEntry {
        let now = Date()
        func entry(_ snapshot: OrbitWidgetSnapshot?, message: String? = nil, stale: Bool = false, unreachable: Bool = false) -> OrbitPCWidgetEntry {
            OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, monochrome: monochrome,
                               snapshot: snapshot, message: message, isStale: stale, isUnreachable: unreachable)
        }
        let connection: OrbitWidgetConnection?
        if let pc {
            connection = OrbitWidgetConnectionStore.connections().first { $0.id == pc.id }
        } else {
            connection = OrbitWidgetConnectionStore.defaultConnection()
        }
        guard let connection else { return entry(nil, message: OrbitWidgetRequestError.address.message) }
        // What the user just saw in Orbit: no network round trip needed (iOS may not even allow one now).
        if let fresh = cached(connection, maxAge: 120, now: now) { return entry(fresh) }
        do {
            let (snapshot, data) = try await fetch(connection)
            guard snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt else {
                if let last = cached(connection, maxAge: keepFor, now: now) { return entry(last, stale: true) }
                return entry(snapshot, message: "Waiting for the PC's sensors")
            }
            OrbitWidgetConnectionStore.cacheSnapshot(data, for: connection.id, reloadInterval: .infinity)
            let old = now.timeIntervalSince(measured) > freshFor || measured.timeIntervalSince(now) > 60
            return entry(snapshot, stale: old)
        } catch {
            let problem = error as? OrbitWidgetRequestError ?? .unavailable
            if !problem.needsAttention, let last = cached(connection, maxAge: keepFor, now: now) {
                return entry(last, stale: true, unreachable: true)
            }
            return entry(nil, message: problem.message, unreachable: problem == .unavailable)
        }
    }

    private static func fetch(_ connection: OrbitWidgetConnection) async throws -> (OrbitWidgetSnapshot, Data) {
        let url = try endpoint(connection)
        let token: String
        do { token = try OrbitWidgetConnectionStore.readOnlyToken(for: connection.id) }
        catch { throw OrbitWidgetRequestError.token }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = 6
        sessionConfiguration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: sessionConfiguration, delegate: OrbitWidgetSessionDelegate(fingerprint: connection.certificateSHA256), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OrbitWidgetRequestError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw OrbitWidgetRequestError.denied }
        guard response.statusCode == 200, data.count <= 64 * 1024 else { throw OrbitWidgetRequestError.invalidResponse }
        do {
            return (try JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data), data)
        } catch {
            throw OrbitWidgetRequestError.invalidResponse
        }
    }

    private static func endpoint(_ connection: OrbitWidgetConnection) throws -> URL {
        guard !connection.host.isEmpty, !connection.host.contains("/"), !connection.host.contains(":"),
              (1...65535).contains(connection.port) else { throw OrbitWidgetRequestError.address }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = connection.host; parts.port = connection.port
        parts.path = "/api/widget/status"
        guard let url = parts.url else { throw OrbitWidgetRequestError.address }
        return url
    }
}

private struct OrbitPanelWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = OrbitPanelWidgetIntent
    typealias Entry = OrbitPCWidgetEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .sample)
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return Entry(date: Date(), pc: configuration.pc, theme: configuration.theme, monochrome: configuration.monochrome, snapshot: .sample)
        }
        return await OrbitWidgetLoader.load(pc: configuration.pc, metric: .cpuUsage, theme: configuration.theme, monochrome: configuration.monochrome)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = await OrbitWidgetLoader.load(pc: configuration.pc, metric: .cpuUsage, theme: configuration.theme, monochrome: configuration.monochrome)
        return OrbitWidgetLoader.timeline(for: entry)
    }
}

private struct OrbitPCWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = OrbitPCWidgetIntent
    typealias Entry = OrbitPCWidgetEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .sample)
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return Entry(date: Date(), pc: configuration.pc, metric: configuration.metric, theme: configuration.theme, monochrome: configuration.monochrome, snapshot: .sample)
        }
        return await OrbitWidgetLoader.load(pc: configuration.pc, metric: configuration.metric, theme: configuration.theme, monochrome: configuration.monochrome)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = await OrbitWidgetLoader.load(pc: configuration.pc, metric: configuration.metric, theme: configuration.theme, monochrome: configuration.monochrome)
        return OrbitWidgetLoader.timeline(for: entry)
    }
}

private enum OrbitTelemetryWidgetKind {
    case overview, gaming, power, thermal, cooling, storage, network, metric

    var title: String {
        switch self {
        case .overview: "PC Overview"
        case .gaming: "Gaming"
        case .power: "Power"
        case .thermal: "Temperatures"
        case .cooling: "Cooling"
        case .storage: "Storage"
        case .network: "Network"
        case .metric: "PC Metric"
        }
    }

    func metrics(_ selected: OrbitWidgetMetric) -> [OrbitWidgetMetric] {
        switch self {
        case .overview: [.cpuUsage, .gpuUsage, .ramUsage, .vramUsage]
        case .gaming: [.fps, .gpuUsage, .vramUsed, .gpuTemperature]
        case .power: [.cpuPower, .gpuPower]
        case .thermal: [.cpuTemperature, .gpuTemperature, .coolantTemperature]
        case .cooling: [.cpuFan, .gpuFan, .coolantTemperature]
        case .storage: [.diskRead, .diskWrite]
        case .network: [.networkDownload, .networkUpload]
        case .metric: [selected]
        }
    }

    /// Readings without a natural scale (throughput) are drawn as tiles instead of rings.
    var usesRings: Bool { self != .storage && self != .network }
}

struct OrbitOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitOverview", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .overview)
        }
        .configurationDisplayName("PC Overview")
        .description("CPU, GPU, RAM, VRAM, temperatures, and power at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitGamingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitGaming", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .gaming)
        }
        .configurationDisplayName("Gaming Snapshot")
        .description("Game FPS, VRAM, GPU load, and temperatures.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitPowerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitPower", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .power)
        }
        .configurationDisplayName("CPU & GPU Power")
        .description("CPU package and GPU board power in watts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitThermalWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitThermal", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .thermal)
        }
        .configurationDisplayName("Temperatures")
        .description("CPU, GPU, and coolant temperature sensors.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitCoolingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitCooling", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .cooling)
        }
        .configurationDisplayName("PC Cooling")
        .description("CPU and GPU fan speeds plus coolant temperature.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitStorageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitStorage", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .storage)
        }
        .configurationDisplayName("Storage Activity")
        .description("Physical drive read and write throughput.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitNetworkWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitNetwork", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .network)
        }
        .configurationDisplayName("Network Activity")
        .description("Download and upload throughput across active adapters.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitMetricWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitMetric", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .metric)
        }
        .configurationDisplayName("Single PC Metric")
        .description("Pick any single metric (CPU, GPU, RAM, VRAM, FPS, Power, Temps, Fans, Disk, or Network).")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}


// MARK: - Views

private struct OrbitTelemetryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OrbitPCWidgetEntry
    var kind: OrbitTelemetryWidgetKind

    private var accent: Color { entry.theme.accent }
    private var metrics: [OrbitWidgetMetric] { kind.metrics(entry.metric) }
    private var base: Color { entry.theme == .noir ? OrbitWidgetStyle.base : entry.theme.background }

    private func tint(_ metric: OrbitWidgetMetric) -> Color {
        entry.monochrome || entry.theme.isFlat ? accent : metric.color
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: panel
            }
        }
        .widgetURL(OrbitWidgetStyle.dashboardURL)
        .containerBackground(for: .widget) {
            OrbitWidgetBackdrop(accent: accent, base: base)
        }
    }

    // MARK: Home Screen

    private var panel: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            header
            if let message = entry.message, !entry.hasReadings {
                unavailable(message)
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(entry.isStale ? 0.62 : 1)
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        OrbitWidgetHeader(title: kind == .metric ? entry.metric.title : (family == .systemSmall ? entry.name : kind.title), accent: accent) {
            freshnessBadge
        }
    }

    /// A dot and the reading's time: green while fresh, amber once old or when the PC didn't answer.
    @ViewBuilder
    private var freshnessBadge: some View {
        if entry.hasReadings, let measured = entry.measuredAt {
            HStack(spacing: 4) {
                Circle()
                    .fill(entry.isStale ? OrbitWidgetStyle.caution : OrbitWidgetStyle.live)
                    .frame(width: 5, height: 5)
                Text(measured, style: .time)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.isStale ? OrbitWidgetStyle.caution : .white.opacity(0.55))
                    .lineLimit(1)
            }
        } else if entry.isUnreachable {
            Circle().fill(OrbitWidgetStyle.danger).frame(width: 5, height: 5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall: smallContent
        case .systemLarge: largeContent
        default: mediumContent
        }
    }

    // MARK: Small

    @ViewBuilder
    private var smallContent: some View {
        switch kind {
        case .overview:
            GeometryReader { proxy in
                let diameter = max(34, min((proxy.size.width - 12) / 2, (proxy.size.height - 8) / 2, 60))
                Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        ring(.cpuUsage, diameter: diameter, labelInside: true)
                        ring(.gpuUsage, diameter: diameter, labelInside: true)
                    }
                    GridRow {
                        ring(.ramUsage, diameter: diameter, labelInside: true)
                        ring(.vramUsage, diameter: diameter, labelInside: true)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .gaming:
            VStack(alignment: .leading, spacing: 4) {
                hero(.fps, size: 34)
                Text(entry.snapshot?.gameName ?? "No game running")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(entry.snapshot?.gameName == nil ? .white.opacity(0.45) : accent)
                    .lineLimit(1)
                Spacer(minLength: 2)
                row(.gpuUsage, compact: true)
            }
        case .metric:
            VStack(alignment: .leading, spacing: 8) {
                hero(entry.metric, size: 40)
                Spacer(minLength: 0)
                bar(entry.normalizedProgress(entry.metric), tint: tint(entry.metric), height: 6)
                Text(entry.metric == .fps ? (entry.snapshot?.gameName ?? "No game running") : entry.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        case .storage, .network:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(metrics, id: \.self) { metric in
                    throughput(metric, size: 22)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 9) {
                ForEach(metrics, id: \.self) { metric in
                    row(metric, compact: false)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Medium

    @ViewBuilder
    private var mediumContent: some View {
        switch kind {
        case .gaming:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    hero(.fps, size: 40)
                    Text(entry.snapshot?.gameName ?? "No game running")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.snapshot?.gameName == nil ? .white.opacity(0.45) : accent)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    row(.gpuUsage, compact: true)
                    row(.vramUsed, compact: true)
                    row(.gpuTemperature, compact: true)
                }
                .frame(maxWidth: .infinity)
            }
        case .metric:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    hero(entry.metric, size: 44)
                    Text(entry.metric == .fps ? (entry.snapshot?.gameName ?? "No game running") : entry.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ring(entry.metric, diameter: 70, labelInside: false, showsLabel: false)
            }
        case .storage, .network:
            HStack(spacing: 10) {
                ForEach(metrics, id: \.self) { metric in
                    throughput(metric, size: 26)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        default:
            ringRow(metrics, maxDiameter: 74)
        }
    }

    /// Rings side by side, as large as the space allows.
    private func ringRow(_ items: [OrbitWidgetMetric], maxDiameter: CGFloat) -> some View {
        GeometryReader { proxy in
            let count = CGFloat(max(items.count, 1))
            let byWidth = (proxy.size.width - (count - 1) * 10) / count
            let diameter = max(34, min(maxDiameter, byWidth, proxy.size.height - 18))
            HStack(alignment: .center, spacing: 0) {
                ForEach(items, id: \.self) { metric in
                    ring(metric, diameter: diameter, labelInside: false)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: Large

    private var largeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind == .metric {
                HStack(spacing: 16) {
                    hero(entry.metric, size: 52)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ring(entry.metric, diameter: 84, labelInside: false, showsLabel: false)
                }
            } else {
                ringRow(Array(metrics.prefix(4)), maxDiameter: 64)
                    .frame(height: 84)
            }
            if let game = entry.snapshot?.gameName, !game.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(game)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.snapshot?.fps != nil {
                        let fps = entry.parts(.fps)
                        Text("\(fps.value) \(fps.unit)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(spacing: 9) {
                ForEach(largeDetails, id: \.self) { metric in
                    row(metric, compact: true)
                }
            }
            .padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var largeDetails: [OrbitWidgetMetric] {
        let candidates: [OrbitWidgetMetric] = kind == .gaming
            ? [.cpuUsage, .cpuTemperature, .gpuPower, .ramUsage, .networkDownload]
            : [.cpuTemperature, .gpuTemperature, .cpuPower, .gpuPower, .networkDownload, .diskRead]
        let hasGame = !(entry.snapshot?.gameName ?? "").isEmpty
        return Array(candidates.filter { !metrics.contains($0) }.prefix(hasGame ? 4 : 5))
    }

    // MARK: Pieces

    /// A ring with the reading inside (and the label under it, or inside for small widgets).
    private func ring(_ metric: OrbitWidgetMetric, diameter: CGFloat, labelInside: Bool, showsLabel: Bool = true) -> some View {
        let color = tint(metric)
        let parts = entry.parts(metric)
        let progress = entry.normalizedProgress(metric)
        let lineWidth = max(4, diameter * 0.1)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(max(1, 360 * progress))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.45), radius: 3)
                }
                VStack(spacing: labelInside ? 0 : -1) {
                    HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                        Text(parts.value)
                            .font(.system(size: diameter * (labelInside ? 0.27 : 0.29), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if ["%", "°"].contains(parts.unit) {
                            Text(parts.unit)
                                .font(.system(size: diameter * 0.15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    if labelInside {
                        Text(metric.ringLabel)
                            .font(.system(size: diameter * 0.15, weight: .bold))
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else if !["%", "°"].contains(parts.unit), !parts.unit.isEmpty {
                        Text(parts.unit)
                            .font(.system(size: diameter * 0.14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(lineWidth + 2)
            }
            .frame(width: diameter, height: diameter)
            if showsLabel && !labelInside {
                HStack(spacing: 3) {
                    Image(systemName: metric.symbol)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(color)
                    Text(metric.ringLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(entry.formatted(metric))")
    }

    /// The big number of a single-reading layout.
    private func hero(_ metric: OrbitWidgetMetric, size: CGFloat) -> some View {
        let parts = entry.parts(metric)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint(metric))
                .contentTransition(.numericText())
            Text(parts.unit)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(entry.formatted(metric))")
    }

    /// Icon, name, reading and a thin bar.
    private func row(_ metric: OrbitWidgetMetric, compact: Bool) -> some View {
        let color = tint(metric)
        let parts = entry.parts(metric)
        return VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            HStack(spacing: 5) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 12)
                Text(metric.shortTitle)
                    .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(parts.value)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(parts.unit)
                        .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            bar(entry.normalizedProgress(metric), tint: color, height: compact ? 3 : 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(entry.formatted(metric))")
    }

    /// Disk and network rates: arrow, big number with unit, label.
    private func throughput(_ metric: OrbitWidgetMetric, size: CGFloat) -> some View {
        let color = tint(metric)
        let parts = entry.parts(metric)
        let symbol: String = switch metric {
        case .diskRead, .networkDownload: "arrow.down.circle.fill"
        default: "arrow.up.circle.fill"
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                Text(metric.shortTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.value)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(parts.unit)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(entry.formatted(metric))")
    }

    private func bar(_ progress: Double?, tint: Color, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if let progress {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, proxy.size.width * min(max(progress, 0), 1)))
                }
            }
        }
        .frame(height: height)
    }

    /// No readings at all: what to do, and Power On when the PC is away.
    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: entry.isUnreachable ? "moon.zzz.fill" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: family == .systemSmall ? 20 : 22, weight: .semibold))
                .foregroundStyle(entry.isUnreachable ? OrbitWidgetStyle.caution : accent)
            Text(message)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if entry.isUnreachable {
                OrbitPowerPill(action: .wake, compact: true, pcID: entry.pc?.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Lock Screen

    @ViewBuilder
    private var circular: some View {
        let parts = entry.parts(entry.metric)
        if let progress = entry.normalizedProgress(entry.metric) {
            Gauge(value: progress) {
                Image(systemName: entry.metric.symbol)
            } currentValueLabel: {
                Text(parts.value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
            .accessibilityLabel("\(entry.metric.title): \(entry.formatted(entry.metric))")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: entry.metric.symbol).font(.system(size: 11, weight: .semibold))
                    Text(parts.value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("\(entry.metric.title): \(entry.formatted(entry.metric))")
        }
    }

    private var rectangular: some View {
        let parts = entry.parts(entry.metric)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.metric.symbol)
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
                Text(entry.metric.shortTitle)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                if let measured = entry.measuredAt, entry.hasReadings {
                    Text(measured, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(parts.unit)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let progress = entry.normalizedProgress(entry.metric) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .widgetAccentable()
            } else {
                Text(entry.message ?? entry.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var inline: some View {
        Text("\(entry.metric.shortTitle) \(entry.formatted(entry.metric))")
    }
}

private extension OrbitWidgetMetric {
    /// One short word for ring labels.
    var ringLabel: String {
        switch self {
        case .cpuUsage: "CPU"
        case .gpuUsage: "GPU"
        case .ramUsage: "RAM"
        case .vramUsage, .vramUsed: "VRAM"
        case .cpuPower: "CPU W"
        case .gpuPower: "GPU W"
        case .cpuTemperature: "CPU"
        case .gpuTemperature: "GPU"
        case .cpuClock: "Clock"
        case .cpuFan: "CPU fan"
        case .gpuFan: "GPU fan"
        case .coolantTemperature: "Coolant"
        case .diskRead: "Read"
        case .diskWrite: "Write"
        case .networkDownload: "Down"
        case .networkUpload: "Up"
        case .fps: "FPS"
        }
    }
}
