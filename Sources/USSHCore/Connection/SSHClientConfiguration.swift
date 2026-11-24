import Logging
import NIOCore
import NIOSSH

extension SSHClient {
    /// 一条 SSH 连接的全部配置。值类型、`Sendable`，可以在任何隔离域里组装好再交给 `connect`。
    ///
    /// 时限分三段，各管各的（RFC 4253 没有规定，这里按 uTerm 的实际需要切）：
    /// - `connectTimeout`：TCP 建连（含 DNS），跳板机的内层连接没有这一段；
    /// - `handshakeTimeout`：版本交换 + 密钥交换 + 认证，**不含**主机密钥回调里花掉的时间；
    /// - `hostKeyValidationTimeout`：主机密钥回调自己的上限（用户可能对着确认框想好几分钟），`nil` 不限。
    public struct Configuration: Sendable {
        /// 登录用户名与认证方式。
        public var authentication: SSHAuthentication

        /// 主机密钥怎么核对。
        public var hostKeyValidation: SSHHostKeyValidation

        /// TCP 建连的时限。
        public var connectTimeout: Duration

        /// 握手 + 认证的时限，主机密钥回调期间暂停计时。
        public var handshakeTimeout: Duration

        /// 主机密钥回调自己的时限，`nil` 表示不限（由回调自己决定什么时候返回）。
        public var hostKeyValidationTimeout: Duration?

        /// 我方愿意接收的单个通道数据包的最大字节数（RFC 4254 §5.1 的 maximum packet size）。
        ///
        /// NIOSSH 0.15 把每条子通道的接收窗口定为它的 64 倍（与 OpenSSH 相同），所以它同时决定窗口：
        /// 默认 128 KiB → 窗口 8 MiB。取值会被夹进 `SSHClient.maximumPacketSizeRange`——NIOSSH 对越界值
        /// 用 precondition 卡住，越界是进程 abort 而不是抛错。跳板机的两跳各自按自己的配置设。
        ///
        /// 内存：一个读得慢（但还在读）的消费者，一条通道最多压住约 **2 个窗口**——NIOSSH 在把数据交给
        /// pipeline 时就补发窗口，而一次 `read()` 会把它缓冲的整窗数据一起交上来；输出序列里压着一窗，
        /// NIOSSH 里又能再收一窗。默认 8 MiB 窗口即每条通道约 16 MiB。
        public var maximumPacketSize: Int

        /// 额外的算法。默认只有 NIOSSH 自带的那些。
        public var algorithms: SSHAlgorithms

        /// 跑这条连接的 EventLoopGroup。`nil` 用 `MultiThreadedEventLoopGroup.singleton`。
        /// 跳板机的内层连接总在外层连接的 EventLoop 上，忽略这一项。
        public var eventLoopGroup: (any EventLoopGroup)?

        /// 连接层的日志。只记协议事件，不记口令、私钥这类材料。
        public var logger: Logger

        /// 保活间隔：认证成功后每隔这么久发一个 `keepalive@openssh.com`（want-reply）。`nil` 不发。
        /// 对端回 SUCCESS 或 FAILURE 都算活着（OpenSSH 回 FAILURE）。
        public var keepAliveInterval: Duration? = nil

        /// 连续这么多个保活没有回应就关闭连接，断开原因是 `SSHDisconnectReason.keepAliveTimeout`
        /// （与 OpenSSH 的 `ServerAliveCountMax` 同义，默认也是 3）。判死所需时间约为
        /// `keepAliveInterval × (keepAliveMaximumUnanswered + 1)`。
        public var keepAliveMaximumUnanswered: Int = 3

        public init(
            authentication: SSHAuthentication,
            hostKeyValidation: SSHHostKeyValidation,
            connectTimeout: Duration = .seconds(30),
            handshakeTimeout: Duration = .seconds(30),
            hostKeyValidationTimeout: Duration? = nil,
            maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
            algorithms: SSHAlgorithms = SSHAlgorithms(),
            eventLoopGroup: (any EventLoopGroup)? = nil,
            logger: Logger = Logger(label: "USSHCore", factory: { _ in SwiftLogNoOpLogHandler() })
        ) {
            self.authentication = authentication
            self.hostKeyValidation = hostKeyValidation
            self.connectTimeout = connectTimeout
            self.handshakeTimeout = handshakeTimeout
            self.hostKeyValidationTimeout = hostKeyValidationTimeout
            self.maximumPacketSize = maximumPacketSize
            self.algorithms = algorithms
            self.eventLoopGroup = eventLoopGroup
            self.logger = logger
        }

        /// 夹进 NIOSSH 接受的区间之后真正用的包长。
        public var effectiveMaximumPacketSize: Int {
            min(max(maximumPacketSize, SSHClient.maximumPacketSizeRange.lowerBound),
                SSHClient.maximumPacketSizeRange.upperBound)
        }

        /// 每条子通道实际通告给对端的接收窗口（NIOSSH：包长 × 64，上限 `UInt32.max`）。
        public var channelWindowSize: Int {
            min(effectiveMaximumPacketSize * 64, Int(UInt32.max))
        }
    }

    /// NIOSSH 0.15 的默认包长（`1 << 17`）。
    public static let defaultMaximumPacketSize = 1 << 17

    /// 我们允许的包长区间。下限是 RFC 4253 §6.1 要求必须支持的 32768。
    ///
    /// 上限 512 KiB → 窗口 32 MiB → 慢消费者每条通道最多约 64 MiB。理由：窗口只要盖住带宽 × 往返时延，
    /// 32 MiB 足够 1 Gbit/s × 250 ms（≈ 30 MB）；再大不会更快，只会让 iOS 上同时开着的几条通道一起把
    /// 内存顶到被系统杀掉（16 MiB 包长 = 1 GiB 窗口，最坏 2 GiB）。uTerm 今天给 SFTP 调的 1 MiB 窗口
    /// （旧 fork 里窗口 = 包长），在这里用默认的 128 KiB 包长就已经是它的 8 倍。
    public static let maximumPacketSizeRange: ClosedRange<Int> = 32_768...(1 << 19)
}

/// 登录用户名 + 按顺序尝试的认证方式。
///
/// 每次服务器回 `USERAUTH_FAILURE` 都会带上它还接受哪些方式（RFC 4252 §5.1）；我们从列表里往下找
/// 第一个服务器还接受的，没有了就以 `SSHClientError.authenticationFailed` 结束连接。
public struct SSHAuthentication: Sendable {
    public var username: String
    public var methods: [SSHAuthenticationMethod]

    public init(username: String, methods: [SSHAuthenticationMethod]) {
        self.username = username
        self.methods = methods
    }

    public static func password(_ password: String, username: String) -> SSHAuthentication {
        SSHAuthentication(username: username, methods: [.password(password)])
    }

    public static func privateKey(_ key: NIOSSHPrivateKey, username: String) -> SSHAuthentication {
        SSHAuthentication(username: username, methods: [.privateKey(key)])
    }
}

/// 一种认证方式。
public enum SSHAuthenticationMethod: Sendable {
    /// 口令（RFC 4252 §8）。
    case password(String)
    /// 公钥（RFC 4252 §7）：ed25519、ECDSA P-256/384/521，以及以后经 NIOSSH 扩展接口注册的类型。
    case privateKey(NIOSSHPrivateKey)
    /// 带 OpenSSH 证书的公钥。
    case certifiedPrivateKey(NIOSSHPrivateKey, certificate: NIOSSHCertifiedPublicKey)
    /// 原样交给一个 NIOSSH 的认证 delegate：每轮都问它，它给 `nil` 才轮到列表里的下一项。
    /// delegate 在连接的 EventLoop 上被调用。
    case delegate(any NIOSSHClientUserAuthenticationDelegate & Sendable)

    /// 这种方式在 RFC 4252 里的名字类别，用来和服务器声明的可用方式比对。
    public var kind: Kind {
        switch self {
        case .password: return .password
        case .privateKey, .certifiedPrivateKey: return .publicKey
        case .delegate: return .delegate
        }
    }

    public enum Kind: Sendable, Hashable {
        case password
        case publicKey
        /// 透传的 delegate，自己判断服务器接受什么。
        case delegate
    }
}

/// 认证失败的详情。
public struct SSHAuthenticationFailure: Error, Sendable, Hashable {
    /// 服务器最后一次声明它还接受的方式（RFC 4252 §5.1 的 "authentications that can continue"）。
    public var remainingMethods: NIOSSHAvailableUserAuthenticationMethods
    /// 我们实际发出过的方式，按顺序。
    public var attemptedMethods: [SSHAuthenticationMethod.Kind]

    public init(remainingMethods: NIOSSHAvailableUserAuthenticationMethods,
                attemptedMethods: [SSHAuthenticationMethod.Kind]) {
        self.remainingMethods = remainingMethods
        self.attemptedMethods = attemptedMethods
    }
}

/// 主机密钥核对时交给回调的信息。
public struct SSHHostKeyContext: Sendable {
    /// 连接时写的主机名（跳板机的内层连接是目标机的名字，不是跳板机）。
    public var host: String
    public var port: Int
    public var hostKey: NIOSSHPublicKey

    public init(host: String, port: Int, hostKey: NIOSSHPublicKey) {
        self.host = host
        self.port = port
        self.hostKey = hostKey
    }
}

/// 主机密钥的核对方式。
public enum SSHHostKeyValidation: Sendable {
    /// 什么都接受。只该用在测试里。
    case acceptAnything
    /// 只接受这几把。
    case trustedKeys(Set<NIOSSHPublicKey>)
    /// 自己决定：正常返回 = 接受，抛错 = 拒绝（抛出的错误原样放进 `SSHClientError.hostKeyRejected`）。
    /// 回调可以一直挂着等用户，期间不计入握手时限；它自己的上限是 `hostKeyValidationTimeout`。
    case custom(@Sendable (SSHHostKeyContext) async throws -> Void)
}

/// 主机密钥不在 `trustedKeys` 里时抛的错误（放在 `SSHClientError.hostKeyRejected` 里）。
public struct SSHUntrustedHostKey: Error, Sendable, Hashable {
    public var hostKey: NIOSSHPublicKey
    public init(hostKey: NIOSSHPublicKey) { self.hostKey = hostKey }
}

/// NIOSSH 默认集之外的算法。
///
/// 现在只有加密方式能经 NIOSSH 0.15.2 的公开接口传进去。密钥交换算法与公钥（主机密钥 / 用户私钥 / 签名）
/// 算法要等 NIOSSH 那条线把扩展接口补上，接好之后各加一个字段放在这里（`keyExchangeAlgorithms`、
/// `publicKeyAlgorithms`），连接层在 `SSHClient.makeNIOConfiguration` 里一并交给 NIOSSH。
public struct SSHAlgorithms: Sendable {
    /// 按偏好排序的加密方式（含 MAC）。默认是 NIOSSH 自带的 AES-GCM 两种。
    public var transportProtectionSchemes: [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type]

    public init(
        transportProtectionSchemes: [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type] =
            Constants.bundledTransportProtectionSchemes
    ) {
        self.transportProtectionSchemes = transportProtectionSchemes
    }
}
