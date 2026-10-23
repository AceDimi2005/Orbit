import CryptoKit
import Foundation
import Security

/// Small pinned HTTPS client for Shortcuts actions (and later widget buttons and controls) that
/// talk to a paired PC outside the app's own connection.
///
/// Modelled on `OrbitWidgetPowerService`: an ephemeral session per call, the PC's certificate
/// pinned by SHA-256 (then checked as the only trust anchor), redirects refused, and the shared
/// control token from the App Group keychain (`Orbit.WidgetControl.v1`), so it works in the app,
/// in Siri and in the widget extension. Every failure is an `OrbitIntentError` with one sentence.
/// Compiled into Orbit and OrbitWidgets.
struct OrbitIntentClient: Sendable {
    let pcID: String
    let pcName: String
    private let host: String
    private let port: Int
    private let fingerprint: String
    private let token: String
    private let timeout: TimeInterval

    /// Picks the PC (`nil` = the default PC) and its credentials. Throws when Orbit is in Demo Mode,
    /// no PC is paired, the shortcut names a removed PC, or the app never shared control access.
    static func resolve(_ pc: OrbitPCEntity?, timeout: TimeInterval = 8) throws -> OrbitIntentClient {
        if isDemoMode { throw OrbitIntentError.demo }
        let connection: OrbitWidgetConnection
        if let pc {
            guard let match = OrbitWidgetConnectionStore.connections().first(where: { $0.id == pc.id }) else {
                throw OrbitIntentError.removedPC
            }
            connection = match
        } else {
            guard let fallback = OrbitWidgetConnectionStore.defaultConnection() else { throw OrbitIntentError.noPC }
            connection = fallback
        }
        let name = connection.name.isEmpty ? "Your PC" : connection.name
        let fingerprint = connection.certificateSHA256.lowercased()
        guard !connection.host.isEmpty, (1...65535).contains(connection.port),
              fingerprint.count == 64, fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let token = try? OrbitWidgetConnectionStore.controlToken(for: connection.id), !token.isEmpty,
              !token.contains(where: { $0.isNewline }) else {
            throw OrbitIntentError.needsSetup(name)
        }
        return OrbitIntentClient(pcID: connection.id, pcName: name, host: connection.host, port: connection.port,
                                 fingerprint: fingerprint, token: token, timeout: timeout)
    }

    // MARK: Requests

    /// Sends one request and returns the body of a 2xx reply.
    @discardableResult
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard path.hasPrefix("/api/") else { throw OrbitIntentError("Orbit tried an invalid PC request.") }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = port
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = query
            // URLComponents leaves "+" alone, but the agent reads it as a space ("C++" would arrive as "C  ").
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else {
            throw OrbitIntentError("\(pcName)'s saved address isn't valid. Pair the PC again in Orbit.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let delegate = PinnedDelegate(fingerprint: fingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let reply: (Data, URLResponse)
        do {
            reply = try await session.data(for: request)
        } catch {
            throw transportError(error, pinFailed: delegate.pinFailed)
        }
        guard let http = reply.1 as? HTTPURLResponse else { throw OrbitIntentError.unexpectedReply(pcName) }
        guard (200..<300).contains(http.statusCode) else {
            throw OrbitIntentError.reply(status: http.statusCode, detail: OrbitIntentError.detail(from: reply.0), pc: pcName)
        }
        guard reply.0.count <= 4 * 1024 * 1024 else { throw OrbitIntentError.unexpectedReply(pcName) }
        return reply.0
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(type, from: await data("GET", path, query: query))
    }

    @discardableResult
    func send<Body: Encodable>(_ method: String, _ path: String, json: Body) async throws -> Data {
        let body: Data
        do { body = try JSONEncoder().encode(json) } catch { throw OrbitIntentError("Orbit couldn't prepare this request.") }
        return try await data(method, path, body: body)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw OrbitIntentError.unexpectedReply(pcName) }
    }

    /// Feature strings from `GET /api/capabilities`; empty for an older agent (404).
    func features() async throws -> Set<String> {
        do {
            return Set(try await get(OrbitAgentCapabilities.self, "/api/capabilities").features)
        } catch let error as OrbitIntentError where error.kind == .olderCompanion {
            return []
        }
    }

    /// Throws "needs a newer Orbit Companion" unless the PC lists `feature`.
    func require(feature: String) async throws {
        guard try await features().contains(feature) else { throw OrbitIntentError.olderCompanion(pcName) }
    }

    private func transportError(_ error: Error, pinFailed: Bool) -> Error {
        if pinFailed { return OrbitIntentError.certificateChanged(pcName) }
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else { return OrbitIntentError.unreachable(pcName) }
        switch urlError.code {
        case .cancelled:
            return Task.isCancelled ? CancellationError() : OrbitIntentError.unreachable(pcName)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return OrbitIntentError.secureConnectionFailed(pcName)
        default:
            // iOS reports a denied Local Network permission as an unsatisfied network path.
            let path = (urlError.userInfo["_NSURLErrorNWPathKey"] as? NSObject)?.description ?? ""
            if path.localizedCaseInsensitiveContains("local network prohibited") {
                return OrbitIntentError.localNetworkDenied(pcName)
            }
            return OrbitIntentError.unreachable(pcName)
        }
    }

    private final class PinnedDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private let fingerprint: String
        private let lock = NSLock()
        private var failed = false

        init(fingerprint: String) { self.fingerprint = fingerprint }

        var pinFailed: Bool { lock.withLock { failed } }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                lock.withLock { failed = true }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let received = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
            guard received == fingerprint,
                  SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                lock.withLock { failed = true }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: Demo Mode

    /// App Group mirror of the app's `demoMode` setting, so actions running in the widget extension
    /// know about Demo Mode too. The app writes it through `startMirroringDemoMode()`.
    static let demoModeKey = "Orbit.DemoMode.v1"
    private static let appDemoModeKey = "demoMode"

    private static var groupDefaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "OrbitAppGroupIdentifier") as? String,
              group.hasPrefix("group."), !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }

    private static var isAppProcess: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// The app itself reads its own setting; extensions read the mirror.
    static var isDemoMode: Bool {
        if isAppProcess { return UserDefaults.standard.bool(forKey: appDemoModeKey) }
        return groupDefaults?.bool(forKey: demoModeKey) ?? false
    }

    /// Called once at app launch: copies `demoMode` into the App Group now and whenever it changes.
    static func startMirroringDemoMode() {
        mirrorDemoMode()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil) { _ in
            mirrorDemoMode()
        }
    }

    private static func mirrorDemoMode() {
        guard let defaults = groupDefaults else { return }
        let value = UserDefaults.standard.bool(forKey: appDemoModeKey)
        if defaults.object(forKey: demoModeKey) as? Bool != value { defaults.set(value, forKey: demoModeKey) }
    }
}
