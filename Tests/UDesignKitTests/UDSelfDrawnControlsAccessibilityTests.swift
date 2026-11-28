#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 自绘控件对辅助功能的样子：有名字、读得出状态、AX 按下 / 增减能驱动绑定。
/// 判据都走 AX 树（同 `UDToggleAccessibilityTests`）：VoiceOver 与消费方的界面测试都只看得到这一层。
///
/// 类名刻意排在 `UDDropdownAccessibilityTests` 之后：那条用例在同进程里先有别的测试摆过窗口时
/// 会失败（按下触发器后不弹浮层，与本文件无关，单跑通过），XCTest 按类名字母序执行。
@MainActor
final class UDSelfDrawnControlsAccessibilityTests: XCTestCase {
    // MARK: - AX 树工具

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

    private func numberValue(_ node: NSObject) -> Double? {
        (node.value(forKey: "accessibilityValue") as? NSNumber)?.doubleValue
    }

    private func stringValue(_ node: NSObject) -> String {
        (node.value(forKey: "accessibilityValue") as? String) ?? ""
    }

    private func dump(_ root: NSObject) -> [String] {
        nodes(in: root).map { "\(role($0))|\(label($0))|\(String(describing: $0.value(forKey: "accessibilityValue")))" }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    private func press(_ node: NSObject) -> Bool {
        (node as AnyObject).accessibilityPerformPress?() ?? false
    }

    /// 摆到屏外窗口里，返回窗口；调用方 `defer { close(window) }`。
    private func host(_ view: some View, width: CGFloat = 320, height: CGFloat = 120) -> NSWindow {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: width, height: height))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = NSView()
        window.orderOut(nil)
    }

    /// 等到 AX 树里出现满足条件的节点。
    private func find(in window: NSWindow, _ match: (NSObject) -> Bool) throws -> NSObject {
        let content = try XCTUnwrap(window.contentView)
        var hit: NSObject?
        let found = waitUntil {
            hit = nodes(in: content).first(where: match)
            return hit != nil
        }
        XCTAssertTrue(found, "AX 树里没找到目标：\(dump(content))")
        return try XCTUnwrap(hit)
    }

    private final class Counter { var count = 0 }
    private final class Flag { var isOn = false }
    private final class Number { var value = 0.0 }

    private let button = NSAccessibility.Role.button.rawValue
    private let checkBox = NSAccessibility.Role.checkBox.rawValue

    // MARK: - UDButton

    /// 进行中的按钮被 AX 按下不能再触发动作。回车快捷键、全键盘空格同样不走命中测试、走的是同一个
    /// action 闭包；进程内合成的按键到不了不在前台的宿主窗口，这里只能用 AX 按下来判。
    /// 顺带确认进行中的按钮在 AX 里仍是按钮（迷你转子不再把它变成「忙碌指示器」）。
    func testLoadingButtonIgnoresAccessibilityPress() throws {
        let counter = Counter()
        let window = host(UDButton(title: "提交中…", isLoading: true) { counter.count += 1 })
        defer { close(window) }
        let node = try find(in: window) { role($0) == button && label($0).contains("提交中") }
        _ = press(node)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(counter.count, 0, "isLoading 时 AX 按下仍触发了 action")
    }

    func testIdleButtonRunsActionOnAccessibilityPress() throws {
        let counter = Counter()
        let window = host(UDButton(title: "提交") { counter.count += 1 })
        defer { close(window) }
        let node = try find(in: window) { role($0) == button && label($0).contains("提交") }
        XCTAssertTrue(press(node))
        XCTAssertTrue(waitUntil { counter.count == 1 })
    }

    // MARK: - 图标钮

    func testIconButtonLabelNamesTheButton() throws {
        let window = host(UDIconButton(systemImage: "doc.on.doc", label: Text(verbatim: "复制 SQL")) {})
        defer { close(window) }
        _ = try find(in: window) { role($0) == button && label($0) == "复制 SQL" }
    }

    func testGlyphButtonUsesHelpAsName() throws {
        let window = host(UDGlyphButton(icon: .glyph(.tabSql), help: "SQL 编辑器") {})
        defer { close(window) }
        _ = try find(in: window) { role($0) == button && label($0) == "SQL 编辑器" }
    }

    // MARK: - 勾选类

    func testCheckboxIsACheckBoxThatReportsAndFlipsState() throws {
        let flag = Flag()
        let binding = Binding(get: { flag.isOn }, set: { flag.isOn = $0 })
        let window = host(UDCheckbox("NOT NULL", isOn: binding))
        defer { close(window) }
        let node = try find(in: window) { role($0) == checkBox && label($0) == "NOT NULL" }
        XCTAssertEqual(numberValue(node), 0)
        XCTAssertTrue(press(node))
        XCTAssertTrue(waitUntil { flag.isOn }, "AX 按下没有切换绑定")
    }

    func testBareCheckboxTakesCallSiteLabel() throws {
        let flag = Flag()
        let binding = Binding(get: { flag.isOn }, set: { flag.isOn = $0 })
        let window = host(UDCheckbox(isOn: binding).accessibilityLabel(Text(verbatim: "主键")))
        defer { close(window) }
        _ = try find(in: window) { role($0) == checkBox && label($0) == "主键" }
    }

    /// `.button` 模式以前完全不看 `accessibilityName`，也读不出「部分选中」。
    func testTriCheckboxButtonModeUsesNameAndReportsPartialState() throws {
        let counter = Counter()
        let window = host(UDTriCheckbox(state: .part, accessibilityName: "SELECT users") { counter.count += 1 })
        defer { close(window) }
        let node = try find(in: window) { role($0) == button && label($0) == "SELECT users" }
        XCTAssertFalse(stringValue(node).isEmpty, "三态没有读出状态值")
        XCTAssertTrue(press(node))
        XCTAssertTrue(waitUntil { counter.count == 1 })
    }

    func testTriCheckboxStatesReadDifferently() throws {
        func value(of state: UDTriState) throws -> String {
            let window = host(UDTriCheckbox(state: state, accessibilityName: "格子") {})
            defer { close(window) }
            return stringValue(try find(in: window) { label($0) == "格子" })
        }
        let values = try [UDTriState.on, .part, .off].map(value(of:))
        XCTAssertEqual(Set(values).count, 3, "三态的 AX 值应各不相同：\(values)")
    }

    func testPillToggleIsACheckBoxThatRunsAction() throws {
        let counter = Counter()
        let window = host(UDPillToggle(label: "SELECT", hint: "读取数据", isOn: true) { counter.count += 1 })
        defer { close(window) }
        let node = try find(in: window) { role($0) == checkBox && label($0) == "SELECT" }
        XCTAssertEqual(numberValue(node), 1)
        XCTAssertTrue(press(node))
        XCTAssertTrue(waitUntil { counter.count == 1 }, "AX 按下没有走 action")
    }

    // MARK: - 滑块

    func testSliderIsAnAdjustableSlider() throws {
        let number = Number()
        number.value = 10
        let binding = Binding(get: { number.value }, set: { number.value = $0 })
        let window = host(UDSlider(value: binding, in: 8...24, step: 1, label: Text(verbatim: "字号")))
        defer { close(window) }
        let node = try find(in: window) {
            role($0) == NSAccessibility.Role.slider.rawValue && label($0) == "字号"
        }
        XCTAssertEqual(numberValue(node) ?? -1, 10, accuracy: 0.001)
        _ = (node as AnyObject).accessibilityPerformIncrement?()
        XCTAssertTrue(waitUntil { number.value == 11 }, "AX 增加一档没有写回绑定：\(number.value)")
    }

    // MARK: - 输入框

    func testTextFieldIsNamedByItsLabelNotThePlaceholder() throws {
        let window = host(UDTextField(label: "主机", placeholder: "user@host", text: .constant("")))
        defer { close(window) }
        _ = try find(in: window) {
            role($0) == NSAccessibility.Role.textField.rawValue && label($0) == "主机"
        }
    }

    // MARK: - 进度

    func testLinearBarIsAProgressIndicator() throws {
        let window = host(UDLinearBar(progress: 0.4))
        defer { close(window) }
        let node = try find(in: window) { role($0) == NSAccessibility.Role.progressIndicator.rawValue }
        XCTAssertEqual(numberValue(node) ?? -1, 0.4, accuracy: 0.01)
    }

    func testRingIsAProgressIndicator() throws {
        let window = host(UDRing(progress: 0.72))
        defer { close(window) }
        _ = try find(in: window) { role($0) == NSAccessibility.Role.progressIndicator.rawValue }
    }

    // MARK: - 标签页

    /// 选中是 `onTapGesture`，以前 VoiceOver 看不到；关闭钮要保持独立，不能被并进「选中」里。
    func testTabSelectionIsAButtonSeparateFromClose() throws {
        let selected = Counter()
        let closed = Counter()
        let window = host(UDPreviewTab(name: "README.md", active: true,
                                       onSelect: { selected.count += 1 },
                                       onClose: { closed.count += 1 }))
        defer { close(window) }
        let tab = try find(in: window) { role($0) == button && label($0).contains("README.md") }
        XCTAssertTrue(press(tab))
        XCTAssertTrue(waitUntil { selected.count == 1 })
        XCTAssertEqual(closed.count, 0, "按下 tab 本身把它关了")

        let content = try XCTUnwrap(window.contentView)
        let buttons = nodes(in: content).filter { role($0) == button }
        XCTAssertEqual(buttons.count, 2, "应有「选中」与「关闭」两个 AX 按钮：\(dump(content))")
    }
}
#endif
