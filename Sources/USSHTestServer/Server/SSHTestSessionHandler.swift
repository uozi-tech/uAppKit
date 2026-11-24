import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import USSHCore

/// 服务端的 session 通道：处理 env / pty-req / window-change / exec / shell / subsystem / signal，
/// 把数据交给处理函数的 `stdin`。只在通道的 EventLoop 上用。
final class SSHTestSessionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData

    private let state: SSHTestServerState
    private var environment: [String: String] = [:]
    private var pty: SSHTestPTYInfo?
    private var started = false
    private var stdin: AsyncStream<ByteBuffer>.Continuation?
    private var windowChanges: AsyncStream<SSHTestWindowSize>.Continuation?
    private var execContext: SSHTestExecContext?
    private var task: Task<Void, Never>?
    /// 客户端已经发过 EOF。
    private let stdinClosed = NIOLockedValueBox(false)

    init(state: SSHTestServerState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        stdin?.yield(buffer)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            let accepted = state.configuration.acceptedEnvironmentNames.map { $0.contains(request.name) } ?? true
            if accepted {
                environment[request.name] = request.value
                state.record { $0.environment[request.name] = request.value }
            } else {
                state.record { $0.rejectedEnvironment.append(request.name) }
            }
            reply(context, success: accepted, wantReply: request.wantReply)

        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            let info = SSHTestPTYInfo(
                term: request.term, columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                pixelWidth: request.terminalPixelWidth, pixelHeight: request.terminalPixelHeight,
                modes: request.terminalModes)
            pty = info
            state.record { $0.ptyRequests.append(info) }
            reply(context, success: true, wantReply: request.wantReply)

        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            let size = SSHTestWindowSize(
                columns: request.terminalCharacterWidth, rows: request.terminalRowHeight,
                pixelWidth: request.terminalPixelWidth, pixelHeight: request.terminalPixelHeight)
            state.record { $0.windowChanges.append(size) }
            windowChanges?.yield(size)

        case let request as SSHChannelRequestEvent.ExecRequest:
            state.record { $0.execCommands.append(request.command) }
            start(context, command: request.command, handler: state.configuration.exec, wantReply: request.wantReply)

        case let request as SSHChannelRequestEvent.ShellRequest:
            state.record { $0.shellRequests += 1 }
            start(context, command: "", handler: state.configuration.shell, wantReply: request.wantReply)

        case let request as SSHChannelRequestEvent.SubsystemRequest:
            state.record { $0.subsystems.append(request.subsystem) }
            startSubsystem(context, name: request.subsystem, wantReply: request.wantReply)

        case let request as SSHChannelRequestEvent.SignalRequest:
            state.record { $0.signals.append(request.signal) }
            execContext?.receivedSignal.withLockedValue { $0 = request.signal }
            task?.cancel()

        case ChannelEvent.inputClosed:
            stdinClosed.withLockedValue { $0 = true }
            stdin?.finish()

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        stdin?.finish()
        windowChanges?.finish()
        task?.cancel()
        context.fireChannelInactive()
    }

    private func reply(_ context: ChannelHandlerContext, success: Bool, wantReply: Bool) {
        guard wantReply else { return }
        let event: any Sendable = success ? ChannelSuccessEvent() : ChannelFailureEvent()
        context.triggerUserOutboundEvent(event, promise: nil)
    }

    private func start(_ context: ChannelHandlerContext, command: String, handler: SSHTestExecHandler, wantReply: Bool) {
        guard !started else {
            reply(context, success: false, wantReply: wantReply)
            return
        }
        started = true
        reply(context, success: true, wantReply: wantReply)
        let (stdinStream, stdin) = AsyncStream.makeStream(of: ByteBuffer.self)
        let (windowStream, windowChanges) = AsyncStream.makeStream(of: SSHTestWindowSize.self)
        self.stdin = stdin
        self.windowChanges = windowChanges
        let channel = context.channel
        let execContext = SSHTestExecContext(
            command: command, environment: environment, pty: pty, stdin: stdinStream,
            windowChanges: windowStream, channel: channel)
        self.execContext = execContext
        let stdinClosed = self.stdinClosed
        task = Task {
            let exit: SSHTestExit
            do {
                exit = try await handler.run(execContext)
            } catch {
                if let signal = execContext.signal {
                    exit = .signal(signal)
                } else if Task.isCancelled {
                    exit = .noStatus
                } else {
                    exit = .status(1)
                }
            }
            Self.finish(channel, exit: exit, sendEOF: !stdinClosed.withLockedValue { $0 })
        }
    }

    /// EOF、退出状态、CHANNEL_CLOSE（OpenSSH 的顺序）。通道已经关了的话这些调用都会默默失败。
    ///
    /// 客户端已经发过 EOF 时不发 EOF（RFC 4254 §5.3 里 EOF 是可选的）：NIOSSH 0.15.2 的
    /// `ChildChannelStateMachine.sendChannelEOF` 在「对端已 EOF」状态下误判为乱序、把通道当协议错误拆掉。
    private static func finish(_ channel: any Channel, exit: SSHTestExit, sendEOF: Bool) {
        if sendEOF { channel.close(mode: .output, promise: nil) }
        switch exit {
        case .status(let code):
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: code), promise: nil)
        case .signal(let name):
            channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitSignal(signalName: name, errorMessage: "", language: "", dumpedCore: false),
                promise: nil)
        case .noStatus:
            break
        }
        channel.close(promise: nil)
    }

    private func startSubsystem(_ context: ChannelHandlerContext, name: String, wantReply: Bool) {
        guard !started, let subsystem = state.configuration.subsystems[name] else {
            reply(context, success: false, wantReply: wantReply)
            return
        }
        started = true
        let channel = context.channel
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        do {
            try channel.pipeline.syncOperations.addHandler(SSHChannelDataCodec(), position: .after(self))
        } catch {
            reply(context, success: false, wantReply: wantReply)
            return
        }
        subsystem(channel).hop(to: channel.eventLoop).whenComplete { result in
            let this = loopBoundSelf.value
            guard let context = this.context(in: channel) else { return }
            switch result {
            case .success:
                // 让出位置：之后通道上只有编解码与 subsystem 自己的 handler。
                this.reply(context, success: true, wantReply: wantReply)
                channel.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            case .failure:
                this.reply(context, success: false, wantReply: wantReply)
            }
        }
    }

    private func context(in channel: any Channel) -> ChannelHandlerContext? {
        try? channel.pipeline.syncOperations.context(handler: self)
    }
}
