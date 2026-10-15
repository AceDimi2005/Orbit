import Foundation

@main
struct VolumeCommandQueueTests {
    @MainActor
    static func main() async throws {
        var delivered: [Double] = []
        var concurrent = 0
        var maxConcurrent = 0
        let queue = VolumeCommandQueue(interval: .milliseconds(20)) { value in
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            delivered.append(value)
            try? await Task.sleep(for: .milliseconds(30))
            concurrent -= 1
        }
        queue.enqueue(12)
        try await Task.sleep(for: .milliseconds(5))
        for level in 13...87 { queue.enqueue(Double(level)) }
        await queue.flush()
        precondition(delivered == [12, 87], "Only the first and most recent slider values should be sent: \(delivered)")
        precondition(maxConcurrent == 1, "Audio commands must remain serialized")
        precondition(!queue.isSending, "The sender must finish after the final value")

        delivered.removeAll()
        queue.enqueue(-20)
        await queue.flush()
        queue.enqueue(150)
        await queue.flush()
        queue.enqueue(.nan)
        await queue.flush()
        precondition(delivered == [0, 100], "Clamp endpoints and reject invalid values")

        delivered.removeAll()
        queue.enqueue(25)
        try await Task.sleep(for: .milliseconds(5))
        queue.enqueue(80)
        queue.cancel()
        try await Task.sleep(for: .milliseconds(80))
        precondition(delivered == [25], "A connection change must discard unsent values")
        queue.enqueue(42)
        await queue.flush()
        precondition(delivered == [25, 42], "The queue must recover after cancellation")
        print("PASS: volume coalescing, final value, serialization, bounds, cancellation, recovery")
    }
}
