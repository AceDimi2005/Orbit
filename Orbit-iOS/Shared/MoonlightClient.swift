import CommonCrypto
import CryptoKit
import Foundation
import Security

// Native client for the Sunshine / NVIDIA GameStream control protocol that Moonlight
// speaks: client identity, PIN pairing, server info, app list, box art and session
// control. Everything here is an original implementation of the published wire
// protocol (Sunshine `nvhttp.cpp`); no Moonlight (GPL) code is linked, so the apps
// keep their MIT licence. The audio/video stream itself still runs in Moonlight.
//
// Shared by the iOS, tvOS and macOS targets.

struct MoonlightError: LocalizedError, Equatable {
    let message: String
    /// Sunshine refused this device's certificate: the pairing is gone and has to be redone.
    var untrusted = false
    var errorDescription: String? { message }

    static let untrustedClient = MoonlightError(
        message: "Sunshine no longer accepts this device. Its pairing was removed, disabled or paired twice on the PC. Pair again.",
        untrusted: true)
}

// MARK: - Minimal DER (ASN.1) encoder and reader

enum MoonlightDER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }
    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        return integer(bytes)
    }
    static func null() -> [UInt8] { [0x05, 0x00] }
    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return tlv(0x06, []) }
        var body: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for component in parts.dropFirst(2) {
            var encoded: [UInt8] = [UInt8(component & 0x7F)]
            var rest = component >> 7
            while rest > 0 { encoded.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            body += encoded
        }
        return tlv(0x06, body)
    }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }
    static func explicit(_ tagNumber: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | tagNumber, content) }
    /// UTCTime is valid for years 1950–2049, which comfortably covers a 20-year certificate.
    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    struct Element { let tag: UInt8; let content: Data }

    /// Splits one DER container into its direct children.
    static func children(of data: Data) throws -> [Element] {
        var elements: [Element] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = data[index]
            index += 1
            guard index < data.endIndex else { throw MoonlightError(message: "Truncated DER element.") }
            var length = Int(data[index]); index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + count <= data.endIndex else { throw MoonlightError(message: "Invalid DER length.") }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(data[index]); index += 1 }
            }
            guard index + length <= data.endIndex else { throw MoonlightError(message: "DER element exceeds its container.") }
            elements.append(Element(tag: tag, content: data[index..<(index + length)]))
            index += length
        }
        return elements
    }

    /// The raw `signatureValue` bytes of an X.509 certificate (the third top-level field).
    static func certificateSignature(_ der: Data) throws -> Data {
        let outer = try children(of: der)
        guard outer.count == 1, outer[0].tag == 0x30 else { throw MoonlightError(message: "Not an X.509 certificate.") }
        let fields = try children(of: outer[0].content)
        guard fields.count == 3, fields[2].tag == 0x03, fields[2].content.count > 1 else { throw MoonlightError(message: "Certificate has no signature.") }
        return Data(fields[2].content.dropFirst()) // skip the unused-bits byte
    }
}

// MARK: - PEM / hex helpers

enum MoonlightEncoding {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
    static func bytes(fromHex text: String) -> Data? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
    static func pem(_ der: Data, label: String = "CERTIFICATE") -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }
    static func der(fromPEM pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined())
    }
}

// MARK: - Crypto primitives

enum MoonlightCrypto {
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    /// AES-128 ECB without padding, as used by the GameStream pairing exchange.
    static func aesECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES128, data.count % kCCBlockSizeAES128 == 0 else {
            throw MoonlightError(message: "Invalid AES block size in pairing exchange.")
        }
        let count = data.count
        var output = Data(count: count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil,
                            inputBytes.baseAddress, count,
                            outputBytes.baseAddress, count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == count else { throw MoonlightError(message: "AES operation failed (\(status)).") }
        return output
    }
    static func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
            throw MoonlightError(message: "Could not sign the pairing secret: \((error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error")")
        }
        return signature
    }
    static func verify(_ data: Data, signature: Data, certificateDER: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let key = SecCertificateCopyKey(certificate) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }
}

// MARK: - Client identity (RSA-2048 key + self-signed certificate)

/// The certificate Sunshine stores for this device when pairing succeeds. The private
/// key proves ownership during pairing and authenticates every later HTTPS request.
struct MoonlightClientIdentity {
    let privateKey: SecKey
    let certificateDER: Data
    /// Keychain identity used for TLS client authentication; nil for ephemeral (test) identities.
    let secIdentity: SecIdentity?

    var certificatePEM: String { MoonlightEncoding.pem(certificateDER) }
    func certificateSignature() throws -> Data { try MoonlightDER.certificateSignature(certificateDER) }
    func sign(_ data: Data) throws -> Data { try MoonlightCrypto.sign(data, with: privateKey) }

    /// Builds an X.509 v3 certificate signed with `sha256WithRSAEncryption`, valid for 20 years.
    static func makeCertificate(privateKey: SecKey, commonName: String, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw MoonlightError(message: "Could not export the client public key.")
        }
        let rsaEncryption = MoonlightDER.sequence([MoonlightDER.oid("1.2.840.113549.1.1.1"), MoonlightDER.null()])
        let sha256WithRSA = MoonlightDER.sequence([MoonlightDER.oid("1.2.840.113549.1.1.11"), MoonlightDER.null()])
        let name = MoonlightDER.sequence([MoonlightDER.set([MoonlightDER.sequence([MoonlightDER.oid("2.5.4.3"), MoonlightDER.utf8String(commonName)])])])
        let validity = MoonlightDER.sequence([MoonlightDER.utcTime(now.addingTimeInterval(-86_400)), MoonlightDER.utcTime(now.addingTimeInterval(20 * 365.25 * 86_400))])
        let subjectPublicKeyInfo = MoonlightDER.sequence([rsaEncryption, MoonlightDER.bitString(Array(publicKeyDER))])
        var serial = Array(MoonlightCrypto.random(16))
        serial[0] &= 0x7F
        let tbs = MoonlightDER.sequence([
            MoonlightDER.explicit(0, MoonlightDER.integer(2)),
            MoonlightDER.integer(serial),
            sha256WithRSA, name, validity, name, subjectPublicKeyInfo
        ])
        let signature = try MoonlightCrypto.sign(Data(tbs), with: privateKey)
        return Data(MoonlightDER.sequence([tbs, sha256WithRSA, MoonlightDER.bitString(Array(signature))]))
    }

    /// In-memory identity: used by the offline protocol tests; cannot do TLS client auth.
    static func ephemeral(commonName: String = "Orbit Moonlight Client") throws -> MoonlightClientIdentity {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightError(message: "Could not create an RSA key: \((error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error")")
        }
        return MoonlightClientIdentity(privateKey: key, certificateDER: try makeCertificate(privateKey: key, commonName: commonName), secIdentity: nil)
    }
}

/// The client identity a host was paired with: its Keychain id and the certificate Sunshine
/// stored. Records from before 2026-10-22 have none and use the shared identity.
struct MoonlightIdentityReference: Codable, Equatable {
    var id: String
    var certificateDER: Data
}

/// Client identities in the Keychain.
///
/// Every pairing creates a new identity for that one host. Sunshine 2026 refuses a certificate
/// that it stores twice ("Client certificate identity is not enabled"), and it stores one more
/// copy each time a known certificate pairs again, so a host is never re-paired with a
/// certificate it may already know. Hosts paired by earlier versions keep the shared identity
/// (`loadOrCreate`) until they are paired again.
///
/// iOS and tvOS: the data-protection keychain pairs a permanent key and its certificate into an
/// identity that a `kSecClassIdentity` query reports. macOS is different in two ways found the
/// hard way: the data-protection keychain there never reports identities at all, and the login
/// keychain ignores the label filter on identity queries (it returned the developer's "Apple
/// Development" signing identity, which Sunshine then rejected as "client not authorized"). On
/// macOS the key is therefore generated permanently in the login keychain and the identity is
/// built from our own certificate with `SecIdentityCreateWithCertificate`.
enum MoonlightIdentityStore {
    private static let legacyKeyTag = Data("com.dimitrie.orbit.moonlight.clientkey".utf8)
    /// Subject and Keychain label of the shared identity; per-host certificates add their id.
    private static let certificateLabel = "Orbit Moonlight Client"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MoonlightClientIdentity?
    nonisolated(unsafe) private static var cachedHosts: [String: MoonlightClientIdentity] = [:]

    private static func label(forHost id: String) -> String { "\(certificateLabel) \(id)" }
    private static func keyTag(forHost id: String) -> Data { Data("com.dimitrie.orbit.moonlight.clientkey.\(id)".utf8) }

    /// The identity to present to a paired host: its own, or the shared one for older pairings.
    static func identity(for reference: MoonlightIdentityReference?) throws -> MoonlightClientIdentity {
        guard let reference else { return try loadOrCreate() }
        lock.lock(); defer { lock.unlock() }
        if let hit = cachedHosts[reference.id], hit.certificateDER == reference.certificateDER { return hit }
        guard let found = loadHostIdentity(reference) else {
            throw MoonlightError(message: "This device's Sunshine certificate is missing from the Keychain. Pair again.", untrusted: true)
        }
        cachedHosts[reference.id] = found
        return found
    }

    /// A brand-new identity for one pairing attempt; `remove` it when the attempt fails.
    static func createForPairing() throws -> (reference: MoonlightIdentityReference, identity: MoonlightClientIdentity) {
        let id = UUID().uuidString.lowercased()
        let identity = try create(label: label(forHost: id), keyTag: keyTag(forHost: id), commonName: label(forHost: String(id.prefix(8))))
        lock.lock(); cachedHosts[id] = identity; lock.unlock()
        return (MoonlightIdentityReference(id: id, certificateDER: identity.certificateDER), identity)
    }

    /// Deletes one host's identity from the Keychain (failed pairing, or replaced by a new one).
    static func remove(_ reference: MoonlightIdentityReference) {
        lock.lock(); cachedHosts[reference.id] = nil; lock.unlock()
        deleteItems(label: label(forHost: reference.id), keyTag: keyTag(forHost: reference.id))
    }

    /// The shared identity used by pairings made before 2026-10-22.
    static func loadOrCreate() throws -> MoonlightClientIdentity {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let existing = loadExisting() { cached = existing; return existing }
        let created = try create(label: certificateLabel, keyTag: legacyKeyTag, commonName: certificateLabel)
        cached = created
        return created
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        deleteItems(label: certificateLabel, keyTag: legacyKeyTag)
    }

    private static func deleteItems(label: String, keyTag: Data) {
        for protected in keychains {
            SecItemDelete(withKeychain([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label], protected: protected) as CFDictionary)
            SecItemDelete(withKeychain([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag], protected: protected) as CFDictionary)
        }
    }

    /// Keychains to clean up: on macOS both, so leftovers of earlier versions disappear too.
    private static var keychains: [Bool] {
        #if os(macOS)
        return [true, false]
        #else
        return [true]
        #endif
    }

    private static func withKeychain(_ query: [String: Any], protected: Bool) -> [String: Any] {
        var result = query
        #if os(macOS)
        if protected { result[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return result
    }

    /// The shared identity's certificate: self-signed, subject exactly "Orbit Moonlight Client"
    /// (per-host certificates carry their id), with the layout our DER builder emits.
    private static func isOurs(_ certificate: SecCertificate) -> Bool {
        guard let summary = SecCertificateCopySubjectSummary(certificate) as String?, summary == certificateLabel else { return false }
        return (try? MoonlightDER.certificateSignature(SecCertificateCopyData(certificate) as Data)) != nil
    }

    private static func identity(privateKey: SecKey, certificate: SecCertificate, identity: SecIdentity) -> MoonlightClientIdentity {
        MoonlightClientIdentity(privateKey: privateKey, certificateDER: SecCertificateCopyData(certificate) as Data, secIdentity: identity)
    }

    #if os(macOS)
    /// Our certificates in the login keychain, newest first is not guaranteed; any one with a usable key will do.
    private static func storedCertificates() -> [SecCertificate] {
        var found: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: certificateLabel,
                                    kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found else { return [] }
        let items: [AnyObject] = CFGetTypeID(found) == CFArrayGetTypeID() ? (found as! [AnyObject]) : [found]
        return items.compactMap { CFGetTypeID($0) == SecCertificateGetTypeID() ? ($0 as! SecCertificate) : nil }.filter(isOurs)
    }

    private static func identity(for certificate: SecCertificate) -> MoonlightClientIdentity? {
        var secIdentity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &secIdentity) == errSecSuccess, let secIdentity else { return nil }
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(secIdentity, &key) == errSecSuccess, let key else { return nil }
        return identity(privateKey: key, certificate: certificate, identity: secIdentity)
    }

    private static func loadExisting() -> MoonlightClientIdentity? {
        storedCertificates().lazy.compactMap(identity(for:)).first
    }

    /// The certificate comes from the host record; the Keychain finds its private key.
    private static func loadHostIdentity(_ reference: MoonlightIdentityReference) -> MoonlightClientIdentity? {
        SecCertificateCreateWithData(nil, reference.certificateDER as CFData).flatMap(identity(for:))
    }

    private static func create(label: String, keyTag: Data, commonName: String) throws -> MoonlightClientIdentity {
        deleteItems(label: label, keyTag: keyTag)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrLabel as String: label,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: keyTag, kSecAttrLabel as String: label]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightError(message: "Could not create the Moonlight client key in the login keychain: \((error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error")")
        }
        let der = try MoonlightClientIdentity.makeCertificate(privateKey: key, commonName: commonName)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MoonlightError(message: "The generated client certificate is invalid.")
        }
        let status = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: label] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            deleteItems(label: label, keyTag: keyTag)
            throw MoonlightError(message: "Could not store the Moonlight client certificate in the login keychain (\(status)).")
        }
        var secIdentity: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &secIdentity)
        guard identityStatus == errSecSuccess, let secIdentity else {
            deleteItems(label: label, keyTag: keyTag)
            throw MoonlightError(message: "The Keychain could not pair the Moonlight client certificate with its key (\(identityStatus)).")
        }
        return identity(privateKey: key, certificate: certificate, identity: secIdentity)
    }
    #else
    /// Every identity the Keychain reports for this app (it holds a handful at most).
    private static func storedIdentities(label: String? = nil) -> [(SecIdentity, SecCertificate, SecKey)] {
        var query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        if let label { query[kSecAttrLabel as String] = label }
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found else { return [] }
        let items: [AnyObject] = CFGetTypeID(found) == CFArrayGetTypeID() ? (found as! [AnyObject]) : [found]
        return items.compactMap { item in
            guard CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
            let secIdentity = item as! SecIdentity
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess, let certificate,
                  SecIdentityCopyPrivateKey(secIdentity, &key) == errSecSuccess, let key else { return nil }
            return (secIdentity, certificate, key)
        }
    }

    private static func loadExisting() -> MoonlightClientIdentity? {
        storedIdentities(label: certificateLabel).first { isOurs($0.1) }.map { identity(privateKey: $0.2, certificate: $0.1, identity: $0.0) }
    }

    /// Matched by the exact certificate the host record stores, whatever the label filter does.
    private static func loadHostIdentity(_ reference: MoonlightIdentityReference) -> MoonlightClientIdentity? {
        storedIdentities().first { SecCertificateCopyData($0.1) as Data == reference.certificateDER }
            .map { identity(privateKey: $0.2, certificate: $0.1, identity: $0.0) }
    }

    /// Permanent key straight into the data-protection keychain, then the certificate; the
    /// identity is what the Keychain reports for the pair.
    private static func create(label: String, keyTag: Data, commonName: String) throws -> MoonlightClientIdentity {
        deleteItems(label: label, keyTag: keyTag)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightError(message: "Could not create the Moonlight client key: \((error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error")")
        }
        let der = try MoonlightClientIdentity.makeCertificate(privateKey: key, commonName: commonName)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MoonlightError(message: "The generated client certificate is invalid.")
        }
        let status = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: label,
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            deleteItems(label: label, keyTag: keyTag)
            throw MoonlightError(message: "Could not store the Moonlight client certificate (\(status)).")
        }
        guard let stored = storedIdentities().first(where: { SecCertificateCopyData($0.1) as Data == der }) else {
            deleteItems(label: label, keyTag: keyTag)
            throw MoonlightError(message: "The Keychain stored the Moonlight client certificate but reports no identity for it.")
        }
        return identity(privateKey: stored.2, certificate: stored.1, identity: stored.0)
    }
    #endif

    /// Human-readable state of the shared identity, for support and the Mac self-test.
    static func diagnostics() -> String {
        var lines: [String] = []
        for protected in keychains {
            let name = protected ? "data-protection keychain" : "login keychain"
            func count(_ query: [String: Any]) -> String {
                var items: CFTypeRef?
                var full = query
                full[kSecMatchLimit as String] = kSecMatchLimitAll
                full[kSecReturnAttributes as String] = true
                let status = SecItemCopyMatching(withKeychain(full, protected: protected) as CFDictionary, &items)
                return status == errSecSuccess ? "\((items as? [Any])?.count ?? 0)" : "none (\(status))"
            }
            let certificates = count([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: certificateLabel])
            let keys = count([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: legacyKeyTag])
            lines.append("\(name): shared certificates \(certificates), shared keys \(keys)")
        }
        lines.append("stored shared identity: \(loadExisting() != nil ? "yes" : "no")")
        do {
            let identity = try loadOrCreate()
            let subject = SecCertificateCreateWithData(nil, identity.certificateDER as CFData).flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "?"
            lines.append("loadOrCreate: ok, TLS identity \(identity.secIdentity != nil ? "available" : "MISSING"), certificate \(identity.certificateDER.count) bytes, subject \"\(subject)\"")
            do {
                let signature = try identity.sign(Data("probe".utf8))
                lines.append("private key signs: yes (\(signature.count) bytes)")
            } catch {
                lines.append("private key signs: NO (\(error))")
            }
        } catch {
            lines.append("loadOrCreate failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// Client certificate of the shared identity, PEM encoded (self-test helper).
    static func currentCertificatePEM() throws -> String { try loadOrCreate().certificatePEM }

    /// Performs one HTTPS GET with the shared identity as the TLS client certificate, against a
    /// server whose DER certificate is given, and reports the outcome (self-test helper).
    static func probeTLS(url: URL, serverCertificateDER: Data) async -> String {
        do {
            let identity = try loadOrCreate()
            let endpoints = try MoonlightEndpoints.standard(host: url.host ?? "127.0.0.1", httpPort: url.port ?? 47989, httpsPort: url.port ?? 47984)
            let transport = MoonlightTransport(endpoints: endpoints, uniqueID: "selftest0000beef", deviceName: "Orbit self-test",
                                               serverCertificate: serverCertificateDER, identity: identity.secIdentity)
            let data = try await transport.request(secure: true, path: url.path.isEmpty ? "/serverinfo" : url.path, query: [], timeout: 10)
            return "TLS probe: HTTP 200, \(data.count) bytes: \(String(decoding: data.prefix(160), as: UTF8.self))"
        } catch {
            return "TLS probe failed: \(error)"
        }
    }
}

// MARK: - XML responses

/// Tiny DOM for Sunshine's small XML replies (`<root status_code="200"><paired>1</paired>…`).
final class MoonlightXMLNode {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [MoonlightXMLNode] = []
    weak var parent: MoonlightXMLNode?
    init(name: String, attributes: [String: String], parent: MoonlightXMLNode?) {
        self.name = name; self.attributes = attributes; self.parent = parent
    }
    func first(_ name: String) -> MoonlightXMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String? { first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var statusCode: Int { Int(attributes["status_code"] ?? "") ?? 0 }
    var statusMessage: String? { attributes["status_message"] }
}

final class MoonlightXML: NSObject, XMLParserDelegate {
    private var root: MoonlightXMLNode?
    private var current: MoonlightXMLNode?

    static func parse(_ data: Data) throws -> MoonlightXMLNode {
        let parser = XMLParser(data: data)
        let delegate = MoonlightXML()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = delegate.root else {
            throw MoonlightError(message: "The host returned an unreadable reply.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let node = MoonlightXMLNode(name: elementName, attributes: attributes, parent: current)
        if let current { current.children.append(node) } else { root = node }
        current = node
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { current?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { current = current?.parent }
}

// MARK: - Models

struct MoonlightServerInfo: Equatable {
    var hostname = ""
    var appVersion = ""
    var gfeVersion = ""
    var uniqueID = ""
    var httpsPort = 47984
    var externalPort = 47989
    var macAddress = ""
    var localIP = ""
    var state = ""
    var pairStatus = 0
    var currentGame = 0
    var serverCodecModeSupport = 0

    var majorVersion: Int { Int(appVersion.split(separator: ".").first ?? "0") ?? 0 }
    var isBusy: Bool { currentGame > 0 || state.hasSuffix("_SERVER_BUSY") }
    var supportsHEVC: Bool { serverCodecModeSupport & 0x100 != 0 }
    var supportsAV1: Bool { serverCodecModeSupport & 0x10000 != 0 }

    static func parse(_ node: MoonlightXMLNode) -> MoonlightServerInfo {
        var info = MoonlightServerInfo()
        info.hostname = node.value("hostname") ?? ""
        info.appVersion = node.value("appversion") ?? ""
        info.gfeVersion = node.value("GfeVersion") ?? ""
        info.uniqueID = node.value("uniqueid") ?? ""
        info.httpsPort = Int(node.value("HttpsPort") ?? "") ?? 47984
        info.externalPort = Int(node.value("ExternalPort") ?? "") ?? 47989
        info.macAddress = node.value("mac") ?? ""
        info.localIP = node.value("LocalIP") ?? ""
        info.state = node.value("state") ?? ""
        info.pairStatus = Int(node.value("PairStatus") ?? "") ?? 0
        info.currentGame = Int(node.value("currentgame") ?? "") ?? 0
        info.serverCodecModeSupport = Int(node.value("ServerCodecModeSupport") ?? "") ?? 0
        return info
    }
}

struct MoonlightApp: Identifiable, Equatable, Hashable, Codable {
    let id: Int
    let title: String
    let supportsHDR: Bool
}

/// Everything Orbit remembers about one paired Sunshine host, keyed by the PC profile.
struct MoonlightHostRecord: Codable, Equatable {
    var pcID: String
    var address: String
    var httpPort = 47989
    var httpsPort = 47984
    var serverCertificateDER: Data?
    var hostname = ""
    var appVersion = ""
    var pairedAt: Date?
    var apps: [MoonlightApp] = []
    /// Client identity this host trusts; nil for pairings made with the shared identity before 2026-10-22.
    var clientIdentity: MoonlightIdentityReference?
    /// Sunshine's `uniqueid`, which survives address and PC profile changes.
    var serverUniqueID: String?

    var isPaired: Bool { serverCertificateDER != nil && pairedAt != nil }
}

enum MoonlightHostStore {
    private static let recordsKey = "orbit.moonlight.hosts.v1"
    private static let uniqueIDKey = "orbit.moonlight.uniqueid"

    /// The Moonlight protocol identifies a client install by a 16-hex-digit id (not secret).
    static func uniqueID(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: uniqueIDKey), stored.count == 16 { return stored }
        let generated = MoonlightEncoding.hex(MoonlightCrypto.random(8))
        defaults.set(generated, forKey: uniqueIDKey)
        return generated
    }
    static func records(defaults: UserDefaults = .standard) -> [MoonlightHostRecord] {
        guard let data = defaults.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([MoonlightHostRecord].self, from: data)) ?? []
    }
    static func record(for pcID: String, defaults: UserDefaults = .standard) -> MoonlightHostRecord? {
        records(defaults: defaults).first { $0.pcID == pcID }
    }
    static func save(_ record: MoonlightHostRecord, defaults: UserDefaults = .standard) {
        var all = records(defaults: defaults).filter { $0.pcID != record.pcID }
        all.append(record)
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: recordsKey) }
    }
    static func remove(pcID: String, defaults: UserDefaults = .standard) {
        let remaining = records(defaults: defaults).filter { $0.pcID != pcID }
        if let data = try? JSONEncoder().encode(remaining) { defaults.set(data, forKey: recordsKey) }
    }

    /// A throwaway id for one pairing attempt. Sunshine 2026 keeps an abandoned pairing request
    /// for five minutes and refuses another one with the same uniqueid until then.
    static func pairingUniqueID() -> String { MoonlightEncoding.hex(MoonlightCrypto.random(8)) }

    /// The pairing of the same Sunshine host saved under another PC profile id (profiles get new
    /// ids when iCloud sync merges duplicates or a PC is added again). Matched by Sunshine's
    /// uniqueid when known, else by address; copied to `pcID` and returned.
    static func adopt(pcID: String, address: String, serverUniqueID: String? = nil, defaults: UserDefaults = .standard) -> MoonlightHostRecord? {
        let candidates = records(defaults: defaults).filter { record in
            guard record.isPaired, record.pcID != pcID else { return false }
            if let serverUniqueID, !serverUniqueID.isEmpty { return record.serverUniqueID == serverUniqueID }
            return !address.isEmpty && record.address == address
        }
        guard var adopted = candidates.max(by: { ($0.pairedAt ?? .distantPast) < ($1.pairedAt ?? .distantPast) }) else { return nil }
        adopted.pcID = pcID
        if !address.isEmpty { adopted.address = address }
        save(adopted, defaults: defaults)
        return adopted
    }

    /// Drops every saved pairing of the same Sunshine host that presents the same client identity
    /// as `record`: Sunshine refused that certificate, so none of those copies can work.
    static func removeRefused(_ record: MoonlightHostRecord, defaults: UserDefaults = .standard) {
        let remaining = records(defaults: defaults).filter { other in
            let sameHost = other.pcID == record.pcID || (!record.address.isEmpty && other.address == record.address)
                || (record.serverUniqueID != nil && other.serverUniqueID == record.serverUniqueID)
            return !(sameHost && other.clientIdentity?.id == record.clientIdentity?.id)
        }
        if let data = try? JSONEncoder().encode(remaining) { defaults.set(data, forKey: recordsKey) }
    }

    /// Whether any saved pairing other than `pcID`'s still presents this client identity.
    static func identityInUse(_ reference: MoonlightIdentityReference, excluding pcID: String, defaults: UserDefaults = .standard) -> Bool {
        records(defaults: defaults).contains { $0.pcID != pcID && $0.clientIdentity?.id == reference.id }
    }
}

// MARK: - Transport

/// Base URLs of one host. Tests point both at a plain HTTP mock; the apps use
/// http://host:47989 before pairing and https://host:47984 with the client certificate after.
struct MoonlightEndpoints {
    var http: URL
    var https: URL
    static func standard(host: String, httpPort: Int = 47989, httpsPort: Int = 47984) throws -> MoonlightEndpoints {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), !clean.contains("?"),
              (1...65535).contains(httpPort), (1...65535).contains(httpsPort) else {
            throw MoonlightError(message: "The Sunshine host address is invalid.")
        }
        guard let http = URL(string: "http://\(clean):\(httpPort)"), let https = URL(string: "https://\(clean):\(httpsPort)") else {
            throw MoonlightError(message: "The Sunshine host address is invalid.")
        }
        return MoonlightEndpoints(http: http, https: https)
    }
}

/// URLSession wrapper: pins the Sunshine server certificate learned during pairing and
/// presents the client identity for HTTPS requests. Redirects are refused.
final class MoonlightTransport: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let endpoints: MoonlightEndpoints
    let uniqueID: String
    let deviceName: String
    private let identity: SecIdentity?
    private let lock = NSLock()
    private var pinnedServerCertificate: Data?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(endpoints: MoonlightEndpoints, uniqueID: String, deviceName: String, serverCertificate: Data?, identity: SecIdentity?) {
        self.endpoints = endpoints
        self.uniqueID = uniqueID
        self.deviceName = String(deviceName.prefix(40))
        self.identity = identity
        pinnedServerCertificate = serverCertificate
    }
    deinit { session.invalidateAndCancel() }

    func pin(serverCertificate: Data) { lock.lock(); pinnedServerCertificate = serverCertificate; lock.unlock() }
    var serverCertificate: Data? { lock.lock(); defer { lock.unlock() }; return pinnedServerCertificate }

    func request(secure: Bool, path: String, query: [(String, String)], timeout: TimeInterval = 15) async throws -> Data {
        guard var components = URLComponents(url: secure ? endpoints.https : endpoints.http, resolvingAgainstBaseURL: false) else {
            throw MoonlightError(message: "Invalid Sunshine host.")
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "uniqueid", value: uniqueID), URLQueryItem(name: "devicename", value: deviceName)]
            + query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw MoonlightError(message: "Invalid Sunshine request.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoonlightError(message: "Sunshine did not answer.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw MoonlightError.untrustedClient }
            throw MoonlightError(message: "Sunshine returned HTTP \(http.statusCode).")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw MoonlightError(message: "The Sunshine reply is too large.") }
        return data
    }

    func xml(secure: Bool, path: String, query: [(String, String)] = [], timeout: TimeInterval = 15) async throws -> MoonlightXMLNode {
        let node = try MoonlightXML.parse(try await request(secure: secure, path: path, query: query, timeout: timeout))
        guard node.statusCode == 200 else {
            // Sunshine answers an unknown, disabled or duplicated client certificate with HTTP 200
            // and `status_code="401"` ("The client is not authorized. Certificate verification failed.").
            if secure && node.statusCode == 401 { throw MoonlightError.untrustedClient }
            throw MoonlightError(message: node.statusMessage.map { "Sunshine: \($0)" } ?? "Sunshine refused the request (\(node.statusCode)).")
        }
        return node
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  let pinned = serverCertificate, SecCertificateCopyData(leaf) as Data == pinned else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            // Sunshine's certificate is self-signed; identity is the exact certificate obtained during pairing.
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Protocol operations

enum MoonlightClient {
    /// Four-digit PIN the user types into Sunshine's web UI (Pairing page) on the PC.
    static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    static func serverInfo(_ transport: MoonlightTransport, secure: Bool) async throws -> MoonlightServerInfo {
        MoonlightServerInfo.parse(try await transport.xml(secure: secure, path: "/serverinfo", timeout: 6))
    }

    static func appList(_ transport: MoonlightTransport) async throws -> [MoonlightApp] {
        let root = try await transport.xml(secure: true, path: "/applist")
        return root.children.filter { $0.name == "App" }.compactMap { app in
            guard let id = Int(app.value("ID") ?? ""), let title = app.value("AppTitle") else { return nil }
            return MoonlightApp(id: id, title: title, supportsHDR: app.value("IsHdrSupported") == "1")
        }
    }

    static func appAsset(_ transport: MoonlightTransport, appID: Int) async throws -> Data {
        try await transport.request(secure: true, path: "/appasset", query: [("appid", String(appID)), ("AssetType", "2"), ("AssetIdx", "0")])
    }

    /// Ends the running app and its stream (`/cancel`).
    static func quit(_ transport: MoonlightTransport) async throws {
        _ = try await transport.xml(secure: true, path: "/cancel", timeout: 30)
    }

    /// Complete PIN pairing. `onStage` receives short progress messages for the UI.
    /// The first request blocks until the PIN is entered on the PC, so it may take minutes.
    static func pair(_ transport: MoonlightTransport, identity: MoonlightClientIdentity, pin: String, serverMajorVersion: Int,
                     onStage: @Sendable (String) -> Void = { _ in }) async throws -> Data {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { throw MoonlightError(message: "The PIN must have four digits.") }
        guard serverMajorVersion >= 7 else { throw MoonlightError(message: "This host is too old for Orbit; update Sunshine.") }
        let salt = MoonlightCrypto.random(16)
        let clientCertHex = MoonlightEncoding.hex(Data(identity.certificatePEM.utf8))

        onStage("Waiting for the PIN on the PC…")
        let first = try await transport.xml(secure: false, path: "/pair", query: [
            ("updateState", "1"), ("phrase", "getservercert"), ("salt", MoonlightEncoding.hex(salt)), ("clientcert", clientCertHex)
        ], timeout: 150)
        guard first.value("paired") == "1", let plainCertHex = first.value("plaincert"), !plainCertHex.isEmpty,
              let pemData = MoonlightEncoding.bytes(fromHex: plainCertHex), let pem = String(data: pemData, encoding: .utf8),
              let serverCert = MoonlightEncoding.der(fromPEM: pem) else {
            throw MoonlightError(message: "Pairing was declined by the host, or another pairing is already in progress.")
        }
        transport.pin(serverCertificate: serverCert)
        let aesKey = MoonlightCrypto.sha256(salt + Data(pin.utf8)).prefix(16)

        onStage("Exchanging challenges…")
        let clientChallenge = MoonlightCrypto.random(16)
        let second = try await transport.xml(secure: false, path: "/pair", query: [
            ("updateState", "1"), ("clientchallenge", MoonlightEncoding.hex(try MoonlightCrypto.aesECB(clientChallenge, key: aesKey, encrypt: true)))
        ])
        guard second.value("paired") == "1", let encryptedResponse = MoonlightEncoding.bytes(fromHex: second.value("challengeresponse") ?? ""),
              encryptedResponse.count == 48 else { throw MoonlightError(message: "Pairing stage 2 failed.") }
        let decrypted = try MoonlightCrypto.aesECB(encryptedResponse, key: aesKey, encrypt: false)
        let serverResponse = decrypted.prefix(32)
        let serverChallenge = decrypted.suffix(16)

        let clientSecret = MoonlightCrypto.random(16)
        let challengeHash = MoonlightCrypto.sha256(serverChallenge + (try identity.certificateSignature()) + clientSecret)
        let third = try await transport.xml(secure: false, path: "/pair", query: [
            ("updateState", "1"), ("serverchallengeresp", MoonlightEncoding.hex(try MoonlightCrypto.aesECB(challengeHash, key: aesKey, encrypt: true)))
        ])
        guard third.value("paired") == "1", let pairingSecret = MoonlightEncoding.bytes(fromHex: third.value("pairingsecret") ?? ""),
              pairingSecret.count > 16 else { throw MoonlightError(message: "Pairing stage 3 failed.") }
        let serverSecret = pairingSecret.prefix(16)
        let serverSignature = pairingSecret.suffix(from: pairingSecret.startIndex + 16)
        guard MoonlightCrypto.verify(Data(serverSecret), signature: Data(serverSignature), certificateDER: serverCert) else {
            throw MoonlightError(message: "The host certificate signature is invalid (possible impersonation).")
        }
        let expected = MoonlightCrypto.sha256(clientChallenge + (try MoonlightDER.certificateSignature(serverCert)) + serverSecret)
        guard expected == Data(serverResponse) else { throw MoonlightError(message: "Incorrect PIN. Start pairing again.") }

        onStage("Confirming with the host…")
        let clientPairingSecret = clientSecret + (try identity.sign(clientSecret))
        let fourth = try await transport.xml(secure: false, path: "/pair", query: [
            ("updateState", "1"), ("clientpairingsecret", MoonlightEncoding.hex(clientPairingSecret))
        ])
        guard fourth.value("paired") == "1" else { throw MoonlightError(message: "Pairing stage 4 failed.") }

        let fifth = try await transport.xml(secure: true, path: "/pair", query: [("updateState", "1"), ("phrase", "pairchallenge")])
        guard fifth.value("paired") == "1" else { throw MoonlightError(message: "The host did not accept the client certificate.") }
        return serverCert
    }
}

// MARK: - Observable host coordinator (shared by the SwiftUI apps)

#if canImport(Combine)
import Combine

extension MoonlightClientIdentity: @unchecked Sendable {}

/// Drives one Sunshine host for the UI: pairing state, server status, app list and box art.
/// One instance per screen; call `configure` whenever the selected PC changes.
@MainActor
final class MoonlightHostCoordinator: ObservableObject {
    @Published private(set) var record: MoonlightHostRecord?
    @Published private(set) var info: MoonlightServerInfo?
    @Published private(set) var apps: [MoonlightApp] = []
    @Published private(set) var artwork: [Int: Data] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPairing = false
    @Published private(set) var pairingPIN: String?
    @Published private(set) var pairingStage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var reachable = false
    @Published private(set) var lastRefreshed: Date?

    private(set) var address = ""
    private var pcID = ""
    private var httpPort = 47989
    private var httpsPort = 47984
    private var generation = 0
    private var pairingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = -1
    private var artworkTasks: Set<Int> = []

    var isConfigured: Bool { !pcID.isEmpty && !address.isEmpty }
    var isPaired: Bool { record?.isPaired == true }
    var isBusy: Bool { info?.isBusy == true }
    /// Title of the app Sunshine reports as running, when known.
    var runningAppTitle: String? {
        guard let info, info.currentGame > 0 else { return nil }
        return apps.first { $0.id == info.currentGame }?.title ?? "App #\(info.currentGame)"
    }
    /// Sunshine's web UI pairing page on the PC, where the PIN is typed.
    var pairingPageURL: URL? { URL(string: "https://\(address):\(httpPort + 1)/pin") }
    var hostDisplayName: String { info?.hostname ?? record?.hostname ?? address }

    /// Short human-readable state for status pills.
    var statusText: String {
        if isPairing { return "Pairing…" }
        if !isConfigured { return "No PC" }
        if !isPaired { return reachable ? "Not paired" : "Sunshine not found" }
        if !reachable { return "Unreachable" }
        return isBusy ? "Streaming" : "Ready"
    }

    func configure(pcID: String, address: String, httpPort: Int = 47989, httpsPort: Int = 47984) {
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pcID != self.pcID || cleanAddress != self.address || httpPort != self.httpPort || httpsPort != self.httpsPort else { return }
        generation += 1
        cancelPairing()
        self.pcID = pcID
        self.address = cleanAddress
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        info = nil; apps = []; artwork = [:]; lastError = nil; reachable = false; lastRefreshed = nil
        record = pcID.isEmpty ? nil : (MoonlightHostStore.record(for: pcID) ?? MoonlightHostStore.adopt(pcID: pcID, address: cleanAddress))
        if var stored = record, stored.address != cleanAddress, !cleanAddress.isEmpty {
            stored.address = cleanAddress
            MoonlightHostStore.save(stored)
            record = stored
        }
        apps = record?.apps ?? []
    }

    /// Updates the ports reported by the Orbit agent (`/api/sunshine/info`) without dropping state.
    func updatePorts(http: Int, https: Int) {
        guard (1...65535).contains(http), (1...65535).contains(https), http != httpPort || https != httpsPort else { return }
        httpPort = http; httpsPort = https
        if var stored = record { stored.httpPort = http; stored.httpsPort = https; MoonlightHostStore.save(stored); record = stored }
    }

    /// Transport with the stored pairing, for launching and controlling streams.
    func streamingTransport() async throws -> MoonlightTransport {
        guard isPaired else { throw MoonlightError(message: "Pair Orbit with Sunshine on this PC first.") }
        return try makeTransport(identity: try await Self.loadIdentity(for: record?.clientIdentity))
    }

    private func makeTransport(identity: MoonlightClientIdentity?, uniqueID: String = MoonlightHostStore.uniqueID()) throws -> MoonlightTransport {
        let endpoints = try MoonlightEndpoints.standard(host: address, httpPort: httpPort, httpsPort: httpsPort)
        return MoonlightTransport(endpoints: endpoints, uniqueID: uniqueID, deviceName: Self.deviceName,
                                  serverCertificate: record?.serverCertificateDER, identity: identity?.secIdentity)
    }

    private static func loadIdentity(for reference: MoonlightIdentityReference?) async throws -> MoonlightClientIdentity {
        try await Task.detached(priority: .userInitiated) { try MoonlightIdentityStore.identity(for: reference) }.value
    }

    /// Name Sunshine shows for this device; the same text goes with the pairing request and the
    /// PIN the agent types, which is how the agent finds the request among several.
    static var pairingName: String { String(deviceName.prefix(40)) }

    static var deviceName: String {
        #if os(macOS)
        return "Orbit on \(Host.current().localizedName ?? "Mac")"
        #elseif os(tvOS)
        return "Orbit on Apple TV"
        #else
        return "Orbit on iPhone"
        #endif
    }

    /// Reads server info (and the app list when paired). Never throws; errors land in `lastError`.
    func refresh() async {
        guard isConfigured, !isPairing else { return }
        // One refresh per PC at a time, running on its own: views call this from `.task(id:)`,
        // which is cancelled whenever its key changes (the PC coming online, Sunshine's ports
        // arriving). Tied to that task, the request was cut off half-way, left "cancelled" as the
        // error and the follow-up call was skipped as a duplicate. Later callers now wait for it.
        if let running = refreshTask, refreshGeneration == generation {
            await running.value
            return
        }
        let version = generation
        let task = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { if version == self.generation { self.isRefreshing = false } }
            // A pairing found under another profile id is used right away.
            if await self.refreshOnce(version: version) { _ = await self.refreshOnce(version: version) }
        }
        refreshTask = task
        refreshGeneration = version
        await task.value
        if refreshGeneration == version { refreshTask = nil }
    }

    /// One server info (+ app list) pass. Returns true when it adopted a pairing and should run again.
    private func refreshOnce(version: Int) async -> Bool {
        do {
            let identity = isPaired ? try await Self.loadIdentity(for: record?.clientIdentity) : nil
            guard version == generation else { return false }
            let transport = try makeTransport(identity: identity)
            if isPaired {
                do {
                    let secure = try await MoonlightClient.serverInfo(transport, secure: true)
                    guard version == generation else { return false }
                    info = secure
                    reachable = true
                    lastError = nil
                    let fetched = try await MoonlightClient.appList(transport)
                    guard version == generation else { return false }
                    apps = fetched
                    if var stored = record {
                        stored.apps = fetched; stored.hostname = secure.hostname; stored.appVersion = secure.appVersion
                        if !secure.uniqueID.isEmpty { stored.serverUniqueID = secure.uniqueID }
                        MoonlightHostStore.save(stored); record = stored
                    }
                } catch let error as MoonlightError where error.untrusted {
                    // Sunshine dropped, disabled or duplicated this certificate: offer pairing again.
                    pairingWasRefused(error)
                    reachable = true
                }
            } else {
                let plain = try await MoonlightClient.serverInfo(transport, secure: false)
                guard version == generation else { return false }
                info = plain
                reachable = true
                lastError = nil
                if !plain.uniqueID.isEmpty, let adopted = MoonlightHostStore.adopt(pcID: pcID, address: address, serverUniqueID: plain.uniqueID) {
                    record = adopted
                    apps = adopted.apps
                    return true
                }
            }
            lastRefreshed = Date()
        } catch let error as MoonlightError where error.untrusted {
            // The identity this host was paired with is gone from the Keychain (for example after
            // restoring a backup on another device): pairing again is the only way back.
            guard version == generation else { return false }
            pairingWasRefused(error)
        } catch {
            guard version == generation else { return false }
            // A cancelled request says nothing about Sunshine; keep what was known.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            reachable = false
            info = nil
            lastError = (error as? MoonlightError)?.message ?? error.localizedDescription
        }
        return false
    }

    /// Generates a PIN and waits for it to be typed into Sunshine's web UI on the PC.
    ///
    /// Each attempt pairs a brand-new client certificate (see `MoonlightIdentityStore`) under a
    /// throwaway uniqueid, so neither an earlier pairing nor an abandoned request gets in the way.
    func beginPairing() {
        guard isConfigured, !isPairing else { return }
        let version = generation
        let pin = MoonlightClient.generatePIN()
        pairingPIN = pin
        pairingStage = "Enter the PIN in Sunshine on the PC…"
        lastError = nil
        isPairing = true
        pairingTask = Task { [weak self] in
            guard let self else { return }
            var fresh: MoonlightIdentityReference?
            do {
                let created = try await Task.detached(priority: .userInitiated) { try MoonlightIdentityStore.createForPairing() }.value
                fresh = created.reference
                guard !Task.isCancelled, version == self.generation else { MoonlightIdentityStore.remove(created.reference); return }
                let transport = try self.makeTransport(identity: created.identity, uniqueID: MoonlightHostStore.pairingUniqueID())
                let probe = try await MoonlightClient.serverInfo(transport, secure: false)
                guard !Task.isCancelled, version == self.generation else { MoonlightIdentityStore.remove(created.reference); return }
                let certificate = try await MoonlightClient.pair(transport, identity: created.identity, pin: pin, serverMajorVersion: probe.majorVersion) { [weak self] stage in
                    Task { @MainActor in self?.pairingStage = stage }
                }
                guard !Task.isCancelled, version == self.generation else { MoonlightIdentityStore.remove(created.reference); return }
                let previous = self.record?.clientIdentity
                var stored = MoonlightHostRecord(pcID: self.pcID, address: self.address, httpPort: self.httpPort, httpsPort: self.httpsPort)
                stored.serverCertificateDER = certificate
                stored.hostname = probe.hostname
                stored.appVersion = probe.appVersion
                stored.pairedAt = Date()
                stored.clientIdentity = created.reference
                stored.serverUniqueID = probe.uniqueID.isEmpty ? nil : probe.uniqueID
                MoonlightHostStore.save(stored)
                if let previous, previous.id != created.reference.id, !MoonlightHostStore.identityInUse(previous, excluding: self.pcID) {
                    MoonlightIdentityStore.remove(previous)
                }
                self.record = stored
                self.pairingStage = "Paired with \(probe.hostname.isEmpty ? self.address : probe.hostname)"
                self.isPairing = false
                self.pairingPIN = nil
                await self.refresh()
            } catch {
                if let fresh { MoonlightIdentityStore.remove(fresh) }
                guard !Task.isCancelled, version == self.generation else { return }
                self.lastError = (error as? MoonlightError)?.message ?? error.localizedDescription
                self.pairingStage = nil
                self.pairingPIN = nil
                self.isPairing = false
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        if isPairing { pairingStage = nil; pairingPIN = nil; isPairing = false }
    }

    /// Sunshine refused this device's certificate while streaming: drop the pairing so the
    /// Stream tab offers pairing again, and say why.
    func pairingWasRefused(_ error: MoonlightError) {
        if let record { MoonlightHostStore.removeRefused(record) }
        forgetPairing()
        lastError = error.message
    }

    func forgetPairing() {
        cancelPairing()
        if let identity = record?.clientIdentity, !MoonlightHostStore.identityInUse(identity, excluding: pcID) {
            MoonlightIdentityStore.remove(identity)
        }
        MoonlightHostStore.remove(pcID: pcID)
        record = nil
        apps = []
        artwork = [:]
        info = nil
    }

    /// Asks Sunshine to end the running app and its stream.
    func quitRunningApp() async {
        guard isPaired else { return }
        let version = generation
        do {
            let transport = try makeTransport(identity: try await Self.loadIdentity(for: record?.clientIdentity))
            try await MoonlightClient.quit(transport)
            guard version == generation else { return }
            lastError = nil
            await refresh()
        } catch {
            guard version == generation else { return }
            lastError = (error as? MoonlightError)?.message ?? error.localizedDescription
        }
    }

    /// Fetches box art once per app; the UI shows a placeholder until it arrives.
    func loadArtwork(for app: MoonlightApp) {
        guard isPaired, artwork[app.id] == nil, !artworkTasks.contains(app.id) else { return }
        artworkTasks.insert(app.id)
        let version = generation
        Task { [weak self] in
            guard let self else { return }
            defer { self.artworkTasks.remove(app.id) }
            guard let identity = try? await Self.loadIdentity(for: self.record?.clientIdentity), let transport = try? self.makeTransport(identity: identity),
                  let data = try? await MoonlightClient.appAsset(transport, appID: app.id), data.count > 64, version == self.generation else { return }
            self.artwork[app.id] = data
        }
    }

    /// Sunshine app matching an agent library entry (titles come from the same apps.json).
    func app(titled title: String) -> MoonlightApp? {
        apps.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }
}
#endif
