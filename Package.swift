// swift-tools-version: 6.2

import PackageDescription

/// uTable / uTerm 共用的包。原先每个包各自住在其中一个 app 仓库里、由另一个 app
/// 按 `../<兄弟仓库>/Packages/<名字>` 的相对路径引用——本地包不进
/// `Package.resolved`，于是发版产物里到底嵌了哪一版共享代码，任何地方都没有记录。
/// 集中到这里并按 tag 发布之后，两个 app 的 `Package.resolved` 会钉住具体 revision，
/// 历史发版才能复现。
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
    ],
    targets: [
        .target(name: "UDesignKit"),
        // macOS 专用（AppKit 事件桥）。源码整体用 `#if os(macOS)` 包住，
        // 这样即使被拉进 iOS 的构建图也只是空目标，不会编译失败。
        .target(name: "UAppKitBridge"),
        // 原先是 swift-tools-version 5.10，即 Swift 5 语言模式。这里统一到 6.2
        // 是为了 UDesignKit，不该顺手把 AgentKit 拖进 Swift 6 严格并发——
        // 那是一次独立的迁移，要单独做、单独验。
        .target(name: "AgentKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "UAppKitBridgeTests", dependencies: ["UAppKitBridge"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
