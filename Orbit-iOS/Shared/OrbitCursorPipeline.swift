import Foundation

/// The same cursor payload is used by the Watch HTTPS sender and the iPhone relay.
struct OrbitCursorPacket: Codable, Equatable, Sendable {
    var dx: Int
    var dy: Int
    var click: String
    var scroll: Int
    var hscroll: Int
    var normX: Double?
    var normY: Double?
    var drag: String

    init(dx: Int = 0, dy: Int = 0, click: String = "", scroll: Int = 0, hscroll: Int = 0,
         normX: Double? = nil, normY: Double? = nil, drag: String = "") {
        self.dx = dx
        self.dy = dy
        self.click = click
        self.scroll = scroll
        self.hscroll = hscroll
        self.normX = normX
        self.normY = normY
        self.drag = drag
    }

    var isMotionOnly: Bool {
        click.isEmpty && drag.isEmpty && scroll == 0 && hscroll == 0
    }

    var isEmpty: Bool {
        isMotionOnly && dx == 0 && dy == 0 && normX == nil && normY == nil
    }

    var isReleaseOnly: Bool {
        drag == "up" && click.isEmpty && scroll == 0 && hscroll == 0 && dx == 0 && dy == 0
            && normX == nil && normY == nil
    }

    /// Clamp accumulated movement to the PC input limits. Reject malformed controls.
    func validated() throws -> Self {
        guard ["", "left", "double", "right", "middle"].contains(click),
              ["", "up", "down"].contains(drag),
              (normX == nil) == (normY == nil),
              normX?.isFinite != false, normY?.isFinite != false else {
            throw OrbitCursorPipelineError.invalidPacket
        }
        var packet = self
        packet.dx = min(10_000, max(-10_000, dx))
        packet.dy = min(10_000, max(-10_000, dy))
        packet.scroll = min(100, max(-100, scroll))
        packet.hscroll = min(100, max(-100, hscroll))
        if let x = normX, let y = normY {
            packet.normX = min(1, max(0, x))
            packet.normY = min(1, max(0, y))
            // The PC uses absolute coordinates in preference to relative movement.
            packet.dx = 0
            packet.dy = 0
        }
        return packet
    }

    private enum CodingKeys: String, CodingKey {
        case dx, dy, click, scroll, hscroll, normX, normY, drag
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dx = try values.decodeIfPresent(Int.self, forKey: .dx) ?? 0
        dy = try values.decodeIfPresent(Int.self, forKey: .dy) ?? 0
        click = try values.decodeIfPresent(String.self, forKey: .click) ?? ""
        scroll = try values.decodeIfPresent(Int.self, forKey: .scroll) ?? 0
        hscroll = try values.decodeIfPresent(Int.self, forKey: .hscroll) ?? 0
        normX = try values.decodeIfPresent(Double.self, forKey: .normX)
        normY = try values.decodeIfPresent(Double.self, forKey: .normY)
        drag = try values.decodeIfPresent(String.self, forKey: .drag) ?? ""
    }
}

enum OrbitCursorPipelineError: LocalizedError, Equatable {
    case invalidPacket
    case queueFull

    var errorDescription: String? {
        switch self {
        case .invalidPacket: "The cursor command is invalid."
        case .queueFull: "Cursor controls are waiting for the PC. Pause and try again."
        }
    }
}

/// One request at a time. Motion is combined only between ordered control events.
/// Cancellation changes the generation immediately, but retains the worker until
/// an in-flight sender finishes, even if that sender ignores Task cancellation.
@MainActor
final class OrbitCursorCommandQueue {
    private let send: (OrbitCursorPacket) async throws -> Void
    private let onFailure: (any Error) -> Void
    private let maximumPending: Int
    private let minimumInterval: Duration
    private var pending: [OrbitCursorPacket] = []
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isSending: Bool { worker != nil }
    var pendingCount: Int { pending.count }

    init(maxPending: Int = 32, minimumInterval: Duration = .milliseconds(35),
         send: @escaping (OrbitCursorPacket) async throws -> Void,
         onFailure: @escaping (any Error) -> Void = { _ in }) {
        maximumPending = max(1, maxPending)
        self.minimumInterval = max(.zero, minimumInterval)
        self.send = send
        self.onFailure = onFailure
    }

    @discardableResult
    func enqueue(_ value: OrbitCursorPacket) -> Bool {
        let packet: OrbitCursorPacket
        do { packet = try value.validated() }
        catch { onFailure(error); return false }
        guard !packet.isEmpty else { return true }

        if packet.isMotionOnly, let last = pending.last, last.isMotionOnly {
            if packet.normX != nil {
                // A new absolute position supersedes every unsent movement after
                // the last click/drag/scroll barrier, including mixed motion modes.
                while pending.last?.isMotionOnly == true { pending.removeLast() }
                pending.append(packet)
                return true
            }
            if last.normX == nil {
                var combined = last
                // Each operand is already bounded, so these additions cannot overflow.
                combined.dx = min(10_000, max(-10_000, last.dx + packet.dx))
                combined.dy = min(10_000, max(-10_000, last.dy + packet.dy))
                pending[pending.count - 1] = combined
                return true
            }
        }

        // Keep one extra bounded slot for button release, even when click controls
        // fill the regular queue. Repeated releases with no intervening command
        // are equivalent and must not consume additional slots.
        if packet.isReleaseOnly, pending.last?.isReleaseOnly == true { return true }
        if pending.count >= maximumPending {
            guard packet.isReleaseOnly, pending.count == maximumPending else {
                onFailure(OrbitCursorPipelineError.queueFull)
                return false
            }
        }
        pending.append(packet)
        startWorkerIfNeeded()
        return true
    }

    /// Stop a gesture without dropping accepted clicks or a pending button release.
    func discardMotion() {
        pending.removeAll(where: \.isMotionOnly)
    }

    /// Invalidate unsent input and stale completion callbacks when the PC changes.
    /// The owner should enqueue a drag release for the old PC before switching.
    func cancel() {
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        worker?.cancel()
    }

    func flush() async {
        while let currentWorker = worker { await currentWorker.value }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        let currentGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == currentGeneration, !pending.isEmpty {
                let packet = pending.removeFirst()
                do { try await send(packet) }
                catch {
                    if generation == currentGeneration, !Task.isCancelled {
                        onFailure(error)
                    }
                }
                guard generation == currentGeneration, !Task.isCancelled, !pending.isEmpty else { break }
                do { try await Task.sleep(for: minimumInterval) }
                catch { break }
            }
            worker = nil
            // A new PC may already have queued input while the old request exited.
            startWorkerIfNeeded()
        }
    }
}
