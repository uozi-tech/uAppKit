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
    /// 第一次密钥交换时接受的主机密钥。NIOSSH 每次密钥交换（含重新交换）都会来问，重新交换时只认这一把，
    /// 不再回调（用户不会被同一台主机再问一遍）；换了别的密钥就是硬失败（RFC 4253 §9 不允许换主机身份）。
    private var acceptedKey: NIOSSHPublicKey?

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
        if let acceptedKey {
            if acceptedKey == hostKey {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejection(
                    underlying: SSHHostKeyChangedDuringRekey(previous: acceptedKey, offered: hostKey)))
            }
            return
        }
        switch validation {
        case .acceptAnything:
            acceptedKey = hostKey
            validationCompletePromise.succeed(())
        case .trustedKeys(let keys):
            if keys.contains(hostKey) {
                acceptedKey = hostKey
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
                if case .success = result { delegate.acceptedKey = context.hostKey }
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

/// `.delegate` 认证方式的委托以错误完成了 promise。包一层，`SSHConnectionGuard` 才分得清它和传输错误。
struct AuthenticationDelegateFailure: Error {
    var underlying: any Error
}

/// `NIOSSHClientUserAuthenticationDelegate` 的实现：按 `SSHAuthentication.methods` 的顺序，
/// 跳过服务器不再接受的方式。
///
/// 列表用完时以 `nil` 完成 promise，NIOSSH（补丁 0011）随即在 pipeline 上报
/// `NIOSSHError.noFurtherAuthenticationOffers`，`SSHConnectionGuard` 据此结束连接、取 `failure` 作为详情。
/// 认证结束（成功或失败）后 `forgetCredentials()` 丢掉口令与私钥，不让它们跟着连接活下去。
final class SSHClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var methods: [SSHAuthenticationMethod]
    private let allowsLegacyAlgorithms: Bool
    private let allowsSHA1Fallback: Bool
    private var index = 0
    private var activeDelegate: (any NIOSSHClientUserAuthenticationDelegate & Sendable)?
    /// 正在逐个算法尝试的 RSA 用户私钥与还没试的算法。
    private var rsaAttempts: (key: SSHRSAPrivateKey, remaining: ArraySlice<SSHRSASignatureAlgorithm>)?
    private(set) var attempted: [SSHAuthenticationMethod.Kind] = []
    /// 依次试过的 RSA 签名算法（测试用）。
    private(set) var attemptedRSAAlgorithms: [SSHRSASignatureAlgorithm] = []
    /// 最近一次出价是 RSA 用户私钥时用的签名算法，别的方式时为 nil。认证成功时它就是成功的那一次。
    private(set) var lastOfferedRSAAlgorithm: SSHRSASignatureAlgorithm?
    /// 服务器最后一次声明还接受的方式。
    private var lastAvailable: NIOSSHAvailableUserAuthenticationMethods = .all

    /// 服务器在 `server-sig-algs`（RFC 8308）里宣告的公钥算法（NIOSSH 补丁 0008 交给三参数的
    /// `nextAuthenticationType`）；没宣告时 `nil`。EXT_INFO 早于 SERVICE_ACCEPT，第一次被问时就已经在了。
    private(set) var serverSignatureAlgorithms: [String]?

    init(authentication: SSHAuthentication, allowsLegacyAlgorithms: Bool, allowsSHA1Fallback: Bool = false) {
        self.username = authentication.username
        self.methods = authentication.methods
        self.allowsLegacyAlgorithms = allowsLegacyAlgorithms
        self.allowsSHA1Fallback = allowsSHA1Fallback
    }

    /// 认证失败的详情（列表用完时）。
    var failure: SSHAuthenticationFailure {
        SSHAuthenticationFailure(remainingMethods: lastAvailable, attemptedMethods: attempted)
    }

    /// 丢掉还没用到（或已经用过）的口令、私钥与委托。
    func forgetCredentials() {
        methods = []
        index = 0
        activeDelegate = nil
        rsaAttempts = nil
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextAuthenticationType(
            availableMethods: availableMethods, serverSignatureAlgorithms: nil, nextChallengePromise: nextChallengePromise)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lastAvailable = availableMethods
        self.serverSignatureAlgorithms = serverSignatureAlgorithms
        lastOfferedRSAAlgorithm = nil
        if let delegate = activeDelegate {
            ask(delegate, availableMethods: availableMethods, promise: nextChallengePromise)
        } else if availableMethods.contains(.publicKey), let next = nextRSAAttempt() {
            nextChallengePromise.succeed(next)
        } else {
            rsaAttempts = nil
            advance(availableMethods: availableMethods, promise: nextChallengePromise)
        }
    }

    /// RSA 私钥还有没试的算法就取下一个。
    private func nextRSAAttempt() -> NIOSSHUserAuthenticationOffer? {
        guard var attempts = rsaAttempts, let algorithm = attempts.remaining.popFirst() else { return nil }
        rsaAttempts = attempts
        attempted.append(.publicKey)
        attemptedRSAAlgorithms.append(algorithm)
        lastOfferedRSAAlgorithm = algorithm
        let key = NIOSSHPrivateKey(rsaPrivateKey: attempts.key, algorithm: algorithm)
        return .init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key)))
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
            case .rsaPrivateKey(let key):
                guard availableMethods.contains(.publicKey) else { continue }
                let plan = SSHRSAUserAuthenticationPlan.algorithms(
                    allowsSHA1: allowsLegacyAlgorithms || allowsSHA1Fallback,
                    serverSignatureAlgorithms: serverSignatureAlgorithms)
                rsaAttempts = (key, plan[...])
                guard let offer = nextRSAAttempt() else { continue }
                promise.succeed(offer)
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
    }

    private func ask(
        _ delegate: any NIOSSHClientUserAuthenticationDelegate & Sendable,
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let eventLoop = promise.futureResult.eventLoop
        let inner = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: availableMethods, serverSignatureAlgorithms: serverSignatureAlgorithms,
            nextChallengePromise: inner)
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
                promise.fail(AuthenticationDelegateFailure(underlying: error))
            }
        }
    }
}

/// RSA 用户私钥按哪些签名算法、以什么顺序尝试（每个算法一次认证尝试）。
enum SSHRSAUserAuthenticationPlan {
    /// 候选按偏好：`rsa-sha2-512`、`rsa-sha2-256`，`allowsSHA1` 时最后是 `ssh-rsa`。
    ///
    /// - Parameters:
    ///   - allowsSHA1: 连接允许旧算法，或打开了 `allowsSHA1RSAUserAuthenticationFallback`。
    ///   - serverSignatureAlgorithms: 服务器的 `server-sig-algs`。
    ///     - 宣告了：严格照它。只试其中有的 SHA-2 算法，按我们的偏好，第一次就用最好的那个；`ssh-rsa` 只在它被列出、
    ///       又没有任何 SHA-2 的 RSA 算法时才用；一个 RSA 算法都没有就不试 RSA（OpenSSH 7.2 起都发这个列表，
    ///       没列的它不会接受，试了只是白占认证次数）。
    ///     - 没宣告（`nil`，老服务器）：按候选顺序逐个试，SHA-2 都被拒了才轮到 `ssh-rsa`。
    static func algorithms(
        allowsSHA1: Bool,
        serverSignatureAlgorithms: [String]?
    ) -> [SSHRSASignatureAlgorithm] {
        let sha1 = allowsSHA1 ? SSHRSASignatureAlgorithm.legacy : []
        guard let serverSignatureAlgorithms else { return SSHRSASignatureAlgorithm.modern + sha1 }
        let modern = SSHRSASignatureAlgorithm.modern.filter { serverSignatureAlgorithms.contains($0.name) }
        guard modern.isEmpty else { return modern }
        return sha1.filter { serverSignatureAlgorithms.contains($0.name) }
    }
}
