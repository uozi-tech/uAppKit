import Logging
import NIOCore
import NIOSSH

/// 挂在 `NIOSSHHandler` 之后的连接守护（只在 EventLoop 上用）：
/// - 握手阶段：管计时、等认证成功、把各种失败归成 `SSHClientError`，完成 `authenticated`；
/// - 连上之后：记下第一个错误、出错就关连接、按配置发保活，连接关了把断开原因交给 `SSHConnectionLifecycle`。
///
/// 断开靠 `closeFuture` 判断而不是 `channelInactive`：`NIOSSHHandler` 不往后传 `channelInactive`。
/// 错误（`errorCaught`）它会往后传，主机密钥回调的失败、认证用完（`noFurtherAuthenticationOffers`）也是经这里报上来的。
///
/// `authenticated` 在握手失败的那一刻就完成，不等 closeFuture：跳板机内层的传输是外层的子通道，
/// 外层链路卡死时子通道的关闭要等一个永远不来的 CHANNEL_CLOSE。
final class SSHConnectionGuard: ChannelInboundHandler {
    typealias InboundIn = Never

    private enum Phase {
        case handshaking
        case connected
        case closed
    }

    struct KeepAlive {
        var interval: Duration
        var maximumUnanswered: Int
    }

    private let lifecycle: SSHConnectionLifecycle
    private let authenticated: EventLoopPromise<Void>
    private var authenticatedCompleted = false
    private let clock: SSHHandshakeClock
    private let hostKeyDelegate: SSHHostKeyDelegate
    private let authDelegate: SSHClientAuthDelegate
    private let sshHandler: NIOSSHHandler
    private let handshakeTimeout: Duration
    private let keepAlive: KeepAlive?
    private let logger: Logger
    private var phase = Phase.handshaking
    private var firstError: (any Error)?
    private var handshakeFailure: SSHClientError?
    private var context: ChannelHandlerContext?
    private var keepAliveTask: RepeatedTask?
    private var unansweredProbes = 0
    private var keepAliveExpired = false

    init(lifecycle: SSHConnectionLifecycle, authenticated: EventLoopPromise<Void>, clock: SSHHandshakeClock,
         hostKeyDelegate: SSHHostKeyDelegate, authDelegate: SSHClientAuthDelegate, sshHandler: NIOSSHHandler,
         handshakeTimeout: Duration, keepAlive: KeepAlive?, logger: Logger) {
        self.lifecycle = lifecycle
        self.authenticated = authenticated
        self.clock = clock
        self.hostKeyDelegate = hostKeyDelegate
        self.authDelegate = authDelegate
        self.sshHandler = sshHandler
        self.handshakeTimeout = handshakeTimeout
        self.keepAlive = keepAlive
        self.logger = logger
        clock.onExpire = { [weak self] in
            guard let self else { return }
            self.failHandshake(.handshakeTimeout(self.handshakeTimeout))
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive { clock.start() }
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        // NIOSSH 补丁 0002 之后子通道的 closeFuture 也不会失败；成败都算「关了」，不依赖这一点。
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
            authDelegate.forgetCredentials()
            lifecycle.markConnected()
            logger.debug("SSH 认证成功")
            completeAuthenticated(.success(()))
            startKeepAlive(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if firstError == nil { firstError = error }
        logger.debug("SSH 连接出错，关闭连接", metadata: ["error": "\(String(reflecting: error))"])
        if case .handshaking = phase, let failure = handshakeError(forCaught: error) {
            failHandshake(failure)
        }
        context.close(promise: nil)
    }

    private func completeAuthenticated(_ result: Result<Void, any Error>) {
        guard !authenticatedCompleted else { return }
        authenticatedCompleted = true
        authenticated.completeWith(result)
    }

    private func failHandshake(_ failure: SSHClientError) {
        guard case .handshaking = phase else { return }
        if handshakeFailure == nil { handshakeFailure = failure }
        authDelegate.forgetCredentials()
        completeAuthenticated(.failure(handshakeFailure ?? failure))
        context?.close(promise: nil)
    }

    // MARK: - 保活

    private func startKeepAlive(context: ChannelHandlerContext) {
        guard let keepAlive, keepAlive.interval > .zero else { return }
        let interval = TimeAmount(keepAlive.interval)
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        keepAliveTask = context.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { _ in
            loopBoundSelf.value.keepAliveTick()
        }
    }

    private func keepAliveTick() {
        guard case .connected = phase, let keepAlive, let context else { return }
        if unansweredProbes >= keepAlive.maximumUnanswered {
            logger.debug("SSH 保活无回应，关闭连接", metadata: ["unanswered": "\(unansweredProbes)"])
            keepAliveExpired = true
            keepAliveTask?.cancel()
            context.close(promise: nil)
            return
        }
        unansweredProbes += 1
        let promise = context.eventLoop.makePromise(of: GlobalRequest.GenericResponse.self)
        sshHandler.sendGlobalRequest(type: SSHClient.keepAliveRequestType, payload: nil, wantReply: true, promise: promise)
        promise.futureResult.assumeIsolated().whenSuccess { [weak self] _ in
            // 成功、失败（REQUEST_FAILURE）都说明对端还活着。
            self?.unansweredProbes = 0
        }
    }

    // MARK: - 关闭

    private func channelClosed() {
        let previous = phase
        phase = .closed
        clock.stop()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        hostKeyDelegate.cancelAll()
        authDelegate.forgetCredentials()
        switch previous {
        case .closed:
            return
        case .handshaking:
            let reason = disconnectReason()
            completeAuthenticated(.failure(handshakeFailure ?? handshakeError(for: reason)))
            lifecycle.finish(reason)
        case .connected:
            let reason = disconnectReason()
            logger.debug("SSH 连接已断开", metadata: ["reason": "\(reason)"])
            lifecycle.finish(reason)
        }
    }

    private func disconnectReason() -> SSHDisconnectReason {
        if lifecycle.localCloseRequested { return .localClose }
        if keepAliveExpired, let keepAlive { return .keepAliveTimeout(unansweredProbes: keepAlive.maximumUnanswered) }
        if let firstError {
            if let rejection = firstError as? HostKeyRejection { return .transportError(rejection.underlying) }
            return .transportError(firstError)
        }
        return .remoteClosed
    }

    /// 握手阶段收到的错误里，哪些可以立刻定性（不必等通道关掉）。
    private func handshakeError(forCaught error: any Error) -> SSHClientError? {
        switch error {
        case let rejection as HostKeyRejection:
            return .hostKeyRejected(rejection.underlying)
        case let timeout as HostKeyValidationTimedOut:
            return .hostKeyValidationTimeout(timeout.timeout)
        case let failure as AuthenticationDelegateFailure:
            return .authenticationDelegateFailed(failure.underlying)
        case let sshError as NIOSSHError where sshError.type == .noFurtherAuthenticationOffers:
            return .authenticationFailed(authDelegate.failure)
        case let sshError as NIOSSHError where sshError.type != .tcpShutdown:
            return .handshakeFailed(error)
        case is any SSHAlgorithmFailure:
            // 我们自己的算法实现拒绝了对端的东西（越界的 DH 公开值、畸形的 RSA 密钥 / 签名、加密层校验失败）。
            return .handshakeFailed(error)
        default:
            return nil
        }
    }

    private func handshakeError(for reason: SSHDisconnectReason) -> SSHClientError {
        if let firstError, let failure = handshakeError(forCaught: firstError) { return failure }
        return .connectionClosed(reason)
    }
}
