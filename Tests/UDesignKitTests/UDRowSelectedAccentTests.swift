#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UD.rowSelected` 跟随强调色（1.21.0）。
///
/// 只测 `AccentPalette` 这一层：`UD.rowSelected` 本身读的是 `AccentState.shared`，
/// 那是跑测试这台机器上用户的真实选色，测试不碰它。选色来源用私有 suite 的
/// `AccentState(defaults:)` 驱动，再按它的 `selected` 查表。
@MainActor
final class UDRowSelectedAccentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "UDRowSelectedAccentTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// 每个强调色解析出的选中行底：RGB 等于该强调色本身（同色相），alpha 深 14% / 日 12%。
    func testRowSelectedFollowsEachAccentWithFixedAlpha() throws {
        let state = AccentState(defaults: defaults)
        for accent in AccentColor.allCases {
            state.selected = accent
            let palette = UD.accentPalette(for: state.selected)
            for (appearance, alpha) in [(NSAppearance.Name.darkAqua, 0.14), (.aqua, 0.12)] {
                let row = try resolve(palette.rowSelected, under: appearance)
                let base = try resolve(palette.accent, under: appearance)
                let where_ = "\(accent.rawValue) @ \(appearance.rawValue)"
                XCTAssertEqual(row.redComponent, base.redComponent, accuracy: 0.002, where_)
                XCTAssertEqual(row.greenComponent, base.greenComponent, accuracy: 0.002, where_)
                XCTAssertEqual(row.blueComponent, base.blueComponent, accuracy: 0.002, where_)
                XCTAssertEqual(row.alphaComponent, alpha, accuracy: 0.002,
                               "选中行底的 alpha 变了（\(where_)）——深 14% / 日 12% 是调色板 sel 的值。")
                if base.saturationComponent > 0.05 {
                    XCTAssertEqual(row.hueComponent, base.hueComponent, accuracy: 0.002,
                                   "选中行底的色相不等于强调色（\(where_)）。")
                }
            }
        }
    }

    /// 同一强调色两次查表必须拿到同一个 `Color` 实例——理由见 `UDAccentTokenIdentityTests`。
    func testRowSelectedIsCachedPerAccent() {
        let state = AccentState(defaults: defaults)
        for accent in AccentColor.allCases {
            state.selected = accent
            XCTAssertEqual(UD.accentPalette(for: state.selected).rowSelected,
                           UD.accentPalette(for: state.selected).rowSelected,
                           "\(accent.rawValue) 的 rowSelected 两次读到的不是同一个 Color 实例——又在现建颜色了。")
        }
    }

    /// 不同强调色不能撞到同一个实例上（查表漏 case 会掉进蓝色兜底）。
    func testRowSelectedDiffersAcrossAccents() {
        var seen: [Color] = []
        for accent in AccentColor.allCases {
            let color = UD.accentPalette(for: accent).rowSelected
            XCTAssertFalse(seen.contains(color), "\(accent.rawValue) 的 rowSelected 与前面某色是同一实例。")
            seen.append(color)
        }
    }

    /// `rowSelectedDefault` 是 1.21.0 前 `rowSelected` 的原值：固定蓝、深 14% / 日 12%，
    /// 与蓝色调色板的 rowSelected 解析值一致（uTable 这类无切换器的 app 行为不变）。
    func testRowSelectedDefaultMatchesBluePalette() throws {
        let blue = UD.accentPalette(for: .blue).rowSelected
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let fixed = try resolve(UD.rowSelectedDefault, under: appearance)
            let dynamic = try resolve(blue, under: appearance)
            XCTAssertEqual(fixed.redComponent, dynamic.redComponent, accuracy: 0.002)
            XCTAssertEqual(fixed.greenComponent, dynamic.greenComponent, accuracy: 0.002)
            XCTAssertEqual(fixed.blueComponent, dynamic.blueComponent, accuracy: 0.002)
            XCTAssertEqual(fixed.alphaComponent, dynamic.alphaComponent, accuracy: 0.002)
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
