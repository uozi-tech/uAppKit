# Citadel 的补丁

基线：[orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) `0.12.1`
（`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`），只取 `Sources/Citadel` 与 `Sources/CCitadelBcrypt`。

## 0001 login timeout 可配置，登录失败时关闭 channel

文件：`Sources/Citadel/ClientSession.swift`、`Sources/Citadel/Client.swift`。

上游 `SSHClientSession.addHandlers` 把 `ClientHandshakeHandler` 的 `loginTimeout` 写死成 10 秒，从 handler
装进 pipeline 起算，覆盖 TCP + 版本交换 + KEX + 认证全程。主机密钥校验就在 KEX 期：`.ask` 策略下用户在
首连 / 密钥变化的确认框上停超过 10 秒，`authenticated` 以 `ChannelError.connectTimeout` 失败，`connect` 抛错
（用户看到「ChannelError 错误 0」）。上游失败后不关 channel，握手在后台照常走完、认证成功，socket 泄漏到
进程退出。

- `SSHClientSettings` 新增 `loginTimeout`（默认 10 秒，与上游一致），`addHandlers` 改用它。
- `SSHClientSession.connect` 与 `SSHClient.connect` 两个便捷入口加带默认值的 `loginTimeout:` 参数，源码兼容。
- `handshakeHandler.authenticated` 失败时关闭 channel。

USSHKit 把 `loginTimeout` 设成「连接超时 + 主机密钥审批超时」（`SSHClientFactory`）。

**去掉的时机**：可以提给上游。上游若把 login timeout 做成可配置但字段名不同，USSHKit 改用上游的名字，
保留「失败时关闭 channel」这一条。

## 不用再改 manifest

以前的 Citadel fork 还改了 `Package.swift`（nio-ssh 指向我们的 fork、裁掉示例与测试 target、放宽 BigInt /
swift-crypto 版本区间、导出 `CCitadelBcrypt`）。target 编进本包之后这些都由本包 `Package.swift` 决定，
不再有对应的补丁。升级上游时只需核对它的 Citadel target 依赖有没有变。
