import XCTest
@testable import UDesignKit

/// `AccentState` 与 UserDefaults 的双向关系：选色要落盘，外部写入（偏好同步）要立刻生效。
@MainActor
final class AccentStateDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AccentStateDefaultsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testSelectingPersists() {
        let state = AccentState(defaults: defaults)
        state.selected = .green
        XCTAssertEqual(defaults.string(forKey: AccentState.key), "green")
    }

    func testExternalWriteUpdatesSelectionWithoutRestart() async {
        let state = AccentState(defaults: defaults)
        XCTAssertEqual(state.selected, .blue)

        defaults.set("red", forKey: AccentState.key)

        await waitUntil { state.selected == .red }
        XCTAssertEqual(state.selected, .red)
    }

    func testExternalWriteNotifiesObservers() async {
        let state = AccentState(defaults: defaults)
        let changed = expectation(description: "selected observed")
        withObservationTracking {
            _ = state.selected
        } onChange: {
            changed.fulfill()
        }

        defaults.set("purple", forKey: AccentState.key)

        await fulfillment(of: [changed], timeout: 2)
    }

    /// 比这个版本新的客户端同步来的颜色：既不能显示成别的，也不能被写回蓝色冲掉。
    func testUnknownStoredValueIsLeftAlone() async {
        defaults.set("orange", forKey: AccentState.key)
        let state = AccentState(defaults: defaults)

        defaults.set("chartreuse", forKey: AccentState.key)
        await drainMainQueue()

        XCTAssertEqual(state.selected, .orange)
        XCTAssertEqual(defaults.string(forKey: AccentState.key), "chartreuse")
    }

    func testRemovedKeyKeepsSelection() async {
        let state = AccentState(defaults: defaults)
        state.selected = .green

        defaults.removeObject(forKey: AccentState.key)
        await drainMainQueue()

        XCTAssertEqual(state.selected, .green)
        XCTAssertNil(defaults.string(forKey: AccentState.key))
    }

    func testWritesToOtherSuitesAreIgnored() async throws {
        let otherName = "AccentStateDefaultsTests-other-\(UUID().uuidString)"
        let other = try XCTUnwrap(UserDefaults(suiteName: otherName))
        defer { other.removePersistentDomain(forName: otherName) }
        let state = AccentState(defaults: defaults)

        other.set("red", forKey: AccentState.key)
        await drainMainQueue()

        XCTAssertEqual(state.selected, .blue)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            OperationQueue.main.addOperation { continuation.resume() }
        }
    }
}
