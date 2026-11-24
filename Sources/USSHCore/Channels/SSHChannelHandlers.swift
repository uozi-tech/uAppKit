import NIOCore
import NIOSSH

/// 子通道上的 `SSHChannelData` ⇄ `ByteBuffer`：只有通道数据（type 0）往后传，扩展数据（stderr 等）丢掉。
/// direct-tcpip、forwarded-tcpip、subsystem、跳板机内层连接都用它，之后的 handler 只看到字节流。
public final class SSHChannelDataCodec: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel else { return }
        switch message.data {
        case .byteBuffer(let buffer):
            context.fireChannelRead(wrapInboundOut(buffer))
        case .fileRegion:
            // 入站数据不会是 FileRegion。
            break
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

@available(*, unavailable)
extension SSHChannelDataCodec: Sendable {}

/// session 通道上的请求与回应（RFC 4254 §6）：发带 want-reply 的请求并按顺序等 SUCCESS / FAILURE；
/// 记下对端的 exit-status / exit-signal。数据原样往后传。只在通道的 EventLoop 上用。
final class SSHChannelRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData

    /// 等回应的请求，按发出顺序（RFC 4254 §5.4：回应按请求的顺序回来）。
    private var pendingReplies = CircularBuffer<(promise: EventLoopPromise<Void>, kind: SSHChannelRequestKind)>()
    private let eventLoop: any EventLoop
    private var context: ChannelHandlerContext?
    private(set) var exitStatus: SSHExitStatus?
    /// 收到 SUCCESS 时、在同一个 EventLoop tick 里要跑的动作（subsystem 的 initializer），按请求顺序。
    var onSuccess: [SSHChannelRequestKind: () -> Void] = [:]

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failAll(SSHChannelError.channelClosed)
        self.context = nil
    }

    /// 发一个请求。`wantReply` 为 false 时写出去就算完成。
    func send(_ event: any Sendable, kind: SSHChannelRequestKind, wantReply: Bool) -> EventLoopFuture<Void> {
        guard let context else {
            return eventLoop.makeFailedFuture(SSHChannelError.channelClosed)
        }
        let written = context.eventLoop.makePromise(of: Void.self)
        if wantReply {
            let reply = context.eventLoop.makePromise(of: Void.self)
            pendingReplies.append((reply, kind))
            context.triggerUserOutboundEvent(event, promise: written)
            written.futureResult.assumeIsolated().whenFailure { [weak self] error in
                self?.dropPending(reply, error: error)
            }
            return reply.futureResult
        }
        context.triggerUserOutboundEvent(event, promise: written)
        return written.futureResult
    }

    private func dropPending(_ promise: EventLoopPromise<Void>, error: any Error) {
        guard let index = pendingReplies.firstIndex(where: { $0.promise.futureResult === promise.futureResult }) else {
            return
        }
        pendingReplies.remove(at: index)
        promise.fail(error)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if let next = pendingReplies.popFirst() {
                onSuccess.removeValue(forKey: next.kind)?()
                next.promise.succeed(())
            }
        case is ChannelFailureEvent:
            if let next = pendingReplies.popFirst() {
                onSuccess.removeValue(forKey: next.kind)
                next.promise.fail(SSHChannelError.requestRejected(next.kind))
            }
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = .exited(status.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitStatus = .signaled(SSHExitSignal(
                name: signal.signalName, coreDumped: signal.dumpedCore, message: signal.errorMessage))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SSHChannelError.channelClosed)
        context.fireChannelInactive()
    }

    private func failAll(_ error: any Error) {
        while let next = pendingReplies.popFirst() {
            next.promise.fail(error)
        }
        onSuccess.removeAll()
    }
}

/// exec / shell 通道的输出端：把通道数据交给一个带背压的 async 序列。
///
/// 背压：序列里攒够 `highWatermark` 块就不再向子通道要数据（拦下 `read()`），NIOSSH 收不到读请求就不会
/// 把数据交上来，也就不发 window-adjust，对端在窗口（包长 × 64）用完后停下。所以慢消费者占用的内存
/// 上限是「窗口 + 高水位 × 包长」，不会无限涨。消费者跑掉（任务取消、提前退出循环、句柄被释放）时关掉通道。
final class SSHSessionOutputHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Any

    typealias Producer = NIOThrowingAsyncSequenceProducer<
        SSHChannelOutputChunk, any Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        Delegate
    >

    struct Delegate: NIOAsyncSequenceProducerDelegate {
        let handler: NIOLoopBound<SSHSessionOutputHandler>

        func produceMore() {
            handler.eventLoop.execute { handler.value.resumeReading() }
        }

        func didTerminate() {
            handler.eventLoop.execute { handler.value.consumerGone() }
        }
    }

    private var source: Producer.Source?
    private var context: ChannelHandlerContext?
    private var paused = false
    private var readPending = false
    private var finished = false
    private var error: (any Error)?

    /// 建好序列（在通道的 EventLoop 上）。序列只交给一个消费者。
    static func make(eventLoop: any EventLoop) -> (SSHSessionOutputHandler, Producer) {
        let handler = SSHSessionOutputHandler()
        let sequence = Producer.makeSequence(
            backPressureStrategy: .init(lowWatermark: 2, highWatermark: 8),
            finishOnDeinit: true,
            delegate: Delegate(handler: NIOLoopBound(handler, eventLoop: eventLoop)))
        handler.source = sequence.source
        return (handler, sequence.sequence)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, let source else { return }
        let chunk: SSHChannelOutputChunk = message.type == .stdErr ? .stderr(buffer) : .stdout(buffer)
        if case .stopProducing = source.yield(chunk) {
            paused = true
        }
    }

    func read(context: ChannelHandlerContext) {
        if paused {
            readPending = true
        } else {
            context.read()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if self.error == nil { self.error = error }
        context.fireErrorCaught(error)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // 对端 EOF（ChannelEvent.inputClosed）不结束序列：exit-status 往往在 EOF 之后才到，
        // 序列等通道真正关闭时才结束，那时退出状态已经确定。
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
        self.context = nil
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let error {
            // 通道是因为出错才拆的（典型：整条连接断了，NIOSSH 报 tcpShutdown）。正常关闭（含对端先关）不算错。
            source?.finish(SSHChannelError.connectionClosed(.transportError(error)))
        } else {
            source?.finish()
        }
        source = nil
    }

    fileprivate func resumeReading() {
        paused = false
        if readPending, let context {
            readPending = false
            context.read()
        }
    }

    fileprivate func consumerGone() {
        // 序列正常结束（我们 finish 的）之后也会走到这里，那时通道已经关了。
        guard !finished, let context else { return }
        context.close(promise: nil)
    }
}
