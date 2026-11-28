import XCTest
@testable import UDesignKit

/// 设置行整数输入框的钳值：提交时把草稿钳进 `minValue...maxValue`，钳后的值同时写回输入框。
final class UDSettingsNumberFieldTests: XCTestCase {
    func testClampKeepsValuesInRange() {
        XCTAssertEqual(UDSettingsNumberField.clamped(999, min: 1, max: 100), 100)
        XCTAssertEqual(UDSettingsNumberField.clamped(-5, min: 1, max: 100), 1)
        XCTAssertEqual(UDSettingsNumberField.clamped(42, min: 1, max: 100), 42)
        XCTAssertEqual(UDSettingsNumberField.clamped(.max, min: 0, max: .max), .max)
    }

    /// 回归：越界值不再走「钳值绑定」——值已在边界时绑定无变化，框里会留着越界的字。
    func testFieldCommitsThroughDraftNotClampingBinding() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UDesignKit/Settings/UDSettings.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("TextField(\"\", value: $draft, format: .number)"))
        XCTAssertFalse(source.contains("set: { value = min(maxValue, max(minValue, $0)) }"))
    }
}
