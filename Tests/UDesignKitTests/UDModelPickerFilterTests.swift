import XCTest
@testable import UDesignKit

final class UDModelPickerFilterTests: XCTestCase {
    private let groups = [
        UDModelPickerGroup(id: "a", title: "Anthropic", items: [
            UDModelPickerItem(id: "a/1", groupID: "a", title: "claude-opus-4-7"),
            UDModelPickerItem(id: "a/2", groupID: "a", title: "claude-haiku-4-5"),
        ]),
        UDModelPickerGroup(id: "d", title: "DeepSeek", items: [
            UDModelPickerItem(id: "d/1", groupID: "d", title: "deepseek-chat"),
            UDModelPickerItem(id: "d/2", groupID: "d", title: "claude-opus-4-7"),
        ]),
        UDModelPickerGroup(id: "o", title: "OpenAI", items: [], status: .loading),
    ]

    func testEmptyQueryKeepsEveryGroupIncludingEmptyOnes() {
        XCTAssertEqual(UDModelPickerFilter.filter(groups, query: "  ").map(\.id), ["a", "d", "o"])
    }

    func testModelNameMatchIsCaseInsensitiveAcrossGroups() {
        let result = UDModelPickerFilter.filter(groups, query: "OPUS")
        XCTAssertEqual(result.map(\.id), ["a", "d"])
        XCTAssertEqual(result.flatMap(\.items).map(\.id), ["a/1", "d/2"])
    }

    func testProviderNameMatchKeepsWholeGroup() {
        let result = UDModelPickerFilter.filter(groups, query: "deeps")
        XCTAssertEqual(result.map(\.id), ["d"])
        XCTAssertEqual(result.first?.items.count, 2)
    }

    func testGroupsWithoutHitsAreDropped() {
        XCTAssertTrue(UDModelPickerFilter.filter(groups, query: "gemini").isEmpty)
        // 分组名命中但组里没有模型（加载中）：搜索时也不留空壳。
        XCTAssertTrue(UDModelPickerFilter.filter(groups, query: "openai").isEmpty)
    }
}
