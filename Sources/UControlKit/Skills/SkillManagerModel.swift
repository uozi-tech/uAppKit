// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation
import Observation

/// 驱动「命令行与技能」设置页的观察式模型。状态住在主线程，文件操作在后台执行。
/// 按工具「整包装」：每个工具下 catalog 的全部技能一起装 / 卸，多技能状态聚合成一个。
@MainActor
@Observable
public final class SkillManagerModel {
    @ObservationIgnored private let installers: [SkillInstaller]
    @ObservationIgnored private let targets: [SkillTarget]
    /// 可选的 `~/.local/bin/<ctl>` 链接；nil 表示这个 app 不提供这条链接。
    @ObservationIgnored public let clientLink: ClientLinkInstaller?
    /// 本机在用的工具（CLI 配置目录存在），即可安装技能的对象。
    public private(set) var availableTargets: [SkillTarget] = []
    public private(set) var statuses: [SkillTarget: SkillInstallStatus] = [:]
    /// 首次 `load()` 是否完成 —— 用于区分「还在检测」与「确实一个都没有」，避免空状态闪烁。
    public private(set) var didLoad = false
    /// 正在执行安装 / 卸载的 target，用于禁用按钮并避免重复点击。
    public private(set) var busyTargets: Set<SkillTarget> = []
    public var lastError: String?
    /// `~/.local/bin/<ctl>` 的当前状态（与技能安装分开：它是独立开关）。
    public private(set) var clientLinkStatus: SkillInstallStatus = .notInstalled
    public private(set) var clientLinkBusy = false

    /// - Parameters:
    ///   - installers: 一般是 `catalog.installers()`；测试注入临时 home 与假 app 包。
    ///   - clientLink: 可选的 `~/.local/bin/<ctl>` 链接。
    public init(installers: [SkillInstaller], clientLink: ClientLinkInstaller? = nil) {
        self.installers = installers
        self.targets = installers.first?.catalog.targets ?? SkillTarget.allCases
        self.clientLink = clientLink
    }

    /// 生产用：真实家目录与 `Bundle.main`。
    public convenience init(catalog: SkillCatalog, clientLink: ClientLinkInstaller? = nil) {
        self.init(installers: catalog.installers(), clientLink: clientLink)
    }

    public func status(for target: SkillTarget) -> SkillInstallStatus {
        statuses[target] ?? .notInstalled
    }

    public func isBusy(_ target: SkillTarget) -> Bool {
        busyTargets.contains(target)
    }

    /// 把一个工具下各技能的状态聚合成一个：任一冲突→冲突；全部一致→就是它；其余→需修复。
    public nonisolated static func aggregateStatus(
        installers: [SkillInstaller], target: SkillTarget
    ) -> SkillInstallStatus {
        let pairs = installers.map { ($0.definition.displayName, $0.status(for: target)) }
        if let conflict = pairs.first(where: { $0.1.conflictReason != nil }) {
            let name = conflict.0
            let reason = conflict.1.conflictReason ?? ""
            return .conflict(reason: String(localized: "\(name)：\(reason)", bundle: .module, comment: "名称：失败原因"))
        }
        if let first = pairs.first, pairs.allSatisfy({ $0.1 == first.1 }) { return first.1 }
        return .brokenLink
    }

    /// 首次加载：后台判定哪些工具在用，把我们建过的链接对齐到当前 app 包，再计算聚合状态。
    ///
    /// 启动时 `SkillReconciler.onLaunch` 已经对齐过一遍；这里再跑一次，是为了
    /// 覆盖「运行期间 app 被挪走 / 外部删了几条链接」这类启动之后才发生的变化。
    public func load() async {
        let installers = self.installers
        let targets = self.targets
        let snapshot = await Task.detached {
            () -> (targets: [SkillTarget], statuses: [SkillTarget: SkillInstallStatus]) in
            var present: [SkillTarget] = []
            var statuses: [SkillTarget: SkillInstallStatus] = [:]
            for target in targets where installers.first?.isToolPresent(target) == true {
                present.append(target)
                try? SkillInstaller.reconcile(installers, target: target)
                statuses[target] = Self.aggregateStatus(installers: installers, target: target)
            }
            return (present, statuses)
        }.value
        availableTargets = snapshot.targets
        statuses = snapshot.statuses
        didLoad = true
        await refreshClientLink()
    }

    // MARK: - ~/.local/bin/<ctl>

    public func refreshClientLink() async {
        guard let clientLink else { return }
        clientLinkStatus = await Task.detached { clientLink.status() }.value
    }

    /// 打开开关就建链接、关掉就删。与技能安装互不影响：不装任何技能也能只要这条链接。
    public func setClientLinkEnabled(_ enabled: Bool) async {
        guard let clientLink, !clientLinkBusy else { return }
        clientLinkBusy = true
        defer { clientLinkBusy = false }
        do {
            try await Task.detached { enabled ? try clientLink.install() : try clientLink.uninstall() }.value
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refreshClientLink()
    }

    /// 开关记在 `UserDefaults` 里，链接却可能被外部删掉（清理脚本、换 home）。
    /// 打开设置页时按开关状态补一次，只在「开着但没链上」时动手。
    public func reconcileClientLink(enabled: Bool) async {
        await refreshClientLink()
        guard clientLink != nil, enabled, clientLinkStatus.canInstall else { return }
        await setClientLinkEnabled(true)
    }

    // MARK: - 技能

    public func install(_ target: SkillTarget) async {
        let installers = self.installers
        await mutate(target) {
            let installed = Result { try SkillInstaller.forEach(installers) { try $0.install(target: target) } }
            try Self.removeRetiredLinks(installers: installers, target: target)
            try installed.get()
        }
    }

    public func uninstall(_ target: SkillTarget) async {
        let installers = self.installers
        await mutate(target) {
            let removed = Result { try SkillInstaller.forEach(installers) { try $0.uninstall(target: target) } }
            try Self.removeRetiredLinks(installers: installers, target: target)
            try removed.get()
        }
    }

    /// 装 / 卸都顺手摘掉已并入别处的旧技能链接，免得新旧两套同时触发或留下悬空链接。
    private nonisolated static func removeRetiredLinks(
        installers: [SkillInstaller], target: SkillTarget
    ) throws {
        guard let first = installers.first else { return }
        try SkillInstaller.removeRetiredLinks(
            catalog: first.catalog, homeDirectoryURL: first.homeDirectoryURL, target: target)
    }

    /// 执行单个 target 的整包安装 / 卸载：同一 target 不并发；只在结束时写 `lastError`
    /// （成功清空、失败置文案），避免新操作抹掉用户尚未看到的旧错误；完成后只重读该 target 聚合状态。
    private func mutate(_ target: SkillTarget, _ work: @escaping @Sendable () throws -> Void) async {
        guard !busyTargets.contains(target) else { return }
        busyTargets.insert(target)
        defer { busyTargets.remove(target) }

        let installers = self.installers
        do {
            try await Task.detached { try work() }.value
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        statuses[target] = await Task.detached {
            Self.aggregateStatus(installers: installers, target: target)
        }.value
    }
}

#endif
