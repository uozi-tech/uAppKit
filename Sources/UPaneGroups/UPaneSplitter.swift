#if os(macOS)
import AppKit
import SwiftUI
import UDesignKit

/// 两个组之间可拖动的分隔条。拖动时实时更新 `fraction`，两侧同帧重排。
///
/// 区域本身不用递归的容器视图布局（见 `UPaneGroupArea`：树摊平成矩形列表，
/// 避免分屏 / 合屏时重建整棵子树），只留这枚手柄。
public struct UPaneSplitter: View {
    public enum Orientation: Sendable {
        case horizontal      // 线是横的 → 上下拖
        case vertical        // 线是竖的 → 左右拖
    }

    public let orientation: Orientation
    @Binding public var fraction: Double
    public let totalLength: CGFloat
    public var minFraction: Double
    public var maxFraction: Double

    @State private var dragStartFraction: Double?
    @State private var hovering = false
    @Environment(\.uPaneGroupStyle) private var style
    @Environment(\.uPaneGroupWells) private var wellsEnabled

    public init(orientation: Orientation, fraction: Binding<Double>, totalLength: CGFloat,
                minFraction: Double = 0.15, maxFraction: Double = 0.85) {
        self.orientation = orientation
        self._fraction = fraction
        self.totalLength = totalLength
        self.minFraction = minFraction
        self.maxFraction = maxFraction
    }

    public var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay { indicator }
            .frame(
                width: orientation == .vertical ? 6 : nil,
                height: orientation == .horizontal ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // **`.global` 坐标系，不是 `.local`：** 这枚手柄随 `fraction` 变化
                // 自己移动，而 `.local` 拖拽测的是相对于「移动中的视图」的位移 ——
                // 每一步都把原点在光标下推一次，比例震荡、相邻面板抖动。全局坐标
                // 在手柄移动时保持不变，位移能干净地累加。
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartFraction == nil { dragStartFraction = fraction }
                        let start = dragStartFraction ?? fraction
                        let rawDelta = orientation == .vertical
                            ? value.translation.width
                            : value.translation.height
                        let unclamped = start + Double(rawDelta) / Double(totalLength)
                        fraction = min(max(unclamped, minFraction), maxFraction)
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
            .accessibilityLabel(Text(orientation == .vertical ? "调整左右分组宽度" : "调整上下分组高度"))
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    @ViewBuilder
    private var indicator: some View {
        let dragging = dragStartFraction != nil
        if style.kind == .card && wellsEnabled {
            // 凹槽模式：6pt 卡面间隙本身就是分隔，静息态什么都不画，悬停浮出 2×24 的
            // text4 把手，拖动时把手转 accent（设计稿 pane-split.jsx）。
            let long = UPaneWellMetrics.gripLength
            let thin = UPaneWellMetrics.gripThickness
            Capsule()
                .fill(dragging ? UD.accent : UD.text4)
                .frame(width: orientation == .vertical ? thin : long,
                       height: orientation == .vertical ? long : thin)
                .opacity(dragging || hovering ? 1 : 0)
        } else {
            // 静息态画 1px UD.border 实线分隔；悬停 / 拖动时加粗到 3px 并转 accent（1px 太细、
            // 看不出能拖）。粗线只画在 overlay 里，布局仍按 1px 算，两侧分组不会跟着挤动。
            Rectangle()
                .fill(UD.border)
                .frame(
                    width: orientation == .vertical ? 1 : nil,
                    height: orientation == .horizontal ? 1 : nil
                )
                .overlay {
                    if dragging || hovering {
                        Rectangle()
                            .fill(UD.accent)
                            .frame(width: orientation == .vertical ? 3 : nil,
                                   height: orientation == .horizontal ? 3 : nil)
                    }
                }
        }
    }
}
#endif
