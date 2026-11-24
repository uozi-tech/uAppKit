import NIOSSH

/// USSHCore 提供的传输保护目录，接在 NIOSSH 自带的 AES-GCM 之后用：
///
/// ```swift
/// config.transportProtectionSchemes = NIOSSH 自带的 + SSHTransportProtections.modern
/// ```
///
/// NIOSSH 按数组顺序得出加密名列表与 MAC 名列表（各取第一次出现的顺序）去协商，所以这里的顺序就是偏好顺序。
public enum SSHTransportProtections {
    public typealias Scheme = any (NIOSSHTransportProtection & SendableMetatype).Type

    /// 默认可用：AES-CTR（256 > 192 > 128）× HMAC-SHA2-256（ETM 优先于 E&M）。
    ///
    /// 不含 HMAC-SHA2-512，原因见 `requiringKeyExtension`。
    public static let modern: [Scheme] = [
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA256>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA256>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self,
    ]

    /// AES-CTR × HMAC-SHA2-512。算法本身完整、测过，但**现在不要放进协商列表**：
    ///
    /// HMAC-SHA2-512 要 64 字节的 MAC 密钥（RFC 6668），而 NIOSSH 0.15.2 推导密钥时只取一次摘要、
    /// 不做 RFC 4253 §7.2 的扩展（K1 ‖ K2 ‖ …）。密钥交换用 SHA-256 / SHA-384（curve25519、P-256、P-384，
    /// 也就是几乎所有情况）时摘要不够长：Debug 构建在 NIOSSH 里 `assert` 直接中断进程，Release 拿到截短的
    /// 密钥，本类型的初始化会抛 `.invalidKeySize`、握手失败。只有协商到 `ecdh-sha2-nistp521`（SHA-512）时才可用。
    /// 等 NIOSSH 补上密钥扩展再并进 `modern`。
    public static let requiringKeyExtension: [Scheme] = [
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512ETM>.self,
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA512ETM>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA512>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA512ETM>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA512>.self,
    ]

    /// 旧算法，需要调用方明确选用：AES-CTR × HMAC-SHA1（ETM 优先）。只为连接只认 SHA-1 MAC 的老设备。
    public static let legacy: [Scheme] = [
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA1ETM>.self,
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA1>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA1ETM>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA1>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1ETM>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self,
    ]
}
