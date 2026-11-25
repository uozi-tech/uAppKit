#if USSH_TEST_SERVER
import NIOConcurrencyHelpers
import NIOCore
import USSHCore

/// 测试用的 SFTP v3 服务端，挂在一条以 `ByteBuffer` 收发字节流的通道上（与 `SFTPClient` 的对接约定相同：
/// 可以是 SSH 的 `sftp` 子系统通道，也可以直接是一条本机 TCP 连接或管道）。
///
/// 行为照 OpenSSH 的 sftp-server：SYMLINK 的参数顺序、RENAME 不覆盖、`posix-rename` 覆盖、扩展的格式、
/// 句柄编号复用（最近释放的先用，所以「关了以后迟到的请求落进新开的文件」这种客户端错误在这里也测得出来）。
/// 同一个句柄上的操作按到达顺序串行执行（CLOSE 等它前面的做完），不同句柄、不带句柄的操作并发执行，
/// 所以不同请求的回答可以乱序；要让同一个句柄上的回答也乱序，用 `faults` 的延迟或 `reverseResponseOrder`。
/// `faults` 还能注入失败、短读、断线、不回答。
public final class SFTPServer: Sendable {
    public struct Configuration: Sendable {
        /// SSH_FXP_VERSION 里宣告的扩展（名字 → 数据）。不在这里的扩展请求回 OP_UNSUPPORTED。
        public var extensions: [String: String]
        /// `limits@openssh.com` 的回答；READ 也按其中的 `maximumReadLength` 截短（0 = 不限）。
        public var limits: SFTPServerLimits
        /// 收到的单帧最大长度；超过就关通道。
        public var maximumPacketLength: Int

        public init(
            extensions: [String: String] = SFTPServer.defaultExtensions,
            limits: SFTPServerLimits = SFTPServer.defaultLimits,
            maximumPacketLength: Int = 256 * 1024
        ) {
            self.extensions = extensions
            self.limits = limits
            self.maximumPacketLength = maximumPacketLength
        }
    }

    /// 和 OpenSSH 宣告的版本号一致。
    public static let defaultExtensions: [String: String] = [
        SFTPExtensionName.posixRename: "1",
        SFTPExtensionName.statVFS: "2",
        SFTPExtensionName.fstatVFS: "2",
        SFTPExtensionName.hardLink: "1",
        SFTPExtensionName.fsync: "1",
        SFTPExtensionName.lsetstat: "1",
        SFTPExtensionName.limits: "1",
    ]

    /// 和 OpenSSH 的 sftp-server 一样：包长 256 KiB，读写各 255 KiB。
    public static let defaultLimits = SFTPServerLimits(
        maximumPacketLength: 256 * 1024, maximumReadLength: 255 * 1024,
        maximumWriteLength: 255 * 1024, maximumOpenHandles: 0)

    public let channel: Channel
    public let fileSystem: any SFTPServerFileSystem
    public let faults: SFTPFaultInjector

    private init(channel: Channel, fileSystem: any SFTPServerFileSystem, faults: SFTPFaultInjector) {
        self.channel = channel
        self.fileSystem = fileSystem
        self.faults = faults
    }

    /// 在 `channel` 的 pipeline 末尾装上服务端。必须在 `channel.eventLoop` 上调用
    /// （适合放进 `ServerBootstrap.childChannelInitializer`）。
    public static func install(
        on channel: Channel,
        fileSystem: any SFTPServerFileSystem,
        configuration: Configuration = Configuration(),
        faults: SFTPFaultInjector = SFTPFaultInjector()
    ) throws -> SFTPServer {
        channel.eventLoop.preconditionInEventLoop()
        let handler = SFTPServerChannelHandler(fileSystem: fileSystem, configuration: configuration, faults: faults)
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(SFTPFrameDecoder(maximumFrameLength: configuration.maximumPacketLength)),
            handler,
        ])
        return SFTPServer(channel: channel, fileSystem: fileSystem, faults: faults)
    }

    /// 同 `install`，可以在任意线程调用。
    public static func start(
        on channel: Channel,
        fileSystem: any SFTPServerFileSystem,
        configuration: Configuration = Configuration(),
        faults: SFTPFaultInjector = SFTPFaultInjector()
    ) async throws -> SFTPServer {
        try await channel.eventLoop.submit {
            try install(on: channel, fileSystem: fileSystem, configuration: configuration, faults: faults)
        }.get()
    }

    public func close() async {
        channel.close(promise: nil)
        try? await channel.closeFuture.get()
    }
}

// MARK: - handler

final class SFTPServerChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum OpenHandle {
        case file(any SFTPServerFile)
        case directory(any SFTPServerDirectory)
    }

    /// 文件系统任务的结果，回到 EventLoop 上再变成回答（开句柄要在这里登记）。
    private enum Outcome: Sendable {
        case response(SFTPResponse)
        case openedFile(any SFTPServerFile)
        case openedDirectory(any SFTPServerDirectory)
    }

    private let fileSystem: any SFTPServerFileSystem
    private let configuration: SFTPServer.Configuration
    private let faults: SFTPFaultInjector
    private var context: ChannelHandlerContext?
    private var initialized = false
    /// 一个开着的句柄。同一个句柄上的操作**按到达顺序一个一个执行**（和 OpenSSH 一样），
    /// 不同句柄之间、以及不带句柄的操作照常并发。CLOSE 排在它前面的操作之后，关完才释放编号。
    private struct Slot {
        var handle: OpenHandle
        var busy = false
        /// CLOSE 已经排上了：之后到的请求按「句柄无效」回。
        var closing = false
        var waiting = CircularBuffer<HandleJob>()
    }

    private struct HandleJob {
        var id: UInt32
        var decision: SFTPFaultInjector.Decision
        var isClose: Bool
        /// nil = 只关不回答（连接没了之后的清理）。
        var replies: Bool
        var body: @Sendable (OpenHandle) async throws -> Outcome
    }

    private var slots: [UInt32: Slot] = [:]
    /// 照 OpenSSH 复用编号：最近释放的先用，没有空位才往后加（编号从 0 起）。
    private var freeNumbers: [UInt32] = []
    private var nextNumber: UInt32 = 0
    private var reorderBuffer: [SFTPResponse] = []
    private var flushScheduled = false
    private var active = true

    init(fileSystem: any SFTPServerFileSystem, configuration: SFTPServer.Configuration, faults: SFTPFaultInjector) {
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.faults = faults
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        shutDown()
        self.context = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        shutDown()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // 帧坏了（超长、空帧、截断在流尾）：字节流对不齐了，只能断开。
        context.close(promise: nil)
    }

    /// 连接没了：客户端没来得及关的句柄排在各自已有的操作之后关掉。
    private func shutDown() {
        guard active else { return }
        active = false
        reorderBuffer = []
        for number in slots.keys where slots[number]?.closing == false {
            enqueue(on: number, HandleJob(id: 0, decision: .init(), isClose: true, replies: false) { open in
                try await Self.close(open)
                return .response(.status(id: 0, code: .ok, message: "", languageTag: ""))
            })
        }
    }

    private static func close(_ open: OpenHandle) async throws {
        switch open {
        case .file(let file): try await file.close()
        case .directory(let directory): try await directory.close()
        }
    }

    // MARK: 收请求

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request: SFTPRequest
        do {
            request = try SFTPRequest.decode(frame: unwrapInboundIn(data))
        } catch SFTPWireError.unknownPacketType(_, let id?) where initialized {
            send(.status(id: id, code: .operationUnsupported, message: "Unsupported request", languageTag: ""))
            return
        } catch {
            context.close(promise: nil)
            return
        }

        if case .initialize = request {
            guard !initialized else {
                context.close(promise: nil)
                return
            }
            initialized = true
            let extensions = configuration.extensions.sorted { $0.key < $1.key }
                .map { SFTPWireExtension(name: $0.key, data: $0.value) }
            send(.version(version: 3, extensions: extensions))
            return
        }
        guard initialized, let id = request.requestID else {
            context.close(promise: nil)
            return
        }

        let decision = faults.decide(for: request.operation)
        if decision.dropConnection {
            context.close(promise: nil)
            return
        }
        if let failure = decision.failure {
            finish(.response(.status(id: id, code: failure.code, message: failure.message, languageTag: "en")),
                   id: id, decision: decision)
            return
        }
        dispatch(request, id: id, decision: decision)
    }

    private func dispatch(_ request: SFTPRequest, id: UInt32, decision: SFTPFaultInjector.Decision) {
        let fs = fileSystem
        switch request {
        case .initialize:
            return
        case .open(_, let path, let flags, let attributes):
            run(id, decision) { .openedFile(try await fs.openFile(path, flags: flags, attributes: attributes)) }
        case .opendir(_, let path):
            run(id, decision) { .openedDirectory(try await fs.openDirectory(path)) }
        case .close(_, let handle):
            onHandle(handle, id: id, decision: decision, isClose: true) { open in
                try await Self.close(open)
                return Self.ok(id)
            }
        case .read(_, let handle, let offset, let length):
            var wanted = Int(length)
            if configuration.limits.maximumReadLength > 0 {
                wanted = min(wanted, Int(clamping: configuration.limits.maximumReadLength))
            }
            if let cap = decision.readLengthCap { wanted = min(wanted, max(1, cap)) }
            onHandle(handle, id: id, decision: decision) { [wanted] open in
                guard let data = try await Self.file(open).read(at: offset, length: wanted) else {
                    return .response(.status(id: id, code: .eof, message: "End of file", languageTag: "en"))
                }
                return .response(.data(id: id, data: data))
            }
        case .write(_, let handle, let offset, let data):
            onHandle(handle, id: id, decision: decision) { open in
                try await Self.file(open).write(data, at: offset)
                return Self.ok(id)
            }
        case .fstat(_, let handle):
            onHandle(handle, id: id, decision: decision) { open in
                .response(.attributes(id: id, attributes: try await Self.file(open).attributes()))
            }
        case .fsetstat(_, let handle, let attributes):
            onHandle(handle, id: id, decision: decision) { open in
                try await Self.file(open).setAttributes(attributes)
                return Self.ok(id)
            }
        case .readdir(_, let handle):
            onHandle(handle, id: id, decision: decision) { open in
                guard case .directory(let directory) = open else { throw Self.invalidHandleError }
                guard let entries = try await directory.nextBatch() else {
                    return .response(.status(id: id, code: .eof, message: "End of file", languageTag: "en"))
                }
                return .response(.name(id: id, entries: entries))
            }
        case .lstat(_, let path):
            run(id, decision) { .response(.attributes(id: id, attributes: try await fs.attributes(at: path, followingSymlinks: false))) }
        case .stat(_, let path):
            run(id, decision) { .response(.attributes(id: id, attributes: try await fs.attributes(at: path, followingSymlinks: true))) }
        case .setstat(_, let path, let attributes):
            run(id, decision) {
                try await fs.setAttributes(attributes, at: path, followingSymlinks: true)
                return Self.ok(id)
            }
        case .remove(_, let path):
            run(id, decision) {
                try await fs.removeFile(path)
                return Self.ok(id)
            }
        case .mkdir(_, let path, let attributes):
            run(id, decision) {
                try await fs.createDirectory(path, attributes: attributes)
                return Self.ok(id)
            }
        case .rmdir(_, let path):
            run(id, decision) {
                try await fs.removeDirectory(path)
                return Self.ok(id)
            }
        case .realpath(_, let path):
            run(id, decision) {
                let resolved = try await fs.realPath(path)
                return .response(.name(id: id, entries: [SFTPDirectoryEntry(name: resolved, longname: resolved.string, attributes: .none)]))
            }
        case .rename(_, let oldPath, let newPath):
            run(id, decision) {
                try await fs.rename(oldPath, to: newPath, replacingExisting: false)
                return Self.ok(id)
            }
        case .readlink(_, let path):
            run(id, decision) {
                let target = try await fs.readLink(path)
                return .response(.name(id: id, entries: [SFTPDirectoryEntry(name: target, longname: target.string, attributes: .none)]))
            }
        case .symlink(_, let linkPath, let targetPath):
            run(id, decision) {
                try await fs.createSymlink(at: linkPath, pointingTo: targetPath)
                return Self.ok(id)
            }
        case .extended(_, let extended):
            dispatchExtended(extended, id: id, decision: decision)
        }
    }

    private func dispatchExtended(_ request: SFTPExtendedRequest, id: UInt32, decision: SFTPFaultInjector.Decision) {
        guard configuration.extensions[request.name] != nil else {
            return finish(.response(.status(id: id, code: .operationUnsupported, message: "Unsupported extension", languageTag: "en")),
                          id: id, decision: decision)
        }
        let fs = fileSystem
        switch request {
        case .posixRename(let oldPath, let newPath):
            run(id, decision) {
                try await fs.rename(oldPath, to: newPath, replacingExisting: true)
                return Self.ok(id)
            }
        case .hardLink(let oldPath, let newPath):
            run(id, decision) {
                try await fs.createHardLink(at: newPath, pointingTo: oldPath)
                return Self.ok(id)
            }
        case .statVFS(let path):
            run(id, decision) {
                var data = ByteBuffer()
                try await fs.fileSystemStats(at: path).encode(into: &data)
                return .response(.extendedReply(id: id, data: data))
            }
        case .fstatVFS(let handle):
            onHandle(handle, id: id, decision: decision) { open in
                var data = ByteBuffer()
                try await Self.file(open).fileSystemStats().encode(into: &data)
                return .response(.extendedReply(id: id, data: data))
            }
        case .fsync(let handle):
            onHandle(handle, id: id, decision: decision) { open in
                try await Self.file(open).sync()
                return Self.ok(id)
            }
        case .lsetstat(let path, let attributes):
            run(id, decision) {
                try await fs.setAttributes(attributes, at: path, followingSymlinks: false)
                return Self.ok(id)
            }
        case .limits:
            var data = ByteBuffer()
            configuration.limits.encode(into: &data)
            finish(.response(.extendedReply(id: id, data: data)), id: id, decision: decision)
        case .other:
            finish(.response(.status(id: id, code: .operationUnsupported, message: "Unsupported extension", languageTag: "en")),
                   id: id, decision: decision)
        }
    }

    // MARK: 执行与回答

    /// 在单独的任务里跑文件系统操作，结果回到 EventLoop 上写回答。
    private func run(_ id: UInt32, _ decision: SFTPFaultInjector.Decision, _ body: @escaping @Sendable () async throws -> Outcome) {
        guard let context else { return }
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        Task {
            let outcome = await Self.outcome(id: id, body)
            eventLoop.execute {
                bound.value.finish(outcome, id: id, decision: decision)
            }
        }
    }

    /// 排进句柄自己的队列。句柄不认识或者已经在关：回「句柄无效」（OpenSSH 回 SSH_FX_FAILURE）。
    private func onHandle(
        _ handle: ByteBuffer, id: UInt32, decision: SFTPFaultInjector.Decision, isClose: Bool = false,
        _ body: @escaping @Sendable (OpenHandle) async throws -> Outcome
    ) {
        guard let number = Self.handleNumber(handle), let slot = slots[number], !slot.closing else {
            return finish(Self.invalidHandle(id), id: id, decision: decision)
        }
        enqueue(on: number, HandleJob(id: id, decision: decision, isClose: isClose, replies: true, body: body))
    }

    private func enqueue(on number: UInt32, _ job: HandleJob) {
        guard slots[number] != nil else { return }
        if job.isClose { slots[number]!.closing = true }
        slots[number]!.waiting.append(job)
        startNext(on: number)
    }

    private func startNext(on number: UInt32) {
        guard let context, var slot = slots[number], !slot.busy, let job = slot.waiting.popFirst() else { return }
        slot.busy = true
        slots[number] = slot
        let handle = slot.handle
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        let body = job.body
        let id = job.id
        Task {
            let outcome = await Self.outcome(id: id) { try await body(handle) }
            eventLoop.execute {
                bound.value.jobFinished(on: number, job, outcome)
            }
        }
    }

    private func jobFinished(on number: UInt32, _ job: HandleJob, _ outcome: Outcome) {
        if job.isClose {
            // 关完才释放编号，下一个 OPEN 才可能拿到它（OpenSSH 的行为）。
            slots[number] = nil
            freeNumbers.append(number)
        } else {
            slots[number]?.busy = false
        }
        if job.replies { finish(outcome, id: job.id, decision: job.decision) }
        startNext(on: number)
    }

    private static func outcome(id: UInt32, _ body: () async throws -> Outcome) async -> Outcome {
        do {
            return try await body()
        } catch let status as SFTPServerStatusError {
            return .response(.status(id: id, code: status.code, message: status.message, languageTag: "en"))
        } catch {
            return .response(.status(id: id, code: .failure, message: String(describing: error), languageTag: "en"))
        }
    }

    private static let invalidHandleError = SFTPServerStatusError.failure("Invalid handle")

    private static func file(_ open: OpenHandle) throws -> any SFTPServerFile {
        guard case .file(let file) = open else { throw invalidHandleError }
        return file
    }

    private func finish(_ outcome: Outcome, id: UInt32, decision: SFTPFaultInjector.Decision) {
        let response: SFTPResponse
        switch outcome {
        case .response(let value):
            response = value
        case .openedFile(let file):
            response = register(.file(file), id: id)
        case .openedDirectory(let directory):
            response = register(.directory(directory), id: id)
        }
        guard !decision.withhold else { return }
        if let delay = decision.delay, let context {
            context.eventLoop.assumeIsolated().scheduleTask(in: TimeAmount.nanoseconds(Self.nanoseconds(delay))) {
                self.send(response)
            }
        } else {
            send(response)
        }
    }

    private func register(_ handle: OpenHandle, id: UInt32) -> SFTPResponse {
        guard active else {
            // 连接已经没了，开出来的东西直接关掉。
            Task {
                switch handle {
                case .file(let file): try? await file.close()
                case .directory(let directory): try? await directory.close()
                }
            }
            return .status(id: id, code: .connectionLost, message: "", languageTag: "")
        }
        let number: UInt32
        if let reused = freeNumbers.popLast() {
            number = reused
        } else {
            number = nextNumber
            nextNumber &+= 1
        }
        slots[number] = Slot(handle: handle)
        var bytes = ByteBuffer()
        bytes.writeInteger(number)
        return .handle(id: id, handle: bytes)
    }

    private func send(_ response: SFTPResponse) {
        guard active, let context else { return }
        if let batch = faults.reverseBatchSize, response.packetType != .version {
            reorderBuffer.append(response)
            guard reorderBuffer.count >= batch else { return }
            let held = reorderBuffer
            reorderBuffer = []
            for item in held.reversed() { write(item, context: context) }
        } else {
            if !reorderBuffer.isEmpty {
                let held = reorderBuffer
                reorderBuffer = []
                for item in held { write(item, context: context) }
            }
            write(response, context: context)
        }
        scheduleFlush(context: context)
    }

    private func write(_ response: SFTPResponse, context: ChannelHandlerContext) {
        var header = context.channel.allocator.buffer(capacity: 64)
        let trailing = response.encodeHeader(into: &header)
        context.write(wrapOutboundOut(header), promise: nil)
        if let trailing {
            context.write(wrapOutboundOut(trailing), promise: nil)
        }
    }

    private func scheduleFlush(context: ChannelHandlerContext) {
        guard !flushScheduled else { return }
        flushScheduled = true
        context.eventLoop.assumeIsolated().execute {
            self.flushScheduled = false
            self.context?.flush()
        }
    }

    // MARK: 小工具

    private static func handleNumber(_ handle: ByteBuffer) -> UInt32? {
        guard handle.readableBytes == 4 else { return nil }
        return handle.getInteger(at: handle.readerIndex, as: UInt32.self)
    }

    private static func ok(_ id: UInt32) -> Outcome {
        .response(.status(id: id, code: .ok, message: "Success", languageTag: "en"))
    }

    private static func invalidHandle(_ id: UInt32) -> Outcome {
        // OpenSSH 对不认识的句柄回 SSH_FX_FAILURE。
        .response(.status(id: id, code: .failure, message: "Invalid handle", languageTag: "en"))
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

extension SFTPRequest {
    var operation: SFTPServerOperation {
        switch self {
        case .initialize: return .realpath // 不会用到：INIT 不经过故障注入。
        case .open: return .open
        case .close: return .close
        case .read: return .read
        case .write: return .write
        case .lstat: return .lstat
        case .fstat: return .fstat
        case .setstat: return .setstat
        case .fsetstat: return .fsetstat
        case .opendir: return .opendir
        case .readdir: return .readdir
        case .remove: return .remove
        case .mkdir: return .mkdir
        case .rmdir: return .rmdir
        case .realpath: return .realpath
        case .stat: return .stat
        case .rename: return .rename
        case .readlink: return .readlink
        case .symlink: return .symlink
        case .extended(_, let request): return .extended(request.name)
        }
    }
}
#endif
