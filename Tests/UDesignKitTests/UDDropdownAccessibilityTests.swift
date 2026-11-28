#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDDropdown` 的触发器对辅助功能是一个按钮：标签取触发器里的文字，按下（AX 默认动作）打开浮层，
/// 再按一下收起。
///
/// 触发器是真 `Button`（全键盘控制也够得着）。进程内合成鼠标事件点不动它（宿主不在前台时 mouseDown
/// 会被当成 first-mouse 吞掉）；消费方（uGit 等）的界面测试和 VoiceOver 都走 `accessibilityPerformPress`。
/// 鼠标点触发器不被 `.anchoredPanel` 当成「点外关闭」由 `UDAnchoredPanelEventsTests` 守。
@MainActor
final class UDDropdownAccessibilityTests: XCTestCase {
    private func nodes(in root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 40 else { return [] }
        let children = (root.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        return [root] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    private func label(_ node: NSObject) -> String {
        (node.value(forKey: "accessibilityLabel") as? String) ?? ""
    }

    private func role(_ node: NSObject) -> String {
        (node.value(forKey: "accessibilityRole") as? String) ?? ""
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    func testTriggerIsAnAccessibilityButtonThatOpensThePanel() throws {
        // `swift test` 的进程里没有跑起来的 App：不 finishLaunching 的话 SwiftUI 不建 AX 树
        // （NSHostingView 下只有一个空 AXGroup），这条用例就判不出触发器是不是按钮。
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let view = UDDropdown(anchor: .leading) { open in
            HStack {
                Image(systemName: "folder")
                Text(open ? "已展开" : "选择仓库")
            }
        } content: {
            Text("浮层内容").padding(20)
        }
        .frame(width: 320, height: 200, alignment: .topLeading)

        // 摆在所有屏幕之外：判据是 AX 树与子窗口，不需要被看见。
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer {
            for child in window.childWindows ?? [] { child.orderOut(nil) }
            window.contentView = NSView()
            window.orderOut(nil)
        }
        let content = try XCTUnwrap(window.contentView)

        var trigger: NSObject?
        let found = waitUntil {
            trigger = nodes(in: content).first { role($0) == NSAccessibility.Role.button.rawValue && label($0).contains("选择仓库") }
            return trigger != nil
        }
        XCTAssertTrue(found, "触发器不是 AX 按钮：\(nodes(in: content).map { "\(role($0))|\(label($0))" })")
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)

        let pressed = (try XCTUnwrap(trigger) as AnyObject).accessibilityPerformPress?() ?? false
        XCTAssertTrue(pressed)

        let opened = waitUntil { !(window.childWindows ?? []).isEmpty }
        XCTAssertTrue(opened, "按下触发器后没有弹出浮层子窗口")
        let panel = try XCTUnwrap(window.childWindows?.first?.contentView)
        let shown = waitUntil {
            nodes(in: panel).contains { node in
                [label(node), (node.value(forKey: "accessibilityValue") as? String) ?? ""].contains { $0.contains("浮层内容") }
            }
        }
        XCTAssertTrue(shown, "浮层里没有内容")
        let expanded = waitUntil { nodes(in: content).contains { label($0).contains("已展开") } }
        XCTAssertTrue(expanded, "触发器没收到展开状态")

        // 再按一下触发器：收起（toggle），不是「关了又开」。
        var openTrigger: NSObject?
        XCTAssertTrue(waitUntil {
            openTrigger = nodes(in: content).first { role($0) == NSAccessibility.Role.button.rawValue && label($0).contains("已展开") }
            return openTrigger != nil
        })
        let pressedAgain = (try XCTUnwrap(openTrigger) as AnyObject).accessibilityPerformPress?() ?? false
        XCTAssertTrue(pressedAgain)
        let closed = waitUntil { (window.childWindows ?? []).isEmpty }
        XCTAssertTrue(closed, "再按触发器没有收起浮层")
    }
}
#endif
