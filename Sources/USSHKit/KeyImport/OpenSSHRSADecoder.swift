import Foundation
import USSHCore

/// 解析 OpenSSH 容器里的 `ssh-rsa` 私钥分量。
///
/// 自己读出 n / e / d / p / q 交给 USSHCore 的 `SSHRSAPrivateKey`，以 `rsa-sha2-512` / `-256` 签名
/// （OpenSSH 8.8 起服务端默认不再接受 SHA-1 的 `ssh-rsa` 签名）。带口令的容器先解密一层
/// （见 `OpenSSHKeyDecryption`）。私钥段里缺 p / q 的（只有 n / e / d）由 `RSAKeyMaterial.recoverPrimes` 补上。
nonisolated enum OpenSSHRSADecoder {

    /// - Parameter passphrase: 容器带口令时必须给，否则抛 `.encryptedKeyNeedsPassphrase`。
    /// - Throws: `.encryptedKeyNeedsPassphrase` / `.incorrectPassphrase`、容器结构损坏，
    ///   或声明的算法不是 `ssh-rsa`。
    static func decodeComponents(openSSHText: String,
                                 passphrase: String? = nil) throws -> SSHRSAPrivateKeyComponents {
        switch try OpenSSHContainer.openPrivateSection(
            text: openSSHText, passphrase: passphrase) {
        case .encrypted:
            throw PrivateKeyImportError.encryptedKeyNeedsPassphrase
        case .plaintext(let keyType, var body):
            guard keyType == "ssh-rsa" else {
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            // 私钥段分量顺序（PROTOCOL.key）：n, e, d, iqmp, p, q。
            // 注意 n 在 e 之前 —— 与公钥 blob 的 (e, n) 相反。
            let n = try body.readMPInt()
            let e = try body.readMPInt()
            let d = try body.readMPInt()
            _ = try body.readMPInt()                   // iqmp：由 p/q 现算（与 PKCS#1 那条路一致）
            var p = try body.readMPInt()
            var q = try body.readMPInt()
            guard !n.isEmpty, !e.isEmpty, !d.isEmpty else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH RSA：分量为空", bundle: ModuleBundle.bundle))
            }
            if p.isEmpty || q.isEmpty {
                guard let recovered = try RSAKeyMaterial.recoverPrimes(
                    modulus: n, publicExponent: e, privateExponent: d) else {
                    throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH RSA：分量为空", bundle: ModuleBundle.bundle))
                }
                (p, q) = recovered
            }
            return SSHRSAPrivateKeyComponents(
                modulus: n, publicExponent: e, privateExponent: d, prime1: p, prime2: q)
        }
    }

    static func decode(openSSHText: String, passphrase: String?) throws -> ParsedPrivateKey {
        .rsa(try RSAKeyMaterial.makeKey(decodeComponents(openSSHText: openSSHText, passphrase: passphrase)))
    }
}
