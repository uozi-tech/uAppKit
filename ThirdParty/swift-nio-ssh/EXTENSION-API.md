# NIOSSH 的两个扩展接口

补丁 0003 / 0004（见 [PATCHES.md](PATCHES.md)）给 NIOSSH 开的口子：NIOSSH 自己不带的公钥算法与密钥交换算法，
在 NIOSSH 之外实现、登记进来。这里是这两个接口的**完整公开 API**（以 `Sources/NIOSSH` 里的源码为准，
文档注释更细）。下面的代码都在 `import NIOSSH` 之后；测试里的玩具实现见
`Tests/NIOSSHTests/CustomKeyTests.swift`、`CustomKeyExchangeTests.swift`。

## 通用规则

- 注册表**进程级**、加锁、线程安全，只增不减（测试用的复位函数是 `internal` 的）。在建任何连接之前登记完；
  连接协商时才读注册表。
- 重复登记同一个类型（或同一对类型）什么都不做。名字和内置算法重名、或同一个名字登记给两个不同的类型，是编程
  错误（`precondition`）。
- 所有协议都是 `Sendable` 的（密钥交换协议只要求元类型 `SendableMetatype`，实例只在一个 event loop 上用）。

## 一、公钥 / 私钥 / 签名（`Keys And Signatures/CustomKeys.swift`）

### 两个名字

SSH 里有两个对内置算法恰好相同、对 RSA 不同的名字：

| 概念 | 出现在哪 | 接口里的名字 | RSA 的例子 |
|---|---|---|---|
| 密钥格式 | 公钥 blob 开头（RFC 4253 §6.6）、OpenSSH 公钥文件 | `NIOSSHPublicKeyProtocol.publicKeyPrefix` | `ssh-rsa` |
| 公钥算法名 | userauth 请求、`server_host_key_algorithms`、签名 blob 开头（RFC 4252 §7、RFC 8332） | `NIOSSHSignatureProtocol.signaturePrefix`，私钥侧 `NIOSSHPrivateKeyProtocol.keyPrefix` | `rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa` |

`register(publicKey:signature:)` 声明「这种格式的密钥可以用这个算法」。一种格式登记几个算法，就要几个签名类型
（每个签名类型的 `signaturePrefix` 是一个算法名）；私钥同理，一个算法一个私钥类型（可以是同一个泛型的不同特化）。

### 协议

```swift
public protocol NIOSSHSignatureProtocol: Sendable {
    /// 签名格式名 = 公钥算法名，例如 "rsa-sha2-512"。全局唯一，不能是内置名字。
    static var signaturePrefix: String { get }
    /// 规范字节表示，只用于相等与哈希。
    var rawRepresentation: Data { get }
    /// 写签名 blob 中格式名之后的部分（格式名 NIOSSH 自己写），返回写入字节数。
    /// SSH 常见的 `string signature` 就要自己写长度前缀。
    func write(to buffer: inout ByteBuffer) -> Int
    /// 读 write(to:) 写的东西。buffer 是签名 blob 去掉格式名之后的剩余部分。
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

public protocol NIOSSHPublicKeyProtocol: Sendable {
    /// 密钥格式名，例如 "ssh-rsa"。全局唯一，不能是内置名字。
    static var publicKeyPrefix: String { get }
    /// 规范字节表示，只用于相等与哈希。
    var rawRepresentation: Data { get }
    /// signature 可能是任何已登记的签名类型：自己按类型（也就是按算法）判断。
    /// data：主机密钥是交换哈希 H 本身；userauth 是 RFC 4252 §7 的待签数据。
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool
    /// 写公钥 blob 中格式名之后的部分（ssh-rsa：mpint e、mpint n），返回写入字节数。
    /// 必须和 read(from:) 读进来的字节逐字节相同：交换哈希里的 K_S 是 NIOSSH 把解析出的主机密钥重新序列化
    /// 得到的。对端发来的编码不规范时，把收到的原始字节存下来原样写回。
    func write(to buffer: inout ByteBuffer) -> Int
    /// 读 write(to:) 写的东西。buffer 是公钥 blob 去掉格式名之后的剩余部分。
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

public protocol NIOSSHPrivateKeyProtocol: Sendable {
    /// 这把私钥签名所用的公钥算法名，例如 "rsa-sha2-512"。
    /// userauth 时作为算法名发出；当主机密钥时作为它支持的主机密钥算法报给对端。
    /// signature(for:) 返回的签名的 signaturePrefix 必须等于它，且它必须对 publicKey 的格式登记过。
    static var keyPrefix: String { get }
    var publicKey: NIOSSHPublicKeyProtocol { get }
    /// 主机密钥：data 是交换哈希 H；userauth：RFC 4252 §7 的待签数据。
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol
}
```

### 登记与包装

```swift
public enum NIOSSHAlgorithms {
    public static func register<PublicKey: NIOSSHPublicKeyProtocol, Signature: NIOSSHSignatureProtocol>(
        publicKey: PublicKey.Type,
        signature: Signature.Type
    )
}

extension NIOSSHPublicKey {
    public init<Key: NIOSSHPublicKeyProtocol>(custom key: Key)
    /// 写完整公钥 blob（格式名 + 数据），即 SSH 报文与 OpenSSH 文件里的形式（指纹就对它算）。
    @discardableResult public func write(to buffer: inout ByteBuffer) -> Int
}

extension NIOSSHPrivateKey {
    public init<Key: NIOSSHPrivateKeyProtocol>(custom key: Key)
}
```

### 登记之后 NIOSSH 做什么

- 解析：已登记格式的公钥（`NIOSSHPublicKey(openSSHPublicKey:)`、主机密钥、userauth 里的公钥）与已登记算法的
  签名都能解析；没登记的照旧抛 `NIOSSHError` 的 `.unknownPublicKey` / `.unknownSignature`。写出不需要登记。
- 相等与哈希：自定义公钥 / 签名按（格式名或算法名, `rawRepresentation`）比较，永远不等于内置密钥。
  `String(openSSHPublicKey:)` 以密钥格式名开头。
- 客户端：KEXINIT 的 `server_host_key_algorithms` = 内置算法（原顺序）+ 已登记算法名（登记顺序）。**登记即启用**，
  没有按连接关掉的开关。主机回复里要求：(主机密钥类型, 协商的算法) 已登记，且签名的 `signaturePrefix` 就是协商的
  算法，否则 `.invalidHostKeyForKeyExchange`；然后用 `isValidSignature` 验 H。
- 客户端 userauth：`.privateKey(.init(privateKey: NIOSSHPrivateKey(custom: k)))` 时，请求与待签数据里的算法名取
  `K.keyPrefix`，公钥 blob 用公钥的格式名。NIOSSH 0.15.2 没有 `server-sig-algs`（`ext-info-c`），客户端事先不知道
  服务端接受哪个 RSA 算法，只能在 `NIOSSHClientUserAuthenticationDelegate` 里逐个试（每试一次算一次认证尝试）。
- 服务端：userauth 请求的算法名必须已登记且对该密钥格式登记过、签名算法与之相同，否则请求按格式错误处理；
  算法名不认识则按「不认识的算法」回失败（不会问认证委托）。PK_OK 原样回请求里的算法名。服务端报的主机密钥算法
  只来自 `hostKeys`：同一把密钥要以几个算法提供，就放几个 `NIOSSHPrivateKey(custom:)`（每个算法一个私钥类型），
  协商到哪个算法就用排在前面、支持它的那个签名。
- 证书：自定义密钥不能当被证书认证的公钥（`NIOSSHCertifiedPublicKey` 构造时抛 `.invalidCertificate`）；
  可以当签发证书的 CA 密钥。

### 例子（RSA 的形状；签名算法本身省略）

```swift
struct RSAPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ssh-rsa"
    let blob: [UInt8]                      // 收到的原始 blob（mpint e、mpint n），原样写回
    var rawRepresentation: Data { Data(blob) }
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        switch signature {
        case let s as RSASignature<SHA2_512>: return verify(s.bytes, data, hash: .sha512)
        case let s as RSASignature<SHA2_256>: return verify(s.bytes, data, hash: .sha256)
        default: return false
        }
    }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(blob) }
    static func read(from buffer: inout ByteBuffer) throws -> Self { /* 读两个 mpint，保留原始字节 */ }
}

protocol RSAHash { static var algorithm: String { get } }
enum SHA2_512: RSAHash { static let algorithm = "rsa-sha2-512" }
enum SHA2_256: RSAHash { static let algorithm = "rsa-sha2-256" }

struct RSASignature<H: RSAHash>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { H.algorithm }
    let bytes: [UInt8]
    var rawRepresentation: Data { Data(bytes) }
    func write(to buffer: inout ByteBuffer) -> Int {            // string rsa_signature_blob
        buffer.writeInteger(UInt32(bytes.count)) + buffer.writeBytes(bytes)
    }
    static func read(from buffer: inout ByteBuffer) throws -> Self { /* 读一个 string */ }
}

struct RSAPrivateKey<H: RSAHash>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { H.algorithm }
    let key: /* _RSA.Signing.PrivateKey */
    var publicKey: NIOSSHPublicKeyProtocol { /* RSAPublicKey */ }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASignature<H>(bytes: /* PKCS#1 v1.5 签名 HASH(data) */)
    }
}

// 启动时登记一次（顺序 = 客户端报 server_host_key_algorithms 的顺序）：
NIOSSHAlgorithms.register(publicKey: RSAPublicKey.self, signature: RSASignature<SHA2_512>.self)
NIOSSHAlgorithms.register(publicKey: RSAPublicKey.self, signature: RSASignature<SHA2_256>.self)

// 用户认证：先试 rsa-sha2-512，被拒再试 rsa-sha2-256。
let offer = NIOSSHUserAuthenticationOffer(
    username: "me", serviceName: "",
    offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(custom: RSAPrivateKey<SHA2_512>(key: k)))))
```

是否登记 SHA-1 的 `ssh-rsa` 算法要想清楚：登记了，客户端就会接受只提供 `ssh-rsa` 主机签名的服务端。

## 二、密钥交换（`Key Exchange/CustomKeyExchange.swift`）

实现只管算术：本端临时公开值、由对端公开值算共享秘密 K、用哪个哈希。NIOSSH 负责其余一切，和它自己的 ECDH
完全一样：

1. 经 `SSH_MSG_KEX_ECDH_INIT` / `_REPLY`（消息号 30 / 31，`SSH_MSG_KEXDH_INIT` / `_REPLY` 相同）收发公开值。
   线上的 mpint 与「装着补码字节的 string」逐字节相同，所以两类算法共用报文。
2. 交换哈希 `H = HASH(V_C ‖ V_S ‖ I_C ‖ I_S ‖ K_S ‖ e ‖ f ‖ K)`：`.string` 时 e / f 按 string 入哈希；`.mpint` 时
   按**规范** mpint（不管对端多发了几个前导 0，和 OpenSSH 一致）；K 一律按 mpint。HASH 是实现给的 `Hasher`。
3. 服务端用协商到的主机密钥签 H；客户端先做第一节说的主机密钥 / 签名算法检查，再验签，失败抛
   `.invalidExchangeHashSignature`。
4. 会话 ID = 首次交换的 H，重新交换时沿用。会话密钥按 RFC 4253 §7.2 派生，所需长度超过哈希长度时按
   `K1 = HASH(K‖H‖X‖session_id)`、`K2 = HASH(K‖H‖K1)`… 续长。

### 协议与登记

```swift
public enum NIOSSHKeyExchangePublicValueEncoding: Sendable, Hashable {
    /// 不透明字节串（ECDH、Curve25519）。
    case string
    /// 正的 mpint（有限域 DH）。和实现交换的是无符号大端数值字节：NIOSSH 负责加 / 去 0x00 前缀与长度，
    /// 对端发来负数时抛 `.invalidSSHMessage`。
    case mpint
}

public protocol NIOSSHKeyExchangeAlgorithmProtocol: _NIOSSHSendableMetatype {
    /// 交换哈希与密钥派生用的哈希（swift-crypto 的 HashFunction：SHA256、SHA512、Insecure.SHA1……）。
    associatedtype Hasher: HashFunction
    /// KEXINIT 里的名字，例如 ["diffie-hellman-group14-sha256"]。不能是内置名字。
    static var keyExchangeAlgorithmNames: [Substring] { get }
    /// 默认 .string。
    static var publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding { get }
    /// 每次密钥交换（首次与每次重新交换）新建一个实例：在这里生成临时密钥对。
    init()
    /// 本端公开值（客户端 e，服务端 f）。.mpint：无符号大端数值（允许前导 0）；.string：原样字节。
    /// 每次交换会读不止一次：在 init() 里算好存起来。
    var publicValue: [UInt8] { get }
    /// 由对端公开值（编码规则同上；.mpint 时已去掉前导 0）算共享秘密 K，返回无符号大端数值。
    /// 每次交换调一次。在这里校验对端值（DH：1 < f < p-1），不合格就抛错，交换随之失败。K 为 0 时 NIOSSH 拒绝
    /// （`.weakSharedSecret`）。
    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8]
}

extension NIOSSHAlgorithms {
    public static func register<KeyExchange: NIOSSHKeyExchangeAlgorithmProtocol>(
        keyExchangeAlgorithm: KeyExchange.Type
    )
}

extension SSHClientConfiguration {
    /// 按偏好排列的密钥交换算法名。默认 = 内置算法（上游原顺序）：
    /// ecdh-sha2-nistp384, ecdh-sha2-nistp256, ecdh-sha2-nistp521, curve25519-sha256, curve25519-sha256@libssh.org
    public var keyExchangeAlgorithms: [String]
}
extension SSHServerConfiguration {
    public var keyExchangeAlgorithms: [String]   // 同上
}
```

**登记不等于启用**（和公钥算法不同）：名字要加进 `keyExchangeAlgorithms` 才会出现在 KEXINIT 里、参与协商。
列表里既非内置又没登记的名字直接跳过，不会报出去。列表只能挑选和排序，内置算法也可以去掉或挪后。

### 例子（DH group14 的形状；大数运算省略）

```swift
struct DiffieHellmanGroup14SHA256: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["diffie-hellman-group14-sha256"]
    static let publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding = .mpint

    private let x: BigUInt                 // 私有指数
    let publicValue: [UInt8]               // g^x mod p，大端，init 里算好

    init() {
        x = /* 随机 */
        publicValue = /* modpow(2, x, p) 的大端字节 */
    }

    mutating func sharedSecret(peerPublicValue f: [UInt8]) throws -> [UInt8] {
        let f = BigUInt(Data(f))
        guard f > 1, f < p - 1 else { throw DHError.invalidPublicValue }
        return /* modpow(f, x, p) 的大端字节 */
    }
}

NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14SHA256.self)

var configuration = SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: hostKeys)
// 内置算法优先，DH 只作为老设备的兜底：
configuration.keyExchangeAlgorithms += ["diffie-hellman-group14-sha256"]
```

## 给实现方的提醒

- 实例方法都在连接的 event loop 上同步调用。2048 位以上的模幂（尤其非常数时间的 BigInt）会占住 event loop
  几十毫秒；`init()` 与 `sharedSecret` 各一次。
- 这两个接口不碰 `ext-info` / `server-sig-algs`、strict KEX（Terrapin 对策），NIOSSH 0.15.2 本身也没有。
- 不要在 NIOSSH 里加算法实现；需要接口没有的能力时，改补丁 0003 / 0004 并更新这份文档。
