import NIOConcurrencyHelpers
import NIOCore

/// SFTP 客户端挂在通道上的那一节：按请求号多路复用在途请求。
///
/// 全部状态只在通道的 EventLoop 上读写（NIO 的 handler 语义），所以没有锁：
/// - 发请求：调用方在自己的任务里取号、建 promise，`eventLoop.execute` 进来调 `enqueue`；
///   号已经被一个还在途的请求占着（32 位请求号绕回一圈）时换一个空号，见 `remapped`；
/// - 收回答：`channelRead` 按请求号找到 promise 完成它，回答可以乱序；
/// - 冲刷：同一轮里进来的请求攒进同一块缓冲，排一次 `flush`（不是每个请求冲一次）；
/// - 背压：通道不可写时请求先排在 `backlog`，等 `channelWritabilityChanged` 再写，
///   不把大批 WRITE 一股脑压进下游的缓冲；
/// - 关闭 / 出错 / 写失败：在途与排队的请求全部以 `SFTPError` 失败。
///
/// 取消：调用方的取消处理只排一个任务进来调 `abandon`，在**同一个** EventLoop 任务里撤掉记录、
/// 让 promise 失败。于是同一个请求的回答要么在它之前到（调用方照常拿到结果），要么在它之后到
/// （找不到记录，丢掉）；不会有「promise 已经失败、回答把记录拿走、句柄没人关」的夹缝。
/// 被撤掉的 OPEN / OPENDIR 迟到地拿到了句柄时，这里替调用方把句柄关掉；还排在 backlog 里没发出去的
/// 直接不发。`abandon` 总在对应的 `enqueue` 之后执行：两者都是调用方按先后顺序交给同一个 EventLoop 的任务。
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
        /// 调用方取到的号（和线上的号不同时，`remapped` 里有一条从它指过来的记录）。
        var callerID: UInt32
    }

    /// 攒批的缓冲超过这么大就先写出去，免得一轮里请求太多时一块缓冲无限长。
    private static let batchFlushThreshold = 64 * 1024

    private var state = State.initial
    private var context: ChannelHandlerContext?
    /// 线上的请求号 → 在途请求。
    private var pending: [UInt32: Pending] = [:]
    /// 调用方取到的号撞上了还在途的请求、换了一个号发出去：调用方的号 → 线上的号。
    private var remapped: [UInt32: UInt32] = [:]
    /// 已撤掉、但服务端可能还会回句柄的 OPEN / OPENDIR（线上的号）。
    private var abandonedOpens: Set<UInt32> = []
    /// 通道不可写时排队的请求（还没编码，号已经是线上的号）。
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
        write(buffer, context: context)
        context.flush()
    }

    // MARK: 发请求

    func enqueue(_ request: SFTPRequest, promise: EventLoopPromise<SFTPResponse>) {
        guard case .ready = state, let context, let callerID = request.requestID else {
            if case .closed(let error) = state {
                promise.fail(error)
            } else {
                promise.fail(SFTPError.connectionClosed)
            }
            return
        }
        var request = request
        var wireID = callerID
        if isOccupied(wireID) {
            // 32 位请求号绕回来撞上了一个还没回答的请求：换一个空号，绝不覆盖它的记录。
            repeat {
                wireID = requestIDs.withLockedValue { next in
                    defer { next &+= 1 }
                    return next
                }
            } while isOccupied(wireID)
            request = request.replacingRequestID(wireID)
            remapped[callerID] = wireID
        }
        pending[wireID] = Pending(promise: promise, opensHandle: request.opensHandle, callerID: callerID)
        if backlog.isEmpty && context.channel.isWritable {
            emit(request, context: context)
            scheduleFlush(context: context)
        } else {
            backlog.append(request)
            if context.channel.isWritable { drainBacklog(context: context) }
        }
    }

    private func isOccupied(_ id: UInt32) -> Bool {
        pending[id] != nil || abandonedOpens.contains(id)
    }

    /// 调用方不再等这个请求了（任务被取消、批量读写里别的请求已经失败）：撤掉记录、让 promise 失败。
    /// 请求若还排在 backlog 里，之后出队时直接跳过、不发。
    func abandon(_ callerID: UInt32, promise: EventLoopPromise<SFTPResponse>) {
        var wireID = callerID
        if let mapped = remapped[callerID], pending[mapped]?.promise == promise {
            wireID = mapped
        }
        if let entry = pending[wireID], entry.promise == promise {
            removePending(wireID)
            if entry.opensHandle { abandonedOpens.insert(wireID) }
        }
        // 回答已经先到了（promise 已完成）时这一句什么都不做。
        promise.fail(CancellationError())
    }

    @discardableResult
    private func removePending(_ wireID: UInt32) -> Pending? {
        guard let entry = pending.removeValue(forKey: wireID) else { return nil }
        if entry.callerID != wireID { remapped[entry.callerID] = nil }
        return entry
    }

    private func emit(_ request: SFTPRequest, context: ChannelHandlerContext) {
        if batch == nil {
            batch = context.channel.allocator.buffer(capacity: 512)
        }
        if let trailing = request.encodeHeader(into: &batch!) {
            // WRITE：头部随本批写出，数据切片原样跟在后面，不拷贝。
            writeBatch(context: context)
            write(trailing, context: context)
        } else if batch!.readableBytes >= Self.batchFlushThreshold {
            writeBatch(context: context)
        }
    }

    private func writeBatch(context: ChannelHandlerContext) {
        if let buffer = batch {
            batch = nil
            write(buffer, context: context)
        }
    }

    /// 写进通道并盯着结果：任何一次写失败，字节流就不完整了（半个报文），全部请求失败、关通道。
    /// 不能写了 `promise: nil` 了事——写失败而通道没变成 inactive 时，请求会永远挂着。
    private func write(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.assumeIsolated().whenFailure { [weak self] _ in
            self?.writeFailed()
        }
        context.write(wrapOutboundOut(buffer), promise: promise)
    }

    private func writeFailed() {
        failAll(.connectionClosed)
        context?.close(promise: nil)
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
                // 排队期间就被撤掉了：不发；它要是 OPEN，也就不会有句柄要替调用方关。
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
            if let entry = removePending(id) {
                entry.promise.succeed(response)
            } else if abandonedOpens.remove(id) != nil, case .handle(_, let handle) = response {
                closeAbandonedHandle(handle, context: context)
            }
            // 其余：已撤掉请求的迟到回答，丢弃。
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
        remapped = [:]
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

    /// 换一个请求号（INIT 没有请求号，原样返回）。
    func replacingRequestID(_ id: UInt32) -> SFTPRequest {
        switch self {
        case .initialize: return self
        case .open(_, let path, let flags, let attributes): return .open(id: id, path: path, flags: flags, attributes: attributes)
        case .close(_, let handle): return .close(id: id, handle: handle)
        case .read(_, let handle, let offset, let length): return .read(id: id, handle: handle, offset: offset, length: length)
        case .write(_, let handle, let offset, let data): return .write(id: id, handle: handle, offset: offset, data: data)
        case .lstat(_, let path): return .lstat(id: id, path: path)
        case .fstat(_, let handle): return .fstat(id: id, handle: handle)
        case .setstat(_, let path, let attributes): return .setstat(id: id, path: path, attributes: attributes)
        case .fsetstat(_, let handle, let attributes): return .fsetstat(id: id, handle: handle, attributes: attributes)
        case .opendir(_, let path): return .opendir(id: id, path: path)
        case .readdir(_, let handle): return .readdir(id: id, handle: handle)
        case .remove(_, let path): return .remove(id: id, path: path)
        case .mkdir(_, let path, let attributes): return .mkdir(id: id, path: path, attributes: attributes)
        case .rmdir(_, let path): return .rmdir(id: id, path: path)
        case .realpath(_, let path): return .realpath(id: id, path: path)
        case .stat(_, let path): return .stat(id: id, path: path)
        case .rename(_, let oldPath, let newPath): return .rename(id: id, oldPath: oldPath, newPath: newPath)
        case .readlink(_, let path): return .readlink(id: id, path: path)
        case .symlink(_, let linkPath, let targetPath): return .symlink(id: id, linkPath: linkPath, targetPath: targetPath)
        case .extended(_, let request): return .extended(id: id, request: request)
        }
    }
}
