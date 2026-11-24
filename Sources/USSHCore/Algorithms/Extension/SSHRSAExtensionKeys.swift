import Foundation
import NIOCore
import NIOSSH

// RSA 内核（`SSHRSAPublicKey` / `SSHRSAPrivateKey` / `SSHRSASignature`）接到 NIOSSH 的密钥扩展接口上
// （`ThirdParty/swift-nio-ssh/EXTENSION-API.md` 第一节）。
//
// 名字（RFC 8332）：公钥 blob 的格式名永远是 `ssh-rsa`（`publicKeyPrefix`）；签名算法名
// `rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa`（SHA-1）出现在签名 blob、主机密钥算法列表与 userauth 里。
// NIOSSH 按类型区分算法：一个签名算法一个签名类型、一个私钥类型，所以签名与私钥都是按算法特化的泛型。
// 公钥只有一个类型（一个格式名只能登记给一个公钥类型）。
//
// 登记见 `SSHAlgorithms.registerStandardAlgorithms()` / `registerLegacyAlgorithms()`，不要在别处登记。

/// 一种 RSA 签名算法在扩展接口上的标记（只用作泛型参数）。
package protocol SSHRSAExtensionAlgorithm: Sendable {
    static var algorithm: SSHRSASignatureAlgorithm { get }
}

/// `rsa-sha2-512`。
package enum SSHRSAExtensionSHA512: SSHRSAExtensionAlgorithm {
    package static var algorithm: SSHRSASignatureAlgorithm { .rsaSHA2_512 }
}

/// `rsa-sha2-256`。
package enum SSHRSAExtensionSHA256: SSHRSAExtensionAlgorithm {
    package static var algorithm: SSHRSASignatureAlgorithm { .rsaSHA2_256 }
}

/// `ssh-rsa`（SHA-1）。**旧算法**，只经 `registerLegacyAlgorithms()` 登记。
package enum SSHRSAExtensionSHA1: SSHRSAExtensionAlgorithm {
    package static var algorithm: SSHRSASignatureAlgorithm { .sshRSA }
}

// MARK: - 公钥

/// `ssh-rsa` 公钥在 NIOSSH 里的形态。
///
/// `write(to:)` 原样写回 `read(from:)` 读到的字节：NIOSSH 把解析出的主机密钥重新序列化进交换哈希（K_S），
/// 必须和服务器发来的逐字节相同。内核按 RFC 4251 §5 拒绝非最短的 mpint（与 OpenSSH 的
/// `sshbuf_get_bignum2` 一致），所以现在收到的字节总是规范的；照样存原始字节，免得内核哪天放宽了解析
/// 却忘了这里。
package struct SSHRSAExtensionPublicKey: NIOSSHPublicKeyProtocol {
    package static var publicKeyPrefix: String { SSHRSAPublicKey.keyType }

    package let key: SSHRSAPublicKey
    /// 格式名之后的字节（`mpint e ‖ mpint n`），收到的原样。
    private let body: [UInt8]

    package init(_ key: SSHRSAPublicKey) {
        var buffer = ByteBuffer()
        key.writeBody(to: &buffer)
        self.key = key
        self.body = Array(buffer.readableBytesView)
    }

    /// 规范编码，只用于相等与哈希：同一把钥匙不论怎么来的都相等。
    package var rawRepresentation: Data {
        var buffer = ByteBuffer()
        self.key.writeBody(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    package func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        // NIOSSH 已经核对过签名的算法就是期望的那个（主机密钥：协商出的算法；userauth：请求里的算法名），
        // 这里按签名自己的类型（= 算法）验，内核再核一遍签名与算法一致。
        guard let rsa = signature as? any SSHRSAExtensionSignatureCarrier else {
            return false
        }
        let algorithm = rsa.signature.algorithm
        guard self.key.isValidSignature(rsa.signature, for: data, algorithm: algorithm) else {
            return false
        }
        SSHRSAVerificationRecord.record(algorithm: algorithm, keyBlob: self.blob)
        return true
    }

    package func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(self.body)
    }

    /// 完整的公钥 blob（格式名 + 收到的字节），即 `NIOSSHPublicKey.write(to:)` 写出的东西。
    var blob: [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeSSHWireString(Self.publicKeyPrefix)
        buffer.writeBytes(self.body)
        return Array(buffer.readableBytesView)
    }

    /// `buffer` 是格式名之后的剩余部分，可能比公钥长（NIOSSH 有的调用点给的是整条报文的剩余部分）：
    /// 只读两个 mpint，不要求读完；失败时读指针不动（内核保证）。
    package static func read(from buffer: inout ByteBuffer) throws -> SSHRSAExtensionPublicKey {
        // 读之前留一份（ByteBuffer 是写时复制，不拷数据）：读过的区间不能再从原缓冲 get。
        var before = buffer
        let key = try SSHRSAPublicKey(readingBodyFrom: &buffer)
        let consumed = buffer.readerIndex - before.readerIndex
        let body = before.readBytes(length: consumed)!
        return SSHRSAExtensionPublicKey(key: key, body: body)
    }

    private init(key: SSHRSAPublicKey, body: [UInt8]) {
        self.key = key
        self.body = body
    }
}

// MARK: - 签名

/// 让公钥不必逐个枚举签名的泛型特化就能取出内核签名。
package protocol SSHRSAExtensionSignatureCarrier: Sendable {
    var signature: SSHRSASignature { get }
}

/// 一种算法的 RSA 签名：签名 blob 中算法名之后是 `string 签名`。
package struct SSHRSAExtensionSignature<Algorithm: SSHRSAExtensionAlgorithm>: NIOSSHSignatureProtocol,
    SSHRSAExtensionSignatureCarrier
{
    package static var signaturePrefix: String { Algorithm.algorithm.name }

    package let signature: SSHRSASignature

    package init(_ signature: SSHRSASignature) {
        precondition(signature.algorithm == Algorithm.algorithm, "签名算法与类型不符")
        self.signature = signature
    }

    package var rawRepresentation: Data { Data(self.signature.bytes) }

    package func write(to buffer: inout ByteBuffer) -> Int {
        self.signature.writeBody(to: &buffer)
    }

    package static func read(from buffer: inout ByteBuffer) throws -> SSHRSAExtensionSignature<Algorithm> {
        SSHRSAExtensionSignature(try SSHRSASignature(algorithm: Algorithm.algorithm, readingBodyFrom: &buffer))
    }
}

// MARK: - 私钥

/// 按一种算法签名的 RSA 私钥。同一把钥匙要以几种算法用，就包几个（userauth 逐个试、主机密钥逐个提供）。
package struct SSHRSAExtensionPrivateKey<Algorithm: SSHRSAExtensionAlgorithm>: NIOSSHPrivateKeyProtocol {
    package static var keyPrefix: String { Algorithm.algorithm.name }

    package let key: SSHRSAPrivateKey

    package init(_ key: SSHRSAPrivateKey) {
        self.key = key
    }

    package var publicKey: NIOSSHPublicKeyProtocol {
        SSHRSAExtensionPublicKey(self.key.publicKey)
    }

    package func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        SSHRSAExtensionSignature<Algorithm>(try self.key.signature(for: data, algorithm: Algorithm.algorithm))
    }
}

// MARK: - 公开的包装

extension NIOSSHPublicKey {
    /// 把 RSA 公钥包成 NIOSSH 的公钥（用于 `SSHHostKeyValidation.trustedKeys`、比较、写 OpenSSH 格式）。
    ///
    /// 要让 NIOSSH 认得服务器发来的 RSA 主机密钥、或解析 `ssh-rsa …` 的 OpenSSH 公钥行，
    /// 先 `SSHAlgorithms.registerStandardAlgorithms()`（建连接时会自动登记）。
    public init(rsaPublicKey: SSHRSAPublicKey) {
        self.init(custom: SSHRSAExtensionPublicKey(rsaPublicKey))
    }

    /// 是 `ssh-rsa` 公钥时取出它，否则 `nil`。
    public var rsaPublicKey: SSHRSAPublicKey? {
        var buffer = ByteBuffer()
        self.write(to: &buffer)
        return try? SSHRSAPublicKey(sshBlob: buffer.readableBytesView)
    }
}

extension NIOSSHPrivateKey {
    /// 把 RSA 私钥包成以 `algorithm` 签名的 NIOSSH 私钥。
    ///
    /// 给服务端当主机密钥用（测试服务端）：同一把钥匙要以几种算法提供，就包几个放进 `hostKeys`。
    /// 客户端的用户认证不要用它，用 `SSHAuthenticationMethod.rsaPrivateKey`（会按算法依次尝试）。
    /// 旧算法 `ssh-rsa` 只有在 `SSHAlgorithms.registerLegacyAlgorithms()` 之后对端才认。
    public init(rsaPrivateKey: SSHRSAPrivateKey, algorithm: SSHRSASignatureAlgorithm) {
        switch algorithm {
        case .rsaSHA2_512: self.init(custom: SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA512>(rsaPrivateKey))
        case .rsaSHA2_256: self.init(custom: SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA256>(rsaPrivateKey))
        case .sshRSA: self.init(custom: SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA1>(rsaPrivateKey))
        }
    }
}
