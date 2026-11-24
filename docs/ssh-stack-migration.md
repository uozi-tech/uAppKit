# SSH 栈迁移：Citadel → USSHCore（给 app 开发者）

2026-11 起 USSHKit 不再依赖 Citadel。客户端层换成本包自己的 `USSHCore`（架在打过补丁的 apple/swift-nio-ssh 0.15.2，
即 `NIOSSH` 上），`Citadel` target 与 product 删除。这份文档列出 app 要改的地方。背景与分工见 uTerm 的
`docs/ssh-stack-rewrite-plan.md`。

## 依赖与 import

- **`Citadel` product 没了**。以前链它的 target 现在什么都不用额外链：`USSHKit` 用 `@_exported import USSHCore`
  把客户端层整个转出去，`import USSHKit` 就能用 `SSHClient`、`SFTPClient`、通道句柄与它们的错误类型。
  pbxproj 里去掉 `Citadel` 的 `packageProductDependencies`，源码里的 `import Citadel` 删掉（或换成 `import USSHKit`）。
- 还要直接用 NIOSSH 的类型（`NIOSSHPublicKey`、`NIOSSHError`……）就照旧 `import NIOSSH`（本包的 target，模块名不变）。
- 同一个构建图里不能再出现上游的 Citadel / swift-nio-ssh 包（模块重名），这条和以前一样。
- 测试要起 SSH 服务端时链 `USSHTestServer` product（见文末）。

## 接口：之前 → 之后

### `@_spi(uTermIntegration)`

| 之前 | 之后 |
|---|---|
| `USSHKitIntegration.connect(…, protocolOptions: Set<Citadel.SSHProtocolOption> = [])` | `USSHKitIntegration.connect(…, maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize, algorithms: SSHAlgorithms = 今天的默认)` |
| `protocolOptions: [.maximumPacketSize(1 << 20)]` | `maximumPacketSize: 1 << 20`（**窗口语义变了**，见下文「行为差异」） |
| `USSHKitIntegration.makeAuthenticationMethod(username:credential:) -> Citadel.SSHAuthenticationMethod` | `USSHKitIntegration.makeAuthentication(username:credential:) -> SSHAuthentication`（用户名 + 按顺序尝试的方式） |
| `USSHKitIntegration.makeHostKeyValidator(host:port:store:policy:approvalTimeout:approver:) -> Citadel.SSHHostKeyValidator` | `USSHKitIntegration.makeHostKeyValidation(host:port:store:policy:approver:) -> SSHHostKeyValidation`；等用户的时限配在 `SSHClient.Configuration.hostKeyValidationTimeout` |
| —（新增） | `USSHKitIntegration.makeConfiguration(host:port:username:credential:hostKeyStore:hostKeyPolicy:connectTimeout:approvalTimeout:approver:maximumPacketSize:algorithms:) throws -> SSHClient.Configuration`：`connect` 内部用的同一份，自己调 `SSHClient.connect` / `client.jump` 时用 |
| —（新增） | `USSHKitIntegration.describe(_ error: any Error) -> String`：`NIOConnectionError` / `IOError` / `ChannelError` 等桥接后只剩「错误 N」的类型给出可定位的文案 |
| `struct ConnectedClient: @unchecked Sendable { let target: Citadel.SSHClient; let bastion: Citadel.SSHClient? }` | `struct ConnectedClient: Sendable { let target: SSHClient; let bastion: SSHClient? }`（USSHCore 的 `SSHClient`，本身 `Sendable`），新增 `public init(target:bastion:)` 与 `isConnected` |
| `try await connected.exec(cmd)`，失败抛 `SSHClient.CommandFailed` / `CitadelError.commandOutputTooLarge` | 同名同签名，失败抛 `SSHCommandError.nonZeroExit(status, output:)` / `.outputTooLarge(limit:)` |
| `try await connected.openDirectTCPIP(host:port:) -> NIOAsyncChannel<ByteBuffer, ByteBuffer>` | 同名同签名；现在打开了出站半关闭（`outbound.finish()` 向对端发 EOF） |
| `SSHForwardingChannelFailure(classifying: NIOSSHError)` | 同时认 `SSHChannelError.openRejected(NIOSSHError)`（USSHCore 开通道被拒抛的就是它） |
| `LocalForwardListener`、`TunnelGlue`、`TunnelByteCounter`、`TunnelOutcome`、`withForwardingTimeout`、`ForwardingTimeoutError` | 不变 |

### 公开接口

| 之前 | 之后 |
|---|---|
| `struct SSHPrivateKey: @unchecked Sendable` | `struct SSHPrivateKey: Sendable` |
| `SSHConnectionError` | case 不变；**抛哪个 case 变了**：服务器拒绝凭据现在是 `.authenticationFailed`（以前是 `.connectFailed("…allAuthenticationOptionsFailed…")`），等用户确认主机密钥超时是 `.hostKeyRejected("等待确认主机密钥超时（…）")` |
| `SSHFileTransferSession`、`SSHLocalForwardingTunnel`、`SSHPrivateKeyParser`、`KeyImportInspector`、`SSHKeyGenerator`、`PrivateKeyImportError`、`KeyImportErrorMessage` | 签名不变 |
| USSHCore 的错误类型（`SSHClientError`、`SSHChannelError`、`SFTPError`、`SSHCommandError`、`SSHRSAError`）没有文案 | USSHKit 给它们补上了 `LocalizedError`（四种语言），`error.localizedDescription` 直接可用 |

### 直接用 `connected.target` 的地方（Citadel → USSHCore）

| 之前（Citadel） | 之后（USSHCore） |
|---|---|
| `try await client.executeCommand(cmd, maxResponseSize:, mergeStreams:)` | 同名；非零退出抛 `SSHCommandError.nonZeroExit` |
| `try await client.executeCommandStream(cmd)`，元素 `.stdout(ByteBuffer)` / `.stderr(ByteBuffer)` | 同名同元素；消费者提前退出或任务取消会结束远端命令 |
| `try await client.withPTY(SSHChannelRequestEvent.PseudoTerminalRequest(…)) { inbound, outbound in … }` | `try await client.withPTY(SSHPseudoTerminal(term:columns:rows:)) { output, handle in … }`；或 `let shell = try await client.openShell(pty:)` 拿句柄（`write` / `resize` / `exitStatus()` / `close()`），不用挂着闭包 |
| `try await client.withExec(cmd) { … }` | `try await client.withExec(cmd) { output, handle in … }`，或 `openExec(_:)` 拿句柄；任务取消会发 `signal TERM` 再关通道 |
| `client.onDisconnect(perform: handler)`（只存一个回调） | `let token = client.onDisconnect { reason in … }`，可以挂任意多个，`removeDisconnectObserver(token)`；另有 `await client.waitForDisconnect()` |
| `try await client.close()` | `await client.close()`（不抛错，幂等） |
| `try await client.openSFTP()` | `try await client.openSFTP()` |
| `sftp.getAttributes(at:)` / `openFile(filePath:flags:)` / `rename(at:to:)` / `remove(at:)` / `rmdir(at:)` / `createDirectory(atPath:)` / `getRealPath(atPath:)` | `stat(_:)` / `openFile(_:flags:)` / `rename(_:to:mode:)` / `remove(_:)` / `removeDirectory(_:)` / `createDirectory(_:)` / `realPath(_:)` |
| `SFTPFile`（不是 Sendable，要包一层 `@unchecked Sendable` 才能并发读） | `SFTPFile` 是 `Sendable` 的值，`read(from:length:)` / `write(_:at:)` 各对应一个请求，可以从多个任务并发调 |
| 服务端状态有两种装法：裸的 `SFTPMessage.Status` 与 `SFTPError.errorStatus(status)` | 只有一种：`SFTPError.status(code:message:languageTag:)`，`error.statusCode == .noSuchFile`；通道断了是 `SFTPError.connectionClosed` |
| `try await client.createDirectTCPIPChannel(using: .init(targetHost:targetPort:originatorAddress:)) { channel in … }` | `try await client.openDirectTCPIPAsyncChannel(targetHost:targetPort:originatorAddress:)`（激活前就包好），或 `openDirectTCPIP(…, initializer:)` 自己装 handler |
| `try await client.runRemotePortForward(host:port:onOpen:handleChannel:)` | `try await client.withRemotePortForward(host:port:onOpen:onAccept:)`，或 `startRemotePortForward` 拿 `SSHRemotePortForward`（`boundPort`、`cancel()`） |
| `try await bastion.jump(to: SSHClientSettings(…))` | `try await bastion.jump(to: host, port: port, configuration: SSHClient.Configuration(…))` |
| 传输断开：`NIOSSHError` 的 `.tcpShutdown`、`ChannelError.ioOnClosedChannel` | 连接级：`client.disconnectReason`（`.remoteClosed` / `.transportError(原错误)` / `.localClose`）；通道级：`SSHChannelError.connectionClosed(reason)` / `.channelClosed`；SFTP：`SFTPError.connectionClosed` |
| keepalive 只能自己开通道试 | `try await client.ping(timeout:)` |

## 行为差异

- **时限**：以前 Citadel 的一个 login timer 覆盖「TCP + 握手 + 认证」，从装 handler 起算；USSHKit 只好把它放大成
  「连接超时 + 审批超时」，否则用户在主机密钥确认框上停久了连接就会失败。现在分三段：TCP 建连 `connectTimeout`、
  握手 + 认证再给一个 `connectTimeout`、等主机密钥回调单独计（`.ask` 给 `approvalTimeout`，其余策略给 `connectTimeout`），
  **等回调期间握手不计时**。所以最坏情况下建连会比以前多等一个 `connectTimeout`（TCP 慢、握手也慢的时候）。
  审批超时按拒绝算，确认框所在的任务会被取消（以前要等 login timer 到点，`approver` 不响应取消时还会一直挂着）。
- **错误类型**：建连失败照旧是 `SSHConnectionError`，但底下的原因换成了 USSHCore 的类型（见上表）。分类器（例如 uTerm 的
  `SSHTransportFailure`）要按 `SSHDisconnectReason` / `SSHChannelError.connectionClosed` / `SFTPError.connectionClosed` 判断，
  不再有 Citadel 的错误类型。不要按文案判断（文案现在是本地化的）。
- **子通道窗口**：NIOSSH 0.15 把每条子通道的接收窗口定为 `maximumPacketSize × 64`（以前的 fork 是 `× 1`）。默认包长
  128 KiB → 窗口 8 MiB，已经比 uTerm 今天特地设的 1 MiB 大；照搬 `maximumPacketSize: 1 << 20` 会变成 64 MiB 窗口
  （每条通道最多在内存里攒这么多对端没被读走的数据）。要原来的窗口就传 `窗口 / 64`，不在乎就别传。
  越界值由 USSHCore 夹进 `SSHClient.maximumPacketSizeRange`，不会再 abort 进程。`SSHFileTransferSession` 的
  `channelWindowBytes` 参数已经按新语义换算，窗口大小与以前相同。
- **SFTP 单次读写的上限**跟服务器的 `limits@openssh.com` 走（OpenSSH 是 255 KiB），没宣告时按 32 KiB；
  `SFTPFile.write(_:at:)` 超过 `client.maximumWriteLength` 直接抛 `SFTPError.requestTooLarge`，不会切块。
  uTerm 流水线里写死的 32 000 可以放大到 `client.maximumReadLength` / `maximumWriteLength`。
- **SFTP 改名**：`rename(_:to:mode: .posix)` 走 `posix-rename@openssh.com`，原子替换已存在的目标；
  `SSHFileTransferSession.uploadAtomically` 已改用它（服务端没有这个扩展时保留「删旧文件再改名」）。
- **取消真的生效了**：开通道、exec、SFTP 请求、建连都响应任务取消（以前 Citadel 的 exec 与开通道不响应，要靠
  `withForwardingTimeout` 那种非结构化的超时兜底）。建连被取消抛 `CancellationError`，不再包成 `SSHConnectionError`。
- **direct-tcpip 的半关闭**：`openDirectTCPIP` 返回的通道打开了出站半关闭，`TunnelGlue` 在本地一侧读到 EOF 时调的
  `outbound.finish()` 现在真的向服务器发 EOF（以前是空操作），和 OpenSSH 的 `-L` 一致。
- **RSA 用户私钥**：先试 `rsa-sha2-512`，被拒再试 `rsa-sha2-256`（以前只有 512），每次各占服务器一次认证次数。
  不发 SHA-1 的 `ssh-rsa`：以前只有「解析失败回退到 Citadel」的那一小撮 OpenSSH 容器会走 SHA-1，现在它们（私钥段
  缺 p / q 的）由 n / e / d 还原素因子，同样走 SHA-2。1024 位的 RSA 私钥现在能用了（以前 swift-crypto 按分量构造的
  入口要求 ≥ 2048 位，建连时失败）。RSA 分量互相不一致时在导入时就报「私钥结构损坏」，不用等到建连。
- **算法**：默认仍只协商 NIOSSH 自带的算法（AES-GCM、curve25519 / ECDH、ed25519 / ECDSA 主机密钥），和今天一样。
  要连只认旧算法的设备，由 app 经 `algorithms:` 参数放宽。

## 在 app 的测试里用 `USSHTestServer`（替代 Citadel 的 `SSHServer`）

app 的测试宿主带沙盒、起不了 `sshd`，以前用 Citadel 自带的 `SSHServer.host(…)` + `enableSFTP(withDelegate:)`。
现在链 `USSHTestServer` product：

```swift
import USSHTestServer
@_spi(uTermIntegration) import USSHKit

let fileSystem = try SFTPLocalFileSystem.makeTemporary()      // 真实临时目录；也可以自己实现 SFTPServerFileSystem
let server = try await SSHTestServer.start(.init(
    authentication: .init(passwords: ["tester": "secret"]),   // 或 authorizedKeys / custom / .acceptAnyone
    exec: .routes(["uname": .scripted(stdout: "Linux\n")]),
    subsystems: ["sftp": { channel in
        channel.eventLoop.makeCompletedFuture { _ = try SFTPServer.install(on: channel, fileSystem: fileSystem) }
    }]
))
defer { Task { await server.stop(); try? fileSystem.removeRoot() } }

let client = try await USSHKitIntegration.connect(
    endpoint: SSHEndpoint(host: server.host, port: server.port, username: "tester"),
    credential: .password("secret"), hostKeyStore: store, hostKeyPolicy: .insecureAcceptAll,
    connectTimeout: .seconds(10), approver: { _ in true })
```

- 服务端监听 `127.0.0.1` 的随机端口（`server.port`），主机公钥在 `server.hostPublicKey`。
- 它记下发生过的事：`server.events`（认证尝试、exec 命令、PTY 与窗口变化、环境变量、direct-tcpip 目标、远程转发……），
  `waitForEvents { … }` 等某件事发生。
- 故障注入：`SSHTestFaults`（认证延迟、先拒 N 次、不发版本行以测握手超时）、`dropAllConnections()`；SFTP 一侧有
  `SFTPFaultInjector`（延迟、按操作失败、短读、乱序回答、断线）。
- shell 默认回显（`.echoShell`），direct-tcpip 默认真的去连目标、远程转发默认放行，都能在配置里关掉。
- RSA 用户私钥：服务端要认得 `ssh-rsa`（NIOSSH 的密钥扩展登记是进程级的），USSHKit 自己的测试在
  `Tests/USSHKitTests/Support/TestSupport.swift` 里登记一次。
- 例子：本包 `Tests/USSHKitTests` 下的 `ConnectIntegrationTests`、`SFTPSessionIntegrationTests`、`ForwardingIntegrationTests`。
