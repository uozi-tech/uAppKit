import Logging
import NIOCore
import NIOSSH

/// 挂在 `NIOSSHHandler` 之后的连接守护（只在 EventLoop 上用）：
/// - 握手阶段：管计时、等认证成功、把各种失败归成 `SSHClientError`，完成 `authenticated`；
/// - 连上之后：记下第一个错误、出错就关连接，连接关了把断开原因交给 `SSHConnectionLifecycle`。
///
/// 断开靠 `closeFuture` 判断而不是 `channelInactive`：`NIOSSHHandler` 不往后传 `channelInactive`。
/// 错误（`errorCaught`）它会往后传，主机密钥回调的失败也是经这里报上来的。
final class SSHConnectionGuard: ChannelInboundHandler {
    typealias InboundIn = Never

    private enum Phase {
        case handshaking
        case connected
        case closed
    }

    private let lifecycle: SSHConnectionLifecycle
    private let authenticated: EventLoopPromise<Void>
    private let clock: SSHHandshakeClock
    private let hostKeyDelegate: SSHHostKeyDelegate
    private let handshakeTimeout: Duration
    private let logger: Logger
    private var phase = Phase.handshaking
    private var firstError: (any Error)?
    private var handshakeFailure: SSHClientError?
    private var context: ChannelHandlerContext?

    init(lifecycle: SSHConnectionLifecycle, authenticated: EventLoopPromise<Void>, clock: SSHHandshakeClock,
         hostKeyDelegate: SSHHostKeyDelegate, authDelegate: SSHClientAuthDelegate,
         handshakeTimeout: Duration, logger: Logger) {
        self.lifecycle = lifecycle
        self.authenticated = authenticated
        self.clock = clock
        self.hostKeyDelegate = hostKeyDelegate
        self.handshakeTimeout = handshakeTimeout
        self.logger = logger
        clock.onExpire = { [weak self] in
            guard let self else { return }
            self.failHandshake(.handshakeTimeout(self.handshakeTimeout))
        }
        authDelegate.onExhausted = { [weak self] failure in
            self?.failHandshake(.authenticationFailed(failure))
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive { clock.start() }
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        // 子通道（跳板机内层）出错拆除时 closeFuture 是失败的，所以不论成败都算「关了」。
        context.channel.closeFuture.whenComplete { _ in
            loopBoundSelf.value.channelClosed()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        clock.start()
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, case .handshaking = phase {
            phase = .connected
            clock.stop()
            lifecycle.markConnected()
            logger.debug("SSH 认证成功")
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if firstError == nil { firstError = error }
        logger.debug("SSH 连接出错，关闭连接", metadata: ["error": "\(String(reflecting: error))"])
        context.close(promise: nil)
    }

    private func failHandshake(_ failure: SSHClientError) {
        guard case .handshaking = phase else { return }
        if handshakeFailure == nil { handshakeFailure = failure }
        context?.close(promise: nil)
    }

    private func channelClosed() {
        let previous = phase
        phase = .closed
        clock.stop()
        hostKeyDelegate.cancelAll()
        switch previous {
        case .closed:
            return
        case .handshaking:
            let reason = disconnectReason()
            authenticated.fail(handshakeFailure ?? handshakeError(for: reason))
            lifecycle.finish(reason)
        case .connected:
            let reason = disconnectReason()
            logger.debug("SSH 连接已断开", metadata: ["reason": "\(reason)"])
            lifecycle.finish(reason)
        }
    }

    private func disconnectReason() -> SSHDisconnectReason {
        if lifecycle.localCloseRequested { return .localClose }
        if let firstError {
            // 主机密钥回调的失败不是传输错误，但握手阶段它会先走 `handshakeError`；这里只是断开原因。
            return .transportError(firstError)
        }
        return .remoteClosed
    }

    private func handshakeError(for reason: SSHDisconnectReason) -> SSHClientError {
        if let firstError {
            switch firstError {
            case let rejection as HostKeyRejection:
                return .hostKeyRejected(rejection.underlying)
            case let timeout as HostKeyValidationTimedOut:
                return .hostKeyValidationTimeout(timeout.timeout)
            case let refused as SSHHostKeyAlgorithmRefused:
                return .handshakeFailed(refused)
            case let sshError as NIOSSHError where sshError.type != .tcpShutdown:
                return .handshakeFailed(firstError)
            default:
                break
            }
        }
        return .connectionClosed(reason)
    }
}
