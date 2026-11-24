/// SFTP 客户端抛出的**唯一**错误类型。
///
/// 服务端回的每一个非 OK 状态都落在 `.status`，不论哪个操作、哪条路径——调用方只认这一个类型
/// （Citadel 有的路径抛裸的状态消息、有的路径包一层，调用方得两种都接）。
/// 任务取消照 Swift 惯例抛 `CancellationError`，不在此列。
///
/// 这里不带面向用户的文字：`message` 是服务端的原话，`description` 只给日志与诊断，
/// 给人看的文案由 app 按 `code` 本地化。
public enum SFTPError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 服务端回了非 OK 的 SSH_FXP_STATUS。
    case status(code: SFTPStatusCode, message: String, languageTag: String)
    /// 通道已关（对端断开、本端关闭、传输出错）。在途的请求一律以它失败。
    case connectionClosed
    /// 服务端回了违反协议的东西（类型不对、格式坏、超长）。参数是给日志看的说明。
    /// 坏在分帧 / 解码层（字节流已经无法再信任）时通道会被关掉，在途请求全部以它失败；
    /// 只是某个请求的回答类型不对时只有那个请求失败。
    case invalidResponse(String)
    /// SSH_FXP_VERSION 给的版本不是 3。
    case unsupportedVersion(UInt32)
    /// 请求超过了服务端（`limits@openssh.com`）或本端配置允许的长度，没有发出去。
    case requestTooLarge(length: Int, limit: Int)
    /// 服务端没在 SSH_FXP_VERSION 里宣告这个扩展，请求没有发出去。
    case extensionUnsupported(String)
    /// 文件或目录句柄已经关过。
    case handleClosed
    /// 便捷读（`readAll`）读到的数据超过了调用方给的上限。
    case limitExceeded(maximumBytes: Int)

    /// 服务端状态码；不是 `.status` 时为 nil。
    public var statusCode: SFTPStatusCode? {
        if case .status(let code, _, _) = self { return code }
        return nil
    }

    public var description: String {
        switch self {
        case .status(let code, let message, _):
            return message.isEmpty ? "SFTP status \(code)" : "SFTP status \(code): \(message)"
        case .connectionClosed:
            return "SFTP channel closed"
        case .invalidResponse(let detail):
            return "SFTP protocol violation: \(detail)"
        case .unsupportedVersion(let version):
            return "SFTP server speaks version \(version), expected 3"
        case .requestTooLarge(let length, let limit):
            return "SFTP request of \(length) bytes exceeds limit \(limit)"
        case .extensionUnsupported(let name):
            return "SFTP server does not support \(name)"
        case .handleClosed:
            return "SFTP handle already closed"
        case .limitExceeded(let maximumBytes):
            return "SFTP read exceeded \(maximumBytes) bytes"
        }
    }
}
