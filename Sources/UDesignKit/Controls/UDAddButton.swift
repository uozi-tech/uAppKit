import SwiftUI

/// uTerm DesignKit 虚线「＋新建 / 添加」affordance —— 列表 / 表格尾部的新增入口。
///
/// 32 高、`UD.Radius.md` 圆角、`UD.borderHi` 虚线描边（dash 4/3）、前导「＋」+ 标签，
/// 文字 `UD.text2`（禁用 `text4`，hover 提到 `text` 并把描边提到 `text3`）。默认满宽
/// （`fullWidth`）。**无填充**——虚线本身即「待填充」的视觉隐喻（v2「填充即边界」的例外，
/// 描边在此承载「虚位以待」语义）。仅切文字 / 描边色，无位移、无投影。
///
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
public struct UDAddButton: View {
    let title: String
    var systemImage: String = "plus"
    /// 满宽（列表尾部通栏）；`false` 则按内容宽 + 14 横向内边距（行内新增）。
    var fullWidth: Bool = true
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(
        title: String,
        systemImage: String = "plus",
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(title).font(UD.font(12))
            }
            .foregroundStyle(!isEnabled ? UD.text4 : (hovering ? UD.text : UD.text2))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 32)
            .padding(.horizontal, fullWidth ? 0 : 14)
            .overlay {
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .strokeBorder(hovering && isEnabled ? UD.text3 : UD.borderHi,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
        }
        .buttonStyle(.udPlainKeepsDisabledLook)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    @MainActor func demo(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            UDAddButton(title: "新建角色") {}
            UDAddButton(title: "添加成员") {}.disabled(true)
            HStack {
                UDAddButton(title: "添加列", fullWidth: false) {}
                UDAddButton(title: "添加外键", systemImage: "plus", fullWidth: false) {}
            }
        }
        .padding(24)
        .frame(width: 320, alignment: .leading)
        .background(UD.card)
        .environment(\.colorScheme, scheme)
    }
    return HStack(spacing: 0) { demo(.dark); demo(.light) }
}
