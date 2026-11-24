import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// 一条已认证的 SSH 连接（RFC 4251–4254 的客户端一侧）。
///
/// `Sendable`，可以在任意任务、任意线程里用；所有协议操作都在连接自己的 EventLoop 上执行，
/// async 接口只是一层薄壳。通道一律句柄式：`openExec` / `openShell` / `openSubsystemChannel` /
/// `openDirectTCPIP` 各返回自己的句柄或 NIO `Channel`，不需要挂住一个闭包。
///
/// 没有重连逻辑：断了就断了，由上层（USSHKit / app）决定要不要重新 `connect`。
public final class SSHClient: Sendable {
    /// 连接时写的主机名与端口（跳板机内层连接是目标机的）。
    public let host: String
    public let port: Int
    /// 承载这条 SSH 连接的 NIO 通道：直连是 TCP 通道，跳板机内层是外层连接上的 direct-tcpip 子通道。
    public let transport: any Channel

    let sshHandler: NIOLoopBound<NIOSSHHandler>
    let lifecycle: SSHConnectionLifecycle
    let remoteForwards: SSHRemoteForwardRegistry
    let logger: Logger

    /// 连接所在的 EventLoop。所有子通道也在这上面。
    public var eventLoop: any EventLoop { transport.eventLoop }

    init(host: String, port: Int, transport: any Channel, sshHandler: NIOLoopBound<NIOSSHHandler>,
                 lifecycle: SSHConnectionLifecycle, remoteForwards: SSHRemoteForwardRegistry, logger: Logger) {
        self.host = host
        self.port = port
        self.transport = transport
        self.sshHandler = sshHandler
        self.lifecycle = lifecycle
        self.remoteForwards = remoteForwards
        self.logger = logger
    }

    // MARK: - 建连

    /// 连接 `host:port`，完成握手与认证。
    ///
    /// 任务被取消会关掉正在建的连接并抛 `CancellationError`（TCP 建连那一段要等 `connectTimeout`
    /// 或建连结束才能停下——NIO 的建连不能中途撤回）。其余失败都是 `SSHClientError`。
    public static func connect(host: String, port: Int = 22, configuration: Configuration) async throws -> SSHClient {
        let group = configuration.eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
        let eventLoop = group.next()
        let setup = SSHConnectionSetup(host: host, port: port, configuration: configuration, eventLoop: eventLoop)
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(TimeAmount(configuration.connectTimeout))
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try setup.install(on: channel)
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch let error as ChannelError {
            if case .connectTimeout = error { throw SSHClientError.connectTimeout(configuration.connectTimeout) }
            throw SSHClientError.connectFailed(error)
        } catch {
            try Task.checkCancellation()
            throw SSHClientError.connectFailed(error)
        }
        return try await setup.finish(on: channel)
    }

    /// 在一条已经连上的通道上跑 SSH（测试、或者自己建的隧道）。
    ///
    /// 通道必须还没读过任何字节：要么用 `autoRead = false` 建、要么建好后立刻交过来，
    /// 否则对端的版本行可能在 handler 装上之前就被读走丢掉。通道归返回的 `SSHClient` 所有。
    public static func connect(on channel: any Channel, host: String, port: Int,
                               configuration: Configuration) async throws -> SSHClient {
        let setup = SSHConnectionSetup(host: host, port: port, configuration: configuration,
                                       eventLoop: channel.eventLoop)
        do {
            try await channel.eventLoop.submit {
                try setup.install(on: channel)
            }.get()
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
        } catch {
            channel.close(promise: nil)
            throw SSHClientError.connectFailed(error)
        }
        return try await setup.finish(on: channel)
    }

    /// 经这条连接的 direct-tcpip 通道连到 `host:port`，在上面再建一条 SSH 连接（`ssh -J`）。
    ///
    /// 内层连接跑在外层的 EventLoop 上：外层断开或被关闭，内层随之断开（原因是传输错误
    /// `NIOSSHError.tcpShutdown`）；关闭内层不影响外层。`configuration.maximumPacketSize` 只管内层；
    /// 外层那条 direct-tcpip 子通道的窗口由外层自己的配置决定，两跳都要设大才有用。
    /// `connectTimeout` 用作开 direct-tcpip 通道的时限。
    public func jump(to host: String, port: Int = 22, configuration: Configuration) async throws -> SSHClient {
        let setup = SSHConnectionSetup(host: host, port: port, configuration: configuration, eventLoop: eventLoop)
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let channel = try await withTimeout(configuration.connectTimeout, onTimeout: SSHClientError.connectTimeout(configuration.connectTimeout)) {
            try await self.openDirectTCPIP(
                targetHost: host, targetPort: port, originatorAddress: originator, allowsHalfClosure: false
            ) { child in
                child.eventLoop.makeCompletedFuture { try setup.install(on: child) }
            }
        }
        return try await setup.finish(on: channel)
    }

    // MARK: - 生命周期

    /// 认证成功、还没断开。
    public var isConnected: Bool { lifecycle.isConnected }

    /// 断开原因；还连着时是 `nil`。
    public var disconnectReason: SSHDisconnectReason? { lifecycle.disconnectReason }

    /// 挂一个断开观察者，可以挂任意多个。回调在连接的 EventLoop 上同步执行，别在里面阻塞。
    /// 已经断开时立刻回调一次。
    @discardableResult
    public func onDisconnect(_ observer: @escaping @Sendable (SSHDisconnectReason) -> Void) -> SSHDisconnectObserverToken {
        SSHDisconnectObserverToken(id: lifecycle.addObserver(observer))
    }

    /// 移除一个断开观察者。已经回调过或已移除的 token 无效果。
    public func removeDisconnectObserver(_ token: SSHDisconnectObserverToken) {
        lifecycle.removeObserver(token.id)
    }

    /// 等到连接断开，返回原因。
    public func waitForDisconnect() async -> SSHDisconnectReason {
        await lifecycle.waitForDisconnect()
    }

    /// 关闭连接。幂等；返回时断开观察者都已回调过。
    ///
    /// 跳板机内层连接的关闭要等外层对端回 CHANNEL_CLOSE；外层传输半死时最多等 `gracePeriod`，
    /// 之后照样算已关闭（观察者以 `.localClose` 回调），子通道留给外层断开时一起收拾。
    public func close(gracePeriod: Duration = .seconds(5)) async {
        lifecycle.markLocalClose()
        transport.close(promise: nil)
        let lifecycle = self.lifecycle
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await lifecycle.waitForDisconnect()
            }
            group.addTask {
                // 等待断开不响应取消，所以到点（或本任务被取消）时由这里收尾，等待那一头随之返回。
                try? await Task.sleep(for: gracePeriod)
                lifecycle.finish(.localClose)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// 确认对端还活着：开一个 session 通道再立刻关掉。对端的任何回应（包括拒绝开通道）都算活着。
    ///
    /// NIOSSH 0.15.2 不能从公开接口发任意全局请求，所以没有 `keepalive@openssh.com`；这是同样需要
    /// 对端应答的一次往返，不会在服务器上起进程。超时抛 `SSHChannelError.timeout`，连接已断抛
    /// `SSHChannelError.connectionClosed`——要不要因此关闭连接由调用方决定。
    public func ping(timeout: Duration = .seconds(10)) async throws {
        do {
            let channel = try await withTimeout(timeout, onTimeout: SSHChannelError.timeout(timeout)) {
                try await self.openChildChannel(type: .session) { $0.eventLoop.makeSucceededVoidFuture() }
            }
            channel.close(promise: nil)
        } catch SSHChannelError.openRejected {
            return
        }
    }
}

/// `onDisconnect` 返回的 token。
public struct SSHDisconnectObserverToken: Sendable, Hashable {
    let id: UInt64
}

// MARK: - 建连的公共部分

/// 一次建连用到的东西：在 EventLoop 上装 handler（`install`），再等认证结果（`finish`）。
/// 两步之间跨线程，所以是 Sendable：可变部分只有装好后存下的 handler，用锁保护。
final class SSHConnectionSetup: Sendable {
    let host: String
    let port: Int
    let configuration: SSHClient.Configuration
    let lifecycle = SSHConnectionLifecycle()
    let remoteForwards = SSHRemoteForwardRegistry()
    let authenticated: EventLoopPromise<Void>
    private let installed = NIOLockedValueBox<NIOLoopBound<NIOSSHHandler>?>(nil)

    init(host: String, port: Int, configuration: SSHClient.Configuration, eventLoop: any EventLoop) {
        self.host = host
        self.port = port
        self.configuration = configuration
        self.authenticated = eventLoop.makePromise(of: Void.self)
    }

    /// 在 `channel` 的 EventLoop 上同步调用：装 `NIOSSHHandler` 与 `SSHConnectionGuard`。
    func install(on channel: any Channel) throws {
        let eventLoop = channel.eventLoop
        let clock = SSHHandshakeClock(eventLoop: eventLoop, budget: TimeAmount(configuration.handshakeTimeout))
        let hostKeyDelegate = SSHHostKeyDelegate(
            eventLoop: eventLoop, validation: configuration.hostKeyValidation, host: host, port: port,
            timeout: configuration.hostKeyValidationTimeout, clock: clock)
        let authDelegate = SSHClientAuthDelegate(authentication: configuration.authentication)
        var nioConfiguration = SSHClientConfiguration(
            userAuthDelegate: authDelegate,
            serverAuthDelegate: hostKeyDelegate,
            globalRequestDelegate: nil,
            transportProtectionSchemes: configuration.algorithms.transportProtectionSchemes)
        nioConfiguration.maximumPacketSize = configuration.effectiveMaximumPacketSize
        let remoteForwards = self.remoteForwards
        let handler = NIOSSHHandler(
            role: .client(nioConfiguration),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { child, type in
                remoteForwards.initializeInbound(child, type: type)
            })
        let guardHandler = SSHConnectionGuard(
            lifecycle: lifecycle, authenticated: authenticated, clock: clock,
            hostKeyDelegate: hostKeyDelegate, authDelegate: authDelegate,
            handshakeTimeout: configuration.handshakeTimeout, logger: configuration.logger)
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(handler)
        try sync.addHandler(guardHandler)
        let bound = NIOLoopBound(handler, eventLoop: eventLoop)
        installed.withLockedValue { $0 = bound }
    }

    /// 等认证结果。失败或被取消时连接已经（或正在）关闭。
    func finish(on channel: any Channel) async throws -> SSHClient {
        let lifecycle = self.lifecycle
        do {
            try await withTaskCancellationHandler {
                try await authenticated.futureResult.get()
            } onCancel: {
                lifecycle.markLocalClose()
                channel.close(promise: nil)
            }
        } catch {
            channel.close(promise: nil)
            try Task.checkCancellation()
            throw error
        }
        guard let handler = installed.withLockedValue({ $0 }) else {
            // install 没跑到就成功了，不可能发生；保险起见按连接已断处理。
            channel.close(promise: nil)
            throw SSHClientError.connectionClosed(.localClose)
        }
        let logger = configuration.logger
        logger.debug("SSH 已连接", metadata: ["host": "\(host)", "port": "\(port)"])
        return SSHClient(host: host, port: port, transport: channel, sshHandler: handler,
                         lifecycle: lifecycle, remoteForwards: remoteForwards, logger: logger)
    }
}

// MARK: - 子通道

extension SSHClient {
    /// 开一条子通道。`initializer` 在子通道的 EventLoop 上、通道激活之前执行。
    /// 任务取消时立刻抛 `CancellationError`；之后才开成的通道会被关掉。
    func openChildChannel(
        type: SSHChannelType,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let sshHandler = self.sshHandler
        let lifecycle = self.lifecycle
        let future: EventLoopFuture<any Channel> = eventLoop.flatSubmit {
            if let reason = lifecycle.disconnectReason {
                return self.eventLoop.makeFailedFuture(SSHChannelError.connectionClosed(reason))
            }
            let promise = self.eventLoop.makePromise(of: (any Channel).self)
            sshHandler.value.createChannel(promise, channelType: type) { child, _ in
                initializer(child)
            }
            return promise.futureResult
        }
        do {
            return try await future.getCancellable { $0.close(promise: nil) }
        } catch let error as NIOSSHError {
            throw mapChannelError(error)
        } catch let error as ChannelError {
            throw mapChannelError(error)
        }
    }

    /// NIOSSH / NIO 的通道错误归成 `SSHChannelError`。
    func mapChannelError(_ error: any Error) -> any Error {
        if let error = error as? NIOSSHError {
            if error.type == .channelSetupRejected { return SSHChannelError.openRejected(error) }
            if error.type == .creatingChannelAfterClosure || error.type == .tcpShutdown {
                return SSHChannelError.connectionClosed(lifecycle.disconnectReason ?? .transportError(error))
            }
            return error
        }
        if let error = error as? ChannelError {
            switch error {
            case .eof, .ioOnClosedChannel, .alreadyClosed:
                if let reason = lifecycle.disconnectReason { return SSHChannelError.connectionClosed(reason) }
                return SSHChannelError.channelClosed
            default:
                return error
            }
        }
        return error
    }
}

// MARK: - 小工具

extension EventLoopFuture where Value: Sendable {
    /// `get()`，但任务被取消时立刻抛 `CancellationError`；future 之后才成功的话把值交给 `lateValue` 收拾。
    func getCancellable(lateValue: @escaping @Sendable (Value) -> Void) async throws -> Value {
        let promise = eventLoop.makePromise(of: Value.self)
        let state = NIOLockedValueBox(CancellableGetState.waiting)
        self.whenComplete { result in
            let abandoned = state.withLockedValue { state -> Bool in
                if case .abandoned = state { return true }
                state = .delivered
                return false
            }
            switch (abandoned, result) {
            case (true, .success(let value)): lateValue(value)
            case (true, .failure): break
            case (false, _): promise.completeWith(result)
            }
        }
        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            let abandon = state.withLockedValue { state -> Bool in
                guard case .waiting = state else { return false }
                state = .abandoned
                return true
            }
            if abandon { promise.fail(CancellationError()) }
        }
    }
}

enum CancellableGetState { case waiting, delivered, abandoned }

/// 给一段 async 操作加时限：到点抛 `onTimeout`，操作被取消。
func withTimeout<T: Sendable>(
    _ timeout: Duration, onTimeout: any Error,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw onTimeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
