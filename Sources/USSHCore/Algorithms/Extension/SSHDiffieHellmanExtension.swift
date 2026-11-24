import Crypto
import NIOSSH

// 有限域 DH 内核（`SSHDiffieHellmanKeyExchange`）接到 NIOSSH 的密钥交换扩展接口上
// （`ThirdParty/swift-nio-ssh/EXTENSION-API.md` 第二节）。
//
// 扩展接口只要数学：本端公开值与共享秘密 K。交换哈希 H、主机签名的校验、会话密钥推导（含 RFC 4253 §7.2
// 的加长）都由 NIOSSH 按 `Hasher` 自己做，所以这里只调内核的 `localPublicValue` 与 `sharedSecret`，
// 内核里拼 H、推导密钥的那一半不经过这里。
//
// 耗时：模幂在连接的 EventLoop 上同步算（`init()` 一次、`sharedSecret` 一次），Release 下 group14 每次约
// 17 ms、group16 约 66 ms（见 Algorithms/README.md 的安全说明；握手实测见 `SSHDiffieHellmanHandshakeTests`）。
// 换钥时同样。没有挪出 EventLoop：那要改 NIOSSH 的密钥交换状态机，不值得。

/// 一种 DH 算法在扩展接口上的标记（只用作泛型参数）。
package protocol SSHDiffieHellmanExtensionVariant: Sendable {
    associatedtype Hasher: HashFunction
    static var algorithm: SSHDiffieHellmanAlgorithm { get }
}

/// `diffie-hellman-group16-sha512`。
package enum SSHDiffieHellmanGroup16SHA512: SSHDiffieHellmanExtensionVariant {
    package typealias Hasher = SHA512
    package static var algorithm: SSHDiffieHellmanAlgorithm { .group16SHA512 }
}

/// `diffie-hellman-group14-sha256`。
package enum SSHDiffieHellmanGroup14SHA256: SSHDiffieHellmanExtensionVariant {
    package typealias Hasher = SHA256
    package static var algorithm: SSHDiffieHellmanAlgorithm { .group14SHA256 }
}

/// `diffie-hellman-group14-sha1`。**旧算法**，只经 `registerLegacyAlgorithms()` 登记。
package enum SSHDiffieHellmanGroup14SHA1: SSHDiffieHellmanExtensionVariant {
    package typealias Hasher = Insecure.SHA1
    package static var algorithm: SSHDiffieHellmanAlgorithm { .group14SHA1 }
}

/// 一次有限域 DH 交换（NIOSSH 每次交换——首次与每次换钥——新建一个实例，只在一个 EventLoop 上用）。
package struct SSHDiffieHellmanExtensionKeyExchange<Variant: SSHDiffieHellmanExtensionVariant>:
    NIOSSHKeyExchangeAlgorithmProtocol
{
    package typealias Hasher = Variant.Hasher

    package static var keyExchangeAlgorithmNames: [Substring] { [Substring(Variant.algorithm.name)] }

    package static var publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding { .mpint }

    /// 引用类型：NIOSSH 在状态机里复制这个结构体，复制品共享同一个只能用一次的临时私钥。
    private let exchange: SSHDiffieHellmanKeyExchange

    /// 本端公开值（客户端的 e / 服务端的 f），`init()` 里算好。
    package let publicValue: [UInt8]

    package init() {
        // 内核的 role 只决定它自己拼 H 时 e、f 的先后；这里不用内核拼 H，两端都可以当客户端建。
        let exchange = SSHDiffieHellmanKeyExchange(algorithm: Variant.algorithm, role: .client)
        self.exchange = exchange
        self.publicValue = exchange.localPublicValue
    }

    /// 对端值的校验在这里做，不靠 NIOSSH（它只拒绝负数与 K = 0）：不在 (1, p − 1) 内（0、1、p − 1、≥ p）
    /// 抛 `SSHDiffieHellmanError.invalidPeerPublicValue`，NIOSSH 随之中止交换。同一个实例（及其复制品）
    /// 只能算一次，再调抛 `.alreadyCompleted`。
    package mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] {
        try self.exchange.sharedSecret(peerPublicValue: peerPublicValue)
    }
}
