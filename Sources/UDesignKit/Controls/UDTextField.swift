// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// uTerm DesignKit 文本输入框 —— 可带标签 / 错误提示的单行输入。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。
/// 经由 `@Environment(\.isEnabled)` 响应 `.disabled()`。视觉状态优先级
/// 错误 > 聚焦 > 禁用 > 闲置。字段高 34，水平内边距 11，圆角 `UD.Radius.md`；
/// 标签 11 用 `UD.text3`，错误文案 10.5 用 `UD.danger`。聚焦 / 错误态换成 accent / 红色
/// 描边并叠一圈 3px 焦点环（`showsFocusRing: false` 不叠）。`isSecure` + `revealable` 时尾部多一个眼睛钮，点一下在掩码与原文之间切。
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
    var revealable: Bool = false
    /// 聚焦 / 错误时外面那圈 3pt 柔环。浮层里的输入框（选择面板的搜索框等）传 false：浮层自带阴影，再叠一圈像重影。
    var showsFocusRing: Bool = true

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var revealed = false
    @State private var revealHovering = false

    public init(label: String? = nil,
         placeholder: String,
         text: Binding<String>,
         errorMessage: String? = nil,
         autoFocus: Bool = false,
         monospaced: Bool = false,
         isSecure: Bool = false,
         revealable: Bool = false,
         showsFocusRing: Bool = true) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.autoFocus = autoFocus
        self.monospaced = monospaced
        self.isSecure = isSecure
        self.revealable = revealable
        self.showsFocusRing = showsFocusRing
    }

    private var hasError: Bool { errorMessage != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(UD.font(11))
                    .foregroundStyle(UD.text3)
            }

            HStack(spacing: UD.Space.sm) { // 8
                field
                    .textFieldStyle(.plain)
                    .font(monospaced ? UD.mono(13) : UD.body)
                    .foregroundStyle(UD.text)
                    .focused($focused)
                    // AppKit 把 text field（以及聚焦时接管绘制的 field editor clip view）排得比
                    // SwiftUI 内容框每边宽 2 ~ 4.5pt。文本一超出宽度，闲置态的末字、聚焦态滚出去的
                    // 首字就画进内边距里、糊到圆角描边上（长密码尤其明显），有显隐钮时还会糊进
                    // 两者之间的间隙。按槽位横向裁掉；槽位只有一行文字高，纵向撑到整行控件高
                    // （34 / 2 = 17 > 一行文字），别削 CJK / emoji 的字形。
                    .clipShape(UDInputContentClip(horizontalInset: 0, verticalOutset: 17))

                if showsRevealToggle {
                    revealToggle
                }
            }
            .disabled(!isEnabled)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: 34)
            // 内部的 NSTextField 只有一行文字高（约 16pt）、且不含水平内边距；点在 34pt 框的
            // 留白上原本落不到它身上，用户会以为「要点两次」。整框可点，点到就聚焦。
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { focused = true } }
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.md)
                    .fill(fieldBackground)
            )
            .overlay(
                // 闲置 `inputBorder`（暗夜透明）；聚焦 accent / 错误红。
                RoundedRectangle(cornerRadius: UD.Radius.md)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .overlay(
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
        if isSecure, !revealed {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    /// 只有密码框显式要了才画眼睛钮 —— 普通输入框没有「原文」一说。
    private var showsRevealToggle: Bool { isSecure && revealable }

    /// 尾部「查看原文 / 隐藏」眼睛钮。
    private var revealToggle: some View {
        Button(action: toggleReveal) {
            Image(systemName: revealed ? "eye" : "eye.slash")
                .font(.system(size: 12))
                .foregroundStyle(revealHovering ? UD.text2 : UD.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .onHover { revealHovering = $0 }
        .help(revealed ? String(localized: "隐藏", bundle: ModuleBundle.bundle) : String(localized: "查看原文", bundle: ModuleBundle.bundle))
        .accessibilityLabel(revealed ? String(localized: "隐藏原文", bundle: ModuleBundle.bundle) : String(localized: "查看原文", bundle: ModuleBundle.bundle))
    }

    /// 掩码 ⇄ 明文。`SecureField` 和 `TextField` 是两个不同的 AppKit 视图，换一个必然
    /// 把 field editor 交出去 —— 原来在编辑就等这拍界面更新落地后把焦点还回去，
    /// 光标和聚焦描边不掉。
    @MainActor
    private func toggleReveal() {
        let wasFocused = focused
        revealed.toggle()
        guard wasFocused else { return }
        Task {
            await Task.yield()
            focused = true
        }
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
        @State private var secret = "hunter2-correct-horse"

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
                UDTextField(label: "密码", placeholder: "••••••••", text: $secret,
                            isSecure: true, revealable: true)
                    .frame(width: 240)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
#endif
