// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Darwin
import Foundation

public enum SkillInstallError: Error, LocalizedError, Sendable {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// `~/.<tool>/skills/<slug>`（或 `~/.local/bin/<ctl>`）的安装状态。
public enum SkillInstallStatus: Sendable, Equatable {
    /// 目标位置不存在。
    case notInstalled
    /// 符号链接指向**当前 app 包**里的技能，且包内文件在。
    case installed
    /// 我们建的链接，但没指向当前 app 包：旧版本指向沙盒容器 / Application Support 里的物化副本、
    /// app 搬了家、链到了同一个 app 的另一份拷贝。启动与打开设置页时自动改指
    /// （`SkillInstaller.reconcile`），用户不用动手。
    case brokenLink
    /// 目标已被占用：普通文件 / 真实目录，或符号链接指向与本 app 无关的位置。
    case conflict(reason: String)

    public var canInstall: Bool {
        switch self {
        case .notInstalled, .brokenLink: return true
        case .installed, .conflict: return false
        }
    }

    /// 确认由我们建的链接都可卸载。
    public var canUninstall: Bool {
        switch self {
        case .installed, .brokenLink: return true
        case .notInstalled, .conflict: return false
        }
    }

    public var conflictReason: String? {
        if case .conflict(let reason) = self { return reason }
        return nil
    }
}

/// 纯 Foundation 的技能安装器：在 `~/.<tool>/skills/<slug>` 建**直接指向 app 包内**
/// `Contents/Resources/Skills/<slug>` 的符号链接。
///
/// 为什么链到包内、而不是链到 app 自己写出的一份：
/// - **沙盒容器对别家开发者的进程不可读**。macOS 27 起访问别家的 app 数据容器默认拒绝、
///   不再弹窗；没给完全磁盘访问权限的 AI CLI 顺着链接读容器里的 `SKILL.md` 直接 `EPERM`
///   （实测：同一个无授权进程读容器文件 `EPERM`，读 app 包内文件、列包内目录都行）。
/// - **沙盒 app 写出的文件必带 `com.apple.quarantine`**，可执行文件直接 exec 必 `EPERM`，
///   而且沙盒进程摘不掉。包内文件随 app 签名、公证，没有这个问题。
/// - Sparkle 原地替换 app，技能内容自动跟着升级，不需要任何物化 / 自检。
///
/// 代价是链接绑死 app 路径，所以有 `reconcile`：启动时把我们建过的链接整包改指到
/// 当前 app 包（**正在运行的那份 app 说了算**）。
///
/// 错误消息里的 app 名来自 `SkillCatalog.appName`；冲突原因等文案目前是中文，直接显示在设置页。
public struct SkillInstaller: Sendable {
    public let definition: SkillDefinition
    public let catalog: SkillCatalog
    public let homeDirectoryURL: URL
    /// 技能所在的 app 包（`…/<App>.app`）。
    public let bundleURL: URL

    public init(
        definition: SkillDefinition,
        catalog: SkillCatalog,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.definition = definition
        self.catalog = catalog
        self.homeDirectoryURL = homeDirectoryURL
        self.bundleURL = bundleURL.standardizedFileURL
    }

    /// 链接目标：`<bundle>/Contents/Resources/Skills/<slug>`。
    public var sourceDirectoryURL: URL {
        Self.skillsDirectoryURL(inBundle: bundleURL)
            .appending(path: definition.slug, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func skillsDirectoryURL(inBundle bundleURL: URL) -> URL {
        bundleURL
            .appending(path: "Contents/Resources/Skills", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public func targetLinkURL(for target: SkillTarget) -> URL {
        target.skillsDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appending(path: definition.slug)
    }

    /// 用户是否在用该工具：以其 CLI 配置目录 `<home>/.<tool>` 是否存在为判据。
    /// 跟随符号链接（软链到真实目录也算）。这是技能可安装的判据，与桌面 app 无关。
    public func isToolPresent(_ target: SkillTarget) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: target.configDirectoryURL(homeDirectoryURL: homeDirectoryURL).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// 当前 app 包装不了技能的原因；nil 表示可以装。
    public var unavailableReason: String? {
        if let reason = Self.transientBundleReason(bundleURL, appName: catalog.appName) { return reason }
        guard Self.fileType(at: sourceDirectoryURL.appending(path: "SKILL.md")) == S_IFREG else {
            let appName = catalog.appName
            let slug = definition.slug
            return String(localized: "\(appName).app 里缺少技能文件（\(slug)），重新安装 \(appName) 即可。", bundle: ModuleBundle.bundle)
        }
        return nil
    }

    /// app 跑在**会消失的位置**时拒绝建链接，否则链上去很快就悬空：
    /// - App Translocation：从「下载」里直接双击、没拖进「应用程序」时，系统把 app 挂到
    ///   一个随机的只读路径上运行；
    /// - 磁盘映像里直接运行（只读卷，推出即没）。
    /// 两者都是只读卷，`/AppTranslocation/` 再兜一道。
    public static func transientBundleReason(_ bundleURL: URL, appName: String) -> String? {
        guard isTransientBundle(bundleURL) else { return nil }
        return String(localized: "\(appName) 正从临时位置运行（磁盘映像，或下载后没拖进「应用程序」），先把 \(appName).app 移到「应用程序」文件夹再安装。", bundle: ModuleBundle.bundle)
    }

    /// 只读卷，或路径里带 `/AppTranslocation/`。
    public static func isTransientBundle(_ bundleURL: URL) -> Bool {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly == true
        return readOnly || bundleURL.path.contains("/AppTranslocation/")
    }

    public func status(for target: SkillTarget) -> SkillInstallStatus {
        let link = targetLinkURL(for: target)
        guard let type = Self.fileType(at: link) else {
            return .notInstalled
        }
        guard type == S_IFLNK else {
            return .conflict(reason: type == S_IFDIR
                ? String(localized: "已存在同名目录（非 \(catalog.appName) 创建）", bundle: ModuleBundle.bundle)
                : String(localized: "已存在同名文件（非 \(catalog.appName) 创建）", bundle: ModuleBundle.bundle))
        }
        guard let resolved = Self.linkDestination(of: link) else {
            return .conflict(reason: String(localized: "无法读取符号链接目标", bundle: ModuleBundle.bundle))
        }
        // 故意按字面路径比较、不做 resolvingSymlinksInPath：链接是用绝对路径建的，
        // 存的就是这个路径。解析符号链接反而可能在 /var → /private/var 这类前缀上误判。
        if resolved.path == sourceDirectoryURL.path {
            return Self.fileType(at: sourceDirectoryURL) == S_IFDIR ? .installed : .brokenLink
        }
        if Self.looksLikeManagedSkillLocation(
            resolved, slug: definition.slug, managedDirectoryName: catalog.managedDirectoryName) {
            return .brokenLink
        }
        return .conflict(reason: String(localized: "符号链接指向其它位置：\(resolved.path)", bundle: ModuleBundle.bundle))
    }

    /// 建（或改指）链接。真冲突抛错，不覆盖用户文件；app 在临时位置或包内缺技能时
    /// 抛错且**不动**既有链接。
    public func install(target: SkillTarget) throws {
        if let reason = unavailableReason {
            throw SkillInstallError.failed(String(localized: "\(target.displayName)：\(reason)", bundle: ModuleBundle.bundle, comment: "名称：失败原因"))
        }
        let link = targetLinkURL(for: target)
        switch status(for: target) {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed(String(localized: "\(target.displayName)：\(reason)", bundle: ModuleBundle.bundle, comment: "名称：失败原因"))
        case .brokenLink:
            // 只删这条已确认是我们建的符号链接，不碰它指向的东西。
            do {
                try FileManager.default.removeItem(at: link)
            } catch {
                throw SkillInstallError.failed(
                    String(localized: "\(target.displayName)：无法替换旧链接（\(error.localizedDescription)）", bundle: ModuleBundle.bundle)
                )
            }
        case .notInstalled:
            break
        }
        do {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceDirectoryURL)
        } catch {
            throw SkillInstallError.failed(
                String(localized: "\(target.displayName)：无法写入 \(link.path)（\(error.localizedDescription)）", bundle: ModuleBundle.bundle)
            )
        }
    }

    /// 仅删除「确认由我们建的」符号链接；其它情况抛错且不动文件。
    public func uninstall(target: SkillTarget) throws {
        switch status(for: target) {
        case .installed, .brokenLink:
            try FileManager.default.removeItem(at: targetLinkURL(for: target))
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed(String(localized: "\(target.displayName)：未删除（\(reason)）", bundle: ModuleBundle.bundle))
        }
    }

    /// 这个路径是不是我们建过的技能链接会指向的地方：
    /// - 当前形态：`<X>.app/Contents/Resources/Skills/<slug>`（app 搬家、另一份拷贝）；
    /// - 旧形态：`…/<managedDirectoryName>/Skills/<slug>`（旧版本物化在 Application Support，
    ///   沙盒版在容器里）。
    public static func looksLikeManagedSkillLocation(
        _ url: URL, slug: String, managedDirectoryName: String
    ) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[parts.count - 1] == slug, parts[parts.count - 2] == "Skills"
        else { return false }
        if parts[parts.count - 3] == managedDirectoryName { return true }
        return parts.count >= 6
            && parts[parts.count - 3] == "Resources"
            && parts[parts.count - 4] == "Contents"
            && parts[parts.count - 5].hasSuffix(".app")
    }

    /// 这个路径看起来是不是某个 app 副本**包内**的客户端，即末四段为
    /// `<X>.app/Contents/Resources/<name>`。app 换了位置（或另一份拷贝）时，
    /// 旧链接靠这个判成「我们建的、只是指向旧位置」，而不是无关的冲突。
    public static func looksLikeBundledClient(_ url: URL, executableName: String) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 4 else { return false }
        return parts[parts.count - 1] == executableName
            && parts[parts.count - 2] == "Resources"
            && parts[parts.count - 3] == "Contents"
            && parts[parts.count - 4].hasSuffix(".app")
    }

    /// 读符号链接目标并规范成绝对路径（相对目标按链接所在目录解析）。
    public static func linkDestination(of link: URL) -> URL? {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return (destination as NSString).isAbsolutePath
            ? URL(fileURLWithPath: destination).standardizedFileURL
            : link.deletingLastPathComponent().appending(path: destination).standardizedFileURL
    }

    /// `lstat` 的文件类型位（不跟随符号链接）。路径不存在返回 nil。
    public static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// 对每个元素执行操作；保留首个错误并在全部跑完后抛出（整包尽力而为）。
    public static func forEach<T>(_ items: [T], _ operation: (T) throws -> Void) throws {
        var firstError: Error?
        for item in items {
            do { try operation(item) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}

// MARK: - 自动对齐

extension SkillInstaller {
    /// 把一个工具下我们建过的技能链接**整包**对齐到当前 app 包：旧链接改指、catalog
    /// 里新增的技能补上、已并入别处的旧技能（`SkillCatalog.retiredSlugs`）摘掉。
    ///
    /// - 该工具下一条我们的链接都没有（没装过、用户卸载了）→ 不动，尊重用户的选择；
    ///   只有旧技能的链接也算装过 —— 这正是从多份技能升级上来的老用户；
    /// - app 在临时位置（或包内缺技能）→ 不动，免得把能用的链接改指到马上会消失的路径；
    /// - 真冲突的位置不动，其余照样对齐，跑完抛首个错误。
    public static func reconcile(_ installers: [SkillInstaller], target: SkillTarget) throws {
        guard let first = installers.first,
              first.isToolPresent(target),
              first.unavailableReason == nil
        else { return }
        let retired = retiredLinks(
            catalog: first.catalog, homeDirectoryURL: first.homeDirectoryURL, target: target)
        let statuses = installers.map { $0.status(for: target) }
        guard !retired.isEmpty || statuses.contains(where: { $0 == .installed || $0 == .brokenLink })
        else { return }
        let installed = Result { try forEach(installers) { try $0.install(target: target) } }
        try removeRetiredLinks(catalog: first.catalog, homeDirectoryURL: first.homeDirectoryURL, target: target)
        try installed.get()
    }

    /// 该工具下我们建过的旧技能链接（`SkillCatalog.retiredSlugs`）。只认指向技能目录
    /// 形态（包内或旧副本）的符号链接，用户自己的同名文件 / 目录 / 别处的链接不算。
    public static func retiredLinks(
        catalog: SkillCatalog, homeDirectoryURL: URL, target: SkillTarget
    ) -> [URL] {
        let directory = target.skillsDirectoryURL(homeDirectoryURL: homeDirectoryURL)
        return catalog.retiredSlugs.compactMap { slug in
            let link = directory.appending(path: slug)
            guard fileType(at: link) == S_IFLNK,
                  let resolved = linkDestination(of: link),
                  looksLikeManagedSkillLocation(
                      resolved, slug: slug, managedDirectoryName: catalog.managedDirectoryName)
            else { return nil }
            return link
        }
    }

    /// 摘掉 `retiredLinks`。删的是链接本身，不碰它指向的东西。
    public static func removeRetiredLinks(
        catalog: SkillCatalog, homeDirectoryURL: URL, target: SkillTarget
    ) throws {
        let links = retiredLinks(catalog: catalog, homeDirectoryURL: homeDirectoryURL, target: target)
        try forEach(links) { link in
            do {
                try FileManager.default.removeItem(at: link)
            } catch {
                throw SkillInstallError.failed(
                    String(localized: "\(target.displayName)：无法删除旧技能链接 \(link.lastPathComponent)（\(error.localizedDescription)）", bundle: ModuleBundle.bundle)
                )
            }
        }
    }

    /// 旧版本物化出的副本（`SkillCatalog.legacyMaterializedRoot`）：没有任何链接再指向它时删掉
    /// （它在 app 自己的 Application Support / 容器里，删得动）。还有链接指着（比如那个位置冲突、
    /// 没对齐成功）就留着，不把现状弄得更糟。
    ///
    /// - Returns: 删除失败时的错误描述；没东西可删或删成功返回 nil。
    @discardableResult
    public static func removeLegacySourceIfUnused(
        installers: [SkillInstaller],
        legacyRoot explicitRoot: URL? = nil
    ) -> String? {
        guard let first = installers.first,
              let legacyRoot = (explicitRoot ?? first.catalog.legacyMaterializedRoot)?.standardizedFileURL,
              fileType(at: legacyRoot) == S_IFDIR
        else { return nil }
        let prefix = legacyRoot.path.hasSuffix("/") ? legacyRoot.path : legacyRoot.path + "/"
        // 旧技能的链接也可能还指着旧副本（这一处没对齐成功），同样要留着。
        let slugs = installers.map(\.definition.slug) + first.catalog.retiredSlugs
        let home = first.homeDirectoryURL
        for slug in slugs {
            for target in SkillTarget.allCases {
                let link = target.skillsDirectoryURL(homeDirectoryURL: home).appending(path: slug)
                guard fileType(at: link) == S_IFLNK,
                      let resolved = linkDestination(of: link)
                else { continue }
                if resolved.path.hasPrefix(prefix) { return nil }
            }
        }
        do {
            try FileManager.default.removeItem(at: legacyRoot)
            return nil
        } catch {
            return String(localized: "删除旧的技能副本失败：\(error.localizedDescription)", bundle: ModuleBundle.bundle)
        }
    }
}

#endif
