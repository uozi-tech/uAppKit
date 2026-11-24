import Crypto
import Foundation
import NIOCore
import _CryptoExtras

/// `ssh-rsa` 公钥（RFC 4253 §6.6）：blob = `string "ssh-rsa" ‖ mpint e ‖ mpint n`。
///
/// RFC 8332 §3：三种签名算法（`rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa`）共用这一种公钥格式，
/// blob 里的类型名永远是 `ssh-rsa`；签名算法名只出现在签名 blob 和协商 / userauth 的算法字段里。
public struct SSHRSAPublicKey: Sendable {
    public static let keyType = "ssh-rsa"

    /// 能接受的最小模数位数。低于 2048 的仍接受（为了连老设备），但 `isWeak` 为真，调用方可据此提示或拒绝。
    public static let minimumModulusBits = 1024
    /// 不算弱的最小模数位数（NIST SP 800-131A、OpenSSH 的 `RequiredRSASize` 默认值）。
    public static let recommendedMinimumModulusBits = 2048
    /// 能接受的最大模数位数：BoringSSL 的 `OPENSSL_RSA_MAX_MODULUS_BITS`（8192）。签名与校验都走 BoringSSL，
    /// 更大的钥匙它根本不肯装（OpenSSH 自己的上限是 16384 位，这样的钥匙极少见，连不上的会以
    /// `.unsupportedModulusSize` 干净地失败）。
    public static let maximumModulusBits = 8192

    /// 模数 n，大端无符号、无前导零。
    public let modulus: [UInt8]
    /// 公钥指数 e，大端无符号、无前导零。
    public let publicExponent: [UInt8]

    let backing: _RSA.Signing.PublicKey

    /// 模数的位数。
    public var modulusBitCount: Int {
        // 构造时已保证 modulus 非空、首字节非零。
        (self.modulus.count - 1) * 8 + (8 - self.modulus[0].leadingZeroBitCount)
    }

    /// 模数的字节数，也是签名的长度。
    public var modulusByteCount: Int { self.modulus.count }

    /// 模数低于 2048 位。
    public var isWeak: Bool { self.modulusBitCount < Self.recommendedMinimumModulusBits }

    /// 由分量构造。`modulus` / `publicExponent` 是大端无符号字节串，允许带前导零。
    public init<N: Collection, E: Collection>(modulus: N, publicExponent: E) throws
    where N.Element == UInt8, E.Element == UInt8 {
        let n = SSHBytes.trimmingLeadingZeros(modulus)
        let e = SSHBytes.trimmingLeadingZeros(publicExponent)
        guard let lastN = n.last, let lastE = e.last else {
            throw SSHRSAError.invalidPublicKey
        }
        let bits = (n.count - 1) * 8 + (8 - n[0].leadingZeroBitCount)
        guard bits >= Self.minimumModulusBits, bits <= Self.maximumModulusBits else {
            throw SSHRSAError.unsupportedModulusSize(bits: bits)
        }
        // n 是两个奇素数之积，必为奇数；e 必须是 ≥ 3 的奇数，且比 n 小。
        guard lastN & 1 == 1, lastE & 1 == 1, e != [1], e.count <= n.count else {
            throw SSHRSAError.invalidPublicKey
        }
        do {
            self.backing = try _RSA.Signing.PublicKey(
                unsafeDERRepresentation: RSADEREncoding.pkcs1PublicKey(modulus: n, publicExponent: e)
            )
        } catch {
            throw SSHRSAError.invalidPublicKey
        }
        self.modulus = n
        self.publicExponent = e
    }

    // MARK: 线格式

    /// 解析完整的公钥 blob（含 `string "ssh-rsa"`），不允许多余字节。
    public init<Bytes: Collection>(sshBlob: Bytes) throws where Bytes.Element == UInt8 {
        var buffer = ByteBuffer(bytes: sshBlob)
        guard try buffer.readSSHWireIdentifier() == Self.keyType else {
            throw SSHRSAError.unexpectedKeyType
        }
        self = try Self(readingBodyFrom: &buffer)
        try buffer.requireFullyConsumed()
    }

    /// 完整的公钥 blob：`string "ssh-rsa" ‖ mpint e ‖ mpint n`。
    public var sshBlob: [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeSSHWireString(Self.keyType)
        self.writeBody(to: &buffer)
        return Array(buffer.readableBytesView)
    }

    /// 只读 blob 的主体（类型名之后的 `mpint e ‖ mpint n`）。给 NIOSSH 的密钥扩展接口用：
    /// 那边已经读掉了类型名。读完不要求缓冲为空。
    package init(readingBodyFrom buffer: inout ByteBuffer) throws {
        let original = buffer.readerIndex
        do {
            let e = try buffer.readSSHWireUnsignedMPInt()
            let n = try buffer.readSSHWireUnsignedMPInt()
            try self.init(modulus: n, publicExponent: e)
        } catch {
            buffer.moveReaderIndex(to: original)
            throw error
        }
    }

    /// 只写 blob 的主体（`mpint e ‖ mpint n`），返回写入字节数。
    @discardableResult
    package func writeBody(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHWireUnsignedMPInt(magnitude: self.publicExponent)
            + buffer.writeSSHWireUnsignedMPInt(magnitude: self.modulus)
    }

    // MARK: 校验

    /// 校验 `signature` 是不是本公钥用 `algorithm` 对 `data` 的签名。
    ///
    /// `algorithm` 是调用方期望的算法（协商出的主机密钥算法、或 userauth 请求里的算法名）：签名 blob 里的
    /// 算法与它不同直接判假，防止降级到 SHA-1。签名比模数短时按 RFC 8332 §3 左侧补零再验，比模数长判假。
    public func isValidSignature<D: DataProtocol>(
        _ signature: SSHRSASignature,
        for data: D,
        algorithm: SSHRSASignatureAlgorithm
    ) -> Bool {
        guard signature.algorithm == algorithm,
            let padded = SSHBytes.leftPadded(signature.bytes, to: self.modulusByteCount)
        else {
            return false
        }
        let raw = _RSA.Signing.RSASignature(rawRepresentation: padded)
        switch algorithm {
        case .rsaSHA2_512:
            return self.backing.isValidSignature(raw, for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        case .rsaSHA2_256:
            return self.backing.isValidSignature(raw, for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        case .sshRSA:
            return self.backing.isValidSignature(raw, for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
        }
    }
}

extension SSHRSAPublicKey: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modulus == rhs.modulus && lhs.publicExponent == rhs.publicExponent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.modulus)
        hasher.combine(self.publicExponent)
    }
}
