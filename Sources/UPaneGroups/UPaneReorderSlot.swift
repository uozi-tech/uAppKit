import Foundation

// 模型层：不放在 `#if os(macOS)` 里。`UPaneGroupsModel.moveTab(_:to:inGroup:)` 用到它，
// 模型要在 iOS 上也能编（以前它和拖动视图一起被 macOS 条件包住，iOS 构建因此找不到这个类型）。

/// 拖动排序时被拖的标签落在哪：插在某个标签前面，或排到组末尾。
public enum UPaneReorderSlot: Equatable, Sendable {
    case before(UUID)
    case end
}
