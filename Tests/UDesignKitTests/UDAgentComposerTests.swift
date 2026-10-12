#if os(macOS)
import XCTest
@testable import UDesignKit

/// `UDAgentComposer`：版式常量 + 两条只能盯源文本的行为守卫（同 `UDComposerSourceGuardTests`）。
final class UDAgentComposerTests: XCTestCase {
    /// 工具栏控件与主操作钮都要是点得中的尺寸，且主操作钮不比旁边的控件小。
    func testControlsUseClickableHitTargets() {
        XCTAssertGreaterThanOrEqual(UDAgentComposerLayout.controlHeight, 24)
        XCTAssertGreaterThanOrEqual(UDAgentComposerLayout.primarySize, UDAgentComposerLayout.controlHeight)
    }

    /// 回车要触发发送动作，而不是把焦点留在发送按钮上。
    func testReturnKeyRoutesToSendAction() throws {
        XCTAssertTrue(try source().contains(".onSubmit(onSend)"),
                      "UDAgentComposer 必须把 Return 路由到发送动作。")
    }

    /// 停止必须能从键盘触发，且只在 Agent 在跑时生效。
    func testEscapeRoutesToStopOnlyWhileRunning() throws {
        XCTAssertTrue(try source().contains(".onExitCommand { if canStop { onStop() } }"),
                      "UDAgentComposer 必须让 esc 在 canStop 时触发停止。")
    }

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UDesignKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <包根>
            .appendingPathComponent("Sources/UDesignKit/Comms/UDAgentComposer.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
#endif
