#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 会叠在一起用的 token 对，在深浅两套外观下都必须解析成**看得出差别**的颜色。
///
/// 调色板换成 Ant Design 预设时，日间 border / panelHi / panelHover / tabActive 撞成同一个
/// #F0F0F0：带描边的卡片悬停时整块填成边框色而丢边，悬停的 tab 与激活 tab 分不出；
/// 次按钮 #F5F5F5 与画布 pageBg 同值而隐形；断开（caution）并进连接中（warning）。
/// 半透明 token 先合成到它实际所在的底色上再比较。
final class UDTokenCollisionTests: XCTestCase {
    private typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    func testHoverIsVisibleOnEverySurfaceItLandsOn() throws {
        for name in appearances {
            for surface in [UD.panel, UD.panelHi, UD.overlay, UD.overlayHi] {
                try assertDistinct(UD.panelHover, over: surface, from: surface, name,
                                   "悬停填充叠上去要看得出")
            }
        }
    }

    func testHoverDoesNotSwallowBorderOrActiveTab() throws {
        for name in appearances {
            try assertDistinct(UD.panelHover, over: UD.panel, from: UD.tabActive, name,
                               "悬停的 tab 不能和激活 tab 同色")
            try assertDistinct(UD.panelHover, over: UD.card, from: UD.borderHi, name,
                               "带描边卡片悬停后描边提到 borderHi，仍要与填充分得开")
        }
    }

    func testSecondaryButtonIsVisibleOnPageCanvas() throws {
        for name in appearances {
            try assertDistinct(UD.button2, over: UD.pageBg, from: UD.pageBg, name,
                               "次按钮放在画布上不能隐形")
            try assertDistinct(UD.button2Hover, over: UD.pageBg, from: UD.button2, name,
                               "次按钮悬停要与默认态分得开")
        }
    }

    func testStatusColorsStayDistinct() throws {
        for name in appearances {
            try assertDistinct(UD.caution, over: UD.bg, from: UD.warning, name,
                               "断开（caution）与连接中（warning）要分得出")
            try assertDistinct(UD.danger, over: UD.bg, from: UD.caution, name,
                               "失败（danger）与断开（caution）要分得出")
        }
    }

    // MARK: - 合成与比较

    private func assertDistinct(_ top: Color, over base: Color, from other: Color,
                                _ name: NSAppearance.Name, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let canvas = try resolve(base, name)
        let a = composite(try resolve(top, name), over: canvas.rgb)
        let b = composite(try resolve(other, name), over: canvas.rgb)
        let delta = max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        XCTAssertGreaterThan(delta, 3.0 / 255, "\(name.rawValue)：\(message)", file: file, line: line)
    }

    private func composite(_ c: (rgb: RGB, a: CGFloat), over base: RGB) -> RGB {
        (c.rgb.r * c.a + base.r * (1 - c.a),
         c.rgb.g * c.a + base.g * (1 - c.a),
         c.rgb.b * c.a + base.b * (1 - c.a))
    }

    private func resolve(_ color: Color, _ name: NSAppearance.Name) throws -> (rgb: RGB, a: CGFloat) {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let c = try XCTUnwrap(resolved, "在 \(name.rawValue) 下解析不出 sRGB 颜色")
        return ((c.redComponent, c.greenComponent, c.blueComponent), c.alphaComponent)
    }
}
#endif
