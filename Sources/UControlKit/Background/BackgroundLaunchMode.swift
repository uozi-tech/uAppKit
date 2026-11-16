// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation

/// 进程是怎么被拉起来的：前台（用户打开）还是后台（登录项 / 命令行客户端按需启动）。
///
/// 启动参数是已发版的契约：登录项 launcher 传 `--background --launch-source login-item`，
/// 客户端（`open -gjW … --args --background --launch-source cli`）传 `--launch-source cli`。
public enum BackgroundLaunchMode {
    public enum Presentation: Equatable, Sendable { case background, foreground }

    public static let backgroundArgument = "--background"
    public static let launchSourceArgument = "--launch-source"
    /// 客户端按需唤起时的 `--launch-source` 值。
    public static let cliLaunchSource = "cli"
    /// 登录项唤起时的 `--launch-source` 值。
    public static let loginItemLaunchSource = "login-item"

    public static func presentation(arguments: [String]) -> Presentation {
        arguments.contains(backgroundArgument) ? .background : .foreground
    }

    public static func shouldStartHidden(arguments: [String]) -> Bool {
        presentation(arguments: arguments) == .background
    }

    /// 已在后台运行的实例被再次打开（reopen）时一律露出界面。
    public static let reopenPresentation: Presentation = .foreground

    /// 当前进程是不是以后台方式启动的。
    public static let shouldStartHidden = presentation(arguments: ProcessInfo.processInfo.arguments) == .background

    public static func launchSource(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchSourceArgument),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// `cliLaunchRefusal` 的拒绝原因文案（会写进 app 的日志；客户端看不到，它只看到进程退出）。
    public struct RefusalCopy: Sendable {
        /// 没打开「允许 CLI 按需启动」。
        public var onDemandDisabled: String
        /// 没打开「启用命令行接口」。
        public var controlDisabled: String

        public init(onDemandDisabled: String, controlDisabled: String) {
            self.onDemandDisabled = onDemandDisabled
            self.controlDisabled = controlDisabled
        }
    }

    /// CLI 按需唤起由 app 自己把关，返回拒绝原因；nil 表示放行。在 `@main` 里、`App.main()` 之前调，
    /// 非 nil 就 `exit(0)`。
    ///
    /// 客户端本来会先读设置再决定唤不唤起，但 macOS 27 起没给完全磁盘访问权限的进程读不了
    /// 沙盒容器里的偏好 plist（`EPERM`）。读不到时客户端照样请求启动，由这里按用户设置决定
    /// 去留：「允许 CLI 按需启动」与「启用命令行接口」缺一不可，否则进程立刻退出，客户端靠
    /// `open -W` 看到它退出后报错。非 CLI 来源（手动打开、登录项）一律放行。
    ///
    /// - Parameter controlEnabledKey: 命令行接口主开关的 defaults key（两个 app 都是 `control.enabled`）。
    public static func cliLaunchRefusal(
        arguments: [String],
        defaults: UserDefaults,
        controlEnabledKey: String = "control.enabled",
        copy: RefusalCopy
    ) -> String? {
        guard launchSource(arguments: arguments) == cliLaunchSource else { return nil }
        guard defaults.object(forKey: BackgroundServiceSettings.Keys.allowOnDemandLaunch) as? Bool == true else {
            return copy.onDemandDisabled
        }
        guard defaults.object(forKey: controlEnabledKey) as? Bool == true else {
            return copy.controlDisabled
        }
        return nil
    }
}

#endif
