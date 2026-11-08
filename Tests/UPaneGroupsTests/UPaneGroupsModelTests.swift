import XCTest
import UPaneTree
@testable import UPaneGroups

/// 载荷形状照着 uTable 的 `UTab.Kind` 取：带关联值的枚举，其中一个 case 携带
/// 指向后端文档的 id —— 泛型 `@Observable` 的可行性也是用这个形状验的。
enum TestPayload: Equatable, Sendable {
    case table(String, doc: UUID)
    case sql(seq: Int, doc: UUID)
    case scratch
}

@MainActor
private func makeModel(policy: UPaneGroupsPolicy = .init()) -> UPaneGroupsModel<TestPayload> {
    UPaneGroupsModel<TestPayload>(policy: policy)
}

@MainActor
private func tab(_ name: String, doc: UUID = UUID()) -> UPaneTab<TestPayload> {
    UPaneTab(payload: .table(name, doc: doc))
}

// MARK: - 开 / 去重 / 预览标签

final class UPaneGroupsOpenTests: XCTestCase {

    @MainActor
    func testInitStartsWithOneEmptyActiveGroup() {
        let model = makeModel()
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertNotNil(model.activeGroupID)
        XCTAssertEqual(model.activeGroupID, model.root.firstLeafID)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.activeTab)
    }

    @MainActor
    func testOpenTabAppendsAndActivates() {
        let model = makeModel()
        let a = model.openTab { tab("users") }
        let b = model.openTab { tab("orders") }
        XCTAssertEqual(model.activeGroup?.tabs.count, 2)
        XCTAssertEqual(model.activeTab?.id, b)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(model.allTabs.count, 2)
    }

    @MainActor
    func testOpenTabDedupeFocusesExistingAndKeepsItsDocument() {
        let model = makeModel()
        let doc = UUID()
        let first = model.openTab { tab("users", doc: doc) }
        model.openTab { tab("orders") }
        // 重开已有表 → 聚焦已有标签、不新增、文档不变。
        let again = model.openTab({ tab("users") },
                                  dedupe: { if case .table(let n, _) = $0.payload { return n == "users" } else { return false } })
        XCTAssertEqual(again, first)
        XCTAssertEqual(model.activeGroup?.tabs.count, 2)
        XCTAssertEqual(model.activeGroup?.activeIndex, 0)
        XCTAssertEqual(model.activeTab?.payload, .table("users", doc: doc),
                       "同组重复打开必须聚焦原标签并保留原文档")
    }

    @MainActor
    func testDedupeIsScopedToTheTargetGroupOnly() {
        let model = makeModel()
        let doc1 = UUID()
        model.openTab { tab("users", doc: doc1) }
        let source = try! XCTUnwrap(model.activeGroupID)
        model.splitGroup(source)
        let second = try! XCTUnwrap(model.activeGroupID)
        XCTAssertNotEqual(source, second)

        let doc2 = UUID()
        let opened = model.openTab({ tab("users", doc: doc2) },
                                   dedupe: { if case .table(let n, _) = $0.payload { return n == "users" } else { return false } })
        // 另一组里已有同名标签，但去重只看本组 —— 两个组各自拥有自己的文档。
        XCTAssertEqual(model.groups[second]?.tabs.count, 1)
        XCTAssertEqual(model.groups[second]?.tabs.first?.id, opened)
        XCTAssertEqual(model.groups[second]?.tabs.first?.payload, .table("users", doc: doc2))
        XCTAssertEqual(model.groups[source]?.tabs.first?.payload, .table("users", doc: doc1))
    }

    @MainActor
    func testTransientTabReplacesTheGroupsExistingTransientSlot() {
        let model = makeModel()
        model.openTab { tab("pinned") }
        let firstPreview = model.openTab({ tab("a") }, asTransient: true)
        XCTAssertEqual(model.activeGroup?.tabs.count, 2)
        let secondPreview = model.openTab({ tab("b") }, asTransient: true)
        // 同组至多一个 transient：第二次单击顶替第一次，不新增。
        XCTAssertEqual(model.activeGroup?.tabs.count, 2)
        XCTAssertEqual(model.activeGroup?.tabs.filter(\.isTransient).count, 1)
        XCTAssertEqual(model.activeTab?.id, secondPreview)
        XCTAssertNil(model.tab(firstPreview))
        XCTAssertEqual(model.activeGroup?.tabs[0].isTransient, false)
    }

    @MainActor
    func testPromoteTransientKeepsTabAndClearsTheSlot() {
        let model = makeModel()
        let preview = model.openTab({ tab("a") }, asTransient: true)
        model.promoteTransient(preview)
        XCTAssertEqual(model.tab(preview)?.isTransient, false)
        // 转正之后再单击别的文件不该顶掉它。
        model.openTab({ tab("b") }, asTransient: true)
        XCTAssertEqual(model.activeGroup?.tabs.count, 2)
    }

    @MainActor
    func testDedupeHitOnATransientTabPromotesItWhenOpenedForReal() {
        let model = makeModel()
        let preview = model.openTab({ tab("a") }, asTransient: true)
        let again = model.openTab({ tab("a") },
                                  dedupe: { if case .table(let n, _) = $0.payload { return n == "a" } else { return false } })
        XCTAssertEqual(again, preview)
        XCTAssertEqual(model.tab(preview)?.isTransient, false)
    }

    @MainActor
    func testOpenTabInExplicitGroup() {
        let model = makeModel()
        let first = try! XCTUnwrap(model.activeGroupID)
        model.splitGroup(first)
        let second = try! XCTUnwrap(model.activeGroupID)
        model.openTab({ tab("x") }, in: first)
        XCTAssertEqual(model.groups[first]?.tabs.count, 1)
        XCTAssertEqual(model.groups[second]?.tabs.count, 0)
        XCTAssertEqual(model.activeGroupID, first, "往哪个组开就聚焦哪个组")
    }
}

// MARK: - 活动态

final class UPaneTabActivityTests: XCTestCase {

    @MainActor
    func testOnlyOneTabIsActiveAcrossTheWholeArea() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { tab("b") }

        XCTAssertEqual(model.tabActivity(groupID: g2, index: 0), .active)
        XCTAssertEqual(model.tabActivity(groupID: g1, index: 0), .frontUnfocused)

        model.focusGroup(g1)
        XCTAssertEqual(model.tabActivity(groupID: g1, index: 0), .active)
        XCTAssertEqual(model.tabActivity(groupID: g2, index: 0), .frontUnfocused)

        let actives = model.groupIDs.flatMap { gid in
            (model.groups[gid]?.tabs.indices ?? (0..<0)).map { model.tabActivity(groupID: gid, index: $0) }
        }.filter { $0 == .active }
        XCTAssertEqual(actives.count, 1, "全区域同时只能有一个 .active")
    }

    @MainActor
    func testBackgroundTabsStayInactive() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        model.openTab { tab("b") }
        let gid = try XCTUnwrap(model.activeGroupID)
        XCTAssertEqual(model.tabActivity(groupID: gid, index: 0), .inactive)
        XCTAssertEqual(model.tabActivity(groupID: gid, index: 1), .active)
    }

    @MainActor
    func testActivateTabSkipsNoOpWrites() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        model.openTab { tab("b") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.activateTab(groupID: gid, index: 0)
        XCTAssertEqual(model.activeGroup?.activeIndex, 0)
        // 越界不动。
        model.activateTab(groupID: gid, index: 9)
        XCTAssertEqual(model.activeGroup?.activeIndex, 0)
    }
}

// MARK: - 关 / 塌缩 / 垃圾回收

final class UPaneGroupsCloseTests: XCTestCase {

    @MainActor
    func testAdjustedActiveIndex() {
        typealias M = UPaneGroupsModel<TestPayload>
        // 关的是前面的标签 → 前台标签整体左移一格。
        XCTAssertEqual(M.adjustedActiveIndex(2, removedAt: 0, newCount: 3), 1)
        // 关的是自己 → 停在同一个下标，越界则退到最后一个。
        XCTAssertEqual(M.adjustedActiveIndex(1, removedAt: 1, newCount: 3), 1)
        XCTAssertEqual(M.adjustedActiveIndex(2, removedAt: 2, newCount: 2), 1)
        // 关的是后面的标签 → 不动。
        XCTAssertEqual(M.adjustedActiveIndex(0, removedAt: 2, newCount: 2), 0)
        // 关光了 → 0（不能是 -1）。
        XCTAssertEqual(M.adjustedActiveIndex(0, removedAt: 0, newCount: 0), 0)
    }

    @MainActor
    func testCloseLastTabKeepsTheSoleGroupAsPlaceholder() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.closeTab(groupID: gid, index: 0)
        XCTAssertEqual(model.groupCount, 1, "唯一的组要留下来显示空态")
        XCTAssertEqual(model.groups[gid]?.tabs.count, 0)
        XCTAssertEqual(model.activeGroupID, gid)
        XCTAssertTrue(model.isEmpty)
    }

    @MainActor
    func testCloseTabCollapsesTheEmptiedGroup() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { tab("b") }
        XCTAssertEqual(model.groupCount, 2)

        model.closeTab(groupID: g2, index: 0)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertNil(model.groups[g2])
        XCTAssertEqual(model.activeGroupID, g1, "塌缩后活动组回落到还在的那一个")
        XCTAssertEqual(model.root, .leaf(paneID: g1))
    }

    @MainActor
    func testCollapsesEmptyGroupsFalseKeepsTheEmptyGroup() throws {
        let model = makeModel(policy: .init(collapsesEmptyGroups: false))
        model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { tab("b") }
        model.closeTab(groupID: g2, index: 0)
        XCTAssertEqual(model.groupCount, 2, "策略关掉塌缩 → 空组留在树上")
        XCTAssertEqual(model.groups[g2]?.tabs.count, 0)
    }

    @MainActor
    func testOnTabRemovedReceivesRemainingTabs() throws {
        let model = makeModel()
        final class Box: @unchecked Sendable { var calls: [(UUID, [UUID])] = [] }
        let box = Box()
        model.onTabRemoved = { removed, remaining in
            box.calls.append((removed.id, remaining.map(\.id)))
        }
        let a = model.openTab { tab("a") }
        let b = model.openTab { tab("b") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.closeTab(groupID: gid, index: 0)
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls[0].0, a)
        XCTAssertEqual(box.calls[0].1, [b], "remaining 是关掉之后还剩的全部标签")
    }

    @MainActor
    func testGarbageCollectShapeSharedDocumentIsKeptUntilTheLastReferenceGoes() throws {
        // uTable `garbageCollect` 的形状：同一份文档被两个组的标签引用，
        // 关掉其中一个不该释放文档。
        let model = makeModel()
        final class Box: @unchecked Sendable { var closedDocs: [UUID] = [] }
        let box = Box()
        model.onTabRemoved = { removed, remaining in
            guard case .table(_, let doc) = removed.payload else { return }
            let stillUsed = remaining.contains {
                if case .table(_, let other) = $0.payload { return other == doc }
                return false
            }
            if !stillUsed { box.closedDocs.append(doc) }
        }
        let doc = UUID()
        model.openTab { UPaneTab(payload: .table("users", doc: doc)) }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { UPaneTab(payload: .table("users", doc: doc)) }

        model.closeTab(groupID: g2, index: 0)
        XCTAssertTrue(box.closedDocs.isEmpty, "还有别的标签引用同一份文档 → 不释放")
        model.closeTab(groupID: g1, index: 0)
        XCTAssertEqual(box.closedDocs, [doc])
    }

    @MainActor
    func testCloseActiveTabClosesTheEmptySplitGroup() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)                       // 分屏按钮开的是空组
        let g2 = try XCTUnwrap(model.activeGroupID)
        XCTAssertEqual(model.groups[g2]?.tabs.count, 0)
        XCTAssertTrue(model.closeActiveTab(), "⌘W 打在空组上应把这个组收掉")
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertNil(model.groups[g2])
    }

    @MainActor
    func testCloseActiveTabReturnsFalseWhenNothingToClose() {
        let model = makeModel()
        XCTAssertFalse(model.closeActiveTab(), "唯一的空组没东西可关 → 交给调用方关窗口")
        XCTAssertEqual(model.groupCount, 1)
    }

    @MainActor
    func testCloseEmptyGroupKeepsTheLastGroup() throws {
        let model = makeModel()
        let gid = try XCTUnwrap(model.activeGroupID)
        XCTAssertFalse(model.closeEmptyGroup(groupID: gid))
        XCTAssertEqual(model.groupCount, 1)
        // 非空组也不许走这条。
        model.openTab { tab("a") }
        model.splitGroup(gid)
        let other = try XCTUnwrap(model.activeGroupID)
        XCTAssertFalse(model.closeEmptyGroup(groupID: gid))
        XCTAssertTrue(model.closeEmptyGroup(groupID: other))
    }

    @MainActor
    func testCloseTabsWherePredicateSweepsEveryGroup() throws {
        let model = makeModel()
        model.openTab { tab("users") }
        model.openTab { tab("orders") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        model.openTab { tab("users") }
        model.openTab { tab("logs") }

        model.closeTabs { if case .table(let n, _) = $0.payload { return n == "users" } else { return false } }
        let names = model.allTabs.compactMap { t -> String? in
            if case .table(let n, _) = t.payload { return n } else { return nil }
        }
        XCTAssertEqual(Set(names), ["orders", "logs"])
    }

    @MainActor
    func testAreaEmptiedHookFiresWhenLastGroupMayNotBeEmpty() throws {
        let model = makeModel(policy: .init(allowsLastGroupEmpty: false))
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        model.onAreaEmptied = { box.count += 1 }
        model.openTab { tab("a") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.closeTab(groupID: gid, index: 0)
        XCTAssertEqual(box.count, 1)
    }
}

// MARK: - 分屏 / 布局

final class UPaneGroupsLayoutTests: XCTestCase {

    @MainActor
    func testSplitGroupOpensAnEmptyGroupByDefault() throws {
        let model = makeModel()
        model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        XCTAssertEqual(model.groupCount, 2)
        let g2 = try XCTUnwrap(model.activeGroupID)
        XCTAssertNotEqual(g1, g2)
        XCTAssertEqual(model.groups[g2]?.tabs.count, 0,
                       "默认开空组 —— 克隆当前标签是大表分屏卡顿的一半来源")
        // 默认横向：新叶子在第二位（右边）。
        guard case .split(let s) = model.root else { return XCTFail("expected a split") }
        XCTAssertEqual(s.direction, .horizontal)
        XCTAssertEqual(s.first, .leaf(paneID: g1))
        XCTAssertEqual(s.second, .leaf(paneID: g2))
    }

    @MainActor
    func testSplitGroupSeedsTheNewGroupWhenAsked() throws {
        let model = makeModel()
        model.makeTabForNewGroup = { UPaneTab(payload: .scratch) }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1, direction: .vertical, newLeafFirst: true)
        let g2 = try XCTUnwrap(model.activeGroupID)
        XCTAssertEqual(model.groups[g2]?.tabs.count, 1)
        XCTAssertEqual(model.groups[g2]?.tabs.first?.payload, .scratch)
        guard case .split(let s) = model.root else { return XCTFail("expected a split") }
        XCTAssertEqual(s.direction, .vertical)
        XCTAssertEqual(s.first, .leaf(paneID: g2), "newLeafFirst → 新组在上/左")
    }

    @MainActor
    func testSplitButtonCapAppliesToTheButtonOnly() throws {
        let model = makeModel(policy: .init(splitButtonMaxGroups: 3))
        var gid = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(gid)
        gid = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(gid)
        XCTAssertEqual(model.groupCount, 3)
        gid = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(gid)
        XCTAssertEqual(model.groupCount, 3, "按钮/快捷键封顶 3 组")

        // 拖拽分屏不受限。
        let target = try XCTUnwrap(model.groupIDs.first)
        model.openTab({ tab("a") }, in: target)
        model.openTab({ tab("b") }, in: target)
        let moving = try XCTUnwrap(model.groups[target]?.tabs.last?.id)
        model.moveTab(moving, toGroup: target, zone: .trailing)
        XCTAssertEqual(model.groupCount, 4, "拖拽分屏不受 splitButtonMaxGroups 限制")
    }

    @MainActor
    func testSetFraction() throws {
        let model = makeModel()
        let gid = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(gid)
        guard case .split(let s) = model.root else { return XCTFail("expected a split") }
        model.setFraction(0.7, splitID: s.id)
        guard case .split(let after) = model.root else { return XCTFail("expected a split") }
        XCTAssertEqual(after.fraction, 0.7, accuracy: 0.0001)
    }

    @MainActor
    func testFocusGroupIgnoresUnknownIDs() throws {
        let model = makeModel()
        let gid = try XCTUnwrap(model.activeGroupID)
        model.focusGroup(UUID())
        XCTAssertEqual(model.activeGroupID, gid)
    }

    @MainActor
    func testResetRebuildsASingleEmptyGroup() throws {
        let model = makeModel()
        model.onTabRemoved = { _, _ in XCTFail("reset 是换作用域，不该走逐个关标签的钩子") }
        model.openTab { tab("a") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(gid)
        model.reset()
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.activeGroupID, model.root.firstLeafID)
    }
}

// MARK: - 拖拽：moveTab / reorderTab

final class UPaneGroupsDragModelTests: XCTestCase {

    @MainActor
    func testMoveTabToEdgeSplitsTarget() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        model.openTab { tab("b") }
        let g1 = try XCTUnwrap(model.activeGroupID)

        model.moveTab(a, toGroup: g1, zone: .trailing)
        XCTAssertEqual(model.groupCount, 2)
        let g2 = try XCTUnwrap(model.activeGroupID)
        XCTAssertEqual(model.groups[g2]?.tabs.count, 1)
        XCTAssertEqual(model.groups[g2]?.tabs.first?.id, a)
        XCTAssertEqual(model.groups[g1]?.tabs.count, 1)
        guard case .split(let s) = model.root else { return XCTFail("expected a split") }
        XCTAssertEqual(s.direction, .horizontal)
        XCTAssertEqual(s.second, .leaf(paneID: g2))
    }

    @MainActor
    func testMoveTabLeadingAndTopPutTheNewGroupFirst() throws {
        for (zone, direction) in [(PaneDropZone.leading, SplitDirection.horizontal),
                                  (PaneDropZone.top, SplitDirection.vertical)] {
            let model = makeModel()
            let a = model.openTab { tab("a") }
            model.openTab { tab("b") }
            let g1 = try XCTUnwrap(model.activeGroupID)
            model.moveTab(a, toGroup: g1, zone: zone)
            let g2 = try XCTUnwrap(model.activeGroupID)
            guard case .split(let s) = model.root else { return XCTFail("expected a split") }
            XCTAssertEqual(s.direction, direction)
            XCTAssertEqual(s.first, .leaf(paneID: g2), "\(zone) → 新组排在前面")
        }
        // bottom 与 leading 的镜像。
        let model = makeModel()
        let a = model.openTab { tab("a") }
        model.openTab { tab("b") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.moveTab(a, toGroup: g1, zone: .bottom)
        let g2 = try XCTUnwrap(model.activeGroupID)
        guard case .split(let s) = model.root else { return XCTFail("expected a split") }
        XCTAssertEqual(s.direction, .vertical)
        XCTAssertEqual(s.second, .leaf(paneID: g2))
    }

    @MainActor
    func testMoveTabCenterMovesIntoGroupAndCollapsesSource() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { tab("b") }

        model.moveTab(a, toGroup: g2, zone: .center)
        XCTAssertEqual(model.groupCount, 1, "源组空掉 → 从树里塌缩")
        XCTAssertNil(model.groups[g1])
        XCTAssertEqual(model.groups[g2]?.tabs.count, 2)
        XCTAssertEqual(model.groups[g2]?.tabs.last?.id, a, "center = 追加到末尾")
        XCTAssertEqual(model.groups[g2]?.activeIndex, 1)
        XCTAssertEqual(model.activeGroupID, g2)
    }

    @MainActor
    func testMoveTabCenterIntoItsOwnGroupIsANoop() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        model.openTab { tab("b") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.moveTab(a, toGroup: g1, zone: .center)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups[g1]?.tabs.map(\.id).first, a, "顺序没动")
        XCTAssertEqual(model.groups[g1]?.tabs.count, 2)
    }

    @MainActor
    func testSoleTabOntoItsOwnEdgeClonesWhenACloneHookExists() throws {
        let model = makeModel()
        model.cloneTab = { source in
            guard case .table(let name, _) = source.payload else { return nil }
            // uTable 的语义：克隆时铸一份新文档 id。
            return UPaneTab(payload: .table(name, doc: UUID()), customTitle: source.customTitle)
        }
        let doc = UUID()
        let a = model.openTab { UPaneTab(payload: .table("users", doc: doc)) }
        let g1 = try XCTUnwrap(model.activeGroupID)

        model.moveTab(a, toGroup: g1, zone: .trailing)
        XCTAssertEqual(model.groupCount, 2, "真移动会让源组塌缩、分完还是一个组 → 改克隆")
        XCTAssertEqual(model.groups[g1]?.tabs.first?.id, a, "源标签留在原地")
        let g2 = try XCTUnwrap(model.activeGroupID)
        let cloned = try XCTUnwrap(model.groups[g2]?.tabs.first)
        XCTAssertNotEqual(cloned.id, a)
        guard case .table(let name, let clonedDoc) = cloned.payload else { return XCTFail("bad payload") }
        XCTAssertEqual(name, "users")
        XCTAssertNotEqual(clonedDoc, doc, "克隆铸新文档，不共用原来那份")
    }

    @MainActor
    func testSoleTabOntoItsOwnEdgeIsANoopWithoutACloneHook() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.moveTab(a, toGroup: g1, zone: .trailing)
        XCTAssertEqual(model.groupCount, 1, "cloneTab 缺席 = 拒绝克隆 → 整次拖拽无操作")
        XCTAssertEqual(model.groups[g1]?.tabs.count, 1)
    }

    @MainActor
    func testMoveTabIgnoresUnknownTargetsAndTabs() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.moveTab(a, toGroup: UUID(), zone: .center)
        model.moveTab(UUID(), toGroup: g1, zone: .trailing)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups[g1]?.tabs.count, 1)
    }

    @MainActor
    func testReorderWithinGroupCorrectsTheInsertionIndex() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let b = model.openTab { tab("b") }
        let c = model.openTab { tab("c") }
        let gid = try XCTUnwrap(model.activeGroupID)

        // a 从 0 拖到 c(2) 的槽位：摘除后目标前移一格 → 落在 1。
        model.reorderTab(a, before: c)
        XCTAssertEqual(model.groups[gid]?.tabs.map(\.id), [b, a, c])
        XCTAssertEqual(model.groups[gid]?.activeIndex, 1, "重排后前台跟着被拖的标签走")

        // 从后往前拖不做修正。
        model.reorderTab(c, before: b)
        XCTAssertEqual(model.groups[gid]?.tabs.map(\.id), [c, b, a])
        XCTAssertEqual(model.groups[gid]?.activeIndex, 0)
    }

    @MainActor
    func testReorderAcrossGroupsCollapsesTheEmptiedSource() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        let b = model.openTab { tab("b") }

        model.reorderTab(a, before: b)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertNil(model.groups[g1])
        XCTAssertEqual(model.groups[g2]?.tabs.map(\.id), [a, b])
        XCTAssertEqual(model.groups[g2]?.activeIndex, 0)
        XCTAssertEqual(model.activeGroupID, g2)
    }

    @MainActor
    func testMoveTabToEndWithinGroupNeverSplits() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let b = model.openTab { tab("b") }
        let c = model.openTab { tab("c") }
        let gid = try XCTUnwrap(model.activeGroupID)

        // 标签条空白处松手：挪到末尾，不分屏。
        model.moveTabToEnd(a, ofGroup: gid)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups[gid]?.tabs.map(\.id), [b, c, a])
        XCTAssertEqual(model.groups[gid]?.activeIndex, 2)

        // 已在末尾：位置不变。
        model.moveTabToEnd(a, ofGroup: gid)
        XCTAssertEqual(model.groups[gid]?.tabs.map(\.id), [b, c, a])
        XCTAssertEqual(model.groupCount, 1)
    }

    @MainActor
    func testMoveTabToEndOfAnotherGroupMerges() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        let b = model.openTab { tab("b") }

        model.moveTabToEnd(a, ofGroup: g2)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(model.groups[g2]?.tabs.map(\.id), [b, a])
        XCTAssertEqual(model.activeGroupID, g2)
    }

    @MainActor
    func testReorderOntoItselfIsANoop() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.reorderTab(a, before: a)
        XCTAssertEqual(model.groups[gid]?.tabs.count, 1)
    }

    @MainActor
    func testLocateTab() throws {
        let model = makeModel()
        let a = model.openTab { tab("a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        let b = model.openTab { tab("b") }
        XCTAssertEqual(model.locateTab(a)?.groupID, g1)
        XCTAssertEqual(model.locateTab(a)?.index, 0)
        XCTAssertEqual(model.locateTab(b)?.groupID, g2)
        XCTAssertNil(model.locateTab(UUID()))
    }
}
