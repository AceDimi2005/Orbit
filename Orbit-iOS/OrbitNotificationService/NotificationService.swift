import Foundation
import UserNotifications

/// Notification Service Extension for alerts pushed by the PC (`NSExtensionPrincipalClass`).
///
/// iOS runs it for every remote notification that carries `"mutable-content": 1`, before the alert is
/// shown, and gives it about 30 seconds. The relay only ever sees ciphertext: the push says
/// "Orbit — New alert from your PC" and carries the encrypted alert in `o`. `OrbitPushContent` opens it
/// with the key this iPhone gave that PC (App Group keychain, one key per PC, AAD = this install's device
/// ID) and shows the real title and text. When nothing opens it (no key yet after a restart, a removed
/// PC), the alert says "Your PC sent an alert. Open Orbit." instead.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let fallback = OrbitPushContent.fallback(request.content)
        lock.lock()
        self.contentHandler = contentHandler
        bestAttemptContent = fallback
        lock.unlock()

        deliver(OrbitPushContent.decrypted(request.content) ?? fallback)
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
}
