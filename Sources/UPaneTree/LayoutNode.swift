import Foundation

// uTable 与 uTerm 各自维护过一份逐字相同的分屏树。两边只有文档措辞不同：
// uTerm 的叶子是终端窗格，uTable 的叶子是「编辑组」（带标签条的 group）。
// 树逻辑没有任何差别，于是合并到这里，用中性的「窗格」称呼叶子。

/// 分屏方向。
public nonisolated enum SplitDirection: String, Codable, Sendable, Equatable {
    case horizontal   // 左右两个子节点
    case vertical     // 上下两个子节点
}

/// 一个分屏节点。`fraction` 是首个子节点的占比（0–1）。
public nonisolated struct SplitNode: Equatable, Sendable {
    public let id: UUID
    public var direction: SplitDirection
    public var fraction: Double
    public var first: LayoutNode
    public var second: LayoutNode

    public init(id: UUID, direction: SplitDirection, fraction: Double,
                first: LayoutNode, second: LayoutNode) {
        self.id = id
        self.direction = direction
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

/// 递归二叉布局树。值类型 —— 树操作是纯函数，返回新树。
///
/// 叶子由调用方解释：uTerm 里是一个终端窗格，uTable 里是一个编辑组。
public nonisolated indirect enum LayoutNode: Equatable, Sendable {
    case leaf(paneID: UUID)
    case split(SplitNode)

    /// 树中所有窗格 id。
    public nonisolated var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let s): return s.first.leafIDs + s.second.leafIDs
        }
    }

    /// 深度优先的第一个窗格 id。
    public nonisolated var firstLeafID: UUID? { leafIDs.first }

    /// 树中窗格数量。递归累加，不分配数组，比 `leafIDs.count` 轻。
    public nonisolated var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(let s): return s.first.leafCount + s.second.leafCount
        }
    }

    /// 整棵树只有一个窗格 —— 等价 `leafCount == 1`，但避免遍历。
    public nonisolated var isSingleLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    /// 把 `.leaf(paneID)` 替换为一个 `.split`，子节点为原 leaf 与新 leaf。
    /// `newLeafFirst` 为 true 时新 leaf 放 `first`，否则放 `second`。
    public nonisolated func splitting(paneID: UUID, direction: SplitDirection,
                                      newPaneID: UUID, splitID: UUID, fraction: Double = 0.5,
                                      newLeafFirst: Bool = false) -> LayoutNode {
        switch self {
        case .leaf(let id):
            guard id == paneID else { return self }
            let original = LayoutNode.leaf(paneID: id)
            let added = LayoutNode.leaf(paneID: newPaneID)
            return .split(SplitNode(
                id: splitID, direction: direction, fraction: fraction,
                first: newLeafFirst ? added : original,
                second: newLeafFirst ? original : added))
        case .split(var s):
            s.first = s.first.splitting(paneID: paneID, direction: direction,
                                        newPaneID: newPaneID, splitID: splitID,
                                        fraction: fraction, newLeafFirst: newLeafFirst)
            s.second = s.second.splitting(paneID: paneID, direction: direction,
                                          newPaneID: newPaneID, splitID: splitID,
                                          fraction: fraction, newLeafFirst: newLeafFirst)
            return .split(s)
        }
    }

    /// 交换两个 paneID 在各自 `.leaf` 中的位置。树结构与所有 `fraction` 保留。
    /// 任一 id 不在树中时整体无操作 —— 否则会把在场的那个 leaf 改写成
    /// 不存在的幽灵 id，丢掉真实窗格。
    public nonisolated func swapping(_ a: UUID, _ b: UUID) -> LayoutNode {
        guard a != b else { return self }
        let ids = leafIDs
        guard ids.contains(a), ids.contains(b) else { return self }
        return swappingKnown(a, b)
    }

    /// `swapping` 的递归核心 —— 调用前已确保 `a`、`b` 均在树中。
    private nonisolated func swappingKnown(_ a: UUID, _ b: UUID) -> LayoutNode {
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(paneID: b) }
            if id == b { return .leaf(paneID: a) }
            return self
        case .split(var s):
            s.first = s.first.swappingKnown(a, b)
            s.second = s.second.swappingKnown(a, b)
            return .split(s)
        }
    }

    /// 移除某窗格。其兄弟子树上提替换父 `.split`。
    /// 若移除的是整棵树唯一的 leaf，返回 nil —— 调用方自己决定这意味着什么
    /// （uTerm 关掉标签，uTable 留一个空组占位）。
    public nonisolated func removingLeaf(paneID: UUID) -> LayoutNode? {
        switch self {
        case .leaf(let id):
            return id == paneID ? nil : self
        case .split(var s):
            // 先判断目标在哪一侧子树，只递归含目标的那一侧。
            // 不能用 `if let = removingLeaf(...)` 直接试 —— 不含目标的子树
            // 也会返回非 nil 的自身，那样会误入错误分支、永不深入真正含
            // 目标的子树。
            if s.first.leafIDs.contains(paneID) {
                guard let newFirst = s.first.removingLeaf(paneID: paneID) else {
                    return s.second   // first 子树整体塌缩 → 兄弟上提
                }
                s.first = newFirst
                return .split(s)
            }
            if s.second.leafIDs.contains(paneID) {
                guard let newSecond = s.second.removingLeaf(paneID: paneID) else {
                    return s.first
                }
                s.second = newSecond
                return .split(s)
            }
            return .split(s)   // 树中无此窗格
        }
    }

    /// 设置某 `splitID` 的分隔比例。
    public nonisolated func settingFraction(_ fraction: Double, splitID: UUID) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case .split(var s):
            if s.id == splitID {
                s.fraction = fraction
            } else {
                s.first = s.first.settingFraction(fraction, splitID: splitID)
                s.second = s.second.settingFraction(fraction, splitID: splitID)
            }
            return .split(s)
        }
    }
}
