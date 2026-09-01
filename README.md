# uAppKit

uTable 与 uTerm 共用的包，一个 SwiftPM 包三个产品。

| 产品 | 用途 | 平台 |
|---|---|---|
| `UDesignKit` | 设计语言 token 与 UD 组件 | macOS 14+ / iOS 18+ |
| `UAppKitBridge` | SwiftUI ↔ AppKit 事件桥（`.onPointerDown`） | macOS 14+ |
| `AgentKit` | AI 助手的会话与工具协议 | macOS 14+ / iOS 18+ |

## 为什么单独一个仓库

这三个包原先各自住在其中一个 app 仓库里，由另一个 app 按
`../<兄弟仓库>/Packages/<名字>` 的相对路径引用。这样有两个后果：

1. 任何一个 app 都不能单独 clone —— 必须两个仓库并排放，目录名还得一字不差。
2. **本地包不进 `Package.resolved`**。所以一个已签名公证、正在通过 Sparkle 推给
   用户的发版产物里，到底嵌了哪一版 UDesignKit，任何地方都没有记录，历史发版
   无法复现。

集中到这里并**按 tag 发布**之后，两个 app 的 `Package.resolved` 会钉住具体
revision，上面两条都不成立了。

## 消费方式

两个 app 按远程依赖 + 版本 tag 引用：

```
https://github.com/uozi-tech/uAppKit
```

### 本地开发：用 workspace 覆盖远程依赖

日常改包时不必"改一行就提交打 tag"。两个 app 各自带了一个 **dev workspace**，
把本仓库挂进去，Xcode 会用本地副本覆盖同名的远程依赖（按 `Package.swift` 里的
包名 `uAppKit` 匹配，与 URL 无关）：

```
uTable/uTable-dev.xcworkspace     ← uTable.xcodeproj + ../uAppKit
uTerm/uTerm-dev.xcworkspace       ← uTerm.xcodeproj  + ../uAppKit
```

用 Xcode 打开 `*-dev.xcworkspace` 而不是 `.xcodeproj`，就能在 app 里直接改包源码、
断点、跑测试，改动即时生效，不经过 git。命令行同理：

```sh
xcodebuild -workspace uTable-dev.xcworkspace -scheme uTable ...
```

这两个 workspace **被 gitignore 了**，是每个人本地的东西。原因是它一旦提交，
发版构建也会走本地覆盖——那按 tag 钉版本就白做了。新机器上自己建一个即可，
内容就是两个 `FileRef`（工程 + `../uAppKit`）。

改完之后的正常流程：在 uAppKit 里提交 → 打 tag → 在 app 里把版本要求升上去 →
用 `.xcodeproj`（不是 dev workspace）验一遍，确保拿的是发布出去的那一版。

> 怎么确认覆盖真的生效了：看编译命令里 `UDColor.swift` 的路径。走覆盖时是
> `<workspace>/uAppKit/Sources/...`，没走覆盖时是
> `DerivedData/SourcePackages/checkouts/uAppKit/Sources/...`。

## 语言模式

包整体是 swift-tools-version 6.2（Swift 6 语言模式），但 `AgentKit` 显式钉在
`.swiftLanguageMode(.v5)` —— 它迁进来之前是 tools-version 5.10。把它拖进 Swift 6
严格并发是一次独立的迁移，要单独做、单独验，不该混在搬家里顺手完成。

## 尚未迁入

`USSHKit` 仍在 uTerm。它依赖 `vendor/Citadel` 与 `vendor/swift-nio-ssh` 两个
vendored fork（相对路径指进 uTerm），搬它得连这两个 fork 一起处理，成本和风险都
另一个量级。
