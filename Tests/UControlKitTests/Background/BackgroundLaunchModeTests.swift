#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// 启动参数与 CLI 按需启动的把关（两个 app 原先各有一份同样的用例）。
@MainActor
final class BackgroundLaunchModeTests: XCTestCase {
    func testLoginHelperUsesExplicitBackgroundEntry() {
        XCTAssertEqual(
            BackgroundLaunchMode.presentation(arguments: ["uTable", "--background", "--launch-source", "login-item"]),
            .background
        )
    }

    func testCLIUsesExplicitBackgroundEntry() {
        XCTAssertTrue(BackgroundLaunchMode.shouldStartHidden(arguments: ["uTable", "--background"]))
    }

    func testManualColdLaunchIsForegroundEvenWhenPreferencesExist() {
        XCTAssertEqual(BackgroundLaunchMode.presentation(arguments: ["uTable"]), .foreground)
    }

    func testReopeningExistingBackgroundProcessPromotesGUI() {
        XCTAssertEqual(BackgroundLaunchMode.reopenPresentation, .foreground)
    }

    /// 启动参数是已发版的契约（launcher 模板与客户端都写死了它们）。
    func testLaunchArgumentsAreFrozen() {
        XCTAssertEqual(BackgroundLaunchMode.backgroundArgument, "--background")
        XCTAssertEqual(BackgroundLaunchMode.launchSourceArgument, "--launch-source")
        XCTAssertEqual(BackgroundLaunchMode.cliLaunchSource, "cli")
        XCTAssertEqual(BackgroundLaunchMode.loginItemLaunchSource, "login-item")
        XCTAssertEqual(BackgroundLaunchMode.launchSource(arguments: ["x", "--launch-source", "cli"]), "cli")
        XCTAssertNil(BackgroundLaunchMode.launchSource(arguments: ["x", "--launch-source"]))
    }

    private func defaults(onDemand: Bool?, controlEnabled: Bool?) -> UserDefaults {
        let name = "BackgroundLaunchModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if let onDemand { defaults.set(onDemand, forKey: "background.allowOnDemandLaunch") }
        if let controlEnabled { defaults.set(controlEnabled, forKey: "control.enabled") }
        return defaults
    }

    private let cliArguments = ["uTable", "--background", "--launch-source", "cli"]
    private let copy = BackgroundLaunchMode.RefusalCopy(onDemandDisabled: "按需启动关着", controlDisabled: "接口关着")

    private func refusal(_ arguments: [String], _ defaults: UserDefaults) -> String? {
        BackgroundLaunchMode.cliLaunchRefusal(arguments: arguments, defaults: defaults, copy: copy)
    }

    /// 客户端读不到设置时照样请求启动，app 自己按设置把关：两项都开才留下。
    func testCLILaunchNeedsBothOnDemandAndControlInterface() {
        XCTAssertNil(refusal(cliArguments, defaults(onDemand: true, controlEnabled: true)))
        XCTAssertEqual(refusal(cliArguments, defaults(onDemand: false, controlEnabled: true)), "按需启动关着")
        XCTAssertEqual(refusal(cliArguments, defaults(onDemand: true, controlEnabled: false)), "接口关着")
        // 没设过 = 默认关。
        XCTAssertNotNil(refusal(cliArguments, defaults(onDemand: nil, controlEnabled: nil)))
    }

    /// 手动打开、登录项唤起不受这两个开关影响。
    func testNonCLILaunchesAreNeverRefused() {
        let off = defaults(onDemand: false, controlEnabled: false)
        XCTAssertNil(refusal(["uTable"], off))
        XCTAssertNil(refusal(["uTable", "--background", "--launch-source", "login-item"], off))
        XCTAssertNil(refusal(["uTable", "--launch-source"], off))
    }

    /// 主开关的 key 可换（core 不认死 `control.enabled`）。
    func testControlEnabledKeyIsInjectable() {
        let defaults = defaults(onDemand: true, controlEnabled: nil)
        defaults.set(true, forKey: "other.enabled")
        XCTAssertNil(BackgroundLaunchMode.cliLaunchRefusal(
            arguments: cliArguments, defaults: defaults, controlEnabledKey: "other.enabled", copy: copy))
    }
}

#endif
