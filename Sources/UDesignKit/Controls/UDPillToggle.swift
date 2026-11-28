import SwiftUI

/// uTerm DesignKit 胶囊开关 —— 设计稿 v2 权限/属性「点 + 标签 + 说明」胶囊。
///
/// 区别于 `UDToggle`（拨动开关）与 `UDCheckbox`（方形勾选）：`UDPillToggle` 是一整条
/// 可点胶囊，含前导 6px 状态点 + 标签 + 可选说明文字。开态 = `UD.accentTint` 底、无边、
/// 状态点亮（`onDot`）、标签 `UD.text`；关态 = `UD.bg` 底 + hairline 描边、状态点 `UD.uw10`、
/// 标签 `UD.text2`。用 `isOn: Bool` + `action`（而非 `Binding`），便于调用方拦截切换去跑
/// 授权/回收等副作用。仅切底色，无位移、无投影。
///
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
public struct UDPillToggle: View {
    let label: String
    var hint: String? = nil
    let isOn: Bool
    /// 开态状态点颜色（默认 accent；「已授权」类语义可传 `UD.success`）。
    var onDot: Color = UD.accentDefault
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(
        label: String,
        hint: String? = nil,
        isOn: Bool,
        onDot: Color = UD.accentDefault,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.hint = hint
        self.isOn = isOn
        self.onDot = onDot
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isOn ? onDot : UD.uw10)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(UD.mono(11.5, weight: .semibold))
                    .foregroundStyle(isOn ? UD.text : UD.text2)
                if let hint {
                    Text(hint)
                        .font(UD.font(11))
                        .foregroundStyle(UD.text2)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? UD.accentTint : (hovering && isEnabled ? UD.panelHover : UD.bg))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isOn ? Color.clear : UD.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.udPlainKeepsDisabledLook)
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { hovering = $0 }
        // 开 / 关只靠底色与状态点区分，对辅助功能补成系统开关：读得出状态，按下走 `action`
        // （调用方拦截切换的语义不变——写回值被忽略，真正的切换由 action 决定）。
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) { Text(verbatim: label) }
                .udAccessibilityHint(hint.map { Text(verbatim: $0) })
        }
    }
}

// MARK: - Preview

#Preview {
    struct Demo: View {
        @State private var ssl = true
        @State private var expired = false
        @State private var locked = false
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                UDPillToggle(label: "SELECT", hint: "读取数据", isOn: true, onDot: UD.success) {}
                UDPillToggle(label: "INSERT", hint: "写入数据", isOn: false, onDot: UD.success) {}
                UDPillToggle(label: "要求 SSL", isOn: ssl) { ssl.toggle() }
                UDPillToggle(label: "密码已过期", isOn: expired) { expired.toggle() }
                UDPillToggle(label: "账户锁定", isOn: locked) { locked.toggle() }
                    .disabled(true)
            }
            .padding(24)
            .frame(width: 320, alignment: .leading)
            .background(UD.card)
        }
    }
    return HStack(spacing: 0) {
        Demo().environment(\.colorScheme, .dark)
        Demo().environment(\.colorScheme, .light)
    }
}
