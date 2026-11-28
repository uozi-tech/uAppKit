#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 设置行里的 `UDToggle`：`UDSettingsRow` 把行标题挂在包住右侧控件的容器上（`.contain`），
/// 开关本身拿不到名字 —— uTable 的 AX 审计里这类开关是无名的。调用处要用 `label:` 把行标题传给开关。
@MainActor
final class UDSettingsRowToggleAccessibilityTests: XCTestCase {
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

    private func checkBoxLabels(in view: some View) throws -> [String] {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 420, height: 80))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        var labels: [String] = []
        for _ in 0..<200 {
            labels = nodes(in: content).filter { role($0) == NSAccessibility.Role.checkBox.rawValue }.map(label)
            if !labels.isEmpty { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return labels
    }

    func testToggleInSettingsRowIsNamedWhenLabelIsPassed() throws {
        let labels = try checkBoxLabels(in: UDSettingsRow(label: "允许外部 agent 连接", hint: "说明") {
            UDToggle(.constant(true), label: Text(verbatim: "允许外部 agent 连接"))
        })
        XCTAssertEqual(labels, ["允许外部 agent 连接"], "设置行里的开关要读得出行标题")
    }
}
#endif
