import Foundation
import Crypto

/// 把一段已被 `PrivateKeyImporter` 校验通过的私钥文本，提炼成密钥库要展示的
/// 元数据（类型 / 位数 / 公钥串 / 指纹）。
///
/// 公钥一律从 `ParsedPrivateKey`（真正用来认证的那把）反推：ed25519 用公钥原始字节，RSA 用公钥的 e/n，
/// ECDSA 用 X9.63 公钥点。不取 OpenSSH 容器里明文的公钥段——那是文件自己说的，可以和私钥段不是同一把
/// （导入时 `OpenSSHContainer.requireMatchingPublicKey` 已经拒绝这种文件，这里再不依赖它）。
///
/// 密钥库模型表达 ed25519 / rsa / ecdsa；DSA 等旧算法抛 `unsupportedAlgorithm`，
/// 由调用方提示用户。
public nonisolated enum KeyImportInspector {

    public struct Material: Sendable {
        public let type: SSHPrivateKeyKind
        public let bits: Int
        public let publicKey: String
        public let fingerprint: String
    }

    public enum InspectError: Error { case unsupportedAlgorithm, malformed }

    public static func inspect(
        rawText: String,
        parsed key: SSHPrivateKey,
        comment: String
    ) throws -> Material {
        try inspectParsed(rawText: rawText, parsed: key.parsed, comment: comment)
    }

    static func inspect(
        rawText: String,
        parsed: ParsedPrivateKey,
        comment: String
    ) throws -> Material {
        try inspectParsed(rawText: rawText, parsed: parsed, comment: comment)
    }

    private static func inspectParsed(
        rawText: String,
        parsed: ParsedPrivateKey,
        comment: String
    ) throws -> Material {
        switch parsed {
        case .ed25519(let key):
            let blob = SSHPublicMaterial.ed25519Blob(pub: [UInt8](key.publicKey.rawRepresentation))
            return material(type: .ed25519, bits: 256, blob: blob, comment: comment)
        case .rsa(let key):
            let publicKey = key.publicKey
            let blob = SSHPublicMaterial.rsaBlob(e: publicKey.publicExponent, n: publicKey.modulus)
            return material(type: .rsa, bits: publicKey.modulusByteCount * 8, blob: blob, comment: comment)
        case .p256(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp256",
                curve: "nistp256",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP256, bits: 256, blob: blob, comment: comment)
        case .p384(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp384",
                curve: "nistp384",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP384, bits: 384, blob: blob, comment: comment)
        case .p521(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp521",
                curve: "nistp521",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP521, bits: 521, blob: blob, comment: comment)
        }
    }

    // MARK: - 私有

    private static func material(type: SSHPrivateKeyKind, bits: Int, blob: [UInt8], comment: String) -> Material {
        Material(
            type: type, bits: bits,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: publicKeyPrefix(for: type),
                                                       blob: blob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: blob))
    }

    private static func publicKeyPrefix(for type: SSHPrivateKeyKind) -> String {
        switch type {
        case .ed25519:   return "ssh-ed25519"
        case .rsa:       return "ssh-rsa"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        }
    }
}
