// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import AppKit
import SwiftUI
import UControlKit
import UDesignKit

/// 「命令行与技能」设置的三段：命令行接口 / 后台服务 / AI 技能。来自 uTerm 的 `CLISettingsView`。
///
/// 只渲染三个分组（`UDSettingsGroup`，组间距 24），不带滚动容器和页头：uTerm 放进
/// `UDSettingsScroll` + `UDSettingsPageHeader`，uTable 放进自己设置屏的内容列。
///
/// - 接口：本机 IPC 的两个门禁开关（落 `ControlGateSettings`，`ControlService` 观察它起停服务端）
///   与 socket 地址（可拷贝）。
/// - 后台服务：登录后在后台启动、允许 CLI 按需启动（落 `BackgroundServiceSettings`）。
/// - AI 技能：把内置技能装进各 AI CLI 的 `~/.<tool>/skills`（落 `SkillManagerModel`），以及可选的
///   `~/.local/bin/<ctl>` 开关。
///
/// 文案全部来自 `CLISettingsCopy`。出现时刷新登录项状态、加载技能状态；app 回到前台时再刷新登录项
/// （用户可能刚在系统设置里批准 / 关掉了它）。
@available(macOS 15.0, *)
public struct UControlSettingsSections: View {
    private let copy: CLISettingsCopy
    private let control: ControlGateSettings
    private let socketPath: String
    private let background: BackgroundServiceSettings
    private let skills: SkillManagerModel
    private let clientLinkEnabled: Binding<Bool>?

    @State private var copied = false
    /// 「已拷贝」两秒后复原的那次计时；再点一次就换一个新的，旧的作废。
    @State private var copiedReset: Task<Void, Never>?

    /// - Parameters:
    ///   - socketPath: 「接口地址」行显示与拷贝的路径。
    ///   - skills: 由 app 持有（`@State`），这样切走设置页再回来不会再闪一次「检测中」（每次出现仍会在后台重新对齐一遍）。
    ///   - clientLinkEnabled: `~/.local/bin/<ctl>` 开关的持久化值（app 的 `@AppStorage`）。nil，或
    ///     `skills.clientLink` / `copy.clientLink` 为 nil 时不显示这一行。
    public init(
        copy: CLISettingsCopy,
        control: ControlGateSettings,
        socketPath: String,
        background: BackgroundServiceSettings,
        skills: SkillManagerModel,
        clientLinkEnabled: Binding<Bool>? = nil
    ) {
        self.copy = copy
        self.control = control
        self.socketPath = socketPath
        self.background = background
        self.skills = skills
        self.clientLinkEnabled = clientLinkEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UDSettingsMetrics.groupSpacing) {
            interfaceGroup
            backgroundGroup
            skillsGroup
        }
        .task {
            background.refreshLoginItemStatus()
            await skills.load()
            if let clientLinkEnabled, showsClientLink {
                await skills.reconcileClientLink(enabled: clientLinkEnabled.wrappedValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 保留上一次注册失败的说明：用户多半正是切去系统设置处理它，回来时不该看着它消失。
            background.refreshLoginItemStatus(preserveError: true)
        }
    }

    private func copySocketPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(socketPath, forType: .string)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            copied = false
        }
    }

    private var showsClientLink: Bool {
        clientLinkEnabled != nil && skills.clientLink != nil && copy.clientLink != nil
    }

    // MARK: - 接口

    private var interfaceGroup: some View {
        let copy = copy.interface
        return UDSettingsGroup(title: copy.title, footer: copy.footer) {
            UDSettingsRow(label: copy.enableLabel, hint: copy.enableHint) {
                UDToggle(Bindable(control).isEnabled, label: Text(verbatim: copy.enableLabel))
            }

            UDSettingsRow(label: copy.mutationsLabel, hint: copy.mutationsHint) {
                UDToggle(Bindable(control).allowMutations, label: Text(verbatim: copy.mutationsLabel))
                    .disabled(!control.isEnabled)
                    .opacity(control.isEnabled ? 1 : 0.45)
            }

            UDSettingsRow(label: copy.socketLabel, hint: socketPath, hintStyle: .monospaced) {
                UDButton(title: copied ? copy.copiedButton : copy.copyButton, style: .secondary,
                         action: copySocketPath)
            }

            if let error = control.startupError {
                UDSettingsInlineNote(tone: .danger, text: error)
            }
        }
    }

    // MARK: - 后台服务

    private var backgroundGroup: some View {
        let copy = copy.background
        return UDSettingsGroup(title: copy.title, footer: copy.footer) {
            UDSettingsRow(label: copy.launchAtLoginLabel, hint: copy.launchAtLoginHint) {
                UDToggle(Binding(
                    get: { background.launchAtLogin },
                    set: { background.setLaunchAtLogin($0) }
                ), label: Text(verbatim: copy.launchAtLoginLabel))
            }
            UDSettingsRow(label: copy.onDemandLabel, hint: copy.onDemandHint) {
                UDToggle(Bindable(background).allowOnDemandLaunch, label: Text(verbatim: copy.onDemandLabel))
            }
            if let error = background.loginItemError {
                UDSettingsInlineNote(tone: .danger, text: error)
            } else if background.needsLoginItemApproval {
                UDSettingsInlineNote(tone: .warning, text: copy.approvalPending)
            } else if background.loginItemStatus == .notFound {
                UDSettingsInlineNote(tone: .muted, text: copy.notRegistered)
            }
        }
    }

    // MARK: - 技能

    private var skillsGroup: some View {
        let copy = copy.skills
        return UDSettingsGroup(title: copy.title, footer: copy.footer) {
            if !skills.didLoad {
                UDSettingsEmptyRow(symbol: "magnifyingglass", text: copy.detecting)
            } else if skills.availableTargets.isEmpty {
                UDSettingsEmptyRow(symbol: "sparkles", text: copy.noTools)
            } else {
                ForEach(skills.availableTargets, id: \.self) { target in
                    targetRow(target, copy: copy)
                }
            }

            if showsClientLink {
                clientLinkRow
            }

            if let error = skills.lastError {
                UDSettingsInlineNote(tone: .danger, text: error)
            }
        }
    }

    private func targetRow(_ target: SkillTarget, copy: CLISettingsCopy.Skills) -> some View {
        let status = skills.status(for: target)
        let busy = skills.isBusy(target)
        return UDSettingsListRow(icon: target.iconSystemName, tint: Self.tint(for: status),
                                 title: target.displayName,
                                 subtitle: status.conflictReason ?? copy.statusHints.text(for: status)) {
            HStack(spacing: 10) {
                // 已安装不挂徽标：右侧已经有「卸载」，状态一目了然。
                if case .installed = status {} else {
                    StatusPill(text: copy.statusLabels.text(for: status), color: Self.pillColor(for: status))
                }
                if status.canInstall {
                    UDButton(title: copy.installButton, style: .primary, isLoading: busy) {
                        Task { await skills.install(target) }
                    }
                    .disabled(busy)
                } else if status.canUninstall {
                    UDButton(title: copy.uninstallButton, style: .secondary, isLoading: busy) {
                        Task { await skills.uninstall(target) }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    /// 可选的 PATH 链接。与技能安装分开：不装技能也能只要这条链接。
    @ViewBuilder
    private var clientLinkRow: some View {
        if let binding = clientLinkEnabled, let copy = copy.clientLink {
            UDSettingsRow(label: copy.label, hint: copy.hint(for: skills.clientLinkStatus)) {
                UDToggle(Binding(
                    get: { binding.wrappedValue },
                    set: { newValue in
                        binding.wrappedValue = newValue
                        Task { await skills.setClientLinkEnabled(newValue) }
                    }
                ), label: Text(verbatim: copy.label))
                .disabled(skills.clientLinkBusy)
            }
        }
    }

    static func tint(for status: SkillInstallStatus) -> Color {
        switch status {
        case .installed: return UD.success
        case .brokenLink: return UD.caution
        case .conflict: return UD.danger
        case .notInstalled: return UD.text2
        }
    }

    static func pillColor(for status: SkillInstallStatus) -> Color {
        switch status {
        case .installed: return UD.accent
        case .brokenLink: return UD.caution
        case .conflict: return UD.danger
        case .notInstalled: return UD.text4
        }
    }
}

/// 技能行右侧的状态徽标。
private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule(style: .continuous))
    }
}

#endif
