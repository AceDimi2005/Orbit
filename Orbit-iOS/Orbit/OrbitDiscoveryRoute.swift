import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An untrusted Bonjour hint, not a saved/authenticated PC identity.
struct OrbitDiscoveryEndpoint: Hashable, Sendable {
    let host: String
    let port: Int

    /// Only a preference hint. Private IPs may belong to virtual adapters; every
    /// candidate still needs a pinned HTTPS probe. Shared-range IPs are not proof of Tailscale.
    var prefersLocal: Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    static func ipv4Addresses(from addresses: [Data]) -> [String] {
        var result: [String] = []
        for address in addresses where address.count >= MemoryLayout<sockaddr_in>.size {
            var storage = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &storage) { address.copyBytes(to: $0, count: MemoryLayout<sockaddr_in>.size) }
            guard storage.sin_family == sa_family_t(AF_INET) else { continue }
            var raw = storage.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let first = UInt8(text.split(separator: ".")[0]) ?? 0
            guard first != 0, first != 127, first < 224, !text.hasPrefix("169.254.") else { continue }
            if !result.contains(text) { result.append(text) }
        }
        return result
    }

    static func bounded(_ endpoints: [Self]) -> [Self] {
        Array(Set(endpoints).sorted {
            if $0.prefersLocal != $1.prefersLocal { return $0.prefersLocal }
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.port < $1.port
        }.prefix(16))
    }
}

/// Probes only; the caller starts exactly one peer-bound handshake after selection.
/// Probe implementations must cooperate with cancellation (URLSession.data does).
struct OrbitDiscoveryRouteSelector: Sendable {
    var probeTimeout: Duration = .seconds(2)
    var overallTimeout: Duration = .seconds(8)
    var localPreferenceWindow: Duration = .milliseconds(300)

    private enum Event: Sendable {
        case probed(OrbitDiscoveryEndpoint, Bool)
        case deadline
        case preferenceExpired
    }

    func select(_ candidates: [OrbitDiscoveryEndpoint],
                probe: @escaping @Sendable (OrbitDiscoveryEndpoint) async throws -> Void) async throws -> OrbitDiscoveryEndpoint {
        let routes = try await scan(candidates, selectOne: true, probe: probe)
        guard let route = routes.first else { throw Self.unreachable }
        return route
    }

    /// Discovery displays only verified routes. Unlike selection, this collects
    /// every success within the deadline; pairing rechecks them when the user taps.
    func reachable(_ candidates: [OrbitDiscoveryEndpoint],
                   probe: @escaping @Sendable (OrbitDiscoveryEndpoint) async throws -> Void) async throws -> [OrbitDiscoveryEndpoint] {
        try await scan(candidates, selectOne: false, probe: probe)
    }

    private func scan(_ candidates: [OrbitDiscoveryEndpoint], selectOne: Bool,
                      probe: @escaping @Sendable (OrbitDiscoveryEndpoint) async throws -> Void) async throws -> [OrbitDiscoveryEndpoint] {
        try Task.checkCancellation()
        let candidates = OrbitDiscoveryEndpoint.bounded(candidates)
        return try await withThrowingTaskGroup(of: Event.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await Task.sleep(for: overallTimeout)
                return .deadline
            }
            var next = 0
            var pending = 0
            var result: [OrbitDiscoveryEndpoint] = []
            func enqueue(_ endpoint: OrbitDiscoveryEndpoint) {
                group.addTask {
                    let success = await Self.check(endpoint, timeout: probeTimeout, probe: probe)
                    return .probed(endpoint, success)
                }
            }
            while next < min(4, candidates.count) {
                enqueue(candidates[next]); next += 1; pending += 1
            }
            while pending > 0, let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .deadline, .preferenceExpired:
                    return OrbitDiscoveryEndpoint.bounded(result)
                case let .probed(endpoint, success):
                    pending -= 1
                    if success {
                        if selectOne && endpoint.prefersLocal { return [endpoint] }
                        result.append(endpoint)
                        if selectOne && result.count == 1 {
                            group.addTask {
                                try await Task.sleep(for: localPreferenceWindow)
                                return .preferenceExpired
                            }
                        }
                    }
                    if next < candidates.count {
                        enqueue(candidates[next]); next += 1; pending += 1
                    }
                }
            }
            try Task.checkCancellation()
            return OrbitDiscoveryEndpoint.bounded(result)
        }
    }

    private static var unreachable: OrbitError {
        OrbitError(message: "No advertised address responded with a verified Orbit connection. Check that your iPhone can reach the PC’s network and that Orbit is allowed through the firewall, then retry or use manual setup.")
    }

    private static func check(_ endpoint: OrbitDiscoveryEndpoint, timeout: Duration,
                              probe: @escaping @Sendable (OrbitDiscoveryEndpoint) async throws -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                do { try Task.checkCancellation(); try await probe(endpoint); try Task.checkCancellation(); return true }
                catch { return false }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            return await group.next() ?? false
        }
    }
}
