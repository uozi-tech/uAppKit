#if canImport(AppKit)
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDPanelListStack`：列表高在同一次布局里算出（不再等外框高下一拍写回），
/// 所以面板呈现时的尺寸就是最终尺寸，屏幕边缘受限时不会先多出一截再缩回。
@MainActor
final class UDPanelListStackTests: XCTestCase {
    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 30

    @Observable
    final class Model {
        var rows = 30
        var lazy = false
        var isPresented = false
        var useUDMenu = false
    }

    private struct Menu: View {
        let model: Model

        var body: some View {
            UDPanelListStack(spacing: 1, listMaxHeight: 420, reserved: 12) {
                Color.red.frame(height: UDPanelListStackTests.headerHeight)
                ScrollView(.vertical) {
                    if model.lazy {
                        LazyVStack(spacing: 0) { rows }
                    } else {
                        VStack(spacing: 0) { rows }
                    }
                }
                .udPanelList()
                Color.blue.frame(height: UDPanelListStackTests.footerHeight)
            }
            .padding(6)
            .frame(width: 240)
        }

        private var rows: some View {
            ForEach(0..<model.rows, id: \.self) { i in
                Text("row \(i)").frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: UDPanelListStackTests.rowHeight)
            }
        }
    }

    /// 外框（列表以外）= header + footer + 两道间距 + 外层 padding。
    private static let chrome: CGFloat = headerHeight + footerHeight + 2 + 12

    private func fittingHeight(_ model: Model, available: CGFloat? = nil) -> CGFloat {
        let host = NSHostingView(rootView: Menu(model: model).environment(\.udPanelAvailableHeight, available))
        return host.fittingSize.height
    }

    func testListTakesContentHeightUpToCap() {
        let model = Model()
        model.rows = 30
        XCTAssertEqual(fittingHeight(model), Self.chrome + 420, accuracy: 0.5, "长列表钉在固定上限")
        model.rows = 3
        XCTAssertEqual(fittingHeight(model), Self.chrome + 3 * Self.rowHeight, accuracy: 0.5,
                       "短列表贴内容高，不被撑到上限")
    }

    func testLazyListMeasuresLikeEagerOne() {
        let model = Model()
        model.lazy = true
        model.rows = 30
        XCTAssertEqual(fittingHeight(model), Self.chrome + 420, accuracy: 0.5)
        model.rows = 3
        XCTAssertEqual(fittingHeight(model), Self.chrome + 3 * Self.rowHeight, accuracy: 0.5)
    }

    func testAvailableHeightLimitsWholePanelInOnePass() {
        let model = Model()
        model.rows = 30
        XCTAssertEqual(fittingHeight(model, available: 300), 300, accuracy: 0.5,
                       "受限时整块内容恰好等于可用高度（外框已从列表里扣掉）")
        XCTAssertEqual(fittingHeight(model, available: 2000), Self.chrome + 420, accuracy: 0.5,
                       "可用高宽裕时仍守固定上限")
        XCTAssertEqual(fittingHeight(model, available: 40), Self.chrome + UDPanelListCap.minimum, accuracy: 0.5,
                       "再局促也给列表留最低高度")
    }

    func testFilteringShrinksInTheSameLayoutPass() {
        let model = Model()
        model.rows = 30
        let host = NSHostingView(rootView: Menu(model: model))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, Self.chrome + 420, accuracy: 0.5)
        model.rows = 2
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, Self.chrome + 2 * Self.rowHeight, accuracy: 0.5)
    }

    // MARK: - 真面板：呈现后不再改尺寸

    private struct Host: View {
        @Bindable var model: Model
        var body: some View {
            VStack(spacing: 0) {
                Color.gray.frame(width: 120, height: 24)
                    .anchoredPanel(isPresented: $model.isPresented, becomesKey: true) { _ in
                        if model.useUDMenu {
                            UDMenu(head: "Items", maxHeight: 420,
                                   items: (0..<model.rows).map { UDMenuItem(label: "item \($0)", action: {}) })
                        } else {
                            Menu(model: model)
                        }
                    }
                Spacer(minLength: 0)
            }
            .frame(width: 400, height: 60)
        }
    }

    /// 锚点贴着屏幕可见区下沿上方 `roomBelow` 处，展开一个长列表面板，记下面板窗口的每一次改尺寸。
    private func panelResizes(roomBelow: CGFloat, udMenu: Bool = false) throws -> (initial: CGFloat, resizes: [CGFloat], panel: NSPanel) {
        let screen = try XCTUnwrap(NSScreen.main)
        let model = Model()
        model.rows = 30
        model.useUDMenu = udMenu
        let host = NSHostingView(rootView: Host(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        // 窗口顶边（锚点在内容顶部 24pt）落在可见区下沿 + roomBelow + 24 处。
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 40,
                                                  y: screen.visibleFrame.minY + roomBelow + 24 - 60,
                                                  width: 400, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC 管生命周期；默认 true 会在 close() 时二次释放
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        var resizes: [CGFloat] = []
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                           object: nil, queue: nil) { note in
            guard let panel = note.object as? NSPanel else { return }
            MainActor.assumeIsolated { resizes.append(panel.frame.height) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.isPresented = true
        var panel: NSPanel?
        for _ in 0..<40 where panel == nil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            panel = window.childWindows?.compactMap { $0 as? NSPanel }.first
        }
        let presented = try XCTUnwrap(panel, "面板没有呈现")
        let initial = presented.frame.height
        // 给异步回写（若还有）足够的拍数落地。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        model.isPresented = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return (initial, resizes, presented)
    }

    func testConstrainedPanelOpensAtFinalHeight() throws {
        let r = try panelResizes(roomBelow: 260)
        XCTAssertEqual(r.resizes, [], "受限面板呈现后又改了尺寸（先高后缩 = 打开时闪一下）：初始 \(r.initial)")
        // 面板窗口 = 内容 + 上下各 24pt 落影边距；内容应被压进锚点下方 260pt 的空间。
        XCTAssertLessThanOrEqual(r.initial - 48, 260, "受限面板没被压进可用高度：初始 \(r.initial)")
    }

    func testRoomyPanelOpensAtFinalHeight() throws {
        let r = try panelResizes(roomBelow: 900)
        XCTAssertEqual(r.resizes, [], "不受限面板呈现后又改了尺寸：初始 \(r.initial)")
    }

    func testConstrainedUDMenuOpensAtFinalHeight() throws {
        let r = try panelResizes(roomBelow: 260, udMenu: true)
        XCTAssertEqual(r.resizes, [], "受限 UDMenu 呈现后又改了尺寸：初始 \(r.initial)")
        XCTAssertLessThanOrEqual(r.initial - 48, 260, "受限 UDMenu 没被压进可用高度：初始 \(r.initial)")
    }
}
#endif
