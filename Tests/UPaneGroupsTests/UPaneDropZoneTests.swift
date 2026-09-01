import XCTest
@testable import UPaneGroups

/// 投放区归类与高亮门控 —— 拖拽逻辑里唯一能脱离视图测的部分。
final class UPaneDropZoneTests: XCTestCase {

    func testDropZoneClassification() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 50), in: bounds), .center)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 5, y: 50), in: bounds), .leading)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 95, y: 50), in: bounds), .trailing)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 5), in: bounds), .top)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 95), in: bounds), .bottom)
        // 中心区正好是 50%×50%，边界含在内。
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 25, y: 25), in: bounds), .center)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 75, y: 75), in: bounds), .center)
        XCTAssertNil(paneDropZone(at: .zero, in: .zero))
        XCTAssertNil(paneDropZone(at: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 0)))
    }

    func testDropZoneRespectsANonZeroOrigin() {
        let bounds = CGRect(x: 100, y: 200, width: 100, height: 100)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 150, y: 250), in: bounds), .center)
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 105, y: 250), in: bounds), .leading)
    }

    func testDropHighlightGate() {
        let group = UUID(), other = UUID(), tab = UUID()
        // 无进行中的拖拽 → 抑制陈旧 hover，不高亮。
        XCTAssertNil(paneDropHighlightZone(
            groupID: group, draggingTabID: nil, draggingSourceGroupID: nil,
            hover: PaneDragHoverTarget(groupID: group, zone: .top)))
        // 拖到源组中心 = 并回原组的 no-op → 不高亮。
        XCTAssertNil(paneDropHighlightZone(
            groupID: group, draggingTabID: tab, draggingSourceGroupID: group,
            hover: PaneDragHoverTarget(groupID: group, zone: .center)))
        // 拖到源组边缘（移动或克隆分屏）→ 高亮。
        XCTAssertEqual(paneDropHighlightZone(
            groupID: group, draggingTabID: tab, draggingSourceGroupID: group,
            hover: PaneDragHoverTarget(groupID: group, zone: .trailing)), .trailing)
        // 其他组任意投放区正常高亮。
        XCTAssertEqual(paneDropHighlightZone(
            groupID: other, draggingTabID: tab, draggingSourceGroupID: group,
            hover: PaneDragHoverTarget(groupID: other, zone: .center)), .center)
        // hover 不在本组 → 不高亮。
        XCTAssertNil(paneDropHighlightZone(
            groupID: group, draggingTabID: tab, draggingSourceGroupID: group,
            hover: PaneDragHoverTarget(groupID: other, zone: .top)))
    }
}

#if os(macOS)
import Observation
import UniformTypeIdentifiers

final class UPaneDragStateTests: XCTestCase {

    /// `dropUpdated` 每帧都调（鼠标不动也调），而 `@Observable` 的 setter 不比较
    /// 新旧值 —— 原样写回同一个 target 也会让所有读 `hover` 的 body 失效。
    @MainActor
    func testSetHoverSkipsRedundantWrites() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let state = UPaneDragState()
        let group = UUID()

        func observeOnce() {
            withObservationTracking {
                _ = state.hover
            } onChange: {
                counter.n += 1
            }
        }

        observeOnce()
        state.setHover(PaneDragHoverTarget(groupID: group, zone: .center))
        XCTAssertEqual(counter.n, 1)

        observeOnce()
        state.setHover(PaneDragHoverTarget(groupID: group, zone: .center))   // 同值
        XCTAssertEqual(counter.n, 1, "同值写入不该让读 hover 的 body 失效")

        state.setHover(PaneDragHoverTarget(groupID: group, zone: .trailing)) // 跨区
        XCTAssertEqual(counter.n, 2)
    }

    @MainActor
    func testBeginAndEndTrackTheDragSource() {
        let state = UPaneDragState()
        let tab = UUID(), group = UUID()
        XCTAssertNil(state.draggingTabID)
        state.begin(tabID: tab, groupID: group)
        XCTAssertEqual(state.draggingTabID, tab)
        XCTAssertEqual(state.draggingSourceGroupID, group)
        XCTAssertNil(state.hover)
        state.setHover(PaneDragHoverTarget(groupID: group, zone: .top))
        state.end()
        XCTAssertNil(state.draggingTabID)
        XCTAssertNil(state.draggingSourceGroupID)
        XCTAssertNil(state.hover)
        state.end()   // 幂等
        XCTAssertNil(state.draggingTabID)
    }

    @MainActor
    func testGroupBoundsAreASharedReferenceNotCapturedValues() {
        // `groupBounds` 是共享引用：delegate 注册后窗口 resize 也要读到新宽高，
        // 否则左右投放区会按旧宽度错判（「改了宽度后左右分屏拖不出来」）。
        let state = UPaneDragState()
        let group = UUID()
        state.groupBounds[group] = CGRect(x: 0, y: 0, width: 100, height: 100)
        let read: () -> CGRect = { state.groupBounds[group] ?? .zero }
        state.groupBounds[group] = CGRect(x: 0, y: 0, width: 400, height: 100)
        XCTAssertEqual(read().width, 400)
    }

    func testItemProviderRoundTrip() {
        let tabID = UUID()
        let type = UTType.plainText
        let provider = UPaneTabDragPayload.itemProvider(tabID: tabID, type: type)
        let done = expectation(description: "loaded")
        nonisolated(unsafe) var loaded: UUID?
        UPaneTabDragPayload.load(from: provider, type: type) { id in
            loaded = id
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(loaded, tabID)
    }
}
#endif
