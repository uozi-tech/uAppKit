import SwiftUI

extension EnvironmentValues {
    /// 所在设置行的标题，由 `UDSettingsRow` 写给右侧控件。行内没有自己名字的控件
    /// （`UDToggle` / `UDSegmented` / `UDSlider` / `UDStepper` / 无标题的勾选框）拿它当读屏名字。
    @Entry var udRowAccessibilityLabel: String? = nil
}

/// 行内控件用了行标题当名字：`UDSettingsRow` 据此把左侧的标题文字从 AX 里藏起来，
/// 免得读屏先读一遍标题文字、再读一遍同名的开关。
struct UDRowLabelAdoptedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// 控件的读屏名字：显式名字优先；没有时取所在设置行的标题；都没有就什么也不挂
    /// （保留 SwiftUI 推出的名字）。调用处外挂的 `.accessibilityLabel` 在外层，仍然优先。
    ///
    /// 只有真用了行标题时才上报给行；显式名字和行标题可能不同（「约束」行里的「NOT NULL」），
    /// 那时行标题要留着给读屏。
    func udRowAwareAccessibilityLabel(_ explicit: Text?) -> some View {
        modifier(UDRowAwareAccessibilityLabel(explicit: explicit))
    }

    /// 由几个子按钮组成的控件（分段、步进器）：在设置行里时收成一个以行标题命名的组，
    /// 子按钮仍各读各的（「Monaco，已选」）。不在行里时原样不动。
    func udRowAwareAccessibilityGroup() -> some View {
        modifier(UDRowAwareAccessibilityGroup())
    }
}

private struct UDRowAwareAccessibilityLabel: ViewModifier {
    let explicit: Text?
    @Environment(\.udRowAccessibilityLabel) private var rowLabel

    func body(content: Content) -> some View {
        content
            .udAccessibilityLabel(explicit ?? rowLabel.map { Text(verbatim: $0) })
            .preference(key: UDRowLabelAdoptedKey.self, value: explicit == nil && rowLabel != nil)
    }
}

private struct UDRowAwareAccessibilityGroup: ViewModifier {
    @Environment(\.udRowAccessibilityLabel) private var rowLabel

    func body(content: Content) -> some View {
        if let rowLabel {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: rowLabel))
                .preference(key: UDRowLabelAdoptedKey.self, value: true)
        } else {
            content
        }
    }
}
