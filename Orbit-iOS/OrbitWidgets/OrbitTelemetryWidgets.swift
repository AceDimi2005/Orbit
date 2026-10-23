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
    func formatted(_ metric: OrbitWidgetMetric) -> String {
        guard let value = value(metric) else { return "—" }
        switch metric {
        case .cpuUsage, .gpuUsage, .ramUsage, .vramUsage, .gpuFan: return "\(Int(value.rounded()))%"
        case .vramUsed: return String(format: "%.1f GB", value)
        case .cpuPower, .gpuPower: return "\(Int(value.rounded())) W"
        case .cpuTemperature, .gpuTemperature, .coolantTemperature: return "\(Int(value.rounded()))°"
        case .cpuClock: return String(format: "%.2f GHz", value / 1000)
        case .cpuFan: return "\(Int(value.rounded())) RPM"
        case .diskRead, .diskWrite, .networkDownload, .networkUpload:
            if value >= 1 { return String(format: "%.1f MB/s", value) }
            if value >= 0.001 { return String(format: "%.1f KB/s", value * 1000) }
            return "\(Int((value * 1_000_000).rounded())) B/s"
        case .fps: return "\(Int(value.rounded()))"
        }
    }
}

private struct OrbitPCWidgetEntry: TimelineEntry {
    var date: Date
    var pc: OrbitWidgetPC?
    var metric: OrbitWidgetMetric = .cpuUsage
    var theme: OrbitWidgetTheme = .noir
    var monochrome: Bool = false
    var snapshot: OrbitWidgetSnapshot?
    var message: String?
    var isExpired = false

    var hasReadings: Bool { snapshot != nil && !isExpired && message == nil }
    var name: String { snapshot?.pcName ?? pc?.name ?? "Your PC" }
    var measuredAt: Date? { snapshot?.measuredAt }

    func formatted(_ metric: OrbitWidgetMetric) -> String {
        hasReadings ? snapshot?.formatted(metric) ?? "—" : "—"
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
            return min(max(raw / 400.0, 0.04), 1)
        case .fps:
            return min(max(raw / 165.0, 0.05), 1)
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
        case .invalidResponse: "Update your Orbit PC agent"
        case .unavailable: "PC unavailable · open Orbit"
        }
    }
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
    static func timeline(for entry: OrbitPCWidgetEntry) -> Timeline<OrbitPCWidgetEntry> {
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        var entries = [entry]
        if entry.hasReadings, let sampledAt = entry.measuredAt {
            let expiresAt = sampledAt.addingTimeInterval(15 * 60)
            if expiresAt > entry.date {
                var expired = entry
                expired.date = expiresAt
                expired.isExpired = true
                expired.message = "Snapshot expired · open Orbit"
                entries.append(expired)
            }
        }
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    /// A reading the app cached within the last two minutes is shown as-is: it is what the
    /// user just saw in Orbit, and it spares the widget a network round trip that iOS may
    /// not even allow right now.
    private static func cachedEntry(connection: OrbitWidgetConnection, pc: OrbitWidgetPC?, metric: OrbitWidgetMetric, theme: OrbitWidgetTheme, monochrome: Bool, now: Date) -> OrbitPCWidgetEntry? {
        guard let data = OrbitWidgetConnectionStore.cachedSnapshot(for: connection.id, maxAge: 120),
              let snapshot = try? JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data),
              snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt,
              now.timeIntervalSince(measured) <= 120, measured.timeIntervalSince(now) <= 60 else { return nil }
        return OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, monochrome: monochrome, snapshot: snapshot)
    }

    static func load(pc: OrbitWidgetPC?, metric: OrbitWidgetMetric, theme: OrbitWidgetTheme, monochrome: Bool) async -> OrbitPCWidgetEntry {
        let now = Date()
        do {
            let connection: OrbitWidgetConnection?
            if let pc {
                connection = OrbitWidgetConnectionStore.connections().first { $0.id == pc.id }
            } else {
                connection = OrbitWidgetConnectionStore.defaultConnection()
            }
            guard let connection else { throw OrbitWidgetRequestError.address }
            if let cached = cachedEntry(connection: connection, pc: pc, metric: metric, theme: theme, monochrome: monochrome, now: now) {
                return cached
            }
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
            let snapshot = try JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data)
            if snapshot.telemetryAvailable == true { OrbitWidgetConnectionStore.cacheSnapshot(data, for: connection.id, reloadInterval: .infinity) }
            guard snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt else {
                return OrbitPCWidgetEntry(
                    date: now, pc: pc, metric: metric, theme: theme, monochrome: monochrome,
                    snapshot: snapshot, message: "Waiting for PC telemetry"
                )
            }
            let expired = now.timeIntervalSince(measured) > 15 * 60 || measured.timeIntervalSince(now) > 60
            return OrbitPCWidgetEntry(
                date: now, pc: pc, metric: metric, theme: theme, monochrome: monochrome,
                snapshot: snapshot,
                message: expired ? "Snapshot expired · open Orbit" : nil,
                isExpired: expired
            )
        } catch {
            let problem = error as? OrbitWidgetRequestError ?? .unavailable
            return OrbitPCWidgetEntry(
                date: now, pc: pc, metric: metric, theme: theme, monochrome: monochrome,
                message: problem.message
            )
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
        Entry(date: Date(), message: "Pair your PC in Orbit")
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return Entry(date: Date(), pc: configuration.pc, theme: configuration.theme, monochrome: configuration.monochrome, message: "Pair your PC in Orbit")
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
        Entry(date: Date(), message: "Pair your PC in Orbit")
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return Entry(date: Date(), pc: configuration.pc, metric: configuration.metric, theme: configuration.theme, monochrome: configuration.monochrome, message: "Pair your PC in Orbit")
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

    var symbol: String {
        switch self {
        case .overview: "desktopcomputer"
        case .gaming: "gamecontroller.fill"
        case .power: "bolt.fill"
        case .thermal: "thermometer.medium"
        case .cooling: "fanblades.fill"
        case .storage: "internaldrive.fill"
        case .network: "arrow.up.arrow.down"
        case .metric: "waveform.path.ecg"
        }
    }

    func metrics(_ selected: OrbitWidgetMetric) -> [OrbitWidgetMetric] {
        switch self {
        case .overview: [.cpuUsage, .gpuUsage, .ramUsage, .vramUsage]
        case .gaming: [.fps, .vramUsed, .gpuUsage, .gpuTemperature]
        case .power: [.cpuPower, .gpuPower]
        case .thermal: [.cpuTemperature, .gpuTemperature, .coolantTemperature]
        case .cooling: [.cpuFan, .gpuFan, .coolantTemperature]
        case .storage: [.diskRead, .diskWrite]
        case .network: [.networkDownload, .networkUpload]
        case .metric: [selected]
        }
    }
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

private struct OrbitTelemetryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OrbitPCWidgetEntry
    var kind: OrbitTelemetryWidgetKind

    private var accent: Color { entry.theme.accent }
    private var metrics: [OrbitWidgetMetric] { kind.metrics(entry.metric) }

    var body: some View {
        Group {
            if family == .accessoryCircular {
                circular
            } else if family == .accessoryRectangular {
                rectangular
            } else {
                panel
            }
        }
        .widgetURL(URL(string: "orbit://dashboard"))
        .containerBackground(entry.theme.isFlat ? AnyShapeStyle(entry.theme.background) : AnyShapeStyle(entry.theme.background.gradient), for: .widget)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            headerBar
            if let message = entry.message {
                unavailable(message)
            } else {
                readings
            }
            Spacer(minLength: 0)
            footer
        }
        .foregroundStyle(.white)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .metric ? entry.metric.symbol : kind.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
            Text(kind == .metric ? entry.metric.title : kind.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 4)
            if family != .systemSmall {
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.hasReadings ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(entry.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.07), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var readings: some View {
        if kind == .metric {
            singleMetricContent
        } else if family == .systemMedium {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(metrics, id: \.self) { metric in
                        metricTile(metric, prominent: true, showBar: true)
                    }
                }
                if kind == .gaming, let game = entry.snapshot?.gameName {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles.tv")
                            .font(.system(size: 9))
                            .foregroundStyle(accent)
                        Text(game)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }
        } else if family == .systemLarge {
            largePanelContent
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(metrics, id: \.self) { metric in
                    metricReading(metric, prominent: false, showBar: true)
                }
            }
        }
    }

    @ViewBuilder
    private var singleMetricContent: some View {
        let color = entry.monochrome || entry.theme.isFlat ? accent : entry.metric.color
        VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 6) {
            Text(entry.formatted(entry.metric))
                .font(.system(size: family == .systemSmall ? 34 : (family == .systemLarge ? 48 : 40), weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(color)

            if let progress = entry.normalizedProgress(entry.metric) {
                progressBar(value: progress, color: color, height: family == .systemLarge ? 7 : 5)
            }

            if entry.metric == .fps {
                Text(entry.snapshot?.gameName ?? "No active game detected")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            } else if entry.snapshot?.value(entry.metric) == nil {
                Text("Sensor unavailable")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            if family == .systemLarge {
                Divider().overlay(.white.opacity(0.1))
                Text("System Context")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    metricTile(.cpuUsage, prominent: true, showBar: true)
                    metricTile(.gpuUsage, prominent: true, showBar: true)
                    metricTile(.cpuTemperature, prominent: true, showBar: false)
                    metricTile(.gpuTemperature, prominent: true, showBar: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var largePanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let game = entry.snapshot?.gameName, !game.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                    Text(game)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if entry.snapshot?.fps != nil {
                        Text("\(entry.formatted(.fps)) FPS")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(metrics, id: \.self) { metric in
                    metricTile(metric, prominent: true, showBar: true)
                }
            }

            let secondaryMetrics: [OrbitWidgetMetric] = kind == .gaming
                ? [.cpuUsage, .cpuTemperature, .gpuPower, .ramUsage]
                : [.cpuTemperature, .gpuTemperature, .cpuPower, .gpuPower]

            HStack(spacing: 8) {
                ForEach(secondaryMetrics, id: \.self) { metric in
                    metricTile(metric, prominent: false, showBar: false)
                }
            }

            HStack(spacing: 8) {
                metricTile(.networkDownload, prominent: false, showBar: false)
                metricTile(.diskRead, prominent: false, showBar: false)
            }
        }
    }

    private func metricTile(_ metric: OrbitWidgetMetric, prominent: Bool, showBar: Bool) -> some View {
        let color = entry.monochrome || entry.theme.isFlat ? accent : metric.color
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color.opacity(0.9))
                Text(metric.shortTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Text(entry.formatted(metric))
                .font(.system(size: prominent ? 21 : 16, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if showBar {
                progressBar(value: entry.normalizedProgress(metric) ?? 0, color: color, height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, prominent ? 8 : 7)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func metricReading(_ metric: OrbitWidgetMetric, prominent: Bool, showBar: Bool) -> some View {
        let color = entry.monochrome || entry.theme.isFlat ? accent : metric.color
        return VStack(alignment: .leading, spacing: 3) {
            Text(metric.shortTitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Text(entry.formatted(metric))
                .font(.system(size: prominent ? 22 : 19, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if showBar, let progress = entry.normalizedProgress(metric) {
                progressBar(value: progress, color: color, height: 3.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressBar(value: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.isExpired ? "clock.badge.exclamationmark" : "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.headline).foregroundStyle(accent)
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
            }
            if family == .systemMedium || family == .systemLarge || family == .systemSmall {
                HStack(spacing: 6) {
                    OrbitProPowerButton(intent: OrbitWidgetWakePCIntent(pcID: entry.pc?.id)) {
                        Label("Power On", systemImage: "power")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.22), in: Capsule())
                            .foregroundStyle(Color(red: 0.45, green: 0.96, blue: 0.68))
                    }
                    .buttonStyle(.plain)
                    if family != .systemSmall {
                        OrbitProPowerButton(intent: OrbitWidgetShutdownPCIntent(pcID: entry.pc?.id)) {
                            Label("Shut Down", systemImage: "power.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.red.opacity(0.20), in: Capsule())
                                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let feedback = OrbitWidgetConnectionStore.recentPowerFeedback() {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
                Text(feedback)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            } else if let measured = entry.measuredAt {
                Image(systemName: "clock").font(.system(size: 8))
                Text(measured, style: .time).font(.system(size: 9, weight: .medium))
            } else {
                Text(entry.name).font(.system(size: 9, weight: .medium))
            }
            Spacer(minLength: 4)
            if family == .systemMedium || family == .systemLarge {
                OrbitProPowerButton(intent: OrbitWidgetWakePCIntent(pcID: entry.pc?.id)) {
                    HStack(spacing: 3) {
                        Image(systemName: "power")
                        Text("On")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color(red: 0.45, green: 0.96, blue: 0.68))
                }
                .buttonStyle(.plain)

                OrbitProPowerButton(intent: OrbitWidgetShutdownPCIntent(pcID: entry.pc?.id)) {
                    HStack(spacing: 3) {
                        Image(systemName: "power.circle.fill")
                        Text("Off")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)
    }

    @ViewBuilder
    private var circular: some View {
        if let progress = entry.normalizedProgress(entry.metric) {
            Gauge(value: progress) {
                Image(systemName: entry.metric.symbol)
                    .font(.system(size: 10))
            } currentValueLabel: {
                Text(entry.formatted(entry.metric))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
            }
            .gaugeStyle(.accessoryCircular)
            .accessibilityLabel("\(entry.metric.title): \(entry.formatted(entry.metric))")
        } else {
            VStack(spacing: 2) {
                Image(systemName: entry.metric.symbol).font(.system(size: 11))
                Text(entry.formatted(entry.metric))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .accessibilityLabel("\(entry.metric.title): \(entry.formatted(entry.metric))")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: entry.metric.symbol)
                    .font(.caption2.weight(.bold))
                Text(entry.metric.shortTitle)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Text(entry.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.formatted(entry.metric))
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
            if let progress = entry.normalizedProgress(entry.metric) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if let measured = entry.measuredAt, entry.message == nil {
                Text(measured, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.message ?? "Open Orbit")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
