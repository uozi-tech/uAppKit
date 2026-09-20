import SwiftUI
import XCTest
@testable import UDesignKit

/// 强调色 token 的**实例同一性**守卫。
///
/// `Color` 的 `==` 落到底层 NSColor 的实例同一性上：值一模一样、但来自两次构造的
/// 两个颜色并不相等。所以 `UD.accent*` 每次必须返回**同一个**缓存实例——否则任何把
/// 强调色存进 view value 的视图「这一帧的值永远不等于上一帧」，SwiftUI「值没变就跳过
/// 子树」的快路径被永久废掉，body 每帧重跑。
///
/// 这条在类型层面看不出来（computed `var` 和查表 getter 的签名一样），只能真读两次
/// 比一比。2026-09 从 computed `var` 改成查表缓存，就是为了修掉这个重渲染放大器。
@MainActor
final class UDAccentTokenIdentityTests: XCTestCase {
    private var original: AccentColor!

    override func setUp() async throws {
        try await super.setUp()
        original = AccentState.shared.selected
    }

    override func tearDown() async throws {
        AccentState.shared.selected = original
        try await super.tearDown()
    }

    /// 每个槽位连读两次必须拿到相等（= 同一个）的 `Color`。
    func testAccentTokensReturnTheSameInstanceAcrossReads() {
        for accent in AccentColor.allCases {
            AccentState.shared.selected = accent
            for (name, read) in Self.slots {
                XCTAssertEqual(read(), read(),
                               "UD.\(name) 在 \(accent.rawValue) 下两次读到的不是同一个 Color 实例——"
                               + "getter 又在现建颜色了，SwiftUI 的子树剪枝会被废掉。")
            }
        }
    }

    /// 守卫自身要能失败：两次独立的 `UD.dyn` 必须**不**相等，否则上面那条永远绿、等于没写。
    /// 非 AppKit 平台的 `dyn` 回退成值相等的静态色，故只在 AppKit 上校验。
    func testIdentityAssertionCanActuallyFail() {
        #if canImport(AppKit)
        XCTAssertNotEqual(UD.dyn(.white(0.5), .black(0.5)), UD.dyn(.white(0.5), .black(0.5)),
                          "两次独立构造的动态 Color 居然相等——`Color` 的等值语义变了，"
                          + "本文件的同一性守卫已失效，需要重新设计。")
        #endif
    }

    /// 缓存不能把颜色钉死：换 `AccentState.shared.selected`，每个槽位都要跟着换。
    /// 顺带证明查表覆盖了所有 case——漏了的 case 会掉进 `.blue` 兜底、与蓝撞色。
    func testSwitchingAccentSwitchesEveryToken() {
        for (name, read) in Self.slots {
            var seen: [Color] = []
            for accent in AccentColor.allCases {
                AccentState.shared.selected = accent
                let color = read()
                XCTAssertFalse(seen.contains(color),
                               "UD.\(name) 在 \(accent.rawValue) 下与之前某个强调色撞色——"
                               + "查表漏了这个 case（掉进兜底），或缓存把颜色钉死了。")
                seen.append(color)
            }
        }
    }

    /// 切色仍要读到新值，而不是首次读之后就锁死。
    func testAccentFollowsSelectionAfterFirstRead() {
        AccentState.shared.selected = .blue
        let blue = UD.accent
        AccentState.shared.selected = .red
        XCTAssertNotEqual(blue, UD.accent, "切换强调色后 UD.accent 没变——Observation 真源断了。")
        AccentState.shared.selected = .blue
        XCTAssertEqual(blue, UD.accent, "切回蓝之后 UD.accent 与之前读到的不是同一个实例——缓存没命中。")
    }

    /// 7 个可切换槽位。`accentDefault` / `aiAccent` 等固定色本就是 `static let`，不在此列。
    private static let slots: [(String, @MainActor () -> Color)] = [
        ("accent", { UD.accent }),
        ("accentInk", { UD.accentInk }),
        ("accentSoft", { UD.accentSoft }),
        ("accentPressed", { UD.accentPressed }),
        ("accentTint", { UD.accentTint }),
        ("accentTintHover", { UD.accentTintHover }),
        ("accentTintDisabled", { UD.accentTintDisabled }),
    ]
}
