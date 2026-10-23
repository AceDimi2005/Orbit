import CryptoKit
import Foundation

/// One alert the PC pushed, after this iPhone decrypted it.
///
/// The PC (`orbit_push.py`) encrypts this JSON for each registered device:
/// `{"v":1,"pc":"<hostname>","id":<eventID>,"kind":"…","title":"…","body":"…","ts":<epoch>,"link":"orbit://notifications"}`.
/// `id` is 0 for the "PC offline" message the relay keeps and sends when the PC stops answering.
struct OrbitPushMessage: Equatable {
    var pc: String
    var id: Int
    var kind: String
    var title: String
    var body: String
    var timestamp: Double
    var link: String
}

/// A push this iPhone could open, and whether its event was already shown.
struct OrbitPushOutcome: Equatable {
    /// The profile id of the PC whose key opened it.
    var pcID: String
    var message: OrbitPushMessage
    var duplicate: Bool
}

/// End-to-end encryption of PC alerts (DESIGN F1, `Orbit-Push-Relay/PROTOCOL.md` §6).
///
/// Wire format: standard base64 of `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`, AES-256-GCM with
/// the 32-byte key this iPhone gave that PC, AAD = the UTF-8 bytes of this install's `deviceID`. The
/// plaintext is compact JSON right-padded with ASCII spaces to a multiple of 128 bytes, so the relay
/// cannot guess the kind of alert from its length.
///
/// Compiled into the iPhone app and the Notification Service Extension, and on its own by
/// `Tests/check_push_crypto.py`, so it uses nothing but Foundation and CryptoKit.
enum OrbitPushCrypto {
    static let keyByteCount = 32
    static let nonceByteCount = 12
    static let tagByteCount = 16
    /// The relay refuses ciphertexts above 3072 base64 characters (2048-byte padded plaintext).
    static let maximumCiphertextCharacters = 4096
    static let defaultLink = "orbit://notifications"
    static let fallbackTitle = "Orbit"
    static let fallbackBody = "Your PC sent an alert. Open Orbit."

    enum Failure: Error, Equatable {
        /// Not base64, too short or too long.
        case malformed
        /// Wrong key, wrong device ID, or the bytes were changed on the way.
        case authentication
        /// Decrypted, but not a message this version understands.
        case unsupported
    }

    /// A fresh random 256-bit key for one (device, PC) pair.
    static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Decrypts and parses one alert with one key.
    static func open(_ ciphertext: String, key: Data, deviceID: String) throws -> OrbitPushMessage {
        let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == keyByteCount, !deviceID.isEmpty,
              trimmed.count <= maximumCiphertextCharacters,
              let combined = Data(base64Encoded: trimmed),
              combined.count > nonceByteCount + tagByteCount else { throw Failure.malformed }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(deviceID.utf8))
        } catch {
            throw Failure.authentication
        }
        return try message(fromPlaintext: plaintext)
    }

    /// Tries every stored key (one per paired PC) and returns the PC whose key opened the alert.
    static func open(_ ciphertext: String, keys: [(id: String, key: Data)], deviceID: String) -> (id: String, message: OrbitPushMessage)? {
        for candidate in keys {
            if let message = try? open(ciphertext, key: candidate.key, deviceID: deviceID) {
                return (candidate.id, message)
            }
        }
        return nil
    }

    /// What the Notification Service Extension does with one push: opens it with the stored keys and
    /// records its event as shown. `record(eventID, pcID)` returns false when the event was shown already
    /// (the app's poller got there first): the push is then a duplicate and arrives silently.
    static func receive(_ ciphertext: String, keys: [(id: String, key: Data)], deviceID: String,
                        record: (_ eventID: Int, _ pcID: String) -> Bool) -> OrbitPushOutcome? {
        guard let opened = open(ciphertext, keys: keys, deviceID: deviceID) else { return nil }
        let duplicate = opened.message.id > 0 && !record(opened.message.id, opened.id)
        return OrbitPushOutcome(pcID: opened.id, message: opened.message, duplicate: duplicate)
    }

    /// Parses the decrypted JSON after removing the space padding.
    static func message(fromPlaintext plaintext: Data) throws -> OrbitPushMessage {
        var end = plaintext.endIndex
        while end > plaintext.startIndex, plaintext[plaintext.index(before: end)] == 0x20 { end = plaintext.index(before: end) }
        let json = plaintext[plaintext.startIndex..<end]
        guard !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
              integer(object["v"]) == 1 else { throw Failure.unsupported }
        let title = clean(object["title"] as? String, limit: 200)
        let body = clean(object["body"] as? String, limit: 1000)
        let link = (object["link"] as? String).flatMap(safeLink) ?? defaultLink
        return OrbitPushMessage(
            pc: clean(object["pc"] as? String, limit: 80),
            id: max(0, integer(object["id"]) ?? 0),
            kind: clean(object["kind"] as? String, limit: 64),
            title: title.isEmpty ? fallbackTitle : title,
            body: body.isEmpty && title.isEmpty ? fallbackBody : body,
            timestamp: (object["ts"] as? NSNumber)?.doubleValue ?? 0,
            link: link
        )
    }

    /// Only Orbit's own links may open from a notification.
    static func safeLink(_ value: String) -> String? {
        guard value.count <= 200, let url = URL(string: value), url.scheme?.lowercased() == "orbit" else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9.0e15 else { return nil }
        return Int(double)
    }

    private static func clean(_ value: String?, limit: Int) -> String {
        guard let value else { return "" }
        let scalars = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F || $0 == "\n" }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
