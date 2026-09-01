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

日常要改包时，不必"改一行就提交打 tag"：把本地的 uAppKit 目录拖进 app 的
`.xcworkspace`，Xcode 会用本地副本覆盖同名的远程依赖；改完再提交、打 tag、
在 app 里升版本。

## 语言模式

包整体是 swift-tools-version 6.2（Swift 6 语言模式），但 `AgentKit` 显式钉在
`.swiftLanguageMode(.v5)` —— 它迁进来之前是 tools-version 5.10。把它拖进 Swift 6
严格并发是一次独立的迁移，要单独做、单独验，不该混在搬家里顺手完成。

## 尚未迁入

`USSHKit` 仍在 uTerm。它依赖 `vendor/Citadel` 与 `vendor/swift-nio-ssh` 两个
vendored fork（相对路径指进 uTerm），搬它得连这两个 fork 一起处理，成本和风险都
另一个量级。
