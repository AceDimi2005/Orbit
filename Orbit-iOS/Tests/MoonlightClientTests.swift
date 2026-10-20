import Foundation

// Driven by check_moonlight_pairing.py: <port> <pin> <certificate-pem-path>.
// Exercises the production MoonlightClient against the Python Sunshine mock.
@main
struct MoonlightClientTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let port = Int(arguments[1]) else {
            print("usage: moonlight-tests <port> <pin> <pem-path>")
            exit(2)
        }
        let pin = arguments[2]
        let pemPath = arguments[3]

        // DER / encoding primitives
        precondition(MoonlightDER.oid("1.2.840.113549.1.1.11") == [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B], "OID encoding")
        precondition(MoonlightDER.integer([0x80]) == [0x02, 0x02, 0x00, 0x80], "INTEGER keeps a leading zero for high-bit values")
        precondition(MoonlightDER.length(200) == [0x81, 0xC8] && MoonlightDER.length(300) == [0x82, 0x01, 0x2C], "long-form lengths")
        precondition(MoonlightEncoding.bytes(fromHex: "00ff10") == Data([0, 255, 16]) && MoonlightEncoding.hex(Data([0, 255, 16])) == "00FF10", "hex round trip")
        precondition(MoonlightEncoding.bytes(fromHex: "abc") == nil, "odd hex rejected")
        let pemSample = MoonlightEncoding.pem(Data([1, 2, 3]))
        precondition(pemSample.hasPrefix("-----BEGIN CERTIFICATE-----\n") && MoonlightEncoding.der(fromPEM: pemSample) == Data([1, 2, 3]), "PEM round trip")
        let aesKey = Data(repeating: 7, count: 16)
        let block = Data((0..<32).map { UInt8($0) })
        let encryptedBlock = try MoonlightCrypto.aesECB(block, key: aesKey, encrypt: true)
        let decryptedBlock = try MoonlightCrypto.aesECB(encryptedBlock, key: aesKey, encrypt: false)
        precondition(encryptedBlock != block && decryptedBlock == block, "AES-ECB round trip")

        // Client identity: self-signed certificate whose signature verifies with its own key.
        let identity = try MoonlightClientIdentity.ephemeral(commonName: "Orbit Test Client")
        try identity.certificatePEM.write(toFile: pemPath, atomically: true, encoding: .utf8)
        let certificateSignature = try identity.certificateSignature()
        precondition(certificateSignature.count == 256, "RSA-2048 signature length")
        let fields = try MoonlightDER.children(of: try MoonlightDER.children(of: identity.certificateDER)[0].content)
        let tbs = Data(MoonlightDER.tlv(0x30, Array(fields[0].content)))
        precondition(MoonlightCrypto.verify(tbs, signature: certificateSignature, certificateDER: identity.certificateDER), "certificate self-signature verifies")
        precondition(!MoonlightCrypto.verify(tbs + Data([1]), signature: certificateSignature, certificateDER: identity.certificateDER), "tampered data fails")

        // Protocol against the mock (both endpoints on the plain HTTP mock port).
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let transport = MoonlightTransport(endpoints: MoonlightEndpoints(http: base, https: base), uniqueID: "0123456789ABCDEF",
                                           deviceName: "Orbit Test", serverCertificate: nil, identity: nil)
        let unpaired = try await MoonlightClient.serverInfo(transport, secure: false)
        precondition(unpaired.hostname == "MockSunshine" && unpaired.majorVersion == 7 && unpaired.pairStatus == 0 && !unpaired.isBusy, "serverinfo before pairing")
        precondition(unpaired.supportsHEVC && unpaired.supportsAV1, "codec flags")

        let wrongPIN = pin == "0000" ? "0001" : "0000"
        do {
            _ = try await MoonlightClient.pair(transport, identity: identity, pin: wrongPIN, serverMajorVersion: unpaired.majorVersion)
            preconditionFailure("pairing with the wrong PIN must fail")
        } catch let error as MoonlightError {
            precondition(error.message.contains("Incorrect PIN"), "wrong PIN is detected on the client side: \(error.message)")
        }

        var stages: [String] = []
        let stageLock = NSLock()
        let serverCertificate = try await MoonlightClient.pair(transport, identity: identity, pin: pin, serverMajorVersion: unpaired.majorVersion) { stage in
            stageLock.lock(); stages.append(stage); stageLock.unlock()
        }
        precondition(stages.count == 3, "three progress stages reported")
        precondition(transport.serverCertificate == serverCertificate, "server certificate pinned for later HTTPS calls")
        precondition(MoonlightEncoding.der(fromPEM: MoonlightEncoding.pem(serverCertificate)) == serverCertificate, "server certificate round-trips")

        let paired = try await MoonlightClient.serverInfo(transport, secure: true)
        precondition(paired.pairStatus == 1, "serverinfo reports paired")
        let apps = try await MoonlightClient.appList(transport)
        precondition(apps.map(\.title) == ["Desktop", "Steam Big Picture"] && apps.map(\.id) == [1, 2] && apps[1].supportsHDR && !apps[0].supportsHDR, "applist parsed")
        let art = try await MoonlightClient.appAsset(transport, appID: 2)
        precondition(art.starts(with: [0x89, 0x50, 0x4E, 0x47]), "box art is a PNG")
        _ = try await transport.request(secure: true, path: "/launch", query: [("appid", "2")])
        let busy = try await MoonlightClient.serverInfo(transport, secure: true)
        precondition(busy.isBusy, "host busy after launch")
        try await MoonlightClient.quit(transport)
        let free = try await MoonlightClient.serverInfo(transport, secure: true)
        precondition(!free.isBusy, "host free after cancel")

        // Persistence helpers use an isolated defaults domain.
        let defaults = UserDefaults(suiteName: "orbit.moonlight.tests.\(UUID().uuidString)")!
        let uniqueID = MoonlightHostStore.uniqueID(defaults: defaults)
        precondition(uniqueID.count == 16 && MoonlightHostStore.uniqueID(defaults: defaults) == uniqueID, "stable unique id")
        var record = MoonlightHostRecord(pcID: "pc-1", address: "192.168.1.50")
        precondition(!record.isPaired)
        record.serverCertificateDER = serverCertificate; record.pairedAt = Date(); record.apps = apps
        MoonlightHostStore.save(record, defaults: defaults)
        precondition(MoonlightHostStore.record(for: "pc-1", defaults: defaults)?.isPaired == true && MoonlightHostStore.record(for: "pc-1", defaults: defaults)?.apps == apps, "record persisted")
        MoonlightHostStore.remove(pcID: "pc-1", defaults: defaults)
        precondition(MoonlightHostStore.record(for: "pc-1", defaults: defaults) == nil, "record removed")
        precondition((try? MoonlightEndpoints.standard(host: "bad/host")) == nil && (try? MoonlightEndpoints.standard(host: "192.168.1.50")) != nil, "host validation")

        print("PASS: Moonlight client certificate, 5-step Sunshine pairing, app list, box art, cancel and host records")
    }
}
