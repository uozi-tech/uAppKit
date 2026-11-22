// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// uTerm DesignKit 搜索框 —— 带前导放大镜与尾部 `⌘K` 提示芯片的输入框。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。
/// 高 32，内边距水平 12，圆角 `UD.Radius.md`，子元素间距 8。聚焦态（`@FocusState`）
/// 切换 accent 描边与图标色，并叠一圈 3px `accent` 焦点环（`showsFocusRing: false` 只去掉这圈环）。`width` 给定则定宽，
/// 否则横向撑满。
public struct UDSearchField: View {
    @Binding var text: String
    var placeholder: String = String(localized: "搜索", bundle: .module)
    var width: CGFloat? = nil
    var autoFocus: Bool = false
    var showsHotkeyChip: Bool = true
    var showsFocusRing: Bool = true

    public init(
        text: Binding<String>,
        placeholder: String = String(localized: "搜索", bundle: ModuleBundle.bundle),
        width: CGFloat? = nil,
        autoFocus: Bool = false,
        showsHotkeyChip: Bool = true,
        showsFocusRing: Bool = true
    ) {
        self._text = text
        self.placeholder = placeholder
        self.width = width
        self.autoFocus = autoFocus
        self.showsHotkeyChip = showsHotkeyChip
        self.showsFocusRing = showsFocusRing
    }

    @FocusState private var focused: Bool

    public var body: some View {
        HStack(spacing: UD.Space.sm) { // 8
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(focused ? UD.text2 : UD.text3)

            TextField(placeholder, text: $text)
                .font(UD.body)
                .foregroundStyle(UD.text)
                .textFieldStyle(.plain)
                .focused($focused)
                // AppKit 的 text field 比 SwiftUI 给的槽位每边宽 2pt，聚焦滚动后首字会画进
                // 放大镜 / ⌘K 芯片两侧的 8pt 间隙。裁回槽位；槽位只有一行文字高，纵向
                // 撑到整行控件高（32 / 2 = 16 > 一行文字），别削 CJK / emoji 的字形。
                .clipShape(UDInputContentClip(horizontalInset: 0, verticalOutset: 16))

            if showsHotkeyChip {
                Text("⌘ K")
                    .font(UD.monoKbd)
                    .foregroundStyle(UD.text4)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        // v2 键帽：uw03 胶囊底、无边。
                        RoundedRectangle(cornerRadius: UD.Radius.xs) // 4
                            .fill(UD.uw03)
                    )
            }
        }
        .padding(.horizontal, UD.Space.lg) // 12
        .frame(height: 32)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(
            // 暗：白 6% 填充承担边界；日：白底 + `inputBorder` 细边。聚焦不换底色。
            RoundedRectangle(cornerRadius: UD.Radius.md) // 8
                .fill(UD.inputFill)
        )
        .overlay(
            // 闲置 `inputBorder`（暗夜透明）；聚焦 = accent 描边（始终有，`showsFocusRing` 只管外圈柔环）。
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .strokeBorder(focused ? UD.accent : UD.inputBorder, lineWidth: 1)
        )
        .overlay(
            // 聚焦焦点环：3pt 柔环（强调色 13%）。`showsFocusRing: false`（浮层里）不画，accent 描边照样有。
            RoundedRectangle(cornerRadius: UD.Radius.md)
                .stroke(UD.accent.opacity(showsFocusRing && focused ? 0.13 : 0), lineWidth: 3)
        )
        .overlay(
            UDInputFocusDismissMonitor(isFocused: $focused)
        )
        .onAppear { focused = autoFocus }
        .onChange(of: autoFocus) { _, newValue in
            focused = newValue
        }
    }

}

#Preview("UDSearchField") {
    struct PreviewWrapper: View {
        @State private var empty = ""
        @State private var focusedLook = ""
        @State private var filled = "nginx"

        var body: some View {
            VStack(alignment: .leading, spacing: UD.Space.xxl) {
                UDSearchField(text: $empty)
                UDSearchField(text: $focusedLook, width: 320)
                UDSearchField(text: $filled, width: 320)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
#endif
