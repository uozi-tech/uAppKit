#if os(macOS)
import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import UniformTypeIdentifiers
import UPaneTree

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

    /// 标签条高度 + 其下 1px 分隔线 = 组内容区的顶部偏移。
    private var contentTopInset: CGFloat { stripHeight + 1 }

    public var body: some View {
        GeometryReader { geo in
            let layout = model.root.frames(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneID) { pane in
                    UPaneGroupChrome(
                        model: model, dragState: dragState, groupID: pane.paneID,
                        dragType: dragType, foreignDropTypes: foreignDropTypes,
                        stripHeight: stripHeight,
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
                ForEach(mountedTabs(in: layout)) { item in
                    UPaneContentHost(
                        model: model, dragState: dragState, item: item,
                        dragType: dragType, foreignDropTypes: foreignDropTypes,
                        contentTopInset: contentTopInset,
                        content: content, onForeignDrop: onForeignDrop)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .offset(x: item.rect.minX, y: item.rect.minY)
                        .zIndex(item.isFront ? 1 : 0)
                }
                if showsActiveGroupRing, layout.panes.count > 1 {
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
        }
        .background(UD.bg)
    }

    /// 该挂载哪些标签的面板，各自配上该占的内容矩形（组矩形去掉标签条）。
    /// 每个标签只出现一次、身份就是 `tab.id` —— 换组只换 frame。
    /// 挂多少由 `policy.keepAlive` 决定。
    private func mountedTabs(in layout: LayoutFrames) -> [MountedTab<Payload>] {
        let keepAlive = model.policy.keepAlive
        let activeGroupID = model.activeGroupID ?? model.root.firstLeafID
        return layout.panes.flatMap { pane -> [MountedTab<Payload>] in
            guard let group = model.groups[pane.paneID], !group.tabs.isEmpty else { return [] }
            let isActiveGroup = pane.paneID == activeGroupID
            if keepAlive == .activeGroupOnly && !isActiveGroup { return [] }
            let rect = CGRect(
                x: pane.rect.minX,
                y: pane.rect.minY + contentTopInset,
                width: pane.rect.width,
                height: max(0, pane.rect.height - contentTopInset))
            return group.tabs.enumerated().compactMap { idx, tab in
                let isFront = idx == group.activeIndex
                if keepAlive != .allTabs && !isFront { return nil }
                return MountedTab(tab: tab, groupID: pane.paneID, rect: rect, isFront: isFront)
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
    let contentTopInset: CGFloat
    let content: (UPaneTab<Payload>, Bool) -> Content
    let onForeignDrop: (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool

    /// 身份稳定的「本面板是不是活动面板」信号 —— 见 `ActivePaneGate`。
    @State private var gate = ActivePaneGate(isActive: false)

    private var isActivePane: Bool {
        item.isFront && (model.activeGroupID ?? model.root.firstLeafID) == item.groupID
    }

    var body: some View {
        content(item.tab, item.isFront)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()   // AppKit 内容不许画到自己的面板外面
            .opacity(item.isFront ? 1 : 0)
            .environment(\.activePaneGate, gate)
            .onChange(of: isActivePane, initial: true) { _, now in gate.isActive = now }
            // 面板盖在组外壳上面，所以落点区得挂在这里一份（外壳那份只剩标签条与
            // 空组）。位置换算要补上标签条的高度：分区判定用的是**整个组**的坐标系。
            .onDrop(of: [dragType] + foreignDropTypes, delegate: UPaneGroupDropDelegate(
                targetID: item.groupID,
                dragState: dragState,
                dragType: dragType,
                foreignTypes: foreignDropTypes,
                locationOffset: CGSize(width: 0, height: contentTopInset),
                onDrop: { sourceTab, zone in
                    model.moveTab(sourceTab, toGroup: item.groupID, zone: zone)
                },
                onForeignDrop: onForeignDrop))
            // 面板里任意一次按下都把它那一组变成活动组。SwiftUI 手势只覆盖得到
            // SwiftUI 内容：AppKit 子视图（NSTableView / NSTextView / 终端视图）
            // 自己吃掉 mouseDown，挂在祖先上的 SwiftUI 点击手势**永不触发**。
            // 用 NSEvent 旁观探针补上：不消费事件、对命中测试透明。
            .simultaneousGesture(TapGesture().onEnded { model.focusGroup(item.groupID) })
            .onPointerDown {
                // 同组的后台标签和前台标签矩形完全重合，必须按前台过滤，
                // 否则一次点击会被同组每个已挂载标签各响应一次。
                if item.isFront { model.focusGroup(item.groupID) }
            }
            // 最外层：隐藏的标签既不该被点到，也不该抢落点。
            .allowsHitTesting(item.isFront)
            .accessibilityHidden(!item.isFront)
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
        let isActive = (model.activeGroupID ?? model.root.firstLeafID) == groupID
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
            Rectangle().fill(UD.border).frame(height: 1)
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
        }
        .background(UD.bg)
        // 把本组当前尺寸实时写进共享拖拽状态，供投放代理的分区判定读取。
        // 不能让 delegate 捕获尺寸 —— 窗口 resize 后会变旧，见 `groupBounds`。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { dragState.groupBounds[groupID] = CGRect(origin: .zero, size: geo.size) }
                    .onChange(of: geo.size) { _, newSize in
                        dragState.groupBounds[groupID] = CGRect(origin: .zero, size: newSize)
                    }
            }
        )
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
        .onChange(of: group?.activeIndex) { _, _ in
            if model.policy.releasesHiddenEditorFocusOnTabSwitch {
                UPaneFocusRelease.releaseHiddenEditorFocus()
            }
            onActiveTabChanged?(groupID)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array((group?.tabs ?? []).enumerated()), id: \.element.id) { idx, tab in
                        UPaneTabChip(
                            tab: tab,
                            activity: model.tabActivity(groupID: groupID, index: idx),
                            descriptor: descriptor,
                            tabMenu: tabMenu,
                            dragState: dragState,
                            dragType: dragType,
                            groupID: groupID,
                            stripHeight: stripHeight,
                            onActivate: { model.activateTab(groupID: groupID, index: idx) },
                            onClose: { onRequestClose(tab) },
                            onReorder: { source, target in model.reorderTab(source, before: target) })
                    }
                }
            }
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
                .buttonStyle(.plain)
                .help("关闭这个空分组（⌘W）")
            }

            if showsSplitButton, splitAllowed {
                Rectangle().fill(UD.border).frame(width: 1)
                Button { model.splitGroup(groupID, direction: resolvedSplitDirection()) } label: {
                    UPaneTabIconView(icon: splitButtonIcon, size: 14)
                        .foregroundStyle(UD.text3)
                        .frame(width: 34, height: stripHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("拆分出一个新分组（⌘\\，或直接拖动标签到区域边缘）")
            }
        }
        .frame(height: stripHeight)
        .background(UD.panel)
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
    let onActivate: () -> Void
    let onClose: () -> Void
    let onReorder: @MainActor @Sendable (_ source: UUID, _ target: UUID) -> Void

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
            // 触发读起来像输入延迟）。不能用 SwiftUI 手势实现：任何在按下瞬间就
            // 响应的手势（即使 simultaneous 的 `DragGesture(minimumDistance: 0)`
            // 或 `onLongPressGesture(0.01s)`）都会抢占鼠标事件流，外层 `.onDrag`
            // 的 AppKit 拖拽会话永远起不来 —— 标签就拖不动、拖拽分屏整套没了。
            // （探针实测：DragGesture 稳定阻断，LongPress 时序竞态偶发阻断。）
            .onPointerDown {
                if !hoveringClose { onActivate() }
            }
            .onHover { hovering = $0 }
            .onDrag {
                dragState.begin(tabID: tab.id, groupID: groupID)
                return UPaneTabDragPayload.itemProvider(tabID: tab.id, type: dragType)
            } preview: {
                UPaneTabDragPreviewChip(title: title(d), icon: d.icon)
            }
            .onDrop(of: [dragType], delegate: UPaneTabReorderDropDelegate(
                targetTabID: tab.id,
                dragState: dragState,
                dragType: dragType,
                onReorder: onReorder))
            .modifier(OptionalContextMenu(isEnabled: TabMenu.self != EmptyView.self,
                                          menu: { tabMenu(tab) }))
            .help(d.help ?? title(d))
    }

    @ViewBuilder
    private func chip(_ d: UPaneTabDescriptor) -> some View {
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
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(hoveringClose ? UD.panelHover : Color.clear))
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("关闭")
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
        .background(RoundedRectangle(cornerRadius: 7).fill(UD.overlay))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(UD.borderHi, lineWidth: 1))
    }
}
#endif
