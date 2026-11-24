import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

// 这几个类型都只在连接的 EventLoop 上用：NIOSSH 在 EventLoop 上调 delegate，`SSHConnectionGuard` 也在那里。
// 它们互相直接持有引用，不跨线程，所以都不是 Sendable；跨线程的那一步（主机密钥回调）经 `NIOLoopBound` 回到 EventLoop。

/// 握手计时：从 TCP 连上（或内层连接的通道激活）开始，主机密钥回调期间暂停，认证成功就停。
final class SSHHandshakeClock {
    private let eventLoop: any EventLoop
    private var remaining: TimeAmount
    private var runningSince: NIODeadline?
    private var scheduled: Scheduled<Void>?
    private var started = false
    private var stopped = false
    private var pauseDepth = 0

    /// 到点时调用（在 EventLoop 上）。
    var onExpire: (() -> Void)?

    init(eventLoop: any EventLoop, budget: TimeAmount) {
        self.eventLoop = eventLoop
        self.remaining = budget
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        if pauseDepth == 0 { run() }
    }

    func pause() {
        pauseDepth += 1
        guard pauseDepth == 1, let since = runningSince else { return }
        remaining = remaining - (NIODeadline.now() - since)
        runningSince = nil
        scheduled?.cancel()
        scheduled = nil
    }

    func resume() {
        guard pauseDepth > 0 else { return }
        pauseDepth -= 1
        if pauseDepth == 0, started, !stopped { run() }
    }

    func stop() {
        stopped = true
        scheduled?.cancel()
        scheduled = nil
        runningSince = nil
    }

    private func run() {
        runningSince = .now()
        let budget = max(remaining, .zero)
        scheduled = eventLoop.assumeIsolated().scheduleTask(in: budget) { [weak self] in
            guard let self, !self.stopped else { return }
            self.stop()
            self.onExpire?()
        }
    }
}

/// 主机密钥回调抛出的错误，包一层以便 `SSHConnectionGuard` 认出它（NIOSSH 只会原样 fireErrorCaught）。
struct HostKeyRejection: Error {
    var underlying: any Error
}

/// 主机密钥回调超时。
struct HostKeyValidationTimedOut: Error {
    var timeout: Duration
}

/// `NIOSSHClientServerAuthenticationDelegate` 的实现：把 `SSHHostKeyValidation` 接到 NIOSSH 上。
final class SSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let eventLoop: any EventLoop
    private let validation: SSHHostKeyValidation
    private let host: String
    private let port: Int
    private let timeout: Duration?
    private let clock: SSHHandshakeClock
    /// 正在跑的回调，连接关掉时取消。
    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var cancelled = false

    init(eventLoop: any EventLoop, validation: SSHHostKeyValidation, host: String, port: Int,
         timeout: Duration?, clock: SSHHandshakeClock) {
        self.eventLoop = eventLoop
        self.validation = validation
        self.host = host
        self.port = port
        self.timeout = timeout
        self.clock = clock
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch validation {
        case .acceptAnything:
            validationCompletePromise.succeed(())
        case .trustedKeys(let keys):
            if keys.contains(hostKey) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejection(underlying: SSHUntrustedHostKey(hostKey: hostKey)))
            }
        case .custom(let callback):
            guard !cancelled else {
                validationCompletePromise.fail(ChannelError.ioOnClosedChannel)
                return
            }
            startCustom(callback, hostKey: hostKey, promise: validationCompletePromise)
        }
    }

    private func startCustom(_ callback: @escaping @Sendable (SSHHostKeyContext) async throws -> Void,
                             hostKey: NIOSSHPublicKey, promise: EventLoopPromise<Void>) {
        clock.pause()
        let id = nextID
        nextID += 1
        let context = SSHHostKeyContext(host: host, port: port, hostKey: hostKey)
        let timeout = self.timeout
        let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
        let eventLoop = self.eventLoop
        // 回调和计时器谁先到算谁；另一个被取消，晚到的结果丢掉。回调不响应取消也不会拖住连接。
        let once = NIOLockedValueBox(false)
        let deliver: @Sendable (Result<Void, any Error>) -> Void = { result in
            let first = once.withLockedValue { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            eventLoop.execute {
                let delegate = loopBoundSelf.value
                delegate.pending[id]?.cancel()
                delegate.pending[id] = nil
                delegate.clock.resume()
                promise.completeWith(result)
            }
        }
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        try await callback(context)
                        deliver(.success(()))
                    } catch {
                        deliver(.failure(HostKeyRejection(underlying: error)))
                    }
                }
                if let timeout {
                    group.addTask {
                        do {
                            try await Task.sleep(for: timeout)
                            deliver(.failure(HostKeyValidationTimedOut(timeout: timeout)))
                        } catch {
                            // 被取消：回调已经给出结果，或连接关了。
                        }
                    }
                }
                // 不等回调本身结束：任一结果送出后取消整组，`withTaskGroup` 退出时才会等子任务，
                // 但这个 Task 是游离的，等多久都不影响 EventLoop 上的连接。
                await group.next()
                group.cancelAll()
            }
        }
        pending[id] = task
    }

    /// 连接关了：取消还挂着的回调。
    func cancelAll() {
        cancelled = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}

/// `NIOSSHClientUserAuthenticationDelegate` 的实现：按 `SSHAuthentication.methods` 的顺序，
/// 跳过服务器不再接受的方式。
final class SSHClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let methods: [SSHAuthenticationMethod]
    private var index = 0
    private var activeDelegate: (any NIOSSHClientUserAuthenticationDelegate & Sendable)?
    private(set) var attempted: [SSHAuthenticationMethod.Kind] = []

    /// 列表用完了（在 EventLoop 上调）。NIOSSH 0.15.2 收到 `nil` 之后什么也不做，连接会一直挂着，
    /// 所以必须由我们自己结束连接。
    var onExhausted: ((SSHAuthenticationFailure) -> Void)?

    init(authentication: SSHAuthentication) {
        self.username = authentication.username
        self.methods = authentication.methods
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let delegate = activeDelegate {
            ask(delegate, availableMethods: availableMethods, promise: nextChallengePromise)
        } else {
            advance(availableMethods: availableMethods, promise: nextChallengePromise)
        }
    }

    private func advance(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while index < methods.count {
            let method = methods[index]
            index += 1
            switch method {
            case .delegate(let delegate):
                activeDelegate = delegate
                ask(delegate, availableMethods: availableMethods, promise: promise)
                return
            case .password(let password):
                guard availableMethods.contains(.password) else { continue }
                attempted.append(.password)
                promise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
                return
            case .privateKey(let key):
                guard availableMethods.contains(.publicKey) else { continue }
                attempted.append(.publicKey)
                promise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
                return
            case .certifiedPrivateKey(let key, let certificate):
                guard availableMethods.contains(.publicKey) else { continue }
                attempted.append(.publicKey)
                promise.succeed(.init(
                    username: username, serviceName: "",
                    offer: .privateKey(.init(privateKey: key, certifiedKey: certificate))))
                return
            }
        }
        promise.succeed(nil)
        onExhausted?(SSHAuthenticationFailure(remainingMethods: availableMethods, attemptedMethods: attempted))
    }

    private func ask(
        _ delegate: any NIOSSHClientUserAuthenticationDelegate & Sendable,
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let eventLoop = promise.futureResult.eventLoop
        let inner = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: inner)
        // delegate 可能在别的线程完成 promise；回调总在 promise 的 EventLoop（即本连接的）上。
        let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
        inner.futureResult.whenComplete { result in
            let this = loopBoundSelf.value
            switch result {
            case .success(.some(let offer)):
                this.attempted.append(.delegate)
                promise.succeed(offer)
            case .success(.none):
                this.activeDelegate = nil
                this.advance(availableMethods: availableMethods, promise: promise)
            case .failure(let error):
                promise.fail(error)
            }
        }
    }
}
