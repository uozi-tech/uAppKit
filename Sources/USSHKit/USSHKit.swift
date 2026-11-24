import Foundation
// 客户端层整个转出去：app 只要 `import USSHKit` 就能用 `SSHClient`、`SFTPClient`、通道句柄与它们的错误类型。
@_exported import USSHCore

/// A network address used by an SSH endpoint or forwarding destination.
public struct SSHHostAddress: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Authentication material supplied by the application. USSHKit never reads a keychain.
public enum SSHCredential: Hashable, Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
    case agent
}

/// A single optional bastion. It is deliberately non-recursive so the endpoint remains a value type.
public struct SSHJumpHost: Hashable, Sendable {
    public var address: SSHHostAddress
    public var username: String
    public var credential: SSHCredential

    public init(
        host: String,
        port: Int = 22,
        username: String,
        credential: SSHCredential
    ) {
        self.address = SSHHostAddress(host: host, port: port)
        self.username = username
        self.credential = credential
    }
}

/// Everything needed to identify an SSH server, with an optional one-hop bastion.
public struct SSHEndpoint: Hashable, Sendable {
    public var address: SSHHostAddress
    public var username: String
    public var jumpHost: SSHJumpHost?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        jumpHost: SSHJumpHost? = nil
    ) {
        self.address = SSHHostAddress(host: host, port: port)
        self.username = username
        self.jumpHost = jumpHost
    }

    public var host: String {
        get { address.host }
        set { address.host = newValue }
    }

    public var port: Int {
        get { address.port }
        set { address.port = newValue }
    }
}

/// A serialized server host key. The byte representation matches OpenSSH `known_hosts` key data.
public struct SSHHostKey: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let keyBlob: Data
    public let fingerprint: String

    public init(
        host: String,
        port: Int,
        keyType: String,
        keyBlob: Data,
        fingerprint: String
    ) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.keyBlob = keyBlob
        self.fingerprint = fingerprint
    }
}

public enum SSHHostKeyVerification: Equatable, Sendable {
    case trusted
    case unknown
    case mismatch(previousFingerprint: String)
}

/// An error a `HostKeyStore` throws from `verify` / `remember` to refuse a host key with the
/// application's own typed error (for example "the key changed since it was first trusted", carrying
/// both fingerprints). USSHKit hands it unchanged to the caller of `connect` / `open` (direct and
/// through a jump host) instead of wrapping it into `SSHConnectionError.hostKeyRejected(String)`.
/// Other errors a store throws are still wrapped.
public protocol HostKeyStoreRejection: Error {}

/// Persistence boundary for host-key trust. Applications own storage and UI policy.
public protocol HostKeyStore: Sendable {
    func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification
    func remember(_ hostKey: SSHHostKey) async throws
}

public enum SSHHostKeyPolicy: String, CaseIterable, Sendable {
    case ask
    case strict
    case acceptNew
    case insecureAcceptAll
}

public struct SSHHostKeyChallenge: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable {
        case unknown
        case mismatch
    }

    public let id: UUID
    public let hostKey: SSHHostKey
    public let kind: Kind
    public let previousFingerprint: String?

    public init(
        id: UUID = UUID(),
        hostKey: SSHHostKey,
        kind: Kind,
        previousFingerprint: String? = nil
    ) {
        self.id = id
        self.hostKey = hostKey
        self.kind = kind
        self.previousFingerprint = previousFingerprint
    }
}

public enum SSHPrivateKeyKind: String, CaseIterable, Hashable, Codable, Sendable {
    case rsa
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
}

/// An immutable parsed private key. The concrete key types (USSHCore's RSA key, swift-crypto's
/// Ed25519 / ECDSA keys) stay internal.
public struct SSHPrivateKey: Sendable {
    public let kind: SSHPrivateKeyKind
    let parsed: ParsedPrivateKey

    init(kind: SSHPrivateKeyKind, parsed: ParsedPrivateKey) {
        self.kind = kind
        self.parsed = parsed
    }
}

/// Stable parsing entry point for OpenSSH, PEM, encrypted PKCS#8, RSA, Ed25519, and ECDSA keys.
public enum SSHPrivateKeyParser {
    public static func parse(pem: String, passphrase: String? = nil) throws -> SSHPrivateKey {
        let parsed = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
        return SSHPrivateKey(kind: parsed.kind, parsed: parsed)
    }
}

public struct SSHForwardingRequest: Hashable, Sendable {
    public var endpoint: SSHEndpoint
    public var credential: SSHCredential
    public var target: SSHHostAddress
    public var localHost: String
    /// Zero asks the operating system to choose an available local port.
    public var localPort: Int

    public init(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        targetHost: String,
        targetPort: Int,
        localHost: String = "127.0.0.1",
        localPort: Int = 0
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.target = SSHHostAddress(host: targetHost, port: targetPort)
        self.localHost = localHost
        self.localPort = localPort
    }
}

public struct SSHForwardingEndpoint: Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public protocol SSHForwardingTunnel: Sendable {
    func open() async throws -> SSHForwardingEndpoint
    func close() async
}

public indirect enum SSHConnectionError: Error, LocalizedError, Sendable {
    case alreadyOpen
    case closed
    case unsupportedAgentAuthentication
    case authenticationFailed(String)
    case connectFailed(String)
    /// 握手没成（协议错误、算法协商不成）：服务器配置问题，**不是**网络断了，重试不会好。
    /// 与 `connectFailed` 分开是为了让 app 的重连逻辑不在这种错误上打转；给用户看的文案与 `connectFailed` 相同。
    case handshakeFailed(String)
    /// 经跳板机时某一跳失败了。`String` 是给用户看的整句（说明是哪一跳），`cause` 是那一跳的失败按直连归的类
    /// （`.authenticationFailed` / `.hostKeyRejected` / `.handshakeFailed` 是配置问题、重试不会好；`.connectFailed`
    /// 是网络问题；跳板机拒绝开到目标的通道、或开通道超时也归 `.connectFailed`）。app 判断要不要重连看 `cause`，
    /// 不看文字。只有本端以外的极少数情形 `cause` 为 nil。
    /// 主机密钥库按类型拒绝的（`HostKeyStoreRejection`，哪一跳都一样）不包进这里，原样抛给调用方，类别由 app 自己的类型决定。
    case jumpHostFailed(String, cause: SSHConnectionError? = nil)
    case hostKeyRejected(String)
    case bindFailed(String)
    /// 这一跳要退到 SHA-1 时代的旧算法才连得上，`legacyFallbackApproval` 没有同意（`request` 就是被拒的那一问：
    /// 哪一跳、哪台、为什么、卡在哪一类）。是 app 自己的决定、不是网络问题，**重试不会好**，重连逻辑别在它上面打转。
    /// 没有同意就不会用旧算法再连，进程内也不记什么。经跳板机时同样包在 `jumpHostFailed(_, cause:)` 里。
    case legacyFallbackDeclined(SSHLegacyFallbackRequest)

    public var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            return String(localized: "SSH 隧道已经建立", bundle: ModuleBundle.bundle)
        case .closed:
            return String(localized: "SSH 隧道已关闭", bundle: ModuleBundle.bundle)
        case .unsupportedAgentAuthentication:
            return String(localized: "当前版本尚未支持 ssh-agent 认证", bundle: ModuleBundle.bundle)
        case .authenticationFailed(let message):
            return String(localized: "SSH 认证失败：\(message)", bundle: ModuleBundle.bundle)
        case .connectFailed(let message), .handshakeFailed(let message):
            return String(localized: "SSH 连接失败：\(message)", bundle: ModuleBundle.bundle)
        case .jumpHostFailed(let message, _):
            return String(localized: "SSH 跳板机连接失败：\(message)", bundle: ModuleBundle.bundle)
        case .hostKeyRejected(let message):
            return String(localized: "SSH 主机密钥被拒绝：\(message)", bundle: ModuleBundle.bundle)
        case .bindFailed(let message):
            return String(localized: "SSH 本地转发端口绑定失败：\(message)", bundle: ModuleBundle.bundle)
        case .legacyFallbackDeclined(let request):
            let address = "\(request.host):\(String(request.port))"
            switch request.hop {
            case .target:
                return String(localized: "没有连接 \(address)：这台主机这次只提供较旧、安全性较低的加密方式（SHA-1），所以没有继续连接。", bundle: ModuleBundle.bundle)
            case .jumpHost:
                return String(localized: "没有连接跳板机 \(address)：这台跳板机这次只提供较旧、安全性较低的加密方式（SHA-1），所以没有继续连接。", bundle: ModuleBundle.bundle)
            }
        }
    }
}

public enum SSHLogLevel: Sendable {
    case trace
    case debug
    case info
    case warning
    case error
}

public struct SSHLogEvent: Sendable {
    public let level: SSHLogLevel
    public let message: String
    public let metadata: [String: String]

    public init(level: SSHLogLevel, message: String, metadata: [String: String] = [:]) {
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

public protocol SSHLogger: Sendable {
    func log(_ event: SSHLogEvent)
}

public struct NoOpSSHLogger: SSHLogger {
    public init() {}
    public func log(_ event: SSHLogEvent) {}
}
