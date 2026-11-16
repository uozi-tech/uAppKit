// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Darwin
import Foundation
import os

/// 这个 app 是不是装好的那一份：在 /Applications 或 ~/Applications（含子文件夹）里。
///
/// 开发构建（DerivedData、worktree 里编出来的）与正式版同 bundle id、同沙盒容器、同钥匙串。它们启动时如果照样
/// 把技能与客户端的链接改指向自己，客户端的按需启动就会拉起这个开发构建，顶掉正在用的正式版（uTerm 2026-11-08
/// 实际出过：一个 worktree 的 Debug 构建经 utermctl 按需拉起后以本机身份注册中继，把已安装的 uTerm 挤掉）。
/// 判断看 App 所在的位置，不看构建配置：装进 /Applications 的 Apple Development 签名测试版也算装好的那一份。
public enum AppInstallLocation {
    public static func isInstalled(bundleURL: URL, home: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications", home.appending(path: "Applications").standardizedFileURL.path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// 当前进程是不是装好的那一份。沙盒里 `homeDirectoryForCurrentUser` 指向容器，这里用真实家目录。
    public static let isCurrentInstalled = isInstalled(
        bundleURL: Bundle.main.bundleURL, home: SkillTarget.realHomeDirectoryURL)
}

/// 启动期把技能链接（与可选的 `~/.local/bin/<ctl>`）对齐到当前 app 包。
public enum SkillReconciler {
    public enum LogLevel: Sendable {
        case info
        case warning
    }

    /// 日志出口。包不认识各 app 的日志设施，由调用方注入；默认写 `os.Logger`。
    public typealias Log = @Sendable (LogLevel, String) -> Void

    /// 写 `os.Logger(subsystem:category:)` 的日志出口。
    public static func osLog(subsystem: String, category: String = "skills") -> Log {
        let logger = Logger(subsystem: subsystem, category: category)
        return { level, message in
            switch level {
            case .info: logger.info("\(message, privacy: .public)")
            case .warning: logger.error("\(message, privacy: .public)")
            }
        }
    }

    /// 默认日志出口：subsystem 取当前 bundle id。
    public static var defaultLog: Log {
        osLog(subsystem: Bundle.main.bundleIdentifier ?? "UControlKit")
    }

    /// 启动时跑一次（后台）：全部工具的技能链接、以及开关开着的 `~/.local/bin/<ctl>`
    /// 对齐到当前 app 包，然后清掉旧版本物化出的技能副本。
    ///
    /// 这是老用户的升级路径：旧版本的链接指向沙盒容器 / Application Support，macOS 27 上别的进程读不到。
    /// 升级后第一次启动就自动改指，不用打开设置页、也不用重装。
    ///
    /// **开发构建不动链接**（`isInstalledBuild` 为 false，默认按 `AppInstallLocation` 判）：改指向它之后，
    /// 客户端的按需启动会拉起这个开发构建。调试命令行请用 `<APP>_CONTROL_SOCKET` 指过去。
    ///
    /// **测试宿主里不要调**：否则跑一次测试就会把开发机上真实的 `~/.claude/skills` 改指到 DerivedData
    /// 里的测试构建。这条由调用方守（通常与 `ControlService.isRunningInTestHost` 一起判）。
    ///
    /// - Returns: 后台任务；开发构建直接返回 nil。调用方一般忽略它，测试可以 `await` 它。
    @discardableResult
    public static func onLaunch(
        catalog: SkillCatalog,
        isInstalledBuild: Bool = AppInstallLocation.isCurrentInstalled,
        clientLink: ClientLinkInstaller? = nil,
        clientLinkEnabled: Bool = false,
        log: @escaping Log = SkillReconciler.defaultLog
    ) -> Task<Void, Never>? {
        guard isInstalledBuild else {
            log(.info, "开发构建不对齐技能与命令行客户端的链接")
            return nil
        }
        let installers = catalog.installers()
        return Task.detached(priority: .utility) {
            reconcileAll(
                installers: installers,
                clientLink: clientLinkEnabled ? clientLink : nil,
                log: log
            )
        }
    }

    /// `onLaunch` 的同步本体：可注入安装器（临时 home + 假 app 包）。
    ///
    /// - Parameter clientLink: 只在开关开着时传；nil 表示不动 `~/.local/bin`。
    public static func reconcileAll(
        installers: [SkillInstaller],
        clientLink: ClientLinkInstaller?,
        log: Log
    ) {
        let targets = installers.first?.catalog.targets ?? SkillTarget.allCases
        for target in targets {
            do {
                try SkillInstaller.reconcile(installers, target: target)
            } catch {
                log(.warning, "启动期对齐 \(target.displayName) 的技能链接失败：\(error.localizedDescription)")
            }
        }
        if let clientLink, clientLink.status().canInstall {
            do {
                try clientLink.install()
            } catch {
                log(.warning,
                    "启动期对齐 ~/.local/bin/\(clientLink.executableName) 失败：\(error.localizedDescription)")
            }
        }
        if let failure = SkillInstaller.removeLegacySourceIfUnused(installers: installers) {
            log(.warning, failure)
        }
    }
}

#endif
