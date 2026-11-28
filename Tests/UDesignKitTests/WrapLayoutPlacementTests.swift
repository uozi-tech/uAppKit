#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `WrapLayout`：放得下的子视图按理想尺寸排；理想宽度超过行宽的，按行宽重新提议去折行，
/// 不能按理想宽度画出容器（以前一个长气泡会直接冲出右边界，居中时左半截被切掉）。
@MainActor
final class WrapLayoutPlacementTests: XCTestCase {
    private final class Frames { var byID: [Int: CGRect] = [:] }

    /// 排一组子视图，返回每个子视图在布局里的 frame。
    private func layout(width: CGFloat, alignment: WrapLayout.Align = .leading,
                        @ViewBuilder _ content: (Frames) -> some View) -> [Int: CGRect] {
        let frames = Frames()
        let root = WrapLayout(spacing: 8, lineSpacing: 8, alignment: alignment) { content(frames) }
            .frame(width: width, alignment: .topLeading)
            .coordinateSpace(.named("wrap"))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<10 where frames.byID.isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        return frames.byID
    }

    private func probe(_ id: Int, _ frames: Frames) -> some View {
        GeometryReader { geo in
            Color.clear.onAppear { frames.byID[id] = geo.frame(in: .named("wrap")) }
        }
    }

    private static let longText = String(repeating: "很长的一段追问气泡文字 ", count: 12)

    func testOversizedItemWrapsInsideTheRow() throws {
        let frames = layout(width: 200) { frames in
            Text(verbatim: Self.longText).background { probe(0, frames) }
            Text(verbatim: "短").background { probe(1, frames) }
        }
        let long = try XCTUnwrap(frames[0])
        XCTAssertLessThanOrEqual(long.width, 200.5, "超长子视图冲出了容器：\(long)")
        XCTAssertGreaterThanOrEqual(long.minX, -0.5)
        XCTAssertGreaterThan(long.height, 30, "超长文本应在行内折成多行：\(long)")
        let short = try XCTUnwrap(frames[1])
        XCTAssertGreaterThanOrEqual(short.minY, long.maxY, "下一个子视图排到长文本下面一行")
    }

    func testOversizedItemStaysInsideWhenCentered() throws {
        let frames = layout(width: 200, alignment: .center) { frames in
            Text(verbatim: Self.longText).background { probe(0, frames) }
        }
        let long = try XCTUnwrap(frames[0])
        XCTAssertGreaterThanOrEqual(long.minX, -0.5, "居中时左半截被推出容器：\(long)")
        XCTAssertLessThanOrEqual(long.maxX, 200.5)
    }

    func testItemsThatFitKeepTheirIdealSizeAndWrapGreedily() throws {
        let frames = layout(width: 200) { frames in
            Color.red.frame(width: 90, height: 20).background { probe(0, frames) }
            Color.red.frame(width: 90, height: 20).background { probe(1, frames) }
            Color.red.frame(width: 90, height: 20).background { probe(2, frames) }
        }
        let a = try XCTUnwrap(frames[0]), b = try XCTUnwrap(frames[1]), c = try XCTUnwrap(frames[2])
        XCTAssertEqual(a.width, 90, accuracy: 0.5)
        XCTAssertEqual(b.minX, 98, accuracy: 0.5, "同一行：90 + 间距 8")
        XCTAssertEqual(b.minY, a.minY, accuracy: 0.5)
        XCTAssertEqual(c.minX, 0, accuracy: 0.5, "第三个放不下，换行")
        XCTAssertEqual(c.minY, 28, accuracy: 0.5, "行高 20 + 行距 8")
    }
}
#endif
