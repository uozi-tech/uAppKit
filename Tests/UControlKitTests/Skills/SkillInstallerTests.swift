#if os(macOS)

import Darwin
import Foundation
import XCTest
@testable import UControlKit

/// 安装器全部在**临时 home + 假 app 包**下跑 —— 绝不碰真实的 `~/.claude` 等目录。
///
/// 用例以 uTable 的 catalog 为样本（原先是 uTable 的 `SkillInstallerTests`，随实现迁进包里），
/// `~/.local/bin` 链接部分来自 uTerm 的 `BinLinkInstaller` 用例。
final class SkillInstallerTests: XCTestCase {
    /// uTable 发版时的 catalog：slug、旧 slug、目录名都是已发版的值。
    static let uTableSkill = SkillDefinition(slug: "utable", displayName: "uTable 数据库")

    private var catalog: SkillCatalog {
        SkillCatalog(
            appName: "uTable",
            managedDirectoryName: "uTable",
            skills: [Self.uTableSkill],
            retiredSlugs: ["utable-query", "utable-write", "utable-redis"],
            legacyMaterializedRoot: legacyRoot
        )
    }
    private var root: URL!
    private var home: URL!
    /// 假的 app 包：`<root>/Applications/uTable.app`，按构建阶段的产物摆好
    /// `Contents/Resources/Skills/<slug>/SKILL.md` 与 `Skills/utable/bin/utablectl`。
    /// 路径形状必须**真的像个 app 包** —— `looksLikeManagedSkillLocation` 认的就是这几段。
    private var appBundle: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "utable-skill-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        appBundle = try makeAppBundle(at: root.appending(path: "Applications/uTable.app"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func makeAppBundle(at bundle: URL, withSkills: Bool = true) throws -> URL {
        let resources = bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        guard withSkills else { return bundle.standardizedFileURL }
        for definition in catalog.skills {
            let directory = SkillInstaller.skillsDirectoryURL(inBundle: bundle)
                .appending(path: definition.slug, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(definition.slug)\n---\n\(bundle.path)\n"
                .write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let clients = [
            SkillInstaller.skillsDirectoryURL(inBundle: bundle).appending(path: "utable/bin/utablectl"),
            resources.appending(path: "utablectl"),
        ]
        for client in clients {
            try FileManager.default.createDirectory(
                at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho utablectl\n".write(to: client, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: client.path)
        }
        return bundle.standardizedFileURL
    }

    private func installer(
        _ definition: SkillDefinition = SkillInstallerTests.uTableSkill,
        bundle: URL? = nil
    ) -> SkillInstaller {
        SkillInstaller(definition: definition, catalog: catalog, homeDirectoryURL: home, bundleURL: bundle ?? appBundle)
    }

    private func installers(bundle: URL? = nil) -> [SkillInstaller] {
        catalog.installers(homeDirectoryURL: home, bundleURL: bundle ?? appBundle)
    }

    private func clientLink(bundle: URL? = nil) -> ClientLinkInstaller {
        ClientLinkInstaller(catalog: catalog, executableName: "utablectl", legacyClientSlug: "utable-query",
                            homeDirectoryURL: home, bundleURL: bundle ?? appBundle)
    }

    private func linkDestination(of url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// 只建 `<home>/.<tool>` —— `isToolPresent` 认的就是这一层，`skills/` 由安装器自己建。
    private func makeToolDirectory(_ target: SkillTarget) throws {
        try FileManager.default.createDirectory(
            at: target.configDirectoryURL(homeDirectoryURL: home),
            withIntermediateDirectories: true
        )
    }

    /// 需要**手工**在 skills 目录里摆东西的用例（模拟用户自己的文件）用这个，
    /// 否则父目录不存在，摆放本身就先失败了。
    private func makeSkillsDirectory(_ target: SkillTarget) throws {
        try FileManager.default.createDirectory(
            at: target.skillsDirectoryURL(homeDirectoryURL: home),
            withIntermediateDirectories: true
        )
    }

    /// 旧版本物化出的技能副本根目录（Release 在沙盒容器里）。
    private var legacyRoot: URL {
        root.appending(
            path: "Containers/com.uozi.uTable/Data/Library/Application Support/uTable/Skills",
            directoryHint: .isDirectory
        ).standardizedFileURL
    }

    /// 模拟旧版本装下的链接：`~/.<tool>/skills/<slug>` → Application Support 里的旧副本。
    private func linkToLegacyCopy(_ installer: SkillInstaller, target: SkillTarget) throws {
        let copy = legacyRoot.appending(path: installer.definition.slug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try "旧副本".write(to: copy.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try makeSkillsDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: target), withDestinationURL: copy)
    }

    // MARK: - 技能目录

    func testToolPresenceFollowsConfigDirectory() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.claude))
        try makeToolDirectory(.claude)
        XCTAssertTrue(installer.isToolPresent(.claude))
        XCTAssertFalse(installer.isToolPresent(.codex))
    }

    func testCodeBuddyTargetUsesItsOwnSkillsDirectory() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.codebuddy))
        try makeToolDirectory(.codebuddy)
        XCTAssertTrue(installer.isToolPresent(.codebuddy))

        try installer.install(target: .codebuddy)

        let link = installer.targetLinkURL(for: .codebuddy)
        XCTAssertEqual(
            link.path,
            home.appending(path: ".codebuddy/skills/utable").standardizedFileURL.path
        )
        XCTAssertEqual(installer.status(for: .codebuddy), .installed)
        XCTAssertEqual(try linkDestination(of: link), installer.sourceDirectoryURL.path)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled, "只装进 CodeBuddy，不波及别的工具")
    }

    func testAntigravityTargetDetectsAppDirAndInstallsIntoConfigSkills() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.antigravity))
        // 仅有 ~/.gemini（如只装了 Gemini CLI）不算装了 Antigravity。
        try FileManager.default.createDirectory(
            at: home.appending(path: ".gemini", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        XCTAssertFalse(installer.isToolPresent(.antigravity))

        try makeToolDirectory(.antigravity)
        XCTAssertTrue(installer.isToolPresent(.antigravity))

        try installer.install(target: .antigravity)

        let link = installer.targetLinkURL(for: .antigravity)
        XCTAssertEqual(
            link.path,
            home.appending(path: ".gemini/config/skills/utable").standardizedFileURL.path
        )
        XCTAssertEqual(installer.status(for: .antigravity), .installed)
        XCTAssertEqual(try linkDestination(of: link), installer.sourceDirectoryURL.path)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled, "只装进 Antigravity，不波及别的工具")
    }

    // MARK: - 直接链到 app 包内

    /// 整个方案的核心：链接**直接**指向包内技能目录，不经过任何 app 写出的副本。
    func testInstallLinksStraightIntoTheAppBundle() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        let link = installer.targetLinkURL(for: .claude)
        XCTAssertEqual(
            try linkDestination(of: link),
            appBundle.appending(path: "Contents/Resources/Skills/utable").path
        )
        XCTAssertEqual(
            try String(contentsOf: link.appending(path: "SKILL.md"), encoding: .utf8),
            try String(contentsOf: installer.sourceDirectoryURL.appending(path: "SKILL.md"), encoding: .utf8)
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.appending(path: "bin/utablectl").path))
    }

    func testInstallIsIdempotent() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)
        XCTAssertNoThrow(try installer.install(target: .claude))
        XCTAssertEqual(installer.status(for: .claude), .installed)
    }

    /// 包里没有技能（构建阶段坏了）：拒绝安装，既有链接不动。
    func testBundleWithoutSkillsIsRefusedAndLeavesLinksAlone() throws {
        try makeToolDirectory(.claude)
        try installer().install(target: .claude)
        let bare = try makeAppBundle(at: root.appending(path: "Broken/uTable.app"), withSkills: false)
        let broken = installer(bundle: bare)

        XCTAssertNotNil(broken.unavailableReason)
        XCTAssertThrowsError(try broken.install(target: .claude))
        XCTAssertNoThrow(try SkillInstaller.reconcile(installers(bundle: bare), target: .claude))

        XCTAssertEqual(
            try linkDestination(of: broken.targetLinkURL(for: .claude)),
            installer().sourceDirectoryURL.path,
            "原来能用的链接不能被改指到一个没有技能的包"
        )
    }

    /// 从「下载」里直接运行（App Translocation）或磁盘映像里运行：路径马上会消失，
    /// 拒绝装、也不自动对齐，免得把能用的链接改指过去。
    func testTranslocatedAppIsRefusedAndLeavesLinksAlone() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let translocated = try makeAppBundle(
            at: root.appending(path: "AppTranslocation/0A1B2C/d/uTable.app"))

        XCTAssertNotNil(installer(bundle: translocated).unavailableReason)
        XCTAssertThrowsError(try installer(bundle: translocated).install(target: .claude))
        XCTAssertNoThrow(try SkillInstaller.reconcile(installers(bundle: translocated), target: .claude))

        for one in installers() {
            XCTAssertEqual(one.status(for: .claude), .installed, "\(one.definition.slug) 被改指到临时位置了")
        }
    }

    // MARK: - 旧链接自动对齐

    /// 旧版本的链接指向 Application Support 里的副本：认得出是 uTable 建的（不是冲突）。
    func testLegacyLinkIsRecognisedAsOurs() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .brokenLink)
        XCTAssertTrue(installer.status(for: .claude).canInstall)
        XCTAssertTrue(installer.status(for: .claude).canUninstall)
    }

    func testInstallRepointsLegacyLinkWithoutTouchingTheOldCopy() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        XCTAssertEqual(
            try linkDestination(of: installer.targetLinkURL(for: .claude)),
            installer.sourceDirectoryURL.path
        )
        XCTAssertEqual(
            try String(contentsOf: legacyRoot.appending(path: "utable/SKILL.md"), encoding: .utf8),
            "旧副本"
        )
    }

    /// 升级路径：一个工具下只要有 uTable 的旧链接，就整包改指到包内，并补上缺的技能。
    func testReconcileRepointsLegacyLinksAndAddsMissingSkills() throws {
        try makeToolDirectory(.codex)
        let all = installers()
        try linkToLegacyCopy(all[0], target: .codex)

        try SkillInstaller.reconcile(all, target: .codex)

        XCTAssertEqual(SkillManagerModel.aggregateStatus(installers: all, target: .codex), .installed)
        for one in all {
            XCTAssertEqual(
                try linkDestination(of: one.targetLinkURL(for: .codex)), one.sourceDirectoryURL.path)
        }
    }

    /// app 搬了家：旧路径悬空，由新位置的 uTable 自动接过来。
    func testReconcileFollowsTheAppToItsNewLocation() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let moved = try makeAppBundle(at: root.appending(path: "Moved/uTable.app"))
        try FileManager.default.removeItem(at: appBundle)
        XCTAssertEqual(installer(bundle: moved).status(for: .claude), .brokenLink)

        try SkillInstaller.reconcile(installers(bundle: moved), target: .claude)

        for one in installers(bundle: moved) {
            XCTAssertEqual(one.status(for: .claude), .installed)
        }
    }

    /// 另一份 uTable 还在（Debug / Release 并存、两份拷贝）：正在运行的那份说了算，
    /// 只改链接，不碰另一份的包。
    func testRunningAppTakesOverLinksToAnotherCopy() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let other = try makeAppBundle(at: root.appending(path: "Other/uTable.app"))

        try SkillInstaller.reconcile(installers(bundle: other), target: .claude)

        for one in installers(bundle: other) {
            XCTAssertEqual(one.status(for: .claude), .installed)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer().sourceDirectoryURL.appending(path: "SKILL.md").path))
    }

    /// 没装过（或用户卸载了）的工具不动，也不凭空建 `skills/` 目录。
    func testReconcileLeavesToolsWithoutUTableLinksAlone() throws {
        try makeToolDirectory(.claude)

        try SkillInstaller.reconcile(installers(), target: .claude)
        try SkillInstaller.reconcile(installers(), target: .codex)   // 工具目录都不存在

        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers(), target: .claude), .notInstalled)
        XCTAssertNil(SkillInstaller.fileType(at: SkillTarget.claude.skillsDirectoryURL(homeDirectoryURL: home)))
        XCTAssertNil(SkillInstaller.fileType(at: SkillTarget.codex.configDirectoryURL(homeDirectoryURL: home)))
    }

    /// 新技能的位置被用户自己的目录占着：那一处不动、报错，旧技能的链接照样摘掉
    /// （新包里已没有它们，留着也只会悬空）。
    func testReconcileReportsAConflictButStillRetiresOldLinks() throws {
        try makeToolDirectory(.claude)
        try linkRetired("utable-query", target: .claude, into: appBundle)
        let userDirectory = installer().targetLinkURL(for: .claude)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let marker = userDirectory.appending(path: "user.md")
        try "别动我".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SkillInstaller.reconcile(installers(), target: .claude))

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "别动我")
        XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL("utable-query", target: .claude)))
    }

    // MARK: - 三份旧技能并入 utable

    /// 旧技能的位置：`~/.<tool>/skills/<旧 slug>`。
    private func retiredLinkURL(_ slug: String, target: SkillTarget) -> URL {
        target.skillsDirectoryURL(homeDirectoryURL: home).appending(path: slug)
    }

    /// 模拟旧版本装下的旧技能链接：指向 `root`（某个 app 包，或旧副本根）下的 `Skills/<slug>`。
    /// 新包里没有这些目录，链接是悬空的 —— 正是用户升级后的样子。
    private func linkRetired(_ slug: String, target: SkillTarget, into root: URL) throws {
        let skills = root.pathExtension == "app" ? SkillInstaller.skillsDirectoryURL(inBundle: root) : root
        try makeSkillsDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: retiredLinkURL(slug, target: target),
            withDestinationURL: skills.appending(path: slug, directoryHint: .isDirectory))
    }

    /// 升级路径：只装过三份旧技能的工具，对齐后换成一份 `utable`，旧链接全部摘掉。
    func testReconcileReplacesRetiredSkillsWithTheMergedOne() throws {
        try makeToolDirectory(.claude)
        for slug in catalog.retiredSlugs {
            try linkRetired(slug, target: .claude, into: appBundle)
        }

        try SkillInstaller.reconcile(installers(), target: .claude)

        XCTAssertEqual(installer().status(for: .claude), .installed)
        for slug in catalog.retiredSlugs {
            XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL(slug, target: .claude)), "\(slug) 没摘掉")
        }
    }

    /// 已经装好 `utable`、又残留旧链接（比如被别的 uTable 副本补回来）：也照样摘。
    func testReconcileRetiresOldLinksEvenWhenTheMergedSkillIsInstalled() throws {
        try makeToolDirectory(.claude)
        try installer().install(target: .claude)
        try linkRetired("utable-redis", target: .claude, into: appBundle)

        try SkillInstaller.reconcile(installers(), target: .claude)

        XCTAssertEqual(installer().status(for: .claude), .installed)
        XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL("utable-redis", target: .claude)))
    }

    /// 旧技能名下是用户自己的东西（真实目录、指向别处的链接）：不认、不动；
    /// 只有这些时也不算「装过 uTable」，不凭空装上新技能。
    func testUserOwnedThingsUnderRetiredNamesAreLeftAlone() throws {
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let userDirectory = retiredLinkURL("utable-write", target: .claude)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let elsewhere = root.appending(path: "somewhere-else", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: retiredLinkURL("utable-redis", target: .claude), withDestinationURL: elsewhere)

        try SkillInstaller.reconcile(installers(), target: .claude)

        XCTAssertEqual(installer().status(for: .claude), .notInstalled)
        XCTAssertEqual(SkillInstaller.fileType(at: userDirectory), S_IFDIR)
        XCTAssertEqual(SkillInstaller.fileType(at: retiredLinkURL("utable-redis", target: .claude)), S_IFLNK)

        try linkRetired("utable-query", target: .claude, into: appBundle)
        try SkillInstaller.reconcile(installers(), target: .claude)

        XCTAssertEqual(installer().status(for: .claude), .installed)
        XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL("utable-query", target: .claude)))
        XCTAssertEqual(SkillInstaller.fileType(at: userDirectory), S_IFDIR)
        XCTAssertEqual(SkillInstaller.fileType(at: retiredLinkURL("utable-redis", target: .claude)), S_IFLNK)
    }

    /// 旧技能链接还指着旧副本时，旧副本留着；摘掉后才删。
    func testLegacyCopyIsKeptWhileARetiredLinkPointsAtIt() throws {
        try makeToolDirectory(.claude)
        try FileManager.default.createDirectory(
            at: legacyRoot.appending(path: "utable-query", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try linkRetired("utable-query", target: .claude, into: legacyRoot)

        SkillInstaller.removeLegacySourceIfUnused(installers: installers(), legacyRoot: legacyRoot)
        XCTAssertNotNil(SkillInstaller.fileType(at: legacyRoot), "还有旧技能链接指着，不能删")

        try SkillInstaller.reconcile(installers(), target: .claude)
        SkillInstaller.removeLegacySourceIfUnused(installers: installers(), legacyRoot: legacyRoot)

        XCTAssertNil(SkillInstaller.fileType(at: legacyRoot))
        XCTAssertEqual(installer().status(for: .claude), .installed)
    }

    /// 设置页的装/卸按钮也顺手摘旧链接。
    @MainActor
    func testModelInstallAndUninstallRetireOldLinks() async throws {
        try makeToolDirectory(.claude)
        try linkRetired("utable-write", target: .claude, into: appBundle)
        let model = SkillManagerModel(installers: installers())

        await model.install(.claude)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(installer().status(for: .claude), .installed)
        XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL("utable-write", target: .claude)))

        try linkRetired("utable-redis", target: .claude, into: appBundle)
        await model.uninstall(.claude)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(installer().status(for: .claude), .notInstalled)
        XCTAssertNil(SkillInstaller.fileType(at: retiredLinkURL("utable-redis", target: .claude)))
    }

    /// 打开设置页即自动对齐，用户不需要点任何按钮。
    @MainActor
    func testModelLoadReconcilesAutomatically() async throws {
        try makeToolDirectory(.claude)
        let all = installers()
        for one in all { try linkToLegacyCopy(one, target: .claude) }

        let model = SkillManagerModel(installers: all)
        await model.load()

        XCTAssertEqual(model.status(for: .claude), .installed)
        XCTAssertNil(model.lastError)
    }

    /// 让 `load` 算完快照后停在写回之前：返回「已停下」的信号与「放行」的开关。
    @MainActor
    private func pauseLoadBeforeApplying(_ model: SkillManagerModel)
        -> (reached: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let (reached, didReach) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        model.beforeApplyingLoad = {
            didReach.yield()
            for await _ in gate { return }
        }
        return (reached, release)
    }

    /// 设置页刚出现、`load` 还在后台算的时候用户点了「安装」：`load` 那份更早的快照不能把
    /// 安装写下的状态盖回「未安装」。
    @MainActor
    func testModelLoadDoesNotOverwriteAnInstallThatFinishedMeanwhile() async throws {
        try makeToolDirectory(.claude)
        let model = SkillManagerModel(installers: installers())
        let (reached, release) = pauseLoadBeforeApplying(model)

        let loading = Task { @MainActor in await model.load() }
        for await _ in reached { break }                 // 快照已算好，里面是「未安装」
        await model.install(.claude)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.status(for: .claude), .installed)

        release.yield()
        release.finish()
        await loading.value
        XCTAssertTrue(model.didLoad)
        XCTAssertEqual(model.availableTargets, [.claude])
        XCTAssertEqual(model.status(for: .claude), .installed, "过时的快照不写回")
    }

    /// 后开始的 `load` 让先开始、晚结束的那次作废。
    @MainActor
    func testOlderLoadFinishingLateIsDiscarded() async throws {
        let model = SkillManagerModel(installers: installers())
        let (reached, release) = pauseLoadBeforeApplying(model)
        let stale = Task { @MainActor in await model.load() }   // 此时一个工具都没有
        for await _ in reached { break }

        try makeToolDirectory(.claude)
        model.beforeApplyingLoad = nil
        await model.load()
        XCTAssertEqual(model.availableTargets, [.claude])

        release.yield()
        release.finish()
        await stale.value
        XCTAssertEqual(model.availableTargets, [.claude], "旧的那次不能把新结果盖回去")
    }

    // MARK: - 旧副本清理

    /// 还有链接指着旧副本就留着；全部改指后删掉。
    func testLegacyCopyIsRemovedOnlyOnceNothingPointsAtIt() throws {
        try makeToolDirectory(.claude)
        let all = installers()
        for one in all { try linkToLegacyCopy(one, target: .claude) }

        SkillInstaller.removeLegacySourceIfUnused(installers: all, legacyRoot: legacyRoot)
        XCTAssertNotNil(SkillInstaller.fileType(at: legacyRoot), "还有链接指着，不能删")

        try SkillInstaller.reconcile(all, target: .claude)
        SkillInstaller.removeLegacySourceIfUnused(installers: all, legacyRoot: legacyRoot)

        XCTAssertNil(SkillInstaller.fileType(at: legacyRoot))
        XCTAssertEqual(SkillManagerModel.aggregateStatus(installers: all, target: .claude), .installed)
    }

    // MARK: - 冲突与卸载

    func testForeignDirectoryIsAConflictAndIsNeverOverwritten() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let link = installer.targetLinkURL(for: .claude)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let marker = link.appending(path: "user.md")
        try "别动我".write(to: marker, atomically: true, encoding: .utf8)

        guard case .conflict = installer.status(for: .claude) else {
            return XCTFail("用户自己的目录应判为冲突")
        }
        XCTAssertThrowsError(try installer.install(target: .claude))
        XCTAssertThrowsError(try installer.uninstall(target: .claude))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "别动我")
    }

    func testSymlinkPointingElsewhereIsAConflict() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let other = root.appending(path: "somewhere-else", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: .claude),
            withDestinationURL: other
        )
        guard case .conflict = installer.status(for: .claude) else {
            return XCTFail("指向别处的链接应判为冲突")
        }
    }

    func testUninstallRemovesOnlyTheLink() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)

        try installer.uninstall(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .notInstalled)
        // 包里的技能绝不能动。
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.sourceDirectoryURL.appending(path: "SKILL.md").path))
        XCTAssertNoThrow(try installer.uninstall(target: .claude))
    }

    func testUninstallAlsoRemovesALegacyLink() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        try installer.uninstall(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.appending(path: "utable").path))
    }

    func testAggregateStatusAcrossCatalog() throws {
        let installers = installers()
        try makeToolDirectory(.claude)
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .notInstalled
        )

        for one in installers { try one.install(target: .claude) }
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .installed
        )
    }

    /// 不传 `legacyRoot` 时用 catalog 里登记的旧副本位置。
    func testLegacyCopyDefaultsToTheCatalogRoot() throws {
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        XCTAssertNil(SkillInstaller.removeLegacySourceIfUnused(installers: installers()))
        XCTAssertNil(SkillInstaller.fileType(at: legacyRoot))
    }

    // MARK: - 参数化

    /// 「是不是我们建的」按 catalog 的目录名认，别家 app 的旧副本不算。
    func testManagedLocationUsesTheCatalogDirectoryName() {
        let slug = "utable"
        XCTAssertTrue(SkillInstaller.looksLikeManagedSkillLocation(
            URL(fileURLWithPath: "/x/Application Support/uTable/Skills/utable"), slug: slug,
            managedDirectoryName: "uTable"))
        XCTAssertFalse(SkillInstaller.looksLikeManagedSkillLocation(
            URL(fileURLWithPath: "/x/Application Support/uTerm/Skills/utable"), slug: slug,
            managedDirectoryName: "uTable"))
        XCTAssertTrue(SkillInstaller.looksLikeManagedSkillLocation(
            URL(fileURLWithPath: "/Applications/Any.app/Contents/Resources/Skills/utable"), slug: slug,
            managedDirectoryName: "uTable"))
    }

    /// 错误消息里的 app 名来自 catalog。
    func testMessagesUseTheCatalogAppName() throws {
        let bare = try makeAppBundle(at: root.appending(path: "Broken/uTable.app"), withSkills: false)
        let reason = try XCTUnwrap(installer(bundle: bare).unavailableReason)
        XCTAssertTrue(reason.contains("uTable.app"), reason)
        let transient = try XCTUnwrap(SkillInstaller.transientBundleReason(
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/uTable.app"), appName: "uTable"))
        XCTAssertTrue(transient.contains("uTable.app"), transient)
    }

    func testEntitlementPathsCoverEveryTarget() {
        XCTAssertEqual(
            catalog.homeRelativeEntitlementPaths,
            ["/.claude/", "/.codex/", "/.cursor/", "/.codebuddy/", "/.gemini/"]
        )
        XCTAssertEqual(ClientLinkInstaller.homeRelativeEntitlementPath, "/.local/bin/")
    }

    /// 设置页只列 catalog 声明的工具。
    @MainActor
    func testModelOnlyListsCatalogTargets() async throws {
        try makeToolDirectory(.claude)
        try makeToolDirectory(.codex)
        var narrowed = catalog
        narrowed.targets = [.codex]
        let model = SkillManagerModel(installers: narrowed.installers(homeDirectoryURL: home, bundleURL: appBundle))
        await model.load()
        XCTAssertEqual(model.availableTargets, [.codex])
    }

    // MARK: - 为什么可执行文件不能由 app 写出

    /// 沙盒 app 写出的每一个文件都被打上 `com.apple.quarantine`，带着这条属性的脚本直接 exec 必然
    /// `operation not permitted`，而沙盒进程**无权解除自己的隔离**：`removexattr` 回 `EPERM`，
    /// `setResourceValue(nil, forKey: .quarantinePropertiesKey)`（Apple 文档的正路）报成功但属性纹丝不动。
    /// 这是技能文件必须放在 app 包里、而不是由 app 写出的原因之一，逐条量在这里。
    /// （`swift test` 的宿主不开沙盒，这条会跳过；在沙盒 app 宿主里才真正跑。）
    func testAppWrittenFileIsQuarantinedAndCannotBeExecuted() throws {
        let attribute = "com.apple.quarantine"
        let script = root.appending(path: "written-by-app")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: script.path)
        let hasQuarantine = { getxattr(script.path, attribute, nil, 0, 0, 0) >= 0 }

        try XCTSkipUnless(hasQuarantine(), "宿主没开沙盒（写出的文件不带 quarantine），这条不适用")

        XCTAssertEqual(removexattr(script.path, attribute, 0), -1)
        XCTAssertEqual(errno, EPERM)

        try (script as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
        XCTAssertTrue(hasQuarantine(), "setResourceValue(nil) 只是报成功")

        let process = Process()
        process.executableURL = script
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        XCTAssertThrowsError(try process.run()) { error in
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }
    }

    // MARK: - ~/.local/bin/<ctl>

    func testClientLinkPointsStraightAtTheBundledClient() throws {
        let link = clientLink()
        XCTAssertEqual(link.status(), .notInstalled)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(link.sourceURL.path, appBundle.appending(path: "Contents/Resources/utablectl").path)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.linkURL.path))
        XCTAssertEqual(link.linkURL.path, home.appending(path: ".local/bin/utablectl").standardizedFileURL.path)
    }

    /// 旧版本建的链接指向物化出的客户端（Application Support / 容器里）。它是我们建的，只是指着旧位置 ——
    /// 判需修复（不是冲突），重装即指向包内脚本。
    func testLegacyClientLinkIsRepairableNotAConflict() throws {
        let link = clientLink()
        let legacyClient = legacyRoot.appending(path: "utable-query/bin/utablectl")
        try FileManager.default.createDirectory(
            at: legacyClient.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "旧客户端".write(to: legacyClient, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: legacyClient)

        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
    }

    /// 没声明旧客户端形态时，指向旧副本的链接就是别人的东西。
    func testLegacyClientLinkIsAConflictWithoutALegacySlug() throws {
        let link = ClientLinkInstaller(executableName: "utablectl", appName: "uTable", managedDirectoryName: "uTable",
                                       homeDirectoryURL: home, bundleURL: appBundle)
        let legacyClient = legacyRoot.appending(path: "utable-query/bin/utablectl")
        try FileManager.default.createDirectory(
            at: legacyClient.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "旧客户端".write(to: legacyClient, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: legacyClient)

        guard case .conflict = link.status() else { return XCTFail("应判为冲突") }
    }

    /// app 搬家后链接悬空：判需修复，重装即指回新位置。
    func testClientLinkToAMovedAppIsRepairable() throws {
        try clientLink().install()
        let moved = try makeAppBundle(at: root.appending(path: "Moved/uTable.app"))
        try FileManager.default.removeItem(at: appBundle)
        let link = clientLink(bundle: moved)

        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
    }

    /// 装 bin 链接不需要先装任何技能，也不会往 `~/.<tool>/skills` 里写东西。
    func testClientLinkDoesNotTouchToolDirectories() throws {
        try makeToolDirectory(.claude)
        try clientLink().install()
        XCTAssertEqual(installer().status(for: .claude), .notInstalled)
    }

    func testClientLinkIsIdempotentAndUninstallable() throws {
        let link = clientLink()
        try link.install()
        XCTAssertNoThrow(try link.install())

        try link.uninstall()
        XCTAssertEqual(link.status(), .notInstalled)
        XCTAssertNoThrow(try link.uninstall())
        // 只删链接，绝不动 app 包里的脚本。
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.sourceURL.path))
    }

    /// 整个 app 包没了：判需修复；装不上（没有可以链的东西）要报错，而不是链到空处。
    func testClientLinkReportsBrokenWhenTheBundleDisappears() throws {
        let link = clientLink()
        try link.install()
        try FileManager.default.removeItem(at: appBundle)

        XCTAssertEqual(link.status(), .brokenLink)
        XCTAssertThrowsError(try link.install())
    }

    func testClientLinkNeverOverwritesARealFile() throws {
        let link = clientLink()
        try FileManager.default.createDirectory(at: link.binDirectoryURL, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 用户自己的".write(to: link.linkURL, atomically: true, encoding: .utf8)

        guard case .conflict = link.status() else {
            return XCTFail("同名真实文件应判为冲突")
        }
        XCTAssertThrowsError(try link.install())
        XCTAssertThrowsError(try link.uninstall())
        XCTAssertEqual(try String(contentsOf: link.linkURL, encoding: .utf8), "#!/bin/sh\necho 用户自己的")
    }

    func testClientLinkPointingElsewhereIsAConflict() throws {
        let link = clientLink()
        let elsewhere = root.appending(path: "some-tool")
        try "x".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: elsewhere)

        guard case .conflict = link.status() else {
            return XCTFail("指向别处的链接应判为冲突")
        }
    }

    @MainActor
    func testModelTogglesClientLink() async throws {
        let model = SkillManagerModel(installers: installers(), clientLink: clientLink())
        await model.load()
        XCTAssertEqual(model.clientLinkStatus, .notInstalled)

        await model.setClientLinkEnabled(true)
        XCTAssertEqual(model.clientLinkStatus, .installed)
        XCTAssertNil(model.lastError)

        await model.setClientLinkEnabled(false)
        XCTAssertEqual(model.clientLinkStatus, .notInstalled)
    }

    /// 开关记在 UserDefaults 里，链接被外部删掉后打开设置页应自动补回来。
    @MainActor
    func testModelReconcilesClientLinkOnLoad() async throws {
        let link = clientLink()
        let model = SkillManagerModel(installers: installers(), clientLink: link)
        try link.install()
        try FileManager.default.removeItem(at: link.linkURL)

        await model.reconcileClientLink(enabled: true)
        XCTAssertEqual(model.clientLinkStatus, .installed)
    }

    /// 开关关着时，`reconcile` 不该悄悄建链接。
    @MainActor
    func testModelDoesNotCreateClientLinkWhenDisabled() async throws {
        let link = clientLink()
        let model = SkillManagerModel(installers: installers(), clientLink: link)
        await model.reconcileClientLink(enabled: false)
        XCTAssertEqual(model.clientLinkStatus, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.linkURL.path))
    }

    /// 不提供客户端链接的 app：开关相关调用都是空操作。
    @MainActor
    func testModelWithoutClientLinkIgnoresTheSwitch() async throws {
        let model = SkillManagerModel(installers: installers())
        await model.setClientLinkEnabled(true)
        await model.reconcileClientLink(enabled: true)
        XCTAssertEqual(model.clientLinkStatus, .notInstalled)
        XCTAssertNil(model.lastError)
        XCTAssertNil(SkillInstaller.fileType(at: home.appending(path: ".local")))
    }

    // MARK: - 启动期对齐

    /// 升级路径一把跑完：技能改指、开关开着的客户端链接补上、旧副本删掉。
    func testReconcileAllRepointsSkillsLinksClientAndRemovesLegacyCopy() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try linkToLegacyCopy(one, target: .claude) }
        let messages = LogRecorder()

        SkillReconciler.reconcileAll(installers: installers(), clientLink: clientLink(), log: messages.log)

        XCTAssertEqual(installer().status(for: .claude), .installed)
        XCTAssertEqual(clientLink().status(), .installed)
        XCTAssertNil(SkillInstaller.fileType(at: legacyRoot))
        XCTAssertEqual(messages.lines, [])
    }

    /// 开关关着（传 nil）时不动 `~/.local/bin`；冲突写日志、不抛。
    func testReconcileAllLogsConflictsAndLeavesClientLinkAlone() throws {
        try makeToolDirectory(.claude)
        try linkRetired("utable-query", target: .claude, into: appBundle)
        try FileManager.default.createDirectory(
            at: installer().targetLinkURL(for: .claude), withIntermediateDirectories: true)
        let messages = LogRecorder()

        SkillReconciler.reconcileAll(installers: installers(), clientLink: nil, log: messages.log)

        XCTAssertNil(SkillInstaller.fileType(at: home.appending(path: ".local")))
        XCTAssertEqual(messages.lines.count, 1)
        XCTAssertTrue(messages.lines.first?.contains("Claude") == true, "\(messages.lines)")
    }

    /// 开发构建（不在 /Applications 里）不动任何链接。
    func testOnLaunchSkipsDevelopmentBuilds() throws {
        let messages = LogRecorder()
        let task = SkillReconciler.onLaunch(catalog: catalog, isInstalledBuild: false, log: messages.log)
        XCTAssertNil(task)
        XCTAssertEqual(messages.lines.count, 1)
    }
}

/// 收集 `SkillReconciler` 的日志。
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    var log: SkillReconciler.Log {
        { [self] _, message in lock.withLock { storage.append(message) } }
    }
}

/// 只有装好的那一份 app（/Applications 或 ~/Applications 里）才对齐技能链接。
/// 回归 uTerm 2026-11-08：worktree 的 Debug 构建被客户端按需拉起后顶掉了已安装的那一份。
final class AppInstallLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func installed(_ path: String) -> Bool {
        AppInstallLocation.isInstalled(bundleURL: URL(fileURLWithPath: path, isDirectory: true), home: home)
    }

    func testApplicationsFoldersCountAsInstalled() {
        XCTAssertTrue(installed("/Applications/uTerm.app"))
        XCTAssertTrue(installed("/Applications/Utilities/uTerm.app"), "子文件夹也算")
        XCTAssertTrue(installed("/Users/someone/Applications/uTerm.app"))
    }

    func testBuildProductsAndLookalikePathsDoNot() {
        XCTAssertFalse(installed("/Users/someone/Workspace/uTerm/.claude/worktrees/x/build/DerivedData/Build/Products/Debug/uTerm.app"))
        XCTAssertFalse(installed("/Users/someone/Library/Developer/Xcode/DerivedData/uTerm-abc/Build/Products/Release/uTerm.app"))
        XCTAssertFalse(installed("/Applications.backup/uTerm.app"), "只认那两个文件夹本身")
        XCTAssertFalse(installed("/Volumes/uTerm/uTerm.app"), "直接从 DMG 里打开")
        XCTAssertFalse(installed("/Users/other/Applications/uTerm.app"), "别人的家目录")
    }
}

#endif
