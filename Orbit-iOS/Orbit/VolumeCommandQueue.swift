import Foundation

/// Serializes audio requests and replaces intermediate slider positions with the
/// newest value. A slow connection cannot replay a backlog after the finger stops.
@MainActor
final class VolumeCommandQueue {
    private let send: (Double) async -> Void
    private let interval: Duration
    private var pending: Double?
    private var worker: Task<Void, Never>?
    private var revision = 0

    var isSending: Bool { worker != nil }

    init(interval: Duration = .milliseconds(80), send: @escaping (Double) async -> Void) {
        self.interval = interval
        self.send = send
    }

    func enqueue(_ level: Double) {
        guard level.isFinite else { return }
        pending = min(100, max(0, level)).rounded()
        guard worker == nil else { return }
        let currentRevision = revision
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.revision == currentRevision, let value = self.pending else { break }
                self.pending = nil
                await self.send(value)
                // A fixed minimum spacing limits traffic even when requests are fast.
                do { try await Task.sleep(for: self.interval) } catch { break }
            }
            guard let self, self.revision == currentRevision else { return }
            self.worker = nil
        }
    }

    func cancel() {
        revision += 1
        pending = nil
        worker?.cancel()
        worker = nil
    }

    func flush() async { await worker?.value }
}
