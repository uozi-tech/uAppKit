# 编辑组（Pane Groups）通用组件设计

把 uTable 的「分屏里装标签」（VSCode 编辑组模型）抽成 uAppKit 的共享 target，
并用它改造 uTerm 的预览区与终端区。

本文基于 2026-09-01 两个仓库工作树里的实际代码写成。所有性能结论、坑位与数字都
出自源码注释或代码本身，出处逐条给出。拿不准的地方明确标注「未确认」。

底层分屏二叉树 `LayoutNode` 已由另一条工作线并入
`uAppKit/Sources/UPaneTree`（`LayoutNode.swift` + `LayoutFrames.swift`，
含 uTable 的 `frames(in:)` 摊平几何与 uTerm 的 `swapping`）。本文**假定它存在
且可用**，只设计它之上的那一层。

---

## 0. 术语

本文统一用这套词，避免两边的历史命名互相打架：

| 本文用词 | uTable 现名 | uTerm 现名 |
|---|---|---|
| **组**（group） | `UPaneGroup`，树的叶子 | 终端区：无对应物（叶子就是窗格）；预览区：`FilePreviewPanel` |
| **标签**（tab） | `UTab` | 终端区：`TabModel`（窗口级，不在树里）；预览区：`FileBuffer`（全局一条标签条） |
| **载荷**（payload） | `UTab.Kind` | 终端区：`PaneModel`；预览区：`FileBuffer` |
| **活动组** | `activePaneID` | 终端区：`TabModel.focusedPaneID`（每标签一个）；预览区：`focusedPanelID` |

「VSCode 模型」= 树的叶子是组，组内有一排标签 + 一个前台标签；全窗口只有一棵树、
只有一个活动组。

---

## 1. 通用组件的 API

### 1.1 落点：新 target `UPaneGroups`

```swift
// Package.swift
.target(name: "UPaneGroups", dependencies: ["UPaneTree", "UDesignKit", "UAppKitBridge"]),
.testTarget(name: "UPaneGroupsTests", dependencies: ["UPaneGroups"]),
```

macOS 专用（拖拽走 AppKit、按下激活走 `UAppKitBridge`），整份源码用
`#if os(macOS)` 包住 —— 与 `UAppKitBridge/PointerDownProbe.swift` 同款做法，
即使被拉进 iOS 构建图也只是空目标。

模型层（`UPaneGroupsModel` 及其操作）本身不依赖 AppKit，可以单独放一个
`#if` 之外的文件，让纯逻辑单测在任何平台跑。**建议这么切**：三份模型的
open/close/move/reorder/split/collapse 逻辑是本次改造最容易出错的地方，
必须有单测。

### 1.2 泛型参数：`Payload`，无约束；不用协议关联类型

**结论：用泛型，不用 protocol + associatedtype。**

理由（都能从现有代码验证）：

1. **三种载荷结构上毫无共同点。**
   - uTable：`UTab.Kind` 是值类型 enum，四个 case，其中 `.data` / `.sql` 携带
     `queryTabID: UUID` 指向 `QueryTabState` 里的文档；
   - uTerm 预览区：`FileBuffer` 是 `@MainActor @Observable final class`，一个
     buffer 可以同时被两个面板引用；
   - uTerm 终端区：`PaneModel`（`serverProfileID` + `TerminalSession` +
     `hostKeyRelay`），会话与窗格 1:1，不可共享。

   协议要覆盖这三者，方法集会退化成一堆各自只实现一半的可选要求。

2. **标题给不出来。** 终端标签的标题是服务器名，而 `PaneModel` 只有
   `serverProfileID`；名字要靠 `PaneView` 里的 `@Query private var profiles`
   查（`PaneView.swift:56-58`）。载荷自己**无法**回答「你叫什么」。所以标题
   不能是载荷的协议要求，必须由调用方在视图层提供闭包。

3. **模型要 `@Observable` 且被 SwiftUI 持有。** 带 associatedtype 的协议做不了
   存在类型，`@State`/`@Bindable`/环境注入全部要开箱。泛型 class 直接可用。

4. **组件内部对载荷零操作。** 查一遍 uTable 的模型代码：`locateTab`、
   `reorderTab`、`removeAdjustingActive`、`collapseIfEmpty` 全部只用
   `UTab.id`；唯一碰 `kind` 的两处 —— 去重开标签（`openObjectTab(matching:)`）
   和垃圾回收（`garbageCollect`）—— **都已经是闭包/回调形态**。所以
   `Payload` 可以彻底无约束。

### 1.3 值类型

```swift
import UPaneTree

/// 一个标签。身份是 `id`，与载荷无关 —— 同一个文档（同一个 FileBuffer /
/// 同一个 QueryTab）可以有多个标签分别住在不同的组里。
public struct UPaneTab<Payload>: Identifiable {
    public let id: UUID
    public var payload: Payload
    /// 覆盖 descriptor 派生出的标题（uTable 的 `UTab.customTitle`：已保存查询
    /// 用保存的名字，而不是「查询 N」）。
    public var customTitle: String?
    /// 「预览（临时）标签」标记 —— VSCode 里单击打开的斜体标签。
    /// 组件保证**同组内至多一个** transient 标签（见 §1.7 `openTab`）。
    public var isTransient: Bool

    public init(id: UUID = UUID(), payload: Payload,
                customTitle: String? = nil, isTransient: Bool = false)
}

/// 一个组：树的叶子。
public struct UPaneGroup<Payload>: Identifiable {
    public let id: UUID
    public var tabs: [UPaneTab<Payload>]
    public var activeIndex: Int
    public var activeTab: UPaneTab<Payload>? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
}

/// 标签在**整个区域**里的活动态。照抄 uTable `UTabActivity`
/// （`UTableModel.swift:112-119`），三档缺一不可 —— 只有两档时用户看到几个
/// 同样高亮的标签，判断不出自己在哪一组，而「从侧栏打开」一律开在活动组。
public enum UPaneTabActivity {
    case active          // 前台标签，且它所在的组就是活动组：全区域唯一
    case frontUnfocused  // 本组前台标签，但焦点不在这一组
    case inactive        // 同组里的后台标签
}

/// 5 投放区。归类函数与 uTable / uTerm 现有的 `paneDropZone(at:in:)` 逐字相同
/// （中心 50%×50% → center，否则归最近边）。
public enum PaneDropZone: String, Sendable, Hashable {
    case center, top, bottom, leading, trailing
}
public func paneDropZone(at location: CGPoint, in bounds: CGRect) -> PaneDropZone?
```

`PaneDropZone` 与归类函数放 `UPaneGroups` 而不是 `UPaneTree`：`PaneDropHighlight`
要用 `UD.accent`，把 UDesignKit 依赖压给纯值类型的 `UPaneTree` 不划算。

### 1.4 标题 / 图标 / 脏标记：descriptor 闭包，在 chip 内部求值

```swift
public enum UPaneTabIcon {
    case glyph(UIconGlyph)      // uTable 走这条（UIcon 自绘图标）
    case system(String)         // uTerm 现在全是 SF Symbols
    case none
}

/// 一个标签在标签条上怎么画。由调用方按标签算出。
public struct UPaneTabDescriptor {
    public var title: String
    public var icon: UPaneTabIcon
    /// 图标在 `.active` 态下的着色。nil = 用 UD.accent。
    public var accentColor: Color?
    /// 脏标记小圆点（uTerm 预览标签）。
    public var isDirty: Bool
    /// 悬停提示；nil 则用 title。
    public var help: String?
}
```

**求值位置是这个 API 唯一重要的设计点：descriptor 闭包必须在每个 chip 自己的
`body` 里调用，不能在标签条的 body 里先算成数组。**

原因是 uTable 已经踩过的那条：`MountedPane.document` 的注释
（`UTablePaneArea.swift:104-119`）写明，让每个面板自己去扫
`env.queryTabState.tabs` 会让所有面板都挂在那个 `@Observable` 数组上，
「实测每挂一个数据网格就多 60ms，开/关任意一个标签都要付」。同一个道理：
如果标签条先 `model.tabs.map(descriptor)`，那么 uTerm 预览标签里的
`buffer.isDirty`（`FileBuffer` 的 `@Observable` 属性）一变，**整条标签条**
连同所有 chip 一起重算；放进 chip 内求值，则只有那一个 chip 失效。

### 1.5 模型

```swift
@MainActor
@Observable
public final class UPaneGroupsModel<Payload> {
    public private(set) var root: LayoutNode
    public private(set) var groups: [UUID: UPaneGroup<Payload>]
    /// 新标签开进哪一组、命令打向哪一组。存的 id 失效时回落到树的第一个叶子。
    public var activeGroupID: UUID?

    public var groupCount: Int { root.leafCount }
    public var activeGroup: UPaneGroup<Payload>?
    public var activeTab: UPaneTab<Payload>?
    public var allTabs: [UPaneTab<Payload>] { root.leafIDs.flatMap { groups[$0]?.tabs ?? [] } }

    public init(policy: UPaneGroupsPolicy = .init())
    public var policy: UPaneGroupsPolicy

    // — 钩子（都可选；默认 nil = 不做）—
    /// 标签被移出模型后调用，`remaining` 是剩下的全部标签。
    /// uTable 的 `garbageCollect` 就是它：没人再引用那个 QueryTab 就关掉。
    public var onTabRemoved: ((UPaneTab<Payload>, _ remaining: [UPaneTab<Payload>]) -> Void)?
    /// 克隆一个标签（组内唯一标签拖到本组边缘时）。返回 nil = 拒绝克隆，
    /// 该次拖拽退化为无操作。uTable 的 `.data` 标签克隆时铸新 `queryTabID`；
    /// 终端标签克隆 = 新开一条会话。
    public var cloneTab: ((UPaneTab<Payload>) -> UPaneTab<Payload>?)?
    /// 分屏按钮 / 快捷键开新组时，往新组里放什么。返回 nil = 开**空**组。
    /// uTable 返回 nil（见 §3.4）；终端区返回一个新会话标签。
    public var makeTabForNewGroup: (() -> UPaneTab<Payload>?)?

    // — 查询 —
    public func tabActivity(groupID: UUID, index: Int) -> UPaneTabActivity
    public func locateTab(_ tabID: UUID) -> (groupID: UUID, index: Int)?

    // — 开 / 切 / 关 —
    /// 在活动组里开一个标签。`dedupe` 命中已存在的标签时只切过去，不新开。
    /// `asTransient` 时顶替同组里已有的 transient 标签（VSCode 预览标签语义）。
    @discardableResult
    public func openTab(_ make: () -> UPaneTab<Payload>,
                        dedupe: ((UPaneTab<Payload>) -> Bool)? = nil,
                        asTransient: Bool = false,
                        in groupID: UUID? = nil) -> UUID
    public func activateTab(groupID: UUID, index: Int)
    public func promoteTransient(_ tabID: UUID)      // 双击 / 编辑 / 保存 → 转正
    public func closeTab(groupID: UUID, index: Int)
    @discardableResult public func closeActiveTab() -> Bool
    @discardableResult public func closeEmptyGroup(groupID: UUID) -> Bool
    /// 批量关闭（uTable 删表后收拾标签；uTerm 预览区的「关闭其他 / 右侧 / 全部」）。
    public func closeTabs(where predicate: (UPaneTab<Payload>) -> Bool)

    // — 布局 —
    public func splitGroup(_ groupID: UUID, direction: SplitDirection, newLeafFirst: Bool = false)
    public func focusGroup(_ groupID: UUID)
    public func setFraction(_ fraction: Double, splitID: UUID)

    // — 拖拽 —
    /// center = 并入目标组（追加到末尾）；边缘 = 在该侧新建组。
    /// 源组因此空掉时从树里塌缩。组内唯一标签拖到本组边缘 → 走 `cloneTab`。
    public func moveTab(_ tabID: UUID, toGroup targetID: UUID, zone: PaneDropZone)
    /// 插到目标 chip 的槽位（同组重排 / 跨组移动都走这条）。
    public func reorderTab(_ tabID: UUID, before targetTabID: UUID)

    // — 整体重置（uTable 的 resetForLaunch / selectDatabase）—
    public func reset()
}

public struct UPaneGroupsPolicy {
    /// 分屏**按钮/快捷键**的组数上限；拖拽分屏不受限（对齐 uTable 现状：
    /// `splitPane` 里 `guard groupCount < 3`，而 `moveTab` 无限制）。
    public var splitButtonMaxGroups: Int? = nil
    /// 最后一个标签关掉后，组是否塌缩出树。false = 组留着显示空态。
    /// 两边现状都该是 true（uTable 的 `collapseIfEmpty`）。
    public var collapsesEmptyGroups: Bool = true
    /// 树只剩一个组时，那个组允许为空（显示空态占位）。
    public var allowsLastGroupEmpty: Bool = true
    /// 保活策略，见 §3.1。
    public var keepAlive: KeepAlive = .allTabs
    public enum KeepAlive { case allTabs, activeTabPerGroup, activeGroupOnly }
}
```

**`reorderTab` 与 `moveTab` 必须都在。** uTable 两条都有（chip 上的
`UTabReorderDropDelegate` 与组上的 `UTabDropDelegate`），uTerm 预览区**只有拖出去
分屏、没有重排**（`PreviewTabBar` 只挂了 `.onDrag`，没有任何 reorder drop
delegate）。改造后预览区白得重排能力，这是净收益。

### 1.6 视图

```swift
public struct UPaneGroupArea<Payload, Content: View, EmptyGroup: View>: View {
    public init(
        model: UPaneGroupsModel<Payload>,
        /// 拖拽载荷的专属 UTType。**必须由 app 传入** —— `UTType(exportedAs:)`
        /// 要求在各自的 Info.plist 里登记 `UTExportedTypeDeclarations`，
        /// 包替 app 声明不了。uTable 用 "com.uozi.utable.editor-tab"。
        dragType: UTType,
        /// 标签条高度。uTable 38（与侧栏、AI 面板头对齐），uTerm 现在 36。
        stripHeight: CGFloat = 38,
        /// 每个 chip 自己 body 内求值，见 §1.4。
        descriptor: @escaping (UPaneTab<Payload>) -> UPaneTabDescriptor,
        /// 面板内容。`isFront` 为 false 的标签仍然被挂载（保活），只是透明。
        @ViewBuilder content: @escaping (UPaneTab<Payload>, _ isFront: Bool) -> Content,
        /// 空组占位。uTable：「从左侧选择一张表…」；uTerm 预览区：「最近打开」。
        @ViewBuilder emptyGroup: @escaping (_ groupID: UUID) -> EmptyGroup,
        /// 关闭请求。**不是**「已关闭」—— 组件不自己关。
        /// 默认实现 `{ model.closeTab(...) }`；uTerm 预览区传自己的脏文件
        /// 确认版本（NSAlert 三选一，保存成功才关，见 §1.8）。
        onRequestClose: @escaping (UPaneTab<Payload>) -> Void,
        /// 标签条右侧的额外按钮（uTerm 终端区的「＋新建终端」）。
        @ViewBuilder stripAccessory: @escaping (_ groupID: UUID) -> some View = { _ in EmptyView() },
        /// chip 的右键菜单（uTerm 预览区的「关闭其他 / 右侧 / 全部 / 拷贝路径」）。
        @ViewBuilder contextMenu: @escaping (UPaneTab<Payload>) -> some View = { _ in EmptyView() },
        /// 外来拖拽（不是本区域标签）的落点钩子。返回 true 表示已消费。
        /// uTerm 用它接「SFTP 侧栏文件 → 组」「预览区标签 → 终端区组」。
        foreignDropTypes: [UTType] = [],
        onForeignDrop: @escaping (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool = { _,_,_ in false }
    )
}
```

内部结构照抄 `UTablePaneArea.body`（`UTablePaneArea.swift:35-68`）的四层扁平
ZStack，**顺序与 zIndex 不能改**：

1. `UPaneGroupChrome`（标签条 + 空态占位 + 组级落点区），按摊平矩形定位
2. **所有组的所有标签的面板**，按 `tab.id` 定身份，`zIndex(isFront ? 1 : 0)`
3. `PaneDropOverlay`（只画投放高亮的薄视图），`zIndex(2)`
4. `SplitterHandle`，`zIndex(3)`

### 1.7 关闭行为为什么是「请求」式

uTable 的关闭是同步的（`closeTab` 直接删）。uTerm 预览区的关闭是**模态 + 异步**的
（`WorkspaceWindowView.swift:316-342`）：脏文件先弹 NSAlert 三选一，选「保存」时
起一个 Task，`await handleSave(id:)` 之后再判断 `!b.isDirty` 才真的关，保存失败
就不关。

组件若自己在关闭按钮里调 `model.closeTab`，这条流程就没地方插了。所以：
**chip 的 × 与 ⌘W 都只调 `onRequestClose`，模型的 `closeTab` 由 app 在确认后自己调。**
uTable 传 `{ model.closeTab(groupID:index:) }` 即可，行为不变。

### 1.8 持久化 API

```swift
/// 组树快照。叶子记「这个组有哪些标签」，标签的载荷由调用方降维成 `P`。
public struct UPaneGroupsSnapshot<P: Codable & Sendable>: Codable, Sendable {
    public struct Group: Codable, Sendable {
        public var tabs: [P]
        public var activeIndex: Int
    }
    /// 叶子是 `groups` 数组的下标 —— 不存 UUID，恢复时全部重新铸造。
    public indirect enum Node: Codable, Sendable {
        case leaf(groupIndex: Int)
        case split(direction: SplitDirection, fraction: Double, first: Node, second: Node)
    }
    public var root: Node
    public var groups: [Group]
    public var activeGroupIndex: Int?
}

extension UPaneGroupsModel {
    public func snapshot<P>(_ encode: (UPaneTab<Payload>) -> P?) -> UPaneGroupsSnapshot<P>
    public func restore<P>(_ snapshot: UPaneGroupsSnapshot<P>,
                           make: (P) -> UPaneTab<Payload>?)
}
```

两条必须照抄 uTerm 现有快照的防御性做法（`WorkspaceModel.nodeSnapshot`
`WorkspaceModel.swift:427-451`）：

- **`encode` 返回 nil 的标签直接丢掉**（uTerm 里文件窗格不进终端快照）；
  一个组的标签被丢光则整个组丢掉；一个 split 的两侧都丢光则整个 split 丢掉，
  只剩一侧就把那一侧上提。
- **绝不给缺失项回落一个随机 UUID**。uTerm 的注释写得很清楚：旧代码
  `guard let pane = panes[paneID]` 失败时回落 `UUID()`，把一个不存在的
  `serverProfileID` 写进快照，「下次打开工作区恢复出的终端永远显示
  『连接失败 / 服务器配置已被删除』，且没有可用的重试入口」。

`frozenSnapshot` 那条（`WorkspaceModel.swift:38-43`：dispose 会清空 panes 映射，
而 `.onDisappear` 里「释放资源」与「保存快照」的先后 SwiftUI 不保证，所以
dispose 前先冻结一份）属于 app 的窗口生命周期，留在 `WorkspaceModel`，不进组件。

---

## 2. 功能清单与差异矩阵

这张表是防丢功能的清单。**「必保」列写「是」的，改造后必须还在。**

### 2.1 布局与分屏

| 功能 | uTable 编辑组 | uTerm 预览区 | uTerm 终端区 | 目标 | 必保 |
|---|---|---|---|---|---|
| 树的叶子是什么 | 组（带标签条） | 面板（绑一个 buffer，无标签条） | 窗格（一个会话） | 组 | — |
| 树的作用域 | 整个编辑区一棵 | 整个预览区一棵 | **每个标签一棵** | 整个区域一棵 | — |
| 分屏数量上限 | 按钮/⌘\ 限 3 组；拖拽不限 | 无限 | 无限 | policy 可配 | 是 |
| 分屏入口 | 标签条右侧按钮、⌘\、拖标签到边缘 | 只有拖标签到面板边缘 | pane header 按钮、⌘D / ⇧⌘D、命令面板、拖拽 | 全部保留 | 是 |
| 分屏方向选择 | 恒向右 | 由落点边决定 | header 按钮按长宽比自动（`autoSplitDirection`）；⌘D 横、⇧⌘D 纵 | 全部保留 | 是 |
| 分屏时新组内容 | **空组**（有意为之，见 §3.4） | 复制当前 buffer 的引用 | **克隆**：新 `PaneModel`，同服务器新会话 | `makeTabForNewGroup` 可配 | 是 |
| 分隔条 | 摊平后的 `SplitterHandle` | 递归 `SplitContainerView` | 递归 `SplitContainerView` | 摊平版 | 是 |
| 分隔条拖动坐标系 | `.global` | `.global` | `.global` | `.global`（`.local` 会抖，两边注释都写了） | 是 |
| 分隔条比例持久化 | 不持久化 | 不持久化（面板树整体不存） | **持久化**（`NodeSnapshot.fraction`） | 见 §4 | 是 |

### 2.2 标签

| 功能 | uTable | uTerm 预览区 | uTerm 终端区 | 目标 | 必保 |
|---|---|---|---|---|---|
| 标签条位置 | 每组一条，38px | **全区域一条**，36px | 全区域一条（窗口级标签），36px | 每组一条 | — |
| 标签重排 | 有（chip drop，跨组也行） | **无** | 有（一维，`TabReorderDropDelegate`） | 有 | 是 |
| 跨组移动标签 | 有（center drop / chip drop） | 不适用 | **无**（`dropPane` 要求源与目标同标签） | 有 | — |
| 标签 → 边缘分屏 | 有 | 有 | 有（`dropTab`：复制源标签的聚焦窗格，源标签若非当前则被关闭） | 有（改为真移动，见 §4.3） | 是 |
| 拖拽预览图 | `UTabDragPreviewChip`（AppKit 拖拽图像） | `Label` | **浮动 NSPanel 幽灵**（`PaneDragGhostLayer`，按窗格真实尺寸 + 抓取偏移；AppKit 拖拽图像被设成 1×1 透明） | 二选一，见 §5-P3 | 否 |
| 关闭按钮 | chip 内 ×，hover 变色 | `UDPreviewTab` 的 ×（active/hover 才可见） | `UDTermTab` 的 × | 保留 | 是 |
| 脏标记 | 无 | accent 小圆点 | 无 | descriptor.isDirty | 是 |
| 连接状态点 | 无 | 无 | 有（`UDTermTab` 的 dot，取 `tab.focusedPane?.session` 状态色） | descriptor 扩一个 `leadingDot: Color?` | 是 |
| 预览（临时）标签 | 无 | **有**（斜体、单击顶替、全局至多一个） | 无 | `UPaneTab.isTransient`，改为**每组**至多一个 | 是 |
| 右键菜单 | 无 | 有（保留标签页 / 关闭 / 关闭其他 / 关闭右侧 / 关闭所有 / 拷贝文件名 / 拷贝路径） | 无 | `contextMenu` 闭包 | 是 |
| 标签图标 | `UIcon` 自绘 glyph，按 kind 分色 | SF Symbol 按 `FileKind` | 无（只有状态点） | `UPaneTabIcon` 二选一 | 是 |
| 自定义标题 | 有（`customTitle`，已保存查询） | 无（恒 `displayName`） | 有（`TabModel.title` = 服务器名） | `customTitle` | 是 |

### 2.3 关闭与空态

| 功能 | uTable | uTerm 预览区 | uTerm 终端区 | 目标 | 必保 |
|---|---|---|---|---|---|
| 关最后一个标签 | 组塌缩；唯一的组留着显示空态 | buffer 关掉后面板改指 `activeBufferID`；全关光 → `panelRoot = nil` → 显示「最近打开」 | `closePane` 返回 false → 上层**关掉整个标签** | 组塌缩；最后一个组留空 | 是 |
| 空组存在吗 | **存在**，有占位 + 两个关闭出口（标签条 × 与占位里的链接） | 不存在 | 不存在 | 存在（policy 控制） | 是 |
| 关闭前确认 | 无 | **有**（脏文件 NSAlert 三选一，保存成功才关） | 无 | `onRequestClose` | 是 |
| 关标签的连带清理 | `garbageCollect`：没人引用的 `QueryTab` 才关 | `close()` 直接删 buffer | `pane.dispose()`（关会话 + 解 host-key relay） | `onTabRemoved(tab, remaining)` | 是 |
| 空态内容 | 「从左侧选择一张表，或点右上角 SQL 新建查询」；单组且正在载入 schema 时改成转圈 + 「正在载入数据库结构…」 | 「最近打开」列表 + 清空按钮 | 「没有打开的终端标签」+ 新建按钮 | `emptyGroup` 闭包 | 是 |

### 2.4 焦点与活动态

| 功能 | uTable | uTerm 预览区 | uTerm 终端区 | 目标 | 必保 |
|---|---|---|---|---|---|
| 活动态档数 | **3 档**（active / frontUnfocused / inactive） | 2 档（active buffer / 其余） | 2 档 | 3 档 | 是 |
| 活动组视觉 | 全区域唯一一条 accent 顶条（有意不画第二条压暗的，注释在 `UTabItem`） | 面板 1.5px accent 圆角框（多面板才画） | 同左 | 顶条 + 焦点框都留（焦点框只在多组时） | 是 |
| 按下即激活 | 有，走 `.onPointerDown` | 有，走 `.onPointerDown` | 有，走 `.onPointerDown` | 有 | 是 |
| 点面板正文改焦点 | 有（面板层也挂 `.onPointerDown`，按 `isFront` 过滤） | 有 | 有 | 有 | 是 |
| 切标签释放隐藏编辑器焦点 | **有**（`releaseHiddenEditorFocus`：`NSTableView` / 非 field-editor 的 `NSTextView` 交还 first responder） | 不需要（不保活） | 不需要 | 需要（保活后必须有） | 是 |
| 键盘焦点请求 | 无 | **有**（`EditorFocusRequest`，代数递增；会话恢复时不发，避免开窗抢终端焦点） | 无 | 保留在 app 侧 | 是 |

### 2.5 拖拽机制

| 功能 | uTable | uTerm 预览区 | uTerm 终端区 | 目标 | 必保 |
|---|---|---|---|---|---|
| 落点区数 | 5 | **4**（`actionableZone` 显式排除 center） | 5 | 5 | 是 |
| center 语义 | 并入目标组 | 无（被排除） | **交换两个窗格**（`swapPanes`） | 并入组；swap 无处安放，见 §4.3(a) | — |
| 落点高亮 | 边条 4px + 半区 10% 底 + center 描边**且带 6% 填充** | 同 uTerm 版（center 无填充） | center 只有描边、无填充 | 取 uTable 版 | 否 |
| 高亮写入去重 | **有**（`setHover` 比较新旧） | 无 | 无 | 有 | 是 |
| 高亮读取隔离 | **有**（`PaneDropOverlay` 是唯一读 dragState 观察属性的视图） | 无（`@State hoverZone` 在面板上，重算整个面板） | 无（`dropHighlightZone` 在 `PaneView` body 里） | 有 | 是 |
| 组尺寸来源 | **共享引用** `dragState.groupBounds`（不能捕获） | `let bounds` 捕获进 delegate | `let bounds` 捕获进 delegate | 共享引用 | 是 |
| 拖拽结束检测 | 30ms 鼠标释放轮询 + 120ms 宽限 | 走 workspace 的轮询（30ms + 120ms） | 30ms 轮询，**无**宽限 | 30ms + 120ms | 是 |
| 同步拖拽源优先 | 有（不依赖 provider 异步回调） | 有（+ provider 兜底路径） | 有 | 有 + provider 兜底 | 是 |
| 落点区挂载处 | **两处**（组外壳 + 盖在其上的面板层，后者带 `locationOffset` 补标签条高度） | 一处 | 一处（多一层 `shouldCatchDrop` 的透明 overlay） | 两处 | 是 |

### 2.6 持久化

| 功能 | uTable | uTerm 预览区 | uTerm 终端区 |
|---|---|---|---|
| 布局是否持久化 | **完全不持久化**（`resetForLaunch` / `selectDatabase` 直接重置成单个空组） | 不持久化（`restoreOpenFiles` 后 `rebuildSinglePanelForActiveBuffer` 只留一个面板） | **持久化**：`TabSnapshot { title, layout: NodeSnapshot }`，叶子只记 `serverProfileID` |
| 标签是否持久化 | 否 | 是：`openFiles: [OpenFileSnapshot{remotePath, byteSize, mtimeWhenLoaded}]` + `activeFileIndex`；不存正文与未保存修改 | 是（叶子即标签） |
| 焦点是否持久化 | 否 | `activeFileIndex` | `activeTabIndex` 存；`focusedPaneID` **不存**，恢复取 `firstLeafID` |
| 恢复时的校验 | 无 | 无 | `pruningUnknownServers` 白名单剪枝；剪光的标签整个丢掉，`activeTabIndex` 按保留下标重映射 |

**这一格是本次改造风险最集中的地方** —— 只有终端区真的存了布局，也只有它需要迁移。

---

## 3. 必须保留的性能约束

uTable 这套是被性能问题逼出来的，抽包时逐条带走。下面每条都给了出处，
改动这些地方前先读原注释。

### 3.1 面板拍平挂载，不建递归视图树

出处：`UTablePaneArea.swift:26-34` 与 `UTableLayoutNode.swift:151-158`
（后者已进 `UPaneTree/LayoutFrames.swift`）。

**机理。** 递归渲染时（uTerm 的 `TabContentView.nodeView` / `PreviewArea.nodeView`
现在就是这样），把内容挂在各自的组/面板子树里，那么分屏、合屏、把标签拖进另一组，
都会改变面板在视图树里的路径 —— 而且 `nodeView` 返回 `AnyView`，具体类型被抹掉，
SwiftUI 连做差量的可能都没有，只能整棵拆掉重建。

**实测数字（uTable，30 列 × 100 行的数据网格）：**

| 操作 | 代价 |
|---|---|
| 重建一个面板 | ≈350ms |
| 拆掉一个面板 | ≈180ms |
| 摊平后的纯 resize | ≈60ms |

**做法。** 树摊平成矩形列表（`LayoutNode.frames(in:)`），编辑区用一个扁平
`ZStack` + `.frame` + `.offset` 定位；**每个标签的面板只出现一次，身份就是
`tab.id`**。换组、分屏、合屏于是只是改 frame，重排而不重建。

**衍生的两条，一起带走：**

- **非前台标签也留在树上**，只是 `.opacity(0)` + `.allowsHitTesting(false)` +
  `.accessibilityHidden(true)`。切标签是纯透明度翻转，不是重建。
- **文档解析在区域这一层做完，往下传值**（`MountedPane.document`，
  `UTablePaneArea.swift:104-119`）。`queryTabState.tabs` 是 `@Observable` 属性，
  谁在 body 里读它谁就被任何一次增删标签波及 —— 实测每挂一个数据网格多 60ms，
  开/关任意标签都要付。

  **uTerm 预览区现在正踩着这条**：`PreviewPanelView.content` 调
  `model.buffer(forPanel: panelID)`，其内部 `buffers.first { $0.id == bufferID }`
  在每个面板的 body 里扫 `buffers` 数组。现在只有 1–2 个面板所以看不出来；
  改成 VSCode 模型 + 保活之后，面板数会涨到「所有打开的文件」，这条必须先改成
  区域层解析。

**保活策略要可配（`UPaneGroupsPolicy.KeepAlive`）。** uTable 保活的是
`NSTableView` / `NSTextView`，静止时不产生工作。终端保活的是 SwiftTerm 视图 ——
隐藏但挂载的终端视图会不会继续绘制/布局，**未确认，需实测**。所以给三档：
`.allTabs`（uTable 现状）/ `.activeTabPerGroup`（每组只挂前台标签）/
`.activeGroupOnly`。终端区先按 `.allTabs` 试，实测掉帧就退到
`.activeTabPerGroup` —— 那时终端区拿不到「切标签零重建」这个收益，但代价可控：
`TerminalHostView` 本来就复用 `TerminalSession` 持有的那个 NSView（scrollback
因此不丢），重挂只是 attach/detach。

### 3.2 活动态传对象，不传 Bool

出处：`uTable/UI/Common/ActivePaneEnvironment.swift:14-18`。

**机理。** 把 `isActivePane: Bool` 直接 `.environment()` 进去，值一变
SwiftUI 就重建整棵子树的环境节点 —— 实测「点进另一个编辑组」这种什么都没改的
操作要 **80–160ms**（数据网格整块重算），切标签同理。

**做法。** 传一个身份稳定的 `@Observable` 对象：

```swift
@MainActor @Observable
public final class ActivePaneGate { public var isActive: Bool }
```

对象身份不变、翻转的只是它的 `@Observable` 属性，于是只有真正在 body 里读它的
视图才失效。而现有读点（`TableDataView` / `SQLEditor` / `DataGridTableView`）
全都在通知/事件回调里运行时读，不建依赖 —— 切活动面板因此降到 ~0。

**为什么必须有这个 gate（不只是性能）。** 因为所有标签都挂着，`⌘S 保存` /
`⌘R 刷新` / undo / redo 这类**广播**通知会打到隐藏面板上；处理器必须 gate
在这个值上，只让可见面板动手。uTerm 里对应的广播是
`.savePreviewBuffer`（`WorkspaceCommands.swift:18-21`，userInfo 带 bufferID 时
精确到具体 buffer，缺省回落 `activeBufferID`）—— 保活之后同样需要 gate。

配套的还有 `releaseHiddenEditorFocus`（`UTablePaneArea.swift:314-319`）：
保活的面板在被隐藏时**仍持有 AppKit first responder**，不放掉的话键盘会打进一个
看不见的 SQL 编辑器 / 数据网格。切标签时把内容编辑器（`NSTableView`、
非 field-editor 的 `NSTextView`）的 first responder 交还 `nil`；field editor
（侧栏筛选框、AI 输入框那种 `NSTextField`）不动。

组件应当把 gate 建好、按 `isFront && activeGroupID == myGroup` 翻转、
注入环境，并暴露一个 `onActiveTabChanged` 让 app 挂 `releaseHiddenEditorFocus`
这类清理。

### 3.3 按下激活用 NSEvent 探针，不用 SwiftUI 手势

出处：`UTablePaneArea.swift:456-467`（chip）、`UTablePaneArea.swift:159-168`
（面板层）、`PaneView.swift:99-106`、`PreviewArea.swift:108-113`，
以及 `UAppKitBridge/PointerDownProbe.swift` 顶部那段。

**两条独立的理由，缺一条都还是得用探针：**

1. **SwiftUI 在 macOS 上不装 `NSGestureRecognizer`。** `.onTapGesture` /
   `.simultaneousGesture` 都由 `NSHostingView` 自己的响应方法处理。只要区域里
   放的是 `NSViewRepresentable`，而那个 NSView 自己实现了 `mouseDown`
   （`NSTableView`、`NSTextView`、SwiftTerm 的终端视图**全都是**），命中测试就
   落到 AppKit 子视图上，`NSHostingView.mouseDown` 根本不被调用，挂在祖先上的
   SwiftUI 点击手势**永不触发**。

   离屏 `NSHostingView` 实测（`PointerDownProbe.swift:17-23`）：

   | 内容 | 整棵树的手势识别器 | 命中测试落到 |
   |---|---|---|
   | 纯 SwiftUI | 0 | `NSHostingView` ✓ 手势正常 |
   | `NSViewRepresentable` | 0 | 那个 `NSView` ✗ 手势失效 |

   症状：点进另一个分区的表格/终端，「当前分区」不跟着变，随后的开表、分屏、
   ⌘W、状态栏显示的会话全都还作用在上一个分区上。

2. **任何「按下瞬间就响应」的手势会抢占鼠标事件流，让同一视图的 `.onDrag`
   永远起不了 AppKit 拖拽会话。** 即使是 `simultaneousGesture` 的
   `DragGesture(minimumDistance: 0)`，或 `onLongPressGesture(0.01s)`。
   探针实测：`DragGesture` **稳定阻断**，`LongPress` 时序竞态**偶发阻断**。
   后果就是标签拖不动、拖拽分屏整套没了。

   这条是为什么「按下即激活」（对齐原生标签栏/浏览器标签，`.onTapGesture` 的
   抬起触发读起来像输入延迟）与「chip 可拖拽」这两个需求，在 SwiftUI 手势体系
   里无解。

3. **`.onDrag` 没有位移死区。** 按下后收到第一个 `mouseDragged`（探针实测移动
   0.5pt）就起 AppKit 拖拽会话、把预览画出来——点标签时手一抖，预览就在点下去的
   地方闪一下，这次点击的抬起也被拖拽会话吞掉。chip 因此不挂 `.onDrag`，改用
   `UAppKitBridge/DragSourceProbe.swift` 的 `.dragSource`：同样旁观鼠标事件，按下后
   拖过 5pt 才自己调 `beginDraggingSession`；落点那头不变，还是 SwiftUI 的
   `.onDrop`（载荷写在拖拽板上，`DropInfo` 照常认）。

**探针的三个实现细节，照抄别改：**

- `hitTest` 返回 `nil` —— 对命中测试完全透明，AppKit 内容的选中、拖拽、
  first responder 全部照常；
- 本地 monitor **原样 `return event`**，绝不消费；
- 命中判定取 `bounds ∩ visibleRect`（`PointerDownHitTest.contains`）。只用
  `visibleRect`：在 `ScrollView` 里它不是「本视图裁剪后的可见部分」而是整个滚动
  视口（实测比 `bounds` 还大、原点可为负），相邻探针会互相误命中；只用
  `bounds`：已滚出视口的视图仍会响应其名义 frame 上的点击。

**调用方要过滤重叠。** 同组的后台标签与前台标签矩形完全重合，每个探针都会各响应
一次 —— 面板层的回调里必须 `if item.isFront`，否则一次点击被同组每个已挂载标签
各响应一遍（`UTablePaneArea.swift:165-168`）。

### 3.4 其余同样是踩出来的，一起带走

| 约束 | 出处 | 说明 |
|---|---|---|
| 组尺寸走共享引用，不捕获进 DropDelegate | `UTableTabDrag.swift:73-80` | SwiftUI 的 `.onDrop(of:delegate:)` 在拖放目标注册后**不随 body 重建刷新 delegate 的存储值**。注册时的宽高一旦窗口 resize 就变旧，左右（宽度相关）投放区随即错判甚至失灵；上下用高度，只改宽时仍正常，故表现为「改了宽度后左右分屏拖不出来」。**uTerm 的 `PaneView.paneDropDelegate` 与 `PreviewPanelView` 现在都是 `bounds:` 直接捕获 `paneSize`，按这条推断它们有同样的 bug（未在 uTerm 上实测复现）。** |
| `setHover` 去重 | `UTableTabDrag.swift:65-71` | `dropUpdated` 每帧都调（鼠标不动也调），`@Observable` 的 setter 不比较新旧值 —— 原样写回同一个 target 也会让所有读 `hover` 的 body 失效。去重后每次拖拽只剩「跨区」那几次真正的失效。 |
| 高亮独立成薄视图 | `UTablePaneArea.swift:360-376` | `PaneDropOverlay` 是唯一读 `dragState` 观察属性的地方 —— 拖拽期间失效重算的就只有它，组本体和里面的数据网格一概不动。 |
| 跳过 no-op 写 | `UTableModel.swift:461-466` | 每次 `@Observable` 变更可能同步 flush 一次窗口布局（`ObservationCenter.invalidate → flushTransactions`），一次点击冗余重写三个属性就付三次布局。`activateTab` 里三个赋值全带 `if != ` 判断。 |
| 分屏按钮开**空**组，不克隆 | `UTableModel.swift:517-521` | 「克隆当前标签只会把同一张表（连同它的 NSTableView 和一次数据加载）再开一份，既不是想要的内容，也是大表分屏卡顿的一半来源。」注意这是 uTable 的取舍，终端区应保留克隆语义（见 §4.3(c)）。 |
| 可选链赋值会触发独占性冲突 | `UTableModel.swift:419-421` | `groups[gid]?.x = f(groups[gid])` 先开写访问再求值右侧 → Fatal access conflict。必须本地拷贝、改完写回。 |
| 拖拽结束靠鼠标释放轮询（当年 `.onDrag` 没有结束回调，换成 `.dragSource` 后沿用） | `UTableTabDrag.swift:84-106` | 30ms 周期（`NSEvent.pressedMouseButtons & 1`），检测到松手后**再等 120ms** 给 drop target 跑完 `performDrop` 才清进程内拖拽源；成功的 drop 会提前 `end()`。uTerm 的 `PaneDragState.begin` 没有这 120ms 宽限，合并时取 uTable 版。 |
| 分隔条用 `.global` 坐标 | 两边 `SplitterHandle` 注释一致 | 手柄随 `fraction` 变化自己移动，`.local` 拖拽测的是相对移动中视图的位移 → 每步都把原点在光标下推一次 → 比例震荡、面板抖动。 |

---

## 4. uTerm 改造的具体影响面

### 4.1 窗口 IA：先做两个独立区域，不要一步合一

两条路：

- **(a) 两个 `UPaneGroupsModel` 实例**：预览区一个、终端区一个，中间仍是
  `WorkspaceCenter` 的 `previewTerminalRatio` 分隔条。
- **(b) 一棵树**：终端和文件是同一棵组树里的不同 payload
  （`enum WorkspacePayload { case terminal(PaneModel); case file(FileBuffer) }`）。

**推荐 (a) 先落地，(b) 作为可选后续。** (b) 会连带推翻
`previewTerminalRatio`、`FocusRegion` / `CloseIntent` 整套 ⌘W 逻辑、
两个区各自的底色（终端区底是 `TerminalColorScheme` 的背景色，预览区是 `UD.bg`），
不该和模型改造混在一次里。

值得记一笔：现有代码里 (b) 其实**已经半成立** —— `TabModel.insertFilePane` 可以
把一个 `FileBuffer` 插进终端窗格树，`PaneView.content` 里 `pane.fileBuffer != nil`
就渲染 `PreviewBufferBody`。所以 (b) 不是空想，payload 枚举是它的自然形态。

### 4.2 持久化格式

#### 预览区：无损，几乎不用改

现在存的是 `openFiles: [OpenFileSnapshot]` + `activeFileIndex`
（`WorkspaceSnapshot.swift:62-67`），**面板树本来就不持久化**，恢复时
`rebuildSinglePanelForActiveBuffer()` 只重建一个面板。

所以旧快照迁到新模型是**恒等映射**：全部标签塞进唯一一个组，`activeFileIndex`
成为该组的 `activeIndex`。既不丢东西，也不需要写迁移代码。

之后若要顺带持久化预览区的组树，加一个新的可选字段即可，旧快照解码为 nil
走上面那条路。

#### 终端区：格式必变，需要迁移

现在是 `tabs: [TabSnapshot{ title, layout: NodeSnapshot }]` + `activeTabIndex`，
`NodeSnapshot.leaf` 只记 `serverProfileID`。新模型是**全窗口一棵组树**，
所以 `[树]` → `树` 这一步天然降维。

建议加新字段、保留旧字段只读：

```swift
struct WorkspaceSnapshot: Codable {
    /// 旧格式（每标签一棵窗格树）。只解码、不再写；迁移完成后可以删。
    var tabs: [TabSnapshot]
    var activeTabIndex: Int?
    /// 新格式：终端区的组树。nil = 旧快照，走 §4.2 的迁移。
    var terminalGroups: UPaneGroupsSnapshot<TerminalTabSnapshot>?
    // …其余字段不变
}
struct TerminalTabSnapshot: Codable, Sendable {
    var serverProfileID: UUID
    var title: String
}
```

**迁移规则（推荐 M2）：**

1. 取旧的**活动标签**（`activeTabIndex`），它那棵窗格树保形迁过来：
   每个叶子 → 一个组，组里放一个标签（`serverProfileID` 不变，
   `title` 取该 `TabSnapshot.title`）。分屏形状与 `fraction` 全部保留。
2. 其余每个旧标签，按 DFS 把它树里的每个叶子各变成一个标签，**追加到第一个组的
   标签列表末尾**。
3. `activeGroupIndex` = 步骤 1 里对应旧 `focusedPaneID` 的组；`focusedPaneID`
   本来就不持久化，所以取第一个叶子。
4. `pruningUnknownServers` 的白名单剪枝原样保留，只是作用在标签列表上：
   指向不存在服务器的标签丢掉，标签被丢光的组丢掉，组被丢光则整棵树丢掉，
   由「没有标签就开一个」兜底。

**这条迁移会丢什么：非活动标签的分屏形状。** 会话本身一个不丢（都会重连），
丢的只是「标签 B 曾经是 2×2 四宫格」这个布局信息。这是 §4.3(b) 那条固有取舍的
一次性代价。

**备选（更省事）：不迁移。** 直接起新键，旧 `tabs` 忽略，首次升级后用户看到
「每台服务器一个组一个标签」。终端布局本来就是重连出来的，代价不大。
若选这条，请在发版说明里写一句 —— 用户会注意到窗口布局被重置了。

**要不要同时写旧字段（支持降级回滚）：** 可以把新布局降维成
`[TabSnapshot]`（每个组一个 TabSnapshot，其 layout 为单叶 = 组内前台标签的
serverProfileID）一起写。这样万一回滚到旧版本不会白屏。**建议做** ——
`WorkspaceStore` 是本地 JSON，代价只有十来行。

### 4.3 语义映射

| 旧 | 新 | 备注 |
|---|---|---|
| `WorkspaceModel.tabs: [TabModel]` + `activeTabID` | 一个 `UPaneGroupsModel<PaneModel>` | 窗口级标签这个层次**消失**了 |
| `TabModel.root` / `TabModel.panes` | `model.root` / `model.groups` | 叶子从窗格变成组 |
| `TabModel.focusedPaneID`（每标签一个） | `model.activeGroupID`（全区域一个）+ 该组的 `activeIndex` | |
| `focusedTerminalSession()` = `activeTab?.focusedPane?.session` | `model.activeTab?.payload.session` | 调用点：`TerminalWindowView.swift:63`、`WorkspaceWindowView.swift:92`、`StatusBarView.swift:19,144` |
| `TerminalTabBar` 的连接状态点 = `tab.focusedPane?.session` | 每个 chip 用**它自己**那条会话的状态 | 语义更准了：现在一个标签里四个窗格连四台机器，点只反映聚焦那个 |
| `TabModel.title`（服务器名，标签级） | `UPaneTab.customTitle` = 服务器名 | 组没有标题；`PaneView` 那个 22px header 的服务器名并进 chip |
| ⌘T `openServer(profileID:title:)` | 在活动组追加一个新标签（新 `PaneModel` = 新会话） | 行为等价 |
| ⌘D / ⇧⌘D `splitFocusedPane(direction:)` | `model.splitGroup(activeGroupID, direction:)`，`makeTabForNewGroup` 返回一个新会话标签 | **克隆语义保留**（见 (c)） |
| `⌘W` → `WorkspaceCloseShortcut.focusRegion` → `resolveCloseIntent` → 关文件 buffer / 关聚焦窗格 → 最后窗格关标签 → 关窗口 | 焦点区判定**保留**（两区各一个模型，仍需决定打哪个区）；`CloseIntent.closeTerminalFocusedPane(tabID:)` 改成 `closeTerminalActiveTab`；「最后窗格关标签」变成「组空则塌缩」；树只剩一个空组时关窗口 | `CloseIntent.swift` 的纯函数与单测形状不变，只换字段名 |
| `dropPane` center = `swapPanes` | **没有对应表达**，见 (a) | |
| `dropTab(sourceTabID, onto:zone:)`：复制源标签的聚焦窗格、源标签若非当前则关闭 | 直接就是 `moveTab` —— 真移动、不复制、不关源 | 逻辑大幅简化，`WorkspaceModel.swift:340-363` 整段可删 |
| `dropFileBuffer(...)`（SFTP 文件 / 预览标签 → 终端窗格） | 方案 (a)：跨模型拖拽，走 `onForeignDrop`；方案 (b)：payload 枚举天然支持 | 是现有功能，别丢 |
| `FilePreviewModel.assignActiveBufferToFocusedPanel` / `rebuildSinglePanelForActiveBuffer` / `reconcilePanelsAfterClosingBuffer` | **整段删掉** | 它们存在的唯一原因是「面板只记 bufferID、全局只有一个 activeBufferID」这个错位模型 |
| `FilePreviewModel.close(bufferID:)` 直接删 buffer | 关的是**标签**；`onTabRemoved` 里数还有没有别的标签引用同一个 buffer，没有才释放 | 与 uTable 的 `garbageCollect` 同形 |
| `previewTabBufferID`（全局至多一个临时标签） | `UPaneTab.isTransient`，**每组**至多一个 | 与 VSCode 一致 |
| `EditorFocusRequest`（代数递增） | 保留，但消费端要加 `ActivePaneGate` 判定 | 否则隐藏编辑器也会抢 first responder |

### 4.4 做不到 / 会变差的地方

**(a) 「交换两个窗格」这个功能在 VSCode 模型下没有对应表达。**
uTerm 终端区现在把 center 落点用作 `swapPanes`（`WorkspaceModel.swift:330-334`），
`LayoutNode.swapping` 就是为它存在的。改成 VSCode 模型后 center 必须让给
「并入目标组」——否则拖标签到组中央什么都不发生，就是预览区现在那个体验
（`actionableZone` 把 center 排除掉了）。

问题在于：交换的对象是**组**，而拖拽的对象是**标签**，两者不是一回事。
三个补偿方案，按推荐排序：

1. 让**组的标签条空白处**可拖 —— 拖的是整个组，落到另一组的 center = 交换两组。
   语义正确、与 VSCode 的「拖组」一致。工作量在于要再定义一种拖拽载荷。
2. ⌥ 修饰键把 center drop 从「并入」改成「交换」。省事但是隐藏功能。
3. 砍掉，记账。

**建议：先按 3 落地（能力还在 —— `swapping` 已经在 `UPaneTree` 里），把 1 排进
后续。** 但这条要让用户知道：这是本次改造里唯一一个**明确会消失**的交互。

**(b) 每标签一棵分屏树 → 全窗口一棵树，这是真的会变差。**
旧模型下「标签 A 是四宫格、标签 B 是单窗格」可以并存，切标签 = 切一整套布局，
拿标签当工作集切换器用是完全成立的。新模型下全窗口只有一套分屏形状。

这是 VSCode 模型的固有取舍，没有缓解办法（除非引入 VSCode 的「编辑器布局预设」，
那是另一个项目）。**如果这个用法是 uTerm 的核心工作流，整个改造的前提就要重新
讨论。** 值得在动手前先确认一次。

**(c) 分屏时新组是空的还是克隆的，两边必须不同。**
uTable 的 ⌘\ 刻意开**空**组（理由见 §3.4 那条：克隆大表是分屏卡顿的一半来源）。
终端区没有「空组占位」这种有意义的状态 —— 空的终端组只能显示一个「新建终端标签」
按钮，多一次点击。所以：

- 终端区：`makeTabForNewGroup` 返回新会话标签（保持现有克隆语义）；
- 预览区：返回 nil，开空组，空态显示「最近打开」；
- uTable：返回 nil。

policy 化即可，不冲突。

**(d) 保活成本未知。** 见 §3.1 末尾。SwiftTerm 视图在隐藏但挂载状态下的开销
**未实测**，这是本次改造最大的技术未知数。

**(e) 「同一个文件在两个面板」现在是免费的。**
面板只记 `bufferID`，两个面板指同一个 buffer 天然成立。新模型下这变成
「两个标签指同一个 document」—— 同样免费，但关闭语义要从「关 buffer」改成
「关标签 + 引用计数」。这条其实是**净收益**：现在
`reconcilePanelsAfterClosingBuffer` 会在关掉一个 buffer 后**把所有指向它的面板
改指 `activeBufferID`**，结果是两个面板显示同一个文件，很怪。

**(f) 预览区的落点区从 4 个变 5 个。** center 从「无操作」变成「并入组」。
这是改善，但也是行为变化，用户会察觉。

**(g) 终端区的窗格 header（22px：图标 + 服务器名 + 拖拽手柄 + 分屏 + 关闭）
整条消失**，功能分散到 chip（标题、关闭）与标签条右侧（分屏）。
拖拽手柄没有了 —— 现在拖的是 chip。要确认这个手感变化可接受，
以及那个做得很讲究的浮动 NSPanel 拖拽幽灵（`PaneDragGhostLayer`，
按窗格真实尺寸 + 抓取偏移绘制）要不要保留：拖一个 chip 时再拖出一个
「整块窗格大小」的幽灵，观感上是否还成立，需要看着实物定。

---

## 5. 分阶段实施建议

每一步都能独立编译、独立验证、独立提交。

### P0 — uAppKit：新 target `UPaneGroups`（纯搬运 + 泛型化）

把 uTable 的四个文件按 §1 的 API 泛型化搬进包：
`UTablePaneArea.swift` / `UTableTabDrag.swift` / `UTableDropZone.swift` /
`UTableSplitContainer.swift`，加上 `UTableModel.swift` 里
`UTab` / `UPaneGroup` / 编辑组那一段方法。

**验证**：`swift test` 覆盖模型逻辑 —— open 去重、close 后 activeIndex 修正、
collapse、moveTab 五种 zone、组内唯一标签拖本组边缘的克隆分支、reorder 的
`insertAt -= 1` 修正、`onTabRemoved` 的 remaining 计算、snapshot/restore 往返。

**风险：低。** 唯一的未知是**泛型 `@Observable` class 能不能用** —— 第一天就
写个 5 行的空壳编译一下。若宏不支持，退路是模型做成 struct，由 app 侧的
`@Observable` 容器持有（uTable 的 `UTableShellModel` 本来就是这个形态）。

### P1 — uTable：换用组件，行为零变化

删掉本地四个文件，`UTableShellModel` 内嵌一个
`UPaneGroupsModel<UTab.Kind>`，把 `openData` / `openStructure` / `openDesign` /
`openNewSQL` / `closeTabs(for:)` 改成调组件 API。

**这一步必须在动 uTerm 之前做完。** uTable 是参考实现，先证明抽出来的组件和原来
一模一样，再拿去改另一个 app —— 否则一旦 uTerm 出问题，分不清是抽包抽坏了还是
改造改坏了。

**验证**：工作区已有的 `PaneAreaInteractionPerfProbe` 量尺跑一遍（分屏 / 合屏 /
拖标签 / 切标签 / 点另一组的耗时），对比改造前的基线；手工过一遍
§2 表里 uTable 那一列的每一格。

**风险：中。** 性能回归是主要风险，量尺能兜住。

### P2 — uTerm 预览区

最安全的一步：面板树本来就不持久化、迁移无损、编辑器本来也不保活。

要点：
- 全局 `PreviewTabBar` → 每组标签条；
- `assignActiveBufferToFocusedPanel` / `rebuildSinglePanelForActiveBuffer` /
  `reconcilePanelsAfterClosingBuffer` 删掉；
- `previewTabBufferID` → 每组 transient；
- `close` 改成「关标签 → 引用计数 → 释放 buffer」；
- 顺手修 §3.4 那条：`buffer(forPanel:)` 改成区域层解析后传值；
- `EditorFocusRequest` 消费端加 gate；
- 右键菜单、脏文件确认、`onRequestClose` 接上。

**验证**：`FilePreviewModelTests` 改写并扩充；手工过一遍
「单击预览 → 斜体 → 双击转正」「改了内容再单击别的文件不该被顶掉」
「脏文件关闭三选一」「同一文件拖到另一组」「关掉其中一个组后另一个组还在」。

**风险：中。** transient 语义从全局改成每组，是唯一有行为变化的地方。

### P3 — uTerm 终端区（模型 + 视图，暂不迁移持久化）

`WorkspaceModel.tabs: [TabModel]` → 一个 `UPaneGroupsModel<PaneModel>`；
`TabModel` 整个删掉；`TabContentView` / `PaneView` / `TerminalTabBar` 重写成
组件的 descriptor + content 闭包；`TerminalArea` 只剩一层壳。

这一步**先只写新快照键、旧快照直接忽略**（开发期布局丢失可接受），
把迁移隔离到 P4。

同时决定：拖拽幽灵保留哪一版（§4.4(g)）、center-swap 怎么处理（§4.4(a)）。

**验证**：`TabModelTests` / `WorkspaceModelTests` 大改；手工过
⌘T / ⌘D / ⇧⌘D / ⌘W 四条快捷键的每个分支、状态栏与工具栏徽标的会话跟随、
连接状态点、host-key sheet（`hostKeySheet(pane.hostKeyRelay)` 挂在 `PaneView`
上，保活之后**每个标签都会挂一份** —— 要确认多个 sheet 不会打架，这是个具体
风险点）。

**风险：高。** 改动面最大，且触及会话生命周期。

### P4 — 终端区持久化迁移

按 §4.2 加 `terminalGroups` 字段 + M2 迁移 + 降级写。

**验证**：单测钉住「旧 `tabs` 快照 → 新组树」的每种形状（单标签单窗格 /
单标签四宫格 / 多标签 / 含未知服务器的叶子 / `activeTabIndex` 指向被剪掉的标签）；
手工验一次**带旧快照启动**（把一份改造前的 `workspace-<serverID>.json` 拷回去）。

**风险：中。** 出错的表现是「用户升级后窗口布局乱了」，不是崩溃。

### P5 — 可选增强

按需排：两区合一（§4.1(b)）、拖组以交换（§4.4(a) 方案 1）、
跨区拖拽（预览标签 ↔ 终端组）、预览区组树持久化。

---

## 6. 未确认清单

动手前应逐条确认，不要按本文的推断直接写：

1. ~~**泛型 `@Observable` class 是否被宏支持。**~~ **已确认可行**（2026-09-01 实测）：
   Swift 6 语言模式下泛型 `@Observable final class` 正常编译，`withObservationTracking`
   对泛型属性也会触发回调；载荷用带关联值的枚举（与 `UTab.Kind` 同形状）验的。
2. ~~**保活的 SwiftTerm 视图在隐藏状态下的开销。**~~ **已实测**（2026-09-01）。
   做法：同一进程内每 30s 交替翻转挂载策略做配对测量（抵消机器负载漂移），6 个终端
   各 24 KB/s 输出、只 1 个活动，在 vendored SwiftTerm 里插绘制计数器 + `sample` 归因。
   必须加 `-NSAppSleepDisabled YES`，否则 App Nap 会把进程挂起、数据全废。

   | | 基线（只挂活动标签） | 拍平挂载（全挂 + opacity 0） |
   |---|---|---|
   | draw 调用 | 34/s（1 个终端） | **202/s（6 个各 33.7/s）** |
   | 单次重绘面积 | 204 278 pt² | **204 278 pt²（逐位相同）** |
   | 主线程花在 draw 里 | 113 ms/s | **315 ms/s** |
   | feed 字节 | 142 KB/s | 142 KB/s（相同） |

   > ✅ **已用 Release 复核**（2026-09-01）。Debug 那轮的绝对数字不可引用，但**结论方向
   > 没变**，最终建议也没变。核实构建：`-showBuildSettings` 不打印
   > `SWIFT_OPTIMIZATION_LEVEL`（Release 的 xcconfig 没显式设它），要核编译器真实命令行 ——
   > 两个 target 都是 `swiftc -O -whole-module-optimization`。插桩用环境变量开关，不用
   > `#if DEBUG`（否则 Release 下不生效）。
   >
   > **场景 A**（6 标签各 22 KB/s，1 个活动）：draw 32.1/s → **192.9/s**（严格 6×），
   > 主线程 draw 耗时 30.7 → **113.6 ms/s**，等频归一后**额外 +90～140 ms/s（约 0.1 核）**。
   > **场景 B**（真实工作流：只有 2 个在输出，4 个静止）：draw 33.0 → 66.3/s（严格 2×），
   > **额外仅 +21.5 ms/s**；4 个被挂载但静止的终端贡献 **0 次 draw**。
   >
   > **绘制只吃到 ≈3.9× 的 `-O` 红利，解析是 9.4×** —— CoreText / CoreGraphics 那一半不提速，
   > 「不能按 9.4× 外推」的判断成立。顺带更正上一轮 Debug 数字：那轮拍平相的 SoC 频率比
   > 自己的基线相高 2.09×，所以「113 → 315，Δ202」是被 DVFS 压缩过的，**等频 Δ 实际约
   > +544 ms/s**；两轮等频 Δ 之比 544:123 = 4.4×，与每次 draw 的 3.9× 自洽。

   **决定：`KeepAlive` 默认取 `.activeTabPerGroup`，`.allTabs` 留成显式选项。**
   拍平挂载在 Release 下**技术上可用**（真实工作流只要 +21 ms/s），但不做默认，三条依据：
   ① **代价没有上限** —— 严格线性于「后台标签数 × 输出量」，用户开 12 个 tail 日志的标签
   就是 +0.25 核长期烧着，产品侧没有任何东西给它封顶；② **在 uTerm 换不来什么** ——
   `TerminalHostView` 本来就复用 `TerminalSession` 持有的 NSView，重挂只是 attach/detach、
   scrollback 不丢，省下的只是 SwiftUI 那侧窗格树的一次性重建；③ **交易形状不划算** ——
   拿一次性的切标签成本，换一个永久的每秒成本，且恰好在主线程最忙（后台狂输出）时付。
   真要上 `.allTabs`，正确的缓解方向是让不可见的终端别画（SwiftTerm 侧改动），而不是靠
   KeepAlive 档位。

   **结论（Debug 数据，绝对值不可引用，结构性事实仍成立）：隐藏但挂载的终端在全速重绘，
   `.opacity(0)` 一点绘制都不省** —— CoreAnimation
   照样叫 `drawInContext:`，透明度是合成阶段的事。**所以终端区不能照搬拍平挂载**，
   `UPaneGroupsPolicy.KeepAlive` 默认应取 `.activeTabPerGroup`。代价是终端区拿不到
   「切标签零重建」，但 `TerminalHostView` 本来就复用 `TerminalSession` 持有的 NSView，
   重挂只是 attach/detach，scrollback 不丢。

   两条附带发现：**静止的终端确实不干活**（空载两组 draw 均为 0），代价严格正比于后台
   标签的输出量，不是固定开销；**解析（feed）与挂载与否无关** —— `TerminalSession`
   无条件 `terminalView.feed()`，所以 uTerm 今天的后台标签**已经**在全速解析 VT，
   keep-alive 档位只能省掉绘制那一半，要省解析得在 `TerminalSession` 层另做暂停机制
   （与本次改造无关的独立优化项）。
3. **uTerm 的 `PaneView` / `PreviewPanelView` 是否真的有「resize 后左右投放区
   失灵」的 bug。** §3.4 第一条。这是按 uTable 的注释推断的，未在 uTerm 上实测
   复现。若确实存在，可以作为一个独立的小修先落地。
4. **保活后每个标签各挂一份 `hostKeySheet` 会怎样。** §5-P3。
5. ~~**「每标签一棵分屏树」这个用法在 uTerm 上有多重要。**~~ **已决策**（2026-09-01）：
   已向用户说明这个能力在 VSCode 模型下无法表达、且非活动标签的分屏形状会在持久化
   迁移中丢失（会话不丢），用户选择**终端区照改，接受这个损失**。P3 / P4 按原计划推进。
6. **`PaneDragGhostLayer` 那套幽灵在拖 chip 的场景下是否还成立。** §4.4(g)。
