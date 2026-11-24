import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

// TCP 转发（RFC 4254 §7）：direct-tcpip（本地 → 远端）与 tcpip-forward / forwarded-tcpip（远端 → 本地）。

extension SSHClient {
    /// 开一条 direct-tcpip 通道，让服务器去连 `targetHost:targetPort`（`ssh -L` 的那一半）。
    ///
    /// 返回的子通道 pipeline 上收发 `ByteBuffer`。`initializer` 在子通道的 EventLoop 上、通道激活之前执行——
    /// 这时还不可能有数据进来，所以可以放心地加 handler，或用 `NIOAsyncChannel(wrappingChannelSynchronously:)`
    /// 包起来（必须在这里包：通道开成之后再从别的线程包，服务器先说话的协议的首包会被丢掉，跨线程调用还会断言崩溃）。
    ///
    /// 半关闭两个方向都生效：对端发 EOF 时 pipeline 收到 `ChannelEvent.inputClosed`、还能继续写；
    /// 本端 `close(mode: .output)` 发 EOF、还能继续读。
    public func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        originatorAddress: SocketAddress,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void> = { $0.eventLoop.makeSucceededVoidFuture() }
    ) async throws -> any Channel {
        try await openDirectTCPIP(targetHost: targetHost, targetPort: targetPort,
                                  originatorAddress: originatorAddress, allowsHalfClosure: true,
                                  initializer: initializer)
    }

    /// 开一条 direct-tcpip 通道并（在激活之前、在它的 EventLoop 上）包成 `NIOAsyncChannel`。
    /// 默认开启出站半关闭：`outbound.finish()` 发 EOF。
    public func openDirectTCPIPAsyncChannel(
        targetHost: String,
        targetPort: Int,
        originatorAddress: SocketAddress,
        configuration: NIOAsyncChannel<ByteBuffer, ByteBuffer>.Configuration = .init(isOutboundHalfClosureEnabled: true)
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let wrapped = NIOLockedValueBox<NIOAsyncChannel<ByteBuffer, ByteBuffer>?>(nil)
        let channel = try await openDirectTCPIP(
            targetHost: targetHost, targetPort: targetPort, originatorAddress: originatorAddress
        ) { child in
            child.eventLoop.makeCompletedFuture {
                let asyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: child, configuration: configuration)
                wrapped.withLockedValue { $0 = asyncChannel }
            }
        }
        guard let asyncChannel = wrapped.withLockedValue({ $0 }) else {
            channel.close(promise: nil)
            throw SSHChannelError.channelClosed
        }
        return asyncChannel
    }

    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        originatorAddress: SocketAddress,
        allowsHalfClosure: Bool,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let type = SSHChannelType.directTCPIP(.init(
            targetHost: targetHost, targetPort: targetPort, originatorAddress: originatorAddress))
        return try await openChildChannel(type: type) { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: allowsHalfClosure).flatMap {
                do {
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
                return initializer(child)
            }
        }
    }

    // MARK: - 远程转发

    /// 请服务器在 `host:port` 上监听（`ssh -R`），每个连进来的连接成为一条 forwarded-tcpip 子通道。
    ///
    /// `port` 为 0 时由服务器挑端口，结果在 `boundPort`。每条入站子通道先装好 `ByteBuffer` 编解码
    /// （并打开对端半关闭），再在它的 EventLoop 上、激活之前调 `initializer`——和 `openDirectTCPIP` 一样，
    /// 在这里装 handler 或包成 `NIOAsyncChannel`。`initializer` 返回失败的 future 会拒绝这条连接。
    ///
    /// - Throws: 服务器拒绝时抛 `SSHChannelError.globalRequestRejected`。
    public func startRemotePortForward(
        host: String,
        port: Int,
        initializer: @escaping @Sendable (any Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>
    ) async throws -> SSHRemotePortForward {
        let sshHandler = self.sshHandler
        let lifecycle = self.lifecycle
        // 先登记再发请求：服务器回应之前就可能有连接进来（port 为 0 时先按「这个地址的任意端口」登记）。
        remoteForwards.register(host: host, port: port, requestedPort: port, initializer: initializer)
        let response: EventLoopFuture<GlobalRequest.TCPForwardingResponse?> = eventLoop.flatSubmit {
            if let reason = lifecycle.disconnectReason {
                return self.eventLoop.makeFailedFuture(SSHChannelError.connectionClosed(reason))
            }
            let promise = self.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            sshHandler.value.sendTCPForwardingRequest(.listen(host: host, port: port), promise: promise)
            return promise.futureResult
        }
        let boundPort: Int
        do {
            let result = try await response.get()
            boundPort = (port == 0 ? result?.boundPort : nil) ?? port
        } catch let error as SSHChannelError {
            remoteForwards.unregister(host: host, port: port)
            throw error
        } catch {
            remoteForwards.unregister(host: host, port: port)
            if let reason = lifecycle.disconnectReason { throw SSHChannelError.connectionClosed(reason) }
            throw SSHChannelError.globalRequestRejected(.tcpipForward(host: host, port: port))
        }
        if boundPort != port {
            remoteForwards.rebind(host: host, from: port, to: boundPort)
        }
        return SSHRemotePortForward(client: self, host: host, requestedPort: port, boundPort: boundPort)
    }

    /// `startRemotePortForward` 的作用域写法：每个入站连接包成 `NIOAsyncChannel`（激活前、在它的 EventLoop 上），
    /// 交给 `onAccept` 在自己的子任务里处理。`onOpen` 在监听建立后调用一次（参数是实际端口）。
    /// 任务被取消时撤销监听并结束所有子任务后返回；连接断开时抛 `SSHChannelError.connectionClosed`。
    public func withRemotePortForward(
        host: String,
        port: Int,
        onOpen: @Sendable (Int) async -> Void = { _ in },
        onAccept: @escaping @Sendable (NIOAsyncChannel<ByteBuffer, ByteBuffer>, SSHChannelType.ForwardedTCPIP) async -> Void
    ) async throws {
        let accepted = AcceptQueue<(NIOAsyncChannel<ByteBuffer, ByteBuffer>, SSHChannelType.ForwardedTCPIP)>()
        let forward = try await startRemotePortForward(host: host, port: port) { channel, info in
            channel.eventLoop.makeCompletedFuture {
                guard accepted.isOpen else {
                    // 作用域已经结束：拒绝这条连接（还没包成 NIOAsyncChannel，失败即可）。
                    throw SSHChannelError.channelClosed
                }
                let asyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(isOutboundHalfClosureEnabled: true))
                if !accepted.push((asyncChannel, info)) {
                    // 检查与入队之间队列刚好关了：没人会消费它，按 NIOAsyncChannel 的规矩经 executeThenClose 收尾。
                    Task { try? await asyncChannel.executeThenClose { _, _ in } }
                }
            }
        }
        let token = onDisconnect { _ in accepted.close() }
        await onOpen(forward.boundPort)
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                while let (channel, info) = await accepted.next() {
                    group.addTask { await onAccept(channel, info) }
                }
            }
        } onCancel: {
            accepted.close()
        }
        removeDisconnectObserver(token)
        await forward.cancel()
        if !Task.isCancelled, let reason = disconnectReason {
            throw SSHChannelError.connectionClosed(reason)
        }
    }
}

/// 一个简单的多生产者、单消费者队列：`next()` 不因任务取消而提前返回（取消由调用方 `close()`），
/// 关闭之后已经入队的元素照样按顺序交出去，交完才返回 `nil`——放进来的 `NIOAsyncChannel` 一定有人收尾。
final class AcceptQueue<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var waiter: CheckedContinuation<Element?, Never>?
        var open = true
    }

    private enum PushOutcome {
        case rejected
        case queued
        case handOff(CheckedContinuation<Element?, Never>)
    }

    private let state = NIOLockedValueBox(State())

    var isOpen: Bool { state.withLockedValue { $0.open } }

    /// 入队；队列已关时返回 false。
    func push(_ element: Element) -> Bool {
        let outcome: PushOutcome = state.withLockedValue { state in
            guard state.open else { return .rejected }
            if let waiter = state.waiter {
                state.waiter = nil
                return .handOff(waiter)
            }
            state.items.append(element)
            return .queued
        }
        switch outcome {
        case .rejected:
            return false
        case .queued:
            return true
        case .handOff(let waiter):
            waiter.resume(returning: element)
            return true
        }
    }

    func next() async -> Element? {
        await withCheckedContinuation { continuation in
            let immediate: Element?? = state.withLockedValue { state in
                if !state.items.isEmpty { return .some(state.items.removeFirst()) }
                if !state.open { return .some(nil) }
                state.waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    /// 关闭队列：不再接收新元素，已入队的照样交出。幂等。
    func close() {
        let waiter: CheckedContinuation<Element?, Never>? = state.withLockedValue { state in
            state.open = false
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// 一个远程转发监听。`cancel()` 撤销（`cancel-tcpip-forward`）；连接断开后自然失效。
public final class SSHRemotePortForward: Sendable {
    /// 请求时写的监听地址。
    public let host: String
    /// 请求时写的端口（0 = 由服务器挑）。
    public let requestedPort: Int
    /// 服务器实际监听的端口。
    public let boundPort: Int
    private let client: SSHClient
    private let cancelled = NIOLockedValueBox(false)

    init(client: SSHClient, host: String, requestedPort: Int, boundPort: Int) {
        self.client = client
        self.host = host
        self.requestedPort = requestedPort
        self.boundPort = boundPort
    }

    /// 撤销监听。幂等；连接已断时直接返回。之后到达的 forwarded-tcpip 通道一律拒绝。
    public func cancel() async {
        let first = cancelled.withLockedValue { cancelled -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        guard first else { return }
        client.remoteForwards.unregister(host: host, port: boundPort)
        guard client.isConnected else { return }
        let sshHandler = client.sshHandler
        let host = self.host
        let port = boundPort
        let eventLoop = client.eventLoop
        _ = try? await eventLoop.flatSubmit {
            let promise = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            sshHandler.value.sendTCPForwardingRequest(.cancel(host: host, port: port), promise: promise)
            return promise.futureResult
        }.get()
    }
}

/// 入站 forwarded-tcpip 通道的分发表。NIOSSH 的入站通道回调只能在建 `NIOSSHHandler` 时给一个，
/// 所以先建这张表，回调查表找对应的监听。
final class SSHRemoteForwardRegistry: Sendable {
    typealias Initializer = @Sendable (any Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>

    private struct Key: Hashable {
        var host: String
        var port: Int
    }

    private struct Entry {
        var requestedPort: Int
        var initializer: Initializer
    }

    private let entries = NIOLockedValueBox<[Key: Entry]>([:])

    func register(host: String, port: Int, requestedPort: Int, initializer: @escaping Initializer) {
        entries.withLockedValue { $0[Key(host: host, port: port)] = Entry(requestedPort: requestedPort, initializer: initializer) }
    }

    func unregister(host: String, port: Int) {
        _ = entries.withLockedValue { $0.removeValue(forKey: Key(host: host, port: port)) }
    }

    /// 服务器回了实际端口：把「任意端口」的登记改到实际端口上。
    func rebind(host: String, from oldPort: Int, to newPort: Int) {
        entries.withLockedValue { entries in
            if let entry = entries.removeValue(forKey: Key(host: host, port: oldPort)) {
                entries[Key(host: host, port: newPort)] = entry
            }
        }
    }

    /// `NIOSSHHandler` 的入站通道回调（在 EventLoop 上）。只接 forwarded-tcpip，其余（服务器发起的
    /// session、direct-tcpip 等）一律拒绝。
    func initializeInbound(_ channel: any Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = type else {
            return channel.eventLoop.makeFailedFuture(SSHChannelError.channelClosed)
        }
        let entry = entries.withLockedValue { entries -> Entry? in
            if let exact = entries[Key(host: info.listeningHost, port: info.listeningPort)] { return exact }
            // 有的服务器回报的监听地址和请求时写的不完全一样（"" / "0.0.0.0" / "localhost"），按端口兜底；
            // 再不行就是 port 为 0、回应还没到的那一条。
            if let byPort = entries.first(where: { $0.key.port == info.listeningPort })?.value { return byPort }
            return entries.first { $0.key.port == 0 && $0.key.host == info.listeningHost }?.value
        }
        guard let entry else {
            return channel.eventLoop.makeFailedFuture(SSHChannelError.channelClosed)
        }
        return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            do {
                try channel.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
            return entry.initializer(channel, info)
        }
    }
}
