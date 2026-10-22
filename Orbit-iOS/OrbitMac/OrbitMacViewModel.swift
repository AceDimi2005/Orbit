import AppKit
import Combine
import Darwin
import Foundation
import ImageIO
import Network
import Security
import SwiftUI
import UserNotifications

/// Keychain storage for per-PC pairing tokens (one generic-password item per PC id).
///
/// Items live in the data-protection keychain, which belongs to the app itself (team + bundle
/// id) and never shows the "OrbitMac wants to use your confidential information" password
/// prompt. Tokens that an earlier version stored in the login keychain are moved over on first
/// read, so the prompt can appear one last time at most.
enum MacTokenStore {
    private static let service = "OrbitMac.PairedPC.v1"

    private static func query(_ id: String, protected: Bool = true) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        if protected { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func read(_ id: String, protected: Bool) -> String? {
        var q = query(id, protected: protected)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func token(for id: String) -> String {
        if let token = read(id, protected: true) { return token }
        // Older builds kept the token in the login keychain; move it into the app's own keychain.
        guard let legacy = read(id, protected: false), !legacy.isEmpty else { return "" }
        save(legacy, for: id)
        SecItemDelete(query(id, protected: false) as CFDictionary)
        return legacy
    }

    static func save(_ value: String, for id: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
        SecItemDelete(query(id, protected: false) as CFDictionary)
    }
}

/// Central state for the Mac app. Every network call captures the connection
/// generation at the moment it starts, so switching PCs never lets a late reply
/// from the previous PC overwrite the new one.
@MainActor
final class OrbitMacViewModel: ObservableObject {
    // MARK: Profiles & navigation
    @Published var savedPCs: [MacSavedPC] = []
    @Published var selectedPCID: String = UserDefaults.standard.string(forKey: "mac.selectedPCID") ?? ""
    @Published var isDemoMode: Bool = UserDefaults.standard.bool(forKey: "mac.demoMode")
    /// Menu bar status item preferences live here instead of `@AppStorage` so the
    /// `MenuBarExtra(isInserted:)` binding can drop unchanged writes (see OrbitMacApp).
    @Published var menuBarEnabled: Bool = (UserDefaults.standard.object(forKey: "mac.menuBarEnabled") as? Bool) ?? true {
        didSet { if oldValue != menuBarEnabled { UserDefaults.standard.set(menuBarEnabled, forKey: "mac.menuBarEnabled") } }
    }
    @Published var menuBarMetric: String = UserDefaults.standard.string(forKey: "mac.menuBarMetric") ?? "cpu" {
        didSet { if oldValue != menuBarMetric { UserDefaults.standard.set(menuBarMetric, forKey: "mac.menuBarMetric") } }
    }
    /// Set by menu commands; `MacLibraryView` consumes it as soon as the Stream section shows.
    @Published var pendingStreamAction: MacStreamAction?
    @Published var selectedSection: MacSection = MacSection(rawValue: UserDefaults.standard.string(forKey: "mac.section") ?? "") ?? .overview {
        didSet { UserDefaults.standard.set(selectedSection.rawValue, forKey: "mac.section") }
    }
    @Published var dashboardMetrics: [MacMetric] = {
        let stored = UserDefaults.standard.stringArray(forKey: "mac.dashboardMetrics") ?? []
        let parsed = stored.compactMap(MacMetric.init(rawValue:))
        return parsed.isEmpty ? MacMetric.defaultDashboard : parsed
    }() {
        didSet { UserDefaults.standard.set(dashboardMetrics.map(\.rawValue), forKey: "mac.dashboardMetrics") }
    }

    // MARK: Telemetry
    @Published var metrics = MacPCMetrics()
    @Published var history = MacMetricHistory()
    @Published var peaks = MacSessionPeaks()
    @Published var pingMs = 0
    @Published var lastUpdated: Date?
    @Published var statusBanner = "Pair a PC or import one from your iPhone to get started"
    @Published var connectionError: String?
    @Published var isWaking = false
    @Published var specs: MacPCSpecs?
    @Published var isLoadingSpecs = false
    @Published var specsError: String?
    @Published var isDraggingVolume = false

    // MARK: Library, audio, processes, clipboard
    @Published var games: [MacSunshineGame] = []
    @Published var sunshineInfo: MacSunshineInfo?
    @Published var isLoadingGames = false
    @Published var audioSessions: [MacAudioSession] = []
    /// Windows app icons for process and audio rows, loaded on demand.
    let appIcons = OrbitAppIconStore()
    @Published var audioOutputs: [MacAudioOutput] = []
    @Published var audioRoutingAvailable = false
    @Published var audioRoutingReason: String?
    @Published var audioError: String?
    @Published var audioStatus: String?
    @Published var audioUpdated: Date?
    @Published var isLoadingAudio = false
    @Published var audioRoutingSessionID: String?
    @Published var defaultOutputSwitchAvailable = false
    @Published var defaultOutputSwitchReason: String?
    @Published var microphone: OrbitMicrophoneState?

    // Orbit Companion 5
    @Published var capabilities: OrbitCapabilities?
    @Published var power: OrbitPowerState?
    /// When `power` arrived, so countdowns can tick between refreshes.
    @Published var powerFetchedAt = Date()
    @Published var powerError: String?
    @Published var localCountdown: OrbitLocalCountdown?
    @Published var devices: [OrbitDevice] = []
    @Published var devicesError: String?
    @Published var isLoadingDevices = false
    @Published var library: OrbitLibrary?
    @Published var isLoadingLibrary = false
    @Published var activity: [OrbitActivityEntry] = []
    @Published var activityError: String?
    var libraryCovers: [String: NSImage] = [:]
    @Published var processes: [MacProcess] = []
    @Published var processesCapturedAt: Date?
    @Published var processGpuStatus: String?
    @Published var processesError: String?
    @Published var processActionStatus: String?
    @Published var isLoadingProcesses = false
    @Published var endingProcessID: Int?
    @Published var clipboardText = ""
    @Published var clipboardStatus: String?
    @Published var clipboardError: String?
    @Published var isClipboardBusy = false

    // MARK: Files
    @Published var fileRoots: MacFileRoots?
    @Published var filePath: String?
    @Published var fileParentPath: String?
    @Published var fileEntries: [MacFileEntry] = []
    @Published var fileTotal = 0
    @Published var fileTruncated = false
    @Published var fileSearch = ""
    @Published var fileSort: MacFileSort = .name
    @Published var isLoadingFiles = false
    @Published var filesError: String?
    @Published var filesNotice: String?
    @Published var fileFavorites: [MacFileFavorite] = []
    @Published var transfer: MacTransferState?
    @Published var canGoBack = false
    @Published var canGoForward = false
    var fileBackHistory: [String?] = []
    var fileForwardHistory: [String?] = []
    var transferTask: Task<Void, Never>?
    var transferID = UUID()
    var transferTotalBytes: Int64 = 0
    var transferLastBytes: Double = 0
    var transferLastTime = Date()

    // MARK: Session history
    @Published var historyList: MacHistoryList?
    @Published var isLoadingHistory = false
    @Published var historyError: String?
    @Published var isHistoryActing = false

    // MARK: Desktop preview stream
    @Published var previewFrame: NSImage?
    @Published var previewFPS: Double = 0
    @Published var isStreaming = false
    @Published var streamError: String?
    var streamTask: Task<Void, Never>?
    var streamSocket: URLSessionWebSocketTask?
    var streamClient: OrbitAPIClient?
    var frameTimestamps: [Date] = []

    // MARK: Discovery, pairing, iPhone sync
    @Published var discoveredPCs: [MacDiscoveredPC] = []
    @Published var isScanning = false
    @Published var isProbing = false
    @Published var pairingTarget: MacDiscoveredPC?
    @Published var pairingExpiresAt: Date?
    @Published var pairingLifetime: Double = 120
    @Published var isPairing = false
    @Published var pairingError: String?
    @Published var justPaired = false
    @Published var isSyncingFromiPhone = false
    @Published var iPhoneSyncMessage: String?
    var handshake: OrbitPairingHandshake?
    var browser: NWBrowser?
    var iphoneBrowser: NWBrowser?
    var pairingAttempt = UUID()

    // MARK: Agent updates
    @Published var agentLatestVersion: String?
    @Published var agentUpdateAvailable = false
    @Published var agentUpdateMessage: String?
    @Published var isCheckingUpdate = false

    // MARK: Internals
    var generation = 0
    var hasSyncedExtras = false
    var appActive = true
    var pollTask: Task<Void, Never>?
    var pendingVolume: Double?
    var volumeWorker: Task<Void, Never>?
    var lastVolumeChange: Date = .distantPast
    var inputSocket: URLSessionWebSocketTask?
    var inputClient: OrbitAPIClient?
    var inputHostKey = ""
    var audioPending: [String: MacAudioSessionChange] = [:]
    var audioWorker: Task<Void, Never>?
    var audioDragging: Set<String> = []
    var audioChanged: [String: Date] = [:]
    var wasOnline = false
    var lastSpecsAttempt: Date = .distantPast

    private static let savedPCsKey = "mac.savedPCs.v1"

    init() {
        loadSavedPCs()
        if isDemoMode { applyDemo() }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncFromiPhone(silent: true) }
        }
        startPolling()
        Task { await syncFromiPhone(silent: true) }
    }

    // MARK: - Profiles

    var currentPC: MacSavedPC? { savedPCs.first(where: { $0.id == selectedPCID }) ?? savedPCs.first }
    var isConfigured: Bool { currentPC != nil || isDemoMode }
    var selectedPCName: String { isDemoMode ? "Example PC" : (currentPC?.name ?? metrics.hostname) }

    func loadSavedPCs() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedPCsKey),
              let decoded = try? JSONDecoder().decode([MacSavedPC].self, from: data) else { return }
        savedPCs = decoded.map { profile in
            var copy = profile
            let resolved = OrbitPCCloudSync.normalizedAddress(address: profile.address, lastKnownIPv4: profile.lastKnownIPv4, bonjourHost: profile.bonjourHost)
            copy.address = resolved.address
            copy.bonjourHost = resolved.bonjourHost
            return copy
        }
        if selectedPCID.isEmpty, let first = decoded.first { selectedPCID = first.id }
    }

    /// Saves locally and publishes the result to iCloud (merged with the iPhone's and the Apple TV's copies).
    func persistSavedPCs(removing: [String] = []) {
        if let data = try? JSONEncoder().encode(savedPCs) { UserDefaults.standard.set(data, forKey: Self.savedPCsKey) }
        let items = savedPCs.map { $0.syncedItem(token: MacTokenStore.token(for: $0.id), selected: $0.id == selectedPCID) }
        OrbitPCCloudSync.publish(local: items, removing: removing)
    }

    /// Free users can keep one PC; Orbit Pro removes the limit.
    var canAddNewPC: Bool {
        OrbitProEntitlement.canAddPC(existingCount: savedPCs.count, isUnlocked: OrbitProStore.shared.isProUnlocked)
    }

    func savePC(_ profile: MacSavedPC, token: String?, select: Bool = true) {
        guard savedPCs.contains(where: { $0.id == profile.id }) || canAddNewPC else {
            statusBanner = OrbitProPCLimitError().errorDescription ?? ""
            return
        }
        var cleaned = profile
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.address = cleaned.address.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(cleaned.certificateFingerprint)
        if let token, !token.isEmpty { MacTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: cleaned.id) }
        if let previous = savedPCs.first(where: { $0.id == cleaned.id }), previous != cleaned { cleaned.updatedAt = Date().timeIntervalSince1970 }
        if cleaned.updatedAt == nil { cleaned.updatedAt = Date().timeIntervalSince1970 }
        if let index = savedPCs.firstIndex(where: { $0.id == cleaned.id }) { savedPCs[index] = cleaned } else { savedPCs.append(cleaned) }
        persistSavedPCs()
        if select { selectPC(cleaned) }
    }

    func selectPC(_ profile: MacSavedPC) {
        if isDemoMode { isDemoMode = false; UserDefaults.standard.set(false, forKey: "mac.demoMode") }
        selectedPCID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "mac.selectedPCID")
        resetConnection()
        statusBanner = "Connecting to \(profile.name)…"
        Task { await refreshMetrics() }
    }

    func removePC(_ profile: MacSavedPC) {
        MacTokenStore.remove(profile.id)
        savedPCs.removeAll { $0.id == profile.id }
        persistSavedPCs(removing: [profile.syncIdentity])
        if selectedPCID == profile.id {
            selectedPCID = savedPCs.first?.id ?? ""
            UserDefaults.standard.set(selectedPCID, forKey: "mac.selectedPCID")
            resetConnection()
            Task { await refreshMetrics() }
        }
    }

    func token(for profile: MacSavedPC) -> String { MacTokenStore.token(for: profile.id) }

    func client(for pc: MacSavedPC? = nil) throws -> OrbitAPIClient {
        guard !isDemoMode else { throw OrbitError(message: "Pair a real PC to use this feature. Demo mode only simulates telemetry.") }
        guard let target = pc ?? currentPC else { throw OrbitError(message: "Pair your PC first in PCs.") }
        let token = MacTokenStore.token(for: target.id)
        return try OrbitAPIClient(host: target.address, port: target.securePort, token: token, fingerprint: target.certificateFingerprint)
    }

    /// Points the shared icon store at the current PC (process table and audio mixer rows).
    func prepareAppIcons() {
        guard !isDemoMode, let pc = currentPC else { appIcons.reset(); return }
        let version = generation
        appIcons.configure(scope: "\(pc.id)#\(version)") { [weak self] ids in
            guard let self, self.generation == version else { throw CancellationError() }
            return try await self.client(for: pc).get("/api/icons", query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))])
        }
    }

    /// Bumps the generation so in-flight replies for the previous PC are discarded.
    func resetConnection() {
        generation += 1
        appIcons.reset()
        hasSyncedExtras = false
        metrics = MacPCMetrics()
        if let pc = currentPC { metrics.hostname = pc.name }
        history.reset()
        peaks = MacSessionPeaks()
        pingMs = 0
        lastUpdated = nil
        isLoadingSpecs = false; isLoadingGames = false; isLoadingAudio = false
        isLoadingProcesses = false; isLoadingHistory = false; isHistoryActing = false
        isClipboardBusy = false; endingProcessID = nil; audioRoutingSessionID = nil
        connectionError = nil
        specs = nil
        specsError = nil
        lastSpecsAttempt = .distantPast
        games = []; sunshineInfo = nil
        audioSessions = []; audioOutputs = []; audioRoutingAvailable = false; audioRoutingReason = nil; audioError = nil; audioStatus = nil; audioUpdated = nil
        audioPending = [:]; audioWorker?.cancel(); audioWorker = nil; audioDragging = []; audioChanged = [:]
        defaultOutputSwitchAvailable = false; defaultOutputSwitchReason = nil; microphone = nil
        capabilities = nil; power = nil; powerError = nil; localCountdown = nil; devices = []; devicesError = nil; isLoadingDevices = false
        library = nil; isLoadingLibrary = false; activity = []; activityError = nil; libraryCovers = [:]
        processes = []; processesCapturedAt = nil; processGpuStatus = nil; processesError = nil; processActionStatus = nil
        clipboardStatus = nil; clipboardError = nil
        historyList = nil; historyError = nil
        resetFiles()
        stopPreview()
        previewFrame = nil
        streamError = nil
        closeInputSocket()
        pendingVolume = nil; volumeWorker?.cancel(); volumeWorker = nil
        agentUpdateAvailable = false; agentLatestVersion = nil; agentUpdateMessage = nil
        wasOnline = false
    }

    // MARK: - Demo mode

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        UserDefaults.standard.set(enabled, forKey: "mac.demoMode")
        resetConnection()
        if enabled {
            applyDemo()
        } else {
            statusBanner = currentPC.map { "Connecting to \($0.name)…" } ?? "Pair a PC or import one from your iPhone to get started"
            Task { await refreshMetrics() }
        }
    }

    private func applyDemo() {
        metrics = .demo
        specs = .demo
        pingMs = 2
        lastUpdated = Date()
        statusBanner = "Demo mode · simulated data"
        games = [
            MacSunshineGame(id: "demo-1", title: "Example game", genre: "Simulated preview", iconSymbol: "gamecontroller.fill", accentHex: "5EDBD5"),
            MacSunshineGame(id: "demo-2", title: "Example launcher", genre: "Simulated preview", iconSymbol: "tv.and.mediabox.fill", accentHex: "9D7BFF")
        ]
        audioSessions = [
            MacAudioSession(id: "demo-1", pid: 4100, name: "Example game", volume: 80, isMuted: false, processCreateTime: 1, outputDeviceID: "out-1", outputDeviceName: "Speakers (Example)", isActive: true, kind: "app"),
            MacAudioSession(id: "demo-2", pid: 5210, name: "Voice chat", volume: 65, isMuted: false, processCreateTime: 2, outputDeviceID: "out-2", outputDeviceName: "Headset (Example)", isActive: false, kind: "app"),
            MacAudioSession(id: "demo-3", pid: 6320, name: "Music player", volume: 45, isMuted: true, processCreateTime: 3, outputDeviceID: "out-1", outputDeviceName: "Speakers (Example)", isActive: true, kind: "background")
        ]
        audioOutputs = [MacAudioOutput(id: "out-1", name: "Speakers (Example)"), MacAudioOutput(id: "out-2", name: "Headset (Example)")]
        audioRoutingAvailable = true
        audioUpdated = Date()
        processes = [
            MacProcess(pid: 4100, name: "ExampleGame.exe", createTime: 1, memoryMB: 2840, cpuPercent: 14.2, gpuPercent: 62.0, vramMB: 3100, status: "running", canTerminate: true),
            MacProcess(pid: 4200, name: "ExampleBrowser.exe", createTime: 2, memoryMB: 620, cpuPercent: 2.8, gpuPercent: 1.1, vramMB: 180, status: "running", canTerminate: true),
            MacProcess(pid: 4, name: "System", createTime: 0, memoryMB: 120, cpuPercent: 0.4, status: "running", canTerminate: false)
        ]
        processesCapturedAt = Date()
        processGpuStatus = "Preview processes · simulated readings"
        history.reset()
        for _ in 0..<20 { applyDemoDrift() }
    }

    private func applyDemoDrift() {
        guard isDemoMode, metrics.isOnline else { return }
        func drift(_ value: Double, by amount: Double, in range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, value + Double.random(in: -amount...amount)))
        }
        metrics.cpuUsage = drift(metrics.cpuUsage, by: 3, in: 6...92).rounded()
        metrics.gpuUsage = metrics.gpuUsage.map { drift($0, by: 3, in: 10...96).rounded() }
        metrics.fps = metrics.fps.map { drift($0, by: 4, in: 90...144).rounded() }
        metrics.cpuPowerWatts = metrics.cpuPowerWatts.map { drift($0, by: 4, in: 35...110).rounded() }
        metrics.gpuPowerWatts = metrics.gpuPowerWatts.map { drift($0, by: 8, in: 60...280).rounded() }
        metrics.cpuTemp = metrics.cpuTemp.map { drift($0, by: 1, in: 40...70).rounded() }
        metrics.gpuTemp = metrics.gpuTemp.map { drift($0, by: 1, in: 45...75).rounded() }
        metrics.networkDownloadMBps = metrics.networkDownloadMBps.map { max(0.1, drift($0, by: 2.5, in: 0.1...60)) }
        metrics.diskReadMBps = metrics.diskReadMBps.map { max(0.1, drift($0, by: 6, in: 0.1...200)) }
        metrics.uptimeSeconds += 2
        history.append(metrics)
        peaks.observe(metrics)
        lastUpdated = Date()
    }

    // MARK: - Polling

    var refreshInterval: Double {
        let stored = UserDefaults.standard.double(forKey: "mac.refreshInterval")
        return stored >= 1 ? stored : 2
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if active { startPolling() }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetrics()
                let interval = self?.refreshInterval ?? 2
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func refreshMetrics() async {
        if isDemoMode { applyDemoDrift(); return }
        guard let pc = currentPC else {
            metrics.isOnline = false
            statusBanner = "Pair a PC or import one from your iPhone to get started"
            return
        }
        let version = generation
        let start = Date()
        do {
            let apiClient = try client(for: pc)
            let fetched: MacPCMetrics = try await apiClient.get("/api/status")
            guard version == generation, !Task.isCancelled else { return }
            let sliderVolume = metrics.volume
            metrics = fetched
            if isDraggingVolume || pendingVolume != nil || Date().timeIntervalSince(lastVolumeChange) < 2 { metrics.volume = sliderVolume }
            history.append(fetched)
            peaks.observe(fetched)
            pingMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
            lastUpdated = Date()
            connectionError = nil
            statusBanner = "Connected to \(pc.name) · \(pingMs) ms"
            if !wasOnline {
                wasOnline = true
                notifyIfNeeded(title: "\(pc.name) is online", body: "Orbit reconnected to your PC.")
            }
            if !hasSyncedExtras {
                hasSyncedExtras = true
                await fetchNetworkConfig()
                guard version == generation else { return }
                await refreshGames()
            }
            if specs == nil, Date().timeIntervalSince(lastSpecsAttempt) > 30 { await fetchSpecs() }
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            metrics.isOnline = false
            metrics.fps = nil
            pingMs = 0
            wasOnline = false
            hasSyncedExtras = false
            connectionError = (error as? OrbitError)?.message ?? error.localizedDescription
            statusBanner = "\(pc.name) is offline · \(connectionError ?? "unreachable")"
            if isStreaming { stopPreview() }
        }
    }

    func fetchNetworkConfig() async {
        guard !isDemoMode, let pc = currentPC else { return }
        let version = generation
        do {
            let info: MacNetworkConfig = try await client(for: pc).get("/api/network-info")
            guard version == generation, let index = savedPCs.firstIndex(where: { $0.id == pc.id }) else { return }
            if !info.macAddress.isEmpty { savedPCs[index].macAddress = info.macAddress }
            if !info.subnetMask.isEmpty { savedPCs[index].subnetMask = info.subnetMask }
            if savedPCs[index].autoCalcBroadcast && !info.broadcastAddress.isEmpty { savedPCs[index].broadcastAddress = info.broadcastAddress }
            if !info.ipAddress.isEmpty { savedPCs[index].lastKnownIPv4 = info.ipAddress }
            if !info.hostname.isEmpty && savedPCs[index].name.isEmpty { savedPCs[index].name = info.hostname }
            persistSavedPCs()
        } catch {}
    }

    func fetchSpecs() async {
        guard !isLoadingSpecs else { return }
        if isDemoMode { specs = .demo; specsError = nil; return }
        guard metrics.isOnline, let pc = currentPC else { return }
        isLoadingSpecs = true
        specsError = nil
        lastSpecsAttempt = Date()
        defer { isLoadingSpecs = false }
        let version = generation
        do {
            let result: MacPCSpecs = try await client(for: pc).get("/api/specs")
            guard version == generation else { return }
            specs = result
        } catch {
            guard version == generation else { return }
            specsError = "Could not read specifications. Check that the Orbit Agent is up to date."
        }
    }

    // MARK: - Power & actions

    private static let actionAliases: [String: String] = [
        "play_pause": "media_play_pause", "next_track": "media_next", "prev_track": "media_prev"
    ]

    @discardableResult
    func sendAction(_ rawAction: String) async -> Bool {
        let action = Self.actionAliases[rawAction] ?? rawAction
        let label = action.replacingOccurrences(of: "media_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        if isDemoMode {
            if ["shutdown", "sleep", "restart"].contains(action) { metrics.isOnline = false }
            if action == "mute" { metrics.isMuted.toggle() }
            if action == "kill_game" { metrics.activeGame = nil; metrics.fps = nil }
            statusBanner = "Demo · \(label)"
            return true
        }
        guard metrics.isOnline else { statusBanner = "Connect to your PC first."; return false }
        let version = generation
        do {
            _ = try await client().data("/api/action/\(action)", method: "POST")
            guard version == generation else { return false }
            statusBanner = "Sent \(label) to \(currentPC?.name ?? "PC")"
            if ["shutdown", "restart"].contains(action), has("power.countdown") {
                // Windows waits 30 seconds and the PC stays online meanwhile, so Cancel still works.
                localCountdown = OrbitLocalCountdown(action: action, until: Date().addingTimeInterval(30))
            } else if ["shutdown", "sleep", "restart"].contains(action) {
                metrics.isOnline = false
                wasOnline = false
                stopPreview()
            } else if action == "mute" {
                metrics.isMuted.toggle()
            }
            return true
        } catch {
            guard version == generation else { return false }
            statusBanner = "\(label) failed: \(error.localizedDescription)"
            return false
        }
    }

    func wakePC() async {
        guard !isWaking else { return }
        isWaking = true
        defer { isWaking = false }
        if isDemoMode { metrics = .demo; statusBanner = "Demo · Wake-on-LAN simulated"; return }
        guard let pc = currentPC else { statusBanner = "Pair your PC first to save its MAC address."; return }
        let cleaned = pc.macAddress.filter { !":-. ".contains($0) }
        guard cleaned.count == 12 else {
            statusBanner = "Connect to \(pc.name) once while it is on so Orbit can save its MAC address."
            return
        }
        var mac: [UInt8] = []
        let chars = Array(cleaned)
        for i in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { statusBanner = "The saved MAC address is invalid."; return }
            mac.append(byte)
        }
        let packet = Array(repeating: UInt8(255), count: 6) + Array(repeating: mac, count: 16).flatMap { $0 }
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { statusBanner = "Could not open a Wake-on-LAN socket."; return }
        defer { Darwin.close(sock) }
        var enabled: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var targets = Set([pc.broadcastAddress, pc.lastKnownIPv4, pc.address, "255.255.255.255"]).filter { !$0.isEmpty }
        if pc.broadcastAddress.isEmpty, !pc.lastKnownIPv4.isEmpty {
            targets.insert(Self.broadcast(ip: pc.lastKnownIPv4, mask: pc.subnetMask))
        }
        var sent = false
        let port = UInt16(max(1, min(65535, pc.wolPort)))
        var addresses = targets.compactMap { OrbitWakeTargets.resolve($0, defaultPort: port).first }
        if !pc.wolRelay.isEmpty { addresses += OrbitWakeTargets.resolve(pc.wolRelay, defaultPort: port) }
        for var addr in addresses {
            for _ in 0..<3 {
                let count = packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.sendto(sock, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent = sent || count == packet.count
            }
        }
        guard sent else { statusBanner = "Wake packet could not be sent. Check the Mac's network connection."; return }
        statusBanner = "Wake-on-LAN sent to \(pc.name) · waiting for the PC…"
        let version = generation
        for _ in 0..<15 {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard version == generation else { return }
            await refreshMetrics()
            if metrics.isOnline { statusBanner = "\(pc.name) is online"; return }
        }
        statusBanner = "Wake packet sent, but \(pc.name) has not responded yet. Check BIOS and adapter Wake-on-LAN settings."
    }

    static func broadcast(ip: String, mask: String) -> String {
        var address = in_addr(), netmask = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1, inet_pton(AF_INET, mask, &netmask) == 1 else { return "" }
        var result = in_addr(s_addr: address.s_addr | ~netmask.s_addr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &result, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }

    // MARK: - Volume (coalesced)

    func setVolume(_ value: Double) {
        guard value.isFinite, metrics.isOnline, metrics.volumeAvailable != false else { return }
        let level = min(100, max(0, value)).rounded()
        metrics.volume = level
        lastVolumeChange = Date()
        guard !isDemoMode else { return }
        pendingVolume = level
        guard volumeWorker == nil else { return }
        let version = generation
        volumeWorker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == version, let next = self.pendingVolume else { break }
                self.pendingVolume = nil
                if let apiClient = try? self.client() {
                    _ = try? await apiClient.data("/api/volume", method: "POST", query: [URLQueryItem(name: "level", value: "\(Int(next))")])
                }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
            self?.volumeWorker = nil
        }
    }

    func adjustVolume(by delta: Double) {
        setVolume(metrics.volume + delta)
    }

    // MARK: - Input

    func closeInputSocket() {
        inputSocket?.cancel(with: .goingAway, reason: nil)
        inputSocket = nil
        inputClient = nil
        inputHostKey = ""
    }

    /// Low-latency cursor path: a persistent `/ws/input` socket with HTTP fallback.
    func sendCursor(dx: Int = 0, dy: Int = 0, click: String = "", scroll: Int = 0, hscroll: Int = 0, normX: Double? = nil, normY: Double? = nil, drag: String = "") async {
        guard !isDemoMode, metrics.isOnline, let pc = currentPC else { return }
        let key = "\(pc.id):\(pc.address):\(pc.securePort)"
        if inputSocket == nil || inputHostKey != key {
            closeInputSocket()
            inputHostKey = key
            if let apiClient = try? client(for: pc), let socket = try? apiClient.inputWebSocket() {
                inputClient = apiClient
                inputSocket = socket
                socket.resume()
            }
        }
        var json: [String: Any] = ["dx": dx, "dy": dy, "click": click, "scroll": scroll, "hscroll": hscroll, "drag": drag]
        if let normX, let normY { json["normX"] = normX; json["normY"] = normY }
        if let socket = inputSocket,
           let data = try? JSONSerialization.data(withJSONObject: json),
           let text = String(data: data, encoding: .utf8) {
            do {
                try await socket.send(.string(text))
                return
            } catch {
                closeInputSocket()
            }
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "dx", value: "\(dx)"), URLQueryItem(name: "dy", value: "\(dy)"),
            URLQueryItem(name: "click", value: click), URLQueryItem(name: "scroll", value: "\(scroll)"),
            URLQueryItem(name: "hscroll", value: "\(hscroll)"), URLQueryItem(name: "drag", value: drag)
        ]
        if let normX, let normY {
            items.append(URLQueryItem(name: "normX", value: String(format: "%.4f", normX)))
            items.append(URLQueryItem(name: "normY", value: String(format: "%.4f", normY)))
        }
        _ = try? await client(for: pc).data("/api/input/cursor", method: "POST", query: items)
    }

    /// Text and the agent's supported special keys: ENTER, BACKSPACE, SPACE, ESC, WIN, TAB.
    func sendKeyboard(text: String = "", key: String = "") async {
        guard !isDemoMode, metrics.isOnline, !(text.isEmpty && key.isEmpty) else { return }
        let version = generation
        do {
            _ = try await client().data("/api/input/keyboard", method: "POST", query: [URLQueryItem(name: "text", value: text), URLQueryItem(name: "key", value: key)])
        } catch {
            if version == generation { statusBanner = "Keyboard input failed: \(error.localizedDescription)" }
        }
    }

    func sendGamepad(_ button: String) async {
        guard !isDemoMode, metrics.isOnline else { return }
        _ = try? await client().data("/api/input/gamepad", method: "POST", query: [URLQueryItem(name: "button", value: button)])
    }

    // MARK: - Desktop preview (JPEG frames over /ws/stream)

    func startPreview() {
        stopPreview()
        streamError = nil
        guard !isDemoMode else { streamError = "Desktop preview needs a paired PC; demo mode only simulates telemetry."; return }
        guard metrics.isOnline else { streamError = "Connect to your PC to start the desktop preview."; return }
        do {
            let apiClient = try client()
            let socket = try apiClient.webSocket()
            streamClient = apiClient
            streamSocket = socket
            isStreaming = true
            frameTimestamps = []
            socket.resume()
            let version = generation
            streamTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard !Task.isCancelled, self != nil, self?.generation == version else { break }
                        guard case .data(let data) = message else { continue }
                        // Decoding happens off the main actor; the receive loop waits for it,
                        // so frames never pile up faster than they can be shown.
                        let decoded = await Self.decodeFrame(data)
                        guard !Task.isCancelled, let self, self.generation == version else { break }
                        if let image = decoded?.image {
                            self.previewFrame = image
                            let now = Date()
                            self.frameTimestamps.append(now)
                            self.frameTimestamps.removeAll { now.timeIntervalSince($0) > 2 }
                            self.previewFPS = Double(self.frameTimestamps.count) / 2
                        }
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.generation == version else { return }
                    self.streamError = "Desktop preview disconnected. Check the PC capture permission and that the agent is running."
                    self.isStreaming = false
                }
            }
        } catch {
            streamError = error.localizedDescription
            isStreaming = false
        }
    }

    /// `NSImage(data:)` only parses the header and leaves the expensive JPEG decode to
    /// the first draw on the main thread, which stalls the UI at high frame rates.
    /// Forcing the decode through ImageIO on a background task keeps the window responsive.
    struct DecodedFrame: @unchecked Sendable { let image: NSImage }
    nonisolated static func decodeFrame(_ data: Data) async -> DecodedFrame? {
        await Task.detached(priority: .userInitiated) {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            return DecodedFrame(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        }.value
    }

    func stopPreview() {
        streamTask?.cancel(); streamTask = nil
        streamSocket?.cancel(with: .goingAway, reason: nil); streamSocket = nil
        streamClient = nil
        isStreaming = false
        previewFPS = 0
    }

    // MARK: - Notifications

    func notifyIfNeeded(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: "mac.notifyOnline") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Agent updates

    func checkAgentUpdate() async {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        agentUpdateMessage = nil
        defer { isCheckingUpdate = false }
        struct Reply: Decodable { let currentVersion: String?; let latestVersion: String?; let updateAvailable: Bool?; let releaseTitle: String? }
        if isDemoMode { agentLatestVersion = metrics.agentVersion; agentUpdateAvailable = false; agentUpdateMessage = "Up to date (demo)."; return }
        guard metrics.isOnline else { agentUpdateMessage = "Connect to your PC first, or check github.com/AceDimi2005/Orbit."; return }
        do {
            let info: Reply = try await client().get("/api/update/check")
            agentLatestVersion = info.latestVersion
            agentUpdateAvailable = info.updateAvailable == true
            agentUpdateMessage = info.updateAvailable == true
                ? "Update \(info.latestVersion ?? "") is available on GitHub."
                : "PC Companion is up to date (\(info.currentVersion ?? metrics.agentVersion ?? "—"))."
        } catch {
            agentUpdateMessage = "Could not check for updates: \(error.localizedDescription)"
        }
    }

    func applyAgentUpdate() async {
        guard !isCheckingUpdate, metrics.isOnline, !isDemoMode else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        struct Reply: Decodable { let status: String?; let latestVersion: String? }
        do {
            let result: Reply = try await client().send("/api/update/apply", body: MacHistoryEmptyBody())
            agentUpdateAvailable = false
            agentUpdateMessage = result.status == "updated"
                ? "Updated to \(result.latestVersion ?? "latest"). Restart the PC Companion from the Windows tray."
                : "Already running the latest version."
        } catch {
            agentUpdateMessage = "Update failed: \(error.localizedDescription)"
        }
    }
}
