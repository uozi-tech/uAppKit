#if canImport(AppKit)
import SwiftUI
import XCTest
@testable import UDesignKit

/// 调用方在 `body` 里现造的展示数据（菜单项、状态栏项、会话项）身份要稳定：同一项再造一次还是同一个 id。
@MainActor
final class UDStableIDTests: XCTestCase {
    func testDerivedUUIDIsDeterministicAndDistinct() {
        XCTAssertEqual(UDStableID.uuid("abc"), UDStableID.uuid("abc"))
        XCTAssertNotEqual(UDStableID.uuid("abc"), UDStableID.uuid("abd"))
        XCTAssertNotEqual(UDStableID.uuid(""), UDStableID.uuid(" "))
        // 版本 / 变体位按 RFC 4122 打好，看着就是个正常 UUID。
        let text = UDStableID.uuid("abc").uuidString
        XCTAssertEqual(Array(text)[14], "5")
        XCTAssertTrue("89AB".contains(Array(text)[19]))
    }

    func testMenuItemIdentitySurvivesRebuild() {
        let first = UDMenuItem(label: "复制路径", systemImage: "doc.on.doc") {}
        let again = UDMenuItem(label: "复制路径", systemImage: "doc.on.doc", active: true) {}
        XCTAssertEqual(first.id, again.id, "宿主重新求值、选中态变了，仍是同一行")
        XCTAssertNotEqual(first.id, UDMenuItem(label: "重命名").id)
        // 标签会变的项用固定 key。
        XCTAssertEqual(UDMenuItem(key: "count", label: "3 项").id, UDMenuItem(key: "count", label: "4 项").id)
        XCTAssertNotEqual(UDMenuItem.divider().id, UDMenuItem(label: "").id, "分隔线与空标签项不混")
    }

    /// 多条分隔线、同名项共用派生 id 时，`UDMenu` 的行键仍各不相同且可复现。
    func testKeyedRowsDisambiguateDuplicates() {
        let items: [UDMenuItem] = [
            UDMenuItem(label: "打开"), .divider(), UDMenuItem(label: "复制"), .divider(), UDMenuItem(label: "打开"),
        ]
        let keys = UDStableID.keyed(items, id: \.id).map(\.key)
        XCTAssertEqual(Set(keys).count, items.count)
        let rebuilt: [UDMenuItem] = [
            UDMenuItem(label: "打开"), .divider(), UDMenuItem(label: "复制"), .divider(), UDMenuItem(label: "打开"),
        ]
        XCTAssertEqual(UDStableID.keyed(rebuilt, id: \.id).map(\.key), keys)
    }

    func testFooterItemIdentityIgnoresChangingLabel() {
        let tick1 = UDFooterItem(systemImage: "clock", color: .gray, label: "14:22:08")
        let tick2 = UDFooterItem(systemImage: "clock", color: .gray, label: "14:22:09")
        XCTAssertEqual(tick1.id, tick2.id, "状态栏每秒刷新，同一项身份不变")
        XCTAssertNotEqual(tick1.id, UDFooterItem(systemImage: "cpu", color: .gray, label: "14:22:08").id)
        XCTAssertNotEqual(UDFooterItem(systemImage: "terminal", color: .gray, label: "a", key: "git").id,
                          UDFooterItem(systemImage: "terminal", color: .gray, label: "a", key: "shell").id)
    }

    func testSessionItemIdentity() {
        XCTAssertEqual(UDChatSessionItem(title: "排查", preview: "a", updated: "刚刚").id,
                       UDChatSessionItem(title: "排查", preview: "b", updated: "1 分钟前", active: true).id)
        XCTAssertNotEqual(UDChatSessionItem(title: "排查", preview: "", updated: "", key: "1").id,
                          UDChatSessionItem(title: "排查", preview: "", updated: "", key: "2").id)
    }
}
#endif
