#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 自绘模态弹层按 ESC 关闭：只关最上面一层；弹层里开着下拉 / 浮层、输入法在组字、带修饰键时都放行。
@MainActor
final class UDModalEscapeTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        await MainActor.run {
            for window in windows {
                window.contentView = NSView()
                window.orderOut(nil)
            }
            windows.removeAll()
            XCTAssertTrue(UDModalEscape.registrations.allSatisfy { $0.view?.window == nil } || UDModalEscape.registrations.isEmpty)
        }
    }

    private func makeWindow(_ content: NSView = NSView()) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func escape(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                         isARepeat: false, keyCode: 53)!
    }

    private func catcher(_ onEscape: @escaping () -> Void) -> UDModalEscapeCatcher.CatcherView {
        UDModalEscapeCatcher.CatcherView(onEscape: onEscape)
    }

    func testClosesOnlyTopmostModal() {
        let window = makeWindow()
        var closed: [String] = []
        let bottom = catcher { closed.append("bottom") }
        let top = catcher { closed.append("top") }
        window.contentView?.addSubview(bottom)
        window.contentView?.addSubview(top)

        XCTAssertTrue(UDModalEscape.handle(escape(in: window)))
        XCTAssertEqual(closed, ["top"])

        top.removeFromSuperview()
        XCTAssertTrue(UDModalEscape.handle(escape(in: window)))
        XCTAssertEqual(closed, ["top", "bottom"])

        bottom.removeFromSuperview()
        XCTAssertFalse(UDModalEscape.handle(escape(in: window)), "没有弹层时 ESC 照常往下传")
    }

    func testIgnoresOtherWindowsAndModifiedEscape() {
        let modalWindow = makeWindow()
        let otherWindow = makeWindow()
        var count = 0
        modalWindow.contentView?.addSubview(catcher { count += 1 })

        XCTAssertFalse(UDModalEscape.handle(escape(in: otherWindow)), "别的窗口的 ESC 不关这个弹层")
        XCTAssertFalse(UDModalEscape.handle(escape(in: modalWindow, modifiers: .command)), "⌘ESC 不算")
        XCTAssertEqual(count, 0)
        XCTAssertTrue(UDModalEscape.handle(escape(in: modalWindow)))
        XCTAssertEqual(count, 1)
    }

    func testLetsChildPanelHandleEscapeFirst() {
        let window = makeWindow()
        var count = 0
        window.contentView?.addSubview(catcher { count += 1 })
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 50, height: 50),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        XCTAssertFalse(UDModalEscape.handle(escape(in: window)), "弹层里开着下拉 / 浮层时先关它们")
        window.removeChildWindow(panel)
        panel.orderOut(nil)
        XCTAssertTrue(UDModalEscape.handle(escape(in: window)))
        XCTAssertEqual(count, 1)
    }

    func testLetsInputMethodCancelComposition() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let window = makeWindow()
        window.contentView?.addSubview(textView)
        var count = 0
        window.contentView?.addSubview(catcher { count += 1 })
        window.makeFirstResponder(textView)
        textView.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())

        XCTAssertFalse(UDModalEscape.handle(escape(in: window)), "组字中的 ESC 交给输入法")
        textView.unmarkText()
        XCTAssertTrue(UDModalEscape.handle(escape(in: window)))
        XCTAssertEqual(count, 1)
    }

    /// `UDModal` / `UDConfirmModal` 经背板自带 ESC：真实 SwiftUI 宿主里按 ESC 调到 `onDismiss` / `onCancel`。
    func testUDModalAndConfirmModalCloseOnEscape() throws {
        final class Box { var dismissed = 0; var cancelled = 0 }
        let box = Box()
        let view = ZStack {
            UDModal(onDismiss: { box.dismissed += 1 }) { Text("设置").frame(width: 200, height: 100) }
            UDConfirmModal(title: "删除？", onCancel: { box.cancelled += 1 }, onConfirm: {}) { Text("不可撤销") }
        }
        .frame(width: 400, height: 300)
        let hosting = NSHostingView(rootView: view)
        let window = makeWindow(hosting)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(UDModalEscape.handle(escape(in: window)))
        XCTAssertEqual(box.cancelled, 1, "后出现的确认框在上，先关它")
        XCTAssertEqual(box.dismissed, 0)
    }

    func testSpinningStartsAtZeroAndFinishesTheTurn() {
        typealias Spin = UDSpinningIcon<EmptyView>
        let start = Date(timeIntervalSinceReferenceDate: 1000.37)
        XCTAssertEqual(Spin.angle(at: start, since: start).degrees, 0, accuracy: 0.001, "从 0° 起转，不跳到墙钟角度")
        XCTAssertEqual(Spin.angle(at: start.addingTimeInterval(0.25), since: start).degrees, 90, accuracy: 0.001)
        XCTAssertEqual(Spin.angle(at: start.addingTimeInterval(1.5), since: start).degrees, 180, accuracy: 0.001)

        XCTAssertEqual(Spin.stopDate(start: start, now: start.addingTimeInterval(1.2)), start.addingTimeInterval(2),
                       "停下时转完当前这一圈")
        XCTAssertEqual(Spin.stopDate(start: start, now: start.addingTimeInterval(0.1)), start.addingTimeInterval(1),
                       "刚开始就停也转满一圈")
        XCTAssertEqual(Spin.stopDate(start: start, now: start.addingTimeInterval(3)), start.addingTimeInterval(3))
    }
}
#endif
