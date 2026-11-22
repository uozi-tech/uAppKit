import SwiftUI

/// 需审批工具的确认卡（uTable `ApprovalCard` 收编）：标题 + 工具名、模型给的理由、审批策略的
/// 说明、等宽正文（SQL / 命令 / 参数），拒绝 / 允许，以及可选的「本会话允许」。
///
/// 纯展示组件：文案、正文、回调都由调用方给，不依赖 AgentKit。
/// 极淡 warning 底 + warning 状态描边；卡里的正文块是唯一一层灰。
public struct UDAgentApprovalCard: View {
    let title: String
    let toolName: String
    let reason: String?
    let note: String?
    let detail: String
    let isDestructive: Bool
    let denyTitle: String
    let allowTitle: String
    let allowForSessionTitle: String?
    let onDeny: () -> Void
    let onAllow: () -> Void
    let onAllowForSession: (() -> Void)?

    /// - Parameters:
    ///   - note: 审批策略转人工的说明（如「不是只读命令」）；nil 不显示。
    ///   - isDestructive: 允许钮用危险色（写库、强推）。
    ///   - allowForSessionTitle: 非 nil 且给了 `onAllowForSession` 时出现「本会话允许」。
    public init(
        title: String = String(localized: "需要确认", bundle: ModuleBundle.bundle),
        toolName: String,
        reason: String? = nil,
        note: String? = nil,
        detail: String,
        isDestructive: Bool = false,
        denyTitle: String = String(localized: "拒绝", bundle: ModuleBundle.bundle),
        allowTitle: String = String(localized: "允许", bundle: ModuleBundle.bundle),
        allowForSessionTitle: String? = String(localized: "本会话允许", bundle: ModuleBundle.bundle),
        onDeny: @escaping () -> Void,
        onAllow: @escaping () -> Void,
        onAllowForSession: (() -> Void)? = nil
    ) {
        self.title = title
        self.toolName = toolName
        self.reason = reason
        self.note = note
        self.detail = detail
        self.isDestructive = isDestructive
        self.denyTitle = denyTitle
        self.allowTitle = allowTitle
        self.allowForSessionTitle = allowForSessionTitle
        self.onDeny = onDeny
        self.onAllow = onAllow
        self.onAllowForSession = onAllowForSession
    }

    private static let tint = UD.warning.opacity(0.05)
    private static let stroke = UD.warning.opacity(0.45)

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.warning)
                Text(title).font(UD.font(11.5, weight: .semibold)).foregroundStyle(UD.text)
                Text(toolName).font(UD.mono(10.5)).foregroundStyle(UD.text3)
                Spacer(minLength: 0)
            }

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(UD.font(11.5))
                    .foregroundStyle(UD.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(detail)
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: UD.Radius.sm).fill(UD.uw03))

            if let note, !note.isEmpty {
                Label(note, systemImage: "info.circle")
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text3)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let allowForSessionTitle, let onAllowForSession {
                    UDButton(title: allowForSessionTitle, style: .ghost, action: onAllowForSession)
                }
                UDButton(title: denyTitle, style: .secondary, action: onDeny)
                UDButton(title: allowTitle, style: isDestructive ? .danger : .primary, action: onAllow)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UD.Radius.md).fill(Self.tint))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).stroke(Self.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(title)：\(toolName)", bundle: .module, comment: "审批卡片读屏标签：标题：工具名"))
    }
}
