import CommonCrypto
import CryptoKit
import XCTest
@testable import MoonlightCore

/// The crypto hooks must behave exactly like moonlight-common-c's OpenSSL implementation,
/// otherwise the host rejects control packets or audio decrypts to noise.
final class PlatformCryptoTests: XCTestCase {
    private let gcm: Int32 = 2
    private let cbc: Int32 = 1
    private let resetIV: Int32 = 0x01
    private let finish: Int32 = 0x02
    private let padToBlock: Int32 = 0x04

    private func referenceCBC(encrypt: Bool, key: [UInt8], iv: [UInt8], input: [UInt8], pkcs7: Bool) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(pkcs7 ? kCCOptionPKCS7Padding : 0),
                             key, key.count, iv, input, input.count, &output, output.count, &moved)
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Array(output[0..<moved])
    }

    func testGCMMatchesCryptoKitAndRejectsTampering() throws {
        let encryptor = PltCreateCryptoContext()
        let decryptor = PltCreateCryptoContext()
        defer { PltDestroyCryptoContext(encryptor); PltDestroyCryptoContext(decryptor) }
        var key = [UInt8](repeating: 0x11, count: 16)
        var iv = [UInt8](repeating: 0x22, count: 12)
        var tag = [UInt8](repeating: 0, count: 16)
        var plain = Array("hello moonlight control stream".utf8)
        var cipher = [UInt8](repeating: 0, count: plain.count)
        var length: Int32 = 0

        XCTAssertTrue(PltEncryptMessage(encryptor, gcm, 0, &key, 16, &iv, 12, &tag, 16, &plain, Int32(plain.count), &cipher, &length))
        XCTAssertEqual(Int(length), plain.count)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        XCTAssertEqual(Array(box.ciphertext), cipher)
        XCTAssertEqual(Array(box.tag), tag)

        var decrypted = [UInt8](repeating: 0, count: cipher.count)
        var decryptedLength: Int32 = 0
        XCTAssertTrue(PltDecryptMessage(decryptor, gcm, 0, &key, 16, &iv, 12, &tag, 16, &cipher, Int32(cipher.count), &decrypted, &decryptedLength))
        XCTAssertEqual(Array(decrypted[0..<Int(decryptedLength)]), plain)

        var badTag = tag
        badTag[3] ^= 0x80
        XCTAssertFalse(PltDecryptMessage(decryptor, gcm, 0, &key, 16, &iv, 12, &badTag, 16, &cipher, Int32(cipher.count), &decrypted, &decryptedLength))

        // The video stream uses 16-byte IVs; the IV may change every message without RESET_IV.
        var longIV = [UInt8](repeating: 0x33, count: 16)
        XCTAssertTrue(PltEncryptMessage(encryptor, gcm, 0, &key, 16, &longIV, 16, &tag, 16, &plain, Int32(plain.count), &cipher, &length))
        XCTAssertTrue(PltDecryptMessage(decryptor, gcm, 0, &key, 16, &longIV, 16, &tag, 16, &cipher, Int32(cipher.count), &decrypted, &decryptedLength))
        XCTAssertEqual(Array(decrypted[0..<Int(decryptedLength)]), plain)
    }

    func testCBCPaddedInputKeepsChainingBetweenPackets() {
        let context = PltCreateCryptoContext()
        defer { PltDestroyCryptoContext(context) }
        var key = (0..<16).map { UInt8($0) }
        var iv = (0..<16).map { UInt8(0xF0 | $0) }
        let first = Array("input packet".utf8)                 // 12 bytes → padded to 16
        let second = Array("second packet!!!".utf8)            // 16 bytes → padded to 32
        var input1 = first + [UInt8](repeating: 0, count: 4)
        var output1 = [UInt8](repeating: 0, count: 16)
        var length: Int32 = 0
        XCTAssertTrue(PltEncryptMessage(context, cbc, padToBlock, &key, 16, &iv, 16, nil, 0, &input1, Int32(first.count), &output1, &length))
        XCTAssertEqual(length, 16)
        XCTAssertEqual(output1, referenceCBC(encrypt: true, key: key, iv: iv, input: first, pkcs7: true))

        // moonlight-common-c's ROUND_TO_PKCS7_PADDED_LEN never adds a whole padding block to
        // block-aligned input (unlike textbook PKCS7); Sunshine expects exactly that.
        var input2 = second + [UInt8](repeating: 0, count: 16)
        var output2 = [UInt8](repeating: 0, count: 32)
        XCTAssertTrue(PltEncryptMessage(context, cbc, padToBlock, &key, 16, &iv, 16, nil, 0, &input2, Int32(second.count), &output2, &length))
        XCTAssertEqual(length, 16)
        // Without RESET_IV the chain continues: the second packet equals the tail of one long CBC run.
        let padded = first + [UInt8](repeating: 4, count: 4) + second
        let reference = referenceCBC(encrypt: true, key: key, iv: iv, input: padded, pkcs7: false)
        XCTAssertEqual(Array(output2[0..<16]), Array(reference[16..<32]))
    }

    func testCBCFinishAddsAndStripsPKCS7Padding() {
        let encryptor = PltCreateCryptoContext()
        let decryptor = PltCreateCryptoContext()
        defer { PltDestroyCryptoContext(encryptor); PltDestroyCryptoContext(decryptor) }
        var key = [UInt8](repeating: 0xAB, count: 16)
        var iv = [UInt8](repeating: 0x5C, count: 16)
        var plain = Array("opus frame data 20b.".utf8) // 20 bytes
        var cipher = [UInt8](repeating: 0, count: 32)
        var length: Int32 = 0
        XCTAssertTrue(PltEncryptMessage(encryptor, cbc, resetIV | finish, &key, 16, &iv, 16, nil, 0, &plain, Int32(plain.count), &cipher, &length))
        XCTAssertEqual(length, 32)
        XCTAssertEqual(cipher, referenceCBC(encrypt: true, key: key, iv: iv, input: plain, pkcs7: true))

        var decrypted = [UInt8](repeating: 0, count: 32)
        var decryptedLength: Int32 = 0
        XCTAssertTrue(PltDecryptMessage(decryptor, cbc, resetIV | finish, &key, 16, &iv, 16, nil, 0, &cipher, 32, &decrypted, &decryptedLength))
        XCTAssertEqual(Array(decrypted[0..<Int(decryptedLength)]), plain)

        // Audio packets reuse the context with a fresh IV each time.
        var otherIV = [UInt8](repeating: 0x77, count: 16)
        var otherPlain = Array("another".utf8)
        var otherCipher = referenceCBC(encrypt: true, key: key, iv: otherIV, input: otherPlain, pkcs7: true)
        XCTAssertTrue(PltDecryptMessage(decryptor, cbc, resetIV | finish, &key, 16, &otherIV, 16, nil, 0, &otherCipher, Int32(otherCipher.count), &decrypted, &decryptedLength))
        XCTAssertEqual(Array(decrypted[0..<Int(decryptedLength)]), otherPlain)

        // Partial blocks cannot be finished.
        var truncated = Array(cipher[0..<20])
        XCTAssertFalse(PltDecryptMessage(decryptor, cbc, resetIV | finish, &key, 16, &iv, 16, nil, 0, &truncated, 20, &decrypted, &decryptedLength))
        _ = otherPlain.count
    }

    func testRandomDataFillsBuffer() {
        var buffer = [UInt8](repeating: 0, count: 64)
        PltGenerateRandomData(&buffer, 64)
        XCTAssertTrue(buffer.contains { $0 != 0 })
    }

    func testRecommendedBitrateMatchesMoonlightDefaults() {
        XCTAssertEqual(MoonlightStreamSettings.recommendedBitrateKbps(width: 1920, height: 1080, fps: 60), 20_000)
        XCTAssertEqual(MoonlightStreamSettings.recommendedBitrateKbps(width: 1280, height: 720, fps: 30), 5_000)
        XCTAssertEqual(MoonlightStreamSettings.recommendedBitrateKbps(width: 3840, height: 2160, fps: 60), 80_000)
        XCTAssertEqual(MoonlightStreamSettings.recommendedBitrateKbps(width: 2560, height: 1440, fps: 120), 57_000)
    }

    func testKeyMappingCoversLettersAndModifiers() {
        XCTAssertEqual(MoonlightVirtualKey.fromHIDUsage(0x04), 0x41)   // a
        XCTAssertEqual(MoonlightVirtualKey.fromHIDUsage(0x27), 0x30)   // 0
        XCTAssertEqual(MoonlightVirtualKey.fromHIDUsage(0xE3), 0x5B)   // left command → Windows key
        XCTAssertEqual(MoonlightVirtualKey.fromMacKeyCode(0x24), MoonlightVirtualKey.enter)
        XCTAssertEqual(MoonlightVirtualKey.fromMacKeyCode(0x7E), 0x26) // up arrow
        XCTAssertNil(MoonlightVirtualKey.fromMacKeyCode(0xFF))
    }
}
