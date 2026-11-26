#if canImport(AppKit)
import XCTest
@testable import UDesignKit

/// 菜单行的底色（用户报的：侧栏「分组与显示」菜单里勾着的几项连着铺满选中底，糊成一大块）：
/// 只有单选的「当前项」（`active`）铺选中底；开关类的勾选（`checked`）只打对勾，hover 时才有底。
@MainActor
final class UDMenuRowFillTests: XCTestCase {
    func testActiveRowKeepsTheSelectedFill() {
        XCTAssertEqual(UDMenuRowFill(active: true, hovered: false), .selected)
        XCTAssertEqual(UDMenuRowFill(active: true, hovered: true), .selected)
    }

    func testCheckedRowHasNoFillUntilHovered() {
        let item = UDMenuItem(label: "Codex", checked: true)
        XCTAssertTrue(item.checked)
        XCTAssertFalse(item.active, "勾选不是选中")
        XCTAssertEqual(UDMenuRowFill(active: item.active, hovered: false), .none)
        XCTAssertEqual(UDMenuRowFill(active: item.active, hovered: true), .hover)
    }
}
#endif
