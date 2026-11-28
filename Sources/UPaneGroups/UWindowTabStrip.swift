#if os(macOS)
import AppKit
import SwiftUI
import UDesignKit
import UniformTypeIdentifiers

/// 窗口级标签条：浏览器 / iTerm2 / Ghostty 那种「一个窗口一条标签条」，通常画在标题栏里。
/// 标签里装什么（一个窗格还是一棵分屏树）由 app 决定；分屏树常用一个组标签条隐藏的
/// `UPaneGroupArea`（`.uPaneGroupTabStrip(.hidden)`）画。
///
/// chip 与编辑组标签条是**同一个实现**（`UPaneTabChip` / `UPaneTabRow`，`.card` 胶囊）：
/// 按下即激活、带死区的拖拽、拖动时邻居让位、悬停出关闭钮、右键菜单。
///
/// 拖放：
/// - 本条内拖动排序、从别的标签条（别的窗口）拖进来，都回调 `onMove(id, slot)`。app 看 id
///   是不是自己的决定是重排还是接收（接收 = 从来源处摘出来再放进来）。
/// - 拖进来时要看到「正在拖哪个」，所有窗口得共用一份拖拽状态：给共同的祖先挂
///   `.uPaneSharedDragState(_:)`。没挂时用自己的一份，只支持本条内排序。
/// - 松手时回调 `onDragEnded(id, 屏幕坐标, accepted)`；`accepted == false` 表示没有任何落点
///   接住（松在窗口外、标题栏外的空白处），浏览器的做法是把它拖出成一个新窗口。
///
/// 标签条只占自己内容那么宽（放不下时横向滚动、选中的标签滚进可见区），后面紧跟的「＋」与
/// 右侧按钮由 app 摆在同一行。空白处不吃鼠标：标题栏的拖窗 / 双击缩放照常落到下层。
public struct UWindowTabStrip<TabMenu: View>: View {
    private let stripID: UUID
    private let tabIDs: [UUID]
    private let activeTabID: UUID?
    private let dragType: UTType
    private let height: CGFloat
    private let descriptor: (UUID) -> UPaneTabDescriptor
    private let onActivate: (UUID) -> Void
    private let onRequestClose: (UUID) -> Void
    private let onMove: @MainActor (_ tabID: UUID, _ slot: UPaneReorderSlot) -> Void
    private let onDragEnded: ((_ tabID: UUID, _ screenPoint: NSPoint, _ accepted: Bool) -> Void)?
    private let tabMenu: (UUID) -> TabMenu

    @State private var ownDragState = UPaneDragState()
    @Environment(\.uPaneSharedDragState) private var sharedDragState
    private var dragState: UPaneDragState { sharedDragState ?? ownDragState }
    /// 一排 chip 的实际宽度：标签条最多占这么宽，后面的「＋」紧跟最后一个标签。
    @State private var rowWidth: CGFloat = 0
    /// 当前顺序的实时副本：chip 上的落点代理注册后不随 body 刷新，捕获数组会变旧，只能读引用。
    @State private var order = LiveTabOrder()

    public init(
        /// 这条标签条的身份（通常是窗口 id）。拖拽状态按它认「同一条标签条里的排序」。
        stripID: UUID,
        tabIDs: [UUID],
        activeTabID: UUID?,
        /// 拖拽载荷的 UTType，app 声明（见 `UPaneTabDragPayload`）。要能把标签拖到编辑区边缘分屏时，
        /// 编辑区用同一个类型。
        dragType: UTType,
        height: CGFloat = 38,
        /// 每个 chip 自己的 body 里求值（同 `UPaneGroupArea`）。
        descriptor: @escaping (UUID) -> UPaneTabDescriptor,
        onActivate: @escaping (UUID) -> Void,
        /// 关闭**请求**：组件不自己关（app 可能要先确认）。
        onRequestClose: @escaping (UUID) -> Void,
        onMove: @escaping @MainActor (_ tabID: UUID, _ slot: UPaneReorderSlot) -> Void,
        onDragEnded: ((_ tabID: UUID, _ screenPoint: NSPoint, _ accepted: Bool) -> Void)? = nil,
        @ViewBuilder tabMenu: @escaping (UUID) -> TabMenu
    ) {
        self.stripID = stripID
        self.tabIDs = tabIDs
        self.activeTabID = activeTabID
        self.dragType = dragType
        self.height = height
        self.descriptor = descriptor
        self.onActivate = onActivate
        self.onRequestClose = onRequestClose
        self.onMove = onMove
        self.onDragEnded = onDragEnded
        self.tabMenu = tabMenu
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                UPaneTabRow(tabIDs: tabIDs, groupID: stripID, dragState: dragState, spacing: 2) { id in
                    chip(id).id(id)
                }
                .frame(height: height)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rowWidth = $0 }
                .onDrop(of: [dragType], delegate: UPaneTabStripDropDelegate(
                    groupID: stripID,
                    dragState: dragState,
                    dragType: dragType,
                    onDropAtEnd: { [onMove] id in onMove(id, .end) },
                    onCommit: { [onMove] id, slot in onMove(id, slot) }))
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
            .onChange(of: activeTabID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .frame(height: height)
        .onChange(of: tabIDs, initial: true) { _, ids in order.ids = ids }
    }

    private func chip(_ id: UUID) -> some View {
        UPaneTabChip(
            tabID: id,
            isTransient: false,
            customTitle: nil,
            activity: id == activeTabID ? .active : .inactive,
            descriptor: { descriptor(id) },
            tabMenu: { tabMenu(id) },
            dragState: dragState,
            dragType: dragType,
            groupID: stripID,
            stripHeight: height,
            style: .card,
            onActivate: { onActivate(id) },
            onClose: { onRequestClose(id) },
            tabs: { [order] in order.ids },
            onReorder: { [onMove] source, target in onMove(source, .before(target)) },
            onCommit: { [onMove] source, slot in onMove(source, slot) },
            onDragEnded: onDragEnded.map { ended in
                { point, operation in ended(id, point, !operation.isEmpty) }
            })
    }
}

/// 见 `UWindowTabStrip.order`。不参与观察：只给落点代理读。
@MainActor
final class LiveTabOrder {
    var ids: [UUID] = []
}

extension UWindowTabStrip where TabMenu == EmptyView {
    public init(
        stripID: UUID,
        tabIDs: [UUID],
        activeTabID: UUID?,
        dragType: UTType,
        height: CGFloat = 38,
        descriptor: @escaping (UUID) -> UPaneTabDescriptor,
        onActivate: @escaping (UUID) -> Void,
        onRequestClose: @escaping (UUID) -> Void,
        onMove: @escaping @MainActor (_ tabID: UUID, _ slot: UPaneReorderSlot) -> Void,
        onDragEnded: ((_ tabID: UUID, _ screenPoint: NSPoint, _ accepted: Bool) -> Void)? = nil
    ) {
        self.init(stripID: stripID, tabIDs: tabIDs, activeTabID: activeTabID, dragType: dragType,
                  height: height, descriptor: descriptor, onActivate: onActivate,
                  onRequestClose: onRequestClose, onMove: onMove, onDragEnded: onDragEnded,
                  tabMenu: { _ in EmptyView() })
    }
}
#endif
