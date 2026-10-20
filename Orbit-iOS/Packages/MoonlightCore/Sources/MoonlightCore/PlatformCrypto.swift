import CommonCrypto
import CryptoKit
import Foundation

// moonlight-common-c expects the host application to provide its crypto primitives
// (`PlatformCrypto.h`). The library only ever passes the context pointer back, so the
// context is an opaque Swift object. Semantics mirror the OpenSSL reference:
//  - AES-GCM: one-shot per message, 12- or 16-byte IV, 16-byte tag.
//  - AES-CBC: a streaming cipher that keeps its chaining state between calls, reset with
//    CIPHER_FLAG_RESET_IV; PKCS7 padding is added in place with CIPHER_FLAG_PAD_TO_BLOCK_SIZE,
//    and CIPHER_FLAG_FINISH pads (encrypt) or strips padding (decrypt) like EVP_*Final_ex.
private let algorithmCBC: Int32 = 1
private let algorithmGCM: Int32 = 2
private let flagResetIV: Int32 = 0x01
private let flagFinish: Int32 = 0x02
private let flagPadToBlockSize: Int32 = 0x04

private final class MoonlightCryptoContext {
    var cryptor: CCCryptorRef?
    var gcmKey: SymmetricKey?
    /// Bytes CommonCrypto is holding back because they do not fill a block yet.
    var pending = 0

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    func prepareCBC(operation: CCOperation, key: UnsafeMutablePointer<UInt8>?, keyLength: Int32,
                    iv: UnsafeMutablePointer<UInt8>?, ivLength: Int32, reset: Bool) -> Bool {
        guard keyLength == 16, ivLength == 16, let key, let iv else { return false }
        if cryptor == nil {
            var created: CCCryptorRef?
            let status = CCCryptorCreateWithMode(operation, CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES),
                                                 CCPadding(ccNoPadding), iv, key, Int(keyLength), nil, 0, 0, 0, &created)
            guard status == kCCSuccess, let created else { return false }
            cryptor = created
            pending = 0
        } else if reset {
            guard CCCryptorReset(cryptor, iv) == kCCSuccess else { return false }
            pending = 0
        }
        return true
    }

    func update(_ input: UnsafeRawPointer?, _ inputLength: Int, _ output: UnsafeMutableRawPointer?, _ capacity: Int) -> Int? {
        guard let cryptor else { return nil }
        var moved = 0
        guard CCCryptorUpdate(cryptor, input, inputLength, output, capacity, &moved) == kCCSuccess else { return nil }
        pending = (pending + inputLength) % 16
        return moved
    }

    func symmetricKey(_ key: UnsafeMutablePointer<UInt8>?, _ keyLength: Int32) -> SymmetricKey? {
        if let gcmKey { return gcmKey }
        guard let key, keyLength == 16 || keyLength == 24 || keyLength == 32 else { return nil }
        let made = SymmetricKey(data: UnsafeRawBufferPointer(start: key, count: Int(keyLength)))
        gcmKey = made
        return made
    }
}

private func context(_ raw: UnsafeMutableRawPointer?) -> MoonlightCryptoContext? {
    guard let raw else { return nil }
    return Unmanaged<MoonlightCryptoContext>.fromOpaque(raw).takeUnretainedValue()
}

@_cdecl("PltCreateCryptoContext")
public func PltCreateCryptoContext() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(MoonlightCryptoContext()).toOpaque()
}

@_cdecl("PltDestroyCryptoContext")
public func PltDestroyCryptoContext(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<MoonlightCryptoContext>.fromOpaque(raw).release()
}

@_cdecl("PltGenerateRandomData")
public func PltGenerateRandomData(_ data: UnsafeMutablePointer<UInt8>?, _ length: Int32) {
    guard let data, length > 0 else { return }
    arc4random_buf(data, Int(length))
}

@_cdecl("PltEncryptMessage")
public func PltEncryptMessage(_ raw: UnsafeMutableRawPointer?, _ algorithm: Int32, _ flags: Int32,
                              _ key: UnsafeMutablePointer<UInt8>?, _ keyLength: Int32,
                              _ iv: UnsafeMutablePointer<UInt8>?, _ ivLength: Int32,
                              _ tag: UnsafeMutablePointer<UInt8>?, _ tagLength: Int32,
                              _ input: UnsafeMutablePointer<UInt8>?, _ inputLength: Int32,
                              _ output: UnsafeMutablePointer<UInt8>?, _ outputLength: UnsafeMutablePointer<Int32>?) -> Bool {
    guard let ctx = context(raw), let output, let outputLength, inputLength >= 0 else { return false }
    switch algorithm {
    case algorithmGCM:
        guard let tag, tagLength == 16, let iv, ivLength >= 12, let symmetric = ctx.symmetricKey(key, keyLength) else { return false }
        do {
            let nonce = try AES.GCM.Nonce(data: UnsafeRawBufferPointer(start: iv, count: Int(ivLength)))
            let plaintext = UnsafeRawBufferPointer(start: input, count: Int(inputLength))
            let box = try AES.GCM.seal(plaintext, using: symmetric, nonce: nonce)
            box.ciphertext.copyBytes(to: output, count: box.ciphertext.count)
            box.tag.copyBytes(to: tag, count: 16)
            outputLength.pointee = Int32(box.ciphertext.count)
            return true
        } catch {
            return false
        }
    case algorithmCBC:
        guard ctx.prepareCBC(operation: CCOperation(kCCEncrypt), key: key, keyLength: keyLength, iv: iv, ivLength: ivLength,
                             reset: flags & flagResetIV != 0) else { return false }
        var length = Int(inputLength)
        if flags & flagPadToBlockSize != 0 {
            // The caller guarantees room up to the next block boundary and allows modification.
            guard let input else { return false }
            let padded = (length + 15) / 16 * 16
            let padding = UInt8(16 - length % 16)
            (input + length).initialize(repeating: padding, count: padded - length)
            length = padded
        }
        let capacity = flags & flagFinish != 0 ? (length + 15) / 16 * 16 + 16 : length
        guard var moved = ctx.update(input, length, output, capacity) else { return false }
        if flags & flagFinish != 0 {
            let padding = 16 - ctx.pending
            let pad = [UInt8](repeating: UInt8(padding), count: padding)
            guard let tail = ctx.update(pad, padding, output + moved, capacity - moved) else { return false }
            moved += tail
            ctx.pending = 0
        }
        outputLength.pointee = Int32(moved)
        return true
    default:
        return false
    }
}

@_cdecl("PltDecryptMessage")
public func PltDecryptMessage(_ raw: UnsafeMutableRawPointer?, _ algorithm: Int32, _ flags: Int32,
                              _ key: UnsafeMutablePointer<UInt8>?, _ keyLength: Int32,
                              _ iv: UnsafeMutablePointer<UInt8>?, _ ivLength: Int32,
                              _ tag: UnsafeMutablePointer<UInt8>?, _ tagLength: Int32,
                              _ input: UnsafeMutablePointer<UInt8>?, _ inputLength: Int32,
                              _ output: UnsafeMutablePointer<UInt8>?, _ outputLength: UnsafeMutablePointer<Int32>?) -> Bool {
    guard let ctx = context(raw), let output, let outputLength, inputLength >= 0 else { return false }
    switch algorithm {
    case algorithmGCM:
        guard let tag, tagLength == 16, let iv, ivLength >= 12, let symmetric = ctx.symmetricKey(key, keyLength) else { return false }
        do {
            let nonce = try AES.GCM.Nonce(data: UnsafeRawBufferPointer(start: iv, count: Int(ivLength)))
            let box = try AES.GCM.SealedBox(nonce: nonce,
                                            ciphertext: UnsafeRawBufferPointer(start: input, count: Int(inputLength)),
                                            tag: UnsafeRawBufferPointer(start: tag, count: 16))
            let plaintext = try AES.GCM.open(box, using: symmetric)
            plaintext.copyBytes(to: output, count: plaintext.count)
            outputLength.pointee = Int32(plaintext.count)
            return true
        } catch {
            return false
        }
    case algorithmCBC:
        guard ctx.prepareCBC(operation: CCOperation(kCCDecrypt), key: key, keyLength: keyLength, iv: iv, ivLength: ivLength,
                             reset: flags & flagResetIV != 0) else { return false }
        let length = Int(inputLength)
        guard var moved = ctx.update(input, length, output, (length + 15) / 16 * 16) else { return false }
        if flags & flagFinish != 0 {
            // EVP_DecryptFinal_ex fails on a partial block or malformed PKCS7 padding.
            guard ctx.pending == 0, moved >= 16 else { return false }
            let padding = Int(output[moved - 1])
            guard (1...16).contains(padding), padding <= moved else { return false }
            for index in (moved - padding)..<moved where output[index] != UInt8(padding) { return false }
            moved -= padding
            ctx.pending = 0
        }
        outputLength.pointee = Int32(moved)
        return true
    default:
        return false
    }
}
