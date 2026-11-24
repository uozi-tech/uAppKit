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

    private var connected: ConnectedClient?
    private var listener: LocalForwardListener?
    private var isClosed = false
    /// SSH 连接（任一跳）断开的原因；断了之后监听已经关掉。
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
        onDisconnect: @escaping @Sendable (SSHDisconnectReason) -> Void = { _ in }
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
    }

    /// 隧道能用：已经 `open()`、没有 `close()`、本地监听开着、每一跳的 SSH 连接都还连着。
    /// SSH 连接断了（服务器关闭、传输出错、保活判死）之后恒为 false——隧道不会自己重连，要换一条新的。
    public var isConnected: Bool {
        guard !isClosed, lostReason == nil, listener != nil, let connected else { return false }
        return connected.isConnected
    }

    /// SSH 连接断开的原因（本端 `close()` 不算）。连着、没开、或是本端关的时为 nil。
    public var disconnectReason: SSHDisconnectReason? { lostReason }

    public func open() async throws -> SSHForwardingEndpoint {
        guard connected == nil, listener == nil else {
            throw SSHConnectionError.alreadyOpen
        }
        guard !isClosed else {
            throw SSHConnectionError.closed
        }

        let connected = try await SSHClientFactory.connect(
            endpoint: request.endpoint,
            credential: request.credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            keepAliveInterval: keepAliveInterval,
            // 建连这一段的日志（用上了 SHA-1 旧算法的那条警告）也交给 app 的 logger。
            logger: logger
        )

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

    /// SSH 连接断了：和本端关闭一样收掉本地监听（之后连进本地端口的连接立刻被拒，不会再在死连接上开通道），
    /// 正在转发的连接随各自的 SSH 通道一起结束；连接本身也关掉（另一跳可能还连着）。只处理第一次。
    private func connectionLost(_ reason: SSHDisconnectReason) async {
        guard !isClosed, lostReason == nil else { return }
        lostReason = reason
        logger.log(SSHLogEvent(
            level: .error,
            message: "SSH 隧道断开：\(reason.userDescription)",
            metadata: ["host": request.endpoint.host, "port": String(request.endpoint.port)]
        ))
        let listener = self.listener
        self.listener = nil
        await listener?.close()
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
