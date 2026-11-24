# swift-nio-ssh 的补丁

基线：[apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) `0.15.2`
（`e8de09a26d3d0a6ecf509fe0554bd27a6f9ee3d0`），取 `Sources/NIOSSH` 与 `Tests/NIOSSHTests`。补丁按序在
`patches/`，每个补丁的提交说明里有完整的根因。补丁都带自己的回归测试，写在 `Tests/NIOSSHTests` 里、和上游的
测试放在一起，所以每个补丁原样就能提给上游。

原则：补丁只做「扩展接口」「修 bug」与「补上协议的安全扩展」，**算法实现（RSA、DH……）一律不进 NIOSSH**，
放在 USSHCore。扩展接口与新增公开 API 见 [EXTENSION-API.md](EXTENSION-API.md)。

顺序：先是能单独提给上游的修复（0001–0004），然后两个扩展接口（0005 / 0006），再是两项协议扩展
（0007 / 0008，它们用到 0006 加的 `keyExchangeAlgorithms` 配置），然后客户端层要的三处小改动（0009–0011），
再是重新密钥交换的修复与自动触发（0012 / 0013）、把 partial success 交给认证委托（0014），
修改声明（0015）**始终排在最后**。

| 补丁 | 内容 | 类别 |
|---|---|---|
| 0001 | 对端先关时不回 window-adjust | 修 bug（纵深防御） |
| 0002 | closeFuture 永不失败 | 修 bug |
| 0003 | 会话密钥按 RFC 4253 §7.2 续长 | 修 bug |
| 0004 | `sendChannelEOF` 状态转换写反 | 修 bug |
| 0005 | 自定义公钥 / 私钥 / 签名 | 扩展接口 |
| 0006 | 自定义密钥交换 | 扩展接口 |
| 0007 | strict KEX（Terrapin） | 协议扩展 |
| 0008 | RFC 8308 `server-sig-algs` | 协议扩展 |
| 0009 | 公开发送任意全局请求（keepalive） | 公开 API |
| 0010 | 公开 CHANNEL_OPEN_FAILURE 原因码 | 公开 API |
| 0011 | 认证委托用完了立即报错 | 修 bug（行为变化） |
| 0012 | 重新密钥交换期间 channel 写入排队 | 修 bug |
| 0013 | 按需与按流量自动重新密钥交换 | 新功能（默认开启） |
| 0014 | USERAUTH_FAILURE 的 partial success 交给认证委托 | 公开 API |
| 0015 | 修改声明 | 许可证 |

## 0001 对端先关（`.closedRemotely`）时也不回 window-adjust

`SSHChildChannel.deliverSingleRead` 排空缓冲读时只用 `!state.sentClose` 判断能不能回
`CHANNEL_WINDOW_ADJUST`。`sentClose` 对 `.closedRemotely`（对端先发了 CLOSE）为假，而
`sendChannelWindowAdjust` 在这个状态下是 `preconditionFailure`，会在 event-loop 线程上 abort 整个进程。
`ChildChannelStateMachine` 新增 `canSendWindowAdjust`（恰好是 `sendChannelWindowAdjust` 接受的 4 个状态），
`deliverSingleRead` 改用它。

这是**纵深防御**（客户端层的线也没能在 0.15.2 上复现那个崩溃）：0.15.2 里 `.closedRemotely` 是瞬时的（收到 CLOSE 后同步回 CLOSE、进 `.closed`，
`closedCleanly` 先置 `didClose` 再排空），今天的路径到不了那个 precondition。补丁让守卫和状态机的合法集合
对齐，上游以后改成延迟回 CLOSE 也不会崩。回归测试（`ChildChannelStateMachineTests`）直接核对状态机。

旧 Wellz 基线上的 0001（`!sentClose` 守卫，uTerm 1.6.0 线上崩溃的修复）Apple 早已合入，不再需要。

**去掉的时机 / 上游**：可以提给 Apple（main 至今只有 `sentClose` 守卫）。上游合入后删掉。

## 0002 closeFuture 永不失败；已关闭 channel 上的打开请求直接失败

- 出错拆除（`errorEncountered`）时原代码让 `closePromise` 失败，违反 NIOCore「`Channel.closeFuture`
  永不失败」的约定：`NIOAsyncChannel.executeThenClose` 对此断言，SSH 传输突然断开时包成 `NIOAsyncChannel`
  的 direct-tcpip channel（`-L` 转发）在 Debug 构建里崩溃。改成 `succeed`；错误照旧经 `fireErrorCaught`、
  失败的待写数据、待关闭与激活 promise 报出去。
- 初始化器完成时 channel 已经关了，原代码用 `closeFuture.cascadeFailure(to:)` 让 promise 失败；closeFuture
  不再失败之后这个 promise 会永远挂着。改成直接失败，错误取拆除 channel 的那个（新记的 `closeError`，
  例如 `tcpShutdown`），干净关闭时是 `ChannelError.ioOnClosedChannel`。

上游有两个用例断言了 closeFuture 会失败（`testFailingOutboundChannelInitializerDoesNotDoIO`、
`testTCPCloseWhileAwaitingChannelSetup`），补丁按约定改成断言成功；新增
`testCloseFutureSucceedsWhenActiveChannelIsTornDownByTCPClose`。

客户端层的线确认这个补丁是必须的：没有它，套在 child channel 上的 `NIOAsyncChannel` 在连接断开时直接
fatalError。

**去掉的时机 / 上游**：两处都是通用 bug（0.15.2 仍在），可以提给 Apple。

## 0003 内置密钥交换按 RFC 4253 §7.2 续长会话密钥

`EllipticCurveKeyExchange.generateKeys` 的六把会话密钥只取一次哈希输出再截断。传输保护要的密钥比 KEX 哈希长时
（例如 `hmac-sha2-512` 要 64 字节 MAC 密钥，而 curve25519-sha256 / nistp256 只产出 32 字节），Debug 构建在
`assert(expectedKeySize <= Digest.byteCount)` 上崩溃，Release 构建握手失败。内置的两个 AES-GCM 碰不到
（密钥 ≤ 32 字节），换上自定义 `NIOSSHTransportProtection` 才会。

新文件 `Key Exchange/SSHKeyDerivation.swift`：`HashFunction.sshDerivedKey(discriminatorByte:sessionID:length:)`，
`K1 = HASH(K‖H‖X‖session_id)`、`K2 = HASH(K‖H‖K1)`、`K3 = HASH(K‖H‖K1‖K2)`……取 `K1‖K2‖…` 的前 n 字节。
六个 `generate*Key` 改用它（长度不超过哈希时与原来逐字节相同），删掉不再用到的三个小助手。0006 的自定义
密钥交换也用它。测试（`KeyDerivationTests`）：对照 Python hashlib 独立算出的向量；四种内置曲线在 80 / 64 / 48
字节的加密密钥 / MAC 密钥 / IV 下两端一致；用派生出的全部密钥算 HMAC 的测试传输保护端到端握手、重新交换。

**去掉的时机 / 上游**：通用 bug，可以提给 Apple（只动 `EllipticCurveKeyExchange.swift` 与新文件）。

## 0004 `sendChannelEOF` 的状态转换写反了

`ChildChannelStateMachine.sendChannelEOF` 接受 `.active → .halfClosedLocal` 与 `.halfClosedLocal → .quiescent`，
却对 `.halfClosedRemote` 抛 `protocolViolation("Sent EOF out of sequence.")`。EOF 每个方向只能发一次，合法的是
`.active → .halfClosedLocal` 与 `.halfClosedRemote → .quiescent`，在 `.halfClosedLocal` 再发才是违规——与
`receiveChannelEOF` 对称。后果：对端先半关闭、我方再发 EOF（`-L` 转发里服务端先关写端的正常收尾，exec 输出结束后
再 `sendEOF`）会把 child channel 当场拆掉、丢掉排在 EOF 前面的写入。只动那一个 switch。

上游没有用例固化错误的行为。测试：状态机四种 EOF 次序（`ChildChannelStateMachineTests.testEOFOrderings`）；
端到端 `ChannelHalfClosureTests`：对端先 EOF，我方再写数据、再 EOF，数据送达、对端看到 EOF、干净关闭、两端都没
有错误（修之前在 EOF 处报错）。

**去掉的时机 / 上游**：通用 bug，可以提给 Apple。

## 0005 自定义公钥 / 私钥 / 签名的扩展接口

NIOSSH 只带 ed25519 与 ECDSA，Apple 维护者表态只接受扩展接口、不把 RSA 合进主线（issue #60、PR #62 / #158）。
新文件 `Keys And Signatures/CustomKeys.swift`：`NIOSSHPublicKeyProtocol`、`NIOSSHPrivateKeyProtocol`、
`NIOSSHSignatureProtocol` 与进程级注册表 `NIOSSHAlgorithms.register(publicKey:signature:)`，
`NIOSSHPublicKey(custom:)`、`NIOSSHPrivateKey(custom:)`、`NIOSSHPublicKey.write(to:)`。名字沿用 Wellz26 fork
（同样出自 #62 / #158），改动点：

- **密钥格式和算法名分开**：`publicKeyPrefix` 是公钥 blob 开头的类型（`ssh-rsa`），`signaturePrefix` 是
  公钥算法名（`rsa-sha2-512`），一种格式可以登记多个算法。Wellz fork 把两者绑成一个值，USSHKit 只好把 RSA
  公钥的类型也写成 `rsa-sha2-512`。
- 内置密钥的行为一字不变（内部判断 `isUsable(withAlgorithm:signature:)` 对内置密钥就是原来的
  「算法名 == 密钥前缀」）。自定义密钥要求 (类型, 算法) 已登记，签名也必须是那个算法的（防止协商了
  `rsa-sha2-512` 却回 SHA-1 的 `ssh-rsa` 签名）。主机密钥校验、userauth 请求、PK_OK 都按算法名走。
- 客户端 KEXINIT 的 `server_host_key_algorithms` 默认 = 内置算法 + 已登记算法（登记顺序）；
  `SSHClientConfiguration.hostKeyAlgorithms` 可按连接挑选、排序（未知名字丢弃），报出的、协商的、验签接受的
  都只来自它——为一台老主机登记 SHA-1 `ssh-rsa` 不会让所有连接都接受它。
- 自定义密钥不能当被证书认证的公钥（构造证书时抛 `invalidCertificate`），可以当 CA。
  `NIOSSHCertifiedPublicKey.validate` 新增 `allowedSignatureAlgorithms`：CA 签名的算法必须属于 CA 密钥（自定义
  密钥要对其类型登记过）且在给定集合里。
- 不能登记内置密钥类型名，也不能登记 4 个 `*-cert-v01@openssh.com` 证书类型名：自定义类型先于证书解析查找，
  登记了就会顶掉 NIOSSH 自己的证书解析器。

（`hostKeyAlgorithms`、`allowedSignatureAlgorithms` 与证书类型名的保留是安全审查之后补的。测试
`CustomKeyPolicyTests`。）

**去掉的时机 / 上游**：接口可以提给 Apple。上游合入某种扩展接口后，按它的形状改 USSHCore 的算法实现，
再删这个补丁。

## 0006 自定义密钥交换的扩展接口

新文件 `Key Exchange/CustomKeyExchange.swift`：`NIOSSHKeyExchangeAlgorithmProtocol` 只管算术（名字、
`Hasher: HashFunction`、公开值编码 `.string` / `.mpint`、本端临时公开值、由对端公开值算共享秘密 K），
`NIOSSHAlgorithms.register(keyExchangeAlgorithm:)`；`SSHClientConfiguration` / `SSHServerConfiguration` 新增
`keyExchangeAlgorithms: [String]`（默认 = 内置算法、上游原顺序）。

其余都由 NIOSSH 做，与它自己的 ECDH 相同：经消息 30/31 收发公开值（mpint 在线上就是装着补码字节的 string，
所以 `KEXDH_INIT` / `KEXDH_REPLY` 与 ECDH 共用报文），算交换哈希（`.mpint` 时 e/f 按规范 mpint、K 一律 mpint），
用主机密钥签名 / 验签（含 0005 的算法一致检查），按 RFC 4253 §7.2 派生密钥（用 0003 的续长）。内置算法的
代码一行没动；状态机从配置读算法列表（原先读静态列表的 4 处），协商到自定义名字时由内部适配器驱动实现。
测试里把 `curve25519-sha256` 照接口重写一遍，与内置实现互为两端，交换哈希输入和六把会话密钥逐一相同。

安全审查之后补的两点：
- **每次密钥交换只读一次注册表**：状态机创建时对我方的密钥交换算法列表和主机密钥算法列表各取一份快照，KEXINIT、
  协商、抢先发包的判断都用它。原先 KEXINIT 与协商分别读注册表，中间正好有登记时客户端会协商出自己没报过的算法。
- **对端值兜底**：两种编码都拒绝空的对端值，`.mpint` 还拒绝 0 与 1，共享秘密 K 为 0 或 1 都拒绝。上界 p-1 NIOSSH
  不知道 p，仍由实现检查。

**去掉的时机 / 上游**：同 0005。

## 0007 严格密钥交换（strict KEX，Terrapin 对策 CVE-2023-48795）

Terrapin 利用两点：包序号在 NEWKEYS 之后不归零；初次密钥交换期间能夹带 SSH_MSG_IGNORE 之类的明文包。中间人
在握手时插入 / 删除明文包把序号对齐，就能悄悄删掉加密后的头几个包（比如 EXT_INFO）。照 OpenSSH `PROTOCOL`
§1.10 实现：

- 只在第一个 KEXINIT 的密钥交换算法列表末尾追加 `kex-strict-c-v00@openssh.com`（客户端）/
  `kex-strict-s-v00@openssh.com`（服务端）；用户配置的 `keyExchangeAlgorithms` 照样自动追加；重新交换不带。
  标记从不参与协商（手写进配置会被当成未知名字滤掉，也不能注册成自定义算法），也不影响 first_kex_packet_follows
  的猜测判断（只看候选列表第一项）。
- 双方都宣告时（`SSHKeyExchangeStateMachine.isStrictKeyExchange`，只在初次交换为真）：对端 KEXINIT 必须是它的
  第一个二进制包；收到对端 NEWKEYS 之前连 IGNORE / DEBUG 也断开（`protocolViolation`）；每次发出 / 收到 NEWKEYS
  之后对应方向的包序号归零，之后每次重新交换都如此。
- 序号归零放在 `SSHPacketSerializer` / `SSHPacketParser.addEncryption` 里：它们是序号的唯一持有者、贯穿所有连接
  状态，第一次以 `strictKeyExchange: true` 调用后就记住。一端没宣告时行为与改动前一字不差。
- 配置里有一个 internal 的 `offersStrictKeyExchange`（默认开），只给测试扮演旧对端，不对外公开。

测试（`StrictKeyExchangeTests`）：标记的位置与只出现在首个 KEXINIT、重新交换不严格、猜测判断不受影响；双方严格
时首次与两次重新交换后两端两个方向序号都从 0 开始（记录序号的测试传输保护）；一端严格时序号接着数；严格时初次
交换中插入 IGNORE、或 KEXINIT 不是第一个包都断开，不严格时照常完成；与自定义密钥交换组合。

**去掉的时机 / 上游**：可以提给 Apple（它至今没有这个对策）；提交时要把对 0006 的 `keyExchangeAlgorithms` 的依赖
换成上游的静态算法表。

## 0008 扩展协商（RFC 8308 ext-info-c / server-sig-algs）

RSA 用户密钥有三个算法，客户端事先不知道服务端接受哪个，逐个试会耗掉认证次数。`server-sig-algs` 让服务端提前说。

- 客户端只在首个 KEXINIT 追加 `ext-info-c`（排在 strict 标记之前，同 OpenSSH）；同样从不参与协商。
- 新报文 SSH_MSG_EXT_INFO（7）：读写在新文件 `ExtensionNegotiation.swift`，`SSHMessages.swift` 只加 enum case 和
  读写分派；解析不信任扩展个数，未知扩展忽略。
- 客户端在收到服务端 NEWKEYS 之后的 `receivedNewKeys`（我方 NEWKEYS 还没发）与 `userAuthentication` 两个状态里
  接受它（后者也覆盖 RFC 允许的「USERAUTH_SUCCESS 之前」），其他时候仍是协议错误。strict KEX 下它在 NEWKEYS 之后、
  序号归零之后，合法。
- `NIOSSHClientUserAuthenticationDelegate` 新增带默认实现的 `nextAuthenticationType(availableMethods:
  serverSignatureAlgorithms:nextChallengePromise:)`，NIOSSH 改调它，默认实现转调原来的两参数版本。
- 服务端对 `ext-info-c` 只是容忍；新增 `SSHServerConfiguration.serverSignatureAlgorithms`（默认 nil = 不发），设了
  且客户端宣告了 `ext-info-c` 时在第一次 NEWKEYS 之后立刻发 EXT_INFO。给 USSHTestServer 用。

测试（`ExtensionInfoTests`）：报文往返、虚报个数与截断被拒；`ext-info-c` 只在客户端首个 KEXINIT、服务端只对宣告了
的客户端且只在初次交换时发；委托拿到 `server-sig-algs`（含我方 NEWKEYS 未发时收到）、没发时为 nil、旧委托照常工作；
与 strict KEX 组合时 EXT_INFO 以序号 0 发出并通过校验。

**去掉的时机 / 上游**：可以提给 Apple；委托的新要求是增量 API。

## 0009 公开发送任意全局请求

保活要发 `keepalive@openssh.com`（want_reply = true，对端回成功还是失败都证明它活着），但能发任意全局请求的
`sendGlobalRequestMessage` 是 internal 的。新增 `NIOSSHHandler.sendGlobalRequest(type:payload:wantReply:promise:)`
（新文件 `GenericGlobalRequest.swift`），回复为 `GlobalRequest.GenericResponse`（`.success(附带数据)` / `.failure`），
拒绝不是错误；与 TCP 转发请求共用发送与回复队列、按顺序配对；未知的入站全局请求照旧回 REQUEST_FAILURE。
`NIOSSHHandler.swift` 只加了 `PendingGlobalRequestResponse.generic`、`refuse()` 和一个入队辅助函数。
测试 `GenericGlobalRequestTests`：保活往返、不要回复的请求、与 tcpip-forward 交错、请求挂着时连接关闭。

**去掉的时机 / 上游**：可以提给 Apple。

## 0010 公开 CHANNEL_OPEN_FAILURE 的原因码

原因码以前只写在不公开的诊断字符串里。`NIOSSHError` 多存一个 private 的 (原因码, 描述)，只由
`channelSetupRejected` 设；新增公开的 `channelOpenFailureReasonCode` / `channelOpenFailureDescription`。
测试 `ChannelOpenFailureTests`（含端到端：拒绝一切 channel 的服务端回原因码 2）。

**去掉的时机 / 上游**：可以提给 Apple。

## 0011 认证委托用完了立即报错

客户端认证委托以 nil 完成 promise 表示没有更多可试的了，原代码收到 nil 什么也不做，连接停在认证阶段直到对端超时。
`AcceptsUserAuthMessages` 的 transform 遇到 nil 抛新的 `NIOSSHError.ErrorType.noFurtherAuthenticationOffers`，
经 `fireErrorCaught` 交给 pipeline。只影响客户端；内部 `UserAuthenticationStateMachine` 及其上游测试不变。
测试 `AuthenticationOffersExhaustedTests`；0005 里「未登记的用户密钥被拒」的用例改为断言这个错误。

**去掉的时机 / 上游**：可以提给 Apple。注意是行为变化：以前挂住的连接现在报错（客户端层不用再自己检测用完）。

## 0012 重新密钥交换期间 child channel 的写入排队

RFC 4253 §7.1：发出 KEXINIT 之后、发出 NEWKEYS 之前只能发密钥交换消息。状态机守着这一条，但 `NIOSSHHandler`
把 child channel 的写入直接交给它：重新交换进行中（不论谁发起），任何 channel 数据、窗口调整、EOF、CLOSE 都以
`protocolViolation("Sent unexpected message type")` 失败，数据丢失。OpenSSH 服务端按 RekeyLimit 重新交换时，
正在传输的 channel 就会在那一刻出错；上游的重新交换测试只在交换完成后才开 channel，没测到。

`SSHConnectionStateMachine.canSendChannelMessages`（`.active` / `.rekeyingSentNewKeysState`）；`writeFromChildChannel`
不能发时按顺序排进 `queuedChildMessages`，处理完每条入站消息、密钥交换的异步结果写出后与 `channelReadComplete`
时再发；handler 被移除时以 `ChannelError.eof` 失败。测试 `RekeyTests`（前 3 个）。

**去掉的时机 / 上游**：通用 bug，可以提给 Apple。0013 的自动重新交换依赖它。

## 0013 按需与按流量自动重新密钥交换

NIOSSH 从不主动重新交换（`_rekey` 只给测试）；对端也不发起时，32 位包序号会在同一把 MAC 密钥下回绕（`hmac-*`、
`*-etm` 用序号算 MAC）。新增：

- `NIOSSHHandler.rekey() -> Bool`：连接已建立且没有进行中的交换时发起，否则什么也不做、返回 false。
- `SSHClientConfiguration` / `SSHServerConfiguration.rekeyLimits: NIOSSHRekeyLimits`，默认 `.default`（2^31 个包或
  1 GiB，先到为准），`.disabled` 关闭，单项可设 nil。任一方向在当前密钥下的加密包数或字节数到达上限就发起一次。
- 计数在 `SSHPacketParser` / `SSHPacketSerializer`（只数加密流量），每次换密钥（`addEncryption`）清零，与 strict KEX
  的序号归零同处。只有状态机处于 `.active` 时才会发起，交换进行中不会再发起；双方同时发起时两份 KEXINIT 合成一次
  交换（状态机原本支持）。

测试 `RekeyTests`（后 8 个）：按需与重复请求、包数上限触发多次交换且两个方向数据完整、字节上限、双方同时到达上限、
双方同时请求只做一次交换、关闭后从不自动交换、每次交换后计数清零、默认值。

**去掉的时机 / 上游**：可以提给 Apple。行为变化：默认开启，超过 1 GiB 的连接会自动重新交换。

## 0014 把 USERAUTH_FAILURE 的 partial success 交给客户端认证委托

`receiveUserAuthFailure` 只把剩下的认证方式交给委托，丢掉了 `partial success`（RFC 4252 §5.1）。客户端分不清
「这一步通过、还要下一步」和「被拒」：多步认证写不了；RSA 的 `rsa-sha2-512` 其实已被接受时，客户端层会换
`rsa-sha2-256` 再递同一把钥匙，白耗一次认证尝试，也记不下是哪个算法通过的（USSHCoreTests 里有一个
`XCTExpectFailure` 用例记着这两点，客户端层改用新方法后去掉）。

与 0008 同样做法：`NIOSSHClientUserAuthenticationDelegate` 新增带默认实现的
`nextAuthenticationType(availableMethods:serverSignatureAlgorithms:partialSuccess:nextChallengePromise:)`，NIOSSH 改调它，
默认实现转调三参数版本。第一次调用与普通拒绝之后为 false。测试 `PartialSuccessTests`：先 partial success 再接受时委托
依次看到 false / true、普通拒绝都是 false、两参数与三参数老委托照常认证、partial success 之后没有可提供的仍以
`noFurtherAuthenticationOffers` 结束。

**去掉的时机 / 上游**：可以提给 Apple；依赖 0008 的三参数要求，单独提交时把默认实现改为转调两参数版本。

## 0015 修改声明（始终最后）

Apache-2.0 第 4(b) 条：0001–0014 改过的 23 个上游源文件和 1 个上游测试文件
（`ChildChannelMultiplexerTests.swift`）头部各加一行 `Modified by uAppKit`。补丁新加的文件文件头写明出自
uAppKit，不用再加。新补丁插在它前面；改到别的上游文件，就在这个补丁里给那个文件也加一行。

## 验证

- `swift test --filter NIOSSHTests`：上游的 347 个用例加补丁的 83 个（共 430），全过才算补丁打对。
- 0001 / 0002 的线上崩溃只在 `-L` / `-D` / 长连接**远端先断**时出现。改这几个补丁之后，发版前要在真机上做
  断网 smoke，编译和测试通过不等于修好。
- 0005 / 0006 只用测试专用的玩具算法验证了接口本身；0007 / 0008 只在 NIOSSH 两端之间验证过。RSA、DH 接上之后，
  以及 strict KEX 与 EXT_INFO 对真实 OpenSSH（9.6+ 两端都严格、8.x 只认 ext-info）的互通，由 USSHCore 的测试负责。
