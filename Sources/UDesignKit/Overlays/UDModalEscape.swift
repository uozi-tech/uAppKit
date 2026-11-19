#if os(macOS)
import AppKit
import SwiftUI

/// 自绘模态弹层的 ESC 关闭。`UDModalBackdrop` 自带（因此 `UDModal` / `UDConfirmModal` 都有），
/// 调用方不用再各自挂 `onExitCommand`。
///
/// 规则：
/// - 只认不带修饰键的 ESC，且只处理发往弹层所在窗口的按键；
/// - 同一窗口叠了几层弹层时只关最上面一层（后出现的在上）；
/// - 窗口上还挂着可见的子窗口（弹层里打开的下拉、`UDAnchoredPanel` 浮层）时放行，先让它们关；
/// - 输入法正在组字（有 marked text）时放行，ESC 交给输入法取消组字；
/// - 窗口挂着系统 sheet 时放行。
///
/// 实现：弹层背板里放一个零尺寸 `NSView` 登记自己，全局共用一个本地 keyDown 监听。
@MainActor
enum UDModalEscape {
    final class Registration {
        weak var view: NSView?
        var onEscape: () -> Void
        init(view: NSView, onEscape: @escaping () -> Void) {
            self.view = view
            self.onEscape = onEscape
        }
    }

    private(set) static var registrations: [Registration] = []
    private static var monitor: Any?

    static func register(_ registration: Registration) {
        registrations.removeAll { $0 === registration || $0.view == nil }
        registrations.append(registration)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    static func unregister(_ registration: Registration) {
        registrations.removeAll { $0 === registration || $0.view == nil }
        if registrations.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 处理了（关掉了一层弹层）返回 true，按键被吞掉。
    @discardableResult
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window,
              let top = registrations.last(where: { $0.view?.window === window })
        else { return false }
        if window.attachedSheet != nil { return false }
        if window.childWindows?.contains(where: \.isVisible) == true { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        top.onEscape()
        return true
    }
}

/// 背板里登记 ESC 的零尺寸视图。
struct UDModalEscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(onEscape: onEscape)
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.registration.onEscape = onEscape
    }

    /// 零尺寸，不参与布局。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CatcherView, context: Context) -> CGSize? { .zero }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        UDModalEscape.unregister(view.registration)
    }

    final class CatcherView: NSView {
        private(set) var registration: UDModalEscape.Registration!

        init(onEscape: @escaping () -> Void) {
            super.init(frame: .zero)
            registration = UDModalEscape.Registration(view: self, onEscape: onEscape)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                UDModalEscape.unregister(registration)
            } else {
                UDModalEscape.register(registration)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
