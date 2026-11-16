// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation

/// 一份可安装技能的静态定义：只有标识与显示名，**不带内容**。
///
/// **真值源是 app 仓库里的文件**：`skills/<slug>/`（`SKILL.md` 与 `references/*.md`）与
/// `scripts/<ctl>`。构建期的「Copy … CLI and Skills」阶段（模板见 `Tools/xcode/copy-cli-and-skills.sh`）
/// 把它们拷进 `<App>.app/Contents/Resources/Skills/<slug>/`（另带 `bin/<ctl>`），随 app 一起签名、
/// 公证；安装只是在 `~/.<tool>/skills/<slug>` 建一条**直接指向包内**的符号链接（见 `SkillInstaller`）。
public struct SkillDefinition: Sendable, Hashable {
    /// 技能目录名，也是 `SKILL.md` frontmatter 的 `name`。已随 app 发版，不能改。
    public var slug: String
    /// 设置页与错误消息里给人看的名字。
    public var displayName: String

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

/// 一个 app 内置的全部技能，以及安装它们时要用到的 app 身份。
///
/// 这里的字符串都已随各 app 发过版（slug、旧 slug、目录名），核心原样使用、不做归一化。
public struct SkillCatalog: Sendable, Hashable {
    /// 给人看的 app 名，拼进错误消息（「uTable.app 里缺少技能文件……」）。
    public var appName: String
    /// 旧版本物化技能副本时用的目录名：`…/<managedDirectoryName>/Skills/<slug>`。
    /// 认「这条链接是我们建的」时用（见 `SkillInstaller.looksLikeManagedSkillLocation`）。
    /// 两个 app 都是 Application Support 下的目录名（`uTable` / `uTerm`）。
    public var managedDirectoryName: String
    /// app 内置的全部技能；安装界面按工具「整包」装这些技能。必须与仓库 `skills/` 下的目录一一对应。
    public var skills: [SkillDefinition]
    /// 已并入别的技能的旧 slug。我们建过的这些链接在对齐时一并摘掉（新包里已没有它们，
    /// 留着只会悬空），用户自己的同名文件不动。
    public var retiredSlugs: [String]
    /// 旧版本物化出的技能副本根目录（`<Application Support>/<dir>/Skills`）。不再有链接指着它时
    /// 启动期删掉（`SkillInstaller.removeLegacySourceIfUnused`）。nil = 没有旧副本可清。
    public var legacyMaterializedRoot: URL?
    /// 支持安装的 AI 工具，设置页按这个顺序列。
    public var targets: [SkillTarget]
    /// 安装时要不要沙盒 entitlement 的 home-relative 例外（沙盒构建为 true）。不影响安装逻辑，
    /// 只给 app 的测试用：为 true 时 entitlements 里必须有 `homeRelativeEntitlementPaths`。
    public var requiresHomeRelativeEntitlement: Bool

    public init(
        appName: String,
        managedDirectoryName: String,
        skills: [SkillDefinition],
        retiredSlugs: [String] = [],
        legacyMaterializedRoot: URL? = nil,
        targets: [SkillTarget] = SkillTarget.allCases,
        requiresHomeRelativeEntitlement: Bool = true
    ) {
        self.appName = appName
        self.managedDirectoryName = managedDirectoryName
        self.skills = skills
        self.retiredSlugs = retiredSlugs
        self.legacyMaterializedRoot = legacyMaterializedRoot
        self.targets = targets
        self.requiresHomeRelativeEntitlement = requiresHomeRelativeEntitlement
    }

    /// 全部技能的 slug，按 catalog 顺序。
    public var slugs: [String] { skills.map(\.slug) }

    /// 沙盒 entitlements 的 `temporary-exception.files.home-relative-path.read-write` 至少要有的项：
    /// 每个工具一条 `/.<tool>/`。装 `~/.local/bin/<ctl>` 链接（`ClientLinkInstaller`）还要另加 `/.local/bin/`。
    public var homeRelativeEntitlementPaths: [String] {
        targets.map { "/\($0.dotDirectoryName)/" }
    }

    /// 每个技能一个安装器。`home` 与 `bundleURL` 可注入便于测试；生产用真实家目录与 `Bundle.main`。
    public func installers(
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> [SkillInstaller] {
        skills.map {
            SkillInstaller(definition: $0, catalog: self, homeDirectoryURL: homeDirectoryURL, bundleURL: bundleURL)
        }
    }
}

#endif
