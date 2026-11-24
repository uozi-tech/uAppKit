# swift-nio-ssh 的补丁

基线：[apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) `0.15.2`
（`e8de09a26d3d0a6ecf509fe0554bd27a6f9ee3d0`），取 `Sources/NIOSSH` 与 `Tests/NIOSSHTests`。补丁按序在
`patches/`，每个补丁的提交说明里有完整的根因。补丁都带自己的回归测试，写在 `Tests/NIOSSHTests` 里、和上游的
测试放在一起，所以每个补丁原样就能提给上游。

原则：补丁只做「扩展接口」和「修 bug」，**算法实现（RSA、DH……）一律不进 NIOSSH**，放在 USSHCore。
两个扩展接口的公开 API 见 [EXTENSION-API.md](EXTENSION-API.md)。

## 0001 对端先关（`.closedRemotely`）时也不回 window-adjust

`SSHChildChannel.deliverSingleRead` 排空缓冲读时只用 `!state.sentClose` 判断能不能回
`CHANNEL_WINDOW_ADJUST`。`sentClose` 对 `.closedRemotely`（对端先发了 CLOSE）为假，而
`sendChannelWindowAdjust` 在这个状态下是 `preconditionFailure`，会在 event-loop 线程上 abort 整个进程。
`ChildChannelStateMachine` 新增 `canSendWindowAdjust`（恰好是 `sendChannelWindowAdjust` 接受的 4 个状态），
`deliverSingleRead` 改用它。

这是**纵深防御**：0.15.2 里 `.closedRemotely` 是瞬时的（收到 CLOSE 后同步回 CLOSE、进 `.closed`，
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

**去掉的时机 / 上游**：两处都是通用 bug（0.15.2 仍在），可以提给 Apple。

## 0003 自定义公钥 / 私钥 / 签名的扩展接口

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
- 客户端 KEXINIT 的 `server_host_key_algorithms` = 内置算法 + 已登记算法（登记顺序）。
- 自定义密钥不能当被证书认证的公钥（构造证书时抛 `invalidCertificate`），可以当 CA。

**去掉的时机 / 上游**：接口可以提给 Apple。上游合入某种扩展接口后，按它的形状改 USSHCore 的算法实现，
再删这个补丁。

## 0004 自定义密钥交换的扩展接口

新文件 `Key Exchange/CustomKeyExchange.swift`：`NIOSSHKeyExchangeAlgorithmProtocol` 只管算术（名字、
`Hasher: HashFunction`、公开值编码 `.string` / `.mpint`、本端临时公开值、由对端公开值算共享秘密 K），
`NIOSSHAlgorithms.register(keyExchangeAlgorithm:)`；`SSHClientConfiguration` / `SSHServerConfiguration` 新增
`keyExchangeAlgorithms: [String]`（默认 = 内置算法、上游原顺序）。

其余都由 NIOSSH 做，与它自己的 ECDH 相同：经消息 30/31 收发公开值（mpint 在线上就是装着补码字节的 string，
所以 `KEXDH_INIT` / `KEXDH_REPLY` 与 ECDH 共用报文），算交换哈希（`.mpint` 时 e/f 按规范 mpint、K 一律 mpint），
用主机密钥签名 / 验签（含 0003 的算法一致检查），按 RFC 4253 §7.2 派生密钥（哈希比密钥短时续长）。内置算法的
代码一行没动；状态机从配置读算法列表（原先读静态列表的 4 处），协商到自定义名字时由内部适配器驱动实现。
测试里把 `curve25519-sha256` 照接口重写一遍，与内置实现互为两端，交换哈希输入和六把会话密钥逐一相同。

**去掉的时机 / 上游**：同 0003。

## 0005 修改声明

Apache-2.0 第 4(b) 条：0001–0004 改过的 13 个上游源文件和 1 个上游测试文件
（`ChildChannelMultiplexerTests.swift`）头部各加一行 `Modified by uAppKit`。补丁新加的文件文件头写明出自
uAppKit，不用再加。新补丁改到别的上游文件，就在这个补丁里给那个文件也加一行。

## 验证

- `swift test --filter NIOSSHTests`：上游的 347 个用例加补丁的 28 个，全过才算补丁打对。
- 0001 / 0002 的线上崩溃只在 `-L` / `-D` / 长连接**远端先断**时出现。改这几个补丁之后，发版前要在真机上做
  断网 smoke，编译和测试通过不等于修好。
- 0003 / 0004 只用测试专用的玩具算法验证了接口本身；RSA、DH 接上之后的互通（真实 OpenSSH）由 USSHCore 的
  测试负责。
