#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UD.accentDivider`：可拖分隔线悬停 / 拖动时的颜色，是强调色本身的 50%（2026-11-26，实色太抢眼）。
@MainActor
final class UDAccentDividerTests: XCTestCase {
    /// 每个强调色、深浅两种外观：RGB 等于强调色本身，alpha 50%。
    func testDividerIsHalfAlphaOfEachAccent() throws {
        for accent in AccentColor.allCases {
            let palette = UD.accentPalette(for: accent)
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let divider = try resolve(palette.divider, under: appearance)
                let base = try resolve(palette.accent, under: appearance)
                let where_ = "\(accent.rawValue) @ \(appearance.rawValue)"
                XCTAssertEqual(divider.redComponent, base.redComponent, accuracy: 0.002, where_)
                XCTAssertEqual(divider.greenComponent, base.greenComponent, accuracy: 0.002, where_)
                XCTAssertEqual(divider.blueComponent, base.blueComponent, accuracy: 0.002, where_)
                XCTAssertEqual(divider.alphaComponent, 0.5, accuracy: 0.002, where_)
            }
        }
    }

    /// 同一强调色两次查表拿到同一个 `Color` 实例（理由见 `UDAccentTokenIdentityTests`）。
    func testDividerIsCachedPerAccent() {
        for accent in AccentColor.allCases {
            XCTAssertEqual(UD.accentPalette(for: accent).divider, UD.accentPalette(for: accent).divider,
                           "\(accent.rawValue) 的 divider 两次读到的不是同一个 Color 实例。")
        }
    }

    private func resolve(_ color: Color, under name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name), "取不到外观 \(name.rawValue)")
        let ns = NSColor(color)
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = ns.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "在 \(name.rawValue) 下解析不出 sRGB 颜色")
    }
}
#endif
