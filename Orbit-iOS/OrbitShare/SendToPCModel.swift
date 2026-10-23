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
        /// Position of the current file in this batch, and the batch size.
        var index: Int
        var count: Int
        /// True when an earlier attempt already saved some files; this batch sends only the rest.
        var resuming: Bool
        var currentID: UUID
        var name: String
        var fileFraction: Double
        var overallFraction: Double
        var bytesSent: Int64
        var bytesTotal: Int64
        /// Files of this batch the PC confirmed.
        var savedIDs: Set<UUID>
    }

    @Published private(set) var stage: Stage = .loading
    @Published private(set) var content: SharedContent?
    @Published private(set) var textSummary: SharedTextSummary?
    @Published private(set) var skippedNote: String?
    /// How far reading the shared items got (shown while `stage == .loading`).
    @Published private(set) var preparing: SharedLoadProgress?
    @Published private(set) var targets: [SendToPCTarget] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var pcState: PCState = .checking
    @Published private(set) var notice: Notice?
    @Published private(set) var busyAction: Action?
    @Published private(set) var transfer: Transfer?
    /// Files each PC already received from an interrupted "Save to PC Downloads". Saving again sends
    /// only the other files, so nothing lands twice.
    @Published private(set) var deliveries = SendToPCDeliveries()

    private let items: [NSExtensionItem]
    private let loader = ShareItemLoader()
    private let finish: () -> Void
    private let cancelRequest: () -> Void
    private var loadTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var ended = false
    private var hostObservers: [NSObjectProtocol] = []
    private var hostInBackground = false
    /// The app the sheet was opened from went to the background while something was being sent.
    private var leftHostWhileSending = false
    private var grace: SendGrace?

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

    /// Files the selected PC already has from an earlier attempt in this share.
    var alreadySavedIDs: Set<UUID> {
        guard let id = selectedTarget?.id else { return [] }
        return Set(deliveries.saved(on: id).keys)
    }

    /// Shared files the selected PC does not have yet.
    var remainingFiles: [SharedFile] {
        guard case .files(let files)? = content else { return [] }
        let saved = alreadySavedIDs
        return files.filter { !saved.contains($0.id) }
    }

    // MARK: Lifecycle

    func start() {
        guard loadTask == nil else { return }
        observeHost()
        ShareItemLoader.removeStaleFolders()
        targets = Self.savedTargets()
        guard let first = targets.first else {
            stage = .unavailable(title: "No PC paired yet", message: SendToPCText.notPaired)
            return
        }
        selectedID = first.id
        checkSelectedPC()
        let relay = ProgressRelay<SharedLoadProgress>(perSecond: 10, isImportant: { update, previous in
            update.index != previous?.index || update.itemFraction >= 1
        }) { [weak self] update in
            guard let self, self.stage == .loading else { return }
            self.preparing = update
        }
        loadTask = Task { [weak self, loader, items] in
            do {
                let shared = try await loader.load(items) { relay.send($0) }
                guard let self, !Task.isCancelled else { return }
                self.preparing = nil
                self.content = shared.content
                self.textSummary = shared.textSummary
                self.skippedNote = shared.skippedNote
                if self.stage == .loading { self.stage = .ready }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.preparing = nil
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

    /// Switching PCs keeps what each PC already received, so switching back never sends twice.
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
        grace?.end(); grace = nil
        hostObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hostObservers = []
        loader.cleanUp()
    }

    // MARK: Host app in the background

    /// iOS pauses an extension soon after its host app goes to the background, which stops a running
    /// upload. Knowing that happened turns a vague "isn't reachable" into the real reason.
    private func observeHost() {
        guard hostObservers.isEmpty else { return }
        let center = NotificationCenter.default
        hostObservers.append(center.addObserver(forName: .NSExtensionHostDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostMoved(toBackground: true) }
        })
        hostObservers.append(center.addObserver(forName: .NSExtensionHostWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostMoved(toBackground: false) }
        })
    }

    private func hostMoved(toBackground: Bool) {
        hostInBackground = toBackground
        if toBackground && isBusy { leftHostWhileSending = true }
    }

    /// Asks iOS for extra time while sending, in case the user leaves the app for a moment.
    private func beginSending(_ reason: String) {
        leftHostWhileSending = hostInBackground
        grace?.end()
        grace = SendGrace(reason: reason)
    }

    /// Returns whether the host app went to the background while sending.
    @discardableResult
    private func endSending() -> Bool {
        grace?.end()
        grace = nil
        let left = leftHostWhileSending
        leftHostWhileSending = false
        return left
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
        beginSending("Sending to \(target.name)")
        sendTask = Task { [weak self] in
            do {
                let service = try SendToPCService(target: target)
                let (title, message) = try await operation(service)
                guard let self, !self.ended else { return }
                self.endSending()
                self.busyAction = nil
                self.succeed(title: title, message: message)
            } catch {
                guard let self, !self.ended else { return }
                let leftHost = self.endSending()
                self.busyAction = nil
                self.showError(leftHost && SendToPCService.isConnectionLoss(error)
                               ? SendToPCText.sendStoppedLeftApp
                               : SendToPCService.message(for: error, pcName: target.name))
            }
        }
    }

    func saveFiles() {
        guard !isBusy, case .files(let all)? = content, let target = selectedTarget else { return }
        // After an interrupted attempt, only the files this PC does not have yet.
        let earlier = deliveries.saved(on: target.id)
        let files = all.filter { earlier[$0.id] == nil }
        guard let first = files.first else { return }
        let uploads = files.map { SendToPCService.UploadItem(url: $0.url, name: $0.name, size: $0.size) }
        if let big = SendToPCService.oversized(uploads) {
            showError("\(big.name) is \(SendToPCService.format(big.size)). Orbit Companion accepts files up to 2 GB each.")
            return
        }
        notice = nil
        busyAction = .saveFiles
        stage = .sending
        beginSending("Saving files to \(target.name)")
        let total = uploads.reduce(Int64(0)) { $0 + $1.size }
        transfer = Transfer(index: 0, count: files.count, resuming: !earlier.isEmpty, currentID: first.id, name: first.name,
                            fileFraction: 0, overallFraction: 0, bytesSent: 0, bytesTotal: total, savedIDs: [])
        let ids = files.map(\.id)
        let names = files.map(\.name)
        let relay = ProgressRelay<SendToPCUploadProgress>(perSecond: 15, isImportant: { update, previous in
            update.index != previous?.index || update.fileFraction >= 1 || update.overallFraction >= 1
        }) { [weak self] update in
            self?.apply(update, ids: ids, names: names)
        }
        sendTask = Task { [weak self] in
            do {
                let service = try SendToPCService(target: target)
                let folder = try await service.downloadsFolder()
                let saved = try await service.save(uploads, into: folder) { relay.send($0) }
                // Every file arrived; a Cancel tapped in the last moment does not change that.
                guard let self, !self.ended else { return }
                self.endSending()
                self.busyAction = nil
                self.deliveries.record(saved, forFirstOf: ids, on: target.id)
                let delivered = self.deliveries.saved(on: target.id)
                let everything = all.compactMap { delivered[$0.id] }
                self.succeed(title: everything.count == 1 ? "Saved to Downloads" : "Saved \(everything.count) files",
                             message: Self.savedMessage(everything, pcName: target.name))
            } catch {
                let cancelled = Task.isCancelled
                guard let self, !self.ended else { return }
                let leftHost = self.endSending()
                self.busyAction = nil
                self.stage = .ready
                self.transfer = nil
                if let batch = error as? SendToPCBatchError { self.deliveries.record(batch.saved, forFirstOf: ids, on: target.id) }
                self.reportBatchFailure(error, cancelled: cancelled, leftHost: leftHost, total: all.count, target: target)
            }
        }
    }

    /// Stops the running upload. Files that already arrived stay on the PC.
    func cancelTransfer() {
        guard stage == .sending else { return }
        sendTask?.cancel()
    }

    static func savedMessage(_ saved: [SendToPCSavedFile], pcName: String) -> String {
        guard let only = saved.first, saved.count == 1 else {
            var message = "\(saved.count) files are in Downloads on \(pcName)."
            let renamed = saved.filter(\.wasRenamed).count
            if renamed > 0 {
                message += " \(renamed) got a number in their name because a file with the same name was already there."
            }
            return message
        }
        if only.wasRenamed {
            return "\(only.savedName) is in Downloads on \(pcName), because \(only.originalName) was already there."
        }
        return "\(only.savedName) is in Downloads on \(pcName)."
    }

    private func reportBatchFailure(_ error: Error, cancelled: Bool, leftHost: Bool, total: Int, target: SendToPCTarget) {
        let batch = error as? SendToPCBatchError
        let savedCount = deliveries.saved(on: target.id).count
        let rest = total - savedCount
        let savedText: String? = savedCount == 0 ? nil
            : "\(savedCount) of \(total) files \(savedCount == 1 ? "is" : "are") already in Downloads. "
              + (rest == 1 ? "Saving again sends only the last one." : "Saving again sends only the other \(rest).")
        if cancelled || SendToPCService.isCancellation(error) {
            let message = savedText ?? "Nothing was saved on \(target.name)."
            notice = Notice(title: "Upload cancelled", message: message, tone: .info)
            UIAccessibility.post(notification: .announcement, argument: "Upload cancelled. \(message)")
            return
        }
        var message: String
        if leftHost && SendToPCService.isConnectionLoss(error) {
            message = SendToPCText.uploadStoppedLeftApp
        } else {
            message = SendToPCService.message(for: error, pcName: target.name)
            if let name = batch?.failedName, total > 1, !message.contains(name) {
                message = "\(name) wasn't saved. " + message
            }
        }
        if let savedText { message += " " + savedText }
        showError(message)
    }

    private func apply(_ update: SendToPCUploadProgress, ids: [UUID], names: [String]) {
        guard stage == .sending, var current = transfer, ids.indices.contains(update.index) else { return }
        current.index = update.index
        current.currentID = ids[update.index]
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

/// Forwards progress from background queues to the main actor, at most `perSecond` times a second,
/// always passing the updates `isImportant` picks (a new file starting, the last update).
private final class ProgressRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    private var previous: Value?
    private let minimumGap: TimeInterval
    private let isImportant: (Value, Value?) -> Bool
    private let deliver: @MainActor (Value) -> Void

    init(perSecond: Double, isImportant: @escaping (Value, Value?) -> Bool, deliver: @escaping @MainActor (Value) -> Void) {
        minimumGap = 1 / max(1, perSecond)
        self.isImportant = isImportant
        self.deliver = deliver
    }

    func send(_ update: Value) {
        lock.lock()
        let now = Date()
        guard isImportant(update, previous) || now.timeIntervalSince(lastSent) >= minimumGap else { lock.unlock(); return }
        lastSent = now
        previous = update
        lock.unlock()
        Task { @MainActor [deliver] in deliver(update) }
    }
}

/// Asks iOS for extra time while something is being sent, so leaving the app the share sheet came
/// from does not pause the upload at once. iOS decides how long the extra time lasts.
private final class SendGrace: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var ended = false

    init(reason: String) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [self] expired in
            if expired {
                // The extra time is over: let the call that holds the activity open return.
                end()
            } else {
                // Holding this call open (on a background queue) keeps the activity running.
                release.wait()
            }
        }
    }

    func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        if first { release.signal() }
    }
}
