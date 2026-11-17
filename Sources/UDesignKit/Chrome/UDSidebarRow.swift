import SwiftUI

/// uTerm DesignKit 侧栏行 —— 可点击的侧边列表项（设计稿 `Components.html` SidebarRow）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// 选中态用 `UD.rowSelected` 实底，hover 用 `UD.rowHover`，其余透明。
public struct UDSidebarRow: View {
    /// 前导 SF Symbol 名。
    let systemImage: String
    /// 图标颜色（nil = 跟随选中态：选中 `UD.accent`、否则 `UD.text3`）。
    /// 显式给值时它是**语义色**，选中态不覆盖。
    let iconColor: Color?
    /// 行标题。
    let label: String
    /// 尾部计数徽标（nil 不显示）。
    let count: Int?
    /// hover 时尾部显示的快捷键提示（如 "⌘1"）；nil 不显示。优先于计数。
    let shortcutHint: String?
    /// 是否选中。
    let selected: Bool
    /// 点击回调。
    let action: () -> Void

    public init(
        systemImage: String = "circle",
        label: String,
        count: Int? = nil,
        selected: Bool = false,
        action: @escaping () -> Void = {},
        iconColor: Color? = nil,
        shortcutHint: String? = nil
    ) {
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.label = label
        self.count = count
        self.selected = selected
        self.action = action
        self.shortcutHint = shortcutHint
    }

    @State private var hovered = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // v2「驾驶舱」样式：选中态文字与图标同用 accent 色。
                //
                // **显式传进来的 `iconColor` 是语义色（欢迎页侧栏的分组色就是它），
                // 选中态不覆盖它** —— 否则选中一个分组，代表这个分组的那个圆点会被
                // 染成 accent 蓝，行里就再也看不出这是哪个分组。没传 `iconColor`
                // 的调用方（图标本来就是中性灰）照旧走「选中变 accent」。
                Image(systemName: systemImage)
                    .font(UD.font(12.5))
                    .foregroundStyle(iconColor ?? (selected ? UD.accent : UD.text3))
                    .frame(width: 14)

                Text(label)
                    .font(UD.font(12.5))
                    .foregroundStyle(selected ? UD.accent : UD.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hovered, let shortcutHint {
                    UDKbd(shortcutHint)
                } else if let count {
                    Text("\(count)")
                        .font(UD.monoMetric)
                        .foregroundStyle(UD.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        }
        .buttonStyle(.udPlain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if selected { return UD.rowSelected }
        if hovered { return UD.rowHover }
        return .clear
    }
}

/// uTerm DesignKit 侧栏分组标题 —— 全大写、加宽字距的小标签。
public struct UDSidebarSectionHeader: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(UD.font(10.5, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(UD.text4)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 2) {
        UDSidebarSectionHeader("Servers")
        UDSidebarRow(systemImage: "server.rack", label: "Production")
        UDSidebarRow(systemImage: "externaldrive.connected.to.line.below",
                     label: "Staging", selected: true)
        UDSidebarRow(systemImage: "folder", label: "Bookmarks", count: 12)
    }
    .padding(UD.Space.sm)
    .frame(width: 224)
    .background(UD.bg)
}
