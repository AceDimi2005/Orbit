import AppKit
import Foundation
import Network

// MARK: - Library (Sunshine)

extension OrbitMacViewModel {
    func refreshGames() async {
        guard !isDemoMode, metrics.isOnline, !isLoadingGames else { return }
        let version = generation
        isLoadingGames = true
        defer { if version == generation { isLoadingGames = false } }
        do {
            let fetched: [MacSunshineGame] = try await client().get("/api/sunshine/apps")
            guard version == generation else { return }
            games = fetched
        } catch {
            guard version == generation else { return }
            statusBanner = "Could not refresh the Sunshine library: \(error.localizedDescription)"
        }
        if let info: MacSunshineInfo = try? await client().get("/api/sunshine/info"), version == generation {
            sunshineInfo = info
        }
    }

    /// Starts the stream straight away in Moonlight (moonlight-qt) with its command line
    /// `stream <host> "<app>"`. Moonlight must already be paired with the PC itself; if it is
    /// already running, macOS only brings it forward and the app has to be picked there.
    func streamInMoonlight(appTitle: String) {
        guard let pc = currentPC, !isDemoMode else { openMoonlight(); return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.moonlight-stream.Moonlight") else {
            openMoonlight(); return
        }
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.moonlight-stream.Moonlight").isEmpty == false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["stream", pc.address, appTitle]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.statusBanner = "Moonlight could not start: \(error.localizedDescription)"
                } else if alreadyRunning {
                    self.statusBanner = "Moonlight was already open: choose \(pc.name) and \(appTitle) there."
                } else {
                    self.statusBanner = "Moonlight is starting \(appTitle) from \(pc.name)."
                }
            }
        }
    }

    func launchGame(_ game: MacSunshineGame) async {
        if isDemoMode {
            metrics.activeGame = game.title
            metrics.fps = 120
            statusBanner = "Demo · launched \(game.title)"
            return
        }
        if !metrics.isOnline { await wakePC() }
        guard metrics.isOnline else { statusBanner = "Launch stopped: the PC is not connected."; return }
        let version = generation
        do {
            _ = try await client().data("/api/sunshine/launch", method: "POST", query: [URLQueryItem(name: "app", value: game.title)])
            guard version == generation else { return }
            statusBanner = "Launched \(game.title) on \(currentPC?.name ?? "PC")"
            if UserDefaults.standard.bool(forKey: "mac.autoOpenMoonlight") { openMoonlight() }
        } catch {
            guard version == generation else { return }
            statusBanner = "Could not launch \(game.title): \(error.localizedDescription)"
        }
    }

    /// Opens Moonlight if installed, otherwise its download page.
    func openMoonlight() {
        if let url = URL(string: "moonlight://"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.moonlight-stream.Moonlight") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let page = URL(string: "https://moonlight-stream.org") {
            NSWorkspace.shared.open(page)
            statusBanner = "Moonlight is not installed. Opened moonlight-stream.org."
        }
    }
}

// MARK: - Audio mixer

extension OrbitMacViewModel {
    func refreshAudio() async {
        if isDemoMode { return }
        prepareAppIcons()
        guard metrics.isOnline, !isLoadingAudio else { return }
        let version = generation
        isLoadingAudio = true
        defer { if version == generation { isLoadingAudio = false } }
        do {
            let apiClient = try client()
            let reply: MacAudioSessionsReply = try await apiClient.get("/api/audio/sessions")
            guard version == generation else { return }
            guard reply.available else {
                audioError = "Windows audio sessions are unavailable. Check the active playback device."
                return
            }
            var seen = Set<String>()
            audioSessions = reply.sessions.filter { $0.volume.isFinite && (0...100).contains($0.volume) && seen.insert($0.id).inserted }.map { fetched in
                guard let local = audioSessions.first(where: { $0.id == fetched.id }) else { return fetched }
                let keepLocal = audioDragging.contains(fetched.id) || audioPending[fetched.id] != nil
                    || Date().timeIntervalSince(audioChanged[fetched.id] ?? .distantPast) < 1.5
                guard keepLocal else { return fetched }
                var result = fetched
                result.volume = local.volume
                result.isMuted = local.isMuted
                return result
            }
            audioUpdated = Date()
            audioError = nil
            do {
                let outputs: MacAudioOutputsReply = try await apiClient.get("/api/audio/outputs")
                guard version == generation else { return }
                audioOutputs = outputs.devices
                audioRoutingAvailable = outputs.routingAvailable
                audioRoutingReason = outputs.routingUnavailableReason
                defaultOutputSwitchAvailable = outputs.defaultSwitchAvailable == true
                defaultOutputSwitchReason = outputs.defaultSwitchUnavailableReason
            } catch {
                guard version == generation else { return }
                audioRoutingAvailable = false
                audioRoutingReason = "Choosing an output per app needs a newer Orbit Companion. Windows Settings → System → Sound → Volume mixer does it on the PC."
            }
        } catch {
            guard version == generation else { return }
            audioError = error.localizedDescription
        }
    }

    func setAudioDragging(_ id: String, _ active: Bool) {
        if active { audioDragging.insert(id) } else { audioDragging.remove(id); audioChanged[id] = Date() }
    }

    func setAppVolume(_ session: MacAudioSession, volume: Double) {
        guard volume.isFinite, let index = audioSessions.firstIndex(where: { $0.id == session.id }) else { return }
        let value = min(100, max(0, volume)).rounded()
        audioSessions[index].volume = value
        enqueueAudio(id: session.id, volume: value, muted: nil)
    }

    func toggleAppMute(_ session: MacAudioSession) {
        guard let index = audioSessions.firstIndex(where: { $0.id == session.id }) else { return }
        audioSessions[index].isMuted.toggle()
        enqueueAudio(id: session.id, volume: nil, muted: audioSessions[index].isMuted)
    }

    func routeApp(_ session: MacAudioSession, to outputID: String) async {
        if isDemoMode {
            if let index = audioSessions.firstIndex(where: { $0.id == session.id }), let device = audioOutputs.first(where: { $0.id == outputID }) {
                audioSessions[index].outputDeviceID = device.id
                audioSessions[index].outputDeviceName = device.name
            }
            return
        }
        guard audioRoutingAvailable, audioRoutingSessionID == nil, metrics.isOnline,
              session.pid > 0, let created = session.processCreateTime, created.isFinite, created > 0 else { return }
        let version = generation
        audioRoutingSessionID = session.id
        audioStatus = nil
        audioError = nil
        defer { if version == generation { audioRoutingSessionID = nil } }
        do {
            let _: MacAudioRouteReply = try await client().send("/api/audio/route", body: MacAudioRouteChange(id: session.id, expectedCreateTime: created, deviceID: outputID))
            guard version == generation else { return }
            audioStatus = "Windows saved this app's output preference. Some apps need playback or a restart before audio moves."
            await refreshAudio()
        } catch {
            guard version == generation else { return }
            audioError = error.localizedDescription
        }
    }

    private func enqueueAudio(id: String, volume: Double?, muted: Bool?) {
        guard !isDemoMode, metrics.isOnline else { return }
        audioChanged[id] = Date()
        var change = audioPending[id] ?? MacAudioSessionChange(id: id, volume: nil, isMuted: nil)
        if let volume { change.volume = volume }
        if let muted { change.isMuted = muted }
        audioPending[id] = change
        guard audioWorker == nil else { return }
        let version = generation
        audioWorker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == version, let next = self.audioPending.first else { break }
                self.audioPending.removeValue(forKey: next.key)
                if let apiClient = try? self.client() {
                    do {
                        let reply: MacAudioSessionReply = try await apiClient.send("/api/audio/session", body: next.value)
                        guard self.generation == version else { break }
                        if self.audioPending[next.key] == nil, !self.audioDragging.contains(next.key),
                           reply.session.volume.isFinite, (0...100).contains(reply.session.volume),
                           let index = self.audioSessions.firstIndex(where: { $0.id == next.key }) {
                            // Only the levels: name, group and icon come from the list.
                            self.audioSessions[index].volume = reply.session.volume
                            self.audioSessions[index].isMuted = reply.session.isMuted
                        }
                        self.audioError = nil
                    } catch {
                        guard self.generation == version else { break }
                        self.audioError = error.localizedDescription
                    }
                }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
            self?.audioWorker = nil
        }
    }
}

// MARK: - Processes

extension OrbitMacViewModel {
    func refreshProcesses() async {
        if isDemoMode { return }
        prepareAppIcons()
        guard metrics.isOnline, !isLoadingProcesses else { return }
        let version = generation
        isLoadingProcesses = true
        defer { if version == generation { isLoadingProcesses = false } }
        do {
            let list: MacProcessList = try await client().get("/api/processes")
            guard version == generation else { return }
            processes = list.processes
            processesCapturedAt = Date(timeIntervalSince1970: list.capturedAt)
            // The agent explains its GPU counters even when they work; only a problem is worth a line.
            processGpuStatus = list.gpuMetricsAvailable == true ? nil : (list.gpuMetricsStatus ?? "Update Orbit Companion on the PC for per-app graphics readings.")
            processesError = nil
        } catch {
            guard version == generation else { return }
            processesError = "Could not refresh processes. \(error.localizedDescription)"
        }
    }

    func endProcess(_ process: MacProcess) async {
        guard endingProcessID == nil, process.canTerminate else { return }
        if isDemoMode {
            processes.removeAll { $0.id == process.id }
            processActionStatus = "Demo · ended \(process.name)"
            return
        }
        guard metrics.isOnline, processes.contains(where: { $0.id == process.id }) else {
            processesError = "The process list changed. Refresh it and select the application again."
            return
        }
        let version = generation
        endingProcessID = process.pid
        processActionStatus = nil
        processesError = nil
        defer { if version == generation { endingProcessID = nil } }
        do {
            let data = try await client().data("/api/processes/\(process.pid)/terminate", method: "POST",
                                               query: [URLQueryItem(name: "expectedCreateTime", value: String(process.createTime))])
            guard version == generation else { return }
            let result = try JSONDecoder().decode(MacSimpleStatus.self, from: data)
            processActionStatus = result.status == "terminated" ? "Ended \(process.name)." : "End task requested for \(process.name). Refresh to check its state."
            await refreshProcesses()
        } catch {
            guard version == generation else { return }
            processesError = "Could not end \(process.name). \(error.localizedDescription)"
        }
    }
}

// MARK: - Clipboard (always user-initiated, never polled)

extension OrbitMacViewModel {
    var clipboardFitsLimit: Bool { clipboardText.utf16.count * 2 + 2 <= 1_048_576 && !clipboardText.contains("\0") }

    func pullClipboard() async {
        guard !isDemoMode, metrics.isOnline, !isClipboardBusy else { return }
        let version = generation
        isClipboardBusy = true; clipboardStatus = nil; clipboardError = nil
        defer { if version == generation { isClipboardBusy = false } }
        do {
            let result: MacClipboardPayload = try await client().get("/api/clipboard")
            guard version == generation else { return }
            clipboardText = result.text
            clipboardStatus = result.available ? "PC clipboard loaded." : "The PC clipboard does not contain text."
        } catch {
            guard version == generation else { return }
            clipboardError = error.localizedDescription
        }
    }

    func pushClipboard() async {
        guard !isDemoMode, metrics.isOnline, !isClipboardBusy, clipboardFitsLimit else { return }
        let version = generation
        let payload = MacClipboardWrite(text: clipboardText)
        isClipboardBusy = true; clipboardStatus = nil; clipboardError = nil
        defer { if version == generation { isClipboardBusy = false } }
        do {
            let _: MacSimpleStatus = try await client().send("/api/clipboard", method: "PUT", body: payload)
            guard version == generation else { return }
            clipboardStatus = payload.text.isEmpty ? "PC clipboard cleared." : "Text sent to the PC clipboard."
        } catch {
            guard version == generation else { return }
            clipboardError = error.localizedDescription
        }
    }

    func copyClipboardToMac() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardText, forType: .string)
        clipboardStatus = "Copied to the Mac clipboard."
        clipboardError = nil
    }

    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            clipboardError = "The Mac clipboard does not contain text."
            return
        }
        clipboardText = text
        clipboardStatus = "Pasted from the Mac clipboard."
        clipboardError = nil
    }
}

// MARK: - Session history

extension OrbitMacViewModel {
    func refreshHistory() async {
        guard !isDemoMode, metrics.isOnline, !isLoadingHistory else { return }
        let version = generation
        isLoadingHistory = true
        defer { if version == generation { isLoadingHistory = false } }
        do {
            let result: MacHistoryList = try await client().get("/api/history/sessions")
            guard version == generation else { return }
            historyList = result
            historyError = nil
        } catch {
            guard version == generation else { return }
            historyError = error.localizedDescription
        }
    }

    func loadSessionDetail(_ session: MacHistorySession) async throws -> MacHistoryDetail {
        try await client().get("/api/history/sessions/\(session.id)")
    }

    func startRecording(name: String?) async {
        await performHistoryAction {
            let _: MacHistorySession = try await $0.send("/api/history/start", body: MacHistoryStartBody(name: name))
        }
    }

    func stopRecording() async {
        await performHistoryAction {
            let _: MacHistoryStopResponse = try await $0.send("/api/history/stop", body: MacHistoryEmptyBody())
        }
    }

    func deleteSession(_ session: MacHistorySession) async {
        await performHistoryAction {
            let _: MacHistoryDeleteResponse = try await $0.send("/api/history/sessions/\(session.id)", method: "DELETE", body: MacHistoryEmptyBody())
        }
    }

    private func performHistoryAction(_ work: (OrbitAPIClient) async throws -> Void) async {
        guard !isDemoMode, metrics.isOnline, !isHistoryActing else { return }
        let version = generation
        isHistoryActing = true
        defer { if version == generation { isHistoryActing = false } }
        do {
            let apiClient = try client()
            try await work(apiClient)
            guard version == generation else { return }
            await refreshHistory()
        } catch {
            guard version == generation else { return }
            historyError = error.localizedDescription
        }
    }
}

// MARK: - Files

extension OrbitMacViewModel {
    var filesEnabled: Bool { metrics.isOnline && !isDemoMode }
    private var favoritesKey: String { "mac.files.favorites.\(currentPC?.id ?? "none")" }
    private static let previewLimit: Int64 = 256 * 1024 * 1024

    func resetFiles() {
        cancelTransfer()
        fileRoots = nil; filePath = nil; fileParentPath = nil
        fileBackHistory = []; fileForwardHistory = []; canGoBack = false; canGoForward = false
        fileEntries = []; fileTotal = 0; fileTruncated = false; fileSearch = ""
        filesError = nil; filesNotice = nil; isLoadingFiles = false
        loadFavorites()
    }

    func loadFavorites() {
        fileFavorites = UserDefaults.standard.data(forKey: favoritesKey).flatMap { try? JSONDecoder().decode([MacFileFavorite].self, from: $0) } ?? []
    }

    func toggleFavorite(_ path: String) {
        if fileFavorites.contains(where: { $0.path == path }) {
            fileFavorites.removeAll { $0.path == path }
        } else {
            let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
            fileFavorites.append(MacFileFavorite(name: name, path: path))
        }
        if let data = try? JSONEncoder().encode(fileFavorites) { UserDefaults.standard.set(data, forKey: favoritesKey) }
    }

    func isFavorite(_ path: String) -> Bool { fileFavorites.contains { $0.path == path } }

    /// Navigates to a folder (`nil` = the locations overview) and records history.
    func openLocation(_ path: String?) {
        guard filePath != path else { return }
        fileBackHistory.append(filePath)
        if fileBackHistory.count > 100 { fileBackHistory.removeFirst() }
        fileForwardHistory = []
        applyLocation(path)
    }

    func goBack() {
        guard let previous = fileBackHistory.popLast() else { return }
        fileForwardHistory.append(filePath)
        applyLocation(previous)
    }

    func goForward() {
        guard let next = fileForwardHistory.popLast() else { return }
        fileBackHistory.append(filePath)
        applyLocation(next)
    }

    func goToParent() {
        if let fileParentPath { openLocation(fileParentPath) } else { openLocation(nil) }
    }

    private func applyLocation(_ path: String?) {
        filePath = path
        fileParentPath = nil
        fileEntries = []
        fileTotal = 0
        fileSearch = ""
        filesError = nil
        filesNotice = nil
        canGoBack = !fileBackHistory.isEmpty
        canGoForward = !fileForwardHistory.isEmpty
        Task { await refreshFiles() }
    }

    func refreshFiles() async {
        guard filesEnabled else { return }
        let version = generation
        let requestedPath = filePath
        let requestedSearch = fileSearch
        let requestedSort = fileSort
        isLoadingFiles = true
        filesError = nil
        loadFavorites()
        defer { if version == generation { isLoadingFiles = false } }
        do {
            let apiClient = try client()
            if let requestedPath {
                let page: MacFilePage = try await apiClient.get(path: "/api/files/list", query: ["path": requestedPath, "search": requestedSearch, "sort": requestedSort.rawValue])
                guard version == generation, filePath == requestedPath, fileSearch == requestedSearch, fileSort == requestedSort else { return }
                fileEntries = page.entries
                fileParentPath = page.parentPath
                fileTotal = page.total
                fileTruncated = page.truncated == true
            } else {
                let roots: MacFileRoots = try await apiClient.get(path: "/api/files/roots")
                guard version == generation, filePath == nil else { return }
                fileRoots = roots
            }
        } catch is CancellationError {
        } catch {
            guard version == generation, filePath == requestedPath, fileSearch == requestedSearch, fileSort == requestedSort else { return }
            filesError = error.localizedDescription
        }
    }

    func loadMoreFiles() async {
        guard filesEnabled, let path = filePath, !isLoadingFiles, fileEntries.count < fileTotal else { return }
        let version = generation
        let requestedSearch = fileSearch, requestedSort = fileSort
        isLoadingFiles = true
        defer { if version == generation { isLoadingFiles = false } }
        do {
            let page: MacFilePage = try await client().get(path: "/api/files/list", query: ["path": path, "search": requestedSearch, "sort": requestedSort.rawValue, "offset": String(fileEntries.count)])
            guard version == generation, filePath == path, fileSearch == requestedSearch, fileSort == requestedSort else { return }
            let existing = Set(fileEntries.map(\.path))
            fileEntries += page.entries.filter { !existing.contains($0.path) }
            fileTotal = page.total
        } catch {
            guard version == generation, filePath == path, fileSearch == requestedSearch, fileSort == requestedSort else { return }
            filesError = error.localizedDescription
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        transferID = UUID()
        transfer = nil
    }

    private func beginProgress(size: Int64) {
        transferTotalBytes = size
        transferLastBytes = 0
        transferLastTime = Date()
        transfer?.progress = 0
        transfer?.bytesPerSecond = 0
        transfer?.indeterminate = false
        transfer?.phase = "encrypted transfer"
    }

    private func progressHandler(_ identifier: UUID, generation version: Int) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, self.transferID == identifier, self.generation == version else { return }
                self.transfer?.progress = min(1, max(0, progress))
                let elapsed = Date().timeIntervalSince(self.transferLastTime)
                if elapsed >= 0.25 {
                    let bytes = Double(self.transferTotalBytes) * (self.transfer?.progress ?? 0)
                    self.transfer?.bytesPerSecond = max(0, (bytes - self.transferLastBytes) / elapsed)
                    self.transferLastBytes = bytes
                    self.transferLastTime = Date()
                }
            }
        }
    }

    /// Downloads files (and folders as ZIP) into `directory`. Returns the saved URLs.
    @discardableResult
    func download(_ entries: [MacFileEntry], to directory: URL, revealInFinder: Bool = true) async -> [URL] {
        guard filesEnabled, !entries.isEmpty, transfer == nil else { return [] }
        let apiClient: OrbitAPIClient
        do { apiClient = try client() } catch { filesError = error.localizedDescription; return [] }
        let version = generation
        let identifier = UUID()
        transferID = identifier
        transfer = MacTransferState(title: "Downloading \(entries[0].name)")
        filesError = nil
        filesNotice = nil
        var saved: [URL] = []
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard version == generation, transferID == identifier else { throw CancellationError() }
                let temporary: URL
                if entry.isDirectory {
                    temporary = try await downloadArchive(entry, index: index, count: entries.count, client: apiClient, identifier: identifier, version: version)
                } else {
                    beginProgress(size: entry.sizeBytes ?? 0)
                    transfer?.title = "Downloading \(entry.name) · \(index + 1)/\(entries.count)"
                    temporary = try await apiClient.download(path: "/api/files/download", query: ["path": entry.path], progress: progressHandler(identifier, generation: version))
                }
                let destination = Self.uniqueDestination(in: directory, name: temporary.lastPathComponent)
                try FileManager.default.moveItem(at: temporary, to: destination)
                saved.append(destination)
            }
            guard version == generation, transferID == identifier else { return saved }
            filesNotice = "Saved \(saved.count) item\(saved.count == 1 ? "" : "s") to \(directory.lastPathComponent)."
            if revealInFinder, !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        } catch is CancellationError {
        } catch {
            if version == generation, transferID == identifier { filesError = error.localizedDescription }
        }
        if transferID == identifier { transfer = nil; transferTask = nil }
        return saved
    }

    /// Downloads a single file to a temporary folder and opens it with the default app.
    func openWithDefaultApp(_ entry: MacFileEntry) async {
        guard filesEnabled, !entry.isDirectory, transfer == nil else { return }
        if let size = entry.sizeBytes, size > Self.previewLimit {
            filesError = "Files over 256 MB are not opened directly. Use Download instead."
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitMac-Open", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = await download([entry], to: directory, revealInFinder: false)
        if let url = saved.first { NSWorkspace.shared.open(url) }
    }

    private func downloadArchive(_ folder: MacFileEntry, index: Int, count: Int, client apiClient: OrbitAPIClient, identifier: UUID, version: Int) async throws -> URL {
        transfer?.title = "Preparing \(folder.name).zip · \(index + 1)/\(count)"
        transfer?.progress = 0
        transfer?.bytesPerSecond = 0
        transfer?.indeterminate = true
        transfer?.phase = "Checking folder contents…"
        var job: MacArchiveJob = try await apiClient.send(path: "/api/files/archive", body: MacFilePathRequest(path: folder.path))
        let jobID = job.id
        guard jobID.count == 32, jobID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw OrbitError(message: "The PC returned an invalid folder transfer. Update the Orbit Agent and try again.")
        }
        defer {
            let path = "/api/files/archive/\(jobID)"
            Task { _ = try? await apiClient.data(path, method: "DELETE") }
        }
        let deadline = Date().addingTimeInterval(150)
        while true {
            try Task.checkCancellation()
            guard version == generation, identifier == transferID else { throw CancellationError() }
            guard job.id == jobID else { throw OrbitError(message: "The folder transfer changed unexpectedly. Start the download again.") }
            if job.status == "ready" { break }
            guard Date() < deadline else { throw OrbitError(message: "This folder is taking too long to prepare. Choose a smaller folder and try again.") }
            if job.status == "failed" || job.status == "cancelling" {
                throw OrbitError(message: job.error ?? "Folder download was cancelled. Start it again when ready.")
            }
            transfer?.indeterminate = job.status == "scanning"
            transfer?.progress = min(1, max(0, job.progress))
            transfer?.phase = job.status == "scanning" ? "Checking folder contents…" : "preparing ZIP · \(job.totalEntries) items"
            try await Task.sleep(for: .milliseconds(400))
            job = try await apiClient.get(path: "/api/files/archive/\(jobID)")
        }
        beginProgress(size: job.archiveBytes ?? 0)
        transfer?.title = "Downloading \(job.name) · \(index + 1)/\(count)"
        return try await apiClient.download(path: "/api/files/archive/\(jobID)/download", query: [:], progress: progressHandler(identifier, generation: version))
    }

    static func uniqueDestination(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    /// Uploads local files into the current PC folder.
    func upload(_ urls: [URL]) async {
        guard filesEnabled, let directory = filePath, !urls.isEmpty, transfer == nil else { return }
        let apiClient: OrbitAPIClient
        do { apiClient = try client() } catch { filesError = error.localizedDescription; return }
        let version = generation
        let identifier = UUID()
        transferID = identifier
        transfer = MacTransferState(title: "Preparing upload…")
        filesError = nil
        filesNotice = nil
        var completed = 0
        var renamed = 0
        do {
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                guard version == generation, transferID == identifier else { throw CancellationError() }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw OrbitError(message: "Select files rather than folders. Folder uploads are not supported.")
                }
                beginProgress(size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                let name = OrbitFileNames.windowsSafe(url.lastPathComponent) ?? "Upload \(index + 1)"
                transfer?.title = "Uploading \(name) · \(index + 1)/\(urls.count)"
                // A taken name becomes "name (2).ext" instead of failing the rest of the batch.
                let saved = try await apiClient.uploadAvoidingConflicts(directory: directory, name: name, file: url,
                                                                        progress: progressHandler(identifier, generation: version))
                if saved != name { renamed += 1 }
                completed += 1
            }
            guard version == generation, transferID == identifier else { return }
            filesNotice = "Uploaded \(completed) file\(completed == 1 ? "" : "s")." + (renamed > 0 ? " \(renamed) renamed because the name was already taken." : "")
        } catch is CancellationError {
        } catch {
            if version == generation, transferID == identifier {
                filesError = "\(completed > 0 ? "\(completed) file(s) uploaded. " : "")\(error.localizedDescription)"
            }
        }
        if transferID == identifier { transfer = nil; transferTask = nil; await refreshFiles() }
    }

    func createFolder(named name: String) async {
        guard let directory = filePath else { return }
        await performFileOperation(title: "Creating folder…") { apiClient in
            let _: MacFileResult = try await apiClient.send(path: "/api/files/mkdir", body: MacFileNameRequest(parent: directory, name: name))
        }
    }

    func rename(_ entry: MacFileEntry, to name: String) async {
        await performFileOperation(title: "Renaming…") { apiClient in
            let _: MacFileResult = try await apiClient.send(path: "/api/files/rename", body: MacFileRenameRequest(path: entry.path, name: name))
        }
    }

    func move(_ entries: [MacFileEntry], toDirectory destination: String) async {
        await performFileOperation(title: "Moving items…") { apiClient in
            for entry in entries {
                try Task.checkCancellation()
                let _: MacFileResult = try await apiClient.send(path: "/api/files/move", body: MacFileMoveRequest(path: entry.path, destinationDirectory: destination))
            }
        }
    }

    func recycle(_ entries: [MacFileEntry]) async {
        await performFileOperation(title: "Moving to Recycle Bin…") { apiClient in
            for entry in entries {
                try Task.checkCancellation()
                let _: MacFileResult = try await apiClient.send(path: "/api/files/trash", body: MacFilePathRequest(path: entry.path))
            }
        }
    }

    private func performFileOperation(title: String, work: (OrbitAPIClient) async throws -> Void) async {
        guard filesEnabled, transfer == nil else { return }
        let apiClient: OrbitAPIClient
        do { apiClient = try client() } catch { filesError = error.localizedDescription; return }
        let version = generation
        let identifier = UUID()
        transferID = identifier
        transfer = MacTransferState(title: title, indeterminate: true, phase: title)
        filesError = nil
        filesNotice = nil
        do {
            try await work(apiClient)
            guard version == generation, transferID == identifier else { return }
            filesNotice = "Done."
        } catch is CancellationError {
        } catch {
            if version == generation, transferID == identifier { filesError = error.localizedDescription }
        }
        if transferID == identifier { transfer = nil; await refreshFiles() }
    }
}

// MARK: - Discovery, pairing and iPhone sync

extension OrbitMacViewModel {
    func startDiscovery() {
        stopDiscovery()
        isScanning = true
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let nwBrowser = NWBrowser(for: .bonjourWithTXTRecord(type: "_orbit._tcp", domain: nil), using: parameters)
        browser = nwBrowser
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                var txt: [String: String] = [:]
                if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                self?.resolve(result.endpoint, txt: txt)
            }
        }
        nwBrowser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.pairingError = "Bonjour discovery is unavailable. Check Local Network access for Orbit in System Settings → Privacy & Security." }
            }
        }
        nwBrowser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    nonisolated private func resolve(_ endpoint: NWEndpoint, txt: [String: String]) {
        let fingerprint = OrbitAPIClient.normalizedFingerprint(txt["fingerprint"] ?? "")
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint, case .hostPort(let host, let port) = remote {
                    let rawHost = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    let securePort = Int(port.rawValue)
                    connection.cancel()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if OrbitAPIClient.validFingerprint(fingerprint) {
                            let item = MacDiscoveredPC(name: txt["name"] ?? rawHost, host: rawHost, discoveryPort: 8765, securePort: securePort,
                                                       fingerprint: fingerprint, agentVersion: txt["version"] ?? "")
                            if let index = self.discoveredPCs.firstIndex(where: { $0.id == item.id }) { self.discoveredPCs[index] = item } else { self.discoveredPCs.append(item) }
                        } else {
                            await self.probeHost(rawHost, port: 8765)
                        }
                    }
                } else {
                    connection.cancel()
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    /// Manual pairing by address: asks the agent's public discovery endpoint for its fingerprint.
    func probeManualHost(_ hostInput: String, discoveryPort: Int = 8765) async {
        let clean = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        guard !clean.isEmpty else { pairingError = "Enter your PC's IPv4 address first (for example 192.168.1.50)."; return }
        pairingError = nil
        isProbing = true
        defer { isProbing = false }
        if let found = await probeHost(clean, port: discoveryPort) {
            await beginPairing(with: found)
        } else {
            pairingError = "Could not reach Orbit Agent at \(clean):\(discoveryPort). Make sure the PC is on and Orbit Agent is running."
        }
    }

    @discardableResult
    func probeHost(_ host: String, port: Int) async -> MacDiscoveredPC? {
        guard let url = URL(string: "http://\(host):\(port)/api/discover") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4096,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["service"] as? String == "orbit-agent",
              let fingerprint = json["fingerprint"] as? String,
              OrbitAPIClient.validFingerprint(fingerprint) else { return nil }
        let item = MacDiscoveredPC(
            name: (json["name"] as? String) ?? host,
            host: host,
            discoveryPort: port,
            securePort: (json["securePort"] as? Int) ?? 8766,
            fingerprint: OrbitAPIClient.normalizedFingerprint(fingerprint),
            agentVersion: (json["agentVersion"] as? String) ?? ""
        )
        if let index = discoveredPCs.firstIndex(where: { $0.id == item.id }) { discoveredPCs[index] = item } else { discoveredPCs.append(item) }
        return item
    }

    func beginPairing(with target: MacDiscoveredPC) async {
        cancelPairing()
        let attempt = UUID()
        pairingAttempt = attempt
        pairingTarget = target
        isPairing = true
        defer { if pairingAttempt == attempt { isPairing = false } }
        do {
            let connection = try OrbitPairingHandshake(host: target.host, port: target.securePort, fingerprint: target.fingerprint)
            let seconds = try await connection.begin(name: "Orbit on \(Host.current().localizedName ?? "Mac")")
            guard pairingAttempt == attempt else { return }
            handshake = connection
            pairingLifetime = Double(seconds)
            pairingExpiresAt = Date().addingTimeInterval(Double(seconds))
        } catch {
            guard pairingAttempt == attempt else { return }
            pairingError = error.localizedDescription
            handshake = nil
        }
    }

    func finishPairing(pin: String) async {
        guard let connection = handshake, let target = pairingTarget, !isPairing else { return }
        let attempt = pairingAttempt
        isPairing = true
        pairingError = nil
        defer { if pairingAttempt == attempt { isPairing = false } }
        do {
            let credentials = try await connection.finish(pin: pin.trimmingCharacters(in: .whitespacesAndNewlines))
            guard pairingAttempt == attempt else { return }
            let fingerprint = OrbitAPIClient.normalizedFingerprint(credentials.certificateFingerprint)
            var profile = savedPCs.first(where: { OrbitAPIClient.normalizedFingerprint($0.certificateFingerprint) == fingerprint })
                ?? MacSavedPC(name: credentials.hostname, address: target.host)
            profile.name = credentials.hostname
            profile.address = OrbitPCCloudSync.isIPv4(credentials.ipAddress) ? credentials.ipAddress : target.host
            if target.host.lowercased().hasSuffix(".local") { profile.bonjourHost = target.host }
            profile.updatedAt = Date().timeIntervalSince1970
            profile.agentPort = credentials.agentPort
            profile.securePort = credentials.securePort
            profile.certificateFingerprint = fingerprint
            profile.macAddress = credentials.macAddress
            profile.subnetMask = credentials.subnetMask
            profile.broadcastAddress = credentials.broadcastAddress
            profile.lastKnownIPv4 = credentials.ipAddress
            guard savedPCs.contains(where: { $0.id == profile.id }) || canAddNewPC else { throw OrbitProPCLimitError() }
            handshake = nil
            pairingExpiresAt = nil
            justPaired = true
            savePC(profile, token: credentials.apiToken)
            pairingTarget = nil
        } catch {
            guard pairingAttempt == attempt else { return }
            pairingError = error.localizedDescription
            handshake = nil
            pairingExpiresAt = nil
        }
    }

    func cancelPairing() {
        pairingAttempt = UUID()
        handshake = nil
        pairingTarget = nil
        pairingExpiresAt = nil
        pairingError = nil
        isPairing = false
        justPaired = false
    }

    // MARK: iPhone sync (iCloud KVS + Bonjour `_orbit-iphone._tcp`)

    func syncFromiPhone(silent: Bool = false) async {
        if !silent {
            isSyncingFromiPhone = true
            iPhoneSyncMessage = "Looking for your paired PC on iPhone (iCloud & local network)…"
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: "orbit.syncedPCs.v1"),
           let items = try? JSONDecoder().decode([MacSyncedPCItem].self, from: data), !items.isEmpty {
            importSyncedItems(items, source: "iCloud")
            isSyncingFromiPhone = false
            return
        }
        startiPhoneBrowser(silent: silent)
    }

    private func startiPhoneBrowser(silent: Bool) {
        iphoneBrowser?.cancel()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let nwBrowser = NWBrowser(for: .bonjour(type: "_orbit-iphone._tcp", domain: nil), using: parameters)
        iphoneBrowser = nwBrowser
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results { self?.fetchSyncedItems(from: result.endpoint) }
        }
        nwBrowser.start(queue: .main)
        if !silent {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.isSyncingFromiPhone else { return }
                self.isSyncingFromiPhone = false
                self.iPhoneSyncMessage = "No iPhone found. Open Orbit on your iPhone on the same network and try again, or pair directly below."
            }
        }
    }

    nonisolated private func fetchSyncedItems(from endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 2, maximumLength: 65_536) { data, _, _, _ in
                    connection.cancel()
                    guard let data, let items = try? JSONDecoder().decode([MacSyncedPCItem].self, from: data), !items.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        self?.importSyncedItems(items, source: "your iPhone")
                        self?.isSyncingFromiPhone = false
                    }
                }
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .global())
    }

    private func importSyncedItems(_ items: [MacSyncedPCItem], source: String) {
        let removed = OrbitPCCloudSync.removed()
        var imported = 0
        var preferred: String?
        for raw in items where !raw.address.isEmpty {
            let item = OrbitPCCloudSync.normalized(raw)
            let key = OrbitPCCloudSync.identity(of: item)
            if (removed[key] ?? 0) > (item.updatedAt ?? 0) { continue }
            if let index = savedPCs.firstIndex(where: { $0.syncIdentity == key }) {
                let local = savedPCs[index]
                guard (item.updatedAt ?? 0) > (local.updatedAt ?? 0) || MacTokenStore.token(for: local.id).isEmpty else { continue }
                var profile = MacSavedPC(from: item)
                profile.id = local.id
                profile.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(item.certificateFingerprint)
                if profile.certificateFingerprint.isEmpty { profile.certificateFingerprint = local.certificateFingerprint }
                if profile.name.isEmpty { profile.name = local.name }
                if !item.apiToken.isEmpty { MacTokenStore.save(item.apiToken, for: local.id) }
                guard profile != local else { continue }
                savedPCs[index] = profile
            } else {
                guard !item.apiToken.isEmpty else { continue }
                guard canAddNewPC else { continue }
                var profile = MacSavedPC(from: item)
                profile.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(item.certificateFingerprint)
                if profile.name.isEmpty { profile.name = "PC \(profile.address)" }
                MacTokenStore.save(item.apiToken, for: profile.id)
                savedPCs.append(profile)
            }
            if item.isSelected { preferred = savedPCs.first(where: { $0.syncIdentity == key })?.id }
            imported += 1
        }
        for profile in savedPCs where (removed[profile.syncIdentity] ?? 0) > (profile.updatedAt ?? 0) {
            MacTokenStore.remove(profile.id)
            savedPCs.removeAll { $0.id == profile.id }
            imported += 1
        }
        guard imported > 0 else { return }
        persistSavedPCs()
        iPhoneSyncMessage = "Imported \(imported) PC\(imported == 1 ? "" : "s") from \(source)."
        if let current = savedPCs.first(where: { $0.id == selectedPCID }) {
            if !metrics.isOnline { selectPC(current) }
        } else if let id = preferred ?? savedPCs.first?.id, let profile = savedPCs.first(where: { $0.id == id }) {
            selectPC(profile)
        }
    }
}
