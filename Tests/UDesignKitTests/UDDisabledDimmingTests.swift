#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// 自己画禁用态的组件只压暗一次：`.udPlain` 的 0.5 不能再和组件自己的降透明叠乘
/// （以前 `UDToggle` / `UDCheckbox` 实际是 0.45 × 0.5 ≈ 0.23，几乎看不见）。
///
/// 判法：禁用的控件要和「启用的同一个控件整体 `.opacity(文档值)`」逐像素一致。
/// 两边走同一条渲染与色彩空间换算，所以比的是相对结果，不依赖绝对像素值。
@MainActor
final class UDDisabledDimmingTests: XCTestCase {
    private static var swatch: some View { Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 30, height: 30) }

    func testPlainStyleVariantKeepsLabelOpaqueWhenDisabled() {
        let center = CGPoint(x: 20, y: 20)
        assertSamePixel(Button {} label: { Self.swatch }.buttonStyle(.udPlainKeepsDisabledLook).disabled(true),
                        Self.swatch.frame(width: 40, height: 40), at: center)
        // 默认 `.udPlain` 照旧是 0.5，别的几百个按钮外观不变。
        assertSamePixel(Button {} label: { Self.swatch }.buttonStyle(.udPlain).disabled(true),
                        Self.swatch.frame(width: 40, height: 40).opacity(0.5), at: center)
    }

    func testToggleIsDimmedOnceToDocumentedOpacity() {
        // ON 态轨道左段（knob 在右）是实心强调色。
        let size = CGSize(width: 40, height: 24)
        let toggle = UDToggle(.constant(true))
        assertSamePixel(toggle.disabled(true), toggle.opacity(0.45), size: size, at: CGPoint(x: 6, y: 12))
    }

    func testCheckboxIsDimmedOnceToDocumentedOpacity() {
        // 选中态方块是实心 tint；取方块左上角内侧，避开白色对勾。
        let size = CGSize(width: 80, height: 20)
        let box = UDCheckbox("标志", isOn: .constant(true))
        assertSamePixel(box.disabled(true), box.opacity(0.45), size: size, at: CGPoint(x: 3, y: 4))
    }

    func testPillToggleAndListRowAreDimmedOnce() {
        let pill = UDPillToggle(label: "SELECT", isOn: true) {}
        let pillSize = CGSize(width: 120, height: 32)
        assertSamePixel(pill.disabled(true), pill.opacity(0.6), size: pillSize,
                        at: darkestPoint(pill.opacity(0.6), size: pillSize))
        let row = UDListRow(systemImage: "person.fill", title: "成员") {}
        let rowSize = CGSize(width: 160, height: 30)
        assertSamePixel(row.disabled(true), row.opacity(0.5), size: rowSize,
                        at: darkestPoint(row.opacity(0.5), size: rowSize))
    }

    /// 文字 / 图标落在哪不好写死：取参照图里最深的那个点来比。
    private func darkestPoint<V: View>(_ view: V, size: CGSize) -> CGPoint {
        let rep = render(view, size: size)
        var best = (point: CGPoint.zero, value: CGFloat.infinity)
        for y in 1..<Int(size.height) - 1 {
            for x in 1..<Int(size.width) - 1 {
                let point = CGPoint(x: x, y: y)
                let c = color(in: rep, size: size, at: point)
                let v = c.redComponent + c.greenComponent + c.blueComponent
                if v < best.value { best = (point, v) }
            }
        }
        return best.point
    }

    private func assertSamePixel<A: View, B: View>(_ a: A, _ b: B, size: CGSize = CGSize(width: 40, height: 40),
                                                   at point: CGPoint,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let pa = pixel(a, size: size, at: point)
        let pb = pixel(b, size: size, at: point)
        // 取样点得落在有颜色的地方，白底上两边都是白就什么也没比。
        XCTAssertLessThan(min(pb.redComponent, pb.greenComponent, pb.blueComponent), 0.97,
                          "取样点 \(point) 是白底，换一个落在色块上的点", file: file, line: line)
        XCTAssertEqual(pa.redComponent, pb.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(pa.greenComponent, pb.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(pa.blueComponent, pb.blueComponent, accuracy: 0.02, file: file, line: line)
    }

    private func pixel<V: View>(_ view: V, size: CGSize, at point: CGPoint) -> NSColor {
        color(in: render(view, size: size), size: size, at: point)
    }

    private func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 位图按像素计（可能是 2x），坐标按点换算；y 从上往下。
    private func color(in rep: NSBitmapImageRep, size: CGSize, at point: CGPoint) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / size.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!.usingColorSpace(.sRGB)!
    }
}
#endif
