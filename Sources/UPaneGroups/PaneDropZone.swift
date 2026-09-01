import Foundation
import CoreGraphics

// 5 投放区的归类 + 拖拽高亮的门控。都是纯函数，不在 `#if os(macOS)` 里，可单测。
//
// 放在 `UPaneGroups` 而不是 `UPaneTree`：配套的 `PaneDropHighlight` 要用
// `UD.accent`，把 UDesignKit 依赖压给纯值类型的 `UPaneTree` 不划算。

/// 一个组的 5 个投放区：
/// - 中心 50%×50% → 把标签并入该组
/// - 上 / 下 25% 横条 → 在目标上方 / 下方分屏
/// - 左 / 右 25% 竖条 → 在目标左侧 / 右侧分屏
public enum PaneDropZone: String, Sendable, Hashable, Codable {
    case center, top, bottom, leading, trailing
}

/// 把组本地坐标系下的一个点归类到投放区。中心 50%×50% → `center`；否则归到
/// 最近的边。`bounds` 宽或高为零时返回 nil。
public nonisolated func paneDropZone(at location: CGPoint, in bounds: CGRect) -> PaneDropZone? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let nx = (location.x - bounds.minX) / bounds.width
    let ny = (location.y - bounds.minY) / bounds.height
    let edge = 0.25
    if nx >= edge && nx <= 1 - edge && ny >= edge && ny <= 1 - edge {
        return .center
    }
    let distLeading = nx
    let distTrailing = 1 - nx
    let distTop = ny
    let distBottom = 1 - ny
    let minDist = min(distLeading, distTrailing, distTop, distBottom)
    switch minDist {
    case distLeading: return .leading
    case distTrailing: return .trailing
    case distTop: return .top
    default: return .bottom
    }
}

/// 拖拽悬停目标：某个组 + 命中的投放区。
public nonisolated struct PaneDragHoverTarget: Equatable, Sendable {
    public let groupID: UUID
    public let zone: PaneDropZone

    public init(groupID: UUID, zone: PaneDropZone) {
        self.groupID = groupID
        self.zone = zone
    }
}

/// 某个组此刻该画哪个投放区高亮。
///
/// 只看 hover 是不够的：SwiftUI/AppKit 在拖拽结束后可能留下陈旧的 hover，所以
/// 视觉必须由「确有进行中的标签拖拽」门控。另外，把标签投到**源组的中心**等于
/// 把它并回自己那一组 —— 一次 no-op，所以那个组合不画高亮；源组的**边缘**要画
/// （那是真分屏：移动，或组内唯一标签时克隆）。
public nonisolated func paneDropHighlightZone(
    groupID: UUID,
    draggingTabID: UUID?,
    draggingSourceGroupID: UUID?,
    hover: PaneDragHoverTarget?
) -> PaneDropZone? {
    guard draggingTabID != nil else { return nil }
    guard let hover, hover.groupID == groupID else { return nil }
    if draggingSourceGroupID == groupID && hover.zone == .center { return nil }
    return hover.zone
}
