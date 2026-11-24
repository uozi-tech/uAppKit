import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import _CryptoExtras

// MARK: - 加密与 MAC 的参数

/// AES-CTR 的一种密钥长度（RFC 4344 §4）。
public protocol SSHAESCTRCipher: SendableMetatype {
    /// 协商时用的名字，如 `aes128-ctr`。
    static var name: String { get }
    /// 密钥字节数：16 / 24 / 32。
    static var keyByteCount: Int { get }
}

/// 一种 HMAC（RFC 4253 §6.4、RFC 6668、OpenSSH PROTOCOL §1.5 的 `-etm@openssh.com`）。
public protocol SSHHMACAlgorithm: SendableMetatype {
    associatedtype Hash: HashFunction
    /// 协商时用的名字，如 `hmac-sha2-256-etm@openssh.com`。
    static var name: String { get }
    /// `true` = encrypt-then-MAC：长度字段明文传、MAC 覆盖序号 + 长度 + 密文；
    /// `false` = encrypt-and-MAC（RFC 4253）：长度字段也加密、MAC 覆盖序号 + 明文包。
    static var encryptThenMAC: Bool { get }
}

extension SSHHMACAlgorithm {
    /// MAC 密钥与输出长度都等于摘要长度（RFC 4253 §6.4、RFC 6668）。
    static var keyByteCount: Int { Hash.Digest.byteCount }
    static var outputByteCount: Int { Hash.Digest.byteCount }
}

public enum SSHAES128CTR: SSHAESCTRCipher {
    public static var name: String { "aes128-ctr" }
    public static var keyByteCount: Int { 16 }
}

public enum SSHAES192CTR: SSHAESCTRCipher {
    public static var name: String { "aes192-ctr" }
    public static var keyByteCount: Int { 24 }
}

public enum SSHAES256CTR: SSHAESCTRCipher {
    public static var name: String { "aes256-ctr" }
    public static var keyByteCount: Int { 32 }
}

public enum SSHHMACSHA256: SSHHMACAlgorithm {
    public typealias Hash = SHA256
    public static var name: String { "hmac-sha2-256" }
    public static var encryptThenMAC: Bool { false }
}

public enum SSHHMACSHA256ETM: SSHHMACAlgorithm {
    public typealias Hash = SHA256
    public static var name: String { "hmac-sha2-256-etm@openssh.com" }
    public static var encryptThenMAC: Bool { true }
}

public enum SSHHMACSHA512: SSHHMACAlgorithm {
    public typealias Hash = SHA512
    public static var name: String { "hmac-sha2-512" }
    public static var encryptThenMAC: Bool { false }
}

public enum SSHHMACSHA512ETM: SSHHMACAlgorithm {
    public typealias Hash = SHA512
    public static var name: String { "hmac-sha2-512-etm@openssh.com" }
    public static var encryptThenMAC: Bool { true }
}

/// 旧算法，只为连老设备。SHA-1 做 HMAC 目前没有已知的实际攻击，但已不推荐。
public enum SSHHMACSHA1: SSHHMACAlgorithm {
    public typealias Hash = Insecure.SHA1
    public static var name: String { "hmac-sha1" }
    public static var encryptThenMAC: Bool { false }
}

/// 旧算法，见 `SSHHMACSHA1`。
public enum SSHHMACSHA1ETM: SSHHMACAlgorithm {
    public typealias Hash = Insecure.SHA1
    public static var name: String { "hmac-sha1-etm@openssh.com" }
    public static var encryptThenMAC: Bool { true }
}

// MARK: - 传输保护

/// AES-CTR + HMAC 的 SSH 传输保护（RFC 4253 §6、RFC 4344、RFC 6668、OpenSSH PROTOCOL）。
///
/// NIOSSH 按「加密名 + MAC 名」一对来协商，所以每一对是一个具体类型（泛型参数的一个组合）。
///
/// 包格式（RFC 4253 §6）：`uint32 packet_length ‖ byte padding_length ‖ payload ‖ padding ‖ mac`。
/// - encrypt-and-MAC：前四段整体加密；`mac = HMAC(K, uint32 seq ‖ 明文前四段)`，MAC 不加密。
/// - encrypt-then-MAC：`packet_length` 明文，其余三段加密；`mac = HMAC(K, uint32 seq ‖ packet_length ‖ 密文)`。
///   先验 MAC 再解密，长度字段不经解密就能读，没有 E&M 那种「解出长度再等数据」的长度预言。
///
/// CTR 计数器按方向各一个，跨包连续（见 `SSHCTRCounter`）。NIOSSH 把同一个实例同时交给包解析器
/// （入站）和序列化器（出站），换钥时新建实例，所以两个方向的状态互不影响。
///
/// 只在所属 channel 的 EventLoop 上被调用（NIOSSH 保证），因此不是 `Sendable`。
public final class SSHAESCTRTransportProtection<Cipher: SSHAESCTRCipher, MAC: SSHHMACAlgorithm> {
    private struct Direction {
        var encryptionKey: SymmetricKey
        var macKey: SymmetricKey
        var counter: SSHCTRCounter
        /// 这组密钥的初始 IV（计数器从它开始），只用来在 `updateKeys` 时识别重复。
        var initialIV: [UInt8]
    }

    private var inbound: Direction
    private var outbound: Direction

    private static var blockSize: Int { 16 }

    public init(initialKeys: NIOSSHSessionKeys) throws {
        (self.inbound, self.outbound) = try Self.directions(from: initialKeys)
    }

    private static func directions(from keys: NIOSSHSessionKeys) throws -> (inbound: Direction, outbound: Direction) {
        guard keys.inboundEncryptionKey.bitCount == Cipher.keyByteCount * 8,
            keys.outboundEncryptionKey.bitCount == Cipher.keyByteCount * 8,
            keys.inboundMACKey.bitCount == MAC.keyByteCount * 8,
            keys.outboundMACKey.bitCount == MAC.keyByteCount * 8
        else {
            throw SSHTransportProtectionError.invalidKeySize
        }
        let inbound = Direction(
            encryptionKey: keys.inboundEncryptionKey,
            macKey: keys.inboundMACKey,
            counter: try SSHCTRCounter(iv: keys.initialInboundIV),
            initialIV: keys.initialInboundIV
        )
        let outbound = Direction(
            encryptionKey: keys.outboundEncryptionKey,
            macKey: keys.outboundMACKey,
            counter: try SSHCTRCounter(iv: keys.initialOutboundIV),
            initialIV: keys.initialOutboundIV
        )
        return (inbound, outbound)
    }

    // MARK: 内部工具

    /// 原地对 `buffer` 的 `[index, index+length)` 应用 CTR 密钥流，并把计数器前进相应块数。
    /// `length` 必须是块大小的整数倍（SSH 的包总是如此，调用方已核对）。
    private static func applyKeystream(
        _ buffer: inout ByteBuffer,
        at index: Int,
        length: Int,
        direction: inout Direction
    ) throws {
        precondition(length % Self.blockSize == 0, "CTR 段必须是整块")
        guard length > 0 else { return }
        guard let view = buffer.viewBytes(at: index, length: length) else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        let output = try AES._CTR.encrypt(
            view,
            using: direction.encryptionKey,
            nonce: AES._CTR.Nonce(nonceBytes: direction.counter.block)
        )
        buffer.setContiguousBytes(output, at: index)
        direction.counter.advance(byBlocks: UInt64(length / Self.blockSize))
    }

    /// `HMAC(K, uint32 seq ‖ buffer[index, index+length))`。
    private static func authenticationCode(
        _ buffer: ByteBuffer,
        at index: Int,
        length: Int,
        sequenceNumber: UInt32,
        key: SymmetricKey
    ) throws -> HMAC<MAC.Hash>.MAC {
        guard let view = buffer.viewBytes(at: index, length: length) else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        var hmac = HMAC<MAC.Hash>(key: key)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { hmac.update(data: $0) }
        hmac.update(data: view)
        return hmac.finalize()
    }

    /// 校验 MAC。比较交给 swift-crypto 的 `MessageAuthenticationCode ==`，它是恒定时间的。
    private static func verifyAuthenticationCode(
        _ buffer: ByteBuffer,
        at index: Int,
        length: Int,
        macAt macIndex: Int,
        sequenceNumber: UInt32,
        key: SymmetricKey
    ) throws {
        let expected = try Self.authenticationCode(
            buffer,
            at: index,
            length: length,
            sequenceNumber: sequenceNumber,
            key: key
        )
        guard let received = buffer.viewBytes(at: macIndex, length: MAC.outputByteCount),
            expected == received
        else {
            throw SSHTransportProtectionError.authenticationFailure
        }
    }

    /// 校验 `packet_length`：去掉 MAC 后的包长（E&M 含长度字段四字节，ETM 不含）必须是块的整数倍，
    /// 且至少一块。最大长度由 NIOSSH 的解析器把关。
    private static func validatePacketLength(_ packetLength: UInt32) throws {
        let covered = MAC.encryptThenMAC ? UInt64(packetLength) : UInt64(packetLength) + 4
        guard covered >= UInt64(Self.blockSize), covered % UInt64(Self.blockSize) == 0 else {
            throw SSHTransportProtectionError.invalidPacketLength
        }
    }

    /// 从解密后的包里取出 payload：`[start+4]` 是 padding_length，payload 在 `[start+5, ...)`。
    private static func payloadSlice(_ buffer: ByteBuffer, packetStart start: Int, packetLength: Int) throws -> ByteBuffer {
        guard let paddingLength = buffer.getInteger(at: start + 4, as: UInt8.self) else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        let payloadLength = packetLength - 1 - Int(paddingLength)
        guard paddingLength >= 4, payloadLength >= 0,
            let payload = buffer.getSlice(at: start + 5, length: payloadLength)
        else {
            throw SSHTransportProtectionError.invalidPadding
        }
        return payload
    }
}

extension SSHAESCTRTransportProtection: NIOSSHTransportProtection {
    public static var cipherName: String { Cipher.name }

    public static var macName: String? { MAC.name }

    public static var cipherBlockSize: Int { Self.blockSize }

    public static var keySizes: ExpectedKeySizes {
        ExpectedKeySizes(ivSize: 16, encryptionKeySize: Cipher.keyByteCount, macKeySize: MAC.keyByteCount)
    }

    public var macBytes: Int { MAC.outputByteCount }

    public var lengthEncrypted: Bool { !MAC.encryptThenMAC }

    /// 换成新一组密钥：两个方向的计数器都从新的 IV 重新开始。
    ///
    /// NIOSSH 换钥时实际上是新建实例（`init(initialKeys:)`），不调这里；这里防误用：CTR 下同一（密钥, IV）
    /// 再从头开始就会重复密钥流（两段密文异或即得明文异或），所以任一方向的加密密钥与 IV 都和当前一样时抛
    /// `SSHTransportProtectionError.keyReuse`，状态不变。真正的换钥（RFC 4253 §9）推出的是全新的密钥。
    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        let (inbound, outbound) = try Self.directions(from: newKeys)
        if Self.reusesKeystream(inbound, self.inbound) || Self.reusesKeystream(outbound, self.outbound) {
            throw SSHTransportProtectionError.keyReuse
        }
        (self.inbound, self.outbound) = (inbound, outbound)
    }

    private static func reusesKeystream(_ new: Direction, _ current: Direction) -> Bool {
        // SymmetricKey 的 == 是恒定时间比较。
        new.encryptionKey == current.encryptionKey && new.initialIV == current.initialIV
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        // NIOSSH 保证此时至少有一块。ETM 的长度本来就是明文，只核对；E&M 先解开第一块再核对。
        if !MAC.encryptThenMAC {
            guard source.readableBytes >= Self.blockSize else {
                throw SSHTransportProtectionError.invalidCiphertextLength
            }
            try Self.applyKeystream(&source, at: source.readerIndex, length: Self.blockSize, direction: &self.inbound)
        }
        guard let packetLength = source.getInteger(at: source.readerIndex, as: UInt32.self) else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        try Self.validatePacketLength(packetLength)
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        // `source` 正好是一整个包：长度字段 + 包体 + MAC。E&M 时第一块已在 `decryptFirstBlock` 里解开。
        let start = source.readerIndex
        let total = source.readableBytes
        guard let rawLength = source.getInteger(at: start, as: UInt32.self) else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        try Self.validatePacketLength(rawLength)
        let packetLength = Int(rawLength)
        guard total == 4 + packetLength + MAC.outputByteCount else {
            throw SSHTransportProtectionError.invalidCiphertextLength
        }
        let macIndex = start + 4 + packetLength

        if MAC.encryptThenMAC {
            // 先验 MAC（覆盖序号 + 明文长度 + 密文），通过了才解密。
            try Self.verifyAuthenticationCode(
                source,
                at: start,
                length: 4 + packetLength,
                macAt: macIndex,
                sequenceNumber: sequenceNumber,
                key: self.inbound.macKey
            )
            try Self.applyKeystream(&source, at: start + 4, length: packetLength, direction: &self.inbound)
        } else {
            // E&M：解开剩下的块，再对整段明文验 MAC。
            let remaining = 4 + packetLength - Self.blockSize
            try Self.applyKeystream(
                &source,
                at: start + Self.blockSize,
                length: remaining,
                direction: &self.inbound
            )
            try Self.verifyAuthenticationCode(
                source,
                at: start,
                length: 4 + packetLength,
                macAt: macIndex,
                sequenceNumber: sequenceNumber,
                key: self.inbound.macKey
            )
        }

        let payload = try Self.payloadSlice(source, packetStart: start, packetLength: packetLength)
        source.moveReaderIndex(forwardBy: total)
        return payload
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        // 序列化器已写好整包明文（长度、填充都按 `lengthEncrypted` 与块大小算好），读指针在包头。
        let start = destination.readerIndex
        let total = destination.readableBytes
        let encryptedStart = MAC.encryptThenMAC ? start + 4 : start
        let encryptedLength = MAC.encryptThenMAC ? total - 4 : total
        guard encryptedLength > 0, encryptedLength % Self.blockSize == 0 else {
            throw SSHTransportProtectionError.invalidPacketLength
        }

        let mac: HMAC<MAC.Hash>.MAC
        if MAC.encryptThenMAC {
            try Self.applyKeystream(
                &destination,
                at: encryptedStart,
                length: encryptedLength,
                direction: &self.outbound
            )
            mac = try Self.authenticationCode(
                destination,
                at: start,
                length: total,
                sequenceNumber: sequenceNumber,
                key: self.outbound.macKey
            )
        } else {
            mac = try Self.authenticationCode(
                destination,
                at: start,
                length: total,
                sequenceNumber: sequenceNumber,
                key: self.outbound.macKey
            )
            try Self.applyKeystream(
                &destination,
                at: encryptedStart,
                length: encryptedLength,
                direction: &self.outbound
            )
        }
        mac.withUnsafeBytes { _ = destination.writeBytes($0) }
    }
}

extension SSHAESCTRTransportProtection: SendableMetatype {}
