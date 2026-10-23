import Foundation

// Networking for the "Send to PC" Share Extension.
//
// Foundation only (plus `OrbitAPIClient`, `OrbitFileNames` and `OrbitError`), so
// `Tests/check_share_extension.py` can compile it on macOS and run it against the real agent.

/// A paired PC the share sheet can send to. The app fills the App Group store when it pairs or
/// saves a PC (`OrbitWidgetConnectionStore`), including the control token under the shared
/// keychain service `Orbit.WidgetControl.v1`.
struct SendToPCTarget: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: Int
    /// SHA-256 of the PC's certificate; empty when the PC was never set up for HTTPS.
    let fingerprint: String
    /// The PC's control token; nil when the app has not shared it yet.
    let token: String?
}

/// What the PC can do, learned from `GET /api/capabilities` (404 there means an older agent).
struct SendToPCReadiness: Equatable, Sendable {
    var agentVersion: String?
    var features: Set<String>
    /// False when the agent predates `/api/capabilities`.
    var reportsCapabilities: Bool
    var canOpenLinks: Bool { features.contains("openUrl") }
}

/// Progress of a "Save to PC Downloads" batch. Fractions are 0…1.
struct SendToPCUploadProgress: Sendable {
    let index: Int
    let fileFraction: Double
    let overallFraction: Double
    let bytesSent: Int64
    let bytesTotal: Int64
}

/// One file saved on the PC.
struct SendToPCSavedFile: Equatable, Sendable {
    let originalName: String
    let savedName: String
    var wasRenamed: Bool { originalName != savedName }
}

/// Thrown when a batch stops early (an error or Cancel). `saved` lists what already arrived.
struct SendToPCBatchError: Error {
    let saved: [SendToPCSavedFile]
    let failedName: String?
    let underlying: Error
    var isCancellation: Bool { underlying is CancellationError }
}

/// A request that took longer than the share sheet waits.
struct SendToPCTimeout: Error {}

/// Plain-words messages the share sheet shows.
enum SendToPCText {
    static let notPaired = "Open Orbit and pair your PC first."
    static let unreachable = "Your PC isn't reachable. Wake it from Orbit and try again."
    static let localNetworkBlocked = "Orbit isn't allowed to use your local network. Turn it on in Settings → Privacy & Security → Local Network → Orbit."
    static func needsToken(_ pc: String) -> String {
        "Open Orbit and connect to \(pc) once, so Send to PC can use it."
    }
    static func needsEncryption(_ pc: String) -> String {
        "Set up the encrypted connection for \(pc) in Orbit (My PCs), then try again."
    }
    static func tokenRejected(_ pc: String) -> String {
        "\(pc) no longer accepts this iPhone. Open Orbit and pair the PC again."
    }
    static func linksNeedUpdate(_ pc: String) -> String {
        "Opening links needs a newer Orbit Companion on \(pc). On the PC, right-click the Orbit icon in the taskbar and choose Check for updates."
    }
    static func noDownloads(_ pc: String) -> String {
        "Orbit couldn't find the Downloads folder on \(pc). Open Orbit and check Files."
    }
    static func secureConnectionFailed(_ pc: String) -> String {
        "Orbit couldn't open an encrypted connection to \(pc). Open Orbit and check the PC in My PCs."
    }
    static let textTooLong = "This text is too long for the PC clipboard. It can hold about 500,000 characters."
    static let linkTooLong = "This link is longer than 4,096 characters, so it can't be opened on the PC."
    static let notWindows = "This needs Orbit Companion running on a Windows PC."
}

/// Talks to one PC through the pinned `OrbitAPIClient` (fingerprint-checked TLS, no redirects).
struct SendToPCService: Sendable {
    /// `MAX_UPLOAD_BYTES` in the agent's `orbit_files.py`.
    static let maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// `MAX_CLIPBOARD_BYTES` in `orbit_desktop.py`: UTF-16 text plus its terminator.
    static let maxClipboardBytes = 1024 * 1024
    static let maxLinkLength = 4096

    let target: SendToPCTarget
    private let client: OrbitAPIClient

    /// Throws a plain-words `OrbitError` when the PC was never paired securely or the app has not
    /// shared its token with the extension yet.
    init(target: SendToPCTarget) throws {
        guard OrbitAPIClient.validFingerprint(target.fingerprint) else {
            throw OrbitError(message: SendToPCText.needsEncryption(target.name))
        }
        guard let token = target.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw OrbitError(message: SendToPCText.needsToken(target.name))
        }
        do {
            client = try OrbitAPIClient(host: target.host, port: target.port, token: token, fingerprint: target.fingerprint)
        } catch {
            throw OrbitError(message: SendToPCText.needsEncryption(target.name))
        }
        self.target = target
    }

    // MARK: Checks

    private struct Capabilities: Decodable {
        let agentVersion: String?
        let features: [String]?
    }

    /// Asks the PC what it supports. Also the reachability check: a sleeping PC times out here.
    func readiness(timeout: Double = 6) async throws -> SendToPCReadiness {
        try await Self.withTimeout(timeout) { [client] in
            do {
                let capabilities: Capabilities = try await client.get("/api/capabilities")
                return SendToPCReadiness(agentVersion: capabilities.agentVersion,
                                         features: Set(capabilities.features ?? []), reportsCapabilities: true)
            } catch let error as OrbitError where error.statusCode == 404 {
                // Agents before 4.4 have no /api/capabilities: no new features, everything else works.
                return SendToPCReadiness(agentVersion: nil, features: [], reportsCapabilities: false)
            }
        }
    }

    private struct FileLocation: Decodable {
        let name: String
        let path: String
    }
    private struct FileRoots: Decodable {
        let roots: [FileLocation]?
        let shortcuts: [FileLocation]?
    }

    /// The PC's Downloads folder, from the `shortcuts` of `GET /api/files/roots`.
    func downloadsFolder(timeout: Double = 12) async throws -> String {
        let roots: FileRoots = try await Self.withTimeout(timeout) { [client] in
            try await client.get("/api/files/roots")
        }
        guard let downloads = roots.shortcuts?.first(where: { $0.name.caseInsensitiveCompare("Downloads") == .orderedSame }),
              !downloads.path.isEmpty else {
            throw OrbitError(message: SendToPCText.noDownloads(target.name))
        }
        return downloads.path
    }

    // MARK: Actions

    private struct Status: Decodable { let status: String? }
    private struct OpenURLBody: Encodable { let url: String }
    private struct ClipboardBody: Encodable { let text: String }

    /// Whether `url` is a link the agent opens (http/https with a host).
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// `POST /api/open-url`: opens the link in the PC's default browser.
    func openOnPC(_ url: URL, timeout: Double = 15) async throws {
        let value = url.absoluteString
        guard value.count <= Self.maxLinkLength else { throw OrbitError(message: SendToPCText.linkTooLong) }
        do {
            let _: Status = try await Self.withTimeout(timeout) { [client] in
                try await client.send("/api/open-url", body: OpenURLBody(url: value))
            }
        } catch let error as OrbitError where error.statusCode == 404 || error.statusCode == 405 {
            throw OrbitError(message: SendToPCText.linksNeedUpdate(target.name), statusCode: error.statusCode)
        }
    }

    /// Whether `text` fits the PC clipboard (UTF-16 plus a terminator, at most 1 MB).
    static func fitsClipboard(_ text: String) -> Bool {
        text.utf16.count * 2 + 2 <= maxClipboardBytes
    }

    /// `PUT /api/clipboard`: replaces the PC clipboard with `text`.
    func copyToClipboard(_ text: String, timeout: Double = 15) async throws {
        // The PC refuses null characters; nothing visible is lost by dropping them.
        let cleaned = text.replacingOccurrences(of: "\u{0}", with: "")
        guard Self.fitsClipboard(cleaned) else { throw OrbitError(message: SendToPCText.textTooLong) }
        let _: Status = try await Self.withTimeout(timeout) { [client] in
            try await client.send("/api/clipboard", method: "PUT", body: ClipboardBody(text: cleaned))
        }
    }

    /// A file to upload: a local copy in the extension's temporary folder and its name on the PC.
    struct UploadItem: Sendable {
        let url: URL
        let name: String
        let size: Int64
    }

    /// The first file over the agent's per-file limit, if any.
    static func oversized(_ items: [UploadItem]) -> UploadItem? {
        items.first { $0.size > maxFileBytes }
    }

    /// Streams each file from disk into `directory` on the PC (`POST /api/files/upload`). A name that
    /// is already taken becomes "name (2).ext", so nothing on the PC is overwritten. Stops at the first
    /// error or when the task is cancelled, throwing `SendToPCBatchError` with what was saved.
    func save(_ items: [UploadItem], into directory: String,
              progress: @escaping @Sendable (SendToPCUploadProgress) -> Void) async throws -> [SendToPCSavedFile] {
        let total = max(1, items.reduce(Int64(0)) { $0 + max(0, $1.size) })
        var saved: [SendToPCSavedFile] = []
        var sentBefore: Int64 = 0
        for (index, item) in items.enumerated() {
            let size = max(0, item.size)
            let before = sentBefore
            // A retry after a name conflict starts the body again; progress never moves backwards.
            let peak = ProgressPeak()
            do {
                try Task.checkCancellation()
                if item.size > Self.maxFileBytes {
                    throw OrbitError(message: "\(item.name) is \(Self.format(item.size)). Orbit Companion accepts files up to 2 GB each.", statusCode: 413)
                }
                progress(SendToPCUploadProgress(index: index, fileFraction: 0, overallFraction: Double(before) / Double(total),
                                                bytesSent: before, bytesTotal: total))
                let name = try await client.uploadAvoidingConflicts(directory: directory, name: item.name, file: item.url) { fraction in
                    let clamped = peak.raise(to: min(1, max(0, fraction)))
                    let sent = before + Int64(Double(size) * clamped)
                    progress(SendToPCUploadProgress(index: index, fileFraction: clamped, overallFraction: min(1, Double(sent) / Double(total)),
                                                    bytesSent: sent, bytesTotal: total))
                }
                try Task.checkCancellation()
                saved.append(SendToPCSavedFile(originalName: item.name, savedName: name))
                sentBefore += size
            } catch {
                let reason: Error = (Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled)
                    ? CancellationError() : error
                throw SendToPCBatchError(saved: saved, failedName: item.name, underlying: reason)
            }
        }
        progress(SendToPCUploadProgress(index: max(0, items.count - 1), fileFraction: 1, overallFraction: 1, bytesSent: total, bytesTotal: total))
        return saved
    }

    // MARK: Helpers

    /// Runs `operation`, failing with `SendToPCTimeout` after `seconds` (and cancelling the request).
    static func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw SendToPCTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// Turns any error from the calls above into one sentence for the share sheet.
    static func message(for error: Error, pcName: String) -> String {
        if let batch = error as? SendToPCBatchError { return message(for: batch.underlying, pcName: pcName) }
        if error is SendToPCTimeout { return SendToPCText.unreachable }
        if let orbit = error as? OrbitError {
            switch orbit.statusCode {
            case 401?: return SendToPCText.tokenRejected(pcName)
            case 501?: return SendToPCText.notWindows
            default: return orbit.message
            }
        }
        if let url = error as? URLError {
            if mentionsLocalNetworkDenial(url as NSError) { return SendToPCText.localNetworkBlocked }
            switch url.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                 .notConnectedToInternet, .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed,
                 .callIsActive, .cannotLoadFromNetwork:
                return SendToPCText.unreachable
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired:
                return SendToPCText.secureConnectionFailed(pcName)
            case .cancelled:
                return "The transfer was cancelled."
            default:
                return "Orbit couldn't reach \(pcName). \(url.localizedDescription)"
            }
        }
        if error is CancellationError { return "The transfer was cancelled." }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "Something went wrong. Try again." : text
    }

    /// iOS reports a Local Network denial as "offline", with the reason only in the path details.
    private static func mentionsLocalNetworkDenial(_ error: NSError) -> Bool {
        let details = error.userInfo.values.map { String(describing: $0) }.joined(separator: " ").lowercased()
        return details.contains("local network prohibited") || details.contains("local network denied")
    }
}

/// The highest fraction seen so far for one file (URLSession reports progress on its own queue).
private final class ProgressPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func raise(to candidate: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        value = max(value, candidate)
        return value
    }
}
