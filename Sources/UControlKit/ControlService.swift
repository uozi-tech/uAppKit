// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import AppKit
import Foundation

/// 能被 `ControlService` 起停的东西。`ControlSocketServer` 实现它；测试可以塞桩。
public protocol ControlServing: AnyObject, Sendable {
    /// 返回 nil 表示已开始监听（或本来就在跑）；非 nil 是不会自愈的启动失败原因。
    @discardableResult func start() -> String?
    func stop()
}

/// 把开关和服务端连起来：主开关开 → 起服务端（失败原因写进 `startupError`）；关 → 停服务端、
/// unlink socket、清 `startupError`、调 `onDisabled`。app 正常退出时也停一次，免得路径上留一个
/// 没人监听的残留文件（客户端连上去只会拿到 ECONNREFUSED，看起来像「在跑但坏了」）。
@MainActor
public final class ControlService {
    public let settings: ControlGateSettings
    public let server: any ControlServing
    /// 主开关关掉时调（服务端已经停了）。uTerm 用它松开命令行自己持有的 SSH 连接。
    public var onDisabled: (@MainActor () -> Void)?
    private let skipsServer: Bool
    private var terminationObserver: (any NSObjectProtocol)?

    /// - Parameter skipsInTestHost: 在 XCTest 宿主里不起服务端。测试宿主**就是这个 app**，
    ///   照常读到开关就会去抢开发者正在用的那个实例的 socket；测试自己会在临时路径上起独立实例。
    public init(
        settings: ControlGateSettings,
        server: any ControlServing,
        skipsInTestHost: Bool = true,
        onDisabled: (@MainActor () -> Void)? = nil
    ) {
        self.settings = settings
        self.server = server
        self.skipsServer = skipsInTestHost && Self.isRunningInTestHost
        self.onDisabled = onDisabled
    }

    /// 接线：观察开关（立刻按当前状态起停一次），并在 app 退出时停服务端。只调一次。
    public func activate() {
        settings.observe { [weak self] settings in
            self?.apply(settings)
        }
        // 测试宿主里服务端从没起过，退出时也不能 stop：`stop()` 会 unlink socket 路径，而 Debug
        // 测试宿主与开发者正开着的那个实例用的是同一条路径，等于把别人的 socket 摘掉。
        guard terminationObserver == nil, !skipsServer else { return }
        let server = server
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            server.stop()
        }
    }

    private func apply(_ settings: ControlGateSettings) {
        if settings.isEnabled {
            guard !skipsServer else { return }
            settings.startupError = server.start()
        } else {
            if !skipsServer { server.stop() }
            settings.startupError = nil
            onDisabled?()
        }
    }

    /// 当前进程是不是 XCTest 宿主。前三个环境变量是 `xcodebuild test` 注入 app 宿主时设的；
    /// `swift test` 不设它们，但进程里已经载入了 XCTest，按类名兜底（正常运行的 app 不会载入 XCTest）。
    public nonisolated static var isRunningInTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

#endif
