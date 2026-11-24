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
    // 包内文案的源语言。每个带面向用户文案的 target 有自己的 `Localizable.xcstrings`，
    // 代码里一律按 `bundle: .module` 查（SwiftUI 不带 bundle 时去 App 的 Bundle.main 找，查不到）。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "UDesignKit", targets: ["UDesignKit"]),
        .library(name: "UAppKitBridge", targets: ["UAppKitBridge"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        // SSH-STACK-WIP: 重写期间 USSHKit 暂时停编（它还依赖 Citadel），接到 USSHCore 上之后恢复。
        // .library(name: "USSHKit", targets: ["USSHKit"]),
        .library(name: "USSHCore", targets: ["USSHCore"]),
        .library(name: "USSHTestServer", targets: ["USSHTestServer"]),
        .library(name: "UPaneTree", targets: ["UPaneTree"]),
        .library(name: "UPaneGroups", targets: ["UPaneGroups"]),
        .library(name: "UControlKit", targets: ["UControlKit"]),
        .library(name: "AgentProviders", targets: ["AgentProviders"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "AgentRuntimeUI", targets: ["AgentRuntimeUI"]),
        .library(name: "UControlKitUI", targets: ["UControlKitUI"]),
        // SSH-STACK-WIP: Citadel 停编，重写完成后连同 Sources/Citadel 一起删掉。
        // .library(name: "Citadel", targets: ["Citadel"]),
    ],
    dependencies: [
        // 依赖一律写 https：上游包之间互相引用都是 https，同一个包写成两种地址（https 与 SSH 形式）
        // 会让 Xcode 解析时卡住；没配 SSH key 的人和 CI 也只拉得动 https。
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // 下面两个只有包内的 Citadel / NIOSSH 用。
        .package(url: "https://github.com/attaswift/BigInt.git", "5.2.0"..<"7.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(name: "UDesignKit", resources: [.process("Localizable.xcstrings")]),
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
        .target(name: "UPaneGroups", dependencies: ["UPaneTree", "UDesignKit", "UAppKitBridge"],
                resources: [.process("Localizable.xcstrings")]),
        // 本机 IPC 的外部 agent 通道核心：Unix socket 服务端、请求分发与门禁、开关设置；
        // 以及 AI 技能安装（链到 app 包内）与后台模式（登录项、CLI 按需启动、窗口恢复）。
        // 以前 uTerm / uTable 各有一份同源实现（出自 uService 的 `ServiceControlServer`），
        // 这里以 uTerm 版为基准泛型化。macOS 专用，源码整体用 `#if os(macOS)` 包住，
        // 理由同 UAppKitBridge。Swift 6 语言模式；包内没有默认 MainActor 隔离，
        // 每个类型都显式标注了隔离。
        .target(name: "UControlKit", resources: [.process("Localizable.xcstrings")]),
        // 「命令行与技能」设置页的三段区块（接口 / 后台服务 / AI 技能），以 uTerm 的 CLISettingsView 为基准。
        // macOS 专用；文案全部由调用方经 `CLISettingsCopy` 传入（包内字符串收不进 app 的 String Catalog）。
        .target(name: "UControlKitUI", dependencies: ["UControlKit", "UDesignKit"]),
        // 原先是 swift-tools-version 5.10，即 Swift 5 语言模式。这里统一到 6.2
        // 是为了 UDesignKit，不该顺手把 AgentKit 拖进 Swift 6 严格并发——
        // 那是一次独立的迁移，要单独做、单独验。
        .target(name: "AgentKit", resources: [.process("Localizable.xcstrings")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // 三个 app 共享的 AI provider：SwiftData `LLMProvider`（共享 iCloud 容器
        // `iCloud.com.uozi.shared`）、共享钥匙串组里的 API Key、旧数据导入器。
        // Swift 6 语言模式；与 UControlKit 一样没有默认 MainActor 隔离，每个类型显式标注。
        .target(name: "AgentProviders", dependencies: ["AgentKit", "UDesignKit"],
                resources: [.process("Localizable.xcstrings")]),
        // 内置 agent 运行时：工具协议与注册表、审批、agent 循环、会话 codec、slash 命令。
        // 以 uTable 的 `Core/Agent` 为蓝本泛型化。Swift 6，显式隔离。
        .target(name: "AgentRuntime", dependencies: ["AgentKit", "AgentProviders"],
                resources: [.process("Localizable.xcstrings")]),
        // `UDAgentPanel`：把 `AgentRuntimeSession` / `AgentApprovalQueue` 绑到 UDesignKit 的
        // 纯展示 agent 视图上。
        .target(name: "AgentRuntimeUI", dependencies: ["AgentRuntime", "AgentKit", "UDesignKit"],
                resources: [.process("Localizable.xcstrings")]),
        // ---- SSH 栈的两个上游（源码来自上游 tag + ThirdParty/<名字>/patches/）----
        // Sources/NIOSSH、Sources/Citadel、Sources/CCitadelBcrypt 由
        // `Tools/ssh-stack/sync.sh apply` 生成，**别直接改**：改动写成补丁放进
        // ThirdParty/，`sync.sh check` 会核对两者一致。来源、补丁清单与升级步骤见
        // ThirdParty/README.md。模块名保持上游原名，所以同一个构建图里不能再出现
        // 上游的 Citadel / swift-nio-ssh 包（模块会重名）。
        //
        // apple/swift-nio-ssh 0.15.2 + 我们的 5 个补丁（ThirdParty/swift-nio-ssh/PATCHES.md）：
        // 两处 child channel 的 bug，以及「自定义密钥 / 签名」「自定义密钥交换」两个扩展接口
        // （公开 API 见 ThirdParty/swift-nio-ssh/EXTENSION-API.md；算法实现在 USSHCore，不进 NIOSSH）。
        // 依赖与设置照抄上游 manifest（工具版本 6.1，即 Swift 6 语言模式；上游的
        // MemberImportVisibility 没开，它只让编译更严，不影响行为）。
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ]
        ),
        // 我们自己的 SSH 客户端层，直接架在 NIOSSH 上：连接 / 认证 / 通道（exec、PTY、
        // direct-tcpip、远程转发）/ SFTP / NIOSSH 没带的算法。不认识主机密钥库、偏好、
        // 文案这些产品概念（那是 USSHKit 的事），所以没有面向用户的文字、没有资源。
        // Swift 6 语言模式，没有默认 MainActor 隔离。
        .target(
            name: "USSHCore",
            dependencies: [
                "NIOSSH",
                "CCitadelBcrypt",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // 进程内的 SSH 服务端，只给测试用（本包的测试和 app 的测试宿主都用它）：
        // 架在 NIOSSH 的服务端角色上，带脚本化的 exec、回显 PTY、SFTP、TCP 转发。
        .target(
            name: "USSHTestServer",
            dependencies: [
                "USSHCore",
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // orlandos-nl/Citadel 0.12.1。bcrypt_pbkdf 的 C 实现（OpenBSD）。
        .target(name: "CCitadelBcrypt"),
        // SSH-STACK-WIP: Citadel 与 USSHKit 两个 target 暂时停编，见 products 一节的说明。
        // .target(
        //     name: "Citadel",
        //     dependencies: [
        //         "CCitadelBcrypt",
        //         "NIOSSH",
        //         .product(name: "NIO", package: "swift-nio"),
        //         .product(name: "Crypto", package: "swift-crypto"),
        //         .product(name: "_CryptoExtras", package: "swift-crypto"),
        //         .product(name: "BigInt", package: "BigInt"),
        //         .product(name: "Logging", package: "swift-log"),
        //     ],
        //     swiftSettings: [.swiftLanguageMode(.v5)]
        // ),
        // // 同上：原先也是 5.10。
        // .target(
        //     name: "USSHKit",
        //     dependencies: [
        //         "Citadel",
        //         // bcrypt_pbkdf。解密带口令的 OpenSSH 私钥容器要用，整个 SSH 栈里
        //         // 只有这个 C target 有实现。
        //         "CCitadelBcrypt",
        //         "NIOSSH",
        //         .product(name: "NIOCore", package: "swift-nio"),
        //         .product(name: "NIOPosix", package: "swift-nio"),
        //         .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        //         .product(name: "Crypto", package: "swift-crypto"),
        //         .product(name: "_CryptoExtras", package: "swift-crypto"),
        //         .product(name: "SwiftASN1", package: "swift-asn1"),
        //         .product(name: "Logging", package: "swift-log"),
        //     ],
        //     resources: [.process("Localizable.xcstrings")],
        //     swiftSettings: [.swiftLanguageMode(.v5)],
        //     linkerSettings: [
        //         .linkedFramework("Security"),
        //     ]
        // ),
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
        // SSH-STACK-WIP: 同上。
        // .testTarget(
        //     name: "USSHKitTests",
        //     dependencies: [
        //         "USSHKit",
        //         .product(name: "NIOCore", package: "swift-nio"),
        //         .product(name: "NIOEmbedded", package: "swift-nio"),
        //     ],
        //     swiftSettings: [.swiftLanguageMode(.v5)]
        // ),
        // apple/swift-nio-ssh 自己的测试，和 Sources/NIOSSH 一起由 sync.sh 生成（别直接改），
        // 我们补丁带的回归测试也写在这里。升级上游后先跑它：`swift test --filter NIOSSHTests`。
        // 依赖照抄上游 manifest。
        .testTarget(
            name: "NIOSSHTests",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "USSHCoreTests",
            dependencies: [
                "USSHCore",
                "USSHTestServer",
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
    ]
)
