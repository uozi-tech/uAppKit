import Foundation
import Observation
import UPaneTree

// 「分屏里装标签」的 VSCode 编辑组模型。从 uTable 的 `UTableModel.swift`
// （`UTab` / `UPaneGroup` / `UTableShellModel` 的编辑组那一段）泛型化搬过来。
//
// 这个文件**不在 `#if os(macOS)` 里**：模型层不碰 AppKit，纯逻辑单测在任何平台
// 都能跑。三份模型（uTable 编辑组、uTerm 预览区、uTerm 终端区）的
// open/close/move/reorder/split/collapse 是本次改造最容易出错的地方，必须可测。

// MARK: - 标签

/// 一个标签。身份是 `id`，与载荷无关 —— 同一个文档（同一个 FileBuffer /
/// 同一个 QueryTab）可以有多个标签分别住在不同的组里。
///
/// `Payload` **无约束**。理由（设计文档 §1.2，逐条能从现有代码验证）：
///
/// 1. 三种载荷结构上毫无共同点：uTable 的 `UTab.Kind` 是值类型 enum，uTerm 预览区的
///    `FileBuffer` 是可被两个面板共享的 `@Observable` class，uTerm 终端区的
///    `PaneModel` 与会话 1:1 且不可共享。协议要覆盖这三者，方法集会退化成一堆
///    各自只实现一半的可选要求。
/// 2. 标题给不出来：终端标签的标题是服务器名，而 `PaneModel` 只有
///    `serverProfileID`，名字要靠视图层的 `@Query` 查。载荷自己无法回答
///    「你叫什么」—— 所以标题不是载荷的协议要求，而是调用方在视图层给的闭包
///    （见 `UPaneTabDescriptor`）。
/// 3. 模型要 `@Observable` 且被 SwiftUI 持有。带 associatedtype 的协议做不了
///    存在类型，`@State` / `@Bindable` / 环境注入全部要开箱；泛型 class 直接可用。
/// 4. 组件内部对载荷零操作：定位、重排、摘除、塌缩全部只用 `UPaneTab.id`；
///    唯一碰载荷的两处（去重开标签、垃圾回收）本来就已经是闭包/回调形态。
public struct UPaneTab<Payload>: Identifiable {
    public let id: UUID
    public var payload: Payload
    /// 覆盖 descriptor 派生出的标题（uTable 的 `UTab.customTitle`：已保存查询
    /// 用保存的名字，而不是「查询 N」；uTerm 终端标签用服务器名）。
    public var customTitle: String?
    /// 「预览（临时）标签」标记 —— VSCode 里单击打开的斜体标签。
    /// 模型保证**同组内至多一个** transient 标签（见 `openTab`）。
    public var isTransient: Bool

    public init(id: UUID = UUID(), payload: Payload,
                customTitle: String? = nil, isTransient: Bool = false) {
        self.id = id
        self.payload = payload
        self.customTitle = customTitle
        self.isTransient = isTransient
    }
}

extension UPaneTab: Equatable where Payload: Equatable {}
extension UPaneTab: Sendable where Payload: Sendable {}

/// 一个组：分屏树的叶子。自己的一条标签条 + 一个前台标签。
public struct UPaneGroup<Payload>: Identifiable {
    public let id: UUID
    public var tabs: [UPaneTab<Payload>]
    public var activeIndex: Int

    public init(id: UUID = UUID(), tabs: [UPaneTab<Payload>] = [], activeIndex: Int = 0) {
        self.id = id
        self.tabs = tabs
        self.activeIndex = activeIndex
    }

    public var activeTab: UPaneTab<Payload>? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }
}

extension UPaneGroup: Equatable where Payload: Equatable {}
extension UPaneGroup: Sendable where Payload: Sendable {}

/// 标签在**整个区域**里的活动态。三档缺一不可 —— 只有两档时用户看到几个同样
/// 高亮的标签，判断不出自己在哪一组，而「从侧栏打开」一律开在活动组。
public enum UPaneTabActivity: Sendable, Hashable {
    /// 前台标签，且它所在的组就是活动组：全区域唯一。
    case active
    /// 本组的前台标签，但焦点不在这一组。
    case frontUnfocused
    /// 同组里的后台标签。
    case inactive
}

// MARK: - 策略

public struct UPaneGroupsPolicy: Sendable, Equatable {
    /// 分屏**按钮 / 快捷键**的组数上限；拖拽分屏（`moveTab` 的边缘投放）不受限。
    /// 对齐 uTable 现状：`splitPane` 里 `guard groupCount < 3`，而 `moveTab` 无限制。
    /// nil = 不限。
    public var splitButtonMaxGroups: Int?
    /// 最后一个标签关掉后，组是否塌缩出树。false = 组留着显示空态。
    public var collapsesEmptyGroups: Bool
    /// 树只剩一个组时，那个组允许为空（显示空态占位）。
    ///
    /// 树必须有叶子，所以模型**永远**保留最后一个组；这个开关的作用是：为 false
    /// 时，一旦整个区域空掉就回调 `onAreaEmptied`，由 app 决定关窗还是补一个标签
    /// （uTerm 终端区的「最后窗格关标签 → 关窗口」走这条）。
    public var allowsLastGroupEmpty: Bool
    /// 切标签时是否交还隐藏编辑器的 AppKit first responder。
    /// 保活的面板被隐藏后**仍持有 first responder**，不放掉的话键盘会打进一个
    /// 看不见的编辑器 / 数据网格。见 `UPaneFocusRelease`。
    public var releasesHiddenEditorFocusOnTabSwitch: Bool
    /// 保活策略。
    ///
    /// uTable 保活的是 `NSTableView` / `NSTextView`，静止时不产生工作，所以
    /// `.allTabs` 免费。终端保活的是 SwiftTerm 视图 —— 隐藏但挂载的终端视图会不会
    /// 继续绘制 / 布局**尚未实测**，所以这里留成可配的三档而不是把「一直挂载」
    /// 写死：实测掉帧就退到 `.activeTabPerGroup`，那时切标签不再是零重建，但
    /// 代价可控（终端视图本来就复用会话持有的那个 NSView，重挂只是 attach/detach）。
    public var keepAlive: KeepAlive

    public enum KeepAlive: Sendable, Hashable {
        /// 所有组的所有标签都挂着，非前台的只是透明 —— 切标签是纯透明度翻转。
        case allTabs
        /// 每组只挂前台标签。切组零重建，切标签要重建。
        case activeTabPerGroup
        /// 只挂活动组的前台标签。最省，但切组也要重建。
        case activeGroupOnly
    }

    public init(splitButtonMaxGroups: Int? = nil,
                collapsesEmptyGroups: Bool = true,
                allowsLastGroupEmpty: Bool = true,
                releasesHiddenEditorFocusOnTabSwitch: Bool = true,
                keepAlive: KeepAlive = .allTabs) {
        self.splitButtonMaxGroups = splitButtonMaxGroups
        self.collapsesEmptyGroups = collapsesEmptyGroups
        self.allowsLastGroupEmpty = allowsLastGroupEmpty
        self.releasesHiddenEditorFocusOnTabSwitch = releasesHiddenEditorFocusOnTabSwitch
        self.keepAlive = keepAlive
    }
}

// MARK: - 模型

/// 一个区域的组树：`LayoutNode` 的叶子是组，组里是一排标签 + 一个前台标签，
/// 全区域只有一个活动组。
///
/// 泛型 `@Observable final class` 已实测可用（2026-09-01，Swift 6 语言模式）。
@MainActor
@Observable
public final class UPaneGroupsModel<Payload> {
    /// 布局树：叶子 = 组 id。树是值类型，所有操作返回新树。
    public private(set) var root: LayoutNode
    /// 组 id → 组。
    public private(set) var groups: [UUID: UPaneGroup<Payload>]
    /// 新标签开进哪一组、命令打向哪一组。存的 id 失效时回落到树的第一个叶子。
    public var activeGroupID: UUID?
    public var policy: UPaneGroupsPolicy

    // MARK: 钩子（都可选；默认 nil = 不做）

    /// 标签被移出模型后调用，`remaining` 是剩下的全部标签。
    /// uTable 的 `garbageCollect` 就是它：没人再引用那个 QueryTab 就关掉；
    /// uTerm 终端的 `pane.dispose()`（关会话 + 解 host-key relay）也是它。
    ///
    /// `@ObservationIgnored`：钩子是接线，不是状态，改它不该让任何视图失效。
    @ObservationIgnored public var onTabRemoved: ((_ removed: UPaneTab<Payload>, _ remaining: [UPaneTab<Payload>]) -> Void)?
    /// 克隆一个标签（组内唯一标签拖到本组边缘时）。返回 nil = 拒绝克隆，
    /// 该次拖拽退化为无操作。uTable 的 `.data` 标签克隆时铸新 `queryTabID`；
    /// 终端标签克隆 = 新开一条会话。
    @ObservationIgnored public var cloneTab: ((UPaneTab<Payload>) -> UPaneTab<Payload>?)?
    /// 分屏按钮 / 快捷键开新组时往新组里放什么。返回 nil = 开**空**组。
    ///
    /// uTable 返回 nil 是有意的：「克隆当前标签只会把同一张表（连同它的
    /// NSTableView 和一次数据加载）再开一份，既不是想要的内容，也是大表分屏
    /// 卡顿的一半来源。」终端区则该返回一个新会话标签 —— 空的终端组只能显示
    /// 一个「新建终端」按钮，多一次点击。
    @ObservationIgnored public var makeTabForNewGroup: (() -> UPaneTab<Payload>?)?
    /// `policy.allowsLastGroupEmpty == false` 时，整个区域空掉的回调。
    @ObservationIgnored public var onAreaEmptied: (() -> Void)?

    public init(policy: UPaneGroupsPolicy = .init()) {
        let group = UPaneGroup<Payload>()
        self.groups = [group.id: group]
        self.root = .leaf(paneID: group.id)
        self.activeGroupID = group.id
        self.policy = policy
    }

    // MARK: 查询

    public var groupCount: Int { root.leafCount }
    /// 树里所有组的 id，深度优先。
    public var groupIDs: [UUID] { root.leafIDs }

    public var activeGroup: UPaneGroup<Payload>? {
        if let id = activeGroupID, let g = groups[id] { return g }
        return root.firstLeafID.flatMap { groups[$0] }
    }
    public var activeTab: UPaneTab<Payload>? { activeGroup?.activeTab }
    public var allTabs: [UPaneTab<Payload>] { root.leafIDs.flatMap { groups[$0]?.tabs ?? [] } }
    /// 整个区域一个标签都没有（可能仍有一个或多个空组）。
    public var isEmpty: Bool { root.leafIDs.allSatisfy { groups[$0]?.tabs.isEmpty ?? true } }

    /// 标签在整个区域里的活动态。VSCode 语义：每个组各有自己的前台标签，但
    /// 同时只有一个是「当前」的 —— 活动组的那一个；别的组的前台标签退到
    /// `.frontUnfocused`。
    public func tabActivity(groupID: UUID, index: Int) -> UPaneTabActivity {
        guard groups[groupID]?.activeIndex == index else { return .inactive }
        return (activeGroupID ?? root.firstLeafID) == groupID ? .active : .frontUnfocused
    }

    /// 标签在树中的位置（组 id + 组内下标）。
    public func locateTab(_ tabID: UUID) -> (groupID: UUID, index: Int)? {
        for gid in root.leafIDs {
            if let idx = groups[gid]?.tabs.firstIndex(where: { $0.id == tabID }) {
                return (gid, idx)
            }
        }
        return nil
    }

    public func tab(_ tabID: UUID) -> UPaneTab<Payload>? {
        guard let at = locateTab(tabID) else { return nil }
        return groups[at.groupID]?.tabs[at.index]
    }

    // MARK: 开 / 切 / 关

    /// 在活动组（或指定组）里开一个标签。
    ///
    /// - `dedupe` 命中**本组**已存在的标签时只切过去，不新开。只在本组里查是
    ///   有意的：同一张表在两个组里各开一个标签，两边各自拥有自己的文档。
    /// - `asTransient` 时顶替同组里已有的 transient 标签（VSCode 预览标签语义），
    ///   由此保证同组至多一个 transient。
    ///
    /// 返回最终活动的那个标签 id（去重命中时是既有标签的 id）。
    @discardableResult
    public func openTab(_ make: () -> UPaneTab<Payload>,
                        dedupe: ((UPaneTab<Payload>) -> Bool)? = nil,
                        asTransient: Bool = false,
                        in groupID: UUID? = nil) -> UUID {
        let gid = resolveGroupID(groupID)
        // 本地拷贝再写回 —— `groups[gid]?.x = f(groups[gid])` 的可选链赋值会先开
        // 写访问再求值右侧，触发独占性冲突（Fatal access conflict）。
        guard var group = groups[gid] else {
            // 树的每个叶子都该有组；真缺了就地补上，别让调用方拿不到 id。
            let tab = make()
            groups[gid] = UPaneGroup<Payload>(id: gid, tabs: [tab], activeIndex: 0)
            activeGroupID = gid
            return tab.id
        }

        if let dedupe, let hit = group.tabs.firstIndex(where: dedupe) {
            group.activeIndex = hit
            // 已是预览标签、这次是「正式打开」→ 顺手转正。
            if !asTransient, group.tabs[hit].isTransient { group.tabs[hit].isTransient = false }
            groups[gid] = group
            activeGroupID = gid
            return group.tabs[hit].id
        }

        var tab = make()
        tab.isTransient = asTransient
        if asTransient, let slot = group.tabs.firstIndex(where: { $0.isTransient }) {
            group.tabs[slot] = tab
            group.activeIndex = slot
        } else {
            group.tabs.append(tab)
            group.activeIndex = group.tabs.count - 1
        }
        groups[gid] = group
        activeGroupID = gid
        return tab.id
    }

    public func activateTab(groupID: UUID, index: Int) {
        guard let group = groups[groupID], group.tabs.indices.contains(index) else { return }
        // 跳过 no-op 写：每次 @Observable 变更都可能同步 flush 一次窗口布局
        // （ObservationCenter.invalidate → flushTransactions），一次点击冗余重写
        // 两三个属性就付两三次布局。
        if group.activeIndex != index { groups[groupID]?.activeIndex = index }
        if activeGroupID != groupID { activeGroupID = groupID }
    }

    /// 预览标签转正（双击 / 编辑 / 保存）。
    public func promoteTransient(_ tabID: UUID) {
        guard let at = locateTab(tabID),
              groups[at.groupID]?.tabs[at.index].isTransient == true else { return }
        groups[at.groupID]?.tabs[at.index].isTransient = false
    }

    /// 关一个标签。组丢掉最后一个标签后从分屏树里塌缩（除非它是唯一的组 ——
    /// 那个留着显示空态占位）。
    ///
    /// 注意这是**真的关**。UI 上的 × 与 ⌘W 走的是 `UPaneGroupArea` 的
    /// `onRequestClose`，由 app 决定要不要先弹脏文件确认。
    public func closeTab(groupID: UUID, index: Int) {
        guard var group = groups[groupID], group.tabs.indices.contains(index) else { return }
        let closed = group.tabs.remove(at: index)
        group.activeIndex = Self.adjustedActiveIndex(group.activeIndex, removedAt: index,
                                                     newCount: group.tabs.count)
        groups[groupID] = group

        collapseIfEmpty(groupID)
        onTabRemoved?(closed, allTabs)
        if !policy.allowsLastGroupEmpty, isEmpty { onAreaEmptied?() }
    }

    /// 关活动组的前台标签（⌘W）。返回 false = 没东西可关（调用方回落到关窗口）。
    @discardableResult
    public func closeActiveTab() -> Bool {
        guard let group = activeGroup else { return false }
        // 分屏出来的空组没有标签可关，⌘W 直接把这个组收掉（否则只能靠拖标签
        // 进来再关，等于没有出路）。
        guard group.activeTab != nil else { return closeEmptyGroup(groupID: group.id) }
        closeTab(groupID: group.id, index: group.activeIndex)
        return true
    }

    /// 收掉一个空组（分屏按钮开出来的空白组）：兄弟子树上提。整棵树只剩这一个组
    /// 时不动 —— 那是区域的空态占位，不是多余的分屏。
    @discardableResult
    public func closeEmptyGroup(groupID: UUID) -> Bool {
        guard groups[groupID]?.tabs.isEmpty == true, !root.isSingleLeaf else { return false }
        collapseIfEmpty(groupID, force: true)
        return groups[groupID] == nil
    }

    /// 批量关闭（uTable 删表后收拾标签；uTerm 预览区的「关闭其他 / 右侧 / 全部」）。
    ///
    /// 每次 `closeTab` 都会改组内下标（并可能塌缩整组），所以定位一个、关一个、
    /// 重新定位，而不是先收集下标再批量删。
    public func closeTabs(where predicate: (UPaneTab<Payload>) -> Bool) {
        while true {
            var hit: (groupID: UUID, index: Int)?
            for gid in root.leafIDs {
                guard let group = groups[gid] else { continue }
                if let idx = group.tabs.firstIndex(where: predicate) {
                    hit = (gid, idx)
                    break
                }
            }
            guard let hit else { return }
            closeTab(groupID: hit.groupID, index: hit.index)
        }
    }

    // MARK: 布局

    /// 分屏按钮 / 快捷键：在 `groupID` 的一侧开一个新组，内容由
    /// `makeTabForNewGroup` 决定（nil = 空组）。受 `policy.splitButtonMaxGroups` 限制。
    public func splitGroup(_ groupID: UUID, direction: SplitDirection = .horizontal,
                           newLeafFirst: Bool = false) {
        if let cap = policy.splitButtonMaxGroups, groupCount >= cap { return }
        guard groups[groupID] != nil else { return }
        var group = UPaneGroup<Payload>()
        if let seed = makeTabForNewGroup?() {
            group.tabs = [seed]
            group.activeIndex = 0
        }
        groups[group.id] = group
        root = root.splitting(paneID: groupID, direction: direction,
                              newPaneID: group.id, splitID: UUID(),
                              newLeafFirst: newLeafFirst)
        activeGroupID = group.id
    }

    public func focusGroup(_ groupID: UUID) {
        guard groups[groupID] != nil else { return }
        if activeGroupID != groupID { activeGroupID = groupID }
    }

    public func setFraction(_ fraction: Double, splitID: UUID) {
        root = root.settingFraction(fraction, splitID: splitID)
    }

    // MARK: 拖拽

    /// 把标签投放到某组的投放区：`center` = 并入该组（追加到末尾）；
    /// 边缘 = 在该组对应侧新建组。源组因此空掉时从树中塌缩。
    /// 组里唯一的标签拖到**本组**边缘时改走 `cloneTab`（真移动会让源组塌缩，
    /// 分完还是一个组，等于没分）。
    public func moveTab(_ tabID: UUID, toGroup targetID: UUID, zone: PaneDropZone) {
        guard groups[targetID] != nil, let src = locateTab(tabID) else { return }

        if zone == .center {
            guard src.groupID != targetID else { return }
            guard let tab = removeForMove(tabID, from: src), var target = groups[targetID] else { return }
            target.tabs.append(tab)
            target.activeIndex = target.tabs.count - 1
            groups[targetID] = target
            activeGroupID = targetID
        } else {
            let direction: SplitDirection
            let newLeafFirst: Bool
            switch zone {
            case .leading:  direction = .horizontal; newLeafFirst = true
            case .trailing: direction = .horizontal; newLeafFirst = false
            case .top:      direction = .vertical;   newLeafFirst = true
            case .bottom:   direction = .vertical;   newLeafFirst = false
            case .center:   return
            }
            var group = UPaneGroup<Payload>()
            if src.groupID == targetID, groups[src.groupID]?.tabs.count == 1 {
                guard let srcTab = groups[src.groupID]?.tabs.first,
                      let cloned = cloneTab?(srcTab) else { return }
                group.tabs = [cloned]
            } else {
                guard let tab = removeForMove(tabID, from: src) else { return }
                group.tabs = [tab]
            }
            groups[group.id] = group
            root = root.splitting(paneID: targetID, direction: direction,
                                  newPaneID: group.id, splitID: UUID(),
                                  newLeafFirst: newLeafFirst)
            activeGroupID = group.id
        }
    }

    /// 把标签插到目标标签的槽位（同组重排 / 跨组移动都走这条）。
    public func reorderTab(_ tabID: UUID, before targetTabID: UUID) {
        guard tabID != targetTabID,
              let src = locateTab(tabID),
              let tab = groups[src.groupID]?.tabs[src.index],
              let dst = locateTab(targetTabID) else { return }

        // 同组内从前往后拖时，摘除会把目标槽位整体前移一格。
        var insertAt = dst.index
        if src.groupID == dst.groupID, src.index < dst.index { insertAt -= 1 }

        removeAdjustingActive(at: src)
        groups[dst.groupID]?.tabs.insert(tab, at: insertAt)
        groups[dst.groupID]?.activeIndex = insertAt
        activeGroupID = dst.groupID
        if src.groupID != dst.groupID { collapseIfEmpty(src.groupID) }
    }

    // MARK: 整体重置

    /// 重置成单个空组（uTable 的 `resetForLaunch` / `selectDatabase`）。
    /// 不走 `onTabRemoved` —— 重置是换作用域，不是逐个关标签。
    public func reset() {
        let group = UPaneGroup<Payload>()
        groups = [group.id: group]
        root = .leaf(paneID: group.id)
        activeGroupID = group.id
    }

    // MARK: 内部

    private func resolveGroupID(_ requested: UUID?) -> UUID {
        if let requested, groups[requested] != nil { return requested }
        if let id = activeGroupID, groups[id] != nil { return id }
        if let first = root.firstLeafID { return first }
        // 树永远有叶子；真到这一步就重建一个，别崩。
        let group = UPaneGroup<Payload>()
        groups[group.id] = group
        root = .leaf(paneID: group.id)
        activeGroupID = group.id
        return group.id
    }

    /// 摘除一个标签后的 activeIndex 修正。
    static func adjustedActiveIndex(_ current: Int, removedAt index: Int, newCount: Int) -> Int {
        var value = current
        if index < value {
            value -= 1
        } else if index == value {
            value = min(value, newCount - 1)
        }
        return max(0, value)
    }

    /// 拖拽移动的摘除步骤：从源组移出标签并修正 activeIndex；源组空掉先塌缩
    /// （目标 leaf 保留在树中，后续 splitting 才找得到锚点）。
    private func removeForMove(_ tabID: UUID, from src: (groupID: UUID, index: Int)) -> UPaneTab<Payload>? {
        guard let tab = groups[src.groupID]?.tabs[src.index], tab.id == tabID else { return nil }
        removeAdjustingActive(at: src)
        collapseIfEmpty(src.groupID)
        return tab
    }

    private func removeAdjustingActive(at src: (groupID: UUID, index: Int)) {
        guard var group = groups[src.groupID], group.tabs.indices.contains(src.index) else { return }
        group.tabs.remove(at: src.index)
        group.activeIndex = Self.adjustedActiveIndex(group.activeIndex, removedAt: src.index,
                                                     newCount: group.tabs.count)
        groups[src.groupID] = group
    }

    /// 空组塌缩：兄弟子树上提；最后一个组保留（空态占位）。
    private func collapseIfEmpty(_ groupID: UUID, force: Bool = false) {
        guard force || policy.collapsesEmptyGroups else { return fixActiveGroup() }
        guard groups[groupID]?.tabs.isEmpty == true, !root.isSingleLeaf,
              let newRoot = root.removingLeaf(paneID: groupID) else { return fixActiveGroup() }
        root = newRoot
        groups.removeValue(forKey: groupID)
        fixActiveGroup()
    }

    private func fixActiveGroup() {
        if activeGroupID == nil || groups[activeGroupID!] == nil {
            activeGroupID = root.firstLeafID
        }
    }

    // MARK: 恢复用的整树写入（`restore` 专用）

    func replaceLayout(root newRoot: LayoutNode,
                       groups newGroups: [UUID: UPaneGroup<Payload>],
                       activeGroupID newActive: UUID?) {
        root = newRoot
        groups = newGroups
        activeGroupID = newActive ?? newRoot.firstLeafID
    }
}
