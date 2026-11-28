#if os(macOS)
import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import UniformTypeIdentifiers
import UPaneTree

/// 标签栏 chrome 与正文区域的共享几何。`stripHeight` 包含底部发丝线；相邻的
/// toolbar 只要使用同一高度，分隔线就会落在同一条基线上。
nonisolated enum UPaneGroupGeometry {
    static func contentRect(in paneRect: CGRect, stripHeight: CGFloat) -> CGRect {
        CGRect(
            x: paneRect.minX,
            y: paneRect.minY + stripHeight,
            width: paneRect.width,
            height: max(0, paneRect.height - stripHeight))
    }
}

/// 分屏按钮的方向。
public enum UPaneSplitButtonDirection: Sendable, Hashable {
    case horizontal          // 向右开新组
    case vertical            // 向下开新组
    /// 按组当前长宽比自动选：宽多于高就左右分，否则上下分（uTerm 的 `autoSplitDirection`）。
    case automatic
}

/// 「分屏里装标签」的区域视图：`LayoutNode` 摊平成一个扁平 ZStack，叶子是带
/// 标签条的组。标签可自由拖动 —— 投到组中心 = 并入该组，投到边缘 = 在那侧分屏，
/// 投到另一个 chip = 插到它的槽位。
///
/// **内部是四层扁平结构，顺序与 zIndex 不能改：**
/// 1. 组外壳（标签条 + 空态占位 + 组级落点区），按摊平矩形定位
/// 2. **所有组的所有标签的面板**，按 `tab.id` 定身份，`zIndex(isFront ? 1 : 0)`
/// 3. 投放高亮（只画高亮的薄视图），`zIndex(2)`
/// 4. 分隔条，`zIndex(3)`
///
/// 第 2 层是关键。递归渲染时把内容挂在各自的组子树里，那么分屏、合屏、把标签
/// 拖进另一组，都会改变面板在视图树里的路径 —— SwiftUI 只能整棵拆掉重建。
/// uTable 实测（30 列 × 100 行的数据网格）：重建一个面板 ≈350ms，拆掉 ≈180ms，
/// 而摊平后的纯 resize ≈60ms。摊平之后每个标签的面板只出现一次、身份就是
/// `tab.id`，换组 / 分屏 / 合屏于是只是改 frame，重排而不重建。
public struct UPaneGroupArea<Payload, Content: View, EmptyGroup: View, StripAccessory: View, TabMenu: View>: View {
    private let model: UPaneGroupsModel<Payload>
    private let dragType: UTType
    private let stripHeight: CGFloat
    private let showsSplitButton: Bool
    private let showsActiveGroupRing: Bool
    private let splitButtonDirection: UPaneSplitButtonDirection
    private let splitButtonIcon: UPaneTabIcon
    private let descriptor: (UPaneTab<Payload>) -> UPaneTabDescriptor
    private let content: (UPaneTab<Payload>, Bool) -> Content
    private let emptyGroup: (UUID) -> EmptyGroup
    private let onRequestClose: (UPaneTab<Payload>) -> Void
    private let stripAccessory: (UUID) -> StripAccessory
    private let tabMenu: (UPaneTab<Payload>) -> TabMenu
    private let foreignDropTypes: [UTType]
    private let onForeignDrop: (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool
    private let onActiveTabChanged: ((UUID) -> Void)?

    /// 本区域的拖拽会话状态，所有组共享一份。
    @State private var dragState = UPaneDragState()
    /// 视觉风格（`.uPaneGroupStyle(_:)` 注入，默认 `.classic`）。
    @Environment(\.uPaneGroupStyle) private var style
    /// `.card` 下是否把面板画成卡内凹槽（`.uPaneGroupWells()` 注入，见 `UPaneWellMetrics`）。
    @Environment(\.uPaneGroupWells) private var wellsEnabled

    private var drawsWells: Bool { style.kind == .card && wellsEnabled }

    /// 测试用：换上一份外面持有的拖拽会话状态，好断言 `groupBounds` 之类的共享表。
    /// `@State` 只在第一次建视图时取初值，所以要在视图挂上去之前调用。
    func withDragState(_ state: UPaneDragState) -> Self {
        var copy = self
        copy._dragState = State(initialValue: state)
        return copy
    }

    /// 完整初始化器。带默认值的便捷版本见下方 extension。
    public init(
        model: UPaneGroupsModel<Payload>,
        /// 拖拽载荷的专属 UTType。**必须由 app 传入** —— `UTType(exportedAs:)`
        /// 要求在各自的 Info.plist 里登记 `UTExportedTypeDeclarations`。
        dragType: UTType,
        /// 标签条高度。uTable 38（与侧栏、AI 面板头对齐），uTerm 现在 36。
        stripHeight: CGFloat = 38,
        showsSplitButton: Bool = true,
        /// 活动组四周画一圈 1.5px accent 圆角焦点框（只在多组时画）。uTerm 的
        /// 预览区 / 终端区靠它认「焦点在哪一格」；uTable 只用 chip 顶条，默认关。
        showsActiveGroupRing: Bool = false,
        splitButtonDirection: UPaneSplitButtonDirection = .horizontal,
        /// 分屏按钮的图标。默认沿用 uTable 设计稿那枚自绘的「向右拆分」。
        splitButtonIcon: UPaneTabIcon = .glyph(.tabSplitRight),
        /// 每个 chip 自己 body 内求值 —— 见 `UPaneTabDescriptor` 的说明。
        descriptor: @escaping (UPaneTab<Payload>) -> UPaneTabDescriptor,
        /// 面板内容。`isFront` 为 false 的标签在 `.allTabs` 保活下仍然被挂载，
        /// 只是透明、不可命中。
        @ViewBuilder content: @escaping (UPaneTab<Payload>, _ isFront: Bool) -> Content,
        /// 空组占位。
        @ViewBuilder emptyGroup: @escaping (_ groupID: UUID) -> EmptyGroup,
        /// 关闭**请求**。**不是**「已关闭」—— 组件不自己关。
        ///
        /// uTable 的关闭是同步的，传 `{ tab in model.locateTab(tab.id).map { … } }`
        /// 即可；uTerm 预览区的关闭是模态 + 异步的（脏文件先弹三选一，选「保存」
        /// 时起一个 Task，保存成功才真的关，失败就不关）。组件若自己在 × 里调
        /// `closeTab`，这条流程就没地方插了。
        onRequestClose: @escaping (UPaneTab<Payload>) -> Void,
        /// 标签条右侧的额外按钮（uTerm 终端区的「＋新建终端」）。
        @ViewBuilder stripAccessory: @escaping (_ groupID: UUID) -> StripAccessory,
        /// chip 的右键菜单（uTerm 预览区的「关闭其他 / 右侧 / 全部 / 拷贝路径」）。
        @ViewBuilder tabMenu: @escaping (UPaneTab<Payload>) -> TabMenu,
        /// 外来拖拽（不是本区域标签）的落点钩子。返回 true 表示已消费。
        foreignDropTypes: [UTType] = [],
        onForeignDrop: @escaping (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool = { _, _, _ in false },
        /// 某个组切了前台标签之后的回调（组 id）。组件自己已按
        /// `policy.releasesHiddenEditorFocusOnTabSwitch` 处理隐藏编辑器的 first
        /// responder；这个钩子留给 app 的其余清理。
        onActiveTabChanged: ((UUID) -> Void)? = nil
    ) {
        self.model = model
        self.dragType = dragType
        self.stripHeight = stripHeight
        self.showsSplitButton = showsSplitButton
        self.showsActiveGroupRing = showsActiveGroupRing
        self.splitButtonDirection = splitButtonDirection
        self.splitButtonIcon = splitButtonIcon
        self.descriptor = descriptor
        self.content = content
        self.emptyGroup = emptyGroup
        self.onRequestClose = onRequestClose
        self.stripAccessory = stripAccessory
        self.tabMenu = tabMenu
        self.foreignDropTypes = foreignDropTypes
        self.onForeignDrop = onForeignDrop
        self.onActiveTabChanged = onActiveTabChanged
    }

    /// `stripHeight` 是标签栏 chrome 的完整高度；底部发丝线画在这个高度内部，
    /// 所以内容区直接从 `stripHeight` 开始。若再额外加 1pt，会让它比同高的相邻
    /// toolbar 多出一行，三栏底线无法落在同一条基线上。
    private var contentTopInset: CGFloat { stripHeight }

    public var body: some View {
        GeometryReader { geo in
            let layout = model.root.frames(in: CGRect(origin: .zero, size: geo.size))
            let wells = drawsWells
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { pane in
                    UPaneGroupChrome(
                        model: model, dragState: dragState, groupID: pane.paneID,
                        dragType: dragType, foreignDropTypes: foreignDropTypes,
                        stripHeight: stripHeight,
                        style: style,
                        bodyInsets: bodyInsets(for: pane.rect, areaSize: geo.size),
                        showsSplitButton: showsSplitButton,
                        splitButtonDirection: splitButtonDirection,
                        splitButtonIcon: splitButtonIcon,
                        descriptor: descriptor, emptyGroup: emptyGroup,
                        onRequestClose: onRequestClose,
                        stripAccessory: stripAccessory, tabMenu: tabMenu,
                        onForeignDrop: onForeignDrop,
                        onActiveTabChanged: onActiveTabChanged)
                        .frame(width: pane.rect.width, height: pane.rect.height)
                        .offset(x: pane.rect.minX, y: pane.rect.minY)
                }
                ForEach(mountedTabs(in: layout, areaSize: geo.size)) { item in
                    UPaneContentHost(
                        model: model, dragState: dragState, item: item,
                        dragType: dragType, foreignDropTypes: foreignDropTypes,
                        content: content, onForeignDrop: onForeignDrop)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .offset(x: item.rect.minX, y: item.rect.minY)
                        .zIndex(item.isFront ? 1 : 0)
                }
                if wells {
                    // 凹槽外框（角帽 / 日间窗格轮廓 / 活动组 accent 框）按组画一份，
                    // 盖在面板之上、投放高亮之下。
                    let multi = layout.panes.count > 1
                    ForEach(layout.panes, id: \.paneID) { pane in
                        let well = UPaneGroupGeometry.rect(
                            pane.rect, insetBy: bodyInsets(for: pane.rect, areaSize: geo.size))
                        UPaneWellChrome(groupID: pane.paneID, model: model,
                                        showsRings: multi,
                                        showsActiveRing: showsActiveGroupRing && multi)
                            .frame(width: well.width, height: well.height)
                            .offset(x: well.minX, y: well.minY)
                            .zIndex(1.5)
                    }
                } else if showsActiveGroupRing, layout.panes.count > 1 {
                    ForEach(layout.panes, id: \.paneID) { pane in
                        PaneFocusRing(groupID: pane.paneID, model: model)
                            .frame(width: pane.rect.width, height: pane.rect.height)
                            .offset(x: pane.rect.minX, y: pane.rect.minY)
                            .zIndex(2)
                    }
                }
                ForEach(layout.panes, id: \.paneID) { pane in
                    PaneDropOverlay(groupID: pane.paneID, dragState: dragState)
                        .frame(width: pane.rect.width, height: pane.rect.height)
                        .offset(x: pane.rect.minX, y: pane.rect.minY)
                        .zIndex(2)
                }
                ForEach(layout.splitters, id: \.splitID) { splitter in
                    UPaneSplitter(
                        orientation: splitter.direction == .horizontal ? .vertical : .horizontal,
                        fraction: Binding(
                            get: { splitter.fraction },
                            set: { model.setFraction($0, splitID: splitter.splitID) }),
                        totalLength: splitter.totalLength)
                        .frame(width: splitter.rect.width, height: splitter.rect.height)
                        .offset(x: splitter.rect.minX, y: splitter.rect.minY)
                        .zIndex(3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // 组塌缩出树就把它在 `groupBounds` 里那一格删掉：每次分屏都铸新 id，不删的话这张表
            // 只涨不跌。在这里按树上现有的组整表收，不靠组外壳的 `onDisappear` —— 那个回调
            // 什么时候发由 SwiftUI 定，可能拖到很久以后。
            .onChange(of: layout.panes.map(\.paneID)) { _, ids in
                dragState.pruneGroupBounds(keeping: Set(ids))
            }
        }
        .background(style.areaBackground)
    }

    /// 组矩形里正文（面板 / 空态）相对组矩形的内缩。默认只让出标签条；凹槽模式另把
    /// 贴区域外缘的三边各缩 6pt。
    private func bodyInsets(for paneRect: CGRect, areaSize: CGSize) -> EdgeInsets {
        guard drawsWells else {
            return EdgeInsets(top: contentTopInset, leading: 0, bottom: 0, trailing: 0)
        }
        return UPaneGroupGeometry.wellInsets(
            paneRect: paneRect, areaSize: areaSize, stripHeight: contentTopInset)
    }

    /// 该挂载哪些标签的面板，各自配上该占的内容矩形（组矩形去掉标签条）。
    /// 每个标签只出现一次、身份就是 `tab.id` —— 换组只换 frame。
    /// 挂多少由 `policy.keepAlive` 决定。
    private func mountedTabs(in layout: LayoutFrames, areaSize: CGSize) -> [MountedTab<Payload>] {
        let keepAlive = model.policy.keepAlive
        // 只有 `.activeGroupOnly` 需要知道活动组。另外两档不读：body 一读 `activeGroupID`，点进
        // 另一组（什么都没改）就让整个区域 body 重求一遍 —— 重摊几何、重建每个组外壳与面板宿主
        // 的值。面板的活动态由 `ActivePaneGateDriver` 单独观察。
        let activeGroupID = keepAlive == .activeGroupOnly ? model.resolvedActiveGroupID : nil
        return layout.panes.flatMap { pane -> [MountedTab<Payload>] in
            guard let group = model.groups[pane.paneID], !group.tabs.isEmpty else { return [] }
            if keepAlive == .activeGroupOnly && pane.paneID != activeGroupID { return [] }
            let insets = bodyInsets(for: pane.rect, areaSize: areaSize)
            let rect = drawsWells
                ? UPaneGroupGeometry.rect(pane.rect, insetBy: insets)
                : UPaneGroupGeometry.contentRect(in: pane.rect, stripHeight: contentTopInset)
            // 落点区的分区判定用**整个组**的坐标系，面板内的位置要补回这段偏移。
            let locationOffset = CGSize(width: rect.minX - pane.rect.minX,
                                        height: rect.minY - pane.rect.minY)
            return group.tabs.enumerated().compactMap { idx, tab in
                let isFront = idx == group.activeIndex
                if keepAlive != .allTabs && !isFront { return nil }
                return MountedTab(tab: tab, groupID: pane.paneID, rect: rect, isFront: isFront,
                                  locationOffset: locationOffset)
            }
        }
    }
}

// MARK: - 便捷初始化器（没有 accessory / 右键菜单时）

extension UPaneGroupArea where StripAccessory == EmptyView, TabMenu == EmptyView {
    public init(
        model: UPaneGroupsModel<Payload>,
        dragType: UTType,
        stripHeight: CGFloat = 38,
        showsSplitButton: Bool = true,
        showsActiveGroupRing: Bool = false,
        splitButtonDirection: UPaneSplitButtonDirection = .horizontal,
        splitButtonIcon: UPaneTabIcon = .glyph(.tabSplitRight),
        descriptor: @escaping (UPaneTab<Payload>) -> UPaneTabDescriptor,
        @ViewBuilder content: @escaping (UPaneTab<Payload>, _ isFront: Bool) -> Content,
        @ViewBuilder emptyGroup: @escaping (_ groupID: UUID) -> EmptyGroup,
        onRequestClose: @escaping (UPaneTab<Payload>) -> Void,
        foreignDropTypes: [UTType] = [],
        onForeignDrop: @escaping (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool = { _, _, _ in false },
        onActiveTabChanged: ((UUID) -> Void)? = nil
    ) {
        self.init(model: model, dragType: dragType, stripHeight: stripHeight,
                  showsSplitButton: showsSplitButton, showsActiveGroupRing: showsActiveGroupRing,
                  splitButtonDirection: splitButtonDirection,
                  splitButtonIcon: splitButtonIcon, descriptor: descriptor, content: content, emptyGroup: emptyGroup,
                  onRequestClose: onRequestClose,
                  stripAccessory: { _ in EmptyView() }, tabMenu: { _ in EmptyView() },
                  foreignDropTypes: foreignDropTypes, onForeignDrop: onForeignDrop,
                  onActiveTabChanged: onActiveTabChanged)
    }
}

extension UPaneGroupArea where TabMenu == EmptyView {
    public init(
        model: UPaneGroupsModel<Payload>,
        dragType: UTType,
        stripHeight: CGFloat = 38,
        showsSplitButton: Bool = true,
        showsActiveGroupRing: Bool = false,
        splitButtonDirection: UPaneSplitButtonDirection = .horizontal,
        splitButtonIcon: UPaneTabIcon = .glyph(.tabSplitRight),
        descriptor: @escaping (UPaneTab<Payload>) -> UPaneTabDescriptor,
        @ViewBuilder content: @escaping (UPaneTab<Payload>, _ isFront: Bool) -> Content,
        @ViewBuilder emptyGroup: @escaping (_ groupID: UUID) -> EmptyGroup,
        onRequestClose: @escaping (UPaneTab<Payload>) -> Void,
        @ViewBuilder stripAccessory: @escaping (_ groupID: UUID) -> StripAccessory,
        foreignDropTypes: [UTType] = [],
        onForeignDrop: @escaping (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool = { _, _, _ in false },
        onActiveTabChanged: ((UUID) -> Void)? = nil
    ) {
        self.init(model: model, dragType: dragType, stripHeight: stripHeight,
                  showsSplitButton: showsSplitButton, showsActiveGroupRing: showsActiveGroupRing,
                  splitButtonDirection: splitButtonDirection,
                  splitButtonIcon: splitButtonIcon, descriptor: descriptor, content: content, emptyGroup: emptyGroup,
                  onRequestClose: onRequestClose,
                  stripAccessory: stripAccessory, tabMenu: { _ in EmptyView() },
                  foreignDropTypes: foreignDropTypes, onForeignDrop: onForeignDrop,
                  onActiveTabChanged: onActiveTabChanged)
    }
}

extension UPaneGroupArea where StripAccessory == EmptyView {
    public init(
        model: UPaneGroupsModel<Payload>,
        dragType: UTType,
        stripHeight: CGFloat = 38,
        showsSplitButton: Bool = true,
        showsActiveGroupRing: Bool = false,
        splitButtonDirection: UPaneSplitButtonDirection = .horizontal,
        splitButtonIcon: UPaneTabIcon = .glyph(.tabSplitRight),
        descriptor: @escaping (UPaneTab<Payload>) -> UPaneTabDescriptor,
        @ViewBuilder content: @escaping (UPaneTab<Payload>, _ isFront: Bool) -> Content,
        @ViewBuilder emptyGroup: @escaping (_ groupID: UUID) -> EmptyGroup,
        onRequestClose: @escaping (UPaneTab<Payload>) -> Void,
        @ViewBuilder tabMenu: @escaping (UPaneTab<Payload>) -> TabMenu,
        foreignDropTypes: [UTType] = [],
        onForeignDrop: @escaping (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool = { _, _, _ in false },
        onActiveTabChanged: ((UUID) -> Void)? = nil
    ) {
        self.init(model: model, dragType: dragType, stripHeight: stripHeight,
                  showsSplitButton: showsSplitButton, showsActiveGroupRing: showsActiveGroupRing,
                  splitButtonDirection: splitButtonDirection,
                  splitButtonIcon: splitButtonIcon, descriptor: descriptor, content: content, emptyGroup: emptyGroup,
                  onRequestClose: onRequestClose,
                  stripAccessory: { _ in EmptyView() }, tabMenu: tabMenu,
                  foreignDropTypes: foreignDropTypes, onForeignDrop: onForeignDrop,
                  onActiveTabChanged: onActiveTabChanged)
    }
}

// MARK: - 已挂载的面板

/// 一个已挂载的面板：标签、它当前所属的组、该占的内容矩形。
///
/// **文档解析要在区域这一层做完、往下传值。** 组件不替 app 做这件事（载荷无约束，
/// 它也做不了），但 app 必须做：把 `[tabID: 文档]` 在 `UPaneGroupArea` **之上**
/// 算好、捕获进 `content` 闭包，而不是让每个面板自己在 body 里扫那个
/// `@Observable` 数组 —— uTable 实测「每挂一个数据网格多 60ms，开/关任意标签都
/// 要付」。
struct MountedTab<Payload>: Identifiable {
    let tab: UPaneTab<Payload>
    let groupID: UUID
    let rect: CGRect
    let isFront: Bool
    /// 面板矩形相对组矩形的偏移（投放分区判定换算用）。
    let locationOffset: CGSize
    var id: UUID { tab.id }
}

/// 承载一个标签的面板内容。保活语义：非前台标签留在树上，只是透明且不可命中 ——
/// 切标签是纯透明度翻转，不是重建。
private struct UPaneContentHost<Payload, Content: View>: View {
    let model: UPaneGroupsModel<Payload>
    let dragState: UPaneDragState
    let item: MountedTab<Payload>
    let dragType: UTType
    let foreignDropTypes: [UTType]
    let content: (UPaneTab<Payload>, Bool) -> Content
    let onForeignDrop: (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool

    /// 身份稳定的「本面板是不是活动面板」信号 —— 见 `ActivePaneGate`。
    @State private var gate = ActivePaneGate(isActive: false)

    var body: some View {
        content(item.tab, item.isFront)
            // `minWidth/minHeight: 0` 不能省：flexible frame 没有下限时会跟着内容的
            // 最小尺寸撑大，再被外层 `.frame(width:height:)` 居中摆进面板矩形 ——
            // 内容一宽过面板就两侧一起溢出、盖到相邻编辑组上，而下面的 `.clipped()`
            // 裁的是撑大后的帧，拦不住。
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                   alignment: .topLeading)
            .clipped()   // AppKit 内容不许画到自己的面板外面
            .opacity(item.isFront ? 1 : 0)
            .environment(\.activePaneGate, gate)
            // 活动态只由这个薄视图观察：宿主 body 不读 `activeGroupID`，切活动组时只有它重求，
            // 面板内容不动。以前宿主为了 `onChange` 自己读它，每次点进别的组都要把 app 的
            // `content` 对每个已挂载标签再调一遍（`testFocusingAnotherGroupDoesNotReinvokeContent`）。
            .background {
                ActivePaneGateDriver(model: model, groupID: item.groupID,
                                     isFront: item.isFront, gate: gate)
            }
            // 面板盖在组外壳上面，所以落点区得挂在这里一份（外壳那份只剩标签条与
            // 空组）。位置换算要补上标签条的高度：分区判定用的是**整个组**的坐标系。
            .onDrop(of: [dragType] + foreignDropTypes, delegate: UPaneGroupDropDelegate(
                targetID: item.groupID,
                dragState: dragState,
                dragType: dragType,
                foreignTypes: foreignDropTypes,
                locationOffset: item.locationOffset,
                onDrop: { sourceTab, zone in
                    model.moveTab(sourceTab, toGroup: item.groupID, zone: zone)
                },
                onForeignDrop: onForeignDrop))
            // 面板里任意一次按下都把它那一组变成活动组。SwiftUI 手势只覆盖得到
            // SwiftUI 内容：AppKit 子视图（NSTableView / NSTextView / 终端视图）
            // 自己吃掉 mouseDown，挂在祖先上的 SwiftUI 点击手势**永不触发**。
            // 用 NSEvent 旁观探针补上：不消费事件、对命中测试透明。
            .simultaneousGesture(TapGesture().onEnded { model.focusGroup(item.groupID) })
            // 同组的后台标签和前台标签矩形完全重合，必须按前台过滤，否则一次点击会被同组每个
            // 已挂载标签各响应一次。后台面板干脆不装监视器（`.allTabs` 下每次按下都要过一遍
            // 所有面板的监视器），闭包里的判断留作兜底。
            .onPointerDown(isEnabled: item.isFront) {
                if item.isFront { model.focusGroup(item.groupID) }
            }
            // 最外层：隐藏的标签既不该被点到，也不该抢落点。
            .allowsHitTesting(item.isFront)
            .accessibilityHidden(!item.isFront)
    }
}

/// 把「本面板是不是活动面板」写进 `ActivePaneGate`。**唯一**为面板读 `activeGroupID` 的地方：
/// 切活动组时失效重求的只有这个空视图，面板宿主与 app 的内容都不动。
private struct ActivePaneGateDriver<Payload>: View {
    let model: UPaneGroupsModel<Payload>
    let groupID: UUID
    let isFront: Bool
    let gate: ActivePaneGate

    var body: some View {
        let isActive = isFront && model.resolvedActiveGroupID == groupID
        Color.clear
            .onChange(of: isActive, initial: true) { _, now in gate.isActive = now }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 投放区高亮（独立观察 dragState）

/// 只画投放区高亮的薄视图。**唯一读 `UPaneDragState` 观察属性的地方** —— 拖拽
/// 期间失效重算的就只有它，组本体和里面的内容一概不动。
private struct PaneDropOverlay: View {
    let groupID: UUID
    let dragState: UPaneDragState

    var body: some View {
        let zone = paneDropHighlightZone(
            groupID: groupID,
            draggingTabID: dragState.draggingTabID,
            draggingSourceGroupID: dragState.draggingSourceGroupID,
            hover: dragState.hover)
        if let zone {
            PaneDropHighlight(zone: zone)
        }
    }
}

/// 活动组的 1.5px accent 焦点框。和 `PaneDropOverlay` 一样是**独立的薄视图**：
/// 唯一读 `activeGroupID` 来画边框的地方，切活动组时失效重算的就只有它，组本体和
/// 里面挂着的内容一概不动。
private struct PaneFocusRing<Payload>: View {
    let groupID: UUID
    let model: UPaneGroupsModel<Payload>

    var body: some View {
        let isActive = model.resolvedActiveGroupID == groupID
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isActive ? UD.accent : Color.clear, lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}

// MARK: - 一个组的外壳（标签条 + 空态 + 组级落点区）

private struct UPaneGroupChrome<Payload, EmptyGroup: View, StripAccessory: View, TabMenu: View>: View {
    let model: UPaneGroupsModel<Payload>
    let dragState: UPaneDragState
    let groupID: UUID
    let dragType: UTType
    let foreignDropTypes: [UTType]
    let stripHeight: CGFloat
    let style: UPaneGroupStyle
    /// 正文（空态占位）相对组矩形的内缩；顶边即标签条高度。
    let bodyInsets: EdgeInsets
    let showsSplitButton: Bool
    let splitButtonDirection: UPaneSplitButtonDirection
    let splitButtonIcon: UPaneTabIcon
    let descriptor: (UPaneTab<Payload>) -> UPaneTabDescriptor
    let emptyGroup: (UUID) -> EmptyGroup
    let onRequestClose: (UPaneTab<Payload>) -> Void
    let stripAccessory: (UUID) -> StripAccessory
    let tabMenu: (UPaneTab<Payload>) -> TabMenu
    let onForeignDrop: (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool
    let onActiveTabChanged: ((UUID) -> Void)?

    private var group: UPaneGroup<Payload>? { model.groups[groupID] }

    private var splitAllowed: Bool {
        guard let cap = model.policy.splitButtonMaxGroups else { return true }
        return model.groupCount < cap
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            // 内容由区域的扁平面板层画（见 `UPaneGroupArea.mountedTabs`），
            // 这里只剩空组占位和底色。
            Group {
                if group?.tabs.isEmpty ?? true {
                    emptyGroup(groupID)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, bodyInsets.leading)
            .padding(.trailing, bodyInsets.trailing)
            .padding(.bottom, bodyInsets.bottom)
        }
        .background(style.areaBackground)
        // 把本组当前尺寸实时写进共享拖拽状态，供投放代理的分区判定读取。
        // 不能让 delegate 捕获尺寸 —— 窗口 resize 后会变旧，见 `groupBounds`。
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            dragState.groupBounds[groupID] = CGRect(origin: .zero, size: size)
        }
        .onDrop(of: [dragType] + foreignDropTypes, delegate: UPaneGroupDropDelegate(
            targetID: groupID,
            dragState: dragState,
            dragType: dragType,
            foreignTypes: foreignDropTypes,
            onDrop: { sourceTab, zone in
                model.moveTab(sourceTab, toGroup: groupID, zone: zone)
            },
            onForeignDrop: onForeignDrop))
        // 组内任意一次按下都把它变成活动组。simultaneous 保证标签 / 关闭 /
        // 内部按钮照常触发。
        .simultaneousGesture(TapGesture().onEnded { model.focusGroup(groupID) })
        // 按**前台标签的 id** 判「切了前台标签」，不按下标：关掉不是最后一枚的前台标签、预览标签
        // 原地顶替、把下标 0 的标签拖去别的组，前台都换了人而下标没变。反过来，拖着前台标签在
        // 本组里换位置只改下标、前台还是它，也不该当成切标签。
        .onChange(of: group?.activeTab?.id) { _, _ in
            if model.policy.releasesHiddenEditorFocusOnTabSwitch {
                UPaneFocusRelease.releaseHiddenEditorFocus()
            }
            onActiveTabChanged?(groupID)
        }
    }

    /// 标签条整条挂一个只做重排的落点区（见 `UPaneTabStripDropDelegate`）。chip
    /// 自己的重排代理在里层，先命中；落在 chip 之外的位置由它接住，不再漏给外层
    /// 组外壳的 5 分区判定。
    private var tabStrip: some View {
        tabStripContent
            .contentShape(Rectangle())
            .onDrop(of: [dragType], delegate: UPaneTabStripDropDelegate(
                groupID: groupID,
                dragState: dragState,
                dragType: dragType,
                onDropAtEnd: { sourceTab in
                    model.moveTabToEnd(sourceTab, ofGroup: groupID)
                },
                onCommit: { sourceTab, slot in
                    model.moveTab(sourceTab, to: slot, inGroup: groupID)
                }))
    }

    @ViewBuilder
    private var tabStripContent: some View {
        switch style.kind {
        case .classic: classicTabStrip
        case .card: cardTabStrip
        }
    }

    private func chip(index idx: Int, tab: UPaneTab<Payload>) -> some View {
        UPaneTabChip(
            tab: tab,
            activity: model.tabActivity(groupID: groupID, index: idx),
            descriptor: descriptor,
            tabMenu: tabMenu,
            dragState: dragState,
            dragType: dragType,
            groupID: groupID,
            stripHeight: stripHeight,
            style: style,
            onActivate: { model.activateTab(groupID: groupID, index: idx) },
            onClose: { onRequestClose(tab) },
            tabs: { model.groups[groupID]?.tabs.map(\.id) ?? [] },
            onReorder: { source, target in model.reorderTab(source, before: target) },
            onCommit: { source, slot in model.moveTab(source, to: slot, inGroup: groupID) })
    }

    /// 标签条上的一排 chip。拖动排序时按落位实时重排（见 `UPaneTabRow`）。
    private func tabRow(spacing: CGFloat) -> some View {
        let tabs = group?.tabs ?? []
        return UPaneTabRow(tabIDs: tabs.map(\.id), groupID: groupID, dragState: dragState,
                           spacing: spacing) { id in
            if let idx = tabs.firstIndex(where: { $0.id == id }) {
                chip(index: idx, tab: tabs[idx])
            }
        }
    }

    /// `.card`：标签条透出卡面；胶囊之间 2pt，左右内边距 8，右侧按钮 26×26 无竖线。
    /// 默认无底线，`stripDivider` 打开时在条内底部画 1pt 线（含在 `stripHeight` 里）。
    private var cardTabStrip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                tabRow(spacing: 2)
                    .frame(height: stripHeight)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            stripAccessory(groupID)

            if (group?.tabs.isEmpty ?? true), model.groupCount > 1 {
                UPaneCardStripButton(accessibilityLabel: String(localized: "关闭空分组", bundle: ModuleBundle.bundle,
                                                                comment: "标签条右侧图标钮的辅助功能名字：收掉这个没有标签的分屏分组"),
                                     help: String(localized: "关闭这个空分组（⌘W）", bundle: ModuleBundle.bundle),
                                     action: { model.closeEmptyGroup(groupID: groupID) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }

            if showsSplitButton, splitAllowed {
                UPaneCardStripButton(accessibilityLabel: String(localized: "拆分分组", bundle: ModuleBundle.bundle,
                                                                comment: "标签条右侧图标钮的辅助功能名字：在旁边开一个新的分屏分组"),
                                     help: String(localized: "拆分出一个新分组（⌘\\，或直接拖动标签到区域边缘）", bundle: ModuleBundle.bundle),
                                     action: { model.splitGroup(groupID, direction: resolvedSplitDirection()) }) {
                    UPaneTabIconView(icon: splitButtonIcon, size: 14)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: stripHeight)
        .overlay(alignment: .bottom) {
            if style.stripDivider {
                Rectangle().fill(UD.border).frame(height: 1)
            }
        }
    }

    private var classicTabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                tabRow(spacing: 0)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            stripAccessory(groupID)

            // 空组（分屏按钮开出来的）没有标签可关 —— 给它一个显式的关闭入口，
            // 否则唯一的出路是拖个标签进来再关掉。
            if (group?.tabs.isEmpty ?? true), model.groupCount > 1 {
                Rectangle().fill(UD.border).frame(width: 1)
                Button { model.closeEmptyGroup(groupID: groupID) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UD.text3)
                        .frame(width: 34, height: stripHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.udPlain)
                .help(String(localized: "关闭这个空分组（⌘W）", bundle: ModuleBundle.bundle))
                .accessibilityLabel(Text("关闭空分组", bundle: ModuleBundle.bundle,
                                         comment: "标签条右侧图标钮的辅助功能名字：收掉这个没有标签的分屏分组"))
            }

            if showsSplitButton, splitAllowed {
                Rectangle().fill(UD.border).frame(width: 1)
                Button { model.splitGroup(groupID, direction: resolvedSplitDirection()) } label: {
                    UPaneTabIconView(icon: splitButtonIcon, size: 14)
                        .foregroundStyle(UD.text3)
                        .frame(width: 34, height: stripHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.udPlain)
                .help(String(localized: "拆分出一个新分组（⌘\\，或直接拖动标签到区域边缘）", bundle: ModuleBundle.bundle))
                .accessibilityLabel(Text("拆分分组", bundle: ModuleBundle.bundle,
                                         comment: "标签条右侧图标钮的辅助功能名字：在旁边开一个新的分屏分组"))
            }
        }
        .frame(height: stripHeight)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    /// `.automatic` 要读组的当前尺寸。在**点击回调里**读 `groupBounds`（一个
    /// `@ObservationIgnored` 属性），既拿得到最新值，又不给 body 建依赖。
    private func resolvedSplitDirection() -> SplitDirection {
        switch splitButtonDirection {
        case .horizontal: return .horizontal
        case .vertical:   return .vertical
        case .automatic:
            let size = dragState.groupBounds[groupID]?.size ?? .zero
            return size.width >= size.height ? .horizontal : .vertical
        }
    }
}

// MARK: - 标签条上的一排 chip（拖动排序动画）

/// 一排 chip。**单独成视图**：只有它读 `reorderPreview`，拖动排序期间失效重算的就只有这一排，组外壳不动。
///
/// 同组拖动时按落位实时重排：其余标签滑过去让位（`UPaneTabReorder.animation`）；被拖的那枚在新位置
/// 留一个空槽（光标下已经有系统画的拖拽图，原位不再画一遍标签）。空槽**不参与滑动**、直接跳到新槽位——
/// 让位时邻居一次只挪一格，空槽也滑的话两者会在半路叠在一起。松手落在空槽上（模型改成的顺序与显示的
/// 一致，不会再跳），空槽 0.2s 淡回成标签。「减弱动态效果」打开时不滑，淡入淡出照旧（不是位移）。
/// 时长与曲线与 iOS 工作区标签条一致。
struct UPaneTabRow<Chip: View>: View {
    let tabIDs: [UUID]
    let groupID: UUID
    let dragState: UPaneDragState
    let spacing: CGFloat
    /// 测试用：系统的「减弱动态效果」读不到可写的环境值，用它代替。
    var reduceMotionOverride: Bool? = nil
    @ViewBuilder let chip: (UUID) -> Chip

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    struct Arrangement: Equatable {
        var order: [UUID]
        var placeholder: UUID?
    }

    static func arrangement(tabIDs: [UUID], groupID: UUID, dragState: UPaneDragState) -> Arrangement {
        let preview = dragState.reorderPreview?.groupID == groupID ? dragState.reorderPreview : nil
        let source = preview == nil ? nil : dragState.draggingTabID
        return Arrangement(order: UPaneTabReorder.displayOrder(tabIDs, source: source, slot: preview?.slot),
                           placeholder: source)
    }

    var body: some View {
        let arrangement = Self.arrangement(tabIDs: tabIDs, groupID: groupID, dragState: dragState)
        HStack(spacing: spacing) {
            ForEach(arrangement.order, id: \.self) { id in
                let isPlaceholder = id == arrangement.placeholder
                chip(id)
                    .opacity(isPlaceholder ? 0 : 1)
                    .background {
                        RoundedRectangle(cornerRadius: UPaneGroupStyle.pillRadius, style: .continuous)
                            .fill(UD.panelHover)
                            .frame(height: UPaneGroupStyle.pillHeight)
                            .opacity(isPlaceholder ? 1 : 0)
                    }
                    // 变成空槽是瞬时的，落回标签是淡出。
                    .animation(isPlaceholder ? nil : UPaneTabReorder.landing, value: isPlaceholder)
                    // 空槽自己的位置变化不做动画（见上）。
                    .transaction { if isPlaceholder { $0.animation = nil } }
            }
        }
        .animation(reduceMotion ? nil : UPaneTabReorder.animation, value: arrangement.order)
    }
}

// MARK: - 标签条上的一枚 chip

/// 活动态 = 2px accent 顶条 + accent 图标 + 正文强度标题，**不填灰底**；非选中项
/// 保留 hover 反馈；右侧 1px 分隔线。
///
/// 顶条只归当前标签：全区域就这一条 accent。别的组的前台标签靠文字强度（正文层
/// vs 次要层）与后台标签区分，不画压暗的顶条 —— 两条深浅不一的条子摆在一起，
/// 反而要比对才看得出哪条是当前的。
private struct UPaneTabChip<Payload, TabMenu: View>: View {
    let tab: UPaneTab<Payload>
    let activity: UPaneTabActivity
    /// **在本视图的 body 里求值**，不是在标签条里先算成数组。见 `UPaneTabDescriptor`。
    let descriptor: (UPaneTab<Payload>) -> UPaneTabDescriptor
    let tabMenu: (UPaneTab<Payload>) -> TabMenu
    let dragState: UPaneDragState
    let dragType: UTType
    let groupID: UUID
    let stripHeight: CGFloat
    let style: UPaneGroupStyle
    let onActivate: () -> Void
    let onClose: () -> Void
    let tabs: @MainActor () -> [UUID]
    let onReorder: @MainActor @Sendable (_ source: UUID, _ target: UUID) -> Void
    let onCommit: @MainActor @Sendable (_ source: UUID, _ slot: UPaneReorderSlot) -> Void

    @State private var hovering = false
    @State private var hoveringClose = false

    /// 前台标签（含非焦点组的那一个）不吃 hover 反馈，也不再画灰底。
    private var isFront: Bool { activity != .inactive }

    private func iconColor(_ d: UPaneTabDescriptor) -> Color {
        switch activity {
        case .active:         return d.accentColor ?? UD.accent
        case .frontUnfocused: return UD.text2
        case .inactive:       return UD.text3
        }
    }

    private var titleColor: Color {
        switch activity {
        case .active:         return UD.text
        case .frontUnfocused: return UD.text2
        case .inactive:       return UD.text3
        }
    }

    /// `UPaneTab.customTitle` **覆盖** descriptor 派生出的标题（uTable 的已保存
    /// 查询用保存的名字而不是「查询 N」；uTerm 终端标签用服务器名）。
    private func title(_ d: UPaneTabDescriptor) -> String { tab.customTitle ?? d.title }

    var body: some View {
        let d = descriptor(tab)
        chip(d)
            .contentShape(Rectangle())
            // **按下即激活**，对齐原生标签栏 / 浏览器标签（`.onTapGesture` 的抬起
            // 触发读起来像输入延迟）。走事件旁观而不是 SwiftUI 手势：任何在按下瞬间就
            // 响应的手势（即使 simultaneous 的 `DragGesture(minimumDistance: 0)`
            // 或 `onLongPressGesture(0.01s)`）都会抢占鼠标事件流，同一视图上的
            // SwiftUI 拖放跟着失灵。（探针实测：`.onDrag` 被 DragGesture 稳定阻断，
            // LongPress 时序竞态偶发阻断。）
            .onPointerDown {
                if !hoveringClose { onActivate() }
            }
            .onHover { hovering = $0 }
            // 不用 SwiftUI 的 `.onDrag`：它没有位移死区，点击时手一抖就起拖、预览闪出来。
            .dragSource(canBegin: { !hoveringClose }) {
                dragState.begin(tabID: tab.id, groupID: groupID)
                return UPaneTabDragPayload.pasteboardItem(tabID: tab.id, type: dragType)
            } preview: {
                UPaneTabDragPreviewChip(title: title(d), icon: d.icon)
            }
            .onDrop(of: [dragType], delegate: UPaneTabReorderDropDelegate(
                targetTabID: tab.id,
                groupID: groupID,
                dragState: dragState,
                dragType: dragType,
                tabs: tabs,
                onReorder: onReorder,
                onCommit: onCommit))
            // 拖动排序按光标在左半还是右半判落位，要知道自己多宽。
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                dragState.chipWidths[tab.id] = width
            }
            .onDisappear { dragState.chipWidths[tab.id] = nil }
            .modifier(OptionalContextMenu(isEnabled: TabMenu.self != EmptyView.self,
                                          menu: { tabMenu(tab) }))
            .help(d.help ?? title(d))
            // 对 VoiceOver 是**一个**标签：按下（AX 默认动作）= 切到它，前台标签带「已选中」，
            // × 收成一个具名动作。激活本来只走 NSEvent 旁观（`onPointerDown`），辅助功能的
            // 按下不产生鼠标事件，不补这一层的话 VoiceOver 根本切不了标签、也听不出哪个是当前的。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title(d))
            .accessibilityAddTraits(isFront ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { onActivate() }
            .accessibilityAction(named: Text("关闭", bundle: ModuleBundle.bundle, comment: "关闭标签页")) {
                onClose()
            }
    }

    @ViewBuilder
    private func chip(_ d: UPaneTabDescriptor) -> some View {
        switch style.kind {
        case .classic: classicChip(d)
        case .card: cardChip(d)
        }
    }

    /// `.card`：26 高胶囊。前台标签（含非焦点组的那一枚）填 `UD.panelHi`，后台标签透明、
    /// 悬停 `panelHover`；没有 accent 顶条与竖线 —— 活动组的前台标签图标走 accent、标题
    /// 正文强度，「哪一组是活动组」另可由焦点框表达（`showsActiveGroupRing`）。
    @ViewBuilder
    private func cardChip(_ d: UPaneTabDescriptor) -> some View {
        HStack(spacing: 7) {
            if let dot = d.leadingDot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if case .none = d.icon {} else {
                UPaneTabIconView(icon: d.icon, size: 12)
                    .foregroundStyle(iconColor(d))
            }
            Text(title(d))
                .font(UD.mono(12))
                .italic(tab.isTransient)
                .foregroundStyle(hovering && !isFront ? UD.text2 : titleColor)
                .lineLimit(1)
                .fixedSize()
            if d.isDirty {
                Circle().fill(d.accentColor ?? UD.accent).frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hoveringClose ? UD.text
                                     : (isFront || hovering ? UD.text3 : Color.clear))
                    .frame(width: 18, height: 18)
                    .background(hoveringClose ? UD.panelHover : Color.clear,
                                in: .rect(cornerRadius: 5, style: .circular))
            }
            .buttonStyle(.udPlain)
            .onHover { hoveringClose = $0 }
            .help(String(localized: "关闭", bundle: ModuleBundle.bundle, comment: "关闭标签页"))
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: UPaneGroupStyle.pillHeight)
        .background(isFront ? UD.panelHi : (hovering ? UD.panelHover : Color.clear),
                    in: .rect(cornerRadius: UPaneGroupStyle.pillRadius, style: .continuous))
    }

    @ViewBuilder
    private func classicChip(_ d: UPaneTabDescriptor) -> some View {
        HStack(spacing: 7) {
            if let dot = d.leadingDot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if case .none = d.icon {} else {
                UPaneTabIconView(icon: d.icon, size: 13)
                    .foregroundStyle(iconColor(d))
            }
            Text(title(d))
                .font(UD.font(12.5))
                .italic(tab.isTransient)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .fixedSize()
            if d.isDirty {
                Circle().fill(d.accentColor ?? UD.accent).frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hoveringClose ? UD.text : UD.text2)
                    .frame(width: 22, height: 22)
                    .background(hoveringClose ? UD.panelHover : Color.clear,
                                in: .rect(cornerRadius: 5, style: .circular))
            }
            .buttonStyle(.udPlain)
            .onHover { hoveringClose = $0 }
            .help(String(localized: "关闭", bundle: ModuleBundle.bundle, comment: "关闭标签页"))
        }
        .padding(.leading, 12).padding(.trailing, 7)
        .frame(height: stripHeight)
        .background(!isFront && hovering ? UD.panelHover : Color.clear)
        .overlay(alignment: .top) {
            if activity == .active { Rectangle().fill(UD.accent).frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(UD.border).frame(width: 1)
        }
    }
}

/// `TabMenu == EmptyView` 时不挂 `.contextMenu` —— 挂了会弹出一个空菜单。
private struct OptionalContextMenu<Menu: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}

/// AppKit 拖拽预览：一枚跟随光标的标签小卡片。
private struct UPaneTabDragPreviewChip: View {
    let title: String
    let icon: UPaneTabIcon

    var body: some View {
        HStack(spacing: 6) {
            if case .none = icon {} else {
                UPaneTabIconView(icon: icon, size: 12)
                    .foregroundStyle(UD.text3)
            }
            Text(title)
                .font(UD.font(12))
                .foregroundStyle(UD.text2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(UD.overlay, in: .rect(cornerRadius: 7, style: .circular))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(UD.borderHi, lineWidth: 1) }
    }
}
#endif
