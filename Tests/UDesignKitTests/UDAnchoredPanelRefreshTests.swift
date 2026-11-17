#if canImport(AppKit)
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import UDesignKit

/// 浮层展开后，宿主依赖的状态变了（如模型列表加载完），浮层内容要跟着更新，而浮层里的 @State 保留。
@MainActor
final class UDAnchoredPanelRefreshTests: XCTestCase {
    @Observable
    final class Model {
        var label = "加载中"
        var isPresented = false
    }

    /// 浮层内容每次求值记下看到的 label 与 @State token（不依赖 AX：测试进程里子面板的 AX 树不一定建起来）。
    final class Recorder {
        var labels: [String] = []
        var tokens: Set<String> = []
    }

    /// 浮层里的一行：@State 在第一次创建时取一个随机 token，刷新内容后应保持不变。
    private struct Probe: View {
        let label: String
        let recorder: Recorder
        @State private var token = UUID().uuidString

        var body: some View {
            let _ = record()
            Text(label)
        }

        private func record() {
            recorder.labels.append(label)
            recorder.tokens.insert(token)
        }
    }

    private struct Host: View {
        @Bindable var model: Model
        let recorder: Recorder
        var body: some View {
            Color.clear
                .frame(width: 200, height: 40)
                .anchoredPanel(isPresented: $model.isPresented) { _ in
                    Probe(label: model.label, recorder: recorder).frame(width: 160, height: 30)
                }
        }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    func testOpenPanelFollowsHostStateAndKeepsPanelState() throws {
        _ = NSApplication.shared
        let model = Model()
        let recorder = Recorder()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model, recorder: recorder))
        window.orderFront(nil)
        defer {
            window.childWindows?.forEach { $0.close() }
            window.close()
        }

        // 同真实使用：挂上窗口之后才展开（展开那一刻锚点要在窗口里）。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        model.isPresented = true
        XCTAssertTrue(waitUntil { window.childWindows?.count == 1 && recorder.labels.last == "加载中" }, "浮层没展开")

        model.label = "已加载 3 个模型"
        XCTAssertTrue(waitUntil { recorder.labels.last == "已加载 3 个模型" }, "浮层内容定格在展开那一刻")
        XCTAssertEqual(recorder.tokens.count, 1, "刷新内容不应重建浮层里的 @State")
        XCTAssertEqual(window.childWindows?.count, 1, "刷新不应再开一个浮层")
    }
}
#endif
