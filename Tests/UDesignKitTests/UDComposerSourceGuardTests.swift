import XCTest
@testable import UDesignKit

/// 源码守卫：有些行为在类型层面看不出来，只能盯住源文本。
///
/// 这条原先住在 uTerm 的 `AssistantInputBarLayoutTests` 里，按相对路径去兄弟仓库找
/// `uTable/Packages/UDesignKit/…`。UDesignKit 收编进本包、且两个 app 改成按 tag 取
/// 远程依赖之后，那条路径不再存在，而且**指向兄弟目录本身就是错的** —— 那正是这次
/// 收编要拆掉的耦合。守卫跟着源码走，才不会随消费方的依赖方式改变而失效。
final class UDComposerSourceGuardTests: XCTestCase {
    /// 回车要触发发送动作，而不是把焦点留在发送按钮上。
    func testComposerRoutesReturnKeyToSendAction() throws {
        let source = try String(contentsOf: Self.composerSourceURL, encoding: .utf8)
        let handlesReturn = source.contains(".onSubmit")
            || source.contains(".onKeyPress(.return)")
            || source.contains(".keyboardShortcut(.return")
        XCTAssertTrue(handlesReturn,
                      "UDComposer 必须把 Return 路由到发送动作，而不是把焦点留在发送按钮上。")
    }

    /// 守卫自身要能失败。路径找不到就是守卫坏了，必须报错而不是静默跳过 ——
    /// 一条永远不会红的守卫等于没有。
    func testGuardCanActuallyReadTheSource() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.composerSourceURL.path),
                      "找不到 UDComposer.swift，源码守卫已失效：\(Self.composerSourceURL.path)")
    }

    private static var composerSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UDesignKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <包根>
            .appendingPathComponent("Sources/UDesignKit/Comms/UDComposer.swift")
    }
}
