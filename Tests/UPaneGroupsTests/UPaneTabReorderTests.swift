#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import UPaneGroups

/// 拖动排序：让位规则（不来回抖）、松手落位与显示一致、逐帧看其余标签滑动而空槽直接跳。
@MainActor
final class UPaneTabReorderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: 让位规则

    func testHoveringLeftHalfInsertsBeforeAndRightHalfAfter() {
        let tabs = [a, b, c, d]
        XCTAssertEqual(UPaneTabReorder.slot(tabs: tabs, source: a, hovered: c, trailingHalf: false), .before(c))
        XCTAssertEqual(UPaneTabReorder.slot(tabs: tabs, source: a, hovered: c, trailingHalf: true), .before(d))
        XCTAssertEqual(UPaneTabReorder.slot(tabs: tabs, source: a, hovered: d, trailingHalf: true), .end)
        XCTAssertEqual(UPaneTabReorder.slot(tabs: tabs, source: d, hovered: a, trailingHalf: false), .before(a))
        // 悬停在自己的空槽上：保持当前落位。
        XCTAssertNil(UPaneTabReorder.slot(tabs: tabs, source: b, hovered: b, trailingHalf: true))
        // 别组的标签不归这里排。
        XCTAssertNil(UPaneTabReorder.slot(tabs: tabs, source: UUID(), hovered: b, trailingHalf: true))
    }

    func testDisplayOrderFollowsTheSlot() {
        let tabs = [a, b, c, d]
        XCTAssertEqual(UPaneTabReorder.displayOrder(tabs, source: a, slot: .before(d)), [b, c, a, d])
        XCTAssertEqual(UPaneTabReorder.displayOrder(tabs, source: a, slot: .end), [b, c, d, a])
        XCTAssertEqual(UPaneTabReorder.displayOrder(tabs, source: d, slot: .before(a)), [d, a, b, c])
        XCTAssertEqual(UPaneTabReorder.displayOrder(tabs, source: nil, slot: .end), tabs)
        XCTAssertEqual(UPaneTabReorder.displayOrder(tabs, source: b, slot: nil), tabs)
    }

    /// 回归点：窄标签拖过宽标签时，换位后光标仍落在宽标签上——按「移到悬停位置」会来回换，按半边判不会。
    func testNarrowTabDraggedOverAWideTabDoesNotOscillate() {
        let widths: [UUID: CGFloat] = [a: 40, b: 200]
        func hit(_ order: [UUID], _ x: CGFloat) -> (UUID, Bool)? {
            var left: CGFloat = 0
            for id in order {
                let width = widths[id]!
                if x < left + width { return (id, x - left > width / 2) }
                left += width
            }
            return nil
        }
        var order = [a, b]
        // 光标从 a 往右慢慢扫过 b，每一步按当时的显示判落位，再让显示跟上。
        var history: [[UUID]] = [order]
        for x in stride(from: CGFloat(10), through: 235, by: 5) {
            guard let (hovered, trailing) = hit(order, x),
                  let slot = UPaneTabReorder.slot(tabs: [a, b], source: a, hovered: hovered, trailingHalf: trailing)
            else { continue }
            order = UPaneTabReorder.displayOrder([a, b], source: a, slot: slot)
            if history.last != order { history.append(order) }
        }
        XCTAssertEqual(history, [[a, b], [b, a]], "一路只该换一次")
    }

    /// 松手落在显示的位置：模型改成的顺序与标签条上看到的一致，不会再跳一下。
    func testCommittingASlotMatchesWhatTheStripShowed() {
        let ids = [a, b, c, d]
        for source in ids {
            for slot in ids.filter({ $0 != source }).map(UPaneReorderSlot.before) + [.end] {
                let model = UPaneGroupsModel<Int>()
                for (n, id) in ids.enumerated() { model.openTab({ UPaneTab(id: id, payload: n) }, in: nil) }
                let group = try! XCTUnwrap(model.activeGroupID)
                let shown = UPaneTabReorder.displayOrder(ids, source: source, slot: slot)
                model.moveTab(source, to: slot, inGroup: group)
                XCTAssertEqual(model.groups[group]?.tabs.map(\.id), shown, "\(slot)")
                XCTAssertEqual(model.activeTab?.id, source, "落下的标签成为前台")
            }
        }
    }

    func testReorderPreviewIsDedupedAndClearedWhenTheDragEnds() {
        let state = UPaneDragState()
        let group = UUID()
        state.draggingTabID = a
        state.draggingSourceGroupID = group
        state.setReorderPreview(UPaneReorderPreview(groupID: group, slot: .end))
        XCTAssertEqual(state.reorderPreview?.slot, .end)
        state.end()
        XCTAssertNil(state.reorderPreview)
        XCTAssertNil(state.draggingTabID)
    }

    // MARK: 逐帧

    final class ChipView: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    }

    struct Chip: NSViewRepresentable {
        let id: UUID
        let probe: Probe
        func makeNSView(context: Context) -> ChipView {
            let view = ChipView()
            probe.views[id] = view
            return view
        }
        func updateNSView(_ nsView: ChipView, context: Context) { probe.views[id] = nsView }
    }

    final class Probe {
        var views: [UUID: NSView] = [:]
        /// 屏幕上（含动画中）看到的左边缘。
        func x(_ id: UUID) -> CGFloat? {
            guard let view = views[id], let layer = view.layer else { return views[id]?.frame.minX }
            let shown = layer.presentation() ?? layer
            return (view.superview?.convert(shown.frame.origin, to: nil) ?? shown.frame.origin).x
        }
    }

    private func host(_ state: UPaneDragState, group: UUID, probe: Probe, reduceMotion: Bool = false) -> (NSWindow, NSView) {
        let ids = [a, b, c]
        let row = UPaneTabRow(tabIDs: ids, groupID: group, dragState: state, spacing: 2,
                              reduceMotionOverride: reduceMotion) { id in
            Chip(id: id, probe: probe).frame(width: 80, height: 26)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostView = NSHostingView(rootView: row.frame(width: 400, height: 60, alignment: .leading))
        window.contentView = hostView
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (window, hostView)
    }

    /// 每 8ms 采一次，采 `duration` 这么久。
    private func samples(_ probe: Probe, _ ids: [UUID], for duration: TimeInterval) -> [[UUID: CGFloat]] {
        var frames: [[UUID: CGFloat]] = []
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            var frame: [UUID: CGFloat] = [:]
            for id in ids { frame[id] = probe.x(id) }
            frames.append(frame)
        }
        return frames
    }

    func testNeighboursSlideWhileThePlaceholderJumps() throws {
        let state = UPaneDragState(), group = UUID(), probe = Probe()
        let (window, _) = host(state, group: group, probe: probe)
        defer { window.orderOut(nil) }
        let start = [a, b, c].map { probe.x($0)! }
        XCTAssertEqual(start[1] - start[0], 82, accuracy: 0.5)

        // 拖 a 到 c 后面：b、c 各左移一格，a 的空槽跳到末尾。
        state.draggingTabID = a
        state.draggingSourceGroupID = group
        state.setReorderPreview(UPaneReorderPreview(groupID: group, slot: .end))
        let frames = samples(probe, [a, b, c], for: 0.4)
        let bPath = frames.compactMap { $0[b] }
        let aPath = frames.compactMap { $0[a] }
        let intermediateB = bPath.filter { $0 > start[0] + 1 && $0 < start[1] - 1 }
        XCTAssertGreaterThan(intermediateB.count, 3, "b 应该滑过去，实际路径 \(bPath.map { Int($0) })")
        let intermediateA = aPath.filter { $0 > start[0] + 1 && $0 < start[2] - 1 }
        XCTAssertEqual(intermediateA, [], "空槽不该滑，实际路径 \(aPath.map { Int($0) })")
        XCTAssertEqual(bPath.last!, start[0], accuracy: 0.5)
        XCTAssertEqual(probe.x(c)!, start[1], accuracy: 0.5)
        XCTAssertEqual(aPath.last!, start[2], accuracy: 0.5)

        // 接着往回拖一格（a 插到 c 前面）：已经是空槽的 a 再挪一次也是跳，c 滑回右边。
        state.setReorderPreview(UPaneReorderPreview(groupID: group, slot: .before(c)))
        let second = samples(probe, [a, c], for: 0.4)
        let aBack = second.compactMap { $0[a] }
        let cBack = second.compactMap { $0[c] }
        XCTAssertEqual(aBack.filter { $0 > start[1] + 1 && $0 < start[2] - 1 }, [],
                       "空槽第二次挪也不该滑，实际路径 \(aBack.map { Int($0) })")
        XCTAssertGreaterThan(cBack.filter { $0 > start[1] + 1 && $0 < start[2] - 1 }.count, 3,
                             "c 应该滑回去，实际路径 \(cBack.map { Int($0) })")
        XCTAssertEqual(aBack.last!, start[1], accuracy: 0.5)
        XCTAssertEqual(cBack.last!, start[2], accuracy: 0.5)
    }

    func testReduceMotionSwapsWithoutSliding() throws {
        let state = UPaneDragState(), group = UUID(), probe = Probe()
        let (window, _) = host(state, group: group, probe: probe, reduceMotion: true)
        defer { window.orderOut(nil) }
        let start = [a, b, c].map { probe.x($0)! }
        state.draggingTabID = a
        state.draggingSourceGroupID = group
        state.setReorderPreview(UPaneReorderPreview(groupID: group, slot: .end))
        let bPath = samples(probe, [b], for: 0.3).compactMap { $0[b] }
        XCTAssertEqual(bPath.filter { $0 > start[0] + 1 && $0 < start[1] - 1 }, [], "实际路径 \(bPath.map { Int($0) })")
        XCTAssertEqual(bPath.last!, start[0], accuracy: 0.5)
    }
}
#endif
