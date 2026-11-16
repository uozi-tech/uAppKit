// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation
import UControlKit

/// 「命令行与技能」三段设置的全部文案，由 app 传入。
///
/// 包内的字符串收不进 app 的 String Catalog，所以这里一个默认值都不给：每个 app 按自己的产品语言填
/// （含 app 名、ctl 名、能力描述），要本地化就在 app 里 `String(localized:)` 好再传进来。
public struct CLISettingsCopy: Sendable {
    // MARK: 命令行接口

    public struct Interface: Sendable {
        public var title: String
        /// 卡片下方的脚注；nil 不显示。
        public var footer: String?
        public var enableLabel: String
        public var enableHint: String
        public var mutationsLabel: String
        public var mutationsHint: String
        /// 「接口地址」行的标签。
        public var socketLabel: String
        public var copyButton: String
        public var copiedButton: String

        public init(
            title: String,
            footer: String?,
            enableLabel: String,
            enableHint: String,
            mutationsLabel: String,
            mutationsHint: String,
            socketLabel: String,
            copyButton: String,
            copiedButton: String
        ) {
            self.title = title
            self.footer = footer
            self.enableLabel = enableLabel
            self.enableHint = enableHint
            self.mutationsLabel = mutationsLabel
            self.mutationsHint = mutationsHint
            self.socketLabel = socketLabel
            self.copyButton = copyButton
            self.copiedButton = copiedButton
        }
    }

    // MARK: 后台服务

    public struct Background: Sendable {
        public var title: String
        public var footer: String?
        public var launchAtLoginLabel: String
        public var launchAtLoginHint: String
        public var onDemandLabel: String
        public var onDemandHint: String
        /// 登录项等待系统批准时的提示。
        public var approvalPending: String
        /// 登录项未注册 / 系统没识别时的提示。
        public var notRegistered: String

        public init(
            title: String,
            footer: String?,
            launchAtLoginLabel: String,
            launchAtLoginHint: String,
            onDemandLabel: String,
            onDemandHint: String,
            approvalPending: String,
            notRegistered: String
        ) {
            self.title = title
            self.footer = footer
            self.launchAtLoginLabel = launchAtLoginLabel
            self.launchAtLoginHint = launchAtLoginHint
            self.onDemandLabel = onDemandLabel
            self.onDemandHint = onDemandHint
            self.approvalPending = approvalPending
            self.notRegistered = notRegistered
        }
    }

    // MARK: AI 技能

    /// 按安装状态分的四段文案（徽标 / 行说明）。
    public struct StatusTexts: Sendable {
        public var notInstalled: String
        public var installed: String
        public var brokenLink: String
        public var conflict: String

        public init(notInstalled: String, installed: String, brokenLink: String, conflict: String) {
            self.notInstalled = notInstalled
            self.installed = installed
            self.brokenLink = brokenLink
            self.conflict = conflict
        }

        public func text(for status: SkillInstallStatus) -> String {
            switch status {
            case .notInstalled: return notInstalled
            case .installed: return installed
            case .brokenLink: return brokenLink
            case .conflict: return conflict
            }
        }
    }

    public struct Skills: Sendable {
        public var title: String
        public var footer: String?
        /// 首次检测还没结束。
        public var detecting: String
        /// 一个 AI 工具的配置目录都没找到。
        public var noTools: String
        public var installButton: String
        public var uninstallButton: String
        /// 行右侧的状态徽标（已安装时不显示）。
        public var statusLabels: StatusTexts
        /// 行副标题（冲突时改显示冲突原因）。
        public var statusHints: StatusTexts

        public init(
            title: String,
            footer: String?,
            detecting: String,
            noTools: String,
            installButton: String,
            uninstallButton: String,
            statusLabels: StatusTexts,
            statusHints: StatusTexts
        ) {
            self.title = title
            self.footer = footer
            self.detecting = detecting
            self.noTools = noTools
            self.installButton = installButton
            self.uninstallButton = uninstallButton
            self.statusLabels = statusLabels
            self.statusHints = statusHints
        }
    }

    /// `~/.local/bin/<ctl>` 开关行（app 提供 `ClientLinkInstaller` 时才显示）。
    public struct ClientLink: Sendable {
        public var label: String
        /// 说明的主体；后面按状态接 `installedNote` / `brokenNote` / `（冲突原因）`。
        public var hint: String
        public var installedNote: String
        public var brokenNote: String

        public init(label: String, hint: String, installedNote: String, brokenNote: String) {
            self.label = label
            self.hint = hint
            self.installedNote = installedNote
            self.brokenNote = brokenNote
        }

        /// 行说明 = 主体 + 状态后缀。
        public func hint(for status: SkillInstallStatus) -> String {
            switch status {
            case .installed: return hint + installedNote
            case .brokenLink: return hint + brokenNote
            case .conflict(let reason): return hint + "（\(reason)）"
            case .notInstalled: return hint
            }
        }
    }

    public var interface: Interface
    public var background: Background
    public var skills: Skills
    /// nil = 不显示 `~/.local/bin` 开关行（即便传了绑定）。
    public var clientLink: ClientLink?

    public init(interface: Interface, background: Background, skills: Skills, clientLink: ClientLink? = nil) {
        self.interface = interface
        self.background = background
        self.skills = skills
        self.clientLink = clientLink
    }
}

#endif
