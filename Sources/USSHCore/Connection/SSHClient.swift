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

    /// `keepalive@openssh.com`：OpenSSH 自己的保活请求名，任何实现都会回 SUCCESS 或 FAILURE。
    static let keepAliveRequestType = "keepalive@openssh.com"

    /// 连接 `host:port`，完成握手与认证。
    ///
    /// TCP 建连走 NIO 的 Happy Eyeballs（RFC 8305）：一个名字解析出多个地址时并行尝试，SSH 只装在胜出的那条
    /// 连接上（落败的连接各自关掉，不影响结果）。任务被取消会关掉正在建的连接并抛 `CancellationError`
    /// （TCP 建连那一段立刻返回，晚到的连接随即关掉）。其余失败都是 `SSHClientError`。
    public static func connect(host: String, port: Int = 22, configuration: Configuration) async throws -> SSHClient {
        try await connect(host: host, port: port, configuration: configuration, resolver: nil)
    }

    /// 同上，可以换 DNS 解析器（测试用：造「第一个地址连不上」的情形）。
    static func connect(host: String, port: Int, configuration: Configuration,
                        resolver: (any Resolver & Sendable)?) async throws -> SSHClient {
        let group = configuration.eventLoopGroup ?? MultiThreadedEventLoopGroup.singleton
        // autoRead 关着建连：胜出的通道交给 connect(on:) 装好 handler 再开始读，版本行不会丢。
        // 不在 channelInitializer 里装：Happy Eyeballs 对每次尝试都跑一遍 initializer，
        // 落败的尝试被关掉时会把共用的握手状态一起带坏。
        var bootstrap = ClientBootstrap(group: group)
            .connectTimeout(TimeAmount(configuration.connectTimeout))
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelOption(.autoRead, value: false)
        if let resolver { bootstrap = bootstrap.resolver(resolver) }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).getCancellable { $0.close(promise: nil) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChannelError {
            if case .connectTimeout = error { throw SSHClientError.connectTimeout(configuration.connectTimeout) }
            throw SSHClientError.connectFailed(error)
        } catch {
            throw SSHClientError.connectFailed(error)
        }
        return try await connect(on: channel, host: host, port: port, configuration: configuration)
    }

    /// 在一条已经连上的通道上跑 SSH（测试、或者自己建的隧道）。
    ///
    /// 通道必须还没读过任何字节：用 `autoRead = false` 建（这里装好 handler 之后会打开它）、或建好后立刻交过来，
    /// 否则对端的版本行可能在 handler 装上之前就被读走丢掉。通道归返回的 `SSHClient` 所有，失败时会被关掉。
    public static func connect(on channel: any Channel, host: String, port: Int,
                               configuration: Configuration) async throws -> SSHClient {
        let setup = SSHConnectionSetup(host: host, port: port, configuration: configuration)
        do {
            try await channel.eventLoop.submit {
                try setup.install(on: channel)
                // 只读本地状态，同步可得；失败也无妨（读不到就等对端的数据自己触发）。
                _ = channel.setOption(ChannelOptions.autoRead, value: true)
            }.get()
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
    /// `connectTimeout` 用作开 direct-tcpip 通道的时限，`handshakeTimeout` 照常管内层握手——外层链路卡死
    /// 时两者都能让 `jump` 按时失败，任务取消也会立刻返回。
    public func jump(to host: String, port: Int = 22, configuration: Configuration) async throws -> SSHClient {
        let setup = SSHConnectionSetup(host: host, port: port, configuration: configuration)
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let channel = try await withTimeout(
            configuration.connectTimeout,
            onTimeout: SSHClientError.connectTimeout(configuration.connectTimeout),
            discard: { $0.close(promise: nil) }
        ) {
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

    /// 挂一个断开观察者，可以挂任意多个。回调同步执行（通常在连接的 EventLoop 上），别在里面阻塞。
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

    /// 确认对端还活着：发一个 `keepalive@openssh.com`（want-reply）。对端回 SUCCESS 或 FAILURE 都算活着。
    ///
    /// 超时抛 `SSHChannelError.timeout`，连接已断抛 `SSHChannelError.connectionClosed`——要不要因此关闭连接
    /// 由调用方决定（自动判死用 `Configuration.keepAliveInterval`）。
    public func ping(timeout: Duration = .seconds(10)) async throws {
        let sshHandler = self.sshHandler
        let lifecycle = self.lifecycle
        let eventLoop = self.eventLoop
        let response: EventLoopFuture<GlobalRequest.GenericResponse> = eventLoop.flatSubmit {
            if let reason = lifecycle.disconnectReason {
                return eventLoop.makeFailedFuture(SSHChannelError.connectionClosed(reason))
            }
            let promise = eventLoop.makePromise(of: GlobalRequest.GenericResponse.self)
            sshHandler.value.sendGlobalRequest(
                type: Self.keepAliveRequestType, payload: nil, wantReply: true, promise: promise)
            return promise.futureResult
        }
        do {
            _ = try await withTimeout(timeout, onTimeout: SSHChannelError.timeout(timeout)) {
                try await response.getCancellable { _ in }
            }
        } catch let error as SSHChannelError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SSHChannelError.connectionClosed(await connectionClosedReason(error))
        }
    }
}

extension SSHClient {
    /// 现在就重新交换密钥（RFC 4253 §9）。连接没建立好、或已有一次交换在进行（任一方发起）时什么也不做，
    /// 返回 false。交换期间各通道的写入排队，完成后按序发出（NIOSSH 补丁 0012）；主机密钥必须与第一次相同，
    /// 不会再调主机密钥回调。
    @discardableResult
    public func rekey() async -> Bool {
        let sshHandler = self.sshHandler
        return (try? await eventLoop.submit { sshHandler.value.rekey() }.get()) ?? false
    }
}

/// `onDisconnect` 返回的 token。
public struct SSHDisconnectObserverToken: Sendable, Hashable {
    let id: UInt64
}

// MARK: - 建连的公共部分

/// 一次建连用到的东西：在 EventLoop 上装 handler（`install`），再等认证结果（`finish`）。
/// 两步之间跨线程，所以是 Sendable：可变部分只有装好后存下的东西，用锁保护。
///
/// 等认证结果的 promise 在 `install` 里建、交给 `SSHConnectionGuard` 负责完成：没装上（DNS 失败、建连超时、
/// 外层连接已断……）就根本没有这个 promise，不会留下一个没人完成的 promise（NIO 在 Debug 下会为此崩溃）。
final class SSHConnectionSetup: Sendable {
    let host: String
    let port: Int
    let configuration: SSHClient.Configuration
    let lifecycle = SSHConnectionLifecycle()
    let remoteForwards = SSHRemoteForwardRegistry()

    private struct Installed: Sendable {
        var handler: NIOLoopBound<NIOSSHHandler>
        var authenticated: EventLoopFuture<Void>
    }

    private let installed = NIOLockedValueBox<Installed?>(nil)

    init(host: String, port: Int, configuration: SSHClient.Configuration) {
        self.host = host
        self.port = port
        self.configuration = configuration
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
        nioConfiguration.rekeyLimits = configuration.rekeyLimits
        let remoteForwards = self.remoteForwards
        let handler = NIOSSHHandler(
            role: .client(nioConfiguration),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { child, type in
                remoteForwards.initializeInbound(child, type: type)
            })
        let keepAlive = configuration.keepAliveInterval.map {
            SSHConnectionGuard.KeepAlive(interval: $0, maximumUnanswered: max(configuration.keepAliveMaximumUnanswered, 0))
        }
        let authenticated = eventLoop.makePromise(of: Void.self)
        let guardHandler = SSHConnectionGuard(
            lifecycle: lifecycle, authenticated: authenticated, clock: clock,
            hostKeyDelegate: hostKeyDelegate, authDelegate: authDelegate, sshHandler: handler,
            handshakeTimeout: configuration.handshakeTimeout, keepAlive: keepAlive, logger: configuration.logger)
        do {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(handler)
            try sync.addHandler(guardHandler)
        } catch {
            authenticated.fail(error)
            throw error
        }
        let bound = NIOLoopBound(handler, eventLoop: eventLoop)
        installed.withLockedValue { $0 = Installed(handler: bound, authenticated: authenticated.futureResult) }
    }

    /// 等认证结果。失败或被取消时连接已经（或正在）关闭。
    func finish(on channel: any Channel) async throws -> SSHClient {
        guard let installed = installed.withLockedValue({ $0 }) else {
            channel.close(promise: nil)
            throw SSHClientError.connectionClosed(.localClose)
        }
        let lifecycle = self.lifecycle
        do {
            try await installed.authenticated.getCancellable { _ in }
        } catch is CancellationError {
            lifecycle.markLocalClose()
            channel.close(promise: nil)
            throw CancellationError()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        // 认证刚好在取消之后完成：不把一条马上要被丢掉的连接交出去。
        if Task.isCancelled {
            lifecycle.markLocalClose()
            channel.close(promise: nil)
            throw CancellationError()
        }
        let logger = configuration.logger
        logger.debug("SSH 已连接", metadata: ["host": "\(host)", "port": "\(port)"])
        return SSHClient(host: host, port: port, transport: channel, sshHandler: installed.handler,
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
            throw await mapChannelError(error)
        } catch let error as ChannelError {
            throw await mapChannelError(error)
        }
    }

    /// NIOSSH / NIO 的通道错误归成 `SSHChannelError`。
    func mapChannelError(_ error: any Error) async -> any Error {
        if let error = error as? NIOSSHError {
            if error.type == .channelSetupRejected {
                return SSHChannelError.openRejected(SSHChannelOpenFailure(
                    reasonCode: error.channelOpenFailureReasonCode ?? 0,
                    description: error.channelOpenFailureDescription ?? ""))
            }
            if error.type == .creatingChannelAfterClosure || error.type == .tcpShutdown {
                return SSHChannelError.connectionClosed(await connectionClosedReason(error))
            }
            return error
        }
        if let error = error as? ChannelError {
            switch error {
            case .eof, .ioOnClosedChannel, .alreadyClosed:
                if lifecycle.disconnectReason != nil || !transport.isActive || lifecycle.localCloseRequested {
                    return SSHChannelError.connectionClosed(await connectionClosedReason(error))
                }
                return SSHChannelError.channelClosed
            default:
                return error
            }
        }
        return error
    }

    /// 连接断了的原因。子通道先于连接的 closeFuture 回调被拆掉，所以原因可能还差一拍才定下来：
    /// 本端在关就是 `.localClose`，否则稍等它落定（最多半秒），实在等不到才按 `fallback` 算传输错误。
    func connectionClosedReason(_ fallback: any Error) async -> SSHDisconnectReason {
        for _ in 0..<100 {
            if let reason = lifecycle.disconnectReason { return reason }
            if lifecycle.localCloseRequested { return .localClose }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lifecycle.disconnectReason ?? .transportError(fallback)
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
///
/// 计时器赢了而操作恰好也交出了结果（两者几乎同时完成）时，那个结果没人要，交给 `discard` 收拾
/// （例如关掉开好的通道），不会泄漏。
func withTimeout<T: Sendable>(
    _ timeout: Duration, onTimeout: any Error,
    discard: @escaping @Sendable (T) -> Void = { _ in },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first: Result<T?, any Error>
        do {
            first = .success(try await group.next() ?? nil)
        } catch {
            first = .failure(error)
        }
        group.cancelAll()
        // 把剩下的那个也收回来：它若是操作的结果，交给 discard。
        while let rest = try? await group.next() {
            if let value = rest { discard(value) }
        }
        switch first {
        case .success(.some(let value)): return value
        case .success(.none): throw onTimeout
        case .failure(let error): throw error
        }
    }
}
