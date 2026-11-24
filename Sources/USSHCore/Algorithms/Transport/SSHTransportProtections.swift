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
    /// HMAC-SHA2-512 在 `requiringKeyExtension`（历史上的分组，现在已能用）。
    public static let modern: [Scheme] = [
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA256>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES192CTR, SSHHMACSHA256>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256ETM>.self,
        SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self,
    ]

    /// AES-CTR × HMAC-SHA2-512（RFC 6668 要 64 字节 MAC 密钥）。名字是历史原因：NIOSSH 0.15.2 原本推导会话密钥时
    /// 不做 RFC 4253 §7.2 的加长，SHA-256 / SHA-384 的密钥交换配它会握手失败；补丁 0003 补上之后都能用，
    /// `SSHAlgorithms.standard` 已经包含它们。
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
