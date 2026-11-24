# NIOSSH 的扩展接口与新增公开 API

补丁 0005 / 0006（见 [PATCHES.md](PATCHES.md)）给 NIOSSH 开的两个口子：NIOSSH 自己不带的公钥算法与密钥交换算法，
在 NIOSSH 之外实现、登记进来（第一、二节）。补丁 0007 / 0008 加的 strict KEX 与 `server-sig-algs`（第三、四节）
不需要登记，但改变了线上行为、多了两个公开入口。补丁 0009–0011 的三处小 API（全局请求、OPEN_FAILURE 原因码、
认证用完的错误）在第五节，0012 / 0013 的重新密钥交换在第六节。这里是**全部新增的公开 API**（以 `Sources/NIOSSH` 里的源码为准，
文档注释更细）。下面的代码都在 `import NIOSSH` 之后；测试里的玩具实现见
`Tests/NIOSSHTests/CustomKeyTests.swift`、`CustomKeyExchangeTests.swift`、`StrictKeyExchangeTests.swift`、
`ExtensionInfoTests.swift`。

## 通用规则

- 注册表**进程级**、加锁、线程安全，只增不减（测试用的复位函数是 `internal` 的）。在建任何连接之前登记完；
  每次密钥交换开始时（状态机创建时）读一次、取快照，这次交换的 KEXINIT 与协商都用这份快照。
- 重复登记同一个类型（或同一对类型）什么都不做。名字和内置名字重名（内置密钥类型、4 个
  `*-cert-v01@openssh.com` 证书类型、内置密钥交换算法、`kex-strict-*` / `ext-info-*` 标记）、或同一个名字登记给
  两个不同的类型，是编程错误（`precondition`）。
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
- 客户端：KEXINIT 的 `server_host_key_algorithms` 默认 = 内置算法（原顺序）+ 已登记算法名（登记顺序），即
  **登记即启用**；`SSHClientConfiguration.hostKeyAlgorithms: [String]?` 可以按连接挑选、排序（nil = 默认，未知名字
  丢弃），报出的、协商的、验签时接受的都只来自它。主机回复里要求：(主机密钥类型, 协商的算法) 已登记，且签名的 `signaturePrefix` 就是协商的
  算法，否则 `.invalidHostKeyForKeyExchange`；然后用 `isValidSignature` 验 H。
- 客户端 userauth：`.privateKey(.init(privateKey: NIOSSHPrivateKey(custom: k)))` 时，请求与待签数据里的算法名取
  `K.keyPrefix`，公钥 blob 用公钥的格式名。用哪个 RSA 算法，按服务端的 `server-sig-algs` 挑（第四节）；服务端没发
  时只能逐个试（每试一次算一次认证尝试）。
- 服务端：userauth 请求的算法名必须已登记且对该密钥格式登记过、签名算法与之相同，否则请求按格式错误处理；
  算法名不认识则按「不认识的算法」回失败（不会问认证委托）。PK_OK 原样回请求里的算法名。服务端报的主机密钥算法
  只来自 `hostKeys`：同一把密钥要以几个算法提供，就放几个 `NIOSSHPrivateKey(custom:)`（每个算法一个私钥类型），
  协商到哪个算法就用排在前面、支持它的那个签名。
- 证书：自定义密钥不能当被证书认证的公钥（`NIOSSHCertifiedPublicKey` 构造时抛 `.invalidCertificate`）；
  可以当签发证书的 CA 密钥。`validate(principal:type:allowedAuthoritySigningKeys:acceptableCriticalOptions:
  allowedSignatureAlgorithms: [String]? = nil)`：CA 签名的算法必须属于 CA 密钥（自定义密钥要对其类型登记过），
  给了 `allowedSignatureAlgorithms` 还必须在其中（通常传连接的 `hostKeyAlgorithms`），否则 `.invalidCertificate`。

```swift
extension SSHClientConfiguration {
    /// 要报出和接受的主机密钥算法，按偏好排列。nil（默认）= 内置算法 + 全部已登记算法（登记顺序）。
    public var hostKeyAlgorithms: [String]?
}
// 只为这一台老主机接受 SHA-1 的 ssh-rsa：
configuration.hostKeyAlgorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]
// 其他连接：
configuration.hostKeyAlgorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]
```

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

// 用户认证：按 server-sig-algs 挑算法，见第四节的例子。
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
    /// 每次交换调一次。在这里校验对端值（DH：1 < f < p-1），不合格就抛错，交换随之失败。兜底：NIOSSH 在调用前
    /// 拒绝空的对端值（.mpint 还拒绝 0 与 1，`.invalidSSHMessage`），之后拒绝 K = 0 或 1（`.weakSharedSecret`）；
    /// 上界 p-1 只有实现知道。
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

## 三、严格密钥交换（strict KEX，补丁 0007）

没有新的公开 API，**默认开启、不能关**（和 OpenSSH 一样）。行为（OpenSSH `PROTOCOL` §1.10，CVE-2023-48795）：

- 每个连接的**第一个** KEXINIT 在密钥交换算法列表末尾自动追加标记：客户端 `kex-strict-c-v00@openssh.com`，
  服务端 `kex-strict-s-v00@openssh.com`。配置了 `keyExchangeAlgorithms` 也照样追加；重新交换的 KEXINIT 不带。
  标记不是算法：写进 `keyExchangeAlgorithms` 会被滤掉，`register(keyExchangeAlgorithm:)` 用这些名字会 precondition。
- 双方都宣告时：对端的 KEXINIT 必须是它的第一个包；收到对端 NEWKEYS 之前，任何非密钥交换消息（包括
  SSH_MSG_IGNORE / DEBUG）都以 `NIOSSHError` 的 `.protocolViolation` 断开；每次 NEWKEYS 之后两个方向的包序号归零。
- 只有一端宣告时，一切和以前一样。

对 `NIOSSHTransportProtection` 实现方：`encryptPacket` / `decryptAndVerifyRemainingPacket` 收到的 `sequenceNumber`
在严格模式下每次换密钥都从 0 开始，用序号做 MAC / nonce 的算法（`hmac-*`、`chacha20-poly1305@openssh.com`）
要按收到的值算，别自己数。Terrapin 能攻击的正是这两类（chacha20-poly1305、`*-etm` 的 CBC）；对端不支持 strict KEX
时，客户端应把 AES-GCM 排在它们前面（`transportProtectionSchemes` 的顺序就是偏好顺序）。

## 四、扩展协商与 `server-sig-algs`（RFC 8308，补丁 0008）

客户端在第一个 KEXINIT 自动追加 `ext-info-c`（在 strict 标记之前）。服务端回的 SSH_MSG_EXT_INFO 里的
`server-sig-algs` 交给用户认证委托：

```swift
public protocol NIOSSHClientUserAuthenticationDelegate {
    // 原有，仍是必须实现的要求。
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )
    // 新增。NIOSSH 调的是这一个；默认实现丢掉 serverSignatureAlgorithms，转调上面那个。
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,   // 服务端没发 server-sig-algs 时为 nil
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )
}

extension SSHServerConfiguration {
    /// 设了、且客户端宣告了 ext-info-c，服务端就在第一次 NEWKEYS 之后发 EXT_INFO（只有 server-sig-algs）。
    /// 默认 nil：不发，和以前一样。
    public var serverSignatureAlgorithms: [String]?
}
```

- EXT_INFO 紧跟服务端的 NEWKEYS，一定早于 SERVICE_ACCEPT，所以委托**第一次**被调用时值已经在了；之后每次调用传的
  都是最新值。RFC 允许服务端在 USERAUTH_SUCCESS 之前再发一次（更新给认证之后用），NIOSSH 收下但不会再调委托。
  其他时候收到 EXT_INFO 仍是协议错误。strict KEX 下它是新密钥下序号 0 的那个包，合法。
- 解析是防御式的：扩展个数超过包能装下的上限就当格式错误；未知扩展忽略；`server-sig-algs` 按逗号分隔取出，
  原样（包括大小写与顺序）交出。
- 服务端对客户端的 `ext-info-c` 只是容忍，不宣告 `ext-info-s`，也不读客户端的 EXT_INFO。
- 想用新参数的委托两参数的那个也要实现（它仍是必须的要求），通常写成转调新方法、传 nil / false。
  只实现两参数版本的老委托不用改。

### partial success（补丁 0014）

```swift
public protocol NIOSSHClientUserAuthenticationDelegate {
    // …上面两个之外再加一个。NIOSSH 现在调的是这一个；默认实现丢掉 partialSuccess，转调三参数版本。
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        partialSuccess: Bool,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )
}
```

- `partialSuccess` 为 true：上一次提交的认证（RFC 4252 §5.1）**已被接受**，但服务端还要求 `availableMethods` 里的一种。
  第一次调用（SERVICE_ACCEPT 之后）与普通拒绝之后为 false。
- RSA：`rsa-sha2-512` 换来 partial success 就说明这把钥匙用这个算法通过了——记下算法，别再用别的算法递同一把钥匙，
  直接给下一种方式（比如密码）。
- 委托在任何时候以 nil 完成 promise，都以 `noFurtherAuthenticationOffers` 结束（补丁 0011），partial success 之后也一样。
- 实现三个方法的委托写法同上：两参数、三参数的那两个转调四参数的，补上默认值。

### RSA 实现怎么用

```swift
final class RSAAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var remaining: [NIOSSHPrivateKey]?     // 第一次调用时按 server-sig-algs 定下来

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        self.nextAuthenticationType(availableMethods: availableMethods, serverSignatureAlgorithms: nil,
                                    nextChallengePromise: nextChallengePromise)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if self.remaining == nil {
            let candidates: [(algorithm: String, key: NIOSSHPrivateKey)] = [
                (RSAPrivateKey<SHA2_512>.keyPrefix, NIOSSHPrivateKey(custom: RSAPrivateKey<SHA2_512>(key: k))),
                (RSAPrivateKey<SHA2_256>.keyPrefix, NIOSSHPrivateKey(custom: RSAPrivateKey<SHA2_256>(key: k))),
                (RSAPrivateKey<SHA1>.keyPrefix, NIOSSHPrivateKey(custom: RSAPrivateKey<SHA1>(key: k))),  // ssh-rsa
            ]
            if let accepted = serverSignatureAlgorithms {
                // 服务端说了：只试它接受的，按我们的偏好顺序，通常一次就中。
                self.remaining = candidates.filter { accepted.contains($0.algorithm) }.map(\.key)
            } else {
                // 没说（老服务端，或 OpenSSH < 7.2）：先 SHA-2，SHA-1 放最后（或者干脆不试，看产品取舍）。
                self.remaining = candidates.map(\.key)
            }
        }
        guard availableMethods.contains(.publicKey), let key = self.remaining?.first else {
            nextChallengePromise.succeed(nil)
            return
        }
        self.remaining!.removeFirst()
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
```

OpenSSH 7.2+ 都发 `server-sig-algs`；里面没有任何 RSA 算法时就别再试 RSA 了。

## 五、其他新增的公开 API（补丁 0009–0011）与客户端层要知道的行为

```swift
extension GlobalRequest {
    public enum GenericResponse: Hashable, Sendable {
        case success(ByteBuffer)   // REQUEST_SUCCESS 之后的附带数据（通常为空）；wantReply: false 时写出即 .success(空)
        case failure               // REQUEST_FAILURE：拒绝或不认识，不是错误
    }
}

extension NIOSSHHandler {
    /// 只能在 channel 的 event loop 上调用。连接建立前调用会排队，建立后按顺序发出。
    public func sendGlobalRequest(
        type: String,                      // 例如 "keepalive@openssh.com"
        payload: ByteBuffer?,              // want_reply 之后的数据，nil = 没有
        wantReply: Bool,
        promise: EventLoopPromise<GlobalRequest.GenericResponse>? = nil
    )
}

extension NIOSSHError {
    /// 只在 .channelSetupRejected 时有值：SSH_MSG_CHANNEL_OPEN_FAILURE 的原因码（RFC 4254 §5.1：
    /// 1 管理上禁止、2 连接失败、3 未知 channel 类型、4 资源不足）与对端的描述。
    public var channelOpenFailureReasonCode: UInt32? { get }
    public var channelOpenFailureDescription: String? { get }
}

extension NIOSSHError.ErrorType {
    /// 客户端认证委托以 nil 完成了 promise（没有更多可试的），服务端还没接受任何一次：认证失败。
    public static let noFurtherAuthenticationOffers: NIOSSHError.ErrorType
}
```

- **保活**：`sendGlobalRequest(type: "keepalive@openssh.com", payload: nil, wantReply: true, promise:)`，收到
  `.success` 或 `.failure` 都说明对端活着；promise 失败（`ChannelError.eof` 等）说明连接已经断了或请求发不出去。
  回复与 `sendTCPForwardingRequest` 的回复共用一个队列、按发送顺序配对，可以随意交错。未知的**入站**全局请求
  NIOSSH 照旧回 REQUEST_FAILURE。OpenSSH 服务端的 ClientAliveInterval 保活（`keepalive@openssh.com`，走全局请求或
  channel 请求）NIOSSH 都回失败，OpenSSH 把失败也当作对端活着。
- **认证用完**：委托以 nil 完成 promise 后，pipeline 上会收到 `noFurtherAuthenticationOffers` 错误（以前是一直挂着）。
  NIOSSH 不替你关连接：收到这个错误就关。
- **半关闭**（补丁 0004）：对端先发 EOF 之后，我方照常写数据、再 `close(mode: .output)` 发 EOF 是合法的，channel
  不再被拆掉；之后 `close()` 干净关闭。
- **closeFuture**（补丁 0002）：child channel 的 `closeFuture` 永不失败，出错的原因看 `errorCaught`。

## 六、重新密钥交换（补丁 0012 / 0013）

```swift
extension NIOSSHHandler {
    /// 连接已建立且没有进行中的交换（不论谁发起）时发起一次重新密钥交换并返回 true，否则什么也不做、返回 false。
    /// 只能在 channel 的 event loop 上调用。
    @discardableResult public func rekey() -> Bool
}

public struct NIOSSHRekeyLimits: Hashable, Sendable {
    public var packets: UInt64?   // 任一方向在当前密钥下的加密包数；nil = 不按包数
    public var bytes: UInt64?     // 任一方向在当前密钥下的加密字节数；nil = 不按字节
    public init(packets: UInt64?, bytes: UInt64?)
    public static let `default`: NIOSSHRekeyLimits   // 2^31 个包或 1 GiB
    public static let disabled: NIOSSHRekeyLimits    // 从不自动交换
}

extension SSHClientConfiguration { public var rekeyLimits: NIOSSHRekeyLimits }   // 默认 .default
extension SSHServerConfiguration { public var rekeyLimits: NIOSSHRekeyLimits }   // 默认 .default
```

- 到达上限就由 NIOSSH 自己发起，计数每次换密钥清零；交换进行中不会再发起，双方同时发起合成一次交换。
- 重新交换期间（我方 KEXINIT 之后、NEWKEYS 之前）child channel 的写入由 handler 按顺序排队，交换完成后发出，
  写入的 promise 到那时才完成；连接断开时以 `ChannelError.eof` 失败。对端发起的交换也一样（以前这些写入直接以
  `protocolViolation` 失败）。
- 客户端层：用序号算 MAC 的自定义传输保护（AES-CTR + `hmac-*` / `*-etm`）保持默认上限即可；想按时间换密钥（RFC 4253
  §9 建议每小时一次），自己定时调 `rekey()`。

## 给实现方的提醒

- 实例方法都在连接的 event loop 上同步调用。2048 位以上的模幂（尤其非常数时间的 BigInt）会占住 event loop
  几十毫秒；`init()` 与 `sharedSecret` 各一次。
- 会话密钥按 RFC 4253 §7.2 续长（补丁 0003），自定义传输保护要多长的密钥都行（`keySizes`）。
- NIOSSH 仍然没有 `publickey-hostbound@openssh.com`、`ping@openssh.com` 等其他 OpenSSH 扩展，收到了也只是忽略。
- 不要在 NIOSSH 里加算法实现；需要接口没有的能力时，改补丁 0005 / 0006 并更新这份文档。
