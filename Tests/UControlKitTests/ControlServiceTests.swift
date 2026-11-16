#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// 开关 → 服务端起停的接线。服务端换成桩，只看调用序列。
@MainActor
final class ControlServiceTests: XCTestCase {
    private final class StubServer: ControlServing, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var startError: String?

        func start() -> String? {
            lock.withLock { log.append("start") }
            return startError
        }

        func stop() {
            lock.withLock { log.append("stop") }
        }

        var calls: [String] { lock.withLock { log } }
    }

    private func makeSettings() -> ControlGateSettings {
        let defaults = UserDefaults(suiteName: "UControlKitTests.\(UUID().uuidString)")!
        return ControlGateSettings(keys: .init(enabled: "control.enabled", allowMutations: "m"), defaults: defaults)
    }

    func testFollowsTheMasterSwitch() {
        let settings = makeSettings()
        let server = StubServer()
        var disabledCalls = 0
        let service = ControlService(settings: settings, server: server, skipsInTestHost: false) {
            disabledCalls += 1
        }
        service.activate()
        // 开关默认关：立刻按关处理一次。
        XCTAssertEqual(server.calls, ["stop"])
        XCTAssertEqual(disabledCalls, 1)

        server.startError = "socket 路径过长"
        settings.isEnabled = true
        XCTAssertEqual(server.calls, ["stop", "start"])
        XCTAssertEqual(settings.startupError, "socket 路径过长", "不会自愈的启动失败要落到设置页")

        settings.isEnabled = false
        XCTAssertEqual(server.calls, ["stop", "start", "stop"])
        XCTAssertNil(settings.startupError, "接口关掉就清掉启动失败")
        XCTAssertEqual(disabledCalls, 2)
    }

    /// 测试宿主里不起服务端：测试宿主就是 app 本身，起了会抢开发者正在用的实例的 socket。
    func testSkipsTheServerInTestHost() {
        XCTAssertTrue(ControlService.isRunningInTestHost, "swift test / xcodebuild test 都应被识别为测试宿主")
        let settings = makeSettings()
        settings.isEnabled = true
        let server = StubServer()
        let service = ControlService(settings: settings, server: server)
        service.activate()
        settings.isEnabled = false
        settings.isEnabled = true
        XCTAssertEqual(server.calls, [])
    }
}

#endif
