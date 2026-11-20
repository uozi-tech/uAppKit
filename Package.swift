// swift-tools-version: 6.2

import PackageDescription

/// uTable / uTerm 共用的包。原先每个包各自住在其中一个 app 仓库里、由另一个 app
/// 按 `../<兄弟仓库>/Packages/<名字>` 的相对路径引用——本地包不进
/// `Package.resolved`，于是发版产物里到底嵌了哪一版共享代码，任何地方都没有记录。
/// 集中到这里并按 tag 发布之后，两个 app 的 `Package.resolved` 会钉住具体 revision，
/// 历史发版才能复现。
///
/// 注意：本包按 tag 被消费，因此**不能有任何 path 依赖**——SwiftPM 会拒绝
/// 「stable-version 的包依赖 unstable-version 的包」。USSHKit 要的 Citadel 与
/// swift-nio-ssh 带着补丁，所以不作为依赖引用，而是把上游源码作为本包的 target
/// 编进来（见下方 `NIOSSH` / `Citadel`），补丁与来源记在 `ThirdParty/`。
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
        .library(name: "UControlKitUI", targets: ["UControlKitUI"]),
        // uTerm 的 iOS target 直接链这个 product（共享源码里 `import Citadel`）。
        .library(name: "Citadel", targets: ["Citadel"]),
    ],
    dependencies: [
        .package(url: "git@github.com:apple/swift-nio.git", from: "2.81.0"),
        .package(url: "git@github.com:apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
        .package(url: "git@github.com:apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "git@github.com:apple/swift-log.git", from: "1.0.0"),
        // 下面两个只有包内的 Citadel / NIOSSH 用。swift-atomics 写 https：swift-nio
        // 自己按 https 引用它，同一个包写两种地址会让 Xcode 解析时卡住。
        .package(url: "git@github.com:attaswift/BigInt.git", "5.2.0"..<"7.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
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
        // 本机 IPC 的外部 agent 通道核心：Unix socket 服务端、请求分发与门禁、开关设置；
        // 以及 AI 技能安装（链到 app 包内）与后台模式（登录项、CLI 按需启动、窗口恢复）。
        // 以前 uTerm / uTable 各有一份同源实现（出自 uService 的 `ServiceControlServer`），
        // 这里以 uTerm 版为基准泛型化。macOS 专用，源码整体用 `#if os(macOS)` 包住，
        // 理由同 UAppKitBridge。Swift 6 语言模式；包内没有默认 MainActor 隔离，
        // 每个类型都显式标注了隔离。
        .target(name: "UControlKit"),
        // 「命令行与技能」设置页的三段区块（接口 / 后台服务 / AI 技能），以 uTerm 的 CLISettingsView 为基准。
        // macOS 专用；文案全部由调用方经 `CLISettingsCopy` 传入（包内字符串收不进 app 的 String Catalog）。
        .target(name: "UControlKitUI", dependencies: ["UControlKit", "UDesignKit"]),
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
        // ---- SSH 栈的两个上游（源码来自上游 tag + ThirdParty/<名字>/patches/）----
        // Sources/NIOSSH、Sources/Citadel、Sources/CCitadelBcrypt 由
        // `Tools/ssh-stack/sync.sh apply` 生成，**别直接改**：改动写成补丁放进
        // ThirdParty/，`sync.sh check` 会核对两者一致。来源、补丁清单与升级步骤见
        // ThirdParty/README.md。模块名保持上游原名，所以同一个构建图里不能再出现
        // 上游的 Citadel / swift-nio-ssh 包（模块会重名）。
        //
        // Wellz26/swift-nio-ssh 0.3.6（Citadel 依赖的 fork，带 cert-auth）。设置照抄
        // 上游 manifest：5.10 工具版本即 Swift 5 语言模式，加上它的三个 upcoming feature。
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        // orlandos-nl/Citadel 0.12.1。bcrypt_pbkdf 的 C 实现（OpenBSD）。
        .target(name: "CCitadelBcrypt"),
        .target(
            name: "Citadel",
            dependencies: [
                "CCitadelBcrypt",
                "NIOSSH",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 同上：原先也是 5.10。
        .target(
            name: "USSHKit",
            dependencies: [
                "Citadel",
                // bcrypt_pbkdf。解密带口令的 OpenSSH 私钥容器要用，整个 SSH 栈里
                // 只有这个 C target 有实现。
                "CCitadelBcrypt",
                "NIOSSH",
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
        .testTarget(name: "UControlKitUITests", dependencies: ["UControlKitUI", "UControlKit"]),
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
