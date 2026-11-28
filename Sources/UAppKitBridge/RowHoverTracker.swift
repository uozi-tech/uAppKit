// macOS 专用：整份文件用平台条件包住，理由同 `PointerDownProbe.swift`。
#if os(macOS)

import AppKit
import SwiftUI

// MARK: - 为什么需要这个跟踪器

/// 整表**一个**悬停跟踪层，落点按行几何算命中行 —— 取代「每行一个 `.onHover`」。
///
/// ## 病灶（`ScrollHoverGate` 之后剩下的那一截）
///
/// `ScrollHoverGate` 把「滚动期间不往下转发 hover」做掉了，但它只挡在最外面一层：
/// 实测滚动时「光标停在列表内」仍比「停在列表外」贵 1.35~2.31×。
///
/// **去之前的病因假设是错的。** 原以为「SwiftUI 的每个 `.onHover` 各占 hosting view
/// 上一块 `NSTrackingArea`」，光标在窗内时 AppKit 每帧重算整窗追踪区、按行数收费。
/// 探针实测推翻了它：2000 行的列表整棵树上自始至终只有 1~3 块追踪区，跟行数毫无
/// 关系 —— **SwiftUI 自己就是「一块追踪区 + 内部按区域派发」**，跟这个文件做的事
/// 同构。
///
/// 逐行的账在 SwiftUI 内部那张 hover 区域表上：`.onHover` 越多，表越长；鼠标位置
/// 或几何一变就要过一遍表，命中之后还要把 `@State` 写回、让那一行重求 body。滚动
/// 时内容在指针底下走，每一帧都有行进出指针，这张表因此每帧都在被翻。闸门挡掉的
/// 是「写回 + 重求」，翻表本身照付。
///
/// 换成整表一个跟踪层之后，同样一件事变成**一次算术**（落点 y ÷ 行高），而且滚动
/// 期间连这一次都不做。三处列表实测 in/out 比值 1.32 / 1.31 / 2.18× → 0.88 / 1.03 /
/// 0.98×，单帧 p50 降 23~59%。
///
/// ## 做法：跟点击层 / 拖放层同构
///
/// 「整表一个 `DropDelegate`」（`RemoteRowDropTargeting`）与「整表一个透明点击层」
/// （`ClickSelectActivate`）已经证明过这条路：容器级一个平台对象 + 落点纵坐标按
/// 行几何换算成行号。悬停是第三个同构的场合：
///
/// - 容器挂 `.rowHoverTracker(state, geometry:)` —— 一个透明 `NSView`
///   （`hitTest` 返 nil、不画东西）、**一个** `NSTrackingArea`（整棵树因此从
///   1~3 块变成 2~4 块：多的那一块就是它）
///   （`.mouseMoved` / `.mouseEnteredAndExited` / `.activeInActiveApp` /
///   `.inVisibleRect`，只建一次，`.inVisibleRect` 让 AppKit 自己把矩形跟着可视区走）；
/// - `mouseMoved` 时按落点 y 与行几何算出「现在悬的是哪一行」，只把那个 id 写进
///   `RowHoverState`；
/// - 行上挂 `.rowHover(state, id: …) { hover = $0 }` 取代 `.onHover`。
///
/// **只有前后两行会失效。** `RowHoverState` 自己不是 `@Observable`：每行各有一个
/// `RowHoverBox`（`@Observable`，只有一个 `Bool`），行的 body 读的是自己那个盒子。
/// 悬停从 A 行挪到 B 行只翻两个盒子，其余几千行一个都不重求 —— 如果把
/// `hoveredID` 直接做成 `@Observable` 属性，读它的每一行都会失效，那比原来还糟。
///
/// ## 与 `ScrollHoverGate` 协作
///
/// 滚动期间跟踪器不更新（读闸门的 `suspendsHover`），进滚动那一刻把当前行灭掉；
/// 静默期一到（闸门的 `isScrolling` 翻回 false）按
/// `window.mouseLocationOutsideOfEventStream` **补算一次** —— 这一步不能省：
/// 光标没动但内容滚过去了，它底下已经换了一行，而 AppKit 不会为此发任何事件
/// （单个覆盖整块可视区的追踪区，「在不在里面」自始至终没变过）。
///
/// ## 行几何只有一份
///
/// 点击层、拖放层、本跟踪器共用 `UniformRowHit` / `RowGeometry` 这一套算术，
/// 别再出现第四份拷贝：行高改一次，三层一起对。
public enum UniformRowHit {

    /// 等高行容器里，落点 `y` 命中第几行 —— **行高从容器高度反推**。
    ///
    /// 欢迎页那类「行高是内容撑出来的」（实测 61pt）没有写死的常量可用，而
    /// 「所有行等高、行间距 0」对那份列表成立，反推比抄一个容易过期的常量更准。
    ///
    /// - Returns: 行下标；容器空 / 落点在容器外返回 nil。
    public static func index(atY y: CGFloat, containerHeight: CGFloat, rowCount: Int) -> Int? {
        guard rowCount > 0, containerHeight > 0, y >= 0, y < containerHeight else { return nil }
        let index = Int((y * CGFloat(rowCount) / containerHeight).rounded(.down))
        return min(max(0, index), rowCount - 1)
    }

    /// 定高行容器里，落点 `y` 命中第几行；容器可以有一个**高度不同的首行**
    /// （文件表的 `..`）。
    ///
    /// - Parameters:
    ///   - leadingRowHeight: 首行高度；nil = 没有首行。
    /// - Returns: `nil` = 落在容器外 / 末行之后；`.leading` = 落在首行；
    ///   `.row(i)` = 落在第 i 个普通行。
    public static func slot(atY y: CGFloat,
                            rowHeight: CGFloat,
                            rowCount: Int,
                            leadingRowHeight: CGFloat? = nil) -> RowSlot? {
        guard y >= 0, rowHeight > 0 else { return nil }
        var offset = y
        if let leadingRowHeight {
            if offset < leadingRowHeight { return .leading }
            offset -= leadingRowHeight
        }
        let index = Int((offset / rowHeight).rounded(.down))
        guard index >= 0, index < rowCount else { return nil }
        return .row(index)
    }

    /// `slot(atY:…)` 的结果。
    public enum RowSlot: Equatable {
        /// 高度不同的首行（文件表的 `..`）。
        case leading
        /// 普通行的下标。
        case row(Int)
    }

    /// 分组列表（每组一个组头 + 组内定高行，组间固定间距）里，落点命中
    /// 「第几组的第几行」。
    ///
    /// 组头必须**定高**（调用方用 `.frame(height:)` 钉死），否则这套算术会随
    /// 组头内容漂移。落在组头 / 组间空隙上返回 nil。
    public static func groupedRow(atY y: CGFloat,
                                  headerHeight: CGFloat,
                                  rowHeight: CGFloat,
                                  spacing: CGFloat,
                                  rowCounts: [Int]) -> (section: Int, row: Int)? {
        guard y >= 0, rowHeight > 0 else { return nil }
        var offset = y
        for (section, count) in rowCounts.enumerated() {
            if section > 0 {
                if offset < spacing { return nil }   // 组间空隙
                offset -= spacing
            }
            if offset < headerHeight { return nil }  // 组头
            offset -= headerHeight
            let body = rowHeight * CGFloat(count)
            if offset < body {
                let row = min(count - 1, Int((offset / rowHeight).rounded(.down)))
                return row >= 0 ? (section, row) : nil
            }
            offset -= body
        }
        return nil
    }
}

// MARK: - 行几何

/// 「落点纵坐标 → 是哪一行」。跟踪器只认这一个闭包，具体算术由调用方从
/// `UniformRowHit` 里挑（三层共用同一套，见本文件顶部）。
public struct RowGeometry {

    /// - Parameters:
    ///   - y: 落点在**行容器自身坐标系**里的纵坐标，原点在容器顶部。
    ///   - containerHeight: 容器高度（反推行高那一档要用；定高档忽略）。
    /// - Returns: 命中行的 id；没命中返回 nil。
    public let rowID: (_ y: CGFloat, _ containerHeight: CGFloat) -> AnyHashable?

    public init(rowID: @escaping (_ y: CGFloat, _ containerHeight: CGFloat) -> AnyHashable?) {
        self.rowID = rowID
    }

    /// 等高行、行高由容器高度反推（欢迎页服务器列表）。
    public static func uniform(rowCount: Int,
                               id: @escaping (Int) -> AnyHashable?) -> RowGeometry {
        RowGeometry { y, height in
            UniformRowHit.index(atY: y, containerHeight: height, rowCount: rowCount).flatMap(id)
        }
    }

    /// 定高行 + 可选的定高首行（SFTP 文件表 / 工作区文件树的 `..`）。
    /// `id` 收到 `nil` 表示首行。
    public static func fixedHeight(rowHeight: CGFloat,
                                   rowCount: Int,
                                   leadingRowHeight: CGFloat? = nil,
                                   id: @escaping (Int?) -> AnyHashable?) -> RowGeometry {
        RowGeometry { y, _ in
            switch UniformRowHit.slot(atY: y, rowHeight: rowHeight, rowCount: rowCount,
                                      leadingRowHeight: leadingRowHeight) {
            case .leading: return id(nil)
            case .row(let index): return id(index)
            case nil: return nil
            }
        }
    }

    /// 分组列表：每组一个**定高**组头 + 组内定高行，组间固定间距（全局端口转发）。
    public static func grouped(headerHeight: CGFloat,
                               rowHeight: CGFloat,
                               spacing: CGFloat,
                               rowCounts: [Int],
                               id: @escaping (Int, Int) -> AnyHashable?) -> RowGeometry {
        RowGeometry { y, _ in
            guard let hit = UniformRowHit.groupedRow(atY: y, headerHeight: headerHeight,
                                                     rowHeight: rowHeight, spacing: spacing,
                                                     rowCounts: rowCounts) else { return nil }
            return id(hit.section, hit.row)
        }
    }
}

// MARK: - 每行一个的观察盒

/// 一行的悬停位。**每行各一个**，行的 body 只读自己这个 —— 悬停在行之间挪动时
/// 因此只有前后两行失效。
@MainActor
@Observable
public final class RowHoverBox {
    public internal(set) var isHovered = false
    nonisolated init() {}
}

/// 一份列表的悬停状态：谁在悬 + 每行的观察盒。
///
/// **刻意不是 `@Observable`**：`hoveredID` 一旦被观察，读它的每一行都会随每次
/// 悬停移动失效 —— 那正是本轮要省掉的账。对外可见的观察点只有 `RowHoverBox`。
@MainActor
public final class RowHoverState {

    /// 新建状态的默认 `isEnabled`。探针在挂窗之前翻它。
    public nonisolated(unsafe) static var isEnabledByDefault = true

    /// 跟踪器是否生效。`false` 时 `.rowHoverTracker` 不装追踪区、`.rowHover` 退回
    /// 逐行 `.hoverGated`（也就是改前的形态）。
    ///
    /// **只给探针的同轮前后对照用** —— 产线一律 true。绝对毫秒跨进程不可比，
    /// 「改前」臂必须与「改后」臂在同一个进程里轮流量，而被测视图的接线都长在
    /// 产线代码里，没有这个开关就只能各抄一份改前视图。
    public let isEnabled: Bool

    /// 现在悬着的行。普通存储属性，写它不触发任何 SwiftUI 失效。
    public private(set) var hoveredID: AnyHashable?

    /// 行 id → 观察盒。行第一次求 body 时按需建，行**消失**时（`onDisappear`）摘掉 ——
    /// 只留当前在场的行和正悬着的那一行。
    ///
    /// 以前只建不删，注释说「最多涨到被滚到过的行数」，但那只在行集不变时成立：进目录、
    /// 过滤、排序都会换一批新 id，同一个 `RowHoverState` 活多久，旧 id 的盒子就攒多久。
    private var boxes: [AnyHashable: RowHoverBox] = [:]
    /// 每个盒子当前有几个在场的行在用（`attach` / `detach` 记账）。
    private var attachCounts: [AnyHashable: Int] = [:]

    /// 表里现有多少个盒子。给测试断言「摘得掉」用。
    var boxCount: Int { boxes.count }

    public nonisolated init(isEnabled: Bool? = nil) {
        self.isEnabled = isEnabled ?? Self.isEnabledByDefault
    }

    /// 取（必要时建）某一行的观察盒。
    public func box(for id: AnyHashable) -> RowHoverBox {
        if let box = boxes[id] { return box }
        let box = RowHoverBox()
        boxes[id] = box
        return box
    }

    /// 行出现：把它手里那个盒子登记回表里（被摘掉过就原样放回，保持身份不变 —— 行若没有
    /// 重求 body，它的修饰器还攥着旧盒子），并把盒子对齐到现在的悬停行。
    func attach(_ box: RowHoverBox, for id: AnyHashable) {
        if boxes[id] == nil { boxes[id] = box }
        attachCounts[id, default: 0] += 1
        let hovered = hoveredID == id
        if box.isHovered != hovered { box.isHovered = hovered }
    }

    /// 行消失：没人再用、也没在悬着的盒子从表里摘掉。
    func detach(_ box: RowHoverBox, for id: AnyHashable) {
        let remaining = max(0, (attachCounts[id] ?? 0) - 1)
        guard remaining == 0 else {
            attachCounts[id] = remaining
            return
        }
        attachCounts[id] = nil
        // 悬着的那一行留着：`setHovered` 挪走时还要靠它把亮态灭掉。
        if hoveredID != id, boxes[id] === box { boxes[id] = nil }
    }

    /// 把悬停挪到 `id`（nil = 谁都不悬）。只翻前后两个盒子。
    public func setHovered(_ id: AnyHashable?) {
        guard hoveredID != id else { return }
        if let old = hoveredID, let box = boxes[old] {
            if box.isHovered { box.isHovered = false }
            // 悬着时消失的行（`detach` 特意留下的那一个）这会儿可以摘了。
            if attachCounts[old] == nil { boxes[old] = nil }
        }
        hoveredID = id
        if let id {
            // 没建过盒子的行（还没求过 body）不必现建：等它求 body 时会从
            // `hoveredID` 拿到初值。
            if let box = boxes[id] { box.isHovered = true }
        }
    }
}

// MARK: - 探针计数器

/// `.rowHover` 的转发 / 抑制计数。理由同 `HoverGateStats`：让「滚动期间到底还在不在
/// 算 hover」成为一个**可断言的整数**，而不是靠帧时间去猜。
@MainActor
public enum RowHoverStats {
    /// 悬停行真的换了的次数。
    public private(set) static var forwarded = 0
    /// 因为在滚而被丢掉的更新次数。
    public private(set) static var suppressed = 0

    public static func reset() {
        forwarded = 0
        suppressed = 0
    }

    static func noteForwarded() { forwarded &+= 1 }
    static func noteSuppressed() { suppressed &+= 1 }
}

// MARK: - 整表一个的追踪层

/// 挂在行容器上的透明层：自己不画、不吃事件、不参与命中测试，只带**一个**
/// `NSTrackingArea`。
public final class RowHoverTrackerView: NSView {

    public var geometry: RowGeometry?
    public var state: RowHoverState?
    public var gate: ScrollHoverGate?

    private var trackingArea: NSTrackingArea?
    private var refreshScheduled = false

    /// 与 SwiftUI / `DropInfo` 同向：y 自顶部向下增长。
    public override var isFlipped: Bool { true }

    /// 对命中测试完全透明 —— 下面的内容照常拿到自己的点击、拖拽与右键。
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            state?.setHovered(nil)
            return
        }
        // 追踪区带 `.mouseMoved` 时，事件要靠窗口收 mouse-moved —— 显式打开，
        // 不在拆除时关掉（同一个窗口里可能还有别的东西指望它）。
        window.acceptsMouseMovedEvents = true
        installTrackingAreaIfNeeded()
        refreshSoon()
    }

    /// 下一拍按合成 / 真实光标补算一次悬停行。
    ///
    /// **必须有这一步**：AppKit 只在光标**移动**时发 `mouseMoved`，追踪区装上那一刻
    /// 若光标已经压在里面，它不会补发 `mouseEntered`（那要 `.assumeInside`，而那个
    /// 选项对 `.inVisibleRect` 的区域并不可靠）。列表刚挂出来、行集换了一批
    /// （进目录 / 过滤）、滚动停下 —— 这三件事都可能在光标一动不动的情况下换掉
    /// 它底下那一行。合并到下一拍是为了不在 SwiftUI 的更新过程里改状态。
    public func refreshSoon() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshFromWindow()
        }
    }

    /// **只建一次**：`.inVisibleRect` 让 AppKit 自己把矩形跟着可视区走，
    /// 不需要在 `updateTrackingAreas` 里拆了重建（那就把省下来的账又付回去了）。
    private func installTrackingAreaIfNeeded() {
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// 视图被拆除时收尾。
    public func detach() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        state?.setHovered(nil)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        update(atWindowPoint: event.locationInWindow)
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        update(atWindowPoint: event.locationInWindow)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard state?.isEnabled == true else { return }
        deliver(nil)
    }

    /// 进滚动：把当前悬着的那一行灭掉（否则它会僵在亮态滚完全程）。
    public func suspend() {
        guard state?.isEnabled == true else { return }
        deliver(nil)
    }

    /// 停下之后补算一次。
    ///
    /// **这一步不能省**：光标没动、内容滚过去了，它底下已经换了一行，而 AppKit
    /// 不会为此发任何事件 —— 整块可视区就一个追踪区，「在不在里面」自始至终没变。
    /// （这也正是每行一块追踪区时 AppKit 每帧要重算的那件事，只不过现在由我们
    /// 在滚动**停下之后**做一次，而不是每帧做一遍。）
    public func refreshFromWindow() {
        guard let window, state?.isEnabled == true else { return }
        guard gate?.suspendsHover != true else { return }
        deliver(rowID(atWindowPoint: window.mouseLocationOutsideOfEventStream))
    }

    private func update(atWindowPoint point: NSPoint) {
        guard state?.isEnabled == true else { return }
        if gate?.suspendsHover == true {
            RowHoverStats.noteSuppressed()
            return
        }
        deliver(rowID(atWindowPoint: point))
    }

    private func rowID(atWindowPoint point: NSPoint) -> AnyHashable? {
        let local = convert(point, from: nil)
        // bounds ∩ visibleRect：滚出视口的那部分不算悬停，而 `visibleRect` 单独用
        // 又不是「本视图露出来的部分」。理由同 `RowClickLayerView`。
        guard bounds.intersection(visibleRect).contains(local) else { return nil }
        return geometry?.rowID(local.y, bounds.height)
    }

    private func deliver(_ id: AnyHashable?) {
        guard let state, state.hoveredID != id else { return }
        RowHoverStats.noteForwarded()
        state.setHovered(id)
    }
}

/// 跟 SwiftUI 那侧交换 `RowHoverTrackerView` 引用的小盒子（用来在闸门开合时
/// 叫它 `suspend()` / `refreshFromWindow()`）。
@MainActor
public final class RowHoverTrackerHandle {
    weak var view: RowHoverTrackerView?
    public nonisolated init() {}
}

private struct RowHoverTrackerLayer: NSViewRepresentable {
    let state: RowHoverState
    let geometry: RowGeometry
    let gate: ScrollHoverGate?
    let handle: RowHoverTrackerHandle

    func makeNSView(context: Context) -> RowHoverTrackerView {
        let view = RowHoverTrackerView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: RowHoverTrackerView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: RowHoverTrackerView, coordinator: ()) {
        nsView.detach()
    }

    private func apply(to view: RowHoverTrackerView) {
        view.state = state
        view.geometry = geometry
        view.gate = gate
        handle.view = view
        // 行集可能刚换过一批（进目录 / 过滤 / 排序），光标底下那一行随之变了 ——
        // 而光标一动没动，AppKit 不会为此发任何事件。
        view.refreshSoon()
    }
}

// MARK: - 修饰器

public struct RowHoverTrackerModifier: ViewModifier {
    private let state: RowHoverState
    private let geometry: RowGeometry
    @Environment(\.scrollHoverGate) private var gate
    @State private var handle = RowHoverTrackerHandle()

    public init(state: RowHoverState, geometry: RowGeometry) {
        self.state = state
        self.geometry = geometry
    }

    public func body(content: Content) -> some View {
        if state.isEnabled {
            content
                .background(RowHoverTrackerLayer(state: state, geometry: geometry,
                                                 gate: gate, handle: handle))
                // 闸门开合各做一件事：进滚动灭掉当前行，停下补算一次。
                // 读 `isScrolling` 只让**这一个**修饰器失效（内容是已经建好的
                // `Content` 占位，不会因此重求）——改前那是每行各读一次。
                .onChange(of: gate?.isScrolling ?? false) { _, scrolling in
                    if scrolling {
                        handle.view?.suspend()
                    } else {
                        handle.view?.refreshFromWindow()
                    }
                }
        } else {
            content
        }
    }
}

public struct RowHoverModifier: ViewModifier {
    private let state: RowHoverState?
    private let id: AnyHashable
    private let action: (Bool) -> Void

    public init(state: RowHoverState?, id: AnyHashable, action: @escaping (Bool) -> Void) {
        self.state = state
        self.id = id
        self.action = action
    }

    public func body(content: Content) -> some View {
        if let state, state.isEnabled {
            content.modifier(TrackedRowHoverModifier(state: state, id: id,
                                                     box: state.box(for: id),
                                                     action: action))
        } else {
            // 没有跟踪器（或被探针关掉）时退回逐行 `.onHover` + 滚动闸门 ——
            // 与改前逐字等价。
            content.hoverGated(action)
        }
    }
}

private struct TrackedRowHoverModifier: ViewModifier {
    let state: RowHoverState
    let id: AnyHashable
    let box: RowHoverBox
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        // 读 `box.isHovered` 就是在这一行上注册观察：盒子一翻，**只有这一行**
        // 的这个修饰器重求，`onChange` 随即把值交给行自己的 `@State`。
        //
        // **刻意不用 `initial: true`**：滚动时 `LazyVStack` 每建一行都会因此白发
        // 一次 `action(false)`，把「新建一行」的账又抬回来（行的 `@State hover`
        // 本来就是 false）。行刚建出来就已经被悬着的那种情况由下面的 `onAppear`
        // 单独补。
        content.onChange(of: box.isHovered) { _, hovering in
            action(hovering)
        }
        .onAppear {
            // 行是滚出来才建的，建的时候光标可能已经压在它上面了。`attach` 把盒子对齐到
            // 现在的悬停行：盒子由 false 翻 true 时 `onChange` 会接住；盒子本来就是 true
            // 而行是新的一份 `@State`，`onChange` 不会发，就直接把值交给它。
            let wasHovered = box.isHovered
            state.attach(box, for: id)
            if wasHovered, box.isHovered { action(true) }
        }
        .onDisappear { state.detach(box, for: id) }
    }
}

extension View {
    /// 给一个行容器装上「整表一个 tracking area」的悬停跟踪器。
    ///
    /// 挂法与整表 `.onDrop(delegate:)` / `.clickToSelect` 完全一致 —— 挂在承载行的
    /// `LazyVStack`（或 `VStack`）上、**`.padding` 之前**，否则落点坐标会带上内边距
    /// 的偏移。
    ///
    /// 要与 `ScrollHoverGate` 协作时，把 `.scrollHoverGate()` 挂在**外面**
    /// （本修饰器之后），环境里的闸门才传得进来：
    ///
    /// ```swift
    /// LazyVStack { … }
    ///     .rowHoverTracker(rowHover, geometry: .uniform(rowCount: rows.count) { rows[$0].id })
    ///     .scrollHoverGate()
    /// ```
    public func rowHoverTracker(_ state: RowHoverState, geometry: RowGeometry) -> some View {
        modifier(RowHoverTrackerModifier(state: state, geometry: geometry))
    }

    /// 行的悬停位：由容器那一个追踪器算出来，行自己不再装 `.onHover`。
    ///
    /// `state` 为 nil（或跟踪器被关掉）时退回 `.hoverGated`，与改前等价 ——
    /// 所以行组件可以无条件用它。
    public func rowHover(_ state: RowHoverState?,
                         id: some Hashable,
                         _ action: @escaping (Bool) -> Void) -> some View {
        modifier(RowHoverModifier(state: state, id: AnyHashable(id), action: action))
    }
}

#endif
