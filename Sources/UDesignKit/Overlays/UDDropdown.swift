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
        // 触发器是真 `Button`：VoiceOver / 全键盘控制（Tab 聚焦、空格按下）都够得着，AX 默认动作
        // 就是按下。再点一下收起：`.anchoredPanel` 不把落在触发器上的点击当成「点外关闭」，
        // 这里的 toggle 就是唯一的那次状态变化，不再需要「刚关又开」的去抖。
        Button(action: toggle) {
            trigger(open)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .anchoredPanel(isPresented: $open, gap: gap,
                       alignment: anchor == .leading ? .leading : .trailing,
                       becomesKey: becomesKey) { dismiss in
            content().environment(\.udMenuDismiss, dismiss)
        }
    }

    private func toggle() {
        open.toggle()
    }
}
#endif
