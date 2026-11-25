#if USSH_TEST_SERVER
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import USSHCore

/// 把两条通道的字节对接起来（经典的 NIO glue）：一边读到的写到另一边，另一边写不动就停读；
/// 一边 EOF 就关另一边的写方向；一边关了另一边也关。两条通道必须在同一个 EventLoop 上。
final class SSHTestGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: SSHTestGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// 最后一笔写入：半关闭要等它真的写出去。NIO 的 socket 在 `close(mode: .output)` 时会让还没写出的数据失败。
    private var lastWrite: EventLoopFuture<Void>?

    static func pair() -> (SSHTestGlueHandler, SSHTestGlueHandler) {
        let first = SSHTestGlueHandler()
        let second = SSHTestGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    private func partnerWrite(_ data: NIOAny) {
        guard let context else { return }
        let promise = context.eventLoop.makePromise(of: Void.self)
        lastWrite = promise.futureResult
        context.write(data, promise: promise)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        guard let context else { return }
        // 对端的 EOF 可能和最后一块数据在同一批里到、排在 channelReadComplete 之前：先冲出去，等写完再半关。
        context.flush()
        if let lastWrite {
            lastWrite.assumeIsolated().whenComplete { _ in context.close(mode: .output, promise: nil) }
        } else {
            context.close(mode: .output, promise: nil)
        }
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

enum SSHTestGlue {
    /// direct-tcpip：在子通道的 EventLoop 上连目标，连上之后两边对接；连不上则让开通道失败
    /// （客户端收到 CHANNEL_OPEN_FAILURE，和 OpenSSH 的行为一致）。
    static func connect(_ child: any Channel, toHost host: String, port: Int) -> EventLoopFuture<Void> {
        child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            ClientBootstrap(group: child.eventLoop)
                .channelOption(.allowRemoteHalfClosure, value: true)
                .connect(host: host, port: port)
        }.flatMapThrowing { target in
            let (childGlue, targetGlue) = SSHTestGlueHandler.pair()
            try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
            try child.pipeline.syncOperations.addHandler(childGlue)
            try target.pipeline.syncOperations.addHandler(targetGlue)
        }
    }
}

/// 服务端的远程转发（RFC 4254 §7.1）：tcpip-forward 时在 127.0.0.1 上真的监听，每个连进来的连接
/// 开一条 forwarded-tcpip 子通道给客户端。只在连接的 EventLoop 上用。
final class SSHTestRemoteForwarding: GlobalRequestDelegate {
    private let state: SSHTestServerState
    private let eventLoop: any EventLoop
    private var listeners: [String: any Channel] = [:]
    private var closed = false

    init(state: SSHTestServerState, eventLoop: any EventLoop) {
        self.state = state
        self.eventLoop = eventLoop
    }

    func tcpForwardingRequest(_ request: GlobalRequest.TCPForwardingRequest, handler: NIOSSHHandler,
                              promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>) {
        guard state.configuration.allowsRemoteForwarding, !closed else {
            promise.fail(ChannelError.operationUnsupported)
            return
        }
        switch request {
        case .listen(let host, let port):
            listen(host: host, port: port, handler: handler, promise: promise)
        case .cancel(let host, let port):
            let key = "\(host):\(port)"
            state.record { $0.cancelledRemoteForwards.append(key) }
            if let listener = listeners.removeValue(forKey: key) {
                listener.close(promise: nil)
                promise.succeed(.init(boundPort: nil))
            } else {
                promise.fail(ChannelError.operationUnsupported)
            }
        }
    }

    private func listen(host: String, port: Int, handler: NIOSSHHandler,
                        promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>) {
        let sshHandler = NIOLoopBound(handler, eventLoop: eventLoop)
        let eventLoop = self.eventLoop
        let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
        ServerBootstrap(group: eventLoop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { accepted in
                // 和 SSH 连接在同一个 EventLoop 上，可以直接用 NIOSSHHandler。
                let remote = accepted.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
                let boundPort = accepted.localAddress?.port ?? port
                guard let remote else { return eventLoop.makeFailedFuture(ChannelError.unknownLocalAddress) }
                let info = SSHChannelType.ForwardedTCPIP(
                    listeningHost: host, listeningPort: boundPort, originatorAddress: remote)
                let opened = eventLoop.makePromise(of: (any Channel).self)
                sshHandler.value.createChannel(opened, channelType: .forwardedTCPIP(info)) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                        let (childGlue, acceptedGlue) = SSHTestGlueHandler.pair()
                        try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                        try child.pipeline.syncOperations.addHandler(childGlue)
                        try accepted.pipeline.syncOperations.addHandler(acceptedGlue)
                    }
                }
                opened.futureResult.whenComplete { result in
                    switch result {
                    case .success:
                        accepted.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                    case .failure:
                        accepted.close(promise: nil)
                    }
                }
                return eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: port)
            .whenComplete { result in
                switch result {
                case .success(let listener):
                    let bound = listener.localAddress?.port ?? port
                    let this = loopBoundSelf.value
                    guard !this.closed else {
                        listener.close(promise: nil)
                        promise.fail(ChannelError.ioOnClosedChannel)
                        return
                    }
                    let key = "\(host):\(bound)"
                    this.listeners[key] = listener
                    this.state.record { $0.remoteForwards.append(key) }
                    promise.succeed(.init(boundPort: port == 0 ? bound : nil))
                case .failure(let error):
                    promise.fail(error)
                }
            }
    }

    /// SSH 连接断了：关掉所有监听。
    func closeAll() {
        closed = true
        for listener in listeners.values { listener.close(promise: nil) }
        listeners.removeAll()
    }
}
#endif
