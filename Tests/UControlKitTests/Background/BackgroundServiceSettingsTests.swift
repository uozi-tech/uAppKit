#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// 登录项开关以系统状态为准，defaults 只是镜像（两个 app 原先各有一份同样的用例）。
@MainActor
final class BackgroundServiceSettingsTests: XCTestCase {
    private final class MockService: BackgroundServiceSettings.LoginItemServicing {
        var status: BackgroundServiceSettings.LoginItemStatus
        var registerError: Error?
        var unregisterError: Error?
        var statusAfterRegister: BackgroundServiceSettings.LoginItemStatus?

        init(status: BackgroundServiceSettings.LoginItemStatus) { self.status = status }

        func register() throws {
            if let registerError { throw registerError }
            if let statusAfterRegister { status = statusAfterRegister }
        }

        func unregister() throws {
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private struct TestError: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    private func defaults() -> UserDefaults {
        let suite = "BackgroundServiceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func settings(_ service: MockService, defaults: UserDefaults? = nil) -> BackgroundServiceSettings {
        BackgroundServiceSettings(
            loginItemIdentifier: "com.uozi.uTable.BackgroundLauncher",
            defaults: defaults ?? self.defaults(),
            loginItemService: service)
    }

    func testKeysAreFrozen() {
        XCTAssertEqual(BackgroundServiceSettings.Keys.launchAtLogin, "background.launchAtLogin")
        XCTAssertEqual(BackgroundServiceSettings.Keys.allowOnDemandLaunch, "background.allowOnDemandLaunch")
    }

    func testRegisterFailureRollsToggleAndPersistedValueBack() {
        let service = MockService(status: .notRegistered)
        service.registerError = TestError()
        let defaults = defaults()
        let settings = settings(service, defaults: defaults)

        settings.setLaunchAtLogin(true)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(defaults.bool(forKey: "background.launchAtLogin"))
        XCTAssertEqual(settings.loginItemError, "无法启用登录后台启动：Operation not permitted")
    }

    func testRequiresApprovalIsDistinctFromFailure() {
        let service = MockService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let settings = settings(service)

        settings.setLaunchAtLogin(true)

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.needsLoginItemApproval)
        XCTAssertNil(settings.loginItemError)
    }

    func testRefreshTracksExternalSystemStatus() {
        let service = MockService(status: .enabled)
        let settings = settings(service)
        XCTAssertTrue(settings.launchAtLogin)

        service.status = .notRegistered
        settings.refreshLoginItemStatus()

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .notRegistered)
    }

    func testUnregisterFailureKeepsSystemEnabledState() {
        let service = MockService(status: .enabled)
        service.unregisterError = TestError()
        let settings = settings(service)

        settings.setLaunchAtLogin(false)

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginItemStatus, .enabled)
        XCTAssertNotNil(settings.loginItemError)
    }

    /// 按需启动开关原样读写已发版的 key。
    func testOnDemandSwitchPersistsUnderTheShippedKey() {
        let defaults = defaults()
        defaults.set(true, forKey: "background.allowOnDemandLaunch")
        let settings = settings(MockService(status: .notRegistered), defaults: defaults)
        XCTAssertTrue(settings.allowOnDemandLaunch)
        settings.allowOnDemandLaunch = false
        XCTAssertEqual(defaults.object(forKey: "background.allowOnDemandLaunch") as? Bool, false)
    }
}

#endif
