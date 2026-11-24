import NIOCore

extension SSHClient {
    /// 开一条 `sftp` subsystem 通道，在上面启动 `SFTPClient`（SSH_FXP_INIT / VERSION、`limits@openssh.com`）。
    ///
    /// 通道满足 `SFTPClient` 的对接约定：
    /// - pipeline 末端以 `ByteBuffer` 收发字节流（`openSubsystemChannel` 装的 `SSHChannelDataCodec`；
    ///   扩展数据——sftp-server 的 stderr——被丢掉），SFTP 自己分帧；
    /// - 可写性：NIOSSH 子通道按对端窗口与本地缓冲水位翻转可写性，`channelWritabilityChanged` 一路传到
    ///   SFTP 的 handler，大批 WRITE 在对端窗口用完时排队、不堆进缓冲；
    /// - 通道关闭（本端、对端 CHANNEL_CLOSE、整条连接断开）→ 在途与排队的请求以 `SFTPError.connectionClosed`
    ///   失败；对端只发 EOF（sftp-server 退出）同样如此（session 通道开着对端半关闭，EOF 会传上来）。
    ///
    /// 接收窗口：每条子通道的窗口是 `Configuration.channelWindowSize`（包长 × 64，默认 8 MiB），大于
    /// `SFTPFile.readAll` 默认 16 个在途 READ × 单次最多 255 KiB（OpenSSH 的 `limits@openssh.com`）≈ 4 MiB，
    /// 所以默认窗口下服务器回 READ 不会因为窗口停下来等 window-adjust。更多的并发读照样正确，只是可能要等窗口。
    /// 跳板机内层连接的窗口按内层自己的配置。
    ///
    /// 失败（服务器拒绝 subsystem、版本不对、握手中途断开）时通道已关闭；任务取消抛 `CancellationError`。
    public func openSFTP(configuration: SFTPClient.Configuration = .init()) async throws -> SFTPClient {
        let channel = try await openSubsystemChannel("sftp")
        return try await SFTPClient.start(on: channel, configuration: configuration)
    }
}
