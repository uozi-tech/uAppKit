import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// session 通道上的一块输出。
public enum SSHChannelOutputChunk: Sendable, Hashable {
    /// 通道数据（RFC 4254 §5.2 的 CHANNEL_DATA）。PTY 下 stdout 与 stderr 都在这里。
    case stdout(ByteBuffer)
    /// 扩展数据 type 1（SSH_EXTENDED_DATA_STDERR）。
    case stderr(ByteBuffer)

    public var buffer: ByteBuffer {
        switch self {
        case .stdout(let buffer), .stderr(let buffer): return buffer
        }
    }
}

/// 远端进程怎么结束的（RFC 4254 §6.10）。
public enum SSHExitStatus: Sendable, Hashable {
    /// exit-status。
    case exited(Int)
    /// exit-signal。
    case signaled(SSHExitSignal)
    /// 通道关了，对端两样都没报（OpenSSH 在会话被强行关闭时会这样）。
    case unknown

    /// 正常结束且状态为 0。
    public var isSuccess: Bool { self == .exited(0) }
}

/// exit-signal 的内容。
public struct SSHExitSignal: Sendable, Hashable {
    /// 不带 "SIG" 前缀的信号名（"TERM"、"KILL"……）。
    public var name: String
    public var coreDumped: Bool
    public var message: String

    public init(name: String, coreDumped: Bool, message: String) {
        self.name = name
        self.coreDumped = coreDumped
        self.message = message
    }
}

/// 伪终端请求（RFC 4254 §6.2）。
public struct SSHPseudoTerminal: Sendable, Hashable {
    /// TERM 环境变量。
    public var term: String
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 终端模式（RFC 4254 §8）。空表示用服务器默认。
    public var modes: SSHTerminalModes

    public init(term: String = "xterm-256color", columns: Int = 80, rows: Int = 24,
                pixelWidth: Int = 0, pixelHeight: Int = 0, modes: SSHTerminalModes = SSHTerminalModes([:])) {
        self.term = term
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.modes = modes
    }
}

/// session 通道的输出序列，带背压（见 `SSHSessionHandle.output`）。只能有一个消费者（只能 `makeAsyncIterator` 一次）。
///
/// 正常结束 = 通道关闭（对端发 EOF 不会结束它，退出状态通常在 EOF 之后才到）；整条连接断掉时抛
/// `SSHChannelError.connectionClosed`。消费者提前退出（break、任务取消）会关掉通道。
public struct SSHChannelOutput: AsyncSequence, Sendable {
    public typealias Element = SSHChannelOutputChunk

    let producer: SSHSessionOutputHandler.Producer
    /// 有没有人拿走过迭代器（或被 `exitStatus()` 认领去丢弃）。
    let claim: NIOLockedValueBox<Bool>

    init(producer: SSHSessionOutputHandler.Producer) {
        self.producer = producer
        self.claim = NIOLockedValueBox(false)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: SSHSessionOutputHandler.Producer.AsyncIterator

        public mutating func next() async throws -> SSHChannelOutputChunk? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        claim.withLockedValue { $0 = true }
        return AsyncIterator(base: producer.makeAsyncIterator())
    }

    /// 还没人读的话认领下来（返回 true），之后的输出交给 `exitStatus()` 丢弃。
    func claimForDiscard() -> Bool {
        claim.withLockedValue { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// 一条 exec / shell 通道。`Sendable`，可以同时在一个任务里读输出、在另一个任务里写。
///
/// 句柄被释放（且没有正在读输出的迭代器）时通道会被关闭；不想依赖这一点就显式 `close()`。
public final class SSHSessionHandle: Sendable {
    /// 底层的 NIO 子通道。
    public let channel: any Channel
    /// 输出（stdout / stderr），见 `SSHChannelOutput`。
    public let output: SSHChannelOutput

    let requests: NIOLoopBound<SSHChannelRequestHandler>
    let outputHandler: NIOLoopBound<SSHSessionOutputHandler>
    let client: SSHClient
    /// 通道关了：对端回了 CHANNEL_CLOSE / 连接断了，或者本端 `close()` 等过了宽限、在本端收了尾。
    private let closed = SSHCloseSignal()

    init(channel: any Channel, output: SSHChannelOutput, requests: NIOLoopBound<SSHChannelRequestHandler>,
         outputHandler: NIOLoopBound<SSHSessionOutputHandler>, client: SSHClient) {
        self.channel = channel
        self.output = output
        self.requests = requests
        self.outputHandler = outputHandler
        self.client = client
        let closed = self.closed
        channel.closeFuture.whenComplete { _ in closed.markClosed() }
    }

    /// 写到远端的标准输入。返回时数据已交给连接（对端窗口满时会等）。任务被取消时立刻抛
    /// `CancellationError`（数据可能已经排进去了）。
    public func write(_ buffer: ByteBuffer) async throws {
        guard !closed.isClosed else { throw SSHChannelError.channelClosed }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: promise)
        try await awaitWrite(promise.futureResult)
    }

    /// 写字节。
    public func write(_ bytes: some Sequence<UInt8>) async throws {
        try await write(channel.allocator.buffer(bytes: bytes))
    }

    /// 发 EOF（关掉远端的标准输入）。之后不能再写。对端先发过 EOF 也没关系（RFC 4254 §5.3）。
    public func sendEOF() async throws {
        guard !closed.isClosed else { throw SSHChannelError.channelClosed }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.close(mode: .output, promise: promise)
        try await awaitWrite(promise.futureResult)
    }

    /// 改终端尺寸（window-change，RFC 4254 §6.7，不要回应）。
    public func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: pixelWidth, terminalPixelHeight: pixelHeight)
        try await sendRequest(event, kind: .windowChange, wantReply: false)
    }

    /// 给远端进程发信号（RFC 4254 §6.9，信号名不带 "SIG"）。OpenSSH 7.9 起支持。
    public func signal(_ name: String) async throws {
        try await sendRequest(SSHChannelRequestEvent.SignalRequest(signal: name), kind: .signal(name), wantReply: false)
    }

    /// 等通道关闭，返回远端进程的结束方式。任务被取消时不再等，按当时已知的返回（多半是 `.unknown`）。
    ///
    /// 还没有人读 `output` 时，这里把它认领下来并**丢弃之后的输出**——否则输出超过一个窗口的命令会因为
    /// 没人读而永远停在那里，退出状态也就永远等不到。要输出就先开始读（`for try await` / `makeAsyncIterator`），
    /// 再在另一个任务里或读完之后调这里。
    public func exitStatus() async -> SSHExitStatus {
        if output.claimForDiscard() {
            let outputHandler = self.outputHandler
            channel.eventLoop.execute { outputHandler.value.discardOutput() }
        }
        await closed.wait()
        let requests = self.requests
        return (try? await channel.eventLoop.submit { requests.value.exitStatus ?? .unknown }.get()) ?? .unknown
    }

    /// 等远端进程**报告**结束（exit-status / exit-signal 到达），不等通道关闭；不认领、不丢弃输出。
    /// 通道关了也没等到时返回 nil；任务被取消时立刻返回 nil。
    ///
    /// 和 `exitStatus()` 的区别：远端 shell 退出了、但后台进程还占着伪终端（`sleep 1000 &` 再 `exit`）时，sshd 先发
    /// exit-status，通道要等那个进程结束才关——`exitStatus()` 会一直等，这里立刻返回，调用方可以自己决定再给输出
    /// 一点时间、然后关通道（OpenSSH 的 `ssh` 这时也会卡住，这是给 app 选的另一条路）。
    public func exitStatusReported() async -> SSHExitStatus? {
        let requests = self.requests
        let arrival = channel.eventLoop.flatSubmit { requests.value.exitStatusArrival.futureResult }
        return (try? await arrival.getCancellable(lateValue: { _ in })) ?? nil
    }

    /// 关闭通道。幂等。正常情况下返回时通道已关闭（对端回了 CHANNEL_CLOSE）；传输半死、对端迟迟不回时
    /// 最多等 `gracePeriod`（默认 `SSHClient.closeGracePeriod`）就在本端收尾：输出序列结束、`exitStatus()` 返回
    /// （多半是 `.unknown`）、等回应的请求以 `channelClosed` 失败、之后的写入立刻失败、`isActive` 为 false。
    /// 留下的 NIOSSH 子通道随连接断开时一起拆掉。
    public func close(gracePeriod: Duration = SSHClient.closeGracePeriod) async {
        channel.close(promise: nil)
        guard await !channel.closeFuture.completes(within: gracePeriod) else { return }
        let requests = self.requests
        let outputHandler = self.outputHandler
        channel.eventLoop.execute {
            requests.value.closeLocally()
            outputHandler.value.closeLocally()
        }
        closed.markClosed()
    }

    /// 通道是否还开着（本端关过、等过了宽限的也算关了）。
    public var isActive: Bool { channel.isActive && !closed.isClosed }

    func sendRequest(_ event: any Sendable, kind: SSHChannelRequestKind, wantReply: Bool) async throws {
        guard !closed.isClosed else { throw SSHChannelError.channelClosed }
        let requests = self.requests
        let future = channel.eventLoop.flatSubmit {
            requests.value.send(event, kind: kind, wantReply: wantReply)
        }
        try await awaitWrite(future)
    }

    private func awaitWrite(_ future: EventLoopFuture<Void>) async throws {
        do {
            try await future.getCancellable { _ in }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SSHChannelError {
            throw error
        } catch {
            throw await mapWriteError(error)
        }
    }

    private func mapWriteError(_ error: any Error) async -> any Error {
        if let error = error as? NIOSSHError, error.type == .tcpShutdown {
            return SSHChannelError.connectionClosed(await client.connectionClosedReason(error))
        }
        if let error = error as? ChannelError {
            switch error {
            case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed:
                if client.lifecycle.disconnectReason != nil || !client.transport.isActive
                    || client.lifecycle.localCloseRequested {
                    return SSHChannelError.connectionClosed(await client.connectionClosedReason(error))
                }
                return SSHChannelError.channelClosed
            default:
                break
            }
        }
        // 通道已经（被本端或对端）关掉了还在用它：NIOSSH 报的是状态机的协议错误，对调用方就是「通道已关」。
        if !channel.isActive { return SSHChannelError.channelClosed }
        return SSHChannelError.channelFailed(error)
    }
}

/// `openExec` / `openShell` 的句柄。两者是同一个类型：exec 带了 PTY 也能 `resize`。
public typealias SSHExecHandle = SSHSessionHandle
public typealias SSHShellHandle = SSHSessionHandle
