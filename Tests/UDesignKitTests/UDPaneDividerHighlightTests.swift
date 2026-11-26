#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDPaneDividerHighlight`：始终挂着、靠透明度显隐（才能淡入淡出），不活跃时什么都不画。
@MainActor
final class UDPaneDividerHighlightTests: XCTestCase {
    func testActiveDrawsLightAccentAndInactiveDrawsNothing() throws {
        let active = try centerPixel(active: true)
        let inactive = try centerPixel(active: false)
        XCTAssertGreaterThan(active.blueComponent - active.redComponent, 0.2, "活跃时应画出浅 accent：\(active)")
        XCTAssertLessThan(active.redComponent, 0.95, "活跃时不该是纯白：\(active)")
        XCTAssertEqual(inactive.redComponent, 1, accuracy: 0.01, "不活跃时应完全透明：\(inactive)")
        XCTAssertEqual(inactive.blueComponent, 1, accuracy: 0.01, "不活跃时应完全透明：\(inactive)")
    }

    private func centerPixel(active: Bool) throws -> NSColor {
        let view = ZStack {
            Color.white
            UDPaneDividerHighlight(.vertical, active: active)
        }
        .frame(width: 21, height: 40)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 21, height: 40)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let c = try XCTUnwrap(rep.colorAt(x: Int(10.5 * scale), y: Int(20 * scale)))
        return try XCTUnwrap(c.usingColorSpace(.sRGB))
    }
}
#endif
