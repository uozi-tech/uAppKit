import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class AgentModelCatalogTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "AgentModelCatalogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private struct Boom: Error {}

    private func catalog(now: @escaping () -> Date = Date.init) -> AgentModelCatalog {
        AgentModelCatalog(defaults: defaults, describe: { _ in "失败了" }, now: now)
    }

    func testLoadsEveryProviderAndPersists() async {
        let a = UUID(), b = UUID()
        let c = catalog()
        c.refresh([
            .init(providerID: a, endpoint: "anthropic|x") { ["claude-opus-4-7", "claude-haiku-4-5"] },
            .init(providerID: b, endpoint: "openai|y") { ["gpt-5"] },
        ])
        XCTAssertTrue(c.isRefreshing)
        await c.waitUntilSettled()
        XCTAssertFalse(c.isRefreshing)
        XCTAssertEqual(c.entry(for: a)?.models, ["claude-opus-4-7", "claude-haiku-4-5"])
        XCTAssertEqual(c.entry(for: b)?.models, ["gpt-5"])

        // 重启后直接有列表。
        let reloaded = catalog()
        XCTAssertEqual(reloaded.entry(for: a)?.models, ["claude-opus-4-7", "claude-haiku-4-5"])
        XCTAssertEqual(reloaded.entry(for: a)?.isLoading, false)
    }

    func testFailureKeepsPreviousModels() async {
        let a = UUID()
        var clock = Date(timeIntervalSince1970: 0)
        let c = catalog(now: { clock })
        c.refresh([.init(providerID: a, endpoint: "e") { ["m1"] }])
        await c.waitUntilSettled()

        clock += AgentModelCatalog.freshness + 1
        c.refresh([.init(providerID: a, endpoint: "e") { throw Boom() }])
        await c.waitUntilSettled()
        XCTAssertEqual(c.entry(for: a)?.models, ["m1"])
        XCTAssertEqual(c.entry(for: a)?.error, "失败了")
    }

    func testFreshListIsNotRefetchedUnlessForced() async {
        let a = UUID()
        let c = catalog()
        c.refresh([.init(providerID: a, endpoint: "e") { ["m1"] }])
        await c.waitUntilSettled()

        c.refresh([.init(providerID: a, endpoint: "e") { ["m2"] }])
        await c.waitUntilSettled()
        XCTAssertEqual(c.entry(for: a)?.models, ["m1"])

        c.refresh([.init(providerID: a, endpoint: "e") { ["m2"] }], force: true)
        await c.waitUntilSettled()
        XCTAssertEqual(c.entry(for: a)?.models, ["m2"])
    }

    func testEndpointChangeDropsOldListAndRefetches() async {
        let a = UUID()
        let c = catalog()
        c.refresh([.init(providerID: a, endpoint: "old") { ["m1"] }])
        await c.waitUntilSettled()
        c.refresh([.init(providerID: a, endpoint: "new") { throw Boom() }])
        await c.waitUntilSettled()
        XCTAssertEqual(c.entry(for: a)?.models, [])
        XCTAssertEqual(c.entry(for: a)?.endpoint, "new")
    }

    func testRemovedProvidersAreDropped() async {
        let a = UUID(), b = UUID()
        let c = catalog()
        c.refresh([.init(providerID: a, endpoint: "e") { ["m"] }, .init(providerID: b, endpoint: "e") { ["n"] }])
        await c.waitUntilSettled()
        // 只刷新其中一个不会清掉另一个。
        c.refresh([.init(providerID: a, endpoint: "e") { ["m"] }])
        XCTAssertNotNil(c.entry(for: b))
        c.retainOnly([a])
        XCTAssertNil(c.entry(for: b))
        XCTAssertNil(catalog().entry(for: b))
    }

    func testSelectedModelMissingFromListStaysVisible() async {
        let a = UUID()
        let c = catalog()
        XCTAssertEqual(c.models(for: a, including: "saved"), ["saved"])
        c.refresh([.init(providerID: a, endpoint: "e") { ["m1", "m2"] }])
        await c.waitUntilSettled()
        XCTAssertEqual(c.models(for: a, including: "m2"), ["m1", "m2"])
        XCTAssertEqual(c.models(for: a, including: "gone"), ["gone", "m1", "m2"])
        XCTAssertEqual(c.models(for: a, including: ""), ["m1", "m2"])
    }
}
