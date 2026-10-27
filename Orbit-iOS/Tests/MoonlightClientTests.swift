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

        // A refused client certificate ends the pairing: Sunshine's XML 401 over HTTPS and an HTTP 401.
        let refused = MoonlightTransport(endpoints: MoonlightEndpoints(http: base, https: base), uniqueID: "REFUSED000000000",
                                         deviceName: "Orbit Test", serverCertificate: nil, identity: nil)
        do {
            _ = try await MoonlightClient.serverInfo(refused, secure: true)
            preconditionFailure("a refused certificate must throw")
        } catch let error as MoonlightError {
            precondition(error.untrusted, "XML status_code 401 marks the pairing as refused: \(error.message)")
        }
        do {
            _ = try await MoonlightClient.serverInfo(refused, secure: false)
            preconditionFailure("the mock refuses plain requests from this id too")
        } catch let error as MoonlightError {
            precondition(!error.untrusted, "a plain-HTTP reply says nothing about the client certificate")
        }
        let stranger = MoonlightTransport(endpoints: MoonlightEndpoints(http: base, https: base), uniqueID: "FEDCBA9876543210",
                                          deviceName: "Orbit Test", serverCertificate: nil, identity: nil)
        do {
            _ = try await MoonlightClient.appList(stranger)
            preconditionFailure("an unpaired client gets no app list")
        } catch let error as MoonlightError {
            precondition(error.untrusted, "HTTP 401 marks the pairing as refused")
        }

        // Each pairing attempt gets its own throwaway uniqueid.
        let attemptID = MoonlightHostStore.pairingUniqueID()
        precondition(attemptID.count == 16 && attemptID != MoonlightHostStore.pairingUniqueID() && attemptID != uniqueID, "fresh pairing ids")

        // Records written by older versions (no client identity, no Sunshine uniqueid) still load.
        let legacy = #"[{"pcID":"legacy","address":"10.0.0.9","httpPort":47989,"httpsPort":47984,"hostname":"PC","appVersion":"7.1.431.-1","apps":[]}]"#
        defaults.set(Data(legacy.utf8), forKey: "orbit.moonlight.hosts.v1")
        let legacyRecord = MoonlightHostStore.record(for: "legacy", defaults: defaults)
        precondition(legacyRecord != nil && legacyRecord?.clientIdentity == nil && legacyRecord?.serverUniqueID == nil, "legacy record decodes")
        precondition(legacyRecord?.serverCodecModeSupport == nil && legacyRecord?.supportsHEVC == nil, "a host never asked has unknown codecs")
        MoonlightHostStore.remove(pcID: "legacy", defaults: defaults)

        // The host's codecs are remembered, so stream sizes follow them before the host is asked again.
        var codecs = MoonlightHostRecord(pcID: "codecs", address: "10.0.0.8")
        codecs.serverCodecModeSupport = free.serverCodecModeSupport
        MoonlightHostStore.save(codecs, defaults: defaults)
        precondition(MoonlightHostStore.record(for: "codecs", defaults: defaults)?.supportsHEVC == free.supportsHEVC, "codec support persisted")
        codecs.serverCodecModeSupport = 0x1   // H.264 only
        precondition(codecs.supportsHEVC == false, "no HEVC bit, no HEVC")
        MoonlightHostStore.remove(pcID: "codecs", defaults: defaults)

        // A pairing follows its Sunshine host when the PC profile id changes (iCloud merge, PC added again).
        var hostA = MoonlightHostRecord(pcID: "old-profile", address: "192.168.1.60")
        hostA.serverCertificateDER = serverCertificate; hostA.pairedAt = Date(timeIntervalSince1970: 1_000); hostA.serverUniqueID = "HOST-A"
        var hostB = MoonlightHostRecord(pcID: "other-pc", address: "192.168.1.70")
        hostB.serverCertificateDER = serverCertificate; hostB.pairedAt = Date(timeIntervalSince1970: 2_000); hostB.serverUniqueID = "HOST-B"
        MoonlightHostStore.save(hostA, defaults: defaults)
        MoonlightHostStore.save(hostB, defaults: defaults)
        precondition(MoonlightHostStore.adopt(pcID: "new-profile", address: "192.168.1.99", defaults: defaults) == nil, "no adoption from another address")
        let byAddress = MoonlightHostStore.adopt(pcID: "new-profile", address: "192.168.1.60", defaults: defaults)
        precondition(byAddress?.pcID == "new-profile" && byAddress?.serverUniqueID == "HOST-A"
                     && MoonlightHostStore.record(for: "new-profile", defaults: defaults)?.isPaired == true, "adopted by address")
        let byHost = MoonlightHostStore.adopt(pcID: "tailscale-profile", address: "100.64.0.5", serverUniqueID: "HOST-A", defaults: defaults)
        precondition(byHost?.address == "100.64.0.5" && byHost?.pcID == "tailscale-profile", "adopted by Sunshine uniqueid with the new address")
        precondition(MoonlightHostStore.adopt(pcID: "x", address: "192.168.1.60", serverUniqueID: "HOST-C", defaults: defaults) == nil,
                     "another Sunshine host at the same address is never adopted")

        // A refused certificate drops every copy of that host's pairing with the same identity, and only those.
        let reference = MoonlightIdentityReference(id: "per-host-1", certificateDER: Data([1, 2, 3]))
        var first = MoonlightHostRecord(pcID: "lan-profile", address: "10.0.0.1")
        first.serverCertificateDER = serverCertificate; first.pairedAt = Date(); first.clientIdentity = reference; first.serverUniqueID = "HOST-D"
        var sameHost = first; sameHost.pcID = "vpn-profile"; sameHost.address = "100.64.0.9"
        var elsewhere = first; elsewhere.pcID = "second-pc"; elsewhere.address = "10.0.0.2"; elsewhere.serverUniqueID = "HOST-E"
        var sharedIdentity = first; sharedIdentity.pcID = "old-copy"; sharedIdentity.clientIdentity = nil
        for record in [first, sameHost, elsewhere, sharedIdentity] { MoonlightHostStore.save(record, defaults: defaults) }
        precondition(MoonlightHostStore.identityInUse(reference, excluding: "lan-profile", defaults: defaults), "identity still used by other copies")
        MoonlightHostStore.removeRefused(first, defaults: defaults)
        precondition(MoonlightHostStore.record(for: "lan-profile", defaults: defaults) == nil
                     && MoonlightHostStore.record(for: "vpn-profile", defaults: defaults) == nil, "refused copies removed")
        precondition(MoonlightHostStore.record(for: "second-pc", defaults: defaults) != nil, "another host keeps its pairing")
        precondition(MoonlightHostStore.record(for: "old-copy", defaults: defaults) != nil, "a pairing with a different identity is kept")
        precondition(MoonlightHostStore.identityInUse(reference, excluding: "second-pc", defaults: defaults) == false, "no other user of the identity")

        await checkSecondaryAddress(port: port)

        print("PASS: Moonlight client certificate, 5-step Sunshine pairing, app list, box art, cancel, refused certificates, host records and the secondary address")
    }

    /// A Sunshine host that only answers on its secondary address (for example Tailscale) is reached there; the
    /// preferred address follows the Orbit agent's path without dropping state; nothing is stored per address.
    @MainActor
    static func checkSecondaryAddress(port: Int) async {
        let processDefaults = ProcessInfo.processInfo.processName
        defer { UserDefaults.standard.removePersistentDomain(forName: processDefaults) }
        let host = MoonlightHostCoordinator()
        // Nothing answers on 127.0.0.2 (not configured on the loopback): the LAN address times out.
        host.configure(pcID: "secondary-test", address: "127.0.0.2", secondaryAddress: " 127.0.0.1 ", httpPort: port, httpsPort: port)
        precondition(host.activeAddress == "127.0.0.2" && host.secondaryAddress == "127.0.0.1" && !host.isUsingSecondary, "starts on the LAN address")
        await host.refresh()
        precondition(host.reachable && host.isUsingSecondary && host.activeAddress == "127.0.0.1", "reached through the secondary address: \(host.lastError ?? "-")")
        precondition(host.info?.hostname == "MockSunshine" && host.pairingPageURL?.host == "127.0.0.1", "server info and pairing page from the secondary address")

        host.configure(pcID: "secondary-test", address: "127.0.0.2", secondaryAddress: "127.0.0.1", preferSecondary: false, httpPort: port, httpsPort: port)
        precondition(host.activeAddress == "127.0.0.2" && host.info != nil && host.reachable, "same host: only the address to try first changes")
        host.configure(pcID: "secondary-test", address: "127.0.0.2", secondaryAddress: "127.0.0.1", preferSecondary: true, httpPort: port, httpsPort: port)
        precondition(host.activeAddress == "127.0.0.1", "the secondary address goes first while the agent only answers there")
        host.configure(pcID: "secondary-test", address: "127.0.0.2", secondaryAddress: "", preferSecondary: true, httpPort: port, httpsPort: port)
        precondition(host.activeAddress == "127.0.0.2" && !host.isUsingSecondary, "without a secondary address only the LAN address is used")

        precondition(MoonlightHostCoordinator.cleanedSecondary("127.0.0.2", primary: "127.0.0.2").isEmpty, "the LAN address is no secondary address")
        for bad in ["https://100.64.0.1", "100.64.0.1:47989", "100.64.0.1/x", "fe80::1"] {
            precondition(MoonlightHostCoordinator.cleanedSecondary(bad, primary: "10.0.0.1").isEmpty, "\(bad) is not a bare host")
        }
        precondition(MoonlightHostCoordinator.cleanedSecondary("gaming-pc.tail1234.ts.net", primary: "10.0.0.1") == "gaming-pc.tail1234.ts.net", "MagicDNS names work")
        precondition(MoonlightHostCoordinator.mayAnswerElsewhere(URLError(.timedOut)) && !MoonlightHostCoordinator.mayAnswerElsewhere(URLError(.cancelled))
                     && !MoonlightHostCoordinator.mayAnswerElsewhere(MoonlightError.untrustedClient), "only unanswered requests move to the other address")
        precondition(MoonlightHostStore.record(for: "secondary-test") == nil, "nothing stored for an unpaired host on either address")
    }
}
