import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import USSHCore

/// 进程内的 SSH 服务端，只给测试用：监听 127.0.0.1 的随机端口，架在 NIOSSH 的服务端角色上。
///
/// 本包的测试和 app 的测试宿主（沙盒里起不了 sshd）都用它。能力：口令 / 公钥认证（规则可编程）、
/// 脚本化 exec、回显 PTY shell（记录 TERM、窗口变化、环境变量）、direct-tcpip（真的去连目标）、
/// 远程转发、subsystem 挂载点（SFTP 那条线接在这里），以及故障注入。
public final class SSHTestServer: Sendable {
    public let host = "127.0.0.1"
    public let port: Int
    public let hostPublicKey: NIOSSHPublicKey

    let state: SSHTestServerState
    private let listener: any Channel

    private init(port: Int, hostPublicKey: NIOSSHPublicKey, state: SSHTestServerState, listener: any Channel) {
        self.port = port
        self.hostPublicKey = hostPublicKey
        self.state = state
        self.listener = listener
    }

    /// 起一个服务端。`group` 默认 `MultiThreadedEventLoopGroup.singleton`。
    public static func start(_ configuration: Configuration = Configuration(),
                             group: (any EventLoopGroup)? = nil) async throws -> SSHTestServer {
        // NIOSSH 的算法登记是进程级的：服务端要认 RSA 用户签名、提供 RSA 主机密钥或 DH，同样先登记。
        SSHAlgorithms.registerStandardAlgorithms()
        if configuration.requiresLegacyRegistration {
            SSHAlgorithms.registerLegacyAlgorithms()
        }
        let state = SSHTestServerState(configuration: configuration)
        let bootstrap = ServerBootstrap(group: group ?? MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try state.installConnection(on: channel)
                }
            }
        let listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = listener.localAddress?.port else {
            try? await listener.close()
            throw ChannelError.unknownLocalAddress
        }
        return SSHTestServer(port: port, hostPublicKey: configuration.effectiveHostKeys[0].publicKey,
                             state: state, listener: listener)
    }

    /// 到目前为止记下的事。
    public var events: SSHTestServerEvents { state.events.withLockedValue { $0 } }

    /// 当前开着的 TCP 连接数。
    public var connectionCount: Int { state.connections.withLockedValue { $0.count } }

    /// 等到 `predicate` 成立（每 10 ms 看一次），超时抛 `SSHTestServerTimeout`。
    @discardableResult
    public func waitForEvents(timeout: Duration = .seconds(5),
                              _ predicate: @Sendable (SSHTestServerEvents) -> Bool) async throws -> SSHTestServerEvents {
        let deadline = ContinuousClock.now + timeout
        while true {
            let snapshot = events
            if predicate(snapshot) { return snapshot }
            guard ContinuousClock.now < deadline else { throw SSHTestServerTimeout(events: snapshot) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 故障注入：直接掐断所有 TCP 连接（不发 SSH_MSG_DISCONNECT）。
    public func dropAllConnections() async {
        let channels = state.connections.withLockedValue { Array($0.values) }
        for channel in channels {
            try? await channel.close()
        }
    }

    /// 停止监听并断开所有连接。
    public func stop() async {
        try? await listener.close()
        await dropAllConnections()
    }
}

/// `waitForEvents` 超时。
public struct SSHTestServerTimeout: Error, Sendable {
    public var events: SSHTestServerEvents
}

/// 服务端记下的事，按发生顺序。
public struct SSHTestServerEvents: Sendable {
    public var authAttempts: [SSHTestAuthAttempt] = []
    public var execCommands: [String] = []
    public var shellRequests = 0
    public var ptyRequests: [SSHTestPTYInfo] = []
    public var windowChanges: [SSHTestWindowSize] = []
    /// 接受了的环境变量（同名后到的覆盖先到的）。
    public var environment: [String: String] = [:]
    /// 被拒绝的环境变量名。
    public var rejectedEnvironment: [String] = []
    public var subsystems: [String] = []
    public var signals: [String] = []
    /// direct-tcpip 的目标 "host:port"。
    public var directTCPIPTargets: [String] = []
    /// 收到的 tcpip-forward（"host:port"，port 是实际监听的）。
    public var remoteForwards: [String] = []
    public var cancelledRemoteForwards: [String] = []
    /// 断开过的连接数。
    public var closedConnections = 0
}

/// 服务端共享的状态（所有连接共用）。
final class SSHTestServerState: Sendable {
    let configuration: SSHTestServer.Configuration
    let events = NIOLockedValueBox(SSHTestServerEvents())
    let connections = NIOLockedValueBox<[ObjectIdentifier: any Channel]>([:])
    private let rejectionsLeft: NIOLockedValueBox<Int>

    init(configuration: SSHTestServer.Configuration) {
        self.configuration = configuration
        self.rejectionsLeft = NIOLockedValueBox(configuration.faults.rejectFirstAuthenticationAttempts)
    }

    func record(_ update: (inout SSHTestServerEvents) -> Void) {
        events.withLockedValue { update(&$0) }
    }

    /// 这一次要不要按故障注入拒绝。
    func consumeForcedRejection() -> Bool {
        rejectionsLeft.withLockedValue { left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }

    /// 在新 TCP 连接上装服务端 handler（在它的 EventLoop 上）。
    func installConnection(on channel: any Channel) throws {
        let id = ObjectIdentifier(channel)
        connections.withLockedValue { $0[id] = channel }
        channel.closeFuture.whenComplete { [self] _ in
            _ = connections.withLockedValue { $0.removeValue(forKey: id) }
            record { $0.closedConnections += 1 }
        }
        if configuration.faults.withholdServerVersion { return }

        let forwarding = SSHTestRemoteForwarding(state: self, eventLoop: channel.eventLoop)
        var serverConfiguration = SSHServerConfiguration(
            hostKeys: configuration.effectiveHostKeys,
            userAuthDelegate: SSHTestAuthDelegate(state: self, eventLoop: channel.eventLoop),
            globalRequestDelegate: forwarding)
        serverConfiguration.maximumPacketSize = configuration.maximumPacketSize
        if let keyExchangeAlgorithms = configuration.keyExchangeAlgorithms {
            serverConfiguration.keyExchangeAlgorithms = keyExchangeAlgorithms
        }
        serverConfiguration.serverSignatureAlgorithms = configuration.serverSignatureAlgorithms
        if let schemes = configuration.transportProtectionSchemes {
            serverConfiguration.transportProtectionSchemes = schemes
        }
        let handler = NIOSSHHandler(
            role: .server(serverConfiguration),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { [self] child, type in
                initializeChild(child, type: type)
            })
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(SSHTestErrorCloser())
        let boundForwarding = NIOLoopBound(forwarding, eventLoop: channel.eventLoop)
        channel.closeFuture.whenComplete { _ in
            boundForwarding.value.closeAll()
        }
    }

    private func initializeChild(_ child: any Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        switch type {
        case .session:
            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                try child.pipeline.syncOperations.addHandler(SSHTestSessionHandler(state: self))
            }
        case .directTCPIP(let target):
            record { $0.directTCPIPTargets.append("\(target.targetHost):\(target.targetPort)") }
            guard configuration.allowsDirectTCPIP else {
                return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
            }
            return SSHTestGlue.connect(child, toHost: target.targetHost, port: target.targetPort)
        case .forwardedTCPIP:
            // 服务端不接受客户端发起的 forwarded-tcpip。
            return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
        }
    }
}

/// 连接上出了错就关掉它（NIOSSH 自己只报错不关）。
final class SSHTestErrorCloser: ChannelInboundHandler {
    typealias InboundIn = Never

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// 服务端认证：按 `SSHTestAuthentication` 的规则，加上故障注入（延迟、先拒 N 次）。
final class SSHTestAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let state: SSHTestServerState
    private let eventLoop: any EventLoop

    init(state: SSHTestServerState, eventLoop: any EventLoop) {
        self.state = state
        self.eventLoop = eventLoop
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        state.configuration.authentication.supportedMethods
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        let method: SSHTestAuthAttempt.Method
        var rsaAlgorithm: SSHRSASignatureAlgorithm?
        switch request.request {
        case .password(let password): method = .password(password.password)
        case .publicKey(let key):
            method = .publicKey(key.publicKey)
            // NIOSSH 刚在同一个调用栈里验过签名，记录还在本线程上（见 `SSHRSAVerificationRecord`）。
            if key.publicKey.rsaPublicKey != nil {
                var blob = ByteBuffer()
                key.publicKey.write(to: &blob)
                rsaAlgorithm = SSHRSAVerificationRecord.take(keyBlob: Array(blob.readableBytesView))
            }
        case .none, .hostBased: method = .none
        }
        let state = self.state
        let username = request.username
        let rsaSignatureAlgorithm = rsaAlgorithm
        Task {
            if let delay = state.configuration.faults.authenticationDelay {
                try? await Task.sleep(for: delay)
            }
            var attempt = SSHTestAuthAttempt(
                username: username, method: method, rsaSignatureAlgorithm: rsaSignatureAlgorithm, accepted: false)
            let supported = state.configuration.authentication.supportedMethods
            let methodSupported: Bool
            switch method {
            case .none: methodSupported = false
            case .password: methodSupported = supported.contains(.password)
            case .publicKey: methodSupported = supported.contains(.publicKey)
            }
            // 不支持的方式直接拒绝，不占故障注入的次数。
            if methodSupported, !state.consumeForcedRejection() {
                attempt.accepted = await state.configuration.authentication.accepts(attempt)
            }
            let recorded = attempt
            state.record { $0.authAttempts.append(recorded) }
            responsePromise.succeed(recorded.accepted ? .success : .failure)
        }
    }
}
