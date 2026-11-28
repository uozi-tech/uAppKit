#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import UAppKitBridge
@testable import UPaneGroups

/// 视图层能测的那部分：**拍平挂载**这条硬约束是可观测的 —— 把面板内容做成一个
/// `NSViewRepresentable` 标记视图，就能数出「哪些标签真的挂在树上」，以及「分屏 /
/// 换组之后那个 NSView 还是不是同一个实例」。后者正是 §3.1 的全部意义：
/// 递归渲染时这些操作会改变面板在视图树里的路径，SwiftUI 只能拆掉重建
/// （uTable 实测重建一个 30 列 × 100 行的数据网格 ≈350ms、拆掉 ≈180ms）；
/// 摊平之后身份只由 `tab.id` 决定，操作只是改 frame。
///
/// 测不了的：真实拖拽会话（要真的按住鼠标走 AppKit 拖拽循环；起拖与落点两头各自的
/// 测法见 `UPaneTabDragSourceTests`）、`onPointerDown` 的 NSEvent 本地监视器（要真实鼠标事件；这条前提
/// 已由 `UAppKitBridgeTests` 钉住）、以及颜色 / 排版的观感。
@MainActor
final class UPaneGroupAreaViewTests: XCTestCase {

    // MARK: 标记视图

    final class MarkerView: NSView {
        let tabID: UUID
        init(tabID: UUID) {
            self.tabID = tabID
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }

    struct Marker: NSViewRepresentable {
        let tabID: UUID
        func makeNSView(context: Context) -> MarkerView { MarkerView(tabID: tabID) }
        func updateNSView(_ nsView: MarkerView, context: Context) {}
    }

    private func markers(in view: NSView) -> [MarkerView] {
        (view as? MarkerView).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }

    // MARK: 宿主

    /// 宿主必须真的进窗口并转过 runloop —— 否则 `NSViewRepresentable` 的 NSView
    /// 还没建出来，断言就是空的。
    private func host<V: View>(_ view: V) -> (window: NSWindow, host: NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (window, host)
    }

    private func settle(_ host: NSView, _ window: NSWindow) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func area(_ model: UPaneGroupsModel<TestPayload>)
        -> UPaneGroupArea<TestPayload, Marker, Color, EmptyView, EmptyView> {
        UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { tab in
                UPaneTabDescriptor(title: tab.customTitle ?? "tab", icon: .system("doc"))
            },
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { tab in
                guard let at = model.locateTab(tab.id) else { return }
                model.closeTab(groupID: at.groupID, index: at.index)
            })
    }

    // MARK: 保活：每个标签只挂一次，非前台的也留在树上

    func testAllTabsKeepAliveMountsEveryTabExactlyOnce() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let c = model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        let mounted = markers(in: hostView)
        XCTAssertEqual(Set(mounted.map(\.tabID)), [a, b, c],
                       "非前台标签也必须留在树上 —— 切标签是纯透明度翻转，不是重建")
        XCTAssertEqual(mounted.count, 3, "每个标签的面板只出现一次，身份就是 tab.id")
    }

    func testActiveTabPerGroupMountsOnlyFrontTabs() throws {
        let model = UPaneGroupsModel<TestPayload>(policy: .init(keepAlive: .activeTabPerGroup))
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let c = model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        XCTAssertEqual(Set(markers(in: hostView).map(\.tabID)), [b, c],
                       ".activeTabPerGroup 每组只挂前台标签")
    }

    func testActiveGroupOnlyMountsOneTab() throws {
        let model = UPaneGroupsModel<TestPayload>(policy: .init(keepAlive: .activeGroupOnly))
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let c = model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        XCTAssertEqual(markers(in: hostView).map(\.tabID), [c])
    }

    // MARK: 拍平：分屏 / 换组只改 frame，不重建面板

    func testSplittingDoesNotRebuildTheMountedPane() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        let before = try XCTUnwrap(markers(in: hostView).first { $0.tabID == a })

        model.splitGroup(g1)
        settle(hostView, window)

        let after = try XCTUnwrap(markers(in: hostView).first { $0.tabID == a })
        XCTAssertTrue(before === after,
                      "分屏后面板必须还是同一个 NSView —— 重建一个数据网格 ≈350ms")
    }

    func testMovingATabToAnotherGroupDoesNotRebuildItsPane() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        let before = try XCTUnwrap(markers(in: hostView).first { $0.tabID == a })

        model.moveTab(a, toGroup: g2, zone: .center)
        settle(hostView, window)

        let after = try XCTUnwrap(markers(in: hostView).first { $0.tabID == a })
        XCTAssertTrue(before === after, "换组只该改 frame，不该重建面板")
        XCTAssertEqual(model.locateTab(a)?.groupID, g2)
    }

    func testCollapsingAGroupKeepsTheSurvivingPane() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        let before = try XCTUnwrap(markers(in: hostView).first { $0.tabID == a })

        model.closeTab(groupID: g2, index: 0)          // g2 空掉 → 塌缩
        settle(hostView, window)

        XCTAssertEqual(model.groupCount, 1)
        let remaining = markers(in: hostView)
        XCTAssertEqual(remaining.map(\.tabID), [a])
        XCTAssertFalse(remaining.contains { $0.tabID == b })
        XCTAssertTrue(before === remaining[0], "合屏也只是改 frame")
    }

    // MARK: 内容比面板宽：不许溢出到相邻组

    /// 800pt 宽的编辑区左右分屏，每组 ~400pt，面板内容最小宽 600pt。内容只能在
    /// 自己的面板里从左缘排起、超出部分被裁掉 —— 而不是把帧撑到 600 再居中，
    /// 左右各溢出 100pt 盖住邻组（uTable 窄分屏下数据网格工具栏 / 页脚的实况）。
    func testContentWiderThanItsPaneStaysInsideThePaneRect() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }

        let view = UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { tab, _ in Marker(tabID: tab.id).frame(minWidth: 600) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in })
        let (window, hostView) = host(view.frame(width: 800, height: 600))
        defer { window.contentView = nil }

        let frames = Dictionary(uniqueKeysWithValues: markers(in: hostView).map {
            ($0.tabID, $0.convert($0.bounds, to: nil))
        })
        let left = try XCTUnwrap(frames[a])
        let right = try XCTUnwrap(frames[b])
        XCTAssertEqual(left.width, 600, accuracy: 0.5, "内容保持自己的最小宽，靠裁剪而不是压扁")
        XCTAssertEqual(left.minX, 0, accuracy: 0.5,
                       "左组内容必须从面板左缘排起，不能居中后向左溢出：\(left)")
        // 右组面板从中线（± 分隔线几个点）开始。
        XCTAssertGreaterThanOrEqual(right.minX, 400 - 4,
                                    "右组内容越过中线盖到了左组上：\(right)")
    }

    // MARK: 空组与活动态门

    func testEmptyGroupPlaceholderIsShownAndNoPaneIsMounted() throws {
        let model = UPaneGroupsModel<TestPayload>()
        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        XCTAssertTrue(markers(in: hostView).isEmpty, "空组不该挂任何面板")
    }

    func testActivePaneGateIsInjectedAndFollowsTheActiveTab() throws {
        final class Seen: @unchecked Sendable {
            var gates: [UUID: ActivePaneGate] = [:]
        }
        let seen = Seen()

        struct Probe: View {
            let tabID: UUID
            let seen: Seen
            @Environment(\.activePaneGate) private var gate
            var body: some View {
                Color.clear.onAppear { if let gate { seen.gates[tabID] = gate } }
            }
        }

        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let gid = try XCTUnwrap(model.activeGroupID)

        let view = UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { tab, _ in Probe(tabID: tab.id, seen: seen) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in })
        let (window, hostView) = host(view)
        defer { window.contentView = nil }

        let gateA = try XCTUnwrap(seen.gates[a])
        let gateB = try XCTUnwrap(seen.gates[b])
        XCTAssertFalse(gateA === gateB, "每个面板一个身份稳定的 gate 对象")
        XCTAssertFalse(gateA.isActive)
        XCTAssertTrue(gateB.isActive, "b 是前台标签且它那一组是活动组")

        model.activateTab(groupID: gid, index: 0)
        settle(hostView, window)
        XCTAssertTrue(gateA.isActive)
        XCTAssertFalse(gateB.isActive)
        XCTAssertTrue(try XCTUnwrap(seen.gates[a]) === gateA,
                      "翻转的只是 @Observable 属性，gate 的身份不变 —— 传 Bool 会重建整棵子树")
    }

    // MARK: 标签栏几何

    func testStripHeightIncludesItsBottomSeparator() throws {
        let stripHeight: CGFloat = 36
        let pane = CGRect(x: 11, y: 13, width: 800, height: 600)
        let content = UPaneGroupGeometry.contentRect(in: pane, stripHeight: stripHeight)

        XCTAssertEqual(content.minY - pane.minY, stripHeight, accuracy: 0.001,
                       "底部分隔线必须画在 stripHeight 内，不能再把正文下推 1pt")
        XCTAssertEqual(content.height, pane.height - stripHeight, accuracy: 0.001)
        XCTAssertEqual(content.minX, pane.minX, accuracy: 0.001)
        XCTAssertEqual(content.width, pane.width, accuracy: 0.001)
    }

    // MARK: 四个初始化器（accessory / 右键菜单的有无组合）都要能构造出来

    func testAllInitialiserOverloadsBuildAndRender() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let d: (UPaneTab<TestPayload>) -> UPaneTabDescriptor = { _ in UPaneTabDescriptor(title: "t") }

        // ① 都没有（便捷版）
        let plain = UPaneGroupArea(
            model: model, dragType: .plainText, descriptor: d,
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear }, onRequestClose: { _ in })
        // ② 只有标签条右侧按钮
        let withAccessory = UPaneGroupArea(
            model: model, dragType: .plainText,
            splitButtonDirection: .automatic, descriptor: d,
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear }, onRequestClose: { _ in },
            stripAccessory: { _ in Image(systemName: "plus") })
        // ③ 只有右键菜单
        let withMenu = UPaneGroupArea(
            model: model, dragType: .plainText, descriptor: d,
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear }, onRequestClose: { _ in },
            tabMenu: { _ in Button("关闭其他") {} })
        // ④ 全都有 + 外来拖拽 + 切标签回调
        let full = UPaneGroupArea(
            model: model, dragType: .plainText, stripHeight: 36,
            showsSplitButton: false, splitButtonDirection: .vertical, descriptor: d,
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear }, onRequestClose: { _ in },
            stripAccessory: { _ in Image(systemName: "plus") },
            tabMenu: { _ in Button("关闭其他") {} },
            foreignDropTypes: [.fileURL],
            onForeignDrop: { _, _, _ in true },
            onActiveTabChanged: { _ in })

        for view in [AnyView(plain), AnyView(withAccessory), AnyView(withMenu), AnyView(full)] {
            let (window, hostView) = host(view)
            XCTAssertEqual(markers(in: hostView).count, 1)
            window.contentView = nil
        }
    }

    // MARK: 关闭是「请求」式

    func testCloseIsARequestTheModelIsNotTouchedByTheComponent() throws {
        final class Box: @unchecked Sendable { var requested: [UUID] = [] }
        let box = Box()
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }

        let view = UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { tab in box.requested.append(tab.id) })
        let (window, hostView) = host(view)
        defer { window.contentView = nil }
        _ = hostView

        // 组件里没有任何一条直接调 closeTab 的路径 —— 这里只钉住「模型没被动过」。
        XCTAssertEqual(model.allTabs.map(\.id), [a])
        XCTAssertTrue(box.requested.isEmpty)
    }

    // MARK: 切活动组不重求面板内容

    /// 点进另一组（只改 `activeGroupID`）不该把 app 的 `content` 再调一遍：区域 body 不读活动组，
    /// 面板的活动态由 `ActivePaneGateDriver` 单独观察。gate 照样跟着翻。
    func testFocusingAnotherGroupDoesNotReinvokeContent() throws {
        final class Calls: @unchecked Sendable { var content = 0 }
        let calls = Calls()
        final class Seen: @unchecked Sendable { var gates: [UUID: ActivePaneGate] = [:] }
        let seen = Seen()
        struct Probe: View {
            let tabID: UUID
            let seen: Seen
            @Environment(\.activePaneGate) private var gate
            var body: some View {
                Color.clear.onAppear { if let gate { seen.gates[tabID] = gate } }
            }
        }

        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let b = model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let g2 = try XCTUnwrap(model.activeGroupID)

        let view = UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { tab, _ in
                calls.content += 1
                return Probe(tabID: tab.id, seen: seen)
            },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in })
        let (window, hostView) = host(view)
        defer { window.contentView = nil }
        let gateA = try XCTUnwrap(seen.gates[a])
        let gateB = try XCTUnwrap(seen.gates[b])
        XCTAssertTrue(gateB.isActive)

        let before = calls.content
        model.focusGroup(g1)
        settle(hostView, window)
        XCTAssertEqual(calls.content, before, "切活动组把面板内容重求了 \(calls.content - before) 次")
        XCTAssertTrue(gateA.isActive, "gate 仍要跟着活动组翻")
        XCTAssertFalse(gateB.isActive)

        model.focusGroup(g2)
        settle(hostView, window)
        XCTAssertEqual(calls.content, before)
        XCTAssertFalse(gateA.isActive)
        XCTAssertTrue(gateB.isActive)
    }

    /// `.activeGroupOnly` 下 app 写进一个失效的 `activeGroupID`：按 `resolvedActiveGroupID`
    /// 回落到第一组，照样挂一个面板，而不是一个都不挂。
    func testActiveGroupOnlyWithAStaleActiveGroupStillMountsTheFirstGroup() throws {
        let model = UPaneGroupsModel<TestPayload>(policy: .init(keepAlive: .activeGroupOnly))
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }
        model.activeGroupID = UUID()

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }
        XCTAssertEqual(markers(in: hostView).map(\.tabID), [a])
    }

    // MARK: 切前台标签的回调

    private func areaReportingTabChanges(_ model: UPaneGroupsModel<TestPayload>,
                                         into log: TabChangeLog) -> some View {
        UPaneGroupArea(
            model: model,
            dragType: .plainText,
            descriptor: { _ in UPaneTabDescriptor(title: "t") },
            content: { tab, _ in Marker(tabID: tab.id) },
            emptyGroup: { _ in Color.clear },
            onRequestClose: { _ in },
            onActiveTabChanged: { log.groups.append($0) })
    }

    final class TabChangeLog: @unchecked Sendable { var groups: [UUID] = [] }

    /// 关掉不是最后一枚的前台标签：下标没变（还是 0），前台却换成了下一枚 —— 回调要发。
    func testClosingTheFrontTabReportsAChangeEvenWhenTheIndexStays() throws {
        let log = TabChangeLog()
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }
        let gid = try XCTUnwrap(model.activeGroupID)
        model.activateTab(groupID: gid, index: 0)

        let (window, hostView) = host(areaReportingTabChanges(model, into: log))
        defer { window.contentView = nil }
        XCTAssertEqual(log.groups, [])

        model.closeTab(groupID: gid, index: 0)
        settle(hostView, window)
        XCTAssertEqual(model.groups[gid]?.activeIndex, 0, "前提：下标没变")
        XCTAssertEqual(log.groups, [gid], "前台换了人，回调没发")
    }

    /// 预览标签原地顶替：同一个槽位、下标不变，前台换成新标签。
    func testReplacingTheTransientTabInPlaceReportsAChange() throws {
        let log = TabChangeLog()
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab({ UPaneTab(payload: .scratch, customTitle: "p1") }, asTransient: true)
        let gid = try XCTUnwrap(model.activeGroupID)

        let (window, hostView) = host(areaReportingTabChanges(model, into: log))
        defer { window.contentView = nil }

        model.openTab({ UPaneTab(payload: .scratch, customTitle: "p2") }, asTransient: true)
        settle(hostView, window)
        XCTAssertEqual(model.groups[gid]?.activeIndex, 0)
        XCTAssertEqual(log.groups, [gid])
    }

    /// 反过来：拖着前台标签在本组里换位置，只改下标、前台还是它 —— 不是切标签，不发。
    func testReorderingTheFrontTabIsNotATabChange() throws {
        let log = TabChangeLog()
        let model = UPaneGroupsModel<TestPayload>()
        let a = model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        let c = model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }
        let gid = try XCTUnwrap(model.activeGroupID)
        XCTAssertEqual(model.activeTab?.id, c)

        let (window, hostView) = host(areaReportingTabChanges(model, into: log))
        defer { window.contentView = nil }

        model.reorderTab(c, before: a)
        settle(hostView, window)
        XCTAssertEqual(model.groups[gid]?.activeIndex, 0, "前提：下标变了")
        XCTAssertEqual(model.activeTab?.id, c)
        XCTAssertEqual(log.groups, [], "前台没换，不该当成切标签")

        // 真的切标签照常发。
        model.activateTab(groupID: gid, index: 1)
        settle(hostView, window)
        XCTAssertEqual(log.groups, [gid])
    }

    // MARK: 共享拖拽状态的几何表

    /// 每组的尺寸实时写进 `groupBounds`；组塌缩出树后那一格要删掉。
    func testGroupBoundsAreWrittenAndPrunedWhenAGroupCollapses() throws {
        let dragState = UPaneDragState()
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        let g1 = try XCTUnwrap(model.activeGroupID)
        model.splitGroup(g1)
        let g2 = try XCTUnwrap(model.activeGroupID)
        model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }

        let (window, hostView) = host(area(model).withDragState(dragState))
        defer { window.contentView = nil }
        XCTAssertEqual(Set(dragState.groupBounds.keys), [g1, g2])
        let bounds = try XCTUnwrap(dragState.groupBounds[g1])
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertEqual(bounds.origin, .zero)

        model.closeTab(groupID: g2, index: 0)
        settle(hostView, window)
        XCTAssertEqual(model.groupCount, 1)
        XCTAssertEqual(Set(dragState.groupBounds.keys), [g1], "塌缩掉的组还留在 groupBounds 里")
        XCTAssertEqual(try XCTUnwrap(dragState.groupBounds[g1]).width, 800, accuracy: 0.5,
                       "剩下那组的尺寸要跟着变成整块区域")
    }

    // MARK: 后台面板不装按下监视器

    /// `.allTabs` 下同组的后台面板也挂着；它们的按下探针不该各占一份进程级监视器。
    func testOnlyFrontPanesObservePointerDown() throws {
        let model = UPaneGroupsModel<TestPayload>()
        model.openTab { UPaneTab(payload: .scratch, customTitle: "a") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "b") }
        model.openTab { UPaneTab(payload: .scratch, customTitle: "c") }
        let gid = try XCTUnwrap(model.activeGroupID)

        let (window, hostView) = host(area(model))
        defer { window.contentView = nil }

        func probes(_ view: NSView) -> [PointerDownProbeView] {
            (view as? PointerDownProbeView).map { [$0] } ?? view.subviews.flatMap { probes($0) }
        }
        // 3 枚 chip 各一个（按下即激活），3 个面板各一个。
        let all = probes(hostView)
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.filter(\.isObserving).count, 4, "3 枚 chip + 1 个前台面板")

        model.activateTab(groupID: gid, index: 0)
        settle(hostView, window)
        XCTAssertEqual(probes(hostView).filter(\.isObserving).count, 4, "切标签后仍只有前台面板在旁观")
    }
}
#endif
