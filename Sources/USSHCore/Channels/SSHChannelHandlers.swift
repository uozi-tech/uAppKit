import NIOCore
import NIOSSH

/// 子通道上的 `SSHChannelData` ⇄ `ByteBuffer`：只有通道数据（type 0）往后传，扩展数据（stderr 等）丢掉。
/// direct-tcpip、forwarded-tcpip、subsystem、跳板机内层连接都用它，之后的 handler 只看到字节流。
/// 半关闭原样透传（对端 EOF 是 `ChannelEvent.inputClosed`，本端 `close(mode: .output)` 发 EOF）。
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
    /// exit-status / exit-signal 到了（值），或者通道关了也没等到（nil）。只完成一次。
    let exitStatusArrival: EventLoopPromise<SSHExitStatus?>
    private var exitStatusDelivered = false
    /// 收到 SUCCESS 时、在同一个 EventLoop tick 里要跑的动作（subsystem 的 initializer），按请求顺序。
    /// 抛错则这个请求按失败（带那个错误）完成，通道随之关闭。
    var onSuccess: [SSHChannelRequestKind: () throws -> Void] = [:]

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
        self.exitStatusArrival = eventLoop.makePromise(of: SSHExitStatus?.self)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failAll(SSHChannelError.channelClosed)
        deliverExitStatus(nil)
        self.context = nil
    }

    private func deliverExitStatus(_ status: SSHExitStatus?) {
        guard !exitStatusDelivered else { return }
        exitStatusDelivered = true
        exitStatusArrival.succeed(status)
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
                do {
                    try onSuccess.removeValue(forKey: next.kind)?()
                    next.promise.succeed(())
                } catch {
                    next.promise.fail(error)
                    context.close(promise: nil)
                }
            }
        case is ChannelFailureEvent:
            if let next = pendingReplies.popFirst() {
                onSuccess.removeValue(forKey: next.kind)
                next.promise.fail(SSHChannelError.requestRejected(next.kind))
            }
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = .exited(status.exitStatus)
            deliverExitStatus(exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitStatus = .signaled(SSHExitSignal(
                name: signal.signalName, coreDumped: signal.dumpedCore, message: signal.errorMessage))
            deliverExitStatus(exitStatus)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SSHChannelError.channelClosed)
        deliverExitStatus(nil)
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
/// 背压：序列里攒够 `highWatermark` 块就不再向子通道要数据（拦下 `read()`），NIOSSH 收不到读请求就不再
/// 把数据交上来；对端在窗口（包长 × 64）用完后停下。NIOSSH 在数据交给 pipeline 时就补发窗口，一次 `read()`
/// 会把它缓冲的整窗一起交上来，所以一个读得慢的消费者最多压住约 2 个窗口（见 `Configuration.maximumPacketSize`）。
///
/// 消费者跑掉（任务取消、提前退出循环、句柄被释放）时先 signal TERM 再关通道。没有消费者而有人等退出状态时
/// （`SSHSessionHandle.exitStatus()`），切到丢弃模式：照常读、直接丢掉，远端不会因窗口满而卡住。
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

    private let lifecycle: SSHConnectionLifecycle
    private var source: Producer.Source?
    private var context: ChannelHandlerContext?
    private var paused = false
    private var readPending = false
    private var finished = false
    private var discarding = false
    private var error: (any Error)?

    init(lifecycle: SSHConnectionLifecycle) {
        self.lifecycle = lifecycle
    }

    /// 建好序列（在通道的 EventLoop 上）。序列只交给一个消费者。
    static func make(eventLoop: any EventLoop, lifecycle: SSHConnectionLifecycle) -> (SSHSessionOutputHandler, Producer) {
        let handler = SSHSessionOutputHandler(lifecycle: lifecycle)
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
        guard !discarding, case .byteBuffer(let buffer) = message.data, let source else { return }
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

    /// 没有人读输出、却有人在等退出状态：之后到的数据直接丢掉，不再施加背压。
    func discardOutput() {
        discarding = true
        resumeReading()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        guard let source else { return }
        self.source = nil
        guard let error else {
            // 正常关闭（含对端先关）。
            source.finish()
            return
        }
        guard let sshError = error as? NIOSSHError, sshError.type == .tcpShutdown else {
            // 只有这一条通道出了问题，连接本身没事。
            source.finish(SSHChannelError.channelFailed(error))
            return
        }
        // 整条连接没了。子通道先于连接的 closeFuture 回调被拆掉，原因此刻可能还没定下来：
        // 本端在关就是 .localClose，否则等连接把原因定下来（对端正常关闭是 .remoteClosed）。
        if let reason = lifecycle.disconnectReason {
            source.finish(SSHChannelError.connectionClosed(reason))
        } else if lifecycle.localCloseRequested {
            source.finish(SSHChannelError.connectionClosed(.localClose))
        } else {
            _ = lifecycle.addObserver { reason in
                source.finish(SSHChannelError.connectionClosed(reason))
            }
        }
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
        guard !finished, !discarding, let context else { return }
        // 消费者跑掉（任务取消、提前退出、句柄释放）= 不要这个进程了：先 signal TERM 再关通道，
        // 理由见 `SSHSessionHandle.terminate`。两步在同一个 tick 里按顺序写出。
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SignalRequest(signal: "TERM"), promise: nil)
        context.close(promise: nil)
    }
}
