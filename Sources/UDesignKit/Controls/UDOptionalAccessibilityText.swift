import SwiftUI

extension View {
    /// 有名字才挂 `accessibilityLabel`；`nil` 时什么都不加，保留 SwiftUI 自己推出来的标签
    /// （SF 符号名、按钮里的文字）或调用处外挂的 `.accessibilityLabel`。
    ///
    /// 两个分支的视图类型不同，但是否为 nil 由调用处的参数决定、同一个实例里基本不会来回翻，
    /// 不存在「条件一翻就重建子树」的问题。
    func udAccessibilityLabel(_ label: Text?) -> some View {
        modifier(UDOptionalAccessibilityText(kind: .label, text: label))
    }

    /// 有值才挂 `accessibilityValue`；`nil` 时保留控件自带的值（如 Slider 的数值）。
    func udAccessibilityValue(_ value: Text?) -> some View {
        modifier(UDOptionalAccessibilityText(kind: .value, text: value))
    }

    /// 有提示才挂 `accessibilityHint`。
    func udAccessibilityHint(_ hint: Text?) -> some View {
        modifier(UDOptionalAccessibilityText(kind: .hint, text: hint))
    }
}

private struct UDOptionalAccessibilityText: ViewModifier {
    enum Kind { case label, value, hint }
    let kind: Kind
    let text: Text?

    func body(content: Content) -> some View {
        if let text {
            switch kind {
            case .label: content.accessibilityLabel(text)
            case .value: content.accessibilityValue(text)
            case .hint: content.accessibilityHint(text)
            }
        } else {
            content
        }
    }
}
