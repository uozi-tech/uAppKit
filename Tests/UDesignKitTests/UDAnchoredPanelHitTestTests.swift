#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 锚定浮层的锚点视图只量位置，对命中测试透明：放进 overlay 盖在别的内容上时不吞点击。
@MainActor
final class UDAnchoredPanelHitTestTests: XCTestCase {
    func testAnchorViewDoesNotSwallowClicks() throws {
        _ = NSApplication.shared
        let view = Color.blue
            .frame(width: 300, height: 200)
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 300, height: 200)
                    .allowsHitTesting(false)
                    .anchoredPanel(isPresented: .constant(false)) { _ in Text("浮层") }
            }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        // 锚点视图：SwiftUI 宿主下由 representable 挂进来的那个裸视图（旧实现是 `NSView()`，现在是
        // `PassthroughAnchorView`）——按类型找，不靠类名，换回旧实现时这条测试会红。
        func anchors(in root: NSView) -> [NSView] {
            let isAnchor = root is PassthroughAnchorView || type(of: root) == NSView.self
            return (isAnchor && root !== content ? [root] : []) + root.subviews.flatMap(anchors)
        }
        let anchorViews = anchors(in: content)
        XCTAssertFalse(anchorViews.isEmpty, "锚点视图应该挂在层级里")
        for point in [NSPoint(x: 20, y: 20), NSPoint(x: 150, y: 100), NSPoint(x: 280, y: 180)] {
            let hit = content.hitTest(point)
            XCTAssertFalse(anchorViews.contains { $0 === hit }, "\(point) 落到了锚点视图上：\(String(describing: hit))")
        }
    }
}
#endif
