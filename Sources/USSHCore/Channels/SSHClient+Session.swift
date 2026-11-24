import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

// session 通道（RFC 4254 §6）：exec、shell、subsystem。

extension SSHClient {
    /// 开一条 exec 通道跑 `command`。
    ///
    /// - Parameters:
    ///   - environment: 逐个发 `env` 请求（不要回应）。服务器没在 `AcceptEnv` 里放行的会被它默默忽略，不算失败。
    ///   - pty: 给了就先要一个伪终端（远端进程看到的是 tty，stdout / stderr 合在一起）。
    /// - Throws: `SSHChannelError.openRejected` / `.requestRejected(.exec 或 .pseudoTerminal)` /
    ///   `.connectionClosed`；任务取消抛 `CancellationError`（通道已关闭）。
    public func openExec(_ command: String, environment: [String: String] = [:],
                         pty: SSHPseudoTerminal? = nil) async throws -> SSHExecHandle {
        try await openSession(environment: environment, pty: pty, start: .exec(command))
    }

    /// 开一条交互 shell 通道。`pty` 为 `nil` 时不要伪终端（远端 shell 以非交互方式读标准输入）。
    public func openShell(pty: SSHPseudoTerminal? = SSHPseudoTerminal(),
                          environment: [String: String] = [:]) async throws -> SSHShellHandle {
        try await openSession(environment: environment, pty: pty, start: .shell)
    }

    /// 开一条 subsystem 通道（例如 `"sftp"`）。
    ///
    /// subsystem 请求成功之后返回；返回的子通道 pipeline 上只收发 `ByteBuffer`（只有通道数据，
    /// 扩展数据被丢掉），字节流协议的 handler 直接加在末尾即可。
    ///
    /// 请求成功到调用方加上 handler 之间如果对端先发了数据，那些数据会落到 pipeline 末尾被丢掉——
    /// 对 sftp 这类客户端先说话的协议没有影响；服务器先说话的协议用带 `initializer` 的版本。
    public func openSubsystemChannel(_ name: String) async throws -> any Channel {
        try await openSubsystemChannel(name, initializer: { _ in })
    }

    /// 同上，`initializer` 在 subsystem 请求成功的同一个 EventLoop tick 里、任何数据交上来之前执行，
    /// 可以用 `channel.pipeline.syncOperations` 装 handler、或用 `NIOAsyncChannel(wrappingChannelSynchronously:)` 包起来。
    public func openSubsystemChannel(
        _ name: String,
        initializer: @escaping @Sendable (any Channel) throws -> Void
    ) async throws -> any Channel {
        let handle = try await openSession(environment: [:], pty: nil, start: .subsystem(name, initializer))
        return handle.channel
    }

    // MARK: - 便捷写法

    /// 跑一条命令，收集输出。
    ///
    /// - Parameters:
    ///   - maxResponseSize: 收集到的字节数上限，超过就关通道并抛 `SSHCommandError.outputTooLarge`。
    ///   - mergeStreams: stderr 是否也收进结果（按到达顺序穿插）。不合并时 stderr 被丢弃。
    /// - Throws: 非零退出抛 `SSHCommandError.nonZeroExit`（带已收集的输出）。
    public func executeCommand(
        _ command: String,
        maxResponseSize: Int = .max,
        mergeStreams: Bool = false,
        environment: [String: String] = [:]
    ) async throws -> ByteBuffer {
        let handle = try await openExec(command, environment: environment)
        var collected = handle.channel.allocator.buffer(capacity: 0)
        do {
            for try await chunk in handle.output {
                var buffer: ByteBuffer
                switch chunk {
                case .stdout(let bytes): buffer = bytes
                case .stderr(let bytes):
                    guard mergeStreams else { continue }
                    buffer = bytes
                }
                guard collected.readableBytes + buffer.readableBytes <= maxResponseSize else {
                    await handle.terminate()
                    throw SSHCommandError.outputTooLarge(limit: maxResponseSize)
                }
                collected.writeBuffer(&buffer)
            }
        } catch {
            await handle.terminate()
            throw error
        }
        let status = await handle.exitStatus()
        guard status.isSuccess else {
            throw SSHCommandError.nonZeroExit(status, output: collected)
        }
        return collected
    }

    /// 跑一条命令，边跑边交出输出。序列正常结束说明退出状态为 0；否则在末尾抛 `SSHCommandError.nonZeroExit`
    /// （`output` 为空，输出已经交出去了）。和 `SSHChannelOutput` 一样有背压、只能有一个消费者，
    /// 消费者提前退出或任务取消会结束远端命令。
    public func executeCommandStream(
        _ command: String,
        environment: [String: String] = [:]
    ) async throws -> SSHCommandOutputStream {
        SSHCommandOutputStream(handle: try await openExec(command, environment: environment))
    }

    /// 开一条 exec 通道交给 `body`，`body` 返回（或抛错、或任务被取消）后关闭通道。
    /// `body` 拿到输出序列与句柄（写标准输入、`sendEOF`、`exitStatus`）。
    public func withExec<R>(
        _ command: String,
        environment: [String: String] = [:],
        pty: SSHPseudoTerminal? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SSHChannelOutput, SSHExecHandle) async throws -> sending R
    ) async throws -> sending R {
        let handle = try await openExec(command, environment: environment, pty: pty)
        return try await Self.withHandle(handle, body)
    }

    /// 开一条带伪终端的 shell 交给 `body`，`body` 返回后关闭通道。句柄支持 `write` / `resize`。
    public func withPTY<R>(
        _ pty: SSHPseudoTerminal = SSHPseudoTerminal(),
        environment: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SSHChannelOutput, SSHShellHandle) async throws -> sending R
    ) async throws -> sending R {
        let handle = try await openShell(pty: pty, environment: environment)
        return try await Self.withHandle(handle, body)
    }

    private static func withHandle<R>(
        _ handle: SSHSessionHandle,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SSHChannelOutput, SSHSessionHandle) async throws -> sending R
    ) async throws -> sending R {
        let result: R
        do {
            result = try await body(handle.output, handle)
        } catch {
            await handle.terminate()
            throw error
        }
        if Task.isCancelled {
            await handle.terminate()
        } else {
            await handle.close()
        }
        return result
    }

    // MARK: - 实现

    enum SessionStart: Sendable {
        case exec(String)
        case shell
        case subsystem(String, @Sendable (any Channel) throws -> Void)
    }

    private struct SessionParts: Sendable {
        var requests: NIOLoopBound<SSHChannelRequestHandler>
        var output: SSHChannelOutput?
    }

    func openSession(environment: [String: String], pty: SSHPseudoTerminal?,
                     start: SessionStart) async throws -> SSHSessionHandle {
        let parts = NIOLockedValueBox<SessionParts?>(nil)
        let isSubsystem: Bool
        if case .subsystem = start { isSubsystem = true } else { isSubsystem = false }
        let channel = try await openChildChannel(type: .session) { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                let requests = SSHChannelRequestHandler(eventLoop: child.eventLoop)
                let sync = child.pipeline.syncOperations
                try sync.addHandler(requests)
                var output: SSHChannelOutput?
                if isSubsystem {
                    try sync.addHandler(SSHChannelDataCodec())
                } else {
                    let (handler, producer) = SSHSessionOutputHandler.make(eventLoop: child.eventLoop)
                    try sync.addHandler(handler)
                    output = SSHChannelOutput(producer: producer)
                }
                let bound = NIOLoopBound(requests, eventLoop: child.eventLoop)
                parts.withLockedValue { $0 = SessionParts(requests: bound, output: output) }
            }
        }
        guard let session = parts.withLockedValue({ $0 }) else {
            channel.close(promise: nil)
            throw SSHChannelError.channelClosed
        }
        let requests = session.requests
        let replies = channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            let handler = requests.value
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                let event = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
                _ = handler.send(event, kind: .environment(name), wantReply: false)
            }
            var pending: [EventLoopFuture<Void>] = []
            if let pty {
                let event = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: pty.term,
                    terminalCharacterWidth: pty.columns, terminalRowHeight: pty.rows,
                    terminalPixelWidth: pty.pixelWidth, terminalPixelHeight: pty.pixelHeight,
                    terminalModes: pty.modes)
                pending.append(handler.send(event, kind: .pseudoTerminal, wantReply: true))
            }
            // 请求按顺序流水线发出（RFC 4254 §5.4 保证回应按序），不等 pty-req 的回应再发 exec，省一个往返；
            // pty 被拒时整条通道关掉，已经起来的进程随通道结束。
            switch start {
            case .exec(let command):
                pending.append(handler.send(
                    SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                    kind: .exec, wantReply: true))
            case .shell:
                pending.append(handler.send(
                    SSHChannelRequestEvent.ShellRequest(wantReply: true), kind: .shell, wantReply: true))
            case .subsystem(let name, let initializer):
                let child = channel
                handler.onSuccess[.subsystem(name)] = {
                    do {
                        try initializer(child)
                    } catch {
                        child.pipeline.fireErrorCaught(error)
                        child.close(promise: nil)
                    }
                }
                pending.append(handler.send(
                    SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true),
                    kind: .subsystem(name), wantReply: true))
            }
            return EventLoopFuture.andAllSucceed(pending, on: channel.eventLoop)
        }
        do {
            try await withTaskCancellationHandler {
                try await replies.get()
            } onCancel: {
                channel.close(promise: nil)
            }
            try Task.checkCancellation()
        } catch {
            channel.close(promise: nil)
            try Task.checkCancellation()
            throw mapChannelError(error)
        }
        let output = session.output ?? SSHChannelOutput.empty(on: channel.eventLoop)
        return SSHSessionHandle(channel: channel, output: output, requests: requests, lifecycle: lifecycle)
    }
}

extension SSHChannelOutput {
    /// 没有输出的序列（subsystem 通道的句柄用不到输出，数据走 pipeline）。
    static func empty(on eventLoop: any EventLoop) -> SSHChannelOutput {
        let (_, producer) = SSHSessionOutputHandler.make(eventLoop: eventLoop)
        return SSHChannelOutput(producer: producer)
    }
}

extension SSHSessionHandle {
    /// 结束远端进程并关闭通道：先发 `signal TERM`（RFC 4254 §6.9），再关通道。
    ///
    /// 只关通道的话，OpenSSH 只回收伪终端（有 PTY 的进程因此收到 SIGHUP）；没有 PTY 的进程要等它下次
    /// 写输出撞上 SIGPIPE 才会退出，`sleep` 这类不输出的会一直跑下去。服务器不支持或拒绝 signal 也无妨。
    public func terminate(signal name: String = "TERM") async {
        if channel.isActive {
            try? await signal(name)
        }
        await close()
    }
}

/// `executeCommandStream` 的输出：`SSHChannelOutput` 加上「非零退出在末尾抛错」。
public struct SSHCommandOutputStream: AsyncSequence, Sendable {
    public typealias Element = SSHChannelOutputChunk

    /// 底层句柄（需要写标准输入、拿退出状态时用）。
    public let handle: SSHExecHandle

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: SSHChannelOutput.AsyncIterator
        let handle: SSHExecHandle
        var done = false

        public mutating func next() async throws -> SSHChannelOutputChunk? {
            guard !done else { return nil }
            do {
                if let chunk = try await base.next() { return chunk }
            } catch {
                done = true
                await handle.terminate()
                throw error
            }
            done = true
            let status = await handle.exitStatus()
            guard status.isSuccess else {
                throw SSHCommandError.nonZeroExit(status, output: ByteBuffer())
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: handle.output.makeAsyncIterator(), handle: handle)
    }
}
