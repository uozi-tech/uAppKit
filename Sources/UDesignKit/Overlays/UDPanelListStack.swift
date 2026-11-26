// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// 浮层面板内容的竖排容器：其余子视图按内容高排，标了 `.udPanelList()` 的那一个（限高内滚的
/// 列表）拿剩下的高度——`min(列表内容高, 上限, 面板可用高 − 其余子视图高 − reserved)`。
///
/// **为什么要它**：此前的做法是列表高、外框高（搜索框 / 标题 / 底部行）各自 `onGeometryChange`
/// 实测后下一拍写回 `@State`。外框高没量到之前按 0 算，屏幕边缘受限时列表上限等于整个可用高，
/// 面板先多出一截外框高、隔一两帧再缩回——就是「下拉一打开闪一下」。这里在同一次布局里量完
/// 所有子视图、一次给出最终高度：面板呈现时的 fittingSize 就是最终尺寸，搜索过滤变矮也同拍收缩。
///
/// 列表子视图一般是 `ScrollView`：它在 nil 提案下按内容给 ideal 高，实提案下吃满提案——这里先用
/// nil 提案量内容高，再按算好的高度实提案摆放，所以既不会撑高（短列表贴内容）也不会伸出屏幕。
///
/// ```
/// UDPanelListStack(spacing: 1, listMaxHeight: 420, reserved: 12) {
///     searchField
///     ScrollView { rows }.udPanelList()
///     footer
/// }
/// .padding(6)
/// ```
public struct UDPanelListStack<Content: View>: View {
    let spacing: CGFloat
    let listMaxHeight: CGFloat
    let reserved: CGFloat
    let content: Content

    /// 所在 `.anchoredPanel` 给出的可用高度（锚点到屏幕可见区边缘）；不在面板里或放得下时为 nil。
    @Environment(\.udPanelAvailableHeight) private var available

    /// - Parameters:
    ///   - spacing: 子视图间距。
    ///   - listMaxHeight: 列表的固定上限（屏幕再宽裕也不超过它）。
    ///   - reserved: 本容器**外面**、同样占用面板可用高度的竖向尺寸——外层 padding、描边等。
    ///     `.padding(6)` 就传 12。
    public init(spacing: CGFloat = 0, listMaxHeight: CGFloat, reserved: CGFloat = 0,
                @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.listMaxHeight = listMaxHeight
        self.reserved = reserved
        self.content = content()
    }

    public var body: some View {
        UDPanelListLayout(spacing: spacing, listMaxHeight: listMaxHeight,
                          available: available.map { $0 - reserved }) {
            content
        }
    }
}

public extension View {
    /// 标记 `UDPanelListStack` 里那个限高内滚的列表（通常是 `ScrollView`）。每个容器只标一个。
    func udPanelList() -> some View {
        layoutValue(key: UDPanelListKey.self, value: true)
    }
}

struct UDPanelListKey: LayoutValueKey {
    static let defaultValue = false
}

/// `UDPanelListStack` 的布局本体（单测直接量它）。`available` 已扣掉 `reserved`。
struct UDPanelListLayout: Layout {
    let spacing: CGFloat
    let listMaxHeight: CGFloat
    let available: CGFloat?

    struct Plan {
        var width: CGFloat
        /// 每个子视图的高度（与 subviews 同序）。
        var heights: [CGFloat]
        var totalHeight: CGFloat
    }

    func plan(width proposedWidth: CGFloat?, subviews: Subviews) -> Plan {
        let width = proposedWidth
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max()
            ?? 0
        var heights: [CGFloat] = []
        heights.reserveCapacity(subviews.count)
        var others: CGFloat = 0
        var listIndex: Int?
        for (i, subview) in subviews.enumerated() {
            if subview[UDPanelListKey.self], listIndex == nil {
                listIndex = i
                heights.append(0)
            } else {
                let h = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                heights.append(h)
                others += h
            }
        }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        if let i = listIndex {
            let natural = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let cap = UDPanelListCap.cap(listMaxHeight, available: available, chrome: others + gaps)
            heights[i] = min(natural, cap)
        }
        return Plan(width: width, heights: heights, totalHeight: heights.reduce(0, +) + gaps)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = plan(width: proposal.width, subviews: subviews)
        return CGSize(width: p.width, height: p.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, p.heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}
#endif
