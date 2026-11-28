// macOS 专用：整份文件用平台条件包住，这样这个 target 即使被拉进 iOS 的
// 构建图也只是空目标，而不是因为 import AppKit 直接编译失败。
#if os(macOS)

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

    /// 前提一：SwiftUI 的点击手势**不靠挂 NSGestureRecognizer 实现**——手势不会像 iOS 那样
    /// 因为「识别器挂在祖先上」就自动看到 AppKit 子视图的事件。
    ///
    /// macOS 27（实测 27.2，Swift 6.4.2）起树里不再是 0 个识别器：`NSHostingView` 根上总挂着
    /// 一个 SwiftUI 私有的 `FocusTapGestureRecognizer`（`NSClickGestureRecognizer` 子类，
    /// delegate 是它自己）。它与点击手势无关——不加任何手势的纯 `Color` 也有它，`buttonMask`
    /// 为 0（不认任何鼠标键），实测禁用或摘掉它，`onTapGesture` 的行为都不变。所以这里不再数
    /// 「总数为 0」，而是钉住两件真正撑起本包的事：
    /// 1. 加 `onTapGesture` 不会多出任何识别器（与无手势的同一内容逐类比对）；
    /// 2. 除这个已知的、不认鼠标键的焦点识别器外，没有别的识别器。
    /// 将来出现新的识别器类、或它开始认鼠标键，这条会红——那时要重新评估本包的前提。
    func testSwiftUIInstallsNoGestureRecognizers() {
        let (bare, _) = hostAndHitTest(Color.gray.contentShape(Rectangle()))
        let (tapped, _) = hostAndHitTest(Color.gray.contentShape(Rectangle()).onTapGesture { })

        XCTAssertEqual(recognizerClasses(in: tapped), recognizerClasses(in: bare),
                       "加了 onTapGesture 后多出了手势识别器——SwiftUI 改用识别器实现点击了，"
                       + "onPointerDown 可能已经没有存在必要")
        for recognizer in recognizers(in: tapped) where !Self.isKnownFocusRecognizer(recognizer) {
            XCTFail("出现未知手势识别器 \(type(of: recognizer))（buttonMask \(Self.buttonMask(of: recognizer))）"
                    + "——若它认鼠标键，onPointerDown 可能已经没有存在必要")
        }
    }

    /// macOS 27 起 SwiftUI 在 `NSHostingView` 上挂的焦点识别器：只要类名对得上且不认任何鼠标键，
    /// 它就看不到点击，不影响本包的前提。类名用字符串比：它是 SwiftUI 的私有类。
    private static func isKnownFocusRecognizer(_ recognizer: NSGestureRecognizer) -> Bool {
        NSStringFromClass(type(of: recognizer)).hasSuffix("FocusTapGestureRecognizer")
            && buttonMask(of: recognizer) == 0
    }

    private static func buttonMask(of recognizer: NSGestureRecognizer) -> Int {
        (recognizer as? NSClickGestureRecognizer)?.buttonMask ?? -1
    }

    private func recognizers(in view: NSView) -> [NSGestureRecognizer] {
        view.gestureRecognizers + view.subviews.flatMap { recognizers(in: $0) }
    }

    private func recognizerClasses(in view: NSView) -> [String] {
        recognizers(in: view).map { NSStringFromClass(type(of: $0)) }.sorted()
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
    /// NSHostingView.mouseDown 不会被调用。
    ///
    /// 注意这条在 macOS 27 起**不再等于**「祖先上的点击手势永不触发」：SwiftUI 的点击改由
    /// 窗口的手势环境驱动（`NSWindow.sendEvent` 在命中派发之前先把鼠标事件喂给手势系统），
    /// 只要 mouseUp 还走正常派发，挂在祖先上的 `onTapGesture` 照样会触发。真正让它失效的是
    /// 下面 `testTrackingLoopContentStillSwallowsSwiftUITaps` 钉住的那种情况。
    func testAppKitContentStealsTheHitTestFromSwiftUI() {
        let (host, hit) = hostAndHitTest(
            EatingRep().contentShape(Rectangle()).onTapGesture { }
        )
        // 先确认 representable 真的挂上了，否则下面那条断言毫无意义。
        XCTAssertTrue(contains(host, EatingView.self), "representable 还没挂上，测试是空的")
        XCTAssertTrue(hit is EatingView, "实际落到: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
    }

    /// 前提四（本包的功能前提）：AppKit 内容在 `mouseDown` 里自己跑事件跟踪循环
    /// （`NSTableView`、`NSTextView`、SwiftTerm 终端都是）时，mouseUp 被循环直接取走，
    /// SwiftUI 的点击手势在任何系统版本上都等不到结束——`onTapGesture` 不触发，
    /// 只有 `onPointerDown` 的旁观探针还能知道「这块被按下了」。
    ///
    /// 带对照组：同样的派发方式下纯 SwiftUI 内容的点击必须触发，否则下面的「不触发」毫无意义。
    func testTrackingLoopContentStillSwallowsSwiftUITaps() throws {
        var controlTaps = 0
        try hostAndClick(Color.gray.contentShape(Rectangle()).onTapGesture { controlTaps += 1 })
        XCTAssertEqual(controlTaps, 1, "对照组：合成点击在纯 SwiftUI 内容上没触发 onTapGesture，"
                       + "事件派发方式失效了，本测试的否定断言不可信")

        var taps = 0, pointerDowns = 0
        let tracking = TrackingView()
        try hostAndClick(
            TrackingRep(view: tracking).contentShape(Rectangle())
                .onTapGesture { taps += 1 }
                .onPointerDown { pointerDowns += 1 }
        )
        XCTAssertEqual(tracking.mouseDowns, 1, "跟踪循环视图没收到 mouseDown，测试是空的")
        XCTAssertEqual(tracking.trackedMouseUps, 1, "mouseUp 没被跟踪循环取走，测试没有模拟到 NSTableView 的情形")
        XCTAssertEqual(taps, 0, "跟踪循环视图上的 onTapGesture 触发了——SwiftUI 已能看到被跟踪循环取走的事件，"
                       + "onPointerDown 可能已经没有存在必要")
        XCTAssertEqual(pointerDowns, 1, "onPointerDown 在跟踪循环视图上没触发——本包的核心功能坏了")
    }

    /// 仿 `NSTableView` / `NSTextView`：在 mouseDown 里自己用 `nextEvent` 取后续事件，mouseUp
    /// 不再经过 `NSApplication.sendEvent`。
    private final class TrackingView: NSView {
        var mouseDowns = 0, trackedMouseUps = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            mouseDowns += 1
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                                until: Date().addingTimeInterval(1),
                                                inMode: .eventTracking, dequeue: true) {
                if next.type == .leftMouseUp { trackedMouseUps += 1; return }
            }
        }
    }

    private struct TrackingRep: NSViewRepresentable {
        let view: TrackingView
        func makeNSView(context: Context) -> TrackingView { view }
        func updateNSView(_ v: TrackingView, context: Context) {}
    }

    /// 测试窗口不是 key、应用也没激活，默认的首次点击会被吞掉；对照组需要宿主接受首击。
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 在窗口中心合成一次左键按下 + 抬起，经 `NSApplication` 的事件队列走完整派发
    /// （本地监视器、手势环境、命中派发都在这条路径上）。窗口由 teardown 收回。
    /// 窗口要真的上屏事件才会派发进来，但摆在所有屏幕之外（同 `WindowDragRegionTests`，不抢屏）。
    private func hostAndClick<V: View>(_ view: V) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.orderOut(nil) }
        let host = FirstMouseHostingView(rootView: view)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let center = NSPoint(x: 200, y: 150)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.3)
        while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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

    /// `isEnabled = false` 的探针连监视器都不装（保活的后台面板用）；翻回来就重新装上。
    func testDisabledProbeInstallsNoMonitor() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let probe = PointerDownProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        probe.isEnabled = false
        window.contentView?.addSubview(probe)
        XCTAssertFalse(probe.isObserving, "关掉的探针不该占一份进程级监视器")

        probe.isEnabled = true
        XCTAssertTrue(probe.isObserving)

        probe.isEnabled = false
        XCTAssertFalse(probe.isObserving)

        probe.isEnabled = true
        probe.removeFromSuperview()
        XCTAssertFalse(probe.isObserving, "离开窗口照样摘掉")
    }
}

#endif
