import Foundation
import UPaneTree

/// 组树快照。叶子记「这个组有哪些标签」，标签的载荷由调用方降维成 `P`。
///
/// **不存 UUID。** 叶子是 `groups` 数组的下标，恢复时组 id 与分屏节点 id 全部
/// 重新铸造 —— 快照里留着的 UUID 只会诱使人拿它当身份用，而跨进程它什么都不是。
public struct UPaneGroupsSnapshot<P: Codable & Sendable>: Codable, Sendable {
    public struct Group: Codable, Sendable {
        public var tabs: [P]
        public var activeIndex: Int

        public init(tabs: [P], activeIndex: Int) {
            self.tabs = tabs
            self.activeIndex = activeIndex
        }
    }

    public indirect enum Node: Codable, Sendable {
        case leaf(groupIndex: Int)
        case split(direction: SplitDirection, fraction: Double, first: Node, second: Node)
    }

    public var root: Node
    public var groups: [Group]
    public var activeGroupIndex: Int?

    public init(root: Node, groups: [Group], activeGroupIndex: Int?) {
        self.root = root
        self.groups = groups
        self.activeGroupIndex = activeGroupIndex
    }

    /// 一个组都不剩时的快照：一个空组。`snapshot` / `restore` 两侧共用这条兜底。
    public static var empty: UPaneGroupsSnapshot<P> {
        UPaneGroupsSnapshot(root: .leaf(groupIndex: 0),
                            groups: [Group(tabs: [], activeIndex: 0)],
                            activeGroupIndex: 0)
    }
}

// MARK: - Equatable

/// 条件遵循 `Equatable`，让消费方能直接 `.onChange(of:)` 整个快照。
///
/// 没有它的时候，uTerm 把快照塞进自己的 `WorkspaceSnapshot` 就合成不出 `==`，只能
/// 手写一份逐字段比较 —— 而它的自动保存正是 `.onChange(of: autosaveStructureSnapshot())`，
/// 于是「谁给快照加了字段却忘了同步手写的 `==`」会变成**静默不再写盘**：比如只拖分隔条
/// 改 `fraction`，除了组树没有别的字段会动，漏掉就等于那类改动永远存不下来。
/// 合成出来的 `==` 不会漏字段，加字段自动跟上。
extension UPaneGroupsSnapshot: Equatable where P: Equatable {}
extension UPaneGroupsSnapshot.Group: Equatable where P: Equatable {}
extension UPaneGroupsSnapshot.Node: Equatable where P: Equatable {}

extension UPaneGroupsModel {
    /// 降维成可存盘的快照。
    ///
    /// 防御性做法照抄 uTerm 现有快照（`WorkspaceModel.nodeSnapshot`）：
    /// - `encode` 返回 nil 的标签直接丢掉（uTerm 里文件窗格不进终端快照）；
    ///   一个**原本有标签**的组被丢光则整个组丢掉；一个 split 的两侧都丢光则整个
    ///   split 丢掉，只剩一侧就把那一侧上提。
    /// - **绝不给缺失项回落一个随机 UUID。** 旧代码 `guard let pane = panes[id]`
    ///   失败时回落 `UUID()`，把一个不存在的 `serverProfileID` 写进快照，
    ///   「下次打开工作区恢复出的终端永远显示『连接失败 / 服务器配置已被删除』，
    ///   且没有可用的重试入口」。
    ///
    /// 原本就是空组（用户分屏开出来、还没往里放东西的那种）予以保留 —— 它不是
    /// 「被丢光的组」，是用户有意留着的布局。
    public func snapshot<P: Codable & Sendable>(
        _ encode: (UPaneTab<Payload>) -> P?
    ) -> UPaneGroupsSnapshot<P> {
        typealias Snap = UPaneGroupsSnapshot<P>

        var out: [Snap.Group] = []
        var indexByGroupID: [UUID: Int] = [:]

        for gid in root.leafIDs {
            guard let group = groups[gid] else { continue }
            var kept: [P] = []
            var keptOriginalIndex: [Int] = []
            for (i, tab) in group.tabs.enumerated() {
                guard let encoded = encode(tab) else { continue }
                kept.append(encoded)
                keptOriginalIndex.append(i)
            }
            // 原本有标签、这次全被丢掉 → 整个组不进快照。
            if kept.isEmpty && !group.tabs.isEmpty { continue }

            // 前台标签若被丢掉，退到它前面最近的一个幸存标签。
            let active: Int
            if let exact = keptOriginalIndex.firstIndex(of: group.activeIndex) {
                active = exact
            } else if let before = keptOriginalIndex.lastIndex(where: { $0 < group.activeIndex }) {
                active = before
            } else {
                active = 0
            }
            indexByGroupID[gid] = out.count
            out.append(Snap.Group(tabs: kept, activeIndex: active))
        }

        func prune(_ node: LayoutNode) -> Snap.Node? {
            switch node {
            case .leaf(let id):
                return indexByGroupID[id].map { Snap.Node.leaf(groupIndex: $0) }
            case .split(let s):
                let first = prune(s.first)
                let second = prune(s.second)
                if let first, let second {
                    return .split(direction: s.direction, fraction: s.fraction,
                                  first: first, second: second)
                }
                return first ?? second
            }
        }

        guard let prunedRoot = prune(root) else { return .empty }
        return Snap(root: prunedRoot,
                    groups: out,
                    activeGroupIndex: activeGroupID.flatMap { indexByGroupID[$0] })
    }

    /// 从快照重建。`make` 返回 nil 的标签丢掉（uTerm 的
    /// `pruningUnknownServers` 白名单剪枝就是它），丢光的组丢掉，丢光的 split
    /// 只剩一侧就上提；整棵树都没剩下时回落到一个空组。
    ///
    /// 组 id 与分屏节点 id 全部重新铸造。
    public func restore<P: Codable & Sendable>(
        _ snapshot: UPaneGroupsSnapshot<P>,
        make: (P) -> UPaneTab<Payload>?
    ) {
        typealias Snap = UPaneGroupsSnapshot<P>

        var rebuilt: [UUID: UPaneGroup<Payload>] = [:]
        var idByIndex: [Int: UUID] = [:]

        for (i, snapGroup) in snapshot.groups.enumerated() {
            var tabs: [UPaneTab<Payload>] = []
            var keptOriginalIndex: [Int] = []
            for (j, encoded) in snapGroup.tabs.enumerated() {
                guard let tab = make(encoded) else { continue }
                tabs.append(tab)
                keptOriginalIndex.append(j)
            }
            if tabs.isEmpty && !snapGroup.tabs.isEmpty { continue }

            let active: Int
            if let exact = keptOriginalIndex.firstIndex(of: snapGroup.activeIndex) {
                active = exact
            } else if let before = keptOriginalIndex.lastIndex(where: { $0 < snapGroup.activeIndex }) {
                active = before
            } else {
                active = 0
            }
            let group = UPaneGroup<Payload>(tabs: tabs, activeIndex: active)
            rebuilt[group.id] = group
            idByIndex[i] = group.id
        }

        func build(_ node: Snap.Node) -> LayoutNode? {
            switch node {
            case .leaf(let gi):
                return idByIndex[gi].map { LayoutNode.leaf(paneID: $0) }
            case .split(let direction, let fraction, let first, let second):
                let lhs = build(first)
                let rhs = build(second)
                if let lhs, let rhs {
                    return .split(SplitNode(id: UUID(), direction: direction, fraction: fraction,
                                            first: lhs, second: rhs))
                }
                return lhs ?? rhs
            }
        }

        guard let newRoot = build(snapshot.root) else {
            reset()
            return
        }
        // 树里没引用到的组不留（快照里多余的条目）。
        let live = Set(newRoot.leafIDs)
        rebuilt = rebuilt.filter { live.contains($0.key) }
        let active = snapshot.activeGroupIndex.flatMap { idByIndex[$0] }
        replaceLayout(root: newRoot, groups: rebuilt,
                      activeGroupID: live.contains(active ?? UUID()) ? active : newRoot.firstLeafID)
    }
}
