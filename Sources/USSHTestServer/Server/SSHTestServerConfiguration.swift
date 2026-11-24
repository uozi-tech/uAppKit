import Crypto
import NIOCore
import NIOSSH

extension SSHTestServer {
    /// 测试服务端的配置。默认：随机 ed25519 主机密钥，谁都登不进（要自己填 `authentication`），
    /// exec 一律「找不到命令」（127），shell 回显，放行 direct-tcpip 与远程转发。
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

    public init(authenticationDelay: Duration? = nil, rejectFirstAuthenticationAttempts: Int = 0,
                withholdServerVersion: Bool = false) {
        self.authenticationDelay = authenticationDelay
        self.rejectFirstAuthenticationAttempts = rejectFirstAuthenticationAttempts
        self.withholdServerVersion = withholdServerVersion
    }
}
