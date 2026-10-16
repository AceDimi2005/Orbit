import Foundation
import Security
import CryptoKit

/// One immutable connection. An operation never changes destination when the user switches PCs.
final class OrbitAPIClient: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let token: String
    private let fingerprint: String
    private let session: URLSession
    private let authentication: OrbitPinnedDelegate
    private let pairingOnly: Bool

    static func normalizedFingerprint(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "").lowercased()
    }
    static func validFingerprint(_ value: String) -> Bool {
        let normalized = normalizedFingerprint(value)
        return normalized.count == 64 && normalized.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    init(host: String, port: Int, token: String, fingerprint: String, pairingOnly: Bool = false) throws {
        guard !host.isEmpty, !host.contains("/"), !host.contains(":"), (1...65535).contains(port), (!token.isEmpty || pairingOnly) else {
            throw OrbitError(message: "Enter the PC address, secure port and pairing token in My PCs.")
        }
        guard Self.validFingerprint(fingerprint) else {
            throw OrbitError(message: "Set up the encrypted connection in My PCs. Copy the certificate fingerprint printed by Orbit Agent 4.0.0 on your PC.")
        }
        self.host = host; self.port = port; self.token = token
        self.pairingOnly = pairingOnly
        self.fingerprint = Self.normalizedFingerprint(fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        authentication = OrbitPinnedDelegate(fingerprint: self.fingerprint)
        session = URLSession(configuration: configuration, delegate: authentication, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard path.hasPrefix("/api/") || path == "/ws/stream" else { throw OrbitError(message: "Invalid PC request.") }
        guard !pairingOnly || path.hasPrefix("/api/pair/") else { throw OrbitError(message: "Complete pairing before accessing this PC.") }
        var components = URLComponents()
        components.scheme = path == "/ws/stream" ? "wss" : "https"
        components.host = host; components.port = port; components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OrbitError(message: "Invalid PC address.") }
        var request = URLRequest(url: url); request.httpMethod = method
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let response = response as? HTTPURLResponse else { throw OrbitError(message: "The PC did not return a valid response.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
            throw OrbitError(message: detail ?? (response.statusCode == 401 ? "Pairing token rejected. Update this PC in My PCs." : "PC returned error \(response.statusCode)."))
        }
    }
    private func transportError(_ error: Error, transfer: OrbitPinnedDelegate? = nil) -> Error {
        if !Task.isCancelled, let message = transfer?.failureMessage ?? authentication.failureMessage { return OrbitError(message: message) }
        return error
    }
    func data(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request(path, method: method, query: query)) }
        catch { throw transportError(error) }
        let (data, response) = result
        try validate(response, data: data)
        guard data.count <= 8 * 1024 * 1024 else { throw OrbitError(message: "The PC response is too large.") }
        return data
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(path, query: query))
    }
    func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        try await get(path, query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
    }
    func send<T: Decodable, Body: Encodable>(_ path: String, method: String = "POST", body: Body) async throws -> T {
        var request = try request(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) } catch { throw transportError(error) }
        let (data, response) = result
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func send<T: Decodable, Body: Encodable>(path: String, method: String = "POST", body: Body) async throws -> T {
        try await send(path, method: method, body: body)
    }
    func download(path: String, query: [String: String], progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let delegate = OrbitTransferDelegate(fingerprint: fingerprint, progress: progress)
        let result: (URL, URLResponse)
        do { result = try await session.download(for: request(path, query: items), delegate: delegate) }
        catch { throw transportError(error, transfer: delegate) }
        let (temporary, response) = result
        do { try validate(response) } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        try Task.checkCancellation()
        let rawName = response.suggestedFilename ?? "download"
        let name = String(rawName.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { $0.value < 32 }) && !"/\\:".contains($0) }.prefix(180))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTransfers", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name.isEmpty ? "download" : name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }
    func upload(path: String, query: [String: String], file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = try request(path, method: "POST", query: items)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize
        if let size { request.setValue(String(size), forHTTPHeaderField: "Content-Length") }
        let delegate = OrbitTransferDelegate(fingerprint: fingerprint, progress: progress)
        let result: (Data, URLResponse)
        do { result = try await session.upload(for: request, fromFile: file, delegate: delegate) }
        catch { throw transportError(error, transfer: delegate) }
        let (data, response) = result
        try validate(response, data: data)
        progress(1)
        return data
    }
    func webSocket() throws -> URLSessionWebSocketTask { session.webSocketTask(with: try request("/ws/stream")) }
}

private class OrbitPinnedDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    private let lock = NSLock()
    private var rejection: String?
    var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return rejection }
    private func reject(_ message: String) { lock.lock(); rejection = message; lock.unlock() }
    init(fingerprint: String) { self.fingerprint = fingerprint }

    private func authenticate(_ challenge: URLAuthenticationChallenge, completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else {
            completion(.performDefaultHandling, nil); return
        }
        let der = SecCertificateCopyData(certificate) as Data
        let received = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard received == fingerprint else {
            reject("The PC certificate fingerprint does not match. Check Certificate SHA-256 in the agent window and update this PC in My PCs.")
            completion(.cancelAuthenticationChallenge, nil); return
        }
        // The exact certificate identifies the PC, verified out of band. Basic
        // X.509 validation keeps signature/validity checks without binding that
        // identity to a DHCP address that can change after the certificate was issued.
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            reject("The PC certificate is invalid or expired. Check the PC and iPhone clocks, then verify the certificate in My PCs.")
            completion(.cancelAuthenticationChallenge, nil); return
        }
        completion(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authenticate(challenge, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the token or a file to another endpoint.
    }
}

private final class OrbitTransferDelegate: OrbitPinnedDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(fingerprint: String, progress: @escaping @Sendable (Double) -> Void) { self.progress = progress; super.init(fingerprint: fingerprint) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
}
