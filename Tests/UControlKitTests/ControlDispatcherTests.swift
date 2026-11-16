#if os(macOS)

import Foundation
import XCTest
@testable import UControlKit

/// 分发层的门禁矩阵：就绪 × 主开关 × 改动开关 × 动作门禁，每一格的结果都要和规格一致。
/// 顺序（就绪 → ping 短路 → 主开关 → 改动开关 → handler）是两个 app 已发版的行为。
@MainActor
final class ControlDispatcherTests: XCTestCase {
    private struct NotAControlFailure: LocalizedError {
        var errorDescription: String? { "磁盘满了" }
    }

    private final class Switches {
        var enabled = false
        var mutations = false
    }

    private static let policy = TestDispatcher.Policy(
        notReady: ControlFailure(code: ControlFailureCode.appNotReady, message: "还没起来"),
        controlDisabled: ControlFailure(code: ControlFailureCode.controlDisabled, message: "主开关关着"),
        // uTable 的码。uTerm 传 `mutations_disabled`，核心不归一化。
        mutationDenied: ControlFailure(code: "writes_disabled", message: "写开关关着")
    )

    private func makeDispatcher(_ switches: Switches) -> TestDispatcher {
        TestDispatcher(
            policy: Self.policy,
            isEnabled: { switches.enabled },
            allowsMutation: { switches.mutations }
        )
    }

    /// 门禁矩阵的真值源。
    func testGatingMatrixMatchesTheSpec() async {
        for ready in [false, true] {
            for enabled in [false, true] {
                for mutations in [false, true] {
                    for action in TestAction.allCases {
                        let switches = Switches()
                        switches.enabled = enabled
                        switches.mutations = mutations
                        let dispatcher = makeDispatcher(switches)
                        if ready {
                            dispatcher.attach { request in .success(id: request.id, message: "handled") }
                        }
                        XCTAssertEqual(dispatcher.isReady, ready)

                        let response = await dispatcher.dispatch(TestRequest(id: "x", action: action))
                        let expected: String
                        if !ready {
                            expected = ControlFailureCode.appNotReady
                        } else if action.gate == .always {
                            expected = "ok"
                        } else if !enabled {
                            expected = ControlFailureCode.controlDisabled
                        } else if action.gate == .mutation, !mutations {
                            expected = "writes_disabled"
                        } else {
                            expected = "ok"
                        }
                        XCTAssertEqual(
                            response.code, expected,
                            "ready=\(ready) enabled=\(enabled) mutations=\(mutations) action=\(action.rawValue)")
                        XCTAssertEqual(response.id, "x", "失败响应也要带回请求 id")
                    }
                }
            }
        }
    }

    /// 只有 `.always`（ping）能绕过主开关 —— 否则客户端连「开关关着」都问不出来。
    func testOnlyAlwaysGateSkipsTheMasterSwitch() {
        XCTAssertEqual(TestAction.allCases.filter { $0.gate == .always }, [.ping])
    }

    /// 门禁失败时告诉 app 失败在哪一步，app 据此往响应里加载荷（例如主开关拒绝时附上 ping 信息）。
    func testFailureResponderSeesTheStage() async {
        let switches = Switches()
        var stages: [TestDispatcher.Stage] = []
        let dispatcher = TestDispatcher(
            policy: Self.policy,
            isEnabled: { switches.enabled },
            allowsMutation: { switches.mutations },
            failureResponse: { request, failure, stage in
                stages.append(stage)
                return .controlFailure(id: request.id, code: failure.code, message: "[\(stage)] \(failure.message)")
            }
        )
        _ = await dispatcher.dispatch(TestRequest(action: .hosts))
        dispatcher.attach { _ in throw ControlFailure(code: "table_required", message: "要 --table") }
        _ = await dispatcher.dispatch(TestRequest(action: .hosts))
        switches.enabled = true
        _ = await dispatcher.dispatch(TestRequest(action: .run))
        let handled = await dispatcher.dispatch(TestRequest(action: .hosts))
        XCTAssertEqual(stages, [.notReady, .enabledGate, .mutationGate, .handler])
        XCTAssertEqual(handled.code, "table_required", "handler 抛的 ControlFailure 原样回")
    }

    /// handler 抛 `ControlFailure` 以外的错误：回 `operation_failed`，文案可由 app 定制。
    func testUnexpectedErrorsBecomeOperationFailed() async {
        let switches = Switches()
        switches.enabled = true
        let dispatcher = TestDispatcher(
            policy: Self.policy,
            isEnabled: { switches.enabled },
            allowsMutation: { switches.mutations },
            describeError: { "presentable: \($0.localizedDescription)" }
        )
        dispatcher.attach { _ in throw NotAControlFailure() }
        let response = await dispatcher.dispatch(TestRequest(id: "e", action: .hosts))
        XCTAssertEqual(response.code, ControlFailureCode.operationFailed)
        XCTAssertEqual(response.message, "presentable: 磁盘满了")
    }

    /// 要看参数才能判写的 handler（Redis 写命令）抛的是与动作级门禁同一个失败。
    func testRequireMutationAllowedThrowsThePolicyFailure() async {
        let switches = Switches()
        switches.enabled = true
        let dispatcher = makeDispatcher(switches)
        dispatcher.attach { [unowned dispatcher] request in
            try dispatcher.requireMutationAllowed()
            return .success(id: request.id, message: "wrote")
        }
        let denied = await dispatcher.dispatch(TestRequest(action: .hosts))
        XCTAssertEqual(denied.code, "writes_disabled")
        XCTAssertEqual(denied.message, "写开关关着")
        switches.mutations = true
        let allowed = await dispatcher.dispatch(TestRequest(action: .hosts))
        XCTAssertEqual(allowed.message, "wrote")
    }

    func testDetachReturnsToNotReady() async {
        let dispatcher = makeDispatcher(Switches())
        dispatcher.attach { request in .success(id: request.id, message: "pong") }
        let attached = await dispatcher.dispatch(TestRequest(action: .ping))
        XCTAssertEqual(attached.code, "ok")
        dispatcher.detach()
        let detached = await dispatcher.dispatch(TestRequest(action: .ping))
        XCTAssertEqual(detached.code, ControlFailureCode.appNotReady)
    }

    /// 开关取自 `ControlGateSettings` 的便捷构造：每条请求现读，开关一变立刻生效。
    func testSettingsBackedDispatcherReadsLiveValues() async {
        let defaults = UserDefaults(suiteName: "UControlKitTests.\(UUID().uuidString)")!
        let settings = ControlGateSettings(
            keys: .init(enabled: "control.enabled", allowMutations: "control.allowWrites"), defaults: defaults)
        let dispatcher = TestDispatcher(policy: Self.policy, settings: settings)
        dispatcher.attach { request in .success(id: request.id, message: "ok") }
        var codes: [String] = []
        codes.append(await dispatcher.dispatch(TestRequest(action: .run)).code)
        settings.isEnabled = true
        codes.append(await dispatcher.dispatch(TestRequest(action: .run)).code)
        settings.allowMutations = true
        codes.append(await dispatcher.dispatch(TestRequest(action: .run)).code)
        XCTAssertEqual(codes, [ControlFailureCode.controlDisabled, "writes_disabled", "ok"])
    }
}

#endif
