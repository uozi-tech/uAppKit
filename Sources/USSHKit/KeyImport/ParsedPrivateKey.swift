import Crypto
import NIOSSH
import USSHCore

/// 已解析的私钥。RSA 已经是 USSHCore 的 `SSHRSAPrivateKey`（分量在导入时就核对过）。
nonisolated enum ParsedPrivateKey: Sendable {
    case rsa(SSHRSAPrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    /// 这把私钥对应的认证方式，按顺序试。RSA 依次是 `rsa-sha2-512`、`rsa-sha2-256`（不发 SHA-1 的 `ssh-rsa`）。
    var authenticationMethods: [SSHAuthenticationMethod] {
        switch self {
        case .rsa(let key): return CoreShims.rsaAuthenticationMethods(key)
        case .ed25519(let key): return [.privateKey(NIOSSHPrivateKey(ed25519Key: key))]
        case .p256(let key): return [.privateKey(NIOSSHPrivateKey(p256Key: key))]
        case .p384(let key): return [.privateKey(NIOSSHPrivateKey(p384Key: key))]
        case .p521(let key): return [.privateKey(NIOSSHPrivateKey(p521Key: key))]
        }
    }

    var kind: SSHPrivateKeyKind {
        switch self {
        case .rsa: return .rsa
        case .ed25519: return .ed25519
        case .p256: return .ecdsaP256
        case .p384: return .ecdsaP384
        case .p521: return .ecdsaP521
        }
    }
}
