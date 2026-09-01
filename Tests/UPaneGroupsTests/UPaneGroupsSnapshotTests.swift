import XCTest
import UPaneTree
@testable import UPaneGroups

/// 存盘用的降维载荷。形状对齐设计文档 §4.2 的 `TerminalTabSnapshot`。
private struct TabSnap: Codable, Sendable, Equatable {
    var name: String
    var serverID: UUID
}

@MainActor
private func snapshotModel() -> UPaneGroupsModel<TestPayload> { UPaneGroupsModel<TestPayload>() }

private func encode(_ tab: UPaneTab<TestPayload>) -> TabSnap? {
    guard case .table(let name, let doc) = tab.payload else { return nil }
    return TabSnap(name: name, serverID: doc)
}

private func decode(_ snap: TabSnap) -> UPaneTab<TestPayload>? {
    UPaneTab(payload: .table(snap.name, doc: snap.serverID))
}

final class UPaneGroupsSnapshotTests: XCTestCase {

    @MainActor
    func testRoundTripPreservesShapeTabsAndFractions() throws {
        let model = snapshotModel()
        model.openTab { UPaneTab(payload: .table("a", doc: UUID())) }
        model.openTab { UPaneTab(payload: .table("b", doc: UUID())) }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.activateTab(groupID: g1, index: 0)
        model.splitGroup(g1, direction: .vertical)
        model.openTab { UPaneTab(payload: .table("c", doc: UUID())) }
        guard case .split(let split) = model.root else { return XCTFail("expected a split") }
        model.setFraction(0.3, splitID: split.id)

        let snap = model.snapshot(encode)
        XCTAssertEqual(snap.groups.count, 2)
        XCTAssertEqual(snap.groups[0].tabs.map(\.name), ["a", "b"])
        XCTAssertEqual(snap.groups[0].activeIndex, 0)
        XCTAssertEqual(snap.groups[1].tabs.map(\.name), ["c"])
        XCTAssertEqual(snap.activeGroupIndex, 1)

        // 经过 JSON 一圈也不掉东西。
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(UPaneGroupsSnapshot<TabSnap>.self, from: data)

        let restored = snapshotModel()
        restored.restore(decoded, make: decode)
        XCTAssertEqual(restored.groupCount, 2)
        guard case .split(let rebuilt) = restored.root else { return XCTFail("expected a split") }
        XCTAssertEqual(rebuilt.direction, .vertical)
        XCTAssertEqual(rebuilt.fraction, 0.3, accuracy: 0.0001)
        XCTAssertNotEqual(rebuilt.id, split.id, "分屏节点 id 重新铸造，不沿用快照里的")

        let names = restored.groupIDs.map { gid in restored.groups[gid]!.tabs.compactMap { t -> String? in
            if case .table(let n, _) = t.payload { return n } else { return nil } } }
        XCTAssertEqual(names, [["a", "b"], ["c"]])
        XCTAssertEqual(restored.activeGroup?.tabs.first.map { t -> String in
            if case .table(let n, _) = t.payload { return n } else { return "" } }, "c")
    }

    @MainActor
    func testEncodeReturningNilDropsTabsGroupsAndCollapsesSplits() throws {
        let model = snapshotModel()
        // g1: 一个可存的标签；g2: 全是不可存的标签 → 整组丢掉，split 也随之塌缩。
        model.openTab { UPaneTab(payload: .table("keep", doc: UUID())) }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        model.openTab { UPaneTab(payload: .scratch) }
        model.openTab { UPaneTab(payload: .sql(seq: 1, doc: UUID())) }

        let snap = model.snapshot(encode)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups[0].tabs.map(\.name), ["keep"])
        guard case .leaf(let idx) = snap.root else { return XCTFail("split 的一侧丢光 → 另一侧上提") }
        XCTAssertEqual(idx, 0)
        XCTAssertNil(snap.activeGroupIndex, "活动组被丢掉 → 不给它回落一个错的下标")
    }

    @MainActor
    func testActiveIndexRemapsWhenTheFrontTabIsDropped() throws {
        let model = snapshotModel()
        model.openTab { UPaneTab(payload: .table("a", doc: UUID())) }
        model.openTab { UPaneTab(payload: .scratch) }   // 前台，且不可存
        let snap = model.snapshot(encode)
        XCTAssertEqual(snap.groups[0].tabs.map(\.name), ["a"])
        XCTAssertEqual(snap.groups[0].activeIndex, 0, "前台被丢 → 退到它前面最近的幸存标签")
    }

    @MainActor
    func testAnOriginallyEmptyGroupSurvivesTheSnapshot() throws {
        let model = snapshotModel()
        model.openTab { UPaneTab(payload: .table("a", doc: UUID())) }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)                         // 空组，是用户有意留的布局
        let snap = model.snapshot(encode)
        XCTAssertEqual(snap.groups.count, 2)
        XCTAssertTrue(snap.groups[1].tabs.isEmpty)

        let restored = snapshotModel()
        restored.restore(snap, make: decode)
        XCTAssertEqual(restored.groupCount, 2)
    }

    @MainActor
    func testRestoreDropsUnknownEntriesAndPrunesTheTree() throws {
        // uTerm 的 `pruningUnknownServers`：指向不存在服务器的标签丢掉，
        // 标签被丢光的组丢掉，组被丢光则整棵树丢掉。
        let known = UUID()
        let snap = UPaneGroupsSnapshot<TabSnap>(
            root: .split(direction: .horizontal, fraction: 0.5,
                         first: .leaf(groupIndex: 0), second: .leaf(groupIndex: 1)),
            groups: [
                .init(tabs: [TabSnap(name: "gone", serverID: UUID())], activeIndex: 0),
                .init(tabs: [TabSnap(name: "kept", serverID: known)], activeIndex: 0),
            ],
            activeGroupIndex: 0)

        let model = snapshotModel()
        model.restore(snap) { $0.serverID == known ? decode($0) : nil }
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.allTabs.count, 1)
        XCTAssertEqual(model.activeGroupID, model.root.firstLeafID,
                       "活动组被剪掉 → 回落到第一个叶子，绝不铸一个不存在的 id")
    }

    @MainActor
    func testRestoreOfAFullyPrunedSnapshotFallsBackToOneEmptyGroup() throws {
        let snap = UPaneGroupsSnapshot<TabSnap>(
            root: .leaf(groupIndex: 0),
            groups: [.init(tabs: [TabSnap(name: "gone", serverID: UUID())], activeIndex: 0)],
            activeGroupIndex: 0)
        let model = snapshotModel()
        model.openTab { UPaneTab(payload: .table("stale", doc: UUID())) }
        model.restore(snap) { _ in nil }
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.activeGroupID, model.root.firstLeafID)
    }

    @MainActor
    func testSnapshotOfAFullyDroppedModelIsTheEmptySnapshot() throws {
        let model = snapshotModel()
        model.openTab { UPaneTab(payload: .scratch) }
        let snap = model.snapshot(encode)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertTrue(snap.groups[0].tabs.isEmpty)
        guard case .leaf(let idx) = snap.root else { return XCTFail("expected a leaf") }
        XCTAssertEqual(idx, 0)
    }

    @MainActor
    func testRestoreIgnoresGroupsTheTreeNeverReferences() throws {
        let snap = UPaneGroupsSnapshot<TabSnap>(
            root: .leaf(groupIndex: 0),
            groups: [
                .init(tabs: [TabSnap(name: "a", serverID: UUID())], activeIndex: 0),
                .init(tabs: [TabSnap(name: "orphan", serverID: UUID())], activeIndex: 0),
            ],
            activeGroupIndex: 1)
        let model = snapshotModel()
        model.restore(snap, make: decode)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.allTabs.count, 1)
        XCTAssertEqual(model.activeGroupID, model.root.firstLeafID)
    }
}

// MARK: - 条件 Equatable

/// 快照要能直接进 `.onChange(of:)`。这些用例钉住的是**合成的** `==` 覆盖到每个字段 ——
/// 消费方（uTerm）原先手写 `==`，漏字段就等于那一类改动静默不再写盘。
final class UPaneGroupsSnapshotEquatableTests: XCTestCase {
    private typealias Snap = UPaneGroupsSnapshot<String>

    private func twoGroupSnapshot(fraction: Double) -> Snap {
        Snap(root: .split(direction: .horizontal, fraction: fraction,
                          first: .leaf(groupIndex: 0), second: .leaf(groupIndex: 1)),
             groups: [Snap.Group(tabs: ["a"], activeIndex: 0),
                      Snap.Group(tabs: ["b", "c"], activeIndex: 1)],
             activeGroupIndex: 0)
    }

    /// 真实回归场景：只拖分隔条。除了组树里的 `fraction`，没有任何别的字段会动 ——
    /// 手写 `==` 漏掉组树时，这类改动永远存不下来。
    func testFractionOnlyChangeIsNotEqual() {
        XCTAssertNotEqual(twoGroupSnapshot(fraction: 0.5), twoGroupSnapshot(fraction: 0.62))
    }

    func testIdenticalSnapshotsAreEqual() {
        XCTAssertEqual(twoGroupSnapshot(fraction: 0.5), twoGroupSnapshot(fraction: 0.5))
    }

    func testEachFieldParticipatesInEquality() {
        let base = twoGroupSnapshot(fraction: 0.5)

        var activeGroup = base
        activeGroup.activeGroupIndex = 1
        XCTAssertNotEqual(base, activeGroup, "activeGroupIndex 必须参与比较")

        var tabs = base
        tabs.groups[1].tabs = ["b", "c", "d"]
        XCTAssertNotEqual(base, tabs, "组内标签必须参与比较")

        var activeIndex = base
        activeIndex.groups[1].activeIndex = 0
        XCTAssertNotEqual(base, activeIndex, "组内 activeIndex 必须参与比较")

        var direction = base
        direction.root = .split(direction: .vertical, fraction: 0.5,
                                first: .leaf(groupIndex: 0), second: .leaf(groupIndex: 1))
        XCTAssertNotEqual(base, direction, "分屏方向必须参与比较")

        var shape = base
        shape.root = .leaf(groupIndex: 0)
        XCTAssertNotEqual(base, shape, "组树形状必须参与比较")
    }
}
