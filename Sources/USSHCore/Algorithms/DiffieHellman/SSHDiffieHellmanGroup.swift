import BigInt
import Crypto
import Foundation

/// RFC 3526 的 MODP 群（安全素数 p，生成元 g = 2）。
public struct SSHDiffieHellmanGroup: Hashable, Sendable {
    /// 便于日志与测试的名字，如 `group14`。
    public let name: String
    let prime: BigUInt
    let generator: BigUInt
    /// 私钥指数的位数。
    ///
    /// RFC 4253 §8 只要求 1 < x < q；RFC 8268 §4 要求指数至少是群安全强度的两倍
    /// （group14 约 112 位 → ≥ 224；group16 约 150 位 → ≥ 300）。这里两组都取 512 位，
    /// 与 OpenSSH 的做法（`dh_gen_key` 用 2 × 所需密钥位数，最多 2 × 256）一致，远小于 q 的长度，
    /// 所以天然落在 (1, q) 内。指数短一些是为了大数模幂不至于太慢（见 README 的安全说明）。
    public let privateExponentBits: Int

    /// 素数 p 的大端字节串（无前导零）。
    public var primeBytes: [UInt8] { self.prime.sshMagnitudeBytes }

    /// 素数 p 的位数。
    public var primeBitCount: Int { self.prime.bitWidth }

    /// 2048 位 MODP 群（RFC 3526 §3，SSH 里叫 group14）。
    public static let group14 = SSHDiffieHellmanGroup(
        name: "group14",
        primeHex: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF
            """,
        privateExponentBits: 512
    )

    /// 4096 位 MODP 群（RFC 3526 §5，SSH 里叫 group16）。
    public static let group16 = SSHDiffieHellmanGroup(
        name: "group16",
        primeHex: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
            A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
            ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
            D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
            08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7
            88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8
            DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2
            233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9
            93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF
            """,
        privateExponentBits: 512
    )

    private init(name: String, primeHex: String, privateExponentBits: Int) {
        self.name = name
        // 常量写在源码里，解析失败是编程错误。
        self.prime = BigUInt(primeHex.filter { !$0.isWhitespace }, radix: 16)!
        self.generator = 2
        self.privateExponentBits = privateExponentBits
    }

    /// RFC 4253 §8：「Values of 'e' or 'f' that are not in the range [1, p-1] MUST NOT be sent or
    /// accepted」。这里更严：0、1、p−1 都拒绝（1 与 p−1 只生成大小为 1、2 的子群，K 可被猜出），
    /// 也就是要求 1 < value < p − 1。
    func isValidPublicValue(_ value: BigUInt) -> Bool {
        value > 1 && value < self.prime - 1
    }
}

/// 交换哈希与密钥推导用的哈希函数。
public enum SSHExchangeHashFunction: Hashable, Sendable {
    case sha1
    case sha256
    case sha512

    public var digestByteCount: Int {
        switch self {
        case .sha1: return Insecure.SHA1.Digest.byteCount
        case .sha256: return SHA256.Digest.byteCount
        case .sha512: return SHA512.Digest.byteCount
        }
    }

    func hash<Bytes: DataProtocol>(_ data: Bytes) -> [UInt8] {
        switch self {
        case .sha1: return Array(Insecure.SHA1.hash(data: data))
        case .sha256: return Array(SHA256.hash(data: data))
        case .sha512: return Array(SHA512.hash(data: data))
        }
    }
}

/// 有限域 Diffie-Hellman 密钥交换算法（RFC 4253 §8、RFC 8268）。
public enum SSHDiffieHellmanAlgorithm: String, CaseIterable, Hashable, Sendable {
    case group16SHA512 = "diffie-hellman-group16-sha512"
    case group14SHA256 = "diffie-hellman-group14-sha256"
    /// **旧算法**：交换哈希用 SHA-1（RFC 8268 降为 MAY），只为连只认它的老设备。
    case group14SHA1 = "diffie-hellman-group14-sha1"

    /// 协商时用的名字。
    public var name: String { self.rawValue }

    public init?(name: String) {
        self.init(rawValue: name)
    }

    public var group: SSHDiffieHellmanGroup {
        switch self {
        case .group16SHA512: return .group16
        case .group14SHA256, .group14SHA1: return .group14
        }
    }

    public var hashFunction: SSHExchangeHashFunction {
        switch self {
        case .group16SHA512: return .sha512
        case .group14SHA256: return .sha256
        case .group14SHA1: return .sha1
        }
    }

    public var isLegacy: Bool { self == .group14SHA1 }

    /// 默认可用的，按偏好排序（与 OpenSSH 的默认顺序一致：group16 先于 group14）。
    /// 都排在 NIOSSH 自带的 curve25519 / ECDH 之后。
    public static let modern: [SSHDiffieHellmanAlgorithm] = [.group16SHA512, .group14SHA256]

    /// 需要调用方明确选用的。
    public static let legacy: [SSHDiffieHellmanAlgorithm] = [.group14SHA1]
}
