// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Darwin
import Foundation

/// 把 app 包内的命令行客户端再往 `~/.local/bin/<ctl>` 链一条，让它进用户的 PATH。
///
/// 通常默认关（设置页开关）。技能自带的 `~/.<tool>/skills/<slug>/bin/<ctl>` 才是主路径 —— 装了技能
/// 就一定能跑，不依赖用户的 shell 环境；这条链接只是给「在自己终端里也想直接敲 `<ctl>`」的人省一步。
///
/// 链接目标是 `<App>.app/Contents/Resources/<ctl>`（构建阶段要带 `--resources-copy` 把客户端拷到这里，
/// 见 `Tools/xcode/copy-cli-and-skills.sh`），与技能目录里那份同源，app 升级时两边同时更新。app 搬家后
/// 由 `SkillReconciler.onLaunch` 自动改指。
///
/// 冲突规则与 `SkillInstaller` 一致：只认自己建的符号链接，同名真实文件（比如用户自己编译的同名工具）
/// 判 `conflict` 且绝不覆盖。
///
/// 沙盒下要能写到这里，entitlements 必须有 `temporary-exception.files.home-relative-path.read-write`
/// 的 `/.local/bin/`（见 `homeRelativeEntitlementPath`）。
///
/// （由 uTerm 的 `BinLinkInstaller` 泛化而来。）
public struct ClientLinkInstaller: Sendable {
    /// 客户端文件名，如 `utermctl`。
    public let executableName: String
    /// 给人看的 app 名，拼进错误消息。
    public let appName: String
    /// 旧版本物化技能副本的目录名（同 `SkillCatalog.managedDirectoryName`）。
    public let managedDirectoryName: String
    /// 旧版本物化出的客户端所在的技能名：`…/<managedDirectoryName>/Skills/<slug>/bin/<ctl>`。
    /// 指向那里的旧链接判「需修复」而不是冲突。nil = 没有这种旧形态。
    public let legacyClientSlug: String?
    public let homeDirectoryURL: URL
    public let bundleURL: URL

    /// entitlements 里要有的 home-relative 例外。
    public static let homeRelativeEntitlementPath = "/.local/bin/"

    public init(
        executableName: String,
        appName: String,
        managedDirectoryName: String,
        legacyClientSlug: String? = nil,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.executableName = executableName
        self.appName = appName
        self.managedDirectoryName = managedDirectoryName
        self.legacyClientSlug = legacyClientSlug
        self.homeDirectoryURL = homeDirectoryURL
        self.bundleURL = bundleURL.standardizedFileURL
    }

    /// 与技能 catalog 同一个 app：app 名与目录名取自 catalog。
    public init(
        catalog: SkillCatalog,
        executableName: String,
        legacyClientSlug: String? = nil,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.init(
            executableName: executableName,
            appName: catalog.appName,
            managedDirectoryName: catalog.managedDirectoryName,
            legacyClientSlug: legacyClientSlug,
            homeDirectoryURL: homeDirectoryURL,
            bundleURL: bundleURL
        )
    }

    /// `<bundle>/Contents/Resources/<ctl>`。
    public var sourceURL: URL {
        bundleURL
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
            .appending(path: executableName)
            .standardizedFileURL
    }

    /// `<home>/.local/bin`。
    public var binDirectoryURL: URL {
        homeDirectoryURL
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// `<home>/.local/bin/<ctl>`。
    public var linkURL: URL {
        binDirectoryURL.appending(path: executableName)
    }

    public func status() -> SkillInstallStatus {
        let name = executableName
        guard let type = SkillInstaller.fileType(at: linkURL) else {
            return .notInstalled
        }
        guard type == S_IFLNK else {
            return .conflict(reason: type == S_IFDIR
                ? String(localized: "~/.local/bin/\(name) 是一个目录", bundle: .module)
                : String(localized: "~/.local/bin/\(name) 已被别的文件占用（非 \(appName) 创建）", bundle: .module))
        }
        guard let resolved = SkillInstaller.linkDestination(of: linkURL) else {
            return .conflict(reason: String(localized: "无法读取符号链接目标", bundle: .module))
        }
        if resolved.path == sourceURL.path {
            return SkillInstaller.fileType(at: sourceURL) == nil ? .brokenLink : .installed
        }
        // 我们自己建的、只是指向旧位置：app 搬家 / 另一份拷贝的包内脚本，或旧版本物化出的客户端。
        if SkillInstaller.looksLikeBundledClient(resolved, executableName: name)
            || looksLikeLegacyMaterializedClient(resolved) {
            return .brokenLink
        }
        return .conflict(reason: String(localized: "符号链接指向其它位置：\(resolved.path)", bundle: .module))
    }

    private func looksLikeLegacyMaterializedClient(_ url: URL) -> Bool {
        guard let legacyClientSlug else { return false }
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 5,
              parts[parts.count - 1] == executableName,
              parts[parts.count - 2] == "bin"
        else { return false }
        let skillRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        return SkillInstaller.looksLikeManagedSkillLocation(
            skillRoot, slug: legacyClientSlug, managedDirectoryName: managedDirectoryName)
    }

    /// 建 `~/.local/bin` → 建（或改指）链接。真冲突抛错，绝不覆盖用户的文件。
    public func install() throws {
        if let reason = SkillInstaller.transientBundleReason(bundleURL, appName: appName) {
            throw SkillInstallError.failed(reason)
        }
        guard SkillInstaller.fileType(at: sourceURL) != nil else {
            throw SkillInstallError.failed(String(localized: "\(appName).app 里缺少 \(executableName)，重新安装 \(appName) 即可。", bundle: .module))
        }
        switch status() {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed(reason)
        case .brokenLink:
            // 已确认是我们建的**符号链接**，删掉重建即可 —— 删的是链接本身。
            do {
                try FileManager.default.removeItem(at: linkURL)
            } catch {
                throw SkillInstallError.failed(
                    String(localized: "无法替换既有的 ~/.local/bin/\(executableName)（\(error.localizedDescription)）", bundle: .module)
                )
            }
        case .notInstalled:
            break
        }
        do {
            try FileManager.default.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
        } catch {
            throw SkillInstallError.failed(String(localized: "无法写入 \(linkURL.path)（\(error.localizedDescription)）", bundle: .module))
        }
    }

    /// 只删「确认由我们建的」符号链接。
    public func uninstall() throws {
        switch status() {
        case .installed, .brokenLink:
            try FileManager.default.removeItem(at: linkURL)
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed(String(localized: "未删除（\(reason)）", bundle: .module))
        }
    }
}

#endif
