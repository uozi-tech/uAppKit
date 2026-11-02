#if os(macOS)
import AppKit
import SwiftUI
import UDesignKit

/// `.card` 外观（见 `UPaneGroupStyle`）之上的**凹槽**变体：面板内容不铺满组矩形，而是
/// 卡内凹槽 —— 贴区域外缘的三边各内缩 6pt、圆角 8；组与组之间是 6pt 卡面间隙（`UPaneSplitter`
/// 不再画线，悬停浮出 2×24 把手）；多组时日间给每个凹槽一圈极淡轮廓、活动组凹槽保留 1.5pt
/// accent 外框（`showsActiveGroupRing` 打开时）。
///
/// uTerm 的终端区 / 预览区用（分区方案 v3.3 第 6 条：终端 / 编辑区是卡内凹槽）；uTable 的
/// 编辑区不用 —— 它的分屏是卡内 1pt 线。只在 `.card` 下生效，`.classic` 忽略。
///
/// 单独一个环境值而不是 `UPaneGroupStyle` 的一个档位：两者正交（凹槽只是 `.card` 的子选项），
/// 老调用方与只要 `.card` 的调用方都不受影响。
public enum UPaneWellMetrics {
    /// 凹槽距区域外缘的内缩（组与组之间的间隙由分隔条厚度 6 提供）。
    public nonisolated static let inset: CGFloat = UD.Layout.wellGap
    public nonisolated static let radius: CGFloat = UD.Layout.wellRadius
    /// 凹槽四角之外露出的卡面色 —— 角帽用它把方角盖成圆角（见 `UPaneWellChrome`）。
    public nonisolated static let cardFill: Color = UD.panel
    /// 分屏窗格轮廓 `--u-pane-ring`：日间 #E8E8E8，暗夜透明。
    public nonisolated static let paneRing: Color = UD.dyn(.white(0), .hex(0xE8E8E8))
    /// 分隔条把手（悬停 `text4`，拖动转 accent）。
    public nonisolated static let gripLength: CGFloat = 24
    public nonisolated static let gripThickness: CGFloat = 2
}

private struct UPaneGroupWellsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `.card` 外观下面板是否画成卡内凹槽。默认 false。
    public var uPaneGroupWells: Bool {
        get { self[UPaneGroupWellsKey.self] }
        set { self[UPaneGroupWellsKey.self] = newValue }
    }
}

extension View {
    /// 让子树里 `.card` 外观的 `UPaneGroupArea` 把面板画成卡内凹槽（见 `UPaneWellMetrics`）。
    public func uPaneGroupWells(_ enabled: Bool = true) -> some View {
        environment(\.uPaneGroupWells, enabled)
    }
}

// MARK: - 凹槽几何

extension UPaneGroupGeometry {
    /// 凹槽相对组矩形的内缩：贴区域外缘的边缩 `inset`，与相邻组相接的边不缩（两组之间
    /// 已有 6pt 分隔条），顶边让出标签条。
    static func wellInsets(paneRect: CGRect, areaSize: CGSize,
                           stripHeight: CGFloat) -> EdgeInsets {
        let inset = UPaneWellMetrics.inset
        let epsilon: CGFloat = 0.5
        return EdgeInsets(
            top: stripHeight,
            leading: paneRect.minX <= epsilon ? inset : 0,
            bottom: paneRect.maxY >= areaSize.height - epsilon ? inset : 0,
            trailing: paneRect.maxX >= areaSize.width - epsilon ? inset : 0)
    }

    static func rect(_ paneRect: CGRect, insetBy e: EdgeInsets) -> CGRect {
        CGRect(x: paneRect.minX + e.leading,
               y: paneRect.minY + e.top,
               width: max(0, paneRect.width - e.leading - e.trailing),
               height: max(0, paneRect.height - e.top - e.bottom))
    }
}

// MARK: - 凹槽外框（角帽 + 轮廓 + 焦点框）

/// 一个组的凹槽外框，盖在面板内容之上、不可命中。
///
/// **圆角用角帽，不用 `clipShape`：** 凹槽里常是 AppKit 内容（终端的 Metal 图层、
/// 代码编辑器），圆角裁剪会给它们挂遮罩层，终端每帧重绘都要多走一遍离屏合成。四个
/// 角上各画一小块卡面色（矩形减圆角矩形）效果一样，而且是静态图元，只在尺寸变化时重画。
struct UPaneWellChrome<Payload>: View {
    let groupID: UUID
    let model: UPaneGroupsModel<Payload>
    let showsRings: Bool
    let showsActiveRing: Bool

    var body: some View {
        let radius = UPaneWellMetrics.radius
        ZStack {
            WellCornerCaps(radius: radius)
                .fill(UPaneWellMetrics.cardFill, style: FillStyle(eoFill: true))
            if showsRings {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(UPaneWellMetrics.paneRing, lineWidth: 1)
            }
            if showsActiveRing {
                UPaneWellFocusRing(groupID: groupID, model: model)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 活动组凹槽的 1.5pt accent 外框。独立的薄视图：唯一读 `activeGroupID` 的地方。
private struct UPaneWellFocusRing<Payload>: View {
    let groupID: UUID
    let model: UPaneGroupsModel<Payload>

    var body: some View {
        let isActive = (model.activeGroupID ?? model.root.firstLeafID) == groupID
        RoundedRectangle(cornerRadius: UPaneWellMetrics.radius, style: .continuous)
            .strokeBorder(isActive ? UD.accent : Color.clear, lineWidth: 1.5)
    }
}

/// 矩形 + 内切圆角矩形，奇偶填充后只剩四个角。
private struct WellCornerCaps: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius),
                         style: .continuous)
        return p
    }
}

// MARK: - `.card` 标签条右侧的小按钮

/// 标签条右侧的方形图标按钮（分屏 / 关闭空分组）：26×26、圆角 6，悬停 `panelHover`。
struct UPaneCardStripButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovering ? UD.text : UD.text3)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? UD.panelHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
#endif
