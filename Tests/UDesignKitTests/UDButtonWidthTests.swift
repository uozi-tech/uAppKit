#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import UDesignKit

/// `UDButton(fillsWidth:)`：底色撑满给定宽度（表单底部的整宽主按钮）；默认仍随内容宽。
@MainActor
final class UDButtonWidthTests: XCTestCase {
    private func width(of button: UDButton, in proposed: CGFloat) -> CGFloat {
        NSHostingController(rootView: button).sizeThatFits(in: CGSize(width: proposed, height: 100)).width
    }

    func testFillsWidthTakesProposedWidth() {
        let filled = width(of: UDButton(title: "提交", fillsWidth: true) {}, in: 320)
        let hugging = width(of: UDButton(title: "提交") {}, in: 320)
        XCTAssertEqual(filled, 320, accuracy: 0.5)
        XCTAssertLessThan(hugging, 120, "默认随内容宽")
    }
}
#endif
