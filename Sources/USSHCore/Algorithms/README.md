# USSHCore/Algorithms

NIOSSH（apple/swift-nio-ssh 0.15.2）只带 AES-GCM、curve25519 / ECDH 和 ed25519 / ECDSA。这里补上其余的：
可以直接插进 NIOSSH 的传输保护，RSA、有限域 DH 两个**纯计算内核**，以及把内核接到 NIOSSH 扩展接口上的
适配层（`Extension/`，见「接线」一节）。连接层用的是 `SSHAlgorithms` 的三个预设（`Connection/SSHClientConfiguration.swift`）。密码学原语一律来自 swift-crypto（`Crypto`、`_CryptoExtras`），DH 的大数运算用
attaswift/BigInt；没有自己写的原语。按 RFC 写，没有照抄 Citadel。

## 一览

| 类型 | SSH 名字 | 状态 |
|---|---|---|
| `SSHAESCTRTransportProtection<SSHAES{128,192,256}CTR, SSHHMACSHA256ETM>` | `aes*-ctr` + `hmac-sha2-256-etm@openssh.com` | 现代，`SSHTransportProtections.modern` |
| `SSHAESCTRTransportProtection<…, SSHHMACSHA256>` | `aes*-ctr` + `hmac-sha2-256` | 现代，`modern` |
| `SSHAESCTRTransportProtection<…, SSHHMACSHA512ETM / SSHHMACSHA512>` | `aes*-ctr` + `hmac-sha2-512[-etm@openssh.com]` | 现代（NIOSSH 补丁 0003 补上密钥加长之后可用），`requiringKeyExtension`；在 `SSHAlgorithms.standard` 里 |
| `SSHAESCTRTransportProtection<…, SSHHMACSHA1ETM / SSHHMACSHA1>` | `aes*-ctr` + `hmac-sha1[-etm@openssh.com]` | 旧算法，需明确选用，`legacy` |
| — | `chacha20-poly1305@openssh.com` | **没做**：swift-crypto 没有公开的独立 Poly1305（只有 RFC 8439 的 AEAD，认证的消息格式不同），不自己写 |
| `SSHRSAPublicKey` / `SSHRSAPrivateKey` / `SSHRSASignature` | 公钥 `ssh-rsa`；签名 `rsa-sha2-512`、`rsa-sha2-256` | 现代，`SSHRSASignatureAlgorithm.modern` |
| 同上 | 签名 `ssh-rsa`（SHA-1） | 旧算法，`SSHRSASignatureAlgorithm.legacy` |
| `SSHDiffieHellmanKeyExchange` | `diffie-hellman-group16-sha512`、`diffie-hellman-group14-sha256` | 现代，`SSHDiffieHellmanAlgorithm.modern` |
| 同上 | `diffie-hellman-group14-sha1` | 旧算法，`SSHDiffieHellmanAlgorithm.legacy` |
| `SSHKeyDerivation` | RFC 4253 §7.2 | 带 K1 ‖ K2 ‖ … 长度扩展 |
| `Wire/SSHWireFormat.swift`（`package`） | string / uint32 / name-list / mpint | 严格校验 |

## 传输保护（现在就能用）

```swift
config.transportProtectionSchemes = Constants.bundledTransportProtectionSchemes   // NIOSSH 自带的 AES-GCM
    + SSHTransportProtections.modern
    // + SSHTransportProtections.legacy   // 只在用户明确要连老设备时
```

- 每个（加密，MAC）组合是一个具体类型，因为 NIOSSH 按 `cipherName` + `macName` 一对协商。数组顺序就是偏好：
  NIOSSH 从数组按顺序取出加密名列表和 MAC 名列表。
- CTR 计数器是 128 位大端整数，初值为 IV，**跨包连续**到下一次换钥，进位贯穿全部 128 位（RFC 4344 §4）。
  NIOSSH 换钥时新建实例（`init(initialKeys:)`），`updateKeys` 也支持。
- encrypt-and-MAC（RFC 4253）：长度字段一起加密，`mac = HMAC(seq ‖ 明文包)`；
  encrypt-then-MAC（OpenSSH `-etm@openssh.com`）：长度明文，`mac = HMAC(seq ‖ 长度 ‖ 密文)`，先验 MAC 再解密。
  默认目录里 ETM 排在前面。
- MAC 比较用 swift-crypto 的 `MessageAuthenticationCode ==`（恒定时间）。长度字段先核对（至少一块、块的整数倍），
  解析器给的字节数与长度对不上、填充少于 4 字节都抛 `SSHTransportProtectionError`，不会越界或 trap。

### HMAC-SHA2-512

RFC 6668 要 64 字节的 MAC 密钥。NIOSSH 0.15.2 原本推导会话密钥时不做 RFC 4253 §7.2 的加长，SHA-256 / SHA-384
的密钥交换配它会握手失败；补丁 0003 补上之后都能用（互通测试对每种内置与 DH 密钥交换都验过）。目录名
`requiringKeyExtension` 是历史名字，`SSHAlgorithms.standard` 已经包含它们。

## RSA 内核

- `SSHRSAPublicKey`：`ssh-rsa` 公钥。`init(sshBlob:)` / `sshBlob` 读写整个 blob；
  `package init(readingBodyFrom:)` / `writeBody(to:)` 只读写类型名之后的 `mpint e ‖ mpint n`。
  模数 1024–8192 位（BoringSSL 的上限；OpenSSH 允许到 16384，更大的以 `.unsupportedModulusSize` 拒绝）；`isWeak`（< 2048 位）让调用方决定提示还是拒绝。
- `SSHRSASignature`：`string 算法名 ‖ string 签名`。`init(sshBlob:)` / `sshBlob`，
  `package init(algorithm:readingBodyFrom:)` / `writeBody(to:)`。
- `SSHRSAPublicKey.isValidSignature(_:for:algorithm:)`：`algorithm` 是**调用方期望的**算法；签名里的算法不同直接判假
  （防降级到 SHA-1）。签名比模数短时左侧补零（RFC 8332 §3 的宽松规则），比模数长判假。
- `SSHRSAPrivateKey`：`init(components:)`（PKCS#1 九项 / OpenSSH 私钥段的 n e d iqmp p q / 今天 USSHKit 的
  n e d p q，缺的 CRT 值用 BigInt 算）、`init(derRepresentation:)`、`init(pemRepresentation:)`、
  `init(generatingModulusBits:)`（≥ 2048）。`signature(for:algorithm:)` 输出恒为模数长度。
  分量一律拼成 PKCS#1 DER 交给 `_RSA.Signing.PrivateKey(unsafeDERRepresentation:)`（swift-crypto 按分量构造的入口
  要求 ≥ 2048 位），BoringSSL 解析时做 `RSA_check_key`，分量不一致会被拒绝。
  这一套可以替掉 USSHKit 的 `RSASHA512Signer` / `RSAKeyComponents` 路径和 Citadel 的 `Insecure.RSA`。

### 接到 NIOSSH 密钥扩展接口时要调的

| 场合 | 调用 |
|---|---|
| 解析主机公钥 / userauth 里的公钥 blob（类型名 `ssh-rsa` 已被读掉） | `SSHRSAPublicKey(readingBodyFrom: &buffer)` |
| 写公钥 blob 主体 | `publicKey.writeBody(to: &buffer)` |
| 解析签名（算法名已被读掉） | `SSHRSASignature(algorithm: 由名字得到的算法, readingBodyFrom: &buffer)` |
| 校验主机密钥对 H 的签名 | `publicKey.isValidSignature(sig, for: H, algorithm: 协商出的主机密钥算法)` |
| 服务端校验 userauth 签名 | `publicKey.isValidSignature(sig, for: 待签数据, algorithm: 请求里的算法名)` |
| 用户私钥签名 | `privateKey.signature(for: data, algorithm: .rsaSHA2_512)`，再 `writeBody` |

名字要分开对待（RFC 8332）：公钥 blob 里的类型名**永远是 `ssh-rsa`**；主机密钥算法列表与 userauth 的
「公钥算法」字段用签名算法名（`rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa`）。旧 fork 把两者绑成同一个值，
新接口不要再这样。没有 `server-sig-algs`（RFC 8308）时选哪种签名算法是调用方的策略，不在内核里。

## 接线（`Extension/`）

| 文件 | 内容 |
|---|---|
| `SSHRSAExtensionKeys.swift` | `SSHRSAExtensionPublicKey`（一个类型，格式名 `ssh-rsa`，原样存收到的字节写回）、按算法特化的 `SSHRSAExtensionSignature<A>` / `SSHRSAExtensionPrivateKey<A>`；公开包装 `NIOSSHPublicKey(rsaPublicKey:)`、`.rsaPublicKey`、`NIOSSHPrivateKey(rsaPrivateKey:algorithm:)` |
| `SSHDiffieHellmanExtension.swift` | `SSHDiffieHellmanExtensionKeyExchange<V>`：`init()` 算好公开值，`sharedSecret` 校验 1 < f < p − 1 后算 K；H 与密钥推导由 NIOSSH 做 |
| `SSHAlgorithmRegistration.swift` | 唯一调 `NIOSSHAlgorithms.register` 的地方：`SSHAlgorithms.registerStandardAlgorithms()`（建连接时自动）与 ⚠️ `registerLegacyAlgorithms()`（SHA-1，只由允许旧算法的连接或明确调用触发） |
| `SSHRSAVerificationRecord.swift` | 验签时记下 RSA 算法，主机密钥回调按**这条连接**的 `SSHAlgorithms` 决定接不接受（登记是进程级的，接受是按连接的） |

适配层没法知道 NIOSSH「期望」哪个算法（接口不传），它按签名自己的类型验；期望算法与签名算法一致由 NIOSSH 保证
（主机密钥：`isUsable`；userauth：服务端状态机），连接层再按策略拒绝不允许的算法。这几条都有恶意对端的测试
（`SSHAlgorithmConnectionTests` 经 `KeyExchangeReplyTamperer` 改写 KEX 回复）。

## 有限域 DH 内核

```swift
let kex = SSHDiffieHellmanKeyExchange(algorithm: .group14SHA256, role: .client)
// SSH_MSG_KEXDH_INIT (30)：buffer.writeSSHWireUnsignedMPInt(magnitude: kex.localPublicValue)
// SSH_MSG_KEXDH_REPLY (31)：读 string K_S、mpint f（readSSHWireUnsignedMPInt，负数在读时就拒绝）、string 签名
let result = try kex.complete(
    peerPublicValue: f,
    inputs: SSHExchangeHashInputs(
        clientVersion: V_C, serverVersion: V_S,                         // 不含 CR LF
        clientKeyExchangeInit: I_C, serverKeyExchangeInit: I_S,         // KEXINIT payload，从消息号 20 起
        serverHostKey: K_S))
// 用 K_S 校验签名是否覆盖 result.exchangeHash；第一次交换的 H 就是 session_id。
// 会话密钥：result.deriveKey(letter: A…F, sessionID:, length:)，或把 result.sharedSecretMPInt
// （K 的 mpint 编码，含长度前缀）与 result.exchangeHash 交给 NIOSSH 的推导。
```

服务端对称：`role: .server`，`localPublicValue` 是 f，`complete(peerPublicValue: e, …)`，再用主机私钥签 `result.exchangeHash`。

- 群：RFC 3526 group14（2048 位）、group16（4096 位），g = 2。
- 临时私钥：系统 CSPRNG 取 512 位（≥ RFC 8268 要求的两倍安全强度，同 OpenSSH），落在 (1, q) 内。
  `complete` 成功后私钥即清除，再调抛 `.alreadyCompleted`。
- 对端公开值要求 1 < v < p − 1（RFC 4253 §8；0、1、p − 1 只生成平凡子群）。
- 交换哈希 H = HASH(string V_C ‖ string V_S ‖ string I_C ‖ string I_S ‖ string K_S ‖ mpint e ‖ mpint f ‖ mpint K)。

## 安全说明

- **BigInt 的模幂不是恒定时间的。** 可能从时间上泄露临时私钥的信息；但临时私钥每次连接只用一次、用完即弃，
  对手只有一次观测机会，实际风险低（与 Citadel 今天的做法相同）。耗时（本机 Release，单次模幂）：group14 约 17 ms、
  group16 约 66 ms，每端两次；Debug 构建慢一到两个数量级（group16 每次 1–3 秒）。RSA 不受影响：走 BoringSSL（带 blinding）。
- **encrypt-and-MAC 的长度字段**要先解密才能读，NIOSSH 的解析器在 MAC 校验前就按它等数据，是 RFC 4253 固有的长度预言；
  对端支持时优先协商 ETM（默认目录已如此）。
- **密钥材料**：会话密钥都在 swift-crypto 的 `SymmetricKey` 里（释放时清零）。RSA 拼出的 PKCS#1 DER 用完 `memset_s` 清零；
  `SSHRSAPrivateKeyComponents` 的 `[UInt8]` 与 DH 的 `BigUInt` 私钥做不到可靠清零（Swift 值类型可能被复制），尽量短命。
- SHA-1 的三个（`hmac-sha1*`、`ssh-rsa` 签名、`group14-sha1`）都只在单独的 `legacy` 列表里，不会被默认启用。

## 测试与线上兼容性

`Tests/USSHCoreTests/Algorithms/`：

- **证明线上兼容的**：`TransportProtectionOpenSSHInteropTests`（本机真实 sshd，每种加密方式登录、exec、收 300 KB、核对 sshd 自己的协商日志
  与至少一次换钥）；`SSHRSATests` 里 ssh-keygen 产出的公钥 blob 逐字节往返、`ssh-keygen -Y sign` 的签名 blob 与我们签出的
  逐字节相同、openssl 三种摘要的签名逐字节相同、与 Security.framework 双向互验。
- **独立实现对照（算法正确，但没经过真实对端）**：NIST SP 800-38A、RFC 4231 / 2202 已知答案；CommonCrypto 参考实现逐字节
  比对整包；逐块 AES 参考实现核对 2^32 / 2^64 / 2^128 进位；python3 独立算的 DH 向量；Machin 公式现算 π 核对 RFC 3526 素数。
  DH、RSA 主机 / 用户密钥经扩展接口与真实 sshd 的互通在 `Interop/OpenSSHAlgorithmInteropTests`。
- **自洽**：NIOSSH 客户端 / 服务端内存背靠背协商与换钥；篡改、截断、畸形 blob、越界公开值。

夹具由 `Tests/USSHCoreTests/Algorithms/Fixtures/generate-fixtures.sh` 用 ssh-keygen / openssl / python3 重新生成。
