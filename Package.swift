// swift-tools-version: 6.2

import PackageDescription

/// uTable / uTerm 共用的包。原先每个包各自住在其中一个 app 仓库里、由另一个 app
/// 按 `../<兄弟仓库>/Packages/<名字>` 的相对路径引用——本地包不进
/// `Package.resolved`，于是发版产物里到底嵌了哪一版共享代码，任何地方都没有记录。
/// 集中到这里并按 tag 发布之后，两个 app 的 `Package.resolved` 会钉住具体 revision，
/// 历史发版才能复现。
///
/// 注意：本包按 tag 被消费，因此**不能有任何 path 依赖**——SwiftPM 会拒绝
/// 「stable-version 的包依赖 unstable-version 的包」。USSHKit 的两个 fork 正是为此
/// 从 uTerm 的 `vendor/` 里拆成了独立仓库。
let package = Package(
    name: "uAppKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "UDesignKit", targets: ["UDesignKit"]),
        .library(name: "UAppKitBridge", targets: ["UAppKitBridge"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "USSHKit", targets: ["USSHKit"]),
        .library(name: "UPaneTree", targets: ["UPaneTree"]),
        .library(name: "UPaneGroups", targets: ["UPaneGroups"]),
        .library(name: "UControlKit", targets: ["UControlKit"]),
        .library(name: "AgentProviders", targets: ["AgentProviders"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "AgentRuntimeUI", targets: ["AgentRuntimeUI"]),
    ],
    dependencies: [
        // 两个打过补丁的 fork。exact 钉死：它们不走语义化版本演进，每次动都是
        // 人工重放补丁，不该让解析器自己挑版本。补丁清单见各仓库的 PATCHES.md。
        .package(url: "https://github.com/uozi-tech/Citadel.git", exact: "1.0.2"),
        .package(url: "https://github.com/uozi-tech/swift-nio-ssh.git", exact: "1.0.0"),
        .package(url: "git@github.com:apple/swift-nio.git", from: "2.81.0"),
        .package(url: "git@github.com:apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
        .package(url: "git@github.com:apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "git@github.com:apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "UDesignKit"),
        // 分屏二叉树。原先 uTable / uTerm 各有一份逐字相同的实现，只有文档
        // 措辞不同；两边改一处就得手工同步到另一处。纯值类型、无平台依赖，
        // 天然属于共享包。
        .target(name: "UPaneTree"),
        // macOS 专用（AppKit 事件桥）。源码整体用 `#if os(macOS)` 包住，
        // 这样即使被拉进 iOS 的构建图也只是空目标，不会编译失败。
        .target(name: "UAppKitBridge"),
        // 「分屏里装标签」的 VSCode 编辑组模型：树的叶子是组，组内一排标签 +
        // 一个前台标签，全区域一个活动组。视图层 macOS 专用（拖拽走 AppKit、
        // 按下激活走 UAppKitBridge），模型层与投放区归类在 `#if` 之外，纯逻辑
        // 单测在任何平台都能跑。
        .target(name: "UPaneGroups", dependencies: ["UPaneTree", "UDesignKit", "UAppKitBridge"]),
        // 本机 IPC 的外部 agent 通道核心：Unix socket 服务端、请求分发与门禁、开关设置。
        // 以前 uTerm / uTable 各有一份同源实现（出自 uService 的 `ServiceControlServer`），
        // 这里以 uTerm 版为基准泛型化。macOS 专用，源码整体用 `#if os(macOS)` 包住，
        // 理由同 UAppKitBridge。Swift 6 语言模式；包内没有默认 MainActor 隔离，
        // 每个类型都显式标注了隔离。
        .target(name: "UControlKit"),
        // 原先是 swift-tools-version 5.10，即 Swift 5 语言模式。这里统一到 6.2
        // 是为了 UDesignKit，不该顺手把 AgentKit 拖进 Swift 6 严格并发——
        // 那是一次独立的迁移，要单独做、单独验。
        .target(name: "AgentKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // 三个 app 共享的 AI provider：SwiftData `LLMProvider`（共享 iCloud 容器
        // `iCloud.com.uozi.shared`）、共享钥匙串组里的 API Key、旧数据导入器。
        // Swift 6 语言模式；与 UControlKit 一样没有默认 MainActor 隔离，每个类型显式标注。
        .target(name: "AgentProviders", dependencies: ["AgentKit", "UDesignKit"]),
        // 内置 agent 运行时：工具协议与注册表、审批、agent 循环、会话 codec、slash 命令。
        // 以 uTable 的 `Core/Agent` 为蓝本泛型化。Swift 6，显式隔离。
        .target(name: "AgentRuntime", dependencies: ["AgentKit", "AgentProviders"]),
        // `UDAgentPanel`：把 `AgentRuntimeSession` / `AgentApprovalQueue` 绑到 UDesignKit 的
        // 纯展示 agent 视图上。
        .target(name: "AgentRuntimeUI", dependencies: ["AgentRuntime", "AgentKit", "UDesignKit"]),
        // 同上：原先也是 5.10。
        .target(
            name: "USSHKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                // bcrypt_pbkdf。解密带口令的 OpenSSH 私钥容器要用，整个 SSH 栈里
                // 只有这个 C target 有实现；Citadel fork 为此把它导出成了 product。
                .product(name: "CCitadelBcrypt", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "UDesignKitTests", dependencies: ["UDesignKit"]),
        .testTarget(name: "UAppKitBridgeTests", dependencies: ["UAppKitBridge"]),
        .testTarget(name: "UPaneTreeTests", dependencies: ["UPaneTree"]),
        .testTarget(name: "UPaneGroupsTests", dependencies: ["UPaneGroups", "UPaneTree", "UAppKitBridge"]),
        .testTarget(name: "UControlKitTests", dependencies: ["UControlKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AgentProvidersTests", dependencies: ["AgentProviders", "AgentKit"]),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime", "AgentProviders", "AgentKit"]),
        .testTarget(name: "AgentRuntimeUITests", dependencies: ["AgentRuntimeUI", "AgentRuntime", "UDesignKit"]),
        .testTarget(
            name: "USSHKitTests",
            dependencies: [
                "USSHKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
