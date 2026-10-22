import Foundation
import CryptoKit
import SRP

struct PCPairingCredentials: Decodable {
    let hostname: String
    let ipAddress: String
    let agentPort: Int
    let securePort: Int
    let macAddress: String
    let subnetMask: String
    let broadcastAddress: String
    let apiToken: String
    let widgetToken: String
    let certificateFingerprint: String
}

/// Bootstrap hints are untrusted until the PIN proves the SRP secret and the
/// encrypted result authenticates the certificate used for this connection.
final class OrbitPairingHandshake {
    /// `platform` and `model` (Orbit Companion 5) name the device in the PC's device list and
    /// PIN dialog; older companions ignore them.
    private struct Begin: Encodable { let name: String; let clientPublic: String; let platform: String; let model: String }
    private struct Challenge: Decodable {
        let id: String; let `protocol`: String; let salt: String; let serverPublic: String; let expiresIn: Int
    }
    private struct Finish: Encodable { let id: String; let proof: String }
    private struct Confirmation: Decodable { let serverProof: String; let nonce: Data; let ciphertext: Data }
    private let client = SRPClient(configuration: SRPConfiguration<SHA256>(.N2048))
    private let keys: SRPKeyPair
    private let transport: OrbitAPIClient
    private let fingerprint: String
    private var challenge: Challenge?
    private var used = false

    init(host: String, port: Int, fingerprint: String) throws {
        self.fingerprint = OrbitAPIClient.normalizedFingerprint(fingerprint)
        transport = try OrbitAPIClient(host: host, port: port, token: "", fingerprint: fingerprint, pairingOnly: true)
        keys = client.generateKeys()
    }

    func begin(name: String) async throws -> Int {
        guard challenge == nil, !used else { throw OrbitError(message: "Request a new pairing code.") }
        let result: Challenge = try await transport.send("/api/pair/start", body: Begin(name: String(name.prefix(60)), clientPublic: keys.public.hex,
                                                                                  platform: OrbitDeviceIdentity.platform, model: OrbitDeviceIdentity.model))
        guard result.protocol == "orbit-srp6a-sha256-2048-v1", result.id.count >= 20, result.id.count <= 80,
              Self.bytes(result.salt)?.count == 16, Self.bytes(result.serverPublic)?.count == 256,
              (1...120).contains(result.expiresIn) else { throw OrbitError(message: "This PC returned an unsupported pairing response. Update Orbit Companion on the PC.") }
        challenge = result
        return result.expiresIn
    }

    func finish(pin: String) async throws -> PCPairingCredentials {
        guard !used, let challenge, pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }),
              let salt = Self.bytes(challenge.salt), let server = SRPKey(hex: challenge.serverPublic, padding: 256) else {
            throw OrbitError(message: "Enter the six-digit code displayed on your PC.")
        }
        used = true
        let secret = try client.calculateSharedSecret(username: "orbit-pairing", password: pin, salt: salt, clientKeys: keys, serverPublicKey: server)
        let proof = client.calculateClientProof(username: "orbit-pairing", salt: salt, clientPublicKey: keys.public, serverPublicKey: server, sharedSecret: secret)
        let response: Confirmation = try await transport.send("/api/pair/finish", body: Finish(id: challenge.id, proof: Self.hex(proof)))
        guard let serverProof = Self.bytes(response.serverProof), serverProof.count == 32, response.nonce.count == 12,
              response.ciphertext.count >= 16, response.ciphertext.count <= 16384 else { throw OrbitError(message: "Invalid pairing confirmation.") }
        try client.verifyServerProof(serverProof: serverProof, clientProof: proof, clientPublicKey: keys.public, sharedSecret: secret)
        let sessionKey = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.with(padding: 256).bytes))))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: Data(challenge.id.utf8),
                                       info: Data("Orbit PIN pairing v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: response.nonce),
                                           ciphertext: response.ciphertext.dropLast(16), tag: response.ciphertext.suffix(16))
        let data = try AES.GCM.open(sealed, using: key, authenticating: Data(challenge.id.utf8))
        let credentials = try JSONDecoder().decode(PCPairingCredentials.self, from: data)
        guard OrbitAPIClient.normalizedFingerprint(credentials.certificateFingerprint) == fingerprint,
              credentials.apiToken.count >= 24, credentials.widgetToken.count >= 24,
              (1...65535).contains(credentials.agentPort), (1...65535).contains(credentials.securePort) else {
            throw OrbitError(message: "The PC identity changed during pairing. Cancel and search again.")
        }
        return credentials
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.count <= 512 else { return nil }
        var result: [UInt8] = []; var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
