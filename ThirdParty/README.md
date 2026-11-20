# ThirdParty：编进本包的上游源码

USSHKit 依赖的 SSH 栈带着补丁，没法作为普通依赖引用（SwiftPM 没有「解析时打补丁」的机制，
本包又按 tag 发布、不能带 path 依赖）。所以上游源码直接作为本包的 target 编进来：

| target | 上游 | 基线 | 许可证 | 补丁 |
|---|---|---|---|---|
| `NIOSSH` | [Wellz26/swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) | `0.3.6`（`a05e6bbe`） | Apache-2.0 | 4 个，见 [swift-nio-ssh/PATCHES.md](swift-nio-ssh/PATCHES.md) |
| `Citadel`、`CCitadelBcrypt` | [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) | `0.12.1`（`ae8562f8`） | MIT（bcrypt 部分为 OpenBSD 的 BSD 许可） | 1 个，见 [Citadel/PATCHES.md](Citadel/PATCHES.md) |

每个组件一个目录：`UPSTREAM`（来源与基线）、`patches/`（按序重放的补丁，`git format-patch` 格式）、
`PATCHES.md`（每个补丁为什么存在、什么时候能去掉）、上游的 `LICENSE`。

为什么 NIOSSH 用 Wellz26 的 fork 而不是 apple/swift-nio-ssh：Citadel 0.12.1 用到了这个 fork 加的
证书认证等 API，换成 Apple 的会编不过。

## 规矩

- **`Sources/NIOSSH`、`Sources/Citadel`、`Sources/CCitadelBcrypt` 是生成出来的，别直接改。**
  改动写成补丁放进 `patches/`，再跑 `apply`。`check` 会拦下「直接改了 Sources/」。
- 模块名保持上游原名（`import Citadel` / `import NIOSSH` 不用改），代价是同一个构建图里不能再出现
  上游的 Citadel / swift-nio-ssh 包，否则模块重名编不过。依赖本包的 app 不要再单独引用它们；
  app 要直接链 Citadel 时用本包导出的 `Citadel` product。
- Apache-2.0 第 4 条：NIOSSH 被改过的文件头部带一行修改声明（补丁 0004），LICENSE.txt 随包保留。

## 命令

```sh
Tools/ssh-stack/sync.sh check            # 核对 Sources/ == 上游基线 + 补丁（只读；要联网 clone 上游）
Tools/ssh-stack/sync.sh apply [组件]     # 按 UPSTREAM 重新生成 Sources/，补丁按新上下文重新导出
Tools/ssh-stack/sync.sh finish <组件>    # apply 冲突、手工解决后收尾
bash Tools/ssh-stack/sync.test.sh        # 脚本自测（离线）
```

组件名就是这里的目录名：`swift-nio-ssh`、`Citadel`。设了 `SSH_STACK_CACHE=<目录>` 时从
`<目录>/<组件>` 的现成 clone 取上游，不联网。

## 加一个补丁

1. `Tools/ssh-stack/sync.sh apply <组件>` 之后，工作区 `.build/ssh-stack/<组件>/repo` 是「基线一笔 + 补丁逐笔」的 git 仓库
   （`apply` 成功后它还留着）。
2. 在那里改代码、`git commit`（提交信息写清楚根因和改法，它就是补丁的说明）。
3. `Tools/ssh-stack/sync.sh finish <组件>`：拷回 `Sources/`，重新导出 `patches/`。
4. 在 `PATCHES.md` 里补一节，跑 USSHKit 的测试。

## 升级上游

1. 改 `UPSTREAM` 的 `TAG` 与 `REV`。
2. `Tools/ssh-stack/sync.sh apply <组件>`。补丁打不上会停在 `git am` 中途、不动 `Sources/`，按提示进工作区
   解决（`git am --continue`），再 `finish`。上游已经包含某个补丁时 `git am --skip` 掉它，并删掉
   `PATCHES.md` 里那一节。
3. 核对上游 manifest 有没有新增依赖或编译设置，同步进本包 `Package.swift` 里对应的 target。
4. `swift test --filter USSHKitTests`，再到 app 里跑 SSH 相关的用例。

## 来历

2026-06 起这两份源码在 uTerm 的 `vendor/` 里，2026-09 为了让 USSHKit 搬进按 tag 发布的 uAppKit，
拆成了两个独立的 fork 仓库（Citadel 1.0.2、swift-nio-ssh 1.0.0）。
2026-11 改成现在这样：两个 fork 仓库不再需要，manifest 上的补丁（改依赖地址、裁掉示例与测试、放宽版本区间、
导出 `CCitadelBcrypt`）随之全部消失，只剩源码补丁。`Sources/` 与那两个 fork 最后一版的源码逐字相同。
