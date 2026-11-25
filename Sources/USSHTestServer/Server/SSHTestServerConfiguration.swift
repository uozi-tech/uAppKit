#if USSH_TEST_SERVER
import Crypto
import NIOCore
import NIOSSH
import USSHCore

extension SSHTestServer {
    /// 测试服务端的配置。默认：随机 ed25519 主机密钥，谁都登不进（要自己填 `authentication`），
    /// exec 一律「找不到命令」（127），shell 回显，放行 direct-tcpip 与远程转发，没有 SFTP（`serveSFTP` 挂上），
    /// 算法用 NIOSSH 的默认集（`hostKeys` / `keyExchangeAlgorithms` / `transportProtectionSchemes` 改）。
    public struct Configuration: Sendable {
        public var hostKey: NIOSSHPrivateKey
        public var authentication: SSHTestAuthentication
        /// exec 请求怎么处理。
        public var exec: SSHTestExecHandler
        /// shell 请求怎么处理（`command` 为空串）。
        public var shell: SSHTestExecHandler
        /// subsystem 名 → 处理函数（见 `SSHTestSubsystemHandler`）。
        public var subsystems: [String: SSHTestSubsystemHandler]
        /// 接受哪些环境变量名（其余的 `env` 请求回 FAILURE，不进 `environment`）。`nil` 全接受。
        public var acceptedEnvironmentNames: Set<String>?
        public var allowsDirectTCPIP: Bool
        public var allowsRemoteForwarding: Bool
        /// 服务端愿意接收的通道包长（决定它通告给客户端的窗口：× 64）。
        public var maximumPacketSize: Int
        public var faults: SSHTestFaults
        /// 服务端按流量自动重新交换密钥的上限（默认 NIOSSH 的 2^31 包 / 1 GiB）。测试设小就能频繁交换。
        public var rekeyLimits: NIOSSHRekeyLimits = .default

        /// 给了就用这几把当主机密钥、按顺序提供（同一把 RSA 钥匙以几种算法提供就放几个，见
        /// `useRSAHostKey`），`hostKey` 不再用。`SSHTestServer.hostPublicKey` 取第一把的公钥。
        public var hostKeys: [NIOSSHPrivateKey]?
        /// 按偏好排序的密钥交换算法名；`nil` 用 NIOSSH 的默认（自带的那几种）。
        /// 可以放 USSHCore 的 DH（`SSHDiffieHellmanAlgorithm.name`），起服务端时自动登记。
        public var keyExchangeAlgorithms: [String]?
        /// 按偏好排序的加密方式；`nil` 用 NIOSSH 自带的 AES-GCM。
        public var transportProtectionSchemes: [SSHTransportProtections.Scheme]?
        /// 在 EXT_INFO 里宣告的 `server-sig-algs`（RFC 8308，客户端宣告了 `ext-info-c` 才发）；`nil` 不发
        /// （像 OpenSSH 7.2 之前的服务器）。OpenSSH 发的是它接受的全部用户公钥算法。
        public var serverSignatureAlgorithms: [String]?
        /// 接受 SHA-1 的旧算法（`ssh-rsa` 用户签名等）。为真时起服务端会调进程级的
        /// `SSHAlgorithms.registerLegacyAlgorithms()`；`keyExchangeAlgorithms` 里有 group14-sha1、或
        /// `useRSAHostKey` 带了 `ssh-rsa` 时自动视为真。
        public var acceptsLegacyAlgorithms = false

        /// 主机密钥只用这把 RSA 钥匙，按 `algorithms` 的顺序提供这几种签名算法。
        public mutating func useRSAHostKey(
            _ key: SSHRSAPrivateKey,
            algorithms: [SSHRSASignatureAlgorithm] = SSHRSASignatureAlgorithm.modern
        ) {
            hostKeys = algorithms.map { NIOSSHPrivateKey(rsaPrivateKey: key, algorithm: $0) }
            if algorithms.contains(where: \.isLegacy) { acceptsLegacyAlgorithms = true }
        }

        /// 挂上 SFTP：`sftp` subsystem 交给 `SFTPServer.install`，文件来自 `fileSystem`。
        public mutating func serveSFTP(
            fileSystem: any SFTPServerFileSystem,
            configuration: SFTPServer.Configuration = SFTPServer.Configuration(),
            faults: SFTPFaultInjector = SFTPFaultInjector()
        ) {
            subsystems["sftp"] = { channel in
                channel.eventLoop.makeCompletedFuture {
                    _ = try SFTPServer.install(
                        on: channel, fileSystem: fileSystem, configuration: configuration, faults: faults)
                }
            }
        }

        /// 实际提供的主机密钥。
        var effectiveHostKeys: [NIOSSHPrivateKey] {
            if let hostKeys, !hostKeys.isEmpty { return hostKeys }
            return [hostKey]
        }

        var requiresLegacyRegistration: Bool {
            acceptsLegacyAlgorithms
                || (keyExchangeAlgorithms ?? []).contains { SSHDiffieHellmanAlgorithm(name: $0)?.isLegacy == true }
        }

        public init(
            hostKey: NIOSSHPrivateKey = NIOSSHPrivateKey(ed25519Key: .init()),
            authentication: SSHTestAuthentication = SSHTestAuthentication(),
            exec: SSHTestExecHandler = .notFound,
            shell: SSHTestExecHandler = .echoShell,
            subsystems: [String: SSHTestSubsystemHandler] = [:],
            acceptedEnvironmentNames: Set<String>? = nil,
            allowsDirectTCPIP: Bool = true,
            allowsRemoteForwarding: Bool = true,
            maximumPacketSize: Int = 1 << 17,
            faults: SSHTestFaults = SSHTestFaults()
        ) {
            self.hostKey = hostKey
            self.authentication = authentication
            self.exec = exec
            self.shell = shell
            self.subsystems = subsystems
            self.acceptedEnvironmentNames = acceptedEnvironmentNames
            self.allowsDirectTCPIP = allowsDirectTCPIP
            self.allowsRemoteForwarding = allowsRemoteForwarding
            self.maximumPacketSize = maximumPacketSize
            self.faults = faults
        }
    }
}

/// subsystem 的挂载点：subsystem 请求到来时，服务端先在子通道上装好 `SSHChannelData` ⇄ `ByteBuffer` 的编解码
/// （只有通道数据，扩展数据丢弃），再调这个函数让它在末尾加自己的 handler（在通道的 EventLoop 上）。
/// future 成功才回 SUCCESS，失败回 FAILURE。和客户端 `openSubsystemChannel` 的约定一致。
public typealias SSHTestSubsystemHandler = @Sendable (any Channel) -> EventLoopFuture<Void>

/// 登录规则。
public struct SSHTestAuthentication: Sendable {
    /// 用户名 → 口令。
    public var passwords: [String: String]
    /// 用户名 → 接受的公钥。
    public var authorizedKeys: [String: [NIOSSHPublicKey]]
    /// 给了就只听它的（上面两项不再看）。
    public var custom: (@Sendable (SSHTestAuthAttempt) async -> Bool)?
    /// 比 `custom` 更细：可以回「部分成功」（RFC 4252 §5.1 的 partial success，要求再用别的方式认证一次）。
    /// 给了就优先于 `custom`。
    public var decision: (@Sendable (SSHTestAuthAttempt) async -> SSHTestAuthDecision)?
    /// 服务器声明支持的方式（RFC 4252 §5.1 的 "authentications that can continue"）。
    public var supportedMethods: NIOSSHAvailableUserAuthenticationMethods
    /// RSA 用户签名只接受这几种算法（像 sshd 的 `PubkeyAcceptedAlgorithms`）；`nil` 都接受。
    /// 签名本身已由 NIOSSH 验过，这里只看算法，不符的按认证失败回。
    public var acceptedRSASignatureAlgorithms: Set<SSHRSASignatureAlgorithm>?

    public init(
        passwords: [String: String] = [:],
        authorizedKeys: [String: [NIOSSHPublicKey]] = [:],
        custom: (@Sendable (SSHTestAuthAttempt) async -> Bool)? = nil,
        supportedMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]
    ) {
        self.passwords = passwords
        self.authorizedKeys = authorizedKeys
        self.custom = custom
        self.supportedMethods = supportedMethods
    }

    /// 谁来都放行。
    public static var acceptAnyone: SSHTestAuthentication {
        SSHTestAuthentication(custom: { _ in true })
    }

    func decide(_ attempt: SSHTestAuthAttempt) async -> SSHTestAuthDecision {
        // 像 sshd 的 PubkeyAcceptedAlgorithms：不在名单里的 RSA 签名算法，不论别的规则怎么说都拒绝。
        if let rsa = attempt.rsaSignatureAlgorithm, let accepted = acceptedRSASignatureAlgorithms,
           !accepted.contains(rsa) {
            return .reject
        }
        if let decision { return await decision(attempt) }
        return await accepts(attempt) ? .accept : .reject
    }

    func accepts(_ attempt: SSHTestAuthAttempt) async -> Bool {
        if let custom { return await custom(attempt) }
        switch attempt.method {
        case .password(let password):
            return passwords[attempt.username] == password
        case .publicKey(let key):
            return authorizedKeys[attempt.username]?.contains(key) ?? false
        case .none:
            return false
        }
    }
}

/// 对一次认证请求的判定。
public enum SSHTestAuthDecision: Sendable {
    case accept
    case reject
    /// 这一步通过了，但还要再用 `remaining` 里的方式认证（RFC 4252 §5.1）。
    case partialSuccess(remaining: NIOSSHAvailableUserAuthenticationMethods)
}

/// 一次登录尝试。
public struct SSHTestAuthAttempt: Sendable, Hashable {
    public enum Method: Sendable, Hashable {
        case password(String)
        case publicKey(NIOSSHPublicKey)
        case none
    }

    public var username: String
    public var method: Method
    /// RSA 公钥认证时客户端用的签名算法（`rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa`），其余为 `nil`。
    public var rsaSignatureAlgorithm: SSHRSASignatureAlgorithm?
    /// 服务端的判定（含故障注入造成的拒绝）。
    public var accepted: Bool
}

/// 故障注入。
public struct SSHTestFaults: Sendable {
    /// 每次认证请求都先等这么久再回应。
    public var authenticationDelay: Duration?
    /// 前 N 次认证请求一律拒绝（整个服务端计数，不分连接）。
    public var rejectFirstAuthenticationAttempts: Int
    /// 接受 TCP 连接后一言不发（不发版本行），用来测握手超时。
    public var withholdServerVersion: Bool
    /// 把服务端 KEXINIT 里的每个 name-list 写成带空项与结尾逗号的样子（`a,b` → `,a,,b,`）。RFC 4251 不允许，
    /// 但 NIOSSH 照收（按逗号切、丢掉空项），所以有的实现就这么发。不影响交换哈希：NIOSSH 解析之后重新序列化再算。
    public var unusualNameLists: Bool

    public init(authenticationDelay: Duration? = nil, rejectFirstAuthenticationAttempts: Int = 0,
                withholdServerVersion: Bool = false, unusualNameLists: Bool = false) {
        self.authenticationDelay = authenticationDelay
        self.rejectFirstAuthenticationAttempts = rejectFirstAuthenticationAttempts
        self.withholdServerVersion = withholdServerVersion
        self.unusualNameLists = unusualNameLists
    }
}
#endif
