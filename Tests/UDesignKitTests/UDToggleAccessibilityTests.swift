#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDToggle` 外观是自绘的 `Button(.plain)`，但对辅助功能必须是一个开关：有名字、读得出开 / 关，
/// 按下（AX 默认动作）就拨动绑定。以前它只是一个没名字的「按钮」，VoiceOver 听不出状态。
@MainActor
final class UDToggleAccessibilityTests: XCTestCase {
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

    private func value(_ node: NSObject) -> Int? {
        (node.value(forKey: "accessibilityValue") as? NSNumber)?.intValue
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    private final class Box {
        var isOn = false
    }

    /// 摆一个 UDToggle 到屏外窗口里，返回窗口内容视图；调用方负责 `defer` 收窗口。
    private func host(_ view: some View) -> NSWindow {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 200, height: 80))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        return window
    }

    func testLabelledToggleIsACheckBoxThatReportsAndFlipsState() throws {
        let box = Box()
        let binding = Binding(get: { box.isOn }, set: { box.isOn = $0 })
        let window = host(UDToggle(binding, label: Text(verbatim: "热加载")))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        var toggle: NSObject?
        let found = waitUntil {
            toggle = nodes(in: content).first { role($0) == NSAccessibility.Role.checkBox.rawValue && label($0) == "热加载" }
            return toggle != nil
        }
        XCTAssertTrue(found, "UDToggle 不是带名字的 AX 开关：\(nodes(in: content).map { "\(role($0))|\(label($0))" })")
        XCTAssertEqual(value(try XCTUnwrap(toggle)), 0)

        let pressed = (try XCTUnwrap(toggle) as AnyObject).accessibilityPerformPress?() ?? false
        XCTAssertTrue(pressed)
        XCTAssertTrue(waitUntil { box.isOn }, "AX 按下没有拨动绑定")
    }

    func testCallSiteAccessibilityLabelNamesTheToggle() throws {
        let box = Box()
        let binding = Binding(get: { box.isOn }, set: { box.isOn = $0 })
        let window = host(UDToggle(binding).accessibilityLabel(Text(verbatim: "允许写操作")))
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)

        let found = waitUntil {
            nodes(in: content).contains { role($0) == NSAccessibility.Role.checkBox.rawValue && label($0) == "允许写操作" }
        }
        XCTAssertTrue(found, "调用处的 accessibilityLabel 没落到开关上：\(nodes(in: content).map { "\(role($0))|\(label($0))" })")
    }
}
#endif
