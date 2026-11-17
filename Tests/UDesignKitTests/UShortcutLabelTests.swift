import XCTest
@testable import UDesignKit

final class UShortcutLabelTests: XCTestCase {
    func testModifiersAreSeparatedFromEachOtherAndTheKey() {
        XCTAssertEqual(UFormat.shortcut("⌥⌘O"), "⌥ ⌘ O")
        XCTAssertEqual(UFormat.shortcut("⇧⌘P"), "⇧ ⌘ P")
        XCTAssertEqual(UFormat.shortcut("⌘K"), "⌘ K")
        XCTAssertEqual(UFormat.shortcut("⌘,"), "⌘ ,")
    }

    func testKeyNamesStayWhole() {
        XCTAssertEqual(UFormat.shortcut("esc"), "esc")
        XCTAssertEqual(UFormat.shortcut("⌘Tab"), "⌘ Tab")
        XCTAssertEqual(UFormat.shortcut("↩"), "↩")
        XCTAssertEqual(UFormat.shortcut("⌘"), "⌘")
    }

    func testIdempotent() {
        XCTAssertEqual(UFormat.shortcut("⌥ ⌘ O"), "⌥ ⌘ O")
        XCTAssertEqual(UFormat.shortcut(UFormat.shortcut("⌃⇧⌘4")), "⌃ ⇧ ⌘ 4")
    }
}
