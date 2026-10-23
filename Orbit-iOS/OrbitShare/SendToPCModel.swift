import Foundation
import SwiftUI
import UIKit

/// State of the Send to PC sheet: what was shared, which PC receives it, and the send itself.
@MainActor
final class SendToPCModel: ObservableObject {
    enum Stage: Equatable {
        case loading
        /// Nothing can be sent (no paired PC, nothing readable); the sheet only explains why.
        case unavailable(title: String, message: String)
        case ready
        case sending
        case finished(title: String, message: String)
    }

    enum PCState: Equatable {
        case checking
        case ready(SendToPCReadiness)
        case problem(String)
    }

    enum Action: Equatable { case openLink, copyText, saveFiles }

    struct Notice: Equatable {
        enum Tone: Equatable { case info, warning, error }
        var title: String
        var message: String
        var tone: Tone
    }

    struct Transfer: Equatable {
        var index: Int
        var count: Int
        var name: String
        var fileFraction: Double
        var overallFraction: Double
        var bytesSent: Int64
        var bytesTotal: Int64
        var savedIDs: Set<UUID>
    }

    @Published private(set) var stage: Stage = .loading
    @Published private(set) var content: SharedContent?
    @Published private(set) var skippedNote: String?
    @Published private(set) var targets: [SendToPCTarget] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var pcState: PCState = .checking
    @Published private(set) var notice: Notice?
    @Published private(set) var busyAction: Action?
    @Published private(set) var transfer: Transfer?

    private let items: [NSExtensionItem]
    private let loader = ShareItemLoader()
    private let finish: () -> Void
    private let cancelRequest: () -> Void
    private var loadTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var ended = false

    init(items: [NSExtensionItem], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.items = items
        self.finish = finish
        self.cancelRequest = cancel
    }

    var selectedTarget: SendToPCTarget? { targets.first { $0.id == selectedID } ?? targets.first }
    var selectedName: String { selectedTarget?.name ?? "your PC" }
    var isBusy: Bool { busyAction != nil || stage == .sending }
    var readiness: SendToPCReadiness? {
        if case .ready(let value) = pcState { return value }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard loadTask == nil else { return }
        ShareItemLoader.removeStaleFolders()
        targets = Self.savedTargets()
        guard let first = targets.first else {
            stage = .unavailable(title: "No PC paired yet", message: SendToPCText.notPaired)
            return
        }
        selectedID = first.id
        checkSelectedPC()
        loadTask = Task { [weak self, loader, items] in
            do {
                let shared = try await loader.load(items)
                guard let self, !Task.isCancelled else { return }
                self.content = shared.content
                self.skippedNote = shared.skippedNote
                if self.stage == .loading { self.stage = .ready }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.stage = .unavailable(title: "Nothing to send", message: error.localizedDescription)
            }
        }
    }

    /// Default PC first, then the others in the order they were saved.
    static func savedTargets() -> [SendToPCTarget] {
        let connections = OrbitWidgetConnectionStore.connections()
        let defaultID = OrbitWidgetConnectionStore.defaultConnection()?.id
        let ordered = connections.filter { $0.id == defaultID } + connections.filter { $0.id != defaultID }
        return ordered.map { connection in
            let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return SendToPCTarget(id: connection.id, name: name.isEmpty ? connection.host : name,
                                  host: connection.host, port: connection.port,
                                  fingerprint: connection.certificateSHA256,
                                  token: try? OrbitWidgetConnectionStore.controlToken(for: connection.id))
        }
    }

    func select(_ id: String) {
        guard id != selectedID, !isBusy, targets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        notice = nil
        checkSelectedPC()
    }

    /// "Try Again": reads the saved PCs again first, so a PC the user just paired or fixed in Orbit
    /// (with the share sheet still open in the other app) is used with its new details.
    func retryCheck() {
        guard !isBusy else { return }
        let fresh = Self.savedTargets()
        guard !fresh.isEmpty else {
            targets = []
            stage = .unavailable(title: "No PC paired yet", message: SendToPCText.notPaired)
            return
        }
        targets = fresh
        if !fresh.contains(where: { $0.id == selectedID }) { selectedID = fresh[0].id }
        notice = nil
        checkSelectedPC()
    }

    /// Checks that the chosen PC answers and learns what it supports.
    func checkSelectedPC() {
        checkTask?.cancel()
        guard let target = selectedTarget else { return }
        pcState = .checking
        checkTask = Task { [weak self] in
            let result: PCState
            do {
                let service = try SendToPCService(target: target)
                result = .ready(try await service.readiness())
            } catch {
                result = .problem(SendToPCService.message(for: error, pcName: target.name))
            }
            guard let self, !Task.isCancelled, self.selectedID == target.id else { return }
            self.pcState = result
        }
    }

    /// Ends the extension request without sending (toolbar Cancel, or the sheet went away).
    func cancel() {
        guard !ended else { return }
        ended = true
        stopAll()
        cancelRequest()
    }

    /// Ends the request as completed (after a success, or Done).
    func done() {
        guard !ended else { return }
        ended = true
        stopAll()
        finish()
    }

    private func stopAll() {
        loadTask?.cancel(); checkTask?.cancel(); sendTask?.cancel(); finishTask?.cancel()
        loader.cleanUp()
    }

    // MARK: Actions

    func openLink() {
        guard case .link(let link)? = content else { return }
        run(.openLink) { service in
            try await service.openOnPC(link.url)
            return ("Opened on \(service.target.name)", "The link is open in the PC's web browser.")
        }
    }

    func copyText() {
        let text: String
        switch content {
        case .link(let link)?: text = link.url.absoluteString
        case .text(let value)?: text = value
        default: return
        }
        guard SendToPCService.fitsClipboard(text) else {
            showError(SendToPCText.textTooLong)
            return
        }
        run(.copyText) { service in
            try await service.copyToClipboard(text)
            return ("Copied to \(service.target.name)", "Press Ctrl+V on the PC to paste it.")
        }
    }

    private func run(_ action: Action, _ operation: @escaping @Sendable (SendToPCService) async throws -> (String, String)) {
        guard !isBusy, let target = selectedTarget else { return }
        notice = nil
        busyAction = action
        sendTask = Task { [weak self] in
            do {
                let service = try SendToPCService(target: target)
                let (title, message) = try await operation(service)
                guard let self, !Task.isCancelled else { return }
                self.busyAction = nil
                self.succeed(title: title, message: message)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.busyAction = nil
                self.showError(SendToPCService.message(for: error, pcName: target.name))
            }
        }
    }

    func saveFiles() {
        guard !isBusy, case .files(let files)? = content, !files.isEmpty, let target = selectedTarget else { return }
        let uploads = files.map { SendToPCService.UploadItem(url: $0.url, name: $0.name, size: $0.size) }
        if let big = SendToPCService.oversized(uploads) {
            showError("\(big.name) is \(SendToPCService.format(big.size)). Orbit Companion accepts files up to 2 GB each.")
            return
        }
        notice = nil
        busyAction = .saveFiles
        stage = .sending
        let total = uploads.reduce(Int64(0)) { $0 + $1.size }
        transfer = Transfer(index: 0, count: files.count, name: files[0].name, fileFraction: 0, overallFraction: 0,
                            bytesSent: 0, bytesTotal: total, savedIDs: [])
        let ids = files.map(\.id)
        let progressBox = ProgressRelay { [weak self] update in self?.apply(update, ids: ids, names: files.map(\.name)) }
        sendTask = Task { [weak self] in
            do {
                let service = try SendToPCService(target: target)
                let folder = try await service.downloadsFolder()
                let saved = try await service.save(uploads, into: folder) { update in progressBox.send(update) }
                guard let self, !Task.isCancelled else { return }
                self.busyAction = nil
                let renamed = saved.filter(\.wasRenamed).count
                let count = saved.count == 1 ? "\(saved[0].savedName) is" : "\(saved.count) files are"
                var message = "\(count) in Downloads on \(target.name)."
                if renamed == 1 && saved.count == 1 {
                    message = "\(saved[0].savedName) is in Downloads on \(target.name), because \(saved[0].originalName) was already there."
                } else if renamed > 0 {
                    message += " \(renamed) got a number in their name because a file with the same name was already there."
                }
                self.succeed(title: saved.count == 1 ? "Saved to Downloads" : "Saved \(saved.count) files", message: message)
            } catch {
                guard let self else { return }
                self.busyAction = nil
                self.stage = .ready
                self.transfer = nil
                self.reportBatchFailure(error, total: files.count, pcName: target.name)
            }
        }
    }

    /// Stops the running upload. Files that already arrived stay on the PC.
    func cancelTransfer() {
        guard stage == .sending else { return }
        sendTask?.cancel()
    }

    private func reportBatchFailure(_ error: Error, total: Int, pcName: String) {
        let batch = error as? SendToPCBatchError
        let savedCount = batch?.saved.count ?? 0
        let savedText = savedCount == 0 ? nil
            : "\(savedCount) of \(total) file\(total == 1 ? "" : "s") \(savedCount == 1 ? "was" : "were") already saved to Downloads."
        if batch?.isCancellation == true || error is CancellationError {
            notice = Notice(title: "Upload cancelled", message: savedText ?? "Nothing was saved on \(pcName).", tone: .info)
            return
        }
        var message = SendToPCService.message(for: error, pcName: pcName)
        if let name = batch?.failedName, total > 1, !message.contains(name) {
            message = "\(name) wasn't saved. " + message
        }
        if let savedText { message += " " + savedText }
        showError(message)
    }

    private func apply(_ update: SendToPCUploadProgress, ids: [UUID], names: [String]) {
        guard stage == .sending, var current = transfer, ids.indices.contains(update.index) else { return }
        current.index = update.index
        current.name = names[update.index]
        current.fileFraction = update.fileFraction
        current.overallFraction = update.overallFraction
        current.bytesSent = update.bytesSent
        current.bytesTotal = update.bytesTotal
        // A file counts as saved only once the PC answered for it; "all bytes sent" is not enough.
        current.savedIDs = Set(ids.prefix(update.index))
        transfer = current
    }

    // MARK: Results

    private func showError(_ message: String) {
        notice = Notice(title: "Couldn't send", message: message, tone: .error)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func succeed(title: String, message: String) {
        transfer = nil
        stage = .finished(title: title, message: message)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
        // A short look at the result, longer with VoiceOver so the announcement can finish.
        let delay: UInt64 = UIAccessibility.isVoiceOverRunning ? 4_000_000_000 : 1_400_000_000
        finishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.done()
        }
    }
}

/// Forwards upload progress from URLSession's queue to the main actor, at most ~15 times a second
/// (always passing the first update of each file and the final one).
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    private var lastIndex = -1
    private let deliver: @MainActor (SendToPCUploadProgress) -> Void

    init(deliver: @escaping @MainActor (SendToPCUploadProgress) -> Void) { self.deliver = deliver }

    func send(_ update: SendToPCUploadProgress) {
        lock.lock()
        let now = Date()
        let important = update.index != lastIndex || update.fileFraction >= 1 || update.overallFraction >= 1
        guard important || now.timeIntervalSince(lastSent) >= 1.0 / 15 else { lock.unlock(); return }
        lastSent = now
        lastIndex = update.index
        lock.unlock()
        Task { @MainActor [deliver] in deliver(update) }
    }
}
