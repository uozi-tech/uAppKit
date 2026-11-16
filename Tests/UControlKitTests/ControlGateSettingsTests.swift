#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// 开关的持久化：key 由调用方传入、值是 Bool，与两个 app 发版时写下的偏好逐字节兼容。
@MainActor
final class ControlGateSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "UControlKitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultsToBothSwitchesOff() {
        let settings = ControlGateSettings(
            keys: .init(enabled: "control.enabled", allowMutations: "control.allowWrites"), defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.allowMutations)
        XCTAssertNil(settings.startupError)
    }

    /// 已发版的偏好（uTable 的 `control.allowWrites`、uTerm 的 `control.allowMutations`）原样读得回来。
    func testReadsShippedKeysVerbatim() {
        defaults.set(true, forKey: "control.enabled")
        defaults.set(true, forKey: "control.allowWrites")
        defaults.set(false, forKey: "control.allowMutations")

        let table = ControlGateSettings(
            keys: .init(enabled: "control.enabled", allowMutations: "control.allowWrites"), defaults: defaults)
        XCTAssertTrue(table.isEnabled)
        XCTAssertTrue(table.allowMutations)

        let term = ControlGateSettings(
            keys: .init(enabled: "control.enabled", allowMutations: "control.allowMutations"), defaults: defaults)
        XCTAssertTrue(term.isEnabled)
        XCTAssertFalse(term.allowMutations)
    }

    /// 写回去的是 Bool，key 不变 —— 老版本 app、客户端脚本（读 plist 判主开关）都认。
    func testWritesBoolUnderTheGivenKeys() {
        let settings = ControlGateSettings(
            keys: .init(enabled: "control.enabled", allowMutations: "control.allowWrites"), defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        XCTAssertEqual(defaults.object(forKey: "control.enabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "control.allowWrites") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "control.allowMutations"))
    }

    /// `observe` 立刻回调一次（让服务端与持久化状态对齐），之后每次开关变化回调。
    func testObserveFiresImmediatelyAndOnChange() {
        let settings = ControlGateSettings(
            keys: .init(enabled: "e", allowMutations: "m"), defaults: defaults)
        var seen: [(Bool, Bool)] = []
        settings.observe { seen.append(($0.isEnabled, $0.allowMutations)) }
        settings.isEnabled = true
        settings.isEnabled = true   // 没变：不回调
        settings.allowMutations = true
        XCTAssertEqual(seen.map(\.0), [false, true, true])
        XCTAssertEqual(seen.map(\.1), [false, false, true])
    }
}

#endif
