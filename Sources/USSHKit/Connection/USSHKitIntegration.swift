@preconcurrency import Citadel

/// Narrow integration surface used by uTerm while its terminal/SFTP adapters remain app-owned.
@_spi(uTermIntegration)
public enum USSHKitIntegration {
    /// 建立一条 SSH 连接。
    ///
    /// - Parameter protocolOptions: 透传给 Citadel / NIOSSH 的协议级选项，默认空集（即
    ///   NIOSSH 自己的默认值）。目前唯一的选项是 `.maximumPacketSize(_:)`，它同时决定
    ///   **子通道的初始窗口**——NIOSSH 的 `SSHChannelMultiplexer` 用
    ///   `targetWindowSize: Int32(maximumPacketSize)` 建每条 child channel，默认
    ///   `1 << 17`（128 KiB）。窗口就是「对端还能往我这边灌多少字节才必须停下等
    ///   window-adjust」，所以高带宽·高延迟链路上的大文件传输（SFTP 下载）会被这
    ///   128 KiB 卡住吞吐；调到 `1 << 20`（1 MiB）能把一个 RTT 内的在途字节数放大 8 倍。
    ///
    ///   **边界**：NIOSSH 的 `SSHPacketParser` 对这个值有两条 `precondition`——
    ///   `>= 32768` 且 `<= 1 << 24`（16 MiB）。`precondition` 越界是**进程 abort，不是
    ///   抛错**，调用方无从捕获，所以传进来的值必须落在 `[32768, 16777216]` 之内。
    public static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        protocolOptions: Set<Citadel.SSHProtocolOption> = []
    ) async throws -> ConnectedClient {
        try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            protocolOptions: protocolOptions
        )
    }

    public static func makeAuthenticationMethod(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        try SSHClientFactory.makeAuthenticationMethod(
            username: username,
            credential: credential
        )
    }

    public static func makeHostKeyValidator(
        host: String,
        port: Int,
        store: any HostKeyStore,
        policy: SSHHostKeyPolicy,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) -> Citadel.SSHHostKeyValidator {
        .custom(HostKeyValidationDelegate(
            host: host,
            port: port,
            store: store,
            policy: policy,
            approvalTimeout: approvalTimeout,
            approver: approver
        ))
    }
}
