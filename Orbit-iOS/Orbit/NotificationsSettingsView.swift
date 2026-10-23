import SwiftUI
import UIKit
import UserNotifications

// MARK: - Model for the selected PC's automation settings

/// What the notifications screen shows for the selected PC: features, alert settings (`/api/alerts`),
/// downloads, the "sleep when finished" rule and watched apps. Demo mode fills it with sample data and
/// never calls a PC.
@MainActor
final class OrbitPCAutomationModel: ObservableObject {
    @Published private(set) var features: OrbitPCFeatures = .unknown
    @Published private(set) var featuresError: String?
    @Published private(set) var alerts: OrbitAlertSettings?
    @Published private(set) var alertsError: String?
    @Published private(set) var isSavingAlerts = false
    @Published private(set) var downloads: OrbitPCDownloads?
    @Published private(set) var downloadsError: String?
    @Published private(set) var rule: OrbitPowerRule?
    @Published private(set) var powerError: String?
    @Published private(set) var tasks: [OrbitWatchedTask] = []
    @Published private(set) var tasksLoaded = false
    @Published private(set) var tasksError: String?
    @Published private(set) var pushStatus: OrbitPushStatus?
    @Published private(set) var isWorking = false
    @Published var notice: String?
    private(set) var link: OrbitPCLink?
    private(set) var isDemo = false
    private var generation = 0
    private var saveTask: Task<Void, Never>?

    var pcID: String { link?.id ?? "" }

    /// True while the features or the alert settings are still missing for a real PC.
    var needsSettings: Bool {
        guard !isDemo, link != nil else { return false }
        return !features.isKnown || (features.has("alerts") && alerts == nil)
    }

    func configure(_ vm: OrbitViewModel) {
        generation += 1
        saveTask?.cancel(); saveTask = nil
        features = .unknown; featuresError = nil
        alerts = nil; alertsError = nil; isSavingAlerts = false
        downloads = nil; downloadsError = nil
        rule = nil; powerError = nil
        tasks = []; tasksLoaded = false; tasksError = nil
        pushStatus = nil; notice = nil
        isDemo = vm.isDemoMode
        link = OrbitPCLink.current(vm)
        if isDemo { loadDemo() }
    }

    /// Features, alert settings and push status: read once per screen visit.
    func loadSettings() async {
        guard !isDemo, let link else { return }
        let version = generation
        do {
            let found = try await OrbitFeatureStore.shared.features(for: link, maxAge: 30)
            guard version == generation else { return }
            features = found
            featuresError = nil
        } catch {
            guard version == generation else { return }
            featuresError = OrbitPlainError.describe(error)
            return
        }
        if features.has("alerts") {
            do {
                let raw: OrbitJSON = try await link.client.get("/api/alerts")
                guard version == generation else { return }
                alerts = OrbitAlertSettings(raw: raw)
                alertsError = nil
            } catch {
                guard version == generation else { return }
                alertsError = "Couldn't read the PC's alert settings. \(OrbitPlainError.describe(error))"
            }
        }
        await refreshPushStatus()
    }

    func refreshPushStatus() async {
        guard !isDemo, let link, features.has("push") else { return }
        let version = generation
        if let status: OrbitPushStatus = try? await link.client.get("/api/push/status"), version == generation {
            pushStatus = status
        }
    }

    /// Downloads, the power rule and watched apps: refreshed every few seconds while visible.
    func refreshLive() async {
        guard !isDemo, let link, features.isKnown else { return }
        let version = generation
        if features.has("downloads") {
            do {
                let reply: OrbitPCDownloads = try await link.client.get("/api/downloads")
                guard version == generation else { return }
                downloads = reply; downloadsError = nil
            } catch {
                guard version == generation else { return }
                downloadsError = OrbitPlainError.describe(error)
            }
        }
        if features.has("powerAfter") {
            do {
                let reply: OrbitPowerAfter = try await link.client.get("/api/power/after")
                guard version == generation else { return }
                rule = reply.rule; powerError = nil
            } catch {
                guard version == generation else { return }
                powerError = OrbitPlainError.describe(error)
            }
        }
        if features.has("tasks") {
            do {
                let reply: OrbitWatchedTasks = try await link.client.get("/api/tasks")
                guard version == generation else { return }
                tasks = reply.tasks; tasksLoaded = true; tasksError = nil
            } catch {
                guard version == generation else { return }
                tasksError = OrbitPlainError.describe(error)
            }
        }
    }

    /// Saves alert settings on the PC half a second after the last change.
    func updateAlerts(_ settings: OrbitAlertSettings) {
        alerts = settings
        alertsError = nil
        saveTask?.cancel()
        guard !isDemo, let link else { return }
        let version = generation
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, version == self.generation else { return }
            self.isSavingAlerts = true
            defer { if version == self.generation { self.isSavingAlerts = false } }
            do {
                let saved: OrbitJSON = try await link.client.send("/api/alerts", method: "PUT", body: settings.raw)
                guard version == self.generation, !Task.isCancelled else { return }
                if case .object = saved, saved["temperature"] != nil { self.alerts = OrbitAlertSettings(raw: saved) }
            } catch {
                guard version == self.generation, !Task.isCancelled else { return }
                self.alertsError = "Not saved on the PC. \(OrbitPlainError.describe(error))"
            }
        }
    }

    /// "Sleep / Shut down when downloads finish" (or when a watched app finishes).
    @discardableResult
    func schedulePower(action: String, trigger: String = "downloads", taskID: String? = nil, delaySeconds: Int = 60) async -> Bool {
        if isDemo {
            rule = OrbitPowerRule(trigger: trigger, taskID: taskID, action: action, delaySeconds: delaySeconds, state: "waiting", countdownEndsAt: nil)
            notice = "Demo mode: nothing was sent to a PC."
            return true
        }
        guard let link, !isWorking else { return false }
        let version = generation
        isWorking = true
        defer { if version == generation { isWorking = false } }
        do {
            let request = OrbitPowerAfterRequest(trigger: trigger, action: action, delaySeconds: delaySeconds, taskID: taskID)
            let _: OrbitJSON = try await link.client.send("/api/power/after", method: "PUT", body: request)
            guard version == generation else { return false }
            powerError = nil
            await refreshLive()
            return true
        } catch {
            guard version == generation else { return false }
            powerError = OrbitPlainError.describe(error)
            return false
        }
    }

    func cancelPower() async {
        if isDemo { rule = nil; return }
        guard let link else { return }
        let version = generation
        isWorking = true
        defer { if version == generation { isWorking = false } }
        do {
            _ = try await link.client.data("/api/power/after", method: "DELETE")
            guard version == generation else { return }
            rule = nil; powerError = nil
            OrbitHaptics.success()
        } catch let error as OrbitError where error.statusCode == 404 {
            // Nothing left to cancel: the rule already ended.
            guard version == generation else { return }
            rule = nil; powerError = nil
        } catch {
            guard version == generation else { return }
            powerError = "Couldn't cancel. \(OrbitPlainError.describe(error))"
            OrbitHaptics.error()
        }
    }

    func stopWatching(_ task: OrbitWatchedTask) async {
        if isDemo { tasks.removeAll { $0.id == task.id }; return }
        guard let link else { return }
        let version = generation
        do {
            let path = "/api/tasks/" + (task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? task.id)
            _ = try await link.client.data(path, method: "DELETE")
            guard version == generation else { return }
            tasks.removeAll { $0.id == task.id }
            tasksError = nil
        } catch {
            guard version == generation else { return }
            tasksError = "Couldn't stop watching \(task.label). \(OrbitPlainError.describe(error))"
        }
    }

    private func loadDemo() {
        features = .available(agentVersion: "4.4.0", features: ["events", "alerts", "downloads", "tasks", "powerAfter", "push", "summary"])
        alerts = .fallback
        downloads = OrbitPCDownloads(downloads: [
            .init(id: "steam:620", store: "steam", name: "Portal 2", state: "downloading", progress: 0.42, bytesDone: 5_200_000_000, bytesTotal: 12_400_000_000, updatedAt: nil),
            .init(id: "epic:Fortnite", store: "epic", name: "Fortnite", state: "queued", progress: 0, bytesDone: 0, bytesTotal: 31_000_000_000, updatedAt: nil)
        ], active: true, stores: ["steam": true, "epic": true, "gog": false])
        tasks = [OrbitWatchedTask(id: "demo-render", pid: 4300, label: "Premiere Pro", mode: "idle", state: "watching",
                                  startedAt: OrbitEventFeed.isoString(Date().addingTimeInterval(-1260)), finishedAt: nil)]
        tasksLoaded = true
    }
}

extension OrbitEventFeed {
    static func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

// MARK: - Watching an app from Task Manager

enum OrbitTaskWatch {
    /// "Notify Me When It Finishes" / "Sleep When It Finishes" on a Task Manager row.
    /// Returns the sentence to show under the process list.
    @MainActor
    static func watch(_ process: PCProcess, mode: String, sleepAfter: Bool, vm: OrbitViewModel) async -> (message: String, ok: Bool) {
        let label = displayName(process.name)
        if vm.isDemoMode { return ("Demo mode: Orbit would watch \(label) on a real PC.", true) }
        guard let link = OrbitPCLink.current(vm) else {
            return ("Pair \(vm.selectedPCName) again in My PCs to watch apps (it needs Orbit's encrypted connection).", false)
        }
        if !sleepAfter, !OrbitNotificationPreferences.isEnabled, let problem = await OrbitNotificationSwitch.enable() {
            return (problem, false)
        }
        do {
            let features = try await OrbitFeatureStore.shared.features(for: link)
            guard features.has("tasks") else {
                return ("Update Orbit PC Companion on \(link.name) to watch apps.", false)
            }
            if sleepAfter, !features.has("powerAfter") {
                return ("Update Orbit PC Companion on \(link.name) to sleep when an app finishes.", false)
            }
            let body = OrbitNewWatchedTask(pid: process.pid, createTime: process.createTime, mode: mode,
                                           idleMinutes: mode == "idle" ? 2 : nil, label: label)
            let task: OrbitWatchedTask = try await link.client.send("/api/tasks", body: body)
            if sleepAfter {
                let rule = OrbitPowerAfterRequest(trigger: "task", action: "sleep", delaySeconds: 60, taskID: task.id)
                let _: OrbitJSON = try await link.client.send("/api/power/after", method: "PUT", body: rule)
                return ("\(link.name) will sleep a minute after \(label) \(mode == "idle" ? "goes idle" : "closes"). Cancel it in Tools › Notifications.", true)
            }
            return ("Orbit will tell you when \(label) \(mode == "idle" ? "goes idle" : "closes").", true)
        } catch {
            return ("Couldn't watch \(label). \(OrbitPlainError.describe(error))", false)
        }
    }

    static func displayName(_ processName: String) -> String {
        let trimmed = processName.hasSuffix(".exe") || processName.hasSuffix(".EXE") ? String(processName.dropLast(4)) : processName
        return trimmed.isEmpty ? processName : trimmed
    }
}

// MARK: - Screen

struct NotificationsSettingsView: View {
    @ObservedObject var vm: OrbitViewModel
    var showsDoneButton = false
    @StateObject private var model = OrbitPCAutomationModel()
    @ObservedObject private var registrar = OrbitPushRegistrar.shared
    @AppStorage(OrbitNotificationPreferences.enabledKey) private var enabled = false
    @State private var authorization: UNAuthorizationStatus?
    @State private var timeSensitive: UNNotificationSetting?
    @State private var switchError: String?
    @State private var isSwitching = false
    @State private var pendingPowerAction: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.orbitTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var pcName: String { vm.isDemoMode ? vm.metrics.hostname : vm.selectedPCName }
    private var isOnline: Bool { vm.isDemoMode || vm.metrics.isOnline }
    private var features: OrbitPCFeatures { model.features }

    var body: some View {
        Form {
            headerSection
            phoneSection
            if enabled && !vm.isDemoMode { deliverySection }
            statusNotices
            if features.has("alerts") { alertKindsSection.id("alerts") }
            if features.has("downloads") { downloadsSection.id("downloads") }
            if features.has("powerAfter"), model.rule != nil || model.powerError != nil { powerSection.id("power") }
            if features.has("tasks") { tasksSection.id("tasks") }
        }
        #if DEBUG
        // `ORBIT_SELFTEST_SCROLL=downloads|power|tasks|alerts`: screenshots of the lower sections without swipes.
        .modifier(OrbitSelfTestScroll())
        #endif
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task(id: vm.connectionID) {
            model.configure(vm)
            await refreshPermission()
            await model.loadSettings()
            if enabled, let link = OrbitPCLink.current(vm) { await registrar.ensureRegistered(link) }
            while !Task.isCancelled {
                if scenePhase == .active {
                    // The PC may have been offline (or busy) when the screen opened: read its settings once it answers.
                    if vm.metrics.isOnline, model.needsSettings { await model.loadSettings() }
                    await model.refreshLive()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshPermission() } }
        }
        .onChange(of: registrar.phases[vm.selectedPCID]) { _, _ in
            Task { await model.refreshPushStatus() }
        }
        .confirmationDialog(powerDialogTitle, isPresented: Binding(get: { pendingPowerAction != nil }, set: { if !$0 { pendingPowerAction = nil } }),
                            titleVisibility: .visible) {
            if let action = pendingPowerAction {
                Button(action == "shutdown" ? "Shut Down When Finished" : "Sleep When Finished", role: action == "shutdown" ? .destructive : nil) {
                    pendingPowerAction = nil
                    OrbitHaptics.press()
                    Task { await model.schedulePower(action: action) }
                }
            }
            Button("Cancel", role: .cancel) { pendingPowerAction = nil }
        } message: {
            Text("A minute after the last download finishes, \(pcName) \(pendingPowerAction == "shutdown" ? "shuts down" : "goes to sleep"). Orbit tells you first, and you can cancel from here or from the notification.")
        }
        .orbitAppearance()
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                OrbitIconBadge(systemName: enabled ? "bell.badge.fill" : "bell.slash.fill", tint: enabled ? .red : .secondary, size: 46, filled: enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alerts from \(pcName)")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        OrbitStatusPill(text: headerStatus.text, tint: headerStatus.tint, pulsing: enabled && headerStatus.instant)
                        if vm.isDemoMode { OrbitStatChip(label: "Mode", value: "Demo") }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .orbitRow(tint: .red)
    }

    private var headerStatus: (text: String, tint: Color, instant: Bool) {
        guard enabled else { return ("Off", .secondary, false) }
        if let authorization, !OrbitNotificationPreferences.isAuthorized(authorization) { return ("Blocked in iOS Settings", .orange, false) }
        if vm.isDemoMode { return ("On", .mint, false) }
        if case .registered(true) = registrar.phase(for: vm.selectedPCID) { return ("On · instant", .mint, true) }
        return ("On · checks while open", .yellow, false)
    }

    // MARK: This iPhone

    private var deviceWord: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private var phoneSection: some View {
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { setEnabled($0) })) {
                Label("Show PC alerts on this \(deviceWord)", systemImage: "bell.fill")
            }
            .disabled(isSwitching)
            if let switchError {
                Text(switchError).font(.caption).foregroundStyle(.orange)
            }
            if enabled, let authorization, !OrbitNotificationPreferences.isAuthorized(authorization) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notifications are turned off for Orbit in iOS Settings, so alerts can't appear.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open iOS Settings") { openSystemSettings() }
                        .font(.caption.weight(.semibold))
                }
            } else if enabled, timeSensitive == .disabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Time Sensitive alerts are off for Orbit, so a Focus can hold back temperature warnings and \"sleeping in 60 s\" alerts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open iOS Settings") { openSystemSettings() }
                        .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("This \(deviceWord)")
        } footer: {
            Text("Get told when a download finishes, your PC runs hot, an app you're watching is done, or the PC is about to sleep. Alerts from every PC you've paired appear here once this is on.")
        }
        .orbitRow()
    }

    // MARK: Instant delivery

    private var deliverySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                OrbitIconBadge(systemName: delivery.icon, tint: delivery.tint, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(delivery.title).font(.subheadline.weight(.semibold))
                    Text(delivery.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            if let device = thisDeviceStatus {
                if let last = device.lastDeliveryAt.flatMap(OrbitEventFeed.parseTimestamp) {
                    LabeledContent("Last instant alert", value: last.formatted(.relative(presentation: .named)))
                        .font(.caption)
                }
                if let error = device.lastError, !error.isEmpty {
                    Text("The relay reported a problem reaching this \(deviceWord): \(error).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if canRetryRegistration {
                Button {
                    OrbitHaptics.tap()
                    if registrar.token == nil {
                        registrar.requestToken()
                    } else if let link = OrbitPCLink.current(vm) {
                        Task { await registrar.register(link, force: true) }
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .font(.subheadline.weight(.semibold))
            }
        } header: {
            Text("Delivery")
        }
        .orbitRow(tint: delivery.tint)
    }

    private var thisDeviceStatus: OrbitPushStatus.Device? {
        guard let deviceID = OrbitPushStore.deviceID(create: false) else { return nil }
        return model.pushStatus?.devices.first { $0.deviceID == deviceID }
    }

    private var canRetryRegistration: Bool {
        if case .failed = registrar.tokenState { return true }
        switch registrar.phase(for: vm.selectedPCID) {
        case .failed: return true
        default: return false
        }
    }

    private var delivery: (title: String, detail: String, icon: String, tint: Color) {
        let fallback = "Orbit checks \(pcName) for alerts while the app is open, and now and then in the background, so some alerts can arrive late."
        if !vm.hasSecureConnection {
            return ("Needs the encrypted connection", "Pair \(pcName) again in My PCs to get its alerts.", "lock.trianglebadge.exclamationmark", .orange)
        }
        if features == .olderAgent || registrar.phase(for: vm.selectedPCID) == .olderAgent {
            return ("Update Orbit PC Companion", "The agent on \(pcName) is older than PC alerts. Update it from Settings › Check for PC Companion Update.", "arrow.down.circle.fill", .orange)
        }
        switch registrar.tokenState {
        case .failed(let reason):
            return ("Instant alerts unavailable on this \(deviceWord)", "Apple's push service didn't accept this \(deviceWord) (\(reason)). " + fallback, "exclamationmark.triangle.fill", .orange)
        case .none, .requesting:
            return ("Signing up for instant alerts…", "Asking Apple's push service for this \(deviceWord)'s address.", "hourglass", .secondary)
        case .ready:
            break
        }
        switch registrar.phase(for: vm.selectedPCID) {
        case .registered(true):
            return ("Instant", "\(pcName) sends alerts through Orbit's push relay and Apple, even when Orbit is closed. They're end-to-end encrypted: only this \(deviceWord) can read them.", "bolt.fill", .mint)
        case .registered(false):
            return ("Not instant", "\(pcName) has instant delivery turned off. " + fallback, "clock.fill", .yellow)
        case .noPushSupport:
            return ("Not instant", "This version of Orbit PC Companion can't send instant alerts. " + fallback, "clock.fill", .yellow)
        case .needsSecureConnection:
            return ("Needs the encrypted connection", "Pair \(pcName) again in My PCs to get its alerts.", "lock.trianglebadge.exclamationmark", .orange)
        case .failed(let reason):
            return ("Couldn't sign up with \(pcName)", reason + " " + fallback, "exclamationmark.triangle.fill", .orange)
        case .olderAgent:
            return ("Update Orbit PC Companion", "The agent on \(pcName) is older than PC alerts.", "arrow.down.circle.fill", .orange)
        case .unknown, .registering:
            return ("Connecting to \(pcName)…", isOnline ? "Handing this \(deviceWord)'s encrypted alert key to the PC." : "Orbit signs up with \(pcName) as soon as it's online. " + fallback, "hourglass", .secondary)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var statusNotices: some View {
        if vm.isDemoMode {
            Section {
                OrbitNotice(title: "Demo mode", message: "Sample downloads and apps. Nothing is sent to a PC.", icon: "sparkles", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if vm.savedPCs.isEmpty || !vm.isConfigured {
            Section {
                OrbitNotice(title: "Pair a PC first", message: "Find and pair your PC in My PCs, then choose which alerts it sends.", icon: "desktopcomputer", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if !vm.metrics.isOnline {
            Section {
                OrbitNotice(title: "\(pcName) is offline", message: "Connect to it to change its alerts. Alerts and automatic sleep you set up keep running on the PC.", icon: "wifi.slash", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if features == .olderAgent {
            Section {
                OrbitNotice(title: "Update Orbit PC Companion", message: "\(pcName) runs an older agent without PC alerts. Update it from Settings, then come back.", icon: "arrow.down.circle.fill", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if let error = model.featuresError {
            Section {
                OrbitNotice(title: "Couldn't reach \(pcName)", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if features.isKnown, !features.has("alerts"), !features.has("downloads"), !features.has("tasks") {
            Section {
                OrbitNotice(title: "Update Orbit PC Companion", message: "This version of the agent on \(pcName) doesn't send alerts yet.", icon: "arrow.down.circle.fill", tint: .orange)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        } else if !features.isKnown {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading what \(pcName) can do…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .orbitRow()
        }
        if let notice = model.notice {
            Section { Text(notice).font(.caption).foregroundStyle(.orange) }.orbitRow()
        }
    }

    // MARK: Alert kinds

    private func alertBinding<T>(_ keyPath: WritableKeyPath<OrbitAlertSettings, T>) -> Binding<T> {
        Binding(
            get: { (model.alerts ?? .fallback)[keyPath: keyPath] },
            set: { value in
                var settings = model.alerts ?? .fallback
                settings[keyPath: keyPath] = value
                OrbitHaptics.selection()
                model.updateAlerts(settings)
            }
        )
    }

    private var alertKindsSection: some View {
        let editable = model.alerts != nil && isOnline
        let settings = model.alerts ?? .fallback
        return Section {
            if model.alerts == nil, model.alertsError == nil, !vm.isDemoMode, isOnline {
                HStack(spacing: 10) { ProgressView(); Text("Reading alert settings…").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle(isOn: alertBinding(\.downloads)) { Label("A download finishes", systemImage: "arrow.down.circle.fill") }
            Toggle(isOn: alertBinding(\.tasks)) { Label("A watched app finishes", systemImage: "app.badge.checkmark.fill") }
            Toggle(isOn: alertBinding(\.online)) { Label("The PC comes online", systemImage: "power.circle.fill") }
            if features.has("summary") {
                Toggle(isOn: alertBinding(\.summary)) { Label("My monthly summary is ready", systemImage: "calendar") }
            }
            Toggle(isOn: alertBinding(\.temperatureEnabled)) { Label("The PC runs hot", systemImage: "thermometer.high") }
            if settings.temperatureEnabled {
                Stepper(value: alertBinding(\.cpuLimit), in: 50...110) {
                    LabeledContent("CPU above", value: "\(settings.cpuLimit) °C")
                }
                Stepper(value: alertBinding(\.gpuLimit), in: 50...110) {
                    LabeledContent("GPU above", value: "\(settings.gpuLimit) °C")
                }
                Picker("For at least", selection: alertBinding(\.forSeconds)) {
                    ForEach(Self.durations(including: settings.forSeconds), id: \.self) { seconds in
                        Text(Self.durationTitle(seconds)).tag(seconds)
                    }
                }
            }
            Toggle(isOn: alertBinding(\.pcToasts)) { Label("Also show alerts on the PC", systemImage: "macwindow.badge.plus") }
            if let error = model.alertsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Alert me when")
                Spacer()
                if model.isSavingAlerts { ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text("Saved on \(pcName), so every device that gets its alerts follows them. A temperature alert repeats at most every 10 minutes per sensor.")
        }
        .disabled(!editable)
        .orbitRow()
    }

    private static func durations(including current: Int) -> [Int] {
        let base = [10, 30, 60, 120, 300]
        return base.contains(current) || current <= 0 ? base : (base + [current]).sorted()
    }

    private static func durationTitle(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : (seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds")
    }

    // MARK: Downloads

    private var downloadsSection: some View {
        Section {
            if let downloads = model.downloads {
                if downloads.downloads.isEmpty {
                    Text(storesSummary(downloads.stores, empty: true)).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(downloads.downloads) { item in downloadRow(item) }
                }
                if features.has("powerAfter"), downloads.active, model.rule == nil {
                    HStack(spacing: 10) {
                        Button {
                            pendingPowerAction = "sleep"
                        } label: {
                            Label("Sleep When Done", systemImage: "moon.zzz.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OrbitGlassButtonStyle(tint: .indigo))
                        Button {
                            pendingPowerAction = "shutdown"
                        } label: {
                            Label("Shut Down When Done", systemImage: "power").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OrbitGlassButtonStyle(tint: .red))
                    }
                    .font(.caption.weight(.bold))
                    .disabled(model.isWorking || !isOnline)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                }
            } else if let error = model.downloadsError {
                Text("Couldn't read downloads. \(error)").font(.caption).foregroundStyle(.orange)
            } else if isOnline {
                HStack(spacing: 10) { ProgressView(); Text("Looking for downloads…").font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Downloads on the PC")
        } footer: {
            if let downloads = model.downloads, !downloads.downloads.isEmpty {
                Text(storesSummary(downloads.stores, empty: false))
            }
        }
        .orbitRow()
    }

    private func downloadRow(_ item: OrbitPCDownloads.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                OrbitIconBadge(systemName: storeIcon(item.store), tint: storeTint(item.store), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(downloadDetail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(stateTitle(item.state))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(stateTint(item.state))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(stateTint(item.state).opacity(0.14), in: Capsule())
            }
            if let progress = item.progress, progress.isFinite, ["downloading", "staging", "paused", "queued"].contains(item.state) {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(stateTint(item.state))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func downloadDetail(_ item: OrbitPCDownloads.Item) -> String {
        var parts: [String] = [storeName(item.store)]
        if let total = item.bytesTotal, total > 0 {
            let done = item.bytesDone ?? (item.progress ?? 0) * total
            parts.append(done > 0 ? "\(Self.bytes(done)) of \(Self.bytes(total))" : Self.bytes(total))
        } else if let progress = item.progress, progress.isFinite {
            parts.append("\(Int((progress * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value, 9.0e15))), countStyle: .file)
    }

    private func storesSummary(_ stores: [String: Bool]?, empty: Bool) -> String {
        let found = ["steam", "epic", "gog"].filter { stores?[$0] == true }.map(storeName)
        guard !found.isEmpty else { return "No Steam, Epic Games or GOG install found on \(pcName)." }
        let list = ListFormatter.localizedString(byJoining: found)
        return empty ? "Nothing downloading in \(list) right now." : "Orbit watches \(list) on \(pcName) and tells you when downloads finish."
    }

    private func storeName(_ store: String) -> String {
        switch store { case "steam": return "Steam"; case "epic": return "Epic Games"; case "gog": return "GOG"; default: return store.capitalized }
    }
    private func storeIcon(_ store: String) -> String {
        switch store { case "steam": return "gamecontroller.fill"; case "epic": return "e.square.fill"; case "gog": return "g.square.fill"; default: return "arrow.down.circle.fill" }
    }
    private func storeTint(_ store: String) -> Color {
        switch store { case "steam": return .blue; case "epic": return .gray; case "gog": return .purple; default: return theme.accent }
    }
    private func stateTitle(_ state: String) -> String {
        switch state {
        case "queued": return "Queued"; case "downloading": return "Downloading"; case "staging": return "Installing"
        case "paused": return "Paused"; case "finished": return "Done"; case "failed": return "Failed"
        default: return state.capitalized
        }
    }
    private func stateTint(_ state: String) -> Color {
        switch state {
        case "downloading", "staging": return .cyan; case "finished": return .mint; case "failed": return .red
        case "paused": return .yellow; default: return .secondary
        }
    }

    // MARK: Automatic sleep

    private var powerDialogTitle: String {
        pendingPowerAction == "shutdown" ? "Shut down \(pcName) when downloads finish?" : "Put \(pcName) to sleep when downloads finish?"
    }

    private var powerSection: some View {
        Section {
            if let rule = model.rule {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        OrbitIconBadge(systemName: rule.action == "shutdown" ? "power" : "moon.zzz.fill", tint: rule.action == "shutdown" ? .red : .indigo, size: 36, filled: rule.state == "countdown")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ruleTitle(rule)).font(.subheadline.weight(.semibold))
                            if rule.state == "countdown", let end = rule.countdownEnd {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(countdownText(rule, end: end, now: context.date))
                                        .font(.title3.weight(.bold)).monospacedDigit()
                                        .foregroundStyle(rule.action == "shutdown" ? .red : .indigo)
                                        .contentTransition(.numericText())
                                }
                            } else {
                                Text(ruleWaitingText(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    Button(role: .destructive) {
                        OrbitHaptics.press()
                        Task { await model.cancelPower() }
                    } label: {
                        Label(rule.state == "countdown" ? "Cancel \(rule.action == "shutdown" ? "Shutdown" : "Sleep")" : "Cancel", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OrbitGlassButtonStyle(tint: .red))
                    .disabled(model.isWorking || !isOnline)
                }
                .padding(.vertical, 4)
            }
            if let error = model.powerError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Automatic \(model.rule?.action == "shutdown" ? "shutdown" : "sleep")")
        } footer: {
            Text("You can also cancel from the notification \(pcName) sends before it goes down.")
        }
        .orbitRow(tint: model.rule?.state == "countdown" ? .red : nil)
    }

    private func ruleTitle(_ rule: OrbitPowerRule) -> String {
        let verb = rule.action == "shutdown" ? "Shut down" : "Sleep"
        if rule.trigger == "task" {
            let label = model.tasks.first { $0.id == rule.taskID }?.label ?? "the watched app"
            return "\(verb) when \(label) finishes"
        }
        return "\(verb) when downloads finish"
    }

    private func ruleWaitingText(_ rule: OrbitPowerRule) -> String {
        let delay = rule.delaySeconds ?? 60
        return "Waiting. \(pcName) \(rule.action == "shutdown" ? "shuts down" : "sleeps") \(delay) seconds after that, unless you cancel."
    }

    private func countdownText(_ rule: OrbitPowerRule, end: Date, now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let verb = rule.action == "shutdown" ? "Shutting down" : "Sleeping"
        return remaining == 0 ? "\(verb) now…" : "\(verb) in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }

    // MARK: Watched apps

    private var tasksSection: some View {
        Section {
            if !model.tasksLoaded, model.tasksError == nil, isOnline {
                HStack(spacing: 10) { ProgressView(); Text("Reading watched apps…").font(.caption).foregroundStyle(.secondary) }
            } else if model.tasks.isEmpty, model.tasksLoaded {
                Text("No apps are being watched.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.tasks) { task in
                HStack(spacing: 12) {
                    OrbitIconBadge(systemName: task.mode == "idle" ? "hourglass" : "xmark.app.fill", tint: taskTint(task.state), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(taskDetail(task)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        OrbitHaptics.tap()
                        Task { await model.stopWatching(task) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.state == "watching" ? "Stop watching \(task.label)" : "Remove \(task.label)")
                }
                .swipeActions {
                    Button(task.state == "watching" ? "Stop" : "Remove", role: .destructive) { Task { await model.stopWatching(task) } }
                }
            }
            if let error = model.tasksError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            NavigationLink { TaskManagerView(vm: vm) } label: {
                Label("Open Task Manager", systemImage: "list.bullet.rectangle.portrait.fill")
            }
        } header: {
            Text("Watched apps")
        } footer: {
            Text("In Task Manager, touch and hold an app and choose Notify Me When It Finishes. \"Goes idle\" suits renders and exports that keep the app open.")
        }
        .orbitRow()
    }

    private func taskDetail(_ task: OrbitWatchedTask) -> String {
        let when = task.mode == "idle" ? "when it goes idle" : "when it closes"
        switch task.state {
        case "finished":
            if let finished = task.finishedAt.flatMap(OrbitEventFeed.parseTimestamp) { return "Finished \(finished.formatted(.relative(presentation: .named)))" }
            return "Finished"
        case "gone": return "No longer running"
        default:
            if let started = task.startedAt.flatMap(OrbitEventFeed.parseTimestamp) {
                return "Notifies \(when) · watching since \(started.formatted(date: .omitted, time: .shortened))"
            }
            return "Notifies \(when)"
        }
    }

    private func taskTint(_ state: String) -> Color {
        switch state { case "finished": return .mint; case "gone": return .secondary; default: return .orange }
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        guard on != enabled, !isSwitching else { return }
        isSwitching = true
        switchError = nil
        OrbitHaptics.selection()
        Task {
            if on {
                switchError = await OrbitNotificationSwitch.enable()
            } else {
                await OrbitNotificationSwitch.disable()
            }
            await refreshPermission()
            if on, enabled, let link = OrbitPCLink.current(vm) { await registrar.ensureRegistered(link) }
            isSwitching = false
        }
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        timeSensitive = settings.timeSensitiveSetting
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
}
