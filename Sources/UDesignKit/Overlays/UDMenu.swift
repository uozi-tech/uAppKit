// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// uTerm DesignKit 实体浮层菜单 —— 下拉 / 上下文菜单 / 列表（设计稿 `Components.html` Menu）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// **实底，无模糊**（背景 `UD.overlay`），与 popover/玻璃面区分。选中态用
/// `UD.rowSelected` 实底 + 尾部对勾，hover 用白/黑 5% 叠加，其余透明。
public struct UDMenu: View {
    /// 菜单宽度。
    let width: CGFloat
    /// 可选分组标题（全大写小标签）。
    let head: String?
    /// 菜单项（含分隔线）。
    let items: [UDMenuItem]
    /// 选项区最大高度：项过多时超出即内部纵向滚动（`head` 保持置顶不滚）。
    /// 默认 `defaultMaxHeight`；nil = 不设固定上限（在 `.anchoredPanel` 里仍受屏幕可用高度约束）。
    let maxHeight: CGFloat?

    /// 选项区默认最大高度（约 11 行）。数据驱动的列表（模型、库、编码……）长度不可控，
    /// 不限高会一路伸出屏幕、底部的项点不到，所以默认就限高内滚。
    public static let defaultMaxHeight: CGFloat = 360

    /// 所在 `.anchoredPanel` 给出的可用高度（锚点到屏幕可见区边缘）。
    @Environment(\.udPanelAvailableHeight) private var panelAvailableHeight
    /// 选项区内容的实测高度。nil = 尚未量到（首帧走 `maxHeight` 路径）。
    @State private var itemsHeight: CGFloat?
    /// 已做过「滚到选中项」（只在首次实测落地后做一次）。
    @State private var didInitialScroll = false
    /// 选项区以外（标题行 + 外框 padding）的实测高，从面板可用高度里扣掉。
    @State private var chromeHeight: CGFloat = 0

    public init(width: CGFloat = 200, head: String? = nil, maxHeight: CGFloat? = UDMenu.defaultMaxHeight, items: [UDMenuItem]) {
        self.width = width
        self.head = head
        self.maxHeight = maxHeight
        self.items = items
    }

    private var itemsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isDivider {
                    Rectangle()
                        .fill(UD.border)
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    UDMenuItemRow(item: item).id(item.id)
                }
            }
        }
    }

    /// 选项区高度上限：显式 `maxHeight` 与面板可用高度（扣掉标题与外框 padding）取小。
    private var itemsCap: CGFloat {
        UDPanelListCap.cap(maxHeight ?? .greatestFiniteMagnitude,
                           available: panelAvailableHeight, chrome: chromeHeight)
    }

    /// 选项区当前渲染高（未量到为 nil）。
    private var renderedItemsHeight: CGFloat? {
        itemsHeight.map { min($0, itemsCap) }
    }

    /// 选项区：恒套 ScrollView，高度钉成 `min(实测内容高, 上限)`。
    ///
    /// 不直接 `.frame(maxHeight:)`：它在实提案下会伸展到 `min(提案, 上限)` 而非贴内容，
    /// 短菜单会被撑高、内容在 ScrollView 里垂直居中。首帧未量到时才走 `maxHeight` 路径
    /// （面板初次 fittingSize 是 nil 提案，此时按内容 ideal 收缩，不会撑高）。
    private var scrollingItems: some View {
        let cap = itemsCap
        let overflows = (itemsHeight ?? 0) > cap
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                itemsStack
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured in
                        // 写回落到下一拍：同步写会让被约束的 ScrollView 实测依赖自身（AttributeGraph 环）。
                        guard itemsHeight.map({ abs($0 - measured) > 0.5 }) ?? true else { return }
                        DispatchQueue.main.async {
                            guard itemsHeight.map({ abs($0 - measured) > 0.5 }) ?? true else { return }
                            itemsHeight = measured
                        }
                    }
            }
            .scrollIndicators(overflows ? .automatic : .never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(UDHeightClamp(measured: itemsHeight, cap: cap))
            .onChange(of: itemsHeight == nil) {
                // 当前选中项不在首屏时滚到可见（长模型列表里选中的是第 30 个，展开直接看到它）。
                // 等首次实测落地、ScrollView 钉到最终高度后再滚——更早滚会被随后的改高冲掉。
                guard !didInitialScroll, overflows,
                      let active = items.first(where: { $0.active })?.id else { return }
                didInitialScroll = true
                DispatchQueue.main.async { proxy.scrollTo(active, anchor: .center) }
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let head {
                Text(head.uppercased())
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text4)
                    .padding(.top, 4)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if maxHeight == nil && panelAvailableHeight == nil {
                itemsStack
            } else {
                scrollingItems
            }
        }
        .padding(4)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(UD.overlay)
        )
        .overlay(
            // 浮层细发丝边：单层 UD.border（白 7% / 黑 10%），无内高光。
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .udPanelChrome($chromeHeight, listHeight: renderedItemsHeight)
        // 落影由承载它的 `.anchoredPanel` 统一提供（见 UDDropdown）；此处不再自带，避免双重阴影。
    }
}

/// 选项点击后收起承载 `UDMenu` 的浮层。`UDDropdown` 会把 `.anchoredPanel` 的 dismiss
/// 经此环境注入到每个选项行；`UDMenu` 独立使用（不在下拉里）时默认 no-op。
private struct UDMenuDismissKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: () -> Void = {}
}
public extension EnvironmentValues {
    var udMenuDismiss: () -> Void {
        get { self[UDMenuDismissKey.self] }
        set { self[UDMenuDismissKey.self] = newValue }
    }
}

/// 单条菜单行（hover 态内部自管理）。`item.action` 非 nil 时整行可点（功能菜单）；
/// 为 nil 时为纯展示（Gallery）。
private struct UDMenuItemRow: View {
    let item: UDMenuItem
    @State private var hovered = false
    /// 由 `UDDropdown` 注入：选中后收起浮层。独立 `UDMenu` 时为 no-op。
    @Environment(\.udMenuDismiss) private var dismiss

    public var body: some View {
        if let action = item.action {
            Button(action: { action(); dismiss() }) { rowBody }
                .buttonStyle(.udPlain)
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: 8) {
            if let dotColor = item.dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(UD.font(12.5))
                    .foregroundStyle(foreground)
                    .frame(width: 14)
            }

            Text(item.label)
                .font(UD.font(12.5))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.active {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.accentInk)
            } else if let kbd = item.kbd {
                Text(UFormat.shortcut(kbd))
                    .font(UD.mono(10))
                    .foregroundStyle(UD.text4)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.sm)
                .fill(background)
        )
        .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        .onHover { hovered = $0 }
    }

    private var foreground: Color {
        if item.danger { return UD.danger }
        // v2「驾驶舱」样式：激活行文字与图标同用 accent 色。
        return item.active ? UD.accent : UD.text2
    }

    /// hover 行底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let hoverBg = UD.dyn(.white(0.05), .black(0.05))

    private var background: Color {
        if item.active { return UD.rowSelected }
        if hovered { return Self.hoverBg }
        return .clear
    }
}

/// uTerm DesignKit 菜单项模型 —— `UDMenu` 的数据载体。
///
/// `isDivider == true` 时只渲染一条分隔线，其余字段忽略；用 `.divider()` 构造。
public struct UDMenuItem: Identifiable {
    public let id = UUID()
    /// 行标题。
    var label: String
    /// 前导 SF Symbol 名（与 `dotColor` 二选一，`dotColor` 优先）。
    var systemImage: String?
    /// 前导 6pt 圆点色（模型 / 状态指示）。
    var dotColor: Color?
    /// 尾部快捷键标签（`active` 时被对勾取代）。
    var kbd: String?
    /// 选中态：实底 + 尾部对勾。
    var active: Bool
    /// 危险项：文本染 `UD.danger`。
    var danger: Bool
    /// 是否为分隔线。
    var isDivider: Bool
    /// 点击回调。非 nil 时整行变 `Button`（功能菜单）；nil 为纯展示（Gallery）。
    var action: (() -> Void)?

    public init(
        label: String,
        systemImage: String? = nil,
        dotColor: Color? = nil,
        kbd: String? = nil,
        active: Bool = false,
        danger: Bool = false,
        isDivider: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.systemImage = systemImage
        self.dotColor = dotColor
        self.kbd = kbd
        self.active = active
        self.danger = danger
        self.isDivider = isDivider
        self.action = action
    }

    /// 分隔线项。
    public static func divider() -> UDMenuItem {
        UDMenuItem(label: "", isDivider: true)
    }
}

#Preview {
    HStack(alignment: .top, spacing: 24) {
        // (a) 模型选择器
        UDMenu(width: 184, head: "模型", items: [
            UDMenuItem(label: "claude-sonnet", dotColor: UD.accent, active: true),
            UDMenuItem(label: "claude-opus", dotColor: UD.accentViolet),
            UDMenuItem(label: "claude-haiku", dotColor: UD.success),
        ])

        // (b) 上下文菜单
        UDMenu(items: [
            UDMenuItem(label: "在终端打开", systemImage: "terminal", kbd: "↩"),
            UDMenuItem(label: "复制路径", systemImage: "doc.on.doc", kbd: "⌘C"),
            UDMenuItem(label: "重命名", systemImage: "pencil"),
            .divider(),
            UDMenuItem(label: "删除", systemImage: "trash", kbd: "⌫", danger: true),
        ])
    }
    .padding(40)
    .background(UD.bg)
}
#endif
