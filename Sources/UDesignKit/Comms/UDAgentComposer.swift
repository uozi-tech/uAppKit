// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI

/// `UDAgentComposer` 的版式常量。消费方的布局测试守这些数，而不是守源文本。
public enum UDAgentComposerLayout {
    /// 工具栏里所有控件（幽灵图标钮 / 下拉触发器）的统一高度。
    public nonisolated static let controlHeight: CGFloat = 26
    /// 主操作钮（发送 / 停止）的直径。
    public nonisolated static let primarySize: CGFloat = 28
    public nonisolated static let cornerRadius: CGFloat = 14
}

/// Agent 对话输入区 —— uTerm / uTable 共用。
///
/// 一张卡片：上面是纵向增长的输入行，下面是一行工具栏。与旧的 `UDComposer` 相比：
///
/// - **一个主操作位**：空闲时是发送（`canSend` 才点亮），Agent 在跑时（`canStop`）同一位置
///   变成停止。两者同时成立（忙碌时允许排队发送）则并排：停止 + 发送。停止不再是悬在
///   输入框之外的另一颗按钮。
/// - **工具栏恒为一行**：左侧 `toolbar` 槽放消费方自己的控件（模型、审批档位、附加…），
///   推荐用本文件的幽灵外观（`UDComposerGhostLabel` / `UDComposerGhostIconStyle`）——
///   静态无底色、hover 才出底，不再一控件一枚灰胶囊。
/// - **状态可见**：`status` 是卡片上方的一行小字。聚焦时卡片外观不变（不加强调描边 / 外环）。
/// - **键盘**：↩ 发送、⌥↩ 换行、esc 停止（焦点在输入框且 `canStop` 时）。
///
/// 纯展示组件：只读 `UD` token + 普通值 / 闭包 / 视图输入，不依赖任何 domain model。
/// 「什么时候算能发 / 能停」由消费方定 —— 有的面板忙碌时排队（仍可发），有的不排队。
public struct UDAgentComposer<Accessory: View, Toolbar: View>: View {
    @Binding var text: String
    var placeholder: String
    var minLines: Int
    var maxLines: Int
    var fontSize: CGFloat
    var status: String?
    var canSend: Bool
    var canStop: Bool
    var sendHelp: String
    var stopHelp: String
    var focus: FocusState<Bool>.Binding?
    var onSend: () -> Void
    var onStop: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var toolbar: () -> Toolbar

    @FocusState private var ownFocus: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - maxLines: 输入行最多长到几行；缺省 `max(minLines + 4, 8)`。
    ///   - status: 卡片上方的一行小字（如「已停止」）；nil 不占位。
    ///   - canSend: 发送钮是否点亮。通常是「输入非空」；不排队的面板再并上「不忙」。
    ///   - canStop: Agent 是否在跑。为真时出现停止钮，esc 触发 `onStop`。
    ///   - focus: 消费方要自己控制焦点（如外部动作把文字塞进输入框后聚焦）时传入；
    ///     不传则组件自管。
    ///   - accessory: 输入行前缀（如已确认的命令 token），与文字同一行。
    ///   - toolbar: 工具栏左侧内容；右侧的停止 / 发送由组件自己画。
    public init(
        text: Binding<String>,
        placeholder: String,
        minLines: Int = 2,
        maxLines: Int? = nil,
        fontSize: CGFloat = 13,
        status: String? = nil,
        canSend: Bool,
        canStop: Bool = false,
        sendHelp: String = String(localized: "发送（↩）", bundle: ModuleBundle.bundle),
        stopHelp: String = String(localized: "停止（esc）", bundle: ModuleBundle.bundle),
        focus: FocusState<Bool>.Binding? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder toolbar: @escaping () -> Toolbar
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minLines = max(minLines, 1)
        self.maxLines = max(maxLines ?? max(minLines + 4, 8), max(minLines, 1))
        self.fontSize = fontSize
        self.status = status
        self.canSend = canSend
        self.canStop = canStop
        self.sendHelp = sendHelp
        self.stopHelp = stopHelp
        self.focus = focus
        self.onSend = onSend
        self.onStop = onStop
        self.accessory = accessory
        self.toolbar = toolbar
    }

    private func takeFocus() {
        if let focus { focus.wrappedValue = true } else { ownFocus = true }
    }

    /// ↩ 与发送钮同一个门：`canSend` 为假（输入为空、不排队的面板正忙）时回车不发。
    private func submitIfAllowed() {
        UDAgentComposerSubmit.perform(canSend: canSend, onSend: onSend)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                Text(status)
                    .font(UD.font(11))
                    .foregroundStyle(UD.text3)
                    .padding(.horizontal, 4)
            }
            card
        }
    }

    /// 底板 + 投影。投影只挂在底板形状上：挂在整张卡片上时，SwiftUI 要把输入框、工具栏
    /// 整棵离屏栅格化才算得出阴影，每敲一个字都重来一遍。
    ///
    /// 两层：贴边的接触影交代边缘，更散更淡的环境影把卡片托起来。原先单层 `.sm`
    /// （半径 4、10%）在浅色下是一圈发灰的晕边，深色下几乎看不见。
    private func cardBackground(_ shape: RoundedRectangle) -> some View {
        let dark = colorScheme == .dark
        return shape.fill(UD.overlay)
            .shadow(color: .black.opacity(dark ? 0.30 : 0.035), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(dark ? 0.38 : 0.07), radius: 14, x: 0, y: 6)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: UDAgentComposerLayout.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                accessory()
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(UD.font(fontSize))
                    .foregroundStyle(UD.text)
                    .lineLimit(minLines...maxLines)
                    .focused(focus ?? $ownFocus)
                    .onSubmit(submitIfAllowed)
                    .onExitCommand { if canStop { onStop() } }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 2) {
                toolbar()
                Spacer(minLength: 6)
                if canStop {
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .buttonStyle(UDAgentComposerPrimaryStyle(role: .stop))
                        .help(stopHelp)
                        .accessibilityLabel(String(localized: "停止", bundle: ModuleBundle.bundle))
                }
                // 忙碌且不能发时只留停止：同一个位置，发送 ⇄ 停止。
                if canSend || !canStop {
                    Button(action: onSend) { Image(systemName: "arrow.up") }
                        .buttonStyle(UDAgentComposerPrimaryStyle(role: .send))
                        .disabled(!canSend)
                        .help(sendHelp)
                        .accessibilityLabel(String(localized: "发送", bundle: ModuleBundle.bundle))
                }
            }
        }
        .padding(.top, 12)
        .padding([.horizontal, .bottom], 8)
        .background { cardBackground(shape) }
        // 聚焦不换描边、不加外环：光标已经说明了焦点，蓝框在面板里太抢眼。
        .overlay { shape.strokeBorder(UD.border, lineWidth: 1) }
        // 卡片留白处也能点进输入框（工具栏上的控件各自吃掉自己的点击）。
        .contentShape(shape)
        .onTapGesture { takeFocus() }
    }
}

/// 回车提交的判定（单测守它）：与发送钮的 `.disabled(!canSend)` 一致。
enum UDAgentComposerSubmit {
    /// 发出去了返回 true。
    @discardableResult
    static func perform(canSend: Bool, onSend: () -> Void) -> Bool {
        guard canSend else { return false }
        onSend()
        return true
    }
}

// MARK: - 省略插槽的便捷初始化

public extension UDAgentComposer where Accessory == EmptyView {
    /// 无输入行前缀。
    init(
        text: Binding<String>,
        placeholder: String,
        minLines: Int = 2,
        maxLines: Int? = nil,
        fontSize: CGFloat = 13,
        status: String? = nil,
        canSend: Bool,
        canStop: Bool = false,
        sendHelp: String = String(localized: "发送（↩）", bundle: ModuleBundle.bundle),
        stopHelp: String = String(localized: "停止（esc）", bundle: ModuleBundle.bundle),
        focus: FocusState<Bool>.Binding? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {},
        @ViewBuilder toolbar: @escaping () -> Toolbar
    ) {
        self.init(text: text, placeholder: placeholder, minLines: minLines, maxLines: maxLines,
                  fontSize: fontSize, status: status, canSend: canSend, canStop: canStop,
                  sendHelp: sendHelp, stopHelp: stopHelp, focus: focus,
                  onSend: onSend, onStop: onStop,
                  accessory: { EmptyView() }, toolbar: toolbar)
    }
}

public extension UDAgentComposer where Accessory == EmptyView, Toolbar == EmptyView {
    /// 既无前缀也无工具栏内容（底栏只剩发送 / 停止）。
    init(
        text: Binding<String>,
        placeholder: String,
        minLines: Int = 2,
        maxLines: Int? = nil,
        fontSize: CGFloat = 13,
        status: String? = nil,
        canSend: Bool,
        canStop: Bool = false,
        sendHelp: String = String(localized: "发送（↩）", bundle: ModuleBundle.bundle),
        stopHelp: String = String(localized: "停止（esc）", bundle: ModuleBundle.bundle),
        focus: FocusState<Bool>.Binding? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {}
    ) {
        self.init(text: text, placeholder: placeholder, minLines: minLines, maxLines: maxLines,
                  fontSize: fontSize, status: status, canSend: canSend, canStop: canStop,
                  sendHelp: sendHelp, stopHelp: stopHelp, focus: focus,
                  onSend: onSend, onStop: onStop,
                  accessory: { EmptyView() }, toolbar: { EmptyView() })
    }
}

// MARK: - 幽灵控件（无底色，hover / 展开才出底）

/// 工具栏下拉触发器的外观：`<内容> ⌄`。静态无底，hover 出 `uw04`，展开加深到 `uw06`。
/// 配 `UDDropdown` 用：`UDDropdown { open in UDComposerGhostLabel(open: open) { … } } content: { … }`。
public struct UDComposerGhostLabel<Content: View>: View {
    let open: Bool
    var showsChevron: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    /// - Parameter showsChevron: 收缩档（只剩一枚图标）可以省掉 chevron，把宽度让给邻居。
    public init(open: Bool, showsChevron: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.showsChevron = showsChevron
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 5) {
            content()
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .font(UD.font(11.5))
        .foregroundStyle(open || hovering ? UD.text : UD.text2)
        .padding(.horizontal, 6)
        .frame(minWidth: UDAgentComposerLayout.controlHeight)
        .frame(height: UDAgentComposerLayout.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(open ? UD.uw06 : hovering ? UD.uw04 : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// 工具栏图标钮（附加上下文、调出命令菜单…）：与 `UDComposerGhostLabel` 同高同圆角。
public struct UDComposerGhostIconStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? UD.text : UD.text3)
                .frame(width: UDAgentComposerLayout.controlHeight,
                       height: UDAgentComposerLayout.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? UD.uw06 : hovering ? UD.uw04 : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - 主操作钮（发送 / 停止）

private struct UDAgentComposerPrimaryStyle: ButtonStyle {
    enum Role { case send, stop }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        Chrome(role: role, configuration: configuration)
    }

    private struct Chrome: View {
        let role: Role
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: role == .stop ? 9.5 : 12, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: UDAgentComposerLayout.primarySize, height: UDAgentComposerLayout.primarySize)
                .background { Circle().fill(fill) }
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch role {
            case .send: return isEnabled ? .white : UD.text4
            case .stop: return UD.text
            }
        }

        private var fill: Color {
            switch role {
            case .send:
                guard isEnabled else { return UD.uw04 }
                return configuration.isPressed ? UD.accentPressed : (hovering ? UD.accentHover : UD.accent)
            case .stop:
                return configuration.isPressed || hovering ? UD.uw08 : UD.uw06
            }
        }
    }
}

// MARK: - 带说明的选项菜单

/// `UDOptionMenu` 的一项：图标 + 标题 + 一行说明。
public struct UDOptionMenuItem: Identifiable {
    public let id: String
    var systemImage: String
    var tint: Color
    var title: String
    var detail: String
    var active: Bool
    var action: () -> Void

    public init(id: String, systemImage: String, tint: Color, title: String, detail: String,
                active: Bool, action: @escaping () -> Void) {
        self.id = id
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.detail = detail
        self.active = active
        self.action = action
    }
}

/// 每项带一行说明的选项菜单（放进 `UDDropdown` 的浮层里）。
///
/// 给「几个档位、光看名字分不清差别」的选择用（如 Agent 的审批档位）：`UDMenu` 一项只有
/// 一个标签，差别只能藏在 tooltip 里。选中后经环境 `udMenuDismiss` 自动收起。
public struct UDOptionMenu: View {
    let width: CGFloat
    let head: String?
    let items: [UDOptionMenuItem]
    @Environment(\.udMenuDismiss) private var dismiss

    public init(width: CGFloat = 264, head: String? = nil, items: [UDOptionMenuItem]) {
        self.width = width
        self.head = head
        self.items = items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let head {
                Text(head.uppercased())
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text4)
                    .padding(.top, 4).padding(.horizontal, 8).padding(.bottom, 6)
            }
            ForEach(items) { item in
                UDOptionMenuRow(item: item) {
                    item.action()
                    dismiss()
                }
            }
        }
        .padding(4)
        .frame(width: width)
        .background { RoundedRectangle(cornerRadius: 9).fill(UD.overlay) }
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        // 落影由承载它的 `.anchoredPanel` 统一提供（同 `UDMenu`）；自带一层会叠成双重阴影。
    }
}

private struct UDOptionMenuRow: View {
    let item: UDOptionMenuItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(item.tint)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(UD.font(12))
                        .foregroundStyle(UD.text)
                    Text(item.detail)
                        .font(UD.font(11))
                        .foregroundStyle(UD.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if item.active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UD.accentInk)
                        .frame(height: 16)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 6).fill(hovering ? UD.panelHover : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.udPlain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityHint(item.detail)
        .accessibilityAddTraits(item.active ? .isSelected : [])
    }
}

// MARK: - Preview

#Preview {
    struct Wrapper: View {
        @State private var empty = ""
        @State private var filled = "帮我看下为什么 load average 这么高"

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                UDAgentComposer(text: $empty, placeholder: "描述目标，交给 Agent 处理…",
                                canSend: false, onSend: {}, toolbar: {
                    Button {} label: { Image(systemName: "plus") }
                        .buttonStyle(UDComposerGhostIconStyle())
                    UDComposerGhostLabel(open: false) { Text("claude-sonnet") }
                })
                UDAgentComposer(text: $filled, placeholder: "", status: "已停止",
                                canSend: true, canStop: true, onSend: {}, toolbar: {
                    UDComposerGhostLabel(open: false) { Text("gpt-4o") }
                })
                UDAgentComposer(text: $empty, placeholder: "Agent 正在处理…",
                                canSend: false, canStop: true, onSend: {})
            }
            .frame(width: 300)
            .padding(32)
            .background(UD.bg)
        }
    }
    return Wrapper()
}
#endif
