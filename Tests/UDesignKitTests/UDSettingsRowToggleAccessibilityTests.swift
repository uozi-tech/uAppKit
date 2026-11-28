#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 设置行把标题经环境交给右侧控件：行内没有自己名字的控件读出来的名字就是行标题，
/// 同一个名字只读一遍（左侧标题文字退出 AX）。显式 `label:` 与调用处外挂的
/// `.accessibilityLabel` 仍然优先，那时行标题留着。
///
/// 以前行标题挂在包住控件的容器上（`.contain`），名字落在组上，开关本身是无名的 ——
/// uTable 的 AX 审计里这类开关都报无名按钮。
@MainActor
final class UDSettingsRowToggleAccessibilityTests: XCTestCase {
    private let title = "允许外部 agent 连接"

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

    private func text(_ node: NSObject) -> String {
        [label(node), (node.value(forKey: "accessibilityValue") as? String) ?? ""].joined(separator: "|")
    }

    /// 摆进屏外窗口，等到出现 `role` 的节点，返回整棵 AX 树。
    private func tree(_ view: some View, waitingFor role: NSAccessibility.Role) throws -> [NSObject] {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 460, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 460, height: 80))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        var all: [NSObject] = []
        for _ in 0..<200 {
            all = nodes(in: content)
            if all.contains(where: { self.role($0) == role.rawValue }) { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        // 行标题是否退出 AX 由偏好回传驱动，多给一拍让它落地。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        return nodes(in: content)
    }

    private func checkBoxes(_ all: [NSObject]) -> [String] {
        all.filter { role($0) == NSAccessibility.Role.checkBox.rawValue }.map(label)
    }

    private func staticTexts(_ all: [NSObject], containing needle: String) -> [NSObject] {
        all.filter { role($0) == NSAccessibility.Role.staticText.rawValue && text($0).contains(needle) }
    }

    func testUnlabeledToggleInSettingsRowIsNamedByRowTitleOnce() throws {
        let all = try tree(UDSettingsRow(label: title, hint: "说明") { UDToggle(.constant(true)) },
                           waitingFor: .checkBox)
        XCTAssertEqual(checkBoxes(all), [title], "行内没传 label 的开关要读出行标题")
        XCTAssertTrue(staticTexts(all, containing: title).isEmpty,
                      "开关已经叫这个名字，左侧标题文字不该再读一遍：\(all.map(text))")
        XCTAssertFalse(staticTexts(all, containing: "说明").isEmpty, "说明文字照常可读")
    }

    func testExplicitLabelWinsAndRowTitleStaysReadable() throws {
        let all = try tree(UDSettingsRow(label: title) {
            UDToggle(.constant(true), label: Text(verbatim: "写操作开关"))
        }, waitingFor: .checkBox)
        XCTAssertEqual(checkBoxes(all), ["写操作开关"])
        XCTAssertFalse(staticTexts(all, containing: title).isEmpty, "显式名字和行标题不同，行标题要留着")
    }

    func testCallSiteAccessibilityLabelWins() throws {
        let all = try tree(UDSettingsRow(label: title) {
            UDToggle(.constant(false)).accessibilityLabel(Text(verbatim: "调用处的名字"))
        }, waitingFor: .checkBox)
        XCTAssertEqual(checkBoxes(all), ["调用处的名字"])
    }

    func testSegmentedInSettingsRowBecomesGroupNamedByRowTitle() throws {
        let all = try tree(UDSettingsRow(label: "字体") {
            UDSegmented(selection: .constant("Monaco"), options: [("Monaco", "Monaco"), ("Menlo", "Menlo")])
        }, waitingFor: .button)
        XCTAssertTrue(all.contains { role($0) == NSAccessibility.Role.group.rawValue && label($0) == "字体" },
                      "分段控件在设置行里应是以行标题命名的组：\(all.map { "\(role($0))|\(text($0))" })")
        XCTAssertTrue(all.contains { role($0) == NSAccessibility.Role.button.rawValue && text($0).contains("Monaco") },
                      "各段仍读自己的文字")
        XCTAssertTrue(staticTexts(all, containing: "字体").isEmpty, "组已叫「字体」，标题文字不再读")
    }

    func testUntitledCheckboxInSettingsRowIsNamedByRowTitle() throws {
        let all = try tree(UDSettingsRow(label: "自增") { UDCheckbox(isOn: .constant(true)) },
                           waitingFor: .checkBox)
        XCTAssertEqual(checkBoxes(all), ["自增"])
    }
}
#endif
