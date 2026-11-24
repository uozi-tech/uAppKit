import BigInt
import Foundation
import NIOCore

/// 有限域 DH 的错误。
public enum SSHDiffieHellmanError: Error, Hashable, Sendable {
    /// 对端的公开值不在 (1, p − 1) 内（RFC 4253 §8）。
    case invalidPeerPublicValue
    /// 算出的共享秘密是退化值（≤ 1）。对端公开值合法时不会发生，留作防御。
    case degenerateSharedSecret
    /// 同一个临时私钥已经用过一次了。
    case alreadyCompleted
    /// 测试用入口给的私钥指数不在 (1, q) 内。
    case invalidPrivateExponent
}

/// 交换哈希 H 的输入（RFC 4253 §8）：除 e、f、K 之外的部分。
public struct SSHExchangeHashInputs: Sendable {
    /// V_C：客户端的版本串，不含结尾的 CR LF。
    public var clientVersion: [UInt8]
    /// V_S：服务端的版本串，不含结尾的 CR LF。
    public var serverVersion: [UInt8]
    /// I_C：客户端 SSH_MSG_KEXINIT 的 payload（从消息号 20 开始，不含包长、填充）。
    public var clientKeyExchangeInit: [UInt8]
    /// I_S：服务端 SSH_MSG_KEXINIT 的 payload。
    public var serverKeyExchangeInit: [UInt8]
    /// K_S：服务端主机公钥 blob。
    public var serverHostKey: [UInt8]

    public init(
        clientVersion: [UInt8],
        serverVersion: [UInt8],
        clientKeyExchangeInit: [UInt8],
        serverKeyExchangeInit: [UInt8],
        serverHostKey: [UInt8]
    ) {
        self.clientVersion = clientVersion
        self.serverVersion = serverVersion
        self.clientKeyExchangeInit = clientKeyExchangeInit
        self.serverKeyExchangeInit = serverKeyExchangeInit
        self.serverHostKey = serverHostKey
    }

    public init(
        clientVersion: String,
        serverVersion: String,
        clientKeyExchangeInit: [UInt8],
        serverKeyExchangeInit: [UInt8],
        serverHostKey: [UInt8]
    ) {
        self.init(
            clientVersion: Array(clientVersion.utf8),
            serverVersion: Array(serverVersion.utf8),
            clientKeyExchangeInit: clientKeyExchangeInit,
            serverKeyExchangeInit: serverKeyExchangeInit,
            serverHostKey: serverHostKey
        )
    }
}

/// 一次 DH 交换的结果。
public struct SSHDiffieHellmanResult: Sendable {
    public let algorithm: SSHDiffieHellmanAlgorithm
    /// e（客户端公开值），大端无符号、无前导零。
    public let clientPublicValue: [UInt8]
    /// f（服务端公开值），大端无符号、无前导零。
    public let serverPublicValue: [UInt8]
    /// 共享秘密 K 按 SSH `mpint` 编码（含 `uint32` 长度前缀），即密钥推导
    /// `HASH(K ‖ H ‖ X ‖ session_id)` 里 K 的那一段字节。**是秘密**，用完别留着。
    public let sharedSecretMPInt: [UInt8]
    /// 交换哈希 H。第一次交换的 H 也是整条连接的 session_id；主机密钥签的就是它。
    public let exchangeHash: [UInt8]

    /// RFC 4253 §7.2 的密钥推导，带长度扩展：
    /// `K1 = HASH(K ‖ H ‖ X ‖ session_id)`，`Kn = HASH(K ‖ H ‖ K1 ‖ … ‖ Kn−1)`，拼起来截到 `length`。
    /// `letter` 是 `A`…`F`（IV、加密密钥、MAC 密钥 × 两个方向）。
    public func deriveKey(letter: UInt8, sessionID: [UInt8], length: Int) -> [UInt8] {
        SSHKeyDerivation.derive(
            hash: self.algorithm.hashFunction,
            sharedSecretMPInt: self.sharedSecretMPInt,
            exchangeHash: self.exchangeHash,
            letter: letter,
            sessionID: sessionID,
            length: length
        )
    }
}

/// RFC 4253 §7.2 的密钥推导（与具体密钥交换算法无关，只依赖哈希函数）。
public enum SSHKeyDerivation {
    public static func derive(
        hash: SSHExchangeHashFunction,
        sharedSecretMPInt: [UInt8],
        exchangeHash: [UInt8],
        letter: UInt8,
        sessionID: [UInt8],
        length: Int
    ) -> [UInt8] {
        precondition(length >= 0)
        var output = hash.hash(sharedSecretMPInt + exchangeHash + [letter] + sessionID)
        while output.count < length {
            output += hash.hash(sharedSecretMPInt + exchangeHash + output)
        }
        return Array(output.prefix(length))
    }
}

/// 有限域 Diffie-Hellman 的一端（RFC 4253 §8）：生成临时密钥对、校验对端公开值、算 K 和 H。
///
/// 客户端：`e = g^x mod p` 放进 SSH_MSG_KEXDH_INIT；收到 KEXDH_REPLY 里的 f 后 `complete`。
/// 服务端：`f = g^y mod p`；收到 KEXDH_INIT 里的 e 后 `complete`，再用主机私钥签 H。
///
/// 临时私钥只用一次：`complete` 之后就清掉，再调抛 `.alreadyCompleted`。
/// 大数运算（attaswift/BigInt）不是恒定时间的，见 README 的安全说明。
public struct SSHDiffieHellmanKeyExchange: Sendable {
    public enum Role: Hashable, Sendable {
        case client
        case server
    }

    public let algorithm: SSHDiffieHellmanAlgorithm
    public let role: Role
    /// 本端公开值（客户端的 e / 服务端的 f），大端无符号、无前导零。
    public let localPublicValue: [UInt8]
    private var privateExponent: BigUInt?

    /// 用系统 CSPRNG 生成临时私钥。
    public init(algorithm: SSHDiffieHellmanAlgorithm, role: Role) {
        let group = algorithm.group
        var rng = SystemRandomNumberGenerator()
        var exponent: BigUInt
        repeat {
            exponent = BigUInt.randomInteger(withMaximumWidth: group.privateExponentBits, using: &rng)
        } while exponent <= 1
        self.init(algorithm: algorithm, role: role, validatedExponent: exponent)
    }

    /// 指定私钥指数（大端无符号），只给已知答案测试用。要求 1 < x < q = (p − 1) / 2。
    package init(algorithm: SSHDiffieHellmanAlgorithm, role: Role, privateExponent: [UInt8]) throws {
        let exponent = BigUInt(sshMagnitude: privateExponent)
        let q = (algorithm.group.prime - 1) >> 1
        guard exponent > 1, exponent < q else {
            throw SSHDiffieHellmanError.invalidPrivateExponent
        }
        self.init(algorithm: algorithm, role: role, validatedExponent: exponent)
    }

    private init(algorithm: SSHDiffieHellmanAlgorithm, role: Role, validatedExponent exponent: BigUInt) {
        let group = algorithm.group
        self.algorithm = algorithm
        self.role = role
        self.privateExponent = exponent
        self.localPublicValue = group.generator.power(exponent, modulus: group.prime).sshMagnitudeBytes
    }

    /// 校验对端公开值、算出 K，并按 `inputs` 拼出交换哈希 H。
    ///
    /// - Parameter peerPublicValue: 对端的 f（客户端）或 e（服务端），大端无符号，允许带前导零；
    ///   从线上读 `mpint` 时用非负读法（负数在读的时候就会被拒绝）。
    public mutating func complete(
        peerPublicValue: [UInt8],
        inputs: SSHExchangeHashInputs
    ) throws -> SSHDiffieHellmanResult {
        guard let exponent = self.privateExponent else {
            throw SSHDiffieHellmanError.alreadyCompleted
        }
        let group = self.algorithm.group
        let peer = BigUInt(sshMagnitude: peerPublicValue)
        guard group.isValidPublicValue(peer) else {
            throw SSHDiffieHellmanError.invalidPeerPublicValue
        }
        // 私钥只用这一次（校验失败时保留，调用方可以换一个合法的值重试——不会泄露什么，因为什么也没算）。
        self.privateExponent = nil

        let shared = peer.power(exponent, modulus: group.prime)
        guard shared > 1 else {
            throw SSHDiffieHellmanError.degenerateSharedSecret
        }
        let peerBytes = peer.sshMagnitudeBytes
        let (e, f) = self.role == .client ? (self.localPublicValue, peerBytes) : (peerBytes, self.localPublicValue)

        var sharedMPInt = ByteBuffer()
        sharedMPInt.writeSSHWireUnsignedMPInt(magnitude: shared.sshMagnitudeBytes)
        let sharedSecretMPInt = Array(sharedMPInt.readableBytesView)

        let exchangeHash = Self.exchangeHash(
            hash: self.algorithm.hashFunction,
            inputs: inputs,
            e: e,
            f: f,
            sharedSecretMPInt: sharedSecretMPInt
        )
        return SSHDiffieHellmanResult(
            algorithm: self.algorithm,
            clientPublicValue: e,
            serverPublicValue: f,
            sharedSecretMPInt: sharedSecretMPInt,
            exchangeHash: exchangeHash
        )
    }

    /// H = HASH(string V_C ‖ string V_S ‖ string I_C ‖ string I_S ‖ string K_S ‖ mpint e ‖ mpint f ‖ mpint K)。
    package static func exchangeHash(
        hash: SSHExchangeHashFunction,
        inputs: SSHExchangeHashInputs,
        e: [UInt8],
        f: [UInt8],
        sharedSecretMPInt: [UInt8]
    ) -> [UInt8] {
        var transcript = ByteBuffer()
        transcript.writeSSHWireString(inputs.clientVersion)
        transcript.writeSSHWireString(inputs.serverVersion)
        transcript.writeSSHWireString(inputs.clientKeyExchangeInit)
        transcript.writeSSHWireString(inputs.serverKeyExchangeInit)
        transcript.writeSSHWireString(inputs.serverHostKey)
        transcript.writeSSHWireUnsignedMPInt(magnitude: e)
        transcript.writeSSHWireUnsignedMPInt(magnitude: f)
        transcript.writeBytes(sharedSecretMPInt)
        return hash.hash(transcript.readableBytesView)
    }
}
