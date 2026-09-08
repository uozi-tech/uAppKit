// macOS 专用：整份文件用平台条件包住，理由同 `PointerDownProbe.swift`。
#if os(macOS)

import AppKit
import SwiftUI

// MARK: - 为什么需要这个闸门

/// 滚动期间把 hover 关掉的共享闸门。
///
/// ## 病灶
///
/// 鼠标停着不动、内容在指针底下滚过去时，**每一行经过指针都是一次真的
/// enter / exit**：AppKit 在视图几何变化时会拿窗口的
/// `mouseLocationOutsideOfEventStream` 重算 `NSTrackingArea`，SwiftUI 的
/// `.onHover` 于是逐帧亮起又灭掉。代价不是那个回调本身，而是回调写进
/// `@State` 之后连锁的那一串：
///
/// - 「悬停才建真控件」的行（hover 出编辑 / 删除按钮、hover 才挂 `.help`）
///   每帧拆一棵子树再建一棵；
/// - hover 底色变化让那一行重绘；
/// - 行 body 重求，连带里面所有插值字符串重新拼一遍。
///
/// 一次「光标恰好停在列表上」的滚动因此比「光标在列表外」的同一次滚动贵得多 ——
/// 而前者才是用户的真实姿势（他刚刚才用这只手滚的轮）。
///
/// ## 做法
///
/// 闸门盯住最近的那个 `NSScrollView`：
///
/// - `willStartLiveScroll` / `didEndLiveScroll`：用户拖滚动条 / 惯性滚动；
/// - `NSClipView` 的 `boundsDidChange`：滚轮、程序性 `scrollTo`、键盘翻页 ——
///   这些**不发** live-scroll 通知，只能靠 bounds 变化兜底；
/// - 两者都只做一件事：置 `isScrolling = true` 并把 150ms 的静默计时器往后推。
///
/// 静默 150ms 之后 `isScrolling` 归 false。
///
/// ## 恢复：不做命中测试，补发「最后一次真值」
///
/// 滚动停下时要让光标底下那一行重新亮起来。直觉的做法是拿
/// `NSEvent.mouseLocation` 去命中测试 —— 但 SwiftUI 的行不是独立 `NSView`，
/// 命中测试给不出「是哪一行」。
///
/// 其实不必测：**滚动期间 `.onHover` 照样在发，我们只是没有转发**。
/// `hoverGated` 把每一次 enter / exit 记在一个不触发重求值的盒子里
/// （`HoverGateBox`，普通 class，不是 `@State` 值），静默期一到就把最后那个
/// 值交出去。光标底下那一行的最后一个事件必然是 enter，其余行必然是 exit ——
/// 这是 AppKit 已经算好的结论，比我们自己命中测试更准，且一次几何计算都不用做。
///
/// 滚动**开始**时同样处理：先把当前值记进盒子，再强制交付一次 `false`，
/// 于是滚动中没有任何一行是「亮着的」。
///
/// ## 用法
///
/// ```swift
/// ScrollView {
///     LazyVStack { ForEach(rows) { Row($0) } }
///         .scrollHoverGate()          // 挂在滚动内容上（与 .onDrop / 点击层同一层）
/// }
/// ```
/// ```swift
/// // 行里：
/// .hoverGated { hover = $0 }          // 取代 .onHover { hover = $0 }
/// ```
///
/// 需要在别处读「现在在不在滚」时用 `@Environment(\.isScrolling)`，
/// 并在容器上传 `publishesIsScrolling: true`（见那个参数的说明 —— 它有代价）。
@MainActor
@Observable
public final class ScrollHoverGate {

    /// 现在是不是正在滚。`hoverGated` 读的就是它。
    public private(set) var isScrolling = false

    /// 最后一次滚动活动之后多久算「停下了」。
    ///
    /// 150ms 是权衡：短于一次滚轮 tick 的间隔（惯性滚动约 60~120Hz，但用户手指
    /// 分段拨轮时两段之间常有 100ms 上下的空档）会在一次连续滚动中间反复开合；
    /// 长了则「停下之后 hover 迟迟不回来」会被感知成迟钝。
    @ObservationIgnored public var quietInterval: TimeInterval

    /// 闸门是否生效。`false` 时 `noteActivity()` 什么都不做，`isScrolling` 恒 false，
    /// `hoverGated` 因此与裸 `.onHover` 完全等价。
    ///
    /// **只给探针的前后同轮对照用** —— 产线一律 true。绝对毫秒跨进程不可比，
    /// 「改前」臂必须与「改后」臂在同一个进程里轮流量，而三处被测视图的闸门都
    /// 长在产线代码里，没有这个开关就只能各抄一份改前视图。
    @ObservationIgnored public var isEnabled: Bool

    /// 新建闸门的默认 `isEnabled`。探针在挂窗之前翻它。
    public nonisolated(unsafe) static var isEnabledByDefault = true

    /// 静默计时器。用 `Timer` 而不是每次活动都开一个 `Task`：滚动中活动通知是
    /// 每帧一条，`fireDate` 往后推是常数开销，开 Task 不是。
    ///
    /// **必须加进 `.common` 模式**：live scroll 期间主 runloop 跑在
    /// `eventTracking` 模式里，默认模式的计时器在整个拖拽过程中一次都不会烧。
    @ObservationIgnored private var quietTimer: Timer?

    /// 被观察的 `NSClipView` 与「上一次判定为停下时」的滚动原点。见 `suspendsHover`。
    @ObservationIgnored private weak var observedClip: NSClipView?
    @ObservationIgnored private var settledOrigin: NSPoint?

    public nonisolated init(quietInterval: TimeInterval = 0.15) {
        self.quietInterval = quietInterval
        self.isEnabled = Self.isEnabledByDefault
    }

    // 刻意没有 `deinit` 里的 `quietTimer?.invalidate()`：Swift 6 的 nonisolated
    // deinit 碰不了非 Sendable 的 `Timer?`。计时器是一次性的、最长 150ms 后自烧，
    // 且只弱引用 self，烧的时候 self 已经没了就什么都不做。真正需要提前收尾的
    // 场合（视图离开窗口）走 `ScrollActivityObserverView.detach()` → `settle()`。

    /// hover 这一刻该不该被吃掉。**`hoverGated` 读的是它，不是 `isScrolling`。**
    ///
    /// 为什么不能只看 `isScrolling`：AppKit 在 `NSClipView` 的 bounds 变掉时
    /// **先**重算 tracking area、把 enter / exit 送出去，**再**发
    /// `boundsDidChangeNotification`。于是一次滚动的第一个 enter 抢在闸门开之前
    /// 落地（实测：200 步程序性滚动里正好漏 1 个 enter + 它随后的 exit）。
    /// 真人滚轮时 `willStartLiveScroll` 会在任何 bounds 变化之前发，漏不掉；
    /// 但滚轮之外的路径（程序性 `scrollTo`、键盘翻页）没有那条通知。
    ///
    /// 兜底判据是**几何**而不是通知：滚动原点只要与「上次判定停下时」不同，
    /// 这一拍就已经在滚了。读一个 `NSPoint` 比什么都便宜，而且不会漏。
    public var suspendsHover: Bool {
        guard isEnabled else { return false }
        if isScrolling { return true }
        if let observedClip, let settledOrigin, observedClip.bounds.origin != settledOrigin {
            return true
        }
        return false
    }

    /// 观察这个 `NSClipView` 的滚动原点（由 `ScrollActivityObserverView` 接线）。
    public func observe(clipView: NSClipView?) {
        observedClip = clipView
        settledOrigin = clipView?.bounds.origin
    }

    /// 「刚刚滚了一下」。置 `isScrolling` 并把静默计时器往后推。
    public func noteActivity() {
        guard isEnabled else { return }
        if !isScrolling { isScrolling = true }
        let deadline = Date(timeIntervalSinceNow: quietInterval)
        if let quietTimer, quietTimer.isValid {
            quietTimer.fireDate = deadline
        } else {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            quietTimer = timer
        }
    }

    /// 立刻当作「已经停下」。给测试与「视图离开窗口」这类收尾用。
    public func settle() {
        quietTimer?.invalidate()
        quietTimer = nil
        // 停下的那一刻把滚动原点记成新的基准 —— `suspendsHover` 的几何兜底
        // 就是拿它比的。
        settledOrigin = observedClip?.bounds.origin
        if isScrolling { isScrolling = false }
    }
}

// MARK: - 探针计数器

/// `hoverGated` 的转发 / 抑制计数。
///
/// 产线代码不读它 —— 它存在的唯一理由是让「滚动期间到底还有没有把 hover
/// 交出去」变成一个**可断言的整数**，而不是靠帧时间去猜。两次整数自增，
/// 对读数没有可测量的影响。
@MainActor
public enum HoverGateStats {
    /// 真正交给调用方闭包的次数。
    public private(set) static var forwarded = 0
    /// 滚动期间被吃掉的 enter / exit 次数。
    public private(set) static var suppressed = 0

    public static func reset() {
        forwarded = 0
        suppressed = 0
    }

    static func noteForwarded() { forwarded &+= 1 }
    static func noteSuppressed() { suppressed &+= 1 }
}

// MARK: - 观察最近的 NSScrollView

/// 装在滚动内容里、只负责把滚动活动喂给闸门的透明视图。
///
/// 与 `PointerDownProbeView` 一样对命中测试完全透明（`hitTest` 返回 nil），
/// 也不画任何东西。
public final class ScrollActivityObserverView: NSView {

    public var gate: ScrollHoverGate? {
        didSet { gate?.observe(clipView: observedClipView) }
    }

    private weak var observedScrollView: NSScrollView?
    private weak var observedClipView: NSClipView?
    private var didRetryAttach = false

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            attach()
        }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil, window != nil { attach() }
    }

    /// 找到最近的 `NSScrollView` 并订阅它的滚动活动。
    ///
    /// SwiftUI 有时先把 background 视图挂进树、稍后才把它塞进 documentView，
    /// 所以第一次找不到时下一轮 runloop 再试一次（只试一次，避免空转）。
    public func attach() {
        guard let scroll = enclosingScrollView else {
            guard !didRetryAttach else { return }
            didRetryAttach = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.attach()
            }
            return
        }
        guard scroll !== observedScrollView else { return }
        detach()
        observedScrollView = scroll
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        observedClipView = clip
        gate?.observe(clipView: clip)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scrollActivity(_:)),
                           name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(scrollActivity(_:)),
                           name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // 滚轮 / 程序性滚动 / 键盘翻页都不发 live-scroll 通知，只有这一条能兜住。
        center.addObserver(self, selector: #selector(scrollActivity(_:)),
                           name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// 退订。视图离开窗口或被拆除时必须调用，否则观察者随视图泄漏。
    public func detach() {
        guard observedScrollView != nil || observedClipView != nil else { return }
        NotificationCenter.default.removeObserver(self)
        observedScrollView = nil
        observedClipView = nil
        gate?.observe(clipView: nil)
        // 拆的瞬间闸门可能正开着，收尾一下，免得停在 `isScrolling = true`。
        gate?.settle()
    }

    @objc private func scrollActivity(_ note: Notification) {
        gate?.noteActivity()
    }
}

private struct ScrollActivityProbe: NSViewRepresentable {
    let gate: ScrollHoverGate

    func makeNSView(context: Context) -> ScrollActivityObserverView {
        let view = ScrollActivityObserverView()
        view.gate = gate
        return view
    }

    func updateNSView(_ nsView: ScrollActivityObserverView, context: Context) {
        nsView.gate = gate
    }

    static func dismantleNSView(_ nsView: ScrollActivityObserverView, coordinator: ()) {
        nsView.detach()
    }
}

// MARK: - 环境值

private struct ScrollHoverGateKey: EnvironmentKey {
    static let defaultValue: ScrollHoverGate? = nil
}

private struct IsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 当前滚动容器的闸门。没有容器装闸门时为 nil ——`hoverGated` 那时与
    /// 裸 `.onHover` 等价，所以行组件可以无条件用 `hoverGated`，不必关心自己
    /// 这次是不是长在滚动列表里。
    public var scrollHoverGate: ScrollHoverGate? {
        get { self[ScrollHoverGateKey.self] }
        set { self[ScrollHoverGateKey.self] = newValue }
    }

    /// 「现在在不在滚」。**只有容器传了 `publishesIsScrolling: true` 才会更新**，
    /// 否则恒 false。理由见 `scrollHoverGate(_:publishesIsScrolling:)`。
    public var isScrolling: Bool {
        get { self[IsScrollingKey.self] }
        set { self[IsScrollingKey.self] = newValue }
    }
}

// MARK: - 修饰器

public struct ScrollHoverGateModifier: ViewModifier {
    private let external: ScrollHoverGate?
    private let publishesIsScrolling: Bool
    @State private var owned = ScrollHoverGate()

    public init(gate: ScrollHoverGate?, publishesIsScrolling: Bool) {
        self.external = gate
        self.publishesIsScrolling = publishesIsScrolling
    }

    public func body(content: Content) -> some View {
        let gate = external ?? owned
        content
            .background(ScrollActivityProbe(gate: gate))
            .environment(\.scrollHoverGate, gate)
            // 只在被要求时才把 Bool 灌进环境：环境值一变，这个修饰器整棵子树
            // （也就是整份列表）都要重求一次 body。`hoverGated` 走的是上面那个
            // **对象**通道 —— 对象引用不变，只有真读了 `isScrolling` 的那几十个
            // 在屏行会失效，代价小一个量级。
            .environment(\.isScrolling, publishesIsScrolling ? gate.isScrolling : false)
    }
}

/// 每个 `hoverGated` 各自的小盒子。
///
/// **故意不是 `@State` 的值类型**：滚动期间每一行经过指针都会写一次 `pending`，
/// 写 `@State` 就等于每帧让那一行重求 body —— 那正是这个闸门要省掉的开销。
/// 普通 class 存在 `@State` 里，实例身份稳定，改字段不触发任何失效。
final class HoverGateBox: @unchecked Sendable {
    /// 最近一次 `.onHover` 报的真值（含滚动期间被抑制掉的那些）。
    var pending = false
    /// 最近一次真正交给调用方的值。
    var delivered = false
}

public struct HoverGatedModifier: ViewModifier {
    private let action: (Bool) -> Void
    @Environment(\.scrollHoverGate) private var gate
    @State private var box = HoverGateBox()

    public init(action: @escaping (Bool) -> Void) {
        self.action = action
    }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                box.pending = hovering
                if gate?.suspendsHover == true {
                    HoverGateStats.noteSuppressed()
                    return
                }
                deliver(hovering)
            }
            .onChange(of: gate?.isScrolling ?? false) { _, scrolling in
                if scrolling {
                    // 进滚动：记住当前值，然后一律灭掉。
                    box.pending = box.delivered
                    deliver(false)
                } else {
                    // 出滚动：把滚动期间 AppKit 已经算好的最后一个真值交出去。
                    deliver(box.pending)
                }
            }
    }

    private func deliver(_ value: Bool) {
        guard box.delivered != value else { return }
        box.delivered = value
        HoverGateStats.noteForwarded()
        action(value)
    }
}

extension View {
    /// 给一个滚动容器的**内容**装上 hover 闸门。
    ///
    /// 挂法与整表 `.onDrop(delegate:)` / 点击层完全一致 —— 挂在承载行的
    /// `LazyVStack`（或 `VStack`）上，**不是挂在 `ScrollView` 上**：装进去的
    /// 观察视图靠 `enclosingScrollView` 找滚动视图，挂在 `ScrollView` 外面就找不到。
    ///
    /// - Parameters:
    ///   - gate: 想自己持有闸门时传进来（跨视图共享、或测试里驱动）。默认自建一个。
    ///   - publishesIsScrolling: 是否顺带把 `@Environment(\.isScrolling)` 也灌进子树。
    ///     默认 **false**：这个 Bool 一变，整棵子树都要重求 body，2 万行的列表付不起。
    ///     只有真的要在别处读这个状态时才打开。
    public func scrollHoverGate(_ gate: ScrollHoverGate? = nil,
                                publishesIsScrolling: Bool = false) -> some View {
        modifier(ScrollHoverGateModifier(gate: gate,
                                         publishesIsScrolling: publishesIsScrolling))
    }

    /// `.onHover` 的滚动门控版：滚动期间不转发，停下 150ms 后补发最后一个真值。
    ///
    /// 没有祖先装闸门时与裸 `.onHover` 完全等价，所以行组件可以无条件用它。
    public func hoverGated(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(HoverGatedModifier(action: action))
    }
}

#endif
