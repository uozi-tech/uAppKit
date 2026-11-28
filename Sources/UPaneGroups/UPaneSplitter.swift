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

    /// 这次拖动开始时的比例；不在拖时为 nil。用 `@GestureState`：手势被取消（拖到一半切走
    /// app、手柄被拆掉）时 SwiftUI 会自己把它复位 —— 普通 `@State` 只在 `onEnded` 里清，取消
    /// 不走 `onEnded`，留下的旧起点会让下一次拖动一上来就跳，指示条也一直停在「拖动中」。
    @GestureState private var dragStartFraction: Double?
    @State private var hovering = false
    @Environment(\.uPaneGroupStyle) private var style
    @Environment(\.uPaneGroupWells) private var wellsEnabled

    /// 辅助功能里一次「增加 / 减少」挪多少比例。
    static let accessibilityStep = 0.05

    public init(orientation: Orientation, fraction: Binding<Double>, totalLength: CGFloat,
                minFraction: Double = 0.15, maxFraction: Double = 0.85) {
        self.orientation = orientation
        self._fraction = fraction
        self.totalLength = totalLength
        self.minFraction = minFraction
        self.maxFraction = maxFraction
    }

    /// 从 `start` 拖过 `translation` 点之后的比例，夹在 `[minFraction, maxFraction]` 里。
    /// `totalLength` 为 0（区域被压没了）时不动，免得除出 NaN 写进布局树。
    static func draggedFraction(from start: Double, translation: CGFloat, totalLength: CGFloat,
                                minFraction: Double, maxFraction: Double) -> Double {
        guard totalLength > 0 else { return start }
        return min(max(start + Double(translation) / Double(totalLength), minFraction), maxFraction)
    }

    private var accessibilityName: String {
        orientation == .vertical
            ? String(localized: "调整左右分组宽度", bundle: ModuleBundle.bundle)
            : String(localized: "调整上下分组高度", bundle: ModuleBundle.bundle)
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
            .onHover { hovering = $0 }
            .modifier(SplitterResizePointer(orientation: orientation))
            .gesture(
                // **`.global` 坐标系，不是 `.local`：** 这枚手柄随 `fraction` 变化
                // 自己移动，而 `.local` 拖拽测的是相对于「移动中的视图」的位移 ——
                // 每一步都把原点在光标下推一次，比例震荡、相邻面板抖动。全局坐标
                // 在手柄移动时保持不变，位移能干净地累加。
                //
                // 起点记在 `updating` 的 inout 里、比例也在这里算：同一拍里 `onChanged` 读到的
                // `@GestureState` 未必已经是这一拍写进去的值，起点读错一次比例就会叠加跳动。
                DragGesture(coordinateSpace: .global)
                    .updating($dragStartFraction) { value, start, _ in
                        let origin = start ?? fraction
                        start = origin
                        let rawDelta = orientation == .vertical
                            ? value.translation.width
                            : value.translation.height
                        fraction = Self.draggedFraction(from: origin, translation: rawDelta,
                                                        totalLength: totalLength,
                                                        minFraction: minFraction,
                                                        maxFraction: maxFraction)
                    }
            )
            // 对辅助功能是一根滑杆：读得出当前占比，「增加 / 减少」按 5% 挪。以前只挂了
            // `.allowsDirectInteraction`（macOS 上什么都不做），VoiceOver 只能听到名字、调不动。
            .accessibilityRepresentation {
                Slider(value: $fraction,
                       in: minFraction...max(minFraction, maxFraction),
                       step: Self.accessibilityStep) {
                    Text(accessibilityName)
                }
                .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            }
            .accessibilityLabel(accessibilityName)
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
                .animation(UDPaneDividerHighlight.animation, value: dragging || hovering)
        } else {
            // 静息态画 1px UD.border 实线分隔；悬停 / 拖动时淡入一条 3px 的浅 accent（1px 太细、
            // 看不出能拖）。粗线只画在 overlay 里，布局仍按 1px 算，两侧分组不会跟着挤动。
            Rectangle()
                .fill(UD.border)
                .frame(
                    width: orientation == .vertical ? 1 : nil,
                    height: orientation == .horizontal ? 1 : nil
                )
                .overlay {
                    UDPaneDividerHighlight(orientation == .vertical ? .vertical : .horizontal,
                                           active: dragging || hovering)
                }
        }
    }
}

/// 悬停时的缩放光标。macOS 15 起走 `pointerStyle`（系统自己管进出与拖动中的光标）；更早的系统
/// 退回 `NSCursor.set()` —— 那条路在快速拖动、光标滑出 6pt 手柄的一瞬会被 `onHover(false)`
/// 换回箭头。
private struct SplitterResizePointer: ViewModifier {
    let orientation: UPaneSplitter.Orientation

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(orientation == .vertical ? .columnResize : .rowResize)
        } else {
            content.onHover { inside in
                if inside {
                    (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }
}
#endif
