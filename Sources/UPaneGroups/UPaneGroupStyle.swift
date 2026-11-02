#if os(macOS)
import SwiftUI
import UDesignKit

/// 编辑区的外观档位。默认 `.classic` 就是组件一直以来的画法（`UD.bg` 底、标签条
/// `UD.panel` 底 + 底部发丝线、chip 之间竖线、活动标签 2px accent 顶条），老调用方
/// 一行不改、像素不变。
///
/// `.card` 对应「分区方案 v3.3」：编辑区坐在一张内容卡里（`UD.panel`），标签条并入
/// 卡顶——无底色、无底线、无 chip 竖线；活动标签是 `UD.panelHi` 胶囊（圆角 7、高 26），
/// 未激活 text3、悬停 `UD.panelHover`；分屏 / 关闭空组按钮是 26×26 圆角 6 的图标钮，
/// 前面不再画竖分隔线。分屏窗格之间仍是 `UPaneSplitter` 的 1pt 线（两侧同为卡面色）。
/// 需要「卡内凹槽 + 6pt 间隙」的调用方（uTerm 终端区）另加 `.uPaneGroupWells()`。
///
/// 走 environment 而不是给 `UPaneGroupArea.init` 加参数：组件已有三个便捷 init，
/// 加参数要四处同步；环境值对老调用方完全透明。
public struct UPaneGroupStyle: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case classic
        case card
    }

    public var kind: Kind
    /// `.card` 下标签条底部是否画 1pt `UD.border` 线（两侧同为卡面色）。标签条下面紧接
    /// 编辑器 / 预览这类铺满的正文时用它标出正文起点；正文是凹槽或自带分区时不需要。
    public var stripDivider: Bool

    public init(_ kind: Kind, stripDivider: Bool = false) {
        self.kind = kind
        self.stripDivider = stripDivider
    }

    public static let classic = UPaneGroupStyle(.classic)
    public static let card = UPaneGroupStyle(.card)
    /// `.card` + 标签条底线。
    public static let cardDivided = UPaneGroupStyle(.card, stripDivider: true)

    /// 胶囊标签的高与圆角（设计稿 `.ut-tab`：height 26 · radius 7）。
    public static let pillHeight: CGFloat = 26
    public static let pillRadius: CGFloat = 7

    /// 区域与组外壳的底色：classic 是画布色，card 是卡面色。
    var areaBackground: Color { kind == .card ? UD.panel : UD.bg }
}

private struct UPaneGroupStyleKey: EnvironmentKey {
    static let defaultValue = UPaneGroupStyle.classic
}

public extension EnvironmentValues {
    var uPaneGroupStyle: UPaneGroupStyle {
        get { self[UPaneGroupStyleKey.self] }
        set { self[UPaneGroupStyleKey.self] = newValue }
    }
}

public extension View {
    /// 设定子树里 `UPaneGroupArea` 的外观档位（默认 `.classic`）。
    func uPaneGroupStyle(_ style: UPaneGroupStyle) -> some View {
        environment(\.uPaneGroupStyle, style)
    }
}
#endif
