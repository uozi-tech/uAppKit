// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// uTerm DesignKit 多行文本框 —— `UDTextField` 的多行姐妹件。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。经由
/// `@Environment(\.isEnabled)` 响应 `.disabled()`。视觉语言与 `UDTextField`
/// 完全一致：`inputFill` 底 + 闲置 `inputBorder` 细边（暗夜透明）、聚焦 / 错误换成
/// accent / 红色描边并叠一圈 3px 焦点环（`showsFocusRing: false` 不叠）、圆角 `UD.Radius.md`。内容超出 `maxHeight` 后由
/// `TextEditor` 内部纵向滚动。
///
/// 用于承载不定长 `text` 字段（PG `text` / MySQL `TEXT`）等适合多行编辑的值，
/// 与 [UDTextField] 的单行输入互补。
public struct UDTextArea: View {
    var label: String? = nil
    var placeholder: String = ""
    @Binding var text: String
    var errorMessage: String? = nil
    var autoFocus: Bool = false
    var monospaced: Bool = false
    /// 文本框最低高度（≈ 静息展示高度）。
    var minHeight: CGFloat = 76
    /// 高度上限；内容超出后 `TextEditor` 内部滚动。
    var maxHeight: CGFloat = 180
    /// 聚焦 / 错误时外面那圈 3pt 柔环（同 `UDTextField.showsFocusRing`）。
    var showsFocusRing: Bool = true

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var hasError: Bool { errorMessage != nil }

    public init(
        label: String? = nil,
        placeholder: String = "",
        text: Binding<String>,
        errorMessage: String? = nil,
        autoFocus: Bool = false,
        monospaced: Bool = false,
        minHeight: CGFloat = 76,
        maxHeight: CGFloat = 180,
        showsFocusRing: Bool = true
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.autoFocus = autoFocus
        self.monospaced = monospaced
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.showsFocusRing = showsFocusRing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(UD.font(11))
                    .foregroundStyle(UD.text3)
                    // 名字挂到编辑器本身（见 `editor`），这行字不再单独读一遍。
                    .accessibilityHidden(true)
            }

            editor
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .background {
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .fill(fieldBackground)
                }
                .overlay {
                    // 闲置 `inputBorder`（暗夜透明）；聚焦 accent / 错误红。
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .stroke(ringColor, lineWidth: 3)
                }
                .overlay {
                    UDInputFocusDismissMonitor(isFocused: $focused)
                }
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

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // 占位：TextEditor 没有垂直内衬、左右各有 5pt 行片段留白（lineFragmentPadding），
            // 所以占位水平 9+5、垂直与编辑器同为 10，光标和占位落在同一位置。
            if text.isEmpty {
                Text(placeholder)
                    .font(contentFont)
                    .foregroundStyle(UD.text4)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                // TextEditor 没有占位也没有名字，VoiceOver 只读出「文本」；用标签（没有就用占位）命名。
                .udAccessibilityLabel(accessibilityName.map { Text(verbatim: $0) })
                .font(contentFont)
                .foregroundStyle(UD.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .disabled(!isEnabled)
                .padding(.horizontal, 9).padding(.vertical, 10)
        }
    }

    private var accessibilityName: String? {
        if let label, !label.isEmpty { return label }
        return placeholder.isEmpty ? nil : placeholder
    }

    private var contentFont: Font {
        monospaced ? UD.mono(13) : UD.body
    }

    /// 禁用态输入底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let disabledBg = UD.dyn(.white(0.02), .black(0.025))

    private var fieldBackground: Color {
        if !isEnabled {
            return Self.disabledBg
        }
        return UD.inputFill   // 暗：白 6% 填充承担边界；日：白底 + `inputBorder` 细边
    }

    private var borderColor: Color {
        if hasError { return UD.danger }
        if focused { return UD.accent }
        return UD.inputBorder   // 闲置：日间细边、暗夜透明（占位防跳动）
    }

    /// 聚焦 / 错误焦点环：3pt 柔环（强调色 13% / 错误 12%）；`showsFocusRing == false` 时不画。
    private var ringColor: Color {
        guard showsFocusRing else { return .clear }
        if hasError { return UD.danger.opacity(0.12) }
        if focused { return UD.accent.opacity(0.13) }
        return Color.clear
    }
}

#Preview("UDTextArea") {
    struct PreviewWrapper: View {
        @State private var empty = ""
        @State private var filled = #"{"group":"build-bot","sender":"demo","message":"hello world"}"#
        @State private var errored = "line one\nline two"

        var body: some View {
            HStack(alignment: .top, spacing: UD.Space.xxl) {
                UDTextArea(label: "payload", placeholder: "输入文本…", text: $empty)
                    .frame(width: 260)
                UDTextArea(label: "payload", text: $filled, monospaced: true)
                    .frame(width: 260)
                UDTextArea(label: "payload", text: $errored,
                           errorMessage: "格式错误", monospaced: true)
                    .frame(width: 260)
                    .disabled(true)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
#endif
