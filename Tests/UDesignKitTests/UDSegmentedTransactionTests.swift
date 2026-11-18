#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDSegmented` 切换时不能把动画事务带给使用方：分段下面的内容按选中值整块换（分支 / 拉取请求
/// 两页这类）时，带着动画会淡入淡出叠影，放在锚定浮层里还会因窗口先改尺寸而被截断几帧。
@MainActor
final class UDSegmentedTransactionTests: XCTestCase {
    private final class Recorder {
        var animated: [Bool] = []
    }

    private struct Host: View {
        let recorder: Recorder
        @State private var selection = "a"

        var body: some View {
            VStack {
                UDSegmented(selection: $selection, options: [("a", "甲页"), ("b", "乙页")])
                Text(selection == "a" ? "甲内容" : "乙内容")
                    .transaction { recorder.animated.append($0.animation != nil) }
            }
            .frame(width: 320, height: 120)
        }
    }

    private func nodes(in root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 40 else { return [] }
        let children = (root.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        return [root] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    private func text(_ node: NSObject) -> String {
        ((node.value(forKey: "accessibilityLabel") as? String) ?? "")
            + ((node.value(forKey: "accessibilityValue") as? String) ?? "")
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return condition()
    }

    func testSwitchingSegmentUpdatesConsumerWithoutAnimation() throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let recorder = Recorder()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(recorder: recorder))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        let content = try XCTUnwrap(window.contentView)

        var second: NSObject?
        XCTAssertTrue(waitUntil {
            second = nodes(in: content).first {
                ($0.value(forKey: "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue && text($0).contains("乙页")
            }
            return second != nil
        }, "找不到「乙页」分段按钮")
        recorder.animated.removeAll()

        XCTAssertTrue((try XCTUnwrap(second) as AnyObject).accessibilityPerformPress?() ?? false)
        XCTAssertTrue(waitUntil { nodes(in: content).contains { text($0).contains("乙内容") } }, "切换后内容没换")
        // `.transaction` 回调次数由 SwiftUI 决定（整套跑时可能一次都不回调），只判「没有带动画的那次」；
        // 换回旧的 `withAnimation` 写法时这里稳定记到 true。
        XCTAssertFalse(recorder.animated.contains(true), "切换分段把动画事务带给了使用方：\(recorder.animated)")
    }
}
#endif
