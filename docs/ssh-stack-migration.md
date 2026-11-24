# SSH 栈迁移：Citadel → USSHCore（给 app 开发者）

2026-11 起 USSHKit 不再依赖 Citadel。客户端层换成本包自己的 `USSHCore`（架在打过 14 个补丁的 apple/swift-nio-ssh 0.15.2，
即 `NIOSSH` 上），`Citadel` target 与 product 删除。这份文档自成一体：app 迁移只看它就够。背景见 uTerm 的
`docs/ssh-stack-rewrite-plan.md`。

## 1. 依赖与 import

- **`Citadel` product 没了**。以前链它的 target 现在什么都不用额外链：`USSHKit` 用 `@_exported import USSHCore`
  把客户端层整个转出去，`import USSHKit` 就能用 `SSHClient`、`SFTPClient`、`SFTPPath`、通道句柄与它们的错误类型。
  pbxproj 里去掉 `Citadel` 的 `packageProductDependencies`，源码里的 `import Citadel` 删掉（或换成 `import USSHKit`）。
- 还要直接用 NIOSSH 的类型（`NIOSSHPublicKey`、`NIOSSHError`……）就照旧 `import NIOSSH`（本包的 target，模块名不变）。
- 同一个构建图里不能再出现上游的 Citadel / swift-nio-ssh 包（模块重名）。
- 测试要起 SSH 服务端时链 `USSHTestServer` product（第 9 节）。
- 别自己调 `NIOSSHAlgorithms.register`：RSA / DH 由 USSHCore 登记（建连接、起测试服务端时自动），同一个格式名被
  两种类型登记会 trap。要在连接之前解析 `ssh-rsa …` 公钥行（known_hosts）就先调 `SSHAlgorithms.registerStandardAlgorithms()`。

## 2. USSHKit 的接口：最终签名

### `@_spi(uTermIntegration)`

```swift
public struct ConnectedClient: Sendable {
    public let target: SSHClient            // USSHCore 的 SSHClient（Sendable 句柄）
    public let bastion: SSHClient?
    public init(target: SSHClient, bastion: SSHClient?)
    public var isConnected: Bool            // 两跳都还连着
    public func close() async               // 先目标、再跳板机；幂等
    public func exec(_ command: String) async throws -> String   // stdout+stderr，≤ 64 000 字节
    public func openDirectTCPIP(host: String, port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer>
}

public enum USSHKitIntegration {
    public static func connect(
        endpoint: SSHEndpoint, credential: SSHCredential,
        hostKeyStore: any HostKeyStore, hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration, approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        algorithms: SSHAlgorithms = .builtInOnly,
        keepAliveInterval: Duration? = nil
    ) async throws -> ConnectedClient

    public static func makeAuthentication(username: String, credential: SSHCredential) throws -> SSHAuthentication

    public static func makeHostKeyValidation(
        host: String, port: Int, store: any HostKeyStore, policy: SSHHostKeyPolicy,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool
    ) -> SSHHostKeyValidation

    public static func makeConfiguration(
        host: String, port: Int, username: String, credential: SSHCredential,
        hostKeyStore: any HostKeyStore, hostKeyPolicy: SSHHostKeyPolicy,
        connectTimeout: Duration, approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        algorithms: SSHAlgorithms = .builtInOnly,
        keepAliveInterval: Duration? = nil
    ) throws -> SSHClient.Configuration

    public static func describe(_ error: any Error) -> String
}
```

不变的 SPI：`LocalForwardListener`、`TunnelGlue`、`TunnelByteCounter`、`TunnelOutcome`、`withForwardingTimeout`、
`ForwardingTimeoutError`。

### 之前 → 之后

| 之前 | 之后 |
|---|---|
| `connect(…, protocolOptions: [.maximumPacketSize(1 << 20)])` | `connect(…, maximumPacketSize: …)`——**窗口语义变了**，按第 4 节换算，不要照搬数字 |
| `makeAuthenticationMethod(username:credential:) -> Citadel.SSHAuthenticationMethod` | `makeAuthentication(username:credential:) -> SSHAuthentication` |
| `makeHostKeyValidator(host:port:store:policy:approvalTimeout:approver:) -> Citadel.SSHHostKeyValidator` | `makeHostKeyValidation(host:port:store:policy:approver:)`；等用户的时限配在 `Configuration.hostKeyValidationTimeout`，或直接用 `makeConfiguration` |
| — | `makeConfiguration(…)`：`connect` 内部用的同一份配置，自己调 `SSHClient.connect(host:port:configuration:)` / `client.jump(to:port:configuration:)` 时用 |
| — | `connect` / `makeConfiguration` 的 `algorithms:`（默认 `.builtInOnly`）、`keepAliveInterval:`（默认 `nil`，不发） |
| `struct ConnectedClient: @unchecked Sendable`（Citadel 的 `SSHClient`） | `struct ConnectedClient: Sendable`（USSHCore 的 `SSHClient`），新增 `init(target:bastion:)`、`isConnected` |
| `exec` 失败抛 `SSHClient.CommandFailed` / `CitadelError.commandOutputTooLarge` | 抛 `SSHCommandError.nonZeroExit(status, output:)` / `.outputTooLarge(limit:)` |
| `openDirectTCPIP(host:port:)`：出站半关闭没开 | 同签名；出站半关闭打开，`outbound.finish()` 向服务器发 EOF |
| `SSHForwardingChannelFailure.Kind`：`.timeout` `.administrativelyProhibited` `.connectFailed` `.other` | **新增 `.resourceShortage`**（app 里对 `Kind` 的 `switch` 要补）；原因码来自 USSHCore 的 `SSHChannelOpenFailure.reason`，不再解析文本 |

### 公开接口

| 之前 | 之后 |
|---|---|
| `struct SSHPrivateKey: @unchecked Sendable` | `struct SSHPrivateKey: Sendable` |
| `SSHConnectionError` | case 不变；**抛哪个变了**：服务器拒绝凭据 → `.authenticationFailed("服务器拒绝了密码 / 私钥…")`（以前是 `.connectFailed("…allAuthenticationOptionsFailed…")`）；等确认主机密钥超时 → `.hostKeyRejected("等待确认主机密钥超时（N 秒）")`；取消建连抛 `CancellationError`（不包） |
| `SSHFileTransferSession`、`SSHLocalForwardingTunnel`、`SSHPrivateKeyParser`、`KeyImportInspector`、`SSHKeyGenerator`、`PrivateKeyImportError`、`KeyImportErrorMessage` | 签名不变；`SSHFileTransferSession.download` 遇到变短的文件改为报错（第 6 节） |
| USSHCore 的错误类型没有文案 | USSHKit 给 `SSHClientError`、`SSHChannelError`、`SFTPError`、`SSHCommandError`、`SSHRSAError` 补上 `LocalizedError`（四种语言），`error.localizedDescription` 直接可用。判断一律看类型与 case，不看文案 |

## 3. 直接用 `connected.target` 的地方（Citadel → USSHCore）

| 之前（Citadel） | 之后（USSHCore） |
|---|---|
| `try await client.executeCommand(cmd, maxResponseSize:, mergeStreams:)` | 同名；非零退出抛 `SSHCommandError.nonZeroExit` |
| `try await client.executeCommandStream(cmd)`，元素 `.stdout` / `.stderr` | 同名同元素；消费者提前退出或任务取消会结束远端命令 |
| `withPTY(SSHChannelRequestEvent.PseudoTerminalRequest(…)) { inbound, outbound in }` | `withPTY(SSHPseudoTerminal(term:columns:rows:)) { output, handle in }`；或 `let shell = try await client.openShell(pty:)` 拿句柄（`write` / `resize` / `exitStatus()` / `close()`），不用挂着闭包 |
| `withExec(cmd) { … }` | `withExec(cmd) { output, handle in }` 或 `openExec(_:)`；任务取消会发 `signal TERM` 再关通道 |
| — | `await handle.exitStatus()`：**没人读 `output` 时会认领并丢弃之后的输出**（否则输出超过一个窗口的命令会卡住）。要输出就先开始读，再在别的任务里或读完之后等退出状态 |
| `client.onDisconnect(perform:)`（只存一个回调） | `let token = client.onDisconnect { reason in }`，可挂任意多个，`removeDisconnectObserver(token)`；`await client.waitForDisconnect()`；`client.disconnectReason` |
| `try await client.close()` | `await client.close()`（不抛错，幂等） |
| `try await client.openSFTP()` | `try await client.openSFTP(configuration: SFTPClient.Configuration = .init())` |
| `createDirectTCPIPChannel(using:initialize:)` | `openDirectTCPIPAsyncChannel(targetHost:targetPort:originatorAddress:)`，或 `openDirectTCPIP(targetHost:targetPort:originatorAddress:initializer:)`——**initializer 必填**，在通道激活前、它的 EventLoop 上装 handler |
| `runRemotePortForward(host:port:onOpen:handleChannel:)` | `withRemotePortForward(host:port:onOpen:onAccept:)`，或 `startRemotePortForward(host:port:initializer:)` 拿 `SSHRemotePortForward`（`boundPort`；`await forward.cancel(timeout: .seconds(5))` 撤销，传输半死时最多等这么久） |
| `bastion.jump(to: SSHClientSettings(…))` | `bastion.jump(to: host, port: port, configuration: SSHClient.Configuration(…))` |
| keepalive 只能自己开通道试 | `Configuration.keepAliveInterval` 自动保活（第 5 节），或手动 `try await client.ping(timeout:)`（发 `keepalive@openssh.com`） |
| — | `await client.rekey()` 立刻重新交换密钥；`Configuration.rekeyLimits` 按流量自动换（默认 2^31 包 / 1 GiB） |

## 4. 包长与窗口（**照搬旧数字会错**）

NIOSSH 0.15 把每条子通道的接收窗口定为 `maximumPacketSize × 64`（以前的 fork 是 `× 1`）。`maximumPacketSize` 会被夹进
`SSHClient.maximumPacketSizeRange` = **32 KiB…512 KiB**，所以能拿到的窗口是 **2 MiB…32 MiB**（越界不再 abort）。
一个读得慢（但还在读）的消费者每条通道最多压住约 2 个窗口的内存。

要窗口 W，就传 `maximumPacketSize: W / 64`：

| 用途 | 今天（旧 fork） | 现在传 | 实际窗口 |
|---|---|---|---|
| 终端 / 转发 / 普通连接（uTerm 的 `SSHClientFactory.channelWindowOptions`、`SSHBridgeSession.channelWindowBytes`，都是 1 MiB） | `.maximumPacketSize(1 << 20)` → 窗口 1 MiB | 1 MiB 低于能拿到的下限：传 `32_768`（最小，窗口 2 MiB），或者干脆不传（默认 128 KiB → 窗口 8 MiB，USSHKit 的默认） | 2 MiB（或 8 MiB）；1 MiB 拿不到 |
| `SSHFileTransferSession`（`channelWindowBytes`，默认 4 MiB） | 窗口 = 包长 | USSHKit 内部已换算成 `channelWindowBytes / 64` = 64 KiB | 4 MiB，与今天相同 |
| uTerm 的并行传输专用连接（`ParallelTransfer.Tuning.windowBytes`，16 MiB） | 窗口 16 MiB | `maximumPacketSize: (16 << 20) / 64` = 256 KiB | 16 MiB |
| 想要更大 | — | 最多 512 KiB | 32 MiB（上限） |

**照搬 `maximumPacketSize: 1 << 20` 会被夹成 512 KiB → 32 MiB 窗口**（每条通道最坏约 64 MiB 内存），不是 1 MiB。
uTerm 的 `SSHClientFactory.windowOptions(bytes:)` / `clampedMaximumPacketSize` 改成「字节数 ÷ 64，再交给 USSHCore 夹」，
`maximumPacketSizeRange` 的测试改成 `32_768...(1 << 19)`。

## 5. 时限、保活、算法预设

- **时限**分三段：TCP 建连 `connectTimeout`；握手 + 认证再给一个 `connectTimeout`；等主机密钥回调单独计
  （`.ask` 给 `approvalTimeout`，其余策略给 `connectTimeout`），**等回调期间握手不计时**。最坏情况下建连比以前多等一个
  `connectTimeout`。审批超时按拒绝算，确认框所在的任务被取消。
- **保活**：`keepAliveInterval: .seconds(n)` 之后，认证成功每隔 n 秒发一个 `keepalive@openssh.com`；连续 3 个
  （`Configuration.keepAliveMaximumUnanswered`）没回应就关连接，断开原因 `SSHDisconnectReason.keepAliveTimeout(unansweredProbes:)`，
  判死约需 `n × 4` 秒。默认 `nil`（不发，今天的行为）。跳板机两跳各自保活。uTerm 自己的看门狗可以改用它，或继续用 `ping()`。
- **算法预设**（`SSHAlgorithms`）：
  - `.builtInOnly`（USSHKit 默认，今天的行为）：AES-GCM、curve25519 / ECDH、ed25519 / ECDSA 主机密钥。**RSA 用户私钥照样能登录**；
    只有 RSA 主机密钥的服务器握手失败（「与服务器没有共同支持的算法」）。
  - `.standard`：再加 RSA 主机密钥（`rsa-sha2-512/256`）、DH group16-sha512 / group14-sha256、AES-CTR + hmac-sha2（ETM 在前）。
  - `.legacyCompatible`：再加 SHA-1 的 `ssh-rsa`（主机与用户）、group14-sha1、hmac-sha1。只在用户明确要连老设备时用；它会触发进程级的
    旧算法登记，但不影响别的连接（接受与否按连接判断）。
  - 放宽与否是产品决定，经 `connect(…, algorithms:)` 传。
- **RSA 用户私钥**（`SSHAuthenticationMethod.rsaPrivateKey`，USSHKit 导入的 RSA 私钥都走它）：服务器宣告了 `server-sig-algs`
  （OpenSSH 7.2+）就直接用它列的最好的那个，只占一次认证次数；没宣告就依次 `rsa-sha2-512`、`rsa-sha2-256`；只有连接允许旧算法时
  才再试 `ssh-rsa`。

## 6. SFTP

- **路径**：`SFTPPath` 按字节往返（非 UTF-8 的文件名也能原样操作）。`SFTPClient` 的每个方法都有 `SFTPPath` 与 `String` 两个重载；
  `realPath` / `readLink` 给 `SFTPPath` 就回 `SFTPPath`，给 `String` 回 `String`。目录项 `SFTPDirectoryEntry.name: SFTPPath`；
  **拿目录项做后续操作（stat、打开、改名、删除）用 `entry.name`**，`entry.filename` 只是给显示的解码字符串（非法字节被替换）。
- **名字对照**：`getAttributes(at:)` → `stat(_:)`；`openFile(filePath:flags:)` → `openFile(_:flags:)`；`rename(at:to:)` →
  `rename(_:to:mode:)`（`.posix` 原子替换已存在的目标）；`remove(at:)` → `remove(_:)`；`rmdir(at:)` → `removeDirectory(_:)`；
  `createDirectory(atPath:)` → `createDirectory(_:)`；`getRealPath(atPath:)` → `realPath(_:)`；`listDirectory(atPath:)` → `listDirectory(_:)`。
- **错误只有一种**：服务端状态一律 `SFTPError.status(code:message:languageTag:)`，按 `error.statusCode`（`.noSuchFile`、`.permissionDenied`、
  `.fileAlreadyExists`……）判断。Citadel 的两种装法（裸 `SFTPMessage.Status` 与 `SFTPError.errorStatus`）都没了。
- **单次读写的上限**跟服务器的 `limits@openssh.com` 走（OpenSSH 是 255 KiB），没宣告时按 32 KiB：`client.maximumReadLength` /
  `client.maximumWriteLength`。`write(_:at:)` 超过上限抛 `requestTooLarge`，不会切块；`read(from:length:)` 超过上限按上限要。
  **app 自己的流水线（uTerm 的 `SFTPPipeline` 写死的 32 000）要按这两个值切块**，USSHKit 的 `SSHFileTransferSession` 已经这样做。
- **完整性**：知道大小时用 `file.readAll(from:expectedLength:maximumBytes:window:)`：读不满就抛 `SFTPError.shortRead(expected:actual:)`，
  不会把被截短的数据当成功；0 字节的 DATA、EOF 后面又冒出数据都是 `invalidResponse`。区间越过 `UInt64` 抛 `offsetOutOfRange`。
  `SSHFileTransferSession.download` 现在按 stat 的大小分段（每段 8 MiB）`readAll(expectedLength:)`：**下载过程中文件变短 →
  报 `shortRead`**（以前按成功返回、只拿到前一部分）；变长照旧读到 EOF。
- `SFTPFile` 是 `Sendable` 的值，可以从多个任务并发 `read` / `write`；`close()` 等在途的请求都回来再关，关之后不会再往旧句柄发请求。

## 7. 错误怎么分类

### 7.1 「传输断了、值得重连吗」（替代 `SSHTransportFailure` 里对 Citadel / `NIOSSHError.tcpShutdown` 的判断）

| 错误 | 网络断了、值得重连？ | 说明 |
|---|---|---|
| `SSHChannelError.connectionClosed(.transportError(e))` | **是** | 传输层出错（`IOError` 的 errno、`ChannelError`；跳板机外层断掉时内层是 `NIOSSHError.tcpShutdown`）；`e` 原样保留，可再按 errno 细分。`e` 是 `SSHHostKeyChangedDuringRekey` 时**不是**网络问题（重新交换时对端换了主机密钥），不要自动重连 |
| `SSHChannelError.connectionClosed(.remoteClosed)` | **是** | 对端关了连接（TCP EOF 或 `SSH_MSG_DISCONNECT`）：服务器重启、被 NAT / 防火墙掐断都是这样 |
| `SSHChannelError.connectionClosed(.keepAliveTimeout)` | **是** | 保活判死（链路卡死、对端失联） |
| `SSHChannelError.connectionClosed(.localClose)` | 否 | 本端关的 |
| `client.disconnectReason` / `onDisconnect` 的原因 | 同上四行 | 连接级的同一套原因 |
| `SFTPError.connectionClosed` | **是**，先看连接的 `disconnectReason` | SFTP 通道没了；连接还在而只是通道关了时重开 SFTP 即可 |
| `SSHChannelError.channelFailed(e)` | 否（重开这条通道即可） | 只坏了这一条通道，连接没事 |
| `SSHChannelError.channelClosed` | 否 | 通道已经关了还在用它（调用方的问题） |
| `SSHChannelError.timeout` | 视情况 | `ping` 超时：连接可能半死，由调用方决定要不要关掉重连 |
| `SSHChannelError.openRejected(f)` | 否 | 服务器拒绝开通道，按 `f.reason` 告诉用户（7.2） |
| `SSHChannelError.requestRejected` / `.globalRequestRejected` | 否 | 服务器拒绝了 PTY / exec / subsystem / 端口转发请求 |
| `SFTPError.status` / `.invalidResponse` / `.shortRead` / `.requestTooLarge` / `.extensionUnsupported` / `.handleClosed` / `.limitExceeded` / `.offsetOutOfRange` / `.unsupportedVersion` | 否 | 应用层错误，原样报给用户 |
| `SSHCommandError` | 否 | 命令自己的结果 |
| `CancellationError` | 否 | 本端取消 |

建连阶段（`SSHClientError`，USSHKit 已经归进 `SSHConnectionError`）：

| `SSHClientError` | USSHKit 抛的 | 值得重试？ |
|---|---|---|
| `.connectTimeout`、`.connectFailed`、`.handshakeTimeout`、`.connectionClosed` | `.connectFailed` | 是（网络问题） |
| `.handshakeFailed`（协议错误、算法协商不成，包括 USSHCore 算法实现抛的错） | `.connectFailed`（「SSH 握手失败：…」） | 否（配置问题，重试不会好；协商不成时文案提示可能要放宽算法） |
| `.authenticationFailed`、`.authenticationDelegateFailed` | `.authenticationFailed` | 否 |
| `.hostKeyRejected`、`.hostKeyValidationTimeout` | `.hostKeyRejected` | 否 |

### 7.2 开通道被拒（`SSHChannelOpenFailure.reason`）

| 原因 | 用户看到（`SSHChannelError.errorDescription`） | `SSHForwardingChannelFailure.Kind`（转发场景的文案） |
|---|---|---|
| `.administrativelyProhibited`（1） | 服务器禁止打开这类通道（例如关闭了端口转发） | `.administrativelyProhibited`：跳板机拒绝端口转发（sshd 可能配置了 AllowTcpForwarding no） |
| `.connectFailed`（2） | 服务器连不上目标（连接被拒绝或地址不可达） | `.connectFailed`：跳板机无法连接目标 host:port |
| `.resourceShortage`（4） | 服务器资源不足，暂时打不开新通道（例如超过了 MaxSessions） | `.resourceShortage`：跳板机暂时打不开到 host:port 的通道 |
| `.unknownChannelType`（3）、`.other(code)` | 服务器不支持这类通道 / 服务器拒绝打开通道（原因码 N）：说明 | `.other` |

## 8. 其他行为差异

- **取消真的生效**：开通道、exec、SFTP 请求、建连、撤销远程转发都响应任务取消（以前 Citadel 的 exec 与开通道不响应，要靠
  `withForwardingTimeout` 兜底；这个函数照旧可用）。
- **direct-tcpip 半关闭**：`TunnelGlue` 在本地读到 EOF 时的 `outbound.finish()` 现在真的向服务器发 EOF，和 OpenSSH 的 `-L` 一致。
- **主机密钥在重新交换时钉住**：重新交换不再调主机密钥回调；对端换了密钥是硬失败（`.transportError(SSHHostKeyChangedDuringRekey)`）。
- **RSA 私钥**：1024–8192 位都能导入（1024 位以前在建连时失败；8192 位以上以前能导入，现在导入时就报不支持）；分量互相不一致时在导入时
  就报「私钥结构损坏」；私钥段只有 n / e / d 的 OpenSSH 容器由 n / e / d 还原素因子，和别的 RSA 私钥一样走 SHA-2（以前回退 Citadel
  的 SHA-1）。
- **认证失败的文案**按实际发出过的方式说（「服务器拒绝了密码」「服务器拒绝了私钥」「服务器不接受所提供的认证方式（服务器支持：…）」）。

## 9. 在 app 的测试里用 `USSHTestServer`（替代 Citadel 的 `SSHServer`）

app 的测试宿主带沙盒、起不了 `sshd`，以前用 Citadel 的 `SSHServer.host(…)` + `enableSFTP(withDelegate:)`。现在链 `USSHTestServer`：

```swift
import USSHTestServer
@_spi(uTermIntegration) import USSHKit

let fileSystem = try SFTPLocalFileSystem.makeTemporary()       // 真实临时目录；也可以自己实现 SFTPServerFileSystem（参数是 SFTPPath）
var configuration = SSHTestServer.Configuration(
    authentication: .init(passwords: ["tester": "secret"]),     // 或 authorizedKeys / custom / decision / .acceptAnyone
    exec: .routes(["uname": .scripted(stdout: "Linux\n")]))
configuration.serveSFTP(fileSystem: fileSystem)                 // 可带 SFTPServer.Configuration（扩展、limits）与 SFTPFaultInjector
let server = try await SSHTestServer.start(configuration)
defer { Task { await server.stop(); try? fileSystem.removeRoot() } }

let client = try await USSHKitIntegration.connect(
    endpoint: SSHEndpoint(host: server.host, port: server.port, username: "tester"),
    credential: .password("secret"), hostKeyStore: store, hostKeyPolicy: .insecureAcceptAll,
    connectTimeout: .seconds(10), approver: { _ in true })
```

- 监听 `127.0.0.1` 的随机端口（`server.port`），主机公钥 `server.hostPublicKey`。
- **RSA**：`authorizedKeys` 里放 `NIOSSHPublicKey(rsaPublicKey:)` 或解析 `ssh-rsa …` 行（先 `SSHAlgorithms.registerStandardAlgorithms()`）；
  `authentication.acceptedRSASignatureAlgorithms` 限定服务端收哪些签名算法，`configuration.serverSignatureAlgorithms` 控制
  发不发 `server-sig-algs`；`configuration.useRSAHostKey(key, algorithms:)` 让服务端只用 RSA 主机密钥（测 `.builtInOnly` 拒绝、`.standard` 接受）。
- **记录**：`server.events`（认证尝试含 RSA 签名算法、exec 命令、PTY 与窗口变化、环境变量、direct-tcpip 目标、远程转发……），
  `waitForEvents { … }` 等某件事发生。
- **故障**：`SSHTestFaults`（认证延迟、先拒 N 次、不发版本行测握手超时）；`authentication.decision` 返回 `.partialSuccess(remaining:)`
  测多步认证；`dropAllConnections()`（掐断 TCP，客户端看到 `.remoteClosed`）；`freezeAllConnections()`（不读不写、TCP 还在，测保活判死）；
  `rekeyAllConnections()`（服务端发起重新交换）；`openChannelToClient(_:)`（服务端主动开通道）。SFTP 一侧 `SFTPFaultInjector`：
  延迟、按操作失败、`limitReadLength(to:)` 短读、`reverseResponseOrder(batchSize:)` 乱序回答、断线、扣住回答。
- shell 默认回显（`.echoShell`），direct-tcpip 默认真的去连目标（不允许时回原因码 2）、远程转发默认放行，都能在配置里关掉。
- 例子：本包 `Tests/USSHKitTests` 的 `ConnectIntegrationTests`、`AlgorithmPolicyTests`、`SFTPSessionIntegrationTests`、`ForwardingIntegrationTests`。
