import XCTest
@testable import UDesignKit

/// 渲染窗口与贴底策略（由 uTerm `AgentMessageWindowTests` / `AgentStreamingPolicyTests` 移植）。
/// 钉的是「只裁渲染、不裁数据」的窗口算术，以及「听可滚高度、按窗口合并」的贴底规则。
@MainActor
final class UDAgentTranscriptPolicyTests: XCTestCase {
    // MARK: - 窗口算术

    func testWindowKeepsTheTailAndNeverDropsBelowZero() {
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 1000, limit: 200), 800)
        XCTAssertEqual(UDTranscriptWindow.hiddenCount(count: 1000, limit: 200), 800)
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 200, limit: 200), 0)
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 10, limit: 200), 0)
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 1000, limit: Int.max), 0)
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 1000, limit: 0), 0)
        XCTAssertEqual(UDTranscriptWindow.startIndex(count: 0, limit: 200), 0)
        XCTAssertEqual(UDTranscriptWindow.hiddenCount(count: 200, limit: 200), 0)
    }

    func testWindowExpansionSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(UDTranscriptWindow.expanded(200, count: 1000), 400)
        XCTAssertEqual(UDTranscriptWindow.expanded(200, count: 300), 300, "剩下不足一步就直接放开全部")
        XCTAssertEqual(UDTranscriptWindow.expanded(1000, count: 1000), 1000)
        XCTAssertEqual(UDTranscriptWindow.expanded(Int.max, count: 1000), 1000)
        XCTAssertEqual(UDTranscriptWindow.expanded(Int.max - 1, count: Int.max), Int.max)
    }

    // MARK: - 贴底

    func testNearBottomAllowsShortContentAndToleranceBand() {
        XCTAssertTrue(UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: 400, contentHeight: 300))
        XCTAssertTrue(UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: 910, contentHeight: 1_000))
        XCTAssertFalse(UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: 800, contentHeight: 1_000))
        XCTAssertFalse(UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: .nan, contentHeight: 1_000))
        XCTAssertFalse(UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: 1_000, contentHeight: .infinity))
    }

    private typealias Tail = UDTranscriptScrollPolicy.TailGeometry

    func testTailGeometryMeasuresContentBeyondViewport() {
        let pinned = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertEqual(pinned.scrollableHeight, 400)
        XCTAssertTrue(pinned.isNearBottom)
        XCTAssertEqual(Tail(contentHeight: 300, containerHeight: 600, visibleMaxY: 600).scrollableHeight, 0)
        XCTAssertEqual(Tail(contentHeight: .nan, containerHeight: 600, visibleMaxY: 600).scrollableHeight, 0)
    }

    func testRepinWhenPinnedContentGrowsOrViewportShrinks() {
        let before = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertTrue(UDTranscriptScrollPolicy.needsRepin(
            from: before, to: Tail(contentHeight: 1_120, containerHeight: 600, visibleMaxY: 1_000)),
            "流式 Markdown 重排把内容撑高")
        XCTAssertTrue(UDTranscriptScrollPolicy.needsRepin(
            from: before, to: Tail(contentHeight: 1_000, containerHeight: 560, visibleMaxY: 960)),
            "排队条带把视口挤矮")
    }

    func testNoRepinAwayFromBottomOrWhenHeightHolds() {
        let away = Tail(contentHeight: 3_000, containerHeight: 600, visibleMaxY: 1_400)
        XCTAssertFalse(UDTranscriptScrollPolicy.needsRepin(
            from: away, to: Tail(contentHeight: 3_400, containerHeight: 600, visibleMaxY: 1_400)))
        let pinned = Tail(contentHeight: 1_000, containerHeight: 600, visibleMaxY: 1_000)
        XCTAssertFalse(UDTranscriptScrollPolicy.needsRepin(
            from: pinned, to: Tail(contentHeight: 1_000.3, containerHeight: 600, visibleMaxY: 1_000)))
        XCTAssertFalse(UDTranscriptScrollPolicy.needsRepin(
            from: pinned, to: Tail(contentHeight: 900, containerHeight: 600, visibleMaxY: 900)))
    }

    // MARK: - 合并器

    func testCoalescerFiresOncePerWindow() async throws {
        let coalescer = UDTailScrollCoalescer(delay: 0.02)
        var fired = 0
        coalescer.schedule { fired += 1 }
        coalescer.schedule { fired += 100 }
        XCTAssertTrue(coalescer.isPending)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(coalescer.isPending)
        coalescer.schedule { fired += 1 }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fired, 2)
    }

    func testCoalescerRestartDebouncesAndCancelDrops() async throws {
        let coalescer = UDTailScrollCoalescer(delay: 0.03)
        var log: [String] = []
        coalescer.restart { log.append("first") }
        coalescer.restart { log.append("second") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log, ["second"])
        coalescer.schedule { log.append("dropped") }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log, ["second"])
    }

    func testToolTraceTruncatesDisplayOnly() {
        let long = String(repeating: "a", count: 5_000)
        let shown = UDAgentToolTrace.truncated(long)
        XCTAssertTrue(shown.hasPrefix(String(repeating: "a", count: UDAgentToolTrace.displayCap)))
        XCTAssertTrue(shown.contains("全文 5000 字符"))
        XCTAssertEqual(UDAgentToolTrace.truncated("short"), "short")
    }
}
