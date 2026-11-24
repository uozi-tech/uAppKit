/// 传输层加密方式（`NIOSSHTransportProtection` 的实现）抛出的错误。
///
/// 这些错误都会让连接整体失败（NIOSSH 的包解析器不会尝试恢复），所以只按「哪一步不对」区分，
/// 不带对端数据。
public enum SSHTransportProtectionError: Error, Hashable, Sendable {
    /// 密钥交换给的加密密钥 / MAC 密钥长度不符合本算法。
    case invalidKeySize
    /// 密钥交换给的 IV 长度不符合本算法。
    case invalidIVSize
    /// 包长度字段不合法：太短，或不是块大小的整数倍（RFC 4253 §6）。
    case invalidPacketLength
    /// 交给解密的字节数与包长度字段对不上。
    case invalidCiphertextLength
    /// MAC 校验失败。
    case authenticationFailure
    /// 填充长度不合法：少于 4 字节，或比包体还长。
    case invalidPadding
    /// `updateKeys` 给的某个方向的加密密钥与 IV 和当前的相同：CTR 会重复密钥流，拒绝。
    case keyReuse
}
