import AppKit
import Foundation
import SwiftUI
import UserNotifications

// PC alerts on the Mac (DESIGN F1): while Orbit runs it reads each paired PC's event log
// (`GET /api/events`, agents with the `events` feature) every 15 seconds and posts local notifications.
// The first read of a PC only learns where its log ends, so nothing old is replayed.

/// Settings › General › PC alerts. Everything defaults to on.
enum MacPCAlertPrefs {
    static let enabledKey = "mac.pcAlerts"
    static let cursorKey = "mac.pcAlerts.cursor.v1"

    static func key(_ category: OrbitEventFeed.Category) -> String { "mac.pcAlerts.\(category.rawValue)" }

    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }

    static func allows(_ category: OrbitEventFeed.Category) -> Bool {
        guard category != .other else { return true }
        return (UserDefaults.standard.object(forKey: key(category)) as? Bool) ?? true
    }

    /// The toggles shown in Settings, in order.
    static let choices: [(category: OrbitEventFeed.Category, title: String)] = [
        (.downloads, "A download finishes"),
        (.temperature, "A PC runs hot"),
        (.tasks, "A watched app finishes"),
        (.power, "A PC is about to sleep or shut down"),
        (.online, "A PC comes online"),
        (.summary, "A monthly summary is ready")
    ]

    static func cursor(for pcID: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: cursorKey) as? [String: Int])?[pcID]
    }

    static func setCursor(_ value: Int, for pcID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: cursorKey) as? [String: Int]) ?? [:]
        map[pcID] = value
        UserDefaults.standard.set(map, forKey: cursorKey)
    }
}

@MainActor
final class MacPCAlertPoller {
    static let shared = MacPCAlertPoller()
    static let interval: TimeInterval = 15
    private weak var viewModel: OrbitMacViewModel?
    private var loop: Task<Void, Never>?
    /// Features per PC; nil features = an agent older than `/api/capabilities`.
    private var features: [String: (features: Set<String>?, checkedAt: Date)] = [:]
    private var inFlight: Set<String> = []
    private var wasEnabled = MacPCAlertPrefs.isEnabled

    func start(with viewModel: OrbitMacViewModel) {
        self.viewModel = viewModel
        let center = UNUserNotificationCenter.current()
        center.delegate = MacNotificationPresenter.shared
        let cancel = UNNotificationAction(identifier: OrbitEventFeed.cancelPowerAction, title: "Cancel", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: OrbitEventFeed.powerScheduledCategory, actions: [cancel], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: OrbitEventFeed.eventCategory, actions: [], intentIdentifiers: [], options: [])
        ])
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Let the first status poll settle before touching the PCs again.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self?.pollAll()
                do { try await Task.sleep(for: .seconds(Self.interval)) } catch { break }
            }
        }
    }

    func pollAll() async {
        let enabled = MacPCAlertPrefs.isEnabled
        defer { wasEnabled = enabled }
        guard enabled else { return }
        // Turned back on: start from "now", never with what happened while alerts were off.
        if !wasEnabled { UserDefaults.standard.removeObject(forKey: MacPCAlertPrefs.cursorKey) }
        guard let viewModel, !viewModel.isDemoMode else { return }
        let pcs = viewModel.savedPCs.filter(\.isSecure)
        await withTaskGroup(of: Void.self) { group in
            for pc in pcs {
                group.addTask { @MainActor in await self.poll(pc) }
            }
        }
    }

    private func client(for pc: MacSavedPC) -> OrbitAPIClient? {
        let token = MacTokenStore.token(for: pc.id)
        guard !token.isEmpty else { return nil }
        return try? OrbitAPIClient(host: pc.address, port: pc.securePort, token: token, fingerprint: pc.certificateFingerprint)
    }

    private func supportsEvents(_ pc: MacSavedPC, client: OrbitAPIClient) async throws -> Bool {
        if let known = features[pc.id] {
            let maxAge: TimeInterval = known.features == nil ? 1800 : 600
            if Date().timeIntervalSince(known.checkedAt) < maxAge { return known.features?.contains("events") ?? false }
        }
        do {
            let reply: MacCapabilities = try await client.get("/api/capabilities")
            features[pc.id] = (Set(reply.features), Date())
            return reply.features.contains("events")
        } catch let error as OrbitError where error.statusCode == 404 {
            features[pc.id] = (nil, Date())
            return false
        }
    }

    private func poll(_ pc: MacSavedPC) async {
        guard !inFlight.contains(pc.id), let client = client(for: pc) else { return }
        inFlight.insert(pc.id)
        defer { inFlight.remove(pc.id) }
        do {
            guard try await supportsEvents(pc, client: client) else { return }
            let previous = MacPCAlertPrefs.cursor(for: pc.id)
            let result = try await OrbitEventFeed.poll(cursor: previous, delivered: previous ?? 0) { since, limit in
                var query = [URLQueryItem(name: "limit", value: String(limit))]
                if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
                return try await client.get("/api/events", query: query)
            }
            let wanted = result.toPost.filter { shouldShow($0, from: pc) }
            if !wanted.isEmpty, await mayPost() {
                for event in wanted { await post(event, from: pc) }
            }
            MacPCAlertPrefs.setCursor(result.cursor, for: pc.id)
        } catch {
            // Offline or busy: try again next round from the same place.
        }
    }

    private func shouldShow(_ event: OrbitPCEvent, from pc: MacSavedPC) -> Bool {
        let category = OrbitEventFeed.category(of: event.kind)
        guard MacPCAlertPrefs.allows(category) else { return false }
        // The Mac already says "<PC> is online" for the selected PC when it reconnects.
        if event.kind == "pc.online", pc.id == viewModel?.currentPC?.id, UserDefaults.standard.bool(forKey: "mac.notifyOnline") { return false }
        return true
    }

    /// Asks for permission the first time an alert is about to appear (same options as
    /// `OrbitMacViewModel.requestNotificationPermission`).
    private func mayPost() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    private func post(_ event: OrbitPCEvent, from pc: MacSavedPC) async {
        let content = UNMutableNotificationContent()
        content.title = event.title.isEmpty ? pc.name : event.title
        content.subtitle = pc.name
        content.body = event.body
        content.threadIdentifier = pc.id
        content.categoryIdentifier = OrbitEventFeed.notificationCategory(for: event.kind)
        content.userInfo = ["pcID": pc.id, "eventID": event.id, "kind": event.kind]
        switch event.level {
        case "passive": content.interruptionLevel = .passive
        case "timeSensitive": content.interruptionLevel = .timeSensitive; content.sound = .default
        default: content.sound = .default
        }
        let request = UNNotificationRequest(identifier: OrbitEventFeed.notificationIdentifier(pcID: pc.id, eventID: event.id), content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// "Cancel" on a "Sleeping in 60 s" alert.
    func cancelPower(pcID: String?) async {
        guard let viewModel else { return }
        let pc = viewModel.savedPCs.first { $0.id == pcID } ?? viewModel.currentPC
        guard let pc, let client = client(for: pc) else { return }
        do {
            _ = try await client.data("/api/power/after", method: "DELETE")
            viewModel.statusBanner = "Cancelled the automatic sleep on \(pc.name)"
        } catch let error as OrbitError where error.statusCode == 404 {
            viewModel.statusBanner = "Nothing to cancel on \(pc.name)"
        } catch {
            let content = UNMutableNotificationContent()
            content.title = "Couldn't cancel on \(pc.name)"
            content.body = "\(error.localizedDescription) Open Orbit and try again."
            content.sound = .default
            content.userInfo = ["orbitNote": true]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orbit.note.\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}

private struct MacCapabilities: Decodable {
    var agentVersion: String?
    var features: [String]
}

/// Shows Orbit's notifications while the app is in front too, and handles the "Cancel" action.
final class MacNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // PC alerts show as banners even while Orbit is in front; the Mac's own "<PC> is online" note
        // keeps its old behaviour (Notification Center only while the app is open).
        let info = notification.request.content.userInfo
        let isPCAlert = info["eventID"] != nil || (info["orbitNote"] as? Bool) == true
        completionHandler(isPCAlert ? [.banner, .list, .sound] : [.list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let pcID = response.notification.request.content.userInfo["pcID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == OrbitEventFeed.cancelPowerAction {
                await MacPCAlertPoller.shared.cancelPower(pcID: pcID)
            } else if action == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }
}

/// Settings › General › PC alerts.
struct MacPCAlertsSettingsSection: View {
    @AppStorage(MacPCAlertPrefs.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("Show alerts from your PCs", isOn: $enabled)
            ForEach(MacPCAlertPrefs.choices, id: \.category) { choice in
                MacPCAlertToggle(category: choice.category, title: choice.title)
                    .disabled(!enabled)
            }
        } header: {
            Text("PC alerts")
        } footer: {
            Text("While Orbit runs, it checks your paired PCs every 15 seconds for finished downloads, high temperatures, apps you're watching and automatic sleep. Choose what each PC reports in Orbit on your iPhone (Tools › Notifications). Needs a recent Orbit PC Companion.")
        }
    }
}

private struct MacPCAlertToggle: View {
    let category: OrbitEventFeed.Category
    let title: String
    @AppStorage private var isOn: Bool

    init(category: OrbitEventFeed.Category, title: String) {
        self.category = category
        self.title = title
        _isOn = AppStorage(wrappedValue: true, MacPCAlertPrefs.key(category))
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
    }
}
