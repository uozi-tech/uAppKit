import Foundation

public actor SSHLocalForwardingTunnel: SSHForwardingTunnel {
    private let request: SSHForwardingRequest
    private let hostKeyStore: any HostKeyStore
    private let hostKeyPolicy: SSHHostKeyPolicy
    private let connectTimeout: Duration
    private let channelOpenTimeout: Duration
    private let approvalTimeout: Duration
    private let approver: @Sendable (SSHHostKeyChallenge) async -> Bool
    private let logger: any SSHLogger
    /// 隧道建立后、某条本地连接开 direct-tcpip 通道失败时回调（已归类）。
    /// 供应用层把「隧道通了但跳板机开不到目标」的真实原因浮出到 UI。
    private let onChannelFailure: @Sendable (SSHForwardingChannelFailure) -> Void
    /// 保活间隔（每一跳都发 `keepalive@openssh.com`），nil 不发。
    private let keepAliveInterval: Duration?
    /// 隧道底下的 SSH 连接（任一跳）不是本端关的而断了时回调一次。
    private let onDisconnect: @Sendable (SSHDisconnectReason) -> Void
    /// 用旧算法连某一跳之前问 app（同 `USSHKitIntegration.connect(legacyFallbackApproval:)`）；nil 不问，照旧自动退级。
    private let legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)?

    private var connected: ConnectedClient?
    private var listener: LocalForwardListener?
    private var isClosed = false
    /// `open()` 正在建连 / 绑端口（等询问、等主机密钥确认时 actor 会重入）：第二次 `open()` 直接拒绝。
    private var isOpening = false
    /// SSH 连接（任一跳）断开的原因；断了之后监听不再接连接（端口留到 `close()`）。
    private var lostReason: SSHDisconnectReason?
    private var disconnectTokens: [(SSHClient, SSHDisconnectObserverToken)] = []

    public init(
        request: SSHForwardingRequest,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy = .strict,
        connectTimeout: Duration = .seconds(30),
        channelOpenTimeout: Duration = .seconds(10),
        approvalTimeout: Duration = .seconds(180),
        logger: any SSHLogger = NoOpSSHLogger(),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in false },
        onChannelFailure: @escaping @Sendable (SSHForwardingChannelFailure) -> Void = { _ in },
        keepAliveInterval: Duration? = nil,
        onDisconnect: @escaping @Sendable (SSHDisconnectReason) -> Void = { _ in },
        legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)? = nil
    ) {
        self.request = request
        self.hostKeyStore = hostKeyStore
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = connectTimeout
        self.channelOpenTimeout = channelOpenTimeout
        self.approvalTimeout = approvalTimeout
        self.logger = logger
        self.approver = approver
        self.onChannelFailure = onChannelFailure
        self.keepAliveInterval = keepAliveInterval
        self.onDisconnect = onDisconnect
        self.legacyFallbackApproval = legacyFallbackApproval
    }

    /// 隧道能用：已经 `open()`、没有 `close()`、本地监听开着、每一跳的 SSH 连接都还连着。
    /// SSH 连接断了（服务器关闭、传输出错、保活判死）之后恒为 false——隧道不会自己重连，要换一条新的。
    public var isConnected: Bool {
        guard !isClosed, lostReason == nil, listener != nil, let connected else { return false }
        return connected.isConnected
    }

    /// SSH 连接断开的原因（本端 `close()` 不算）。连着、没开、或是本端关的时为 nil。
    public var disconnectReason: SSHDisconnectReason? { lostReason }

    /// 目标那一跳的传输层这次是不是靠 SHA-1 时代的旧算法才协商成的（三态，见
    /// `ConnectedClient.targetNeededLegacyTransport`）：`open()` 成功之后才有值，之前与失败时为 nil。
    /// App 记「这台需要旧算法」按它写：`true` 记、`false` 清、`nil` 不动。
    public var targetNeededLegacyTransport: Bool? { connected?.targetNeededLegacyTransport }

    /// 跳板机那一跳的同上（没有跳板机、或还没连上时为 nil）。
    public var bastionNeededLegacyTransport: Bool? { connected?.bastionNeededLegacyTransport }

    /// 建连（含跳板机）并开始本地监听。`legacyFallbackApproval` 没同意用旧算法时抛
    /// `SSHConnectionError.legacyFallbackDeclined`（经跳板机时在 `.jumpHostFailed` 的 `cause` 里），不可重试。
    /// 建连期间（等询问、等主机密钥确认）`close()` 了：回来后关掉已连上的连接、不绑端口，抛 `.closed`；
    /// 建连期间再调 `open()` 抛 `.alreadyOpen`。
    public func open() async throws -> SSHForwardingEndpoint {
        guard !isOpening, connected == nil, listener == nil else {
            throw SSHConnectionError.alreadyOpen
        }
        guard !isClosed else {
            throw SSHConnectionError.closed
        }
        // 建连时会等（询问、主机密钥确认），actor 在这期间重入：`close()` 可能先到，第二次 `open()` 也可能来。
        isOpening = true
        defer { isOpening = false }

        let connected = try await SSHClientFactory.connect(
            endpoint: request.endpoint,
            credential: request.credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            keepAliveInterval: keepAliveInterval,
            legacyFallbackApproval: legacyFallbackApproval,
            // 建连这一段的日志（用上了 SHA-1 旧算法的那条警告）也交给 app 的 logger。
            logger: logger
        )
        // 等的时候被 `close()` 了：那时还没有东西可关，这里自己收尾，不留下连接。
        guard !isClosed else {
            await connected.close()
            throw SSHConnectionError.closed
        }

        let onChannelFailure = self.onChannelFailure
        let listener = LocalForwardListener(
            connected: connected,
            listenHost: request.localHost,
            listenPort: request.localPort,
            destHost: request.target.host,
            destPort: request.target.port,
            channelOpenTimeout: channelOpenTimeout,
            logger: logger,
            onChannelFailure: { error in
                onChannelFailure(SSHForwardingChannelFailure(classifying: error))
            }
        )
        let port: Int
        do {
            port = try await listener.start()
        } catch {
            await connected.close()
            throw SSHConnectionError.bindFailed(error.localizedDescription)
        }
        guard !isClosed else {
            await listener.close()
            await connected.close()
            throw SSHConnectionError.closed
        }
        self.connected = connected
        self.listener = listener
        // 每一跳都盯着：跳板机断了，内层的目标连接也会断，先到的那个原因算数。已经断了的话这里立刻回调。
        for client in [connected.target] + (connected.bastion.map { [$0] } ?? []) {
            let token = client.onDisconnect { [weak self] reason in
                guard !reason.isLocalClose else { return }
                Task { await self?.connectionLost(reason) }
            }
            disconnectTokens.append((client, token))
        }
        return SSHForwardingEndpoint(host: request.localHost, port: port)
    }

    /// SSH 连接断了：本地监听不再接连接（连进来的立刻关掉，不会再在死连接上开通道；端口留到 `close()` 才释放），
    /// 正在转发的连接随各自的 SSH 通道一起结束；连接本身也关掉（另一跳可能还连着）。只处理第一次。
    private func connectionLost(_ reason: SSHDisconnectReason) async {
        guard !isClosed, lostReason == nil else { return }
        lostReason = reason
        logger.log(SSHLogEvent(
            level: .error,
            message: "SSH 隧道断开：\(reason.userDescription)",
            metadata: ["host": request.endpoint.host, "port": String(request.endpoint.port)]
        ))
        // 监听的端口**不还给系统**，只是不再接连接（连进来的立刻关掉）：还给系统之后它可能被别的进程绑上，
        // app 还没来得及关掉的连接池（后台补连接、探活）再去连，就会把握手、密码、查询发给那个进程。
        // 端口在 `close()` 时才释放。
        await listener?.stopAccepting()
        await connected?.close()
        onDisconnect(reason)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let listener = self.listener
        let connected = self.connected
        self.listener = nil
        self.connected = nil
        for (client, token) in disconnectTokens { client.removeDisconnectObserver(token) }
        disconnectTokens.removeAll()
        await listener?.close()
        await connected?.close()
    }
}
