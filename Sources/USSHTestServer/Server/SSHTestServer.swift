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
    /// 监听的地址（默认 127.0.0.1）。
    public let host: String
    public let port: Int
    public let hostPublicKey: NIOSSHPublicKey

    let state: SSHTestServerState
    private let listener: any Channel

    private init(host: String, port: Int, hostPublicKey: NIOSSHPublicKey, state: SSHTestServerState,
                 listener: any Channel) {
        self.host = host
        self.port = port
        self.hostPublicKey = hostPublicKey
        self.state = state
        self.listener = listener
    }

    /// 起一个服务端。`group` 默认 `MultiThreadedEventLoopGroup.singleton`；`bindHost` 默认只听 127.0.0.1
    /// （测「localhost 解析出的 ::1 连不上」时用得到），`port` 为 0 时随机。
    public static func start(_ configuration: Configuration = Configuration(),
                             group: (any EventLoopGroup)? = nil,
                             bindHost: String = "127.0.0.1",
                             port: Int = 0) async throws -> SSHTestServer {
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
        let listener = try await bootstrap.bind(host: bindHost, port: port).get()
        guard let boundPort = listener.localAddress?.port else {
            try? await listener.close()
            throw ChannelError.unknownLocalAddress
        }
        return SSHTestServer(host: bindHost, port: boundPort, hostPublicKey: configuration.effectiveHostKeys[0].publicKey,
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

    /// 故障注入：直接掐断所有 TCP 连接（不发 SSH_MSG_DISCONNECT）。客户端看到的是对端正常关闭（TCP EOF）。
    public func dropAllConnections() async {
        let channels = state.connections.withLockedValue { $0.values.map(\.channel) }
        for channel in channels {
            try? await channel.close()
        }
    }

    /// 故障注入：所有现有连接从此不读也不写（TCP 连接保持着），模拟链路卡死、对端失联。
    public func freezeAllConnections() async {
        let freezers = state.connections.withLockedValue { $0.values.map(\.freezer) }
        for freezer in freezers {
            try? await freezer.eventLoop.submit { freezer.value.freeze() }.get()
        }
    }

    /// 在每条连接（已装 SSH 的）的 EventLoop 上对它的 `NIOSSHHandler` 执行 `body`。测试拿它触发服务端发起的
    /// 重新交换密钥之类的操作。
    public func withEachConnection(_ body: @escaping @Sendable (NIOSSHHandler) throws -> Void) async throws {
        let handlers = state.connections.withLockedValue { $0.values.compactMap(\.handler) }
        for handler in handlers {
            try await handler.eventLoop.submit { try body(handler.value) }.get()
        }
    }

    /// 让每条连接现在就（由服务端发起）重新交换密钥。返回发起成功的连接数（交换已在进行中的不算）。
    @discardableResult
    public func rekeyAllConnections() async throws -> Int {
        let started = NIOLockedValueBox(0)
        try await withEachConnection { handler in
            if handler.rekey() { started.withLockedValue { $0 += 1 } }
        }
        return started.withLockedValue { $0 }
    }

    /// 服务端主动向（第一条）客户端连接开一条通道，返回开成的通道或抛出客户端的拒绝
    /// （`NIOSSHError`，`channelOpenFailureReasonCode` 是客户端给的原因码）。
    public func openChannelToClient(_ type: SSHChannelType) async throws -> any Channel {
        guard let handler = state.connections.withLockedValue({ $0.values.compactMap(\.handler).first }) else {
            throw ChannelError.ioOnClosedChannel
        }
        return try await handler.eventLoop.flatSubmit {
            let promise = handler.eventLoop.makePromise(of: (any Channel).self)
            handler.value.createChannel(promise, channelType: type) { child, _ in
                child.eventLoop.makeSucceededVoidFuture()
            }
            return promise.futureResult
        }.get()
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
    /// 接受过的 TCP 连接数（含已断开的）。
    public var acceptedConnections = 0
}

/// 服务端共享的状态（所有连接共用）。
final class SSHTestServerState: Sendable {
    let configuration: SSHTestServer.Configuration
    let events = NIOLockedValueBox(SSHTestServerEvents())
    struct Connection: Sendable {
        var channel: any Channel
        var freezer: NIOLoopBound<SSHTestFreezeHandler>
        var handler: NIOLoopBound<NIOSSHHandler>?
    }

    let connections = NIOLockedValueBox<[ObjectIdentifier: Connection]>([:])
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
        let freezer = SSHTestFreezeHandler()
        try channel.pipeline.syncOperations.addHandler(freezer)
        if configuration.faults.unusualNameLists {
            try channel.pipeline.syncOperations.addHandler(SSHTestNameListRewriter())
        }
        let boundFreezer = NIOLoopBound(freezer, eventLoop: channel.eventLoop)
        connections.withLockedValue { $0[id] = Connection(channel: channel, freezer: boundFreezer, handler: nil) }
        record { $0.acceptedConnections += 1 }
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
        serverConfiguration.rekeyLimits = configuration.rekeyLimits
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
        let boundHandler = NIOLoopBound(handler, eventLoop: channel.eventLoop)
        connections.withLockedValue { $0[id]?.handler = boundHandler }
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

/// 故障注入用：挂在 TCP 通道的最前面，冻结之后不再读、写出的数据直接丢掉（promise 照常完成）。
final class SSHTestFreezeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var frozen = false

    func freeze() {
        frozen = true
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // 冻结之前已经读进来的这一批也丢掉：对端看到的就是石沉大海。
        guard !frozen else { return }
        context.fireChannelRead(data)
    }

    func read(context: ChannelHandlerContext) {
        guard !frozen else { return }
        context.read()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !frozen else {
            promise?.succeed(())
            return
        }
        context.write(data, promise: promise)
    }
}

/// 故障注入用：把服务端版本行之后的第一个包（KEXINIT）里的每个 name-list 改成 `,a,,b,` 的写法。
final class SSHTestNameListRewriter: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var versionSent = false
    private var done = false

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !done else { return context.write(data, promise: promise) }
        var buffer = unwrapOutboundIn(data)
        var out = ByteBuffer()
        if !versionSent {
            guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                return context.write(data, promise: promise)
            }
            var line = buffer.readSlice(length: newline - buffer.readerIndex + 1)!
            out.writeBuffer(&line)
            versionSent = true
        }
        if buffer.readableBytes > 0 {
            let length = Int(buffer.readInteger(as: UInt32.self)!)
            let padding = Int(buffer.readInteger(as: UInt8.self)!)
            var payload = buffer.readSlice(length: length - 1 - padding)!
            buffer.moveReaderIndex(forwardBy: padding)
            var rewritten = ByteBuffer()
            rewritten.writeBytes(payload.readBytes(length: 17)!)            // 类型 + cookie
            for _ in 0..<10 {
                let listLength = Int(payload.readInteger(as: UInt32.self)!)
                let names = payload.readString(length: listLength)!.split(separator: ",")
                let list = names.isEmpty ? "," : "," + names.joined(separator: ",,") + ","
                rewritten.writeInteger(UInt32(list.utf8.count))
                rewritten.writeString(list)
            }
            rewritten.writeBuffer(&payload)
            var newPadding = 8 - (rewritten.readableBytes + 5) % 8
            if newPadding < 4 { newPadding += 8 }
            out.writeInteger(UInt32(rewritten.readableBytes + newPadding + 1))
            out.writeInteger(UInt8(newPadding))
            out.writeBuffer(&rewritten)
            out.writeBytes([UInt8](repeating: 0, count: newPadding))
            out.writeBuffer(&buffer)
            done = true
        }
        context.write(wrapOutboundOut(out), promise: promise)
    }
}

/// 连接上出了错就关掉它（NIOSSH 自己只报错不关）。
///
/// 关之前先 flush：NIOSSH 只在 `channelReadComplete` 里 flush，客户端的版本行与 KEXINIT 在同一次读里到达时，
/// 服务端被版本行触发写出的 KEXINIT 还没 flush，处理客户端的 KEXINIT 就已经协商失败、报错——不 flush 就关，
/// 这个 KEXINIT 永远发不出去，客户端只看到对端关闭（分不出是不是协商失败）。真实的服务器（OpenSSH）在读对方的
/// KEXINIT 之前就已经发出自己的，失败时还会先发 DISCONNECT。
final class SSHTestErrorCloser: ChannelInboundHandler {
    typealias InboundIn = Never

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.flush()
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
            var outcome = NIOSSHUserAuthenticationOutcome.failure
            if methodSupported, !state.consumeForcedRejection() {
                switch await state.configuration.authentication.decide(attempt) {
                case .accept:
                    outcome = .success
                case .reject:
                    outcome = .failure
                case .partialSuccess(let remaining):
                    outcome = .partialSuccess(remainingMethods: remaining)
                }
            }
            if case .success = outcome { attempt.accepted = true }
            let recorded = attempt
            state.record { $0.authAttempts.append(recorded) }
            responsePromise.succeed(outcome)
        }
    }
}
