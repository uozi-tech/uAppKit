import XCTest
import UPaneTree
@testable import UPaneGroups

/// 跨模型移交（窗口之间拖标签、拖出成新窗口）：`detachTab` / `insertTab` / `onExternalTabDrop`。
@MainActor
final class UPaneGroupsTransferTests: XCTestCase {

    private func model() -> UPaneGroupsModel<TestPayload> { UPaneGroupsModel<TestPayload>() }

    func testDetachRemovesWithoutCallingTheRemovalHook() {
        let source = model()
        var removed: [UUID] = []
        source.onTabRemoved = { tab, _ in removed.append(tab.id) }
        let a = source.openTab { UPaneTab(payload: .scratch) }
        let b = source.openTab { UPaneTab(payload: .scratch) }

        let detached = source.detachTab(a)

        XCTAssertEqual(detached?.id, a)
        XCTAssertEqual(source.allTabs.map(\.id), [b])
        XCTAssertTrue(removed.isEmpty, "摘出去的标签没有被关掉，不能触发销毁钩子")
    }

    func testDetachingTheOnlyTabOfASplitGroupCollapsesItWithoutEmptyingTheArea() {
        let source = model()
        var emptied = false
        source.policy.allowsLastGroupEmpty = false
        source.onAreaEmptied = { emptied = true }
        let a = source.openTab { UPaneTab(payload: .scratch) }
        let first = source.activeGroupID!
        source.makeTabForNewGroup = { UPaneTab(payload: .scratch) }
        source.splitGroup(first)
        XCTAssertEqual(source.groupCount, 2)

        source.detachTab(a)

        XCTAssertEqual(source.groupCount, 1)
        XCTAssertEqual(source.allTabs.count, 1)
        XCTAssertFalse(emptied)
        source.detachTab(source.allTabs[0].id)
        XCTAssertFalse(emptied, "整片摘空由调用方处理，不走 onAreaEmptied")
    }

    func testDetachUnknownTabReturnsNil() {
        XCTAssertNil(model().detachTab(UUID()))
    }

    func testInsertAtCenterAppendsAndActivates() {
        let target = model()
        target.openTab { UPaneTab(payload: .scratch) }
        let moved = UPaneTab<TestPayload>(payload: .sql(seq: 1, doc: UUID()))

        target.insertTab(moved)

        XCTAssertEqual(target.groupCount, 1)
        XCTAssertEqual(target.activeTab?.id, moved.id)
    }

    func testInsertAtEdgeSplitsNextToTheTargetGroup() {
        let target = model()
        target.openTab { UPaneTab(payload: .scratch) }
        let anchor = target.activeGroupID!
        let moved = UPaneTab<TestPayload>(payload: .scratch)

        target.insertTab(moved, toGroup: anchor, zone: .leading)

        XCTAssertEqual(target.groupCount, 2)
        XCTAssertEqual(target.groupIDs.last, anchor, "leading 在目标组前面开新组")
        XCTAssertEqual(target.activeTab?.id, moved.id)
    }

    func testInsertIgnoresATabAlreadyInTheModel() {
        let target = model()
        let a = target.openTab { UPaneTab(payload: .scratch) }
        target.insertTab(target.tab(a)!, zone: .trailing)
        XCTAssertEqual(target.groupCount, 1)
        XCTAssertEqual(target.allTabs.count, 1)
    }

    func testMovingAnUnknownTabIsHandedToTheExternalDropHook() {
        let target = model()
        target.openTab { UPaneTab(payload: .scratch) }
        let group = target.activeGroupID!
        var seen: (UUID, UUID, PaneDropZone)?
        target.onExternalTabDrop = { id, gid, zone in
            seen = (id, gid, zone)
            return true
        }
        let foreign = UUID()

        target.moveTab(foreign, toGroup: group, zone: .bottom)

        XCTAssertEqual(seen?.0, foreign)
        XCTAssertEqual(seen?.1, group)
        XCTAssertEqual(seen?.2, .bottom)
        XCTAssertEqual(target.groupCount, 1, "模型自己不动，交给 app")
    }

    func testSplitForZoneMapping() {
        let cases: [(PaneDropZone, SplitDirection, Bool)] = [
            (.leading, .horizontal, true), (.trailing, .horizontal, false),
            (.top, .vertical, true), (.bottom, .vertical, false),
        ]
        for (zone, direction, first) in cases {
            let got = UPaneGroupsModel<TestPayload>.split(for: zone)
            XCTAssertEqual(got.0, direction, "\(zone)")
            XCTAssertEqual(got.newLeafFirst, first, "\(zone)")
        }
    }
}
