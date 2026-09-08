// macOS 专用：理由同 `PointerDownProbeTests.swift`。
#if os(macOS)

import AppKit
import SwiftUI
import XCTest
@testable import UAppKitBridge

/// 三层（点击 / 拖放 / 悬停）共用的那套行几何算术。
final class UniformRowHitTests: XCTestCase {

    /// 反推行高档：容器高 200 / 10 行 = 每行 20。
    func testDerivedRowHeight() {
        XCTAssertEqual(UniformRowHit.index(atY: 0, containerHeight: 200, rowCount: 10), 0)
        XCTAssertEqual(UniformRowHit.index(atY: 19.9, containerHeight: 200, rowCount: 10), 0)
        XCTAssertEqual(UniformRowHit.index(atY: 20, containerHeight: 200, rowCount: 10), 1)
        XCTAssertEqual(UniformRowHit.index(atY: 199.9, containerHeight: 200, rowCount: 10), 9)
        XCTAssertNil(UniformRowHit.index(atY: -1, containerHeight: 200, rowCount: 10))
        XCTAssertNil(UniformRowHit.index(atY: 200, containerHeight: 200, rowCount: 10))
        XCTAssertNil(UniformRowHit.index(atY: 10, containerHeight: 200, rowCount: 0))
        XCTAssertNil(UniformRowHit.index(atY: 10, containerHeight: 0, rowCount: 10))
    }

    /// 定高档 + 高度不同的首行（文件表的 `..` 是 46，条目行是 52）。
    func testFixedHeightWithLeadingRow() {
        func slot(_ y: CGFloat) -> UniformRowHit.RowSlot? {
            UniformRowHit.slot(atY: y, rowHeight: 52, rowCount: 3, leadingRowHeight: 46)
        }
        XCTAssertEqual(slot(0), .leading)
        XCTAssertEqual(slot(45.9), .leading)
        XCTAssertEqual(slot(46), .row(0))
        XCTAssertEqual(slot(46 + 51.9), .row(0))
        XCTAssertEqual(slot(46 + 52), .row(1))
        XCTAssertNil(slot(-1))
        XCTAssertNil(slot(46 + 52 * 3))

        // 没有首行时 y=0 就是第 0 行。
        XCTAssertEqual(UniformRowHit.slot(atY: 0, rowHeight: 30, rowCount: 2), .row(0))
        XCTAssertNil(UniformRowHit.slot(atY: 60, rowHeight: 30, rowCount: 2))
    }

    /// 分组档：组头 22 + 组内 52 的行 + 组间 12。
    func testGroupedRows() {
        let counts = [2, 3]
        func hit(_ y: CGFloat) -> (section: Int, row: Int)? {
            UniformRowHit.groupedRow(atY: y, headerHeight: 22, rowHeight: 52, spacing: 12,
                                     rowCounts: counts)
        }
        XCTAssertNil(hit(0), "组头上不算命中任何行")
        XCTAssertNil(hit(21.9))
        XCTAssertEqual(hit(22)?.section, 0)
        XCTAssertEqual(hit(22)?.row, 0)
        XCTAssertEqual(hit(22 + 51.9)?.row, 0)
        XCTAssertEqual(hit(22 + 52)?.row, 1)

        let firstSection = 22 + 52 * 2                    // 第一组高 126
        XCTAssertNil(hit(CGFloat(firstSection) + 5), "组间空隙不算命中")
        let secondHeader = CGFloat(firstSection) + 12
        XCTAssertNil(hit(secondHeader + 21.9), "第二组组头")
        XCTAssertEqual(hit(secondHeader + 22)?.section, 1)
        XCTAssertEqual(hit(secondHeader + 22)?.row, 0)
        XCTAssertEqual(hit(secondHeader + 22 + 52 * 2)?.row, 2)
        XCTAssertNil(hit(secondHeader + 22 + 52 * 3), "末行之后")
    }

    /// 空组也要能跨过去（组头照常占位，组内 0 行）。
    func testGroupedRowsSkipsEmptySection() {
        let hit = UniformRowHit.groupedRow(atY: 22 + 12 + 22, headerHeight: 22, rowHeight: 52,
                                           spacing: 12, rowCounts: [0, 1])
        XCTAssertEqual(hit?.section, 1)
        XCTAssertEqual(hit?.row, 0)
    }
}

/// `RowHoverState` 的最小失效面：悬停在行之间挪动**只**翻前后两个盒子。
@MainActor
final class RowHoverStateTests: XCTestCase {

    func testOnlyTwoBoxesFlip() {
        let state = RowHoverState(isEnabled: true)
        let boxes = (0..<5).map { state.box(for: $0) }

        state.setHovered(2)
        XCTAssertTrue(boxes[2].isHovered)
        XCTAssertEqual(boxes.filter(\.isHovered).count, 1)

        state.setHovered(3)
        XCTAssertFalse(boxes[2].isHovered)
        XCTAssertTrue(boxes[3].isHovered)
        XCTAssertEqual(boxes.filter(\.isHovered).count, 1)

        state.setHovered(nil)
        XCTAssertTrue(boxes.allSatisfy { !$0.isHovered })
        XCTAssertNil(state.hoveredID)
    }

    /// 同一个 id 拿到的必须是同一个盒子 —— 否则行每求一次 body 就换一个观察源。
    func testBoxIdentityIsStable() {
        let state = RowHoverState(isEnabled: true)
        XCTAssertTrue(state.box(for: "a") === state.box(for: "a"))
        XCTAssertFalse(state.box(for: "a") === state.box(for: "b"))
    }
}

/// 追踪层本身：一块追踪区、按落点算行、滚动期间不更新、停下补算一次。
@MainActor
final class RowHoverTrackerViewTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    /// 造一个 300×400 的窗口，里面一个 10 行 × 40pt 的追踪层。
    private func makeTracker(gate: ScrollHoverGate?) -> (RowHoverTrackerView, RowHoverState) {
        let state = RowHoverState(isEnabled: true)
        let tracker = RowHoverTrackerView()
        tracker.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        tracker.state = state
        tracker.gate = gate
        tracker.geometry = .fixedHeight(rowHeight: 40, rowCount: 10) { index in
            index.map { AnyHashable($0) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        host.addSubview(tracker)
        window.contentView = host
        windows.append(window)
        return (tracker, state)
    }

    /// 窗口坐标（原点左下）里、落在第 `row` 行上的点。追踪层自身是 flipped 的。
    private func windowPoint(row: Int) -> NSPoint {
        NSPoint(x: 150, y: 400 - (CGFloat(row) * 40 + 20))
    }

    private func move(_ tracker: RowHoverTrackerView, to row: Int) {
        let event = NSEvent.mouseEvent(with: .mouseMoved,
                                       location: windowPoint(row: row),
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: tracker.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tracker.mouseMoved(with: event)
    }

    /// 整块只有一个追踪区（本轮的**结构判据**：改前是每行一块）。
    func testInstallsExactlyOneTrackingArea() {
        defer { closeAllWindows() }
        let (tracker, _) = makeTracker(gate: nil)
        XCTAssertEqual(tracker.trackingAreas.count, 1,
                       "整表只该有一块追踪区，实测 \(tracker.trackingAreas.count)")
        let options = tracker.trackingAreas[0].options
        XCTAssertTrue(options.contains(.mouseMoved))
        XCTAssertTrue(options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(options.contains(.inVisibleRect))
        XCTAssertTrue(options.contains(.activeInActiveApp))

        // 几何变化不该让它拆了重建 —— `.inVisibleRect` 就是为了省这一步。
        tracker.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
        tracker.updateTrackingAreas()
        XCTAssertEqual(tracker.trackingAreas.count, 1)
    }

    /// 落点 → 行：光标在第 3 行上，state 就该悬第 3 行。
    func testMouseMovedMapsPointToRow() {
        defer { closeAllWindows() }
        let (tracker, state) = makeTracker(gate: nil)
        move(tracker, to: 3)
        XCTAssertEqual(state.hoveredID, AnyHashable(3))
        move(tracker, to: 7)
        XCTAssertEqual(state.hoveredID, AnyHashable(7))
    }

    /// 落在容器外（追踪层高度之外）不悬任何行。
    func testPointOutsideClearsHover() {
        defer { closeAllWindows() }
        let (tracker, state) = makeTracker(gate: nil)
        move(tracker, to: 2)
        XCTAssertEqual(state.hoveredID, AnyHashable(2))
        let below = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 150, y: -20),
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: tracker.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tracker.mouseMoved(with: below)
        XCTAssertNil(state.hoveredID)
    }

    /// 滚动期间不更新，进滚动那一刻把当前行灭掉；停下之后 `refreshFromWindow` 补算。
    func testGateSuspendsUpdatesAndSuspendClearsCurrentRow() {
        defer { closeAllWindows() }
        let gate = ScrollHoverGate()
        let (tracker, state) = makeTracker(gate: gate)
        move(tracker, to: 4)
        XCTAssertEqual(state.hoveredID, AnyHashable(4))

        gate.noteActivity()
        tracker.suspend()
        XCTAssertNil(state.hoveredID, "进滚动要把亮着的那一行灭掉")

        RowHoverStats.reset()
        move(tracker, to: 6)
        XCTAssertNil(state.hoveredID, "滚动期间不更新悬停行")
        XCTAssertEqual(RowHoverStats.forwarded, 0)
        XCTAssertGreaterThan(RowHoverStats.suppressed, 0, "被吃掉的那一次要记账")

        gate.settle()
        move(tracker, to: 6)
        XCTAssertEqual(state.hoveredID, AnyHashable(6), "停下之后恢复更新")
    }

    /// 关掉（探针的改前臂）之后 state 一动不动。
    func testDisabledStateIsInert() {
        defer { closeAllWindows() }
        let state = RowHoverState(isEnabled: false)
        let tracker = RowHoverTrackerView()
        tracker.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        tracker.state = state
        tracker.geometry = .fixedHeight(rowHeight: 40, rowCount: 10) { $0.map { AnyHashable($0) } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tracker
        windows.append(window)
        move(tracker, to: 3)
        XCTAssertNil(state.hoveredID)
    }
}

#endif
