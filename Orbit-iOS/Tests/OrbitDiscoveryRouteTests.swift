import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func record(_ host: String) -> Data {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    _ = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    return withUnsafeBytes(of: address) { Data($0) }
}

private actor Probes {
    var active = 0
    var peak = 0
    var calls = 0
    func enter() { active += 1; calls += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

@main struct OrbitDiscoveryRouteTests {
    static let lan = OrbitDiscoveryEndpoint(host: "192.168.1.20", port: 8766)
    static let vmware = OrbitDiscoveryEndpoint(host: "192.168.100.1", port: 8766)
    static let remote = OrbitDiscoveryEndpoint(host: "100.80.1.2", port: 8766)
    static let selector = OrbitDiscoveryRouteSelector(probeTimeout: .milliseconds(60), overallTimeout: .milliseconds(300), localPreferenceWindow: .milliseconds(30))

    static func main() async throws {
        let addresses = OrbitDiscoveryEndpoint.ipv4Addresses(from: [
            record(vmware.host), Data([0]), record(lan.host), record(vmware.host),
            record("127.0.0.1"), record("169.254.1.2"), record("0.0.0.0"), record("224.0.0.1")
        ])
        precondition(Set(addresses) == Set([vmware.host, lan.host]))
        // The actual Bonjour records feed the selector; no dependency on result order.
        for hosts in [addresses, addresses.reversed().map { $0 }] {
            let route = try await selector.select(hosts.map { OrbitDiscoveryEndpoint(host: $0, port: 8766) }) { endpoint in
                if endpoint == lan { return }
                try await Task.sleep(for: .seconds(10))
            }
            precondition(route == lan)
        }
        let virtualAdapters = (1...5).map { OrbitDiscoveryEndpoint(host: "10.0.0.\($0)", port: 8766) }
        let queuedLAN = try await selector.select(virtualAdapters + [lan, remote]) { endpoint in
            if endpoint != lan { try await Task.sleep(for: .seconds(10)) }
        }
        precondition(queuedLAN == lan)
        print("PASS: VMware first, malformed records, duplicates and reordered Bonjour results")

        let visible = try await selector.reachable([vmware, remote, lan, lan]) { endpoint in
            if endpoint == vmware { try await Task.sleep(for: .seconds(10)) }
            if endpoint == remote { throw URLError(.serverCertificateUntrusted) }
        }
        precondition(visible == [lan], "Unreachable or unverified route would be displayed")
        let noneVisible = try await selector.reachable([vmware]) { _ in throw URLError(.cannotConnectToHost) }
        precondition(noneVisible.isEmpty)
        let bothVisible = try await selector.reachable([remote, lan]) { _ in }
        precondition(Set(bothVisible) == Set([remote, lan]))
        print("PASS: discovery displays only reachable, certificate-verified routes")

        let local = try await selector.select([remote, lan]) { endpoint in
            if endpoint == lan { try await Task.sleep(for: .milliseconds(10)) }
        }
        precondition(local == lan)
        let fallback = try await selector.select([lan, remote]) { endpoint in
            if endpoint == lan { try await Task.sleep(for: .seconds(10)) }
        }
        precondition(fallback == remote)
        let noVPN = try await selector.select([remote, lan]) { endpoint in
            if endpoint == remote { throw URLError(.cannotConnectToHost) }
        }
        precondition(noVPN == lan)
        print("PASS: local preference, remote fallback, and phone without VPN connectivity")

        let alternatePort = OrbitDiscoveryEndpoint(host: lan.host, port: 9999)
        let verified = try await selector.select([lan, alternatePort]) { endpoint in
            if endpoint == lan { throw URLError(.serverCertificateUntrusted) }
        }
        precondition(verified == alternatePort)
        print("PASS: rejected certificate leaves independently verified candidates eligible; ports retained")

        let probes = Probes()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await selector.select((1...40).map { OrbitDiscoveryEndpoint(host: "10.0.0.\($0)", port: 8766) }) { _ in
                await probes.enter()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await probes.leave(); throw error }
                await probes.leave()
            }
            fatalError("Unreachable addresses selected")
        } catch is CancellationError { throw CancellationError() }
        catch { precondition(error.localizedDescription.contains("No advertised address")) }
        precondition(start.duration(to: clock.now) < .seconds(1))
        let (active, peak, calls) = await (probes.active, probes.peak, probes.calls)
        precondition(active == 0 && peak <= 4 && calls <= 16)
        print("PASS: bounded failure, candidate cap, concurrency cap, and timed-out probes cancelled")

        let deadlineSelector = OrbitDiscoveryRouteSelector(probeTimeout: .seconds(10), overallTimeout: .milliseconds(40))
        let deadlineStart = clock.now
        do {
            _ = try await deadlineSelector.select([lan]) { _ in try await Task.sleep(for: .seconds(10)) }
            fatalError("Overall deadline did not stop selection")
        } catch is CancellationError { throw CancellationError() }
        catch { precondition(error.localizedDescription.contains("No advertised address")) }
        precondition(deadlineStart.duration(to: clock.now) < .seconds(1))
        let partialVisible = try await deadlineSelector.reachable([lan, vmware]) { endpoint in
            if endpoint != lan { try await Task.sleep(for: .seconds(10)) }
        }
        precondition(partialVisible == [lan])
        print("PASS: overall deadline cancels pending probes and retains verified discovery results")

        let inFlight = Probes()
        let cancelled = Task {
            try await selector.select([lan]) { _ in
                await inFlight.enter()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await inFlight.leave(); throw error }
                await inFlight.leave()
            }
        }
        while await inFlight.calls == 0 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled selection succeeded") }
        catch is CancellationError {}
        let remaining = await inFlight.active
        precondition(remaining == 0)
        print("PASS: cancellation stops in-flight probes and cannot select a stale route")

        let discoveryInFlight = Probes()
        let cancelledDiscovery = Task {
            try await selector.reachable([lan]) { _ in
                await discoveryInFlight.enter()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await discoveryInFlight.leave(); throw error }
                await discoveryInFlight.leave()
            }
        }
        while await discoveryInFlight.calls == 0 { await Task.yield() }
        cancelledDiscovery.cancel()
        do { _ = try await cancelledDiscovery.value; fatalError("Cancelled discovery returned stale routes") }
        catch is CancellationError {}
        let discoveryRemaining = await discoveryInFlight.active
        precondition(discoveryRemaining == 0)
        print("PASS: cancelled discovery stops pending route checks")

        let successes = Probes()
        let selected = try await selector.select([lan, lan, vmware, remote]) { _ in
            await successes.enter()
            await successes.leave()
        }
        precondition([lan, vmware].contains(selected))
        let successCalls = await successes.calls
        precondition(successCalls <= 3)
        print("PASS: duplicates probed once and multiple successful probes yield one route")
    }
}
