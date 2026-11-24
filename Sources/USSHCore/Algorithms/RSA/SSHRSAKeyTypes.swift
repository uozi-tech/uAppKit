import Crypto

/// RSA 相关操作的错误。
public enum SSHRSAError: Error, Hashable, Sendable {
    /// 模数位数不在 [`SSHRSAPublicKey.minimumModulusBits`, `maximumModulusBits`] 内。
    case unsupportedModulusSize(bits: Int)
    /// 公钥分量不合法：模数是偶数、公钥指数不是 ≥ 3 的奇数等。
    case invalidPublicKey
    /// 私钥分量不合法或彼此不一致（BoringSSL 的密钥检查没通过）。
    case invalidPrivateKey
    /// blob 的类型名不是期望的那个（公钥 blob 必须是 `ssh-rsa`）。
    case unexpectedKeyType
    /// 签名 blob 里的算法名不认识。
    case unknownSignatureAlgorithm
    /// 签名长度超过模数长度。
    case invalidSignatureLength
    /// 底层签名运算失败。
    case signingFailed
}

/// RSA 签名算法（RFC 8332 §3、RFC 4253 §6.6）。三者共用同一种公钥格式 `ssh-rsa`，只差摘要。
public enum SSHRSASignatureAlgorithm: String, CaseIterable, Hashable, Sendable {
    /// SHA-512 + PKCS#1 v1.5。
    case rsaSHA2_512 = "rsa-sha2-512"
    /// SHA-256 + PKCS#1 v1.5。
    case rsaSHA2_256 = "rsa-sha2-256"
    /// SHA-1 + PKCS#1 v1.5。**旧算法**：OpenSSH 8.8 起默认不再接受；只为连只认它的老服务端（签名与校验都要）。
    case sshRSA = "ssh-rsa"

    /// 协商时用的名字。
    public var name: String { self.rawValue }

    public var isLegacy: Bool { self == .sshRSA }

    /// 默认可用的，按偏好排序（与 OpenSSH 相同：512 先于 256）。
    public static let modern: [SSHRSASignatureAlgorithm] = [.rsaSHA2_512, .rsaSHA2_256]

    /// 需要调用方明确选用的。
    public static let legacy: [SSHRSASignatureAlgorithm] = [.sshRSA]

    public init?(name: String) {
        self.init(rawValue: name)
    }
}
