import SwiftUI

/// uTerm DesignKit 文本输入框 —— 可带标签 / 错误提示的单行输入。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。
/// 经由 `@Environment(\.isEnabled)` 响应 `.disabled()`。视觉状态优先级
/// 错误 > 聚焦 > 禁用 > 闲置。字段高 34，水平内边距 11，圆角 `UD.Radius.md`；
/// 标签 11 用 `UD.text3`，错误文案 10.5 用 `UD.danger`。聚焦 / 错误态各叠一圈
/// 3px 焦点环。
public struct UDTextField: View {
    /// 内容框水平内边距。文本裁剪边界与它同源，改一处即可。
    public static let horizontalPadding: CGFloat = 11

    var label: String? = nil
    var placeholder: String
    @Binding var text: String
    var errorMessage: String? = nil
    var autoFocus: Bool = false
    var monospaced: Bool = false
    var isSecure: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    public init(label: String? = nil,
         placeholder: String,
         text: Binding<String>,
         errorMessage: String? = nil,
         autoFocus: Bool = false,
         monospaced: Bool = false,
         isSecure: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.autoFocus = autoFocus
        self.monospaced = monospaced
        self.isSecure = isSecure
    }

    private var hasError: Bool { errorMessage != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(UD.font(11))
                    .foregroundStyle(UD.text3)
            }

            field
                .textFieldStyle(.plain)
                .font(monospaced ? UD.mono(13) : UD.body)
                .foregroundStyle(UD.text)
                .focused($focused)
                .disabled(!isEnabled)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: 34)
                // AppKit 把 text field（以及聚焦时接管绘制的 field editor clip view）排得比
                // SwiftUI 内容框每边宽 2 ~ 4.5pt。文本一超出宽度，闲置态的末字、聚焦态滚出去的
                // 首字就画进内边距里、糊到圆角描边上（长密码尤其明显）。按内容框横向裁掉。
                .clipShape(UDInputContentClip(horizontalInset: Self.horizontalPadding))
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .fill(fieldBackground)
                )
                .overlay(
                    // v2：闲置无描边（透明占位防聚焦切换跳动）；仅聚焦 accent / 错误红。
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .overlay(
                    // 聚焦 / 错误焦点环：3pt 柔环（强调色 13% / 错误 12%），不用粗发光。
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .stroke(ringColor, lineWidth: 3)
                )
                .overlay(
                    UDInputFocusDismissMonitor(isFocused: $focused)
                )
                .opacity(isEnabled ? 1 : 0.55)
                .onAppear { focused = autoFocus }
                .onChange(of: autoFocus) { _, newValue in
                    focused = newValue
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.danger)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var fieldBackground: Color {
        if !isEnabled {
            return UD.dyn(.white(0.02), .black(0.025))
        }
        return UD.inputBg   // v2：淡灰填充承担边界（暗 white 5.5% / 日 black 5%）
    }

    private var borderColor: Color {
        if hasError { return UD.danger }
        if focused { return UD.accent }
        return .clear   // v2：闲置无描边，占位防跳动
    }

    private var ringColor: Color {
        if hasError { return UD.danger.opacity(0.12) }
        if focused { return UD.accent.opacity(0.13) }
        return Color.clear
    }
}

/// 输入框文本裁剪形状：横向裁到内容框（矩形内缩 `horizontalInset`），纵向只放不收。
///
/// SwiftUI 的 `TextField` / `SecureField` 底下是 AppKit 的 `NSTextField`。它被排在比
/// SwiftUI 内容框每边宽 2pt 的位置，聚焦后接管绘制的 field editor clip view 还要再外扩
/// 约 2.5pt —— 于是长文本会画进水平内边距、糊在圆角描边上（`UDTextField`），
/// 或者糊进图标 / 快捷键芯片之间的间隙（`UDSearchField`）。
///
/// 纵向绝不能一起裁：整体 `.clipped()` 会把裁剪盒收成单行文字高（13pt 字号下 16pt，
/// 而 CJK + emoji 的字形实测已占 15.5pt），余量太薄，换个字体 / 语言就会削掉字形。
/// 套在只有一行文字高的视图上时用 `verticalOutset` 把裁剪盒撑到整行控件高。
public struct UDInputContentClip: Shape {
    public var horizontalInset: CGFloat
    /// 纵向外扩量：裁剪盒上下各放宽这么多，`0` = 按视图自身高度。
    public var verticalOutset: CGFloat

    public init(horizontalInset: CGFloat, verticalOutset: CGFloat = 0) {
        self.horizontalInset = horizontalInset
        self.verticalOutset = verticalOutset
    }

    public nonisolated func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: horizontalInset, dy: -verticalOutset))
    }
}

#Preview("UDTextField") {
    struct PreviewWrapper: View {
        @State private var idle = ""
        @State private var filled = "root@203.0.113.10"
        @State private var errored = "47.113"
        @State private var disabled = "root@203.0.113.10"

        var body: some View {
            HStack(alignment: .top, spacing: UD.Space.xxl) {
                UDTextField(label: "主机", placeholder: "user@host", text: $idle)
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $filled)
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $errored,
                            errorMessage: "无法解析该地址")
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $disabled)
                    .frame(width: 240)
                    .disabled(true)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
