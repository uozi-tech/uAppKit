#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import UPaneGroups

/// 窗口级标签条与「组标签条隐藏」的编辑区。真实拖拽会话测不了（见 `UPaneGroupAreaViewTests` 的说明），
/// 这里核挂载与几何。
@MainActor
final class UWindowTabStripViewTests: XCTestCase {

    final class MarkerView: NSView {}
    struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> MarkerView { MarkerView() }
        func updateNSView(_ nsView: MarkerView, context: Context) {}
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 800, height: 600)) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (window, host)
    }

    private func markers(in view: NSView) -> [MarkerView] {
        (view as? MarkerView).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }

    func testHiddenGroupStripStartsContentAtTheTopOfTheGroup() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch) }
        let view = UPaneGroupArea(
            model: model, dragType: .plainText, stripHeight: 40,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { _, _ in Marker() },
            emptyGroup: { _ in Color.clear }, onRequestClose: { _ in })
            .uPaneGroupTabStrip(.hidden)
        let (window, hostView) = host(view)
        defer { window.contentView = nil }

        let marker = try XCTUnwrap(markers(in: hostView).first)
        let frame = marker.convert(marker.bounds, to: hostView)
        // NSHostingView 是翻转坐标：minY = 距顶。
        XCTAssertEqual(hostView.isFlipped ? frame.minY : hostView.bounds.height - frame.maxY, 0, accuracy: 0.5,
                       "组标签条隐藏时内容从组的顶边开始")
        XCTAssertEqual(frame.height, 600, accuracy: 0.5)
    }

    func testHiddenGroupStripWithWellsInsetsTheTopEdgeLikeTheOtherOuterEdges() {
        let pane = CGRect(x: 0, y: 0, width: 400, height: 300)
        let insets = UPaneGroupGeometry.wellInsets(paneRect: pane, areaSize: pane.size, stripHeight: 0)
        XCTAssertEqual(insets.top, UPaneWellMetrics.inset)
        XCTAssertEqual(insets.leading, UPaneWellMetrics.inset)

        let lower = CGRect(x: 0, y: 150, width: 400, height: 150)
        XCTAssertEqual(UPaneGroupGeometry.wellInsets(paneRect: lower, areaSize: pane.size, stripHeight: 0).top, 0,
                       "下面那一格与上一格相接，顶边不缩")
    }

    func testWindowStripRendersOneChipPerTabAndNarrowsToItsContent() {
        let ids = [UUID(), UUID(), UUID()]
        let strip = HStack(spacing: 0) {
            UWindowTabStrip(
                stripID: UUID(), tabIDs: ids, activeTabID: ids[1], dragType: .plainText,
                descriptor: { _ in UPaneTabDescriptor(title: "tab") },
                onActivate: { _ in }, onRequestClose: { _ in }, onMove: { _, _ in })
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        let (window, hostView) = host(strip, size: NSSize(width: 1200, height: 38))
        defer { window.contentView = nil }
        // 三枚「tab」胶囊远窄于 1200：标签条只占内容宽，后面留给「＋」与拖窗空白。
        XCTAssertGreaterThan(hostView.fittingSize.width, 0)
        let scroll = firstScrollView(in: hostView)
        XCTAssertNotNil(scroll)
        XCTAssertLessThan(scroll?.frame.width ?? .infinity, 600)
    }

    /// 窗口一出现、当前标签就在放不下的那一截里（重启接回、拖出成新窗口）：一开始就滚到它，不等它下次换。
    func testActiveTabFarToTheRightIsScrolledIntoViewOnFirstAppearance() throws {
        let ids = (0..<12).map { _ in UUID() }
        let strip = HStack(spacing: 0) {
            UWindowTabStrip(
                stripID: UUID(), tabIDs: ids, activeTabID: ids[10], dragType: .plainText,
                descriptor: { _ in UPaneTabDescriptor(title: "a fairly long tab title") },
                onActivate: { _ in }, onRequestClose: { _ in }, onMove: { _, _ in })
            Spacer(minLength: 40)
        }
        let (window, hostView) = host(strip, size: NSSize(width: 500, height: 38))
        defer { window.contentView = nil }

        let scroll = try XCTUnwrap(firstScrollView(in: hostView))
        let visible = scroll.contentView.bounds
        let content = try XCTUnwrap(scroll.documentView).frame.width
        XCTAssertGreaterThan(content, visible.width, "标签放不下，要能滚")
        XCTAssertGreaterThan(visible.minX, content / 2, "第 11 个标签在后半截：一出现就滚过去了")
    }

    func testEmptyMenuOverloadBuilds() {
        let strip = UWindowTabStrip(
            stripID: UUID(), tabIDs: [UUID()], activeTabID: nil, dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "a") },
            onActivate: { _ in }, onRequestClose: { _ in }, onMove: { _, _ in },
            onDragEnded: { _, _, _ in })
        let (window, _) = host(strip)
        window.contentView = nil
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let hit = firstScrollView(in: sub) { return hit } }
        return nil
    }
}
#endif
