import NIOConcurrencyHelpers
import NIOCore

/// SFTP 客户端挂在通道上的那一节：按请求号多路复用在途请求。
///
/// 全部状态只在通道的 EventLoop 上读写（NIO 的 handler 语义），所以没有锁：
/// - 发请求：调用方在自己的任务里取号、建 promise，`eventLoop.execute` 进来调 `enqueue`；
/// - 收回答：`channelRead` 按请求号找到 promise 完成它，回答可以乱序；
/// - 冲刷：同一轮里进来的请求攒进同一块缓冲，排一次 `flush`（不是每个请求冲一次）；
/// - 背压：通道不可写时请求先排在 `backlog`，等 `channelWritabilityChanged` 再写，
///   不把大批 WRITE 一股脑压进下游的缓冲；
/// - 关闭 / 出错：在途与排队的请求全部以 `SFTPError` 失败。
///
/// 取消由调用方处理（见 `SFTPClient.perform`）：先让 promise 以 `CancellationError` 失败，
/// 再进来 `forget` 掉这条记录；迟到的回答找不到记录就丢掉。被取消的 OPEN / OPENDIR 若迟到地拿到了句柄，
/// 这里替调用方把句柄关掉，免得在服务端漏开着。
final class SFTPClientChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    struct Handshake: Sendable {
        var version: UInt32
        var extensions: [SFTPWireExtension]
    }

    private enum State {
        case initial
        case awaitingVersion(EventLoopPromise<Handshake>)
        case ready
        case closed(SFTPError)
    }

    private struct Pending {
        var promise: EventLoopPromise<SFTPResponse>
        var opensHandle: Bool
    }

    /// 攒批的缓冲超过这么大就先写出去，免得一轮里请求太多时一块缓冲无限长。
    private static let batchFlushThreshold = 64 * 1024

    private var state = State.initial
    private var context: ChannelHandlerContext?
    private var pending: [UInt32: Pending] = [:]
    /// 已取消、但服务端可能还会回句柄的 OPEN / OPENDIR。
    private var abandonedOpens: Set<UInt32> = []
    /// 通道不可写时排队的请求（还没编码）。
    private var backlog = CircularBuffer<SFTPRequest>()
    /// 本轮攒起来、还没写进通道的小报文。
    private var batch: ByteBuffer?
    private var flushScheduled = false
    private let requestIDs: NIOLockedValueBox<UInt32>

    init(requestIDs: NIOLockedValueBox<UInt32>) {
        self.requestIDs = requestIDs
    }

    // MARK: 生命周期

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failAll(.connectionClosed)
        self.context = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(.connectionClosed)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // 对端关了子系统的输出：之后不会再有回答，等下去只会挂死。
        if let event = event as? ChannelEvent, event == .inputClosed {
            failAll(.connectionClosed)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let mapped: SFTPError
        switch error {
        case let error as SFTPWireError: mapped = .invalidResponse(error.description)
        case let error as ByteToMessageDecoderError: mapped = .invalidResponse("\(error)")
        case let error as SFTPError: mapped = error
        default: mapped = .connectionClosed
        }
        failAll(mapped)
        context.close(promise: nil)
    }

    // MARK: 握手

    func beginHandshake(promise: EventLoopPromise<Handshake>) {
        guard case .initial = state, let context, context.channel.isActive else {
            promise.fail(SFTPError.connectionClosed)
            return
        }
        state = .awaitingVersion(promise)
        var buffer = context.channel.allocator.buffer(capacity: 16)
        SFTPRequest.initialize(version: 3, extensions: []).encode(into: &buffer)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    // MARK: 发请求

    func enqueue(_ request: SFTPRequest, promise: EventLoopPromise<SFTPResponse>) {
        guard case .ready = state, let context, let id = request.requestID else {
            if case .closed(let error) = state {
                promise.fail(error)
            } else {
                promise.fail(SFTPError.connectionClosed)
            }
            return
        }
        pending[id] = Pending(promise: promise, opensHandle: request.opensHandle)
        if backlog.isEmpty && context.channel.isWritable {
            emit(request, context: context)
            scheduleFlush(context: context)
        } else {
            backlog.append(request)
            if context.channel.isWritable { drainBacklog(context: context) }
        }
    }

    /// 调用方的任务被取消了：撤掉记录。请求若还排在 backlog 里，之后出队时直接跳过、不发。
    func forget(_ id: UInt32) {
        if let entry = pending.removeValue(forKey: id), entry.opensHandle {
            abandonedOpens.insert(id)
        }
    }

    private func emit(_ request: SFTPRequest, context: ChannelHandlerContext) {
        if batch == nil {
            batch = context.channel.allocator.buffer(capacity: 512)
        }
        if let trailing = request.encodeHeader(into: &batch!) {
            // WRITE：头部随本批写出，数据切片原样跟在后面，不拷贝。
            writeBatch(context: context)
            context.write(wrapOutboundOut(trailing), promise: nil)
        } else if batch!.readableBytes >= Self.batchFlushThreshold {
            writeBatch(context: context)
        }
    }

    private func writeBatch(context: ChannelHandlerContext) {
        if let buffer = batch {
            batch = nil
            context.write(wrapOutboundOut(buffer), promise: nil)
        }
    }

    private func scheduleFlush(context: ChannelHandlerContext) {
        guard !flushScheduled else { return }
        flushScheduled = true
        // 排在已经进了任务队列的那些 `enqueue` 之后执行：同一阵并发发来的请求一起冲刷。
        context.eventLoop.assumeIsolated().execute {
            self.flushNow()
        }
    }

    private func flushNow() {
        flushScheduled = false
        guard let context else { return }
        writeBatch(context: context)
        context.flush()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            drainBacklog(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    private func drainBacklog(context: ChannelHandlerContext) {
        var wrote = false
        while context.channel.isWritable, let request = backlog.popFirst() {
            guard let id = request.requestID, pending[id] != nil else {
                // 排队期间就被取消了：不发；它要是 OPEN，也就不会有句柄要替调用方关。
                if let id = request.requestID { abandonedOpens.remove(id) }
                continue
            }
            emit(request, context: context)
            wrote = true
        }
        if wrote {
            writeBatch(context: context)
            context.flush()
        }
    }

    // MARK: 收回答

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let response: SFTPResponse
        do {
            response = try SFTPResponse.decode(frame: frame)
        } catch {
            errorCaught(context: context, error: error)
            return
        }
        switch state {
        case .awaitingVersion(let promise):
            guard case .version(let version, let extensions) = response else {
                errorCaught(context: context, error: SFTPError.invalidResponse("expected SSH_FXP_VERSION, got \(response.packetType)"))
                return
            }
            state = .ready
            promise.succeed(Handshake(version: version, extensions: extensions))
        case .ready:
            guard let id = response.requestID else {
                errorCaught(context: context, error: SFTPError.invalidResponse("unexpected SSH_FXP_VERSION"))
                return
            }
            if let entry = pending.removeValue(forKey: id) {
                entry.promise.succeed(response)
            } else if abandonedOpens.remove(id) != nil, case .handle(_, let handle) = response {
                closeAbandonedHandle(handle, context: context)
            }
            // 其余：已取消请求的迟到回答，丢弃。
        case .initial, .closed:
            break
        }
    }

    private func closeAbandonedHandle(_ handle: ByteBuffer, context: ChannelHandlerContext) {
        let id = requestIDs.withLockedValue { next in
            defer { next &+= 1 }
            return next
        }
        // 结果没人等；仍登记一条记录，关闭时它跟着一起失败，promise 不会悬空。
        enqueue(.close(id: id, handle: handle), promise: context.eventLoop.makePromise())
    }

    // MARK: 收尾

    private func failAll(_ error: SFTPError) {
        let previous = state
        if case .closed = previous { return }
        state = .closed(error)
        if case .awaitingVersion(let promise) = previous {
            promise.fail(error)
        }
        let entries = pending
        pending = [:]
        abandonedOpens = []
        backlog.removeAll()
        batch = nil
        for entry in entries.values {
            entry.promise.fail(error)
        }
    }
}

extension SFTPRequest {
    /// 成功时服务端会回一个要关的句柄。
    var opensHandle: Bool {
        switch self {
        case .open, .opendir: return true
        default: return false
        }
    }
}
