#if canImport(AppKit)
import AppKit
import XCTest
@testable import UDesignKit

/// `.anchoredPanel` 打开期间的事件判定：点触发器不算点外关闭（交给触发器 toggle）、
/// 组字中的 ESC 交给输入法、别的窗口的 ESC 不关面板。
@MainActor
final class UDAnchoredPanelEventsTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let inset: CGFloat = 24

    override func tearDown() async throws {
        await MainActor.run {
            for window in windows {
                window.contentView = NSView()
                window.orderOut(nil)
            }
            windows.removeAll()
        }
    }

    private func makeWindow(_ rect: NSRect = NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                            panel: Bool = false) -> NSWindow {
        _ = NSApplication.shared
        let window: NSWindow = panel
            ? NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    /// 父窗口里挂一个锚点（= 触发器所在位置），再开一个面板。
    private func makeFixture() -> (parent: NSWindow, anchor: NSView, panel: NSWindow) {
        let parent = makeWindow()
        let anchor = NSView(frame: NSRect(x: 20, y: 200, width: 120, height: 26))
        parent.contentView?.addSubview(anchor)
        let panel = makeWindow(NSRect(x: -19_990, y: -19_900, width: 248, height: 148), panel: true)
        return (parent, anchor, panel)
    }

    private func mouseUp(_ type: NSEvent.EventType = .leftMouseUp, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    private func escape(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                         isARepeat: false, keyCode: 53)!
    }

    private func decide(_ event: NSEvent, _ s: (parent: NSWindow, anchor: NSView, panel: NSWindow)) -> UDAnchoredPanelEvents.Decision {
        UDAnchoredPanelEvents.decide(event, panel: s.panel, anchor: s.anchor, inset: inset)
    }

    /// 点在触发器上：不收起，交给触发器自己 toggle（否则「关 → 又被 toggle 回开」，面板关不掉）。
    func testClickOnTriggerIsLeftToTheTrigger() {
        let s = makeFixture()
        XCTAssertEqual(decide(mouseUp(at: NSPoint(x: 60, y: 210), in: s.parent), s), .pass)
        // 触发器旁边一点点就是「面板外」。
        XCTAssertEqual(decide(mouseUp(at: NSPoint(x: 160, y: 210), in: s.parent), s), .dismiss)
        XCTAssertEqual(decide(mouseUp(at: NSPoint(x: 60, y: 100), in: s.parent), s), .dismiss)
        // 右键点在触发器上仍算点外（触发器不响应右键）。
        XCTAssertEqual(decide(mouseUp(.rightMouseUp, at: NSPoint(x: 60, y: 210), in: s.parent), s), .dismiss)
    }

    func testClicksInsidePanelContentPassAndInsetDismisses() {
        let s = makeFixture()
        XCTAssertEqual(decide(mouseUp(at: NSPoint(x: 100, y: 70), in: s.panel), s), .pass, "内容区点击放行")
        XCTAssertEqual(decide(mouseUp(at: NSPoint(x: 5, y: 5), in: s.panel), s), .dismiss, "透明留白算面板外")
    }

    func testEscapeDismissesAndIsSwallowed() {
        let s = makeFixture()
        XCTAssertEqual(decide(escape(in: s.parent), s), .dismissAndSwallow)
        XCTAssertEqual(decide(escape(in: s.panel), s), .dismissAndSwallow)
        XCTAssertEqual(decide(escape(in: s.parent, modifiers: .command), s), .pass, "⌘ESC 不算")
    }

    /// 别的窗口里的 ESC 与面板无关：不关、不吞。
    func testEscapeInUnrelatedWindowPasses() {
        let s = makeFixture()
        let other = makeWindow()
        XCTAssertEqual(decide(escape(in: other), s), .pass)
    }

    /// 输入法组字中的 ESC 是取消组字，不收起面板（面板里搜索框打拼音按 ESC 的常见场景）。
    func testEscapeWhileTextIsMarkedGoesToInputMethod() {
        let s = makeFixture()
        let textView = NSTextView(frame: NSRect(x: 30, y: 30, width: 180, height: 24))
        s.panel.contentView?.addSubview(textView)
        s.panel.makeFirstResponder(textView)
        textView.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())

        XCTAssertEqual(decide(escape(in: s.panel), s), .pass)
        textView.unmarkText()
        XCTAssertEqual(decide(escape(in: s.panel), s), .dismissAndSwallow)
    }

    func testOtherKeysPass() {
        let s = makeFixture()
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: s.panel.windowNumber, context: nil,
                                   characters: "a", charactersIgnoringModifiers: "a",
                                   isARepeat: false, keyCode: 0)!
        XCTAssertEqual(decide(key, s), .pass)
    }
}
#endif
