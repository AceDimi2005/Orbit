#if DEBUG
import Foundation
import Security
import SwiftUI
import UIKit
import UserNotifications

/// Headless check of PC alerts in Debug builds (the Simulator UI needs no taps).
///
/// `ORBIT_NOTIFY_SELFTEST=pair|enable|status|poll` (pass `SIMCTL_CHILD_ORBIT_NOTIFY_SELFTEST` to
/// `xcrun simctl launch --console-pty`) runs one step and exits:
/// - `pair`: PIN-pairs with `ORBIT_SELFTEST_HOST`:`ORBIT_SELFTEST_TLS_PORT` (certificate
///   `ORBIT_SELFTEST_FINGERPRINT`), reading the code from the pretend PC's control API
///   (`ORBIT_SELFTEST_PIN_URL`), and saves the PC the way a real pairing does.
/// - `enable`: grants provisional notification permission (no prompt) and turns PC alerts on.
/// - `status`: asks for the APNs token, registers with every PC, polls the selected PC once and
///   prints the keys, ids and delivered notifications.
/// - `poll`: `status` after waiting `ORBIT_SELFTEST_WAIT` seconds.
/// Scrolls a list to the section named by `ORBIT_SELFTEST_SCROLL` a few seconds after it appears.
struct OrbitSelfTestScroll: ViewModifier {
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.task {
                guard let anchor = ProcessInfo.processInfo.environment["ORBIT_SELFTEST_SCROLL"] else { return }
                // The section appears once the PC answered, so try a few times.
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
        }
    }
}

enum OrbitNotifySelfTest {
    /// `ORBIT_SELFTEST_OPEN_URL=orbit://notifications` (or `orbit://settings` for the Tools tab) opens an
    /// Orbit link from inside the app a few seconds after launch, for screenshots without taps (`simctl
    /// openurl` asks for a confirmation tap first).
    static func open(_ link: String) {
        guard let url = URL(string: link), url.scheme == "orbit" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await UIApplication.shared.open(url)
        }
    }

    static func start(mode: String) {
        Task { @MainActor in
            await perform(mode: mode)
            exit(0)
        }
    }

    @MainActor
    private static func perform(mode: String) async {
        let environment = ProcessInfo.processInfo.environment
        switch mode {
        case "pair":
            await pair(environment)
        case "enable":
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional])) ?? false
            UserDefaults.standard.set(granted, forKey: OrbitNotificationPreferences.enabledKey)
            print("selftest: provisional permission \(granted) · alerts on \(OrbitNotificationPreferences.isEnabled)")
        case "status", "poll":
            if mode == "poll", let wait = environment["ORBIT_SELFTEST_WAIT"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(wait)) }
            await status()
        case "watch":
            // Task Manager's "Sleep When It Finishes" requests (same bodies) for ORBIT_SELFTEST_PID / _CREATE_TIME.
            guard let link = OrbitPCLink.selected(), let pid = environment["ORBIT_SELFTEST_PID"].flatMap(Int.init),
                  let created = environment["ORBIT_SELFTEST_CREATE_TIME"].flatMap(Double.init) else { print("selftest: PC, pid and create time needed"); return }
            do {
                let mode = environment["ORBIT_SELFTEST_MODE"] ?? "idle"
                let task: OrbitWatchedTask = try await link.client.send("/api/tasks", body: OrbitNewWatchedTask(
                    pid: pid, createTime: created, mode: mode, idleMinutes: mode == "idle" ? 2 : nil, label: environment["ORBIT_SELFTEST_LABEL"] ?? "Self-test"))
                print("selftest: watching \(task.label) · id \(task.id) · mode \(task.mode) · state \(task.state)")
                if environment["ORBIT_SELFTEST_SLEEP"] == "1" {
                    let _: OrbitJSON = try await link.client.send("/api/power/after", method: "PUT",
                                                                  body: OrbitPowerAfterRequest(trigger: "task", action: "sleep", delaySeconds: 60, taskID: task.id))
                    let after: OrbitPowerAfter = try await link.client.get("/api/power/after")
                    print("selftest: rule \(after.rule.map { "\($0.action) after \($0.trigger) \($0.taskID ?? "-") · \($0.state)" } ?? "none")")
                }
            } catch {
                print("selftest: watch failed: \(OrbitPlainError.describe(error))")
            }
        case "cancel":
            // The "Cancel" notification action's code path.
            await OrbitLocalAlerts.cancelPower(pcID: OrbitPCLink.selected()?.id)
            if let link = OrbitPCLink.selected(), let after: OrbitPowerAfter = try? await link.client.get("/api/power/after") {
                print("selftest: after cancel the rule is \(after.rule == nil ? "gone" : "still \(after.rule!.state)")")
            }
        case "nse":
            // The extension's code path on pushes sealed by the PC (comma-separated in ORBIT_SELFTEST_CIPHERTEXTS).
            let ciphertexts = (environment["ORBIT_SELFTEST_CIPHERTEXTS"] ?? "").split(separator: ",").map(String.init)
            for (index, ciphertext) in ciphertexts.enumerated() {
                let push = UNMutableNotificationContent()
                push.title = "Orbit"
                push.body = "New alert from your PC"
                push.sound = .default
                push.userInfo = ["o": ciphertext, "v": 1]
                let shown = OrbitPushContent.process(push)
                print("selftest: push \(index + 1) → \(shown.title) — \(shown.body) · category \(shown.categoryIdentifier) · thread \(shown.threadIdentifier) · pc \(shown.userInfo["pcID"] as? String ?? "none") · event \(shown.userInfo["eventID"] as? Int ?? -1) · duplicate \(shown.userInfo[OrbitPushContent.duplicateKey] as? Bool ?? false) · link \(shown.userInfo["link"] as? String ?? "none")")
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orbit.selftest.push.\(index)", content: shown, trigger: nil))
            }
        default:
            print("selftest: unknown mode \(mode)")
        }
    }

    @MainActor
    private static func pair(_ environment: [String: String]) async {
        guard let host = environment["ORBIT_SELFTEST_HOST"], let port = environment["ORBIT_SELFTEST_TLS_PORT"].flatMap(Int.init),
              let fingerprint = environment["ORBIT_SELFTEST_FINGERPRINT"],
              let pinURL = environment["ORBIT_SELFTEST_PIN_URL"].flatMap(URL.init(string:)) else {
            print("selftest: ORBIT_SELFTEST_HOST, _TLS_PORT, _FINGERPRINT and _PIN_URL are required"); return
        }
        do {
            let handshake = try OrbitPairingHandshake(host: host, port: port, fingerprint: fingerprint)
            _ = try await handshake.begin(name: "Orbit self-test")
            var pin = ""
            for _ in 0..<30 {
                if let (data, _) = try? await URLSession.shared.data(from: pinURL),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = object["pin"] as? String, value.count == 6 { pin = value; break }
                try await Task.sleep(for: .milliseconds(300))
            }
            let credentials = try await handshake.finish(pin: pin)
            var profile = SavedPC(name: credentials.hostname, address: credentials.ipAddress.isEmpty ? host : credentials.ipAddress)
            profile.agentPort = credentials.agentPort
            profile.securePort = credentials.securePort
            profile.certificateFingerprint = OrbitAPIClient.normalizedFingerprint(credentials.certificateFingerprint)
            profile.macAddress = credentials.macAddress
            profile.lastKnownIPv4 = credentials.ipAddress
            profile.updatedAt = Date().timeIntervalSince1970
            PCProfileStore.saveToken(credentials.apiToken, for: profile.id, publish: false)
            PCProfileStore.save([profile])
            let defaults = UserDefaults.standard
            defaults.set(profile.id, forKey: "selectedPCID")
            defaults.set(profile.address, forKey: "pcIP")
            defaults.set(profile.agentPort, forKey: "agentPort")
            defaults.set(profile.securePort, forKey: "securePort")
            defaults.set(profile.certificateFingerprint, forKey: "certificateFingerprint")
            defaults.set(true, forKey: "hasCompletedOnboarding")
            // The view model's current-connection token (`TokenStore` in ModelsAndServices.swift).
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OrbitAgent", kSecAttrAccount as String: "apiToken"]
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = Data(credentials.apiToken.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            try? OrbitWidgetConnectionStore.save(id: profile.id, name: profile.name, host: profile.address, port: profile.securePort,
                                                 readOnlyToken: credentials.widgetToken, certificateSHA256: profile.certificateFingerprint,
                                                 controlToken: credentials.apiToken)
            print("selftest: paired \(profile.name) at \(profile.address):\(profile.securePort) · keychain \(status) · profile token saved \(!PCProfileStore.token(profile.id).isEmpty)")
        } catch {
            print("selftest: pairing failed: \(OrbitPlainError.describe(error))")
        }
    }

    @MainActor
    private static func status() async {
        let registrar = OrbitPushRegistrar.shared
        registrar.requestToken()
        for _ in 0..<40 where registrar.token == nil {
            if case .failed = registrar.tokenState { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await registrar.registerAll(force: true)
        print("selftest: token \(registrar.token.map { "\($0.prefix(8))… (\($0.count) hex)" } ?? "\(registrar.tokenState)") · phases \(registrar.phases)")
        // The foreground loop may be polling right now (the app's window is up); wait for a turn.
        var polled = false
        for _ in 0..<20 where !polled {
            polled = await OrbitEventPoller.shared.pollSelected(background: false)
            if !polled { try? await Task.sleep(for: .milliseconds(500)) }
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        print("selftest: authorization \(settings.authorizationStatus.rawValue) · polled \(polled) · app group \(OrbitPushStore.sharedDefaults != nil)")
        print("selftest: deviceID \(OrbitPushStore.deviceID(create: false) ?? "none") · keys for \(OrbitPushStore.keyAccounts())")
        if let link = OrbitPCLink.selected() {
            print("selftest: selected \(link.name) · cursor \(OrbitEventPoller.cursor(for: link.id).map(String.init) ?? "none") · delivered \(OrbitPushStore.deliveredEventID(for: link.id)) · relay \(OrbitPushRegistrar.relayActive(for: link.id)) · key \(OrbitPushStore.key(for: link.id)?.count ?? 0) bytes")
        }
        for note in await UNUserNotificationCenter.current().deliveredNotifications() {
            let content = note.request.content
            print("selftest: delivered [\(note.request.identifier)] \(content.title) — \(content.body) · category \(content.categoryIdentifier) · level \(content.interruptionLevel.rawValue)")
        }
    }
}
#endif
