import Foundation

private enum CursorTestError: Error { case timedOut, transportFailed }

/// Holds each request until the test explicitly completes it. Cancellation is
/// deliberately ignored to exercise a real transport's late-completion behavior.
@MainActor
private final class CursorSenderGate {
    var delivered: [OrbitCursorPacket] = []
    var continuations: [CheckedContinuation<Void, any Error>] = []
    var concurrent = 0
    var maximumConcurrent = 0

    func send(_ packet: OrbitCursorPacket) async throws {
        delivered.append(packet)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func complete(_ error: (any Error)? = nil) {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

@main
private struct OrbitCursorPipelineTests {
    @MainActor
    static func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !predicate() {
            if clock.now > deadline { throw CursorTestError.timedOut }
            await Task.yield()
        }
    }

    @MainActor
    static func drain(_ queue: OrbitCursorCommandQueue, _ gate: CursorSenderGate) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while queue.isSending {
            if clock.now > deadline { throw CursorTestError.timedOut }
            gate.complete()
            await Task.yield()
        }
        await queue.flush()
    }

    @MainActor
    static func main() async throws {
        try packetContract()
        try await movementCoalescing()
        try await absoluteAndControlOrdering()
        try await stopDiscardsOnlyPendingMotion()
        try await cancelledRequestsCannotOverlapTheNextPC()
        try await cancellationBeforeWorkerStarts()
        try await boundedControlsReserveARelease()
        try await errorsAreReportedAndTheQueueRecovers()
        print("PASS: cursor payload contract, validation, bounded motion, absolute positions, ordered controls, stop, generation cancellation, serialization, overflow release, failure and recovery")
    }

    static func packetContract() throws {
        let packet = OrbitCursorPacket(dx: 12, dy: -5, click: "right", scroll: -2, hscroll: 3,
                                       normX: 0.25, normY: 0.75, drag: "up")
        let data = try JSONEncoder().encode(packet)
        let roundTrip = try JSONDecoder().decode(OrbitCursorPacket.self, from: data)
        precondition(roundTrip == packet)
        let values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Set(values.keys) == ["dx", "dy", "click", "scroll", "hscroll", "normX", "normY", "drag"])
        let legacy = try JSONDecoder().decode(OrbitCursorPacket.self, from: Data("{\"dx\":3,\"dy\":-4}".utf8))
        precondition(legacy == OrbitCursorPacket(dx: 3, dy: -4))
        let clamped = try OrbitCursorPacket(dx: Int.max, dy: Int.min, scroll: 900, hscroll: -900).validated()
        precondition(clamped.dx == 10_000 && clamped.dy == -10_000 && clamped.scroll == 100 && clamped.hscroll == -100)
        let absolute = try OrbitCursorPacket(dx: 300, dy: 400, normX: -1, normY: 2).validated()
        precondition(absolute.dx == 0 && absolute.dy == 0 && absolute.normX == 0 && absolute.normY == 1)
        for invalid in [OrbitCursorPacket(click: "other"), OrbitCursorPacket(drag: "left"),
                        OrbitCursorPacket(normX: 0.5), OrbitCursorPacket(normX: .nan, normY: 0),
                        OrbitCursorPacket(normX: 0, normY: .infinity)] {
            do {
                _ = try invalid.validated()
                preconditionFailure("Malformed input must be rejected")
            } catch let error as OrbitCursorPipelineError {
                precondition(error == .invalidPacket)
            }
        }
    }

    @MainActor
    static func movementCoalescing() async throws {
        let gate = CursorSenderGate()
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send)
        queue.enqueue(.init(dx: 4))
        try await until { gate.delivered.count == 1 }
        for _ in 0..<500 { queue.enqueue(.init(dx: 100, dy: -100)) }
        precondition(queue.pendingCount == 1, "A slow PC must not retain hundreds of gyro frames")
        try await drain(queue, gate)
        precondition(gate.delivered == [.init(dx: 4), .init(dx: 10_000, dy: -10_000)])
        precondition(gate.maximumConcurrent == 1)
    }

    @MainActor
    static func absoluteAndControlOrdering() async throws {
        let gate = CursorSenderGate()
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send)
        queue.enqueue(.init(dx: 1))
        try await until { gate.delivered.count == 1 }
        queue.enqueue(.init(dx: 40))
        queue.enqueue(.init(normX: 0.1, normY: 0.1))
        queue.enqueue(.init(dx: 15))
        queue.enqueue(.init(normX: 0.9, normY: 0.8))
        queue.enqueue(.init(click: "left"))
        queue.enqueue(.init(normX: 0.3, normY: 0.4))
        queue.enqueue(.init(dx: 12, dy: -3))
        queue.enqueue(.init(dx: 5, dy: -2))
        queue.enqueue(.init(drag: "down"))
        queue.enqueue(.init(dx: 6, click: "double"))
        queue.enqueue(.init(drag: "up"))
        try await drain(queue, gate)
        precondition(gate.delivered == [
            .init(dx: 1), .init(normX: 0.9, normY: 0.8), .init(click: "left"),
            .init(normX: 0.3, normY: 0.4), .init(dx: 17, dy: -5),
            .init(drag: "down"), .init(dx: 6, click: "double"), .init(drag: "up")
        ], "Motion may combine only inside the same interval between controls")
        precondition(gate.maximumConcurrent == 1)
    }

    @MainActor
    static func stopDiscardsOnlyPendingMotion() async throws {
        let gate = CursorSenderGate()
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send)
        queue.enqueue(.init(dx: 1))
        try await until { gate.delivered.count == 1 }
        queue.enqueue(.init(dx: 2))
        queue.enqueue(.init(click: "left"))
        queue.enqueue(.init(normX: 1, normY: 0))
        queue.enqueue(.init(drag: "down"))
        queue.enqueue(.init(dx: 4))
        queue.enqueue(.init(drag: "up"))
        queue.discardMotion()
        precondition(queue.pendingCount == 3)
        try await drain(queue, gate)
        precondition(gate.delivered == [.init(dx: 1), .init(click: "left"), .init(drag: "down"), .init(drag: "up")])
    }

    @MainActor
    static func cancelledRequestsCannotOverlapTheNextPC() async throws {
        let gate = CursorSenderGate()
        var failures = 0
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send, onFailure: { _ in failures += 1 })
        queue.enqueue(.init(dx: 1))
        try await until { gate.delivered.count == 1 }
        queue.enqueue(.init(click: "left"))
        queue.cancel()
        queue.enqueue(.init(dx: 90))
        for _ in 0..<20 { await Task.yield() }
        precondition(gate.delivered.count == 1, "A transport ignoring cancellation must not overlap a new connection")
        gate.complete(CursorTestError.transportFailed)
        try await until { gate.delivered.count == 2 }
        precondition(failures == 0, "A stale failure must not replace the new PC's status")
        try await drain(queue, gate)
        precondition(gate.delivered == [.init(dx: 1), .init(dx: 90)], "Pending commands for the previous PC must be invalidated")
        precondition(gate.maximumConcurrent == 1)
    }

    @MainActor
    static func cancellationBeforeWorkerStarts() async throws {
        let gate = CursorSenderGate()
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send)
        queue.enqueue(.init(click: "left"))
        queue.cancel()
        await queue.flush()
        precondition(gate.delivered.isEmpty)
        queue.enqueue(.init(click: "right"))
        try await drain(queue, gate)
        precondition(gate.delivered == [.init(click: "right")])
    }

    @MainActor
    static func boundedControlsReserveARelease() async throws {
        let gate = CursorSenderGate()
        var failures: [OrbitCursorPipelineError] = []
        let queue = OrbitCursorCommandQueue(maxPending: 2, minimumInterval: .zero, send: gate.send,
                                            onFailure: { if let error = $0 as? OrbitCursorPipelineError { failures.append(error) } })
        queue.enqueue(.init(drag: "down"))
        try await until { gate.delivered.count == 1 }
        precondition(queue.enqueue(.init(click: "left")))
        precondition(queue.enqueue(.init(click: "right")))
        precondition(!queue.enqueue(.init(click: "double")))
        precondition(queue.enqueue(.init(drag: "up")), "A full control queue must reserve space for release")
        for _ in 0..<100 { precondition(queue.enqueue(.init(drag: "up"))) }
        precondition(queue.pendingCount == 3)
        precondition(!queue.enqueue(.init(drag: "down")))
        precondition(!queue.enqueue(.init(dx: 1)))
        precondition(failures == [.queueFull, .queueFull, .queueFull], "Every rejected control must be reported")
        try await drain(queue, gate)
        precondition(gate.delivered == [.init(drag: "down"), .init(click: "left"), .init(click: "right"), .init(drag: "up")])
        precondition(gate.maximumConcurrent == 1)
    }

    @MainActor
    static func errorsAreReportedAndTheQueueRecovers() async throws {
        let gate = CursorSenderGate()
        var failures: [any Error] = []
        let queue = OrbitCursorCommandQueue(minimumInterval: .zero, send: gate.send, onFailure: { failures.append($0) })
        precondition(!queue.enqueue(.init(normX: .nan, normY: 0)))
        precondition(queue.enqueue(.init()))
        precondition(!queue.isSending)
        queue.enqueue(.init(dx: 1))
        try await until { gate.delivered.count == 1 }
        queue.enqueue(.init(click: "right"))
        gate.complete(CursorTestError.transportFailed)
        try await until { gate.delivered.count == 2 }
        try await drain(queue, gate)
        precondition(failures.count == 2)
        precondition(failures[0] as? OrbitCursorPipelineError == .invalidPacket)
        precondition(failures[1] is CursorTestError)
        precondition(gate.delivered == [.init(dx: 1), .init(click: "right")])
        precondition(!queue.isSending && queue.pendingCount == 0)
    }
}
