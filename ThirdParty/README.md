# ThirdParty：编进本包的上游源码

SSH 栈最底下的 swift-nio-ssh 带着补丁，没法作为普通依赖引用（SwiftPM 没有「解析时打补丁」的机制，
本包又按 tag 发布、不能带 path 依赖）。所以上游源码直接作为本包的 target 编进来：

| target | 上游 | 基线 | 许可证 | 补丁 |
|---|---|---|---|---|
| `NIOSSH`（及测试 `NIOSSHTests`） | [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | `0.15.2`（`e8de09a2`） | Apache-2.0 | 5 个，见 [swift-nio-ssh/PATCHES.md](swift-nio-ssh/PATCHES.md) |

每个组件一个目录：`UPSTREAM`（来源与基线）、`patches/`（按序重放的补丁，`git format-patch` 格式）、
`PATCHES.md`（每个补丁为什么存在、什么时候能去掉）、上游的 `LICENSE`。

为什么 NIOSSH 跟 apple/swift-nio-ssh：以前用的 Wellz26 fork 0.3.6 在 2022 年从 Apple 的 0.4.0 分出去，
之后 Apple 的加固（超长 mpint、认证次数上限、缓冲上限、最大包长、`readVersion` 崩溃等）全都没有；而我们真正需要
fork 的只有「自定义密钥 / 签名 / 密钥交换」的注册接口。现在这两个接口在 Apple 0.15.2 上作为补丁 0003 / 0004
重做（公开 API 见 [swift-nio-ssh/EXTENSION-API.md](swift-nio-ssh/EXTENSION-API.md)），RSA、DH 等算法在
USSHCore 里实现，不进 NIOSSH。

客户端层原先是 [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1（同样编进本包、带一个补丁）。
它依赖那个 fork 的 API，在 Apple 版上编不过；而且上游 2026-04 之后没有提交，我们为它的设计绕了很多路
（登录超时写死、`withPTY` 只能挂着闭包、断开回调只能挂一个、exec 取消不了、`SFTPFile` 不是 Sendable）。
2026-11 换成我们自己的 `USSHCore`，Citadel 连同它的补丁、`Citadel` product 一起删掉了，app 的迁移见
[`docs/ssh-stack-migration.md`](../docs/ssh-stack-migration.md)。

**不在这里的**：`Sources/CBcryptPBKDF` 是 OpenBSD 的 `bcrypt_pbkdf`（解密带口令的 OpenSSH 私钥用），当年随 Citadel
一起取来（Citadel 里叫 `CCitadelBcrypt`）。它没有要跟的上游，改名后作为我们自己的普通 target 维护，可以直接改，
不走 `sync.sh`；来源与许可见仓库根目录的 `THIRD_PARTY_NOTICES.md`。

NIOSSH 连同上游自己的测试一起取（`UPSTREAM` 的 `PATHS` 有两项），编成测试 target `NIOSSHTests`：升级时它是回归网，
补丁的回归测试也写在那里。

## 规矩

- **`Sources/NIOSSH`、`Tests/NIOSSHTests` 是生成出来的，别直接改。**
  改动写成补丁放进 `patches/`，再跑 `apply`。`check` 会拦下「直接改了 Sources/」。
- 模块名保持上游原名（`import NIOSSH` 不用改），代价是同一个构建图里不能再出现上游的 swift-nio-ssh 包，
  否则模块重名编不过。依赖本包的 app 不要再单独引用它（也别再引用上游的 Citadel：它依赖上游的 swift-nio-ssh）；
  app 只要 `import USSHKit`，`USSHCore` 被它转出去了。
- Apache-2.0 第 4 条：NIOSSH 被改过的文件头部带一行修改声明（swift-nio-ssh 的补丁 0005），LICENSE.txt 随包保留。

## 命令

```sh
Tools/ssh-stack/sync.sh check            # 核对 Sources/ == 上游基线 + 补丁（只读；要联网 clone 上游）
Tools/ssh-stack/sync.sh apply [组件]     # 按 UPSTREAM 重新生成 Sources/，补丁按新上下文重新导出
Tools/ssh-stack/sync.sh finish <组件>    # apply 冲突、手工解决后收尾
bash Tools/ssh-stack/sync.test.sh        # 脚本自测（离线）
```

组件名就是这里的目录名，现在只有 `swift-nio-ssh`。设了 `SSH_STACK_CACHE=<目录>` 时从
`<目录>/<组件>` 的现成 clone 取上游，不联网。

## 加一个补丁

1. `Tools/ssh-stack/sync.sh apply <组件>` 之后，工作区 `.build/ssh-stack/<组件>/repo` 是「基线一笔 + 补丁逐笔」的 git 仓库
   （`apply` 成功后它还留着）。
2. 在那里改代码、`git commit`（提交信息写清楚根因和改法，它就是补丁的说明）。
3. `Tools/ssh-stack/sync.sh finish <组件>`：拷回 `Sources/`，重新导出 `patches/`。
4. 在 `PATCHES.md` 里补一节，跑 `swift test --filter NIOSSHTests` 与上层（USSHCore / USSHKit）的测试。
   NIOSSH 的补丁要带回归测试，写在 `Tests/NIOSSHTests` 里（同一个提交）；改了上游文件就在修改声明补丁里给它加一行。

## 升级上游

1. 改 `UPSTREAM` 的 `TAG` 与 `REV`。
2. `Tools/ssh-stack/sync.sh apply <组件>`。补丁打不上会停在 `git am` 中途、不动 `Sources/`，按提示进工作区
   解决（`git am --continue`），再 `finish`。上游已经包含某个补丁时 `git am --skip` 掉它，并删掉
   `PATCHES.md` 里那一节。
3. 核对上游 manifest 有没有新增依赖或编译设置，同步进本包 `Package.swift` 里对应的 target（NIOSSH 还有测试 target
   `NIOSSHTests`）。
4. 先 `swift test --filter NIOSSHTests`（上游测试 + 补丁的回归测试），再跑 USSHCore / USSHKit 的测试，最后到 app 里
   跑 SSH 相关的用例。swift-nio-ssh 升级算协议层变更，发版说明里要写。

## 来历

2026-06 起这两份源码在 uTerm 的 `vendor/` 里，2026-09 为了让 USSHKit 搬进按 tag 发布的 uAppKit，
拆成了两个独立的 fork 仓库（Citadel 1.0.2、swift-nio-ssh 1.0.0）。
2026-11 改成「上游源码 + 补丁重放」：两个 fork 仓库不再需要，manifest 上的补丁（改依赖地址、裁掉示例与测试、放宽版本区间、
导出 `CCitadelBcrypt`）随之全部消失，只剩源码补丁。
2026-11-24 起 NIOSSH 的基线从 Wellz26 fork 0.3.6 换成 apple/swift-nio-ssh 0.15.2（连同它的测试），旧的 4 个补丁
在新基线上重做或去掉，另加两个扩展接口，见 [swift-nio-ssh/PATCHES.md](swift-nio-ssh/PATCHES.md)。
2026-11-24 起客户端层换成 USSHCore，Citadel（`ThirdParty/Citadel/` 与它唯一的补丁「login timeout 可配置、登录失败关 channel」）
删除：USSHCore 把握手时限做成配置项、等主机密钥确认的时间单独计，失败时关通道，那个补丁要解决的问题不存在了。
