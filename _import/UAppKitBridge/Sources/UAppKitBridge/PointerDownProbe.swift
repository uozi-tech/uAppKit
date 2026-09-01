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

    /// 当前是否正在旁观事件。跟随"在不在窗口里"。
    public var isObserving: Bool { monitor != nil }

    /// 对命中测试完全透明——AppKit 内容照常拿到自己的 `mouseDown`。
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
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
    let action: () -> Void

    func makeNSView(context: Context) -> PointerDownProbeView {
        let view = PointerDownProbeView()
        view.onPointerDown = action
        return view
    }

    func updateNSView(_ nsView: PointerDownProbeView, context: Context) {
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
    public func onPointerDown(perform action: @escaping () -> Void) -> some View {
        background(PointerDownProbe(action: action))
    }
}
