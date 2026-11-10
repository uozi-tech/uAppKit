#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import UAppKitBridge
@testable import UPaneGroups

/// 标签 chip 的拖拽源，接在真的 `UPaneGroupArea` 上测两头：
/// - 起拖：按在 chip 上，拖过死区才起会话，拖拽板上是这枚标签的 id；
/// - 落点：这份拖拽板载荷 SwiftUI 的 `.onDrop` 认得（落点用伪造的 `NSDraggingInfo` 喂给宿主视图）。
///
/// 中间那段——AppKit 的拖拽循环本身——要真的按住鼠标，单测里起不了（会卡到松手为止）。
@MainActor
final class UPaneTabDragSourceTests: XCTestCase {
    private let dragType = UTType.plainText

    private struct Marker: NSViewRepresentable {
        let tabID: UUID
        func makeNSView(context: Context) -> UPaneGroupAreaViewTests.MarkerView { .init(tabID: tabID) }
        func updateNSView(_ nsView: UPaneGroupAreaViewTests.MarkerView, context: Context) {}
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    /// 整棵子树，按绘制顺序（后面的盖在前面的上面）。
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func host(_ model: UPaneGroupsModel<TestPayload>) -> (window: NSWindow, host: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: UPaneGroupArea(
            model: model,
            dragType: dragType,
            descriptor: { tab in UPaneTabDescriptor(title: tab.customTitle ?? "tab", icon: .system("doc")) },
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in }))
        window.contentView = host
        settle(window)
        return (window, host)
    }

    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    // MARK: 起拖

    func testChipStartsADragOnlyAfterTheDeadZoneAndCarriesItsTabID() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "beta") }
        let (window, hostView) = host(model)
        defer { window.contentView = nil }

        // 每枚 chip 一个拖拽源，从左到右就是标签顺序。
        let probes = find(DragSourceProbeView.self, in: hostView)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(probes.count, 2)
        var dragged: [UUID] = []
        for probe in probes {
            probe.startSession = { item, _ in
                let data = (item.item as? NSPasteboardItem)?
                    .data(forType: NSPasteboard.PasteboardType(self.dragType.identifier))
                if let id = data.flatMap({ UUID(uuidString: String(decoding: $0, as: UTF8.self)) }) {
                    dragged.append(id)
                }
            }
        }

        let frame = probes[1].convert(probes[1].bounds, to: nil)
        // 靠左按，躲开右侧的关闭按钮。
        let press = NSPoint(x: frame.minX + 14, y: frame.midY)

        // 点一下、手抖 3pt：不起拖。按下即激活照旧。
        model.activateTab(groupID: try XCTUnwrap(model.activeGroupID), index: 0)
        send(.leftMouseDown, at: press, in: window)
        send(.leftMouseDragged, at: NSPoint(x: press.x + 3, y: press.y), in: window)
        send(.leftMouseUp, at: NSPoint(x: press.x + 3, y: press.y), in: window)
        XCTAssertEqual(dragged, [])
        XCTAssertEqual(model.activeTab?.id, b, "按下就该切到这枚标签")

        // 按住拖出去：起一次，带的是这枚标签。
        send(.leftMouseDown, at: press, in: window)
        send(.leftMouseDragged, at: NSPoint(x: press.x + 3, y: press.y), in: window)
        send(.leftMouseDragged, at: NSPoint(x: press.x + 12, y: press.y - 9), in: window)
        send(.leftMouseDragged, at: NSPoint(x: press.x + 40, y: press.y - 60), in: window)
        XCTAssertEqual(dragged, [b])
        XCTAssertNotEqual(a, b)
    }

    /// 垫在标签区下面、会自己处理 `mouseDown` 的 AppKit 视图（app 里是标题栏的拖窗手柄）。
    private final class UnderlayView: NSView {
        override func mouseDown(with event: NSEvent) {}
    }

    private struct Underlay: NSViewRepresentable {
        func makeNSView(context: Context) -> UnderlayView { UnderlayView() }
        func updateNSView(_ nsView: UnderlayView, context: Context) {}
    }

    /// 拖拽源对命中测试透明，但 chip 本身不能跟着变透明：按在标签上不该漏给垫在下面的
    /// AppKit 视图（标签条在标题栏里时，那就是拖窗手柄——死区里窗口会先被拖走）。
    func testPressOnAChipDoesNotFallThroughToAppKitViewsUnderneath() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hostView = NSHostingView(rootView: UPaneGroupArea(
            model: model,
            dragType: dragType,
            descriptor: { tab in UPaneTabDescriptor(title: tab.customTitle ?? "tab", icon: .system("doc")) },
            content: { _, _ in Color.clear },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in }).background(Underlay()))
        window.contentView = hostView
        defer { window.contentView = nil }
        settle(window)

        XCTAssertEqual(find(UnderlayView.self, in: hostView).count, 1, "垫底视图还没挂上，测试是空的")
        let probe = try XCTUnwrap(find(DragSourceProbeView.self, in: hostView).first)
        let frame = probe.convert(probe.bounds, to: hostView)
        let hit = hostView.hitTest(NSPoint(x: frame.minX + 14, y: frame.midY))
        XCTAssertFalse(hit is UnderlayView, "按在标签上漏给了下面的 AppKit 视图")
        XCTAssertNotNil(hit)
    }

    // MARK: 落点

    /// 喂给 `NSDraggingDestination` 的假拖拽：只带拖拽板与位置。
    private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = .move
        let draggingLocation: NSPoint
        var draggedImageLocation: NSPoint { draggingLocation }
        let draggedImage: NSImage? = nil
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any? = nil
        let draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        @MainActor
        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            draggingDestinationWindow = window
            draggingLocation = location
            draggingPasteboard = pasteboard
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    func testThePasteboardPayloadIsAcceptedBySwiftUIDropTargets() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "alpha") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "beta") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let c = model.openTab { UPaneTab(payload: .scratch, customTitle: "gamma") }
        let g2 = try XCTUnwrap(model.locateTab(c)?.groupID)
        XCTAssertNotEqual(g1, g2)

        let (window, hostView) = host(model)
        defer { window.contentView = nil }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("UPaneTabDragSourceTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([UPaneTabDragPayload.pasteboardItem(tabID: a, type: dragType)]))

        // 落在另一组面板的正中：并进那一组。
        let target = try XCTUnwrap(find(UPaneGroupAreaViewTests.MarkerView.self, in: hostView)
            .first { $0.tabID == c })
        let centre = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let info = FakeDraggingInfo(window: window, location: centre, pasteboard: pasteboard)

        // SwiftUI 给每个 `.onDrop` 垫一个登记了拖放类型的 NSView；取盖在落点上、最靠前的那个。
        let destination = try XCTUnwrap(
            descendants(of: hostView).last {
                !$0.registeredDraggedTypes.isEmpty && $0.convert($0.bounds, to: nil).contains(centre)
            },
            "落点上没有登记拖放类型的视图")
        XCTAssertNotEqual(destination.draggingEntered(info), [], "SwiftUI 的落点不认这份载荷")
        XCTAssertNotEqual(destination.draggingUpdated(info), [])
        XCTAssertTrue(destination.prepareForDragOperation(info))
        XCTAssertTrue(destination.performDragOperation(info))
        // 没有进程内的拖拽源（没起会话），落点从拖拽板异步取 id。
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(model.locateTab(a)?.groupID, g2, "标签应当并进落点所在的组")
    }
}
#endif
