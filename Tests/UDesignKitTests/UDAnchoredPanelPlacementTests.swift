import AppKit
import XCTest
@testable import UDesignKit

final class UDAnchoredPanelPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testPanelFittingOnScreenStaysAligned() {
        XCTAssertEqual(UDAnchoredPanelPlacement.clampedX(100, panelWidth: 348, inset: 24,
                                                         visible: screen, margin: 8), 100)
    }

    /// 靠右的 Agent 侧栏：左对齐触发器的 300pt 浮层会伸出屏幕右缘 → 推回来。
    func testPanelPastRightEdgeIsPulledBack() {
        let x = UDAnchoredPanelPlacement.clampedX(1250, panelWidth: 348, inset: 24,
                                                  visible: screen, margin: 8)
        // 内容右沿 = x + 348 - 24 应正好停在 1440 - 8。
        XCTAssertEqual(x + 348 - 24, 1432)
    }

    func testPanelPastLeftEdgeIsPushedRight() {
        let x = UDAnchoredPanelPlacement.clampedX(-80, panelWidth: 348, inset: 24,
                                                  visible: screen, margin: 8)
        XCTAssertEqual(x + 24, 8)
    }

    func testSecondaryScreenOriginIsRespected() {
        let right = NSRect(x: 1440, y: 0, width: 1280, height: 800)
        let x = UDAnchoredPanelPlacement.clampedX(2600, panelWidth: 348, inset: 24,
                                                  visible: right, margin: 8)
        XCTAssertEqual(x + 348 - 24, 2712)
    }

    func testNoScreenLeavesPositionAlone() {
        XCTAssertEqual(UDAnchoredPanelPlacement.clampedX(5000, panelWidth: 348, inset: 24,
                                                         visible: nil, margin: 8), 5000)
    }
}
