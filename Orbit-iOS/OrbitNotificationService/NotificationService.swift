import UserNotifications

/// Notification Service Extension for alerts pushed by the PC (`NSExtensionPrincipalClass`).
///
/// iOS runs it for every remote notification that carries `"mutable-content": 1`, before the alert is
/// shown, and gives it about 30 seconds. For now it delivers the alert exactly as it arrived; the
/// decryption of the PC's payload is added on top of this.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content
        deliver(request.content)
    }

    /// iOS is about to kill the extension: deliver the best content so far, never nothing.
    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent { deliver(bestAttemptContent) }
    }

    /// Calls the content handler once; later calls are ignored.
    private func deliver(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }
}
