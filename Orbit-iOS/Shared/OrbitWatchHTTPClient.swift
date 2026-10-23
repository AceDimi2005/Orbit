import CryptoKit
import Foundation
import Security

/// Capture a connection before queuing a command, so changing PCs cannot retarget it.
struct OrbitWatchControlTarget: Equatable, Sendable {
    let id: String
    let host: String
    let agentPort: Int
    let securePort: Int
    let fingerprint: String
    let token: String

    init(id: String, host: String, agentPort: Int, securePort: Int, fingerprint: String, token: String) {
        self.id = id
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentPort = agentPort
        self.securePort = securePort
        self.fingerprint = Self.normalizedFingerprint(fingerprint)
        self.token = token
    }

    var hasCredentials: Bool { !host.isEmpty && !token.isEmpty }
    var hasSecureTLS: Bool {
        fingerprint.count == 64 && fingerprint.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func normalizedFingerprint(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

enum OrbitWatchHTTPError: LocalizedError, Equatable {
    case invalidTarget
    case invalidFingerprint
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case certificateRejected(String)
    case http(Int, String?)
    case cursorNotAcknowledged
    /// The PC's agent has no button deck yet (`POST /api/deck/buttons/{id}/run` is an unknown route).
    case deckUnavailable
    /// The PC refused to run a deck button and said why (deleted button, invalid action…).
    case deckRejected(String)

    var statusCode: Int? {
        if case let .http(status, _) = self { return status }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "Open Orbit on iPhone and check this PC's address, ports and pairing token."
        case .invalidFingerprint:
            return "The PC certificate fingerprint is invalid. Pair this PC again in Orbit on iPhone."
        case .invalidRequest:
            return "This PC command is invalid."
        case .invalidResponse:
            return "The PC did not return a valid response."
        case .responseTooLarge:
            return "The PC response is too large."
        case let .certificateRejected(message):
            return message
        case .http(401, _), .http(403, _):
            return "The PC rejected the pairing token. Pair this PC again in Orbit on iPhone."
        case .http(503, _):
            return "The Windows desktop is unavailable. Sign in on the PC and check Orbit Agent."
        case .http(404, _), .http(405, _):
            return "This control is unavailable. Update Orbit Agent on the PC."
        case let .http(status, detail):
            if (300..<400).contains(status) {
                return "The PC tried to redirect the command. Check its address in Orbit on iPhone."
            }
            return detail.map { "PC error \(status): \($0)" } ?? "The PC returned error \(status)."
        case .cursorNotAcknowledged:
            return "The PC did not confirm the cursor command. Check Orbit Agent."
        case .deckUnavailable:
            return "Buttons need the latest Orbit agent on your PC. Update it, then try again."
        case let .deckRejected(message):
            return message
        }
    }
}

/// watchOS supports URLSession HTTP(S) without requiring an audio or VoIP session.
/// Keep one ephemeral session per immutable PC; never use a Watch WebSocket here.
final class OrbitWatchHTTPClient: @unchecked Sendable {
    let target: OrbitWatchControlTarget
    private let session: URLSession
    private let authentication: OrbitWatchHTTPDelegate

    convenience init(target: OrbitWatchControlTarget) throws {
        try self.init(target: target, configuration: .ephemeral)
    }

    /// Configuration injection lets native tests exercise real URLSession behavior
    /// through URLProtocol without connecting to a PC or moving a real cursor.
    init(target: OrbitWatchControlTarget, configuration: URLSessionConfiguration) throws {
        let forbiddenHostCharacters = CharacterSet(charactersIn: "/\\:?#@[]%")
            .union(.whitespacesAndNewlines).union(.controlCharacters)
        guard target.hasCredentials,
              target.host.rangeOfCharacter(from: forbiddenHostCharacters) == nil,
              (1...65535).contains(target.agentPort), (1...65535).contains(target.securePort),
              target.token.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw OrbitWatchHTTPError.invalidTarget
        }
        guard target.fingerprint.isEmpty || target.hasSecureTLS else {
            // A malformed pin must never select plaintext HTTP.
            throw OrbitWatchHTTPError.invalidFingerprint
        }
        self.target = target
        authentication = OrbitWatchHTTPDelegate(target: target)
        let safeConfiguration = configuration.copy() as! URLSessionConfiguration
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        safeConfiguration.timeoutIntervalForRequest = 3
        safeConfiguration.timeoutIntervalForResource = 4
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCredentialStorage = nil
        safeConfiguration.urlCache = nil
        session = URLSession(configuration: safeConfiguration, delegate: authentication, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        let allowedPath = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        guard path.hasPrefix("/api/"), path.unicodeScalars.allSatisfy(allowedPath.contains),
              !path.split(separator: "/").contains(".."),
              ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
            throw OrbitWatchHTTPError.invalidRequest
        }
        var components = URLComponents()
        components.scheme = target.hasSecureTLS ? "https" : "http"
        components.host = target.host
        components.port = target.hasSecureTLS ? target.securePort : target.agentPort
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.host?.lowercased() == target.host.lowercased() else {
            throw OrbitWatchHTTPError.invalidTarget
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if !Task.isCancelled, let message = authentication.failureMessage {
                throw OrbitWatchHTTPError.certificateRejected(message)
            }
            throw error
        }
        let (data, response) = result
        guard let response = response as? HTTPURLResponse else { throw OrbitWatchHTTPError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (dictionary?["detail"] as? String).map {
                String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(240))
            }
            throw OrbitWatchHTTPError.http(response.statusCode, detail)
        }
        guard data.count <= 8 * 1024 * 1024 else { throw OrbitWatchHTTPError.responseTooLarge }
        return data
    }

    func sendCursor(_ value: OrbitCursorPacket) async throws {
        let packet = try value.validated()
        var query = [
            URLQueryItem(name: "dx", value: String(packet.dx)),
            URLQueryItem(name: "dy", value: String(packet.dy)),
            URLQueryItem(name: "click", value: packet.click),
            URLQueryItem(name: "scroll", value: String(packet.scroll)),
            URLQueryItem(name: "hscroll", value: String(packet.hscroll)),
            URLQueryItem(name: "drag", value: packet.drag),
        ]
        if let x = packet.normX, let y = packet.normY {
            query += [URLQueryItem(name: "normX", value: String(x)), URLQueryItem(name: "normY", value: String(y))]
        }
        let response: Data
        do {
            response = try await data(path: "/api/input/cursor", method: "POST", query: query)
        } catch let error as OrbitWatchHTTPError {
            guard [404, 405].contains(error.statusCode ?? 0),
                  packet.normX == nil, packet.normY == nil, packet.drag.isEmpty, packet.hscroll == 0 else {
                throw error
            }
            // A definitive missing endpoint is safe to retry. A timeout or a 5xx
            // could happen after a click was applied, so those are never replayed.
            query.removeAll { ["hscroll", "drag"].contains($0.name) }
            response = try await data(path: "/api/input/mouse", method: "POST", query: query)
        }
        struct Acknowledgement: Decodable { let status: String }
        guard let acknowledgement = try? JSONDecoder().decode(Acknowledgement.self, from: response),
              acknowledgement.status == "sent" else {
            throw OrbitWatchHTTPError.cursorNotAcknowledged
        }
    }

    /// Runs one button of the PC's deck (`POST /api/deck/buttons/{id}/run`) and returns the PC's
    /// `detail` sentence, if any. Sent once: a timeout can arrive after the PC already pressed the
    /// keys, so it is never replayed.
    func runDeckButton(id: String) async throws -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...64).contains(id.unicodeScalars.count), id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw OrbitWatchHTTPError.invalidRequest
        }
        let response: Data
        do {
            response = try await data(path: "/api/deck/buttons/\(id)/run", method: "POST")
        } catch let error as OrbitWatchHTTPError {
            guard case let .http(status, detail) = error else { throw error }
            // FastAPI answers an unknown route with the bare detail "Not Found"; the deck's own
            // refusals are sentences meant for people.
            if status == 404, detail == nil || detail == "Not Found" { throw OrbitWatchHTTPError.deckUnavailable }
            if [400, 404, 409, 422, 426, 501, 503].contains(status), let detail, !detail.isEmpty {
                throw OrbitWatchHTTPError.deckRejected(detail)
            }
            throw error
        }
        struct Reply: Decodable { let detail: String? }
        let detail = (try? JSONDecoder().decode(Reply.self, from: response))?.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail?.isEmpty == false ? detail : nil
    }
}

private final class OrbitWatchHTTPDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let target: OrbitWatchControlTarget
    private let lock = NSLock()
    private var rejection: String?

    init(target: OrbitWatchControlTarget) { self.target = target }
    var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return rejection }
    private func setRejection(_ message: String?) { lock.lock(); rejection = message; lock.unlock() }

    private func authenticate(_ challenge: URLAuthenticationChallenge,
                              completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completion(.performDefaultHandling, nil)
            return
        }
        guard target.hasSecureTLS,
              challenge.protectionSpace.host.lowercased() == target.host.lowercased(),
              challenge.protectionSpace.port == target.securePort,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            setRejection("The PC certificate could not be verified. Pair this PC again in Orbit on iPhone.")
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        let received = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard received == target.fingerprint else {
            setRejection("The PC certificate changed. Verify its SHA-256 fingerprint and pair this PC again in Orbit on iPhone.")
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        // Pin the exact self-signed agent certificate while retaining signature
        // and expiry validation. A DHCP address change does not change PC identity.
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            setRejection("The PC certificate is invalid or expired. Check the PC and Watch clocks, then pair again.")
            completion(.cancelAuthenticationChallenge, nil)
            return
        }
        setRejection(nil)
        completion(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
