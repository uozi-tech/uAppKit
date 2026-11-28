#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import UPaneGroups

/// 编辑区对辅助功能长什么样。读的是 `NSHostingView` 交出来的 AX 树（窗口要真的摆到屏上，
/// SwiftUI 才会把树建出来；做法同 `UDToggleAccessibilityTests`）。
///
/// - 标签 chip：一个带名字的按钮，前台标签带「已选中」，按下 = 切过去，× 是一个具名动作。
///   激活本来只走 NSEvent 旁观，辅助功能的按下不产生鼠标事件，没有这一层 VoiceOver 切不了标签。
/// - 标签条右侧的图标钮（分屏 / 关闭空分组）：有自己的名字，不靠悬停提示。
/// - 分隔条：一根读得出占比、按「增加 / 减少」挪动的滑杆。
@MainActor
final class UPaneGroupsAccessibilityTests: XCTestCase {

    // MARK: AX 树

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

    private func isSelected(_ node: NSObject) -> Bool {
        (node.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue ?? false
    }

    private func customActions(_ node: NSObject) -> [NSAccessibilityCustomAction] {
        (node.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
    }

    private func dump(_ root: NSObject) -> [String] {
        nodes(in: root).map { "\(role($0))|\(label($0))" }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    private func host(_ view: some View, size: NSSize = NSSize(width: 800, height: 600)) -> NSWindow {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        return window
    }

    private final class CloseLog: @unchecked Sendable { var requested: [UUID] = [] }

    private func area(_ model: UPaneGroupsModel<TestPayload>, closes: CloseLog = CloseLog()) -> some View {
        UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { tab in UPaneTabDescriptor(title: tab.customTitle ?? "tab", icon: .system("doc")) },
            content: { _, _ in Color.clear },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { closes.requested.append($0.id) })
    }

    // MARK: 标签 chip

    func testTabsAreNamedButtonsAndTheFrontOneIsSelected() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "beta") }
        let window = host(area(model))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        func chip(_ name: String) -> NSObject? {
            nodes(in: content).first { role($0) == NSAccessibility.Role.button.rawValue && label($0) == name }
        }
        XCTAssertTrue(waitUntil { chip("alpha") != nil && chip("beta") != nil },
                      "标签不是带名字的按钮：\(dump(content))")
        XCTAssertTrue(isSelected(try XCTUnwrap(chip("beta"))), "前台标签要带「已选中」")
        XCTAssertFalse(isSelected(try XCTUnwrap(chip("alpha"))))
        XCTAssertFalse(nodes(in: content).contains { role($0) == NSAccessibility.Role.staticText.rawValue },
                       "chip 里的标题 / 图标 / × 应当并成一个元素，不再各自露出来：\(dump(content))")
    }

    /// 没给 help 时 chip 的 tooltip 是标题，和读屏名字同一句：AXHelp 要为空，免得 VoiceOver 念两遍。
    /// 给了不同的 help 时照常报出。
    func testTabHelpIsNotRepeatedAsAXHelpWhenItEqualsTheTitle() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "beta") }
        let view = UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { tab in
                UPaneTabDescriptor(title: tab.customTitle ?? "tab", icon: .system("doc"),
                                   help: tab.customTitle == "beta" ? "~/projects/beta.sql" : nil)
            },
            content: { _, _ in Color.clear },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in })
        let window = host(view)
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        func help(of name: String) -> String? {
            nodes(in: content)
                .first { role($0) == NSAccessibility.Role.button.rawValue && label($0) == name }
                .map { ($0.value(forKey: "accessibilityHelp") as? String) ?? "" }
        }
        XCTAssertTrue(waitUntil { help(of: "alpha") != nil && help(of: "beta") != nil }, "\(dump(content))")
        XCTAssertEqual(help(of: "alpha"), "", "help 缺省借标题，和名字同一句，AXHelp 要清空")
        XCTAssertEqual(help(of: "beta"), "~/projects/beta.sql", "不同的 help 照常作为提示")
    }

    func testPressingATabActivatesItAndItsCloseActionRequestsClose() throws {
        let closes = CloseLog()
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "beta") }
        let window = host(area(model, closes: closes))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        var alpha: NSObject?
        XCTAssertTrue(waitUntil {
            alpha = nodes(in: content).first { label($0) == "alpha" }
            return alpha != nil
        }, "\(dump(content))")
        let pressed = (try XCTUnwrap(alpha) as AnyObject).accessibilityPerformPress?() ?? false
        XCTAssertTrue(pressed)
        XCTAssertTrue(waitUntil { model.activeTab?.id == a }, "AX 按下没有切到这枚标签")

        let beta = try XCTUnwrap(nodes(in: content).first { label($0) == "beta" })
        let close = try XCTUnwrap(customActions(beta).first, "× 没有收成具名动作")
        XCTAssertEqual(close.name, String(localized: "关闭", bundle: ModuleBundle.bundle, comment: "关闭标签页"))
        XCTAssertTrue(close.handler?() ?? false)
        XCTAssertEqual(closes.requested, [b], "关闭动作要走 onRequestClose，组件自己不关")
        XCTAssertEqual(model.allTabs.count, 2)
    }

    // MARK: 标签条右侧的图标钮

    func testStripIconButtonsHaveTheirOwnNames() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)                               // 右边是个空组：有「关闭空分组」钮

        for style in [UPaneGroupStyle.classic, .card] {
            let window = host(area(model).uPaneGroupStyle(style))
            defer { window.contentView = NSView(); window.orderOut(nil) }
            let content = try XCTUnwrap(window.contentView)
            let split = String(localized: "拆分分组", bundle: ModuleBundle.bundle,
                               comment: "标签条右侧图标钮的辅助功能名字：在旁边开一个新的分屏分组")
            let closeEmpty = String(localized: "关闭空分组", bundle: ModuleBundle.bundle,
                                    comment: "标签条右侧图标钮的辅助功能名字：收掉这个没有标签的分屏分组")
            func buttons(_ name: String) -> Int {
                nodes(in: content).filter { role($0) == NSAccessibility.Role.button.rawValue && label($0) == name }.count
            }
            XCTAssertTrue(waitUntil { buttons(split) == 2 && buttons(closeEmpty) == 1 },
                          "\(style.kind)：图标钮缺名字：\(dump(content))")
        }
    }

    // MARK: 分隔条

    final class FractionBox: @unchecked Sendable { var value = 0.5 }

    func testSplitterIsASliderThatReportsAndAdjustsTheFraction() throws {
        let box = FractionBox()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let window = host(UPaneSplitter(orientation: .vertical, fraction: binding, totalLength: 800),
                          size: NSSize(width: 6, height: 300))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        let name = String(localized: "调整左右分组宽度", bundle: ModuleBundle.bundle)

        var slider: NSObject?
        XCTAssertTrue(waitUntil {
            slider = nodes(in: content).first { role($0) == NSAccessibility.Role.slider.rawValue && label($0) == name }
            return slider != nil
        }, "分隔条不是带名字的滑杆：\(dump(content))")
        XCTAssertEqual((try XCTUnwrap(slider).value(forKey: "accessibilityValue") as? NSNumber)?.doubleValue ?? -1,
                       0.5, accuracy: 0.001)

        _ = (try XCTUnwrap(slider) as AnyObject).accessibilityPerformIncrement?()
        XCTAssertTrue(waitUntil { abs(box.value - 0.55) < 0.001 }, "「增加」没有把比例挪 5%：\(box.value)")
        _ = (try XCTUnwrap(slider) as AnyObject).accessibilityPerformDecrement?()
        _ = (try XCTUnwrap(slider) as AnyObject).accessibilityPerformDecrement?()
        XCTAssertTrue(waitUntil { abs(box.value - 0.45) < 0.001 }, "\(box.value)")

        // 夹在 [min, max] 里。
        box.value = 0.85
        _ = (try XCTUnwrap(slider) as AnyObject).accessibilityPerformIncrement?()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertLessThanOrEqual(box.value, 0.85 + 0.0001)
    }

    /// 调用方自己挂的标签 / 调节动作盖过分隔条内置的（uTable 的结果表分隔条按 32pt 一步调）。
    func testCallSiteAdjustableActionOverridesTheBuiltInOne() throws {
        final class Log: @unchecked Sendable { var calls = 0 }
        let log = Log()
        let box = FractionBox()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let window = host(
            UPaneSplitter(orientation: .horizontal, fraction: binding, totalLength: 600)
                .accessibilityLabel(Text(verbatim: "调整结果表高度"))
                .accessibilityAdjustableAction { _ in log.calls += 1 },
            size: NSSize(width: 300, height: 6))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        var slider: NSObject?
        XCTAssertTrue(waitUntil {
            slider = nodes(in: content).first { label($0) == "调整结果表高度" }
            return slider != nil
        }, "调用处的标签没落到分隔条上：\(dump(content))")
        _ = (try XCTUnwrap(slider) as AnyObject).accessibilityPerformIncrement?()
        XCTAssertTrue(waitUntil { log.calls == 1 })
        XCTAssertEqual(box.value, 0.5, accuracy: 0.0001, "内置的 5% 不该再叠一次")
    }

    /// 拖动的算术：位移按总长换算成比例，夹在区间里；总长为 0 时不动（不除出 NaN）。
    func testDraggedFractionMath() {
        XCTAssertEqual(UPaneSplitter.draggedFraction(from: 0.5, translation: 80, totalLength: 800,
                                                     minFraction: 0.15, maxFraction: 0.85), 0.6, accuracy: 1e-9)
        XCTAssertEqual(UPaneSplitter.draggedFraction(from: 0.5, translation: -800, totalLength: 800,
                                                     minFraction: 0.15, maxFraction: 0.85), 0.15)
        XCTAssertEqual(UPaneSplitter.draggedFraction(from: 0.5, translation: 800, totalLength: 800,
                                                     minFraction: 0.15, maxFraction: 0.85), 0.85)
        let collapsed = UPaneSplitter.draggedFraction(from: 0.4, translation: 30, totalLength: 0,
                                                      minFraction: 0.15, maxFraction: 0.85)
        XCTAssertEqual(collapsed, 0.4)
        XCTAssertFalse(collapsed.isNaN)
    }
}
#endif
