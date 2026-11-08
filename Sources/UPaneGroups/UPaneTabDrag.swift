#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 标签拖拽载荷、拖拽会话状态（鼠标释放轮询兜底）、组投放代理。
// 从 uTable `UTableTabDrag.swift` 泛型化搬入（uTable 那份又是从 uTerm 的
// `TabDragItem` / `PaneDragState` / `PaneDropDelegate` 移植的）。

/// 把标签 id 装进 / 取出 `NSItemProvider`，供 chip 重排与拖到组边缘分屏共用。
/// `DropDelegate` 走的是 `NSItemProvider` API，故不用 `Transferable`。
///
/// **类型由 app 传入。** `UTType(exportedAs:)` 要求在各自的 `Info.plist` 里登记
/// `UTExportedTypeDeclarations`，包替 app 声明不了。用专属类型而非 `.plainText`，
/// 免得被其他接受文本拖放的视图拦截。
public enum UPaneTabDragPayload {
    public static func itemProvider(tabID: UUID, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        let identifier = type.identifier
        provider.registerDataRepresentation(forTypeIdentifier: identifier,
                                            visibility: .ownProcess) { completion in
            completion(Data(tabID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    public static func load(from provider: NSItemProvider, type: UTType,
                            completion: @escaping @Sendable (UUID?) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(UUID(uuidString: string))
        }
    }
}

/// 一次标签拖拽会话的瞬态状态。不持久化。`UPaneGroupArea` 以 `@State` 持有，
/// 透传给每个组与其投放代理。拖拽源同时记在这里 —— drop 时同步消费，不依赖
/// `NSItemProvider` 的异步回调决定 UI 是否更新。
@MainActor
@Observable
public final class UPaneDragState {
    /// 正在被拖拽的标签 id 与其所在组；nil 表示当前无拖拽。
    public internal(set) var draggingTabID: UUID?
    public internal(set) var draggingSourceGroupID: UUID?
    /// 光标当前悬停的投放目标。写入一律走 `setHover(_:)`。
    public internal(set) var hover: PaneDragHoverTarget?

    public init() {}

    /// 悬停目标的**去重**写入。`dropUpdated` 每帧都调（鼠标不动也调），而
    /// `@Observable` 的 setter 不比较新旧值 —— 原样写回同一个 target 也会让所有读
    /// `hover` 的 body 失效重算。拖拽过程中光标绝大多数帧还停在同一个投放区里，
    /// 去重后每次拖拽只剩「跨区」那几次真正的失效。
    public func setHover(_ target: PaneDragHoverTarget?) {
        if hover != target { hover = target }
    }

    /// 每个组的当前尺寸（本地坐标，原点 0,0），由各组的 GeometryReader 实时维护，
    /// 投放代理按 groupID 读取。
    ///
    /// **不能把尺寸作为 `let` 捕获进 delegate**：SwiftUI 的 `.onDrop(of:delegate:)`
    /// 在拖放目标注册后不随 body 重建刷新 delegate 的存储值 —— 注册时的宽高一旦
    /// 窗口 resize 就变旧，左右（宽度相关）投放区随即错判甚至失灵（上下用高度，
    /// 窗口只改宽时仍正常，故表现为「改了宽度后左右分屏拖不出来」）。改走共享
    /// 引用即可实时读到最新尺寸。
    ///
    /// `@ObservationIgnored`：不参与视图观察（无人在 body 里读），避免布局回写触发重绘。
    @ObservationIgnored public var groupBounds: [UUID: CGRect] = [:]

    @ObservationIgnored private var endPollTask: Task<Void, Never>?

    /// 拖拽开始时由标签 chip 的 `.onDrag` 调用。`.onDrag` 没有结束回调，故启动一个
    /// 鼠标释放轮询，松手即 `end()`。
    public func begin(tabID: UUID, groupID: UUID) {
        draggingTabID = tabID
        draggingSourceGroupID = groupID
        hover = nil
        endPollTask?.cancel()
        endPollTask = Task { @MainActor [weak self] in
            // 30ms 周期：足够灵敏又不空耗。bit 0 = 鼠标左键。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled { return }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    // 给 SwiftUI/AppKit 的 drop target 一点时间先跑 performDrop
                    // 再清掉进程内拖拽源；成功的 drop 会提前 end()。
                    try? await Task.sleep(for: .milliseconds(120))
                    if Task.isCancelled { return }
                    self?.end()
                    return
                }
            }
        }
    }

    /// 结束拖拽会话。由鼠标释放轮询调用，也由 drop 路径兜底调用。幂等。
    public func end() {
        draggingTabID = nil
        draggingSourceGroupID = nil
        hover = nil
        endPollTask?.cancel()
        endPollTask = nil
    }
}

/// 单个组的拖放代理。读 `DropInfo.location` 归类到 `PaneDropZone`，把悬停写进
/// 共享的 `UPaneDragState.hover`；落点时回调 `onDrop`。
///
/// 不认识的载荷（app 声明的 `foreignDropTypes`，例如 SFTP 侧栏文件）转给
/// `onForeignDrop`。
struct UPaneGroupDropDelegate: DropDelegate {
    let targetID: UUID
    let dragState: UPaneDragState
    let dragType: UTType
    let foreignTypes: [UTType]
    /// 本落点区在**整个组**坐标系里的原点偏移。组的落点区挂在两处：组外壳
    /// （偏移 0）和盖在它上面的面板内容层（偏移 = 标签条高度），而 5 分区判定用的
    /// 是整组的矩形 —— 内容层报上来的坐标得先补回这段。
    var locationOffset: CGSize = .zero
    let onDrop: @MainActor @Sendable (_ sourceTab: UUID, _ zone: PaneDropZone) -> Void
    let onForeignDrop: (_ providers: [NSItemProvider], _ groupID: UUID, _ zone: PaneDropZone) -> Bool

    /// 目标组当前本地尺寸（原点 0,0）。**实时**从共享 `dragState` 读取而非作为
    /// `let` 捕获 —— 见 `UPaneDragState.groupBounds`。
    private var bounds: CGRect { dragState.groupBounds[targetID] ?? .zero }

    private var acceptedTypes: [UTType] { [dragType] + foreignTypes }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        updateHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHover(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // 仅当记录的悬停仍是自己时才清除 —— 兄弟组的 dropEntered 可能已把记录
        // 替换掉了，再清会让高亮闪烁。
        if dragState.hover?.groupID == targetID {
            dragState.setHover(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = paneDropZone(at: locationInGroup(info), in: bounds) ?? .center
        let onDrop = onDrop
        // 优先走进程内同步源：不依赖 provider 的异步回调。
        if let sourceTab = dragState.draggingTabID {
            dragState.end()
            onDrop(sourceTab, zone)
            return true
        }
        dragState.end()
        if let provider = info.itemProviders(for: [dragType]).first {
            UPaneTabDragPayload.load(from: provider, type: dragType) { sourceTab in
                guard let sourceTab else { return }
                Task { @MainActor in onDrop(sourceTab, zone) }
            }
            return true
        }
        guard !foreignTypes.isEmpty else { return false }
        let providers = info.itemProviders(for: foreignTypes)
        guard !providers.isEmpty else { return false }
        return onForeignDrop(providers, targetID, zone)
    }

    private func updateHover(_ info: DropInfo) {
        if let zone = paneDropZone(at: locationInGroup(info), in: bounds) {
            dragState.setHover(PaneDragHoverTarget(groupID: targetID, zone: zone))
        }
    }

    /// 把落点坐标从「本落点区」换算到「整个组」。
    private func locationInGroup(_ info: DropInfo) -> CGPoint {
        CGPoint(x: info.location.x + locationOffset.width,
                y: info.location.y + locationOffset.height)
    }
}

/// 标签条（chip 以外的部分：胶囊间隙、胶囊上下留白、尾部空白、右侧按钮）的
/// 投放代理。标签条横向拖动是重排手势，**不能**掉进组级 5 分区判定 —— 标签条
/// 贴着组的上沿，按整组矩形算会落进 `.top`（靠两端还会落进左右），一松手就
/// 意外分屏。这里悬停不画分屏高亮，松手只把标签挪到本组末尾。
struct UPaneTabStripDropDelegate: DropDelegate {
    let groupID: UUID
    let dragState: UPaneDragState
    let dragType: UTType
    let onDropAtEnd: @MainActor @Sendable (_ sourceTab: UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [dragType])
    }

    func dropEntered(info: DropInfo) {
        dragState.setHover(nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragState.setHover(nil)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let onDropAtEnd = onDropAtEnd
        if let sourceTab = dragState.draggingTabID {
            dragState.end()
            onDropAtEnd(sourceTab)
            return true
        }
        dragState.end()
        guard let provider = info.itemProviders(for: [dragType]).first else { return false }
        UPaneTabDragPayload.load(from: provider, type: dragType) { sourceTab in
            guard let sourceTab else { return }
            Task { @MainActor in onDropAtEnd(sourceTab) }
        }
        return true
    }
}

/// 标签 chip 上的重排代理：把被拖拽标签插到本 chip 的槽位（跨组也适用）。
/// 同步源优先。
struct UPaneTabReorderDropDelegate: DropDelegate {
    let targetTabID: UUID
    let dragState: UPaneDragState
    let dragType: UTType
    let onReorder: @MainActor @Sendable (_ sourceTab: UUID, _ targetTab: UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [dragType])
    }

    func dropEntered(info: DropInfo) {
        // chip 内的悬停不属于任何分屏投放区 —— 清掉组级高亮。
        dragState.setHover(nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragState.setHover(nil)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let onReorder = onReorder
        let target = targetTabID
        let dragType = dragType
        if let sourceTab = dragState.draggingTabID {
            dragState.end()
            guard sourceTab != target else { return true }
            onReorder(sourceTab, target)
            return true
        }
        dragState.end()
        guard let provider = info.itemProviders(for: [dragType]).first else { return false }
        UPaneTabDragPayload.load(from: provider, type: dragType) { sourceTab in
            guard let sourceTab, sourceTab != target else { return }
            Task { @MainActor in onReorder(sourceTab, target) }
        }
        return true
    }
}
#endif
