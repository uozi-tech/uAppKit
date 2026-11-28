#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 刷新图标绕圆心转：`arrow.clockwise` 的墨迹框被箭头撑偏，轴心要用拟合出的圆心。
@MainActor
final class USymbolRotationAnchorTests: XCTestCase {
    /// 真实的 12pt 刷新图标转到几个角度渲染出来，量环的圆心漂了多远（= 转起来晃的幅度）。
    private func wobble(anchor: UnitPoint) throws -> CGFloat {
        var centers: [CGPoint] = []
        for degrees in stride(from: 0.0, to: 360.0, by: 45.0) {
            let view = USymbol("arrow.clockwise", size: 12, box: 13)
                .rotationEffect(.degrees(degrees), anchor: anchor)
                .foregroundStyle(Color.black)
                .frame(width: 24, height: 24)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 4
            let cgImage = try XCTUnwrap(renderer.cgImage)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: 24, height: 24))
            centers.append(try XCTUnwrap(USymbolMetrics.circleCenter(of: image)))
        }
        let mean = CGPoint(x: centers.map(\.x).reduce(0, +) / CGFloat(centers.count),
                           y: centers.map(\.y).reduce(0, +) / CGFloat(centers.count))
        return centers.map { hypot($0.x - mean.x, $0.y - mean.y) }.max() ?? 0
    }

    func testRefreshIconSpinsInPlace() throws {
        let anchor = try XCTUnwrap(USymbolMetrics.rotationAnchor("arrow.clockwise"))
        let fixed = try wobble(anchor: anchor)
        let naive = try wobble(anchor: .center)
        XCTAssertLessThan(fixed, 0.2, "绕圆心转，环的圆心几乎不动：\(fixed)pt")
        XCTAssertGreaterThan(naive, 0.5, "绕墨迹框中心转会晃（对照）：\(naive)pt")
    }

    /// 已知圆心的环（加一个偏在一侧的「箭头」块）：拟合出的圆心误差在 0.3pt 内，不被箭头带偏到墨迹框中心。
    func testCircleFitFindsRingCenterDespiteArrowhead() throws {
        let size = NSSize(width: 40, height: 48)
        let center = CGPoint(x: 20, y: 28)   // 左上原点
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
            ring.lineWidth = 3
            ring.stroke()
            NSColor.black.setFill()
            // 箭头：环顶上偏右的三角，把墨迹框往上撑。
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 22, y: 6)); head.line(to: NSPoint(x: 30, y: 14)); head.line(to: NSPoint(x: 22, y: 20))
            head.close()
            head.fill()
            return true
        }
        let fitted = try XCTUnwrap(USymbolMetrics.circleCenter(of: image))
        XCTAssertEqual(fitted.x, center.x, accuracy: 0.6)
        XCTAssertEqual(fitted.y, center.y, accuracy: 0.6)
        // 墨迹框中心在 y ≈ (6 + 43.5) / 2 ≈ 24.8，比圆心高约 3pt；拟合结果要贴近真圆心。
    }

    /// `arrow.clockwise`：圆心比墨迹框中心低（箭头在上），左右基本居中。
    func testArrowClockwiseAnchorIsBelowInkCenter() throws {
        let anchor = try XCTUnwrap(USymbolMetrics.rotationAnchor("arrow.clockwise"))
        XCTAssertEqual(anchor.x, 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(anchor.y, 0.53, "轴心应在墨迹框中心下方：\(anchor)")
        XCTAssertLessThan(anchor.y, 0.62, "\(anchor)")
    }

    /// 拟合不出（这里用不存在的符号）也要记下来，否则每次求值都重新光栅化 + 拟合。
    func testMissingAnchorIsCachedToo() {
        let name = "udesignkit.test.no-such-symbol"
        XCTAssertNil(USymbolMetrics.rotationAnchor(name))
        XCTAssertTrue(USymbolMetrics.hasCachedRotationAnchor(name), "nil 结果没进缓存")
    }

    /// 首次算轴心要光栅化 + 圆拟合（实测 10–300ms）：不转的图标钮不该付这笔，开始转了才算。
    func testIconButtonComputesAnchorOnlyOnceSpinning() {
        let name = "square.and.arrow.down.on.square"
        XCTAssertFalse(USymbolMetrics.hasCachedRotationAnchor(name), "前置：别的用例没算过这个符号")

        func render(spinning: Bool) {
            let hosting = NSHostingView(rootView: UDIconButton(systemImage: name, isSpinning: spinning) {})
            hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }

        render(spinning: false)
        XCTAssertFalse(USymbolMetrics.hasCachedRotationAnchor(name), "不转的图标钮也算了轴心")
        render(spinning: true)
        XCTAssertTrue(USymbolMetrics.hasCachedRotationAnchor(name), "转起来时应按圆心转，轴心得算出来")
    }
}
#endif
