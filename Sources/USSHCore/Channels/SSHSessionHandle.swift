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

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: SSHSessionOutputHandler.Producer.AsyncIterator

        public mutating func next() async throws -> SSHChannelOutputChunk? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: producer.makeAsyncIterator())
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
    let lifecycle: SSHConnectionLifecycle

    init(channel: any Channel, output: SSHChannelOutput, requests: NIOLoopBound<SSHChannelRequestHandler>,
         lifecycle: SSHConnectionLifecycle) {
        self.channel = channel
        self.output = output
        self.requests = requests
        self.lifecycle = lifecycle
    }

    /// 写到远端的标准输入。返回时数据已交给连接（对端窗口满时会等）。
    public func write(_ buffer: ByteBuffer) async throws {
        do {
            try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
        } catch {
            throw mapWriteError(error)
        }
    }

    /// 写字节。
    public func write(_ bytes: some Sequence<UInt8>) async throws {
        try await write(channel.allocator.buffer(bytes: bytes))
    }

    /// 发 EOF（关掉远端的标准输入）。之后不能再写。
    public func sendEOF() async throws {
        do {
            try await channel.close(mode: .output)
        } catch {
            throw mapWriteError(error)
        }
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

    /// 等通道关闭，返回远端进程的结束方式。
    public func exitStatus() async -> SSHExitStatus {
        await waitForClose()
        let requests = self.requests
        return (try? await channel.eventLoop.submit { requests.value.exitStatus ?? .unknown }.get()) ?? .unknown
    }

    /// 关闭通道。幂等；返回时通道已关闭。
    public func close() async {
        channel.close(promise: nil)
        await waitForClose()
    }

    /// 通道是否还开着。
    public var isActive: Bool { channel.isActive }

    private func waitForClose() async {
        // 出错拆除的子通道 closeFuture 是失败的，成败都算关了。
        _ = try? await channel.closeFuture.get()
    }

    func sendRequest(_ event: any Sendable, kind: SSHChannelRequestKind, wantReply: Bool) async throws {
        let requests = self.requests
        do {
            try await channel.eventLoop.flatSubmit {
                requests.value.send(event, kind: kind, wantReply: wantReply)
            }.get()
        } catch let error as SSHChannelError {
            throw error
        } catch {
            throw mapWriteError(error)
        }
    }

    private func mapWriteError(_ error: any Error) -> any Error {
        if let reason = lifecycle.disconnectReason { return SSHChannelError.connectionClosed(reason) }
        if let error = error as? ChannelError {
            switch error {
            case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed:
                return SSHChannelError.channelClosed
            default:
                break
            }
        }
        if let error = error as? NIOSSHError, error.type == .tcpShutdown {
            return SSHChannelError.connectionClosed(.transportError(error))
        }
        return error
    }
}

/// `openExec` / `openShell` 的句柄。两者是同一个类型：exec 带了 PTY 也能 `resize`。
public typealias SSHExecHandle = SSHSessionHandle
public typealias SSHShellHandle = SSHSessionHandle
