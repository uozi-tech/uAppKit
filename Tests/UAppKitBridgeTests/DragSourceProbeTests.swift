// macOS 专用：整份文件用平台条件包住，这样这个 target 即使被拉进 iOS 的
// 构建图也只是空目标，而不是因为 import AppKit 直接编译失败。
#if os(macOS)

import AppKit
import SwiftUI
import XCTest
@testable import UAppKitBridge

/// 位移死区：按下后拖过 `deadZone` 才起拖。事件用 `NSApp.sendEvent` 合成（本地监视器
/// 就挂在这条路上）；真实拖拽会话会卡到真的松开鼠标为止，所以起会话那一步换成替身。
@MainActor
final class DragSourceProbeViewTests: XCTestCase {
    private var window: NSWindow!
    private var probe: DragSourceProbeView!
    private var sessions: [(item: NSDraggingItem, event: NSEvent)] = []
    private var itemRequests = 0

    /// 探针占窗口内容区左下角 (20, 20) 起的 100×30。
    private let press = NSPoint(x: 60, y: 35)

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        probe = DragSourceProbeView(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        probe.makeItem = { [unowned self] in
            itemRequests += 1
            let item = NSPasteboardItem()
            item.setString("tab", forType: .string)
            return item
        }
        probe.makeImage = { _ in NSImage(size: NSSize(width: 40, height: 20)) }
        probe.startSession = { [unowned self] item, event in sessions.append((item, event)) }
        window.contentView?.addSubview(probe)
    }

    override func tearDown() async throws {
        probe.removeFromSuperview()
        window = nil
        probe = nil
        sessions = []
        itemRequests = 0
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }

    private func moved(_ dx: CGFloat, _ dy: CGFloat = 0) -> NSPoint {
        NSPoint(x: press.x + dx, y: press.y + dy)
    }

    /// 这个 bug 本身：点击时手抖了几个点，不该起拖。
    func testMovementInsideTheDeadZoneDoesNotStartADrag() {
        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(1))
        send(.leftMouseDragged, at: moved(3, -3))
        send(.leftMouseUp, at: moved(3, -3))

        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(itemRequests, 0, "没起拖就不该去要载荷——调用方在那里记「拖拽开始了」")
    }

    func testCrossingTheDeadZoneStartsExactlyOneDrag() {
        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(4))
        XCTAssertTrue(sessions.isEmpty)

        send(.leftMouseDragged, at: moved(5))
        send(.leftMouseDragged, at: moved(30))
        send(.leftMouseDragged, at: moved(60))

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(itemRequests, 1)
        XCTAssertEqual(sessions.first?.event.locationInWindow, moved(5), "起拖事件就是越过死区的那一个")
    }

    /// 死区按直线距离算，斜着拖也一样。
    func testDeadZoneIsMeasuredAsStraightLineDistance() {
        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(3, 3))     // 4.24
        XCTAssertTrue(sessions.isEmpty)
        send(.leftMouseDragged, at: moved(4, -3))    // 5
        XCTAssertEqual(sessions.count, 1)
    }

    /// 预览以探针为中心，再补上死区里已经走过的那一段，起拖时不落后光标。
    func testPreviewIsCentredOnTheViewAndOffsetByTheDeadZoneTravel() throws {
        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(6, 2))

        let frame = try XCTUnwrap(sessions.first).item.draggingFrame
        XCTAssertEqual(frame.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(frame.midX, probe.bounds.midX + 6, accuracy: 0.01)
        XCTAssertEqual(frame.midY, probe.bounds.midY + 2, accuracy: 0.01)
    }

    func testPressOutsideTheViewDoesNotArm() {
        send(.leftMouseDown, at: NSPoint(x: 200, y: 150))
        send(.leftMouseDragged, at: NSPoint(x: 60, y: 35))   // 拖进探针范围也不算
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCanBeginIsAskedAtPressAndVetoesTheDrag() {
        probe.canBegin = { false }
        send(.leftMouseDown, at: press)
        probe.canBegin = { true }                            // 按下之后才变也不算
        send(.leftMouseDragged, at: moved(40))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testControlClickIsAContextMenuNotADrag() {
        send(.leftMouseDown, at: press, modifiers: .control)
        send(.leftMouseDragged, at: moved(40), modifiers: .control)
        XCTAssertTrue(sessions.isEmpty)
    }

    /// 松手就解除：下一次没有按在探针上的拖动不能接着上一次的按下算。
    func testReleaseDisarms() {
        send(.leftMouseDown, at: press)
        send(.leftMouseUp, at: press)
        send(.leftMouseDragged, at: moved(40))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testNoItemMeansNoDrag() {
        probe.makeItem = { nil }
        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(40))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testProbeIsTransparentToHitTesting() {
        XCTAssertNil(probe.hitTest(NSPoint(x: 50, y: 15)))
    }

    func testMonitorFollowsWindowMembership() {
        XCTAssertTrue(probe.isObserving)
        probe.removeFromSuperview()
        XCTAssertFalse(probe.isObserving, "离开窗口必须摘掉监视器")

        send(.leftMouseDown, at: press)
        send(.leftMouseDragged, at: moved(40))
        XCTAssertTrue(sessions.isEmpty)
    }

    /// 只在本 app 内移动；别的 app 接不到。
    func testSourceOnlyOffersMoveWithinTheApp() throws {
        let session = unsafeBitCast(NSObject(), to: NSDraggingSession.self)   // 实现里不读它
        XCTAssertEqual(probe.draggingSession(session, sourceOperationMaskFor: .withinApplication), .move)
        XCTAssertEqual(probe.draggingSession(session, sourceOperationMaskFor: .outsideApplication), [])
    }
}

/// `dragSource` 修饰器：挂在 SwiftUI 视图上后，探针量到的就是那个视图的范围，预览按当前深浅色出图。
@MainActor
final class DragSourceModifierTests: XCTestCase {
    private func probes(in view: NSView) -> [DragSourceProbeView] {
        (view as? DragSourceProbeView).map { [$0] } ?? view.subviews.flatMap { probes(in: $0) }
    }

    private func host<V: View>(_ view: V) -> (window: NSWindow, host: NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (window, host)
    }

    func testModifierSizesTheProbeToTheViewAndForwardsItsConfiguration() throws {
        var asked = 0
        let (window, host) = host(
            Color.gray.frame(width: 120, height: 30)
                .dragSource(deadZone: 9, canBegin: { false }) {
                    asked += 1
                    return NSPasteboardItem()
                } preview: { Color.red.frame(width: 50, height: 20) }
        )
        let probe = try XCTUnwrap(probes(in: host).first)
        XCTAssertEqual(probe.bounds.size, CGSize(width: 120, height: 30))
        XCTAssertEqual(probe.deadZone, 9)
        XCTAssertFalse(probe.canBegin())
        XCTAssertNotNil(probe.makeItem())
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(probe.makeImage(2)?.size, CGSize(width: 50, height: 20))
        withExtendedLifetime(window) {}
    }

    /// 预览用的是会随深浅色变的颜色：`ImageRenderer` 不继承环境，漏带就永远按浅色画。
    func testPreviewImageFollowsTheColorScheme() throws {
        let dynamic = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        })
        func luminance(_ scheme: ColorScheme) throws -> CGFloat {
            let (window, host) = host(
                Color.gray.frame(width: 60, height: 30)
                    .dragSource(item: { NSPasteboardItem() }) { dynamic.frame(width: 10, height: 10) }
                    .environment(\.colorScheme, scheme)
            )
            let image = try XCTUnwrap(probes(in: host).first?.makeImage(1))
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).colorAt(x: 5, y: 5)?
                .usingColorSpace(.deviceRGB))
            withExtendedLifetime(window) {}
            return pixel.redComponent
        }
        XCTAssertEqual(try luminance(.light), 1, accuracy: 0.05)
        XCTAssertEqual(try luminance(.dark), 0, accuracy: 0.05)
    }
}

#endif
