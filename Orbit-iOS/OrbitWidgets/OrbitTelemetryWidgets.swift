import AppIntents
import Foundation
import SwiftUI
import WidgetKit
import Security
import CryptoKit

struct OrbitWidgetPC: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Paired PC")
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
struct OrbitPCWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Your PC"
    static var description = IntentDescription("Choose a PC paired in Orbit. Secure read-only access is configured automatically.")
    @Parameter(title: "PC") var pc: OrbitWidgetPC?
    @Parameter(title: "Metric", default: .cpuUsage) var metric: OrbitWidgetMetric
    @Parameter(title: "Theme", default: .ocean) var theme: OrbitWidgetTheme
    @Parameter(title: "Use one accent colour", default: false) var monochrome: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$pc)") { \.$metric; \.$theme; \.$monochrome }
    }
}
enum OrbitWidgetTheme: String, AppEnum {
    case ocean, aurora, violet, ember, graphite
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Theme")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.ocean: "Ocean", .aurora: "Aurora", .violet: "Violet", .ember: "Ember", .graphite: "Graphite"]
    var accent: Color {
        switch self {
        case .ocean: Color(red: 0.30, green: 0.85, blue: 0.97)
        case .aurora: Color(red: 0.45, green: 0.92, blue: 0.73)
        case .violet: Color(red: 0.76, green: 0.66, blue: 1)
        case .ember: Color(red: 1, green: 0.70, blue: 0.43)
        case .graphite: Color(red: 0.82, green: 0.88, blue: 0.97)
        }
    }
    var background: Color {
        switch self {
        case .ocean: Color(red: 0.035, green: 0.065, blue: 0.105)
        case .aurora: Color(red: 0.035, green: 0.08, blue: 0.07)
        case .violet: Color(red: 0.075, green: 0.05, blue: 0.115)
        case .ember: Color(red: 0.11, green: 0.06, blue: 0.045)
        case .graphite: Color(red: 0.065, green: 0.075, blue: 0.09)
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
    var configuration: OrbitPCWidgetIntent
    var snapshot: OrbitWidgetSnapshot?
    var message: String?
    var isExpired = false

    var hasReadings: Bool { snapshot != nil && !isExpired && message == nil }
    var name: String { snapshot?.pcName ?? "Your PC" }
    var measuredAt: Date? { snapshot?.measuredAt }

    func formatted(_ metric: OrbitWidgetMetric) -> String {
        hasReadings ? snapshot?.formatted(metric) ?? "—" : "—"
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

private struct OrbitPCWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = OrbitPCWidgetIntent
    typealias Entry = OrbitPCWidgetEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), configuration: Intent(), message: "Pair your PC in Orbit")
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return Entry(date: Date(), configuration: configuration, message: "Pair your PC in Orbit")
        }
        return await load(configuration)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = await load(configuration)
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        // A separate timeline entry clears readings even if iOS delays the next fetch.
        // No network polling or continuously live readings are implied by the widget.
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

    private func load(_ configuration: Intent) async -> Entry {
        let now = Date()
        do {
            let connection: OrbitWidgetConnection?
            if let pc = configuration.pc {
                connection = OrbitWidgetConnectionStore.connections().first { $0.id == pc.id }
            } else { connection = OrbitWidgetConnectionStore.defaultConnection() }
            guard let connection else { throw OrbitWidgetRequestError.address }
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
            guard snapshot.telemetryAvailable == true, let measured = snapshot.measuredAt else {
                return Entry(date: now, configuration: configuration, snapshot: snapshot, message: "Waiting for PC telemetry")
            }
            let expired = now.timeIntervalSince(measured) > 15 * 60 || measured.timeIntervalSince(now) > 60
            return Entry(date: now, configuration: configuration, snapshot: snapshot,
                         message: expired ? "Snapshot expired · open Orbit" : nil, isExpired: expired)
        } catch {
            let problem = error as? OrbitWidgetRequestError ?? .unavailable
            return Entry(date: now, configuration: configuration, message: problem.message)
        }
    }

    private func endpoint(_ connection: OrbitWidgetConnection) throws -> URL {
        guard !connection.host.isEmpty, !connection.host.contains("/"), !connection.host.contains(":"),
              (1...65535).contains(connection.port) else { throw OrbitWidgetRequestError.address }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = connection.host; parts.port = connection.port
        parts.path = "/api/widget/status"
        guard let url = parts.url else { throw OrbitWidgetRequestError.address }
        return url
    }
}

private enum OrbitTelemetryWidgetKind {
    case overview, gaming, power, thermal, cooling, storage, network, metric

    var title: String {
        switch self {
        case .overview: "PC overview"
        case .gaming: "Gaming"
        case .power: "Power"
        case .thermal: "Temperatures"
        case .cooling: "Cooling"
        case .storage: "Storage activity"
        case .network: "Network activity"
        case .metric: "PC metric"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "desktopcomputer"
        case .gaming: "gamecontroller.fill"
        case .power: "bolt.fill"
        case .thermal: "thermometer.medium"
        case .cooling: "fanblades"
        case .storage: "internaldrive"
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
        AppIntentConfiguration(kind: "OrbitOverview", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .overview)
        }
        .configurationDisplayName("PC overview")
        .description("CPU, GPU, RAM, and VRAM at a glance. Choose a PC paired in Orbit; access is configured automatically.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OrbitGamingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitGaming", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .gaming)
        }
        .configurationDisplayName("Gaming snapshot")
        .description("Measured game FPS, VRAM, and GPU readings from your last PC snapshot. Refresh timing is managed by iOS.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitPowerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitPower", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .power)
        }
        .configurationDisplayName("CPU & GPU power")
        .description("Measured CPU package and GPU board power in watts, when your hardware exposes the sensors. This is not total PC power.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitThermalWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitThermal", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .thermal)
        }
        .configurationDisplayName("CPU & GPU temperatures")
        .description("A periodic snapshot of the processor and graphics temperature sensors. Missing readings display a dash.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitCoolingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitCooling", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .cooling)
        }
        .configurationDisplayName("PC cooling")
        .description("CPU and GPU fan speeds plus coolant temperature, when supported by your hardware sensors.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitStorageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitStorage", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .storage)
        }
        .configurationDisplayName("Storage activity")
        .description("A periodic snapshot of physical drive read and write throughput.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitNetworkWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitNetwork", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .network)
        }
        .configurationDisplayName("Network activity")
        .description("A periodic snapshot of download and upload throughput across active adapters.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OrbitMetricWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OrbitMetric", intent: OrbitPCWidgetIntent.self, provider: OrbitPCWidgetProvider()) { entry in
            OrbitTelemetryWidgetView(entry: entry, kind: .metric)
        }
        .configurationDisplayName("Choose a PC metric")
        .description("Choose load, VRAM, power, temperatures, clocks, fans, network, disk activity, or FPS. Add multiple widgets to watch different metrics or PCs.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct OrbitTelemetryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OrbitPCWidgetEntry
    var kind: OrbitTelemetryWidgetKind

    private var accent: Color { entry.configuration.theme.accent }
    private var metrics: [OrbitWidgetMetric] { kind.metrics(entry.configuration.metric) }

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
        .containerBackground(entry.configuration.theme.background.gradient, for: .widget)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack(spacing: 6) {
                Label(kind == .metric ? entry.configuration.metric.title : kind.title, systemImage: kind == .metric ? entry.configuration.metric.symbol : kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if family != .systemSmall {
                    Text(entry.name).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
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

    @ViewBuilder
    private var readings: some View {
        if kind == .metric {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.formatted(entry.configuration.metric))
                    .font(.system(size: family == .systemSmall ? 36 : 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(entry.configuration.monochrome ? accent : entry.configuration.metric.color)
                if entry.configuration.metric == .fps {
                    Text(entry.snapshot?.gameName ?? "No measured game FPS").font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else if entry.snapshot?.value(entry.configuration.metric) == nil {
                    Text("Sensor unavailable").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if family == .systemMedium {
            HStack(alignment: .top, spacing: 10) {
                ForEach(metrics, id: \.self) { metric in metricReading(metric, prominent: true) }
            }
            if kind == .gaming {
                Text(entry.snapshot?.gameName ?? "No measured game FPS")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: family == .systemLarge ? 24 : 10) {
                ForEach(metrics, id: \.self) { metric in metricReading(metric, prominent: family == .systemLarge) }
            }
            if family == .systemLarge {
                Divider().overlay(.white.opacity(0.1))
                HStack {
                    metricReading(.cpuTemperature, prominent: true)
                    metricReading(.gpuTemperature, prominent: true)
                }
                HStack {
                    metricReading(.cpuPower, prominent: true)
                    metricReading(.gpuPower, prominent: true)
                }
            }
        }
    }

    private func metricReading(_ metric: OrbitWidgetMetric, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.title.replacingOccurrences(of: " temperature", with: " temp"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Text(entry.formatted(metric))
                .font(.system(size: prominent ? 23 : 20, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.configuration.monochrome ? accent : metric.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: entry.isExpired ? "clock.badge.exclamationmark" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.title3).foregroundStyle(accent)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let measured = entry.measuredAt {
                Image(systemName: "clock").font(.system(size: 8))
                Text("Snapshot").font(.system(size: 9))
                Text(measured, style: .time).font(.system(size: 9))
            } else {
                Text("Open Orbit to set up").font(.system(size: 9))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 9))
        }
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
    }

    private var circular: some View {
        VStack(spacing: 1) {
            Image(systemName: entry.configuration.metric.symbol).font(.system(size: 12))
            Text(entry.formatted(entry.configuration.metric)).font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
        }
        .accessibilityLabel("\(entry.configuration.metric.title): \(entry.formatted(entry.configuration.metric)). Periodic snapshot. Open Orbit for live readings.")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(entry.configuration.metric.title, systemImage: entry.configuration.metric.symbol).font(.caption.weight(.semibold))
            Text(entry.formatted(entry.configuration.metric)).font(.headline).monospacedDigit()
            if let measured = entry.measuredAt, entry.message == nil {
                HStack(spacing: 3) {
                    Text("Snapshot"); Text(measured, style: .time)
                }.font(.system(size: 9))
            } else {
                Text(entry.message ?? "Pair your PC in Orbit").font(.system(size: 9)).lineLimit(1)
            }
        }
    }
}
