#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDIconButton(weight:)`：加粗一档后图标笔画更粗（墨迹更多），默认仍是常规粗细。
@MainActor
final class UDIconButtonWeightTests: XCTestCase {
    private func inkCoverage(_ weight: Font.Weight?) throws -> Double {
        let button = weight.map { UDIconButton(systemImage: "bubble.left", size: 26, weight: $0) {} }
            ?? UDIconButton(systemImage: "bubble.left", size: 26) {}
        let renderer = ImageRenderer(content: button.environment(\.colorScheme, .light).background(Color.white))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var ink = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                ink += 1 - Double(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1)
            }
        }
        return ink
    }

    func testMediumWeightDrawsThickerStroke() throws {
        let regular = try inkCoverage(nil)
        let medium = try inkCoverage(.medium)
        XCTAssertEqual(try inkCoverage(.regular), regular, accuracy: regular * 0.001, "默认就是常规粗细")
        XCTAssertGreaterThan(medium, regular * 1.1, "加粗一档墨迹应明显变多：\(regular) → \(medium)")
    }
}
#endif
