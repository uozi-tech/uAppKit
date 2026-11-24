import NIOCore
import NIOSSH

/// 建立连接时的失败。只有类型与载荷，文案由 app 按这些 case 自己写。
public enum SSHClientError: Error, Sendable {
    /// TCP 建连超时（`Configuration.connectTimeout`）。
    case connectTimeout(Duration)
    /// TCP 建连失败（DNS、拒绝连接、网络不可达……），底层 NIO 错误原样保留。
    case connectFailed(any Error)
    /// 握手 + 认证超时（`Configuration.handshakeTimeout`，不含主机密钥回调的时间）。
    case handshakeTimeout(Duration)
    /// 主机密钥回调超过 `Configuration.hostKeyValidationTimeout` 还没返回。
    case hostKeyValidationTimeout(Duration)
    /// 主机密钥被拒绝：回调抛出的错误，或 `SSHUntrustedHostKey`。
    case hostKeyRejected(any Error)
    /// 列表里的认证方式都试过了（或服务器一种也不接受）。
    case authenticationFailed(SSHAuthenticationFailure)
    /// 握手期间的协议错误（算法协商失败、报文格式错误、签名不对……），NIOSSH 的错误原样保留。
    case handshakeFailed(any Error)
    /// 握手完成之前连接就断了。
    case connectionClosed(SSHDisconnectReason)
}

/// 连接为什么断了。
public enum SSHDisconnectReason: Sendable {
    /// 本端调用了 `close()`（或外层跳板机连接被本端关闭后连带断开的内层连接以外的情况）。
    case localClose
    /// 对端正常关闭：TCP 收到 EOF，或对端发了 `SSH_MSG_DISCONNECT`。
    case remoteClosed
    /// 传输层出错：底层错误原样保留（`IOError` 的 errno、`ChannelError`、`NIOSSHError` 等），
    /// 给 app 的分类器判断该不该重连。跳板机外层断掉时，内层的原因是 `NIOSSHError.tcpShutdown`。
    case transportError(any Error)

    /// 是否本端主动关的。
    public var isLocalClose: Bool {
        if case .localClose = self { return true }
        return false
    }
}

/// 通道层的失败（exec、shell、subsystem、direct-tcpip、远程转发）。
public enum SSHChannelError: Error, Sendable {
    /// 服务器拒绝开通道（RFC 4254 §5.1 的 CHANNEL_OPEN_FAILURE）。NIOSSH 0.15.2 没有公开 reason code，
    /// 原样保留它的错误（`type == .channelSetupRejected`，原因码在 `description` 里）。
    case openRejected(NIOSSHError)
    /// 服务器回了 CHANNEL_FAILURE。
    case requestRejected(SSHChannelRequestKind)
    /// 服务器拒绝了全局请求（`tcpip-forward` 等）。
    case globalRequestRejected(SSHGlobalRequestKind)
    /// 通道已经关了还在用它。
    case channelClosed
    /// 整条连接已经断了。
    case connectionClosed(SSHDisconnectReason)
    /// 等对端回应超时（`SSHClient.ping`）。
    case timeout(Duration)
}

/// 通道请求（RFC 4254 §6）的种类，用在 `SSHChannelError.requestRejected`。
public enum SSHChannelRequestKind: Sendable, Hashable {
    case pseudoTerminal
    case shell
    case exec
    case subsystem(String)
    case environment(String)
    case windowChange
    case signal(String)
}

/// 全局请求（RFC 4254 §4）的种类。
public enum SSHGlobalRequestKind: Sendable, Hashable {
    case tcpipForward(host: String, port: Int)
    case cancelTcpipForward(host: String, port: Int)
}

/// `executeCommand` 的失败。
public enum SSHCommandError: Error, Sendable {
    /// 命令以非零状态（或被信号杀死、没报状态）结束。`output` 是按调用参数收集到的输出。
    case nonZeroExit(SSHExitStatus, output: ByteBuffer)
    /// 输出超过了 `maxResponseSize`。通道已关闭，远端命令会收到 SIGPIPE / 通道关闭。
    case outputTooLarge(limit: Int)
}
