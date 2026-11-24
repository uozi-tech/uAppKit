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
        public var maximumPacketSize: Int

        /// 额外的算法。默认只有 NIOSSH 自带的那些。
        public var algorithms: SSHAlgorithms

        /// 跑这条连接的 EventLoopGroup。`nil` 用 `MultiThreadedEventLoopGroup.singleton`。
        /// 跳板机的内层连接总在外层连接的 EventLoop 上，忽略这一项。
        public var eventLoopGroup: (any EventLoopGroup)?

        /// 连接层的日志。只记协议事件，不记口令、私钥这类材料。
        public var logger: Logger

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

    /// 我们允许的包长区间。下限是 RFC 4253 §6.1 要求必须支持的 32768；上限取 16 MiB——
    /// NIOSSH 本身放得更宽，但窗口是包长的 64 倍、按 `UInt32` 存，再大就饱和了，没有意义。
    public static let maximumPacketSizeRange: ClosedRange<Int> = 32_768...(1 << 24)
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

    public static func rsaPrivateKey(_ key: SSHRSAPrivateKey, username: String) -> SSHAuthentication {
        SSHAuthentication(username: username, methods: [.rsaPrivateKey(key)])
    }
}

/// 一种认证方式。
public enum SSHAuthenticationMethod: Sendable {
    /// 口令（RFC 4252 §8）。
    case password(String)
    /// 公钥（RFC 4252 §7）：ed25519、ECDSA P-256/384/521，以及以后经 NIOSSH 扩展接口注册的类型。
    case privateKey(NIOSSHPrivateKey)
    /// RSA 用户私钥（RFC 8332）。依次以 `rsa-sha2-512`、`rsa-sha2-256` 签名尝试，连接允许旧算法时最后再试
    /// SHA-1 的 `ssh-rsa`；每个算法算服务器的一次认证尝试，第一次成功就停。
    ///
    /// 服务器宣告了 `server-sig-algs`（RFC 8308，OpenSSH 7.2 起都发）时只试其中有的、第一次就用最好的那个，
    /// 一个 RSA 算法都没列就跳过这把钥匙；没宣告时按上面的顺序逐个试（`SSHRSAUserAuthenticationPlan`）。
    case rsaPrivateKey(SSHRSAPrivateKey)
    /// 带 OpenSSH 证书的公钥。
    case certifiedPrivateKey(NIOSSHPrivateKey, certificate: NIOSSHCertifiedPublicKey)
    /// 原样交给一个 NIOSSH 的认证 delegate：每轮都问它，它给 `nil` 才轮到列表里的下一项。
    /// delegate 在连接的 EventLoop 上被调用。
    case delegate(any NIOSSHClientUserAuthenticationDelegate & Sendable)

    /// 这种方式在 RFC 4252 里的名字类别，用来和服务器声明的可用方式比对。
    public var kind: Kind {
        switch self {
        case .password: return .password
        case .privateKey, .rsaPrivateKey, .certifiedPrivateKey: return .publicKey
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

/// 一条连接用哪些算法。现成的组合见 `.builtInOnly`（默认）、`.standard`、`.legacyCompatible`。
///
/// 四个列表都按偏好排序，NIOSSH 按这个顺序报给服务器、取第一个双方都支持的。
/// `allowsLegacyAlgorithms == false` 时列表里的 SHA-1 旧算法（`hmac-sha1*`、`diffie-hellman-group14-sha1`、
/// `ssh-rsa` 主机密钥）一律被去掉，RSA 用户密钥也不会以 `ssh-rsa` 尝试——放进列表不等于启用，必须同时打开开关。
public struct SSHAlgorithms: Sendable {
    /// 按偏好排序的加密方式（含 MAC）。NIOSSH 自带的是 AES-GCM 两种（`Constants.bundledTransportProtectionSchemes`），
    /// USSHCore 的在 `SSHTransportProtections`。
    public var transportProtectionSchemes: [SSHTransportProtections.Scheme]

    /// 按偏好排序的密钥交换算法名。可以是 NIOSSH 自带的（`builtInKeyExchangeAlgorithms`）或 USSHCore 的
    /// 有限域 DH（`SSHDiffieHellmanAlgorithm.name`）；不认识的名字被 NIOSSH 跳过、不会报出去。
    public var keyExchangeAlgorithms: [String]

    /// 按偏好排序的主机密钥算法名，原样交给 NIOSSH 的 `SSHClientConfiguration.hostKeyAlgorithms`（补丁 0014 起
    /// 按连接生效）：报给服务器的、协商的、验主机签名时接受的都只来自它。NIOSSH 自带的在
    /// `builtInHostKeyAlgorithms`，USSHCore 的 RSA 是 `SSHRSASignatureAlgorithm.name`。
    ///
    /// 进程级的登记表只决定 NIOSSH 认识哪些算法；接受与否只看这里。所以别的连接用过 `.legacyCompatible`
    /// （登记过 `ssh-rsa`）之后，这里没有 `ssh-rsa` 的连接照样不接受 SHA-1 的主机签名。
    public var hostKeyAlgorithms: [String]

    /// 是否允许 SHA-1 的旧算法。打开后建连接时会调 `SSHAlgorithms.registerLegacyAlgorithms()`（进程级登记，
    /// 见那里的说明；别的连接不受影响）。
    public var allowsLegacyAlgorithms: Bool

    public init(
        transportProtectionSchemes: [SSHTransportProtections.Scheme] = Constants.bundledTransportProtectionSchemes,
        keyExchangeAlgorithms: [String] = SSHAlgorithms.builtInKeyExchangeAlgorithms,
        hostKeyAlgorithms: [String] = SSHAlgorithms.builtInHostKeyAlgorithms,
        allowsLegacyAlgorithms: Bool = false
    ) {
        self.transportProtectionSchemes = transportProtectionSchemes
        self.keyExchangeAlgorithms = keyExchangeAlgorithms
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.allowsLegacyAlgorithms = allowsLegacyAlgorithms
    }

    /// NIOSSH 0.15.2 自带的密钥交换算法，按它的默认顺序（`SSHClientConfiguration.keyExchangeAlgorithms` 的默认值）。
    public static let builtInKeyExchangeAlgorithms: [String] = [
        "ecdh-sha2-nistp384", "ecdh-sha2-nistp256", "ecdh-sha2-nistp521",
        "curve25519-sha256", "curve25519-sha256@libssh.org",
    ]

    /// NIOSSH 0.15.2 自带的主机密钥算法，按它的默认顺序。
    public static let builtInHostKeyAlgorithms: [String] = [
        "ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521",
    ]

    // MARK: 预设

    /// 只用 NIOSSH 自带的：AES-GCM、curve25519 / ECDH、ed25519 / ECDSA 主机密钥（今天 app 发出去的就是这一套）。
    /// RSA 用户密钥照样能用（`rsa-sha2-512` → `rsa-sha2-256`），不报、不接受 RSA 主机密钥。
    public static let builtInOnly = SSHAlgorithms()

    /// 自带的优先，后面补上 USSHCore 的现代算法：密钥交换 `diffie-hellman-group16-sha512`、
    /// `diffie-hellman-group14-sha256`，RSA 主机密钥（`rsa-sha2-512`、`rsa-sha2-256`），加密 AES-CTR +
    /// `hmac-sha2-256` / `hmac-sha2-512`（ETM 在前），排序见 `SSHAlgorithmsPresetSchemes`。
    public static let standard = SSHAlgorithms(
        transportProtectionSchemes: Constants.bundledTransportProtectionSchemes
            + SSHAlgorithmsPresetSchemes.standardAESCTRSchemes,
        keyExchangeAlgorithms: builtInKeyExchangeAlgorithms + SSHDiffieHellmanAlgorithm.modern.map(\.name),
        hostKeyAlgorithms: builtInHostKeyAlgorithms + SSHRSASignatureAlgorithm.modern.map(\.name)
    )

    /// ⚠️ 只为连老设备（旧的网络设备、嵌入式 sshd）：`.standard` 再加 SHA-1 的 `ssh-rsa`（主机密钥与用户认证）、
    /// `diffie-hellman-group14-sha1`、AES-CTR + `hmac-sha1`（ETM 在前）。要用户明确选用；它会触发进程级的
    /// `SSHAlgorithms.registerLegacyAlgorithms()`（不影响别的连接，见那里的说明）。
    public static let legacyCompatible = SSHAlgorithms(
        transportProtectionSchemes: standard.transportProtectionSchemes
            + SSHAlgorithmsPresetSchemes.legacyAESCTRSchemes,
        keyExchangeAlgorithms: standard.keyExchangeAlgorithms + SSHDiffieHellmanAlgorithm.legacy.map(\.name),
        hostKeyAlgorithms: standard.hostKeyAlgorithms + SSHRSASignatureAlgorithm.legacy.map(\.name),
        allowsLegacyAlgorithms: true
    )

    // MARK: 实际交给 NIOSSH 的

    /// 去掉了未经允许的旧算法的加密方式。
    var effectiveTransportProtectionSchemes: [SSHTransportProtections.Scheme] {
        guard !allowsLegacyAlgorithms else { return transportProtectionSchemes }
        let legacy = Set(SSHTransportProtections.legacy.map { ObjectIdentifier($0) })
        return transportProtectionSchemes.filter { !legacy.contains(ObjectIdentifier($0)) }
    }

    /// 去掉了未经允许的旧算法的密钥交换算法名。
    var effectiveKeyExchangeAlgorithms: [String] {
        guard !allowsLegacyAlgorithms else { return keyExchangeAlgorithms }
        let legacy = Set(SSHDiffieHellmanAlgorithm.legacy.map(\.name))
        return keyExchangeAlgorithms.filter { !legacy.contains($0) }
    }

    /// 去掉了未经允许的旧算法的主机密钥算法名。
    var effectiveHostKeyAlgorithms: [String] {
        guard !allowsLegacyAlgorithms else { return hostKeyAlgorithms }
        let legacy = Set(SSHRSASignatureAlgorithm.legacy.map(\.name))
        return hostKeyAlgorithms.filter { !legacy.contains($0) }
    }

    /// 这条连接要不要先登记旧算法（进程级）：只有真的会用到 SHA-1 主机签名或 group14-sha1 时。
    /// 用户认证的 `ssh-rsa` 签名是本端写出的，不需要登记。
    var requiresLegacyRegistration: Bool {
        allowsLegacyAlgorithms
            && (hostKeyAlgorithms.contains { SSHRSASignatureAlgorithm(name: $0)?.isLegacy == true }
                || keyExchangeAlgorithms.contains(where: { SSHDiffieHellmanAlgorithm(name: $0)?.isLegacy == true }))
    }
}

/// 预设里 USSHCore 的 AES-CTR 组合——要调整预设的加密方式就改这里（`SSHAlgorithmPresetTests` 钉着确切内容）。
///
/// 排序：NIOSSH 自带的 AES-GCM 永远在最前（AEAD，不受 Terrapin 影响），然后是 AES-CTR + ETM 的 MAC，最后
/// AES-CTR + 普通（encrypt-and-MAC）MAC。NIOSSH 按数组里第一次出现的顺序得出加密名与 MAC 名的偏好列表，
/// 所以 MAC 的偏好是 `hmac-sha2-256-etm` > `hmac-sha2-512-etm` > `hmac-sha2-256` > `hmac-sha2-512`，和 OpenSSH 一样。
///
/// 为什么现在能放 ETM 与 `hmac-sha2-512`：
/// - **strict KEX**（NIOSSH 补丁 0007，Terrapin / CVE-2023-48795 的对策）：受影响的正是 `-etm` 的 MAC 与
///   chacha20-poly1305。strict KEX 只在对端也支持时生效（OpenSSH 9.6+），对付不支持的老服务器，靠的是 AES-GCM
///   排在 ETM 前面——双方都有 AES-GCM 时根本协商不到 ETM。
/// - **RFC 4253 §7.2 的密钥加长**（补丁 0003）：自带的 curve25519 / ECDH 推导会话密钥也会加长了，
///   要 64 字节 MAC 密钥的 `hmac-sha2-512` 不再握手失败。
enum SSHAlgorithmsPresetSchemes {
    private typealias CTR<Cipher: SSHAESCTRCipher, MAC: SSHHMACAlgorithm> = SSHAESCTRTransportProtection<Cipher, MAC>

    /// `.standard`：AES-CTR（256 > 192 > 128）× ETM（SHA2-256 > SHA2-512），再 × 普通 MAC（同序）。
    static let standardAESCTRSchemes: [SSHTransportProtections.Scheme] = [
        CTR<SSHAES256CTR, SSHHMACSHA256ETM>.self, CTR<SSHAES256CTR, SSHHMACSHA512ETM>.self,
        CTR<SSHAES192CTR, SSHHMACSHA256ETM>.self, CTR<SSHAES192CTR, SSHHMACSHA512ETM>.self,
        CTR<SSHAES128CTR, SSHHMACSHA256ETM>.self, CTR<SSHAES128CTR, SSHHMACSHA512ETM>.self,
        CTR<SSHAES256CTR, SSHHMACSHA256>.self, CTR<SSHAES256CTR, SSHHMACSHA512>.self,
        CTR<SSHAES192CTR, SSHHMACSHA256>.self, CTR<SSHAES192CTR, SSHHMACSHA512>.self,
        CTR<SSHAES128CTR, SSHHMACSHA256>.self, CTR<SSHAES128CTR, SSHHMACSHA512>.self,
    ]

    /// `.legacyCompatible` 额外加的：AES-CTR × `hmac-sha1-etm@openssh.com`，再 × `hmac-sha1`。
    static let legacyAESCTRSchemes: [SSHTransportProtections.Scheme] = [
        CTR<SSHAES256CTR, SSHHMACSHA1ETM>.self, CTR<SSHAES192CTR, SSHHMACSHA1ETM>.self,
        CTR<SSHAES128CTR, SSHHMACSHA1ETM>.self,
        CTR<SSHAES256CTR, SSHHMACSHA1>.self, CTR<SSHAES192CTR, SSHHMACSHA1>.self,
        CTR<SSHAES128CTR, SSHHMACSHA1>.self,
    ]
}
