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
    public func close() async {
        await target.close()
        await bastion?.close()
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
        var legacyMemory: SSHLegacyEndpointMemory = .shared
        var logger: any SSHLogger = NoOpSSHLogger()
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
            legacyMemory: legacyMemory,
            logger: logger
        )
        let target = Hop(host: endpoint.host, port: endpoint.port, username: endpoint.username,
                         credential: credential)
        guard let jumpHost = endpoint.jumpHost else {
            return ConnectedClient(target: try await connectDirect(target, options: options), bastion: nil)
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
    static func makeConfiguration(_ hop: Hop, options: Options,
                                  algorithms: SSHAlgorithms? = nil) throws -> SSHClient.Configuration {
        let trust = HostKeyTrust(
            host: hop.host,
            port: hop.port,
            store: options.hostKeyStore,
            policy: options.hostKeyPolicy,
            approver: options.approver
        )
        var configuration = SSHClient.Configuration(
            authentication: try makeAuthentication(username: hop.username, credential: hop.credential),
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

    /// 连一跳，按 `SSHLegacyFallback` 的规则至多再试一次。抛的是 USSHCore 的原始错误，由调用方归类。
    /// `open` 用给定的配置建这一跳（直连或经跳板机）。
    private static func connectHop(
        _ hop: Hop,
        options: Options,
        open: (SSHClient.Configuration) async throws -> SSHClient
    ) async throws -> SSHClient {
        let first = firstAttemptAlgorithms(hop, options: options)
        let fallback = options.legacyFallback && !first.allowsLegacyAlgorithms
            ? SSHLegacyFallback.retryAlgorithms(for: first) : nil
        let watch = SSHApproverWatch()
        var firstOptions = options
        firstOptions.approver = watch.wrap(options.approver)
        let client: SSHClient
        do {
            client = try await open(makeConfiguration(hop, options: firstOptions, algorithms: first))
        } catch SSHClientError.noCommonAlgorithm(let failure) {
            guard let fallback, SSHLegacyFallback.shouldRetry(after: failure), !watch.wasCalled else {
                throw SSHClientError.noCommonAlgorithm(failure)
            }
            // 第二次的错误（含又一次没有共同算法）原样交出去。
            client = try await open(makeConfiguration(hop, options: options, algorithms: fallback))
        }
        note(client, hop: hop, options: options)
        return client
    }

    /// 连上之后：记下这一跳要不要旧算法、记警告（见 `SSHLegacyFallback.outcome`）。
    private static func note(_ client: SSHClient, hop: Hop, options: Options) {
        let events = SSHLegacyFallback.outcome(
            negotiated: client.negotiatedAlgorithms, rsaUserAuthentication: client.rsaUserAuthenticationAlgorithm,
            host: hop.host, port: hop.port, legacyFallback: options.legacyFallback, memory: options.legacyMemory)
        for event in events { options.logger.log(event) }
    }

    private static func connectDirect(_ hop: Hop, options: Options) async throws -> SSHClient {
        do {
            return try await connectHop(hop, options: options) { configuration in
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
            bastion = try await connectDirect(bastionHop, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let rejection as any HostKeyStoreRejection {
            throw rejection
        } catch {
            // `connectDirect` 抛的已经是归好类的 `SSHConnectionError`。
            throw SSHConnectionError.jumpHostFailed(
                String(localized: "无法连接 \(bastionHop.host):\(String(bastionHop.port)) —— \(SSHErrorText.describe(error))", bundle: ModuleBundle.bundle),
                cause: (try? connectionError(for: error)) ?? .connectFailed(SSHErrorText.describe(error))
            )
        }

        do {
            let client = try await connectHop(target, options: options) { configuration in
                try await bastion.jump(to: target.host, port: target.port, configuration: configuration)
            }
            return ConnectedClient(target: client, bastion: bastion)
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
