#if canImport(AppKit)
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import UDesignKit

/// 工具轨迹「出错默认展开」：调用先以 running 出现、后来才失败时也要展开。
@MainActor
final class UDAgentToolTraceTests: XCTestCase {
    @Observable
    final class Model {
        var status: UDAgentToolTrace.Status = .running
    }

    private struct Host: View {
        @Bindable var model: Model
        var body: some View {
            UDAgentToolTrace(name: "query", arguments: "{\"sql\": \"select 1\"}",
                             result: model.status == .failed ? "permission denied" : nil,
                             status: model.status)
                .frame(width: 320)
        }
    }

    func testAutoExpandRule() {
        XCTAssertTrue(UDAgentToolTrace.shouldAutoExpand(from: .running, to: .failed))
        XCTAssertTrue(UDAgentToolTrace.shouldAutoExpand(from: .pending, to: .failed))
        XCTAssertFalse(UDAgentToolTrace.shouldAutoExpand(from: .running, to: .done))
        XCTAssertFalse(UDAgentToolTrace.shouldAutoExpand(from: .failed, to: .failed))
    }

    func testTraceExpandsWhenRunningCallFails() {
        _ = NSApplication.shared
        let model = Model()
        let hosting = NSHostingView(rootView: Host(model: model))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.contentView = NSView(); window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let collapsed = hosting.fittingSize.height

        model.status = .failed
        var expanded = collapsed
        for _ in 0..<80 where expanded < collapsed + 20 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
            hosting.layoutSubtreeIfNeeded()
            expanded = hosting.fittingSize.height
        }
        XCTAssertGreaterThan(expanded, collapsed + 20, "running → failed 后没有展开（\(collapsed) → \(expanded)）")
    }
}
#endif
