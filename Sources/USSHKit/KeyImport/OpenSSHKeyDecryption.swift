import Foundation
import Crypto
import _CryptoExtras
import CBcryptPBKDF

/// OpenSSH 新格式容器（`-----BEGIN OPENSSH PRIVATE KEY-----`）私钥段的解密。
///
/// 带口令的容器用 `bcrypt_pbkdf(口令, salt, rounds)` 一次性派生出 `key || iv`，再用
/// `ciphername` 声明的对称算法解私钥段。bcrypt_pbkdf 是 OpenSSH 自己的 PBKDF2 变体
/// （摘要 SHA-512、分组函数是 EksBlowfish），实现是本包的 C target `CBcryptPBKDF`（OpenBSD 的代码，
/// 来源见 THIRD_PARTY_NOTICES.md）。对称算法用 swift-crypto 的 `AES._CTR`，不引新依赖。
nonisolated enum OpenSSHKeyDecryption {

    /// 容器的对称算法。`ssh-keygen` 默认写 `aes256-ctr`；其余两档是它支持的另两个 CTR
    /// 变体。容器里出现别的算法（如 aes256-cbc、chacha20-poly1305）一律报
    /// `unsupportedCipher`，不要猜。
    enum Cipher: String {
        case aes128ctr = "aes128-ctr"
        case aes192ctr = "aes192-ctr"
        case aes256ctr = "aes256-ctr"

        /// 派生出的 `key || iv` 里 key 占的字节数。
        var keyLength: Int {
            switch self {
            case .aes128ctr: return 16
            case .aes192ctr: return 24
            case .aes256ctr: return 32
            }
        }

        /// CTR 的计数块即一个 AES 块。
        var ivLength: Int { 16 }
        var blockSize: Int { 16 }
    }

    /// bcrypt 轮数上限：128。轮数读自密钥文件（不可信），每一轮都是完整的 EksBlowfish 状态扩展，而且每次连接都会
    /// 重新解一遍私钥。实测（2026-11，Apple M5 Pro，OpenSSH 自己的 `ssh-keygen -p`）一轮约 20 ms：`-a 16`（默认）
    /// 0.35 秒，`-a 100`（不少加固指南的写法）约 2 秒，128 约 2.6 秒；手机慢 1.5–2 倍，128 轮一次也就三五秒。
    /// 以前的 10 000 轮要三分多钟。更高的报 `.unsupportedKDFCost`，用 `ssh-keygen -p -a 100` 重新存一次即可。
    static let maxRounds: UInt32 = 128

    /// salt 的长度范围。`ssh-keygen` 写 16 字节；bcrypt_pbkdf 自己允许到 1 MiB，这里卡在 64 字节。
    static let saltLengthRange = 1...64

    /// 解密私钥段。
    ///
    /// - Parameters:
    ///   - blob: 容器里的私钥段密文。
    ///   - cipherName: 容器声明的 `ciphername`。
    ///   - kdfName: 容器声明的 `kdfname`，加密容器只可能是 `bcrypt`。
    ///   - kdfOptions: `kdfoptions` 原始字节（`string salt` + `uint32 rounds`）。
    ///   - passphrase: 用户口令。
    static func decryptPrivateSection(
        blob: [UInt8],
        cipherName: String,
        kdfName: String,
        kdfOptions: [UInt8],
        passphrase: String
    ) throws -> [UInt8] {
        guard let cipher = Cipher(rawValue: cipherName) else {
            throw PrivateKeyImportError.unsupportedCipher(name: cipherName)
        }
        guard kdfName == "bcrypt" else {
            throw PrivateKeyImportError.unsupportedKDF(name: kdfName)
        }

        var options = SSHWireReader(kdfOptions)
        let salt = try options.readString()            // 注意是 string，不能按 mpint 读
        let rounds = try options.readUInt32()
        guard saltLengthRange.contains(salt.count), rounds >= 1, options.isAtEnd else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：bcrypt 参数非法", bundle: ModuleBundle.bundle))
        }
        guard rounds <= maxRounds else {
            throw PrivateKeyImportError.unsupportedKDFCost(rounds: Int(rounds), maximum: Int(maxRounds))
        }
        guard !blob.isEmpty, blob.count % cipher.blockSize == 0 else {
            throw PrivateKeyImportError.malformedKey(
                reason: String(localized: "OpenSSH：私钥段长度不是块大小的整数倍", bundle: ModuleBundle.bundle))
        }

        let derived = try bcryptPBKDF(
            passphrase: Array(passphrase.utf8), salt: salt,
            rounds: rounds, keyLength: cipher.keyLength + cipher.ivLength)
        return try aesCTR(
            key: Array(derived[..<cipher.keyLength]),
            iv: Array(derived[cipher.keyLength...]),
            input: blob)
    }

    /// bcrypt_pbkdf。派生失败只可能是参数被上面的守卫漏过，不当成口令错误。
    static func bcryptPBKDF(passphrase: [UInt8], salt: [UInt8],
                            rounds: UInt32, keyLength: Int) throws -> [UInt8] {
        guard sha512HookInstalled else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "bcrypt：SHA-512 未就绪", bundle: ModuleBundle.bundle))
        }
        // C 侧 passlen == 0 直接返回 -1；空口令在这里就归到「口令错」更贴合用户视角。
        guard !passphrase.isEmpty else { throw PrivateKeyImportError.incorrectPassphrase }

        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = passphrase.withUnsafeBufferPointer { pass in
            salt.withUnsafeBufferPointer { salt in
                derived.withUnsafeMutableBufferPointer { out in
                    uappkit_bcrypt_pbkdf(
                        pass.baseAddress, pass.count,
                        salt.baseAddress, salt.count,
                        out.baseAddress, keyLength, rounds)
                }
            }
        }
        guard status == 0 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "bcrypt_pbkdf 失败", bundle: ModuleBundle.bundle))
        }
        return derived
    }

    /// AES-CTR。加解密是同一运算，这里只用于解密。
    static func aesCTR(key: [UInt8], iv: [UInt8], input: [UInt8]) throws -> [UInt8] {
        do {
            // 16 字节 nonce = 完整的 128 位大端计数块，正是 OpenSSH 用的形态。
            let nonce = try AES._CTR.Nonce(nonceBytes: iv)
            return Array(try AES._CTR.decrypt(input, using: SymmetricKey(data: key), nonce: nonce))
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "AES-CTR 解密失败", bundle: ModuleBundle.bundle))
        }
    }

    /// `uappkit_bcrypt_pbkdf` 不自带摘要实现，要调用方先注入一个。这里注入 swift-crypto 的 `SHA512`。
    private static let sha512HookInstalled: Bool = {
        uappkit_set_crypto_hash_sha512 { out, input, inputLength in
            guard let out, let input else { return }
            var hasher = SHA512()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: input, count: Int(inputLength)))
            hasher.finalize().withUnsafeBytes { digest in
                UnsafeMutableRawBufferPointer(start: out, count: SHA512.byteCount)
                    .copyMemory(from: digest)
            }
        }
        return true
    }()
}
