import Foundation
import NIOCore
import NIOSSH
import USSHCore

/// 一条已认证的连接（经跳板机时带着外层的跳板机连接）。`SSHClient` 本身是 `Sendable` 的句柄，
/// 通道、SFTP、转发都直接在 `target` 上开。
@_spi(uTermIntegration)
public nonisolated struct ConnectedClient: Sendable {
    public let target: SSHClient
    public let bastion: SSHClient?

    public init(target: SSHClient, bastion: SSHClient?) {
        self.target = target
        self.bastion = bastion
    }

    /// 先关目标连接，再关跳板机。幂等。
    /// 关掉目标连接，再关跳板机。经跳板机时目标连接的关闭最多等 `gracePeriod` 让跳板机回 CHANNEL_CLOSE
    /// （见 `SSHClient.close(gracePeriod:)`）；跳板机是 TCP，关掉就是关了。所以整个最多约 `gracePeriod`。
    public func close(gracePeriod: Duration = SSHClient.closeGracePeriod) async {
        await target.close(gracePeriod: gracePeriod)
        await bastion?.close(gracePeriod: gracePeriod)
    }

    /// 目标连接用上的 SHA-1 时代旧算法（自动退级的结果，见 `SSHLegacyFallback`）：协商到的密钥交换 / 主机密钥 / MAC
    /// 是旧算法时各一项，RSA 用户私钥以 `ssh-rsa` 认证成功时一项。没有用上时为空。
    public var legacyAlgorithmsInUse: [SSHLegacyAlgorithm] {
        SSHLegacyFallback.legacyAlgorithms(of: target)
    }

    /// 跳板机那一跳用上的旧算法（没有跳板机时为空）。
    public var bastionLegacyAlgorithmsInUse: [SSHLegacyAlgorithm] {
        bastion.map(SSHLegacyFallback.legacyAlgorithms(of:)) ?? []
    }

    /// 目标那一跳的传输层算法读得出来（`legacyAlgorithmsInUse` 里的密钥交换 / 主机密钥 / MAC 可信）。
    /// 为 false 时 USSHCore 没读懂服务器的 KEXINIT：空的 `legacyAlgorithmsInUse` 只说明 RSA 用户认证没用 `ssh-rsa`，
    /// 传输层用没用旧算法**不知道**（日志里另有一条警告）。
    public var legacyAlgorithmStatusKnown: Bool { target.negotiatedAlgorithms != nil }

    /// 跳板机那一跳的同上（没有跳板机时为 true）。
    public var bastionLegacyAlgorithmStatusKnown: Bool { bastion.map { $0.negotiatedAlgorithms != nil } ?? true }

    /// 目标那一跳的**传输层**这次是不是靠 SHA-1 时代的旧算法才协商成的：`true` 需要（密钥交换 / 主机密钥 / MAC 有一项是
    /// 旧算法，含「加密是 AES-GCM、MAC 不用，但服务器只报了 `hmac-sha1`、没有它协商不出来」），`false` 不需要，`nil` 不知道
    /// （没读懂服务器的 KEXINIT）。`ConnectedClient` 只在连接（含认证）成功之后才有，所以这是已经连上的那一次的结论。
    ///
    /// App 记「这台需要旧算法」（`legacyFallbackApproval` 据此决定问不问）按它写：`true` 记、`false` 清、`nil` 不动。
    /// 别用 `legacyAlgorithmsInUse`：那是给人看的，含 RSA 用户签名的 `ssh-rsa`（与主机那一端的安全性无关），MAC 只看实际
    /// 在用的（AES-GCM 时为空），两个方向都会记错。也别在 `legacyFallbackApproval` 里提前落盘：同意之后那次连接可能失败，
    /// 也可能协商到现代算法（中间人只篡改了第一次的 KEXINIT）。
    public var targetNeededLegacyTransport: Bool? {
        SSHLegacyFallback.negotiationNeededLegacy(target.negotiatedAlgorithms)
    }

    /// 跳板机那一跳的同上。没有跳板机时为 nil（没有要记的）。
    public var bastionNeededLegacyTransport: Bool? {
        bastion.flatMap { SSHLegacyFallback.negotiationNeededLegacy($0.negotiatedAlgorithms) }
    }

    /// 两条连接（有跳板机时）都还连着。
    public var isConnected: Bool {
        target.isConnected && (bastion?.isConnected ?? true)
    }

    /// 跑一条命令，stdout 与 stderr 合在一起按到达顺序返回，最多 64 000 字节。
    ///
    /// - Throws: 非零退出抛 `SSHCommandError.nonZeroExit`，输出超限抛 `SSHCommandError.outputTooLarge`
    ///   （远端命令随之结束）；通道层的失败是 `SSHChannelError`。
    public func exec(_ command: String) async throws -> String {
        let buffer = try await target.executeCommand(
            command,
            maxResponseSize: 64_000,
            mergeStreams: true
        )
        return String(buffer: buffer)
    }

    /// 经目标连接开 direct-tcpip 到 `host:port`，返回已经包好的 `NIOAsyncChannel`（在通道激活之前、
    /// 在它的 EventLoop 上包的，服务器先说话的协议的首包不会丢）。出站半关闭打开：`outbound.finish()`
    /// 向对端发 EOF。
    public func openDirectTCPIP(
        host: String,
        port: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await target.openDirectTCPIPAsyncChannel(
            targetHost: host,
            targetPort: port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        )
    }
}

/// 由 `SSHEndpoint` + 凭据 + 主机密钥策略组装 USSHCore 的连接配置并建连（含一跳跳板机），
/// 把失败归成 `SSHConnectionError`。
nonisolated enum SSHClientFactory {

    /// 一跳连接的参数（目标与跳板机各一份）。
    struct Hop: Sendable {
        var host: String
        var port: Int
        var username: String
        var credential: SSHCredential
    }

    /// 两跳共用的设置。
    struct Options: Sendable {
        var hostKeyStore: any HostKeyStore
        var hostKeyPolicy: SSHHostKeyPolicy
        var connectTimeout: Duration
        var approvalTimeout: Duration
        var approver: @Sendable (SSHHostKeyChallenge) async -> Bool
        var maximumPacketSize: Int
        var algorithms: SSHAlgorithms
        var keepAliveInterval: Duration?
        /// 自动退到旧算法（见 `SSHLegacyFallback`）；关掉时只用 `algorithms`，RSA 用户私钥也不试 `ssh-rsa`
        /// （除非 `algorithms` 本身允许旧算法）。
        var legacyFallback: Bool = true
        /// 即将用旧算法连之前问 app（见 `USSHKitIntegration.connect(legacyFallbackApproval:)`）；nil 时不问、照旧自动退级。
        var legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)? = nil
        var legacyMemory: SSHLegacyEndpointMemory = .shared
        var logger: any SSHLogger = NoOpSSHLogger()
        /// 这一次 `connect` 里解析过的凭据（退级再试、两跳用同一份凭据时不再解析一遍）。
        var credentials = SSHCredentialResolver()
    }

    static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        algorithms: SSHAlgorithms = .standard,
        keepAliveInterval: Duration? = nil,
        legacyFallback: Bool = true,
        legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)? = nil,
        legacyMemory: SSHLegacyEndpointMemory = .shared,
        logger: any SSHLogger = NoOpSSHLogger()
    ) async throws -> ConnectedClient {
        let options = Options(
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            maximumPacketSize: maximumPacketSize,
            algorithms: algorithms,
            keepAliveInterval: keepAliveInterval,
            legacyFallback: legacyFallback,
            legacyFallbackApproval: legacyFallbackApproval,
            legacyMemory: legacyMemory,
            logger: logger
        )
        let target = Hop(host: endpoint.host, port: endpoint.port, username: endpoint.username,
                         credential: credential)
        guard let jumpHost = endpoint.jumpHost else {
            return ConnectedClient(target: try await connectDirect(target, role: .target, options: options), bastion: nil)
        }
        let bastionHop = Hop(host: jumpHost.address.host, port: jumpHost.address.port,
                             username: jumpHost.username, credential: jumpHost.credential)
        return try await connectViaJumpHost(target: target, bastion: bastionHop, options: options)
    }

    /// 一跳的 USSHCore 配置。跳板机场景两跳各一份，`maximumPacketSize` 两跳都设：内层连接的全部流量
    /// 都装在外层那条 direct-tcpip 子通道里，外层窗口不放大，内层放大了也白搭。
    ///
    /// 时限：TCP 建连与「握手 + 认证」各给 `connectTimeout`；等主机密钥回调的那段不计入握手（USSHCore
    /// 暂停计时），单独给 `HostKeyTrust.validationTimeout`。保活默认关（`keepAliveInterval == nil`，今天的行为）。
    ///
    /// `algorithms` 不给时用 `options.algorithms`；`legacyFallback` 开着、而这一跳在进程内记着需要旧算法时，
    /// 直接用补上旧算法的那一套。`legacyFallback` 开着时也打开同一条连接里 RSA 用户私钥的 `ssh-rsa` 回退。
    ///
    /// `authentication` 给了就用它（`connect` 里预先解析好的），否则在这里同步解析凭据。
    static func makeConfiguration(_ hop: Hop, options: Options, algorithms: SSHAlgorithms? = nil,
                                  authentication: SSHAuthentication? = nil) throws -> SSHClient.Configuration {
        let trust = HostKeyTrust(
            host: hop.host,
            port: hop.port,
            store: options.hostKeyStore,
            policy: options.hostKeyPolicy,
            approver: options.approver
        )
        var configuration = SSHClient.Configuration(
            authentication: try authentication ?? makeAuthentication(username: hop.username, credential: hop.credential),
            hostKeyValidation: trust.validation,
            connectTimeout: options.connectTimeout,
            handshakeTimeout: options.connectTimeout,
            hostKeyValidationTimeout: HostKeyTrust.validationTimeout(
                policy: options.hostKeyPolicy,
                connectTimeout: options.connectTimeout,
                approvalTimeout: options.approvalTimeout
            ),
            maximumPacketSize: options.maximumPacketSize,
            algorithms: algorithms ?? firstAttemptAlgorithms(hop, options: options)
        )
        configuration.allowsSHA1RSAUserAuthenticationFallback = options.legacyFallback
        // 两跳各自保活：外层断了内层随之断，但外层还活着、内层的服务器卡死时只有内层的保活看得见。
        configuration.keepAliveInterval = options.keepAliveInterval
        return configuration
    }

    /// 第一次用的算法：记着需要旧算法的就直接补上。
    private static func firstAttemptAlgorithms(_ hop: Hop, options: Options) -> SSHAlgorithms {
        guard options.legacyFallback,
              options.legacyMemory.needsLegacy(host: hop.host, port: hop.port),
              let fallback = SSHLegacyFallback.retryAlgorithms(for: options.algorithms) else {
            return options.algorithms
        }
        return fallback
    }

    /// 连一跳，按 `SSHLegacyFallback` 的规则再试。抛的是 USSHCore 的原始错误，由调用方归类；
    /// `options.legacyFallbackApproval` 不同意用旧算法时抛 `SSHConnectionError.legacyFallbackDeclined`。
    /// `open` 用给定的配置建这一跳（直连或经跳板机），`role` 是问 app 时报的是哪一跳。
    ///
    /// 没有共同算法时：
    /// 1. 调用方的算法集比 `.standard` 窄（如 `.builtInOnly`），而服务器这一类的报价里有 `.standard` 补上的**现代**算法：
    ///    先只补现代算法再试一次，**不问**（这不是退到旧算法）；
    /// 2. 仍然（或一开始就）要补上 SHA-1 的旧算法才对得上、或说不出卡在哪一类：问 app，同意了再补上旧算法试一次。
    /// 所以默认的 `.standard` 至多再试一次，更窄的集合至多两次。
    ///
    /// 用旧算法连之前问 app 的两处：第一次就要带上旧算法（进程内记着这台需要）、上面的第 2 步。
    /// 前一处被拒时不带旧算法照常连：主机可能已经升级了；仍然要补上旧算法才对得上时不再问，抛被拒的那一问
    /// （`failure` 换成这次实际的协商失败）。被拒时不再连，进程内的记录也不动（那一次没用上旧算法才会忘掉）。
    private static func connectHop(
        _ hop: Hop,
        role: SSHLegacyFallbackRequest.Hop,
        options: Options,
        open: (SSHClient.Configuration) async throws -> SSHClient
    ) async throws -> SSHClient {
        // 凭据只解析一次（带口令的私钥要跑 bcrypt，1024 轮在 Mac 上就要二十秒），在后台队列上做，不占协作线程池。
        let authentication = try await options.credentials.authentication(username: hop.username, credential: hop.credential)
        var attempt = firstAttemptAlgorithms(hop, options: options)
        /// app 不同意用旧算法的那一问（之后不再用旧算法、也不再问）。
        var declined: SSHLegacyFallbackRequest?
        if attempt.allowsLegacyAlgorithms, !options.algorithms.allowsLegacyAlgorithms {
            // 是进程内的记录让第一次就带上了旧算法。
            let request = SSHLegacyFallbackRequest(
                hop: role, host: hop.host, port: hop.port, trigger: .remembered,
                failure: options.legacyMemory.failure(host: hop.host, port: hop.port))
            let approved = try await approveLegacy(request, options: options)
            if !approved {
                declined = request
                attempt = options.algorithms
            }
        }
        /// 补现代算法那一步做过没有（至多一次）。
        var triedModernRetry = false
        /// 让这次补上了旧算法的那次协商失败（连上之后记进进程内记录）。
        var legacyRetryAfter: SSHAlgorithmNegotiationFailure?
        while true {
            let watch = SSHApproverWatch()
            var attemptOptions = options
            attemptOptions.approver = watch.wrap(options.approver)
            do {
                let client = try await open(makeConfiguration(hop, options: attemptOptions, algorithms: attempt,
                                                              authentication: authentication))
                note(client, hop: hop, options: options, failure: legacyRetryAfter)
                return client
            } catch SSHClientError.noCommonAlgorithm(let failure) {
                // 问过主机密钥信任的不再试（不问两次）；已经带着旧算法的、关掉退级的也不再试。
                guard options.legacyFallback, !attempt.allowsLegacyAlgorithms, !watch.wasCalled else {
                    throw SSHClientError.noCommonAlgorithm(failure)
                }
                if !triedModernRetry, failure.category != nil,
                   let modern = SSHLegacyFallback.retryAlgorithms(for: attempt, includingLegacy: false),
                   SSHLegacyFallback.shouldRetry(after: failure, first: attempt, retry: modern) {
                    triedModernRetry = true
                    try Task.checkCancellation()
                    attempt = modern
                    continue
                }
                guard let fallback = SSHLegacyFallback.retryAlgorithms(for: attempt),
                      SSHLegacyFallback.shouldRetry(after: failure, first: attempt, retry: fallback) else {
                    throw SSHClientError.noCommonAlgorithm(failure)
                }
                if var declined {
                    declined.failure = failure
                    throw SSHConnectionError.legacyFallbackDeclined(declined)
                }
                let request = SSHLegacyFallbackRequest(hop: role, host: hop.host, port: hop.port,
                                                       trigger: .noCommonAlgorithm, failure: failure)
                guard try await approveLegacy(request, options: options) else {
                    throw SSHConnectionError.legacyFallbackDeclined(request)
                }
                // 这一次的错误（含又一次没有共同算法）原样交出去：带着旧算法，循环开头的守卫不再试。
                try Task.checkCancellation()
                attempt = fallback
                legacyRetryAfter = failure
            }
        }
    }

    /// 用旧算法连之前问 app；没给 `legacyFallbackApproval` 时同意（今天的行为）。不同意时记一条日志。
    ///
    /// 限时 `options.approvalTimeout`（与等主机密钥确认同一个时限）：到点还没回答按不同意处理，日志写明是超时——app 把询问交给
    /// 没人接的通道时，连接不会永远停在「连接中」。等的时候没有连接开着，`connectTimeout` 不计。建连任务被取消时立刻抛
    /// `CancellationError`，不等闭包返回。不论哪种结局，闭包所在的任务都会被取消。
    private static func approveLegacy(_ request: SSHLegacyFallbackRequest, options: Options) async throws -> Bool {
        guard options.legacyFallback, let approval = options.legacyFallbackApproval else { return true }
        // 建连任务已经取消了就不弹询问（例如第一次连接正好以「没有共同算法」结束的同一刻被取消）。
        try Task.checkCancellation()
        let outcome = try await SSHLegacyApprovalWait.run(approval, request: request, timeout: options.approvalTimeout)
        guard outcome != .approved else { return true }
        options.logger.log(SSHLogEvent(
            level: .info,
            message: outcome == .timedOut
                ? "等待是否改用 SHA-1 时代旧算法的回答超时，按不同意处理，不再试"
                : "没有同意改用 SHA-1 时代的旧算法连接，不再试",
            metadata: [
                "host": request.host,
                "port": String(request.port),
                "hop": request.hop == .target ? "target" : "jumpHost",
                "trigger": request.trigger == .noCommonAlgorithm ? "noCommonAlgorithm" : "remembered",
                "timedOut": outcome == .timedOut ? "true" : "false",
            ]))
        return false
    }

    /// 连上之后：记下这一跳要不要旧算法、记警告（见 `SSHLegacyFallback.outcome`）。
    private static func note(_ client: SSHClient, hop: Hop, options: Options,
                             failure: SSHAlgorithmNegotiationFailure?) {
        // 进程内记录只在自动退级的模式下写：调用方自己给了带旧算法的集合（`.legacyCompatible`）时，这次用上旧算法
        // 不说明「需要」，也没有退级那一次的失败可记。
        let events = SSHLegacyFallback.outcome(
            negotiated: client.negotiatedAlgorithms, rsaUserAuthentication: client.rsaUserAuthenticationAlgorithm,
            host: hop.host, port: hop.port,
            legacyFallback: options.legacyFallback && !options.algorithms.allowsLegacyAlgorithms,
            memory: options.legacyMemory, failure: failure)
        for event in events { options.logger.log(event) }
    }

    private static func connectDirect(_ hop: Hop, role: SSHLegacyFallbackRequest.Hop,
                                      options: Options) async throws -> SSHClient {
        do {
            return try await connectHop(hop, role: role, options: options) { configuration in
                try await SSHClient.connect(host: hop.host, port: hop.port, configuration: configuration)
            }
        } catch {
            throw try connectionError(for: error)
        }
    }

    private static func connectViaJumpHost(target: Hop, bastion bastionHop: Hop,
                                           options: Options) async throws -> ConnectedClient {
        let bastion: SSHClient
        do {
            bastion = try await connectDirect(bastionHop, role: .jumpHost, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let rejection as any HostKeyStoreRejection {
            throw rejection
        } catch SSHConnectionError.legacyFallbackDeclined(let request) {
            // 文案自己就说了是哪台跳板机，不再套「无法连接……」。
            throw SSHConnectionError.jumpHostFailed(SSHErrorText.describeLegacyDecline(request),
                                                    cause: .legacyFallbackDeclined(request))
        } catch {
            // `connectDirect` 抛的已经是归好类的 `SSHConnectionError`。
            throw SSHConnectionError.jumpHostFailed(
                String(localized: "无法连接 \(bastionHop.host):\(String(bastionHop.port)) —— \(SSHErrorText.describe(error))", bundle: ModuleBundle.bundle),
                cause: (try? connectionError(for: error)) ?? .connectFailed(SSHErrorText.describe(error))
            )
        }

        do {
            let client = try await connectHop(target, role: .target, options: options) { configuration in
                try await bastion.jump(to: target.host, port: target.port, configuration: configuration)
            }
            return ConnectedClient(target: client, bastion: bastion)
        } catch SSHConnectionError.legacyFallbackDeclined(let request) {
            // 目标那一跳没同意用旧算法：说清楚是经哪台跳板机、没连哪台目标（跳板机本身是好的）。
            await bastion.close()
            throw SSHConnectionError.jumpHostFailed(
                SSHErrorText.describeLegacyDecline(
                    request, via: SSHErrorText.address(host: bastionHop.host, port: bastionHop.port)),
                cause: .legacyFallbackDeclined(request))
        } catch let error as SSHConnectionError {
            // 组配置时的失败（私钥导入等）。
            await bastion.close()
            throw SSHConnectionError.jumpHostFailed(SSHErrorText.describe(error), cause: error)
        } catch {
            await bastion.close()
            if error is CancellationError { throw error }
            if case SSHClientError.hostKeyRejected(let underlying) = error,
               let rejection = underlying as? any HostKeyStoreRejection {
                throw rejection
            }
            throw SSHConnectionError.jumpHostFailed(
                String(localized: "经跳板机连接 \(target.host):\(String(target.port)) 失败 —— \(jumpFailureDetail(error, target: target))", bundle: ModuleBundle.bundle),
                cause: jumpFailureCause(error)
            )
        }
    }

    /// 内层那一跳的失败按直连归类；跳板机拒绝开 direct-tcpip（RFC 4254 的原因码）与开通道超时归 `.connectFailed`。
    private static func jumpFailureCause(_ error: any Error) -> SSHConnectionError {
        if case SSHChannelError.openRejected(let failure) = error {
            return .connectFailed(SSHErrorText.describe(failure))
        }
        return (try? connectionError(for: error)) ?? .connectFailed(SSHErrorText.describe(error))
    }

    /// 内层那一跳的失败：跳板机拒绝开 direct-tcpip 时按 RFC 4254 的原因码说人话
    /// （转发被禁止 / 跳板机连不上目标），开通道超时同 `-L` 的说法，其余同直连。
    private static func jumpFailureDetail(_ error: any Error, target: Hop) -> String {
        if case SSHChannelError.openRejected = error {
            return SSHForwardingChannelFailure(classifying: error)
                .userMessage(targetHost: target.host, targetPort: target.port)
        }
        if case SSHClientError.connectTimeout = error {
            // `jump` 把 connectTimeout 当作开 direct-tcpip 通道的时限。
            return SSHForwardingChannelFailure(kind: .timeout, detail: SSHErrorText.describe(error))
                .userMessage(targetHost: target.host, targetPort: target.port)
        }
        let mapped: any Error = (try? connectionError(for: error)) ?? error
        return SSHErrorText.describe(mapped)
    }

    /// USSHCore 的建连错误 → `SSHConnectionError`。任务取消原样抛 `CancellationError`。
    static func connectionError(for error: any Error) throws -> SSHConnectionError {
        switch error {
        case let error as SSHConnectionError:
            return error
        case is CancellationError:
            throw error
        case let error as SSHClientError:
            switch error {
            case .hostKeyRejected(let underlying):
                // 我们的信任判定抛的就是 `SSHConnectionError.hostKeyRejected`，原样交出去；
                // 主机密钥库自己按类型拒绝（`HostKeyStoreRejection`）的原样抛给调用方；
                // 主机密钥库自己出错（读写失败）也算拒绝。
                if let rejection = underlying as? SSHConnectionError { return rejection }
                if let rejection = underlying as? any HostKeyStoreRejection { throw rejection }
                return .hostKeyRejected(SSHErrorText.describe(underlying))
            case .hostKeyValidationTimeout:
                return .hostKeyRejected(SSHErrorText.describe(error))
            case .authenticationFailed, .authenticationDelegateFailed:
                return .authenticationFailed(SSHErrorText.describe(error))
            case .handshakeFailed, .noCommonAlgorithm:
                // 配置问题、不是网络断了：单列，app 的重连逻辑据此不打转。显示同 `.connectFailed`。
                return .handshakeFailed(SSHErrorText.describe(error))
            case .connectTimeout, .connectFailed, .handshakeTimeout, .connectionClosed:
                return .connectFailed(SSHErrorText.describe(error))
            }
        default:
            return .connectFailed(SSHErrorText.describe(error))
        }
    }

    /// 凭据 → USSHCore 的认证配置。私钥在这里解析，解析失败报 `.authenticationFailed`（带导入错误的文案）。
    static func makeAuthentication(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthentication {
        switch credential {
        case .password(let password):
            return .password(password, username: username)
        case .privateKey(let pem, let passphrase):
            keyImports.increment()
            do {
                let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
                return SSHAuthentication(username: username, methods: key.authenticationMethods)
            } catch let error as PrivateKeyImportError {
                throw SSHConnectionError.authenticationFailed(
                    error.errorDescription ?? String(localized: "私钥导入失败", bundle: ModuleBundle.bundle)
                )
            } catch {
                throw SSHConnectionError.authenticationFailed(SSHErrorText.describe(error))
            }
        case .agent:
            throw SSHConnectionError.unsupportedAgentAuthentication
        }
    }
}

extension SSHClientFactory {
    /// 解析私钥的次数（测试用：核对一次 `connect` 里每份凭据只解析一次）。
    static let keyImports = SSHCounter()
}

/// 一次 `connect` 里的凭据缓存：同一份凭据（目标与跳板机相同、退级再试）只解析一次。只活到这次 `connect` 结束，
/// 不把私钥留得比以前更久。解析在专门的队列上做（bcrypt 可能要几十秒，不能占着协作线程池），开始前、结束后各看
/// 一次取消。
nonisolated final class SSHCredentialResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [SSHCredential: [SSHAuthenticationMethod]] = [:]

    private static let queue = DispatchQueue(label: "com.uozi.USSHKit.key-import", qos: .userInitiated,
                                             attributes: .concurrent)

    func authentication(username: String, credential: SSHCredential) async throws -> SSHAuthentication {
        try Task.checkCancellation()
        if let cached = lock.withLock({ methods[credential] }) {
            return SSHAuthentication(username: username, methods: cached)
        }
        let resolved: [SSHAuthenticationMethod] = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try SSHClientFactory.makeAuthentication(username: username, credential: credential).methods
                })
            }
        }
        try Task.checkCancellation()
        lock.withLock { methods[credential] = resolved }
        return SSHAuthentication(username: username, methods: resolved)
    }
}

/// 线程安全的计数器。
nonisolated final class SSHCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// 等 `legacyFallbackApproval` 的回答：闭包的结果、超时、建连任务被取消，先到的算数，不等闭包自己返回
/// （它可能卡在一个没人接的界面上、也不响应取消）。闭包在一个单独的任务里跑，结局一定下就取消它。
nonisolated enum SSHLegacyApprovalWait {
    enum Outcome: Sendable, Equatable {
        case approved
        case declined
        case timedOut
    }

    static func run(
        _ approval: @escaping @Sendable (SSHLegacyFallbackRequest) async -> Bool,
        request: SSHLegacyFallbackRequest,
        timeout: Duration
    ) async throws -> Outcome {
        try Task.checkCancellation()
        let slot = SSHOneShotSlot<Outcome>()
        let asking = Task {
            let approved = await approval(request)
            slot.resume(.success(approved ? .approved : .declined))
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            slot.resume(.success(.timedOut))
        }
        defer {
            asking.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await slot.value()
        } onCancel: {
            slot.resume(.failure(CancellationError()))
        }
    }
}

/// 只认第一次 `resume` 的一次性结果；`value()` 之前就有了结果时直接交出。
nonisolated final class SSHOneShotSlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func resume(_ result: Result<Value, any Error>) {
        let waiting: CheckedContinuation<Value, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Value, any Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
