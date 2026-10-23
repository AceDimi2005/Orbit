import Foundation

private struct MockHTTPResult: @unchecked Sendable {
    var status = 200
    var body = Data("{\"status\":\"sent\"}".utf8)
    var headers: [String: String] = [:]
    var error: URLError?
}

private final class MockHTTPStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [MockHTTPResult] = []
    private var recorded: [URLRequest] = []

    func prepare(_ responses: [MockHTTPResult]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses
        recorded = []
    }

    func next(_ request: URLRequest) -> MockHTTPResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        precondition(!responses.isEmpty, "Unexpected retry or request")
        return responses.removeFirst()
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private final class MockWatchURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = MockHTTPStore()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result = Self.store.next(request)
        if let error = result.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                       httpVersion: "HTTP/1.1", headerFields: result.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private struct OrbitWatchHTTPClientTests {
    static let fingerprint = String(repeating: "ab", count: 32)

    static func target(host: String = "desktop.local", agentPort: Int = 8765, securePort: Int = 8766,
                       fingerprint: String = fingerprint, token: String = "paired-test-token") -> OrbitWatchControlTarget {
        OrbitWatchControlTarget(id: "pc-a", host: host, agentPort: agentPort, securePort: securePort,
                                fingerprint: fingerprint, token: token)
    }

    static func client(_ target: OrbitWatchControlTarget = target()) throws -> OrbitWatchHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWatchURLProtocol.self]
        return try OrbitWatchHTTPClient(target: target, configuration: configuration)
    }

    static func values(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
    }

    static func expectHTTP(_ status: Int, packet: OrbitCursorPacket = .init(click: "left")) async throws {
        MockWatchURLProtocol.store.prepare([MockHTTPResult(status: status, body: Data("{\"detail\":\"desktop message\"}".utf8))])
        do {
            try await client().sendCursor(packet)
            preconditionFailure("HTTP \(status) must fail")
        } catch let error as OrbitWatchHTTPError {
            precondition(error.statusCode == status)
            if status == 401 { precondition(error.localizedDescription.contains("Pair this PC again")) }
            if status == 503 { precondition(error.localizedDescription.contains("Windows desktop is unavailable")) }
        }
        precondition(MockWatchURLProtocol.store.requests.count == 1)
    }

    static func main() async throws {
        try invalidConnectionsNeverReachTheNetwork()
        try await pinnedHTTPSAndFullCursorContract()
        try await explicitLegacyHTTPAndImmutableDestination()
        try await onlyMissingCompatibleEndpointsCanFallback()
        try await errorsAndAmbiguousFailuresNeverReplayClicks()
        try await acknowledgementIsRequired()
        try await malformedRequestsAreRejectedBeforeSending()
        try await deckButtonsRunOnceWithPlainErrors()
        print("PASS: Watch HTTP target validation, HTTPS pin selection, immutable destination, exact cursor fields, explicit legacy HTTP, bounded legacy fallback, auth/desktop errors, refused redirects, no timeout replay, PC acknowledgement and deck button runs")
    }

    static func invalidConnectionsNeverReachTheNetwork() throws {
        MockWatchURLProtocol.store.prepare([])
        for host in ["", "http://desktop.local", "desktop.local/evil", "desktop.local?x=1", "desktop.local#x", "x@desktop.local", "desktop.local:8766", "desktop.local\\evil", "desktop\n.local", "[::1]"] {
            do {
                _ = try client(target(host: host))
                preconditionFailure("Invalid host was accepted: \(host)")
            } catch let error as OrbitWatchHTTPError { precondition(error == .invalidTarget) }
        }
        for badTarget in [target(agentPort: 0), target(agentPort: 65536), target(securePort: -1), target(token: ""), target(token: "token\r\nInjected: x")] {
            do {
                _ = try client(badTarget)
                preconditionFailure("Invalid target was accepted")
            } catch let error as OrbitWatchHTTPError { precondition(error == .invalidTarget) }
        }
        for pin in ["not-a-certificate", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            do {
                _ = try client(target(fingerprint: pin))
                preconditionFailure("A malformed TLS pin must never downgrade to HTTP")
            } catch let error as OrbitWatchHTTPError { precondition(error == .invalidFingerprint) }
        }
        precondition(MockWatchURLProtocol.store.requests.isEmpty)
    }

    static func pinnedHTTPSAndFullCursorContract() async throws {
        MockWatchURLProtocol.store.prepare([MockHTTPResult()])
        let spacedPin = Array(repeating: "AB", count: 32).joined(separator: ":")
        let connection = target(host: " desktop.local ", fingerprint: spacedPin)
        precondition(connection.hasSecureTLS && connection.fingerprint == fingerprint)
        try await client(connection).sendCursor(.init(dx: 4, dy: -2, click: "right", scroll: -3,
                                                      hscroll: 2, normX: 0.25, normY: 0.75, drag: "down"))
        let request = MockWatchURLProtocol.store.requests.only
        precondition(request.httpMethod == "POST")
        precondition(request.url?.scheme == "https" && request.url?.port == 8766)
        precondition(request.url?.host == "desktop.local" && request.url?.path == "/api/input/cursor")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer paired-test-token")
        precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        precondition(values(request) == ["dx": "0", "dy": "0", "click": "right", "scroll": "-3", "hscroll": "2", "drag": "down", "normX": "0.25", "normY": "0.75"])
    }

    static func explicitLegacyHTTPAndImmutableDestination() async throws {
        MockWatchURLProtocol.store.prepare([MockHTTPResult(), MockHTTPResult()])
        var selectedPC = target(host: "first-pc.local", agentPort: 9000, fingerprint: "")
        let connection = try client(selectedPC)
        selectedPC = target(host: "second-pc.local", token: "other-token")
        try await connection.sendCursor(.init(dx: 12, dy: -4))
        _ = try await connection.data(path: "/api/watch/summary")
        precondition(selectedPC.host == "second-pc.local")
        let requests = MockWatchURLProtocol.store.requests
        precondition(requests.count == 2)
        precondition(requests.allSatisfy { $0.url?.host == "first-pc.local" && $0.url?.port == 9000 && $0.url?.scheme == "http" })
        precondition(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer paired-test-token" })
        precondition(requests[1].httpMethod == "GET")
    }

    static func onlyMissingCompatibleEndpointsCanFallback() async throws {
        for status in [404, 405] {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(status: status), MockHTTPResult()])
            try await client().sendCursor(.init(dx: 6, dy: -7, click: "double", scroll: 2))
            let requests = MockWatchURLProtocol.store.requests
            precondition(requests.map { $0.url!.path } == ["/api/input/cursor", "/api/input/mouse"])
            precondition(requests.allSatisfy { $0.httpMethod == "POST" })
            precondition(values(requests[1]) == ["dx": "6", "dy": "-7", "click": "double", "scroll": "2"])
        }
        try await expectHTTP(404, packet: .init(normX: 0.5, normY: 0.5))
        try await expectHTTP(405, packet: .init(drag: "up"))
        try await expectHTTP(404, packet: .init(hscroll: 2))
    }

    static func errorsAndAmbiguousFailuresNeverReplayClicks() async throws {
        for status in [400, 401, 403, 500, 503] { try await expectHTTP(status) }
        MockWatchURLProtocol.store.prepare([MockHTTPResult(status: 302, headers: ["Location": "https://untrusted.local/collect"])])
        do {
            try await client().sendCursor(.init(click: "left"))
            preconditionFailure("Redirects must fail")
        } catch let error as OrbitWatchHTTPError {
            precondition(error.statusCode == 302)
            precondition(error.localizedDescription.contains("redirect"))
        }
        precondition(MockWatchURLProtocol.store.requests.only.url?.host == "desktop.local")
        for code in [URLError.timedOut, URLError.networkConnectionLost, URLError.cannotConnectToHost] {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(error: URLError(code))])
            do {
                try await client().sendCursor(.init(click: "left"))
                preconditionFailure("Transport error must fail without replay")
            } catch let error as URLError { precondition(error.code == code) }
            precondition(MockWatchURLProtocol.store.requests.count == 1)
        }
    }

    static func acknowledgementIsRequired() async throws {
        for response in ["{\"status\":\"ok\"}", "{}", "not JSON"] {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(body: Data(response.utf8))])
            do {
                try await client().sendCursor(.init(click: "left"))
                preconditionFailure("A buffered or malformed response cannot count as delivered")
            } catch let error as OrbitWatchHTTPError { precondition(error == .cursorNotAcknowledged) }
            precondition(MockWatchURLProtocol.store.requests.count == 1)
        }
    }

    static func malformedRequestsAreRejectedBeforeSending() async throws {
        MockWatchURLProtocol.store.prepare([])
        let connection = try client()
        for path in ["https://evil.local/api/status", "/ws/input", "/api/../secret", "/api/status?token=x", "/api/status#fragment", "/api/%2e%2e/status", "/api/status\n"] {
            do {
                _ = try await connection.data(path: path)
                preconditionFailure("Unsafe path was accepted")
            } catch let error as OrbitWatchHTTPError { precondition(error == .invalidRequest) }
        }
        do {
            _ = try await connection.data(path: "/api/status", method: "POST\r\nInjected: x")
            preconditionFailure("Invalid HTTP method was accepted")
        } catch let error as OrbitWatchHTTPError { precondition(error == .invalidRequest) }
        do {
            try await connection.sendCursor(.init(click: "invalid"))
            preconditionFailure("Invalid cursor packet was accepted")
        } catch let error as OrbitCursorPipelineError { precondition(error == .invalidPacket) }
        precondition(MockWatchURLProtocol.store.requests.isEmpty)
    }
}

extension OrbitWatchHTTPClientTests {
    /// `POST /api/deck/buttons/{id}/run`: pinned HTTPS, the id goes into the path only after
    /// validation, older agents and refused buttons get plain sentences, and nothing is replayed.
    static func deckButtonsRunOnceWithPlainErrors() async throws {
        let id = "3f2c9a8e-1b7d-4c55-9e0a-2d6f8b1c4e77"
        MockWatchURLProtocol.store.prepare([MockHTTPResult(body: Data("{\"status\":\"done\",\"detail\":\" Pressed Ctrl+Shift+M \"}".utf8))])
        let detail = try await client().runDeckButton(id: id)
        precondition(detail == "Pressed Ctrl+Shift+M")
        let request = MockWatchURLProtocol.store.requests.only
        precondition(request.httpMethod == "POST")
        precondition(request.url?.scheme == "https" && request.url?.port == 8766 && request.url?.host == "desktop.local")
        precondition(request.url?.path == "/api/deck/buttons/\(id)/run" && request.url?.query == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer paired-test-token")

        // A reply without a detail (or not JSON at all) still means the PC ran the button.
        for body in ["{\"status\":\"done\"}", "{\"status\":\"done\",\"detail\":\"  \"}", "ok"] {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(body: Data(body.utf8))])
            let none = try await client().runDeckButton(id: "deck_button-2")
            precondition(none == nil)
        }

        MockWatchURLProtocol.store.prepare([])
        for bad in ["", "../status", "a/b", "a b", "id?x=1", "%2e%2e", "ü", String(repeating: "a", count: 65), "id\n"] {
            do {
                _ = try await client().runDeckButton(id: bad)
                preconditionFailure("Unsafe deck button id was accepted: \(bad)")
            } catch let error as OrbitWatchHTTPError { precondition(error == .invalidRequest) }
        }
        precondition(MockWatchURLProtocol.store.requests.isEmpty)

        let cases: [(Int, String, OrbitWatchHTTPError)] = [
            (404, "{\"detail\":\"Not Found\"}", .deckUnavailable),
            (404, "{}", .deckUnavailable),
            (404, "{\"detail\":\"That button was deleted on another device.\"}", .deckRejected("That button was deleted on another device.")),
            (409, "{\"detail\":\"OBS is not running on the PC.\"}", .deckRejected("OBS is not running on the PC.")),
            (401, "{\"detail\":\"Invalid token\"}", .http(401, "Invalid token")),
            (500, "{\"detail\":\"boom\"}", .http(500, "boom")),
        ]
        for (status, body, expected) in cases {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(status: status, body: Data(body.utf8))])
            do {
                _ = try await client().runDeckButton(id: id)
                preconditionFailure("HTTP \(status) must fail")
            } catch let error as OrbitWatchHTTPError {
                precondition(error == expected, "HTTP \(status): \(error)")
                precondition(!(error.errorDescription ?? "").isEmpty)
            }
            precondition(MockWatchURLProtocol.store.requests.count == 1)
        }
        precondition(OrbitWatchHTTPError.deckUnavailable.localizedDescription.contains("Update"))

        for code in [URLError.timedOut, URLError.networkConnectionLost] {
            MockWatchURLProtocol.store.prepare([MockHTTPResult(error: URLError(code))])
            do {
                _ = try await client().runDeckButton(id: id)
                preconditionFailure("Transport error must fail without replay")
            } catch let error as URLError { precondition(error.code == code) }
            precondition(MockWatchURLProtocol.store.requests.count == 1)
        }
    }
}

private extension Array {
    var only: Element {
        precondition(count == 1, "Expected exactly one request, received \(count)")
        return self[0]
    }
}
