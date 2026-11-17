import SwiftUI

/// 不带按下变淡的 `.plain`：自绘按钮（侧栏行、图标栏、标签、分段钮…）统一用它。
///
/// 系统 `.plain` 在 macOS 上按住时会把整个 label（底色、图标、文字）压到约一半不透明度。
/// 自绘按钮的底色本身就是状态 —— 选中项点一下，选中底跟着变淡再恢复，看上去就是
/// 「失焦 → 聚焦」来回切；连点时一闪一闪。按下的反馈交给各组件自己的底色。
///
/// 禁用态照抄 `.plain`：整体 0.5 不透明度（实测与 `.plain` 禁用逐像素一致），
/// 换用后禁用按钮的外观不变。
///
/// Menu 不要用它：`.menuStyle(.button)` 的 Menu 走 AppKit 渲染，继续写 `.buttonStyle(.plain)`。
public struct UDPlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : Self.disabledOpacity)
    }

    static let disabledOpacity: Double = 0.5
}

public extension ButtonStyle where Self == UDPlainButtonStyle {
    /// 不带按下变淡的 `.plain`，见 `UDPlainButtonStyle`。
    static var udPlain: UDPlainButtonStyle { UDPlainButtonStyle() }
}
