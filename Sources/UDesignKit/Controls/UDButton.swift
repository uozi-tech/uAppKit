import SwiftUI

/// uTerm DesignKit 按钮族 —— 设计稿 v2「填充即边界」Buttons 组。
///
/// `UDButton` 是 SwiftUI `Button` 的包装，五种风格（primary / secondary / ghost /
/// danger / link），前四种默认 32 高（可为局部操作区显式调整）、14 横向内边距、
/// `UD.Radius.md` 圆角、`UD.control` 字体；`link` 为紧凑透明文字链
/// （无底、无固定高、11.5pt）。
/// 通过自定义 `ButtonStyle` 读 hover（`.onHover`）+ `configuration.isPressed`。
///
/// v2 约定：**有填充就没有描边**（透明 1pt 描边占位防聚焦跳动）；两主题同构——
/// primary = accent 14% tint 底 + accent 色文字（非白字），hover / 按下换 hover / pressed 色的 tint；
/// secondary / ghost = `button2` 三态填充；danger = danger 14% tint 底 + danger 文字；
/// link = 透明底 + accent 文字。
/// `isLoading` 时前置 `ProgressView` 迷你转子、按钮不可点、文案由调用方切换（「创建中…」等）。
/// 状态切换仅靠底色与文本——无位移（transform）、无四周投影（shadow）。
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
public struct UDButton: View {
    /// 按钮风格。
    public enum Style {
        case primary, secondary, ghost, danger, link
    }

    let title: String
    var style: Style = .primary
    var systemImage: String? = nil
    /// 按钮内尾部的键位提示（如 "esc"、"⌘↵"）；nil 不显示。随按钮文本色自适应。
    var trailingHint: String? = nil
    /// 非 link 按钮的视觉高度；默认保持设计系统的紧凑 32pt。
    var height: CGFloat = 32
    /// 进行中：前置迷你转子、按钮不可点。文案由调用方切换（传「创建中…」）。
    var isLoading: Bool = false
    /// 底色撑满可用宽度（表单底部的整宽主按钮，如提交框）；默认随内容宽。link 风格忽略。
    var fillsWidth: Bool = false
    let action: () -> Void

    public init(
        title: String,
        style: Style = .primary,
        systemImage: String? = nil,
        trailingHint: String? = nil,
        height: CGFloat = 32,
        isLoading: Bool = false,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.systemImage = systemImage
        self.trailingHint = trailingHint
        self.height = height
        self.isLoading = isLoading
        self.fillsWidth = fillsWidth
        self.action = action
    }

    /// 转子颜色随风格取按钮的基准文本色（circular `ProgressView` 走 `.tint`）。
    private var spinnerTint: Color {
        switch style {
        case .primary, .link: return UD.accent
        case .secondary, .ghost: return UD.text2
        case .danger: return UD.danger
        }
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).tint(spinnerTint)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                if let trailingHint {
                    UDButtonKbd(text: trailingHint).padding(.leading, 1)
                }
            }
        }
        .buttonStyle(UDButtonStyle(style: style, height: height, fillsWidth: fillsWidth))
        .allowsHitTesting(!isLoading)
    }
}

/// 按钮内嵌的键位小帽：背景用当前前景色的低透明度叠底，文本继承按钮前景色，
/// 故在实心 / 半透明 / 各风格按钮上都自洽（无需感知具体风格）。
private struct UDButtonKbd: View {
    let text: String
    public var body: some View {
        Text(UFormat.shortcut(text))
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
            )
            .opacity(0.9)
    }
}

// MARK: - ButtonStyle

private struct UDButtonStyle: ButtonStyle {
    let style: UDButton.Style
    let height: CGFloat
    var fillsWidth = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let c = colors(pressed: configuration.isPressed)
        return Group {
            if style == .link {
                // 紧凑透明文字链：无底、无固定高，只切文本色。
                configuration.label
                    .font(UD.font(11.5, weight: .medium))
                    .foregroundStyle(c.text)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
            } else {
                configuration.label
                    .font(UD.control)
                    .foregroundStyle(c.text)
                    .frame(height: height)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .background(
                        RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                            .fill(c.bg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                            .strokeBorder(c.border, lineWidth: 1)
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    // MARK: 配色映射（深 vs 浅 不同）

    private struct Palette {
        var bg: Color
        var border: Color
        var text: Color
    }

    /// 解析当前视觉态配色。优先级：禁用 → 按下(active) → 悬停 → 默认；
    /// v2「填充即边界」：两主题同构，全部 tint / 淡灰填充，`border` 恒为 `.clear`
    /// （描边槽位保留作 1pt 透明占位，防状态切换布局跳动）。
    private func colors(pressed: Bool) -> Palette {
        let hover = hovering && isEnabled
        let down = pressed && isEnabled

        switch style {
        case .primary:
            // tint 型主按钮：accent 14% 底 + accent 色文字（非白字）。
            guard isEnabled else {
                return Palette(bg: UD.accentTintDisabled, border: .clear,
                               text: UD.accentInk.opacity(0.45))
            }
            let bg: Color = down ? UD.accentTintPressed
                                 : (hover ? UD.accentTintHover : UD.accentTint)
            return Palette(bg: bg, border: .clear, text: UD.accentInk)

        case .secondary, .ghost:
            // 次按钮 / 幽灵：调色板 button2 三态填充、无边。
            guard isEnabled else {
                return Palette(bg: UD.uw03, border: .clear, text: UD.text4)
            }
            if down {
                return Palette(bg: UD.button2Pressed, border: .clear, text: UD.text)
            }
            return Palette(bg: hover ? UD.button2Hover : UD.button2, border: .clear,
                           text: hover ? UD.text : UD.text2)

        case .danger:
            guard isEnabled else {
                return Palette(bg: UD.danger.opacity(0.07), border: .clear,
                               text: UD.danger.opacity(0.45))
            }
            let bg = (hover || down) ? UD.danger.opacity(0.22) : UD.danger.opacity(0.14)
            return Palette(bg: bg, border: .clear, text: (hover || down) ? UD.dangerHover : UD.danger)

        case .link:
            // 透明文字链：无底无边，accent 文字；禁用 text4，按下略降透明。
            guard isEnabled else {
                return Palette(bg: .clear, border: .clear, text: UD.text4)
            }
            return Palette(bg: .clear, border: .clear,
                           text: down ? UD.accentInk.opacity(0.7) : UD.accentInk)
        }
    }
}

// MARK: - UDIconButton

/// 纯图标钮（工具栏 / 行尾操作）。默认 28×28 `.plain`（无描边，idle `UD.text3`、
/// hover 底 `UD.panelHover` + 文本 `UD.text`、按下叠更亮底）。另有：
/// `.filled` = accentTint 底 + accent 图标；`.bordered` = uw04 底 + hairline 描边；
/// `.danger` = 透明 idle，hover 染 danger 底 + danger 图标。`size` 可调（迷你清除 18 /
/// 密码框 26 / 翻页 32）。仅切底色与文本，无位移、无投影。
public struct UDIconButton: View {
    /// 图标钮风格。
    public enum Style { case plain, filled, bordered, danger }

    let systemImage: String
    var size: CGFloat = 28
    var style: Style = .plain
    var isSpinning = false
    let action: () -> Void

    /// - Parameter isSpinning: 图标原地匀速旋转（刷新进行中），见 `UDRefreshButton`。
    public init(systemImage: String, size: CGFloat = 28, style: Style = .plain, isSpinning: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.size = size
        self.style = style
        self.isSpinning = isSpinning
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            // 图标框比字号大 1pt：`xmark` / `plus` 这类本来就小的不动，`eye` / `doc.on.doc`
            // 这类宽或高的收进框里，并按墨迹居中（见 `USymbol`）。
            let pt: CGFloat = size <= 20 ? 10 : 12
            UDSpinningIcon(isSpinning: isSpinning, anchor: Self.rotationAnchor(systemImage)) {
                USymbol(systemImage, size: pt, box: pt + 1)
            }
        }
        .buttonStyle(UDIconButtonStyle(size: size, style: style))
    }

    /// 环形符号绕圆心转（墨迹框中心会被箭头撑偏，见 `USymbolMetrics.rotationAnchor`）。
    private static func rotationAnchor(_ name: String) -> UnitPoint {
        #if canImport(AppKit)
        USymbolMetrics.rotationAnchor(name) ?? .center
        #else
        .center
        #endif
    }
}

/// 刷新按钮：刷新进行中时 `arrow.clockwise` 自己转圈，不再在旁边另放一个小转圈。
/// 转圈期间再点不触发（避免叠请求）。
public struct UDRefreshButton: View {
    let isRefreshing: Bool
    var size: CGFloat
    let action: () -> Void

    public init(isRefreshing: Bool, size: CGFloat = 28, action: @escaping () -> Void) {
        self.isRefreshing = isRefreshing
        self.size = size
        self.action = action
    }

    public var body: some View {
        UDIconButton(systemImage: "arrow.clockwise", size: size, isSpinning: isRefreshing) {
            if !isRefreshing { action() }
        }
    }
}

/// 原地匀速旋转（一圈 1 秒）：开始时从 0° 起转；停下时把当前这一圈转完再停，不跳回 0°。
/// `anchor` 是旋转轴心（环形符号传圆心）。「减弱动态效果」打开时不转，改为半透明。
struct UDSpinningIcon<Content: View>: View {
    let isSpinning: Bool
    var anchor: UnitPoint = .center
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 这一轮开始转的时刻；转完收尾后清空。
    @State private var spinStart: Date?
    /// 不再转了：转到这个时刻（整圈）停。
    @State private var stopAt: Date?

    static var period: TimeInterval { 1 }

    static func angle(at date: Date, since start: Date) -> Angle {
        let turns = max(date.timeIntervalSince(start), 0) / period
        return .degrees((turns - turns.rounded(.down)) * 360)
    }

    /// 停在当前这一圈转完的时刻（刚开始就停也至少转满一圈，让点击有反馈）。
    static func stopDate(start: Date, now: Date) -> Date {
        let turns = max(now.timeIntervalSince(start) / period, 0)
        return start.addingTimeInterval(max(turns.rounded(.up), 1) * period)
    }

    var body: some View {
        Group {
            if reduceMotion {
                content.opacity(isSpinning ? 0.5 : 1)
            } else if let spinStart {
                TimelineView(.animation) { context in
                    let date = stopAt.map { min(context.date, $0) } ?? context.date
                    content.rotationEffect(Self.angle(at: date, since: spinStart), anchor: anchor)
                }
            } else {
                content
            }
        }
        .onAppear { if isSpinning, spinStart == nil { spinStart = Date() } }
        .onChange(of: isSpinning) { _, spinning in
            if spinning {
                // 收尾那一圈里又开始转：接着转，不重新起步。
                if spinStart == nil { spinStart = Date() }
                stopAt = nil
            } else if let spinStart {
                stopAt = Self.stopDate(start: spinStart, now: Date())
            }
        }
        .task(id: stopAt) {
            guard let stopAt else { return }
            try? await Task.sleep(for: .seconds(max(stopAt.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, self.stopAt == stopAt, !isSpinning else { return }
            spinStart = nil
            self.stopAt = nil
        }
    }
}

private struct UDIconButtonStyle: ButtonStyle {
    let size: CGFloat
    let style: UDIconButton.Style
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && isEnabled
        let hover = hovering && isEnabled
        let c = colors(hover: hover, down: down)
        let radius: CGFloat = size >= 30 ? UD.Radius.md : UD.Radius.sm
        return configuration.label
            .font(.system(size: size <= 20 ? 10 : 12))
            .foregroundStyle(c.text)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(c.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(c.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }

    private struct Palette { var bg: Color; var border: Color; var text: Color }

    /// plain 按下底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let plainDownBg = UD.dyn(.white(0.12), .black(0.10))

    private func colors(hover: Bool, down: Bool) -> Palette {
        switch style {
        case .plain:
            let text: Color = !isEnabled ? UD.text4 : ((hover || down) ? UD.text : UD.text3)
            let bg: Color = down ? Self.plainDownBg
                                 : (hover ? UD.panelHover : .clear)
            return Palette(bg: bg, border: .clear, text: text)
        case .filled:
            guard isEnabled else { return Palette(bg: UD.accentTintDisabled, border: .clear, text: UD.accentInk.opacity(0.45)) }
            let bg: Color = down ? UD.accentTintPressed : (hover ? UD.accentTintHover : UD.accentTint)
            return Palette(bg: bg, border: .clear, text: UD.accentInk)
        case .bordered:
            let text: Color = !isEnabled ? UD.text4 : ((hover || down) ? UD.text : UD.text2)
            let bg: Color = down ? UD.button2Pressed : (hover ? UD.button2Hover : UD.button2)
            return Palette(bg: bg, border: .clear, text: text)
        case .danger:
            guard isEnabled else { return Palette(bg: .clear, border: .clear, text: UD.text4) }
            let bg: Color = (hover || down) ? UD.danger.opacity(0.14) : .clear
            let text: Color = (hover || down) ? UD.danger : UD.text3
            return Palette(bg: bg, border: .clear, text: text)
        }
    }
}

// MARK: - Preview

#Preview {
    @MainActor func gallery(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([("primary", UDButton.Style.primary),
                     ("secondary", .secondary),
                     ("ghost", .ghost),
                     ("danger", .danger),
                     ("link", .link)], id: \.0) { name, style in
                HStack(spacing: 12) {
                    Text(name)
                        .font(UD.caption)
                        .foregroundStyle(UD.text3)
                        .frame(width: 72, alignment: .leading)
                    UDButton(title: "默认", style: style) {}
                    UDButton(title: "禁用", style: style) {}
                        .disabled(true)
                }
            }

            HStack(spacing: 12) {
                Text("loading").font(UD.caption).foregroundStyle(UD.text3).frame(width: 72, alignment: .leading)
                UDButton(title: "创建中…", style: .primary, isLoading: true) {}
                UDButton(title: "新建服务器", style: .primary, systemImage: "plus") {}
            }

            HStack(spacing: 8) {
                Text("icon").font(UD.caption).foregroundStyle(UD.text3).frame(width: 72, alignment: .leading)
                UDIconButton(systemImage: "pencil") {}
                UDIconButton(systemImage: "wand.and.stars", style: .filled) {}
                UDIconButton(systemImage: "chevron.left", size: 32, style: .bordered) {}
                UDIconButton(systemImage: "trash", style: .danger) {}
                UDIconButton(systemImage: "xmark", size: 18) {}
            }
        }
        .padding(24)
        .frame(width: 380, alignment: .leading)
        .background(UD.bg)
        .environment(\.colorScheme, scheme)
    }

    return HStack(spacing: 0) {
        gallery(.dark)
        gallery(.light)
    }
}
