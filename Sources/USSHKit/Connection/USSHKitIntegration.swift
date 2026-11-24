import Foundation
import USSHCore

/// uTerm 用的窄接口：终端、SFTP、转发的适配层还在 app 里，它们拿 `ConnectedClient.target`（USSHCore 的
/// `SSHClient`）直接开通道。
@_spi(uTermIntegration)
public enum USSHKitIntegration {
    /// 建立一条 SSH 连接（`endpoint.jumpHost` 不为 nil 时先连跳板机，再经它的 direct-tcpip 连目标）。
    ///
    /// - Parameters:
    ///   - connectTimeout: TCP 建连、以及「握手 + 认证」各自的时限（两段分开计）。跳板机的内层连接用它当
    ///     开 direct-tcpip 通道的时限。
    ///   - approvalTimeout: `.ask` 策略下等 `approver` 回答的上限。等待期间握手不计时；到点算拒绝
    ///     （`SSHConnectionError.hostKeyRejected`），`approver` 所在的任务被取消。
    ///   - maximumPacketSize: 我方愿意接收的单个通道数据包的最大字节数。NIOSSH 0.15 把每条子通道的接收窗口
    ///     定为它的 64 倍（默认 128 KiB → 8 MiB），所以它同时决定 SFTP 下载等大流量的在途字节数。要某个窗口就传
    ///     「窗口 / 64」。USSHCore 把它夹进 `SSHClient.maximumPacketSizeRange`（32 KiB…512 KiB，即窗口
    ///     2 MiB…32 MiB），不会 abort。跳板机两跳都设。
    ///   - algorithms: 加密 / 密钥交换 / 主机密钥算法。默认 `.builtInOnly`（今天的行为：只用 NIOSSH 自带的算法，
    ///     RSA 用户私钥照样能认证，不接受 RSA 主机密钥）。`.standard` 加上 USSHCore 的现代算法（RSA 主机密钥、
    ///     DH group14 / 16、AES-CTR）；`.legacyCompatible` 再加 SHA-1 的旧算法，只给用户明确要连老设备时用。
    ///   - keepAliveInterval: 认证成功后每隔这么久发一个 `keepalive@openssh.com`；连续 3 个没回应就断开，
    ///     断开原因是 `SSHDisconnectReason.keepAliveTimeout`。`nil`（默认）不发，和今天一样。跳板机两跳都设。
    /// - Throws: `SSHConnectionError`；任务被取消时抛 `CancellationError`（连接已关闭）。
    public static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        algorithms: SSHAlgorithms = .builtInOnly,
        keepAliveInterval: Duration? = nil
    ) async throws -> ConnectedClient {
        try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            maximumPacketSize: maximumPacketSize,
            algorithms: algorithms,
            keepAliveInterval: keepAliveInterval
        )
    }

    /// 凭据 → USSHCore 的认证配置（用户名 + 按顺序尝试的方式）。私钥在这里解析。
    ///
    /// - Throws: `SSHConnectionError.authenticationFailed`（私钥导入失败，带导入错误的文案）、
    ///   `.unsupportedAgentAuthentication`。
    public static func makeAuthentication(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthentication {
        try SSHClientFactory.makeAuthentication(username: username, credential: credential)
    }

    /// 主机密钥的核对方式：查 `store`、按 `policy` 接受 / 记住 / 问 `approver` / 拒绝，拒绝时抛
    /// `SSHConnectionError.hostKeyRejected`。自己调 `SSHClient.connect` 时用；等用户的时限要配在
    /// `SSHClient.Configuration.hostKeyValidationTimeout` 上（`connect` 与 `makeConfiguration` 已经配好）。
    public static func makeHostKeyValidation(
        host: String,
        port: Int,
        store: any HostKeyStore,
        policy: SSHHostKeyPolicy,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) -> SSHHostKeyValidation {
        HostKeyTrust(host: host, port: port, store: store, policy: policy, approver: approver).validation
    }

    /// 一跳连接的完整配置（认证 + 主机密钥核对 + 时限 + 包长 + 算法），与 `connect` 内部用的是同一份。
    /// 自己调 `SSHClient.connect(host:port:configuration:)` 或 `client.jump(to:port:configuration:)` 时用。
    public static func makeConfiguration(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        algorithms: SSHAlgorithms = .builtInOnly,
        keepAliveInterval: Duration? = nil
    ) throws -> SSHClient.Configuration {
        try SSHClientFactory.makeConfiguration(
            .init(host: host, port: port, username: username, credential: credential),
            options: .init(
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                approver: approver,
                maximumPacketSize: maximumPacketSize,
                algorithms: algorithms,
                keepAliveInterval: keepAliveInterval
            )
        )
    }

    /// 任意错误的文案（与 `SSHConnectionError` 里拼进去的是同一套）。`NIOConnectionError`、`IOError`、
    /// `ChannelError` 这类桥接后只剩「错误 N」的类型给出可定位的描述。
    public static func describe(_ error: any Error) -> String {
        SSHErrorText.describe(error)
    }
}
