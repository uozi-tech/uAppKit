import AppKit
import SwiftUI
import XCTest
@testable import UAppKitBridge

/// 本包存在的前提：SwiftUI 的点击手势在 AppKit 内容上失效。这条前提本身也要钉住，
/// 否则哪天 SwiftUI 改了实现，这个包就该退役而不是继续留着。
@MainActor
final class GesturePremiseTests: XCTestCase {
    private final class EatingView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            super.mouseDown(with: event)
        }
    }

    private struct EatingRep: NSViewRepresentable {
        func makeNSView(context: Context) -> EatingView { EatingView() }
        func updateNSView(_ v: EatingView, context: Context) {}
    }

    /// 宿主必须真的进窗口并转过 runloop —— 否则 `NSViewRepresentable` 的 NSView
    /// 还没建出来，命中测试落回 hosting view，断言就是空的（这个坑踩过一次）。
    private func hostAndHitTest<V: View>(_ view: V) -> (host: NSView, hit: NSView?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (host, host.hitTest(NSPoint(x: 200, y: 150)))
    }

    private func contains<T: NSView>(_ v: NSView, _ type: T.Type) -> Bool {
        v is T || v.subviews.contains { contains($0, type) }
    }

    /// 前提一：SwiftUI 在 macOS 上不装 NSGestureRecognizer——手势不会像 iOS 那样
    /// 因为"挂在祖先上"就自动看到子视图的事件。
    func testSwiftUIInstallsNoGestureRecognizers() {
        let (host, _) = hostAndHitTest(
            Color.gray.contentShape(Rectangle()).onTapGesture { }
        )
        func count(_ v: NSView) -> Int { (v.gestureRecognizers.count) + v.subviews.reduce(0) { $0 + count($1) } }
        XCTAssertEqual(count(host), 0, "若这条不再成立，onPointerDown 可能已经没有存在必要")
    }

    /// 前提二：纯 SwiftUI 内容时命中测试落在 hosting view 上——手势正常，是对照组。
    func testPlainSwiftUIContentIsHitByTheHostingView() {
        let (host, hit) = hostAndHitTest(
            Color.gray.contentShape(Rectangle()).onTapGesture { }
        )
        XCTAssertTrue(hit === host || hit?.isDescendant(of: host) == true)
        XCTAssertFalse(hit is EatingView)
    }

    /// 前提三：一旦内容是自己处理 mouseDown 的 NSView，命中测试就落到它身上，
    /// NSHostingView.mouseDown 不会被调用，祖先上的点击手势永不触发。
    func testAppKitContentStealsTheHitTestFromSwiftUI() {
        let (host, hit) = hostAndHitTest(
            EatingRep().contentShape(Rectangle()).onTapGesture { }
        )
        // 先确认 representable 真的挂上了，否则下面那条断言毫无意义。
        XCTAssertTrue(contains(host, EatingView.self), "representable 还没挂上，测试是空的")
        XCTAssertTrue(hit is EatingView, "实际落到: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
    }
}

@MainActor
final class PointerDownHitTestTests: XCTestCase {
    /// 只用 visibleRect：ScrollView 里它是整个滚动视口，会让相邻探针全部误命中。
    func testUsesIntersectionNotVisibleRectAlone() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 38)
        let viewport = CGRect(x: -200, y: -10, width: 900, height: 200)   // 比 bounds 还大
        XCTAssertFalse(PointerDownHitTest.contains(point: CGPoint(x: 300, y: 10),
                                                   bounds: bounds, visibleRect: viewport))
        XCTAssertTrue(PointerDownHitTest.contains(point: CGPoint(x: 50, y: 10),
                                                  bounds: bounds, visibleRect: viewport))
    }

    /// 只用 bounds：滚出视口的视图还会对其名义 frame 上的点击作出响应。
    func testScrolledOutOfViewportDoesNotRespond() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 38)
        let clipped = CGRect(x: 0, y: 0, width: 0, height: 0)             // 完全滚出
        XCTAssertFalse(PointerDownHitTest.contains(point: CGPoint(x: 50, y: 10),
                                                   bounds: bounds, visibleRect: clipped))
    }

    /// 部分可见时，只有露在外面的那半边算命中。
    func testPartiallyVisibleOnlyCountsTheVisibleHalf() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 38)
        let half = CGRect(x: 0, y: 0, width: 50, height: 38)
        XCTAssertTrue(PointerDownHitTest.contains(point: CGPoint(x: 25, y: 10),
                                                  bounds: bounds, visibleRect: half))
        XCTAssertFalse(PointerDownHitTest.contains(point: CGPoint(x: 75, y: 10),
                                                   bounds: bounds, visibleRect: half))
    }
}

@MainActor
final class PointerDownProbeViewTests: XCTestCase {
    /// 探针对命中测试透明，AppKit 内容才拿得到自己的 mouseDown。
    func testProbeIsTransparentToHitTesting() {
        let probe = PointerDownProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(probe.hitTest(NSPoint(x: 50, y: 50)))
    }

    /// 进窗口才装监视器，离开窗口就摘掉——否则监视器会随视图泄漏。
    func testMonitorFollowsWindowMembership() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let probe = PointerDownProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(probe.isObserving, "未进窗口前不该有监视器")

        window.contentView?.addSubview(probe)
        XCTAssertTrue(probe.isObserving)

        probe.removeFromSuperview()
        XCTAssertFalse(probe.isObserving, "离开窗口必须摘掉监视器")
    }
}
