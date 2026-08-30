// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// DesignKit 下拉触发器：自绘触发按钮 + 贴在其下方的 `UDMenu` 浮层 —— 替代原生 SwiftUI
/// `Menu`（后者渲染系统毛玻璃半透明底、无法套用 DesignKit）。
///
/// **浮层用 `.anchoredPanel`（无边框子 `NSPanel`，`.popUpMenu` 层级）呈现**，天然浮在所有
/// SwiftUI 内容与 AppKit 平台视图之上——不像 in-hierarchy `.overlay` 会被后续同层卡片
/// **遮挡**、或被父容器 `.clipShape` **裁掉**（设置屏分区卡即会裁掉溢出的下拉，只露一条边，
/// 故改用子窗口）。选项点击后由 `UDMenu` 经环境 `udMenuDismiss` 自动收起；点外部 / ESC 亦关。
///
/// 用法：
/// ```
/// UDDropdown(anchor: .leading) { open in
///     triggerLabel(open: open)          // 自绘胶囊 / 带 chevron
/// } content: {
///     UDMenu(width: 184, head: "模型", items: [...带 action...])
/// }
/// ```
public struct UDDropdown<Trigger: View, Content: View>: View {
    /// 浮层与触发器对齐的边（左对齐 / 右对齐）。
    public enum Anchor { case leading, trailing }

    var anchor: Anchor = .leading
    /// 浮层与触发器之间的竖向间隙。
    var gap: CGFloat = 6
    /// 浮层是否成为 key window（内含搜索框等 TextField 时传 true，见 `.anchoredPanel`）。
    var becomesKey = false
    /// 触发器（参数 = 当前是否展开，便于旋转 chevron）。
    @ViewBuilder var trigger: (Bool) -> Trigger
    /// 浮层内容（通常是 `UDMenu`，其选项 `action` 自带业务动作；收起由本组件经 dismiss 统一处理）。
    @ViewBuilder var content: () -> Content

    @State private var open = false
    /// 刚被关闭的时刻 —— 去抖，避免「点触发器把它关闭那一下」又立刻重开。
    @State private var lastClosedAt: Date?

    public init(
        anchor: Anchor = .leading,
        gap: CGFloat = 6,
        becomesKey: Bool = false,
        @ViewBuilder trigger: @escaping (Bool) -> Trigger,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.anchor = anchor
        self.gap = gap
        self.becomesKey = becomesKey
        self.trigger = trigger
        self.content = content
    }

    public var body: some View {
        // 收起（点外部 / ESC / 选中项后 dismiss）都会把 binding 置 false —— 顺手记录时刻用于去抖。
        let presented = Binding<Bool>(
            get: { open },
            set: { newValue in
                if !newValue { lastClosedAt = Date() }
                open = newValue
            }
        )
        return trigger(open)
            .contentShape(Rectangle())
            .onTapGesture {
                if let t = lastClosedAt, Date().timeIntervalSince(t) < 0.25 { return }
                open = true
            }
            .anchoredPanel(isPresented: presented, gap: gap,
                           alignment: anchor == .leading ? .leading : .trailing,
                           becomesKey: becomesKey) { dismiss in
                content().environment(\.udMenuDismiss, dismiss)
            }
    }
}
#endif
