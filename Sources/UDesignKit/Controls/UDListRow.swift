import SwiftUI

/// uTerm DesignKit 列表行选择钮 —— 弹层/下拉里「逐行列出、点选即动作」的候选行。
///
/// 可选前导 SF 图标 + 标题 + 可选尾部文本，整行 30 高、`UD.bg` 底、hover 提 `UD.rowHover`、
/// 连续圆角 7。点选触发 `action`（如 GRANT 某成员、切换某项）。仅切底色，无位移、无投影。
///
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
public struct UDListRow: View {
    var systemImage: String? = nil
    let title: String
    var trailing: String? = nil
    /// 标题用等宽字体（对象名 / 标识符行）。
    var monospacedTitle: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(
        systemImage: String? = nil,
        title: String,
        trailing: String? = nil,
        monospacedTitle: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.trailing = trailing
        self.monospacedTitle = monospacedTitle
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10)).foregroundStyle(UD.text3)
                }
                Text(title)
                    .font(monospacedTitle ? UD.mono(11.5) : UD.font(12.5))
                    .foregroundStyle(UD.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(UD.font(11)).foregroundStyle(UD.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && isEnabled ? UD.rowHover : UD.bg)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.udPlainKeepsDisabledLook)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    @MainActor func demo(_ scheme: ColorScheme) -> some View {
        VStack(spacing: 2) {
            UDListRow(systemImage: "person", title: "app_readonly", monospacedTitle: true) {}
            UDListRow(systemImage: "person", title: "analytics_rw", monospacedTitle: true) {}
            UDListRow(title: "public", trailing: "12 表") {}
            UDListRow(systemImage: "person", title: "禁用行", monospacedTitle: true) {}.disabled(true)
        }
        .padding(14).frame(width: 240).background(UD.overlay)
        .environment(\.colorScheme, scheme)
    }
    return HStack(spacing: 0) { demo(.dark); demo(.light) }
}
