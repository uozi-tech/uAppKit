import XCTest
import CoreGraphics
@testable import UPaneTree

/// 摊平几何。移植自 uTable 的 `UTableEditorGroupTests`。
final class LayoutFramesTests: XCTestCase {

    func testFramesForSingleLeafFillsRect() {
        let a = UUID()
        let frames = LayoutNode.leaf(paneID: a)
            .frames(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(frames.panes.count, 1)
        XCTAssertTrue(frames.splitters.isEmpty)
        XCTAssertEqual(frames.panes[0].paneID, a)
        XCTAssertEqual(frames.panes[0].rect, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testFramesForHorizontalSplitLeavesRoomForSplitter() {
        let a = UUID(), b = UUID(), splitID = UUID()
        let tree = LayoutNode.leaf(paneID: a)
            .splitting(paneID: a, direction: .horizontal, newPaneID: b, splitID: splitID)
        let thickness = LayoutNode.splitterThickness
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(frames.panes.map(\.paneID), [a, b])
        XCTAssertEqual(frames.panes[0].rect, CGRect(x: 0, y: 0, width: 400, height: 600))
        XCTAssertEqual(frames.panes[1].rect,
                       CGRect(x: 400 + thickness, y: 0, width: 400 - thickness, height: 600))
        XCTAssertEqual(frames.splitters.count, 1)
        XCTAssertEqual(frames.splitters[0].splitID, splitID)
        XCTAssertEqual(frames.splitters[0].totalLength, 800)
        XCTAssertEqual(frames.splitters[0].rect,
                       CGRect(x: 400, y: 0, width: thickness, height: 600))
    }

    func testFramesNestSplitsWithinParentRect() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = LayoutNode.leaf(paneID: a)
            .splitting(paneID: a, direction: .horizontal, newPaneID: b, splitID: UUID())
            .splitting(paneID: b, direction: .vertical, newPaneID: c, splitID: UUID())
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(frames.panes.map(\.paneID), [a, b, c])
        // b / c 都待在右半边，且没有一个溢出容器。
        for pane in frames.panes {
            XCTAssertLessThanOrEqual(pane.rect.maxX, 800)
            XCTAssertLessThanOrEqual(pane.rect.maxY, 600)
        }
        XCTAssertEqual(frames.panes[1].rect.minX, frames.panes[2].rect.minX)
        XCTAssertLessThan(frames.panes[1].rect.maxY, frames.panes[2].rect.minY)
    }
}
