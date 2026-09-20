#if canImport(AppKit)
import AppKit
import XCTest
@testable import UDesignKit

/// 动态色的外观解析守卫：缓存的是「哪个 Color 对象」，**不是**「解析后的 RGBA」——
/// 同一个 token 在不同外观下必须仍然解析出不同的值。
///
/// 外加 `dynNS` 里那个反复踩到的坑：判深色必须走 `bestMatch(from:)`，不能比
/// `appearance.name == .darkAqua`。VibrantDark（菜单 / popover / 系统浮层用的外观）
/// 的 `name` 是 `NSAppearanceNameVibrantDark`，比 name 会把深色浮层判成浅色，
/// 整个浮层的颜色当场翻浅。
final class UDDynamicColorAppearanceTests: XCTestCase {
    /// 纯黑 / 纯白两个分支，好判。
    private let token = UD.dynNS(.hex(0x000000), .hex(0xFFFFFF))

    func testResolvesDarkBranchUnderDarkAqua() throws {
        XCTAssertEqual(try brightness(of: token, under: .darkAqua), 0, accuracy: 0.01,
                       "darkAqua 下没解析成深色分支。")
    }

    func testResolvesLightBranchUnderAqua() throws {
        XCTAssertEqual(try brightness(of: token, under: .aqua), 1, accuracy: 0.01,
                       "aqua 下没解析成浅色分支。")
    }

    /// 本文件存在的理由。`name == .darkAqua` 会让这条变红。
    func testResolvesDarkBranchUnderVibrantDark() throws {
        XCTAssertEqual(try brightness(of: token, under: .vibrantDark), 0, accuracy: 0.01,
                       "VibrantDark（菜单 / popover）下解析成了浅色——判深色的写法又退回比 name 了。")
    }

    /// 确认这坑是真的：VibrantDark 的 name 确实不等于 darkAqua，`bestMatch` 才认得出它是深色。
    func testVibrantDarkNameDoesNotEqualDarkAqua() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .vibrantDark))
        XCTAssertNotEqual(appearance.name, .darkAqua,
                          "VibrantDark 的 name 变成 darkAqua 了？那本守卫的前提没了，重新确认 dynNS 的写法。")
        XCTAssertEqual(appearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                       "bestMatch 不再把 VibrantDark 归到 darkAqua——dynNS 的判深色逻辑要重做。")
    }

    /// 缓存的强调色 token 同样要随外观解析，不能被预先算死成一个静态色。
    @MainActor
    func testCachedAccentStillResolvesPerAppearance() throws {
        let original = AccentState.shared.selected
        defer { AccentState.shared.selected = original }
        AccentState.shared.selected = .blue

        let accent = try XCTUnwrap(NSColor(UD.accent) as NSColor?)
        XCTAssertNotEqual(try brightness(of: accent, under: .aqua),
                          try brightness(of: accent, under: .darkAqua), accuracy: 0.001,
                          "缓存的 UD.accent 在深浅两个外观下解析出同一个值——"
                          + "动态 provider 被算死成静态色了。")
    }

    /// 在指定外观下解析，返回 sRGB 红分量（本文件的两个分支是黑/白，红分量足够判别）。
    private func brightness(of color: NSColor, under name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name), "取不到外观 \(name.rawValue)")
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "在 \(name.rawValue) 下解析不出 sRGB 颜色").redComponent
    }
}
#endif
