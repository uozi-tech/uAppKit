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
    ///   - algorithms: 加密 / 密钥交换 / 主机密钥算法。默认 `.standard`：NIOSSH 自带的算法排在前面，后面只补
    ///     SHA-2 时代的算法（RSA 主机密钥 `rsa-sha2-512` / `rsa-sha2-256`、DH group16-sha512 / group14-sha256、
    ///     AES-CTR 配 SHA-2 的 MAC）。所以今天连得上的服务器协商结果和以前完全一样（主机密钥类型也不变，已记的
    ///     known-hosts 照常生效），只有 RSA 主机密钥、或者没有 curve25519 / ECDH / AES-GCM 的服务器现在也能连上。
    ///     SHA-1 的旧算法不在其中，只在服务器什么更好的都不支持时由 `legacyFallback` 自动补上（也可以直接传
    ///     `.legacyCompatible`）；`.builtInOnly` 是只用 NIOSSH 自带算法的窄集。
    ///     这是产品层（USSHKit）的默认；USSHCore 自己的 `SSHClient.Configuration` 默认仍是 `.builtInOnly`。
    ///   - keepAliveInterval: 认证成功后每隔这么久发一个 `keepalive@openssh.com`；连续 3 个没回应就断开，
    ///     断开原因是 `SSHDisconnectReason.keepAliveTimeout`。`nil`（默认）不发，和今天一样。跳板机两跳都设。
    ///   - legacyFallback: 自动退级（默认开，跳板机与目标各自判断，规则与安全上的理由见 `SSHLegacyFallback`）：
    ///     遇到类型化的「没有共同算法」时，用 `algorithms` 加上 `.standard` 的现代算法、再加上旧算法同一跳再连一次——
    ///     服务器这一类的报价与扩展出来的名字有交集时才试，不知道卡在哪时盲试一次；
    ///     RSA 用户私钥在服务器没宣告 `server-sig-algs`、SHA-2 签名都被拒时，同一条连接里最后试 `ssh-rsa`；
    ///     进程内记住需要旧算法的主机，重连时省掉注定失败的那一次。用上了哪些看
    ///     `ConnectedClient.legacyAlgorithmsInUse` / `bastionLegacyAlgorithmsInUse`，并经 `logger` 记一条警告。
    ///     关掉时只用 `algorithms`（把它当严格策略的调用方这样传），没有共同算法就报 `SSHConnectionError.handshakeFailed`。
    ///   - legacyFallbackApproval: 即将用 SHA-1 时代的旧算法连某一跳之前问一声（`legacyFallback` 开着才有用）。`nil`（默认）
    ///     不问，和今天完全一样。给了的话两处会调它，各跳各问（跳板机那一跳 `request.hop == .jumpHost`）：
    ///     - 第一次用现代算法连，服务器说没有共同算法、补上旧算法就对得上，再连之前（`request.trigger == .noCommonAlgorithm`，
    ///       `request.failure` 是这一次卡在哪一类、服务器报了什么）；
    ///     - 这个进程里记着这一跳需要旧算法、第一次就要直接带上旧算法连之前（`.remembered`，`failure` 是当时记下的那一份）。
    ///       不同意时这一次不带旧算法照常连（主机可能已经升级）；仍然要旧算法才连得上时不再问，直接按不同意处理。
    ///     返回 `true` 照常用旧算法连；返回 `false` 不再连，抛 `SSHConnectionError.legacyFallbackDeclined(request)`
    ///     （经跳板机时包在 `.jumpHostFailed(_, cause:)` 里），进程内的记录也不动。一次 `connect` 里每一跳至多问一次。
    ///     在建连的任务里调（不在主线程上；要弹界面就在闭包里切到主线程，或者传一个 `@MainActor` 的闭包）。等它的时候
    ///     没有连接开着、不计时；`connect` 所在的任务被取消时，闭包返回之后抛 `CancellationError`（闭包自己要响应取消）。
    ///     RSA **用户**私钥在同一条连接里退到 `ssh-rsa` 签名不经过它（那不是降低服务器那一端的安全性，见 `SSHLegacyFallback`）。
    ///   - logger: 记自动退级之类的事件。
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
        algorithms: SSHAlgorithms = .standard,
        keepAliveInterval: Duration? = nil,
        legacyFallback: Bool = true,
        legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)? = nil,
        logger: any SSHLogger = NoOpSSHLogger()
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
            keepAliveInterval: keepAliveInterval,
            legacyFallback: legacyFallback,
            legacyFallbackApproval: legacyFallbackApproval,
            logger: logger
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
    /// 参数与默认值同 `connect`（算法默认 `.standard`，见那里的说明）。只建一条连接用不了「再连一次」：
    /// `legacyFallback` 开着时，这一跳在进程内记着需要旧算法就直接给补上旧算法的那一套，并打开同一条连接里
    /// RSA 用户私钥的 `ssh-rsa` 回退。它是同步的，问不了 `connect` 的 `legacyFallbackApproval`：要先问用户的调用方
    /// 用 `connect`，或者传 `legacyFallback: false`。
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
        algorithms: SSHAlgorithms = .standard,
        keepAliveInterval: Duration? = nil,
        legacyFallback: Bool = true
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
                keepAliveInterval: keepAliveInterval,
                legacyFallback: legacyFallback
            )
        )
    }

    /// 任意错误的文案（与 `SSHConnectionError` 里拼进去的是同一套）。`NIOConnectionError`、`IOError`、
    /// `ChannelError` 这类桥接后只剩「错误 N」的类型给出可定位的描述。
    public static func describe(_ error: any Error) -> String {
        SSHErrorText.describe(error)
    }
}
