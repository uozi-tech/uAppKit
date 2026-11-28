#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `.help` 同时报 AXHelp：读屏名字借自 help（或恰好同一句）时，开着「读提示」的 VoiceOver 会
/// 念完名字再念一遍。`udHelp` 让这种情况下 AXHelp 为空；名字和 help 不同时 help 照常报。
/// （uTable 升 2.1.5 后在标题栏「开启只读模式」的 UDGlyphButton 上报的问题。）
@MainActor
final class UDHelpAccessibilityTests: XCTestCase {
    private func nodes(in root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 40 else { return [] }
        let children = (root.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        return [root] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    private struct Button: Equatable {
        let label: String
        let help: String
    }

    private func buttons(in view: some View) throws -> [Button] {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 240, height: 80))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.contentView = NSView(); window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        var found: [Button] = []
        for _ in 0..<200 {
            found = nodes(in: content)
                .filter { ($0.value(forKey: "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue }
                .map { Button(label: ($0.value(forKey: "accessibilityLabel") as? String) ?? "",
                              help: ($0.value(forKey: "accessibilityHelp") as? String) ?? "") }
            if !found.isEmpty { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return found
    }

    func testGlyphButtonNamedByHelpDoesNotRepeatItAsAXHelp() throws {
        let found = try buttons(in: UDGlyphButton(icon: .sf("lock"), help: "开启只读模式") {})
        XCTAssertEqual(found, [Button(label: "开启只读模式", help: "")],
                       "名字借自 help 时 AXHelp 要清空，否则 VoiceOver 念两遍")
    }

    func testDistinctNameKeepsHelpAsAXHelp() throws {
        let found = try buttons(in: SwiftUI.Button {} label: { Image(systemName: "square.split.2x1") }
            .udHelp("拆分出一个新分组（⌘\\）", accessibilityName: "拆分分组"))
        XCTAssertEqual(found, [Button(label: "拆分分组", help: "拆分出一个新分组（⌘\\）")],
                       "名字和 help 不同，help 照常作为提示报出")
    }

    func testExplicitNameEqualToHelpAlsoClearsAXHelp() throws {
        let found = try buttons(in: SwiftUI.Button {} label: { Image(systemName: "pencil") }
            .udHelp("编辑", accessibilityName: "编辑"))
        XCTAssertEqual(found, [Button(label: "编辑", help: "")])
    }

    func testEmptyHelpLeavesInferredNameAlone() throws {
        let found = try buttons(in: UDGlyphButton(icon: .sf("lock")) {})
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.help, "")
        XCTAssertFalse(found.first?.label.isEmpty ?? true, "没有 help 时保留 SwiftUI 从 SF 符号推出的名字")
    }
}
#endif
