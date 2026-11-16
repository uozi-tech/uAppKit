import CloudKit
import XCTest
@testable import AgentProviders

/// 迁移闸门与同步诊断：只认自己那个 store 的事件；「setup 成功之后再一次成功的 import」才算
/// 首次同步完成；失败带 retry-after 时给出重建容器的信号。
@MainActor
final class ProviderCloudKitMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: CloudKitEventSnapshot.Kind, store: String = "S", at offset: TimeInterval = 1,
                       succeeded: Bool = true, failure: CloudKitSyncFailure? = nil) -> CloudKitEventSnapshot {
        CloudKitEventSnapshot(kind: kind, storeIdentifier: store, startDate: start.addingTimeInterval(offset),
                              endDate: start.addingTimeInterval(offset + 1), succeeded: succeeded, failure: failure)
    }

    func testReadyOnlyAfterSetupThenImport() {
        let monitor = ProviderCloudKitMonitor(notificationCenter: NotificationCenter(), now: { self.start })
        monitor.bind(storeIdentifier: "S")
        monitor.start()
        XCTAssertEqual(monitor.status, .settingUp)

        monitor.handle(event(.import))
        XCTAssertFalse(monitor.isReadyForMigration, "setup 之前的 import 不算")
        monitor.handle(event(.setup))
        XCTAssertEqual(monitor.status, .waitingForFirstImport)
        monitor.handle(event(.export))
        XCTAssertFalse(monitor.isReadyForMigration)
        monitor.handle(event(.import, at: 5))
        XCTAssertTrue(monitor.isReadyForMigration)
        XCTAssertEqual(monitor.status, .ready)
        XCTAssertEqual(monitor.lastImportAt, start.addingTimeInterval(6))
    }

    func testIgnoresOtherStoresAndUnfinishedEvents() {
        let monitor = ProviderCloudKitMonitor(notificationCenter: NotificationCenter(), now: { self.start })
        monitor.bind(storeIdentifier: "S")
        monitor.start()
        monitor.handle(event(.setup, store: "uTerm"))
        monitor.handle(CloudKitEventSnapshot(kind: .setup, storeIdentifier: "S", startDate: start, endDate: nil,
                                             succeeded: false, failure: nil))
        XCTAssertEqual(monitor.status, .settingUp)
    }

    func testClaimsFirstSetupAfterStartWhenMetadataUnavailable() {
        let monitor = ProviderCloudKitMonitor(notificationCenter: NotificationCenter(), now: { self.start })
        monitor.start()
        monitor.handle(event(.setup, store: "Old", at: -30))   // 监听开始前的 setup：不认领
        monitor.handle(event(.setup, store: "Mine"))
        monitor.handle(event(.import, store: "Other", at: 3))
        XCTAssertFalse(monitor.isReadyForMigration)
        monitor.handle(event(.import, store: "Mine", at: 3))
        XCTAssertTrue(monitor.isReadyForMigration)
    }

    func testFailureThenRecreateSignal() {
        var now = start
        let monitor = ProviderCloudKitMonitor(notificationCenter: NotificationCenter(), now: { now })
        monitor.bind(storeIdentifier: "S")
        monitor.start()
        let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 30)])
        let failure = CloudKitSyncFailure.make(error: error, eventKind: .setup, endedAt: start.addingTimeInterval(2))
        XCTAssertEqual(failure.reason, .busy)
        XCTAssertTrue(failure.shouldRecreateContainer)
        XCTAssertEqual(failure.message, "iCloud 同步失败：CloudKit 当前繁忙（约 30 秒后自动重试）")

        monitor.handle(event(.setup, succeeded: false, failure: failure))
        XCTAssertEqual(monitor.status, .failed(failure))
        now = start.addingTimeInterval(12)
        XCTAssertEqual(monitor.retryDelayFromNow, 20, accuracy: 0.001)
        XCTAssertTrue(monitor.prepareForRetryIfNeeded())
        XCTAssertEqual(monitor.status, .settingUp)
        XCTAssertFalse(monitor.prepareForRetryIfNeeded(), "已经处理过")
    }

    func testNotAuthenticatedFailureDoesNotAskForRecreate() {
        let failure = CloudKitSyncFailure.make(error: CKError(.notAuthenticated), eventKind: .import, endedAt: start)
        XCTAssertEqual(failure.reason, .notAuthenticated)
        XCTAssertFalse(failure.shouldRecreateContainer)
        XCTAssertNil(failure.retryNotBefore)
    }

    func testWaitUntilReadyResumesOnImportAndTimesOut() async {
        let monitor = ProviderCloudKitMonitor(notificationCenter: NotificationCenter(), now: { self.start })
        monitor.bind(storeIdentifier: "S")
        monitor.start()
        let timedOut = await monitor.waitUntilReadyForMigration(timeout: .milliseconds(20))
        XCTAssertFalse(timedOut)

        Task { @MainActor in
            monitor.handle(self.event(.setup))
            monitor.handle(self.event(.import, at: 3))
        }
        let ready = await monitor.waitUntilReadyForMigration(timeout: .seconds(5))
        XCTAssertTrue(ready)
    }
}
