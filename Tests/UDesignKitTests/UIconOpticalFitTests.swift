import SwiftUI
import XCTest
@testable import UDesignKit

/// 图标钮里的图标「大小一致、居中」两条契约（见 `USymbol` / `UIconShape`）。
///
/// 背景：按字号排版时，同为 13pt 的 `terminal` 墨迹宽 15pt、`sparkles` 不到 12pt；
/// `person.2` 在 15pt 下宽 20.5pt；`chevron.left` 在排版框里偏左近 0.9pt；
/// 自绘的 `toolUndo` 在 viewBox 里偏右 1.25pt。
final class UIconOpticalFitTests: XCTestCase {

    #if canImport(AppKit)
    /// 超出图标框的符号被收进去；本来放得下的保持原字号（不放大）。
    func testSymbolsFitTheirBoxWithoutGrowing() throws {
        let cases: [(String, CGFloat, CGFloat)] = [
            ("terminal", 13, 13), ("rectangle.bottomthird.inset.filled", 13, 13), ("sparkles", 13, 13),
            ("person.2", 15, 16), ("key", 15, 16), ("tablecells", 15, 16), ("square.and.arrow.up", 15, 16),
            ("eye", 12, 13), ("doc.on.doc", 10, 11),
        ]
        for (name, size, box) in cases {
            let natural = try XCTUnwrap(USymbolMetrics.measure(name, size: size, weight: .regular), name)
            let fit = try XCTUnwrap(USymbolMetrics.fitted(name, size: size, weight: .regular, box: box), name)
            let extent = max(fit.ink.width, fit.ink.height)
            XCTAssertLessThanOrEqual(extent, box + 0.01, "\(name) 墨迹 \(extent) 超出图标框 \(box)")
            XCTAssertLessThanOrEqual(extent, max(natural.ink.width, natural.ink.height) + 0.01, "\(name) 被放大了")
        }
        // 放得下的不动：xmark 12pt 墨迹约 9.5pt。
        let xmark = try XCTUnwrap(USymbolMetrics.fitted("xmark", size: 12, weight: .regular, box: 13))
        let natural = try XCTUnwrap(USymbolMetrics.measure("xmark", size: 12, weight: .regular))
        XCTAssertEqual(xmark.ink, natural.ink)
    }

    /// 偏移后墨迹中心与图像中心重合（`chevron.left` 原本偏左近 0.9pt）。
    func testSymbolOffsetCentersInk() throws {
        for name in ["chevron.left", "chevron.right", "wand.and.stars", "square.and.arrow.up", "person.badge.plus"] {
            let fit = try XCTUnwrap(USymbolMetrics.fitted(name, size: 12, weight: .regular, box: nil), name)
            let cx = fit.ink.midX + fit.offset.width
            let cy = fit.ink.midY + fit.offset.height
            XCTAssertEqual(cx, fit.image.size.width / 2, accuracy: 0.001, name)
            XCTAssertEqual(cy, fit.image.size.height / 2, accuracy: 0.001, name)
        }
    }

    func testUnknownSymbolFallsBack() {
        XCTAssertNil(USymbolMetrics.fitted("no.such.symbol.uozi", size: 12, weight: .regular, box: 13))
    }
    #endif

    /// 自绘字形按墨迹居中、缩放比仍按 viewBox（相对大小不变）。
    func testGlyphPathIsInkCentered() {
        let rect = CGRect(x: 3, y: 5, width: 14, height: 14)
        for glyph in [UIconGlyph.toolUndo, .copyRow, .panelBottom, .objCagg, .objFunc, .sendArrow, .setAgent, .lockOutline] {
            let bounds = UIconShape(glyph: glyph).path(in: rect).boundingRect
            XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.001)
            XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.001)
            // 只平移、不改缩放：与旧的「viewBox 贴框」变换比，尺寸一致。
            let scale = rect.width / glyph.box
            let viewBoxFit = UIconEngine.outline(for: glyph)
                .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
                .boundingRect
            XCTAssertEqual(bounds.width, viewBoxFit.width, accuracy: 0.001)
            XCTAssertEqual(bounds.height, viewBoxFit.height, accuracy: 0.001)
        }
    }
}
