/// USSHCore：架在 NIOSSH 上的 SSH 客户端层。
///
/// 目录即分工，互不引用对方的内部类型，只经公开接口相接：
/// - `Connection/`、`Channels/`：连接、认证、exec、PTY、TCP 转发、跳板机
/// - `SFTP/`：SFTP v3 的报文与客户端（服务端一侧在 `USSHTestServer`）
/// - `Algorithms/`：NIOSSH 没带的加密方式、密钥类型、密钥交换
public enum USSHCore {}
