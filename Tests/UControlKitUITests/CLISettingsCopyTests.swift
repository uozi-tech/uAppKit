#if os(macOS)

import XCTest
import UControlKit
@testable import UControlKitUI

/// 文案按状态取值、`~/.local/bin` 行说明的拼法（与 uTerm 设置页逐字一致）。
final class CLISettingsCopyTests: XCTestCase {
    private let texts = CLISettingsCopy.StatusTexts(
        notInstalled: "未安装", installed: "已安装", brokenLink: "需修复", conflict: "冲突")

    func testStatusTextsCoverEveryStatus() {
        XCTAssertEqual(texts.text(for: .notInstalled), "未安装")
        XCTAssertEqual(texts.text(for: .installed), "已安装")
        XCTAssertEqual(texts.text(for: .brokenLink), "需修复")
        XCTAssertEqual(texts.text(for: .conflict(reason: "x")), "冲突")
    }

    func testClientLinkHintAppendsStatusNote() {
        let copy = CLISettingsCopy.ClientLink(
            label: "同时链接到 ~/.local/bin/utermctl",
            hint: "在自己的终端里也能直接敲 utermctl",
            installedNote: "（已链接）",
            brokenNote: "（链接指向旧位置，关掉再打开开关即可修复）")
        XCTAssertEqual(copy.hint(for: .notInstalled), "在自己的终端里也能直接敲 utermctl")
        XCTAssertEqual(copy.hint(for: .installed), "在自己的终端里也能直接敲 utermctl（已链接）")
        XCTAssertEqual(copy.hint(for: .brokenLink),
                       "在自己的终端里也能直接敲 utermctl（链接指向旧位置，关掉再打开开关即可修复）")
        XCTAssertEqual(copy.hint(for: .conflict(reason: "被占用")), "在自己的终端里也能直接敲 utermctl（被占用）")
    }
}

#endif
