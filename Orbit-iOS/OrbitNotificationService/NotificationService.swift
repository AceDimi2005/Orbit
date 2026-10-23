import Foundation
import UserNotifications

/// Notification Service Extension for alerts pushed by the PC (`NSExtensionPrincipalClass`).
///
/// iOS runs it for every remote notification that carries `"mutable-content": 1`, before the alert is
/// shown, and gives it about 30 seconds. The relay only ever sees ciphertext: the push says
/// "Orbit — New alert from your PC" and carries the encrypted alert in `o`. This extension opens it with
/// the key this iPhone gave that PC (App Group keychain, one key per PC, AAD = this install's device ID)
/// and shows the real title and text. When nothing opens it (no key yet after a restart, a removed PC),
/// it shows "Your PC sent an alert. Open Orbit." instead.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let fallback = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        fallback.title = OrbitPushCrypto.fallbackTitle
        fallback.body = OrbitPushCrypto.fallbackBody
        fallback.userInfo["link"] = OrbitPushCrypto.defaultLink
        lock.lock()
        self.contentHandler = contentHandler
        bestAttemptContent = fallback
        lock.unlock()

        let content = Self.decrypted(request.content) ?? fallback
        deliver(content)
    }

    /// iOS is about to stop the extension: deliver the best content so far, never nothing.
    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let best = bestAttemptContent
        lock.unlock()
        if let best { deliver(best) }
    }

    /// Calls the content handler once; later calls are ignored.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        lock.unlock()
        handler?(content)
    }

    /// The alert with its real text, or nil when no stored key opens it.
    static func decrypted(_ original: UNNotificationContent) -> UNMutableNotificationContent? {
        guard let ciphertext = original.userInfo["o"] as? String,
              let deviceID = OrbitPushStore.deviceID(create: false) else { return nil }
        let keys = OrbitPushStore.allKeys()
        guard !keys.isEmpty, let opened = OrbitPushCrypto.open(ciphertext, keys: keys, deviceID: deviceID) else { return nil }
        let message = opened.message
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else { return nil }
        content.title = message.title
        content.body = message.body
        if !message.pc.isEmpty { content.threadIdentifier = message.pc }
        content.categoryIdentifier = OrbitEventFeed.notificationCategory(for: message.kind)
        content.userInfo["link"] = message.link
        content.userInfo["pcID"] = opened.id
        content.userInfo["eventID"] = message.id
        content.userInfo["kind"] = message.kind
        content.userInfo.removeValue(forKey: "o")
        // The app's own poller may have shown this event already (it records the same ids). The
        // extension can't hide a push, so it arrives silently and the app removes it later.
        if message.id > 0, !OrbitPushStore.recordDelivered(message.id, for: opened.id) {
            content.userInfo[duplicateKey] = true
            content.sound = nil
            content.interruptionLevel = .passive
        }
        return content
    }

    static let duplicateKey = "orbitDuplicate"
}
