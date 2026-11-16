#if os(macOS)

import AppKit
import XCTest
@testable import UControlKit

/// 窗口恢复（来自 uTerm 的 `DockReopenTests`）：露出界面时放回藏起的窗口、按前后顺序、不把后台期间
/// 关掉的窗口放出来，没有窗口时走开窗入口。
@MainActor
final class BackgroundWindowControllerTests: XCTestCase {
    private var createdWindows: [NSWindow] = []
    private var hostWindows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        hostWindows = NSApp.orderedWindows.filter(\.isVisible)
        hostWindows.forEach { $0.orderOut(nil) }
    }

    override func tearDown() async throws {
        createdWindows.forEach { $0.close() }
        createdWindows = []
        hostWindows.reversed().forEach { $0.orderFront(nil) }
    }

    private func makeWindow(_ title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.orderFront(nil)
        createdWindows.append(window)
        return window
    }

    private func frontmostVisible() -> NSWindow? {
        NSApp.orderedWindows.first(where: \.isVisible)
    }

    /// 测试里的控制器：不碰 Dock 以外的全局状态，开窗入口单独计数。
    private func controller(opens: (@MainActor () -> Void)? = nil) -> BackgroundWindowController {
        let controller = BackgroundWindowController(startsHidden: false)
        controller.openPrimaryWindow = opens
        return controller
    }

    func testPickerPrefersFrontmostVisibleWindow() {
        let older = makeWindow("older")
        let newer = makeWindow("newer")
        older.orderFront(nil)

        XCTAssertTrue(ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows) === older)
        XCTAssertFalse(ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows) === newer)
    }

    func testPickerSkipsClosedAndHiddenWindows() {
        let closed = makeWindow("closed")
        let hidden = makeWindow("hidden")
        closed.close()
        hidden.orderOut(nil)

        XCTAssertNil(ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows))
    }

    func testPickerSkipsPanels() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)

        XCTAssertNil(ReopenWindowPicker.pick(frontToBack: [panel]))
    }

    /// 后台唤起时窗口在视图出现前就被藏起来、开窗入口没装上：露出界面要把这个藏着的窗口拿出来（面板不算）。
    func testHiddenPickerFindsWindowHiddenBeforeItsViewAppeared() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let welcome = makeWindow("welcome")
        welcome.orderOut(nil)

        XCTAssertNil(ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows), "藏着的窗口不算可见")
        XCTAssertTrue(ReopenWindowPicker.pickHidden([panel, welcome]) === welcome)
        XCTAssertNil(ReopenWindowPicker.pickHidden([panel]))
    }

    func testReopenKeepsFrontWindowInsteadOfFirstCreatedWindow() {
        let welcome = makeWindow("welcome")
        let terminal = makeWindow("terminal")
        terminal.orderFront(nil)

        let handledBySystem = controller().applicationShouldHandleReopen()

        XCTAssertFalse(handledBySystem)
        XCTAssertTrue(frontmostVisible() === terminal)
        XCTAssertTrue(welcome.isVisible)
    }

    func testReopenOpensPrimaryWindowWhenNoWindowRemains() {
        var opens = 0
        makeWindow("closed").close()

        let presentation = controller(opens: { opens += 1 }).showGUI()

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(presentation, .shown)
    }

    func testShowGUICallsTheWillShowHook() {
        let controller = controller()
        var calls = 0
        controller.onWillShowGUI = { calls += 1 }
        _ = makeWindow("window")

        controller.showGUI()

        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.hasShownGUI)
    }

    func testBackgroundRoundTripRestoresEveryWindowInOrder() {
        let controller = controller()
        let back = makeWindow("back")
        let front = makeWindow("front")

        controller.moveToBackground()
        XCTAssertFalse(back.isVisible)
        XCTAssertFalse(front.isVisible)
        controller.showGUI()

        XCTAssertTrue(back.isVisible)
        XCTAssertTrue(frontmostVisible() === front)
    }

    func testWindowClosedInBackgroundStaysClosed() {
        let controller = controller()
        let survivor = makeWindow("survivor")
        let ended = makeWindow("ended")

        controller.moveToBackground()
        ended.close()
        controller.showGUI()

        XCTAssertTrue(survivor.isVisible)
        XCTAssertFalse(ended.isVisible)
    }
}

#endif
