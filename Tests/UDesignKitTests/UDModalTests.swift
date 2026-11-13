#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 自绘模态弹层的外观与布局：不描边、投影四周均匀、窗口再矮也不贴边。
@MainActor
final class UDModalTests: XCTestCase {
    private let canvas = CGSize(width: 400, height: 300)

    /// 浅色下卡片四边外侧都有投影、深浅相当；卡片内贴边处是卡片底色，没有描边。
    func testLightCardHasUniformShadowAndNoBorder() throws {
        let image = try render(UDModal(onDismiss: {}) {
            Color.clear.frame(width: 200, height: 100)
        })
        // 卡片居中：x 100…300，y 100…200。
        let outside = [
            image.brightness(x: 96, y: 150),   // 左
            image.brightness(x: 303, y: 150),  // 右
            image.brightness(x: 200, y: 96),   // 上
            image.brightness(x: 200, y: 203),  // 下
        ]
        for value in outside {
            XCTAssertLessThan(value, 0.985, "卡片外侧没有投影：\(outside)")
        }
        XCTAssertLessThan(outside.max()! - outside.min()!, 0.02,
                          "四边投影深浅不一（带了纵向偏移？）：\(outside)")

        let insideEdges = [
            image.brightness(x: 101, y: 150),
            image.brightness(x: 298, y: 150),
            image.brightness(x: 200, y: 101),
            image.brightness(x: 200, y: 198),
        ]
        let fill = image.brightness(x: 200, y: 150)
        for value in insideEdges {
            XCTAssertEqual(value, fill, accuracy: 0.01, "卡片边缘颜色与底色不同，像是描了边：\(insideEdges)")
        }
    }

    /// 内容比窗口高时，卡片上下都离窗口边留出 `windowInset`。
    func testCardKeepsInsetFromShortWindow() throws {
        let image = try render(UDModal(onDismiss: {}) {
            Color(red: 1, green: 0, blue: 0).frame(width: 200).frame(maxHeight: .infinity)
        })
        let column = 200
        let redRows = (0..<Int(canvas.height)).filter { image.isRed(x: column, y: $0) }
        let inset = Int(UD.ModalCard.windowInset)
        XCTAssertEqual(redRows.first, inset, "卡片顶到了窗口上沿")
        XCTAssertEqual(redRows.last, Int(canvas.height) - inset - 1, "卡片顶到了窗口下沿")
    }

    private func render(_ view: some View) throws -> Bitmap {
        let renderer = ImageRenderer(content: view
            .frame(width: canvas.width, height: canvas.height)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        let cgImage = try XCTUnwrap(renderer.cgImage, "渲染失败")
        return Bitmap(NSBitmapImageRep(cgImage: cgImage))
    }

    private struct Bitmap {
        let rep: NSBitmapImageRep
        init(_ rep: NSBitmapImageRep) { self.rep = rep }

        private func color(_ x: Int, _ y: Int) -> NSColor {
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        }

        func brightness(x: Int, y: Int) -> CGFloat {
            let c = color(x, y)
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }

        func isRed(x: Int, y: Int) -> Bool {
            let c = color(x, y)
            return c.redComponent > 0.8 && c.greenComponent < 0.3 && c.blueComponent < 0.3
        }
    }
}
#endif
