import Crypto
import Foundation

/// 解析 OpenSSH 容器里的 `ssh-ed25519` 私钥（明文与带口令的都行，解密在 `OpenSSHContainer`）。
///
/// 私钥段（PROTOCOL.key）：`string 公钥(32)`、`string 私钥(64)`，后者是 32 字节种子 ‖ 32 字节公钥。
nonisolated enum OpenSSHEd25519Decoder {

    static func decode(openSSHText: String, passphrase: String?) throws -> ParsedPrivateKey {
        switch try OpenSSHContainer.openPrivateSection(text: openSSHText, passphrase: passphrase) {
        case .encrypted:
            throw PrivateKeyImportError.encryptedKeyNeedsPassphrase
        case .plaintext(let keyType, var body, let publicBlob):
            guard keyType == "ssh-ed25519" else {
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            let publicKey = try body.readString()
            let secret = try body.readString()
            guard publicKey.count == 32, secret.count == 64, Array(secret[32...]) == publicKey else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "Ed25519 私钥构造失败", bundle: ModuleBundle.bundle))
            }
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret[..<32])
            } catch {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "Ed25519 私钥构造失败", bundle: ModuleBundle.bundle))
            }
            // 种子推出的公钥要和文件里记的一致，否则私钥段被篡改或拼错了。
            guard Array(key.publicKey.rawRepresentation) == publicKey else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "Ed25519 私钥构造失败", bundle: ModuleBundle.bundle))
            }
            try OpenSSHContainer.requireMatchingPublicKey(publicBlob, keyType: "ssh-ed25519", fields: [publicKey])
            return .ed25519(key)
        }
    }
}
