import Foundation
import Crypto
import _CryptoExtras
import CCitadelBcrypt

/// OpenSSH 新格式容器（`-----BEGIN OPENSSH PRIVATE KEY-----`）私钥段的解密。
///
/// 带口令的容器用 `bcrypt_pbkdf(口令, salt, rounds)` 一次性派生出 `key || iv`，再用
/// `ciphername` 声明的对称算法解私钥段。bcrypt_pbkdf 是 OpenSSH 自己的 PBKDF2 变体
/// （摘要 SHA-512、分组函数是 EksBlowfish），整个 SSH 栈里只有 Citadel 的 C target
/// `CCitadelBcrypt` 有实现 —— 那个 fork 为此把它导出成 product（见 Citadel 仓库
/// `PATCHES.md`）。对称算法用 swift-crypto 的 `AES._CTR`，不引新依赖。
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

    /// bcrypt 轮数上限。轮数读自密钥文件（不可信），而每一轮都是一次完整的
    /// EksBlowfish 状态扩展 —— 比 PBKDF2 的单次迭代贵几个数量级，不设上限的话一个
    /// 伪造的 rounds 就能把导入卡死。`ssh-keygen -a` 默认 16，手动调到 100 已属激进。
    static let maxRounds: UInt32 = 10_000

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
        guard !salt.isEmpty, rounds >= 1, rounds <= maxRounds else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：bcrypt 参数非法")
        }
        guard !blob.isEmpty, blob.count % cipher.blockSize == 0 else {
            throw PrivateKeyImportError.malformedKey(
                reason: "OpenSSH：私钥段长度不是块大小的整数倍")
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
            throw PrivateKeyImportError.malformedKey(reason: "bcrypt：SHA-512 未就绪")
        }
        // C 侧 passlen == 0 直接返回 -1；空口令在这里就归到「口令错」更贴合用户视角。
        guard !passphrase.isEmpty else { throw PrivateKeyImportError.incorrectPassphrase }

        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = passphrase.withUnsafeBufferPointer { pass in
            salt.withUnsafeBufferPointer { salt in
                derived.withUnsafeMutableBufferPointer { out in
                    citadel_bcrypt_pbkdf(
                        pass.baseAddress, pass.count,
                        salt.baseAddress, salt.count,
                        out.baseAddress, keyLength, rounds)
                }
            }
        }
        guard status == 0 else {
            throw PrivateKeyImportError.malformedKey(reason: "bcrypt_pbkdf 失败")
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
            throw PrivateKeyImportError.malformedKey(reason: "AES-CTR 解密失败")
        }
    }

    /// `citadel_bcrypt_pbkdf` 不自带摘要实现，要调用方先注入一个（Citadel 自己注入的是
    /// BoringSSL 的那份）。这里注入 swift-crypto 的 `SHA512`：两边写进去的实现等价，
    /// 谁先谁后、谁覆盖谁都不影响派生结果。
    private static let sha512HookInstalled: Bool = {
        citadel_set_crypto_hash_sha512 { out, input, inputLength in
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
