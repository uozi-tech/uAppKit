#if os(macOS)
import AppKit
import SwiftUI
import UAppKitBridge
import UDesignKit
import UniformTypeIdentifiers

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
struct UPaneTabChip<TabMenu: View>: View {
    let tabID: UUID
    let isTransient: Bool
    /// `UPaneTab.customTitle`：**覆盖** descriptor 派生出的标题。
    let customTitle: String?
    let activity: UPaneTabActivity
    /// **在本视图的 body 里求值**，不是在标签条里先算成数组。见 `UPaneTabDescriptor`。
    let descriptor: () -> UPaneTabDescriptor
    let tabMenu: () -> TabMenu
    let dragState: UPaneDragState
    let dragType: UTType
    /// 拖拽会话与落位预览按它认「同一条标签条」：编辑组里是组 id，窗口标签条是标签条自己的 id。
    let groupID: UUID
    let stripHeight: CGFloat
    let style: UPaneGroupStyle
    let onActivate: () -> Void
    let onClose: () -> Void
    let tabs: @MainActor () -> [UUID]
    let onReorder: @MainActor @Sendable (_ source: UUID, _ target: UUID) -> Void
    let onCommit: @MainActor @Sendable (_ source: UUID, _ slot: UPaneReorderSlot) -> Void
    /// 拖拽会话结束（松手）时调用：屏幕坐标与目标接受的操作；没有任何落点接住时操作为空。
    var onDragEnded: ((_ screenPoint: NSPoint, _ operation: NSDragOperation) -> Void)? = nil

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

    /// `customTitle` **覆盖** descriptor 派生出的标题（uTable 的已保存
    /// 查询用保存的名字而不是「查询 N」；uTerm 终端标签用服务器名）。
    private func title(_ d: UPaneTabDescriptor) -> String { customTitle ?? d.title }

    var body: some View {
        let d = descriptor()
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
            .dragSource(canBegin: { !hoveringClose }, item: {
                dragState.begin(tabID: tabID, groupID: groupID)
                return UPaneTabDragPayload.pasteboardItem(tabID: tabID, type: dragType)
            }, onEnded: onDragEnded) {
                UPaneTabDragPreviewChip(title: title(d), icon: d.icon)
            }
            .onDrop(of: [dragType], delegate: UPaneTabReorderDropDelegate(
                targetTabID: tabID,
                groupID: groupID,
                dragState: dragState,
                dragType: dragType,
                tabs: tabs,
                onReorder: onReorder,
                onCommit: onCommit))
            // 拖动排序按光标在左半还是右半判落位，要知道自己多宽。
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                dragState.chipWidths[tabID] = width
            }
            .onDisappear { dragState.chipWidths[tabID] = nil }
            .modifier(OptionalContextMenu(isEnabled: TabMenu.self != EmptyView.self,
                                          menu: { tabMenu() }))
            .help(d.help ?? title(d))
            // 对 VoiceOver 是**一个**标签：按下（AX 默认动作）= 切到它，前台标签带「已选中」，
            // × 收成一个具名动作。激活本来只走 NSEvent 旁观（`onPointerDown`），辅助功能的
            // 按下不产生鼠标事件，不补这一层的话 VoiceOver 根本切不了标签、也听不出哪个是当前的。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title(d))
            // 没给 help 时 tooltip 用的是标题，和名字同一句：AXHelp 清空，免得 VoiceOver 念两遍。
            .accessibilityHint(Text(verbatim: d.help.flatMap { $0 == title(d) ? nil : $0 } ?? ""))
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
                .italic(isTransient)
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
                .italic(isTransient)
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
struct OptionalContextMenu<Menu: View>: ViewModifier {
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
