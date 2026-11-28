// macOS 专用：整份文件用平台条件包住，这样这个 target 即使被拉进 iOS 的
// 构建图也只是空目标，而不是因为 import AppKit 直接编译失败。
#if os(macOS)

import AppKit
import SwiftUI

// MARK: - 为什么需要这个包

/// SwiftUI 在 macOS 上**不装 `NSGestureRecognizer`**：`.onTapGesture` /
/// `.simultaneousGesture` 都由 `NSHostingView` 自己的响应方法处理。于是只要视图
/// 区域里放的是 `NSViewRepresentable`，而那个 `NSView` 自己实现了 `mouseDown`
/// （`NSTableView`、`NSTextView`、SwiftTerm 的终端视图都是），命中测试就落到
/// AppKit 子视图上，`NSHostingView.mouseDown` 根本不会被调用——挂在祖先上的
/// SwiftUI 点击手势**永不触发**。
///
/// 实测（离屏 `NSHostingView`，无需激活应用）：
///
/// | 内容 | 整棵树的手势识别器 | 命中测试落到 |
/// |---|---|---|
/// | 纯 SwiftUI | 0 | `NSHostingView` ✓ 手势正常 |
/// | `NSViewRepresentable` | 0 | 那个 `NSView` ✗ 手势失效 |
///
/// 典型症状：分屏工作区里点进某一格的表格 / 终端，"当前分区" 不跟着变，随后的
/// 开表、分屏、关闭都作用在上一个分区上。
///
/// macOS 27（实测 27.2）的变化：SwiftUI 的点击改由窗口的手势环境驱动
/// （`NSWindow.sendEvent` 在命中派发前先把鼠标事件交给手势系统），`NSHostingView`
/// 根上也多了一个私有的 `FocusTapGestureRecognizer`（`buttonMask` 为 0，不认鼠标键，
/// 与点击手势无关）。于是只要 AppKit 子视图让 mouseUp 走正常派发，祖先上的点击手势
/// 在 27 上会触发；但 `NSTableView` / `NSTextView` / 终端视图在 `mouseDown` 里自己跑
/// 跟踪循环、直接取走 mouseUp，手势仍然等不到结束——上表的「手势失效」在这些真实
/// 内容上依旧成立，本包在所有支持的系统上都还需要。`GesturePremiseTests` 钉着这两条。
///
/// 本包用 `NSEvent` 本地监视器**旁观** `leftMouseDown`：不消费事件、`hitTest`
/// 返回 `nil`（对命中测试完全透明），因此 AppKit 内容的选中、拖拽、first
/// responder 全部照常工作，同时 SwiftUI 侧也能知道"这块区域被按下了"。
///
/// 这也是 SwiftUI 手势做不到的另一件事：任何在按下瞬间就响应的手势（哪怕
/// `simultaneousGesture` 的 `DragGesture(minimumDistance: 0)`）都会抢占鼠标事件
/// 流，让同一视图上的 `.onDrag` 永远起不了 AppKit 拖拽会话。

// MARK: - 命中判定（纯函数，可单测）

public enum PointerDownHitTest {
    /// 探针是否该为落在 `point`（探针自身坐标系）的这次按下负责。
    ///
    /// 必须取 `bounds ∩ visibleRect` 而不是任一单独一个：
    /// - 只用 `visibleRect`：在 `ScrollView` 里它不是"本视图被裁剪后的可见部分"，
    ///   而是整个滚动视口（实测比 `bounds` 还大、原点可为负），相邻的每个探针都会误命中；
    /// - 只用 `bounds`：已经滚出视口的视图，仍会对其名义 frame 上的点击作出响应。
    ///
    /// 交集恰好是"这个视图真正露在外面的那部分"。
    public static func contains(point: CGPoint, bounds: CGRect, visibleRect: CGRect) -> Bool {
        bounds.intersection(visibleRect).contains(point)
    }
}

// MARK: - 探针视图

/// 旁观 `leftMouseDown` 的透明层。自己不画、不吃事件、不参与命中测试。
public final class PointerDownProbeView: NSView {
    /// 落在本视图可见范围内的左键按下。始终在主线程回调。
    public var onPointerDown: (() -> Void)?

    private var monitor: Any?

    /// 是否旁观按下。`false` 时连监视器都不装：本地监视器是进程级的，窗口里每一次按下都要把
    /// 所有装着的监视器跑一遍，暂时不需要回调的探针（保活下的后台面板）不该占一份。
    public var isEnabled = true {
        didSet { if isEnabled != oldValue { updateMonitor() } }
    }

    /// 当前是否正在旁观事件。跟随"在不在窗口里"与 `isEnabled`。
    public var isObserving: Bool { monitor != nil }

    /// 对命中测试完全透明——AppKit 内容照常拿到自己的 `mouseDown`。
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }

    private func updateMonitor() {
        if window == nil || !isEnabled {
            removeMonitor()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                if PointerDownHitTest.contains(point: local, bounds: self.bounds, visibleRect: self.visibleRect) {
                    self.onPointerDown?()
                }
                return event   // 原样放行：绝不消费
            }
        }
    }

    /// 视图离开窗口或被拆除时必须调用，否则监视器会随视图一起泄漏。
    public func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct PointerDownProbe: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> PointerDownProbeView {
        let view = PointerDownProbeView()
        view.isEnabled = isEnabled
        view.onPointerDown = action
        return view
    }

    func updateNSView(_ nsView: PointerDownProbeView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onPointerDown = action
    }

    static func dismantleNSView(_ nsView: PointerDownProbeView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

extension View {
    /// 本视图区域内被按下左键时回调——**即使区域里是自己处理 `mouseDown` 的
    /// AppKit 内容**（`NSTableView` / `NSTextView` / 终端视图），SwiftUI 的
    /// `.onTapGesture` 在那种情况下不会触发。见文件顶部的说明。
    ///
    /// 语义是"按下即回调"（对齐原生标签栏、浏览器标签），不是点击手势的抬起触发；
    /// 事件原样放行，不影响选中、拖拽与 first responder。
    ///
    /// 多个区域重叠时（例如同一组里前台与后台标签的矩形完全重合），每个探针都会
    /// 各响应一次——由调用方在闭包里按"当前是否可见/在前台"过滤。
    ///
    /// `isEnabled` 为 false 时不装 NSEvent 监视器、也不回调（视图身份不变，翻回 true 即恢复）。
    /// 给「一直挂着、但只有一份该响应」的场合用，例如保活的后台面板。
    public func onPointerDown(isEnabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        background(PointerDownProbe(isEnabled: isEnabled, action: action))
    }
}

#endif
