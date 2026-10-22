import AppIntents
import CryptoKit
import Foundation
import Security
import SwiftUI
import WidgetKit

struct OrbitWidgetPC: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "PC")
    static var defaultQuery = OrbitWidgetPCQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct OrbitWidgetPCQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [OrbitWidgetPC] {
        OrbitWidgetConnectionStore.connections().filter { identifiers.contains($0.id) }.map { OrbitWidgetPC(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [OrbitWidgetPC] {
        OrbitWidgetConnectionStore.connections().map { OrbitWidgetPC(id: $0.id, name: $0.name) }
    }
    func defaultResult() async -> OrbitWidgetPC? {
        OrbitWidgetConnectionStore.defaultConnection().map { OrbitWidgetPC(id: $0.id, name: $0.name) }
    }
}

/// The readings widgets: which PC, and the accent color.
struct OrbitPanelWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "PC and Color"
    static var description = IntentDescription("Choose the PC and the accent color.")
    @Parameter(title: "PC") var pc: OrbitWidgetPC?
    @Parameter(title: "Accent Color", default: .noir) var theme: OrbitWidgetTheme
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$pc)") { \.$theme }
    }
}

/// The Reading widget: which PC, which reading, and the accent color.
struct OrbitPCWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Reading"
    static var description = IntentDescription("Choose the PC, the reading and the accent color.")
    @Parameter(title: "PC") var pc: OrbitWidgetPC?
    @Parameter(title: "Reading", default: .cpuUsage) var metric: OrbitWidgetMetric
    @Parameter(title: "Accent Color", default: .noir) var theme: OrbitWidgetTheme
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$pc) · \(\.$metric)") { \.$theme }
    }
}

/// Accent colors for widgets. The stored names are the app's theme names.
enum OrbitWidgetTheme: String, AppEnum {
    case noir, ocean, aurora, violet, ember, graphite
    case cyberpunk, solarGold, crimson, matrix, arctic, sakura
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Accent Color")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .noir: "Orbit Blue", .ocean: "Teal", .aurora: "Mint", .violet: "Indigo", .ember: "Orange", .graphite: "Graphite",
        .cyberpunk: "Pink (Orbit Pro)", .solarGold: "Gold (Orbit Pro)", .crimson: "Red (Orbit Pro)",
        .matrix: "Green (Orbit Pro)", .arctic: "Ice (Orbit Pro)", .sakura: "Rose (Orbit Pro)"
    ]

    /// The color; Orbit Blue for an Orbit Pro color without Orbit Pro.
    var color: Color {
        if OrbitAccentPalette.proNames.contains(rawValue) && !OrbitProEntitlement.cachedIsUnlocked { return OrbitPalette.accent }
        return OrbitAccentPalette.color(rawValue)
    }
}

enum OrbitWidgetMetric: String, AppEnum {
    case cpuUsage, gpuUsage, ramUsage, vramUsage, vramUsed, cpuPower, gpuPower
    case cpuTemperature, gpuTemperature, cpuClock, cpuFan, gpuFan, coolantTemperature
    case diskRead, diskWrite, networkDownload, networkUpload, fps

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reading")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .cpuUsage: "Processor", .gpuUsage: "Graphics", .ramUsage: "Memory",
        .vramUsage: "Video memory", .vramUsed: "Video memory in GB", .cpuPower: "CPU power",
        .gpuPower: "GPU power", .cpuTemperature: "CPU temperature", .gpuTemperature: "GPU temperature",
        .cpuClock: "CPU clock", .cpuFan: "CPU fan", .gpuFan: "GPU fan", .coolantTemperature: "Coolant temperature",
        .diskRead: "Disk reading", .diskWrite: "Disk writing", .networkDownload: "Network receiving",
        .networkUpload: "Network sending", .fps: "Frame rate"
    ]

    /// The reading's name on a widget.
    var title: String {
        switch self {
        case .cpuUsage: "Processor"
        case .gpuUsage: "Graphics"
        case .ramUsage: "Memory"
        case .vramUsage, .vramUsed: "Video Memory"
        case .cpuPower: "CPU Power"
        case .gpuPower: "GPU Power"
        case .cpuTemperature: "CPU Temperature"
        case .gpuTemperature: "GPU Temperature"
        case .cpuClock: "CPU Clock"
        case .cpuFan: "CPU Fan"
        case .gpuFan: "GPU Fan"
        case .coolantTemperature: "Coolant"
        case .diskRead: "Reading"
        case .diskWrite: "Writing"
        case .networkDownload: "Receiving"
        case .networkUpload: "Sending"
        case .fps: "Frame Rate"
        }
    }

    /// A shorter name where two readings share a line.
    var shortTitle: String {
        switch self {
        case .cpuUsage, .cpuTemperature, .cpuPower, .cpuClock, .cpuFan: "CPU"
        case .gpuUsage, .gpuTemperature, .gpuPower, .gpuFan: "GPU"
        case .ramUsage: "RAM"
        case .vramUsage, .vramUsed: "VRAM"
        case .coolantTemperature: "Coolant"
        case .diskRead: "Read"
        case .diskWrite: "Write"
        case .networkDownload: "In"
        case .networkUpload: "Out"
        case .fps: "FPS"
        }
    }

    /// For the Lock Screen gauge.
    var symbol: String {
        switch self {
        case .cpuUsage, .cpuClock: "cpu"
        case .gpuUsage, .vramUsage, .vramUsed: "rectangle.3.group"
        case .ramUsage: "memorychip"
        case .cpuPower, .gpuPower: "bolt"
        case .cpuTemperature, .gpuTemperature: "thermometer.medium"
        case .cpuFan, .gpuFan: "fanblades"
        case .coolantTemperature: "drop"
        case .diskRead, .diskWrite: "internaldrive"
        case .networkDownload, .networkUpload: "arrow.up.arrow.down"
        case .fps: "gamecontroller"
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
    var snapshot: OrbitWidgetSnapshot?
    var message: String?
    var isExpired = false

    var hasReadings: Bool { snapshot != nil && !isExpired && message == nil }
    var name: String { snapshot?.pcName ?? pc?.name ?? "Your PC" }
    var measuredAt: Date? { snapshot?.measuredAt }
}

private enum OrbitWidgetRequestError: Error, CaseIterable {
    case address, token, denied, invalidResponse, unavailable

    var message: String {
        switch self {
        case .address: "Pair a PC in Orbit to see it here."
        case .token: "Open Orbit once so widgets can read your PC."
        case .denied: "Open Orbit to reconnect this PC."
        case .invalidResponse: "Update Orbit Companion on the PC."
        case .unavailable: "It may be asleep or off."
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
    static let expiredMessage = "Open Orbit to refresh it."
    static let waitingMessage = "Orbit Companion is starting its sensors."

    static func timeline(for entry: OrbitPCWidgetEntry) -> Timeline<OrbitPCWidgetEntry> {
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        var entries = [entry]
        if entry.hasReadings, let sampledAt = entry.measuredAt {
            let expiresAt = sampledAt.addingTimeInterval(15 * 60)
            if expiresAt > entry.date {
                var expired = entry
                expired.date = expiresAt
                expired.isExpired = true
                expired.message = expiredMessage
                entries.append(expired)
            }
        }
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    /// A reading the app cached within the last two minutes is shown as-is: it is what the
    /// user just saw in Orbit, and it spares the widget a network round trip that iOS may
    /// not even allow right now.
    private static func cachedEntry(connection: OrbitWidgetConnection, pc: OrbitWidgetPC?, metric: OrbitWidgetMetric, theme: OrbitWidgetTheme, now: Date) -> OrbitPCWidgetEntry? {
        guard let data = OrbitWidgetConnectionStore.cachedSnapshot(for: connection.id, maxAge: 120),
              let snapshot = try? JSONDecoder().decode(OrbitWidgetSnapshot.self, from: data),
              snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt,
              now.timeIntervalSince(measured) <= 120, measured.timeIntervalSince(now) <= 60 else { return nil }
        return OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, snapshot: snapshot)
    }

    static func load(pc: OrbitWidgetPC?, metric: OrbitWidgetMetric, theme: OrbitWidgetTheme) async -> OrbitPCWidgetEntry {
        let now = Date()
        do {
            let connection: OrbitWidgetConnection?
            if let pc {
                connection = OrbitWidgetConnectionStore.connections().first { $0.id == pc.id }
            } else {
                connection = OrbitWidgetConnectionStore.defaultConnection()
            }
            guard let connection else { throw OrbitWidgetRequestError.address }
            if let cached = cachedEntry(connection: connection, pc: pc, metric: metric, theme: theme, now: now) {
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
                return OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, snapshot: snapshot, message: waitingMessage)
            }
            let expired = now.timeIntervalSince(measured) > 15 * 60 || measured.timeIntervalSince(now) > 60
            return OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, snapshot: snapshot,
                                      message: expired ? expiredMessage : nil, isExpired: expired)
        } catch {
            let problem = error as? OrbitWidgetRequestError ?? .unavailable
            return OrbitPCWidgetEntry(date: now, pc: pc, metric: metric, theme: theme, message: problem.message)
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
            return Entry(date: Date(), pc: configuration.pc, theme: configuration.theme, snapshot: .sample)
        }
        return await OrbitWidgetLoader.load(pc: configuration.pc, metric: .cpuUsage, theme: configuration.theme)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = await OrbitWidgetLoader.load(pc: configuration.pc, metric: .cpuUsage, theme: configuration.theme)
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
            return Entry(date: Date(), pc: configuration.pc, metric: configuration.metric, theme: configuration.theme, snapshot: .sample)
        }
        return await OrbitWidgetLoader.load(pc: configuration.pc, metric: configuration.metric, theme: configuration.theme)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = await OrbitWidgetLoader.load(pc: configuration.pc, metric: configuration.metric, theme: configuration.theme)
        return OrbitWidgetLoader.timeline(for: entry)
    }
}

// MARK: - Widgets

private enum OrbitTelemetryWidgetKind {
    case overview, gaming, power, thermal, cooling, storage, network, metric

    var title: String {
        switch self {
        case .overview: "Status"
        case .gaming: "Frame Rate"
        case .power: "Power Draw"
        case .thermal: "Temperatures"
        case .cooling: "Fans"
        case .storage: "Disk Activity"
        case .network: "Network"
        case .metric: "Reading"
        }
    }

    var metrics: [OrbitWidgetMetric] {
        switch self {
        case .overview: [.cpuUsage, .gpuUsage, .ramUsage, .vramUsage]
        case .gaming: [.gpuUsage, .gpuTemperature, .vramUsed, .gpuPower, .cpuUsage, .cpuTemperature]
        case .power: [.cpuPower, .gpuPower]
        case .thermal: [.cpuTemperature, .gpuTemperature, .coolantTemperature]
        case .cooling: [.cpuFan, .gpuFan, .coolantTemperature]
        case .storage: [.diskRead, .diskWrite]
        case .network: [.networkDownload, .networkUpload]
        case .metric: []
        }
    }
}

struct OrbitOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitOverview", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .overview)
        }
        .configurationDisplayName("Status")
        .description("How your PC is doing, in one sentence, with its main readings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitGamingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitGaming", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .gaming)
        }
        .configurationDisplayName("Frame Rate")
        .description("The game that's running and how smoothly it runs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitPowerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitPower", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .power)
        }
        .configurationDisplayName("Power Draw")
        .description("The watts the processor and the graphics card use.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitThermalWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitThermal", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .thermal)
        }
        .configurationDisplayName("Temperatures")
        .description("The processor, the graphics card and the liquid loop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitCoolingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitCooling", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .cooling)
        }
        .configurationDisplayName("Fans")
        .description("Fan speeds and the liquid loop's temperature.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitStorageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitStorage", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .storage)
        }
        .configurationDisplayName("Disk Activity")
        .description("How fast the PC reads and writes its drives.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitNetworkWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitNetwork", intent: OrbitPanelWidgetIntent.self, provider: OrbitPanelWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .network)
        }
        .configurationDisplayName("Network")
        .description("What the PC receives and sends.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitMetricWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitMetric", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .metric)
        }
        .configurationDisplayName("Reading")
        .description("Any one reading, on the Home Screen or the Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Entry presentation

private extension OrbitWidgetSnapshot {
    /// Sample readings for the widget gallery and placeholders.
    static var sample: OrbitWidgetSnapshot {
        OrbitWidgetSnapshot(pcName: "Your PC", timestamp: Date().timeIntervalSince1970, telemetryAvailable: true,
                            cpuUsage: 23, gpuUsage: 71, ramUsage: 46, cpuTemp: 52, gpuTemp: 65, vramUsed: 6.2, vramTotal: 12,
                            cpuPower: 63, gpuPower: 210, cpuClock: 4850, cpuFan: 980, gpuFan: 42, coolantTemp: 31,
                            diskRead: 12.5, diskWrite: 4.5, networkDownload: 8.6, networkUpload: 0.8, fps: 144, gameName: "Example game")
    }
}

/// The widget reading as the shared readings model, so the takeaway matches the app's.
private struct OrbitWidgetTelemetry: OrbitTelemetry {
    var snapshot: OrbitWidgetSnapshot

    var isOnline: Bool { true }
    var cpuUsage: Double { snapshot.value(.cpuUsage) ?? 0 }
    var cpuTemp: Double? { snapshot.value(.cpuTemperature) }
    var gpuUsage: Double? { snapshot.value(.gpuUsage) }
    var gpuTemp: Double? { snapshot.value(.gpuTemperature) }
    var gpuPowerWatts: Double? { snapshot.value(.gpuPower) }
    var cpuPowerWatts: Double? { snapshot.value(.cpuPower) }
    var cpuClockMHz: Double? { snapshot.value(.cpuClock) }
    var liquidTemp: Double? { snapshot.value(.coolantTemperature) }
    var cpuFanRPM: Double? { snapshot.value(.cpuFan) }
    var gpuFanPercent: Double? { snapshot.value(.gpuFan) }
    var diskReadMBps: Double? { snapshot.value(.diskRead) }
    var diskWriteMBps: Double? { snapshot.value(.diskWrite) }
    var networkUploadMBps: Double? { snapshot.value(.networkUpload) }
    var networkDownloadMBps: Double? { snapshot.value(.networkDownload) }
    var vramUsedGB: Double? { snapshot.value(.vramUsed) }
    var vramTotalGB: Double? { snapshot.vramTotal }
    /// The widget carries memory as a percentage; as GB of 100 the ratio is the same.
    var ramUsedGB: Double { snapshot.value(.ramUsage) ?? 0 }
    var ramTotalGB: Double { snapshot.value(.ramUsage) == nil ? 0 : 100 }
    var ssdUsedTB: Double { 0 }
    var ssdTotalTB: Double { 0 }
    var uptimeSeconds: Int { 0 }
    var activeGame: String? { snapshot.gameName }
    var fps: Double? { snapshot.value(.fps) }
    var telemetryAvailable: Bool? { snapshot.telemetryAvailable }
    var sessionLocked: Bool? { nil }
}

private extension OrbitPCWidgetEntry {
    var accent: Color { theme.color }

    var markStatus: OrbitWidgetMark.Status {
        if hasReadings { return .online }
        return isExpired || snapshot != nil ? .paused : .offline
    }

    /// A reading as widgets draw it, or nil when the PC doesn't report it.
    func reading(_ metric: OrbitWidgetMetric) -> OrbitGlanceReading? {
        guard hasReadings, let v = snapshot?.value(metric) else { return nil }
        let id = metric.rawValue
        switch metric {
        case .cpuUsage, .gpuUsage, .ramUsage, .vramUsage:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "%", shortLabel: metric.shortTitle,
                                      fraction: v / 100, color: OrbitPalette.load(v / 100))
        case .gpuFan:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "%", shortLabel: metric.shortTitle, fraction: v / 100)
        case .vramUsed:
            let fraction = snapshot?.vramTotal.flatMap { $0 > 0 ? v / $0 : nil }
            return OrbitGlanceReading(id: id, label: metric.title, value: v.formatted(.number.precision(.fractionLength(1))), unit: "GB",
                                      shortLabel: metric.shortTitle, fraction: fraction, color: OrbitPalette.load(fraction))
        case .cpuPower, .gpuPower:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "W", shortLabel: metric.shortTitle)
        case .cpuTemperature, .gpuTemperature:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "°", shortLabel: metric.shortTitle,
                                      fraction: v / 100, color: OrbitPalette.temperature(v))
        case .coolantTemperature:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "°", shortLabel: metric.shortTitle)
        case .cpuClock:
            return OrbitGlanceReading(id: id, label: metric.title, value: (v / 1000).formatted(.number.precision(.fractionLength(2))), unit: "GHz",
                                      shortLabel: metric.shortTitle)
        case .cpuFan:
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "rpm", shortLabel: metric.shortTitle)
        case .diskRead, .diskWrite, .networkDownload, .networkUpload:
            let rate = Self.rate(v)
            return OrbitGlanceReading(id: id, label: metric.title, value: rate.0, unit: rate.1, shortLabel: metric.shortTitle)
        case .fps:
            guard v > 0 else { return nil }
            return OrbitGlanceReading(id: id, label: metric.title, value: "\(Int(v.rounded()))", unit: "fps")
        }
    }

    func readings(_ metrics: [OrbitWidgetMetric]) -> [OrbitGlanceReading] { metrics.compactMap(reading) }

    var game: String? {
        guard hasReadings, let game = snapshot?.gameName?.trimmingCharacters(in: .whitespaces), !game.isEmpty else { return nil }
        return game
    }

    /// One sentence about the PC, like the PC tab's header.
    var takeaway: String {
        guard hasReadings, let snapshot else { return problemTitle }
        let headline = OrbitTakeaway(OrbitWidgetTelemetry(snapshot: snapshot)).headline
        if headline == "In game", let game { return game }
        return headline
    }

    /// What is wrong when there are no readings, in a few words.
    var problemTitle: String {
        if isExpired { return "Not updated lately" }
        if snapshot != nil { return "Waiting for readings" }
        switch OrbitWidgetRequestError.allCases.first(where: { $0.message == message }) {
        case .address: return "No PC yet"
        case .token, .denied: return "Open Orbit"
        case .invalidResponse: return "Update needed"
        case .unavailable, nil: return "Can't reach your PC"
        }
    }

    /// Waking the PC is the one action that could fix it.
    var offersWake: Bool {
        !hasReadings && (isExpired || message == OrbitWidgetRequestError.unavailable.message)
    }

    private static func rate(_ megabytes: Double) -> (String, String) {
        if megabytes >= 1 { return (megabytes.formatted(.number.precision(.fractionLength(1))), "MB/s") }
        return ((megabytes * 1000).formatted(.number.precision(.fractionLength(0))), "KB/s")
    }
}

// MARK: - Views

private struct OrbitTelemetryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OrbitPCWidgetEntry
    var kind: OrbitTelemetryWidgetKind

    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .widgetURL(URL(string: "orbit://dashboard"))
            .containerBackground(for: .widget) { OrbitPalette.surface }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            OrbitReadingCircular(entry: entry)
        case .accessoryRectangular:
            OrbitReadingRectangular(entry: entry)
        case .accessoryInline:
            OrbitReadingInline(entry: entry)
        default:
            if !entry.hasReadings {
                OrbitWidgetProblem(entry: entry, family: family)
            } else {
                switch kind {
                case .overview: OverviewWidgetBody(entry: entry, family: family)
                case .gaming: FrameRateWidgetBody(entry: entry, family: family)
                case .power: PowerDrawWidgetBody(entry: entry, family: family)
                case .metric: ReadingWidgetBody(entry: entry, family: family)
                case .thermal, .cooling, .storage, .network:
                    PairWidgetBody(entry: entry, family: family, title: kind.title, metrics: kind.metrics)
                }
            }
        }
    }
}

/// The mark and a title along the top of a widget; the reading time on wider widgets.
private struct WidgetHeader: View {
    var entry: OrbitPCWidgetEntry
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            OrbitWidgetMark(status: entry.markStatus, size: 15, accent: entry.accent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// A label over a number, for the small widgets.
private struct WidgetLabeledReading: View {
    var reading: OrbitGlanceReading
    var size: CGFloat = 30
    var short = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(short ? (reading.shortLabel ?? reading.label) : reading.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            OrbitGlanceValue(reading: reading, size: size)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row with the label on the left, the number on the right and a meter under them.
private struct WidgetReadingBar: View {
    var reading: OrbitGlanceReading
    var accent: Color
    var valueSize: CGFloat = 20
    /// A smaller label, for the narrow column of a medium widget.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reading.label)
                    .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                OrbitGlanceValue(reading: reading, size: valueSize)
            }
            if reading.fraction != nil {
                OrbitGlanceMeter(fraction: reading.fraction, color: reading.color, accent: accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewWidgetBody: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily

    private var readings: [OrbitGlanceReading] { entry.readings([.cpuUsage, .gpuUsage, .ramUsage, .vramUsage]) }

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(entry: entry, title: entry.name)
                Spacer(minLength: 6)
                Text(entry.takeaway)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    ForEach(readings.prefix(2)) { reading in
                        WidgetLabeledReading(reading: reading, size: 22, short: true)
                    }
                }
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(entry: entry, title: entry.name, trailing: entry.measuredAt?.formatted(date: .omitted, time: .shortened))
                Text(entry.takeaway)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .padding(.top, 10)
                if let game = entry.game {
                    // The takeaway names the game while you play, so the line under it gives the frame rate.
                    let fps = entry.reading(.fps).map { "\($0.value) fps" }
                    let line = entry.takeaway == game ? fps : game
                    if let line {
                        Label(line, systemImage: "gamecontroller")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 12)
                VStack(spacing: 14) {
                    ForEach(entry.readings([.cpuUsage, .gpuUsage, .ramUsage, .vramUsage, .cpuTemperature, .gpuTemperature]).prefix(5)) { reading in
                        WidgetReadingBar(reading: reading, accent: entry.accent)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(entry: entry, title: entry.name, trailing: entry.measuredAt?.formatted(date: .omitted, time: .shortened))
                Text(entry.takeaway)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 8)
                Spacer(minLength: 8)
                OrbitGlanceReadingsRow(readings: Array(readings.prefix(3)), valueSize: 26, accent: entry.accent)
            }
        }
    }
}

private struct FrameRateWidgetBody: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily

    private var fps: OrbitGlanceReading? { entry.reading(.fps) }
    private var others: [OrbitGlanceReading] { entry.readings(OrbitTelemetryWidgetKind.gaming.metrics) }

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(entry: entry, title: "Frame Rate")
                Spacer(minLength: 4)
                frameRate(size: 46)
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(entry: entry, title: "Frame Rate", trailing: entry.name)
                Spacer(minLength: 8)
                frameRate(size: 64)
                Spacer(minLength: 16)
                VStack(spacing: 14) {
                    // The graphics card's readings; a fifth row would squeeze the numbers.
                    ForEach(others.prefix(4)) { reading in
                        WidgetReadingBar(reading: reading, accent: entry.accent)
                    }
                }
            }
        default:
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(entry: entry, title: "Frame Rate")
                    Spacer(minLength: 4)
                    frameRate(size: 48)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !others.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(others.prefix(3)) { reading in
                            WidgetReadingBar(reading: reading, accent: entry.accent, valueSize: 17, compact: true)
                        }
                    }
                    .frame(width: 164)
                }
            }
        }
    }

    @ViewBuilder
    private func frameRate(size: CGFloat) -> some View {
        if let fps {
            OrbitGlanceValue(reading: fps, size: size)
            Text(entry.game ?? entry.name)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("No game running")
                .font(.headline)
            Text("The frame rate shows up while you play.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct PowerDrawWidgetBody: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily

    private var parts: [OrbitGlanceReading] { entry.readings([.cpuPower, .gpuPower]) }

    /// The header says Power Draw, so each part goes by its name.
    private var namedParts: [OrbitGlanceReading] {
        parts.map { reading in
            var reading = reading
            reading.label = reading.id == OrbitWidgetMetric.cpuPower.rawValue ? "Processor" : "Graphics"
            return reading
        }
    }

    private var total: OrbitGlanceReading? {
        guard !parts.isEmpty else { return nil }
        let watts = [entry.snapshot?.value(.cpuPower), entry.snapshot?.value(.gpuPower)].compactMap { $0 }.reduce(0, +)
        return OrbitGlanceReading(id: "total", label: parts.count > 1 ? "Together" : parts[0].label, value: "\(Int(watts.rounded()))", unit: "W")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, title: "Power Draw", trailing: family == .systemSmall ? nil : entry.name)
            Spacer(minLength: 4)
            if let total {
                if family == .systemSmall {
                    OrbitGlanceValue(reading: total, size: 44)
                    Text(parts.map { "\($0.shortLabel ?? $0.label) \($0.value) W" }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    HStack(alignment: .bottom, spacing: 20) {
                        VStack(alignment: .leading, spacing: 0) {
                            OrbitGlanceValue(reading: total, size: 48)
                            Text(parts.count > 1 ? "In total" : total.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if parts.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(namedParts) { reading in
                                    WidgetLabeledReading(reading: reading, size: 22)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Not reported")
                    .font(.headline)
                Text("This PC doesn't report its power draw.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Two or three readings of one kind: temperatures, fans, disk or network.
private struct PairWidgetBody: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily
    var title: String
    var metrics: [OrbitWidgetMetric]

    /// The header names the group, so each reading goes by its part ("Processor", not "CPU Temperature").
    private var readings: [OrbitGlanceReading] {
        entry.readings(metrics).map { reading in
            var reading = reading
            switch OrbitWidgetMetric(rawValue: reading.id) {
            case .cpuTemperature, .cpuFan: reading.label = "Processor"
            case .gpuTemperature, .gpuFan: reading.label = "Graphics"
            default: break
            }
            return reading
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, title: title, trailing: family == .systemSmall ? nil : entry.name)
            Spacer(minLength: 6)
            if readings.isEmpty {
                Text("Not reported")
                    .font(.headline)
                Text("This PC doesn't report these readings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if family == .systemSmall {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(readings.prefix(2)) { reading in
                        WidgetLabeledReading(reading: reading, size: 28)
                    }
                }
            } else {
                OrbitGlanceReadingsRow(readings: Array(readings.prefix(3)), valueSize: 30,
                                       showsMeters: readings.filter { $0.fraction != nil }.count > 1, accent: entry.accent)
            }
        }
    }
}

/// One reading, as large as the widget allows.
private struct ReadingWidgetBody: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily

    private var reading: OrbitGlanceReading? { entry.reading(entry.metric) }

    private var context: [OrbitGlanceReading] {
        let preferred: [OrbitWidgetMetric] = [.cpuUsage, .gpuUsage, .ramUsage, .cpuTemperature, .gpuTemperature]
        return Array(entry.readings(preferred.filter { $0 != entry.metric }).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, title: entry.metric.title, trailing: family == .systemSmall ? nil : entry.name)
            Spacer(minLength: 4)
            if let reading {
                OrbitGlanceValue(reading: reading, size: family == .systemLarge ? 72 : (family == .systemSmall ? 46 : 52))
                if reading.fraction != nil {
                    OrbitGlanceMeter(fraction: reading.fraction, color: reading.color, accent: entry.accent, height: family == .systemLarge ? 6 : 4)
                        .padding(.top, 8)
                }
                if family == .systemSmall {
                    Text(entry.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 8)
                }
            } else {
                Text("Not reported")
                    .font(.headline)
                Text(entry.metric == .fps ? "The frame rate shows up while you play." : "This PC doesn't report this reading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if family == .systemLarge, !context.isEmpty {
                Spacer(minLength: 16)
                Text(entry.takeaway)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.bottom, 10)
                OrbitGlanceReadingsRow(readings: context, valueSize: 24, accent: entry.accent)
            }
        }
    }
}

/// No readings: what is wrong, and the one action that fixes it.
private struct OrbitWidgetProblem: View {
    var entry: OrbitPCWidgetEntry
    var family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, title: entry.name)
            Spacer(minLength: 6)
            Text(entry.problemTitle)
                .font(.headline)
                .lineLimit(2)
            if let message = entry.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 2 : 3)
                    .padding(.top, 2)
            }
            if entry.offersWake {
                OrbitWakeButton(pcID: entry.pc?.id, accent: entry.accent)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lock Screen

private struct OrbitReadingCircular: View {
    var entry: OrbitPCWidgetEntry

    var body: some View {
        if let reading = entry.reading(entry.metric) {
            if let fraction = reading.fraction {
                Gauge(value: min(1, max(0, fraction))) {
                    Image(systemName: entry.metric.symbol)
                } currentValueLabel: {
                    Text(reading.value + (reading.unit == "%" || reading.unit == "°" ? reading.unit ?? "" : ""))
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .accessibilityLabel("\(entry.metric.title) \(reading.value)\(reading.unit ?? "")")
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: -1) {
                        Text(reading.value)
                            .font(.system(size: 17, weight: .semibold).width(.condensed))
                            .minimumScaleFactor(0.6)
                        Text(reading.unit ?? "")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .monospacedDigit()
                }
                .accessibilityLabel("\(entry.metric.title) \(reading.value) \(reading.unit ?? "")")
            }
        } else {
            ZStack {
                AccessoryWidgetBackground()
                OrbitWidgetMark(status: entry.markStatus, size: 26)
            }
            .accessibilityLabel(entry.problemTitle)
        }
    }
}

private struct OrbitReadingRectangular: View {
    var entry: OrbitPCWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                OrbitWidgetMark(status: entry.markStatus, size: 12)
                Text(entry.metric.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let reading = entry.reading(entry.metric) {
                OrbitGlanceValue(reading: reading, size: 24)
                if let fraction = reading.fraction {
                    Gauge(value: min(1, max(0, fraction))) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                }
            } else {
                Text(entry.problemTitle)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OrbitReadingInline: View {
    var entry: OrbitPCWidgetEntry

    var body: some View {
        if let reading = entry.reading(entry.metric) {
            Label("\(entry.metric.title) \(reading.value)\(reading.unit == "%" || reading.unit == "°" ? reading.unit ?? "" : " \(reading.unit ?? "")")",
                  systemImage: entry.metric.symbol)
        } else {
            Label(entry.problemTitle, systemImage: "desktopcomputer")
        }
    }
}
