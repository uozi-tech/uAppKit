import SwiftUI

/// 可拖分隔线悬停 / 拖动时叠在 1pt 线上的那条粗线：3pt、浅 accent（`UD.accentDivider`），
/// 淡入淡出而不是一下子冒出来（2026-11-26 实机反馈：硬切太生硬）。
///
/// 用法：叠在 1pt 的 `UD.border` 线的 overlay 里，始终挂着、靠 `active` 切透明度；
/// 布局仍按 1pt 算，两侧的栏不会跟着挤动。不接收鼠标，命中区由调用方叠。
/// UPaneGroups 的分隔线和各 App 的列宽分隔线都用它。
public struct UDPaneDividerHighlight: View {
    /// 粗线的粗细。
    public static let thickness: CGFloat = 3
    /// 出现 / 消失的动画。分隔条上的把手（凹槽模式那根 2×24 的胶囊）也用它，两者节奏一致。
    public static let animation: Animation = .easeOut(duration: 0.16)

    let axis: UDPaneDivider.Axis
    let active: Bool

    public init(_ axis: UDPaneDivider.Axis = .vertical, active: Bool) {
        self.axis = axis
        self.active = active
    }

    public var body: some View {
        Rectangle()
            .fill(UD.accentDivider)
            .frame(width: axis == .vertical ? Self.thickness : nil,
                   height: axis == .horizontal ? Self.thickness : nil)
            .opacity(active ? 1 : 0)
            .animation(Self.animation, value: active)
            .allowsHitTesting(false)
    }
}
