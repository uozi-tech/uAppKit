import Foundation
@preconcurrency import Citadel
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

@_spi(uTermIntegration)
public nonisolated struct ConnectedClient: @unchecked Sendable {
    public let target: SSHClient
    public let bastion: SSHClient?

    init(target: SSHClient, bastion: SSHClient?) {
        self.target = target
        self.bastion = bastion
    }

    public func close() async {
        try? await target.close()
        try? await bastion?.close()
    }

    public func exec(_ command: String) async throws -> String {
        let buffer = try await target.executeCommand(
            command,
            maxResponseSize: 64_000,
            mergeStreams: true
        )
        return String(buffer: buffer)
    }

    public func openDirectTCPIP(
        host: String,
        port: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let prepared = NIOLockedValueBox<NIOAsyncChannel<ByteBuffer, ByteBuffer>?>(nil)

        _ = try await target.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: host,
                targetPort: port,
                originatorAddress: originator
            ),
            initialize: { channel in
                // Install NIOAsyncChannel before the direct-tcpip channel is
                // activated. Server-first protocols such as MySQL may send
                // their greeting immediately; wrapping after create returns
                // leaves an empty-pipeline window that drops those bytes.
                channel.eventLoop.makeCompletedFuture {
                    let asyncChannel = try DirectTCPIPAsyncChannelPreparation.wrap(channel)
                    prepared.withLockedValue { $0 = asyncChannel }
                }
            }
        )

        guard let asyncChannel = prepared.withLockedValue({ $0 }) else {
            throw SSHConnectionError.connectFailed(
                "direct-tcpip channel activated before its async reader was installed"
            )
        }
        return asyncChannel
    }
}

/// Installs the async sequence handlers while the direct-tcpip channel is still
/// inside its initializer and therefore cannot have delivered protocol bytes.
nonisolated enum DirectTCPIPAsyncChannelPreparation {
    static func wrap(
        _ channel: Channel
    ) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
            wrappingChannelSynchronously: channel
        )
    }
}

nonisolated enum SSHClientFactory {
    /// - Parameter protocolOptions: 透传给 Citadel / NIOSSH 的协议级选项。语义、默认值与
    ///   取值边界见 `USSHKitIntegration.connect` 的文档注释。跳板机场景下**两跳都会设**。
    static func connect(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> ConnectedClient {
        if let jumpHost = endpoint.jumpHost {
            return try await connectViaJumpHost(
                endpoint: endpoint,
                credential: credential,
                jumpHost: jumpHost,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                approver: approver,
                protocolOptions: protocolOptions
            )
        }

        let target = try await connectDirect(
            host: endpoint.host,
            port: endpoint.port,
            username: endpoint.username,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            protocolOptions: protocolOptions
        )
        return ConnectedClient(target: target, bastion: nil)
    }

    private static func connectDirect(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> SSHClient {
        let authenticationMethod = try makeAuthenticationMethod(
            username: username,
            credential: credential
        )
        do {
            return try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: .custom(
                    HostKeyValidationDelegate(
                        host: host,
                        port: port,
                        store: hostKeyStore,
                        policy: hostKeyPolicy,
                        approvalTimeout: approvalTimeout,
                        approver: approver
                    )
                ),
                reconnect: .never,
                protocolOptions: protocolOptions,
                connectTimeout: .nanoseconds(connectTimeout.nanosecondsClamped),
                loginTimeout: .nanoseconds(
                    loginTimeout(
                        connectTimeout: connectTimeout,
                        approvalTimeout: approvalTimeout,
                        policy: hostKeyPolicy
                    ).nanosecondsClamped
                )
            )
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.connectFailed(describe(error))
        }
    }

    /// Citadel 的 login timer 覆盖「TCP 连接 + 握手 + 认证」全程，且从装 handler 那一刻起算。
    /// 上游把它硬编码成 10 秒 —— 比用户读完并点掉主机密钥确认框所需的时间还短：`.ask`
    /// 策略下 host-key 审批就发生在握手期，用户在弹层上多停几秒，timer 先到，`connect`
    /// 以 `ChannelError.connectTimeout` 抛出；而底下的 NIOSSH 握手照常走完、服务端
    /// 记下一次没人认领的 `Accepted publickey`。这里把它放大到「连接超时 + 审批超时」：
    /// 审批本身另有 `approveWithTimeout` 兜底，超时即以 `hostKeyRejected` 失败，所以这个
    /// 上限只在「服务端握手/认证期彻底无响应」时才会真的等满。非 `.ask` 策略不会有交互
    /// 等待，只需覆盖连接超时本身。
    static func loginTimeout(
        connectTimeout: Duration,
        approvalTimeout: Duration,
        policy: SSHHostKeyPolicy
    ) -> Duration {
        switch policy {
        case .ask:
            return connectTimeout + approvalTimeout
        case .strict, .acceptNew, .insecureAcceptAll:
            return connectTimeout
        }
    }

    private static func connectViaJumpHost(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        jumpHost: SSHJumpHost,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> ConnectedClient {
        let bastion: SSHClient
        do {
            bastion = try await connectDirect(
                host: jumpHost.address.host,
                port: jumpHost.address.port,
                username: jumpHost.username,
                credential: jumpHost.credential,
                hostKeyStore: hostKeyStore,
                hostKeyPolicy: hostKeyPolicy,
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                approver: approver,
                // 外层 hop 也要放大：内层连接的全部流量都装在外层这条 direct-tcpip
                // 子通道里，外层窗口不放大，内层放大了也白搭。
                protocolOptions: protocolOptions
            )
        } catch {
            throw SSHConnectionError.jumpHostFailed(
                String(localized: "无法连接 \(jumpHost.address.host):\(String(jumpHost.address.port)) —— \(describe(error))", bundle: ModuleBundle.bundle)
            )
        }

        let targetAuthentication: SSHAuthenticationMethod
        do {
            targetAuthentication = try makeAuthenticationMethod(
                username: endpoint.username,
                credential: credential
            )
        } catch {
            try? await bastion.close()
            throw SSHConnectionError.jumpHostFailed(describe(error))
        }

        let settings = makeJumpSettings(
            endpoint: endpoint,
            authenticationMethod: targetAuthentication,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            protocolOptions: protocolOptions
        )

        do {
            let target = try await bastion.jump(to: settings)
            return ConnectedClient(target: target, bastion: bastion)
        } catch {
            try? await bastion.close()
            throw SSHConnectionError.jumpHostFailed(
                String(localized: "经跳板机连接 \(endpoint.host):\(String(endpoint.port)) 失败 —— \(describe(error))", bundle: ModuleBundle.bundle)
            )
        }
    }

    /// 内层 hop（跳板机 → 目标机）的 `SSHClientSettings`。
    ///
    /// 单独抽出来是为了可测：`bastion.jump(to:)` 必须有真连接才能调，而这些字段
    /// 是否被正确填上（尤其是 `protocolOptions`——漏了它内层子通道就还是 128 KiB 窗口）
    /// 是纯数据判断，不该只能靠真连一台跳板机来验。
    static func makeJumpSettings(
        endpoint: SSHEndpoint,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        protocolOptions: Set<SSHProtocolOption>
    ) -> SSHClientSettings {
        var settings = SSHClientSettings(
            host: endpoint.host,
            port: endpoint.port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: .custom(
                HostKeyValidationDelegate(
                    host: endpoint.host,
                    port: endpoint.port,
                    store: hostKeyStore,
                    policy: hostKeyPolicy,
                    approvalTimeout: approvalTimeout,
                    approver: approver
                )
            )
        )
        // 内层 hop 的窗口。外层 hop 在 `connectDirect` 那边设，两跳都要——见该处注释。
        settings.protocolOptions = protocolOptions
        settings.connectTimeout = .nanoseconds(connectTimeout.nanosecondsClamped)
        settings.loginTimeout = .nanoseconds(
            loginTimeout(
                connectTimeout: connectTimeout,
                approvalTimeout: approvalTimeout,
                policy: hostKeyPolicy
            ).nanosecondsClamped
        )
        return settings
    }

    static func makeAuthenticationMethod(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let pem, let passphrase):
            do {
                let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
                return try key.authenticationMethod(username: username)
            } catch let error as PrivateKeyImportError {
                throw SSHConnectionError.authenticationFailed(
                    error.errorDescription ?? String(localized: "私钥导入失败", bundle: ModuleBundle.bundle)
                )
            } catch {
                throw SSHConnectionError.authenticationFailed(describe(error))
            }
        case .agent:
            throw SSHConnectionError.unsupportedAgentAuthentication
        }
    }

    /// 把底层错误翻成能定位问题的文案。
    ///
    /// 纯 Swift 值类型错误（如 `NIOCore.ChannelError`）没有 `LocalizedError`，其
    /// `localizedDescription` 走 NSError 桥接，只会给出「未能完成操作。（NIOCore.ChannelError
    /// 错误 0。）」—— 那个数字是枚举 case 的序号（带载荷的 case 排在前面，所以
    /// `connectTimeout` 恰好是 0），完全无法定位。这里对这类错误改用其自身的
    /// `description` 并附上类型名。
    static func describe(_ error: Error) -> String {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout(let amount):
                return String(localized: "登录阶段超时：\(formatSeconds(amount)) 内未完成握手与认证（ChannelError.connectTimeout）", bundle: ModuleBundle.bundle)
            default:
                return "\(channelError)（NIOCore.ChannelError）"
            }
        }
        if let connectionError = error as? NIOConnectionError {
            // 同样是无 LocalizedError 的值类型（struct → 恒为「错误 1」）。取最后一次尝试的
            // 底层 IOError（含 errno 与 strerror），再带上目标地址。
            let target = "\(connectionError.host):\(connectionError.port)"
            if let last = connectionError.connectionErrors.last {
                return String(localized: "无法连接 \(target)：\(describe(last.error))", bundle: ModuleBundle.bundle)
            }
            if let dns = connectionError.dnsAError ?? connectionError.dnsAAAAError {
                return String(localized: "无法解析 \(connectionError.host)：\(describe(dns))", bundle: ModuleBundle.bundle)
            }
            return String(localized: "无法连接 \(target)（NIOPosix.NIOConnectionError）", bundle: ModuleBundle.bundle)
        }
        if let ioError = error as? IOError {
            // IOError 自带 description（"<reason>: <strerror> (errno: N)"），比桥接文案有用。
            return String(describing: ioError)
        }
        if error is LocalizedError || type(of: error) is NSError.Type {
            let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty { return localized }
        }
        let described = String(describing: error)
        let typeName = String(reflecting: type(of: error))
        if described.isEmpty || described == typeName {
            return typeName
        }
        return described.contains(typeName) ? described : "\(described)（\(typeName)）"
    }

    private static func formatSeconds(_ amount: TimeAmount) -> String {
        let seconds = Double(amount.nanoseconds) / 1_000_000_000
        if seconds == seconds.rounded() {
            let whole = Int(seconds)
            return String(localized: "\(whole) 秒", bundle: ModuleBundle.bundle)
        }
        let text = String(format: "%.1f", seconds)
        return String(localized: "\(text) 秒", bundle: ModuleBundle.bundle, comment: "带一位小数的秒数")
    }
}

private extension Duration {
    var nanosecondsClamped: Int64 {
        let parts = components
        let seconds = parts.seconds
        let attoseconds = parts.attoseconds
        let maxSeconds = Int64.max / 1_000_000_000
        if seconds >= maxSeconds { return Int64.max }
        if seconds <= -maxSeconds { return Int64.min }
        return seconds * 1_000_000_000 + Int64(attoseconds / 1_000_000_000)
    }
}
