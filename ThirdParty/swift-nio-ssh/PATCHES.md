# swift-nio-ssh 的补丁

基线：[Wellz26/swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) `0.3.6`
（`a05e6bbe6b141ee68da3030e00275504c0595d4d`），只取 `Sources/NIOSSH`。补丁按序在 `patches/`，
每个补丁的提交说明里有完整的根因。

## 0001 我方已发 CLOSE 后不再回 window-adjust

`SSHChildChannel.deliverSingleRead` 的 `.data` 分支。channel 进入 `.closedLocally` / `.closed`
后还在排空缓冲读时，原代码会回 `CHANNEL_WINDOW_ADJUST`，`sendChannelWindowAdjust` 对已关闭状态
`preconditionFailure`，在 event-loop 线程 abort 整个进程（uTerm 1.6.0 线上崩溃，
`ChildChannelStateMachine.swift:432` "Sent channel window adjust on channel in invalid state"）。
加 `!state.sentClose` 守卫。

**去掉的时机**：apple/swift-nio-ssh 早已这么修；Wellz26 的 fork 合进这一修复，或 Citadel 改用 Apple 版之后。

## 0002 对端先关（`.closedRemotely`）时也不回 window-adjust

0001 只挡住我方先关。对端先发 `CHANNEL_CLOSE`（网络抖动、远端掉线）时状态是 `.closedRemotely`，
`sentClose` 为 false，同一个崩溃照样触发。`ChildChannelStateMachine` 新增 `canSendWindowAdjust`
（只对 `sendChannelWindowAdjust` 接受的 4 个状态为 true），`deliverSingleRead` 改用它。

**去掉的时机**：apple/swift-nio-ssh 的 main 仍只有 `sentClose` 守卫，这个补丁可以提给 Apple；
上游合进去、且 NIOSSH 的来源跟上之后。

## 0003 closeFuture 永不失败；已关闭 channel 上的打开请求直接失败

- 在已关闭的 channel 上发起打开时，原代码用 `closeFuture.cascadeFailure` 让 promise 失败，
  但 closeFuture 从不失败，promise 永远挂着。改成直接以 `ioOnClosedChannel` 失败。
- 出错拆除时原代码让 `closePromise` 失败，违反 NIOCore「closeFuture 永不失败」的约定：
  `NIOAsyncChannel.executeThenClose` 对此断言，SSH 传输突然断开时包成 `NIOAsyncChannel` 的
  direct-tcpip channel（USSHKit 的 `-L` 转发）在 Debug 构建里崩溃。改成 `succeed`。

**去掉的时机**：两处都是通用 bug，提给上游之前先核对 apple/swift-nio-ssh 有没有修过。

## 0004 修改声明

Apache-2.0 第 4(b) 条：给 0001–0003 改过的两个文件（`SSHChildChannel.swift`、
`ChildChannelStateMachine.swift`）头部加一行 `Modified by uAppKit`。其他补丁不再改到新文件时它不用动；
新补丁改到别的文件，就给那个文件也加一行（写在这个补丁里）。

## 验证

线上崩溃只在 `-L` / `-D` / 长连接**远端先断**时复现。改这几个补丁之后，发版前要在真机上做断网 smoke，
编译通过不等于修好。
