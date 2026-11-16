# uAppKit

uTable、uTerm 与 uGit 共用的包，一个 SwiftPM 包多个产品。

| 产品 | 用途 | 平台 |
|---|---|---|
| `UDesignKit` | 设计语言 token 与 UD 组件；设置页原语 `UDSettings*`（分组卡片、行、列表行、行内提示等，来自 uTerm 的 `SettingsPrimitives`，需 macOS 15+） | macOS 14+ / iOS 18+ |
| `UAppKitBridge` | SwiftUI ↔ AppKit 事件桥（`.onPointerDown`、带位移死区的拖拽源 `.dragSource`）；跨屏拖窗口修正（`WindowMoveBehavior`、`TitlebarDragRegion`） | macOS 14+ |
| `AgentKit` | AI 助手的会话与工具协议 | macOS 14+ / iOS 18+ |
| `USSHKit` | SSH 连接、隧道与 SFTP | macOS 14+ / iOS 18+ |
| `UPaneTree` | 分屏二叉树（`LayoutNode` 与摊平几何） | macOS 14+ / iOS 18+ |
| `UPaneGroups` | 「分屏里装标签」的 VSCode 编辑组（模型 + 区域视图） | 模型 macOS/iOS；视图 macOS 14+ |
| `UControlKit` | 本机 IPC 外部 agent 通道核心（Unix socket 服务端、请求分发与门禁、开关设置）；AI 技能安装（`SkillCatalog` / `SkillInstaller` / `ClientLinkInstaller` / `SkillManagerModel` / `SkillReconciler`）；后台模式（`BackgroundServiceSettings` / `BackgroundLaunchMode` / `BackgroundWindowController` / `BackgroundLifecycleCommands`） | macOS 14+ |
| `UControlKitUI` | 「命令行与技能」设置页的三段区块 `UControlSettingsSections`，文案经 `CLISettingsCopy` 传入 | macOS 15+ |
| `AgentProviders` | 三个 app 共享的 AI provider：SwiftData `LLMProvider`（iCloud 容器 `iCloud.com.uozi.shared`）、共享钥匙串组里的 API Key、模型目录 Source、编辑草稿与测试连接、旧数据导入器 | macOS 14+ / iOS 18+（编辑表单仅 macOS） |
| `AgentRuntime` | 内置 agent 运行时：工具协议与注册表、审批策略 / 审批门 / 审批队列、agent 循环 `AgentRuntimeSession`、JSONL 审计、会话持久化 codec 与 `AgentChatStore`、`/` 命令匹配、Anthropic / OpenAI 兼容 provider | macOS 14+ / iOS 18+ |
| `AgentRuntimeUI` | `UDAgentPanel`：把会话与审批队列绑到 UDesignKit 的 agent 视图（`UDAgentTranscript` / `UDAgentApprovalCard` / `UDSlashMenu` / `UDAgentEmptyState` / `UDAgentToolTrace`） | 行映射 macOS/iOS；面板 macOS 14+ |

内置 agent 怎么接（工具、上下文、审批策略、持久化、provider、entitlements）见
`docs/agent-runtime.md`。

`Tools/` 不是 Swift 产品，是各 app vendor 的模板与客户端公共代码：

| 路径 | 用途 |
|---|---|
| `Tools/uctl/uctl_core.py` | 命令行客户端（`utablectl` / `utermctl` / …）的公共区 canonical 版；`sync-core.sh <ctl>` 回写，`selftest.py` 离线自测 |
| `Tools/xcode/copy-cli-and-skills.sh` | Run Script「Copy <ctl> CLI and Skills」：`CTL SLUG [--resources-copy]`；自测 `build-phases.test.sh` |
| `Tools/xcode/embed-login-item.sh` | Run Script「Embed Background Login Item」：`LAUNCHER` |
| `Tools/launcher/main.swift.template` | 后台登录项 launcher（沙盒 helper，不链本包） |
| `Tools/verify-background-launcher.py` | 发版前核 launcher 签名与沙盒 |

vendor 规则：app 把模板拷到自己仓库（build phase 脚本放 `scripts/build-phases/`），pbxproj 的
shellScript 只调它；改模板先改这里、再拷回各 app，不在 app 里分叉。

## 为什么单独一个仓库

`UDesignKit` / `UAppKitBridge` / `AgentKit` / `USSHKit` 原先各自住在其中一个 app 仓库里，由另一个 app 按
`../<兄弟仓库>/Packages/<名字>` 的相对路径引用。这样有两个后果：

1. 任何一个 app 都不能单独 clone —— 必须两个仓库并排放，目录名还得一字不差。
2. **本地包不进 `Package.resolved`**。所以一个已签名公证、正在通过 Sparkle 推给
   用户的发版产物里，到底嵌了哪一版 UDesignKit，任何地方都没有记录，历史发版
   无法复现。

集中到这里并**按 tag 发布**之后，两个 app 的 `Package.resolved` 会钉住具体
revision，上面两条都不成立了。

`UPaneTree` 的来源不同：它从来不是包，而是**两个 app 各抄了一份**的分屏树源码，
逐字相同、只有文档措辞按各自的叶子叫法（终端窗格 / 编辑组）改过。这种复制不会
被任何构建报错抓到，改一处忘了另一处就是静默的行为分叉，所以也收进来。

`UPaneGroups` 又不同：它是把 uTable 那套「分屏里装标签」泛型化抽出来，好让 uTerm
的预览区与终端区改用同一套模型。抽包的动机不是去重（uTerm 还没有这套），而是
**uTable 那 1165 行里有一半是被性能问题逼出来的**：面板拍平挂载而不建递归视图树、
活动态传对象不传 Bool、按下激活用 NSEvent 探针不用 SwiftUI 手势。这些约束在源码
注释里逐条写着出处和实测数字，重写一遍必然丢。设计与差异矩阵见
`docs/pane-groups-design.md`。

## 消费方式

两个 app 按远程依赖 + 版本 tag 引用：

```
https://github.com/uozi-tech/uAppKit
```

### 本地开发：用 uozi.xcworkspace 覆盖远程依赖

日常改包时不必"改一行就提交打 tag"。`path/to/dev.xcworkspace` 里同时挂着
两个 app 和本仓库，Xcode 会用本地副本覆盖同名的远程依赖（按 `Package.swift` 里的
包名 `uAppKit` 匹配，与 URL 无关）：

```
uozi.xcworkspace
├── uTable/uTable.xcodeproj
├── uTerm/uTerm.xcodeproj
└── uAppKit                  ← 覆盖两个 app 的远程 uAppKit 依赖
```

用 Xcode 打开 `uozi.xcworkspace` 而不是单个 `.xcodeproj`，就能在 app 里直接改包源码、
断点、跑测试，改动即时生效，不经过 git。命令行同理：

```sh
xcodebuild -workspace path/to/dev.xcworkspace -scheme uTable ...
```

`<workspace>` 本身不是 git 仓库，所以这个 workspace 天然只存在于本地，不会
把覆盖状态带进任何一个 app 的历史——**发版构建走 `-project uTable.xcodeproj`，
拿的仍是按 tag 钉住的那一版**。

两个 SSH fork（`Citadel` / `swift-nio-ssh`）也是 `<workspace>` 下的同级目录，
但默认**不**挂进 workspace：它们用 `exact:` 钉死、只在人工重放补丁时才动。真要改的
时候再拖进来，改完记得拖出去。

改完之后的正常流程：在 uAppKit 里提交 → 打 tag → 在 app 里把版本要求升上去 →
用 `.xcodeproj`（不是 workspace）验一遍，确保拿的是发布出去的那一版。

> 怎么确认覆盖真的生效了：看编译命令里 `UDColor.swift` 的路径。走覆盖时是
> `<workspace>/uAppKit/Sources/...`，没走覆盖时是
> `DerivedData/SourcePackages/checkouts/uAppKit/Sources/...`。

## 语言模式

`AgentProviders` / `AgentRuntime` / `AgentRuntimeUI` 是 Swift 6 语言模式，与 `UControlKit` 一样没有默认
MainActor 隔离，每个类型都显式标注了隔离（`@MainActor` / actor / `Sendable` 值类型）。

包整体是 swift-tools-version 6.2（Swift 6 语言模式），但 `AgentKit` 显式钉在
`.swiftLanguageMode(.v5)` —— 它迁进来之前是 tools-version 5.10。把它拖进 Swift 6
严格并发是一次独立的迁移，要单独做、单独验，不该混在搬家里顺手完成。

## 本包不能有 path 依赖

**按 tag 消费的远程包不允许带 path 依赖**，SwiftPM 会直接拒绝：

```
package 'X' is required using a stable-version but
'X' depends on an unstable-version package 'Y'
```

`USSHKit` 迁进来时正是撞上这条：它原先依赖 uTerm 里的 `vendor/Citadel` 和
`vendor/swift-nio-ssh` 两个 path 包。解法是把那两个 fork 也拆成独立仓库、按 tag 引用：

- `github.com/uozi-tech/swift-nio-ssh` —— 基线 `Wellz26/swift-nio-ssh` 0.3.6 + 补丁
- `github.com/uozi-tech/Citadel` —— 基线 `orlandos-nl/Citadel` 0.12.1，仅改 manifest

两者都用 `exact:` 钉死：它们不走语义化版本演进，每次动都是人工重放补丁，不该让
解析器自己挑版本。补丁清单见各仓库的 `PATCHES.md`。

往本包加依赖时记住这条约束——一条 path 依赖就会让两个 app 都解析失败。
