// macOS 专用：整份文件用平台条件包住，这样这个 target 即使被拉进 iOS 的
// 构建图也只是空目标，而不是因为 import AppKit 直接编译失败。
#if os(macOS)

import AppKit
import SwiftUI

// MARK: - 为什么不用 SwiftUI 的 `.onDrag`

/// SwiftUI 的 `.onDrag` 在 macOS 上**没有位移死区**：按下后收到第一个 `mouseDragged`
/// （实测移动 0.5pt）就起 AppKit 拖拽会话、把预览画出来。手一抖，普通点击就变成了
/// 拖拽——预览在点下去的地方闪一下，这次点击的抬起也被拖拽会话吞掉。
///
/// 这里换成自己起会话：旁观 `leftMouseDown` / `leftMouseDragged` / `leftMouseUp`
/// （同 `PointerDownProbe`，不消费事件、对命中测试透明），按下后拖过 `deadZone` 才调
/// `beginDraggingSession`。死区以内 SwiftUI 侧看到的就是一次普通点击。
///
/// 局限同 `onPointerDown`：同一个窗口里盖在本视图上面的纯 SwiftUI 内容挡不住它
/// （sheet / popover / 菜单是另一个窗口，不受影响）。

// MARK: - 探针视图

/// 带位移死区的拖拽源。自己不画、不吃事件、不参与命中测试。
public final class DragSourceProbeView: NSView, NSDraggingSource {
    /// 默认死区。够盖住点击时的手抖，又不至于让人觉得拖不动。
    public static let defaultDeadZone: CGFloat = 5

    /// 按下后要拖过这么远才起拖。
    public var deadZone: CGFloat = DragSourceProbeView.defaultDeadZone
    /// 按下时问一次：这次按下能不能起拖（例如按在关闭按钮上就不能）。
    public var canBegin: () -> Bool = { true }
    /// 拖过死区、会话开始前调用一次，返回放上拖拽板的内容；返回 nil 不起拖。
    public var makeItem: () -> NSPasteboardItem? = { nil }
    /// 跟随光标的预览图。参数是窗口的 backing scale。
    public var makeImage: (_ scale: CGFloat) -> NSImage? = { _ in nil }

    /// 测试替身。真实拖拽会话会卡在 AppKit 的拖拽循环里，直到真的松开鼠标才返回，
    /// 单测里不能起。
    var startSession: ((_ item: NSDraggingItem, _ event: NSEvent) -> Void)?

    private var monitor: Any?
    /// 这次按下的位置（窗口坐标）。非 nil = 已按下、还没拖过死区。
    private var pressLocation: NSPoint?

    /// 当前是否正在旁观事件。跟随「在不在窗口里」。
    public var isObserving: Bool { monitor != nil }

    /// 对命中测试完全透明——点击、悬停、右键菜单照常落到 SwiftUI 内容上。
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else if monitor == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.observe(event)
                return event   // 原样放行：绝不消费
            }
        }
    }

    /// 视图离开窗口或被拆除时必须调用，否则监视器会随视图一起泄漏。
    public func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressLocation = nil
    }

    private func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressLocation = nil
            // Control + 左键是右键菜单，不是拖拽的起点。
            guard event.window === window, !event.modifierFlags.contains(.control) else { return }
            let local = convert(event.locationInWindow, from: nil)
            guard PointerDownHitTest.contains(point: local, bounds: bounds, visibleRect: visibleRect),
                  canBegin() else { return }
            pressLocation = event.locationInWindow
        case .leftMouseDragged:
            guard let start = pressLocation, event.window === window else { return }
            let now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) >= deadZone else { return }
            pressLocation = nil
            beginDrag(with: event, pressedAt: start)
        default:   // leftMouseUp
            pressLocation = nil
        }
    }

    private func beginDrag(with event: NSEvent, pressedAt start: NSPoint) {
        guard let item = makeItem() else { return }
        let image = makeImage(window?.backingScaleFactor ?? 2)
        let size = image?.size ?? CGSize(width: 1, height: 1)
        // 预览以本视图为中心（同 SwiftUI `.onDrag` 的摆法），再补上死区里已经走过的
        // 那一段——AppKit 按起拖事件之后的位移挪预览，不补的话预览会落后光标一个死区。
        let from = convert(start, from: nil)
        let to = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX + to.x - from.x, y: bounds.midY + to.y - from.y)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: image)
        if let startSession {
            startSession(dragItem, event)
        } else {
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }
    }

    // MARK: NSDraggingSource

    /// 只在本 app 内移动：载荷是进程内的 id，别的 app 拿去没有意义。
    public func draggingSession(_ session: NSDraggingSession,
                                sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// 按住 Option 不改成「拷贝」——来源只给了「移动」，改了就哪儿都放不下。
    public func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private struct DragSourceProbe<Preview: View>: NSViewRepresentable {
    let deadZone: CGFloat
    let canBegin: () -> Bool
    let item: () -> NSPasteboardItem?
    let preview: Preview

    func makeNSView(context: Context) -> DragSourceProbeView {
        let view = DragSourceProbeView()
        configure(view, context: context)
        return view
    }

    func updateNSView(_ nsView: DragSourceProbeView, context: Context) {
        configure(nsView, context: context)
    }

    private func configure(_ view: DragSourceProbeView, context: Context) {
        view.deadZone = deadZone
        view.canBegin = canBegin
        view.makeItem = item
        // `ImageRenderer` 不继承环境：深浅色要显式带过去，否则预览永远按浅色画。
        let preview = preview.environment(\.colorScheme, context.environment.colorScheme)
        view.makeImage = { scale in
            let renderer = ImageRenderer(content: preview)
            renderer.scale = scale
            return renderer.nsImage
        }
    }

    static func dismantleNSView(_ nsView: DragSourceProbeView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

extension View {
    /// 把本视图变成拖拽源：按下后**拖过 `deadZone`** 才起拖拽会话。用它代替
    /// `.onDrag`——后者没有死区，手一抖点击就成了拖拽。见文件顶部的说明。
    ///
    /// - Parameters:
    ///   - canBegin: 按下时问一次，返回 false 这次按下不起拖。
    ///   - item: 起拖时调用一次，返回放上拖拽板的内容（`.onDrop` 那头按它的类型认）；
    ///     返回 nil 不起拖。「拖拽开始了」的状态也在这里记。
    ///   - preview: 跟随光标的预览，起拖时以本视图为中心摆放。
    public func dragSource<Preview: View>(
        deadZone: CGFloat = DragSourceProbeView.defaultDeadZone,
        canBegin: @escaping () -> Bool = { true },
        item: @escaping () -> NSPasteboardItem?,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        background(DragSourceProbe(deadZone: deadZone, canBegin: canBegin, item: item, preview: preview()))
    }
}

#endif
