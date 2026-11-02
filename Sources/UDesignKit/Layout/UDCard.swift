import SwiftUI

/// 分区方案 v3.3 的版式常量与内容卡外框（设计稿「分区方案 v3.html」与两份 SwiftUI 交接）。
///
/// 三层底色：窗口画布 `UD.pageBg` → 内容卡 `UD.panel` → 卡内抬升 `UD.panelHi`。
/// 窗口里的内容区是**一张卡**，距窗口边 `cardInset`；卡里的各栏（列表 | 内容 | Agent）
/// 用 1pt `UD.border` 竖线分开、两侧同为卡面色——线和底色差只用其一。
/// 标题栏、状态栏、图标导航轨直接画在画布上，不铺底色、不画分隔线。
public extension UD {
    enum Layout {
        /// 内容卡距窗口边（右 / 下；左侧由画布上的导航占位）。
        public nonisolated static let cardInset: CGFloat = 8
        /// 内容卡圆角。
        public nonisolated static let cardRadius: CGFloat = UD.Radius.lg
        /// 卡内凹槽（终端 / 代码区）圆角。
        public nonisolated static let wellRadius: CGFloat = UD.Radius.md
        /// 卡内凹槽之间（终端分屏窗格）的间距。
        public nonisolated static let wellGap: CGFloat = 6
        /// 卡内分隔线两侧的拖拽命中区总宽（线居中）。
        public nonisolated static let dividerHitWidth: CGFloat = 7
        /// 图标导航轨宽度与按钮边长。
        public nonisolated static let railWidth: CGFloat = 48
        public nonisolated static let railButton: CGFloat = 32
    }

    /// 内容卡的 1pt 细轮廓：日间白卡在 #F5F5F5 画布上不发虚，暗夜补一道明度边。
    nonisolated static let cardRing = dyn(.white(0.06), .black(0.06))
}

private struct UDCardModifier: ViewModifier {
    let fill: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UD.Layout.cardRadius, style: .continuous)
        content
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.strokeBorder(UD.cardRing, lineWidth: 1))
            // 只有日间补一层极轻投影（0 1 2 · 4%）；暗夜靠明度差与轮廓成边。
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 1, x: 0, y: 1)
    }
}

public extension View {
    /// 套用内容卡外框：卡面底色 + 圆角 10 + 1pt 细轮廓（+ 日间轻投影）。
    /// 卡里的分栏用 `UDPaneDivider` 分开，不要再给子栏单独套卡。
    nonisolated func udCard(fill: Color = UD.panel) -> some View {
        modifier(UDCardModifier(fill: fill))
    }

    /// 卡内凹槽（终端 / 代码区）：凹槽底色 + 圆角 8。
    nonisolated func udWell(fill: Color = UD.termBg) -> some View {
        background(RoundedRectangle(cornerRadius: UD.Layout.wellRadius, style: .continuous).fill(fill))
            .clipShape(RoundedRectangle(cornerRadius: UD.Layout.wellRadius, style: .continuous))
    }
}

/// 卡内分栏之间的 1pt 分隔线（两侧同为卡面色）。`axis` 为线的走向。
public struct UDPaneDivider: View {
    public enum Axis { case vertical, horizontal }
    let axis: Axis

    public init(_ axis: Axis = .vertical) { self.axis = axis }

    public var body: some View {
        Rectangle()
            .fill(UD.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}
