// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import AppKit
import SwiftUI

public extension View {
    /// 点输入框以外的地方就退出编辑态。
    ///
    /// macOS 上 `TextField` 一旦拿到 field editor，就只有另一个响应者来抢才会松手
    /// —— 点空白处、点行、点卡片都不算，光标和聚焦描边会一直挂着。`UDTextField`
    /// / `UDTextArea` / `UDSearchField` 早就在内部挂了这个监听，本修饰符把同一套
    /// 逻辑开放给外面自绘的输入框（数据表设计器的单元格输入就是一例）。
    func udDismissFocusOnOutsideClick(_ isFocused: FocusState<Bool>.Binding) -> some View {
        overlay { UDInputFocusDismissMonitor(isFocused: isFocused) }
    }
}

enum UDInputFocusDismissal {
    static func shouldDismissFocus(eventWindow: NSWindow?,
                                   inputWindow: NSWindow?,
                                   eventLocationInWindow: NSPoint,
                                   inputFrameInWindow: NSRect) -> Bool {
        guard let eventWindow,
              let inputWindow,
              eventWindow === inputWindow
        else { return false }

        return !inputFrameInWindow.contains(eventLocationInWindow)
    }
}

struct UDInputFocusDismissMonitor: NSViewRepresentable {
    var isFocused: FocusState<Bool>.Binding

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isFocused = isFocused.wrappedValue
        nsView.onDismiss = { isFocused.wrappedValue = false }
        nsView.updateMonitor()
    }

    final class MonitorView: NSView {
        var isFocused = false
        var onDismiss: () -> Void = {}
        private nonisolated(unsafe) var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        func updateMonitor() {
            if window != nil, isFocused {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    self?.handleMouseDown(event) ?? event
                }
            } else {
                removeMonitor()
            }
        }

        private func handleMouseDown(_ event: NSEvent) -> NSEvent {
            guard isFocused,
                  let inputWindow = window
            else { return event }

            let inputFrame = convert(bounds, to: nil)
            guard UDInputFocusDismissal.shouldDismissFocus(eventWindow: event.window,
                                                           inputWindow: inputWindow,
                                                           eventLocationInWindow: event.locationInWindow,
                                                           inputFrameInWindow: inputFrame)
            else { return event }

            // 本地监听器在事件真正派发**之前**就被调用。这里若同步写 `isFocused = false`，
            // SwiftUI 会把这次「清焦点」排到下一拍界面更新；而 mouseDown 紧接着就被送到
            // 目标视图 —— 目标若是另一个输入框，它先拿到 field editor，随后那拍清焦点落地，
            // 把刚建立的焦点也一起清掉，用户看到的就是「要点两次才能聚焦」。
            // 所以推迟到事件派发完成之后再判断：别的视图已经接管第一响应者就不插手，
            // 焦点仍在本输入框（点的是空白 / 不可聚焦的控件）才退出编辑态。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFocused, let window = self.window else { return }
                if let takenOver = Self.responderView(of: window),
                   takenOver.window === window,
                   !takenOver.convert(takenOver.bounds, to: nil).intersects(self.convert(self.bounds, to: nil)) {
                    return
                }
                self.onDismiss()
            }
            return event
        }

        /// 当前第一响应者对应的视图：field editor 归还给它正在编辑的 `NSTextField`。
        private static func responderView(of window: NSWindow) -> NSView? {
            guard let responder = window.firstResponder as? NSView else { return nil }
            if let textView = responder as? NSTextView, textView.isFieldEditor {
                return textView.delegate as? NSView ?? textView
            }
            return responder
        }

        private nonisolated func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
#endif
