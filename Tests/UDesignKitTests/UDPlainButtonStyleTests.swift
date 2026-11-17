#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `.udPlain` 替换系统 `.plain`：只去掉按下变淡，静止与禁用的样子必须和 `.plain` 一模一样，
/// 否则全量替换会悄悄改掉几百个按钮的外观。
@MainActor
final class UDPlainButtonStyleTests: XCTestCase {
    private static let swatchColors: [Color] = [
        .black,
        Color(red: 1, green: 0, blue: 0),
        Color(red: 0, green: 0.4, blue: 1),
    ]

    func testEnabledMatchesSystemPlain() {
        for color in Self.swatchColors {
            assertSameRendering(color: color, disabled: false)
        }
    }

    func testDisabledMatchesSystemPlain() {
        for color in Self.swatchColors {
            assertSameRendering(color: color, disabled: true)
        }
    }

    private func assertSameRendering(color: Color, disabled: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let label = Rectangle().fill(color).frame(width: 30, height: 30)
        let system = centerPixel(Button {} label: { label }.buttonStyle(.plain).disabled(disabled))
        let ours = centerPixel(Button {} label: { label }.buttonStyle(.udPlain).disabled(disabled))
        XCTAssertEqual(system.redComponent, ours.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(system.greenComponent, ours.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(system.blueComponent, ours.blueComponent, accuracy: 0.01, file: file, line: line)
    }

    private func centerPixel<V: View>(_ view: V) -> NSColor {
        let host = NSHostingView(rootView: view.frame(width: 40, height: 40).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.colorAt(x: 20, y: 20)!.usingColorSpace(.sRGB)!
    }
}
#endif
